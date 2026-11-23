Overlay a mentor plan run loads when the requested plan deliverable is a rollout to a
running environment: a deploy, a promotion between environments, a live data or schema
migration, or a production flag or config flip. It supplies the safe-deploy contract,
phased rollout, gates and rollback; planning still owns approval, grading and the run.
A code change whose PR merely carries a deploy runbook, or a fix to a deploy script,
stays software-change.

# Playbook — deployment

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused
question directly and wait for the answer. If delegated agents are unavailable or
prohibited, perform research and rollout serially and label every required
self-grading under planning's verifier contract; a self-graded phase gate never
counts as the independent grade a deploy grant needs, so that phase pauses. Resolve
optional Mentor helpers with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; without
either, use the durable `.mentor/` artifacts and report state actions that cannot be
performed safely. Use the deploy tooling, metrics and probes the host can actually
reach; an unreachable signal is an evidence gap, never a pass.

## The safe-deploy contract

A production phase is **safe** only when its plan states, and the run proves, all three:

1. **Zero downtime** — serving capacity never drops below what the baseline load needs,
   and an external probe of every user-facing endpoint the phase touches records zero
   failures from phase start to the end of its bake window.
2. **Backward compatible** — the old and new versions run side by side and either can
   serve alone: schema and data changes are additive (expand only), API, event and
   message contracts accept both versions' producers and consumers, and redeploying the
   captured prior version is proven to work (rehearsed in a lower environment, or the
   tool's rollback verified per planning Step 2 → "Verify literal CLI commands, and
   claims about a live system's current state").
3. **Zero user interruption** — error rate and p95 latency stay within the baseline's
   noise band through the bake window; in-flight requests drain before an instance
   stops; sessions, tokens and long-lived connections survive the switch; a
   user-visible change ships dark behind a flag and is exposed progressively.

Plan for safety first: reach for every technique that turns a risky change into safe
phases — environment progression (dev → staging → prod), canary steps, blue-green,
rolling updates that never remove capacity before adding it, cell- or region-sized
waves, shadow traffic, feature flags, versioned APIs, and expand → migrate/backfill →
contract for data. Several small deploys beat one big one whenever splitting makes a
phase safe. A phase no decomposition can make safe (a breaking contract, a destructive
contract-step migration, a single stateful instance, a required maintenance window) is
marked `safe: no` and always pauses.

## Deploy grant (autonomous production)

A safe phase deploys without pausing only under a **deploy grant**: a line in the
repo constitution's Always-pause list that names the built-in item "Deploys and
production configuration changes" and lifts it for safe phases, scoped to named
services and environments (constitution-authoring → "The autonomy contract"). Record
the constitution version and the grant line as a decision-log row before approval, and
state in the Goal check whether production phases run autonomously, so the approval
card shows it. With no grant, or outside its scope, plan the same phased rollout and
pause at each production phase with that phase as the one question.

The grant covers what an approved safe phase needs: deploying the phase's artifact,
running an additive (expand) migration or a backfill that only fills new columns,
creating the release tag and applying the deploy config the phase names, shifting
traffic or flag exposure along the planned steps, and rolling back to the captured prior
version when a gate breaks. Software-change's "deploy config, or release tags" item and
merging's data-migration pause lift too only when the grant line also names them
(constitution-authoring's example line does); otherwise they still pause. The grant
never covers secrets, a migration that drops or rewrites existing data, or any action
the plan did not name.

## 1. Research directives (planning Step 2)

Find and cite, with `file:line`, command output or the deploy tool's own docs:

- **What runs now**: the deployed version or ref per target environment — the rollback
  anchor — and how traffic reaches it.
- **The deploy path**: the tool, pipeline or runbook the repo actually uses, its safe
  primitives (canary weights, surge/unavailable limits, readiness gates, automatic
  abort), and the rollback command. Load a repo or session skill that covers the
  platform before relying on memory (planning Step 2 → "A fast-moving
  vendor/product/SDK topic goes to the reference skill").
- **Compatibility surface**: schema and data changes, API, event and message contracts
  with their producers and consumers, config defaults, and session or token formats.
- **Signals**: where probes, error rate and latency come from; measure a baseline and
  its noise band now and record them as an experiment row. When planning cannot reach
  live metrics, make that measurement the first read-only step and log it as a gap.
- **Constraints**: change freezes, release windows, the constitution's deploy grant
  line and scope, and who else's commits the release would carry.

## 2. Definition of done (Goal check and `Done when:`)

- **Goal check**: the target version serves 100% of traffic in every target environment;
  every phase's gate passed; the three safe-deploy predicates held in every phase with
  their measured values; and the rollback anchor is recorded. Name the probe, metric
  queries and band.
- **Plan shape**: preparation (baseline, rollback rehearsal, compatibility proof) and
  then each rollout phase are ordinary `## Implementation steps`, so planning's verify,
  tick order and per-step verifier apply unchanged. Each phase step names its
  environment, technique and exposure, artifact, `safe: yes|no`, bake window, rollback
  trigger and rollback action. Every production phase names a concrete rollback action,
  data and schema phases included (for an additive migration: stop the writer, or revert
  to the prior version that ignores the new column). "Pause" alone is not a rollback. A
  phase that cannot be undone, including a deferred contract phase this run won't
  execute, still writes its gate and `rollback: none (forward-only)` and is `safe: no`,
  because it fails the backward-compatible check. When combined with software-change,
  the code must merge first, so the phases are the runbook's **After merge** lines
  instead, and this Goal check stays out of the plan's `## Goal check` (it cannot pass
  before the merge) and becomes the After-merge grade's predicate.
- **Phase gate** (each phase's `Done when:`): probe failures are 0, error rate and p95
  latency are within the band, and the exposure matches the row — all measured over the
  full bake window. A gate is never shortened or relaxed to pass.
- A constitution's Definition of done adds to these rollout checks by AND; unlike
  software-change's code defaults, it never replaces the rollout predicate.

## 3. Extra always-pause items (the run)

Added to the constitution's list or the built-in default (a union):

- A production phase with no deploy grant covering its service and environment
- A phase marked `safe: no`, or whose pre-phase grade is not an independent PASS
- A destructive migration step (contract, drop, rewrite) and any data deletion
- Changing the approved rollout mid-run: skipping a phase, raising exposure faster,
  shortening a bake window, or rolling forward after a failed gate
- A deploy during a change freeze or outside a named release window

Under a deploy grant, the grant's covered actions (above) proceed without asking.

## 4. Deliver mode (the run's deliver state)

Record a single delivery owner before approval. For a pure rollout, deployment owns
delivery: the phases already ran as steps, so deliver hands the Done review and the
evidence below to the human. When combined with software-change, **software-change is
the sole delivery owner**: shipping and merging run as its Deliver mode describes (the
merge gate is unchanged), and merging Step 6's After-merge walk runs each deploy line
under §6 below, followed by its After-merge grade. The rollout runs only after a merge in
this session; when the PR is left open or auto-merges later, the phases go to the Done
review's Leftovers as not run, and the rollout predicate stays ungraded.

## 5. Evidence kinds (the Done review)

Per phase, under `.mentor/plans/<slug>/evidence/rollout/`: the prior and new version or
ref; the commit delta (`git log <prior>..<new>`, one row per commit with its author); the
probe log with its failure count; error rate and p95 latency against the band with the
query used; exposure reached; bake start and end; the gate verdict path; and any
rollback taken with its output. The Done review's runbook lists the rollout phases with
their results and each phase's rollback line.

## 6. Run rules (After Proceed)

- **One phase at a time** (a phase step, or an After-merge deploy line). Capture the
  current version as that phase's rollback anchor, have a fresh verifier grade the
  phase's safe-deploy readiness and save it to `evidence/rollout/<phase>/pre-grade.md`
  (never `verdicts/step-N.md`, which would tick the phase before it deploys), then
  deploy, hold the full bake window, and have a fresh verifier grade the gate before the
  next phase starts. The gate grade is the phase step's `verdicts/step-N.md`; for an
  After-merge deploy line it goes to `evidence/rollout/<phase>/gate-grade.md`, and the
  walk's `verdicts/after-merge.md` follows.
- **A gate breach rolls back and stops.** Roll back to the anchor (under the grant this
  proceeds; without it, pause first), confirm the rollback with the same probe and
  metrics, log the row, and pause with what broke. Never fix forward without a re-plan.
  In an After-merge walk the plan is already `implemented`, so the remaining phases go
  to the Done review's Leftovers as not run, and fixing forward is a new plan.
- **Re-read the `evidence/rollout/` files and the decision log on resume**; a phase
  without a saved gate grade is re-graded, not assumed.
