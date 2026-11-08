# planning — rationale

Why the rules in `SKILL.md` are shaped the way they are: the failure each one
prevents, the mechanism behind it, and the incident that produced it.

**Read this only when you are editing `planning/SKILL.md`, or when a rule there looks
wrong and you are about to work around it.** It is deliberately not part of the skill's
own context — every one of these passages was once inline, re-read on every plan run,
to explain something that only matters when the rule itself is in question.

Each section is anchored so `SKILL.md` can point at it directly.

## Plan-file continuity — early drafts, feedback, and tracked writes

The plan-file tracking session found that research and decision-making could outlast
the context window before Step 4 created a file. The session wrote an early plan by
hand to avoid losing those findings. Step 2 now runs the reuse scan and `start` before
research, then writes a skeleton with a title, Rev 1, Context, Research notes, and the
Decision log. Findings and decisions land incrementally in that same file; Step 4
completes its approval sections. Strict `verify` still begins at Step 4 because an
intentional research skeleton does not yet have the Goal check or implementation
predicates it requires. An abandoned skeleton remains a discoverable draft, without
adding a cleanup question to the flow.

Moving the reuse scan earlier retains its ownership boundary: an obvious same-topic
draft can continue only when this worktree owns it or it is unowned. Reading its
existing plan and sidecar note preserves earlier decisions and rejection feedback;
`start` is idempotent but stamps ownership, so it is not permission to take another
worktree's slug. The stable path also gives a retrospective's Step 2 evidence an
existing plan directory before its research overlays run.

The same review found that **Keep planning** revised the file without retaining the
user's feedback. A `kept` decision-log row now records that feedback, including change
requests returned through Other. The Rev line on the answering revision identifies
the resulting content; the row explains why it changed. Both remain on disk if the
session compacts or resumes before the next approval answer.

Content hashes introduced a second continuity problem: Write/Edit hooks cannot see
shell writes, and hosts without hooks cannot observe any model write that way. A
mentor-authored PASS row would then look like an outside edit when `tick` checked
drift. Explicit `record-write` immediately after each mentor write covers every host
and write mechanism, and is harmless when a hook already recorded the same bytes.
The run therefore orders its writes as save `verdicts/step-N.md` → PASS row →
`record-write` → `tick`.

The pre-edit `drift` check and a read of changed content protect changes that arrived
since the last tracked write. Recording the hash merely to dismiss a notice would
hide those bytes without incorporating them; only an actual mentor write establishes
the new baseline. When helpers are unavailable, the skill's existing artifact fallback
still applies and reports the state action it could not perform.

## Step 0 — the armed-gate check

(The `dir` guard comes first on purpose: outside a git repo, `dir` echoes the
`_no-repo` fallback path — never one ending in `/.mentor` — so `gate`'s `RELEASED`
there is never mistaken for "not armed inside a repo"; the `case` simply has no
branch to match and prints nothing. Inside a repo, `gate` already resolves this
worktree's own marker or the legacy repo-global one, so this check needs no
`--git-common-dir`/`--show-toplevel` handling of its own.)

The equality is **strict**: only the exact `ARMED` token counts as armed for this
check. `ARMED_ELSEWHERE` — a sibling worktree's marker is live, an independent gate
that does not block this one — reads as **NOT ARMED here**, same as `STALE` or
`RELEASED`. `STALE` reading as NOT ARMED is a **deliberate flip** from the old bare
`[ -f marker ]` check: a marker file merely *existing* used to read as armed no
matter its age, but a `STALE` marker is past the self-heal window and
`plan-gate.sh` no longer enforces it — treating it as armed here would make this
check stricter than the gate it is checking.

When the gate is not armed here (an advisory host, or `STALE`/`RELEASED`/`ARMED_ELSEWHERE`),
planning continues and says plainly that no host-level edit gate is active. Sending the
user to `/mentor:plan` would loop on hosts that have no facade.

Do **not** run `begin-plan.sh` yourself to patch this up — arming the gate is the
command's job, not this skill's, and the command carries the foreign-marker handling
a bare script run would skip.

## Step 2 — why searching `.mentor/` needs `sweep`, not a grep

**`.mentor/` is gitignored — a recursive `grep` can miss it, even aimed straight at the
dir.** `hooks/lib/state.sh` writes `.mentor/.gitignore` as `*` + negations (only
`.gitignore`/`config.json`/`constitution.md` are un-ignored), so a gitignore-aware search
returns a clean "no hits" for a standing instruction — an earlier decision, a recorded
rejection — kept anywhere under `.mentor/plans/`, whether the search scans the whole repo
or `.mentor/` alone. A bare relative path is also wrong in a
linked worktree, which shares the MAIN repo's `.mentor/` (what `plan-state.sh dir`
resolves) rather than having its own.

The mechanism is the **traversal root**, not a missing flag — worth understanding, because
it decides what the fix has to be. Ignore rules apply only while **grep itself** is
walking, and a grep collects the `.gitignore` files at or below its own root without ever
walking *up*. So a search rooted at the repo root or at `.mentor/` finds nothing, while
one rooted at `.mentor/plans/` happens to work — which is exactly why the command that
used to sit here *looked* fine. It is also not a quirk of one machine's toolchain: the
Bash tool's shell carries a `grep` **function** routing to Claude Code's own bundled ugrep
with `--ignore-files` already on, so `grep -r` over `.mentor/` returns a clean zero here
whatever greps are installed — and since that function is not on `PATH`, a check launched
as `bash foo.sh` gets a *different*, ignore-blind `grep` and appears to work. Never
conclude from "it worked in my test script" that it works where this is prescribed. Reaching for a "no ignore" flag is the wrong fix twice
over: those spellings differ per implementation (ugrep rejects the GNU one outright with
exit 2), so a flag only moves the failure to someone else's machine. Hand grep an explicit
file list instead — `find` walks, `grep` only reads — which is what `sweep` does, worktree
resolution included.

## Step 4 — why verify is one call

A session was observed hand-rebuilding a different grep/awk one-liner for these checks on 5
consecutive revisions, never the same check twice, and the one revision that dropped the
table half is exactly where a table-adjacent defect landed. One helper call runs the same
checks every time. v6.0.0 added the fourth — a new plan must carry `## Goal check` and
`## Decision log` — because a plan without a done predicate gives the run nothing to stop
on, and a plan without a log leaves the human nothing to review afterwards. Legacy plans
already past `draft` are skipped, so released data keeps verifying.

## Step 6 — why the approval message is a pointer, not the plan

A plan already lives at `.mentor/plans/<slug>/plan.md`; pasting it verbatim at approval
adds a second complete copy to the conversation. Real plans run 160–400 lines, so the
`Write` payload plus the paste costs about two copies of the plan per approval turn,
plus one more paste per re-ask. Rewriting the whole file for small revisions adds
another full payload. Whole-section edits and the short pointer card keep the file
current without repeatedly carrying its full body through chat.

The card links to the absolute path because a session can move into a subdirectory.
The question repeats the repo-relative path and newest Rev because the question dialog
may be the only thing visible. An appended Rev changelog identifies the exact content
being approved and supplies the re-ask's change note for content revisions (not step ticks,
run-time log rows, or research notes and decision rows appended during Steps 2–3).

Auto-opening the file is only a convenience: remote users, phones, hosts without an
opener, and users who disable it still need a way to read the plan. `show plan` in
Other prints it once and re-asks the same question, preserving the existing three
options and leaving approval explicit. The Done review and grouped decision log can
be another large chat dump, so they stay in the file while the terminal verdict gives
counts and its path. A playbook that delivers the review in a PR body still does so,
because the PR is the deliverable.

## Step 6 — why there is one gate and three options

The approval is the only point where the human must answer (AGENTS.md → Mentor core
concept). *Proceed* starts the run; *Deliver plan only* is the one way to release the gate
without starting work; *Keep planning* stays a button because a listed option is one the
user recognizes on sight. Everything else — a change request, a plan-quality ask — rides
in "Other", and the question text names
them, because an option with no button is invisible unless something says it exists.

v6.0.0 removed the split row along with the split skill: an
oversized plan now moves isolated deliverables to `## Out of scope`, which needs no extra
machinery and keeps every plan approvable in one look.

Before v6.0.0 a fresh grep re-read the option table, because a conditional row was once
rebuilt wrongly from memory late in a session; with one fixed row there is nothing to
select.

## After Proceed — why the run keeps going on its own

Before v6.0.0 the main thread stopped after every phase and offered the next command by
name, so an overnight task needed a human at each boundary. The run now ends only at a
terminal state. Three things keep that safe: the Always-pause list stops anything
irreversible or outward-facing; an independent verifier grades every step so the builder
cannot declare victory; and the decision log records every choice so the human reviews it
afterwards instead of during. The re-plan limits (one per step, three per run) and the Stop
hook's idle cap exist so a dead end ends as `failed` with a report rather than an endless
loop — v2.37's hand-rolled re-poll ladder is the failure mode this design avoids by using
the host's own Stop hook instead.

## Retracting an approval — why each of the three steps is required

The `plan-state.sh set <slug> draft` line in the first snippet above is not optional
either. **Every** approval path — no-arg and `--deliver` — promotes the
plan's `.state.json` to `approved` before it exits, and `begin-plan.sh` touches only
the marker. Re-arm alone therefore leaves a plan recorded as `approved` behind a
closed gate: later sessions read the sidecar, not the marker, so one sees a green
light and starts implementing into a gate that denies its first write.

Two consequences to tell the user about while you do it:

- **The plan must be re-written before it can be approved again.** Re-running
  `begin-plan.sh` resets the marker's mtime, and `approve-plan.sh` refuses any
  `plan.md` older than the marker. This is the same staleness defense that stops an
  old plan being resurrected, and here it fires on the plan you just retracted. Any
  genuine revision (a Rev bump per Step 4) clears it.
- **Retraction is a pre-implementation act.** Effective state is the *more advanced* of
  the stored state and what the plan's `✅` step ticks imply, so storing `draft` on a
  plan that already has ticks is silently outranked — `plan-state.sh` even says so as it
  writes. If any step is ticked, work has already shipped: surface that to the user as a
  rollback decision (revert the work, or keep it and re-plan the remainder) instead of
  quietly writing a state that will not take.
