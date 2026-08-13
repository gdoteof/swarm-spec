/// Small-scope instances of chuggy_domain for simulation: one per
/// GatePricing branch (charter §2 gate-pricing row: parameterize and decide
/// on evidence — the model must generate traces under BOTH prices), plus a
/// RetryFree instance so the operator-churn exemption in stepDescends is
/// exercised by a machine run, not just by pure unit tests.
///
/// PR 2: every instance runs the AUTHORING actions — the fleet starts
/// empty and jobs arrive as Drafts, with N_JOBS read as the ARRIVAL BOUND
/// (kept small so the grown state space stays small: arrivals, the
/// unfreeze loop, and revoke multiply the branching).
///
/// PR 3: every instance runs WITH PROGRAMS ENABLED — MAX_STAGES = 2, so
/// arrivals draw nondet from ALL well-formed eval programs (both lengths,
/// both combinators, every fan-out in 1..N_TASKS: 20 programs at these
/// bounds), and the EVAL_COMBINATOR const is gone (the combinator is data
/// on each job's program now; the charter's unanimous default is
/// domain.qnt defaultProgram, one of the drawn programs). All three
/// instances must keep `allInvariants` green — now including the PR 3
/// additions recordWellFormed, recordMonotone, and programsWellFormed —
/// while the budgeted instance also feeds Stage 9b's second and third
/// expected-violation runs (cascadeParkNever, the cascade-reachability
/// probe, and stageAdvanceNever, the stage-advance-reachability probe).
///
/// Imports are not re-exported by the chuggy_domain instance, so each
/// module pulls the vocabulary (constructors used in --invariant
/// expressions and in the instantiation itself) from chuggy_measure
/// directly — same structure as v1's mc_small.

/// Budgeted gate pricing: a landing failure costs 1 gate budget AND 1 gas;
/// the gate wall (gate_budget_exhausted) is reachable.
module mc_chuggy_budgeted {
  import chuggy_measure.* from "../measure"
  import chuggy_domain(
    N_JOBS = 3,
    N_TASKS = 2,
    REWORK_BUDGET = 1,
    DEADLINE = 3,
    GATE_PRICING = Budgeted(1),
    OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2
  ).* from "../domain"
}

/// DeadlineOnly gate pricing: a landing failure costs gas alone — v1's
/// unbudgeted gate loop, metered only by the (required) deadline.
module mc_chuggy_deadline_only {
  import chuggy_measure.* from "../measure"
  import chuggy_domain(
    N_JOBS = 3,
    N_TASKS = 2,
    REWORK_BUDGET = 1,
    DEADLINE = 3,
    GATE_PRICING = DeadlineOnly,
    OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2
  ).* from "../domain"
}

/// RetryFree metering (v1's model-status §5b operator churn, kept as a
/// configuration): allInvariants must still HOLD here — free resumes are
/// exactly the exempted CHURN arm of stepDescends — while the
/// freeClimbNever witness must be VIOLATED (check.sh Stage 9's
/// expected-violation run proves the exemption is exercised, not dead).
/// DEADLINE = 2 keeps escalations frequent so retries are common. The
/// PR 3 churn bound is exercised here too: a free REvaluating resume
/// respawns the LOWEST stage's fan-out with the full stage digit
/// (measure.qnt CHURN set).
module mc_chuggy_retryfree {
  import chuggy_measure.* from "../measure"
  import chuggy_domain(
    N_JOBS = 2,
    N_TASKS = 2,
    REWORK_BUDGET = 1,
    DEADLINE = 2,
    GATE_PRICING = DeadlineOnly,
    OP_RETRY_PRICING = RetryFree,
    MAX_STAGES = 2
  ).* from "../domain"
}
