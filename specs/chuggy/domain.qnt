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
/// ATOMIC park-cascade (decideRevoke) covering its dependents.
///
/// PR 3 (task-records depth; gate: phase-outcome combinators pinned by a
/// real eval/vocabulary example) is IN. The intake question
/// `eval/vocabulary` was never answered (charter §3), so the real example
/// is EXTRACTED FROM CHUGGERNAUT ITSELF — docs/spec.md §3.3 "Staged
/// progression" + §1.2 Task, the golden fixture
/// staged_eval_short_circuit.yaml (replayed by specs/chuggernaut/tests/
/// conformance/conformance_staged_eval_short_circuit_test.qnt, whose
/// header marks the staged content as gated on exactly this model), and
/// docs/trace-conformance.md §2 — standing in until the intake answer
/// confirms or overrides it (README, PR 3 section). What it gives us:
///   - a job's eval program is an ORDERED LIST OF STAGES; within a stage
///     the tasks fan out in parallel (evaluator `stage:`, default 0);
///   - a stage completes when all its tasks are terminal; every required
///     evaluator passing CREATES the next stage's tasks;
///   - any required failure SHORT-CIRCUITS: later stages are "skipped, not
///     failed, so no task records exist for them" and the reduce proceeds
///     immediately — into chuggy's existing rework/escalation economy;
///   - a rework cycle "restarts from the lowest stage — stages are
///     recomputed per cycle, never resumed mid-sequence";
///   - a single-stage program is byte-for-byte the flat fan-out — the
///     compatibility story that preserves PR 1-2's default shape;
///   - task records are a chronological, RETAINED log with sequential
///     per-job identity.
/// The program is DATA ON THE JOB (charter §2: eval is data, not
/// machinery), authored — it arrives with the Draft, which is exactly why
/// authoring came first; decideEvalStageReduce below is the interpreter.
///
/// What is deliberately NOT here (and which roadmap PR restores it):
///   - Batched + the merge queue it serves (PR 5) — the v1 table's
///     (Frozen, Batched) and (Batched, Frozen|Done) rows (table.qnt lines
///     27-30) are deliberately not transcribed yet; chuggernaut's STAGED
///     MERGE GATE (spec.md §3.3 Merge Gate item 3 — gate stages, the
///     gate-fix fast path) defers WITH it;
///   - multi-repo (PR 4); merge-queue + landing mechanics (PR 5);
///   - scheduler/capacity: NO agent-slot count, NO FIFO ready queue —
///     charter §2 non-goals (no bespoke scheduler) plus the trusted fabric
///     axioms (quota/scheduling): dispatch is a nondet pick among Ready
///     jobs, K8s owns the rest;
///   - below-cycle retry machinery: NO attempt counter, NO per-task
///     budgets, NO work-retries wall — charter §2 non-goals ("no retry
///     machinery below the cycle"); chuggernaut's per-task `work_retries`/
///     `eval_retries` (spec.md §1.2) are exactly that machinery, so the
///     extracted vocabulary does NOT import them (README notes the skip);
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
  /// Task fan-out ceiling (PR 3 re-reading): the Work phase's single
  /// task-set width, AND the per-stage fan-out cap an authored eval program
  /// may declare (charter §2 job anatomy: a SET of possibly-parallel
  /// tasks). PR 1-2 read this as the uniform size of every set; stages made
  /// widths per-stage data, so the const became their bound — the measure's
  /// stageWeight radix needs exactly this cap.
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
  /// PR 3: authored-program length cap — the measure's stage radix
  /// (Bounds.maxStages) and arrival's validity ceiling. Real programs are
  /// short by construction in the extracted vocabulary (chuggernaut
  /// spec.md §3.3: stages are declared per evaluator; even the synthesized
  /// approval gate sits at max+1) — the cap exists for the radix argument,
  /// not as domain vocabulary.
  const MAX_STAGES: int

  /// The measure's bounds, from this instance's consts.
  pure val bounds: Bounds = {
    reworkBudget: REWORK_BUDGET,
    nTasks: N_TASKS,
    maxStages: MAX_STAGES,
    gatePricing: GATE_PRICING
  }

  /// The stage vocabulary an author may draw from: any fan-out 1..N_TASKS,
  /// either combinator (both branches stay exercisable — the PR 1 lesson).
  pure val stageChoices: Set[Stage] =
    tuples(1.to(N_TASKS), Set(CUnanimousPass, CAnyPass))
      .map(t => { fanout: t._1, combinator: t._2 })

  /// Every WELL-FORMED authorable program: non-empty, at most MAX_STAGES
  /// stages, each stage from stageChoices. This set IS the arrival-refusal
  /// rule (programsWellFormed): the empty program, an oversized fan-out,
  /// and an overlong program are not in it, so no arrival can carry one —
  /// the same structural-refusal shape as dependableJobs for deps
  /// (decideArrive's callers guarantee membership; the `arrive` action
  /// draws from exactly this set).
  pure val validPrograms: Set[List[Stage]] =
    1.to(MAX_STAGES).fold(Set([]), (acc, _) =>
      acc.union(acc.map(p => stageChoices.map(s => p.append(s))).flatten()))
      .filter(p => p.length() >= 1)

  /// THE DEFAULT PROGRAM (charter §2 evaluation row: "default combinator:
  /// unanimous pass"; chuggernaut spec.md §3.3: every evaluator defaults to
  /// stage 0, and "a job whose evaluators all share one stage (the
  /// default) is byte-for-byte the single-fan-out behavior, and that is
  /// the compatibility story"): ONE stage, full fan-out, unanimous. A job
  /// carrying this program behaves exactly like the PR 1-2 machine —
  /// pinned in tests/chuggy_test.qnt. PR 3 removed the EVAL_COMBINATOR
  /// const in its favor: a machine-wide combinator parameter was PR 1's
  /// stand-in for eval-as-data; now that the combinator is data on the job
  /// record, a const would be exactly the "machinery" the charter row says
  /// eval is not.
  pure val defaultProgram: List[Stage] =
    [{ fanout: N_TASKS, combinator: CUnanimousPass }]

  /// The job-source seam, now CLOSED by PR 2 exactly as PR 1 promised:
  /// every job the machine ever holds is built here, and the only caller is
  /// decideArrive — a job is born a Draft (v1 vocabulary: authoring starts
  /// at Draft, table.qnt lines 21-22) with its full accounts, and reaches
  /// the released pipeline only through decideRelease. PR 3: the author's
  /// eval PROGRAM arrives with the Draft (eval is data; authoring came
  /// first precisely so programs would have an arrival to ride).
  pure def freshJob(deps_: Set[int], prog: List[Stage]): Job = {
    phase: PDraft,
    deps: deps_,
    program: prog,
    tasks: Set(),
    record: [],
    spawned: 0,
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
  /// transition (golden-trace shaped, standing rule 4). PR 3: from == to is
  /// a real row now — the stage advance records
  /// Evaluating -> Evaluating (chuggernaut spec.md §2.1 line 832).
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
  /// PR 3: the arrival also carries the job's EVAL PROGRAM, validated the
  /// same structural way — callers guarantee prog ∈ validPrograms, so an
  /// empty program, a zero/oversized fan-out, or an overlong program is
  /// REFUSED at authoring time: no reachable state holds one
  /// (programsWellFormed), rather than the interpreter defending against
  /// one mid-flight. The program is immutable after arrival, like deps.
  ///
  /// Dynamic-DAG boundary (charter §3): arrivals are AUTHOR actions — only
  /// the environment action `arrive` calls this decider, and no job-event
  /// decider creates jobs, so the job set grows only by authoring, never by
  /// jobs spawning jobs. Author commands (freeze/unfreeze/release/revoke)
  /// are also guarded by enablement, not absorbed as duplicates: authors
  /// are command sources, not the at-least-once fabric — only fabric events
  /// get idempotent stutter deciders.
  pure def decideArrive(c: Core, deps_: Set[int], prog: List[Stage]): Decision =
    val id = c.jobs.keys().size() + 1
    { rec: { label: "job-arrived", transitions: [], effects: ["CreateDraft"] },
      post: { ...c, jobs: c.jobs.put(id, freshJob(deps_, prog)) } }

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
  /// terminalsAbsorbing). The revoked job settles: rank -> 0, live task set
  /// RETIRED into the record (PR 3: still-running tasks force-closed as
  /// TCancelled — chuggernaut spec.md §1.2 "Revoke closes tasks"; the
  /// record itself is KEPT: provenance survives the author's settlement,
  /// "Revoked runs nothing" ≠ "Revoked remembers nothing"), accounts
  /// UNTOUCHED — revoke charges no gas and spends no budget in either
  /// direction — and reason/resumeAt cleared: PRevoked opens NO human task
  /// (hasOpenHumanTask excludes it; revocation is the author's settled
  /// choice, like PDone).
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
  /// already-settled alone (no duplicate transitions). Pre-flight jobs hold
  /// no live tasks, so the cascade retires nothing on the parked side.
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
          { ...retireLive(c.jobs.get(k)), phase: PRevoked,
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
  /// trace-visible effect. PR 3: the failed set is RETIRED into the
  /// retained record, not dropped — escalation is always reached at a
  /// reduce, so the set is fully resolved and the TCancelled arm of
  /// retireLive never fires here.
  pure def escalate(c: Core, j: int, at: Resume, why: Reason, label: str): Decision =
    move(
      withJob(c, j, { ...retireLive(c.jobs.get(j)), resumeAt: at, reason: why }),
      j, PEscalated, label, ["OpenHumanTask"])

  /// Ready -> Working: launch a cycle. Charges one deadline gas — EVERY
  /// entry to Working does (standing rule 2: no free re-entry; the deadline
  /// is the account that makes the graph valid at all). Work is ONE
  /// task-set phase (kasofsk's anatomy note; chuggernaut spec.md §1.2:
  /// one work task per cycle — Work is not staged), width N_TASKS, ids
  /// sequential within the job (PR 3).
  pure def decideDispatch(c: Core, j: int): Decision =
    val jb = c.jobs.get(j)
    move(
      withJob(c, j, { ...spawnOn(jb, TKWork, N_TASKS),
        deadlineLeft: jb.deadlineLeft - 1 }),
      j, PWorking, "dispatch", ["SpawnWorkTasks"])

  /// A task-completion event for task `tid` of job j (Working or
  /// Evaluating — one decider for both phases' task sets). First write
  /// wins: if the task is not RUNNING IN THE LIVE SET, this is a duplicate
  /// or stale delivery and the decision is a state-identical no-op
  /// (STUTTER set in measure.qnt). PR 3 made the stale arm structural:
  /// task ids are unique across the job's whole history, so a completion
  /// for a task of an earlier stage or incarnation names an id that is
  /// already RETIRED into the record — no live match, no-op BY IDENTITY
  /// (PR 1 had to absorb cross-incarnation staleness into the nondet
  /// verdict of a respawned same-id task; that argument is now needed for
  /// nothing). No phase transition either way — task records resolve
  /// inside the phase.
  pure def decideTaskDone(c: Core, j: int, tid: int, v: Verdict): Decision =
    if (c.jobs.get(j).tasks.exists(t => t.id == tid and t.outcome == TRunning))
      { rec: { label: "task-done", transitions: [], effects: [] },
        post: withJob(c, j, { ...c.jobs.get(j),
          tasks: resolveTask(c.jobs.get(j).tasks, tid,
            match v { | VPass => TPassed | VFail => TFailed }) }) }
    else
      noop(c, "task-done-duplicate")

  /// The Working task set fully resolved: reduce the phase, at CYCLE level
  /// only. Work's phase-outcome combinator is UNANIMOUS PASS — no longer a
  /// placeholder: PR 3 pins it from the extracted vocabulary (chuggernaut
  /// spec.md §1.2: Work runs ONE task per cycle whose success is the
  /// phase's success — unanimous over a singleton; under kasofsk's
  /// parallel task-set generalization, charter §2 job anatomy, the
  /// faithful reading stays "every work task passed"). A pass RETIRES the
  /// work set into the record and spawns the eval program's LOWEST stage
  /// (spec.md §3.3: "creates one task per evaluator in the lowest stage
  /// and fans them out in parallel"). A failed task set is a failed CYCLE
  /// and escalates directly: the fabric has already retried each task
  /// below the cycle (trusted `backoffLimit`, charter §2 fabric row), and
  /// modeling attempts of our own is a §2 non-goal.
  pure def decideWorkReduce(c: Core, j: int): Decision =
    val jb = c.jobs.get(j)
    val retired = retireLive(jb)
    if (jb.tasks.forall(t => t.outcome == TPassed))
      move(
        withJob(c, j, spawnOn(retired, TKEval(0), retired.program[0].fanout)),
        j, PEvaluating, "work-passed", ["SpawnEvalTasks"])
    else
      escalate(c, j, RWorking, RsWorkFailed, "job-escalated work_failed")

  /// THE EVAL-PROGRAM INTERPRETER (PR 3 — the machinery; the program is
  /// data on the job). Fires when the CURRENT stage's task set is fully
  /// resolved (chuggernaut spec.md §3.3: "a stage completes when all its
  /// tasks reach a terminal state"), reads the stage's own combinator off
  /// the program, and takes exactly one of three edges:
  ///
  ///   - stage PASSES, later stage remains -> ADVANCE: retire the stage
  ///     into the record, spawn the next stage's fan-out. The
  ///     Evaluating -> Evaluating transition is chuggernaut's own table row
  ///     (spec.md §2.1 line 832: "a stage completes with every required
  ///     evaluator passing and a later stage remains: create the next
  ///     stage's evaluator tasks"). Descends: stagesLeft -1 dominates the
  ///     spawn (measure.qnt, the PR 3 digit).
  ///   - the FINAL stage passes -> the program passed: PLanding.
  ///   - stage FAILS -> SHORT-CIRCUIT (spec.md §3.3: "the later stages are
  ///     not created — they are skipped, not failed, so no task records
  ///     exist for them — and the eval reduce proceeds immediately"; the
  ///     golden fixture staged_eval_short_circuit.yaml pins exactly this:
  ///     stage-0 fails, stage 1 never launched): straight into the SAME
  ///     rework/escalation economy as PR 1-2 — a budgeted rework cycle
  ///     costs 1 reworkLeft + 1 gas and re-enters Work, and the next
  ///     Evaluation RESTARTS FROM THE LOWEST STAGE ("stages are recomputed
  ///     per cycle, never resumed mid-sequence"); an empty account parks
  ///     the job behind the existing wall (budget wall checked before the
  ///     deadline wall, v1 convention). No new wall, no new account.
  ///
  /// Evaluator-infrastructure death is a TFailed INSIDE the stage — THE
  /// JOB PAYS from the same accounts, no new machinery (charter §2
  /// eval/evaluator-failure). Deliberate abstraction from the extracted
  /// vocabulary, README-noted: chuggernaut §3.3 escalates required INFRA
  /// failures immediately (skipping rework) and distinguishes abort
  /// verdicts; chuggy folds all three into TFailed-fails-the-stage because
  /// the charter row prices them identically — flagged as a question for
  /// the intake confirmation, not silently adopted.
  pure def decideEvalStageReduce(c: Core, j: int): Decision =
    val jb = c.jobs.get(j)
    val s = evalStage(jb.tasks)
    val retired = retireLive(jb)
    if (combine(jb.program[s].combinator, jb.tasks))
      if (s + 1 < jb.program.length())
        move(
          withJob(c, j,
            spawnOn(retired, TKEval(s + 1), retired.program[s + 1].fanout)),
          j, PEvaluating, "eval-stage-passed", ["SpawnEvalTasks"])
      else
        move(
          withJob(c, j, retired),
          j, PLanding, "eval-passed", ["EnqueueLanding"])
    else if (jb.reworkLeft > 0 and jb.deadlineLeft > 0)
      move(
        withJob(c, j, { ...spawnOn(retired, TKWork, N_TASKS),
          reworkLeft: jb.reworkLeft - 1,
          deadlineLeft: jb.deadlineLeft - 1 }),
        j, PWorking, "rework-started eval_failure", ["SpawnWorkTasks"])
    else if (jb.reworkLeft == 0)
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
  /// name. (Chuggernaut's own merge gate runs STAGED — spec.md §3.3 Merge
  /// Gate item 3 — but that structure is deferred to PR 5 with the gate
  /// itself; here the gate stays one abstract outcome.)
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
                withJob(c, j, { ...spawnOn(c.jobs.get(j), TKWork, N_TASKS),
                  gateLeft: c.jobs.get(j).gateLeft - 1,
                  deadlineLeft: c.jobs.get(j).deadlineLeft - 1 }),
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
                withJob(c, j, { ...spawnOn(c.jobs.get(j), TKWork, N_TASKS),
                  deadlineLeft: c.jobs.get(j).deadlineLeft - 1 }),
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
  /// PR 3: the Evaluating resume is A FRESH FAN-OUT OF THE LOWEST STAGE —
  /// chuggernaut spec.md §1.2, escalation Retry semantics: "re-enter
  /// Evaluation against the intact branch ... with a fresh eval fan-out";
  /// stages are never resumed mid-sequence (§3.3). New ids: the retried
  /// tasks are NEW records, the failed ones stay retired in the log.
  pure def decideOpRetry(c: Core, j: int): Decision =
    val jb = c.jobs.get(j)
    val charge = match OP_RETRY_PRICING {
      | RetryCharged => 1
      | RetryFree => if (jb.resumeAt == RWorking) 1 else 0
    }
    val resumed = { ...jb,
      reason: RsNone, resumeAt: RNone,
      deadlineLeft: jb.deadlineLeft - charge }
    match jb.resumeAt {
      | RWorking =>
        move(withJob(c, j, spawnOn(resumed, TKWork, N_TASKS)),
          j, PWorking, "operator-retry", ["SpawnWorkTasks"])
      | REvaluating =>
        move(withJob(c, j, spawnOn(resumed, TKEval(0), jb.program[0].fanout)),
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
  /// GHOST (PR 3): the PREVIOUS state's retained task records, per job —
  /// written by every action, read only by recordMonotone (the
  /// retained-record monotonicity invariant needs one step of history,
  /// exactly like stepDescends needs prevMeasure).
  var prevRecords: int -> List[Task]

  val core: Core = { jobs: jobs }
  val currentMeasure: int = sysMeasure(bounds, jobs)
  /// The current records snapshot the ghost carries forward each step.
  val currentRecords: int -> List[Task] =
    jobs.keys().mapBy(j => jobs.get(j).record)

  /// The live fleet (PR 2): ids are dense 1..size and never reused
  /// (invariant idsDense), so ascending-id folds below stay correct. PR 1's
  /// static `allJobs = 1.to(N_JOBS)` became this — N_JOBS is now the
  /// arrival BOUND, not the fleet size.
  val liveJobs: Set[int] = jobs.keys()

  action apply(d: Decision): bool = all {
    jobs' = d.post.jobs,
    lastStep' = d.rec,
    prevMeasure' = currentMeasure,
    prevRecords' = currentRecords
  }

  // --- Derived waiting room (standing rule 3: derive, don't store) ---------
  // Blocked and Ready are PREDICATES over deps + record, not phases. v1
  // stored both; chuggy stores only PPending and derives the split, so the
  // unblock cascade disappears entirely — there is no Blocked->Ready edge
  // to model or to get wrong. (The open-human-task flag is derived too:
  // measure.qnt hasOpenHumanTask; PR 3's eval-stage index is derived from
  // the live set's kind marks: measure.qnt evalStage.) PR 2 extends them
  // for free: an UNRELEASED dep (Draft/Frozen) is simply a dep that is not
  // Done, so it blocks with no new machinery; the pure bodies live with
  // the deciders (isReadyIn/isBlockedIn) so unit tests can pin exactly
  // that.

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
  /// every job ever created). PR 3 adds `MAX_STAGES >= 1`: a machine that
  /// admits no well-formed eval program admits no jobs either.
  action init = all {
    DEADLINE >= 1,       // charter §2 economy/deadline: required field
    N_TASKS >= 1,        // well-formedness: a phase carries a real task set
    N_JOBS >= 1,         // the arrival bound must admit at least one job
    MAX_STAGES >= 1,     // PR 3: at least one authorable program must exist
    REWORK_BUDGET >= 0,
    gateBudget(GATE_PRICING) >= 0,
    jobs' = Map(),
    lastStep' = { label: "init", transitions: [], effects: [] },
    prevMeasure' = 0,
    prevRecords' = Map()
  }

  // --- actions --------------------------------------------------------------

  /// A new job arrives as a Draft (the environment/author acts), deps a
  /// nondet subset of DEPENDABLE live jobs — released or not (unreleased
  /// deps block via the derived waiting room; tombstones are refused at
  /// authoring time, see decideArrive/dependableJobs) — and (PR 3) its
  /// eval PROGRAM a nondet pick among the WELL-FORMED programs: the
  /// machine explores every authorable program, and ill-formed ones are
  /// refused structurally (validPrograms is the refusal rule). AUTHORING
  /// set in the measure: climbs by the fresh Draft's whole jobMeasure,
  /// bounded by N_JOBS.
  action arrive = all {
    canArrive,
    nondet deps_ = dependableJobs.powerset().oneOf()
    nondet prog = validPrograms.oneOf()
    apply(decideArrive(core, deps_, prog))
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

  /// A task-completion event arrives for ANY task the job EVER SPAWNED —
  /// live (real resolution or duplicate of a resolved one) or already
  /// retired to the record (a stale delivery from an earlier stage or
  /// incarnation). One action models all of it because the fabric is
  /// at-least-once: the machine cannot choose to not receive duplicates.
  ///
  /// Duplicate-adversary SCOPE (PR 3 extension of the PR 1 note): the tid
  /// range below is the job's ENTIRE task history — ids are sequential
  /// within the job and never reused (chuggernaut spec.md §1.2), so a
  /// stale completion from an earlier STAGE or incarnation names a retired
  /// id and no-ops BY IDENTITY (decideTaskDone finds no live running
  /// match). This RETIRES PR 1's weaker absorption argument (a stale
  /// same-id completion was indistinguishable from a fresh nondet verdict
  /// on the respawned set) — staleness is now absorbed structurally, and
  /// the only remaining first-write-wins case is a duplicate delivery for
  /// a LIVE resolved task. A stale landing SUCCESS still implies a success
  /// occurred, and PDone is absorbing (landDuplicate). The observed/actual
  /// split that would make mid-rework duplicates dangerous — a decider
  /// acting on a stale VIEW — is exactly the deferred §4 refinement layer
  /// (reconcile vs journaled-actor), not this shared domain layer. PR 2's
  /// deferred corner stands: a job revoked OUT of PLanding after
  /// "EnqueueLanding" was emitted could race an in-flight merge — in-model
  /// revokedNeverLands holds because no action delivers a landing
  /// resolution to a revoked job; the real revoke/merge race is deferred
  /// with landing mechanics (PR 5) and the §4 refinement layer.
  action taskDone = all {
    taskPhaseJobs.size() > 0,
    nondet j = taskPhaseJobs.oneOf()
    nondet tid = 1.to(jobs.get(j).record.length() + jobs.get(j).tasks.size()).oneOf()
    nondet v = Set(VPass, VFail).oneOf()
    apply(decideTaskDone(core, j, tid, v))
  }

  action workReduce = all {
    reducibleWork.size() > 0,
    nondet j = reducibleWork.oneOf()
    apply(decideWorkReduce(core, j))
  }

  /// The current eval STAGE's task set fully resolved: run the interpreter
  /// over the job's authored program (advance / pass / short-circuit —
  /// decideEvalStageReduce).
  action evalReduce = all {
    reducibleEval.size() > 0,
    nondet j = reducibleEval.oneOf()
    apply(decideEvalStageReduce(core, j))
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
    prevMeasure' = currentMeasure,
    prevRecords' = currentRecords
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
  /// RsNone/RNone — "Revoked runs nothing" is this invariant plus
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
  /// PR 3: stage advances move through here untouched too — stage progress
  /// is priced by the MEASURE's stage digit, not by any account; only a
  /// stage FAILURE (the short-circuit into rework) spends.
  val accountsBounded: bool = liveJobs.forall(j => and {
    jobs.get(j).deadlineLeft >= 0, jobs.get(j).deadlineLeft <= DEADLINE,
    jobs.get(j).reworkLeft >= 0, jobs.get(j).reworkLeft <= REWORK_BUDGET,
    jobs.get(j).gateLeft >= 0, jobs.get(j).gateLeft <= gateBudget(GATE_PRICING)
  })

  /// The LIVE task set is exactly the current phase's anatomy (PR 3
  /// rewrite — this is also the STAGE-INDEX SANITY invariant):
  ///   - PWorking: the single work set — width N_TASKS, all TKWork;
  ///   - PEvaluating: ONE stage's fan-out — uniformly TKEval(s) for a
  ///     single s that indexes INTO the program (0 <= s < |program|), with
  ///     exactly that stage's declared width (the interpreter is running
  ///     the program as written, not improvising);
  ///   - every other phase: empty — dead live-task state is never carried
  ///     (derive-don't-store spirit; Draft/Frozen have not spawned,
  ///     PRevoked runs nothing).
  /// In the task phases the live ids are the contiguous run directly above
  /// the retired record (identity is sequential within the job — the
  /// at-least-once-by-identity argument needs exactly this), and TCancelled
  /// never appears live (it is a retirement mark, not an outcome events
  /// can deliver).
  val tasksWellFormed: bool = liveJobs.forall(j =>
    val jb = jobs.get(j)
    val start = jb.record.length() + 1
    if (jb.phase == PWorking) and {
      jb.tasks.size() == N_TASKS,
      jb.tasks.map(t => t.id) == start.to(start + N_TASKS - 1),
      jb.tasks.forall(t => t.kind == TKWork and t.outcome != TCancelled)
    } else if (jb.phase == PEvaluating)
      val s = evalStage(jb.tasks)
      and {
        s >= 0,
        s < jb.program.length(),
        jb.tasks.forall(t => t.kind == TKEval(s) and t.outcome != TCancelled),
        jb.tasks.size() == jb.program[s].fanout,
        jb.tasks.map(t => t.id) == start.to(start + jb.tasks.size() - 1)
      }
    else jb.tasks == Set())

  /// THE RETAINED RECORD is well-formed (PR 3): entry i carries id i+1
  /// (the chronological log IS the identity order — chuggernaut spec.md
  /// §1.2, sequential within job, 1-indexed), nothing retired is still
  /// running (retirement settles: TPassed/TFailed by verdict, TCancelled
  /// by revoke), and every retired eval task names a stage its job's
  /// program actually has (programs are immutable, so history never dangles).
  val recordWellFormed: bool = liveJobs.forall(j =>
    val jb = jobs.get(j)
    and {
      jb.record.indices().forall(i => jb.record[i].id == i + 1),
      jb.record.indices().forall(i => jb.record[i].outcome != TRunning),
      jb.record.indices().forall(i =>
        match jb.record[i].kind {
          | TKWork => true
          | TKEval(s) => s >= 0 and s < jb.program.length()
        })
    })

  /// RETAINED-RECORD MONOTONICITY (PR 3): the task record is append-only
  /// history — against the previous state (ghost prevRecords), every job's
  /// record still starts with exactly what it was: nothing shrinks,
  /// nothing settled is ever rewritten (outcome, kind, or id). Checked
  /// step-wise like stepDescends; with it, "retained" is a theorem, not a
  /// convention. (Jobs are never deleted, so prevRecords' domain always
  /// survives into liveJobs.)
  val recordMonotone: bool = prevRecords.keys().forall(j => and {
    liveJobs.contains(j),
    jobs.get(j).record.length() >= prevRecords.get(j).length(),
    prevRecords.get(j).indices().forall(i =>
      jobs.get(j).record[i] == prevRecords.get(j)[i])
  })

  /// IDENTITY ACCOUNTING (PR 3, defense in depth): every task a job ever
  /// spawned is STILL somewhere — retired in the record or live in the
  /// set. The ghost spawn counter (measure.qnt Job.spawned, bumped by
  /// every spawnOn) equals record + live exactly, which makes
  /// history-unique sequential identity a machine-checked theorem: a
  /// mutant decider that DROPPED a task set instead of retiring it (e.g.
  /// escalate clearing tasks without the retireLive) would leave spawned
  /// strictly greater in the very next state — invisible to
  /// tasksWellFormed/recordWellFormed (both look at surviving state, not
  /// at what vanished), caught here.
  val idsAccounted: bool = liveJobs.forall(j =>
    jobs.get(j).spawned ==
      jobs.get(j).record.length() + jobs.get(j).tasks.size())

  /// PROGRAM WELL-FORMEDNESS (PR 3): every live job carries a well-formed
  /// eval program — non-empty, at most MAX_STAGES stages, every fan-out in
  /// 1..N_TASKS. Holding in EVERY reachable state is the arrival-refusal
  /// claim made durable: programs enter only through decideArrive (whose
  /// callers draw from validPrograms) and are never rewritten, so an
  /// ill-formed program is refused at authoring time or never exists.
  val programsWellFormed: bool = liveJobs.forall(j =>
    val p = jobs.get(j).program
    and {
      p.length() >= 1,
      p.length() <= MAX_STAGES,
      p.indices().forall(i => p[i].fanout >= 1 and p[i].fanout <= N_TASKS)
    })

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
  /// named STUTTER, CHURN, and AUTHORING sets (measure.qnt header) —
  /// checked by label against the ghost prevMeasure. Under the default
  /// RetryCharged pricing the operator-retry exemption is empty: every
  /// retry pays gas and MUST descend. PR 3 adds NO exemption: the stage
  /// advance (eval-stage-passed) must strictly descend like any other
  /// progress step — that is the stage digit earning its keep.
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

  /// ANTI-VACUITY WITNESS #3 (PR 3), not an invariant of the machine: "no
  /// eval stage ever advances". EXPECTED TO BE VIOLATED (check.sh Stage
  /// 9b's third expected-violation run, pinned seed) — a reachable
  /// eval-stage-passed step is the machine-level proof that multi-stage
  /// programs actually run stage-by-stage on machine traces, so the green
  /// invariant runs above are checked against traces where the stage digit
  /// and the interpreter's advance edge are exercised, not vacuous (a
  /// fleet that only ever drew single-stage programs would never take the
  /// edge). The unit tests walk the advance deterministically; this pins
  /// it as REACHABLE.
  val stageAdvanceNever: bool =
    not(lastStep.label == "eval-stage-passed")

  /// All safety invariants, for `--invariant=allInvariants`.
  val allInvariants: bool = and {
    landingExclusive,
    revokedNeverLands,
    terminalsAbsorbing,
    deskConsistent,
    gateWallNamed,
    accountsBounded,
    tasksWellFormed,
    recordWellFormed,
    recordMonotone,
    idsAccounted,
    programsWellFormed,
    depsAcyclic,
    idsDense,
    deskVisibility,
    cascadeSafety,
    measureDescends
  }
}
