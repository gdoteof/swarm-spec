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
echo "=== All checks passed ==="
