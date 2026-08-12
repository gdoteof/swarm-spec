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

# Apalache bounded model checking alone (Stage 5 of check).
# Depth 4 by measurement: 5 takes ~5min and 6 >10min (see scripts/check.sh).
verify:
    JVM_ARGS=-Xmx4G npx quint verify specs/chuggernaut/mc/mc_small.qnt --main=mc_small --invariant=allInvariants --max-steps=4

# Full check pipeline (what CI runs).
check:
    bash scripts/check.sh
