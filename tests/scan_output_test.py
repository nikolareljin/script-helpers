"""Exercise commit and transport boundaries using synthetic local repositories."""

import io
import json
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

    def check(self, *args, expected=0, env=None, text=None):
        proc = subprocess.run(
            [BASH, CHECK.as_posix(), "--repo", str(self.repo), *args],
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

    def test_private_report_marker_and_wrapped_native_fields(self):
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
RESULT_LINE = b"\ngitleaks: 3 findings\n"


class LargeFileTests(unittest.TestCase):
    """Files above 64 MiB are streamed, not read whole."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "CHECK_SCAN_OUTPUT_"))}
        self.env.pop("CI", None)
        self.env.pop("GITHUB_ACTIONS", None)
        self.env["XDG_STATE_HOME"] = str(self.base / "state")

    def sparse(self, name, size, head=b"\x7fELF\0", at=None, data=b""):
        path = self.base / name
        with open(path, "wb") as stream:
            stream.write(head)
            if at is not None:
                stream.seek(at)
                stream.write(data)
            stream.truncate(size)
        return path

    def run_check(self, *args, extra=None):
        env = dict(self.env, **(extra or {}))
        return subprocess.run([BASH, CHECK.as_posix(), *args], capture_output=True, env=env, cwd=self.base).returncode

    def test_large_binary_without_results_passes(self):
        path = self.sparse("service", 65 * MIB)
        self.assertEqual(self.run_check("--file", str(path)), 0)

    def test_result_across_chunk_boundary_is_found(self):
        # The line starts 10 bytes before the first 8 MiB boundary.
        path = self.sparse("service", 65 * MIB, at=8 * MIB - 10, data=RESULT_LINE)
        self.assertEqual(self.run_check("--file", str(path)), 1)

    def test_large_staged_blob_is_streamed(self):
        repo = self.base / "repo"
        repo.mkdir()
        self.sparse("repo/clean.bin", 65 * MIB)
        self.sparse("repo/dirty.bin", 65 * MIB, at=8 * MIB - 10, data=RESULT_LINE)
        for args, expected in ((["init", "-q"], 0), (["add", "clean.bin"], 0), (["add", "dirty.bin"], 1)):
            subprocess.run(["git", "-C", str(repo), *args], check=True, env=self.env)
            self.assertEqual(self.run_check("--repo", str(repo), "--staged"), expected)
        self.assertEqual(self.run_check("--repo", str(repo), "--staged"), 1)

    def test_still_unchecked_large_text_archive_and_report_name(self):
        text = self.base / "notes.txt"
        with open(text, "wb") as stream:
            stream.truncate(0)
            stream.write(b"plain text\n" * (7 * MIB))
        self.assertEqual(self.run_check("--file", str(text)), 2)
        self.assertEqual(self.run_check("--file", str(self.sparse("big.gz", 65 * MIB, head=b"\x1f\x8b\0"))), 2)
        self.assertEqual(self.run_check("--file", str(self.sparse("big.zip", 65 * MIB))), 2)
        self.assertEqual(self.run_check("--file", str(self.sparse("gitleaks-report.json", 65 * MIB))), 1)

    def test_size_limit_is_configurable_and_validated(self):
        path = self.sparse("service", 65 * MIB)
        self.assertEqual(self.run_check("--file", str(path), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": "64"}), 2)
        self.assertEqual(self.run_check("--max-mib", "64", "--file", str(path)), 2)
        self.assertEqual(self.run_check("--max-mib", "65", "--file", str(path)), 0)
        small = self.sparse("small", 2 * MIB)
        self.assertEqual(self.run_check("--file", str(small), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": "1"}), 2)
        for bad in ("0", "2049", "-1", "1.5", "x"):
            self.assertEqual(self.run_check("--file", str(small), extra={"CHECK_SCAN_OUTPUT_MAX_MIB": bad}), 2, bad)

    def test_stream_memory_is_bounded(self):
        checker = load_checker()
        checker.CHUNK, checker.OVERLAP = 4096, 256
        sizes = []
        real = checker.inspect

        def spy(name, raw, depth=0, text_only=False):
            sizes.append(len(raw))
            return real(name, raw, depth, text_only)

        checker.inspect = spy
        data = bytearray(b"\0" * (100 * 4096))
        checker.inspect_stream("service", io.BytesIO(bytes(data)))
        self.assertTrue(sizes)
        self.assertLessEqual(max(sizes), 4096 + 256)
        # Every boundary offset, including a line longer than OVERLAP.
        for line in (RESULT_LINE, b"\n" + b"x" * 1000 + b" gitleaks: 3 findings\n"):
            for offset in range(4096 - len(line), 4097):
                blob = bytearray(data)
                blob[offset:offset + len(line)] = line
                with self.assertRaises(checker.Refused, msg=offset):
                    checker.inspect_stream("service", io.BytesIO(bytes(blob)))
        report = bytearray(data)
        report[5000:5000 + 40] = b'[\n {\n  "RuleID": "generic-api-key",\n'
        with self.assertRaises(checker.Unchecked):
            checker.inspect_stream("service", io.BytesIO(bytes(report)))
        tail = bytearray(data)
        tail[-len(RESULT_LINE):] = RESULT_LINE
        with self.assertRaises(checker.Refused):
            checker.inspect_stream("service", io.BytesIO(bytes(tail)))


if __name__ == "__main__":
    unittest.main()
