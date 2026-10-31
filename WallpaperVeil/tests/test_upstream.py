"""Pinned-source materialization tests use only small local Git fixtures."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OWN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OWN))
import upstream
from upstream_fixture import make_project


class UpstreamInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wallpaper-veil-upstream-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project, self.commit, self.digest = make_project(self.root)
        self.patch = patch.object(upstream, "QUALIFIED_POLICY_SHA256", self.digest)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.path = self.project / "engine/upstream.json"

    def policy_edit(self, change, *, qualify=False):
        value = json.loads(self.path.read_text())
        change(value)
        raw = (json.dumps(value, indent=2) + "\n").encode()
        self.path.write_bytes(raw)
        if qualify:
            upstream.QUALIFIED_POLICY_SHA256 = hashlib.sha256(raw).hexdigest()

    def reject(self):
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            upstream.validate_checkout(self.project)

    def test_clean_product_checkout_recovers_all_inputs_from_history(self):
        self.assertFalse((self.project / "Hammerspoon").exists())
        result = upstream.materialize_inputs(self.project, self.root / "inputs")
        self.assertEqual(result["policy"]["upstream"]["commit"], self.commit)
        self.assertEqual(len(result["files"]), 87)
        self.assertEqual(len(result["policy"]["componentNotices"]), 81)
        for entry in result["files"]:
            raw = (result["root"] / entry["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), entry["sha256"])
        self.assertEqual((result["root"] / "extensions/eventtap/LICENSE.md").stat().st_mode & 0o777, 0o755)

    def test_policy_edit_requires_deliberate_requalification(self):
        self.policy_edit(lambda p: p["upstream"].update(build="9999"))
        self.reject()

    def test_unknown_schema_and_nonempty_patch_list_rejected_even_with_changed_digest(self):
        raw = self.path.read_bytes()
        for change in (lambda p: p.update(schema=True), lambda p: p.update(schema=2),
                       lambda p: p.update(patches=[{"path": "engine/patches/change.patch"}])):
            with self.subTest(change=change):
                self.path.write_bytes(raw)
                self.policy_edit(change, qualify=True)
                self.reject()

    def test_other_commit_or_tree_cannot_be_substituted(self):
        raw = self.path.read_bytes()
        for field in ("commit", "tree"):
            with self.subTest(field=field):
                self.path.write_bytes(raw)
                self.policy_edit(lambda p: p["upstream"].update({field: "a" * 40}), qualify=True)
                self.reject()

    def test_mutated_header_blob_or_missing_notice_is_rejected(self):
        raw = self.path.read_bytes()
        for change in (lambda p: p["headers"][0].update(blob="b" * 40),
                       lambda p: p["componentNotices"].pop()):
            with self.subTest(change=change):
                self.path.write_bytes(raw)
                self.policy_edit(change, qualify=True)
                self.reject()

    def test_undeclared_engine_patch_or_native_tree_is_rejected(self):
        for relative in ("engine/patches/hidden.patch", "Hammerspoon/core.m", "extensions/screen/injected.m"):
            with self.subTest(relative=relative):
                file = self.project / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("unregistered native changes")
                self.reject()
                file.unlink()
                # Empty historical source roots are also forbidden.
                if relative.startswith("Hammerspoon/"):
                    file.parent.rmdir()
                if relative.startswith("extensions/"):
                    file.parent.rmdir(); file.parent.parent.rmdir()

    def test_tracked_retired_source_is_rejected_even_after_working_file_is_removed(self):
        file = self.project / "Hammerspoon/injected.m"
        file.parent.mkdir(); file.write_text("unregistered native changes")
        subprocess.run(["/usr/bin/git", "-C", str(self.project), "add", "Hammerspoon"], check=True)
        file.unlink(); file.parent.rmdir()
        self.reject()

    def test_materialization_requires_fresh_non_symlink_staging(self):
        output = self.root / "inputs"
        output.mkdir(); (output / "old").write_text("old input")
        with self.assertRaises(RuntimeError):
            upstream.materialize_inputs(self.project, output)
        alias = self.root / "alias"; alias.symlink_to(output)
        with self.assertRaises(RuntimeError):
            upstream.materialize_inputs(self.project, alias)

    def test_paths_modes_and_duplicate_objects_are_validated(self):
        raw = self.path.read_bytes()
        cases = (lambda p: p["headers"][0].update(path="../escape.h"),
                 lambda p: p["headers"][0].update(mode="120000"),
                 lambda p: p["headers"].__setitem__(1, dict(p["headers"][0])))
        for change in cases:
            with self.subTest(change=change):
                self.path.write_bytes(raw)
                self.policy_edit(change, qualify=True)
                self.reject()

    def test_wrong_tag_and_missing_history_fail_closed(self):
        subprocess.run(["/usr/bin/git", "-C", str(self.project), "tag", "-d", "1.1.1"], check=True,
                       stdout=subprocess.PIPE)
        self.reject()


if __name__ == "__main__":
    unittest.main()
