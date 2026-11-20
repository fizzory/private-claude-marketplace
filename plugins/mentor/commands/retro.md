---
description: Retrospective of a finished session — turn its lessons into skills and open one PR/MR per repository (Markdown plan under .mentor/plans/<slug>/)
argument-hint: "[session id | transcript path] [--until EVENT_ID] [--claude-config DIR] [--codex-home DIR] [--agt-home DIR]"
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — retro

Rebuild the requested session from disk, apply the accepted skill changes, and open
one PR/MR per repository without plan approval. This facade uses planning's
retrospective exception, decision log, independent verifier and Done review; the
human reviews the PR/MR and only a human merges it.

Do these in order:

1. **Check for a live edit gate and distinguish resume from another run first.**
   This preserves existing work without promoting unrelated drafts or clearing gates.

   ```bash
   [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
   command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for /mentor:retro (the refusal check and the evidence graph both use it)" >&2; exit 1; }
   mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
   gate="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate)"
   if [ "$gate" = ARMED ]; then
     echo "A live own or legacy plan gate blocks edits in this worktree — finish that planning flow first; the gate is left untouched." >&2
     exit 1
   fi
   marker="${mentor_dir}/.run-${CLAUDE_CODE_SESSION_ID:-nosession}"
   if [ -f "$marker" ]; then
     slug="$(sed -n 's/^slug=//p' "$marker" | head -n 1)"
     state="$([ -n "$slug" ] && jq -r '.state // ""' "${mentor_dir}/plans/${slug}/.state.json" 2>/dev/null)"
     if [ "$state" = in_progress ] || [ "$state" = approved ]; then
       printf 'EXISTING_RUN=%s\nSTATE=%s\nPLAN=%s\n' "$slug" "$state" "${mentor_dir}/plans/${slug}/plan.md"
     fi
   fi
   ```

   On `EXISTING_RUN`, read that plan's saved playbook selection (including the
   released `playbook-retrospective` alias) and session evidence. If it is this
   requested retro, resume its saved evidence and stored `approved`/`in_progress`
   state per the playbook's **Planning entry**, without plan approval or a new plan.
   If it is another run, including a paused one, refuse: "Another plan run is active or paused in this session;
   finish or resume it first." Never repurpose its marker. A live gate or missing
   dependency stops entry and is left untouched.

2. **Invoke `Skill({"skill": "mentor:planning"})` with the retrospective goal.**
   Carry the session id/path and every `--until` / `--claude-config` / `--codex-home`
   / `--agt-home` argument through so evidence respects the requested roots and cutoff.
   Planning loads only the `retrospective` playbook through
   `skills/planning/references/playbooks.md`, never
   `software-change`. Follow its **Planning entry** for the validated draft →
   `in_progress` transition and `plan-state.sh begin-run <slug>`, then run through
   delivery and the Done review. Do not call `begin-plan.sh` or `approve-plan.sh`.

## Arguments

`<session id | transcript path>` (optional, first positional) names the session to review.
When omitted, the playbook resolves identity from the host (`$CLAUDE_CODE_SESSION_ID` /
`$CODEX_THREAD_ID`), then a unique cwd + opening-prompt match, else labels the result
`partial` — it never guesses the newest file.

The `--…` flags override where the evidence graph reads source transcripts and where it
freezes the cutoff. Each source-root flag wins over the matching environment variable:

| Flag | Overrides | What it points at |
|---|---|---|
| `--until EVENT_ID` | — | freeze the cutoff at this event in the root (else the root's last event at retro start); an id not found in the root yields `partial` |
| `--claude-config DIR` | `CLAUDE_CONFIG_DIR` | the Claude Code config root (`projects/`, `subagents/`) |
| `--codex-home DIR` | `CODEX_HOME` | the Codex home (`sessions/` rollouts) |
| `--agt-home DIR` | `AGT_HOME` | the agt router home (`state/groups/`, `jobs/`) |

An explicit root that is **unavailable** yields a `partial` result with **no fallback** to
the real stores — the same way the eval fixtures run. Pass these through to planning so the
playbook's evidence graph reads only from the roots you named.

$ARGUMENTS
