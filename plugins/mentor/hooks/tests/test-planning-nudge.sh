#!/usr/bin/env bash
# test-planning-nudge.sh — regression tests for the PLANNING-INTENT NUDGE, which since
# v2.34.0 lives in the one per-prompt hook, prompt-advisories.sh (the standalone
# planning-intent.sh hook was retired into it). Live-gate cases also retain the
# per-prompt plan pointer; test-prompt-advisories.sh covers that pointer itself.
#
# Drives the hook with UserPromptSubmit JSON under an isolated $HOME (so the
# once-per-session marker never touches the real machine state) and a real scratch git
# repo (so the gate-armed / kill-switch checks exercise real .mentor/ paths). Asserts:
# match vs no-match on the anchored opener list, the escape hatches (empty prompt, slash
# passthrough, synthetic-prompt shapes), once-per-session suppression, the env + config
# kill switches, suppression while the plan gate is armed, and — the one hardcoded-path
# defect class this house pattern always checks — that firing NEVER creates a .mentor/
# dir in a repo that never used mentor.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/prompt-advisories.sh"
LIB="$(dirname "$SCRIPT_DIR")/lib/state.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
[ -f "$LIB" ]  || { echo "FATAL: lib not found at $LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

ROOT="$(mktemp -d)"
FAKE_HOME="$ROOT/home"
REPO="$ROOT/sample-repo"
mkdir -p "$FAKE_HOME"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
trap 'rm -rf "$ROOT"' EXIT

# Sibling-worktree fixture (v2.23.0 liveness-routed suppression: §F below). A REAL
# linked worktree of $REPO, so its own-marker suffix comes from the SAME production
# wt-id recipe (mentor_worktree_id) the hook itself calls, not a hand-picked string.
WT="$ROOT/linked-wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch >/dev/null 2>&1
wtid() { bash -c "set -euo pipefail; . '$LIB'; mentor_worktree_id '$1'"; }
REPO_WT_ID="$(wtid "$REPO")"
LINKED_WT_ID="$(wtid "$WT")"
[ -n "$REPO_WT_ID" ] && [ -n "$LINKED_WT_ID" ] || { echo "FATAL: could not derive worktree ids for the fixture" >&2; exit 1; }
PLANS_DIR="$REPO/.mentor/plans"
OWN_MARKER="$PLANS_DIR/.planning.$REPO_WT_ID"
SIBLING_MARKER="$PLANS_DIR/.planning.$LINKED_WT_ID"
LEGACY_MARKER="$PLANS_DIR/.planning"

PASS=0; FAIL=0
mkjson() { python3 -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$1" "$2" "$3"; }

# run <prompt> <cwd> <session_id> [env=val ...] — isolated $HOME, fresh per call.
run() {
  local prompt="$1" cwd="$2" sid="$3"; shift 3
  printf '%s' "$(mkjson "$prompt" "$cwd" "$sid")" \
    | env -i HOME="$FAKE_HOME" PATH="$PATH" "$@" bash "$HOOK" 2>/dev/null
}
check_fires() { # desc prompt cwd session_id [env=val ...]
  local desc="$1" prompt="$2" cwd="$3" sid="$4"; shift 4
  local got; got="$(run "$prompt" "$cwd" "$sid" "$@")"
  if [ -n "$got" ]; then PASS=$((PASS+1)); printf "  ok   fires: %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL expected a nudge, got silence: %s\n" "$desc"; fi
}
check_silent() { # desc prompt cwd session_id [env=val ...]
  local desc="$1" prompt="$2" cwd="$3" sid="$4"; shift 4
  local got; got="$(run "$prompt" "$cwd" "$sid" "$@")"
  if [ -z "$got" ]; then PASS=$((PASS+1)); printf "  ok   silent: %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL want=silent got=%q: %s\n" "$got" "$desc"; fi
}
check_pointer_only() { # desc prompt cwd session_id
  local desc="$1" got
  got="$(run "$2" "$3" "$4")"
  if [ "$got" = "mentor plan: no plan file yet · it is created at research start (planning Step 2)" ]; then
    PASS=$((PASS+1)); printf "  ok   pointer without nudge: %s\n" "$desc"
  else
    FAIL=$((FAIL+1)); printf "  FAIL expected only plan pointer got=%q: %s\n" "$got" "$desc"
  fi
}

echo "== A. Anchored openers fire (fresh session each, so once-per-session never masks these) =="
check_fires "help me plan"       "help me plan the checkout flow"        "$REPO" "sess-a1"
check_fires "Help Me Plan (case)" "Help Me Plan the checkout flow"       "$REPO" "sess-a2"
check_fires "let's plan"         "let's plan a migration"                "$REPO" "sess-a3"
check_fires "lets plan (no apostrophe)" "lets plan a migration"          "$REPO" "sess-a4"
check_fires "can you plan"       "can you plan out the auth rework"      "$REPO" "sess-a5"
check_fires "plan out"           "plan out the notification revamp"      "$REPO" "sess-a6"
check_fires "i want to plan"     "i want to plan the billing migration"  "$REPO" "sess-a7"

echo "== B. Non-matches stay silent =="
check_silent "unrelated question"        "what does this function do"                    "$REPO" "sess-b1"
check_silent "mid-sentence mention (not anchored)" "so my plan is to refactor auth later" "$REPO" "sess-b2"
check_silent "empty prompt"              ""                                               "$REPO" "sess-b3"

echo "== C. Escape hatches =="
check_silent "slash command passthrough" "/mentor:grill lets write it as mentor plan"  "$REPO" "sess-c1"
check_silent "slash command (unrelated)" "/compact"                                       "$REPO" "sess-c2"
check_silent "synthetic agent-message"   '<agent-message>help me plan this</agent-message>' "$REPO" "sess-c3"
check_silent "synthetic task-notification" '<task-notification>help me plan</task-notification>' "$REPO" "sess-c4"
check_silent "synthetic teammate report" "Another Claude session sent a message: help me plan X" "$REPO" "sess-c5"
check_silent "synthetic background-agent stop" 'Background agent "foo" was stopped by the user' "$REPO" "sess-c6"

echo "== D. Once per session =="
SID="sess-d1"
check_fires  "first matching prompt fires"           "help me plan the checkout flow" "$REPO" "$SID"
check_silent "second matching prompt, same session"  "help me plan something else"    "$REPO" "$SID"

echo "== E. Kill switch =="
check_silent "env MENTOR_PLANNING_INTENT=off" "help me plan the checkout flow" "$REPO" "sess-e1" MENTOR_PLANNING_INTENT=off
mkdir -p "$REPO/.mentor"
printf '%s\n' '{"planning_intent":"off"}' > "$REPO/.mentor/config.json"
check_silent "config planning_intent=off" "help me plan the checkout flow" "$REPO" "sess-e2"
rm -f "$REPO/.mentor/config.json"
rmdir "$REPO/.mentor" 2>/dev/null || true

echo "== F. Suppression is liveness-routed (v2.23.0): own/legacy live markers suppress; a sibling worktree's marker and a stale own marker do NOT =="
mkdir -p "$PLANS_DIR"

: > "$OWN_MARKER"
check_pointer_only "this worktree's own live marker -> no nudge (already planning here)" \
  "help me plan the checkout flow" "$REPO" "sess-f1"
rm -f "$OWN_MARKER"

: > "$LEGACY_MARKER"
check_pointer_only "live legacy repo-wide marker -> no nudge" \
  "help me plan the checkout flow" "$REPO" "sess-f2"
rm -f "$LEGACY_MARKER"

# A live marker belonging to a SIBLING worktree is an independent gate — it must never
# suppress the nudge in THIS worktree.
: > "$SIBLING_MARKER"
check_fires "sibling worktree's live marker does NOT suppress (independent gate)" \
  "help me plan the checkout flow" "$REPO" "sess-f3"
rm -f "$SIBLING_MARKER"

# A stale own marker no longer suppresses — the check is routed through
# mentor_marker_stale, not a bare `[ -f ]`, so a long-dead marker can't silence the
# nudge forever. MENTOR_PLAN_MARKER_STALE_MIN defaults to 480min (8h); back-date past it.
: > "$OWN_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$OWN_MARKER" 2>/dev/null || true
check_fires "stale own marker no longer suppresses the nudge" \
  "help me plan the checkout flow" "$REPO" "sess-f4"
rm -f "$OWN_MARKER"

rmdir "$PLANS_DIR" "$REPO/.mentor" 2>/dev/null || true

echo "== G. Never creates .mentor/ in a repo that never used mentor =="
CLEAN_REPO="$ROOT/clean-repo"
git init -q -b main "$CLEAN_REPO" >/dev/null 2>&1
( cd "$CLEAN_REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
run "help me plan the checkout flow" "$CLEAN_REPO" "sess-g1" >/dev/null
if [ -e "$CLEAN_REPO/.mentor" ]; then
  FAIL=$((FAIL+1)); printf "  FAIL a matching prompt created %s/.mentor — this hook must never write repo state\n" "$CLEAN_REPO"
else
  PASS=$((PASS+1)); printf "  ok   no .mentor/ created in the target repo after a firing match\n"
fi

echo "== H. Marker lives outside the repo, under the machine-global scratch dir =="
if [ -e "$FAKE_HOME/.claude/mentor/_prompt-nudges/.planning-intent-sess-g1" ]; then
  PASS=$((PASS+1)); printf "  ok   once-per-session marker written under \$HOME/.claude/mentor/_prompt-nudges, not the repo\n"
else
  FAIL=$((FAIL+1)); printf "  FAIL expected marker under \$HOME/.claude/mentor/_prompt-nudges — not found\n"
fi

echo "== I. Fail-soft: no jq on PATH -> silent, never aborts =="
NO_JQ_DIR="$ROOT/no-jq-path"
mkdir -p "$NO_JQ_DIR"
for b in bash env cat tr sed grep mkdir rm; do
  p="$(command -v "$b" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$NO_JQ_DIR/$b"
done
got="$(printf '%s' "$(mkjson "help me plan the checkout flow" "$REPO" "sess-i1")" | env -i HOME="$FAKE_HOME" PATH="$NO_JQ_DIR" bash "$HOOK" 2>/dev/null)"
if [ -z "$got" ]; then PASS=$((PASS+1)); printf "  ok   no jq on PATH -> silent, exits clean\n"
else FAIL=$((FAIL+1)); printf "  FAIL no jq on PATH should be silent, got=%q\n" "$got"; fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
