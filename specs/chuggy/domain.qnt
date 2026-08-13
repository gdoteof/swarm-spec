/// The chuggy core domain machine (chuggy-charter.md §6, roadmap PR 1) —
/// written AFTER and fitted TO measure.qnt (standing rule 1). This is the
/// layer both §4 fork candidates share: every decider is a pure function of
/// observed state (`Core`), so a CRD reconciler and a journaled actor reuse
/// them unchanged; the refinement layer (reconcile vs journaled-actor
/// semantics) is deliberately absent, blocked on the §4 conversation.
///
/// PR 2 (authoring lifecycle, charter §2 first-class rank #1; gate: revoke
/// cascades proved safe) is IN: jobs arrive as Drafts through the
/// `freshJob` seam PR 1 kept open, the Draft/Frozen pair sits above the
/// released pipeline, and Revoked is the second settled terminal with an
/// ATOMIC park-cascade (decideRevoke) covering its dependents. Vocabulary
/// transcribed from v1's table (specs/chuggernaut/table.qnt); adopted rows
/// and deviations are cited decider-by-decider below.
///
/// What is deliberately NOT here (and which roadmap PR restores it):
///   - Batched + the merge queue it serves (PR 5) — the v1 table's
///     (Frozen, Batched) and (Batched, Frozen|Done) rows (table.qnt lines
///     27-30) are deliberately not transcribed yet;
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

  /// ARRIVAL BOUND (PR 2): at most N_JOBS jobs ever arrive; ids are dense
  /// 1..count and never reused, so the live fleet is jobs.keys() ⊆
  /// 1..N_JOBS. (PR 1 read this as a static graph size; authoring turned
  /// the static graph into bounded arrivals — small in mc instances so the
  /// state space stays small.)
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

  /// The measure's bounds, from this instance's consts.
  pure val bounds: Bounds = {
    reworkBudget: REWORK_BUDGET,
    nTasks: N_TASKS,
    gatePricing: GATE_PRICING
  }

  /// The job-source seam, now CLOSED by PR 2 exactly as PR 1 promised:
  /// every job the machine ever holds is built here, and the only caller is
  /// decideArrive — a job is born a Draft (v1 vocabulary: authoring starts
  /// at Draft, table.qnt lines 21-22) with its full accounts, and reaches
  /// the released pipeline only through decideRelease.
  pure def freshJob(deps_: Set[int]): Job = {
    phase: PDraft,
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

  // --- Authoring (PR 2): arrival, freeze/unfreeze, release, revoke ---------
  // Vocabulary source: specs/chuggernaut/table.qnt (verbatim from
  // chuggernaut state.rs). Each decider cites the table row it adopts;
  // deviations are called out where they happen.

  /// A job ARRIVES as a Draft — the environment (an author) creates it.
  /// NOT a table edge: v1's table starts at Draft and has no birth row (its
  /// jobs exist statically); the arrival action is chuggy-new, forced by
  /// authoring being the job source now (charter §2 first-class rank #1).
  /// Ids are dense and never reused (next id = fleet size + 1), which keeps
  /// every ascending-id fold below correct. Dependencies may point at ANY
  /// live job, released or not (Draft/Frozen deps block exactly like
  /// not-yet-Done ones) — but never at a tombstone: not a Revoked job, and
  /// not a job the cascade already parked behind one (Stalled with
  /// dependency_revoked — by cascadeSafety those two cases are EXACTLY the
  /// transitively-doomed jobs). The author cannot depend on either
  /// (authoring-time validation; admitting one would create a job doomed
  /// at birth, which cascadeSafety forbids anyone to hold un-parked — the
  /// first random invariant run caught precisely this). Callers guarantee
  /// deps_ ⊆ dependable ids (see `dependableJobs`).
  ///
  /// Dynamic-DAG boundary (charter §3): arrivals are AUTHOR actions — only
  /// the environment action `arrive` calls this decider, and no job-event
  /// decider creates jobs, so the job set grows only by authoring, never by
  /// jobs spawning jobs. Author commands (freeze/unfreeze/release/revoke)
  /// are also guarded by enablement, not absorbed as duplicates: authors
  /// are command sources, not the at-least-once fabric — only fabric events
  /// get idempotent stutter deciders.
  pure def decideArrive(c: Core, deps_: Set[int]): Decision =
    val id = c.jobs.keys().size() + 1
    { rec: { label: "job-arrived", transitions: [], effects: ["CreateDraft"] },
      post: { ...c, jobs: c.jobs.put(id, freshJob(deps_)) } }

  /// Draft -> Frozen (table line 22: `(Draft, ... | Frozen)`): the author
  /// pins the job's content. Descends (rank 6 -> 5).
  pure def decideFreeze(c: Core, j: int): Decision =
    move(c, j, PFrozen, "job-frozen", [])

  /// Frozen -> Draft (table line 24: `(Frozen, Draft)`): the author thaws
  /// the job to edit again — THE authoring loop. The table has no
  /// Draft -> Draft row (content edits are below the phase table's grain),
  /// so this unfreeze edge is the loop's entire phase-level footprint: the
  /// AUTHORING churn set in measure.qnt (climbs rank 5 -> 6), which is what
  /// makes per-job liveness conditional on authors eventually releasing or
  /// revoking.
  pure def decideUnfreeze(c: Core, j: int): Decision =
    move(c, j, PDraft, "job-unfrozen", [])

  /// {Draft, Frozen} -> Pending (table lines 21-22 `(Draft, Ready |
  /// Blocked | ...)` and lines 25-26 `(Frozen, Ready | Blocked)`): the job
  /// enters the released pipeline. Both table targets collapse to PPending
  /// because Ready/Blocked are DERIVED predicates in chuggy (standing rule
  /// 3, the PR 1 decision) — the split re-derives from deps the moment the
  /// phase lands. Descends (rank 6 or 5 -> 4). Charges nothing: the
  /// Working boundary still meters actual work entry (standing rule 2).
  pure def decideRelease(c: Core, j: int): Decision =
    move(c, j, PPending, "job-released", [])

  /// Revoke + THE CASCADE (the PR 2 gate). Table provenance for the revoke
  /// edge itself: lines 47-48 `(_, Revoked) => true` — every non-terminal
  /// phase may be revoked (the caller's guard, revocableIn) — and lines
  /// 45-46 `(Done | Revoked, Revoked) => false` — the terminals are
  /// absorbing, so no decider ever moves a job OUT of PRevoked (invariant
  /// terminalsAbsorbing). The revoked job settles: rank -> 0, task set
  /// cleared (Revoked holds nothing), accounts UNTOUCHED — revoke charges
  /// no gas and spends no budget in either direction — and reason/resumeAt
  /// cleared: PRevoked opens NO human task (hasOpenHumanTask excludes it;
  /// revocation is the author's settled choice, like PDone).
  ///
  /// THE CASCADE, designed here (v1 never answered it — model-status §6b
  /// lists "revoke fan-out cascade" as unanswerable): a job whose dep chain
  /// contains a revoked job can never unblock (a dep that is not Done
  /// blocks, and PRevoked never becomes PDone). Of the two candidate
  /// semantics —
  ///   (a) transitive cascade-REVOKE: dependents are revoked too;
  ///   (b) PARK: dependents stall on the desk with a named wall —
  /// chuggy picks (b), ATOMICALLY in this decision, for two charter
  /// reasons. First, revocation is a per-job authorial choice: (a) would
  /// let one author's revocation silently destroy OTHER jobs with no human
  /// decision and no desk trace (a cascade-revoked job opens no task — the
  /// exact invisibility the §2 visibility row forbids). Second, parking
  /// preserves deskVisibility structurally: every doomed dependent gets its
  /// OWN open task (RsDependencyRevoked) telling a human "your dependency
  /// was revoked; settle me" — and the human settles it by revoking it (its
  /// desk revoke is the AUTHORING flat member in measure.qnt). The park is
  /// atomic with the revoke — same decision, one StepRecord — so
  /// cascadeSafety holds in EVERY reachable state, never just eventually.
  ///
  /// Why parking only PDraft/PFrozen/PPending dependents is exhaustive: a
  /// transitive dependent of a revocable (hence non-Done) job can never
  /// have dispatched — dispatch needs all deps Done, Done is absorbing, and
  /// the revoked ancestor is not Done — so every dependent is still
  /// pre-flight: Draft, Frozen, Pending, or already settled by an earlier
  /// cascade (PStalled RsDependencyRevoked) or by its own author
  /// (PRevoked). The filter parks exactly the first three and leaves the
  /// already-settled alone (no duplicate transitions).
  pure def decideRevoke(c: Core, j: int): Decision =
    val n = c.jobs.keys().size()
    // Transitive dependents of j: deps point strictly downward, so one
    // ascending pass decides each id after all its deps (same shape as the
    // stuckSet/coveredSet folds).
    val doomedByJ = range(1, n + 1).foldl(Set(), (dset, k) =>
      if (c.jobs.get(k).deps.contains(j) or
          c.jobs.get(k).deps.exists(d => dset.contains(d)))
        dset.union(Set(k)) else dset)
    val parked = doomedByJ.filter(k =>
      val p = c.jobs.get(k).phase
      p == PDraft or p == PFrozen or p == PPending)
    // Ascending, deterministic order for the golden-trace record.
    val parkedList = range(1, n + 1).foldl([], (l, k) =>
      if (parked.contains(k)) l.append(k) else l)
    { rec: {
        label: "job-revoked",
        transitions:
          [{ job: j, from: c.jobs.get(j).phase, to: PRevoked }]
            .concat(parkedList.foldl([], (l, k) =>
              l.append({ job: k, from: c.jobs.get(k).phase, to: PStalled }))),
        // "Revoke" for the revoked job; one OpenHumanTask per parked
        // dependent — and NONE for the revoked job itself.
        effects: ["Revoke"].concat(parkedList.foldl([], (l, k) =>
          l.append("OpenHumanTask"))) },
      post: { ...c, jobs: c.jobs.keys().mapBy(k =>
        if (k == j)
          { ...c.jobs.get(k), phase: PRevoked, tasks: Set(),
            resumeAt: RNone, reason: RsNone }
        else if (parked.contains(k))
          { ...c.jobs.get(k), phase: PStalled, reason: RsDependencyRevoked }
        else c.jobs.get(k)) } }

  // --- Pure guard predicates (PR 2: shared by actions and unit tests) ------

  /// Table lines 45-48: every phase but the two absorbing terminals may be
  /// revoked.
  pure def revocableIn(c: Core, j: int): bool =
    c.jobs.get(j).phase != PDone and c.jobs.get(j).phase != PRevoked

  /// May the operator retry this stall? RsRevalidationFailed: yes — v1's
  /// (Stalled, Ready) edge (table line 44), nothing was ever spent.
  /// RsDependencyRevoked: NO — a DELIBERATE RESTRICTION of table line 44:
  /// deps are immutable in this model (no re-authoring machinery yet), so a
  /// retry could only re-enter Pending still doomed behind the same revoked
  /// dep — a lie to the desk and an immediate cascadeSafety hole. The
  /// dependency_revoked wall's only modeled exit is revoke; dep re-authoring
  /// is future work (README, deliberately-absent table).
  pure def stallRetryableIn(c: Core, j: int): bool =
    c.jobs.get(j).phase == PStalled and
    c.jobs.get(j).reason != RsDependencyRevoked

  pure def depsDoneIn(c: Core, j: int): bool =
    c.jobs.get(j).deps.forall(k => c.jobs.get(k).phase == PDone)

  /// The derived waiting room (standing rule 3), as pure predicates over a
  /// Core so tests can pin them: a dep that is not Done blocks — including
  /// UNRELEASED deps (Draft/Frozen, PR 2) and, transiently impossible but
  /// definitionally covered, revoked ones.
  pure def isReadyIn(c: Core, j: int): bool =
    c.jobs.get(j).phase == PPending and depsDoneIn(c, j)

  pure def isBlockedIn(c: Core, j: int): bool =
    c.jobs.get(j).phase == PPending and not(depsDoneIn(c, j))

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
  /// desk opens. PR 2 delivered the anticipated second stall cause: the
  /// cascade's dependency_revoked wall (decideRevoke) — which, unlike this
  /// one, is NOT retryable (stallRetryableIn).
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

  /// The live fleet (PR 2): ids are dense 1..size and never reused
  /// (invariant idsDense), so ascending-id folds below stay correct. PR 1's
  /// static `allJobs = 1.to(N_JOBS)` became this — N_JOBS is now the
  /// arrival BOUND, not the fleet size.
  val liveJobs: Set[int] = jobs.keys()

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
  // measure.qnt hasOpenHumanTask.) PR 2 extends them for free: an
  // UNRELEASED dep (Draft/Frozen) is simply a dep that is not Done, so it
  // blocks with no new machinery; the pure bodies live with the deciders
  // (isReadyIn/isBlockedIn) so unit tests can pin exactly that.

  def isReady(j: int): bool = isReadyIn(core, j)

  def isBlocked(j: int): bool = isBlockedIn(core, j)

  // --- Enablement sets ------------------------------------------------------

  /// Room for one more arrival (the N_JOBS arrival bound keeps the state
  /// space finite; ids dense, never reused).
  val canArrive: bool = liveJobs.size() < N_JOBS
  /// Jobs a new arrival may depend on: no tombstones — neither Revoked nor
  /// cascade-parked (which, by cascadeSafety, is exactly the
  /// transitively-doomed set; decideArrive's doc has the argument).
  val dependableJobs: Set[int] = liveJobs.filter(k => and {
    jobs.get(k).phase != PRevoked,
    not(jobs.get(k).phase == PStalled and jobs.get(k).reason == RsDependencyRevoked)
  })
  val draftJobs: Set[int] = liveJobs.filter(j => jobs.get(j).phase == PDraft)
  val frozenJobs: Set[int] = liveJobs.filter(j => jobs.get(j).phase == PFrozen)
  /// Release is table-legal from BOTH authoring phases (table.qnt lines
  /// 21-22 and 25-26).
  val releasableJobs: Set[int] = draftJobs.union(frozenJobs)
  /// Every non-terminal may be revoked (table.qnt lines 45-48).
  val revocableJobs: Set[int] = liveJobs.filter(j => revocableIn(core, j))
  val readyJobs: Set[int] = liveJobs.filter(j => isReady(j))
  /// Jobs whose task set can receive completion events (real or duplicate).
  val taskPhaseJobs: Set[int] =
    liveJobs.filter(j => jobs.get(j).phase == PWorking or jobs.get(j).phase == PEvaluating)
  val reducibleWork: Set[int] =
    liveJobs.filter(j => jobs.get(j).phase == PWorking and runningCount(jobs.get(j).tasks) == 0)
  val reducibleEval: Set[int] =
    liveJobs.filter(j => jobs.get(j).phase == PEvaluating and runningCount(jobs.get(j).tasks) == 0)
  val landingJobs: Set[int] = liveJobs.filter(j => jobs.get(j).phase == PLanding)
  val doneJobs: Set[int] = liveJobs.filter(j => jobs.get(j).phase == PDone)
  /// Stalls the operator may retry: the revalidation wall only — the
  /// dependency_revoked wall is deliberately NOT retryable (see
  /// stallRetryableIn for the table-line-44 deviation note).
  val retryableStalled: Set[int] = liveJobs.filter(j => stallRetryableIn(core, j))

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

  val retryableEscalated: Set[int] = liveJobs.filter(j => retryable(j))

  /// No machine, operator, or author action can move anything. PR 2 shrank
  /// this dramatically: revoke is enabled on EVERY non-terminal (table
  /// lines 47-48), so unretryable escalations, doomed Pending chains, and
  /// parked stalls are all still actionable — the only true dead end is a
  /// fully-arrived fleet in which every job is settled in a terminal
  /// (Done or Revoked). The `settled` stutter covers exactly that state so
  /// runs never deadlock.
  val quiet: bool = and {
    not(canArrive),
    liveJobs.forall(j => jobs.get(j).phase == PDone or jobs.get(j).phase == PRevoked)
  }

  // --- init -----------------------------------------------------------------

  /// The fleet starts EMPTY (PR 2): authoring is the job source now —
  /// PR 1's static nondet DAG is fully replaced by `arrive`, which grows
  /// the fleet one Draft at a time through the freshJob seam (deps still
  /// acyclic by construction: they may only point at already-arrived,
  /// strictly smaller ids).
  /// The `DEADLINE >= 1` conjunct is the charter's REQUIRED-deadline row as
  /// a validity condition: an instantiation without a deadline has NO
  /// initial state — the graph is invalid, not merely unmetered (every
  /// arrival funds a job from this grant, so checking it here still gates
  /// every job ever created).
  action init = all {
    DEADLINE >= 1,       // charter §2 economy/deadline: required field
    N_TASKS >= 1,        // well-formedness: a phase carries a real task set
    N_JOBS >= 1,         // the arrival bound must admit at least one job
    REWORK_BUDGET >= 0,
    gateBudget(GATE_PRICING) >= 0,
    jobs' = Map(),
    lastStep' = { label: "init", transitions: [], effects: [] },
    prevMeasure' = 0
  }

  // --- actions --------------------------------------------------------------

  /// A new job arrives as a Draft (the environment/author acts), deps a
  /// nondet subset of DEPENDABLE live jobs — released or not (unreleased
  /// deps block via the derived waiting room; tombstones are refused at
  /// authoring time, see decideArrive/dependableJobs). AUTHORING set in
  /// the measure: climbs by the fresh Draft's whole jobMeasure, bounded by
  /// N_JOBS.
  action arrive = all {
    canArrive,
    nondet deps_ = dependableJobs.powerset().oneOf()
    apply(decideArrive(core, deps_))
  }

  /// Author freezes a Draft (table line 22). Descends: rank 6 -> 5.
  action freeze = all {
    draftJobs.size() > 0,
    nondet j = draftJobs.oneOf()
    apply(decideFreeze(core, j))
  }

  /// Author thaws a Frozen job to edit again (table line 24) — the
  /// authoring loop; AUTHORING churn (climbs), which is exactly why
  /// per-job liveness is conditional on authors eventually releasing or
  /// revoking (measure.qnt header).
  action unfreeze = all {
    frozenJobs.size() > 0,
    nondet j = frozenJobs.oneOf()
    apply(decideUnfreeze(core, j))
  }

  /// Author releases a Draft or Frozen job into the pipeline (table lines
  /// 21-22, 25-26); Ready/Blocked re-derive. Descends: rank {6,5} -> 4.
  action release = all {
    releasableJobs.size() > 0,
    nondet j = releasableJobs.oneOf()
    apply(decideRelease(core, j))
  }

  /// Author revokes any non-terminal job (table lines 45-48); the atomic
  /// cascade parks every pre-flight transitive dependent with its own desk
  /// task (decideRevoke — the PR 2 gate).
  action revoke = all {
    revocableJobs.size() > 0,
    nondet j = revocableJobs.oneOf()
    apply(decideRevoke(core, j))
  }

  /// Ready -> Working: nondet pick — scheduling/quota is trusted fabric
  /// (charter §2 non-goals: no bespoke scheduler), so there is no slot
  /// count and no queue order. Pending jobs have never spent gas (arrival
  /// grants the full DEADLINE and the authoring phases charge nothing), so
  /// gas >= 1 here whenever init accepted the configuration; the guard
  /// keeps it structural.
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
  /// journaled-actor), not this shared domain layer. PR 2 adds one more
  /// deferred corner: a job revoked OUT of PLanding after "EnqueueLanding"
  /// was emitted could race an in-flight merge — in-model revokedNeverLands
  /// holds because no action delivers a landing resolution to a revoked
  /// job; the real revoke/merge race is deferred with landing mechanics
  /// (PR 5) and the §4 refinement layer, where the observed/actual split
  /// lives.
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
    retryableStalled.size() > 0,
    nondet j = retryableStalled.oneOf()
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
    arrive,
    freeze,
    unfreeze,
    release,
    revoke,
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
  val landingExclusive: bool = liveJobs.forall(j => and {
    jobs.get(j).landings <= 1,
    (jobs.get(j).landings == 1) iff (jobs.get(j).phase == PDone)
  })

  /// REVOKED NEVER LANDS (the PR 2 exclusivity extension): a revoked job
  /// has emitted no landing effect — and never will: PRevoked is absorbing
  /// (terminalsAbsorbing; table lines 45-46), no decider touches a revoked
  /// job's `landings`, and revoke from PLanding clears the job OUT of the
  /// landing boundary before any effect fires. Stated as its own named
  /// invariant because it is the PR 2 gate's exclusivity half, though
  /// state-wise it is a corollary of landingExclusive (landings = 1 iff
  /// Done, landings <= 1, Revoked != Done ⇒ landings = 0) — same
  /// stated-corollary treatment as deskVisibility.
  val revokedNeverLands: bool = liveJobs.forall(j =>
    (jobs.get(j).phase == PRevoked) implies (jobs.get(j).landings == 0))

  /// The two absorbing terminals never transition OUT (table lines 45-46:
  /// `(Done | Revoked, Revoked) => false` — first-match-wins over the
  /// revoke catch-all). Checked against the observed step record: no
  /// transition ever leaves PDone or PRevoked. (v1 proved
  /// terminalIsAbsorbing with Done alone carrying the dynamic content —
  /// model-status §6b; chuggy's PRevoked is reachable, so both terminals
  /// now carry it.)
  val terminalsAbsorbing: bool =
    lastStep.transitions.foldl(true, (b, t) =>
      b and t.from != PDone and t.from != PRevoked)

  /// The human desk is consistent: a named wall iff parked
  /// (Escalated/Stalled), a resume point iff Escalated. (The open-task
  /// flag needs no conjunct any more — it is DERIVED from the phase,
  /// standing rule 3.) PR 2 note: PRevoked passes both iffs with
  /// RsNone/RNone — "Revoked holds nothing" is this invariant plus
  /// tasksWellFormed doing their existing jobs over the new phase.
  val deskConsistent: bool = liveJobs.forall(j => and {
    (jobs.get(j).phase == PEscalated or jobs.get(j).phase == PStalled)
      iff (jobs.get(j).reason != RsNone),
    (jobs.get(j).phase == PEscalated) iff (jobs.get(j).resumeAt != RNone)
  })

  /// The gate-budget wall exists only under Budgeted pricing (the wall
  /// vocabulary is v1-carried; the pricing parameter is charter §2's).
  val gateWallNamed: bool = match GATE_PRICING {
    | Budgeted(_) => true
    | DeadlineOnly => liveJobs.forall(j => jobs.get(j).reason != RsGateBudgetExhausted)
  }

  /// Every account stays a resource: bounded below by 0 (nothing
  /// overdraws) and above by its grant (nothing refunds). PR 2: revoke and
  /// the cascade move through here untouched — no gas charged, no budget
  /// spent, no refund (the no-budget-leakage half of the gate; the exact
  /// account-by-account equality is pinned in tests/chuggy_test.qnt).
  val accountsBounded: bool = liveJobs.forall(j => and {
    jobs.get(j).deadlineLeft >= 0, jobs.get(j).deadlineLeft <= DEADLINE,
    jobs.get(j).reworkLeft >= 0, jobs.get(j).reworkLeft <= REWORK_BUDGET,
    jobs.get(j).gateLeft >= 0, jobs.get(j).gateLeft <= gateBudget(GATE_PRICING)
  })

  /// Task records are exactly the current phase's anatomy: a full task set
  /// (ids 1..N_TASKS) iff Working/Evaluating, empty everywhere else — dead
  /// task state is never carried (derive-don't-store spirit). Covers the
  /// PR 2 phases too: Draft/Frozen jobs have not spawned and PRevoked
  /// "holds nothing" (revoke clears the set even mid-flight).
  val tasksWellFormed: bool = liveJobs.forall(j =>
    if (jobs.get(j).phase == PWorking or jobs.get(j).phase == PEvaluating)
      jobs.get(j).tasks.map(t => t.id) == 1.to(N_TASKS)
    else
      jobs.get(j).tasks == Set())

  /// Arrival's DAG-by-construction survives every step (deps are never
  /// rewritten): each dep points at a known, strictly smaller id.
  val depsAcyclic: bool = liveJobs.forall(j =>
    jobs.get(j).deps.forall(d => liveJobs.contains(d) and d < j))

  /// PR 2 bookkeeping: ids are dense 1..size and never reused — what makes
  /// every ascending-id fold (stuckSet, coveredSet, revokeDoomed, the
  /// cascade's own pass) sound, and what keeps arrivals bounded by N_JOBS.
  val idsDense: bool = and {
    liveJobs == 1.to(liveJobs.size()),
    liveJobs.size() <= N_JOBS
  }

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
    range(1, liveJobs.size() + 1).foldl(Set(), (st, j) =>
      if (or {
        jobs.get(j).phase == PEscalated,
        jobs.get(j).phase == PStalled,
        jobs.get(j).phase == PPending and jobs.get(j).deps.exists(d => st.contains(d))
      }) st.union(Set(j)) else st)

  /// Jobs reachable from an open human task by walking dependency edges
  /// upward: the job's own desk task (derived — hasOpenHumanTask), or a
  /// desk task somewhere in its dependency chain.
  ///
  /// PR 2 note: PRevoked contributes NOTHING here (hasOpenHumanTask
  /// excludes it), so a dependent of a revoked job can only be covered by
  /// its OWN task — which is exactly what the atomic cascade guarantees
  /// (cascadeSafety below): parked dependents are PStalled, hence in
  /// stuckSet AND covered by themselves; the folds needed no change for
  /// the new phases (Draft/Frozen are neither stuck — their progress is
  /// the author's, the named AUTHORING conditionality — nor covering).
  val coveredSet: Set[int] =
    range(1, liveJobs.size() + 1).foldl(Set(), (cov, j) =>
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

  // --- Cascade safety (THE PR 2 gate) ---------------------------------------

  /// Jobs transitively doomed by a revocation: a Revoked job somewhere in
  /// the dependency closure means this job can never unblock (a dep that
  /// is not Done blocks, and PRevoked never becomes PDone). Same
  /// ascending-id fold as stuckSet — deps point strictly downward.
  val revokeDoomed: Set[int] =
    range(1, liveJobs.size() + 1).foldl(Set(), (dset, j) =>
      if (jobs.get(j).deps.exists(d =>
            jobs.get(d).phase == PRevoked or dset.contains(d)))
        dset.union(Set(j)) else dset)

  /// CASCADE SAFETY (deskVisibility's style, revoke's content): every job
  /// transitively stuck behind a Revoked dep is parked with its own open
  /// human task (PStalled, wall dependency_revoked — hasOpenHumanTask
  /// derives the task) or is itself revoked (its author settled it too).
  /// The roadmap gate's "eventually parked" strengthens to ALWAYS-parked
  /// because the cascade is atomic with the revoke (decideRevoke): there
  /// is no reachable in-between state where a doomed job waits invisibly.
  /// No job may wait invisibly forever behind a revoked dep — and since
  /// PRevoked opens no task (the author's settled choice), this invariant
  /// is the coverage deskVisibility cannot provide through the dep itself.
  /// NON-VACUITY: check.sh Stage 9b's second expected-violation run pins a
  /// trace where the cascade actually parks a dependent
  /// (cascadeParkNever), and tests/chuggy_test.qnt walks a 3-job chain
  /// end-to-end.
  val cascadeSafety: bool = revokeDoomed.forall(j => or {
    jobs.get(j).phase == PRevoked,
    jobs.get(j).phase == PStalled and jobs.get(j).reason == RsDependencyRevoked
  })

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
      },
      // AUTHORING (PR 2, measure.qnt header): a job entering the fleet
      // climbs by its whole fresh measure (bounded by the N_JOBS arrival
      // cap)...
      lastStep.label == "job-arrived",
      // ...the unfreeze edit loop climbs one rank (bounded only by author
      // behavior — the named liveness conditionality)...
      lastStep.label == "job-unfrozen",
      // ...and a desk-only revoke is flat: every transition leaves a
      // rank-0 phase (Escalated/Stalled -> Revoked) and the cascade parked
      // nobody. Any cascade park drags a rank>0 phase down, so the
      // condition below then forces strict descent — freeze, release, and
      // every live-rank revoke get NO exemption at all.
      and {
        lastStep.label == "job-revoked",
        lastStep.transitions.foldl(true, (b, t) => b and phaseRank(t.from) == 0)
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

  /// ANTI-VACUITY WITNESS #2 (PR 2), not an invariant of the machine: "no
  /// revoke ever parks a dependent". EXPECTED TO BE VIOLATED (check.sh
  /// Stage 9b's second expected-violation run, pinned seed) — the
  /// violation trace is the machine-level proof that the cascade really
  /// fires on reachable states, so cascadeSafety's green runs are checked
  /// against traces that exercise it (a cascade that never parks would
  /// make cascadeSafety vacuously true wherever revokeDoomed stays empty).
  val cascadeParkNever: bool =
    not(lastStep.label == "job-revoked" and lastStep.transitions.length() > 1)

  /// All safety invariants, for `--invariant=allInvariants`.
  val allInvariants: bool = and {
    landingExclusive,
    revokedNeverLands,
    terminalsAbsorbing,
    deskConsistent,
    gateWallNamed,
    accountsBounded,
    tasksWellFormed,
    depsAcyclic,
    idsDense,
    deskVisibility,
    cascadeSafety,
    measureDescends
  }
}
