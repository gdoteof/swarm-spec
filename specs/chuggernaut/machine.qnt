/// The v1 executable machine. Chuggernaut's dispatcher is a single-writer
/// actor — all state transitions are sequential and the only concurrency is
/// the order events arrive — so the model is a single evolving state with one
/// nondeterministically chosen event per step. Every step's guard lives in
/// the machine; every state change is computed by a pure chug_decide decider
/// and written through `apply`, mirroring the dispatcher shim's
/// gather-view → decide → apply-transitions → run-effects shape
/// (chuggernaut crates/domain/src/decide/mod.rs).
module chug_machine {
  import chug_types.* from "./types"

  /// Number of jobs in the graph (ids 1..N_JOBS).
  const N_JOBS: int
  /// Execution slots: max jobs simultaneously in flight (Work/Evaluation/
  /// WrapUp — Escalated holds no container).
  const N_AGENTS: int
  /// Same-cycle work retries (spec `work_retries`).
  const WORK_RETRIES: int
  /// Budgeted eval-failure reworks (spec `rework_budget`).
  const REWORK_BUDGET: int
  /// Deadline gas per job: how many entries to Work a job may make
  /// (models the spec §3.5 `job_deadline` backstop).
  const DEADLINE: int

  import chug_decide(WORK_RETRIES = WORK_RETRIES, REWORK_BUDGET = REWORK_BUDGET) as D
    from "./decide"

  pure val allJobs: Set[int] = 1.to(N_JOBS)

  var jobs: int -> Job
  var readyQ: List[int]
  var envActive: bool
  /// The last decision's StepRecord — the golden-trace-shaped observation
  /// PR3's invariants (and trace diffing) read.
  var lastStep: StepRecord

  /// The current dispatcher state, as the pure deciders see it.
  val core: Core = { jobs: jobs, readyQ: readyQ, envActive: envActive }

  /// Write a decision back into the state — the model's `Core::set_state` +
  /// effect-interpreter shim: all four vars, every step, no other writer.
  action apply(d: Decision): bool = all {
    jobs' = d.post.jobs,
    readyQ' = d.post.readyQ,
    envActive' = d.post.envActive,
    lastStep' = d.rec
  }

  pure def isActive(s: JobState): bool =
    s == Work or s == Evaluation or s == WrapUp

  pure def isSettledState(s: JobState): bool =
    s == Done or s == Revoked or s == Escalated or s == Stalled

  /// Jobs holding an execution slot. Escalated/Stalled hold none.
  val activeCount: int = allJobs.filter(j => isActive(jobs.get(j).state)).size()

  def depsDone(j: int): bool =
    jobs.get(j).deps.forall(k => jobs.get(k).state == Done)

  val workJobs: Set[int] = allJobs.filter(j => jobs.get(j).state == Work)
  val evalJobs: Set[int] = allJobs.filter(j => jobs.get(j).state == Evaluation)
  val wrapupJobs: Set[int] = allJobs.filter(j => jobs.get(j).state == WrapUp)
  val stalledJobs: Set[int] = allJobs.filter(j => jobs.get(j).state == Stalled)
  /// Blocked jobs whose deps are all Done: eligible for the dep-recheck that
  /// either unblocks them or fails revalidation.
  val unblockable: Set[int] =
    allJobs.filter(j => jobs.get(j).state == Blocked and depsDone(j))
  /// Escalated jobs the operator may Retry. A PWork escalation with no
  /// deadline gas left may not resume (re-entering Work charges gas and gas
  /// never goes below 0); it stays Escalated — a settled state.
  val retryableEscalated: Set[int] =
    allJobs.filter(j =>
      jobs.get(j).state == Escalated and
      (jobs.get(j).escalatedFrom != PWork or jobs.get(j).deadlineLeft > 0))

  /// Every job is settled: nothing in flight, nothing waiting.
  val allSettled: bool = allJobs.forall(j => isSettledState(jobs.get(j).state))

  /// The quiesced wedge: envActive is false (one-way, so Escalated/Stalled
  /// jobs are now permanent) and every job is settled or Blocked on a dep
  /// that can never reach Done. No action but the settle self-loop is
  /// enabled here, and no dep can newly reach Done, so without this
  /// disjunct the state would be a dead end that silently truncates
  /// simulation traces (and would break PR3 liveness).
  val allWedged: bool =
    not(envActive) and allJobs.forall(j =>
      isSettledState(jobs.get(j).state) or
      (jobs.get(j).state == Blocked and not(depsDone(j))))

  /// Nondet acyclic DAG: one nondet total map job -> Set[int], then each
  /// job's dep set is filtered to strictly smaller ids — acyclicity by
  /// construction (many raw maps collapse to the same DAG; harmless).
  /// Jobs with no deps start Ready and seed the ready queue in ascending
  /// id order; the rest start Blocked.
  action init =
    nondet depsChoice = allJobs.setOfMaps(allJobs.powerset()).oneOf()
    val depsOf = allJobs.mapBy(j => depsChoice.get(j).filter(k => k < j))
    all {
      jobs' = allJobs.mapBy(j => {
        state: if (depsOf.get(j) == Set()) Ready else Blocked,
        deps: depsOf.get(j),
        escalatedFrom: PNone,
        attempt: 0,
        evalReworks: 0,
        gateReworks: 0,
        deadlineLeft: DEADLINE,
        humanTaskOpen: false
      }),
      readyQ' = range(1, N_JOBS + 1).select(j => depsOf.get(j) == Set()),
      envActive' = true,
      lastStep' = { label: "init", transitions: [], effects: [] }
    }

  /// Ready→Work, head of the queue, only when a slot is free. The gas guard
  /// never binds when DEADLINE ≥ 1 (Ready jobs have never entered Work) but
  /// keeps deadlineLeft ≥ 0 by construction for any instantiation.
  action dispatch = all {
    readyQ.length() > 0,
    activeCount < N_AGENTS,
    jobs.get(readyQ.head()).deadlineLeft > 0,
    apply(D::decideDispatch(core))
  }

  /// A Work task resolves with a nondet outcome (container execution
  /// abstracted away). Failure is allowed even when quiesced — it is the
  /// job's own product, not environment churn.
  action taskDone = all {
    workJobs.size() > 0,
    nondet j = workJobs.oneOf()
    nondet out = Set(WSuccess, WFailure).oneOf()
    apply(D::decideTaskDone(core, j, out))
  }

  /// The staged eval round reduces to one nondet outcome.
  action evalReduce = all {
    evalJobs.size() > 0,
    nondet j = evalJobs.oneOf()
    nondet out = Set(EPass, EProductFail).oneOf()
    apply(D::decideEval(core, j, out))
  }

  /// The landing resolves. A conflict/gate failure needs a moving default
  /// branch — a stable (quiesced) environment can't produce new conflicts,
  /// so the failure outcome additionally requires envActive.
  action land = all {
    wrapupJobs.size() > 0,
    nondet j = wrapupJobs.oneOf()
    nondet out = (if (envActive) Set(LClean, LConflictOrGateFail) else Set(LClean)).oneOf()
    apply(D::decideLand(core, j, out))
  }

  /// Blocked→Ready: dep recheck after the last dep reached Done. One mailbox
  /// message per dependent — the Done-cascade is these separate steps.
  action depRecheck = all {
    unblockable.size() > 0,
    nondet j = unblockable.oneOf()
    apply(D::decideDepRecheck(core, j))
  }

  /// Blocked→Stalled: same trigger as depRecheck but revalidation fails.
  /// Environment churn (a file vanished since release), so envActive.
  action revalFail = all {
    envActive,
    unblockable.size() > 0,
    nondet j = unblockable.oneOf()
    apply(D::decideRevalFail(core, j))
  }

  /// Operator resolves an escalation with Retry. The operator is part of the
  /// environment, so envActive.
  action opRetry = all {
    envActive,
    retryableEscalated.size() > 0,
    nondet j = retryableEscalated.oneOf()
    apply(D::decideOpRetry(core, j))
  }

  /// Operator Retry on a pre-work stall succeeds: Stalled→Ready.
  action stalledRetry = all {
    envActive,
    stalledJobs.size() > 0,
    nondet j = stalledJobs.oneOf()
    apply(D::decideStalledRetry(core, j))
  }

  /// Operator Retry on a pre-work stall fails again: Stalled→Stalled.
  action stalledRetryFail = all {
    envActive,
    stalledJobs.size() > 0,
    nondet j = stalledJobs.oneOf()
    apply(D::decideStalledRetryFail(core, j))
  }

  /// The environment goes quiet (one-way).
  action quiesce = all {
    envActive,
    apply(D::decideQuiesce(core))
  }

  /// The ONLY self-loop, and the fairness encoding: no other stutter exists,
  /// so infinite runs must make progress until settled (or wedged — see
  /// allWedged).
  action noopSettle = all {
    allSettled or allWedged,
    jobs' = jobs,
    readyQ' = readyQ,
    envActive' = envActive,
    lastStep' = { label: "noop-settle", transitions: [], effects: [] }
  }

  action step = any {
    dispatch,
    taskDone,
    evalReduce,
    land,
    depRecheck,
    revalFail,
    opRetry,
    stalledRetry,
    stalledRetryFail,
    quiesce,
    noopSettle
  }
}
