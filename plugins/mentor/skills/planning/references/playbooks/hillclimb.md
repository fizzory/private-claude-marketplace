Overlay a mentor plan run loads when the requested goal is sustained improvement
of a named metric against a target through measured attempts. A plain fix with
no metric does not load it. Planning owns approval and grading; this reference
supplies the experiment discipline without owning software delivery.

# Playbook — hillclimb

## Host portability

Use a structured question UI when the host offers one; otherwise resolve the
same focused questions in conversation before approval. If delegated agents are
unavailable or prohibited, run attempts serially and label any required
self-grading under planning's verifier contract. Resolve optional Mentor helpers
with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; without either, use the
durable `.mentor/` artifacts and report unavailable state actions. Keep the
measurement method, attempt log and caps identical across hosts; a missing
measurement tool is an evidence gap, never permission to estimate a win.

## 1. Research directives (planning Step 2)

Ground the metric in the actual workload and reproduce the symptom. Name the
metric, units, better direction and representative inputs. Build or identify a
repeatable measurement command, prove it distinguishes relevant workloads, and
sample enough repetitions to establish a baseline and noise floor. Record work
counts, error counts and the correctness or quality checks that must stay green.

Before approval, record the frozen harness and inputs, baseline and noise floor,
target, minimum **N attempts**, and maximum attempt, time or resource caps. Ensure
the maximum attempt count permits at least N attempts. The Goal check states the
target and minimum together; never choose them after seeing the results. List
mechanism-based hypotheses so each attempt tests a specific explanation.

## 2. Definition of done (Goal check and `Done when:`)

Done means **target met AND at least N attempts logged**, with the final retained
artifact measured by the frozen harness and every required regression check
passing. A lucky early result does not waive N. Each attempt's `Done when:`
requires its measurement, regression result and keep-or-revert record; an
attempt's completion does not itself prove the plan's target.

Exhausting the approved attempts or other caps without the target, or having no
viable hypotheses left before the full predicate passes, is a dead end, never
PASS. Preserve the original target and minimum; report the best measured result
and the unmet predicate. When combined with software-change, its checks also
apply with AND to the changed software.

## 3. Extra always-pause items (the run)

No additional pause items. Union the constitution's or built-in list with any
other selected playbook's items. A cap is an execution limit, not permission to
extend the budget or lower the target during the run.

## 4. Deliver mode (the run's deliver state)

Record a single delivery owner before approval. When hillclimb is combined with
software-change, **software-change is the sole delivery owner**; include the
metric report and attempt log as secondary outputs in its Done review. Hillclimb
does not run a second shipping or merging flow.

For a non-software deliverable, choose hillclimb or the general flow as the owner
and record that choice. Hillclimb-owned delivery hands the final measured local
artifact, baseline-to-final comparison and attempt log to the human through the
Done review. Publication remains subject to the approved delivery contract.

## 5. Evidence kinds (the Done review)

Keep an attempt log under `.mentor/plans/<slug>/evidence/`. Each row records id,
hypothesis, single change, measurement command and inputs, before and after
results, delta relative to the noise floor, regression results, kept or reverted,
and a reason. Retain the raw outputs and baseline samples. Report target, N and
caps; final result and delta; attempts made, kept and reverted; accepted changes;
and remaining hypotheses. Cite the final artifact's measurement, not an earlier
best result from an artifact that was later reverted.

## 6. Run rules (After Proceed)

Read the attempt log before each attempt. Apply **one change → one measurement →
keep or revert**, using the frozen harness and regression checks before the next
change. Keep a change only when the metric improves beyond noise and the gates
stay green; otherwise revert that attempt completely without undoing unrelated
work. Log both kept and reverted attempts. Never stack unmeasured changes or
claim an improvement from inspection alone.

For a plateau, follow [planning's After Proceed run rules](../../SKILL.md#implement)
→ **a plateau is not a stop**, including its bounds and dead-end rule. The
approved caps and §2's full predicate govern every attempt. A changed harness or
invalid baseline requires planning's re-plan path and new baseline evidence;
numbers from incompatible methods cannot be combined into a win.
