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
    find specs/chuggernaut/tests/conformance -name '*.qnt' | sort | xargs -rn1 npx quint typecheck

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

# Regenerate the committed trace-replay conformance tests (check.sh Stage 7)
# from a chuggernaut checkout — env CHUGGERNAUT_DIR, defaulting to the dev
# checkout path Stage 7 also probes. The output is deterministic; Stage 7's
# drift guard fails if the committed files differ from a regeneration.
conformance-gen:
    python3 scripts/gen-conformance.py --chuggernaut "${CHUGGERNAUT_DIR:-/tmp/claude-1000/-home-geoff-claude-p/5d6f43fd-980a-4cc1-9c8d-a9824d42c9dc/scratchpad/chuggernaut}" --out specs/chuggernaut/tests/conformance/

# Run only the trace-replay conformance tests (the quint half of Stage 7).
conformance:
    find specs/chuggernaut/tests/conformance -name 'conformance_*_test.qnt' | sort | xargs -rn1 npx quint test

# Generation direction (docs/trace-conformance.md §3): produce the two seeded,
# witness-targeted candidate golden traces under traces/candidates/ (gitignored
# working output) — ITF emitted by expected-fail simulator runs at pinned
# seeds, projected to golden-schema YAML by scripts/itf-to-golden.py and
# round-trip verified. The committed copies live in docs/examples/; check.sh
# Stage 8 regenerates and diffs them.
itf-golden:
    bash scripts/gen-candidates.sh

# Chuggy-model PRs 1-2 (docs/chuggy-charter.md; specs/chuggy/): typecheck +
# unit tests + invariant simulation on all three instances (both GatePricing
# branches + RetryFree). PR 2's authoring lifecycle rides the same runs:
# the fleet starts empty, jobs arrive as Drafts, and allInvariants now
# includes the revoke-cascade gate (revokedNeverLands, cascadeSafety).
# This is check.sh Stage 9 minus its two expected-violation witnesses
# (free-retry climb, cascade park), which need bash logic — run
# `just check` for the full gate.
chuggy:
    npx quint typecheck specs/chuggy/measure.qnt
    npx quint typecheck specs/chuggy/domain.qnt
    npx quint typecheck specs/chuggy/mc/mc_chuggy.qnt
    npx quint typecheck specs/chuggy/tests/chuggy_test.qnt
    npx quint test specs/chuggy/tests/chuggy_test.qnt
    npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted --invariant=allInvariants --max-samples=2000 --max-steps=40
    npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_deadline_only --invariant=allInvariants --max-samples=2000 --max-steps=40
    npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_retryfree --invariant=allInvariants --max-samples=2000 --max-steps=40

# Full check pipeline (what CI runs), Stages 1-9.
check:
    bash scripts/check.sh
