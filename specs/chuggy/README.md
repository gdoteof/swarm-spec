# specs/chuggy — the chuggy-model (PRs 1–4 + the notes reconciliation + citations)

The fresh Quint model for **chuggy**, written *before* the system it
specifies. Requirements and provenance: [docs/chuggy-charter.md](../../docs/chuggy-charter.md).
The v1-review notes from geoff and davemo88 and their authoritative
disposition live in [docs/chuggy-notes-triage.md](../../docs/chuggy-notes-triage.md);
that triage's "changed now" table IS the **notes-reconciliation PR**, which
reshaped everything below after PRs 1–3 merged (each change summarized in
its own section here), and its "recorded for a later PR" citations row is
the **citations PR** (its own section below). The direction of authority is reversed from v1
(`specs/chuggernaut/`, which chased an existing implementation): **this
model emits the golden traces; `chuggy`'s CI replays them** — the
implementation grows up against the model, never the other way around
(charter §5, standing rule 4). Until the monorepo exists, conformance
traces ship from here as versioned artifacts.

## Module map

| File | Module | What it is |
|---|---|---|
| `measure.qnt` | `chuggy_measure` | **Written first** (standing rule 1 — and reworked first again in the notes-reconciliation PR, before the domain surgery). The per-ticket well-founded termination measure — lexicographic over the bounded accounts (**gas**, gate budget when `Budgeted`, the rework account granted by `ReworkPolicy`, then within-cycle progress) — plus the record vocabulary it is a pure function of, the descent table, and the named non-descending sets (STUTTER, CHURN, AUTHORING). The micro digit is three sub-digits (PR 3): **phase rank, then `stagesLeft`, then running-task count**, with the digit-order argument in the header. The notes PR compressed the rank ladder (Frozen removed: Draft 5 sits directly above Pending 4; Stalled merged: the settled tier is Done/Escalated/Revoked) and audited every numeral: the ranks are a **named successor ladder** (`rankSettled`…`rankDraft`, `rankCeiling`), every weight is derived through one named `radix(d) = d + 1`, and `microBound = radix(rankCeiling) · rankWeight` — the old literal multiplier 7 became a derivation and fell to 6 with the ceiling. Task lifecycle is the explicit `TaskState = TSRunning \| TSResolved(TaskOutcome) \| TSCarried` sum (the third state is the citations PR's carried-verdict mark). The citations PR lives here as **vocabulary, not digits**: `Task.cited` (the resolution's citation footprint), `taskPassed`/`combine` reading carried verdicts as passes, and the derived scoping plumbing (`lastEvalIndex`, `changeSince`, `spawnEvalScoped`) — the measure function itself is untouched, and the header's descent-table rows carry the re-derivation showing a scoped spawn only tightens the existing dominance bounds. The multi-repo PR is likewise **vocabulary, not digits**: `Ticket.repo` (the authored target) and the StepRecord's `landing` field (`LandingObs` — landing-boundary attribution: the attempt's repo + the environment's per-attempt `branchMoved` choice); the measure reads neither — repo-blindness is a header derivation (no digit, weight, or account radix touches `repo`; all radices derive from machine-wide consts), machine-pinned by `measureRepoBlindTest`. The machine was designed to fit this file. |
| `domain.qnt` | `chuggy_domain` | The core machine both §4 fork shapes share: pure deciders (`decide*`) over observed `Core` state, the state/actions layer, and the invariants (which must live inside the var-declaring module — Quint 0.32). PR 3: **the eval program is data on the ticket record** and **`decideEvalStageReduce` is the interpreter** — advance on a passing non-final stage (`eval-stage-passed`, an `Evaluating → Evaluating` transition), land on the final stage, short-circuit into the unchanged rework/escalation economy on a failing stage. Notes PR: **one authoring phase** (release is `Draft → Pending`, the deliberate table deviation recorded at `decideRelease`), **one parked phase** (`PEscalated`; the revalidation park and the revoke cascade's wall land there, distinguished by `reason`), **one operator-resume decider** (`decideOpRetry`, four flavors — the pre-work `RPending` flavor is the old stalled-retry, still free, still CHURN), and the **agentic dispatcher documented as such** (the `dispatch` nondet pick IS the dispatcher's decision — see `decideDispatch`). Citations PR: task completions carry a nondet **citation footprint** (`decideTaskDone` grew a `cited` argument; universe `1..N_REGIONS`), and the interpreter's two eval-entry sites spawn **scoped** — retained passing verdicts whose footprints are disjoint from the cycle's change (derived from the record's work entries) are **carried**, visible as `TSCarried` record entries and the `CarryEvalVerdicts` effect; invariant `citationsWellFormed`, witness `carryNever`. Multi-repo PR (roadmap PR 4): a ticket targets **exactly one repo** — `repo`, authored at arrival from `1..N_REPOS` (`repos` is the refusal rule) and immutable, with deps free to **cross repos** (the dep gate is Done-ness, not location); the `land` action draws the environment's per-attempt **`branchMoved`** choice and the outcome from `landOutcomes(moved)` — a quiet branch cannot fail (the envActive standing rule as a named nondet event, no stored flag); `decideLand` stamps every arm with the attempt's own-repo attribution; gate invariants `landingIsolation`, `quietRepoLandsCleanly`, `reposWellFormed`. |
| `mc/mc_chuggy.qnt` | `mc_chuggy_budgeted`, `mc_chuggy_deadline_only`, `mc_chuggy_retryfree`, `mc_chuggy_citations` | Small-scope instances: one per `GatePricing` branch (charter §2: parameterize and decide on evidence) plus a `RetryFree` instance that keeps the operator-churn exemption in `stepDescends` exercised; invariants wired for `--invariant=allInvariants`. All three run **with programs enabled** (`MAX_STAGES = 2`: arrivals draw nondet from all 20 well-formed programs at these bounds) **and citations enabled** (`N_REGIONS = 2`: every completion draws a footprint from the 4 subsets of `{1, 2}` — the smallest universe where a carry is reachable) and instantiate `REWORK_POLICY = RWBudget(n)` and `GAS`. Multi-repo PR: all four run **with repos enabled** (`N_REPOS = 2`: arrivals draw the authored target repo, landing attempts draw `branchMoved` — the smallest universe where own-repo attribution is distinguishable from a constant stamp). |
| `tests/chuggy_test.qnt` | `chuggy_test` | Pure unit tests over deciders + measure: strict descent on every transition the descent table claims, stutter/churn classification pinned, effect-exclusivity on happy + duplicate paths, every wall's name, both gate prices, both retry meterings, init's rejection of gasless graphs, the authoring/revoke/cascade suite (revoke covers every live phase and all **three desk-reason flavors** of the one parked phase), the full PR 3 staged-program suite — and the notes-PR pins: the pre-work park/resume classified (free at zero gas under both meterings, climbs, CHURN), the cascade wall pinned resume-less, program-as-data at machine level — and the citations suite: degeneration pinned byte-for-byte, the carry walked both arms (outcome = combinator over carried ∪ respawned), every conservative default pinned (silent evaluator, silent work attempt, failing evaluator, first-time entries), the all-carried staged walk, and revoke retaining the carry mark. |
| `tests/chuggy_witness_test.qnt` | `chuggy_witness_free_test`, `chuggy_witness_cascade_test`, `chuggy_witness_stage_test`, `chuggy_witness_carry_test`, `chuggy_witness_multirepo_test` | **The deterministic reachability witnesses** (the witness-hardening PR) — the load-bearing half of the two-layer witness policy below. One module per witnessed shape, consts byte-identical to the mc instance the random layer samples; each run is a **machine trace** (`init.then(apply(decide*))` through guard-checked drivers — every accepted trace is a trace of `step`; mechanism note in the file header) that proves the shape reachable with **zero seeds**, asserts the witness verdict at the witnessing step, and asserts `allInvariants` after **every** step — which subsumed Stage 9's two pinned allInvariants twin runs. The carry module also pins the scope discipline (an intersecting footprint must respawn, not carry) — the deterministic catcher for a carry-despite-intersection mutant; the free module's climb step is the deterministic catcher for a `stepDescends` RetryFree-arm sign-flip (both mutation-verified). The multi-repo module (PR 4) carries the isolation gate's witness half — the machine's two new nondet draws each exercised on both branches: the landing choice pinned **quiet** (the landing succeeds, attributed), pinned **moved** (the gate rework AND the gate-budget wall carry `{repo, branchMoved: true}`), and the repo pick exercised off-default with a **cross-repo dep chain** (a repo-1 landing flips its repo-2 dependent to Ready in the same post-state — the dep gate proved location-blind on a machine trace). It has **no paired random probe**: landing attempts are dense in random exploration (unlike the carry), so the unseeded Stage 9 runs are its random side. |

Checked by `scripts/check.sh` Stage 9 + 9b and `just chuggy`. **The
two-layer witness policy** (Stage 9b, the witness-hardening PR — after the
citations PR forced the fourth consecutive `freeClimbNever` seed re-pin):

- **9b-DET, the deterministic layer — gates the build.** The five
  machine-trace modules above (`quint test --main=<module>`): reachability
  of each witnessed shape plus `allInvariants` along its whole trace,
  immune to nondet drift, seeds nowhere. This layer guards **semantics** —
  if it fails, the machine changed meaning (or a witness/invariant did).
  The multi-repo PR extended this layer first, per its convention (new
  nondet must have deterministic runs exercising both branches).
- The unseeded instance runs are **not** landing-semantics coverage: at
  2000×40 the random layer rarely completes landings on the multi-repo
  instances, so landing mutants are caught by the unit and deterministic
  witness layers — which is the two-layer design working as intended
  (multi-repo review, observation B).
- **9b-RND, the random layer — warns, never gates.** The four pinned-seed
  expected-violation probes (freeClimbNever / cascadeParkNever /
  stageAdvanceNever / carryNever, seed forensics preserved at each probe)
  answer what the deterministic layer cannot: does **random** exploration
  of the current nondet surface still reach the shape at this seed/budget
  (trace-space health)? A dead seed prints a loud WARNING with the re-pin
  protocol instead of failing the build — a nondet-changing PR no longer
  restarts the seed-hunt ritual under duress; re-pinning is maintenance,
  on its own clock. Only genuine trace-space news warns (seed held, or
  violation without its signature); a probe that **crashes** — malformed
  invocation, no verdict at all — still hard-fails: harness bugs are not
  dead seeds.

Stage 9 proper is typecheck + unit tests + unseeded `allInvariants`
simulation on all **four** instances (the citations instance's unseeded run
replaced the coverage that used to ride its removed pinned twin).

## The notes-reconciliation PR — what each note changed here

Every row of the triage's "changed now" table, note quoted, landed as:

| Note | Landed as |
|---|---|
| "stalled should be rolled into escalated" | `PStalled` deleted. `PEscalated` is THE parked-with-open-human-task phase; the stored `reason` (deliberate trace vocabulary since PR 1) distinguishes the pipeline walls from the pre-work parks (`revalidation_failed`, `dependency_revoked`). `Resume` grew `RPending`: a pre-work park resumes to **Pending** (Ready/Blocked re-derive), never to a pipeline phase — and the `dependency_revoked` wall stamps **no** resume point (`RNone`): its only modeled exit is revoke, and `deskConsistent`'s resumeAt-iff now says exactly that. Stalled-retry became `decideOpRetry`'s `RPending` flavor — **still free** (nothing was ever spent; both meterings) and **still CHURN**, pinned in tests. |
| "Frozen removed. Draft -> Ready/Blocked." | `PFrozen` deleted; `PDraft` is the only authoring phase and release goes `Draft → PPending` directly (the derived Ready/Blocked split unchanged). This is a **deliberate deviation from v1's table lines 22/24/26** (freeze, the unfreeze edit loop, release-from-Frozen), recorded at `decideRelease` with the note as provenance. The AUTHORING churn set shrank: **arrival is its only climbing member now** (the unbounded author edit loop left the phase table; desk-only revoke stays as the flat member). The rank ladder compressed and `microBound`'s multiplier fell 7 → 6 by derivation. |
| "task state machine" | The task lifecycle is an explicit sum: spawned into `TSRunning`, settled exactly once into `TSResolved(TPassed \| TFailed \| TCancelled)` — `TCancelled` remains revoke's force-close. Structure only: **no decider's behavior changed**, and the PR 3 suite passed with mechanical rewraps (`wt`/`et` build resolved tasks, `wr`/`er` running ones) — the test evidence the triage row asks for. `Ticket.record` stays the resolved log; `idsAccounted` untouched. |
| "agentic dispatcher modeled (not FIFO)" | The dispatch chooser is first-class and named: the `dispatch` action's nondet pick among Ready tickets **is** the agentic dispatcher, its StepRecord the dispatcher's decision event in the golden trace — documented at `decideDispatch` and the action, not incidental scheduler noise. No policy-hook const: with exactly one honest default (unrestricted nondet) a one-branch parameter would have nothing to compare; it enters only when a real competing policy needs modeling. No queue, no fairness — non-goals unchanged. |
| "rework budget should be removed from core job entity and into impl / middleware" | `ReworkPolicy = RWBudget(n)` (the `GatePricing` pattern) replaces the bare `REWORK_BUDGET` const; the measure's rework radix derives from it. `RWBudget` is deliberately the **only branch for now**: removing the bound (an unbounded/gas-only branch) is exactly what the triage rejected — per-ticket liveness would become conditional on middleware behavior. `Ticket.reworkLeft` stays (the measure needs its digit) and is documented as **policy state the middleware owns in the implementation**, the ghost-field documentation pattern applied to a measure input. |
| "what is job deadline exceeded" / "what is deadline left" | The gas rename: const `GAS`, field `gasLeft`, wall `gas_exhausted`, reason `RsGasExhausted`. The charter's §2 economy/deadline row is **unchanged in force** — init still admits no state for a gasless graph; only the wall-clock-implying name died. Chuggernaut knob mapping: **`job_deadline` → gas** (chuggernaut's per-job deadline count is exactly this account under its old name; `GatePricing`'s `DeadlineOnly` branch keeps its charter name and means gas-only). |
| "termMeasure also has magic number 4 in it" | The measure audit (measure.qnt): ranks are a named successor ladder, `rankCeiling` names the top, `radix(d) = d + 1` is the one derivation every weight and account radix is built from, `firstTaskId` names the 1-indexing — no bare rank, multiplier, or radix literal is written twice, and each derivation sits next to its definition. |
| "molting leaving compaction sentinels from old docs/designs/plans" | This sweep: stale references to the superseded designs (the `EVAL_COMBINATOR` const, Frozen/Stalled as live vocabulary, the pre-PR 3 `rankWeight` arithmetic in prose) are gone from specs/chuggy; what remains of them is provenance — deviation notes and this table. |

## The citations PR — scoped eval rework

The triage's "recorded for a later PR" row, note verbatim:

> "allow passing evaluators to cite code they care about to let them
> decide whether to rerun if evaluation must rerun"

"Let them decide" is modeled as: the evaluator *expresses* its rerun-decision as the citation it publishes at resolution, and the interpreter *applies* that rule mechanically — the decision is the footprint.

**The abstraction.** Real citations are code regions; the model abstracts
both sides to opaque region sets over a bounded universe `1..N_REGIONS`.
An evaluator task's **resolution** carries a nondet citation footprint
(what it says it cares about), a work task's resolution carries the
attempt's **touch set** (the change side of the same abstraction) — both
ride the resolved record entry (`Task.cited`), environment-chosen exactly
like the verdict, never stored machine state: a cycle's change footprint
is **derived** from the retained record's work entries (`changeSince`;
work groups already delimit cycles — standing rule 3 twice over).

**The scoping rule.** At the interpreter's two eval-entry sites — the
work-passed lowest-stage entry and the stage advance — the spawn is
scoped (`spawnEvalScoped`): a position whose most recent retired
incarnation **passed**, citing a **nonempty** footprint **disjoint** from
everything the work attempts since that incarnation touched, is born
`TSCarried` (verdict carried over, evaluator not rerun, citation
inherited — which is what keeps carries sound when they **chain** across
cycles); every other position respawns running. The stage's outcome is
the combinator over carried ∪ respawned in one task set — verdict
soundness by construction, and carried verdicts are always passes, so
short-circuit semantics are unchanged. The rule keys on the **record**,
not on why the cycle started (cycle provenance is not stored), so eval
reworks, gate reworks, and post-`work_failed` respawn cycles all scope
the same way; operator resumes stay full fan-outs (chuggernaut's own
extracted `Retry` vocabulary: *"a fresh eval fan-out"*).

**Conservative defaults**, each pinned in tests:

- **Silence is not a free pass, evaluator side**: a passer that cited
  nothing reruns — the empty set is disjoint from everything, which is
  exactly why the empty-footprint arm is load-bearing.
- **Silence is not a free pass, work side**: a work resolution that cited
  nothing is treated as touching everything — nothing carries past it.
- **Work tasks always respawn** (only evaluators cite; structural — the
  work spawn sites never scope).
- **The failing evaluator that caused the rework always respawns**: a
  carry requires a retained *pass*, so its own citation buys it nothing.
- **First-time stage entry runs everything** — including every stage a
  short-circuit skipped: *"skipped, not failed, so no task records exist
  for them"*, hence nothing to carry from, structurally (the PR 3
  skipped-stage rule stands; scoping never resurrects a skipped stage).

**Degeneration** (the compatibility story, same move as PR 3's
single-stage program): under the full-intersection adversary — the change
touches every region, or any work resolution is silent — no position
carries and the machine is the recompute-all machine **byte for byte**
(same labels, transitions, `["SpawnEvalTasks"]` effects, task sets,
records), pinned in `citeDegenerationByteForByteTest`.

**Trace vocabulary.** A carry is visible twice over, because the
implementation will need to replay it: the record entry mark (`TSCarried`
with the inherited citation, never confusable with a re-earned pass) and
the `CarryEvalVerdicts` effect beside `SpawnEvalTasks` (either may appear
alone — an all-carried re-entry spawns nothing running, records
`["CarryEvalVerdicts"]`, and is immediately reducible).

**Deliberately NOT modeled**: real diffs and region granularity (the
nondet footprints over-approximate every concrete diff discipline);
evaluator **honesty** about footprints — an evaluator that under-cites
gets stale verdicts carried, and whether/when to trust a claimed
footprint (require it, audit it, ignore it for security-critical
evaluators) is an implementation/policy concern worth an intake question,
flagged for the `eval/vocabulary` confirmation rather than silently
decided here.

## The multi-repo PR — one orchestrator, many targets

Roadmap **PR 4**; gate: **isolation invariants**. Provenance:
`domain/firstclass` — both respondents picked multi-repo (option text:
"Multiple repos — one orchestrator, many targets"), rank #3 of the charter
§2 first-class order. Deliberately lean:

**A ticket targets exactly one repo.** `Ticket.repo` is an authored field
like deps and the program: drawn nondet at arrival from the bounded
universe `1..N_REPOS` (`repos` is the refusal rule — the `validPrograms`
shape; `reposWellFormed` makes it durable) and immutable after. The DAG
stays **orchestrator-level**: dependencies may cross repos, because the
dep gate is Done-ness, not location (`depsDoneIn` reads phase alone).
That is the lean reading of "one orchestrator, many targets" — forbidding
cross-repo edges would be new machinery with no charter provenance. The
cross-repo unblock is a deterministic machine trace
(`crossRepoDepDeterministicTest`: a repo-1 landing flips its repo-2
dependent to Ready in the same post-state), and location-blindness is
pinned at decider grain too (`crossRepoDepGateLocationBlindTest`).

**Landing failure is conditional and per-repo — the envActive standing
rule honored.** Before this PR the `land` action drew `LandFailed`
unconditionally: failure was always drawable and carried no cause. Now
the environment first chooses, **per landing attempt**, whether the
target repo's default branch **moved** under the candidate — a fresh
nondet draw at every attempt, never stored state (the triage's standing
rule from the `envActive` note: landing-failure conditions enter as
explicitly named nondet events, never a stored mystery flag) — and draws
the outcome from what that choice permits (`landOutcomes`): a **quiet
branch always lands cleanly** (v1's §4 insight — the moving default
branch is the *only* reason a landing can fail — now per-repo and
per-attempt), while a **moved** branch may fail *or* still integrate
(v1's all-outcomes-while-active shape: the move makes failure possible,
never certain). v1's stored `envActive` quiescence flag did **not**
return; the §4 quiescence theorem stays deferred.

**Per-repo attribution.** The StepRecord gained exactly one field —
`landing: LandingObs` — stamped `LOAttempt({repo, branchMoved})` on every
step that **resolves** a landing attempt (both success outcomes, the gate
rework, and both landing walls) and `LONone` everywhere else (including
`eval-passed`, which merely enqueues, and the absorbed `land-duplicate`).
The repo cannot ride the effect strings (no dynamic strings at this
grain), so the minimal extension is structural; labels, effects, account
deltas, and pricing are byte-identical to the pre-multi-repo machine.

**The isolation invariants (the gate):**

- `landingIsolation` — a step-invariant over `lastStep` (the
  `stepDescends` pattern): a step carries `LOAttempt` **iff** it resolves
  a landing attempt; the attribution names the stepped ticket's **own**
  repo, from inside the universe; and a gate-**failure** step carries
  `branchMoved = true` — a landing can fail **only via its own repo's
  branch moving**. No other repo's choice exists anywhere in the step to
  leak in (the environment draws `branchMoved` for the target repo
  alone), and the completeness arm forbids resolving a landing
  off-record.
- `quietRepoLandsCleanly` — the strongest **checkable** form of "a quiet
  repo's tickets never gate-fail", stated honestly about what kind of
  theorem it is: "quiet" is a per-attempt environment choice, not stored
  repo state, so the naive repo-quantified reading is not a predicate
  over any reachable state. The **state theorem** (checked on every
  reachable step) is the per-attempt form — an attempt the environment
  chose quiet resolves as `ticket-done`, full stop. The **trace-level**
  reading is deliberately discharged as deterministic witness traces:
  `quietLandDeterministicTest` (every draw pinned quiet, the landing
  succeeds) and `movedReworkAttributedTest` (pinned moved, the rework and
  the wall each attributed).
- **Repo-blindness** — the measure and every budget never read `repo`: a
  comment-level theorem whose derivation lives in measure.qnt (no digit,
  weight, or account radix touches the field; every radix derives from
  the machine-wide `GAS`/`GATE_PRICING`/`REWORK_POLICY`), machine-pinned
  by `measureRepoBlindTest` (equal `ticketMeasure` across repos, phase by
  phase, under both pricings). `landingExclusive` stays **per-ticket** —
  strictly stronger than any per-repo exclusivity (exactly one landing
  per ticket implies at most one per ticket per repo) — deliberately not
  weakened.

**Deliberately NOT done** — none of it has charter provenance: per-repo
**policies**, per-repo **budgets** (would break the repo-blindness
theorem; the charter's accounts are per-ticket), per-repo **queues** (a
queue is a §2 non-goal in any shape), and any repo vocabulary below the
landing boundary (work/eval never read the repo). `N_REPOS = 1` recovers
the single-repo machine exactly: every draw collapses and the
attribution field goes constant.

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

How it mapped: stage list → `Ticket.program: List[Stage]`; per-stage
required-pass rule → per-stage `Combinator` (unanimous default, charter
§2); staged progression → `decideEvalStageReduce`'s advance edge; the
short-circuit → the same decider's failure arm routing into the **existing**
rework/escalation economy; the chronological task log → `Ticket.record` with
history-unique sequential ids; revoke's force-close → `TCancelled`.

## What the model claims (PRs 1–4 + notes + citations)

- **Effect-only exclusivity** (charter §2): any number of task executions
  may run and duplicate — the fabric is at-least-once, `no-double-pods` was
  dropped — but the landing effect is emitted **exactly once per ticket**,
  proved at the landing boundary (`landingExclusive`) and nowhere else.
  Duplicate task completions and duplicate landing deliveries are
  idempotent no-ops by construction — and PR 3 strengthened the stale
  half: task ids are unique across a ticket's whole history, so a stale
  completion from an earlier stage or incarnation no-ops **by identity**.
- **Gas required** (charter §2 economy/deadline, renamed by the notes):
  `init` admits **no state** for a gasless graph — invalid, not merely
  unmetered.
- **Eval is data, not machinery** (charter §2, the PR 3 gate): each ticket
  carries an **authored eval program** — an ordered list of stages, each a
  parallel task-set with its own verdict combinator — run by one
  interpreter (`decideEvalStageReduce`). Two tickets in the same machine
  instance with different programs behave differently. The charter's
  default is preserved as data: `defaultProgram` = one stage, full
  fan-out, unanimous. Program well-formedness is an **arrival validity
  condition** (`validPrograms`; invariant `programsWellFormed`).
- **A failing stage short-circuits into the same economy** (extracted
  vocabulary + charter §2 evaluator-crash row): later stages are never
  created — no task records exist for them — and the ticket pays the
  **existing** price: 1 rework + 1 gas for a new cycle (which restarts
  from the lowest stage), or the existing walls when an account is empty.
  An evaluator crash is a `TFailed` inside the stage — **the ticket pays**,
  one account, no new machinery, no new wall.
- **Rework respawn is citation-scoped** (the citations PR): evaluators
  cite abstract footprints on their resolutions, and a rework's eval
  re-entry **carries** retained passing verdicts whose footprints are
  disjoint from what the cycle's work attempts touched — fewer tasks
  spawn, never more; the outcome is the combinator over carried ∪
  respawned; every conservative default (silence reruns, work always
  respawns, the failer always respawns, first-time runs everything) is
  pinned, and the full-intersection adversary degenerates **byte for
  byte** to recompute-all. Carries are trace-visible (`TSCarried` record
  entries, `CarryEvalVerdicts` effect) and machine-reachable (the
  `carryNever` witness). No new digit, no new stored state:
  `citationsWellFormed` extends the record invariants without weakening
  `idsAccounted`/`recordMonotone`.
- **Task records are first-class and retained** (charter §2 job anatomy):
  every task carries identity (sequential within the ticket, never reused),
  kind (work vs evaluator-stage), and its **explicit lifecycle state**
  (notes PR: `TSRunning` → `TSResolved(outcome)`, resolved exactly once);
  retired sets append to the per-ticket chronological `record` — the
  resolved log, provenance the golden traces can carry. `recordWellFormed`
  pins the log's shape; `recordMonotone` makes "retained" a theorem.
  Revoke retires a mid-flight set as `TCancelled` and **keeps the
  history**.
- **One parked phase, named walls** (notes PR): every desk parking is
  `PEscalated` and carries its reason — `work_failed`,
  `rework_budget_exhausted`, `gate_budget_exhausted` (only under
  `Budgeted`), `gas_exhausted`, and the pre-work walls
  `revalidation_failed` (retryable, resumes to Pending) and
  `dependency_revoked` (PR 2's cascade wall — no modeled resume; its only
  exit is revoke). `deskConsistent` pins reason-iff-parked and
  resume-point-iff-a-modeled-resume-exists.
- **Landing outcomes precisely named** (charter §2): `AdvanceDefault` ≠
  `SquashMerge` from day one — v1's one conformance divergence lived
  exactly there. Mechanics stay abstract (PR 5).
- **Multi-repo, isolated at the landing boundary** (the PR 4 gate): a
  ticket targets exactly one authored repo (`repo`, arrival-drawn from
  `1..N_REPOS`, immutable); dependencies may **cross repos** — the dep
  gate reads Done-ness, never location; a landing can fail **only via its
  own repo's default branch moving** — the environment's per-attempt
  `branchMoved` choice, an explicitly named nondet event on the step
  record (never a stored flag; the envActive standing rule), with
  `LandFailed` drawable only on a moved branch (`landOutcomes`) — and
  every step resolving a landing attempt carries its own-repo
  attribution (`landingIsolation`, `quietRepoLandsCleanly`,
  `reposWellFormed`; deterministic witnesses for quiet-clean,
  moved-attributed, and the cross-repo unblock). The measure and all
  budgets are **repo-blind** (`measureRepoBlindTest`), and
  `landingExclusive` stays per-ticket — stronger than per-repo needs.
- **The dispatcher is agentic and modeled as such** (notes PR): dispatch
  is a first-class decision — the nondet pick among Ready tickets is the
  dispatcher's own agency, recorded as the `dispatch` event; any
  implementation policy refines it. No queue, no fairness, no slot count
  (non-goals unchanged).
- **Visibility** (charter §2, definition contested per §4): every
  non-progressing ticket is reachable from an open human task
  (`deskVisibility`), with *progressing* read as measure-descent.
- **Per-ticket liveness, sketched — conditional on authors** (the PR 1
  gate, extended by PR 2; PR 3 changed the digits, the notes PR the
  authoring boundary — never the argument): every step outside the named
  STUTTER/CHURN/AUTHORING sets strictly decreases a nonnegative measure
  (`measureDescends`) — including the stage advance, which gets **no
  exemption**. Under the default `RetryCharged` metering the churn set is
  the free pre-work resume alone. The non-descending exemptions are proved
  non-vacuous by Stage 9b's witnesses (`freeClimbNever`,
  `cascadeParkNever`, `stageAdvanceNever`, `carryNever`) — since the
  witness-hardening PR, each as a seed-free deterministic machine trace
  (`tests/chuggy_witness_test.qnt`, the gating layer) with the pinned-seed
  random probes demoted to warn-only trace-space health checks.
- **Authoring lifecycle** (PR 2, reshaped by the notes): tickets arrive as
  Drafts (the fleet starts empty) carrying their eval program, and release
  strictly descends straight into the pipeline — freeze/unfreeze are gone
  (the deliberate table deviation), so arrival is the AUTHORING set's only
  climbing member and per-ticket liveness is conditional exactly on authors
  eventually releasing or revoking each Draft.
- **Rework is policy** (notes PR): the machine consults `ReworkPolicy`
  (`RWBudget(n)`, the only branch — the bound itself is kept deliberately);
  the per-ticket account is middleware-owned in the implementation and a
  measure digit in the model.
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
| `Frozen` (v1's second authoring phase) | **By the notes, never restored**: *"Frozen removed. Draft -> Ready/Blocked."* The v1 table's freeze/unfreeze/release-from-Frozen rows (lines 22/24/26) are deliberately not transcribed — deviation recorded at `decideRelease`. Content-pinning is below the model's grain. |
| `Stalled` (v1's pre-work desk phase) | **By the notes, merged not deferred**: *"stalled should be rolled into escalated."* One parked phase (`PEscalated`); the pre-work walls survive as `reason` values, the pre-work resume as the `RPending` flavor. |
| `Batched` (the authoring table's merge-queue state) | **PR 5**, with the merge queue it serves — and **re-sited by the notes follow-up** (*"Batched from Ready or Blocked"*): it will enter from `PPending`, the released pre-work state whose Ready/Blocked split is derived, **not** from authoring as v1's table rows 27–30 had it. |
| **Staged merge gate** (chuggernaut spec.md §3.3 Merge Gate item 3: gate stages, failure classification, the gate-fix fast path) | **PR 5**, with the gate itself — chuggy's landing stays one abstract outcome until `landing/requirements` is answered. |
| **Per-task budgets / attempt counters** (chuggernaut §1.2 `work_retries`, `eval_retries`, `attempt`) | **Never** — retry machinery below the cycle, a charter §2 non-goal; container relaunches are the trusted `backoffLimit` fabric axiom. Tasks carry identity + kind + lifecycle state, no attempt digit (measure.qnt header re-affirms). |
| **Required vs advisory evaluators** (`required: false` never blocks, §3.3) | Below the model's grain, absorbed into the per-stage **combinator**: an advisory evaluator is one the stage's combinator ignores. Becomes vocabulary only if the intake answer demands per-task requiredness. |
| **Real diffs, region granularity, footprint honesty** (citations PR) | **Never, by design**: citations are nondet region sets over `1..N_REGIONS` — an over-approximation of every concrete diff/citation discipline. Whether an evaluator's claimed footprint is **trusted** (required, audited, ignored) is implementation/policy, flagged as an intake `eval/vocabulary` question. Scoping the operator resume's fresh fan-out is a possible later refinement, gated on the same answer. |
| **Abort verdict** (`abort: true` skips remaining rework budget, §1.2/§3.3) and **infra-fail escalates immediately** (§3.3 reduce) | Folded into `TFailed`-fails-the-stage: the charter's evaluator-crash row prices all of it identically (**the ticket pays**, one account). The chuggernaut distinction is real, though — **flagged as a question for the intake `eval/vocabulary` confirmation**, not silently adopted or silently dropped. |
| **The approval gate** (a synthesized required Human evaluator at `max(stage)+1`, §3.3) | Not synthesized by the model: it is *expressible* as data (a final stage); synthesizing it at resolution time is an authoring/implementation concern. |
| Dep re-authoring (editing a doomed ticket's deps out of a revoked chain) | Not scheduled; the `dependency_revoked` wall's only modeled exit is revoke (the documented table-line-44 deviation at `retryableIn`). |
| **Per-repo policies / budgets / queues** (multi-repo PR) | **Never scheduled — no charter provenance**: the charter's accounts are per-ticket (§2), a queue is a §2 non-goal in any shape, and a per-repo budget would break the measure's repo-blindness theorem (measure.qnt, multi-repo header note). A repo is a landing-boundary attribute of a ticket, not an economy. |
| Merge-queue + landing mechanics | **PR 5**, deliberately last, driven by `landing/requirements` once answered. Only the outcome names are pinned now. |
| Refinement layer (the journaled actor — single-writer crash/recover, record-vs-effect atomicity) | Resolved to the **journaled actor** (charter §4, offline 2026-08-12): roadmap **PR 6**. |
| System-quiescence theorem (v1's `envActive`/`quiesce` apparatus) | Charter §4's contested half. Per-ticket is the committed theorem; quiescence would return in a severable module that constrains nothing if abandoned. The multi-repo PR deliberately did **not** resurrect the flag: the branch-moved condition is a per-attempt named nondet draw on the step record, not stored env state. |
| Scheduler, agent-slot count, FIFO ready queue | **Non-goal** (charter §2). Dispatch is the agentic dispatcher's unrestricted nondet pick among Ready tickets — modeled as its decision, not as a queue (notes PR). |
| Token/API spend | **Never** a model variable (charter §2 currency row; chuggernaut's per-task `token_usage` stays implementation accounting). |
| Multi-tenancy, dynamic DAGs, cross-cluster | In scope by silence (charter §3) but admitted in **no** PR yet. Programs are authored at arrival, and no ticket-event decider creates tickets or rewrites programs. |
| Apalache verification, golden-trace projection for chuggy | Harness depth, not machine shape: the gate is typecheck + unit tests + invariant simulation + the two-layer witness checking above (deterministic traces gate; pinned-seed probes warn). The v1-style verify/projection stages follow once the trace consumer (chuggy CI) exists. |

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
name. Chuggernaut's **`job_deadline` knob maps to gas** — the same
required per-ticket spend meter, renamed by the notes because it never was a
wall-clock deadline.

PR 2's authoring vocabulary is a **transcription, not an invention**: the
Draft/Revoked edges come row-by-row from `specs/chuggernaut/table.qnt`
(itself verbatim from chuggernaut's `state.rs`), cited at each decider.
Deviations, each argued in place: Ready/Blocked collapse into derived
`PPending`, `Batched` deferred to PR 5 (and notes-re-sited to enter from
`PPending`), the `dependency_revoked` wall is not retryable, arrivals are
chuggy-new, the park-cascade is chuggy-new design (v1 left revoke fan-out
explicitly unanswerable, model-status §6b) — and, by the notes, **Frozen's
three table rows are not transcribed** and **Stalled is not a phase**:
both recorded as deliberate deviations with the notes as provenance, not
as silent drift.

PR 3 closes a loop v1 left open on purpose: v1's
`conformance_staged_eval_short_circuit_test.qnt` replays only the
transition skeleton of the staged-eval golden fixture and marks the staged
content *"below v1's one-nondet-EvalOutcome grain … checkable with the v2
staged-eval model"* (docs/trace-conformance.md §2.2, §2.4). This model is that
model, roadmap-renamed: the stage structure, the short-circuit, and the
retained task log are now machine vocabulary, extracted from the same
spec sections the fixture came from — so when chuggy's golden traces start
shipping, that fixture's content finally has a grain to land on.
