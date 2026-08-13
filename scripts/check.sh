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
# quint verify exits 0 even when the Apalache JVM dies mid-check (observed:
# native Z3 SIGSEGV during Step 1 transition exploration left no verdict at
# all, exit code 0 — the same false-success behavior Stage 6 already guards
# against for --temporal). So the exit code is not trusted: the stage passes
# only on an explicit "[ok] No violation found" verdict. The SIGSEGV is
# intermittent (a libz3 instability, not model-dependent), so the stage
# retries up to 3 attempts; a genuine invariant violation ("[violation]")
# fails immediately without retry.
verify_ok=""
for attempt in 1 2 3; do
  verify_out=$(JVM_ARGS=-Xmx4G npx quint verify specs/chuggernaut/mc/mc_small.qnt \
    --main=mc_small --invariant=allInvariants --max-steps=4 2>&1) || true
  if echo "$verify_out" | grep -q '\[ok\] No violation found'; then
    echo "$verify_out" | grep '\[ok\] No violation found'
    verify_ok=yes
    break
  fi
  if echo "$verify_out" | grep -q '\[violation\]'; then
    echo "$verify_out" | tail -30 >&2
    echo "FAIL: quint verify found an invariant violation" >&2
    exit 1
  fi
  echo "Stage 5 attempt $attempt: no verdict (JVM/Z3 crash?) — retrying" >&2
done
if [ -z "$verify_ok" ]; then
  echo "$verify_out" | tail -20 >&2
  echo "FAIL: quint verify produced no explicit success verdict in 3 attempts" >&2
  exit 1
fi
rm -f hs_err_pid*.log core.* 2>/dev/null || true

echo
echo "=== Stage 6: liveness (quiescent termination + documented-livelock reproduction) ==="
# Temporal-checker status (measured on this repo, quint 0.32 + Apalache
# 0.56.1): `quint verify --temporal` dies on true and false properties
# alike — Z3 segfaults natively (SIGSEGV in libz3 bool_rewriter) while the
# temporal-rewritten step relation is translated to SMT, surfaced by quint
# as `error: assertion failed`; `--backend=tlc` trips a TLC evaluation bug on
# the compiled init (`ApaFoldSeqLeft`) AND emits INIT/NEXT with no fairness,
# under which TLC's stuttering-closed liveness semantics would refute any
# eventually-property vacuously. So the liveness layer is discharged as
# SAFETY (see the "Temporal (PR4)" section of machine.qnt for the proof
# shape):
#   - the TRUE theorem (quiescentlySettles) via the well-founded descent
#     invariant quiescentDescent — randomized to depth 40 here, Apalache
#     bounded to depth 4 here (17s measured; depth 6 at ~2.5min lives in
#     `just verify-liveness`);
#   - the FALSE claims via machine-checked reachability of their livelock /
#     wedge configurations (the expected-FAIL runs below).

# 6a — THE headline expected-fail. chuggernaut docs/spec.md §3.3 "Bounding"
# (line ~1265): repeated gate failures don't consume rework_budget, so a job
# that genuinely can't integrate loops Work -> Evaluation -> WrapUp (gate)
# -> Work; job_deadline is the only backstop. On mc_livelock (DEADLINE=1000
# ~ no deadline set) this run MUST find a trace where one job takes that
# loop beyond every budget combined (gateReworks = 3 > WORK_RETRIES +
# REWORK_BUDGET = 2) — the documented livelock as a machine-checked trace.
# Seed pinned (rust backend reproduces exactly); found unseeded at roughly
# 1 in 60k traces.
if livelock_out=$(npx quint run specs/chuggernaut/mc/mc_livelock.qnt --main=mc_livelock \
  --invariant=gateReworksWithinBudgets \
  --max-samples=200000 --max-steps=40 --seed=0xa5110d572bfbd1d5 --backend=rust 2>&1); then
  echo "FAIL: gateReworksWithinBudgets unexpectedly HELD on mc_livelock —" >&2
  echo "      the documented budget-free gate loop was not reproduced" >&2
  exit 1
fi
echo "$livelock_out" | grep -q '\[violation\]' || {
  echo "FAIL: mc_livelock run failed for a reason other than the expected violation:" >&2
  echo "$livelock_out" | tail -5 >&2
  exit 1
}
loop_hits=$(echo "$livelock_out" | grep -c 'job-rework-started merge_gate_failure' || true)
if [ "$loop_hits" -lt 3 ]; then
  echo "FAIL: violation trace shows only $loop_hits merge_gate_failure reworks (expected >= 3)" >&2
  exit 1
fi
echo "Livelock reproduced: $loop_hits unbudgeted 'merge_gate_failure' gate reworks of one job"
echo "(> WORK_RETRIES + REWORK_BUDGET = 2) — spec.md:1265 as a machine-checked trace."

# 6b — expected-fail: the wedge. terminationUnderQuiescence (eventually
# settled, over bare allSettled) is FALSE: after an escalation, quiescing
# strands a Blocked dependent forever — allWedged but not allSettled is
# reachable, and in that state noopSettle is the only enabled action. This
# is exactly why the honest theorem (quiescentlySettles) is stated over
# allSettledOrWedged.
if wedge_out=$(npx quint run specs/chuggernaut/mc/mc_liveness.qnt --main=mc_liveness \
  --invariant=wedgeFree \
  --max-samples=50000 --max-steps=40 --seed=0xa70ac2d5a29cd724 --backend=rust 2>&1); then
  echo "FAIL: wedgeFree unexpectedly HELD on mc_liveness — the wedge was not reproduced" >&2
  exit 1
fi
echo "$wedge_out" | grep -q '\[violation\]' || {
  echo "FAIL: mc_liveness wedge run failed for a reason other than the expected violation:" >&2
  echo "$wedge_out" | tail -5 >&2
  exit 1
}
echo "$wedge_out" | grep -q 'state: Blocked' && echo "$wedge_out" | grep -q 'envActive: false' || {
  echo "FAIL: wedge violation trace lacks the Blocked-after-quiesce signature" >&2
  exit 1
}
echo "Wedge reproduced: allWedged-but-not-allSettled is reachable (Blocked job stranded"
echo "behind an Escalated dep after quiesce) — bare eventually(allSettled) is false."

# 6c — the positive theorem, randomized: quiescentDescent (every step but
# the noopSettle stutter and the envActive-gated operator-churn actions
# strictly decreases a nonnegative measure) holds to depth 40 across 20k
# traces on BOTH instances; on mc_liveness the gas backstop also keeps
# gateReworks within budgets (contrast with 6a).
npx quint run specs/chuggernaut/mc/mc_liveness.qnt --main=mc_liveness \
  --invariant='quiescentDescent and gateReworksWithinBudgets' \
  --max-samples=20000 --max-steps=40
npx quint run specs/chuggernaut/mc/mc_livelock.qnt --main=mc_livelock \
  --invariant=quiescentDescent --max-samples=20000 --max-steps=40

# 6d — the positive theorem, exhaustive over all nondet choices to depth 4
# (Apalache, ~17s measured; depth 6 -> 2m24s lives in `just
# verify-liveness`). mc_livelock is Apalache-intractable (DEADLINE=1000
# pushed depth 4 past 10 minutes), so its descent coverage is 6c's
# randomized run. Bounded = evidence at this depth; the unbounded claim
# rests on the delta-table argument in machine.qnt, every line of which
# these checks exercise.
JVM_ARGS=-Xmx4G npx quint verify specs/chuggernaut/mc/mc_liveness.qnt \
  --main=mc_liveness --invariant=quiescentDescent --max-steps=4

echo
echo "=== Stage 7: trace conformance (replay) ==="
# The replay direction of docs/trace-conformance.md: each committed
# conformance_*_test.qnt (generated by scripts/gen-conformance.py from
# chuggernaut's golden traces — provenance in every header, no upstream file
# content vendored) drives the exact decide* calls a golden fixture implies
# and asserts lastStep after every step: transitions + model label exactly,
# effects through the §4 modeled-vocabulary allowlist, allInvariants on every
# step (driver steps included). This half runs from the committed files
# alone — no chuggernaut checkout required.
conf_dir=specs/chuggernaut/tests/conformance
ls "$conf_dir"/conformance_*_test.qnt >/dev/null   # fail loudly if none committed
for f in "$conf_dir"/conformance_*_test.qnt; do
  echo "--- quint test $f"
  npx quint test "$f"
done

# Drift guard: when a chuggernaut checkout IS available (env CHUGGERNAUT_DIR,
# or the dev-machine default path below), regenerate into a temp dir and
# require byte-identical output — the committed tests must never drift from
# the golden fixtures they claim to replay (or from the generator). Without a
# checkout this is skipped; the replay tests above still ran.
CHUG="${CHUGGERNAUT_DIR:-/tmp/claude-1000/-home-geoff-claude-p/5d6f43fd-980a-4cc1-9c8d-a9824d42c9dc/scratchpad/chuggernaut}"
if [ -d "$CHUG/crates/dispatcher/tests/traces" ]; then
  tmp_gen=$(mktemp -d)
  python3 scripts/gen-conformance.py --chuggernaut "$CHUG" --out "$tmp_gen" >/dev/null
  if ! diff -ru "$conf_dir" "$tmp_gen"; then
    rm -rf "$tmp_gen"
    echo "FAIL: committed conformance tests drift from regenerated output" >&2
    echo "      (regenerate: just conformance-gen, then commit the diff)" >&2
    exit 1
  fi
  rm -rf "$tmp_gen"
  echo "Drift guard: committed conformance tests == regenerated from $CHUG"
  echo "             (upstream @ $(git -C "$CHUG" rev-parse --short=7 HEAD))."
else
  echo "Drift guard skipped: no chuggernaut checkout (set CHUGGERNAUT_DIR to enable)."
fi

echo
echo "=== Stage 8: trace conformance (generation round-trip) ==="
# The generation direction of docs/trace-conformance.md §3: seeded,
# witness-targeted simulator runs (the negated-witness / expected-violation
# trick — the ITF counterexample the simulator dumps IS the targeted trace;
# seeds pinned in scripts/gen-candidates.sh, rust backend reproduces them
# exactly) are projected to candidate golden YAMLs by scripts/itf-to-golden.py
# and round-trip verified: the emitted YAML is re-parsed and aligned
# step-for-step against the ITF's lastStep sequence — transitions exact,
# effect sequences equal in the canonical §4 alphabet, with the YAML side
# re-read through the REPLAY direction's golden-effect classifier
# (scripts/conformance_vocab.py — the same tables Stage 7's generator uses)
# and skipped bookkeeping steps checked to carry nothing modeled. This proves
# the projection is loss-free w.r.t. the modeled vocabulary; executing the
# candidates against chuggernaut is the upstream half (untested here — §3.4).
gen_tmp=$(mktemp -d)
bash scripts/gen-candidates.sh "$gen_tmp"
# Drift guard: the committed example candidates under docs/examples/ must be
# exactly what the pinned-seed pipeline regenerates (like Stage 7's guard,
# but self-contained — no chuggernaut checkout involved).
for f in candidate_clean_lifecycle.yaml candidate_gate_rework_loop.yaml; do
  if ! diff -u "docs/examples/$f" "$gen_tmp/$f"; then
    rm -rf "$gen_tmp"
    echo "FAIL: docs/examples/$f drifts from the pinned-seed regeneration" >&2
    echo "      (regenerate: just itf-golden, then copy traces/candidates/$f)" >&2
    exit 1
  fi
done
rm -rf "$gen_tmp"
echo "Generation round-trip OK: both candidates project loss-free and match docs/examples/."

echo
echo "=== Stage 9: chuggy-model PRs 1-3 + notes-reconciliation (typecheck + unit tests + invariant simulation) ==="
# The model-first successor spec (docs/chuggy-charter.md; specs/chuggy/).
# PR 1's gate is typecheck + unit tests + randomized invariant simulation on
# BOTH GatePricing instances (charter §2: the gate-pricing parameter must be
# exercised under both prices) plus the RetryFree instance (the operator-
# churn exemption in stepDescends must be exercised by a machine run).
# PR 2 (authoring lifecycle; gate: revoke cascades proved safe) rides the
# SAME runs: every instance starts empty and runs the authoring actions
# (arrive/release/revoke), and allInvariants gained revokedNeverLands,
# cascadeSafety, terminalsAbsorbing, and idsDense — plus a second
# expected-violation probe in 9b for cascade reachability.
# PR 3 (task-records depth; gate: phase-outcome combinators pinned by the
# eval vocabulary extracted from chuggernaut) rides the same runs AGAIN,
# with PROGRAMS ENABLED: every instance sets MAX_STAGES = 2, so arrivals
# draw nondet authored eval programs (staged, per-stage combinators) and
# allInvariants gained recordWellFormed, recordMonotone, and
# programsWellFormed — plus a third expected-violation probe in 9b for
# stage-advance reachability.
# The NOTES-RECONCILIATION PR (docs/chuggy-notes-triage.md) rides them all
# once more with the reshaped machine: Frozen removed (no freeze/unfreeze
# actions), Stalled merged into Escalated (the pre-work resume is an
# operator-retry flavor; no stalled-retry action), gas rename, REWORK_POLICY.
# The shrunk action list changed the simulator's nondet structure, so every
# 9b seed was re-examined; forensics at each probe.
# Stage 1 already typechecks specs/chuggy/*.qnt with everything else under
# specs/; the explicit typechecks here keep the stage self-contained.
# Apalache verification is deliberately deferred (see specs/chuggy/README.md).
for f in specs/chuggy/measure.qnt specs/chuggy/domain.qnt \
         specs/chuggy/mc/mc_chuggy.qnt specs/chuggy/tests/chuggy_test.qnt; do
  echo "--- typecheck $f"
  npx quint typecheck "$f"
done
npx quint test specs/chuggy/tests/chuggy_test.qnt
npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted \
  --invariant=allInvariants --max-samples=2000 --max-steps=40
npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_deadline_only \
  --invariant=allInvariants --max-samples=2000 --max-steps=40
npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_retryfree \
  --invariant=allInvariants --max-samples=2000 --max-steps=40
# Pin stepDescends' RetryFree CHURN exemption on a trace KNOWN to contain the
# free pipeline-resume climb (the 9b seed below): the 9b witness proves the
# climb reachable, but only allInvariants ON that trace proves the exemption
# arm exempts it — a sign-flip there ships green through everything else
# (found by adversarial review; mutant-verified).
npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_retryfree \
  --invariant=allInvariants --max-samples=50000 --max-steps=40 \
  --seed=0x240a2d65e1e3e305 --backend=rust

# 9b — anti-vacuity, expected-fail (the Stage 6a pattern: pinned seed, rust
# backend, grep the verdict — never trust exit codes alone). On the
# RetryFree instance the witness freeClimbNever ("no operator-retry into a
# pipeline phase ever climbs the measure") MUST be violated: a free resume
# into Evaluating/Landing climbs the measure and is exactly the RetryFree
# CHURN arm that stepDescends exempts. If this run ever passes, that
# exemption has become dead code (or free retries silently started
# charging) — fail loudly. (The witness deliberately excludes the pre-work
# RPending resume, which climbs free under BOTH meterings — domain.qnt
# freeClimbNever has the argument.)
# (Seed re-pinned for the notes-reconciliation PR — the third re-pin, same
# reason as PR 2's and PR 3's: the nondet structure changed again — the
# step action list shrank by three (freeze/unfreeze/stalled-retry gone)
# and the witness was refined to the pipeline-resume shape. PR 3's seed
# 0x2b196ffb57466d4d was verified GENUINELY DEAD before re-pinning: its
# full 50k-sample budget ran to completion with no violation ([ok], 32s).
# The new seed was found unseeded within ~907k samples (~36s, rust
# backend) and reproduces the violation on its first trace (37ms), with
# the operator-retry-into-Evaluating signature in the trace.)
if free_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_retryfree \
  --invariant=freeClimbNever \
  --max-samples=50000 --max-steps=40 --seed=0x240a2d65e1e3e305 --backend=rust 2>&1); then
  echo "FAIL: freeClimbNever unexpectedly HELD on mc_chuggy_retryfree —" >&2
  echo "      the RetryFree churn exemption in stepDescends is unexercised dead code" >&2
  exit 1
fi
echo "$free_out" | grep -q '\[violation\]' || {
  echo "FAIL: mc_chuggy_retryfree witness run failed for a reason other than the expected violation:" >&2
  echo "$free_out" | tail -5 >&2
  exit 1
}
echo "$free_out" | grep -q 'operator-retry' || {
  echo "FAIL: freeClimbNever violation trace lacks the operator-retry signature" >&2
  exit 1
}
echo "Free-retry climb reproduced: an uncharged operator resume climbs the measure"
echo "(the stepDescends CHURN exemption is exercised, not dead — measure.qnt CHURN set)."

# 9b, second probe (PR 2) — cascade reachability, expected-fail. The
# witness cascadeParkNever ("no revoke ever parks a dependent") MUST be
# violated on the budgeted instance: a reachable revoke whose atomic
# cascade parks at least one dependent (StepRecord with >1 transition) is
# the machine-level proof that cascadeSafety's green runs above are checked
# against traces where the cascade actually fires — without it, a fleet
# whose revokeDoomed set stayed empty would satisfy cascadeSafety
# vacuously. The unit tests walk the 3-job chain deterministically; this
# pins the same shape as REACHABLE in the machine. (Notes-PR forensics:
# the parks now land on PEscalated — the merged desk — but the witness
# shape, label, and RsDependencyRevoked signature are unchanged, and the
# PR 2 seed SURVIVED the re-examination: it still violates within its
# budget on the reshaped machine (38ms) with both signature greps hit, so
# it is deliberately NOT re-pinned.)
if park_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted \
  --invariant=cascadeParkNever \
  --max-samples=20000 --max-steps=40 --seed=0x5cea1f53f74a0e4e --backend=rust 2>&1); then
  echo "FAIL: cascadeParkNever unexpectedly HELD on mc_chuggy_budgeted —" >&2
  echo "      no reachable revoke ever cascade-parks a dependent (cascadeSafety may be vacuous)" >&2
  exit 1
fi
echo "$park_out" | grep -q '\[violation\]' || {
  echo "FAIL: mc_chuggy_budgeted cascade probe failed for a reason other than the expected violation:" >&2
  echo "$park_out" | tail -5 >&2
  exit 1
}
echo "$park_out" | grep -q 'job-revoked' && echo "$park_out" | grep -q 'RsDependencyRevoked' || {
  echo "FAIL: cascadeParkNever violation trace lacks the revoke-then-park signature" >&2
  exit 1
}
echo "Cascade reproduced: a reachable revoke atomically parks a dependent behind the"
echo "dependency_revoked wall (cascadeSafety is exercised, not vacuous — the PR 2 gate)."

# 9b, third probe (PR 3) — stage-advance reachability, expected-fail. The
# witness stageAdvanceNever ("no eval stage ever advances") MUST be
# violated on the budgeted instance (MAX_STAGES = 2, so nondet arrivals
# author multi-stage programs): a reachable eval-stage-passed step — the
# Evaluating -> Evaluating edge, chuggernaut spec.md §2.1 line 832 — is
# the machine-level proof that the green invariant runs above cover traces
# where the staged interpreter and the measure's stage digit actually
# fire; a fleet that only ever drew single-stage programs would leave both
# unexercised. The unit tests walk the advance deterministically; this
# pins it as REACHABLE. (Old PR 1-2 seeds cannot cover this — the label
# did not exist; probe and seed are PR 3-new, found unseeded within ~25k
# samples. Notes-PR forensics: the PR 3 seed SURVIVED the re-examination —
# it still violates within its budget on the reshaped machine (631ms) with
# the eval-stage-passed signature, so it is deliberately NOT re-pinned.)
if stage_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted \
  --invariant=stageAdvanceNever \
  --max-samples=20000 --max-steps=40 --seed=0x9180927e576bcf85 --backend=rust 2>&1); then
  echo "FAIL: stageAdvanceNever unexpectedly HELD on mc_chuggy_budgeted —" >&2
  echo "      no reachable eval stage ever advances (the staged interpreter may be vacuous)" >&2
  exit 1
fi
echo "$stage_out" | grep -q '\[violation\]' || {
  echo "FAIL: mc_chuggy_budgeted stage probe failed for a reason other than the expected violation:" >&2
  echo "$stage_out" | tail -5 >&2
  exit 1
}
echo "$stage_out" | grep -q 'eval-stage-passed' || {
  echo "FAIL: stageAdvanceNever violation trace lacks the eval-stage-passed signature" >&2
  exit 1
}
echo "Stage advance reproduced: a reachable multi-stage program passes a non-final"
echo "stage and spawns the next (the PR 3 interpreter and stage digit are exercised)."

echo
echo "=== All checks passed ==="
