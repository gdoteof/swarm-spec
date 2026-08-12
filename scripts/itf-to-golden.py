#!/usr/bin/env python3
"""Project a Quint ITF trace into a CANDIDATE golden-trace YAML.

The generation direction of docs/trace-conformance.md §3: the model's ghost
variable `lastStep` records every applied decision as a StepRecord {label,
transitions, effects} shaped like one step of chuggernaut's golden-trace YAML
schema, so a simulator run *is already* a golden-shaped trace — this script
only decodes the ITF value encoding and normalizes the effect vocabulary.

Per projected step:
  event:       the model's decision label, prefixed "model:" so candidates
               are always distinguishable from hand-written golden fixtures
               (whose event strings are author prose).
  transitions: decoded verbatim — JobState constructor names match
               chuggernaut's Rust enum exactly (types.qnt, by design), so the
               ITF `tag` IS the golden YAML state name.
  effects:     model effects spelled in the golden vocabulary through the
               shared v1 allowlist (scripts/conformance_vocab.py — the same
               tables the Stage 7 replay generator uses); effects outside the
               modeled vocabulary are omitted.

Skip-vs-emit policy: steps labeled `init`, `noop-settle`, or `quiesce` are
SKIPPED — they are model bookkeeping (the initial snapshot, the settled/
wedged stutter, and the one-way environment-goes-quiet switch) with no
observable decision and no implementation counterpart in the golden schema.
Skipping is checked, not assumed: a skipped step must carry no transitions
and no modeled effects, else this script errors (the projection must be
loss-free w.r.t. the modeled vocabulary).

--roundtrip re-parses the emitted YAML and verifies it against the ITF's
lastStep sequence step-for-step: transitions exact (and every state name a
known JobState spelling), events exact, and the effect sequences equal in the
canonical §4 alphabet — the YAML side re-read through the REPLAY direction's
golden-effect classifier, the ITF side through the model-side allowlist. The
two classifiers are independent tables, so a projection bug on either side
(or an ITF decoding bug) breaks the equation. This proves the candidate is a
faithful, loss-free image of the model trace at the modeled grain — it does
NOT execute the candidate against chuggernaut (that is the upstream half,
docs/trace-conformance.md §3.4).

Faithfulness rule (§4): anything unmappable — an unknown ITF value encoding,
a non-unit variant, an unknown step label or effect string, a decision with
other than exactly one transition — is a hard error, never silently bent.

Usage:
  python3 scripts/itf-to-golden.py TRACE.itf.json --out CANDIDATE.yaml \
      [--roundtrip] [--note "provenance line"]...
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

import conformance_vocab as vocab

# Model bookkeeping labels: no observable decision, skipped by projection
# (see the module docstring for the rationale; skipping is loss-checked).
SKIP_LABELS = {"init", "noop-settle", "quiesce"}

# Every label decide.qnt/machine.qnt can record in lastStep today. An unknown
# label is a hard error: new model vocabulary must be classified here (emit or
# skip) by a human. "operator-retry-unreachable" (decide.qnt's defensive
# match-totalizer) is deliberately absent — it can never be applied, so its
# appearance in a trace is a model bug worth failing on.
EMIT_LABELS = {
    "dispatch",
    "work-succeeded",
    "work-retry",
    "eval-passed",
    "job-done",
    "job-rework-started eval_failure",
    "job-rework-started merge_gate_failure",
    "job-escalated work_retries_exhausted",
    "job-escalated rework_budget_exhausted",
    "job-escalated job_deadline_exceeded",
    "job-unblocked",
    "job-stalled revalidation_failed",
    "operator-retry",
    "stalled-retry",
    "stalled-retry-failed",
}


class ItfError(RuntimeError):
    pass


# --------------------------------------------------------------------------
# ITF value decoding (apalache ADR-015, as quint emits it)
# --------------------------------------------------------------------------

def decode(v):
    """Decode one ITF value into plain Python.

    Sum constructors {tag, value} decode to the bare tag string — v1 has only
    unit-payload variants (JobState/Phase), so a non-unit payload is an error,
    not a guess. #set decodes to a sorted list when orderable (ITF set order
    is arbitrary; sorting makes projection deterministic), #map to a dict.
    """
    if isinstance(v, dict):
        if "#bigint" in v:
            return int(v["#bigint"])
        if "#map" in v:
            return {decode(k): decode(x) for k, x in v["#map"]}
        if "#set" in v:
            items = [decode(x) for x in v["#set"]]
            try:
                return sorted(items)
            except TypeError:
                return items
        if "#tup" in v:
            return tuple(decode(x) for x in v["#tup"])
        if "tag" in v:
            payload = decode(v.get("value", {"#tup": []}))
            if payload != ():
                raise ItfError(
                    f"variant {v['tag']!r} carries a non-unit payload {payload!r} — "
                    f"v1 has none; classify the new encoding")
            return v["tag"]
        if "#unserializable" in v:
            raise ItfError(f"unserializable ITF value: {v['#unserializable']!r}")
        return {k: decode(x) for k, x in v.items() if k != "#meta"}
    if isinstance(v, list):
        return [decode(x) for x in v]
    if isinstance(v, (bool, int, str)):
        return v
    raise ItfError(f"undecodable ITF value {v!r}")


def var_key(itf: dict, name: str) -> str:
    """Find a state variable by suffix match on the qualified name (instance
    prefixes vary by --main: e.g. mc_small::chug_machine::lastStep)."""
    hits = [v for v in itf.get("vars", []) if v == name or v.endswith("::" + name)]
    if len(hits) != 1:
        raise ItfError(f"expected exactly one {name!r} var, found {hits}")
    return hits[0]


def load_trace(path: Path):
    """Load an ITF file into (meta info, init snapshot, decoded step records)."""
    itf = json.loads(path.read_text())
    states = itf.get("states")
    if not isinstance(states, list) or not states:
        raise ItfError("ITF file has no states")
    last_key = var_key(itf, "lastStep")
    jobs_key = var_key(itf, "jobs")
    readyq_key = var_key(itf, "readyQ")

    records = []
    for pos, state in enumerate(states):
        idx = state.get("#meta", {}).get("index")
        if idx is not None and idx != pos:
            raise ItfError(f"ITF state order broken: position {pos} has index {idx}")
        rec = decode(state[last_key])
        for field in ("label", "transitions", "effects"):
            if field not in rec:
                raise ItfError(f"state {pos}: lastStep lacks {field!r}: {rec}")
        for t in rec["transitions"]:
            for f in ("job", "from", "to"):
                if f not in t:
                    raise ItfError(f"state {pos}: transition lacks {f!r}: {t}")
            if not isinstance(t["job"], int):
                raise ItfError(f"state {pos}: non-int job id {t['job']!r}")
            for f in ("from", "to"):
                if t[f] not in vocab.JOB_STATES:
                    raise ItfError(
                        f"state {pos}: {t[f]!r} is not a JobState spelling "
                        f"(chuggernaut Rust enum) — decoding bug or new vocabulary")
        records.append(rec)

    if records[0]["label"] != "init" or records[0]["transitions"] or records[0]["effects"]:
        raise ItfError(f"state 0 is not the init record: {records[0]}")

    init_jobs = decode(states[0][jobs_key])
    init_readyq = decode(states[0][readyq_key])
    source = itf.get("#meta", {}).get("source", str(path))
    return source, init_jobs, init_readyq, records


# --------------------------------------------------------------------------
# Projection
# --------------------------------------------------------------------------

def check_skippable(pos: int, rec: dict):
    """A skipped step must lose nothing modeled (transitions are all modeled;
    effects are checked through the model-side allowlist)."""
    if rec["transitions"]:
        raise ItfError(
            f"state {pos}: label {rec['label']!r} is skip-listed but carries "
            f"transitions {rec['transitions']} — projection would lose them")
    lost = [e for e in rec["effects"] if vocab.model_canonical(e) is not None]
    if lost:
        raise ItfError(
            f"state {pos}: label {rec['label']!r} is skip-listed but carries "
            f"modeled effects {lost} — projection would lose them")


def project_steps(records):
    """ITF step records -> (golden-schema step dicts, skipped-label counts)."""
    steps = []
    skipped = {}
    for pos, rec in enumerate(records):
        if pos == 0 or rec["label"] in SKIP_LABELS:
            check_skippable(pos, rec)
            skipped[rec["label"]] = skipped.get(rec["label"], 0) + 1
            continue
        if rec["label"] not in EMIT_LABELS:
            raise ItfError(
                f"state {pos}: unknown step label {rec['label']!r} — classify it "
                f"as emit or skip in scripts/itf-to-golden.py")
        if len(rec["transitions"]) != 1:
            raise ItfError(
                f"state {pos}: {rec['label']!r} records {len(rec['transitions'])} "
                f"transitions — v1 decisions carry exactly one")
        t = rec["transitions"][0]
        effects = [g for g in
                   (vocab.model_to_golden(e, t["job"]) for e in rec["effects"])
                   if g is not None]
        steps.append({
            "event": f"model:{rec['label']}",
            "transitions": [{"job": t["job"], "from": t["from"], "to": t["to"]}],
            "effects": effects,
        })
    return steps, skipped


def header_lines(source: str, init_jobs: dict, init_readyq: list,
                 n_states: int, n_steps: int, skipped: dict, notes) -> list:
    lines = [
        "CANDIDATE golden trace — GENERATED from the swarm-spec Quint model by",
        "  python3 scripts/itf-to-golden.py <trace.itf.json> --out <this file>",
        "NOT a recorded chuggernaut trace: model output projected into the golden",
        "YAML schema (swarm-spec docs/trace-conformance.md §3) for a",
        "golden_traces.rs-style harness to execute.",
        f"Source: {source} ({n_states} ITF states -> {n_steps} steps; skipped "
        + ", ".join(f"{k} x{v}" for k, v in sorted(skipped.items()))
        + " — model bookkeeping, no observable decision).",
    ]
    lines += list(notes)
    lines.append("Scenario init (ITF state 0) — the job graph the harness must set up:")
    for j in sorted(init_jobs):
        jb = init_jobs[j]
        deps = ", ".join(str(d) for d in jb["deps"]) or "none"
        lines.append(
            f"  job {j}: {jb['state']}, deps: {deps}, deadline gas {jb['deadlineLeft']}")
    lines.append(f"  initial ready queue: {init_readyq}")
    lines += [
        'Events are model decision labels prefixed "model:" (machine provenance;',
        "golden fixtures carry author prose there). Effects are spelled in the",
        "golden vocabulary through the v1 allowlist (swarm-spec",
        "scripts/conformance_vocab.py); effects outside it are omitted, so a",
        "recorded implementation trace must be compared through the same",
        "allowlist projection.",
    ]
    return lines


def render(source, init_jobs, init_readyq, records, notes) -> str:
    steps, skipped = project_steps(records)
    if not steps:
        raise ItfError("projection produced no steps — nothing to emit")
    head = "".join(f"# {l}\n" for l in header_lines(
        source, init_jobs, init_readyq, len(records), len(steps), skipped, notes))
    body = yaml.safe_dump({"steps": steps}, default_flow_style=False,
                          sort_keys=False, width=100)
    return head + body


# --------------------------------------------------------------------------
# Round-trip verification (see the module docstring)
# --------------------------------------------------------------------------

def roundtrip(records, yaml_text: str):
    """Verify the emitted YAML is a loss-free image of the ITF step sequence
    at the modeled grain. Returns (n emitted, n skipped, n canonical effects)."""
    doc = yaml.safe_load(yaml_text)
    steps = list(doc["steps"])
    pos_steps = 0
    n_skip = 0
    n_fx = 0
    for pos, rec in enumerate(records):
        if pos == 0 or rec["label"] in SKIP_LABELS:
            check_skippable(pos, rec)  # loss-freeness of the skip
            n_skip += 1
            continue
        if pos_steps >= len(steps):
            raise ItfError(f"state {pos}: ITF has more decisions than the YAML has steps")
        step = steps[pos_steps]
        pos_steps += 1
        where = f"state {pos} / YAML step {pos_steps}"

        if step["event"] != f"model:{rec['label']}":
            raise ItfError(f"{where}: event {step['event']!r} != model:{rec['label']}")
        got = [{"job": t["job"], "from": t["from"], "to": t["to"]}
               for t in rec["transitions"]]
        if step["transitions"] != got:
            raise ItfError(
                f"{where}: transitions {step['transitions']} != ITF {got}")

        # Effects, compared in the canonical §4 alphabet: the YAML side
        # re-read through the REPLAY direction's golden classifier, the ITF
        # side through the model-side allowlist — two independent tables.
        yaml_canon = []
        for e in step["effects"]:
            c = vocab.classify_golden_effect(e)  # raises on unknown vocabulary
            if c is None:
                raise ItfError(
                    f"{where}: candidate carries {e!r}, which the golden-side "
                    f"classifier files as unmodeled — the projection emitted junk")
            yaml_canon.append(c)
            m = re.fullmatch(r"DeleteBranch job/(\d+)", e)
            if m and int(m.group(1)) != rec["transitions"][0]["job"]:
                raise ItfError(
                    f"{where}: {e!r} names job {m.group(1)} but the step's "
                    f"transition is job {rec['transitions'][0]['job']}")
        itf_canon = [c for c in (vocab.model_canonical(e) for e in rec["effects"])
                     if c is not None]
        if yaml_canon != itf_canon:
            raise ItfError(
                f"{where}: canonical effects diverge: YAML {yaml_canon} != "
                f"ITF {itf_canon}")
        n_fx += len(itf_canon)
    if pos_steps != len(steps):
        raise ItfError(
            f"YAML has {len(steps) - pos_steps} trailing step(s) with no ITF decision")
    return pos_steps, n_skip, n_fx


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("itf", type=Path, help="input ITF trace (quint run --out-itf)")
    ap.add_argument("--out", type=Path,
                    help="write the candidate YAML here (default: stdout)")
    ap.add_argument("--roundtrip", action="store_true",
                    help="verify the projection is loss-free w.r.t. the modeled "
                         "vocabulary (re-parse the YAML and align it against the "
                         "ITF step sequence)")
    ap.add_argument("--note", action="append", default=[],
                    help="extra provenance line for the header (repeatable; use "
                         "for the exact seeded command that produced the ITF)")
    args = ap.parse_args()

    try:
        source, init_jobs, init_readyq, records = load_trace(args.itf)
        text = render(source, init_jobs, init_readyq, records, args.note)
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(text)
            n_steps = sum(1 for line in text.splitlines() if line.startswith("- event:"))
            print(f"wrote {args.out} ({n_steps} steps from {len(records)} ITF states)")
        elif not args.roundtrip:
            sys.stdout.write(text)
        if args.roundtrip:
            n_steps, n_skip, n_fx = roundtrip(records, text)
            print(f"round-trip OK: {args.itf} -> {n_steps} steps "
                  f"({n_skip} bookkeeping states skipped loss-free, "
                  f"{n_fx} canonical effects compared, transitions exact)")
    except (ItfError, vocab.VocabError) as e:
        print(f"error: {args.itf}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
