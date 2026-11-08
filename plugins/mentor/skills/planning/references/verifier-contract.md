# Verifier prompt and return contract

Read this whenever a run needs a grade: after each implementation step, for each
`## Verification` topic, for the plan's `## Goal check`, and before a playbook's
merge. The agent that built the work never grades it (AGENTS.md → Mentor core
concept, rule 5). Paste the fenced block under "What the verifier must return"
into every verifier's prompt verbatim. A verifier briefed only with "check step 3"
re-derives the criteria from memory and confirms instead of checking.

## Who is dispatched

| Grade | One fresh verifier per | Brief carries |
|---|---|---|
| Step | implementation step | the step's `Goal:` and `Done when:` lines, verbatim |
| Topic | `## Verification` topic | its `Focus:`, `Checks:`, `Pass when:` lines, verbatim |
| Goal check | plan | the `## Goal check` predicate and the `## Done review` |
| Merge (playbook) | pull request | the PR diff, the plan path, the Goal check |

- Resolve the verifier through planning → "Role resolution". Scheduling, model,
  and effort come from the host's verifier role; the caller must wait for its returned
  verdict before acting on the grade or ticking a step.
- The verifier SHOULD use another model family than the author. Record the actual
  families, or `unknown`; different runtimes do not prove different families.
- Where delegation is unavailable or prohibited, run the same checks serially in the main
  thread and label the verdict `self-graded`. Never present a self-graded PASS as
  independent.

## What to hand the verifier

- Open every verifier brief with the plan-level Goal: line verbatim, or `Goal:`
  followed by the user's request if no plan exists.
  For a released plan that has no plan-level Goal: line, derive one sentence from its approved Context and Goal check, cite those sections in the brief, and leave the saved plan and its predicate unchanged.
  The grade must serve that outcome.
- The lines named in the table above, copied verbatim, never paraphrased.
- The exact file paths, and the plan path `.mentor/plans/<slug>/plan.md`.
- The grade identity (`Step N`, `Topic N`, `Goal check`, or `PR`) and the author's
  model family, or `unknown`. Ask the verifier to report its actual family or `unknown`.
- Any tool invocation already resolved this session (module path, launch flags), so
  the verifier does not rediscover it.
- Earlier check output and its source verdict, when proposing reuse under
  "Evidence reuse" below.
- For a race or timing-sensitive check, ask for 5+ independent runs before a PASS.
- For numerical claims, read [Explain the number](principles.md#explain-the-number)
  in `references/principles.md` and require its evidence, so noise or skipped work
  cannot masquerade as an improvement.
- The safe-check rule: a zero-hit or empty result is not evidence until the check
  itself is shown to work. A single-line `grep` misses a claim that wraps lines; an
  unquoted glob aborts under zsh `nomatch`; ERE wants `|`, not `\|`.
- For a plan predating `Topic N —`, derive the three lines from the prose bullet
  (title from its subject, its text as `Checks:`, its stated outcome as `Pass when:`).

## Evidence reuse

Reuse only deterministic check output for the same check with identical predicate,
command and cwd on a proven-identical clean tree, with unchanged tool, dependency and config inputs.
For software changes, apply the git proof in [software-change.md](playbooks/software-change.md) §2 and
include its §5 evidence bundle in both the source and current verdicts. If any
condition or evidence field is missing, mismatched or unproven, re-run the check. Never clean
or commit just to enable reuse.

A fresh verifier still grades each stage and cites the recorded output and source
verdict; reusing output never reuses a prior grade. This avoids repeated work
without surrendering independent judgment. Re-run live CI, checks of external
state and timing-sensitive repeats, including the independent runs required above.

## What the verifier must return

```
Verdict: PASS | FAIL | HANDBACK
Grade: Step N | Topic N | Goal check | PR
Grading: independent | self-graded
Author family: <actual family, or unknown>
Verifier family: <actual family, or unknown>
<evidence per check — the exact command run and its output, or a file:line citation; for software checks include the §5 evidence bundle, and apply Evidence reuse above to any reused output>

Gaps / Missing:
<one stamped line per gap, or the literal words "none found">
  [GOAL] <finding> — which `Done when:` / `Pass when:` / Goal check it leaves unmet — fix: <a few words>
  [NON-GOAL][SMALL] <finding> — why the goal is met without it — fix: <a few words>
  [NON-GOAL][LARGE] <finding> — why the goal is met without it — fix: <a few words>

Weakened checks:
<any `Done when:` or Goal check reworded since approval so it is easier to meet, or "none">

Evidence review:
<each Done review scenario marked observed with no evidence or a dead evidence path, or "none" / "n/a"; `evidence: not capturable on this host, verify by <command>` counts as evidence when it names a command>

Notes:
<observations that are NOT defects, or the literal word "none">

Cross-topic:
<a finding that belongs to a different step or topic — name it in one line, or "none">
```

## How the verdict is decided

- **`FAIL` iff at least one `[GOAL]` gap exists**, a check was weakened, or the
  evidence review lists a scenario. `[NON-GOAL]` gaps never fail a grade; they
  become decision-log rows marked `review?: optional`.
- **`HANDBACK`** is a verdict on the brief, not the work: the check itself is broken,
  unrunnable, or larger than what was handed over. Report what you did check and list
  the remainder. It costs the step none of its retry budget.
- **Stamps.** `[GOAL]` names the bullet it leaves unmet, which makes the stamp
  checkable. `[LARGE]` judges the fix: more than one layer, ~10+ files, a live
  multi-service stack to prove, or a design decision the plan never made.
- **Tiebreaks point at review**, never at a silent fix: unsure `[GOAL]` → stamp
  `[NON-GOAL]`; unsure `[LARGE]` → stamp `[LARGE]`. A misfiled `[NON-GOAL]` surfaces
  as a review row the human clears in seconds; a misfiled `[GOAL]` disappears.
- `Gaps / Missing:` is mandatory even on PASS. Its explicit line is what forces
  "what is missing?" to be asked.
- `Notes:` holds everything that is not a defect, so no review row is spent on a
  non-problem.
- `Cross-topic:` never fails this grade. The orchestrator routes it to that step's
  or topic's verifier, or logs it as its own row.
- The verifier reports and stamps. It never fixes, never edits the plan, and never
  ticks a step.

## What the orchestrator does with it

The caller decides what a verdict triggers: planning → "After Proceed" for a step,
topic, or Goal check (topics and Goal checks never tick a step), and merging →
"Step 3.5" for a merge.
**HANDBACK** is a verdict on the brief: repair the brief or the check and re-dispatch
fresh, with the remainder as its inputs. It costs no retry (merging caps it at one
repair per PR).

The caller saves every returned block verbatim, including FAIL and HANDBACK, under
`.mentor/plans/<slug>/verdicts/`: `step-N.md`, `topic-N.md`, `goal.md`, or `pr.md`.
The block includes the `Grade:`, `Grading:`, `Author family:`, and `Verifier family:`
headers above. Persistence belongs to the caller, so a read-only verifier can grade.
Write `verdicts/pr.md` only inside a plan run; standalone merging keeps its existing
reporting behavior without creating a plan artifact.

Overwrite `verdicts/step-N.md` with the latest grade on every re-grade; no reader uses
`-rK` files. Released paths `step-N-verify.md`, `topic-N-verify.md`, and `goal-verify.md`
remain readable only when the corresponding canonical file is missing. A present
canonical verdict takes precedence even when it is non-PASS; legacy headers remain
optional.

For a step PASS, use decision `Step N graded`, evidence
`verdicts/step-N.md · <grading> · <author>/<verifier> family`, and result `PASS` in the
decision log. The order is **save the verdict → append the PASS row →
`plan-state.sh record-write <slug>` → `plan-state.sh tick <slug> <N>`**. With no helpers,
preserve the same order in the durable artifacts and report any unavailable state action.

A verifier carrying several topics returns the whole block once per topic, each
under its own `Topic N —` heading; the caller saves each to its own file. One merged
verdict hides a failing topic behind a passing one.
