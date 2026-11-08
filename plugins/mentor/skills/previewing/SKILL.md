---
name: previewing
description: |
  One scenario-based HTML review page for any subject: a mentor plan, a design doc, a subsystem or the code
  as it is today (no plan needed), or the thing under discussion. It mocks up every surface the change
  reaches (web, mobile, CLI, chat, API, email, push, or a new one), with each edge case as its own card,
  plus C4 and sequence diagrams. Each scenario card has a comment box with Copy, to comment per scenario
  and paste back in chat. Writes a local .mentor/reviews/[subject-slug]/review.html and opens it
  (published only on a yes). Use for /mentor:preview, "preview this plan",
  "show me X as an HTML page", "render X as a local page", "make a diagram page for X", "a diagram of the
  current X flow", "from the end user's or QA's point of view", "mock up the screens and edge cases", "I
  want to see this instead of reading markdown", "refresh the preview". Distinct from grilling (a
  question-by-question stress test of a plan, no page).
---

# Preview — one scenario-based review page

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Build **one HTML page per subject** that lets a person review a change by scenario instead of reading prose:
what each actor receives on every surface, before and after, with each edge case as its own card; the
architecture and flows that move; the data that changes; and what is still undecided. The subject stays the
source of truth. The page is regenerated from it, never edited into it.

**Every preview ask re-enters this contract**: the first one, a "refresh the preview", a mid-revision
regeneration. Run §0–§5 (or §7 for a revision) each time. Why each rule is here, and the incidents behind
them, is in `references/rationale.md`; read it before overriding one.

## When to use

- `/mentor:preview`, or a request to see a plan, a subsystem or a doc rendered as a page with mockups or
  diagrams.
- `planning` Step 5 delegates here when the user opts into a review page.
- A mentor plan that already has a page changed (§7).

## When NOT to use

- The user wants to **stress-test a written plan**: that is `grilling`, a conversation that sharpens the
  `.md`, not a page.
- Nobody asked for a page. A review page is opt-in, never a default deliverable.
- The plan itself needs writing or revising: that is `planning`. This skill draws what exists.

## Workspace

```text
.mentor/reviews/<subject-slug>/      # gate-exempt, like plans/
├── review.html     # the assembled page
├── _ids.md         # surfaces, sections, flows, cards, hops, variants, base: — append-only ids
├── _plan.md        # copy of the plan the ids and fragments were built from (plan subjects; §1, §7)
├── _brief.md       # distilled source pack: research findings, or a subject with no file
├── _trace.md       # the trace worker's evidence, file:symbol only; the main thread never reads it (§1)
├── _built.md       # one line per fragment that passed its check, so a stopped build resumes (§1, §4)
├── shots/          # real captured pictures, only where pixels matter
└── _parts/         # fragments, kept so a revision regenerates only what changed
```

The fragment names, writers and templates are in `references/page-contract.md`. The page's fixed CSS and its
one script ship in this skill's `assets/` and are inlined at assembly, so no run reads or retypes them; do not
open them, since the theme and switching facts a run needs are in page-contract §3–§4.

## §0 — State dir, subject and slug

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
# Neither set (some headless shells): this skill's own base directory, two levels up.
[ -f "$plugin_root/hooks/plan-state.sh" ] || plugin_root="$(cd "<this skill's base directory>/../.." 2>/dev/null && pwd)"
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  state_dir="$(bash "$plugin_root/hooks/plan-state.sh" dir)"
else
  state_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.mentor"
fi
assets="<this skill's base directory>/assets"; [ -f "$assets/page.css" ] || echo "assets missing: $assets"
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -3   # candidate plan subjects, newest first
if [ -n "$plugin_root" ] && [ -f "$plugin_root/hooks/plan-state.sh" ]; then
  sibling_wts="$(bash "$plugin_root/hooks/plan-state.sh" gate --verbose | sed -n 's/^elsewhere=\([^ ]*\).*/\1/p')"
  [ -n "$sibling_wts" ] && bash "$plugin_root/hooks/plan-state.sh" list --owners
fi
```

**Resolve the subject**, in priority order:

1. the **argument**: free text, a file or dir path, or a plan-slug substring;
2. the **newest plan** above, when the conversation is about it. When `$sibling_wts` is non-empty, first drop
   every candidate whose OWNER matches one of those worktrees, because a sibling's live marker means that plan
   is mid-write. If that leaves nothing or an ambiguous pick, ask for the subject. Name the plan you picked;
3. the feature or system under discussion in the **current conversation**.

Derive a kebab-case `<subject-slug>` that stays the same across runs. **When the subject is a mentor plan, the
slug is the plan's dir name**, so the plan's page is found without guessing. Then:

```bash
review_dir="$state_dir/reviews/<subject-slug>"
mkdir -p "$review_dir/_parts/20-scenarios"
case "$state_dir" in */.mentor)   # in a repo: keep review pages out of commits, as the hooks do
  [ -f "$plugin_root/hooks/lib/state.sh" ] && . "$plugin_root/hooks/lib/state.sh" && mentor_ensure_gitignore "$state_dir" ;;
esac
```

The helper is called with `bash`, so test it with `-f`, never `-x`: the file is not always executable, and
an `-x` test silently skips every helper call. Replace `<this skill's base directory>` with the folder this
`SKILL.md` was loaded from (the host names it when the skill loads): without a helper path the state dir,
the sibling-worktree check and the gitignore helper silently fall back.

`.mentor/` is exempt from the plan edit gate, so previewing is legal while a plan gate is armed; workers write
only under `$review_dir`, never repo source.

## §1 — Source pack, section plan and inventory

Everything workers need is resolved here, because workers must not fan out further and cannot ask the user.

| Subject kind | Source pack |
|---|---|
| A document (a mentor plan, spec, ADR, README) | its path; workers read it directly |
| Repo code or a subsystem | the real file paths. When the area is broad, one read-only research worker (or the same survey serially) writes FINDINGS with `file:line` EVIDENCE to `_brief.md` |
| No file (the conversation, facts gathered live from a CLI or API) | the main thread distills it into `_brief.md` |

Open every brief with the plan-level Goal: line verbatim; for a missing line or plan,
follow planning's [Role resolution](../planning/SKILL.md#decision-maker) fallback rule.
This keeps research, trace, probe, fragment and revision work tied to the requested outcome.

Every brief carries the rule **invent nothing**: every claim, string, colour and step traces to the source pack
or to the plan. **Research is read-only**, in the main thread and in every worker: files and git, never a
command against a running service, container or database, not even a rolled-back one (contract §1). A
screenshot of a screen the running app already shows, for a Before picture (contract §8), is allowed. The user's
stack is theirs; what the code cannot settle becomes a question.

**Catch-up first.** When `review.html` exists (plan subjects), compare its stamp with the plan (§7) and treat a
mismatch as a revision. When it does not but `_ids.md` does, an earlier build stopped before assembly: if the
subject is not a plan or `_plan.md` still matches the plan's stamp, keep the pinned ids and the renderer in
`_ids.md`, and go to §3. There, list every fragment `_ids.md` calls for (each card's `-0-shell`, `-h<n>`,
`-s<k>` and `-z-close`, each included section file and the main thread's own parts), keep those `_built.md`
lists with a matching hash, and write all the others in the next wave (§3's six-worker cap and second wave
still apply); each new cells worker writes its own style file, numbered after the highest `w<n>` already in
`_parts/20-scenarios/`, so no kept style file is overwritten. If the plan changed, first run §7 steps 1–2 against `_plan.md` (diff,
then append and retire in `_ids.md`), copy the plan to `_plan.md` once the ids are pinned again, delete the
retired parts, and count every fragment §7 step 3 names (always `00-head.html`, for the new stamp) as missing
even when `_built.md` lists it; §7 step 4 applies to their briefs, and assembly happens once, in §4. Comparing `_built.md` with the disk alone
misses a fragment that was never written, and regenerating finished ones repeats the costliest part of a build.

**Section plan.** Include a section only when the subject changes it, and name every left-out section in the
footer, so silence never reads as "forgotten". For a non-plan subject, read "changes" as "explains what the user
asked to see", and the footer says "Not shown for this subject" instead of "Not affected by this plan":

| Section | Included when the subject… | Limited to |
|---|---|---|
| Questions for you | has unresolved questions, confirm-me defaults, or gaps the mockups raise | those items |
| Scenarios | has a scenario with a changed hop (a plan), or any in-scope scenario (a non-plan subject) | the scenarios with at least one changed hop; a non-plan subject draws each as `view=current` |
| Architecture | adds, removes or rewires a service, container, datastore, queue or external system | the C4 levels whose boxes or edges move |
| Sequences | changes an interaction between two or more participants | one diagram per changed flow, drawn under the scenario whose trigger starts it; only flows no scenario starts get this section. A flow that is one participant's decision path with many exits is drawn as a flowchart |
| Data and contracts | changes a schema, contract, permission, error or config key | entities, rules, migrations, contract delta, API and permissions, errors, config: changed rows only; unchanged entities named, not drawn |
| Decisions | the subject is a plan | the decision log grouped by use case, or what the plan states when it has no log of its own |
| Footer | always | sections and scenarios left out, and the provenance totals |

**Inventory.** Follow `references/surface-mockup-contract.md` §1–§3 to walk each scenario from trigger to
outcome, find every hop (including emitters found only in code, followed link by link through the values they
write, and every writer of each value a guard switches on, grepped across all apps), resolve each hop's
primitive from `references/surface-catalog.md` §2, and split edge cases into child cards (`S1a`, `S1b`). Each
`via=` value the trigger reaches is its own card, because a different writer means a different path. Only
cases under one value that differ in their message alone share a card, with a short Differences list of the
lines that differ. Record everything in `_ids.md` (contract §4), including `base:`, for each section the plan
headings it draws from, and for each flow its owner: the scenario whose trigger starts it, so its diagram sits
under that card where the reviewer is already reading. One author owns the ids, because parallel workers must
share one set of ids and one owner per hop: the main thread, or the trace worker below, whose draft the main
thread pins before any other worker starts. Once they are pinned, copy the plan to `_plan.md` (plan subjects).

**Tracing goes to one worker when the subject reaches several surfaces.** When the scenarios reach three or more
surfaces, or code in two or more apps, start **one** read-only trace worker before
any other worker. Its brief carries the source pack, the scenario list, the section plan, the existing `_ids.md`
if any, and contract §1–§4, §8's Format bullets and catalog §2 by path; it may write only `_trace.md` and `_ids.md`. It writes its
evidence to `_trace.md` (each scenario's hops with `guard=`, every `via=` value with its writer, `found=`, a
family and primitive per surface, the five-question facts for a new surface, all as `file:symbol`) and drafts
`_ids.md` from it. It returns the two paths, `Self-check: scenarios=N cards=N hops=N via-values=N writers=N
untraced=N new-surfaces=N flows=N pixels=N`, and one line per item for the main thread: `ASK:` a new surface whose
perceiver or producer is open, `QUESTION:` a plan link the code contradicts, `SPLIT:` a card split at a cap. The
main thread **never reads `_trace.md`**, nor contract §1–§3 or the catalog, which the worker applied: it reads
contract §4 and `_ids.md` (its own fragments need that file anyway), asks each `ASK:`, edits `_ids.md` for the
answers, and the ids are pinned. It also records the report in `_built.md` as a `_trace.md` line with the
`QUESTION:` lines under it, so they survive a resume (§4). A six-surface plan traced in the main thread, or read
back from a trace file and retyped as ids, filled its context before any cells worker ran. Serial fallback: trace
in the main thread and write `_ids.md` directly, with no `_trace.md`.

- **The code's chain wins.** When the plan's link contradicts an emitter's guard, draw the code's chain and
  turn the plan's link into a question in Questions for you.
- **A new surface** no family matches is settled with the five questions; ask at most one question per new
  surface, before any worker, and record a SURFACE BRIEF that later runs reuse without asking.
- **Ids are append-only.** On a re-run, read `_ids.md` first; never renumber or reuse an id or an edge-card
  letter, because comment drafts are keyed by them.
- **Before and After** follow contract §7. Before is the last commit without the plan's change (for a plan
  already merged, the parent of its first implementing commit), recorded once per repo as `base:`; After is
  the plan. When the code has moved on since an implemented plan, draw the plan and name the drift in Rules
  and edges, raising it as a question only when it changes what a reviewer would decide.
- **Plan citations.** A NEW mark cites the plan section (`§A4`), or its heading path when the plan has no
  numbered sections.
- **Caps.** A card holds at most 6 hops, 12 variants and 40 frames, and a parent at most 8 edge cards; split
  before pinning ids.

## §2 — Diagrams

Only when the section plan includes Architecture or an ER diagram in Data and contracts, or `_ids.md` lists any
flow under `## Flows` (owned or not).

**diagram-design is the renderer.** One read-only probe worker loads the `diagram-design` skill, draws nothing,
and returns `LOADED` or `NOT_AVAILABLE`, plus `PROFILE_GATE: skip <profile>` or `PROFILE_GATE: would-ask` with
the skill's question verbatim. This keeps that long skill out of the main thread. A `skip` whose profile
plainly belongs to another project (its name or brand) counts as `would-ask`. On `would-ask`, ask that
question once, here, before any section worker starts, because workers cannot ask and parallel workers would
answer it differently. Every diagram brief then carries the profile name and "do not re-ask". Without
delegation, load the skill in the main thread.

**When it is missing**, read the saved answer; with none, never stop to ask — use the fallback:

```bash
cfg="$state_dir/config.json"
renderer="$(jq -r '.diagram_renderer // empty' "$cfg" 2>/dev/null)"
save_renderer() {   # $1 = diagram-design | fallback; keeps every other key and the file's mode
  [ -f "$cfg" ] || printf '{}\n' > "$cfg"
  tmp="$(mktemp)" && jq --arg v "$1" '.diagram_renderer = $v' "$cfg" > "$tmp" && cat "$tmp" > "$cfg"
  rm -f "$tmp"
}
```

- `fallback` or unset: ask nothing; use the fallback below. When unset, `save_renderer fallback` and, for a
  plan subject, append a decision-log row (`decided`, `review?: optional`) saying the page used hand-drawn
  diagrams because diagram-design was not installed — and naming its source,
  `https://github.com/cathrynlavery/diagram-design` (on Claude Code: `/plugin marketplace add
  cathrynlavery/diagram-design`, then `/plugin install diagram-design@diagram-design`), so the user can
  install it later. Immediately after this plan write, run
  `bash "$plugin_root/hooks/plan-state.sh" record-write <plan-slug>` when the helper resolved
  in §0 is available; this keeps mentor’s own writes from appearing as drift.
  Installing a third-party plugin is the user's call, never this skill's.
- `diagram-design` but the skill cannot load this session: this run uses the fallback and the header says so.

**Fallback.** Hand-drawn inline SVG that follows diagram-design's rules: its tokens, per-diagram id prefixes,
no overlapping boxes, text inside its box, everything inside the viewBox. A diagram that fails that check after
one fix is redrawn in Mermaid (pinned in `references/page-contract.md` §3) and captioned "drawn with Mermaid".
diagram-design and the fallback never share a page.

**Composition.** Many diagrams share one page, so each is inlined as `<svg class="dd">` under the per-diagram
id prefixes (`ctx-`, `cont-`, `comp-`, `seq-<k>-`, `er-`) and scoped-CSS rules in `references/page-contract.md`
"2. Fragment rules", with the profile's CSS in the diagram fragment's own `<style>`. `00-head.html` carries
diagram-design's Google Fonts link only when that renderer is used.

## §3 — Fragments

Use workers when the host supports delegation and the user has not restricted it; otherwise use the serial
fallback below and say so.

**Main thread** writes, from the `references/page-contract.md` templates: `00-head.html` (with the contents
sidebar, which lists every included section and card, and the include line for the page CSS),
`10-answers.html`, `20-scenarios/000-open.html`, every card's `-0-shell` and `-z-close`, `zzz-close.html`,
`90-decisions.html` and `99-foot.html`. These are short and need the pinned `_ids.md`. Write them before
launching the workers, so nothing is left for the main thread to do while they run.

**Cells workers** write one file per hop plus one style file, packed per
`references/surface-mockup-contract.md` §9: at most 30 frames each, at most 6 per wave. Each brief carries the
token `mentor:frontend-mockup` and the inputs that section lists.

**Section workers**, one per section the §1 section plan includes other than Sequences, plus one sequences
worker whenever `_ids.md` lists a flow; each brief carries that section's "Limited to" cell verbatim and the section's title and lede rule
(`references/page-contract.md` §2). Beyond that cell, Architecture labels its levels L1 context, L2 container
and L3 component, and Data and contracts draws the changed entities as an ER diagram. The sequences worker
draws each flow from the code's chain recorded in `_ids.md` and writes it where its owner says: an owned flow
as `20-scenarios/sNN-s<k>.html` under its card, with one `20-scenarios/001-style-flows.html` for their CSS, and
only `owner=none` flows in `40-sequences.html`.

Each section brief carries the source pack, the plan sections from `_ids.md`, the renderer and profile with "do
not re-ask", the id prefixes, the output path, and the fragment rules (`references/page-contract.md` §2).

**Every brief names the only paths its worker may write, and ends with the delivery rule**: "Write only
<those paths>, under `$review_dir`. Do not publish. Return only the file paths, a `Self-check:` line and any
GAPS list, never the HTML." That holds for §1's trace, research and probe workers too: a trace worker once
left a copy of its file in the plan's folder. Cells workers report the `Self-check:` line in contract §10;
diagram workers report `diagrams=N dd=N ids-prefixed=yes tags-balanced=yes`, where `dd` counts diagrams
inlined as `<svg class="dd">` and must equal `diagrams`. Named fields make an absence visible, where prose
would hide it.

Launch every independent worker in the first wave, up to six cells workers; leftover cells slices go in a
second wave.
**Serial fallback:** without delegation, the main thread writes the same files in the same order and runs
the same checks, one fragment at a time.

## §4 — Assemble and check

1. **Recount** each cells worker's marks with `grep -o … | wc -l` (contract §10) and compare with its
   `Self-check:`, and each diagram worker's `dd` with `grep -oE '<svg[^>]* class="([^"]* )?dd[ "]'` over its
   fragments (for the sequences worker, its flow files and `40-sequences.html` together). A mismatch, a missing field, `dd` below `diagrams`, `captured` plus `no-capture` below `pixels`,
   or any `<script` in a hop or flow file reruns that worker once, naming the defect.
   **Record each fragment that
   passes** (a worker's after its recount, the main thread's after it is written) with one line in
   `_built.md`: `<path under _parts> sha=<first 12 hex of its sha256> <the Self-check, or main>`, with the
   worker's GAPS items indented under it; a regenerated fragment adds a new line, and the last line for a path
   counts. A build that stops before assembly resumes from these lines (§1) instead of regenerating every
   fragment.
2. **Route gaps.** Every `unspecified` item and trace `QUESTION:`, from this run's reports and from
   `_built.md`, becomes a question in Questions for you (rewrite `10-answers.html`, and `00-head.html` and
   `99-foot.html`'s left-out list when the count of open questions changed or the section is new to the page;
   record each of its items as a `QUESTION:` line under its `_built.md` line, so a resume that rewrites it
   keeps every question);
   `untraced` items stay in Rules and edges. Fill the footer totals in `99-foot.html`.
3. **Assemble** with the null-delimited command in `references/page-contract.md` §1, after deleting retired
   parts.
4. **Check** with `references/page-contract.md` §8: doctype, closing `</html>`, non-zero size, unique ids, no
   script in hop or flow files, every contents and path link has its target, both assets inlined, and the 1 MB
   warning (the HTML only). These cost no context and catch a page truncated
   by a worker that died mid-write.
   Over 1 MB is a warning for the user, with the heaviest files (`wc -c`): screens stay whole, drawn from
   the app's real components, because a developer builds from them (contract §8). Nothing is cut to fit.
5. **Look at it once** when the host has a browser tool (its own pane, or a headless browser; never the
   user's browser, which only `open_page` in §5 may open): serve the folder
   in the background (`python3 -m http.server --bind 127.0.0.1 --directory "$review_dir" 8765`, stopped
   afterwards) if the tool cannot open a local file, then view each section in both themes (dark is the
   default; the theme button gives light) and at phone width, 375 px (the host tool's mobile size; headless
   Chrome stops at 500 px, so there view the page inside a 375 px wide `<iframe>`). Scroll a long card and
   confirm the contents sidebar and the card's title bar stay in view; at phone width, confirm
   `document.documentElement.scrollWidth` equals `innerWidth`, because one unwrapped path widens the whole
   page. The text checks above cannot see white-on-white text or an unstyled frame.

Do not re-read fragment bodies to re-verify what a Self-check already reports; that drags HTML into the main
thread for nothing.

## §5 — Deliver

Open the page only by defining and calling `open_page` as written below, never with `open`, `open -a`, a
browser binary or `xdg-open` on the page directly: its `MENTOR_PLAN_OPEN=off` switch is how headless runs and
tests stay out of the user's own browser. It honours the same switches as mentor's plan opener:

```bash
open_page() {
  case "${MENTOR_PLAN_OPEN:-}" in off|0|false|no) echo "not opened (MENTOR_PLAN_OPEN=off): $1"; return 0 ;; esac
  case "${MENTOR_PLAN_OPENER:-auto}" in
    vscode) for b in "${MENTOR_PLAN_VSCODE_BIN:-}" code code-insiders cursor windsurf codium; do
              [ -n "$b" ] && command -v "$b" >/dev/null 2>&1 && { "$b" -r "$1"; return 0; }; done ;;
    system) ;;
    *) if command -v open >/dev/null 2>&1 && open -a "Google Chrome" "$1" 2>/dev/null; then return 0; fi
       for b in google-chrome google-chrome-stable chromium chromium-browser; do
         command -v "$b" >/dev/null 2>&1 && { "$b" "$1" >/dev/null 2>&1 & return 0; }; done ;;
  esac
  { command -v open >/dev/null 2>&1 && open "$1"; } || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$1"; } \
    || { command -v wslview >/dev/null 2>&1 && wslview "$1"; } || echo "open it: $1"
}
open_page "$review_dir/review.html"
```

Report the path, the sections included, the "Not affected" list, the card count, the renderer, and any size
warning, and whether it opened, taken from `open_page`'s output (it prints `not opened
(MENTOR_PLAN_OPEN=off)` when switched off). On a revision, say the page was updated rather than opening it
again.

**Then offer publishing once per build**, when the host has a tool that publishes a private page (an Artifact on
Claude): publish only on yes, passing `shots/` as supporting files. Without such a tool, the page stays local and
you say so. A run that found the page current and rebuilt nothing makes no offer: the user had it when the page
was built, and repeating it on every look is the same nag as re-asking questions (§6).

## §6 — The two answer channels

**Open questions, in chat, one per turn.** After a run that built or revised the page, take the items in
Questions for you in dependency order and ask one at a time, putting the cleanest practical option first, marked Recommended. Ask through the
host's question tool when it has one, otherwise in plain text. Write each question so it stands alone: plain
words, no plan section numbers or ids the user would have to look up. When the subject is a mentor plan,
append each verdict to the plan's `## Decision log` as a new row (planning Step 4's columns:
`# · use case · decision · why · evidence · result · review?`, with `result: kept`).
Immediately after this plan write, run `bash "$plugin_root/hooks/plan-state.sh" record-write <plan-slug>`
when the helper resolved in §0 is available; this keeps mentor’s own writes from appearing as drift.
Then regenerate the affected fragments (§7). The questions live here because the page is read-only and chat is the channel back.
`grilling` is a related skill for interrogating a design, but this loop never depends on it. A legacy plan with
no `## Decision log` gets one, with those seven columns, holding its first recorded answer. Only a genuine
product or preference call becomes one of these questions; anything evidence or a decision-maker agent can
settle (planning Step 3) is settled and logged instead.

**A run that changed nothing asks nothing.** When the catch-up check finds the page current and nothing is
rebuilt, do not restart the loop: say how many questions are still open and that the user can say "go through
them" when ready. Re-asking the same question every time someone opens the page turns a review into a nag.

**Scenario comments.** Each card's comment box and Copy produce a block like:

```text
[mentor:preview] subject=fastship-release-gate scenario=S4a "QA bypass: release not ready" view=after
<comment>
```

When the user pastes one, treat it as review input on that card: answer it, revise the plan (then §7), or fix the
page. The block names the card, and the variant and view the reviewer had switched to, so start there; every
hop is on screen at once, so the comment itself says which hop it means.

## §7 — Re-preview on revision, and keeping the plan and page in sync

A page that lags its plan has reviewers commenting on behaviour that is no longer planned, so a plan and its
page change **together**.

**When this runs** (plan subjects that have a `review.html`):

- any turn that changed `plan.md` content, whoever changed it: this skill's §6 loop, `planning`,
  or a plain edit in chat (on Claude, mentor's plan-open hook reminds you after a Write or Edit of the plan);
- the catch-up check at the start of every `previewing` run.

Step progress marks (`✅` ticks) and `.state.json` are not plan changes. Run it **once per turn,
after the last plan edit**, not after each edit. When a legacy plan is `superseded`, regenerate only
`00-head.html`, whose header then names the plan as superseded and lists the child plans, and reassemble.

**The stamp:**

```bash
plan="$state_dir/plans/<slug>/plan.md"
plan_sha="$(sed 's/ *✅//g' "$plan" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
page_sha="$(sed -n 's/.*name="mentor-plan-sha256" content="\([0-9a-f]*\)".*/\1/p' "$review_dir/review.html" | head -1)"
[ "$plan_sha" = "$page_sha" ] && echo "page current" || echo "page stale"
```

The stamp hashes `plan.md` with its `✅` marks removed, so ticking a step never makes a page stale. The page
carries `plan_sha` in `<meta name="mentor-plan-sha256">` and its header reads "Built from plan.md @
<first 8 hex>, <time>".

**Regenerate only what changed:**

1. `diff <(sed 's/ *✅//g' "$review_dir/_plan.md") <(sed 's/ *✅//g' "$plan")` shows the changed plan text,
   ignoring progress marks as the stamp does; with no `_plan.md`, treat every section as changed.
2. Map changed plan sections to fragments through `_ids.md`: each card's `plan:` list, the `## Sections`
   lines and each flow's line under `## Flows`. Re-run the §1 inventory for affected scenarios: append new
   cards, hops, variants and flows, move vanished ones to `retired:`, and keep every existing id.
3. Regenerate those shells, hop files, flow files and section fragments (§3), plus `10-answers.html` and
   `90-decisions.html` when the questions or the decision log changed, and `00-head.html` for the new stamp
   and contents. A changed flow also regenerates the shells of the cards its `also=` lists (their link line),
   and a flow whose owner changed has its old `sNN-s<k>.html` deleted.
4. When a revision replaces a term, each regeneration brief names the old and new term and asks the worker to
   add `residual-<old>=N` with a reason per remaining hit and `new-term-present=yes` to its Self-check; compare
   with `grep -o '<old>' <file> | wc -l` and rerun once on a mismatch.
5. Delete retired parts, assemble, check (§4), and refresh `_plan.md`.

Hand edits to `review.html` never flow back into the plan; the next regeneration overwrites them.

## Done when

- `review.html` exists under `.mentor/reviews/<subject-slug>/`, every §4 check prints `OK`, and every worker's
  Self-check was consumed and recounted, with one rerun attempted for any defect. A page over 1 MB is
  reported with the size warning, not cut.
- Its sections match the section plan, no section is empty, and the footer names every section left out.
- It was opened (or `MENTOR_PLAN_OPEN=off` was reported), and, when the run built or revised it, publishing was
  offered if the host can publish.
- Every open question was asked one per turn, or there were none, or the run changed nothing (§6); for a
  mentor plan, each answer is a decision row in the plan.
- For a plan subject, the page's `mentor-plan-sha256` equals the current plan's hash.

### Do NOT

- Do **not** write outside `.mentor/reviews/<subject-slug>/` except the three writes this skill names:
  `.mentor/.gitignore` through `mentor_ensure_gitignore` (§0), the `diagram_renderer` key in
  `.mentor/config.json` (§2), and a decision-log row (or a first `## Decision log` table) in a mentor plan (§2, §6).
  Never the repo source.
- Do **not** edit the subject beyond that decision row.
- Do **not** read `_trace.md` in the main thread (§1), or let mockup HTML into it while workers run; workers
  return paths and Self-check lines only. The serial fallback (§3) writes fragments in the main thread one at a
  time and does not re-read them.
- Do **not** draw a plan's link as today's behaviour when the code's chain says otherwise.
- Do **not** run a command against a running service, container or database during research (§1).
- Do **not** put a `<script>` or switching CSS in a hop or flow file, or embed a picture as base64.
- Do **not** open the page with anything but `open_page` (§5).
- Do **not** renumber or reuse a card, edge-card letter, hop or variant id.
- Do **not** publish without the user's yes, or ask more than one question per turn.
