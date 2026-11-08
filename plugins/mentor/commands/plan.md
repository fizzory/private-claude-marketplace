---
description: Start a mentor plan session (marker-driven edit gate, Markdown plan under .mentor/plans/<slug>/)
argument-hint: [what to plan | <slug>]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — plan

You are entering the mentor plan harness. Read-only-during-planning is enforced
by the plugin's marker-driven edit gate, which works even under
`bypassPermissions`.

Do these in order:

1. **Arm the plan gate — run this FIRST, exactly once, before any reading or drafting:**

   One guard before you arm: if another framework already owns the plan of record for
   this work (a spec-kit `tasks.md` phase, a Jira epic — decide from what the user
   asked, not by sniffing the repo), do **not** arm. Point at that framework's own next
   command instead. This sits before the arm deliberately:
   nothing releases this worktree's `.planning.<wt-id>` marker (or a live legacy
   `.planning`) but an approved plan.

   ```bash
   [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh" [<target-slug>]
   ```

   Pass the target plan's slug as the one optional argument whenever the request
   names an existing `.mentor/plans/<slug>/` dir. It is
   what lets `begin-plan.sh` print `ALREADY APPROVED` for an approved or in-progress
   plan (and arm nothing), and WARN when a live sibling worktree owns the slug (see
   "also armed elsewhere" below). Leave it off for a brand-new topic with no slug yet.

   This writes THIS WORKTREE's own `.planning.<wt-id>` marker (`plans/` itself stays
   shared across every worktree). From this point, `plan-gate.sh` blocks every repo
   source edit **in this worktree** until the plan is approved — a sibling worktree
   plans and edits independently. The only file you write during planning is the
   Markdown plan at `<repo>/.mentor/plans/<slug>/plan.md` (inside the repo, but the
   `.mentor/` tree is exempt from the gate). Read the script's stdout:
   - **`Plan gate NOT armed`** (another live session in this worktree, or a legacy
     repo-wide marker): don't re-run `begin-plan.sh` to force it; surface the printed
     owner/age and ask. Only on the user's explicit authorization, and only for the
     same-worktree case, re-run with `--override-foreign-marker`; a legacy marker is
     waited out or removed by hand only with the user's explicit OK. Never delete a
     marker yourself.
   - **`also armed elsewhere:`** lines are informational — don't re-run, don't wait.
   - **`CONTEXT:`** lines: mention them to the user and continue — the context gate
     only warns.
   - **`ALREADY APPROVED: <slug>`** is not an error: that plan is already approved (or
     in progress) and this worktree may build it, so nothing was armed. Invoke
     `Skill({"skill": "mentor:planning"})` and go straight to its "After Proceed —
     run until the Goal check passes {#implement}" section for that slug, after the check
     its Step 0 names for this case. To re-plan it instead, run `plan-state.sh
     set <slug> draft` and re-run step 1 — safe here, since nothing was armed.

2. **Immediately call `Skill({"skill": "mentor:planning"})` and follow it end
   to end** (unless step 1 printed `ALREADY APPROVED`, above).
   At the approval step, take the option list from the **option-set table** in the
   skill's `{#approve}` section — Proceed · Deliver plan only · Keep planning. Do not
   improvise the list here: one copy of it, in the skill, is the only way it stays
   right. Proceed and Deliver plan only validate the plan and release the gate; Keep
   planning stays in planning.

3. **Proceed** — follow planning → **After Proceed** (`{#implement}`) for the full
   run directive. **Deliver plan only** releases the gate and then STOPs,
   exactly as the skill states — it does not implement in this session.

**Never re-run step 1 once it has armed the gate.** `begin-plan.sh` resets THIS worktree's
`.planning.<wt-id>` marker's mtime (or the legacy `.planning`'s, in the empty-wt-id
fallback), and `approve-plan.sh` then refuses to release a plan file older than the
marker — stranding a finished plan unapprovable.


The task to plan:

$ARGUMENTS
