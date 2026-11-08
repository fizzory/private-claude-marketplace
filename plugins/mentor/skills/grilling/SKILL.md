---
name: grilling
description: >
  Stress-test and sharpen a plan or design by interrogating the user one question
  at a time, before any code is written. Use when the user wants to pressure-test
  an approach or resolve open design decisions, or uses a "grill" trigger —
  "grill me", "grill this plan", "stress-test this", "pressure-test this approach",
  "poke holes in this", "review this plan", "is this plan any good". Also the
  plan-quality pass on a drafted plan before approval. Walks the decision tree one
  branch at a time, recommends an answer for every question, and explores the
  codebase directly rather than asking what the code can answer. This is a
  conversation, not an implementation, and runs only before a plan is approved.
---

# Grilling — Sharpen the Design Before You Build

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

This skill interrogates **you** (the user) to pressure-test a plan or design and resolve its open decisions *before* a plan is locked or any code is written. It walks down each branch of the design tree one decision at a time, recommending an answer for every question, until you reach a shared understanding.

It is a **conversation**, not an implementation. It makes **no repo edits** during the interview and does not draft or rewrite the plan — when it surfaces a changed decision, the plan flow re-renders it.

**A plan-quality pass on a drafted plan is grilling's job too.** When the user asks "is this plan any good?" at the approve gate, grill the drafted plan: the same interview answers both "have we actually thought this through?" and "is the written plan any good?", so there is one place to reach for either.

Within the plan flow itself, `plan` Step 3 owns *post-research* decision resolution — the same one-question-at-a-time, recommended-first protocol, run with research evidence in hand. Grilling owns *pre-research* ambiguity in the request, and never re-asks a decision this interview already resolved.

## When to use

- The user typed `/mentor:grill`, or used a grill trigger ("grill me", "grill this plan", "stress-test this", "poke holes in this approach").
- A design or approach has unresolved choices and the user wants to pressure-test it **before** building.
- Naturally upstream of `/mentor:plan`: grill first to sharpen the thinking, then plan.
- A current mentor plan exists and the user wants its decisions challenged, or its quality judged, before approving (run grill, then return to the proceed gate).

## When NOT to use

- Trivial / single-file changes where the interview costs more than the change.
- The plan is already approved — grilling is pre-approval only. After approval the run decides by itself and logs every choice (planning → After Proceed); a doubt about an approved plan is a re-plan, not an interview.
- Pure exploration with no plan or design to interrogate.

---

## Step 1 — Resolve the subject

Figure out *what* you are grilling, in this order:

1. **Explicit argument.** If the user passed a topic (via `/mentor:grill <topic>` or in the message), grill that design.
2. **Current mentor plan.** Otherwise, ask mentor which plan is current:
   ```bash
   [ -d "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks" ] || { echo "ERROR: Mentor helper unavailable — set PLUGIN_ROOT (or use the Claude compatibility fallback) or use the documented artifact fallback" >&2; exit 1; }
   bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" current
   ```
   `Read` the `PLAN:` path it prints (the `.md` is canonical) and grill it. Do **not** edit it.
3. **The conversation.** If there is no argument and no plan, grill the design described in the conversation so far.

**Check for related plans before interrogating**, whichever branch above resolved the
subject — branches 1 and 3 in particular never touch plan state on their own:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" list
```

A plan on the same or an adjacent topic — especially one `draft`, `in_progress`, or
`superseded` — carries context worth having before the interview starts: prior
decisions already made, or why an earlier attempt stalled or was rejected. If one
looks related, read its sidecar `note` field directly rather than reconstructing its
history from the plan body by hand — the note already holds the reviewer's own summary:

```bash
jq -r .note "$(bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" dir --plans)/<slug>/.state.json"
```

If there is genuinely nothing to grill, say so in one line and stop.

---

## Step 2 — The interview protocol

**Check the context before committing to the interview.** An interview runs on `AskUserQuestion` round-trips and codebase reads, neither of which `context-gate.sh`'s WARN tier fires on — so this reading, not the gate, is what tells the user how large the session already is:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" context
```

- **`CONTEXT: HIGH`** — over the limit; surface it, then continue and keep the interview tight.
- **`CONTEXT: WARN`** — surface it, then continue.
- **`CONTEXT: OK` / `UNKNOWN`** — continue.

Re-run the same check at Step 3's Close, before the recap.

Interview the user relentlessly about every aspect of this plan until you reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your **recommended answer** — the most practical and clean solution, never trade maintainability or reliability for implementation speed.

- **Ask the questions one at a time**, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering — favor `AskUserQuestion` with a single focused question (your recommended option first).
- **Every question stands on its own.** The user answers from the question screen alone — never sent to a file, a plan section, a coined id or code (`G14`, `P2`), or an earlier turn to learn what the question means. Name things in plain language, quote the evidence that decides it rather than citing where it lives, and say in each option what it changes and what it costs. This binds the ids *you* mint hardest: an interview that numbers its own questions or decisions (`G7`, `D23`) has built a private index the user never received, so say "the cross-tenant Secrets read", not "G14" — the header takes a plain-language handle, and a bare number belongs in your notes, not in anything the user reads. A definition you gave twenty turns ago is not one they still have.
- **Order by dependency.** Resolve the decisions that other decisions hang off of first; let each answer narrow the next question.
- **Triage before asking — the same four buckets as planning Step 3.** Only a genuine product or preference call reaches the user. A question the files answer is answered by reading them (below). A fact a quick probe can settle is settled by running it in a private `mktemp -d` dir. A reversible call the constitution's Decision authority covers goes to a decision-maker agent resolved by planning → "Role resolution"; use that rule for every needed role and state the decision in the next question's brief instead of asking it. The user asked to be grilled on the *design*, not to answer what evidence or an agent can settle.
- **If a question can be answered by exploring the codebase, explore the codebase instead of asking.** Keep reads targeted — search first, then read only the lines that decide the question — because every line read inline stays in the session the interview runs in. Carry what you find into the next question as a named fact with its `file:line`, so a shipped-capability overlap surfaces as evidence instead of dissolving into paraphrase.
- **Before folding codebase findings into your next question, screen them for a shipped-capability overlap.** If they name a shipped skill, command, feature, endpoint, or script the user could already invoke today to get what the subject under design promises, your next `AskUserQuestion` must be the overlap fork itself — extend the shipped capability, supersede it, or build alongside it, recommended option first — before any further branch question assumes the capability is new. An overlap found here costs one question; the same overlap found at the plan's research step costs the whole interview and everything already built on it.
- Keep going until the material decisions are resolved or explicitly deferred — do not stop at the first easy answer.
- **A free-typed instruction converges immediately — don't ask the user to repeat it.** If the user rejects the open `AskUserQuestion` and free-types an instruction instead of answering from the options, map it onto the open decision: "go with your recommendation" (or similar) accepts your recommended option, and a defer instruction ("defer this", "skip it for now", "come back to it later") closes the decision as deferred — either way, converge in the same turn, never re-ask for confirmation or wait for the instruction to be repeated. If the free text names or plainly covers more than the open question (e.g. "defer the rest of the EKS questions"), apply it to every decision it covers and name what you're accepting or deferring, one line each, before moving to the next open item — the same courtesy `planning`'s **Free-typed bulk-accept** gives its own queue. A decision deferred this way still carries into Step 3's recap as a deferred item, the same as one deferred any other way.
- **If a question is declined, or the interview breaks off before Step 3's Close**, don't let resolved decisions vanish silently: summarize what's been resolved so far — and any codebase research already done — in your closing message, so a later session can pick it up rather than the turn ending with nothing recoverable.

---

## Step 3 — Close

When you reach shared understanding:

1. Re-run the context check before the recap:
   ```bash
   bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}/hooks/plan-state.sh" context
   ```
   `CONTEXT: WARN`/`HIGH` surfaces the same way Step 2's pre-interview check does — a
   warning in the recap, never a reason to skip or reroute the close.
2. Summarize the **resolved decisions** and any **deferred / open items** in a short recap.
3. If a mentor plan was the subject, **surface the deltas** between the plan and what you just resolved, and tell the user to fold them in by re-running the plan flow (`/mentor:plan`) or, if mid-plan, re-asking the proceed gate. **Do not edit the plan file yourself** if this worktree's gate is armed — surface the changes and let the plan flow re-render them. A second hazard the gate does **not** cover: a plan whose sidecar `owner` is a *different* worktree (read the same sidecar's `owner` field the way you already read its `note` above — `jq -r .owner` on that path) — no gate blocks editing that file, since the plan-gate deny is scoped to the owning worktree's writes, not to the file itself, and this worktree may be wide open while that plan is someone else's live draft. Treat a foreign-owned plan the same as an armed gate: surface the deltas, don't edit.
4. Point to the natural next step: `/mentor:plan` (to author/refresh the plan) or, if a locked plan now looks solid, return to its approve gate.
5. Never implement from here, even a one-line change: the grill feeds a plan, and the plan's one approval is what starts work. A trivial change still goes through `/mentor:plan`, whose research and approval cost little on a small task and whose verifier is what proves it.

## Done when

- A shared understanding is reached.
- Every material decision is resolved — by the user, by evidence, or by a decision-maker within the constitution's Decision authority — or explicitly deferred.
- Questions were asked **one at a time**, each with a recommended answer.
- Codebase-answerable questions were answered by targeted codebase reads, not by asking the user or by bulk-reading.
- A declined question or an interview cut short still left resolved decisions recoverable — recapped in the closing message, not silently lost.
- Step 1's related-plans check (`plan-state.sh list`) ran before the interview started, whichever branch resolved the subject.
- The context check (`plan-state.sh context`) ran before the interview started and again before the Close recap.
- A free-typed accept/defer instruction closed its decision(s) on the spot — every covered decision named, none re-asked for confirmation.
- Every question that reached the user was a product or preference call; evidence- and constitution-settleable ones were settled without asking and named in the recap.

### Do NOT

- Do **not** implement anything or edit the repo — grilling is conversation + read-only exploration.
- Do **not** edit or rewrite the plan file mid-grill; surface deltas and let the plan flow re-render.
- Do **not** ask multiple questions in one turn.
