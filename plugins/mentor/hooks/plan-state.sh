#!/usr/bin/env bash
# plan-state.sh — the ONE plan-state API. Read and write .mentor/plans/<slug>/.state.json
# (and, via `tick`, the ✅ step marks in plan.md that the sidecar's effective state derives from).
#
# Not a hook: skills call it as a plain Bash command, like approve-plan.sh.
# It exists so no skill ever hand-rolls the sidecar JSON, and so the three places
# that used to resolve "the current plan" with their own `ls -t` share one answer.
#
# v2.23.0: the plan-gate marker is per-worktree (`.planning.<wt-id>`, one per linked
# worktree, legacy bare `.planning` reserved repo-global — see `gate` below and
# lib/state.sh's state-layout header); plans stay SHARED across every worktree,
# tracked by an `owner`/`owner_session` pair on the sidecar (stamped by ensure-dir/
# init/relocate — see `current --any`, `list --owners`, and `query`'s `owner` field).
#
# v5.0.0: every sidecar write MERGES into the existing object (lib/state.sh,
# mentor_plan_state_write), so keys this script no longer manages — a pre-5.0
# sidecar's origin/parent/priority/category/deferred_from — are left in place, unread.
#
#   init <slug> [--group G] [--order N] [--deps a,b]
#       Create the sidecar as `draft`. Idempotent and never LOWERS an existing
#       state — re-running it on an approved plan keeps it approved. --deps sets the
#       initial dependency slugs (cycle-checked, same as set-deps).
#
#   start <slug> [any init flag]
#       ensure-dir + init in ONE call; prints only the plan.md path on stdout.
#
#   set <slug> <state> [--note "…"]
#       Upsert (create-then-set): most plans predate the sidecar. <state> is one of
#       draft approved in_progress implemented failed superseded.
#       The note is REPLACED every time, so a plain `set` clears a stale failure note.
#
#   set-deps <slug> a,b
#       Replace <slug>'s deps wholesale with the given comma-separated plan slugs
#       (empty string clears them). Unknown slugs are allowed — the dep plan may be
#       written later. Refuses a write that would create a dependency cycle (direct
#       self-cycle or transitive): fail-soft, stderr warning, no write.
#
#   tick <slug> <N>
#       Append ✅ to the Nth step line in plan.md's `## Implementation steps` section
#       (idempotent — already-ticked is a no-op) — replaces hand-rolling an Edit to
#       find and mark that exact line, whose placement is load-bearing (a tick on
#       the wrong line reads as the step never having started). No such step at N →
#       fails loud, no write. New ticks require a saved PASS verdict (canonical,
#       else legacy); refusal names the file and fix. Reports drift before editing,
#       then records the new hash on success. Tick still works without jq or sha256.
#
#   record-write <slug>
#       Record plan.md's current sha256, preserving every other sidecar key.
#       Idempotent, never edits plan.md; a missing plan is an error.
#
#   drift <slug>
#       known|changed|unknown compared with the last tracked write. Read-only;
#       legacy sidecars and an unavailable sha256 tool read unknown.
#
#   list [--group G] [--owners]
#       One row per plan: ordinal, EFFECTIVE state, slug, group, order — and, with
#       --owners, a 6th OWNER column (the wt-id from the sidecar, "-" when unowned).
#       Grouped, ordered within a group, `superseded` and `unknown` last. The default
#       5-column shape is byte-compatible with pre-2.23.0 output.
#
#   current [--any]
#       The current plan, scoped to plans OWNED by THIS worktree (or unowned) — a
#       write target must never resolve to a sibling worktree's in-flight draft.
#       --any drops the filter for a deliberate, repo-wide read. Skips superseded.
#       When the answer belongs to a split group it prints the whole group and says
#       so, instead of silently picking one of N children.
#
#   query [select] [filter] [output]
#       The ONE filterable read surface. Repo-wide JSON array by default: one object
#       per plan dir with a plan.md — {kind: "plan", slug, state (effective), group,
#       order, owner, deps: [{slug, missing}], steps: {ticked, total}}. `missing` is
#       true when no such plan dir exists, so a consumer never re-resolves a dep
#       against the array by hand.
#
#       select   --slug S          just that plan
#       filter   --state --open --closed --group --owner W --unowned --deps-missing
#                --match GLOB
#                AND-combined; a comma-separated value ORs within that ONE flag.
#                "open" means effective state NOT in {implemented, superseded}.
#       output   --format json|table|slug|count|tsv   (json default)
#                --fields a,b      dot paths (steps.total, owner); tsv/table render
#                                   null as `-`
#                --sort F --limit N
#
#       A fixed ~3 subprocesses scan every sidecar and plan.md regardless of plan count.
#
#   context
#       CONTEXT: HIGH|WARN|OK|UNKNOWN (~N tokens) — advisory only, every level proceeds.
#       context-gate.sh passes every slash-prefixed prompt, so a slash command that
#       starts an implementation would otherwise get no reading.
#
#   dir [--plans]
#       The repo-scoped mentor dir (<repo_root>/.mentor via git-common-dir, so linked
#       worktrees share one; mentor_no_repo_state_dir outside a repo) — one path on
#       stdout. Skills call this instead of hand-rolling the derivation: the inlined
#       copies drifted, and most dropped the no-repo fallback.
#
#   gate [--verbose]
#       ARMED|STALE|ARMED_ELSEWHERE|RELEASED — exactly one token on stdout (line 1,
#       always — bare `gate` and `gate --verbose` alike), reporting the plan-gate
#       marker's status for THIS worktree (v2.23.0 — one `.planning.<wt-id>` marker
#       per worktree; see lib/state.sh's state-layout header for the full scheme):
#         ARMED           this worktree's OWN marker is live, or the legacy repo-
#                          global `.planning` marker is live (it blocks every
#                          worktree) — a write HERE would be denied right now.
#         STALE           the own or legacy marker exists but is older than
#                          MENTOR_PLAN_MARKER_STALE_MIN (lib/state.sh, ~8h) —
#                          plan-gate.sh/begin-plan.sh haven't pruned/healed it yet,
#                          but every other caller already reads it as not-armed.
#         ARMED_ELSEWHERE no own/legacy marker at all, but a SIBLING worktree's
#                          marker is live — an independent gate; it does not block
#                          writes here.
#         RELEASED        no marker at all (outside a repo — the `_no-repo`
#                          fallback — always reads RELEASED too).
#       This answers "is the gate armed HERE", not "should it be" — a caller that
#       instead needs "we're inside a repo and planning should have started" wants
#       a different check.
#       READ-ONLY: gate never deletes or heals a marker. That stays true even though
#       it is no longer the ONLY thing that could remove one — two removers exist now
#       (plan-gate.sh's self-heal on a would-deny write, and begin-plan.sh's stale-
#       sibling prune on arm), each printing its own named notice before removing
#       anything, so a marker is never released silently; gate must never become a
#       third, silent one.
#       --verbose is strictly additive: bare `gate` is unchanged (callers'
#       `[ "$(… gate)" = "ARMED" ]` string-equality checks depend on staying exactly
#       one token — and on ARMED_ELSEWHERE reading as "not armed for me" by that same
#       equality check). The per-token field contract below is
#       NORMATIVE — exactly these fields, nothing else:
#         ARMED           marker= owner_session= owner_cwd= owner_worktree=
#                          age_min= affected_plans= — the mentor_marker_field/
#                          mentor_marker_age_min facts plan-gate.sh's own deny
#                          message already computes, plus the mentor_newly_planned
#                          slugs approve-plan.sh would promote to `approved` if run
#                          right now (unfiltered when the armed marker is the legacy
#                          one — mirrors approve-plan.sh's legacy_mode, which is
#                          unfiltered too).
#         ARMED_ELSEWHERE one `elsewhere=<wt-id> session=<sid> worktree=<path>
#                          age_min=<n>` line per live sibling marker, nothing else.
#         STALE/RELEASED  bare token only — there is no "owner" to report.
#
# EFFECTIVE state (see lib/state.sh): the more advanced of the stored state and the
# state derived from plan.md's ✅ step ticks. A forgotten `set` therefore costs
# nothing, and a pre-2.4.0 plan dir with no sidecar reads `unknown` — never `draft`.
#
# Exit codes: 1 for a usage error (unknown subcommand, bad state, missing/unknown
# slug) — mirroring approve-plan.sh. Everything environmental is fail-soft: no repo,
# no plans dir, no jq, nothing to report → empty stdout, ONE reason line on stderr,
# exit 0. Silent-empty would be indistinguishable from "no plans" and the calling
# skill would improvise a listing. Exceptions: drift prints unknown without a
# registry; record-write needs an existing plan and exits 1 without a repo/registry.

set -euo pipefail

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${hook_dir}/lib/state.sh"

# record_plan_write <plan_md> — hash-only merge shared by record-write and tick.
# Keep this write behind the CLI: PostToolUse calls record-write rather than
# becoming another sidecar writer. Lifecycle writes replace note, so cannot be
# reused here without changing unrelated sidecar fields.
record_plan_write() {
  local md="$1" digest sidecar source tmp
  digest="$(mentor_plan_sha256 "$md")"
  [ -n "$digest" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  sidecar="$(mentor_plan_state_file "$(dirname "$md")")"
  [ "$(mentor_plan_state_field "${md%/*}" plan_sha256)" != "$digest" ] || return 0
  source=/dev/null
  [ ! -f "$sidecar" ] || source="$sidecar"
  tmp="$(mktemp "${sidecar}.tmp.XXXXXX" 2>/dev/null)" || return 0
  if jq -s --arg digest "$digest" '
      (.[0] | if type == "object" then . else {} end) + {plan_sha256: $digest}
    ' "$source" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$sidecar" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# warn_same_slug_collision <plan_dir> <this_wt_id> <plans_dir> — stderr WARNING when
# <plan_dir> already exists AND its sidecar `owner` is a DIFFERENT worktree whose own
# marker is currently live: two worktrees drafting the same slug is reachable now that
# the gate is per-worktree (the old repo-global marker used to make this impossible —
# see begin-plan.sh's matching same-slug WARN on the arm side). Never blocks —
# informational only. Called from both `ensure-dir` (mint time) and `init` (re-own
# time), defined here (ahead of both) so `ensure-dir`'s early-exit block can reach it
# too. Skipped entirely when <this_wt_id> is empty — without a wt-id of our own there
# is nothing meaningful to compare against.
warn_same_slug_collision() {
  local plan_dir="${1:-}" this_wt="${2:-}" pdir="${3:-}" other other_marker
  [ -n "$plan_dir" ] && [ -d "$plan_dir" ] && [ -n "$this_wt" ] || return 0
  other="$(mentor_plan_owner "$plan_dir")"
  [ -n "$other" ] && [ "$other" != "$this_wt" ] || return 0
  other_marker="$(mentor_plan_marker "$pdir" "$other")"
  if [ -e "$other_marker" ] && ! mentor_marker_stale "$other_marker"; then
    echo "[mentor plan-state] WARNING: $(basename "$plan_dir") is already owned by worktree ${other}, whose plan gate is currently live — two worktrees may be drafting the same slug. Coordinate with that worktree, or pick a different slug." >&2
  fi
  return 0
}

usage() {
  cat <<'EOF'
Usage: plan-state.sh <subcommand>
  init <slug> [--group G] [--order N] [--deps a,b]
                                         create the sidecar as draft (idempotent)
  start <slug> [any init flag]          ensure-dir + init in ONE call; echoes the plan.md
                                         path. The plan-write path — replaces the two-call
                                         sequence and its re-derive footguns
  set <slug> <state> [--note "…"]       state: draft|approved|in_progress|implemented|failed|superseded
  set-deps <slug> a,b                   replace deps wholesale (cycle-checked, fail-soft)
  tick <slug> <N>                       append ✅ to step N in plan.md (idempotent, fails loud)
  record-write <slug>                   record plan.md's sha256; preserve all other sidecar keys
  drift <slug>                          known|changed|unknown since the last tracked write (read-only)
  verify <slug>                         plan.md structural checks (fence balance, table pipe-count,
                                         step bodies each carrying a Done when:, a draft plan's
                                         ## Goal check + ## Decision log, Rev-note order,
                                         stray ✅ / ### inside the steps section) + a folded CONTEXT
                                         read, as CHECK: lines; exit 1 iff a GATING check fails
                                         (Rev-order, context, stray ✅, ### and untraced steps
                                         in a stored draft are informational)
  list [--group G] [--owners]           every plan with its effective state (--owners adds OWNER)
  current [--any]                       the current plan, owned-by-this-worktree scoped (group-aware);
                                         --any for a deliberate repo-wide read
  query [select] [filter] [output]      the ONE filterable read surface. Repo-wide JSON by default:
                                         slug, state, group, order, owner, deps ({slug, missing}),
                                         step counts.
    select   --slug S
    filter   --state S --open --closed --group G --owner W --unowned --deps-missing --match GLOB
             (AND-combined; a comma-separated value ORs within that one flag)
    output   --format json|table|slug|count|tsv   (default json)
             --fields a,b         dot paths, e.g. steps.total, owner
             --sort F --limit N
  sweep <pattern> [--roots plans|repo] [--ignore-case]
                                        the ONE portable search over mentor's own state.
                                         Prints `SWEEP: roots=N files=N hits=N` FIRST, then
                                         one `path:line:text` per hit. Exits like grep:
                                         0 hits found / 1 files read but no match /
                                         2 NOTHING-SEARCHED (no root existed) or a usage
                                         error. roots: plans = the main repo's .mentor/plans
                                         (default); repo = the whole worktree minus .git/.
                                         find walks so grep never applies .gitignore —
                                         gitignored .mentor/ IS reached
  context                               CONTEXT: HIGH|WARN|OK|UNKNOWN (~N tokens)
  dir [--plans]                         the repo-scoped mentor dir (or its plans dir)
  gate [--verbose]                      ARMED|STALE|ARMED_ELSEWHERE|RELEASED — read-only marker
                                         status for THIS worktree (--verbose adds per-token fields;
                                         see the gate doc comment above for the exact contract)
  ensure-dir <path>                     mkdir it + chmod 700 the whole path; echoes it
  relocate <src-plan-dir>                copy a plan from a DIFFERENT repo's
                                         .mentor/plans/<slug> into THIS repo (run
                                         from the destination repo) and re-own it
                                         here; never deletes the source
EOF
}

sub="${1:-}"
[ "$#" -gt 0 ] && shift

# --- context: the only subcommand that needs neither a repo nor a plans dir ---
if [ "$sub" = "context" ]; then
  ctx_repo="$(mentor_repo_root "$(pwd)")"
  verdict="$(mentor_context_verdict "$ctx_repo" "$(pwd)")"
  if [ -z "$verdict" ]; then
    echo "CONTEXT: UNKNOWN (not measurable — gate off, or no transcript/jq). Proceed."
    exit 0
  fi
  read -r level tokens warn_at ask_at <<<"$verdict"
  case "$level" in
    HIGH)
      echo "CONTEXT: HIGH (~${tokens} tokens ≥ ${ask_at})"
      echo "[mentor] Over the limit — surface this to the user, then proceed. Keep the"
      echo "work in this session small and lean."
      ;;
    WARN)
      echo "CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at})"
      echo "[mentor] Session is getting large — surface this to the user, then proceed."
      ;;
    *)
      echo "CONTEXT: OK (~${tokens} tokens)"
      ;;
  esac
  exit 0
fi

# --- dir: pure path derivation — needs neither a repo (fallback) nor a plans dir ---
if [ "$sub" = "dir" ]; then
  dir_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$dir_repo" ]; then
    mdir="$(mentor_state_dir "$dir_repo")"
  else
    mdir="$(mentor_no_repo_state_dir)"
  fi
  if [ "${1:-}" = "--plans" ]; then
    echo "${mdir}/plans"
  else
    echo "$mdir"
  fi
  exit 0
fi

# --- ensure-dir: create a mentor artifact dir and lock the whole path to 700 ---
# Skills call this instead of `mkdir -p -m 700`, which cannot deliver what it promises
# (see mentor_ensure_private_dir). Echoing the path lets a snippet read
# `d="$(plan-state.sh ensure-dir "$d")"`, so a failure kills the pipeline before the write
# rather than silently leaving the dir wide open.
if [ "$sub" = "ensure-dir" ]; then
  ed_target="${1:-}"
  if [ -z "$ed_target" ]; then
    echo "[mentor plan-state] ensure-dir needs a directory path." >&2
    exit 1
  fi
  ed_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$ed_repo" ]; then
    ed_mdir="$(mentor_state_dir "$ed_repo")"
  else
    ed_mdir="$(mentor_no_repo_state_dir)"
  fi
  # Confine it. Callers substitute a model-chosen <topic> into the path, so without this
  # check ensure-dir would be an arbitrary mkdir-and-chmod primitive reachable from a
  # prompt. Compare canonically so `..` cannot walk out.
  ed_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ed_target" 2>/dev/null || echo "$ed_target")"
  ed_base="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ed_mdir" 2>/dev/null || echo "$ed_mdir")"
  case "$ed_canon" in
    "$ed_base"|"$ed_base"/*) ;;
    *)
      echo "[mentor plan-state] ensure-dir refuses a path outside ${ed_mdir}: ${ed_target}" >&2
      exit 1
      ;;
  esac
  # A direct child of plans/ is a plan TOPIC dir — the first of the three owner-
  # stamping sites (ensure-dir/init/relocate — see the state-layout header
  # comment and this file's top-of-file v2.23.0 note), because the normal flow writes plan.md
  # before Step 4's `init`, which is routinely skipped (approve-plan.sh) — leaving
  # the plan unowned in between is exactly the window this closes. The collision
  # check runs BEFORE the stamp below, so it still sees whatever owner (if any) was
  # on record before this call claims it.
  ed_plans="${ed_mdir}/plans"
  ed_wt_id=""
  if [ "$(dirname "$ed_canon")" = "$ed_plans" ]; then
    ed_wt_id="$(mentor_worktree_id "$(pwd)")"
    warn_same_slug_collision "$ed_canon" "$ed_wt_id" "$ed_plans"
  fi
  mentor_ensure_private_dir "$ed_mdir" "$ed_canon"
  if [ -n "$ed_wt_id" ]; then
    mentor_plan_state_write "$ed_canon" --owner "$ed_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}"
  fi
  echo "$ed_canon"
  exit 0
fi

# --- relocate <src-plan-dir>: copy a plan from a DIFFERENT repo into this one and
# re-own it here. Run from the DESTINATION repo. Sits here (before the plans_dir
# gate below, alongside ensure-dir) rather than in the main case block precisely
# BECAUSE it must work in a destination repo that has no plans dir yet — the
# whole point of relocating a plan into a repo mentor has never tracked before —
# and the main case block's `[ ! -d "$plans_dir" ]` guard would fail-soft-exit
# before ever reaching a case arm placed there. Deliberately narrow: every write
# this makes stays inside THIS repo's own already-confined mentor dir (the source
# is only ever READ, via `cp -R`), so it needs none of ensure-dir's path-
# confinement guard against the source — that guard exists to stop a model-chosen
# path from escaping THIS repo's .mentor tree, which cannot happen here since
# nothing is ever written under the source path. The source plan is never deleted
# (a two-repo `mv` has no atomic rollback if the copy side fails partway), so the
# caller removes it by hand once they've confirmed the copy landed.
if [ "$sub" = "relocate" ]; then
  rl_src="${1:-}"
  if [ "$#" -gt 1 ]; then
    echo "[mentor plan-state] relocate: unexpected argument ${2}" >&2
    exit 1
  fi
  if [ -z "$rl_src" ]; then
    echo "[mentor plan-state] relocate needs <src-plan-dir> — the OTHER repo's <slug> plan directory (…/.mentor/plans/<slug>). Run this from the DESTINATION repo." >&2
    exit 1
  fi
  # No require_jq here (unlike the main-case-block subcommands) — this block runs
  # BEFORE require_jq's own definition is reached in the file, same constraint
  # ensure-dir already lives with. mentor_plan_state_write/_stored/
  # _field all fail-soft on a missing jq internally, same as ensure-dir's stamp.
  rl_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$rl_repo" ]; then
    rl_mdir="$(mentor_state_dir "$rl_repo")"
  else
    rl_mdir="$(mentor_no_repo_state_dir)"
  fi
  rl_src_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$rl_src" 2>/dev/null || echo "$rl_src")"
  rl_src_parent="$(dirname "$rl_src_canon")"
  if [ ! -d "$rl_src_canon" ] || [ "$(basename "$rl_src_parent")" != "plans" ] \
     || [ "$(basename "$(dirname "$rl_src_parent")")" != ".mentor" ]; then
    echo "[mentor plan-state] relocate refuses a source that isn't an existing <repo>/.mentor/plans/<slug> directory: ${rl_src}" >&2
    exit 1
  fi
  if [ ! -f "${rl_src_canon}/plan.md" ] || [ ! -f "${rl_src_canon}/.state.json" ]; then
    echo "[mentor plan-state] relocate refuses ${rl_src_canon} — missing plan.md or .state.json (not a real plan dir)." >&2
    exit 1
  fi
  rl_slug="$(basename "$rl_src_canon")"
  rl_dst="${rl_mdir}/plans/${rl_slug}"
  rl_dst_canon="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$rl_dst" 2>/dev/null || echo "$rl_dst")"
  if [ "$rl_dst_canon" = "$rl_src_canon" ]; then
    echo "[mentor plan-state] relocate: source and destination are the same directory — nothing to do." >&2
    exit 1
  fi
  if [ -e "$rl_dst" ]; then
    echo "[mentor plan-state] relocate refuses — ${rl_dst} already exists. Pick a different slug in the destination, or remove/merge it by hand first." >&2
    exit 1
  fi
  rl_wt_id="$(mentor_worktree_id "$(pwd)")"
  # Collision check reads whatever owner is on record for the (not-yet-created)
  # destination slug — a no-op today (it always returns 0 before $rl_dst exists),
  # kept for the same TOCTOU-race defense ensure-dir/init keep it for.
  warn_same_slug_collision "$rl_dst" "$rl_wt_id" "${rl_mdir}/plans"
  # Ensure the PARENT (plans/) exists + is 700 — but NOT $rl_dst itself: `cp -R src
  # dst` copies src's CONTENTS into dst only when dst does not yet exist; if dst is
  # already a directory, cp nests src one level deeper instead (dst/$(basename src)),
  # which would silently land plan.md/.state.json a level too deep and desync every
  # path this subcommand computes below it.
  mentor_ensure_private_dir "$rl_mdir" "${rl_mdir}/plans"
  if ! cp -R "$rl_src_canon" "$rl_dst" 2>/dev/null; then
    echo "[mentor plan-state] relocate: copy from ${rl_src_canon} to ${rl_dst} failed — nothing was moved; check permissions/disk space." >&2
    rm -rf "$rl_dst" 2>/dev/null || true
    exit 1
  fi
  chmod 700 "$rl_dst" 2>/dev/null || true
  # Third of the three owner-stamping sites (see this file's top-of-file v2.23.0
  # note): re-owns the copied sidecar to THIS worktree, same last-init-wins shape
  # as `init` — preserves whatever state/deps/other keys the copy carried over (the
  # `cp -R` above already copied `.state.json` byte for byte, and the write merges),
  # only overwriting owner/owner_session.
  rl_existing="$(mentor_plan_state_stored "$rl_dst")"
  rl_write_args=(--state "${rl_existing:-draft}" --note "$(mentor_plan_state_field "$rl_dst" note)")
  if [ -n "$rl_wt_id" ]; then
    rl_write_args+=(--owner "$rl_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
  fi
  mentor_plan_state_write "$rl_dst" "${rl_write_args[@]}"
  echo "[mentor plan-state] ${rl_slug}: relocated from ${rl_src_canon} → ${rl_dst}; re-owned to this worktree ($(mentor_plan_effective_state "$rl_dst"))."
  echo "[mentor plan-state] source NOT deleted — remove ${rl_src_canon} yourself once you've confirmed the copy."
  # Under this file's `set -euo pipefail`,
  # `grep` finding ZERO matches — the COMMON case, whenever plan.md has no
  # "Suggested first steps" section or none of its lines look like a path — exits
  # 1, and `pipefail` propagates that through `head` to this bare assignment, which
  # aborts the whole `relocate` under `set -e` before ever reaching the two
  # WARNINGs below. Same class of pitfall the `verify`
  # subcommand's own comment already documents and guards with `|| true` — applying
  # the identical guard here, since this dead-ended `relocate` in exactly the case
  # this line exists to warn about being ABSENT (a plan with nothing stale to flag).
  rl_stale_hits="$(awk '/^## Suggested first steps/{f=1;next} /^## /{f=0} f' "${rl_dst}/plan.md" 2>/dev/null \
    | grep -noE '[[:alnum:]_.-]+/[[:alnum:]/_.-]+' | head -20 || true)"
  if [ -n "$rl_stale_hits" ]; then
    echo "[mentor plan-state] WARNING: plan.md's Suggested first steps still names repo-relative paths that may be stale after this move:" >&2
    printf '%s\n' "$rl_stale_hits" | sed 's/^/  /' >&2
  fi
  echo "[mentor plan-state] WARNING: if the source repo's plan-gate marker is still armed for this plan, its gate will not protect edits made back there — check with 'plan-state.sh gate --verbose' in the source repo." >&2
  exit 0
fi

# --- gate: read-only plan-gate marker status — needs neither a repo (fallback) nor a
# plans dir, same as dir/ensure-dir above. Never deletes a marker itself — see the doc
# comment near the top of this file for the full token contract and why gate must
# never become a third (silent) remover alongside plan-gate.sh's self-heal and
# begin-plan.sh's stale-sibling prune.
if [ "$sub" = "gate" ]; then
  g_verbose=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verbose) g_verbose=1; shift ;;
      *) echo "[mentor plan-state] gate: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
    esac
  done
  g_repo="$(mentor_repo_root "$(pwd)")"
  if [ -n "$g_repo" ]; then
    g_mdir="$(mentor_state_dir "$g_repo")"
  else
    g_mdir="$(mentor_no_repo_state_dir)"
  fi
  g_plans="${g_mdir}/plans"
  g_wt_id="$(mentor_worktree_id "$(pwd)")"
  g_own="$(mentor_plan_marker "$g_plans" "$g_wt_id")"
  g_legacy="$(mentor_plan_marker "$g_plans" "")"

  g_own_exists=0; g_own_live=0
  [ -e "$g_own" ] && g_own_exists=1
  if [ "$g_own_exists" -eq 1 ] && ! mentor_marker_stale "$g_own"; then g_own_live=1; fi

  # Legacy is a SEPARATE path only when wt_id is non-empty (empty wt_id already makes
  # g_own == g_legacy — see mentor_plan_marker) — guarded so the two checks can never
  # double-count the same file.
  g_legacy_exists=0; g_legacy_live=0
  if [ -n "$g_wt_id" ]; then
    [ -e "$g_legacy" ] && g_legacy_exists=1
    if [ "$g_legacy_exists" -eq 1 ] && ! mentor_marker_stale "$g_legacy"; then g_legacy_live=1; fi
  fi

  if [ "$g_own_live" -eq 1 ] || [ "$g_legacy_live" -eq 1 ]; then
    if [ "$g_own_live" -eq 1 ]; then g_marker="$g_own"; else g_marker="$g_legacy"; fi
    echo ARMED
    if [ "$g_verbose" -eq 1 ]; then
      echo "marker=${g_marker}"
      echo "owner_session=$(mentor_marker_field "$g_marker" session)"
      echo "owner_cwd=$(mentor_marker_field "$g_marker" cwd)"
      echo "owner_worktree=$(mentor_marker_field "$g_marker" worktree)"
      echo "age_min=$(mentor_marker_age_min "$g_marker")"
      # Unfiltered when the armed marker is the legacy one, matching approve-plan.sh's
      # own legacy_mode (unfiltered repo-wide sweep) — a legacy-armed gate blocks every
      # worktree, so "what would approving promote" must answer for the whole repo, not
      # just this worktree's slice.
      if [ "$g_marker" = "$g_legacy" ]; then g_affected_wt=""; else g_affected_wt="$g_wt_id"; fi
      g_affected="$(mentor_newly_planned "$g_plans" "$g_marker" "$g_affected_wt" \
        | while IFS= read -r g_p; do basename "$(dirname "$g_p")"; done | paste -sd' ' -)"
      echo "affected_plans=${g_affected}"
    fi
  elif [ "$g_own_exists" -eq 1 ] || [ "$g_legacy_exists" -eq 1 ]; then
    echo STALE
  else
    g_siblings="$(mentor_live_markers "$g_plans")"
    if [ -n "$g_siblings" ]; then
      echo ARMED_ELSEWHERE
      if [ "$g_verbose" -eq 1 ]; then
        while IFS= read -r g_m; do
          [ -n "$g_m" ] || continue
          g_suffix="$(basename "$g_m")"
          g_suffix="${g_suffix#.planning.}"
          echo "elsewhere=${g_suffix} session=$(mentor_marker_field "$g_m" session) worktree=$(mentor_marker_field "$g_m" worktree) age_min=$(mentor_marker_age_min "$g_m")"
        done <<<"$g_siblings"
      fi
    else
      echo RELEASED
    fi
  fi
  exit 0
fi

# --- sweep <pattern> [--roots plans|repo] [--ignore-case]: the ONE portable search
# over mentor's own state. Deliberately an EARLY handler, alongside gate/dir/context:
# it must run BEFORE the repo-root and plans-dir guards below, because a repo with no
# .mentor/plans yet is still a perfectly good `repo` sweep, and a missing plans dir
# must report NOTHING-SEARCHED rather than the plans-dir guard's "nothing planned" —
# the exact silent-clean answer this subcommand exists to make impossible. Outside a git repo it still answers, with
# the NOTHING-SEARCHED verdict rather than a false zero.
#
# The mechanism (find walks, grep only reads the list it is handed), why the GNU/ripgrep
# no-ignore flag and its ugrep-only cousin are both wrong, and the measured hit matrix live
# `sweep` section of lib/state.sh — read it there before changing anything here.
if [ "$sub" = "sweep" ]; then
  sw_pattern=""; sw_set="plans"; sw_icase=""; sw_have_pattern=0; sw_endopts=0
  while [ "$#" -gt 0 ]; do
    if [ "$sw_endopts" -eq 0 ]; then
      case "$1" in
        --roots)
          if [ "$#" -lt 2 ]; then
            echo "[mentor plan-state] sweep --roots needs a value: plans|repo" >&2
            exit 2
          fi
          sw_set="$2"; shift 2; continue ;;
        --roots=*) sw_set="${1#--roots=}"; shift; continue ;;
        --ignore-case) sw_icase=1; shift; continue ;;
        # `--` ends option parsing, so a PATTERN beginning with a dash is still reachable
        # (`sweep -- -not-a-flag`) instead of being rejected as an unknown flag.
        --) sw_endopts=1; shift; continue ;;
        -?*)
          echo "[mentor plan-state] sweep: unknown flag '${1}'." >&2
          echo "  usage: sweep <pattern> [--roots plans|repo] [--ignore-case]" >&2
          exit 2 ;;
      esac
    fi
    if [ "$sw_have_pattern" -eq 1 ]; then
      echo "[mentor plan-state] sweep takes ONE pattern; got an extra argument '${1}'." >&2
      echo "  quote a multi-word pattern: sweep 'two words' --ignore-case" >&2
      exit 2
    fi
    sw_pattern="$1"; sw_have_pattern=1; shift
  done
  case "$sw_set" in
    plans|repo) ;;
    *)
      echo "[mentor plan-state] sweep: unknown root set '${sw_set}' — use plans|repo." >&2
      echo "  plans   the main repo's .mentor/plans" >&2
      echo "  repo    the whole worktree, minus .git/ (.mentor/ included)" >&2
      exit 2 ;;
  esac
  if [ "$sw_have_pattern" -eq 0 ] || [ -z "$sw_pattern" ]; then
    echo "[mentor plan-state] sweep needs a non-empty pattern." >&2
    echo "  usage: sweep <pattern> [--roots plans|repo] [--ignore-case]" >&2
    exit 2
  fi
  sw_out="$(mentor_sweep "$(pwd)" "$sw_set" "$sw_pattern" "$sw_icase")"
  sw_roots=0; sw_files=0; sw_hits=0
  read -r sw_roots sw_files sw_hits <<<"$(printf '%s\n' "$sw_out" | head -1)" || true
  # The accounting line leads, always. On a broken sweep there are no hits at all, so this
  # line IS the entire output; on a long result set it must not scroll away from the
  # reader who has to judge whether a zero is trustworthy.
  echo "SWEEP: roots=${sw_roots:-0} files=${sw_files:-0} hits=${sw_hits:-0}"
  if [ "${sw_files:-0}" -eq 0 ]; then
    echo "SWEEP: NOTHING-SEARCHED — no root existed; this result is not evidence"
    exit 2
  fi
  if [ "${sw_hits:-0}" -gt 0 ]; then
    printf '%s\n' "$sw_out" | tail -n +2
    exit 0
  fi
  exit 1
fi

# parse_init_args <caller> [args…] — the ONE parser for init's argument grammar, setting
# slug/group/order/deps. `start` runs it too, BEFORE ensure-dir, so a bad flag fails
# with no plan dir left behind; `init` runs it for its own arguments. A usage error
# exits 1 naming <caller>.
parse_init_args() {
  local caller="$1"; shift
  slug=""; group=""; order=""; deps=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # shift 1 then conditionally 1 more: a bare trailing `--group` must not
      # leave $# unchanged and spin this loop forever.
      --group) group="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --order) order="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      --deps) deps="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
      -*) echo "[mentor plan-state] ${caller}: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
      *)  [ -z "$slug" ] && slug="$1" || { echo "[mentor plan-state] ${caller}: unexpected argument ${1}" >&2; exit 1; }; shift ;;
    esac
  done
}

# --- start <slug> [init flags]: ensure-dir + init in ONE call (v2.34.0) ---------
# The plan-write path used to cost separate Bash calls around one Write, and because
# each is its own shell, the skill had to warn about re-deriving $slug — an empty one
# silently registering nothing. One call removes that footgun.
#
# Order is load-bearing: the arguments are validated first (parse_init_args), so a
# bad flag leaves no plan dir behind; then ensure-dir, because `init` runs
# require_slug, which demands the dir already exist. Every flag after the slug is
# forwarded to `init` verbatim.
if [ "$sub" = "start" ]; then
  st_slug="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$st_slug" in
    ""|-*)
      echo "[mentor plan-state] start needs <slug> as its FIRST argument." >&2
      echo "  usage: start <slug> [any init flag]" >&2
      exit 1 ;;
  esac
  parse_init_args start "$st_slug" "$@"
  st_repo="$(mentor_repo_root "$(pwd)")"
  if [ -z "$st_repo" ]; then
    echo "[mentor plan-state] Not inside a git repo — mentor keeps no plan registry here." >&2
    exit 1
  fi
  st_plans="$(mentor_plans_dir "$st_repo")"
  st_self="${hook_dir}/plan-state.sh"
  st_dir="$(bash "$st_self" ensure-dir "${st_plans}/${st_slug}")" || exit 1
  # init reports to STDERR here, so this subcommand's stdout is exactly one line: the
  # plan path. That is what lets the caller write
  # `plan_md="$(plan-state.sh start "$slug")"` and have a failure kill the pipeline.
  # The summary is not suppressed, only redirected: it still appears for the reader.
  bash "$st_self" init "$st_slug" "$@" >&2 || exit 1
  echo "${st_dir}/plan.md"
  exit 0
fi

# Every subcommand handled by an early `if` above (context, dir, ensure-dir, relocate,
# gate, sweep, start) exits before reaching here, so none of them appears in this
# allow-list — adding one would be unreachable code, not a fix.
case "$sub" in
  init|set|set-deps|tick|record-write|drift|verify|query|list|current) ;;
  claim|brief|policy|set-parent|set-priority|set-category|handoff-path|handoff-selfcheck)
    echo "plan-state.sh: '${sub}' was removed in mentor v5.0.0 — no replacement" >&2
    exit 1
    ;;
  ""|-h|--help|help)
    usage
    [ -n "$sub" ] && exit 0
    echo "[mentor plan-state] Missing subcommand." >&2
    exit 1
    ;;
  *)
    echo "[mentor plan-state] Unknown subcommand: ${sub}" >&2
    usage >&2
    exit 1
    ;;
esac

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  [ "$sub" != drift ] || { echo unknown; exit 0; }
  echo "[mentor plan-state] Not in a git repo — mentor keeps no plan registry here." >&2
  [ "$sub" != record-write ] || exit 1
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"
if [ ! -d "$plans_dir" ]; then
  [ "$sub" != drift ] || { echo unknown; exit 0; }
  echo "[mentor plan-state] No plans dir yet (${plans_dir}) — nothing planned in this repo." >&2
  [ "$sub" != record-write ] || exit 1
  exit 0
fi

# --- shared per-plan iterator --------------------------------------------------
# _plan_walk [group-filter] — the ONE walk over plans_dir for `list`/`current`, for every
# plan dir that has a plan.md. Emits one tab-separated record per line, unsorted:
#   slug  state  group  order  owner
# IFS-whitespace read pitfall: a lone tab in IFS is still "IFS whitespace" to bash's
# `read` — consecutive tabs COLLAPSE instead of producing an empty field, so a
# genuinely-empty group/order/owner would silently shift every field after it. Emit
# "-" for empty (matching print_table's display convention); consumers translate "-"
# back to "" on read.
_plan_walk() {
  local filter="${1:-}" d slug state group order owner
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    state="$(mentor_plan_effective_state "$d")"
    group="$(mentor_plan_group "$d")"   # sidecar, else the isolation header
    if [ -n "$filter" ] && [ "$group" != "$filter" ]; then continue; fi
    order="$(mentor_plan_order "$d")"
    owner="$(mentor_plan_owner "$d")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$state" "${group:--}" "${order:--}" "${owner:--}"
  done
}

# list_rows [group-filter] [with-owner] — the pre-v2.17.0 5-field row format,
# byte-compatible: <sortkey> <slug> <effective state> <group> <order>, tab-separated
# and sorted. Sort key: bucket (0 active / 1 superseded+unknown) | group (ungrouped
# sorts on its own slug, so it neither splits a group nor clumps with one) |
# zero-padded order | slug. with-owner=1 appends a tab field (owner wt-id, "-" when
# unowned) for `list --owners`; the default 5-field shape stays byte-identical.
list_rows() {
  local filter="${1:-}" with_owner="${2:-0}"
  local slug state group order owner bucket gkey okey line
  while IFS="$(printf '\t')" read -r slug state group order owner; do
    [ -n "$slug" ] || continue
    [ "$group" = "-" ] && group=""   # un-placeholder — see _plan_walk's comment
    [ "$order" = "-" ] && order=""
    [ "$owner" = "-" ] && owner=""
    case "$state" in
      superseded|unknown) bucket=1 ;;
      *)                  bucket=0 ;;
    esac
    gkey="${group:-$slug}"
    case "$order" in
      ''|*[!0-9]*) okey="999" ;;
      *)           okey="$(printf '%03d' "$order")" ;;
    esac
    line="$(printf '%s|%s|%s|%s\t%s\t%s\t%s\t%s' "$bucket" "$gkey" "$okey" "$slug" "$slug" "$state" "${group:--}" "${order:--}")"
    [ "$with_owner" = "1" ] && line="$(printf '%s\t%s' "$line" "${owner:--}")"
    printf '%s\n' "$line"
  done <<<"$(_plan_walk "$filter")" | LC_ALL=C sort -t"$(printf '\t')" -k1,1
}

print_table() {
  local filter="${1:-}" with_owner="${2:-0}"
  local rows i=0 key slug state group order owner
  rows="$(list_rows "$filter" "$with_owner")"
  if [ -z "$rows" ]; then
    return 1
  fi
  if [ "$with_owner" = "1" ]; then
    printf '%-3s %-13s %-38s %-24s %-6s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER" "OWNER"
    while IFS="$(printf '\t')" read -r key slug state group order owner; do
      [ -n "$slug" ] || continue
      i=$((i + 1))
      printf '%-3s %-13s %-38s %-24s %-6s %s\n' "$i" "$state" "$slug" "$group" "$order" "$owner"
    done <<<"$rows"
    return 0
  fi
  printf '%-3s %-13s %-38s %-24s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER"
  while IFS="$(printf '\t')" read -r key slug state group order; do
    [ -n "$slug" ] || continue
    i=$((i + 1))
    printf '%-3s %-13s %-38s %-24s %s\n' "$i" "$state" "$slug" "$group" "$order"
  done <<<"$rows"
  return 0
}

require_slug() {
  local slug="${1:-}"
  if [ -z "$slug" ]; then
    echo "[mentor plan-state] ${sub}: a <slug> is required." >&2
    usage >&2
    exit 1
  fi
  if [ ! -d "${plans_dir}/${slug}" ]; then
    echo "[mentor plan-state] No such plan: ${plans_dir}/${slug}" >&2
    echo "Run 'plan-state.sh list' to see the slugs that exist." >&2
    exit 1
  fi
}

require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[mentor plan-state] jq not found — plan state cannot be written. Install jq;" >&2
  echo "until then mentor derives state from the plan's ✅ step ticks alone." >&2
  exit 0
}

# require_jq_read — the READ-side counterpart for query (which never writes):
# a single stderr line and exit 0, per this file's fail-soft convention for
# environmental problems (see the header comment).
require_jq_read() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "[mentor plan-state] jq not found — cannot compute query." >&2
  exit 0
}

# closing_checklist_reminder <implemented|failed> — best-effort stdout nudge. The
# caller fires this only on a FRESH transition into a terminal state, gauged off the
# STORED sidecar (before_stored != state), not the tick-self-healing effective read —
# a plan whose ✅ ticks alone already self-heal the effective state to "implemented"
# must still get this reminder on its real first `set … implemented`, while a later
# idempotent re-close (shipping/merging re-running `set … implemented`) stays silent.
# Both lines print on both terminal states: every terminal transition writes a
# Done review (planning → After Proceed). Never blocks — the state
# write already succeeded by the time this runs.
closing_checklist_reminder() {
  echo "[mentor plan-state] Closing checklist:"
  echo "  - Name every follow-up WORK item in the report before it's forgotten. Never a check: an unresolved verification check ends 'failed --note', not a follow-up."
  echo "  - Write the ## Done review (per scenario: expected, observed, evidence) if it is not there yet."
  return 0
}

# tick_reconciliation_reminder <plan_dir> — best-effort stderr warning, fired only
# alongside closing_checklist_reminder (same FRESH-transition-to-implemented guard, so
# shipping/merging's idempotent re-`set … implemented` stays silent). Distinct from the
# "'implemented' stored, but the plan's ✅ step ticks report …" note above: that note
# fires only when the tick-derived state OUTRANKS what was just stored
# (mentor_plan_state_rank), which a partially- or un-ticked plan never does —
# `implemented` at 0/6 or 2/6 stores clean, mentor_plan_effective_state agrees with it,
# and nothing above this function ever says otherwise. Ticks self-heal STATE (a stale
# sidecar can be overridden by finishing the ticks) but nothing self-heals a TICK — once
# a plan is closed `implemented`, this is the last chance to write the ones that
# actually passed, which is why this fires exactly here. A false positive here is cheap
# (a legacy plan closed before this sidecar existed, or a `merging` partial close the
# user already accepted) — fail-soft nudge, not a gate.
tick_reconciliation_reminder() {
  local plan_dir="${1:-}" plan_md="${1:-}/plan.md" ticked total
  [ -n "$plan_dir" ] && [ -f "$plan_md" ] || return 0
  read -r ticked total <<<"$(mentor_plan_tick_counts "$plan_md")"
  [ "${total:-0}" -gt 0 ] || return 0
  [ "${ticked:-0}" -lt "${total:-0}" ] || return 0
  echo "[mentor plan-state] WARNING: ${plan_dir##*/} closed 'implemented' with only ${ticked}/${total} steps ticked." >&2
  echo "  For each passed step: save the returned verdict to verdicts/step-N.md, append its PASS row, record-write, then tick (plan-state.sh tick ${plan_dir##*/} <N>), or tell the user which are closing untracked and why." >&2
  return 0
}

# --- query engine ---------------------------------------------------------------
# `query` is deliberately shaped around subprocess COUNT, not code brevity: a fixed,
# small number of spawns REGARDLESS of plan count — one jq over every sidecar, one awk
# over every plan.md, one jq that builds and filters the entries. `_plan_walk` (the
# `list`/`current` source) calls a jq per field per plan, which on a 34-plan repo cost
# hundreds of spawns for what is really two passes over the same bytes. Both readers
# agree because both derive "effective state" from the same stored-vs-ticks rule
# (mentor_plan_effective_state's rank comparison, reimplemented below over
# batch-scanned data rather than re-read per plan).

# _query_sidecars — ONE jq spawn for every plan dir's .state.json, emitting
# `{order: [<slug>…], map: {<slug>: <sidecar>}}`. `order` preserves the bash GLOB
# order the dirs were read in (the order `query` emits entries in); jq's own `keys`
# sorts by codepoint, which disagrees with glob collation on `-` under some locales
# and would silently reorder the array. Each sidecar is streamed as `<slug><TAB><json-on-one-line>`
# so the slug rides WITH its data: a positional zip against a parallel slug list
# would silently shift every later plan the moment one sidecar is missing. `tr -d`
# is safe because a raw newline cannot appear inside a JSON string (it must be
# escaped as \n), so collapsing a pretty-printed sidecar to one line never changes
# what it parses to. A corrupt sidecar yields `null` from `fromjson?` and is treated
# as "no sidecar" — the same fail-soft reading mentor_plan_state_field gives it,
# rather than aborting the whole query.
_query_sidecars() {
  local d slug
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    slug="$(basename "$d")"
    printf '%s\t' "$slug"
    [ -f "${d}/.state.json" ] && tr -d '\n' < "${d}/.state.json"
    printf '\n'
  done | jq -R -s -c '
    [ split("\n")[] | select(length > 0)
      | (index("\t")) as $i
      | { key: .[0:$i], value: ( (.[$i+1:] | fromjson?) // {} ) } ] as $rows
    | { order: [$rows[].key], map: ($rows | from_entries) }' 2>/dev/null
}

# _query_plan_files — ONE awk spawn over every plan.md, emitting
# `<slug>\t<ticked>\t<total>\t<hdr-group>\t<hdr-order>` per plan ("-" for an absent
# header field, matching _plan_walk's placeholder convention — a bare empty field
# collapses under `read`'s IFS handling).
#
# It folds together THREE per-plan reads that were separate processes before:
# mentor_plan_tick_counts' awk, and mentor_plan_header_field's two `sed -n '1,20p'`
# pipelines for the isolation header's group/order. All three want the same file, and
# two of them want only its first 20 lines, so one pass serves all of them.
#
# The step-line match uses MENTOR_STEP_LINE_PATTERN — the SAME shared pattern
# mentor_plan_tick_counts and mentor_plan_tick_step match against — so `query`'s step
# counts can never disagree with what `tick` writes.
# The header extractions mirror mentor_plan_header_field's two `sed` expressions
# exactly (first match within lines 1-20 wins). `[*][*]` rather than `\*\*`: a
# backslash-escaped literal is undefined behavior in a dynamic awk regex on some
# implementations (macOS awk 20200816), and the bracket form is portable in both.
_query_plan_files() {
  local d files=()
  for d in "${plans_dir}"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ -f "${d}/plan.md" ] || continue
    files+=("${d}/plan.md")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v pat="$MENTOR_STEP_LINE_PATTERN" '
    function slugof(f,   n, parts) { n = split(f, parts, "/"); return parts[n-1] }
    FNR == 1 { s = slugof(FILENAME); seen[s] = 1; tot[s] += 0; tk[s] += 0; insec = 0 }
    FNR <= 20 {
      if (grp[s] == "" && match($0, /[Gg]roup `[^`]*`/)) {
        v = substr($0, RSTART, RLENGTH); sub(/^[Gg]roup `/, "", v); sub(/`$/, "", v); grp[s] = v
      }
      if (ord[s] == "" && match($0, /[*][*]Plan [0-9]+ of /)) {
        v = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); ord[s] = v
      }
    }
    /^##[[:space:]]/ {
      h = tolower($0)
      insec = (h ~ /^##[[:space:]]+implementation[[:space:]]+steps/) ? 1 : 0
      next
    }
    !insec { next }
    $0 ~ pat { tot[s]++; if (index($0, "✅") > 0) tk[s]++ }
    END {
      for (x in seen)
        printf "%s\t%d\t%d\t%s\t%s\n", x, tk[x] + 0, tot[x] + 0,
               (grp[x] == "" ? "-" : grp[x]), (ord[x] == "" ? "-" : ord[x])
    }
  ' "${files[@]}" 2>/dev/null
}

# MENTOR_QUERY_JQ — the whole `query` build+filter engine as ONE jq program. Inputs
# (all named, all pre-batched by the `_query_*` helpers above):
#   $sc       {order: [<slug>…], map: {<slug>: <sidecar>}} — plan dirs WITH a plan.md,
#             in glob order (see _query_sidecars on why order is carried explicitly)
#   $alldirs  newline-joined names of EVERY subdir of plans_dir — the set a dep target
#             is checked against (a dir without a plan.md still counts as present)
#   $ticks    <slug>\t<ticked>\t<total>\t<hdr-group>\t<hdr-order> per plan
#   $f        the parsed filter flags
#
# Effective state is recomputed here by the SAME rule as mentor_plan_effective_state —
# the more advanced of the stored state and the tick-derived one, ties keeping stored,
# `unknown` when neither exists. `rank` mirrors mentor_plan_state_rank exactly
# (superseded 9 > failed 5 > implemented 4 > in_progress 3 > approved 2 > draft 1).
MENTOR_QUERY_JQ='
def rank: {"superseded":9,"failed":5,"implemented":4,"in_progress":3,"approved":2,"draft":1}[.] // 0;
def valid_state: . as $s | ["draft","approved","in_progress","implemented","failed","superseded"] | index($s) != null;
def dash: if . == "-" then null else . end;
def nz: if . == null or . == "" then null else . end;

# scal — the batch equivalent of mentor_plan_state_field: a SCALAR sidecar read that
# `tostring`s whatever it finds and reports unset/null/empty alike as null.
def scal($c; $k): ($c[$k] | if . == null then "" else tostring end) | nz;

# globre — glob (`*`, `?`) to regex, escaping every other non-word character so a slug
# containing regex punctuation cannot turn into an accidental pattern.
def globre:
  reduce (explode[] | [.] | implode) as $ch ("";
    . + (if $ch == "*" then ".*"
         elif $ch == "?" then "."
         elif ($ch | test("[A-Za-z0-9_-]")) then $ch
         else "\\" + $ch end));
def csv: split(",") | map(select(length > 0));

($alldirs | split("\n") | map(select(length > 0)))                                    as $DIRS |
($ticks | split("\n") | map(select(length > 0) | split("\t"))
  | map({key: .[0],
         value: {ticked: (.[1] | tonumber), total: (.[2] | tonumber),
                 hgroup: (.[3] | dash), horder: (.[4] | dash)}})
  | from_entries)                                                                     as $T |

[ $sc.order[] as $s
  | ($sc.map[$s] // {})                                                               as $c
  | ($T[$s] // {ticked: 0, total: 0, hgroup: null, horder: null})                     as $t
  | (if (($c.state | type) == "string" and ($c.state | valid_state))
     then $c.state else "" end)                                                       as $stored
  | (if $t.total == 0 then ""
     elif $t.ticked == $t.total then "implemented"
     elif $t.ticked > 0 then "in_progress"
     else "" end)                                                                     as $tick
  | (if $stored == "" then "unknown" else $stored end)                                as $storedeff
  | (if $tick == "" then $storedeff
     elif ($tick | rank) > ($stored | rank) then $tick
     else $storedeff end)                                                             as $eff
  | (scal($c; "group") // $t.hgroup)                                                  as $group
  | (scal($c; "order") // $t.horder)                                                  as $order
  | {kind: "plan", slug: $s, state: $eff,
     group: $group,
     order: (if $order == null then null else ($order | tonumber? // null) end),
     owner: scal($c; "owner"),
     deps: [ ($c.deps // []) | if type == "array" then .[] else empty end
             | tostring | select(length > 0) | . as $dep
             | {slug: $dep, missing: (($DIRS | index($dep)) == null)} ],
     steps: {ticked: $t.ticked, total: $t.total}}
]
| (if $f.sel_slug_set == 1 then map(select(.slug == $f.sel_slug)) else . end)
# Every predicate reads the entry through the explicit `$e` binding, never a bare
# `.`: several of them pipe into a derived value first (`$f.state | csv`), and a
# pipe rebinds `.` to that value — so a bare `.state` inside one of them indexes
# the CSV ARRAY, not the entry, and jq aborts the whole read.
| map(. as $e | select(
      ($f.state    == "" or (($f.state    | csv) | index($e.state)    != null))
  and ($f.openf   == 0 or (($e.state == "implemented" or $e.state == "superseded") | not))
  and ($f.closedf == 0 or ($e.state == "implemented" or $e.state == "superseded"))
  and ($f.group_set  == 0 or (if ($f.group | nz) == null then ($e.group == null)
                              else (($f.group | csv) | index($e.group) != null) end))
  and ($f.owner_set == 0 or (if ($f.owner | nz) == null then ($e.owner == null)
                             else (($f.owner | csv) | index($e.owner) != null) end))
  and ($f.unowned   == 0 or ($e.owner == null))
  and ($f.deps_missing == 0 or (([$e.deps[] | select(.missing)] | length) > 0))
  and ($f.match == "" or (($e.slug // "") | test("^" + ($f.match | globre) + "$")))
))
'

case "$sub" in

  init)
    parse_init_args init "$@"
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    init_wt_id="$(mentor_worktree_id "$(pwd)")"
    # Collision check reads whatever owner is currently on record, BEFORE the
    # last-init-wins re-stamp below overwrites it.
    warn_same_slug_collision "$plan_dir" "$init_wt_id" "$plans_dir"
    # Idempotent: keep whatever state is already on record; only fill in a missing one.
    existing="$(mentor_plan_state_stored "$plan_dir")"
    write_args=(--state "${existing:-draft}" --note "$(mentor_plan_state_field "$plan_dir" note)")
    [ -n "$group" ] && write_args+=(--group "$group")
    [ -n "$order" ] && write_args+=(--order "$order")
    # Second of the three owner-stamping sites (see this file's top-of-file v2.23.0
    # note): last-init-wins re-owning — this is also how `/mentor:plan <slug>` re-owns
    # a plan resumed in a different worktree. Skipped entirely when wt-id is empty
    # (no git / bare repo / etc.) — same fail-soft convention as everywhere else here.
    if [ -n "$init_wt_id" ]; then
      write_args+=(--owner "$init_wt_id" --owner-session "${CLAUDE_CODE_SESSION_ID:-}")
    fi
    deps_summary=""
    if [ -n "$deps" ]; then
      clean_deps=()
      IFS=',' read -r -a raw_deps <<<"$deps"
      for x in "${raw_deps[@]:-}"; do
        x="$(printf '%s' "$x" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$x" ] && clean_deps+=("$x")
      done
      if [ "${#clean_deps[@]}" -gt 0 ]; then
        # A cycle is fail-soft: a graph condition the caller could not have known
        # locally, not a misspelling — deps are skipped, every other field applies.
        if [ -n "$(mentor_plan_would_cycle "$plans_dir" "$slug" "${clean_deps[*]}")" ]; then
          echo "[mentor plan-state] init: --deps would create a dependency cycle (${slug} → … → ${slug}) — deps NOT set; other fields still applied." >&2
        else
          deps_summary="$(IFS=,; echo "${clean_deps[*]}")"
          write_args+=(--deps "$deps_summary")
        fi
      fi
    fi
    mentor_plan_state_write "$plan_dir" "${write_args[@]}"
    echo "[mentor plan-state] ${slug}: $(mentor_plan_effective_state "$plan_dir")${group:+  group=${group}}${order:+  order=${order}}${deps_summary:+  deps=${deps_summary}}"
    ;;

  set)
    slug=""; state=""; note=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --note) note="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        -*) echo "[mentor plan-state] set: unknown flag ${1}" >&2; usage >&2; exit 1 ;;
        *)
          if [ -z "$slug" ]; then slug="$1"
          elif [ -z "$state" ]; then state="$1"
          else echo "[mentor plan-state] set: unexpected argument ${1}" >&2; exit 1
          fi
          shift ;;
      esac
    done
    require_slug "$slug"
    if ! mentor_plan_state_valid "$state"; then
      echo "[mentor plan-state] set: invalid state '${state}'." >&2
      echo "Valid states: ${MENTOR_PLAN_STATES}" >&2
      exit 1
    fi
    require_jq
    plan_dir="${plans_dir}/${slug}"
    before="$(mentor_plan_effective_state "$plan_dir")"
    # Freshness for the reminders below is judged off this STORED read, not `before`
    # above — `before` is effective (max of stored, tick-derived) and self-heals to
    # "implemented" from ✅ ticks alone, before any `set` call ever runs. Gating on
    # that would make the real first `set … implemented` look like an idempotent
    # re-close and silently skip every reminder. `before_stored` only changes when a
    # write actually persists it, so ticks alone can't fool it.
    before_stored="$(mentor_plan_state_stored "$plan_dir")"
    mentor_plan_state_write "$plan_dir" --state "$state" --note "$note"
    after="$(mentor_plan_effective_state "$plan_dir")"
    echo "[mentor plan-state] ${slug}: ${before} → ${after}${note:+  (${note})}"
    # The effective read can outrank what was just stored — say so rather than let a
    # caller believe the sidecar is the last word.
    if [ "$after" != "$state" ]; then
      echo "[mentor plan-state] note: '${state}' stored, but the plan's ✅ step ticks report '${after}'."
    fi
    case "$state" in
      implemented|failed)
        # Fire only on a FRESH transition — before_stored == state means this call is
        # an idempotent re-close (e.g. shipping/merging re-running `set … implemented`
        # after the plan was already closed), which must stay silent.
        if [ "$before_stored" != "$state" ]; then
          closing_checklist_reminder "$state"
          if [ "$state" = "implemented" ]; then
            tick_reconciliation_reminder "$plan_dir"
          fi
        fi
        ;;
    esac
    ;;

  set-deps)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    depstr="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] set-deps: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    require_jq
    plan_dir="${plans_dir}/${slug}"
    clean_deps=()
    IFS=',' read -r -a raw_deps <<<"$depstr"
    for x in "${raw_deps[@]:-}"; do
      x="$(printf '%s' "$x" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -n "$x" ] && clean_deps+=("$x")
    done
    if [ "${#clean_deps[@]}" -gt 0 ] && [ -n "$(mentor_plan_would_cycle "$plans_dir" "$slug" "${clean_deps[*]}")" ]; then
      echo "[mentor plan-state] set-deps: refused — ${slug} → … → ${slug} would be a dependency cycle. No write." >&2
      exit 0
    fi
    clean_csv=""
    [ "${#clean_deps[@]}" -gt 0 ] && clean_csv="$(IFS=,; echo "${clean_deps[*]}")"
    # Re-read and re-pass the note: mentor_plan_state_write always REPLACES --note
    # (even when omitted, which would clear it), so a deps-only write must round-trip
    # the current note to avoid silently wiping it.
    mentor_plan_state_write "$plan_dir" --deps "$clean_csv" --note "$(mentor_plan_state_field "$plan_dir" note)"
    echo "[mentor plan-state] ${slug}: deps = ${clean_csv:-(none)}"
    ;;

  record-write|drift)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] ${sub}: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    plan_md="${plans_dir}/${slug}/plan.md"
    if [ "$sub" = drift ]; then
      mentor_plan_drift "$plan_md"
    else
      if [ ! -f "$plan_md" ]; then
        echo "[mentor plan-state] record-write: no plan.md at ${plan_md}." >&2
        exit 1
      fi
      record_plan_write "$plan_md"
    fi
    ;;

  tick)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    step="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] tick: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    case "$step" in
      ''|*[!0-9]*|0)
        echo "[mentor plan-state] tick: <N> must be a positive integer, got '${step}'." >&2
        usage >&2
        exit 1
        ;;
    esac
    plan_dir="${plans_dir}/${slug}"
    plan_md="${plan_dir}/plan.md"
    if [ ! -f "$plan_md" ]; then
      echo "[mentor plan-state] tick: no plan.md at ${plan_md}." >&2
      exit 1
    fi
    if [ "$(mentor_plan_drift "$plan_md")" = changed ]; then
      echo "plan.md changed since mentor last wrote it — read it before editing it further"
    fi
    # `if var=$(cmd)` (not a bare assignment) — under `set -e` a failing bare
    # assignment aborts the script before the rc check below ever runs.
    if tick_result="$(mentor_plan_tick_step "$plan_md" "$step")"; then
      read -r tick_status tick_n tick_total <<<"$tick_result"
      case "$tick_status" in
        ticked)
          echo "[mentor plan-state] ${slug}: step ${step} ✅ ticked (${tick_n}/${tick_total})."
          record_plan_write "$plan_md"
          ;;
        already) echo "[mentor plan-state] ${slug}: step ${step} was already ✅ (${tick_n}/${tick_total}) — no write." ;;
      esac
    else
      # Verdict refusals already name the file and fix on stderr; only the
      # helper's existing no-such-step result needs a CLI diagnostic here.
      if [[ "$tick_result" == no-such-step\ * ]]; then
        read -r _ tick_total <<<"$tick_result"
        echo "[mentor plan-state] tick: ${slug} has no step ${step} (plan.md has ${tick_total:-0} step(s) in '## Implementation steps'). No write." >&2
      fi
      exit 1
    fi
    ;;


  # --- query: the ONE filterable read surface. Three orthogonal argument groups —
  # Select (which plan), Filter (AND-combined predicates), Output (shape).
  query)
    q_sel_slug=""; q_sel_slug_set=0
    q_state=""; q_openf=0; q_closedf=0
    q_group=""; q_group_set=0
    q_owner=""; q_owner_set=0; q_unowned=0
    q_deps_missing=0; q_match=""
    q_format="json"; q_fields=""; q_sort=""; q_limit=""
    q_need() {
      if [ "$2" -lt 2 ]; then
        echo "[mentor plan-state] query: ${1} needs a value." >&2
        usage >&2
        exit 1
      fi
    }
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --slug)        q_need "$1" "$#"; q_sel_slug="$2";  q_sel_slug_set=1; shift 2 ;;
        --state)       q_need "$1" "$#"; q_state="$2";     shift 2 ;;
        --open)        q_openf=1;   shift ;;
        --closed)      q_closedf=1; shift ;;
        --group)       q_need "$1" "$#"; q_group="$2";     q_group_set=1;  shift 2 ;;
        --owner)       q_need "$1" "$#"; q_owner="$2";     q_owner_set=1;  shift 2 ;;
        --unowned)     q_unowned=1;     shift ;;
        --deps-missing) q_deps_missing=1; shift ;;
        --match)       q_need "$1" "$#"; q_match="$2";     shift 2 ;;
        --format)      q_need "$1" "$#"; q_format="$2";    shift 2 ;;
        --fields)      q_need "$1" "$#"; q_fields="$2";    shift 2 ;;
        --sort)        q_need "$1" "$#"; q_sort="$2";      shift 2 ;;
        --limit)       q_need "$1" "$#"; q_limit="$2";     shift 2 ;;
        *)
          echo "[mentor plan-state] query: unexpected argument ${1}" >&2
          usage >&2
          exit 1
          ;;
      esac
    done
    if [ "$q_openf" -eq 1 ] && [ "$q_closedf" -eq 1 ]; then
      echo "[mentor plan-state] query: --open and --closed are mutually exclusive." >&2
      exit 1
    fi
    if [ "$q_owner_set" -eq 1 ] && [ "$q_unowned" -eq 1 ]; then
      echo "[mentor plan-state] query: --owner and --unowned are mutually exclusive." >&2
      exit 1
    fi
    case "$q_format" in
      json|table|slug|count|tsv) ;;
      *)
        echo "[mentor plan-state] query: --format must be one of json|table|slug|count|tsv (got: ${q_format})." >&2
        exit 1
        ;;
    esac
    if [ -n "$q_limit" ]; then
      case "$q_limit" in
        ''|*[!0-9]*)
          echo "[mentor plan-state] query: --limit must be a non-negative integer (got: ${q_limit})." >&2
          exit 1
          ;;
      esac
    fi
    if [ "$q_sel_slug_set" -eq 1 ]; then require_slug "$q_sel_slug"; fi
    require_jq_read

    # Every subdir of plans_dir, glob order — the set a `deps` target is checked
    # against. Deliberately NOT the plan.md-only set: a dir without a plan.md yet
    # counts as PRESENT, not missing. Plain string concatenation — no subprocess.
    q_alldirs=""
    for q_d in "${plans_dir}"/*/; do
      [ -d "$q_d" ] || continue
      q_d="${q_d%/}"
      q_alldirs="${q_alldirs}${q_d##*/}
"
    done

    q_sc="$(_query_sidecars)"
    [ -n "$q_sc" ] || q_sc='{"order":[],"map":{}}'
    q_ticks="$(_query_plan_files)"

    q_filters="$(jq -n -c \
      --arg state "$q_state" \
      --argjson openf "$q_openf" --argjson closedf "$q_closedf" \
      --arg group "$q_group" --argjson group_set "$q_group_set" \
      --arg owner "$q_owner" --argjson owner_set "$q_owner_set" --argjson unowned "$q_unowned" \
      --argjson deps_missing "$q_deps_missing" \
      --arg match "$q_match" --arg sel_slug "$q_sel_slug" --argjson sel_slug_set "$q_sel_slug_set" \
      '$ARGS.named')"

    q_out="$(jq -n -c \
      --argjson sc "$q_sc" \
      --arg alldirs "$q_alldirs" \
      --arg ticks "$q_ticks" \
      --argjson f "$q_filters" \
      "$MENTOR_QUERY_JQ")" || {
        echo "[mentor plan-state] query: the read failed (corrupt sidecar or jq error)." >&2
        exit 1
      }

    # --- output layer: sort, limit, project, format ------------------------------
    # `--fields` takes dot paths (`steps.total`, `owner`) resolved with getpath, so a
    # caller can pull one scalar out of a nested field without a second jq of their own.
    q_out="$(printf '%s' "$q_out" | jq -c \
      --arg sort "$q_sort" --arg limit "$q_limit" '
      def path_of($s): ($s | split("."));
      (if $sort == "" then . else sort_by(getpath(path_of($sort))) end)
      | (if $limit == "" then . else .[0:($limit | tonumber)] end)')"

    case "$q_format" in
      count)
        printf '%s' "$q_out" | jq 'length'
        ;;
      slug)
        printf '%s' "$q_out" | jq -r '.[] | .slug // empty'
        ;;
      json)
        if [ -n "$q_fields" ]; then
          printf '%s' "$q_out" | jq --arg fields "$q_fields" '
            ($fields | split(",") | map(select(length > 0))) as $F
            | map(. as $e | reduce $F[] as $f ({}; .[$f] = ($e | getpath($f | split(".")))))'
        else
          printf '%s' "$q_out" | jq '.'
        fi
        ;;
      tsv|table)
        # Default columns mirror `list`'s five, so a `--format table` with no --fields
        # reads like the table people already know.
        q_cols="${q_fields:-slug,state,group,order}"
        q_tsv="$(printf '%s' "$q_out" | jq -r --arg fields "$q_cols" '
          ($fields | split(",") | map(select(length > 0))) as $F
          | .[] | . as $e
          | [ $F[] as $f
              | ($e | getpath($f | split(".")))
              | if . == null then "-"
                elif type == "array"  then (map(tostring) | join(" "))
                elif type == "object" then (tostring)
                else tostring end ]
          | @tsv')"
        if [ "$q_format" = "tsv" ]; then
          [ -n "$q_tsv" ] && printf '%s\n' "$q_tsv"
        else
          if [ -z "$q_fields" ]; then
            # print_table's own widths, so the default table lines up with `list`.
            printf '%-3s %-13s %-38s %-24s %s\n' "#" "STATE" "PLAN" "GROUP" "ORDER"
            q_i=0
            while IFS="$(printf '\t')" read -r q_c1 q_c2 q_c3 q_c4; do
              [ -n "$q_c1" ] || continue
              q_i=$((q_i + 1))
              printf '%-3s %-13s %-38s %-24s %s\n' "$q_i" "$q_c2" "$q_c1" "$q_c3" "$q_c4"
            done <<<"$q_tsv"
          else
            # An arbitrary --fields set has no pre-agreed widths, so size each column
            # to its own widest cell (header included) rather than truncating into
            # `list`'s layout, which was chosen for a different five columns.
            printf '%s\n' "$q_tsv" | awk -F'\t' -v hdr="$q_cols" '
              BEGIN { n = split(hdr, H, ",") ; for (i = 1; i <= n; i++) w[i] = length(H[i]) }
              { for (i = 1; i <= n; i++) if (length($i) > w[i]) w[i] = length($i); rows[NR] = $0 }
              END {
                for (i = 1; i <= n; i++) printf "%-*s%s", w[i], toupper(H[i]), (i < n ? "  " : "\n")
                for (r = 1; r <= NR; r++) {
                  split(rows[r], C, "\t")
                  for (i = 1; i <= n; i++) printf "%-*s%s", w[i], C[i], (i < n ? "  " : "\n")
                }
              }'
          fi
        fi
        ;;
    esac
    ;;

  # --- verify <slug>: the ONE call planning's "Verify the write" (SKILL.md, Step 4)
  # needs before every approval ask. Replaces a fresh awk/grep one-liner the agent
  # was observed hand-rebuilding differently on 5 consecutive asks in one session —
  # never the same check twice, and the one ask that dropped the table check is
  # exactly where a table-adjacent defect landed. A script call cannot exhibit a
  # partial-copy failure the way a freshly-typed one-liner can.
  #
  # Four DETERMINISTIC checks gate the exit code (fence balance, table pipe-count
  # uniformity, every step body carrying a `Done when:`, and — for a draft/unknown
  # plan only — the v6 run sections `## Goal check` + `## Decision log`) — the first two already
  # mandated in SKILL.md:447-460 prose, backed by nothing until now; the third is
  # documented at its implementation below. The rest print as informational CHECK:
  # lines and never fail verify (a stray ✅ and an `###` inside the steps section,
  # both documented below, plus untraced steps in a stored draft):
  # Rev-note order (the plugin's content spec does not mandate a Rev-note changelog
  # at all, so flagging its ABSENCE would be a false-positive machine; when Rev
  # lines DO exist this only reports a non-monotonic sequence, it never blocks) and
  # the CONTEXT verdict (folds planning/SKILL.md's separately-mandated pre-ask
  # context re-check into the one command the agent already calls reliably, rather
  # than a second command observed skipped before half this session's asks; the
  # calling skill still decides how to surface HIGH/WARN via `context` itself).
  verify)
    slug="${1:-}"; [ "$#" -gt 0 ] && shift
    if [ "$#" -gt 0 ]; then
      echo "[mentor plan-state] verify: unexpected argument ${1}" >&2
      usage >&2
      exit 1
    fi
    require_slug "$slug"
    plan_md="${plans_dir}/${slug}/plan.md"
    if [ ! -f "$plan_md" ]; then
      echo "[mentor plan-state] verify: no plan.md at ${plan_md}." >&2
      exit 1
    fi
    v_fail=0

    # `|| true` on every substitution below: under this file's `set -euo pipefail`,
    # grep/a pipeline legitimately finding ZERO matches (no fences, no tables, no Rev
    # lines — the common case for the last of those, since Rev headers aren't part of
    # the content spec) exits non-zero and would otherwise abort verify entirely
    # before it prints a single CHECK: line.
    v_fences=$(grep -c '^```' "$plan_md" || true)
    if [ $((v_fences % 2)) -eq 0 ]; then
      echo "CHECK: fences balanced (${v_fences} markers)"
    else
      echo "CHECK: fences UNBALANCED (${v_fences} markers — an odd count means one never closed)"
      v_fail=1
    fi

    # Every contiguous block of '|'-led lines must share one pipe count — a splice
    # that drops/adds a column mid-table doesn't error on write, it just breaks here.
    v_bad_tables="$(awk '
      /^\|/ {
        n = gsub(/\|/, "|", $0)
        if (block == 0) { block = 1; first = n; start = NR }
        else if (n != first) { bad = 1 }
        next
      }
      block == 1 {
        if (bad == 1) print "line " start ": pipe-count mismatch"
        block = 0; bad = 0
      }
      END { if (block == 1 && bad == 1) print "line " start ": pipe-count mismatch" }
    ' "$plan_md" || true)"
    if [ -z "$v_bad_tables" ]; then
      echo "CHECK: tables uniform (one pipe-count per block)"
    else
      echo "CHECK: table pipe-count MISMATCH:"
      printf '%s\n' "$v_bad_tables" | sed 's/^/  /'
      v_fail=1
    fi

    # Step-structure checks (v2.36.0), reading mentor_plan_step_scan (lib/state.sh) —
    # the ONE derivation, so verify can never disagree with tick/query about what a
    # step is. Only the first GATES: every step body
    # carrying a `Done when:` holds across all 14 step-bearing plans in this repo with
    # zero exceptions, and its ABSENCE is the direct symptom of a body truncated by a
    # phantom step line — the class the `[.]` delimiter fix in lib/state.sh closed.
    # The other two only report, because both fire on legitimate authoring: a ✅ off a
    # step line is a stray tick about half the time and the rest of the time is prose
    # quoting the character (a `Prompt sketch:` describing tick state), and an `###`
    # inside the section is a real subsection that step-body extraction nonetheless
    # glues onto the step above.
    v_scan="$(mentor_plan_step_scan "$plan_md" || true)"
    v_total="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "TOTAL" { print $2 }' || true)"
    v_nodw="$(printf '%s\n' "$v_scan" | awk -F'\t' '
      $1 == "STEP" && $6 == 0 {
        h = $8; for (i = 9; i <= NF; i++) h = h "\t" $i
        printf "%d %s\n", $3, substr(h, 1, 60)
      }' || true)"
    if [ "${v_total:-0}" -eq 0 ]; then
      echo "CHECK: no ## Implementation steps section (not yet fleshed out)"
    elif [ -z "$v_nodw" ]; then
      echo "CHECK: step bodies complete (${v_total} step(s), each carrying a Done when:)"
    else
      echo "CHECK: step body INCOMPLETE — no Done when: under:"
      printf '%s\n' "$v_nodw" | sed 's/^/  line /'
      v_fail=1
    fi
    # Traceability is a drafting aid, never a gate or a retrofit of released data.
    # Reuse the shared scanner's body boundaries; only a Goal line can trace a step.
    if [ "$(mentor_plan_state_stored "${plans_dir}/${slug}")" = "draft" ]; then
      awk -F'\t' '
        NR == FNR {
          if ($1 == "STEP") {
            total = $2
            for (line = $3 + 1; line <= $4; line++) step_at[line] = $2
          }
          next
        }
        step_at[FNR] && /^[[:space:]]*(-[[:space:]]+)?([*][*])?Goal:([*][*])?[[:space:]]/ {
          if (index($0, "serves S") > 0) traced[step_at[FNR]] = 1
        }
        END {
          for (step = 1; step <= total; step++)
            if (!traced[step]) printf "CHECK: untraced step %d\n", step
        }
      ' <(printf '%s\n' "$v_scan") "$plan_md" || true
    fi
    # v6.0.0: a plan still being written (effective draft/unknown) must carry the two
    # sections the run reads — `## Goal check` (what "done" is) and `## Decision log`
    # (what the human reviews afterwards). Plans already past draft are legacy data and
    # skip this check, so released plans keep verifying (AGENTS.md compatibility rule).
    v_eff="$(mentor_plan_effective_state "${plans_dir}/${slug}")"
    case "$v_eff" in
      draft|unknown)
        v_missing=""
        grep -q '^## Goal check' "$plan_md" || v_missing="${v_missing} ## Goal check,"
        grep -q '^## Decision log' "$plan_md" || v_missing="${v_missing} ## Decision log,"
        if [ -z "$v_missing" ]; then
          echo "CHECK: run sections present (## Goal check, ## Decision log)"
        else
          echo "CHECK: run section MISSING:${v_missing%,} — a new plan needs both before approval"
          v_fail=1
        fi
        ;;
      *)
        echo "CHECK: run sections not required (state ${v_eff} — only a draft plan is checked)"
        ;;
    esac
    v_tick="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "XTICK" { print $2 }' | paste -sd, - || true)"
    if [ -n "$v_tick" ]; then
      echo "CHECK: ✅ on a non-step line inside ## Implementation steps (line ${v_tick}) — the tick counter cannot see it (informational only)"
    fi
    v_glue="$(printf '%s\n' "$v_scan" | awk -F'\t' '$1 == "GLUE" { print $2 }' | paste -sd, - || true)"
    if [ -n "$v_glue" ]; then
      echo "CHECK: ### heading inside ## Implementation steps (line ${v_glue}) — step-body extraction glues it onto the step above (informational only)"
    fi

    v_revseq="$(sed '/^##/q' "$plan_md" | grep -oE '^Rev [0-9]+' | grep -oE '[0-9]+' || true)"
    if [ -n "$v_revseq" ]; then
      v_mono="$(printf '%s\n' "$v_revseq" | awk '
        NR == 1 { prev = $1; next }
        { if ($1 > prev) asc = 1; if ($1 < prev) desc = 1; prev = $1 }
        END { print (asc && desc) ? "no" : "yes" }
      ')"
      v_seq_str="$(printf '%s' "$v_revseq" | paste -sd, -)"
      if [ "$v_mono" = "yes" ]; then
        echo "CHECK: Rev-note order monotonic (${v_seq_str})"
      else
        echo "CHECK: Rev-note order NOT monotonic (${v_seq_str}) — changelog may be hard to scan (informational only)"
      fi
    fi

    v_ctx_repo="$(mentor_repo_root "$(pwd)")"
    v_verdict="$(mentor_context_verdict "$v_ctx_repo" "$(pwd)")"
    if [ -n "$v_verdict" ]; then
      read -r v_ctx_level v_ctx_tokens v_ctx_rest <<<"$v_verdict"
      echo "CHECK: context ${v_ctx_level} (~${v_ctx_tokens} tokens)"
    else
      echo "CHECK: context UNKNOWN (not measurable — gate off, or no transcript/jq)"
    fi

    [ "$v_fail" -eq 0 ] && exit 0
    exit 1
    ;;

  list)
    filter=""; list_owners=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --group) filter="${2:-}"; shift; if [ "$#" -gt 0 ]; then shift; fi ;;
        --owners) list_owners=1; shift ;;
        *) echo "[mentor plan-state] list: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    echo "PLANS_DIR: ${plans_dir}"
    echo
    if ! print_table "$filter" "$list_owners"; then
      echo "[mentor plan-state] No plans${filter:+ in group ${filter}} in ${plans_dir}." >&2
      exit 0
    fi
    echo
    echo "Plan files are PLANS_DIR/<PLAN>/plan.md. 'unknown' = a pre-2.4.0 plan with no state on record."
    ;;

  current)
    cur_any=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --any) cur_any=1; shift ;;
        *) echo "[mentor plan-state] current: unexpected argument ${1}" >&2; usage >&2; exit 1 ;;
      esac
    done
    cur_wt_id=""
    [ "$cur_any" -eq 1 ] || cur_wt_id="$(mentor_worktree_id "$(pwd)")"
    # Scoped to plans owned by THIS worktree (or unowned) — callers WRITE to the plan
    # `current` resolves, so an unscoped read would let worktree A silently rewrite
    # worktree B's in-flight draft. --any drops the filter for a deliberate,
    # repo-wide read (mentor_newest_plan_owned with an empty wt-id is unfiltered).
    plan="$(mentor_newest_plan_owned "$plans_dir" "$cur_wt_id")"
    if [ -z "$plan" ]; then
      if [ "$cur_any" -eq 1 ]; then
        echo "[mentor plan-state] No plan found in ${plans_dir}." >&2
      else
        echo "[mentor plan-state] No plan owned by this worktree found in ${plans_dir} (plans owned by another worktree are excluded — use --any for a repo-wide, unfiltered read, or /mentor:plan <slug> to re-own one)." >&2
      fi
      exit 0
    fi
    plan_dir="$(dirname "$plan")"
    group="$(mentor_plan_group "$plan_dir")"

    # Inside a split group, mtime order is just "whichever child agent finished last".
    # Re-pick deterministically: lowest `order` that is not already done.
    if [ -n "$group" ]; then
      pick=""; fallback=""
      while IFS="$(printf '\t')" read -r _ s st _ _; do
        [ -n "$s" ] || continue
        [ -n "$fallback" ] || fallback="$s"
        case "$st" in
          implemented|superseded) ;;
          *) [ -n "$pick" ] || pick="$s" ;;
        esac
      done <<<"$(list_rows "$group")"
      [ -n "$pick" ] || pick="$fallback"
      if [ -n "$pick" ]; then
        plan_dir="${plans_dir}/${pick}"
        plan="${plan_dir}/plan.md"
      fi
    fi

    echo "PLAN: ${plan}"
    echo "SLUG: $(basename "$plan_dir")"
    echo "STATE: $(mentor_plan_effective_state "$plan_dir")"
    echo "GROUP: ${group:--}"
    if [ -n "$group" ]; then
      echo
      echo "This plan is one of a split group. PLAN above is only the first unfinished"
      echo "sibling — do NOT assume it is the one the user means. Ask which sibling (or all):"
      echo
      print_table "$group" || true
    fi
    ;;

esac

exit 0
