/// The spec §2.1 job-state transition table, transcribed VERBATIM from
/// chuggernaut crates/domain/src/state.rs:22-45 (`assert_transition`).
///
/// Clause order is preserved exactly: like the Rust `match`, the first
/// matching clause below wins. This matters for the terminal states —
/// `(Done | Revoked, Revoked) => false` sits BEFORE the `(_, Revoked) => true`
/// catch-all, so Done and Revoked are absorbing (nothing leaves them, not
/// even to Revoked) while every non-terminal state may go to Revoked.
///
/// Quint 0.32 has no tuple pattern matching over two sum values, so each Rust
/// clause becomes one `else if` arm of a first-match-wins chain; one comment
/// per Rust clause. Do not reorder or "simplify" — state.rs is the source of
/// truth.
///
/// Note: the second parameter is `to_` because `to` is a Quint builtin
/// (the integer range operator `i.to(j)`) and cannot be shadowed.
module chug_table {
  import chug_types.* from "./types"

  pure def allowedTransition(from: JobState, to_: JobState): bool =
    // (Draft, Ready | Blocked | Frozen) => true
    if (from == Draft and (to_ == Ready or to_ == Blocked or to_ == Frozen)) true
    // (Frozen, Draft) => true
    else if (from == Frozen and to_ == Draft) true
    // (Frozen, Ready | Blocked) => true
    else if (from == Frozen and (to_ == Ready or to_ == Blocked)) true
    // (Frozen, Batched) => true
    else if (from == Frozen and to_ == Batched) true
    // (Batched, Frozen | Done) => true
    else if (from == Batched and (to_ == Frozen or to_ == Done)) true
    // (Blocked, Ready | Stalled) => true
    else if (from == Blocked and (to_ == Ready or to_ == Stalled)) true
    // (Ready, Work | Stalled) => true
    else if (from == Ready and (to_ == Work or to_ == Stalled)) true
    // (Work, Work | Evaluation | Escalated) => true
    else if (from == Work and (to_ == Work or to_ == Evaluation or to_ == Escalated)) true
    // (Evaluation, Evaluation | Work | WrapUp | Done | Escalated) => true
    else if (from == Evaluation and (to_ == Evaluation or to_ == Work or to_ == WrapUp or to_ == Done or to_ == Escalated)) true
    // (WrapUp, WrapUp | Work | Done | Escalated) => true
    else if (from == WrapUp and (to_ == WrapUp or to_ == Work or to_ == Done or to_ == Escalated)) true
    // (Escalated, Work | Evaluation | WrapUp) => true
    else if (from == Escalated and (to_ == Work or to_ == Evaluation or to_ == WrapUp)) true
    // (Stalled, Ready | Stalled) => true
    else if (from == Stalled and (to_ == Ready or to_ == Stalled)) true
    // (Done | Revoked, Revoked) => false  -- terminal states are absorbing
    else if ((from == Done or from == Revoked) and to_ == Revoked) false
    // (_, Revoked) => true  -- every non-terminal state may be revoked
    else if (to_ == Revoked) true
    // _ => false
    else false

  /// Mirrors `JobState::is_terminal` in chuggernaut crates/types/src/job.rs.
  pure def isTerminal(s: JobState): bool =
    s == Done or s == Revoked
}
