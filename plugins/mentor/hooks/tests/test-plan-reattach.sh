#!/usr/bin/env bash
# Regression tests for SessionStart plan continuity, isolation and missing-file recovery.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS/plan-reattach.sh"
for dep in "$HOOK" "$HOOKS/lib/state.sh" "$HOOKS/plan-state.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }

ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
REPO="$ROOT/repo with spaces"
mkdir -p "$SANDBOX" "$REPO"
trap 'rm -rf "$ROOT"' EXIT
export HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
. "$HOOKS/lib/state.sh"
WT="$(mentor_worktree_id "$REPO")"
STATE="$REPO/.mentor"
PLAN="$STATE/plans/demo"
SID=original-session
GATE="$STATE/plans/.planning.$WT"

PASS=0; FAIL=0
chk() {
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
has() { printf '%s' "$2" | grep -Fq -- "$1"; }
hasnt() { ! has "$1" "$2"; }
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
one_block() {
  [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -es '
    length == 1 and (.[0] | keys == ["hookSpecificOutput"]) and
    .[0].hookSpecificOutput.hookEventName == "SessionStart" and
    (.[0].hookSpecificOutput.additionalContext | type == "string")
  ' >/dev/null 2>&1
}
input() {
  jq -nc --arg cwd "${3:-$REPO}" --arg sid "${2:-$SID}" --arg source "${1:-startup}" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:$source}'
}
run() {
  OUT="$(input "${1:-startup}" "${2:-$SID}" "${3:-$REPO}" | bash "$HOOK" 2>"$ROOT/err")"; RC=$?
  CONTEXT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}
set_state() {
  jq -nc --arg s "$1" --arg owner "${2:-$WT}" \
    '{state:$s, owner:$owner, note:"keep this", extra:42}' > "$PLAN/.state.json"
}
write_plan() {
  {
    printf '# Demo\n\n## Implementation steps\n\n'
    for n in 1 2 3; do
      if [ "$n" -le "${1:-1}" ]; then printf '%s. Step %s ✅\n' "$n" "$n"
      else printf '%s. Step %s\n' "$n" "$n"; fi
      printf '   - Done when: `true`\n\n'
    done
    printf '## Goal check\n\n`true`\n\n## Decision log\n\n'
  } > "$PLAN/plan.md"
}
mark() { printf 'slug=demo\nstarted=2026-11-07T00:00:00Z\n' > "$STATE/.run-${1:-$SID}"; }
reset() {
  rm -rf "$STATE"
  mkdir -p "$PLAN"
  write_plan 1; set_state in_progress
}
record() { (cd "$REPO" && CLAUDE_CODE_SESSION_ID="$SID" bash "$HOOKS/plan-state.sh" record-write demo >/dev/null 2>&1); }
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

echo '== A. no live plan is silent =='
rm -rf "$STATE"; run
chk 'no gate, marker or owned in_progress plan → no output' silent
reset; set_state implemented; run
chk 'implemented-only repository → no output' silent
reset; set_state draft; run
chk 'an unarmed draft → no output' silent
reset; set_state in_progress other-worktree; run
chk 'a sibling-owned in_progress plan → no output' silent
reset; printf '{"state":"in_progress"}\n' > "$PLAN/.state.json"; mark another-session; run
chk 'another session marker and unowned plan → no run block' silent
reset; set_state draft; touch "$STATE/plans/.planning.sibling"; run
chk 'a sibling worktree gate alone → no output' silent

echo '== B. all five lifecycle payloads reattach one changed live-plan block =='
reset; mark; record
printf '\nOutside edit\n' >> "$PLAN/plan.md"
for event in startup compact resume clear fork; do
  run "$event" "$SID"
  chk "$event emits one SessionStart additionalContext block" one_block
  chk "$event names path" has 'path: .mentor/plans/demo/plan.md' "$CONTEXT"
  chk "$event reports stored state" has 'state: in_progress' "$CONTEXT"
  chk "$event reports ticks" has 'ticks: 1/3' "$CONTEXT"
  chk "$event names next step" has 'next: step 2/3' "$CONTEXT"
  chk "$event reports drift" has 'plan.md changed since mentor last wrote it — read it before editing it further' "$CONTEXT"
  chk "$event retains exact-session ownership without a recovery line" hasnt 'resume with' "$CONTEXT"
  run "$event" "new-$event"
  chk "$event in another session emits one JSON block" one_block
  chk "$event in another session receives exactly one ownership line" test "$(printf '%s\n' "$CONTEXT" | wc -l | tr -d ' ')" = 1
  chk "$event in another session names original owner" has "belongs to $SID" "$CONTEXT"
  chk "$event in another session offers no recovery command" hasnt 'resume with' "$CONTEXT"
  chk "$event in another session creates no marker" test ! -e "$STATE/.run-new-$event"
done
chk 'original marker stays intact' test "$(cat "$STATE/.run-$SID")" = "$(printf 'slug=demo\nstarted=2026-11-07T00:00:00Z')"

echo '== Transfer into a linked worktree =='
reset; mark
receiving="$ROOT/receiving worktree"
chk 'create linked receiving worktree' git -C "$REPO" worktree add -q --detach "$receiving"
transfer() {
  (cd "$receiving" && CLAUDE_CODE_SESSION_ID=receiving-session bash "$HOOKS/plan-state.sh" begin-run demo --takeover) >/dev/null
}
chk 'receive the live plan from the original worktree' transfer
chk 'transfer preserves the historical sidecar worktree' test "$(jq -r '.owner' "$PLAN/.state.json")" = "$WT"
mkdir -p "$STATE/plans/paused"
printf '# Paused\n' > "$STATE/plans/paused/plan.md"
receiving_wt="$(mentor_worktree_id "$receiving")"
jq -nc '{state:"approved",note:"paused: row 5"}' > "$STATE/plans/paused/.state.json"
printf 'slug=paused\nstarted=fixture\nworktree=%s\n' "$receiving_wt" > "$STATE/.run-earlier-paused"
run resume receiving-fork "$receiving"
chk 'fork in receiving worktree gets one ownership block' one_block
chk 'fork in receiving worktree sees only the current owner' test "$CONTEXT" = \
  'mentor run demo belongs to receiving-session. Leave its plan and verdicts with the owning session.'
OUT="$(jq -nc --arg cwd "$receiving" \
  '{session_id:"receiving-fork",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:"<task-notification>done</task-notification>"}' |
  bash "$HOOKS/prompt-advisories.sh" 2>"$ROOT/err")"; RC=$?
chk 'task notification in the receiving fork emits no pointer' silent
chk 'receiving fork does not reserve the run' test ! -e "$STATE/.run-receiving-fork"
run compact receiving-session "$receiving"
chk 'the new owner still receives the live plan context' has 'path: .mentor/plans/demo/plan.md' "$CONTEXT"

echo '== C. gate, stored state and next-step variants =='
reset; set_state draft
printf '# Draft\n\n## Research notes\n' > "$PLAN/plan.md"
live_gate "$GATE"; after_gate "$PLAN/plan.md"; record; run
chk 'armed skeleton emits a block' one_block
chk 'armed skeleton reads draft' has 'state: draft' "$CONTEXT"
chk 'armed skeleton has no steps yet' has 'ticks: 0/0' "$CONTEXT"
chk 'armed skeleton points at drafting' has 'next: drafting' "$CONTEXT"
chk 'known hash has no change notice' hasnt 'changed since mentor' "$CONTEXT"
write_plan 1; after_gate "$PLAN/plan.md"; record; run
chk 'step-bearing draft still points at drafting' has 'next: drafting' "$CONTEXT"
chk 'step-bearing draft retains tick ratio without starting implementation' has 'ticks: 1/3' "$CONTEXT"
rm -f "$GATE"; live_gate "$STATE/plans/.planning"; run
chk 'legacy repo-wide gate also reattaches the draft' one_block
touch -t 202001010000 "$STATE/plans/.planning"; run
chk 'a stale gate alone does not reattach a draft' silent
reset; write_plan 3; mark; record; run
chk 'all ticked still reports stored in_progress' has 'state: in_progress' "$CONTEXT"
chk 'all ticked reports full ratio' has 'ticks: 3/3' "$CONTEXT"
chk 'all ticked points to goal check' has 'next: goal check' "$CONTEXT"
reset; set_state approved; mark; run
chk 'approved session plan points at the first unticked step' has 'next: step 2/3' "$CONTEXT"
write_plan 3; run
chk 'approved session plan with all steps ticked points to goal check' has 'next: goal check' "$CONTEXT"
reset; mark; printf '{"state":"in_progress"}\n' > "$PLAN/.state.json"; run
chk 'legacy sidecar without hash has no change notice' hasnt 'changed since mentor' "$CONTEXT"
reset; rm -rf "$PLAN"; touch "$STATE/plans/.planning.$WT"; run
chk 'gate before first skeleton still emits one block' one_block
chk 'gate before first skeleton invents no slug' has 'path: .mentor/plans/ (no plan.md yet)' "$CONTEXT"

echo '== D. expired runs offer recovery without taking ownership =='
reset; mark another-session
touch -t 200001010000 "$STATE/.run-another-session"
before="$(cksum "$PLAN/plan.md" "$PLAN/.state.json" "$STATE/.run-another-session")"
run resume fresh-session
chk 'unmatched owned in_progress plan emits one block' one_block
chk 'unmatched run gets exactly one recovery line' test "$(printf '%s\n' "$CONTEXT" | grep -Fc 'resume with /mentor:plan demo')" = 1
chk 'recovery never writes a session marker' test ! -e "$STATE/.run-fresh-session"
chk 'recovery preserves plan, sidecar and other session marker' test "$before" = "$(cksum "$PLAN/plan.md" "$PLAN/.state.json" "$STATE/.run-another-session")"

echo '== E. missing plan names a snapshot fallback or its absence =='
reset; mark
mkdir -p "$STATE/reviews/demo/history" "$STATE/reviews/other"
cp "$PLAN/plan.md" "$STATE/reviews/demo/_plan.md"
touch -t 202001010000 "$STATE/reviews/demo/_plan.md"
write_plan 2; cp "$PLAN/plan.md" "$STATE/reviews/demo/history/_plan.md"
write_plan 3; cp "$PLAN/plan.md" "$STATE/reviews/other/_plan.md"
rm "$PLAN/plan.md"; run
chk 'missing plan still emits a block' one_block
chk 'missing path is explicit' has 'plan.md missing: .mentor/plans/demo/plan.md' "$CONTEXT"
chk 'newest snapshot of this slug is named' has 'fallback: .mentor/reviews/demo/history/_plan.md (sidecar state retained)' "$CONTEXT"
chk 'snapshot supplies ticks' has 'ticks: 2/3' "$CONTEXT"
chk 'snapshot supplies next step' has 'next: step 3/3' "$CONTEXT"
chk 'sidecar still supplies stored state' has 'state: in_progress' "$CONTEXT"
rm -rf "$STATE/reviews/demo"; run
chk 'no copy found is explicit, ignoring other slug snapshots' has 'fallback: no copy found (sidecar state retained)' "$CONTEXT"
chk 'missing without a snapshot gives no invented next step' has 'next: unavailable (plan.md missing)' "$CONTEXT"
rm "$STATE/.run-$SID"; run clear new-clear
chk 'missing owned in_progress plan is found from its sidecar' has 'resume with /mentor:plan demo' "$CONTEXT"
reset; set_state draft; live_gate "$GATE"; after_gate "$PLAN/.state.json"; rm "$PLAN/plan.md"; run
chk 'armed missing draft is found from its sidecar' has 'plan.md missing: .mentor/plans/demo/plan.md' "$CONTEXT"

echo '== F. armed-draft freshness and prompt-selector parity =='
selection_plan() { # <slug> <stored-state> <owner>
  local dir="$STATE/plans/$1"
  mkdir -p "$dir"
  printf '# %s\n\n## Research notes\nFinding.\n' "$1" > "$dir/plan.md"
  jq -nc --arg state "$2" --arg owner "$3" '{state:$state,owner:$owner}' > "$dir/.state.json"
}
reset_selection() {
  rm -rf "$STATE"
  mkdir -p "$STATE/plans"
  live_gate "$GATE"
}
selection() { # <case> <expected-slug-or-empty> [stored-state=draft]
  local label="$1" slug="$2" stored="${3:-draft}" pointer expected
  run compact
  chk "$label → one SessionStart block" one_block
  if [ -n "$slug" ]; then
    chk "$label → reattaches $slug" has "path: .mentor/plans/$slug/plan.md" "$CONTEXT"
    expected="mentor plan: $slug · .mentor/plans/$slug/plan.md · $stored · next:"
  else
    chk "$label → invents no slug" has 'path: .mentor/plans/ (no plan.md yet)' "$CONTEXT"
    expected='mentor plan: no plan file yet · it is created at research start (planning Step 2)'
  fi
  pointer="$(jq -nc --arg cwd "$REPO" --arg sid "$SID" '{cwd:$cwd,session_id:$sid,prompt:"hello"}' \
    | env MENTOR_PLANNING_INTENT=off bash "$HOOKS/prompt-advisories.sh")"
  chk "$label → prompt agrees with SessionStart selector" has "$expected" "$pointer"
}
reset_selection
selection_plan old-only draft "$WT"
after_gate "$STATE/plans/old-only/plan.md" -10
selection 'old-only draft' ''
after_gate "$STATE/plans/old-only/.state.json" 30
selection 'fresh sidecar cannot refresh an existing old plan' ''
touch -r "$GATE" "$STATE/plans/old-only/plan.md"
selection 'plan timestamp equal to gate' ''

reset_selection
selection_plan current draft "$WT"
after_gate "$STATE/plans/current/plan.md" 10
for stored in implemented failed superseded approved in_progress; do
  selection_plan terminal "$stored" "$WT"
  after_gate "$STATE/plans/terminal/plan.md" 40
  selection "newer $stored plan cannot steal draft" current
done
rm -rf "$STATE/plans/current"
selection 'armed gate without a current draft recovers owned in_progress' terminal in_progress
chk 'recovered run retains its stored state' has 'state: in_progress' "$CONTEXT"

reset_selection
selection_plan foreign draft other-worktree
selection_plan unowned draft ''
after_gate "$STATE/plans/foreign/plan.md" 20
after_gate "$STATE/plans/unowned/plan.md" 30
selection 'foreign and unowned drafts' ''
selection_plan first draft "$WT"
selection_plan second draft "$WT"
after_gate "$STATE/plans/first/plan.md" 10
after_gate "$STATE/plans/second/plan.md" 20
after_gate "$STATE/plans/first/.state.json" 40
selection 'multiple current drafts use plan mtime' second
before="$(cksum "$GATE" "$STATE/plans"/*/plan.md "$STATE/plans"/*/.state.json)"
selection 'selector is read-only' second
chk 'armed selectors preserve gates, plans and sidecars' test "$before" = "$(cksum "$GATE" "$STATE/plans"/*/plan.md "$STATE/plans"/*/.state.json)"

reset_selection
selection_plan between draft "$WT"
after_gate "$STATE/plans/between/plan.md" -10
: > "$STATE/plans/.planning"
after_gate "$STATE/plans/.planning" -20
selection 'live own gate takes precedence over older legacy gate' ''
after_gate "$STATE/plans/between/plan.md" 10
after_gate "$STATE/plans/.planning" 20
selection 'live own gate takes precedence over newer legacy gate' between
touch -t 202001010000 "$GATE"
selection 'stale own gate falls back to live legacy freshness' ''
printf '\nFresh research\n' >> "$STATE/plans/between/plan.md"
selection 'live legacy gate selects a fresh draft' between
touch -t 202001010000 "$STATE/plans/.planning"
run
chk 'both gates stale → SessionStart is silent' silent

reset_selection
selection_plan missing draft "$WT"
rm "$STATE/plans/missing/plan.md"
after_gate "$STATE/plans/missing/.state.json" -10
selection 'stale missing-draft sidecar' ''
touch -r "$GATE" "$STATE/plans/missing/.state.json"
selection 'missing sidecar equal to gate' ''
after_gate "$STATE/plans/missing/.state.json" 10
selection 'fresh missing-draft sidecar' missing
chk 'fresh missing draft without a copy keeps next unavailable' has 'next: unavailable (plan.md missing)' "$CONTEXT"
mkdir -p "$STATE/reviews/missing"
printf '# Draft snapshot\n\n## Implementation steps\n1. Await approval\n' > "$STATE/reviews/missing/_plan.md"
selection 'fresh missing-draft sidecar with a snapshot' missing
chk 'armed draft snapshot still waits for drafting' has 'next: drafting' "$CONTEXT"
chk 'armed missing draft names its own snapshot' has 'fallback: .mentor/reviews/missing/_plan.md (sidecar state retained)' "$CONTEXT"

reset_selection
rm "$GATE"
live_gate "$STATE/plans/.planning"
selection_plan fallback draft ''
chk 'empty worktree id keeps legacy/unowned selector fallback' \
  test "$(mentor_armed_draft "$STATE/plans" '')" = "$STATE/plans/fallback/plan.md"

echo '== F2. armed fresh draft B wins over kept run marker A =='
reset_selection
selection_plan plan-a in_progress "$WT"
selection_plan plan-b draft "$WT"
after_gate "$STATE/plans/plan-a/plan.md" 20
after_gate "$STATE/plans/plan-b/plan.md" 10
printf 'slug=plan-a\nstarted=kept\n' > "$STATE/.run-$SID"
before="$(cksum "$GATE" "$STATE/.run-$SID" "$STATE/plans"/*/plan.md "$STATE/plans"/*/.state.json)"
selection 'kept run A + armed fresh draft B' plan-b
chk 'draft selection never offers to resume run A' hasnt 'resume with /mentor:plan plan-a' "$CONTEXT"
chk 'draft selection preserves the kept run marker and all plan state' \
  test "$(cksum "$GATE" "$STATE/.run-$SID" "$STATE/plans"/*/plan.md "$STATE/plans"/*/.state.json)" = "$before"
rm -rf "$STATE/plans/plan-b"
selection 'no armed draft falls back to exact-session run A' plan-a in_progress
chk 'exact-session run fallback retains ownership' hasnt 'resume with' "$CONTEXT"
rm "$STATE/.run-$SID"
selection 'no draft or marker falls back to owned recovery A' plan-a in_progress
chk 'owned recovery offers the resume command' has 'resume with /mentor:plan plan-a' "$CONTEXT"

echo '== G. fail-open input and dependency edges =='
for raw in '' 'not json' '[]' 'null'; do
  OUT="$(printf '%s' "$raw" | bash "$HOOK" 2>"$ROOT/err")"; RC=$?
  chk "invalid payload '$raw' → exit 0, silent" silent
done
run startup "$SID" "$ROOT"
chk 'outside a git repository → exit 0, silent' silent
reset; set_state draft; printf 'started=x\n' > "$STATE/.run-$SID"; run
chk 'marker without slug → exit 0, silent' silent
printf 'slug=../../escape\n' > "$STATE/.run-$SID"; run
chk 'malformed marker cannot escape the plan directory' silent
reset; printf '{broken' > "$PLAN/.state.json"; run
chk 'corrupt sidecar alone → exit 0, silent' silent
mark; run
chk 'exact marker with corrupt sidecar still emits a block' one_block
chk 'corrupt sidecar state is unknown' has 'state: unknown' "$CONTEXT"
NOJQ="$ROOT/nojq"; mkdir "$NOJQ"
ln -s "$(command -v bash)" "$NOJQ/bash"
input > "$ROOT/in.json"
OUT="$(PATH="$NOJQ" "$NOJQ/bash" "$HOOK" < "$ROOT/in.json" 2>"$ROOT/err")"; RC=$?
chk 'no jq → exit 0, silent' silent

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
