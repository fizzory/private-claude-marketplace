# Retrospective PR body

Use this template, rules and example when opening or updating a retrospective PR/MR;
the reviewer needs the behaviour and the session reason before the supporting evidence.

```markdown
<1 sentence, ≤25 words: N change(s) to how the agent works, from the <YYYY-MM-DD> session where it <task in plain words>.>

## Needs your call

- [ ] Confirm: <the pick, ≤15 words> — <why, ≤15 words>. Otherwise: <alternative, ≤10 words>.

## Changes

| # | Agent now… | Because in the session… | Where |
|---|---|---|---|
| <n> | <behaviour, ≤15 words> | <paraphrase or "quote ≤15 words"; cell ≤25 words> | `<path>` (<new or edit or trigger>) |

## Not in this PR

- <what, ≤20 words> → <link to the sibling PR, or `~/<path>` (kept local), or `/mentor:constitution`, or `AGENTS.md` → <Plugin> core concept, or <tool> config>

<details><summary>Review notes</summary>

- **Checks:** <per change: validator result; trigger prompt → fired; link resolves>
- **Decisions:** <one per decision-log row: choice — why>
- **Considered, not changed:** <one per rejected idea: idea — reason>
- **Ideas for later:** <one per backlog item: what kept failing — the check that would catch it>
- **More not in this PR:** <items beyond the 5 visible>
- **Session coverage:** <"all N parts read", else one sub-bullet per skipped part with its reason>
- **Evidence (local, not uploaded):** <`.mentor/…` paths>

</details>
```

**Rules**
1. **Order:** opening sentence → `## Needs your call` → `## Changes` → `## Not in this PR` → one `<details>` → the host's attribution line, if the host requires one. Nothing else is visible.
2. **Omission:** `## Changes` always appears. Leave out every other section, and every item inside `<details>`, when it has nothing. Never write "None". A repo with no applied change gets no PR.
3. **Caps:**
   - Opening: 1 sentence, ≤25 words.
   - Needs your call: ≤5 items, each within the template's per-part caps (pick ≤15, why ≤15, alternative ≤10 words).
   - Changes: one row per applied change, all of them visible. Each cell stays within the word cap shown, and `Where` holds one path plus one state word.
   - Not in this PR: ≤5 items. The rest go to "More not in this PR".
4. **What goes in Needs your call:** include decision-log rows marked `review?: needed`, any check that failed or was NOT RUN, any unexplained coverage gap, and any change the agent was unsure of, using the full shape `- [ ] Confirm: <pick> — <why>. Otherwise: <alternative>.` for each item. This gives every review call a reason and alternative, so a tick means "accepted".
5. **Visible words:** use plain words only. Never show "lens", "epoch", "synthesizer", "node", "manifest", "overlay", "Accepted", "Rejected", "Backlog", "Leftover", event ids or `.mentor/` paths outside `<details>`. A Changes row describes what the agent does differently, never the diff ("adds a section…" is banned).
6. **Only inside `<details>`:** checks that passed, the full decision log, rejected ideas, backlog ideas, coverage, evidence paths, and the overflow from Not in this PR.
7. **Not in this PR holds:**
   - links to the sibling PRs (one PR per repo; each links the others);
   - edits kept outside any repo, written as `~/…`;
   - proposals the retro never applies, each pointing where the human can make it: constitution → `/mentor:constitution`, core concept → `AGENTS.md` → <Plugin> core concept, another tool's settings → that tool's config.
8. **Title:**
   - ≤72 characters, no trailing period, no ids or paths.
   - Shape: `<prefix><top behaviour change, lowercase imperative>`, plus ` (+N more)` when there are other changes.
   - Prefix follows the repo's last 10 merged titles:
     - If they use the `type(scope):` style: `feat(<scope>): ` when any change is a new skill, else `fix(<scope>): `. Scope is the repo's usual one for the main area touched (default `skills`). Add the repo's version suffix if it uses one.
     - Otherwise: `Retro: `.
9. **Redaction and quotes:**
   - Paraphrase, or quote at most 15 words. Never paste a transcript or code block from the session.
   - Replace credentials, tokens, keys, emails, names, internal hostnames and IPs with `[redacted]`.
   - Drop `@handles` or put them in backticks.
   - Write home paths as `~/…`.
   - Never write `#<digits>` or `!<digits>` in prose; GitHub and GitLab turn them into links. Write "change 2".
   - Escape `|` as `\|` inside table cells.
10. **Rendering:** use only exact standalone lines `<details><summary>Review notes</summary>` and `</details>` for the collapsed block, with a blank line inside each end; write each part as a list item and use no HTML comments or code fences anywhere, so only review notes are hidden.
11. **Trimming for host length limits:** drop `<details>` first. Never cut a visible section, and never fall back to a pointer to the plan file.

**Example** (title: `feat(mentor): ask before pushing to the base branch (+1 more)`)

```markdown
2 changes to how the agent works, from the 2026-11-18 session where it shipped a billing-API fix.

## Needs your call

- [ ] Confirm: flaky-test triage is its own skill — it was needed twice outside shipping. Otherwise: fold it into shipping's test step.

## Changes

| # | Agent now… | Because in the session… | Where |
|---|---|---|---|
| 1 | Asks before pushing to the base branch, even mid-plan | Told "never push straight to develop"; after a context reset it pushed there again | `plugins/mentor/skills/shipping/SKILL.md` (edit) |
| 2 | Re-runs a failing test alone before touching code | Rewrote working code three times for one flaky test | `.claude/skills/flaky-test-triage/` (new) |

## Not in this PR

- Make every push to `develop` pause for approval → amend with `/mentor:constitution`

<details><summary>Review notes</summary>

- **Checks:** both pass the skill validator; change 2 fired on "this test keeps failing"; its `.codex` link resolves.
- **Considered, not changed:** "read CI logs first" — shipping already covers it.
- **Session coverage:** all 4 parts read.

</details>
```

