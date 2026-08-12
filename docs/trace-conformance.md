# Trace conformance: model ↔ golden traces (design)

Status: **design + plumbing only** (PR5). This document specifies the
conformance harness between the Quint model and chuggernaut's golden decision
traces. Nothing here is implemented yet except the ITF emission plumbing
(`just itf`); the replay generator and the ITF→YAML converter are the
follow-on work.

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

A generator (`scripts/gen_replay.py`, follow-on PR) reads each golden YAML
and emits one Quint module per scenario into `specs/chuggernaut/replay/`,
each containing:

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

`quint test` over the generated modules is the conformance run; it slots
into `scripts/check.sh` as a new stage when the generator lands.

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

## 3. Generation direction (model → golden candidates) — later

The reverse arrow: let the simulator explore, then hand its traces to
chuggernaut as *candidate scenarios* — model-based conformance testing. The
plumbing landed in this PR:

```sh
just itf   # = npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small \
           #     --max-samples=1 --max-steps=25 --out-itf=traces/sample.itf.json
```

`traces/*.itf.json` is gitignored (only `traces/.gitkeep` is committed).

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

### 3.2 ITF → YAML projection sketch

A small converter (`scripts/itf_to_golden.py`, follow-on PR):

1. **Load** `states` from the ITF JSON; find the `lastStep` key by suffix
   match on the qualified name (instance prefixes vary by `--main`).
2. **Decode ITF values**: Quint sum constructors arrive as
   `{ "tag": "Ready", "value": { "#tup": [] } }` → take `tag`; ints as
   `{ "#bigint": "1" }` → int. `JobState` constructor names match
   chuggernaut's Rust enum exactly (by design, `types.qnt`), so `tag` **is**
   the YAML state name — no mapping table.
3. **Project each state `i ≥ 1`** to a YAML step from its `lastStep`:
   - skip records with label `init`, `noop-settle`, or `quiesce` (model
     bookkeeping, no observable decision);
   - `event:` ← the model label (unlike golden fixtures, generated
     scenarios get *machine* labels — strictly more precise);
   - `transitions:` ← decoded `[{job, from, to}]`;
   - `effects:` ← model→golden normalization (§4): `DeleteBranch` →
     `DeleteBranch job/<j>` using the step's job id,
     `CreateEscalationTask` / `CreateHumanTask` → `PutTask
     Human(escalation)`; drop effects outside the shared vocabulary.
4. **Emit** `steps: [...]` plus a scenario header comment recording the
   instance constants and init DAG (deps per job) so the chuggernaut
   harness can set up the same graph and budgets.

The consumer is a `golden_traces.rs`-style harness on the chuggernaut side:
build the scenario's jobs/deps, drive the dispatcher along the candidate's
event sequence, record with `TraceSink`, and diff — through the same
allowlist, since the implementation's trace will contain effects the
candidate never mentions.

What generation buys beyond replay: candidates for the decision paths **no
golden fixture covers today** (§2.1: same-cycle `work-retry`,
`work_retries_exhausted` and `job_deadline_exceeded` escalations, the whole
`operator-retry` / `stalled-retry` resumption family), and — with
`--max-samples` cranked up — mechanically generated rare interleavings like
the mc_livelock gate-rework loop as an executable implementation test.

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
  | `SquashMerge`         | `SquashMerge`                                           | `SquashMerge`                      |
  | `DeleteBranch`        | `DeleteBranch`                                          | `DeleteBranch job/<n>` (job branch only) |
  | `HumanEscalationTask` | `CreateEscalationTask` (→Escalated), `CreateHumanTask` (→Stalled) | `PutTask Human(escalation)` |

  Everything else is projected away before comparison:
  - golden-only, outside the v1 abstraction: all `PublishEvent …`
    (segmentation signals, not compared), `CreateSquashCandidate`,
    `LaunchGateStage`, `LaunchGateFix`, `AdvanceDefault`,
    `DeleteBranch merge-gate/<n>`, `RebaseOntoWithConflict`, `EnterWork`
    (v3 gate/queue machinery);
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
