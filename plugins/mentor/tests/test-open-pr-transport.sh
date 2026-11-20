#!/usr/bin/env bash
# Execute the documented PR/MR transport with isolated command doubles.
set -euo pipefail
plugin_root="$(cd "$(dirname "$0")/.." && pwd -P)"
python3 - "$plugin_root" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

reference = (Path(sys.argv.pop()) / "skills/shipping/references/open-pr.md").read_text()
gitlab = reference.split("## GitLab", 1)[1].split("## Other hosts", 1)[0]
github = reference.split("## GitHub", 1)[1].split("## GitLab", 1)[0]
transports = {
    host: re.search(r"```bash\n(.*?)\n```", section, re.S).group(1)
    for host, section in (("gitlab", gitlab), ("github", github))
}


class ReviewTransportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.repo = self.root / "repository with spaces"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "cat").symlink_to(shutil.which("cat"))
        self.log = self.root / "calls.jsonl"
        self.body = self.root / "review body.md"
        self.marker = self.root / "must-not-exist"
        self.content = (
            "Review the change.\n\n## Changes\n\n"
            f"Literal $(touch '{self.marker}') and `touch '{self.marker}'`.\n"
        )
        self.body.write_text(self.content)
        self.env = {
            **os.environ,
            "PATH": str(self.bin),
            "HOME": str(self.root / "home"),
            "CALL_LOG": str(self.log),
            "repo_root": str(self.repo),
            "branch": "retro/example",
            "base": "develop",
            "title": 'Review "the change"',
            "body_file": str(self.body),
        }
        self.install_double("git")

    def install_double(self, name):
        command = self.bin / name
        command.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "name = Path(sys.argv[0]).name\n"
            "with open(os.environ['CALL_LOG'], 'a') as out:\n"
            "    out.write(json.dumps([name, os.getcwd(), sys.argv[1:]]) + '\\n')\n"
            "if name == 'git':\n"
            "    sys.exit(int(os.environ.get('MOCK_GIT_EXIT', '0')))\n"
            "if sys.argv[1:3] in (['mr', 'create'], ['pr', 'create']):\n"
            "    sys.exit(int(os.environ.get('MOCK_CREATE_EXIT', '0')))\n"
            "if sys.argv[1:3] == ['mr', 'view']:\n"
            "    print(json.dumps({'state': 'opened', 'source_branch': 'retro/example',\n"
            "                      'target_branch': 'develop',\n"
            "                      'web_url': 'https://gitlab.example/repo/-/merge_requests/1'}))\n"
            "if sys.argv[1:3] == ['pr', 'view']:\n"
            "    print(json.dumps({'state': 'OPEN', 'headRefName': 'retro/example',\n"
            "                      'baseRefName': 'develop',\n"
            "                      'url': 'https://github.example/repo/pull/1'}))\n"
        )
        command.chmod(0o755)

    def run_transport(self, host="gitlab", script=None):
        result = subprocess.run(
            ["/bin/bash", "-u", "-c", transports[host] if script is None else script], env=self.env,
            capture_output=True, text=True,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def existing_gitlab_review_script(self):
        # The rerun query/authorization is prose shared by both callers. Execute
        # its push-only route using the guard extracted from the actual block.
        instructions = " ".join(gitlab.split())
        self.assertIn("Run this block only when the rerun query above found no review", instructions)
        self.assertIn(
            "for an existing authorized review, run the push line alone (same exit check) "
            "and reuse that review's URL", instructions,
        )
        push = re.search(
            r'  if ! git -C "\$repo_root" push -u origin "\$branch"; then\n.*?\n  fi',
            transports["gitlab"], re.S,
        ).group(0)
        return (
            'existing_review="$(cd "$repo_root" && glab mr view "$branch" --output json)"\n'
            + push + '\nprintf \'%s\\n\' "$existing_review"\n'
        )

    def test_glab_preserves_multiline_body_and_confirms_review(self):
        self.install_double("glab")
        result, calls = self.run_transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["git", "glab", "glab"])
        self.assertEqual(calls[0][2], ["-C", str(self.repo), "push", "-u", "origin", "retro/example"])
        self.assertEqual(calls[1][1], str(self.repo))
        self.assertEqual(calls[1][2], [
            "mr", "create", "--source-branch", "retro/example", "--target-branch", "develop",
            "--title", self.env["title"], "--remove-source-branch",
            "--description", self.content.rstrip("\n"),
        ])
        self.assertEqual(calls[2][2], ["mr", "view", "retro/example", "--output", "json"])
        self.assertEqual(json.loads(result.stdout)["state"], "opened")
        self.assertFalse(self.marker.exists(), "body contents were evaluated as shell code")

    def test_shipping_without_glab_pushes_only_title_and_names_local_body(self):
        result, calls = self.run_transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][2], [
            "-C", str(self.repo), "push", "-u", "origin", "retro/example",
            "-o", "merge_request.create", "-o", "merge_request.target=develop",
            "-o", "merge_request.remove_source_branch",
            "-o", f"merge_request.title={self.env['title']}",
        ])
        self.assertIn("body was not attached", result.stdout)
        self.assertIn(str(self.body), result.stdout)
        self.assertTrue(all("\n" not in arg for arg in calls[0][2]))

    def test_shipping_without_body_uses_empty_description(self):
        self.install_double("glab")
        self.env["body_file"] = ""
        result, calls = self.run_transport()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(calls[1][2][-2:], ["--description", ""])

    def test_failed_push_does_not_create_review(self):
        self.install_double("glab")
        self.env["MOCK_GIT_EXIT"] = "1"
        result, calls = self.run_transport()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in calls], ["git"])
        self.assert_not_opened(result, "git push failed")

    def assert_not_opened(self, result, reason):
        self.assertIn("not opened", result.stderr)
        self.assertIn(str(self.repo), result.stderr)
        self.assertIn(self.env["branch"], result.stderr)
        self.assertIn(reason, result.stderr)

    def test_failed_push_options_do_not_report_an_open_review(self):
        self.env["MOCK_GIT_EXIT"] = "1"
        result, calls = self.run_transport()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in calls], ["git"])
        self.assert_not_opened(result, "git push with merge-request options failed")
        self.assertNotIn("body was not attached", result.stdout)

    def test_failed_creation_is_not_confirmed(self):
        self.install_double("glab")
        self.env["MOCK_CREATE_EXIT"] = "1"
        result, calls = self.run_transport()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in calls], ["git", "glab"])
        self.assert_not_opened(result, "glab mr create failed")

    def test_gitlab_rerun_pushes_and_reuses_existing_review_without_creating(self):
        self.install_double("glab")
        self.env["MOCK_CREATE_EXIT"] = "1"  # Creating an existing MR would fail.
        result, calls = self.run_transport(script=self.existing_gitlab_review_script())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["glab", "git"])
        self.assertEqual(calls[0][1], str(self.repo))
        self.assertEqual(calls[0][2], ["mr", "view", "retro/example", "--output", "json"])
        self.assertEqual(calls[1][2], ["-C", str(self.repo), "push", "-u", "origin", "retro/example"])
        self.assertEqual(
            json.loads(result.stdout)["web_url"], "https://gitlab.example/repo/-/merge_requests/1",
        )
        self.assertNotIn("not opened", result.stderr)

    def test_gitlab_rerun_failed_push_does_not_reuse_stale_review(self):
        self.install_double("glab")
        self.env["MOCK_GIT_EXIT"] = "1"
        result, calls = self.run_transport(script=self.existing_gitlab_review_script())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in calls], ["glab", "git"])
        self.assert_not_opened(result, "git push failed")
        self.assertEqual(result.stdout, "")

    def test_github_failed_push_does_not_create_or_reuse_review(self):
        self.install_double("gh")
        self.env["MOCK_GIT_EXIT"] = "1"
        result, calls = self.run_transport(host="github")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in calls], ["git"])
        self.assert_not_opened(result, "git push failed")
        self.assertEqual(result.stdout, "")

    def test_github_existing_review_is_reused_after_successful_push(self):
        self.install_double("gh")
        self.env["MOCK_CREATE_EXIT"] = "1"
        result, calls = self.run_transport(host="github")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["git", "gh", "gh"])
        self.assertEqual(calls[1][1], str(self.repo))
        self.assertEqual(calls[1][2], [
            "pr", "create", "--base", "develop", "--head", "retro/example",
            "--title", self.env["title"], "--body-file", str(self.body),
        ])
        self.assertEqual(calls[2][2], [
            "pr", "view", "retro/example", "--json", "url,state,headRefName,baseRefName",
        ])
        self.assertEqual(json.loads(result.stdout)["url"], "https://github.example/repo/pull/1")


unittest.main()
PY
printf 'PASS mentor PR/MR transport (10 tests)\n'
