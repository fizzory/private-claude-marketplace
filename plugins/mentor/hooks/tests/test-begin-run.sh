#!/usr/bin/env bash
# Regression tests for plan-state.sh begin-run: explicit continuation, no approval.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
for dep in "$HOOKS/plan-state.sh" "$HOOKS/approve-plan.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done
ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
REPO="$ROOT/repo"
mkdir -p "$SANDBOX" "$REPO"
trap 'rm -rf "$ROOT"' EXIT
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
STATE="$REPO/.mentor"
mkdir -p "$STATE/plans/retro" "$STATE/plans/unrelated" "$STATE/plans/empty"
printf '# Retro\n\n## Playbook: playbook-retrospective\n' > "$STATE/plans/retro/plan.md"
printf '{"state":"in_progress","note":"keep","custom":42}\n' > "$STATE/plans/retro/.state.json"
printf '# Other draft\n' > "$STATE/plans/unrelated/plan.md"
printf '{"state":"draft"}\n' > "$STATE/plans/unrelated/.state.json"
cp "$STATE/plans/retro/.state.json" "$ROOT/state-before"
printf 'session=other\n' > "$STATE/plans/.planning"
cp "$STATE/plans/.planning" "$ROOT/gate-before"
PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
run() { (cd "${RUN_CWD:-$REPO}" && HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/config" CLAUDE_CODE_SESSION_ID="${SID-sess-1}" bash "$HOOKS/plan-state.sh" begin-run "$@") > "$ROOT/out" 2>&1; }
fails() { ! run "$@"; }

echo '== Explicit slug and preserved state =='
chk 'starts continuation for the named plan' run retro
chk 'marker names retro, not the newer unrelated draft' grep -qx 'slug=retro' "$STATE/.run-sess-1"
chk 'marker retains the released started field' grep -Eq '^started=[0-9]{4}-' "$STATE/.run-sess-1"
chk 'sidecar bytes unchanged' cmp -s "$ROOT/state-before" "$STATE/plans/retro/.state.json"
chk 'unrelated draft not promoted' grep -qx '{"state":"draft"}' "$STATE/plans/unrelated/.state.json"
chk 'existing edit gate left untouched' cmp -s "$ROOT/gate-before" "$STATE/plans/.planning"
chk 'rerun succeeds without approving' run retro
chk 'rerun still targets exactly retro' grep -qx 'slug=retro' "$STATE/.run-sess-1"

echo '== Usage failures do not replace continuation =='
cp "$STATE/.run-sess-1" "$ROOT/run-before"
chk 'missing slug refuses' fails
chk 'unknown slug refuses' fails absent
chk 'plan directory without plan.md refuses' fails empty
chk 'extra argument refuses' fails retro unrelated
chk 'path traversal refuses' fails ../plans/retro
chk 'dot slug refuses' fails .
chk 'missing spaced basename refuses' fails 'missing slug'
multiline=$'bad\nslug'
mkdir -p "$STATE/plans/$multiline"
printf '# Existing invalid marker slug\n' > "$STATE/plans/$multiline/plan.md"
chk 'a basename requiring multiple marker lines is refused' fails "$multiline"
rm -r "$STATE/plans/$multiline"
chk 'failed calls preserve the marker' cmp -s "$ROOT/run-before" "$STATE/.run-sess-1"

echo '== Native continuation fallback and cleanup =='
rm -f "$STATE/.run-sess-1"
SID='' chk 'host without session succeeds' run retro
chk 'host without session writes no marker' test ! -e "$STATE/.run-"
SID=nosession chk 'nosession sentinel succeeds' run retro
chk 'nosession writes no marker' test ! -e "$STATE/.run-nosession"
printf 'slug=old\n' > "$STATE/.run-old"
touch -t 200001010000 "$STATE/.run-old"
printf 'slug=other\n' > "$STATE/.run-other"
chk 'normal call succeeds after old marker' run retro
chk 'unrelated stale marker is left for exact cleanup' test -e "$STATE/.run-old"
chk 'recent other-session markers survive' test -e "$STATE/.run-other"
mkdir -p "$ROOT/plain" "$ROOT/empty-repo"
git -C "$ROOT/empty-repo" init -q -b main
RUN_CWD="$ROOT/plain" chk 'outside git refuses' fails retro
RUN_CWD="$ROOT/empty-repo" chk 'repo without plans refuses' fails retro
git -C "$REPO" worktree add -q -b linked "$ROOT/linked"
SID=linked-session RUN_CWD="$ROOT/linked" chk 'linked worktree refuses the same live slug' fails retro
SID=linked-session RUN_CWD="$ROOT/linked" chk 'explicit takeover uses the shared registry' run retro --takeover
chk 'linked worktree writes into shared mentor state' grep -qx 'slug=retro' "$STATE/.run-linked-session"

echo '== Exclusive claims, identity, and byte-preserving refusals =='
. "$HOOKS/lib/state.sh"
WT_MAIN="$(mentor_worktree_id "$REPO")"
WT_LINKED="$(mentor_worktree_id "$ROOT/linked")"
# Byte snapshots include all managed artifacts, not merely the selected marker.
snapshot() { python3 - "$STATE" <<'SNAP'
import hashlib, pathlib, sys
root=pathlib.Path(sys.argv[1])
for p in sorted(root.rglob('*')):
    if p.is_file(): print(p.relative_to(root), hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
SNAP
}
reset_claims() { rm -f "$STATE"/.run-*; }
reset_claims
SID=owner chk 'owner acquires the plan' run retro
chk 'new markers record the worktree' grep -qx "worktree=$WT_MAIN" "$STATE/.run-owner"
cp "$STATE/.run-owner" "$ROOT/marker-before"
SID=owner chk 'same-session retry succeeds' run retro
chk 'same-session retry preserves marker bytes' cmp -s "$ROOT/marker-before" "$STATE/.run-owner"
SID=owner chk 'same-session second slug refuses' fails unrelated
before="$(snapshot)"
SID=foreign chk 'foreign session refuses' fails retro
SID='' chk 'missing identity refuses a live claim' fails retro
SID=nosession chk 'sentinel identity refuses a live claim' fails retro
SID='../invalid' chk 'invalid identity refuses without path writes' fails retro
chk 'refusals preserve every managed artifact byte and mtime' test "$(snapshot)" = "$before"
SID=foreign chk 'same-worktree sibling claim refuses' fails unrelated
SID=foreign RUN_CWD="$ROOT/linked" chk 'separate worktree can claim a distinct slug' run unrelated

# Missing worktree on released markers falls back to the plan's stored owner.
reset_claims
printf '{"state":"in_progress","owner":"%s","owner_session":"legacy","custom":{"keep":[1,true]}}\n' "$WT_MAIN" > "$STATE/plans/retro/.state.json"
printf 'slug=retro\nstarted=legacy\nfuture=keep-me\n' > "$STATE/.run-legacy"
before="$(snapshot)"
SID=foreign chk 'known legacy owner reserves its worktree for drafting' fails unrelated
chk 'legacy refusal leaves every file unchanged' test "$(snapshot)" = "$before"
SID=foreign RUN_CWD="$ROOT/linked" chk 'legacy worktree admission allows independent draft/run' run unrelated
SID=new-owner RUN_CWD="$ROOT/linked" chk 'repository-wide slug exclusion spans worktrees' fails retro
reset_claims
printf 'slug=retro\nstarted=legacy\nfuture=keep-me\n' > "$STATE/.run-legacy"
printf 'idle' > "$STATE/.run-legacy.idle"
printf 'wait' > "$STATE/.run-legacy.wait"
printf 'ptr' > "$STATE/.run-legacy.ptr"
printf 'slug=unrelated\n' > "$STATE/.run-legacy-extra"
SID=new-owner chk 'explicit takeover publishes a new owner' run retro --takeover
chk 'takeover stamps only owner_session' jq -e '.owner_session=="new-owner" and .custom.keep==[1,true]' "$STATE/plans/retro/.state.json"
chk 'takeover retains the plan worktree owner' jq -e --arg owner "$WT_MAIN" '.owner==$owner' "$STATE/plans/retro/.state.json"
chk 'takeover preserves unknown marker fields' grep -qx 'future=keep-me' "$STATE/.run-new-owner"
chk 'takeover removes exact old marker and companions' sh -c '[ ! -e "$1" ] && [ ! -e "$1.idle" ] && [ ! -e "$1.wait" ] && [ ! -e "$1.ptr" ]' sh "$STATE/.run-legacy"
chk 'similarly named unrelated session survives' test -f "$STATE/.run-legacy-extra"

reset_claims
printf 'slug=retro\nstarted=one\n' > "$STATE/.run-legacy-a"
printf 'slug=retro\nstarted=two\n' > "$STATE/.run-legacy-b"
before="$(snapshot)"
SID=legacy-a chk 'duplicate legacy owner cannot retry implicitly' fails retro
SID=third chk 'duplicate legacy claim requires explicit recovery' fails retro
chk 'ambiguous claim refusal preserves files' test "$(snapshot)" = "$before"
SID=legacy-a chk 'explicit retry resolves duplicate legacy claims' run retro --takeover
chk 'recovered registry has a single marker' test "$(find "$STATE" -maxdepth 1 -type f -name '.run-*' | wc -l | tr -d ' ')" = 1

reset_claims
printf 'slug=retro\nstarted=stale\nfuture=still-here\n' > "$STATE/.run-expired"
touch -t 200001010000 "$STATE/.run-expired"
SID='' chk 'expired claim allows hookless continuation without renewing it' run retro
chk 'hookless path leaves stale marker untouched' grep -qx 'started=stale' "$STATE/.run-expired"
SID=recovered chk 'explicit acquisition recovers an expired claim' run retro
chk 'expired predecessor retired after acquisition' test ! -e "$STATE/.run-expired"
chk 'expired recovery preserves unknown marker field' grep -qx 'future=still-here' "$STATE/.run-recovered"
reset_claims
printf 'slug=retro\nstarted=short-lease\n' > "$STATE/.run-short"
python3 - "$STATE/.run-short" <<'AGE'
import os,sys,time
os.utime(sys.argv[1], (time.time()-120,time.time()-120))
AGE
MENTOR_PLAN_MARKER_STALE_MIN=1 SID=short-recovery chk 'configured shorter lease is honored' run retro

# Actual overlapping processes from linked worktrees, released by one barrier.
echo '== Concurrent claims =='
for attempt in 1 2 3; do
  reset_claims
  barrier="$ROOT/race-$attempt"; mkdir "$barrier"
  (while [ ! -e "$barrier/go" ]; do sleep .01; done
   SID=race-main run retro; echo "$?" > "$barrier/main.rc") & a=$!
  (while [ ! -e "$barrier/go" ]; do sleep .01; done
   SID=race-linked RUN_CWD="$ROOT/linked" run retro; echo "$?" > "$barrier/linked.rc") & b=$!
  touch "$barrier/go"; wait "$a"; wait "$b"
  chk "race $attempt: exactly one successful claimant" test "$(cat "$barrier/main.rc" "$barrier/linked.rc" | sort | tr '\n' ' ')" = '0 1 '
  chk "race $attempt: exactly one marker" test "$(find "$STATE" -maxdepth 1 -type f -name '.run-*' | wc -l | tr -d ' ')" = 1
done

echo '== Lock lifetime, nesting, and contention =='
reset_claims
lock_callback() {
  # The transaction callback is the process actually retaining fd 9; $! can be
  # the asynchronous caller shell waiting on this subshell. Kill the holder.
  python3 -c 'import os; print(os.getppid())' > "$ROOT/lock-pid"
  : > "$ROOT/lock-ready"; read -r _ < "$ROOT/lock-fifo"
}
mkfifo "$ROOT/lock-fifo"
mentor_with_run_lock "$STATE" lock_callback & holder=$!
for attempt in $(seq 1 200); do [ ! -e "$ROOT/lock-ready" ] || break; sleep .01; done
before="$(snapshot)"
MENTOR_RUN_LOCK_TIMEOUT_SECONDS=.05 SID=contender chk 'busy lock refuses within bounded budget' fails retro
chk 'lock contention leaves artifacts unchanged' test "$(snapshot)" = "$before"
kill "$(cat "$ROOT/lock-pid")"; wait "$holder" 2>/dev/null || true
SID=after-exit chk 'kernel releases the directory lock on shell exit' run retro
chk 'locking created no extra state file' test "$(find "$STATE" -maxdepth 1 -type f ! -name '.run-after-exit' | wc -l | tr -d ' ')" = 0

# Reentrant composition retains the same descriptor; a new shell receives no
# exported transaction token. The callback can exec system Bash and exit cleanly.
nested_claim() { mentor_with_run_lock "$STATE" mentor_run_claim_locked "$STATE" retro nested-owner "$WT_MAIN"; }
reset_claims
chk 'nested in-process transaction reuses the same kernel lock' mentor_with_run_lock "$STATE" nested_claim
reset_claims
exec_callback() { exec /bin/bash -c 'exit 0'; }
chk 'directory lock survives exec until process exit' mentor_with_run_lock "$STATE" exec_callback
SID=after-exec chk 'exec exit releases the directory lock' run retro

echo '== Lease renewal and exact expiry =='
cp "$STATE/.run-after-exec" "$ROOT/renew-before"
before="$(snapshot)"
if mentor_with_run_lock "$STATE" mentor_run_renew_locked "$STATE" retro foreign > "$ROOT/out" 2>&1; then rc=0; else rc=$?; fi
chk 'foreign renewal refuses without changing artifacts' test "$rc:$(snapshot)" = "1:$before"
python3 - "$STATE/.run-after-exec" <<'AGE'
import os,sys,time
os.utime(sys.argv[1], (time.time()-60,time.time()-60))
AGE
before="$(snapshot)"
chk 'verified owner renews a fresh lease' mentor_with_run_lock "$STATE" mentor_run_renew_locked "$STATE" retro after-exec
chk 'renewal changes only marker activity time' cmp -s "$ROOT/renew-before" "$STATE/.run-after-exec"
chk 'renewal advances marker mtime' test "$(snapshot)" != "$before"
chk 'lease is fresh before expiry and stale exactly at expiry' python3 - "$HOOKS/lib/run.py" "$STATE" <<'EXPIRY'
import importlib.util,pathlib,sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('mentor_run_fixture',sys.argv[1])
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
root=pathlib.Path(sys.argv[2]);marker=root/'.run-after-exec'
expiry=marker.stat().st_mtime+module.lease_seconds()
for offset,expected in [(-1,True),(0,False),(1,False)]:
    module.time.time=lambda: expiry+offset
    claim=next(c for c in module.claims(root) if c['session']=='after-exec')
    assert claim['live']==expected,(offset,claim)
EXPIRY
touch -t 200001010000 "$STATE/.run-after-exec"
before="$(snapshot)"
if mentor_with_run_lock "$STATE" mentor_run_renew_locked "$STATE" retro after-exec > "$ROOT/out" 2>&1; then rc=0; else rc=$?; fi
chk 'expired owner cannot revive its own lease through renewal' test "$rc:$(snapshot)" = "1:$before"

# Locked helpers cannot be invoked from an unrelated shell using a stale token.
if mentor_run_renew_locked "$STATE" retro after-exit > "$ROOT/out" 2>&1; then
  chk 'unlocked renewal refuses' false
else
  chk 'unlocked renewal refuses' true
fi

reset_claims
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
