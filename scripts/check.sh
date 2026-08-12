#!/usr/bin/env bash
# Full check pipeline for swarm-spec. Later PRs append stages here.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Stage 1: typecheck (all .qnt under specs/) ==="
find specs -name '*.qnt' | sort | while read -r f; do
  echo "--- typecheck $f"
  npx quint typecheck "$f"
done

echo
echo "=== Stage 2: unit tests ==="
npx quint test specs/chuggernaut/tests/table_test.qnt

echo
echo "=== Stage 3: simulation smoke (mc_small) ==="
npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small \
  --max-samples=500 --max-steps=40

echo
echo "=== Stage 4: randomized invariant + witness checking (mc_small) ==="
npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small \
  --invariant=allInvariants --max-samples=2000 --max-steps=40

# Anti-vacuity: every witness must be hit at least once, else the green
# invariant run above is checked against traces that never exercise the
# behavior it claims to cover. witnessGateReworkTwice needs one job to draw
# LConflictOrGateFail twice before quiesce, which random exploration hits
# only ~1 in 5000 traces — so this run uses 50k samples (still ~1.5s on the
# rust backend) plus a pinned seed, which the rust backend reproduces
# exactly, to keep CI deterministic. Counts only need to be nonzero.
WITNESSES="witnessAllDone witnessGateReworkTwice witnessEscalatedRecovered witnessBlockedUnblocks"
witness_out=$(npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small \
  --witnesses $WITNESSES \
  --max-samples=50000 --max-steps=40 --seed=0xa4f58f7b0cc29183)
echo "$witness_out" | grep -E 'witnessed|\[ok\]'
for w in $WITNESSES; do
  hits=$(echo "$witness_out" | awk -v w="$w" '$1 == w && $3 == "witnessed" {print $5}')
  if [ -z "${hits:-}" ] || [ "$hits" -eq 0 ]; then
    echo "FAIL: witness $w was never hit (vacuous invariant coverage)" >&2
    exit 1
  fi
done
echo "All witnesses hit."

echo
echo "=== Stage 5: Apalache bounded model checking (mc_small) ==="
# Exhaustive over ALL nondet choices (unlike Stage 4's random sampling) for
# every state reachable in <= 4 steps — enough for a complete single-job
# lifecycle (dispatch -> work -> eval -> land = Done) and for reaching every
# decider, including escalation + operator retry. The bound is 4 because
# solver time explodes with depth on this instance (measured, warm
# Apalache: 3 -> 18s, 4 -> 47s, 5 -> 5m16s, 6 -> >10min); Stage 4's random
# simulation covers depth 40. The first run downloads Apalache to ~/.quint.
JVM_ARGS=-Xmx4G npx quint verify specs/chuggernaut/mc/mc_small.qnt \
  --main=mc_small --invariant=allInvariants --max-steps=4

echo
echo "=== All checks passed ==="
