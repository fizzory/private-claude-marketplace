#!/usr/bin/env bash
# prompt-advisories.sh — UserPromptSubmit (the ONE per-prompt hook)
#
# Carries two independent advisories that share one process, one `. lib/state.sh`, and
# one cwd/repo resolution. Both write to stdout, which UserPromptSubmit injects as context.
#
#   • PLANNING-INTENT NUDGE (merged in from the retired planning-intent.sh in v2.34.0).
#     A prompt opening with one of a few anchored phrases ("help me plan…", "let's
#     plan…") gets a one-line advisory suggesting Skill(mentor:planning) or
#     `/mentor:plan <topic>`, once per session. The opener list stays short and anchored
#     at position 0 on purpose: a mid-sentence "plan" ("so my plan is to…") is not a
#     planning request, and a false nudge on every such prompt would teach users to
#     ignore it. Silent for empty prompts, slash commands, harness-synthetic prompts (an
#     inbound agent/teammate report, a task notification, a background-agent stop
#     notice — no human request behind them) and a worktree already planning. Its
#     once-per-session marker lives under a machine-global scratch dir
#     (mentor_host_state_base … /_prompt-nudges), never inside the target repo, and
#     markers older than 24h are pruned. Kill switch: MENTOR_PLANNING_INTENT=off (env;
#     also 0|false|no) or "planning_intent":"off" (.mentor/config.json).
#
#   • PLAN POINTER. Share the path and next action for an armed draft or owned run.
#     The owner gets pointer changes only on repeated task notifications.
#
# Fail-soft everywhere: no jq / malformed input → exit 0. Each advisory is an
# independent call; neither can fail the prompt or swallow the other. Never blocks.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0

INPUT="$(cat)" || exit 0
INPUT="$(mentor_context_event "$INPUT" UserPromptSubmit)" || exit 0
PROMPT="$(printf '%s' "$INPUT" | jq -er '.prompt | strings')" || exit 0
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // ""')" || exit 0
# Passthroughs skip the nudge, independently of the plan pointer.
PASSTHROUGH=0
case "$PROMPT" in ''|/*) PASSTHROUGH=1 ;; esac

# Harness-synthetic prompt? The nudge skips it (see header); the pointer does not.
# Patterns are ANCHORED at position 0 on purpose: a leading `*…*` would exempt a real
# human prompt that merely QUOTES one of these phrases (e.g. asking about a log line).
# Shapes below were measured against this machine's transcript corpus (2026-08-04); the
# bare tags are kept because they are the inner tags of the wrapper form and the shape
# subagent threads already use — a harness change could hoist them to the front.
SYNTHETIC=0
TASK_NOTICE=0
case "$PROMPT" in
  '<task-notification'*) SYNTHETIC=1; TASK_NOTICE=1 ;;
  '<agent-message'* | '<teammate-message'*) SYNTHETIC=1 ;;
  # Inter-session / teammate reports arrive WRAPPED — the tag sits on line 2, so the
  # bare-tag arms above never fire for them. This is the dominant real shape.
  'Another Claude session sent a message:'*) SYNTHETIC=1 ;;
  # Background-agent stop notices: `Background agent "…" was stopped by the user.` and
  # `<N> background agent(s) was|were stopped by the user: …`.
  'Background agent "'*' was stopped by the user'*) SYNTHETIC=1 ;;
  [0-9]*' background agent'*' stopped by the user'*) SYNTHETIC=1 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$CWD")"
plans_dir="$(mentor_plans_dir "$repo_root")"
wt_id=""
[ ! -d "$plans_dir" ] || wt_id="$(mentor_worktree_id "$CWD")"

# ---------------------------------------------------------------------------
# The planning-intent nudge. A function, not the tail of the script, so the plan pointer
# below still runs when the nudge returns early. Its marker lives under a machine-global
# scratch dir rather than the repo: a heuristic prompt match must never create .mentor/
# in a repo that has never used mentor. The shared preamble above already classified
# empty, slash-command and synthetic prompts.
mentor_planning_nudge() {
[ "$PASSTHROUGH" = "0" ] || return 0
[ "$SYNTHETIC" = "0" ] || return 0
# Kill switch (env, or per-repo config when one already exists — read-only, never
# creates .mentor/ or config.json).
case "${MENTOR_PLANNING_INTENT:-}" in
  off|0|false|no) return 0 ;;
esac
[ "$(mentor_config_get "$repo_root" "planning_intent")" = "off" ] && return 0

# Already inside mentor's planning flow → THIS worktree's own marker (or the legacy
# repo-global one) is live, nudging now is noise. Routed through mentor_marker_stale
# (not a bare `-f` check) so a long-dead marker can't suppress the nudge forever, and
# through mentor_worktree_id/mentor_plan_marker so a live SIBLING worktree's marker —
# an independent gate that doesn't touch this worktree — never suppresses here.
if [ -n "$repo_root" ]; then
  if [ -n "$(mentor_live_gate "$plans_dir" "$wt_id" -e)" ]; then
    return 0
  fi
fi

# Narrow, anchored planning-intent openers (case-insensitive). See header for why this
# list stays short.
PROMPT_LC="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$PROMPT_LC" in
  "help me plan"*|"let's plan"*|"lets plan"*|"can you plan"*|"plan out"*|"i want to plan"*) ;;
  *) return 0 ;;
esac

# Once-per-session only. Marker lives under a machine-global scratch dir — NEVER
# inside the target repo's .mentor/ (see header). The base follows MENTOR_STATE_HOME,
# else CLAUDE_CONFIG_DIR, else ~/.claude (mentor_host_state_base).
scratch_dir="$(mentor_host_state_base claude)/_prompt-nudges"
marker="${scratch_dir}/.planning-intent-${SESSION_ID:-nosession}"
[ -e "$marker" ] && return 0
mkdir -p "$scratch_dir" 2>/dev/null || true
# Prune stale nudge markers (>24h) so the scratch dir doesn't grow one empty file
# per matching session forever.
find "$scratch_dir" -maxdepth 1 -name '.planning-intent-*' -mmin +1440 -delete 2>/dev/null || true
: > "$marker" 2>/dev/null || true

echo "[mentor] This looks like a planning request. Use mentor's planning flow so its structured plan format and approval boundary apply: invoke Skill(mentor:planning) directly, or offer the user \`/mentor:plan <topic>\`, which in Claude Code also arms the enforced edit gate. (Disable this advisory with MENTOR_PLANNING_INTENT=off or \"planning_intent\":\"off\" in .mentor/config.json.)"

return 0
}

# ---------------------------------------------------------------------------
# Read stored state; an all-ticked run still owes the Goal check.
mentor_plan_pointer() {
  local pp_gate pp_md="" pp_slug="" pp_stored
  local pp_source pp_next pp_total pp_ticked pp_title pp_change="" pp_selected pp_owner line
  [ -n "$repo_root" ] && [ -d "$plans_dir" ] || return 0
  pp_gate="$(mentor_live_gate "$plans_dir" "$wt_id")"

  pp_selected="$(mentor_live_plan "$plans_dir" "$wt_id" "$SESSION_ID" "$pp_gate")" || return 0
  IFS=$'\t' read -r pp_source pp_md pp_owner <<<"$pp_selected" || return 0
  [ "$pp_source" != foreign ] || return 0
  if [ -z "$pp_md" ]; then
    if [ -n "$pp_gate" ]; then
      echo "mentor plan: no plan file yet · it is created at research start (planning Step 2)"
    fi
    return 0
  fi
  pp_slug="${pp_md%/plan.md}"
  pp_slug="${pp_slug##*/}"

  pp_stored="$(mentor_plan_state_stored "${pp_md%/plan.md}")"
  if [ ! -f "$pp_md" ]; then
    pp_next="unavailable (plan.md missing)"
  elif [ "$pp_stored" = draft ]; then
    pp_next="drafting"
  else
    IFS=$'\t' read -r pp_ticked pp_total pp_next pp_title <<<"$(mentor_plan_scan_summary "$pp_md")" || return 0
    case "$pp_next:$pp_total" in *[!0-9:]*|:*|*:) return 0 ;; esac
    if [ "$pp_total" = "0" ] && [ "$pp_stored" != approved ] && [ "$pp_stored" != in_progress ]; then
      pp_next="drafting"
    elif [ "$pp_next" = "0" ]; then
      pp_next="goal check"
    else
      pp_next="step ${pp_next}/${pp_total}"
    fi
  fi
  if [ "$(mentor_plan_drift "$pp_md")" = "changed" ]; then
    pp_change=" · plan.md changed since mentor last wrote it — read it before editing it further"
  fi
  line="$(printf 'mentor plan: %s · .mentor/plans/%s/plan.md · %s · next: %s%s' \
    "$pp_slug" "$pp_slug" "${pp_stored:-unknown}" "$pp_next" "$pp_change")"
  if [ "$pp_source" = run ]; then
    _mentor_run_locked pointer "${plans_dir%/*}" "$pp_slug" "$SESSION_ID" "$TASK_NOTICE" "$line"
  else
    printf '%s\n' "$line"
  fi
  return 0
}

# Both advisories use the UserPromptSubmit stdout context channel, nudge first.
# Each runs independently; neither can fail the prompt or swallow the other.
mentor_planning_nudge 2>/dev/null || true
mentor_prompt_locked() {
  if [ -n "$SESSION_ID" ]; then
    _mentor_run_locked wake "${plans_dir%/*}" "$SESSION_ID" prompt || return 0
  fi
  mentor_plan_pointer
}
if [ -d "$plans_dir" ]; then
  if declare -F mentor_with_run_lock >/dev/null; then
    mentor_with_run_lock "${plans_dir%/*}" mentor_prompt_locked 2>/dev/null || true
  else
    mentor_plan_pointer 2>/dev/null || true
  fi
fi

exit 0
