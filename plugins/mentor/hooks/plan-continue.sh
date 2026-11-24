#!/usr/bin/env bash
# Stop: allow background waits silently and issue one continuation per stall.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HOOK_DIR}/lib/state.sh" 2>/dev/null || exit 0
declare -F mentor_with_run_lock >/dev/null || exit 0

INPUT="$(cat)" || exit 0
session="$(printf '%s' "$INPUT" | jq -er '.session_id | strings | select(length > 0)' 2>/dev/null)" || exit 0
cwd="$(mentor_cwd "$INPUT")"
repo_root="$(mentor_repo_root "$cwd")"
[ -n "$repo_root" ] || exit 0
state_dir="$(mentor_state_dir "$repo_root")"
[ -d "$state_dir" ] || exit 0

off="$(mentor_config_get "$repo_root" continue)"
[ "${MENTOR_CONTINUE:-${off:-on}}" != off ] || exit 0
limit="$(mentor_config_get "$repo_root" continue_max_idle_blocks)"
limit="${MENTOR_CONTINUE_MAX_IDLE:-${limit:-1}}"

in_flight="$(printf '%s' "$INPUT" | jq -cr '
  .background_tasks
  | if type == "array" then any(.[]; if type == "object" then
      (.id | type == "string" and length > 0) and (.status | type == "string" and length > 0)
      else false end)
    else false end
' 2>/dev/null)" || exit 0

stop_locked() {
  local slug next where reason
  slug="$(_mentor_run_locked stop "$state_dir" "$session" "$in_flight" "$limit")" || return 0
  [ -n "$slug" ] || return 0
  next="$(mentor_plan_step_scan "$state_dir/plans/$slug/plan.md" |
    awk -F'\t' '$1 == "STEP" && $5 == 0 && !found { print $2; found=1 }')"
  where="next step $next"
  if [ -z "$next" ]; then where="grade Verification, write Done review, then grade the Goal check and deliver"; fi
  reason="continue $slug: $where (Claude session ${session:0:8}). Follow planning's After Proceed and verifier-contract.md."
  jq -n --arg r "$reason" '{decision:"block",reason:$r}'
}

mentor_with_run_lock "$state_dir" stop_locked 2>/dev/null || true
exit 0
