"""Behavior checks for deployment archives: integrity, isolation, and safe paths."""
import hashlib
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("package", Path(__file__).parents[1] / "scripts/package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "lib").mkdir()
        self.source = self.root / "lib/example.ex"
        self.source.write_bytes(b"defmodule Example do\nend\n")
        self.manifest = {"lib/example.ex": hashlib.sha256(self.source.read_bytes()).hexdigest()}
        self.output = self.root / "out/source.tar.gz"

    def test_only_planned_files_are_included_and_archive_is_reproducible(self):
        (self.root / ".env").write_text("SECRET=keep-private")
        module.package(self.root, self.manifest, self.output)
        original = self.output.read_bytes()
        with tarfile.open(self.output) as archive:
            self.assertEqual(archive.getnames(), ["lib/example.ex"])
            self.assertEqual(archive.extractfile("lib/example.ex").read(), self.source.read_bytes())
        module.package(self.root, self.manifest, self.output)
        self.assertEqual(original, self.output.read_bytes())

    def test_source_changes_after_plan_are_rejected(self):
        self.source.write_text("changed since planning")
        with self.assertRaisesRegex(ValueError, "Source changed"):
            module.package(self.root, self.manifest, self.output)
        self.assertFalse(self.output.exists())

    def test_traversal_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            module.package(self.root, {"../secret": "a" * 64}, self.output)

    def test_symlinks_are_rejected(self):
        self.source.unlink()
        self.source.symlink_to(self.root / ".env")
        with self.assertRaisesRegex(ValueError, "Symlink"):
            module.package(self.root, self.manifest, self.output)


if __name__ == "__main__":
    unittest.main()
