Overlay a mentor plan run loads when the requested goal is a retrospective of one
finished agent session. It rebuilds the session from disk, even after compaction,
and delivers local skill changes plus unapplied proposals. Planning owns the one
approval and the run; batch harvesting across sessions belongs to loom, and a
forward code-change goal belongs to the software-change playbook.

# Playbook — retrospective

Editing-only rationale — including what was ported from pstack and deliberately
altered — is in [retrospective/rationale.md](retrospective/rationale.md) →
**What was changed, and why**. Read it when editing or questioning a rule.

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Planning's general flow never names transcripts, lenses, or skill authoring. This
playbook is where those live. Planning loads it when the goal is a retrospective,
records `## Playbook: retrospective` plus a decision-log row, and reads the
five overlays below. Nothing here replaces a planning rule; each overlay fills a slot
the general flow leaves open. This playbook is **never co-loaded with
`software-change`** — a retro delivers local edits, it does not ship code.

## Planning entry

Natural-language retrospective requests and Claude Code's `/mentor:retro` facade
enter planning with the goal `retrospective of session <id>`. Planning reads this
reference through its index and owns the edit boundary, one approval, decision log,
independent verifier and Done review, so skill edits wait for the approved plan.

## The five overlays

### 1. Research directives (planning Step 2)

Build the evidence graph, then run the lenses, then synthesize. The reviewers are
read-only; the **parent** persists each returned output immediately under `evidence/`:

1. Follow [retrospective/evidence-graph.md](retrospective/evidence-graph.md) to write `evidence/manifest.json` and one
   digest per transcript. The session is rebuilt from disk, never from memory, because
   after compaction the parent's context holds only the latest summary.
2. Dispatch the three lenses — [retrospective/lens-judgment.md](retrospective/lens-judgment.md),
   [retrospective/lens-tooling.md](retrospective/lens-tooling.md), [retrospective/lens-divergent.md](retrospective/lens-divergent.md) — as native subagents,
   in parallel when the host has them, else serially in-thread and labelled
   `self-graded`. Each lens returns its output read-only; the parent writes that return
   verbatim to `evidence/lens-judgment.md` / `evidence/lens-tooling.md` /
   `evidence/lens-divergent.md` the moment it lands. On restart the parent skips any
   lens whose evidence file already exists.
3. Run [retrospective/synthesizer.md](retrospective/synthesizer.md); it returns the synthesis read-only and the parent
   writes it verbatim to `evidence/synthesis.md` (Coverage, Accepted, Rejected,
   Backlog, Leftovers), skipped on restart if that file already exists.

### 2. Definition of done (Goal check and `Done when:`)

Per Accepted row: the new or edited skill passes skill-creator's `quick_validate.py`;
its description triggers on the prompt that motivated the row; and when the destination
convention includes a symlink (e.g. `.claude/skills/<name>` plus a relative
`.codex/skills/<name>` link), that link is relative and resolves (checked with
`readlink` / `readlink -f`). An in-repo edit (`plugins/*/skills/`) or a destination
with no symlink has no symlink check. A row is not ticked until its own check passes.

### 3. Extra always-pause items (the run)

A union with the constitution's list — nothing here removes an item:
- Committing or pushing (this playbook delivers local edits only).

Lessons that contradict a plugin core concept, change the constitution, or change
another tool's config (e.g. agt roles) are never applied and never paused on — they go
to the Done review's Leftovers and the run continues.

### 4. Deliver mode (the run's deliver state)

Local edits only, then the Done review — never ship, never merge. Leftovers carry the
Backlog items, the constitution proposals, the core-concept proposals, and the other-tool
proposals the synthesizer sorted out. The run is `done` when the Accepted rows are
applied and graded and the Leftovers are reported.

### 5. Evidence kinds (the Done review)

Per Accepted row, prefer: `quick_validate.py` output; the trigger check on the
motivating prompt; `readlink` / `readlink -f` of each new skill's symlink, when its
destination has one; and the Coverage table in `evidence/synthesis.md` showing every node and
epoch `read`, `opaque` (with its `opaque_reason`), or `skipped` with a reason.

## Where outputs land

- **New skills follow the workspace's documented skill-storage convention** (its
  `CLAUDE.md` / `AGENTS.md`), e.g. `.claude/skills/<name>` plus a **relative**
  `.codex/skills/<name>` symlink pointing at it. With none documented, write
  `.claude/skills/<name>` on Claude Code. On Codex, or when a Codex copy is wanted, a
  project-skill path is not promised: report it as a Leftover with the path to verify.
- **Installed plugin skills are copied to the workspace and the copy is edited** —
  never edit a plugin cache in place.
- Inside this marketplace repo, edit `plugins/*/skills/` directly, under the repo gates.
