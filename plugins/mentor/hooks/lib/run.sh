# Shared short run transactions. Sourced optionally by state.sh; Python 3 stdlib
# fcntl is required for native run ownership (macOS/Linux; no flock executable).
#
# mentor_with_run_lock <state_dir> <shell-callback> [args...]
#   Callback runs in a subshell, under fd 9's kernel lock. Context is LOCAL and
#   never exported. Compose shell functions/subshells here, not nested Bash CLIs.
#   Exit closes the fd, including failures/signals. Contention returns nonzero in
#   <=2 seconds; advisory hooks should discard stderr and yield silently.
# *_locked operations MUST run inside that callback. Read-only inspect needs no
# lock; check+mutate callers must inspect again INSIDE the transaction.

_mentor_run_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run.py"
_mentor_run_available() { command -v python3 >/dev/null 2>&1 && [ -f "$_mentor_run_helper" ]; }
_mentor_run_fallback_guard() {
  local path
  for path in "$1"/.run-*; do
    [ ! -e "$path" ] || {
      echo '[mentor run] Python 3 run helper required while run files exist; no write.' >&2; return 1;
    }
  done
}
mentor_with_run_lock() (
  local state_dir="${1:-}"; shift
  if [ "${_MENTOR_RUN_LOCK_DIR:-}" = "$state_dir" ] && _mentor_run_available; then
    python3 "$_mentor_run_helper" validate 9 "$state_dir" || return 1
    "$@"; return $?
  fi
  local _MENTOR_RUN_LOCK_DIR="$state_dir"
  export -n _MENTOR_RUN_LOCK_DIR
  if ! _mentor_run_available; then
    _mentor_run_fallback_guard "$state_dir" || return 1
    "$@"; return $?
  fi
  mkdir -p -m 700 "$state_dir" || return 1
  exec 9< "$state_dir" || return 1
  python3 "$_mentor_run_helper" lock 9 || return 1
  "$@"
)

mentor_run_inspect() {
  if _mentor_run_available; then python3 "$_mentor_run_helper" inspect "$1"; else echo '[]'; fi
}
_mentor_run_locked() {
  local operation="$1" state_dir="$2"; shift 2
  [ "${_MENTOR_RUN_LOCK_DIR:-}" = "$state_dir" ] || {
    echo '[mentor run] operation requires a local run transaction' >&2; return 1;
  }
  if ! _mentor_run_available; then
    _mentor_run_fallback_guard "$state_dir" || return 1
    case "$operation" in
      guard|cleanup|close|activity|finish|wake|stop) return 0 ;;
      claim)
        case "${2:-}" in ''|nosession) return 0 ;; esac
        echo '[mentor run] Python 3 run helper required for native continuation; use durable artifacts.' >&2 ;;
    esac
    return 1
  fi
  python3 "$_mentor_run_helper" "$operation" 9 "$state_dir" "$@"
}
# guard <state_dir> <slug> <session> <worktree> [admit]
# `admit` also protects this worktree against starting/arming another plan.
mentor_run_guard_locked() { _mentor_run_locked guard "$@"; }
mentor_run_claim_locked() { _mentor_run_locked claim "$@"; }
mentor_run_renew_locked() { _mentor_run_locked renew "$@"; }
# Successful managed writes renew a live claim only; no-claim/stale paths stay usable.
mentor_run_activity_locked() { _mentor_run_locked activity "$@"; }
# cleanup <state_dir> <slug> <session> <all|companions>; close <state_dir> <slug>
mentor_run_cleanup_locked() { _mentor_run_locked cleanup "$@"; }
mentor_run_close_locked() { _mentor_run_locked close "$@"; }

mentor_run_finish_locked() { _mentor_run_locked finish "$@"; }
