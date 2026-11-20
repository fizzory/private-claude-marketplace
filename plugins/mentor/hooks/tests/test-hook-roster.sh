#!/usr/bin/env bash
# test-hook-roster.sh — anti-regrowth pin for mentor's machinery surface (v3.0.0).
#
# The README's charter says what mentor is: two gates, one Stop hook that keeps an
# approved run going (v6.0.0), a SessionStart plan pointer (v6.3.0), and a set of skills
# — with no component that drives a
# multi-step run by re-polling script verdicts. That is a claim
# about the file system, not just about prose, and prose alone has already failed to
# hold it once. The v1.0.0 slim-down deleted ~15 hooks; the plugin regrew from 32 to 79
# files in five weeks, largely through automated `/loom:learn` cycles that harvested a
# real lesson and landed it as a new hook or a new subcommand rather than as skill
# prose. Nothing in the repo noticed, because every individual addition was defensible.
#
# So the roster is pinned here. A new hook registration, or a new top-level script in
# hooks/, fails this test until someone amends the charter paragraph in README.md — the
# point being that the amendment is a deliberate act with a reviewer, not a side effect
# of a good idea. Deleting a hook fails too: the charter names what exists, and a
# silently-removed gate is as much a drift as a silently-added one.
#
# This complements, and does not replace, test-hooks-json-paths.sh — that one pins how
# the paths are written (${CLAUDE_PLUGIN_ROOT}, never absolute); this one pins which
# scripts are there at all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$(dirname "$HOOKS_DIR")"
HOOKS_JSON="$HOOKS_DIR/hooks.json"
[ -f "$HOOKS_JSON" ] || { echo "FATAL: hooks.json not found at $HOOKS_JSON" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for this test" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

# --- The pinned registrations: one "<event>:<script>" line per registered hook. ---
PINNED_REGISTRATIONS="$(printf '%s\n' \
  "PostToolBatch:context-checkpoint.sh" \
  "PostToolUse:plan-open.sh" \
  "Stop:plan-continue.sh" \
  "SessionStart:plan-reattach.sh" \
  "PreToolUse:plan-gate.sh" \
  "UserPromptSubmit:context-gate.sh" \
  | sort)"

# --- Scripts that are deliberately NOT hooks: skills and commands call them directly. ---
PINNED_CLIS="$(printf '%s\n' \
  "approve-plan.sh" \
  "begin-plan.sh" \
  "plan-state.sh" \
  "retro-pr-body-check.sh" \
  | sort)"

echo "== A. hooks.json registers exactly the six pinned hooks =="

ACTUAL_REGISTRATIONS="$(jq -r '
  .hooks | to_entries[] as $ev
  | $ev.value[]? | .hooks[]? | .command
  | select(. != null)
  | "\($ev.key):\(. | sub(".*/"; "") | sub("\\\\?\"$"; ""))"
' "$HOOKS_JSON" 2>/dev/null | sort)"

if [ "$ACTUAL_REGISTRATIONS" = "$PINNED_REGISTRATIONS" ]; then
  ok "hooks.json registrations match the pinned roster (6)"
else
  bad "hooks.json registrations drifted from the pinned roster"
  printf '       + added / - removed:\n'
  diff <(printf '%s\n' "$PINNED_REGISTRATIONS") <(printf '%s\n' "$ACTUAL_REGISTRATIONS") \
    | sed -n 's/^< /       - /p; s/^> /       + /p'
  printf '       New machinery needs the README charter amended first — see "What mentor is — and is not".\n'
fi

echo
echo "== B. every top-level hooks/*.sh is a registered hook or a rostered CLI =="

REGISTERED_SCRIPTS="$(printf '%s\n' "$PINNED_REGISTRATIONS" | sed 's/^[^:]*://' | sort -u)"
ALLOWED="$(printf '%s\n%s\n' "$REGISTERED_SCRIPTS" "$PINNED_CLIS" | sort -u)"

strays=0
for f in "$HOOKS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  if ! printf '%s\n' "$ALLOWED" | grep -qx "$n"; then
    strays=$((strays+1))
    printf '       unrostered script: hooks/%s\n' "$n"
  fi
done
if [ "$strays" = 0 ]; then
  ok "no unrostered script in hooks/ ($(printf '%s\n' "$ALLOWED" | grep -c . ) allowed)"
else
  bad "$strays script(s) in hooks/ are neither registered hooks nor rostered CLIs"
  printf '       New machinery needs the README charter amended first — see "What mentor is — and is not".\n'
fi

# The inverse: a rostered name that no longer exists on disk is drift too, and would
# otherwise pass section B silently (it only walks what is actually there).
missing=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  [ -f "$HOOKS_DIR/$n" ] || { missing=$((missing+1)); printf '       rostered but absent: hooks/%s\n' "$n"; }
done < <(printf '%s\n' "$ALLOWED")
if [ "$missing" = 0 ]; then
  ok "every rostered script exists on disk"
else
  bad "$missing rostered script(s) are missing — a deletion the charter does not reflect"
fi

echo
echo "== C. the charter paragraph is present in README.md =="

README="$PLUGIN_DIR/README.md"
if [ -f "$README" ] && grep -q "What mentor is — and is not" "$README"; then
  ok "README.md carries the charter the roster above enforces"
else
  bad "README.md is missing the charter paragraph — the roster has nothing to point a reader at"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
