/// Small concrete instance of chug_machine for simulation and (later) model
/// checking: 3 jobs, 2 agents, 1 same-cycle work retry, rework budget 1,
/// deadline gas 3. Exposes init/step for `quint run --main=mc_small`.
module mc_small {
  // Imports are not re-exported by the chug_machine instance, so pull the
  // vocabulary in directly: CLI --invariant expressions (and PR3's invariant
  // modules) need the JobState/Phase constructors in scope here.
  import chug_types.* from "../types"
  import chug_machine(
    N_JOBS = 3,
    N_AGENTS = 2,
    WORK_RETRIES = 1,
    REWORK_BUDGET = 1,
    DEADLINE = 3
  ).* from "../machine"
}
