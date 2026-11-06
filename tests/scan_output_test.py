"""Exercise commit and transport boundaries using synthetic local repositories."""

import io
import json
import gzip
import bz2
import lzma
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check_scan_output.sh"


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.pop("CI", None)
        self.env.pop("GITHUB_ACTIONS", None)
        self.env["XDG_STATE_HOME"] = str(self.base / "state")
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "initial")
        self.initial = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], env=self.env,
            capture_output=True, text=True, check=check,
        )

    def check(self, *args, expected=0, env=None, text=None):
        proc = subprocess.run(
            ["bash", str(CHECK), "--repo", str(self.repo), *args],
            input=text, capture_output=True, text=True, env=env or self.env, cwd=self.repo,
        )
        self.assertEqual(proc.returncode, expected, proc.stderr)
        return proc

    def stage(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.git("add", "-f", "--", name)

    def commit(self, message="fixture"):
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", message)

    def report(self):
        return json.dumps({"tool": "foxguard", "findings": [], "finding_counts": {"total": 0}}).encode()

    def test_force_added_empty_named_report(self):
        self.stage("gitleaks.json", b"[]")
        self.check("--staged", expected=1)

    def test_renamed_and_nested_reports(self):
        for name in ("ordinary.json", "docs/notes.json", "vendor/nested/value.json"):
            with self.subTest(name=name):
                self.stage(name, self.report())
                self.check("--staged", expected=1)
                self.git("reset", "-q")

    def test_reserved_publication_directory_normalized(self):
        self.stage("scans/ordinary.txt", b"[]")
        for path in ("./scans/ordinary.txt", str(self.repo / "scans/ordinary.txt")):
            self.check("--file", path, expected=1)

    def test_sarif_and_wrapped_gitleaks(self):
        self.check("--stdin", text=json.dumps({"version": "2.1.0", "runs": []}), expected=1)
        self.check("--stdin", text=json.dumps({"data": [{"RuleID": "fixture", "Secret": "REDACTED"}]}), expected=1)

    def test_generic_empty_json_and_configuration(self):
        self.stage("data.json", b'{"version":"1.2.3","runs":[{"name":"build"}]}')
        self.stage(".gitleaksignore", b"# reviewed synthetic fixture\n")
        self.stage(".foxguard.yml", b"severity: high\n")
        self.stage("backend/scans/apps.py", b"name = 'business-scans'\n")
        self.check("--staged")

    def test_embedded_result_text(self):
        tool = "fox" + "guard"
        for text in (tool + ": 19 findings", "The scan: " + tool + " 19 findings to inspect.", "19 " + tool + " findings"):
            self.check("--stdin", text=text, expected=1)

    def test_ansi_and_utf16(self):
        self.stage("notes.md", ("fox" + "guard: 19 findings").encode("utf-16"))
        self.check("--staged", expected=1)
        self.check("--stdin", text="\x1b[31m" + "fox" + "guard: 19 findings\x1b[0m", expected=1)

    def test_archive_inspection_and_encrypted_failure(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("renamed.json", self.report())
        self.stage("bundle.zip", raw.getvalue())
        self.check("--staged", expected=1)
        self.stage("bundle.zip", b"broken")
        self.check("--staged", expected=2)

    def test_index_is_authoritative(self):
        self.stage("notes.json", self.report())
        (self.repo / "notes.json").write_text("[]")
        self.check("--staged", expected=1)

    @unittest.skipIf(os.name == "nt", "Control characters are not Windows filenames.")
    def test_unusual_path(self):
        self.stage("docs/a\tline\nfile.json", self.report())
        self.check("--staged", expected=1)

    def test_added_then_deleted_still_blocks_range(self):
        self.stage("renamed.json", self.report())
        self.commit()
        self.git("rm", "-q", "renamed.json")
        self.commit()
        self.check("--range", self.initial + "..HEAD", expected=1)

    def test_deletion_of_existing_report_allowed(self):
        self.stage("renamed.json", self.report())
        self.commit()
        before = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("rm", "-q", "renamed.json")
        self.commit()
        self.check("--range", before + "..HEAD")

    def test_commit_and_tag_messages(self):
        message = "fox" + "guard: 19 findings"
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", message)
        self.check("--range", self.initial + "..HEAD", expected=1)
        self.git("tag", "-a", "fixture", self.initial, "-m", message)
        oid = self.git("rev-parse", "fixture").stdout.strip()
        refs = self.base / "refs"
        refs.write_text("refs/tags/fixture " + oid + " refs/tags/fixture " + "0" * 40 + "\n")
        self.check("--push-refs", str(refs), expected=1)

    def test_native_console_results_refused(self):
        tool = "git" + "leaks"
        for status in ("11:00AM WRN leaks found: " + "19", "11:00AM INF no " + "leaks found"):
            self.check("--stdin", text=tool + "\n" + status, expected=1)

    def test_missing_or_malformed_range_refused(self):
        self.check("--range", "does-not-exist", expected=2)
        refs = self.base / "refs"
        refs.write_text("invalid\n")
        self.check("--push-refs", str(refs), expected=2)

    def test_noop_and_deletion_refs_allowed(self):
        refs = self.base / "refs"
        refs.write_text("refs/heads/x " + "0" * 40 + " refs/heads/x " + self.initial + "\n")
        self.check("--push-refs", str(refs))

    def test_renamed_compressed_reports_refused(self):
        for compress in (gzip.compress, bz2.compress, lzma.compress):
            with self.subTest(compress=compress.__module__):
                self.stage("ordinary.bin", compress(self.report()))
                self.check("--staged", expected=1)

    def test_ci_output_is_generic(self):
        env = {**self.env, "CI": "true"}
        proc = self.check("--stdin", env=env, text=self.report().decode(), expected=1)
        self.assertIn("check failed.", proc.stderr)
        self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)

    def test_real_commit_hook_refuses_force_added_report(self):
        self.git("config", "core.hooksPath", str(ROOT / "scripts/git-hooks"))
        self.stage("gitleaks.json", b"[]")
        proc = self.git("commit", "-qm", "blocked", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial)
        self.assertIn("Local report:", proc.stderr)

    def test_real_push_refused_before_bare_remote_receives_objects(self):
        remote = self.base / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.stage("ordinary.json", self.report())
        self.commit()
        forbidden = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("rm", "-q", "ordinary.json")
        self.commit()
        self.git("remote", "add", "origin", str(remote))
        self.git("config", "core.hooksPath", str(ROOT / "scripts/git-hooks"))
        for ci in (False, True):
            with self.subTest(ci=ci):
                if ci:
                    self.env["CI"] = "true"
                self.env["SECURITY_GATE_ALLOW_UNCHECKED"] = "1"
                proc = self.git("push", "origin", "HEAD:refs/heads/test", check=False)
                self.assertNotEqual(proc.returncode, 0)
                absent = subprocess.run(["git", "--git-dir", str(remote), "cat-file", "-e", forbidden], capture_output=True)
                self.assertNotEqual(absent.returncode, 0)
                if ci:
                    self.assertNotIn("Local report:", proc.stderr)

    def test_local_report_rejects_checkout(self):
        helper = ROOT / "scripts/local_security_report.py"
        proc = subprocess.run(["python3", "-I", str(helper), "--output", str(self.repo / "report.json")], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(proc.returncode, 2)

    def test_local_report_rejects_symlink(self):
        helper = ROOT / "scripts/local_security_report.py"
        path = self.base / "link.json"
        try:
            path.symlink_to(self.repo / "target.json")
        except OSError:
            self.skipTest("native symlinks unavailable")
        proc = subprocess.run(["python3", "-I", str(helper), "--output", str(path)], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(proc.returncode, 2)

    def test_ci_installer_guards_a_second_clone_before_transport(self):
        runner = self.base / "runner"
        runner.mkdir()
        exports = runner / "environment"
        exports.touch()
        paths = runner / "paths"
        paths.touch()
        scanner = runner / "credential-checker"
        scanner.write_text("#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        cli = runner / "bin"
        cli.mkdir()
        gh = cli / "gh"
        gh.write_text("#!/bin/sh\nexit 0\n")
        gh.chmod(0o700)
        env = {**self.env, "PATH": str(cli) + os.pathsep + self.env["PATH"], "CI": "true", "RUNNER_TEMP": str(runner),
               "GITHUB_ENV": str(exports), "GITHUB_PATH": str(paths), "GITLEAKS_BIN": str(scanner)}
        proc = subprocess.run(["bash", str(ROOT / "scripts/install-publication-hooks.sh"), "--ci"], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout + proc.stderr, "")
        env.update(line.split("=", 1) for line in exports.read_text().splitlines())
        remote = self.base / "runner-remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.stage("ordinary.json", self.report())
        self.commit()
        forbidden = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("config", "core.hooksPath", "/dev/null")
        proc = subprocess.run(["git", "-C", str(self.repo), "push", str(remote), "HEAD:refs/heads/test"], env=env, capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("run Scan Repository in Leak-Lock", proc.stderr)
        self.assertNotIn("Local report:", proc.stderr)
        absent = subprocess.run(["git", "--git-dir", str(remote), "cat-file", "-e", forbidden], capture_output=True)
        self.assertNotEqual(absent.returncode, 0)

    def test_report_in_markdown_fence_is_refused(self):
        self.check("--stdin", text="Example:\n```json\n" + self.report().decode() + "\n```", expected=1)

    def test_pii_inside_archive_is_refused(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("contact.txt", "jane.roe" + "@" + "mailbox.org")
        self.stage("bundle.zip", raw.getvalue())
        self.check("--staged", expected=1)

    def test_github_cli_refuses_payloads_before_calling_real_cli(self):
        scanner = self.base / "credential-checker"
        scanner.write_text("#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        gh = self.base / "real-gh"
        marker = self.base / "sent"
        gh.write_text("#!/usr/bin/env python3\nimport pathlib,os\npathlib.Path(os.environ['SENT']).touch()\nprint('published')\n")
        gh.chmod(0o700)
        report = self.base / "gitleaks.json"
        report.write_text("[]")
        payload = self.base / "payload.json"
        payload.write_text(json.dumps({"title": "fixture", "body": self.report().decode()}))
        alias = self.base / "notes.json"
        try:
            alias.symlink_to(report)
        except OSError:
            alias = report
        env = {**self.env, "CI": "true", "GITLEAKS_BIN": str(scanner), "SENT": str(marker)}
        attempts = [
            ["pr", "create", "--title", "fixture", "--body", self.report().decode()],
            ["--repo", "fixture/project", "pr", "create", "--body", self.report().decode()],
            ["pr", "create", "--fill=true", "--body", "Ready."],
            ["release", "create", "fixture", "--notes-from-tag", "--notes", "Ready."],
            ["pr", "create", "--title", "fixture", "-b" + self.report().decode()],
            ["pr", "create", "--title", "fixture", "--body-file", str(report)],
            ["pr", "create", "--title", "fixture", "--body-file", str(alias)],
            ["pr", "create", "--title", "fixture"],
            ["api", "repos/fixture/project/issues", "--input", "-"],
            ["api", "repos/fixture/project/issues", "--input", str(payload)],
            ["release", "upload", "fixture", str(report)],
            ["release", "create", "fixture", str(report), "--notes", "Ready."],
            ["pr", "create", "--title", "fixture", "--template", str(report)],
            ["pr", "create", "--title", "fixture", "-f"],
        ]
        for args in attempts:
            with self.subTest(args=args[:2]):
                proc = subprocess.run(["python3", "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), *args], env=env, input=self.report().decode(), capture_output=True, text=True)
                self.assertEqual(proc.returncode, 1)
                self.assertFalse(marker.exists())
                self.assertIn("check failed.", proc.stderr)
                self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)
                self.assertNotIn(str(self.base), proc.stderr)
        proc = subprocess.run(["python3", "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), "pr", "create", "--title", "fixture", "--body", "Ready for review."], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(marker.exists())
        safe_asset = self.base / "notes.txt"
        safe_asset.write_text("Ready for review.")
        for args in (["gist", "create", str(safe_asset)], ["pr", "review", "1", "--approve"]):
            proc = subprocess.run(["python3", "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), *args], env=env, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)


if __name__ == "__main__":
    unittest.main()
