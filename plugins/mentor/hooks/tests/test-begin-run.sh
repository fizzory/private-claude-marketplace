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
chk 'invalid slug refuses' fails 'bad slug'
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
chk 'old markers are pruned' test ! -e "$STATE/.run-old"
chk 'recent other-session markers survive' test -e "$STATE/.run-other"
mkdir -p "$ROOT/plain" "$ROOT/empty-repo"
git -C "$ROOT/empty-repo" init -q -b main
RUN_CWD="$ROOT/plain" chk 'outside git refuses' fails retro
RUN_CWD="$ROOT/empty-repo" chk 'repo without plans refuses' fails retro
git -C "$REPO" worktree add -q -b linked "$ROOT/linked"
SID=linked-session RUN_CWD="$ROOT/linked" chk 'linked worktree shares the plan registry' run retro
chk 'linked worktree writes into shared mentor state' grep -qx 'slug=retro' "$STATE/.run-linked-session"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
