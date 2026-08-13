# v1-review notes → chuggy-model: the triage

geoff and davemo88 reviewed the v1 model (the one derived from chuggernaut) and
kept notes; those notes arrived after chuggy-model PRs 1–3 had merged. This
document is the reconciliation: every note, verbatim, mapped to one of —
**already true** (with the receipt), **changed now** (the notes-reconciliation
PR), **recorded for a later PR**, or **open** (flagged, default chosen,
veto welcome). Refinements from the follow-up message are folded in.

## Already true in chuggy-model

| Note | Receipt |
|---|---|
| "retries are infra/intermittent failure oriented, TF they should not be part of core job state machine (they are task specific-only). reworks (work-evaluate cycles are legit and good)" | PR 1's adversarial review **blocked** on exactly this and the machinery was deleted: retries live in the trusted `backoffLimit` fabric axiom; a terminally-failed work set escalates at cycle level (`work_failed`); rework cycles are core and budgeted. |
| "clean up task phase, possibly specify task by role directly e.g. evaluator / worker" | PR 3: `TaskKind = TKWork \| TKEval(stage)`. |
| "the dispatcher working with the ready q is not pure fifo popping, it's nondet outcome because the dispatcher is also agentic" | chuggy has no queue at all (non-goals row); dispatch is a nondet pick among Ready jobs. The follow-up's "agentic dispatcher **modeled**" goes further — see *changed now*. |
| "decideDepRecheck - is this good?" | Dissolved. Blocked/Ready are derived predicates; the unblock cascade does not exist as machinery. |
| "why doesn't decide.qnt retry work have any effects?" / "why does decide eval set attempts: 1 unconditionally" | No retry decider and no `attempt` field exist to be confused by. |
| "batched could also be moved elsewhere" | Unmodeled; deferred to the merge-queue PR. Re-sited per the follow-up — see *recorded*. |
| "how do decision events flow to consumers / executors that apply their side effects" | This is the refinement layer (charter §4, resolved to the journaled actor): record-vs-effect atomicity, roadmap PR 6. |
| "wtf is envActive in types.qnt/Core" | chuggy has none. Standing rule for the multi-repo PR: landing-failure conditions enter as explicitly named nondet events (e.g. `branchMoved(repo)`, "the default branch moved under the candidate"), never a stored mystery flag. |

## Changed now (the notes-reconciliation PR)

| Note | Change |
|---|---|
| "stalled should be rolled into escalated" / "stalled similarly, need intent clarified" | `PStalled` merges into `PEscalated`: one parked-with-open-human-task phase; the `reason` field (already deliberate trace vocabulary) carries the distinction (`revalidation_failed`, `dependency_revoked` are the pre-work reasons). Stalled-retry becomes an operator resume flavor. |
| "Frozen removed. Draft -> Ready/Blocked." | Single authoring phase: `PDraft` releases directly into the pipeline (`PPending`, whose Ready/Blocked split is derived). Freeze/unfreeze deciders die; the authoring churn set shrinks (unfreeze was its only in-pipeline member besides arrival). Deliberate deviation from v1's table, recorded at the deciders. |
| "task state machine" | The run's own lifecycle becomes explicit: a task is spawned → running → resolved(outcome), with `TCancelled` as revoke's force-close — one small sum type instead of implicit set-membership. |
| "agentic dispatcher modeled (not FIFO)" | Dispatch becomes a first-class modeled decision: the chooser is the agentic dispatcher, its pick a named nondet decision event in the trace — documented as the dispatcher's agency, not incidental scheduler noise. |
| "rework budget should be removed from core job entity and into impl / middleware" | The bound survives as a **policy parameter** (the `GatePricing` pattern): the machine consults an abstract rework policy; the termination measure keeps its bounded digit; the model documents that the account is middleware-owned in the implementation, not a core-entity field. (Removing the bound entirely would make per-job liveness conditional on middleware behavior — rejected for the model; say the word to overrule.) |
| "what is job deadline exceeded" / "what is deadline left" | The account is renamed to what it is: **gas**. `gasLeft`, wall `gas_exhausted`, const `GAS`. The charter's "deadline required" decision is unchanged — the required bound stays; the wall-clock-implying name dies. README maps chuggernaut's `job_deadline` knob onto it. |
| "termMeasure also has magic number 4 in it" | Measure audit: every numeral becomes a named, derived constant with its derivation next to it. |
| "molting leaving compaction sentinels from old docs/designs/plans" | Doc sweep across specs/chuggy for stale remnants of superseded designs. |

## Recorded for a later PR

| Note | Where |
|---|---|
| "Batched from Ready or Blocked" (follow-up) | Merge-queue PR: `Batched` enters from the released pre-work state (`PPending`), **not** from authoring as v1's table had it. |
| "allow passing evaluators to cite code they care about to let them decide whether to rerun if evaluation must rerun" | Own small PR after this one: task records carry abstract citation footprints; rework respawns only evaluators whose footprint intersects the cycle's change (nondet abstraction over real diffs). |

## Open — default chosen, veto welcome

| Note | Default |
|---|---|
| "name job / task to something more contrasting and clear" | **Kept job/task for now.** Renaming is exported trace vocabulary; my proposal is `job / run` ("a job's stages spawn runs") — one word from either of you and the rename lands as its own mechanical PR. |
