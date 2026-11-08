#!/usr/bin/env bash
# test-plan-state.sh — regression tests for hooks/plan-state.sh (v2.4.0).
#
# Contract:
#   • EFFECTIVE state = the more advanced of the sidecar's state and the state
#     derived from plan.md's ✅ step ticks. No sidecar and no ticks → `unknown`,
#     NEVER `draft` — a plan that shipped months ago was not "never approved".
#   • `init` is idempotent and never LOWERS a state; `set` is an upsert, because
#     most plans predate the sidecar.
#   • Usage errors (unknown subcommand, invalid state, unknown slug) exit 1.
#     Everything environmental (no repo, no plans dir) is fail-soft: exit 0 with a
#     reason line on stderr — silent-empty is indistinguishable from "no plans", and
#     the calling skill would improvise a listing.
#   • `current` skips superseded plans and, inside a split group, reports the whole
#     group instead of silently picking whichever child agent finished last.
#   • v2.23.0 (worktree-scoped plan gate): `gate` reports one of FOUR tokens
#     (ARMED/STALE/ARMED_ELSEWHERE/RELEASED) for THIS worktree, with a per-token
#     `--verbose` field contract; `current` scopes to plans owned by this worktree
#     (or unowned) unless `--any`; `ensure-dir`/`init`/`relocate` stamp sidecar
#     `owner`/`owner_session`; `list --owners` adds a 6th OWNER column.
#   • v5.0.0: every sidecar write MERGES, so a pre-5.0 sidecar's origin/parent/
#     priority/category/deferred_from survive untouched and unread (section K7);
#     the retired subcommands and flags are usage errors, never silent no-ops.
#
# Runs against a SANDBOX $HOME and CLAUDE_CONFIG_DIR so it never touches real user
# state and never finds a real session transcript.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }
# shellcheck source=../lib/state.sh
. "$HOOKS/lib/state.sh"   # only for mentor_worktree_id, to derive wt-ids the same way begin-plan.sh does

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX/.claude/projects/proj"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-b" -b wtb >/dev/null 2>&1
git -C "$REPO" worktree add -q "$ROOT/wt-c" -b wtc >/dev/null 2>&1
BARE="$ROOT/bare-repo"          # a repo that has never planned
git init -q -b main "$BARE" >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

# Second/third linked worktrees of the SAME repo (plans stay shared — one plans/
# dir — but the plan-gate marker is per-worktree, v2.23.0). Ids derived with the
# exact production recipe so a marker suffix here can never drift from what
# begin-plan.sh would actually write.
WTB="$ROOT/wt-b"
WTC="$ROOT/wt-c"
WTA_ID="$(mentor_worktree_id "$REPO")"
WTB_ID="$(mentor_worktree_id "$WTB")"
WTC_ID="$(mentor_worktree_id "$WTC")"
[ -n "$WTA_ID" ] && [ -n "$WTB_ID" ] && [ -n "$WTC_ID" ] || { echo "FATAL: could not derive worktree ids for the fixture repo" >&2; exit 1; }

# A PATH with real `git`/`dirname` but NO jq — for query's fail-soft-without-jq
# check. Only those two externals run before query's own require_jq_read guard
# (mentor_repo_root → git/dirname; everything after is shell builtins), so this
# minimal PATH is enough to prove the guard fires rather than crashing on a missing
# unrelated tool.
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"
ln -s "$(command -v git)" "$NOJQ_DIR/git"
ln -s "$(command -v dirname)" "$NOJQ_DIR/dirname"

trap 'rm -rf "$ROOT"' EXIT

PLANS="$REPO/.mentor/plans"
mkdir -p "$PLANS"

# Marker paths (v2.23.0): one per worktree, plus the reserved legacy repo-global
# bare marker. Sections that exercise `gate` write these directly.
LEGACY_MARKER="$PLANS/.planning"
OWN_MARKER="$PLANS/.planning.${WTA_ID}"
SIB_MARKER="$PLANS/.planning.${WTB_ID}"
SIB_MARKER_C="$PLANS/.planning.${WTC_ID}"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
has()  { printf '%s' "$2" | grep -q -- "$1"; }
hasnt(){ ! printf '%s' "$2" | grep -q -- "$1"; }

# All runners pin HOME + CLAUDE_CONFIG_DIR into the sandbox and drop the context
# env overrides, so a developer's own shell can never change an assertion.
_env() { env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
              -u CLAUDE_CODE_SESSION_ID HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" "$@"; }
ps()    { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>&1 ); }          # merged
psout() { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>/dev/null ); }   # stdout only
pserr() { ( cd "${CWD:-$REPO}" && _env bash "$PLANSTATE" "$@" 2>&1 >/dev/null ); } # stderr only
# Same as ps/psout/pserr but with a PATH where `jq` cannot be found (see NOJQ_DIR).
psq_nojq_out() { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" 2>/dev/null ); }
psq_nojq_err() { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" 2>&1 >/dev/null ); }
psq_nojq_rc()  { ( cd "${CWD:-$REPO}" && _env PATH="$NOJQ_DIR" "$BASH_BIN" "$PLANSTATE" "$@" >/dev/null 2>&1 ); }
# Same as ps(), but with an explicit CLAUDE_CODE_SESSION_ID — for the owner_session
# stamping checks (ps()/psout() deliberately strip it via _env above).
ps_sess() { local sess="$1"; shift
  ( cd "${CWD:-$REPO}" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
        HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID="$sess" bash "$PLANSTATE" "$@" 2>&1 );
}
# Read one field straight off a plan's sidecar (deps/owner — list/current never
# surface these, so the CLI-output assertions above can't reach them).
sidecar() { jq -r "${2}" "$PLANS/$1/.state.json" 2>/dev/null; }   # sidecar <slug> <jq filter>

plan() { # <slug> [body line...]  — create a plan dir with a plan.md
  local slug="$1"; shift
  mkdir -p "$PLANS/$slug"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$PLANS/$slug/plan.md"
  else printf '# %s\n' "$slug" > "$PLANS/$slug/plan.md"; fi
}
saved_pass() { # <slug> <step> — a returned grade saved before a fixture ticks
  mkdir -p "$PLANS/$1/verdicts"
  printf 'Verdict: PASS\nGrade: Step %s\nGrading: independent\n' "$2" > "$PLANS/$1/verdicts/step-$2.md"
}
# `list` columns: $1 ordinal · $2 STATE · $3 PLAN · $4 GROUP · $5 ORDER
state_of() { psout list | awk -v s="$1" '$3 == s { print $2 }'; }
slugs_in_order() { printf '%s' "$1" | awk 'NF && $1 ~ /^[0-9]+$/ { printf "%s ", $3 }'; }

echo "== A. Usage errors exit 1; the marker of a real CLI, not a hook =="
out="$(ps)"; rc=$?
chk "no subcommand → exit 1"            test "$rc" = "1"
chk "no subcommand → usage printed"     has "Usage: plan-state.sh" "$out"
out="$(ps frobnicate)"; rc=$?
chk "unknown subcommand → exit 1"       test "$rc" = "1"
chk "unknown subcommand → names it"     has "Unknown subcommand: frobnicate" "$out"
plan solo
out="$(ps set solo bogus)"; rc=$?
chk "invalid state → exit 1"            test "$rc" = "1"
chk "invalid state → lists valid ones"  has "draft approved in_progress implemented failed superseded" "$out"
out="$(ps set nope approved)"; rc=$?
chk "set unknown slug → exit 1"         test "$rc" = "1"
chk "set unknown slug → points at list" has "plan-state.sh list" "$out"
out="$(ps init nope)"; rc=$?
chk "init unknown slug → exit 1"        test "$rc" = "1"
out="$(ps set)"; rc=$?
chk "set with no slug → exit 1"         test "$rc" = "1"
# v5.0.0: subcommands that served removed skills are gone — a named removal notice,
# never a silent no-op and never the generic "Unknown subcommand" usage dump.
for gone in set-priority set-category set-parent claim brief policy handoff-path handoff-selfcheck; do
  out="$(ps "$gone" solo)"; rc=$?
  chk "$gone (removed) → exit 1, names the v5.0.0 removal" sh -c '[ "$0" = 1 ] && printf "%s" "$1" | grep -q "plan-state.sh: '"'"'$2'"'"' was removed in mentor v5.0.0 — no replacement"' "$rc" "$out" "$gone"
  chk "$gone (removed) → no usage dump" hasnt "Unknown subcommand" "$out"
done
# Retired before v5.0.0 — plain unknown subcommands.
for gone in overview subtree; do
  out="$(ps "$gone" solo)"; rc=$?
  chk "$gone (retired) → exit 1, unknown subcommand" sh -c '[ "$0" = 1 ] && printf "%s" "$1" | grep -q "Unknown subcommand: $2"' "$rc" "$out" "$gone"
done

echo "== B. Effective state derives from the ✅ ticks, so a forgotten set costs nothing =="
plan no-sidecar
plan ticked-all   '# t' '## Implementation steps' '1. **One** ✅' '2. **Two** ✅' '## Verification' '1. unticked, not a step'
plan ticked-some  '# t' '## Implementation steps' '1. **One** ✅' '2. **Two**'
plan ticked-steps '# t' '## Implementation steps' 'Step 1 — one  [role: general-purpose] ✅' 'Step 2 — two  [role: general-purpose] ✅'
plan no-steps     '# t' '## Context' 'nothing to tick here'
chk "no sidecar, no ticks → unknown (never draft)" test "$(state_of no-sidecar)" = "unknown"
chk "every step ticked → implemented"              test "$(state_of ticked-all)" = "implemented"
chk "some steps ticked → in_progress"              test "$(state_of ticked-some)" = "in_progress"
chk "'Step N —' style ticks counted too"           test "$(state_of ticked-steps)" = "implemented"
chk "ticks outside Implementation steps ignored"   test "$(state_of no-steps)" = "unknown"
# The derivation must OUTRANK a stale sidecar, which is the whole point.
ps init ticked-all >/dev/null
chk "stale 'draft' sidecar loses to all-ticked"    test "$(state_of ticked-all)" = "implemented"
# …but never demote a terminal state.
ps set ticked-all superseded >/dev/null
chk "superseded outranks all-ticked"               test "$(state_of ticked-all)" = "superseded"
ps set ticked-some failed --note "typecheck" >/dev/null
chk "failed survives a tick-derived in_progress"   test "$(state_of ticked-some)" = "failed"

echo "== C. init is idempotent and never lowers a state =="
plan idem
ps init idem >/dev/null
chk "init → draft"                      test "$(state_of idem)" = "draft"
ps init idem >/dev/null
chk "init twice → still draft"          test "$(state_of idem)" = "draft"
ps set idem approved >/dev/null
ps init idem >/dev/null
chk "init on an approved plan keeps it" test "$(state_of idem)" = "approved"
ps init idem --group parent --order 4 >/dev/null
out="$(psout list)"
chk "init backfills group/order"        has "idem  *parent  *4" "$out"
ps set idem in_progress >/dev/null
out="$(psout list)"
chk "set preserves group/order"         has "idem  *parent  *4" "$out"

echo "== C2. init re-stamps ownership — last-init-wins (v2.23.0) =="
plan reown
CWD="$WTB"; ps init reown >/dev/null; CWD="$REPO"
chk "reown initially owned by the worktree that inited it (B)" test "$(sidecar reown '.owner')" = "$WTB_ID"
ps init reown >/dev/null   # re-init from A (this worktree) — re-owns
chk "re-init from a different worktree re-owns it (last-init-wins)" test "$(sidecar reown '.owner')" = "$WTA_ID"
ps set reown approved >/dev/null
chk "a plain set leaves ownership exactly as it was" test "$(sidecar reown '.owner')" = "$WTA_ID"


echo "== D. set upserts onto a sidecar-less plan (the majority path on upgrade) =="
plan upsert
chk "no sidecar to begin with"          test ! -f "$PLANS/upsert/.state.json"
out="$(ps set upsert approved)"; rc=$?
chk "set on sidecar-less plan → exit 0" test "$rc" = "0"
chk "set on sidecar-less plan → wrote"  test -f "$PLANS/upsert/.state.json"
chk "set on sidecar-less plan → state"  test "$(state_of upsert)" = "approved"
chk "set reports the transition"        has "unknown → approved" "$out"
# A corrupt sidecar must be repairable, not permanently unwritable.
printf 'not json at all' > "$PLANS/upsert/.state.json"
chk "corrupt sidecar reads unknown"     test "$(state_of upsert)" = "unknown"
ps set upsert approved >/dev/null
chk "corrupt sidecar is repaired"       test "$(state_of upsert)" = "approved"

echo "== E. The note is replaced every time, so a stale failure reason cannot linger =="
plan noted
ps set noted failed --note "typecheck failed in invoice.ts" >/dev/null
chk "note stored"     sh -c "grep -q 'typecheck failed in invoice.ts' '$PLANS/noted/.state.json'"
ps set noted in_progress >/dev/null
chk "plain set clears the note" sh -c "! grep -q 'typecheck failed' '$PLANS/noted/.state.json'"

echo "== F. list: grouped, ordered, terminal states last =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan parent; plan kid-a; plan kid-b; plan kid-c; plan standalone; plan ancient
ps init parent >/dev/null
ps init kid-a --group parent --order 1 >/dev/null
ps init kid-b --group parent --order 2 >/dev/null
ps init kid-c --group parent --order 3 >/dev/null
ps init standalone >/dev/null
ps set parent superseded >/dev/null
ps set kid-a implemented >/dev/null
ps set standalone approved >/dev/null
out="$(psout list)"
order="$(slugs_in_order "$out")"
chk "group ordered by 'order', terminals last" test "$order" = "kid-a kid-b kid-c standalone ancient parent "
chk "list prints PLANS_DIR"             has "PLANS_DIR: $PLANS" "$out"
chk "list explains 'unknown'"           has "pre-2.4.0" "$out"
out="$(psout list --group parent)"
sibs="$(slugs_in_order "$out")"
chk "--group filters to the group"      test "$sibs" = "kid-a kid-b kid-c "
chk "--group excludes the parent"       hasnt "superseded" "$out"
out="$(ps list --group)"; rc=$?
chk "bare trailing --group terminates"  test "$rc" = "0"

echo "== G. current: skips superseded, and never silently picks one of N children =="
# parent is the newest by mtime but superseded → must not be "current".
touch "$PLANS/parent/plan.md"
out="$(psout current)"
chk "current skips the superseded parent" hasnt "SLUG: parent" "$out"
# Standalone plan is the answer when it is the newest non-superseded one.
touch "$PLANS/standalone/plan.md"
out="$(psout current)"
chk "current → newest non-superseded"   has "SLUG: standalone" "$out"
chk "current → GROUP: -"                has "GROUP: -" "$out"
chk "current → absolute PLAN path"      has "PLAN: $PLANS/standalone/plan.md" "$out"
# Inside a group, current reports the group and warns off a blind pick.
touch "$PLANS/kid-c/plan.md"
out="$(psout current)"
chk "current in a group → GROUP set"    has "GROUP: parent" "$out"
chk "current in a group → warns"        has "do NOT assume it is the one the user means" "$out"
chk "current in a group → lists siblings" has "kid-b" "$out"
# …and the pick is deterministic: lowest order that is not already done (kid-a is
# implemented), NOT whichever child agent happened to write last.
chk "current in a group → lowest unfinished order" has "SLUG: kid-b" "$out"

echo "== G2. A destroyed sidecar must not drop a child out of its group =="
# Everything the sidecar holds is also in the child's isolation header, so a plan dir
# carrying nothing but plan.md still reads correctly. If this regresses, `current`
# starts handing back finished work.
rm -rf "$PLANS"; mkdir -p "$PLANS"
for i in 1 2 3; do
  mkdir -p "$PLANS/kid-$i"
  cat > "$PLANS/kid-$i/plan.md" <<MD
# Child $i

> [!NOTE]
> **Plan $i of 3** · group \`huge-thing\` · depends on \`kid-1\`
> **Owns:** src/thing-$i/**
> **Does NOT touch:** the rest → \`kid-2\`

## Implementation steps
1. **step**
MD
  ps init "kid-$i" --group huge-thing --order "$i" >/dev/null
  ps set "kid-$i" approved >/dev/null
done
# Finish kid-1, destroy its sidecar, and make it the newest file — the worst case.
printf '# Child 1\n\n> [!NOTE]\n> **Plan 1 of 3** · group `huge-thing`\n\n## Implementation steps\n1. **step** ✅\n' > "$PLANS/kid-1/plan.md"
rm -f "$PLANS/kid-1/.state.json"
sleep 1; touch "$PLANS/kid-1/plan.md"
out="$(psout list)"
chk "sidecar-less child keeps its group" has "kid-1  *huge-thing  *1" "$out"
chk "sidecar-less child keeps its state" test "$(state_of kid-1)" = "implemented"
out="$(psout current)"
chk "current skips the finished sibling" has "SLUG: kid-2" "$out"
chk "current still reports the group"    has "GROUP: huge-thing" "$out"

echo "== G3. current: scoped to this worktree's owned/unowned plans; --any is unfiltered (v2.23.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan cur-a-owned; plan cur-unowned; plan cur-b-owned
ps init cur-a-owned >/dev/null                            # owned by A (this worktree)
CWD="$WTB"; ps init cur-b-owned >/dev/null; CWD="$REPO"    # owned by B
sleep 1; touch "$PLANS/cur-a-owned/plan.md"
sleep 1; touch "$PLANS/cur-unowned/plan.md"
sleep 1; touch "$PLANS/cur-b-owned/plan.md"   # B-owned is now the true mtime-newest
out="$(psout current)"
chk "current (scoped): skips the sibling-owned newest, picks next eligible" has "SLUG: cur-unowned" "$out"
chk "current (scoped): never names the sibling-owned plan"                  hasnt "SLUG: cur-b-owned" "$out"
out="$(psout current --any)"
chk "current --any: unfiltered, reports the true mtime-newest (sibling-owned)" has "SLUG: cur-b-owned" "$out"

rm -rf "$PLANS"; mkdir -p "$PLANS"
plan only-b-owned
CWD="$WTB"; ps init only-b-owned >/dev/null; CWD="$REPO"
out="$(ps current)"; rc=$?
chk "current (scoped), only a sibling-owned plan exists → exit 0" test "$rc" = "0"
chk "current (scoped) → ownership-aware refusal names it"          has "owned by another worktree" "$out"
out="$(ps current --any)"; rc=$?
chk "current --any still finds the sibling-owned plan"             has "SLUG: only-b-owned" "$out"

echo "== H. context: the advisory backstop (context-gate.sh passes slash commands) =="
mktx() { python3 - "$1" "$2" <<'PY'
import json,sys
open(sys.argv[1],"w").write(json.dumps(
  {"type":"assistant","message":{"usage":{"input_tokens":10,
   "cache_read_input_tokens":int(sys.argv[2])-10,"cache_creation_input_tokens":0}}})+"\n")
PY
}
TXDIR="$SANDBOX/.claude/projects/proj"
out="$(ps context)"; rc=$?
chk "no transcript → exit 0"            test "$rc" = "0"
chk "no transcript → UNKNOWN, proceed"  has "CONTEXT: UNKNOWN" "$out"
ctx() { ( cd "$REPO" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
          HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID=sess \
          bash "$PLANSTATE" context 2>&1 ); }
mktx "$TXDIR/sess.jsonl" 400000
out="$(ctx)"; rc=$?
chk "over ask → exit 0"                 test "$rc" = "0"
chk "over ask → CONTEXT: HIGH"          has "CONTEXT: HIGH" "$out"
chk "over ask → proceeds"               has "then proceed" "$out"
# v4.2.0 warn-only: this command must NEVER refuse, ask, or steer toward a handoff —
# being stricter than the gate itself is the bug this guards.
chk "over ask → no handoff suggestion"  hasnt "handoff" "$out"
chk "over ask → no bypass"              hasnt "bypass" "$out"
chk "over ask → no dispatch refusal"    hasnt "Do NOT dispatch" "$out"
mktx "$TXDIR/sess.jsonl" 230000
out="$(ctx)"
chk "over warn → CONTEXT: WARN"         has "CONTEXT: WARN" "$out"
chk "over warn → no HIGH verdict"       hasnt "CONTEXT: HIGH" "$out"
chk "over warn → no handoff suggestion" hasnt "handoff" "$out"
mktx "$TXDIR/sess.jsonl" 50000
out="$( cd "$REPO" && env -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
        HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" CLAUDE_CODE_SESSION_ID=sess \
        bash "$PLANSTATE" context 2>&1 )"
chk "under warn → CONTEXT: OK"          has "CONTEXT: OK" "$out"
out="$( cd "$REPO" && env HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" \
        CLAUDE_CODE_SESSION_ID=sess MENTOR_CONTEXT_GATE=off bash "$PLANSTATE" context 2>&1 )"
chk "kill switch honored → UNKNOWN"     has "CONTEXT: UNKNOWN" "$out"
rm -f "$TXDIR/sess.jsonl"

echo "== I2. dir: pure path derivation, before every guard =="
CWD="$REPO"
out="$(psout dir)"; rc=$?
chk "dir in a repo → exit 0"            test "$rc" = "0"
chk "dir in a repo → <root>/.mentor"    test "$out" = "$REPO/.mentor"
chk "dir --plans → plans dir"           test "$(psout dir --plans)" = "$REPO/.mentor/plans"
CWD="$BARE"
chk "dir in a never-planned repo works" test "$(psout dir)" = "$BARE/.mentor"   # no plans-dir guard
CWD="$NONGIT"
chk "Claude adapter dir outside a repo → CLAUDE_CONFIG_DIR fallback" \
  test "$(psout dir)" = "$SANDBOX/.claude/mentor/_no-repo"
portable_dir="$(cd "$NONGIT" && env -u CLAUDE_CONFIG_DIR -u MENTOR_STATE_HOME \
  HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/xdg-state" bash "$PLANSTATE" dir 2>/dev/null)"
chk "host-neutral dir outside a repo → XDG state fallback" \
  test "$portable_dir" = "$SANDBOX/xdg-state/mentor/_no-repo"
CWD="$REPO"

echo "== I. Environmental problems are fail-soft: exit 0 with ONE reason on stderr =="
CWD="$NONGIT"
out="$(ps list)"; rc=$?
chk "not in a repo → exit 0"            test "$rc" = "0"
chk "not in a repo → says so"           has "Not in a git repo" "$out"
chk "not in a repo → reason on stderr"  test -n "$(pserr list)"
chk "not in a repo → nothing on stdout" test -z "$(psout list)"
out="$(ps current)"; rc=$?
chk "current outside a repo → exit 0"   test "$rc" = "0"
out="$(ps context)"; rc=$?
chk "context outside a repo → exit 0"   test "$rc" = "0"
CWD="$BARE"
out="$(ps list)"; rc=$?
chk "repo with no plans dir → exit 0"   test "$rc" = "0"
chk "repo with no plans dir → says so"  has "No plans dir yet" "$out"
CWD="$REPO"
rm -rf "$PLANS"; mkdir -p "$PLANS"
out="$(ps list)"; rc=$?
chk "empty plans dir → exit 0"          test "$rc" = "0"
chk "empty plans dir → reason"          has "No plans" "$out"
out="$(ps current)"; rc=$?
chk "current with no plans → exit 0"    test "$rc" = "0"
chk "current with no plans → reason (ownership-scoped wording, v2.23.0)" \
  has "No plan owned by this worktree found" "$out"
out="$(ps current --any)"; rc=$?
chk "current --any with no plans → exit 0"   test "$rc" = "0"
chk "current --any with no plans → reason"   has "No plan found" "$out"

echo "== ensure-dir — creates + locks to 700, and refuses to escape the mentor dir =="
# Skills substitute a model-chosen <topic> into these paths, so an unconfined ensure-dir
# would be an arbitrary mkdir-and-chmod primitive reachable straight from a prompt.
ed_mdir="$(ps dir)"
out="$(ps ensure-dir "$ed_mdir/plans/ed-topic/handoffs")"; rc=$?
chk "ensure-dir inside the mentor dir → exit 0"  test "$rc" = "0"
chk "ensure-dir echoes the path"                 has "plans/ed-topic/handoffs" "$out"
chk "ensure-dir created it"                      test -d "$ed_mdir/plans/ed-topic/handoffs"
chk "ensure-dir locked the leaf to 700" \
  test "$(ls -ld "$ed_mdir/plans/ed-topic/handoffs" | cut -c1-10)" = "drwx------"
chk "ensure-dir locked the intermediate too" \
  test "$(ls -ld "$ed_mdir/plans/ed-topic" | cut -c1-10)" = "drwx------"
# The target above (plans/ed-topic/handoffs) is a GRANDCHILD of plans/, not a direct
# child — ownership is stamped on the plan TOPIC dir only (see ensure-dir2 below).
chk "ensure-dir on a nested (non-direct-child) target stamps no owner" \
  test ! -f "$ed_mdir/plans/ed-topic/.state.json"

out="$(ps ensure-dir "$ROOT/escape-me")"; rc=$?
chk "ensure-dir outside the mentor dir → exit 1" test "$rc" = "1"
chk "ensure-dir refusal says so"                 has "refuses a path outside" "$out"
chk "ensure-dir created nothing outside"         test ! -d "$ROOT/escape-me"

out="$(ps ensure-dir "$ed_mdir/plans/../../../escape-dots")"; rc=$?
chk "ensure-dir rejects a .. escape"             test "$rc" = "1"
chk "..-escape created nothing"                  test ! -d "$ROOT/escape-dots"

out="$(ps ensure-dir)"; rc=$?
chk "ensure-dir with no path → exit 1"           test "$rc" = "1"

echo "== ensure-dir2 — a direct child of plans/ gets owner/owner_session stamped (v2.23.0) =="
out="$(ps_sess owner-sess ensure-dir "$ed_mdir/plans/owner-topic")"; rc=$?
chk "ensure-dir (direct child of plans/) → exit 0"  test "$rc" = "0"
chk "ensure-dir stamps owner"                        test "$(sidecar owner-topic '.owner')" = "$WTA_ID"
chk "ensure-dir stamps owner_session"                test "$(sidecar owner-topic '.owner_session')" = "owner-sess"

echo "== J. init --deps (v2.17.0); retired init flags are usage errors (v5.0.0) =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan dep-a; plan dep-b
ps init dep-a >/dev/null
out="$(ps init dep-b --deps dep-a)"; rc=$?
chk "init --deps → exit 0"                  test "$rc" = "0"
chk "init --deps reports deps"              has "deps=dep-a" "$out"
chk "init --deps stored in sidecar"         test "$(sidecar dep-b '(.deps//[])|join(",")')" = "dep-a"
for retired in --deferred "--from x" "--parent dep-a" "--priority high" "--category fix"; do
  # shellcheck disable=SC2086 # word-split on purpose: flag + its value
  out="$(ps init dep-b $retired)"; rc=$?
  chk "init ${retired%% *} (retired) → exit 1"        test "$rc" = "1"
  chk "  …names the unknown flag"                    has "unknown flag ${retired%% *}" "$out"
done
chk "retired flags wrote nothing: deps undisturbed" test "$(sidecar dep-b '(.deps//[])|join(",")')" = "dep-a"
chk "retired flags wrote nothing: no origin key"    test "$(sidecar dep-b 'has("origin")')" = "false"

plan dep-self
out="$(ps init dep-self --deps dep-self --group g)"; rc=$?
chk "init --deps self-cycle → exit 0 (fail-soft)"          test "$rc" = "0"
chk "init --deps self-cycle refused on stderr"              has "dependency cycle" "$out"
chk "init --deps self-cycle: deps NOT set"                  test "$(sidecar dep-self '(.deps//[])|length')" = "0"
chk "init --deps self-cycle: sibling flags still applied"   test "$(sidecar dep-self '.group')" = "g"

echo "== K. set-deps: replace wholesale, cycle-checked, fail-soft =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan sd-a; plan sd-b; plan sd-c
ps init sd-a >/dev/null; ps init sd-b >/dev/null; ps init sd-c >/dev/null
out="$(ps set-deps sd-a sd-b,sd-c)"; rc=$?
chk "set-deps → exit 0"                      test "$rc" = "0"
chk "set-deps reports deps"                  has "deps = sd-b,sd-c" "$out"
chk "set-deps stored wholesale, in order"    test "$(sidecar sd-a '(.deps//[])|join(",")')" = "sd-b,sd-c"

out="$(ps set-deps sd-a sd-a)"; rc=$?
chk "self-cycle → exit 0 (fail-soft)"        test "$rc" = "0"
chk "self-cycle refused on stderr"           has "dependency cycle" "$out"
chk "self-cycle: deps unchanged"             test "$(sidecar sd-a '(.deps//[])|join(",")')" = "sd-b,sd-c"

# Multi-node (2 hops): a→b, then b→a must be refused (closes a→b→a).
plan mn-a; plan mn-b
ps init mn-a >/dev/null; ps init mn-b >/dev/null
ps set-deps mn-a mn-b >/dev/null
out="$(ps set-deps mn-b mn-a)"; rc=$?
chk "2-node multi-node cycle → exit 0 (fail-soft)" test "$rc" = "0"
chk "2-node multi-node cycle refused on stderr"    has "dependency cycle" "$out"
chk "2-node cycle: deps unchanged (empty)"         test "$(sidecar mn-b '(.deps//[])|length')" = "0"

# Multi-node (3 hops): a→b→c, then c→a must also be refused.
plan mn3-a; plan mn3-b; plan mn3-c
ps init mn3-a >/dev/null; ps init mn3-b >/dev/null; ps init mn3-c >/dev/null
ps set-deps mn3-a mn3-b >/dev/null
ps set-deps mn3-b mn3-c >/dev/null
out="$(ps set-deps mn3-c mn3-a)"; rc=$?
chk "3-node cycle → exit 0 (fail-soft)"      test "$rc" = "0"
chk "3-node cycle refused on stderr"         has "dependency cycle" "$out"
chk "3-node cycle: deps unchanged (empty)"   test "$(sidecar mn3-c '(.deps//[])|length')" = "0"

plan unk-x
ps init unk-x >/dev/null
out="$(ps set-deps unk-x does-not-exist)"; rc=$?
chk "unknown dep slug allowed (may be written later)" test "$rc" = "0"
chk "unknown dep slug stored"                          test "$(sidecar unk-x '(.deps//[])|join(",")')" = "does-not-exist"
out="$(ps set-deps unk-x "")"; rc=$?
chk "empty deps clears them → exit 0"        test "$rc" = "0"
chk "empty deps reported as (none)"          has "deps = (none)" "$out"
chk "empty deps → sidecar deps = []"         test "$(sidecar unk-x '(.deps//[])|length')" = "0"

plan note-dep
ps init note-dep >/dev/null
ps set note-dep failed --note "keep me" >/dev/null
ps set-deps note-dep sd-b >/dev/null
chk "set-deps preserves the note"            test "$(sidecar note-dep '.note')" = "keep me"
chk "set-deps preserves the state"           test "$(state_of note-dep)" = "failed"

echo "== K7. a pre-5.0 sidecar keeps origin/parent/priority/category/deferred_from through every write (v5.0.0) =="
plan legacy-sc '# legacy' '## Implementation steps' '1. one' '   - Done when: x'
cat > "$PLANS/legacy-sc/.state.json" <<'JSON'
{"state":"draft","group":null,"order":null,"note":"","deps":[],"origin":"deferred","owner":null,"owner_session":null,"priority":"high","category":"fix","deferred_from":"sd-a","parent":"sd-b"}
JSON
legacy_keys() { jq -cS '{origin, parent, priority, category, deferred_from}' "$PLANS/legacy-sc/.state.json"; }
before_keys="$(legacy_keys)"
ps set legacy-sc approved --note "ok" >/dev/null
chk "set on a legacy sidecar: state lands"      test "$(sidecar legacy-sc '.state')" = "approved"
chk "set on a legacy sidecar: legacy keys kept" test "$(legacy_keys)" = "$before_keys"
ps set-deps legacy-sc sd-c >/dev/null
ps init legacy-sc --group lg >/dev/null
saved_pass legacy-sc 1
ps tick legacy-sc 1 >/dev/null
ps set legacy-sc implemented >/dev/null
chk "set-deps/init/tick/set: managed fields land" \
  test "$(jq -c '[.state, .deps, .group]' "$PLANS/legacy-sc/.state.json")" = '["implemented",["sd-c"],"lg"]'
chk "set-deps/init/tick/set: legacy keys still byte-identical" test "$(legacy_keys)" = "$before_keys"
chk "query does not surface the legacy keys" \
  test "$(psout query --slug legacy-sc | jq -c '.[0] | [has("origin"), has("parent"), has("priority")]')" = '[false,false,false]'

echo "== L2. tick: writes the ✅ a hand-rolled Edit used to place by hand =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
plan tk '# t' '## Implementation steps' \
  'Step 1 — first  [role: general-purpose]' '   Done when: it works' \
  'Step 2 — second  [role: general-purpose]' '   Done when: it also works' \
  '1. **Numbered form**' '2. **Second numbered**' \
  '## Verification' 'Step 1 — prose about verification, not a real step'
for n in 1 2 3 4; do saved_pass tk "$n"; done
chk "before any tick: 0 ticked"          test "$(state_of tk)" = "unknown"
out="$(ps tick tk 1)"; rc=$?
chk "tick step 1 → exit 0"               test "$rc" = "0"
chk "tick step 1 → reports 1/4"          has "step 1 .* ticked (1/4)" "$out"
chk "tick step 1 → plan.md carries ✅ on the Step 1 line, not Done when:" \
  bash -c "sed -n '3p' '$PLANS/tk/plan.md' | grep -q '✅' && ! sed -n '4p' '$PLANS/tk/plan.md' | grep -q '✅'"
chk "tick step 1 → derived state advances"   test "$(state_of tk)" = "in_progress"
out="$(ps tick tk 1)"; rc=$?
chk "re-tick the same step → exit 0 (idempotent)"  test "$rc" = "0"
chk "re-tick reports already-ticked, no write"     has "already ✅" "$out"
out="$(ps tick tk 3)"; rc=$?
chk "tick a numbered-item step → exit 0"           test "$rc" = "0"
chk "numbered-item step ✅ lands on its own line" bash -c "sed -n '7p' '$PLANS/tk/plan.md' | grep -q '✅'"
out="$(ps tick tk 99)"; rc=$?
chk "tick past the last step → exit 1"             test "$rc" = "1"
chk "tick past the last step → names the count"    has "no step 99" "$out"
chk "tick past the last step → no write happened"  test "$(state_of tk)" = "in_progress"
out="$(ps tick tk 0)"; rc=$?
chk "tick step 0 → exit 1"                         test "$rc" = "1"
out="$(ps tick tk abc)"; rc=$?
chk "tick a non-numeric step → exit 1"             test "$rc" = "1"
out="$(ps tick tk 1 extra)"; rc=$?
chk "tick with a stray extra argument → exit 1"    test "$rc" = "1"
out="$(ps tick nope 1)"; rc=$?
chk "tick unknown slug → exit 1"                   test "$rc" = "1"
chk "tick unknown slug → points at list"           has "plan-state.sh list" "$out"
before_verify="$(sed -n '10p' "$PLANS/tk/plan.md")"
chk "the Verification section's own 'Step 1 —' line is never touched" \
  test "$before_verify" = "Step 1 — prose about verification, not a real step"
ps tick tk 2 >/dev/null; ps tick tk 4 >/dev/null
chk "all 4 steps ticked → derived state reaches implemented" test "$(state_of tk)" = "implemented"

echo "== L2b. A new tick requires the latest saved step PASS =="
TV_DIR="$PLANS/tick-verdict"
TV_FILE="$TV_DIR/verdicts/step-1.md"
tv_reset() {
  rm -rf "$TV_DIR"
  plan tick-verdict '# verdict check' '## Implementation steps' '1. First' '2. Second'
  ps init tick-verdict >/dev/null
  ps record-write tick-verdict >/dev/null
  mkdir -p "$TV_DIR/verdicts"
}
tv_refused() { # <case> [expected file]
  local label="$1" file="${2:-$TV_FILE}" before out rc
  before="$(cksum "$TV_DIR/plan.md" "$TV_DIR/.state.json")"
  out="$(ps tick tick-verdict 1)"; rc=$?
  chk "$label → exit 1" test "$rc" = 1
  chk "$label → names the verdict file" has "$file" "$out"
  chk "$label → gives the fix" has "Fix:.*Verdict: PASS.*Step 1.*retry tick" "$out"
  chk "$label → plan and sidecar unchanged" test "$(cksum "$TV_DIR/plan.md" "$TV_DIR/.state.json")" = "$before"
}
tv_accepted() { # <case>
  local out rc
  out="$(ps tick tick-verdict 1)"; rc=$?
  chk "$1 → exit 0" test "$rc" = 0
  chk "$1 → unchanged tick output" test "$out" = '[mentor plan-state] tick-verdict: step 1 ✅ ticked (1/2).'
  chk "$1 → writes the step tick" has '^1\. First ✅$' "$(cat "$TV_DIR/plan.md")"
}

tv_reset
tv_refused 'tick-verdict: missing'
tv_reset; : > "$TV_FILE"
tv_refused 'tick-verdict: empty'
tv_reset; printf 'Verdict PASS\n' > "$TV_FILE"
tv_refused 'tick-verdict: malformed'
tv_reset; printf 'Verdict: FAIL\n' > "$TV_FILE"
tv_refused 'tick-verdict: FAIL'
tv_reset; printf 'Verdict: HANDBACK\n' > "$TV_FILE"
tv_refused 'tick-verdict: HANDBACK'
for grade in 'Step 2' 'Topic 1' 'Goal check' 'PR' 'Step 1 extra'; do
  tv_reset; printf 'Verdict: PASS\nGrade: %s\n' "$grade" > "$TV_FILE"
  tv_refused "tick-verdict: mismatched Grade ($grade)"
done
tv_reset; saved_pass tick-verdict 1
tv_accepted 'tick-verdict: independent PASS'
tv_reset; printf 'Verdict: PASS\nGrade: Step 1\nGrading: self-graded\n' > "$TV_FILE"
tv_accepted 'tick-verdict: self-graded PASS'
tv_reset; printf 'Verdict: PASS\n' > "$TV_DIR/step-1-verify.md"
tv_accepted 'tick-verdict: legacy-path PASS'
tv_reset; printf '<!-- verifier notes -->\n# Check\n\nVerdict: PASS\n' > "$TV_FILE"
tv_accepted 'tick-verdict: comment-offset Verdict PASS'
tv_reset; printf 'Verdict: PASS\ngRaDe: sTeP-1\n' > "$TV_FILE"
tv_accepted 'tick-verdict: case-insensitive step-N Grade PASS'
tv_reset; printf 'Verdict: PASS\nGRADE: sTeP 1\n' > "$TV_FILE"
tv_accepted 'tick-verdict: case-insensitive Step N Grade PASS'
tv_reset; saved_pass tick-verdict 1; ps tick tick-verdict 1 >/dev/null
rm "$TV_FILE"
before="$(cksum "$TV_DIR/plan.md" "$TV_DIR/.state.json")"
out="$(ps tick tick-verdict 1)"; rc=$?
chk 'tick-verdict: already-ticked without verdict → exit 0' test "$rc" = 0
chk 'already-ticked without verdict → no write reported' has 'was already ✅' "$out"
chk 'already-ticked without verdict → plan and sidecar unchanged' test "$(cksum "$TV_DIR/plan.md" "$TV_DIR/.state.json")" = "$before"
tv_reset
printf 'Verdict: PASS\n' > "$TV_DIR/verdicts/step-1-r2.md"
printf 'Verdict: PASS\n' > "$TV_DIR/step-1-verify-r2.md"
tv_refused 'tick-verdict: revision-only PASS rejected'
tv_reset; printf 'Verdict: FAIL\n' > "$TV_FILE"
printf 'Verdict: PASS\n' > "$TV_DIR/step-1-verify.md"
tv_refused 'tick-verdict: canonical FAIL with legacy PASS rejected'
tv_reset; saved_pass tick-verdict 1
printf 'Verdict: FAIL\n' > "$TV_FILE"
tv_refused 'tick-verdict: latest canonical FAIL overwriting prior PASS rejected'
tv_reset; printf 'Verdict: FAIL\nVerdict: PASS\n' > "$TV_FILE"
tv_refused 'tick-verdict: first Verdict wins over later PASS'
tv_reset; printf 'Verdict: PASS | FAIL | HANDBACK\n' > "$TV_FILE"
tv_refused 'tick-verdict: unfilled verdict template rejected'
tv_reset; : > "$TV_FILE"
printf 'Verdict: PASS\n' > "$TV_DIR/step-1-verify.md"
tv_refused 'tick-verdict: empty canonical with legacy PASS rejected'
tv_reset; printf 'Verdict: FAIL\n' > "$TV_DIR/step-1-verify.md"
tv_refused 'tick-verdict: legacy FAIL rejected' "$TV_DIR/step-1-verify.md"

echo "== L3. verify <slug>: plan.md structural checks + folded CONTEXT read =="
# v6: a draft plan must carry ## Goal check + ## Decision log, so every structural
# fixture below gets both appended; their absence is tested on its own in L3c.
vplan() { plan "$@"; printf '%s\n' '' '## Goal check' '`true` exits 0' '' '## Decision log' '' >> "$PLANS/$1/plan.md"; }
rm -rf "$PLANS"; mkdir -p "$PLANS"
vplan vf '# Verify test' '' 'Rev 1: initial draft' 'Rev 2: added scope' '' \
  '## Decisions' '' '| A | B |' '|---|---|' '| 1 | 2 |' '' \
  '```bash' 'echo hi' '```'
out="$(ps verify vf)"; rc=$?
chk "verify (clean plan) → exit 0"                 test "$rc" = "0"
chk "..reports fences balanced"                     has "CHECK: fences balanced (2 markers)" "$out"
chk "..reports tables uniform"                      has "CHECK: tables uniform" "$out"
chk "..reports Rev-note order monotonic"            has "CHECK: Rev-note order monotonic (1,2)" "$out"
chk "..reports a context line (informational)"      has "CHECK: context" "$out"

vplan vf-fence '# t' '```bash' 'echo hi' '```' '```python' 'never closed'
out="$(ps verify vf-fence)"; rc=$?
chk "verify (unbalanced fence) → exit 1"            test "$rc" = "1"
chk "..names the odd marker count"                  has "CHECK: fences UNBALANCED (3 markers" "$out"

vplan vf-table '# t' '| A | B |' '|---|---|' '| 1 | 2 | 3 |'
out="$(ps verify vf-table)"; rc=$?
chk "verify (mismatched table) → exit 1"            test "$rc" = "1"
chk "..names the mismatched line"                   has "CHECK: table pipe-count MISMATCH:" "$out"
chk "..points at the block's start line"            has "line 2: pipe-count mismatch" "$out"

vplan vf-revs '# t' '' 'Rev 3: third' 'Rev 1: first' 'Rev 2: second' '' '## Section'
out="$(ps verify vf-revs)"; rc=$?
chk "verify (non-monotonic Rev order) → still exit 0 (informational only)" test "$rc" = "0"
chk "..reports the non-monotonic sequence"          has "CHECK: Rev-note order NOT monotonic (3,1,2)" "$out"

vplan vf-norevs '# t' 'No Rev headers here at all — the content spec never mandates one.'
out="$(ps verify vf-norevs)"; rc=$?
chk "verify (no Rev lines at all) → exit 0"         test "$rc" = "0"
chk "..prints no Rev-note CHECK line (never a false positive on an unspec'd format)" \
  hasnt "Rev-note order" "$out"

echo "== L3b. verify <slug>: step-structure checks (Done when: GATES; stray ✅ / ### report) =="
vplan vf-steps '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' 'Step 2 — two' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-steps)"; rc=$?
chk "verify (every step body carries a Done when:) → exit 0" test "$rc" = "0"
chk "..reports the step count"                      has "CHECK: step bodies complete (2 step(s)" "$out"

vplan vf-nodw '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' 'Step 2 — no criterion at all' '  Goal: something' '' '## Verification'
out="$(ps verify vf-nodw)"; rc=$?
chk "verify (a step body with no Done when:) → exit 1" test "$rc" = "1"
chk "..flags it as INCOMPLETE"                      has "CHECK: step body INCOMPLETE" "$out"
chk "..names the offending step, not just a count"  has "Step 2 — no criterion at all" "$out"

vplan vf-nosteps '# t' '## Goal' 'A plan not yet fleshed out carries no Implementation steps section.'
out="$(ps verify vf-nosteps)"; rc=$?
chk "verify (no steps section yet) → exit 0" test "$rc" = "0"
chk "..says so rather than reporting zero steps"    has "no ## Implementation steps section" "$out"

vplan vf-stray '# t' '## Implementation steps' '' 'Step 1 — one' '  Inputs: Step 0 output. ✅' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-stray)"; rc=$?
chk "verify (✅ on a non-step line) → exit 0, informational only" test "$rc" = "0"
chk "..reports the tick the counter cannot see"     has "✅ on a non-step line" "$out"

vplan vf-glue '# t' '## Implementation steps' '' 'Step 1 — one' '  Done when: `true` exits 0' '' '### Release' '- ship it' '' '## Verification'
out="$(ps verify vf-glue)"; rc=$?
chk "verify (### inside the steps section) → exit 0, informational only" test "$rc" = "0"
chk "..reports the heading that gets glued on"      has "### heading inside ## Implementation steps" "$out"

# Ties verify to lib/state.sh's `[.]` delimiter (v2.36.0): a wrapped `Inputs:` line
# beginning `48, ` must not read as its own step — under the old `\.` form it did,
# which both inflated the count and stranded the real step's Done when: beneath a
# phantom successor.
vplan vf-wrapped '# t' '## Implementation steps' '' 'Step 1 — one' '  Inputs: rows 7, 17, 42,' '    48, 55, 61, 66); final descriptions.' '  Done when: `true` exits 0' '' '## Verification'
out="$(ps verify vf-wrapped)"; rc=$?
chk "verify (wrapped '48, ' continuation) → exit 0" test "$rc" = "0"
chk "..counts one step, not two"                    has "CHECK: step bodies complete (1 step(s)" "$out"

echo "== L3c. verify <slug>: v6 run sections gate a draft plan only =="
plan vf-nogoal '# t' '## Decision log' ''
out="$(ps verify vf-nogoal)"; rc=$?
chk "verify (draft, no ## Goal check) → exit 1"        test "$rc" = "1"
chk "..names the missing Goal check"                   has "MISSING:.*Goal check" "$out"
plan vf-nolog '# t' '## Goal check' '`true` exits 0'
out="$(ps verify vf-nolog)"; rc=$?
chk "verify (draft, no ## Decision log) → exit 1"      test "$rc" = "1"
chk "..names the missing Decision log"                 has "MISSING:.*Decision log" "$out"
plan vf-legacy '# t' 'A plan written before v6 carries neither section.'
ps set vf-legacy implemented >/dev/null
out="$(ps verify vf-legacy)"; rc=$?
chk "verify (legacy implemented plan, no run sections) → exit 0" test "$rc" = "0"
chk "..says the check was not required"                has "run sections not required" "$out"

echo "== L3d. verify <slug>: traceability reports only for stored drafts =="
vplan vf-untraced '# Traceability' 'Goal: Deliver the requested outcome' \
  '## Implementation steps' \
  '### 1. Untraced work' '- Goal: Optional polish' '- Inputs: example text (serves S1)' \
  '- Done when: `true` exits 0' \
  '### 2. Traced work' '- Goal: Deliver the outcome (serves S1, S2)' \
  '- Done when: `true` exits 0' \
  '### 3. Missing Goal' '- Inputs: example text (serves S1)' \
  '- Done when: `true` exits 0' \
  '## Verification' 'Goal: Outside the steps (serves S1)'
ps init vf-untraced >/dev/null
out="$(ps verify vf-untraced)"; rc=$?
chk "untraced-draft: a missing trace remains informational → exit 0" test "$rc" = "0"
chk "untraced-draft: names the step whose Goal lacks serves S" has '^CHECK: untraced step 1$' "$out"
chk "untraced-draft: a Goal with scenario references is traced" hasnt '^CHECK: untraced step 2$' "$out"
chk "untraced-draft: Inputs and later sections cannot trace a missing Goal" has '^CHECK: untraced step 3$' "$out"

for trace_state in approved in_progress implemented failed superseded; do
  ps set vf-untraced "$trace_state" >/dev/null
  out="$(ps verify vf-untraced)"; rc=$?
  chk "untraced-released: ${trace_state} → exit 0" test "$rc" = "0"
  chk "untraced-released: ${trace_state} skips traceability" hasnt 'CHECK: untraced step' "$out"
done
# A released plan may have no sidecar at all: unknown must not mean draft.
rm -f "$PLANS/vf-untraced/.state.json"
out="$(ps verify vf-untraced)"; rc=$?
chk "untraced-released: no stored state → exit 0" test "$rc" = "0"
chk "untraced-released: no stored state skips traceability" hasnt 'CHECK: untraced step' "$out"

out="$(ps verify)"; rc=$?
chk "verify with no slug → exit 1"                  test "$rc" = "1"
chk "..names the required argument"                 has "a <slug> is required" "$out"

out="$(ps verify nope)"; rc=$?
chk "verify unknown slug → exit 1"                  test "$rc" = "1"
chk "..points at list"                              has "plan-state.sh list" "$out"

mkdir -p "$PLANS/vf-noplanmd"
out="$(ps verify vf-noplanmd)"; rc=$?
chk "verify a plan dir with no plan.md → exit 1"    test "$rc" = "1"
chk "..names the missing file"                      has "no plan.md at" "$out"

out="$(ps verify vf extra)"; rc=$?
chk "verify with a stray extra argument → exit 1"   test "$rc" = "1"

echo "== M. query: the ONE filterable read surface =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
out="$(psout query)"; rc=$?
chk "query on an empty repo → exit 0" test "$rc" = "0"
chk "query on an empty repo → []"     test "$out" = "[]"

plan ov-a '# a' '## Implementation steps' '1. one ✅' '2. two ✅'
ps init ov-a >/dev/null

plan ov-b '# b' '## Implementation steps' '1. one ✅' '2. two'
ps init ov-b >/dev/null
ps set-deps ov-b "ov-a,ov-missing,ov-noplan" >/dev/null

# A dir with NO plan.md: never an entry, but still a PRESENT dep target.
mkdir -p "$PLANS/ov-noplan"

# Two split-group siblings — `--group` is the only filter with a meaningful EMPTY
# value (`--group ""` means "ungrouped"), so it needs both a grouped and an ungrouped
# plan present to be tested at all.
plan ov-g1 '# sibling 1'
plan ov-g2 '# sibling 2'
ps init ov-g1 --group ov-split --order 1 >/dev/null
ps init ov-g2 --group ov-split --order 2 >/dev/null

# A pre-5.0 sidecar carrying retired keys: query must read it, and never echo them.
plan ov-legacy '# legacy'
cat > "$PLANS/ov-legacy/.state.json" <<'JSON'
{"state":"draft","deps":[],"origin":"deferred","parent":"ov-a","priority":"high","category":"fix","deferred_from":"ov-a"}
JSON

out="$(psout query)"; rc=$?
chk "query → exit 0"    test "$rc" = "0"
chk "query → valid JSON" sh -c 'printf "%s" "$0" | jq . >/dev/null 2>&1' "$out"
chk "query → 5 entries (plan dirs with a plan.md only)" test "$(printf '%s' "$out" | jq 'length')" = "5"
chk "every entry is kind plan" test "$(printf '%s' "$out" | jq -r '[.[].kind]|unique|join(",")')" = "plan"
chk "entry shape is exactly the kept fields" \
  test "$(printf '%s' "$out" | jq -c '[.[]|keys]|unique')" = '[["deps","group","kind","order","owner","slug","state","steps"]]'

ov_a="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-a")')"
chk "ov-a: effective state implemented" test "$(printf '%s' "$ov_a" | jq -r '.state')" = "implemented"
chk "ov-a: step counts 2/2"             test "$(printf '%s' "$ov_a" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "2 2 "
chk "ov-a: no deps"                     test "$(printf '%s' "$ov_a" | jq -c '.deps')" = '[]'
chk "ov-a: owner carries this worktree's wt-id (v2.23.0)" test "$(printf '%s' "$ov_a" | jq -r '.owner')" = "$WTA_ID"

ov_b="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-b")')"
chk "ov-b: step counts 1/2"                  test "$(printf '%s' "$ov_b" | jq -r '.steps.ticked,.steps.total' | tr '\n' ' ')" = "1 2 "
chk "ov-b: deps carry every slug, in order"  test "$(printf '%s' "$ov_b" | jq -c '.deps | map(.slug)')" = '["ov-a","ov-missing","ov-noplan"]'
chk "ov-b: known dep marked not missing"     test "$(printf '%s' "$ov_b" | jq -r '.deps[0].missing')" = "false"
chk "ov-b: unknown dep marked missing"       test "$(printf '%s' "$ov_b" | jq -r '.deps[1].missing')" = "true"
chk "ov-b: a dir without plan.md is a present dep, not missing" test "$(printf '%s' "$ov_b" | jq -r '.deps[2].missing')" = "false"

ov_l="$(printf '%s' "$out" | jq -c '.[] | select(.slug=="ov-legacy")')"
chk "ov-legacy: read through the retired keys"   test "$(printf '%s' "$ov_l" | jq -r '.state')" = "draft"
chk "ov-legacy: owner null (none recorded)"      test "$(printf '%s' "$ov_l" | jq -r '.owner')" = "null"

echo "-- M2. filters: each one against an independent jq over the unfiltered array --"
# Every assertion compares `query <filter>` to the same predicate evaluated in jq over
# the FULL array — so a filter that silently returns everything, or nothing, fails.
# `[.[] | (.slug // "-")]`, never `[.[].slug // "-"]`: jq's `//` yields its default when
# the LEFT side produces no outputs at all, so the second form renders an empty result
# as "-" and quietly turns a broken filter into a passing test.
qslugs() { psout query "$@" | jq -r '[.[] | (.slug // "-")] | sort | join(",")'; }
jslugs() { printf '%s' "$out" | jq -r "[.[] | select($1) | (.slug // \"-\")] | sort | join(\",\")"; }
chk "--state draft"            test "$(qslugs --state draft)"        = "$(jslugs '.state=="draft"')"
chk "--state draft,implemented ORs within one flag" \
                               test "$(qslugs --state draft,implemented)" = "$(jslugs '.state|IN("draft","implemented")')"
chk "--open"                   test "$(qslugs --open)"               = "$(jslugs '(.state|IN("implemented","superseded"))|not')"
chk "--closed"                 test "$(qslugs --closed)"             = "$(jslugs '.state|IN("implemented","superseded")')"
chk "--closed is not vacuous"  test "$(qslugs --closed)"             = "ov-a"
chk "--group <name>"           test "$(qslugs --group ov-split)"     = "$(jslugs '.group=="ov-split"')"
chk "--group <name> really selects both siblings" test "$(qslugs --group ov-split)" = "ov-g1,ov-g2"
chk "--group \"\" means UNGROUPED, not unfiltered" \
                               test "$(qslugs --group "")"           = "$(jslugs '.group==null')"
chk "--group \"\" is a strict subset (the grouped siblings are excluded)" \
  sh -c 'case ",$0," in *,ov-g1,*) exit 1 ;; *) exit 0 ;; esac' "$(qslugs --group "")"
chk "--group order field survives the round trip" \
                               test "$(psout query --slug ov-g2 --format tsv --fields order)" = "2"
chk "--owner <this worktree>"  test "$(qslugs --owner "$WTA_ID")"    = "$(jslugs ".owner==\"$WTA_ID\"")"
chk "--unowned"                test "$(qslugs --unowned)"            = "$(jslugs '.owner==null')"
chk "--unowned is not vacuous" test "$(qslugs --unowned)"            = "ov-legacy"
chk "--deps-missing"           test "$(qslugs --deps-missing)"       = "$(jslugs '([.deps[]|select(.missing)]|length)>0')"
chk "--deps-missing is not vacuous" test "$(qslugs --deps-missing)"  = "ov-b"
chk "--match glob"             test "$(qslugs --match 'ov-g*')"      = "$(jslugs '(.slug//"")|test("^ov-g.*$")')"
chk "--slug picks exactly one" test "$(qslugs --slug ov-b)"          = "ov-b"
# Comma-as-OR holds for every value-taking filter: a false empty is the worst shape for
# a read API (it reads as "no matches", not as an error).
chk "--group ORs within one flag (real + bogus == real alone)" \
                               test "$(qslugs --group ov-split,no-such-group)" = "$(qslugs --group ov-split)"
chk "--group comma form is not silently empty" \
                               test "$(qslugs --group ov-split,no-such-group)" = "ov-g1,ov-g2"
chk "--owner ORs within one flag (real + bogus == real alone)" \
                               test "$(qslugs --owner "$WTA_ID",no-such-worktree)" = "$(qslugs --owner "$WTA_ID")"
chk "--owner comma form is not silently empty" \
  sh -c '[ -n "$0" ] && [ "$0" != "-" ]' "$(qslugs --owner "$WTA_ID",no-such-worktree)"
chk "--owner \"\" still means UNOWNED" \
                               test "$(qslugs --owner "")"  = "$(jslugs '.owner==null')"
chk "two filters AND (intersection, never union)" \
  test "$(qslugs --open --group ov-split)" = "$(jslugs '((.state|IN("implemented","superseded"))|not) and .group=="ov-split"')"

echo "-- M3. retired flags are usage errors, never silently ignored (v5.0.0) --"
for retired in "--subtree ov-a" --roots "--parent ov-a" --no-parent --open-counts "--origin deferred" \
               "--deferred-from ov-a" --deferred-from-exists "--priority high" "--category fix" \
               --has-handoff "--kind plan"; do
  # shellcheck disable=SC2086 # word-split on purpose: flag + its value
  ps query $retired >/dev/null 2>&1; rc=$?
  chk "query ${retired%% *} → exit 1" test "$rc" = "1"
done
ps query --format tree >/dev/null 2>&1; rc=$?
chk "--format tree → exit 1" test "$rc" = "1"

echo "-- M4. output layer: --format / --fields / --sort / --limit --"
chk "--format count equals --format slug | wc -l" \
  test "$(psout query --format count)" = "$(psout query --format slug | wc -l | tr -d ' ')"
chk "--format tsv: one row per entry"  test "$(psout query --format tsv | wc -l | tr -d ' ')" = "$(psout query --format count)"
chk "--format tsv: default 4 columns"  test "$(psout query --format tsv | head -1 | awk -F'\t' '{print NF}')" = "4"
chk "--format tsv: null renders as the - placeholder, never an empty field" \
  test "$(psout query --slug ov-a --format tsv --fields slug,group)" = "$(printf 'ov-a\t-')"
chk "--format table: prints a header row" has "STATE" "$(psout query --format table)"
chk "--fields dot path pulls one nested scalar" \
  test "$(psout query --slug ov-b --format tsv --fields steps.total)" = "2"
chk "--fields json projection emits ONLY the requested keys" \
  test "$(psout query --slug ov-b --fields steps.total | jq -c '.[0]|keys')" = '["steps.total"]'
chk "--limit truncates"    test "$(psout query --limit 2 --format count)" = "2"
chk "--limit 0 is empty"   test "$(psout query --limit 0 --format count)" = "0"
chk "--sort slug ascends"  test "$(psout query --sort slug --format slug | tr '\n' ',')" = "$(psout query --format slug | sort | tr '\n' ',')"
out="$(ps query --format bogus)"; rc=$?
chk "--format rejects an unknown value (exit 1)"        test "$rc" = "1"
chk "--format error names the valid set"                has "json|table|slug|count|tsv" "$out"
ps query --limit abc >/dev/null 2>&1; rc=$?
chk "--limit rejects a non-integer (exit 1)"            test "$rc" = "1"
out="$(ps query --state)"; rc=$?
chk "a flag missing its value is a usage error"         test "$rc" = "1"
chk "  ...and says which flag"                          has -- "--state needs a value" "$out"
ps query --open --closed >/dev/null 2>&1; rc=$?
chk "--open and --closed together are refused"          test "$rc" = "1"
ps query --owner x --unowned >/dev/null 2>&1; rc=$?
chk "--owner and --unowned together are refused"        test "$rc" = "1"
ps query --frobnicate >/dev/null 2>&1; rc=$?
chk "an unknown flag is a usage error"                  test "$rc" = "1"
ps query --slug nope >/dev/null 2>&1; rc=$?
chk "--slug on a nonexistent plan is a usage error"     test "$rc" = "1"

echo "== N. query is fail-soft when jq is absent from PATH =="
out="$(psq_nojq_out query)"
err="$(psq_nojq_err query)"
rc=0; psq_nojq_rc query || rc=$?
chk "no jq → exit 0"                  test "$rc" = "0"
chk "no jq → empty stdout"            test -z "$out"
chk "no jq → one-line stderr notice"  test "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = "1"
chk "no jq → notice names the problem" has "jq not found" "$err"

echo "== O. list stays byte-compatible even when a plan carries deps or retired pre-5.0 keys =="
out="$(psout list)"
row="$(printf '%s' "$out" | awk -v s="ov-b" '$3 == s')"
chk "row for a plan with deps is found"              test -n "$row"
chk "row is exactly 5 whitespace-separated columns"  test "$(printf '%s' "$row" | awk '{print NF}')" = "5"
chk "row carries no stray JSON from deps"            sh -c '! printf "%s" "$0" | grep -qE "[][{}]"' "$row"
row_l="$(printf '%s' "$out" | awk -v s="ov-legacy" '$3 == s')"
chk "a legacy-keyed plan's row is exactly 5 columns" test "$(printf '%s' "$row_l" | awk '{print NF}')" = "5"
chk "…and carries none of its retired values"        sh -c '! printf "%s" "$0" | grep -qE "fix|high|deferred"' "$row_l"
plan byte-compat
ps init byte-compat >/dev/null
row_plain="$(psout list | awk -v s="byte-compat" '$3 == s')"
chk "a plain plan's row matches the pre-v2.25.0 shape exactly" \
  test "$(printf '%s' "$row_plain" | awk '{print $2, $3, $4, $5}')" = "draft byte-compat - -"
out="$(ps list --parent)"; rc=$?
chk "list --parent (retired) → exit 1" test "$rc" = "1"

echo "== O2. list --owners adds a 6th OWNER column; bare list stays 5 (v2.23.0) =="
row_default="$(psout list | awk -v s="ov-b" '$3 == s')"
chk "list (default) row is still exactly 5 columns" test "$(printf '%s' "$row_default" | awk '{print NF}')" = "5"
row_owners="$(psout list --owners | awk -v s="ov-b" '$3 == s')"
chk "list --owners row is exactly 6 columns"      test "$(printf '%s' "$row_owners" | awk '{print NF}')" = "6"
chk "list --owners 6th column is the owner wt-id" test "$(printf '%s' "$row_owners" | awk '{print $6}')" = "$WTA_ID"

echo "== P. gate: read-only plan-gate marker status, before every guard (v2.23.0 4-token contract) =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
chk "no marker anywhere → RELEASED"            test "$(psout gate)" = "RELEASED"

: > "$OWN_MARKER"
chk "own marker live → ARMED"                  test "$(psout gate)" = "ARMED"
rm -f "$OWN_MARKER"

: > "$LEGACY_MARKER"
chk "legacy marker live → ARMED"               test "$(psout gate)" = "ARMED"
rm -f "$LEGACY_MARKER"

: > "$SIB_MARKER"
chk "sibling-only live → ARMED_ELSEWHERE"      test "$(psout gate)" = "ARMED_ELSEWHERE"

: > "$OWN_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$OWN_MARKER" 2>/dev/null || true
chk "own-stale + sibling-live → STALE (own_exists outranks the sibling check)" \
  test "$(psout gate)" = "STALE"
chk "gate never deletes the own marker"        test -e "$OWN_MARKER"
chk "gate never deletes the sibling marker"    test -e "$SIB_MARKER"
rm -f "$OWN_MARKER" "$SIB_MARKER"

CWD="$BARE"
chk "gate in a never-planned repo → RELEASED"  test "$(psout gate)" = "RELEASED"
CWD="$NONGIT"
chk "gate outside a repo → RELEASED"           test "$(psout gate)" = "RELEASED"
CWD="$REPO"
out="$(ps gate extra)"; rc=$?
chk "gate rejects a stray argument → exit 1"   test "$rc" = "1"
chk "gate rejects a stray argument → names it" has "unexpected argument" "$out"

echo "== P2. gate --verbose: ARMED (own marker) — exactly marker/owner_session/owner_cwd/owner_worktree/age_min/affected_plans, ownership-filtered =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
plan gv-old "old plan — written BEFORE the marker, must not show as affected"
sleep 1
{ echo "session=test-session-xyz"; echo "cwd=/some/other/repo"; echo "worktree=$REPO"; } > "$OWN_MARKER"
sleep 1
plan gv-new "new plan — written AFTER the marker, exactly what approve-plan.sh would promote"
ps init gv-new >/dev/null   # owned by THIS worktree — must appear in affected_plans
plan gv-b-owned "written after the marker too, but owned by the sibling worktree — must be excluded (ownership-filtered)"
CWD="$WTB"; ps init gv-b-owned >/dev/null; CWD="$REPO"
out="$(psout gate --verbose)"
chk "gate --verbose (own): line 1 is still the bare token" \
  test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED"
chk "gate --verbose (own): exactly 7 lines total (token + 6 fields)" \
  test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "7"
chk "gate --verbose (own): field order/names are exactly the normative six" \
  test "$(printf '%s\n' "$out" | sed -n '2,7p' | sed -E 's/=.*//' | tr '\n' ',')" \
  = "marker,owner_session,owner_cwd,owner_worktree,age_min,affected_plans,"
chk "gate --verbose (own): reports the marker path"     has "marker=${OWN_MARKER}" "$out"
chk "gate --verbose (own): reports the owning session"  has "owner_session=test-session-xyz" "$out"
chk "gate --verbose (own): reports the owning cwd"      has "owner_cwd=/some/other/repo" "$out"
chk "gate --verbose (own): reports the owning worktree" has "owner_worktree=${REPO}" "$out"
chk "gate --verbose (own): reports a numeric age" \
  sh -c 'printf "%s" "$0" | grep -qE "age_min=[0-9]+"' "$out"
chk "gate --verbose (own): affected_plans is ownership-filtered to gv-new only" \
  test "$(printf '%s\n' "$out" | grep '^affected_plans=')" = "affected_plans=gv-new"
rm -rf "$PLANS/gv-old" "$PLANS/gv-new" "$PLANS/gv-b-owned" "$OWN_MARKER"

echo "== P3. gate --verbose: ARMED (legacy marker) — affected_plans UNFILTERED, mirroring approve-plan.sh's legacy_mode =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
{ echo "session=legacy-sess"; echo "cwd=/legacy/cwd"; } > "$LEGACY_MARKER"
sleep 1
plan lg-a-owned "owned by this worktree"
ps init lg-a-owned >/dev/null
plan lg-b-owned "owned by the sibling worktree"
CWD="$WTB"; ps init lg-b-owned >/dev/null; CWD="$REPO"
plan lg-unowned "never init'd — unowned"
out="$(psout gate --verbose)"
chk "gate --verbose (legacy): line 1 ARMED"        test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED"
chk "gate --verbose (legacy): marker= is the bare legacy path" has "marker=${LEGACY_MARKER}" "$out"
chk "gate --verbose (legacy): affected_plans includes ALL three, unfiltered by ownership" \
  sh -c 'line=$(printf "%s\n" "$0" | grep "^affected_plans="); sorted=$(printf "%s" "${line#affected_plans=}" | tr " " "\n" | sort | tr "\n" ","); [ "$sorted" = "lg-a-owned,lg-b-owned,lg-unowned," ]' "$out"
rm -f "$LEGACY_MARKER"; rm -rf "$PLANS/lg-a-owned" "$PLANS/lg-b-owned" "$PLANS/lg-unowned"

echo "== P4. gate --verbose: ARMED_ELSEWHERE — one elsewhere= line per live sibling, nothing else =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
{ echo "session=sib-sess-b"; echo "cwd=$WTB"; echo "worktree=$WTB"; } > "$SIB_MARKER"
{ echo "session=sib-sess-c"; echo "cwd=$WTC"; echo "worktree=$WTC"; } > "$SIB_MARKER_C"
out="$(psout gate --verbose)"
chk "gate --verbose (elsewhere): line 1 ARMED_ELSEWHERE" test "$(printf '%s\n' "$out" | sed -n '1p')" = "ARMED_ELSEWHERE"
chk "gate --verbose (elsewhere): exactly 3 lines total (token + one per sibling)" \
  test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "3"
chk "gate --verbose (elsewhere): sibling B's line present with all four fields" \
  has "elsewhere=${WTB_ID} session=sib-sess-b worktree=${WTB} age_min=" "$out"
chk "gate --verbose (elsewhere): sibling C's line present with all four fields" \
  has "elsewhere=${WTC_ID} session=sib-sess-c worktree=${WTC} age_min=" "$out"
rm -f "$SIB_MARKER" "$SIB_MARKER_C"

echo "== P5. gate --verbose on STALE/RELEASED: still exactly the bare token, no fields =="
CWD="$REPO"
rm -f "$LEGACY_MARKER" "$OWN_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
chk "gate --verbose on RELEASED: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
chk "gate --verbose on RELEASED: bare token" \
  test "$(psout gate --verbose)" = "RELEASED"
: > "$OWN_MARKER"
touch -t "$(date -v-9H +%Y%m%d%H%M 2>/dev/null || date -d '9 hours ago' +%Y%m%d%H%M)" "$OWN_MARKER" 2>/dev/null || true
chk "gate --verbose on STALE: still exactly one line" \
  test "$(psout gate --verbose | wc -l | tr -d ' ')" = "1"
chk "gate --verbose on STALE: bare token" \
  test "$(psout gate --verbose)" = "STALE"
rm -f "$OWN_MARKER"

out="$(ps gate --verbose extra)"; rc=$?
chk "gate --verbose rejects a further stray argument → exit 1"   test "$rc" = "1"
chk "gate --verbose rejects a further stray argument → names it" has "unexpected argument" "$out"

echo "== Q. set … implemented/failed: closing-checklist reminder (closing_checklist_reminder) =="
plan cc-fire; plan cc-silent-otherstate; plan cc-refire; plan cc-failed

merged="$(ps set cc-fire implemented)"; rc=$?   # ps merges stdout+stderr — one call, several assertions
chk "fresh implemented → reminder fires"                    has "Closing checklist" "$merged"
chk "reminder → asks to name follow-ups"                     has "follow-up WORK item" "$merged"
chk "reminder → asks for the Done review"                    has "Done review" "$merged"
chk "reminder → names no removed command"                    hasnt "/mentor:\(defer\|tour\|track\|handoff\)" "$merged"
chk "reminder → no TaskList / dispatch wording"              hasnt "TaskList\|dispatch\|verifier" "$merged"
chk "reminder → still reports the state transition"         has "unknown → implemented" "$merged"
chk "reminder path still exits 0"                            test "$rc" = "0"

out="$(pserr set cc-silent-otherstate in_progress)"
chk "transition to a non-terminal state → silent"            hasnt "Closing checklist" "$out"

ps set cc-refire implemented >/dev/null   # first close
out="$(ps set cc-refire implemented)"     # shipping/merging idempotently re-closing the same plan
chk "idempotent re-close (before==state already) → silent"   hasnt "Closing checklist" "$out"

out="$(ps set cc-failed failed --note "verification unresolved")"
chk "failed → reminder fires"                                has "Closing checklist" "$out"
chk "failed → follow-up line still fires"                    has "follow-up WORK item" "$out"
chk "failed → Done-review line fires too"                     has "Done review" "$out"

# A plan whose ✅ ticks alone already self-heal mentor_plan_effective_state to
# "implemented" — with NO prior `set` call — must still get this reminder on its real
# first `set … implemented` (freshness is judged off the STORED state).
plan cc-selfheal '## Implementation steps' '1. one ✅' '2. two ✅'
merged="$(ps set cc-selfheal implemented)"; rc=$?
chk "ticks alone self-heal effective state → reminder still fires" has "Closing checklist" "$merged"
chk "self-heal case → still reports the state transition"          has "implemented → implemented" "$merged"
chk "self-heal reminder path still exits 0"                        test "$rc" = "0"

# The verifier-artifact warning is gone with dispatch: a non-empty ## Verification and
# no *verify*.md must not warn.
plan cc-verif '# v' '## Implementation steps' '1. one ✅' '## Verification' '- run the tests'
out="$(ps set cc-verif implemented)"
chk "no verify-artifact warning any more"                    hasnt "verify\*\.md\|verifier" "$out"

echo "== S. set … implemented: tick-reconciliation reminder (tick_reconciliation_reminder) =="
plan tr-partial '## Implementation steps' '1. one ✅' '2. two' '3. three'
merged="$(ps set tr-partial implemented)"; rc=$?
chk "1/3 ticked → warning fires"                    has "steps ticked" "$merged"
chk "warning → names the ratio"                     has "1/3 steps ticked" "$merged"
chk "warning → names the plan slug"                 has "tr-partial" "$merged"
chk "warning → gives the tick remediation command"  has "plan-state.sh tick tr-partial" "$merged"
chk "reminder path still exits 0"                   test "$rc" = "0"

# The reminder gate is judged off the STORED sidecar (before_stored), not the
# tick-derived effective read, so a plan whose ✅ ticks alone would already self-heal
# the effective state to "implemented" still reaches this function on its first real
# `set … implemented` — no detour through another stored state required.
plan tr-full '## Implementation steps' '1. one ✅' '2. two ✅'
out="$(ps set tr-full implemented)"
chk "2/2 ticked (no prior close) → silent"          hasnt "steps ticked" "$out"

plan tr-empty '## Notes' 'no Implementation steps section at all'
out="$(ps set tr-empty implemented)"
chk "no recognizable step lines (0 total) → silent" hasnt "steps ticked" "$out"

plan tr-failed '## Implementation steps' '1. one' '2. two'
out="$(ps set tr-failed failed --note "blocked")"
chk "transition to failed (not implemented) → silent" hasnt "steps ticked" "$out"

plan tr-refire '## Implementation steps' '1. one'
ps set tr-refire implemented >/dev/null            # first close — the fresh transition
out="$(pserr set tr-refire implemented)"           # idempotent re-close (e.g. ship re-running set)
chk "idempotent re-close → no re-fired tick warning" hasnt "steps ticked" "$out"

echo "== V. relocate <src-plan-dir>: copy a plan from a DIFFERENT repo into this one, re-own it here =="
rm -rf "$PLANS"; mkdir -p "$PLANS"
SRC_REPO="$ROOT/src-repo"
git init -q -b main "$SRC_REPO" >/dev/null 2>&1
( cd "$SRC_REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
SRC_PLANS="$SRC_REPO/.mentor/plans"
mkdir -p "$SRC_PLANS/rl-slug"
printf '# Relocate me\n\n## Implementation steps\n1. one\n\n## Suggested first steps\n- src/somefile.ts\n- lib/other.py\n' > "$SRC_PLANS/rl-slug/plan.md"
CWD="$SRC_REPO"; ps init rl-slug >/dev/null; CWD="$REPO"
# A retired pre-5.0 key on the source sidecar: relocate's re-own write must merge it through.
jq '.priority = "high"' "$SRC_PLANS/rl-slug/.state.json" > "$SRC_PLANS/rl-slug/.tmp" && mv "$SRC_PLANS/rl-slug/.tmp" "$SRC_PLANS/rl-slug/.state.json"

out="$(ps relocate "$SRC_PLANS/rl-slug")"; rc=$?
chk "relocate → exit 0"                              test "$rc" = "0"
chk "relocate reports the move"                      has "relocated from" "$out"
chk "relocate copied plan.md"                        test -f "$PLANS/rl-slug/plan.md"
chk "relocate copied .state.json"                    test -f "$PLANS/rl-slug/.state.json"
chk "relocate preserves unmanaged keys (priority)"  test "$(sidecar rl-slug '.priority')" = "high"
chk "relocate re-owns to this worktree"              test "$(sidecar rl-slug '.owner')" = "$WTA_ID"
chk "relocate never deletes the source"              test -f "$SRC_PLANS/rl-slug/plan.md"
chk "relocate reports the source is kept"            has "source NOT deleted" "$out"
chk "relocate warns about the source gate (informational)" \
  has "if the source repo's plan-gate marker is still armed" "$out"
# "Suggested first steps" names repo-relative-looking paths → the stale-paths WARNING.
chk "relocate flags stale-looking paths in Suggested first steps" \
  has "still names repo-relative paths that may be stale" "$out"
chk "..lists the paths it found"                     has "src/somefile.ts" "$out"

echo "== V2. relocate: no 'Suggested first steps' section — must complete without aborting =="
mkdir -p "$SRC_PLANS/rl-nosteps"
printf '# No suggested steps here\n\n## Implementation steps\n1. one\n' > "$SRC_PLANS/rl-nosteps/plan.md"
CWD="$SRC_REPO"; ps init rl-nosteps >/dev/null; CWD="$REPO"
out="$(ps relocate "$SRC_PLANS/rl-nosteps")"; rc=$?
chk "relocate (no Suggested first steps section) → exit 0, does not abort" test "$rc" = "0"
chk "relocate (no Suggested first steps) still relocated"                  test -f "$PLANS/rl-nosteps/plan.md"
chk "relocate (no Suggested first steps) → no stale-paths warning printed" \
  hasnt "still names repo-relative paths" "$out"

echo "== V4. relocate: usage/edge-case errors =="
out="$(ps relocate)"; rc=$?
chk "relocate with no src → exit 1"            test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/rl-slug" extra)"; rc=$?
chk "relocate with a stray extra arg → exit 1" test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/does-not-exist")"; rc=$?
chk "relocate: nonexistent source → exit 1"    test "$rc" = "1"
out="$(ps relocate "$SRC_PLANS/rl-slug")"; rc=$?   # already relocated once in section V
chk "relocate: destination already exists → exit 1" test "$rc" = "1"
chk "..names the collision"                          has "already exists" "$out"
mkdir -p "$SRC_PLANS/rl-notaplan"    # missing plan.md/.state.json
out="$(ps relocate "$SRC_PLANS/rl-notaplan")"; rc=$?
chk "relocate: not a real plan dir → exit 1"   test "$rc" = "1"
chk "..names the reason"                        has "not a real plan dir" "$out"

echo "== W. start <slug>: ensure-dir + init in ONE call =="
# The contract that matters is stdout purity: callers write
# `plan_md="$(plan-state.sh start "$slug")"`, so anything init prints has to go to
# stderr or the capture is unusable.
CWD="$REPO"
out="$(psout start st-fresh --group st-g --order 3)"; rc=$?
chk "start: exit 0"                              test "$rc" = "0"
chk "start: stdout is EXACTLY one line"          test "$(printf '%s\n' "$out" | grep -c .)" = "1"
chk "start: stdout is the plan.md path"          has "/.mentor/plans/st-fresh/plan.md$" "$out"
chk "start: created the plan dir"                test -d "$REPO/.mentor/plans/st-fresh"
chk "start: dir locked to 700 (ensure-dir ran)"  test "$(stat -c '%a' "$REPO/.mentor/plans/st-fresh" 2>/dev/null || stat -f '%Lp' "$REPO/.mentor/plans/st-fresh")" = "700"  # GNU -c first: GNU's -f is --file-system
chk "start: sidecar written (init ran)"          test -f "$REPO/.mentor/plans/st-fresh/.state.json"
chk "start: init flags forwarded — group"        test "$(jq -r .group "$REPO/.mentor/plans/st-fresh/.state.json")" = "st-g"
chk "start: init flags forwarded — order"        test "$(jq -r .order "$REPO/.mentor/plans/st-fresh/.state.json")" = "3"
chk "start: owner stamped"                       test "$(jq -r .owner "$REPO/.mentor/plans/st-fresh/.state.json")" = "$WTA_ID"
chk "start: state is draft"                      test "$(jq -r .state "$REPO/.mentor/plans/st-fresh/.state.json")" = "draft"
err="$(pserr start st-fresh)"
chk "start: init summary goes to stderr, not stdout" has "st-fresh: draft" "$err"
chk "start: no claim step any more"              hasnt "claim" "$err"
out2="$(psout start st-fresh)"
chk "start: idempotent re-run → same path"       test "$out2" = "$out"
chk "start: idempotent re-run → still draft"     test "$(jq -r .state "$REPO/.mentor/plans/st-fresh/.state.json")" = "draft"
out="$(ps start st-bad --priority high)"; rc=$?
chk "start: a retired init flag → exit 1"        test "$rc" = "1"
chk "..leaves no plan dir behind"                test ! -e "$REPO/.mentor/plans/st-bad"
out="$(ps start newone --deferred)"; rc=$?
chk "start newone --deferred → exit 1"           test "$rc" = "1"
chk "..names the bad flag"                       has "start: unknown flag --deferred" "$out"
chk "..leaves no plan dir behind"                test ! -e "$REPO/.mentor/plans/newone"
out="$(ps start st-extra stray)"; rc=$?
chk "start: a stray positional → exit 1, no dir" sh -c '[ "$0" = 1 ] && [ ! -e "$1" ]' "$rc" "$REPO/.mentor/plans/st-extra"

# A pre-5.0 deferred stub: start no longer clears origin — the key is simply left in
# place, unread (approve-plan's sweep no longer shields on it either).
ps ensure-dir "$REPO/.mentor/plans/st-stub" >/dev/null
printf '{"state":"draft","origin":"deferred"}\n' > "$REPO/.mentor/plans/st-stub/.state.json"
out="$(psout start st-stub)"; rc=$?
chk "start on a legacy stub: exit 0, path printed" sh -c '[ "$0" = 0 ] && case "$1" in */st-stub/plan.md) exit 0 ;; *) exit 1 ;; esac' "$rc" "$out"
chk "start on a legacy stub: origin left untouched" test "$(jq -r .origin "$REPO/.mentor/plans/st-stub/.state.json")" = "deferred"

out="$(ps start)"; rc=$?
chk "start: no slug → exit 1"                    test "$rc" = "1"
chk "..names the usage"                          has "start needs <slug>" "$out"
out="$(ps start --priority high)"; rc=$?
chk "start: flag in the slug position → exit 1"  test "$rc" = "1"
CWD="$ROOT"; out="$(ps start outside-a-repo)"; rc=$?
chk "start: outside a git repo → exit 1"         test "$rc" = "1"
chk "..names the reason"                         has "Not inside a git repo" "$out"
CWD="$REPO"

echo "== X. plan content drift: record-write, outside edits, ticks and lifecycle writes =="
NOTICE='plan.md changed since mentor last wrote it — read it before editing it further'
plan hash-plan '# tracked' '## Implementation steps' '1. first' '2. second' '## Verification'
HASH_MD="$PLANS/hash-plan/plan.md"
HASH_STATE="$PLANS/hash-plan/.state.json"
chk "no sidecar → drift unknown" test "$(psout drift hash-plan)" = unknown
cat > "$HASH_STATE" <<'JSON'
{"state":"approved","owner":"old-wt","owner_session":"old-session","note":"keep this note","group":"old-group","order":4,"deps":["solo"],"extra":{"keep":[1,true,null]}}
JSON
chk "legacy sidecar without plan_sha256 → drift unknown" test "$(psout drift hash-plan)" = unknown
hash_fields="$(jq -cS . "$HASH_STATE")"
hash_content="$(cat "$HASH_MD")"
out="$(ps record-write hash-plan)"; rc=$?
chk "record-write → exit 0" test "$rc" = 0
chk "record-write never changes plan.md" test "$(cat "$HASH_MD")" = "$hash_content"
chk "record-write → known" test "$(psout drift hash-plan)" = known
chk "lib mentor_plan_drift → known" test "$(mentor_plan_drift "$HASH_MD")" = known
chk "record-write stores a sha256" jq -e '.plan_sha256 | test("^[0-9a-f]{64}$")' "$HASH_STATE"
chk "record-write preserves every other sidecar key" test "$(jq -cS 'del(.plan_sha256)' "$HASH_STATE")" = "$hash_fields"
hash_once="$(cat "$HASH_STATE")"
ps record-write hash-plan >/dev/null
chk "record-write is idempotent" test "$(cat "$HASH_STATE")" = "$hash_once"

printf '\noutside edit\n' >> "$HASH_MD"
chk "outside printf append → changed" test "$(psout drift hash-plan)" = changed
chk "lib mentor_plan_drift → changed" test "$(mentor_plan_drift "$HASH_MD")" = changed
saved_pass hash-plan 1
out="$(ps tick hash-plan 1)"; rc=$?
chk "tick after outside edit → exit 0" test "$rc" = 0
chk "tick reports drift BEFORE its tick result" test "$(printf '%s\n' "$out" | head -1)" = "$NOTICE"
chk "tick reports the drift notice once" test "$(printf '%s\n' "$out" | grep -Fxc "$NOTICE")" = 1
chk "successful tick re-baselines → known" test "$(psout drift hash-plan)" = known
chk "tick preserves every other sidecar key" test "$(jq -cS 'del(.plan_sha256)' "$HASH_STATE")" = "$hash_fields"
out="$(ps tick hash-plan 1)"
chk "unchanged idempotent tick → no drift notice" hasnt "$NOTICE" "$out"
chk "unchanged idempotent tick → known" test "$(psout drift hash-plan)" = known

before_already_tick="$(cksum "$HASH_STATE")"
printf '\noutside edit before an already-ticked step\n' >> "$HASH_MD"
before_already_content="$(cksum "$HASH_MD")"
out="$(ps tick hash-plan 1)"; rc=$?
chk "already-ticked step after outside edit → exit 0" test "$rc" = 0
chk "already-ticked step after outside edit → reports no write" has 'was already ✅' "$out"
chk "already-ticked step after outside edit → reports drift" has "$NOTICE" "$out"
chk "already-ticked step after outside edit → sidecar unchanged" test "$(cksum "$HASH_STATE")" = "$before_already_tick"
chk "already-ticked step after outside edit → plan.md unchanged" test "$(cksum "$HASH_MD")" = "$before_already_content"
chk "already-ticked step after outside edit → drift still changed" test "$(psout drift hash-plan)" = changed

before_failed_tick="$(cat "$HASH_STATE")"
printf '\nanother outside edit\n' >> "$HASH_MD"
before_failed_content="$(cat "$HASH_MD")"
out="$(ps tick hash-plan 99)"; rc=$?
chk "failed tick → non-zero" test "$rc" = 1
chk "failed tick preserves the old baseline and sidecar" test "$(cat "$HASH_STATE")" = "$before_failed_tick"
chk "failed tick preserves plan.md" test "$(cat "$HASH_MD")" = "$before_failed_content"
chk "failed tick leaves outside edit changed" test "$(psout drift hash-plan)" = changed

plan hash-cycle '# hookless' '## Implementation steps' '1. first' '2. second' '3. third' '## Verification'
ps init hash-cycle >/dev/null
ps record-write hash-cycle >/dev/null
for cycle in 1 2; do
  saved_pass hash-cycle "$cycle"
  printf '| Step %s | PASS |\n' "$cycle" >> "$PLANS/hash-cycle/plan.md"
  ps record-write hash-cycle >/dev/null
  out="$(ps tick hash-cycle "$cycle")"; rc=$?
  chk "hookless cycle $cycle: PASS row → record-write → tick succeeds" test "$rc" = 0
  chk "hookless cycle $cycle → no drift notice" hasnt "$NOTICE" "$out"
  chk "hookless cycle $cycle → known" test "$(psout drift hash-cycle)" = known
done
# Approval must promote a fresh, unticked draft through a real gate release;
# an already-open gate or the ticked hash-cycle plan would skip the sidecar write.
rm -f "$OWN_MARKER" "$LEGACY_MARKER" "$SIB_MARKER" "$SIB_MARKER_C"
out="$(cd "$REPO" && _env bash "$HOOKS/begin-plan.sh" hash-approval 2>&1)"; rc=$?
chk "approval fixture: begin-plan succeeds" test "$rc" = 0
chk "approval fixture: this worktree's gate is armed" test -f "$OWN_MARKER"
sleep 1
plan hash-approval '# approval' '## Implementation steps' '1. first' '2. second' '## Verification' '## Goal check' 'The change is verified.'
ps init hash-approval >/dev/null
ps record-write hash-approval >/dev/null
approval_content="$(cat "$PLANS/hash-approval/plan.md")"
approval_baseline="$(sidecar hash-approval .plan_sha256)"
chk "approval fixture: stored state is draft" test "$(sidecar hash-approval .state)" = draft
chk "approval fixture: plan is newer than the gate marker" test "$PLANS/hash-approval/plan.md" -nt "$OWN_MARKER"
chk "approval fixture: recorded baseline is a sha256" jq -e '.plan_sha256 | test("^[0-9a-f]{64}$")' "$PLANS/hash-approval/.state.json"
chk "approval fixture: drift is known" test "$(psout drift hash-approval)" = known
out="$(cd "$REPO" && _env bash "$HOOKS/approve-plan.sh" 2>&1)"; rc=$?
chk "fresh draft approval → exit 0" test "$rc" = 0
chk "fresh draft approval → gate released" test ! -f "$OWN_MARKER"
chk "fresh draft approval → stored state approved" test "$(sidecar hash-approval .state)" = approved
chk "fresh draft approval → no drift notice" hasnt "$NOTICE" "$out"
chk "fresh draft approval → known" test "$(psout drift hash-approval)" = known
chk "fresh draft approval preserves plan.md" test "$(cat "$PLANS/hash-approval/plan.md")" = "$approval_content"
chk "fresh draft approval preserves the baseline" test "$(sidecar hash-approval .plan_sha256)" = "$approval_baseline"
out="$(ps set hash-approval in_progress)"; rc=$?
chk "state transition → exit 0" test "$rc" = 0
chk "state transition → stored state in_progress" test "$(sidecar hash-approval .state)" = in_progress
chk "state transition → no drift notice" hasnt "$NOTICE" "$out"
chk "state transition → known" test "$(psout drift hash-approval)" = known
chk "state transition preserves plan.md" test "$(cat "$PLANS/hash-approval/plan.md")" = "$approval_content"
chk "state transition preserves the baseline" test "$(sidecar hash-approval .plan_sha256)" = "$approval_baseline"

out="$(ps record-write absent-hash-plan)"; rc=$?
chk "record-write on a missing plan → non-zero" test "$rc" = 1
chk "record-write on a missing plan creates no sidecar" test ! -e "$PLANS/absent-hash-plan/.state.json"
mkdir -p "$PLANS/hash-empty"
out="$(ps record-write hash-empty)"; rc=$?
chk "record-write on a dir without plan.md → non-zero" test "$rc" = 1
chk "record-write without plan.md creates no sidecar" test ! -e "$PLANS/hash-empty/.state.json"
chk "drift without plan.md → unknown" test "$(psout drift hash-empty)" = unknown
out="$(ps record-write)"; rc=$?
chk "record-write without a slug → usage error" test "$rc" = 1
out="$(ps drift hash-plan extra)"; rc=$?
chk "drift rejects extra arguments" test "$rc" = 1
CWD="$BARE"
out="$(ps record-write missing)"; rc=$?
chk "record-write with no plans dir → non-zero" test "$rc" = 1
chk "drift with no plans dir → unknown" test "$(psout drift missing)" = unknown
CWD="$REPO"

echo "== X2. unavailable hash tools and sha256sum fallback =="
NOHASH_DIR="$ROOT/nohash"; mkdir -p "$NOHASH_DIR"
for tool in git dirname jq; do ln -s "$(command -v "$tool")" "$NOHASH_DIR/$tool"; done
out="$(cd "$REPO" && _env PATH="$NOHASH_DIR" "$BASH_BIN" "$PLANSTATE" drift hash-cycle)"; rc=$?
chk "no sha256 tool → drift exits 0" test "$rc" = 0
chk "no sha256 tool → unknown" test "$out" = unknown
before_nohash="$(cat "$PLANS/hash-cycle/.state.json")"
out="$(cd "$REPO" && _env PATH="$NOHASH_DIR" "$BASH_BIN" "$PLANSTATE" record-write hash-cycle)"; rc=$?
chk "no sha256 tool → record-write exits 0" test "$rc" = 0
chk "no sha256 tool → existing baseline preserved" test "$(cat "$PLANS/hash-cycle/.state.json")" = "$before_nohash"
# Use the real Linux utility when present; on macOS adapt the real shasum to the
# same stdin interface so the fallback branch remains covered on either host.
if command -v sha256sum >/dev/null 2>&1; then
  ln -s "$(command -v sha256sum)" "$NOHASH_DIR/sha256sum"
else
  printf '#!%s\nexec "%s" -a 256 "$@"\n' "$BASH_BIN" "$(command -v shasum)" > "$NOHASH_DIR/sha256sum"
  chmod +x "$NOHASH_DIR/sha256sum"
fi
out="$(cd "$REPO" && _env PATH="$NOHASH_DIR" "$BASH_BIN" "$PLANSTATE" drift hash-cycle)"; rc=$?
chk "sha256sum fallback → exit 0" test "$rc" = 0
chk "sha256sum fallback matches the recorded hash → known" test "$out" = known
out="$(psout --help)"
chk "help documents record-write" has 'record-write <slug>' "$out"
chk "help documents drift" has 'drift <slug>' "$out"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
