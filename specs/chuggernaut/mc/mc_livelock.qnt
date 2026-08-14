/// The deadline-free livelock instance: identical to mc_liveness except
/// DEADLINE=1000 — effectively unbounded, modeling a graph where no
/// `job_deadline` is set (chuggernaut docs/spec.md §3.5: the deadline is
/// opt-in; §3.3 "Bounding" line 1269 says the merge-gate rework loop
/// consumes no rework_budget and `job_deadline` is the backstop — so with
/// no deadline there is no backstop at all).
///
/// Checked here (see scripts/check.sh Stage 6):
/// - gateReworksWithinBudgets FAILS (expected — the headline artifact): a
///   single job loops Work -> Evaluation -> WrapUp -> Work on
///   "job-rework-started merge_gate_failure" more times than every budget
///   combined — the documented livelock as a machine-checked trace.
/// - quiescentDescent still HOLDS (randomized; DEADLINE=1000 makes this
///   instance Apalache-intractable): even the budget-free gate loop pays
///   gas on every rework, which is exactly the "job_deadline is the
///   backstop" clause of spec.md:1269.
module mc_livelock {
  import chug_types.* from "../types"
  import chug_machine(
    N_JOBS = 2,
    N_AGENTS = 1,
    WORK_RETRIES = 1,
    REWORK_BUDGET = 1,
    DEADLINE = 1000
  ).* from "../machine"
}
