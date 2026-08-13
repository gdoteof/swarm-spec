# specs/chuggy — the chuggy-model (PRs 1–2)

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
| `measure.qnt` | `chuggy_measure` | **Written first** (standing rule 1). The per-job well-founded termination measure — lexicographic over the bounded accounts (deadline gas, gate budget when `Budgeted`, rework budget, then within-cycle progress: phase rank, running-task count) — plus the record vocabulary it is a pure function of, the descent table, and the named non-descending sets (STUTTER, CHURN, and PR 2's AUTHORING). PR 2 put `PDraft` (rank 6) and `PFrozen` (rank 5) above the released pipeline so freeze and release strictly descend, added `PRevoked` to the settled rank-0 tier, and re-derived the radix argument (microBound multiplier 5 → 7 for the new rank ceiling). No attempt digit: the model prices cycles, not container relaunches. The machine was designed to fit this file. |
| `domain.qnt` | `chuggy_domain` | The core machine both §4 fork shapes share: pure deciders (`decide*`) over observed `Core` state, the state/actions layer, and the invariants (which must live inside the module that declares the vars — Quint 0.32). Stored phases: `PDraft | PFrozen | PPending | PWorking | PEvaluating | PLanding | PDone | PEscalated | PStalled | PRevoked`; **Blocked, Ready, and the open-human-task flag are derived predicates**, not stored state (standing rule 3), so the unblock cascade does not exist as machinery and the desk-task iff holds by construction. PR 2: the fleet starts empty and jobs **arrive as Drafts** through the `freshJob` seam (bounded by `N_JOBS`, now the arrival cap; ids dense, never reused); revoke is legal from every non-terminal with an **atomic park-cascade** for dependents (`decideRevoke` — the design argument lives on that decider). |
| `mc/mc_chuggy.qnt` | `mc_chuggy_budgeted`, `mc_chuggy_deadline_only`, `mc_chuggy_retryfree` | Small-scope instances: one per `GatePricing` branch (charter §2: parameterize and decide on evidence) plus a `RetryFree` instance that keeps the operator-churn exemption in `stepDescends` exercised; invariants wired for `--invariant=allInvariants`. All three run the PR 2 authoring actions with small arrival bounds. |
| `tests/chuggy_test.qnt` | `chuggy_test` | Pure unit tests over deciders + measure: strict descent on every transition the descent table claims, stutter/churn classification pinned, effect-exclusivity on happy + duplicate paths, every wall's name, both gate prices, both retry meterings, machine-level combinator coverage (`CAnyPass` vs `CUnanimousPass` on the same state), init's rejection of deadline-less graphs. PR 2: the happy path starts at authoring (arrive → freeze → release), revoke is exercised from **every** table-permitted phase with account-by-account no-spend equalities, the desk-revoke flat cases and the AUTHORING climbers (arrival, unfreeze) are pinned, unreleased deps block, and the cascade runs end-to-end on a 3-job chain. |

Checked by `scripts/check.sh` Stage 9 (typecheck + unit tests + invariant
simulation on all three instances + the two expected-violation witnesses:
the churn climb and PR 2's cascade-reachability probe) and `just chuggy`.

## What the model claims (PRs 1–2)

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
  `Budgeted`), `job_deadline_exceeded`, `revalidation_failed`, and (PR 2)
  `dependency_revoked`. The wall *vocabulary* is carried from v1's
  explainer (docs/chuggernaut.md §5) and constrained by the charter §2
  termination row (which commits the terminals); the charter itself does
  not name individual walls. `dependency_revoked` is chuggy-NEW — v1 never
  modeled revoke fan-out (model-status §6b), so the cascade wall had no v1
  name to carry.
- **Landing outcomes precisely named** (charter §2): `AdvanceDefault` ≠
  `SquashMerge` from day one — v1's single conformance divergence lived
  exactly there. Mechanics stay abstract (PR 5).
- **Visibility** (charter §2, definition contested per §4): every
  non-progressing job is reachable from an open human task
  (`deskVisibility`), with *progressing* read as measure-descent — stated
  and checked (structurally a corollary of the desk being derived state),
  while §4 decides whether it stays a theorem or becomes a report.
- **Per-job liveness, sketched — now conditional on authors** (the PR 1
  gate, extended by PR 2): every step outside the named
  STUTTER/CHURN/AUTHORING sets strictly decreases a nonnegative measure
  (`measureDescends`); under the default `RetryCharged` metering the churn
  set shrinks to `stalled-retry` alone. PR 2's AUTHORING set (arrival,
  the unfreeze edit loop, desk-only revokes) makes the liveness claim
  honestly conditional: a run parks every job **provided every author
  eventually releases or revokes** — the exact charter §4 quiescence
  conditionality, stated in the `measure.qnt` header. Both non-descending
  exemptions are proved non-vacuous by Stage 9b's expected-violation
  witnesses (`freeClimbNever`, `cascadeParkNever`).
- **Authoring lifecycle** (PR 2, first-class rank #1): jobs arrive as
  Drafts (the fleet starts empty; `init`'s nondet DAG is gone), freeze
  and release strictly descend the measure, and the unfreeze edit loop is
  named churn. Vocabulary transcribed from v1's transition table
  (`specs/chuggernaut/table.qnt` lines 21–26; provenance cited per
  decider). Dependencies may point at unreleased jobs — a dep that is not
  Done blocks, with no new machinery.
- **Revoked never lands** (PR 2, the exclusivity extension): `PRevoked` is
  absorbing (`terminalsAbsorbing`, table lines 45–46), holds nothing, has
  emitted no landing effect and never will (`revokedNeverLands`), and
  opens **no human task** — revocation is the author's settled choice.
  Revoke is legal from every non-terminal (table lines 47–48) and spends
  nothing: no gas, no budgets, no refunds.
- **Cascade safety** (the PR 2 gate): a job whose dependency chain
  contains a revoked job can never unblock, so `decideRevoke` **atomically
  parks** every pre-flight transitive dependent on the desk behind the
  new `dependency_revoked` wall — each with its own open human task, whose
  only modeled exit is revoke (deps are immutable; the stalled-retry
  restriction is a documented deviation from table line 44). The
  invariant `cascadeSafety` states it deskVisibility-style: every
  transitively doomed job is parked-with-task or itself revoked, in
  **every** reachable state (the atomicity upgrades "eventually parked" to
  always-parked). Chosen over transitive cascade-*revoke* because
  auto-revoking other authors' jobs would destroy work with no human
  decision and no desk trace — the exact invisibility the visibility row
  forbids. Non-vacuous by Stage 9b's `cascadeParkNever` probe and the
  3-job-chain unit test.

## Deliberately absent — and which PR restores it

| Absent | Why / restored by |
|---|---|
| `Batched` (the authoring table's merge-queue state) | **PR 5**, with the merge queue it serves. The v1 table's `(Frozen, Batched)` and `(Batched, Frozen \| Done)` rows (`table.qnt` lines 27–30) are deliberately not transcribed until then — PR 2 took the rest of the authoring rows. |
| Dep re-authoring (editing a doomed job's deps out of a revoked chain) | Not scheduled. Deps are immutable once arrived, which is why the `dependency_revoked` wall's only modeled exit is revoke (the documented table-line-44 deviation at `stallRetryableIn`). |
| Below-cycle retry machinery (attempt counters, work-retries walls) | **Never** — charter §2 non-goals ("no retry machinery below the cycle"); container relaunches are the trusted `backoffLimit` fabric axiom. A failed Work task set resolves at cycle level: `work_failed`. |
| Task anatomy depth (per-task budgets, heterogeneous sets, real eval programs) | **PR 3** — the eval interpreter stays a verdict combinator until a real `eval/vocabulary` example exists (charter §3); Work's combinator is hardcoded unanimous until then. |
| Multi-repo | **PR 4** (isolation invariants). |
| Merge-queue + landing mechanics | **PR 5**, deliberately last, driven by `landing/requirements` once answered. Only the outcome names are pinned now. |
| Refinement layer (reconcile vs journaled-actor semantics) | Blocked on the charter §4 fork conversation; this machine is exactly the layer both shapes share. The observed/actual split it will introduce is also what would make mid-rework duplicate deliveries dangerous — see the duplicate-adversary scope note on `taskDone`. |
| System-quiescence theorem (v1's `envActive`/`quiesce` apparatus) | Charter §4's contested half. Per-job is the committed theorem; quiescence would return in a severable module that constrains nothing if abandoned. |
| Scheduler, agent-slot count, FIFO ready queue | **Non-goal** (charter §2: no bespoke scheduler; quota/scheduling are trusted fabric axioms). Dispatch is a nondet pick among Ready jobs. |
| Token/API spend | **Never** a model variable (charter §2 currency row: observed only; the model keeps one gas). |
| Multi-tenancy, dynamic DAGs, cross-cluster | In scope by silence (charter §3) but admitted in **no** PR yet — each enters only by explicit decision. PR 2's arrivals do not cross the dynamic-DAG line: arrivals are *author* actions (§3 defines dynamic DAGs as jobs **spawning** jobs), enforced structurally — `decideArrive`'s only caller is the environment action `arrive`, and no job-event decider can create a job. The line stays undrawn until a job's own decider can. |
| Apalache verification, seeded witness batteries, golden-trace projection for chuggy | Harness depth, not machine shape: the PR 1–2 gate is typecheck + unit tests + invariant simulation (+ two expected-violation witnesses: the churn climb and the cascade park). The v1-style verify/witness/projection stages follow once the trace consumer (chuggy CI) exists. |

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

PR 2's authoring vocabulary is a **transcription, not an invention**: the
Draft/Frozen/Revoked edges come row-by-row from `specs/chuggernaut/
table.qnt` (itself verbatim from chuggernaut's `state.rs`), cited at each
decider. Adopted: Draft→{Frozen, released} (lines 21–22), Frozen→Draft
(line 24, the edit loop), Frozen→released (lines 25–26), revoke from every
non-terminal (lines 47–48), absorbing terminals (lines 45–46). Deviations,
each argued in place: Ready/Blocked collapse into derived `PPending`
(PR 1's decision), `Batched` deferred to PR 5, the `dependency_revoked`
stall is not retryable (line 44 restricted — deps are immutable), arrivals
are chuggy-new (v1's jobs exist statically), and the park-cascade itself is
chuggy-new design — v1 left "revoke fan-out cascade" explicitly
unanswerable (model-status §6b).
