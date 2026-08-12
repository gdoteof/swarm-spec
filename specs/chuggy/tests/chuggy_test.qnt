/// Unit tests over the chuggy deciders and the termination measure
/// (chuggy-charter.md, roadmap PR 1). Everything here is PURE: cores are
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
///   - both retry-metering branches (charter §2 op-retry row);
///   - the eval combinator changes MACHINE decisions, not just the pure
///     `combine` (charter §2: eval is data).
module chuggy_test {
  import chuggy_measure.* from "../measure"

  // Reference instance: Budgeted(1) gate pricing, charged retries (the
  // charter defaults where the charter names a default).
  import chuggy_domain(
    N_JOBS = 2, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryCharged,
    EVAL_COMBINATOR = CUnanimousPass
  ) as DB from "../domain"

  // DeadlineOnly gate pricing (the other §2 branch).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = DeadlineOnly, OP_RETRY_PRICING = RetryCharged,
    EVAL_COMBINATOR = CUnanimousPass
  ) as DD from "../domain"

  // Free retry metering — v1's model-status §5b churn, kept reproducible
  // by configuration (machine-level coverage: mc_chuggy_retryfree).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryFree,
    EVAL_COMBINATOR = CUnanimousPass
  ) as DF from "../domain"

  // CAnyPass combinator — same machine, different eval parameter: the
  // combinator must change decideEvalReduce's DECISION, not just the pure
  // combine().
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 3,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryCharged,
    EVAL_COMBINATOR = CAnyPass
  ) as DA from "../domain"

  // A graph WITHOUT a deadline — invalid by charter §2 (economy/deadline).
  import chuggy_domain(
    N_JOBS = 1, N_TASKS = 2, REWORK_BUDGET = 1, DEADLINE = 0,
    GATE_PRICING = Budgeted(1), OP_RETRY_PRICING = RetryCharged,
    EVAL_COMBINATOR = CUnanimousPass
  ) as DZ from "../domain"

  /// Charter §2, deadline row: a graph without a deadline is INVALID — the
  /// model admits no initial state for it at all.
  run deadlineRequiredTest = DZ::init.fail()

  // The same bounds the instances above carry, for measure recomputation.
  pure val bB: Bounds =
    { reworkBudget: 1, nTasks: 2, gatePricing: Budgeted(1) }
  pure val bD: Bounds =
    { reworkBudget: 1, nTasks: 2, gatePricing: DeadlineOnly }

  pure def mB(c: Core): int = sysMeasure(bB, c.jobs)
  pure def mD(c: Core): int = sysMeasure(bD, c.jobs)

  // === The happy path, decision by decision ================================
  // Job 1 free, job 2 blocked behind it (the derived waiting room).

  pure val c0: Core = { jobs: Map(1 -> DB::freshJob(Set()), 2 -> DB::freshJob(Set(1))) }
  pure val dDispatch = DB::decideDispatch(c0, 1)
  pure val c1 = dDispatch.post
  pure val dWork1 = DB::decideTaskDone(c1, 1, 1, VPass)
  pure val c2 = dWork1.post
  pure val dWork2 = DB::decideTaskDone(c2, 1, 2, VPass)
  pure val c3 = dWork2.post
  pure val dWorkReduce = DB::decideWorkReduce(c3, 1)
  pure val c4 = dWorkReduce.post
  pure val dEval1 = DB::decideTaskDone(c4, 1, 1, VPass)
  pure val c5 = dEval1.post
  pure val dEval2 = DB::decideTaskDone(c5, 1, 2, VPass)
  pure val c6 = dEval2.post
  pure val dEvalReduce = DB::decideEvalReduce(c6, 1)
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

  /// A duplicate completion for an already-resolved task (even with a
  /// CONTRADICTING verdict — first write wins) changes nothing: no state,
  /// no effects, no measure movement. The dropped no-double-pods axiom,
  /// honored idempotently (charter §2 fabric row).
  run duplicateTaskDoneIdempotentTest = assert(and {
    DB::decideTaskDone(c2, 1, 1, VFail).post == c2,
    DB::decideTaskDone(c2, 1, 1, VFail).rec.label == "task-done-duplicate",
    DB::decideTaskDone(c2, 1, 1, VFail).rec.effects == [],
    mB(DB::decideTaskDone(c2, 1, 1, VFail).post) == mB(c2)
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

  pure def oneFailed: Set[Task] =
    Set({ id: 1, outcome: TFailed }, { id: 2, outcome: TPassed })

  /// A failed Work task set escalates DIRECTLY at cycle level — there is
  /// no same-cycle retry branch to take: below-cycle retries are the
  /// fabric's trusted backoffLimit (charter §2 fabric row) and modeling
  /// them is a §2 non-goal ("no retry machinery below the cycle").
  pure val cWorkFail: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PWorking, deadlineLeft: 2, tasks: oneFailed }) }
  pure val dWorkFail = DB::decideWorkReduce(cWorkFail, 1)

  run workFailedWallTest = assert(and {
    dWorkFail.rec.label == "job-escalated work_failed",
    dWorkFail.post.jobs.get(1).phase == PEscalated,
    dWorkFail.post.jobs.get(1).reason == RsWorkFailed,
    dWorkFail.post.jobs.get(1).resumeAt == RWorking,
    hasOpenHumanTask(dWorkFail.post.jobs.get(1)),
    dWorkFail.rec.effects == ["OpenHumanTask"],
    mB(dWorkFail.post) < mB(cWorkFail)
  })

  // === The middle loop (budgeted eval rework) and its two walls ============

  /// Eval rework: 1 rework budget + 1 gas buy a new cycle; both accounts
  /// (and the measure) descend. TFailed here also covers evaluator-infra
  /// death — the job pays, one account (charter §2 eval/evaluator-failure).
  pure val cEvalFail: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PEvaluating, reworkLeft: 1, deadlineLeft: 2, tasks: oneFailed }) }
  pure val dEvalRework = DB::decideEvalReduce(cEvalFail, 1)

  run evalReworkDescendsTest = assert(and {
    dEvalRework.rec.label == "rework-started eval_failure",
    dEvalRework.post.jobs.get(1).phase == PWorking,
    dEvalRework.post.jobs.get(1).reworkLeft == 0,
    dEvalRework.post.jobs.get(1).deadlineLeft == 1,
    mB(dEvalRework.post) < mB(cEvalFail)
  })

  /// Budget wall (checked before the deadline wall, v1 convention).
  pure val cReworkWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PEvaluating, reworkLeft: 0, deadlineLeft: 2, tasks: oneFailed }) }
  pure val dReworkWall = DB::decideEvalReduce(cReworkWall, 1)

  /// Deadline wall: budget remains but the gas is gone.
  pure val cEvalGasWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PEvaluating, reworkLeft: 1, deadlineLeft: 0, tasks: oneFailed }) }
  pure val dEvalGasWall = DB::decideEvalReduce(cEvalGasWall, 1)

  run evalWallsNamedTest = assert(and {
    dReworkWall.rec.label == "job-escalated rework_budget_exhausted",
    dReworkWall.post.jobs.get(1).reason == RsReworkBudgetExhausted,
    dReworkWall.post.jobs.get(1).resumeAt == REvaluating,
    mB(dReworkWall.post) < mB(cReworkWall),
    dEvalGasWall.rec.label == "job-escalated job_deadline_exceeded",
    dEvalGasWall.post.jobs.get(1).reason == RsDeadlineExceeded,
    mB(dEvalGasWall.post) < mB(cEvalGasWall)
  })

  // === The outer loop, priced per GatePricing (charter §2) =================

  /// Budgeted branch: a landing failure spends 1 gate budget AND 1 gas.
  pure val cGateB: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PLanding, gateLeft: 1, deadlineLeft: 2 }) }
  pure val dGateRework = DB::decideLand(cGateB, 1, LandFailed)

  run gateReworkBudgetedDescendsTest = assert(and {
    dGateRework.rec.label == "rework-started gate_failure",
    dGateRework.post.jobs.get(1).phase == PWorking,
    dGateRework.post.jobs.get(1).gateLeft == 0,
    dGateRework.post.jobs.get(1).deadlineLeft == 1,
    mB(dGateRework.post) < mB(cGateB)
  })

  /// The gate-budget wall — a reason that EXISTS ONLY under Budgeted.
  pure val cGateWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PLanding, gateLeft: 0, deadlineLeft: 2 }) }
  pure val dGateWall = DB::decideLand(cGateWall, 1, LandFailed)

  /// Budgeted branch, deadline wall: gate budget remains, gas is gone.
  pure val cGateGasWall: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
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
  pure val cGateD: Core = { jobs: Map(1 -> { ...DD::freshJob(Set()),
    phase: PLanding, deadlineLeft: 2 }) }
  pure val dGateD = DD::decideLand(cGateD, 1, LandFailed)

  pure val cGateDWall: Core = { jobs: Map(1 -> { ...DD::freshJob(Set()),
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
  pure val cFresh: Core = { jobs: Map(1 -> DB::freshJob(Set())) }
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
  pure val escLanding: Job = { ...DB::freshJob(Set()),
    phase: PEscalated, resumeAt: RLanding, reason: RsDeadlineExceeded,
    deadlineLeft: 2 }
  pure val cEscB: Core = { jobs: Map(1 -> escLanding) }
  pure val dRetryCharged = DB::decideOpRetry(cEscB, 1)

  pure val escWorking: Job = { ...DB::freshJob(Set()),
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

  // === The eval combinator is a real parameter =============================

  pure val mixedOutcomes: Set[Task] =
    Set({ id: 1, outcome: TPassed }, { id: 2, outcome: TFailed })
  pure val allPassed: Set[Task] =
    Set({ id: 1, outcome: TPassed }, { id: 2, outcome: TPassed })
  pure val allFailed: Set[Task] =
    Set({ id: 1, outcome: TFailed }, { id: 2, outcome: TFailed })

  /// Both branches of the combinator parameter are semantically distinct
  /// (charter §2: eval is data; unanimous pass is only the DEFAULT).
  run combinatorBranchesTest = assert(and {
    combine(CUnanimousPass, allPassed),
    not(combine(CUnanimousPass, mixedOutcomes)),
    combine(CAnyPass, mixedOutcomes),
    not(combine(CAnyPass, allFailed))
  })

  /// MACHINE-level: the combinator parameter reaches decideEvalReduce.
  /// Same resolved task set, different EVAL_COMBINATOR instance, different
  /// machine decision — AnyPass lands, UnanimousPass reworks (and pays).
  pure val cMixedAny: Core = { jobs: Map(1 -> { ...DA::freshJob(Set()),
    phase: PEvaluating, tasks: mixedOutcomes, deadlineLeft: 2 }) }
  pure val cMixedUna: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()),
    phase: PEvaluating, tasks: mixedOutcomes, deadlineLeft: 2 }) }

  run combinatorChangesMachineTest = assert(and {
    DA::decideEvalReduce(cMixedAny, 1).rec.label == "eval-passed",
    DA::decideEvalReduce(cMixedAny, 1).post.jobs.get(1).phase == PLanding,
    DB::decideEvalReduce(cMixedUna, 1).rec.label == "rework-started eval_failure",
    DB::decideEvalReduce(cMixedUna, 1).post.jobs.get(1).phase == PWorking,
    DB::decideEvalReduce(cMixedUna, 1).post.jobs.get(1).deadlineLeft == 1
  })

  /// All-failed still walls under CAnyPass (the parameter is not "always
  /// pass"): the rework path is taken.
  pure val cFailAny: Core = { jobs: Map(1 -> { ...DA::freshJob(Set()),
    phase: PEvaluating, tasks: allFailed, deadlineLeft: 2 }) }

  run anyPassNotAlwaysPassTest = assert(
    DA::decideEvalReduce(cFailAny, 1).rec.label == "rework-started eval_failure")
}
