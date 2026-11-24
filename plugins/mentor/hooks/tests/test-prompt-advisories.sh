#!/usr/bin/env bash
# test-prompt-advisories.sh — regression tests for prompt-advisories.sh, the one
# UserPromptSubmit hook. It carries two independent advisories: the planning-intent
# nudge (its opener matrix, kill switches and marker hygiene live in
# test-planning-nudge.sh) and the per-prompt plan pointer (v6.3.0), covered here.
#
# A. passthroughs and fail-soft input with no plan: silent, exit 0.
# B. the two advisories side by side: the nudge fires once per session, its marker
#    follows CLAUDE_CONFIG_DIR, it prints above the pointer when both fire, and its kill
#    switch or a synthetic prompt silences only the nudge.
# C. the pointer's content on every prompt, including slash commands and empty prompts.
# D. armed-draft freshness, and agreement with plan-reattach.sh's SessionStart selection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/prompt-advisories.sh"
LIB="$HOOKS/lib/state.sh"
for f in "$HOOK" "$LIB"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
STATE="$REPO/.mentor"
ERRFILE="$ROOT/err"
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"   # empty PATH dir → `command -v jq` fails
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
mkinput() { python3 -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}))' "$1" "$2" "$3"; }

# Pin the environment: MENTOR_STATE_HOME points the nudge marker at a sandbox instead
# of the real config dir, and a developer's own CLAUDE_CONFIG_DIR / XDG_STATE_HOME can
# never move an assertion.
STATE_HOME="$ROOT/state-home"
PIN_ENV=(-u CLAUDE_CONFIG_DIR -u XDG_STATE_HOME -u MENTOR_STATE_HOME -u MENTOR_PLANNING_INTENT)

# run <prompt> <session> [env=val ...] → sets RC / OUT / ERR. The nudge is pinned off so
# pointer assertions measure the pointer alone; section B turns it back on.
run() {
  local prompt="$1" sess="$2"; shift 2
  RC=0
  OUT="$(mkinput "$prompt" "$REPO" "$sess" \
    | env "${PIN_ENV[@]}" HOME="$SANDBOX" MENTOR_STATE_HOME="$STATE_HOME" MENTOR_PLANNING_INTENT=off "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
# run_both <prompt> <session> [env=val ...] — both advisories live, isolated $HOME so the
# nudge's once-per-session marker never touches the real machine.
NUDGE_HOME="$ROOT/nudge-home"
run_both() {
  local prompt="$1" sess="$2"; shift 2
  RC=0
  OUT="$(mkinput "$prompt" "$REPO" "$sess" \
    | env "${PIN_ENV[@]}" HOME="$NUDGE_HOME" "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
NUDGE="This looks like a planning request"

echo "== A. Passthroughs and fail-soft input, no plan: silent, exit 0 =="
for p in "hello" "/compact" "/mentor:plan the billing rewrite" "" "<task-notification>done</task-notification>"; do
  run "$p" pass-a
  chk "no plan, prompt '${p:0:24}' → exit 0, silent" test "$RC:$OUT$ERR" = "0:"
done
chk "no plan → no .mentor/ created"            test ! -e "$STATE"
RC=0
OUT="$(mkinput "hello" "$NONGIT" pass-ng | env "${PIN_ENV[@]}" HOME="$SANDBOX" MENTOR_STATE_HOME="$STATE_HOME" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
chk "outside a git repo → exit 0, silent"      test "$RC:$OUT$(cat "$ERRFILE")" = "0:"
RC=0
OUT="$(printf '{broken json' | env "${PIN_ENV[@]}" HOME="$SANDBOX" MENTOR_STATE_HOME="$STATE_HOME" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
chk "malformed stdin → exit 0, silent"         test "$RC:$OUT$(cat "$ERRFILE")" = "0:"
# No jq: input from a FILE, not a pipe — the hook exits at the `command -v jq` guard
# before reading stdin, so a pipe would hand its producer a BrokenPipe that pipefail
# then surfaces as the rc.
mkinput "help me plan the billing rewrite" "$REPO" pass-nojq > "$ROOT/in.json"
RC=0
OUT="$(HOME="$SANDBOX" PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" < "$ROOT/in.json" 2>"$ERRFILE")" || RC=$?
chk "no jq on PATH → exit 0, silent"           test "$RC:$OUT$(cat "$ERRFILE")" = "0:"

echo "== B. Nudge and pointer side by side =="
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the billing rewrite" b1
chk "no plan → the nudge fires alone"          test "$(printf '%s\n' "$OUT" | grep -c .)" = "1"
chk "no plan → nudge line"                     contains "$NUDGE" "$OUT"
chk "nudge → exit 0, silent stderr"            test "$RC:$ERR" = "0:"
run_both "help me plan the billing rewrite" b1
chk "same session → nudge silent the second time" test -z "$OUT$ERR"
chk "nudge never creates .mentor/"             test ! -e "$STATE"
# The once-per-session marker follows CLAUDE_CONFIG_DIR (v4.3.0). It was hardcoded to
# ~/.claude, so a second Claude profile wrote into the default one.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the billing rewrite" b5 CLAUDE_CONFIG_DIR="$ROOT/alt-cfg"
chk "nudge marker lands under CLAUDE_CONFIG_DIR"  test -e "$ROOT/alt-cfg/mentor/_prompt-nudges/.planning-intent-b5"
chk "nudge marker not under \$HOME/.claude"        test ! -e "$NUDGE_HOME/.claude/mentor/_prompt-nudges/.planning-intent-b5"

# A session run with no gate: the nudge is not suppressed (no live gate) and the
# pointer prints, so one prompt can carry both lines.
. "$LIB"
BWT="$(mentor_worktree_id "$REPO")"
mkdir -p "$STATE/plans/both-run"
printf '# Run\n## Implementation steps\n1. First ✅\n2. Second\n## Goal check\nPredicate\n' > "$STATE/plans/both-run/plan.md"
jq -n --arg owner "$BWT" '{state:"in_progress",owner:$owner}' > "$STATE/plans/both-run/.state.json"
printf 'slug=both-run\n' > "$STATE/.run-b2"
BOTH_POINTER="mentor plan: both-run · .mentor/plans/both-run/plan.md · in_progress · next: step 2/2"
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the next phase" b2
chk "run + matching opener → two lines"        test "$(printf '%s\n' "$OUT" | grep -c .)" = "2"
chk "run + matching opener → nudge first"      contains "$NUDGE" "${OUT%%$'\n'*}"
chk "run + matching opener → pointer second"   test "${OUT#*$'\n'}" = "$BOTH_POINTER"
chk "run + matching opener → exit 0, silent stderr" test "$RC:$ERR" = "0:"
run_both "help me plan the next phase" b2
chk "second matching prompt → pointer only"    test "$OUT" = "$BOTH_POINTER"
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
mv "$STATE/.run-b2" "$STATE/.run-b3"
run_both "help me plan the next phase" b3 MENTOR_PLANNING_INTENT=off
chk "MENTOR_PLANNING_INTENT=off → pointer only" test "$OUT" = "$BOTH_POINTER"
mv "$STATE/.run-b3" "$STATE/.run-b4"
run_both "Another Claude session sent a message: help me plan X" b4
chk "synthetic prompt → pointer only"          test "$OUT" = "$BOTH_POINTER"
chk "synthetic prompt → burns no nudge marker" test ! -e "$NUDGE_HOME/.claude/mentor/_prompt-nudges/.planning-intent-b4"
mv "$STATE/.run-b4" "$STATE/.run-b6"
run_both "/mentor:plan help me plan X" b6
chk "slash command → pointer only"             test "$OUT" = "$BOTH_POINTER"
mv "$STATE/.run-b6" "$STATE/.run-b7"
run_both "quick one: help me plan X" b7
chk "opener mid-sentence (not anchored) → pointer only" test "$OUT" = "$BOTH_POINTER"
rm -rf "$STATE"

echo "== C. Live plan pointer on every prompt =="
. "$LIB"
PLANS="$STATE/plans"
WT_ID="$(mentor_worktree_id "$REPO")"
GATE="$(mentor_plan_marker "$PLANS" "$WT_ID")"
CHANGE_NOTE="plan.md changed since mentor last wrote it — read it before editing it further"
NO_PLAN_HINT="mentor plan: no plan file yet · it is created at research start (planning Step 2)"
mkdir -p "$PLANS"
# Every fixture records stored state explicitly; tests must never infer lifecycle
# state from ticks or accidentally depend on real session/config directories.
pointer_plan() { # <slug> <stored-state> <owner> <body>
  local slug="$1" stored="$2" owner="$3" body="$4"
  mkdir -p "$PLANS/$slug"
  printf '%s\n' "$body" > "$PLANS/$slug/plan.md"
  jq -n --arg state "$stored" --arg owner "$owner" \
    '{state:$state,owner:$owner}' > "$PLANS/$slug/.state.json"
}
pointer_lines() { printf '%s\n' "$1" | grep -c '^mentor plan:'; }
line_count() { printf '%s\n' "$1" | grep -c .; }
pointer_baseline() {
  local plan_dir="$PLANS/$1" digest
  digest="$(mentor_plan_sha256 "$plan_dir/plan.md")"
  jq --arg hash "$digest" '. + {plan_sha256:$hash}' "$plan_dir/.state.json" > "$ROOT/sidecar.tmp"
  mv "$ROOT/sidecar.tmp" "$plan_dir/.state.json"
}
live_gate() {
  : > "$1"
  python3 - "$1" <<'PY'
import os, sys, time
stamp = time.time() - 60
os.utime(sys.argv[1], (stamp, stamp))
PY
}
after_gate() { # <file> [seconds after the own gate]
  python3 - "$1" "$GATE" "${2:-10}" <<'PY'
import os, sys
stamp = os.stat(sys.argv[2]).st_mtime + int(sys.argv[3])
os.utime(sys.argv[1], (stamp, stamp))
PY
}
rm -f "$PLANS"/.planning* "$STATE"/.run-*

pointer_plan quiet-run in_progress '' $'# Plan\n## Implementation steps\n1. Work'
run "hello" pointer-none
chk "unowned run without gate or marker → no pointer" test -z "$OUT$ERR"
printf 'slug=quiet-run\n' > "$STATE/.run-other-session"
run "hello" pointer-none
chk "different session run marker → no pointer" test -z "$OUT$ERR"
rm -f "$STATE/.run-other-session"

live_gate "$GATE"
run "hello" pointer-empty
chk "armed gate with no owned draft → research-start location hint" test "$OUT" = "$NO_PLAN_HINT"
pointer_plan sibling-draft draft sibling-worktree $'# Sibling\n## Research notes\nFinding'
run "hello" pointer-empty
chk "sibling-owned draft → research-start location hint" test "$OUT" = "$NO_PLAN_HINT"
pointer_plan older-draft draft "$WT_ID" $'# Old draft\n## Research notes\nOld finding'
touch -t 202001010000 "$PLANS/older-draft/plan.md"
pointer_plan active-draft draft "$WT_ID" $'# Draft\n## Research notes\nFinding'
pointer_baseline active-draft
pointer_plan completed implemented "$WT_ID" $'# Completed\n## Implementation steps\n1. Shipped ✅'
after_gate "$PLANS/active-draft/plan.md"
# Other candidates are newer: only a current owned draft qualifies.
run "hello" pointer-draft
DRAFT_POINTER="mentor plan: active-draft · .mentor/plans/active-draft/plan.md · draft · next: drafting"
chk "armed draft → slug, path, stored state, next: drafting" test "$OUT" = "$DRAFT_POINTER"
chk "known draft → no change note" test -z "$(printf '%s\n' "$OUT" | grep -F "$CHANGE_NOTE")"
run "hello again" pointer-draft
chk "armed draft → pointer repeats each prompt" test "$OUT" = "$DRAFT_POINTER"
run "/compact" pointer-draft
chk "/compact → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
run "/mentor:plan more work" pointer-draft
chk "/mentor:plan → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
run "" pointer-draft
chk "empty prompt → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
run "Another Claude session sent a message: status" pointer-draft
chk "synthetic prompt → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
printf '\n## Implementation steps\n1. Await approval\n2. Later work\n' >> "$PLANS/active-draft/plan.md"
pointer_baseline active-draft
run "hello" pointer-draft
chk "step-bearing draft → next: drafting before approval" test "$OUT" = "$DRAFT_POINTER"
printf '\nOutside edit\n' >> "$PLANS/active-draft/plan.md"
run "hello" pointer-draft
chk "changed plan → exact change note on pointer" test "$OUT" = "$DRAFT_POINTER · $CHANGE_NOTE"
chk "changed plan → one pointer line" test "$(line_count "$OUT")" = 1
pointer_baseline active-draft
run "hello" pointer-draft
chk "tracked write → change note cleared" test "$OUT" = "$DRAFT_POINTER"
rm -f "$GATE"

RUN_BODY=$'# Run\n## Implementation steps\n1. First ✅\n2. Second\n3. Third ✅\n## Goal check\nPredicate'
pointer_plan active-run in_progress "$WT_ID" "$RUN_BODY"
pointer_baseline active-run
printf 'slug=active-run\n' > "$STATE/.run-pointer-run"
RUN_POINTER="mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: step 2/3"
run "continue" pointer-run
chk "session run → first unticked step N/M" test "$OUT" = "$RUN_POINTER"
chk "session run → exit 0, silent stderr" test "$RC:$ERR" = "0:"
run "continue again" pointer-run
chk "session run → pointer repeats each prompt" test "$OUT" = "$RUN_POINTER"
jq '.state="approved"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
run "continue" pointer-run
chk "approved session plan → first unticked step N/M" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · approved · next: step 2/3"
jq '.state="in_progress"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"

run "continue" pointer-other
chk "fresh foreign run → no pointer" test -z "$OUT$ERR"
touch -t 200001010000 "$STATE/.run-pointer-run"
run "continue" pointer-other
chk "expired foreign claim → unclaimed recovery pointer" test "$OUT" = "$RUN_POINTER"
rm -f "$STATE/.run-pointer-run"
printf 'slug=active-run\n' > "$STATE/.run-pointer-other"
run "continue" pointer-other
chk "exact-session marker → the same pointer" test "$OUT" = "$RUN_POINTER"
rm -f "$STATE/.run-pointer-other"
printf 'slug=active-run\n' > "$STATE/.run-pointer-run"

printf '%s\n' "$RUN_BODY" | sed 's/2\. Second/2. Second ✅/' > "$PLANS/active-run/plan.md"
CLAUDE_CODE_SESSION_ID=pointer-run pointer_baseline active-run
run "continue" pointer-run
chk "all steps ticked → stored in_progress and next: goal check" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: goal check"
jq '.state="approved"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
run "continue" pointer-run
chk "all steps ticked → approved session plan still points to goal check" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · approved · next: goal check"
jq '.state="in_progress"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
printf '\nOutside run edit\n' >> "$PLANS/active-run/plan.md"
run "continue" pointer-run
chk "changed run → change note" contains "next: goal check · $CHANGE_NOTE" "$OUT"
printf '{"state":"in_progress","owner":"%s"}\n' "$WT_ID" > "$PLANS/active-run/.state.json"
run "continue" pointer-run
chk "legacy sidecar → unknown drift stays quiet" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: goal check"
printf '{broken json\n' > "$PLANS/active-run/.state.json"
run "continue" pointer-run
chk "corrupt sidecar → unknown stored state, never fails prompt" test "$RC:$ERR" = "0:"
chk "corrupt sidecar → ticks never imply implemented" contains " · unknown · next: goal check" "$OUT"
rm -f "$PLANS/active-run/plan.md"
run "continue" pointer-run
chk "run plan file missing → names the unavailable plan, exit 0" \
  test "$RC:$OUT$ERR" = "0:mentor plan: active-run · .mentor/plans/active-run/plan.md · unknown · next: unavailable (plan.md missing)"
printf 'slug=../outside\n' > "$STATE/.run-pointer-run"
run "continue" pointer-run
chk "invalid run slug → silent, exit 0" test "$RC:$OUT$ERR" = "0:"
rm -f "$STATE/.run-pointer-run"
: > "$PLANS/.planning.sibling-worktree"
run "hello" pointer-sibling
chk "sibling armed gate → no pointer" test -z "$OUT$ERR"
rm -f "$PLANS/.planning.sibling-worktree"
: > "$GATE"
touch -t 202001010000 "$GATE"
run "hello" pointer-stale
chk "stale armed gate → no pointer" test -z "$OUT$ERR"
rm -f "$GATE"

echo "== D. Armed-draft freshness and reattachment parity =="
reset_selection() {
  rm -rf "$PLANS"
  rm -f "$STATE"/.run-*
  mkdir -p "$PLANS"
  live_gate "$GATE"
}
selection() { # <case> <expected-slug-or-empty> [stored-state=draft]
  local label="$1" slug="$2" stored="${3:-draft}" attached context expected
  run "hello" selection
  if [ -n "$slug" ]; then
    chk "$label → prompt selects $slug" contains "mentor plan: $slug · .mentor/plans/$slug/plan.md · $stored · next:" "$OUT"
    expected="path: .mentor/plans/$slug/plan.md"
  else
    chk "$label → prompt gives only the research-start hint" test "$OUT" = "$NO_PLAN_HINT"
    expected="path: .mentor/plans/ (no plan.md yet)"
  fi
  attached="$(jq -nc --arg cwd "$REPO" '{cwd:$cwd,session_id:"selection",source:"compact"}' \
    | env "${PIN_ENV[@]}" HOME="$SANDBOX" bash "$HOOKS/plan-reattach.sh")"
  context="$(printf '%s' "$attached" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  chk "$label → SessionStart agrees with the prompt selector" contains "$expected" "$context"
}
reset_selection
pointer_plan old-only draft "$WT_ID" '# Old draft'
after_gate "$PLANS/old-only/plan.md" -10
selection 'old-only draft' ''
after_gate "$PLANS/old-only/.state.json" 30
selection 'fresh sidecar cannot refresh an existing old plan' ''
touch -r "$GATE" "$PLANS/old-only/plan.md"
selection 'plan timestamp equal to gate' ''

reset_selection
pointer_plan current draft "$WT_ID" '# Current draft'
after_gate "$PLANS/current/plan.md" 10
for stored in implemented failed superseded approved in_progress; do
  pointer_plan terminal "$stored" "$WT_ID" $'# Terminal\n## Implementation steps\n1. Done ✅'
  after_gate "$PLANS/terminal/plan.md" 40
  selection "newer $stored plan cannot steal draft" current
done
rm -rf "$PLANS/current"
selection 'armed gate without a current draft recovers owned in_progress' terminal in_progress

reset_selection
pointer_plan foreign draft other-worktree '# Foreign draft'
pointer_plan unowned draft '' '# Unowned draft'
after_gate "$PLANS/foreign/plan.md" 20
after_gate "$PLANS/unowned/plan.md" 30
selection 'foreign and unowned drafts' ''
pointer_plan first draft "$WT_ID" '# First current draft'
pointer_plan second draft "$WT_ID" '# Second current draft'
after_gate "$PLANS/first/plan.md" 10
after_gate "$PLANS/second/plan.md" 20
after_gate "$PLANS/first/.state.json" 40
selection 'multiple current drafts use plan mtime' second
before="$(cksum "$GATE" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"
selection 'selector is read-only' second
chk 'armed selectors preserve gates, plans and sidecars' test "$before" = "$(cksum "$GATE" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"

reset_selection
pointer_plan between draft "$WT_ID" '# Between gates'
after_gate "$PLANS/between/plan.md" -10
: > "$PLANS/.planning"
after_gate "$PLANS/.planning" -20
selection 'live own gate takes precedence over older legacy gate' ''
after_gate "$PLANS/between/plan.md" 10
after_gate "$PLANS/.planning" 20
selection 'live own gate takes precedence over newer legacy gate' between
touch -t 202001010000 "$GATE"
selection 'stale own gate falls back to live legacy freshness' ''
touch -r "$PLANS/.planning" "$PLANS/between/plan.md"
printf '\nFresh research\n' >> "$PLANS/between/plan.md"
selection 'live legacy gate selects a fresh draft' between
touch -t 202001010000 "$PLANS/.planning"
run 'hello' selection
chk 'both gates stale → prompt is silent' test -z "$OUT$ERR"

reset_selection
pointer_plan missing draft "$WT_ID" '# Missing draft'
rm "$PLANS/missing/plan.md"
after_gate "$PLANS/missing/.state.json" -10
selection 'stale missing-draft sidecar' ''
touch -r "$GATE" "$PLANS/missing/.state.json"
selection 'missing sidecar equal to gate' ''
after_gate "$PLANS/missing/.state.json" 10
selection 'fresh missing-draft sidecar' missing
chk 'missing armed draft gives no invented next step' contains 'next: unavailable (plan.md missing)' "$OUT"

reset_selection
rm "$GATE"
live_gate "$PLANS/.planning"
pointer_plan fallback draft '' '# Empty worktree id fallback'
chk 'empty worktree id keeps legacy/unowned selector fallback' \
  test "$(mentor_armed_draft "$PLANS" '')" = "$PLANS/fallback/plan.md"

echo '== D2. armed fresh draft B wins over kept run marker A =='
reset_selection
pointer_plan plan-a in_progress "$WT_ID" $'# Run A\n## Implementation steps\n1. Continue run A'
pointer_plan plan-b draft "$WT_ID" '# Fresh research B'
after_gate "$PLANS/plan-a/plan.md" 20
after_gate "$PLANS/plan-b/plan.md" 10
printf 'slug=plan-a\nstarted=kept\n' > "$STATE/.run-selection"
before="$(cksum "$GATE" "$STATE/.run-selection" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"
selection 'kept run A + armed fresh draft B' plan-b
chk 'draft B wins without modifying the kept marker or either plan' \
  test "$(cksum "$GATE" "$STATE/.run-selection" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)" = "$before"
rm -rf "$PLANS/plan-b"
selection 'no armed draft falls back to exact-session run A' plan-a in_progress
rm "$STATE/.run-selection"
selection 'no draft or marker falls back to owned recovery A' plan-a in_progress


echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
