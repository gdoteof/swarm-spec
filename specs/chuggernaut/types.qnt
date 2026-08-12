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
  type Phase = PWork | PEvaluation | PMergeGate | PWrapUp | PTriage | PEscalation

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
}
