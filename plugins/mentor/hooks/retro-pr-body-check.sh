#!/usr/bin/env bash
# Check the retrospective PR/MR body before any remote write. No state mutations.
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -f "${1:-}" ]; then
  echo 'body-file: provide one readable Markdown file' >&2
  exit 1
fi
python3 - "$1" <<'PY'
import ipaddress
import re
import sys
from pathlib import Path

try:
    body = Path(sys.argv[1]).read_text(encoding="utf-8")
except (OSError, UnicodeError):
    print("body-file: cannot read UTF-8 Markdown")
    sys.exit(1)

errors = []
if "<!--" in body:
    errors.append("html comment: not allowed in a retro PR body")
opens = list(re.finditer(r"<details\b[^>]*>", body, re.I))
closes = list(re.finditer(r"</details\s*>", body, re.I))
exact_open = re.search(r"^<details><summary>Review notes</summary>$", body, re.M)
exact_close = re.search(r"^</details>$", body, re.M)
visible = body
if re.search(r"`{3,}|~{3,}", body):
    errors.append("fences: code fences are not allowed anywhere in the body")
if len(opens) > 1 or len(closes) > 1:
    errors.append("details: at most one collapsed block is allowed")
if len(opens) != len(closes) or (opens and closes and opens[0].end() > closes[0].start()):
    errors.append("details: opening and closing tags must form one complete block")
valid_details = (
    len(opens) == len(closes) == 1
    and exact_open is not None and exact_close is not None
    and opens[0].start() == exact_open.start()
    and closes[0].span() == exact_close.span()
    and exact_open.end() <= exact_close.start()
)
if (opens or closes) and not valid_details:
    errors.append("details: use exact lines <details><summary>Review notes</summary> and </details>")
if valid_details:
    visible = body[:exact_open.start()] + body[exact_close.end():]
    tail = body[exact_close.end():].strip()
    if tail and not re.fullmatch(r"(?:🤖\s*)?(?:Generated|Created) (?:with|by) [^\n]+", tail, re.I):
        errors.append("details: only the host attribution line may follow the collapsed block")

allowed = ["Needs your call", "Changes", "Not in this PR"]
headings = list(re.finditer(r"^[ \t]*(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$", visible, re.M))
names = [match.group(2) for match in headings]
if "Changes" not in names:
    errors.append("sections: ## Changes is required")
if any(match.group(1) != "##" or match.group(2) not in allowed for match in headings):
    errors.append("sections: only Needs your call, Changes, Not in this PR are allowed")
if len(names) != len(set(names)) or [allowed.index(n) for n in names if n in allowed] != sorted(allowed.index(n) for n in names if n in allowed):
    errors.append("sections: visible sections must appear once in the prescribed order")
if opens and any(match.start() > opens[0].start() for match in headings):
    errors.append("details: the collapsed block must follow all visible sections")

opening = visible[:headings[0].start()].strip() if headings else visible.strip()
sentence_ends = re.findall(r"[.!?][\"'”’)]*(?=\s|$)", opening)
if (not opening or "\n\n" in opening or len(sentence_ends) != 1
        or not re.search(r"[.!?][\"'”’)]*$", opening)):
    errors.append("opening: use one sentence before the first ## heading")
if len(opening.split()) > 25:
    errors.append("opening: at most 25 words")

sections = {}
for index, heading in enumerate(headings):
    end = headings[index + 1].start() if index + 1 < len(headings) else len(visible)
    sections[heading.group(2)] = visible[heading.end():end]


def list_items(section, label):
    items = []
    for line in section.splitlines():
        if not line.strip():
            continue
        if re.match(r"^\s*(?:[-+*]|\d+[.)])\s+", line):
            items.append(line.strip())
        elif items:
            items[-1] += " " + line.strip()
        else:
            errors.append(f"{label}: use list items")
    if len(items) > 5:
        errors.append(f"{label}: at most 5 items")
    return items


for index, item in enumerate(list_items(sections.get("Needs your call", ""), "needs your call"), 1):
    parts = re.fullmatch(r"- \[ \] Confirm: (.+?)\s+—\s+(.+?)\.\s+Otherwise:\s+(.+?)\.", item)
    if not parts or any(not part.strip() for part in parts.groups()):
        errors.append(f"needs your call: item {index} must use - [ ] Confirm: <pick> — <why>. Otherwise: <alternative>.")
        continue
    for label, part, cap in zip(("pick", "why", "alternative"), parts.groups(), (15, 15, 10)):
        if len(part.split()) > cap:
            errors.append(f"needs your call: item {index} {label} exceeds {cap} words")
list_items(sections.get("Not in this PR", ""), "not in this PR")


def table_cells(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line)]


if "Changes" in sections:
    lines = sections["Changes"].strip().splitlines()
    header = ["#", "Agent now…", "Because in the session…", "Where"]
    if (len(lines) < 2 or table_cells(lines[0]) != header
            or len(table_cells(lines[1])) != 4
            or not all(re.fullmatch(r":?-{3,}:?", cell) for cell in table_cells(lines[1]))):
        errors.append("changes: use the template table header and separator")
    else:
        rows = []
        for line in lines[2:]:
            if not line.strip() or "|" not in line:
                break
            rows.append(table_cells(line))
        if not rows:
            errors.append("changes: table needs at least one data row")
        for index, cells in enumerate(rows, 1):
            if len(cells) != 4:
                errors.append(f"changes: row {index} must have four cells")
                continue
            if len(cells[1].split()) > 15:
                errors.append(f"changes: row {index} Agent now exceeds 15 words")
            if len(cells[2].split()) > 25:
                errors.append(f"changes: row {index} Because in the session exceeds 25 words")
            if not re.fullmatch(r"`[^`\s|]+`\s+\((?:new|edit|trigger)\)", cells[3]):
                errors.append(f"changes: row {index} Where must hold one path and state (new, edit or trigger)")

banned = r"\b(?:lens|epoch|synthesizer|node|manifest|overlay|Accepted|Rejected|Backlog|Leftover)\b"
if re.search(banned, visible, re.I):
    errors.append("visible words: remove internal workflow terms")
if ".mentor/" in visible:
    errors.append("visible paths: .mentor/ belongs only inside details")
# Inline code and link targets are not prose; issue references in plain text are.
prose = re.sub(r"`+[^`\n]*`+", "", body)
prose = re.sub(r"\]\([^\n)]*\)", "]", prose)
if re.search(r"[#!]\d+\b", prose):
    errors.append("references: write change numbers in words, without # or !")
if re.search(r"^\s*(?:[-*]\s+)?(?:\*\*)?None(?:\*\*)?\.?\s*$", body, re.M | re.I):
    errors.append("placeholders: omit empty sections instead of writing None")

# Redaction applies to the entire uploaded body, including collapsed review notes.
if re.search(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b", body):
    errors.append("redaction: email address found")
if re.search(r"(?<![A-Za-z0-9])(?:gh[pousr]_|glpat-|sk-|xox[abp]-|AKIA[0-9A-Z]{16}|-----BEGIN)", body):
    errors.append("redaction: token or key shape found")
if re.search(r"/(?:Users|home)/[^/\s`<>]+", body):
    errors.append("redaction: replace named home paths with ~/")
# Consume whole decimal octets; punctuation may follow, but another dotted octet may not.
ipv4 = re.findall(r"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?!\w|\.+[0-9])", body)
has_ip = any(all(int(octet) <= 255 for octet in candidate.split(".")) for candidate in ipv4)
ipv6 = re.findall(r"(?<![\w:])(?:[\da-fA-F]{0,4}:){2,}[\w:.]*(?![\w:])", body)
for candidate in ipv6:
    # Validate before trimming: a trailing colon may complete a compressed address.
    # Try shorter colon-group prefixes for word suffixes; validation keeps MACs out.
    while "::" in candidate or candidate.count(":") >= 3:
        try:
            ipaddress.IPv6Address(candidate)
        except ValueError:
            if candidate[-1] in ":.,;)":
                candidate = candidate[:-1]
            else:
                candidate = candidate[:candidate.rfind(":") + 1]
        else:
            has_ip = True
            break
    if has_ip:
        break
if has_ip:
    errors.append("redaction: IP address found")

for error in dict.fromkeys(errors):
    print(error)
sys.exit(bool(errors))
PY
