"""Exercise commit and transport boundaries using synthetic local repositories."""

import io
import json
import random
import time
import gzip
import bz2
import lzma
import os
from pathlib import Path
import subprocess
import sys
import shlex
import shutil
import tempfile
import unittest
import zipfile
import contextlib
import types
from unittest import mock

try:
    from compression import zstd as ZSTD
except ImportError:
    ZSTD = None
import tarfile


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check_scan_output.sh"
BASH = shutil.which("bash") or "bash"


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

    def check(self, *args, expected=0, env=None, text=None, script=None):
        command = [CHECK.as_posix(), "--repo", str(self.repo)] if script is None else [script.as_posix()]
        proc = subprocess.run(
            [BASH, *command, *args],
            input=text, capture_output=True, text=True, env=env or self.env, cwd=self.repo,
        )
        if expected is not None:
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

    def test_python_resolver_skips_unusable_launcher(self):
        folder = self.base / "interpreters"
        folder.mkdir()
        bad = folder / "python3"
        bad.write_bytes(b"#!/bin/sh\nexit 1\n")
        bad.chmod(0o700)
        good = folder / "python"
        good.write_bytes(("#!/usr/bin/env bash\nexec " + shlex.quote(Path(sys.executable).as_posix()) + ' "$@"\n').encode("utf-8"))
        good.chmod(0o700)
        env = {**self.env, "PATH": str(folder) + os.pathsep + self.env["PATH"]}
        proc = subprocess.run([BASH, "-c", 'source "$1"; security_python', "_", (ROOT / "scripts/security_notice.sh").as_posix()], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(Path(proc.stdout.strip().replace("\\", "/")).name, "python")

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

    def test_small_compressed_files_are_read(self):
        # A release tarball under the large-file limit goes through _inspect.
        # gzip used to crash there (GzipFile took the BytesIO as a filename),
        # so every .tar.gz was refused whatever it held.
        packed = io.BytesIO()
        with tarfile.open(fileobj=packed, mode="w:gz") as archive:
            info = tarfile.TarInfo("app-1.0/README.md")
            body = b"plain release notes\n"
            info.size = len(body)
            archive.addfile(info, io.BytesIO(body))
        # Decoded members go to check_sensitive.sh, which needs a gitleaks; CI
        # legs have none. A stub that finds nothing keeps the outcome the same.
        scanner = self.base / "clean-scanner"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        env = dict(self.env, GITLEAKS_BIN=str(scanner))
        # The crash exited 1, so a clean archive passing is the proof. bz2 and
        # xz were never affected and test_renamed_compressed_reports_refused
        # covers them; each check run costs seconds on the Windows leg.
        (self.repo / "app-1.0.tar.gz").write_bytes(packed.getvalue())
        self.check("--file", "app-1.0.tar.gz", expected=0, env=env)
        (self.repo / "packed.gz").write_bytes(gzip.compress(b"notes\n" + RESULT_LINE))
        self.check("--file", "packed.gz", expected=1, env=env)

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

    def test_existing_destination_history_is_not_republished(self):
        self.git("remote", "add", "destination", str(self.base / "remote.git"))
        self.stage("old.json", self.report())
        self.commit()
        published = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/destination/main", published)
        self.git("rm", "-q", "old.json")
        self.commit()
        refs = self.base / "refs"
        refs.write_text("refs/heads/topic " + self.git("rev-parse", "HEAD").stdout.strip() + " refs/heads/topic " + self.initial + "\n")
        self.check("--push-refs", str(refs), "--remote", "destination")
        # Another destination must still inspect the same intermediate commit.
        self.check("--push-refs", str(refs), "--remote", "other", expected=1)

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
            for prefix in ("", tool + "\n"):
                self.check("--stdin", text=prefix + status, expected=1)

    def test_native_csv_and_junit_reports_are_refused(self):
        header = "Rule" + "ID,Secret,Fingerprint,File\n"
        self.check("--stdin", text=header, expected=1)
        xml = '<testsuites><testsuite name="' + "git" + 'leaks" tests="' + str(0) + '"/></testsuites>'
        self.check("--stdin", text=xml, expected=1)
        self.check("--stdin", text="RuleID,Description\nfixture,ordinary\n")
        self.check("--stdin", text='<testsuites><testsuite name="ordinary-unit-tests"/></testsuites>')

    def test_reports_in_publication_text_are_refused(self):
        header = "Rule" + "ID,Secret,Fingerprint,File\n"
        self.check("--stdin", text="Export:\n```csv\n" + header + "```", expected=1)
        tool = "git" + "leaks"
        xml = '<testsuites><testsuite name="' + tool + '" tests="' + str(0) + '"/></testsuites>'
        self.check("--stdin", text="Export:\n```xml\n" + xml + "\n```", expected=1)
        self.check("--stdin", text="> 11:00AM INF no " + "leaks found", expected=1)
        self.check("--stdin", text=tool + " findings: 19", expected=1)
        self.check("--stdin", text=tool + " clean", expected=1)
        self.check("--stdin", text=json.dumps({tool: 0}), expected=1)
        self.check("--stdin", text=json.dumps({tool: "clean"}), expected=1)
        self.check("--stdin", text=json.dumps({tool: {"findings": []}}), expected=1)
        self.check("--stdin", text=json.dumps({tool: {"enabled": True, "version": "8.30.1"}}))

    def test_report_marker_private_and_wrapped_native_fields(self):
        marker = "SCRIPT_HELPERS_PRIVATE_" + "SECURITY_REPORT_V1"
        self.check("--stdin", text=marker + "\nordinary diagnostics\n", expected=1)
        self.check("--stdin", text="```text\n" + marker + "\nordinary diagnostics\n```", expected=1)
        tool = "git" + "leaks"
        self.check("--stdin", text="[sensitive] BLOCK " + tool + " found 19 credential(s)", expected=1)
        self.check("--stdin", text="[sensitive] " + tool + ": Fingerprint: REDACTED", expected=1)

    def test_annotated_tag_name_cannot_hide_behind_a_safe_ref(self):
        self.git("tag", "-a", "fox" + "guard/19-findings", self.initial, "-m", "fixture")
        oid = self.git("rev-parse", "fox" + "guard/19-findings").stdout.strip()
        refs = self.base / "refs"
        refs.write_text("refs/tags/safe " + oid + " refs/tags/safe " + "0" * 40 + "\n")
        self.check("--push-refs", str(refs), expected=1)

    def test_missing_or_malformed_range_refused(self):
        self.check("--range", "does-not-exist", expected=2)
        refs = self.base / "refs"
        refs.write_text("invalid\n")
        self.check("--push-refs", str(refs), expected=2)

    def test_noop_and_deletion_refs_allowed(self):
        refs = self.base / "refs"
        refs.write_text("refs/heads/x " + "0" * 40 + " refs/heads/x " + self.initial + "\n")
        self.check("--push-refs", str(refs))

    def test_empty_named_compressed_report_refused(self):
        self.stage("gitleaks.json.gz", gzip.compress(b"[]"))
        self.check("--staged", expected=1)

    def test_renamed_compressed_reports_refused(self):
        for compress in (gzip.compress, bz2.compress, lzma.compress):
            with self.subTest(compress=compress.__module__):
                self.stage("ordinary.bin", compress(self.report()))
                self.check("--staged", expected=1)

    def test_local_commands_refuse_ci_without_echoing_input(self):
        canary = "PRIVATE" + "-SCAN-PATH"
        for name in ("ci_security.sh", "foxguard_report.sh", "ci_gitleaks_report.sh"):
            proc = subprocess.run([BASH, (ROOT / "scripts" / name).as_posix(), "--unexpected=" + canary], env={**self.env, "CI": "true", "GITHUB_ACTIONS": "true"}, capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertNotIn(canary, proc.stdout + proc.stderr)
            self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)

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

    def test_filename_pii_is_refused_before_commit(self):
        scanner = self.base / "clean-scanner"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        names = self.base / "names.tsv"
        names.write_text("private\tfixture\tzzqprivatefixture\tR-999\t\n")
        self.env.update(GITLEAKS_BIN=str(scanner), PRIVATE_NAMES_FILE=str(names), PRIVATE_NAMES_AUTO_REFRESH="false")
        self.git("config", "core.hooksPath", str(ROOT / "scripts/git-hooks"))
        self.stage("jane.roe" + "@mailbox.org", b"")
        result = self.git("commit", "-qm", "fixture", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial)

    def test_ref_pii_is_refused_without_echoing_it_in_ci(self):
        scanner = self.base / "clean-scanner"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        names = self.base / "names.tsv"
        names.write_text("private\tfixture\tzzqprivatefixture\tR-999\t\n")
        name = "jane.roe" + "@mailbox.org"
        self.env.update(GITLEAKS_BIN=str(scanner), PRIVATE_NAMES_FILE=str(names), PRIVATE_NAMES_AUTO_REFRESH="false", CI="true", GITHUB_HEAD_REF=name)
        remote = self.base / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        self.git("config", "core.hooksPath", str(ROOT / "scripts/git-hooks"))
        result = self.git("push", str(remote), "HEAD:refs/heads/" + name, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(name, result.stdout + result.stderr)
        absent = subprocess.run(["git", "--git-dir", str(remote), "show-ref"], capture_output=True)
        self.assertNotEqual(absent.returncode, 0)

    def test_local_report_path_uses_lf(self):
        helper = ROOT / "scripts/local_security_report.py"
        proc = subprocess.run([sys.executable, "-I", str(helper)], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(proc.returncode, 0)
        self.assertNotIn(b"\r", proc.stdout)
        self.assertTrue(Path(os.fsdecode(proc.stdout).strip()).is_file())

    def test_local_report_rejects_checkout(self):
        helper = ROOT / "scripts/local_security_report.py"
        proc = subprocess.run([sys.executable, "-I", str(helper), "--output", str(self.repo / "report.json")], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(proc.returncode, 2)

    def test_local_report_rejects_symlink(self):
        helper = ROOT / "scripts/local_security_report.py"
        path = self.base / "link.json"
        try:
            path.symlink_to(self.repo / "target.json")
        except OSError:
            self.skipTest("native symlinks unavailable")
        proc = subprocess.run([sys.executable, "-I", str(helper), "--output", str(path)], cwd=self.repo, env=self.env, capture_output=True)
        self.assertEqual(proc.returncode, 2)

    def test_ci_installer_guards_a_second_clone_before_transport(self):
        runner = self.base / "runner"
        runner.mkdir()
        exports = runner / "environment"
        exports.touch()
        paths = runner / "paths"
        paths.touch()
        scanner = runner / "credential-checker"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        cli = runner / "bin"
        cli.mkdir()
        gh = cli / "gh"
        gh.write_bytes(b"#!/bin/sh\nexit 0\n")
        gh.chmod(0o700)
        env = {**self.env, "PATH": str(cli) + os.pathsep + self.env["PATH"], "CI": "true", "RUNNER_TEMP": str(runner),
               "GITHUB_ENV": str(exports), "GITHUB_PATH": str(paths), "GITLEAKS_BIN": str(scanner)}
        proc = subprocess.run([BASH, (ROOT / "scripts/install-publication-hooks.sh").as_posix(), "--ci"], cwd=self.repo, env=env, capture_output=True, text=True)
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

    def test_ci_installer_hides_failed_scanner_installation(self):
        source = self.base / "source"
        source.mkdir()
        shutil.copy2(ROOT / "helpers.sh", source / "helpers.sh")
        for folder in ("lib", "scripts"):
            shutil.copytree(ROOT / folder, source / folder)
        canary = "PRIVATE" + "-INSTALL-DIAGNOSTIC"
        marker = self.base / "install-ran"
        (source / "lib/gitleaks.sh").write_bytes((
            "gitleaks_bin() { return 1; }\n"
            "gitleaks_install() { touch " + shlex.quote(marker.as_posix()) + "; printf '%s\\n' '" + canary + "' >&2; return 1; }\n"
        ).encode("utf-8"))
        runner = self.base / "runner"
        runner.mkdir()
        env = {**self.env, "CI": "true", "RUNNER_TEMP": runner.as_posix(),
               "GITHUB_ENV": (runner / "environment").as_posix(), "GITHUB_PATH": (runner / "paths").as_posix()}
        env.pop("GITLEAKS_BIN", None)
        proc = subprocess.run([BASH, (source / "scripts/install-publication-hooks.sh").as_posix(), "--ci"], cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertTrue(marker.exists())
        self.assertNotIn(canary, proc.stdout + proc.stderr)
        self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)

    def test_report_in_markdown_fence_is_refused(self):
        self.check("--stdin", text="Example:\n```json\n" + self.report().decode() + "\n```", expected=1)

    def test_pii_inside_archive_is_refused(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("contact.txt", "jane.roe" + "@" + "mailbox.org")
        self.stage("bundle.zip", raw.getvalue())
        self.check("--staged", expected=1)

    def test_archive_member_name_pii_is_refused(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("jane.roe" + "@mailbox.org", "")
        self.stage("bundle.zip", raw.getvalue())
        self.check("--staged", expected=1)

    def test_document_suffix_does_not_hide_pii(self):
        for suffix in (".txt", ".tar.gz", ".json"):
            proc = subprocess.run(
                [BASH, str(ROOT / "scripts/check_sensitive.sh"), "--stdin", "--no-gitleaks", "--no-machine"],
                input="jane.roe" + "@mailbox.org" + suffix,
                capture_output=True, text=True, env=self.env, cwd=self.repo,
            )
            self.assertEqual(proc.returncode, 1, proc.stderr)

    def test_deep_json_fails_closed(self):
        self.check("--stdin", text="[" * 1200 + "0" + "]" * 1200, expected=2)

    def test_archive_links_and_directory_names_are_checked(self):
        for archive_type in ("zip", "tar"):
            raw = io.BytesIO()
            name = "jane.roe" + "@mailbox.org"
            if archive_type == "zip":
                with zipfile.ZipFile(raw, "w") as archive:
                    archive.writestr(name + "/", "")
            else:
                with tarfile.open(fileobj=raw, mode="w") as archive:
                    member = tarfile.TarInfo("ordinary-link")
                    member.type = tarfile.SYMTYPE
                    member.linkname = name
                    archive.addfile(member)
            target = self.base / ("bundle." + archive_type)
            target.write_bytes(raw.getvalue())
            self.check("--file", str(target), expected=1)

    def test_asset_and_example_domain_suffixes_are_allowed(self):
        for name in ("logo@2x.png", "module@package.js", "fixture" + "@example.org.txt"):
            proc = subprocess.run(
                [BASH, str(ROOT / "scripts/check_sensitive.sh"), "--stdin", "--no-gitleaks", "--no-machine"],
                input=name, capture_output=True, text=True, env=self.env, cwd=self.repo,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_github_cli_refuses_payloads_before_calling_real_cli(self):
        scanner = self.base / "credential-checker"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        gh = self.base / "real-gh"
        marker = self.base / "sent"
        gh.write_text("#!/usr/bin/env python3\nimport pathlib,os\npathlib.Path(os.environ['SENT']).touch()\nprint('published')\n")
        gh.chmod(0o700)
        if os.name == "nt":
            script = gh.with_suffix(".py")
            gh.rename(script)
            gh = gh.with_suffix(".cmd")
            gh.write_text('@echo off\n"' + sys.executable + '" "' + str(script) + '" %*\n')
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
                proc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), *args], env=env, input=self.report().decode(), capture_output=True, text=True)
                self.assertEqual(proc.returncode, 1)
                self.assertFalse(marker.exists())
                self.assertIn("check failed.", proc.stderr)
                self.assertIn("https://nikolareljin.github.io/leak-lock/", proc.stderr)
                self.assertNotIn(str(self.base), proc.stderr)
        proc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), "pr", "create", "--title", "fixture", "--body", "Ready for review."], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(marker.exists())
        safe_asset = self.base / "notes.txt"
        safe_asset.write_text("Ready for review.")
        for args in (["gist", "create", str(safe_asset)], ["pr", "review", "1", "--approve"]):
            proc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/guard_gh.py"), str(gh), *args], env=env, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)


def load_checker():
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_scan_output", ROOT / "scripts/check_scan_output.py")
    module = importlib.util.module_from_spec(spec)
    # Leave no __pycache__ in scripts/; lint-docs treats it as an undocumented file.
    saved, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = saved
    return module


MIB = 1024 * 1024
# Assembled at run time so this source file is not itself a scanner result.
RESULT_LINE = ("\n%s: 3 findings\n" % ("git" + "leaks")).encode()
# Skewed text around RESULT_LINE, so every compressor codes the line instead of
# storing it raw; a test then fails if the embedded data is not decoded.
_rng = random.Random(1)
_TEXT = "".join(_rng.choice("abcdefgh ") for _ in range(20000)).encode()
PACKED_PAYLOAD = _TEXT + RESULT_LINE + _TEXT[:5000]


class LargeFileTests(unittest.TestCase):
    """Executables above 64 MiB are streamed and their embedded data decoded."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "CHECK_SCAN_OUTPUT_"))}
        self.env.pop("CI", None)
        self.env.pop("GITHUB_ACTIONS", None)
        self.env["XDG_STATE_HOME"] = str(self.base / "state")
        # Decoded members go to check_sensitive.sh, which needs a gitleaks; CI
        # legs have none. A stub that finds nothing keeps the outcome the same.
        scanner = self.base / "clean-scanner"
        scanner.write_bytes(b"#!/bin/sh\nexit 0\n")
        scanner.chmod(0o700)
        self.env["GITLEAKS_BIN"] = str(scanner)
        self.repo = self.base

    def sparse(self, name, size, head=b"\x7fELF\0", at=None, data=b""):
        path = self.base / name
        with path.open("wb") as stream:
            stream.write(head)
            if at is not None:
                stream.seek(at)
                stream.write(data)
            stream.truncate(size)
        return path

    def run_check(self, *args, extra=None):
        """Run check_scan_output.py's main() in this process, as the shell wrapper would."""
        checker = load_checker()
        out, err = io.StringIO(), io.StringIO()
        saved = os.getcwd()
        os.chdir(self.base)
        try:
            with mock.patch.dict(os.environ, dict(self.env, **(extra or {})), clear=True), \
                    mock.patch.object(sys, "argv", ["check_scan_output.py", *args]), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = checker.main()
                except SystemExit as exc:
                    code = exc.code
        finally:
            os.chdir(saved)
        return types.SimpleNamespace(returncode=code, stdout=out.getvalue(), stderr=err.getvalue())

    def run_script(self, script, *args, extra=None):
        return PublicationTests.check(self, *args, expected=None, env=dict(self.env, **(extra or {})), script=script)

    def status(self, *args, extra=None):
        return self.run_check(*args, extra=extra).returncode

    def test_large_executable_without_results_passes(self):
        harmless = gzip.compress(b"plain asset\n" * 1000)
        path = self.sparse("service", 65 * MIB, at=30 * MIB, data=harmless + b"\x1f\x8b\x08\x99junk PK\x03\x04junk ustar")
        self.assertEqual(self.status("--file", str(path)), 0)

    def test_result_across_chunk_boundary_is_found(self):
        # The line starts 10 bytes before the first 8 MiB boundary.
        path = self.sparse("service", 65 * MIB, at=8 * MIB - 10, data=RESULT_LINE)
        self.assertEqual(self.status("--file", str(path)), 1)

    def test_result_inside_embedded_archives_is_found(self):
        packed = io.BytesIO()
        with zipfile.ZipFile(packed, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("notes.txt", PACKED_PAYLOAD)
        for data in (packed.getvalue(), gzip.compress(PACKED_PAYLOAD), bz2.compress(PACKED_PAYLOAD), lzma.compress(PACKED_PAYLOAD)):
            self.assertNotIn(RESULT_LINE.strip(), data)
            path = self.sparse("service", 71 * MIB, at=70 * MIB, data=data)
            self.assertEqual(self.status("--file", str(path)), 1, data[:4])

    @unittest.skipUnless(ZSTD, "compression.zstd needs Python 3.14")
    def test_result_inside_embedded_zstd_is_found(self):
        frame = ZSTD.compress(PACKED_PAYLOAD)
        self.assertNotIn(RESULT_LINE.strip(), frame)
        path = self.sparse("service", 71 * MIB, at=70 * MIB, data=frame)
        self.assertEqual(self.status("--file", str(path)), 1)

    def test_large_staged_blob_is_streamed(self):
        repo = self.base / "repo"
        repo.mkdir()
        self.sparse("repo/clean.bin", 65 * MIB)
        self.sparse("repo/dirty.bin", 65 * MIB, at=8 * MIB - 10, data=RESULT_LINE)
        for args, expected in ((["init", "-q"], 0), (["add", "clean.bin"], 0), (["add", "dirty.bin"], 1)):
            subprocess.run(["git", "-C", str(repo), *args], check=True, env=self.env)
            self.assertEqual(self.status("--repo", str(repo), "--staged"), expected)

    def test_incomplete_check_warns_locally_and_does_not_block_ci(self):
        bomb = gzip.compress(b"\0" * (65 * MIB))
        cases = (
            self.sparse("service", 66 * MIB, at=30 * MIB, data=bomb),
            self.sparse("blob.bin", 65 * MIB, head=b"\0data"),
            self.sparse("big.gz", 65 * MIB, head=b"\x1f\x8b\x08\0"),
            self.sparse("big.zip", 65 * MIB),
            self.sparse("report-like", 65 * MIB, at=MIB, data=b'"RuleID": "x"'),
        )
        for path in cases:
            local = self.run_check("--file", str(path))
            self.assertEqual(local.returncode, 3, path.name)
            self.assertIn("WARNING: security check incomplete: " + str(path), local.stderr)
            ci = self.run_check("--file", str(path), extra={"GITHUB_ACTIONS": "true"})
            self.assertEqual(ci.returncode, 0, path.name)
            self.assertIn("::warning title=Security check incomplete::" + str(path), ci.stdout)
            self.assertEqual(self.status("--non-blocking", "--file", str(path)), 0)
        self.assertEqual(self.status("--file", str(self.sparse("gitleaks-report.json", 65 * MIB))), 1)

    def test_findings_still_block_in_ci(self):
        path = self.sparse("service", 71 * MIB, at=70 * MIB, data=gzip.compress(PACKED_PAYLOAD))
        self.assertEqual(self.status("--file", str(path), extra={"GITHUB_ACTIONS": "true"}), 1)
        self.assertEqual(self.status("--non-blocking", "--file", str(path)), 1)

    def test_size_limit_is_configurable_and_validated(self):
        path = self.sparse("service", 65 * MIB)
        self.assertEqual(self.status("--file", str(path), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": "64"}), 3)
        self.assertEqual(self.status("--max-mib", "64", "--file", str(path)), 3)
        self.assertEqual(self.status("--max-mib", "65", "--file", str(path)), 0)
        small = self.sparse("small", 2 * MIB)
        self.assertEqual(self.status("--file", str(small), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": "1"}), 3)
        for bad in ("0", "2049", "-1", "1.5", "x"):
            self.assertEqual(self.status("--file", str(small), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": bad}), 2, bad)

    def test_publication_check_forwards_incomplete_warning(self):
        path = self.sparse("blob.bin", 65 * MIB, head=b"\0data")
        script = ROOT / "scripts/check_publication.sh"
        local = self.run_script(script, "--file", str(path))
        self.assertEqual(local.returncode, 3, local.stderr)
        self.assertIn("WARNING: security check incomplete", local.stderr)

    def test_result_after_an_unchecked_part_still_blocks(self):
        packed = io.BytesIO()
        with zipfile.ZipFile(packed, "w") as archive:
            archive.writestr("x.txt", "hi")
        encrypted = bytearray(packed.getvalue())
        encrypted[6] |= 1
        cases = (self.sparse("service", 70 * MIB, at=MIB, data=bytes(encrypted) + b"\0" * (59 * MIB) + RESULT_LINE),
                 self.sparse("blob.bin", 70 * MIB, head=b"\0data", at=60 * MIB, data=RESULT_LINE))
        for path in cases:
            self.assertEqual(self.status("--file", str(path), extra={"GITHUB_ACTIONS": "true"}), 1, path.name)

    @unittest.skipUnless(ZSTD, "compression.zstd needs Python 3.14")
    def test_clean_zstd_frame_far_from_the_end_passes(self):
        frame = ZSTD.compress(_TEXT * 3)
        path = self.sparse("service", 200 * MIB, at=MIB, data=frame)
        proc = self.run_check("--file", str(path))
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_tar_with_many_members_is_read_once(self):
        packed = io.BytesIO()
        with tarfile.open(fileobj=packed, mode="w") as archive:
            for index in range(1900):
                info = tarfile.TarInfo("f%d" % index)
                info.size = 3
                archive.addfile(info, io.BytesIO(b"abc"))
        path = self.sparse("service", 70 * MIB, at=MIB, data=packed.getvalue())
        started = time.monotonic()
        proc = self.run_check("--file", str(path))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertLess(time.monotonic() - started, 60)

    def test_personal_data_in_one_of_many_embedded_members_is_refused(self):
        email = ("jane.roe" + "@mailbox.org").encode()
        for kind in ("content", "link"):
            packed = io.BytesIO()
            with tarfile.open(fileobj=packed, mode="w") as archive:
                for index in range(400):
                    info = tarfile.TarInfo("f%d" % index)
                    body = email if kind == "content" and index == 300 else b"abc"
                    if kind == "link" and index == 300:
                        info.type, info.linkname = tarfile.SYMTYPE, email.decode()
                        body = b""
                    info.size = len(body)
                    archive.addfile(info, io.BytesIO(body))
            path = self.sparse("service", 70 * MIB, at=MIB, data=packed.getvalue())
            self.assertEqual(self.status("--file", str(path), extra={"GITHUB_ACTIONS": "true"}), 1, kind)

    def test_file_under_home_with_embedded_data_passes(self):
        # The file's own path is not part of the decoded data it carries.
        home = self.base / "home"
        (home / "bin").mkdir(parents=True)
        path = self.sparse("home/bin/service", 65 * MIB, at=MIB, data=gzip.compress(b"plain asset\n" * 100))
        ids = self.base / "machine-ids.tsv"
        ids.write_text("this machine's home directory\t%s\n" % home)
        proc = self.run_check("--file", str(path), extra={"SENSITIVE_MACHINE_IDS_FILE": str(ids)})
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_zstd_without_a_decoder_is_incomplete(self):
        # 'hello' as a zstd frame; no external zstd command is ever run.
        path = self.sparse("service", 65 * MIB, at=MIB, data=bytes.fromhex("28b52ffd045831000068656c6c6f0a5388bd91"))
        checker = load_checker()
        with path.open("rb") as stream:
            checker.ZstdDecompressor = None
            with self.assertRaises(checker.Anomaly):
                checker.inspect_large("service", stream)
        if ZSTD is None:
            self.assertEqual(self.status("--file", str(path)), 3)
            self.assertEqual(self.status("--file", str(path), extra={"GITHUB_ACTIONS": "true"}), 0)

    def test_hooks_show_incomplete_warning_outside_the_report(self):
        path = self.sparse("blob.bin", 65 * MIB, head=b"\0data")
        wrapper = self.base / "guard.sh"
        wrapper.write_text('source "%s"\nsec_guard sec_scan_output "$@"\n' % (ROOT / "scripts/security_hooks.sh").as_posix())
        local = self.run_script(wrapper, "--file", str(path))
        self.assertNotEqual(local.returncode, 0)
        self.assertIn("WARNING: security check incomplete: " + str(path), local.stderr)
        ci = self.run_script(wrapper, "--file", str(path), extra={"GITHUB_ACTIONS": "true", "CI": "true"})
        self.assertEqual(ci.returncode, 0, ci.stderr)
        self.assertIn("::warning title=Security check incomplete::" + str(path), ci.stdout)

    def scan(self, checker, data):
        path = self.base / "window.bin"
        path.write_bytes(bytes(data))
        with path.open("rb") as stream:
            checker.inspect_large("service", stream)

    def test_stream_memory_is_bounded_and_boundaries_are_covered(self):
        checker = load_checker()
        checker.CHUNK, checker.OVERLAP = 4096, 256
        sizes = []
        real = checker.inspect

        def spy(name, raw, depth=0, text_only=False):
            if text_only:
                sizes.append(len(raw))
            return real(name, raw, depth, text_only)

        checker.inspect = spy
        data = bytearray(b"\x7fELF" + b"\0" * (100 * 4096 - 4))
        self.scan(checker, data)
        self.assertTrue(sizes)
        self.assertLessEqual(max(sizes), 4096 + 256)
        # Every boundary offset, including a line longer than OVERLAP and
        # a compressed result whose signature is cut by the boundary.
        long_line = b"\n" + b"x" * 1000 + b" " + RESULT_LINE[1:]
        packed = gzip.compress(PACKED_PAYLOAD)
        cases = [(RESULT_LINE, range(4096 - len(RESULT_LINE), 4097)),
                 (long_line, range(4096 - len(long_line), 4097)),
                 (packed, range(4096 - 3, 4097))]
        for payload, offsets in cases:
            for offset in offsets:
                blob = bytearray(data)
                blob[offset:offset + len(payload)] = payload
                with self.assertRaises(checker.Refused, msg=(payload[:4], offset)):
                    self.scan(checker, blob)
        # Stray magic bytes are not a finding.
        for magic in (b"\x1f\x8b\x08", b"PK\x03\x04", b"BZh9", b"\xfd7zXZ\x00", b"7z\xbc\xaf\x27\x1c", b"\x28\xb5\x2f\xfd", b"ustar"):
            blob = bytearray(data)
            blob[4093:4093 + len(magic)] = magic
            self.scan(checker, blob)
        tail = bytearray(data)
        tail[-len(RESULT_LINE):] = RESULT_LINE
        with self.assertRaises(checker.Refused):
            self.scan(checker, tail)


def _tar(members, mode):
    packed = io.BytesIO()
    with tarfile.open(fileobj=packed, mode=mode) as archive:
        for name, body in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            archive.addfile(info, io.BytesIO(body))
    return packed.getvalue()


class CompressedInputTests(unittest.TestCase):
    """Small .gz, .bz2, .xz files and tarballs go through _inspect, not the large-file path."""

    # Assembled at run time so this source file holds no token or address.
    TOKEN = "ghp_" + "Fx7Qw2Lm9Rt4Yu6Io8Pa1Sd3Gh5Jk0ZxCvBn"
    ADDRESS = "anna.weber" + "@" + "firma-gmbh.de"
    CLEAN = {"app-1.0/README.md": b"plain release notes\n", "app-1.0/bin/run": b"#!/bin/sh\necho ok\n"}

    def setUp(self):
        LargeFileTests.setUp(self)
        # A gitleaks stand-in that reports a finding when the token is in the
        # directory it is pointed at, and writes its JSON report as gitleaks does.
        scanner = self.base / "token-scanner"
        scanner.write_text(
            "#!/bin/sh\nsrc=; rep=; prev=\n"
            "for a in \"$@\"; do\n"
            "  case \"$prev\" in --source|dir) src=$a ;; --report-path) rep=$a ;; esac\n"
            "  prev=$a\n"
            "done\n"
            "if grep -rqF '" + self.TOKEN + "' \"$src\" 2>/dev/null; then\n"
            "  printf '[{\"RuleID\":\"github-pat\"}]\\n' > \"$rep\"; exit 1\n"
            "fi\nprintf '[]\\n' > \"$rep\"; exit 0\n"
        )
        scanner.chmod(0o700)
        self.env["GITLEAKS_BIN"] = str(scanner)

    def run_check(self, *args, extra=None):
        return LargeFileTests.run_check(self, *args, extra=extra)

    def status_of(self, name, data):
        path = self.base / name
        path.write_bytes(data)
        return self.run_check("--file", str(path)).returncode

    def test_stand_in_scanner_reports_the_token(self):
        # Without this the token cases below could pass on a scanner that never fires.
        proc = subprocess.run(
            [BASH, str(ROOT / "scripts/check_sensitive.sh"), "--stdin", "--no-machine"],
            input="token=" + self.TOKEN + "\n", capture_output=True, text=True, env=self.env, cwd=self.base,
        )
        self.assertEqual(proc.returncode, 1, proc.stderr)

    def test_clean_tarballs_pass(self):
        for name, mode in (("a.tar.gz", "w:gz"), ("a.tgz", "w:gz"), ("a.tar.bz2", "w:bz2"), ("a.tar.xz", "w:xz")):
            self.assertEqual(self.status_of(name, _tar(self.CLEAN, mode)), 0, name)
        self.assertEqual(self.status_of("notes.gz", gzip.compress(b"plain notes\n")), 0)

    def test_planted_secret_in_tarball_is_found(self):
        for body in (("token = '" + self.TOKEN + "'\n").encode(), ("contact: " + self.ADDRESS + "\n").encode()):
            members = dict(self.CLEAN, **{"app-1.0/config.ini": body})
            for name, mode in (("a.tar.gz", "w:gz"), ("a.tar.bz2", "w:bz2"), ("a.tar.xz", "w:xz")):
                self.assertEqual(self.status_of(name, _tar(members, mode)), 1, (name, body[:8]))
            self.assertEqual(self.status_of("config.gz", gzip.compress(body)), 1, body[:8])

    def test_nested_archives_are_opened(self):
        secret = _tar(dict(self.CLEAN, **{"app-1.0/.env": ("TOKEN=" + self.TOKEN + "\n").encode()}), "w:gz")
        clean = _tar(self.CLEAN, "w:gz")
        for inner, expected in ((secret, 1), (clean, 0)):
            # A .tar.gz inside a gzip, and inside another .tar.gz.
            self.assertEqual(self.status_of("outer.gz", gzip.compress(inner)), expected)
            self.assertEqual(self.status_of("outer.tar.gz", _tar({"inner.tar.gz": inner}, "w:gz")), expected)

    def test_truncated_or_corrupt_input_is_refused(self):
        whole = _tar(self.CLEAN, "w:gz")
        corrupt = bytearray(whole)
        corrupt[-6] ^= 0xFF  # inside the CRC32 trailer
        for name, data in (("cut.tar.gz", whole[: len(whole) // 2]), ("cut.gz", whole[:-4]),
                           ("crc.tar.gz", bytes(corrupt)), ("trailing.tar.gz", whole + b"not gzip"),
                           ("cut.tar.bz2", _tar(self.CLEAN, "w:bz2")[:-10]),
                           ("cut.tar.xz", _tar(self.CLEAN, "w:xz")[:-10])):
            self.assertEqual(self.status_of(name, data), 2, name)


class BinaryNoiseEmailTests(unittest.TestCase):
    """Random bytes hold short email-shaped runs; addresses in text are still found."""

    def scan(self, data):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        with tempfile.TemporaryDirectory() as tmp:
            env["XDG_STATE_HOME"] = tmp
            proc = subprocess.run(
                [BASH, str(ROOT / "scripts/check_sensitive.sh"), "--stdin", "--no-gitleaks", "--no-machine"],
                input=data, capture_output=True, env=env, cwd=tmp,
            )
        return proc

    def test_random_bytes_are_not_an_email_address(self):
        # This 4 MiB block holds an email-shaped run that was refused before.
        self.assertEqual(self.scan(random.Random(5).randbytes(4 * MIB)).returncode, 0)
        self.assertEqual(self.scan(b"\xff\x01\x9c\x02" + b"q@zk.vo" + b"\x03\xfe\x80\x04").returncode, 0)

    def test_addresses_in_text_are_still_found(self):
        address = ("anna.weber" + "@" + "firma-gmbh.de").encode()
        for data in (b"contact " + address + b" today\n", address + b"\n", b"mail:" + address,
                     "連絡先：".encode() + address + "。".encode(),
                     b"\x7fELF\x01\x02\0\0support: " + address + b"\0usage: %s\0",
                     random.Random(5).randbytes(4096) + b"\n" + address + b"\n",
                     # The same address beside noise first and in text later on one line.
                     b"\x01\x02\x03\x04" + address + b"\x05\x06 and mail " + address + b" again\n"):
            self.assertEqual(self.scan(data).returncode, 1, data[:16])


if __name__ == "__main__":
    unittest.main()
