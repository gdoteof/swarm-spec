/// The chuggy core domain machine (chuggy-charter.md §6, roadmap PR 1) —
/// written AFTER and fitted TO measure.qnt (standing rule 1). This is the
/// layer both §4 fork candidates share: every decider is a pure function of
/// observed state (`Core`), so a CRD reconciler and a journaled actor reuse
/// them unchanged; the refinement layer (reconcile vs journaled-actor
/// semantics) is deliberately absent, blocked on the §4 conversation.
///
/// PR 2 (authoring lifecycle, charter §2 first-class rank #1; gate: revoke
/// cascades proved safe) is IN: tickets arrive as Drafts through the
/// `freshTicket` seam PR 1 kept open, and Revoked is the second settled
/// terminal with an ATOMIC park-cascade (decideRevoke) covering its
/// dependents.
///
/// THE NOTES-RECONCILIATION PR (docs/chuggy-notes-triage.md, "changed now")
/// reshaped the machine after geoff and davemo88's v1-review notes, with
/// the measure reworked first (standing rule 1 — see measure.qnt's header
/// for the rank/radix re-derivation). In this file:
///   - "Frozen removed. Draft -> Ready/Blocked": PDraft is the only
///     authoring phase; decideFreeze/decideUnfreeze are DELETED and
///     decideRelease goes Draft -> PPending directly — a deliberate
///     deviation from v1's table lines 22/24/26, recorded at decideRelease.
///   - "stalled should be rolled into escalated": PEscalated is THE
///     parked-with-open-human-task phase; the revalidation park and the
///     revoke cascade's wall both land there, distinguished by `reason`,
///     and the old stalled-retry is now decideOpRetry's RPending arm
///     (still free — nothing was ever spent; still CHURN).
///   - "task state machine": tasks carry the explicit TaskState lifecycle
///     (measure.qnt) — a structuring change only; every decider's behavior
///     is unchanged and the PR 3 tests pass with mechanical updates.
///   - "agentic dispatcher modeled (not FIFO)": the dispatch chooser is
///     documented AS the dispatcher's agency — see the `dispatch` action.
///   - "rework budget ... into impl / middleware": REWORK_POLICY
///     (ReworkPolicy, the GatePricing pattern) replaces the bare budget
///     const; the account stays on Ticket as documented policy state.
///   - gas rename: GAS / gasLeft / gas_exhausted / RsGasExhausted — the
///     charter's required "deadline" account under its honest name.
///
/// PR 3 (task-records depth; gate: phase-outcome combinators pinned by a
/// real eval/vocabulary example) is IN. The intake question
/// `eval/vocabulary` was never answered (charter §3), so the real example
/// is EXTRACTED FROM CHUGGERNAUT ITSELF — docs/spec.md §3.3 "Staged
/// progression" + §1.2 Task, the golden fixture
/// staged_eval_short_circuit.yaml (replayed by specs/chuggernaut/tests/
/// conformance/conformance_staged_eval_short_circuit_test.qnt, whose
/// header marks the staged content as gated on exactly this model), and
/// docs/trace-conformance.md §2 — standing in until the intake answer
/// confirms or overrides it (README, PR 3 section). What it gives us:
///   - a ticket's eval program is an ORDERED LIST OF STAGES; within a stage
///     the tasks fan out in parallel (evaluator `stage:`, default 0);
///   - a stage completes when all its tasks are terminal; every required
///     evaluator passing CREATES the next stage's tasks;
///   - any required failure SHORT-CIRCUITS: later stages are "skipped, not
///     failed, so no task records exist for them" and the reduce proceeds
///     immediately — into chuggy's existing rework/escalation economy;
///   - a rework cycle "restarts from the lowest stage — stages are
///     recomputed per cycle, never resumed mid-sequence";
///   - a single-stage program is byte-for-byte the flat fan-out — the
///     compatibility story that preserves PR 1-2's default shape;
///   - task records are a chronological, RETAINED log with sequential
///     per-ticket identity.
/// The program is DATA ON THE TICKET (charter §2: eval is data, not
/// machinery), authored — it arrives with the Draft, which is exactly why
/// authoring came first; decideEvalStageReduce below is the interpreter.
///
/// THE CITATIONS PR (docs/chuggy-notes-triage.md, "recorded for a later
/// PR"; the note verbatim: "allow passing evaluators to cite code they
/// care about to let them decide whether to rerun if evaluation must
/// rerun") is IN. Both sides abstract to region sets over 1..N_REGIONS:
/// a task's RESOLUTION carries a citation footprint (the completion event
/// grew a `cited` argument, environment-chosen like the verdict — an
/// evaluator's citation, or a work attempt's touch set), and the
/// interpreter's two eval-entry sites (the work-passed lowest-stage entry
/// and the stage advance) spawn SCOPED (measure.qnt spawnEvalScoped): a
/// position whose most recent retired incarnation PASSED citing a
/// nonempty footprint disjoint from the change since then is born
/// TSCarried — verdict carried over, evaluator not rerun — and everything
/// else respawns. The change footprint is DERIVED from the retained
/// record's work entries (standing rule 3; work groups delimit cycles),
/// never stored. Conservative defaults, each pinned in tests: silence is
/// not a free pass on either side (an evaluator that cited nothing
/// reruns; a work attempt that cited nothing blocks every carry), work
/// tasks always respawn (only evaluators cite), the failing evaluator
/// that caused a rework always respawns (a carry requires a PASS), and
/// first-time stage entry runs everything. Operator resumes are NOT
/// scoped — chuggernaut's own extracted Retry semantics is "a fresh eval
/// fan-out" (spec.md §1.2), kept verbatim at decideOpRetry. Skipped-stage
/// discipline stands: a short-circuit still leaves NO records for later
/// stages, and scoping never resurrects them — a carry happens only at a
/// spawn the interpreter performs anyway, reading only records that
/// exist. Carried verdicts are trace-visible twice over: the record entry
/// mark (TSCarried, citation intact) and the "CarryEvalVerdicts" effect
/// beside "SpawnEvalTasks" (either may appear alone — all-carried entries
/// spawn nothing running and reduce immediately). What is deliberately
/// NOT modeled: real diffs, region granularity, and evaluator HONESTY
/// about footprints — an evaluator that under-cites gets stale verdicts
/// carried; footprint trust is an implementation/policy concern, flagged
/// as an intake question (README).
///
/// What is deliberately NOT here (and which roadmap PR restores it):
///   - Batched + the merge queue it serves (PR 5) — the v1 table's Batched
///     rows (table.qnt lines 27-30) are deliberately not transcribed yet,
///     and the notes follow-up RE-SITED the state ("Batched from Ready or
///     Blocked"): when PR 5 lands it, Batched enters from PPending — the
///     released pre-work state whose Ready/Blocked split is derived — not
///     from authoring as v1's table had it (README, deliberately-absent
///     table); chuggernaut's STAGED MERGE GATE (spec.md §3.3 Merge Gate
///     item 3 — gate stages, the gate-fix fast path) defers WITH it;
///   - multi-repo (PR 4); merge-queue + landing mechanics (PR 5);
///   - scheduler/capacity: NO agent-slot count, NO FIFO ready queue —
///     charter §2 non-goals (no bespoke scheduler) plus the trusted fabric
///     axioms (quota/scheduling): dispatch is a nondet pick among Ready
///     tickets, K8s owns the rest;
///   - below-cycle retry machinery: NO attempt counter, NO per-task
///     budgets, NO work-retries wall — charter §2 non-goals ("no retry
///     machinery below the cycle"); chuggernaut's per-task `work_retries`/
///     `eval_retries` (spec.md §1.2) are exactly that machinery, so the
///     extracted vocabulary does NOT import them (README notes the skip);
///     container relaunches are the trusted `backoffLimit` fabric axiom,
///     so a Work task-set resolves at CYCLE level only;
///   - environment quiescence (v1's envActive/quiesce): the quiescence
///     theorem is §4's contested half — per-ticket liveness only, sketched via
///     measure descent.
module chuggy_domain {
  import chuggy_measure.* from "./measure"

  /// ARRIVAL BOUND (PR 2): at most N_TICKETS tickets ever arrive; ids are dense
  /// 1..count and never reused, so the live fleet is tickets.keys() ⊆
  /// 1..N_TICKETS. (PR 1 read this as a static graph size; authoring turned
  /// the static graph into bounded arrivals — small in mc instances so the
  /// state space stays small.)
  const N_TICKETS: int
  /// Task fan-out ceiling (PR 3 re-reading): the Work phase's single
  /// task-set width, AND the per-stage fan-out cap an authored eval program
  /// may declare (charter §2 ticket anatomy: a SET of possibly-parallel
  /// tasks). PR 1-2 read this as the uniform size of every set; stages made
  /// widths per-stage data, so the const became their bound — the measure's
  /// stageWeight radix needs exactly this cap.
  const N_TASKS: int
  /// Eval-rework pricing (notes PR: the bound is a POLICY PARAMETER on the
  /// GatePricing pattern, not a core-entity constant — RWBudget(n) is the
  /// only branch for now, argued at the type in measure.qnt; the account
  /// it grants is middleware-owned policy state, documented at
  /// Ticket.reworkLeft).
  const REWORK_POLICY: ReworkPolicy
  /// Gas per ticket — the charter's REQUIRED account (§2 economy/deadline),
  /// renamed by the notes PR ("what is deadline left": a spend meter, not
  /// a clock). REQUIRED >= 1: a gasless graph is invalid — init admits no
  /// state otherwise; the charter row's force is unchanged.
  const GAS: int
  /// Gate-rework pricing (charter §2: a parameter, not a constant; both
  /// branches instantiated in mc/mc_chuggy.qnt).
  const GATE_PRICING: GatePricing
  /// Operator-retry metering (charter §2: configurable per deployment,
  /// default charge — mc instantiates RetryCharged, plus a RetryFree
  /// instance so the free-resume churn path stays exercised).
  const OP_RETRY_PRICING: RetryPricing
  /// PR 3: authored-program length cap — the measure's stage radix
  /// (Bounds.maxStages) and arrival's validity ceiling. Real programs are
  /// short by construction in the extracted vocabulary (chuggernaut
  /// spec.md §3.3: stages are declared per evaluator; even the synthesized
  /// approval gate sits at max+1) — the cap exists for the radix argument,
  /// not as domain vocabulary.
  const MAX_STAGES: int
  /// Citations PR: the size of the abstract region universe citations
  /// range over — real citations are code regions; the model bounds them
  /// to opaque ids 1..N_REGIONS so footprints stay finite nondet choices
  /// (small in mc instances: the citation draw multiplies task-completion
  /// branching by 2^N_REGIONS). NOT a measure bound: no digit reads it
  /// (measure.qnt, citations header). The no-citation world is expressed
  /// by evaluators citing Set() (which means "rerun me"), not by an empty
  /// universe — init requires the universe to exist.
  const N_REGIONS: int

  /// The citation universe (citations PR): every footprint — evaluator
  /// citation or work touch set — is a subset of this
  /// (citationsWellFormed).
  pure val regions: Set[int] = 1.to(N_REGIONS)

  /// The measure's bounds, from this instance's consts.
  pure val bounds: Bounds = {
    reworkPolicy: REWORK_POLICY,
    nTasks: N_TASKS,
    maxStages: MAX_STAGES,
    gatePricing: GATE_PRICING
  }

  /// The stage vocabulary an author may draw from: any fan-out 1..N_TASKS,
  /// either combinator (both branches stay exercisable — the PR 1 lesson).
  pure val stageChoices: Set[Stage] =
    tuples(1.to(N_TASKS), Set(CUnanimousPass, CAnyPass))
      .map(t => { fanout: t._1, combinator: t._2 })

  /// Every WELL-FORMED authorable program: non-empty, at most MAX_STAGES
  /// stages, each stage from stageChoices. This set IS the arrival-refusal
  /// rule (programsWellFormed): the empty program, an oversized fan-out,
  /// and an overlong program are not in it, so no arrival can carry one —
  /// the same structural-refusal shape as dependableTickets for deps
  /// (decideArrive's callers guarantee membership; the `arrive` action
  /// draws from exactly this set).
  pure val validPrograms: Set[List[Stage]] =
    1.to(MAX_STAGES).fold(Set([]), (acc, _) =>
      acc.union(acc.map(p => stageChoices.map(s => p.append(s))).flatten()))
      .filter(p => p.length() >= 1)

  /// THE DEFAULT PROGRAM (charter §2 evaluation row: "default combinator:
  /// unanimous pass"; chuggernaut spec.md §3.3: every evaluator defaults to
  /// stage 0, and "a job whose evaluators all share one stage (the
  /// default) is byte-for-byte the single-fan-out behavior, and that is
  /// the compatibility story"): ONE stage, full fan-out, unanimous. A ticket
  /// carrying this program behaves exactly like the PR 1-2 machine —
  /// pinned in tests/chuggy_test.qnt. PR 3 retired PR 1's machine-wide
  /// combinator parameter in this program's favor: that const was the
  /// stand-in for eval-as-data; now that the combinator is data on the
  /// ticket record, a const would be exactly the "machinery" the charter row
  /// says eval is not.
  pure val defaultProgram: List[Stage] =
    [{ fanout: N_TASKS, combinator: CUnanimousPass }]

  /// The ticket-source seam, now CLOSED by PR 2 exactly as PR 1 promised:
  /// every ticket the machine ever holds is built here, and the only caller is
  /// decideArrive — a ticket is born a Draft (v1 vocabulary: authoring starts
  /// at Draft, table.qnt lines 21-22) with its full accounts, and reaches
  /// the released pipeline only through decideRelease. PR 3: the author's
  /// eval PROGRAM arrives with the Draft (eval is data; authoring came
  /// first precisely so programs would have an arrival to ride).
  pure def freshTicket(deps_: Set[int], prog: List[Stage]): Ticket = {
    phase: PDraft,
    deps: deps_,
    program: prog,
    tasks: Set(),
    record: [],
    spawned: 0,
    reworkLeft: reworkBudget(REWORK_POLICY),
    gateLeft: gateBudget(GATE_PRICING),
    gasLeft: GAS,
    resumeAt: RNone,
    reason: RsNone,
    landings: 0
  }

  // ==========================================================================
  // === Pure deciders ========================================================
  // ==========================================================================
  // v1's discipline (chug_decide): decide(view, event) -> Decision, never an
  // effect. Both §4 shapes reuse these unchanged.

  pure def withTicket(c: Core, j: int, jb: Ticket): Core =
    { ...c, tickets: c.tickets.set(j, jb) }

  /// The one funnel every phase flip goes through, recording exactly one
  /// transition (golden-trace shaped, standing rule 4). PR 3: from == to is
  /// a real row now — the stage advance records
  /// Evaluating -> Evaluating (chuggernaut spec.md §2.1 line 832).
  pure def move(c: Core, j: int, to_: Phase, label: str, effects_: List[str]): Decision =
    { rec: {
        label: label,
        transitions: [{ ticket: j, from: c.tickets.get(j).phase, to: to_ }],
        effects: effects_ },
      post: withTicket(c, j, { ...c.tickets.get(j), phase: to_ }) }

  /// A decision that changes nothing — the idempotent answer to duplicate
  /// deliveries (at-least-once fabric, charter §2: no-double-pods dropped,
  /// every effect idempotent).
  pure def noop(c: Core, label: str): Decision =
    { rec: { label: label, transitions: [], effects: [] }, post: c }

  // --- Authoring (PR 2, reshaped by the notes PR): arrival, release, ------
  // revoke. Vocabulary source: specs/chuggernaut/table.qnt (verbatim from
  // chuggernaut state.rs). Each decider cites the table row it adopts;
  // deviations are called out where they happen — including the notes PR's
  // deletion of the freeze/unfreeze pair (see decideRelease).

  /// A ticket ARRIVES as a Draft — the environment (an author) creates it.
  /// NOT a table edge: v1's table starts at Draft and has no birth row (its
  /// tickets exist statically); the arrival action is chuggy-new, forced by
  /// authoring being the ticket source now (charter §2 first-class rank #1).
  /// Ids are dense and never reused (next id = fleet size + 1), which keeps
  /// every ascending-id fold below correct. Dependencies may point at ANY
  /// live ticket, released or not (Draft deps block exactly like
  /// not-yet-Done ones) — but never at a tombstone: not a Revoked ticket, and
  /// not a ticket the cascade already parked behind one (Escalated with
  /// dependency_revoked — by cascadeSafety those two cases are EXACTLY the
  /// transitively-doomed tickets). The author cannot depend on either
  /// (authoring-time validation; admitting one would create a ticket doomed
  /// at birth, which cascadeSafety forbids anyone to hold un-parked — the
  /// first random invariant run caught precisely this). Callers guarantee
  /// deps_ ⊆ dependable ids (see `dependableTickets`).
  ///
  /// PR 3: the arrival also carries the ticket's EVAL PROGRAM, validated the
  /// same structural way — callers guarantee prog ∈ validPrograms, so an
  /// empty program, a zero/oversized fan-out, or an overlong program is
  /// REFUSED at authoring time: no reachable state holds one
  /// (programsWellFormed), rather than the interpreter defending against
  /// one mid-flight. The program is immutable after arrival, like deps.
  ///
  /// Dynamic-DAG boundary (charter §3): arrivals are AUTHOR actions — only
  /// the environment action `arrive` calls this decider, and no ticket-event
  /// decider creates tickets, so the ticket set grows only by authoring, never by
  /// tickets spawning tickets. Author commands (release/revoke) are also guarded
  /// by enablement, not absorbed as duplicates: authors are command
  /// sources, not the at-least-once fabric — only fabric events get
  /// idempotent stutter deciders.
  pure def decideArrive(c: Core, deps_: Set[int], prog: List[Stage]): Decision =
    val id = c.tickets.keys().size() + 1
    { rec: { label: "ticket-arrived", transitions: [], effects: ["CreateDraft"] },
      post: { ...c, tickets: c.tickets.put(id, freshTicket(deps_, prog)) } }

  /// Draft -> Pending (table line 21 `(Draft, Ready | Blocked | ...)`):
  /// the ticket enters the released pipeline. The table's Ready/Blocked
  /// targets collapse to PPending because the split is DERIVED (standing
  /// rule 3, the PR 1 decision) — it re-derives from deps the moment the
  /// phase lands. Descends (rank 5 -> 4). Charges nothing: the Working
  /// boundary still meters actual work entry (standing rule 2).
  ///
  /// DELIBERATE DEVIATION (notes PR, docs/chuggy-notes-triage.md: "Frozen
  /// removed. Draft -> Ready/Blocked"): the v1 table's Frozen rows — line
  /// 22 `(Draft, Frozen)` (freeze), line 24 `(Frozen, Draft)` (the
  /// unfreeze edit loop), line 26 `(Frozen, Ready | Blocked)` (release
  /// from Frozen) — are NOT transcribed. PR 2 carried all three; the note
  /// deletes the phase, so release now leaves from Draft alone and the
  /// content-pinning freeze step is below the model's grain (an
  /// implementation concern of the authoring surface, like Draft content
  /// edits always were). Consequence for the liveness sketch: the unfreeze
  /// loop was the AUTHORING churn set's only unbounded climber, so its
  /// removal leaves arrival as that set's only climbing member
  /// (measure.qnt AUTHORING).
  pure def decideRelease(c: Core, j: int): Decision =
    move(c, j, PPending, "ticket-released", [])

  /// Revoke + THE CASCADE (the PR 2 gate). Table provenance for the revoke
  /// edge itself: lines 47-48 `(_, Revoked) => true` — every non-terminal
  /// phase may be revoked (the caller's guard, revocableIn) — and lines
  /// 45-46 `(Done | Revoked, Revoked) => false` — the terminals are
  /// absorbing, so no decider ever moves a ticket OUT of PRevoked (invariant
  /// terminalsAbsorbing). The revoked ticket settles: rank -> 0, live task set
  /// RETIRED into the record (PR 3: still-running tasks force-closed as
  /// TCancelled — chuggernaut spec.md §1.2 "Revoke closes tasks"; the
  /// record itself is KEPT: provenance survives the author's settlement,
  /// "Revoked runs nothing" ≠ "Revoked remembers nothing"), accounts
  /// UNTOUCHED — revoke charges no gas and spends no budget in either
  /// direction — and reason/resumeAt cleared: PRevoked opens NO human task
  /// (hasOpenHumanTask excludes it; revocation is the author's settled
  /// choice, like PDone).
  ///
  /// THE CASCADE, designed here (v1 never answered it — model-status §6b
  /// lists "revoke fan-out cascade" as unanswerable): a ticket whose dep chain
  /// contains a revoked ticket can never unblock (a dep that is not Done
  /// blocks, and PRevoked never becomes PDone). Of the two candidate
  /// semantics —
  ///   (a) transitive cascade-REVOKE: dependents are revoked too;
  ///   (b) PARK: dependents wait on the desk behind a named wall —
  /// chuggy picks (b), ATOMICALLY in this decision, for two charter
  /// reasons. First, revocation is a per-ticket authorial choice: (a) would
  /// let one author's revocation silently destroy OTHER tickets with no human
  /// decision and no desk trace (a cascade-revoked ticket opens no task — the
  /// exact invisibility the §2 visibility row forbids). Second, parking
  /// preserves deskVisibility structurally: every doomed dependent gets its
  /// OWN open task (RsDependencyRevoked) telling a human "your dependency
  /// was revoked; settle me" — and the human settles it by revoking it (its
  /// desk revoke is the AUTHORING flat member in measure.qnt). The park is
  /// atomic with the revoke — same decision, one StepRecord — so
  /// cascadeSafety holds in EVERY reachable state, never just eventually.
  ///
  /// Why parking only PDraft/PPending dependents is exhaustive: a
  /// transitive dependent of a revocable (hence non-Done) ticket can never
  /// have dispatched — dispatch needs all deps Done, Done is absorbing, and
  /// the revoked ancestor is not Done — so every dependent is still
  /// pre-flight: Draft, Pending, or already settled by an earlier
  /// cascade (PEscalated RsDependencyRevoked) or by its own author
  /// (PRevoked). The filter parks exactly the first two and leaves the
  /// already-settled alone (no duplicate transitions). Pre-flight tickets hold
  /// no live tasks, so the cascade retires nothing on the parked side.
  /// The parked wall stamps NO resume point (resumeAt stays RNone): deps
  /// are immutable, so no modeled resume exists — the wall's only exit is
  /// revoke (retryableIn; the deliberate table-line-44 deviation).
  pure def decideRevoke(c: Core, j: int): Decision =
    val n = c.tickets.keys().size()
    // Transitive dependents of j: deps point strictly downward, so one
    // ascending pass decides each id after all its deps (same shape as the
    // stuckSet/coveredSet folds).
    val doomedByJ = range(1, n + 1).foldl(Set(), (dset, k) =>
      if (c.tickets.get(k).deps.contains(j) or
          c.tickets.get(k).deps.exists(d => dset.contains(d)))
        dset.union(Set(k)) else dset)
    val parked = doomedByJ.filter(k =>
      val p = c.tickets.get(k).phase
      p == PDraft or p == PPending)
    // Ascending, deterministic order for the golden-trace record.
    val parkedList = range(1, n + 1).foldl([], (l, k) =>
      if (parked.contains(k)) l.append(k) else l)
    { rec: {
        label: "ticket-revoked",
        transitions:
          [{ ticket: j, from: c.tickets.get(j).phase, to: PRevoked }]
            .concat(parkedList.foldl([], (l, k) =>
              l.append({ ticket: k, from: c.tickets.get(k).phase, to: PEscalated }))),
        // "Revoke" for the revoked ticket; one OpenHumanTask per parked
        // dependent — and NONE for the revoked ticket itself.
        effects: ["Revoke"].concat(parkedList.foldl([], (l, k) =>
          l.append("OpenHumanTask"))) },
      post: { ...c, tickets: c.tickets.keys().mapBy(k =>
        if (k == j)
          { ...retireLive(c.tickets.get(k)), phase: PRevoked,
            resumeAt: RNone, reason: RsNone }
        else if (parked.contains(k))
          { ...c.tickets.get(k), phase: PEscalated, reason: RsDependencyRevoked }
        else c.tickets.get(k)) } }

  // --- Pure guard predicates (PR 2: shared by actions and unit tests) ------

  /// Table lines 45-48: every phase but the two absorbing terminals may be
  /// revoked.
  pure def revocableIn(c: Core, j: int): bool =
    c.tickets.get(j).phase != PDone and c.tickets.get(j).phase != PRevoked

  /// What one operator resume costs, by flavor (notes PR: with Stalled
  /// merged into Escalated, ONE decider — decideOpRetry — carries every
  /// resume, and this table is its pricing):
  ///   RPending    — 0 under BOTH meterings, deliberately: a pre-work park
  ///                 (revalidation_failed) spent nothing, so its resume
  ///                 charges nothing — the old stalled-retry's pricing,
  ///                 kept ("still free", the triage's resume-flavor row);
  ///                 the Working boundary still meters any actual re-entry
  ///                 (standing rule 2). CHURN in the measure.
  ///   RWorking    — 1 always: entry to Working always meters (standing
  ///                 rule 2), even under RetryFree.
  ///   REvaluating/RLanding — per OP_RETRY_PRICING (charter §2:
  ///                 configurable, default charge); RetryFree makes these
  ///                 the reproducible v1 livelock (model-status §5b).
  /// RNone falls through the wildcard but is unreachable: retryableIn
  /// refuses it and decideOpRetry's RNone arm is a guarded no-op.
  pure def resumeCharge(at: Resume): int =
    match at {
      | RPending => 0
      | RWorking => 1
      | _ => match OP_RETRY_PRICING { | RetryCharged => 1 | RetryFree => 0 }
    }

  /// May the operator Retry this parked ticket? Parked is PEscalated (the
  /// only desk phase now); a resume must EXIST (resumeAt != RNone) and be
  /// AFFORDABLE (a charging resume needs gas). The one wall with no
  /// modeled resume is dependency_revoked (resumeAt RNone) — a DELIBERATE
  /// RESTRICTION of v1's table line 44 (Stalled, Ready): deps are
  /// immutable in this model (no re-authoring machinery yet), so a retry
  /// could only re-enter Pending still doomed behind the same revoked dep
  /// — a lie to the desk and an immediate cascadeSafety hole. That wall's
  /// only modeled exit is revoke; dep re-authoring is future work (README,
  /// deliberately-absent table).
  pure def retryableIn(c: Core, j: int): bool = and {
    c.tickets.get(j).phase == PEscalated,
    c.tickets.get(j).resumeAt != RNone,
    resumeCharge(c.tickets.get(j).resumeAt) <= c.tickets.get(j).gasLeft
  }

  pure def depsDoneIn(c: Core, j: int): bool =
    c.tickets.get(j).deps.forall(k => c.tickets.get(k).phase == PDone)

  /// The derived waiting room (standing rule 3), as pure predicates over a
  /// Core so tests can pin them: a dep that is not Done blocks — including
  /// UNRELEASED deps (Draft, PR 2) and, transiently impossible but
  /// definitionally covered, revoked ones.
  pure def isReadyIn(c: Core, j: int): bool =
    c.tickets.get(j).phase == PPending and depsDoneIn(c, j)

  pure def isBlockedIn(c: Core, j: int): bool =
    c.tickets.get(j).phase == PPending and not(depsDoneIn(c, j))

  /// May the dispatcher launch ticket j? Ready (the derived waiting room)
  /// with gas to charge — entry to Working always meters (standing rule
  /// 2). Pending tickets have never spent gas (arrival grants the full
  /// GAS and authoring charges nothing), so the gas conjunct is
  /// structurally implied whenever init accepted the configuration; it is
  /// stated so the enablement is ONE predicate. HOISTED by the
  /// witness-hardening PR (review finding m6): this guard used to live
  /// inline in the `dispatch` action, and the witness drivers carried a
  /// copied expression of it — a copied guard drifts silently
  /// (strengthen the machine's and the stale copy keeps the drivers'
  /// "machine trace" claim alive while the machine refuses the step).
  /// Both the `dispatch` action and tests/chuggy_witness_test.qnt's
  /// doDispatch drivers now REFERENCE this definition; neither copies it.
  pure def dispatchableIn(c: Core, j: int): bool = and {
    isReadyIn(c, j),
    c.tickets.get(j).gasLeft > 0
  }

  /// Every task id ticket j has EVER issued — the delivery range the
  /// at-least-once fabric may name (live or retired; ids dense from
  /// firstTaskId, so this is exactly firstTaskId..nextTaskId-1). Shared,
  /// like dispatchableIn, by the `taskDone` action's nondet draw and the
  /// witness drivers' guards (tests/chuggy_witness_test.qnt), so the
  /// range is referenced on both sides, never copied.
  pure def deliverableTaskIds(c: Core, j: int): Set[int] =
    firstTaskId.to(nextTaskId(c.tickets.get(j)) - 1)

  /// Park a ticket on the human desk, naming the wall (vocabulary carried
  /// from v1; the charter §2 termination row commits the terminal, not the
  /// names) and where Retry resumes. The open desk task is DERIVED from
  /// the phase (hasOpenHumanTask, standing rule 3); "OpenHumanTask" is its
  /// trace-visible effect. Notes PR: this is THE park — the pre-work
  /// revalidation wall comes through here too (decideRevalFail, resume
  /// RPending), since Escalated is the one parked phase. PR 3: the failed
  /// set is RETIRED into the retained record, not dropped — every pipeline
  /// escalation is reached at a reduce, so the set is fully resolved and
  /// the TCancelled arm of retireLive never fires here; a pre-work park
  /// holds no tasks, so retireLive is a no-op for it.
  pure def escalate(c: Core, j: int, at: Resume, why: Reason, label: str): Decision =
    move(
      withTicket(c, j, { ...retireLive(c.tickets.get(j)), resumeAt: at, reason: why }),
      j, PEscalated, label, ["OpenHumanTask"])

  /// Ready -> Working: launch a cycle for the ticket THE DISPATCHER CHOSE.
  /// Charges one gas — EVERY entry to Working does (standing rule 2: no
  /// free re-entry; gas is the account that makes the graph valid at all).
  /// Work is ONE task-set phase (kasofsk's anatomy note; chuggernaut
  /// spec.md §1.2: one work task per cycle — Work is not staged), width
  /// N_TASKS, ids sequential within the ticket (PR 3).
  ///
  /// THE AGENTIC DISPATCHER (notes PR, "agentic dispatcher modeled (not
  /// FIFO)"): this decider is the dispatch decision made first-class — j
  /// is the CHOICE, and the chooser is the `dispatch` action's nondet pick
  /// among readyTickets. That pick is not incidental scheduler noise to be
  /// refined away: chuggy's dispatcher is itself agentic (the v1 note:
  /// "the dispatcher working with the ready q is not pure fifo popping,
  /// it's nondet outcome because the dispatcher is also agentic"), so ANY
  /// Ready ticket may be chosen next, and the `dispatch` StepRecord in the
  /// trace IS the dispatcher's decision event — an implementation
  /// conforms with any policy (LLM-driven, priority, whatever) because
  /// every policy refines unrestricted choice among Ready tickets. No
  /// policy-hook parameter is introduced: with exactly one honest default
  /// (unrestricted nondet) a GatePricing-style const would have one
  /// branch and nothing to compare — it enters only when a real competing
  /// policy needs modeling. No queue, no fairness — non-goals unchanged
  /// (charter §2).
  pure def decideDispatch(c: Core, j: int): Decision =
    val jb = c.tickets.get(j)
    move(
      withTicket(c, j, { ...spawnOn(jb, TKWork, N_TASKS),
        gasLeft: jb.gasLeft - 1 }),
      j, PWorking, "dispatch", ["SpawnWorkTasks"])

  /// A task-completion event for task `tid` of ticket j (Working or
  /// Evaluating — one decider for both phases' task sets). First write
  /// wins: if the task is not RUNNING IN THE LIVE SET, this is a duplicate
  /// or stale delivery and the decision is a state-identical no-op
  /// (STUTTER set in measure.qnt). PR 3 made the stale arm structural:
  /// task ids are unique across the ticket's whole history, so a completion
  /// for a task of an earlier stage or incarnation names an id that is
  /// already RETIRED into the record — no live match, no-op BY IDENTITY
  /// (PR 1 had to absorb cross-incarnation staleness into the nondet
  /// verdict of a respawned same-id task; that argument is now needed for
  /// nothing). No phase transition either way — task records resolve
  /// inside the phase.
  ///
  /// CITATIONS PR: the resolution event carries the CITATION FOOTPRINT
  /// beside the verdict — for an evaluator, the regions it cites (its
  /// claim; whether to TRUST it is implementation policy, README); for a
  /// work task, what the attempt touched. Environment-chosen like the
  /// verdict, stamped on the resolved entry (resolveTask), Set() = cited
  /// nothing (which scoping treats as citing/touching EVERYTHING — the
  /// conservative default). First-write-wins covers the footprint too: a
  /// duplicate with a different citation changes nothing, and a TSCarried
  /// task has no running match, so deliveries naming a carried id absorb
  /// here as duplicates (nobody is running to report).
  pure def decideTaskDone(
      c: Core, j: int, tid: int, v: Verdict, cited_: Set[int]): Decision =
    if (c.tickets.get(j).tasks.exists(t => t.id == tid and t.state == TSRunning))
      { rec: { label: "task-done", transitions: [], effects: [] },
        post: withTicket(c, j, { ...c.tickets.get(j),
          tasks: resolveTask(c.tickets.get(j).tasks, tid,
            match v { | VPass => TPassed | VFail => TFailed }, cited_) }) }
    else
      noop(c, "task-done-duplicate")

  /// The effects a scoped eval spawn records (citations PR), derived from
  /// the spawn's RESULT so the deciders and the derivation cannot drift:
  /// "SpawnEvalTasks" iff anything actually starts running,
  /// "CarryEvalVerdicts" iff any position was born TSCarried. The full
  /// respawn (every position running — every first-time entry, and every
  /// scoped entry under a full-intersection change) yields exactly
  /// ["SpawnEvalTasks"], byte-for-byte the pre-citations vocabulary — the
  /// degeneration story at the trace grain. An all-carried entry yields
  /// ["CarryEvalVerdicts"] alone: nothing runs, and the stage is
  /// immediately reducible (reducibleEval counts running tasks).
  pure def evalSpawnEffects(next_: Ticket, n: int): List[str] =
    val nRun = runningCount(next_.tasks)
    (if (nRun > 0) ["SpawnEvalTasks"] else [])
      .concat(if (nRun < n) ["CarryEvalVerdicts"] else [])

  /// The Working task set fully resolved: reduce the phase, at CYCLE level
  /// only. Work's phase-outcome combinator is UNANIMOUS PASS — no longer a
  /// placeholder: PR 3 pins it from the extracted vocabulary (chuggernaut
  /// spec.md §1.2: Work runs ONE task per cycle whose success is the
  /// phase's success — unanimous over a singleton; under kasofsk's
  /// parallel task-set generalization, charter §2 ticket anatomy, the
  /// faithful reading stays "every work task passed" — deliberately NOT
  /// taskPassed: work tasks never carry, so a TSCarried work task must
  /// never satisfy this reduce, structurally). A pass RETIRES the
  /// work set into the record and spawns the eval program's LOWEST stage
  /// (spec.md §3.3: "creates one task per evaluator in the lowest stage
  /// and fans them out in parallel") — SCOPED since the citations PR
  /// (spawnEvalScoped): on a RE-entry (any earlier incarnation of stage 0
  /// in the record — an eval rework, a gate rework, or a work respawn
  /// after work_failed; the rule keys on the record, not on why the cycle
  /// started, because cycle provenance is not stored — derive, don't
  /// store), positions whose retained passing verdicts cite footprints
  /// disjoint from everything the cycle's work attempts touched are
  /// CARRIED instead of rerun; a first-time entry runs everything. A
  /// failed task set is a failed CYCLE and escalates directly: the fabric
  /// has already retried each task below the cycle (trusted
  /// `backoffLimit`, charter §2 fabric row), and modeling attempts of our
  /// own is a §2 non-goal.
  pure def decideWorkReduce(c: Core, j: int): Decision =
    val jb = c.tickets.get(j)
    val retired = retireLive(jb)
    if (jb.tasks.forall(t => t.state == TSResolved(TPassed)))
      val fan = retired.program[0].fanout
      val next_ = spawnEvalScoped(retired, 0, fan, regions)
      move(
        withTicket(c, j, next_),
        j, PEvaluating, "work-passed", evalSpawnEffects(next_, fan))
    else
      escalate(c, j, RWorking, RsWorkFailed, "ticket-escalated work_failed")

  /// THE EVAL-PROGRAM INTERPRETER (PR 3 — the machinery; the program is
  /// data on the ticket). Fires when the CURRENT stage's task set is fully
  /// resolved (chuggernaut spec.md §3.3: "a stage completes when all its
  /// tasks reach a terminal state"), reads the stage's own combinator off
  /// the program, and takes exactly one of three edges:
  ///
  ///   - stage PASSES, later stage remains -> ADVANCE: retire the stage
  ///     into the record, spawn the next stage's fan-out. The
  ///     Evaluating -> Evaluating transition is chuggernaut's own table row
  ///     (spec.md §2.1 line 832: "a stage completes with every required
  ///     evaluator passing and a later stage remains: create the next
  ///     stage's evaluator tasks"). Descends: stagesLeft -1 dominates the
  ///     spawn (measure.qnt, the PR 3 digit).
  ///   - the FINAL stage passes -> the program passed: PLanding.
  ///   - stage FAILS -> SHORT-CIRCUIT (spec.md §3.3: "the later stages are
  ///     not created — they are skipped, not failed, so no task records
  ///     exist for them — and the eval reduce proceeds immediately"; the
  ///     golden fixture staged_eval_short_circuit.yaml pins exactly this:
  ///     stage-0 fails, stage 1 never launched): straight into the SAME
  ///     rework/escalation economy as PR 1-2 — a budgeted rework cycle
  ///     costs 1 reworkLeft + 1 gas and re-enters Work, and the next
  ///     Evaluation RESTARTS FROM THE LOWEST STAGE ("stages are recomputed
  ///     per cycle, never resumed mid-sequence"); an empty account parks
  ///     the ticket behind the existing wall (budget wall checked before the
  ///     gas wall, v1 convention). No new wall, no new account.
  ///
  /// Evaluator-infrastructure death is a TFailed INSIDE the stage — THE
  /// TICKET PAYS from the same accounts, no new machinery (charter §2
  /// eval/evaluator-failure). Deliberate abstraction from the extracted
  /// vocabulary, README-noted: chuggernaut §3.3 escalates required INFRA
  /// failures immediately (skipping rework) and distinguishes abort
  /// verdicts; chuggy folds all three into TFailed-fails-the-stage because
  /// the charter row prices them identically — flagged as a question for
  /// the intake confirmation, not silently adopted.
  pure def decideEvalStageReduce(c: Core, j: int): Decision =
    val jb = c.tickets.get(j)
    val s = evalStage(jb.tasks)
    val retired = retireLive(jb)
    if (combine(jb.program[s].combinator, jb.tasks))
      if (s + 1 < jb.program.length())
        // Citations PR: the advance spawn is SCOPED like the work-passed
        // entry — a re-entered stage (this cycle is recomputing stages an
        // earlier cycle already ran) carries the positions whose retained
        // passing verdicts are disjoint from the change; a stage the
        // record has never seen (including every stage a short-circuit
        // skipped: "skipped, not failed, so no task records exist for
        // them" — nothing to carry FROM, by construction) runs in full.
        val fan = retired.program[s + 1].fanout
        val next_ = spawnEvalScoped(retired, s + 1, fan, regions)
        move(
          withTicket(c, j, next_),
          j, PEvaluating, "eval-stage-passed", evalSpawnEffects(next_, fan))
      else
        move(
          withTicket(c, j, retired),
          j, PLanding, "eval-passed", ["EnqueueLanding"])
    else if (jb.reworkLeft > 0 and jb.gasLeft > 0)
      move(
        withTicket(c, j, { ...spawnOn(retired, TKWork, N_TASKS),
          reworkLeft: jb.reworkLeft - 1,
          gasLeft: jb.gasLeft - 1 }),
        j, PWorking, "rework-started eval_failure", ["SpawnWorkTasks"])
    else if (jb.reworkLeft == 0)
      escalate(c, j, REvaluating, RsReworkBudgetExhausted,
        "ticket-escalated rework_budget_exhausted")
    else
      escalate(c, j, REvaluating, RsGasExhausted,
        "ticket-escalated gas_exhausted")

  /// The landing resolves. Mechanics abstract (charter §2 landing row,
  /// deferred to PR 5) but OUTCOMES precisely named from day one: the two
  /// success effects AdvanceDefault and SquashMerge are distinct — v1's one
  /// conformance divergence lived exactly here. A landing success is the
  /// ticket's single landing effect (ghost `landings` counts it — the
  /// effect-exclusivity boundary). A landing failure re-enters work priced
  /// per GATE_PRICING: Budgeted(n) spends gate budget AND gas, DeadlineOnly
  /// spends gas alone (v1's shape); either wall parks the ticket with its own
  /// name. (Chuggernaut's own merge gate runs STAGED — spec.md §3.3 Merge
  /// Gate item 3 — but that structure is deferred to PR 5 with the gate
  /// itself; here the gate stays one abstract outcome.)
  pure def decideLand(c: Core, j: int, out: LandOutcome): Decision =
    match out {
      | LandAdvanceDefault =>
        move(
          withTicket(c, j, { ...c.tickets.get(j), landings: c.tickets.get(j).landings + 1 }),
          j, PDone, "ticket-done", ["AdvanceDefault"])
      | LandSquashMerge =>
        move(
          withTicket(c, j, { ...c.tickets.get(j), landings: c.tickets.get(j).landings + 1 }),
          j, PDone, "ticket-done", ["SquashMerge"])
      | LandFailed =>
        match GATE_PRICING {
          | Budgeted(_) =>
            if (c.tickets.get(j).gateLeft > 0 and c.tickets.get(j).gasLeft > 0)
              move(
                withTicket(c, j, { ...spawnOn(c.tickets.get(j), TKWork, N_TASKS),
                  gateLeft: c.tickets.get(j).gateLeft - 1,
                  gasLeft: c.tickets.get(j).gasLeft - 1 }),
                j, PWorking, "rework-started gate_failure", ["SpawnWorkTasks"])
            else if (c.tickets.get(j).gateLeft == 0)
              escalate(c, j, RLanding, RsGateBudgetExhausted,
                "ticket-escalated gate_budget_exhausted")
            else
              escalate(c, j, RLanding, RsGasExhausted,
                "ticket-escalated gas_exhausted")
          | DeadlineOnly =>
            if (c.tickets.get(j).gasLeft > 0)
              move(
                withTicket(c, j, { ...spawnOn(c.tickets.get(j), TKWork, N_TASKS),
                  gasLeft: c.tickets.get(j).gasLeft - 1 }),
                j, PWorking, "rework-started gate_failure", ["SpawnWorkTasks"])
            else
              escalate(c, j, RLanding, RsGasExhausted,
                "ticket-escalated gas_exhausted")
        }
    }

  /// A duplicate landing event for an already-Done ticket (at-least-once: a
  /// stale executor re-delivers). NO landing effect is emitted — this
  /// no-op IS the exactly-once-at-the-landing-boundary claim; the
  /// landingExclusive invariant checks it (charter §2 exclusivity +
  /// fabric rows).
  pure def decideLandDuplicate(c: Core, j: int): Decision =
    noop(c, "land-duplicate")

  /// Ready -> Escalated behind the revalidation wall: the world changed
  /// under a ticket before it ever ran (static config no longer valid). Free
  /// — nothing was spent — and the desk opens. Notes PR ("stalled should
  /// be rolled into escalated"): this used to be its own PStalled phase;
  /// now it is a PARK like any other — Escalated with a pre-work reason
  /// and the pre-work resume point (RPending: an operator retry returns
  /// the ticket to Pending, where Ready/Blocked re-derive — never to a
  /// pipeline phase, because it never entered one). The OTHER pre-work
  /// wall is the cascade's dependency_revoked (decideRevoke) — which,
  /// unlike this one, is NOT retryable (retryableIn: resumeAt RNone).
  pure def decideRevalFail(c: Core, j: int): Decision =
    escalate(c, j, RPending, RsRevalidationFailed,
      "ticket-escalated revalidation_failed")

  /// Operator Retry on a parked ticket: resume at the point the wall stamped,
  /// metered by resumeCharge (charter §2: configurable, default charge —
  /// see the pricing table there). Notes PR: with Stalled merged into
  /// Escalated this is THE operator resume — one decider, four flavors,
  /// one trace label ("operator-retry"; the flavor is visible in the
  /// transition's target):
  ///   RPending (the old stalled-retry, now a resume flavor per the
  ///     triage): back to Pending — Blocked/Ready re-derive — charging
  ///     nothing under either metering (nothing was ever spent; the
  ///     Working boundary still meters actual re-entry). CHURN in the
  ///     measure, exactly as before the merge.
  ///   RWorking: respawn the work set; always pays gas — the v1 lesson
  ///     (model-status §5b: free resumes defeat the bound) priced in.
  ///   REvaluating: A FRESH FAN-OUT OF THE LOWEST STAGE (PR 3 —
  ///     chuggernaut spec.md §1.2 escalation Retry: "re-enter Evaluation
  ///     against the intact branch ... with a fresh eval fan-out"; stages
  ///     are never resumed mid-sequence, §3.3). New ids: the retried tasks
  ///     are NEW records, the failed ones stay retired in the log.
  ///     Deliberately NOT scoped by citations (spawnOn, not
  ///     spawnEvalScoped): "a fresh eval fan-out" is the extracted
  ///     vocabulary verbatim, and an operator resume models no new work
  ///     attempt whose change could license a skip — recompute-all is the
  ///     conservative superset (scoping this seam is a possible later
  ///     refinement, gated on the intake eval/vocabulary confirmation).
  ///   RLanding: re-enqueue the landing.
  /// Under RetryFree the Evaluating/Landing resumes join the CHURN set —
  /// v1's livelock kept reproducible by configuration.
  pure def decideOpRetry(c: Core, j: int): Decision =
    val jb = c.tickets.get(j)
    val resumed = { ...jb,
      reason: RsNone, resumeAt: RNone,
      gasLeft: jb.gasLeft - resumeCharge(jb.resumeAt) }
    match jb.resumeAt {
      | RPending =>
        move(withTicket(c, j, resumed), j, PPending, "operator-retry", [])
      | RWorking =>
        move(withTicket(c, j, spawnOn(resumed, TKWork, N_TASKS)),
          j, PWorking, "operator-retry", ["SpawnWorkTasks"])
      | REvaluating =>
        move(withTicket(c, j, spawnOn(resumed, TKEval(0), jb.program[0].fanout)),
          j, PEvaluating, "operator-retry", ["SpawnEvalTasks"])
      | RLanding =>
        move(withTicket(c, j, resumed), j, PLanding, "operator-retry", ["EnqueueLanding"])
      | RNone =>
        // Unreachable: retryableIn refuses a ticket with no modeled resume
        // (the dependency_revoked wall — its only exit is revoke).
        noop(c, "operator-retry-unreachable")
    }

  // ==========================================================================
  // === State + actions ======================================================
  // ==========================================================================

  var tickets: int -> Ticket
  /// The last decision's StepRecord — the golden-trace-shaped observation
  /// (standing rule 4: the model emits golden traces from day one).
  var lastStep: StepRecord
  /// GHOST: sysMeasure of the PREVIOUS state, written by every action, read
  /// only by stepDescends.
  var prevMeasure: int
  /// GHOST (PR 3): the PREVIOUS state's retained task records, per ticket —
  /// written by every action, read only by recordMonotone (the
  /// retained-record monotonicity invariant needs one step of history,
  /// exactly like stepDescends needs prevMeasure).
  var prevRecords: int -> List[Task]

  val core: Core = { tickets: tickets }
  val currentMeasure: int = sysMeasure(bounds, tickets)
  /// The current records snapshot the ghost carries forward each step.
  val currentRecords: int -> List[Task] =
    tickets.keys().mapBy(j => tickets.get(j).record)

  /// The live fleet (PR 2): ids are dense 1..size and never reused
  /// (invariant idsDense), so ascending-id folds below stay correct. PR 1's
  /// static `allTickets = 1.to(N_TICKETS)` became this — N_TICKETS is now the
  /// arrival BOUND, not the fleet size.
  val liveTickets: Set[int] = tickets.keys()

  action apply(d: Decision): bool = all {
    tickets' = d.post.tickets,
    lastStep' = d.rec,
    prevMeasure' = currentMeasure,
    prevRecords' = currentRecords
  }

  // --- Derived waiting room (standing rule 3: derive, don't store) ---------
  // Blocked and Ready are PREDICATES over deps + record, not phases. v1
  // stored both; chuggy stores only PPending and derives the split, so the
  // unblock cascade disappears entirely — there is no Blocked->Ready edge
  // to model or to get wrong. (The open-human-task flag is derived too:
  // measure.qnt hasOpenHumanTask; PR 3's eval-stage index is derived from
  // the live set's kind marks: measure.qnt evalStage.) PR 2 extends them
  // for free: an UNRELEASED dep (a Draft) is simply a dep that is not
  // Done, so it blocks with no new machinery; the pure bodies live with
  // the deciders (isReadyIn/isBlockedIn) so unit tests can pin exactly
  // that.

  def isReady(j: int): bool = isReadyIn(core, j)

  def isBlocked(j: int): bool = isBlockedIn(core, j)

  // --- Enablement sets ------------------------------------------------------

  /// Room for one more arrival (the N_TICKETS arrival bound keeps the state
  /// space finite; ids dense, never reused).
  val canArrive: bool = liveTickets.size() < N_TICKETS
  /// Tickets a new arrival may depend on: no tombstones — neither Revoked nor
  /// cascade-parked (which, by cascadeSafety, is exactly the
  /// transitively-doomed set; decideArrive's doc has the argument).
  val dependableTickets: Set[int] = liveTickets.filter(k => and {
    tickets.get(k).phase != PRevoked,
    not(tickets.get(k).phase == PEscalated and tickets.get(k).reason == RsDependencyRevoked)
  })
  /// The only authoring phase (notes PR: Frozen removed), hence the only
  /// releasable set — table line 21; the Frozen release row (line 26) died
  /// with the phase (deviation recorded at decideRelease).
  val draftTickets: Set[int] = liveTickets.filter(j => tickets.get(j).phase == PDraft)
  /// Every non-terminal may be revoked (table.qnt lines 45-48).
  val revocableTickets: Set[int] = liveTickets.filter(j => revocableIn(core, j))
  val readyTickets: Set[int] = liveTickets.filter(j => isReady(j))
  /// Tickets whose task set can receive completion events (real or duplicate).
  val taskPhaseTickets: Set[int] =
    liveTickets.filter(j => tickets.get(j).phase == PWorking or tickets.get(j).phase == PEvaluating)
  val reducibleWork: Set[int] =
    liveTickets.filter(j => tickets.get(j).phase == PWorking and runningCount(tickets.get(j).tasks) == 0)
  val reducibleEval: Set[int] =
    liveTickets.filter(j => tickets.get(j).phase == PEvaluating and runningCount(tickets.get(j).tasks) == 0)
  val landingTickets: Set[int] = liveTickets.filter(j => tickets.get(j).phase == PLanding)
  val doneTickets: Set[int] = liveTickets.filter(j => tickets.get(j).phase == PDone)
  /// Parked tickets the operator may Retry (retryableIn: a modeled resume
  /// exists and is affordable). Under RetryCharged a charging resume with
  /// zero gas parks the ticket permanently (v1's retryableEscalated corner);
  /// the pre-work RPending flavor is free, so a revalidation park is
  /// always retryable; the dependency_revoked wall never is (resumeAt
  /// RNone — its only exit is revoke).
  val retryableEscalated: Set[int] = liveTickets.filter(j => retryableIn(core, j))

  /// No machine, operator, or author action can move anything. PR 2 shrank
  /// this dramatically: revoke is enabled on EVERY non-terminal (table
  /// lines 47-48), so unretryable parks and doomed Pending chains are
  /// all still actionable — the only true dead end is a
  /// fully-arrived fleet in which every ticket is settled in a terminal
  /// (Done or Revoked). The `settled` stutter covers exactly that state so
  /// runs never deadlock.
  val quiet: bool = and {
    not(canArrive),
    liveTickets.forall(j => tickets.get(j).phase == PDone or tickets.get(j).phase == PRevoked)
  }

  // --- init -----------------------------------------------------------------

  /// The fleet starts EMPTY (PR 2): authoring is the ticket source now —
  /// PR 1's static nondet DAG is fully replaced by `arrive`, which grows
  /// the fleet one Draft at a time through the freshTicket seam (deps still
  /// acyclic by construction: they may only point at already-arrived,
  /// strictly smaller ids).
  /// The `GAS >= 1` conjunct is the charter's REQUIRED-deadline row (§2
  /// economy/deadline — the account the notes PR renamed to gas) as a
  /// validity condition: a gasless instantiation has NO initial state —
  /// the graph is invalid, not merely unmetered (every arrival funds a
  /// ticket from this grant, so checking it here still gates every ticket ever
  /// created). PR 3 adds `MAX_STAGES >= 1`: a machine that admits no
  /// well-formed eval program admits no tickets either.
  action init = all {
    GAS >= 1,            // charter §2 economy/deadline: required, now named gas
    N_TASKS >= 1,        // well-formedness: a phase carries a real task set
    N_TICKETS >= 1,         // the arrival bound must admit at least one ticket
    MAX_STAGES >= 1,     // PR 3: at least one authorable program must exist
    N_REGIONS >= 1,      // citations PR: the region universe must exist
    reworkBudget(REWORK_POLICY) >= 0,
    gateBudget(GATE_PRICING) >= 0,
    tickets' = Map(),
    lastStep' = { label: "init", transitions: [], effects: [] },
    prevMeasure' = 0,
    prevRecords' = Map()
  }

  // --- actions --------------------------------------------------------------

  /// A new ticket arrives as a Draft (the environment/author acts), deps a
  /// nondet subset of DEPENDABLE live tickets — released or not (unreleased
  /// deps block via the derived waiting room; tombstones are refused at
  /// authoring time, see decideArrive/dependableTickets) — and (PR 3) its
  /// eval PROGRAM a nondet pick among the WELL-FORMED programs: the
  /// machine explores every authorable program, and ill-formed ones are
  /// refused structurally (validPrograms is the refusal rule). AUTHORING
  /// set in the measure: climbs by the fresh Draft's whole ticketMeasure,
  /// bounded by N_TICKETS.
  action arrive = all {
    canArrive,
    nondet deps_ = dependableTickets.powerset().oneOf()
    nondet prog = validPrograms.oneOf()
    apply(decideArrive(core, deps_, prog))
  }

  /// Author releases a Draft into the pipeline (table line 21;
  /// Ready/Blocked re-derive). Descends: rank 5 -> 4. There is no freeze
  /// or unfreeze action any more — the notes PR removed Frozen (deviation
  /// recorded at decideRelease), so release is authoring's only
  /// phase-level act after arrival.
  action release = all {
    draftTickets.size() > 0,
    nondet j = draftTickets.oneOf()
    apply(decideRelease(core, j))
  }

  /// Author revokes any non-terminal ticket (table lines 45-48); the atomic
  /// cascade parks every pre-flight transitive dependent with its own desk
  /// task (decideRevoke — the PR 2 gate).
  action revoke = all {
    revocableTickets.size() > 0,
    nondet j = revocableTickets.oneOf()
    apply(decideRevoke(core, j))
  }

  /// Ready -> Working: THE AGENTIC DISPATCHER'S PICK (notes PR). The
  /// nondet choice below IS the dispatcher — an agentic component whose
  /// selection among Ready tickets is a real decision, not scheduler noise
  /// (see decideDispatch's header for the full agency note); the recorded
  /// `dispatch` step is its decision event in the golden trace.
  /// Scheduling/quota below the pick stays trusted fabric (charter §2
  /// non-goals: no bespoke scheduler) — no slot count, no queue order, no
  /// fairness. Pending tickets have never spent gas (arrival grants the full
  /// GAS and authoring charges nothing), so gas >= 1 here whenever init
  /// accepted the configuration; the guard keeps it structural — stated
  /// once, in dispatchableIn, which the witness drivers reference too
  /// (guards are shared, never copied — see dispatchableIn's header).
  action dispatch = all {
    readyTickets.size() > 0,
    nondet j = readyTickets.oneOf()
    all {
      dispatchableIn(core, j),
      apply(decideDispatch(core, j))
    }
  }

  /// A task-completion event arrives for ANY task the ticket EVER SPAWNED —
  /// live (real resolution or duplicate of a resolved one) or already
  /// retired to the record (a stale delivery from an earlier stage or
  /// incarnation). One action models all of it because the fabric is
  /// at-least-once: the machine cannot choose to not receive duplicates.
  ///
  /// Duplicate-adversary SCOPE (PR 3 extension of the PR 1 note): the tid
  /// range below (deliverableTaskIds — the shared definition the witness
  /// drivers reference too) is the ticket's ENTIRE task history — ids are sequential
  /// within the ticket and never reused (chuggernaut spec.md §1.2), so a
  /// stale completion from an earlier STAGE or incarnation names a retired
  /// id and no-ops BY IDENTITY (decideTaskDone finds no live running
  /// match). This RETIRES PR 1's weaker absorption argument (a stale
  /// same-id completion was indistinguishable from a fresh nondet verdict
  /// on the respawned set) — staleness is now absorbed structurally, and
  /// the only remaining first-write-wins case is a duplicate delivery for
  /// a LIVE resolved task. A stale landing SUCCESS still implies a success
  /// occurred, and PDone is absorbing (landDuplicate). The observed/actual
  /// split that would make mid-rework duplicates dangerous — a decider
  /// acting on a stale VIEW — is exactly the deferred §4 refinement layer
  /// (reconcile vs journaled-actor), not this shared domain layer. PR 2's
  /// deferred corner stands: a ticket revoked OUT of PLanding after
  /// "EnqueueLanding" was emitted could race an in-flight merge — in-model
  /// revokedNeverLands holds because no action delivers a landing
  /// resolution to a revoked ticket; the real revoke/merge race is deferred
  /// with landing mechanics (PR 5) and the §4 refinement layer.
  /// Citations PR: the completion event also carries a nondet CITATION
  /// FOOTPRINT — any subset of the region universe, the environment's
  /// choice exactly like the verdict (an evaluator's citation claim, or a
  /// work attempt's touch report; Set() is the silent resolution both
  /// conservative defaults key on). The adversary that always draws the
  /// full universe (or always Set() on work tasks) is the degeneration
  /// story: every spawn recomputes everything, pre-citations behavior
  /// byte for byte.
  action taskDone = all {
    taskPhaseTickets.size() > 0,
    nondet j = taskPhaseTickets.oneOf()
    nondet tid = deliverableTaskIds(core, j).oneOf()
    nondet v = Set(VPass, VFail).oneOf()
    nondet cited_ = regions.powerset().oneOf()
    apply(decideTaskDone(core, j, tid, v, cited_))
  }

  action workReduce = all {
    reducibleWork.size() > 0,
    nondet j = reducibleWork.oneOf()
    apply(decideWorkReduce(core, j))
  }

  /// The current eval STAGE's task set fully resolved: run the interpreter
  /// over the ticket's authored program (advance / pass / short-circuit —
  /// decideEvalStageReduce).
  action evalReduce = all {
    reducibleEval.size() > 0,
    nondet j = reducibleEval.oneOf()
    apply(decideEvalStageReduce(core, j))
  }

  /// The landing resolves, nondet over the three named outcomes. No
  /// quiescence gate on LandFailed (v1 had envActive) — the environment
  /// layer is deferred with §4's contested quiescence theorem.
  action land = all {
    landingTickets.size() > 0,
    nondet j = landingTickets.oneOf()
    nondet out = Set(LandAdvanceDefault, LandSquashMerge, LandFailed).oneOf()
    apply(decideLand(core, j, out))
  }

  /// At-least-once: a duplicate landing event for a Done ticket. Must emit
  /// nothing (landingExclusive checks it).
  action landDuplicate = all {
    doneTickets.size() > 0,
    nondet j = doneTickets.oneOf()
    apply(decideLandDuplicate(core, j))
  }

  /// Environment churn: revalidation fails at the moment a ticket would
  /// start. Same enablement as dispatch; which fires is the environment's
  /// choice.
  action revalFail = all {
    readyTickets.size() > 0,
    nondet j = readyTickets.oneOf()
    apply(decideRevalFail(core, j))
  }

  /// One resume action for every retryable park (notes PR: the pre-work
  /// resume is a decideOpRetry flavor, not its own action).
  action opRetry = all {
    retryableEscalated.size() > 0,
    nondet j = retryableEscalated.oneOf()
    apply(decideOpRetry(core, j))
  }

  /// The dead-end stutter (STUTTER set): keeps quiet states from
  /// deadlocking the simulator.
  action settle = all {
    quiet,
    tickets' = tickets,
    lastStep' = { label: "settled", transitions: [], effects: [] },
    prevMeasure' = currentMeasure,
    prevRecords' = currentRecords
  }

  action step = any {
    arrive,
    release,
    revoke,
    dispatch,
    taskDone,
    workReduce,
    evalReduce,
    land,
    landDuplicate,
    revalFail,
    opRetry,
    settle
  }

  // ==========================================================================
  // === Invariants ===========================================================
  // ==========================================================================
  // Inside the machine module (Quint 0.32: a separate module cannot see
  // instantiated vars — v1's hard-won structure), re-exposed to --main
  // scope through each mc instance's wildcard import.

  /// THE charter headline (§2 exclusivity, effect-only): exactly one
  /// landing per cycle, proved at the landing boundary and nowhere else —
  /// any number of task executions may duplicate (at-least-once fabric),
  /// but the landing effect is emitted exactly once per ticket, exactly when
  /// it is Done. "Per cycle" collapses to "per ticket" because a landing
  /// effect ends the ticket (PDone is absorbing) and failed landings emit no
  /// landing effect.
  val landingExclusive: bool = liveTickets.forall(j => and {
    tickets.get(j).landings <= 1,
    (tickets.get(j).landings == 1) iff (tickets.get(j).phase == PDone)
  })

  /// REVOKED NEVER LANDS (the PR 2 exclusivity extension): a revoked ticket
  /// has emitted no landing effect — and never will: PRevoked is absorbing
  /// (terminalsAbsorbing; table lines 45-46), no decider touches a revoked
  /// ticket's `landings`, and revoke from PLanding clears the ticket OUT of the
  /// landing boundary before any effect fires. Stated as its own named
  /// invariant because it is the PR 2 gate's exclusivity half, though
  /// state-wise it is a corollary of landingExclusive (landings = 1 iff
  /// Done, landings <= 1, Revoked != Done ⇒ landings = 0) — same
  /// stated-corollary treatment as deskVisibility.
  val revokedNeverLands: bool = liveTickets.forall(j =>
    (tickets.get(j).phase == PRevoked) implies (tickets.get(j).landings == 0))

  /// The two absorbing terminals never transition OUT (table lines 45-46:
  /// `(Done | Revoked, Revoked) => false` — first-match-wins over the
  /// revoke catch-all). Checked against the observed step record: no
  /// transition ever leaves PDone or PRevoked. (v1 proved
  /// terminalIsAbsorbing with Done alone carrying the dynamic content —
  /// model-status §6b; chuggy's PRevoked is reachable, so both terminals
  /// now carry it.)
  val terminalsAbsorbing: bool =
    lastStep.transitions.foldl(true, (b, t) =>
      b and t.from != PDone and t.from != PRevoked)

  /// The human desk is consistent. The reason-iff-parked half SURVIVES
  /// the notes PR's Stalled merge verbatim in spirit: a named wall iff
  /// parked — and parked now just IS PEscalated. The resumeAt half is
  /// where the merge earned its keep: a resume point iff a MODELED RESUME
  /// EXISTS — every wall stamps one (pipeline walls resume in-pipeline;
  /// the pre-work revalidation wall resumes to Pending, RPending) EXCEPT
  /// dependency_revoked, whose resumeAt stays RNone because its only
  /// modeled exit is revoke (retryableIn). (The open-task flag needs no
  /// conjunct — it is DERIVED from the phase, standing rule 3.) PR 2
  /// note: PRevoked passes both iffs with RsNone/RNone — "Revoked runs
  /// nothing" is this invariant plus tasksWellFormed doing their existing
  /// tickets over the phase.
  val deskConsistent: bool = liveTickets.forall(j => and {
    (tickets.get(j).phase == PEscalated) iff (tickets.get(j).reason != RsNone),
    (tickets.get(j).resumeAt != RNone) iff
      (tickets.get(j).phase == PEscalated and
       tickets.get(j).reason != RsDependencyRevoked)
  })

  /// The gate-budget wall exists only under Budgeted pricing (the wall
  /// vocabulary is v1-carried; the pricing parameter is charter §2's).
  val gateWallNamed: bool = match GATE_PRICING {
    | Budgeted(_) => true
    | DeadlineOnly => liveTickets.forall(j => tickets.get(j).reason != RsGateBudgetExhausted)
  }

  /// Every account stays a resource: bounded below by 0 (nothing
  /// overdraws) and above by its grant (nothing refunds). PR 2: revoke and
  /// the cascade move through here untouched — no gas charged, no budget
  /// spent, no refund (the no-budget-leakage half of the gate; the exact
  /// account-by-account equality is pinned in tests/chuggy_test.qnt).
  /// PR 3: stage advances move through here untouched too — stage progress
  /// is priced by the MEASURE's stage digit, not by any account; only a
  /// stage FAILURE (the short-circuit into rework) spends.
  val accountsBounded: bool = liveTickets.forall(j => and {
    tickets.get(j).gasLeft >= 0, tickets.get(j).gasLeft <= GAS,
    tickets.get(j).reworkLeft >= 0,
    tickets.get(j).reworkLeft <= reworkBudget(REWORK_POLICY),
    tickets.get(j).gateLeft >= 0, tickets.get(j).gateLeft <= gateBudget(GATE_PRICING)
  })

  /// The LIVE task set is exactly the current phase's anatomy (PR 3
  /// rewrite — this is also the STAGE-INDEX SANITY invariant):
  ///   - PWorking: the single work set — width N_TASKS, all TKWork;
  ///   - PEvaluating: ONE stage's fan-out — uniformly TKEval(s) for a
  ///     single s that indexes INTO the program (0 <= s < |program|), with
  ///     exactly that stage's declared width (the interpreter is running
  ///     the program as written, not improvising);
  ///   - every other phase: empty — dead live-task state is never carried
  ///     (derive-don't-store spirit; a Draft has not spawned,
  ///     PRevoked runs nothing).
  /// In the task phases the live ids are the contiguous run directly above
  /// the retired record (identity is sequential within the ticket — the
  /// at-least-once-by-identity argument needs exactly this), and TCancelled
  /// never appears live (it is a retirement mark, not an outcome events
  /// can deliver).
  val tasksWellFormed: bool = liveTickets.forall(j =>
    val jb = tickets.get(j)
    val start = jb.record.length() + firstTaskId
    if (jb.phase == PWorking) and {
      jb.tasks.size() == N_TASKS,
      jb.tasks.map(t => t.id) == start.to(start + N_TASKS - 1),
      jb.tasks.forall(t => t.kind == TKWork and t.state != TSResolved(TCancelled))
    } else if (jb.phase == PEvaluating)
      val s = evalStage(jb.tasks)
      and {
        s >= 0,
        s < jb.program.length(),
        jb.tasks.forall(t => t.kind == TKEval(s) and t.state != TSResolved(TCancelled)),
        jb.tasks.size() == jb.program[s].fanout,
        jb.tasks.map(t => t.id) == start.to(start + jb.tasks.size() - 1)
      }
    else jb.tasks == Set())

  /// THE RETAINED RECORD is well-formed (PR 3): entry i carries id i+1
  /// (the chronological log IS the identity order — chuggernaut spec.md
  /// §1.2, sequential within ticket, 1-indexed), nothing retired is still
  /// running — the record is the RESOLVED log, every entry TSResolved
  /// (TPassed/TFailed by verdict, TCancelled by revoke; the notes PR's
  /// explicit lifecycle makes this a constructor check, not an
  /// outcome-sentinel comparison) — and every retired eval task names a
  /// stage its ticket's program actually has (programs are immutable, so
  /// history never dangles).
  val recordWellFormed: bool = liveTickets.forall(j =>
    val jb = tickets.get(j)
    and {
      jb.record.indices().forall(i => jb.record[i].id == i + firstTaskId),
      jb.record.indices().forall(i => jb.record[i].state != TSRunning),
      jb.record.indices().forall(i =>
        match jb.record[i].kind {
          | TKWork => true
          | TKEval(s) => s >= 0 and s < jb.program.length()
        })
    })

  /// RETAINED-RECORD MONOTONICITY (PR 3): the task record is append-only
  /// history — against the previous state (ghost prevRecords), every ticket's
  /// record still starts with exactly what it was: nothing shrinks,
  /// nothing settled is ever rewritten (outcome, kind, or id). Checked
  /// step-wise like stepDescends; with it, "retained" is a theorem, not a
  /// convention. (Tickets are never deleted, so prevRecords' domain always
  /// survives into liveTickets.)
  val recordMonotone: bool = prevRecords.keys().forall(j => and {
    liveTickets.contains(j),
    tickets.get(j).record.length() >= prevRecords.get(j).length(),
    prevRecords.get(j).indices().forall(i =>
      tickets.get(j).record[i] == prevRecords.get(j)[i])
  })

  /// IDENTITY ACCOUNTING (PR 3, defense in depth): every task a ticket ever
  /// spawned is STILL somewhere — retired in the record or live in the
  /// set. The ghost spawn counter (measure.qnt Ticket.spawned, bumped by
  /// every spawnOn) equals record + live exactly, which makes
  /// history-unique sequential identity a machine-checked theorem: a
  /// mutant decider that DROPPED a task set instead of retiring it (e.g.
  /// escalate clearing tasks without the retireLive) would leave spawned
  /// strictly greater in the very next state — invisible to
  /// tasksWellFormed/recordWellFormed (both look at surviving state, not
  /// at what vanished), caught here.
  val idsAccounted: bool = liveTickets.forall(j =>
    tickets.get(j).spawned ==
      tickets.get(j).record.length() + tickets.get(j).tasks.size())

  /// PROGRAM WELL-FORMEDNESS (PR 3): every live ticket carries a well-formed
  /// eval program — non-empty, at most MAX_STAGES stages, every fan-out in
  /// 1..N_TASKS. Holding in EVERY reachable state is the arrival-refusal
  /// claim made durable: programs enter only through decideArrive (whose
  /// callers draw from validPrograms) and are never rewritten, so an
  /// ill-formed program is refused at authoring time or never exists.
  val programsWellFormed: bool = liveTickets.forall(j =>
    val p = tickets.get(j).program
    and {
      p.length() >= 1,
      p.length() <= MAX_STAGES,
      p.indices().forall(i => p[i].fanout >= 1 and p[i].fanout <= N_TASKS)
    })

  /// CITATION DISCIPLINE (citations PR), live set and record together:
  /// every footprint lives inside the region universe; a RUNNING task has
  /// no footprint (the citation is part of the resolution event — nothing
  /// is cited until something resolves); a WORK task is never TSCarried
  /// (work tasks always respawn — only evaluators cite, made structural
  /// here); and a TSCarried entry always carries the NONEMPTY citation
  /// that earned it (a carry without a citation would be a skip that
  /// silence bought — exactly what the conservative default forbids).
  /// Together with recordMonotone (entries compared whole, `cited`
  /// included, so a settled footprint is never rewritten) and idsAccounted
  /// (carried tasks are SPAWNED entries — spawnEvalScoped bumps the ghost
  /// by the full fan-out, so the equality holds verbatim over carries),
  /// this extends the record invariants to carried entries without
  /// weakening any of them.
  val citationsWellFormed: bool = liveTickets.forall(j =>
    val jb = tickets.get(j)
    and {
      jb.tasks.forall(t => and {
        t.cited.subseteq(regions),
        t.state == TSRunning implies t.cited == Set(),
        t.kind == TKWork implies t.state != TSCarried,
        t.state == TSCarried implies t.cited != Set()
      }),
      jb.record.indices().forall(i => and {
        jb.record[i].cited.subseteq(regions),
        jb.record[i].state == TSCarried implies and {
          jb.record[i].kind != TKWork,
          jb.record[i].cited != Set()
        }
      })
    })

  /// Arrival's DAG-by-construction survives every step (deps are never
  /// rewritten): each dep points at a known, strictly smaller id.
  val depsAcyclic: bool = liveTickets.forall(j =>
    tickets.get(j).deps.forall(d => liveTickets.contains(d) and d < j))

  /// PR 2 bookkeeping: ids are dense 1..size and never reused — what makes
  /// every ascending-id fold (stuckSet, coveredSet, revokeDoomed, the
  /// cascade's own pass) sound, and what keeps arrivals bounded by N_TICKETS.
  val idsDense: bool = and {
    liveTickets == 1.to(liveTickets.size()),
    liveTickets.size() <= N_TICKETS
  }

  // --- Visibility (charter §2 humans/invariant) -----------------------------

  /// Tickets whose own measure cannot descend without a human: parked on the
  /// desk, or Pending behind a chain containing a parked ticket. Built by
  /// ascending-id fold — deps point strictly downward, so each ticket's
  /// membership is decided after all its deps'.
  ///
  /// CONTESTED DEFINITION (charter §4 "Progressing"): "non-progressing" is
  /// defined here via measure-descent (geoff, humans/progressing =
  /// measure-descent — the termination measure doing double duty); kasofsk
  /// answered report-only. The invariant is STATED and checked with the
  /// measure-descent reading so it is at least a theorem candidate; whether
  /// it stays a checked theorem or becomes a dashboard report is the open
  /// §4 conversation.
  val stuckSet: Set[int] =
    range(1, liveTickets.size() + 1).foldl(Set(), (st, j) =>
      if (or {
        tickets.get(j).phase == PEscalated,
        tickets.get(j).phase == PPending and tickets.get(j).deps.exists(d => st.contains(d))
      }) st.union(Set(j)) else st)

  /// Tickets reachable from an open human task by walking dependency edges
  /// upward: the ticket's own desk task (derived — hasOpenHumanTask), or a
  /// desk task somewhere in its dependency chain.
  ///
  /// PR 2 note: PRevoked contributes NOTHING here (hasOpenHumanTask
  /// excludes it), so a dependent of a revoked ticket can only be covered by
  /// its OWN task — which is exactly what the atomic cascade guarantees
  /// (cascadeSafety below): parked dependents are PEscalated, hence in
  /// stuckSet AND covered by themselves; the folds needed no change for
  /// the authoring phase (a Draft is neither stuck — its progress is
  /// the author's, the named AUTHORING conditionality — nor covering).
  val coveredSet: Set[int] =
    range(1, liveTickets.size() + 1).foldl(Set(), (cov, j) =>
      if (hasOpenHumanTask(tickets.get(j)) or tickets.get(j).deps.exists(d => cov.contains(d)))
        cov.union(Set(j)) else cov)

  /// The visibility invariant (charter §2, adopted by both): every
  /// non-progressing ticket is reachable from an open human task. This is
  /// v1's §5c wedge hazard answered structurally: a ticket stuck behind an
  /// escalated dependency has no desk task of its own but IS reachable
  /// from its dependency's.
  ///
  /// NOTE: with the desk task derived from the phase, this is a structural
  /// COROLLARY of the stuck/covered definitions (induction over the dep
  /// order: every stuckSet base case is a desk phase, which is covered by
  /// hasOpenHumanTask; every inductive case rides the same dep edge in
  /// both folds). It is kept as a STATED, checked theorem — the charter
  /// row deserves a name in the invariant list — not as an independent
  /// check.
  val deskVisibility: bool = stuckSet.subseteq(coveredSet)

  // --- Cascade safety (THE PR 2 gate) ---------------------------------------

  /// Tickets transitively doomed by a revocation: a Revoked ticket somewhere in
  /// the dependency closure means this ticket can never unblock (a dep that
  /// is not Done blocks, and PRevoked never becomes PDone). Same
  /// ascending-id fold as stuckSet — deps point strictly downward.
  val revokeDoomed: Set[int] =
    range(1, liveTickets.size() + 1).foldl(Set(), (dset, j) =>
      if (tickets.get(j).deps.exists(d =>
            tickets.get(d).phase == PRevoked or dset.contains(d)))
        dset.union(Set(j)) else dset)

  /// CASCADE SAFETY (deskVisibility's style, revoke's content): every ticket
  /// transitively stuck behind a Revoked dep is parked with its own open
  /// human task (PEscalated, wall dependency_revoked — hasOpenHumanTask
  /// derives the task) or is itself revoked (its author settled it too).
  /// The roadmap gate's "eventually parked" strengthens to ALWAYS-parked
  /// because the cascade is atomic with the revoke (decideRevoke): there
  /// is no reachable in-between state where a doomed ticket waits invisibly.
  /// No ticket may wait invisibly forever behind a revoked dep — and since
  /// PRevoked opens no task (the author's settled choice), this invariant
  /// is the coverage deskVisibility cannot provide through the dep itself.
  /// NON-VACUITY: check.sh Stage 9b pins a machine trace where the
  /// cascade actually parks dependents (cascadeParkNever — deterministic
  /// since the witness-hardening PR, tests/chuggy_witness_test.qnt), and
  /// tests/chuggy_test.qnt walks a 3-ticket chain end-to-end.
  val cascadeSafety: bool = revokeDoomed.forall(j => or {
    tickets.get(j).phase == PRevoked,
    tickets.get(j).phase == PEscalated and tickets.get(j).reason == RsDependencyRevoked
  })

  // --- Measure descent (per-ticket liveness, sketched) -------------------------

  /// Well-foundedness half: the measure is bounded below (follows from
  /// accountsBounded, checked directly for the descent argument's own
  /// integrity).
  val measureNonNegative: bool = currentMeasure >= 0

  /// Descent half: every step strictly decreases sysMeasure EXCEPT the
  /// named STUTTER, CHURN, and AUTHORING sets (measure.qnt header) —
  /// checked by label against the ghost prevMeasure. Under the default
  /// RetryCharged pricing the only churn is the pre-work resume (which
  /// never charges — the notes PR folded the old stalled-retry in as an
  /// operator-retry flavor, pricing intact); with Frozen gone there is no
  /// unfreeze exemption any more, so release descends unconditionally.
  /// PR 3 adds NO exemption: the stage advance (eval-stage-passed) must
  /// strictly descend like any other progress step — that is the stage
  /// digit earning its keep.
  ///
  /// NORMATIVE CONVENTION (witness-hardening PR): NO EXEMPTION ARM
  /// WITHOUT A DETERMINISTIC WITNESS RUN THAT FIRES IT. An arm below that
  /// no deterministic machine trace exercises is either dead code or an
  /// unreviewed weakening of the descent theorem — and the missing run is
  /// the review hook that makes either visible: a PR that adds or widens
  /// an arm here must add the tests/chuggy_witness_test.qnt step that
  /// fires it (asserting allInvariants on that step, so the arm is proved
  /// to exempt exactly the climb it names). Current roster:
  ///   init                  — every run's first step;
  ///   task-done-duplicate   — free module (the re-delivered completion);
  ///   land-duplicate        — stage module (the stale landing success);
  ///   settled               — carry module (the quiet fleet's stutter);
  ///   operator-retry, RPending flavor
  ///                         — preWorkResumeClimbDeterministicTest;
  ///   operator-retry, RetryFree pipeline flavor
  ///                         — freeClimbDeterministicTest's climbing step;
  ///   ticket-arrived        — every run's arrivals;
  ///   ticket-revoked, desk-only flat
  ///                         — cascadeParkDeterministicTest's second revoke.
  val stepDescends: bool =
    val exempt = or {
      lastStep.label == "init",
      // STUTTER: state-identical delivery noise + the dead-end self-loop.
      lastStep.label == "task-done-duplicate",
      lastStep.label == "land-duplicate",
      lastStep.label == "settled",
      // CHURN: the uncharged operator-resume flavors (measure.qnt CHURN):
      // the PRE-WORK resume (Escalated -> Pending; free under BOTH
      // meterings — nothing was ever spent) and, under RetryFree only,
      // the Evaluating/Landing resumes (the Working resume always pays).
      and {
        lastStep.label == "operator-retry",
        or {
          lastStep.transitions.foldl(false, (b, t) => b or t.to == PPending),
          and {
            OP_RETRY_PRICING == RetryFree,
            lastStep.transitions.foldl(false, (b, t) => b or t.to != PWorking)
          }
        }
      },
      // AUTHORING (PR 2, measure.qnt header): a ticket entering the fleet
      // climbs by its whole fresh measure (bounded by the N_TICKETS arrival
      // cap) — the set's ONLY climbing member since the notes PR removed
      // the unfreeze edit loop with Frozen...
      lastStep.label == "ticket-arrived",
      // ...and a desk-only revoke is flat: every transition leaves a
      // settled-rank phase (Escalated -> Revoked) and the cascade parked
      // nobody. Any cascade park drags a live-rank phase down, so the
      // condition below then forces strict descent — release and every
      // live-rank revoke get NO exemption at all.
      and {
        lastStep.label == "ticket-revoked",
        lastStep.transitions.foldl(true, (b, t) =>
          b and phaseRank(t.from) == rankSettled)
      }
    }
    exempt or currentMeasure < prevMeasure

  /// Both halves, for --invariant runs: the per-ticket termination sketch
  /// (roadmap PR 1 gate: "per-job liveness sketched").
  val measureDescends: bool = and { measureNonNegative, stepDescends }

  /// ANTI-VACUITY WITNESS, not an invariant of the machine: "no
  /// operator-retry into a PIPELINE phase (Evaluating/Landing) ever climbs
  /// the measure". EXPECTED TO BE VIOLATED on the RetryFree instance
  /// (check.sh Stage 9b: deterministically by the free-climb machine
  /// trace in tests/chuggy_witness_test.qnt, plus the demoted pinned-seed
  /// probe) — the violation is the
  /// machine-level proof that free pipeline resumes really do climb and
  /// really are exempted by stepDescends' RetryFree CHURN arm, which no
  /// green run could otherwise distinguish from dead code. Under
  /// RetryCharged it must HOLD (every pipeline resume pays gas and
  /// descends). The witness deliberately EXCLUDES the pre-work RPending
  /// resume (notes PR): that flavor is free and climbs under BOTH
  /// meterings — the old stalled-retry churn, whose exemption arm the
  /// unit tests pin (the climb is deterministic there) — so including it
  /// would let a charged instance violate this witness without ever
  /// exercising the RetryFree arm it exists to prove alive.
  val freeClimbNever: bool =
    not(and {
      lastStep.label == "operator-retry",
      lastStep.transitions.foldl(false, (b, t) =>
        b or t.to == PEvaluating or t.to == PLanding),
      currentMeasure > prevMeasure
    })

  /// ANTI-VACUITY WITNESS #2 (PR 2), not an invariant of the machine: "no
  /// revoke ever parks a dependent". EXPECTED TO BE VIOLATED (check.sh
  /// Stage 9b: deterministically by the cascade machine trace in
  /// tests/chuggy_witness_test.qnt, plus the demoted pinned-seed probe)
  /// — the
  /// violation trace is the machine-level proof that the cascade really
  /// fires on reachable states, so cascadeSafety's green runs are checked
  /// against traces that exercise it (a cascade that never parks would
  /// make cascadeSafety vacuously true wherever revokeDoomed stays empty).
  val cascadeParkNever: bool =
    not(lastStep.label == "ticket-revoked" and lastStep.transitions.length() > 1)

  /// ANTI-VACUITY WITNESS #3 (PR 3), not an invariant of the machine: "no
  /// eval stage ever advances". EXPECTED TO BE VIOLATED (check.sh Stage
  /// 9b: deterministically by the stage-advance machine trace in
  /// tests/chuggy_witness_test.qnt, plus the demoted pinned-seed probe)
  /// — a reachable
  /// eval-stage-passed step is the machine-level proof that multi-stage
  /// programs actually run stage-by-stage on machine traces, so the green
  /// invariant runs above are checked against traces where the stage digit
  /// and the interpreter's advance edge are exercised, not vacuous (a
  /// fleet that only ever drew single-stage programs would never take the
  /// edge). The unit tests walk the advance deterministically; this pins
  /// it as REACHABLE.
  val stageAdvanceNever: bool =
    not(lastStep.label == "eval-stage-passed")

  /// ANTI-VACUITY WITNESS #4 (citations PR), not an invariant of the
  /// machine: "no eval spawn ever carries a verdict". EXPECTED TO BE
  /// VIOLATED (check.sh Stage 9b: deterministically by the gate-rework
  /// carry machine trace in tests/chuggy_witness_test.qnt — whose twin
  /// run also pins the intersecting footprint NOT carrying — plus the
  /// demoted pinned-seed probe) — a reachable CarryEvalVerdicts effect is
  /// the machine-level
  /// proof that the scoped respawn actually skips an evaluator on machine
  /// traces (a disjoint retained pass really is carried), so the green
  /// invariant runs above — citationsWellFormed, idsAccounted,
  /// measureDescends over carried spawns — are checked against traces
  /// where a carry OCCURS, not vacuous: an adversary that always cited
  /// the full universe (or nothing) would never take the carry branch.
  /// The unit tests walk carries deterministically; this pins one as
  /// REACHABLE.
  val carryNever: bool =
    not(lastStep.effects.foldl(false, (b, e) => b or e == "CarryEvalVerdicts"))

  /// All safety invariants, for `--invariant=allInvariants`.
  val allInvariants: bool = and {
    landingExclusive,
    revokedNeverLands,
    terminalsAbsorbing,
    deskConsistent,
    gateWallNamed,
    accountsBounded,
    tasksWellFormed,
    recordWellFormed,
    recordMonotone,
    idsAccounted,
    programsWellFormed,
    citationsWellFormed,
    depsAcyclic,
    idsDense,
    deskVisibility,
    cascadeSafety,
    measureDescends
  }
}
