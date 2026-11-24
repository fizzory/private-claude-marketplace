#!/usr/bin/env python3
"""Short repo-shared run transactions (Python stdlib, macOS and Linux).

`lock FD` flocks the descriptor opened by the shell on the shared directory.
The shell retains that same open description after this helper exits. Nested
helpers reuse it, never reacquire another open description. Only `inspect` is
read-only; all other operations validate their inherited FD against DIR.
Content/lifecycle decisions must be read again *inside* the transaction. Hooks
may suppress a lock refusal; managed commands must propagate its nonzero status.
"""

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
import time

COMPANIONS = (".idle", ".wait", ".ptr")
TERMINAL = {"implemented", "failed", "superseded"}


def refuse(message):
    raise ValueError(message)


def number(name, default, maximum=None):
    try:
        value = float(os.environ.get(name, default))
        if not math.isfinite(value) or value <= 0:
            raise ValueError()
        return min(value, maximum) if maximum else value
    except ValueError:
        return default


def held(fd, directory):
    try:
        actual, expected = os.fstat(fd), directory.stat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            return False
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def lock(fd):
    deadline = time.monotonic() + number("MENTOR_RUN_LOCK_TIMEOUT_SECONDS", 1.0, 2.0)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                refuse("run state is busy; retry the command")
            time.sleep(0.01)


def valid_slug(value):
    # Released directories can have spaces and non-ASCII names. The marker
    # format requires one line and the plan path requires one basename.
    return bool(value and value not in {".", ".."}
                and not re.search(r"[/\x00-\x1f\x7f-\x9f\u2028\u2029]", value))


def identity(value):
    return bool(value not in {".", "..", "nosession"}
                and re.fullmatch(r"[A-Za-z0-9_.-]+", value))


def lease_seconds():
    return 60 * number("MENTOR_PLAN_MARKER_STALE_MIN", 480)


def metadata(path):
    try:
        return dict(reversed([line.split("=", 1) for line in path.read_text().splitlines()
                              if "=" in line]))
    except (OSError, UnicodeError):
        return {}


def sidecar(directory, slug):
    try:
        value = json.loads((directory / "plans" / slug / ".state.json").read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def claims(directory):
    now = time.time()
    lease = lease_seconds()
    result = []
    for path in sorted(directory.glob(".run-*")):
        session = path.name[len(".run-"):]
        # Companions may contain arbitrary user/task text, even slug= lines.
        if session.endswith(COMPANIONS) or not path.is_file():
            continue
        fields = metadata(path)
        slug = fields.get("slug", "")
        if not valid_slug(slug) or not identity(session):
            continue
        state = sidecar(directory, slug)
        stored = state.get("state", "")
        if not isinstance(stored, str):
            stored = ""
        try:
            fresh = now < path.stat().st_mtime + lease
        except OSError:
            continue
        result.append(dict(session=session, slug=slug, path=str(path),
                           worktree=fields.get("worktree") or state.get("owner") or "",
                           fresh=fresh, state=stored,
                           note=state.get("note", ""),
                           live=fresh and stored not in TERMINAL and (directory / "plans" / slug).is_dir()))
    return result


def check(directory, slug, session):
    rows = claims(directory)
    same = [c for c in rows if c["slug"] == slug and c["state"] not in TERMINAL]
    # A fresh replacement and its unretired stale predecessor are a conflict too.
    reserved = same if any(c["live"] for c in same) else []
    if len(reserved) > 1:
        refuse(f"{slug} has conflicting run claims; explicit begin-run {slug} --takeover is required")
    if reserved and (not identity(session) or reserved[0]["session"] != session):
        refuse(f"{slug} is owned by Claude session {reserved[0]['session']}; no write")
    return reserved


def running(claim):
    return claim["state"] == "in_progress" or (
        claim["state"] == "approved" and not str(claim["note"]).startswith("paused:")
    )


def admit(directory, worktree, session, slug=""):
    """Worktree admission is separate from repository-wide named-slug checks."""
    for claim in claims(directory):
        if worktree and claim["live"] and claim["worktree"] == worktree and running(claim):
            if (slug and claim["slug"] != slug) or (not slug and claim["session"] != session):
                refuse(f"worktree is reserved by {claim['slug']} (Claude session {claim['session']})")
            if slug:
                check(directory, slug, session)


def atomic(path, data):
    fd, tmp = tempfile.mkstemp(prefix=".mentor-run-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def cleanup(directory, session, marker=True):
    if not identity(session):
        refuse("invalid session identity")
    path = directory / (".run-" + session)
    for suffix in COMPANIONS:
        path.with_name(path.name + suffix).unlink(missing_ok=True)
    if marker:
        path.unlink(missing_ok=True)


def claim(directory, slug, session, worktree, takeover=False):
    existing = claims(directory)
    live = [c for c in existing if c["live"]]
    if session and session != "nosession" and not identity(session):
        refuse("invalid session identity")
    if session.endswith(COMPANIONS):
        refuse("session identity collides with a reserved run companion suffix")
    if not identity(session):
        if takeover:
            refuse("takeover requires a Claude session identity")
        check(directory, slug, session)
        return  # Hookless continuation, only when no live claim exists.
    if not valid_slug(slug) or not worktree:
        refuse("invalid slug or missing worktree identity")
    same = [c for c in existing if c["slug"] == slug]
    target = directory / (".run-" + session)
    for c in live:
        if c["slug"] != slug and (c["session"] == session or (c["worktree"] == worktree and running(c))):
            refuse(f"session/worktree already runs {c['slug']}; no claim written")
    if not takeover:
        check(directory, slug, session)
    own = next((c for c in same if c["session"] == session and c["live"]), None)
    if own and len([c for c in same if c["live"]]) == 1 and not takeover:
        os.utime(target, None)  # Preserve marker and normal begin-run sidecar bytes.
        return
    # Publish first: a kill before retirement leaves a visible reservation/conflict,
    # never a markerless window in which the previous owner can write.
    source = target if target.exists() and metadata(target).get("slug") == slug else (
        Path(same[0]["path"]) if same else None)
    fields = metadata(source) if source else {}
    fields.update(slug=slug, worktree=worktree)
    fields.setdefault("started", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    atomic(target, "".join(f"{k}={v}\n" for k, v in fields.items()))
    if takeover or same:
        path = directory / "plans" / slug / ".state.json"
        state = sidecar(directory, slug)
        state["owner_session"] = session
        atomic(path, json.dumps(state, indent=2) + "\n")
    # Existing target companions belong to the prior claim too, including a retry
    # after an interrupted transfer. Do not match session prefixes or glob cleanup.
    cleanup(directory, session, marker=False)
    for c in same:
        if c["session"] != session:
            cleanup(directory, c["session"])


def companion(claim, suffix):
    return Path(claim["path"] + suffix)


def read_wait(claim):
    try:
        wait = json.loads(companion(claim, ".wait").read_text())
        expires = wait["expires"]
        if (wait["slug"] == claim["slug"] and type(expires) in (int, float)
                and math.isfinite(expires) and isinstance(wait["label"], str)):
            return wait
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def declare_wait(directory, slug, session, label, ttl):
    owned = check(directory, slug, session)
    if not owned or owned[0]["state"] != "in_progress":
        refuse("a wait requires this session's live in-progress run")
    label = " ".join(label.split())
    if not label:
        refuse("a wait requires a nonempty label")
    lease = lease_seconds()
    duration = int(ttl) * 60 if ttl else min(3600, lease)
    if duration <= 0 or duration > lease:
        refuse("wait TTL must be positive and no longer than the run lease")
    claim = owned[0]
    atomic(companion(claim, ".wait"), json.dumps(
        dict(slug=slug, label=label, expires=time.time() + duration)) + "\n")
    os.utime(claim["path"], None)


def progress_fingerprint(plan):
    paths = [plan / "plan.md"]
    verdict_dir = plan / "verdicts"
    paths.extend(item for item in verdict_dir.glob("*.md")
                 if re.fullmatch(r"(step-\d+|topic-\d+|goal|pr|after-merge)\.md", item.name))
    for item in plan.glob("*-verify.md"):
        match = re.fullmatch(r"(step-\d+|topic-\d+|goal)-verify\.md", item.name)
        if match and not os.path.lexists(verdict_dir / (match[1] + ".md")):
            paths.append(item)
    digest = hashlib.sha256()
    for path in sorted(paths):
        if not path.is_file():
            continue
        digest.update(os.fsencode(path.relative_to(plan)) + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def read_companion(path):
    try:
        return path.read_text().rstrip("\n")
    except FileNotFoundError:
        return ""


def stop(directory, session, in_flight, limit):
    rows = claims(directory)
    claim = next((item for item in rows if item["session"] == session), None)
    if not claim:
        return
    slug = claim["slug"]
    plan = directory / "plans" / slug
    wait = read_wait(claim)
    if claim["state"] in TERMINAL or not (plan / "plan.md").is_file():
        cleanup(directory, session)
        return
    if not claim["fresh"]:
        if not wait and not any(item["live"] and item["slug"] == slug for item in rows):
            cleanup(directory, session)
        return
    if claim["state"] != "in_progress" or not check(directory, slug, session):
        return
    os.utime(claim["path"], None)
    if in_flight == "true" or wait or re.fullmatch(r"0+", limit):
        return
    fingerprint = slug + ":" + progress_fingerprint(plan)
    idle = companion(claim, ".idle")
    if read_companion(idle) != fingerprint:
        atomic(idle, fingerprint + "\n")
        print(slug)


def wake(directory, session, event):
    rows = claims(directory)
    claim = next((item for item in rows if item["session"] == session), None)
    if not claim:
        return
    slug = claim["slug"]
    if any(item["live"] and item["slug"] == slug and item["session"] != session for item in rows):
        return
    if claim["state"] in TERMINAL:
        cleanup(directory, session)
        return
    owned = check(directory, slug, session)
    wait = read_wait(claim)
    expired = wait and time.time() >= wait["expires"]
    if expired or event == "prompt":
        companion(claim, ".wait").unlink(missing_ok=True)
        if expired:
            print(f"mentor run {slug}: background wait expired ({wait['label']}). Check the job before continuing.")
        wait = None
    if owned:
        os.utime(claim["path"], None)
    elif not wait:
        cleanup(directory, session)


def pointer(directory, slug, session, synthetic, line):
    owned = check(directory, slug, session)
    if not owned:
        return
    path = companion(owned[0], ".ptr")
    previous = read_companion(path)
    if previous != line:
        atomic(path, line + "\n")
    if synthetic != "1" or previous != line:
        print(line)


def main():
    operation, *args = sys.argv[1:]
    if operation == "lock":
        lock(int(args[0]))
        return 0
    if operation == "inspect":
        directory = Path(args[0]).resolve()
        print(json.dumps(claims(directory)))
    else:
        raw_fd, raw, *args = args
        directory = Path(raw).resolve()
        if not held(int(raw_fd), directory):
            refuse("run operation requires mentor_with_run_lock")
        if operation == "validate":
            return 0
        if operation == "guard":
            slug, session, worktree, *flags = args
            check(directory, slug, session)
            if "admit" in flags:
                admit(directory, worktree, session, slug)
        elif operation == "claim":
            claim(directory, *args[:3], takeover="--takeover" in args[3:])
        elif operation == "wait":
            declare_wait(directory, *args)
        elif operation == "stop":
            stop(directory, *args)
        elif operation == "wake":
            wake(directory, *args)
        elif operation == "pointer":
            pointer(directory, *args)
        elif operation in {"renew", "activity"}:
            slug, session = args
            live = check(directory, slug, session)
            if not live:
                if operation == "renew":
                    refuse("expired or absent claim cannot be renewed")
                return 0
            os.utime(live[0]["path"], None)
        elif operation in {"close", "finish"}:
            slug = args[0]
            if operation == "finish":
                check(directory, slug, args[1])
            state = sidecar(directory, slug)
            for c in claims(directory):
                if c["slug"] == slug and state.get("state") in TERMINAL:
                    cleanup(directory, c["session"])
                elif (operation == "finish" and c["slug"] == slug
                      and state.get("state") == "approved"
                      and str(state.get("note", "")).startswith("paused:")):
                    Path(c["path"] + ".wait").unlink(missing_ok=True)
        elif operation == "cleanup":
            slug, session, mode = args
            check(directory, slug, session)
            path = directory / (".run-" + session)
            if metadata(path).get("slug") == slug:
                if mode == "companions":
                    # Human pause preserves the stall and pointer memory; only
                    # its now-invalid background wait is discarded.
                    Path(str(path) + ".wait").unlink(missing_ok=True)
                else:
                    cleanup(directory, session)
        else:
            refuse("unknown run operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"[mentor run] {error}", file=sys.stderr)
        sys.exit(1)
