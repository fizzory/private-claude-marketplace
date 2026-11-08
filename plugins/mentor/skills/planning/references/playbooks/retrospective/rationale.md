# Rationale — retrospective

Narrative home for this playbook, per [the mentor README](../../../../../README.md) → "Where a new rule
goes". The imperative rules live in [the retrospective playbook](../retrospective.md) and its reference files; this file
records where they came from and why, read only when someone is about to change them.

## Lineage: Cursor's pstack `/reflect`

The retro adopts the idea behind Cursor's pstack plugin `/reflect`
(https://github.com/cursor/plugins/tree/main/pstack, `skills/reflect`): three
reviewers run over one session, a synthesizer sorts their findings into
Accepted / Rejected / Backlog, and approved rows become skill edits or new skills. The
three lens prompts and the synthesizer in this directory are ported from pstack's
`skills/reflect/references/{judgment-reviewer,tooling-reviewer,divergent-reviewer,synthesizer}.md`.

## What was kept

- The three-lens split (judgment / tooling / divergent) and a separate synthesizer, so
  no reviewer grades its own findings.
- Transcript-is-untrusted-data: quoted content can be prompt-injection, MCP lookups are
  confined to context the session references.
- Route findings only to skills the session used or should have triggered; drop drifting
  details (SHAs, paths, versions, byte counts); numbered-list output.
- pstack's eight synthesizer filters, including the structural-mechanism check that sends
  enforceable rules to Backlog rather than skill prose — except where mentor's added ninth
  filter overrides it (see **Lost corrections beat the structural filter**).

## What was changed, and why

- **Cursor model names and store paths removed.** Every Cursor-specific model name and
  Cursor store path from the pstack originals is gone — this plugin is host-neutral and
  runs on Claude Code and Codex. Host store facts live in the adapters, not in these
  prompts.
- **Inputs are the evidence graph, not a live transcript.** pstack reads the active
  transcript directly. After several compactions that transcript holds only the latest
  summary and the real work lives in delegate transcripts, so the lenses instead read
  `evidence/manifest.json` + the root digest, grep delegate digests on demand, and
  re-open raw spans before citing truncated text. See [evidence-graph.md](evidence-graph.md).
- **The repeatable bar for a new skill.** pstack treats a new skill as rare. Here a new
  skill is a normal output when a procedure was done 2+ times, the user said they will
  redo it, or an existing skill should have covered it (then prefer editing or tuning
  that skill's description). This matches the core ask: turn repeated manual steps into
  skills.
- **The `## Orchestration and continuity` section**, added to each lens and active only
  when the manifest has ≥1 delegate node or ≥1 compaction. pstack's `/reflect` assumes a
  single flat session. Mentor's hard requirement is a compacted, delegating orchestrator
  (Claude Code or Codex) with subagents and agt workers, so each lens gained a
  conditional section: judgment grades brief completeness, redone work, and corrections
  lost across a compaction (citing both epochs); tooling grades provider/role capability
  and routing failures and the limits of opaque nodes; divergent proposes alternative
  orchestration.
- **Synthesizer coverage check + Destination column + Leftovers.** The coverage check
  confirms every node and epoch was read, marked `opaque` (brief and outcome only), or
  skipped with a reason — the retro must not
  claim completeness over a session it only partly reconstructed. The `Destination`
  column names exactly where each Accepted change lands. Leftovers routes the proposals
  the retro reports but never applies: constitution changes, lessons that contradict a
  plugin core concept, and other-tool config (agt roles).

- **pstack's worked-example lists were shortened or dropped.** pstack's tooling
  reviewer carried an "Examples of the pattern" list and its synthesizer carried Drop/
  Keep example lists; those were trimmed here to keep each prompt lean and host-neutral,
  since the concrete examples were Cursor-specific and drifted fast. The filters and
  the three finding shapes carry the judgment the examples used to illustrate; restore
  two or three short, host-neutral examples in a prompt only where they sharpen a
  judgment call that the rule alone leaves ambiguous.

### Lost corrections beat the structural filter

pstack's structural-mechanism filter routes anything a mechanism (lint, hook, check)
could enforce to the backlog, on the theory that skill prose is for what mechanisms
cannot enforce. But mentor's retro has to catch corrections lost across a compaction —
the user's explicit requirement for orchestrated, multi-compaction sessions, where the
user corrects the agent in one epoch and a later compaction drops the rule from context
so the agent repeats the mistake. A `git add -A` rule is exactly the kind of thing a
mechanism could enforce, so the structural filter would route it to Backlog. The retro
never applies Backlog items — it only reports them — so that routing would leave the
very failure a compacted-session retro exists to fix permanently unfixed. The carrier
is therefore an Accepted skill edit (or a new skill) into a home that reloads after
compaction, citing both epochs, and the enforcing mechanism still goes to Backlog as
well, never instead.

## Why a playbook, not a new workflow

Shaping the retro as an indexed reference loaded by planning (like
[software-change](../software-change.md)) makes it inherit the edit gate, the one approval, the
decision log, the independent verifier, and the Done review with no new hooks, scripts,
or state tokens — the charter in [the mentor README](../../../../../README.md) → "What mentor is — and is
not" forbids that machinery. The decision log behind these choices lived in the local,
gitignored plan that built v6.1.0; this file is its durable record.

## Boundary with loom

The NOT-for line in planning's description splits mentor retro from loom's batch harvesting:
mentor retro covers **one** session, interactively, with one approval, on both hosts,
and reads the plan and decision log. loom covers batches across sessions, uses a ledger,
runs headless, and is Claude Code only. Mentor installs without loom.
