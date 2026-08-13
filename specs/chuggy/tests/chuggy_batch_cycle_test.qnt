/// THE GROUP-DEP CYCLE (finding, against PR 5's R7): absorption can build
/// a dependency cycle through the DERIVED union, deadlocking the group and
/// its dep forever — and no invariant in allInvariants sees it, because
/// depsAcyclic quantifies over STORED deps (which stay acyclic) and
/// stuckSet's only base case is PEscalated (which a pure cycle never
/// reaches).
///
/// The machine trace below is built with chuggy_witness_test.qnt's driver
/// discipline: every driver conjoins the machine action's own enablement
/// guard, so the state it reaches is reachable by `step`, not by a
/// loosened relation. Consts are byte-identical to
/// chuggy_witness_batch_test's instance.
module chuggy_batch_cycle_test {
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

  action doArrive(deps_: Set[int], prog: List[Stage], repo_: int): bool = all {
    canArrive,
    deps_.subseteq(dependableTickets),
    validPrograms.contains(prog),
    repos.contains(repo_),
    apply(decideArrive(core, deps_, prog, repo_))
  }
  action doRelease(j: int): bool = all {
    draftTickets.contains(j),
    apply(decideRelease(core, j))
  }
  action doAbsorb(l: int, m: int): bool = all {
    absorbableIn(core, l, m),
    apply(decideAbsorb(core, l, m))
  }

  pure val progFlat1: List[Stage] = [{ fanout: 1, combinator: CUnanimousPass }]

  /// Transitive closure of the STORED deps (acyclic by construction, so
  /// the fold saturates within one sweep per live ticket).
  pure def depsReach(c: Core, k: int): Set[int] =
    range(1, c.tickets.keys().size() + 1).foldl(c.tickets.get(k).deps,
      (acc, _) => acc.union(acc.fold(Set(),
        (a, d) => a.union(c.tickets.get(d).deps))))

  /// THE PROPOSED INVARIANT (the fix's shape): the group is CONVEX in the
  /// dep DAG — no ticket outside the group sits on a dep path between two
  /// of its members. Equivalently, at the derived edge: nothing the group
  /// still WAITS on may depend, transitively, back on the group. Violated
  /// by the trace below; `absorbableIn`'s direct-dep check is strictly
  /// weaker. Done tickets are filtered from both sides: a satisfied dep
  /// gates nothing, so a path through one is not a wait.
  pure def groupDepsAcyclic(c: Core): bool =
    c.tickets.keys().forall(l =>
      val g = Set(l).union(membersOf(c, l))
      groupDeps(c, l).filter(d => c.tickets.get(d).phase != PDone)
        .forall(d => depsReach(c, d)
          .filter(k => c.tickets.get(k).phase != PDone)
          .intersect(g) == Set()))

  /// A -> nothing, X -> A, B -> X. Absorbing B under lead A is permitted
  /// (A does not DIRECTLY dep B), and the union then makes the group wait
  /// on X while X waits on the lead.
  run groupDepCycleTest =
    init
      .then(doArrive(Set(), progFlat1, 1))         // 1 = A, the lead
      .expect(allInvariants)
      .then(doArrive(Set(1), progFlat1, 1))        // 2 = X, deps A
      .expect(allInvariants)
      .then(doArrive(Set(2), progFlat1, 1))        // 3 = B, deps X
      .expect(allInvariants)
      .then(doRelease(1))
      .expect(and { isReady(1), allInvariants })
      .then(doRelease(2))
      .expect(and { isBlocked(2), allInvariants })
      .then(doRelease(3))
      .expect(and { isBlocked(3), allInvariants })
      // THE ABSORPTION THE GUARD ALLOWS. absorbableIn's last conjunct
      // ("the lead never absorbs its own dependency") is satisfied: the
      // lead deps NOTHING. The path A <- X <- B is two hops, and a
      // direct-dep check cannot see it.
      .then(doAbsorb(1, 3))
      .expect(and {
        lastStep.label == "ticket-batched",
        tickets.get(3).phase == PBatched,
        membersOf(core, 1) == Set(3),
        // THE CYCLE, stated: the group waits on X...
        groupDeps(core, 1) == Set(2),
        // ...and X waits on the lead of that same group.
        tickets.get(2).deps == Set(1),
        // Consequence: nothing can ever dispatch or land.
        isBlocked(1),
        isBlocked(2),
        readyTickets == Set(),
        not(dispatchableIn(core, 1)),
        not(dispatchableIn(core, 2)),
        // THE MODEL DOES NOT SEE IT — every existing invariant is green
        // on this permanently deadlocked state.
        depsAcyclic,                    // stored deps: still acyclic
        stuckSet == Set(),              // nobody is "non-progressing"
        deskVisibility,                 // holds VACUOUSLY: no human owns it
        allInvariants,
        // ...and the proposed invariant is what catches it.
        not(groupDepsAcyclic(core))
      })

  /// The same shape one hop shorter, to show the existing guard is doing
  /// real work and this finding is about its REACH, not its absence:
  /// with the lead depping the member DIRECTLY, absorption is refused.
  run directDepStillRefusedTest =
    init
      .then(doArrive(Set(), progFlat1, 1))         // 1
      .then(doArrive(Set(1), progFlat1, 1))        // 2, deps 1
      .then(doRelease(1))
      .then(doRelease(2))
      .expect(and {
        // 2 deps 1, so 2 may not absorb 1 (the existing conjunct)...
        not(absorbableIn(core, 2, 1)),
        // ...but the DIRECTED reading is allowed, and is safe: the
        // member-on-lead dep drops out of the union harmlessly.
        absorbableIn(core, 1, 2),
        groupDepsAcyclic(core)
      })
      .then(doAbsorb(1, 2))
      .expect(and {
        groupDeps(core, 1) == Set(),    // the member-on-lead dep drops out
        isReady(1),
        groupDepsAcyclic(core),         // no cycle: this one is fine
        allInvariants
      })
}
