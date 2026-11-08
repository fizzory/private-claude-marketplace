# Evidence graph — the portable contract

The retro never reviews from memory. After several compactions the parent's own
context holds only the latest summary, and most of the work lives in other
transcripts (resumed files, subagents, delegated workers). So the parent rebuilds
the session from disk **first**, into one `manifest.json` plus one digest per
transcript, before any lens runs.

This file is host-neutral: it names no store paths and no host field names. Those
live in the adapters — point every host lookup at them:

- Claude Code layout, id variable, resume chain, compaction marker, child linkage,
  the jq filter → [claude/README.md](../../../../../adapters/claude/README.md) → **## Retrospective evidence**.
- Codex layout and the same six facts → [codex/README.md](../../../../../adapters/codex/README.md) → **## Retrospective evidence**.
- agt worker mapping (claude / codex / kiro / agy) and the opaque rule →
  [delegate-stores.md](../../../../../adapters/delegate-stores.md).

## Source roots

Explicit source-root arguments win over the environment. When an explicit root is
unavailable the outcome is one consistent rule for every argument — `--claude-config`,
`--codex-home`, and `--agt-home` alike: coverage is `partial` and the graph never falls
back to the real stores, so a fixture run can never silently read a developer's live
transcripts:

| Argument | Overrides | When the explicit root is unavailable |
|---|---|---|
| `--claude-config` | `CLAUDE_CONFIG_DIR` | coverage `partial`, no fallback to the real store |
| `--codex-home` | `CODEX_HOME` | coverage `partial`, no fallback to the real store |
| `--agt-home` | `AGT_HOME` | coverage `partial`, no fallback to the real store (agt nodes are skipped with a reason) |

Read a host's transcripts only from its resolved root. Never guess a store location
from the model name or the newest file on disk.

## Build order (each stage persists before the next)

Build the graph once, in this order, writing each output under
`.mentor/plans/<retro-slug>/evidence/` as it is produced. On restart, read
`evidence/` first and run only the stages whose output is **missing** — that is how a
retro that is itself compacted mid-run resumes without re-running the lenses.

1. **Freeze the cutoff.** An explicit `--until <event id>` argument wins: it fixes
   the cutoff at that event in the root. Otherwise the cutoff is the root's last
   event at retro start (the last event id on Claude Code, the last item ordinal on
   Codex). No event after the cutoff is evidence — the retro reviews the session up
   to the cutoff, not the retro's own later turns. If an `--until` id is **not found**
   in the root, coverage is `partial` with the reason recorded (`--until <id> not
   found in root`); never silently fall back to the last-event cutoff.

2. **Resolve identity**, in strict order, never newest-file:
   1. an explicit id or path argument;
   2. the host's native session id (Claude Code `sessionId`, Codex `session_meta.id`)
      **verified against the transcript file's own metadata** — a bare env var that
      does not match the file is not trusted;
   3. a unique match on cwd **and** the opening-prompt text;
   4. otherwise `method: partial` with the reason recorded. Two live sessions in one
      project with no id given resolve by 3 or fall to `partial`; they never pick the
      most recently modified file.

3. **Chain resumes and dedupe.** A resumed session writes a new transcript that
   replays the old one. Follow the referenced prior session, then dedupe every event
   by its event id so a replayed turn is counted once. Record `replayed_dropped` per
   node.

4. **Split epochs at compaction.** A compaction boundary ends one epoch and starts
   the next. Keep each compaction summary and label it `summary` — the summary is
   *not* the evidence, the raw turns of each epoch are; the summary only marks the
   seam and records what the agent carried forward. `ends_with` is
   `compaction|cutoff|end`; `trigger` is `auto|manual|null`.

5. **Walk the delegation tree, recursively.** Each delegate (Claude subagent, Codex
   child thread, agt worker) is a node whose `parent` points at the node that spawned
   it; a delegate that itself delegates adds its own children. Link by the host's
   documented mechanism (see the adapters). An optional store that is absent skips its
   nodes with a reason rather than failing the graph.

6. **Mark opaque nodes.** A delegate with no readable transcript (a kiro or agy agt
   worker has only a brief and a result, no linked session) is `opaque: true` with an
   `opaque_reason`. For an opaque node record only its brief and its result — never
   invent the steps it took. Lenses may reason about *what it was asked and returned*,
   never about *how it did it*.

7. **Digest each transcript.** Reduce every readable transcript with one jq filter
   (text truncated, tool calls as name + truncated input, results truncated, plus
   compaction markers and link ids) to `evidence/digest/<node-id>.jsonl`. The raw
   transcript never enters the parent's context. The exact per-host filter lives in
   the adapters.

8. **Lenses read lean, re-open before citing.** A lens reads the manifest and the
   **root** digest, and greps the delegate digests on demand. Before quoting anything
   that a digest truncated, it re-opens the raw span at `source_path` so no citation
   rests on a cut-off string.

A plan dir with no writable `.mentor/` is labelled `partial` and non-resumable: the
graph cannot persist, so a later restart cannot know which stages already ran.

## Manifest schema

The parent writes `evidence/manifest.json` to exactly this schema. Do not rename these
fields.

```json
{
  "cutoff": {"node": "<root node id>", "event": "<last event id or item ordinal at retro start>"},
  "identity": {"host": "claude|codex", "method": "explicit|native|prompt-match|partial", "detail": "<why>"},
  "coverage": "complete|partial",
  "nodes": [{
    "id": "<stable id>", "kind": "root|resume|subagent|codex-child|agt-worker",
    "parent": "<node id or null>", "host": "claude|codex|kiro|agy|unknown",
    "role": "<agentType / agt role / null>", "source_path": "<transcript path or null>",
    "digest_path": "evidence/digest/<id>.jsonl or null",
    "brief": "<first ~300 chars of the delegate's brief or null>", "outcome": "<first ~300 chars of its result or null>",
    "opaque": false, "opaque_reason": null,
    "epochs": [{"n": 1, "from": "<event id>", "to": "<event id>", "ends_with": "compaction|cutoff|end", "trigger": "auto|manual|null"}],
    "events": 0, "replayed_dropped": 0
  }],
  "skipped": [{"node": "<id>", "reason": "<why>"}]
}
```

Field notes:
- `coverage` is `complete` only when every expected node resolved to a readable
  transcript or a deliberately `opaque` node; any unavailable explicit root, missing
  store, or `partial` identity makes it `partial`.
- `skipped` records every node that could not be built and why (unavailable store,
  unreadable file), so a lens can list what it did not read rather than pretend
  completeness.
- `opaque: true` requires `opaque_reason` and null `digest_path`; `brief` and `outcome`
  are the only content an opaque node carries.
