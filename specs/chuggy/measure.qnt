/// THE MEASURE COMES FIRST (chuggy-charter.md §5, standing rule 1: "The
/// termination measure is written before the machine"). This module was
/// written before domain.qnt, and domain.qnt was designed to fit it — every
/// transition the machine takes either strictly descends `jobMeasure` or
/// belongs to one of the two named non-descending sets at the bottom of this
/// header. The record types live here too: the measure is a pure function of
/// a single job's record (per-job — the committed half of the termination
/// row, charter §2; the contested system-quiescence half, §4, is deferred),
/// so the record shape is part of the measure's definition, not the
/// machine's.
///
/// The measure is LEXICOGRAPHIC over the bounded accounts, most significant
/// first, flattened into one nonnegative integer by radix weighting (every
/// digit is bounded by its radix, so the integer order IS the lexicographic
/// order):
///
///   1. deadlineLeft   — deadline gas (charter §2: deadline REQUIRED; init
///                       admits no graph without it). Charged on every entry
///                       to Working and on metered operator retries; never
///                       refunded.
///   2. gateLeft       — gate-rework budget, only under
///                       GatePricing = Budgeted(n) (charter §2 gate-pricing
///                       row; identically 0 under DeadlineOnly).
///   3. reworkLeft     — eval-rework budget.
///   4. micro          — within-cycle progress:
///                       phaseRank  (Pending 4 > Working 3 > Evaluating 2 >
///                                   Landing 1 > Done/Escalated/Stalled 0)
///                       then running-task count (the parallel task set,
///                                                charter §2 job anatomy).
///
/// There is deliberately NO attempt digit and no per-attempt account:
/// same-cycle retry machinery is a charter non-goal (§2 non-goals row: "no
/// retry machinery below the cycle") and container relaunches live in the
/// trusted, unmodeled `backoffLimit` fabric axiom (§2 fabric row) — the
/// model prices CYCLES, not container relaunches.
///
/// Weights (b: Bounds): rankWeight = nTasks + 1 dominates the running-task
/// count (<= nTasks); microBound = 5 * rankWeight dominates micro
/// (rank <= 4). So one unit of any account outweighs every within-cycle
/// climb below it.
///
/// DESCENT TABLE — which transitions descend, and by which account.
/// (Deltas verified per-step by the machine's `stepDescends` invariant and
/// by tests/chuggy_test.qnt; labels are domain.qnt's StepRecord labels.)
///
///   label                               descends via
///   ----------------------------------- ---------------------------------
///   dispatch                            gas -1 (micro also falls:
///                                       rank 4->3 dominates the spawn: -1)
///   task-done (a running task resolves) task count -1
///   work-passed                         rank 3->2 (dominates respawn: -1)
///   job-escalated work_failed           rank 3->0 (cycle-level resolution:
///                                       the fabric already retried below
///                                       the cycle via trusted backoffLimit)
///   eval-passed                         rank 2->1
///   rework-started eval_failure         gas -1 AND reworkLeft -1
///   job-escalated rework_budget_exhausted rank 2->0
///   job-escalated job_deadline_exceeded rank {2,1}->0
///   job-done                            rank 1->0
///   rework-started gate_failure         gas -1 (AND gateLeft -1 when Budgeted)
///   job-escalated gate_budget_exhausted rank 1->0 (Budgeted only)
///   job-stalled revalidation_failed     rank 4->0
///   operator-retry, whenever it charges gas -1 (dominates the rank climb
///     gas (always under RetryCharged,    back to 3/2/1 + task respawn,
///     Working-resume under RetryFree)    since gas outweighs microBound)
///
/// NAMED NON-DESCENDING SETS — everything else, isolated by name:
///
///   STUTTER (state-identical; at-least-once delivery noise — the fabric
///   axioms row dropped no-double-pods, charter §2, so duplicates are
///   tolerated idempotently and change nothing):
///     task-done-duplicate (= 0), land-duplicate (= 0), settled (= 0).
///   Finitely many by fabric assumption; they cannot cycle through distinct
///   states, so termination is modulo this stuttering.
///
///   CHURN (operator/environment re-entry; measure may CLIMB; every path
///   back into active work is still metered at the Working boundary —
///   standing rule 2, with operator paths governed by the §2 op-retry
///   configurability row):
///     stalled-retry                        (+4*rankWeight)
///     operator-retry into Evaluating/Landing under RetryFree
///                                          (+<= 2*rankWeight + nTasks)
///   Under the DEFAULT metering (RetryCharged) the churn set is
///   stalled-retry alone. RetryFree deliberately reproduces v1's discovered
///   operator-churn livelock (model-status §5b) as a configuration, so the
///   model can generate escalation traces under both prices — the
///   mc_chuggy_retryfree instance plus check.sh Stage 9's expected-violation
///   witness keep that exemption exercised, not dead.
///
/// PER-JOB LIVENESS, SKETCHED (roadmap PR 1 gate): jobMeasure is a
/// nonnegative integer, every non-STUTTER non-CHURN step strictly decreases
/// the sum of jobMeasure over all jobs, and each CHURN step requires an
/// operator acting on a desk-visible job (domain.qnt `deskVisibility`). So
/// under default metering, any run with finitely many stutter and churn
/// events parks every job in Done, Escalated, or Stalled. The unconditional
/// system-quiescence theorem is charter §4's contested half and is NOT
/// claimed here.
module chuggy_measure {

  // === Vocabulary ==========================================================
  // Sum-type constructors share one namespace per module, hence the
  // prefixes (P/T/V/R/Rs/C/Land). The two-branch parameter types keep bare
  // descriptive constructor names — Budgeted/DeadlineOnly (GatePricing) and
  // RetryCharged/RetryFree (RetryPricing) — documented here because they
  // live in the same module-wide constructor namespace.

  /// STORED job phases. Deliberately few (charter standing rule 3, derive
  /// don't store): Blocked and Ready are PREDICATES over deps + record in
  /// domain.qnt, not phases — a job that has not started is PPending, and
  /// the waiting-room split is derived. PPending must be stored (phase is
  /// total and "never started" is not expressible as a predicate over the
  /// other fields without overloading them). PWorking/PEvaluating carry the
  /// parallel task set; PLanding is its own phase because its outcome is
  /// the exclusivity boundary (charter §2, effect-only exclusivity); PDone
  /// is absorbing; PEscalated/PStalled are the human desk.
  type Phase =
    PPending | PWorking | PEvaluating | PLanding | PDone | PEscalated | PStalled

  /// A first-class task record (charter §2 job anatomy: Work and Eval
  /// phases each carry a set of discrete, possibly parallel tasks; the task
  /// records carry the anatomy). PR 1 keeps a task to its minimum: identity
  /// plus outcome. PR 3 (task-records depth) grows the anatomy.
  type Task = { id: int, outcome: TaskOutcome }

  /// A task's stored outcome. TFailed covers BOTH a failed verdict and
  /// evaluator-infrastructure death: "the job pays" for evaluator crashes —
  /// one account, no new machinery (charter §2 eval/evaluator-failure).
  type TaskOutcome = TRunning | TPassed | TFailed

  /// A task-completion event's verdict (the event, as distinct from the
  /// stored outcome — duplicates of the event must be tolerated).
  type Verdict = VPass | VFail

  /// Verdict combinator over a resolved task set — eval is data, not
  /// machinery (charter §2): the machine takes the combinator as a
  /// parameter and instantiates unanimous-pass as the default. A sum-type
  /// selector rather than an operator-typed const (Quint 0.32 consts are
  /// values); both branches are real so the parameter is exercisable.
  type Combinator = CUnanimousPass | CAnyPass

  /// Gate-rework pricing — a model parameter, not a constant (charter §2):
  /// the model generates escalation traces under both branches and the
  /// choice is made on evidence.
  type GatePricing = Budgeted(int) | DeadlineOnly

  /// Operator-retry metering — configurable per deployment, default charge
  /// (charter §2 economy/op-retry). RetryFree reproduces v1's discovered
  /// livelock (model-status §5b) by configuration.
  type RetryPricing = RetryCharged | RetryFree

  /// Where an operator Retry resumes an escalated job (RNone when not
  /// escalated).
  type Resume = RNone | RWorking | REvaluating | RLanding

  /// Why a job sits on the human desk. The wall VOCABULARY is carried from
  /// v1's explainer (docs/chuggernaut.md §5) and constrained by the charter
  /// §2 termination row (which commits the terminals Done/Escalated/
  /// Stalled) — the charter itself does not name individual walls.
  /// RsGateBudgetExhausted exists only under Budgeted pricing;
  /// RsWorkFailed is the CYCLE-level work wall (there is no retries wall:
  /// below-cycle retries are the fabric's trusted backoffLimit, §2).
  type Reason =
    RsNone | RsWorkFailed | RsReworkBudgetExhausted |
    RsGateBudgetExhausted | RsDeadlineExceeded | RsRevalidationFailed

  /// How a landing resolves. The two SUCCESS outcomes are deliberately
  /// distinct from day one — v1's single conformance divergence was exactly
  /// AdvanceDefault vs SquashMerge (charter §2 landing row); mechanics stay
  /// abstract until landing/requirements is answered (roadmap PR 5).
  type LandOutcome = LandAdvanceDefault | LandSquashMerge | LandFailed

  /// One job's record. The measure below is a pure function of this.
  type Job = {
    phase: Phase,
    // Upstream dependency job ids (acyclic by construction in domain.qnt).
    deps: Set[int],
    // The live task set of the current Working/Evaluating phase; empty in
    // every other phase.
    tasks: Set[Task],
    // Eval-rework budget REMAINING (counts down; the measure wants
    // remaining, not spent).
    reworkLeft: int,
    // Gate-rework budget remaining; identically 0 under DeadlineOnly.
    gateLeft: int,
    // Deadline gas remaining — the REQUIRED account (charter §2).
    deadlineLeft: int,
    // Operator-resume point (RNone unless Escalated).
    resumeAt: Resume,
    // Desk reason (RsNone unless Escalated/Stalled). Deliberately
    // FIRST-CLASS stored trace vocabulary, not derived from phase: PR 2's
    // authoring stall causes break its derivability.
    reason: Reason,
    // GHOST: landing effects ever emitted for this job — the counter the
    // effect-exclusivity invariant (charter §2: exactly one landing) reads.
    // Not implementation state.
    landings: int
  }

  /// Standing rule 3 (derive, don't store): the open-human-task flag IS a
  /// predicate over the phase — a desk task is open exactly while the job
  /// is parked on the desk. (v1 stored the flag and proved the iff as an
  /// invariant; chuggy derives it, so the invariant is by construction.)
  /// The trace-visible artifact is the "OpenHumanTask" effect string.
  pure def hasOpenHumanTask(job: Job): bool =
    job.phase == PEscalated or job.phase == PStalled

  /// The machine's observed state, as the pure deciders see it. A record
  /// (not a bare map) so the job-source shape stays open: authoring (PR 2)
  /// attaches by widening this record, without surgery on the deciders.
  type Core = { jobs: int -> Job }

  /// One observed job-phase transition, golden-trace shaped (standing rule
  /// 4: conformance from day one — the model emits, the implementation
  /// replays).
  type Transition = { job: int, from: Phase, to: Phase }

  /// One decision's observable record, mirroring the golden-trace step
  /// schema {event, transitions, effects}.
  type StepRecord = { label: str, transitions: List[Transition], effects: List[str] }

  /// What a pure decider returns: record performed + post-state.
  type Decision = { rec: StepRecord, post: Core }

  /// The bounds the measure is parameterized by — passed explicitly so this
  /// module needs no consts and the measure stays a pure function usable
  /// from tests with any bounds.
  type Bounds = {
    reworkBudget: int,
    nTasks: int,
    gatePricing: GatePricing
  }

  // === The measure =========================================================

  /// The gate account's size under a pricing: Budgeted(n) grants n,
  /// DeadlineOnly grants none (gas alone meters the gate loop — v1's
  /// documented-livelock shape, kept as the branch to be priced on
  /// evidence).
  pure def gateBudget(gp: GatePricing): int =
    match gp {
      | Budgeted(n) => n
      | DeadlineOnly => 0
    }

  /// How far from settled a job's lifecycle position is. Terminals (and the
  /// human desk) rank 0.
  pure def phaseRank(p: Phase): int =
    match p {
      | PPending => 4
      | PWorking => 3
      | PEvaluating => 2
      | PLanding => 1
      | _ => 0
    }

  pure def runningCount(tasks: Set[Task]): int =
    tasks.filter(t => t.outcome == TRunning).size()

  /// Weight of one unit of phase rank: strictly dominates the running-task
  /// count (<= nTasks).
  pure def rankWeight(b: Bounds): int = b.nTasks + 1

  /// Strict upper bound on micro (rank <= 4, so micro < 5*rankWeight).
  pure def microBound(b: Bounds): int = 5 * rankWeight(b)

  /// Within-cycle progress, lexicographic (rank, running count).
  pure def micro(b: Bounds, job: Job): int =
    phaseRank(job.phase) * rankWeight(b) + runningCount(job.tasks)

  /// THE per-job termination measure: lexicographic
  /// (deadlineLeft, gateLeft, reworkLeft, micro), radix-flattened.
  /// Nonnegative whenever the accounts are (domain.qnt's accountsBounded
  /// keeps them so).
  pure def jobMeasure(b: Bounds, job: Job): int =
    ((job.deadlineLeft * (gateBudget(b.gatePricing) + 1) + job.gateLeft)
        * (b.reworkBudget + 1)
      + job.reworkLeft) * microBound(b)
    + micro(b, job)

  /// Sum over the fleet — steps touch one job, so per-step descent of the
  /// sum IS per-job descent. Order-independent fold (+ commutes).
  pure def sysMeasure(b: Bounds, jobs: int -> Job): int =
    jobs.keys().fold(0, (acc, j) => acc + jobMeasure(b, jobs.get(j)))

  // === Vocabulary helpers (task plumbing shared by machine and tests) ======

  /// A fresh parallel task set, all running — spawned on every entry to
  /// Working/Evaluating.
  pure def freshTasks(n: int): Set[Task] =
    1.to(n).map(i => { id: i, outcome: TRunning })

  /// First write wins: resolve task `tid` if it is still running; the
  /// caller (decideTaskDone) treats an already-resolved task as a duplicate
  /// delivery and changes nothing — the idempotence the dropped
  /// no-double-pods axiom demands (charter §2 fabric row).
  pure def resolveTask(tasks: Set[Task], tid: int, out: TaskOutcome): Set[Task] =
    tasks.map(t => if (t.id == tid and t.outcome == TRunning) { ...t, outcome: out } else t)

  /// The verdict combinator, interpreted (eval is data: the program stays
  /// abstract until a real eval/vocabulary example exists — charter §3,
  /// roadmap PR 3). Callers guarantee all tasks are resolved.
  pure def combine(c: Combinator, tasks: Set[Task]): bool =
    match c {
      | CUnanimousPass => tasks.forall(t => t.outcome == TPassed)
      | CAnyPass => tasks.exists(t => t.outcome == TPassed)
    }
}
