#!/usr/bin/env bash
# test-approve-plan.sh — regression tests for approve-plan.sh.
#
# Contract: release the .planning gate ONLY when a non-empty Markdown plan
# exists that is NEWER than the marker (i.e. written this planning session).
# --deliver prints its directive (still printed when the gate is already
# open); unknown flags,
# including the retired --handoff (v4.2.0), are rejected before the marker is
# touched.
#
# v2.23.0 (worktree-scoped plan gate): the marker is now per-worktree —
# `.planning.<wt-id>` — with a bare legacy `.planning` reserved as a
# repo-wide fallback that only its own arming session may approve through.
# Ownership (sidecar `owner`/`owner_session`) scopes approval to THIS
# worktree's plans (or unowned ones, while no sibling worktree is planning);
# a live sibling marker excludes unowned plans too, reported by name rather
# than silently swept or silently dropped. MARKER below is retargeted to
# this (the "A") worktree's OWN suffixed marker; a second, linked worktree
# ("B", $WTB) exercises the cross-worktree cases.
#
# Section Q drives begin-plan.sh <slug>: an approved/in_progress plan owned by
# this worktree (or unowned) prints ALREADY APPROVED and writes no marker;
# foreign-owned or draft plans arm as before.
#
# Runs against a SANDBOX $HOME so it never touches real user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
APPROVE="$HOOKS/approve-plan.sh"
PLANSTATE="$HOOKS/plan-state.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$APPROVE" "$PLANSTATE" "$BEGIN"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }
# shellcheck source=../lib/state.sh
. "$HOOKS/lib/state.sh"   # only for mentor_worktree_id, to derive wt-ids the same way begin-plan.sh does

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-b" -b wtb >/dev/null 2>&1

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
STATE_DIR="$repo_root/.mentor"   # project-scoped, in-repo (v2.0.0)
PLANS_DIR="$STATE_DIR/plans"
WTB="$ROOT/wt-b"
WTA_ID="$(mentor_worktree_id "$REPO")"
WTB_ID="$(mentor_worktree_id "$WTB")"
[ -n "$WTA_ID" ] && [ -n "$WTB_ID" ] || { echo "FATAL: could not derive worktree ids for the fixture repo" >&2; exit 1; }
MARKER="$PLANS_DIR/.planning.${WTA_ID}"    # A's own marker (retargeted from the old bare .planning)
MARKER_B="$PLANS_DIR/.planning.${WTB_ID}"  # B's own marker
LEGACY_MARKER="$PLANS_DIR/.planning"       # reserved legacy repo-global marker
mkdir -p "$PLANS_DIR"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# Every runner below unsets CLAUDE_CODE_SESSION_ID so the ambient session (if any)
# never leaks into a legacy_mode session-match check — sections that need a specific
# session pass it explicitly instead (see apsess/pssess).
ap()     { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$APPROVE" "$@" 2>&1 ); }
ap_b()   { ( cd "$WTB"  && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$APPROVE" "$@" 2>&1 ); }
apsess() { local sess="$1"; shift; ( cd "$REPO" && HOME="$SANDBOX" CLAUDE_CODE_SESSION_ID="$sess" bash "$APPROVE" "$@" 2>&1 ); }
arm() { : > "$MARKER"; }
arm_b() { : > "$MARKER_B"; }
write_complete_plan() { printf '# %s\n\n## Goal check\nVerified result.\n\n## Implementation steps\n1. Do the thing.\n   - Done when: verified.\n' "$2" > "$1"; }
fresh_plan() { sleep 1; mkdir -p "$PLANS_DIR/fixture-plan"; write_complete_plan "$PLANS_DIR/fixture-plan/plan.md" Plan; }
stale_plan() { mkdir -p "$PLANS_DIR/fixture-plan"; printf '# Old plan\n\nfrom last session\n' > "$PLANS_DIR/fixture-plan/plan.md"; }
clear_plans() { rm -rf "$PLANS_DIR"/*/ 2>/dev/null; rm -f "$PLANS_DIR"/*.md; }
sidecar() { jq -r "${2}" "$PLANS_DIR/$1/.state.json" 2>/dev/null; }   # sidecar <slug> <jq filter>
psq() { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$PLANSTATE" "$@" 2>/dev/null ); }
psq_b() { ( cd "$WTB" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$PLANSTATE" "$@" 2>/dev/null ); }
saved_pass() {
  mkdir -p "$PLANS_DIR/$1/verdicts"
  printf 'Verdict: PASS\nGrade: Step %s\n' "$2" > "$PLANS_DIR/$1/verdicts/step-$2.md"
}

echo "== A. No plan → gate stays closed =="
sm plan
clear_plans; arm
out="$(ap)"; rc=$?
chk "no plan → exit 1"                 test "$rc" = "1"
chk "no plan → marker kept"            test -f "$MARKER"
chk "no plan → error message"          sh -c "printf '%s' \"\$0\" | grep -q 'No Markdown plan found'" "$out"

echo "== B. Empty plan → gate stays closed =="
arm; mkdir -p "$PLANS_DIR/fixture-plan"; : > "$PLANS_DIR/fixture-plan/plan.md"
out="$(ap)"; rc=$?
chk "empty plan → exit 1"              test "$rc" = "1"
chk "empty plan → marker kept"         test -f "$MARKER"

echo "== C. Stale prior-session plan (older than marker) → gate stays closed =="
clear_plans
stale_plan
sleep 1; arm   # marker is now NEWER than the plan
out="$(ap)"; rc=$?
chk "stale plan → exit 1"              test "$rc" = "1"
chk "stale plan → marker kept"         test -f "$MARKER"
chk "stale plan → staleness message"   sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"

echo "== D. Fresh plan → gate released =="
arm; fresh_plan
out="$(ap)"; rc=$?
chk "fresh plan → exit 0"              test "$rc" = "0"
chk "fresh plan → marker gone"         test ! -f "$MARKER"
chk "fresh plan → APPROVED message"    sh -c "printf '%s' \"\$0\" | grep -q 'Plan APPROVED'" "$out"
chk "fresh plan → plan path printed"   sh -c "printf '%s' \"\$0\" | grep -q 'fixture-plan/plan.md'" "$out"
chk "fresh plan → run directive" sh -c "printf '%s' \"\$0\" | grep -q 'Run the plan until its Goal check passes'" "$out"
chk "fresh plan → directive names verifier, Verification, Goal check, Done review" sh -c "printf '%s' \"\$0\" | grep -q 'verifier-contract.md' && printf '%s' \"\$0\" | grep -q '## Verification' && printf '%s' \"\$0\" | grep -q '## Goal check' && printf '%s' \"\$0\" | grep -q '## Done review'" "$out"
directive_lines="$(printf '%s\n' "$out" | awk '
  /^Run the plan until its Goal check passes/ { in_directive = 1 }
  in_directive && /^$/ { exit }
  in_directive { count++ }
  END { print count + 0 }
')"
chk "directive-at-most-six-lines: Proceed directive stays a pointer" test "$directive_lines" -le 6
chk "fresh plan, no session id → no run marker" sh -c "! ls '$STATE_DIR'/.run-* >/dev/null 2>&1"
chk "fresh plan → no removed-skill routing" sh -c "! printf '%s' \"\$0\" | grep -qE 'dispatch-agents|Dispatch: skipped|/mentor:handoff|claim'" "$out"

echo "== D2. Legacy flat <slug>.md is ignored by the resolver =="
sleep 1; arm                                                # marker now NEWER than the nested plan
sleep 1; printf '# Flat legacy plan\n' > "$PLANS_DIR/legacy-flat.md"   # newer than marker, but flat
out="$(ap)"; rc=$?
chk "flat newer → still exit 1"        test "$rc" = "1"
chk "flat newer → marker kept"         test -f "$MARKER"
chk "flat newer → staleness message"   sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"
rm -f "$PLANS_DIR/legacy-flat.md" "$MARKER"

echo "== E. Idempotency: gate already open → exit 0, directives still print =="
out="$(ap)"; rc=$?
chk "already open → exit 0"            test "$rc" = "0"
chk "already open → notice"            sh -c "printf '%s' \"\$0\" | grep -q 'already open'" "$out"
chk "already open → run directive" sh -c "printf '%s' \"\$0\" | grep -q 'Run the plan until its Goal check passes'" "$out"
# A re-run of a no-implementation flag must never lose its directive.
out="$(ap --deliver)"; rc=$?
chk "open + --deliver → exit 0"        test "$rc" = "0"
chk "open + --deliver → directive"     sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"

echo "== F. --handoff retired (v4.2.0): usage error, marker untouched =="
arm; fresh_plan
out="$(ap --handoff 2>&1)"; rc=$?
chk "handoff → exit 1"                 test "$rc" = "1"
chk "handoff → marker kept"            test -f "$MARKER"
chk "handoff → usage names --deliver only" sh -c "printf '%s' \"\$0\" | grep -q 'Usage: approve-plan.sh \[--deliver\]'" "$out"
chk "handoff → no hand-off directive"  sh -c "! printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"
rm -f "$MARKER"; clear_plans

echo "== F2. Proceed with a session id writes the run marker; --deliver never does =="
rm -f "$STATE_DIR"/.run-*
arm; fresh_plan
out="$(apsess run-sess-1)"; rc=$?
chk "proceed + session → exit 0"            test "$rc" = "0"
chk "proceed + session → run marker written" test -f "$STATE_DIR/.run-run-sess-1"
chk "..marker names the slug"               grep -q '^slug=fixture-plan$' "$STATE_DIR/.run-run-sess-1"
chk "..marker carries started="             grep -q '^started=' "$STATE_DIR/.run-run-sess-1"
chk "..stdout says so"                      sh -c "printf '%s' \"\$0\" | grep -q 'run: marker written'" "$out"
rm -f "$STATE_DIR"/.run-*
arm; fresh_plan
out="$(apsess run-sess-2 --deliver)"; rc=$?
chk "deliver + session → exit 0"            test "$rc" = "0"
chk "deliver + session → NO run marker"     test ! -f "$STATE_DIR/.run-run-sess-2"
rm -f "$STATE_DIR"/.run-*

echo "== G. --deliver: deliverable soft-stop =="
arm; fresh_plan
out="$(ap --deliver)"; rc=$?
chk "deliver → exit 0"                 test "$rc" = "0"
chk "deliver → marker gone"            test ! -f "$MARKER"
chk "deliver → DELIVER-ONLY directive" sh -c "printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
chk "deliver → no handoff/run directive" sh -c "! printf '%s' \"\$0\" | grep -qE '/mentor:handoff|Run the plan until'" "$out"
# deliver with a stale plan: validation precedes the directive.
clear_plans
stale_plan; sleep 1; arm
out="$(ap --deliver)"; rc=$?
chk "deliver(stale) → exit 1"          test "$rc" = "1"
chk "deliver(stale) → marker kept"     test -f "$MARKER"
chk "deliver(stale) → no directive"    sh -c "! printf '%s' \"\$0\" | grep -q 'DELIVER-ONLY'" "$out"
# A legacy .mentor/config.json "mode": "plan-only" key is never read: a plain approve
# never soft-stops.
printf '{"mode":"plan-only"}\n' > "$STATE_DIR/config.json"
arm; fresh_plan
out="$(ap)"; rc=$?
chk "legacy plan-only key + no-arg → exit 0"      test "$rc" = "0"
chk "legacy plan-only key + no-arg → no soft-stop" sh -c "! printf '%s' \"\$0\" | grep -qE 'DELIVER-ONLY|PLAN-ONLY MODE'" "$out"
rm -f "$STATE_DIR/config.json"

echo "== H. Unknown flag → rejected before touching the marker =="
arm; fresh_plan
out="$(ap --bogus)"; rc=$?
chk "bogus flag → exit 1"              test "$rc" = "1"
chk "bogus flag → marker kept"         test -f "$MARKER"
chk "bogus flag → usage printed"       sh -c "printf '%s' \"\$0\" | grep -q 'Usage:'" "$out"
rm -f "$MARKER"

echo "== I. Non-repo cwd → exit 1 =="
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"
rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$APPROVE" >/dev/null 2>&1 ) || rc=$?
chk "non-repo → exit 1"                test "$rc" = "1"

echo "== J. Plan state: every approval path promotes, and only THIS session's plans =="
# The bug this section guards: approve-plan.sh deletes the marker, and both
# `[ a -nt b ]` and `find -newer b` are TRUE when b is gone. Asking "which plans are
# newer than the marker" AFTER the release would stamp every plan dir in the repo.
st()  { psq list | awk -v s="$1" '$3 == s { print $2 }'; }   # $2 STATE · $3 PLAN
newplan() { sleep 1; mkdir -p "$PLANS_DIR/$1"; write_complete_plan "$PLANS_DIR/$1/plan.md" "$1"; psq init "$1" >/dev/null; }

clear_plans; rm -f "$MARKER"
# A months-old plan dir. It must survive every approve below untouched.
mkdir -p "$PLANS_DIR/ancient"; printf '# ancient\n' > "$PLANS_DIR/ancient/plan.md"
touch -t 202501010000 "$PLANS_DIR/ancient/plan.md"

arm; newplan this-session
out="$(ap)"
chk "no-arg approve promotes this session's plan" test "$(st this-session)" = "approved"
chk "months-old plan NOT promoted"                test "$(st ancient)" = "unknown"
chk "approve reports the promotion"    sh -c "printf '%s' \"\$0\" | grep -q 'state: approved'" "$out"

# A split parent's plan.md is ALSO newer than the marker — it must not flip back.
arm; newplan split-parent; newplan split-kid
psq set split-parent superseded >/dev/null
psq init split-kid --group split-parent --order 1 >/dev/null
ap >/dev/null
chk "superseded parent not flipped back"          test "$(st split-parent)" = "superseded"
chk "split child promoted"                        test "$(st split-kid)" = "approved"

# --deliver approves too — the flag defers implementation, not approval.
# (A flagged approval left at `draft` reads as "the gate never released" next session.)
arm; newplan delivered
ap --deliver >/dev/null
chk "--deliver promotes to approved"              test "$(st delivered)" = "approved"

# No marker → no snapshot → nothing to promote. This is what stops a re-run from
# stamping the whole repo.
rm -f "$MARKER"; newplan gate-open
out="$(ap)"
chk "gate already open → nothing promoted"        test "$(st gate-open)" = "draft"
# Silence here is indistinguishable from a plugin too old to have the promotion block
# at all — which is how a plan left at `draft` after a clean-looking approval went
# unnoticed until the next session refused to build it. Every path reports.
chk "gate-open path still reports state"   sh -c "printf '%s' \"\$0\" | grep -q 'state: unchanged'" "$out"

# Marker armed, but every candidate is already approved → nothing to promote, and that
# must say so rather than print nothing.
arm; newplan already-ok
psq set already-ok approved >/dev/null
out="$(ap)"
chk "all-already-approved reports state"   sh -c "printf '%s' \"\$0\" | grep -q 'state: unchanged'" "$out"
chk "already-approved plan stays approved"        test "$(st already-ok)" = "approved"

# The flag path early-exits after its directive — the state line must land BEFORE that.
arm; newplan flagged-d
out="$(ap --deliver)"
chk "--deliver prints the state line"      sh -c "printf '%s' \"\$0\" | grep -q 'state: approved'" "$out"

chk "months-old plan still untouched at the end"  test "$(st ancient)" = "unknown"

echo "== K. deps/group/order survive the promotion write =="

clear_plans; rm -f "$MARKER"
arm; newplan main-plan
# A plan's deps/group/order must survive its promotion — the write path is
# --state approved only. This is the whole reason mentor_plan_state_write went
# flag-style: the old fixed-positional write clobbered these back to defaults on
# every promotion.
arm; newplan survive-fields
psq init survive-fields --group grp-x --order 7 --deps main-plan >/dev/null
out="$(ap)"; rc=$?
chk "ordinary plan with deps/group/order → exit 0" test "$rc" = "0"
chk "ordinary plan promoted"                        test "$(st survive-fields)" = "approved"
chk "deps survive an ordinary promotion"            test "$(sidecar survive-fields '(.deps//[])|join(",")')" = "main-plan"
chk "group survives an ordinary promotion"          test "$(sidecar survive-fields '.group')" = "grp-x"
chk "order survives an ordinary promotion"          test "$(sidecar survive-fields '.order')" = "7"

echo "== L. Ownership matrix: A owns plan-a, B owns plan-b — A's approve promotes plan-a ONLY (v2.23.0) =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/plan-a"; write_complete_plan "$PLANS_DIR/plan-a/plan.md" a; psq init plan-a >/dev/null
mkdir -p "$PLANS_DIR/plan-b"; write_complete_plan "$PLANS_DIR/plan-b/plan.md" b; psq_b init plan-b >/dev/null
chk "plan-a owned by A before approving"           test "$(sidecar plan-a '.owner')" = "$WTA_ID"
chk "plan-b owned by B before approving"           test "$(sidecar plan-b '.owner')" = "$WTB_ID"
out="$(ap)"; rc=$?
chk "A's approve → exit 0"                         test "$rc" = "0"
chk "A's own marker gone"                          test ! -f "$MARKER"
chk "B's marker survives A's approve untouched"    test -f "$MARKER_B"
chk "plan-a promoted"                              test "$(sidecar plan-a '.state')" = "approved"
chk "plan-b stays draft (B's draft survives untouched)" test "$(sidecar plan-b '.state')" = "draft"
chk "plan-b's owner is unchanged (still B)"        test "$(sidecar plan-b '.owner')" = "$WTB_ID"
chk "A's approve output names plan-a"              sh -c "printf '%s' \"\$0\" | grep -q 'plan-a'" "$out"
chk "A's approve output never names plan-b"        sh -c "! printf '%s' \"\$0\" | grep -q 'plan-b'" "$out"
# B's own approve then succeeds on its own plan, independently.
out_b="$(ap_b)"; rc=$?
chk "B's approve → exit 0"                         test "$rc" = "0"
chk "B's marker gone"                              test ! -f "$MARKER_B"
chk "plan-b promoted by B's own approve"           test "$(sidecar plan-b '.state')" = "approved"

echo "== M. Unowned plan + live sibling marker → excluded from newest AND the sweep, reported by name =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/owned-a"; write_complete_plan "$PLANS_DIR/owned-a/plan.md" a; psq init owned-a >/dev/null
mkdir -p "$PLANS_DIR/stray-unowned"; printf '# u\n' > "$PLANS_DIR/stray-unowned/plan.md"   # never init'd — unowned
out="$(ap)"; rc=$?
chk "A's approve, sibling live + unowned present → exit 0"  test "$rc" = "0"
chk "owned-a promoted"                                       test "$(sidecar owned-a '.state')" = "approved"
chk "stray-unowned excluded from the sweep (no sidecar written)" test ! -f "$PLANS_DIR/stray-unowned/.state.json"
chk "approve reports the unowned skip by name"  sh -c "printf '%s' \"\$0\" | grep -q 'unowned, skipped' && printf '%s' \"\$0\" | grep -q 'stray-unowned'" "$out"

echo "== M2. Unowned plan, no sibling live → promoted (solo back-compat); promotion stamps owner =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm
sleep 1
mkdir -p "$PLANS_DIR/solo-unowned"; write_complete_plan "$PLANS_DIR/solo-unowned/plan.md" s   # never init'd — unowned
chk "solo-unowned starts with no owner"      test -z "$(sidecar solo-unowned '.owner')"
out="$(ap)"; rc=$?
chk "solo unowned, no sibling → exit 0"      test "$rc" = "0"
chk "solo unowned → marker gone"             test ! -f "$MARKER"
chk "solo unowned → promoted"                test "$(sidecar solo-unowned '.state')" = "approved"
chk "promotion stamps owner on the previously-unowned plan" test "$(sidecar solo-unowned '.owner')" = "$WTA_ID"

echo "== N. legacy_mode requires session match — matching session gets repo-wide behavior; mismatched/missing refuses, marker untouched =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
{ echo "session=S1"; echo "cwd=/wherever"; } > "$LEGACY_MARKER"
sleep 1
mkdir -p "$PLANS_DIR/legacy-plan"; write_complete_plan "$PLANS_DIR/legacy-plan/plan.md" lp
before_sum="$(cksum "$LEGACY_MARKER")"
out="$(apsess S2)"; rc=$?
chk "mismatched session → exit 1"                test "$rc" = "1"
chk "mismatched session → marker byte-untouched" test "$(cksum "$LEGACY_MARKER")" = "$before_sum"
chk "mismatched session → refusal names it"      sh -c "printf '%s' \"\$0\" | grep -q 'Refusing to approve through the legacy plan gate'" "$out"
out="$(ap)"; rc=$?   # ap() unsets CLAUDE_CODE_SESSION_ID — missing session
chk "missing session → exit 1"                   test "$rc" = "1"
chk "missing session → marker byte-untouched"    test "$(cksum "$LEGACY_MARKER")" = "$before_sum"
out="$(apsess S1)"; rc=$?
chk "matching session → exit 0"                  test "$rc" = "0"
chk "matching session → legacy marker gone"      test ! -f "$LEGACY_MARKER"
chk "matching session → repo-wide release message" sh -c "printf '%s' \"\$0\" | grep -q 'legacy repo-wide gate released'" "$out"
chk "matching session → legacy-plan promoted"    test "$(sidecar legacy-plan '.state')" = "approved"

echo "== O. Own marker released while a live legacy exists → warn printed, legacy kept =="
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
{ echo "session=S1"; echo "cwd=/other"; } > "$LEGACY_MARKER"
arm
sleep 1
mkdir -p "$PLANS_DIR/own-and-legacy"; write_complete_plan "$PLANS_DIR/own-and-legacy/plan.md" x; psq init own-and-legacy >/dev/null
out="$(ap)"; rc=$?
chk "own approve while legacy live → exit 0"     test "$rc" = "0"
chk "own marker released"                        test ! -f "$MARKER"
chk "legacy marker kept (not deleted)"           test -f "$LEGACY_MARKER"
chk "warns the legacy marker is still live"      sh -c "printf '%s' \"\$0\" | grep -q 'legacy repo-wide marker is still live'" "$out"
chk "own-and-legacy still promoted"              test "$(sidecar own-and-legacy '.state')" = "approved"
rm -f "$LEGACY_MARKER"

echo "== P. Owned-filter validation failures print the ownership wording, never the false 'No Markdown plan found' =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
sleep 1
mkdir -p "$PLANS_DIR/b-only"; printf '# b\n' > "$PLANS_DIR/b-only/plan.md"; psq_b init b-only >/dev/null
out="$(ap)"; rc=$?
chk "A approve, every candidate foreign-owned → exit 1"  test "$rc" = "1"
chk "A's marker kept"                                     test -f "$MARKER"
chk "names the ownership situation"                       sh -c "printf '%s' \"\$0\" | grep -q 'owned by another worktree'" "$out"
chk "never prints the false 'No Markdown plan found'"     sh -c "! printf '%s' \"\$0\" | grep -q 'No Markdown plan found'" "$out"

echo "== P2. The staleness branch also names the ownership situation when the filter excluded candidates =="
clear_plans; rm -f "$MARKER" "$MARKER_B"
arm; arm_b
mkdir -p "$PLANS_DIR/a-stale"; printf '# old\n' > "$PLANS_DIR/a-stale/plan.md"; psq init a-stale >/dev/null
sleep 1; arm   # re-arm A so a-stale now predates A's marker
mkdir -p "$PLANS_DIR/b-fresh"; printf '# new\n' > "$PLANS_DIR/b-fresh/plan.md"; psq_b init b-fresh >/dev/null
out="$(ap)"; rc=$?
chk "A approve, only-owned plan predates the marker → exit 1" test "$rc" = "1"
chk "staleness message shown"                                  sh -c "printf '%s' \"\$0\" | grep -q 'predates this planning session'" "$out"
chk "ownership situation named too"                             sh -c "printf '%s' \"\$0\" | grep -q 'owned by another worktree'" "$out"

echo "== Q. begin-plan.sh <slug>: an approved/in-progress plan owned here (or unowned) is NOT re-armed =="
# Re-arming would close the gate on a plan already cleared for implementation, with
# nothing newer than the fresh marker left to release it. Foreign-owned and draft plans
# arm exactly as before.
bp()  { ( cd "$REPO" && HOME="$SANDBOX" env -u CLAUDE_CODE_SESSION_ID bash "$BEGIN" "$@" 2>&1 ); }
mkplan() { mkdir -p "$PLANS_DIR/$1"; printf '# Plan %s\n\n1. Do it.\n' "$1" > "$PLANS_DIR/$1/plan.md"; }
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"

mkplan q-own; psq init q-own >/dev/null; psq set q-own approved >/dev/null
out="$(bp q-own)"; rc=$?
chk "approved+owned → exit 0"                         test "$rc" = "0"
chk "approved+owned → ALREADY APPROVED line"          sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-own'" "$out"
chk "approved+owned → re-plan hint"                   sh -c "printf '%s' \"\$0\" | grep -q 'plan-state.sh set q-own draft'" "$out"
chk "approved+owned → no marker written"              test ! -e "$MARKER"
chk "approved+owned → not ARMED"                      sh -c "! printf '%s' \"\$0\" | grep -q 'ARMED'" "$out"
# An existing own marker is not touched either (its mtime is the session start).
: > "$MARKER"; touch -t 202001010000 "$MARKER"; before="$(ls -l "$MARKER")"
out="$(bp q-own)"
chk "approved+owned → existing marker untouched"      test "$(ls -l "$MARKER")" = "$before"
rm -f "$MARKER"

psq set q-own in_progress >/dev/null
out="$(bp q-own)"; rc=$?
chk "in_progress+owned → ALREADY APPROVED, exit 0"    sh -c "[ \"\$1\" = 0 ] && printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-own'" "$out" "$rc"
chk "in_progress+owned → no marker written"           test ! -e "$MARKER"

mkplan q-unowned; printf '{"state":"approved"}\n' > "$PLANS_DIR/q-unowned/.state.json"
out="$(bp q-unowned)"
chk "approved+unowned → ALREADY APPROVED"             sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-unowned'" "$out"
chk "approved+unowned → no marker written"            test ! -e "$MARKER"

mkplan q-foreign; psq_b init q-foreign >/dev/null; psq_b set q-foreign approved >/dev/null
out="$(bp q-foreign)"; rc=$?
chk "approved+foreign-owned → arms (exit 0, ARMED)"   sh -c "[ \"\$1\" = 0 ] && printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out" "$rc"
chk "approved+foreign-owned → marker written"         test -f "$MARKER"
chk "approved+foreign-owned → no ALREADY APPROVED"    sh -c "! printf '%s' \"\$0\" | grep -q 'ALREADY APPROVED'" "$out"
rm -f "$MARKER"

# The re-plan hint must actually work on a partly-TICKED plan: ticks advance the
# effective state, so the check keys on the stored one.
mkdir -p "$PLANS_DIR/q-ticked"
printf '# Plan\n\n## Implementation steps\n\n1. One.\n2. Two.\n' > "$PLANS_DIR/q-ticked/plan.md"
saved_pass q-ticked 1
psq init q-ticked >/dev/null; psq set q-ticked approved >/dev/null; psq tick q-ticked 1 >/dev/null
out="$(bp q-ticked)"
chk "approved+ticked 1/2 → ALREADY APPROVED"          sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-ticked'" "$out"
chk "approved+ticked 1/2 → no marker written"         test ! -e "$MARKER"
psq set q-ticked draft >/dev/null
out="$(bp q-ticked)"
chk "after the hint's set draft → arms"               sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "after the hint's set draft → marker written"     test -f "$MARKER"
rm -f "$MARKER"
# Fully ticked: effective state is implemented, past approval — arms as before.
mkdir -p "$PLANS_DIR/q-done"
printf '# Plan\n\n## Implementation steps\n\n1. One.\n' > "$PLANS_DIR/q-done/plan.md"
saved_pass q-done 1
psq init q-done >/dev/null; psq set q-done approved >/dev/null; psq tick q-done 1 >/dev/null
out="$(bp q-done)"
chk "approved but fully ticked → arms"                sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
rm -f "$MARKER"
# Stored in_progress + fully ticked: the run still owes Verification, Goal check, Done
# review and delivery — resume it (After Proceed step 6), never re-arm.
mkdir -p "$PLANS_DIR/q-run"
printf '# Plan\n\n## Implementation steps\n\n1. One.\n' > "$PLANS_DIR/q-run/plan.md"
saved_pass q-run 1
psq init q-run >/dev/null; psq set q-run in_progress >/dev/null; psq tick q-run 1 >/dev/null
out="$(bp q-run)"; rc=$?
chk "in_progress fully ticked → exit 0"               test "$rc" = "0"
chk "in_progress fully ticked → ALREADY APPROVED"     sh -c "printf '%s' \"\$0\" | grep -q '^ALREADY APPROVED: q-run'" "$out"
chk "in_progress fully ticked → step-6 resume clause" sh -c "printf '%s' \"\$0\" | grep -q 'resume at After Proceed step 6'" "$out"
chk "in_progress fully ticked → no marker written"    test ! -e "$MARKER"
: > "$MARKER"; touch -t 202001010000 "$MARKER"; before="$(ls -l "$MARKER")"
out="$(bp q-run)"
chk "in_progress fully ticked → marker untouched"     test "$(ls -l "$MARKER")" = "$before"
rm -f "$MARKER"
psq set q-run draft >/dev/null
out="$(bp q-run)"
chk "in_progress fully ticked, set draft → arms"      sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
rm -f "$MARKER"

mkplan q-draft; psq init q-draft >/dev/null
out="$(bp q-draft)"
chk "draft → arms"                                    sh -c "printf '%s' \"\$0\" | grep -q 'Plan phase ARMED'" "$out"
chk "draft → marker written"                          test -f "$MARKER"
chk "draft → no ALREADY APPROVED"                     sh -c "! printf '%s' \"\$0\" | grep -q 'ALREADY APPROVED'" "$out"
rm -f "$MARKER"

echo "== R. Approval re-anchors the run after mentor writes and ticks =="
output_has() { printf '%s\n' "$out" | grep -Fqx -- "$1"; }
output_lacks() { ! printf '%s\n' "$out" | grep -Fq -- "$1"; }
change_notice='plan.md changed since mentor last wrote it — read it before editing it further'
tick_instruction='tick each step with `plan-state.sh tick` after saving verdicts/step-N.md → PASS row → record-write'
clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
arm; sleep 1
mkdir -p "$PLANS_DIR/anchor-run"
cat > "$PLANS_DIR/anchor-run/plan.md" <<'EOF'
# Approval anchor

## Goal check
The change is verified.

## Implementation steps

1. Record the finding
   - Done when: finding recorded.
2. Build the change
   - Done when: change verified.
EOF
psq init anchor-run >/dev/null
psq record-write anchor-run >/dev/null
saved_pass anchor-run 1
psq tick anchor-run 1 >/dev/null
before_plan="$(cksum "$PLANS_DIR/anchor-run/plan.md")"
before_hash="$(sidecar anchor-run '.plan_sha256')"
out="$(ap)"; rc=$?
chk "anchor after mentor write + tick → exit 0" test "$rc" = "0"
chk "anchor → resolved plan path printed" output_has "  plan: $PLANS_DIR/anchor-run/plan.md"
chk "anchor → first unticked step number and title" output_has "  next: step 2/2 — Build the change"
chk "anchor → tick instruction" output_has "  $tick_instruction"
chk "anchor → planning ended and edit gate released" output_has "  planning ended — edit gate released"
chk "mentor record-write + tick → no change notice" output_lacks "$change_notice"
chk "approval → plan.md byte-untouched" test "$(cksum "$PLANS_DIR/anchor-run/plan.md")" = "$before_plan"
chk "approval → tracked hash unchanged" test "$(sidecar anchor-run '.plan_sha256')" = "$before_hash"
expected_anchor="$(printf '  plan: %s\n  next: step 2/2 — Build the change\n  planning ended — edit gate released\n  %s' "$PLANS_DIR/anchor-run/plan.md" "$tick_instruction")"
chk "anchor block follows every existing output line" test "$(printf '%s\n' "$out" | tail -n 4)" = "$expected_anchor"

echo "== R2. Outside edits are reported without approval re-baselining =="
arm; sleep 1
printf '\n3. Outside-added step\n   - Done when: extra work verified.\n' >> "$PLANS_DIR/anchor-run/plan.md"
before_plan="$(cksum "$PLANS_DIR/anchor-run/plan.md")"
out="$(ap)"; rc=$?
chk "outside edit → approval still exits 0" test "$rc" = "0"
chk "outside edit → change notice printed" output_has "  $change_notice"
chk "outside edit → fresh step total read from disk" output_has "  next: step 2/3 — Build the change"
chk "outside edit → approval leaves plan.md untouched" test "$(cksum "$PLANS_DIR/anchor-run/plan.md")" = "$before_plan"
chk "outside edit → approval preserves old tracked hash" test "$(sidecar anchor-run '.plan_sha256')" = "$before_hash"
chk "outside edit → drift remains changed after approval" test "$(psq drift anchor-run)" = "changed"

echo "== R3. --deliver re-anchors without starting implementation =="
arm; sleep 1
printf '\nMentor recorded a finding.\n' >> "$PLANS_DIR/anchor-run/plan.md"
psq record-write anchor-run >/dev/null
out="$(apsess anchor-deliver --deliver)"; rc=$?
chk "deliver anchor → exit 0" test "$rc" = "0"
chk "deliver anchor → path printed" output_has "  plan: $PLANS_DIR/anchor-run/plan.md"
chk "deliver anchor → gate-released line" output_has "  planning ended — edit gate released"
chk "deliver anchor → no next-step line" output_lacks "next:"
chk "deliver anchor → no tick instruction" output_lacks "$tick_instruction"
chk "deliver mentor record-write → no change notice" output_lacks "$change_notice"
chk "deliver anchor → no run marker" test ! -f "$STATE_DIR/.run-anchor-deliver"
expected_anchor="$(printf '  plan: %s\n  planning ended — edit gate released' "$PLANS_DIR/anchor-run/plan.md")"
chk "deliver anchor block is last" test "$(printf '%s\n' "$out" | tail -n 2)" = "$expected_anchor"

echo "== R4. Fully ticked steps never invent another step =="
saved_pass anchor-run 2
saved_pass anchor-run 3
psq tick anchor-run 2 >/dev/null
psq tick anchor-run 3 >/dev/null
out="$(ap)"; rc=$?
chk "all ticked → approval exits 0" test "$rc" = "0"
chk "all ticked → names completed steps" output_has "  next: all steps ticked"
chk "all ticked → no phantom next step" output_lacks "next: step"
chk "mentor ticks → no change notice" output_lacks "$change_notice"

echo "== R5. Already-open gate uses its existing repo-wide newest candidate =="
sleep 1
mkdir -p "$PLANS_DIR/foreign-newest"
printf '# Foreign plan\n\n## Implementation steps\n\n### 1. Freshly read title\n' > "$PLANS_DIR/foreign-newest/plan.md"
psq_b init foreign-newest >/dev/null
out="$(ap)"; rc=$?
chk "open gate anchor → exit 0" test "$rc" = "0"
chk "open gate → retains repo-wide candidate warning" output_has "  plan (repo-wide newest, may not be yours): $PLANS_DIR/foreign-newest/plan.md"
chk "open gate anchor → names the same candidate" output_has "  plan: $PLANS_DIR/foreign-newest/plan.md"
chk "open gate anchor → reads candidate's first step and title" output_has "  next: step 1/1 — Freshly read title"
chk "legacy unknown hash → no change notice" output_lacks "$change_notice"
chk "approval never establishes a missing hash" test "$(psq drift foreign-newest)" = "unknown"
chk "open gate anchor → tick instruction still printed" output_has "  $tick_instruction"
out="$(ap --deliver)"
chk "open gate deliver anchor → path printed" output_has "  plan: $PLANS_DIR/foreign-newest/plan.md"
chk "open gate deliver anchor → gate-released line" output_has "  planning ended — edit gate released"
chk "open gate deliver anchor → no next-step line" output_lacks "next:"
chk "open gate deliver anchor → no tick instruction" output_lacks "$tick_instruction"

echo "== R6. Missing steps and missing plan keep successful approval paths =="
clear_plans
mkdir -p "$PLANS_DIR/skeleton"
printf '# Skeleton\n\n## Research notes\n\nFinding.\n' > "$PLANS_DIR/skeleton/plan.md"
out="$(ap)"; rc=$?
chk "no steps → approval exits 0" test "$rc" = "0"
chk "no steps → next is drafting" output_has "  next: drafting"
clear_plans
out="$(ap)"; rc=$?
chk "open gate without a plan → still exits 0" test "$rc" = "0"
chk "no plan → explicit path fallback" output_has "  plan: (no plan file on record)"
chk "no plan → no change notice" output_lacks "$change_notice"

echo "== S. Non-primary approval sweep leaves incomplete research unchanged =="
sweep_plan() { # <slug> <stored-state-or-unknown> <offset-after-gate> <body>
  local dir="$PLANS_DIR/$1"
  mkdir -p "$dir"
  printf '%s\n' "$4" > "$dir/plan.md"
  jq -nc --arg state "$2" --arg owner "$WTA_ID" \
    '{owner:$owner,note:"research remains recoverable",extra:42} +
     (if $state == "unknown" then {} else {state:$state} end)' > "$dir/.state.json"
  python3 - "$dir/plan.md" "$MARKER" "$3" <<'PY'
import os, sys
stamp = os.stat(sys.argv[2]).st_mtime + int(sys.argv[3])
os.utime(sys.argv[1], (stamp, stamp))
PY
}
sidecar_snapshot() {
  python3 - "$PLANS_DIR/$1/.state.json" <<'PY'
import hashlib, os, sys
path = sys.argv[1]
stat = os.stat(path)
with open(path, 'rb') as source:
    print(stat.st_ino, stat.st_mtime_ns, hashlib.sha256(source.read()).hexdigest())
PY
}
complete_body=$'# Completed plan\n\n## Implementation steps\n1. Build the change\n   - Done when: verified.\n\n## Goal check\nVerified result.'
for approval in proceed deliver; do
  clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER"
  arm
  python3 - "$MARKER" <<'PY'
import os, sys, time
stamp = time.time() - 60
os.utime(sys.argv[1], (stamp, stamp))
PY
  sweep_plan abandoned draft 10 $'# Abandoned skeleton\n\n## Research notes\nFinding.'
  sweep_plan missing-goal unknown 20 $'# Missing Goal check\n\n## Implementation steps\n1. Build work\n   - Done when: verified.'
  sweep_plan missing-steps draft 30 $'# Missing parsed steps\n\n1. Numbered research outside implementation.\n\n## Implementation steps\nResearch is still in progress.\n\n## Goal check\nVerified result.'
  sweep_plan secondary draft 40 "$complete_body"
  sweep_plan unknown-secondary unknown 45 "$complete_body"
  sweep_plan primary draft 50 "$complete_body"
  before_abandoned="$(sidecar_snapshot abandoned)"
  before_goal="$(sidecar_snapshot missing-goal)"
  before_steps="$(sidecar_snapshot missing-steps)"
  if [ "$approval" = deliver ]; then out="$(ap --deliver)"; rc=$?
  else out="$(ap)"; rc=$?; fi
  chk "$approval + completed primary → approval succeeds" test "$rc" = 0
  chk "$approval → primary promoted" test "$(sidecar primary '.state')" = approved
  chk "$approval → gate released" test ! -f "$MARKER"
  chk "$approval → abandoned skeleton stays draft" test "$(sidecar abandoned '.state')" = draft
  chk "$approval → abandoned skeleton sidecar unchanged" test "$(sidecar_snapshot abandoned)" = "$before_abandoned"
  chk "$approval → missing Goal check sidecar unchanged" test "$(sidecar_snapshot missing-goal)" = "$before_goal"
  chk "$approval → missing parsed steps sidecar unchanged" test "$(sidecar_snapshot missing-steps)" = "$before_steps"
  skipped="$(printf '%s\n' "$out" | grep 'state: incomplete, skipped')"
  for slug in abandoned missing-goal missing-steps; do
    chk "$approval → reports $slug as incomplete" bash -c '[[ "$1" == *"$2"* ]]' _ "$skipped" "$slug"
  done
  chk "$approval → completed secondary still promoted" test "$(sidecar secondary '.state')" = approved
  chk "$approval → completed unknown secondary still promoted" test "$(sidecar unknown-secondary '.state')" = approved
  chk "$approval → completed secondary keeps sweep-review note" \
    bash -c '[[ "$1" == *"not individually reviewed"* ]]' _ "$(sidecar secondary '.note')"
  chk "$approval → incomplete reporting retains original plan path" output_has "  plan: $PLANS_DIR/primary/plan.md"
done

echo "== T. Primary approval skips newer incomplete plans and refuses skeleton-only sessions =="
for approval in proceed deliver; do
  clear_plans; rm -f "$MARKER" "$MARKER_B" "$LEGACY_MARKER" "$STATE_DIR/.run-primary-selection"
  arm
  sweep_plan completed draft 10 "$complete_body"
  sweep_plan abandoned draft 20 $'# Newer skeleton\n\n## Research notes\nFinding.'
  sweep_plan newest-empty draft 30 ''
  before_abandoned="$(sidecar_snapshot abandoned)"
  before_empty="$(sidecar_snapshot newest-empty)"
  if [ "$approval" = deliver ]; then out="$(apsess primary-selection --deliver)"; rc=$?
  else out="$(apsess primary-selection)"; rc=$?; fi
  chk "$approval + newer skeletons → newest complete primary succeeds" test "$rc" = 0
  chk "$approval + newer skeletons → names complete primary" output_has "  plan: $PLANS_DIR/completed/plan.md"
  chk "$approval + newer skeletons → primary promoted" test "$(sidecar completed '.state')" = approved
  chk "$approval + newer skeletons → gate released" test ! -f "$MARKER"
  chk "$approval + newer skeletons → research sidecar untouched" test "$(sidecar_snapshot abandoned)" = "$before_abandoned"
  chk "$approval + newer skeletons → empty draft sidecar untouched" test "$(sidecar_snapshot newest-empty)" = "$before_empty"
  skipped="$(printf '%s\n' "$out" | grep 'state: incomplete, skipped')"
  for slug in abandoned newest-empty; do
    chk "$approval + newer skeletons → reports $slug incomplete" bash -c '[[ "$1" == *"$2"* ]]' _ "$skipped" "$slug"
  done
  if [ "$approval" = proceed ]; then
    chk "proceed + newer skeletons → run marker names complete primary" grep -qx 'slug=completed' "$STATE_DIR/.run-primary-selection"
  else
    chk "deliver + newer skeletons → no run marker" test ! -f "$STATE_DIR/.run-primary-selection"
  fi

  clear_plans; rm -f "$STATE_DIR/.run-primary-selection"; arm
  sweep_plan skeleton draft 10 $'# Skeleton\n## Research notes\nFinding.'
  sweep_plan missing-goal unknown 20 $'# No goal\n## Implementation steps\n1. Build'
  sweep_plan missing-steps draft 30 $'# No steps\n## Goal check\nVerified.\n## Implementation steps\nStill researching.'
  before_gate="$(cksum "$MARKER")"
  before_sidecars="$(cksum "$PLANS_DIR"/*/.state.json)"
  if [ "$approval" = deliver ]; then out="$(apsess primary-selection --deliver)"; rc=$?
  else out="$(apsess primary-selection)"; rc=$?; fi
  chk "$approval + no complete candidate → refuses approval" test "$rc" = 1
  chk "$approval + no complete candidate → gate untouched" test "$(cksum "$MARKER")" = "$before_gate"
  chk "$approval + no complete candidate → promotes nothing" test "$(cksum "$PLANS_DIR"/*/.state.json)" = "$before_sidecars"
  chk "$approval + no complete candidate → no run marker" test ! -f "$STATE_DIR/.run-primary-selection"
  chk "$approval + no complete candidate → explains Step 4" output_lacks 'Plan APPROVED'
  chk "$approval + no complete candidate → finish planning directive" \
    bash -c '[[ "$1" == *"plan not complete — finish planning Step 4"* ]]' _ "$out"
  skipped="$(printf '%s\n' "$out" | grep 'state: incomplete, skipped')"
  for slug in skeleton missing-goal missing-steps; do
    chk "$approval + no complete candidate → reports $slug incomplete" bash -c '[[ "$1" == *"$2"* ]]' _ "$skipped" "$slug"
  done
done

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
