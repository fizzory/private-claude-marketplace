#!/usr/bin/env bash
# Regression tests for hooks/plan-continue.sh — the Stop hook that keeps an approved
# run going until a terminal state (v6.0.0). One section per row of its first-match
# table, plus the fail-open edges.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$HOOKS/plan-continue.sh"
for dep in "$HOOK" "$HOOKS/lib/state.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }

ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
REPO="$ROOT/repo"
mkdir -p "$SANDBOX" "$REPO"
trap 'rm -rf "$ROOT"' EXIT

git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
STATE="$REPO/.mentor"
PLAN="$STATE/plans/demo"
mkdir -p "$PLAN"

PASS=0; FAIL=0
chk() {  # chk <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
has()   { printf '%s' "$2" | grep -q -- "$1"; }
hasnt() { ! printf '%s' "$2" | grep -q -- "$1"; }

SID="sess-1"
input() {  # input [stop_hook_active] [session_id] [background_tasks]
  jq -nc --arg cwd "$REPO" --arg sid "${2-$SID}" --argjson a "${1:-false}" --argjson tasks "${3:-null}" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"Stop",stop_hook_active:$a} +
     (if $tasks == null then {} else {background_tasks:$tasks} end)'
}
run() {  # run [stop_hook_active] [session_id] — prints stdout, sets RC
  OUT="$(input "${1:-false}" "${2-$SID}" "${3:-null}" |
    HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/claude" env -u MENTOR_CONTINUE bash "$HOOK" 2>"$ROOT/stop-err")"; RC=$?
  ERR="$(cat "$ROOT/stop-err")"
}
blocks() { [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)" = "block" ]; }
allows() { [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null)" != "block" ]; }
silent() { [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; }
state() { (cd "$REPO" && HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/claude" CLAUDE_CODE_SESSION_ID="$SID" bash "$HOOKS/plan-state.sh" "$@"); }

write_plan() {  # write_plan <ticked-steps e.g. "1">
  {
    printf '# Demo\n\n## Implementation steps\n\n'
    for n in 1 2 3; do
      if printf '%s' "$1" | grep -q "$n"; then printf '%s. Step %s ✅\n' "$n" "$n"; else printf '%s. Step %s\n' "$n" "$n"; fi
      printf '   - Done when: `true`\n\n'
    done
    printf '## Goal check\n\n`true`\n\n## Decision log\n\n'
  } > "$PLAN/plan.md"
}
set_state() { printf '{"state":"%s"}\n' "$1" > "$PLAN/.state.json"; }
mark() { printf 'slug=demo\nstarted=2026-11-01T00:00:00Z\n' > "$STATE/.run-$SID"; rm -f "$STATE/.run-$SID.idle"; }
reset() { rm -f "$STATE"/.run-* "$STATE/config.json" "$PLAN/step-2-verify.md"; rm -rf "$PLAN/verdicts"; write_plan "1"; set_state in_progress; mark; }

echo "== Row 6. in_progress + marker → block naming the next step =="
reset; run
chk "blocks the stop"                          blocks
chk "reason names the slug and next step 2"    has "continue demo: next step 2" "$OUT"
chk "reason points at After Proceed + verifier contract" has "After Proceed.*verifier-contract.md" "$OUT"
write_plan "1 2"; run true
chk "stop_hook_active:true still blocks under the cap" blocks
chk "..and names the new next step 3"          has "next step 3" "$OUT"
write_plan "1 2 3"; run
chk "all steps ticked → still blocks (stored state rules, not ticks)" blocks
chk "..reason asks for Done review, then Goal check" has "Done review.*Goal check" "$OUT"

echo "== Row 1. off switch =="
reset; OUT="$(input | HOME="$SANDBOX" MENTOR_CONTINUE=off bash "$HOOK" 2>/dev/null)"; RC=$?
chk "MENTOR_CONTINUE=off → allows"             allows
reset; printf '{"continue":"off"}\n' > "$STATE/config.json"; run
chk "\"continue\":\"off\" in config → allows"  allows

echo "== Row 2. no run marker =="
reset; rm -f "$STATE/.run-$SID"; run
chk "no marker → allows"                       allows
chk "..silently"                               test -z "$OUT"
reset; run false "other-session"
chk "another session's marker does not trap this one" allows
reset; run false ""
chk "no session_id → allows"                   allows

echo "== Row 3. stored state other than in_progress =="
for st in approved implemented failed draft; do
  reset; set_state "$st"; run
  chk "stored $st → allows"                    allows
done
reset; rm -f "$PLAN/plan.md"; run
chk "marker names a plan with no plan.md → allows" allows
chk "..and drops the dead marker"              test ! -f "$STATE/.run-$SID"

echo "== Row 4. stale run =="
reset; touch -t 202001010000 "$STATE/.run-$SID" "$PLAN/plan.md"; run
chk "marker + plan.md older than the stale threshold → allows" allows
chk "..and deletes the marker"                 test ! -f "$STATE/.run-$SID"
reset; touch -t 202001010000 "$PLAN/plan.md"; run
chk "a fresh owner lease survives an older plan.md" blocks
two_h_ago="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
reset; touch -t "$two_h_ago" "$STATE/.run-$SID"; run
chk "fresh plan.md → blocks"                   blocks
chk "..and the block refreshes the marker's mtime" test -z "$(find "$STATE/.run-$SID" -mmin +5)"

echo '== One block per unchanged stall =='
reset; printf '{"continue_max_idle_blocks":3}\n' > "$STATE/config.json"
run; chk 'first stall blocks and names the owner' blocks
chk 'reason carries the session identity' has "$SID" "$OUT"
printf '%s\n' work > "$REPO/untracked.txt"
git -C "$REPO" add -- untracked.txt
for attempt in 1 2 3 4; do
  printf '%s\n' "$attempt" > "$REPO/untracked.txt"
  printf '%s\n' "$attempt" > "$REPO/really-untracked.txt"
  run; chk "unchanged stall $attempt is silent despite checkout edits" silent
done
write_plan "1 2"; run; chk 'plan progress permits one new block' blocks
printf 'Verdict: PASS\n' > "$PLAN/step-2-verify.md"
run; chk 'legacy verdict progress permits one new block' blocks
mkdir -p "$PLAN/verdicts"
printf 'Verdict: PASS\n' > "$PLAN/verdicts/step-2.md"
run; chk 'canonical verdict takes precedence' blocks
printf 'Verdict: FAIL\n' > "$PLAN/step-2-verify.md"
run; chk 'shadowed legacy verdict is not progress' silent
printf 'Verdict: FAIL\n' > "$PLAN/verdicts/step-2.md"
run; chk 'canonical verdict content counts as progress' blocks
reset; printf '{"continue_max_idle_blocks":0}\n' > "$STATE/config.json"
run; chk 'zero disables the stall block and notice' silent

echo '== Native and declared waits =='
reset
active='[{"id":"builder","type":"subagent","status":"running"}]'
for attempt in 1 2 3; do
  run false "$SID" "$active"; chk "native wait $attempt is silent" silent
done
chk 'owner can declare an external wait' state wait demo --for 'external builder' --ttl-min 2
run false "$SID"; chk 'missing task registry uses declared wait' silent
run false "$SID" '{"not":"an array"}'; chk 'malformed task registry uses declared wait' silent
run false "$SID" '[]'; chk 'empty task registry uses declared wait' silent
if state wait demo --for job --ttl-min 0 > "$ROOT/invalid" 2>&1; then
  chk 'zero TTL is refused' false
else
  chk 'zero TTL is refused' true
fi
rm -f "$STATE/.run-$SID.wait"
run false "$SID" '[{}]'; chk 'malformed task entries alone do not hide a real stall' blocks

echo '== Partial completion with another job pending =='
notify() {
  jq -nc --arg cwd "$REPO" --arg sid "$SID" --arg task "$1" \
    '{cwd:$cwd, session_id:$sid, hook_event_name:"UserPromptSubmit",
      prompt:("<task-notification>" + $task + " complete</task-notification>")}' |
    HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/claude" bash "$HOOKS/prompt-advisories.sh" >/dev/null
}

reset
both='[{"id":"builder-a","type":"subagent","status":"running"},{"id":"builder-b","type":"subagent","status":"running"}]'
remaining='[{"id":"builder-b","type":"subagent","status":"running"}]'
run false "$SID" "$both"
chk 'two native jobs permit a silent Stop' silent
chk 'owner receives completion for one native job' notify 'builder-a'
run false "$SID" "$remaining"
chk 'remaining native job permits a silent Stop after partial completion' silent

reset
chk 'owner declares a wait for two external jobs' state wait demo --for 'external-a and external-b' --ttl-min 2
run false "$SID" '[]'
chk 'the two external jobs permit a silent Stop without a task registry' silent
chk 'owner receives completion for one external job' notify 'external-a'
chk 'the partial completion consumes the prior declaration' test ! -e "$STATE/.run-$SID.wait"
chk 'owner redeclares wait for the remaining job' state wait demo --for 'external-b' --ttl-min 2
run false "$SID" '[]'
chk 'remaining external job permits a silent Stop after partial completion' silent

echo '== Overlapping continuation events =='
reset
race="$ROOT/stop-race"; mkdir -p "$race"
for i in 1 2; do
  (while [ ! -e "$race/go" ]; do sleep .01; done
   input | HOME="$SANDBOX" bash "$HOOK" > "$race/$i.out" 2> "$race/$i.err") &
  if [ "$i" = 1 ]; then first=$!; else second=$!; fi
done
touch "$race/go"
wait "$first"; wait "$second"
chk 'concurrent Stops produce exactly one block' test "$(jq -s 'map(select(.decision=="block")) | length' "$race/1.out" "$race/2.out")" = 1
chk 'both Stop stderrs are empty' test -z "$(cat "$race/1.err" "$race/2.err")"
run; chk 'the same fingerprint stays silent' silent

cat > "$race/sitecustomize.py" <<'PYTHON'
import fcntl
import os
from pathlib import Path
import time

flock = fcntl.flock
barrier = Path(os.environ["STOP_LOCK_BARRIER"])


def delayed_flock(fd, operation):
    (barrier / "ready").touch()
    deadline = time.monotonic() + 10
    while not (barrier / "release").exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("timed out waiting to release Stop")
        time.sleep(.01)
    return flock(fd, operation)


fcntl.flock = delayed_flock
PYTHON

for transition in takeover closure; do
  reset
  mkdir -p "$race/$transition"
  barrier="$race/$transition"
  input > "$barrier/input"
  HOME="$SANDBOX" PYTHONPATH="$race" STOP_LOCK_BARRIER="$barrier" bash "$HOOK" \
    < "$barrier/input" > "$barrier/out" 2> "$barrier/err" &
  delayed=$!
  for ((i = 0; i < 200; i++)); do
    [ ! -e "$barrier/ready" ] || break
    sleep .02
  done
  chk "$transition: Stop reached the lock boundary first" test -e "$barrier/ready"
  if [ "$transition" = takeover ]; then
    chk 'takeover: replacement acquired the claim while Stop was held' \
      env CLAUDE_CODE_SESSION_ID=replacement bash -c 'cd "$1" && bash "$2" begin-run demo --takeover' _ "$REPO" "$HOOKS/plan-state.sh" >/dev/null
  else
    chk 'closure: owner closed the run while Stop was held' state set demo implemented >/dev/null
  fi
  touch "$barrier/release"
  RC=0; wait "$delayed" || RC=$?
  OUT="$(cat "$barrier/out")"; ERR="$(cat "$barrier/err")"
  chk "$transition: delayed Stop stays silent" silent
  chk "$transition: former marker and companions remain absent" test -z "$(find "$STATE" -maxdepth 1 -name ".run-$SID*")"
done

echo "== Fail-open edges =="
reset; OUT="$(printf 'not json' | HOME="$SANDBOX" bash "$HOOK" 2>/dev/null)"; RC=$?
chk "malformed stdin → exit 0, no block"       allows
OUT="$(jq -nc --arg cwd "$ROOT" '{session_id:"sess-1", cwd:$cwd}' | HOME="$SANDBOX" bash "$HOOK" 2>/dev/null)"; RC=$?
chk "cwd outside a git repo → allows"          allows
reset; printf 'started=x\n' > "$STATE/.run-$SID"; run
chk "marker with no slug= → allows"            allows
reset
NOJQ="$ROOT/nojq"; mkdir -p "$NOJQ"
for b in bash cat dirname git sed find head awk cksum cut rm printf grep; do
  p="$(command -v "$b" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$NOJQ/$b"
done
# Input from a FILE, not a pipe: the hook exits at the `command -v jq` guard before reading
# stdin, so a piped producer can die of SIGPIPE (141), which pipefail then reports as the rc.
input > "$ROOT/in.json"
OUT="$(HOME="$SANDBOX" PATH="$NOJQ" "$NOJQ/bash" "$HOOK" < "$ROOT/in.json" 2>/dev/null)"; RC=$?
chk "no jq on PATH → exit 0, no block"         allows

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
