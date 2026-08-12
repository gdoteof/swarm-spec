"""The v1 modeled-effect vocabulary (docs/trace-conformance.md §4) — one home.

Both conformance directions import this module, so the allowlist can never
fork:

- **Replay** (scripts/gen-conformance.py, golden -> model): projects a golden
  fixture's effect stream through `classify_golden_effect` before baking it
  into the generated `.expect` assertions.
- **Generation** (scripts/itf-to-golden.py, model -> golden candidates):
  spells a model effect the way chuggernaut's golden traces record it via
  `model_to_golden`, and its `--roundtrip` check compares the two sides in
  the canonical alphabet (`model_canonical` vs `classify_golden_effect`).

The canonical v1 alphabet and both mappings (the §4 table):

    canonical             model side                golden side
    --------------------  ------------------------  --------------------------
    SquashMerge           SquashMerge               SquashMerge | AdvanceDefault
    DeleteBranch          DeleteBranch              DeleteBranch job/<n>
    HumanEscalationTask   CreateEscalationTask,     PutTask Human(escalation)
                          CreateHumanTask

Everything else is projected away before comparison — each filtered effect is
a claim the v1 model does not yet make (the honesty boundary; v2-v4 shrink
it). Faithfulness rule (docs/trace-conformance.md §4): an effect string
neither in the vocabulary nor in the explicit known-unmodeled tables raises
VocabError — nothing is silently dropped. New vocabulary on either side must
be classified by a human.

The generated Quint module conformance_allowlist.qnt (the model-side half the
replay tests execute) is emitted from ALLOWLIST_MODULE below; its text is
kept byte-stable so the committed Stage 7 tests never drift on a pure
refactor (the emitted prose still names gen-conformance.py, the script that
emits it).
"""

import re


class VocabError(RuntimeError):
    """Unknown effect vocabulary — must be classified by a human."""


# --------------------------------------------------------------------------
# Golden side (chuggernaut's fixture spellings) -> canonical.
# --------------------------------------------------------------------------

# Golden effects outside the v1 modeled vocabulary: projected away before
# comparison. Explicitly enumerated so an unknown effect string fails
# classification instead of being silently dropped.
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
    """Golden-side half of the §4 allowlist projection (canonical name or None).

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


def classify_golden_effect(effect: str):
    """Return the canonical name, or None for a known-unmodeled golden effect.

    Raises VocabError on vocabulary these tables have never seen — the
    faithfulness rule: unknown effects must be classified by a human, not
    dropped.
    """
    canon = golden_canonical(effect)
    if canon is not None:
        return canon
    if effect in UNMODELED_GOLDEN_EXACT:
        return None
    for pat in UNMODELED_GOLDEN_PATTERNS:
        if pat.fullmatch(effect):
            return None
    raise VocabError(f"unclassified golden effect {effect!r} — extend the allowlist tables")


# --------------------------------------------------------------------------
# Model side (the effect strings decide.qnt emits) -> canonical, and
# -> golden spelling (the generation direction's normalization, §3).
# --------------------------------------------------------------------------

MODEL_TO_CANONICAL = {
    "SquashMerge": "SquashMerge",
    "DeleteBranch": "DeleteBranch",
    "CreateEscalationTask": "HumanEscalationTask",  # ->Escalated
    "CreateHumanTask": "HumanEscalationTask",       # ->Stalled
}

# Model-only effects below or beside the goldens' grain (§4): the impl logs
# these only as PublishEvent task-created/task-launched (or not at all).
UNMODELED_MODEL = {
    "CreateWorkTask",        # impl grain: PublishEvent task-created
    "LaunchContainer",       # impl grain: PublishEvent task-launched
    "FanOutEvaluators",      # v2 staged-eval grain
    "EnqueueMergeCandidate", # v3 merge-queue grain
}


def model_canonical(effect: str):
    """Model-side half of the §4 projection: canonical name, or None for a
    known-unmodeled model effect. The Python mirror of the generated Quint
    `modeledEffects` (conformance_allowlist.qnt). Raises VocabError on an
    effect string decide.qnt does not emit today.
    """
    if effect in MODEL_TO_CANONICAL:
        return MODEL_TO_CANONICAL[effect]
    if effect in UNMODELED_MODEL:
        return None
    raise VocabError(f"unclassified model effect {effect!r} — extend the allowlist tables")


def model_to_golden(effect: str, job: int):
    """Spell a model effect the way chuggernaut's golden traces record it
    (docs/trace-conformance.md §3), or None for a known-unmodeled model
    effect (dropped from candidates: outside the shared vocabulary).

    `job` parameterizes the branch-scoped golden spelling (DeleteBranch
    job/<n>). Note the deliberate asymmetry with `golden_canonical`: a gated
    landing would record AdvanceDefault, but v1 cannot see gates, so
    candidates always spell promotion "SquashMerge" — a consumer must compare
    through the canonical alphabet, where the two collapse (§4).
    """
    if effect == "SquashMerge":
        return "SquashMerge"
    if effect == "DeleteBranch":
        return f"DeleteBranch job/{job}"
    if effect in ("CreateEscalationTask", "CreateHumanTask"):
        return "PutTask Human(escalation)"
    if effect in UNMODELED_MODEL:
        return None
    raise VocabError(f"unclassified model effect {effect!r} — extend the allowlist tables")


# The 12 JobState constructor names — spelled exactly as chuggernaut's Rust
# enum (crates/types/src/job.rs) and the model's types.qnt spell them, by
# design, so an ITF `tag` IS the golden YAML state name. Used as a decoding
# guard by scripts/itf-to-golden.py.
JOB_STATES = frozenset({
    "Draft", "Frozen", "Batched", "Blocked", "Ready", "Work",
    "Evaluation", "WrapUp", "Escalated", "Stalled", "Done", "Revoked",
})


# --------------------------------------------------------------------------
# The model-side allowlist as executed by the Stage 7 replay tests: emitted
# verbatim into specs/chuggernaut/tests/conformance/conformance_allowlist.qnt
# by scripts/gen-conformance.py. Byte-stable — see the module docstring.
# --------------------------------------------------------------------------

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
