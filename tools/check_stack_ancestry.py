#!/usr/bin/env python3
"""Check current open PR ancestry without changing branches or GitHub state."""

import argparse
import json
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def check_stack(prs, selected=None):
    by_number = {pr["number"]: pr for pr in prs}
    by_branch = {pr["headRefName"]: pr for pr in prs if not pr["isCrossRepository"]}
    requested = set(selected) if selected else set(by_number)
    unknown = requested - set(by_number)
    if unknown:
        raise ValueError(f"PRs are not open in this repository: {sorted(unknown)}")

    failures = 0
    for number in sorted(requested):
        pr = by_number[number]
        if pr["isCrossRepository"]:
            raise ValueError(f"PR #{number}: fork heads are unsupported; check their exact refs separately")
        parent = by_branch.get(pr["baseRefName"])
        # An open parent's current head is authoritative, even if the child's recorded base is stale.
        base = parent["headRefOid"] if parent else run(
            "git", "rev-parse", "--verify", f"refs/remotes/origin/{pr['baseRefName']}^{{commit}}"
        )
        head = pr["headRefOid"]
        for commit in (base, head):
            run("git", "cat-file", "-e", f"{commit}^{{commit}}")
        result = subprocess.run(["git", "merge-base", "--is-ancestor", base, head], check=False)
        if result.returncode == 1:
            failures += 1
            print(f"FAIL #{number}: {pr['headRefName']} lacks commits from {pr['baseRefName']}")
            print(run("git", "log", "--oneline", f"{head}..{base}", "--"))
        elif result.returncode != 0:
            raise ValueError(f"PR #{number}: git merge-base failed ({result.returncode})")
    print(f"Checked {len(requested)} PRs; {failures} ancestry gaps.")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, action="append", help="check this open PR only; repeat for multiple PRs")
    args = parser.parse_args()
    try:
        # Fetch branches only. Never rebase, merge, push, or retarget a PR here.
        subprocess.run(["git", "fetch", "origin", "--quiet"], check=True)
        prs = json.loads(run(
            "gh", "pr", "list", "--state", "open", "--limit", "1000", "--json",
            "number,baseRefName,headRefName,headRefOid,isCrossRepository",
        ))
        if len(prs) == 1000:
            raise ValueError("PR listing reached its limit; refusing an incomplete stack check")
        return check_stack(prs, args.pr)
    except (ValueError, subprocess.CalledProcessError, OSError) as error:
        print(f"ERROR: {error}. Refresh the refs or resolve the listing error, then rerun.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
