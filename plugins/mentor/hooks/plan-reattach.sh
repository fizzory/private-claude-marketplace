#!/usr/bin/env bash
# SessionStart: point fresh context at this worktree's live plan, without owning a run.
# Exact-session run markers survive resume/compact. Ownership uses the session id.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0
INPUT="$(cat)" || exit 0
INPUT="$(mentor_context_event "$INPUT" SessionStart)" || exit 0
CWD="$(mentor_cwd "$INPUT")"
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // ""')" || exit 0

repo_root="$(mentor_repo_root "$CWD")"
[ -n "$repo_root" ] || exit 0
state_dir="$(mentor_state_dir "$repo_root")"
plans_dir="$(mentor_plans_dir "$repo_root")"
wt_id=""
[ ! -d "$plans_dir" ] || wt_id="$(mentor_worktree_id "$CWD")"

# A live own/legacy gate applies here; a sibling worktree's gate does not.
armed=0
gate="$(mentor_live_gate "$plans_dir" "$wt_id")"
[ -z "$gate" ] || armed=1
reattach_locked() {
  local wake_notice=""
  if [ -n "$session_id" ]; then
    wake_notice="$(_mentor_run_locked wake "$state_dir" "$session_id" session-start)" || return 1
  fi
  printf '%s\n' "notice=$wake_notice"
  mentor_live_plan "$plans_dir" "$wt_id" "$session_id" "$gate"
}

slug=""; selected=""; notice=""
if [ -d "$plans_dir" ] && declare -F mentor_with_run_lock >/dev/null; then
  augmented="$(mentor_with_run_lock "$state_dir" reattach_locked 2>/dev/null)" || exit 0
  notice="${augmented%%$'\n'*}"; notice="${notice#notice=}"
  if [[ "$augmented" == *$'\n'* ]]; then selected="${augmented#*$'\n'}"; fi
else
  selected="$(mentor_live_plan "$plans_dir" "$wt_id" "$session_id" "$gate")"
fi
IFS=$'\t' read -r selection candidate owner <<<"$selected"
if [ -n "$candidate" ]; then slug="$(basename "$(dirname "$candidate")")"; fi
[ -n "$slug$notice" ] || [ "$armed" -eq 1 ] || exit 0

if [ "$selection" = foreign ]; then
  block="mentor run $slug belongs to $owner. Leave its plan and verdicts with the owning session."
elif [ -z "$slug" ]; then
  # The gate can predate research's first skeleton; do not invent a plan slug.
  block=""
  if [ "$armed" -eq 1 ]; then
    block="$(printf 'mentor plan: drafting\npath: .mentor/plans/ (no plan.md yet)\nstate: unknown\nticks: 0/0\nnext: drafting')"
  fi
else
  plan_dir="${plans_dir}/${slug}"
  plan_md="${plan_dir}/plan.md"
  stored="$(mentor_plan_state_stored "$plan_dir")"
  stored="${stored:-unknown}"
  scan_md="$plan_md"; recovery=""
  if [ ! -f "$plan_md" ]; then
    # Review snapshots are copies of this slug, never another plan's history.
    copy=""
    while IFS= read -r f; do
      if [ -z "$copy" ] || [ "$f" -nt "$copy" ]; then copy="$f"; fi
    done < <(find "${state_dir}/reviews/${slug}" -type f -name _plan.md 2>/dev/null || true)
    if [ -n "$copy" ]; then
      recovery="plan.md missing: .mentor/plans/${slug}/plan.md; fallback: ${copy#"${repo_root}/"} (sidecar state retained)"
      scan_md="$copy"
    else
      recovery="plan.md missing: .mentor/plans/${slug}/plan.md; fallback: no copy found (sidecar state retained)"
    fi
  fi
  # The shared step scan is also used by plan-continue.sh: ticks never finish a run.
  IFS=$'\t' read -r ticked total next title <<<"$(mentor_plan_scan_summary "$scan_md" 2>/dev/null)"
  if [ ! -f "$scan_md" ]; then where="unavailable (plan.md missing)"
  elif [ "$stored" = draft ]; then where=drafting
  elif [ "$total" -eq 0 ] && [ "$stored" != approved ] && [ "$stored" != in_progress ]; then where=drafting
  elif [ "$next" -gt 0 ]; then where="step ${next}/${total}"
  else where="goal check"; fi
  block="$(printf 'mentor plan: %s\npath: .mentor/plans/%s/plan.md\nstate: %s\nticks: %s/%s\nnext: %s' "$slug" "$slug" "$stored" "$ticked" "$total" "$where")"
  [ -z "$recovery" ] || block="${block}"$'\n'"${recovery}"
  if [ "$(mentor_plan_drift "$plan_md")" = changed ]; then
    block="${block}"$'\n'"plan.md changed since mentor last wrote it — read it before editing it further"
  fi
  if [ "$selection" = recovery ] && [ "$stored" = in_progress ]; then
    block="${block}"$'\n'"resume with /mentor:plan ${slug}"
  fi
fi
[ -z "$notice" ] || block="$notice${block:+$'\n'$block}"
jq -n --arg context "$block" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}' 2>/dev/null || true
exit 0
