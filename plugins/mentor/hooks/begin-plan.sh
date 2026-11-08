#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before any
# drafting. It writes THIS WORKTREE's gate marker, `.planning.<wt-id>` (v2.23.0
# — one marker per git worktree, via lib/state.sh's mentor_worktree_id /
# mentor_plan_marker), or the legacy repo-global bare `.planning` when no
# worktree id can be derived — which CLOSES the edit gate (plan-gate.sh) for
# that worktree (or, for the legacy marker, every worktree) and clears stale
# sidecars from a prior planning session.
# It runs as a normal Bash call and is allowed precisely because the gate never
# matches Bash.
#
# The marker's mtime is the SESSION START: approve-plan.sh only accepts a plan
# file NEWER than the marker, so a stale plan from a prior session can never
# release the gate.
#
# Optional slug arg (any position): the slug this session is about to
# plan or re-plan (e.g. the slug named in `/mentor:plan <slug>`). Never
# required. It does two things:
#   • ALREADY APPROVED short-circuit: when that plan's stored state is
#     `in_progress` (whatever its ✅ ticks say — an all-ticked run still owes
#     its Verification, Goal check, Done review and delivery), or `approved`
#     with ticks that have not taken it past that, and it is owned by THIS
#     worktree (or unowned), print `ALREADY APPROVED: <slug>` and exit 0 WITHOUT arming —
#     no marker is written or touched. Re-arming would close the edit gate
#     on a plan that is already cleared for implementation, and nothing
#     newer than the fresh marker exists to release it again. Re-planning
#     stays one explicit step away: `plan-state.sh set <slug> draft`, re-run.
#     A plan owned by a DIFFERENT worktree falls through to arming as usual.
#   • Otherwise, warn in the ARMED banner when that slug is already owned by
#     a worktree with a live sibling marker.
#
# Optional --override-foreign-marker: re-arms past the foreign-marker guard
# below. NOT a way to skip the human confirm that guard demands — it is the
# supported command for acting on a confirm that already happened, so a
# session with an authorized "yes, override" has something safer to run than
# hand-deleting the marker file. A session was observed doing exactly that
# (`rm .planning.<wt-id> && begin-plan.sh`) after finding no supported route —
# a freelance delete skips this guard's own stranding check entirely, and is
# strictly worse than a flag that still prints it. Callers must obtain the
# confirm FIRST (same AskUserQuestion the guard's refusal message asks for),
# then re-run with this flag — never set it pre-emptively "just in case".
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

target_slug=""
override_foreign=0
for arg in "$@"; do
  case "$arg" in
    --override-foreign-marker) override_foreign=1 ;;
    *) target_slug="$arg" ;;
  esac
done

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan gate NOT armed (planning still proceeds)."
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

# --- worktree id + own marker (v2.23.0) -------------------------------------
# Every worktree gets its own gate marker so parallel sessions in DIFFERENT
# worktrees never block each other; two sessions in the SAME worktree still
# serialize on the one marker (unchanged, intentional). Empty wt_id (git
# failure, `.git/` cwds, bare repos) means our own marker IS the legacy path —
# mentor_plan_marker's one fallback site — which is exactly why the legacy
# guard below is skipped in that case (see its comment).
wt_id="$(mentor_worktree_id "$(pwd)")"
marker="$(mentor_plan_marker "$plans_dir" "$wt_id")"
legacy_marker="$(mentor_plan_marker "$plans_dir" "")"
toplevel="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)"

# --- context gate (plan start) ---------------------------------------------
# begin-plan gets no hook stdin, so mentor_context_verdict locates the session
# transcript itself and measures it. Warn-only (v4.2.0): a large context never stops
# the gate from arming — it prints a CONTEXT: line the plan skill surfaces to the user.
# The UserPromptSubmit gate never sees /mentor:plan (slash passthrough), so we check
# here. The same helper backs `plan-state.sh context`, so both entry points apply one
# policy.
# Fail-soft: unmeasurable → empty verdict → skip silently (like the not-a-repo grace).
context_warn=""
verdict="$(mentor_context_verdict "$repo_root" "$(pwd)")"
if [ -n "$verdict" ]; then
  read -r level tokens warn_at ask_at <<<"$verdict"
  case "$level" in
    HIGH)
      context_warn="CONTEXT: HIGH (~${tokens} tokens ≥ ${ask_at}) — over the limit: surface to the user and keep the plan lean; do not propose a preview."
      ;;
    WARN)
      context_warn="CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at}) — surface to the user."
      ;;
  esac
fi

# --- already-approved short-circuit -----------------------------------------
# See the header: an approved/in-progress plan owned here (or unowned) needs no
# gate — arming would block the implementation it is already cleared for.
# Runs BEFORE every guard and write below, so no marker is created, touched, or
# pruned on this path. Keyed on the STORED state, not the tick-derived effective
# one: ticks only ever advance effective state, so after the re-plan hint's
# `set <slug> draft` a partly-ticked plan would still read in_progress and the
# hint could never take effect. Stored in_progress short-circuits whatever the
# ticks say: a fully ticked run is still owed After Proceed step 6 onward, and
# re-arming would strand it. Only a stored `approved` plan whose effective state
# is already past it (implemented/failed/superseded, e.g. fully ticked) arms as
# before.
target_owner=""
if [ -n "$target_slug" ] && [ -d "${plans_dir}/${target_slug}" ]; then
  target_dir="${plans_dir}/${target_slug}"
  target_owner="$(mentor_plan_owner "$target_dir")"
  if [ -z "$target_owner" ] || [ "$target_owner" = "$wt_id" ]; then
    case "$(mentor_plan_state_stored "$target_dir"):$(mentor_plan_effective_state "$target_dir")" in
      approved:approved|approved:in_progress|in_progress:*)
        msg="ALREADY APPROVED: ${target_slug} — not arming the gate; follow skills/planning/SKILL.md → After Proceed. To re-plan instead: plan-state.sh set ${target_slug} draft, then re-run."
        [ "$(mentor_plan_effective_state "$target_dir")" = implemented ] &&
          msg="${msg} — run in progress (all steps ticked): resume at After Proceed step 6."
        echo "$msg"
        [ -n "$context_warn" ] && echo "$context_warn"
        exit 0
        ;;
    esac
  fi
fi

# --- legacy-marker guard (v2.23.0) ------------------------------------------
# A bare `.planning` (no worktree suffix) is a pre-upgrade repo-global marker,
# reserved to still block EVERY worktree until released or stale — fail-closed,
# because it may have been armed by a session this upgrade has no worktree
# attribution for. SKIPPED ENTIRELY when wt_id is empty: in that case our own
# marker already IS this same legacy path (mentor_plan_marker's one fallback
# site), so running this guard would refuse a session's own re-arm and turn
# the design back into an un-armable repo-global lock — the foreign-session
# guard below (which fail-softs on no session match) is what same-session
# re-arming depends on in that case.
if [ -n "$wt_id" ] && [ -f "$legacy_marker" ]; then
  if ! mentor_marker_stale "$legacy_marker"; then
    other_session="$(mentor_marker_field "$legacy_marker" session)"
    other_cwd="$(mentor_marker_field "$legacy_marker" cwd)"
    other_age="$(mentor_marker_age_min "$legacy_marker")"
    cat <<EOF
[mentor] Plan gate NOT armed — a legacy repo-wide plan gate marker is still active.
  marker:   ${legacy_marker}
  armed by: session ${other_session:-unknown} at ${other_cwd:-<unknown cwd>}
  age:      ~${other_age:-unknown}m ago (not yet stale)

This is a PRE-UPGRADE marker with no worktree attribution, so it fail-closed
blocks every worktree, not just this one. Wait for its owning session to
approve or release it, or ask the user to explicitly authorize removing
${legacy_marker} by hand.
EOF
    exit 0
  fi
  s_session="$(mentor_marker_field "$legacy_marker" session)"
  s_age="$(mentor_marker_age_min "$legacy_marker")"
  rm -f "$legacy_marker" 2>/dev/null || true
  echo "[mentor] Pruned stale legacy plan gate marker .planning (session ${s_session:-unknown}, age ~${s_age:-unknown}m) — released, proceeding."
fi

# --- foreign-marker guard -----------------------------------------------------
# begin-plan.sh used to truncate any existing marker unconditionally. If another
# session's plan was still being drafted (not yet approved), its plan.md silently
# stopped being newer than the marker the instant this ran, and approve-plan.sh
# would refuse it forever afterwards ("predates this planning session") — the
# other session's work stranded with no error until someone notices. Same-session
# re-arms are expected and harmless; only a marker armed by a genuinely DIFFERENT, still-live session is
# a collision worth stopping for. A marker with no metadata (pre-upgrade) or no
# session match can't be attributed — fail-soft, arm as before.
#
# This now operates on THIS WORKTREE's own marker (v2.23.0) — a linked
# worktree's session arms its own independent marker and never reaches this
# branch over another worktree's live session; only two sessions sharing the
# SAME worktree (or the empty-wt_id case, where "own marker" IS the legacy
# marker) still serialize here.
this_session="${CLAUDE_CODE_SESSION_ID:-nosession}"
if [ -f "$marker" ] && ! mentor_marker_stale "$marker"; then
  other_session="$(mentor_marker_field "$marker" session)"
  if [ -n "$other_session" ] && [ "$other_session" != "$this_session" ]; then
    other_cwd="$(mentor_marker_field "$marker" cwd)"
    other_age="$(mentor_marker_age_min "$marker")"
    if [ "$override_foreign" -eq 1 ]; then
      cat <<EOF
[mentor] Plan gate re-armed PAST a foreign marker via --override-foreign-marker.
  was armed by: session ${other_session} at ${other_cwd:-<unknown cwd>}
  age:          ~${other_age:-unknown}m ago (not yet stale)
  marker:       ${marker}

If that session's plan.md was not yet approved, its work may now be
stranded (approve-plan.sh will refuse it as "predates this planning
session"). This flag exists for a confirm the user already gave — never set
it pre-emptively. Proceeding.
EOF
    else
      cat <<EOF
[mentor] Plan gate NOT armed — another session's plan gate is already active.
  armed by: session ${other_session} at ${other_cwd:-<unknown cwd>}
  age:      ~${other_age:-unknown}m ago (not yet stale)
  marker:   ${marker}

Re-arming now would reset the marker: if that session's plan.md isn't approved
yet, approve-plan.sh will then refuse it ("predates this planning session"),
silently stranding its work. This marker is scoped to THIS worktree only — a
linked worktree's own session arms its own independent marker and is never
blocked by this one; this collision means another session shares THIS SAME
worktree (or no worktree id could be derived here at all).

Ask the user to confirm before proceeding — either wait for that session to
finish/approve, or, once they explicitly authorize overriding it, re-run this
exact command with --override-foreign-marker appended. Do not delete the
marker file by hand — that skips this stranding check entirely.
EOF
      exit 0
    fi
  fi
fi

mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "$plans_dir"
mentor_ensure_gitignore "$(mentor_state_dir "$repo_root")"

# --- stale sibling marker prune (v2.23.0) -----------------------------------
# Any OTHER worktree's `.planning.<wt-id>` marker gone stale is pruned here —
# by ANY worktree's arm, not just its own — so an abandoned sibling gate never
# outlives its usefulness. This IS releasing that sibling's gate, so per the
# never-release-silently doctrine (plan-gate.sh) it always prints a named
# notice. `2>/dev/null || true` guards the whole construct: mentor_ensure_
# private_dir above is fail-soft and may not have created plans_dir on an
# unwritable path, and a bare `find` on a missing dir aborts under this
# script's `set -e`. The glob `.planning.*` requires a dot-suffix after
# "planning" and so never matches the bare legacy `.planning` marker (handled
# above, not here) — verified. Our OWN marker is excluded too: if it happens
# to be stale, it's about to be overwritten below anyway, not "released".
while IFS= read -r stale; do
  [ -n "$stale" ] || continue
  [ "$stale" = "$marker" ] && continue
  suffix="${stale##*/.planning.}"
  s_session="$(mentor_marker_field "$stale" session)"
  s_age="$(mentor_marker_age_min "$stale")"
  rm -f "$stale" 2>/dev/null || true
  echo "[mentor] Pruned stale sibling plan gate marker .planning.${suffix} (session ${s_session:-unknown}, age ~${s_age:-unknown}m) — released."
done < <(find "$plans_dir" -maxdepth 1 -name '.planning.*' -mmin "+${MENTOR_PLAN_MARKER_STALE_MIN}" 2>/dev/null || true)

# One-shot migration (v2.2.0): flat <slug>.md → <slug>/plan.md. Longest slug
# first, kept from the original layout migration. Flat html files beside the
# old .md are left where they are (harmless, gitignored).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  slug="$(basename "$f" .md)"
  mentor_ensure_private_dir "$(mentor_state_dir "$repo_root")" "${plans_dir}/${slug}"
  mv -n "$f" "${plans_dir}/${slug}/plan.md" 2>/dev/null || true
done < <(ls "${plans_dir}"/*.md 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- || true)

# Clear ".opened" sidecars (dot-hidden beside plans; legacy flat ones swept
# too): plan paths are slug-derived, so a stale sidecar from a prior session
# would suppress plan-open.sh's first-creation open for the same slug.
# Ownership-scoped (v2.23.0): a plan dir owned by a DIFFERENT, still-live
# worktree must not have its sidecars swept out from under it — only unowned
# or THIS-worktree-owned plan dirs are cleared. Each plan dir is swept at its
# top level only, never recursively, so no other folder a plan dir holds is touched.
for pd in "$plans_dir"/*/; do
  [ -d "$pd" ] || continue
  pd="${pd%/}"
  pd_owner="$(mentor_plan_owner "$pd")"
  if [ -z "$pd_owner" ] || [ "$pd_owner" = "$wt_id" ]; then
    find "$pd" -maxdepth 1 \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true
  fi
done
# Legacy flat .opened (pre-v2.2.0 layout: <slug>.md.opened directly under
# plans_dir, no slug dir to carry ownership) — always cleared.
find "$plans_dir" -maxdepth 1 \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true

# Metadata body, not an empty file: session + cwd + worktree let a blocked
# agent (plan-gate.sh's deny path) tell "I armed this myself and forgot to
# approve" from "a different, still-live session/worktree owns this" without
# hand-rolled ls/find forensics. Nothing reads the marker's content besides
# mentor_marker_field/mentor_marker_age_min (every other reader uses
# -f/-e/-nt/-newer/-mmin), and mtime — the field approve-plan.sh's staleness
# check depends on — is still set by this one write, same as `: >` before it.
{
  echo "session=${this_session}"
  echo "cwd=$(pwd)"
  echo "worktree=${toplevel}"
} > "$marker"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${marker}
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions); this marker is
          scoped to THIS worktree only.

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

# Informational sibling-marker lines (v2.23.0) — a live marker in another
# worktree never blocks THIS worktree's gate, but the model should still know
# it exists. Additionally, when $1 named a slug that ALREADY exists and is
# owned by that sibling worktree, WARN of a same-slug collision — this is the
# protection the old repo-global guard used to provide for free, now that
# siblings arm independently.
# target_owner was resolved by the already-approved short-circuit above.
while IFS= read -r lm; do
  [ -n "$lm" ] || continue
  [ "$lm" = "$marker" ] && continue
  s_suffix="${lm##*/.planning.}"
  s_session="$(mentor_marker_field "$lm" session)"
  s_age="$(mentor_marker_age_min "$lm")"
  echo "  also armed elsewhere: ${s_suffix} (session ${s_session:-unknown}, age ${s_age:-unknown}min) — independent gate, does not block this worktree"
  if [ -n "$target_owner" ] && [ "$s_suffix" = "$target_owner" ]; then
    echo "  WARNING: slug '${target_slug}' is owned by worktree ${target_owner}, whose marker .planning.${s_suffix} is live — two worktrees may be drafting the same slug concurrently."
  fi
done < <(mentor_live_markers "$plans_dir")

[ -n "$context_warn" ] && echo "$context_warn"

exit 0
