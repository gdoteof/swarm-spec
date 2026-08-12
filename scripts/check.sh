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
echo "=== All checks passed ==="
