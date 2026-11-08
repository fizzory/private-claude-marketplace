#!/usr/bin/env bash
# Static and executable checks for the Mentor Claude Code/Codex portability contract.
set -euo pipefail

plugin_root="$(cd "$(dirname "$0")/.." && pwd -P)"

python3 - "$plugin_root" <<'PY'
import ast
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "plugin.json").read_text())
assert manifest["extensions"]["com.openai"]["hooks"] == []

capabilities = json.loads((root / "capabilities.json").read_text())
assert capabilities["tier"] == "dual-enhanced"
assert capabilities["hosts"]["claude"]["status"] == "supported"
assert capabilities["hosts"]["codex"]["status"] == "supported"
assert capabilities["hosts"]["codex"]["hooks"] is False
workflows = {workflow["name"]: workflow for workflow in capabilities["workflows"]}
tracking = workflows["planning"]["fallback"]
for declaration in (
    "Claude-only hooks:",
    "per-prompt plan pointer (context-gate.sh)",
    "SessionStart re-attachment (plan-reattach.sh)",
    "automatic hook-recorded plan_sha256 hashes on Write/Edit (plan-open.sh)",
    "plan-state.sh record-write <slug>",
    "drift <slug> (known/changed/unknown)",
    "portable record-write, drift and tick commands",
):
    assert declaration in tracking, declaration
for host in ("claude", "codex"):
    assert workflows["planning"][host]["status"] == "supported"

hooks = json.loads((root / "hooks" / "hooks.json").read_text())["hooks"]
assert len(hooks["SessionStart"]) == 1
reattach = hooks["SessionStart"][0]
assert "matcher" not in reattach  # Includes clear/fork as well as startup/resume/compact.
assert reattach["hooks"][0]["command"] == 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-reattach.sh"'
assert (root / "hooks" / "plan-reattach.sh").is_file()

skills = sorted((root / "skills").glob("*/SKILL.md"))
assert len(skills) == 7, len(skills)
skill_names = {skill.parent.name for skill in skills}
for workflow in workflows.values():
    assert set(workflow["skills"]) <= skill_names, workflow["name"]
assert workflows["planning"]["skills"] == ["planning", "grilling"]
assert workflows["delivery"]["skills"] == ["shipping", "merging"]
assert "Retrospective:" in tracking
assert "skills/planning/references/playbooks.md" in tracking
assert "software-change reference" in workflows["delivery"]["fallback"]
mapped_skills = [name for workflow in workflows.values() for name in workflow["skills"]]
assert len(mapped_skills) == len(set(mapped_skills))

references = root / "skills" / "planning" / "references"
playbooks = references / "playbooks"
new_playbook_names = ("investigation", "hillclimb", "prototype")
playbook_names = ("software-change", "retrospective", *new_playbook_names)
overlays = [playbooks / f"{name}.md" for name in playbook_names]
slots = (
    "Research directives",
    "Definition of done",
    "Extra always-pause items",
    "Deliver mode",
    "Evidence kinds",
    "Run rules",
)
assert {path.stem for path in playbooks.glob("*.md")} == set(playbook_names)
assert not list(playbooks.rglob("SKILL.md"))
for skill in [*skills, *overlays]:
    text = skill.read_text()
    assert "Use a structured question UI when the host offers one" in text, skill
    assert "PLUGIN_ROOT" in text, skill
    assert "~/.claude/mentor/_no-repo" not in text, skill

for overlay in overlays:
    assert overlay.is_file(), overlay
    text = overlay.read_text()
    assert text.startswith("Overlay a mentor plan run loads when"), overlay
    assert not text.startswith("---\n"), overlay
    assert "## Host portability" in text, overlay
    required_slots = slots if overlay.stem in new_playbook_names else slots[:5]
    for number, slot in enumerate(required_slots, 1):
        assert re.search(rf"^#{{2,3}} {number}\. {re.escape(slot)}(?: |$)", text, re.M), (overlay, slot)
    assert overlay.stem in tracking, overlay.stem

software = overlays[0].read_text()
goal_check = software.split("- **Goal check**:", 1)[1].split("- **`Done when:`**", 1)[0]
assert "git rev-parse HEAD" in goal_check
assert "git status --porcelain --untracked-files=all" in goal_check
assert software.index('Skill(skill="mentor:shipping")') < software.index('Skill(skill="mentor:merging")')
assert "per-check evidence bundle in every verdict" in software
retro = overlays[1].read_text()
assert "Local edits only, then the Done review" in retro
assert "Editing-only rationale" in retro
assert "never co-loaded" in retro

investigation = (playbooks / "investigation.md").read_text()
for declaration in ("read-only", "Cite every claim", "**measured**", "**inferred**", "**guess**", "Ship nothing."):
    assert declaration in investigation, declaration
hillclimb = (playbooks / "hillclimb.md").read_text()
for declaration in ("baseline and noise floor", "Before approval", "maximum attempt", "target met AND at least N attempts logged", "dead end, never", "software-change is the sole delivery owner", "a plateau is not a stop"):
    assert declaration in hillclimb, declaration
prototype = (playbooks / "prototype.md").read_text()
for declaration in ("goal is the prototype itself", "mid-plan fork", "previewing", "Name the decision", "observed comparison evidence", "Never ship prototype code"):
    assert declaration in prototype, declaration

resources = ("evidence-graph", "lens-judgment", "lens-tooling", "lens-divergent", "synthesizer", "rationale")
for name in resources:
    resource = playbooks / "retrospective" / f"{name}.md"
    assert resource.is_file(), resource
    if name not in ("evidence-graph", "rationale"):
        assert "Open this brief with the plan-level Goal: line verbatim" in resource.read_text(), resource
    if name != "rationale":
        assert f"retrospective/{name}.md" in retro, name
# Every relative Markdown link in the moved bodies/resources must resolve.
for resource in [*overlays, *(playbooks / "retrospective").glob("*.md")]:
    for link in re.findall(r"\]\(([^)]+)\)", resource.read_text()):
        if not re.match(r"[a-z]+:|#", link):
            assert (resource.parent / link.split("#", 1)[0]).is_file(), (resource, link)

index = (references / "playbooks.md").read_text()
indexed = dict(re.findall(r"^\| ([a-z-]+) \| Loads when.*\]\(([^)]+)\) \|$", index, re.M))
assert set(indexed) == set(playbook_names)
for name, relative_path in indexed.items():
    assert relative_path == f"playbooks/{name}.md", relative_path
    assert (references / relative_path).is_file(), relative_path
    alias = f"playbook-{name}"
    assert not (root / "skills" / alias).exists(), alias
for name in ("software-change", "retrospective"):
    alias = f"playbook-{name}"
    assert re.search(rf"`{alias}` to \*\*{name}\*\*", index), alias
for exclusion in ("how/why question outside a plan loads nothing", "plain fix with no metric", "mid-plan fork", "previewing"):
    assert exclusion in index, exclusion
assert "after `## Playbook:` or on the next non-empty line after `## Playbook`" in index
assert "Both aliases work in either format" in index
assert "leave old plans unchanged" in index

harness = (root / "evals" / "harness.py").read_text()
assert 'args[0] in ("claude", "codex")' in harness
assert '".agents"' in harness
assert '"codex", "exec"' in harness
registry = next(node for node in ast.parse(harness).body
                if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "SKILLS" for target in node.targets))
assert set(ast.literal_eval(registry.value)) == skill_names

evals = json.loads((root / "evals" / "evals.json").read_text())
assert set(evals["skills_in_play"]) == skill_names
assert all(case["expected"] in skill_names | {"none"} for case in evals["evals"])
direct_plan = next(case for case in evals["evals"] if case["id"] == 20)
assert direct_plan["expected"] == "planning"
assert all(case["expected"] == "planning" for case in evals["evals"] if case["id"] in (77, 78, 79, 80))
planning = (root / "skills" / "planning" / "SKILL.md").read_text()
description = planning.split("---", 2)[1]
for trigger in ("retro", "retrospective", "reflect on this session", "lessons learned", "turn this session into a skill"):
    assert trigger in description, trigger
assert "NOT for batch harvesting across sessions" in description
command = (root / "commands" / "retro.md").read_text()
assert 'Skill({"skill": "mentor:planning"})' in command
assert "skills/planning/references/playbooks.md" in command

for host in ("claude", "codex"):
    adapter = (root / "adapters" / host / "README.md").read_text()
    assert "../../skills/planning/references/playbooks.md" in adapter, host
    for name in playbook_names:
        assert f"../../skills/planning/references/playbooks/{name}.md" in adapter, (host, name)
    for reference in ("principles.md", "verifier-contract.md"):
        assert f"../../skills/planning/references/{reference}" in adapter, (host, reference)
    assert "#decision-maker" in adapter and "#implement" in adapter, host
    assert "save `verdicts/step-N.md` → PASS row → `record-write` → tick" in adapter, host

# Codex retains the explicit serial fallback, including verdict-gated self-graded ticks.
codex = (root / "adapters" / "codex" / "README.md").read_text()
assert "`Grading: self-graded` PASS can tick when subagents are unavailable" in codex
assert "a saved Grading: self-graded PASS can tick when subagents are unavailable" in tracking

readme = (root / "README.md").read_text()
skill_table = readme.split("| Skill | What it does |", 1)[1].split("\n\n", 1)[0]
assert set(re.findall(r"^\| `([a-z-]+)` \|", skill_table, re.M)) == skill_names
reference_table = readme.split("| Reference | What it supplies |", 1)[1].split("\n\n", 1)[0]
assert set(re.findall(r"^\| \[([a-z-]+)\]", reference_table, re.M)) == set(playbook_names)
for resource in (root / "README.md", *(root / "adapters" / host / "README.md" for host in ("claude", "codex"))):
    for link in re.findall(r"\]\(([^)]+)\)", resource.read_text()):
        if not re.match(r"[a-z]+:|#", link):
            assert (resource.parent / link.split("#", 1)[0]).is_file(), (resource, link)
PY

python3 -m unittest discover -s "$plugin_root/evals" -p test_harness.py

printf 'PASS mentor dual-host contract\n'
