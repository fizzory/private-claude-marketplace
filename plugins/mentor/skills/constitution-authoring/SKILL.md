---
name: constitution-authoring
description: >
  Create, amend, or show this repo's mentor CONSTITUTION — a committed,
  semantic-versioned set of governing principles (declarative, testable rules) at
  .mentor/constitution.md that every /mentor:plan must verify against, plus the
  autonomy contract an approved run follows: the always-pause list, decision
  authority, and definition of done. Use this
  whenever the user wants to establish, change, or inspect project-wide
  planning/engineering principles or the "rules of the repo": e.g. "set up a
  constitution", "add/amend/remove a principle", "make every plan enforce X",
  "what principles govern this repo", "what may agents decide without me",
  "what should always stop a run". Standalone authoring flow — it never arms
  the plan gate and is not itself planning. NOT for writing a single plan (use
  /mentor:plan) or judging one plan's quality (/mentor:grill).
---

# mentor Constitution

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

A **constitution** is the supreme rulebook for how work is planned and built in a
repo: a short list of named principles, each declarative and testable, plus a
governance block that records how the document is versioned and amended. Once it
exists, its consumers resolve `constitution_path` and read this file live —
planning proves compliance in a **Constitution Check** section. The constitution never forces itself — a plan may deviate, but only with an explicit, justified
note (or by amending the constitution first).

It is committed to the repo at **`.mentor/constitution.md`** so the whole team
shares one rulebook — unlike plans, which are gitignored transient state.
A repo that already keeps its rulebook elsewhere (e.g. `docs/constitution.md`)
can instead **adopt it by reference** (Step 3a): `constitution_path` in
`.mentor/config.json` points at it, and every consumer (`plan` Step 0) resolves
that path and reads the real file live.

## The autonomy contract {#autonomy}

The constitution is also what lets a run proceed without the human (AGENTS.md →
Mentor core concept). After a plan is approved, the run stops only for items on
the **Always-pause list**, lets agents decide what **Decision authority** grants,
and proves completion with the **Definition of done**. Every constitution carries
these three sections (Step 5 template); a repo with none uses the defaults below.

**Built-in always-pause default** — used when no constitution exists, or its
Always-pause list is empty. These are the irreversible or outward-facing actions:

- Messages or posts to people outside the session (email, chat, comments, tickets)
- Publishing anything public, or sharing it beyond the user
- Deleting or overwriting data that has no copy
- Reading, writing, or moving secrets and credentials
- Spending money, or adding a paid or licence-changing dependency
- Deploys and production configuration changes

A playbook picked at runtime (planning Step 2) adds its own items on top — the
software playbook adds force-push, protected branches, and merging, for example.
The lists are a union: nothing removes an item (default or playbook) except a
line in the constitution's Always-pause list that names and removes it. That is
the only way to lift one, and `merging` reads such a line for merging as a
**merge grant**. A **deploy grant** is the deployment playbook's conditional form: it
names each item it lifts (the built-in deploy item and, when the rollout needs them,
release tags and deploy config, never CI secrets, and additive data migrations), lifts
them only for rollout phases that pass the safe-deploy check, and scopes them to named
services and environments — e.g. `- Deploys and production configuration changes;
release tags and deploy config (not CI secrets); additive data migrations — deploy
grant: lifted for deployment-playbook phases whose safe-deploy check passed, for the
actions each phase names. Scope: services api, web; environments staging, prod.` Write
it only when the user asks; never lift the whole item.
Decision authority covers reversible calls only.

**Mid-run product calls.** After approval, a reversible product call goes to a
decision-maker agent and is logged `review?: needed`; it never pauses. Always-pause
items still pause. Stop words ("stop", "pause", "wait") write a `paused` row and the
run pauses.

The flow: guard → load any existing constitution → collect/derive principles
(or adopt an external file by reference) → version & date → assemble
(sync-impact report + body) → confirm → write → report.

## Step 1 — Guard {#guard}

```bash
[ -d "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks" ] || { echo "ERROR: Mentor helper unavailable — set PLUGIN_ROOT (or use the Claude compatibility fallback) or use the documented artifact fallback" >&2; exit 1; }
git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$git_common" ]; then
  echo "NOT-A-REPO"
else
  repo_root="$(cd "$(dirname "$git_common")" && pwd)"
  echo "REPO_ROOT=$repo_root"
  # PLANNING-ACTIVE holds IFF this worktree's own gate is armed (the legacy
  # repo-global marker counts as this worktree's own). An ARMED_ELSEWHERE verdict
  # (only a SIBLING worktree's marker is live) must NOT count — otherwise
  # constitution work would deadlock repo-wide any time any worktree is mid-plan,
  # the exact disease the per-worktree gate exists to cure.
  if [ "$(bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" gate)" = "ARMED" ]; then
    echo "PLANNING-ACTIVE"
  else
    echo "PLANNING-IDLE"
  fi
  const_rel="$(jq -r '.constitution_path // empty' "$repo_root/.mentor/config.json" 2>/dev/null)"
  const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
  echo "CONSTITUTION=$const_path"
  [ -n "$const_rel" ] && echo "ADOPTED-BY-REFERENCE"
  [ -f "$const_path" ] && echo "EXISTS" || echo "NEW"
  echo "TODAY=$(date +%F)"
fi
```

- **`NOT-A-REPO`** → the constitution is per-repo and committed. Tell the user to
  `cd` into a git repo and stop.
- **`PLANNING-ACTIVE`** → this worktree's plan gate (own marker or the legacy
  repo-global one) is armed. Split on the target. The default,
  `.mentor/constitution.md`, is **exempt** from the plan edit gate
  (`plan-gate.sh`'s `.mentor/` exemption): say in one line that a plan is
  mid-flight — principles written now and a plan drafted against the old ones can
  talk past each other — and continue. An **adopt-by-reference** target from
  Step 3a that lives outside `.mentor/` (e.g. `docs/constitution.md`) is a
  different matter: the gate blocks that write for real, so stop and tell the user
  to approve or finish the current plan first.
- Otherwise capture `REPO_ROOT`, whether the file `EXISTS` or is `NEW`, and
  `TODAY` for the dates below.

## Step 2 — Load the existing constitution {#load}

If `EXISTS`, `Read` the resolved `CONSTITUTION` file and note its current
**version**, **ratification date**, and the **set of principles** (names +
rules). This is an **amendment**; the ratification date is preserved. If `NEW`,
this is the first **ratification** — version starts at `1.0.0` and the
ratification date is `TODAY`. When the guard printed `ADOPTED-BY-REFERENCE`,
the constitution is an external file the repo already owns: amendments edit
THAT file in place, and only when the user asks — never rewrite an adopted
document into mentor's template uninvited.

**Read-only shortcut:** if the user only wants to *see* the current constitution
(e.g. "show me our principles", "what governs this repo") and requested no change,
surface it verbatim and stop here — do not bump the version or rewrite. The rest
of this flow is for creating or amending.

## Step 3 — Collect / derive the principles {#principles}

Principles come from, in priority order: (1) what the user passed to
`/mentor:constitution`; (2) the existing constitution (for an amendment); (3) the
repo's own conventions when the user asked you to bootstrap one — skim
`README`, `CLAUDE.md`/`AGENTS.md`, `CONTRIBUTING`, any tooling config, and obvious
patterns to propose a first draft. **Respect a user-specified principle count** —
do not pad to a fixed number.

A good principle is:

- **Named** — a short noun phrase (e.g. "Sources cited", "One owner per deliverable", "No secrets in the repo").
- **Declarative & testable** — written in MUST / MUST NOT / SHOULD language, so a
  reviewer can objectively check a plan against it. This is what makes the
  downstream Constitution Check meaningful rather than a rubber stamp. Avoid
  aspirational mush ("do good work"); prefer "Every figure in a report cites
  its source."
- **Justified** — one `Rationale:` line saying why it exists.

Keep the whole document short and high-signal (typically 3–7 principles). Add an
optional extra section (Constraints / Security / Workflow) only if the user has
rules that are not principles.

Always fill the three autonomy sections (#autonomy). When bootstrapping, propose
the built-in always-pause default plus anything the repo's own docs mark as
dangerous, a Decision authority drawn from the repo's conventions, and a
Definition of done drawn from its check commands or review norms.

### Step 3a — Adopt an existing external constitution (by reference) {#adopt}

When the user points at a governing doc the repo **already has** ("use
`docs/constitution.md`", "this existing constitution …"), do **not** duplicate
or re-author its content. Adopt it by reference instead:

1. Confirm the file exists and skim it so you can summarize what was adopted.
2. Write only the pointer into `.mentor/config.json` (merge-json safely —
   backup, edit with `jq`, validate, restore on failure):

   ```bash
   # Re-derive exactly as Step 1 does (the MAIN checkout, via git-common-dir): each
   # fenced block is its own Bash call, and a linked worktree's --show-toplevel would
   # write a config.json that planning never reads.
   repo_root="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
   cfg="$repo_root/.mentor/config.json"
   mkdir -p "$repo_root/.mentor"   # bare on purpose: constitution.md is committed, not private
   [ -f "$cfg" ] || echo '{}' > "$cfg"
   cp "$cfg" "$cfg.bak"
   jq --arg p "docs/constitution.md" '.constitution_path = $p' "$cfg" > "$cfg.tmp" \
     && jq empty "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && rm -f "$cfg.bak" \
     || { mv "$cfg.bak" "$cfg"; rm -f "$cfg.tmp"; echo "config write FAILED — restored"; }
   ```

3. Report: the adopted path, that every `/mentor:plan` Constitution Check will
   now `Read` that file live (it resolves `constitution_path`), and commit guidance for `.mentor/config.json` (it is a
   committed file per `.mentor/.gitignore`).
4. **Skip Steps 4–7 entirely** — no version bump, no template, no
   `.mentor/constitution.md` is written. The external file stays exactly as the
   repo owns it.

## Step 4 — Version & dates {#version}

Decide the new version from the nature of the change and state the reason:

| Bump | When |
|---|---|
| **MAJOR** (`x`.0.0) | A principle is removed or redefined backward-incompatibly (plans that were compliant might no longer be). |
| **MINOR** (`x.y`.0) | A new principle is added, or existing guidance is materially expanded. |
| **PATCH** (`x.y.z`) | Wording/typo/clarification only — no change to what a plan must do. |

First ratification is always `1.0.0`. `Ratified` = the original adoption date
(preserved on amendment); `Last amended` = `TODAY`.

**Amending an adopted external constitution** (Step 2's `ADOPTED-BY-REFERENCE`):
that document belongs to the repo, not to mentor, so keep the shape it already
has. Version and date it only by the convention it already carries — if it has
none, do not impose one. Step 5's template does not apply either: edit the
requested principle into the file in place and describe the change in Step 7's
report rather than prepending a sync-impact header.

## Step 5 — Assemble the document {#assemble}

Fill this template. **Leave no unexplained `[BRACKET]` tokens** — every
placeholder is either replaced or dropped. Prepend the sync-impact report as an
HTML comment. For `<Project Name>`, use the project's own name if it is obvious
(a `package.json` `name`, a README H1, the repo remote) — otherwise fall back to
the `REPO_ROOT` basename.

````markdown
<!--
SYNC IMPACT REPORT
Version:  <old> → <new>   (<MAJOR|MINOR|PATCH>: <one-line reason>)
Ratified: <YYYY-MM-DD>    Last amended: <YYYY-MM-DD>
Principles added:    <names, or none>
Principles modified: <names, or none>
Principles removed:  <names, or none>
Consumed by: mentor `planning` skill (Constitution Check, triage, and the run).
  It reads this file LIVE at plan time — there are no generated templates to
  propagate to, so no downstream files need editing.
Deferred TODOs: <anything intentionally left open, or none>
-->

# <Project Name> Constitution

## Principles

### I. <Principle name>
<One or more declarative rules in MUST / SHOULD language — testable, not aspirational.>
_Rationale:_ <why this principle exists.>

### II. <Principle name>
<…>
_Rationale:_ <…>

<!-- add as many principles as the project needs; do not pad to a fixed count -->

## <Optional extra section — Constraints / Security / Workflow>
<Only include if the user has rules that are not principles; otherwise delete this heading.>

## Always-pause list
<!-- The only actions that stop an approved run and wait for the human. -->
- <Start from the built-in default list; add or name-and-remove items for this repo.>

## Decision authority
<!-- What agents may decide without the human, and who decides. -->
- <e.g. "Naming, file layout, test depth, and dependency choice within the existing
  stack are decided by a decision-maker agent and logged.">

## Definition of done
<!-- The default shape of a plan's Goal check and each step's `Done when:`. -->
- <e.g. "The repo's check command passes" / "Every claim in a report cites a source".>

## Governance

This constitution supersedes ad-hoc practice for planning and implementation in
this repo. Every `/mentor:plan` MUST include a **Constitution Check** that
verifies the plan against these principles; any deviation MUST be justified
explicitly in the plan, or the constitution amended first via
`/mentor:constitution`.

**Amendment procedure:** amendments are made through `/mentor:constitution`, which
bumps the version semantically — MAJOR (remove/redefine a principle),
MINOR (add a principle or materially expand guidance), PATCH (clarify wording).

**Version:** <X.Y.Z> · **Ratified:** <YYYY-MM-DD> · **Last amended:** <YYYY-MM-DD>
````

## Step 6 — Confirm {#confirm}

Surface the **complete assembled document** in your message (verbatim markdown, no
wrapper commentary) so the user reads exactly what will be committed — **every question
stands on its own**, and the user answers from the question screen alone, never sent to a
file, a principle number, or an earlier turn to learn what the question means. Where an
option turns on a specific principle, quote that principle's words in the option rather
than citing it by number. Then ask via `AskUserQuestion` — header "Constitution",
single-select:

- **"Ratify & write"** (first time) / **"Save amendment"** (existing) —
  *"Write `<the resolved constitution path>` at v<new>."* Name the real file, so an
  adopted external document is never mistaken for `.mentor/constitution.md`; drop
  the version clause when that document carries no version.
- **"Keep editing"** — *"Adjust principles/wording; re-surface and ask again."*
- **"Cancel"** — *"Do not write anything."*

On **Keep editing**, revise and re-surface. On **Cancel**, stop without writing.

## Step 7 — Write & report {#write}

**Only a returned answer approves.** Step 6's `AskUserQuestion` must have come back
with **Ratify & write** / **Save amendment** before anything is written. If that
question was interrupted, never asked, or the user only claimed approval in prose
("looks good", "go ahead"), ask it now — prose selects no option. Surfacing the
document and reasoning your way to a conclusion is not consent: this is a committed,
team-shared rulebook, and Step 6 is the only check on the write — `plan-gate.sh`
exempts the `.mentor/` tree, so an armed plan gate never stands in for that consent.

On approval, create the dir and write the file with `Write` (it is in-repo, but
`.mentor/` is exempt from the plan gate, so the write is allowed even mid-plan):

```bash
# Re-derive exactly as Step 1 does (the MAIN checkout, via git-common-dir): each
# fenced block is its own Bash call, and planning reads the main checkout's .mentor/.
repo_root="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
mkdir -p "$repo_root/.mentor"   # bare on purpose: constitution.md is committed, not private
```

Write the assembled document to the **resolved** constitution file —
`$REPO_ROOT/.mentor/constitution.md`, or the adopted external document when Step 1
printed `ADOPTED-BY-REFERENCE`. Then report:

- The path and the new version (e.g. `v1.0.0 ratified` / `v1.2.0 — MINOR`).
- A one-line summary of what changed (from the sync-impact report).
- **Sharing guidance** — it is a shared artifact every future `/mentor:plan` in this
  repo reads, so suggest sharing it the way this repo lands changes. A copy left only
  on this machine diverges from what the next session reads. Do not share it for the
  user unless they ask.
- Remind that from now on planning will include a Constitution Check against it,
  and that an approved run pauses only on its Always-pause list.

### Do NOT
- Do **not** run `begin-plan.sh` or arm the plan gate — this is not a plan session.
- Do **not** write the constitution anywhere but the **resolved** constitution file:
  `$REPO_ROOT/.mentor/constitution.md`, or the adopted external document when Step 1
  printed `ADOPTED-BY-REFERENCE` (amend that one in place — never create a second
  constitution beside it). The adopt-by-reference branch (Step 3a) writes only the
  `constitution_path` key into `.mentor/config.json`.
- Do **not** invent principles the user did not ask for and cannot be grounded in
  the repo — when unsure, propose and let Step 6 confirm.
- Do **not** leave placeholder brackets or a stale version/date in the written file.
