/// The v1 pure decision core: one `pure def decide*` per dispatcher event,
/// mirroring chuggernaut's decider layer (crates/domain/src/decide/*.rs:
/// `decide(view, event) -> (Vec<Transition>, Vec<Effect>)` — pure functions,
/// never an effect). Each decision returns a `Decision`: a StepRecord
/// {label, transitions, effects} shaped like chuggernaut's golden-trace YAML
/// step schema, plus the post-state Core.
///
/// Decisions deliberately do NOT consult `chug_table.allowedTransition`: the
/// table stays an independent oracle that PR3's invariants check these
/// decisions against.
///
/// v1 abstractions: container execution is a nondet WorkOutcome; the staged
/// eval round is one nondet EvalOutcome; git + merge gate + CI are one nondet
/// LandOutcome. The merge-queue mechanism is deferred (v3), but the
/// WrapUp→Work rework edge IS modeled — it carries the headline livelock.
module chug_decide {
  import chug_types.* from "./types"

  /// Max same-cycle work retries — spec §2.1 Work→Work guard
  /// `attempt ≤ work_retries`.
  const WORK_RETRIES: int
  /// Max budgeted eval-failure reworks — spec §2.1 Evaluation→Work guard
  /// `cycle N ≤ rework_budget`.
  const REWORK_BUDGET: int

  pure def mkTransition(j: int, fromState: JobState, toState: JobState): Transition =
    { job: j, from: fromState, to: toState }

  /// Replace job j's record wholesale (field updates that do not change the
  /// lifecycle state — the state flip itself goes through `move`).
  pure def withJob(c: Core, j: int, jb: Job): Core =
    { ...c, jobs: c.jobs.set(j, jb) }

  /// The one funnel every state flip goes through — the model analogue of
  /// chuggernaut's `Core::set_state`: move job j to `toState`, recording
  /// exactly the one transition performed.
  pure def move(c: Core, j: int, toState: JobState, label: str, effects: List[str]): Decision =
    val old = c.jobs.get(j)
    {
      rec: { label: label, transitions: [mkTransition(j, old.state, toState)], effects: effects },
      post: { ...c, jobs: c.jobs.set(j, { ...old, state: toState }) }
    }

  /// §2.1 Ready→Work: the dispatcher pops the ready-queue head and launches
  /// work (cycle's first attempt). Charges one unit of deadline gas — every
  /// entry to Work does.
  pure def decideDispatch(c: Core): Decision =
    val j = c.readyQ.head()
    val old = c.jobs.get(j)
    val charged = { ...old, attempt: 1, deadlineLeft: old.deadlineLeft - 1 }
    val d = move(withJob(c, j, charged), j, Work, "dispatch", ["CreateWorkTask", "LaunchContainer"])
    { ...d, post: { ...d.post, readyQ: c.readyQ.tail() } }

  /// A Work-phase task resolved (spec §3.2). Success → Evaluation fan-out.
  /// Failure: same-cycle retry while `attempt ≤ work_retries` (deadline NOT
  /// charged — retries stay inside the current cycle), else escalate.
  pure def decideTaskDone(c: Core, j: int, out: WorkOutcome): Decision =
    val old = c.jobs.get(j)
    match out {
      | WSuccess => move(c, j, Evaluation, "work-succeeded", ["FanOutEvaluators"])
      | WFailure =>
        if (old.attempt <= WORK_RETRIES)
          move(withJob(c, j, { ...old, attempt: old.attempt + 1 }),
            j, Work, "work-retry", [])
        else
          move(withJob(c, j, { ...old, escalatedFrom: PWork, humanTaskOpen: true, wasEscalated: true }),
            j, Escalated, "job-escalated work_retries_exhausted", ["CreateEscalationTask"])
    }

  /// The eval round reduced (spec §3.3). Pass → WrapUp (enqueue as merge
  /// candidate). Product failure: budgeted rework back to Work while under
  /// REWORK_BUDGET and deadline gas remains, else escalate with the reason
  /// that bound first (budget checked before gas, like the spec's guard
  /// column).
  pure def decideEval(c: Core, j: int, out: EvalOutcome): Decision =
    val old = c.jobs.get(j)
    match out {
      | EPass => move(c, j, WrapUp, "eval-passed", ["EnqueueMergeCandidate"])
      | EProductFail =>
        if (old.evalReworks < REWORK_BUDGET and old.deadlineLeft > 0)
          move(
            withJob(c, j, { ...old,
              evalReworks: old.evalReworks + 1, attempt: 1,
              deadlineLeft: old.deadlineLeft - 1 }),
            j, Work, "job-rework-started eval_failure", [])
        else
          val label =
            if (old.evalReworks >= REWORK_BUDGET) "job-escalated rework_budget_exhausted"
            else "job-escalated job_deadline_exceeded"
          move(withJob(c, j, { ...old, escalatedFrom: PEvaluation, humanTaskOpen: true, wasEscalated: true }),
            j, Escalated, label, ["CreateEscalationTask"])
    }

  /// The landing resolved (spec §3.3 merge gate + squash). Clean → Done.
  /// Conflict/gate failure → WrapUp→Work rework: `gateReworks` counts it but
  /// `rework_budget` is deliberately NOT consumed (spec.md §3.3 "Bounding",
  /// line 1265) — an integration failure is not the author's product failure.
  /// That unbudgeted loop is the documented livelock; deadline gas is its
  /// only backstop, so at 0 gas the job escalates instead.
  pure def decideLand(c: Core, j: int, out: LandOutcome): Decision =
    val old = c.jobs.get(j)
    match out {
      | LClean => move(c, j, Done, "job-done", ["SquashMerge", "DeleteBranch"])
      | LConflictOrGateFail =>
        if (old.deadlineLeft > 0)
          move(
            withJob(c, j, { ...old,
              gateReworks: old.gateReworks + 1, attempt: 1,
              deadlineLeft: old.deadlineLeft - 1 }),
            j, Work, "job-rework-started merge_gate_failure", [])
        else
          move(withJob(c, j, { ...old, escalatedFrom: PWrapUp, humanTaskOpen: true, wasEscalated: true }),
            j, Escalated, "job-escalated job_deadline_exceeded", ["CreateEscalationTask"])
    }

  /// §2.1 Blocked→Ready: the last upstream dep reached Done and re-validation
  /// passed. The machine guards that all deps are Done before calling this.
  ///
  /// Done-cascade note: when a job reaches Done, Blocked dependents are NOT
  /// auto-unblocked inside the same decision — unblocking is a separate
  /// decideDepRecheck step per dependent. Event granularity in v1 is one
  /// mailbox message per decision, matching the dispatcher's actor loop.
  pure def decideDepRecheck(c: Core, j: int): Decision =
    val d = move(c, j, Ready, "job-unblocked", [])
    { ...d, post: { ...d.post, readyQ: d.post.readyQ.append(j) } }

  /// §2.1 Blocked→Stalled: the last dep reached Done but re-validation of the
  /// static config failed (file deleted/renamed since release). Same machine
  /// guard as decideDepRecheck; which of the two fires is the environment's
  /// nondet choice.
  pure def decideRevalFail(c: Core, j: int): Decision =
    val old = c.jobs.get(j)
    move(withJob(c, j, { ...old, humanTaskOpen: true }),
      j, Stalled, "job-stalled revalidation_failed", ["CreateHumanTask"])

  /// §2.1 Escalated→{Work,Evaluation,WrapUp}: operator resolves the
  /// escalation with Retry, resuming at the phase that failed. Re-entering
  /// Work charges deadline gas (the machine guards gas > 0 for that arm);
  /// resuming Evaluation/WrapUp launches no work container and charges none.
  pure def decideOpRetry(c: Core, j: int): Decision =
    val old = c.jobs.get(j)
    val resumed = { ...old, humanTaskOpen: false }
    match old.escalatedFrom {
      | PWork =>
        move(withJob(c, j, { ...resumed, attempt: 1, deadlineLeft: old.deadlineLeft - 1 }),
          j, Work, "operator-retry", [])
      | PEvaluation => move(withJob(c, j, resumed), j, Evaluation, "operator-retry", [])
      | PWrapUp => move(withJob(c, j, resumed), j, WrapUp, "operator-retry", [])
      | _ =>
        // Unreachable: every escalation stamps escalatedFrom with PWork,
        // PEvaluation, or PWrapUp. A no-op Decision keeps the match total.
        { rec: { label: "operator-retry-unreachable", transitions: [], effects: [] }, post: c }
    }

  /// §2.1 Stalled→Ready: operator Retry on a pre-work stall succeeds; the job
  /// re-enters the ready queue. No gas charged — Stalled jobs never started.
  pure def decideStalledRetry(c: Core, j: int): Decision =
    val old = c.jobs.get(j)
    val d = move(withJob(c, j, { ...old, humanTaskOpen: false }),
      j, Ready, "stalled-retry", [])
    { ...d, post: { ...d.post, readyQ: d.post.readyQ.append(j) } }

  /// §2.1 Stalled→Stalled: operator Retry, but the failed step still fails;
  /// the human task stays open.
  pure def decideStalledRetryFail(c: Core, j: int): Decision =
    move(c, j, Stalled, "stalled-retry-failed", [])

  /// Environment quiesce: from here on the environment produces no new churn
  /// (no merge conflicts, no revalidation failures) and the operator stops
  /// intervening. One-way; no job transitions.
  pure def decideQuiesce(c: Core): Decision =
    { rec: { label: "quiesce", transitions: [], effects: [] },
      post: { ...c, envActive: false } }
}
