#!/usr/bin/env bash
# test-plan-gate.sh — regression tests for plan-gate.sh
#
# Builds a real git repo (+ one linked worktree), derives the repo-scoped plans dir
# and this worktree's own marker EXACTLY as the hook does, plants/removes markers,
# then drives the hook with PreToolUse JSON for a matrix of tool calls and asserts
# allow (exit 0) vs block (exit 2).
#
# Contract under test (v2.23.0 — per-worktree plan gate): the hook considers TWO
# marker forms — this worktree's own `.planning.<wt-id>` and the legacy repo-global
# bare `.planning` (blocks EVERY worktree, fail-closed). Either live marker denies
# repo Write/Edit/MultiEdit/NotebookEdit (only OUTSIDE-repo / .mentor/ targets
# allowed); a marker in a SIBLING worktree denies nothing here. Bash is not matched
# (not enforced). A stale marker (>8h) self-heals per marker, each with its own
# notice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(dirname "$SCRIPT_DIR")/plan-gate.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
STATE_LIB="$(dirname "$HOOK")/lib/state.sh"
[ -f "$STATE_LIB" ] || { echo "FATAL: state lib not found at $STATE_LIB" >&2; exit 1; }

# Canonicalize the temp root (macOS mktemp returns /var/... which is a symlink to
# /private/var/...). Production cwd from Claude Code is already canonical.
ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"
  git config user.email t@t.co; git config user.name t
  mkdir -p src; echo "x" > src/app.ts
  git add -A; git commit -q -m init ) >/dev/null 2>&1

# A second, linked worktree of the SAME repo — the fixture every per-worktree case
# below needs. Shares the primary repo's .mentor/ (git-common-dir), but derives its
# own wt-id from its own --show-toplevel.
WTB="$ROOT/wt-b"
git -C "$REPO" worktree add -q "$WTB" -b wtb >/dev/null 2>&1

# Derive plans dir + this worktree's own marker exactly as the hook does.
git_common="$(git -C "$REPO" rev-parse --git-common-dir)"
case "$git_common" in /*) common_abs="$git_common";; *) common_abs="$REPO/$git_common";; esac
repo_root="$(cd "$(dirname "$common_abs")" && pwd)"
PLANS_DIR="$repo_root/.mentor/plans"   # project-scoped, in-repo, SHARED across worktrees
mkdir -p "$PLANS_DIR"

# wt-ids via the production recipe (sourced in a subshell so this script's own
# variables/functions stay untouched).
wt_id_of() { ( . "$STATE_LIB"; mentor_worktree_id "$1" ); }
MAIN_WT_ID="$(wt_id_of "$REPO")"
WTB_WT_ID="$(wt_id_of "$WTB")"
[ -n "$MAIN_WT_ID" ] && [ -n "$WTB_WT_ID" ] && [ "$MAIN_WT_ID" != "$WTB_WT_ID" ] \
  || { echo "FATAL: wt-id fixture broken (main='$MAIN_WT_ID' wtb='$WTB_WT_ID')" >&2; exit 1; }

MARKER="$PLANS_DIR/.planning.$MAIN_WT_ID"       # this worktree's (main's) own marker
WTB_MARKER="$PLANS_DIR/.planning.$WTB_WT_ID"    # the linked worktree's own marker
LEGACY_MARKER="$PLANS_DIR/.planning"            # pre-upgrade repo-global marker

trap 'rm -rf "$ROOT"' EXIT   # .mentor/ lives inside $ROOT, so this cleans everything

PASS=0; FAIL=0
run() { # expect cwd tool desc file_path [session]
  local expect="$1" cwd="$2" tool="$3" desc="$4" payload="$5" json rc=0 got
  json=$(jq -nc --arg cwd "$cwd" --arg file "$payload" --arg tool "$tool" --arg sid "${6:-}" \
    '{tool_name:$tool,cwd:$cwd,session_id:$sid,tool_input:{file_path:$file}}')
  printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
  got="allow"; [ "$rc" = "2" ] && got="block"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf "  ok   [%s] %s\n" "$expect" "$desc"
  else
    FAIL=$((FAIL+1)); printf "  FAIL want=%s got=%s (rc=%s): %s\n       payload: %s\n" "$expect" "$got" "$rc" "$desc" "$payload"
  fi
}
capture_stderr() {  # <cwd> <tool> <file_path> — echo the hook's stderr only
  local cwd="$1" tool="$2" file="$3" json
  json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[3],"cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$cwd" "$file" "$tool")
  printf '%s' "$json" | bash "$HOOK" 2>&1 1>/dev/null
}
count_eq() {  # <expected-count> <needle> <haystack> — exact grep -c match
  local want="$1" needle="$2" haystack="$3" got
  got="$(printf '%s' "$haystack" | command grep -c -- "$needle" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}

echo "== A. No marker → hook inert (ALLOW all) =="
rm -f "$MARKER"
run allow "$REPO" Write "Write repo file (no marker)" "$REPO/src/app.ts"
run allow "$REPO" Edit  "Edit repo file (no marker)"  "$REPO/src/app.ts"

echo "== B. Marker present → repo Write/Edit/MultiEdit/NotebookEdit BLOCKED; outside ALLOWED =="
: > "$MARKER"
run block "$REPO" Write        "Write repo source"           "$REPO/src/app.ts"
run block "$REPO" Edit         "Edit repo source"            "$REPO/src/app.ts"
run block "$REPO" MultiEdit    "MultiEdit repo source"       "$REPO/src/app.ts"
run block "$REPO" Write        "Write new repo file"         "$REPO/NEWFILE"
run block "$REPO" NotebookEdit "NotebookEdit in repo"        "$REPO/nb.ipynb"
run allow "$REPO" Write        "Write the plan .md (.mentor/ exempt)" "$PLANS_DIR/myplan/plan.md"
run allow "$REPO" Write        "Write to scratch (outside)"  "$ROOT/scratch.txt"

echo "== B2. Marker present → mentor's own .mentor/ tree is EXEMPT (always writable) =="
run allow "$REPO" Write "Write .mentor/config.json (exempt)"       "$REPO/.mentor/config.json"
run allow "$REPO" Edit  "Edit nested .mentor/ file (exempt)"        "$REPO/.mentor/reviews/x/notes.md"
run block "$REPO" Write ".mentor-evil sibling is NOT exempt"        "$REPO/.mentor-evil/x"

echo "== C. Marker present → NotebookEdit notebook_path field also gated =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"NotebookEdit","cwd":sys.argv[1],"tool_input":{"notebook_path":sys.argv[2]}}))' "$REPO" "$REPO/nb.ipynb")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] notebook_path in repo"
else FAIL=$((FAIL+1)); echo "  FAIL want=block got=allow (rc=$rc): notebook_path in repo"; fi

echo "== D. Marker present → empty/unresolvable path DENIED (fail-closed) =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{}}))' "$REPO")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] empty file_path"
else FAIL=$((FAIL+1)); echo "  FAIL want=block got=allow (rc=$rc): empty file_path"; fi

echo "== E. Bash is NOT matched → hook inert for Bash even with marker =="
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"rm "+sys.argv[1]+"/src/app.ts"}}))' "$REPO")
rc=0; printf '%s' "$json" | bash "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then PASS=$((PASS+1)); echo "  ok   [allow] Bash not gated"
else FAIL=$((FAIL+1)); echo "  FAIL want=allow got rc=$rc: Bash not gated"; fi

echo "== F. Stale marker (>8h) → treated as released (ALLOW + self-heal) =="
: > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
run allow "$REPO" Write "Write repo file (stale marker)" "$REPO/src/app.ts"
if [ ! -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   stale marker self-healed (removed)"
else FAIL=$((FAIL+1)); echo "  FAIL stale marker still present"; fi

echo "== F2. Stale marker + gate-EXEMPT write → ALLOW, marker KEPT (no side-effect release) =="
: > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
run allow "$REPO" Write "Write plan.md (stale marker, exempt path)" "$PLANS_DIR/myplan/plan.md"
if [ -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   exempt write did not release the stale marker"
else FAIL=$((FAIL+1)); echo "  FAIL exempt write released the marker"; fi
run allow "$REPO" Write "Write outside repo (stale marker)" "$ROOT/scratch2.txt"
if [ -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   outside-repo write did not release the stale marker"
else FAIL=$((FAIL+1)); echo "  FAIL outside-repo write released the marker"; fi

echo "== F. Plan sidecars are plan-state.sh's alone — blocked with OR without a marker =="
# The real violation happened at close-out with the gate long released, so the marker
# state must not matter here. Sibling .mentor/ paths stay exempt.
rm -f "$MARKER"
run block "$REPO" Write "Write .state.json (no marker)"        "$PLANS_DIR/myplan/.state.json"
run block "$REPO" Edit  "Edit .state.json (no marker)"         "$PLANS_DIR/myplan/.state.json"
run allow "$REPO" Write "Write plan.md (no marker)"            "$PLANS_DIR/myplan/plan.md"
run allow "$REPO" Write "Write a look-alike, not a sidecar"    "$PLANS_DIR/myplan/state.json"
: > "$MARKER"
run block "$REPO" Write "Write .state.json (marker armed)"     "$PLANS_DIR/myplan/.state.json"
run allow "$REPO" Bash  "Bash is still unmatched"              "$PLANS_DIR/myplan/.state.json"
# The guard matches the CANONICAL path: a raw-string match is slipped by any of these,
# and since it's a Write, a slipped guard lands.
rm -f "$MARKER"
run block "$REPO" Write "relative ./ path"                     "./.mentor/plans/myplan/.state.json"
run block "$REPO" Write "relative bare path"                   ".mentor/plans/myplan/.state.json"
run block "$REPO" Write "path with a .. segment"               "$PLANS_DIR/myplan/../myplan/.state.json"
run block "$REPO" Write "path through a subdir and .."         "$REPO/src/../.mentor/plans/myplan/.state.json"
: > "$MARKER"
if [ -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   sidecar block did not disturb the marker"
else FAIL=$((FAIL+1)); echo "  FAIL sidecar block released the marker"; fi

echo "== G. Deny message attribution (marker session/cwd metadata, current session_id) =="
denywith() {  # <marker-body> <deny-request-session-id>
  printf '%s' "$1" > "$MARKER"
  python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]},"session_id":sys.argv[3]}))' \
    "$REPO" "$REPO/src/app.ts" "$2" | bash "$HOOK" 2>&1 1>/dev/null
}

# G1. Marker owned by the SAME session as the denied request → original "finish and
# approve" guidance stands; no foreign-marker warning.
out="$(denywith $'session=sess-A\ncwd=/some/repo\n' sess-A)"; rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] same-session deny → exit 2"
else FAIL=$((FAIL+1)); echo "  FAIL same-session deny → rc=$rc"; fi
if printf '%s' "$out" | command grep -qF 'Armed by: session sess-A'; then PASS=$((PASS+1)); echo "  ok   same-session deny → shows owner"
else FAIL=$((FAIL+1)); echo "  FAIL same-session deny → missing owner line"; fi
if printf '%s' "$out" | command grep -q 'choose'; then PASS=$((PASS+1)); echo "  ok   same-session deny → keeps original approve guidance"
else FAIL=$((FAIL+1)); echo "  FAIL same-session deny → lost original guidance"; fi
if printf '%s' "$out" | command grep -q 'do not run approve-plan.sh'; then FAIL=$((FAIL+1)); echo "  FAIL same-session deny → wrongly warns off approve-plan.sh"
else PASS=$((PASS+1)); echo "  ok   same-session deny → no foreign-marker warning"; fi

# G2. Marker owned by a DIFFERENT session → warn off approve-plan.sh, tell the agent
# to ask the user; the original "choose Proceed" instruction must NOT appear (it would
# release/promote the WRONG session's plan).
out="$(denywith $'session=sess-A\ncwd=/some/repo\n' sess-B)"; rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] foreign-session deny → exit 2"
else FAIL=$((FAIL+1)); echo "  FAIL foreign-session deny → rc=$rc"; fi
if printf '%s' "$out" | command grep -qF 'Armed by: session sess-A at /some/repo'; then PASS=$((PASS+1)); echo "  ok   foreign-session deny → names owner + cwd"
else FAIL=$((FAIL+1)); echo "  FAIL foreign-session deny → missing owner/cwd"; fi
if printf '%s' "$out" | command grep -q 'do not run approve-plan.sh'; then PASS=$((PASS+1)); echo "  ok   foreign-session deny → warns off approve-plan.sh"
else FAIL=$((FAIL+1)); echo "  FAIL foreign-session deny → missing approve-plan.sh warning"; fi
if printf '%s' "$out" | command grep -q '"Proceed" (which runs approve-plan.sh)'; then FAIL=$((FAIL+1)); echo "  FAIL foreign-session deny → still tells agent to approve"
else PASS=$((PASS+1)); echo "  ok   foreign-session deny → does not suggest approving"; fi

# G3. Empty OWN marker (pre-metadata, no session= line at all — the exact shape
# planted by `: > "$MARKER"` throughout sections A-F above; this is the worktree's
# OWN suffixed marker, not the bare legacy one — see G4 for that) must deny EXACTLY
# like before: exit 2, no attribution lines, original guidance. This is a regression
# guard for a real bug hit while building this: mentor_marker_field's `grep -m1 |
# cut` pipeline returned grep's no-match exit(1) as the function's own exit status
# under `set -o pipefail`; under plan-gate.sh's `set -e`,
# `owner_session="$(mentor_marker_field ...)"` then aborted the WHOLE fail-closed
# hook with exit 1 (not 2) — silently turning a deny into a script crash the harness
# reads as ALLOW.
out="$(denywith '' sess-Z)"; rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] empty OWN marker → exit 2 (not a fail-open crash)"
else FAIL=$((FAIL+1)); echo "  FAIL empty OWN marker → rc=$rc (fail-open regression if 1)"; fi
if printf '%s' "$out" | command grep -q 'Armed by:'; then FAIL=$((FAIL+1)); echo "  FAIL empty OWN marker → fabricated an owner line"
else PASS=$((PASS+1)); echo "  ok   empty OWN marker → no owner line (nothing to attribute)"; fi
if printf '%s' "$out" | command grep -q '"Proceed" (which runs approve-plan.sh)'; then PASS=$((PASS+1)); echo "  ok   empty OWN marker → keeps original approve guidance"
else FAIL=$((FAIL+1)); echo "  FAIL empty OWN marker → lost original guidance"; fi

echo "== G4. Bare LEGACY marker (no worktree suffix) blocks BOTH worktrees, attributed 'Worktree: ALL' =="
rm -f "$MARKER" "$WTB_MARKER"
: > "$LEGACY_MARKER"
run block "$REPO" Write "legacy marker → main blocked"   "$REPO/src/app.ts"
run block "$WTB"  Write "legacy marker → linked blocked" "$WTB/src/app.ts"
out="$(capture_stderr "$REPO" Write "$REPO/src/app.ts")"
if printf '%s' "$out" | command grep -q 'Worktree: ALL'; then PASS=$((PASS+1)); echo "  ok   legacy deny → 'Worktree: ALL' attribution"
else FAIL=$((FAIL+1)); echo "  FAIL legacy deny → missing 'Worktree: ALL' attribution"; fi
rm -f "$LEGACY_MARKER"

echo "== H. Per-worktree scoping: each worktree's own marker denies only ITS OWN worktree =="
rm -f "$MARKER" "$WTB_MARKER" "$LEGACY_MARKER"
: > "$MARKER"   # arm main only
run block "$REPO" Write "main armed → main blocked"    "$REPO/src/app.ts"
run allow "$WTB"  Write "main armed → linked allowed"  "$WTB/src/app.ts"
out="$(capture_stderr "$REPO" Write "$REPO/src/app.ts")"
if printf '%s' "$out" | command grep -q 'Worktree:' && printf '%s' "$out" | command grep -q 'scoped to this worktree'; then
  PASS=$((PASS+1)); echo "  ok   own-marker deny → 'Worktree: ... (scoped to this worktree)'"
else FAIL=$((FAIL+1)); echo "  FAIL own-marker deny → missing scoped Worktree: line"; fi
rm -f "$MARKER"

: > "$WTB_MARKER"   # arm linked only
run allow "$REPO" Write "linked armed → main allowed"    "$REPO/src/app.ts"
run block "$WTB"  Write "linked armed → linked blocked"  "$WTB/src/app.ts"

: > "$MARKER"       # both armed
run block "$REPO" Write "both armed → main blocked"    "$REPO/src/app.ts"
run block "$WTB"  Write "both armed → linked blocked"  "$WTB/src/app.ts"
rm -f "$MARKER" "$WTB_MARKER"

echo "== I. Stale own marker self-heals without disturbing a LIVE sibling marker =="
: > "$WTB_MARKER"   # sibling stays live throughout
: > "$MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$MARKER" 2>/dev/null || true
run allow "$REPO" Write "stale own heals → main opens" "$REPO/src/app.ts"
if [ ! -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   stale own marker self-healed (removed)"
else FAIL=$((FAIL+1)); echo "  FAIL stale own marker still present"; fi
if [ -f "$WTB_MARKER" ]; then PASS=$((PASS+1)); echo "  ok   live sibling marker untouched by own-marker heal"
else FAIL=$((FAIL+1)); echo "  FAIL live sibling marker was disturbed"; fi
# The sibling's own gate is unaffected by main's heal — still armed for the linked worktree.
run block "$WTB" Write "sibling gate still armed after main's heal" "$WTB/src/app.ts"
rm -f "$WTB_MARKER"

echo "== J. own-live + legacy-stale → deny still fires, AND the stale legacy self-heals with its own notice =="
rm -f "$MARKER" "$WTB_MARKER" "$LEGACY_MARKER"
: > "$MARKER"   # own, live
: > "$LEGACY_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$LEGACY_MARKER" 2>/dev/null || true
# ONE hook invocation only: capture BOTH stdout+stderr merged (the heal notice is a
# plain `echo` on stdout; the deny message is on stderr) and the exit code from the
# SAME call — running it twice would let the first call's self-heal mutate state
# before the second call ever runs, corrupting exactly what this case verifies.
json=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$REPO" "$REPO/src/app.ts")
out="$(printf '%s' "$json" | bash "$HOOK" 2>&1)"; rc=$?
if [ "$rc" = "2" ]; then PASS=$((PASS+1)); echo "  ok   [block] own-live + legacy-stale → still denied"
else FAIL=$((FAIL+1)); echo "  FAIL own-live + legacy-stale → rc=$rc"; fi
if [ -f "$MARKER" ]; then PASS=$((PASS+1)); echo "  ok   own marker still live (not healed — it's not stale)"
else FAIL=$((FAIL+1)); echo "  FAIL own marker was removed"; fi
if [ ! -f "$LEGACY_MARKER" ]; then PASS=$((PASS+1)); echo "  ok   stale legacy marker self-healed (removed)"
else FAIL=$((FAIL+1)); echo "  FAIL stale legacy marker still present"; fi
if count_eq 1 'Stale legacy planning marker' "$out"; then PASS=$((PASS+1)); echo "  ok   stale legacy heal printed its own named notice"
else FAIL=$((FAIL+1)); echo "  FAIL missing/duplicated stale-legacy heal notice: $out"; fi
rm -f "$MARKER" "$LEGACY_MARKER"

echo '== K. Running plan and verdict tool admissions =='
managed="$PLANS_DIR/guarded"
mkdir -p "$managed/verdicts"
printf '{"state":"in_progress"}\n' > "$managed/.state.json"
printf '# Managed\n' > "$managed/plan.md"
printf 'slug=guarded\nstarted=fixture\n' > "$repo_root/.mentor/.run-old-owner"
for artifact in plan.md verdicts/step-1.md step-1-verify.md topic-1-verify.md goal-verify.md; do
  run block "$WTB" Edit "foreign session denied $artifact" "$managed/$artifact" fork
  run allow "$REPO" Write "owner admitted $artifact" "$managed/$artifact" old-owner
done
run block "$ROOT" Write 'foreign tool cwd outside target repo is still denied' "$managed/plan.md" fork
run allow "$WTB" Write 'independent worktree source remains available' "$WTB/src/app.ts" builder
run allow "$WTB" Write 'evidence remains available' "$managed/evidence/probe.txt" builder
if (cd "$REPO" && CLAUDE_CODE_SESSION_ID=new-owner bash "$(dirname "$HOOK")/plan-state.sh" begin-run guarded --takeover) >/dev/null 2>&1; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  printf 'FAIL explicit transfer of guarded fixture\n'
fi
run block "$REPO" Edit 'old owner denied a new admission after transfer' "$managed/plan.md" old-owner
run allow "$REPO" Edit 'replacement owner admitted after transfer' "$managed/plan.md" new-owner

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
