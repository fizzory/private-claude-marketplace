# Delegate stores (optional)

Host-neutral mapping for delegate work the retro's evidence graph may find.
These stores are **optional**: the retro detects them, maps what it can, and
marks the rest opaque. A delegate store is **never a hard dependency** — the
playbook runs without any of them. When a detected delegate's store is absent or
unreadable, that node goes under the manifest's `skipped` with the reason and
coverage is `partial` (this matches
[the evidence graph](../skills/planning/references/playbooks/retrospective/evidence-graph.md)); it never fails the run.

## The rule: detect → map → or mark opaque

1. **Detect** an agt delegate from the orchestrator transcript (a `tool_result`
   carrying `[agt] DONE · … · job g-<id> · …` on Claude, or a `subagent_start` MCP
   call on Codex). Codex's native `spawn_agent` children are **not** agt jobs — they
   are read from their own rollouts, linked by `session_meta.parent_thread_id` (see
   `adapters/codex/README.md` "Retrospective evidence"), not from the agt store.
2. **Map** it to its transcript when the store records a session link, and add a
   node with `source_path`/`digest_path`.
3. **Or mark opaque** when no transcript is linked: the node still exists with
   `opaque: true` and an `opaque_reason`, carrying only `brief` (from `spec.json`)
   and `outcome` (from `result.md`, noting a non-empty `stderr-*.log`). Never invent
   worker steps.

## agt (agents-router)

- Store root: `${AGT_HOME:-~/.agents-router}`. agt's own `--home` flag sets
  `AGT_HOME`; the retro's explicit `--agt-home` overrides both. An unavailable
  explicit root lowers coverage; it never falls back to the real store.
- Resolution chain, starting from `job g-<id>` seen in the orchestrator:

  ```text
  job g-<id>
    → state/groups/g-<id>.json        # {role, cwd, jobs:[{job_id, provider}]}
      → jobs/<job_id>/
          ├── spec.json               # {prompt, runtime, cwd, parent:{host, config_dir}}
          ├── status.json             # {runtime, account, cwd,
          │                           #  attempts:[{home, session_id}]}
          ├── result.md               # the worker's reported outcome (the brief's answer)
          └── stderr-*.log            # captured stderr, if any
  ```

- **Worker transcript by runtime**, from `status.json` `attempts[].home` +
  `session_id`:
  - **claude worker** → `<home>/projects/<cwd-with-/→->/<session_id>.jsonl`
    (same path rule as the Claude adapter; map it as an `agt-worker` node).
  - **codex worker** → the rollout under `<home>` whose `session_meta.id`
    equals `session_id`.
  - **kiro / agy worker** → **opaque**. These runtimes have no transcript linked
    to the agt job: `status.json` `attempts[].session_id` is `null`. The node
    carries only `spec.json` (brief), `result.md` and `stderr-*.log`, with
    `opaque_reason` naming the null session link.

- The `provider` field in the group (`claude:high`, `kiro:xhigh`, …) names the
  runtime and effort; the node's `host` follows the runtime (`claude`, `codex`,
  `kiro`, `agy`).

## Codex spawn

On Codex an **agt** delegate is reached from the `subagent_start` MCP call rather
than a `tool_result` line; the `job g-<id>` and the `${AGT_HOME:-~/.agents-router}`
chain above are identical from there. Codex's native `spawn_agent` children are not
agt jobs — map them from their own rollouts, linked by `session_meta.parent_thread_id`
(see `adapters/codex/README.md` "Retrospective evidence").

## Fixtures

Fixture agt stores use the placeholder `__FIXTURE__` wherever an absolute path is
needed (e.g. `spec.json` `parent.config_dir`, `status.json` `attempts[].home`).
The test runner copies a fixture to a scratch dir and replaces `__FIXTURE__` with
the copy's absolute path, so a claude worker's `__FIXTURE__/worker-claude-config`
resolves to a real readable root under the scratch copy.
