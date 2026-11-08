Overlay a mentor plan run loads when the requested goal is a change to a repository's
code, tests, config, dependencies or CI, such as a bug fix or feature. It supplies
research, checks, always-pause items, delivery and evidence; it never plans or
approves independently. Use the retrospective playbook for lessons from a finished
session, and shipping or merging directly for a standalone delivery request.

# Playbook — software change

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Mentor's main workflow (`planning`) is general-purpose and never names git, tests,
CI, or pull requests. This playbook is where those live. Planning loads it when the
goal is a code change, records `## Playbook: software-change` plus a
decision-log row, and reads the five overlays below at the points it names. Nothing
here replaces a planning rule; each overlay only fills a slot the general flow leaves
open.

## 1. Research directives (planning Step 2)

Before planning completes the plan, find and cite with `file:line`:

- **Callers and dependents** of every function, type, endpoint, or config key the
  change touches — the set a reviewer will ask about first.
- **Existing tests** that cover the area, and the **check commands** the repo itself
  uses: test, typecheck, lint, build (`package.json` scripts, `Makefile`, CI config,
  `CONTRIBUTING`). Run each once now and record the result as an experiment row —
  a pre-existing failure found here is a scope decision, not a surprise at the end.
- **The base branch** and whether it is protected, from the remote's settings or the
  repo's docs.

## 2. Definition of done (Goal check and `Done when:`)

- **Goal check**: the repo's own check command(s) pass on the final tree, plus one
  behavioural check per use case scenario (a test that fails before and passes after,
  or a command whose output shows the new behaviour). Include the before/after
  `git rev-parse HEAD` and `git status --porcelain --untracked-files=all` proof below
  for the final-tree checks and any reused output. Name the exact commands.
- **`Done when:`** per step: the bounded check that proves that step — a targeted test,
  a typecheck, a build. End-to-end proof of a running multi-service stack belongs in a
  `## Verification` topic, not a step.
- **Reuse proof**: apply [the verifier contract](../verifier-contract.md) → **Evidence reuse**.
  Record the full `git rev-parse HEAD` and `git status --porcelain --untracked-files=all`
  before and after each check, and repeat this proof when reusing output. All HEADs
  must match and every status must be empty for reuse; an unchanged HEAD alone hides
  tracked or untracked edits.
- **Command hygiene**: a `git diff`/`git log` against a path puts `--` before the path
  (`git log <range> -- <path>`) — without it, a path that later collides with a revision
  name fails the check.
- A constitution's Definition of done, when present, wins over these defaults.

## 3. Extra always-pause items (the run)

Added to the constitution's list or the built-in default (a union — nothing here
removes an item):

- Force-push, or any push to the base branch or a protected branch
- Merging a pull request into a shared branch
- Database migrations that drop or rewrite data, or cannot be rolled back
- Changing CI secrets, deploy config, or release tags
- A working tree with changes the run cannot attribute to the plan

Everything else — creating a feature branch, committing, pushing that branch, opening
a pull request, re-running a flaky check — is reversible and proceeds without asking.

## 4. Deliver mode (the run's deliver state)

Replaces planning's general deliver state, in this order:

1. `Skill(skill="mentor:shipping")` — its **Standalone vs inside a plan run** section
   governs what it asks and what goes in the PR body.
2. `Skill(skill="mentor:merging")` grades the PR (Step 3.5). Under a merge grant it
   merges; otherwise its merge question is the run's hand-over (Step 4). Then it walks
   the runbook's **After merge** steps (Step 6).

The run is `done` when the PR is open and graded (or merged, under a merge grant).

## 5. Evidence kinds (the Done review)

Record a per-check evidence bundle in every verdict: §2's before/after HEAD and
status proof; command, cwd, exit code and output; tool, dependency and config inputs;
verifier identity; and the source verdict path and check citation (`none` for fresh
output). Preserve the source bundle when reusing, label its output reused, and add
the current verifier's identity and proof that command and cwd match the source
verdict and inputs are unchanged. This lets the next stage check provenance without
trusting a prior PASS.

Per use case scenario, prefer in this order:

- the test or command output that shows the behaviour, as a short inline excerpt;
- the CI run link for the PR's checks — added to the PR body at delivery, since the Done
  review is written before the PR exists;
- `git diff --stat` for the scope of the change;
- a screenshot under `.mentor/plans/<slug>/evidence/` for a visible UI change, cited as
  `local: …` (the folder is gitignored);
- `evidence: not capturable on this host, verify by <command>` when none of these is
  possible.

The **runbook** part of the Done review is required when the change ships a migration,
a feature-flag flip, a config or secret change, or a deploy: numbered **Before merge**,
**Merge**, **After merge**, and **Rollback** steps. Otherwise it reads
`Runbook: n/a, merge is self-contained`.
