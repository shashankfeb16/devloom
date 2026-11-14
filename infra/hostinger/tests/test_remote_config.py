"""Reject malformed deployment input before executing any remote operations."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class RemoteConfigTests(unittest.TestCase):
    def check(self, **changes):
        config = dict(domain="app.your-domain.com", acme_email="you@your-domain.com", ssh_port=22, release_id="a" * 24)
        config.update(changes)
        script = Path(__file__).parents[1] / "scripts/remote-deploy.sh"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            return subprocess.run(["bash", str(script), "--check-config", str(path)], capture_output=True, text=True)

    def test_normal_configuration(self):
        self.assertEqual(self.check().returncode, 0)

    def test_shell_metacharacters_in_hostname(self):
        self.assertNotEqual(self.check(domain="app.example.com;touch /tmp/unsafe").returncode, 0)

    def test_newline_in_email(self):
        self.assertNotEqual(self.check(acme_email="you@example.com\nINJECT=value").returncode, 0)

    def test_release_path_traversal(self):
        self.assertNotEqual(self.check(release_id="../../outside").returncode, 0)

    def test_port_range(self):
        self.assertNotEqual(self.check(ssh_port=65536).returncode, 0)

    def test_boolean_is_not_a_port(self):
        self.assertNotEqual(self.check(ssh_port=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
