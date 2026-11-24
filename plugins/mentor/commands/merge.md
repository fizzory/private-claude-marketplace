---
description: Watch a PR's CI checks, triage a failure once, merge on green (gated)
argument-hint: "[PR#]"
allowed-tools: [Bash, Read, Grep, Skill, AskUserQuestion]
---

# mentor — merge

Invoke `Skill({"skill": "mentor:merging"})` and follow it end to end: it resolves
the open PR for the current branch (or `$ARGUMENTS` as a PR number), runs one
bounded `gh pr checks --watch`, triages a failure once — a job no runner started,
flake, this diff's regression, or rot already on the base branch — has an independent
verifier grade the PR, and merges only on your explicit choice (or under a constitution
that grants merge), then walks the runbook's after-merge steps.


$ARGUMENTS
