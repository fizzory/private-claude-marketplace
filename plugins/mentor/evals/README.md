# Routing and playbook-selection evals

`hooks/tests/` proves the scripts behave. This proves the **descriptions** do: that a
user's phrasing reaches the skill it should, and avoids its six siblings.

Mentor ships seven user-facing skills (`planning`, `grilling`, `previewing`, `merging`,
`shipping`, `constitution-authoring`, `frontend-self-ex-review`). Planning reads
five playbooks (software-change, retrospective, investigation, hillclimb and prototype) as references through
[`skills/planning/references/playbooks.md`](../skills/planning/references/playbooks.md).
Both forward planning and single-session retrospective requests must select `planning`;
reference selection happens within that flow. Other collisions still matter, such as
`previewing` stealing `frontend-self-ex-review`'s screen-review queries. The harness
stages **all seven skills at once** and records which one wins. Selection cases additionally prove which reference files were read, in order, before work starts.

Note the skill names are the **skill** names, not the command names: since v2.18.0 no
skill shares a name with a command (`/mentor:plan` → skill `planning`, and so on), which
is what makes the skills reachable and their descriptions visible at all. Anything this
harness measures is measuring the real routing surface only because of that split.

## Run it

```bash
cd plugins/mentor/evals
python3 harness.py claude "" 1  # <host> <model> <reps-per-query>; empty model uses host default
python3 harness.py codex gpt-5.6-sol 2
```

Needs the selected host CLI on PATH and its normal authentication. The 62 queries × reps run six
at a time, each in a fresh, automatically seeded project. Exit 0 requires every case to pass;
a wrong pick, missing/unexpected/out-of-order read, wrong delivery owner, contamination,
process error, timeout or incomplete transcript exits nonzero. No flags were added.
Scratch projects and evidence go under `$TMPDIR/mentor-trigger-eval/run-<host>-<id>/`
(override the parent with `MENTOR_EVAL_WORKDIR`), never into the repo. Each case retains
`transcript.jsonl`, `stderr.txt`, `reads.json`, `score.json` and its project. Both the run's
`results.json` and the latest `results-<host>.json` retain scores, failures, init inventories,
read paths and evidence locations. Keep host baselines separate.

## Child-session isolation

Every Claude child receives `--setting-sources project,local --strict-mcp-config`,
`--disallowedTools "mcp__*"`, and child-local `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` plus
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`. The harness removes the nesting marker and inherited
plugin-root pointers; it preserves the authenticated profile. It uses an appended system
instruction for the selection boundary because CLAUDE.md and memory are disabled. It does
not use `--bare`, an empty config directory, or caller-supplied isolation settings.

The `system`/`init` guard fails closed on absent/malformed inventories, unexpected skills,
agents or plugins, and any MCP server, reporting `incomplete (contaminated)` with what
loaded. Its explicit name sets allow only the seven staged skills, 22 measured built-in
skills, seven measured built-in agents and five managed plugins. Managed plugin records
must also have `path: builtin` and their matching `@builtin` source. No prefix wildcard or
runtime auto-allowlisting is used. The measured probe inventory is saved in
[`fixtures/selection/claude-isolated-init.json`](fixtures/selection/claude-isolated-init.json);
its one staged `demo` skill is **not** a built-in and is not allowlisted for eval children.
A host update with new built-ins fails until a fresh measured inventory is reviewed.
Non-staged Skill calls, including namespaced picks, retain their full name and fail the
expected routing comparison instead of being reported as `none`.

Codex uses ephemeral read-only sessions and observes completed literal file-read commands;
it does not expose Claude's init inventory, so this guard is a Claude-host check.

Baseline at v2.11.1: **36/40**, 18 of 20 queries clean on both reps — over 8 staged
skills and queries 1–20. v2.12.0 stages 10 skills (`tour` and the topic × perspective
page skill joined) and adds queries 21–28; re-baseline on the first run. A later refresh staged 15 skills
(`deferring`, `constitution-authoring`, `plan-touring` joined) and added queries 36–44.
**v3.0.0** removed `plan-touring` (14 skills staged, query 42 dropped) and rewrote
several descriptions in the isolation pass — re-baseline pending; the harness was not
re-run as part of that change. **v4.0.0** replaced the topic × perspective skill with
`previewing` (still 14 staged), retargeted queries 21–24, 32 and 44 to it, and added
queries 56–59 (two `previewing` core triggers, near-misses for `plan-review` and
`touring`).

Baseline at v4.0.0 (Claude, `claude-opus-5-5`, 2 reps, 2026-10-11): **98/116**, against
86/108 for the 3.1.0 skills on the older fixture the same day. Every `previewing`,
`plan-review` and `touring` query routed as expected on both reps except #34 (1/2) and
#59 (0/2, before the onboarding plan joined the fixture), and no miss went to a wrong
skill. A 6-rep re-measure on the current fixture, new skills against 3.1.0: #59 6/6
(new query), #34 5/6 vs 5/6, #8 5/6 vs 5/6, #37 2/6 vs 4/6.

**v4.1.0** stages 15 skills (`frontend-self-ex-review` joined) and adds queries 60–73: core
and plain-wording triggers for a self-explanatory screen (#60–63, #69–71), near-misses for
`plan-review` (#64), `touring` (#65) and `previewing` (#68), and four `none` baits (blog-copy
editing #66, an aesthetic restyle #67, a general UI review with no self-explanatory goal #72, a
component code review #73). Measured on the shipped description (Claude, `claude-opus-5-5`,
2026-10-16): #60–62, #66, #69, #72 and #73 at 4 reps went **28/28**; the 17 queries the new skill
could plausibly steal (#7, 9, 21–27, 34, 40, 43, 44, 56–59) plus #63–65, #67, #68, #70 and #71 at
2 reps went **46/48**. The two misses, #34 and #57, went to no skill in the slow 30–45s band, not
to the new skill; #57 scored 4/4 with and 4/4 without the skill staged in a same-day run. Two
earlier description drafts are not comparable: one that read as review-only lost "make it
textless" requests (#62 0/2) until the description said to use the skill first even when the
user asks for the change. A full-suite re-baseline is still pending.

**v5.0.0** removed `plan-track`, `plan-review`, `dispatch-agents`, `resuming`,
`handoff-note`, `touring` and `deferring`, so the harness stages 8 skills. Their 34 queries
went: 30 deleted, and 4 kept as `none` negatives — #6 ("where were we"), #11 (fan out to
subagents), #13 (write up where we are for a fresh session) and #36 (note a bug for later) —
since no mentor skill owns those asks any more. The set is now 42 queries (25 skill, 17
`none`). Every number above was measured on the larger skill set and is not comparable;
re-baseline on the first run.

**v6.1.0** stages 9 skills (`playbook-retrospective` joined) and adds queries 77–82: four
core/plain-wording triggers for a single-session retrospective (#77–80) and two near-misses
— a batch harvest across all past sessions, which is loom's job and routes to `none` (#81),
and a forward code-change goal, which stays `planning` (#82). Those released skill IDs
are now compatibility aliases in the playbook index. The four retro cases (#77–80)
now expect `planning`; neither playbook is staged as a public skill. The recorded
baselines above predate the conversion and need a fresh run.

## Fixture and selection boundary

The harness runs `seed.py` for **every** case and repetition. No manual seeding is needed.
The seed supplies the existing billing/onboarding plans, review page and source subjects,
so a missing fixture cannot masquerade as a weak description. Resume cases add their own
released plan/sidecar and saved verdict, and scoring rejects any change to those files.

The original 48 routing cases retain their descriptions and STOP-only bodies. Cases
83–96 instead copy each real skill folder, including its bundled references, byte for
byte into the fresh project. Their common scratch instruction stops at workflow selection
before approval, draft scaffolding, implementation, delegation, grading or delivery.
It never gives the expected selection. The final `EVAL_SELECTION` JSON reports a single
`delivery_owner` and any `history_to_recheck`; actual reads are independently scored from
completed tool events, never from that self-report or a mention in prose.

The parser credits successful `Read` calls and standalone literal `cat`/`sed`/`head`/`tail`
commands with successful results. For literal shell sequences with `cd`, `;` or `&&`,
it requires the staged file's full contents in the returned output and tracks Claude's
working directory across completed calls. An earlier proven read still counts when a
later command fails; a failed read, path mention or unsupported shell expression does not.
Index completion must precede each playbook read request;
parallel index/playbook reads fail. Search results, failed or unfinished reads and partial
stream arguments do not count. All expected read paths must occur and no other indexed
playbook may load. Selection continues past the planning Skill event until a complete
transcript and one selection-boundary report are observed.

| Case | Expected skill | Expected index/playbooks | Delivery owner |
|---|---|---|---|
| 83 | planning | index → software-change | software-change |
| 84 | planning | index only (original writing) | general |
| 85 | planning | index → retrospective | retrospective |
| 86 | planning | index → software-change; no retrospective | software-change |
| 87 | planning | index → investigation | investigation |
| 88 | none | none (ordinary how/why) | none |
| 89 | planning | index → hillclimb | hillclimb or general, exactly one |
| 90 | planning | index → software-change; no hillclimb | software-change |
| 91 | planning | index → prototype; no software-change | prototype |
| 92 | previewing | none (mock-up request) | none |
| 93 | planning | index → hillclimb + software-change | software-change only |
| 94 | planning | saved plan, index → software-change (released inline alias) | software-change |
| 95 | planning | saved plan, index → retrospective (released next-line alias) | retrospective |
| 96 | planning | saved plan/verdict, principles, index → software-change | software-change; no supported history re-check |

The non-software hillclimb accepts either owner expressly permitted by its reference;
it still requires one scalar owner. Case 96 checks the negative S12 boundary at resume
triage: both prior claims have support, so neither is selected for re-check. It does not
execute an approved run or grade the historical artifacts.

Offline scoring regression checks (no model calls):

```bash
python3 -m unittest discover -s plugins/mentor/evals -p test_harness.py
bash plugins/mentor/tests/test-dual-host-contract.sh
scripts/verify-plugin-edits mentor
```

Synthetic passing transcripts exercise the scorer, not the skills' live behavior. Only
the literal live command `python3 plugins/mentor/evals/harness.py claude "" 1` proves the
selection predicate; the offline tests cannot substitute for it.

## The eval set

`evals.json` is **multi-class**, not the usual boolean `should_trigger`: each query
carries the skill that *should* win, or `none`. A binary label cannot express a
collision, which is the whole point here.

Many queries are near-misses chosen to be genuinely hard — an in-document re-phasing
(#3), `previewing` vs `frontend-self-ex-review` on a page of the
frontend (#68), `shipping` vs `merging` on "get it up as a PR" (#30), and keyword baits
(`break up` commits, `split` a component, `review` a PR, `track` a sprint, a video-call
meeting, the US constitution, a general UI review, a component code review) that share
vocabulary with a skill but must trigger nothing. The four v5.0.0 negatives (#6, #11,
#13, #36) guard the opposite drift: a kept skill quietly absorbing a removed one's asks.

## Known failures

- **#20** is intentionally green from v3.1.0 onward: natural-language planning is the
  portable entry point. Claude can still add the `/mentor:plan` command and edit gate,
  while Codex follows the same skill guidance-first.
- **#2** is a flawed query, deliberately left alone. It borrows the old plan-status
  phrase "one session at a time" and gives "break this up" no referent. Tuning a
  description to win it would be overfitting to a bad test.

When you add a skill, run this first. A new sibling that quietly steals
an existing skill's queries is exactly what it is here to catch — v2.12.0's topic ×
perspective page skill (checked against the then-staged `tour` and `plan-review`, since removed) is the worked example, and v4.1.0's
`frontend-self-ex-review` added near-misses against `previewing`.

## Behaviour evals (v6.0.0)

`behaviour.json` is a separate, smaller set: it checks what an **approved run** does, not
which skill fires — no question on a reversible fork, a pause on an always-pause item, a
decision-log row per choice, a verifier before every tick, a mid-run product call decided without pausing, and
a non-code goal picking no playbook. Cases 1–6 each seed a scratch repo with an approved
plan; cases 7–17 set up the state their prompt names. Each is
graded by a reader against its assertions; `harness.py` does not run cases 1–17. Cases 18–31 mirror routing/selection cases 83–96 through `routing_case_id` and are executed by the harness. Their pre-approval scope is the selection boundary described above; full-run behaviour remains reader-graded.

v6.1.0 adds cases 7–15 for the retrospective playbook (scenarios S1–S8; S5 is two cases,
#11 and #12): a plain repeated
procedure becoming one Accepted new-skill row, a compacted Claude orchestrator with opaque
delegates, a Codex orchestrator linked by `parent_thread_id`, resume dedupe by `uuid`,
concurrent-session identity resolving to `partial` rather than newest-file, a retro resuming
from `evidence/` after its own interruption, the live-run refusal, and the one-line
invitation after `implemented` (and none after a retro plan). S1/S2/S3/S5 point at the
fixtures under `fixtures/retro/` and their `expected.md`.

v6.2.0 adds case 16, the one pre-approval case: the approval turn sends a pointer card of
at most 5 lines instead of the plan body, the question names the plan path and Rev, a
re-ask carries the newest Rev line's note only when the plan changed, and `show plan`
in Other prints the body once and re-asks without approving. Case 17 checks the run-end
report — one verdict line with counts and the plan path, leftovers named one per line,
the Done review left in plan.md.
