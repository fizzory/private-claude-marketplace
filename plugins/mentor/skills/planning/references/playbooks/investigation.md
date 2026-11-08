Overlay a mentor plan run loads when the requested plan deliverable is a cited
answer to a how/why question about how an artifact works or is; a written report
or brief for an audience stays on the general flow with no playbook. An ordinary how/why question outside a
plan loads nothing. Planning owns approval, grading and the run; this reference
supplies the investigation's scope, evidence and delivery contract.

# Playbook — investigation

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same
focused question in conversation before approval. If delegated agents are
unavailable or prohibited, research serially and label any required self-grading
under planning's verifier contract. Resolve optional Mentor helpers with
`PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; without either, use the durable
`.mentor/` artifacts and report state actions that cannot be performed safely.
Use the sources and read-only tools available on the host, and report inaccessible
evidence as a limitation rather than inventing a claim.

## 1. Research directives (planning Step 2)

Name the questions the deliverable must answer, the sources that can answer them,
and any freshness or coverage limits. Inspect the actual artifacts and their
callers, history or documentation as needed. Test uncertain premises with
read-only observations; a recommendation compares alternatives against stated
criteria rather than silently implementing one.

Cite every claim with a source location (`file:line`, a document section or a
direct source link) or a saved observation. Label each claim **measured** (directly
observed), **inferred** (reasoned from cited evidence) or **guess** (unverified).
For an inference, state the reasoning; for a guess, state what would verify it.
These labels prevent a plausible explanation from masquerading as an observation.

## 2. Definition of done (Goal check and `Done when:`)

The approved questions are answered in the saved deliverable; every claim has its
citation and measured / inferred / guess label; and coverage gaps, conflicting
evidence and uncertainty are explicit. Each step's check names the question or
source coverage it proves. The verifier checks the cited artifacts and
observations, not just the presence of citations. An unverified guess cannot
satisfy an approved predicate that requires proof.

Confirm that the work wrote only its plan, evidence and deliverable under
`.mentor/`, with no changes to the investigated artifacts or external systems.
The investigation's Goal check includes this scope check.

## 3. Extra always-pause items (the run)

No additional pause items; retain the constitution's or built-in list. Source
edits, shared-system writes, commits, pushes and publication are outside this
read-only plan, rather than actions to request during it. Record a proposed fix
as a follow-up and continue answering the approved questions.

## 4. Deliver mode (the run's deliver state)

Investigation owns delivery of its cited explanation or recommendation and Done
review under `.mentor/plans/<slug>/`. Link the deliverable and its evidence for
the human to read. Ship nothing. A later implementation needs its own approved
scope; do not co-load a playbook whose delivery changes source or ships an artifact.

## 5. Evidence kinds (the Done review)

Save a question-to-evidence map, source citations, short relevant excerpts and
read-only observation output under the plan's `evidence/` folder. Record the
observation command or method, inputs, time and result so another reviewer can
check it. Preserve each claim's label and any access, freshness or coverage limit
in the deliverable as well as the review.

## 6. Run rules (After Proceed)

Remain read-only outside the investigation's `.mentor/` evidence, plan and
deliverable. Read each experiment's command before running it; use a read-only
alternative when it would alter the subject. Revisit claims when evidence
contradicts them and keep the labels current. If required evidence cannot be
obtained, follow planning's bounded retry and dead-end rules; a confident guess
does not turn an unmet check into PASS.
