#!/usr/bin/env bash
# Regression tests for retro-pr-body-check.sh: review structure and redaction.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$HOOKS/retro-pr-body-check.sh"
[ -f "$CHECK" ] || { echo "FATAL: $CHECK not found"; exit 1; }
ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
mkdir -p "$SANDBOX"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
body="$ROOT/body.md"
good() { cat > "$body" <<'EOF'
1 change to how the agent works, from the 2026-11-18 session where it fixed billing.

## Changes

| # | Agent now… | Because in the session… | Where |
|---|---|---|---|
| 1 | Checks a failing test alone | Changed working code for a flaky test | `.claude/skills/test-triage/` (new) |
EOF
}
run() { HOME="$SANDBOX" bash "$CHECK" "$@" > "$ROOT/out" 2>&1; }
fails() { ! run "$@"; }
reject_append() { good; printf '\n%s\n' "$1" >> "$body"; fails "$body"; }
append_details() {
  printf '\n<details><summary>Review notes</summary>\n\n%s\n\n</details>\n' "$1" >> "$body"
}
edit_good() {
  good
  python3 - "$body" "$1" "$2" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
assert sys.argv[2] in text, "test mutation did not match the fixture"
path.write_text(text.replace(sys.argv[2], sys.argv[3], 1))
PY
}
reject_edit() {
  edit_good "$1" "$2" || return 1
  fails "$body" && grep -qF "$3" "$ROOT/out"
}
reject_calls() {
  reject_edit '## Changes' $'## Needs your call\n\n'"$1"$'\n\n## Changes' "$2"
}
reject_call_shape() {
  reject_calls "$1" 'item 1 must use - [ ] Confirm: <pick> — <why>. Otherwise: <alternative>.' &&
    test "$(wc -l < "$ROOT/out")" -eq 1
}
reject_ip() {
  good
  if [ "$1" = visible ]; then
    printf '\n%s\n' "$2" >> "$body"
  else
    append_details "$2"
  fi
  fails "$body" && grep -qx 'redaction: IP address found' "$ROOT/out"
}
words() { python3 - "$1" <<'PY'
import sys
print(" ".join(["word"] * int(sys.argv[1])))
PY
}

echo '== Valid bodies and the maintained example =='
good; chk 'minimal body passes' run "$body"
good; cat >> "$body" <<'EOF'

<details><summary>Review notes</summary>

- **Evidence (local, not uploaded):** `.mentor/plans/demo/evidence/manifest.json`
- **Considered, not changed:** Rejected duplicate; Backlog retained.

</details>
EOF
chk 'internal terms and evidence inside details pass' run "$body"
python3 - "$HOOKS/../skills/planning/references/playbooks/retrospective/pr-body.md" "$ROOT/example.md" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text().split('**Example**', 1)[1]
Path(sys.argv[2]).write_text(re.search(r'```markdown\n(.*?)\n```', text, re.S).group(1))
PY
chk 'verbatim template example passes' run "$ROOT/example.md"
for violation in '.mentor/plans/demo/plan.md' 'person@example.com' '## Notes'; do
  python3 - "$ROOT/example.md" "$body" "$violation" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('## Changes', sys.argv[3] + '\n\n## Changes', 1))
PY
  chk "example with $violation fails" fails "$body"
done
good; printf '\nSee `#123` and `!456`.\n' >> "$body"
chk 'literal references in inline code pass' run "$body"
good; printf '\nSee [the review](https://example.com/pull/2#123).\n' >> "$body"
chk 'link target is not prose' run "$body"
good; printf '\nUse `.claude/skills/task-triage/`.\n' >> "$body"
chk 'ordinary task paths are not token shapes' run "$body"

echo '== Opening, item, table and cell limits =='
opening='1 change to how the agent works, from the 2026-11-18 session where it fixed billing.'
chk 'missing opening sentence fails' reject_edit "$opening" '' 'opening: use one sentence'
chk 'two opening sentences fail' reject_edit "$opening" 'First sentence. Second sentence.' 'opening: use one sentence'
chk 'opening without sentence punctuation fails' reject_edit "$opening" 'Review this change' 'opening: use one sentence'
chk '26-word opening fails' reject_edit "$opening" "$(words 26)." 'opening: at most 25 words'
header='| # | Agent now… | Because in the session… | Where |'
separator='|---|---|---|---|'
row='| 1 | Checks a failing test alone | Changed working code for a flaky test | `.claude/skills/test-triage/` (new) |'
chk 'Changes without a table fails' reject_edit "$header"$'\n'"$separator"$'\n'"$row" 'One change.' 'changes: use the template table header'
chk 'wrong table header fails' reject_edit 'Agent now…' 'Behaviour' 'changes: use the template table header'
chk 'missing table separator fails' reject_edit "$separator" '' 'changes: use the template table header'
chk 'table without data rows fails' reject_edit "$row" '' 'changes: table needs at least one data row'
chk 'table row with extra cell fails' reject_edit "$row" "$row extra |" 'changes: row 1 must have four cells'
call='- [ ] Confirm: keep this choice — it helps review. Otherwise: revise it.'
six_calls="$(printf '%s\n' "$call" "$call" "$call" "$call" "$call" "$call")"
chk 'six Needs your call items fail' reject_calls "$six_calls" 'needs your call: at most 5 items'
chk 'checked Needs your call item fails once' reject_call_shape '- [x] Confirm: keep this choice'
chk 'missing Confirm prefix fails once' reject_call_shape '- [ ] Keep this choice'
chk 'numbered Needs your call item fails once' reject_call_shape '1. Confirm: keep this choice'
chk 'missing Otherwise clause fails once' reject_call_shape '- [ ] Confirm: keep this choice — it helps review.'
chk 'missing em dash fails once' reject_call_shape '- [ ] Confirm: keep this choice it helps review. Otherwise: revise it.'
chk 'blank pick fails once' reject_call_shape '- [ ] Confirm:   — it helps review. Otherwise: revise it.'
chk 'blank why fails once' reject_call_shape '- [ ] Confirm: keep this choice —   . Otherwise: revise it.'
chk 'blank alternative fails once' reject_call_shape '- [ ] Confirm: keep this choice — it helps review. Otherwise:  .'
chk 'all blank call parts fail once' reject_call_shape '- [ ] Confirm:   —   . Otherwise:  .'
chk '40-word unmatched item fails once' reject_call_shape "- [ ] Confirm: $(words 40)"
chk '16-word pick fails' reject_calls "- [ ] Confirm: $(words 16) — it helps. Otherwise: revise it." 'item 1 pick exceeds 15 words'
chk '16-word why fails' reject_calls "- [ ] Confirm: keep it — $(words 16). Otherwise: revise it." 'item 1 why exceeds 15 words'
chk '11-word alternative fails' reject_calls "- [ ] Confirm: keep it — it helps. Otherwise: $(words 11)." 'item 1 alternative exceeds 10 words'
good; printf '\n## Not in this PR\n\n' >> "$body"
for n in 1 2 3 4 5 6; do printf -- '- Local change %s → `~/other/`\n' "$n" >> "$body"; done
chk 'six Not in this PR items fail' fails "$body"
chk 'Not in this PR overflow names the violation' grep -qx 'not in this PR: at most 5 items' "$ROOT/out"
chk '16-word Agent now cell fails' reject_edit 'Checks a failing test alone' "$(words 16)" 'row 1 Agent now exceeds 15 words'
chk '26-word Because cell fails' reject_edit 'Changed working code for a flaky test' "$(words 26)" 'row 1 Because in the session exceeds 25 words'
for where in '`a.md` `b.md` (edit)' '`a.md`' '`a.md` (delete)' '`a.md` (new) extra'; do
  chk "invalid Where $where fails" reject_edit '`.claude/skills/test-triage/` (new)' "$where" 'row 1 Where must hold one path and state'
done
edit_good 'Checks a failing test alone' 'Checks `a\|b` before changing code'
chk 'escaped table pipe stays in its cell' run "$body"
good
python3 - "$body" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
opening, rest = text.split('\n', 1)
text = ' '.join(['word'] * 25) + '.' + rest
call = '- [ ] Confirm: ' + ' '.join(['pick'] * 15) + ' — ' + ' '.join(['why'] * 15) + '. Otherwise: ' + ' '.join(['choice'] * 10) + '.'
text = text.replace('## Changes', '## Needs your call\n\n' + '\n'.join([call] * 5) + '\n\n## Changes')
text = text.replace('Checks a failing test alone', ' '.join(['behaviour'] * 15))
text = text.replace('Changed working code for a flaky test', ' '.join(['reason'] * 25))
text = text.replace('(new)', '(trigger)')
text += '\n## Not in this PR\n\n' + '\n'.join(['- Follow up → `~/other/`'] * 5) + '\n'
path.write_text(text)
PY
chk 'all exact word and item caps plus trigger state pass' run "$body"

echo '== Section and collapsed-block failures =='
printf 'No changes heading\n' > "$body"; chk 'Changes is mandatory' fails "$body"
chk 'unknown Notes section fails' reject_append '## Notes'
good; printf '\n## Needs your call\n' >> "$body"; chk 'out-of-order section fails' fails "$body"
chk 'duplicate section fails' reject_append '## Changes'
chk 'wrong heading level fails' reject_append '# Notes'
chk 'None placeholder fails' reject_append 'None'
chk 'bullet None placeholder fails' reject_append '- None'
good; append_details 'First notes.'; append_details 'Second notes.'
chk 'two exact details blocks fail' fails "$body"
chk 'unclosed details fail' reject_append '<details>'
chk 'orphan closing details fails' reject_append '</details>'
chk 'reversed details fail' reject_append '</details><details>'
chk 'details open attribute fails' reject_append $'<details open><summary>Review notes</summary>\n\nChecks pass.\n\n</details>'
chk 'different summary fails' reject_append $'<details><summary>Other notes</summary>\n\nChecks pass.\n\n</details>'
chk 'summary on its own line fails' reject_append $'<details>\n<summary>Review notes</summary>\n\nChecks pass.\n\n</details>'
chk 'indented details wrapper fails' reject_append $' <details><summary>Review notes</summary>\n\nChecks pass.\n\n</details>'
chk 'indented closing tag fails' reject_append $'<details><summary>Review notes</summary>\n\nChecks pass.\n\n </details>'
chk 'uppercase details wrapper fails' reject_append $'<DETAILS><summary>Review notes</summary>\n\nChecks pass.\n\n</DETAILS>'
good; append_details 'Checks pass.'; printf '\n## Not in this PR\n' >> "$body"
chk 'visible section after details fails' fails "$body"
chk 'visible prose after details fails' reject_append '<details>x</details> Extra visible copy'
good; append_details 'Checks pass.'; printf '\nExtra visible copy\n' >> "$body"
chk 'visible prose after exact details fails' fails "$body"
good; append_details 'Checks pass.'; printf '\nGenerated with an agent.\n' >> "$body"
chk 'host attribution after details passes' run "$body"
for fence in '```' '~~~'; do
  good; printf '\n%s\nChecks pass.\n%s\n' "$fence" "$fence" >> "$body"
  chk "$fence fence in visible part fails" fails "$body"
  good; append_details "$fence"$'\nChecks pass.\n'"$fence"
  chk "$fence fence inside exact details fails" fails "$body"
done
chk 'fenced literal details tags fail' reject_append $'```html\n<details><summary>Review notes</summary>\n\nChecks pass.\n\n</details>\n```'
good; printf '\n<details open><summary>Review notes</summary>\n\nBacklog `.mentor/plans/demo/plan.md`\n\n</details>\n' >> "$body"
run "$body"
chk 'invalid details contents are scanned as visible words' grep -q '^visible words:' "$ROOT/out"
chk 'invalid details contents are scanned as visible paths' grep -q '^visible paths:' "$ROOT/out"

echo '== HTML comment failures =='
cat > "$body" <<'EOF'
<opening sentence>

## Changes
| # | Agent now… | Because in the session… | Where |
|---|---|---|---|
| 1 | x | y | `a/b.md` (edit) |

<!-- <details><summary>Review notes</summary> -->

- Backlog .mentor/x

</details>
EOF
chk 'commented-out opening wrapper fails' fails "$body"
chk 'commented-out wrapper names the comment' grep -qx 'html comment: not allowed in a retro PR body' "$ROOT/out"
chk 'plain HTML comment fails' reject_append '<!-- note -->'
chk 'plain HTML comment names the comment' grep -qx 'html comment: not allowed in a retro PR body' "$ROOT/out"
good; append_details '<!-- first --> <!-- second -->'
chk 'HTML comments inside exact details fail' fails "$body"
chk 'multiple HTML comments produce one violation line' test "$(grep -c '^html comment:' "$ROOT/out")" = 1

echo '== Visible prose failures =='
for word in lens epoch synthesizer node manifest overlay Accepted Rejected Backlog Leftover; do
  chk "banned visible word $word fails" reject_append "$word"
done
chk 'visible mentor evidence path fails' reject_append 'Evidence: `.mentor/plans/demo/plan.md`'
chk 'GitHub issue-like reference fails' reject_append 'See change #123.'
chk 'GitLab issue-like reference fails' reject_append 'See change !123.'

echo '== Redaction in the entire uploaded body =='
chk 'email address fails' reject_append 'person@example.com'
for secret in ghp_example gho_example glpat-example sk-example xoxa-example xoxb-example xoxp-example AKIA1234567890ABCDEF '-----BEGIN PRIVATE KEY-----'; do
  chk "token/key shape $secret fails" reject_append "$secret"
done
for address in 10.1.2.3 172.16.1.2 192.168.1.2 127.0.0.1 fd00::1 fe80::1 8.8.8.8 203.0.113.7 2001:db8::1 2001:4860:4860:0:0:0:0:8888 :: ::1 ::ffff:8.8.8.8 0.0.0.0 255.255.255.255; do
  chk "IP $address fails" reject_append "$address"
done
for literal in v6.5.0 1.2.3 12:30:45 std::string Foo::bar 00:1a:2b:3c:4d:5e 1.2.3.4.5 256.8.8.8 8.256.8.8 8.8.256.8 8.8.8.256; do
  good; printf '\n%s\n' "$literal" >> "$body"
  chk "non-IP $literal passes" run "$body"
done
for address in 8.8.8.8 203.0.113.7 2001:db8::1 fe80::1; do
  good; append_details "$address"
  chk "collapsed IP $address fails" fails "$body"
done
for location in visible collapsed; do
  for address in 'Peer 2001:db8::1: refused' '(fe80::1)' '2001:db8::1.' '8.8.8.8,' '[2001:db8::1]:443' '::ffff:192.0.2.1' '2001:db8::1:refused' '2001:db8::1:ERROR' '2001:db8::1:ERROR:refused'; do
    chk "$location punctuated IP $address fails redaction" reject_ip "$location" "$address"
  done
done
chk 'IPv4 followed by sentence punctuation fails' reject_append 'Use 8.8.8.8.'
chk 'IPv6 followed by sentence punctuation fails' reject_append 'Use 2001:db8::1.'
chk 'named macOS home path fails' reject_append '/Users/person/project/file.md'
chk 'named Linux home path fails' reject_append '/home/person/project/file.md'
good; printf '\nUse `~/project/file.md`.\n' >> "$body"
chk 'redacted home path passes' run "$body"
good; append_details 'person@example.com'
chk 'collapsed email still fails' fails "$body"
good; append_details '10.2.3.4'
chk 'collapsed private IP still fails' fails "$body"
chk 'missing body refuses' fails "$ROOT/missing.md"
chk 'missing argument refuses' fails
chk 'extra argument refuses' fails "$body" "$body"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
