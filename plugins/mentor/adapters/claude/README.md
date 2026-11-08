# Claude Code adapter

Claude Code discovers the command facades in `commands/` and the lifecycle hooks in
`hooks/hooks.json`. Those surfaces add the enforced edit gate, context checks, the
`plan-continue.sh` Stop hook that keeps an approved run going until a terminal state,
plan-file tracking (the per-prompt plan pointer in `context-gate.sh`, `plan-reattach.sh`
SessionStart re-attachment, and automatic `plan_sha256` recording on Write/Edit in
`plan-open.sh`), verifier subagents, and hosted Artifact publishing on top
of the portable skills and `.mentor/` state contract.

Verifier scheduling, model, and effort come from the host's verifier role. The caller
waits for the returned verdict, then saves its block verbatim under the plan's
`verdicts/` directory per `skills/planning/references/verifier-contract.md`; before a
step tick, it saves `verdicts/step-N.md`, appends the PASS row, and records the plan write.
Prefer another model family (SHOULD), recording the actual author and verifier families
or `unknown`; retain the labelled `self-graded` fallback when delegation is unavailable.

## Shared run contract

Resolve every needed role through planning's
[Role resolution](../../skills/planning/SKILL.md#decision-maker), using an explicit
session mapping first and otherwise an agent's described purpose. Every brief opens
with the plan-level `Goal:`. The full run directive lives in
[After Proceed](../../skills/planning/SKILL.md#implement).

The step order is save `verdicts/step-N.md` → PASS row → `record-write` → tick.
A new tick makes a point-in-time read of the latest saved PASS. Released verdict
paths and optional headers remain readable, and historical ticks remain idempotent;
see the [verifier contract](../../skills/planning/references/verifier-contract.md).
For output reuse, follow the verifier contract's
[Evidence reuse](../../skills/planning/references/verifier-contract.md#evidence-reuse) section.

Read [principles](../../skills/planning/references/principles.md) at planning's named
decision points and selected playbooks' optional Run rules before starting or
resuming. Rationale is editing-only, read when editing or considering an override.
Without subagents, the same scope and evidence run serially with labelled self-grading.

The skills remain the source of workflow behavior. A Claude command should route to
its matching skill instead of duplicating that behavior here.

## Planning playbooks

Planning reads the [playbook index](../../skills/planning/references/playbooks.md)
and the references matching the requested plan deliverable:
[software-change](../../skills/planning/references/playbooks/software-change.md),
[retrospective](../../skills/planning/references/playbooks/retrospective.md),
[investigation](../../skills/planning/references/playbooks/investigation.md),
[hillclimb](../../skills/planning/references/playbooks/hillclimb.md) and
[prototype](../../skills/planning/references/playbooks/prototype.md).
Each fills the five required overlay slots; investigation, hillclimb and prototype
also supply optional Run rules. Each keeps its own Host portability fallback.
These are references within planning; Mentor still exposes
seven public skills and needs no new playbook command facade. Host tools provide
the read-only research, measurements or variant observations; unavailable tools
leave an explicit evidence gap under the selected reference's contract.

## Retrospective evidence

Host-specific lookup details for planning's
[retrospective reference](../../skills/planning/references/playbooks/retrospective.md). The playbook prose stays
host-neutral; these are the Claude Code facts the evidence graph relies on.

### Identity

- Native id variable: `CLAUDE_CODE_SESSION_ID`. Verify it against the transcript
  file's own `sessionId` field before trusting it — the file is the source of
  truth, the env var is only a hint.
- Resolution order: explicit session id/path argument → `CLAUDE_CODE_SESSION_ID`
  verified against `sessionId` → unique cwd + opening-prompt match → **partial**.
  Never pick the newest file.

### Store root and layout

- Root: `${CLAUDE_CONFIG_DIR:-~/.claude}`, overridden by `--claude-config`. An
  unavailable explicit root reports `partial`; it never falls back to the real
  store (this is also how fixtures run).
- Transcript path: `<root>/projects/<proj>/<sid>.jsonl`, where `<proj>` is the
  cwd with every `/` rewritten to `-` (e.g. `/tmp/retro-fixture-proj` →
  `-tmp-retro-fixture-proj`).
- Subagents: `<root>/projects/<proj>/<sid>/subagents/agent-<id>.jsonl` plus
  `agent-<id>.meta.json` (`agentType`, `description`, `toolUseId`, `spawnDepth`).
  Every subagent line carries `"agentId":"<id>","isSidechain":true` and the
  parent's `sessionId`.

### Resume chain and uuid dedupe

- A `--resume` writes a NEW `.jsonl` with a new `sessionId` whose first lines
  replay earlier events with the SAME `uuid`s. A trailer
  `{"type":"last-prompt","lastPrompt":…,"leafUuid":…,"sessionId":"<ORIGINAL sessionId>"}`
  links back to the original session.
- Follow the referenced `sessionId` to chain the files, then dedupe by `uuid`:
  every replayed event is counted once (tracked as `replayed_dropped` in the
  manifest), attributed to the resumed node.

### Compaction marker and summary

- Boundary: `{"type":"system","subtype":"compact_boundary","uuid",`
  `"logicalParentUuid":"<last pre-compaction uuid>",`
  `"compactMetadata":{"trigger":"auto"|"manual","preTokens":N}}`.
- Split epochs at each boundary. The compaction summary is the NEXT user
  message (its text begins "This session is being continued from a previous
  conversation… Summary:"); label it *summary*, not fresh user intent.

### Child linkage

- A subagent is linked to the spawning `tool_use` by `meta.json.toolUseId`
  (equal to the `Agent` tool_use `id` in the parent). Recurse into nested
  subagents the same way.
- An agt worker result appears in the parent as a `tool_result` whose text
  contains `[agt] DONE · success · … · job g-<id> · …`; follow it into the agt
  store (see `../delegate-stores.md`).

### Digest filter

Each transcript is reduced by one `jq` filter before any lens reads it: text up
to 4000 chars, tool calls as name + input up to 400 chars, results up to 300
chars, plus compaction markers and link ids. Tested on a real 1.92 MB transcript
→ 67 KB. Raw transcripts never enter the parent's context.

```jq
def clip(n): if type=="string" then .[0:n] else (tojson|.[0:n]) end;
if .type=="system" and .subtype=="compact_boundary" then {k:"compact",id:.uuid,trigger:.compactMetadata.trigger,pre:.compactMetadata.preTokens}
elif (.type=="user" or .type=="assistant") then (.message.role) as $r | .uuid as $u | (.message.content) as $c
  | if ($c|type)=="string" then {k:$r,id:$u,t:($c|clip(4000))}
    else $c[] | if .type=="text" then {k:$r,id:$u,t:(.text|clip(4000))}
      elif .type=="tool_use" then {k:"call",id:$u,call:.id,n:.name,i:(.input|clip(400))}
      elif .type=="tool_result" then {k:"result",id:$u,call:.tool_use_id,r:(.content|clip(300))}
      else empty end end
else empty end
```

The digest omits identity metadata, so the manifest builder reads `sessionId` and the
`last-prompt` trailer (`{"type":"last-prompt",…,"sessionId":"<original>"}`) directly from
the raw file's head and tail, not from the digest.

A digest run is a pass only when jq's **stderr is empty** — jq's exit status reflects only
its last input line, so a filter error on an earlier line exits 0 while silently dropping
that line. Check `jq … 2>err; [ ! -s err ]`, never the exit code alone.
