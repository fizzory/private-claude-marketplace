#!/usr/bin/env python3
"""Cross-host routing and playbook-read evals; the positional CLI always runs live."""
import json
import hashlib
import os
import re
import shlex
import string
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).parent.resolve()
REPO_SKILLS = (HERE / ".." / "skills").resolve()
SKILLS = ["planning", "grilling", "previewing", "merging", "shipping",
          "constitution-authoring", "frontend-self-ex-review"]
INDEX = "planning/references/playbooks.md"
PLAYBOOKS = {f"planning/references/playbooks/{name}.md" for name in
             ("software-change", "retrospective", "investigation", "hillclimb", "prototype")}
DELIVERY_OWNERS = {name: name for name in
                   ("none", "general", *(Path(path).stem for path in PLAYBOOKS))}
DELIVERY_OWNERS["general flow"] = "general"
# Measured system/init inventory from the isolated Claude probe (2026-11-08).
# Keep exact names: a prefix wildcard would silently admit an installed competitor.
BUILTIN_SKILLS = {"deep-research", "design", "slides", "design-sync", "dataviz",
                  "artifact-diagramming", "artifact-capabilities", "update-config",
                  "verify", "debug", "code-review", "simplify", "batch",
                  "fewer-permission-prompts", "doctor", "loop", "schedule", "claude-api",
                  "workflow-authoring", "run", "run-skill-generator", "plugin-authoring"}
BUILTIN_AGENTS = {"claude", "claude-code-guide", "Explore", "general-purpose", "Plan",
                  "statusline-setup", "web-fetch"}
MANAGED_PLUGINS = {"cc-plugin-sec-default", "cc-plugin-agents-md", "cc-plugin-telemetry",
                   "cc-plugin-privacy", "cc-plugin-plugin-authoring"}

SELECTION_BOUNDARY = """This is a workflow-selection evaluation in a disposable project.
Select the skill appropriate to the user's request normally. Stop before approval,
implementation, delegation, grading, or delivery, even if the request says to run.
If planning is selected, follow its instructions only through selecting or resolving
saved playbooks and their single delivery owner. Read the selected references using
the file-read tool, not a search for their names. Do not do their research or run rules.
For a resumed plan, inspect its saved history and identify which inherited claims
need re-checking, without executing those checks or changing the saved plan.
Finish with exactly one delivery owner: if planning is selected and no playbook is
chosen, use \"general\"; use \"none\" only when planning was not selected.
Also report the step numbers needing re-check. Prefer this template; replace <owner>:
EVAL_SELECTION {"delivery_owner":"<owner>","history_to_recheck":[]}
The marker may appear anywhere in your final message, fenced or not. Use exactly
these two JSON keys. Replace [] with a JSON array of positive, distinct step numbers
only when inherited steps need re-checking. The allowed owner values are exactly:
none, general, general flow (an alias for general), software-change, retrospective,
investigation, hillclimb, prototype. Use one exact value, without explanation.
Alternatively finish with these two whole labeled lines:
Delivery owner: <owner>
History to recheck: []
The history value must be a single-line JSON array (for example [2]), or exactly
none, nothing, or []. No punctuation, explanation, or unlabeled continuation lines
may follow either labeled field; only the other field or a standalone marker may
follow. If both formats are present, their owner and history must agree.
Skill selection and completed reference reads are checked from tool events.
Do not ask for approval or perform the user's task in this evaluation.
Skip plan scaffolding: do not create or edit any files at this selection boundary.
"""
ROUTING_BOUNDARY = """This is a workflow-routing evaluation in a disposable project.
Select a skill normally if one matches the user's request. Stop after selecting it;
do not implement, delegate, ask approval, or perform the user's task. If no skill
matches, answer briefly without using one.
"""


def fm_field(fm, key):
    lines = fm.split("\n"); out = []; i = 0
    while i < len(lines):
        m = re.match(rf"^{key}:\s*(.*)$", lines[i])
        if m:
            rest = m.group(1).strip()
            if rest in ("|", "|-", ">", ">-"):
                i += 1
                while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
                    out.append(lines[i].strip()); i += 1
                return " ".join(x for x in out if x)
            out.append(rest); i += 1
            while i < len(lines) and lines[i].startswith("  "):
                out.append(lines[i].strip()); i += 1
            return " ".join(out).strip()
        i += 1
    return ""


def skill_directory(root, host):
    return root / (".claude" if host == "claude" else ".agents") / "skills"


def stage_project(root: Path, descriptions: dict, host: str, case=None):
    """New project per case/repetition; selection uses unmodified real skill trees."""
    case = case or {}
    skill_root = skill_directory(root, host)
    for name, desc in descriptions.items():
        d = skill_root / name
        if "expected_reads" in case:
            shutil.copytree(REPO_SKILLS / name, d)
        else:
            d.mkdir(parents=True, exist_ok=True)
            indented = "\n  ".join(desc.split("\n"))
            (d / "SKILL.md").write_text(
                f"---\nname: {name}\ndescription: |\n  {indented}\n---\n\n"
                f"# {name}\n\nSTOP. Report that you selected the `{name}` skill, then end your turn.\n")
    # Seed every case, not just a shared caller-managed scratch dir.
    subprocess.run([sys.executable, str(HERE / "seed.py"), str(root)],
                   check=True, stdout=subprocess.DEVNULL)
    for relative, content in case.get("fixture_files", {}).items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    if host == "codex":
        (root / "AGENTS.md").write_text(
            SELECTION_BOUNDARY if "expected_reads" in case else ROUTING_BOUNDARY)


def child_command(query, model, host, selection=False):
    boundary = SELECTION_BOUNDARY if selection else ROUTING_BOUNDARY
    if host == "claude":
        cmd = ["claude", "-p", query, "--output-format", "stream-json", "--verbose",
               "--include-partial-messages", "--setting-sources", "project,local",
               "--strict-mcp-config", "--disallowedTools", "mcp__*",
               "--allowedTools", "Read,Glob,Grep,Skill", "--append-system-prompt", boundary]
        # Auth stays in the real profile; instruction/memory isolation is child-local.
        env = {k: v for k, v in os.environ.items()
               if k not in ("CLAUDECODE", "PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT")}
        env.update(CLAUDE_CODE_DISABLE_CLAUDE_MDS="1", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    else:
        cmd = ["codex", "exec", "--json", "--ephemeral", "--skip-git-repo-check",
               "--sandbox", "read-only"]
        env = dict(os.environ)
    if model:
        cmd += ["--model", model]
    if host != "claude":
        cmd += [query]
    return cmd, env


def init_contamination(event, staged):
    """Fail closed when inventories are absent, malformed, or not explicitly allowed."""
    bad = {}
    for key, allowed in (("skills", set(staged) | BUILTIN_SKILLS),
                         ("agents", BUILTIN_AGENTS), ("plugins", MANAGED_PLUGINS)):
        items = event.get(key)
        if not isinstance(items, list):
            bad[key] = ["<missing or malformed inventory>"]
            continue
        names = [item.get("name") if isinstance(item, dict) else item for item in items]
        unexpected = [name for name in names if not isinstance(name, str) or name not in allowed]
        if key == "plugins":
            unexpected += [item for item in items if isinstance(item, dict) and
                           (item.get("path") != "builtin" or item.get("source") != f"{item.get('name', '')}@builtin")]
        if unexpected:
            bad[key] = unexpected
    if event.get("mcp_servers") != []:
        bad["mcp_servers"] = event.get("mcp_servers", "<missing inventory>")
    return bad


def read_path(path, root, host):
    """Canonical relative paths only for files actually inside this staged project."""
    if not isinstance(path, str):
        return None
    absolute = Path(path) if Path(path).is_absolute() else root / path
    absolute = absolute.resolve()
    try:
        return str(absolute.relative_to(skill_directory(root, host).resolve()))
    except ValueError:
        try:
            return str(absolute.relative_to(root.resolve()))
        except ValueError:
            return str(absolute)


def without_shell_comments(command):
    """Strip comments at unquoted word boundaries, preserving literal hashes."""
    output = []
    quote = None
    word_start = True
    i = 0
    while i < len(command):
        char = command[i]
        if char == "\\" and quote != "'" and i + 1 < len(command):
            output.extend(command[i:i + 2])
            i += 2
            word_start = False
            continue
        if quote:
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        elif char == "#" and word_start:
            end = command.find("\n", i)
            i = len(command) if end == -1 else end
            continue
        output.append(char)
        word_start = quote is None and (char.isspace() or char in ";&|<>()")
        i += 1
    return "".join(output)


def command_words(command, allow_variables=False, raw_words=False):
    """Tokenize literal commands once, retaining child-shell cwd isolation."""
    wrapped = False
    while True:
        if "`" in command or "$(" in command or ("$" in command and not allow_variables):
            return None, wrapped
        command = without_shell_comments(command)
        try:
            lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()\n")
            lexer.whitespace = " \t\r"
            lexer.whitespace_split = True
            lexer.commenters = ""  # A # inside an unquoted word is literal shell data.
            if raw_words:
                tokens = []
                while True:
                    # shlex can look one punctuation character ahead. Keep the
                    # original token spelling so quotes/escapes cannot hide a
                    # long literal behind something resembling an expansion.
                    start = lexer.instream.tell() - len(lexer._pushback_chars)
                    word = lexer.get_token()
                    if word is None:
                        break
                    end = lexer.instream.tell() - len(lexer._pushback_chars)
                    tokens.append((word, command[start:end].strip()))
                words = [word for word, _ in tokens]
            else:
                words = list(lexer)
        except ValueError:
            return None, wrapped
        # Codex may wrap the actual command in a login shell.
        if len(words) != 3 or Path(words[0]).name not in ("bash", "zsh", "sh") or words[1] not in ("-c", "-lc"):
            return tokens if raw_words else words, wrapped
        command, wrapped = words[2], True


def reader_operands(words):
    """Recognize supported reader syntax without executing a shell or reader."""
    if not words or words[0] not in ("cat", "sed", "head", "tail"):
        return None
    if any(word and all(char in ";&|<>()\n" for char in word) for word in words):
        return None
    reader, *args = words
    if reader == "sed":
        if args[:1] == ["-n"]:
            args = args[1:]
        if args[:1] == ["-e"]:
            args = args[1:]
        if not args or not re.fullmatch(r"(?:\d+|\$)(?:,(?:\d+|\$))?p", args[0]):
            return None
        args = args[1:]
    files = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            return files + args[i + 1:]
        if not arg.startswith("-"):
            files.append(arg)
        elif reader == "cat":
            if not (re.fullmatch(r"-[AbbenstuvET]+", arg) or arg in (
                    "--show-all", "--number-nonblank", "--show-ends", "--number",
                    "--squeeze-blank", "--show-tabs", "--show-nonprinting")):
                return None
        elif reader in ("head", "tail"):
            if arg in ("-n", "-c", "--lines", "--bytes"):
                i += 1
                if i == len(args) or not re.fullmatch(r"[+-]?\d+", args[i]):
                    return None
            elif not (re.fullmatch(r"-(?:[qv]+|\d+|[nc][+-]?\d+)", arg)
                      or re.fullmatch(r"--(?:lines|bytes)=[+-]?\d+", arg)
                      or arg in ("--quiet", "--silent", "--verbose")):
                return None
        else:
            return None
        i += 1
    return files


def literal_command_reads(words):
    """Recognize simple read tokens without claiming completion evidence."""
    return [word for word in (reader_operands(words) or []) if word.endswith(".md")]


def command_reads(command):
    """Recognize literal cat/sed/head/tail reads, not mentions in search/output text."""
    words, _ = command_words(command)
    return literal_command_reads(words)


def completed_command_reads(command, cwd, root, output, success):
    """Credit shell reads only when the returned output contains the file."""
    words, wrapped = command_words(command)
    if not command_printers_allowed(command, read_credit=True):
        return [], cwd if wrapped else None
    paths, final_cwd = completed_word_reads(words, cwd, root, output, success)
    return paths, cwd if wrapped else final_cwd


def literal_print_output(words, allow_expansions=False):
    """Allow harmless echo diagnostics; never render their text as read evidence."""
    if not words or words[0] != "echo":
        return False
    for arg in words[1:]:
        literal = []
        expanded = False
        quote = None
        i = 0
        while i < len(arg):
            char = arg[i]
            if char in ("'", '"') and (quote is None or quote == char):
                quote = char if quote is None else None
            elif char == "$" and quote != "'":
                variable = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*", arg[i:])
                if variable:
                    expanded = True
                    i += variable.end()
                    continue
                if re.match(r"\$\{[A-Za-z_][A-Za-z0-9_]*", arg[i:]):
                    expanded = True
                    depth, end = 1, i + 2
                    while end < len(arg) and depth:
                        depth += (arg[end] == "{") - (arg[end] == "}")
                        end += 1
                    if depth:
                        return False
                    i = end
                    continue
                literal.append(char)
            else:
                literal.append(char)
            i += 1
        literal = "".join(literal)
        if allow_expansions and expanded:
            continue
        if re.fullmatch(r"-[nEe]+", literal) or "\\" in literal or "%" in literal or len(literal) >= 40:
            return False
        variable_diagnostic = expanded or bool(re.fullmatch(
            r"\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*[^{}]*\})", literal))
        if expanded and not allow_expansions:
            return False
        if not (allow_expansions and variable_diagnostic) and any(char not in string.punctuation for char in literal):
            return False
    return True


def without_echo_redirections(tokens):
    """Remove harmless echo redirections before validating its printed arguments."""
    output = []
    name = None
    i = 0
    while i < len(tokens):
        word, raw = tokens[i]
        if word in (";", "&&", "|", "\n"):
            name = None
        elif name is None:
            name = word
        if name == "echo" and word in (">", ">&"):
            if output and output[-1][0] in ("1", "2"):
                output.pop()
            if i + 1 == len(tokens) or tokens[i + 1][0] not in (
                    ("/dev/null",) if word == ">" else ("1", "2")):
                return None
            i += 2
            continue
        output.append((word, raw))
        i += 1
    return output


def command_printers_allowed(command, read_credit=False):
    """Apply the printer allowlist to original spellings, including shell wrappers."""
    tokens, _ = command_words(command, allow_variables=True, raw_words=True)
    tokens = without_echo_redirections(tokens) if tokens is not None else None
    if tokens is None:
        return False
    segments = [[]]
    for word, raw in tokens:
        if word and all(char in ";&|<>()\n" for char in word):
            if "<<" in word:
                return False
            segments.append([])
        else:
            segments[-1].append((word, raw))
    for segment in filter(None, segments):
        name = segment[0][0]
        if name in ("echo", "printf") and not literal_print_output(
                [name] + [raw for _, raw in segment[1:]], allow_expansions=not read_credit):
            return False
        if name == "sed":
            args = [word for word, _ in segment[1:]]
            if args[:1] == ["-n"]:
                args = args[1:]
            scripts = []
            if args[:1] != ["-e"]:
                scripts = args[:1]
            for index, arg in enumerate(args[:-1]):
                if arg == "-e":
                    scripts.append(args[index + 1])
            if any(re.search(r"(?:^|[;\n])\s*(?:\d+|\$)?(?:,(?:\d+|\$))?[iac]",
                             script) for script in scripts):
                return False
    return True


def completed_word_reads(words, cwd, root, output, success):
    """Apply completion evidence policy to the shared command tokens."""
    def absolute(path):
        return Path(path).resolve() if Path(path).is_absolute() else (
            (cwd / path).resolve() if cwd is not None else None)

    # This is a conservative literal-command observer, not a shell evaluator.
    if words is None or any("$" in word for word in words) or not isinstance(output, str):
        return [], None
    tokens = without_echo_redirections([(word, word) for word in words])
    if tokens is None:
        return [], None
    words = [word for word, _ in tokens]
    if any(word in ("||", "|", "&", "(", ")", "<<") for word in words):
        return [], None
    segments = [[]]
    for word in words:
        if word in (";", "&&", "\n"):
            segments.append([])
        else:
            segments[-1].append(word)
    candidates = []
    diagnostics = output.splitlines()
    operands = {}
    segments = [segment for segment in segments if segment]
    for index, segment in enumerate(segments):
        if segment[0] == "cd" and len(segment) == 2:
            cwd = absolute(segment[1])
            if cwd is None or not cwd.is_dir():
                return [], None
        elif segment[0] in ("echo", "printf"):
            if not literal_print_output(segment):
                return [], None
        elif segment[0] in ("cat", "sed", "head", "tail", "ls", "pwd"):
            if any("$" in word for word in segment):
                return [], None
            operands[index] = [(name, absolute(name)) for name in (reader_operands(segment) or [])]
            for name in literal_command_reads(segment):
                path = absolute(name)
                if path is not None and path.is_relative_to(root.resolve()):
                    candidates.append((path, index, segment[0], name))
        else:
            return [], None
    paths = []
    for path, index, reader, spelling in candidates:
        errors = [line for line in diagnostics if re.match(r"(?:\S*/)?" + reader + r":", line)]

        def failed_operand(name, absolute_name):
            return any(re.search(r"(?<![\w./-])" + re.escape(alias) + r"(?![\w./-])", line)
                       for alias in (name, str(absolute_name)) for line in errors)

        if failed_operand(spelling, path):
            continue
        # A failed final reader can still return other operands successfully.
        # Require an identified sibling failure to explain its nonzero status.
        if not success and index == len(segments) - 1 and not any(
                name != spelling and failed_operand(name, resolved) for name, resolved in operands[index]):
            continue
        try:
            content = path.read_text().rstrip("\n")
        except (OSError, UnicodeError):
            continue
        if content.strip() and isinstance(output, str) and output.strip() and content in output:
            paths.append(str(path))
    # A later failing command need not erase an earlier, visibly completed read.
    return paths, cwd if success or paths else None


def selection_history(value):
    """A history is an array of distinct positive integer step numbers."""
    return (isinstance(value, list) and all(type(step) is int and step > 0 for step in value)
            and len(value) == len(set(value)))


def selection_object(pairs):
    """Duplicate JSON keys cannot silently overwrite an earlier assertion."""
    report = {}
    for key, value in pairs:
        if key in report:
            raise ValueError("duplicate selection key")
        report[key] = value
    return report


def undecorated_selection_line(line):
    """Recognize decorated assertions without accepting them as canonical fields."""
    previous = None
    while line != previous:
        previous = line
        for link in reversed(list(re.finditer(r"\[([^\[\]]*)\]\(", line))):
            depth, end = 1, link.end()
            quote = None
            while end < len(line) and depth:
                if line[end] == "\\":
                    end += 2
                    continue
                if line[end] in ("'", '"') and (quote is None or quote == line[end]):
                    quote = line[end] if quote is None else None
                elif quote is None:
                    depth += (line[end] == "(") - (line[end] == ")")
                end += 1
            if not depth:
                line = line[:link.start()] + link[1] + line[end:]
        line = re.sub(r"<[^>]*>", "", line)
        line = re.sub(r"[*_`~]", "", line)
        line = re.sub(r"^\s*(?:>\s*|[-+]\s+|\d+[.)]\s+)", "", line)
    return line


def selection_report(text_blocks, final_text, errors):
    """Accept exact JSON or whole labeled lines, never normalize report prose."""
    markers = []
    decoder = json.JSONDecoder(object_pairs_hook=selection_object)
    for block in text_blocks:
        for match in re.finditer(r"\bEVAL_SELECTION\b", block):
            try:
                report, _ = decoder.raw_decode(block[match.end():].lstrip())
                markers.append(report)
                if not isinstance(report, dict) or set(report) != {"delivery_owner", "history_to_recheck"}:
                    errors.append("malformed selection boundary fields")
                    continue
                owner = report["delivery_owner"]
                if not isinstance(owner, str) or owner not in DELIVERY_OWNERS:
                    errors.append("wrong or multiple delivery owners: " + json.dumps(owner))
                if not selection_history(report["history_to_recheck"]):
                    errors.append("malformed history re-check statement")
            except ValueError:
                errors.append("malformed selection boundary JSON")
    if len(markers) > 1:
        errors.append("multiple selection boundaries")

    # Blank final marker spans only to distinguish a standalone marker from an
    # unlabeled continuation. Field values are always parsed from the original.
    remainder = list(final_text)
    final_marker = False
    for match in re.finditer(r"\bEVAL_SELECTION\b", final_text):
        final_marker = True
        value = final_text[match.end():]
        try:
            _, end = decoder.raw_decode(value.lstrip())
        except ValueError:
            continue
        end += match.end() + len(value) - len(value.lstrip())
        start = match.start()
        # A fence enclosing only the marker belongs to the marker grammar, even
        # when that marker follows the labeled fields.
        opening = re.search(r"(?m)^[ \t]*(`{3,}|~{3,})[^\n]*\n[ \t]*\Z", final_text[:start])
        if opening:
            closing = re.match(r"[ \t]*\n[ \t]*" + re.escape(opening[1]) + r"[ \t]*(?=\n|\Z)",
                               final_text[end:])
            if closing:
                start, end = opening.start(), end + closing.end()
        for index in range(start, end):
            if remainder[index] != "\n":
                remainder[index] = " "
    residue_lines = "".join(remainder).splitlines()
    labels = {"Delivery owner": "delivery_owner", "History to recheck": "history_to_recheck"}
    marker = markers[0] if len(markers) == 1 else None
    valid_marker = (isinstance(marker, dict)
                    and isinstance(marker.get("delivery_owner"), str)
                    and marker["delivery_owner"] in DELIVERY_OWNERS
                    and selection_history(marker.get("history_to_recheck")))
    report = {}
    seen = set()
    for line, residue in zip(final_text.splitlines(), residue_lines):
        undecorated = undecorated_selection_line(residue)
        assertion = re.search(r"\b(delivery\s+owner|history\s+to\s+recheck)\s*:\s*(.*)",
                              undecorated, re.I)
        match = re.fullmatch(r"(Delivery owner|History to recheck):[ \t]*(.*)", line.strip())
        if not match:
            # Supplemental prose is not a report. Compare only explicit owner
            # or history assertions with an independently valid JSON marker.
            if assertion and valid_marker:
                label, value = assertion[1].lower(), assertion[2].strip()
                if label.startswith("delivery"):
                    owner = value.split()[0] if value else ""
                    if owner in DELIVERY_OWNERS and DELIVERY_OWNERS[owner] != DELIVERY_OWNERS.get(marker.get("delivery_owner")):
                        errors.append("contradictory selection reports: delivery_owner")
                else:
                    try:
                        history = [] if value in ("none", "nothing") else json.loads(value)
                    except ValueError:
                        history = None
                    if isinstance(history, list) and history != marker.get("history_to_recheck"):
                        errors.append("contradictory selection reports: history_to_recheck")
                continue
            if seen and residue.strip():
                errors.append("unlabeled continuation after selection field")
            continue
        key, value = labels[match[1]], match[2].strip()
        if key in seen:
            errors.append("multiple selection field statements: " + key)
        seen.add(key)
        if key == "delivery_owner":
            report[key] = value
            if value not in DELIVERY_OWNERS:
                errors.append("wrong or multiple delivery owners: " + value)
        else:
            try:
                history = [] if value in ("none", "nothing") else json.loads(value)
                if not selection_history(history):
                    raise ValueError("invalid history steps")
                report[key] = history
            except ValueError:
                errors.append("malformed history re-check statement")
    if seen and set(report) != set(labels.values()):
        errors.append("incomplete labeled selection report")
    if isinstance(marker, dict):
        for key, value in report.items():
            marked = marker.get(key)
            if key == "delivery_owner":
                value = DELIVERY_OWNERS.get(value)
                marked = DELIVERY_OWNERS.get(marked) if isinstance(marked, str) else None
            if value != marked:
                errors.append("contradictory selection reports: " + key)
    # An earlier marker still cannot replace a missing or different final report.
    if final_marker:
        return marker, "marker"
    # An absent history field stays absent: cases that check it must still fail.
    return (report, "final-text") if seen else (None, None)


def selection_read_command(command):
    """Allow only selection reads/discovery; unknown shell behavior fails closed."""
    if not command_printers_allowed(command):
        return False
    words, _ = command_words(command, allow_variables=True)
    if not words:
        return False
    segments = [[]]
    i = 0
    while i < len(words):
        word = words[i]
        # Suppressing output or copying stderr to stdout cannot write a file.
        if word in (">", ">&"):
            if segments[-1] and segments[-1][-1] in ("1", "2"):
                segments[-1].pop()
            if i + 1 == len(words) or words[i + 1] not in (
                    ("/dev/null",) if word == ">" else ("1", "2")):
                return False
            i += 2
            continue
        if word in (";", "&&", "|", "\n"):
            if not segments[-1]:
                return False
            segments.append([])
        elif word and all(char in ";&|<>()\n" for char in word):
            return False
        else:
            segments[-1].append(word)
        i += 1
    for segment in segments:
        if not segment:
            return False
        name, *args = segment
        if name == "echo":
            if not literal_print_output(segment, allow_expansions=True):
                return False
            continue
        if any("$" in word for word in segment):
            return False
        if name == "cd":
            if len(args) != 1 or args[0].startswith("-"):
                return False
        elif name in ("cat", "head", "tail", "ls", "pwd"):
            if name == "tail" and any(arg in ("-f", "-F") or arg.startswith("--follow") for arg in args):
                return False
        elif name == "sed":
            # Print-only scripts; -i, w, e and substitution commands can mutate.
            script = args[1:] if args[:1] == ["-n"] else args
            if script[:1] == ["-e"]:
                script = script[1:]
            if not script or not re.fullmatch(r"(?:\d+|\$)(?:,(?:\d+|\$))?p", script[0]):
                return False
            if any(arg.startswith("-") for arg in script[1:]):
                return False
        elif name == "find":
            allowed = {"-type", "-name", "-iname", "-path", "-ipath", "-maxdepth",
                       "-mindepth", "-not", "!", "-a", "-o", "-print", "-print0"}
            if any(arg.startswith("-") and arg not in allowed for arg in args):
                return False
        elif name in ("grep", "rg"):
            if any(arg.startswith("-") and not re.fullmatch(r"-[ivEnHrln0]+", arg) for arg in args):
                return False
        elif name == "env":
            if args:  # env COMMAND executes COMMAND.
                return False
        else:
            return False
    return True


def project_snapshot(root):
    """Record every staged file, including skills and non-fixture project files."""
    snapshot = {}
    for path in root.rglob("*"):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            snapshot[relative] = ("symlink", os.readlink(path))
        elif path.is_file():
            snapshot[relative] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
    return snapshot


def returned_text(content):
    """Read tools return either a string or a list of text content blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(block["text"] for block in content if isinstance(block, dict)
                         and block.get("type") == "text" and isinstance(block.get("text"), str))
    return ""


def returned_file_data(output):
    """Native Read reminders describe the tool result; they are not file data."""
    return re.sub(r"<system-reminder>.*?(?:</system-reminder>|\Z)", "", output,
                  flags=re.S).strip()


def observe_transcript(transcript, root, host):
    """Observe completed tool calls; prose and partial-stream argument guesses don't count."""
    evidence = {"skill_events": [], "reads": [], "init": None, "contamination": {},
                "complete": False, "selection": None, "errors": [], "tool_calls": [],
                "permission_denials": []}
    pending = {}
    seen = set()
    text_blocks = []
    final_text = ""
    shell_cwd = root.resolve()
    for number, line in enumerate(transcript.splitlines()):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            if line.strip():
                evidence["errors"].append(f"malformed transcript line {number + 1}")
            continue
        if not isinstance(event, dict):
            evidence["errors"].append(f"malformed event on line {number + 1}")
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            if evidence["init"] is not None:
                evidence["errors"].append("multiple system/init inventories")
            evidence["init"] = event
            evidence["contamination"].update(init_contamination(event, SKILLS))
        if event.get("type") == "result":
            evidence["complete"] = not event.get("is_error", False) and event.get("subtype") == "success"
        if host == "codex" and event.get("type") == "turn.completed":
            evidence["complete"] = True
        if event.get("type") == "system" and event.get("subtype") == "permission_denied":
            # These system notices carry a string, not an assistant/user Message.
            if not all(isinstance(event.get(key), str) and event[key]
                       for key in ("message", "tool_name", "tool_use_id")):
                evidence["errors"].append(f"malformed permission_denied on line {number + 1}")
            else:
                evidence["permission_denials"].append(dict(event, at=number))
                # A denied read never proves a file was opened, even without a tool_result.
                pending.pop(event["tool_use_id"], None)
            continue
        message = event.get("message", {}) if event.get("type") in ("assistant", "user") else {}
        if not isinstance(message, dict):
            evidence["errors"].append(f"malformed message on line {number + 1}")
            continue
        message_text = []
        for block in message.get("content", []) if isinstance(message.get("content"), list) else []:
            if not isinstance(block, dict):
                evidence["errors"].append(f"malformed content on line {number + 1}")
                continue
            if block.get("type") == "text" and event.get("type") == "assistant":
                message_text.append(block.get("text", ""))
            if block.get("type") == "tool_use":
                call_id = block.get("id")
                if not call_id or call_id in seen:
                    continue
                seen.add(call_id)
                name, inputs = block.get("name"), block.get("input", {})
                if not isinstance(inputs, dict):
                    evidence["errors"].append("malformed tool input: " + call_id)
                    continue
                evidence["tool_calls"].append({"name": name, "input": inputs, "at": number})
                if name == "Skill":
                    # Keep the entire name, including namespaces and non-staged picks.
                    pick = inputs.get("skill", inputs.get("skill_name"))
                    if isinstance(pick, str):
                        evidence["skill_events"].append({"name": pick, "at": number})
                if name in ("Read", "Bash"):
                    pending[call_id] = (number, name, inputs)
            if block.get("type") == "tool_result" and block.get("tool_use_id") in pending:
                call_id = block["tool_use_id"]
                requested, name, inputs = pending.pop(call_id)
                success = not block.get("is_error", False)
                output = returned_text(block.get("content"))
                if name == "Bash":
                    paths, shell_cwd = completed_command_reads(
                        inputs.get("command", ""), shell_cwd, root, output, success)
                else:
                    paths = ([inputs["file_path"]] if success and returned_file_data(output)
                             and inputs.get("file_path") else [])
                for path in paths:
                    evidence["reads"].append({"path": read_path(path, root, host),
                                              "requested_at": requested, "completed_at": number,
                                              "tool_use_id": call_id})
        if event.get("type") == "assistant":
            final_text = "\n".join(message_text)
            text_blocks.append(final_text)
        item = event.get("item", {})
        if host == "codex" and event.get("type") == "item.completed":
            if item.get("type") == "agent_message":
                final_text = item.get("text", "")
                text_blocks.append(final_text)
            if item.get("type") == "command_execution":
                final_text = ""
                evidence["tool_calls"].append({"name": "command_execution", "input": item, "at": number})
                paths, _ = completed_command_reads(item.get("command", ""), root.resolve(), root,
                                                   item.get("aggregated_output", ""),
                                                   item.get("exit_code") == 0)
                for path in paths:
                    evidence["reads"].append({"path": read_path(path, root, host),
                                              "requested_at": number, "completed_at": number,
                                              "tool_use_id": item.get("id")})
    if host == "claude" and evidence["init"] is None:
        evidence["errors"].append("missing system/init inventory")
    if pending:
        evidence["errors"].append("unfinished file reads: " + ", ".join(pending))
    # Codex selects a skill by opening SKILL.md, rather than a Skill tool call.
    if host == "codex":
        for read in evidence["reads"]:
            parts = read["path"].split("/")
            if len(parts) == 2 and parts[1] == "SKILL.md":
                evidence["skill_events"].append({"name": parts[0], "at": read["completed_at"]})
            elif read["path"].endswith("/SKILL.md"):
                pick = "external:" + Path(read["path"]).parent.name
                evidence["skill_events"].append({"name": pick, "at": read["completed_at"]})
    evidence["skills"] = [event["name"] for event in evidence["skill_events"]]
    unexpected_picks = sorted(set(evidence["skills"]) - set(SKILLS) - BUILTIN_SKILLS)
    if unexpected_picks:
        evidence["contamination"]["skill_picks"] = unexpected_picks
    evidence["selection"], evidence["selection_source"] = selection_report(
        text_blocks, final_text, evidence["errors"])
    if evidence["selection_source"] == "final-text":
        evidence["selection_text"] = final_text
    return evidence


def score_case(case, evidence, returncode=0, timed_out=False):
    reasons = list(evidence["errors"])
    if evidence["contamination"]:
        reasons.append("incomplete (contaminated): " + json.dumps(evidence["contamination"], sort_keys=True))
    if timed_out or returncode != 0 or not evidence["complete"]:
        reasons.append(f"incomplete transcript (exit={returncode}, timeout={timed_out})")
    if evidence.get("fixture_changes"):
        reasons.append("saved fixture changed: " + ", ".join(evidence["fixture_changes"]))
    picks = evidence["skills"]
    # Released routing semantics: `none` means no Mentor skill was selected.
    # Only explicitly allowlisted built-ins are excluded from this comparison.
    routing_picks = [pick for pick in picks if pick not in BUILTIN_SKILLS]
    got = routing_picks[0] if routing_picks else "none"
    if got != case["expected"]:
        reasons.append(f"expected skill {case['expected']}, got {got}")
    if any(pick != got for pick in routing_picks):
        reasons.append("unexpected additional skill picks: " + ", ".join(routing_picks))
    if "expected_reads" in case:
        paths = [read["path"] for read in evidence["reads"]]
        expected = set(case["expected_reads"])
        missing = expected - set(paths)
        unexpected = (set(paths) & (PLAYBOOKS | {INDEX})) - expected
        if missing:
            reasons.append("missing reads: " + ", ".join(sorted(missing)))
        if unexpected:
            reasons.append("unexpected reads: " + ", ".join(sorted(unexpected)))
        for read in evidence["reads"]:
            if read["path"] in PLAYBOOKS | {INDEX} and not any(
                    pick["name"] == "planning" and pick["at"] < read["requested_at"]
                    for pick in evidence["skill_events"]):
                reasons.append("reference read outside planning: " + read["path"])
            if read["path"] in PLAYBOOKS and not any(
                    index["path"] == INDEX and index["completed_at"] < read["requested_at"]
                    for index in evidence["reads"]):
                reasons.append("index not read before " + read["path"])
        selection = evidence["selection"]
        if not isinstance(selection, dict):
            reasons.append("incomplete selection boundary")
        else:
            owner = selection.get("delivery_owner")
            normalized_owner = DELIVERY_OWNERS.get(owner) if isinstance(owner, str) else None
            allowed = case["expected_delivery_owner"]
            allowed = allowed if isinstance(allowed, list) else [allowed]
            if normalized_owner is None or normalized_owner not in allowed:
                reasons.append("wrong or multiple delivery owners: " + json.dumps(owner))
            if "expected_history_to_recheck" in case and selection.get("history_to_recheck") != case["expected_history_to_recheck"]:
                reasons.append("supported history marked for re-check")
        # The selection boundary forbids executing work, not just claiming to stop.
        if any(call["name"] in ("Write", "Edit", "Agent", "Task", "TodoWrite") or
               (call["name"] in ("Bash", "command_execution") and
                not selection_read_command(call["input"].get("command", "")))
               for call in evidence["tool_calls"]):
            reasons.append("continued beyond selection boundary")
    return {"got": got, "actual_picks": list(picks), "pass": not reasons, "failures": reasons,
            "read_paths": [read["path"] for read in evidence["reads"]], "evidence": evidence}


def run_query(root, case, model, host, evidence_dir, timeout=150):
    cmd, env = child_command(case["query"], model, host, "expected_reads" in case)
    before = project_snapshot(root)
    t0 = time.monotonic()
    timed_out = False
    with (evidence_dir / "transcript.jsonl").open("w") as output, (evidence_dir / "stderr.txt").open("w") as errors:
        try:
            child = subprocess.Popen(cmd, stdout=output, stderr=errors, cwd=str(root), env=env)
            try:
                child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                child.kill()
                child.wait()
            code = child.returncode
        except OSError as exc:
            errors.write(str(exc))
            code = 127
    transcript = (evidence_dir / "transcript.jsonl").read_text()
    evidence = observe_transcript(transcript, root, host)
    after = project_snapshot(root)
    evidence["fixture_changes"] = sorted(relative for relative in before.keys() | after.keys()
                                         if before.get(relative) != after.get(relative))
    result = score_case(case, evidence, code, timed_out)
    result.update(secs=round(time.monotonic() - t0, 1), exit_code=code,
                  transcript=str(evidence_dir / "transcript.jsonl"), stderr=str(evidence_dir / "stderr.txt"),
                  project=str(root))
    (evidence_dir / "reads.json").write_text(json.dumps(evidence["reads"], indent=2))
    (evidence_dir / "score.json").write_text(json.dumps(result, indent=2))
    return result


USAGE = "usage: harness.py [claude|codex] [model] [reps]"


def usage_error():
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def main():
    args = sys.argv[1:]
    if any(a in ("-h", "--help") for a in args):
        print(USAGE)
        return 0
    if any(a.startswith("-") for a in args):
        usage_error()
    host = args.pop(0) if args and args[0] in ("claude", "codex") else "claude"
    model = args.pop(0) if args else ("claude-opus-5" if host == "claude" else "")
    try:
        reps = int(args.pop(0)) if args else 1
    except ValueError:
        usage_error()
    if args or reps < 1:
        usage_error()
    evals = json.loads((HERE / "evals.json").read_text())["evals"]
    descriptions = {}
    for skill in SKILLS:
        txt = (REPO_SKILLS / skill / "SKILL.md").read_text()
        fm = re.match(r"^---\n(.*?)\n---\n", txt, re.S).group(1)
        descriptions[skill] = fm_field(fm, "description")
    workdir = Path(os.environ.get("MENTOR_EVAL_WORKDIR",
                                  Path(tempfile.gettempdir()) / "mentor-trigger-eval")).resolve()
    run_dir = workdir / f"run-{host}-{uuid.uuid4().hex[:12]}"
    run_dir.mkdir(parents=True)
    results_path = workdir / f"results-{host}.json"
    print(f"staging {len(descriptions)} skills in fresh projects under {run_dir}", flush=True)
    print(f"results -> {results_path}", flush=True)

    def work(job):
        case, rep = job
        directory = run_dir / f"case-{case['id']}-rep-{rep}"
        root = directory / "project"
        directory.mkdir()
        stage_project(root, descriptions, host, case)
        result = run_query(root, case, model, host, directory)
        result.update(id=case["id"], rep=rep, expected=case["expected"], tests=case["tests"], query=case["query"])
        print(f"  [{'PASS' if result['pass'] else 'FAIL'}] #{case['id']} rep{rep} "
              f"expected={case['expected']:<16} got={result['got']:<16} ({result['secs']}s)", flush=True)
        for reason in result["failures"]:
            print(f"    {reason}", flush=True)
        return result

    jobs = [(case, rep) for case in evals for rep in range(reps)]
    with ThreadPoolExecutor(max_workers=6) as executor:
        results = list(executor.map(work, jobs))
    results.sort(key=lambda result: (result["id"], result["rep"]))
    payload = json.dumps(results, indent=2)
    (run_dir / "results.json").write_text(payload)
    results_path.write_text(payload)
    passed = sum(result["pass"] for result in results)
    print(f"\n=== {passed}/{len(results)} correct ({100*passed//len(results)}%) ===")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
