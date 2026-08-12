/// Domain vocabulary for the chuggernaut model: sum types only, no state and
/// no operators. Every type cites the chuggernaut source it mirrors (paths
/// relative to the chuggernaut repo root).
module chug_types {
  /// Job lifecycle states, one constructor per Rust variant.
  /// Mirrors `JobState` in chuggernaut crates/types/src/job.rs:326 (spec §2.1).
  /// Constructor names match the Rust enum exactly; bare `Work` is legal in
  /// Quint 0.32 (no builtin collision).
  type JobState =
    Draft | Frozen | Batched | Blocked | Ready | Work |
    Evaluation | WrapUp | Escalated | Stalled | Done | Revoked

  /// Task phases: which stage of a job's lifecycle a task belongs to.
  /// Mirrors `TaskPhase` in chuggernaut crates/types/src/task.rs:139.
  /// `P`-prefixed because Quint sum-type constructors share one namespace per
  /// module and Work/Evaluation/WrapUp are already claimed by `JobState`.
  /// `PNone` has no Rust counterpart: chuggernaut records the escalation
  /// origin optionally, and v1 folds the "not escalated" case into the sum so
  /// `Job.escalatedFrom` needs no separate option wrapper.
  type Phase = PNone | PWork | PEvaluation | PMergeGate | PWrapUp | PTriage | PEscalation

  /// Result of one Work-phase task attempt: the attempt either completed or
  /// failed. Mirrors the Done/Failed terminal `TaskState`s of a Work task in
  /// chuggernaut crates/types/src/task.rs (spec §3.2).
  type WorkOutcome = WSuccess | WFailure

  /// Result of an evaluation round's reduce: pass, or a product failure that
  /// sends the job back to rework. Mirrors the `pass` verdict reduced in
  /// chuggernaut crates/dispatcher/src/eval.rs (spec §3.3).
  type EvalOutcome = EPass | EProductFail

  /// Result of a landing (merge queue -> merge gate -> squash): clean merge,
  /// or a conflict / gate failure that forces rework. Mirrors `MergeOutcome`
  /// in chuggernaut crates/domain/src/decide/merge_gate.rs:111 (spec §3.3):
  /// Merged/NoOp -> LClean; Conflict/UnresolvedMarkers or a gate CI failure
  /// -> LConflictOrGateFail.
  type LandOutcome = LClean | LConflictOrGateFail

  /// One observed job-state transition, for trace-shaped reasoning.
  /// Mirrors the (from, to) pair of `assert_transition` /
  /// `InvalidTransition` in chuggernaut crates/domain/src/state.rs, tagged
  /// with the job it belongs to.
  type Transition = {job: int, from: JobState, to: JobState}

  /// One job's model state (v1 abstraction of chuggernaut's `Job` record +
  /// its `ExecState` budgets, crates/types/src/job.rs / spec §1.1, §3.2-§3.5).
  type Job = {
    // Current §2.1 lifecycle state.
    state: JobState,
    // Upstream dependency job ids. init builds an acyclic graph by allowing
    // deps only on smaller ids.
    deps: Set[int],
    // Which phase escalated (spec §2.1 Escalated rows: the operator's Retry
    // resumes the job at the phase that failed). PNone when not Escalated.
    escalatedFrom: Phase,
    // Work attempts within the current cycle (spec §3.2: `attempt` is reset
    // to 1 on every entry to Work, bumped by same-cycle retries, bounded by
    // `work_retries`).
    attempt: int,
    // Budgeted rework counter for eval product failures — the spec §2.1
    // Evaluation→Work guard `cycle N ≤ rework_budget`. Never exceeds
    // REWORK_BUDGET.
    evalReworks: int,
    // UNBUDGETED merge-gate/conflict rework counter — the documented
    // livelock source (spec.md §3.3 "Bounding", line 1265: repeated gate
    // failures don't consume `rework_budget`, so a job that can't integrate
    // loops Work → Evaluation → WrapUp → Work; `job_deadline` is the
    // backstop).
    gateReworks: int,
    // Deadline gas, the model's `job_deadline` backstop (spec §3.5):
    // decremented on each entry to Work; at 0 the job is forced to
    // Stalled/Escalated instead of re-entering Work. Never goes below 0.
    deadlineLeft: int,
    // An operator Human task is open for this job (Escalated/Stalled).
    humanTaskOpen: bool,
    // GHOST (PR3): the job escalated at least once, ever. Not dispatcher
    // state — set by the escalation deciders and never cleared, existing
    // only so the `witnessEscalatedRecovered` anti-vacuity probe can ask
    // "did a job that went through escalation still reach Done?" exactly.
    wasEscalated: bool
  }

  /// The dispatcher's single-writer state (v1): all jobs, the ready queue,
  /// and whether the environment (operators + repo churn) is still active.
  type Core = { jobs: int -> Job, readyQ: List[int], envActive: bool }

  /// One decision's observable record. The shape {label, transitions,
  /// effects} deliberately mirrors chuggernaut's golden-trace YAML step
  /// schema {event, transitions: [{job, from, to}], effects} so model traces
  /// and implementation traces line up field-for-field.
  type StepRecord = { label: str, transitions: List[Transition], effects: List[str] }

  /// What a pure decider returns: the step record it performed and the
  /// post-state — the Quint analogue of chuggernaut's
  /// `decide(view, event) -> (Vec<Transition>, Vec<Effect>)`
  /// (crates/domain/src/decide/mod.rs).
  type Decision = { rec: StepRecord, post: Core }
}
