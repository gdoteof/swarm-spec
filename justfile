# Thin wrappers; scripts/check.sh is the real logic.

# Typecheck every spec file.
typecheck:
    npx quint typecheck specs/chuggernaut/types.qnt
    npx quint typecheck specs/chuggernaut/table.qnt
    npx quint typecheck specs/chuggernaut/decide.qnt
    npx quint typecheck specs/chuggernaut/machine.qnt
    npx quint typecheck specs/chuggernaut/mc/mc_small.qnt
    npx quint typecheck specs/chuggernaut/tests/table_test.qnt

# Run the Quint unit tests.
test:
    npx quint test specs/chuggernaut/tests/table_test.qnt

# Simulation smoke run (Stage 3 of check).
sim:
    npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small --max-samples=500 --max-steps=40

# Full check pipeline (what CI runs).
check:
    bash scripts/check.sh
