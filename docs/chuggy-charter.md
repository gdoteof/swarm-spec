# The chuggy-model charter

**What this is.** The founding decisions for `chuggy-model` — a fresh Quint model,
written *before* the system it specifies, for `chuggy`: the Kubernetes-assuming
successor to [chuggernaut](https://github.com/kasofsk/chuggernaut). Every decision
below carries its provenance: the question id from the intake instrument geoff and
kasofsk filled in over two rounds (2026-08-12; answer table archived in
[intake-answers.json](chuggy-intake-answers.json)). Method: converged answers became
decisions, divergences became the agenda (§4), and silence is flagged where the
instrument said silence would cost (§3).

The direction of authority inverts v1: swarm-spec's chuggernaut model chased an
existing implementation and caught it (model-status.md §5). `chuggy-model` leads —
it emits the golden traces; `chuggy`'s CI replays them
(trace-conformance.md, generation direction).

## 1. Identity

| Thing | Name | Provenance |
|---|---|---|
| The model (the ideal machine) | `chuggy-model` | geoff, `identity/name-r2`: "maybe its just: chuggy-model, chuggy" |
| The implementation | `chuggy` | kasofsk, `identity/name`; accepted by geoff |
| Where the model grows now | `specs/chuggy/` in swarm-spec | geoff, `identity/repo` ("this repo already has tooling") |
| Where both eventually live | a fresh monorepo (`chuggy` impl + spec together) | geoff `identity/repo-r2` fresh-monorepo; kasofsk `identity/repo-notes` "monorepo" — the same answer from two directions |

Until the monorepo exists, conformance traces ship from here as versioned artifacts;
when it exists, the spec moves in and replay runs in one CI. The monorepo itself is
decided but deliberately deferred (geoff, 2026-08-12): **public, under `gdoteof`,
kasofsk invited as collaborator** (GitHub user `davemo88` — kasofsk is his org); it gets created when implementation work begins —
model PRs keep landing here against the working harness until then.

## 2. Decided

Each row is settled unless reopened by name.

| Decision | Answer | Provenance |
|---|---|---|
| Deadline | **Required field.** A graph without a deadline is invalid. | both, `economy/deadline` |
| Gate-rework pricing | **A model parameter**, not a constant: `GatePricing = Budgeted(n) \| DeadlineOnly`. The model generates escalation traces under both; the choice is made on evidence. | geoff `economy/gate-pricing-r2` parameterize-and-decide; subsumes kasofsk's r1 `budget-gate` as one branch |
| Operator-retry metering | **Configurable per deployment, default charge.** | both, `economy/op-retry` |
| Currency | **Observed only.** Token/API spend is first-class in the implementation's accounting and dashboards, but not a model variable; the model keeps one gas. | both, `economy/currency` — decided against geoff's own earlier lean (`identity/anything`) |
| Exclusivity | **Effect-only.** Any number of tasks may run; the proved invariant is *exactly one landing per cycle*. **No tournament**: parallelism is task-structure inside Work/Eval phases, not competing implementations. | kasofsk `fabric/exclusivity-r2` effect-only + `fabric/exclusivity-notes`: "jobs have tasks… multiple tasks may run in parallel… no tournament" |
| Job anatomy | A job's Work and Eval phases each carry a **set of discrete tasks**, possibly parallel; phase outcome is a function of task outcomes. Task records are first-class (they carry the anatomy). | kasofsk `fabric/exclusivity-notes`; both `domain/firstclass` |
| Fabric axioms | Trusted unmodeled: `backoffLimit`, `activeDeadlineSeconds`, quota/scheduling, watch delivery. **Dropped: `no-double-pods`** — pod execution is at-least-once (the K8s Jobs docs disclaim uniqueness); every effect is idempotent, exactly-once proved only at the landing boundary. | both `fabric/trust`; geoff `fabric/trust-r2` drop-and-design-idempotent; forced anyway by effect-only exclusivity |
| Evaluation | **Eval is data, not machinery.** Each job carries an eval program (per-job-type stages) run by an interpreter under a verdict combinator; default combinator: unanimous pass. | kasofsk `eval/stages`; geoff `eval/verdict`, unopposed |
| Evaluator crashes | **The job pays.** Evaluator infrastructure failure draws down the job's budgets — one account, no new machinery. | both, `eval/evaluator-failure` |
| Visibility invariant | **Adopted**: every non-progressing job is reachable from an open human task. (Definition of "progressing" is contested — §4.) | both, `humans/invariant` |
| First-class order | **authoring → task-records → multi-repo → merge-queue.** Merge-queue deliberately last. | kasofsk `domain/firstclass-r2`, geoff silent; consistent with kasofsk's "wrapup phase needs thought" |
| Landing | **Deferred by choice.** Both undecided, `landing/requirements` unanswered. The model keeps landing mechanics abstract but names outcomes precisely from day one (`AdvanceDefault` ≠ `SquashMerge` — v1's one conformance divergence lives here). | both `landing/semantics`; kasofsk `landing/divergence` |
| Non-goals | **No bespoke scheduler. No retry machinery below the cycle. No dashboard in the model** (the dashboard consumes state, never causes transitions). | both, `identity/nongoals-r2` |
| Termination, committed part | **Per-job liveness is owed**: every job reaches Done, Escalated, or Stalled, or provably parks. | both rounds, both respondents (the contested half is §4) |
| Fabric shape | **Service + dumb K8s Jobs.** The journaled single-writer actor keeps all state and makes every decision; Kubernetes runs things and decides nothing. CRDs/controllers remain an explicitly open later migration — and the domain machine is shape-agnostic, so migrating would not invalidate the model. | resolved offline, 2026-08-12 (§4) |

## 3. In scope by silence — confirm or shrink

The non-goals checklist said: unchecked means you keep it. Both of you left the same
three unchecked (`identity/nongoals-r2`): **multi-tenancy**, **dynamic DAGs** (jobs
spawning jobs), **cross-cluster**. Dynamic DAGs look deliberate — kasofsk's
task-structure note points that way. The other two look expensive to mean by
accident. The model admits none of them in PR 1; each enters only by explicit
decision, in first-class order. Say the word and any of the three moves to §2's
non-goals row instead.

Also unanswered and still wanted: `eval/vocabulary` (one real eval spec in
pseudo-YAML — the eval interpreter stays abstract until an example exists),
`landing/requirements`, `identity/scale` (kasofsk), `identity/surprise` (both).

## 4. The agenda — the fork resolved, three items open

**The fork: premise and shape — resolved offline (2026-08-12).** The round-2
divergence: kasofsk flipped `premise/agree` to **no** and picked
`fabric/shape = service-plus-jobs`; geoff answered `crd-controllers`. The offline
conversation put the reason on record: kasofsk feels strongly that adapting
chuggernaut's core abstraction to Kubernetes is the wrong move — the fear is being
forced to think and work in the shapes the platform wants rather than the shapes
the core objective wants. geoff holds that the design is, or will be, reasonably
informed by what it runs on — and concedes the present: **service + dumb Jobs is
the shape for next steps**; if controllers are an improvement, they are one that
can come later. Decision recorded in §2.

Two consequences worth naming. First, the refinement layer is unblocked and
*defined*: what gets modeled next is the journaled actor — crash/recover of the
single writer, and the atomicity seam between recording a decision and effecting
it (the double-spend hazard from the shape flows). Second, the model itself is the
standing answer to kasofsk's fear: the domain machine encodes the core objective
with no platform vocabulary in it, and every runtime shape — today's service, any
future controller — must refine the *same* machine. Platform capture is precisely
what the refinement obligation forbids.

**Progressing.** geoff `humans/progressing = measure-descent` (the termination
measure does double duty); kasofsk `report-only` (dashboard query, informal). The
tension: kasofsk also *adopted* the invariant, and an invariant over an undefined
predicate can't be checked. The model uses measure-descent internally so the
invariant is at least stated; whether it's a checked theorem or a report is open.

**Termination's contested half.** geoff wants conditional system quiescence as a
second theorem (v1's strongest result); kasofsk affirmed `per-job-only` knowingly.
Resolution on offer: per-job is the committed theorem (§2); quiescence is attempted
in a severable module that constrains nothing if abandoned.

**macOS / mobile.** geoff's note (`fabric/macos-notes`): mac minis as worker nodes
via hypervisor + [macOS-vz-kubelet](https://github.com/agoda-com/macOS-vz-kubelet)
— the mac-as-node arm, keeping the model's fabric uniform — and "doing and
evaluating mobile work is probably a priority." Needs kasofsk's ack; the model's
fabric layer stays single-semantics on this bet.

## 5. Standing rules

Carried from v1's machine-checked lessons; constraints, not code:

1. **The termination measure is written before the machine.** Every transition
   descends it or belongs to a named, separately-proved bounded set.
2. **No free re-entry.** Every path back into active work is metered
   (operator paths per the §2 configurability row).
3. **Derive, don't store.** Any state expressible as a predicate over other state
   is a predicate, not a variable.
4. **Conformance from day one, direction reversed.** The model emits golden traces;
   the implementation grows up against them.

## 6. Model roadmap

| PR | Contents | Gate |
|---|---|---|
| 1 | `specs/chuggy/`: the measure, the core domain machine (phases with task-sets, budgets, required deadline, gate-pricing parameter, effect-exclusivity, abstract eval interpreter, named landing outcomes), first invariants | `just check` green incl. new stage; per-job liveness sketched |
| 2 | Authoring lifecycle (first-class rank #1) | revoke cascades proved safe |
| 3 | Task-records depth: task anatomy, parallel task-set semantics | phase-outcome combinators pinned by a real `eval/vocabulary` example |
| 4 | Multi-repo | isolation invariants |
| 5 | Merge-queue + landing (rank last, on purpose) | driven by `landing/requirements`, once answered |
| 6 | Refinement layer: the journaled actor (§4 resolved) — single-writer crash/recover, record-vs-effect atomicity | no double-spent budget, no duplicate cycle, across crashes at any seam; a later controller migration re-proves the same refinement against the same machine |
