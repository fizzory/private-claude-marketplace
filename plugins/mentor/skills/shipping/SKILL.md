---
name: shipping
description: Finish the current branch — clean-check, run /simplify, run tests, then push and open a PR/MR (or push to the branch's upstream), with the plan's Done review in the PR body. Standalone it asks for the test step and the target; inside a mentor plan run (the software playbook's deliver mode) it proceeds without asking and pauses only on always-pause items. Never force-pushes; never pushes to a protected branch without an explicit choice. Invoked by /mentor:ship, "ship this", "merge and push", "finish and ship", and by planning's software-change playbook.
---

# ship — Ship the current branch

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Drives clean-check → `/simplify` → tests → **ship target** for the branch currently
checked out. No worktree machinery — the flow operates on `$PWD`'s repo and branch.

## Standalone vs inside a plan run {#plan-run}

Ship runs in one of two modes. This section is the whole plan-run contract; the steps
below are written for standalone ship, and a step marked `(plan run: #plan-run)` is
replaced by the bullet here:

- **Standalone** (`/mentor:ship` with no plan run active): the human chose to ship by
  hand, so Steps 4 and 5 ask, exactly as written.
- **Inside a plan run** — the [software-change playbook](../planning/references/playbooks/software-change.md)'s deliver mode called this skill
  for an approved plan whose stored state is `in_progress`. The approval was the human's
  one gate (AGENTS.md → Mentor core concept), so:
  - **Step 1 on-base:** cut the feature branch `git switch -c <type>/<slug>` without
    asking (local, reversible) and log it. An open PR on this branch that is **not**
    this run's work is always-pause: stop and ask.
  - **Step 2 dirty tree:** a dirty path the plan's steps account for is committed with
    the step's message; a path the run cannot attribute is always-pause — stop and ask.
  - **Step 3 out-of-scope files** from simplify: include in-scope only, log the rest as
    a `review?: needed` row. Never "include all" without a human.
  - **Step 4 tests:** no question. Run the plan's Definition of done commands (the
    playbook's overlay, the constitution, or the Step 4 ladder), or apply
    `planning/references/verifier-contract.md` → **Evidence reuse**, rechecking
    eligibility after `/simplify`. A failure **stops the ship** — there is no "Ship
    anyway" inside a run; it re-enters the run's re-plan path.
  - **Step 5 target:** no question. **5A** (push the feature branch + open the PR/MR).
    Push to the base or a protected branch is always-pause.
  - **PR body:** the plan's `## Done review` plus the decision log grouped by use case,
    `review?: needed` rows first (5A → **PR body under a plan run**).
  - **Step 6:** leave the plan state to the run, which closes it after merging's grade
    (planning → After Proceed).
  - **Step 7:** the test-command save offer becomes a decision-log row, then hand back
    to the playbook, which invokes `merging` next.
  - Append a decision-log row for every choice made here.

Every rule below still applies in both modes except where a bullet above replaces it —
its questions, Step 1's on-base ask, and Step 2's abort, which inside a run commits the
plan-attributed paths instead (Step 2's block still exits 1 on a dirty tree: commit them,
then re-run it). Failure-mode rows that ask (on-base, push rejected) follow the same
overrides.

## Step 1 — Context & summary

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
[ "$branch" = "HEAD" ] && { echo "ERROR: detached HEAD — check out a branch first." >&2; exit 1; }

# Base = the branch's upstream if set, else origin's default branch.
base="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null | sed 's#^origin/##')"
if [ -z "$base" ] || [ "$base" = "$branch" ]; then
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
fi

# branch == base: no PR/MR can open (a branch cannot target itself) and every push here
# lands on the protected branch. Ask before Step 2 — never fall through to Step 5.
# An `if` block, not `[ … ] && echo`: as the block's last command the latter exits 1 on
# every normal ship, which reads as a failed step.
if [ "$branch" = "$base" ]; then
  echo "ON-BASE: $branch is this repo's default/integration branch"
fi
```

Render to the user: the branch, the base, and
`git -C "$repo_root" diff "origin/${base}"...HEAD --stat` (fall back to the
local `$base` if the remote ref is absent).

**Every question stands on its own** — this gate and every other one in this skill. The
user answers from the question screen alone, never sent to a file, a plan section, a
coined id or code, or an earlier turn to learn what the question means: name the branch,
base, and PR in the option itself, and say what each choice pushes and where.

**On the base branch.** If the block printed `ON-BASE`, standalone ship stops and asks
via `AskUserQuestion` before Step 2 (plan run: #plan-run):

- **Cut a feature branch from here and re-invoke (Recommended)** —
  `git switch -c <type>/<slug>`. Branch now, not later: Step 3 commits to
  whatever is checked out, so deferring means undoing a `chore(simplify)`
  commit on `<base>`.
- **Ship from `<branch>` anyway** — pushes straight to `origin/<branch>`, no
  PR/MR, no review. This binds Step 5: skip its question and go to **5B**.

5A is never offered here — `-o merge_request.target="$base"` from `$base` is a
self-targeting MR (GitLab answers `WARNINGS:` and opens nothing) and
`gh pr create --base X --head X` fails, both *after* the push has already landed
on the protected branch.

**`repo_root`, `branch` and `base` do not survive to the next step.** Every step below
is a separate Bash call, so re-run the block above at the top of any step that uses them.
This is not bookkeeping pedantry: `git -C ""` silently falls back to cwd, so an unset
`repo_root` looks like it worked, while an unset `base` turns `origin/${base}...HEAD` into
a fatal `ambiguous argument` — which reads downstream as "the feature touched no files"
and makes every file look out-of-scope.

**Branch-ownership check** (GitHub + `gh` only — skip silently when `gh` is
absent, the remote isn't GitHub, or the call fails; never block on it):

```bash
# Re-derive: Step 1's block was a separate Bash call and its variables are gone. An empty
# $branch would make `gh pr list --head ""` match EVERY open PR in the repo — a false alarm
# that stops a legitimate ship while never checking this branch at all.
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
command -v gh >/dev/null && git remote get-url origin 2>/dev/null | grep -qi github && \
  (cd "$repo_root" && gh pr list --head "$branch" --state open \
     --json number,title,url 2>/dev/null) || true
```

If an open PR already exists for this branch, show it and ask via
`AskUserQuestion` whether that PR is **this session's work** (pushing more
commits onto your own PR is normal — continue) or **unrelated** (stop: shipping
would inject these commits into someone else's PR; recommend cutting a fresh
branch from `$base` and cherry-picking). Catching this here is cheap; catching
it after the push means a cherry-pick/branch-reset recovery.

## Step 2 — Pre-flight clean check

```bash
# Re-derive: every Step here is a separate Bash call, so Step 1's variables are gone.
# `git -C ""` silently falls back to cwd, so an unset $repo_root looks fine and isn't.
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[ -n "$base" ] || base="$branch"

# --untracked-files=no on purpose: untracked files cannot be pushed, so they cannot reach
# the PR — blocking on them protects nothing, while permanently bricking ship in any repo
# that keeps local artifacts around (a tool's .temp/, .venv, a cache dir). This gate still
# blocks staged adds and unmerged paths; the exemption is narrowly "never `git add`ed".
dirty="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
[ -n "$dirty" ] && {
  printf '%s\n' "$dirty" >&2   # name them; else the user re-runs status
  echo "Working tree has uncommitted changes. Commit or stash them, then re-invoke /mentor:ship." >&2

  # A marketplace repo publishes a plugin through its own release flow, not through ship,
  # and "the implementation just finished, nothing committed yet" is exactly the moment
  # ship gets invoked — so this has to look at the DIRTY tree, not a committed range. When
  # every dirty path under plugins/ names the same plugin (paths outside plugins/ don't
  # disqualify this — publish-plugin stages only plugins/<name>/, so it ignores them same
  # as ship would), that plugin is very likely what the user actually wants shipped, and
  # /loom:publish-plugin already commits + bumps + pushes it in one pass. ship still aborts
  # here either way — this only changes what the abort tells the user to do next, never
  # what ship does itself. Scoped to branch == base: publish-plugin pushes to the repo's
  # default branch, so the redirect is wrong advice from a feature branch.
  if [ -f "$repo_root/.claude-plugin/marketplace.json" ] && [ "$branch" = "$base" ]; then
    plugin="$(printf '%s\n' "$dirty" | sed -n 's#^.. plugins/\([^/]*\)/.*#\1#p' | sort -u)"
    [ "$(printf '%s\n' "$plugin" | grep -c .)" = 1 ] &&
      echo "This is a change to plugins/$plugin/ — /loom:publish-plugin commits, bumps and pushes it in one pass; that may be the better fit than a manual commit here." >&2
  fi
  exit 1
}

# Untracked paths are REPORTED, never staged, never blocking. Persist this listing — Step 3
# is a separate Bash call and needs it as the baseline for telling simplify's new files from
# pre-existing local junk. A deterministic /tmp path, not `.mentor/`: that tree's own
# gitignore only allowlists `config.json`/`constitution.md`, and a repo that has never used
# mentor's planning surface may have no `.mentor/` at all — writing there would create it as
# a side effect of a plain ship. Truncate unconditionally: a stale baseline left over from an
# earlier, unrelated ship run must never leak into this one.
baseline="${TMPDIR:-/tmp}/mentor-ship-untracked-$(printf '%s' "$repo_root" | cksum | cut -d' ' -f1)"
git -C "$repo_root" ls-files --others --exclude-standard | tee "$baseline"
```

One exception worth a question: if an untracked path sits under a directory that also
appears in `git diff --name-only "origin/${base}"...HEAD`, that is the "forgot to
`git add` the new module" case — the only untracked state that can actually break the PR.
Ask via `AskUserQuestion` before continuing (plan run: still asks — always-pause, an
unattributable working-tree change; playbook §3). Otherwise say what you saw and move on;
never `git add` an untracked path to satisfy this step.

**Abort means abort (standalone).** (plan run: #plan-run)
Never branch, stage, commit, or stash on the user's behalf
to get past this gate — the exit belongs to the user, and a hand-sorted commit
ship invented is the one commit it must never author. **This is not Step 3's
territory below** — Step 3's auto-commit-without-prompting is scoped narrowly to
files `simplify` itself just created in this same turn; it never licenses
committing whatever Step 2 finds dirty here, however similar the shape looks. A
dirty tree at this gate is work this skill cannot classify — it did not watch it
being made, and only the user knows whether it belongs in this ship.

## Step 3 — Run `/simplify`

Invoke `Skill(skill="simplify")` **in this thread** (a Claude Code built-in; if
unavailable, do a quick review of the branch diff yourself instead). It fans out its own
review agents: while they run, do not wait on them by hand — end the turn and let the
harness re-invoke you when they report. A `Bash true` poll burns a whole turn and returns
nothing.

That fallback is for simplify being **unavailable**, not for skipping it. If a standing
instruction in this environment seems to block simplify's own review agents, ask the user
once, in one line, whether to let simplify run (plan run: do not ask — do the solo diff
review and log a row). Either way, a solo diff review is reported
**as** a solo diff review — reporting the substitute as though this step ran turns a
judgment call into a false green.

Keep the /simplify call in-thread: a wrapping `Agent` delegate commits its own result and
returns 'done', so the clean check, out-of-scope question and Step 4/5 gates never run.
(why: `references/rationale.md` → **Step 3 — why /simplify stays in-thread**)

After it returns:

1. **Re-run the clean check** — simplify may have edited files. Step 2's
   `--untracked-files=no` exemption is for the **blocking gate only**; untracked files
   belong in the comparison here, because simplify can create them.
2. Then, if anything is dirty:

   ```bash
   # Re-derive: separate Bash call again — see Step 2.
   repo_root="$(git rev-parse --show-toplevel)"
   base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
   [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
   feature_files="$(git -C "$repo_root" diff --name-only "origin/${base}...HEAD" | sort -u)"
   # Braces + the pipe INSIDE the substitution. `v=$(a; b) | sort -u` pipes the
   # assignment's stdout to sort and runs the whole thing in a subshell, so v is
   # never set in this shell at all — the comparison below then silently sees nothing.
   tracked_diff="$(git -C "$repo_root" diff --name-only HEAD | sort -u)"

   # Subtract Step 2's baseline from the untracked side only — tracked_diff can't contain
   # a pre-existing file (it was never dirty against HEAD to begin with). Same deterministic
   # path as Step 2's write; a missing baseline (Step 2 didn't run this turn) fails OPEN with
   # a warning rather than silently trusting a stale one from an earlier ship — reusing a
   # stale baseline would hide genuinely new untracked files, the opposite and worse failure.
   baseline="${TMPDIR:-/tmp}/mentor-ship-untracked-$(printf '%s' "$repo_root" | cksum | cut -d' ' -f1)"
   if [ -f "$baseline" ]; then
     new_untracked="$(comm -13 <(sort -u "$baseline") <(git -C "$repo_root" ls-files --others --exclude-standard | sort -u))"
   else
     echo "WARNING: no Step 2 baseline found — treating every untracked file as new." >&2
     new_untracked="$(git -C "$repo_root" ls-files --others --exclude-standard | sort -u)"
   fi
   simplify_files="$(printf '%s\n%s\n' "$tracked_diff" "$new_untracked" | sort -u)"
   ```

   Only untracked paths that were **not** already in Step 2's baseline are simplify's
   output. Pre-existing local junk must never reach the "include all" option — that is how
   a directory nobody meant to commit gets committed. Use the same
   `ls-files --others --exclude-standard` in both places; `git status --porcelain` collapses
   a directory to `?? dir/` while `ls-files` enumerates the files inside it, so mixing the
   two makes the difference meaningless.
   - If every dirty file is in the feature scope: **auto-commit without
     prompting** — `chore(simplify): refactor before ship` — and surface
     `git diff HEAD~1 --stat` in the ship summary.
   - If any file is OUTSIDE the scope: show the list and ask via
     `AskUserQuestion`: include in-scope only (Recommended) / include all / abort.
     (plan run: #plan-run)

**Re-entry.** simplify runs its own numbered steps and its own agents, and it runs
long — dozens of tool calls, all of them someone else's flow. When it returns you are
back in **this** skill at Step 4. This is the seam where ship's tail gets dropped:
the next action is Step 4's question, never a `git add`/`git commit`/`git push` you
compose yourself. Standalone, Steps 4 and 5 are both `AskUserQuestion` gates; skipping
them means the user never chose whether to test, and never chose where the branch goes.
(plan run: #plan-run)

## Step 4 — Conditional test step

**Standalone: ask this together with Step 5's ship target, in ONE `AskUserQuestion`
call carrying both questions.** (plan run: #plan-run) They are independent — whether to run tests does not change where the
branch goes — and both must be answered before the push either way, so splitting them
into two calls costs a round trip and buys nothing. Resolve the test command first (the
ladder below), because the question has to name the command that will actually run.

Question 1: "Run the test suite before shipping?" — Yes (Recommended) / No.
Question 2 is Step 5's, verbatim from the JSON there.

Two cases still ask separately, and both are about the answer arriving too late to be
useful: when `branch` = `base`, Step 1's on-base question already bound the target, so
only the test question remains; and when the test run **fails**, its follow-up ("Stop
and fix / Ship anyway") has to come after the failure, which no combined call can
anticipate. In that second case, a target answer already collected stays valid — do not
re-ask it.

**Per-repo override first** — auto-detect guesses wrong in monorepos (a root
`npm test` can proxy to an unrelated workspace), so an explicit setting always
wins:

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
jq -r '.test_command // empty' "$repo_root/.mentor/config.json" 2>/dev/null
```

Non-empty → use it verbatim and say so. Otherwise **auto-detect from the repo
root:**

| Match | Command |
|---|---|
| `package.json` with `scripts.test` | `npm test` |
| `pyproject.toml` declaring pytest OR `pytest.ini` | `pytest` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test:` target | `make test` |

Pick the first match and tell the user which command will run, adding the hint
`(override with "test_command" in .mentor/config.json)` so the key is
discoverable where the misfire happens. If none match, ask the user for a
command (plan run: #plan-run — no question; log the missing command as a row)
(explicit empty input = skip) — and keep that answer, because **Step 7
offers to save it**. A repo with no `package.json`, no pytest, no `go.mod` and no
`Makefile` test target will miss the table on every future ship too, so the branch
that costs the user a question is the one branch that currently learns nothing.

Before asking, grep the repo's own docs under `$repo_root` — `CLAUDE.md`,
`AGENTS.md`, and any `.claude/rules/*.md` — for a stated test/check command; a
repo that misses the table above often still writes its command in prose.
Surface a hit as a candidate, naming the file it came from, and let the user
confirm or replace it before running anything — the table's matches are
mechanical, prose is not. A confirmed hit counts as hand-supplied for **Step
7**: it still gets the `test_command` save offer, so the next ship in this repo
reads the config instead of re-deriving it from prose.

Run it inside a subshell, re-deriving `repo_root` in that same Bash call:

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
(cd "$repo_root" && <the resolved command>)
```

Monorepo test commands routinely start with their own `cd` into a workspace, and cwd
persists across Bash calls — so a bare `cd apps/web && npm run test:e2e` leaves every
later block running one directory down, where `git add CLAUDE.md` fails with `pathspec
did not match any files`. The parentheses confine the move to the test run.

On failure, standalone ship asks: "Tests failed. What now?" — Stop and fix (default,
exit 1) / Ship anyway. (plan run: #plan-run)

## Step 5 — Choose the ship target (mandatory)

Standalone, both answers must exist before any `git push`: Step 4's test answer and
this step's target answer. Step 4 issues them as one call carrying both questions; the two-call
form is still valid (and is what the exceptions there fall back to). Either way, if you
cannot point at both answers in this transcript, you skipped a step — ask now. Prose selects no option: "ship it",
"lgtm", "ok all pass, let's ship and deploy" answer neither question, however much
they sound like a go-ahead. Everything up to here is local and reversible; the push
is not. (plan run: #plan-run)

Standalone, the human picks the target. Substitute real values before emitting the call:

```json
{
  "question": "Where should '<branch>' go? It adds <ahead> commit(s) on top of <base>.",
  "header": "Ship target",
  "options": [
    { "label": "Push + open PR/MR (Recommended)",
      "description": "Push '<branch>' to origin/<branch> and automatically open a PR/MR into <base>. The remote <base> is never touched." },
    { "label": "Push to upstream",
      "description": "Push '<branch>' to its upstream (origin/<branch>) with no PR/MR. Use when the branch IS the integration branch." }
  ]
}
```

(`ahead` = `git rev-list --count "origin/${base}..${branch}"`, falling back to
the local base ref.)

**Not asked when `branch` = `base`** — Step 1's on-base question already chose;
go straight to 5B. (That is the case where Step 4's combined call carries only the
test question.)

### 5A — Push + open PR/MR

Detect the host from `git remote get-url origin`:

- **GitLab** (URL contains `gitlab` or your self-hosted GitLab host) — fold MR
  creation into the push (idempotent — an existing open MR is reused):
  ```bash
  # Re-derive: separate Bash call, so Step 1/2's vars are gone. Pushing with an empty
  # $branch or $base targets the wrong ref — re-derive before every push, without exception.
  repo_root="$(git rev-parse --show-toplevel)"
  branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  # Same fallback Steps 2/3 carry. Without it an unset origin/HEAD (any remote added with
  # `git remote add` rather than cloned) pushes -o merge_request.target="" — which fails
  # AFTER the push has already landed.
  [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"

  # Title mirrors the GitHub path's `--fill`: the commit subject only when the branch is a
  # single commit. Unconditional `log -1` would title multi-commit MRs with Step 3's
  # auto-created `chore(simplify)` commit — worse than the slug. Fail-soft: a missing
  # origin/$base makes rev-list error, the count is empty, and title stays "$branch".
  title="$branch"
  [ "$(git -C "$repo_root" rev-list --count "origin/${base}..HEAD" 2>/dev/null)" = "1" ] &&
    title="$(git -C "$repo_root" log -1 --format=%s)"

  git -C "$repo_root" push -u origin "$branch" \
    -o merge_request.create \
    -o merge_request.target="$base" \
    -o merge_request.remove_source_branch \
    -o merge_request.title="$title" 2>&1 | tee /tmp/ship-push.out
  ```
  Surface the MR URL (grep for `/-/merge_requests/`) together with the target
  it named (`$base`) — the one piece of "did this land where I meant?" nothing
  else in this block confirms. If a `WARNINGS:` block names `merge_request.target`,
  the target is invalid — the MR did NOT open; re-resolve the base (ask the user;
  plan run: re-resolve from `origin/HEAD` without asking and log a row) and retry. An already-open-MR warning is fine **when the MR is this branch's
  own work** — print its URL and its target, since this path reused an existing
  MR whose target these push options never touched. (An MR opened by someone
  else is the Step 1 ownership case; if Step 1 was skipped — no `gh` on a
  GitLab remote — check the MR author/title before shrugging it off.)

- **GitHub** — push, then open the PR with `gh` (run inside the repo):
  ```bash
  # Re-derive (separate Bash call again — see 5A's GitLab block).
  repo_root="$(git rev-parse --show-toplevel)"
  branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"   # see the GitLab block
  git -C "$repo_root" push -u origin "$branch"
  (cd "$repo_root" && gh pr create --base "$base" --head "$branch" --fill)
  ```
  If `gh` is absent, print the compare URL instead.

- **Other host** — push, then print the compare URL for manual PR creation.

**PR body under a plan run.** Write the body to a temp file first: the plan's
`## Done review` (per scenario: expected, observed, evidence; the runbook or
`Runbook: n/a, merge is self-contained`; leftovers), then the decision log grouped by use
case with `review?: needed` rows first. Evidence cited `local: .mentor/…` stays a local
path — say in the body that it is not uploaded. On GitHub use
`gh pr create --base "$base" --head "$branch" --title "<plan title>" --body-file "$body"`
instead of `--fill`; on GitLab add `-o merge_request.description="$(cat "$body")"` to the
push. A body too long for a push option is trimmed to the Done review and a pointer to
`.mentor/plans/<slug>/plan.md`.

### 5B — Push to upstream

```bash
# Re-derive (separate Bash call again — see 5A).
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
git -C "$repo_root" push -u origin "$branch"
```

**Either target:** the two rejections have opposite fixes — read which one git printed,
don't pattern-match the server's wording (it differs per host).
`! [rejected] … (non-fast-forward / fetch first)` is git's own fast-forward check: the
remote moved. Surface it and ask whether to `git pull --rebase origin "$branch"` and
retry, or stop.
`! [remote rejected]` means the *server* refused, and no rebase can change that — a
retry just re-declines. When the reason names a hook or a protected branch
(`pre-receive hook declined`, `protected branch hook declined`, `GH006`), cut a feature
branch from the current HEAD (`git switch -c <type>/<slug>`) and redo the push via
**5A**, so the work lands as a PR/MR into the protected branch. Then, if you were on
`$base`, `git branch -f "$base" "origin/$base"` — those commits now live on the feature
branch, and leaving `$base` ahead makes the next ship's `origin/$base...HEAD` diff and
ahead-count double-count them. Any other remote rejection (`cannot lock ref`, quota):
surface it and stop — never guess.
**Never force-push.**

## Step 6 — Close the plan's state (post-ship)

(plan run: #plan-run)

A successful ship means the plan's tasks are done, and a shipped plan left
`in_progress` reads as unfinished work to the next session that lists plans.
Resolve `<topic>` from what **this session actually worked on**: the plan file
it followed (`.mentor/plans/<topic>/plan.md`). If the session worked through
more than one plan, run the snippet once per topic. **If you cannot name the
topic from this session's own work, skip this step entirely — never guess**
(e.g. from the newest `plan.md` on disk: it may belong to a different,
unfinished workstream, and closing it would bury live work). Run this only
after the push actually succeeded; it never blocks the ship report.

```bash
plans_dir="$(bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" dir --plans)"
[ -n "$plans_dir" ] || { echo "ERROR: Mentor plans directory unresolved — set PLUGIN_ROOT (or use the Claude compatibility fallback) or derive the repository .mentor directory" >&2; exit 1; }
if [ -d "$plans_dir/<topic>" ]; then
  stored="$(jq -r '.state // ""' "$plans_dir/<topic>/.state.json" 2>/dev/null)"
  case "$stored" in
    implemented|superseded) echo "<topic> is already $stored — left as is." ;;
    *) bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" set <topic> implemented ;;
  esac
fi
```

Guard on the directory rather than letting it fail: `set` exits 1 with "No such
plan" when the plans dir exists but the slug doesn't — a topic that never got a
`plan.md`. Don't invent a slug to satisfy it.
`set implemented` replaces the note, which clears any stale failure reason; `set` has no
downgrade guard, so read the state first and skip a plan already `superseded` (a split
parent) or `implemented`.

## Step 7 — Point at the merge tail, and stop

(plan run: #plan-run)

**Stop here.** Ship's job ends at the open PR/MR. Emit one line in the ship report naming
where the tail lives: **GitHub + `gh`** → `Watch CI and merge with /mentor:merge`;
**any other host** — GitLab included, self-hosted GitLab very much included, since
`/mentor:merge` is scoped to GitHub via `gh` rather than to any particular domain →
`Watch the pipeline and merge at <URL>`, reusing the URL 5A already surfaced.
Say plainly that the tail is manual on this host, so the user is choosing to finish
in the web UI rather than wondering which mentor command they missed.
Keeping the tail in `/mentor:merge` is what makes it re-enterable after a stalled CI run
without re-running ship.

**Do this before anything else in this step: offer to save a hand-supplied test
command.** Placed first on purpose — buried after the marketplace and
deploy-artifact checks below, this offer is easy to reach the end of Step 7
having mentally already closed out ("pushed successfully") and simply never
run. If Step 4 had to ask the user for a command (the table missed) **and that
command passed**, offer here to record it as `test_command`, so the next ship
in this repo reads it instead of asking again. Only a command that actually
passed is worth saving — Step 4 uses a configured value verbatim, so persisting
a broken one hands the next ship a bad default it will trust.

Save it here, after the push, never at Step 4: `.mentor/config.json` is committed, so an
earlier write would leave the tree dirty at push time and trip the next ship's clean gate.
Say plainly in the offer that this file is committed and ship will not commit it for them.
(why: `references/rationale.md` → **Step 7 — why the test command is saved after the push**)

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
state_dir="$repo_root/.mentor"; config="$state_dir/config.json"
mkdir -p -m 700 "$state_dir"
if [ -f "$config" ]; then
  tmp="$(mktemp "${state_dir}/.config.XXXXXX")"
  jq --arg c "<the command that passed>" '.test_command = $c' "$config" > "$tmp" && mv "$tmp" "$config"
else
  jq -n --arg c "<the command that passed>" '{test_command: $c}' > "$config"
fi
```

Keep the merge in place through a temp file, so every other key survives and a `jq`
failure leaves the original untouched. On the create branch, run `mentor_ensure_gitignore`
(or create the config only in a repo that already planned), so `plans/` and `reviews/`
never become committable.
(why: `references/rationale.md` → **Step 7 — how the config.json merge works**)

**Marketplace repos: say whether the plugin is released.** When `$repo_root` holds a
`.claude-plugin/marketplace.json`, shipping the branch and publishing the plugin are two
different acts and only the first one just happened. Add one report line per plugin whose
committed work sits ahead of its last manifest bump — that work is on the branch, in no
release. Naming it here is what keeps "was this published?" from being asked three turns
later and re-derived by hand from `git`, `plugin.json` and `marketplace.json`.

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
if [ -f "$repo_root/.claude-plugin/marketplace.json" ]; then
  for pj in "$repo_root"/plugins/*/.claude-plugin/plugin.json; do
    [ -f "$pj" ] || continue
    name="$(basename "$(dirname "$(dirname "$pj")")")"
    # The publish flow's bump commit is the last thing to touch this manifest, so it IS the
    # release marker: anything committed under the plugin after it is shipped-but-unreleased.
    bump="$(git -C "$repo_root" log -1 --format=%H -- "plugins/$name/.claude-plugin/plugin.json")"
    [ -n "$bump" ] || continue
    if [ -n "$(git -C "$repo_root" log --format=%H "$bump..HEAD" -- "plugins/$name/")" ]; then
      echo "$name is still at $(jq -r .version "$pj") — not released; run /loom:publish-plugin"
    fi
  done
fi
```

Deliberately **no `$base` and no `A...B` range.** The case this exists for is a ship
straight to the integration branch (Step 1's `ON-BASE` → 5B), where `base` *is* `branch`,
so `"$base"...HEAD` is `HEAD...HEAD`: empty, exit 0, nothing printed, in exactly the
situation the line was added to catch. `origin/${base}...HEAD` is no better — this runs
*after* the push, which already fast-forwarded the remote-tracking ref. Anchoring on the
last manifest commit needs no range, and it also surfaces work an *earlier* ship left
unreleased, which is what the user is really asking about. Every branch here exits 0 (an
`if`, never a trailing `[ … ] && echo`) for Step 1's reason: that construct exits 1
whenever the plugin *is* released, turning the healthy path into a failed step.

**Say when the shipped diff touches a deploy artifact.** Ship's job stops at the open
PR/MR (above) — it never deploys anything — but leaving that unstated is how a user ends
up improvising a from-scratch deploy investigation after asking "anything else left?".
One report line, zero config, mirroring the marketplace check's own "detect from git,
don't ask the user to declare it" shape:

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
# The repo's default/integration branch, NOT `@{upstream}` — 5A/5B's `push -u` just set
# the current branch's own upstream to `origin/$branch`, so by the time this step runs
# `@{upstream}` always equals `$branch` and the guard below would never fire, on every ship.
base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
if [ -n "$base" ] && [ "$base" != "$branch" ]; then
  deployish="$(git -C "$repo_root" diff --name-only "$base"...HEAD -- \
    '**/supabase/functions/**' '**/fly.toml' '**/vercel.json' '**/serverless.yml' \
    '**/.github/workflows/deploy*.yml' '**/k8s/**' '**/kubernetes/**' '**/helm/**' \
    '**/terraform/**' 2>/dev/null)"
  if [ -n "$deployish" ]; then
    n="$(printf '%s\n' "$deployish" | wc -l | tr -d ' ')"
    # Name a matching project-local verification surface if this repo built one — never
    # invoke it: nothing has deployed yet at this point in ship, so there is nothing to
    # verify here. That's `/mentor:merge`'s post-merge run, or a manual check later.
    verify_surface="$( { ls "$repo_root/.claude/skills" 2>/dev/null | grep -iE 'deploy|verify'
                          ls "$repo_root/.claude/commands" 2>/dev/null | sed 's/\.md$//' | grep -iE 'deploy|verify'
                        } | sort -u | paste -sd', ' - )"
    echo "$n committed file(s) touch a deploy artifact — deploying is separate from shipping: $(printf '%s' "$deployish" | tr '\n' ' ')${verify_surface:+ (once it's live, this repo's own $verify_surface covers verification)}"
  fi
fi
```

The pattern list is intentionally hardcoded, not a `.mentor/config.json` key — an opt-in
key nobody has populated yet fires for nobody, which is exactly the gap this line exists
to close. Skipped (not just silent) on the `branch == base` on-base path, same as the
edge case named above: there is no PR-scoped range to diff there. The verification-surface
name is offered the same way the marketplace check above names `/loom:publish-plugin` —
say what exists, never run it — since this step still stops at the open PR/MR either way.

Do **not** watch checks, poll `gh run`, or `sleep` after the push — never chain sleeps or
re-checks; `/mentor:merge` owns the one bounded watch on the tail.

One case worth naming, because it is the reason this gets overridden: when the plan's own
`Done when:` requires a green CI run, that obligation is real — but it does not license
watching here. Report that `Done when:` as **outstanding on the merge tail**, naming the
run, so it is visibly unfinished rather than quietly assumed; the bounded watch that
settles it belongs to `/mentor:merge`.

## Failure modes

| Situation | What to do |
|---|---|
| Detached HEAD | Abort — check out a branch first. |
| On the default/integration branch (`branch` = `base`) | Step 1 asks first: cut a feature branch and re-invoke (recommended), or push straight to `origin/<branch>` with no PR. Never offer 5A — the PR/MR cannot open and the push lands first. |
| Dirty tree at Step 2 | Abort — the *user* commits or stashes, then re-invokes; ship never branches, stages or commits to clear it. Untracked-only is NOT dirty; report it and continue. |
| Tempted to watch CI after the push | Stop and hand to `/mentor:merge`. Never a `seq`/`sleep` poll loop — one bounded call or none. |
| Simplify edited out-of-scope files | Ask before committing. |
| Tests fail | Default: stop; branch intact for iteration. |
| A test command with its own `cd` ran unconfined | cwd persists across Bash calls, so later `git add <path>` fails with `pathspec did not match any files`. Wrap it — `(cd "$repo_root" && <cmd>)` — and re-derive `repo_root` in any block that moved. |
| Tempted to dispatch an Agent to run `/simplify` | Keep Step 3 in-thread. The delegate commits its own result and returns "done", so the clean check, the out-of-scope question, and the Step 4/5 gates all silently never run. |
| Push rejected | `! [rejected]` (non-fast-forward) → offer `pull --rebase` + retry, or stop. `! [remote rejected]` (server hook / protected branch) → rebase cannot help; cut a feature branch and redo via 5A, then realign `$base` to `origin/$base`. Never force-push. |
| `gh pr create` fails: PR already exists for this branch | Do NOT open a duplicate — print the existing PR's URL (`gh pr list --head "$branch"`) and confirm with the user it now contains what they meant to ship (Step 1's ownership answer applies). |
| MR/PR creation fails (other) | The branch is already pushed and safe — print the compare URL. |
| Shipped a marketplace repo; user asks "was it published?" | Ship pushes the branch; it never releases the plugin. Step 7's marketplace block names any plugin with commits after its last manifest bump — answer from that line, don't re-derive from `git`/`plugin.json`/`marketplace.json`. |
