Overlay a mentor plan run loads when the requested goal is a retrospective of one
finished agent session. It rebuilds the session from disk, even after compaction,
and delivers one PR/MR per repository plus unapplied proposals. Planning owns the
run; PR review replaces plan approval; batch harvesting across sessions belongs to loom, and a
forward code-change goal belongs to the software-change playbook.

# Playbook — retrospective

Editing-only rationale — including what was ported from pstack and deliberately
altered — is in [retrospective/rationale.md](retrospective/rationale.md) →
**What was changed, and why**. Read it when editing or questioning a rule.

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Planning's general flow never names transcripts, lenses, or skill authoring. This
playbook is where those live. Planning loads it when the goal is a retrospective,
records `## Playbook: retrospective` plus a decision-log row, and reads the
overlays below. The planning-entry exception replaces plan approval for retros;
the remaining overlays fill the general flow’s slots. This playbook is **never co-loaded with
`software-change`** — a retro owns skill-change delivery through PRs/MRs, with local fallback.

## Planning entry

Natural-language retrospective requests and Claude Code's `/mentor:retro` facade
enter planning with the goal `retrospective of session <id>`. Skip plan approval and
pre-run human questions; PR review is the human gate, so requested retros run end to end.

- Check the live own/legacy edit gate in the entry worktree before any evidence work
  or worktree creation. When it reads `ARMED`, refuse as `/mentor:retro` does and leave
  the gate untouched. Refuse while another plan run is active or paused in this session.
  A saved retrospective for this requested session reuses its evidence and stored
  `approved`/`in_progress` state, including released playbook aliases. Before transitioning
  or calling `begin-run`, inspect any `paused:` note: a stop-word pause requires the
  human's explicit resume; an always-pause action stays unapplied under **Needs your call**,
  with a `resumed` row before continuing.
- Write the durable plan, Goal check, decision log and Done review under
  `.mentor/plans/<slug>/`. Resolve facts from evidence and reversible choices through
  decision-makers; log choices with `review?: needed` rather than asking the human.
- Run the existing plan validation (`plan-state.sh verify <slug>` when available).
  Move only this validated plan directly from `draft` to `in_progress`, using
  `plan-state.sh set <slug> in_progress`; never call `begin-plan.sh` or
  `approve-plan.sh`. Resume `approved` with the same targeted transition.
- Log this decision row verbatim: "no plan approval — retro playbook; the PR review
  is the human gate". Start native continuation with `plan-state.sh begin-run <slug>`
  when available; without the Claude Stop hook, keep running in-thread and preserve
  the same plan and checks.
- Before applying any Accepted row, record the destination baselines in Deliver
  mode below; a restart reuses those baselines instead of treating prior retro edits
  as unrelated dirty content. Each row becomes one implementation step and retains
  planning's independent grading and saved-verdict contract. If there are no
  Accepted rows, use a report-only step whose check verifies the Done review and
  zero PRs, rather than inventing a change.

## The overlays

### 1. Research directives (planning Step 2)

Build the evidence graph, then run the lenses, then synthesize. The reviewers are
read-only; the **parent** persists each returned output immediately under `evidence/`:

1. Follow [retrospective/evidence-graph.md](retrospective/evidence-graph.md) to write `evidence/manifest.json` and one
   digest per transcript. The session is rebuilt from disk, never from memory, because
   after compaction the parent's context holds only the latest summary.
2. Dispatch the three lenses — [retrospective/lens-judgment.md](retrospective/lens-judgment.md),
   [retrospective/lens-tooling.md](retrospective/lens-tooling.md), [retrospective/lens-divergent.md](retrospective/lens-divergent.md) — as native subagents,
   in parallel when the host has them, else serially in-thread and labelled
   `self-graded`. Each lens returns its output read-only; the parent writes that return
   verbatim to `evidence/lens-judgment.md` / `evidence/lens-tooling.md` /
   `evidence/lens-divergent.md` the moment it lands. On restart the parent skips any
   lens whose evidence file already exists.
3. Run [retrospective/synthesizer.md](retrospective/synthesizer.md); it returns the synthesis read-only and the parent
   writes it verbatim to `evidence/synthesis.md` (Coverage, Accepted, Rejected,
   Backlog, Leftovers), skipped on restart if that file already exists.

### 2. Definition of done (Goal check and `Done when:`)

Per Accepted row: the new or edited skill passes skill-creator's `quick_validate.py`;
its description triggers on the prompt that motivated the row; and when the destination
convention includes a symlink (e.g. `.claude/skills/<name>` plus a relative
`.codex/skills/<name>` link), that link is relative and resolves (checked with
`readlink` / `readlink -f`). An in-repo edit (`plugins/*/skills/`) or a destination
with no symlink has no symlink check. A row is not ticked until its own check passes.

The Goal check also requires every repository with delivery available to have an
open, confirmed PR/MR whose body passes `retro-pr-body-check.sh`, with every other
change reported as kept local. A pushed branch or compare URL does not pass.

### 3. Extra always-pause items (the run)

For this requested retro, committing its isolated changes, pushing a new
`retro/<slug>` branch and opening a PR/MR proceed without asking unless the destination's
constitution explicitly requires approval for that action. Read that constitution before
delivery. PR review replaces plan approval, never a destination constitution's Always-pause
item; when one blocks delivery, keep that repository's changes local under **Needs your call**
and continue other repositories. Force-push and pushing to protected or base branches are
never performed. Every always-pause action stays unapplied under **Needs your call** while
the retro continues (Deliver mode step 3); stop words still pause the run.
Never merge, enable auto-merge, or invoke `mentor:merging`, even under
a constitution merge grant; a human owns that decision.

Lessons that contradict a plugin core concept, change the constitution, or change
another tool's config (e.g. agt roles) are never applied and never paused on — they go
to the Done review's Leftovers and the run continues.

### 4. Deliver mode (the run's deliver state)

Deliver one PR/MR per git repository touched, using the following sequence so each
review contains only the retro's changes. Do not invoke shipping's full workflow,
`/simplify`, generic test commands, or the software-change merge tail.

1. **Baseline before edits.** For every destination, walk up to its nearest existing
   ancestor directory, then resolve its git worktree root with
   `git -C <that directory> rev-parse --show-toplevel`; if that directory is outside
   git, use a null root and keep the destination local. New skill directories may
   not exist before the first edit. Before the first edit, save
   root, HEAD, current branch, base branch (the destination's documented integration
   branch, else `origin/HEAD`), remote and all dirty paths, including staged and
   untracked paths, in `evidence/delivery.json`.
   Store per-file baseline status and the retro's exact edited paths, including
   resource files, relative symlinks and deletions. This snapshot is immutable on resume.
2. **Group and isolate.** Group applied paths by root. A path dirty at baseline
   cannot be isolated: keep it local and list it under **Needs your call**. For the
   remaining paths, create `retro/<slug>` from `origin/<base>`, never from arbitrary HEAD.
   If the checkout has unrelated dirty content, is on a non-base branch, or its HEAD
   differs from `origin/<base>`, use a separate `git worktree` from `origin/<base>`
   and copy only the retro's files,
   preserving symlinks and deletions. Compare against the baseline HEAD and the base:
   never copy unrelated committed differences within a touched file. Transplant only
   the retro delta when it applies cleanly; otherwise keep that file local and name
   the conflict under **Needs your call**. Never stash, reset or stage someone else's
   work. A new branch from current HEAD alone does not isolate the retro.
3. **Unavailable delivery.** Paths outside git, repositories with no remote, no
   suitable `gh`/`glab`, unavailable base, or an unresolvable isolation or delivery
   failure stay local and are reported with the reason. For GitLab, require `glab`
   before any push; without it, keep the changes local and mark the repository
   **not opened**, because the review requires its full body. A deferred gate or always-pause
   action stays unapplied and goes under **Needs your call**; continue other repos.
   Repositories containing no safely deliverable changes get no PR/MR.
4. **Destination gates, then exact commit.** Read each destination's `CLAUDE.md` and
   `AGENTS.md` and run its documented commit gates on the isolated result. Run every
   gate from the delivery worktree. In this marketplace repo, run `/prune-instructions`
   explicitly as an unattended/headless caller: apply SAFE fixes only and return CONFIRM
   findings unapplied under **Needs your call**, without prompting. Add the gate's own
   edits to the owned paths in `evidence/delivery.json`, then run
   `scripts/verify-plugin-edits <plugin>` for every changed plugin and `--root` when required.
   Never bypass a required gate; if a gate fails or cannot complete unattended, keep the
   affected changes local and report why. Stage exact owned paths only, inspect the staged
   diff, and commit only the retro's changes. Persist the branch and commit before pushing.
5. **Body check, then open.** Read [retrospective/pr-body.md](retrospective/pr-body.md)
   and fill its template from `evidence/synthesis.md` and the Done review. Save each
   repository's title, body file, check output and outcome in `evidence/delivery.json`.
   Run `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/retro-pr-body-check.sh" <body-file>`
   until it passes; without the helper, perform and record the same checks explicitly.
   Fix only the body, never weaken the check. Use shipping's
   [open-pr.md](../../../shipping/references/open-pr.md) with explicit repository root,
   branch, base, title and body file. Confirm the open PR/MR and its URL via `gh`/`glab`;
   a push or compare URL alone is **not opened** and is reported with the local changes.
6. **Sibling links.** Open all repositories' PRs/MRs first, then rewrite each body
   locally so **Not in this PR** links the others, or names the sibling repository
   and branch when linking is unavailable. Run `retro-pr-body-check.sh` on the
   rewritten file and upload it with `gh pr edit --body-file` or the `glab` equivalent
   only when it passes, so no unchecked body reaches the remote; on failure leave the
   remote body unchanged and report the retained check result.
7. **Resume and report.** Review outcomes are **opened** (an open PR/MR confirmed
   through the host) or **not opened** (none confirmed); **kept local** describes
   retained changes, including outside-git and no-remote destinations. Persist
   each root, baseline, owned paths, delivery worktree,
   branch, commit, PR URL, body file and outcome/reason in `evidence/delivery.json` as
   each becomes known. On restart, inspect that record and query an existing PR/MR by
   branch before creating anything; reuse the confirmed review instead of opening a
   duplicate. Complete the Done review with PR URLs, kept-local paths/reasons, Backlog,
   constitution, core-concept and other-tool proposals. With zero applied changes,
   open no PR and report the Done review in chat.

The run is `done` when **2. Definition of done (Goal check and `Done when:`)** passes
its final independent grade and the Done review reports every kept-local change and proposal.

### 5. Evidence kinds (the Done review)

Per Accepted row, prefer: `quick_validate.py` output; the trigger check on the
motivating prompt; `readlink` / `readlink -f` of each new skill's symlink, when its
destination has one; and the Coverage table in `evidence/synthesis.md` showing every node and
epoch `read`, `opaque` (with its `opaque_reason`), or `skipped` with a reason.

Also retain the final body-check result and the confirmed PR/MR URL per repository,
or its kept-local reason, from `evidence/delivery.json`.

### 6. Run rules (the run)

After the step and Verification-topic grades, complete Deliver mode and update the
Done review before dispatching the final Goal-check verifier; the predicate requires
confirmed PRs/MRs. Keep the plan `in_progress` until that final independent grade passes.

## Where outputs land

- **New skills follow the workspace's documented skill-storage convention** (its
  `CLAUDE.md` / `AGENTS.md`), e.g. `.claude/skills/<name>` plus a **relative**
  `.codex/skills/<name>` symlink pointing at it. With none documented, write
  `.claude/skills/<name>` on Claude Code. On Codex, or when a Codex copy is wanted, a
  project-skill path is not promised: report it as a Leftover with the path to verify.
- **Installed plugin skills are copied to the workspace and the copy is edited** —
  never edit a plugin cache in place.
- Inside this marketplace repo, edit `plugins/*/skills/` directly, under the repo gates.
