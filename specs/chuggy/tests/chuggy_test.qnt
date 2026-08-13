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
///
/// PR 2 additions (authoring lifecycle; gate: revoke cascades proved safe):
///   - arrival/freeze/release strictly descend where the descent table
///     says, and the AUTHORING climbers (arrival, unfreeze) are pinned as
///     climbers;
///   - revoke from EVERY phase the v1 table permits (table.qnt lines
///     47-48), with the desk-only flat cases pinned, and revocableIn false
///     exactly on the absorbing terminals (lines 45-46);
///   - the cascade end-to-end on a 3-job chain: atomic park with the
///     dependency_revoked wall, own desk task per dependent, none for the
///     revoked job itself;
///   - a dependency on an UNRELEASED (Draft/Frozen) job blocks;
///   - revoked never lands, and revoke/cascade spend NOTHING (no gas, no
///     budgets — account-by-account equality).
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
  // PR 2: the path now STARTS at authoring — the fleet is empty, job 1
  // arrives as a Draft (freshJob seam), is frozen, and released; job 2
  // arrives as a Draft depending on 1 and stays unreleased throughout.

  pure val cEmpty: Core = { jobs: Map() }
  pure val dArr1 = DB::decideArrive(cEmpty, Set())
  pure val cA1 = dArr1.post                        // job 1: Draft
  pure val dArr2 = DB::decideArrive(cA1, Set(1))
  pure val cA2 = dArr2.post                        // job 2: Draft, dep {1}
  pure val dFreeze = DB::decideFreeze(cA2, 1)
  pure val cFroz = dFreeze.post                    // job 1: Frozen
  pure val dRelease = DB::decideRelease(cFroz, 1)

  pure val c0: Core = dRelease.post                // job 1: Pending, job 2: Draft
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
  /// (PR 2: freshJob now births a Draft, so the RELEASED fixture overrides
  /// the phase — revalFail is a Ready-phase edge.)
  pure val cFresh: Core = { jobs: Map(1 -> { ...DB::freshJob(Set()), phase: PPending }) }
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

  // ==========================================================================
  // === PR 2: the authoring lifecycle =======================================
  // ==========================================================================

  /// Arrival through the freshJob seam: dense ids, born a Draft with FULL
  /// accounts, CreateDraft effect, no phase transition (a birth, not an
  /// edge) — and the measure CLIMBS by the fresh Draft's whole jobMeasure:
  /// the AUTHORING set's arrival member, pinned as a climber so the
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
    j.tasks == Set(),          // Revoked holds nothing
    j.resumeAt == RNone,
    j.reason == RsNone,        // and opens NO human task...
    not(hasOpenHumanTask(j))   // ...revocation is the author's settled choice
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

  pure val jDraft: Job = spent(DB::freshJob(Set()))
  pure val jFrozen: Job = { ...jDraft, phase: PFrozen }
  pure val jPend: Job = { ...jDraft, phase: PPending }
  pure val jWork: Job = { ...jDraft, phase: PWorking, tasks: freshTasks(2) }
  pure val jEval: Job = { ...jDraft, phase: PEvaluating, tasks: mixedOutcomes }
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

  /// Measure classification of revoke, pinned: strict descent from every
  /// live-rank phase (the settled tier swallows rank AND running tasks);
  /// exactly FLAT from the two desk phases with nobody to park — the
  /// AUTHORING set's bounded desk-settle member.
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
    1 -> { ...DB::freshJob(Set()), phase: PPending },
    2 -> { ...DB::freshJob(Set(1)), phase: PPending },
    3 -> DB::freshJob(Set(2))
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
