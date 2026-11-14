"""Exercise the ancestry check against real, temporary Git histories."""

import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import check_stack_ancestry as checker


class StackAncestryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.previous_directory = Path.cwd()
        os.chdir(self.directory.name)
        self.addCleanup(os.chdir, self.previous_directory)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Stack test")
        self.git("config", "user.email", "stack@example.invalid")
        self.root = self.commit("root")
        self.git("update-ref", "refs/remotes/origin/main", self.root)
        self.parent = self.commit("parent")
        self.child = self.commit("child")
        self.prs = [self.pr(1, "parent", "main", self.parent), self.pr(2, "child", "parent", self.child)]

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()

    def commit(self, message):
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def pr(self, number, head, base, commit):
        return dict(number=number, headRefName=head, baseRefName=base, headRefOid=commit, isCrossRepository=False)

    def check(self, selected=None):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = checker.check_stack(self.prs, selected)
        return result, output.getvalue()

    def test_aligned_stack_passes(self):
        self.assertEqual(self.check()[0], 0)

    def test_parent_update_reports_the_missing_commit(self):
        self.git("checkout", "--quiet", "--detach", self.parent)
        updated = self.commit("late parent fix")
        self.prs[0]["headRefOid"] = updated
        result, output = self.check()
        self.assertEqual(result, 1)
        self.assertIn("FAIL #2", output)
        self.assertIn("late parent fix", output)

    def test_merge_propagates_parent_update(self):
        self.git("checkout", "--quiet", "--detach", self.parent)
        updated = self.commit("late parent fix")
        self.prs[0]["headRefOid"] = updated
        self.git("checkout", "--quiet", "--detach", self.child)
        self.git("merge", "--quiet", "--no-ff", updated, "-m", "propagate parent")
        self.prs[1]["headRefOid"] = self.git("rev-parse", "HEAD")
        self.assertEqual(self.check()[0], 0)

    def test_main_update_is_checked_for_root_pr(self):
        self.git("checkout", "--quiet", "--detach", self.root)
        updated = self.commit("main update")
        self.git("update-ref", "refs/remotes/origin/main", updated)
        result, output = self.check([1])
        self.assertEqual(result, 1)
        self.assertIn("main update", output)

    def test_scoped_check_does_not_check_unselected_pr(self):
        self.prs[1]["headRefOid"] = self.root
        self.assertEqual(self.check([1])[0], 0)
        self.assertEqual(self.check([2])[0], 1)

    def test_unknown_pr_fails(self):
        with self.assertRaises(ValueError):
            self.check([999])

    def test_missing_object_is_an_error(self):
        self.prs[1]["headRefOid"] = "0" * 40
        with self.assertRaises(subprocess.CalledProcessError):
            self.check([2])

    def test_fork_pr_requires_separate_check(self):
        self.prs[1]["isCrossRepository"] = True
        with self.assertRaises(ValueError):
            self.check([2])


if __name__ == "__main__":
    unittest.main()
