#!/usr/bin/env bash
# Checks for previewing's scripts/md-slice.sh: print a Markdown file's heading index, sections by
# heading, or decision-log rows by number, ignoring headings inside fenced code.
set -euo pipefail

plugin_root="$(cd "$(dirname "$0")/.." && pwd -P)"
md="${MD_SLICE:-$plugin_root/skills/previewing/scripts/md-slice.sh}"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1: missing '$2'"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then bad "$1: unexpected '$2'"; else ok "$1"; fi; }

plan="$t/plan.md"
cat > "$plan" <<'MD'
# Plan
## Walkthroughs
walk-text
## Edge cases
edge-text
## Approach
### B. Bee
b-text
### C. Cee
c-text
```text
## fenced-not-a-heading
```
## Decision log
| # | use case | decision |
|---|---|---|
| 3 | x | row-three |
| 5 | y | row-five |
MD

bash "$md" index "$plan" > "$t/idx"
has "index lists a heading with its line" $'L9\t###' "$t/idx"
has "index gives each section's size" $'B\tC. Cee' "$t/idx"
lacks "index skips fenced headings" "fenced-not-a-heading" "$t/idx"

bash "$md" section "$plan" '^C[.)] ' > "$t/sec"
has "section prints the matched section" "c-text" "$t/sec"
has "section keeps a fenced block inside it" "fenced-not-a-heading" "$t/sec"
lacks "section stops at the next heading" "Decision log" "$t/sec"
lacks "section leaves out a sibling" "b-text" "$t/sec"
has "section marks where the chunk came from" "<!-- md-slice $plan L9-" "$t/sec"

bash "$md" section "$plan" '^Approach' > "$t/parent"
has "a parent section holds its children" "b-text" "$t/parent"
has "a parent section runs to its own end" "c-text" "$t/parent"
lacks "a parent section stops at its next sibling" "row-five" "$t/parent"

set +e; bash "$md" section "$plan" '^Edge' '^Nope' > "$t/part" 2> "$t/err"; rc=$?; set -e
[ "$rc" -eq 3 ] && ok "section exits 3 on a miss" || bad "section exits 3 on a miss (got $rc)"
has "section names the missed pattern" "no heading matches: ^Nope" "$t/err"
has "section still prints the patterns that matched" "edge-text" "$t/part"

bash "$md" rows "$plan" 3 5 > "$t/rows"
has "rows prints the table header" "| # | use case | decision |" "$t/rows"
has "rows prints a wanted row" "row-five" "$t/rows"
bash "$md" rows "$plan" 5 > "$t/one"
lacks "rows leaves out an unwanted row" "row-three" "$t/one"
set +e; bash "$md" rows "$plan" 9 > /dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 3 ] && ok "rows exits 3 on a missing row" || bad "rows exits 3 on a missing row (got $rc)"

set +e; bash "$md" index > /dev/null 2> "$t/usage"; rc=$?; set -e
[ "$rc" -eq 2 ] && ok "bad usage exits 2" || bad "bad usage exits 2 (got $rc)"
has "usage lists the rows command" "md-slice.sh rows" "$t/usage"
has "usage names the exit codes" "Exit 3" "$t/usage"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all md-slice checks passed"
