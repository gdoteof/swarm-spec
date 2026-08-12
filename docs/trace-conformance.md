# Trace conformance: model ↔ golden traces (design)

Status: **both directions IMPLEMENTED** — replay in PR8, generation in PR9.
This document specifies the conformance harness between the Quint model and
chuggernaut's golden decision traces. Replay: `scripts/gen-conformance.py`
compiles the golden fixtures into Quint runs committed under
`specs/chuggernaut/tests/conformance/`; `scripts/check.sh` Stage 7 runs
them, with a drift guard against a chuggernaut checkout when one is
available (`just conformance-gen` regenerates). Generation:
`scripts/itf-to-golden.py` projects simulator ITF traces into candidate
golden YAMLs (`just itf-golden`; committed examples in `docs/examples/`),
round-trip verified in check Stage 8. The shared effect vocabulary both
directions project through has one executable home,
`scripts/conformance_vocab.py` (§4). §2.4 and §3.5 record exactly where the
implementations diverged from this design; §3.6 is the handoff note for the
chuggernaut owner.

References (paths relative to the chuggernaut repo root):

- `crates/dispatcher/tests/traces/*.yaml` — the eleven golden fixtures.
- `crates/dispatcher/tests/golden_traces.rs` — the harness that records and
  asserts them (`TraceSink`, `sink.begin(label)`, `assert_trace`).
- `specs/chuggernaut/types.qnt` `StepRecord`, `machine.qnt` `lastStep` — the
  model-side observation these fixtures line up against.

## Why this is alignment, not translation

The model's `StepRecord = { label, transitions, effects }` was shaped, on
purpose, like one step of chuggernaut's golden-trace YAML schema
`{ event, transitions: [{job, from, to}], effects: [str] }` (see the comment
on `StepRecord` in `types.qnt`). Every applied `Decision` is recorded in the
ghost variable `lastStep`, so a model run **is already** a golden-shaped
trace: state `i` of any run carries the step record that produced it.

Conformance checking is therefore *sequence alignment* between two artifacts
of the same shape — not a semantic translation layer. The two directions:

1. **Replay (golden → model)** — first to build: compile each golden YAML
   into a deterministic Quint `run` that drives the exact `decide*` calls the
   fixture implies and asserts `lastStep` against the fixture after every
   step.
2. **Generation (model → golden candidates)** — later: project simulator ITF
   traces into candidate golden YAMLs for chuggernaut's own harness to
   execute (model-based conformance testing).

What actually differs between the two artifacts is *vocabulary coverage*:
the implementation records effects the v1 model deliberately abstracts away
(gate machinery, event publishes, task plumbing). The conformance relation
(§4) handles this with a modeled-vocabulary allowlist — transitions are
fully modeled and compare **exactly**; effects compare **after projection**
onto the shared vocabulary.

## 1. What the golden YAMLs actually look like

Reading all eleven fixtures against the assumed schema surfaced four facts
the design must absorb (none breaks the shape; all break naive 1:1
step matching):

1. **A golden "step" is not one decision.** Steps are delimited by
   `sink.begin(label)` in the test, and the actor-driven scenarios wrap an
   *entire lifecycle* in a single step — `work_eval_merge_no_gate.yaml` is
   one step with 5 transitions and 13 effects; `conflict_reentry.yaml` one
   step with 8 transitions. The model records exactly one decision per step
   (v1 deciders emit exactly one transition each). So alignment is: the
   *concatenation* of consecutive model step records against one golden
   step, segmented at the `PublishEvent job-*` boundaries (fact 2). The
   synchronous fixtures (`release_block_unblock`, `revoke_cascade`,
   `stall_on_revalidation_failure`) are closer to one-decision-per-step.
2. **`event` is prose, not a machine label.** Golden `event` strings are
   scenario descriptions ("create+release → work → eval → merge"), written
   by the test author. They never match the model's label vocabulary. The
   *real* per-decision labels hide inside the effects list as
   `PublishEvent job-started`, `PublishEvent job-rework-started`,
   `PublishEvent job-escalated`, … — and **those** names align with the
   model's labels almost one-for-one. The generator keys on
   `(from, to)` transition pairs, disambiguated by the adjacent
   `PublishEvent job-*` effect; the `event` string is carried as a comment.
3. **`transitions` is optional per step.** `release_block_unblock.yaml`'s
   two `create …` steps carry only effects. Effect-only steps with no
   modeled effect project to nothing and are skipped by replay.
4. **Effects are parameterized strings.** `DeleteBranch job/1` vs
   `DeleteBranch merge-gate/1`, `PutTask Human(escalation)`. Comparison
   needs normalization (§4), not string equality.

One more replay-relevant quirk: two fixtures (`release_block_unblock`,
`stall_on_revalidation_failure`) reach "upstream job Done" by **writing the
KV store directly** — the trace records no transitions for the upstream job
finishing. The model can't poke state; replay inserts explicit *driver
steps* (dispatch → work-succeeded → eval-passed → job-done for the
upstream job) that have no golden counterpart. Driver steps are excluded
from alignment but still checked against every model invariant
(`stepRespectsTable` etc.), so they can't smuggle in illegal behavior.

## 2. Replay direction (golden → model) — first to build

The generator (`scripts/gen-conformance.py`) reads each golden YAML from a
chuggernaut checkout at runtime and emits one Quint module per scenario into
`specs/chuggernaut/tests/conformance/` (`conformance_<fixture>_test.qnt`,
plus the shared allowlist module `conformance_allowlist.qnt`), each
containing:

- **Instance constants from the scenario's job type.** The fixtures pin
  budgets in their job-type YAML (`impl-cmd` has no `rework_budget`;
  `impl-rework` has `rework_budget: 1`), so each replay module instantiates
  `chug_machine` / `chug_decide` with matching `WORK_RETRIES` /
  `REWORK_BUDGET` and an ample `DEADLINE` (the fixtures never exercise the
  deadline).
- **An explicit `replayInit` action** assigning the machine's variables
  directly: the scenario's jobs and dep edges, each job `Ready` or
  `Blocked`. This *absorbs the release prefix*: every fixture opens with
  `Frozen → Ready` / `Frozen → Blocked` (release), and v1 has no authoring
  states — but machine `init` starts jobs exactly where release leaves
  them, so the absorbed prefix loses nothing v1 models. (Real
  `decideRelease`/`decideCreate` arrive with v4.)
- **A `run` chaining `.then(apply(D::decide…))` per aligned decision**, one
  specific decider call with the specific outcome argument the golden step
  implies, with `.expect(...)` after each step asserting:
  - `lastStep.transitions` equals the golden transitions for that segment
    **exactly** (transitions are fully modeled — no filtering), and
  - `modeled(lastStep.effects)` equals the allowlist-projection of the
    golden step's effects for that segment (§4).

`quint test` over the generated modules is the conformance run —
`scripts/check.sh` Stage 7, which needs no chuggernaut checkout (the modules
are committed) and, when a checkout *is* present (env `CHUGGERNAUT_DIR` or
the dev default), also regenerates into a temp dir and fails on any diff
against the committed files (drift guard).

### 2.1 Golden signal → decide mapping (as of today's decide.qnt)

The join key is the transition pair plus the adjacent `PublishEvent job-*`
effect. Model labels are the exact strings `decide.qnt` emits today.

| Golden signal (transition + `job-*` event)                       | decide* call                                | model label                             | status |
| ---------------------------------------------------------------- | ------------------------------------------- | ---------------------------------------- | ------ |
| `Frozen→Ready` / `Frozen→Blocked` + `job-released`                | — (absorbed into `replayInit`)              | `init`                                   | now, via init absorption; real create/release deciders need **v4** |
| `Ready→Work` + `job-started`                                      | `decideDispatch(c)`                         | `dispatch`                               | now |
| `Work→Evaluation` + `job-evaluation-started`                      | `decideTaskDone(c, j, WSuccess)`            | `work-succeeded`                         | now |
| `Evaluation→WrapUp` + `job-wrapup-started`                        | `decideEval(c, j, EPass)`                   | `eval-passed`                            | now |
| `WrapUp→Done` + `job-done`                                        | `decideLand(c, j, LClean)`                  | `job-done`                               | now |
| `Evaluation→Work` + `job-rework-started`                          | `decideEval(c, j, EProductFail)`            | `job-rework-started eval_failure`        | now |
| `Evaluation→Escalated` + `job-escalated`                          | `decideEval(c, j, EProductFail)`, budget 0  | `job-escalated rework_budget_exhausted`  | now (needs per-scenario `REWORK_BUDGET = 0` instance) |
| `WrapUp→Work` + `job-rework-started` (conflict *or* gate CI fail *or* gate-fix) | `decideLand(c, j, LConflictOrGateFail)` | `job-rework-started merge_gate_failure`  | now — v1 folds all three causes into one outcome; **v3** splits them |
| `Blocked→Ready` + `job-unblocked`                                 | `decideDepRecheck(c, j)`                    | `job-unblocked`                          | now |
| `Blocked→Stalled` + `job-stalled`                                 | `decideRevalFail(c, j)`                     | `job-stalled revalidation_failed`        | now |
| `Ready→Revoked` / `Frozen→Revoked` + `job-revoked`                | — no decider emits `Revoked`                | —                                        | **v4** (also breaks one-transition-per-decision: the cascade is 3 transitions in one decision) |
| staged-eval short circuit (effects grain: exactly one fan-out `task-created`) | — below v1 grain (one nondet `EvalOutcome` per round) | —                        | **v2** |
| gate entry/promote machinery (`CreateSquashCandidate`, `LaunchGateStage`, `AdvanceDefault`, `LaunchGateFix`) | — effects outside v1 abstraction | —                | **v3** |

Model labels with **no** golden coverage today — `work-retry`,
`job-escalated work_retries_exhausted`, `job-escalated
job_deadline_exceeded`, `operator-retry`, `stalled-retry`,
`stalled-retry-failed` (the goldens stop at escalation; none records an
operator resuming) — are exactly what the generation direction (§3) is for.

### 2.2 Replayability audit — all 11 golden fixtures

| fixture                              | verdict            | notes |
| ------------------------------------ | ------------------ | ----- |
| `work_eval_merge_no_gate.yaml`       | **replayable-now** | release prefix absorbed into init; the worked example below |
| `eval_failure_rework.yaml`           | **replayable-now** | `REWORK_BUDGET = 1` instance (`impl-rework`) |
| `eval_failure_no_budget_escalates.yaml` | **replayable-now** | `REWORK_BUDGET = 0` instance |
| `conflict_reentry.yaml`              | **replayable-now** | conflict rework = `LConflictOrGateFail`; `RebaseOntoWithConflict`/`EnterWork` filtered (v3 vocabulary) |
| `gate_failure_full_rework.yaml`      | **replayable-now** | transitions fully modeled; gate effects filtered (v3) |
| `gate_entry_and_promote.yaml`        | **replayable-now** | same — the gate is invisible at transition grain (`WrapUp→Done`) |
| `release_block_unblock.yaml`         | **replayable-now** | create steps skipped (no modeled content); upstream Done needs driver steps (fixture pokes the KV) |
| `stall_on_revalidation_failure.yaml` | **replayable-now** | same driver-step note |
| `staged_eval_short_circuit.yaml`     | **needs-v2**       | transition skeleton replays now (identical to `eval_failure_no_budget_escalates`), but the content the fixture exists to pin — stage-0 fails so stage 1 never launches — is below v1's one-nondet-`EvalOutcome` grain |
| `gate_fix_fast_path.yaml`            | **needs-v3**       | transition skeleton replays now, but gate-fix classification, `LaunchGateFix`, and the no-cycle-2-eval fast path need the merge-gate model (staged eval from v2 too) |
| `revoke_cascade.yaml`                | **needs-v4**       | `Frozen` and `Revoked` unreachable in v1; multi-job cascade in one decision |

**Score: 8 replayable-now, 1 needs-v2, 1 needs-v3, 1 needs-v4.** ("Needs-vN"
fixtures still replay their transition skeletons today; the verdict marks
where their *distinguishing* content becomes checkable.)

### 2.3 Worked example: `work_eval_merge_no_gate.yaml` by hand

The fixture is one golden step: transitions `Frozen→Ready, Ready→Work,
Work→Evaluation, Evaluation→WrapUp, WrapUp→Done`; effects: ten
`PublishEvent …` entries plus `SquashMerge`, `DeleteBranch job/1`. Its
hand-translation — the exact shape the generator will emit. This module
**typechecks and passes `quint test` against today's model as written**
(validated while drafting this PR; the module itself lands with the
generator, not here):

```quint
module replay_work_eval_merge_no_gate {
  import chug_types.* from "../types"

  // Scenario constants from the impl-cmd job type driven by the fixture:
  // no rework_budget, no same-cycle retries; deadline ample (never binds).
  import chug_machine(
    N_JOBS = 1, N_AGENTS = 1, WORK_RETRIES = 0, REWORK_BUDGET = 0, DEADLINE = 10
  ).* from "../machine"

  // A second (pure, stateless) chug_decide instance, so the run can invoke
  // the specific decide* call each golden step implies.
  import chug_decide(WORK_RETRIES = 0, REWORK_BUDGET = 0) as D from "../decide"

  // v1 modeled-effect allowlist, model side (§4).
  pure def modeled(effects: List[str]): List[str] =
    effects.select(e => Set("SquashMerge", "DeleteBranch").contains(e))

  // Explicit init: the golden trace's release prefix (Frozen -> Ready)
  // absorbed — machine init starts dep-free jobs exactly where release
  // leaves them.
  action replayInit = all {
    jobs' = Map(1 -> {
      state: Ready, deps: Set(), escalatedFrom: PNone, attempt: 0,
      evalReworks: 0, gateReworks: 0, deadlineLeft: 10,
      humanTaskOpen: false, wasEscalated: false
    }),
    readyQ' = [1],
    envActive' = true,
    lastStep' = { label: "init", transitions: [], effects: [] },
    prevMeasure' = 0
  }

  run replayWorkEvalMergeNoGateTest =
    replayInit
      // golden transition [2]: Ready -> Work  (PublishEvent job-started)
      .then(apply(D::decideDispatch(core)))
      .expect(lastStep.transitions == [{ job: 1, from: Ready, to: Work }])
      // golden transition [3]: Work -> Evaluation  (job-evaluation-started)
      .then(apply(D::decideTaskDone(core, 1, WSuccess)))
      .expect(lastStep.transitions == [{ job: 1, from: Work, to: Evaluation }])
      // golden transition [4]: Evaluation -> WrapUp  (job-wrapup-started)
      .then(apply(D::decideEval(core, 1, EPass)))
      .expect(lastStep.transitions == [{ job: 1, from: Evaluation, to: WrapUp }])
      // golden transition [5]: WrapUp -> Done  (SquashMerge, DeleteBranch job/1,
      // job-done). Terminal step: also compare allowlisted effects.
      .then(apply(D::decideLand(core, 1, LClean)))
      .expect(and {
        lastStep.transitions == [{ job: 1, from: WrapUp, to: Done }],
        modeled(lastStep.effects) == ["SquashMerge", "DeleteBranch"],
        jobs.get(1).state == Done
      })
}
```

Golden-side projection of the same step (what the generator computes to
build the final `.expect`): drop the ten `PublishEvent …` entries, normalize
`DeleteBranch job/1 → DeleteBranch`, keep `SquashMerge` — yielding
`[SquashMerge, DeleteBranch]`, which the terminal model step must match.
Note what the two `.expect` sides check: transitions **exactly**, effects
**through the allowlist** — the asymmetry §4 defines.

### 2.4 Implementation deltas (PR8 — what shipped vs this design)

The generator landed as designed — init absorption, decision-marker
segmentation, driver steps, the §2.1 mapping table verbatim — with these
deltas:

1. **Names/paths.** `scripts/gen-conformance.py` (not `gen_replay.py`);
   output committed under `specs/chuggernaut/tests/conformance/` as
   `conformance_<fixture>_test.qnt`; the model-side allowlist is the shared
   generated module `conformance_allowlist.qnt`, and both halves of the §4
   projection are maintained in one Python home — originally the generator
   itself, since PR9 the shared module `scripts/conformance_vocab.py`, which
   both conformance directions import (the refactor is byte-neutral: Stage
   7's drift guard proves the generated output did not change). Licensing:
   chuggernaut has no license file, so nothing from its tree is vendored;
   the generator reads the YAMLs at runtime and every generated file carries
   a provenance header (upstream URL + commit, source fixture, regeneration
   command).
2. **Effects are asserted after every aligned step**, not only at terminal
   steps as the §2.3 worked example sketched: the generator segments the
   golden effect stream at the decision markers and bakes each segment's
   allowlist projection into that step's `.expect`. Each `.expect` also pins
   `lastStep.label` (the §2.1 model label — an eval rework can never satisfy
   a gate-rework step) and `allInvariants`; driver steps assert
   `allInvariants` alone, and each run ends by asserting every job's final
   scenario state.
3. **`AdvanceDefault` is promotion, not filtered machinery** — a real
   vocabulary finding from replay. `gate_entry_and_promote`'s clean landing
   promotes the squash candidate by fast-forwarding the default branch: its
   golden effects carry `AdvanceDefault` and **no** `SquashMerge`, while the
   model's `LClean` emits `SquashMerge` unconditionally. Under this design's
   original allowlist (AdvanceDefault filtered as v3 machinery) that fixture
   fails effect comparison — model `[SquashMerge, DeleteBranch]` vs golden
   `[DeleteBranch]`. v1 cannot see whether a gate is present, so canonical
   `SquashMerge` now reads "the job's work was promoted into the default
   branch", golden side `SquashMerge` *or* `AdvanceDefault` (§4 table
   updated). v3, which models the gate, must split the two mechanisms again.
4. **The faithfulness boundary is hard-coded as generator errors.** An
   unmapped transition pair, an unknown `PublishEvent job-*` label, an
   unclassified effect string, marker/decision misalignment, or a decision
   the generator's mini-simulation says is not enabled (wrong ready-queue
   head, wrong budget arm) each abort generation — nothing is silently
   dropped or bent to pass. A new upstream fixture must be classified in the
   generator's audit tables before anything generates.
5. **`staged_eval_short_circuit` ships as a PARTIAL module** (marked in its
   header): its v1 transition skeleton + v1-grain effects replay green, per
   the §2.2 audit; `gate_fix_fast_path` (v3) and `revoke_cascade` (v4) are
   not generated — the generator prints them as skipped with the gating
   version.

Replay results at upstream `72dfa61`: all 9 generated modules pass
`quint test` — 36 aligned decisions (transitions + labels asserted exactly),
8 driver steps (invariant-checked), 13 modeled-effect comparisons. No
transition-level divergence; the one effect-level finding is delta 3.

## 3. Generation direction (model → golden candidates) — IMPLEMENTED (PR9)

The reverse arrow: let the simulator explore, then hand its traces to
chuggernaut as *candidate scenarios* — model-based conformance testing. The
pipeline:

```sh
just itf         # plumbing (PR5): one random ITF trace to traces/sample.itf.json
just itf-golden  # PR9: seeded, witness-targeted runs (scripts/gen-candidates.sh)
                 # projected to traces/candidates/*.yaml by
                 # scripts/itf-to-golden.py and round-trip verified (§3.4)
```

`traces/*.itf.json` and `traces/candidates/` are gitignored working output
(only `traces/.gitkeep` is committed). The two committed example candidates
live in `docs/examples/` — `candidate_clean_lifecycle.yaml` (all jobs land,
including a Blocked→Ready dep unblock) and `candidate_gate_rework_loop.yaml`
(the documented budget-free gate loop of model-status.md §5a, three
unbudgeted `merge_gate_failure` reworks of one job) — regenerated and
diffed by check Stage 8, so they can
never drift from the pinned seeds that produce them. They are model output
projected by our own tooling (no upstream file content), safe to commit.

### 3.1 What's in the ITF file (evidence)

ITF stores each state as a full snapshot of every variable, keyed by
qualified name (`#meta.vars` lists them; `lastStep` is one of the five).
From an actual `traces/sample.itf.json` emitted by `just itf` — state 2's
`mc_small::chug_machine::lastStep`, a dispatch decision:

```json
{
  "effects": ["CreateWorkTask", "LaunchContainer"],
  "label": "dispatch",
  "transitions": [
    {
      "from": { "tag": "Ready", "value": { "#tup": [] } },
      "job": { "#bigint": "1" },
      "to": { "tag": "Work", "value": { "#tup": [] } }
    }
  ]
}
```

and state 4's, an escalation:

```json
{
  "effects": ["CreateEscalationTask"],
  "label": "job-escalated work_retries_exhausted",
  "transitions": [
    { "from": { "tag": "Work", "value": { "#tup": [] } },
      "job": { "#bigint": "1" },
      "to": { "tag": "Escalated", "value": { "#tup": [] } } }
  ]
}
```

The golden step is sitting right there; only ITF value decoding stands
between them.

### 3.2 ITF → YAML projection (`scripts/itf-to-golden.py`)

As implemented (deltas from the original sketch are marked §3.5):

1. **Load** `states` from the ITF JSON; find the `lastStep` key by suffix
   match on the qualified name (instance prefixes vary by `--main`).
2. **Decode ITF values**: Quint sum constructors arrive as
   `{ "tag": "Ready", "value": { "#tup": [] } }` → take `tag`; ints as
   `{ "#bigint": "1" }` → int; `#map`/`#set`/`#tup` recursively. `JobState`
   constructor names match chuggernaut's Rust enum exactly (by design,
   `types.qnt`), so `tag` **is** the YAML state name — no mapping table
   (every decoded state name is still checked against the 12-name spelling
   set as a decoding guard). `#set` decodes sorted — ITF set order is
   arbitrary, sorting keeps projection deterministic. Non-unit variant
   payloads and unknown encodings are hard errors, per the §4 faithfulness
   rule.
3. **Project each state `i ≥ 1`** to a YAML step from its `lastStep`:
   - **skip** records labeled `init`, `noop-settle`, or `quiesce` — model
     bookkeeping with no observable decision and no counterpart in the
     golden schema (the initial snapshot, the settled/wedged stutter, and
     the one-way environment-goes-quiet switch). The skip is *checked*, not
     assumed: a skipped record must carry no transitions and no modeled
     effects, else projection aborts — so skipping provably loses nothing
     in the modeled vocabulary. Every other label must be in the script's
     explicit emit list (all 15 decision labels `decide.qnt` emits); an
     unknown label is a hard error, classified by a human;
   - `event:` ← the model label prefixed **`model:`** (e.g.
     `model:dispatch`), so candidates are always distinguishable from
     hand-written fixtures — golden `event` strings are author prose (§1
     fact 2), these are machine labels, strictly more precise;
   - `transitions:` ← decoded `[{job, from, to}]` verbatim (exactly one per
     step — v1 decisions carry exactly one transition, asserted);
   - `effects:` ← model→golden normalization via
     `conformance_vocab.model_to_golden` (§4): `DeleteBranch` →
     `DeleteBranch job/<j>` using the step's job id,
     `CreateEscalationTask` / `CreateHumanTask` → `PutTask
     Human(escalation)`, `SquashMerge` → `SquashMerge`; effects outside the
     shared vocabulary are dropped, unknown effect strings are hard errors.
4. **Emit** `steps: [...]` under a provenance header comment recording the
   source ITF, the exact seeded regeneration command (`--note` lines from
   `scripts/gen-candidates.sh`), and the scenario init from ITF state 0 —
   each job's initial state, deps, and deadline gas, plus the initial ready
   queue — so a chuggernaut harness can set up the same graph and budgets.

### 3.3 Interesting-trace selection (`scripts/gen-candidates.sh`)

Random depth-25 traces are mostly noise; the candidates worth handing
upstream are *targeted*. The selection trick is the expected-violation run:
ask the simulator to check the **negation** of the interesting property as
an `--invariant` at a pinned seed, and the counterexample ITF it dumps is
exactly the trace that exhibits it, deterministically (the rust backend
reproduces seeds bit-for-bit). The two pinned candidates:

| candidate | run | targets |
| --------- | --- | ------- |
| `candidate_clean_lifecycle.yaml` | `mc_small`, seed `0x37a1792d8159488`, expected-fail of `not(witnessAllDone and witnessBlockedUnblocks)`, depth 14 | near-minimal full-graph happy path: 3 jobs land, one after a `Blocked→Ready` unblock; also exercises the skip policy (a mid-trace `quiesce`) |
| `candidate_gate_rework_loop.yaml` | `mc_livelock`, seed `0xa5110d572bfbd1d5` (check Stage 6a's own seed), expected-fail of `gateReworksWithinBudgets`, depth 40 | the documented spec.md:1265 budget-free gate loop: 3 `merge_gate_failure` reworks of one job, `rework_budget` untouched — **no hand-written golden fixture covers this path** |

What generation buys beyond replay: candidates for the decision paths **no
golden fixture covers today** (§2.1: same-cycle `work-retry`,
`work_retries_exhausted` and `job_deadline_exceeded` escalations, the whole
`operator-retry` / `stalled-retry` resumption family — all validated
round-trippable in PR9's shakeout), and mechanically generated rare
interleavings like the gate-rework loop as an executable implementation
test.

### 3.4 Round-trip validation (check Stage 8)

The meaningful in-repo check: **the projection is loss-free w.r.t. the
modeled vocabulary.** `itf-to-golden.py --roundtrip` re-parses the emitted
YAML and aligns it step-for-step against the ITF's `lastStep` sequence:

- transitions must match **exactly** (and every state name must be a legal
  `JobState` spelling);
- `event` must be exactly `model:` + the model label;
- effect sequences must be equal **in the canonical §4 alphabet**, with the
  YAML side re-read through the *replay* direction's golden-effect
  classifier (`classify_golden_effect`) and the ITF side through the
  model-side allowlist (`model_canonical`) — two independently maintained
  tables, so a bug in either mapping, or in the ITF decoding, breaks the
  equation rather than cancelling out. `DeleteBranch job/<n>` additionally
  has its job id checked against the step's transition;
- skipped bookkeeping records are re-checked to carry no transitions and no
  modeled effects (the skip loses nothing);
- the YAML must be exactly consumed (no missing or trailing steps).

check.sh Stage 8 runs the full pipeline at the pinned seeds (generate ITF →
project → round-trip) and then diffs the projected YAMLs against
`docs/examples/` — the generation-side drift guard, self-contained (no
chuggernaut checkout involved). What Stage 8 does **not** prove: that the
candidates *execute* against chuggernaut. That is the upstream half (§3.6),
untested until the chuggernaut owner runs it.

### 3.5 Implementation deltas (PR9 — what shipped vs the §3.2 sketch)

1. **Names/paths.** `scripts/itf-to-golden.py` (not `itf_to_golden.py`);
   the shared vocabulary refactored out of `gen-conformance.py` into
   `scripts/conformance_vocab.py` (imported by both directions; Stage 7's
   drift guard proves the refactor changed no generated byte); selection
   lives in `scripts/gen-candidates.sh` (= `just itf-golden`).
2. **The `model:` event prefix** — the sketch had bare machine labels;
   the prefix makes machine provenance unmistakable in a directory of
   mixed fixtures.
3. **The skip policy is enforced, not assumed** (`init`/`noop-settle`/
   `quiesce` must be empty of modeled content), and the label vocabulary is
   closed: `operator-retry-unreachable` (decide.qnt's defensive
   match-totalizer) is deliberately *not* classified, so its appearance in
   a trace fails projection loudly.
4. **Effects are emitted even when empty** (`effects: []`) — one schema for
   every step; golden fixtures omit keys freely, candidates don't.
5. **Scenario constants in the header are partial.** The ITF carries no
   instance constants, so the header records what state 0 proves (initial
   states, deps, deadline gas, ready queue) and the budgets arrive as
   `--note` provenance from gen-candidates.sh, not from the trace itself.

### 3.6 The upstream handoff (for the chuggernaut owner)

*This section is written for the chuggernaut maintainer as first reader.
Context in one line: [swarm-spec](../README.md) maintains a formal model of
your dispatcher's job-state machine; it already replays your eleven golden
trace fixtures against the model (§2), and this section describes the
reverse artifact — **candidate** golden traces generated from the model for
your harness to execute.*

**What a candidate is.** A YAML file in your golden-trace schema (`steps:`
of `{event, transitions: [{job, from, to}], effects: [str]}`), produced by
projecting a model-checker trace, not by recording your dispatcher. State
names are spelled exactly as your `JobState` enum spells them. Two examples
ship in `docs/examples/`; `just itf-golden` regenerates them and can
produce more (any seed, any targeted property). Every candidate's header
records the exact seeded command that produced it and the job graph +
budgets to set the scenario up with.

**How you would consume one.** Drop the YAML into
`crates/dispatcher/tests/traces/` and drive it with a
`golden_traces.rs`-style test: build the header's jobs/deps with the
header's budgets, release, then drive the dispatcher through the step
sequence, recording with `TraceSink` and diffing at the end. Two mapping
tables you need, both small:

- **Events**: candidate `event` strings are machine labels prefixed
  `model:` (`model:dispatch`, `model:eval-passed`,
  `model:job-rework-started merge_gate_failure`, …) — the §2.1 table read
  right-to-left tells you which dispatcher stimulus each one names
  (dispatch the queue head; complete the work task successfully; deliver a
  failing eval verdict; …).
- **Effects**: candidates carry only the three-entry modeled vocabulary,
  spelled your way — `SquashMerge`, `DeleteBranch job/<n>`,
  `PutTask Human(escalation)` (§4 table). Your recorded trace will contain
  *more* effects (every `PublishEvent …`, task/gate machinery); compare
  through the same projection (keep those three, normalize
  `AdvanceDefault` → `SquashMerge`, drop the rest), not by equality.

**What would NOT line up today — the honest paragraph.** (1) *No release
prefix*: candidates start jobs where release leaves them (`Ready`/
`Blocked`), so your recorder's opening `Frozen→Ready` transitions and
`job-created`/`job-released` events have no candidate counterpart — set up
and release first, align from the first dispatch. (2) *The YAML is
assertion data, not a driver script*: labels name **outcomes**
(`model:eval-passed` means "the eval round passes"), so your test must
force each nondeterministic outcome — e.g. the gate-rework-loop candidate
needs a landing that fails the gate three times in a row, which in your
system means a default branch that keeps moving against the job; some
candidates may be awkward or impossible to stage, and *that is signal* (a
candidate your harness can prove unreachable is a model bug we want
reported — §4). (3) *The SquashMerge/AdvanceDefault split*: the model
cannot see merge gates (v3), so a candidate's clean landing always says
`SquashMerge`; if your scenario setup engages the gate, your trace will
record `AdvanceDefault` instead — equivalent under the projection above,
different as strings (this repo's §5e finding, docs/model-status.md).
(4) *Parameterized effect arguments*: the model has no branch names, task
ids, or gate ids — `DeleteBranch job/<n>` is reconstructed from the step's
job id, but everything else you parameterize (task payloads, event bodies,
`merge-gate/<n>` branches) is absent. (5) *No KV shortcuts*: two of your
fixtures finish an upstream job by writing the store directly; the model
can't, so candidates spell out the full dependency lifecycle step by step
— expect candidates to be longer than the fixture you would have written.

**Status**: the projection itself is verified loss-free in this repo
(§3.4), on the pinned seeds and a randomized shakeout. Whether the
candidates execute in your harness is **untested** — that run is yours,
and either outcome is valuable (§4: a rejected candidate is a model bug to
tighten or a real divergence to fix).

## 4. The conformance relation

Both directions are instances of one relation, parameterized by the modeled
vocabulary `V` (grows monotonically with v2/v3/v4):

- **Transition alphabet: total.** Every §2.1 transition among v1-reachable
  states is modeled, so transition sequences must match **exactly** after
  the two structural adjustments of §2: the release prefix absorbed into
  init, and driver steps (model-only, invariant-checked) excluded.
- **Effect alphabet: the shared normalized vocabulary.** v1's is three
  canonical effects:

  | canonical             | model side                                              | golden side                        |
  | --------------------- | ------------------------------------------------------- | ---------------------------------- |
  | `SquashMerge` ("work promoted to default") | `SquashMerge`                      | `SquashMerge`; `AdvanceDefault` (gated promote — §2.4 delta 3) |
  | `DeleteBranch`        | `DeleteBranch`                                          | `DeleteBranch job/<n>` (job branch only) |
  | `HumanEscalationTask` | `CreateEscalationTask` (→Escalated), `CreateHumanTask` (→Stalled) | `PutTask Human(escalation)` |

  Everything else is projected away before comparison:
  - golden-only, outside the v1 abstraction: all `PublishEvent …`
    (segmentation signals, not compared), `CreateSquashCandidate`,
    `LaunchGateStage`, `LaunchGateFix`, `DeleteBranch merge-gate/<n>`,
    `RebaseOntoWithConflict`, `EnterWork` (v3 gate/queue machinery);
  - model-only, below or beside the goldens' grain: `CreateWorkTask`,
    `LaunchContainer` (the impl logs these only as `PublishEvent
    task-created` / `task-launched`), `FanOutEvaluators` (v2 grain),
    `EnqueueMergeCandidate` (v3 queue).

Two traces **conform** iff their projections onto `V` are equal as
sequences. A violation is always one of two valuable outcomes:

- **Model bug** — the model's decision shape diverges from behavior the
  implementation actually exhibits (replay direction), or the model permits
  a sequence the implementation refuses (generation direction: candidate
  rejected by the chuggernaut harness → tighten a model guard).
- **Real divergence** — the implementation took a transition or emitted an
  effect the spec's §2.1/§3.3 reading (as transcribed in the model) does
  not allow. That is precisely the class of bug this repo exists to catch.

The allowlist **is** the honesty boundary: every effect filtered out is a
claim the model does not yet make. Each roadmap version moves effects from
the filtered lists into the shared vocabulary (v2: task/fan-out grain; v3:
gate machinery and the conflict/gate-CI/gate-fix split of
`LConflictOrGateFail`; v4: authoring/revoke), monotonically strengthening
the relation until the projection is the identity.

The vocabulary's one executable home is `scripts/conformance_vocab.py`:
the golden→canonical classifier (replay, §2, and the round-trip's YAML
side), the model→canonical mapping (mirrored by the generated
`conformance_allowlist.qnt` the replay tests execute, whose text is emitted
from the same file), and the model→golden spelling used by generation
(§3). Both directions import it, so the two halves of the projection cannot
drift apart.
