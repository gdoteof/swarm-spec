/// THE MEASURE COMES FIRST (chuggy-charter.md §5, standing rule 1: "The
/// termination measure is written before the machine"). This module was
/// written before domain.qnt, and domain.qnt was designed to fit it — every
/// transition the machine takes either strictly descends `jobMeasure` or
/// belongs to one of the three named non-descending sets at the bottom of
/// this header (STUTTER and CHURN from PR 1; AUTHORING from PR 2; PR 3
/// extended the micro digit here BEFORE domain.qnt grew stages — the rule
/// held a third time).
/// The record types live here too: the measure is a pure function of
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
///   4. micro          — within-cycle progress, now THREE sub-digits
///                       (PR 3), lexicographic:
///                       phaseRank   (Draft 6 > Frozen 5 above the released
///                                    pipeline — PR 2 authoring;
///                                    Pending 4 > Working 3 > Evaluating 2 >
///                                    Landing 1 >
///                                    Done/Escalated/Stalled/Revoked 0 — the
///                                    settled tier)
///                       then stagesLeft  (PR 3: how many stages of the
///                                    job's authored eval program have not
///                                    yet passed — nonzero only in
///                                    Evaluating; the within-phase progress
///                                    the roadmap PR 3 row asks for)
///                       then runningCount (the parallel task set of the
///                                    current phase/stage, charter §2 job
///                                    anatomy).
///
/// THE PR 3 DIGIT-ORDER ARGUMENT (why stagesLeft sits BELOW phase rank and
/// ABOVE — not beside — the running-task count):
///   - BELOW rank: entering Evaluating (work-passed, rank 3->2) makes the
///     stage digit APPEAR at its maximum (stagesLeft 0 -> L <= maxStages)
///     while the stage-0 fan-out spawns (running 0 -> <= nTasks). The one
///     rank step must dominate both at once, which forces
///     rankWeight > maxStages*stageWeight + nTasks — the rankWeight
///     definition below is exactly that bound plus one. Every EXIT from
///     Evaluating (eval-passed, rework, walls, revoke) drops rank or an
///     account, so the stage digit vanishing on exit never needs its own
///     descent argument.
///   - ABOVE the count: advancing a stage (eval-stage-passed) retires a
///     fully-resolved task set (running 0) and spawns the next stage's
///     fan-out — the running count JUMPS from 0 to <= nTasks in the same
///     step. stagesLeft falls by exactly 1, so one stage step must outweigh
///     the whole jump: stageWeight = nTasks + 1. Were the stage digit
///     merely BESIDE the count (equal weight), stage advance over any
///     fan-out > 1 would CLIMB the measure and the machine's cleanest
///     progress step would need an exemption — the wrong shape for the one
///     transition PR 3 exists to add.
///
/// There is deliberately NO attempt digit and no per-attempt account:
/// same-cycle retry machinery is a charter non-goal (§2 non-goals row: "no
/// retry machinery below the cycle") and container relaunches live in the
/// trusted, unmodeled `backoffLimit` fabric axiom (§2 fabric row) — the
/// model prices CYCLES, not container relaunches. PR 3 re-affirms this
/// against the extracted vocabulary: chuggernaut's per-task `work_retries`/
/// `eval_retries` (spec.md §1.2, attempt counters on the task record) are
/// exactly the below-cycle machinery the non-goal excludes, so chuggy tasks
/// carry no attempt counter and no per-task budget (README notes the skip).
///
/// The retained task RECORD (PR 3, Job.record below) is NOT a measure
/// input: it is append-only provenance, so it could only ever climb — the
/// measure reads phase, live tasks, program length, and the accounts. The
/// program is immutable after arrival and enters only through stagesLeft.
///
/// Weights (b: Bounds), re-derived for PR 3 (every changed weight, from its
/// radix):
///   stageWeight = nTasks + 1
///     — one stage step dominates any running count (<= nTasks). NEW.
///   rankWeight  = (maxStages + 1) * stageWeight
///     — one rank step dominates the full stage digit plus any count:
///       stagesLeft <= maxStages (programsWellFormed caps authored programs
///       at MAX_STAGES), so
///       stagesLeft*stageWeight + runningCount
///         <= maxStages*stageWeight + nTasks < (maxStages+1)*stageWeight.
///       CHANGED: PR 1-2 had rankWeight = nTasks + 1; the stage digit now
///       sits between, so the rank radix widens by the stage radix.
///   microBound  = 7 * rankWeight
///     — the top rank is still 6 (PDraft, unchanged since PR 2), so
///       micro = rank*rankWeight + stagesLeft*stageWeight + runningCount
///            <= 6*rankWeight + (rankWeight - 1) < 7*rankWeight.
///       The multiplier 7 is UNCHANGED from PR 2; only rankWeight under it
///       grew.
/// The domination chain above micro is unchanged in shape: micro <
/// microBound, so one unit of reworkLeft outweighs any within-cycle climb
/// (radix microBound), one unit of gateLeft outweighs any reworkLeft refill
/// (radix reworkBudget+1), and one unit of deadline gas outweighs
/// everything below it (radix gateBudget+1). Every digit stays strictly
/// below its radix, so the flattened integer order IS the lexicographic
/// order.
///
/// DESCENT TABLE — which transitions descend, and by which account.
/// (Deltas verified per-step by the machine's `stepDescends` invariant and
/// by tests/chuggy_test.qnt; labels are domain.qnt's StepRecord labels.)
///
///   label                               descends via
///   ----------------------------------- ---------------------------------
///   job-frozen                          rank 6->5 (authoring: freeze)
///   job-released                        rank 6->4 or 5->4 (authoring:
///                                       release; Ready/Blocked stay derived)
///   job-revoked (from any rank>0 phase) rank {6,5,4,3,2,1}->0, stage digit
///                                       and live tasks cleared (retired to
///                                       the record, which the measure does
///                                       not read); every dependent the
///                                       atomic cascade parks adds its own
///                                       rank {6,5,4}->0 drop (see the
///                                       AUTHORING set for the desk-only
///                                       flat case)
///   dispatch                            gas -1 (micro also falls:
///                                       rank 4->3 dominates the spawn:
///                                       −rankWeight + nTasks < 0 — re-
///                                       derived for PR 3's wider rankWeight;
///                                       the PR 1-2 delta was -1 only
///                                       because rankWeight was nTasks+1)
///   task-done (a running task resolves) task count -1
///   work-passed                         rank 3->2 (dominates the stage
///                                       digit appearing at L <= maxStages
///                                       AND the stage-0 fan-out spawn —
///                                       the rankWeight bound above)
///   eval-stage-passed (PR 3, NEW —      stagesLeft -1 (dominates the next
///     a non-final stage passes;           stage's fan-out spawn:
///     Evaluating -> Evaluating,           -stageWeight + fanout <= -1)
///     chuggernaut spec.md §2.1 line 832)
///   job-escalated work_failed           rank 3->0 (cycle-level resolution:
///                                       the fabric already retried below
///                                       the cycle via trusted backoffLimit)
///   eval-passed (the FINAL stage        rank 2->1 AND stagesLeft 1->0
///     passes)
///   rework-started eval_failure         gas -1 AND reworkLeft -1 (the
///     (a stage FAILS: the short-circuit   micro reset — rank 2->3, stage
///     — later stages never spawn)         digit ->0, work respawn — is
///                                         dominated by the account drop)
///   job-escalated rework_budget_exhausted rank 2->0 (and stage digit ->0)
///   job-escalated job_deadline_exceeded rank {2,1}->0
///   job-done                            rank 1->0
///   rework-started gate_failure         gas -1 (AND gateLeft -1 when Budgeted)
///   job-escalated gate_budget_exhausted rank 1->0 (Budgeted only)
///   job-stalled revalidation_failed     rank 4->0
///   operator-retry, whenever it charges gas -1 (dominates the rank climb
///     gas (always under RetryCharged,    back to 3/2/1 + respawn — for the
///     Working-resume under RetryFree)    REvaluating resume that includes
///                                        the stage digit reappearing at L:
///                                        the whole climb is < microBound,
///                                        which gas outweighs)
///
/// NAMED NON-DESCENDING SETS — everything else, isolated by name:
///
///   STUTTER (state-identical; at-least-once delivery noise — the fabric
///   axioms row dropped no-double-pods, charter §2, so duplicates are
///   tolerated idempotently and change nothing):
///     task-done-duplicate (= 0), land-duplicate (= 0), settled (= 0).
///   PR 3 widened task-done-duplicate's REACH, not its effect: task ids are
///   now unique across the job's whole history (sequential within job,
///   chuggernaut spec.md §1.2), so a stale completion from an EARLIER
///   stage or incarnation no-ops BY IDENTITY — its id is already retired
///   into the record — where PR 1 had to absorb it into the nondet verdict
///   of a respawned same-id task. Finitely many by fabric assumption; they
///   cannot cycle through distinct states, so termination is modulo this
///   stuttering.
///
///   CHURN (operator/environment re-entry; measure may CLIMB; every path
///   back into active work is still metered at the Working boundary —
///   standing rule 2, with operator paths governed by the §2 op-retry
///   configurability row):
///     stalled-retry                        (+4*rankWeight)
///     operator-retry into Evaluating/Landing under RetryFree
///       (+<= 2*rankWeight + maxStages*stageWeight + nTasks — the
///        Evaluating resume respawns the LOWEST stage's fan-out with the
///        full stage digit, chuggernaut §1.2 escalation Retry: "a fresh
///        eval fan-out"; bound re-derived for PR 3's stage digit)
///   Under the DEFAULT metering (RetryCharged) the churn set is
///   stalled-retry alone. RetryFree deliberately reproduces v1's discovered
///   operator-churn livelock (model-status §5b) as a configuration, so the
///   model can generate escalation traces under both prices — the
///   mc_chuggy_retryfree instance plus check.sh Stage 9's expected-violation
///   witness keep that exemption exercised, not dead.
///
///   AUTHORING (PR 2 — author/environment churn above the released
///   pipeline; measure may CLIMB or stay flat; each member is bounded by
///   name):
///     job-arrived      (+ the fresh Draft's whole jobMeasure: a job enters
///                       the fleet. Bounded by construction: ids are dense,
///                       never reused, and capped by the N_JOBS arrival
///                       bound — at most N_JOBS arrivals ever. PR 3: the
///                       arrival also fixes the job's eval PROGRAM, but a
///                       Draft's stage digit is 0, so the climb bound is
///                       unchanged.)
///     job-unfrozen     (+rankWeight: Frozen->Draft, the v1 table's edit
///                       loop — table.qnt line 24 `(Frozen, Draft)`. The
///                       table has NO Draft->Draft row: content edits are
///                       below the phase table's grain, so this unfreeze
///                       edge IS the modeled authoring loop. Bounded only
///                       by author behavior — see the conditionality note
///                       below.)
///     job-revoked, desk-only (= 0: revoking an already-parked job —
///                       Escalated/Stalled are rank 0, so nothing falls
///                       when no dependent gets parked by the cascade.
///                       Bounded: PRevoked is absorbing, so each such step
///                       permanently settles one job — at most N_JOBS
///                       ever.)
///
/// PER-JOB LIVENESS, SKETCHED — CONDITIONAL ON AUTHORS (roadmap PR 1 gate,
/// extended by PR 2; PR 3 changes the digits, not the argument): jobMeasure
/// is a nonnegative integer, every non-STUTTER non-CHURN non-AUTHORING step
/// strictly decreases the sum of jobMeasure over all jobs, each CHURN step
/// requires an operator acting on a desk-visible job (domain.qnt
/// `deskVisibility`), and each AUTHORING step is an author acting on their
/// own Draft/Frozen job (or the bounded arrival/settlement members above).
/// So under default metering, any run with finitely many stutter and churn
/// events IN WHICH EVERY AUTHOR EVENTUALLY STOPS EDITING — each
/// Draft/Frozen job is eventually released or revoked, and the unfreeze
/// loop is not taken forever — parks every job in Done, Escalated, Stalled,
/// or Revoked. The conditionality is exact and deliberate: a job an author
/// never freezes is a job the system owes nothing for (this mirrors the
/// charter §4 quiescence conditionality — the system cannot promise
/// termination while the environment keeps acting). The unconditional
/// system-quiescence theorem is charter §4's contested half and is NOT
/// claimed here.
module chuggy_measure {

  // === Vocabulary ==========================================================
  // Sum-type constructors share one namespace per module, hence the
  // prefixes (P/T/TK/V/R/Rs/C/Land). The two-branch parameter types keep
  // bare descriptive constructor names — Budgeted/DeadlineOnly (GatePricing)
  // and RetryCharged/RetryFree (RetryPricing) — documented here because
  // they live in the same module-wide constructor namespace. PR 3 adds the
  // TK prefix (TaskKind) and TCancelled (TaskOutcome); `Stage` is a record
  // type, not a constructor, so it costs the namespace nothing.

  /// STORED job phases. Deliberately few (charter standing rule 3, derive
  /// don't store): Blocked and Ready are PREDICATES over deps + record in
  /// domain.qnt, not phases — a job that has not started is PPending, and
  /// the waiting-room split is derived. PPending must be stored (phase is
  /// total and "never started" is not expressible as a predicate over the
  /// other fields without overloading them). PWorking/PEvaluating carry the
  /// parallel task set; PLanding is its own phase because its outcome is
  /// the exclusivity boundary (charter §2, effect-only exclusivity); PDone
  /// is absorbing; PEscalated/PStalled are the human desk.
  ///
  /// PR 2 (authoring, charter §2 first-class rank #1) added the phases ABOVE
  /// the released pipeline and the settled terminal, vocabulary transcribed
  /// from v1's transition table (specs/chuggernaut/table.qnt, itself
  /// verbatim from chuggernaut state.rs):
  ///   - PDraft/PFrozen: the authoring pair — table lines 21-26 give
  ///     Draft -> {Ready|Blocked|Frozen}, Frozen -> Draft (the edit loop),
  ///     Frozen -> {Ready|Blocked}; Ready/Blocked stay derived from
  ///     PPending exactly as in PR 1.
  ///   - PRevoked: the OTHER settled terminal — table lines 45-48: every
  ///     non-terminal state may go to Revoked, Done and Revoked are
  ///     absorbing. PRevoked is absorbing, runs nothing, never lands, and
  ///     opens NO human task (revocation is the author's settled choice —
  ///     see hasOpenHumanTask).
  ///   - Batched (table lines 27-30) is deliberately NOT transcribed:
  ///     deferred to PR 5 with the merge queue it belongs to
  ///     (specs/chuggy/README.md, deliberately-absent table).
  /// PR 3 deliberately adds NO phase: a stage advance is an
  /// Evaluating -> Evaluating edge, exactly chuggernaut's own state table
  /// (spec.md §2.1 line 832: `Evaluation | Evaluation | a stage completes
  /// ... and a later stage remains`) — within-phase progress lives in the
  /// stage digit, not in new phases.
  type Phase =
    PDraft | PFrozen |
    PPending | PWorking | PEvaluating | PLanding |
    PDone | PEscalated | PStalled | PRevoked

  /// What a task IS for (PR 3, task-records depth — charter §2 job anatomy:
  /// "task records are first-class (they carry the anatomy)"):
  ///   TKWork     — a task of the Work phase's single task set (Work stays
  ///                ONE task-set phase per kasofsk's anatomy note; the
  ///                extracted vocabulary agrees — chuggernaut spec.md §1.2
  ///                task creation: "Job enters Work (new cycle): one work
  ///                task", i.e. Work is not staged).
  ///   TKEval(s)  — a task of eval stage s (0-based index into the job's
  ///                authored program — chuggernaut spec.md §1.1 evaluator
  ///                `stage:`, "default 0; non-negative; evaluators run in
  ///                ascending stage order; within a stage they fan out in
  ///                parallel"). The kind mark is what makes the CURRENT
  ///                stage derivable from the live task set (evalStage
  ///                below) instead of stored — standing rule 3.
  type TaskKind = TKWork | TKEval(int)

  /// A first-class task record (charter §2 job anatomy). PR 3 grows the
  /// anatomy exactly as the roadmap row promised: identity + kind +
  /// outcome. `id` is SEQUENTIAL WITHIN THE JOB, 1-indexed, across the
  /// job's entire history — chuggernaut spec.md §1.2 (`id: u64, sequential
  /// within job, 1-indexed`) — never reused across stages, cycles, or
  /// operator retries. That uniqueness is load-bearing: it is what lets a
  /// stale completion from an earlier stage/incarnation be absorbed BY
  /// IDENTITY (see the STUTTER note in the header). Deliberately NOT
  /// carried from chuggernaut's Task: `attempt` and the per-task retry
  /// budgets (below-cycle machinery, charter §2 non-goal), `cycle`
  /// (derivable from the record's kind sequence — work groups delimit
  /// cycles), timestamps/results (implementation accounting, not machine
  /// state).
  type Task = { id: int, kind: TaskKind, outcome: TaskOutcome }

  /// A task's stored outcome. TFailed covers BOTH a failed verdict and
  /// evaluator-infrastructure death: "the job pays" for evaluator crashes —
  /// one account, no new machinery (charter §2 eval/evaluator-failure).
  /// TCancelled (PR 3) is the retirement mark for a task still RUNNING when
  /// its job is revoked mid-flight — the model's lean form of chuggernaut
  /// spec.md §1.2 "Revoke closes tasks" (revoke force-closes every pending
  /// task with a synthetic resolution recording that the revoke, not a
  /// verdict, retired it). Only revoke produces it: every other retirement
  /// happens at a reduce, when the set is fully resolved.
  type TaskOutcome = TRunning | TPassed | TFailed | TCancelled

  /// A task-completion event's verdict (the event, as distinct from the
  /// stored outcome — duplicates of the event must be tolerated).
  type Verdict = VPass | VFail

  /// Verdict combinator over a resolved task set. PR 3: no longer a
  /// machine-wide parameter — each STAGE of a job's authored program
  /// carries its own (eval is data, charter §2); the charter's default,
  /// unanimous pass, is the default program's combinator
  /// (domain.qnt defaultProgram). CUnanimousPass is chuggernaut's
  /// required-evaluator rule ("if every required evaluator in the stage
  /// passed", spec.md §3.3) at chuggy's grain — the required/advisory split
  /// is BELOW that grain (an advisory evaluator is one the stage's
  /// combinator ignores), README notes the abstraction.
  type Combinator = CUnanimousPass | CAnyPass

  /// One stage of a job's eval program (PR 3): a task-set with its own
  /// fan-out width and its own verdict combinator. Extracted from
  /// chuggernaut spec.md §3.3: "the dispatcher creates one task per
  /// evaluator in the lowest stage and fans them out in parallel" — a
  /// stage's width is its evaluator count, its combinator is the
  /// required-pass rule. `fanout` is chuggernaut's own word.
  type Stage = { fanout: int, combinator: Combinator }

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
  /// RsDependencyRevoked (PR 2) is the cascade wall — chuggy-NEW, not v1
  /// vocabulary: v1 never modeled revoke fan-out at all (model-status §6b:
  /// "revoke fan-out cascade" is listed unanswerable). It names why a job
  /// transitively doomed by a revoked dependency is parked on the desk with
  /// its OWN open task — the coverage the charter §2 visibility row demands,
  /// since PRevoked itself opens no task.
  /// PR 3 adds NO wall: a failed stage short-circuits into the EXISTING
  /// rework/escalation economy (the eval walls above) — same accounts, same
  /// names.
  type Reason =
    RsNone | RsWorkFailed | RsReworkBudgetExhausted |
    RsGateBudgetExhausted | RsDeadlineExceeded | RsRevalidationFailed |
    RsDependencyRevoked

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
    // PR 3: THE EVAL PROGRAM — an ordered list of stages, AUTHORED: it
    // arrives with the Draft (which is exactly why authoring came first,
    // first-class order charter §2) and is immutable after arrival, like
    // deps. This is the charter's "eval is data, not machinery" made
    // literal: the program is data on the job record; domain.qnt's
    // decideEvalStageReduce is the interpreter. Well-formedness (non-empty,
    // length <= MAX_STAGES, every fanout in 1..N_TASKS) is an ARRIVAL
    // validity condition — domain.qnt programsWellFormed.
    program: List[Stage],
    // The LIVE task set of the current Working phase or Evaluating stage;
    // empty in every other phase. Task ids are sequential within the job
    // across its whole history (nextTaskId below).
    tasks: Set[Task],
    // PR 3: THE RETAINED TASK RECORD — the job's chronological task log
    // (chuggernaut spec.md §1.2: "tasks form a chronological log ... never
    // referencing each other; no task graph"), append-only: a task moves
    // here, outcome settled, when its set retires (reduce, escalation, or
    // revoke — retireLive below), and once here it NEVER changes
    // (domain.qnt recordMonotone). This is "task records are first-class:
    // they carry the anatomy" (charter §2) — outcomes are retained history
    // the golden traces can carry as provenance, not overwritten scratch
    // state. Entry i has id i+1 (ids sequential, retirement in id order).
    // NOT a measure input (append-only: it could only climb). GROWTH
    // BOUND: under RetryCharged every spawn burst rides a charged gas
    // unit, so record length <= DEADLINE * (nTasks + maxStages * nTasks);
    // under RetryFree it is unbounded across free-resume churn — the same
    // conditionality as the liveness sketch below.
    record: List[Task],
    // GHOST (PR 3, accounting only — NOT a measure input, exactly like
    // record; jobMeasure never reads it): how many tasks this job has EVER
    // spawned. Every spawn site bumps it by its fan-out (spawnOn below),
    // so the machine invariant `spawned == record.length + tasks.size`
    // (domain.qnt idsAccounted) makes history-unique sequential identity a
    // checked theorem rather than a test-pinned convention: a decider that
    // DROPPED a task set instead of retiring it would break the equality
    // in the very next state.
    spawned: int,
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
    // FIRST-CLASS stored trace vocabulary, not derived from phase — and PR 2
    // delivered the anticipated breakage: a PStalled job now carries either
    // RsRevalidationFailed (pre-work churn, retryable) or
    // RsDependencyRevoked (cascade wall, NOT retryable — domain.qnt
    // stallRetryableIn), which no phase predicate can distinguish.
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
  ///
  /// PRevoked is deliberately NOT here (PR 2): revocation is the author's
  /// settled choice — the desk owes a revoked job nothing, exactly like
  /// PDone. This is precisely why the revoke cascade needs its own
  /// coverage: a dependent stuck behind a Revoked dep gets no visibility
  /// through its dep, so the cascade parks it with a task of its OWN
  /// (RsDependencyRevoked; domain.qnt `cascadeSafety`).
  pure def hasOpenHumanTask(job: Job): bool =
    job.phase == PEscalated or job.phase == PStalled

  /// The machine's observed state, as the pure deciders see it. A record
  /// (not a bare map) so the job-source shape stays open. PR 2 attached
  /// authoring here with no widening needed after all — jobs ARRIVE by
  /// growing the map's (dense, never-reused) id domain through the
  /// `freshJob` seam, and no PR 1 decider needed surgery; the record shape
  /// stays open for later PRs. PR 3 widened only the Job record (program,
  /// record, task kinds), not Core.
  type Core = { jobs: int -> Job }

  /// One observed job-phase transition, golden-trace shaped (standing rule
  /// 4: conformance from day one — the model emits, the implementation
  /// replays). PR 3: from == to is a REAL row, not a degenerate one — the
  /// stage advance is Evaluating -> Evaluating (chuggernaut spec.md §2.1
  /// line 832).
  type Transition = { job: int, from: Phase, to: Phase }

  /// One decision's observable record, mirroring the golden-trace step
  /// schema {event, transitions, effects}.
  type StepRecord = { label: str, transitions: List[Transition], effects: List[str] }

  /// What a pure decider returns: record performed + post-state.
  type Decision = { rec: StepRecord, post: Core }

  /// The bounds the measure is parameterized by — passed explicitly so this
  /// module needs no consts and the measure stays a pure function usable
  /// from tests with any bounds. PR 3 adds maxStages: the authored-program
  /// length cap (domain.qnt MAX_STAGES) — the stage digit's radix.
  type Bounds = {
    reworkBudget: int,
    nTasks: int,
    maxStages: int,
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

  /// How far from settled a job's lifecycle position is. The authoring
  /// phases (PR 2) sit ABOVE the released pipeline so freeze (6->5) and
  /// release (6->4, 5->4) strictly descend; the wildcard is the settled
  /// tier: PDone, PEscalated, PStalled, and (PR 2) PRevoked all rank 0 —
  /// revoke drops any live rank straight to settled.
  pure def phaseRank(p: Phase): int =
    match p {
      | PDraft => 6
      | PFrozen => 5
      | PPending => 4
      | PWorking => 3
      | PEvaluating => 2
      | PLanding => 1
      | _ => 0
    }

  pure def runningCount(tasks: Set[Task]): int =
    tasks.filter(t => t.outcome == TRunning).size()

  /// The CURRENT eval stage, DERIVED from the live task set's kind marks
  /// (standing rule 3: no stored stage index) — meaningful only while the
  /// set is a stage's fan-out (PEvaluating; tasksWellFormed pins the set
  /// uniformly TKEval(s), so the fold's pick order is irrelevant). 0 on an
  /// empty or work set.
  pure def evalStage(tasks: Set[Task]): int =
    tasks.fold(0, (acc, t) => match t.kind { | TKWork => acc | TKEval(s) => s })

  /// The stage digit: how many stages of the authored program have not yet
  /// passed — L - s while Evaluating stage s (so in 1..L there), 0 in every
  /// other phase (the digit APPEARS on work-passed and VANISHES on every
  /// exit, both dominated per the header's digit-order argument).
  pure def stagesLeft(job: Job): int =
    if (job.phase == PEvaluating) job.program.length() - evalStage(job.tasks)
    else 0

  /// Weight of one unit of stage progress: strictly dominates the
  /// running-task count (<= nTasks) — the ABOVE-the-count half of the PR 3
  /// digit-order argument.
  pure def stageWeight(b: Bounds): int = b.nTasks + 1

  /// Weight of one unit of phase rank: strictly dominates the full stage
  /// digit plus any running count (stagesLeft <= maxStages, count <=
  /// nTasks < stageWeight) — the BELOW-rank half of the argument.
  /// CHANGED by PR 3 (was nTasks + 1): the stage radix now sits inside.
  pure def rankWeight(b: Bounds): int = (b.maxStages + 1) * stageWeight(b)

  /// Strict upper bound on micro. The rank ceiling is still 6 (PDraft,
  /// PR 2), so micro <= 6*rankWeight + (rankWeight - 1) < 7*rankWeight —
  /// the multiplier is unchanged; the widened rankWeight under it carries
  /// PR 3's stage digit.
  pure def microBound(b: Bounds): int = 7 * rankWeight(b)

  /// Within-cycle progress, lexicographic (rank, stagesLeft, runningCount).
  pure def micro(b: Bounds, job: Job): int =
    phaseRank(job.phase) * rankWeight(b)
      + stagesLeft(job) * stageWeight(b)
      + runningCount(job.tasks)

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

  /// A fresh parallel task set of kind k: n tasks, all running, ids
  /// start..start+n-1 — the caller passes nextTaskId so identity stays
  /// sequential within the job across the whole history (chuggernaut
  /// spec.md §1.2). Replaces PR 1's freshTasks, whose per-spawn ids 1..n
  /// conflated incarnations.
  pure def spawnTasks(k: TaskKind, start: int, n: int): Set[Task] =
    start.to(start + n - 1).map(i => { id: i, kind: k, outcome: TRunning })

  /// The next task id this job would spawn: every id ever issued is either
  /// retired (record) or live (tasks), and ids are dense from 1.
  pure def nextTaskId(job: Job): int =
    job.record.length() + job.tasks.size() + 1

  /// THE spawn site (PR 3): install a fresh fan-out of kind k on the job —
  /// ids continue the job's sequential history — and bump the ghost
  /// `spawned` counter by the same n, which is what keeps the idsAccounted
  /// equality (domain.qnt) checkable. Callers guarantee the previous set
  /// is already retired (tasks empty), which every spawn site satisfies:
  /// dispatch/land-rework/opRetry spawn from task-free phases, and the
  /// reduces spawn on the retireLive'd job.
  pure def spawnOn(job: Job, k: TaskKind, n: int): Job =
    { ...job, tasks: spawnTasks(k, nextTaskId(job), n), spawned: job.spawned + n }

  /// Retire the live task set into the retained record, in id order
  /// (tasksWellFormed keeps live ids contiguous above the record, so the
  /// appended run keeps record entry i at id i+1). A task still RUNNING at
  /// retirement is force-closed as TCancelled — only revoke retires
  /// mid-flight sets (chuggernaut spec.md §1.2 "Revoke closes tasks");
  /// every reduce/escalation retirement is of a fully-resolved set, so the
  /// TCancelled arm never fires there.
  pure def retireLive(job: Job): Job =
    val start = job.record.length() + 1
    { ...job,
      tasks: Set(),
      record: range(start, start + job.tasks.size()).foldl(job.record, (r, i) =>
        r.append(job.tasks.fold({ id: i, kind: TKWork, outcome: TCancelled }, (acc, t) =>
          if (t.id == i)
            { ...t, outcome: if (t.outcome == TRunning) TCancelled else t.outcome }
          else acc))) }

  /// First write wins: resolve task `tid` if it is still running; the
  /// caller (decideTaskDone) treats an already-resolved task as a duplicate
  /// delivery and changes nothing — the idempotence the dropped
  /// no-double-pods axiom demands (charter §2 fabric row).
  pure def resolveTask(tasks: Set[Task], tid: int, out: TaskOutcome): Set[Task] =
    tasks.map(t => if (t.id == tid and t.outcome == TRunning) { ...t, outcome: out } else t)

  /// The verdict combinator, interpreted per stage (PR 3: the caller reads
  /// it off the job's program — eval is data, this is the interpreter's
  /// leaf). Callers guarantee all tasks are resolved. CUnanimousPass is
  /// chuggernaut's "every required evaluator in the stage passed" (spec.md
  /// §3.3) at this grain; TCancelled and TFailed both fail it.
  pure def combine(c: Combinator, tasks: Set[Task]): bool =
    match c {
      | CUnanimousPass => tasks.forall(t => t.outcome == TPassed)
      | CAnyPass => tasks.exists(t => t.outcome == TPassed)
    }
}
