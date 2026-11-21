# Why `previewing` works the way it does

Load this when editing the skill or before overriding one of its rules. `SKILL.md` states each rule with one
sentence of why; the narrative and the evidence live here.

## Why one page replaced topic × perspective

The skill the retired zoom command used to load wrote one page per topic × perspective (End user, Implementor,
Reviewer, QA), up to six or more files per subject, and its contract forbade a single page for the whole
subject. Three hand-built review pages in a real repo (a release-readiness gate, a list-table redesign, a
deploy-order change) showed what reviewers actually used: one page with a scenario rail, a clickable mockup
per scenario, the C4 levels that move, one sequence per changed flow, the changed data layer, and the
decisions. Nobody asked for the perspective split, and the split hid cross-cutting scenarios (a web action
whose outcome is a chat post) between files. One page per subject, organised by scenario, keeps the whole
story in one place.

## Why the page is adaptive

A section that the plan does not touch is noise, and an empty section reads as "forgotten". So each section
appears only when the subject changes what it shows, and the footer names every section left out ("Not
affected by this plan: …"), which turns silence into a statement the reviewer can check.

## Why questions go to chat, one at a time

The page is read-only toward the plan. A form on the page would need a channel back to the agent that a local
file does not have, and answers typed into a page are lost when it regenerates. Chat already is that channel,
and asking one question per turn, cleanest option first, keeps each decision small enough to answer
correctly. A mentor plan records each answer as a decision row, so the plan, not the page, carries it.

The rule is written into the skill itself rather than pointing at a personal questioning skill, because that
skill does not ship with mentor and Codex hosts do not have it.

## Why diagram-design is settled in the main thread

diagram-design asks a brand or profile question the first time it draws in a repo. Workers cannot ask the
user, and parallel workers that each hit the question would either stall or pick different answers. A
read-only probe worker loads the skill (keeping its long instructions out of the main thread) and reports
whether it would ask; the main thread asks once, and every diagram worker's brief carries the resolved profile
and "do not re-ask".

When the skill is missing, the install question is asked once per repo and the answer is saved as
`diagram_renderer` in `.mentor/config.json`, so a user who declined is never asked again. The fallback is
hand-drawn SVG that follows diagram-design's rules, so the page keeps one visual language; Mermaid is a last
resort for a single diagram that keeps failing the layout check, because its auto-layout looks different from
the rest of the page.

## Why hops

A scenario often crosses surfaces: an approval in the web app leads to a chat post, which links back to a
ticket page. Picking one "primary primitive" per scenario (an earlier design) hid the second and third
surfaces in an "Also happens" strip that nobody switched to. A hop is the unit a perceiver actually sees: it
starts where the perceiver changes or moves to another app, channel, file or device. Overlays stay frames of
their hop, and side outputs nest where they appear, so a card's hops, stacked in path order, read like the user's own path.

## Why the code's chain beats the plan's

Plans describe flows from memory. In the deploy-order review, the plan had an approval post a chat message, but
the code only moves the ticket to a queued status; the chat post comes later, from an execute job's callback or
a sync gate's failure, and only for some stages. Drawing the plan's link would have shown reviewers behaviour
that does not exist. So the inventory follows the code's emit guards and the values that reach them, draws
that chain with `via=` and `guard=`, and turns the plan's contradicting link into a question.

## Why edge cases are separate cards

Edge cases started as states inside one scenario's switcher. Reviewers comment on edge cases separately ("the
not-ready case should block"), so each needs its own comment box, Copy block and draft key. A separate card
with a child id (`S1a`) gives that, and the contents list shows edge cards under their parent. What stays inside a card
are variants that keep the outcome (platform, images blocked, dark mode), because a comment on "iOS" is a
comment on the same scenario.

Cases that end the same way and differ only in their message (several reasons an edit is blocked, each with
its own explanation) were first drawn as separate edge cards, which repeated the same mockup several times.
The user chose one card with a short Differences list instead (2026-10-10): the reviewer needs to see what
differs, stated simply, not another copy of what is the same. A different stream or exit code still makes an
edge card, because a program receiving it behaves differently.

The Differences rule then swallowed a real edge case. In a verification run on a deploy-notification plan, the
chat consumer handled two failure statuses in one branch with a different header line, so the page drew the
sync gate's failure as one Differences line on the deploy-job failure card. The two statuses are written by
different code (a gate that stops before any job is submitted, and the job's own callback), and the inventory
had only traced the consumer's switch, so the gate never appeared in `via=` at all. Two rules came out of it:
every value a guard switches on is grepped for its writers across all apps, and each `via=` value is its own
card. Differences is only for text that varies under one value.

## Why a label printer is a new surface

The catalog's P9 row once listed "printed labels" under Used by. A verification run on a ZPL label plan then
filed the label under the `document` family, skipping the SURFACE BRIEF that the contract's own example asks for
(perceiver, printer host, dots and line limits). A primitive says how to draw a surface; a family says what it
is and where its rules come from. A label printer shares P9's paged drawing but none of the document family's
detection or edge cases, so it is `new:<slug>`, drawn with P9.

## Why one scrolling page

The first pages showed one scenario at a time: a rail of radios on the left switched cards, and a hop strip
switched hops inside a card, so a reviewer saw one hop of one scenario and had to click to find the rest. The
sequences sat in their own section far below, away from the scenario they explained. The user asked for one
page that scrolls instead (2026-10-11): a contents sidebar that stays in view and covers the whole page,
scenarios and their hops stacked in order, each sequence under the scenario that starts it, and section titles
that cannot be mistaken for a mockup's own headings.

- **Scrolling keeps the path whole.** A hop is a step of one person's path, so the steps read best one after
  another, the way the person meets them. Hiding all but one made a three-hop card look like one screen.
- **The sidebar replaces the rail.** It links instead of switching, lists every section as well as every
  card, and marks the part on screen, so the reader always knows where they are on a long page.
- **A sequence belongs to its scenario.** The flow diagram explains how the screens above it are connected;
  drawn next to them, it answers "what happens between these hops" where the question comes up. The owner is
  the scenario whose trigger starts the flow; other scenarios it covers link to it rather than repeat it.
- **Variants and Before/After still switch.** They redraw the same frame, so stacking them would show each
  frame two to six times; the switches sit in the card's title bar, which stays in view while the card
  scrolls. The user kept these as switches when shown the prototype.
- **Titles in a different voice.** Section titles are serif over a heavy rule, with one sentence on what the
  section shows, and frames sit on a dotted backdrop. Mockups use the product's own sans headings, so the
  page's structure never blends into them.
- **Dark by default.** The user asked for it; the theme button switches to light and remembers the choice,
  and print always uses light.
- **Phone width.** The first scrolling prototype scrolled sideways at 375 px because worker CSS set
  `white-space:nowrap` on inline code; page prose now wraps long names, and the §4 look checks the page width.

## Why switching is CSS-only

What still switches is a card's variants, its Before/After view and its width.

- Viewers without scripts: a sandboxed Artifact frame may throw on clipboard or storage access, and previews,
  thumbnails, Quick Look, Git-host HTML previews and locked-down browsers run no script at all. Radios still
  switch in all of them, and a static capture shows the checked default.
- Isolation: a script error in any fragment cannot freeze the review; the contents still link without one.
- Verifiable: "no `<script` in hop or flow files" can be checked with grep.
- No size penalty: shipping every variant as markup costs about what a JS renderer's data would.
- Fallback: without `:has()` (baseline since 2023-12), every variant stacks with a caption.

The block at the end of `assets/page.css` is this loop's output. Run it again only when the caps or axes change
(`page-contract.md` §4), and paste its output over the block's old copy:

```bash
{
printf '@media screen{\n'
for n in $(seq 1 12); do printf '.pv-scn:has(.pv-ax-variant input[data-i="%s"]:checked) .pv-v:not([data-vr~="%s"]){display:none!important}\n' "$n" "$n"; done
for v in before after; do printf '.pv-scn:has(.pv-ax-view input[data-id="%s"]:checked) .pv-v:not([data-view~="%s"]){display:none!important}\n' "$v" "$v"; done
printf '.pv-scn:has(.pv-ax-width input[data-id="narrow"]:checked) .pv-reflow{max-width:360px!important}\n}\n'
printf '@supports not selector(:has(*)){.pv-ax{display:none}.pv-cap{display:block}}\n'
printf '@media print{.pv-ax,.pv-comment button{display:none}.pv-cap{display:block}}\n'
}
```

## Why a text change counts as a change

The retired rule "skip when there is no visual delta" was written for web screens. Applied to other surfaces
it would skip a changed CLI help line, an MCP error prefix or a chat header, all of which a person or program
receives. The change predicate therefore asks whether anything the receiver gets differs, including stream,
exit code, timing and counts, and only a byte-identical hop is unchanged.

## Why `grep -o`, not `grep -c`

`grep -c` counts matching lines, so two marks on one line count as one. Hop files often put several marks on
one line, which made worker self-checks look wrong when they were right (or right when they were wrong). Every
recount uses `grep -o … | wc -l`.

## Why live HTML first, pictures only where pixels matter

The deploy-order review weighed 7.7 MB because it embedded 61 base64 still pictures of mockup states that the
page could have drawn as HTML. Text surfaces need no pictures at all, and a picture of text cannot be copied,
searched or switched. A real capture still earns its place where the look itself is the review: a visual
change to an existing screen, a surface the project does not render, or canvas and chart output. It goes in
`shots/` beside the page, never inline, so the HTML stays small.

## Why the page and the plan change together

A review page that lags its plan is worse than none: reviewers comment on behaviour that is no longer planned.
So any turn that changes plan content regenerates the affected fragments before it ends, and the page carries
the hash of the plan it was built from, so a page that slipped through (a plan edited in another session, by
hand, or on a host without hooks) is caught the next time anyone previews or reviews it.

## Evidence incidents (from the three reference pages)

- **B-1. No Before/After where the Before existed.** None of the pages could show today's behaviour, even where
  the current chat post was fully defined in code. A proposed header change was only visible against a Before.
- **B-2. Browser chrome around non-browser surfaces.** Traffic-light dots and an address bar wrapped a chat
  client. The same frame would be wrong for a CLI, a push or an email, so chrome is per primitive.
- **B-3. The page wrote the assistant's prose.** Invent-nothing cannot cover model output; it needs its own
  class, "illustrative", pointing at the tool description that steers it.
- **B-4. A proposed operation drawn like an existing one.** A tool chip named an RPC that existed only in a
  planning doc. Every tool, command or field is found in source or tagged NEW.
- **B-5. A wrong MCP error prefix.** The page printed `FailedPrecondition:` where the handler emits
  `Failed precondition:`. The transport wrapper is part of the payload and has its own source.
- **B-6. An API call drawn inside the product's web top bar.** A frame must not claim web ownership of an API
  surface.
- **B-7. Invented, undisclosed chrome text.** Sidebar entries, space names and a composer were made up; some
  values come from deploy config and cannot be sourced, so they are marked sample.
- **B-8. One long note and one overloaded switcher.** About 17 states in one switcher and 1,000-character notes.
  Notes split into On screen / What happens / Rules and edges, and cards cap their hops, variants and frames.
- **B-9. Full client against card.** A full chat client is more convincing but invents more chrome; the
  contract chooses the minimum host context needed to read the payload.
- **B-10. Size.** 7.7 MB from base64 pictures (see "Why live HTML first").
- **B-11. Web-only rules applied to every surface.** The old contract's script-disabled srcdoc panes, escaping
  order, swatch strip and 360 px check are web-only; "no visual delta" would have skipped real text changes.
  Invent-nothing and numbered markers carried over.

## Verification round 1 (2026-10-11)

The first verification of this skill found these, each now a rule in `SKILL.md` or a contract:

- **V-1. The opener was bypassed.** A test run opened the page with `open -a "Google Chrome"` directly, the
  same command `open_page` uses, and so skipped `MENTOR_PLAN_OPEN=off` and landed in the user's real browser.
  The skill now says to open only through `open_page` and to keep the §4 look in the host's own or a
  headless browser.
- **V-2. No "no capture available" caption.** The rule existed in contract §8, but nothing marked which hops it
  applied to, so no worker wrote it. Hops now carry `pixels=` from the inventory, and the Self-check counts
  `captured` and `no-capture` against it.
- **V-3. A diagram without `class="dd"`.** The ER diagram skipped the class the scoped CSS hangs on. The
  diagram Self-check now reports `dd=N` beside `diagrams=N`, and §4 recounts it.
- **V-4. A hand-drawn email excerpt.** The page contract's size note said to trim a large template "to the part
  the plan changes", and a worker redrew that part by hand instead of copying it. An excerpt must now be the
  template's own markup, captioned as an excerpt.
- **V-5. A no-change re-run re-asked the first question.** A second run on an unchanged plan restarted the
  question loop. A run that rebuilds nothing now reports the open count and waits to be asked.
- **V-6. The main thread ran out of room before any worker.** Tracing a six-surface plan (CLI, chat, MCP, API,
  email, push) by grep and read in the main thread took its context from about 71k to 174k tokens before a
  single worker ran. A full-stack plan in another run reached about 532k.
  Tracing now goes to one read-only worker that returns `file:symbol` chains; one worker, because the chains
  and the ids that follow them need one author.
- **V-7. No helper path, so no workers.** In two of five headless runs neither `PLUGIN_ROOT` nor
  `CLAUDE_PLUGIN_ROOT` was set in the shell, so the helpers could not run and the page was built serially.
  §0 now falls back to the skill's own base directory.

## Verification round 2 (2026-10-11)

The second verification passed its goals and found these, each now a rule:

- **V-8. A build tested the plan against the user's running database.** A serial run checked an upsert with
  `docker exec … psql` in the user's local stack: a temp table in a rolled-back transaction, so nothing
  persisted, but the stack is the user's and a review page draws what the code says. Research is now
  read-only on files and git, in the main thread and every worker; what the code cannot settle is a question.
- **V-9. A trace worker wrote outside the review folder.** It left a copy of its file in the plan's folder;
  the main thread caught it. The delivery rule used to reach only fragment workers. Every brief, the trace,
  research and probe workers' included, now names the only paths its worker may write.
- **V-10. The trace worker did not stop the context fill.** With V-6's worker in place, session 1 of a
  six-surface plan still went from about 71k to 172k tokens before any cells worker ran, and the main thread
  stopped there. A tally of that transcript: about 37k from reading `surface-mockup-contract.md`,
  `page-contract.md` and the catalog whole, about 17k from reading the 38 KB `_trace.md`, and about 15k from
  retyping it as `_ids.md` and `_brief.md`. Three changes answer it:
  - the trace worker drafts `_ids.md` itself and returns a short report; the main thread reads `_ids.md`,
    which its own fragments need anyway, and never `_trace.md`. One author still writes the ids before any
    parallel worker starts, and the main thread pins them;
  - the page's fixed CSS, switching block and script (about 15 KB of `page-contract.md`) moved to `assets/`
    and are inlined at assembly, so no run reads or retypes them, and a hand-copied rule can no longer drift;
  - each reference is read when its step starts, only the sections the main thread applies; cells briefs
    pass `_ids.md` by path instead of pasting entries into every brief.
- **V-11. A stopped first build started over.** A full build ran out of usage after about 54 minutes with
  most fragments written. Catch-up keyed on `review.html`, which does not exist until assembly, so a fresh
  session would have regenerated everything. `_built.md` now records each fragment once it passes its check,
  with a hash and the worker's Self-check and gaps; a fresh session with `_ids.md` and no `review.html`
  resumes and writes only what is missing. A file merely present is not enough, because a worker that died
  mid-write leaves one.
- **V-12. A path arrow named one writer.** A parent hop's `via=` listed only the value its main path takes;
  the other values sat only on their edge cards, so the arrow above the hop named the deploy job and not the
  sync gate. The parent's hop line now lists every value the trigger reaches.
- **V-13. A no-change run repeated the publish offer.** The question loop already stopped re-asking on a page
  that is current (V-5); the publish offer is now made once per build for the same reason.
- **V-14. One endpoint drawn two ways.** Two runs of the same backend plan drew a new RPC offered through
  REST, gRPC and MCP as three hops in one run and as one hop with three variants in the other. Hops are a
  causal chain and these are alternatives, and the variant rule (§3: several equivalent tools sending the
  same bytes) already covers alternatives that end the same way, so it is one hop with a `channel` variant;
  an entry point whose outcome differs is an edge card.
- **V-15. A finished worker waited ten minutes.** A main thread launched its one worker in the background and
  set a twenty-minute wakeup as a heartbeat; the worker finished early and the page waited for the timer.
  Round 3 also tried foreground waves; previewing now keeps no waiting rule of its own (see "Mentor v5.0.0:
  no worker-handling rules" below).
- **Not a defect: the citation.** One finding said a note cited `dispatch_test.go:183` and `:184` for
  assertions at `:182` and `:183`. `grep -n` shows the assertions at 183 and 184, so the page was right and no
  rule changed.

## Verification round 3 (2026-10-11)

A fresh build of the announcements plan (38 cards, 6 surfaces, three apps) finished in one session. The main
thread grew 73k tokens from skill load to the first cells worker, against 117k for the same plan before
round 2's fixes. It found these:

- **V-16. The page came out at 1.16 MB, and the limit gave way, not the screens.** Two thirds of the heaviest
  frames' bytes were the real utility classes of whole screens. A trial cut the frames down to the changed
  region with the rest as labelled boxes (1.21 MB to 1.03 MB). Shown both side by side, the user chose whole
  screens built from the app's real components, "for most development precision" (D20): a developer builds
  from the frame, so its unchanged surroundings are part of what it tells them. The 1 MB line is a warning
  reported to the user; nothing is cut to fit.
- **V-17. Reruns went to the background.** The §4 rerun and a §7 regeneration were sent as messages to
  finished workers, which resume in the background, so the turn ended mid-build and finished only on the
  task notification. That was a side effect of the foreground waves; with those gone, how to fix a worker's
  output is left to the agent.
- **V-18. "Settled with you" for decisions nobody settled.** A plan with no decision table had its stated
  choices listed as settled with the reader. They now go under "Stated in the plan".
- **V-19. Small leftovers.** The main thread peeked at the inlined assets (about 1 KB; it is now told the facts
  it needs are in the page contract), and the §4 look at phone width stopped at 500 px in headless Chrome (it
  now names a 375 px iframe).

## Verification round 4 (2026-10-11)

A re-check resumed round 3's build with the page and two fragments removed. Resume worked, and these were fixed:

- **V-20. The resume missed fragments that were never written.** It compared `_built.md` with the disk, found
  nothing wrong, and caught one missing hop only when the assembled page had a dead link. It now lists every
  fragment `_ids.md` calls for and writes the missing ones in one wave.
- **V-21. Three questions had no record.** They survived only because `10-answers.html` was kept; a rewrite
  would have dropped them. Its items are now recorded in `_built.md` as `QUESTION:` lines.
- **V-22. A ✅ looked like a plan change.** `_plan.md` gained a progress mark, which a later revision's diff
  would have read as changed text. The §7 diff now strips ✅ marks, as the stamp does. A fact the main thread
  corrects in `_ids.md` from a worker's report (a section's scope note) is allowed; an id still never changes.

## Instruction hygiene, synced with mentor (2026-10-11)

The pre-ship hygiene pass found previewing's worker rules contradicting mentor's general ones at the time
(waiting for workers, fixing a worker's output, where a worker writes). The waiting and recovery rules were
later dropped with the rest of mentor's worker handling (next section). One rule from this pass stays:

- **V-25. Where a worker writes: the folder its brief names.** A trace worker whose brief named the plan left
  a copy of its file beside the plan (V-9). Previewing's briefs name the review folder and list the only paths
  a worker may write.

The same pass found smaller gaps, which the user approved as one batch:

- **V-26. A resume after a plan edit ran all of §7.** That would assemble a page with fragments still missing,
  leave a `review.html` the next run takes for a finished build, and keep the old stamp, because
  `00-head.html` still matched its `_built.md` line. A resume now runs §7 up to assembly (the diff, append and
  retire, the deletions, every fragment step 3 names counted as missing) and assembles once.
- **V-27. "Stated in the plan" vanished after the first answer.** The first chat answer starts a decision table
  in the plan, so the "no decision table" test turned false on the next regeneration and every stated decision
  left the page. `decisions: stated` in the `_ids.md` header now keeps the table.

## Mentor v5.0.0: no worker-handling rules

Mentor v5.0.0 stopped prescribing how subagents are handled: no contract block appended to worker
prompts, no delegation-policy preflight, no waiting or recovery rules. Previewing followed: §3 now just uses
workers when the host supports delegation and the user has not restricted it, and otherwise builds serially.
The no-timer line (V-15) went with the waiting rules; the host decides how workers are awaited. Previewing's
own worker contract — the paths a worker may write, the `Self-check:` line, the main thread never reading
`_trace.md` — stays, because it shapes the page, not the agents.

## Retirement of `ui-mockup-contract.md`

`references/ui-mockup-contract.md` belonged to the retired topic × perspective skill. It made every mockup pane
a script-disabled `<iframe srcdoc>` with no switching, skipped surfaces with no visual delta, and forbade
publishing. All three conflict with this skill: switching is CSS radios on the page, the change predicate
replaces the visual-delta rule, and the page may be offered as an Artifact. `surface-mockup-contract.md`
replaces it and covers every surface; the `mentor:frontend-mockup` token it introduced is kept.
