#!/usr/bin/env bash
# plan-gate.sh — PreToolUse:Write|Edit|MultiEdit|NotebookEdit
#
# The single fail-closed edit gate of the mentor plan harness. It keys off TWO marker
# forms under <repo>/.mentor/plans/ (v2.23.0, per-worktree gate): this worktree's own
# `.planning.<wt-id>` (armed by begin-plan.sh, released by approve-plan.sh — scoped to
# ONE git worktree) and the legacy bare `.planning` (a pre-upgrade repo-global marker —
# blocks EVERY worktree until released/stale). Either live marker denies; the gate
# holds even under bypassPermissions: PreToolUse hooks deny independently of
# permission mode.
#
# While a marker is present, ALLOW targets OUTSIDE the repo working tree AND mentor's
# own in-repo state dir (<repo>/.mentor/ — where the plan file now lives). Any OTHER
# in-repo target — or an unresolvable/absent path — is DENIED. FAIL-CLOSED.
#
# Bash is NOT matched: the gate covers Claude's near-universal edit path
# (Write/Edit/MultiEdit/NotebookEdit); the skill instructs against repo-mutating
# shell commands during planning but does not enforce it.
#
# Staleness: a marker older than 8h is treated as released (a crashed planning
# session must never permanently lock out editing). Checked ONLY for writes the gate
# would otherwise DENY: a gate-exempt .mentor/ write (an ordinary plan.md revision
# hours into a live session) must never silently release a marker as a side effect.
# Multi-marker self-heal (v2.23.0): reaching that point evaluates BOTH the own and
# legacy markers independently — every stale one is deleted, EACH WITH ITS OWN NAMED
# NOTICE (which marker, whose session, its age) — and the write is denied only if at
# least one marker is still live afterward. This covers own-live+legacy-stale (heal
# the legacy so it can't re-block every worktree once the own marker later releases —
# still deny, the own marker is live), own-stale+legacy-live (heal own, deny on
# legacy), and both-stale (heal both, allow). A silent release is later
# indistinguishable from an approval, so every deletion — own or legacy — prints a
# notice; nothing here is ever pruned quietly.
#
# Independently of the marker, a direct write to a plan's `.state.json` sidecar is always
# denied — plan-state.sh is its only writer. That check runs before the marker check
# because sidecars are edited mostly at close-out, when the gate is already released.
#
# Neither marker present → exit 0 (not planning). Cannot resolve the repo → exit 0
# (nothing to protect). Exit 2 = block (stderr shown to the agent).

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

CWD="$(mentor_cwd "$INPUT")"
CURRENT_SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id | strings' 2>/dev/null)" || true

# Canonicalize without requiring the path to exist (new-file writes are the common
# case). macOS BSD `realpath` lacks -m and fails on non-existent paths, so fall back
# to python's os.path.realpath (resolves the existing prefix). A relative path is
# resolved against the TOOL's cwd, not the hook process's — they are not the same.
_canon() {
  local p="${1/#\~/$HOME}"     # expand leading ~ to $HOME before realpath
  case "$p" in /*) ;; *) p="${CWD%/}/$p" ;; esac
  realpath -m -- "$p" 2>/dev/null && return 0
  realpath -- "$p" 2>/dev/null && return 0
  python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null && return 0
  echo "$p"
}

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)" || true
FILE_CANON=""
[ -n "$FILE_PATH" ] && FILE_CANON="$(_canon "$FILE_PATH")"

# --- single-writer guard for plan sidecars ---
# `.state.json` is written ONLY by plan-state.sh, which validates the state, preserves
# the note, and writes atomically. A hand-rolled Write skips all three and drifts as the
# schema evolves. This arm sits ABOVE the marker check on purpose: the sidecar is edited
# most often at close-out, long after the gate released, which is precisely when the
# skill line carrying this rule isn't loaded and nothing else would catch it. Match the
# CANONICAL path — a raw-string match is slipped by `./.mentor/…`, a `..` segment, or a
# symlinked prefix, and this is a Write, so a slipped guard lands.
case "$FILE_CANON" in
  */.mentor/plans/*/.state.json)
    slug="$(basename "$(dirname "$FILE_CANON")")"
    cat >&2 <<EOF
[mentor plan-gate] Refusing a direct write to a plan sidecar: ${FILE_PATH}

plan-state.sh is the only writer of .state.json — it validates the state, keeps the
note, and writes atomically. Use it instead:

  plan-state.sh set ${slug} <draft|approved|in_progress|implemented|failed|superseded> --note "…"

Trying to re-own this plan (owner/owner_session only — e.g. after a worktree move,
or resuming it in a different worktree)? "set" cannot do that. Run this from the
worktree that should own it instead:

  plan-state.sh init ${slug}

Relocating this plan's FILES into a DIFFERENT repo entirely? Run this from the
destination repo instead of hand-copying — it creates the plan there and re-owns
it to the destination worktree in one step:

  plan-state.sh relocate <this-plan-dir>
EOF
    exit 2
    ;;
esac

# Protect managed artifacts in the target's shared repo, independent of the
# planning edit gate in the tool's cwd. This check admits a tool operation.
case "$FILE_CANON" in
  */.mentor/plans/*/*)
    target_state="${FILE_CANON%%/.mentor/plans/*}/.mentor"
    relative="${FILE_CANON#"$target_state/plans/"}"
    target_slug="${relative%%/*}"
    case "${relative#*/}" in
      plan.md|verdicts/*|step-[0-9]*-verify.md|topic-[0-9]*-verify.md|goal-verify.md)
        target_repo="$(mentor_repo_root "${target_state%/.mentor}")"
        if [ "$target_state" = "$(mentor_state_dir "$target_repo")" ] &&
          [ -d "$target_state/plans/$target_slug" ] &&
          declare -F mentor_with_run_lock >/dev/null; then
          mentor_with_run_lock "$target_state" mentor_run_guard_locked \
            "$target_state" "$target_slug" "$CURRENT_SESSION" "" || exit 2
        fi
        ;;
    esac
    ;;
esac

# Resolve the existing worktree and legacy edit gates from the tool's cwd.
repo_root_common="$(mentor_repo_root "$CWD")"
[ -n "$repo_root_common" ] || exit 0
plans_dir="$(mentor_plans_dir "$repo_root_common")"
wt_id="$(mentor_worktree_id "$CWD")"
own_marker="$(mentor_plan_marker "$plans_dir" "$wt_id")"
legacy_marker="${plans_dir}/.planning"
same_marker=0
[ "$own_marker" = "$legacy_marker" ] && same_marker=1

# Neither marker present → not planning → allow.
[ -f "$own_marker" ] || [ -f "$legacy_marker" ] || exit 0

# The working-tree root to protect (writes anywhere inside it are denied while planning).
REPO_WT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_WT" ] && REPO_WT="$repo_root_common"

REPO_CANON="$(_canon "$REPO_WT")"

if [ -n "$FILE_CANON" ]; then
  case "$FILE_CANON" in
    "${REPO_CANON}/.mentor"|"${REPO_CANON}/.mentor/"*) exit 0 ;;  # mentor's own state (plan file, markers) → always allow, staleness never evaluated
    "$REPO_CANON"|"${REPO_CANON}/"*) ;;   # else inside repo → deny (fall through)
    *) exit 0 ;;                          # outside repo (/tmp, …) → allow
  esac
fi

# --- multi-marker self-heal (reached only for writes the gate would otherwise deny —
# exempt/outside-repo targets already exited above, so an ordinary .mentor/ write can
# never disarm a marker as a side effect) ---
_heal_if_stale() {  # <marker path> <label: own|legacy> — delete <marker> if stale,
  # printing a named notice (which marker, whose session, its age); no-op when absent
  # or fresh. See the header doctrine above: nothing here is ever pruned quietly.
  local marker="$1" label="$2" sess age detail
  mentor_marker_stale "$marker" || return 0
  sess="$(mentor_marker_field "$marker" session)"
  age="$(mentor_marker_age_min "$marker")"
  rm -f "$marker" 2>/dev/null || true
  detail="${marker##*/}"
  [ -n "$sess" ] && detail="${detail}, session ${sess}"
  [ -n "$age" ] && detail="${detail}, ~${age}m old"
  echo "[mentor] Stale ${label} planning marker (${detail}) released — no longer armed here."
  return 0
}

if [ "$same_marker" -eq 0 ]; then
  _heal_if_stale "$own_marker" "own"
fi
_heal_if_stale "$legacy_marker" "legacy"

own_live=0
if [ "$same_marker" -eq 0 ]; then
  [ -f "$own_marker" ] && own_live=1
fi
legacy_live=0
[ -f "$legacy_marker" ] && legacy_live=1

if [ "$own_live" -eq 0 ] && [ "$legacy_live" -eq 0 ]; then
  echo "[mentor] Plan gate no longer armed here. If planning is still active, re-arm it by re-running /mentor:plan (begin-plan.sh)."
  exit 0
fi

# empty path (unresolvable) OR inside-repo → deny (fail-closed).
# Attribution: the alternative is a blocked agent hand-rolling ls/find-newer forensics
# to tell "fresh, someone else's live session" from "abandoned, safe to ask the user to
# clear" apart. Prefer the OWN marker's attribution when it is live (this write is
# blocked by ITS worktree's own gate); fall back to the legacy marker only when the own
# marker isn't (or isn't also) live. mentor_marker_stale already returned false for
# whichever marker we attribute to, so its age_min here is always <
# MENTOR_PLAN_MARKER_STALE_MIN.
if [ "$own_live" -eq 1 ]; then
  attr_marker="$own_marker"; attr_kind="own"
else
  attr_marker="$legacy_marker"; attr_kind="legacy"
fi

owner_session="$(mentor_marker_field "$attr_marker" session)"
owner_line=""
if [ -n "$owner_session" ]; then
  owner_cwd="$(mentor_marker_field "$attr_marker" cwd)"
  owner_line="
  Armed by: session ${owner_session} at ${owner_cwd:-<unknown cwd>}"
fi

worktree_line=""
if [ "$attr_kind" = "own" ]; then
  owner_worktree="$(mentor_marker_field "$attr_marker" worktree)"
  worktree_line="
  Worktree: ${owner_worktree:-$REPO_WT} (scoped to this worktree)"
else
  worktree_line="
  Worktree: ALL — pre-upgrade repo-wide marker (${legacy_marker}) blocks every worktree"
fi

age_min="$(mentor_marker_age_min "$attr_marker")"
age_line=""
[ -n "$age_min" ] && age_line="
  Age: ~${age_min}m ago (auto-releases after $(( MENTOR_PLAN_MARKER_STALE_MIN / 60 ))h if abandoned)."

cat >&2 << EOF
BLOCKED by mentor: PLAN PHASE is active — approve the plan first.

  ${FILE_PATH:-<no path>}${owner_line}${worktree_line}${age_line}

EOF

if [ "$attr_kind" = "own" ]; then
  cat >&2 << EOF
This worktree's own .planning.<wt-id> marker blocks edits to any file in ITS working
tree until the plan is approved through the plan skill (approve-plan.sh validates the
plan, then releases this worktree's gate). This holds even under bypassPermissions.
It is scoped to this worktree only — a sibling worktree of this repo is unaffected.
EOF
else
  cat >&2 << EOF
The legacy .planning marker (armed before this repo's mentor plugin gained per-worktree
gates) blocks edits to any file in EVERY linked worktree of this repo until it is
approved through the plan skill (approve-plan.sh validates the plan, then releases it
repo-wide). This holds even under bypassPermissions.
EOF
fi

if [ -n "$owner_session" ] && [ -n "$CURRENT_SESSION" ] && [ "$owner_session" != "$CURRENT_SESSION" ]; then
  cat >&2 << EOF

Do not delete ${attr_marker} yourself, and do not run approve-plan.sh to "clear" it —
approve-plan.sh takes no slug and promotes whatever plan is newest, which may not
be yours. Ask the user to confirm before touching it.
EOF
else
  cat >&2 << EOF

During planning the ONLY file you write is the persisted Markdown plan under
  ${plans_dir}/<slug>/plan.md
(inside the gate-exempt .mentor/ tree — always allowed). Finish the plan, choose
"Proceed" (which runs approve-plan.sh), and edit/implement only AFTER approval.
EOF
fi
exit 2
