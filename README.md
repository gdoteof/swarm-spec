# swarm-spec

A formal [Quint](https://quint-lang.org/) model of chuggernaut's orchestration
core: the job-state machine and the dispatcher built on it. The model exists to
verify the safety invariants the dispatcher relies on and to settle the
documented termination/livelock question about the rework cycle.

**Start here to understand the system:
[docs/chuggernaut.md](docs/chuggernaut.md)** — chuggernaut itself, explained
behavior-first from the model: a job's journey, what each failure costs, and
how its story ends.

**Current status: [docs/model-status.md](docs/model-status.md)** — what is
determined (proved, and to what bound), what is unknown, and what violations
were found, in one document.

Code-level map: [docs/model-map.md](docs/model-map.md) — the module graph,
every `step` branch wired to its decider, and each transition-table edge
traced to the code that emits it.

## Source of truth

The model transcribes chuggernaut, not the other way around. The load-bearing
references (paths relative to the chuggernaut repo root):

- `crates/domain/src/state.rs:22-45` — the §2.1 transition table
  (`assert_transition`); `specs/chuggernaut/table.qnt` is a verbatim,
  clause-order-preserving transcription of it.
- `crates/dispatcher/src/invariants.rs` — the executable data invariants the
  dispatcher checks after every message; later PRs model these.
- `docs/spec.md` §2.1 (state machine), §3.3 (staged evaluation, merge gate).
- `docs/reference/lifecycle-model.md` — the same machine stated language-neutrally
  for a reimplementer: states, the event alphabet, the transition table, the
  Effect vocabulary, the invariants, the authority split and the port boundary.
  The closest prose analogue to this model, and where a disagreement between
  `docs/spec.md` and `crates/` gets adjudicated — its two open `### Finding:`
  sections are holes upstream has not closed, not settled model. One of them
  (`Draft`→`Draft`) bears directly on `specs/chuggernaut/table.qnt`.

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

`just verify-liveness` runs the deeper (slower) Apalache pass over the PR4
liveness layer; check.sh Stage 6 runs the fast version of every liveness
check.

## The headline theorem

Chuggernaut's spec openly carries a potential livelock. docs/spec.md §3.3
"Bounding" (line 1269):

> repeated gate failures don't consume `rework_budget`, so a job that
> genuinely can't integrate could loop Work → Evaluation → WrapUp (gate) →
> Work. [...] `job_deadline` is the backstop.

This PR turns that sentence into machine-checked artifacts (the formal
claims live in the "Temporal (PR4)" section of
`specs/chuggernaut/machine.qnt`; the checks in `scripts/check.sh` Stage 6).

**The loop is real (mc_livelock, expected-fail, reproduced).** On the
deadline-free instance (`DEADLINE=1000`, modeling a graph with no
`job_deadline` set), the invariant `gateReworksWithinBudgets` — "no job
takes more gate reworks than every budget combined" — is violated: the
counterexample trace is one job cycling
`dispatch → work-succeeded → eval-passed → job-rework-started
merge_gate_failure` three times over, with `rework_budget` untouched. Gate
reworks are metered by nothing but deadline gas; without a deadline, by
nothing.

**Termination is restored two ways, each with a precise caveat:**

- **(a) Environment quiescence** — the theorem `quiescentlySettles`: if the
  environment eventually goes permanently quiet, every run reaches
  `allSettledOrWedged`. Two honesty clauses baked into that statement:
  - *Operator actions count as environment.* The model gates operator
    retries on `envActive`, and the termination measure shows why it must:
    the only steps that don't strictly decrease the measure (besides the
    settled/wedged stutter) are the operator-churn actions — Retry resuming
    Evaluation/WrapUp charges no gas, so escalate → retry → fail → escalate
    is a second livelock that a finite `job_deadline` does NOT bound. In the
    real system, "wait for things to calm down" has to include the operator
    walking away, or a well-meaning retry loop defeats every budget.
  - *Settled-or-wedged, not settled.* Bare "eventually all jobs settle" is
    false even under quiescence: a job Blocked behind a dep that escalated
    before quiesce is stranded forever (the wedge — reproduced as the
    expected-fail of `wedgeFree`).
- **(b) The `job_deadline` gas backstop** — every `merge_gate_failure`
  rework charges one unit of gas, so `gateReworks ≤ DEADLINE` (PR3's
  `gateReworksBoundedByGas`, Apalache-verified) and each gate rework
  strictly decreases the termination measure. The gate loop specifically is
  always finite when a deadline is set — but per (a), the deadline alone
  does not give whole-system termination, because operator churn consumes
  no gas.

**What was proved, at what bound, by which method.** `quint verify
--temporal` is unusable in this toolchain (quint 0.32 + Apalache 0.56.1
crashes with `assertion failed` translating the temporal encoding to SMT;
the TLC backend both trips an `ApaFoldSeqLeft` evaluation bug and emits no
fairness, under which TLC's stuttering semantics refute any
eventually-property vacuously). So the temporal claims are discharged as
safety, per the tables in machine.qnt:

| Claim | Encoding | Result | Coverage |
| --- | --- | --- | --- |
| gate loop exceeds all budgets (spec.md:1269) | `gateReworksWithinBudgets` on `mc_livelock` | violated (expected) | deterministic seeded trace, 3 unbudgeted gate reworks |
| the wedge (naive quiescent termination is false) | `wedgeFree` on `mc_liveness` | violated (expected) | deterministic seeded trace |
| quiescent termination (`quiescentlySettles`) | well-founded descent: `quiescentDescent` = measure ≥ 0 ∧ every non-exempt step strictly decreases it | holds | Apalache exhaustive to depth 4 (Stage 6) / depth 6 (`just verify-liveness`) on `mc_liveness`; 20k random traces to depth 40 on both instances |
| gas bounds the gate loop | `gateReworksWithinBudgets` on `mc_liveness` (DEADLINE=2) + PR3 `gateReworksBoundedByGas` | holds | same bounds as above / PR3 Stage 5 |

The descent step is the proof's load-bearing part: bounded checking
validates every line of the hand-derived delta table (machine.qnt lists
each action's exact measure delta), and the well-founded-descent argument
on top of it is depth-independent. The bounded Apalache passes are
exhaustive only to the stated depths — that limit is stated wherever the
checks run.

## Roadmap

- **v1** — job lifecycle + budgets: the transition table, escalation/stall
  budgets, terminal absorption.
- **v2** — tasks + staged evaluation: task phases, attempt outcomes, §3.3
  stage ordering.
- **v3** — merge queue: landing order, merge gate, conflict/gate-failure
  rework.
- **v4** — authoring/revoke: draft editing, batches, revoke fan-out.
- **v5** — trace conformance: **complete, both directions**
  ([docs/trace-conformance.md](docs/trace-conformance.md)).
  *Replay* (golden → model): `scripts/gen-conformance.py` compiles the
  golden traces into Quint runs
  (`specs/chuggernaut/tests/conformance/`, check Stage 7) — 8 of 11 golden
  scenarios plus one partial skeleton replay green, transitions exact and
  effects through the modeled-vocabulary allowlist.
  *Generation* (model → candidate golden fixtures):
  `scripts/itf-to-golden.py` projects seeded simulator traces into
  candidate golden YAMLs (`just itf-golden`; committed examples in
  [docs/examples/](docs/examples/), including the budget-free gate-rework
  loop no hand-written fixture covers), round-trip-verified loss-free in
  check Stage 8; executing the candidates in chuggernaut's own harness is
  the documented upstream handoff (trace-conformance.md §3.6), untested
  here.
