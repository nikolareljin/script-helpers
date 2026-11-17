"""Split foxguard findings of a pushed tip into new and already present.

Usage: foxguard_push_compare.py --level <critical|high|medium|low>
       --tip <tip.json> [--base <base.json> ...]

Reads foxguard JSON reports (`foxguard --format json`). A tip finding is new
when its rule, file and whitespace-normalized snippet occur more often at the
tip than in every base report, so a finding that only moved lines is not new.
Prints one tab-separated line per tip finding:
    BLOCK|WARN <severity> <file>:<line> <rule> <why> <description>
Exit 0: nothing blocks. 1: a new finding at or above --level. 2: a report
could not be read.
"""

import argparse
import json
import sys
from collections import Counter

RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}


def load(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    findings = data.get("findings") if isinstance(data, dict) else None
    if not isinstance(findings, list):
        raise ValueError("no findings list")
    return [f for f in findings if isinstance(f, dict)]


def norm_file(name):
    name = str(name or "").replace("\\", "/")
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
    parser.add_argument("--base", action="append", default=[])
    args = parser.parse_args()
    try:
        tip = load(args.tip)
        bases = [Counter(key(f) for f in load(path)) for path in args.base]
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
    tip.sort(key=lambda f: (norm_file(f.get("file")), int(f.get("line") or 0)))
    for finding in tip:
        k = key(finding)
        seen[k] += 1
        severity = str(finding.get("severity") or "").lower()
        # An unknown severity counts as critical: never let it through unread.
        rank = RANK.get(severity, RANK["critical"])
        if seen[k] <= known[k]:
            verdict, why = "WARN", "already in the base"
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
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
