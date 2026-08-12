#!/usr/bin/env python3
"""Generate Quint replay-conformance tests from chuggernaut's golden traces.

The replay direction of docs/trace-conformance.md: each replayable golden
fixture (crates/dispatcher/tests/traces/*.yaml in a chuggernaut checkout) is
compiled into one deterministic Quint module containing a `run ...Test` that
drives the exact decide* calls the fixture implies and asserts `lastStep`
after every step — transitions (and the model label) exactly, effects through
the v1 modeled-vocabulary allowlist, with every step also checked against
`allInvariants`.

Licensing: chuggernaut has no license file, so NO upstream file content is
vendored into swarm-spec. This generator reads the YAMLs at runtime from
--chuggernaut and emits only re-expressed state-machine facts (job ids,
transitions, event/effect labels) under a provenance header.

Usage:
  python3 scripts/gen-conformance.py \
      --chuggernaut <chuggernaut-checkout> \
      --out specs/chuggernaut/tests/conformance/

Deterministic: the same fixtures at the same upstream commit produce
byte-identical output (no timestamps, no dict-order dependence).

Faithfulness rule (docs/trace-conformance.md §4): this generator NEVER bends
a fixture to make it replay. Anything it cannot map exactly — an unmapped
transition pair, an unclassified effect string, an unknown `PublishEvent
job-*` marker, a decision its mini-simulation says is not enabled — is a hard
error, to be resolved by a human as a generator bug, a model bug, or a real
model<->code divergence.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

GENERATOR_CMD = (
    "python3 scripts/gen-conformance.py "
    "--chuggernaut <chuggernaut-checkout> --out specs/chuggernaut/tests/conformance/"
)
UPSTREAM_URL_FALLBACK = "https://github.com/kasofsk/chuggernaut"
TRACES_SUBDIR = "crates/dispatcher/tests/traces"

# --------------------------------------------------------------------------
# The golden-signal -> decide* mapping (docs/trace-conformance.md §2.1).
# Key: (from, to) transition pair. Value: (decision marker — the adjacent
# `PublishEvent job-*` effect that ends the decision's effect segment,
# model label decide.qnt emits, decide* call template).
# --------------------------------------------------------------------------
DECIDERS = {
    ("Ready", "Work"): (
        "job-started", "dispatch",
        "D::decideDispatch(core)"),
    ("Work", "Evaluation"): (
        "job-evaluation-started", "work-succeeded",
        "D::decideTaskDone(core, {j}, WSuccess)"),
    ("Evaluation", "WrapUp"): (
        "job-wrapup-started", "eval-passed",
        "D::decideEval(core, {j}, EPass)"),
    ("WrapUp", "Done"): (
        "job-done", "job-done",
        "D::decideLand(core, {j}, LClean)"),
    ("Evaluation", "Work"): (
        "job-rework-started", "job-rework-started eval_failure",
        "D::decideEval(core, {j}, EProductFail)"),
    ("WrapUp", "Work"): (
        "job-rework-started", "job-rework-started merge_gate_failure",
        "D::decideLand(core, {j}, LConflictOrGateFail)"),
    ("Evaluation", "Escalated"): (
        "job-escalated", "job-escalated rework_budget_exhausted",
        "D::decideEval(core, {j}, EProductFail)"),
    ("Blocked", "Ready"): (
        "job-unblocked", "job-unblocked",
        "D::decideDepRecheck(core, {j})"),
    ("Blocked", "Stalled"): (
        "job-stalled", "job-stalled revalidation_failed",
        "D::decideRevalFail(core, {j})"),
}

DECISION_MARKERS = {marker for (marker, _, _) in DECIDERS.values()}

# `PublishEvent job-*` labels that are NOT decision markers: either absorbed
# into replayInit (create/release prefix) or v3 gate machinery that happens
# inside a modeled segment. Any job-* label outside these two sets is a hard
# error — new upstream vocabulary must be classified by a human.
NON_MARKER_JOB_EVENTS = {
    "job-created",             # absorbed: authoring is v4; no transition
    "job-released",            # absorbed into replayInit (Frozen -> Ready/Blocked)
    "job-merge-gate-started",  # v3: gate machinery inside the WrapUp segment
    "job-rebase-conflict",     # v3: rebase telemetry inside a work segment
}

# Golden effects outside the v1 modeled vocabulary (docs/trace-conformance.md
# §4): projected away before comparison. Explicitly enumerated so an unknown
# effect string fails generation instead of being silently dropped.
UNMODELED_GOLDEN_EXACT = {
    "CreateSquashCandidate",   # v3 gate machinery
    "LaunchGateStage",         # v3
    "LaunchGateFix",           # v3
    "RebaseOntoWithConflict",  # v3
    "EnterWork",               # v3 queue/rework plumbing
}
UNMODELED_GOLDEN_PATTERNS = [
    re.compile(r"PublishEvent \S+"),          # segmentation signals, not compared
    re.compile(r"DeleteBranch merge-gate/\d+"),  # v3: gate branch, not the job branch
]


def golden_canonical(effect: str):
    """Golden-side half of the §4 allowlist projection.

    Model-side half lives in the generated conformance_allowlist.qnt (both
    halves are emitted from this file — the allowlist has one home).

    Delta from the design doc (recorded in docs/trace-conformance.md):
    `AdvanceDefault` normalizes to canonical "SquashMerge" instead of being
    filtered as v3 machinery. Gated landings promote the squash candidate by
    fast-forwarding the default branch (AdvanceDefault) and never emit a
    literal SquashMerge; v1 cannot see whether a gate is present, so its
    canonical "SquashMerge" means "the job's work was promoted into the
    default branch" — true of both promotion mechanisms.
    """
    if effect in ("SquashMerge", "AdvanceDefault"):
        return "SquashMerge"
    if re.fullmatch(r"DeleteBranch job/\d+", effect):
        return "DeleteBranch"
    if effect == "PutTask Human(escalation)":
        return "HumanEscalationTask"
    return None


def classify_effect(effect: str):
    """Return the canonical name, or None for a known-unmodeled effect.

    Raises on vocabulary this generator has never seen — the faithfulness
    rule: unknown effects must be classified by a human, not dropped.
    """
    canon = golden_canonical(effect)
    if canon is not None:
        return canon
    if effect in UNMODELED_GOLDEN_EXACT:
        return None
    for pat in UNMODELED_GOLDEN_PATTERNS:
        if pat.fullmatch(effect):
            return None
    raise GenError(f"unclassified golden effect {effect!r} — extend the allowlist tables")


# --------------------------------------------------------------------------
# Per-fixture scenario constants, from the job types the upstream harness
# (crates/dispatcher/tests/golden_traces.rs) drives each scenario with.
# Constants the YAML itself carries (job ids, initial Ready/Blocked states)
# are derived from the trace; only budgets and dep edges live here.
# DEADLINE is ample everywhere: no fixture exercises the deadline backstop.
# --------------------------------------------------------------------------
DEFAULTS = dict(n_agents=1, work_retries=0, rework_budget=0, deadline=10, deps={})

SCENARIOS = {
    "work_eval_merge_no_gate": dict(
        job_type="impl-cmd (no rework_budget, no same-cycle retries)"),
    "eval_failure_rework": dict(
        rework_budget=1,
        job_type="impl-rework (rework_budget: 1)"),
    "eval_failure_no_budget_escalates": dict(
        job_type="impl-cmd (no rework_budget)"),
    "conflict_reentry": dict(
        job_type="impl-cmd; conflict rework folds into LConflictOrGateFail (v1)"),
    "gate_failure_full_rework": dict(
        job_type="impl-cmd; gate-CI rework folds into LConflictOrGateFail (v1)"),
    "gate_entry_and_promote": dict(
        job_type="impl-cmd; gate machinery invisible at v1 transition grain"),
    "release_block_unblock": dict(
        deps={2: [1]},
        job_type="build/deploy; job 2 (deploy) depends on job 1 (build)"),
    "stall_on_revalidation_failure": dict(
        deps={2: [1]},
        job_type="build/deploy; job 2 (deploy) depends on job 1 (build)"),
    "staged_eval_short_circuit": dict(
        job_type="gatefix (staged eval; no rework_budget)",
        partial=(
            "PARTIAL replay (gated on v2): only the transition skeleton and\n"
            "v1-grain effects are checked (identical to\n"
            "eval_failure_no_budget_escalates). The content this fixture exists\n"
            "to pin — stage-0 failure short-circuits stage 1, exactly one\n"
            "evaluator fan-out — is below v1's one-nondet-EvalOutcome grain and\n"
            "becomes checkable with the v2 staged-eval model.")),
}

SKIPPED = {
    "gate_fix_fast_path": (
        "v3 — needs the merge-gate model: gate-fix classification, "
        "LaunchGateFix, and the no-cycle-2-eval fast path (staged eval from v2 too)"),
    "revoke_cascade": (
        "v4 — Frozen/Revoked unreachable in v1, and the multi-job cascade is "
        "3 transitions in one decision (breaks v1's one-transition-per-decision grain)"),
}


class GenError(RuntimeError):
    pass


def camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


# --------------------------------------------------------------------------
# Alignment: flatten the golden steps, absorb the release prefix, map each
# remaining transition to a decision, and segment the effect stream at the
# decision markers (docs/trace-conformance.md §1–§2).
# --------------------------------------------------------------------------

def align(name: str, ydata: dict, scen: dict):
    steps = ydata.get("steps")
    if not isinstance(steps, list) or not steps:
        raise GenError("fixture has no steps")

    proses = []          # golden step index -> event prose
    transitions = []     # (golden step index, {job, from, to})
    effects = []         # effect strings, in stream order
    for si, step in enumerate(steps):
        proses.append(str(step.get("event", "")))
        for t in step.get("transitions") or []:
            transitions.append((si, t))
        for e in step.get("effects") or []:
            effects.append(str(e))

    # Release prefix -> initial states; the rest -> decisions.
    init_states = {}
    decisions = []
    for si, t in transitions:
        j, frm, to = int(t["job"]), str(t["from"]), str(t["to"])
        if frm == "Frozen":
            if to not in ("Ready", "Blocked"):
                raise GenError(f"job {j}: unmapped release transition Frozen -> {to}")
            if j in init_states:
                raise GenError(f"job {j}: released twice")
            init_states[j] = to
            continue
        if (frm, to) not in DECIDERS:
            raise GenError(f"job {j}: unmapped transition {frm} -> {to}")
        decisions.append(dict(job=j, frm=frm, to=to, step_idx=si))

    deps = {int(k): sorted(int(d) for d in v) for k, v in scen["deps"].items()}
    job_ids = sorted(set(init_states) | {d["job"] for d in decisions}
                     | set(deps) | {d for ds in deps.values() for d in ds})
    n_jobs = max(job_ids)
    if job_ids != list(range(1, n_jobs + 1)):
        raise GenError(f"non-contiguous job ids {job_ids}")
    for j in job_ids:
        if j not in init_states:
            raise GenError(f"job {j} has no release transition (Frozen -> Ready/Blocked)")
        blocked = init_states[j] == "Blocked"
        if blocked != bool(deps.get(j)):
            raise GenError(f"job {j}: released {init_states[j]} but deps table says {deps.get(j, [])}")

    # Segment the effect stream at decision markers.
    segments = []
    current = []
    for e in effects:
        current.append(e)
        if e.startswith("PublishEvent job-"):
            marker = e[len("PublishEvent "):]
            if marker in DECISION_MARKERS:
                segments.append((marker, current))
                current = []
            elif marker not in NON_MARKER_JOB_EVENTS:
                raise GenError(f"unknown job event {e!r} — classify it as marker or non-marker")
    if any(classify_effect(e) is not None for e in current):
        raise GenError(f"modeled effect(s) after the last decision marker: {current}")
    if len(segments) != len(decisions):
        raise GenError(
            f"{len(decisions)} mapped decisions but {len(segments)} decision markers "
            f"in the effect stream — alignment is broken")

    for d, (marker, seg) in zip(decisions, segments):
        want_marker, label, call = DECIDERS[(d["frm"], d["to"])]
        if marker != want_marker:
            raise GenError(
                f"decision {d['frm']} -> {d['to']} (job {d['job']}) expects marker "
                f"{want_marker!r} but the effect stream has {marker!r}")
        d["label"] = label
        d["call"] = call.format(j=d["job"])
        d["marker"] = marker
        d["golden_effects"] = [x for x in (classify_effect(e) for e in seg) if x is not None]

    return dict(n_jobs=n_jobs, init_states=init_states, deps=deps,
                decisions=decisions, proses=proses)


# --------------------------------------------------------------------------
# Mini-simulation: validates each mapped decision is actually enabled in the
# model (queue head for dispatch, budget arms, deps-Done guards) and inserts
# the driver steps for fixtures that poke the KV store to finish an upstream
# job (docs/trace-conformance.md §1). Driver steps are excluded from golden
# alignment but still invariant-checked in the emitted run.
# --------------------------------------------------------------------------

def simulate(name: str, scen: dict, plan: dict):
    state = dict(plan["init_states"])
    ready_q = [j for j in range(1, plan["n_jobs"] + 1) if state[j] == "Ready"]
    eval_reworks = {j: 0 for j in state}
    deps = plan["deps"]
    budget = scen["rework_budget"]

    emitted = []  # dicts: kind=driver|aligned

    def drive(j, frm, to, label, call):
        emitted.append(dict(kind="driver", job=j, frm=frm, to=to, label=label, call=call))

    def apply_transition(j, frm, to):
        if state[j] != frm:
            raise GenError(f"job {j}: golden says {frm} -> {to} but simulated state is {state[j]}")
        if (frm, to) == ("Ready", "Work"):
            if not ready_q or ready_q[0] != j:
                raise GenError(
                    f"job {j}: dispatch requires it at the readyQ head, queue is {ready_q}")
            ready_q.pop(0)
        elif (frm, to) == ("Evaluation", "Work"):
            if eval_reworks[j] >= budget:
                raise GenError(
                    f"job {j}: golden takes an eval rework but REWORK_BUDGET={budget} "
                    f"is already spent — scenario constants are wrong")
            eval_reworks[j] += 1
        elif (frm, to) == ("Evaluation", "Escalated"):
            if eval_reworks[j] < budget:
                raise GenError(
                    f"job {j}: golden escalates out of Evaluation but rework budget "
                    f"remains ({eval_reworks[j]} < {budget}) — scenario constants are wrong")
        elif frm == "Blocked":
            pending = [d for d in deps.get(j, []) if state[d] != "Done"]
            if pending:
                raise GenError(f"job {j}: dep recheck with deps not Done: {pending}")
            if to == "Ready":
                ready_q.append(j)
        state[j] = to

    def drive_to_done(k):
        """Driver steps: run job k Ready -> ... -> Done (the fixture pokes the
        KV store instead; the model must take real, invariant-checked steps)."""
        if state[k] != "Ready":
            raise GenError(f"driver for dep {k} in state {state[k]} not supported")
        seq = [
            ("Ready", "Work", "dispatch", "D::decideDispatch(core)"),
            ("Work", "Evaluation", "work-succeeded", f"D::decideTaskDone(core, {k}, WSuccess)"),
            ("Evaluation", "WrapUp", "eval-passed", f"D::decideEval(core, {k}, EPass)"),
            ("WrapUp", "Done", "job-done", f"D::decideLand(core, {k}, LClean)"),
        ]
        for frm, to, label, call in seq:
            apply_transition(k, frm, to)
            drive(k, frm, to, label, call)

    for d in plan["decisions"]:
        if d["frm"] == "Blocked":
            for k in deps.get(d["job"], []):
                if state[k] != "Done":
                    drive_to_done(k)
        apply_transition(d["job"], d["frm"], d["to"])
        emitted.append(dict(kind="aligned", **d))

    return emitted, state


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

def qlist(items):
    return "[" + ", ".join(f'"{x}"' for x in items) + "]"


def provenance_header(upstream_url: str, commit: str, source: str) -> str:
    return (
        f"// GENERATED by scripts/gen-conformance.py — DO NOT EDIT. Regenerate with:\n"
        f"//   {GENERATOR_CMD}\n"
        f"// Upstream: {upstream_url} @ {commit}\n"
        f"// Source fixture: {source}\n"
        f"// Licensing/provenance: chuggernaut has no license file, so no upstream file\n"
        f"// content is vendored; this module re-expresses the fixture's state-machine\n"
        f"// facts (job ids, transitions, event/effect labels) as a deterministic Quint\n"
        f"// run per docs/trace-conformance.md §2.\n")


def emit_fixture(name: str, scen: dict, plan: dict, emitted, final_states,
                 upstream_url: str, commit: str) -> str:
    n_jobs = plan["n_jobs"]
    consts = (f"N_JOBS = {n_jobs}, N_AGENTS = {scen['n_agents']}, "
              f"WORK_RETRIES = {scen['work_retries']}, "
              f"REWORK_BUDGET = {scen['rework_budget']}, DEADLINE = {scen['deadline']}")

    out = [provenance_header(upstream_url, commit, f"{TRACES_SUBDIR}/{name}.yaml")]
    if "partial" in scen:
        out.append("//\n")
        for line in scen["partial"].splitlines():
            out.append(f"// {line}\n")
    out.append("//\n")
    out.append(f"// Scenario: {scen['job_type']}.\n")
    out.append(f"// Instance: {consts} (deadline ample — the fixture never exercises it).\n")
    out.append(f"module conformance_{name}_test {{\n")
    out.append('  import chug_types.* from "../../types"\n')
    out.append(f"  import chug_machine(\n    {consts}\n  ).* from \"../../machine\"\n")
    out.append(f"  import chug_decide(WORK_RETRIES = {scen['work_retries']}, "
               f"REWORK_BUDGET = {scen['rework_budget']}) as D from \"../../decide\"\n")
    out.append('  import conformance_allowlist.* from "./conformance_allowlist"\n\n')

    # replayInit: the golden release prefix absorbed (Frozen -> Ready/Blocked).
    out.append("  // Golden release prefix absorbed into init "
               "(docs/trace-conformance.md §2):\n")
    for j in range(1, n_jobs + 1):
        out.append(f"  //   job {j}: Frozen -> {plan['init_states'][j]}\n")
    out.append("  action replayInit = all {\n")
    out.append("    jobs' = Map(\n")
    entries = []
    for j in range(1, n_jobs + 1):
        depset = ", ".join(str(d) for d in plan["deps"].get(j, []))
        entries.append(
            f"      {j} -> {{ state: {plan['init_states'][j]}, deps: Set({depset}), "
            f"escalatedFrom: PNone, attempt: 0,\n"
            f"             evalReworks: 0, gateReworks: 0, deadlineLeft: {scen['deadline']},\n"
            f"             humanTaskOpen: false, wasEscalated: false }}")
    out.append(",\n".join(entries) + "\n    ),\n")
    ready0 = [j for j in range(1, n_jobs + 1) if plan["init_states"][j] == "Ready"]
    out.append(f"    readyQ' = [{', '.join(str(j) for j in ready0)}],\n")
    out.append("    envActive' = true,\n")
    out.append("    lastStep' = { label: \"init\", transitions: [], effects: [] },\n")
    out.append("    prevMeasure' = 0\n")
    out.append("  }\n\n")

    out.append(f"  run {camel(name)}Test =\n")
    out.append("    replayInit\n")
    aligned_total = sum(1 for s in emitted if s["kind"] == "aligned")
    aligned_i = 0
    last_prose = None
    body = []
    for s in emitted:
        if s["kind"] == "driver":
            body.append(
                f"      // DRIVER (no golden counterpart): the fixture pokes the KV store to\n"
                f"      // finish upstream job {s['job']}; the model takes the real step "
                f"{s['frm']} -> {s['to']}.\n"
                f"      // Excluded from alignment; still invariant-checked.\n"
                f"      .then(apply({s['call']}))\n"
                f"      .expect(allInvariants)\n")
            continue
        aligned_i += 1
        prose = plan["proses"][s["step_idx"]]
        if prose != last_prose:
            body.append(f"      // golden step {s['step_idx'] + 1}: \"{prose}\"\n")
            last_prose = prose
        body.append(
            f"      // [{aligned_i}/{aligned_total}] job {s['job']}: {s['frm']} -> {s['to']}"
            f"  (marker: PublishEvent {s['marker']})\n"
            f"      .then(apply({s['call']}))\n"
            f"      .expect(and {{\n"
            f"        lastStep.label == \"{s['label']}\",\n"
            f"        lastStep.transitions == "
            f"[{{ job: {s['job']}, from: {s['frm']}, to: {s['to']} }}],\n"
            f"        modeledEffects(lastStep.effects) == {qlist(s['golden_effects'])},\n"
            f"        allInvariants\n"
            f"      }})\n")
    # Final scenario states, asserted once at the end.
    finals = ",\n".join(
        f"        jobs.get({j}).state == {final_states[j]}" for j in range(1, n_jobs + 1))
    body.append(
        f"      // Final scenario states.\n"
        f"      .expect(and {{\n{finals}\n      }})\n")
    out.append("".join(body))
    out.append("}\n")
    return "".join(out)


ALLOWLIST_MODULE = '''\
/// The v1 modeled-effect allowlist (docs/trace-conformance.md §4) — the model
/// side of the shared effect vocabulary, in ONE place. Both halves of the
/// projection are maintained in scripts/gen-conformance.py (the golden-side
/// half runs at generation time; this module is emitted from the same file).
///
/// Canonical v1 vocabulary and both mappings:
///
///   canonical             model side                golden side
///   --------------------  ------------------------  --------------------------
///   SquashMerge           SquashMerge               SquashMerge | AdvanceDefault
///   DeleteBranch          DeleteBranch              DeleteBranch job/<n>
///   HumanEscalationTask   CreateEscalationTask,     PutTask Human(escalation)
///                         CreateHumanTask
///
/// `AdvanceDefault` (gated landings promote the squash candidate by
/// fast-forwarding default, emitting no literal SquashMerge) maps to canonical
/// SquashMerge = "the job's work was promoted into the default branch" — a
/// delta from the design doc recorded in docs/trace-conformance.md.
/// Everything else is projected away: each filtered effect is a claim the v1
/// model does not yet make (the honesty boundary; v2–v4 shrink it).
module conformance_allowlist {
  pure def modeledEffects(effects: List[str]): List[str] =
    effects.foldl([], (acc, e) =>
      if (e == "SquashMerge" or e == "DeleteBranch")
        acc.append(e)
      else if (e == "CreateEscalationTask" or e == "CreateHumanTask")
        acc.append("HumanEscalationTask")
      else acc)
}
'''


def git_out(repo: Path, *args) -> str:
    return subprocess.run(["git", "-C", str(repo), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chuggernaut", required=True, type=Path,
                    help="path to a chuggernaut checkout (read-only; YAMLs read at runtime)")
    ap.add_argument("--out", required=True, type=Path,
                    help="output directory for the generated .qnt modules")
    args = ap.parse_args()

    traces_dir = args.chuggernaut / TRACES_SUBDIR
    if not traces_dir.is_dir():
        print(f"error: {traces_dir} not found — not a chuggernaut checkout?", file=sys.stderr)
        return 2

    try:
        commit = git_out(args.chuggernaut, "rev-parse", "--short=7", "HEAD")
    except subprocess.CalledProcessError:
        print("error: cannot resolve upstream commit (checkout is not a git repo?)",
              file=sys.stderr)
        return 2
    try:
        upstream_url = git_out(args.chuggernaut, "remote", "get-url", "origin")
    except subprocess.CalledProcessError:
        upstream_url = UPSTREAM_URL_FALLBACK

    fixtures = sorted(p.stem for p in traces_dir.glob("*.yaml"))
    unknown = [f for f in fixtures if f not in SCENARIOS and f not in SKIPPED]
    if unknown:
        print(f"error: unclassified fixtures {unknown} — audit them "
              f"(docs/trace-conformance.md §2.2) and add to SCENARIOS or SKIPPED",
              file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    header = provenance_header(upstream_url, commit,
                               f"{TRACES_SUBDIR}/*.yaml (shared by every conformance module)")
    (args.out / "conformance_allowlist.qnt").write_text(header + ALLOWLIST_MODULE)
    print("generated: conformance_allowlist.qnt (the §4 allowlist, model side)")

    for name in fixtures:
        if name in SKIPPED:
            print(f"skipped:   {name}.yaml — gated on {SKIPPED[name]}")
            continue
        scen = {**DEFAULTS, **SCENARIOS[name]}
        try:
            ydata = yaml.safe_load((traces_dir / f"{name}.yaml").read_text())
            plan = align(name, ydata, scen)
            emitted, final_states = simulate(name, scen, plan)
        except GenError as e:
            print(f"error: {name}.yaml: {e}", file=sys.stderr)
            return 1
        text = emit_fixture(name, scen, plan, emitted, final_states, upstream_url, commit)
        fname = f"conformance_{name}_test.qnt"
        (args.out / fname).write_text(text)
        n_aligned = sum(1 for s in emitted if s["kind"] == "aligned")
        n_driver = len(emitted) - n_aligned
        n_fx = sum(len(s["golden_effects"]) for s in emitted if s["kind"] == "aligned")
        partial = " [PARTIAL: v1 skeleton]" if "partial" in scen else ""
        print(f"generated: {fname} ({n_aligned} aligned + {n_driver} driver steps; "
              f"{n_aligned} transitions asserted; {n_fx} modeled effects){partial}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
