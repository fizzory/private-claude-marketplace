# Playbook index

Use this index when planning selects playbooks or resumes a saved plan. Read each
selected file as a reference, without invoking a playbook skill. Paths are relative
to this index; match the requested deliverable, not incidental implementation work.

| Name | Loads when… | File |
|---|---|---|
| software-change | Loads when the requested plan deliverable is a change to a repository's code, tests, config, dependencies or CI, such as a bug fix or feature. | [playbooks/software-change.md](playbooks/software-change.md) |
| retrospective | Loads when the requested plan deliverable is lessons from a finished agent session, applied as local skill changes with remaining proposals reported. Incidental code or skill edits do not make a retrospective a software-change goal; these two playbooks are incompatible. | [playbooks/retrospective.md](playbooks/retrospective.md) |
| investigation | Loads when the requested plan deliverable is a cited answer to a how/why question about how an artifact works or is; a written report or brief for an audience stays on the general flow with no playbook. A how/why question outside a plan loads nothing; an implementation or prototype is a different deliverable. | [playbooks/investigation.md](playbooks/investigation.md) |
| hillclimb | Loads when the requested plan deliverable is sustained improvement of a named metric against a target through measured attempts. A plain fix with no metric does not load it. Combine with software-change only when the deliverable changes software; software-change then owns delivery. | [playbooks/hillclimb.md](playbooks/hillclimb.md) |
| prototype | Loads when the plan goal is the prototype itself: variants plus observed comparison evidence so the human can pick. Never loads for a mid-plan fork; a bare “mock it up” request goes to previewing. Incidental prototype code does not load software-change and is never shipped. | [playbooks/prototype.md](playbooks/prototype.md) |

## Released selections

Resolve the released alias `playbook-software-change` to **software-change**, and
`playbook-retrospective` to **retrospective**. Read a saved selection either inline
after `## Playbook:` or on the next non-empty line after `## Playbook`, for example:

```markdown
## Playbook: playbook-software-change
```

```markdown
## Playbook

playbook-retrospective
```

Both aliases work in either format. Resolve them through the current index and
leave old plans unchanged, so moving a playbook does not invalidate prior approval.
