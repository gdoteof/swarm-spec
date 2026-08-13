#!/usr/bin/env bash
# Generate the two seeded candidate golden traces (the generation direction of
# docs/trace-conformance.md §3) into $1 (default: traces/candidates, which is
# gitignored working output). Each candidate is produced by a seed-pinned,
# witness-targeted simulator run — the negated-witness / expected-violation
# trick: ask the simulator to "violate" the property that is exactly the
# interesting behavior, so the ITF counterexample it dumps IS the trace that
# exhibits it (the rust backend reproduces seeds exactly, so this is
# deterministic) — then projected to golden-schema YAML and round-trip
# verified by scripts/itf-to-golden.py.
#
# The committed examples under docs/examples/ are these exact files;
# scripts/check.sh Stage 8 regenerates and diffs them (drift guard).
set -euo pipefail
cd "$(dirname "$0")/.."

outdir="${1:-traces/candidates}"
mkdir -p "$outdir"

# --- candidate 1: clean lifecycle -----------------------------------------
# mc_small (3 jobs, 2 agents, WORK_RETRIES=1, REWORK_BUDGET=1, DEADLINE=3).
# Target: every job Done INCLUDING a Blocked->Ready dep unblock, near-minimal
# depth (14) — the golden-shaped happy path work_eval_merge_no_gate +
# release_block_unblock cover, as one machine-generated scenario.
seed_clean=0x37a1792d8159488
if npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small \
    --invariant='not(witnessAllDone and witnessBlockedUnblocks)' \
    --max-samples=50000 --max-steps=14 --seed="$seed_clean" --backend=rust \
    --out-itf="$outdir/candidate_clean_lifecycle.itf.json" >/dev/null 2>&1; then
  echo "FAIL: clean-lifecycle target not reached at seed $seed_clean —" >&2
  echo "      the pinned-seed trace no longer reproduces (model changed?)" >&2
  exit 1
fi
python3 scripts/itf-to-golden.py "$outdir/candidate_clean_lifecycle.itf.json" \
  --out "$outdir/candidate_clean_lifecycle.yaml" --roundtrip \
  --note "Scenario: clean lifecycle — all 3 jobs land (Ready->Work->Evaluation->WrapUp->Done)," \
  --note "including job 2 unblocking (Blocked->Ready) after its dep lands. mc_small instance:" \
  --note "WORK_RETRIES=1, REWORK_BUDGET=1, DEADLINE=3, 2 agents." \
  --note "Regenerate: bash scripts/gen-candidates.sh  (seed ${seed_clean}, expected-fail of" \
  --note "not(witnessAllDone and witnessBlockedUnblocks) on mc_small, depth 14, rust backend)."

# --- candidate 2: the budget-free gate-rework loop ------------------------
# mc_livelock (DEADLINE=1000 ~ no job_deadline set; WORK_RETRIES=1,
# REWORK_BUDGET=1) at check.sh Stage 6a's pinned seed: the documented
# spec.md:1269 livelock — one job takes 3 merge_gate_failure reworks
# (> every budget combined) with rework_budget untouched. No golden fixture
# exhibits this; it is exactly what the generation direction exists to hand
# upstream.
seed_gate=0xa5110d572bfbd1d5
if npx quint run specs/chuggernaut/mc/mc_livelock.qnt --main=mc_livelock \
    --invariant=gateReworksWithinBudgets \
    --max-samples=200000 --max-steps=40 --seed="$seed_gate" --backend=rust \
    --out-itf="$outdir/candidate_gate_rework_loop.itf.json" >/dev/null 2>&1; then
  echo "FAIL: gate-rework-loop violation not reached at seed $seed_gate —" >&2
  echo "      the pinned-seed trace no longer reproduces (model changed?)" >&2
  exit 1
fi
python3 scripts/itf-to-golden.py "$outdir/candidate_gate_rework_loop.itf.json" \
  --out "$outdir/candidate_gate_rework_loop.yaml" --roundtrip \
  --note "Scenario: the budget-free merge-gate rework loop (chuggernaut docs/spec.md par. 3.3" \
  --note "\"Bounding\", line ~1269): job 1 cycles Work->Evaluation->WrapUp->Work on" \
  --note "merge_gate_failure THREE times — more than WORK_RETRIES + REWORK_BUDGET = 2 combined —" \
  --note "with rework_budget untouched (evalReworks stays 1). mc_livelock instance: DEADLINE=1000" \
  --note "models a graph with no job_deadline set, so nothing bounds the loop. No hand-written" \
  --note "golden fixture covers this path." \
  --note "Regenerate: bash scripts/gen-candidates.sh  (seed ${seed_gate}, expected-fail of" \
  --note "gateReworksWithinBudgets on mc_livelock, depth 40, rust backend — the same pinned run" \
  --note "as swarm-spec check.sh Stage 6a)."

echo "candidates in $outdir: candidate_clean_lifecycle.yaml, candidate_gate_rework_loop.yaml"
