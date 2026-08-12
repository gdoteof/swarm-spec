/// Port of the `table_edges` test at the bottom of chuggernaut
/// crates/domain/src/state.rs (mod tests): the same legal and illegal edge
/// enumerations, in the same order, plus completeness-style checks over the
/// whole state space that the Rust test spells out edge-by-edge.
module table_test {
  import chug_types.* from "../types"
  import chug_table.* from "../table"

  pure val allStates = Set(
    Draft, Frozen, Batched, Blocked, Ready, Work,
    Evaluation, WrapUp, Escalated, Stalled, Done, Revoked
  )

  /// The legal edges from state.rs `table_edges`, same order.
  pure val legalEdges: List[(JobState, JobState)] = [
    (Draft, Ready),
    (Draft, Blocked),
    (Draft, Frozen),
    (Draft, Revoked),
    (Frozen, Draft),
    (Frozen, Ready),
    (Frozen, Blocked),
    (Frozen, Batched),
    (Batched, Frozen),
    (Batched, Done),
    (Batched, Revoked),
    (Blocked, Ready),
    (Blocked, Stalled),
    (Ready, Work),
    (Ready, Stalled),
    (Work, Evaluation),
    (Evaluation, Work),
    (Evaluation, WrapUp),
    (Evaluation, Done),
    (WrapUp, WrapUp),
    (WrapUp, Work),
    (WrapUp, Done),
    (WrapUp, Escalated),
    (Escalated, Work),
    (Escalated, Evaluation),
    (Escalated, WrapUp),
    (Stalled, Ready),
    (Stalled, Stalled),
    (Frozen, Revoked),
    (Escalated, Revoked),
    (Stalled, Revoked),
    (WrapUp, Revoked)
  ]

  /// The illegal edges from state.rs `table_edges`, same order.
  pure val illegalEdges: List[(JobState, JobState)] = [
    (Draft, Work),
    (Draft, Evaluation),
    (Frozen, Work),
    (Frozen, Done),
    (Batched, Work),
    (Batched, Ready),
    (Batched, Blocked),
    (Blocked, Work),
    (Blocked, Escalated),
    (Ready, Escalated),
    (Ready, Evaluation),
    (Ready, Done),
    (Work, Done),
    (Work, WrapUp),
    (Done, Work),
    (Done, Revoked),
    (Revoked, Revoked),
    (Escalated, Done),
    (Escalated, Ready),
    (Stalled, Work),
    (Stalled, Evaluation),
    (Stalled, Escalated),
    (WrapUp, Ready),
    (WrapUp, Evaluation)
  ]

  /// Every legal edge is allowed.
  run legalEdgesTest =
    assert(legalEdges.foldl(true, (acc, e) => acc and allowedTransition(e._1, e._2)))

  /// Every illegal edge is rejected — including Done->Revoked, Revoked->Revoked,
  /// Work->Done (work never skips evaluation), Ready->Evaluation, Blocked->Work,
  /// Draft->Work.
  run illegalEdgesTest =
    assert(illegalEdges.foldl(true, (acc, e) => acc and not(allowedTransition(e._1, e._2))))

  /// Work->Done must be false: work never skips evaluation.
  run workNeverSkipsEvaluationTest =
    assert(not(allowedTransition(Work, Done)))

  /// Terminal states are absorbing: nothing leaves Done or Revoked,
  /// to any state — including Revoked itself.
  run terminalStatesAbsorbingTest =
    assert(allStates.forall(s =>
      not(allowedTransition(Done, s)) and not(allowedTransition(Revoked, s))))

  /// The `(_, Revoked) => true` clause: every non-terminal state may be revoked.
  run everyNonTerminalMayRevokeTest =
    assert(allStates.forall(s => not(isTerminal(s)) implies allowedTransition(s, Revoked)))

  /// Completeness over all state pairs: an allowed transition never
  /// originates in a terminal state.
  run allowedImpliesNonTerminalSourceTest =
    assert(allStates.forall(from =>
      allStates.forall(t => allowedTransition(from, t) implies not(isTerminal(from)))))
}
