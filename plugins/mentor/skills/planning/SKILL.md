---
name: planning
description: >
  Plan and run goals with one approval, a durable .mentor/ plan and independent
  checks. Use for requests to create a plan (including design or scope before work),
  run a goal end to end, or continue executing an identified approved .mentor/ plan.
  Also use for retrospectives of the current or one named finished agent session:
  "retro", "retrospective", "reflect on this session", "lessons learned",
  "what should become a skill", "turn this session into a skill",
  "turn what I keep doing into a skill", "lessons from today's session",
  "look back over what we did", or "worth saving as a reusable skill or a tweak to an
  existing one". Rebuilds from disk even for empty, short or compacted threads,
  applies local skill changes and reports proposals.
  NOT for batch harvesting across sessions (loom), progress/status recall or handoff
  notes, routine plan-document edits, direct edits/refactors without a plan or
  end-to-end request, ordinary how/why questions, standalone shipping/merging,
  or bare mockups (previewing).
---

# mentor Plan

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

The flow: check the gate & load the constitution → clarify if needed →
create the draft, pick a playbook & research → triage open questions (evidence, decision-maker,
human) → complete the Markdown plan (Goal check, decision log, Constitution Check
when a constitution exists) → (optional review page via `mentor:previewing`, on
request) → **the one human approval** → run until the Goal check passes →
deliver with a Done review. This is the core concept pinned in the
marketplace's `AGENTS.md` → Mentor core concept.

While this worktree's `.planning.<wt-id>` marker is armed — or the legacy,
repo-global `.planning` marker, which blocks every worktree at once —
`plan-gate.sh` blocks every Write/Edit/MultiEdit/NotebookEdit inside the repo
working tree. The only files written during planning are the plan and its
opt-in review page (plus, when that page's first build asks about
diagram-design, the `diagram_renderer` key in `.mentor/config.json`), all
inside the gate-exempt `.mentor/` tree. Do not run
repo-mutating shell commands during planning either; Bash is not enforced,
but the rule is the same.

## Step 0 — Gate & constitution {#gate}

This is a direct planning entry point: select it when the user asks to plan, whether
they use natural language, a host's skill picker, or Claude Code's `/mentor:plan`
facade. **Do not make source edits while planning; write only the durable `.mentor/`
plan artifacts until the user explicitly approves.** The Claude facade adds an enforced
worktree gate; other hosts use this same boundary as an instruction. The boundary stays
explicit because an unavailable host integration must not turn a planning request into
unannounced implementation.

Resolve the optional Mentor helpers portably. `PLUGIN_ROOT` is the canonical host
contract; `CLAUDE_PLUGIN_ROOT` is a Claude Code compatibility fallback:

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  mentor_dir="$(bash "$plugin_root/hooks/plan-state.sh" dir)"
  gate="$(bash "$plugin_root/hooks/plan-state.sh" gate)"
  printf 'MENTOR_HELPERS=available\nGATE=%s\n' "$gate"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  mentor_dir="$repo_root/.mentor"
  gate="ADVISORY"
  printf 'MENTOR_HELPERS=unavailable\nGATE=ADVISORY\n'
fi
```

When `GATE=ARMED`, preserve the existing Claude worktree gate behavior. `STALE`,
`RELEASED`, and `ARMED_ELSEWHERE` do not gate this worktree. When `GATE=ADVISORY` or
another non-armed value is returned, continue directly — never send the user away to a
slash command — and state that no host-level edit gate is active. Do not run
`begin-plan.sh` merely to simulate the command facade.

(Why a genuine Claude gate must be observed when present: `references/rationale.md`
→ **Step 0 — the armed-gate check**.)

When the Claude facade ran, `begin-plan.sh` may have printed a **`CONTEXT:`** line (the context gate):

- **`CONTEXT: WARN`** — the session is getting large. Surface it to the user. Nothing
  about *how* you plan changes.
- **`CONTEXT: HIGH`** — over the limit. Everything WARN does, plus: do not propose a
  review page (Step 5) yourself — an explicit user ask is still honored. "Keep the plan
  lean" means exactly that omission: Step 4's content spec never shrinks.

The context gate only warns.

**An already-approved plan goes straight to implementation.** When the facade printed
**`ALREADY APPROVED: <slug>`** (`begin-plan.sh` saw that slug `approved` or
`in_progress`, owned by this worktree or unowned, and did not arm) — or, on direct or
other-host entry, the user named an existing plan and its sidecar passes the same rule:

```bash
plans="$mentor_dir/plans"   # mentor_dir from the Step 0 block
jq -r '"stored=\(.state // "") owner=\(.owner // "") note=\(.note // "")"' "$plans/<slug>/.state.json"
```

Build when `stored` is `in_progress`, whatever the step ticks say — an all-ticked run
still owes After Proceed step 6 onward. Build when `stored` is `approved` only if the
ticks have not taken it past that (with helpers, `plan-state.sh query --slug <slug>
--format tsv --fields state` reads `approved` or `in_progress`). This is the rule
`begin-plan.sh` applies. If `owner` is set and differs from this worktree, and this is
not the facade path, ask the user before building.

Then load the constitution (below in this step), read `references/playbooks.md`, and
Read each file selected by the plan's `## Playbook` value through that index. Accept
both an inline value (`## Playbook: playbook-software-change`) and a value on the
next non-empty line after `## Playbook`; resolve released aliases without rewriting
the plan. This preserves approved selections when playbook files move.
Skip Steps 1–6 and go to **After Proceed — run until the
Goal check passes** (`{#implement}`) for that slug — re-planning an approved plan would
only re-ask a question the user already answered. Two checks first: a `note` saying it
was **not individually reviewed** (a plan swept in by a release) means nobody approved
it on its own — confirm with the user before building it; a `note` starting `paused:`
means the run stopped on that decision-log row — ask its question first, write the
`resumed` row, then continue. A resumed run has no run marker (only `approve-plan.sh`
writes one, for the session that approved), so the Stop hook does not hold this
session: keep working until a terminal state per **Hosts without a Stop hook or
subagents**. To re-plan instead, run `plan-state.sh set <slug> draft`, then plan it
again (`/mentor:plan <slug>` in Claude Code).

On resume, read `references/principles.md` and re-check inherited claims backed by
neither a tick nor a verdict file: **a passing prior self-report is not the proof**.
Use the existing readers for historical ticks and saved verdicts; do not blanket
re-grade supported history. This checks unsupported claims without redoing proven work.

**Load the constitution.** Resolve the constitution path (a repo may keep its
governing doc outside `.mentor/` — `constitution_path` in `.mentor/config.json`
points at it; see `/mentor:constitution`'s adopt-by-reference branch):

```bash
# `mentor_dir` comes from the Step 0 helper-or-artifact fallback. Re-derive it when
# this runs in a separate shell.
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  mentor_dir="$(bash "$plugin_root/hooks/plan-state.sh" dir)"
else
  mentor_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.mentor"
fi
repo_root="${mentor_dir%/.mentor}"
const_rel="$(jq -r '.constitution_path // empty' "$mentor_dir/config.json" 2>/dev/null)"
const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
```

If the resolved file exists, `Read` it now — its principles are governing rules
for this repo. Keep them in mind through research and design, and prove
compliance in the plan's **Constitution Check** section (Step 4). If it is
absent but `docs/constitution.md` or `CONSTITUTION.md` exists at the repo root,
surface that once: the repo appears to have a governing doc mentor is not
reading — suggest `/mentor:constitution` to adopt it by reference. Otherwise no
constitution governs this repo; skip the Constitution Check (you may mention
`/mentor:constitution` once if the user seems to want project-wide rules).

## Step 1 — Clarify (optional) {#clarify}

If the request is ambiguous — unclear scope, multiple plausible interpretations,
missing acceptance criteria — invoke `Skill(skill="mentor:grilling")` before
designing anything. Skip this for well-specified tasks.

## Step 2 — Research {#research}

**Create the plan file before research.** Scan for a topic-adjacent existing plan before
minting a slug, so a repeated request can continue its earlier draft:

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  bash "$plugin_root/hooks/plan-state.sh" list --owners
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  find "$repo_root/.mentor/plans" -mindepth 2 -maxdepth 2 -name plan.md -print 2>/dev/null
fi
```

Reuse only an obvious same-topic slug owned by this worktree or unowned (`-`); mint
fresh when uncertain or when another worktree owns it. Read a reused plan and its
sidecar `note` for prior decisions or rejection feedback, using the helper-resolved
plans dir rather than a CWD-relative path:

```bash
jq -r .note "$(bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" dir --plans)/<slug>/.state.json"
```

Without the helper, use `$repo_root/.mentor/plans/<slug>/` from the scan and read the
sidecar's `owner` as well. This preserves prior work without taking another worktree's
plan.

Create or reuse the directory and state record in one call, substituting the selected
slug (for a new one, kebab-case, ≤30 chars, drop articles, keep nouns/verbs):

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  plan_md="$(bash "$plugin_root/hooks/plan-state.sh" start "<slug>")" || exit 1
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  plan_md="$repo_root/.mentor/plans/<slug>/plan.md"
  mkdir -p "$(dirname "$plan_md")"
fi
plan_dir="$(dirname "$plan_md")"
echo "$plan_md"   # stable across revisions; no timestamp
```

`start` is idempotent: it creates the private directory, records a new plan as `draft`,
and stamps this worktree's ownership. Without the helper, keep the same durable path
and preserve any existing `.state.json`; do not invent or overwrite a sidecar.

**Track every plan write on every host.** Before editing a plan that may have changed,
run `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" drift <slug>` and
read any changed content before editing it. Immediately after every mentor write to
`plan.md`, including shell writes and writes on hosts without hooks, run:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" record-write <slug>
```

Never call `record-write` merely to clear a change notice. This preserves outside
changes and keeps mentor's own writes from appearing as drift (mechanism:
`references/rationale.md` → **Plan-file continuity — early drafts, feedback, and tracked writes**).

Write a new skeleton with the title, `Rev 1 · YYYY-MM-DD · Research started`, a
plan-level `Goal:` line stating the user's intended outcome,
`## Context`, `## Research notes`, and `## Decision log` (the flat table in Step 4's
Content spec); extend a reused draft without replacing its content or Rev history.
Append findings and decision rows as they land, and complete the remaining sections
in Step 4 before running strict `verify`. Leave an abandoned skeleton as a `draft`
visible in `plan-state.sh list`, without a cleanup prompt. This keeps research and
decisions recoverable through compaction (rationale: **Plan-file continuity — early
drafts, feedback, and tracked writes**).

**Pick a playbook.** Read `references/playbooks.md`, match the requested plan
deliverables to its "Loads when…" entries, then Read each matching file as a
reference. Do not select from the session's skill list or invoke playbook skills;
deliverables, rather than incidental code or installed skills, determine the match.
An ordinary question outside a plan loads no playbook. A selected file supplies
these overlays at the named points:

| Overlay | Read at |
|---|---|
| Research directives | this step |
| Definition of done | Step 4 `## Goal check` and each `Done when:` |
| Extra always-pause items | the run (After Proceed), on top of the constitution's |
| Deliver mode | the run's deliver state |
| Evidence kinds | the Done review |
| Run rules (optional; absent means none) | After Proceed, throughout the run |

Record the indexed names as the plan's `## Playbook` value and a decision-log row.
No match → the general flow runs alone with delivery owner `general`
(`## Playbook` reads `none`). The user can name or refuse a playbook in plain words;
that wins over the match.

**Combine overlays before approval.** Definitions of done combine with AND, scoped
per artifact. Choose one delivery owner during planning (a selected playbook or the
general flow), record it in the decision log, and include compatible secondary
outputs in its delivery. Deduplicate research and evidence; union always-pause
items with the constitution's or built-in list. Resolve incompatibilities before
approval, never by load order; do not add a prototype overlay mid-plan. This keeps
one coherent delivery contract without weakening any applicable check.

Read `references/principles.md` before research and apply the entries whose triggers
match, so research tests assumptions and covers causes before choosing a fix.
Research what the plan needs: the files, config, docs and history the work touches,
and the facts each decision will turn on. How you gather it is up to you and the host —
read directly for a small task, or use whatever research tooling the host offers for a
wide one. Bring back conclusions with `file:line` evidence and a short list of open
questions; those questions feed Step 3's triage and are never silently dropped. When the
plan touches a second repository, resolve its real path first — the edit gate protects
only the repo the session's CWD sits in.

**Research the category, not just the named instance.** When the request names
one instance of something the repo may have several of — one job to make
continuous, one config to centralize, one surface to consolidate — search for
its siblings before completing the plan, and carry each hit into Step 3 as a scope
decision. A sibling found at the approval gate rewrites the plan; the same
sibling found here costs one question.

**When the request corrects a bad state, also find what regenerates it.** A
migration or cleanup that only fixes the data leaves whatever produced it free
to reproduce the same defect on the next run — a script, an importer, a cron
job, a form handler, or a skill/rule that doesn't validate before writing are
all candidates. Search for that producer before completing the plan, and carry what you
find into Step 3 as a scope decision, the same way a sibling instance is
above.

**A page/feature joining an existing repeated pattern may have its membership
tracked in more than one place.** Wiring a new entry into a nav list, a
routing table, a tab registry, or any other structure that already has
several siblings sometimes means updating a second, independently-maintained
list that mirrors the first without either side pointing at the other — a
route table beside a nav list, a hardcoded switch beside a registry. Check
for a second list before completing the plan, the same way a sibling instance is above;
a hand-paired list found at the approval gate rewrites the plan, the same
list found here costs one question.

**A same-session restart — or an earlier grill — is not a blank page.** When
the user interrupts mid-research to broaden or redirect the request and
re-invokes `/mentor:plan`, or when a `grilling` phase (via `/mentor:grill`
directly, or Step 1's own route into it) already ran earlier in this session,
check the conversation for research findings already delivered on the same
subject before starting a fresh round — a broadened scope usually extends
prior findings rather than replacing them, and a prior grill's research
may have already covered the same ground, so re-researching territory
already covered wastes a full round on overlap the transcript already has
the answer to. Research only the ground the broadened request — or the
grill's own research — genuinely didn't cover.

**Never search `.mentor/` with a recursive `grep` — use `sweep`.** Ignore rules make a
recursive grep report a clean zero for a recorded instruction, which looks the same as
"nothing recorded" (mechanism: `references/rationale.md` → **Step 2 — why searching
`.mentor/` needs `sweep`, not a grep**). `sweep` hands grep an explicit file list and
resolves linked worktrees to the main repo's `.mentor/`:
```bash
[ -d "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks" ] || { echo "ERROR: Mentor helper unavailable — set PLUGIN_ROOT (or use the Claude compatibility fallback) or use the documented artifact fallback" >&2; exit 1; }
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" sweep "<pattern>" --roots plans
```
It prints `SWEEP: roots=N files=N hits=N` before any hits, so a zero is trustworthy only
when `files=` is non-zero; exit **2** plus a `NOTHING-SEARCHED` line means it read nothing
at all and its silence is not evidence.

**Verify literal CLI commands, and claims about a live system's current state, before
drafting them into the plan.** A deploy/release-shaped step that types an exact command
from memory or a runbook paraphrase otherwise gets its first real syntax check when it
runs verbatim against a live system. Before
writing a literal command into such a step, verify it (`--help`, `--dry-run`, or the
tool's own docs) rather than transcribing it as fact. The same applies to claims about
the deploy target's current state (backups exist, a version is what you think it is,
a rollback path works): verify it this session, or write it as conditional on a named,
mandatory verification command, with the fact stated as unverified rather than asserted —
an external-state claim nobody re-checked reads as fact to whoever runs the step. A step
with no captured pre-change state has no rollback anchor either way.

**A fast-moving vendor/product/SDK topic goes to the reference skill before it goes to
memory.** When a research topic names an external platform, SDK, or cloud service that a
skill already available this session covers — the session's skill list, not a filesystem
hunt — load that skill before answering, and make sure any research you hand off is
told to load it too; recall from training data is where such topics go stale first.
Whenever the name could mean more than one product or API from the same vendor, say in
the findings which one they describe — a silent pick surfaces only downstream, after it
has already shaped a user question.

## Step 3 — Triage open questions & decisions {#decisions}

Before completing the plan, drain every open question so the plan encodes
decisions, not question marks. Collect them from all sources: the open
questions research surfaced (Step 2), the playbook's directives, and any design
fork you noticed yourself (approach A vs B, scope boundary, acceptance criteria,
naming). The human is asked only what no one else can answer (AGENTS.md →
Mentor core concept, rule 4).

Read `references/principles.md` during triage; name a principle in the decision log
only when it changes a choice, so the log records decisions rather than a checklist.
Triage each item into exactly one bucket, in this order:

1. **Codebase-answerable** — the files, config, history, or docs settle it.
   Answer it yourself; never ask the human what the material can answer.
2. **Experiment-settleable** — a fact a quick probe can establish (does this
   flag exist, which form does the tool accept, how long does it take). Run the
   probe in a private `mktemp -d` scratch dir, or under
   `.mentor/plans/<slug>/evidence/` when the result is worth keeping as
   evidence. Record the probe and its output as a decision-log row.
3. **Constitution-covered** — a reversible call that the constitution's
   Decision authority (or, with none, ordinary good practice) lets an agent
   make. Dispatch a decision-maker (below) and log its choice.
4. **Product call** — preference, product direction, a trade-off with no
   objectively right answer that the Decision authority does not cover, or any
   choice that commits an always-pause item. Queue it for the human (before approval
   only; mid-run see After Proceed, steps 4–5).

**Immaterial** items — the plan comes out the same either way — are dropped, or
logged as a flagged assumption.

### Role resolution {#decision-maker}

Delegate only work the goal needs, and resolve every needed role by its described
domain or purpose. This keeps the workflow portable across hosts and agent registries
without creating work merely to fill roles.

Open every role brief with the plan-level Goal: line verbatim, or `Goal:` followed
by the user's request if no plan exists.
For a released plan that has no plan-level Goal: line, derive one sentence from its approved Context and Goal check, cite those sections in the brief, and leave the saved plan and its predicate unchanged.
Put the local task after it so every agent can judge its work against the user's
intended outcome.

- **Purpose:** decide system design (architecture, backend, data, infra, or rollout);
  decide what a person sees or does; decide scope, process, or docs; research facts;
  build the artifact; grade the result independently; or settle conflicting findings.
- **Resolution order:** honor an explicit session mapping first; otherwise choose an
  installed agent whose description fits the needed domain or purpose, regardless of
  its name or tool. If none fits, brief a general-purpose agent for that purpose,
  including "decide; do not ask" for decision work. If delegation is unavailable or
  prohibited, perform the work serially in the main thread, retaining the same scope,
  evidence, and verification contract, including labelled self-grading when required.

**Decision-maker contract** — apply to whichever agent resolves a decision:

- **Brief** (self-contained; the agent inherits none of your context): open with the
  goal as above, then the question in plain words, the options known so far with their consequences, the
  constitution's Decision authority section verbatim, and the evidence with
  `file:line` or command output.
- **Return**: `choice · why · evidence · product_call: yes|no`. A `yes` sends the
  item to bucket 4. Several independent items may go out in one batch.
- Every decision becomes one decision-log row (Step 4), `result: decided`.

**Mid-loop scope change.** A scope-change request (not a decision *answer* —
a change to what the plan covers) pauses the per-item loop: confirm the scope
delta itself — what's kept, what's cut — in one `AskUserQuestion` before
continuing. A derived boundary question asked in its place resolves nothing,
because the boundary it assumes was never agreed.

Resolve the queued product calls via `AskUserQuestion`, ordered by dependency:
resolve the decision other decisions hang off first, and let each answer narrow the
next question.

**How many decisions ride in one call is a judgment call with two hard edges.** The
reason to separate them is that a decision answered while three others compete for the
same attention gets a rushed answer; the reason to combine them is that a plan with six
independent decisions should not cost six round trips. So:

- **A decision gets its own call when it is consequential** — it changes what gets
  built, what it costs, or what has to be redone if the answer turns out wrong. The
  clearest tell is that the options diverge sharply: one is an afternoon and another
  is a week, or one forecloses something the other keeps open. These deserve the
  user's whole attention, and a wrong answer here is expensive to unwind.
- **A decision must stay sequential when an earlier answer could change it** — its
  options, its framing, or whether it needs asking at all. This is not a preference;
  a question whose premise the previous answer just invalidated is worse than no
  question, and the dependency ordering above is what surfaces these.
- **Everything else may ride together**, up to the tool's cap of four questions per
  call. Each is still a separate question the user answers on its own screen with its
  own decision brief — combining calls saves round trips, never deliberation. Group
  only decisions that genuinely cannot affect each other; when in doubt whether two
  interact, they are sequential.

Never offer bulk acceptance as an *option* on a question: these decisions share no
common binary (accept/reject) to apply in bulk, so a bulk button here would be
ill-defined.

**Free-typed bulk-accept.** If the user free-types an instruction to take your
recommendations rather than answering item by item — often by interrupting the open
question ("go with your recommendation", "pick the defaults") — map it onto the queue:
accept the recommended option for every decision still unanswered; every question here
carries one by construction (below), so this path leaves nothing unresolved. Before
completing the plan, name what you are accepting on — each decision by its plain-language name,
one line each — since "your recommendation" after four answered questions usually
means the remainder but can mean the whole set, and the user can only correct a span
you showed them. An instruction that also changes what the plan covers is a scope
change first: resolve it under the rule above, then resume. Naming the span is what
makes this safe even when several decisions rode in one call — the user sees exactly
which recommendations they just accepted.

**Every question ships with decision support, and stands on its own** — the
user answers from the question screen alone, never sent to a file, a plan
section, a coined id or code (`G14`, `P2`), or an earlier turn to learn what
the question means. A word the user could read as themselves — "user" above
all — never names a domain entity; when a reviewer finding or a research
return used it that way (a caller, a row, a consumer), rename it before the
question reaches the screen. Name things in plain language, quote the
evidence that decides it rather than citing where it lives, and say in each
option what it changes and what it costs:

- In the message text **before** the tool call, give a compact decision brief:
  what the decision is, why it matters to this plan, and the relevant evidence
  from research (observed behavior, constraints, and the code itself — quote
  the line that decides it and put its `file:line` beside the quote, so the
  address is a courtesy for the curious rather than homework for the answer).
  When the decision turns on what is actually in a data or config artifact,
  read the artifact — a research summary's or the plan's own description of
  it is not the evidence. Enumerate the rows a rule applies to, not just the
  rule.
- `AskUserQuestion` needs 2–4 options per question. For open-ended decisions
  (naming, free-form scope), synthesize 2–4 concrete candidates from the
  research — the tool adds a free-text "Other" automatically, so a candidate
  list never traps the user. Only when you truly cannot form two sensible
  candidates, ask in plain prose instead.
- Put your **recommended option first** with "(Recommended)" appended to its
  label (a convention for decision questions like these — fixed workflow gates
  such as Step 6's approval order by position alone), and make each option's
  `description` carry its concrete consequence or trade-off — not a
  restatement of the label. The recommendation itself must be the most
  practical and clean solution — never trade maintainability or reliability
  for implementation speed.
- When options are competing shapes (schemas, layouts, flows, wording), use
  the `preview` field so the user compares them side by side — but keep it to
  a short literal fragment of the thing being chosen between (the actual
  snippet, schema, or wording; roughly ≤10 lines), never a framed mockup.
  Box-drawing glyphs and non-ASCII text (Thai, CJK, …) each expand to a
  6-byte `\uXXXX` escape inside the tool call's JSON, so a mockup that looks
  small on screen can truncate the call mid-string and fail validation —
  costing a whole turn to retry. **If the comparison needs a frame, a grid,
  or aligned columns to be legible, it is not a `preview`**: say so in the
  decision brief and offer a review page (Step 5 / `mentor:previewing`) instead —
  the user asking is the opt-in that step requires.

Each answer becomes a plan input and a decision-log row (`result: kept`). An
"Other" answer may open new questions — triage those through the same buckets. If the user explicitly defers a
decision, record the deferral in the plan (as a flagged assumption or under
Out of scope) rather than silently choosing for them. A rejected or
interrupted question is neither an answer nor a deferral — when the
clarification lands, re-issue the question; a recommendation given in prose
does not resolve a decision, and an unresolved decision that is never
re-asked is the shape a stalled plan takes.

**Skip condition:** no product calls survived triage → proceed straight to
Step 4. Never manufacture questions to fill the step — a well-specified task
with clean research needs zero.

This step resolves *post-research* decisions with evidence in hand; Step 1's
grilling handles *pre-research* ambiguity in the request itself. An earlier
grill session does not skip this step — research may have surfaced new forks —
but a decision already resolved anywhere in the conversation is never
re-asked.

## Step 4 — Complete the Markdown plan {#write-the-plan}

Complete the skeleton at Step 2's existing `plan_md` path with the Content spec below,
preserving its research notes, decisions, and Rev history; do not mint another slug.
This keeps research and the approval draft in one durable file (rationale:
`references/rationale.md` → **Plan-file continuity — early drafts, feedback, and tracked writes**).

The path is inside the gate-exempt
`.mentor/` tree, so the edit gate allows it; `plan-open.sh` auto-opens it for review the first time
(VSCode tab when available; opener configurable through the host's Mentor environment).
Opening is a convenience, not a delivery requirement. **Keep it current:** revise this SAME
file with whole-section `Edit`s — replace a whole section, table, or fenced block per edit;
use a full `Write` only for a restructure. Never
create a second timestamped copy or write the plan to a host-native plans directory instead
of `.mentor/`. Section edits avoid resending the whole plan on every revision, and an anchor
that lands mid-table or mid-fence can splice a row or split a fence without erroring.

**Verify the write:** re-`grep -n` each edit's target text against the file's current
on-disk state immediately before applying it; earlier edits can move an anchor. Once
the Content spec is complete, and after every later content revision, run:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" verify <slug>
```

when the helper is available. Otherwise perform the equivalent visible checks — balanced
fences, valid tables, and a `Done when:` for every implementation step — before asking
for approval; do not fail a portable planning flow solely because the helper is absent.

`verify` is one call for the four checks that gate its exit code: fence balance,
table pipe-count uniformity, every step in `## Implementation steps` carrying a
`Done when:`, and a new plan carrying `## Goal check` and `## Decision log` (why one call: `references/rationale.md` → **Step 4 — why verify is one
call**). A non-zero exit
names the failing check on its own `CHECK:` line — read that line rather than
guessing which one broke, since a step missing its `Done when:` is also what a
body truncated by a mis-parsed step line looks like. Every other `CHECK:` line
it prints is informational and never fails the call, `CHECK: context` included;
that one is the same reading "Re-check context" below asks for, so if nothing
else ran between this call and the approval ask, that reading already
satisfies it — no second `context` call needed.
Only a plan whose stored state is `draft` gets `CHECK: untraced step N` when a
step's `Goal:` lacks `serves S`; this is informational, and released plans skip it.

### Content spec

The `.md` file is the canonical plan — self-contained, portable, renders richly
on GitHub/GitLab and any Mermaid-capable viewer. No inline HTML/CSS/SVG.

Required sections, in order:

1. `# <Plan title>` — directly below it, keep an appended Rev changelog, one line per
   content revision: `Rev N · YYYY-MM-DD · <what changed>`, starting at Rev 1, newest last.
   Step 2's skeleton is Rev 1; completing the plan in Step 4 adds the next Rev line, and so
   does each later revision. Add no Rev line for research notes or decision rows appended
   during Steps 2–3, step ticks, or run-time log rows. `verify` already reports Rev-line
   order; the newest line identifies the content the user is asked to approve.
   A plan with no Rev line yet gets `Rev 1` on its next content revision.
   Below the title and Rev lines, keep a one-line plan-level Goal: stating the user's
   intended outcome; reuse it verbatim in Step 6's approval card and every brief.
2. `## Context` — the problem, what prompted it, intended outcome. Retain Step 2's
   `## Research notes` directly after it.
3. `## Use case scenarios` — actors & triggers; current vs expected behavior;
   concrete scenario walkthroughs labelled `S1`, `S2`, … (real values from research, not
   placeholders); edge cases & assumptions (flag anything unverified). Give this
   section visualization treatment — a Mermaid flowchart/sequenceDiagram of
   actor→trigger→outcome, or a current-vs-expected GFM table — so the reviewer
   can verify your understanding at a glance.
4. `## Approach` — the recommended design — the most practical and clean
   solution for the requirement, never trading maintainability or reliability
   for implementation speed — with one visualization per significant
   change/decision realized inline under its owning topic.
5. `## Constitution Check` — **include only when the constitution resolved in
   Step 0 exists** (default `.mentor/constitution.md`, or the file
   `constitution_path` points at). A GFM table with one row per principle: `Principle | Verdict | Notes`,
   verdict = ✅ complies / ⚠️ deviates / ➖ N/A. For every ⚠️, the Notes cell must
   either point at the plan change that resolves it or record an explicit,
   justified deviation. If a principle can only be honored by amending the
   constitution, say so and stop short of encoding the violation as the plan.
   A ✅/➖ verdict that rests on a repo search finding nothing names the
   gitignore-bypassed command it ran (Step 2's caveat) — a verdict resting on an
   unqualified `grep -r` is not yet earned.
6. `## Implementation steps` — numbered and concrete. Every step carries `Goal:`,
   `Inputs:` and `Done when:` on `-` bullets under its numbered heading; `verify` fails
   a step with no `Done when:` under it.
   End each step's `Goal:` with the scenario(s) it serves, e.g. `(serves S1, S3)`.
   During drafting, move a step serving neither a scenario nor a Goal-check clause
   into `## Out of scope`, so the plan contains only work the goal needs.
   **Keep it small while you write:** if the step count creeps past ~12, move non-core
   **isolated deliverables** into `## Out of scope` (each can become its own plan later).
   A plan's `## Verification` section is never one of those chunks — every topic stays
   with the work it checks.
   **Never title a step "Verification pass," "Testing," or similar** — that name
   belongs to the plan's own `## Verification` section below, and a step that reads
   as satisfying it invites skipping that section's checks at execution time. Name the step for what it builds or fixes instead.
   **A literal command written into a step here, on a live or shared system, must already
   be verified** per Step 2's directive — not transcribed from memory as you draft.
   **A check command must fail loudly.** Prefer a command's own exit status over a
   `|| echo 0` fallback — a real tool failure and a genuine zero then print the same
   output, and the fallback launders an error into a passing `Done when:`. A playbook
   may add its own command rules (the software playbook's pathspec rule, say).
7. `## Critical files` — cite a file this repo's own tooling edits
   automatically by **section heading**, never a line number: a stale line
   reads as confirmed instead of wrong. This applies anywhere in the plan
   that cites such a file, not just here — `## Implementation steps` and
   `## Verification` included.
8. `## Out of scope` — name every carve-out so the reviewer sees the
   boundary, but give one a **plan number or slug** only when it resolves on
   disk (an existing plan under `.mentor/plans/`);
   an invented `feature 0NN` reads as a roadmap promise nothing on disk backs.
9. `## Verification` — 2–6 single-focus topics, each in this shape:

   ```
   Topic N — <short title>
     Focus: <the single question this topic answers>
     Checks: <concrete commands to run / evidence to gather>
     Pass when: <observable criteria>
   ```

   Each topic runs after implementation, before the plan is marked `implemented`.
   `Topic N —`, never `Step N —` or a bare numbered item, keeps mentor's step
   counter from mistaking a verification topic for an implementation step. One
   focus per topic, because a gap in one check hides behind a pass in another.

   **This section owns end-to-end proof.** When a behavior can only be shown by
   exercising the whole deliverable (a running system, the full report read
   cold), write that check as a topic here, not into a step's `Done when:` — keep
   each `Done when:` to a bounded check, so a step can be ticked the moment its own
   change is proven.
10. `## Playbook` — one line: the indexed playbook name(s) picked in Step 2, or `none`.
11. `## Goal check` — the plan's done predicate: one runnable or observable check
    against the real deliverable, falsifiable, never a restatement of the steps
    ("`scripts/check` exits 0", "the brief covers all 5 regions, each with a cited
    source"). Shape it from the constitution's Definition of done and the
    playbook's overlay. The run is done only when a verifier grades it PASS.
12. `## Decision log` — one flat table, appended to for the life of the plan:

    ```
    | # | use case | decision | why | evidence | result | review? |
    ```

    `use case` names the `## Use case scenarios` entry the row serves (or `general`).
    `result` is one of `kept` (human answered) · `decided` (agent decided) · `PASS` ·
    `FAIL` (a verifier grade) · `paused` · `resumed` · `failed`. `review?` is `needed`
    for a paused row, a deviation from the plan, a mid-run product call decided by an
    agent, or a re-plan — `optional` otherwise. Append every Step 3 resolution as it
    lands; the run appends the rest. The flat table is canonical: grouping by use
    case happens only when it is rendered for review (After Proceed → Done review).

**Visualization decision rule (pick exactly ONE idiom per artifact):**

- Tabular data (field lists, diffs, matrices, before/after values) → **GFM table**.
- Topology / sequence / state (flows, state machines, ER, dependencies) →
  **Mermaid** fenced block.
- Spatial/layout fidelity (UI zone wireframes, fixed-width alignment) →
  **ASCII diagram in a code fence**.
- Callouts / cautions → **GFM alert** (`> [!NOTE]`, `> [!WARNING]`, …).
- Literal code / payloads → fenced code with a language tag.

**State vocabulary rule.** When a plan introduces, renames, or re-scopes a named
status for any entity (`MONITORING → PENDING`, `ACTIVE → TRIGGERED/CANCELLED`),
or changes which transitions are legal between statuses that already exist —
a new cascade side-effect where reaching one terminal status now forces
another, say — render the *transitions*, not just the values. A status name
staying put says nothing about its edges staying put. The `stateDiagram-v2`
the idiom rule already selects shows the shape — which states reach which,
added and removed edges marked; a companion
`From · Event/verb · To · Trigger · Cascade` table carries what a shape
cannot encode, and it is the table that exposes a
**missing** edge, since reverse transitions and cascade side-effects are the
ones that surface late. That pairing is complementary, not the same-thing-twice
the rule below forbids. Skip it when no entity has more than one named state, or
when the states are unchanged and only their storage moves — that delta belongs
in the plan's schema or per-column change table, and restating it here would
duplicate.

**Workspace layout rule.** When a plan introduces on-disk structure the reader cannot see
today — a new state/workspace directory, a sidecar or companion file, a naming scheme other
paths are derived from — render the layout as an **ASCII tree in a code fence** (the idiom
rule's spatial row), with a one-line note per new path saying what writes it. Prose naming
three paths reads as complete until someone has to create them in the right order; the tree
is what makes a missing one visible. Skip it when the change only touches paths that already
exist.

**Anti-duplication:** never restate in prose what a diagram already shows, and
never show the same thing two ways. Prose next to a diagram is limited to a
one-line caption, a legend, and the why/insight the diagram cannot encode.

**Mermaid portability rules:** do NOT set `theme`/`themeVariables`/`%%{init}%%`
(GitHub/GitLab apply their own); do NOT use `C4Context`/`C4Container` (use
`flowchart TB` + `subgraph` + `classDef` instead); keep each diagram small —
split dense flows into 2–3 focused diagrams; a `;` inside `Note over …: text`
truncates the note — use `,` or `+`.

**Generalist-reviewer principle:** write for a generalist, not a domain expert —
define jargon at first use, state why each step matters, prefer concrete
examples. The plan must be approvable by someone outside the domain.

**Verify headline counts before stating them in the plan.** Step 3's evidence rule —
read the artifact itself, a summary is not the evidence — applies to every
count the plan states about its own scope, not just the decisions that reach a
question: an orphan count, an affected-row count, a terminal-state count.
Re-derive each one from the real data source when you draft it, rather than
carrying a number forward from research recall. A wrong headline count caught
here costs nothing; the same number caught later, once a reviewer's own count
check flags it, costs a multi-section sweep to fix everywhere it was restated.

## Step 5 — Optional review page (explicit user opt-in only) {#preview}

The review page is its own skill — `previewing` — and this step is pure
delegation. Only when the **user asks** for a review page / visual preview —
never by default — invoke `Skill(skill="mentor:previewing")` and follow it end
to end with the plan as the subject:

- **Subject = the current plan** (`${plan_dir}/plan.md`), so per that skill's
  plan-slug contract the page lands at `.mentor/reviews/<plan-slug>/review.html`.

EVERY preview ask re-enters that skill's contract (its re-entry rule) — the
first one, a free-text follow-up ("refresh the preview", "add the error
case"), a mid-revision regeneration, at any point in the plan lifecycle.

**The plan and its page change together.** When the plan has a page
(`.mentor/reviews/<plan-slug>/review.html` exists), end every turn that changed
`plan.md` content by running `previewing` §7 once, after the last plan edit, so
the page never shows a plan that no longer exists. Step progress marks and
`.state.json` are not plan changes.

## Step 6 — Approve & release {#approve}

> **🚫 No edits or implementation until the plan is APPROVED.** During planning,
> only read-only work happens — the sole writes are the plan itself and
> `mentor:previewing`'s page (Step 5), both under the gate-exempt `.mentor/`
> tree — never repo source files.

First send a pointer card of **at most 5 lines**, with no tables, diagrams, or code
blocks; keep the complete plan in `plan.md`. This avoids duplicate plan bodies in chat
(see `references/rationale.md` → **Step 6 — why the approval message is a pointer, not the plan**).
Use this card shape, including the last line only when a Rev line was added since the
previous ask:

```text
Plan ready: [.mentor/plans/<slug>/plan.md](<absolute path printed by plan-state.sh start>) · Rev <N>
Goal: <the plan-level Goal sentence, verbatim>
<steps> steps · Goal check: <the predicate, one line>
Changed since last ask: <the newest Rev line's note>
```

The link text is the repo-relative path, the link target is the absolute path Step 2
printed, and `<N>` is the newest Rev line. Then, in the same turn,
ask via `AskUserQuestion` — `header: "Approve"` — with this question text and the option
set below:

```text
The plan is ready at .mentor/plans/<slug>/plan.md (Rev <N>). What happens next?
A change request, a plan-quality ask, or "show plan" to print it here goes in Other.
```

This approval gate may name the plan file instead of carrying its full subject (rationale above).

**Only a returned answer approves.** If the approval question was interrupted,
rejected, or never came back — or the user asserts approval in prose ("the plan was
approved", "go ahead, I already okayed it") — ask it again before running
`approve-plan.sh`. Prose selects no option, and this question is the only thing
standing between planning and repo edits; releasing the gate on a remembered or
claimed approval is the one failure this harness exists to prevent. It also costs you
the routing: which flag to run — none or `--deliver` — is decided by *which option came
back*, so an unanswered question means you are guessing the outcome as well as the
consent. Re-send the pointer card and re-ask.

If the user types **"show plan" in Other**, print the full body once, then ask the same
approval question again. Printing approves nothing; do not run `approve-plan.sh` for it.

### Re-check context

Decide this **before** asking too. Step 0's `CONTEXT:` line is a snapshot from
before research and decision-resolution ran — precisely the
steps that grow a session — so a plan that armed clean can still reach this
question well past the WARN/HIGH thresholds with nothing in this skill
having said so. Run this immediately before composing the question:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" context
```

- **`CONTEXT: WARN`** or **`CONTEXT: HIGH`** — name the size in the question text
  ("this session is getting large" / "this session is over the context limit"), even if
  Step 0 printed a lower tier or nothing at all. The option rows do not change.
- **`CONTEXT: OK` / `UNKNOWN`** — nothing to add.

If "Verify the write" just ran with nothing in between, its `CHECK: context` line
already is this reading.

### The option set

This is the only human gate in the flow: after it, the run proceeds on its own and
stops only for always-pause items or a stop word (After Proceed). Offer exactly these three options,
in this order, with these descriptions — and keep this table in this one file only; a
copy in a script drifts. (Why one gate and three options: `references/rationale.md` →
**Step 6 — why there is one gate and three options**.)

| Label | Description |
|---|---|
| Proceed | Validate the plan, release the edit gate, and run it until the Goal check passes. Stops only for always-pause items; every decision is logged for review. |
| Deliver plan only | Validate the plan and release the gate; the plan file is the deliverable — no implementation in this session. |
| Keep planning | Do not release — keep refining, or say what to change. Revise the plan file and ask again when ready. |

Everything else the user may want reaches you through the always-present "Other" free
text: a change request, moving isolated deliverables into `## Out of scope`, or a
plan-quality ask — route it per **A plan-quality ask in "Other"** below. An "Other"
answer that plainly says to run the plan is a returned answer: treat it as **Proceed**.
Prose outside this question still approves nothing (above).
Name these in the question text so the user knows they need no button.

On a host without `approve-plan.sh`, use the user's returned choice as the same explicit
consent boundary, keep the plan at its durable `.mentor/` path, and report that no
host-level gate or lifecycle sidecar was changed. Do not claim an enforced release that
did not occur.

On **Proceed**, run:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/approve-plan.sh"
```

It validates the plan (a non-empty `.md` newer than the marker it resolves — this
worktree's `.planning.<wt-id>`, or the legacy repo-global `.planning` when running
in legacy_mode), deletes that marker — the gate OPENS for this worktree — and writes
the session's **run marker** `.mentor/.run-<session_id>` (`slug=` + `started=`), which
the `plan-continue.sh` Stop hook reads to keep the run going. On failure it prints the
problem, keeps the gate closed, and exits non-zero: fix the plan (revise it per Step 4)
and re-ask. On success, run the plan per **After Proceed** below.

On **Deliver plan only**, run:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/approve-plan.sh" --deliver
```

Same validation + release, no run marker, then **follow the DELIVER-ONLY directive it
prints** — report where the plan lives and STOP. Do not implement in this session.

**A plan-quality ask in "Other"** ("review this plan", "is this plan any good", "grill
me more", "walk through more use-cases/scenarios", or similar) has no button.
Route it: invoke `Skill(skill="mentor:grilling")` scoped to the **drafted plan** (not
the original request) — interview against what's already written, not from scratch.
This never releases the gate by itself, so fold the answers into the plan per Step 4,
then ask the approval question again.

On **Keep planning** or a change request in **Other**, record the user's feedback as a decision-log row (`result: kept`).
Revise the same plan with a Rev line for the
revision that answers it, and ask again when ready; do not run `approve-plan.sh`.
This carries the feedback into the next revision (rationale:
`references/rationale.md` → **Plan-file continuity — early drafts, feedback, and tracked writes**).

**No repository root?** begin-plan reported the gate was NOT armed — skip
`approve-plan.sh` (it needs a repository root) and honor the user's choice
directly.

### After Proceed — run until the Goal check passes {#implement}

The approval was the human's one gate. From here the run drives the plan to its
Goal check without asking, and records every choice it makes in `## Decision log`
for review afterwards (AGENTS.md → Mentor core concept, rules 1–6).

Read the selected playbooks' optional **Run rules** before starting or resuming the
loop and follow them throughout; an absent slot means none. Attempt constraints
must govern the work as it runs, not just its final acceptance check.

```mermaid
stateDiagram-v2
  [*] --> building: Proceed, run marker written
  building --> grading: step built
  grading --> ticked: saved verdict, PASS row, record-write, tick
  grading --> building: FAIL, retry once
  grading --> replanning: FAIL twice
  replanning --> building: re-plan 1 per step, 3 per run
  replanning --> failed: limit hit
  building --> paused: always-pause item, or stop word
  paused --> building: human answers, resumed row
  ticked --> building: steps left
  ticked --> goal: all ticked
  goal --> deliver: verifier PASS on Goal check
  goal --> replanning: FAIL
  deliver --> done: deliverable handed over
  done --> [*]
  failed --> [*]
```

| Transition | State call (`plan-state.sh …`) | Run marker |
|---|---|---|
| Proceed | `approve-plan.sh` (no flag), then `set <slug> in_progress` | written by `approve-plan.sh` |
| paused | `set <slug> approved --note "paused: row N"` | kept |
| resumed | `set <slug> in_progress` | kept |
| failed | `set <slug> failed --note "<what broke>"` | removed |
| done | `set <slug> implemented` — only after the Goal-check PASS, the Done review, and delivery | removed |

Remove the marker with `rm -f "$mentor_dir/.run-<session_id>"`. While the plan's stored
state is `in_progress` and the marker exists, the Stop hook blocks a premature stop
and names the next step; `paused`, `failed`, and `done` all let the session end.

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <slug> in_progress            # run starts / resumes
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" record-write <slug>               # immediately after every plan.md write
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" tick <slug> <N>                   # after save verdict → PASS row → record-write
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <slug> approved --note "paused: row N"
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <slug> implemented            # Goal-check PASS + Done review + delivered
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"
```

**Keep a step's own body on `-` bullets.** The step counter cannot tell a numbered
sub-item from a step, and an inflated denominator strands a finished plan at
`in_progress` forever.

The ticks are the only step tracker mentor reads — don't mirror them into a separate
todo list as well. Missing a transition is survivable — state also derives from the `✅`
step ticks — but `failed` and `paused` cannot be derived from ticks.

**The loop, step by step:**

Apply Step 2's drift check before editing a plan that may have changed, and call
`bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" record-write <slug>`
immediately after every mentor write to `plan.md`, on every host; never call it merely
to clear a change notice. This keeps run-time log writes tracked without hiding
outside edits (rationale: `references/rationale.md` → **Plan-file continuity — early
drafts, feedback, and tracked writes**).

1. `set <slug> in_progress`. Build steps in order.
2. **Grade every step independently.** When a step looks done, dispatch one fresh
   verifier with the plan-level Goal: first, then the step's `Goal:` and `Done when:`
   per `references/verifier-contract.md`.
   Use the host's verifier role settings and wait for the returned block; save it
   verbatim to `verdicts/step-N.md`, overwriting the previous grade. On PASS, append
   decision `Step N graded`, evidence
   `verdicts/step-N.md · <grading> · <author>/<verifier> family`, result `PASS`; then run
   `plan-state.sh record-write <slug>` and `plan-state.sh tick <slug> <N>`.
   Follow the contract's grading and family headers, including the labelled
   `self-graded` fallback. This preserves the grade for resumed runs and keeps the
   builder from presenting its own judgment as independent. Tick per step, never in a
   batch, after its PASS row; tick now refuses new ticks without a saved PASS verdict.
3. **FAIL** → read `references/principles.md`, fix the `[GOAL]` gaps and re-grade once
   with a fresh verifier. A second FAIL → write down and test any shared premise
   before another fix, then **re-plan** that step: rewrite its approach (log a
   `review?: needed` row), at most once per step and three times per run.
   Testing the premise keeps the next fix tied to evidence. **A re-plan never weakens a
   `Done when:` or the Goal check** — the verifier reports a weakened check as a FAIL.
   Limit hit → `failed`.
4. **Every choice the plan does not cover** — a library, a file layout, a wording, a
   workaround — is triaged as in Step 3 (evidence first, then a decision-maker) and
   gets a row. It never becomes a question to the human; a reversible product call
   goes to a decision-maker, logged `review?: needed`.
   Fix a mid-run discovery only when the Goal check or the current step's Done when
   cannot pass without it; otherwise list it as a leftover in the Done review.
   This keeps the run on its approved goal instead of accumulating related work.
5. **Pause only for an always-pause item** — the constitution's list, the built-in
   default (constitution-authoring → "The autonomy contract"), or a picked playbook's
   extra items — or a stop word ("stop", "pause", "wait"). Write a `paused` row, set
   the paused state, write the **Done review** in `plan.md` (a pause ends this run),
   report the verdict line below with its one question underneath, and on the answer
   write `resumed` and continue.
6. When every step is ticked, dispatch the `## Verification` topics (one fresh
   verifier each), wait and save each returned block verbatim to `verdicts/topic-N.md`;
   write the **Done review** below, then dispatch the **Goal check** verifier with it,
   wait and save its block to `verdicts/goal.md` per the same contract. Saving each
   grade separately keeps failures visible on resume. A FAIL re-enters step 3's
   re-plan path for the step that owns the gap.
7. **Deliver.** Follow the single delivery owner chosen in Step 2, including the
   compatible secondary outputs recorded there. When the general flow owns delivery,
   hand the deliverable named in the Goal check to the human and point to the Done
   review in `plan.md`; otherwise follow that playbook's Deliver mode.
   For a released plan with no recorded owner, use its selected playbook's Deliver
   mode, or the general flow for `none`, so its approved delivery still works.
8. `set <slug> implemented`, remove the run marker, and report the verdict line below.
   After reporting, offer
   a retrospective in one line (`/mentor:retro` in Claude Code; on other hosts, ask for a
   retrospective of this session) to turn this session's lessons into skills — a
   non-blocking invitation so repeated steps become reusable without the human having to
   ask. Skip the offer when this plan's `## Playbook` resolves through the index to
   `retrospective` (including `playbook-retrospective`); a retro inviting its own retro
   is noise.

For every terminal report (`PASS`, `paused`, or `failed`), send one verdict line:

```text
<PASS|paused|failed> · <ticked>/<total> steps · <k> decisions need review · <m> leftovers · <plan path>
```

When `<m>` > 0, name each leftover on one short line under the verdict line; when 0,
add nothing.

Take the step counts from the last `plan-state.sh tick` output (it prints `N/M`); only
when no tick output is at hand, run `plan-state.sh query --slug <slug> --format tsv --fields
steps.ticked,steps.total` if the helper is available (otherwise count the plan's step
ticks). Count `k` from the flat decision log's `review?: needed` rows and `m` from the
Done review's leftovers. Keep the full Done review and grouped decision log in `plan.md`,
without pasting them into chat, so the file remains the review record — except what a
playbook's deliver mode puts in a PR body or its own hand-over question (see merging's
hand-over question).

Treat **a plateau is not a stop** as a run rule only while untried hypotheses remain;
pivot within the retry/attempt caps. The caps and the dead-end rule take precedence:
two identical failures in a row with no new evidence require a re-plan, never a third
identical attempt; report a genuine dead end as `failed`, never weaken the predicate.
This permits evidence-led progress without an unbounded loop.
(Why it runs on its own and what keeps that safe: `references/rationale.md` → **After
Proceed — why the run keeps going on its own**.)

**Hosts without a Stop hook or subagents** (Codex, or a disabled hook): the loop is a
prose rule — keep working through the steps in this turn until a terminal state is
reached — and verification runs serially in the main thread, labelled `self-graded` in
every PASS row.

#### The Done review {#done-review}

Every terminal transition — `done`, `paused`, `failed`, and the Stop hook's idle cap —
writes `## Done review` into `plan.md` (and into whatever a playbook's deliver mode hands
over); chat reports it with the verdict line above. Three parts, organised by the plan's use
case scenarios:

1. **Per scenario: expected vs observed, with evidence.** Text evidence (command
   output, logs, responses) goes inline as short excerpts. Screenshots and larger
   captures are saved under `.mentor/plans/<slug>/evidence/` and cited as
   `local: .mentor/plans/<slug>/evidence/<file>` (the folder is gitignored, so say
   so). Anything not capturable reads `evidence: not capturable on this host, verify
   by <command>`.
2. **Runbook, only when the deliverable needs steps after hand-over** (a migration, a
   flag flip, a deploy, a config or secret change): numbered steps under **Before**,
   **Hand-over**, **After**, and **Rollback** (a playbook may rename them). Otherwise
   one line: `Runbook: n/a, hand-over is self-contained`.
3. **Leftovers** in plain words — follow-ups, gaps, known-broken items. Fix a mid-run
   discovery only when the Goal check or the current step's Done when cannot pass
   without it; list everything else here so related work does not expand the run.
   Do not park or capture leftovers yourself; what happens to them is the user's call.

Under it, render the decision log **grouped by use case**, `review?: needed` rows first
within each group. The flat table stays canonical; this rendering is for the reader.

### Retracting an approval {#retract}

Sometimes an approval lands that the user did not intend — they pick an approving
option, then immediately say "no, that wasn't approved yet". Re-arming the gate is the
obvious half of the fix and the only half people remember, so state the rest here:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/begin-plan.sh"                                       # re-arm the gate
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <slug> draft --note "approval retracted"
```

**Confirm the re-arm actually took before telling the user it did.** `begin-plan.sh`
can now refuse outright — a live legacy repo-global `.planning` marker fail-closes
against every worktree, this one included:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" gate   # expect ARMED
```

Anything other than `ARMED` means `begin-plan.sh` printed a refusal above instead of
arming — read it and resolve that first (wait for the legacy marker's owning session,
or get the user's explicit authorization to remove it by hand). The plan is not
re-protected until `gate` reads exactly `ARMED`.

**Retracting from a different worktree than the one that drafted this plan needs
re-owning too.** The gate re-arms per-worktree regardless of who owns the plan, but
the plan's sidecar `owner` still points at whichever worktree last minted or `init`ed
it, and re-arming the gate here does not change that. Re-own it before the next
approval, the same as any cross-worktree resume:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" init <slug>   # re-owns to THIS worktree, last-init-wins
```

Skip this line only when you are certain this is the same worktree that drafted the
plan — `init` is otherwise harmless to run either way (idempotent, never lowers state).

The `set <slug> draft` line is not optional: **every** approval path — no-arg and
`--deliver` — promotes the sidecar to `approved` before exiting, while
`begin-plan.sh` touches only the marker. Re-arming alone therefore leaves a plan
recorded `approved` behind a closed gate, and later sessions read the sidecar.

Two things to tell the user as you do it: **the plan must be re-written before it can be
approved again** (the re-armed marker's fresh mtime makes `approve-plan.sh` refuse the
older `plan.md`; any real revision clears it), and **retraction is a pre-implementation
act** — if any step is already ticked, work has shipped, so surface that as a rollback
decision rather than writing a `draft` state the tick derivation will outrank anyway.
(Full mechanics: `references/rationale.md` → **Retracting an approval — why each of the
three steps is required**.)
