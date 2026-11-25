"""Split foxguard findings of a pushed tip into new and already present.

Usage: foxguard_push_compare.py --level <critical|high|medium|low>
       --tip <tip.json> [--base <base.json> ...] [--base-unscanned <list> ...]
       [--allow-unscanned] [--base-incomplete]

Reads foxguard JSON reports (`foxguard --format json`), each a file or a
directory of them. A tip finding is new
when its rule, file and whitespace-normalized snippet occur more often at the
tip than in every base report, so a finding that only moved lines is not new.
--base-unscanned names the files the --base before it skipped, as foxguard
printed them ("warning: skipping <file> (<reason>)"). No base can say what
was already in a file every base skipped, so a tip finding there at or above
--level blocks and names the reason; with --allow-unscanned (the operator
reviewed the file) it is a warning instead. A base that scanned the file
still judges it, and once the push lands it is compared as usual.
--base-incomplete says a base is not among the --base reports (its scan
failed, or it was left out): it skipped nothing, so --allow-unscanned turns
no finding into a warning.
Prints one tab-separated line per tip finding:
    BLOCK|WARN <severity> <file>:<line> <rule> <why> <description>
Exit 0: nothing blocks. 3: a new finding at or above --level. 2: a report
could not be read, or anything else went wrong (never read as a pass).
"""

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}
ALLOW = "SCRIPT_HELPERS_FOXGUARD_ALLOW_UNSCANNED_BASE"
SKIPPED = re.compile(r"^warning: skipping (.+) \(([^()]*)\)$")


def load(path):
    # The reports the hook itself wrote into its own temporary directory: one
    # JSON file, or a directory of them (one per scanned file).
    path = Path(path)
    if path.is_dir():
        found = []
        for part in sorted(path.glob("*.json")):
            findings = load(part)
            # <n>.path: the real name of a file scanned from its own directory.
            real = part.with_suffix(".path")
            if real.exists():
                # newline="\n": a carriage return in a file name stays one.
                with real.open(encoding="utf-8", newline="\n") as handle:
                    name = handle.read().rstrip("\n")
                for finding in findings:
                    finding["file"] = name
            found.extend(findings)
        return found
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    findings = data.get("findings") if isinstance(data, dict) else None
    if not isinstance(findings, list):
        raise ValueError("no findings list")
    if not all(isinstance(f, dict) for f in findings):
        raise ValueError("a finding is not an object")
    return findings


def load_unscanned(path):
    # The <out>.skipped list sec_foxguard_scan wrote for a base: file -> reason.
    unscanned = {}
    # newline="\n": a carriage return in a file name must not start a line.
    with Path(path).open(encoding="utf-8", newline="\n") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            match = SKIPPED.match(line)
            if not match:
                raise ValueError(f"unexpected skip line: {line}")
            unscanned.setdefault(norm_file(match.group(1)), clean(match.group(2)))
    return unscanned


def norm_file(name):
    name = str(name or "")
    # Only where a backslash separates directories: elsewhere a\b.py and
    # a/b.py are two files, and one must not stand in for the other. Python
    # under MSYS or Cygwin has os.sep "/", and a Windows foxguard beside it
    # still prints backslashes.
    if os.sep == "\\" or sys.platform in ("win32", "cygwin", "msys"):
        name = name.replace("\\", "/")
    while name.startswith("./"):
        name = name[2:]
    return name


def key(finding):
    snippet = " ".join(str(finding.get("snippet") or "").split())
    return (str(finding.get("rule_id") or ""), norm_file(finding.get("file")), snippet)


def clean(text):
    return " ".join(str(text or "").split())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level", required=True, choices=sorted(RANK))
    parser.add_argument("--tip", required=True)
    # Kept in command-line order: each --base-unscanned belongs to the --base
    # before it.
    parser.add_argument("--base", dest="reports", action="append", type=lambda v: ("base", v), default=[])
    parser.add_argument("--base-unscanned", dest="reports", action="append", type=lambda v: ("skip", v))
    parser.add_argument("--allow-unscanned", action="store_true")
    parser.add_argument("--base-incomplete", action="store_true")
    args = parser.parse_args()
    try:
        tip = load(args.tip)
        bases, skips = [], []
        for kind, path in args.reports:
            if kind == "base":
                bases.append(Counter(key(f) for f in load(path)))
                skips.append({})
            elif not skips:
                raise ValueError(f"--base-unscanned {path} has no --base before it")
            else:
                for name, reason in load_unscanned(path).items():
                    skips[-1].setdefault(name, reason)
        # Unscanned only when every base skipped it.
        unscanned = dict(skips[0]) if skips else {}
        for other in skips[1:]:
            unscanned = {n: r for n, r in unscanned.items() if n in other}
    except (OSError, ValueError) as err:
        print(f"foxguard report unreadable: {err}", file=sys.stderr)
        return 2
    known = Counter()
    for counts in bases:
        for k, n in counts.items():
            known[k] = max(known[k], n)
    threshold = RANK[args.level]
    seen = Counter()
    blocked = False
    tip.sort(key=lambda f: (norm_file(f.get("file")), str(f.get("line") or 0).zfill(12)))
    for finding in tip:
        k = key(finding)
        seen[k] += 1
        severity = str(finding.get("severity") or "").lower()
        # An unknown severity counts as critical: never let it through unread.
        rank = RANK.get(severity, RANK["critical"])
        if seen[k] <= known[k]:
            verdict, why = "WARN", "already in the base"
        elif k[1] in unscanned and rank >= threshold:
            reason = f"the base copy could not be scanned ({unscanned[k[1]]})"
            if args.base_incomplete:
                # A base that is not here skipped nothing: it might have read the file.
                verdict, why = "BLOCK", f"{reason}; another base was not scanned, so {ALLOW}=1 does not apply"
                blocked = True
            elif args.allow_unscanned:
                verdict, why = "WARN", f"{reason}; allowed by {ALLOW}=1"
            else:
                verdict, why = "BLOCK", f"{reason}; review the file, then push with {ALLOW}=1"
                blocked = True
        elif rank >= threshold:
            verdict, why = "BLOCK", "new"
            blocked = True
        else:
            verdict, why = "WARN", "new, below the block level"
        print("\t".join([
            verdict, severity or "unknown",
            f"{norm_file(finding.get('file'))}:{finding.get('line', '?')}",
            clean(finding.get("rule_id")), why, clean(finding.get("description")),
        ]))
    return 3 if blocked else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # a crash must refuse, not pass
        print(f"foxguard_push_compare: {err}", file=sys.stderr)
        sys.exit(2)
