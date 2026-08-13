/// Unit tests over the chuggy deciders and the termination measure
/// (chuggy-charter.md, roadmap PRs 1-3). Everything here is PURE: cores are
/// built by hand, deciders are applied as functions, and the measure is
/// recomputed with explicit Bounds — no init/step machinery, so the tests
/// pin decider behavior independently of the machine's nondet choices.
///
/// What is checked, per the PR 1 test brief:
///   - the measure STRICTLY DECREASES on every transition the descent
///     table (measure.qnt header) claims descends;
///   - the STUTTER-set transitions (duplicate deliveries) leave it exactly
///     unchanged, and the CHURN-set transitions are pinned as the only
///     climbers;
///   - effect-exclusivity at the landing boundary on a happy path AND a
///     duplicate-completion / duplicate-landing path;
///   - every escalation wall carries its name (v1-carried vocabulary), on
///     both GatePricing branches;
///   - both retry-metering branches (charter §2 op-retry row).
///
/// PR 2 additions (authoring lifecycle; gate: revoke cascades proved safe):
///   - arrival/freeze/release strictly descend where the descent table
///     says, and the AUTHORING climbers (arrival, unfreeze) are pinned as
///     climbers;
///   - revoke from EVERY phase the v1 table permits (table.qnt lines
///     47-48), with the desk-only flat cases pinned, and revocableIn false
///     exactly on the absorbing terminals (lines 45-46);
///   - the cascade end-to-end on a 3-job chain; unreleased deps block;
///     revoked never lands; revoke/cascade spend NOTHING.
///
/// PR 3 additions (task-records depth; gate: phase-outcome combinators
/// pinned by the eval vocabulary EXTRACTED from chuggernaut — spec.md §3.3
/// staged evaluation, §1.2 task records, and the golden fixture
/// staged_eval_short_circuit.yaml; standing in until the intake
/// `eval/vocabulary` answer confirms or overrides it):
///   - a two-stage program walks stage-by-stage: the advance is an
///     Evaluating -> Evaluating step (spec.md §2.1 line 832) that STRICTLY
///     DESCENDS (the new stage digit dominates the next fan-out);
///   - a failing stage SHORT-CIRCUITS into the existing rework economy —
///     pays exactly 1 rework + 1 gas, the later stage's tasks are NEVER
///     created ("skipped, not failed, so no task records exist for them"),
///     and the next cycle restarts from the LOWEST stage;
///   - the same short-circuit against empty accounts hits the existing
///     walls (the golden fixture's exact shape: stage-0 fails, stage 1
///     never launched, escalate);
///   - evaluator crash = a TFailed inside the stage = THE JOB PAYS, exact
///     account deltas (charter §2 eval/evaluator-failure);
///   - stale completions from an earlier stage/incarnation NO-OP BY
///     IDENTITY (task ids are sequential within the job, never reused);
///   - task records are RETAINED: the per-job chronological log survives
///     reduces, escalations, and revoke (running tasks force-closed as
///     TCancelled — spec.md §1.2 "Revoke closes tasks");
///   - PROGRAM-AS-DATA at machine level (the PR 1 combinator lesson
///     generalized): two jobs in the SAME machine instance, identical but
///     for their programs, decide differently — combinator and structure
///     both;
///   - validPrograms IS the arrival-refusal rule: the ill-formed programs
///     are not in it.
module chuggy_test {
  import chuggy_measure.* from "../measure"

  // Reference instance: Budgeted(1) gate pricing, charged retries (the
  // charter defaults where the charter names a default). PR 3: programs up
  // to 2 stages; the EVAL_COMBINATOR const is gone — combinators are data
  // on each job's program (the DA instance PR 1-2 used for CAnyPass
  // machine coverage is gone with it: program-as-data tests below get both
  // combinators from ONE instance, which is the point).
  import chuggy_domain(
    N_JOBS = 2, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2
  ) as DB from "../domain"

  // DeadlineOnly gate pricing (the other §2 branch).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = DeadlineOnly, OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2
  ) as DD from "../domain"

  // Free retry metering — v1's model-status §5b churn, kept reproducible
  // by configuration (machine-level coverage: mc_chuggy_retryfree).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryFree,
    MAX_STAGES = 2
  ) as DF from "../domain"

  // A graph WITHOUT a deadline — invalid by charter §2 (economy/deadline).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 0,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2
  ) as DZ from "../domain"

  /// Charter §2, deadline row: a graph without a deadline is INVALID — the
  /// model admits no initial state for it at all.
  run deadlineRequiredTest = DZ::init.fail()

  // The same bounds the instances above carry, for measure recomputation.
  pure val bB: Bounds =
    { reworkBudget: 1, nTasks: 2, maxStages: 2, gatePricing: Budgeted(1) }
  pure val bD: Bounds =
    { reworkBudget: 1, nTasks: 2, maxStages: 2, gatePricing: DeadlineOnly }

  pure def mB(c: Core): int = sysMeasure(bB, c.jobs)
  pure def mD(c: Core): int = sysMeasure(bD, c.jobs)

  // Task-record literals, kept terse: wt = work task, et = eval-stage task.
  pure def wt(i: int, o: TaskOutcome): Task =
    { id: i, kind: TKWork, outcome: o }
  pure def et(i: int, s: int, o: TaskOutcome): Task =
    { id: i, kind: TKEval(s), outcome: o }

  // Programs used throughout. progU2 is exactly DB::defaultProgram (the
  // charter's unanimous single-stage default — the PR 1-2 compatibility
  // shape, chuggernaut spec.md §3.3: "a job whose evaluators all share one
  // stage (the default) is byte-for-byte the single-fan-out behavior").
  pure val progU2: List[Stage] = [{ fanout: 2, combinator: CUnanimousPass }]
  pure val progA2: List[Stage] = [{ fanout: 2, combinator: CAnyPass }]
  pure val progStaged: List[Stage] =
    [{ fanout: 1, combinator: CUnanimousPass },
     { fanout: 2, combinator: CAnyPass }]

  run defaultProgramIsTheCharterDefaultTest = assert(and {
    DB::defaultProgram == progU2,
    DB::validPrograms.contains(DB::defaultProgram)
  })

  /// validPrograms IS the arrival-refusal rule (programs must be non-empty
  /// and valid or arrival refuses): the ill-formed shapes are simply not
  /// authorable. At N_TASKS = 2, MAX_STAGES = 2 there are exactly 4 stage
  /// choices, hence 4 + 16 = 20 programs.
  run validProgramsRefusalTest = assert(and {
    DB::validPrograms.contains(progU2),
    DB::validPrograms.contains(progStaged),
    not(DB::validPrograms.contains([])),                                    // empty program
    not(DB::validPrograms.contains([{ fanout: 0, combinator: CUnanimousPass }])), // zero fan-out
    not(DB::validPrograms.contains([{ fanout: 3, combinator: CUnanimousPass }])), // fan-out > N_TASKS
    not(DB::validPrograms.contains(                                          // length > MAX_STAGES
      [{ fanout: 1, combinator: CUnanimousPass },
       { fanout: 1, combinator: CUnanimousPass },
       { fanout: 1, combinator: CUnanimousPass }])),
    DB::validPrograms.size() == 20
  })

  // === The happy path, decision by decision ================================
  // PR 2: the path STARTS at authoring — the fleet is empty, job 1 arrives
  // as a Draft (freshJob seam), is frozen, and released; job 2 arrives as
  // a Draft depending on 1 and stays unreleased throughout. PR 3: job 1
  // carries the DEFAULT program, and its task ids run 1..4 across the
  // whole history (work 1,2 then eval-stage-0 3,4 — sequential within the
  // job, chuggernaut spec.md §1.2).

  pure val cEmpty: Core = { jobs: Map() }
  pure val dArr1 = DB::decideArrive(cEmpty, Set(), DB::defaultProgram)
  pure val cA1 = dArr1.post                        // job 1: Draft
  pure val dArr2 = DB::decideArrive(cA1, Set(1), DB::defaultProgram)
  pure val cA2 = dArr2.post                        // job 2: Draft, dep {1}
  pure val dFreeze = DB::decideFreeze(cA2, 1)
  pure val cFroz = dFreeze.post                    // job 1: Frozen
  pure val dRelease = DB::decideRelease(cFroz, 1)

  pure val c0: Core = dRelease.post                // job 1: Pending, job 2: Draft
  pure val dDispatch = DB::decideDispatch(c0, 1)   // spawns TKWork ids 1,2
  pure val c1 = dDispatch.post
  pure val dWork1 = DB::decideTaskDone(c1, 1, 1, VPass)
  pure val c2 = dWork1.post
  pure val dWork2 = DB::decideTaskDone(c2, 1, 2, VPass)
  pure val c3 = dWork2.post
  pure val dWorkReduce = DB::decideWorkReduce(c3, 1)  // retires 1,2; spawns TKEval(0) 3,4
  pure val c4 = dWorkReduce.post
  pure val dEval1 = DB::decideTaskDone(c4, 1, 3, VPass)
  pure val c5 = dEval1.post
  pure val dEval2 = DB::decideTaskDone(c5, 1, 4, VPass)
  pure val c6 = dEval2.post
  pure val dEvalReduce = DB::decideEvalStageReduce(c6, 1)  // final (only) stage passes
  pure val c7 = dEvalReduce.post
  pure val dLand = DB::decideLand(c7, 1, LandAdvanceDefault)
  pure val c8 = dLand.post

  /// Every decision on the happy path strictly descends the measure —
  /// dispatch (gas), task completions (task count), both phase reductions
  /// (rank), the landing (rank).
  run happyPathMeasureDescendsTest = assert(and {
    mB(c1) < mB(c0),
    mB(c2) < mB(c1),
    mB(c3) < mB(c2),
    mB(c4) < mB(c3),
    mB(c5) < mB(c4),
    mB(c6) < mB(c5),
    mB(c7) < mB(c6),
    mB(c8) < mB(c7)
  })

  /// The records are golden-trace shaped with the phase flips where — and
  /// only where — the anatomy says (task completions flip no phase).
  run happyPathRecordsTest = assert(and {
    dDispatch.rec.label == "dispatch",
    dDispatch.rec.transitions == [{ job: 1, from: PPending, to: PWorking }],
    dWork1.rec.label == "task-done",
    dWork1.rec.transitions == [],
    dWorkReduce.rec.label == "work-passed",
    dWorkReduce.rec.transitions == [{ job: 1, from: PWorking, to: PEvaluating }],
    dEvalReduce.rec.label == "eval-passed",
    dEvalReduce.rec.transitions == [{ job: 1, from: PEvaluating, to: PLanding }],
    dLand.rec.label == "job-done",
    dLand.rec.transitions == [{ job: 1, from: PLanding, to: PDone }]
  })

  /// RETAINED TASK RECORDS (PR 3): at Done, job 1's chronological log holds
  /// its WHOLE anatomy — the work set then the eval stage, ids sequential,
  /// outcomes settled and never overwritten (chuggernaut spec.md §1.2:
  /// "tasks form a chronological log"). The single-stage default program's
  /// history is byte-for-byte what the PR 1-2 machine would have produced
  /// had it retained anything — the compatibility story, now with
  /// provenance the golden traces can carry.
  run happyPathRetainedRecordTest = assert(and {
    c8.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TPassed), et(4, 0, TPassed)],
    c8.jobs.get(1).tasks == Set(),
    // Intermediate shape: after the work reduce the work set is already
    // retired and the eval stage is live above it.
    c4.jobs.get(1).record == [wt(1, TPassed), wt(2, TPassed)],
    c4.jobs.get(1).tasks == Set(et(3, 0, TRunning), et(4, 0, TRunning))
  })

  /// IDENTITY ACCOUNTING (PR 3 defense-in-depth, domain.qnt idsAccounted):
  /// along the fully decider-built happy path the ghost spawn counter
  /// tracks every fan-out and always equals retired + live — the equality
  /// a retirement-dropping mutant would break. (The machine invariant
  /// checks it on every reachable state; this pins the counter's exact
  /// values.)
  pure def accounted(c: Core): bool =
    c.jobs.get(1).spawned ==
      c.jobs.get(1).record.length() + c.jobs.get(1).tasks.size()

  run happyPathIdsAccountedTest = assert(and {
    cA1.jobs.get(1).spawned == 0,          // a Draft has spawned nothing
    c1.jobs.get(1).spawned == 2,           // the work fan-out
    accounted(c1),
    c4.jobs.get(1).spawned == 4,           // + eval stage 0's fan-out
    accounted(c4),
    c8.jobs.get(1).spawned == 4,           // Done: all retired, none lost
    accounted(c8)
  })

  /// EFFECT EXCLUSIVITY, happy path (charter §2, effect-only exclusivity):
  /// exactly one landing effect, exactly at Done.
  run effectExclusivityHappyPathTest = assert(and {
    c8.jobs.get(1).phase == PDone,
    c8.jobs.get(1).landings == 1,
    dLand.rec.effects == ["AdvanceDefault"]
  })

  /// The two landing SUCCESS outcomes are distinct, named effects — v1's
  /// one conformance divergence, pinned from day one (charter §2 landing
  /// row).
  run landingOutcomesDistinctTest = assert(and {
    DB::decideLand(c7, 1, LandAdvanceDefault).rec.effects == ["AdvanceDefault"],
    DB::decideLand(c7, 1, LandSquashMerge).rec.effects == ["SquashMerge"],
    DB::decideLand(c7, 1, LandSquashMerge).post.jobs.get(1).phase == PDone,
    DB::decideLand(c7, 1, LandSquashMerge).post.jobs.get(1).landings == 1
  })

  // === At-least-once: duplicates are idempotent stutters ===================

  /// A duplicate completion for an already-resolved LIVE task (even with a
  /// CONTRADICTING verdict — first write wins) changes nothing: no state,
  /// no effects, no measure movement. The dropped no-double-pods axiom,
  /// honored idempotently (charter §2 fabric row).
  run duplicateTaskDoneIdempotentTest = assert(and {
    DB::decideTaskDone(c2, 1, 1, VFail).post == c2,
    DB::decideTaskDone(c2, 1, 1, VFail).rec.label == "task-done-duplicate",
    DB::decideTaskDone(c2, 1, 1, VFail).rec.effects == [],
    mB(DB::decideTaskDone(c2, 1, 1, VFail).post) == mB(c2)
  })

  /// STALE-STAGE / STALE-INCARNATION completions no-op BY IDENTITY (PR 3):
  /// ids are sequential within the job and never reused, so a completion
  /// for a task retired into the record — here work task 1 (an earlier
  /// incarnation) and eval task 3 delivered AFTER the eval stage retired —
  /// finds no live running match and absorbs as the duplicate stutter,
  /// whatever verdict it carries. (PR 1 had to absorb the same-id case
  /// into the respawned set's nondet verdict; identity retired that
  /// argument — the honest extension of the duplicate-adversary scope.)
  run staleStageCompletionNoopsTest = assert(and {
    // c4: eval stage 0 live (ids 3,4); work ids 1,2 retired.
    DB::decideTaskDone(c4, 1, 1, VFail).post == c4,
    DB::decideTaskDone(c4, 1, 1, VFail).rec.label == "task-done-duplicate",
    // c7: Landing, everything retired; a stale eval completion no-ops.
    DB::decideTaskDone(c7, 1, 3, VFail).post == c7,
    DB::decideTaskDone(c7, 1, 3, VFail).rec.label == "task-done-duplicate",
    mB(DB::decideTaskDone(c4, 1, 1, VFail).post) == mB(c4)
  })

  /// EFFECT EXCLUSIVITY, duplicate-landing path: a re-delivered landing
  /// event for a Done job emits NOTHING — exactly-once is proved at the
  /// landing boundary and nowhere else.
  run duplicateLandExclusiveTest = assert(and {
    DB::decideLandDuplicate(c8, 1).post == c8,
    DB::decideLandDuplicate(c8, 1).rec.label == "land-duplicate",
    DB::decideLandDuplicate(c8, 1).rec.effects == [],
    DB::decideLandDuplicate(c8, 1).post.jobs.get(1).landings == 1,
    mB(DB::decideLandDuplicate(c8, 1).post) == mB(c8)
  })

  // === The work wall: cycle-level, no below-cycle retries ==================

  pure def oneFailedW: Set[Task] = Set(wt(1, TFailed), wt(2, TPassed))

  /// A failed Work task set escalates DIRECTLY at cycle level — there is
  /// no same-cycle retry branch to take: below-cycle retries are the
  /// fabric's trusted backoffLimit (charter §2 fabric row) and modeling
  /// them is a §2 non-goal ("no retry machinery below the cycle").
  /// PR 3: the failed set is RETIRED, outcomes intact — the record shows
  /// WHICH task failed, provenance the desk can read.
  pure val cWorkFail: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PWorking, deadlineLeft: 2, tasks: oneFailedW }) }
  pure val dWorkFail = DB::decideWorkReduce(cWorkFail, 1)

  run workFailedWallTest = assert(and {
    dWorkFail.rec.label == "job-escalated work_failed",
    dWorkFail.post.jobs.get(1).phase == PEscalated,
    dWorkFail.post.jobs.get(1).reason == RsWorkFailed,
    dWorkFail.post.jobs.get(1).resumeAt == RWorking,
    hasOpenHumanTask(dWorkFail.post.jobs.get(1)),
    dWorkFail.rec.effects == ["OpenHumanTask"],
    dWorkFail.post.jobs.get(1).record == [wt(1, TFailed), wt(2, TPassed)],
    dWorkFail.post.jobs.get(1).tasks == Set(),
    mB(dWorkFail.post) < mB(cWorkFail)
  })

  // === The middle loop (budgeted eval rework) and its two walls ============

  pure def oneFailedE0: Set[Task] = Set(et(1, 0, TFailed), et(2, 0, TPassed))

  /// Eval rework — the SHORT-CIRCUIT priced (single-stage program, so the
  /// short-circuit and the reduce coincide; the staged case is below):
  /// 1 rework budget + 1 gas buy a new cycle; both accounts (and the
  /// measure) descend. TFailed here also covers evaluator-infra death —
  /// the job pays, one account (charter §2 eval/evaluator-failure).
  pure val cEvalFail: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PEvaluating, reworkLeft: 1, deadlineLeft: 2, tasks: oneFailedE0 }) }
  pure val dEvalRework = DB::decideEvalStageReduce(cEvalFail, 1)

  run evalReworkDescendsTest = assert(and {
    dEvalRework.rec.label == "rework-started eval_failure",
    dEvalRework.post.jobs.get(1).phase == PWorking,
    dEvalRework.post.jobs.get(1).reworkLeft == 0,
    dEvalRework.post.jobs.get(1).deadlineLeft == 1,
    // The failed stage is retired; the rework cycle's work set spawns at
    // the NEXT ids (3,4) — new records, not overwrites.
    dEvalRework.post.jobs.get(1).record == [et(1, 0, TFailed), et(2, 0, TPassed)],
    dEvalRework.post.jobs.get(1).tasks == Set(wt(3, TRunning), wt(4, TRunning)),
    mB(dEvalRework.post) < mB(cEvalFail)
  })

  /// Budget wall (checked before the deadline wall, v1 convention).
  pure val cReworkWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PEvaluating, reworkLeft: 0, deadlineLeft: 2, tasks: oneFailedE0 }) }
  pure val dReworkWall = DB::decideEvalStageReduce(cReworkWall, 1)

  /// Deadline wall: budget remains but the gas is gone.
  pure val cEvalGasWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PEvaluating, reworkLeft: 1, deadlineLeft: 0, tasks: oneFailedE0 }) }
  pure val dEvalGasWall = DB::decideEvalStageReduce(cEvalGasWall, 1)

  run evalWallsNamedTest = assert(and {
    dReworkWall.rec.label == "job-escalated rework_budget_exhausted",
    dReworkWall.post.jobs.get(1).reason == RsReworkBudgetExhausted,
    dReworkWall.post.jobs.get(1).resumeAt == REvaluating,
    mB(dReworkWall.post) < mB(cReworkWall),
    dEvalGasWall.rec.label == "job-escalated job_deadline_exceeded",
    dEvalGasWall.post.jobs.get(1).reason == RsDeadlineExceeded,
    mB(dEvalGasWall.post) < mB(cEvalGasWall)
  })

  // === PR 3: THE STAGED PROGRAM, walked stage by stage =====================
  // progStaged = [{1, unanimous}, {2, any}] on the reference instance. The
  // walk mirrors chuggernaut spec.md §3.3 "Staged progression" edge by
  // edge; the short-circuit mirrors the golden fixture
  // staged_eval_short_circuit.yaml (replayed for v1 by specs/chuggernaut/
  // tests/conformance/conformance_staged_eval_short_circuit_test.qnt,
  // whose header gates the staged content on exactly this model).

  pure def allPassedW: Set[Task] = Set(wt(1, TPassed), wt(2, TPassed))

  pure val cStagedWork: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progStaged),
    phase: PWorking, deadlineLeft: 2, tasks: allPassedW }) }
  // Work passes -> spawn the LOWEST stage: fan-out 1, id 3.
  pure val dToEval = DB::decideWorkReduce(cStagedWork, 1)
  pure val cS0 = dToEval.post
  // Stage 0's one task passes.
  pure val dS0Done = DB::decideTaskDone(cS0, 1, 3, VPass)
  // THE ADVANCE: stage 0 passed, stage 1 remains -> Evaluating ->
  // Evaluating (chuggernaut spec.md §2.1 line 832), next fan-out spawns.
  pure val dAdvance = DB::decideEvalStageReduce(dS0Done.post, 1)
  pure val cS1 = dAdvance.post
  // Stage 1 (CAnyPass, fan-out 2): one pass, one fail -> stage passes.
  pure val dS1a = DB::decideTaskDone(cS1, 1, 4, VPass)
  pure val dS1b = DB::decideTaskDone(dS1a.post, 1, 5, VFail)
  pure val dStagedFinal = DB::decideEvalStageReduce(dS1b.post, 1)

  /// The advance edge, exactly: label eval-stage-passed, an Evaluating ->
  /// Evaluating transition, the next stage's fan-out spawned at fresh ids,
  /// the passed stage retired — and STRICT DESCENT (the stage digit
  /// dominates the fresh fan-out: measure.qnt's PR 3 digit-order argument,
  /// machine-checked here).
  run stageAdvanceDescendsTest = assert(and {
    dAdvance.rec.label == "eval-stage-passed",
    dAdvance.rec.transitions == [{ job: 1, from: PEvaluating, to: PEvaluating }],
    dAdvance.rec.effects == ["SpawnEvalTasks"],
    cS1.jobs.get(1).phase == PEvaluating,
    cS1.jobs.get(1).tasks == Set(et(4, 1, TRunning), et(5, 1, TRunning)),
    cS1.jobs.get(1).record == [wt(1, TPassed), wt(2, TPassed), et(3, 0, TPassed)],
    // No account moved: stage progress is priced by the measure digit, not
    // by gas or budget.
    cS1.jobs.get(1).deadlineLeft == 2,
    cS1.jobs.get(1).reworkLeft == 1,
    mB(cS1) < mB(dS0Done.post)
  })

  /// The FINAL stage passing lands the program: eval-passed, everything
  /// retired, the full anatomy in the log (per-stage combinators applied —
  /// stage 1's CAnyPass passed on a mixed set).
  run stagedProgramPassesTest = assert(and {
    dStagedFinal.rec.label == "eval-passed",
    dStagedFinal.rec.transitions == [{ job: 1, from: PEvaluating, to: PLanding }],
    dStagedFinal.post.jobs.get(1).tasks == Set(),
    dStagedFinal.post.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TPassed),
       et(4, 1, TPassed), et(5, 1, TFailed)],
    mB(dStagedFinal.post) < mB(dS1b.post)
  })

  // --- The short-circuit: stage 0 fails, stage 1 is never created ----------

  pure val dS0Fail = DB::decideTaskDone(cS0, 1, 3, VFail)
  pure val dShort = DB::decideEvalStageReduce(dS0Fail.post, 1)
  pure val cAfterShort = dShort.post

  /// SHORT-CIRCUIT ROUTES TO REWORK AND PAYS CORRECTLY (chuggernaut
  /// spec.md §3.3: "the later stages are not created — they are skipped,
  /// not failed, so no task records exist for them — and the eval reduce
  /// proceeds immediately"): the failing stage buys a rework cycle at the
  /// SAME price as the flat case — exactly 1 rework + 1 gas, nothing else
  /// — and the record holds NO stage-1 task, ever.
  run shortCircuitRoutesToReworkTest = assert(and {
    dShort.rec.label == "rework-started eval_failure",
    dShort.rec.transitions == [{ job: 1, from: PEvaluating, to: PWorking }],
    cAfterShort.jobs.get(1).reworkLeft == 0,       // paid 1 rework
    cAfterShort.jobs.get(1).deadlineLeft == 1,     // paid 1 gas
    cAfterShort.jobs.get(1).gateLeft == 1,         // gate untouched
    // "no task records exist for them": stage 1 never spawned.
    cAfterShort.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TFailed)],
    cAfterShort.jobs.get(1).record.indices().forall(i =>
      cAfterShort.jobs.get(1).record[i].kind != TKEval(1)),
    cAfterShort.jobs.get(1).tasks == Set(wt(4, TRunning), wt(5, TRunning)),
    mB(cAfterShort) < mB(dS0Fail.post)
  })

  /// The rework cycle RESTARTS FROM THE LOWEST STAGE (spec.md §3.3:
  /// "stages are recomputed per cycle, never resumed mid-sequence"): after
  /// the rework's work set passes, the next Evaluation spawns stage 0
  /// again — never stage 1.
  pure val dReworkW1 = DB::decideTaskDone(cAfterShort, 1, 4, VPass)
  pure val dReworkW2 = DB::decideTaskDone(dReworkW1.post, 1, 5, VPass)
  pure val dBackToEval = DB::decideWorkReduce(dReworkW2.post, 1)

  run reworkRestartsLowestStageTest = assert(and {
    dBackToEval.rec.label == "work-passed",
    dBackToEval.post.jobs.get(1).tasks == Set(et(6, 0, TRunning)),
    dBackToEval.post.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TFailed),
       wt(4, TPassed), wt(5, TPassed)]
  })

  /// The golden fixture's exact shape (staged_eval_short_circuit.yaml:
  /// "staged eval: stage-0 fails -> stage 1 never launched -> escalate",
  /// REWORK_BUDGET = 0 there): the same short-circuit against an empty
  /// rework account hits the EXISTING wall — stage 1 remains unlaunched,
  /// no new wall, no new account.
  pure val cStagedNoBudget: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progStaged),
    phase: PEvaluating, reworkLeft: 0, deadlineLeft: 2,
    record: [wt(1, TPassed), wt(2, TPassed)],
    tasks: Set(et(3, 0, TFailed)) }) }
  pure val dStagedWall = DB::decideEvalStageReduce(cStagedNoBudget, 1)

  run stagedShortCircuitEscalatesTest = assert(and {
    dStagedWall.rec.label == "job-escalated rework_budget_exhausted",
    dStagedWall.post.jobs.get(1).phase == PEscalated,
    dStagedWall.post.jobs.get(1).resumeAt == REvaluating,
    dStagedWall.post.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TFailed)],
    dStagedWall.post.jobs.get(1).record.indices().forall(i =>
      dStagedWall.post.jobs.get(1).record[i].kind != TKEval(1)),
    mB(dStagedWall.post) < mB(cStagedNoBudget)
  })

  /// EVALUATOR CRASH IN A STAGE = THE JOB PAYS (charter §2
  /// eval/evaluator-failure): evaluator-infrastructure death is a TFailed
  /// INSIDE the stage — indistinguishable at the machine's grain from a
  /// failed verdict, deliberately (one account, no new machinery; the
  /// chuggernaut distinction — infra failures escalate immediately, §3.3 —
  /// is a README-noted question for the intake confirmation, not silently
  /// adopted). The stage short-circuits and the JOB's accounts drain:
  /// exactly 1 rework + 1 gas, same as any product failure.
  run evaluatorCrashJobPaysTest = assert(and {
    // dShort IS the crash case read as infra death: same TFailed, same
    // decision. Pin the account deltas as the claim.
    cStagedWork.jobs.get(1).reworkLeft - cAfterShort.jobs.get(1).reworkLeft == 1,
    cStagedWork.jobs.get(1).deadlineLeft - cAfterShort.jobs.get(1).deadlineLeft == 1,
    cStagedWork.jobs.get(1).gateLeft == cAfterShort.jobs.get(1).gateLeft
  })

  /// Duplicate stale-stage completion, staged edition: while stage 1 is
  /// live (ids 4,5), a re-delivered completion for RETIRED stage-0 task 3
  /// — even with a contradicting verdict — no-ops by identity.
  run staleStageDuplicateNoopsTest = assert(and {
    DB::decideTaskDone(cS1, 1, 3, VFail).post == cS1,
    DB::decideTaskDone(cS1, 1, 3, VFail).rec.label == "task-done-duplicate",
    mB(DB::decideTaskDone(cS1, 1, 3, VFail).post) == mB(cS1)
  })

  // === PROGRAM-AS-DATA at machine level (the PR 1 lesson generalized) ======
  // ONE machine instance (DB), two jobs identical but for the program on
  // their record: different decisions. PR 1-2 needed a separate machine
  // instantiation (EVAL_COMBINATOR) to show this; the program made it what
  // the charter said it is — data.

  pure val mixedE0: Set[Task] = Set(et(1, 0, TPassed), et(2, 0, TFailed))
  pure val allFailedE0: Set[Task] = Set(et(1, 0, TFailed), et(2, 0, TFailed))

  pure val cMixedAny: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progA2),
    phase: PEvaluating, tasks: mixedE0, deadlineLeft: 2 }) }
  pure val cMixedUna: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PEvaluating, tasks: mixedE0, deadlineLeft: 2 }) }

  run programAsDataCombinatorTest = assert(and {
    DB::decideEvalStageReduce(cMixedAny, 1).rec.label == "eval-passed",
    DB::decideEvalStageReduce(cMixedAny, 1).post.jobs.get(1).phase == PLanding,
    DB::decideEvalStageReduce(cMixedUna, 1).rec.label == "rework-started eval_failure",
    DB::decideEvalStageReduce(cMixedUna, 1).post.jobs.get(1).phase == PWorking,
    DB::decideEvalStageReduce(cMixedUna, 1).post.jobs.get(1).deadlineLeft == 1
  })

  /// Program STRUCTURE is data too: the same passed work set spawns a
  /// 2-wide flat fan-out under the default program but a 1-wide stage-0
  /// under the staged program — the machine's very next task anatomy is
  /// decided by the program on the record.
  pure val cFlatWork: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PWorking, deadlineLeft: 2, tasks: allPassedW }) }

  run programAsDataStructureTest = assert(and {
    DB::decideWorkReduce(cFlatWork, 1).post.jobs.get(1).tasks ==
      Set(et(3, 0, TRunning), et(4, 0, TRunning)),
    DB::decideWorkReduce(cStagedWork, 1).post.jobs.get(1).tasks ==
      Set(et(3, 0, TRunning))
  })

  /// Both branches of the combinator vocabulary are semantically distinct
  /// (charter §2: unanimous pass is only the DEFAULT), at the pure grain.
  run combinatorBranchesTest = assert(and {
    combine(CUnanimousPass, Set(et(1, 0, TPassed), et(2, 0, TPassed))),
    not(combine(CUnanimousPass, mixedE0)),
    combine(CAnyPass, mixedE0),
    not(combine(CAnyPass, allFailedE0))
  })

  /// All-failed still walls under CAnyPass (a program is not "always
  /// pass"): the rework path is taken.
  pure val cFailAny: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progA2),
    phase: PEvaluating, tasks: allFailedE0, deadlineLeft: 2 }) }

  run anyPassNotAlwaysPassTest = assert(
    DB::decideEvalStageReduce(cFailAny, 1).rec.label == "rework-started eval_failure")

  // === The outer loop, priced per GatePricing (charter §2) =================

  /// Budgeted branch: a landing failure spends 1 gate budget AND 1 gas.
  pure val cGateB: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PLanding, gateLeft: 1, deadlineLeft: 2 }) }
  pure val dGateRework = DB::decideLand(cGateB, 1, LandFailed)

  run gateReworkBudgetedDescendsTest = assert(and {
    dGateRework.rec.label == "rework-started gate_failure",
    dGateRework.post.jobs.get(1).phase == PWorking,
    dGateRework.post.jobs.get(1).gateLeft == 0,
    dGateRework.post.jobs.get(1).deadlineLeft == 1,
    // PR 3: the gate rework's work set is a fresh incarnation at fresh ids.
    dGateRework.post.jobs.get(1).tasks == Set(wt(1, TRunning), wt(2, TRunning)),
    mB(dGateRework.post) < mB(cGateB)
  })

  /// The gate-budget wall — a reason that EXISTS ONLY under Budgeted.
  pure val cGateWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PLanding, gateLeft: 0, deadlineLeft: 2 }) }
  pure val dGateWall = DB::decideLand(cGateWall, 1, LandFailed)

  /// Budgeted branch, deadline wall: gate budget remains, gas is gone.
  pure val cGateGasWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2),
    phase: PLanding, gateLeft: 1, deadlineLeft: 0 }) }
  pure val dGateGasWall = DB::decideLand(cGateGasWall, 1, LandFailed)

  run gateWallsNamedTest = assert(and {
    dGateWall.rec.label == "job-escalated gate_budget_exhausted",
    dGateWall.post.jobs.get(1).reason == RsGateBudgetExhausted,
    dGateWall.post.jobs.get(1).resumeAt == RLanding,
    mB(dGateWall.post) < mB(cGateWall),
    dGateGasWall.rec.label == "job-escalated job_deadline_exceeded",
    dGateGasWall.post.jobs.get(1).reason == RsDeadlineExceeded,
    mB(dGateGasWall.post) < mB(cGateGasWall)
  })

  /// DeadlineOnly branch: a landing failure spends gas alone (v1's shape;
  /// the required deadline is the only meter), and the gate-budget wall
  /// can never be the reason.
  pure val cGateD: Core = { jobs: Map(1 -> { ...DD::freshJob(Set(), progU2),
    phase: PLanding, deadlineLeft: 2 }) }
  pure val dGateD = DD::decideLand(cGateD, 1, LandFailed)

  pure val cGateDWall: Core = { jobs: Map(1 -> { ...DD::freshJob(Set(), progU2),
    phase: PLanding, deadlineLeft: 0 }) }
  pure val dGateDWall = DD::decideLand(cGateDWall, 1, LandFailed)

  run gateReworkDeadlineOnlyTest = assert(and {
    dGateD.rec.label == "rework-started gate_failure",
    dGateD.post.jobs.get(1).phase == PWorking,
    dGateD.post.jobs.get(1).gateLeft == 0,      // no gate account to spend
    dGateD.post.jobs.get(1).deadlineLeft == 1,
    mD(dGateD.post) < mD(cGateD),
    dGateDWall.rec.label == "job-escalated job_deadline_exceeded",
    dGateDWall.post.jobs.get(1).reason == RsDeadlineExceeded,
    mD(dGateDWall.post) < mD(cGateDWall)
  })

  // === The human desk: stall, retries, and the metering parameter ==========

  /// Pre-work invalidation parks the job (rank 4 -> 0: descends, free) …
  /// (PR 2: freshJob births a Draft, so the RELEASED fixture overrides
  /// the phase — revalFail is a Ready-phase edge.)
  pure val cFresh: Core = { jobs: Map(1 -> { ...DB::freshJob(Set(), progU2), phase: PPending }) }
  pure val dStall = DB::decideRevalFail(cFresh, 1)

  /// … and the operator's stalled-retry is the CHURN set's canonical
  /// member: the measure CLIMBS (nothing was spent, nothing is charged) —
  /// pinned here so the descent claim's exemption list stays honest.
  pure val dStallRetry = DB::decideStalledRetry(dStall.post, 1)

  run stallAndRetryClassifiedTest = assert(and {
    dStall.rec.label == "job-stalled revalidation_failed",
    dStall.post.jobs.get(1).phase == PStalled,
    dStall.post.jobs.get(1).reason == RsRevalidationFailed,
    hasOpenHumanTask(dStall.post.jobs.get(1)),     // derived, not stored
    mB(dStall.post) < mB(cFresh),
    dStallRetry.rec.label == "stalled-retry",
    dStallRetry.post.jobs.get(1).phase == PPending,
    dStallRetry.post.jobs.get(1).reason == RsNone,
    not(hasOpenHumanTask(dStallRetry.post.jobs.get(1))),
    mB(dStallRetry.post) > mB(dStall.post)  // CHURN: climbs, by design
  })

  /// Charged retry metering (the charter default): EVERY resume pays 1 gas,
  /// so operator retries descend the measure — v1's §5b livelock priced
  /// away.
  pure val escLanding: Job = { ...DB::freshJob(Set(), progU2),
    phase: PEscalated, resumeAt: RLanding, reason: RsDeadlineExceeded,
    deadlineLeft: 2 }
  pure val cEscB: Core = { jobs: Map(1 -> escLanding) }
  pure val dRetryCharged = DB::decideOpRetry(cEscB, 1)

  pure val escWorking: Job = { ...DB::freshJob(Set(), progU2),
    phase: PEscalated, resumeAt: RWorking, reason: RsWorkFailed,
    deadlineLeft: 2 }
  pure val dRetryChargedWork = DB::decideOpRetry({ jobs: Map(1 -> escWorking) }, 1)

  run opRetryChargedDescendsTest = assert(and {
    dRetryCharged.rec.label == "operator-retry",
    dRetryCharged.post.jobs.get(1).phase == PLanding,
    dRetryCharged.post.jobs.get(1).deadlineLeft == 1,   // charged
    not(hasOpenHumanTask(dRetryCharged.post.jobs.get(1))),
    mB(dRetryCharged.post) < mB(cEscB),
    dRetryChargedWork.post.jobs.get(1).phase == PWorking,
    dRetryChargedWork.post.jobs.get(1).deadlineLeft == 1,
    mB(dRetryChargedWork.post) < mB({ jobs: Map(1 -> escWorking) })
  })

  /// PR 3: the Evaluating resume is A FRESH FAN-OUT OF THE LOWEST STAGE
  /// (chuggernaut spec.md §1.2 escalation Retry: "re-enter Evaluation ...
  /// with a fresh eval fan-out"; §3.3: stages are never resumed
  /// mid-sequence) — new task ids, the failed history untouched in the
  /// record.
  pure val escEval: Job = { ...DB::freshJob(Set(), progStaged),
    phase: PEscalated, resumeAt: REvaluating, reason: RsReworkBudgetExhausted,
    deadlineLeft: 2, reworkLeft: 0,
    record: [wt(1, TPassed), wt(2, TPassed), et(3, 0, TFailed)] }
  pure val dRetryEval = DB::decideOpRetry({ jobs: Map(1 -> escEval) }, 1)

  run opRetryEvalFreshFanoutTest = assert(and {
    dRetryEval.rec.label == "operator-retry",
    dRetryEval.rec.effects == ["SpawnEvalTasks"],
    dRetryEval.post.jobs.get(1).phase == PEvaluating,
    dRetryEval.post.jobs.get(1).deadlineLeft == 1,   // charged
    // Lowest stage, fresh id 4; the retired stage-0 failure stays on record.
    dRetryEval.post.jobs.get(1).tasks == Set(et(4, 0, TRunning)),
    dRetryEval.post.jobs.get(1).record ==
      [wt(1, TPassed), wt(2, TPassed), et(3, 0, TFailed)],
    mB(dRetryEval.post) < mB({ jobs: Map(1 -> escEval) })
  })

  /// Free retry metering: a resume into Landing charges nothing and the
  /// measure CLIMBS — the CHURN set's other member, v1's model-status §5b
  /// kept reproducible by configuration; the Working resume still pays
  /// (entry to Working always meters — standing rule 2).
  pure val cEscF: Core = { jobs: Map(1 -> escLanding) }
  pure val dRetryFree = DF::decideOpRetry(cEscF, 1)
  pure val dRetryFreeWork = DF::decideOpRetry({ jobs: Map(1 -> escWorking) }, 1)

  run opRetryFreeClassifiedTest = assert(and {
    dRetryFree.post.jobs.get(1).phase == PLanding,
    dRetryFree.post.jobs.get(1).deadlineLeft == 2,      // NOT charged
    mB(dRetryFree.post) > mB(cEscF),                    // CHURN: climbs
    dRetryFreeWork.post.jobs.get(1).deadlineLeft == 1,  // Working resume pays
    mB(dRetryFreeWork.post) < mB({ jobs: Map(1 -> escWorking) })
  })

  // ==========================================================================
  // === PR 2: the authoring lifecycle =======================================
  // ==========================================================================

  /// Arrival through the freshJob seam: dense ids, born a Draft with FULL
  /// accounts, its authored PROGRAM on the record (PR 3) and an empty task
  /// log, CreateDraft effect, no phase transition (a birth, not an edge) —
  /// and the measure CLIMBS by the fresh Draft's whole jobMeasure: the
  /// AUTHORING set's arrival member, pinned as a climber so the
  /// stepDescends exemption list stays honest.
  run arrivalTest = assert(and {
    dArr1.rec.label == "job-arrived",
    dArr1.rec.transitions == [],
    dArr1.rec.effects == ["CreateDraft"],
    cA1.jobs.keys() == Set(1),
    cA1.jobs.get(1).phase == PDraft,
    cA1.jobs.get(1).deadlineLeft == 3,     // full grant, nothing spent
    cA1.jobs.get(1).reworkLeft == 1,
    cA1.jobs.get(1).gateLeft == 1,
    cA1.jobs.get(1).program == DB::defaultProgram,  // PR 3: eval is data, authored
    cA1.jobs.get(1).record == [],                   // PR 3: no history yet
    cA2.jobs.keys() == Set(1, 2),          // dense: next id = size + 1
    cA2.jobs.get(2).deps == Set(1),        // dep on an UNRELEASED job: legal
    mB(cA1) > mB(cEmpty),                  // AUTHORING: climbs
    mB(cA2) > mB(cA1)
  })

  /// Freeze and release strictly descend (freeze 6->5, release 5->4 — the
  /// descent-table rows for table.qnt lines 22 and 25-26), golden-trace
  /// shaped.
  run freezeReleaseDescendTest = assert(and {
    dFreeze.rec.label == "job-frozen",
    dFreeze.rec.transitions == [{ job: 1, from: PDraft, to: PFrozen }],
    mB(cFroz) < mB(cA2),
    dRelease.rec.label == "job-released",
    dRelease.rec.transitions == [{ job: 1, from: PFrozen, to: PPending }],
    mB(c0) < mB(cFroz)
  })

  /// The v1 table also releases straight from Draft (line 21: `(Draft,
  /// Ready | Blocked | ...)`) — no freeze required; descends 6->4.
  run directReleaseFromDraftTest = assert(and {
    DB::decideRelease(cA1, 1).rec.transitions ==
      [{ job: 1, from: PDraft, to: PPending }],
    mB(DB::decideRelease(cA1, 1).post) < mB(cA1),
    DB::isReadyIn(DB::decideRelease(cA1, 1).post, 1)   // no deps: Ready derives
  })

  /// Unfreeze (table line 24, the edit loop) CLIMBS — the AUTHORING churn
  /// member that makes per-job liveness conditional on authors eventually
  /// releasing or revoking (measure.qnt header), pinned exactly like
  /// stalled-retry and the RetryFree resumes.
  run unfreezeClimbsTest = assert(and {
    DB::decideUnfreeze(cFroz, 1).rec.label == "job-unfrozen",
    DB::decideUnfreeze(cFroz, 1).rec.transitions ==
      [{ job: 1, from: PFrozen, to: PDraft }],
    mB(DB::decideUnfreeze(cFroz, 1).post) > mB(cFroz)
  })

  /// A dependency on an UNRELEASED job blocks: release job 2 while its dep
  /// (job 1) is still Draft — Blocked derives; freezing the dep changes
  /// nothing (Frozen is not Done either). Positive control: once the dep
  /// is Done (c8), releasing job 2 derives Ready.
  pure val cRel2: Core = DB::decideRelease(cA2, 2).post   // 2 Pending, dep 1 Draft
  run unreleasedDepBlocksTest = assert(and {
    DB::isBlockedIn(cRel2, 2),
    not(DB::isReadyIn(cRel2, 2)),
    DB::isBlockedIn(DB::decideFreeze(cRel2, 1).post, 2),  // Frozen dep: still blocked
    DB::isReadyIn(DB::decideRelease(c8, 2).post, 2)       // Done dep: Ready
  })

  // === Revoke, from every phase the v1 table permits =======================
  // Table lines 47-48: `(_, Revoked) => true` — every non-terminal. Eight
  // single-job fixtures, one per phase; the two desk phases are the
  // measure-FLAT cases (AUTHORING set), every live-rank phase must
  // strictly descend. Accounts are deliberately part-spent so the
  // no-leakage equality below is not vacuously "full grant == full grant".

  pure def revokedShape(j: Job): bool = and {
    j.phase == PRevoked,
    j.tasks == Set(),          // Revoked RUNS nothing (live set retired)...
    j.resumeAt == RNone,
    j.reason == RsNone,        // ...and opens NO human task:
    not(hasOpenHumanTask(j))   // revocation is the author's settled choice
  }

  /// Revoke charges no gas and spends (or refunds) no budget: every
  /// account unchanged, account by account.
  pure def accountsUntouched(pre: Job, post: Job): bool = and {
    post.deadlineLeft == pre.deadlineLeft,
    post.reworkLeft == pre.reworkLeft,
    post.gateLeft == pre.gateLeft
  }

  pure def spent(j: Job): Job =
    { ...j, deadlineLeft: 2, reworkLeft: 0, gateLeft: 1 }

  pure val jDraft: Job = spent(DB::freshJob(Set(), progU2))
  pure val jFrozen: Job = { ...jDraft, phase: PFrozen }
  pure val jPend: Job = { ...jDraft, phase: PPending }
  pure val jWork: Job = { ...jDraft, phase: PWorking,
    tasks: spawnTasks(TKWork, 1, 2) }
  pure val jEval: Job = { ...jDraft, phase: PEvaluating, tasks: mixedE0 }
  pure val jLand: Job = { ...jDraft, phase: PLanding }
  pure val jEsc: Job = { ...jDraft, phase: PEscalated,
    resumeAt: REvaluating, reason: RsReworkBudgetExhausted }
  pure val jStall: Job = { ...jDraft, phase: PStalled, reason: RsRevalidationFailed }

  pure def revokeOne(j: Job): Decision =
    DB::decideRevoke({ jobs: Map(1 -> j) }, 1)

  pure def revokeOneOk(j: Job): bool = and {
    revokeOne(j).rec.label == "job-revoked",
    revokeOne(j).rec.transitions == [{ job: 1, from: j.phase, to: PRevoked }],
    revokeOne(j).rec.effects == ["Revoke"],   // no OpenHumanTask for the revoked job
    revokedShape(revokeOne(j).post.jobs.get(1)),
    accountsUntouched(j, revokeOne(j).post.jobs.get(1)),
    revokeOne(j).post.jobs.get(1).landings == 0
  }

  run revokeFromEachPhaseTest = assert(and {
    revokeOneOk(jDraft), revokeOneOk(jFrozen), revokeOneOk(jPend),
    revokeOneOk(jWork), revokeOneOk(jEval), revokeOneOk(jLand),
    revokeOneOk(jEsc), revokeOneOk(jStall)
  })

  /// PR 3: revoke RETAINS the task record — "Revoked runs nothing" is
  /// about the live set, not the log. A mid-flight revoke force-closes the
  /// still-running work tasks as TCancelled (chuggernaut spec.md §1.2
  /// "Revoke closes tasks": a synthetic resolution recording that the
  /// revoke, not a verdict, retired them); already-resolved outcomes are
  /// preserved verbatim (jEval's mixed stage). Provenance survives the
  /// author's settlement.
  run revokeRetainsRecordTest = assert(and {
    revokeOne(jWork).post.jobs.get(1).record ==
      [wt(1, TCancelled), wt(2, TCancelled)],
    revokeOne(jEval).post.jobs.get(1).record ==
      [et(1, 0, TPassed), et(2, 0, TFailed)],
    revokeOne(jDraft).post.jobs.get(1).record == []   // never ran: no history
  })

  /// Measure classification of revoke, pinned: strict descent from every
  /// live-rank phase (the settled tier swallows rank, stage digit AND
  /// running tasks); exactly FLAT from the two desk phases with nobody to
  /// park — the AUTHORING set's bounded desk-settle member.
  pure def mOne(j: Job): int = mB({ jobs: Map(1 -> j) })
  pure def mOneAfter(j: Job): int = mB(revokeOne(j).post)

  run revokeMeasureClassifiedTest = assert(and {
    mOneAfter(jDraft) < mOne(jDraft),
    mOneAfter(jFrozen) < mOne(jFrozen),
    mOneAfter(jPend) < mOne(jPend),
    mOneAfter(jWork) < mOne(jWork),
    mOneAfter(jEval) < mOne(jEval),
    mOneAfter(jLand) < mOne(jLand),
    mOneAfter(jEsc) == mOne(jEsc),      // desk revoke: flat, by design
    mOneAfter(jStall) == mOne(jStall)
  })

  /// Table lines 45-46, `(Done | Revoked, Revoked) => false`: the
  /// absorbing terminals are exactly the unrevocable phases.
  run revocableExactlyNonTerminalTest = assert(and {
    DB::revocableIn({ jobs: Map(1 -> jDraft) }, 1),
    DB::revocableIn({ jobs: Map(1 -> jEsc) }, 1),
    not(DB::revocableIn(c8, 1)),                                  // Done
    not(DB::revocableIn(revokeOne(jDraft).post, 1))               // Revoked
  })

  /// REVOKED NEVER LANDS (the exclusivity extension): revoking a job
  /// parked ON the landing strip emits no landing effect and leaves the
  /// landing counter at zero — contrast with the landed job (c8), whose
  /// counter is 1 and which is beyond revoke's reach (previous test).
  run revokedNeverLandsTest = assert(and {
    revokeOne(jLand).post.jobs.get(1).landings == 0,
    revokeOne(jLand).rec.effects == ["Revoke"],
    c8.jobs.get(1).landings == 1
  })

  // === THE CASCADE, end-to-end on a 3-job chain (the PR 2 gate) ============
  // 1 <- 2 <- 3: job 1 released, job 2 released behind it, job 3 still a
  // Draft behind 2. Revoking 1 must — in ONE atomic decision — settle 1
  // (no task) and park BOTH transitive dependents with their own
  // dependency_revoked desk task, spending nothing anywhere.

  pure val cChain: Core = { jobs: Map(
    1 -> { ...DB::freshJob(Set(), progU2), phase: PPending },
    2 -> { ...DB::freshJob(Set(1), progU2), phase: PPending },
    3 -> DB::freshJob(Set(2), progU2)
  ) }
  pure val dCascade = DB::decideRevoke(cChain, 1)
  pure val cParked = dCascade.post

  run cascadeEndToEndTest = assert(and {
    dCascade.rec.label == "job-revoked",
    // One StepRecord, ascending: the revoke then both parks — atomic.
    dCascade.rec.transitions == [
      { job: 1, from: PPending, to: PRevoked },
      { job: 2, from: PPending, to: PStalled },
      { job: 3, from: PDraft, to: PStalled }
    ],
    // A desk task per parked dependent; NONE for the revoked job.
    dCascade.rec.effects == ["Revoke", "OpenHumanTask", "OpenHumanTask"],
    revokedShape(cParked.jobs.get(1)),
    cParked.jobs.get(2).phase == PStalled,
    cParked.jobs.get(2).reason == RsDependencyRevoked,
    hasOpenHumanTask(cParked.jobs.get(2)),
    cParked.jobs.get(3).phase == PStalled,
    cParked.jobs.get(3).reason == RsDependencyRevoked,
    hasOpenHumanTask(cParked.jobs.get(3)),
    // The cascade spends nothing on anyone.
    accountsUntouched(cChain.jobs.get(2), cParked.jobs.get(2)),
    accountsUntouched(cChain.jobs.get(3), cParked.jobs.get(3)),
    // And the whole step strictly descends (three ranks fall to 0).
    mB(cParked) < mB(cChain)
  })

  /// The parked dependents' walls resolve by REVOKE, not retry: the
  /// dependency_revoked wall is not retryable (deps are immutable — the
  /// deliberate table-line-44 deviation documented at stallRetryableIn),
  /// while the revalidation wall stays retryable. A human revoking parked
  /// job 2 settles it from the desk: flat measure (AUTHORING member), no
  /// re-park of already-parked 3, and job 3's task stays open.
  pure val dSettle2 = DB::decideRevoke(cParked, 2)

  run cascadeSettleByRevokeTest = assert(and {
    not(DB::stallRetryableIn(cParked, 2)),         // dependency_revoked: no retry
    not(DB::stallRetryableIn(cParked, 3)),
    DB::stallRetryableIn(dStall.post, 1),          // revalidation_failed: retryable
    dSettle2.rec.transitions == [{ job: 2, from: PStalled, to: PRevoked }],
    dSettle2.rec.effects == ["Revoke"],
    mB(dSettle2.post) == mB(cParked),              // desk revoke: flat, pinned
    dSettle2.post.jobs.get(3).phase == PStalled,   // 3 untouched, still covered
    hasOpenHumanTask(dSettle2.post.jobs.get(3))
  })
}
