"""Check credential setup rejects unsafe input and backup failures stay failures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.called = self.directory / "called"
        self.mock = self.directory / "kubectl"
        self.mock.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n')
        self.mock.chmod(0o700)
        self.env = dict(os.environ, PATH=f"{self.directory}:{os.environ['PATH']}", CALL_LOG=str(self.called))

    def credentials(self, app):
        admin_path, app_path = self.directory / "admin.env", self.directory / "app.env"
        admin_path.write_text("POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=test-admin-only\nPOSTGRES_DB=demodb\n")
        app_path.write_text(app)
        return subprocess.run(["bash", str(ROOT/"scripts/create-db-secrets.sh"), "test-context", "test-namespace", str(admin_path), str(app_path)],
                              env=self.env, text=True, capture_output=True)

    def test_invalid_credentials_do_not_touch_cluster(self):
        for app in ("POSTGRES_USER=reader\nPOSTGRES_DB=demodb\n",
                    "POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=other\nPOSTGRES_DB=demodb\n",
                    "POSTGRES_USER=reader\nPOSTGRES_PASSWORD=other\nPOSTGRES_DB=wrong\n"):
            with self.subTest(app=app):
                result = self.credentials(app)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.called.exists())

    def test_valid_credentials_are_not_passed_as_literals_or_printed(self):
        result = self.credentials("POSTGRES_USER=reader\nPOSTGRES_PASSWORD=test-app-only\nPOSTGRES_DB=demodb\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.called.read_text()
        self.assertIn("--from-env-file=", calls)
        self.assertIn("--server-side", calls)
        self.assertNotIn("--from-literal", calls)
        for value in ("test-admin-only", "test-app-only"):
            self.assertNotIn(value, calls+result.stdout+result.stderr)

    def test_empty_context_or_namespace_does_not_touch_cluster(self):
        for context, namespace in (("", "test-namespace"), ("test-context", "")):
            result = subprocess.run(
                ["bash", str(ROOT/"scripts/create-db-secrets.sh"), context, namespace, "unused", "unused"],
                env=self.env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("nonempty context and namespace", result.stderr)
            self.assertFalse(self.called.exists())

    def test_backup_job_failure_exits_before_restore(self):
        self.mock.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALL_LOG"
case " $* " in
  *" wait "*) exit 1;;
esac
''')
        result = subprocess.run(["bash", str(ROOT/"scripts/test/test-backup-job.sh")], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        calls = self.called.read_text()
        self.assertNotIn("apply -f", calls)
        self.assertNotIn("PASS", result.stdout)

    def test_outage_check_requires_explicit_target(self):
        for missing in ("KUBE_CONTEXT", "NAMESPACE"):
            env = dict(self.env, KUBE_CONTEXT="test-context", NAMESPACE="test-namespace")
            env.pop(missing)
            result = subprocess.run(
                ["bash", str(ROOT/"scripts/test/test-database-outage.sh")],
                env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(missing, result.stderr)
            self.assertFalse(self.called.exists())

if __name__ == "__main__":
    unittest.main()
