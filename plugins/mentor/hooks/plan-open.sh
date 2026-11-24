#!/usr/bin/env bash
# PostToolUse:Write|Edit
#
# Opens the mentor Markdown plan (plans/<slug>/plan.md) for review ONCE, the first time it is
# created; later Write/Edits refresh it in place (Live Preview / the editor reloads when the
# file changes on disk). mentor:previewing opens its own review page, so no HTML path is handled
# here.
#
# Plan and page in sync (v4.0.0): when the edited plan has a review page at
# .mentor/reviews/<slug>/review.html, every Write/Edit of that plan.md also returns a PostToolUse
# additionalContext reminder to regenerate the page's changed sections (mentor:previewing §7)
# before the turn ends. The reminder runs before the open-once and off-switch exits below and
# ignores MENTOR_PLAN_OPEN, which governs opening only.
#
# Opener precedence — set MENTOR_PLAN_OPENER in ~/.claude/settings.json env (default "auto"):
#   auto   - open the plan as a focused VSCode editor tab via the VSCode CLI (`code -r`), so you
#            can toggle Markdown preview (⇧⌘V); without a VSCode CLI, the OS default handler.
#   vscode - same as auto.
#   chrome - Chrome cannot render raw Markdown, so this falls back to the OS default handler.
#   system - legacy: OS default opener (open / xdg-open / wslview).
#
# VSCode CLI is auto-detected (code, code-insiders, cursor, windsurf, codium); override with
# MENTOR_PLAN_VSCODE_BIN. Set MENTOR_PLAN_OPEN=off to disable opening entirely.
# MENTOR_PLAN_OPEN_DRYRUN=1 makes each opener print its name instead of launching (for tests).
#
# Scoped strictly to the plugin's own plan files — any other Write/Edit is ignored.
# Non-blocking: always exit 0.

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

# Only act on the canonical Markdown plan. Deliberately NOT matched: .mentor/reviews/
# (previewing opens its own page, and assembles it with a shell command this hook never sees)
# or any other file under .mentor/.
case "$file" in
  */.mentor/plans/*/plan.md) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

# Every model Write/Edit records the content, even when opening is off or done.
# Resolve from the edited plan's repo, which can differ from the hook's cwd.
plan_dir="$(dirname "$file")"
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session_id="$(printf '%s' "$input" | jq -r '.session_id | strings' 2>/dev/null)"
(cd "$plan_dir" && CLAUDE_CODE_SESSION_ID="$session_id" \
  bash "${hook_dir}/plan-state.sh" record-write "$(basename "$plan_dir")") >/dev/null 2>&1 || true

# Plan and page in sync: remind the agent to regenerate the plan's review page this turn.
review_page="$(dirname "$(dirname "$plan_dir")")/reviews/$(basename "$plan_dir")/review.html"
if [ -f "$review_page" ]; then
  msg="[mentor] This plan has a review page (${review_page}). If this edit changed plan content (not only a step progress mark), regenerate the page's changed sections with mentor:previewing §7 once, after your last plan edit this turn, so the page matches the plan."
  jq -nc --arg c "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' 2>/dev/null || true
fi

# Off-switch: set MENTOR_PLAN_OPEN=off in ~/.claude/settings.json env to disable auto-open.
case "${MENTOR_PLAN_OPEN:-}" in off|0|false|no) exit 0 ;; esac

# Open-once: don't re-open the same plan on every later Write/Edit (dot-hidden sidecar marker
# lives beside the opened file inside the plan's dir, gitignored). The tab/preview self-refreshes.
marker="$(dirname "$file")/.$(basename "$file").opened"
[ -e "$marker" ] && exit 0

# --- openers ---------------------------------------------------------------
# Each prints its name and returns 0 under MENTOR_PLAN_OPEN_DRYRUN (so the fallback chain stops
# at the first), otherwise launches the target and returns its success/failure for fallthrough.

vscode_bin() {
  if [ -n "${MENTOR_PLAN_VSCODE_BIN:-}" ] && command -v "$MENTOR_PLAN_VSCODE_BIN" >/dev/null 2>&1; then
    printf '%s' "$MENTOR_PLAN_VSCODE_BIN"; return 0
  fi
  local b
  for b in code code-insiders cursor windsurf codium; do
    command -v "$b" >/dev/null 2>&1 && { printf '%s' "$b"; return 0; }
  done
  return 1
}

open_vscode() {   # open the plan as a focused editor tab; user renders it via Markdown preview
  [ -n "${MENTOR_PLAN_OPEN_DRYRUN:-}" ] && { echo vscode; return 0; }
  local bin; bin="$(vscode_bin)" || return 1
  "$bin" -r "$file" >/dev/null 2>&1
}

open_system() {
  [ -n "${MENTOR_PLAN_OPEN_DRYRUN:-}" ] && { echo system; return 0; }
  { command -v open    >/dev/null 2>&1 && open    "$file" >/dev/null 2>&1; } \
    || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$file" >/dev/null 2>&1; } \
    || { command -v wslview  >/dev/null 2>&1 && wslview  "$file" >/dev/null 2>&1; } \
    || return 1
}

# --- dispatch --------------------------------------------------------------
# Markdown renders as plain text in a browser, so prefer a VSCode editor tab (the user toggles
# Markdown preview with ⇧⌘V) and fall back to the OS default handler (file association) — never
# Chrome.
case "${MENTOR_PLAN_OPENER:-auto}" in
  system) open_system ;;
  chrome) open_system ;;                  # Chrome can't render raw Markdown → OS default
  *)      open_vscode || open_system ;;   # auto / vscode: VSCode tab if installed, else OS default
esac

: > "$marker" 2>/dev/null || true   # mark as opened so subsequent edits don't re-open

exit 0
