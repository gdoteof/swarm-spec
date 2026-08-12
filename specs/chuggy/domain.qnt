/// The chuggy core domain machine (chuggy-charter.md §6, roadmap PR 1) —
/// written AFTER and fitted TO measure.qnt (standing rule 1). This is the
/// layer both §4 fork candidates share: every decider is a pure function of
/// observed state (`Core`), so a CRD reconciler and a journaled actor reuse
/// them unchanged; the refinement layer (reconcile vs journaled-actor
/// semantics) is deliberately absent, blocked on the §4 conversation.
///
/// What is deliberately NOT here (and which roadmap PR restores it):
///   - authoring lifecycle (PR 2) — init's nondet DAG is the placeholder
///     job source, funneled through `freshJob` so authoring attaches there;
///   - task anatomy depth / real eval programs (PR 3);
///   - multi-repo (PR 4); merge-queue + landing mechanics (PR 5);
///   - scheduler/capacity: NO agent-slot count, NO FIFO ready queue —
///     charter §2 non-goals (no bespoke scheduler) plus the trusted fabric
///     axioms (quota/scheduling): dispatch is a nondet pick among Ready
///     jobs, K8s owns the rest;
///   - below-cycle retry machinery: NO attempt counter, NO work-retries
///     wall — charter §2 non-goals ("no retry machinery below the cycle");
///     container relaunches are the trusted `backoffLimit` fabric axiom,
///     so a Work task-set resolves at CYCLE level only;
///   - environment quiescence (v1's envActive/quiesce): the quiescence
///     theorem is §4's contested half — per-job liveness only, sketched via
///     measure descent.
module chuggy_domain {
  import chuggy_measure.* from "./measure"

  /// Number of jobs in the graph (ids 1..N_JOBS).
  const N_JOBS: int
  /// Discrete tasks spawned per Working/Evaluating phase (charter §2 job
  /// anatomy: a SET of possibly-parallel tasks; uniform size until PR 3).
  const N_TASKS: int
  /// Budgeted eval-failure reworks.
  const REWORK_BUDGET: int
  /// Deadline gas per job. REQUIRED >= 1: a graph without a deadline is
  /// invalid (charter §2 economy/deadline) — init admits no state otherwise.
  const DEADLINE: int
  /// Gate-rework pricing (charter §2: a parameter, not a constant; both
  /// branches instantiated in mc/mc_chuggy.qnt).
  const GATE_PRICING: GatePricing
  /// Operator-retry metering (charter §2: configurable per deployment,
  /// default charge — mc instantiates RetryCharged, plus a RetryFree
  /// instance so the free-resume churn path stays exercised).
  const OP_RETRY_PRICING: RetryPricing
  /// Eval verdict combinator (charter §2: default unanimous pass — mc
  /// instantiates CUnanimousPass).
  const EVAL_COMBINATOR: Combinator

  pure val allJobs: Set[int] = 1.to(N_JOBS)

  /// The measure's bounds, from this instance's consts.
  pure val bounds: Bounds = {
    reworkBudget: REWORK_BUDGET,
    nTasks: N_TASKS,
    gatePricing: GATE_PRICING
  }

  /// The job-source seam (kept open for PR 2): every job the machine ever
  /// holds is built here. Authoring will replace init's nondet DAG with its
  /// lifecycle and still construct through this.
  pure def freshJob(deps_: Set[int]): Job = {
    phase: PPending,
    deps: deps_,
    tasks: Set(),
    reworkLeft: REWORK_BUDGET,
    gateLeft: gateBudget(GATE_PRICING),
    deadlineLeft: DEADLINE,
    resumeAt: RNone,
    reason: RsNone,
    landings: 0
  }

  // ==========================================================================
  // === Pure deciders ========================================================
  // ==========================================================================
  // v1's discipline (chug_decide): decide(view, event) -> Decision, never an
  // effect. Both §4 shapes reuse these unchanged.

  pure def withJob(c: Core, j: int, jb: Job): Core =
    { ...c, jobs: c.jobs.set(j, jb) }

  /// The one funnel every phase flip goes through, recording exactly one
  /// transition (golden-trace shaped, standing rule 4).
  pure def move(c: Core, j: int, to_: Phase, label: str, effects_: List[str]): Decision =
    { rec: {
        label: label,
        transitions: [{ job: j, from: c.jobs.get(j).phase, to: to_ }],
        effects: effects_ },
      post: withJob(c, j, { ...c.jobs.get(j), phase: to_ }) }

  /// A decision that changes nothing — the idempotent answer to duplicate
  /// deliveries (at-least-once fabric, charter §2: no-double-pods dropped,
  /// every effect idempotent).
  pure def noop(c: Core, label: str): Decision =
    { rec: { label: label, transitions: [], effects: [] }, post: c }

  /// Park a job on the human desk, naming the wall (vocabulary carried
  /// from v1; the charter §2 termination row commits the terminal, not the
  /// names) and where Retry resumes. The open desk task is DERIVED from
  /// the phase (hasOpenHumanTask, standing rule 3); "OpenHumanTask" is its
  /// trace-visible effect.
  pure def escalate(c: Core, j: int, at: Resume, why: Reason, label: str): Decision =
    move(
      withJob(c, j, { ...c.jobs.get(j), tasks: Set(), resumeAt: at, reason: why }),
      j, PEscalated, label, ["OpenHumanTask"])

  /// Ready -> Working: launch a cycle. Charges one deadline gas — EVERY
  /// entry to Working does (standing rule 2: no free re-entry; the deadline
  /// is the account that makes the graph valid at all).
  pure def decideDispatch(c: Core, j: int): Decision =
    move(
      withJob(c, j, { ...c.jobs.get(j),
        tasks: freshTasks(N_TASKS),
        deadlineLeft: c.jobs.get(j).deadlineLeft - 1 }),
      j, PWorking, "dispatch", ["SpawnWorkTasks"])

  /// A task-completion event for task `tid` of job j (Working or
  /// Evaluating — one decider for both phases' task sets). First write
  /// wins: if the task already resolved, this is a duplicate delivery and
  /// the decision is a state-identical no-op (STUTTER set in measure.qnt).
  /// No phase transition either way — task records resolve inside the
  /// phase.
  pure def decideTaskDone(c: Core, j: int, tid: int, v: Verdict): Decision =
    if (c.jobs.get(j).tasks.exists(t => t.id == tid and t.outcome == TRunning))
      { rec: { label: "task-done", transitions: [], effects: [] },
        post: withJob(c, j, { ...c.jobs.get(j),
          tasks: resolveTask(c.jobs.get(j).tasks, tid,
            match v { | VPass => TPassed | VFail => TFailed }) }) }
    else
      noop(c, "task-done-duplicate")

  /// The Working task set fully resolved: reduce the phase, at CYCLE level
  /// only. Work reduces under unanimous pass, hardcoded until PR 3 pins
  /// phase-outcome combinators from a real eval/vocabulary example (charter
  /// §3) — the parameterized combinator is eval's. A failed task set is a
  /// failed CYCLE and escalates directly: the fabric has already retried
  /// each task below the cycle (trusted `backoffLimit`, charter §2 fabric
  /// row), and modeling attempts of our own is a §2 non-goal ("no retry
  /// machinery below the cycle").
  pure def decideWorkReduce(c: Core, j: int): Decision =
    if (c.jobs.get(j).tasks.forall(t => t.outcome == TPassed))
      move(
        withJob(c, j, { ...c.jobs.get(j), tasks: freshTasks(N_TASKS) }),
        j, PEvaluating, "work-passed", ["SpawnEvalTasks"])
    else
      escalate(c, j, RWorking, RsWorkFailed, "job-escalated work_failed")

  /// The Evaluating task set fully resolved: apply the eval combinator
  /// (charter §2: eval is data; unanimous pass is the instantiated
  /// default). A failed verdict — including evaluator-infrastructure death,
  /// folded into TFailed because THE JOB PAYS from the same account, no new
  /// machinery (charter §2 eval/evaluator-failure) — buys a budgeted rework
  /// cycle: 1 reworkLeft + 1 gas. Budget wall checked before the deadline
  /// wall (v1 convention).
  pure def decideEvalReduce(c: Core, j: int): Decision =
    if (combine(EVAL_COMBINATOR, c.jobs.get(j).tasks))
      move(
        withJob(c, j, { ...c.jobs.get(j), tasks: Set() }),
        j, PLanding, "eval-passed", ["EnqueueLanding"])
    else if (c.jobs.get(j).reworkLeft > 0 and c.jobs.get(j).deadlineLeft > 0)
      move(
        withJob(c, j, { ...c.jobs.get(j),
          reworkLeft: c.jobs.get(j).reworkLeft - 1,
          deadlineLeft: c.jobs.get(j).deadlineLeft - 1,
          tasks: freshTasks(N_TASKS) }),
        j, PWorking, "rework-started eval_failure", ["SpawnWorkTasks"])
    else if (c.jobs.get(j).reworkLeft == 0)
      escalate(c, j, REvaluating, RsReworkBudgetExhausted,
        "job-escalated rework_budget_exhausted")
    else
      escalate(c, j, REvaluating, RsDeadlineExceeded,
        "job-escalated job_deadline_exceeded")

  /// The landing resolves. Mechanics abstract (charter §2 landing row,
  /// deferred to PR 5) but OUTCOMES precisely named from day one: the two
  /// success effects AdvanceDefault and SquashMerge are distinct — v1's one
  /// conformance divergence lived exactly here. A landing success is the
  /// job's single landing effect (ghost `landings` counts it — the
  /// effect-exclusivity boundary). A landing failure re-enters work priced
  /// per GATE_PRICING: Budgeted(n) spends gate budget AND gas, DeadlineOnly
  /// spends gas alone (v1's shape); either wall parks the job with its own
  /// name.
  pure def decideLand(c: Core, j: int, out: LandOutcome): Decision =
    match out {
      | LandAdvanceDefault =>
        move(
          withJob(c, j, { ...c.jobs.get(j), landings: c.jobs.get(j).landings + 1 }),
          j, PDone, "job-done", ["AdvanceDefault"])
      | LandSquashMerge =>
        move(
          withJob(c, j, { ...c.jobs.get(j), landings: c.jobs.get(j).landings + 1 }),
          j, PDone, "job-done", ["SquashMerge"])
      | LandFailed =>
        match GATE_PRICING {
          | Budgeted(_) =>
            if (c.jobs.get(j).gateLeft > 0 and c.jobs.get(j).deadlineLeft > 0)
              move(
                withJob(c, j, { ...c.jobs.get(j),
                  gateLeft: c.jobs.get(j).gateLeft - 1,
                  deadlineLeft: c.jobs.get(j).deadlineLeft - 1,
                  tasks: freshTasks(N_TASKS) }),
                j, PWorking, "rework-started gate_failure", ["SpawnWorkTasks"])
            else if (c.jobs.get(j).gateLeft == 0)
              escalate(c, j, RLanding, RsGateBudgetExhausted,
                "job-escalated gate_budget_exhausted")
            else
              escalate(c, j, RLanding, RsDeadlineExceeded,
                "job-escalated job_deadline_exceeded")
          | DeadlineOnly =>
            if (c.jobs.get(j).deadlineLeft > 0)
              move(
                withJob(c, j, { ...c.jobs.get(j),
                  deadlineLeft: c.jobs.get(j).deadlineLeft - 1,
                  tasks: freshTasks(N_TASKS) }),
                j, PWorking, "rework-started gate_failure", ["SpawnWorkTasks"])
            else
              escalate(c, j, RLanding, RsDeadlineExceeded,
                "job-escalated job_deadline_exceeded")
        }
    }

  /// A duplicate landing event for an already-Done job (at-least-once: a
  /// stale executor re-delivers). NO landing effect is emitted — this
  /// no-op IS the exactly-once-at-the-landing-boundary claim; the
  /// landingExclusive invariant checks it (charter §2 exclusivity +
  /// fabric rows).
  pure def decideLandDuplicate(c: Core, j: int): Decision =
    noop(c, "land-duplicate")

  /// Ready -> Stalled: the world changed under a job before it ever ran
  /// (static config no longer valid). Free — nothing was spent — and the
  /// desk opens. Minimal entry edge for the Stalled terminal the §2
  /// termination row commits to; richer stall causes arrive with authoring
  /// (PR 2).
  pure def decideRevalFail(c: Core, j: int): Decision =
    move(
      withJob(c, j, { ...c.jobs.get(j), reason: RsRevalidationFailed }),
      j, PStalled, "job-stalled revalidation_failed", ["OpenHumanTask"])

  /// Operator Retry on an escalation: resume at the phase that failed,
  /// metered per OP_RETRY_PRICING (charter §2: configurable, default
  /// charge). RetryCharged: EVERY resume costs 1 gas — the v1 lesson
  /// (model-status §5b: free resumes defeat the deadline) priced in.
  /// RetryFree: only the Working resume pays (entry to Working always
  /// meters — standing rule 2); Evaluating/Landing resumes are the CHURN
  /// set in measure.qnt, v1's livelock kept reproducible by configuration.
  pure def decideOpRetry(c: Core, j: int): Decision =
    val charge = match OP_RETRY_PRICING {
      | RetryCharged => 1
      | RetryFree => if (c.jobs.get(j).resumeAt == RWorking) 1 else 0
    }
    val resumed = { ...c.jobs.get(j),
      reason: RsNone, resumeAt: RNone,
      deadlineLeft: c.jobs.get(j).deadlineLeft - charge }
    match c.jobs.get(j).resumeAt {
      | RWorking =>
        move(withJob(c, j, { ...resumed, tasks: freshTasks(N_TASKS) }),
          j, PWorking, "operator-retry", ["SpawnWorkTasks"])
      | REvaluating =>
        move(withJob(c, j, { ...resumed, tasks: freshTasks(N_TASKS) }),
          j, PEvaluating, "operator-retry", ["SpawnEvalTasks"])
      | RLanding =>
        move(withJob(c, j, resumed), j, PLanding, "operator-retry", ["EnqueueLanding"])
      | RNone =>
        // Unreachable: every escalation stamps a real resume point.
        noop(c, "operator-retry-unreachable")
    }

  /// Operator Retry on a pre-work stall: back to Pending (Blocked/Ready
  /// re-derive). Free — nothing was ever spent, and the Working boundary
  /// still meters any actual re-entry (standing rule 2). CHURN set in the
  /// measure.
  pure def decideStalledRetry(c: Core, j: int): Decision =
    move(
      withJob(c, j, { ...c.jobs.get(j), reason: RsNone }),
      j, PPending, "stalled-retry", [])

  // ==========================================================================
  // === State + actions ======================================================
  // ==========================================================================

  var jobs: int -> Job
  /// The last decision's StepRecord — the golden-trace-shaped observation
  /// (standing rule 4: the model emits golden traces from day one).
  var lastStep: StepRecord
  /// GHOST: sysMeasure of the PREVIOUS state, written by every action, read
  /// only by stepDescends.
  var prevMeasure: int

  val core: Core = { jobs: jobs }
  val currentMeasure: int = sysMeasure(bounds, jobs)

  action apply(d: Decision): bool = all {
    jobs' = d.post.jobs,
    lastStep' = d.rec,
    prevMeasure' = currentMeasure
  }

  // --- Derived waiting room (standing rule 3: derive, don't store) ---------
  // Blocked and Ready are PREDICATES over deps + record, not phases. v1
  // stored both; chuggy stores only PPending and derives the split, so the
  // unblock cascade disappears entirely — there is no Blocked->Ready edge
  // to model or to get wrong. (The open-human-task flag is derived too:
  // measure.qnt hasOpenHumanTask.)

  def depsDone(j: int): bool =
    jobs.get(j).deps.forall(k => jobs.get(k).phase == PDone)

  def isReady(j: int): bool =
    jobs.get(j).phase == PPending and depsDone(j)

  def isBlocked(j: int): bool =
    jobs.get(j).phase == PPending and not(depsDone(j))

  // --- Enablement sets ------------------------------------------------------

  val readyJobs: Set[int] = allJobs.filter(j => isReady(j))
  /// Jobs whose task set can receive completion events (real or duplicate).
  val taskPhaseJobs: Set[int] =
    allJobs.filter(j => jobs.get(j).phase == PWorking or jobs.get(j).phase == PEvaluating)
  val reducibleWork: Set[int] =
    allJobs.filter(j => jobs.get(j).phase == PWorking and runningCount(jobs.get(j).tasks) == 0)
  val reducibleEval: Set[int] =
    allJobs.filter(j => jobs.get(j).phase == PEvaluating and runningCount(jobs.get(j).tasks) == 0)
  val landingJobs: Set[int] = allJobs.filter(j => jobs.get(j).phase == PLanding)
  val doneJobs: Set[int] = allJobs.filter(j => jobs.get(j).phase == PDone)
  val stalledJobs: Set[int] = allJobs.filter(j => jobs.get(j).phase == PStalled)

  /// May the operator Retry this escalation? Under RetryCharged every
  /// resume charges gas, so zero gas parks the job permanently (v1's
  /// retryableEscalated corner, now for all resume points); under RetryFree
  /// only the Working resume needs gas.
  def retryable(j: int): bool =
    jobs.get(j).phase == PEscalated and
    match OP_RETRY_PRICING {
      | RetryCharged => jobs.get(j).deadlineLeft > 0
      | RetryFree => jobs.get(j).resumeAt == RWorking implies jobs.get(j).deadlineLeft > 0
    }

  val retryableEscalated: Set[int] = allJobs.filter(j => retryable(j))

  /// No machine or operator action can move any job: every job is Done,
  /// unretryably Escalated, or Pending behind a chain that can never reach
  /// Done. The `settled` stutter covers exactly this dead end so runs never
  /// deadlock (Stalled and retryable-Escalated jobs keep their operator
  /// actions enabled, so they are NOT quiet).
  val quiet: bool = allJobs.forall(j => or {
    jobs.get(j).phase == PDone,
    jobs.get(j).phase == PEscalated and not(retryable(j)),
    isBlocked(j)
  })

  // --- init -----------------------------------------------------------------

  /// Nondet acyclic DAG exactly as v1: deps filtered to strictly smaller
  /// ids. All jobs start PPending — Ready/Blocked are derived, so unlike v1
  /// there is no seeded ready queue and no stored waiting-room state.
  /// The `DEADLINE >= 1` conjunct is the charter's REQUIRED-deadline row as
  /// a validity condition: an instantiation without a deadline has NO
  /// initial state — the graph is invalid, not merely unmetered.
  action init =
    nondet depsChoice = allJobs.setOfMaps(allJobs.powerset()).oneOf()
    val depsOf = allJobs.mapBy(j => depsChoice.get(j).filter(k => k < j))
    all {
      DEADLINE >= 1,       // charter §2 economy/deadline: required field
      N_TASKS >= 1,        // well-formedness: a phase carries a real task set
      REWORK_BUDGET >= 0,
      gateBudget(GATE_PRICING) >= 0,
      jobs' = allJobs.mapBy(j => freshJob(depsOf.get(j))),
      lastStep' = { label: "init", transitions: [], effects: [] },
      prevMeasure' = 0
    }

  // --- actions --------------------------------------------------------------

  /// Ready -> Working: nondet pick — scheduling/quota is trusted fabric
  /// (charter §2 non-goals: no bespoke scheduler), so there is no slot
  /// count and no queue order. Pending jobs have never spent gas, so gas
  /// >= 1 here whenever init accepted the graph; the guard keeps it
  /// structural.
  action dispatch = all {
    readyJobs.size() > 0,
    nondet j = readyJobs.oneOf()
    all {
      jobs.get(j).deadlineLeft > 0,
      apply(decideDispatch(core, j))
    }
  }

  /// A task-completion event arrives for ANY task of a Working/Evaluating
  /// job — running (real resolution) or already resolved (duplicate
  /// delivery, idempotent no-op). One action models both because the fabric
  /// is at-least-once: the machine cannot choose to not receive duplicates.
  ///
  /// Duplicate-adversary SCOPE (why these two stutters suffice for PR 1):
  /// a stale completion for a task of an EARLIER incarnation of the same
  /// id is absorbed by the nondet verdict over the respawned same-id set
  /// (the adversary already picks any verdict for any running task); a
  /// stale landing SUCCESS implies a success occurred, and PDone is
  /// absorbing (landDuplicate). The observed/actual split that would make
  /// mid-rework duplicates dangerous — a decider acting on a stale VIEW —
  /// is exactly the deferred §4 refinement layer (reconcile vs
  /// journaled-actor), not this shared domain layer.
  action taskDone = all {
    taskPhaseJobs.size() > 0,
    nondet j = taskPhaseJobs.oneOf()
    nondet tid = 1.to(N_TASKS).oneOf()
    nondet v = Set(VPass, VFail).oneOf()
    apply(decideTaskDone(core, j, tid, v))
  }

  action workReduce = all {
    reducibleWork.size() > 0,
    nondet j = reducibleWork.oneOf()
    apply(decideWorkReduce(core, j))
  }

  action evalReduce = all {
    reducibleEval.size() > 0,
    nondet j = reducibleEval.oneOf()
    apply(decideEvalReduce(core, j))
  }

  /// The landing resolves, nondet over the three named outcomes. No
  /// quiescence gate on LandFailed (v1 had envActive) — the environment
  /// layer is deferred with §4's contested quiescence theorem.
  action land = all {
    landingJobs.size() > 0,
    nondet j = landingJobs.oneOf()
    nondet out = Set(LandAdvanceDefault, LandSquashMerge, LandFailed).oneOf()
    apply(decideLand(core, j, out))
  }

  /// At-least-once: a duplicate landing event for a Done job. Must emit
  /// nothing (landingExclusive checks it).
  action landDuplicate = all {
    doneJobs.size() > 0,
    nondet j = doneJobs.oneOf()
    apply(decideLandDuplicate(core, j))
  }

  /// Environment churn: revalidation fails at the moment a job would
  /// start. Same enablement as dispatch; which fires is the environment's
  /// choice.
  action revalFail = all {
    readyJobs.size() > 0,
    nondet j = readyJobs.oneOf()
    apply(decideRevalFail(core, j))
  }

  action opRetry = all {
    retryableEscalated.size() > 0,
    nondet j = retryableEscalated.oneOf()
    apply(decideOpRetry(core, j))
  }

  action stalledRetry = all {
    stalledJobs.size() > 0,
    nondet j = stalledJobs.oneOf()
    apply(decideStalledRetry(core, j))
  }

  /// The dead-end stutter (STUTTER set): keeps quiet states from
  /// deadlocking the simulator.
  action settle = all {
    quiet,
    jobs' = jobs,
    lastStep' = { label: "settled", transitions: [], effects: [] },
    prevMeasure' = currentMeasure
  }

  action step = any {
    dispatch,
    taskDone,
    workReduce,
    evalReduce,
    land,
    landDuplicate,
    revalFail,
    opRetry,
    stalledRetry,
    settle
  }

  // ==========================================================================
  // === Invariants ===========================================================
  // ==========================================================================
  // Inside the machine module (Quint 0.32: a separate module cannot see
  // instantiated vars — v1's hard-won structure), re-exposed to --main
  // scope through each mc instance's wildcard import.

  /// THE charter headline (§2 exclusivity, effect-only): exactly one
  /// landing per cycle, proved at the landing boundary and nowhere else —
  /// any number of task executions may duplicate (at-least-once fabric),
  /// but the landing effect is emitted exactly once per job, exactly when
  /// it is Done. "Per cycle" collapses to "per job" because a landing
  /// effect ends the job (PDone is absorbing) and failed landings emit no
  /// landing effect.
  val landingExclusive: bool = allJobs.forall(j => and {
    jobs.get(j).landings <= 1,
    (jobs.get(j).landings == 1) iff (jobs.get(j).phase == PDone)
  })

  /// The human desk is consistent: a named wall iff parked
  /// (Escalated/Stalled), a resume point iff Escalated. (The open-task
  /// flag needs no conjunct any more — it is DERIVED from the phase,
  /// standing rule 3.)
  val deskConsistent: bool = allJobs.forall(j => and {
    (jobs.get(j).phase == PEscalated or jobs.get(j).phase == PStalled)
      iff (jobs.get(j).reason != RsNone),
    (jobs.get(j).phase == PEscalated) iff (jobs.get(j).resumeAt != RNone)
  })

  /// The gate-budget wall exists only under Budgeted pricing (the wall
  /// vocabulary is v1-carried; the pricing parameter is charter §2's).
  val gateWallNamed: bool = match GATE_PRICING {
    | Budgeted(_) => true
    | DeadlineOnly => allJobs.forall(j => jobs.get(j).reason != RsGateBudgetExhausted)
  }

  /// Every account stays a resource: bounded below by 0 (nothing
  /// overdraws) and above by its grant (nothing refunds).
  val accountsBounded: bool = allJobs.forall(j => and {
    jobs.get(j).deadlineLeft >= 0, jobs.get(j).deadlineLeft <= DEADLINE,
    jobs.get(j).reworkLeft >= 0, jobs.get(j).reworkLeft <= REWORK_BUDGET,
    jobs.get(j).gateLeft >= 0, jobs.get(j).gateLeft <= gateBudget(GATE_PRICING)
  })

  /// Task records are exactly the current phase's anatomy: a full task set
  /// (ids 1..N_TASKS) iff Working/Evaluating, empty everywhere else — dead
  /// task state is never carried (derive-don't-store spirit).
  val tasksWellFormed: bool = allJobs.forall(j =>
    if (jobs.get(j).phase == PWorking or jobs.get(j).phase == PEvaluating)
      jobs.get(j).tasks.map(t => t.id) == 1.to(N_TASKS)
    else
      jobs.get(j).tasks == Set())

  /// init's DAG-by-construction survives every step (deps are never
  /// rewritten): each dep points at a known, strictly smaller id.
  val depsAcyclic: bool = allJobs.forall(j =>
    jobs.get(j).deps.forall(d => allJobs.contains(d) and d < j))

  // --- Visibility (charter §2 humans/invariant) -----------------------------

  /// Jobs whose own measure cannot descend without a human: parked on the
  /// desk, or Pending behind a chain containing a parked job. Built by
  /// ascending-id fold — deps point strictly downward, so each job's
  /// membership is decided after all its deps'.
  ///
  /// CONTESTED DEFINITION (charter §4 "Progressing"): "non-progressing" is
  /// defined here via measure-descent (geoff, humans/progressing =
  /// measure-descent — the termination measure doing double duty); kasofsk
  /// answered report-only. The invariant is STATED and checked with the
  /// measure-descent reading so it is at least a theorem candidate; whether
  /// it stays a checked theorem or becomes a dashboard report is the open
  /// §4 conversation.
  val stuckSet: Set[int] =
    range(1, N_JOBS + 1).foldl(Set(), (st, j) =>
      if (or {
        jobs.get(j).phase == PEscalated,
        jobs.get(j).phase == PStalled,
        jobs.get(j).phase == PPending and jobs.get(j).deps.exists(d => st.contains(d))
      }) st.union(Set(j)) else st)

  /// Jobs reachable from an open human task by walking dependency edges
  /// upward: the job's own desk task (derived — hasOpenHumanTask), or a
  /// desk task somewhere in its dependency chain.
  val coveredSet: Set[int] =
    range(1, N_JOBS + 1).foldl(Set(), (cov, j) =>
      if (hasOpenHumanTask(jobs.get(j)) or jobs.get(j).deps.exists(d => cov.contains(d)))
        cov.union(Set(j)) else cov)

  /// The visibility invariant (charter §2, adopted by both): every
  /// non-progressing job is reachable from an open human task. This is
  /// v1's §5c wedge hazard answered structurally: a job stuck behind an
  /// escalated dependency has no desk task of its own but IS reachable
  /// from its dependency's.
  ///
  /// NOTE: with the desk task derived from the phase, this is a structural
  /// COROLLARY of the stuck/covered definitions (induction over the dep
  /// order: every stuckSet base case is a desk phase, which is covered by
  /// hasOpenHumanTask; every inductive case rides the same dep edge in
  /// both folds). It is kept as a STATED, checked theorem — the charter
  /// row deserves a name in the invariant list — not as an independent
  /// check.
  val deskVisibility: bool = stuckSet.subseteq(coveredSet)

  // --- Measure descent (per-job liveness, sketched) -------------------------

  /// Well-foundedness half: the measure is bounded below (follows from
  /// accountsBounded, checked directly for the descent argument's own
  /// integrity).
  val measureNonNegative: bool = currentMeasure >= 0

  /// Descent half: every step strictly decreases sysMeasure EXCEPT the
  /// named STUTTER and CHURN sets (measure.qnt header) — checked by label
  /// against the ghost prevMeasure. Under the default RetryCharged pricing
  /// the operator-retry exemption is empty: every retry pays gas and MUST
  /// descend.
  val stepDescends: bool =
    val exempt = or {
      lastStep.label == "init",
      // STUTTER: state-identical delivery noise + the dead-end self-loop.
      lastStep.label == "task-done-duplicate",
      lastStep.label == "land-duplicate",
      lastStep.label == "settled",
      // CHURN: pre-work desk exit (nothing was ever spent).
      lastStep.label == "stalled-retry",
      // CHURN: free resumes exist only under RetryFree, and only into
      // Evaluating/Landing (the Working resume always pays gas).
      and {
        lastStep.label == "operator-retry",
        OP_RETRY_PRICING == RetryFree,
        lastStep.transitions.foldl(false, (b, t) => b or t.to != PWorking)
      }
    }
    exempt or currentMeasure < prevMeasure

  /// Both halves, for --invariant runs: the per-job termination sketch
  /// (roadmap PR 1 gate: "per-job liveness sketched").
  val measureDescends: bool = and { measureNonNegative, stepDescends }

  /// ANTI-VACUITY WITNESS, not an invariant of the machine: "no
  /// operator-retry ever climbs the measure". EXPECTED TO BE VIOLATED on
  /// the RetryFree instance (check.sh Stage 9's expected-violation run) —
  /// the violation is the machine-level proof that free resumes really do
  /// climb and really are exempted by stepDescends' CHURN arm, which no
  /// green run could otherwise distinguish from dead code. Under
  /// RetryCharged it must HOLD (every retry pays gas and descends).
  val freeClimbNever: bool =
    not(lastStep.label == "operator-retry" and currentMeasure > prevMeasure)

  /// All safety invariants, for `--invariant=allInvariants`.
  val allInvariants: bool = and {
    landingExclusive,
    deskConsistent,
    gateWallNamed,
    accountsBounded,
    tasksWellFormed,
    depsAcyclic,
    deskVisibility,
    measureDescends
  }
}
