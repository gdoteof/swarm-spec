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
echo "=== Stage 9: chuggy-model PRs 1-5 + notes-reconciliation + citations (typecheck + unit tests + invariant simulation) ==="
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
# The CITATIONS PR (the triage's "recorded for a later PR" row) rides them
# all again with CITATIONS ENABLED: every instance sets N_REGIONS = 2, so
# each task completion draws a nondet citation footprint (4 subsets of
# {1,2}) and scoped rework respawns — carried verdicts, TSCarried record
# entries, the CarryEvalVerdicts effect — are reachable; allInvariants
# gained citationsWellFormed, plus a fourth expected-violation probe in 9b
# for carry reachability. The extra nondet draw per completion changed the
# simulator's nondet structure AGAIN, so every 9b seed was re-examined
# once more; forensics at each probe.
# The WITNESS-HARDENING PR restructured 9b into two layers (policy at the
# 9b header) and REMOVED the two pinned allInvariants "twin" runs that used
# to sit at the end of this stage (retryfree @ 0xcfadb0ec5ca34c85 over 50k
# samples; citations @ 0xd21f881a768a43bc over 20k) — fully subsumed by
# 9b's deterministic layer: each twin's entire purpose was "allInvariants
# ON a trace known to contain the climb/carry" (the sign-flip catcher,
# found by adversarial review; mutant-verified then and re-verified now),
# and the deterministic traces assert allInvariants after EVERY step of a
# trace that provably contains the shape — including the witnessing step
# itself — with zero seed dependence. The unseeded runs below keep generic
# random allInvariants coverage on all FOUR instances; the citations run is
# NEW here for exactly that reason (its only random allInvariants coverage
# used to ride the removed twin).
# The MULTI-REPO PR (roadmap PR 4; gate: isolation invariants) rides the
# same runs once more with REPOS ENABLED: every instance sets N_REPOS = 2,
# arrivals draw the ticket's authored target repo, and every landing
# attempt draws the environment's per-attempt branchMoved choice with the
# outcome drawn from landOutcomes(moved) — LandFailed drawable only on a
# moved branch (the envActive standing rule: an explicitly named nondet
# event on the step record, never a stored flag). allInvariants gained
# landingIsolation, quietRepoLandsCleanly, and reposWellFormed, and
# 9b-DET gained a fifth deterministic module (the isolation gate's
# witness half: quiet-clean landing, moved rework + wall attributed,
# cross-repo dep unblock). The two new draws changed the simulator's
# nondet structure YET AGAIN, so every 9b-RND seed was re-examined:
# cascadeParkNever and stageAdvanceNever SURVIVED; freeClimbNever and
# carryNever died and were re-pinned — forensics at each probe.
# The MERGE-QUEUE + LANDING PR (roadmap PR 5 — deliberately last; its
# gate, landing/requirements, was NEVER ANSWERED, so the requirements it
# serves are PROPOSED-pending-confirmation: specs/chuggy/README.md) rides
# the same runs with the LANDING RESTRUCTURED: eval-passed enqueues
# (PLanding), the dequeue draws branchMoved — quiet fast-paths the direct
# SquashMerge in one step, moved opens the repo's depth-1 gate (PGated) —
# and the gated resolution draws from landOutcomes(true) = AdvanceDefault
# or the priced eviction (the §5e path rule as machine structure); absorb
# joined the any{} roster (Batched re-sited: PPending -> PBatched, the
# grouping whose lead's single landing fans out member completions).
# allInvariants gained gatedPromotesDirectSquashes, gateDepthOne, and
# batchWellFormed (landingExclusive/landingIsolation extended in place),
# and 9b-DET gained THREE deterministic modules (depth-1 guard-refusal +
# both success effects on one trace; the DeadlineOnly eviction walking
# v1's §5a loop into the gas wall; the batch fan-out + dissolution). The
# restructured draws changed the nondet surface YET AGAIN, so every
# 9b-RND seed was re-examined — forensics at each probe.
# Stage 1 already typechecks specs/chuggy/*.qnt with everything else under
# specs/; the explicit typechecks here keep the stage self-contained.
# Apalache verification is deliberately deferred (see specs/chuggy/README.md).
for f in specs/chuggy/measure.qnt specs/chuggy/domain.qnt \
         specs/chuggy/mc/mc_chuggy.qnt specs/chuggy/tests/chuggy_test.qnt \
         specs/chuggy/tests/chuggy_witness_test.qnt; do
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
npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_citations \
  --invariant=allInvariants --max-samples=2000 --max-steps=40

echo
echo "=== Stage 9b: reachability witnesses — deterministic layer (gates) + random layer (warns) ==="
# LAYER POLICY (the witness-hardening PR, after the citations PR forced the
# FOURTH consecutive freeClimbNever seed re-pin): the four witnessed shapes
# are trace facts, and each now has a deterministic machine trace — so the
# DETERMINISTIC layer guards semantics and GATES the build, while the
# RANDOM pinned-seed layer guards trace-space health and only WARNS. A
# nondet-changing PR can kill the random layer's seeds (that layer's
# warning prints the re-pin protocol); it cannot touch the deterministic
# layer, which is what makes the four shapes' reachability — and
# allInvariants along their traces — survive every future nondet drift
# without a seed hunt.
#
# 9b-DET — the LOAD-BEARING layer: eight deterministic machine-trace
# modules (specs/chuggy/tests/chuggy_witness_test.qnt; mechanism note in
# its header — `init.then(apply(decide*))` with guard-checked drivers, so
# every accepted trace is a trace of `step`). Each run proves its shape
# REACHABLE, asserts the witness verdict AT the witnessing step (violated
# exactly where the shape fires, holding where it must not), and asserts
# allInvariants after EVERY step — which is what subsumes the removed
# Stage 9 pinned twins. Zero seeds anywhere. Mutation-verified
# (2026-08-13, the witness-hardening PR): a sign-flip on stepDescends'
# RetryFree arm (either conjunct) and a carry-despite-intersection mutant
# in spawnEvalScoped are each caught by this layer alone. The multi-repo
# module (PR 4) extends this layer per its convention — the machine's two
# new nondet draws each exercised on both branches deterministically
# (quiet -> clean landing; moved -> gate rework and wall, each attributed
# to the ticket's own repo; the repo pick off-default with a cross-repo
# dep unblock) — and has NO paired random probe: landing attempts are
# dense in random exploration, so the unseeded Stage 9 runs are its
# random side. The MERGE-QUEUE PR (PR 5) added modules six through
# eight, per the same convention (new nondet surface -> deterministic
# runs on both branches first): the gate module pins the DEPTH-1
# GUARD-REFUSAL mid-trace (a second same-repo dequeue disabled while the
# slot is held, enabled the step it frees), BOTH success effects on
# one trace — gated AdvanceDefault, quiet fast-path SquashMerge (the
# §5e path rule witnessed) — and the QUIET FAST-PATH as its own
# witnessed run against the hoisted routing decider decideDequeue
# (adversarial-review MAJOR 1: the p3 routing-mutant catcher); the deadline-only module walks the eviction
# on the OTHER GatePricing branch (two gas-only gate failures into the
# gas wall — v1's §5a loop shape with the backstop doing its job); the
# batch module fires the ticket-batched BATCHING climb (the stepDescends
# convention roster), absorbs from Ready AND Blocked (the note's both
# flavors), pins the dep union gating the lead, the completion fan-out
# (member's dependent Ready in the same post-state), and the
# dissolution. None has a paired random probe (absorb pairs and landing
# attempts are dense; the unseeded Stage 9 runs are the random side).
for m in chuggy_witness_free_test chuggy_witness_cascade_test \
         chuggy_witness_stage_test chuggy_witness_carry_test \
         chuggy_witness_multirepo_test chuggy_witness_gate_test \
         chuggy_witness_gate_deadline_test chuggy_witness_batch_test; do
  echo "--- quint test --main=$m specs/chuggy/tests/chuggy_witness_test.qnt"
  npx quint test --main="$m" specs/chuggy/tests/chuggy_witness_test.qnt
done

# 9b-RND — the DEMOTED random layer: the four pinned-seed expected-violation
# probes (the Stage 6a pattern: pinned seed, rust backend, grep the verdict),
# kept because they answer a question the deterministic layer cannot: does
# RANDOM exploration of the CURRENT nondet surface still reach the shape at
# this seed/budget (trace-space health)? A probe that stops firing no longer
# fails the build — it prints the loud warning + re-pin protocol below.
# The verdict TRICHOTOMY still gates on crashes: a probe run that HELD
# (exit 0 with an explicit [ok]) or fired without its signature is
# trace-space news and only WARNS; a probe run that CRASHED — nonzero exit
# with no [violation], or exit 0 with no verdict at all (typo'd invariant,
# missing file, bad flag, dead backend) — is a HARNESS bug, not a dead
# seed, and hard-fails exactly like the pre-hardening era. Demotion never
# extends to malformed invocations.
# Per-probe forensics from the gating era are preserved at each probe.
warn_probe() {
  echo "WARNING: random witness probe '$1' did not fire: $2" >&2
  echo "         The build does NOT fail: Stage 9b-DET above already proves the" >&2
  echo "         shape reachable and allInvariants along its trace. This warning" >&2
  echo "         means the RANDOM layer lost trace-space coverage (a nondet-" >&2
  echo "         structure change killed the seed, or the shape got rarer)." >&2
  echo "         Re-pin protocol (the pre-hardening ritual, now non-blocking):" >&2
  echo "           1. verify the old seed is genuinely dead: rerun the probe with" >&2
  echo "              its full sample budget and confirm [ok] (no violation);" >&2
  echo "           2. hunt unseeded: the same command without --seed until" >&2
  echo "              [violation]; note the reported seed and the sample cost;" >&2
  echo "           3. pin the new seed here with forensics (old seed verified" >&2
  echo "              dead, unseeded find cost, first-trace reproduction time);" >&2
  echo "           4. confirm the new violation trace still carries this probe's" >&2
  echo "              signature greps." >&2
}

# 9b-RND probe 1 — freeClimbNever on the RetryFree instance: expected to
# be violated — a free resume into Evaluating/Landing climbs the measure
# and is exactly the RetryFree CHURN arm that stepDescends exempts. (The
# witness deliberately excludes the pre-work RPending resume, which climbs
# free under BOTH meterings — domain.qnt freeClimbNever has the argument.)
# Semantics — the exemption arm being alive, allInvariants on the climb —
# are 9b-DET's freeClimbDeterministicTest now; this probe only reports
# whether random exploration still finds the shape at this seed.
# (Seed re-pinned for the notes-reconciliation PR — the third re-pin, same
# reason as PR 2's and PR 3's: the nondet structure changed again — the
# step action list shrank by three (freeze/unfreeze/stalled-retry gone)
# and the witness was refined to the pipeline-resume shape. PR 3's seed
# 0x2b196ffb57466d4d was verified GENUINELY DEAD before re-pinning: its
# full 50k-sample budget ran to completion with no violation ([ok], 32s).
# That seed was found unseeded within ~907k samples (~36s, rust
# backend) and reproduced the violation on its first trace (37ms), with
# the operator-retry-into-Evaluating signature in the trace.)
# (Re-pinned AGAIN for the citations PR — the fourth re-pin: taskDone
# grew a nondet citation draw (4 subsets per completion), shifting every
# trace after the first completion event. The notes-PR seed
# 0x240a2d65e1e3e305 was verified GENUINELY DEAD before re-pinning: its
# full 50k-sample budget ran to completion with no violation ([ok], 31s).
# That seed was found unseeded within ~1.8M samples (~2m16s, rust
# backend) and reproduced the violation on its first trace (141ms), with
# the operator-retry pipeline-resume signature in the trace.)
# (Re-pinned AGAIN for the multi-repo PR — the fifth re-pin, and the
# first under the warn-only regime (no build was held hostage): arrive
# grew the authored repo draw (2 choices per arrival) and land grew the
# branchMoved draw with the outcome drawn from landOutcomes(moved),
# shifting every trace from its first arrival. The citations-PR seed
# 0xcfadb0ec5ca34c85 was verified GENUINELY DEAD before re-pinning: its
# full 50k-sample budget ran to completion with no violation ([ok],
# ~30s). The new seed was found unseeded within ~3.6M samples (~3m31s,
# rust backend) and reproduces the violation on its first trace (43ms),
# with the operator-retry pipeline-resume signature in the trace.)
# (Merge-queue-PR forensics: re-examined against the restructured landing
# surface — land split into gateEnter (branchMoved draw; quiet fast-path)
# + gateResolve (the gated outcome draw) and the absorb pair draw joining
# the any{} roster. The multi-repo seed SURVIVED its first re-examination:
# still violates within its 50k budget (~28s, rust backend) with the
# operator-retry pipeline-resume signature; deliberately NOT re-pinned.)
if free_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_retryfree \
  --invariant=freeClimbNever \
  --max-samples=50000 --max-steps=40 --seed=0x8095f27f767afa07 --backend=rust 2>&1); then
  if echo "$free_out" | grep -q '\[ok\]'; then
    warn_probe freeClimbNever "seed 0x8095f27f767afa07 no longer reaches the free climb ([ok] over its 50k budget)"
  else
    echo "FAIL: freeClimbNever probe exited 0 with no verdict (harness bug, not a dead seed):" >&2
    echo "$free_out" | tail -5 >&2
    exit 1
  fi
elif ! echo "$free_out" | grep -q '\[violation\]'; then
  echo "FAIL: freeClimbNever probe crashed — failed for a reason other than the expected" >&2
  echo "      violation (malformed invocation is a harness bug, not a dead seed):" >&2
  echo "$free_out" | tail -5 >&2
  exit 1
elif ! echo "$free_out" | grep -q 'operator-retry'; then
  warn_probe freeClimbNever "violation trace lacks the operator-retry signature"
else
  echo "Random probe freeClimbNever: still firing (an uncharged operator resume climbs"
  echo "the measure — trace-space coverage of the stepDescends CHURN exemption intact)."
fi

# 9b-RND probe 2 (PR 2) — cascadeParkNever on the budgeted instance:
# expected to be violated — a reachable revoke whose atomic cascade parks
# at least one dependent (StepRecord with >1 transition). Reachability and
# cascadeSafety-on-the-parked-state are 9b-DET's
# cascadeParkDeterministicTest now; this probe only reports trace-space
# coverage at this seed. (Notes-PR forensics:
# the parks now land on PEscalated — the merged desk — but the witness
# shape, label, and RsDependencyRevoked signature are unchanged, and the
# PR 2 seed SURVIVED the re-examination: it still violates within its
# budget on the reshaped machine (38ms) with both signature greps hit, so
# it is deliberately NOT re-pinned.) (Citations-PR forensics: re-examined
# once more against the citation-draw nondet shift — the seed SURVIVED
# again: violates within its budget (96ms) with both signature greps hit;
# deliberately NOT re-pinned.) (Multi-repo-PR forensics: re-examined
# against the repo-draw + branchMoved nondet shifts — SURVIVED a third
# time: violates within its budget (45ms) with both signature greps hit;
# deliberately NOT re-pinned.) (Merge-queue-PR forensics: re-examined
# against the gateEnter/gateResolve/absorb restructuring — SURVIVED a
# fourth time: violates within its budget (49ms) with both signature
# greps hit; deliberately NOT re-pinned.)
if park_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted \
  --invariant=cascadeParkNever \
  --max-samples=20000 --max-steps=40 --seed=0x5cea1f53f74a0e4e --backend=rust 2>&1); then
  if echo "$park_out" | grep -q '\[ok\]'; then
    warn_probe cascadeParkNever "seed 0x5cea1f53f74a0e4e no longer reaches a cascade park ([ok] over its 20k budget)"
  else
    echo "FAIL: cascadeParkNever probe exited 0 with no verdict (harness bug, not a dead seed):" >&2
    echo "$park_out" | tail -5 >&2
    exit 1
  fi
elif ! echo "$park_out" | grep -q '\[violation\]'; then
  echo "FAIL: cascadeParkNever probe crashed — failed for a reason other than the expected" >&2
  echo "      violation (malformed invocation is a harness bug, not a dead seed):" >&2
  echo "$park_out" | tail -5 >&2
  exit 1
elif ! { echo "$park_out" | grep -q 'ticket-revoked' && echo "$park_out" | grep -q 'RsDependencyRevoked'; }; then
  warn_probe cascadeParkNever "violation trace lacks the revoke-then-park signature"
else
  echo "Random probe cascadeParkNever: still firing (a reachable revoke atomically parks"
  echo "a dependent behind the dependency_revoked wall — trace-space coverage intact)."
fi

# 9b-RND probe 3 (PR 3) — stageAdvanceNever on the budgeted instance:
# expected to be violated — a reachable eval-stage-passed step (the
# Evaluating -> Evaluating edge, chuggernaut spec.md §2.1 line 832).
# Reachability, the descent through the advance, and allInvariants on the
# advancing trace are 9b-DET's stageAdvanceDeterministicTest now; this
# probe only reports trace-space coverage at this seed — whether random
# arrivals still draw and run multi-stage programs to an advance.
# (Old PR 1-2 seeds cannot cover this — the label
# did not exist; probe and seed are PR 3-new, found unseeded within ~25k
# samples. Notes-PR forensics: the PR 3 seed SURVIVED the re-examination —
# it still violates within its budget on the reshaped machine (631ms) with
# the eval-stage-passed signature, so it is deliberately NOT re-pinned.
# Citations-PR forensics: re-examined against the citation-draw nondet
# shift — SURVIVED again: violates within its budget (~5.1s) with the
# eval-stage-passed signature; deliberately NOT re-pinned. Multi-repo-PR
# forensics: re-examined against the repo-draw + branchMoved shifts —
# SURVIVED a third time: violates within its budget (646ms) with the
# eval-stage-passed signature; deliberately NOT re-pinned. Merge-queue-PR
# forensics: re-examined against the gateEnter/gateResolve/absorb
# restructuring — SURVIVED a fourth time: violates within its budget
# (342ms) with the eval-stage-passed signature; deliberately NOT
# re-pinned.)
if stage_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_budgeted \
  --invariant=stageAdvanceNever \
  --max-samples=20000 --max-steps=40 --seed=0x9180927e576bcf85 --backend=rust 2>&1); then
  if echo "$stage_out" | grep -q '\[ok\]'; then
    warn_probe stageAdvanceNever "seed 0x9180927e576bcf85 no longer reaches a stage advance ([ok] over its 20k budget)"
  else
    echo "FAIL: stageAdvanceNever probe exited 0 with no verdict (harness bug, not a dead seed):" >&2
    echo "$stage_out" | tail -5 >&2
    exit 1
  fi
elif ! echo "$stage_out" | grep -q '\[violation\]'; then
  echo "FAIL: stageAdvanceNever probe crashed — failed for a reason other than the expected" >&2
  echo "      violation (malformed invocation is a harness bug, not a dead seed):" >&2
  echo "$stage_out" | tail -5 >&2
  exit 1
elif ! echo "$stage_out" | grep -q 'eval-stage-passed'; then
  warn_probe stageAdvanceNever "violation trace lacks the eval-stage-passed signature"
else
  echo "Random probe stageAdvanceNever: still firing (a reachable multi-stage program"
  echo "passes a non-final stage and spawns the next — trace-space coverage intact)."
fi

# 9b-RND probe 4 (citations PR) — carryNever on mc_chuggy_citations (the
# probe instance built for exactly this — see its header: one ticket,
# singleton task sets, flat programs, Budgeted(1), the densest honest
# carry choreography being the GATE-REWORK carry): expected to be violated
# — a reachable CarryEvalVerdicts effect, a retained passing verdict
# reused instead of rerun. Reachability and the invariants over the
# carried state are 9b-DET's carryDeterministicTest now (with the
# scope-discipline twin carryScopeRespectsIntersectionTest); this probe
# only reports whether the citation dice still land the carry at this
# seed. (Probe and seed are
# citations-PR-new — no older seed can cover this: the effect did not
# exist. Found unseeded within ~481k samples (~13s, rust backend) after
# the shared instances proved too diffuse — carryNever HELD over ~2M
# unseeded samples on mc_chuggy_budgeted (~2m37s), which is exactly why
# the probe instance exists (the mc_livelock move). Reproduced the
# violation on its first trace (41ms) with both the CarryEvalVerdicts
# effect and a TSCarried live task in the trace.)
# (Re-pinned for the multi-repo PR — this probe's first re-pin, under the
# warn-only regime: the land action's branchMoved draw dilutes the
# LandFailed density (failure is drawable only on a moved branch — the
# probe's gate-rework choreography needs it) and the arrival's repo draw
# shifts every trace from birth. The citations-PR seed
# 0xd21f881a768a43bc was verified GENUINELY DEAD before re-pinning: its
# full 20k-sample budget ran to completion with no violation ([ok], ~9s).
# The new seed was found unseeded within ~1.95M samples (~2m7s, rust
# backend — rarer than the citations-era ~481k find, consistent with the
# diluted failure draw) and reproduces the violation on its first trace
# (96ms), with both the CarryEvalVerdicts effect and a TSCarried live
# task in the trace.)
# (Re-pinned AGAIN for the merge-queue PR — this probe's second re-pin,
# warn-only regime: the probe's gate-rework choreography now needs TWO
# consecutive right draws where it needed one — the dequeue must draw
# MOVED (gateEnter) and the gated resolution must draw LandFailed
# (gateResolve) — and the absorb pair draw joined the any{} roster,
# shifting every trace with >= 2 Pending same-repo tickets. The
# multi-repo seed 0xd1eb524283a15d73 was verified GENUINELY DEAD before
# re-pinning: its full 20k-sample budget ran to completion with no
# violation ([ok], ~10s). The new seed was found unseeded within ~8.8M
# samples (~4m56s, rust backend — rarer than the multi-repo-era ~1.95M
# find, consistent with the split landing draw) and reproduces the
# violation on its first trace (51ms), with both the CarryEvalVerdicts
# effect and a TSCarried task in the trace.)
if carry_out=$(npx quint run specs/chuggy/mc/mc_chuggy.qnt --main=mc_chuggy_citations \
  --invariant=carryNever \
  --max-samples=20000 --max-steps=40 --seed=0x698d28b35e3233fb --backend=rust 2>&1); then
  if echo "$carry_out" | grep -q '\[ok\]'; then
    warn_probe carryNever "seed 0x698d28b35e3233fb no longer reaches a carry ([ok] over its 20k budget)"
  else
    echo "FAIL: carryNever probe exited 0 with no verdict (harness bug, not a dead seed):" >&2
    echo "$carry_out" | tail -5 >&2
    exit 1
  fi
elif ! echo "$carry_out" | grep -q '\[violation\]'; then
  echo "FAIL: carryNever probe crashed — failed for a reason other than the expected" >&2
  echo "      violation (malformed invocation is a harness bug, not a dead seed):" >&2
  echo "$carry_out" | tail -5 >&2
  exit 1
elif ! { echo "$carry_out" | grep -q 'CarryEvalVerdicts' && echo "$carry_out" | grep -q 'TSCarried'; }; then
  warn_probe carryNever "violation trace lacks the carried-verdict signature"
else
  echo "Random probe carryNever: still firing (a reachable rework re-entry carries a"
  echo "disjoint retained passing verdict — trace-space coverage intact)."
fi

echo
echo "=== All checks passed ==="
