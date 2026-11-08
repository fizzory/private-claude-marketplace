# Principles catalog

Apply only entries whose trigger matches the decision at hand. Project-specific
principles belong in the constitution; do not copy this catalog into it.

## Attack the premise

Apply when: Two or more fixes sharing a premise fail the same check.
Write that premise down, test an observation that distinguishes it from an
alternative, and follow the evidence before trying another fix.
Why: Repeating fixes that assume a false premise spends the retry budget on the wrong cause.
Home: [FAIL and re-plan](../SKILL.md#implement).

## Laziness protocol and subtract before you add

Apply when: Choosing an addition, refactor, abstraction, or cleanup.
Choose the smallest change that meets the goal; remove redundant complexity before
adding layers, and keep each decision in one place while preserving required behavior
and released-data readers.
Why: A smaller surface leaves fewer moving parts to maintain and verify.
Home: [Goal tracing and scope](../SKILL.md#write-the-plan).

## Fix root causes

Apply when: A failure or bad state needs correcting.
Reproduce the fault, trace it to the first wrong decision, and check for the same
pattern elsewhere within scope; handle a state where it fails only if that state is
legitimate, otherwise fix its producer.
Why: Treating the symptom leaves the producer free to recreate the fault.
Home: [Research the category and what regenerates a bad state](../SKILL.md#research).

## Build the lever

Apply when: Non-trivial work needs a repeatable operation or proof.
Prefer the smallest rerunnable tool or check over repeated manual work, reuse an
existing one first, and prove it on a representative unit; add machinery only when
the governing contract authorizes it.
Why: A repeatable operation lets another person verify the work without reconstructing it.
Home: [Rule placement and machinery limits](../../../README.md#where-a-new-rule-goes-skill-authoring-convention).

## Explain the number

Apply when: Planning, trusting, reporting, or acting on a numerical claim.
Name the decision the measurement can change and its noise floor before measuring;
record run count, spread, and the evidenced limiter, and rule out skipped, cached,
failed, or irrelevant work before attributing an effect.
Why: An unexplained number can measure noise or a different task from the one that matters.
Home: [Verifier evidence requirements](verifier-contract.md#what-to-hand-the-verifier).

## Make operations idempotent

Apply when: A state-changing operation may be retried or resumed after interruption.
Read the actual state and apply only the difference needed to reach the goal; check
that a second run and a run after partial completion converge to the same result,
with stale artifacts recognizable from evidence.
Why: Safe repetition prevents an interrupted run from turning into manual repair.
Home: [Resume and existing-state handling](../SKILL.md#gate).

## Guard the context window

Apply when: Large outputs, long files, repeated reads, or delegation threaten context capacity.
Bound each phase, keep bulk evidence in durable artifacts, and carry concise findings
and citations into the main thread; delegate bulk reading only when available and useful.
Why: Keeping the active context small preserves the evidence and decisions needed for the next step.
Home: [Context check](../SKILL.md#re-check-context) and [role briefs](../SKILL.md#decision-maker).
