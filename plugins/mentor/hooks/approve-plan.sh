#!/usr/bin/env bash
# approve-plan.sh — validate the plan, release the plan gate.
#
# Run by the plan skill when the user makes an approval choice. Flags map 1:1
# to the approval options — the persisted repo mode is NOT read here; the
# user's explicit choice decides:
#   (no arg)   — approve: validate, release the gate, implementation begins;
#                points to planning's After Proceed directive.
#   --deliver  — approve, but the plan file is the DELIVERABLE: prints a
#                DELIVER-ONLY soft-stop directive (no implementation).
#   anything else — usage error, exit 1, marker untouched. (--handoff retired in
#                v4.2.0 with the approval step's "Hand off to next agent" option.)
#
# Marker resolution (v2.23.0 — per-worktree gates): this worktree's OWN marker
# (`.planning.<wt-id>`) is used if present. Otherwise, a live LEGACY bare
# `.planning` (the reserved pre-upgrade repo-wide marker) is used ONLY when its
# `session=` matches this session — a session that never armed the legacy
# marker must not be able to sweep the whole repo and delete another session's
# marker out from under it; a session/owner mismatch REFUSES instead, marker
# untouched. With neither marker present/live, this is the gate-already-open
# branch below. An empty wt-id (git failure, `.git/` cwd, bare repo) makes the
# own-marker path identical to the legacy path, so that case falls straight
# into the ordinary own-marker branch with no session check — unchanged
# pre-upgrade behavior.
#
# Validation (only while a marker is resolved above): the newest Markdown plan
# owned by this worktree (or unowned, when no sibling worktree marker is live)
# must have a Goal check and a parsed implementation step AND be newer than the resolved marker (the marker's mtime is
# the session start — begin-plan.sh — so a stale plan from a prior session can
# never release the gate). On failure the marker stays (gate CLOSED), exit 1.
# While ANY sibling worktree's marker is live, an unowned plan is excluded from
# both validation and the promotion sweep below (reported by name) — ownership
# stamping happens at plan-dir creation time but is model-followed, not
# hook-enforced, so it can't be trusted alone to tell two worktrees' drafts
# apart.
#
# Idempotent-directive rule: when the gate is already open, validation and
# release are skipped, but --deliver STILL prints its directive —
# a re-run must never silently downgrade a no-implementation instruction.
#
# Plan state (v2.4.0, widened v2.14.0): EVERY approval path — no-arg and --deliver —
# promotes this session's eligible plans to `approved` in their .state.json sidecars. Approval
# is approval: the flag only changes what happens NEXT (implement now / deliver), not
# whether the plan was approved. A flagged approval left at `draft` reads as "the gate
# never released" in the next session — but it did. See the promotion block for why the
# candidate set is snapshotted before the marker is deleted. Promotion also
# stamps `owner`/`owner_session` (this worktree) on any previously-unowned plan
# it promotes — see _promote_plan below.
#
# The promotion write is flag-style (`--state approved`, no other flags beyond
# --owner/--owner-session when stamping), so it never touches deps/group/order or any
# other sidecar field.

set -euo pipefail

flag="${1:-}"
case "$flag" in
  ""|--deliver) ;;
  *)
    echo "[mentor approve-plan] Unknown flag: ${flag}" >&2
    echo "Usage: approve-plan.sh [--deliver]" >&2
    echo "This script takes no plan argument — it releases the gate and promotes eligible" >&2
    echo "plans newer than the .planning marker. To approve ONE plan by slug, use:" >&2
    echo "  plan-state.sh set <slug> approved --note \"…\"" >&2
    exit 1
    ;;
esac

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"
cwd="$(pwd)"

repo_root="$(mentor_repo_root "$cwd")"
if [ -z "$repo_root" ]; then
  echo "[mentor approve-plan] Not in a git repo — nothing to release." >&2
  exit 1
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

wt_id="$(mentor_worktree_id "$cwd")"
this_session="${CLAUDE_CODE_SESSION_ID:-nosession}"
own_marker="$(mentor_plan_marker "$plans_dir" "$wt_id")"
legacy_marker="${plans_dir}/.planning"

# _newest_plan_strict_owned <plans_dir> <wt_id> — mentor_newest_plan_owned's exact walk
# (mtime-newest non-superseded plan.md, all-superseded fallback), but STRICT: an unowned
# plan dir is excluded too, not just a foreign-owned one. Used only while a sibling
# worktree's marker is live — ownership stamping is model-followed, not hook-enforced,
# so an unowned draft racing a live sibling can't be silently treated as this worktree's
# own (plan Design §4, [R]).
_newest_plan_strict_owned() {
  local plans_dir="$1" wt_id="$2" f owner newest=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    owner="$(mentor_plan_owner "$(dirname "$f")")"
    [ "$owner" = "$wt_id" ] || continue
    [ -n "$newest" ] || newest="$f"
    if [ "$(mentor_plan_effective_state "$(dirname "$f")")" != "superseded" ]; then
      echo "$f"; return 0
    fi
  done < <(ls -t "${plans_dir}"/*/plan.md 2>/dev/null || true)
  echo "$newest"
  return 0
}

# _excluded_owner_count <plans_dir> <wt_id> <strict> — how many plan.md files in
# <plans_dir> the CURRENT filtering (wt_id, plus "strict" = also exclude unowned) would
# NOT hand back as the candidate — i.e. foreign-owned always, plus unowned too when
# strict. Used only to explain a validation failure by name, never to gate anything.
_excluded_owner_count() {
  local plans_dir="$1" wt_id="$2" strict="$3" f owner cnt=0
  for f in "${plans_dir}"/*/plan.md; do
    [ -f "$f" ] || continue
    owner="$(mentor_plan_owner "$(dirname "$f")")"
    if [ "$strict" -eq 1 ]; then
      [ "$owner" = "$wt_id" ] || cnt=$((cnt + 1))
    else
      [ -n "$owner" ] && [ "$owner" != "$wt_id" ] && cnt=$((cnt + 1))
    fi
  done
  echo "$cnt"
  return 0
}

# _promote_plan <plan_dir> <note> — the one write path for every promotion below:
# always `--state approved`, always replaces the note (mentor_plan_state_write's
# documented "note always replaced" contract — "" clears it, same as omitting --note
# entirely). Additionally stamps `--owner <wt_id> --owner-session <this_session>` when
# the plan is currently unowned and this worktree has a real wt-id — "promotion
# additionally stamps owner on previously-unowned candidates" (plan Design §4).
_promote_plan() {
  local plan_dir="$1" note="$2"
  if [ -n "$wt_id" ] && [ -z "$(mentor_plan_owner "$plan_dir")" ]; then
    mentor_plan_state_write "$plan_dir" --state approved --owner "$wt_id" --owner-session "$this_session" --note "$note"
  else
    mentor_plan_state_write "$plan_dir" --state approved --note "$note"
  fi
}

_plan_complete() {
  grep -Eq '^##[[:space:]]+Goal check[[:space:]]*$' "$1" \
    && mentor_plan_step_scan "$1" | awk -F '\t' '$1 == "TOTAL" { found = ($2 > 0) } END { exit !found }'
}

marker=""
legacy_mode=0

if [ -f "$own_marker" ]; then
  marker="$own_marker"
elif [ -f "$legacy_marker" ] && ! mentor_marker_stale "$legacy_marker"; then
  legacy_session="$(mentor_marker_field "$legacy_marker" session)"
  if [ -n "$legacy_session" ] && [ "$legacy_session" = "$this_session" ]; then
    marker="$legacy_marker"
    legacy_mode=1
  else
    legacy_cwd="$(mentor_marker_field "$legacy_marker" cwd)"
    legacy_age="$(mentor_marker_age_min "$legacy_marker")"
    cat >&2 <<EOF
[mentor approve-plan] Refusing to approve through the legacy plan gate.
  marker:   ${legacy_marker}
  armed by: session ${legacy_session:-<unknown, pre-metadata marker>} at ${legacy_cwd:-<unknown cwd>}
  age:      ~${legacy_age:-unknown}m ago (not yet stale)

This is the pre-upgrade repo-wide marker — it blocks every worktree until its own
arming session approves it or it goes stale. This session (${this_session}) never
armed it, so approving here would sweep the whole repo AND delete another session's
marker out from under it. The marker is left untouched.

Ask the user to confirm before proceeding — either wait for the arming session to
approve, or have them explicitly authorize clearing ${legacy_marker}.
EOF
    exit 1
  fi
fi

# Sibling-liveness (own-marker mode only, real wt-id only): any OTHER live
# `.planning*` marker besides our own and the legacy one. Drives the strict
# unowned-exclusion below (plan Design §4, [R]) — irrelevant to legacy_mode
# (already unfiltered/repo-wide by design) and to an empty wt-id (pre-change
# behavior, see header).
sibling_live=0
strict=0
if [ -n "$marker" ] && [ "$legacy_mode" -eq 0 ] && [ -n "$wt_id" ]; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case "$m" in
      "$own_marker"|"$legacy_marker") continue ;;
    esac
    sibling_live=1
    break
  done < <(mentor_live_markers "$plans_dir")
  [ "$sibling_live" -eq 1 ] && strict=1
fi

# Plans written during THIS planning session — snapshotted BEFORE the marker is
# removed, because `[ a -nt b ]` and `find -newer b` are both TRUE when b is gone:
# asking "newer than the marker" after the release would match every plan dir in the
# repo, including months-old ones. Empty on the gate-already-open branch, which is
# correct — nothing was planned in this session, so nothing gets promoted.
newest_plan=""
newly_planned=""
unowned_skipped=""

if [ -n "$marker" ]; then
  filter_wt_id="$wt_id"
  [ "$legacy_mode" -eq 1 ] && filter_wt_id=""

  if [ "$strict" -eq 1 ]; then
    newest_plan="$(_newest_plan_strict_owned "$plans_dir" "$wt_id")"
  else
    newest_plan="$(mentor_newest_plan_owned "$plans_dir" "$filter_wt_id")"
  fi

  if [ -z "$newest_plan" ]; then
    excluded=0
    if [ -n "$wt_id" ] && [ "$legacy_mode" -eq 0 ]; then
      excluded="$(_excluded_owner_count "$plans_dir" "$wt_id" "$strict")"
    fi
    if [ "$excluded" -gt 0 ]; then
      echo "[mentor approve-plan] No plan owned by this worktree in ${plans_dir}." >&2
      if [ "$strict" -eq 1 ]; then
        echo "  (${excluded} plan(s) here are owned by another worktree or unowned while a sibling" >&2
        echo "   worktree's planning is active — re-own with /mentor:plan <slug>.)" >&2
      else
        echo "  (${excluded} plan(s) here are owned by another worktree — re-own with /mentor:plan <slug>.)" >&2
      fi
    else
      echo "[mentor approve-plan] No Markdown plan found in ${plans_dir}." >&2
    fi
    echo "plan not complete — finish planning Step 4: write the plan (<slug>/plan.md) before approving — the gate stays CLOSED." >&2
    exit 1
  fi

  # Staleness defense: the plan must be newer than the marker (i.e. written THIS
  # planning session). begin-plan never purges prior sessions' approved plans, so
  # "newest non-empty" alone would let a premature approve resurrect an old plan.
  if [ ! "$newest_plan" -nt "$marker" ]; then
    excluded=0
    if [ -n "$wt_id" ] && [ "$legacy_mode" -eq 0 ]; then
      excluded="$(_excluded_owner_count "$plans_dir" "$wt_id" "$strict")"
    fi
    echo "[mentor approve-plan] Newest plan predates this planning session:" >&2
    echo "  ${newest_plan}" >&2
    if [ "$excluded" -gt 0 ]; then
      if [ "$strict" -eq 1 ]; then
        echo "  (${excluded} plan(s) here are owned by another worktree or unowned while a sibling" >&2
        echo "   worktree's planning is active — re-own with /mentor:plan <slug> if one of" >&2
        echo "   those is yours.)" >&2
      else
        echo "  (${excluded} plan(s) here are owned by another worktree — re-own with /mentor:plan <slug>" >&2
        echo "   if one of those is yours.)" >&2
      fi
    fi
    echo "Write the plan for THIS session before approving — the gate stays CLOSED." >&2
    exit 1
  fi

  newly_planned="$(mentor_newly_planned "$plans_dir" "$marker" "$filter_wt_id")"

  # Strict mode: mentor_newly_planned's own filter keeps unowned candidates (its
  # contract is owner ∈ {wt_id, unset}) — pull those back out here and report them by
  # name instead of silently sweeping or silently dropping them.
  if [ "$strict" -eq 1 ] && [ -n "$newly_planned" ]; then
    filtered=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -z "$(mentor_plan_owner "$(dirname "$p")")" ]; then
        unowned_skipped="${unowned_skipped}$(basename "$(dirname "$p")") "
      else
        filtered="${filtered}${p}"$'\n'
      fi
    done <<<"$newly_planned"
    newly_planned="${filtered%$'\n'}"
  fi

  # A newer research skeleton cannot take approval from a finished plan. Keep
  # the existing ownership/freshness filters and superseded fallback, but choose
  # the newest COMPLETE candidate before releasing anything.
  complete_plan=""; complete_fallback=""; incomplete=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! _plan_complete "$p"; then
      incomplete="${incomplete}$(basename "$(dirname "$p")") "
      continue
    fi
    if [ -z "$complete_fallback" ] || [ "$p" -nt "$complete_fallback" ]; then
      complete_fallback="$p"
    fi
    [ "$(mentor_plan_effective_state "$(dirname "$p")")" != superseded ] || continue
    if [ -z "$complete_plan" ] || [ "$p" -nt "$complete_plan" ]; then
      complete_plan="$p"
    fi
  done <<<"$newly_planned"
  newest_plan="${complete_plan:-$complete_fallback}"
  if [ -z "$newest_plan" ]; then
    echo "[mentor approve-plan] plan not complete — finish planning Step 4; the gate stays CLOSED." >&2
    if [ -n "$incomplete" ]; then
      echo "  state: incomplete, skipped — needs ## Goal check and at least one implementation step — ${incomplete% }" >&2
    fi
    exit 1
  fi

  # Release the gate.
  rm -f "$marker" 2>/dev/null || true
  if [ "$legacy_mode" -eq 1 ]; then
    echo "[mentor approve-plan] Plan APPROVED — legacy repo-wide gate released. Repo edits are now allowed in every worktree."
  else
    echo "[mentor approve-plan] Plan APPROVED — gate released. Repo edits are now allowed."
  fi
  echo "  plan: ${newest_plan}"
  if [ "$legacy_mode" -eq 0 ] && [ -n "$wt_id" ] && [ -f "$legacy_marker" ] && ! mentor_marker_stale "$legacy_marker"; then
    echo "  WARNING: a legacy repo-wide marker is still live (${legacy_marker}) — it blocks edits"
    echo "  in EVERY worktree (including this one) until its own arming session approves it or it"
    echo "  goes stale. This worktree's own gate is released, but repo edits stay BLOCKED."
  fi
else
  # Idempotency: gate already open (already approved, or never armed). Skip
  # validation/release but still honor the flag directive below.
  #
  # No marker keeps no history once it's gone, so this branch can never know which
  # cause applies (another session's approve-plan.sh, plan-gate's stale self-heal, a
  # manual rm — or the gate was simply never armed this session, e.g. begin-plan.sh's
  # foreign-marker guard exiting 0 without arming). Name the
  # candidates instead of asserting one, and point at a command that actually
  # answers "did MY plan promote?" (`list`, not `query` — the latter is
  # JSON-only and repo-wide, the wrong shape here).
  newest_plan="$(mentor_newest_plan "$plans_dir")"
  echo "[mentor approve-plan] Gate is already open — nothing to release."
  echo "  (Could be: another session's approve-plan.sh, plan-gate's stale self-heal,"
  echo "   a manual rm, or the gate was never armed this session. If YOU planned this"
  echo "   session, check: bash \"${hook_dir}/plan-state.sh\" list — and if your plan is"
  echo "   still draft, promote it: plan-state.sh set <slug> approved --note \"…\"."
  echo "   Or this worktree was moved/renamed (\`git worktree move\` changes the worktree"
  echo "   id) — check plan-state.sh gate --verbose for a marker owned by a different"
  echo "   worktree id.)"
  [ -n "$newest_plan" ] && echo "  plan (repo-wide newest, may not be yours): ${newest_plan}"
fi

# Promote plan state on EVERY approval path — this must run before the --deliver
# early exit. `approved` records the user's decision; whether implementation happens
# now, in a later session, or never (deliver) is the directives' business. A stored `draft` reads as
# "the gate never released", so skipping promotion here falsely blocks the plan
# in the very next session.
#
# Only plans from $newly_planned are candidates (see the snapshot above), and only
# those whose effective state is `draft` or `unknown` — never `superseded` (a split
# parent's plan.md is also newer than the marker and would otherwise flip back),
# `implemented`, `failed` or `in_progress`. `unknown` is included because a plan
# written this session predates nothing: it just means Step 4 never ran `init`, and
# the approval should still land rather than depend on the model remembering.
# All candidates need a Goal check and a parsed implementation step;
# an abandoned research skeleton must remain draft rather than be swept to approved.
#
# Fail-soft throughout: every helper here exits 0, so a state-write problem can never
# turn a successful gate release into an error.
#
# Report the outcome on EVERY path, including both "nothing to do" paths. Silence is
# ambiguous: it reads identically to the promotion block never running at all (a stale
# cached plugin predating it), which is exactly how a plan left at `draft` after a
# successful-looking approval went unnoticed until the next session refused to build it.
# One `state:` line always prints, before the --deliver early exit below.
if [ -n "$newly_planned" ] || [ -n "$unowned_skipped" ]; then
  promoted=""; swept=""; incomplete=""; candidates=0
  while IFS= read -r plan_path; do
    [ -n "$plan_path" ] || continue
    candidates=$((candidates + 1))
    plan_dir="$(dirname "$plan_path")"
    case "$(mentor_plan_effective_state "$plan_dir")" in
      draft|unknown) ;;
      *) continue ;;
    esac
    if ! _plan_complete "$plan_path"; then
      incomplete="${incomplete}$(basename "$plan_dir") "
      continue
    fi
    if [ "$plan_path" = "$newest_plan" ]; then
      _promote_plan "$plan_dir" ""
      promoted="${promoted}$(basename "$plan_dir") "
    else
      # Swept in only because its plan.md is also newer than this session's marker
      # (e.g. a different topic touched earlier in the same planning session) — NOT
      # the plan this call is approving. Stamp the sidecar note (not just the stdout
      # line below) so a LATER session — deciding whether to build it, or grilling it —
      # still sees it wasn't individually reviewed, since the
      # promotion write already replaces whatever note was there (mentor_plan_state_write's
      # --note has no "omitted preserves" case) whether we set one or not.
      _promote_plan "$plan_dir" "swept in by approve-plan.sh — plan.md was newer than this session's .planning marker but this wasn't the plan being approved; not individually reviewed. Undo: plan-state.sh set $(basename "$plan_dir") draft"
      swept="${swept}$(basename "$plan_dir") "
    fi
  done <<<"$newly_planned"
  if [ -n "$promoted" ]; then
    echo "  state: approved — ${promoted% }"
  fi
  if [ -n "$swept" ]; then
    echo "  state: approved (also swept in — newer than this session's marker but not the plan being approved here; if you didn't mean to approve this one, verify it — plan-state.sh set <slug> draft to undo) — ${swept% }"
  fi
  if [ -n "$incomplete" ]; then
    echo "  state: incomplete, skipped — needs ## Goal check and at least one implementation step — ${incomplete% }"
  fi
  if [ -z "$promoted" ] && [ -z "$swept" ] && [ -z "$incomplete" ]; then
    echo "  state: unchanged — nothing needed promoting (${candidates} candidate(s), none in draft/unknown)"
  fi
  if [ -n "$unowned_skipped" ]; then
    echo "  state: unowned, skipped — sibling planning active; re-own via /mentor:plan <slug> — ${unowned_skipped% }"
  fi
else
  echo "  state: unchanged — no plans written this session, nothing to promote"
fi

# Read the resolved approval candidate afresh, without recording a mentor write:
# approval must preserve both plan.md and any evidence of an outside edit.
_approval_anchor() {
  local ticked total next title
  printf '\n  plan: %s\n' "${newest_plan:-(no plan file on record)}"
  if [ "$flag" != "--deliver" ]; then
    IFS=$'\t' read -r ticked total next title <<<"$(mentor_plan_scan_summary "$newest_plan")"
    if [ "$next" -gt 0 ]; then printf '  next: step %d/%d — %s\n' "$next" "$total" "$title"
    elif [ "$total" -gt 0 ]; then echo '  next: all steps ticked'
    else echo '  next: drafting'; fi
  fi
  if [ "$(mentor_plan_drift "$newest_plan")" = changed ]; then
    echo "  plan.md changed since mentor last wrote it — read it before editing it further"
  fi
  echo "  planning ended — edit gate released"
  if [ "$flag" != "--deliver" ]; then
    echo '  tick each step with `plan-state.sh tick` after saving verdicts/step-N.md → PASS row → record-write'
  fi
  return 0
}

if [ "$flag" = "--deliver" ]; then
  cat <<EOF

DELIVER-ONLY — plan APPROVED and gate released. The plan file is the deliverable:
  ${newest_plan:-(no plan file on record)}
Do NOT implement in this session.
Report where the plan lives and STOP. (The user can ask to proceed later — the
gate is already open.)
EOF
  _approval_anchor
  exit 0
fi

# v6.0.0 — the run marker. Proceed (no flag) starts an autonomous run: write
# .mentor/.run-<session_id> (slug= + started=) so plan-continue.sh, the Stop hook, keeps
# the session going while the plan's stored state is in_progress. --deliver exited
# above, so it never writes one. No session id (not under Claude Code) → no marker:
# the run loop is then the skill's prose rule alone. Pruned after 1440 minutes, the
# same pattern context-checkpoint.sh uses for its own markers.
run_slug=""
[ -n "${newest_plan:-}" ] && run_slug="$(basename "$(dirname "$newest_plan")")"
if [ "$this_session" != "nosession" ] && [ -n "$run_slug" ]; then
  run_state_dir="$(mentor_state_dir "$repo_root")"
  if [ -n "$run_state_dir" ]; then
    mkdir -p -m 700 "$run_state_dir" 2>/dev/null || true
    find "$run_state_dir" -maxdepth 1 -name '.run-*' -mmin +1440 -delete 2>/dev/null || true
    printf 'slug=%s\nstarted=%s\n' "$run_slug" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "${run_state_dir}/.run-${this_session}" 2>/dev/null || true
    echo "  run: marker written — the Stop hook keeps this session going while ${run_slug} is in_progress"
  fi
fi

# Point to the single full directive as the model resumes after the Bash call.
cat <<EOF

Run the plan until its Goal check passes — follow skills/planning/SKILL.md → "After Proceed".
  Verifier contract: skills/planning/references/verifier-contract.md.
  Completion sections: ## Verification, ## Done review, ## Goal check.
EOF

_approval_anchor
exit 0
