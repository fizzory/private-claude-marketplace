#!/usr/bin/env bash
# Execute the retro facade's entry check in isolated repositories.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
REPO="$ROOT/repo"
mkdir -p "$SANDBOX" "$REPO"
trap 'rm -rf "$ROOT"' EXIT
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
STATE="$REPO/.mentor"
mkdir -p "$STATE/plans/demo"
printf '# Retro\n\n## Playbook: playbook-retrospective\n' > "$STATE/plans/demo/plan.md"
python3 - "$HOOKS/../commands/retro.md" "$ROOT/entry.sh" <<'PY'
import re, sys, textwrap
from pathlib import Path
code = re.search(r'```bash\n(.*?)\n\s*```', Path(sys.argv[1]).read_text(), re.S).group(1)
Path(sys.argv[2]).write_text(textwrap.dedent(code))
PY
. "$HOOKS/lib/state.sh"
WT_ID="$(mentor_worktree_id "$REPO")"
PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
run() { (cd "$REPO" && HOME="$SANDBOX" CLAUDE_CONFIG_DIR="$SANDBOX/config" CLAUDE_PLUGIN_ROOT="$HOOKS/.." CLAUDE_CODE_SESSION_ID=entry-session bash "$ROOT/entry.sh") > "$ROOT/out" 2>&1; }
fails() { ! run; }

echo '== Entry leaves edit gates intact =='
chk 'fresh entry proceeds' run
chk 'fresh entry does not arm a gate' test ! -e "$STATE/plans/.planning.$WT_ID"
printf 'session=another\n' > "$STATE/plans/.planning.$WT_ID"
chk 'live own gate refuses' fails
chk 'own gate survives refusal' grep -qx 'session=another' "$STATE/plans/.planning.$WT_ID"
rm -f "$STATE/plans/.planning.$WT_ID"
printf 'session=another\n' > "$STATE/plans/.planning"
chk 'live legacy gate refuses' fails
chk 'legacy gate survives refusal' grep -qx 'session=another' "$STATE/plans/.planning"
rm -f "$STATE/plans/.planning"

echo '== Saved runs are surfaced for identity-aware resume =='
printf 'slug=demo\nstarted=2026-11-18T00:00:00Z\n' > "$STATE/.run-entry-session"
cp "$STATE/.run-entry-session" "$ROOT/run-before"
printf '{"state":"in_progress"}\n' > "$STATE/plans/demo/.state.json"
chk 'in-progress run can reach the identity check' run
chk 'entry surfaces the exact saved slug' grep -qx 'EXISTING_RUN=demo' "$ROOT/out"
chk 'entry surfaces the exact stored state' grep -qx 'STATE=in_progress' "$ROOT/out"
chk 'entry never replaces the run marker' cmp -s "$ROOT/run-before" "$STATE/.run-entry-session"
printf '{"state":"approved","note":"paused: row 2"}\n' > "$STATE/plans/demo/.state.json"
chk 'paused run can reach the identity check' run
chk 'paused stored state stays approved' grep -qx 'STATE=approved' "$ROOT/out"
chk 'paused note is preserved' grep -q 'paused: row 2' "$STATE/plans/demo/.state.json"
printf '{"state":"implemented"}\n' > "$STATE/plans/demo/.state.json"
chk 'completed run does not prevent a fresh retro' run
chk 'completed run is not surfaced as active' test ! -s "$ROOT/out"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
