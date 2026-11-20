# Marketplace maintainer contract

This repository ships plugins for both Claude Code and Codex. Treat portable
skills and durable project artifacts as the product; host commands, hooks, and
UI integrations are adapters.

## Canonical maintenance tools

- Use `scripts/marketplace` to synchronize, validate, and publish marketplace
  metadata. Do not hand-edit one host's catalog or manifest as a release
  substitute.
- Run `scripts/verify-plugin-edits <plugin>` for each changed plugin, and
  `scripts/verify-plugin-edits --root` when `.claude/**` or root `CLAUDE.md`
  changed. Plugin mode runs canonical marketplace validation, the plugin's
  deterministic tests, and available skill validation; root mode runs
  `.claude/hooks/tests/*.sh`.
- Keep `plugin.json` and portable `skills/` free of host-only paths, tools, and
  guarantees. Put Claude Code or Codex-specific behavior in that host's adapter.

## Compatibility promises

- A change to `.mentor/`-style durable state must preserve readers for released
  data or include an explicit, tested migration.
- Host hooks are guardrails. A portable workflow must remain useful when hooks,
  subagents, publishing, or a structured-question UI are unavailable.
- Do not claim equal host behavior when a capability is adapter-only. Update the
  capability matrix and its tests with the implementation.

## Plugin core concepts

A plugin's core concept is its governing contract, pinned in this file as
`## <Plugin> core concept`. It binds every change and every maintenance pass under
`plugins/<name>/`, whether made by hand or by automation (`/loom:learn`, `/loom:harvest`,
`/loom:audit-plugin`, publish flows).

- **Read it before you change the plugin.** Every skill, hook, command, script, eval, and
  doc you touch must follow each numbered rule; a lesson or fix that cannot be expressed
  within it is out of scope until the concept changes.
- **A contradiction amends the concept first.** Edit the pinned section in the same commit,
  deliberately, and say so in the commit body (`Core concept amended: <what and why>`).
  Never let a plugin drift from its concept one defensible change at a time.
- **Automation never amends a concept.** A headless run that finds its change would
  contradict one leaves the change unapplied and reports it (in the commit body or run
  report) for a human to decide.
- **A plugin without a pinned concept** is governed by the purpose stated in its README
  (its opening section) until one is pinned.

## Mentor core concept

Pinned 2026-11-01. Every mentor skill, hook, command, and doc aligns with this.
A change that contradicts it amends this section first.

> **You approve the plan once. After that, mentor keeps working until the done-check
> passes. It stops only for items on the constitution's always-pause list, and it
> records every decision for you to review afterwards.**

1. **Done is a check.** Every step and the plan's goal carry a falsifiable
   predicate, proven against the real artifact, never relaxed to declare victory.
2. **Never block on the human.** Reversible work proceeds. Only the constitution's
   always-pause list (irreversible or outward-facing actions) stops a run; a
   reversible product call mid-run goes to a decision-maker and is logged
   `review?: needed`. Stop words ("stop", "pause", "wait") pause it.
3. **Decision log.** Every choice made without the human is one row in the plan's
   decision log: what, why, evidence, result. Review happens afterwards.
4. **Triage before asking.** A fact an experiment can settle is settled by running
   it. A call the constitution covers is decided by an agent. Only a genuine
   product or preference call reaches the human, and only before approval.
5. **Independent grader.** The agent that builds never marks its own work passing;
   a separate verifier grades every check, including before a merge.
6. **Run until the check passes.** After approval, mentor drives to the predicate
   using native host primitives (hooks, subagents), not a hand-rolled state
   machine. A dead end is reported, not spun on.

**Retrospective exception.** A requested retrospective skips plan approval, runs end to
end, and delivers one PR/MR per repository touched, with unavailable delivery kept
local and reported. The human's single review is the PR/MR; only a human merges it.
Rules 1 (done is a check), 3 (decision log), and 5 (independent grader) apply unchanged.

## Release safety

- Use semantic versioning from the canonical manifest. A breaking state or
  public-workflow change requires an explicit compatibility decision.
- Verify in a clean plugin cache before publishing. Source-tree success alone
  does not prove an installed plugin can resolve its bundled files.
- Stage exact paths only. Never use `git add -A` or `git add .` in this repo.
