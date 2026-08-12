/// Liveness instance: the smallest configuration that still exercises every
/// loop the temporal properties reason about — 2 jobs (so one can Block on
/// the other and wedge), 1 agent (so the queue matters), 1 work retry,
/// rework budget 1, and a REAL deadline of 2: the §3.5 `job_deadline` gas
/// backstop binds almost immediately, so descent arguments stay shallow and
/// Apalache's temporal encoding stays tractable.
///
/// Checked here (see scripts/check.sh Stage 6 / `just verify-liveness`;
/// the temporal claims are discharged as safety — machine.qnt "Temporal
/// (PR4)" explains why and how):
/// - quiescentDescent HOLDS (randomized depth 40, Apalache depth 4/6) —
///   the safety encoding of the headline theorem quiescentlySettles;
/// - wedgeFree FAILS (expected) — the wedge that makes the naive
///   terminationUnderQuiescence false and forces allSettledOrWedged;
/// - gateReworksWithinBudgets HOLDS: with DEADLINE=2 the gas backstop
///   bounds the unbudgeted gate loop (contrast mc_livelock).
module mc_liveness {
  import chug_types.* from "../types"
  import chug_machine(
    N_JOBS = 2,
    N_AGENTS = 1,
    WORK_RETRIES = 1,
    REWORK_BUDGET = 1,
    DEADLINE = 2
  ).* from "../machine"
}
