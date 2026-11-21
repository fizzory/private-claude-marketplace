#!/usr/bin/env bash
# test-sweep.sh — regression tests for `plan-state.sh sweep` (v2.33.0+).
#
# Contract under test:
#   • `sweep <pattern> [--roots plans|repo] [--ignore-case]` searches <pattern>
#     across a NAMED ROOT SET, printing an accounting line FIRST and the hits after:
#         SWEEP: roots=N files=N hits=N
#         <path>:<line>:<text>            (one per hit)
#     The summary leads on purpose: on a broken sweep there are no hits at all, so the
#     summary IS the whole output, and on a long result set it must not scroll away from
#     the reader who has to judge whether the result is trustworthy.
#   • Exit codes mirror grep's own, so a caller that knows grep needs no new convention:
#     0 = hits found · 1 = read >=1 file, no match · 2 = read NO files (plus an explicit
#     `SWEEP: NOTHING-SEARCHED` line), or a usage error.
#   • Root sets:
#       plans (default) — main repo .mentor/plans
#       repo            — the whole worktree minus .git/ (.mentor/ INCLUDED)
#     (the pre-5.0 `policy` set is gone and is a usage error now)
#   • Reachability is the entire point. `.mentor/.gitignore` contains `*`, and a recursive
#     grep whose traversal root is at or above that file reads NOTHING under a grep that
#     honors ignore rules (ugrep does). `sweep` finds a directive in a gitignored handoff
#     note anyway, because `find` does the walking and `grep` only reads the explicit list
#     it is handed — the escape is structural, not a better flag.
#   • Worktree awareness: `repo` resolves via `git rev-parse --show-toplevel` (this
#     worktree's own checkout) while .mentor/plans resolves via git-common-dir (the
#     shared main repo). Using one resolution for both is wrong in a linked worktree.
#   • Portability: only POSIX grep flags. No -r/-R anywhere — recursion is find's job.
#     `-H` is mandatory: without it a single-file root prints a bare `15:` with no path.
#   • Binary files are skipped (-I) but still counted by find's denominator.
#
# Plus TEXT INVARIANTS over the REAL repo (not the sandbox): the non-portable flag this
# subcommand exists to retire must not reappear under plugins/mentor/, and the
# prescribing skill site must invoke `sweep`.
#
# SELF-REFERENCE NOTE: this file lives under plugins/mentor/, so it must never contain the
# retired flag as a contiguous literal — the invariant would then match itself and fail
# forever. Every mention below is split across a string concatenation on purpose. The same
# trap applies to anyone auditing `plugins/` for that flag by hand.
#
# Runs against a SANDBOX $HOME and throwaway git repos so it never touches real state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
PLANSTATE="$HOOKS/plan-state.sh"
[ -f "$PLANSTATE" ] || { echo "FATAL: not found: $PLANSTATE" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
skip() { printf "  skip %s\n" "$1"; }
has()   { printf '%s\n' "$2" | grep -qF -- "$1"; }
hasnt() { ! printf '%s\n' "$2" | grep -qF -- "$1"; }

_env() { env -u CLAUDE_CODE_SESSION_ID HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/.claude" "$@"; }

# run <dir> <sweep args…> — sets OUT (stdout+stderr) and RC. Deliberately not `local`:
# every assertion below reads them back after the call.
run() { local d="$1"; shift
  OUT="$( cd "$d" && _env bash "$PLANSTATE" sweep "$@" 2>&1 )"; RC=$?
}
# fld <field> — echo the numeric value of `<field>=N` from the SWEEP: line, or -1 when
# there is no such line. The -1 matters: a bare empty string makes every `test … -gt 0`
# below abort with "integer expected" instead of recording an honest FAIL, which is
# exactly the noise a suite that must first FAIL cleanly cannot afford.
fld() { local v
  v="$(printf '%s\n' "$OUT" | sed -n "s/^SWEEP:.*${1}=\([0-9]*\).*/\1/p" | head -1)"
  printf '%s' "${v:--1}"
}

# ---------------------------------------------------------------- fixtures
REPO="$ROOT/main-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t ) >/dev/null 2>&1

# The directive the real bug hid, planted where the real one lives: a gitignored note.
mkdir -p "$REPO/.mentor/plans/topic-a/handoffs"
printf '*\n' > "$REPO/.mentor/.gitignore"
cat > "$REPO/.mentor/plans/topic-a/handoffs/note.md" <<'MD'
# Handoff — something

## Standing directives

- **No subagents without the user asking.** In force for this repo's mentor work.
MD
printf '# Plan\n\nNOTEONLY-TOKEN lives only in the gitignored plans tree.\n' \
  > "$REPO/.mentor/plans/topic-a/plan.md"

# CLAUDE.md — committed, so a linked worktree gets its own copy to diverge from.
printf '# Project\n\nMAINONLY-TOKEN appears only in the main worktree CLAUDE.md.\nMixedCase-Directive here.\n' \
  > "$REPO/CLAUDE.md"
mkdir -p "$REPO/.claude"
printf 'DOTCLAUDE-TOKEN lives only in .claude/rules.md\n' > "$REPO/.claude/rules.md"
mkdir -p "$REPO/src"
printf 'SRCONLY-TOKEN lives only in src/, outside the plans root.\n' > "$REPO/src/code.txt"
# Planted inside .git/ — `repo` must prune it, so this token is unreachable from every set.
printf 'GITONLY-TOKEN must never be reachable.\n' > "$REPO/.git/planted.txt"
# A binary file carrying the pattern: counted by find, skipped by grep -I.
printf 'BINARY-TOKEN here\000\001\002more\n' > "$REPO/src/blob.bin"
( cd "$REPO"; git add -A >/dev/null 2>&1; git commit -q -m init ) >/dev/null 2>&1

NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"
printf 'MAINONLY-TOKEN\n' > "$NONGIT/file.txt"

BARE="$ROOT/bare-repo"          # a git repo with no CLAUDE.md, no .claude/, no .mentor/
git init -q -b main "$BARE" >/dev/null 2>&1
( cd "$BARE"; git config user.email t@t.co; git config user.name t; echo x > only.txt
  git add -A; git commit -q -m init ) >/dev/null 2>&1

echo "== A. Reachability into gitignored .mentor/ — the bug this exists to fix =="
run "$REPO" 'No subagents' --roots plans
chk "gitignored handoff note IS found (plans)"        test "$RC" = "0"
chk "  hit line names the note path"                  has "handoffs/note.md" "$OUT"
# Derive the expected line number from the fixture rather than hardcoding it: this must
# assert grep -n's correctness, not the test author's ability to count heredoc lines.
noteline="$(grep -n 'No subagents' "$REPO/.mentor/plans/topic-a/handoffs/note.md" | cut -d: -f1)"
chk "  hit line carries the fixture's real line number"   has "handoffs/note.md:${noteline}:" "$OUT"
chk "  hits=1"                                        test "$(fld hits)" = "1"
run "$REPO" 'No subagents'
chk "same directive found by the DEFAULT root set"    test "$RC" = "0"
chk "  default set is plans (reaches .mentor/plans)"  has "handoffs/note.md" "$OUT"
chk "  …and only that one root"                       test "$(fld roots)" = "1"

# The old prescription, on this very fixture. Only meaningful under a grep that honors
# ignore rules; on GNU/BSD grep it "works" and would prove nothing, so it is gated.
# Detect the grep implementation, and expect it to DIFFER from the one an agent sees.
# Claude Code installs a `grep` shell FUNCTION into the Bash tool's shell that routes to
# its own bundled ugrep with `--ignore-files --hidden -I`; that function is not exported,
# so a suite launched as `bash test-sweep.sh` gets whatever `grep` is on PATH instead —
# here /usr/bin/grep, BSD grep 2.6.0-FreeBSD, which honors no ignore files at all. So the
# gate below usually skips, correctly: reproducing the old command's silent failure needs
# an ignore-aware grep. To exercise it, put a shim earlier on PATH that execs
# `claude -G --ignore-files --hidden -I` as ugrep and re-run — the suite then reports two
# extra passing assertions. Both implementations must give FAIL=0; that dual run is the
# real portability evidence, since the sweep itself uses no flag either one lacks.
grep_impl="$(grep --version 2>&1 || true)"
case "$grep_impl" in
  *ugrep*|*uGrep*|*UGREP*) is_ugrep=1 ;;
  *)                       is_ugrep=0 ;;
esac
if [ "$is_ugrep" = "1" ]; then
  old="$( cd "$REPO" && grep -rn 'No subagents' .mentor/ 2>&1 )"; old_rc=$?
  chk "old command (grep -rn … .mentor/) finds NOTHING here" test "$old_rc" != "0"
  chk "  …and prints nothing"                                test -z "$old"
else
  skip "old-command reproduction (needs ugrep; this grep does not honor .gitignore)"
fi

echo "== B. The repo root set reaches CLAUDE.md and .claude/ =="
run "$REPO" MAINONLY-TOKEN --roots repo
chk "CLAUDE.md hit found"                             test "$RC" = "0"
chk "  path is CLAUDE.md"                             has "CLAUDE.md:" "$OUT"
run "$REPO" DOTCLAUDE-TOKEN --roots repo
chk ".claude/ hit found"                              test "$RC" = "0"
chk "  path is .claude/rules.md"                       has ".claude/rules.md:" "$OUT"

echo "== C. Root-set boundaries — each reaches what it should and NOT more =="
run "$REPO" SRCONLY-TOKEN --roots plans
chk "plans does NOT reach src/ (exit 1, healthy no-match)" test "$RC" = "1"
chk "  files= is non-zero, so the zero is trustworthy"      test "$(fld files)" -gt 0
chk "  no NOTHING-SEARCHED line on a healthy negative"      hasnt "NOTHING-SEARCHED" "$OUT"
run "$REPO" SRCONLY-TOKEN --roots repo
chk "repo DOES reach src/"                            test "$RC" = "0"
run "$REPO" MAINONLY-TOKEN --roots plans
chk "plans does NOT reach CLAUDE.md"                  test "$RC" = "1"
run "$REPO" NOTEONLY-TOKEN --roots repo
chk "repo reaches gitignored .mentor/ too"            test "$RC" = "0"
run "$REPO" DOTCLAUDE-TOKEN --roots plans
chk "plans does NOT reach .claude/"                   test "$RC" = "1"
run "$REPO" GITONLY-TOKEN --roots repo
chk "repo PRUNES .git/ (planted token unreachable)"   test "$RC" = "1"
run "$REPO" NOTEONLY-TOKEN --roots plans
chk "plans roots=1"                                   test "$(fld roots)" = "1"
run "$REPO" NOTEONLY-TOKEN --roots repo
chk "repo roots=1 (the worktree itself)"              test "$(fld roots)" = "1"

echo "== D. --ignore-case =="
run "$REPO" 'mixedcase-directive' --roots repo
chk "case-sensitive by default → no match"            test "$RC" = "1"
run "$REPO" 'mixedcase-directive' --roots repo --ignore-case
chk "--ignore-case matches mixed case"                test "$RC" = "0"
run "$REPO" 'MIXEDCASE-DIRECTIVE' --roots repo --ignore-case
chk "--ignore-case matches from the other direction"  test "$RC" = "0"
run "$REPO" 'no subagents' --ignore-case
chk "a case-insensitive default-set sweep finds the note" test "$RC" = "0"

echo "== E. Exit codes and the NOTHING-SEARCHED verdict =="
run "$REPO" NOTEONLY-TOKEN --roots plans
chk "hits found → exit 0"                             test "$RC" = "0"
run "$REPO" DEFINITELY-ABSENT-XYZZY --roots plans
chk "files read, no match → exit 1"                   test "$RC" = "1"
chk "  hits=0"                                        test "$(fld hits)" = "0"
chk "  files= still non-zero"                         test "$(fld files)" -gt 0
run "$BARE" ANYTHING --roots plans
chk "no root existed → exit 2"                        test "$RC" = "2"
chk "  NOTHING-SEARCHED line present"                 has "NOTHING-SEARCHED" "$OUT"
chk "  says the result is not evidence"               has "not evidence" "$OUT"
chk "  roots=0"                                       test "$(fld roots)" = "0"
chk "  files=0"                                       test "$(fld files)" = "0"
run "$NONGIT" ANYTHING --roots repo
chk "outside a git repo → exit 2, not a false clean"  test "$RC" = "2"
chk "  NOTHING-SEARCHED there too"                    has "NOTHING-SEARCHED" "$OUT"

echo "== F. The SWEEP line leads, and files= is the real denominator =="
run "$REPO" 'No subagents' --roots plans
chk "SWEEP: is the FIRST output line" \
  test "$(printf '%s\n' "$OUT" | head -1 | cut -c1-6)" = "SWEEP:"
want="$(find "$REPO/.mentor/plans" -type f | wc -l | tr -d ' ')"
chk "files= equals an independent find count (plans)" test "$(fld files)" = "$want"
run "$REPO" 'No subagents' --roots repo
want_repo="$(find "$REPO" -name .git -prune -o -type f -print | wc -l | tr -d ' ')"
chk "files= equals an independent find count (repo)"  test "$(fld files)" = "$want_repo"
run "$REPO" TOKEN --roots repo --ignore-case
n_hits="$(printf '%s\n' "$OUT" | grep -c ':[0-9][0-9]*:' || true)"
chk "hits= equals the number of printed hit lines"    test "$(fld hits)" = "$n_hits"

echo "== G. -H is mandatory: a single-file root still prints path:line: =="
SOLO="$ROOT/solo-repo"
git init -q -b main "$SOLO" >/dev/null 2>&1
( cd "$SOLO"; git config user.email t@t.co; git config user.name t ) >/dev/null 2>&1
mkdir -p "$SOLO/.mentor/plans/solo"
printf 'line one\nline two\nSOLO-TOKEN on line three\n' > "$SOLO/.mentor/plans/solo/plan.md"
run "$SOLO" SOLO-TOKEN --roots plans
chk "single-file root: hit found"                     test "$RC" = "0"
chk "  …and it really was a one-file search"          test "$(fld files)" = "1"
chk "  prints the path, not a bare line number"       has "solo/plan.md:3:" "$OUT"
chk "  no bare '3:' hit line without a path" \
  test -z "$(printf '%s\n' "$OUT" | grep '^3:' || true)"

echo "== H. Binary files are skipped by grep but counted by find =="
run "$REPO" BINARY-TOKEN --roots repo
chk "binary file yields no hit (grep -I)"             test "$RC" = "1"
chk "  blob.bin is absent from the output"            hasnt "blob.bin" "$OUT"
chk "  but find still counted it in files=" \
  test "$(fld files)" -ge "$(find "$REPO/src" -type f | wc -l | tr -d ' ')"

echo "== I. Usage errors are exit 2, never a silent default =="
run "$REPO"
chk "missing pattern → exit 2"                        test "$RC" = "2"
run "$REPO" PATTERN --roots
chk "--roots with no value → exit 2"                  test "$RC" = "2"
run "$REPO" PATTERN --roots bogus
chk "unknown root set → exit 2"                       test "$RC" = "2"
chk "  names the valid sets"                          has "plans|repo" "$OUT"
run "$REPO" PATTERN --roots policy
chk "retired policy set → exit 2 (usage error)"       test "$RC" = "2"
run "$REPO" PATTERN --frobnicate
chk "unknown flag → exit 2"                           test "$RC" = "2"
run "$REPO" PATTERN EXTRA-POSITIONAL
chk "stray extra positional → exit 2"                 test "$RC" = "2"
run "$REPO" '' --roots plans
chk "empty pattern → exit 2"                          test "$RC" = "2"

echo "== J. Worktree awareness: repo = own checkout, plans = shared .mentor/plans =="
WT="$ROOT/linked-wt"
git -C "$REPO" worktree add -q "$WT" -b wt-branch >/dev/null 2>&1
if [ -d "$WT" ]; then
  printf '# Project (linked)\n\nWTONLY-TOKEN appears only in the linked worktree.\n' > "$WT/CLAUDE.md"
  run "$WT" WTONLY-TOKEN --roots repo
  chk "linked worktree reads its OWN CLAUDE.md"       test "$RC" = "0"
  run "$WT" MAINONLY-TOKEN --roots repo
  chk "…and NOT the main worktree's CLAUDE.md"        test "$RC" = "1"
  run "$WT" 'No subagents' --roots plans
  chk "…while .mentor/plans still resolves to the main repo" test "$RC" = "0"
  chk "  hit path points into the main repo's .mentor" has "$REPO/.mentor" "$OUT"
  run "$WT" 'No subagents'
  chk "default plans set works from a linked worktree too" test "$RC" = "0"
else
  skip "linked-worktree checks (git worktree add unavailable)"
fi

echo "== K. Text invariants over the real repo — the flag must not come back =="
REAL="$(cd "$SCRIPT_DIR/../../.." && pwd)"        # …/plugins
MENTOR="$REAL/mentor"
# Split literals: this file lives under plugins/mentor/, so a contiguous spelling here
# would make the invariant match itself forever.
bad_flag="--no-""ignore"
bad_ugrep="--no-""ignore-files"
if [ -d "$MENTOR" ]; then
  offenders="$(find "$MENTOR" -type f -print0 | xargs -0 grep -IlF -e "$bad_flag" 2>/dev/null || true)"
  chk "no '${bad_flag}' anywhere under plugins/mentor/" test -z "$offenders"
  [ -n "$offenders" ] && printf '       offenders: %s\n' "$(printf '%s' "$offenders" | tr '\n' ' ')"
  off2="$(find "$MENTOR" -type f -print0 | xargs -0 grep -IlF -e "$bad_ugrep" 2>/dev/null || true)"
  chk "no ugrep-only '${bad_ugrep}' either"             test -z "$off2"
  # Recursion belongs to find: no recursive grep in the EXECUTABLE lines of either
  # script. Whole-line comments are excluded deliberately — lib/state.sh's sweep header
  # quotes `grep -rl … .mentor/` to record the measured hit matrix, and that prose is
  # precisely what stops the broken form being reintroduced.
  chk "no recursive grep in plan-state.sh / lib/state.sh code" \
    bash -c 'for f in "$@"; do grep -vE "^[[:space:]]*#" "$f" | grep -qE "grep +-[a-zA-Z]*[rR]" && exit 1; done; exit 0' _ \
      "$MENTOR/hooks/plan-state.sh" "$MENTOR/hooks/lib/state.sh"
  # The prescribing site must invoke the shared subcommand, not hand-roll a grep.
  chk "planning/SKILL.md invokes 'plan-state.sh sweep'" \
    grep -qF 'plan-state.sh" sweep' "$MENTOR/skills/planning/SKILL.md"
  # Must be the BACKTICKED subcommand spelling: the bare word "sweep" already appears
  # a dozen times in this README as ordinary English ("promotion sweep", "closing
  # sweep"), so grepping for that would pass before step 5 ever runs.
  # A backtick inside a double-quoted `bash -c` body is COMMAND SUBSTITUTION in the
  # inner shell — it ran `sweep` and matched the empty string, so this assertion
  # passed before the subcommand existed. Build the literal from a single-quoted var.
  bt='`'
  chk "README documents the sweep subcommand (backticked)" \
    grep -qF -- "${bt}sweep${bt}" "$MENTOR/README.md"
else
  skip "text invariants (plugins/mentor not found from $SCRIPT_DIR)"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
