# Surface mockup contract

The rules for drawing **whatever a person or program receives** in a scenario: a screen, CLI output, a chat
post, an assistant's tool call, an API body, an email, a push, a printed file, or a surface nobody listed.
The main thread reads §4 (`_ids.md`) in `SKILL.md` §1, §1–§3 (inventory, resolution, edge cards) only when
it traces itself, and §9–§10 (packing, briefs, recount) in `SKILL.md` §3–§4; when a trace worker traces, that
worker applies §1–§4. Every cells worker reads it whole, plus its own primitives in `surface-catalog.md`.

Every cells-worker brief carries the literal token `mentor:frontend-mockup`. The token names this contract,
and it covers every surface, not only web screens.

Contents: 1 Inventory · 2 Resolution · 3 Edge cards and variants · 4 `_ids.md` · 5 Hop files and cells ·
6 Provenance · 7 Before/After and the change predicate · 8 Faithfulness, format and accessibility ·
9 Packing and briefs · 10 Self-check and recount · 11 Retired rules

## 1. Inventory (before any fragment worker)

The main thread runs the inventory after the section plan and before the diagram probe or any cells or
section worker. A read-only research or probe worker may feed it. When `SKILL.md` §1 sends tracing to one
trace worker, that worker does the tracing below, writes its evidence to `_trace.md` and drafts `_ids.md`
from it (§4); the main thread reads `_ids.md` and the worker's short report, never `_trace.md`, and pins the
ids. Workers cannot ask the user, parallel workers must agree on
ids and on who owns each hop, and the worker split is counted from the inventory, so none of this can wait
for a parallel worker.

**Tracing is read-only.** Read files and git history (`grep`, `git show`, `git log`); never run a command
against a running service, container or database to see how the change would behave (a `psql` in the local
stack, a request to a local API), not even inside a rolled-back transaction. The user's running stack is
theirs, and the page draws what the code and the plan say. A behaviour the code cannot settle becomes a
question in Questions for you. A screenshot of a screen the running app already shows, for §8's Before
picture, is allowed: it reads what is there and changes nothing.

Walk each scenario from its trigger to its outcome and list every surface someone perceives. A scenario is an
actor, a trigger, an outcome and an ordered chain of **hops**.

- **A hop starts** where the perceiver changes, or moves to a different app, route, channel or conversation,
  file or device (CLI → chat → web; the command's channel → the channel the bot posts in).
- **Nesting.** Without that move, an overlay that hides the view (a modal, sheet, dialog or permission prompt,
  a TUI keystroke step) is a frame of the hop. An output added to the view (a toast, an ephemeral reply, an
  inline tool call) nests in the frame of the step that produced it.
- **CI output.** A CI job log is a hop only when the plan changes what the job prints. Tool output also posted
  elsewhere is drawn once, where the actor reads it.
- **Order and caps.** Hops run in causal order; in a fan-out each branch records `after=h<n>`. A card holds at
  most 6 hops, 12 variants and 40 frames, and a parent holds at most 8 edge cards. Past either limit, split
  before ids are pinned (an oversized parent becomes two parent scenarios). On a re-run, ids are already
  pinned: a card that a revision pushes past a cap keeps every existing id, and the overflow (a new edge case,
  hop or variant) starts a new parent scenario `S<next>` whose title names the card it continues.

| # | Signal, strongest first | Example |
|---|---|---|
| 1 | The plan states the surface | "posts to the deploy topic", "returns 403", "prints" |
| 2 | The plan names a changed path | `cmd/<tool>/seal.go`, `*.proto`, `templates/email/*.html`, `app/**/page.tsx` |
| 3 | An emitter reached from a changed symbol | grep the symbol, then each status value, event, queue or routing key and column it writes, then the consumers that switch on them, link by link until the scenario's outcome. Where the chain leaves the repo (a CI job, a third party), the next link is the code that writes the status back |
| 4 | A dependency or config key | `web-push`, `react-toastify`, `@slack/bolt`, a webhook URL key |
| 5 | Wording alone | "notify", "tell the user" |

**Check every hop against its emitter's guard, whichever signal found it.**

- Read the guard around the emit call (the `case` or `if` on status, stage, flag or role) and every value that
  delivers to it. Record them on the hop line as `guard=` and `via=`. `via=` holds one or more values, because
  one hop can be reached by several links. The parent card's hop line lists **every** value the trigger
  reaches, including the ones its edge cards draw, so the path arrow above the hop names every writer and
  the reviewer sees all the ways in; each edge card's `takes:` then picks one of them.
- **Find every writer of each value.** A status is often written in one app and switched on in another, so
  grep the value's constant across every app in the repo, not only the consumer's. Each writer the trigger
  reaches is its own `via=` link, recorded with its writer and timing: `status:X (file:symbol, async)`. Keep
  this to a grep that returns `file:symbol`; the writer's file body is not read. A value whose writer is not
  found stays its own link, marked `data-gap="untraced"`, and is never folded into another value.
- A guard value the trigger reaches off the main path is an **edge card**, and each edge card names the value it
  takes. A guard value the trigger cannot reach belongs to another scenario and is not listed on this card.
- **The code's chain wins.** When the plan places a hop after a trigger its guard rules out, draw the code's
  chain, mark the plan's link `data-gap="unspecified"` ("plan leaves open"), and add a question to Questions
  for you. Never draw the plan's link as today's behaviour.
- A hop found only in code records `found=code`. It becomes a question for the user only when its guard or
  payload reads something the plan changes; otherwise it is drawn as unchanged context.
- The inventory locates only a `file:symbol` per hop, so no HTML or CSS body reaches the main thread.

## 2. Resolution

**Family, then primitive.** The `surface-catalog.md` §2 Detection column gives the family and its default
primitive, but **the payload the code emits decides**: a chat post sent as `{text}` with no card payload is a
P3 message, not a P4 card. Prefer what the person sees at the hop; if still tied, use the shape fallback.

**Emit and render are recorded separately.**

- `emit=` is the call site that writes the bytes, with their stream and exit or status code, not where a
  string is defined. One string written from two call sites gives a second card: an edge card when the
  stream or the exit or status code differs, otherwise a variant.
- `render=` is the code that draws the bytes (web push is built in a worker and drawn by a service worker), or
  `platform:<name> · dialect:<markup>` when a platform or the OS draws them. A dialect with no in-repo spec is
  marked "(verify)", and its frame carries a `<details>` holding the exact bytes sent.

**Shape fallback and the five questions.** When no family matches, pick the primitive by shape
(`surface-catalog.md` §2, Shape fallback), and settle five questions before any worker: (1) who perceives it,
and through which channel; (2) which `file:symbol` produces it; (3) what hosts it, and whether that chrome is
ours; (4) its limits; (5) its outcomes and variants. Derive all five from the repo. Ask at most **one**
question per new surface, only when (1) or (2) is open, cleanest option first; two such surfaces mean two
questions, one per turn. For a large producer, a read-only probe worker may gather (2)–(5).

**SURFACE BRIEF.** A new surface is recorded as `family: new:<slug>` with a compact brief:

```text
SURFACE BRIEF: label-zpl · confidence: high · settled: derived+asked 2026-10-10
PERCEIVER: warehouse picker, printed 4x6 label        PRODUCER: services/shipping/label.go:RenderZPL
HOST: thermal label printer · chrome ours: no          LIMITS: 4x6 in, 203 dpi, 48 chars per line
OUTCOMES: ok · edge: missing-address (ErrNoAddress) · variant: long-name (cut at 48)    SHAPE: paged → P9
```

- **Reuse.** A re-run reuses the brief verbatim and asks nothing. It is re-derived only when the plan text it
  cites changes or the user corrects it.
- **Low confidence.** `confidence: low` adds a frame label and a question to Questions for you.
- **No delegation.** It records `settled: self-authored`.

## 3. Edge cards and variants

- **An edge case is its own scenario card.** It is any outcome other than the parent's main path: an error, an
  empty result, a timeout, denied or missing permission, a guard that is false, a failure status. A different
  stream, exit code, HTTP or RPC status, or status value the code writes is an edge card too (§2), because
  whoever receives it acts on it differently.
- **Each `via=` value is its own card.** Two values that reach a hop through different links (a pre-check that
  fails before any job runs, and a job that runs and fails) are two cards, even when the consumer handles them
  in one branch and their posts look alike: different writers put them there, and what happened before and
  after differs.
- **Same outcome, different message: one card with a Differences list.** When several cases take the same
  value and end the same way (same stream and code) and differ only in what they print or say, keep one card.
  Its frame draws the main case once; a short **Differences** list under What happens gives each other case
  and the one line that differs (`case → line`), with nothing repeated. Spot the difference and state it
  plainly: the reviewer needs what differs, not another copy of the mockup. Typical cases: several reasons
  inside one error branch, or the stage name in a header. A value the trigger cannot reach is not a
  Differences line either; it belongs to another scenario.
- **Ids.** The parent id plus a lowercase letter (`S1a`, `S1b`, …), append-only in `_ids.md`. A new edge case
  takes the parent's next unused letter, and a removed one's letter is never reused, so drafts keyed
  `mentor-preview:<subject-slug>:<scenario-id>` never orphan. Each edge card has its own comment box, Copy
  button and draft key.
- **Order.** Parent scenarios in order, each followed by its edge cards; the page's contents list nests each
  edge card under its parent.
- **Body.** An edge card repeats only the hops that differ from its parent, keeping the parent's hop ids. The
  hops identical to the parent's render as one stub link in its path, "same as S1 up to h2", pointing at the
  parent card. A hop the edge card's path never reaches may be shown for context, greyed and captioned "not
  reached".
- **Variants never change the outcome.** They change presentation only: a platform, a theme,
  images blocked, a long value, which of several equivalent tools sent the same bytes. A platform the plan cares about (iOS against Android, desktop
  against mobile client) is a variant `platform` with ids such as `ios` and `android`, never a second
  scenario; every other card and variant renders on the first-listed platform. P5's images-blocked and
  dark-mode views are variants too. A card with no variants draws no variant switcher.
- **One operation, several entry points: a `channel` variant.** When one handler is reached through several
  entry points (REST through a gateway, gRPC, an MCP tool over the same RPC, a CLI command that calls it), draw
  one hop with a `channel` variant per entry point (`rest`, `grpc`, `mcp`), not one hop per entry point: hops
  are a causal chain, and these are alternatives the same actor picks from. It is the variant rule above
  (several equivalent tools sending the same bytes) applied to entry points, and it keeps two runs of one
  plan from drawing the same endpoint two ways. An entry
  point whose outcome differs (its own error mapping, a confirm step the others lack) is an edge card.
- **Overlays** (a modal, sheet, dialog, permission prompt) are frames of their hop, not variants.

## 4. `_ids.md` schema

The main thread writes it in §1, or pins the trace worker's draft, and it is read first on every re-run. A
trace worker drafting it on a re-run starts from the existing file: it appends new entries and moves
vanished ones to `retired:`, and never renumbers, reuses or deletes an id. Order: header,
surfaces, sections, flows, scenarios (each parent followed by its edge cards). The header gains
`decisions: stated` when the Decisions section uses **Stated in the plan** (`page-contract.md` §6).

```markdown
# Preview ids — fastship-release-gate
base: 4f1c2ab (git merge-base HEAD main)
built-from: plan.md sha256 3e1a9c07… · renderer: diagram-design profile=thanos
cells: groups=text,conversation,screen frames=34 workers=2
## Surfaces
### gchat-deploy
family: chat · primitive: P3 (plain text, no cardsV2) · group: conversation · owner: platform:Google Chat
emit: worker/src/consumers/deployments/tickets/deployment-tickets.consumer.ts:sendGoogleChatNotification (HTTP 200)
render: platform:Google Chat · dialect: Chat text formatting (verify) · chrome: schematic chat client
### label-zpl
family: new:thermal-label · primitive: P9 · group: payload · owner: product
SURFACE BRIEF: … (§2)
## Sections
30-architecture: plan §A3, §A8 · 50-data: plan §A4, §A6
## Flows
- seq-1 · owner=S4 · also=S4a · "QA bypass: CLI to chat to ticket" · plan §A3
- seq-2 · owner=none · "Nightly readiness sweep" · plan §A3
## Scenarios
### S4 — QA bypass
actor: QA engineer · plan: §A3, §A5 · view-axis: yes
hops:
- h1 · cli-thanos · trigger · found=plan · view=before+after
- h2 · gchat-deploy · after=h1 · via=status:ENV_VAR_SYNC_FAILED (sync gate, async) | DEPLOYMENT_FAILED, DEPLOYMENT_SUCCEEDED (execute job, async) · guard=stage in GAMMA,DELTA,PRODUCTION and its topic key set · found=code · view=before+after
- h3 · web-ticket · after=h1 · found=plan · view=before+after
variants: (none)
### S4a — QA bypass: release not ready
parent: S4 · takes: readiness=NOT_READY · plan: §A5 · same-as-parent: h1
hops:
- h3 · web-ticket · view=after
variants:
- ios "iOS" (platform) · android "Android" (platform)
retired: S4b (2026-10-12) · hop h4 of S4 (2026-10-12)
```

**Stability.**

- `S<n>`, edge-card letters and `h<n>` are append-only: never renumbered or reused. Variant ids and surface
  slugs are stable kebab names, and list order is display order. A fact on a line (a section's scope note, a
  hop's guard) may be corrected by the main thread when a worker's report shows it wrong, or by the trace
  worker while it drafts; an id never changes.
- A re-run reads `_ids.md` first, matches hops by surface slug plus `after`, edge cards by the value they
  take, and variants by id, appends new entries, and moves vanished ones to `retired:` permanently.
- A flow's **owner** is the scenario whose trigger starts it, so its diagram is drawn under that card
  (`sNN-s<k>.html`); `also=` lists the other cards it covers, which link to it. `owner=none` (a scheduled job,
  a flow no drawn scenario starts) puts it in the Sequences section. Flow numbers are append-only like card ids.
- Copy blocks, draft keys, page anchors and id prefixes use stable ids only, never render positions.

**Picture keys.** A hop that §8 says may need a picture records `pixels=a`, `b` or `c` (the §8 reason), plus
`shot=shots/<file>` when a real capture exists, so its cells worker knows to show the capture or say there is
none.

## 5. Hop files and cells

The main thread writes each card's shell from `_ids.md` (`page-contract.md` holds the templates). A cells
worker writes **one file per hop**, `_parts/20-scenarios/sNN[a]-h<n>.html`, holding every frame and every note
of that hop for every variant and view, in one Write.

```html
<div class="pv-hop" id="scn-S4-h2" data-id="h2">
  <h4 class="pv-hop-h"><span class="pv-hop-n">h2</span> Chat · #deploys <span class="pv-via">reached by the sync gate or the execute job (async)</span></h4>
  <div class="pv-v" data-vr="1 2" data-view="before">
    <figure class="pv-p3">
      <div class="pv-chrome">schematic chat client · #deploys (sample)</div>
      <div class="pv-payload" data-src="worker/…/deployment-tickets.consumer.ts:sendGoogleChatNotification">…</div>
      <figcaption>Chat post, S4 h2, Before</figcaption>
      <p class="pv-cap">S4 · h2 chat · Before</p>
      <p class="pv-src">Sources: worker/…/deployment-tickets.consumer.ts:147-158 (sendGoogleChatNotification)</p>
    </figure>
    <div class="pv-notes"><h5>In the thread</h5>…<h5>What happens</h5>…
      <ul class="pv-diffs"><li>legacy marker → <code>…the one line that differs…</code></li></ul>
      <h5>Rules and edges</h5>…</div>
  </div>
  <div class="pv-v" data-vr="1 2" data-view="after">…</div>
</div>
```

- **Every hop is on screen, in path order.** The hop's `id` is `scn-<scenario>-h<n>`, the anchor the card's
  path links to. Its `<h4 class="pv-hop-h">` names the hop id, the surface and where it is (taken from the hop
  line in `_ids.md`), plus the `via=` link that reaches it when the card's path has one. Notes headings inside
  the hop are `<h5>`.
- Each `.pv-v` cell carries `data-view` (`before`, `after`, `current`, or `before after diff` for a Change-set
  cell, which stays visible in both views) and, only on a card with variants, `data-vr` listing the variant
  positions it serves. Positions are render-time; a changed hop or variant list regenerates that card's shell
  and hop files.
- **Exactly one visible cell per hop, variant and view.** Placeholders fill the gaps: "Not there before — new
  in plan §X" (a new hop's Before), "Not reachable before — new in plan §X" (an input today's code cannot
  take), "not reached on this card" (a context hop).
- **The first notes heading is per primitive:** On screen (P1, P6), In the terminal (P2, P11), In the thread
  (P3, P4), In the inbox (P5), On the wire (P7), Heard (P8), In the file (P9), On the panel (P10). Then What
  happens, then Rules and edges.
- **Views inside one frame** (an email's Inbox, Open and Plain-text views, a raw payload, P9's Raw) are stacked
  `<details>`, never radios or tabs.
- **No page controls in a hop file:** no `<script>`, no `<form>`, and no radio or checkbox inputs, which the
  page's switching could confuse. A mockup's own buttons are real `<button type="button">` elements, `disabled`
  where the real control is disabled and otherwise `tabindex="-1" aria-disabled="true"`, so the project's
  disabled styles apply. Other fields (selects, text inputs, textareas) are drawn as static elements carrying
  the project's classes.
- **Ids.** Prefix every id in a hop file `<scenario>-h<n>-<variant>-<view>-` (`s4a-h2-ios-after-mk1`),
  including SVG `<title>`, `<desc>`, `<marker>`, `<clipPath>` and gradient ids, because many cells share one
  page.
- **Reserved classes.** No worker CSS selects `.pv-scn`, `.pv-ax`, `.pv-hop`, `.pv-hop-h`, `.pv-v`, `.pv-cap`
  or any `.pg-*` class; the page's own rules own them, and the switching rules carry `!important`. Put layout on
  an element inside the cell. `00-head.html` puts each cell's `<figure>` on a dotted backdrop, so a frame needs
  no outer margin or background of its own.
- **Chrome CSS** goes in the worker's one style file, `001-style-<group>-w<n>.html`, scoped
  `#sec-scenarios .pv-<primitive>`. When two groups share a primitive, each uses a variant class
  (`.pv-p6-inapp`). Project-rendered CSS that is not the pinned framework (a template's own stylesheet) goes in
  the same file, scoped to the payload's root class (`#sec-scenarios .pv-payload .tour-card`).
- **The frame supplies the host's inherited defaults.** Each frame wrapper sets the text colour, background,
  font and `color-scheme` the real host gives its content, so the review page's theme never leaks into a
  mockup (an unclassed label turned white-on-white in a dark page theme). The project's own dark mode is a
  `dark` variant applied the project's way (for example `class="dark"` on the payload root), never inherited
  from the page.
- **One or more payloads per frame.** A frame holds one `.pv-payload` per thing the receiver gets separately:
  stdout and stderr, a request and its response, a hook's stdin and its output. Chrome may select a payload
  element itself (to draw a stderr rule) but never its descendants.
- **CSS isolation runs both ways.** Chrome rules set every property they rely on (font-family, margin,
  padding, list-style, white-space, border) and never lean on UA defaults, because the project's CDN framework
  (for example Tailwind preflight) restyles `pre`, `button`, `ol` and headings page-wide. Project-rendered
  content sits inside `.pv-payload`, and no chrome or page selector crosses into it, because unlayered page
  CSS would override the project's real utilities. When that is not enough, a frame may use an
  `<iframe srcdoc>`: escape `&` first, then `"`, then `<` as `&lt;`, so no literal tag (and no `<script`)
  reaches the hop file. Marks inside a `srcdoc` cannot be counted, so a frame drawn that way carries its
  provenance marks on its outer chrome.
- **Images.** No external images. An image is a box at its real dimensions or aspect ratio, labelled with
  its real alt text and source (`[image 600x120 · alt "Acme logo" · emails/assets/logo.png]`). Avatars and app
  icons are initials on a neutral shape.
- **Markers.** The After view puts numbered markers (➊ ➋ …) on changed elements, keyed to a callout list in
  the notes, each callout citing its plan section.
- **Motion.** No typewriter, streaming, slide-in or pulse effect; a mockup is static per frame.
- **Screen readers.** Each `<figure>` has a `<figcaption>` naming the surface, card, hop, variant and view.

## 6. Provenance

Every visible element belongs to exactly one class, taken from its nearest marked ancestor, and is marked in
text as well as colour. A frame has `.pv-chrome` parts and one or more `.pv-payload`s (§5); inside each payload, verbatim is
the default and only exceptions carry an attribute, so every exception can be counted.

| Class | Markup | Treatment | Rule |
|---|---|---|---|
| Verbatim from code | default in `.pv-payload`; `data-src="file:symbol"` per element group | unmarked; the frame's `Sources:` line lists each `file:line-range (symbol)` | every tool, command, flag, field, operation and message is found in source, or it is NEW or untraced |
| Proposed by the plan | `data-pv="new" data-plan="§A4"` | dashed 2 px outline, "NEW · §A4" tag, ➊ marker in After | the tag names the plan section |
| Neutral host chrome | `.pv-chrome` | grey schematic, system font, initials avatars, labelled "schematic `<host>` frame" | only the host context needed to read the payload; no vendor logo, colour or font; no invented sidebars, space lists or composers |
| Illustrative | `data-pv="illus" data-kind="model\|sample\|runtime"` | dotted underline, italic, tagged "illustrative" or "sample" | non-deterministic content: assistant prose, chart values, latencies, timestamps, ASR results; assistant prose is about one line per turn and names the tool description or server instructions that steer it; "sample" only when no fixture exists, deploy-config values included |
| Untraced · plan leaves open | `<span class="pv-gap" data-gap="untraced">not traced: …</span>` · `data-gap="unspecified"` ("plan leaves open: …") | hatched · dashed | a detail with no source in the repo (a Before, or anything on a current-only page, such as host behaviour), never guessed · an After detail the plan leaves open |

An explanation the frame needs but the receiver never sees ("the browser tooltip reads…") is a `.pv-chrome`
note under the payload; marks inside it count like any other. The legend appears once, at the top of Scenarios
(`000-open.html`), listing only the classes the page uses. The footer prints the totals over the whole page:
"Illustrative N · Sample N · Not traced N · Plan leaves open N". Host chrome stays schematic because a page
that imitates a real organisation's branding cannot be published.

## 7. Before/After and the change predicate

**Before** is what the code did without the plan's change, for the same input, read at the `base:` that
`_ids.md` records once per repo the scenarios reach:

- the change is not in the tree yet: `HEAD`;
- the change is on this branch only: `git merge-base HEAD <default branch>`;
- the change is already merged: the parent of the first commit that implements it (the first commit after the
  plan was written that touches its critical files), with that commit named beside `base:`.

Read files there with `git show <base>:<path>`. A surface that is generated or gitignored has no history; its
Before is a copy the project kept (an older rendered file), named as a capture. **After** is the plan; for a
plan already implemented, draw what it specifies and list any later drift in the code under Rules and edges.

- Each scenario has **one** Before/After toggle, shown when any of its hops exists today (`view-axis: yes`).
- A new hop's Before reads "Not there before — new in plan §X". An edge card or variant the plan introduces
  shows in Before what today's code does with that input, labelled "today, same input", or "Not reachable
  before — new in plan §X".
- A Change-set hop (P11) shows its diff in both views (`view=diff`). A new hop's "not there before" wins over a
  Change-set's diff.
- A non-plan subject renders each scenario `view=current`, with no toggle.

| Primitive | Before is taken from | Before reads "not there before" when |
|---|---|---|
| P1 Screen | the route, components, tokens and i18n | the route is new |
| P2 Terminal | a golden file or output the user pasted; otherwise built from print calls and flag definitions, labelled "assembled from source, not captured" | the command is new |
| P3 Conversation | the code that builds each system message; human turns are sample and assistant prose illustrative, on both sides | nothing was posted there before |
| P4 · P5 | the payload builder and its exact JSON · the template and send code (From, subject) with fixtures | the card or template is new |
| P6 Notification | both the payload builder and the renderer (worker plus service worker) | the notification is new |
| P7 Wire exchange | proto, OpenAPI or SDL; the handler's error branch; marshaller config; the transport wrapper, such as an MCP error prefix | the endpoint or operation is new |
| P8 · P9 · P10 | prompts and SSML · template, columns and formats · panel config, with the same data on both sides | the flow, export or panel is new |
| P11 · Spec card | none: the diff is the comparison, shown in both views · the producing code, if it exists at `base:` | the hop is new (its "not there before" wins over the diff) · the producing code does not exist at `base:` |

**What counts as changed (plan subjects).** A hop has changed when anything its receiver gets differs, in any
variant: text, fields, headers, order, stream, exit or status code, error prefix, a limit crossed, timing or
count (retries, backoff, TTL, rate), or whether it is sent at all. Only a byte-identical hop is unchanged; it
is drawn as context, tagged "unchanged". A scenario is left out only when every hop is unchanged, and the
footer then names it. A one-line CLI message, an MCP error prefix or a chat header is a change.

**Copy block `view=`.** `before` or `after` from the toggle; `after` on a card with no toggle; `current` for a
non-plan subject.

## 8. Faithfulness, format and accessibility

- **Invent nothing.** Every claim, colour, string, field and step traces to a real file from the source pack
  or to the plan. Source authority and the per-primitive "most common lie" are in `surface-catalog.md` §3.
- **Sample values** come from fixtures, seed data or tests; otherwise they are marked sample. Never use a
  plausible invented person, amount or id as if it were real.
- **Limits are checked, not fixed.** A payload over a platform limit is a finding in Rules and edges, never
  silently trimmed.
- **CLI help formatted at runtime with no golden file** is assembled from source strings and labelled
  "assembled from source, not captured".
- **Screens** use the project's real tokens, components and icons. A new element cites the plan section that
  specifies it; an unspecified one is a dashed `data-gap="unspecified"` box. The Before's own contrast
  failures are shown and flagged, not silently fixed.
- **Narrow check.** Every primitive defines what 360 px means for it (`surface-catalog.md`); it is reflow only
  where the real surface reflows. A reflowing card gets a width axis (default, 360 px).
- **Accessibility.** WCAG-AA text contrast (4.5:1) and 3:1 for UI glyphs in both page themes; content stays
  real text; colour is never the only signal; each `pre` that scrolls is focusable (`tabindex="0"`).

**Format.** Pick the format per surface for the most precise review.

- **Live HTML is the default for every surface**, because it can be clicked, read, copied and switched. A web
  or app UI is always live HTML.
- **Text surfaces are never pictures.** CLI output, chat text, API payloads, logs, email text, config and diffs
  are precise only as text.
- **A picture is added beside the live mockup, never instead of it,** only where pixels carry what the
  reviewer must judge and HTML cannot reproduce them faithfully: (a) the Before of an existing screen whose
  change is visual (layout, spacing, a chart), captured from the running app; (b) a surface rendered by
  something the project does not control, where the look matters (a native widget, a third-party unfurl, an
  email client's rendering, a PDF or print layout); (c) canvas, chart, map, image or video output.
- **Real captures only:** a running app, a screenshot the project's own tests already produce, or a file the
  user gives; never drawn or generated. Each carries a caption with its source and capture time. With nothing
  to capture, the live mockup stands alone and the frame's notes say "no capture available", so a reviewer
  knows the look was not checked against the real thing. The inventory marks these hops `pixels=` (§4), and
  the worker's Self-check counts them (§10).
- **Storage.** WebP or JPEG, at most 1400 px wide, in `shots/`, referenced by relative `<img src>`, never
  base64. Capture uses whatever the host offers (a browser tool, the project's e2e screenshot tooling).
- **Whole screens from the real components.** A screen frame draws the whole screen the actor sees,
  every region built from the app's own components: their markup, classes and tokens copied from source, not
  an approximation and not a labelled sketch box for an unchanged region. A developer builds from this frame,
  so the unchanged surroundings are part of its precision. Page size is a warning, never a reason to cut a
  screen (`page-contract.md` §8). An email or document template (catalog P5, P9) is drawn whole too, unless
  it is long (more than about two screens tall, where the changed part would be hard to find): then it may be
  cut to the part the plan changes, copied from the template's own markup with its `<style>` kept, never
  redrawn by hand, and captioned "Excerpt of `<file>`: the rest is unchanged".

## 9. Packing and briefs

| Group | Primitives | Sources loaded |
|---|---|---|
| screen | P1, with nested in-app P6 | tokens, components, i18n, the pinned framework |
| text | P2, P11 | CLI and IaC code, goldens, flag definitions |
| conversation | P3, P4, P8, with nested P7 tool calls | bot, MCP and IVR builders, tool descriptions, error wrappers |
| payload | P5, push or OS P6, standalone P7, P9, P10, Spec card | templates, protos, builders, renderers |

- **Frames.** F is counted from `_ids.md`: the sum over hops of variants × views, without placeholders. A
  frame that embeds a full template or `srcdoc` counts as one frame per 4 KB of its markup.
- **Packing.** Pack card-by-group slices into workers of at most **30 frames**, filling one before opening
  the next. A slice over 30 frames splits between hops, since each hop file has exactly one writer. A worker
  may hold several groups, and 30 frames or fewer in total is one worker. How many run per wave:
  `SKILL.md` §3.
- **Style files.** Each worker writes one `001-style-<group>-w<n>.html`, named for the first group it holds,
  so no two workers write one file.

**A cells-worker brief carries:**

1. the token `mentor:frontend-mockup` and this contract's path;
2. the `surface-catalog.md` headings for its own primitives;
3. the `_ids.md` path and the card and hop ids it owns; the worker reads its entries (surfaces, cards, hops,
   variants, `base:`) and the plan sections they cite from the file, so the main thread does not paste them
   into every brief;
4. the `emit=` and `render=` paths, and the CDN pins from `page-contract.md`;
5. for the screen group, the component, token and font file paths found in research (the project's real
   design tokens and source), and any design principles or visual quality bar the plan states for the
   surfaces the change touches;
6. the output paths, and the instruction: "Read the real sources yourself; invent nothing; mark every
   exception; write each hop file in one Write." The brief then ends with `SKILL.md` §3's delivery rule.

## 10. Self-check and recount

Each cells worker returns, with named fields so an absence shows (`sources=` counts frames with a `Sources:`
line, `class="pv-src"`):

```text
Self-check: hops=N frames=N placeholders=N new=N untraced=N unspecified=N illus=N sources=N pixels=N captured=N no-capture=N js=0 ids-prefixed=yes names-prefixed=yes tags-balanced=yes
GAPS:
- S4 h2 after: plan leaves open: the header emoji for WAITING
```

The main thread recounts each mark per worker's files with `grep -o`, never `grep -c`, which counts lines and
undercounts two marks on one line:

```bash
for m in 'data-pv="new"' 'data-gap="untraced"' 'data-gap="unspecified"' 'data-pv="illus"' 'no capture available' '<script'; do
  printf '%s %s\n' "$m" "$(cat "${files[@]}" | grep -o "$m" | wc -l | tr -d ' ')"
done
```

Each `untraced` item is also listed under its hop's Rules and edges. `SKILL.md` §4 compares these counts
with the Self-check, reruns the worker on any defect listed there, and routes every `unspecified` item to
Questions for you and the totals to the footer.

## 11. Retired rules

Retired from the v3 contract: "every pane is a script-disabled `<iframe srcdoc>`", "skip when there is no visual delta" (replaced by the change predicate in §7), and never-publish (the page may be offered as an Artifact).
