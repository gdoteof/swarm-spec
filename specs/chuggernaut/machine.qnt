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
  // The §2.1 transition table — imported ONLY by the PR3 invariants below.
  // Deciders never consult it, so it stays an independent oracle.
  import chug_table.* from "./table"

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
  /// GHOST (PR4): termMeasure evaluated on the PREVIOUS state, written by
  /// every action, read only by stepDecreasesMeasure. Together they encode
  /// the quiescent-termination proof as a safety check — see the
  /// "Temporal (PR4)" section.
  var prevMeasure: int

  /// The current dispatcher state, as the pure deciders see it.
  val core: Core = { jobs: jobs, readyQ: readyQ, envActive: envActive }

  /// Write a decision back into the state — the model's `Core::set_state` +
  /// effect-interpreter shim: all four vars, every step, no other writer.
  action apply(d: Decision): bool = all {
    jobs' = d.post.jobs,
    readyQ' = d.post.readyQ,
    envActive' = d.post.envActive,
    lastStep' = d.rec,
    prevMeasure' = termMeasure
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
        humanTaskOpen: false,
        wasEscalated: false
      }),
      readyQ' = range(1, N_JOBS + 1).select(j => depsOf.get(j) == Set()),
      envActive' = true,
      lastStep' = { label: "init", transitions: [], effects: [] },
      prevMeasure' = 0
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
    lastStep' = { label: "noop-settle", transitions: [], effects: [] },
    prevMeasure' = termMeasure
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

  // ==========================================================================
  // === Invariants (PR3) =====================================================
  // ==========================================================================
  // These live INSIDE chug_machine (option (a) of the design) because Quint
  // 0.32 has no way for a separate module to see another module's
  // instantiated vars: a `chug_invariants` module importing chug_machine
  // would create a SECOND instance with its own jobs/readyQ, disjoint from
  // the one mc_small steps. Defining them here lets them close over the real
  // vars/consts, and mc_small's wildcard import of its chug_machine instance
  // re-exposes every name below, so `--invariant=allInvariants` and
  // `--witnesses ...` resolve in --main=mc_small's scope.
  //
  // The model analogue of chuggernaut crates/dispatcher/src/invariants.rs
  // (`check_invariants`): each Rust check_* maps to a named val here.
  // No counterpart is needed for rdeps_inverts_deps (v1 stores no reverse
  // index), merge_queue_is_wrapup (merge queue deferred to v3), or
  // one_live_job_per_schedule (v1 has no schedules).

  /// Set of a list's elements (Quint 0.32 has no List.toSet builtin).
  pure def listToSet(l: List[int]): Set[int] =
    l.foldl(Set(), (s, x) => s.union(Set(x)))

  /// THE headline check: every transition the last step recorded is a row of
  /// the §2.1 table (chuggernaut state.rs:22-45 `assert_transition`).
  /// Deciders deliberately never consult `allowedTransition`, so this audits
  /// every decide function against the table as an independent oracle — the
  /// model-level form of `Core::set_state` calling `assert_transition` on
  /// every write.
  val stepRespectsTable: bool =
    lastStep.transitions.foldl(true, (ok, t) => ok and allowedTransition(t.from, t.to))

  /// invariants.rs `ready_queue_only_ready` (spec §3.1): the ready queue
  /// holds only known, currently-Ready jobs, and holds each at most once.
  val readyQueueOnlyReady: bool = and {
    readyQ.indices().forall(i =>
      allJobs.contains(readyQ[i]) and jobs.get(readyQ[i]).state == Ready),
    listToSet(readyQ).size() == readyQ.length()
  }

  /// States in which a job has ever entered Work. Note Done is included —
  /// see activeIsExecuting.
  pure def everWorked(s: JobState): bool =
    s == Work or s == Evaluation or s == WrapUp or s == Escalated or s == Done

  /// invariants.rs `active_is_executing` (§3.2/§3.3), adjusted to the claim
  /// v1 actually maintains. Chuggernaut's form is "an ExecState exists iff
  /// the job is Work/Evaluation/WrapUp/Escalated" — existence, because the
  /// ExecState is DELETED when a job settles. The model's `attempt` is a
  /// plain counter with no deletion, so the true v1 claim is:
  ///
  ///   attempt > 0  iff  the job has ever entered Work
  ///                (state in {Work, Evaluation, WrapUp, Escalated, Done})
  ///
  /// Why each state sits on its side of the iff:
  /// - Work: dispatch/reworks/op-retry set attempt := 1 on every entry.
  /// - Evaluation/WrapUp: reached only from Work/Evaluation with attempt
  ///   untouched; op-retry resume (PEvaluation/PWrapUp) also keeps it ≥ 1.
  /// - Escalated: only escalates out of Work/Evaluation/WrapUp, attempt kept
  ///   (mirrors chuggernaut, where Escalated still holds its ExecState).
  /// - Done: only from WrapUp (attempt ≥ 1) and decideLand never zeroes it —
  ///   the one deliberate divergence from the Rust existence check.
  /// - Ready/Blocked/Stalled: attempt == 0 — init gives 0, Stalled arises
  ///   only pre-work (Blocked→Stalled), stalled-retry re-queues without
  ///   touching attempt, and no edge returns to Ready/Blocked after a job
  ///   has ever been dispatched.
  /// - Revoked: unreachable in v1 (no decider emits it); vacuously fine.
  val activeIsExecuting: bool =
    allJobs.forall(j => (jobs.get(j).attempt > 0) iff everWorked(jobs.get(j).state))

  /// invariants.rs `terminal_is_absorbing` (§2.1): a terminal job is
  /// invisible to scheduling — never in the ready queue. (State-level
  /// absorption — nothing transitions OUT of Done/Revoked — is already
  /// covered by stepRespectsTable, since the table forbids every such row.)
  val terminalIsAbsorbing: bool =
    readyQ.indices().forall(i => not(isTerminal(jobs.get(readyQ[i]).state)))

  /// Spec §2.1 Evaluation→Work guard: budgeted reworks never exceed
  /// `rework_budget` (decideEval increments only under `< REWORK_BUDGET`).
  val evalReworksWithinBudget: bool =
    allJobs.forall(j => jobs.get(j).evalReworks <= REWORK_BUDGET)

  /// Spec §3.2: attempt starts at 1 per cycle and same-cycle retries stop at
  /// `work_retries`, so attempt never exceeds WORK_RETRIES + 1.
  val attemptWithinRetries: bool =
    allJobs.forall(j => jobs.get(j).attempt <= WORK_RETRIES + 1)

  /// Spec §3.5 deadline gas stays a resource: never negative (every
  /// decrement is guarded by `deadlineLeft > 0`), never above its initial
  /// grant (nothing refunds gas).
  val deadlineNonNegative: bool =
    allJobs.forall(j =>
      jobs.get(j).deadlineLeft >= 0 and jobs.get(j).deadlineLeft <= DEADLINE)

  /// The UNBUDGETED gate-rework loop (spec §3.3 "Bounding") is bounded by
  /// deadline gas alone: each WrapUp→Work rework charges one gas, gas starts
  /// at DEADLINE and never goes below 0, so gateReworks ≤ DEADLINE. This is
  /// provable ONLY because decideLand charges gas on the rework arm — delete
  /// that `deadlineLeft - 1` and this invariant MUST start failing (that
  /// deletion is exactly the documented livelock with the backstop removed).
  val gateReworksBoundedByGas: bool =
    allJobs.forall(j => jobs.get(j).gateReworks <= DEADLINE)

  /// The reconcile-heal precondition ("an Escalated/Stalled job must always
  /// hold a Pending Human escalation task"), strengthened to the iff v1
  /// actually maintains: humanTaskOpen is set exactly by the three
  /// escalation arms (→Escalated) and decideRevalFail (→Stalled), kept by
  /// decideStalledRetryFail (Stalled→Stalled, flag untouched and still
  /// required — the task stays open), and cleared exactly by the two ways
  /// out (decideOpRetry, decideStalledRetry). So a job holds an open Human
  /// task iff it is Escalated or Stalled.
  val escalatedHasHumanTask: bool =
    allJobs.forall(j =>
      (jobs.get(j).state == Escalated or jobs.get(j).state == Stalled)
        iff jobs.get(j).humanTaskOpen)

  /// Structural guard for the DAG-by-construction claim (init filters deps
  /// to strictly smaller ids, and nothing ever rewrites deps): every dep
  /// edge points at a known job with a strictly smaller id, so the dep
  /// relation is acyclic at every reachable state, not just at init.
  val depsAcyclicAndSmaller: bool =
    allJobs.forall(j => jobs.get(j).deps.forall(d => allJobs.contains(d) and d < j))

  /// All safety invariants, and-ed for `--invariant=allInvariants` and
  /// `quint verify`.
  val allInvariants: bool = and {
    stepRespectsTable,
    readyQueueOnlyReady,
    activeIsExecuting,
    terminalIsAbsorbing,
    evalReworksWithinBudget,
    attemptWithinRetries,
    deadlineNonNegative,
    gateReworksBoundedByGas,
    escalatedHasHumanTask,
    depsAcyclicAndSmaller
  }

  // === Witnesses (anti-vacuity probes) ======================================
  // Each val is the INTERESTING condition, used with `quint run --witnesses`:
  // the simulator reports how many traces hit each one. A witness with zero
  // hits means the invariants above are being checked against a state space
  // that never exercises the behavior — green but vacuous. check.sh Stage 4
  // fails on any zero count.

  /// The happy path completes: every job Done.
  val witnessAllDone: bool =
    allJobs.forall(j => jobs.get(j).state == Done)

  /// The unbudgeted gate-rework loop actually loops (≥ 2 reworks for one
  /// job) — the livelock gateReworksBoundedByGas is bounding is real.
  val witnessGateReworkTwice: bool =
    allJobs.exists(j => jobs.get(j).gateReworks >= 2)

  /// A job that went through escalation (ghost wasEscalated) still reached
  /// Done — the operator-Retry recovery path is exercised end to end.
  val witnessEscalatedRecovered: bool =
    allJobs.exists(j => jobs.get(j).wasEscalated and jobs.get(j).state == Done)

  /// A job that started Blocked (nonempty deps) reached Done — the
  /// dep-recheck unblock cascade is exercised end to end.
  val witnessBlockedUnblocks: bool =
    allJobs.exists(j => jobs.get(j).state == Done and jobs.get(j).deps != Set())

  // ==========================================================================
  // === Temporal (PR4) =======================================================
  // ==========================================================================
  // Same instance-scoping rule as the PR3 invariants above: everything here
  // must close over the instantiated vars, so it lives inside chug_machine
  // and resolves in --main scope through each mc instance's wildcard import.
  //
  // VERIFICATION STATUS (the honest part). The three `temporal` declarations
  // below are the formal claims, but neither checker in this toolchain can
  // discharge them today:
  //  - `quint verify --temporal` (Apalache 0.56.1 via quint 0.32) dies
  //    deterministically, on both the true and the false properties, at
  //    step 1: Z3 segfaults natively (hs_err log: SIGSEGV in
  //    libz3.so bool_rewriter::mk_flat_or_core) while the server is
  //    translating the temporal-rewritten step relation to SMT, and quint
  //    surfaces it as `error: assertion failed`.
  //  - `quint verify --backend=tlc` fails twice over: the generated TLA+
  //    hits a TLC evaluation bug in init's `ApaFoldSeqLeft`/`MkSeq`
  //    ("Attempted to evaluate an expression of form P /\ Q when P was a
  //    tuple"), and even past that, quint emits INIT/NEXT with no fairness
  //    and no Spec, so TLC's stuttering-closed liveness semantics would
  //    refute ANY eventually-property vacuously. noopSettle-as-fairness
  //    only works under checkers whose lassos are built from real steps.
  // So this PR discharges the claims the sturdy way instead:
  //  - the TRUE theorem (quiescentlySettles) is proved by well-founded
  //    descent, encoded as the plain safety invariant quiescentDescent
  //    below and checked by the same machinery as PR3 (randomized deep
  //    runs + Apalache bounded invariant checking, which does not crash);
  //  - the FALSE claims are refuted by machine-checked reachability of
  //    their livelock/wedge configurations (gateReworksWithinBudgets and
  //    wedgeFree, both expected-FAIL in scripts/check.sh Stage 6).

  /// The honest "the machine is finished" condition: every job settled, OR
  /// the quiesced wedge (see allWedged). allSettled alone is NOT eventually
  /// reached on every quiescent run: a job Blocked behind a dep that
  /// escalated before quiesce can never settle once the operator is gone —
  /// the run stutters forever on noopSettle with allSettled false.
  val allSettledOrWedged: bool = allSettled or allWedged

  /// FALSE — without any fairness assumption the machine need never finish,
  /// EVEN with a finite job_deadline: the counterexample lasso is operator
  /// churn that consumes nothing the deadline meters — an Escalated job
  /// whose Retry resumes Evaluation/WrapUp (no gas charged) and whose next
  /// failure re-escalates, retry -> fail -> escalate -> retry forever. That
  /// this is the ONLY livelock shape left is machine-checked by
  /// stepDecreasesMeasure below: every step except noopSettle and the
  /// envActive-gated operator actions strictly decreases a measure that
  /// cannot decrease forever. Real-system consequence: "quiesce the
  /// environment" must gate OPERATOR actions too, or termination still
  /// fails with all budgets and deadlines finite.
  temporal terminationNoFairness = eventually(allSettledOrWedged)

  /// FALSE — the naive quiescent-termination claim, over bare allSettled.
  /// Refuted by the wedge: reach { j2 Blocked on j1, j1 Escalated }, then
  /// quiesce — machine-checked as the expected-FAIL of wedgeFree. In the
  /// wedge state noopSettle is the only enabled action, so the run stutters
  /// with allSettled false forever. Kept to document exactly why
  /// quiescentlySettles needs the allSettledOrWedged disjunction.
  temporal terminationUnderQuiescence =
    eventually(always(not(envActive))) implies eventually(allSettled)

  /// TRUE — the headline theorem: once the environment goes permanently
  /// quiet, every run reaches allSettledOrWedged. Proof: (1) the machine
  /// never deadlocks (some action is always enabled — noopSettle exists
  /// precisely to cover the settled/wedged dead ends); (2) after quiesce,
  /// every envActive-gated action is disabled, and stepDecreasesMeasure
  /// (checked below) says every remaining action except noopSettle strictly
  /// decreases termMeasure; (3) measureNonNegative bounds termMeasure below.
  /// So an infinite quiesced run takes only finitely many non-noopSettle
  /// steps, must eventually take noopSettle — and noopSettle's guard IS
  /// allSettledOrWedged. The documented gate loop is finite here for both
  /// reasons at once: quiescence removes the LConflictOrGateFail outcome,
  /// and each rework it would take charges gas.
  temporal quiescentlySettles =
    eventually(always(not(envActive))) implies eventually(allSettledOrWedged)

  /// FALSE on mc_livelock (expected-fail) — the finite refutation witness of
  /// the documented budget-free gate loop (chuggernaut docs/spec.md §3.3
  /// "Bounding", line ~1269: "repeated gate failures don't consume
  /// rework_budget"). If gate reworks were metered by ANY of the model's
  /// budgets, gateReworks could never exceed WORK_RETRIES + REWORK_BUDGET;
  /// the violating trace is one job looping Work -> Evaluation -> WrapUp ->
  /// Work on "job-rework-started merge_gate_failure" beyond every budget,
  /// bounded only by deadline gas (PR3's gateReworksBoundedByGas). On
  /// mc_liveness (DEADLINE=2) this val HOLDS — the gas backstop is doing
  /// that bounding.
  val gateReworksWithinBudgets: bool =
    allJobs.forall(j => jobs.get(j).gateReworks <= WORK_RETRIES + REWORK_BUDGET)

  /// FALSE on both mc instances (expected-fail) — the wedge is reachable:
  /// a state that is allWedged but not allSettled (a job Blocked forever
  /// behind an Escalated dep, after quiesce). This is the machine-checked
  /// half of the terminationUnderQuiescence refutation.
  val wedgeFree: bool = allWedged implies allSettled

  // --- The termination measure ---------------------------------------------
  // A per-job weighted potential, summed, plus 1 while the environment is
  // active. GAS = WORK_RETRIES + 4 is the weight of one unit of deadline
  // gas — big enough that every gas-charging step decreases the total even
  // when the phase rank climbs back up (the worst case is operator-retry
  // resuming Work: rank 0 -> 3 + WORK_RETRIES, gas pays GAS).
  //
  // Step-by-step deltas (W = WORK_RETRIES, a = attempt, a <= W+1 by PR3's
  // attemptWithinRetries):
  //   dispatch                                   -5
  //   work-succeeded                             a - W - 2  <= -1
  //   work-retry                                 -1
  //   job-escalated work_retries_exhausted       a - W - 4  <= -3
  //   eval-passed                                -1
  //   job-rework-started eval_failure            -3
  //   job-escalated (from Evaluation)            -2
  //   job-done                                   -1
  //   job-rework-started merge_gate_failure      -2   (gas pays for it)
  //   job-escalated job_deadline_exceeded (WrapUp) -1
  //   job-unblocked                              -1
  //   job-stalled revalidation_failed            -5
  //   operator-retry resuming Work               -1   (charges gas)
  //   quiesce                                    -1   (the envActive term)
  //   --- the ONLY non-decreasing steps: ---
  //   operator-retry resuming Evaluation         +2   (envActive-gated)
  //   operator-retry resuming WrapUp             +1   (envActive-gated)
  //   stalled-retry                              +4   (envActive-gated)
  //   stalled-retry-failed                        0   (envActive-gated)
  //   noop-settle                                 0   (guard = allSettledOrWedged)
  // Every non-decreasing step other than noop-settle requires envActive —
  // that list IS the operator-churn livelock, isolated mechanically.

  /// Phase rank: how far from settled a job's lifecycle position is.
  /// Work's rank falls as attempt climbs so same-cycle retries descend too.
  pure def phaseRank(s: JobState, attempt: int): int =
    if (s == Blocked) 5
    else if (s == Ready) 4
    else if (s == Work) 3 + (WORK_RETRIES + 1 - attempt)
    else if (s == Evaluation) 2
    else if (s == WrapUp) 1
    else 0 // Done, Revoked, Escalated, Stalled (and unreachable authoring states)

  /// The termination measure over the current state.
  val termMeasure: int =
    allJobs.fold(0, (acc, j) =>
      acc
        + (WORK_RETRIES + 4) * jobs.get(j).deadlineLeft
        + phaseRank(jobs.get(j).state, jobs.get(j).attempt))
    + (if (envActive) 1 else 0)

  /// termMeasure is bounded below — the well-foundedness half of the
  /// descent proof (gas never goes negative, ranks are nonnegative).
  val measureNonNegative: bool = termMeasure >= 0

  /// The descent half: every step strictly decreases termMeasure, EXCEPT
  /// the noopSettle stutter and the envActive-gated operator-churn actions
  /// (see the delta table above). Under quiescence the exceptions other
  /// than noopSettle are disabled, so this invariant + measureNonNegative
  /// + deadlock freedom proves quiescentlySettles by well-founded descent —
  /// at every depth, not just a bounded prefix.
  val stepDecreasesMeasure: bool =
    val churnStep = or {
      lastStep.label == "noop-settle",
      lastStep.label == "stalled-retry",
      lastStep.label == "stalled-retry-failed",
      // operator-retry resuming Evaluation/WrapUp charges no gas; the
      // resuming-Work arm does charge gas and must therefore descend.
      lastStep.label == "operator-retry" and
        lastStep.transitions.foldl(false, (b, t) => b or t.to != Work)
    }
    or {
      lastStep.label == "init",
      churnStep,
      termMeasure < prevMeasure
    }

  /// Both halves of the quiescent-termination proof, for --invariant.
  val quiescentDescent: bool = and {
    measureNonNegative,
    stepDecreasesMeasure
  }
}
