"""Fail if docs/quality.md no longer matches what tools/eval produces.

The quality table is a published claim. If a scoring change moves a number and
the report is not regenerated in the same change, this check fails.

Usage: python3 tools/check-quality-docs.py <committed.md> <fresh.md>
"""

import re
import sys

ROW = r"\| `([a-z0-9-]+)` \| \*\*([0-9.]+)\*\*"


def main():
    if len(sys.argv) != 3:
        print("usage: check-quality-docs.py <committed.md> <fresh.md>")
        return 2
    committed = open(sys.argv[1], encoding="utf-8").read()
    fresh = open(sys.argv[2], encoding="utf-8").read()

    rows = re.findall(ROW, fresh)
    if not rows:
        print("no metric rows found in the fresh report — the report format changed")
        return 1

    bad = []
    for name, ndcg in rows:
        m = re.search(r"\| `" + re.escape(name) + r"` \| \*\*([0-9.]+)\*\*", committed)
        if not m:
            bad.append(f"{name}: missing from the committed report")
        elif m.group(1) != ndcg:
            bad.append(f"{name}: committed {m.group(1)} != measured {ndcg}")

    if bad:
        print("docs/quality.md is stale — regenerate it with tools/eval:")
        print("\n".join(bad))
        return 1

    print(f"{len(rows)} configurations match the committed report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
