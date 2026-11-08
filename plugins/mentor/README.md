# mentor

A cross-host agent workflow that runs on top of the host: **you approve the plan once, then
mentor keeps working until the done-check passes.** It stops only for actions on the
constitution's always-pause list, and records every decision it makes for you to review
afterwards. It is general-purpose — a report, a data cleanup, a doc set, or a code change
all run the same flow; software-specific steps (tests, branches, pull requests, merging)
live in a separate playbook reference that planning reads through its index when the
goal is a code change. Plans are durable **Mermaid-first Markdown** artifacts in the repository's
**`.mentor/`** directory (gitignored, shared across worktrees), and the portable skills run
on Claude Code, Codex, or another capable agent.

Install in Claude Code: `/plugin marketplace add Watcharagorn/private-claude-marketplace`, then
`/plugin install mentor@private-marketplace`.

Claude Code adds an enforcement adapter: its `/mentor:plan` facade arms a worktree plan-gate marker
(`.planning.<wt-id>`) and a fail-closed `PreToolUse` hook blocks repo edits until approval. Preserve
that stronger behavior when the adapter is installed. Hosts without compatible hooks use the same
explicit no-source-edits-before-approval rule as an advisory boundary and still write the plan under
`.mentor/`; they must not pretend that an unavailable gate is enforced.

**What mentor is — and is not.** Mentor is the workflow layer for the core concept pinned
in the marketplace's `AGENTS.md` → **Mentor core concept** (the single source; this
paragraph applies it): done is a check, never block on the human, a decision log, triage
before asking, an independent grader, and run until the check passes. Concretely, the edit
gate keeps the repo read-only until the one approval; after it, the run drives the plan to
its Goal check through **native host primitives** — the `plan-continue.sh` Stop hook, fresh
verifier subagents, and the host's own loop — and pauses only for always-pause
items. Mentor is **not a hand-rolled sequencer**: no component re-polls script verdicts in a
bash ladder (v2.37's removed "instant" ladder is the banned shape), and the Stop hook decides
only "may this session stop now?" from the run marker and the plan's stored state — never
what to do next. Single point-in-time reads like `gate`/`context`/`verify` are fine.
A point-in-time verdict read before a new tick is also allowed. Every skill is an
**independent primitive**: it may point at a sibling or execute a verdict just
reached, but never claims the session's lifecycle or governs a sibling's internals —
`frontend-self-ex-review` is the reference shape; a playbook is loaded *by* planning and only
fills slots planning leaves open. The plan file is mentor's **primary** source of truth,
never its only mode. Plan-file tracking adds read-only per-prompt and SessionStart
pointers, plus `record-write` / `drift` commands for a content-hash baseline (v6.3.0);
none of them approves a plan, claims a run or chooses work. Before adding a hook, script, state token, or `plan-state.sh`
subcommand, amend this paragraph first: if the addition contradicts it, the addition is
wrong. (The v1.0.0 slim-down regrew 32 → 79 files in five weeks; this paragraph and
`hooks/tests/test-hook-roster.sh` exist so it doesn't again.)

## Quick start

On any supported host, ask naturally: **“Plan <what you want done>”**, or invoke the
`planning` skill directly. The result is a plan at `.mentor/plans/<slug>/plan.md` with a
`## Goal check` (what "done" means, as a check) and a `## Decision log`. Questions are settled by
evidence or a decision-maker agent first; only genuine product calls reach you. No source edit
occurs before your one approval — after it, the run continues on its own until the Goal check
passes, then hands you the deliverable with a **Done review**. Mid-run product calls are
decided by agents and flagged for your review.

### Claude Code command facade

```
/mentor:grill <topic>         # optional: sharpen open design decisions before you plan
/mentor:plan <what you want to build>
```

In Claude Code, `/mentor:plan` additionally:

1. Runs `begin-plan.sh`, which writes this worktree's own `.planning.<wt-id>` marker
   — **arming the edit gate for this worktree**. From here, repo source edits in
   THIS worktree are blocked until approval; other worktrees plan and edit
   independently (see "Known limitations").
2. Follows the `planning` skill: optional clarify (grilling), a **playbook pick** (a
   reference from `skills/planning/references/playbooks.md` whose “Loads when…” entry
   matches the goal — `software-change` for code), research (starting with a plan-file skeleton), then **triage** of every open question: answered from the material, settled
   by a quick experiment, decided by a decision-maker agent within the constitution's Decision
   authority, or — only for a genuine product call — asked via `AskUserQuestion` with evidence
   and a recommended option. Findings and decision-log rows land incrementally in
   `<repo>/.mentor/plans/<slug>/plan.md` (in-repo, gitignored), then the remaining sections
   are completed before approval.
3. **The one approval**: **Proceed** (run it), **Deliver plan only** (the plan file is the
   deliverable), or **Keep planning**. The full plan stays in the file; chat shows a
   short card with its path and Rev. Type `show plan` in "Other" to print it once and
   re-ask without approving. A plan-quality ask typed into "Other" runs
   `/mentor:grill` on the drafted plan. An approving choice runs `approve-plan.sh`, which
   validates the plan (non-empty, newer than the marker) and deletes the gate marker;
   Proceed also writes the session's run marker `.mentor/.run-<session_id>`.
4. **The run.** Each step is built, graded by a fresh verifier
   (`skills/planning/references/verifier-contract.md`) in this order:
   save `verdicts/step-N.md` → PASS row → `record-write` → tick.
   A FAIL retries once, then re-plans (once per step, three times per run, never weakening a
   check), then `failed`. Every choice not in the plan gets a log row. The run pauses only for
   always-pause items or a stop word. When all steps are ticked, the `## Verification` topics are graded,
   the **Done review** is written (per scenario: expected, observed, evidence; a runbook
   when hand-over needs steps; leftovers), the Goal check is graded against it, and the
   deliverable is handed over — for code, via the playbook: a PR with the Done review in its body, then a
   verifier-graded merge. The `plan-continue.sh` Stop hook keeps the session going while the
   plan is `in_progress`.

> This Claude Code facade is **namespaced** — it cannot collide with Claude Code's native
> reserved `/plan` command. The same holds for every mentor command: they exist
> **only** in `/mentor:<name>` form. A bare `/ship` or `/plan` is not mentor's —
> it is whatever else claims that name, or nothing at all, and "nothing at all"
> is the dangerous case: the assistant may improvise a substitute flow rather
> than report that the command didn't resolve.

> **Claude Code adapter note:** enabling mentor **mid-session** (e.g. toggling it on in `.claude/settings.json`)
> doesn't make its commands or skills live in that same session — until you
> `/reload-plugins` (or start a fresh session), neither `/mentor:ship` nor a
> skill trigger like "grill this plan" resolves, and Claude Code silently falls
> back to whatever else claims the name, or improvises a substitute. Old
> versions also linger in `~/.claude/plugins/cache/` — never `Read` one as if
> it were current; check `.claude-plugin/plugin.json` for the live version,
> then match it against the `Changes in vX.Y.Z` sections below to see whether
> a given fix is in your copy.

## Claude Code commands

These commands are optional Claude Code facades over the portable skills and artifacts. On Codex or
another host, invoke the matching skill or describe the same intent naturally.

| Command | What it does |
|---|---|
| `/mentor:plan <task>` | The gated plan flow (above). |
| `/mentor:retro [session]` | **Retrospective of a finished session** — rebuilds the session from disk (even after several compactions, and across Claude or Codex subagents and agt workers), runs three lenses and a synthesizer over it, and turns the approved findings into skill changes (new skills for repeated procedures, edits, description tunes). A thin facade over the gated plan flow: it refuses while this session's own run is `in_progress` or paused (stored `approved`), and stops without arming when `jq` is missing, then arms the gate and hands `planning` a retro goal that selects the `retrospective` reference from its index. Offered as a one-line invitation after a plan reaches `implemented`. `--claude-config` / `--codex-home` / `--agt-home` point it at explicit source-transcript roots. |
| `/mentor:preview [subject]` | **One scenario-based review page for a plan or any subject** — a repo subsystem, a doc, a mentor plan, or the thing under discussion; no plan file or planning session required. Draws only what the subject changes: a mockup of every surface each scenario reaches (each edge case its own card, Before/After per scenario), each sequence under the scenario that starts it, the C4 levels that move, the changed data and contracts, and the decisions; every card has a comment box with Copy, and open questions come back to chat one at a time. Writes `.mentor/reviews/<subject-slug>/review.html` (gitignored), opens it, and offers to publish it on Claude. `planning` Step 5 delegates here for an in-planning page. |
| `/mentor:ship` | Finish the current branch: clean-check → `/simplify` → tests → push + auto-open PR/MR (or push to upstream). Standalone it asks; inside a plan run (the software playbook's deliver mode) it follows the plan's Definition of done and puts the Done review in the PR body. Never force-pushes. |
| `/mentor:merge [PR#]` | The tail `/mentor:ship` leaves off: one bounded `gh pr checks --watch`, then one triage — flake (one rerun max) / regression (stop and report) / already broken on the base branch (don't spend the rerun; you choose **Merge anyway** or **Leave open**, and any leftover work is named in the report) — then an independent verifier grades the PR, and it merges only on your explicit choice (or under a constitution that grants merge), then walks the runbook's after-merge steps, pausing on always-pause lines. GitHub-only. |
| `/mentor:grill [topic]` | One-question-at-a-time interview that sharpens a design's open decisions before you approve — also the route for a plan-quality review before approval. Asks only product calls; evidence- and constitution-settleable questions are settled without asking. Conversation only, pre-approval only. |
| `/mentor:constitution [principles]` | Create/amend this repo's governing principles and autonomy contract (Always-pause list, Decision authority, Definition of done) at `.mentor/constitution.md` — versioned, committed, and honored by every plan and run. |

`frontend-self-ex-review` has no command of its own; invoke it through natural language
matching its `description:` or `Skill({"skill": "mentor:frontend-self-ex-review"})`.
The seven public skills are `planning`, `grilling`, `previewing`, `shipping`, `merging`,
`constitution-authoring` and `frontend-self-ex-review`.

| Skill | What it does |
|---|---|
| `planning` | Plan any goal, select matching runtime playbooks, take one approval, then run to a verified Goal check with a decision log and Done review. Also handles one-session retrospectives. |
| `grilling` | Pressure-test a plan or design before approval, settling discoverable facts first and asking genuine product questions one at a time. |
| `previewing` | Build a local scenario-based HTML review page for a plan or any subject, including the affected surfaces, edge cases and comment boxes. |
| `shipping` | Finish the current branch, run the required checks, then push and open a PR with the Done review when inside a plan run. |
| `merging` | Watch CI, triage a failure, obtain a fresh pre-merge grade and merge under the governing approval contract. |
| `constitution-authoring` | Create, amend or inspect the project's principles and autonomy contract without starting a plan run. |
| `frontend-self-ex-review` | **Self-explanatory UI review, feedback only** — say "make this screen self-explanatory", "make it textless", "too much text", or "users don't know what to click". Reviews a screen, component, flow, screenshot, or proposed design in one of two modes: **audit** (the default — findings tied to `file:line`, each with its proposed change tagged *small fix* or *needs a plan*) and **verify** (checks a change already made: states, ~360px, keyboard — reported as observed / executed / inferred / not tested). It writes no files and no plans; applying the feedback is follow-on work. A general UX/UI review without that goal doesn't trigger it. Cuts decorative and redundant copy by *purpose*, never by keyword, and keeps labels, constraints, consequences, and user content. Isolated from the rest of mentor: beyond the host-portability paragraph every mentor skill carries, it reads no mentor state and calls no mentor helper, so the folder can be copied into any project's skills directory. |

Planning reads the following playbook references through
[its index](skills/planning/references/playbooks.md); they have no public skill entry
point. Retrospective requests in natural language and `/mentor:retro` enter planning's
one-approval flow. Released selections keep resolving through the index aliases.
Selection follows the requested plan deliverable, not incidental work: an ordinary
how/why question outside a plan loads nothing, and a bare mockup request uses
`previewing`. The aliases `playbook-software-change` and `playbook-retrospective`
resolve in both inline and next-line `## Playbook` formats without rewriting old plans.

| Reference | What it supplies |
|---|---|
| [software-change](skills/planning/references/playbooks/software-change.md) | **The software playbook**, loaded by `planning` at runtime when the goal is a code change. Supplies five overlays the general flow reads: research directives (callers, tests, check commands), the Definition of done (the repo's checks pass), extra always-pause items (force-push, protected branches, merging, destructive migrations), the deliver mode (`shipping` then `merging`), and evidence kinds (test output, CI link, diff stat). Never a workflow of its own. |
| [retrospective](skills/planning/references/playbooks/retrospective.md) | Rebuild one finished session from disk as an evidence graph, run three lenses and a synthesizer, apply accepted local skill changes, and report remaining proposals. Local edits then Done review; never co-loaded with software-change. Host transcript details live in the adapters. |
| [investigation](skills/planning/references/playbooks/investigation.md) | Produce a read-only cited answer. Label claims measured, inferred or guess; write only the plan's evidence and deliverable, and ship nothing. |
| [hillclimb](skills/planning/references/playbooks/hillclimb.md) | Improve a named metric through one change → one measurement → keep or revert. Done requires the target AND at least N logged attempts within approved caps; software-change owns delivery when combined. |
| [prototype](skills/planning/references/playbooks/prototype.md) | Deliver prototype variants and observed comparison evidence so the human can pick. Select only when the prototype itself is the plan goal, never for a mid-plan fork; never ship prototype code. |

## Runtime contracts

The plan-level `Goal:` opens every role brief; the local task follows it. Planning's
[Role resolution](skills/planning/SKILL.md#decision-maker) honors an explicit session
mapping first, otherwise chooses an installed agent by its described domain or
purpose, then a general-purpose agent. Without delegation, work runs serially with
the same scope and evidence and labelled `self-graded` verdicts. Hooks and subagents
are host adapter capabilities; the portable fallback remains useful without them.

The caller saves every returned grade verbatim, including FAIL and HANDBACK. The
latest grade overwrites `verdicts/step-N.md`; a present canonical file wins even
when a legacy file passes. For a step PASS, the order is save `verdicts/step-N.md` →
PASS row → `record-write` → tick. A new tick reads that verdict once at the point of
use and refuses a missing, empty or non-PASS grade; it does not poll or choose work.
Released `step-N-verify.md` paths remain readable only when the canonical file is
missing. Legacy headers are optional, comments may precede `Verdict:`, and an
already-ticked step remains an idempotent no-op without a verdict file. A saved
`Grading: self-graded` PASS can tick on a host without subagents; it does not claim
independent verification.

Deterministic check output can be reused only for the same check and predicate,
with identical command and cwd on a proven-identical clean tree and unchanged tool,
dependency and config inputs.
For software, this includes the same HEAD and clean status plus the per-check
evidence bundle in both verdicts. A fresh verifier cites the source output and
grades each stage; missing proof requires a re-run. Live CI, external state and
timing-sensitive repeats always run again. See the
[verifier contract](skills/planning/references/verifier-contract.md#evidence-reuse).

Runtime references are planning's
[principles catalog](skills/planning/references/principles.md),
[playbook index](skills/planning/references/playbooks.md) and selected playbook files,
and [verifier contract](skills/planning/references/verifier-contract.md).
Principles apply at named decision points: resume, research, triage, scope checks,
FAIL/re-plan and numerical claims. Log a principle only when it changes a choice;
the catalog does not become the project constitution. Selected playbooks may add
bounded Run rules, read before starting or resuming and followed throughout; an
absent slot means none. Planning owns the full
[After Proceed directive](skills/planning/SKILL.md#implement); commands and approval
output point there instead of carrying another copy. `rationale.md` is editing-only,
read when editing or considering an override.

## Where a new rule goes (skill authoring convention)

mentor's skills grow by accretion — most rules here were added after a session went
wrong, together with the story of how. That story is worth keeping and expensive to
re-read: it is loaded into context on every invocation, but it only matters when someone
is questioning the rule itself.

So, when adding or amending a rule in a `SKILL.md`:

- **`SKILL.md` gets the imperative rule plus at most one sentence naming the failure it
  prevents.** That sentence is not optional — a rule with no stated why gets worked
  around by the next reader who finds it inconvenient.
- **`references/rationale.md` gets the narrative** — the incident, the mechanism, the
  alternatives that look right and are not, the measured cost. Give it a `## ` heading
  and point at it from `SKILL.md` by name (`references/rationale.md` → **Heading**), not
  by line number.
- **`references/rationale.md` is editing-only**, read when editing or questioning a rule.
  Runtime references such as planning's `references/principles.md` and `references/verifier-contract.md` load at the decision points the skill names.

This applies to automated contributors too: a `/loom:learn` cycle that harvests a new
rule from a session should append the narrative to `references/rationale.md`, not to
`SKILL.md`. Without that split, every skill converges back on being unreadable.

Since v3.0.0 that binds automated contributors in a stronger form as well: **new lessons
land as skill prose or `references/rationale.md` — never as new hooks, new scripts, new
state tokens, or new `plan-state.sh` subcommands.** (v6.0.0's Stop hook/run marker and
v6.3.0's plan-file pointers/hash commands are sanctioned exceptions, added by human-approved plans that amended the charter first —
the route any future machinery takes too.) A new domain's know-how lands as a new
indexed reference under `skills/planning/references/playbooks/`, never as domain text
in `planning/SKILL.md`. A lesson that seems to need machinery
goes in as prose plus a proposal for the user to decide on;
`hooks/tests/test-hook-roster.sh` fails the build if machinery lands anyway.

## State directory

State is **project-scoped** — `<repo>/.mentor/`, with one dir per plan topic:

```
<repo>/.mentor/
├── .gitignore       # commits config.json + constitution.md; ignores the rest
├── config.json      # context-gate keys, test_command, diagram_renderer,
│                    #   constitution_path                                 ← committed
├── constitution.md  # governing principles + autonomy contract            ← committed
├── .run-<session_id> # v6: slug= + started=; written by approve-plan.sh on Proceed,
│                    #   removed at done/failed; read by continuation and plan pointers ← gitignored
├── plans/           # one .planning.<wt-id> gate marker PER WORKTREE (v2.23.0) +
│                    #   one dir per plan topic, SHARED across every worktree;
│                    #   bare `.planning` is the reserved legacy repo-wide marker ← gitignored
│   └── <slug>/      #   plan.md (+ ## Goal check, ## Decision log, ## Done review)
│       ├── .state.json # lifecycle state + relations + plan_sha256 — written only by plan-state.sh
│       ├── evidence/   # v6: captured logs, screenshots, probe scripts (the run)
│       └── verdicts/   # caller saves returned blocks: step-N.md · topic-N.md · goal.md · pr.md
└── reviews/         # /mentor:preview pages — <subject-slug>/review.html (+ _ids.md,
                     #   _plan.md, _brief.md, _trace.md, _built.md, _parts/,
                     #   shots/)                                           ← gitignored
```

Only `config.json` and `constitution.md` are committed (team-shared); plans, reviews and the
transient markers are gitignored. Un-ignore `plans/` if you want plans version-controlled.
**Not in a git repo?** `plan-state.sh dir` resolves the configured portable state home
(including `MENTOR_STATE_HOME` when set); skills must not hardcode a host config path.

Data older versions wrote — `handoffs/` and `tours/` dirs, deferred plan stubs, and
`mode`/`dispatch` keys in `config.json` — is left on disk as it is; v5.0.0 reads none of it.
Split groups from the removed `plan-split` skill keep reading correctly: `group`, `order`
and `superseded` are still parsed (v6.0.0).
Released verdict paths `step-N-verify.md`, `topic-N-verify.md`, and `goal-verify.md`
remain readable when their canonical `verdicts/` file is missing. The latest step grade
overwrites `verdicts/step-N.md`; readers never search `-rK` files.

## Plan state

Every plan dir carries a hidden `.state.json` recording where it stands, so a fresh
session can answer "which of these five is next?" without re-reading five plans.

| State | Meaning |
|---|---|
| `draft` | Written, not yet approved. |
| `approved` | The gate released it — ready to build, or a paused run (note `paused: row N`). |
| `in_progress` | Execution started; some steps are ticked. |
| `implemented` | Every step graded PASS by a verifier, the `## Goal check` graded PASS, the Done review written, and the deliverable handed over. |
| `failed` | A step or the Goal check could not pass within the re-plan limits; the note says what broke. |
| `superseded` | Legacy: replaced by its children via the removed `plan-split` skill. Still read; sorted last. |
| *(no sidecar)* | `unknown` — a pre-2.4.0 plan. Never reported as "never approved". |

A **paused** run is stored as `approved` with a `paused: row N` note (the decision-log row
naming what needs you); resuming sets `in_progress` again.

**The sidecar is a cache, not the only truth.** Reads take the *more advanced* of the
stored state and the state derived from the plan's `✅` step ticks — every step ticked
reads `implemented`, some reads `in_progress` — with one exception: a recorded `failed`
outranks the derivation, since only a run that watched something break writes it, and
an all-ticked plan must not read its way back out of that. That derivation reports how
far *building* got, not the run: an all-ticked plan reads `implemented` while its
`## Verification` topics, Goal check, Done review and delivery may still be owed — which
is why `plan-continue.sh`, `begin-plan.sh` and the plan pointers read the **stored** state. While it is
still stored `in_progress`, `/mentor:plan <slug>` prints `ALREADY APPROVED` with a
pointer to resume at After Proceed step 6; finish steps 6–8, then
`set <slug> implemented`. Since implementation ticks each step as it passes, a forgotten
state write costs nothing and old plan dirs read correctly with no migration.

Group membership heals the same way: a legacy split child's isolation header carries
`**Plan 3 of 5** · group \`…\``, and mentor parses `group`/`order` back out of it when
the sidecar is missing or torn. Delete a `.state.json` outright and the plan still
lists with the right state, group, and position — a plan dir needs nothing but its
`plan.md`.

> This is not a return to the v1.0.0 footer markers. Those were in-document contracts
> the model had to maintain by hand, and they broke when it forgot. The sidecar is
> written only by `hooks/plan-state.sh`; lifecycle progress is *derivable from the
> plan file*, while the optional content hash remembers the last mentor write.
> Older sidecars remain readable without that baseline.

### Sidecar schema

Every field is written only through `plan-state.sh`; older, shorter sidecars need no
migration — every reader defaults the fields it doesn't find.

| Field | Type | Written by | Since |
|---|---|---|---|
| `state` | one of 6 states | `init` / `set` | v2.4.0 |
| `group` | split-parent slug or `null` | `init --group` | v2.4.0 |
| `order` | int or `null` | `init --order` | v2.4.0 |
| `note` | free text, replaced each write | `set --note` | v2.4.0 |
| `deps` | array of plan slugs, default `[]` | `init --deps a,b` / `set-deps <slug> a,b` | v2.17.0 |
| `owner` / `owner_session` | wt-id + session id, or `null` | `ensure-dir` / `init` / `relocate` | v2.23.0 |
| `plan_sha256` | sha256 string or absent | `record-write` / `tick`; Claude Code's Write/Edit hook calls `record-write` | v6.3.0 |

Omitting a flag **preserves** whatever is stored, which is what lets deps and ownership
survive a later `set <slug> approved` untouched; passing one with an explicit empty value
**clears** it. `note` is the one exception — it is replaced on every write, so a plain
`set` deliberately clears a stale failure note.

Every write **merges** into the existing sidecar, so keys `plan-state.sh` no longer
writes survive untouched: sidecars from older versions keep `origin`, `parent`,
`priority`, `category` and `deferred_from`, and nothing reads them.

`set-deps` replaces a plan's deps wholesale and refuses a write that would create a
dependency cycle (direct or transitive) — fail-soft: a stderr warning, no write.
Unknown dep slugs are allowed (the dep plan may not exist yet); `query` marks them
`missing` rather than failing.

### Content changes

`plan-state.sh record-write <slug>` records the current `plan.md` hash in
`plan_sha256`, preserving every other sidecar key. `tick` reports existing drift before
changing the file and records its resulting hash. Both commands and
`plan-state.sh drift <slug>` work on every host. When mentor calls them is owned by the
`planning` skill: "Step 2 — Research" → **Track every plan write on every host**, and
"After Proceed — run until the Goal check passes".

| `drift <slug>` | Meaning |
|---|---|
| `known` | The file matches the last recorded mentor write. |
| `changed` | The file differs from that write. |
| `unknown` | No baseline yet (including a legacy sidecar), or the file/hash cannot be read. |

The notice is `plan.md changed since mentor last wrote it — read it before editing it further`.
It identifies a change without attributing it to a writer; unknown never produces a notice.
**Claude-only hooks** add the per-prompt pointer, SessionStart re-attachment and automatic
hash recording for Write/Edit. Shell writes and hosts without those hooks use
`record-write` explicitly; the portable `drift` and `tick` commands keep the same meaning.

### Listing plans (`query`)

`plan-state.sh query` answers "what's there?" in one call: a JSON array covering every
plan dir with a `plan.md` — state, group, order, `deps` (each a `{slug, missing}` pair,
`missing` true when no such plan dir exists), owner, and ticked/total step counts.
Computed fresh on every call — nothing is cached, so it can never drift from the
sidecars, plan ticks, or filesystem it reads. Flags ask for a slice instead of the whole
array: `--slug`, `--group`, `--state`, `--open`/`--closed`, `--deps-missing`,
`--owner`/`--unowned`, `--match`, `--fields`, `--sort`, `--limit`, and
`--format json|tsv|table|count|slug`. Unmet deps are reported with a recommended build
order but never block — you can always build the plan you picked.

## Constitution (`/mentor:constitution`)

A **constitution** is this repo's supreme rulebook: a short list of named,
declarative, **testable** principles (MUST/SHOULD language) plus a governance
block. It is the one mentor artifact that lives **in the repo** — committed at
`.mentor/constitution.md` — so the whole team shares one set of rules.

```
/mentor:constitution                     # bootstrap from repo conventions, or
/mentor:constitution "Sources cited: every figure in a report cites its source"
```

`/mentor:constitution` is a **standalone authoring flow** (it never arms the plan
gate): it loads any existing constitution, collects/derives principles, bumps a
**semantic version** (MAJOR remove/redefine · MINOR add/expand · PATCH reword),
records ratification + last-amended dates, prepends a **sync-impact report**, and
writes the file after you confirm. The default target `.mentor/constitution.md` sits
inside the gate-exempt `.mentor/` tree, so it is writable even while this worktree's
plan gate is armed — you are just told a plan is mid-flight, since principles written
now and a plan drafted against the old ones can talk past each other. An
adopt-by-reference target outside `.mentor/` (e.g. `docs/constitution.md`) is different:
the gate really does block that write, so approve or finish the plan first.

Once it exists, it is honored automatically — there are no generated templates to
keep in sync; the plan skill reads it **live**:

| Consumer | Effect |
|---|---|
| `/mentor:plan` | Reads the constitution and adds a **`## Constitution Check`** table to the plan — one row per principle (✅ complies / ⚠️ deviates / ➖ N/A). Every ⚠️ must be resolved by the plan or justified explicitly. |

Deviation is allowed but never silent: a plan either satisfies each principle,
records a justified exception, or the constitution is amended first.

It is also the **autonomy contract** an approved run follows. Three sections:

| Section | What the run does with it |
|---|---|
| `## Always-pause list` | The only actions that stop a run. Without one, the built-in default applies; a playbook adds its own items (a union). |
| `## Decision authority` | What a decision-maker agent may decide in your place, logged for review. |
| `## Definition of done` | The default shape of a plan's Goal check and each step's `Done when:`. |

The built-in default list is defined once, in `constitution-authoring` → "The autonomy
contract".

## Context gate

A long-running session's context can balloon to the point where plan and answer
quality degrade. The **context gate** (`hooks/context-gate.sh`, a `UserPromptSubmit`
hook) measures the live context size from the session transcript and **warns** in
three tiers. It never blocks or erases a prompt, never asks a question, and never
suggests a handoff (v4.2.0) — each tier is a one-line notice, and each ends with the
same progress-first sentence: *"Before compacting, record your progress in the plan:
finished steps, what's in flight, findings, the exact next action. The summary is
lossy; the plan is not."*

**Thresholds (v4.3.0)** are a share of the window the host compacts at, capped by a
fixed token count, whichever comes first:

| Tier | Window known | Window unknown (the default) |
|---|---|---|
| Warn | min(50% of window, 200000) | 200000 |
| Warn-high | 90% of the limit | 90% of the limit (315000) |
| High (the limit) | min(65% of window, 350000) | 350000 |

The window is **never guessed**. Mentor uses one only when you set it or the host
reports it, in this order: `MENTOR_CONTEXT_WINDOW` > `"context_window_tokens"` in
`.mentor/config.json` > Claude Code's `CLAUDE_CODE_AUTO_COMPACT_WINDOW` > a bare-integer
`context-window` file a host adapter writes at `<base>/sessions/<session_id>/context-window`,
where `<base>` is `MENTOR_STATE_HOME`, else `${CLAUDE_CONFIG_DIR:-~/.claude}/mentor`, never
the repo's `.mentor/` (no adapter writes one yet). It is never inferred from the model name, the transcript, or a
compaction percentage such as `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`. With no window only
the caps apply, which are the pre-v4.3.0 numbers. A known window also shows the share
in the size reading: `~105000 tokens (52% of window)`. The three values are clamped so
warn ≤ warn-high ≤ high, and the clamp only ever lowers a value: a limit set below the
warn cap pulls the warn tier down with it.

- **Warn** — "context is getting large"; re-arms after 10% of the window of further
  growth (with no window, a quarter of the warn threshold: ~50000 tokens at defaults)
  rather than firing only once. Skipped for harness-synthetic prompts (inbound
  agent/teammate reports, task notifications, background-agent stop notices) — that
  re-arm belongs to your next real prompt; `context-checkpoint.sh` (below) covers the
  stretch between tool batches.
- **Warn-high** — a near-limit notice that re-fires on every prompt: avoid opening new
  large workstreams.
- **High** — `CONTEXT: HIGH`, over the limit; re-fires on every prompt. `/mentor:plan`
  still arms — over the limit `begin-plan.sh` and `plan-state.sh context` print a
  `CONTEXT: HIGH` warning and proceed, asking only that the plan stay lean.

Escape hatches always pass: an empty prompt and any slash command (`/compact`,
`/mentor:plan`, …) are never measured, so they never pick up a warning. Everything is fail-soft — no `jq`, no transcript, or an unreadable
transcript simply lets the prompt through.

> **Note:** with no window known, the gate is a **long-context / 1M-window backstop**.
> On a standard 200k window with auto-compact enabled it may never fire (auto-compact
> triggers ~155–165k, below the 200k warn cap). Tell mentor the window
> (`MENTOR_CONTEXT_WINDOW=200000`, or `"context_window_tokens": 200000`) and the same
> session is first warned at about 100k, with the limit at 130k.

Knobs — env vars under `env` in `~/.claude/settings.json` (or the project's
`.claude/settings.json`), or per-repo keys in `.mentor/config.json`. Precedence:
**env var > `.mentor/config.json` key > default**.

| Env var | `.mentor/config.json` key | Default | Effect |
|---|---|---|---|
| `MENTOR_CONTEXT_GATE=off` | `"context_gate": "off"` | on | Disable the gate entirely (`off\|0\|false\|no`). |
| `MENTOR_CONTEXT_WINDOW` | `"context_window_tokens"` | unknown | The window the host compacts at (tokens). Turns on the percent thresholds; never guessed. Claude Code's `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is read after these two. |
| `MENTOR_CONTEXT_WARN_RATIO` | `"context_warn_ratio"` | `0.5` | Warn as a share of the window (a decimal in (0, 1]). Used only when the window is known. |
| `MENTOR_CONTEXT_HIGH_RATIO` | `"context_high_ratio"` | `0.65` | High (limit) as a share of the window. Used only when the window is known. |
| `MENTOR_CONTEXT_WARN_TOKENS` | `"context_warn_tokens"` | `200000` | Warn cap (tokens); the warn threshold itself when the window is unknown. |
| `MENTOR_CONTEXT_WARN_HIGH_TOKENS` | `"context_warn_high_tokens"` | 90% of limit | Warn-high threshold (tokens). |
| `MENTOR_CONTEXT_BLOCK_TOKENS` | `"context_block_tokens"` | `350000` | High (limit) cap (tokens); the limit itself when the window is unknown. Key name kept for compatibility. |
| `MENTOR_CONTEXT_TAIL_LINES` | — | `400` | Transcript tail window scanned for the measurement. |
| `MENTOR_CONTEXT_CHECKPOINT=off` | `"context_checkpoint": "off"` | on | Disable the between-batch context checkpoint only (literal `off`); the per-prompt gate keeps running. The gate's own kill switch above disables both. |
| `MENTOR_PLANNING_INTENT=off` | `"planning_intent": "off"` | on | Disable the planning-intent advisory hook entirely (`off\|0\|false\|no`). |
| — | `"test_command"` | auto-detect | `/mentor:ship` Step 4's test command — set it where auto-detect guesses wrong (monorepos). No env-var twin. |
| — | `"constitution_path"` | unset (`.mentor/constitution.md`) | Repo-relative path to a governing doc kept outside `.mentor/` (e.g. `docs/constitution.md`). Written by `/mentor:constitution`'s adopt-by-reference branch; `/mentor:plan` reads the constitution from here. No env-var twin. |
| — | `"diagram_renderer"` | unset (fallback) | `/mentor:preview`'s diagram renderer: `diagram-design` (you installed it) or `fallback` (hand-drawn SVG). Unset means the fallback is used and a decision-log row names how to install diagram-design; never asked. No env-var twin. |
| `MENTOR_CONTINUE=off` | `"continue": "off"` | on | Disable the `plan-continue.sh` Stop hook — an approved run then ends whenever the model stops. |
| `MENTOR_CONTINUE_MAX_IDLE` | `"continue_max_idle_blocks"` | `3` | Consecutive Stop blocks with no progress (plan.md and the working tree unchanged) before the hook lets the stop through with a notice to record a paused row. |

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms (unless the `<slug>` argument names a plan already `approved`/`in_progress` and owned here or unowned — then it prints `ALREADY APPROVED: <slug>` and arms nothing) **this worktree's own** `.planning.<wt-id>` marker (v2.23.0; closes the gate for this worktree only — an optional `<slug>` argument WARNs if that slug is already owned by a live sibling worktree); prunes stale sibling markers with a per-marker notice; refuses over a live legacy `.planning` (distinct refusal message); prints any live siblings as informational "also armed elsewhere" lines — and a `CONTEXT:` line (`WARN`, or `HIGH` at/over the limit: `context_block_tokens`, or 65% of a known window when that is lower — warn-only; the gate arms either way). A foreign-marker refusal (a DIFFERENT, still-live session owns this worktree's own marker) names the supported recovery: re-run with `--override-foreign-marker` once the user explicitly authorizes it — the flag re-arms past the guard and still prints who it overrode; it is the confirmed-override route, never a way to skip the confirm itself. |
| `hooks/plan-gate.sh` | **The one gate.** Fail-closed `PreToolUse` on Write/Edit/MultiEdit/NotebookEdit — denies in-repo writes while THIS worktree's own marker or the legacy repo-wide marker exists, even under `bypassPermissions`; a live sibling worktree's marker never denies here. Mentor's own `.mentor/` tree (where the plan file lives) is exempt, so the plan is always writable. Stale markers (>8h) self-heal on a would-deny write, each with a named notice. |
| `hooks/approve-plan.sh` | Re-anchors approval with a fresh disk read: the plan path, a drift notice when changed, and `planning ended — edit gate released`; without `--deliver` it also names the next step and the pointer to planning’s full run directive and the order save `verdicts/step-N.md` → PASS row → `record-write` → tick. Validates the plan (non-empty `.md` **newer than the marker**), releases this worktree's gate, and on Proceed (no flag) writes the run marker `.mentor/.run-<session_id>` (`slug=` + `started=`) when a session id is known. Promotes only plans **owned** by this worktree (or unowned, when no sibling marker is live) — never a sibling's in-flight draft; a live legacy marker only sweeps repo-wide when the approving session is the one that armed it. The approval sweep skips non-primary drafts that are still skeletons (no `## Goal check` or no implementation steps), preserving their sidecars. Flags map to the approval options: no-arg starts the run, `--deliver` (no run marker) prints the deliverable soft-stop (also printed on a re-run when the gate is already open); unknown flags — including the retired `--handoff` — are rejected. |
| `hooks/plan-open.sh` | Records the Write/Edit hash through `record-write` before opener-off or already-open exits. Auto-opens the Markdown plan for review the first time it is written (VSCode tab / OS default). When the plan has a review page (`.mentor/reviews/<slug>/review.html`), every Write/Edit of the plan also returns a reminder to regenerate the page's changed sections (`previewing` §7) before the turn ends. `previewing` opens its own page. |
| `hooks/context-gate.sh` | **Per-prompt plan pointer (Claude Code).** While this worktree has an armed draft (a stored `draft` owned by this worktree and newer than the gate) or this session has a run, prints the plan path, stored state, next step and drift notice when changed, including alongside all context-warning tiers. Every stored draft shows `next: drafting`; a run shows `step N/M` or `goal check`. With an armed gate but no such draft, prints `mentor plan: no plan file yet · it is created at research start (planning Step 2)`. **Context gate.** `UserPromptSubmit` — measures live context from the transcript: warns (~200k, or 50% of a known window when that is lower; re-arming on growth), re-warns near the limit, and warns `CONTEXT: HIGH` at the limit (~350k, or 65% of a known window when that is lower) — thresholds from `mentor_context_limits`, warn-only, never a question or a handoff steer. Since v2.34.0 it also carries the **planning-intent nudge** as its tier-2 output — an anchored opener ("help me plan…", "let's plan…") suggests `/mentor:plan <topic>` so a conversational planning ask doesn't silently skip the edit gate (`hooks/tests/test-planning-nudge.sh` covers it). Never blocks or erases prompts. Fail-soft; slash commands always pass. |
| `hooks/context-checkpoint.sh` | **Context checkpoint** (v2.37.0). `PostToolBatch` — the reading `context-gate.sh` cannot take: that gate is `UserPromptSubmit`-only, so any long autonomous stretch that collapses N human turns into one got zero readings in between (one real session grew ~247k tokens unseen). Fires the same WARN/WARN-HIGH/HIGH tiers between tool batches, rate-limited by its own `.context-checkpoint-<session_id>` marker (speaks on a tier rise or one re-arm step of growth: ~50k tokens, or 10% of a known window). **Advisory only, by ruling — never exit 2** (which would kill the agentic loop mid-step); every tier is a one-line size warning ending in the gate's progress-first sentence, never a handoff steer. Kill switches: the gate's own, plus `MENTOR_CONTEXT_CHECKPOINT=off` / `"context_checkpoint":"off"`. |
| `hooks/plan-continue.sh` | **Run continuation** (v6.0.0). `Stop` — while this session's run marker exists and its plan's **stored** state is `in_progress`, blocks the stop (`{"decision":"block"}`) with a reason naming the next unticked step. First match wins: off switch → no marker → stored state not `in_progress` (paused, failed, done) → `plan.md` untouched for 8h (deletes the marker) → 3 consecutive blocks with no progress (allows, with a notice) → block. Ignores `stop_hook_active` (true on every re-entry); never reads decision-log rows or decides what to do. Fail-open everywhere. |
| `hooks/plan-reattach.sh` | **Plan re-attachment (Claude Code).** `SessionStart`, with no matcher: startup/resume/clear/compact/fork. Emits one `hookSpecificOutput` block with `hookEventName: SessionStart` and `additionalContext`: path, stored state, ticks N/M, next step and drift notice when changed. An armed draft is a stored `draft` owned by this worktree and newer than the gate; every stored draft shows `next: drafting`. Silent without such an armed draft, exact-session run marker or owned `in_progress` plan. An unmatched owned run gets `resume with /mentor:plan <slug>`; a fork is told it owns no run. A missing `plan.md` names the sidecar state plus the newest `_plan.md` review copy for that slug, or says no copy was found. Read-only and fail-open; never creates a run marker. |
| `hooks/plan-state.sh` | **The one plan-state API** (not a hook — skills call it directly). `init` / `start` / `set` / `set-deps` / `record-write` / `drift` / `tick` / `verify` / `list [--owners]` / `current [--any]` / `query` / `sweep` / `context` / `dir` / `ensure-dir` / `relocate` / `gate`. `verify <slug>` backs planning's "Verify the write": four gating `CHECK:` lines — fence balance, table pipe-count uniformity, every step body inside `## Implementation steps` carrying a `Done when:`, and (v6.0.0, draft/unknown plans only) both `## Goal check` and `## Decision log` present (read via `mentor_plan_step_scan`, the one step-scan, so it can never disagree with `tick`/`query` about what a step is) — plus informational-only lines for Rev-note order, a stray ✅ on a non-step line, an `###` heading inside the steps section, and `CHECK: context` (the pre-approval context re-check folded into the same call). Exit 1 iff a gating check fails. Sole writer of `.state.json` (state, group, order, note, `deps`, `plan_sha256`, and `owner`/`owner_session` — the minting/re-owning worktree, stamped by `ensure-dir`/`init`/`relocate`); every write merges into the existing object, so keys it no longer writes survive. Derives effective state from the plan's ✅ ticks; `current` is group-aware and ownership-scoped to plans owned by this worktree (`--any` for a deliberate repo-wide read) — after a split it reports the whole owned group rather than whichever child finished last. `list --owners` adds an OWNER column for slug-reuse scans. `query` computes the repo-wide plans+deps+owner listing fresh on every call (see "Listing plans"). `dir` is the one repo-scoped `.mentor` path derivation — skills call it instead of hand-rolling `git-common-dir` snippets that drift. `relocate <src-plan-dir>` copies a plan from a DIFFERENT repo's `.mentor/plans/<slug>` into this one (run from the destination repo) and re-owns it here in one step — never deletes the source, and warns about repo-relative paths left stale under "Suggested first steps" and about the source repo's plan-gate no longer protecting edits made back there. `gate` is the one plan-gate marker status check for THIS worktree (`ARMED`/`STALE`/`ARMED_ELSEWHERE`/`RELEASED`, read-only; `--verbose` adds per-token fields, e.g. `owner_worktree=` on `ARMED` or one `elsewhere=` line per live sibling on `ARMED_ELSEWHERE`) — skills call it instead of re-deriving the marker path and 8h staleness window themselves. `sweep <pattern> [--roots plans\|repo] [--ignore-case]` is the one portable search over mentor's own state: it prints `SWEEP: roots=N files=N hits=N` **before** the hits and exits like grep — `0` hits found, `1` files read but nothing matched, `2` nothing was searched (plus an explicit `NOTHING-SEARCHED` line) or a usage error — so a zero result can be told apart from a search that never read a file. Root sets: `plans` (default) = the main repo's `.mentor/plans`, `repo` = the whole worktree minus `.git/`. It exists because `.mentor/` is gitignored and ignore rules apply only while **grep itself** walks: `find` does the walking here and grep only reads the list it is handed, so gitignored state is reached under GNU grep, BSD grep and ugrep alike. planning's Step 2 research sweep calls it. |

Registered hooks: `PreToolUse` (Write|Edit|MultiEdit|NotebookEdit) → `plan-gate.sh`,
`PostToolUse` (Write|Edit) → `plan-open.sh`, `UserPromptSubmit` → `context-gate.sh`,
`PostToolBatch` → `context-checkpoint.sh`, `Stop` → `plan-continue.sh`, and
`SessionStart` (no matcher) → `plan-reattach.sh`: **six registrations**, all Claude-only.
Nothing is registered on Task/Agent calls.

### Commands and skills never share a name

Every command is a **thin entry point** whose body is a skill — and the two must never
carry the same name. When they do, `Skill({"skill": "mentor:<n>"})` resolves to the
COMMAND file and the skill body becomes unreachable: the call returns the command's own
text, the retry returns "already loaded above; instructions unchanged", and every
mandatory step inside the SKILL.md is silently skipped. The skill's `description:` is
shadowed by the command's too, so the skill cannot be reached conversationally either.

Hence the naming split: `/mentor:plan` → skill `planning`, `/mentor:ship` → `shipping`,
`/mentor:grill` → `grilling`, and so on. **Command names are the user-facing
surface and never change; the skill takes the distinct name.**
`hooks/tests/test-skill-command-collision.sh` fails the build if any pair collides
again, if a rename leaves a skill's frontmatter `name:` behind, or if any `Skill()` call
site points at a skill that no longer exists. Prose could not enforce this — each
colliding command used to carry a written fallback for exactly this case, and it went
unused in practice.

### Known limitations

- **Bash is not gated.** The gate covers the Write/Edit/MultiEdit/NotebookEdit
  path (Claude's near-universal edit path); the skill instructs against
  repo-mutating shell commands during planning but does not enforce it.
- **Gates are per-worktree; plans stay shared (v2.23.0).** Each git worktree now
  arms and denies against its own `.planning.<wt-id>` marker
  (`lib/state.sh`'s `mentor_worktree_id`), so planning in one worktree no longer
  blocks writes in another. Every worktree still drafts into the SAME
  `.mentor/plans/` tree, and `approve-plan.sh` only promotes plans it **owns**
  (see "Unowned plans" below) — a sibling's in-flight draft is never swept.
  Two sessions in the SAME worktree still serialize on the one marker; that
  stays intentional.
- **A pre-upgrade bare `.planning` is a reserved legacy marker that blocks
  EVERY worktree**, fail-closed, until it is released or goes stale — only the
  session whose id matches the marker's `session=` can approve through it (a
  repo-wide sweep); every other session is refused and the marker is left
  untouched. `begin-plan.sh` refuses to arm a new per-worktree marker over a
  live legacy one (a distinct refusal message names it), so a worktree cannot
  end up racing both kinds of marker at once.
- **Unowned plans.** A plan's sidecar `owner` is stamped at creation
  (`ensure-dir`) and re-stamped by `init` — the normal flow — but a
  plan can still be unowned (e.g. drafted, then `init` skipped). While ANY
  sibling worktree's marker is live, `approve-plan.sh` excludes unowned
  candidates from both "current plan" resolution and the promotion sweep,
  naming them rather than silently promoting or silently skipping them. With
  no sibling marker live, an unowned plan stays a promotion candidate (the
  original, solo-worktree behavior).
- **`git worktree move`/removal orphans state.** Moving or removing a worktree
  leaves its `.planning.<wt-id>` marker behind with nothing left to deny: in
  the moved tree the gate reads open silently (`mentor_worktree_id` now
  derives a different id there), and an approval run from the moved tree lands
  against that already-open gate, leaving the plan at `draft` instead of
  promoting it. Recovery: re-arm (`/mentor:plan`) and re-run `init` to re-own
  the plan in its new worktree. The same move can orphan a plan's sidecar
  `owner` (pointing at a wt-id that no longer resolves anywhere) — recovery is
  the same: `/mentor:plan <slug>` re-owns it via `init`.
- **Relocating a plan into a DIFFERENT repo** (not a worktree of the same
  repo) is a separate case from the one above — `init` alone re-owns a plan
  that's still in the SAME repo tree; it cannot move a plan's files across
  repos. Use `plan-state.sh relocate <src-plan-dir>` (v2.26.0) from the
  destination repo instead of hand-copying: it creates the plan there via the
  same 700-permission primitive `ensure-dir` uses internally (never a raw
  `mkdir -p`), copies the plan dir over, and re-owns it to the destination
  worktree in one step.
  The source is never deleted — remove it yourself once you've confirmed the
  copy. Two things it can't fix for you: paths under the plan's "Suggested
  first steps" that were relative to the SOURCE repo go stale after the move
  (`relocate` greps for and warns about these, but doesn't rewrite them), and
  the destination repo's plan-gate only ever protects writes made IN the
  destination repo — if the plan's remaining work still touches the source
  repo, that repo's own gate (if still armed) is the only thing guarding it.
- **A cached plugin copy older than v5.0.0 strips unknown keys.** Since v5.0.0
  `plan-state.sh` merges each write into the existing `.state.json`, so keys it
  does not write — legacy fields and hand-added keys alike — survive. Older
  copies rebuild the object key by key and drop whatever they predate (e.g.
  `owner`/`owner_session` on a pre-v2.23.0 cache) the next time anything writes
  that sidecar. Each degrades to the field's own unset handling; nothing is
  corrupted.
- **Same-slug concurrent drafting is unguarded beyond a warning.** Two
  worktrees can now draft the same slug at once (the old repo-global marker
  made this unreachable). `begin-plan.sh` and `plan-state.sh init`/`ensure-dir`
  WARN when a target slug is already owned by a worktree with a live marker,
  but nothing blocks the second worktree from writing anyway — coordinate
  manually.
- **`nosession` marker attribution.** A marker armed without
  `$CLAUDE_CODE_SESSION_ID` set records `session=nosession`, which cannot be
  told apart from any other `nosession`-armed marker — unchanged from before
  v2.23.0.

### Plan format

Plans are single self-contained **Markdown** documents — Mermaid-first
(` ```mermaid ` flowchart/sequence/ER/state), with GFM tables, ASCII diagrams,
and GFM alerts. Portable: renders richly on GitHub/GitLab and any Mermaid-capable
viewer. One visualization per significant change, never two representations of
one thing. New plans carry a plan-level `Goal:` below the title and Rev lines, and
every step's `Goal:` names the scenarios it serves. Since v6.0.0 a plan also carries `## Playbook` (the runtime pick, or `none`),
`## Goal check` (the done predicate), and a flat `## Decision log`
(`# · use case · decision · why · evidence · result · review?`); the run appends
`## Done review`, where the log is rendered grouped by use case with `review?: needed` rows
first.

**Optional review page (`/mentor:preview`):** when you explicitly ask for a
page, the `previewing` skill builds **one** page per subject at
`.mentor/reviews/<subject-slug>/review.html`, drawing only what the subject
changes: scenarios with a mockup of every surface they reach (each edge case
its own card, each sequence under the scenario that starts it), the C4 levels
that move, the changed data and contracts, and the decisions, with a comment box and Copy on every card. Open questions are
asked in chat one at a time, and for a mentor plan each answer becomes a
decision row. The subject stays the source of truth: when a plan with a page
changes, its page is regenerated in the same turn, and the page carries the
hash of the plan it was built from. During planning, `planning` Step 5 delegates
here (the subject slug = the plan slug); standalone, the skill previews **any**
subject — no plan file required.

### Viewing the plan

The plan auto-opens the first time it is written (`plan-open.sh`): as a
**VSCode editor tab** when a VSCode CLI is available (toggle preview with ⇧⌘V;
install a Mermaid preview extension to render the diagrams), otherwise the OS
default Markdown handler. `previewing` opens its own review page in the
browser, honouring the same `MENTOR_PLAN_OPEN` and `MENTOR_PLAN_OPENER` knobs.

Knobs — set under `env` in `~/.claude/settings.json` (a shell `export` won't reach the hook):

| Var | Effect |
|---|---|
| `MENTOR_PLAN_OPENER` | `auto` (default) · `vscode` · `chrome` · `system` |
| `MENTOR_PLAN_VSCODE_BIN` | Force the VSCode CLI binary (default: auto-detect `code` / `cursor` / `windsurf` / …) |
| `MENTOR_PLAN_OPEN=off` | Disable auto-open entirely |

## Changes in v6.4.1

Compatibility decision: **non-breaking: eval scoring fixes; no workflow or durable-state change**.

- Native Read warnings and reminder metadata no longer count as returned file data.
- Shell read credit keeps punctuation-only echo separators and per-path failures; `$` commands earn none.
- Decorated owner/history assertions are compared with the marker; honest prose remains valid.
- Eval documentation names the isolated-session threat model and unsupported evidence forms.

## Changes in v6.4.0

Compatibility decision: **minor release by owner decision; two public playbook skills are removed.**
`playbook-software-change` and
`playbook-retrospective` leave the public skill list. Mentor exposes seven public
skills and five planning-owned runtime playbooks: software-change, retrospective,
investigation, hillclimb and prototype. Invoke planning for these goals; released
plan selections still resolve through index aliases in either `## Playbook` format.
No hidden compatibility skills or durable-data rewrite are needed.

- **Verdict-gated ticks.** Save the latest `verdicts/step-N.md` → PASS row →
  `record-write` → tick. A new tick reads the saved PASS once; canonical files take
  precedence. Released legacy verdict paths, optional headers and leading comments,
  and historical tick idempotency stay supported, including the labelled
  `self-graded` fallback when subagents are unavailable.
- **Roles and goals.** Resolve agents by described purpose, honoring explicit session
  mappings first. Every brief opens with the plan-level `Goal:`; draft steps trace to
  scenarios. The full run directive lives only in planning.
- **Evidence reuse.** Fresh graders can cite prior deterministic output only for the
  same check and predicate, with identical command and cwd on a proven-identical
  clean tree and unchanged inputs with complete evidence. Re-run live CI,
  external-state checks and timing-sensitive repeats.
- **Principles and Run rules.** Apply the runtime principles catalog at named decision
  points and log only choices it changes. Indexed playbooks supply bounded optional
  Run rules; rationale remains editing-only. Investigation delivers a read-only cited
  answer, hillclimb requires its target and minimum attempts within caps, and prototype
  delivers observed variants for the human to pick without shipping prototype code.
- **Both hosts and isolated live evals.** Portable skills retain serial fallbacks;
  hooks, subagents and command facades depend on the adapter. Deterministic contract
  tests cover bundled references and released readers. Live selection evals stage the
  candidate skills and fixture in private workspaces, testing positive and negative
  playbook selection. Claude disables inherited instructions and memory and checks
  its init inventory for contamination; Codex uses ephemeral read-only sessions.
  See [evals](evals/README.md) for the separate live commands and isolation details.

## Changes in v6.3.0

**The plan stays attached through its lifecycle.** Research starts with a plan-file
skeleton; rejection feedback goes into the decision log and the answering revision gets
a Rev line. On every host, `record-write`, `drift` and `tick` maintain the optional
`plan_sha256` baseline with known / changed / unknown drift.

- **Per-prompt pointer (Claude Code).** An armed draft (a stored `draft` owned by this
  worktree and newer than the gate) or this session's run gets its path, stored state
  and next step, including alongside context warnings. Every stored draft shows
  `next: drafting`; with an armed gate but no such draft, the pointer says
  `mentor plan: no plan file yet · it is created at research start (planning Step 2)`.
- **Approval re-anchor.** Approval reads the file fresh and names its path, change notice when needed and released gate; Proceed also names the next step and the order save `verdicts/step-N.md` → PASS row → `record-write` → tick.
  The approval sweep skips non-primary drafts that are still skeletons (no
  `## Goal check` or no implementation steps), preserving their sidecars.
- **SessionStart re-attachment (Claude Code).** Startup, resume, clear, compact and fork
  receive one block for a live plan: path, stored state, ticks and next step. Armed drafts
  must be stored `draft`, owned by this worktree and newer than the gate; every stored
  draft shows `next: drafting`. Unmatched
  owned runs get one recovery command; forks own no run. Missing files name the newest
  available review snapshot or report no copy found. Inactive sessions stay silent.
  This is a new purpose for SessionStart; v5's `handoff-check.sh` stays retired.

Compatibility decision: **non-breaking: no lifecycle state or approval-option change**.
Legacy sidecars without a hash read `unknown`; Claude-only hook output is declared in
`capabilities.json`, and hosts without hooks use the portable tracking commands.

## Changes in v6.2.0

**The plan stays in the file.** Approval chat shows a pointer card of at most 5 lines;
the question names the plan path and Rev. Content revisions append a Rev note and use
whole-section edits, with a change note on a re-ask only when a Rev line was added since
the previous ask. Type `show plan` in Other to
print the full body once and re-ask without approving. Run-end chat reports one verdict
line with step, review-decision, and leftover counts; leftovers are named one per line
under the verdict line. The Done review and grouped
decision log stay in `plan.md`. Playbook delivery into a PR body is unchanged.

Compatibility decision: **non-breaking: no state or option change; plans gain a Rev
changelog that `verify` reports but never requires, and `show plan` gives the old view
on request**. Existing plans remain readable without a Rev line.

## Changes in v6.1.0

**A retrospective playbook: `/mentor:retro`.** Mentor could plan and run work but never
looked back — lessons stayed in the session and steps the user repeated by hand never became
skills. The new `playbook-retrospective` skill, inspired by Cursor's pstack `/reflect`, turns
one finished session into approved skill changes: new skills for repeated procedures, edits to
existing ones, and description tunes, plus reported proposals it does not apply. It runs inside
mentor's pinned core concept — you approve once, and the retro runs to its done-check — reusing
the edit gate, decision log, independent verifier and Done review with **no new hooks, scripts,
state tokens or `plan-state.sh` subcommands**.

- **Works for orchestrated, compacted sessions on both hosts.** The hard requirement was that
  the retro handle a session where **Claude Code or Codex was the orchestrator**, delegating to
  subagents and agt workers, and **compacted several times** — after which the agent's own
  context holds only the latest summary. So it never reviews from memory: the parent rebuilds the
  session from disk first as an **evidence graph** — a frozen cutoff, compaction epochs, recursive
  Claude subagents / Codex child rollouts and optional agt workers (kiro/agy workers stay opaque),
  each reduced to a `jq` digest under `evidence/`. Three lenses and a synthesizer read the digests;
  raw transcripts never enter the parent's context.
- **Thin facade, no new machinery.** `/mentor:retro [session id | path]` refuses while this
  session's own run is `in_progress` or paused (stored `approved`) — reading the state with
  `jq` and failing closed without it — arms the gate exactly as `/mentor:plan` does, then
  hands `planning` a retro goal that loads `playbook-retrospective` (never co-loaded with
  `playbook-software-change`). `--claude-config` / `--codex-home` / `--agt-home` point it at
  explicit source-transcript roots (overriding `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `AGT_HOME`);
  an unavailable explicit root yields a `partial` result with no fallback to the real stores.
- **Outputs.** The synthesizer sorts findings into Accepted / Rejected / Backlog; each Accepted
  row carries its own done-check (`quick_validate.py` passes, the description triggers on its
  motivating prompt, and, when the destination convention uses a symlink, that link is relative and
  resolves) and names its destination. Backlog items, constitution proposals, core-concept
  proposals and other-tool-config proposals go to Leftovers, reported but never applied.
- **Where skills land.** New skills follow the workspace's documented skill-storage convention —
  for this repo that is `plugins/*/skills/` edited directly under the repo gates; with none
  documented, `.claude/skills/<name>` on Claude Code. No Codex project-skill path is promised: on
  Codex, or when a Codex copy is wanted, the path to verify is reported as a Leftover. Installed
  plugin skills are copied to the workspace and the copy is edited, never the cache.
- **Boundary with loom.** Mentor retro covers **one** session, interactively, with one approval,
  on both hosts. loom covers batches across sessions, uses a ledger, runs headless, and is Claude
  Code only. Nine skills are now staged in the trigger evals; `capabilities.json` gains a
  `retrospective` workflow.
- **Serial fallback.** When the host has no subagents the lenses run serially in-thread and are
  labelled `self-graded`; nothing depends on agt or loom.

## Changes in v6.0.2

- Adds a monotone plugin icon (`.claude-plugin/icon.png`): a loop that ends in a check.

## Changes in v6.0.1

- `constitution-authoring`'s example principles are no longer software-only.
- The approve-plan run directive and the Stop hook's block reason name stop words ("stop",
  "pause", "wait") alongside always-pause items as a reason a run pauses.
- Planning's no-repository fallback no longer names git; the README gains an install line.

## Changes in v6.0.0

**BREAKING CHANGE — mentor adopts the core concept pinned in `AGENTS.md` → Mentor core
concept: you approve the plan once, then mentor runs it until the done-check passes,
pausing only for always-pause actions and logging every decision for review.**

- **The charter is amended.** "Not a workflow engine" becomes "not a hand-rolled sequencer":
  native host primitives (a Stop hook, verifier subagents) may drive an approved run; a bash
  re-poll ladder stays banned. `test-hook-roster.sh` now pins five hooks.
- **General-purpose main workflow; software steps move to a playbook.** `planning` never
  names git, tests, CI, or PRs. It picks `playbook-*` skills at runtime by matching the goal
  against their descriptions (`## Playbook` line + a log row). v6 ships one,
  `playbook-software-change`, which supplies research directives, the Definition of done,
  extra always-pause items, the deliver mode (`shipping` → `merging`), and evidence kinds.
- **Triage before asking.** Planning Step 3 has four buckets — answer from the material, run
  an experiment, resolve a decision-maker by described purpose (planning → Role resolution), or, only for a product call, ask you. Grilling uses the same triage and runs
  before approval only; its trivial-implement branch is gone.
- **New plan sections.** `## Goal check` (the done predicate), a flat `## Decision log`
  (`# · use case · decision · why · evidence · result · review?`), and `## Playbook`. The
  run writes `## Done review` (per scenario: expected, observed, evidence; a runbook when
  hand-over needs steps; leftovers) on every terminal transition, with the log grouped by
  use case. `plan-state.sh verify` fails a draft plan missing the Goal check or the log;
  plans past draft are unaffected.
- **One gate, then a loop.** Approval options are Proceed · Deliver plan only · Keep
  planning. Proceed writes `.mentor/.run-<session_id>`; the new `plan-continue.sh` Stop hook
  blocks a premature stop while the plan's stored state is `in_progress` (idle cap 3, stale
  after 8h, off switch `MENTOR_CONTINUE=off`). Paused = `approved` + `paused: row N` note.
- **Independent grader.** `skills/planning/references/verifier-contract.md` (revived from
  v4's dispatch-agents) grades every step, every Verification topic, the Goal check, and the
  PR before a merge. The step order is save
  `verdicts/step-N.md` → PASS row → `record-write` → tick. Hosts without subagents label
  their grades `self-graded`.
- **Constitution as the autonomy contract.** New sections Always-pause list, Decision
  authority, Definition of done, and a built-in general always-pause default.
- **Shipping and merging.** Inside a plan run, ship asks nothing reversible, never offers
  "ship anyway", and puts the Done review in the PR body; merge grades the PR with a verifier,
  pauses with the runbook's Before block, and walks the After block line by line.
- **Removed: `plan-split`** and the split approval option. Legacy
  split groups (`group`, `order`, `superseded`) still read. An oversized plan moves isolated
  deliverables to `## Out of scope`.
- **Previewing** no longer asks to install diagram-design: it uses the fallback renderer and
  logs a row naming the install command. Its Decisions section renders the decision log.

## Changes in v5.0.0

**Breaking: mentor is cut down to 8 skills and 6 commands.** Most of its surface had
outlived its use, so this release removes it, along with the hooks, state-helper
features, tests and evals that existed only to serve it.

- **Skills removed (11):** `plan-review`, `plan-domain-frontend`, `plan-domain-backend-api`,
  `plan-domain-architecture`, `plan-domain-dynamic`, `touring`, `plan-track`,
  `dispatch-agents`, `deferring`, `handoff-note`, `resuming`. **Kept (8):** `planning`,
  `previewing`, `plan-split`, `shipping`, `merging`, `grilling`, `constitution-authoring`,
  `frontend-self-ex-review`.
- **Commands removed (7):** `/mentor:tour`, `/mentor:zoom`, `/mentor:track`,
  `/mentor:defer`, `/mentor:mode`, `/mentor:handoff`, `/mentor:resume`. Typing one now
  reports an unknown command. **Kept (6):** `/mentor:plan`, `/mentor:preview`,
  `/mentor:ship`, `/mentor:merge`, `/mentor:grill`, `/mentor:constitution`.
- **Hooks removed:** `set-mode.sh`, the `SessionStart` hook `handoff-check.sh`, and the
  `PreToolUse` Task|Agent hook `dispatch-contract.sh` (with `dispatch-contract.txt`).
  `begin-plan.sh` no longer prints a `MODE:` line.
- **Mentor no longer prescribes subagent handling.** No dispatch annotations, no
  `Dispatch: skipped` line, no verifier-dispatch rule, no research-dispatch preflight, no
  agent close-out rules; the host harness decides. `## Verification` stays a list of checks.
- **Planning.** Domain routing (the old Step 3) is gone; resolving open decisions is now
  Step 3. The approval options are **Proceed · Deliver plan only · Keep planning**, and on
  an oversized plan the split option led the same three (removed in v6.0.0). "Review the plan (staged)" and the mode-driven order swap are gone; a
  plan-quality review before approval is `/mentor:grill` on the drafted plan.
- **Explicit post-approval flow.** On Proceed the main thread implements the steps, runs
  `plan-state.sh tick` as each `Done when:` passes, runs every `## Verification` check, then
  sets the plan `implemented` (or `failed` with a note), names follow-ups in its report,
  and offers `/mentor:ship`.
- **Split children** are built by running `/mentor:plan <child-slug>` on each. The
  split's retirement check now looks at `deps` instead of a parent tree.
- **An approved plan goes straight to implementation.** `/mentor:plan <slug>` on a plan
  that is already `approved` or `in_progress` — owned by this worktree or unowned — makes
  `begin-plan.sh` print `ALREADY APPROVED: <slug>` and not arm the gate; the planning skill
  then jumps to its implement section (direct or Codex entry reads the state itself). A
  plan swept in as not individually reviewed is confirmed with the user first. To re-plan,
  `plan-state.sh set <slug> draft`, then `/mentor:plan <slug>`.
- **Fix: helper paths in skills and commands now resolve.** Claude Code substitutes only
  the exact `${CLAUDE_PLUGIN_ROOT}` token in skill and command text; the
  `${CLAUDE_PLUGIN_ROOT:-}` form stayed literal and expanded empty in Bash. Every site now
  uses the braced token, and the helper probes test `-f` (plan-state.sh is not executable
  in git) instead of `-x`.
- **Merging** offers **Merge anyway / Leave open** when the base branch is already broken,
  and names leftover work in its report instead of parking it. Its plan close still writes
  `implemented --note "merged: PR #<n> <sha>"` in every state but `superseded` (an
  already-`implemented` plan gains the merge record); the `open:` carry-forward is gone.
- **`plan-state.sh` drops** `policy`, `brief`, `claim`, `set-parent`, `set-priority`,
  `set-category`, `handoff-path` and `handoff-selfcheck`, plus `init`'s `--deferred`,
  `--from`, `--parent`, `--priority`, `--category` and `query`'s tree, parent, origin,
  priority, category and handoff filters. `sweep`'s default root is now `plans`. Sidecar
  writes now merge, so legacy `origin`, `parent`, `priority`, `category` and
  `deferred_from` keys are preserved but never read.
- **Existing `.mentor/` data is left in place.** Handoff notes, tour pages, zoom pages,
  deferred stubs, the extra sidecar fields and the `mode`/`dispatch` keys in
  `config.json` stay on disk untouched; nothing reads them and nothing migrates them.
- **Metadata:** the plugin description drops "review", the `handoff` keyword is gone, and
  the Codex default prompt is now "Grill this plan before I approve it." `capabilities.json`
  drops the `review-and-dispatch` and `durable-state` workflows (and their
  `marketplace/support-matrix.md` rows); `planning` and `visual-artifacts` list only the
  kept skills.
- **Evals:** cases expecting a removed skill are deleted; four of their prompts stay as
  `none` negatives, and the harness stages the 8 kept skills.

## Changes in v4.3.0

**The context gate can warn on a share of the window.** When mentor knows the size of the
window the host compacts at, it first warns at 50% of it and puts the limit at 65%, each
capped by the old fixed numbers (200000 / 350000), whichever comes first. It still only
warns: the three tiers and every knob you already set keep working.

- **Percent warnings stay off until a real window size is known.** Mentor never guesses
  one. Set it yourself (`MENTOR_CONTEXT_WINDOW`, or `"context_window_tokens"` in
  `.mentor/config.json`), or let the host report it (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`,
  or a host adapter's `context-window` file). Until then the thresholds are v4.2.0's,
  except that a limit set below the warn cap now pulls the warn tier down with it (see
  **One derivation** below).
- **What you will notice once a window is known:** a 200k-window session is first warned
  at about **100k**, not 200k, and its limit is 130k. A 1M session still first warns at
  200k, because the caps win. The re-warn step becomes 10% of the window.
- **New knobs:** `MENTOR_CONTEXT_WINDOW` / `"context_window_tokens"`,
  `MENTOR_CONTEXT_WARN_RATIO` / `"context_warn_ratio"` (0.5) and
  `MENTOR_CONTEXT_HIGH_RATIO` / `"context_high_ratio"` (0.65). `context_warn_tokens` and
  `context_block_tokens` keep their values and now act as the caps.
- **Every warning says what to do first.** Each tier, in `context-gate.sh` and
  `context-checkpoint.sh`, ends with "Before compacting, record your progress in the
  plan: …". With a known window the size reads `~N tokens (r% of window)`.
- **One derivation.** `mentor_context_limits` in `hooks/lib/state.sh` replaces the three
  copies of the threshold logic (`context-gate.sh`, `context-checkpoint.sh`,
  `mentor_context_verdict`). It clamps warn ≤ warn-high ≤ high and only ever lowers a
  value. The visible effect: a limit set below the warn cap now pulls the warn tier down
  with it, so `context-checkpoint.sh` no longer stays silent over a low limit, and
  `begin-plan.sh` / `plan-state.sh context` report the clamped warn value.
- **Fix:** the planning-intent nudge wrote its once-per-session marker under a hardcoded
  `~/.claude`. It now follows `MENTOR_STATE_HOME`, then `CLAUDE_CONFIG_DIR`, then
  `~/.claude`.

## Changes in v4.2.0

**The context gate only warns now.** Reaching the context limit used to stop you with a
question — "Hand off to next agent (Recommended)" or "Proceed anyway (bypass for this
session)" — and every softer tier suggested `/mentor:handoff → /mentor:resume`. Now each
tier is a one-line size warning and the work carries on:

- **`context-gate.sh` / `context-checkpoint.sh`** — WARN, WARN-HIGH and the new **HIGH**
  tier (≥ `context_block_tokens`, default 350000) print a warning only: no
  `AskUserQuestion`, no bypass, no handoff or end-the-turn steer. A fresh handoff note no
  longer changes the output — there is no question left to suppress.
- **`begin-plan.sh` and `plan-state.sh context` never refuse.** Over the limit they print
  `CONTEXT: HIGH` and proceed, so `/mentor:plan` and `/mentor:track` keep working at any
  size. The verdict vocabulary is now `HIGH|WARN|OK|UNKNOWN` (`ASK` and `HANDOFF` retired).
- **`bypass-context.sh` removed**, with `mentor_context_bypassed`. Leftover
  `.context-bypass-*` markers are ignored.
- **Planning approval (Step 6) has no handoff options.** "Hand off to next agent" and
  "Pause — still drafting" are gone, along with the context-driven option rows: the menu
  depends only on whether the plan is oversized. `approve-plan.sh --handoff` is retired
  (now an unknown flag). The planning skill no longer offers a handoff when implementation
  is blocked, and grilling no longer routes its close to `/mentor:handoff` on a large
  session.
- **Unchanged:** `/mentor:handoff`, `/mentor:resume`, `handoff-check.sh`, and every
  threshold knob name. Typing `/mentor:handoff` into the approval question's "Other" still
  writes a note without approving.

## Changes in v4.1.0

**A self-explanatory UI review skill: `frontend-self-ex-review`.** Ask for a screen that explains
itself — "self-explanatory", "textless", "minimal copy", or plainly "too much text", "users don't
know what to click", "make it obvious what to do next" — and mentor reviews it against one
principle: *remove the need to explain the interface, not the labels and cues that make it
understandable.* Every visible string is classified by purpose (essential · redundant ·
decorative · contextual help · user content), never by element name or keyword — a
`Description` column of user data or a `Quotes` page of quotation records survives a "remove the
descriptions and quotes" ask. Conflicts resolve safety and accessibility first, then task
clarity, then less copy, then minimalism; word count is never the evidence. A general UX/UI or
visual review with no self-explanatory goal does not trigger it.

- **Feedback only, two modes.** *Audit* (default) returns findings tied to `file:line`, each
  with its proposed change tagged **small fix** or **needs a plan**; *verify* checks a change
  already made (runs what the project has; reports observed · executed · inferred · not tested,
  and never rounds an unrun check up to a pass). The skill writes no files and no plans —
  applying the fixes or planning the bigger ones is follow-on work for the session.
- **Isolated from the rest of mentor.** The skill reads no `.mentor/` state, calls no mentor
  helper, and never names a mentor command; only the standard host-portability paragraph every
  mentor skill carries mentions the plugin. No other mentor skill calls it: it runs only when
  the ask is for a self-explanatory screen.
- **`plan-domain-frontend` gains its own UX lens.** Research now captures each surface's copy,
  primary action, and states; the plan's delta rows carry content/interaction decisions made by
  purpose, never by keyword; UI steps get automatable `Done when:` checks and the plan's
  Verification section gets one hands-on check as its own topic. Its rule 1 splits ownership
  with no overlap: the design skill owns visual design, the UX lens owns content and interaction.
- **Capability matrix.** New `ux-review` workflow, supported on Claude Code and Codex.
- **Twelve acceptance cases** ship in `references/acceptance-tests.md`, each with a concrete
  fixture and failure conditions; fourteen trigger-eval queries (60–73) cover core and
  plain-wording triggers and near-misses against `plan-review`, `touring`, `previewing`,
  blog-copy editing, an aesthetic restyle, a general UI review, and a component code review.

## Changes in v4.0.0

**Breaking: zoom is removed, and `/mentor:preview` replaces it.** One scenario-based review
page per subject replaces the topic × perspective zoom pages.

- **New skill `previewing`, command `/mentor:preview [subject]`.** It writes one page,
  `.mentor/reviews/<subject-slug>/review.html`, opens it, and offers to publish it as a
  private Artifact on Claude. The page is one scroll, dark by default, with a contents sidebar
  that stays in view. It draws only what the subject changes: scenarios with a mockup of every
  surface a scenario reaches (web, mobile, CLI, chat, assistant, API, email, push, or a surface
  no catalog row names), each edge case as its own card (`S1a`, `S1b`), one Before/After switch
  per scenario, each sequence under the scenario that starts it, the C4 levels that move, the
  changed data and contracts, and the decisions. The footer names every section left out.
- **Two answer channels.** Open questions are asked in chat one at a time, cleanest option
  first; for a mentor plan each answer becomes a decision row in the plan. Every card has a
  comment box with Copy, and the copied block names the card, variant and view.
- **Plan and page stay in sync.** The page carries the hash of the plan it was built from.
  `planning`, `plan-split` and `previewing`'s own question loop regenerate the changed sections
  in the same turn a plan changes; `plan-open.sh` reminds the agent after any Write/Edit of a
  plan that has a page; `plan-review` reports a stale page.
- **Diagrams come from diagram-design.** When it is missing, `previewing` asks once whether to
  install it (`https://github.com/cathrynlavery/diagram-design`) and saves the answer as
  `diagram_renderer` in `.mentor/config.json`. Declining draws hand-made SVG in diagram-design's
  style, with Mermaid only for a diagram that keeps failing its layout check.
- **The mockup contract now covers every surface.** `references/surface-mockup-contract.md` and
  `references/surface-catalog.md` (11 primitives, 20 families, a shape fallback) replace
  `ui-mockup-contract.md`. Variants and Before/After switch with CSS radios only; the page's own
  behaviour (Copy, drafts, theme, marking the contents) is one footer script, a section may add one scoped script, and the project's pinned
  CSS framework loads as a script; publishing is allowed. A real captured picture
  is added beside a live mockup only where pixels matter, as a file in `shots/`, never base64.
- **`/mentor:zoom` is a stub.** It prints one line saying it is now `/mentor:preview`, then runs
  it with the same arguments.
- **`.mentor/zooms/` is no longer read or opened; existing pages are left on disk (delete them by
  hand if unwanted).** Nothing in 4.0.0 reads, opens, moves or sweeps `.mentor/zooms/`, the
  no-repo `zooms/` tree or a pre-v2.12 `plans/<slug>/zoom/` folder: `plan-open.sh` opens only
  `plan.md`, `begin-plan.sh` no longer relocates those folders and its `.opened` sweep reaches
  only each plan folder's top level and its `tour/` folder, and `plan-review`, `handoff-note`,
  `plan-split` and `touring` name `.mentor/reviews/` instead. The old pages stay gitignored.
- **Trigger evals.** Queries 21–24, 32 and 44 now expect `previewing`; queries 56–59 add two
  core triggers and near-misses against `plan-review` and `touring`.

## Changes in v3.0.0

**Mentor stops being a workflow controller.** The plugin's primitive is a set of skills
that invoke at the right moment — not a machine that drives a run. Two subsystems are
gone, every surviving skill is restyled as an independent primitive, and a charter plus a
regression test exist to keep the machinery from growing back.

**Removed: unattended continuation (the v2.37.0 per-step loop).**

- `plan-state.sh instant` and its `GO|DEFER|ASK|HOLD|DONE|NO_STEPS|UNRESOLVED` ladder,
  the `instant` mode axis (`/mentor:mode instant-on|instant-off`), `--confirm` on
  `/mentor:resume`, the per-plan `mentor/<slug>` branch, the end-of-run auto-commit, the
  `instant-run-*.md` run records, `mentor_get_instant`, the outward-action patterns, and
  `hooks/tests/test-instant.sh` are all deleted.
- `dispatch-agents`' "Unattended continuation" section is gone whole. "Executing the
  dispatches" is now the only execution path, and it is attended.
- `/mentor:mode` is **two** axes: approval-gate default and dispatch preference.

**Removed: the `plan-touring` skill and `/mentor:plan-tour`.** Pre-approval paged
walkthroughs are gone; `/mentor:tour` (published, post-approval, pass/not-pass acceptance)
and `/mentor:zoom` (topic × perspective HTML) remain. `plan-open.sh` no longer opens
`plans/<slug>/tour/*.html`.

**Every skill is now an independent primitive.** Two adversarial isolation audits over all
18 surviving skills found 69 places where a skill mandated a sibling as continuation,
assumed which parent invoked it, claimed the session's lifecycle, governed a sibling's
internals, or stored its rules in a sibling's file. All are fixed. `deferring` needed no
change and is the reference shape.

User-visible behavior changes worth naming, so they don't read as regressions:

- **`/mentor:resume` always asks.** The unique-entry auto-select (and its announcement)
  is gone with the `instant` axis — a single live candidate still gets a Continue/Cancel
  question.
- **The drain plans each item standalone.** `/mentor:resume <root>` now points at
  `/mentor:plan <item-slug>` per queued item instead of re-running an arm→claim→approve
  cycle inline. Same work, one owner.
- **`touring` and `constitution-authoring` no longer abort while the plan gate is armed.**
  Both write only inside the gate-exempt `.mentor/` tree, so the abort was covering
  nothing. Constitution authoring still stops for an adopt-by-reference target outside
  `.mentor/`, which the gate really does block.
- **The `/mentor:tour` and `/mentor:ship` offers, and the `/mentor:defer` pointer, moved
  out of three skills.** `plan-state.sh set <slug> implemented` prints them once as a
  closing advisory, and `commands/plan.md` / `commands/track.md` name the flow. Skills
  point; entry points sequence.
- **Several skill descriptions changed** (`dispatch-agents`, `plan-split`, and the four
  `plan-domain-*` skills) to describe what the skill knows rather than who calls it. The
  trigger phrases are unchanged; the eval baseline is pending.

**Removed: the `solo` dispatch mode.** `/mentor:mode` took `agents | solo | verify-only`;
it now takes `agents | verify-only`. `solo` was the only setting that retired the
end-of-run verification round, which put it in permanent conflict with mentor's own
"verification dispatch never skips on a mentor plan" — a plan cannot grade itself, so
that is not a preference mentor offers. The dispatch axis now decides only where
**implementation** runs, and `verify-only` is the strongest honor of a standing
no-subagents instruction. The `POLICY: FOUND` question is two options, not three.
A `"dispatch": "solo"` already in a repo's `config.json` is **not** silently rewritten:
it reads as `POLICY: UNRESOLVED`, which re-opens the question once so the user re-records
a value they actually chose.

**Split children are approved one at a time.** The approval question used to offer
"Proceed approves the whole set" after a split. It now lists the children and takes a
multi-select — each selected child is set `approved` before the gate is released, and any
child left unselected is stamped as not individually reviewed, so `/mentor:track` confirms
with the user before it will build that one. No blanket yes over a sibling set.

**Review and split hand back to the gate they came from.** A review or split entered from
a live approval gate returns its result there rather than pointing at `/mentor:plan`.
Re-running that command re-arms the gate marker with a fresh mtime, and approval then
refuses the plan as older than the marker ("Newest plan predates this planning session") —
stranding a finished plan for a reason nobody connects back to the review. The
`/mentor:plan <slug>` pointer stays for the standalone case, where no gate is open.

**New: the charter, and a test that enforces it.** The README's opening now states what
mentor is and is not, and binds `/loom:learn` and every other automated contributor:
lessons land as skill prose or `references/rationale.md`, never as new hooks, scripts,
state tokens, or `plan-state.sh` subcommands. `hooks/tests/test-hook-roster.sh` pins
`hooks/hooks.json` to its six registrations and the top-level `hooks/*.sh` set to the six
hooks plus five rostered CLIs — anything new fails the build until the charter is amended
first.

**The `policy` preflight is now one printed source.** Four skills carried hand-copied
decode tables for `plan-state.sh policy`; all four now say "follow its printed guidance
verbatim", and the script's `CONTRACT: MISSING` branches carry the **action** rather than
only the fault — including the one that matters most: when `hooks/dispatch-contract.txt`
itself is absent or empty there is nothing left to paste, so stop and report a damaged
install rather than reconstructing the standing agent contract from memory. That rule used
to exist in exactly one skill; it now reaches every caller.

**A run with no plan of record still gets closed out.** The plan file is mentor's primary
source of truth, not its only mode. Since the tour/ship offers now ride on
`plan-state.sh set <slug> implemented`, the other-framework path (spec-kit, a Jira epic)
would have lost them — `dispatch-agents/references/other-framework-path.md` now names them
explicitly for that path.

**New reference files, one copy each.** `dispatch-agents/references/decomposition-smells.md`
(the five oversized-step smells, previously inline in `dispatch-agents` and re-read out of
it by `plan-review`) and `zooming/references/ui-mockup-contract.md` (the UI mockup contract,
previously `plan-domain-frontend` §4).

**Compatibility.** The `.mentor/` layout and the `.state.json` sidecar schema are
unchanged — every existing plan dir keeps listing, querying, resuming and tracking
identically. Leftovers are inert, not errors: an `"instant"` key already in a repo's
`config.json` is preserved by `set-mode.sh` and simply never read; leftover
`instant-run-*.md` files and `plans/<slug>/tour/` directories are ignored. Running
`plan-state.sh instant …` now exits with the unknown-subcommand usage error.

## Changes in v2.39.0

**`dispatch-agents` costs less to load, and the standing contract now caps what comes back.**
The skill loads into main context on every plan execution and had grown to 71.4KB (~21k
tokens) — the largest single item on the `/mentor:track` → build path. Three commits cut it
without dropping a rule.

- **Inbound agent reports are capped.** `hooks/dispatch-contract.txt` — the block the
  dispatch hook appends to every prompt — now asks for a reply under ~300 words, with file
  bodies, whole diffs and long logs written beside the plan (or to a `mktemp` file when the
  brief names none) and cited by path. **The cap yields to the brief's own cap or return
  shape**, so `plan-review`'s 600-word reviewer, `touring`'s deliberately uncapped manifest
  and every verifier's `verifier-contract.md` block still ship in full. Four new assertions
  in `test-dispatch-contract.sh` pin the clause through injection. Honest arithmetic: it
  costs ~1.1–1.8k tokens per run to ship (474 b × 9–15 dispatches) against a 2.7–7.5k
  inbound saving — net ~0.9–6.4k, narrower than the headline.
- **New `Verdict: HANDBACK`** in `dispatch-agents/references/verifier-contract.md`. The
  hand-back rule — *the topic outgrew its brief* — was previously unobeyable: `Verdict:` was
  a closed `PASS | FAIL` binary, so a hand-back had to be mis-stamped as one of them, and a
  `FAIL` spends the topic's one remediation on work nobody attempted. `HANDBACK` costs the
  round nothing and routes the topic to a fresh dispatch with the verifier's remainder as
  its inputs.
- **Four conditionally-read blocks moved out of `SKILL.md`**, each behind a short
  on-trigger pointer, and every `## ` heading kept so existing citations still resolve:
  - the five dispatch-recovery bullets → new `references/dispatch-recovery.md`, read when
    an agent idles early, echoes after being stopped, dies, goes dark, or needs a
    correction applied to a brief already in flight;
  - the non-goal gate's six steps → new `references/non-goal-gate.md`, read when a round
    has any open finding the user has not ruled on;
  - the "another framework owns the plan of record" detail → new
    `references/other-framework-path.md`, read only on a spec-kit/Jira phase, never on a
    mentor plan;
  - the worked annotation example → new `references/annotation-example.md`, read when
    authoring a plan, never when running one.

  **The guards that fire before anyone could open a reference stay inline** — the
  foreign-id `SendMessage` check, the ban on hand-debugging a stalled step early, and the
  gate's user's-call and never-re-grade-a-stamp rules. Six pointers inside `SKILL.md` that
  named the moved text positionally ("above", "below") were repointed by heading name.
- **The parent-link taxonomy is stated once.** `dispatch-agents` had restated `deferring`'s
  three-way blocking/backlog split — the rule eval id 54 exercises — so a defer verdict had
  two sources that could drift. It now points at `mentor:deferring` → **blocking vs
  backlog** and states no competing answer.
- **`Unattended continuation` was deliberately NOT moved**, though it is now the largest
  remaining block. The `instant` axis is on by default and `plan-track` enters that loop on
  nearly every build run, so deferring it would move the cost into a reference read rather
  than remove it.
- **The dead "Deliver before idling" pointers are gone.** `hooks/plan-state.sh` printed
  "paste the block from `skills/dispatch-agents/SKILL.md`" on the `CONTRACT: MISSING` path —
  a file that has held no such block since v2.34.0, and the message fires exactly when `jq`
  is missing and the user is already stuck. That advice, and the same stale instruction in
  `planning`, `plan-review`, `plan-split`, `plan-touring` and `zooming`, now names
  `hooks/dispatch-contract.txt` and treats a missing file as a damaged install rather than
  something to retype by hand.
- **Narrative moved to `references/rationale.md`** per the repo's SKILL-prose convention —
  five new headings — and every by-number cross-reference in the skill was converted to name
  form, so a renumbered step can no longer silently redirect a citation. Two `rationale.md`
  sections that had been written as verbatim copies of the `SKILL.md` bullets they explain
  were trimmed to what only that file carries: once the procedures moved into a sibling
  reference, both copies sat in the same load class with a pointer between them, so a reader
  following it re-read eighteen lines to reach three new ones.

**Net: `dispatch-agents/SKILL.md` 71,435 → 60,897 bytes (−14.8%)**, roughly 3.1k tokens off
every plan execution, with all four moved blocks still one read away when they are actually
needed. `Unattended continuation` remains the largest block in the file by design.

## Changes in v2.38.0

**The `/mentor:track` hierarchy is rendered by the script, not by prose.** `plan-track`'s
render section had grown to ~9.5KB of layout instructions that the model re-derived on every
run, on top of the full JSON array it needed to draw the view by hand.

- **New `plan-state.sh query --format tree`** — emits the finished hierarchy, ready to print
  verbatim: glyphs, tier/category columns (blank-padded, never defaulted), depth-first
  ordinals, `▸ group:` blocks, recursive fix-child nesting, live-handoff and deferred-goal
  sublines, `▷ no plan yet` topics, the `▽` legacy dir, the done-with-open-descendants warn,
  the unparented-open-fix clause with its `gate: left uncontained` exclusion, and the
  `set-parent` repair hint. Pair it with `--open-counts`; `--fields` is ignored.
- **`plan-track` Step 1 now prints that output instead of re-rendering it.** Measured on this
  repo (40 plans): tool output 19.8KB → 6.6KB, and the skill dropped 45.5KB → 34.5KB. Together
  that returns roughly 7k tokens per `/mentor:track`. The ordinals Step 2 resolves against are
  now identical between runs — two sessions over the same repo could previously disagree about
  the layout the user was picking from.
- **New `plan-track/references/rationale.md`** — the displaced narrative (why the render moved,
  why tiers pad blank rather than default, why the gate-dispositioned stub is excluded, why
  deps/group/parent stay three axes), per the repo's SKILL-prose convention.
- **32 new regression tests** in `test-plan-state.sh` pin the numbering contract and both
  roll-up clauses, so the layout cannot drift back into prose.

## Changes in v2.37.0

**Unattended continuation.** When a plan already holds a standing grant, mentor can now
run it to completion without a human in the turn — on by default, and safe because the
loop runs nothing until a script says GO:

- **New `plan-state.sh instant <slug> [<step-n>]`** — a read-only condition ladder
  emitting one bare verdict token (`GO|DEFER|ASK|HOLD|DONE|NO_STEPS|UNRESOLVED`).
  Gate ARMED/STALE and structural failures HOLD; a swept-in approval, a missing grant,
  a context ASK, a non-negated outward action (`git push`, `gh pr create`,
  `publish-plugin`, …) or an ambiguous `Done when:` ASK; a forward-referencing
  criterion DEFERs (dispatch, don't tick yet). The grant reads the STORED sidecar
  state, never the effective one, so ticking the last step cannot orphan the
  `## Verification` remediation. The ladder re-runs before every step and every tick.
- **New `dispatch-agents` → "Unattended continuation"** — the per-step loop: brief →
  dispatch → three-way `Done when:` verify (bounded command → run it; prose → ONE
  fresh verifier, **even under `dispatch: solo`**, disclosed; physical event → ask) →
  header-CRC re-check → tick → run record (`instant-run-<ts>.md`). One re-dispatch per
  failed criterion; a second failure writes `failed --note` and stops.
- **Per-plan branch + end-of-run auto-commit** (user-ruled): the run works on
  `mentor/<group>/<slug>` cut from the active branch, commits once at end of run with
  narrow staging, and leaves the branch local — push/PR/merge stay questions. A
  worktree is taken only when a second run is already active in the same tree.
- **New `context-checkpoint.sh`** (`PostToolBatch`) — the mid-run context reading
  `context-gate.sh` (`UserPromptSubmit`-only) structurally cannot take; one real
  session grew ~247k tokens between readings with nothing said. Advisory only, by
  ruling: it never exits 2; its ASK tier directs "finish the current step, record the
  outcome, hand off, end the turn".
- **Third `/mentor:mode` axis** — `instant-on` / `instant-off` (unset behaves as on);
  `--confirm` on `/mentor:resume` runs one selection attended without recording
  anything, and `resuming` now strips flags before resolving and auto-selects a unique
  candidate (announced, never silent) when instant is on.
- `verify` now reads the new shared `mentor_plan_step_scan` (same output, one
  derivation with `instant`), and the `plan-state.sh` roster above gained the `policy`
  entry that was missing since v2.34.0.

Why the loop refuses more than it runs — the 19%/72% `Done when:` measurement, why
ARMED_ELSEWHERE proceeds while STALE stops, and which trades were user-ruled rather
than derived — lives in `skills/dispatch-agents/references/rationale.md`.

## Changes in v2.36.0

**The step-line pattern stopped matching wrapped prose, and `verify` now gates on
step-body completeness.** `MENTOR_STEP_LINE_PATTERN`'s numbered-branch delimiter was a
backslash-escaped `\.` passed to `awk -v` as a *dynamic* regex — a form macOS awk
(20200816) degrades to "any character," which the block's own `[*][*]` note already
warned about for asterisks and left in place for the dot. Any wrapped continuation line
beginning `48, ` or `7) ` therefore counted as its own step: it inflated the denominator
`query` reports, stranded the real step's `Done when:` beneath a phantom successor in
`brief --step N`, and shifted which physical line `tick`'s positional write lands ✅ on —
unrecoverably, since `.mentor/` is gitignored. One plan on disk was live-affected
(`fix-plans-under-root` read `6 8` for a 7-step plan). The delimiter is now the bracket
expression `[.]`, and the comment says never to reintroduce a backslash escape there.

`plan-state.sh verify` gained a third **gating** check — every step body inside
`## Implementation steps` carries a `Done when:`, which is the direct symptom of a body
truncated by a phantom step line, and holds across every step-bearing plan in this repo
with zero exceptions. Two further checks **report only**, because each fires on
legitimate authoring roughly half the time: a ✅ on a non-step line (a real stray tick, or
prose quoting the character) and an `###` heading inside the steps section (a real
subsection that step-body extraction nonetheless glues onto the step above). `planning`'s
"Verify the write" step and this README's `plan-state.sh` row now describe the gating set
as three, and `planning` states explicitly that `Goal:`/`Inputs:`/`Done when:` stay on
every step whichever way it routes — "omit the annotations" always meant the
`[role: …]` bracket, never the step body.

## Changes in v2.35.0

**Implementation dispatch is no longer the default — it has to earn itself.**
`dispatch-agents` used to declare subagent implementation "the DEFAULT for every mentor
plan," with a narrow escape hatch. That framing was never checked against either the
published evidence or mentor's own telemetry, and both disagree with it. Anthropic's
multi-agent writeup is explicit that "most coding tasks involve fewer truly parallelizable
tasks than research," and that domains needing shared context or carrying many
inter-agent dependencies "are not a good fit for multi-agent systems today" — which
describes plan implementation exactly. Measured across 2,545 mentor subagent transcripts,
**63% of dispatches ran exactly one agent at a time**, collecting the context-isolation
benefit while paying for a parallelism benefit they never received.

The new **"Where dispatch pays"** routing test replaces the escape hatch:

- **Verification, review and research always dispatch** — no test, no escape hatch. There
  an independent context *is* the deliverable, and research is the read-heavy shape where
  the median dispatch ingests ~247k tokens and returns ~630 (a ~390× compression).
- **Implementation dispatches only when all three hold:** two or more steps can be in
  flight at once, those steps are file-disjoint and mint no shared-sequence value, and
  each brief stands alone without the conversation.
- **The context-cost override:** a single step whose `Done when:` needs a service brought
  up or a browser driven, or whose `Inputs:` pull in whole large files, dispatches alone —
  isolation bought deliberately, and it must say so in its annotation so a reviewer can
  tell it from a reflex.
- Otherwise the work stays in the main thread behind the same visible
  `Dispatch: skipped — <reason>` line, which now names *which test failed*.
  `plan-review`'s consistency pass checks both directions: an unnamed skip reason, and
  `[role:` annotations on strictly sequential same-file steps with no override stated.

Evidence, numbers and citations live in `skills/dispatch-agents/references/rationale.md`
→ **Where dispatch pays**, per this repo's rule that narrative belongs outside `SKILL.md`.

**The no-subagents question is asked once per repo, not once per plan.** A new `dispatch`
key in `.mentor/config.json` (`agents` | `solo` | `verify-only`) records the answer, and
`plan-state.sh policy` reads it *first*, printing `POLICY: SET` and telling every surface
to ask nothing. Set it directly with `/mentor:mode agents|solo|verify-only` — a second,
independent axis alongside `plan`/`plan-only`. This was measured, not guessed: **46 mentor
sessions asked the user where the work should run, under 16 different question headers**
(`Subagents`, `Dispatch grant`, `Execution`, `Verify how`, `Inventory`, …), and no answer
outlived its session. Repos under such a policy had started writing "do not re-litigate"
into their own handoff notes to compensate.

**The policy sweep sees what people actually write.** It matched one literal string,
`no subagents`, over `CLAUDE.md` + `.claude/` + `.mentor/plans`. Two fixes: **`AGENTS.md`
is now its own root** (a `CLAUDE.md` that is just `@AGENTS.md` kept every real rule in the
imported file, so the sweep read the pointer and reported a clean zero — measured in the
wild against a policy living at `AGENTS.md:119`), and the pattern is now an ERE covering
the real phrasings — "solo in-thread", "background agents/teammates", "do not use the
Agent tool", "never dispatch subagents", "no fan-out". Printed evidence is **capped at 5
hits** with a total count: one real repo produced 68, and the verdict is already on the
line above. `mentor_sweep` grew an optional `ere` argument for this; existing callers are
unchanged, because flipping them all to `-E` would silently reinterpret `+`, `?` and `{}`.

**One premise not worth inheriting.** Standing no-subagents policies often justify
themselves with a reliability claim — that dispatched agents go idle without delivering.
Across **2,495 orchestrator-side dispatches: zero never returned**, and all 16 errors were
environmental or user-initiated (interrupts, rejections, a machine sleeping mid-response,
one malformed `isolation` argument). The cost argument for staying in-thread holds; the
reliability one did not survive measurement, and the skill now tells the model not to
repeat it back to the user as established fact.

## Changes in v2.34.0

A trimming release: same gates, same guarantees, less work to get through them.

**The dispatch contract is injected, not pasted.** `hooks/dispatch-contract.sh` has
appended the standing "Deliver before idling" block to every `Task`/`Agent` prompt since
v2.30.0, but six skills still told you to load `mentor:dispatch-agents` (~16k tokens) and
paste it by hand — an instruction `dispatch-agents/SKILL.md` itself contradicted. Those
eight load points are gone; five real ones remain (the annotation grammar, execution, and
verification dispatch). A standalone `/plan-review`, `/zoom`, `/plan-tour` or `/plan-split`
no longer drags that skill into context at all.

**New `plan-state.sh policy`** — the one pre-dispatch preflight, replacing the skill load.
It answers both questions a surface must settle before its first dispatch: `POLICY:
SET|NONE|FOUND|UNRESOLVED` (has the user recorded a dispatch preference, and failing that,
is a standing no-subagents instruction on record? — `SET` added in v2.35.0) and `CONTRACT:
active|MISSING` (can the hook actually inject?). That second line is new coverage — the
hook fail-softs silently when `jq` or the contract file is missing, and with nobody
pasting by hand any more, nothing else would have said so.

**New `plan-state.sh start <slug>`** — `ensure-dir` + `init` + `claim` in one call,
echoing the plan path. The plan-write path was three separate Bash calls with two
"re-derive `$slug`, this is a separate shell" warnings attached; it is now one call whose
stdout is exactly the path.

**One per-prompt hook instead of two.** `planning-intent.sh` is retired into
`context-gate.sh` as tier 2. Both fired on every prompt, each spawning a process, sourcing
the 1467-line state lib and re-parsing the same stdin with `jq`. Behavior is unchanged —
both kill switches, both config keys, and the separate marker locations all survive, and
the merged hook has explicit tests that neither tier can swallow the other.

**Fewer questions at two gates.** `plan-review`'s Stage 1 fold gate now walks only the
edits its reviewers stamp **CRITICAL** or **HIGH** and resolves the rest in one batched
verdict — the same shape Step 7 already used, for the same measured reason (a 21-step plan
once produced twelve dense questions). Reviewers stamp a severity per edit to make that
split possible. `/mentor:ship` asks its test question and its ship-target question in one
call instead of two.

**`plan` Step 3.5 is impact-gated rather than strictly serial.** A decision still gets its
own question when it is consequential or when an earlier answer could change it; genuinely
independent decisions ride in one call, each still answered on its own screen.

**Skill prose convention.** Rules stay in `SKILL.md` with one sentence of why; the incident
narrative moves to `references/rationale.md`, read only when editing the skill. See
"Where a new rule goes" above — it binds automated contributors too, which is what keeps
the split from reversing itself.

## Changes in v2.33.0

**Deferral is manual only, and verification findings now reach you as a decision.**

`/mentor:defer` started as a `git stash`-like escape hatch *you* reach for. Across
v2.17 → v2.31 it grew into something the harness reached for on its own — twelve
machine-driven trigger points, down to `plan-state.sh` itself printing "Sweep any
follow-up WORK through /mentor:defer" on every close. The harness parked work without
asking, and the plan still read `implemented`. All twelve are gone or converted to an ask.

**The rule:** a fix needed to complete the plan's main goal gets fixed in the loop, no
question asked. Everything else is yours to decide. Two routes into `deferring` remain —
you ask for it, or you pick a Defer option at a gate, where the verdict *is* the
invocation: mentor runs the capture rather than handing you a command to retype.

**Verifiers now grade severity and size.** The return contract
(`dispatch-agents/references/verifier-contract.md`) stamps every gap line: `[GOAL]` /
`[NON-GOAL]` — does the plan's Goal, a `Done when:` bullet, or this topic's own
`Pass when:` stay unmet without the fix — and `[LARGE]` / `[SMALL]`, judged on the *fix*
rather than on the finding. Both tiebreaks point at you: unsure of severity → `[NON-GOAL]`,
unsure of size → `[LARGE]`, because a misfiled `[GOAL]` gets quietly fixed and you never
learn it existed, while a misfiled `[NON-GOAL]` costs you one keystroke. `Verdict:` is
reconciled with the stamps — **`FAIL` iff a `[GOAL]` gap exists** — so a topic whose only
gap is cosmetic can still reach PASS instead of deadlocking a plan with no legal terminal
state.

**A `Notes:` channel, which is the quiet win here.** `Gaps / Missing:` has always been
mandatory even on PASS, so verifiers who found nothing real wrote *something* — "two soft
observations, not scope-rule defects", "not a defect in the implementation, just a note".
Measured across 37 real `topic-N-verify.md` artifacts in this repo, roughly half of all
gap content was not a finding at all, and every one of those would now cost a question.
They go to `Notes:` instead: carried into the report, never gated.

**The non-goal disposition gate** (new, in `dispatch-agents`) runs once per plan, after
`[GOAL]` remediation settles: a digest, then one question per `[LARGE]` finding — those
same 37 artifacts show a round produces a median ~7 gaps but only 0–2 large ones — and one
batched question covering all the `[SMALL]` ones. Defer / fix now / leave open. A stamp the
verifier set is never re-graded by the orchestrator, which is the context that just built
the thing and wants the plan to close.

**Findings you leave open are recorded, not lost.** `implemented` now means every topic
PASS and every `[GOAL]` gap fixed; whatever you left open rides along on the same call as
`set <slug> implemented --note "open: <handle>, <handle>"`. `note` is the one sidecar field
always replaced on write, so `shipping` Step 6 and `merging` Step 5 — both of which
re-close an already-closed plan — now carry that segment forward and let everything else
clear, composing as `open: a, b | merged: PR #12 abc`. `handoff-note`'s "no open findings"
consistency check no longer flips such a plan to `failed`.

**Gate-deferred stubs stop setting off alarms.** A defer chosen at the gate is flat on
purpose — which is exactly the `category: fix` + `deferred_from` + no `parent` signature
`/mentor:track` flags as "lineage without containment" and `/mentor:resume` offers to
adopt. Those stubs now carry `note: gate: left uncontained`; `/mentor:track` renders them
with no ⚠ and no repair hint, and `/mentor:resume`'s adoption gate defaults them to **leave
flat**. Otherwise both surfaces spent every session offering to undo a decision you had
already made.

**Reversed, not relocated:** `verifier-contract.md` used to route a confirmed pre-existing
defect's fix through `/mentor:defer` from inside the verifier, and declared a finding on
the plan's own work "never a defer candidate". Both rules are gone, not moved. A verifier
reports and stamps; it does not dispose. This reverses part of the v2.25.0 note below
rather than relocating it.

`plan-state.sh`'s closing-checklist line is **replaced rather than deleted** — it still
names `/mentor:defer`, now as a pointer for you instead of an instruction to sweep through
it. `deferring`'s own description no longer headlines "a fix a verifier demands, a gap that
would leave a `Done when:` bullet unmet", which was precisely the class that must never
reach it unasked. Its scope rule, its parent-aware capture, and the active-plan branch you
reach by saying "park this, it blocks the plan" all survive unchanged.

## Changes in v2.32.1

**Every mentor command and skill aborted before it could do anything.** The
`CLAUDE_PLUGIN_ROOT` guard standardized in v2.17.0 tested the bare
`$CLAUDE_PLUGIN_ROOT`, but Claude Code substitutes only the **braced**
`${CLAUDE_PLUGIN_ROOT}` token into command/skill text at load time, and it never exports
a `CLAUDE_PLUGIN_ROOT` variable into the Bash tool's environment (hooks get the env var;
Bash tool calls do not). The guard therefore read an empty string on every invocation and
failed unconditionally — `/mentor:track`, `/mentor:plan`, `/mentor:mode` and the skills
behind them stopped at their first step, in every repo, telling the user to
`/reload-plugins` or restart when nothing was actually stale. All 16 guard sites across
3 commands and 10 skills now test `[ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]` instead, which
is correct in both directions: a loaded plugin substitutes to a real absolute path and
passes, while a stale or unresolved one leaves the token literal, expands to nothing, and
fails loudly as intended. `resuming`'s plugin-wide convention note now records why the
braced form is mandatory so the bare form does not creep back.

Also fixes a cross-block variable leak in `plan-split`'s retirement sweep: `$plans_dir`
was derived in an earlier fenced block and read in a later one, and each fenced block is
its own Bash call — the unset variable made `grep` search the cwd instead of the repo's
plans and report a false-clean sweep. It is re-derived and guarded in place.

## Changes in v2.32.0

**The standing dispatch contract is injected structurally, not by remembering to paste
it.** A new `PreToolUse:Task|Agent` hook, `dispatch-contract.sh`, appends the
solution-quality line and the "Deliver before idling" block to every Task/Agent prompt,
sourced byte-identically from the sibling `dispatch-contract.txt`. A typical plan run
makes 9–15 dispatches; delivery no longer depends on the orchestrator pasting ~2.3KB of
directives into each one. It is idempotent — a prompt already carrying the block's first
line is left alone, so a skill that still pastes by hand never double-delivers — and
fail-soft in every degraded case (no `jq`, missing/empty/unreadable contract file,
malformed stdin, an unresolvable script directory, a failed write): silent, exit 0, never
partial JSON on stdout. `plan-state.sh` also gains a `brief` subcommand.

**The solution-quality line is role-independent, with no exemption.** An earlier design
exempted read-only roles such as `Explore`, on the reasoning that the line governs how
something is built rather than how it is found. That carve-out is deliberately gone: the
hook has no `subagent_type` branch, and four assertions now lock it so a future edit
cannot quietly reintroduce one.

**Every terminal path in the hook exits 0.** Two lines ran unguarded under
`set -euo pipefail` and would abort non-zero instead of failing soft — the `HOOK_DIR`
resolution and the final write of the output JSON. Both now carry the same `|| exit 0`
guard the rest of the file already used. The `HOOK_DIR` line additionally let `cd`
consult `CDPATH`, which on a relative invocation resolved the wrong directory and
silently killed injection; it is now scrubbed with `CDPATH= cd`. The suite covers the two
reachable cases (closed stdout, hostile `CDPATH`); the `cd`-failure path is documented as
untestable rather than given an assertion that would only check the guard's presence.

## Changes in v2.30.0

**`/plan-review` Stage 2 verdicts are severity-gated.** Measured on a real 21-step
plan, the mechanical stage's decision-level findings produced twelve dense
one-at-a-time questions (~34 minutes of answering) with no map of what was coming
and no visible bulk path. Step 7 now surfaces every DECISION-REQUIRED finding as a
one-line **digest** (handle · severity · summary · recommendation) before anything
is asked, walks **only CRITICAL findings** individually — each question opening
with one plain sentence naming the decision before the evidence — and resolves the
rest in **one batched question** ("Apply all recommendations (Recommended)" /
"Leave all open" / "Walk them one by one", mixed verdicts via "Other"). The
cleanliness reviewer now tags severity inline (`[DECISION-REQUIRED][HIGH]`) so the
gate has something to gate on; a reviewer-stamped severity always stands, and only
unstamped findings default (MEDIUM, promoted only when content meets a CRITICAL
definition). The guarantees are unchanged: nothing decision-level is ever
auto-applied, toss-ups and demotions with no exact edit stay open rather than
guessed — identically on the button and the free-text path — and an empty
decision-level set skips straight to the report. Stage 1's fold gate is untouched.

## Changes in v2.27.0

**Plan steps are budgeted to one agent's context, and live end-to-end proof runs once.**
Measured across a real project's sessions, every dispatched step-executor teammate reached
400–750k tokens of context over 150–420 tool calls (worst case 746k), with zero compaction
events — a teammate's context only ever grows. Four mentor design choices multiplied into
that: unbounded step granularity, the solo-teammate rule, live e2e proof demanded from the
implementer inside its own `Done when:` (then re-proved by the plan's verifiers), and no
brake on overrun.

Four coordinated instruction changes, no hook or script changes:

- **`dispatch-agents` — new Decomposition rubric item, "Budget each step to one agent's
  context."** The operative test is a five-smell list, all checkable while authoring: spans
  more than one service/layer; touches more than ~10 files across distinct areas; its
  `Done when:` needs a live multi-service stack driven end-to-end; its `Inputs:` or implied
  reconnaissance pull several whole large files; the prompt sketch reads like a project
  brief rather than a task. An oversized step splits into **sequential steps, one dispatch
  each**, handing off by report — preserving `one plan step = one dispatch`, so
  `plan-state.sh tick` still finds a step line for every dispatch. *Collapse small dependent
  steps* bounds the opposite end, and a split that pushes the plan past ~12 steps is
  `/plan-split`'s threshold doing its job, not a reason to re-merge.
- **`Done when:` ownership split.** A dispatched step's acceptance must be provable by the
  implementer with bounded commands — build, typecheck, unit, targeted integration. Live
  multi-service end-to-end proof belongs to a `## Verification` topic, where a fresh verifier
  proves it exactly once instead of the implementer proving it in the most expensive context
  and a verifier re-proving the same ground. `planning`'s content spec cites the rule from
  both item 6 (sizing) and item 9 (e2e ownership).
- **Stop-and-hand-back.** The canonical "Deliver before idling" block gains a clause: when
  work has clearly outgrown its brief, finish the current phase cleanly and hand back —
  what is DONE, what remains as a concrete list, and any contracts discovered. A partial
  result with a sharp remainder brief beats a complete one delivered from a bloated context.
  Orchestrator side, as an addendum to the existing "On a failed `Done when:`" bullet: a
  hand-back is **not** a failure and does **not** spend the one remediation re-dispatch —
  but the chain is bounded at one, because a second hand-back on the same step means the
  step was mis-scoped, not merely unlucky.
- **`plan-review` cleanliness reviewer** flags oversized-step smells and e2e-in-`Done when:`
  as `[DECISION-REQUIRED]` — splitting a step reshapes the plan, so it never auto-folds.

**The standing contract block now has exactly one authored home.** `plan-split`'s child-author
prompt template previously pasted the "Deliver before idling" block verbatim, and that copy had
already drifted once. It now **cites** the canonical block in `dispatch-agents` (the pattern
`references/verifier-contract.md` already used), naming the section, that it must be pasted
verbatim, where it goes, and how to load it — superseding the v2.21.0 note below that recorded
the copy as verbatim. A repo-wide search for the block's lines now hits exactly one file.

## Changes in v2.25.0

**Deferred stubs carry triage signals, and the plugin now enforces one rule everywhere it
routes work toward `/mentor:defer`: a deferred stub captures work to build, never a check
to run.** Before this, every stub rendered as a bare `○ <slug> draft (deferred)` line —
no purpose, no priority, no relation to the plan it came out of — and nothing stopped a
plan from stashing its own unresolved verification as a "verify X later" stub.

`.state.json` gains two fields, mirroring the v2.24.0 `priority` pattern exactly:
`category` (closed set `feature`/`fix`/`refactor`/`docs`/`tooling`, deliberately no
`test`/`verify` entry) and `deferred_from` (an unvalidated plan slug, like `deps`'
targets). `init` takes `--category`/`--from`; `set-category` joins `set-priority` as the
follow-up subcommand; `claim` clears `origin` as before but now also **keeps**
`category`/`priority`/`deferred_from`, so a claimed stub's triage history stays readable.

`/mentor:defer` (via the `deferring` skill) judges **priority**, **category**, and
**source plan** from the conversation's own evidence at capture time — the moment that
context still exists — leaving any of the three unset rather than inventing a default,
and reports what it judged inline:
`deferred → <slug> [<tier> · <cat>] (.mentor/plans/<slug>/) — from: <plan> — deps: <a>`.
`query` returns `category`, `deferred_from`, and a computed `goal` key (a
one-line summary of the stub's own `## Goal`, `null` on non-deferred entries — see "The
repo-wide hierarchy" above); `/mentor:track` renders the tier and category as aligned tag
columns, a `from:` clause (`from: <slug> (missing)` when the source plan is gone), and a
`└ goal:` subline, extending the never-sort/never-filter rule to category too.

**The scope rule now runs through every funnel that routes work toward `/mentor:defer`** —
`dispatch-agents`' closing sweep and verification failure loop, `planning`'s oversize-plan
defer offers, `merging` and `resuming`'s flaky-test capture points, and `handoff-note`'s
close-out checklist. An unresolvable verification topic always ends `set <slug> failed
--note`, never a stub; a check that **ran** and confirmed a defect still lets its **fix**
defer, since a pre-existing bug found incidentally (a flaky test on the base branch, CI
broken before this work began) is ordinary work-to-build, not the check itself.

No auto-migration: this repo's pre-2.25.0 stubs keep `category`/`deferred_from` as `null`
and render exactly as before; backfill with `set-priority`/`set-category` while surveying
is a manual, one-time choice, not a requirement.

## Changes in v2.24.0

**Plans carry an impact tier.** `.state.json` gains `priority` — `critical`, `high`,
`medium`, `low`, `noise`, or `null` — so `/mentor:track`'s hierarchy can say which plans
matter and which are noise. Until now there was nowhere to put that: the sidecar was a
fixed key set that silently dropped anything hand-added on the next write, and `--note`
is replaced on every `set` and never surfaced by `query`.

Written two ways: `init <slug> --priority <p>` at mint time, and `set-priority <slug>
<p>` for an existing plan (`""` clears it back to unset). `set-priority` is its own
subcommand for the same reason `set-deps` and `claim` are — `set <slug> <state>` takes
the state as a required positional, so a tier-only edit through it would have to restate
a state the caller never meant to touch. The tier then rides through every later write
untouched, under the same omitted-preserves contract that already carries `deps`,
`origin`, and ownership.

The vocabulary is a **closed set**, validated on write — deliberately unlike `deps`'
arbitrary slugs. The field exists so a renderer can bucket plans by tier, and an
unvalidated typo would silently become a sixth bucket. An invalid value is a usage error
(exit 1, nothing written), never a fail-soft skip: a tiering pass over twenty plans must
not report success having quietly dropped one.

`query` carries `priority` on every entry, `null` where none is set —
including the `no_plan_topic` and `legacy_handoffs` kinds, so a consumer never branches
on kind to read it. An unset tier renders as **absent**, never as a default: "nobody has
judged this plan's impact" is a different and more honest answer than `medium`.
`/mentor:track` renders it as an aligned tag beside each entry and never sorts or filters
on it — a view of what's remaining that quietly hid the low tiers would be a lie in the
one place a user goes to trust it. Old sidecars need no migration, and `list`'s output is
byte-identical in both its shapes.

## Changes in v2.23.0

**The plan gate is now per-worktree — parallel development on one repo no longer
deadlocks.** Before this, the gate marker `<repo>/.mentor/plans/.planning` was one
file per repo: `mentor_repo_root` resolves via `git rev-parse --git-common-dir`, so
every linked worktree shared the same marker, and a session planning in one worktree
blocked every Write/Edit in every other worktree, including sessions that never armed
anything. `begin-plan.sh` also refused to arm a second marker over a live one, so a
second worktree couldn't even start its own plan — and `approve-plan.sh` swept **every**
`plan.md` newer than the marker, including a sibling worktree's still-drafting one.

Each git worktree now arms and is denied against its own marker,
`.mentor/plans/.planning.<wt-id>` (`wt-id` derived from the worktree name plus a
checksum of its real toplevel path — `lib/state.sh`'s new `mentor_worktree_id`). Plans
themselves stay **shared** in the one `.mentor/plans/` tree — this is not per-worktree
plan storage, only per-worktree gating. A pre-upgrade bare `.planning` (no suffix) is
reserved as the **legacy repo-global marker**: it still fail-closed blocks every
worktree until released or stale, and only the session that armed it (`session=` match)
can approve through it repo-wide — everyone else is refused, marker untouched.
Same-worktree serialization is unchanged and intentional: two sessions in one worktree
still contend for the one marker.

**Ownership closes the sweep hole.** A plan's sidecar `.state.json` gains `owner` +
`owner_session` (the worktree that minted or last re-owned it), stamped at three
points — `ensure-dir` (the instant a plan topic dir is created, closing the normal
unowned-draft window), `init` (last-init-wins re-owning, also how `/mentor:plan <slug>`
re-owns a plan resumed in a different worktree), and `claim` (deferred-stub
resurrection). `approve-plan.sh` now promotes only plans owned by the approving
worktree — and, whenever any sibling worktree's marker is live, excludes UNOWNED
candidates too, reporting them by name rather than silently promoting or silently
skipping them; with no sibling live, unowned plans stay promotable (solo back-compat).
Every failure message names the ownership situation ("owned by another worktree —
re-own with `/mentor:plan <slug>`") instead of a misleading "No Markdown plan found."

**`plan-state.sh gate` gains a fourth token, `ARMED_ELSEWHERE`.** The full contract is
now `ARMED` (this worktree's own marker or the legacy marker is live — a write here
would be denied) / `STALE` (exists but past the staleness window, not yet
pruned/healed) / `ARMED_ELSEWHERE` (no marker here, but a sibling worktree's is live —
an independent gate that does not block this worktree) / `RELEASED`. `--verbose` gains
a normative per-token field contract: `ARMED` reports `marker=` / `owner_session=` /
`owner_cwd=` / `owner_worktree=` / `age_min=` / `affected_plans=`; `ARMED_ELSEWHERE`
reports one `elsewhere=<wt-id> session=<sid> worktree=<path> age_min=<n>` line per live
sibling and nothing else; `STALE`/`RELEASED` stay bare tokens. Bare `gate` is
byte-unchanged (still exactly one token on line 1), so every existing `= "ARMED"`
check keeps working — and now correctly reads `ARMED_ELSEWHERE` as "not armed for me."
`current` is now ownership-scoped to plans owned by this worktree (or unowned), with a
new `--any` for a deliberate repo-wide read; `list` gains an opt-in `--owners` column;
`query` carries an additive `owner` field.

**Every asking/reading skill now understands the difference between "armed here,"
"armed elsewhere," and "a pre-upgrade repo-wide lock."** `planning`'s Step 0 gate
check is rewritten for strict `ARMED` equality (a deliberate flip: `STALE` now reads
as NOT armed) with a guard so it never false-alarms outside a git repo, and its
slug-reuse scan uses `list --owners` to never mint a slug another worktree already
owns. `resuming` teaches that resuming a paused plan in a different worktree from the
one that armed it requires re-owning (`/mentor:plan <slug>` → `init`) before any
approval. `plan-track` hard-refuses approving a `draft` plan owned by a sibling
worktree (worktree B could otherwise promote and dispatch a draft worktree A is
mid-writing) while still allowing dispatch of already-`approved` work under
`ARMED_ELSEWHERE`, and renders ` [worktree: <id>]` on any listed entry owned by another
worktree. `constitution-authoring` treats `ARMED_ELSEWHERE` as NOT planning-active (so
constitution work doesn't re-deadlock repo-wide) while still honoring a live legacy
marker. `touring`/`plan-touring`/`zooming` exclude sibling-owned plans from subject
resolution so "the newest plan" can't silently resolve to a worktree you don't own.
`plan-review` notes its primary-subject resolution is automatically safe via the
now-scoped `current`, while its related-artifact enumeration deliberately stays
repo-wide (those paths are read-only labels, never write targets). `plan-split`
now mints every child's plan dir via the main thread's `ensure-dir` **before**
dispatching the authoring agents — stamping ownership at creation — and registers
(`init --group/--order`) each child **as it verifies**, not batched after all N;
otherwise every child would sit unowned and newer than every live marker for the
whole verification window (sweepable by a sibling's approve) and permanently unowned
if the split aborted partway.

**Known, documented, and deliberately not closed:** a pre-existing sidecar can be
orphaned by `git worktree move`/removal (recovery: re-arm + re-`init`); an older cached
plugin copy rebuilding `.state.json` from its pre-v2.23.0 key whitelist can strip
`owner` (degrades to the unowned handling, never corrupts); two worktrees can now draft
the same slug concurrently, guarded only by a WARN from `begin-plan.sh` and
`init`/`ensure-dir`; and `nosession` marker attribution (plus the pre-existing
`.context-bypass-nosession` cross-worktree leak) is unchanged. All are detailed under
"Known limitations" above.

## Changes in v2.22.0

**A plan's `## Verification` is no longer graded by the thread that wrote the work.**
Until now that section was free-form prose ("how to test end-to-end") and nothing in the
flow owned it: after the last implementation step, the main thread — the same context that
just orchestrated the build — skimmed its own prose. That is the weakest possible reviewer.
It knows what it *meant* to do, so it confirms rather than checks, and nothing ever forces
the question "what is missing?" to be asked at all.

Verification now runs the way `plan-review` already ran: `planning` authors the section as
2–6 single-focus topics (`Topic N — / Focus: / Checks: / Pass when:`, with an optional
`[model: · effort:]` annotation making a model upgrade a reviewable authoring decision), and
`dispatch-agents` executes it by dispatching **one fresh verifier agent per topic, all in a
single message**. Fresh is exact: never an implementation agent from this plan, never a
verifier reused across topics, never the agent that wrote a fix being re-verified.
Verifiers verify and never edit. Each returns `Verdict: PASS | FAIL` plus a **mandatory**
`Gaps / Missing:` section — concrete items or the literal `none found` — because the
explicit line is what forces the question to be asked; a return without it is not a verdict
yet. `plan-review` now flags a plan whose Verification section is missing, empty, or
malformed, so the defect is caught before approval rather than at execution.

**There is no escape hatch.** A plan that opened `Dispatch: skipped` still dispatches
verification — implementation may be main-thread, verification never is. The one sizing
allowance is lite verify: at ≤2 topics a single fresh verifier may carry both, reporting
per topic. A gap — or any non-`none found` gaps line, even on a PASS — surfaces to the user
as **one question for the round**: remediate now, or hand off to a fresh session (offered
before more context is spent, since verification lands when a session is at its largest).
Remediation is one dispatch plus a *fresh* re-verify, sequential when several topics fail;
a second failure escalates and records `failed`.

**A recorded `failed` can no longer be masked by step ticks.** Because verification runs
after every step is ticked, an escalated plan derived `implemented` from its ticks and
outranked the `failed` its orchestrator had just written — reporting success for a plan
that failed. `mentor_plan_state_rank` now ranks `failed` above `implemented`: a derivation
never overrules an explicit failure record, and only an orchestrator that watched something
break writes one. The hand-off branch records state too, so stopping mid-verification does
not read as done. `/mentor:track`'s `failed` recovery splits on the ticks accordingly —
unticked means it broke mid-implementation (retry from the first unticked step); all ticked
means it broke at verification (re-enter the round, stay `failed`).

## Changes in v2.21.0

**Every question stands on its own — now plugin-wide, not just in review.** v2.20.0 fixed
`/plan-review`'s questions; the other eleven skills that call `AskUserQuestion` still had no
such rule, so an interview could ask "G5 logs" or relay "It independently confirmed G14, G5
and G6 … D23 is cheaper" and leave the user to go find what those meant. One canonical
contract now travels with all thirteen asking surfaces — `grilling`, `plan`, `track`,
`plan-split`, `resume`, `zoom`, `tour`, `plan-tour`, `ship`, `merge`, `constitution`,
`dispatch-agents`, and `plan-review` (marked as its fullest statement): the user answers from
the question screen alone, never sent to a file, a plan section, a coined id or code, or an
earlier turn to learn what the question means. `grilling` carries the strongest form, since
it is what mints the ids — say "the cross-tenant Secrets read", not "G14"; a definition given
twenty turns ago is not one the user still has. `resume`'s note picker must say what a note is
*about* rather than restate its slug, and `track`'s plan options describe the work and its
state rather than a hierarchy position that scrolled away. `dispatch-agents` gains the relay
case: an agent's report is written for the orchestrator, so its finding codes, table rows, and
bare `Location(s)` cells get named, never pasted at the user.

**Ad hoc fan-outs are contract-bound.** A handoff note reading "no single mentor command owns
this — dispatch parallel `Explore` agents" led a session to issue nine raw `Agent()` calls with
no "Deliver before idling" block; seven to eight idled without delivering and the work was
redone by hand — the second session in a row to hit it. Five changes close the route: `resume`
now triggers on the keystroke (about to issue an `Agent()` call → load `mentor:dispatch-agents`
first, however the note phrased it) and reconciles direct dispatch against `/mentor:track` (a
research fan-out has no plan steps to tick; an implementing one still routes through track);
`resume`'s fallback command sweep matches bare `mentor:<skill>` tokens, not just
`/mentor:<command>`, so a note naming a skill is no longer dropped; `dispatch-agents` now
explicitly claims non-implementation fan-outs (research sweeps, gap audits) so the route stops
dead-ending at "this is for plan implementation", and its async-surface roster is refreshed
(`ship`, `merge`, `plan-tour`, `plan-split`, `resume` were dispatching or citing but unlisted);
`plan-split`'s child prompt template now carries the standing contract block verbatim — it had
the identical hole, with its missing-child re-dispatch loop absorbing the fallout; and
`handoff-note` writes an executable dispatch instruction instead of the sentence that caused
the failure.

## Changes in v2.20.0

**Review questions now stand on their own.** `/plan-review`'s fold gate and verdict walk
used to lead every question with a letter-number code (`P2`, `C3`) as the header and prefix,
and could point at plan locations by bare label ("Section B", "Step 3") — forcing the user to
scroll back or open the plan just to understand what was being asked. Both gates now name each
edit/finding by a 2–4 word plain-language **handle** ("rollback step", "edge-case tests") that
doubles as the header chip, and every question must be **self-contained**: plan locations are
described by what they do (quoting the plan's current sentence when the edit rewords text),
never by section label; earlier findings are restated in place, never cited by code or
position; a consistency finding's bare `Location(s)` cell is translated before it reaches the
user. Bulk options ("Fold in the rest"), "Other" free-text mapping, re-entry dedup, and the
closing report all follow the handles — the reviewer agents' internal output tables keep their
IDs, since those are never shown as questions.

## Changes in v2.19.0

**A plan can now be walked before it is approved.** mentor had two visual surfaces —
`/mentor:zoom` (static topic × perspective review pages) and `/mentor:tour` (a *published*
post-approval acceptance page where reviewers mark pass/not-pass). Neither told the story of
**how a plan will execute**, which is exactly what a reviewer needs *before* approving it.

`/mentor:plan-tour [plan slug] [area] [perspective]` builds a paged, local-only HTML
walkthrough: an opening context page, one page per implementation step, then a closing page of
done criteria and risks. One persistent inline-SVG diagram evolves from current to target state
as pages advance — class-toggling only, so paging back reverses the story — beside narrative
written for the perspective you name (free-form: "system architect", "on-call engineer",
whatever lens matters). Notes can be left per page and copied out as a self-identifying Markdown
report to paste back into the planning conversation.

Artifacts land in `.mentor/plans/<slug>/tour/<area>-<perspective>.html` and auto-open once, the
same way zooms do. **This is not acceptance touring:** `/mentor:tour` publishes an Artifact and
captures pass/not-pass verdicts on *delivered* work; plan tours are local, capture free text, and
preview *future* work. The two contracts stay mutually exclusive, and `.mentor/tours/` remains
deliberately excluded from auto-open.

## Changes in v2.18.0

**Every skill is now reachable.** Nine skills shared a name with their command
(`constitution defer handoff merge plan resume ship tour zoom`), which made
`Skill({"skill": "mentor:<n>"})` resolve to the *command* file — the SKILL.md body never
loaded. Observed live: `resume`'s secret-scan and gate/PR verification, and `handoff`'s
mandatory `CHECK:` self-verification, all skipped while the run reported success. The
same collision shadowed those nine skills' `description:` out of the model-visible skill
listing, so their trigger phrases were dead text and none could be reached
conversationally.

Each skill is renamed away from its command; **`/mentor:*` command names are unchanged**:

| Command | Skill (was) | Skill (now) |
|---|---|---|
| `/mentor:plan` | `plan` | `planning` |
| `/mentor:resume` | `resume` | `resuming` |
| `/mentor:handoff` | `handoff` | `handoff-note` |
| `/mentor:ship` | `ship` | `shipping` |
| `/mentor:merge` | `merge` | `merging` |
| `/mentor:tour` | `tour` | `touring` |
| `/mentor:plan-tour` | — *(new in v2.19.0)* | `plan-touring` |
| `/mentor:zoom` | `zoom` | `zooming` |
| `/mentor:defer` | `defer` | `deferring` |
| `/mentor:constitution` | `constitution` | `constitution-authoring` |

`grill`/`grilling` and `track`/`plan-track` were already split — they are the control
that proved the fix (they deliver their skill body on the first call).

**The ~110 lines of fallback prose are gone.** Each colliding command carried a block
telling the model to read the SKILL.md directly if the call returned the command's own
text. It was ignored in practice, and post-rename its premise is false, so it is deleted
rather than reworded. Enforcement replaces it:
`hooks/tests/test-skill-command-collision.sh` fails on any collision, any skill whose
frontmatter `name:` no longer matches its directory, and any `Skill()` call site pointing
at a nonexistent skill. See "Commands and skills never share a name" above.

**`planning`'s description is deliberately non-triggering.** Now that it is visible, it
states outright that a conversational planning ask must go through `/mentor:plan` (which
arms the edit gate first) — Step 0's `GATE: NOT ARMED` stop remains the fail-safe. The
trigger evals stage all twelve skills under their new names; `expected` ground truth was
re-pointed, and `merging`/`shipping` are now actually staged (two expectations were
previously unsatisfiable, so those cases could never pass).

**Smaller things:** `handoff` pasted `plan-state.sh list` in its "Current state" section
— `list` only tables topics that already have a `plan.md`, so work done outside a plan
printed "No plans …" and got reported as invisible to `/mentor:track`. It now pastes
`query`, which is what `/mentor:track` itself reads, and offers `/mentor:defer` to
register a stub. `grilling` gained a concrete dispatch threshold (a second file, or any
read past ~100 lines, hands off to an `Explore` subagent) and a gated "the grill settled
it and the work is trivial → implement directly" close, valid only when no `.planning`
marker is armed.

## Changes in v2.17.0

**Work discovered mid-process now has somewhere to go.** New `/mentor:defer`
captures one or many future-work items — mid-planning or mid-implementation —
as draft plan stubs, then returns to the interrupted flow. A stub is not a new
kind of thing on disk: it is an ordinary plan dir at the normal location, born
`draft` with `origin: "deferred"` in its sidecar. There is no stash area, no
stash label, and no second capture path — which is why `list`, the edit gate,
and the single writer already cover it with no new machinery. Stubs carry no
`Relations` section: dependencies live only in the sidecar, so the fact keeps
exactly one owner.

**Deferred stubs survive an approval sweep.** `approve-plan.sh`'s promotion loop
now skips candidates whose sidecar reads `origin: "deferred"`, so a stub jotted
down while the gate was armed stays `draft` instead of being swept into
`approved` alongside the plan you were actually writing. `plan-state.sh claim
<slug>` clears the shield when the stub enters real planning — and
`/mentor:track` will not approve an unclaimed stub through its draft escape
hatch, so the defer→claim path cannot be bypassed.

**`/mentor:track` answers "what's remaining?" for the whole repo.** Discovery
moved from `list` to `plan-state.sh query` (introduced as `overview --json`, renamed and made filterable in v2.33.0), and the view is
now a hierarchy rather than a flat table: every plan with its state and
ticked/total step counts, `deferred` tags, cross-plan dependency edges, and each
plan's live handoffs as sub-lines. It also surfaces two things nothing showed
before — topic dirs holding handoffs but no plan yet, and the legacy flat
`.mentor/handoffs/` dir. Dependencies are advisory: picking a plan whose deps
are unbuilt warns and recommends an order, never blocks.

**The sidecar records relations.** `.state.json` gains `deps` (an array of plan
slugs) and `origin` (`"deferred"` or null), written via `init --deps/--deferred`,
`set-deps`, and `claim`. `set-deps` refuses writes that would close a dependency
cycle, including multi-node ones. Old four-field sidecars need no migration —
readers default the new fields — and `list`/`current` output is byte-identical
to v2.16.0, so anything parsing them keeps working. The repo-wide view is
computed on every call and never cached, so it cannot drift from the files it
describes.

## Changes in v2.16.0

**Review questions now lead with the recommendation.** `/plan-review`'s fold gate
marked `Fold in` as `(Recommended)` only on the reviewer's single highest-impact
edit, and its verdict walk deliberately presented DECISION-REQUIRED alternatives
neutrally. Both now lead with the recommended option: every fold question carries
`(Recommended)` with the reviewer's one-line why in the description, and the verdict
walk orders the reviewer-recommended resolution first. Reviewers name that resolution
themselves — the Step 6 tagging contract now requires it — and on a genuine
either-side-could-be-intended toss-up they say so and the options stay unled. The
guards are unchanged: bulk `Fold in the rest` / `Skip the rest` options are still
never `(Recommended)`, and the recommendation shapes only how options are
*presented*, never whether one is applied — nothing DECISION-REQUIRED is folded
until you verdict it.

**Agents are asked to build the clean thing, not the quick thing.** Four skills —
`plan-review`, `plan`, `grilling`, and `dispatch-agents` — now carry one canonical
line: recommend the most practical and clean solution, never trading maintainability
or reliability for implementation speed. It governs the edits reviewers propose,
planning's recommended option and `## Approach` design, grilling's recommended
answers, and every implementation brief a dispatch writes (read-only roles like
`Explore` were exempt — the line governs how something is built, not how it's found —
superseded in v2.31.0, which injects the line on every dispatch regardless of role).
It never widens a reviewer's lane: naming a recommendation is a choice among that
reviewer's own proposed fixes, not license to critique outside its lens.

## Changes in v2.14.0

**Approval now promotes plan state on every path.** `approve-plan.sh` previously
left state at `draft` when the plan was approved via `--handoff` / `--deliver`,
so the gate released while `/mentor:plan-track` still reported the plan as
unapproved and refused to build it. All three approval paths now promote.

**A new `/mentor:merge`** picks up where `/mentor:ship` deliberately stops: one
bounded `gh pr checks --watch`, at most one rerun of a plausible flake, and a
merge only on your explicit choice. The same job failing the same way twice is
treated as a regression, reported, and left open — fixing it is a new session.

**One repo-root derivation, not nine.** `plan-state.sh` gained a `dir [--plans]`
subcommand and the skills that hand-rolled `git-common-dir` snippets now call it,
which also fixes a worktree bug in plan's constitution lookup (it used
`--show-toplevel` and missed linked worktrees).

**Smaller things:** `/mentor:resume` surfaces the non-conforming-filename skips it
used to swallow, and can rename one on request; `/mentor:ship` and `/mentor:resume`
check branch ownership before you build on someone else's PR; `/mentor:ship` closes
the plan's state on a successful ship and honors a `test_command` in
`.mentor/config.json` for monorepos where test auto-detection misfires.

## Changes in v2.13.0

`/plan-review` review results now reach you **one question at a time**. The
Stage 1 fold gate drops its per-dimension multi-select: every recommended
edit gets its own single-select question (Fold in / Skip / Skip the rest),
written the way a human reviewer would present the finding — the observation,
why it matters, and what changes, with the **key words bolded** — and, when
the reviewer supplied concrete text, a before → after preview of the exact
edit. Stage 2's DECISION-REQUIRED findings get the same treatment: instead of
ending in a surfaced-only report, each finding is asked one verdict question
(the reviewer's stated alternatives / Leave open / Skip the rest), and
accepted resolutions are folded in one final pass — still never auto-applied.
Stage-2-only's "Surface only" stays fully read-only: no writes, no verdict
walk.

## Changes in v2.12.0

The HTML zoom is now its own skill — **`/mentor:zoom`** — usable on **any**
subject, with no plan file and no planning session required.

- **Extracted from `plan` Step 5.** The ~90-line zoom contract (topic ×
  perspective selection gate, one dispatched agent per combo, self-contained
  local HTML, never published) moved to `skills/zoom/SKILL.md`; `plan` Step 5 is
  now a delegation stub, so the planning flow is unchanged from the user's side.
  New in the standalone skill: a **source pack** step — a plan/doc path, real
  file paths (optionally distilled by one `Explore` agent into a `_brief.md`),
  or a conversation brief — so combo agents always render from real sources.
- **Zooms moved to a flat tree:** `.mentor/zooms/<subject-slug>/…` replaces
  `.mentor/plans/<slug>/zoom/…`. For a plan subject the slug IS the plan slug,
  which is how `plan-review` and `handoff` still find a plan's zooms. The next
  `/mentor:plan` run relocates existing zoom files automatically (idempotent,
  `mv -n`); `plan-open.sh` still auto-opens files left at the legacy path.
- **Boundaries restated:** zoom = local, read-only, never published;
  `/mentor:tour` = published, editable, pass/not-pass acceptance;
  `/plan-review` = a quality verdict on the plan `.md`. The trigger evals grew
  matching near-miss queries, and `tour` joined the staged eval set.

## Changes in v2.11.1

Closes a hole where planning could run with the **edit gate open**.

- **`mentor:plan` now checks the gate before planning.** The marker-driven gate is
  armed by `begin-plan.sh`, which only the `/mentor:plan` command runs. Loaded any
  other way — a conversational "help me plan this" — the skill used to plan anyway,
  with `plan-gate.sh` finding no marker and allowing every repo edit for the rest of
  the session, while the approval step still displayed its "no edits until approved"
  banner. Step 0 now detects the unarmed gate and stops, pointing at the command. It
  deliberately does not arm the marker itself: on a large session `begin-plan.sh`
  answers `CONTEXT: ASK` and exits *without* arming, and resolving that with the user
  belongs to the command layer.
  - The check resolves the repo via `--git-common-dir`, matching `mentor_repo_root`,
    so linked worktrees — which share the main repo's `.mentor/` — are read correctly.
  - Step 0 also no longer reports a missing `MODE:` line as "not in a git repo". That
    was one of two causes; the other is this bug, and it needed the opposite response.
- **Trigger evals** (new, `evals/`) — a re-runnable check that a user's phrasing
  reaches the intended skill and not one of its seven siblings. mentor had eight hook
  test suites and nothing guarding the descriptions. 36/40 at this version; see
  `evals/README.md`, including why the fixture must be seeded before the numbers mean
  anything.

## Changes in v2.11.0

Split an oversized plan into isolated sibling plans, backed by **plan state**. The two
changes are one feature: splitting a plan into five is only useful if mentor can then
tell you which of the five are built.

- **`/plan-split`** (new skill) — slices the current plan into N ordinary sibling
  plans, one dispatched agent per child, each opening with an **isolation header**
  naming what it owns and which sibling owns everything it does not. Offered at the
  approval gate when a plan is oversized. Verifies every child before retiring the
  parent — a failed authoring agent can never strand you with no children — and
  returns you to the approval question.
- **Plan state** (new) — a `.state.json` sidecar per plan dir:
  `draft → approved → in_progress → implemented | failed`, plus `superseded`. Reads
  take the more advanced of the sidecar and the state derived from the plan's `✅`
  step ticks, so a forgotten write is a no-op and older plans need no migration. Group
  and order likewise fall back to parsing the isolation header, so a plan dir survives
  with nothing in it but `plan.md`. A plan with no sidecar reads `unknown`, never
  "never approved".
- **`/mentor:track`** (new command) — lists every plan with its state and builds the
  one you pick, re-entering an interrupted run at the first unticked step. Refuses
  `draft` plans (the gate never released them) and runs the shared context check
  before dispatching, since `context-gate.sh` passes every slash command.
- **`hooks/plan-state.sh`** (new) — `init`/`set`/`list`/`current`/`context`; the only
  writer of the sidecar. Its group-aware `current` replaces three hand-rolled
  `ls -t plans/*/plan.md | head -1` snippets in `plan-review`, `grilling` and
  `lib/state.sh`, which after a split each resolved to whichever child agent finished
  writing last.
- **`approve-plan.sh` promotes state on every approval path** (since v2.14.0 — it was
  no-arg-only before, which left `--handoff`/`--deliver` plans at `draft` and made
  `/mentor:track` falsely refuse them next session). The candidate
  set is snapshotted **before** the marker is deleted: `find -newer <marker>` is true
  for everything once the marker is gone, so promoting afterwards would have stamped
  every plan dir in the repo, including months-old ones, and flipped a just-superseded
  parent back to `approved`.
- **The v2.8.0 ask-first context check is now one shared helper**
  (`mentor_context_verdict`, returning `OK`/`WARN`/`ASK`/`HANDOFF`). `begin-plan.sh`
  routes through it instead of measuring inline, and `/mentor:track` applies the same
  policy — including the `.context-bypass-<session_id>` marker, so a user who chose
  "Proceed anyway" is never then refused by a different entry point.
- **One approval-option precedence table** in `plan` `{#approve}`, now covering
  oversized × `WARN`/`HANDOFF`. `commands/plan.md` points at that table instead of
  keeping a second copy that had already drifted.
- **Lane fixes:** `resume` and `handoff` used to claim the "pick the next plan to
  build" lane; both now point at `/mentor:track`. `dispatch-agents` gained a "When NOT
  to use" so invoking it directly cannot skip the context check.

## Changes in v2.9.0

`/plan-review` is restructured around **who decides each fix**. Stage 1
dispatches the two judgment reviewers (practicality, comprehensiveness) and
ends at a **fold gate**: recommended edits get stable IDs (`P1…`, `C1…`) and a
multi-select question lets you pick exactly which to fold into the plan —
declined IDs are not re-offered when the review re-runs in the same session.
Stage 2 then runs the two mechanical reviewers (cleanliness moved here,
joining the spec-kit-`analyze`-style consistency check) against the **updated**
plan; their findings arrive tagged `MECHANICAL` or `DECISION-REQUIRED`, safe
MECHANICAL fixes **auto-fold** (guarded by a demote-on-doubt rule and a
cross-reviewer conflict rule), and decision-level findings are surfaced, never
auto-applied. "Consistency only" becomes **Stage-2-only mode** — auto-fold
included, with a write confirm on direct consistency asks — and the
approval-gate option is renamed **Review the plan (staged)**.

## Changes in v2.8.0

The context gate **no longer blocks** — the exit-2 tier that erased prompts is
gone. The top tier (default raised **270k → 350k**) is now **ask-first**: the
agent must ask via `AskUserQuestion` — **Hand off to next agent (Recommended)**
writes the handoff doc and stops, while **Proceed anyway** runs the new
`bypass-context.sh` (a session-scoped `.context-bypass-<session_id>` marker) and
fulfills the original prompt in the same turn; warnings continue and a fresh
session re-arms the gate. A handoff note written in the last 30 minutes
suppresses re-asking, and synthetic subagent reports get an advisory instead of
a question so autonomous flows never stall. `begin-plan.sh` asks the same way
instead of refusing to arm — after a bypass it arms with `CONTEXT: HANDOFF`
(lean planning, handoff-leading approval marked "(Recommended)"). Warn-high
(90% of the ask threshold) steers toward a natural handoff boundary. Knob names
are unchanged (`context_block_tokens` is now the ask threshold).

## Changes in v2.7.0

The plan flow now **resolves open questions & decisions with the user before
the plan is written** (`plan` Step 3.5). Open questions from research, domain
directives, and the planner's own design forks are triaged — codebase-answerable
ones are explored (never asked), immaterial ones flagged — and every genuine
user decision is asked via `AskUserQuestion`, **one question at a time**, each
with an evidence brief, a recommended option listed first, trade-off-carrying
option descriptions, and side-by-side previews for competing shapes. Grilling
documents its boundary with the new step (pre-research ambiguity vs
post-research decisions). Also two AskUserQuestion contract fixes: tour's
header chip exceeded the 12-char cap, and ship's recommended-option markers
drifted from the plugin-wide recommended-first "(Recommended)" convention.

## Changes in v2.5.0

`/mentor:handoff` now **ends its report with copy-paste resume prompts** — the last
thing on screen is a fenced `/mentor:resume <slug>` block (the slug uniquely matches
the note, so pasting that one line into a fresh session resumes instantly, no picker),
plus a plain-prompt alternative with the absolute note path for a next agent without
the mentor plugin. Prompts are always literal — real slug, real path, no placeholders.

## Changes in v2.3.0

Subagents-driven development (SDD): approved plans now execute **subagents-first**
by default — the main thread orchestrates and verifies, dispatched agents
implement. *(That split has since narrowed: end-to-end plan verification is
dispatched too, one fresh verifier agent per Verification topic — see the
`dispatch-agents` row under "Commands". Only per-step `Done when:` verification
is still the main thread's.)* Each agent gets one narrow, focused step (quality
through focus) and the main context stays lean (no implementation files loaded).
This extends the existing inline per-step `[role: … · model: … · effort: …]`
grammar — it is NOT
a revival of the v1.0.0-removed `dispatch-agents:` footer-line mechanism, and
nothing is hook-enforced:

- **Dispatch-annotated by default:** `plan` Step 4 now invokes
  `mentor:dispatch-agents` and annotates every implementation step (one step =
  one dispatch). Skipping requires the plan to open its Implementation steps
  with `Dispatch: skipped — <reason>` — visible and reviewable at approval.
  *(Superseded in v2.35.0 — implementation dispatch is no longer the default;
  see the routing test in that release's notes.)*
- **Escape hatch:** trivial work (roughly ≤ ~20 changed lines, nothing new to
  read) or work needing tight user back-and-forth may skip; if a skipped task
  turns out non-trivial mid-flight, stop and dispatch normally.
  *(Superseded in v2.35.0.)*
- **Orchestrator contract:** the main thread never reads delegated files —
  it verifies via executable `Done when:` checks, `git diff`, and failing
  command output; one remediation re-dispatch, then escalate to the user.
  Progress is checked off in `plan.md` (✅) so resumed sessions know what ran.
- **Sequential-collapse rule:** adjacent small dependent steps (combined
  ≤ ~40 lines, same role/model) merge into one dispatch — no agent-startup tax
  per tiny step.
- **Backstops:** `plan-review`'s consistency reviewer flags plans with neither
  annotations nor a skip line; `approve-plan.sh` (Proceed) prints an
  informational SDD directive. In-plugin `Skill()` references are now uniformly
  `mentor:`-namespaced.

## Changes in v2.2.0

One plan = one directory. Previously a single zoom-reviewed plan could leave
30+ flat files in `.mentor/plans/` (the `.md`, up to 16 `<slug>-<topic>-<perspective>.html`
zooms, and a visible `.opened` sidecar for each). Now:

- **Per-plan dirs:** the plan lives at `plans/<slug>/plan.md` (fixed name); zoom
  artifacts live in `plans/<slug>/zoom/<topic>-<perspective>.html` (the `<slug>-`
  filename prefix is gone — the dir carries it).
- **Hidden sidecars:** the open-once markers are dot-hidden
  (`.plan.md.opened`), so `ls .mentor/plans/<slug>/` shows just the plan and its
  `zoom/` dir.
- **Silent migration:** the next `/mentor:plan` run migrates any old flat layout
  in place (`<slug>.md` → `<slug>/plan.md`, `<slug>-*.html` → `<slug>/zoom/`,
  longest slug first so prefix-colliding plans keep their own zooms). Old flat
  `.opened` sidecars are swept; orphan `.html` files without a matching `.md`
  are left where they are (gitignored, harmless).
- **Note:** handoff notes written before v2.2.0 may reference the old flat plan
  path — the plan now lives at `…/<slug>/plan.md`.
- **Superseded (v2.12.0):** the per-plan `plans/<slug>/zoom/` location described
  here was later replaced by the flat `.mentor/zooms/<subject-slug>/` tree;
  `begin-plan.sh` relocates old zoom files automatically.

## Changes in v2.1.0

The working mode no longer gates execution — it is now only the **approval-gate
default**. `/mentor:plan` never asks an upfront mode question (an unset mode behaves
as `plan`), and the approval step **always offers both** "Proceed" and "Deliver plan
only"; the persisted mode merely decides which is listed first.

- **`plan-only` no longer hard-blocks implementation:** choosing "Proceed" in a
  `plan-only` repo implements immediately — teams that relied on the hard stop have
  the operator pick "Deliver plan only" at approval instead.
- **No config migration needed:** a committed `{"mode":"plan-only"}` now simply
  reads as "deliver-first default".
- **`approve-plan.sh` is mode-agnostic:** it gained an explicit `--deliver` flag
  (the deliverable soft-stop) and no longer reads the persisted mode; directives
  are also printed when the gate is already open, and unknown flags are rejected.
- **"Hand off to next agent" moved out of the default approval options** — it
  leads them when the context gate warns, and stays reachable via "Other" or
  `/mentor:handoff` after a deliver-only approval.

## Breaking changes in v2.0.0

mentor's state moved from **user scope** (`~/.claude/mentor/<repo>-<hash>/`) to
**project scope** — `<repo>/.mentor/` — so config, plans, handoffs and markers live in
the repo they belong to (`config.json` + `constitution.md` committed; the rest
gitignored). Also new: the **context gate** (above).

**Migration:** the old user-scope state is **ignored**, not read. Re-run `/mentor:mode`
once per repo to re-persist the working mode; existing plans/handoffs under
`~/.claude/mentor/<repo>-<hash>/` are orphaned and can be deleted. Not-in-a-repo
handoffs still use `~/.claude/mentor/_no-repo/`.

## Breaking changes in v1.0.0

mentor 1.0.0 is a wholesale simplification (~10.5k → ~3k lines). Removed:

- **Worktree strategies** — the 4-option strategy question, worktree allocation,
  `worktree-confine.sh`, and per-worktree `mentor.json` are gone. For isolated-
  branch work use Claude Code's native worktree tooling (`EnterWorktree`).
  `/ship` became `/mentor:ship` and ships the **current branch**.
- **Orchestrator subsystem** — the session-wide always-delegate gate, its prompt
  injector, trackers, `/mentor:orchestrator`, and the `commander` stub.
- **HTML plan format & format config** — `/mentor:plan-output-format`, the styled-
  HTML plan document, its machine contract, and the finalize-to-Markdown
  lifecycle. Markdown is the only plan format; HTML survives as an explicit
  opt-in zoom artifact.
- **Native plan-mode integration** — the `ExitPlanMode`/`.proceed-mode` fallback
  path and its hooks. The owned marker flow is the only flow.
- **Enforced delegation** — the read-budget and plan-author gates
  (`plan-read-gate.sh`, `plan-author-gate.sh`, trackers) are gone; research and
  plan-author delegation is suggested, not enforced. `MENTOR_PLAN_RESEARCH`,
  `MENTOR_PLAN_AUTHOR`, `MENTOR_PLAN_FORMAT`, and `MENTOR_PLAN_EXIT_MODE` no
  longer exist.
- **Footer markers & strategy-guard** — plans no longer carry
  `strategy:`/`worktree:`/`dispatch-agents:` footer lines; approval validates
  freshness instead.

Stale state from older versions (`orchestrator`/`format` keys in `config.json`, old
marker sidecars, and the entire user-scope `~/.claude/mentor/<repo>-<hash>/` tree from
≤ v1.x) is simply ignored.

## Requirements

`jq`, `git`, and `python3` (only as a `realpath` fallback for path canonicalization).

## Attribution

The `grilling` (`/mentor:grill`) skill is adapted from
[mattpocock/skills](https://github.com/mattpocock/skills) (the `productivity` skill set), reworked
to fit mentor's conventions, namespacing, and gates. A handoff skill adapted from the same set
shipped until v5.0.0.

Planning's retrospective playbook (`/mentor:retro`) is inspired by Cursor's
[pstack](https://github.com/cursor/plugins/tree/main/pstack) plugin and its `/reflect`
command — the three-reviewer-over-one-session pattern and the Accepted / Rejected / Backlog
synthesis. mentor's port runs inside its own core concept (approve once, run to a done-check),
adds the cross-host, compaction-surviving evidence graph, and removes Cursor's model names and
paths.
