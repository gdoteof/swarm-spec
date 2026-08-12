# swarm-spec

A formal [Quint](https://quint-lang.org/) model of chuggernaut's orchestration
core: the job-state machine and the dispatcher built on it. The model exists to
verify the safety invariants the dispatcher relies on and to settle the
documented termination/livelock question about the rework cycle.

## Source of truth

The model transcribes chuggernaut, not the other way around. The load-bearing
references (paths relative to the chuggernaut repo root):

- `crates/domain/src/state.rs:22-45` — the §2.1 transition table
  (`assert_transition`); `specs/chuggernaut/table.qnt` is a verbatim,
  clause-order-preserving transcription of it.
- `crates/dispatcher/src/invariants.rs` — the executable data invariants the
  dispatcher checks after every message; later PRs model these.
- `docs/spec.md` §2.1 (state machine), §3.3 (staged evaluation, merge gate).

## Toolchain

- Node 22; Quint 0.32.0 via npm (`npm install` puts it in `node_modules`).
- Java 17 — only needed for `quint verify` (Apalache); not required for
  typecheck/test.
- [`just`](https://github.com/casey/just) — optional command runner.

## Commands

```sh
npm install          # once
just check           # full pipeline (= bash scripts/check.sh = npm run check)
just typecheck       # typecheck every .qnt file
just test            # quint unit tests only
```

Or directly:

```sh
npx quint typecheck specs/chuggernaut/table.qnt
npx quint test specs/chuggernaut/tests/table_test.qnt
```

## Roadmap

- **v1** — job lifecycle + budgets: the transition table, escalation/stall
  budgets, terminal absorption.
- **v2** — tasks + staged evaluation: task phases, attempt outcomes, §3.3
  stage ordering.
- **v3** — merge queue: landing order, merge gate, conflict/gate-failure
  rework.
- **v4** — authoring/revoke: draft editing, batches, revoke fan-out.
- **v5** — trace conformance: replaying recorded chuggernaut traces against
  the model.
