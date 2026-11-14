"""Exercise production deployment guards with a fake Terraform executable."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy" / "run.sh"


class DeploymentGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "checkout with spaces"
        self.script = self.root / "infra/jenkins/deploy/run.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, self.script)
        self.source_module = self.root / "infra/hostinger"
        (self.source_module / "scripts").mkdir(parents=True)
        (self.source_module / "main.tf").write_text("# isolated test module\n")
        (self.source_module / "scripts/package.py").write_text("# isolated packager\n")
        self.state = self.directory / "durable state"
        self.config = self.directory / "credential.json"
        self.values = {
            "deploy_enabled": True,
            "vps_host": "198.18.0.1",
            "ssh_user": "root",
            "ssh_port": 22,
            "ssh_host_key": "ssh-ed25519 AAAATESTPUBLICKEY",
            "domain": "devloom.unit.example",
            "acme_email": "operator@unit.example",
        }
        self.write_config()
        self.log = self.directory / "terraform.jsonl"
        binary_directory = self.directory / "bin"
        binary_directory.mkdir()
        terraform = binary_directory / "terraform"
        terraform.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "with open(os.environ['TERRAFORM_TEST_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "for arg in sys.argv[1:]:\n"
            "    if arg.startswith('-out='):\n"
            "        pathlib.Path(arg[5:]).write_text('saved test plan')\n"
        )
        terraform.chmod(0o755)
        self.environment = dict(
            os.environ,
            PATH=f"{binary_directory}{os.pathsep}{os.environ['PATH']}",
            SSH_AUTH_SOCK=str(self.directory / "fake-agent.sock"),
            DEVLOOM_DEPLOY_CONFIG=str(self.config),
            DEVLOOM_TF_STATE_DIR=str(self.state),
            CI_REVISION="a" * 40,
            TERRAFORM_TEST_LOG=str(self.log),
            PYTHONDONTWRITEBYTECODE="1",
        )

    def write_config(self):
        self.config.write_text(json.dumps(self.values))

    def run_deploy(self, action, **environment):
        return subprocess.run(
            ["bash", str(self.script), action],
            env=dict(self.environment, **environment),
            text=True,
            capture_output=True,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_apply_uses_the_saved_plan_and_durable_state(self):
        result = self.run_deploy("plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        private = self.root / ".jenkins-deploy"
        config = json.loads((private / "production.tfvars.json").read_text())
        self.assertEqual(config["source_directory"], str(self.root))
        self.assertIsNone(config["ssh_private_key_path"])
        backend = json.loads((private / "module/backend_override.tf.json").read_text())
        self.assertEqual(
            backend["terraform"]["backend"]["local"]["path"],
            str(self.state / "terraform.tfstate"),
        )
        result = self.run_deploy("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        apply = self.calls()[-1]
        self.assertEqual(apply[1], "apply")
        self.assertEqual(apply[-1], str(private / "production.tfplan"))
        self.assertNotIn("-auto-approve", apply)

    def test_apply_refuses_a_missing_plan_or_different_tested_revision(self):
        result = self.run_deploy("apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.run_deploy("plan").returncode, 0)
        previous_calls = self.calls()
        result = self.run_deploy("apply", CI_REVISION="b" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), previous_calls)

    def test_credentials_cannot_override_checkout_key_or_state_configuration(self):
        for key in ["source_directory", "ssh_private_key_path", "backend"]:
            with self.subTest(key=key):
                self.values[key] = "/untrusted/location"
                self.write_config()
                result = self.run_deploy("plan")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                del self.values[key]

    def test_plan_requires_explicit_enabled_and_complete_configuration(self):
        for key, value in [("deploy_enabled", False), ("deploy_enabled", "true"),
                           ("ssh_host_key", ""), ("vps_host", ""),
                           ("domain", ""), ("acme_email", "")]:
            with self.subTest(key=key, value=value):
                old = self.values[key]
                self.values[key] = value
                self.write_config()
                result = self.run_deploy("plan")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.values[key] = old

    def test_plan_refuses_a_second_state_history(self):
        (self.source_module / "terraform.tfstate").write_text("test existing state")
        result = self.run_deploy("plan")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Migrate", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_persistent_state_cannot_silently_switch_targets(self):
        self.assertEqual(self.run_deploy("plan").returncode, 0)
        previous_calls = self.calls()
        self.values["vps_host"] = "198.18.0.2"
        self.write_config()
        result = self.run_deploy("plan")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different target", result.stderr)
        self.assertEqual(self.calls(), previous_calls)

    def test_cleanup_removes_plans_but_preserves_durable_state(self):
        self.assertEqual(self.run_deploy("plan").returncode, 0)
        state_file = self.state / "terraform.tfstate"
        state_file.write_text("persistent deployment state")
        result = self.run_deploy("cleanup", SSH_AUTH_SOCK="", DEVLOOM_DEPLOY_CONFIG="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / ".jenkins-deploy").exists())
        self.assertEqual(state_file.read_text(), "persistent deployment state")


if __name__ == "__main__":
    unittest.main()
