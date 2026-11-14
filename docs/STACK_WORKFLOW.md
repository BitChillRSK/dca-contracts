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
4. Run the final-tree commands below. Explain every difference outside the protected paths.
5. Run the applicable gates for the resulting tree.
6. Present the exact heads, merge sequence, dispositions, and check results for review.
7. Apply the merge authorization rule in `AGENTS.md` before changing `main`.

## Final-tree checks for the relaunch integration

The audit snapshot is the source commit agreed with the external reviewer, Kann Audits:
`a229ea3b633ad1d0fcf319a8bceab59125049563` (`audit/kann-scope`).
It identifies the code submitted for review; it does not state that the audit is complete.
PR #194 is the intended final stack top. PR #195 is the integration candidate targeting `main`.

Run these commands in Bash or Zsh after publishing the candidate, immediately before requesting merge approval.
They stop on failure. The three checks verify the complete tree, protected paths, and every open PR head.

```bash
set -e
set -o pipefail
git fetch origin
stack_top=$(gh pr view 194 --json headRefOid --jq .headRefOid)
candidate=$(gh pr view 195 --json headRefOid --jq .headRefOid)
audit_snapshot=a229ea3b633ad1d0fcf319a8bceab59125049563

git diff --exit-code "$stack_top" "$candidate"
git diff --exit-code "$audit_snapshot" "$candidate" -- \
  src lib foundry.toml remappings.txt script .github Makefile

stack_heads=$(gh pr list --state open --limit 1000 --json number,headRefOid \
  --jq '.[] | [.number, .headRefOid] | @tsv')
test -n "$stack_heads"
test "$(printf '%s\n' "$stack_heads" | wc -l)" -lt 1000
while read -r pr_number pr_head; do
  git merge-base --is-ancestor "$pr_head" "$candidate" || {
    printf 'Candidate lacks PR #%s head %s\n' "$pr_number" "$pr_head"
    exit 1
  }
done <<< "$stack_heads"
git merge-base --is-ancestor origin/main "$candidate"
```

If the listing reaches 1,000 PRs, paginate it before continuing. An incomplete list cannot establish complete preservation.
The protected-path comparison must be empty. Review all other differences from the audit snapshot explicitly.
The accepted additions are #193's tests and #194's documentation and ancestry tooling.

These checks record a snapshot. If an included PR head or `main` changes, refresh the candidate and repeat the checks.
Do not infer content equality from passing ancestry checks.

## Integration method for the existing relaunch stack

A normal merge of #194 into `main` is unsuitable. Late #44 changes already exist on `main`.
They conflict in `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`, `foundry.toml`, `AGENTS.md`,
`docs/relaunch/R2-utc-purchase-period.md`, and `test/ai-generated/fuzz/Handler.t.sol`.
Other obsolete tests merge silently into `DcaConfigurationTest.t.sol` and `ModifiersTest.t.sol`.
Those tests use removed APIs and constructor arguments, so an ordinary merge can break the build without flagging those additions.

Build the integration commit from the frozen stack top's complete tree with `git commit-tree`.
The initial candidate has five parents:

1. The current `main` commit.
2. The frozen #194 head.
3. The isolated #49 head, `91c2c1ae4b8e63d403480acc4e2f3c5c9abe980c`.
4. The isolated #76 head, `19c1bb41f3109149b8dc4abafaf956e1122ea236`.
5. The isolated #155 head, `bbec4f22cfce58ce7d091aa67ce379a36d63139b`.

This preserves their histories while retaining exactly the reviewed files. It does not replay obsolete contract edits or tests.
The historical dispositions below explain why their old file contents are superseded.

For an updated #194, preserve the published #195 candidate as the first parent of a refresh commit.
Use the new frozen #194 head as its second parent and its complete tree as the refresh commit's tree.
The initial five parents remain ancestors. This permits a normal fast-forward push without rewriting published history.
Verify every open PR head and the current `main` remain ancestors before publishing the refresh.
If `main` changes, review its new commits before integration. Record their dispositions before adding its new head as another parent.

Publish the candidate on the integration branch for review. After explicit approval, merge #195 using a merge commit.
Check the resulting `main` tree against the approved candidate and inspect the constituent PR statuses.
Use no squash, rebase, branch deletion, or history rewrite in this integration.

**One-way operation:** merging records the complete history in `main` and can mark the constituent PRs as merged.
A revert can undo file changes. It cannot remove the recorded history or restore the previous PR statuses.

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
