# specs/chuggy — the chuggy-model (PRs 1–3)

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
| `measure.qnt` | `chuggy_measure` | **Written first** (standing rule 1). The per-job well-founded termination measure — lexicographic over the bounded accounts (deadline gas, gate budget when `Budgeted`, rework budget, then within-cycle progress) — plus the record vocabulary it is a pure function of, the descent table, and the named non-descending sets (STUTTER, CHURN, AUTHORING). PR 3 split the micro digit in three: **phase rank, then `stagesLeft` (the new within-phase eval-stage digit), then running-task count**, with the digit-order argument documented in the header (stage advance must dominate the next stage's fan-out; a rank step must dominate the whole stage digit appearing) and every changed weight re-derived: `stageWeight = nTasks+1` (new), `rankWeight = (maxStages+1)·stageWeight` (was `nTasks+1`), `microBound = 7·rankWeight` (multiplier unchanged). The vocabulary grew the PR 3 anatomy: `Task` = identity + kind (`TKWork` / `TKEval(stage)`) + outcome (`TCancelled` added for revoke-time force-close), `Stage` = fan-out + combinator, `Job.program` (the authored eval program) and `Job.record` (the retained chronological task log — **not** a measure input: append-only provenance). The machine was designed to fit this file. |
| `domain.qnt` | `chuggy_domain` | The core machine both §4 fork shapes share: pure deciders (`decide*`) over observed `Core` state, the state/actions layer, and the invariants (which must live inside the var-declaring module — Quint 0.32). PR 3: **the eval program is data on the job record** (an ordered list of stages, authored, arriving with the Draft through the `freshJob` seam; `validPrograms` is the arrival-refusal rule) and **`decideEvalStageReduce` is the interpreter** — advance on a passing non-final stage (`eval-stage-passed`, an `Evaluating → Evaluating` transition), land on the final stage, **short-circuit into the unchanged rework/escalation economy** on a failing stage. Task sets are spawned with history-unique sequential ids and **retired into the per-job record** at every reduce/escalation/revoke, so stale completions from earlier stages/incarnations no-op **by identity**. |
| `mc/mc_chuggy.qnt` | `mc_chuggy_budgeted`, `mc_chuggy_deadline_only`, `mc_chuggy_retryfree` | Small-scope instances: one per `GatePricing` branch (charter §2: parameterize and decide on evidence) plus a `RetryFree` instance that keeps the operator-churn exemption in `stepDescends` exercised; invariants wired for `--invariant=allInvariants`. All three run **with programs enabled** (`MAX_STAGES = 2`: arrivals draw nondet from all 20 well-formed programs at these bounds). The `EVAL_COMBINATOR` const is gone — combinators live on each job's program. |
| `tests/chuggy_test.qnt` | `chuggy_test` | Pure unit tests over deciders + measure: strict descent on every transition the descent table claims, stutter/churn classification pinned, effect-exclusivity on happy + duplicate paths, every wall's name, both gate prices, both retry meterings, init's rejection of deadline-less graphs, the full PR 2 authoring/revoke/cascade suite — and the PR 3 suite: a two-stage program walked edge-by-edge (advance descends; the `Evaluating → Evaluating` record pinned), short-circuit priced exactly (1 rework + 1 gas; the skipped stage's tasks **never exist**), the golden fixture's escalate shape, rework restarting from the lowest stage, evaluator-crash-equals-job-pays account deltas, stale-stage completions no-oping by identity, retained records end-to-end (including revoke's `TCancelled` force-close), and **program-as-data at machine level**: two jobs in one instance, identical but for their programs, deciding differently — by combinator *and* by structure. |

Checked by `scripts/check.sh` Stage 9 (typecheck + unit tests + invariant
simulation on all three instances + **three** expected-violation witnesses:
the churn climb, PR 2's cascade-reachability probe, and PR 3's
stage-advance-reachability probe) and `just chuggy`.

## The PR 3 eval vocabulary — extracted, standing in

The intake question `eval/vocabulary` ("write the eval spec for one real
job type") was **never answered** (charter §3), so PR 3's gate — pin the
phase-outcome combinators with a real example — is discharged against the
real thing chuggy succeeds: **the vocabulary is extracted from chuggernaut
itself**, and it **stands in until the intake `eval/vocabulary` answer
confirms or overrides it**. Sources, cited per decider in the code:

- chuggernaut `docs/spec.md` §3.3 "Evaluation" / "Staged progression":
  evaluators run as an ascending sequence of **stages** (`stage:`, default
  0); within a stage tasks **fan out in parallel**; a stage completes when
  all its tasks are terminal; every required evaluator passing **creates
  the next stage's tasks**; any required failure means later stages are
  *"skipped, not failed, so no task records exist for them"* and the
  reduce proceeds immediately; a rework cycle *"restarts from the lowest
  stage — stages are recomputed per cycle, never resumed mid-sequence"*;
  a single-stage program is *"byte-for-byte the single-fan-out behavior"*
  (the compatibility story that preserves the PR 1–2 default shape).
- chuggernaut `docs/spec.md` §2.1 state machine, line 832: `Evaluation →
  Evaluation` is a real table row — the stage advance is a within-phase
  edge, not a new phase.
- chuggernaut `docs/spec.md` §1.2 "Task": tasks are *"a chronological
  log"*, id *"sequential within job, 1-indexed"*, carrying kind and state;
  *"Revoke closes tasks"* (pending tasks force-closed with a synthetic
  resolution); escalation `Retry` on eval exhaustion re-enters Evaluation
  with *"a fresh eval fan-out"*.
- The golden fixture `staged_eval_short_circuit.yaml` (replayed by
  `specs/chuggernaut/tests/conformance/conformance_staged_eval_short_circuit_test.qnt`,
  whose header explicitly gates the staged content on this model) and
  `docs/trace-conformance.md` §2.1–2.2: *"stage-0 fails → stage 1 never
  launched → escalate"*, exactly one fan-out `task-created`.

How it mapped: stage list → `Job.program: List[Stage]`; per-stage
required-pass rule → per-stage `Combinator` (unanimous default, charter
§2); staged progression → `decideEvalStageReduce`'s advance edge; the
short-circuit → the same decider's failure arm routing into the **existing**
rework/escalation economy; the chronological task log → `Job.record` with
history-unique sequential ids; revoke's force-close → `TCancelled`.

## What the model claims (PRs 1–3)

- **Effect-only exclusivity** (charter §2): any number of task executions
  may run and duplicate — the fabric is at-least-once, `no-double-pods` was
  dropped — but the landing effect is emitted **exactly once per job**,
  proved at the landing boundary (`landingExclusive`) and nowhere else.
  Duplicate task completions and duplicate landing deliveries are
  idempotent no-ops by construction — and PR 3 strengthened the stale
  half: task ids are unique across a job's whole history, so a stale
  completion from an earlier stage or incarnation no-ops **by identity**
  (PR 1 had to absorb it into the nondet verdict of a respawned same-id
  task; that argument is retired).
- **Deadline required** (charter §2): `init` admits **no state** for a
  graph without deadline gas — invalid, not merely unmetered.
- **Eval is data, not machinery** (charter §2, the PR 3 gate): each job
  carries an **authored eval program** — an ordered list of stages, each a
  parallel task-set with its own verdict combinator — run by one
  interpreter (`decideEvalStageReduce`). Two jobs in the same machine
  instance with different programs behave differently (the PR 1 combinator
  lesson generalized, machine-checked). The charter's default is preserved
  as data: `defaultProgram` = one stage, full fan-out, unanimous — a job
  carrying it reproduces the PR 1–2 machine exactly. Program
  well-formedness is an **arrival validity condition**: non-empty, at most
  `MAX_STAGES` stages, every fan-out in `1..N_TASKS`, or arrival refuses
  (`validPrograms`; invariant `programsWellFormed`).
- **A failing stage short-circuits into the same economy** (extracted
  vocabulary + charter §2 evaluator-crash row): later stages are never
  created — no task records exist for them — and the job pays the
  **existing** price: 1 rework + 1 gas for a new cycle (which restarts
  from the lowest stage), or the existing walls when an account is empty.
  An evaluator crash is a `TFailed` inside the stage — **the job pays**,
  one account, no new machinery, no new wall.
- **Task records are first-class and retained** (charter §2 job anatomy):
  every task carries identity (sequential within the job, never reused),
  kind (work vs evaluator-stage), and outcome; retired sets append to the
  per-job chronological `record` — provenance the golden traces can carry.
  `recordWellFormed` pins the log's shape; `recordMonotone` (against a
  one-step ghost, like `stepDescends`) makes "retained" a theorem: nothing
  shrinks, nothing settled is ever rewritten. Revoke retires a mid-flight
  set as `TCancelled` and **keeps the history** — "Revoked runs nothing"
  is about the live set, not the log.
- **Named walls**: every desk parking carries its reason — `work_failed`,
  `rework_budget_exhausted`, `gate_budget_exhausted` (only under
  `Budgeted`), `job_deadline_exceeded`, `revalidation_failed`, and (PR 2)
  `dependency_revoked`. PR 3 added **no wall** and **no account**.
- **Landing outcomes precisely named** (charter §2): `AdvanceDefault` ≠
  `SquashMerge` from day one — v1's single conformance divergence lived
  exactly there. Mechanics stay abstract (PR 5).
- **Visibility** (charter §2, definition contested per §4): every
  non-progressing job is reachable from an open human task
  (`deskVisibility`), with *progressing* read as measure-descent — stated
  and checked (structurally a corollary of the desk being derived state),
  while §4 decides whether it stays a theorem or becomes a report.
- **Per-job liveness, sketched — conditional on authors** (the PR 1
  gate, extended by PR 2; PR 3 changed the digits, not the argument):
  every step outside the named STUTTER/CHURN/AUTHORING sets strictly
  decreases a nonnegative measure (`measureDescends`) — including the new
  stage advance, which gets **no exemption**: the stage digit dominates
  the next stage's fan-out by construction (`stageWeight = nTasks+1`).
  Under the default `RetryCharged` metering the churn set is
  `stalled-retry` alone. All three non-descending exemptions are proved
  non-vacuous by Stage 9/9b's expected-violation witnesses
  (`freeClimbNever`, `cascadeParkNever`, and PR 3's `stageAdvanceNever` —
  the machine-level proof that multi-stage programs actually run).
- **Authoring lifecycle** (PR 2, first-class rank #1): jobs arrive as
  Drafts (the fleet starts empty), freeze and release strictly descend,
  the unfreeze edit loop is named churn. PR 3 rides it: the eval program
  **arrives with the Draft** — which is exactly why authoring came first.
- **Revoked never lands** (PR 2): `PRevoked` is absorbing, runs nothing,
  has emitted no landing effect and never will (`revokedNeverLands`), and
  opens **no human task**.
- **Cascade safety** (the PR 2 gate): `decideRevoke` **atomically parks**
  every pre-flight transitive dependent on the desk behind the
  `dependency_revoked` wall, each with its own open human task
  (`cascadeSafety`, checked in every reachable state).

## Deliberately absent — and which PR restores it

| Absent | Why / restored by |
|---|---|
| `Batched` (the authoring table's merge-queue state) | **PR 5**, with the merge queue it serves (`table.qnt` lines 27–30 not transcribed until then). |
| **Staged merge gate** (chuggernaut spec.md §3.3 Merge Gate item 3: gate stages, failure classification, the gate-fix fast path) | **PR 5**, with the gate itself — the extracted vocabulary shows the gate reusing stage structure, but chuggy's landing stays one abstract outcome until `landing/requirements` is answered. |
| **Per-task budgets / attempt counters** (chuggernaut §1.2 `work_retries`, `eval_retries`, `attempt`) | **Never** — the extracted vocabulary *does* carry them, and PR 3 deliberately does **not** import them: they are retry machinery below the cycle, a charter §2 non-goal; container relaunches are the trusted `backoffLimit` fabric axiom. Tasks carry identity + kind + outcome, no attempt digit (measure.qnt header re-affirms). |
| **Required vs advisory evaluators** (`required: false` never blocks, §3.3) | Below the model's grain, absorbed into the per-stage **combinator**: an advisory evaluator is one the stage's combinator ignores. Becomes vocabulary only if the intake answer demands per-task requiredness. |
| **Abort verdict** (`abort: true` skips remaining rework budget, §1.2/§3.3) and **infra-fail escalates immediately** (a required task Failed-as-infra skips rework, §3.3 reduce) | Folded into `TFailed`-fails-the-stage: the charter's evaluator-crash row prices all of it identically (**the job pays**, one account). The chuggernaut distinction is real, though — **flagged as a question for the intake `eval/vocabulary` confirmation**, not silently adopted or silently dropped. |
| **The approval gate** (a synthesized required Human evaluator at `max(stage)+1`, §3.3) | Not synthesized by the model: it is *expressible* as data (a final stage), and synthesizing it at resolution time is an authoring/implementation concern. Revisit with the humans agenda if the intake answer asks for it. |
| Dep re-authoring (editing a doomed job's deps out of a revoked chain) | Not scheduled; the `dependency_revoked` wall's only modeled exit is revoke (the documented table-line-44 deviation at `stallRetryableIn`). |
| Multi-repo | **PR 4** (isolation invariants). |
| Merge-queue + landing mechanics | **PR 5**, deliberately last, driven by `landing/requirements` once answered. Only the outcome names are pinned now. |
| Refinement layer (the journaled actor — single-writer crash/recover, record-vs-effect atomicity) | Resolved to the **journaled actor** (service + dumb K8s Jobs, charter §4, offline 2026-08-12): roadmap **PR 6**. The observed/actual split it introduces is also what would make mid-rework duplicate deliveries dangerous — see the duplicate-adversary scope note on `taskDone`. |
| System-quiescence theorem (v1's `envActive`/`quiesce` apparatus) | Charter §4's contested half. Per-job is the committed theorem; quiescence would return in a severable module that constrains nothing if abandoned. |
| Scheduler, agent-slot count, FIFO ready queue | **Non-goal** (charter §2). Dispatch is a nondet pick among Ready jobs. |
| Token/API spend | **Never** a model variable (charter §2 currency row; chuggernaut's per-task `token_usage` stays implementation accounting). |
| Multi-tenancy, dynamic DAGs, cross-cluster | In scope by silence (charter §3) but admitted in **no** PR yet. PR 3 does not cross the dynamic-DAG line: programs are authored at arrival, and no job-event decider creates jobs or rewrites programs. |
| Apalache verification, seeded witness batteries, golden-trace projection for chuggy | Harness depth, not machine shape: the PR 1–3 gate is typecheck + unit tests + invariant simulation (+ three expected-violation witnesses). The v1-style verify/witness/projection stages follow once the trace consumer (chuggy CI) exists. |

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
decider. Deviations, each argued in place: Ready/Blocked collapse into
derived `PPending`, `Batched` deferred to PR 5, the `dependency_revoked`
stall is not retryable, arrivals are chuggy-new, and the park-cascade is
chuggy-new design (v1 left revoke fan-out explicitly unanswerable,
model-status §6b).

PR 3 closes a loop v1 left open on purpose: v1's
`conformance_staged_eval_short_circuit_test.qnt` replays only the
transition skeleton of the staged-eval golden fixture and marks the staged
content *"below v1's one-nondet-EvalOutcome grain … checkable with the v2
staged-eval model"* (docs/trace-conformance.md §2.2, §2.4). This model is that
model, roadmap-renamed: the stage structure, the short-circuit, and the
retained task log are now machine vocabulary, extracted from the same
spec sections the fixture came from — so when chuggy's golden traces start
shipping, that fixture's content finally has a grain to land on.
