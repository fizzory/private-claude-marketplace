---
name: frontend-self-ex-review
description: |
  Reviews whether an app screen explains itself (action-first, minimal copy).
  Use when the user wants a UI people get without explanation, whether they
  say "self-explanatory", "textless", "minimal copy", "action-first", or put
  it plainly: "too much text", "too wordy", "users don't know what to click",
  "people keep missing the button", "make it obvious what to do next", "it
  should explain itself", "no help text needed". Use it first even when they
  ask for the change ("make it textless", "strip the fluff"): it returns
  findings; the session applies the small fixes and plans the rest. Covers
  screens, flows, screenshots and proposed designs. Modes: audit (findings
  tied to components, each with a proposed change) and verify (states,
  viewports, keyboard; observed vs untested). Keeps functional labels,
  constraints, accessibility and user-written content. Not for a general UX/UI
  or visual review without that goal, article, docs or marketing-copy editing,
  judging a plan, code/PR review, or an aesthetic restyle.
---

# Frontend Self-Explanatory Review

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Review product interfaces, and verify changes to them, so that what to do next is obvious
**without explanatory copy**. The governing principle:

> Remove the need to explain the interface, not the labels and cues that make it understandable.

"Textless" means **minimal explanatory copy**, never zero text. A shorter screen is not
evidence of a better one — a valid fix can *add* a three-word label while removing a
paragraph. When goals conflict, resolve them in this order:

1. Safety, accessibility, data integrity
2. Task clarity and discoverability
3. Less explanatory copy
4. Visual minimalism

Design for a working product, not a landing page: every screen is organized around the
user's task, the actions available, and the system's response.

**The review is the whole output.** This skill writes no files and no plans; it hands back
findings, each with its proposed change and fix size. Once the review is delivered the skill
is done — applying the small fixes or planning the bigger ones is ordinary follow-on work for
the session, outside this skill. Never tell the user you are not allowed to make changes they
asked for.

## When NOT to use

- **No self-explanatory goal** — a general UX/UI review, visual polish, or a design-system
  consistency check that is not about the screen explaining itself.
- **Prose is the task** — editing an article, docs, release notes, or marketing copy. Text
  that *is* the user's content (descriptions, quotations, records) is never this skill's to
  cut, even inside an app.
- **Judging a written plan's quality** — that is a plan-quality pass (`/mentor:grill`), not a UI review. Reviewing whether the *UI a plan
  proposes* will explain itself is fine: treat the plan as a description input.
- **Code or PR review**, or a **purely aesthetic restyle** ("make it look stunning") — a design
  skill's job; this skill keeps the existing design system.

## Step 0 — Mode and inputs

**Pick the mode from the ask** (state it in the first line of your reply):

| Mode | The ask sounds like |
|---|---|
| **audit** *(default)* | "make this self-explanatory", "too much text", "users don't know what to click", "make it textless and fix it" |
| **verify** | "check the change works", "verify the new empty state is clear" |

An ask to "fix it" or "clean it up" is still an audit here: deliver the findings with their
proposed changes; the fixes themselves are follow-on work.

**Inventory the inputs** and let them cap your claims:

| You have | You may claim | You may not claim |
|---|---|---|
| Source code | What the markup, copy, and handlers do | How it renders or behaves at runtime, unless you ran it |
| Screenshot | What is visible in that frame | Hover, focus, keyboard, other states, live behavior |
| Description, flow notes, a plan's proposed UI, or a preview mockup (`mentor:previewing`) | Issues in the described or drawn structure, including a state the mockup draws only on hover | Anything about the real app — label output as a design spec |
| A running app + browser tools | What you observed and executed | Accessibility conformance or real-user comprehension |

Nothing concrete supplied → produce a clearly labeled design specification, never invented
"findings" about an app you have not seen.

## Step 1 — Establish the task

For each screen in scope: the user's goal, the main action, constraints (permissions, data
rules, devices), and the existing conventions — component library, design tokens, product
terminology, language, i18n setup. Read the real files before describing them. Record
material assumptions in one line each.

**Design-skill preflight** (once per session; skip if one is already loaded). Pick by runtime
discovery, never hardcoded — the strongest design/UX skill in the active-skills list
(`frontend-design:frontend-design` when installed, else the best alternative); none →
proceed and note the omission. The two own **separate decisions, with no overlap**:
this skill owns *content and interaction* (which text appears, labels and wording, which action
is primary, the order and grouping of actions, states, what is disclosed on demand); the design
skill owns *visual design* (layout geometry, spacing, color, typography, imagery, motion,
component styling). Never restyle — when a finding needs a visual change ("the primary action
needs more emphasis"), state the need and leave how it looks to the design skill and the
existing design system's components.

## Step 2 — Audit

Read [`references/content-and-interaction-rules.md`](references/content-and-interaction-rules.md)
before classifying anything — it holds the classification test, the content decision
table, and the interaction rules. Then:

- **Classify every piece of visible copy by purpose**: essential · redundant · decorative ·
  contextual help · *content* (user-authored or task data — out of scope, never cut).
  Never classify by element name, string length, or keywords like "description" or "quote".
- **Find the interaction problems**: a buried or ambiguous next action, competing primary
  emphasis, common actions hidden in overflow or behind hover, icon-only controls without a
  clear meaning or accessible name, tooltip/placeholder as the only carrier of essential
  information, and missing loading / empty / error / disabled / success / permission states.
- **Ask the four first-time-user questions** at each main screen and state: could they
  identify the task, locate the next action, predict its outcome, understand the result?
  These are review questions — answering them is inference, not a usability result.

Tie every finding to a surface and a `file:line` (or a screenshot region). A finding with
no location is not actionable.

## Step 3 — Propose the smallest effective change

For each finding, say what to **remove, retain, rename, regroup, or disclose progressively**,
with a one-clause UX reason. Repair labels and structure before adding any explanation.
Do not redesign areas outside the ask.
[`references/before-after-examples.md`](references/before-after-examples.md) shows the
target shape, including what must *not* be removed.

**Tag each proposed change with its fix size**, so whoever acts on the review knows how:

- **small fix** — confined to one surface (a screen or component and its own children); touches
  copy, labels, accessible names, which action is primary (using the project's existing button
  variants), ordering, grouping, or states; uses components the project already has; changes
  no routing, data, business rule, permission, or workflow.
- **needs a plan** — anything bigger: merging, splitting, adding, or reordering steps in a flow;
  moving functionality between screens; navigation; a shared component other screens also
  render; or a new shared component. These change behavior users rely on, so say in one clause
  why each needs agreement before anyone builds it.

When small fixes span more than ~3 surfaces, say so once in the review: too many to apply and
check in one pass, so they are worth planning together.

Shape proposals so they can be applied safely: reuse existing components and tokens; keep
semantics, keyboard behavior, responsive layout, and data intact; when strings live in locale
files, name the locale entries to change, in every language present. Describe proposed UI in
the reply, never as a mockup file.

## Step 4 — Verify (verify mode)

Check a change someone has already made, without editing anything. Run what the project
already has and what the environment allows:

- the relevant existing checks (typecheck, lint, unit/component tests for the changed files);
- with a runnable app and browser tools: the changed screen at a narrow (~360px) and a
  desktop width, each changed state, and a keyboard-only pass (tab order, visible focus,
  Enter/Space on the new controls);
- re-read the diff against the failure conditions in
  [`references/acceptance-tests.md`](references/acceptance-tests.md) — e.g. did a removal
  take away a constraint, a row action, or user content?

## Output

Size the output to the ask — a one-component review gets a few lines, not an audit report.
The minimal-copy preference is for the product UI, not for your engineering explanation.

```markdown
**Mode:** audit | verify · **Input:** source | screenshot | description

| # | Surface (`file:line`) | Finding | Class | Proposed change | Size | Why |
|---|---|---|---|---|---|---|
| 1 | ProjectsDashboard `L12` | "Unlock your productivity" hero above the list | decorative | remove | small fix | competes with the list; says nothing actionable |

**Evidence** — Observed: … · Executed: … · Inferred: … · Not tested: …
```

In verify mode, replace the table with one `Check · Result` row per check, and list any new
problem as a finding row below it. In both modes, report evidence in the
four buckets: a check you could not run goes under *Not tested* with the reason, never rounded
up to a pass. Never claim accessibility conformance from a partial check, or user
comprehension without real users.

## References

| File | Read when |
|---|---|
| [`references/content-and-interaction-rules.md`](references/content-and-interaction-rules.md) | Every audit and verify run — before classifying copy |
| [`references/before-after-examples.md`](references/before-after-examples.md) | Writing proposed copy or structure changes; unsure whether something may go |
| [`references/acceptance-tests.md`](references/acceptance-tests.md) | Step 4's self-check in verify runs (the *Fails if* lines), or when testing changes to this skill |
