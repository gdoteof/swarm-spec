# specs/chuggy — the chuggy-model (PRs 1–6 + the notes reconciliation + citations)

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
| `measure.qnt` | `chuggy_measure` | **Written first** (standing rule 1 — and reworked first again in the notes-reconciliation PR, before the domain surgery). The per-ticket well-founded termination measure — lexicographic over the bounded accounts (**gas**, gate budget when `Budgeted`, the rework account granted by `ReworkPolicy`, then within-cycle progress) — plus the record vocabulary it is a pure function of, the descent table, and the named non-descending sets (STUTTER, CHURN, AUTHORING). The micro digit is three sub-digits (PR 3): **phase rank, then `stagesLeft`, then running-task count**, with the digit-order argument in the header. The notes PR compressed the rank ladder (Frozen removed: Draft 5 sits directly above Pending 4; Stalled merged: the settled tier is Done/Escalated/Revoked) and audited every numeral: the ranks are a **named successor ladder** (`rankSettled`…`rankDraft`, `rankCeiling`), every weight is derived through one named `radix(d) = d + 1`, and `microBound = radix(rankCeiling) · rankWeight` — the old literal multiplier 7 became a derivation and fell to 6 with the ceiling. Task lifecycle is the explicit `TaskState = TSRunning \| TSResolved(TaskOutcome) \| TSCarried` sum (the third state is the citations PR's carried-verdict mark). The citations PR lives here as **vocabulary, not digits**: `Task.cited` (the resolution's citation footprint), `taskPassed`/`combine` reading carried verdicts as passes, and the derived scoping plumbing (`lastEvalIndex`, `changeSince`, `spawnEvalScoped`) — the measure function itself is untouched, and the header's descent-table rows carry the re-derivation showing a scoped spawn only tightens the existing dominance bounds. The multi-repo PR is likewise **vocabulary, not digits**: `Ticket.repo` (the authored target) and the StepRecord's `landing` field (`LandingObs` — landing-boundary attribution: the attempt's repo + the environment's per-attempt `branchMoved` choice); the measure reads neither — repo-blindness is a header derivation (no digit, weight, or account radix touches `repo`; all radices derive from machine-wide consts), machine-pinned by `measureRepoBlindTest`. The merge-queue PR (roadmap PR 5) reworked this file **first again**, by surgery: two new rungs on the named ladder — `PGated` (the occupied depth-1 gate, between Landing and settled) and `PBatched` (the pre-work grouping tier, between Pending and Draft) — so `rankCeiling` rose 5 → 7 and `microBound`'s multiplier 6 → 8 **by derivation** (`radix(rankCeiling)`, never an edited literal); plus the `BatchMark` vocabulary (`Ticket.batch` — NOT a measure input: batch-blindness, pinned by `measureBatchBlindTest`) and the descent-table rows for the dequeue, the fast-path, the fan-out, and the new bounded **BATCHING** climb set (absorption, `+rankWeight`, bounded by lead settlements). The machine was designed to fit this file. |
| `domain.qnt` | `chuggy_domain` | The core machine both §4 fork shapes share: pure deciders (`decide*`) over observed `Core` state, the state/actions layer, and the invariants (which must live inside the var-declaring module — Quint 0.32). PR 3: **the eval program is data on the ticket record** and **`decideEvalStageReduce` is the interpreter** — advance on a passing non-final stage (`eval-stage-passed`, an `Evaluating → Evaluating` transition), land on the final stage, short-circuit into the unchanged rework/escalation economy on a failing stage. Notes PR: **one authoring phase** (release is `Draft → Pending`, the deliberate table deviation recorded at `decideRelease`), **one parked phase** (`PEscalated`; the revalidation park and the revoke cascade's wall land there, distinguished by `reason`), **one operator-resume decider** (`decideOpRetry`, four flavors — the pre-work `RPending` flavor is the old stalled-retry, still free, still CHURN), and the **agentic dispatcher documented as such** (the `dispatch` nondet pick IS the dispatcher's decision — see `decideDispatch`). Citations PR: task completions carry a nondet **citation footprint** (`decideTaskDone` grew a `cited` argument; universe `1..N_REGIONS`), and the interpreter's two eval-entry sites spawn **scoped** — retained passing verdicts whose footprints are disjoint from the cycle's change (derived from the record's work entries) are **carried**, visible as `TSCarried` record entries and the `CarryEvalVerdicts` effect; invariant `citationsWellFormed`, witness `carryNever`. Multi-repo PR (roadmap PR 4): a ticket targets **exactly one repo** — `repo`, authored at arrival from `1..N_REPOS` (`repos` is the refusal rule) and immutable, with deps free to **cross repos** (the dep gate is Done-ness, not location); the `land` action draws the environment's per-attempt **`branchMoved`** choice and the outcome from `landOutcomes(moved)` — a quiet branch cannot fail (the envActive standing rule as a named nondet event, no stored flag); `decideLand` stamps every arm with the attempt's own-repo attribution; gate invariants `landingIsolation`, `quietRepoLandsCleanly`, `reposWellFormed`. Merge-queue PR (roadmap PR 5; every mechanic cites its **proposed requirement** R1–R7 by name — the severability rule): the landing is a **path** now — `eval-passed` enqueues (`PLanding`), the dequeue (`gateEnter`, routing hoisted into `decideDequeue` per the adversarial review) draws `branchMoved` per attempt (quiet → the skip fast-path lands `SquashMerge` in the same step; moved → `gate-opened`, the repo's depth-1 slot `PGated`), and the gated resolution (`gateResolve`) draws from `landOutcomes(true)` — `AdvanceDefault` (the validated candidate promoted) or the GatePricing-priced eviction; plus the **group**: `decideAbsorb` (Batched re-sited: `PPending → PBatched`, guard `absorbableIn`), the dep-union dispatch gate (`groupDeps`), the completion fan-out inside `landSuccess`, and the dissolution/park arms in `decideRevoke`; new invariants `gatedPromotesDirectSquashes`, `gateDepthOne`, `batchWellFormed`; visibility walks became group-aware bounded-sweep fixpoints. |
| `mc/mc_chuggy.qnt` | `mc_chuggy_budgeted`, `mc_chuggy_deadline_only`, `mc_chuggy_retryfree`, `mc_chuggy_citations` | Small-scope instances: one per `GatePricing` branch (charter §2: parameterize and decide on evidence) plus a `RetryFree` instance that keeps the operator-churn exemption in `stepDescends` exercised; invariants wired for `--invariant=allInvariants`. All three run **with programs enabled** (`MAX_STAGES = 2`: arrivals draw nondet from all 20 well-formed programs at these bounds) **and citations enabled** (`N_REGIONS = 2`: every completion draws a footprint from the 4 subsets of `{1, 2}` — the smallest universe where a carry is reachable) and instantiate `REWORK_POLICY = RWBudget(n)` and `GAS`. Multi-repo PR: all four run **with repos enabled** (`N_REPOS = 2`: arrivals draw the authored target repo, landing attempts draw `branchMoved` — the smallest universe where own-repo attribution is distinguishable from a constant stamp). Merge-queue PR: all four run **with the gate and grouping enabled at no new const** (occupancy is a phase; grouping is bounded by `N_TICKETS`): the `land` draw became `gateEnter` (the dequeue's `branchMoved` draw — quiet fast-paths, moved occupies) + `gateResolve` (the gated outcome), and `absorb` joined the `any{}` roster drawing same-repo Pending pairs — the nondet surface changed yet again; every 9b-RND seed re-examined (forensics in `scripts/check.sh`). |
| `tests/chuggy_test.qnt` | `chuggy_test` | Pure unit tests over deciders + measure: strict descent on every transition the descent table claims, stutter/churn classification pinned, effect-exclusivity on happy + duplicate paths, every wall's name, both gate prices, both retry meterings, init's rejection of gasless graphs, the authoring/revoke/cascade suite (revoke covers every live phase and all **three desk-reason flavors** of the one parked phase), the full PR 3 staged-program suite — and the notes-PR pins: the pre-work park/resume classified (free at zero gas under both meterings, climbs, CHURN), the cascade wall pinned resume-less, program-as-data at machine level — and the citations suite: degeneration pinned byte-for-byte, the carry walked both arms (outcome = combinator over carried ∪ respawned), every conservative default pinned (silent evaluator, silent work attempt, failing evaluator, first-time entries), the all-carried staged walk, and revoke retaining the carry mark — and the merge-queue suite: the path rule pinned as the outcome sets themselves, the depth-1 refusal (same-repo refused, cross-repo independent), the eviction fixtures re-sited to `PGated` with byte-identical deltas, absorption from Ready and Blocked with every refusal (including the lead-never-absorbs-its-own-dependency safety rule), the dep union, the fan-out on both paths, dissolution, park-wins, and batch-blindness. |
| `refinement.qnt` | `chuggy_refinement` | **The refinement layer** (roadmap PR 6 — charter §4's resolved fork as a machine; full design + theorems at the file header and the PR 6 section below). A CONCRETE module embedding a tiny `chuggy_domain` instance as the journaled actor's in-memory state, plus this layer's own vars: the durable decision `journal` (`Entry = {seq, cmd, rec}` — monotone dense seq, the decision event with its nondet picks named, the produced StepRecord), the executor cursor `applied`, the world ledger (`worldEffects` — received seqs, set semantics = idempotency-key absorption; `orphans` — effects from never-journaled decisions). The two disciplines are **step relations**: `rstep` (journal-then-effect: actor steps journal atomically, `emitNext` lags, `crashRecover` fires at any instant with nondet cursor regression) and `rstepHazard` (= rstep + `effectCrash`, the one seam effect-first admits). Invariants: `journalLegal` (theorem 1), `recoveryComplete` (theorem 3), `executorSound`, `journalCoversWorld` / `noDoubleSpentBudget` / `noDuplicateCycle` (theorem 2), bundled as `refinementCore` (holds under BOTH relations) and `refinementInvariants` (the journal-first gate). |
| `tests/chuggy_refinement_test.qnt` | `chuggy_refinement_unit_test`, `chuggy_refinement_witness_test`, `chuggy_refinement_hazard_test` | PR 6's test half (check.sh Stage 10a): **pure unit tests** (replay determinism via the append agreement, tampered-journal refusals — seq gaps, disabled decisions, forged records — and the double-spend arithmetic on hand-built journals), the **disciplined crash-recover-continue machine trace** (one ticket through a full REWORK to a quiet landing with crashes at every observable seam, re-emission absorbed, `allDomainInvariants and refinementInvariants` at every step), and the **effect-first expected-violation traces** (theorem 4: the dispatch double-spend, the duplicate landing, the rework double-spend — each pinned at its step with the domain machine still green on that step). |
| `tests/chuggy_witness_test.qnt` | `chuggy_witness_free_test`, `chuggy_witness_cascade_test`, `chuggy_witness_stage_test`, `chuggy_witness_carry_test`, `chuggy_witness_multirepo_test`, `chuggy_witness_gate_test`, `chuggy_witness_gate_deadline_test`, `chuggy_witness_batch_test` | **The deterministic reachability witnesses** (the witness-hardening PR) — the load-bearing half of the two-layer witness policy below. One module per witnessed shape, consts byte-identical to the mc instance the random layer samples; each run is a **machine trace** (`init.then(apply(decide*))` through guard-checked drivers — every accepted trace is a trace of `step`; mechanism note in the file header) that proves the shape reachable with **zero seeds**, asserts the witness verdict at the witnessing step, and asserts `allInvariants` after **every** step — which subsumed Stage 9's two pinned allInvariants twin runs. The carry module also pins the scope discipline (an intersecting footprint must respawn, not carry) — the deterministic catcher for a carry-despite-intersection mutant; the free module's climb step is the deterministic catcher for a `stepDescends` RetryFree-arm sign-flip (both mutation-verified). The multi-repo module (PR 4) carries the isolation gate's witness half — the machine's two new nondet draws each exercised on both branches: the landing choice pinned **quiet** (the landing succeeds, attributed), pinned **moved** (the gate rework AND the gate-budget wall carry `{repo, branchMoved: true}`), and the repo pick exercised off-default with a **cross-repo dep chain** (a repo-1 landing flips its repo-2 dependent to Ready in the same post-state — the dep gate proved location-blind on a machine trace). It has **no paired random probe**: landing attempts are dense in random exploration (unlike the carry), so the unseeded Stage 9 runs are its random side. The merge-queue PR (PR 5) added modules six through eight, extending this layer first per its convention: the **gate module** pins the depth-1 exclusivity as a **guard-refusal on a machine trace** (the second same-repo ticket's dequeue disabled while the slot is held, enabled again the step it frees), lands **both success effects on one trace**, each from its own path (gated `AdvanceDefault`, then quiet fast-path `SquashMerge` — the §5e theorem witnessed), and carries the **quiet fast-path as its own witnessed run** — SquashMerge reachability pinned against the hoisted routing decider `decideDequeue` (adversarial review MAJOR 1: the quiet/moved route is a decider both the `gateEnter` action and the `doDequeue` drivers reference, never an inline composition a mutant could re-route silently); the **deadline-only module** walks the eviction on the other GatePricing branch — two gas-only gate failures into the gas wall, v1's §5a gate-loop shape reproduced with the backstop doing its job; the **batch module** fires the `ticket-batched` BATCHING climb (the stepDescends convention roster), absorbs from Ready **and** Blocked (the note's both flavors), pins the union gating the lead, the completion fan-out (the member's cross-repo dependent Ready in the same post-state), and the dissolution. Like the multi-repo module, none has a paired random probe. |

Checked by `scripts/check.sh` Stage 9 + 9b and `just chuggy`. **The
two-layer witness policy** (Stage 9b, the witness-hardening PR — after the
citations PR forced the fourth consecutive `freeClimbNever` seed re-pin):

- **9b-DET, the deterministic layer — gates the build.** The eight
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

**Stage 10** is PR 6's severable extension of the same two-layer policy:
10a is the deterministic gate (the three refinement test modules), 10b the
unseeded instance runs (`rstep` under the full bundle; `rstepHazard` under
`allInvariants and refinementCore` — the hazard corrupts the world ledger,
never the journal, the replay, or the domain), and 10c two warn-only
pinned-seed probes (`noDoubleSpentBudget`, `noDuplicateCycle` — expected
violations under `rstepHazard`, seed forensics at each probe).

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

## The merge-queue + landing PR — one gate, one group, seven proposed requirements

Roadmap **PR 5**, deliberately **last** of the first-class four (charter
§2 first-class-order row: "Merge-queue deliberately last", consistent with
kasofsk's "wrapup phase needs thought"). Its roadmap gate reads "driven by
`landing/requirements`, once answered" — and that question **was never
answered**: geoff and davemo88 both answered `landing/semantics =
undecided`, kasofsk wrote only "wrapup phase needs thought", and the
charter's landing row records the deferral as **deliberate** ("Deferred by
choice... the model keeps landing mechanics abstract but names outcomes
precisely"). This PR therefore lands under a constraint no earlier PR
carried, stated here so nobody mistakes the provenance:

> **PROPOSED / UNCONFIRMED.** Every requirement in the table below is
> **derived** — from chuggernaut's own `docs/spec.md` and from v1's
> machine-checked findings — **not decided by geoff or davemo88**, and
> each is **pending their confirmation**. These are the modeler's best
> derivation of what `landing/requirements` would have said, offered as
> the concrete artifact to confirm, amend, or tear up. Where a row leans
> on something already decided (a charter §2 row, a binding triage note),
> the provenance column says exactly which part is decided and which is
> proposed. Nothing below is presented as their decision.

### The proposed requirements (R1–R7)

Every mechanic in the code cites the requirement that forces it **by
name** (R1…R7), so a torn-up requirement maps to deletable code — the
severability table after the list.

| # | Proposed requirement | Provenance (derived from) |
|---|---|---|
| **R1** | **The default branch is never red.** A commit reaches the default branch only after every required evaluator has passed against the **exact tree that lands**: on a quiet branch the evaluated tree *is* the landing tree (why the fast-path is sound); on a moved branch only the **gate-validated candidate** may land. | chuggernaut spec.md §3.3 Merge Gate, the guarantee sentence verbatim: *"no commit reaches the default branch without every required command evaluator passing against the exact tree that lands"*. Wholly proposed. |
| **R2** | **One landing per diff — extended to groups.** A ticket's diff lands at most once (decided: charter §2 effect-only exclusivity, proved since PR 1); a **group's** diff lands **exactly once for the whole group** — the lead's single effect; members complete via the fan-out with `landings = 0` and the retained mark as provenance (the proposed extension). | Charter §2 exclusivity row (**decided**, the per-ticket half); chuggernaut §2.1 Batches: *"whose single completion finishes every member"*, *"its single merge completes every member"* (**proposed**, the group half). |
| **R3** | **Promotion effect is determined by the path.** A gated clean landing **advances the default ref** to the already-merged gate result (`AdvanceDefault`); an ungated/direct landing **squash-merges** (`SquashMerge`); the model emits the right one per path — never a free draw between them. | The outcome **names** are decided (charter §2 landing row). The **rule** is derived from v1's one conformance divergence — model-status.md §5e: promotion under the gate is *"fast-forwarding the default branch onto the validated squash candidate, and no SquashMerge effect exists"*, with trace-conformance §2.4 promising *"the v3 merge-gate model must split the two promotion mechanisms again, at which point this widening disappears"* — and chuggernaut §3.3 items 1 (*"skip the gate; squash-merge directly"*) and 4 (*"advance the default branch to the candidate commit (this **is** the squash-merge; do not re-merge)"*). This PR is that promised split. |
| **R4** | **The gate runs at depth 1 per repo; queue order is deliberately unspecified.** At most one ticket per repo occupies the merge gate; a second same-repo dequeue is **refused** while the slot is held; gates of different repos are independent. The queue's *order* is not a requirement: any enqueued ticket may dequeue when the slot frees. | chuggernaut §3.3 Serialization: *"the gate is a merge queue of depth 1: at most one job per project is in the gate at a time"* (per-project → per-repo at chuggy's landing boundary). Order-freedom: chuggernaut itself loses FIFO order across restarts (§3.6 step 3 rebuilds the queue from state, not order), and a queue is a charter §2 non-goal (**decided**) — so order is implementation policy refining free choice, like dispatch. |
| **R5** | **A gate failure re-enters work, priced per `GatePricing` — never a silently free loop.** The eviction spends per the charter's parameter (Budgeted: gate budget + gas; DeadlineOnly: gas alone), and empty accounts park behind named walls. | The pricing **parameter** is decided (charter §2 gate-pricing row: generate traces under both, decide on evidence). The proposed part is the mapping: chuggernaut's gate failure consumes **no** `rework_budget` (§3.3 item 4, §3.3 Bounding: *"`job_deadline` is the backstop"*) — which is exactly the `DeadlineOnly` branch — and v1 **machine-checked** what that costs when the backstop is absent (model-status §5a, the gate-loop livelock; docs/chuggernaut.md §6.2: the spinning ticket held the only slot and *"the queue behind a spinning job starves"*), which is why `Budgeted(n)` stays instantiated beside it. |
| **R6** | **The gate never wedges; queue wait is accepted unbounded — flagged for confirmation.** Every gate occupancy has an enabled resolution, and every resolution (landing, eviction, wall, revoke) **frees the slot in the same step** — no occupant state exists that cannot resolve, so the queue always advances past its head. What is deliberately **not** guaranteed: a bound on how long an enqueued ticket waits (the dequeue is a nondet pick, and the environment may keep choosing `moved`). **This is the intake question restated**: bounded staleness between eval-pass and landing attempt, or explicit acceptance of unbounded queue wait — the model currently encodes the *acceptance*, and geoff/davemo88 should confirm or demand the bound. | chuggernaut's own never-wedge discipline, three times over: §2.1 WrapUp rows (*"the merge queue advances past the job rather than wedging"*), §3.2 finalization hard failures (*"the merge queue advances past the job instead of stalling"*), §3.6 restart (*"a gate in flight is superseded... the job re-enters the merge queue"*). The starvation half: v1's finding (docs/chuggernaut.md §6.2) that a spinning occupant starves the queue behind it — bounded per-occupant by gas (R5), unbounded across occupants. |
| **R7** | **Batched enters from the released pre-work state, and a member's only progress is its group's.** `Batched` enters from `PPending` — Ready **or** Blocked — never from authoring; a member never runs, spends nothing, and leaves only via the group's single landing (→ Done), the group's dissolution (→ `PPending`, re-batchable), the cascade's park (doomed), or its own revoke. | The **entry point is binding, not proposed**: docs/chuggy-notes-triage.md, recorded row, verbatim *"Batched from Ready or Blocked"* (the re-siting of v1 table lines 27–30, whose `Frozen → Batched` entry is deliberately not transcribed). The rest is proposed, from chuggernaut §2.1 Batches: *"Invisible to scheduling, holds no branch of its own, cannot be claimed or released — like Draft"*; `Batched → Done` via the batch's merge; *"a revoked or failed batch returns each Batched member"* (re-sited to `PPending` since Frozen is gone — and chuggy's only terminal batch failure **is** revoke, because every wall is a park the operator still owns). |

### The Batched reading — the note, verbatim, against the mechanics

The note (triage, recorded row): **"Batched from Ready or Blocked"** —
Batched enters from the released pre-work state (`PPending`), **not**
from authoring as v1's table had it. Three readings were considered:

1. *Batched as the landing-queue phase* (between Evaluating and Landing)
   — *rejected*: chuggernaut's Batched is unambiguously **pre-work**
   (§2.1: members are absorbed **before** any execution, "invisible to
   scheduling", holding no branch; the landing queue is WrapUp's, a
   different state entirely), and the note's "from Ready or Blocked"
   names pre-work sources.
2. *Batched as the gate-occupancy phase* — *rejected for the same
   reason*: gate occupancy is WrapUp-internal dispatcher memory in
   chuggernaut, not the Batched state; the model gives occupancy its own
   phase (`PGated`) instead.
3. **The adopted reading — Batched as the optional pre-work grouping
   phase**: a released ticket (either derived flavor — Ready or Blocked)
   is absorbed as a **member** of a group an ordinary Pending same-repo
   ticket **leads**; members suspend (run nothing, spend nothing), the
   lead's dispatch gates on the **dep union minus the group**
   (chuggernaut §2.1: *"the batch depends on the union of the members'
   external deps minus the members"* — in-group edges are *"satisfied
   jointly"* and drop out), and the lead's **single landing completes
   every member** atomically, each member's dependents unblocking *"as
   if it had run individually"*.

The adopted reading deviates from chuggernaut in one deliberate way,
**marked proposed like the requirements**: chuggernaut's batch is a
**fresh job** that absorbs members; chuggy's is an **absorbed lead** — an
ordinary ticket carries the group, its own program standing in for the
eval-criteria union. That keeps the PR lean (no new arrival machinery,
no program-union semantics) at the cost of one asymmetry chuggernaut
never faces: an absorbed lead can *have* dependencies, so `absorbableIn`
refuses a lead absorbing **its own dependency** (the union drop-out would
let it dispatch over a revocable un-Done dep and a later revoke would
doom a mid-flight lead — caught by this PR's first random invariant run,
exactly the way PR 2's tombstone-dep rule was; the jointly-implemented
edge stays expressible in the safe direction, with the dependency as the
lead). If the confirmation prefers batch-as-its-own-ticket, the group
mechanics are severable (below) and the reading swaps without touching
the gate.

### Severability — requirement → mechanics → what deletion looks like

Standing instruction honored: every proposed-requirement-driven mechanic
carries a comment naming its requirement, so tearing one up maps to code,
not archaeology.

| Torn up | Deletable/replaceable, without measure surgery beyond the named rung |
|---|---|
| R1/R4 (the gate itself) | `PGated` + its ladder rung, `gateFreeIn`/`gateEnterableIn`/`gatedTickets`/`gateEnterable`, `decideGateOpen`, the `gateEnter`/`gateResolve` actions (restore a one-step `land`), `gateDepthOne`, the path-iff conjunct in `landingIsolation`, the gate witness modules. The measure loses one rung (`rankCeiling` re-derives, 7 → 6). |
| R3 (the path rule) | `landOutcomes` reverts to the PR 4 sets, `gatedPromotesDirectSquashes` deleted, the effect-per-path conjuncts drop out of tests — outcome **names** stay (charter-decided). |
| R5's branch mapping | The eviction arms stay (charter-decided parameter); only the DeadlineOnly-is-chuggernaut's-reading commentary moves. |
| R6's acceptance | Add the wait bound the confirmation demands (a queue-age account or fairness assumption) — new machinery, nothing deleted; the never-wedge half is structural and free. |
| R2's group half / R7 (the group) | `PBatched` + its rung, `BatchMark`/`Ticket.batch`, `membersOf`/`absorbableIn`/`groupDeps`/`decideAbsorb`, the `absorb` action, the fan-out in `landSuccess` (reverts to single-transition success), the dissolution/park arms in `decideRevoke`, `batchWellFormed`, `landingExclusive`'s mark conjunct, the group edges in the visibility walk (fixpoints revert to single ascending folds), the BATCHING set + `stepDescends` arm, the batch witness module. |

**Deliberately NOT modeled** (no provenance anywhere — not even proposed):
**merge trains** (chuggernaut's gate validates one candidate at a time;
nothing stacks candidates), **batching heuristics** (*which* tickets to
group is the author's/operator's unrestricted nondet choice — any real
policy refines it, the agentic-dispatcher shape again), and **cross-repo
atomic landings** (a group is single-repo by `absorbableIn`; nothing
lands in two repos atomically). Chuggernaut's **staged gate internals**
(§3.3 item 3: gate stages, deterministic failure classification, the
gate-fix fast path with its own two-round budget) stay below the model's
grain — the gate is one abstract verdict; the staging enters only if the
`landing/requirements` confirmation demands it (the deliberately-absent
table row).

## The refinement layer — the journaled actor (PR 6)

Roadmap **PR 6**, the final machine PR; gate: *"no double-spent budget, no
duplicate cycle, across crashes at any seam; a later controller migration
re-proves the same refinement against the same machine."* Provenance:
charter §4's fork, **resolved offline (2026-08-12)** to *service + dumb
K8s Jobs* — "one journaled single-writer actor keeps all state and makes
every decision; Kubernetes runs things and decides nothing" — with the
refinement layer thereby "unblocked and *defined*: what gets modeled next
is the journaled actor — crash/recover of the single writer, and the
atomicity seam between recording a decision and effecting it (the
double-spend hazard from the shape flows)." This PR is that definition
built: `refinement.qnt` + `tests/chuggy_refinement_test.qnt` + check.sh
Stage 10, all **severable** (nothing in the domain, the mc instances, or
stages 1–9 reads them — the §4 severability promise kept).

It also closes the one v1-review note the triage filed against this PR
("already true" table): *"how do decision events flow to consumers /
executors that apply their side effects."* The answer, as machine: **the
decision events ARE the journal entries** — every actor decision appends
`{seq, cmd, rec}` (monotone dense sequence number; the decision event
with its nondet picks named — the witness-driver discipline as journal
data; the StepRecord the decision produced), and the **executor is a
cursor** (`applied`) consuming the journal in order and emitting each
entry's effects toward the world. Decisions flow decide → journal →
cursor → world; the seam between journal and effect is the atomicity
this PR proves safe in one order and demonstrates fatal in the other.

**The machine.** The actor's in-memory state is an embedded
`chuggy_domain` instance (a fixed tiny instance — the smallest consts
that exercise a **rework**, because a rework is the re-entry that
charges: `N_TICKETS = 2`, `N_TASKS = 1`, `RWBudget(1)`, `GAS = 3`,
`Budgeted(1)`, `RetryCharged`, single-stage programs, one region, one
repo), so the domain's `allInvariants` is checked against the actor's
memory at every step. The actor's decide step **is** the domain decider:
`execCmd` dispatches `cmd` onto the pure `decide*` functions, guarded by
`cmdEnabled` — the domain's own enablement, re-stated over an explicit
`Core` via pure forms hoisted into domain.qnt (`canArriveIn`,
`draftsIn`, `readiesIn`, … — each enablement val now references its pure
form; referenced, never copied). The crash model: `crashRecover` may
fire **at any instant** — recovery replays the journal into fresh memory
and the cursor regresses nondet (the durable checkpoint lags) — and the
decide↔journal seam is collapsed into the atomic `journalStep` because a
pure decision that dies un-journaled has no footprint anywhere: the run
where it crashed is indistinguishable from the run where it was never
decided, which the machine's nondeterminism already contains.

**The two orderings** are step relations, not machinery: `rstep` is
journal-then-effect (the correct discipline); `rstepHazard` is `rstep`
plus exactly one action — `effectCrash`: decide, emit, die before the
journal write. The delta between the relations **is** the discipline,
and the expected-violation runs show that single delta breaking the
theorems (the house pattern — hazards stay reproducible by
configuration).

**The four theorems, as implemented:**

1. **Refinement** (`journalLegal`) — every journaled history projects to
   a legal domain-machine trace: replay the journal from genesis; each
   entry must carry the next dense seq, be **enabled** at the replayed
   prefix (the domain's own guards), and its record must be **exactly**
   what the decider produces there. Structural (the actor's step is the
   decider behind the same guard) *and* stated as a checked invariant —
   so a tampered journal is caught by predicate, not by construction
   argument (the unit tests pin the refusals: seq gaps, disabled
   decisions, forged records). Since every non-actor step leaves the
   domain vars untouched, the domain-visible trace of a disciplined run
   is literally the journal's record sequence.
2. **No double-spent budget / no duplicate cycle across crashes**
   (`noDoubleSpentBudget`, `noDuplicateCycle`, `journalCoversWorld`;
   `journalLandingsMatchLedger` is the journal-side half) — under
   journal-then-effect, the world never runs more paid work for a ticket
   than the journal charged, and never lands one ticket's diff twice,
   across crashes at any seam. Effects between the journal position and
   the applied cursor **are re-emitted** — at-least-once toward the
   world — but a re-emission carries the same decision seq and absorbs;
   the **journal** never gains a duplicate decision.
3. **Recovery completeness** (`recoveryComplete`) — replay of the
   current journal is exactly the state the actor holds, in every
   reachable state (hence for every prefix of every run). Replay is
   deterministic **by purity**: the deciders are pure functions of
   (Core, picks) — charter §4's "both shapes reuse the deciders" is
   precisely what makes the journal a sufficient recovery basis — and
   the incremental/batch agreement is unit-pinned
   (`replayAppendAgreesTest`).
4. **The demonstration witness** — deterministic expected-violation
   traces under `rstepHazard`: the **dispatch double-spend** (the Job
   launches, the crash eats the journal write, the recovered actor
   re-decides — two Jobs, one journaled charge), the **rework
   double-spend** (the flows-analysis scenario: the rework Job fans out,
   the crash loses the decision *and its charge* — the book's accounts
   are full while the world runs the rework; the re-decision charges
   once for two Jobs), and the **duplicate cycle** (the quiet dequeue
   squash-merges in the world, the crash eats the record, the re-landed
   ticket merges the same diff twice — one clean journaled landing).
   Every violated conjunct is asserted **with `allDomainInvariants`
   green on the same step**: the domain machine is *blind* to the
   hazard — `landingExclusive` holds while the world merges twice —
   which is the machine-checked argument that this obligation belongs to
   the refinement layer and cannot be discharged inside the domain.

**The composition argument (with the fabric's at-least-once).**
Outbound: executor re-emission after cursor loss and fabric redelivery
are the same at-least-once, and both absorb because every emitted effect
is keyed by its decision's journal seq (`worldEffects`' set semantics is
that assumption stated as a model primitive — the charter §2 fabric row,
"every effect is idempotent," given its key). Inbound: completions and
confirmations also arrive at-least-once, and the **domain's existing
duplicate tolerance absorbs them** — duplicate task completions no-op by
identity, duplicate landing deliveries no-op at the boundary — so the
actor journals the absorbing no-op decisions like any others and replay
reproduces them (the witness trace journals both a `task-done-duplicate`
and a `land-duplicate` row). What neither side can absorb is an
**un-keyed** effect — a decision that reached the world but never the
journal — and that is exactly the orphan the discipline forbids.

**Platform capture, made concrete** (charter §4's guard): the domain
machine contains no vocabulary from this layer — no journal, no cursor,
no crash, no Kubernetes — and this PR moved no decider (domain.qnt's
only edits are referentially transparent exports: the pure enablement
forms and the `installCore` seam, each with its val rewired to reference
it). A later controller migration writes a **sibling of
`refinement.qnt`** — its own state and seams — and re-proves these same
obligations (history projects to legal domain traces; no double-spend
across its crash seams) against the **byte-identical domain machine**.
Nothing in the domain moves; only the refinement module is replaced.

**The journal bound, honestly:** the journal grows one entry per
decision and the measure never reads it (append-only provenance, like
`Ticket.record`). Its length is finite under exactly the per-ticket
liveness sketch's conditions (measure.qnt header): descending decisions
are bounded by the measure, AUTHORING/BATCHING rows by the arrival cap,
journaled STUTTER rows by the fabric's finitely-many-duplicates
assumption, CHURN rows by `RetryCharged` (this instance's metering; the
`RetryFree` conditionality is inherited, not new). Snapshot/compaction
is an implementation concern — a snapshot is a replay prefix, sound by
recovery completeness — and is not modeled.

**Deliberately out — no provenance, severable if ever wanted:**
**multi-writer** (the charter shape is the *single*-writer actor; a
second writer would need its own §4-grade decision), **sharding /
partitioned journals** (one journal, one actor — scale machinery with no
charter row), **real persistence formats** (the journal is a list of
decision events; encodings, fsync semantics, and log stores are
implementation), and **executor parallelism** (one cursor, in journal
order; concurrent executors would need their own exclusion argument —
the fabric's at-least-once already covers the observable effect of any
honest executor pool, but proving that is the implementation's
obligation, not assumed here).

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

## What the model claims (PRs 1–6 + notes + citations)

- **Effect-only exclusivity** (charter §2): any number of task executions
  may run and duplicate — the fabric is at-least-once, `no-double-pods` was
  dropped — but the landing effect is emitted **exactly once per ticket**,
  proved at the landing boundary (`landingExclusive`) and nowhere else —
  and, since the merge-queue PR (proposed R2), **exactly once per group**:
  a marked Done ticket completed via its group's single landing, emitted
  nothing of its own (`landings = 0`, mark retained; `batchWellFormed`
  pins the marked-Done shape to a landed lead).
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
- **Landing outcomes precisely named — and path-determined** (charter §2
  names; the merge-queue PR's proposed R3 rule): `AdvanceDefault` ≠
  `SquashMerge` from day one — v1's one conformance divergence lived
  exactly there — and the model now **says which fires when**: a quiet
  dequeue skips the gate and squash-merges directly (`SquashMerge`, the
  only quiet outcome); a moved dequeue opens the gate, and its clean pass
  advances the default ref onto the validated candidate
  (`AdvanceDefault`) while its failure is the priced eviction.
  `landOutcomes` is the draw rule; `gatedPromotesDirectSquashes` +
  `landingIsolation`'s path-iff make it durable; the gate witness module
  lands both effects on one machine trace. This is trace-conformance
  §2.4's promised split, delivered — the v1 allowlist widening can
  retire when the golden traces regenerate.
- **The merge gate runs at depth 1 per repo** (proposed R1/R4): at most
  one ticket per repo occupies the gate (`PGated`; `gateDepthOne` — a
  derived predicate over phase, no stored queue), a second same-repo
  dequeue is refused by guard while the slot is held
  (`gateEnterableIn`, pinned as a machine-trace refusal), gates of
  different repos are independent, and every resolution — landing,
  eviction, wall, revoke — frees the slot in the same step (proposed R6:
  the gate never wedges; queue **order** and queue **wait** are
  deliberately unbounded nondet, flagged for confirmation).
- **Grouping is pre-work, and a group lands as one** (proposed R7/R2;
  entry point binding per the notes follow-up): `Batched` enters from
  `PPending` — Ready or Blocked — never from authoring; a member runs
  nothing and spends nothing; the lead's dispatch gates on the dep union
  minus the group (in-group edges satisfied jointly — with the
  lead-never-absorbs-its-own-dependency safety refusal); the lead's
  single landing completes every member atomically (fan-out,
  `CompleteViaBatch`, dependents unblocking as individual Dones would);
  the lead's revoke releases members re-batchable, and a doomed member
  parks behind the cascade wall like any pre-flight dependent.
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
  authoring boundary, the merge-queue PR added the bounded BATCHING set —
  never the argument): every step outside the named
  STUTTER/CHURN/AUTHORING/BATCHING sets strictly decreases a nonnegative
  measure
  (`measureDescends`) — including the stage advance, which gets **no
  exemption**, and the dequeue, fast-path, and fan-out steps, which
  descend outright. Under the default `RetryCharged` metering the churn
  set is
  the free pre-work resume alone. The non-descending exemptions are proved
  non-vacuous by Stage 9b's witnesses (`freeClimbNever`,
  `cascadeParkNever`, `stageAdvanceNever`, `carryNever`, and the batch
  module's deterministic absorb climb for the BATCHING arm) — since the
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
- **The service shape refines the machine** (PR 6, the roadmap gate):
  the journaled single-writer actor's every journaled history is a legal
  domain trace (`journalLegal`), replay of any journal prefix is exactly
  the memory it recovers (`recoveryComplete`), and under
  journal-then-effect, crash/recover **at any seam** never charges an
  account twice and never lands a diff twice (`noDoubleSpentBudget`,
  `noDuplicateCycle`) — with effect-then-journal's double-spend kept
  reproducible as deterministic expected-violation traces on which the
  domain machine stays green (the hazard is invisible at the domain
  grain; the refinement section above has the composition argument).

## Deliberately absent — and which PR restores it

| Absent | Why / restored by |
|---|---|
| `Frozen` (v1's second authoring phase) | **By the notes, never restored**: *"Frozen removed. Draft -> Ready/Blocked."* The v1 table's freeze/unfreeze/release-from-Frozen rows (lines 22/24/26) are deliberately not transcribed — deviation recorded at `decideRelease`. Content-pinning is below the model's grain. |
| `Stalled` (v1's pre-work desk phase) | **By the notes, merged not deferred**: *"stalled should be rolled into escalated."* One parked phase (`PEscalated`); the pre-work walls survive as `reason` values, the pre-work resume as the `RPending` flavor. |
| **Staged merge gate** (chuggernaut spec.md §3.3 Merge Gate item 3: gate stages, deterministic failure classification, the gate-fix fast path with its own two-round budget) | **Still absent after PR 5, deliberately**: the gate landed at depth 1 with **one abstract verdict** (`gateResolve` draws pass or fail, nothing finer); the staged internals enter only if the `landing/requirements` confirmation demands them (the merge-queue section — R1–R7 are proposed, and gate *structure* was not derivable without over-committing). |
| **Per-task budgets / attempt counters** (chuggernaut §1.2 `work_retries`, `eval_retries`, `attempt`) | **Never** — retry machinery below the cycle, a charter §2 non-goal; container relaunches are the trusted `backoffLimit` fabric axiom. Tasks carry identity + kind + lifecycle state, no attempt digit (measure.qnt header re-affirms). |
| **Required vs advisory evaluators** (`required: false` never blocks, §3.3) | Below the model's grain, absorbed into the per-stage **combinator**: an advisory evaluator is one the stage's combinator ignores. Becomes vocabulary only if the intake answer demands per-task requiredness. |
| **Real diffs, region granularity, footprint honesty** (citations PR) | **Never, by design**: citations are nondet region sets over `1..N_REGIONS` — an over-approximation of every concrete diff/citation discipline. Whether an evaluator's claimed footprint is **trusted** (required, audited, ignored) is implementation/policy, flagged as an intake `eval/vocabulary` question. Scoping the operator resume's fresh fan-out is a possible later refinement, gated on the same answer. |
| **Abort verdict** (`abort: true` skips remaining rework budget, §1.2/§3.3) and **infra-fail escalates immediately** (§3.3 reduce) | Folded into `TFailed`-fails-the-stage: the charter's evaluator-crash row prices all of it identically (**the ticket pays**, one account). The chuggernaut distinction is real, though — **flagged as a question for the intake `eval/vocabulary` confirmation**, not silently adopted or silently dropped. |
| **The approval gate** (a synthesized required Human evaluator at `max(stage)+1`, §3.3) | Not synthesized by the model: it is *expressible* as data (a final stage); synthesizing it at resolution time is an authoring/implementation concern. |
| Dep re-authoring (editing a doomed ticket's deps out of a revoked chain) | Not scheduled; the `dependency_revoked` wall's only modeled exit is revoke (the documented table-line-44 deviation at `retryableIn`). |
| **Per-repo policies / budgets / queues** (multi-repo PR) | **Never scheduled — no charter provenance**: the charter's accounts are per-ticket (§2), a queue is a §2 non-goal in any shape, and a per-repo budget would break the measure's repo-blindness theorem (measure.qnt, multi-repo header note). A repo is a landing-boundary attribute of a ticket, not an economy. |
| Merge trains, batching heuristics, cross-repo atomic landings | **Never scheduled — no provenance anywhere, not even proposed** (the merge-queue section): the gate validates one candidate at a time, grouping choice is unrestricted nondet any policy refines, and a group is single-repo by `absorbableIn`. |
| A bound on landing-queue wait | **Deliberately absent, flagged** (proposed R6): the model encodes *accepted-unbounded* — the never-wedge half is structural, the bound (if geoff/davemo88 demand one) is new machinery on confirmation. |
| Refinement layer (the journaled actor — single-writer crash/recover, record-vs-effect atomicity) | **Landed** (roadmap PR 6): `refinement.qnt` + its tests + check.sh Stage 10, severable — the section above. Still absent within it, deliberately: multi-writer, sharding, persistence formats, executor parallelism (no provenance — the section's deliberately-out list). |
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
`PPending`, `Batched` re-sited by the notes follow-up and landed in PR 5
as the pre-work grouping phase entering from `PPending` (v1's
`Frozen → Batched` table entry deliberately not transcribed), the `dependency_revoked` wall is not retryable, arrivals are
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
