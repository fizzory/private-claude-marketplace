#!/usr/bin/env bash
# Regression replay for issue #19. Pass a plugin root to exercise an installed cache.
set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "${1:-$script_dir/../..}" && pwd)" || exit 1
HOOKS="$PLUGIN/hooks"
command -v jq >/dev/null 2>&1 || { echo 'FATAL: jq is required'; exit 1; }
for dep in hooks.json begin-plan.sh approve-plan.sh plan-state.sh; do
  [ -f "$HOOKS/$dep" ] || { printf 'FATAL: missing %s\n' "$HOOKS/$dep"; exit 1; }
done

# Use the registered event wiring. Each command names one bundled script.
hook_path() {
  local event="$1" command prefix='bash "${CLAUDE_PLUGIN_ROOT}/hooks/' file
  command="$(jq -er --arg event "$event" '.hooks[$event][0].hooks[0].command' "$HOOKS/hooks.json")" || return 1
  case "$command" in "$prefix"*'.sh"') ;; *) return 1 ;; esac
  file="${command#"$prefix"}"
  file="${file%\"}"
  case "$file" in */*|.*) return 1 ;; esac
  [ -f "$HOOKS/$file" ] && printf '%s\n' "$HOOKS/$file"
}

STOP_HOOK="$(hook_path Stop)" || exit 1
PROMPT_HOOK="$(hook_path UserPromptSubmit)" || exit 1
START_HOOK="$(hook_path SessionStart)" || exit 1
ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$ROOT"' EXIT
SANDBOX="$ROOT/home"
REPO="$ROOT/repo"
mkdir -p "$SANDBOX" "$REPO" || exit 1
git -C "$REPO" init -q -b main || exit 1
git -C "$REPO" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit --allow-empty -qm fixture || exit 1
cd "$REPO" || exit 1

STATE="$REPO/.mentor"
PLAN_DIR="$STATE/plans/demo"
OWNER=owner-demo
FORK=fork-demo
TEST_ENV=(HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/claude" MENTOR_STATE_HOME="$SANDBOX/state"
  MENTOR_PLANNING_INTENT=off CLAUDE_PLUGIN_ROOT="$PLUGIN")
PASS=0; FAIL=0

chk() {
  local desc="$1"
  shift
  if "$@"; then PASS=$((PASS+1)); printf 'ok   — %s\n' "$desc"
  else FAIL=$((FAIL+1)); printf 'FAIL — %s\n' "$desc"; fi
}

cli() {
  local session="$1" script="$2"
  shift 2
  env "${TEST_ENV[@]}" CLAUDE_CODE_SESSION_ID="$session" bash "$HOOKS/$script" "$@"
}

state() { cli "$OWNER" plan-state.sh "$@"; }
contains() { printf '%s\n' "$1" | grep -Fq -- "$2"; }
excludes() { ! contains "$@"; }
event() {
  local hook="$1" payload="$2"
  RC=0
  OUT="$(printf '%s\n' "$payload" | env "${TEST_ENV[@]}" bash "$hook" 2>"$ROOT/stderr")" || RC=$?
  ERR="$(cat "$ROOT/stderr")"
}

stop() {
  local session="$1" tasks="$2"
  event "$STOP_HOOK" "$(jq -nc --arg cwd "$REPO" --arg sid "$session" --argjson tasks "$tasks" '
    {cwd:$cwd, session_id:$sid, hook_event_name:"Stop", stop_hook_active:false} +
    (if $tasks == null then {} else {background_tasks:$tasks} end)
  ')"
}

prompt() {
  local session="$1" prompt_text="$2"
  event "$PROMPT_HOOK" "$(jq -nc --arg cwd "$REPO" --arg sid "$session" --arg prompt "$prompt_text" \
    '{cwd:$cwd, session_id:$sid, hook_event_name:"UserPromptSubmit", prompt:$prompt}')"
}

session_start() {
  local session="$1" source="$2"
  event "$START_HOOK" "$(jq -nc --arg cwd "$REPO" --arg sid "$session" --arg source "$source" \
    '{cwd:$cwd, session_id:$sid, hook_event_name:"SessionStart", source:$source}')"
}

silent() { [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; }
blocked() { [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s\n' "$OUT" | jq -e '.decision == "block"' >/dev/null; }

echo '== Set up and approve a real run =='
cli "$OWNER" begin-plan.sh demo >/dev/null || exit 1
state start demo >/dev/null 2>&1 || exit 1
cat > "$PLAN_DIR/plan.md" <<'PLAN'
# Demo

## Implementation steps

1. Build first
   - Done when: The saved grade passes.
2. Build second
   - Done when: The saved grade passes.

## Goal check

Both steps pass.

## Decision log

| # | result |
|---|---|
PLAN
# Some filesystems store whole seconds. Keep the gate fresh and strictly older.
python3 - "$STATE/plans" <<'PY'
from pathlib import Path
import os
import sys
import time

for marker in Path(sys.argv[1]).glob(".planning*"):
    earlier = time.time() - 2
    os.utime(marker, (earlier, earlier))
PY
cli "$OWNER" approve-plan.sh >/dev/null || exit 1
state set demo in_progress >/dev/null || exit 1
chk 'the approved plan belongs to the expected session' grep -qx 'slug=demo' "$STATE/.run-$OWNER"

echo '== Fork and background jobs =='
session_start "$FORK" resume
chk 'fork gets ownership context referencing the owner' contains "$OUT" "$OWNER"
chk 'fork gets no resume instruction' excludes "$OUT" 'resume with'
prompt "$FORK" '<task-notification>fork wake</task-notification>'
chk 'fork prompt gets no run pointer' silent
stop "$FORK" '[]'
chk 'fork Stop is silent' silent
chk 'fork has no run marker' test ! -e "$STATE/.run-$FORK"

prompt "$OWNER" 'Check the plan'
chk 'owner prompt names the first step' contains "$OUT" 'step 1/2'
for attempt in 1 2; do
  stop "$OWNER" '[{"id":"builder","type":"subagent","status":"running"}]'
  chk "native builder Stop $attempt is silent" silent
done
chk 'declare wait for an external builder' state wait demo --for 'external builder' --ttl-min 2
for attempt in 1 2; do
  stop "$OWNER" null
  chk "declared builder Stop $attempt is silent" silent
done
prompt "$OWNER" '<task-notification>builder complete</task-notification>'
chk 'unchanged builder wake has no pointer' silent
chk 'declare a fresh wait for the grader' state wait demo --for grader --ttl-min 2
stop "$OWNER" '[]'
chk 'grader Stop remains silent on an empty native task list' silent
prompt "$OWNER" '<task-notification>grader complete</task-notification>'
chk 'unchanged grader wake has no pointer' silent

mkdir -p "$PLAN_DIR/verdicts" || exit 1
printf 'Verdict: PASS\nGrade: Step 1\nGrading: independent\n' > "$PLAN_DIR/verdicts/step-1.md"
printf '| 1 | PASS |\n' >> "$PLAN_DIR/plan.md"
chk 'save the graded plan write' state record-write demo
chk 'tick reads the persisted PASS' state tick demo 1
prompt "$OWNER" '<task-notification>progress</task-notification>'
chk 'subsequent wake emits the new pointer' contains "$OUT" 'step 2/2'
prompt "$OWNER" '<task-notification>another copy</task-notification>'
chk 'new pointer is emitted only once on identical wakes' silent

echo '== One continuation for an unchanged stall =='
stop "$OWNER" '[]'
chk 'first real stall emits one continuation' blocked
for attempt in 1 2 3 4; do
  printf '%s\n' "$attempt" > "$REPO/unrelated.txt"
  stop "$OWNER" '[]'
  chk "stall repeat $attempt emits no output" silent
done
chk 'final state persists' state set demo failed --note 'replay completed'
chk 'closure removes the session marker' test ! -e "$STATE/.run-$OWNER"
for suffix in idle wait ptr; do
  chk "closure removes the $suffix companion" test ! -e "$STATE/.run-$OWNER.$suffix"
done

echo '== Wait and lease deadlines =='
chk 'restart the fixture in its stored running state' state set demo in_progress
CLOCK="$ROOT/clock"
mkdir -p "$CLOCK"
cat > "$CLOCK/sitecustomize.py" <<'PY'
import os
import time

if "MENTOR_FIXTURE_NOW" in os.environ:
    time.time = lambda: float(os.environ["MENTOR_FIXTURE_NOW"])


if "MENTOR_FIXTURE_WAKE_BARRIER" in os.environ:
    import fcntl
    from pathlib import Path

    barrier = Path(os.environ["MENTOR_FIXTURE_WAKE_BARRIER"])
    flock = fcntl.flock

    def wait_to_lock(fd, operation):
        (barrier / "ready").touch()
        deadline = time.monotonic() + 10
        while not (barrier / "release").exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("timed out waiting for the other wake")
            time.sleep(.01)
        return flock(fd, operation)

    fcntl.flock = wait_to_lock
PY

seed_deadline() {
  printf 'slug=demo\nstarted=fixture\n' > "$STATE/.run-$OWNER"
  printf '{"slug":"demo","label":"fixture grader","expires":100}\n' > "$STATE/.run-$OWNER.wait"
  python3 -c 'import os,sys; os.utime(sys.argv[1], (40, 40))' "$STATE/.run-$OWNER"
}
start_at() { PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW="$1" MENTOR_PLAN_MARKER_STALE_MIN=1 session_start "$OWNER" resume; }
prompt_at() { PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW="$1" MENTOR_PLAN_MARKER_STALE_MIN=1 prompt "$OWNER" "$2"; }

seed_deadline
start_at 99
chk 'one second before the deadline SessionStart retains the wait' test -f "$STATE/.run-$OWNER.wait"
chk 'a live wait has no expiry notice' excludes "$OUT" 'wait expired'
prompt_at 99 ""
chk 'a valid empty prompt consumes the declaration' test ! -e "$STATE/.run-$OWNER.wait"
chk 'consuming a live declaration emits no expiry notice' excludes "$OUT" 'wait expired'

for now in 100 101; do
  for first_event in start prompt; do
    seed_deadline
    if [ "$first_event" = start ]; then start_at "$now"; else prompt_at "$now" '/compact'; fi
    chk "$first_event at $now reports expiry before stale cleanup" contains "$OUT" 'wait expired (fixture grader)'
    chk "$first_event at $now did not renew a stale lease" test ! -e "$STATE/.run-$OWNER"
    if [ "$first_event" = start ]; then prompt_at "$now" 'wake'; else start_at "$now"; fi
    chk "second wake after $first_event at $now does not repeat expiry" excludes "$OUT" 'wait expired'
  done
done

seed_deadline
for fields in '{}' '{"prompt":null}' '{"prompt":42}' '{"prompt":[]}' '{"hook_event_name":"Stop","prompt":"unrelated"}'; do
  payload="$(jq -nc --arg cwd "$REPO" --arg sid "$OWNER" --argjson fields "$fields" \
    '{cwd:$cwd,session_id:$sid} + $fields')"
  PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW=101 MENTOR_PLAN_MARKER_STALE_MIN=1 event "$PROMPT_HOOK" "$payload"
  chk "malformed wake keeps the wait ($fields)" test -f "$STATE/.run-$OWNER.wait"
  chk "malformed wake emits no notice ($fields)" silent
done
for wake_hook in "$START_HOOK" "$PROMPT_HOOK"; do
  seed_deadline
  if [ "$wake_hook" = "$START_HOOK" ]; then wake_name=SessionStart; else wake_name=UserPromptSubmit; fi
  valid="$(jq -nc --arg cwd "$REPO" --arg sid "$OWNER" --arg event "$wake_name" '
    {cwd:$cwd, session_id:$sid, hook_event_name:$event, source:"resume", prompt:"wake"}')"
  before="$(cksum "$STATE/.run-$OWNER" "$STATE/.run-$OWNER.wait")"
  for malformed in '.hook_event_name = "Stop"' '.session_id += "\n"' '.session_id += "\u0000"' '.session_id = null'; do
    payload="$(printf '%s' "$valid" | jq -c "$malformed")"
    PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW=101 MENTOR_PLAN_MARKER_STALE_MIN=1 event "$wake_hook" "$payload"
    chk "$wake_name rejects $malformed" silent
    chk "$wake_name rejects $malformed without consuming expiry" test "$before" = \
      "$(cksum "$STATE/.run-$OWNER" "$STATE/.run-$OWNER.wait" 2>/dev/null)"
  done
  PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW=101 MENTOR_PLAN_MARKER_STALE_MIN=1 event "$wake_hook" "$valid"$'\n{}'
  chk "$wake_name rejects a second JSON value" silent
  chk "$wake_name rejects a second JSON value without consuming expiry" test "$before" = \
    "$(cksum "$STATE/.run-$OWNER" "$STATE/.run-$OWNER.wait" 2>/dev/null)"
done
seed_deadline
PYTHONPATH="$CLOCK" MENTOR_FIXTURE_NOW=101 MENTOR_PLAN_MARKER_STALE_MIN=1 prompt "$FORK" 'unrelated wake'
chk 'foreign wake preserves the expired wait' test -f "$STATE/.run-$OWNER.wait"
chk 'foreign wake does not announce expiry' excludes "$OUT" 'wait expired'

echo '== Overlapping wake hooks =='
seed_deadline
wake_barrier="$ROOT/wake-go"
(while [ ! -e "$wake_barrier" ]; do sleep .01; done
 start_at 101; printf '%s\n' "$OUT") > "$ROOT/start-wake.log" & start_pid=$!
(while [ ! -e "$wake_barrier" ]; do sleep .01; done
 prompt_at 101 'wake'; printf '%s\n' "$OUT") > "$ROOT/prompt-wake.log" & prompt_pid=$!
touch "$wake_barrier"
wait "$start_pid"; wait "$prompt_pid"
notice_count="$(cat "$ROOT/start-wake.log" "$ROOT/prompt-wake.log" | grep -c 'wait expired' || true)"
chk 'the overlapping wakes emit exactly one expiry notice' test "$notice_count" = 1
chk 'expiry consumption leaves no stale wait or lease' test ! -e "$STATE/.run-$OWNER.wait"

wake_at_deadline() {
  if [ "$1" = start ]; then start_at 101; else prompt_at 101 'wake'; fi
}

for first_wake in start prompt; do
  seed_deadline
  if [ "$first_wake" = start ]; then next_wake=prompt; else next_wake=start; fi
  order_barrier="$ROOT/$first_wake-first"
  mkdir -p "$order_barrier"
  (
    MENTOR_FIXTURE_WAKE_BARRIER="$order_barrier" wake_at_deadline "$next_wake"
    printf '%s\n' "$OUT" > "$order_barrier/out"
    [ "$RC" -eq 0 ] && [ -z "$ERR" ]
  ) & delayed_wake=$!
  for ((i = 0; i < 200; i++)); do
    [ ! -e "$order_barrier/ready" ] || break
    sleep .02
  done
  chk "$first_wake first: $next_wake is waiting to take the lock" test -e "$order_barrier/ready"
  wake_at_deadline "$first_wake"
  chk "$first_wake first: expiry notice is delivered" contains "$OUT" 'wait expired'
  touch "$order_barrier/release"
  chk "$first_wake first: delayed $next_wake succeeds" wait "$delayed_wake"
  chk "$first_wake first: delayed $next_wake emits no expiry notice" excludes "$(cat "$order_barrier/out")" 'wait expired'
done

printf 'RESULT: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
