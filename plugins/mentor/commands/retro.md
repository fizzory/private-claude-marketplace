---
description: Retrospective of a finished session — turn its lessons into skills (marker-driven edit gate, Markdown plan under .mentor/plans/<slug>/)
argument-hint: "[session id | transcript path] [--until EVENT_ID] [--claude-config DIR] [--codex-home DIR] [--agt-home DIR]"
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — retro

You are entering the mentor retrospective. It rebuilds a finished session from
disk, runs three lenses and a synthesizer over it, and turns the approved
findings into skill changes. It is a thin facade over the same gated plan flow
`/mentor:plan` uses: the retro IS a mentor plan whose playbook is
`retrospective`, so it inherits the one approval, the decision log, the
independent verifier, and the Done review — no new gate, no new state.

Do these in order:

1. **Refuse while this session's own plan run is in progress or paused — check this
   FIRST, before arming anything.** A retro starts a second plan, and two live plans in
   one worktree would share the gate marker. A paused run keeps its marker with stored
   state `approved` (note `paused: row N`), and a retro's own approval would overwrite
   that marker — so a retro must not begin while this session's run is mid-flight or
   paused.

   ```bash
   [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
   command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for /mentor:retro (the refusal check and the evidence graph both use it)" >&2; exit 1; }
   mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
   # Claude Code exports the session id; resolve the run marker for THIS session.
   marker="${mentor_dir}/.run-${CLAUDE_CODE_SESSION_ID:-nosession}"
   if [ -f "$marker" ]; then
     slug="$(sed -n 's/^slug=//p' "$marker" | head -n 1)"
     state="$([ -n "$slug" ] && jq -r '.state // ""' "${mentor_dir}/plans/${slug}/.state.json" 2>/dev/null)"
     if [ "$state" = "in_progress" ] || [ "$state" = "approved" ]; then
       echo "A plan run ($slug) is in progress or paused in this session and must finish first — not arming a retro." >&2
       exit 1
     fi
   fi
   ```

   If that prints the refusal message, **stop**: report that a plan run in progress or
   paused in this session must finish (or be resumed and finished) first, and arm
   nothing. Otherwise continue to step 2. The missing-`jq` error above also stops the
   command and arms nothing.

2. **Arm the plan gate — exactly as `/mentor:plan` step 1 does, run once, never re-run.**

   Same guard, same call, same output handling as `commands/plan.md` step 1 — read that
   step for the full contract (the ALREADY-APPROVED, NOT-armed, also-armed-elsewhere and
   CONTEXT cases all apply identically here). Pass a target slug only when resuming an
   existing retro plan dir; leave it off for a fresh retrospective.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh" [<target-slug>]
   ```

   This writes THIS WORKTREE's `.planning.<wt-id>` marker and closes the edit gate until
   approval, exactly as planning does. Honor the script's stdout the same way
   `commands/plan.md` does. **Never re-run `begin-plan.sh` once it has armed the gate** —
   it resets the marker mtime and `approve-plan.sh` then refuses the finished plan as
   older than the marker.

3. **Invoke `Skill({"skill": "mentor:planning"})` with the retrospective goal, and let
   planning pick the retro playbook** (unless step 2 printed `ALREADY APPROVED`, below).
   Hand planning the goal, carrying through the session id/path AND any `--until`
   / `--claude-config` / `--codex-home` / `--agt-home` values from `$ARGUMENTS` so the
   playbook's evidence graph reads only from the roots you named and stops at the
   cutoff you named:

   > Retrospective of session `<id or path>` with `<--until/--claude-config/--codex-home/--agt-home
   > values from $ARGUMENTS, if any>`

   Planning reads `skills/planning/references/playbooks.md` and selects the
   `retrospective` reference at Step 2. It is **never co-loaded with `software-change`**: a
   retrospective is not a code-change goal, so planning loads the retro playbook alone.
   Then follow planning end to end — its one approval, its run loop, its Done review.

   **Exception — `ALREADY APPROVED: <slug>`:** if step 2 printed that, nothing was armed
   and the retro plan is already approved (or in progress). Handle it exactly as
   `commands/plan.md` step 1 does for that case: invoke `Skill({"skill": "mentor:planning"})`
   and go straight to its "After Proceed — run until the Goal check passes {#implement}"
   section for that slug, after the check its Step 0 names for this case — do not start a
   new plan.

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
