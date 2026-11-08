Overlay a mentor plan run loads when the plan's goal is the prototype itself:
throwaway variants plus observed comparison evidence so the human can pick.
Never load it for a mid-plan fork or a bare “mock it up” request; the latter goes
to previewing. Planning owns approval, grading and the run; this reference
delivers evidence for a preference without deciding that preference.

# Playbook — prototype

## Host portability

Use a structured question UI when the host offers one; otherwise settle the
same focused questions in conversation before approval. If delegated agents are
unavailable or prohibited, build and observe variants serially and label any
required self-grading under planning's verifier contract. Resolve optional Mentor
helpers with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; without either, use
the durable `.mentor/` artifacts and report unavailable state actions. Use local
artifacts and the host's available observation tools; if a required surface
cannot be observed, report the gap rather than fabricating comparison evidence.

## 1. Research directives (planning Step 2)

Name the decision the variants inform: for example, layout density, interaction,
behavior or timing. Record the alternatives, comparison criteria, representative
tasks, observation method and expected evidence before approval. Inspect existing
constraints and references when needed to make the variants comparable. Without
a named decision and a requested variants-and-evidence deliverable, this playbook
does not match.

Keep the approved goal on the variants and their evidence. A production feature
that might benefit from a prototype does not become a prototype plan; use
planning's triage or re-plan path for its open question without adding this overlay.

## 2. Definition of done (Goal check and `Done when:`)

The agreed variants exist, can be opened or run, and have been observed against
the approved tasks and comparison criteria. Each variant has recorded output,
screenshots, interaction observations or timing as appropriate. The comparison
states observed tradeoffs, limitations and unresolved questions, with evidence
for each. The verifier checks the variants and observations against the approved
predicate, not production readiness or the human's eventual preference.

The human choosing a variant is not part of the run's done predicate. No
preference is decided during the run, and no approved predicate is weakened to
make an unfinished prototype pass.

## 3. Extra always-pause items (the run)

No additional pause items; retain the constitution's or built-in list. Shipping
prototype code, changing production source or publishing it as a finished
feature is outside this plan's deliverable. Leave a later implementation as a
separate scope rather than pausing the evidence run to request a selection.

## 4. Deliver mode (the run's deliver state)

Prototype owns delivery of the labelled variants, instructions to inspect them,
observed comparison evidence and Done review. Hand these to the human, who picks
after delivery. State the decision they inform and that the artifacts are
throwaway. Never ship prototype code or invoke a software shipping flow. A later
production build needs its own approved plan; incidental code here is an
evidence artifact, so software-change is not co-loaded for it.

## 5. Evidence kinds (the Done review)

Keep variants and observations under `.mentor/plans/<slug>/`, with evidence in
`evidence/`. For a visual decision, capture every variant and exercise the named
interactions on the relevant surface. For behavior or timing, retain the observed
outputs, inputs, method and repeated measurements where needed. Provide a
variant-by-criterion comparison with links to those observations and clear
limits; an untested sketch alone is not comparison evidence.

## 6. Run rules (After Proceed)

Build the smallest isolated, disposable artifacts that expose the named choice;
keep them separate from production source. Use the same tasks and criteria for
each variant, label them clearly, and observe each before comparing. Spend
effort on the decision evidence rather than production polish while retaining
every approved check. Record empirical findings without selecting a preferred
variant for the human. Do not introduce this overlay mid-plan or turn its
throwaway quality bar into permission to weaken another plan's predicate.
