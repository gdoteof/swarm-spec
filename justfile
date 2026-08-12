# Thin wrappers; scripts/check.sh is the real logic.

# Typecheck every spec file.
typecheck:
    npx quint typecheck specs/chuggernaut/types.qnt
    npx quint typecheck specs/chuggernaut/table.qnt
    npx quint typecheck specs/chuggernaut/decide.qnt
    npx quint typecheck specs/chuggernaut/machine.qnt
    npx quint typecheck specs/chuggernaut/mc/mc_small.qnt
    npx quint typecheck specs/chuggernaut/mc/mc_liveness.qnt
    npx quint typecheck specs/chuggernaut/mc/mc_livelock.qnt
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

# Deeper Apalache pass over the PR4 liveness layer: the quiescent-descent
# invariant exhaustively to depth 6 (~2.5 min measured; check.sh Stage 6
# runs the same check at depth 4 in ~17s, plus the fast randomized and
# expected-fail livelock checks). mc_livelock is Apalache-intractable
# (DEADLINE=1000 pushed even depth 4 past 10 minutes), so its coverage is
# Stage 6's randomized run. `quint verify --temporal` itself is broken in
# this toolchain — see the Stage 6 header in scripts/check.sh.
verify-liveness:
    JVM_ARGS=-Xmx4G npx quint verify specs/chuggernaut/mc/mc_liveness.qnt --main=mc_liveness --invariant=quiescentDescent --max-steps=6

# Emit a sample ITF trace to traces/sample.itf.json (gitignored). Each ITF
# state snapshots every var, including lastStep {label, transitions,
# effects} — the input to the ITF->golden-YAML projection described in
# docs/trace-conformance.md §3.
itf:
    npx quint run specs/chuggernaut/mc/mc_small.qnt --main=mc_small --max-samples=1 --max-steps=25 --out-itf=traces/sample.itf.json

# Full check pipeline (what CI runs).
check:
    bash scripts/check.sh
