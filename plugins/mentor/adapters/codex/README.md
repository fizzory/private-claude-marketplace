# Codex adapter

Mentor runs guidance-first in Codex through the shared `skills/` directory and the
durable `.mentor/` files. Codex hooks are deliberately disabled in the portable
manifest: hook trust is optional, the current Claude event set is not portable, and
the edit gate must not be advertised as fail-closed until Codex-specific payload and
coverage fixtures prove it.

When a host-native UI action is unavailable, use the portable fallback declared by
the skill: ordinary conversation for questions, the current task for serial work,
and local HTML/Markdown files for review pages.

**The run loop without hooks.** Follow planning → **After Proceed** in
[`skills/planning/SKILL.md`](../../skills/planning/SKILL.md#implement), including its
**Hosts without a Stop hook or subagents** fallback.

## Shared run contract

Resolve needed roles through planning's
[Role resolution](../../skills/planning/SKILL.md#decision-maker): explicit session
mapping first, then an installed agent by described purpose, then a general-purpose
agent or serial work when delegation is unavailable. Every brief opens with the
plan-level `Goal:`; scheduling and model choice belong to the host role.

The step order is save `verdicts/step-N.md` → PASS row → `record-write` → tick.
A new tick makes a point-in-time read of the latest saved PASS. A saved
`Grading: self-graded` PASS can tick when subagents are unavailable; label it and
retain the same evidence instead of claiming independence. Released verdict paths,
optional headers and historical tick idempotency remain supported; see the
[verifier contract](../../skills/planning/references/verifier-contract.md).
For output reuse, follow the verifier contract's
[Evidence reuse](../../skills/planning/references/verifier-contract.md#evidence-reuse) section.

Read [principles](../../skills/planning/references/principles.md) at planning's named
decision points and selected playbooks' optional Run rules before starting or
resuming. Rationale is editing-only, read when editing or considering an override.

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
seven public skills and needs no slash-command facade or hooks to read them. Use
available read-only research, measurement and observation tools, with serial work
and labelled self-grading when delegation is unavailable; report an evidence gap
when a required measurement or surface cannot be observed.

## Retrospective evidence

Host-specific lookup details for planning's
[retrospective reference](../../skills/planning/references/playbooks/retrospective.md). The playbook prose stays
host-neutral; these are the Codex facts the evidence graph relies on.

### Identity

- Native id variable: `CODEX_THREAD_ID` (verified exported in Codex 0.164.0).
  Verify it against the rollout's `session_meta.payload.id` before trusting it.
- Resolution order: explicit session id/path argument → `CODEX_THREAD_ID` verified
  against `session_meta.id` → unique cwd + opening-prompt match → **partial**.
  Never pick the newest file.

### Store root and layout

- Root: `${CODEX_HOME:-~/.codex}`, overridden by `--codex-home`. An unavailable
  explicit root reports `partial`; it never falls back to the real store.
- Rollout path:
  `<root>/sessions/YYYY/MM/DD/rollout-<YYYY-MM-DDTHH-MM-SS>-<thread_id>.jsonl`.
- First line: `{"type":"session_meta","payload":{"id":"<thread_id>","cwd",`
  `"cli_version","source"}}`. Items follow as
  `{"type":"response_item","payload":{…}}` where the payload is a `message`
  (`role`, `content[].input_text|output_text`), a `function_call` (`name`,
  `arguments` as a JSON string, `call_id`), or a `function_call_output`
  (`call_id`, `output`).

### Same-file continuation and double-uuid forks

- Unlike Claude, Codex continues the SAME rollout file across turns; there is no
  separate resume file to chain. Events are addressed by their 1-based item
  ordinal within the rollout.
- A fork is written as a new rollout whose file name carries a double thread id
  (`…-<thread_id>-<thread_id>.jsonl`); treat the forked file as a distinct node
  and dedupe shared leading items by ordinal + payload identity.

### Compaction marker and summary

- Boundary: `{"type":"compacted","payload":{"message":"<summary>",`
  `"replacement_history":[]}}`. Split epochs at each `compacted` item.
- The summary is `payload.message` (and `payload.replacement_history` when
  present); label it *summary*. Codex `compacted` items carry no
  `auto`/`manual` trigger field — record `trigger: null`.

### Child linkage

- A child sub-agent rollout's `session_meta.payload` adds
  `"parent_thread_id":"<parent id>","thread_source":"subagent",`
  `"source":{"subagent":"<role>"}`. Link a child to its parent by
  `parent_thread_id == parent session_meta.id`; take its role from
  `source.subagent`. Recurse the same way.
- The spawning call is the parent's `function_call` with `name:"spawn_agent"`
  (its `call_id` ties the child back to the exact parent turn). An agt worker is
  dispatched from a `subagent_start` MCP call; follow it into the agt store (see
  `../delegate-stores.md`).

### Digest filter

Equivalent reduction for Codex items (text up to 4000 chars, calls as name +
arguments up to 400 chars, outputs up to 300 chars, plus compaction markers and
link ids). Raw rollouts never enter the parent's context.

```jq
def clip(n): if type=="string" then .[0:n] else (tojson|.[0:n]) end;
if .type=="compacted" then {k:"compact",t:(.payload.message|clip(300))}
elif .type=="session_meta" then {k:"meta",id:.payload.id,parent:(.payload.parent_thread_id // null),role:(.payload.source.subagent? // null)}
elif .type=="response_item" then (.payload) as $p
  | if $p.type=="message" then {k:$p.role,t:([$p.content[]?|(.text // "")]|join(" ")|clip(4000))}
    elif $p.type=="function_call" then {k:"call",call:$p.call_id,n:$p.name,i:($p.arguments|clip(400))}
    elif $p.type=="function_call_output" then {k:"result",call:$p.call_id,r:($p.output|clip(300))}
    else empty end
else empty end
```

The manifest builder reads `session_meta.id` (and `parent_thread_id`, `source.subagent`)
directly from the raw rollout's first line, not from the digest, so identity never rests
on a truncated field.

A digest run is a pass only when jq's **stderr is empty** — jq's exit status reflects only
its last input line, so a filter error on an earlier line (for example a rollout whose
`source` is a plain string) exits 0 while silently dropping that line. Check
`jq … 2>err; [ ! -s err ]`, never the exit code alone.
