/// The group-dep-cycle probe: mc_chuggy_budgeted's consts with the
/// proposed convexity invariant attached, so RANDOM exploration — not
/// only the deterministic trace in tests/chuggy_batch_cycle_test.qnt —
/// has to find the absorption that builds a cycle through the derived
/// dep union. Run with `--invariant=groupDepsAcyclic`; a violation is the
/// finding.
module mc_batch_cycle {
  import chuggy_measure.* from "../measure"
  import chuggy_domain(
    N_TICKETS = 3,
    N_TASKS = 2,
    REWORK_POLICY = RWBudget(1),
    GAS = 3,
    GATE_PRICING = Budgeted(1),
    OP_RETRY_PRICING = RetryCharged,
    MAX_STAGES = 2,
    N_REGIONS = 2,
    N_REPOS = 2
  ).* from "../domain"

  pure def depsReach(c: Core, k: int): Set[int] =
    range(1, c.tickets.keys().size() + 1).foldl(c.tickets.get(k).deps,
      (acc, _) => acc.union(acc.fold(Set(),
        (a, d) => a.union(c.tickets.get(d).deps))))

  val groupDepsAcyclic: bool =
    core.tickets.keys().forall(l =>
      val g = Set(l).union(membersOf(core, l))
      groupDeps(core, l).filter(d => core.tickets.get(d).phase != PDone)
        .forall(d => depsReach(core, d)
          .filter(k => core.tickets.get(k).phase != PDone)
          .intersect(g) == Set()))
}
