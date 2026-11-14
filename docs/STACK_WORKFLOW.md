# Stacked PR workflow

A child includes its parent's current head only when that head is an ancestor of the child.
Equivalent patches can have different commit IDs. A failed check requires investigation; it does not prove missing behavior.

## Create and update

1. Fetch `origin` before selecting the latest open PR as the parent.
2. Create the child branch from that parent's remote head.
3. Run `git merge-base --is-ancestor origin/<parent-branch> HEAD` before creating the PR.
4. After publishing, run `python3 tools/check_stack_ancestry.py --pr <number>`.
5. After changing a parent, identify every dependent PR through its base/head branch relationships.
6. Propagate the updated parent through each dependent branch, from bottom to top.
7. Run the scoped check for every affected PR after propagation.
8. Review conflict resolutions, compare the final tree, and run the applicable gates from `AGENTS.md`.
9. Update each changed PR description and report any unresolved gaps before stopping.

Merge commits preserve existing commit IDs. A rebase replaces them.
Choose the method deliberately. Obtain approval before rewriting published history or changing an agreed audit snapshot.

## Check command

```bash
python3 tools/check_stack_ancestry.py             # all open PRs
python3 tools/check_stack_ancestry.py --pr 193    # one open PR
python3 tools/check_stack_ancestry.py --pr 193 --pr 194
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

The command requires Git, Python 3, and authenticated GitHub CLI access to this repository.
It fetches `origin` and reads open PRs. It changes no working files, local branches, or GitHub state.
For stacked bases, it uses the open parent's current head. For other bases, it uses the fetched remote branch.
It reports the commits missing from each child.

- Exit `0`: all selected relationships pass.
- Exit `1`: at least one relationship has missing ancestry.
- Exit `2`: listing, object, or Git errors prevent a complete check. Fork PR heads require a separate explicit check.

Run the check again after any parent changes. It records a snapshot, not a lock against concurrent pushes.
The command reports gaps; it does not repair them or authorize a merge.

## Merge approval

1. Check the complete stack before proposing its merge.
2. Investigate each gap. Distinguish missing changes from equivalent patches, later replacements, and intentional exclusions.
3. Record a disposition for each gap and identify the exact proposed final tree.
4. Compare that tree with the agreed audit snapshot. Explain every approved difference.
5. Run the gates for the resulting tree.
6. Present the exact heads, merge sequence, dispositions, and test results to the human.
7. Obtain explicit approval for the identified merge operation before changing `main`.

Questions about readiness do not authorize merging. Publishing a PR does not authorize merging it.

## Existing relaunch stack: reviewed gaps

The 14 November 2026 investigation compared the 137-PR chain with audit commit
`a229ea3b633ad1d0fcf319a8bceab59125049563`.
PR #44 is already merged; PR #45 now targets `main`. The check should continue to report these gaps
until an approved integration preserves their history and reconciles their content.

| Relationship | Missing commits | Disposition |
|---|---|---|
| #44 → #45 | Nine late R2 commits | Cadence behavior was implemented again in #134 (R75). The later invariant helper needs whole-day generation; #193 supplies that test follow-up. Keep the reviewed final contract implementation. |
| #49 → #50 | `91c2c1ae` | The delete-refund assertion was replaced by `9e734bf6`; `b92cd673` removed its unused tolerance constant. The replacement is not an identical tolerance. |
| #76 → #82 | `19c1bb41` | The same CI pin patch exists at `2c53f5ea`. |
| #155 → #156 | `bbec4f22` | The same gas-test patch exists at `8b13b7f3`. |

The pre-stack `main` also has toolchain commits absent by identity from the audit tip.
Their workflow pins are present in the tip. Reconcile their documentation against the final workflow.

These records do not authorize automatic conflict resolutions, rebases, merges, or exclusions.
Do not replay obsolete contract code merely to make the ancestry check pass.
Prepare integration separately and preserve the tested final tree, audit tag, and existing commits.
