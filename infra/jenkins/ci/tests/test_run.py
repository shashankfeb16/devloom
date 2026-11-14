"""Verify CI cleanup cannot target a development or production Compose stack."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run.sh"


class CleanupIsolationTests(unittest.TestCase):
    def run_cleanup(self, project):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            log = temporary / "docker.jsonl"
            docker = temporary / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['DOCKER_TEST_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            docker.chmod(0o755)
            environment = dict(os.environ, CI_PROJECT_NAME=project,
                               DOCKER_TEST_LOG=str(log),
                               PATH=f"{temporary}{os.pathsep}{os.environ['PATH']}")
            result = subprocess.run(["bash", str(SCRIPT), "cleanup"], env=environment,
                                    text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_non_ci_projects_and_shell_metacharacters_cannot_invoke_docker(self):
        for project in ["devloom", "devloom-production", "devloom-ci-", "devloom-ci-a;id",
                        "devloom-ci-../../production", "DEVLOOM-CI-TEST"]:
            with self.subTest(project=project):
                result, calls = self.run_cleanup(project)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, [])

    def test_cleanup_targets_only_the_selected_ci_project_and_image_tags(self):
        project = "devloom-ci-test-123"
        result, calls = self.run_cleanup(project)
        self.assertEqual(result.returncode, 0, result.stderr)
        compose_calls = [call for call in calls if call[0] == "compose"]
        self.assertEqual(len(compose_calls), 1)
        self.assertEqual(compose_calls[0][1:3], ["--project-name", project])
        self.assertEqual(compose_calls[0][-3:], ["down", "--volumes", "--remove-orphans"])
        removals = [call[2] for call in calls if call[:2] == ["image", "rm"]]
        self.assertEqual(set(removals), {f"devloom-ci:{project}", f"devloom-production:{project}"})
        self.assertFalse(any("prune" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
