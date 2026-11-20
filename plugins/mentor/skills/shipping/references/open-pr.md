# Open a PR or MR

Use this transport after the caller's preparation and approval checks; explicit
inputs keep a multi-repository caller from pushing the shell's current checkout.

Inputs: `repo_root` (absolute git worktree root), `branch`, `base`, `title`, and
`body_file` (absolute prepared body path). Re-resolve and validate these in each
shell call; never rely on variables surviving a prior tool call. Retros always
supply a title and checked body. Shipping alone may supply empty title/body-file
for GitHub's existing `--fill` behaviour. A nonempty body file must exist and be
readable before any push. Do not evaluate its contents as shell code.

Detect the host from `git -C "$repo_root" remote get-url origin`; verify `branch`
and `base` are nonempty and `branch` exists. Honour the caller's branch permissions.
Never force-push. On rerun, query this branch's review first and reuse its URL after
checking its ownership and target; never open a duplicate or change another author's
review. Push updates to an existing authorized review when the commit is not remote yet.

## GitHub

Check the push exit status explicitly and stop with **not opened** on failure.
This prevents an existing PR from being reported with stale commits (see **Review
transport failures** in [rationale.md](rationale.md)).

Run inside the explicit repository so `gh` resolves the intended remote:

```bash
if ! git -C "$repo_root" push -u origin "$branch"; then
  printf 'not opened: repository=%s branch=%s reason=git push failed\n' "$repo_root" "$branch" >&2
  exit 1
fi
if [ -n "$body_file" ]; then
  (cd "$repo_root" && gh pr create --base "$base" --head "$branch" \
    --title "$title" --body-file "$body_file")
else
  (cd "$repo_root" && gh pr create --base "$base" --head "$branch" --fill)
fi
(cd "$repo_root" && gh pr view "$branch" --json url,state,headRefName,baseRefName)
```

Confirm `state` is `OPEN` and head/base match the inputs; return the URL and target.
If creation says a PR already exists, query and reuse that branch's own open PR.
Shipping without `gh` prints a compare URL. Retro checks availability before pushing
and retains local changes when `gh` is unavailable.

## GitLab

For retros, require `glab` before any push; otherwise return **not opened**, keep
the changes local and report the missing tool. The body is required for retro review.

Run this block only when the rerun query above found no review for this branch;
for an existing authorized review, run the push line alone (same exit check) and
reuse that review's URL. Check push and create exit statuses explicitly; on failure,
stop and return **not opened** with the repository, branch and reason. This prevents
a stale remote branch from being reported as the completed review (see **Review
transport failures** in [rationale.md](rationale.md)).

For shipping, prefer `glab` and use title-only push options when it is unavailable:

```bash
if command -v glab >/dev/null 2>&1; then
  if ! git -C "$repo_root" push -u origin "$branch"; then
    printf 'not opened: repository=%s branch=%s reason=git push failed\n' "$repo_root" "$branch" >&2
    exit 1
  fi
  description=""
  if [ -n "$body_file" ]; then
    description="$(cat "$body_file")"
  fi
  if ! (cd "$repo_root" && glab mr create --source-branch "$branch" \
    --target-branch "$base" --title "$title" --remove-source-branch \
    --description "$description"); then
    printf 'not opened: repository=%s branch=%s reason=glab mr create failed\n' "$repo_root" "$branch" >&2
    exit 1
  fi
  (cd "$repo_root" && glab mr view "$branch" --output json)
else
  if ! git -C "$repo_root" push -u origin "$branch" \
    -o merge_request.create -o "merge_request.target=$base" \
    -o merge_request.remove_source_branch \
    -o "merge_request.title=$title"; then
    printf 'not opened: repository=%s branch=%s reason=git push with merge-request options failed\n' "$repo_root" "$branch" >&2
    exit 1
  fi
  printf 'MR body was not attached; local body file: %s\n' "$body_file"
fi
```

With `glab`, confirm `state` is `opened`, source/target branches match the inputs,
and `web_url` exists; return that URL and target. Without `glab`, surface the
`/-/merge_requests/` URL and target from the push response and report that the body
was not attached, naming its local file. Never pass a description through push
options: Git rejects options containing newlines.

A `WARNINGS:`
block naming `merge_request.target` means the MR did not open: re-resolve the base
and retry (standalone shipping asks; a plan caller follows its authority and logs
the decision). An already-open-MR warning is safe only for this branch's own review;
check its author/title and target, since push options do not retarget an existing MR.
A pushed branch or compare URL is never evidence of an open PR/MR.

A retro body over a host length limit is trimmed by its template's **Trimming for host
length limits** rule ([pr-body.md](../../planning/references/playbooks/retrospective/pr-body.md))
and must pass `retro-pr-body-check.sh` again before upload.

## Other hosts and failures

Shipping pushes and prints a compare URL for other hosts; retro keeps the changes
local. Return **not opened** with its repository, branch and reason; the caller owns
reporting and resume.
A non-fast-forward rejection requires resolving remote movement, never force-pushing.
A server rejection cannot be repaired by rebasing blindly. Follow shipping's failure
rules or the retro's kept-local/always-pause rules, as selected by the caller.
