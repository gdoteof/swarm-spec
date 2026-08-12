# specs/chuggy — the chuggy-model (PR 1)

The fresh Quint model for **chuggy**, written *before* the system it
specifies. Requirements and provenance: [docs/chuggy-charter.md](../../docs/chuggy-charter.md).
The direction of authority is reversed from v1 (`specs/chuggernaut/`, which
chased an existing implementation): **this model emits the golden traces;
`chuggy`'s CI replays them** — the implementation grows up against the
model, never the other way around (charter §5, standing rule 4). Until the
monorepo exists, conformance traces ship from here as versioned artifacts.

## Module map

| File | Module | What it is |
|---|---|---|
| `measure.qnt` | `chuggy_measure` | **Written first** (standing rule 1). The per-job well-founded termination measure — lexicographic over the bounded accounts (deadline gas, gate budget when `Budgeted`, rework budget, then within-cycle progress: phase rank, running-task count) — plus the record vocabulary it is a pure function of, the descent table, and the two named non-descending sets (STUTTER, CHURN). No attempt digit: the model prices cycles, not container relaunches. The machine was designed to fit this file. |
| `domain.qnt` | `chuggy_domain` | The core machine both §4 fork shapes share: pure deciders (`decide*`) over observed `Core` state, the state/actions layer, and the invariants (which must live inside the module that declares the vars — Quint 0.32). Stored phases are few: `PPending | PWorking | PEvaluating | PLanding | PDone | PEscalated | PStalled`; **Blocked, Ready, and the open-human-task flag are derived predicates**, not stored state (standing rule 3), so the unblock cascade does not exist as machinery and the desk-task iff holds by construction. |
| `mc/mc_chuggy.qnt` | `mc_chuggy_budgeted`, `mc_chuggy_deadline_only`, `mc_chuggy_retryfree` | Small-scope instances: one per `GatePricing` branch (charter §2: parameterize and decide on evidence) plus a `RetryFree` instance that keeps the operator-churn exemption in `stepDescends` exercised; invariants wired for `--invariant=allInvariants`. |
| `tests/chuggy_test.qnt` | `chuggy_test` | Pure unit tests over deciders + measure: strict descent on every transition the descent table claims, stutter/churn classification pinned, effect-exclusivity on happy + duplicate paths, every wall's name, both gate prices, both retry meterings, machine-level combinator coverage (`CAnyPass` vs `CUnanimousPass` on the same state), init's rejection of deadline-less graphs. |

Checked by `scripts/check.sh` Stage 9 (typecheck + unit tests + invariant
simulation on all three instances + the expected-violation churn witness)
and `just chuggy`.

## What the model claims (PR 1)

- **Effect-only exclusivity** (charter §2): any number of task executions
  may run and duplicate — the fabric is at-least-once, `no-double-pods` was
  dropped — but the landing effect is emitted **exactly once per job**,
  proved at the landing boundary (`landingExclusive`) and nowhere else.
  Duplicate task completions and duplicate landing deliveries are
  idempotent no-ops by construction.
- **Deadline required** (charter §2): `init` admits **no state** for a
  graph without deadline gas — invalid, not merely unmetered.
- **Named walls**: every desk parking carries its reason — `work_failed`,
  `rework_budget_exhausted`, `gate_budget_exhausted` (only under
  `Budgeted`), `job_deadline_exceeded`, `revalidation_failed`. The wall
  *vocabulary* is carried from v1's explainer (docs/chuggernaut.md §5) and
  constrained by the charter §2 termination row (which commits the
  terminals); the charter itself does not name individual walls.
- **Landing outcomes precisely named** (charter §2): `AdvanceDefault` ≠
  `SquashMerge` from day one — v1's single conformance divergence lived
  exactly there. Mechanics stay abstract (PR 5).
- **Visibility** (charter §2, definition contested per §4): every
  non-progressing job is reachable from an open human task
  (`deskVisibility`), with *progressing* read as measure-descent — stated
  and checked (structurally a corollary of the desk being derived state),
  while §4 decides whether it stays a theorem or becomes a report.
- **Per-job liveness, sketched** (the PR 1 gate): every step outside the
  named STUTTER/CHURN sets strictly decreases a nonnegative measure
  (`measureDescends`); under the default `RetryCharged` metering the churn
  set shrinks to `stalled-retry` alone. The RetryFree churn arm is proved
  non-vacuous by Stage 9's expected-violation witness (`freeClimbNever`).
  The full argument is the `measure.qnt` header.

## Deliberately absent — and which PR restores it

| Absent | Why / restored by |
|---|---|
| Authoring lifecycle | Roadmap **PR 2** (first-class rank #1). `init`'s nondet DAG is the placeholder job source, funneled through `freshJob` so authoring attaches without decider surgery. |
| Below-cycle retry machinery (attempt counters, work-retries walls) | **Never** — charter §2 non-goals ("no retry machinery below the cycle"); container relaunches are the trusted `backoffLimit` fabric axiom. A failed Work task set resolves at cycle level: `work_failed`. |
| Task anatomy depth (per-task budgets, heterogeneous sets, real eval programs) | **PR 3** — the eval interpreter stays a verdict combinator until a real `eval/vocabulary` example exists (charter §3); Work's combinator is hardcoded unanimous until then. |
| Multi-repo | **PR 4** (isolation invariants). |
| Merge-queue + landing mechanics | **PR 5**, deliberately last, driven by `landing/requirements` once answered. Only the outcome names are pinned now. |
| Refinement layer (reconcile vs journaled-actor semantics) | Blocked on the charter §4 fork conversation; this machine is exactly the layer both shapes share. The observed/actual split it will introduce is also what would make mid-rework duplicate deliveries dangerous — see the duplicate-adversary scope note on `taskDone`. |
| System-quiescence theorem (v1's `envActive`/`quiesce` apparatus) | Charter §4's contested half. Per-job is the committed theorem; quiescence would return in a severable module that constrains nothing if abandoned. |
| Scheduler, agent-slot count, FIFO ready queue | **Non-goal** (charter §2: no bespoke scheduler; quota/scheduling are trusted fabric axioms). Dispatch is a nondet pick among Ready jobs. |
| Token/API spend | **Never** a model variable (charter §2 currency row: observed only; the model keeps one gas). |
| Multi-tenancy, dynamic DAGs, cross-cluster | In scope by silence (charter §3) but admitted in **no** PR yet — each enters only by explicit decision. |
| Apalache verification, seeded witness batteries, golden-trace projection for chuggy | Harness depth, not machine shape: PR 1's gate is typecheck + unit tests + invariant simulation (+ one expected-violation churn witness). The v1-style verify/witness/projection stages follow once the trace consumer (chuggy CI) exists. |

## Relation to v1 (`specs/chuggernaut/`)

Same discipline (pure deciders, guard/effect split, invariants beside the
vars, golden-trace-shaped `StepRecord`), smaller machine, and four v1
lessons priced in: operator retries **charge by default** (v1's discovered
§5b livelock), landing success outcomes are **two named effects** (v1's
conformance divergence), Blocked/Ready and the desk-task flag are
**derived** (v1 stored them and had to model the unblock cascade and prove
the desk iff), and v1's inner work-retry loop maps to the **trusted
`backoffLimit` fabric axiom** — chuggy prices cycles, not container
relaunches, so there is no attempt counter to bound and no retries wall to
name.
