"""Regressions for database topology, credentials, probes and CNPG replacement."""
import os
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.overlays = {}
        for overlay in ("local", "dev", "staging", "prod", "dev-cnpg"):
            rendered = subprocess.check_output(
                [os.environ.get("KUBECTL", "kubectl"), "kustomize", str(ROOT / "k8s/overlays" / overlay)], text=True)
            cls.overlays[overlay] = list(yaml.safe_load_all(rendered))

    def find(self, overlay, kind, name):
        return next(d for d in self.overlays[overlay] if d["kind"] == kind and d["metadata"]["name"] == name)

    def test_standalone_has_exactly_one_database(self):
        for overlay in ("local", "dev", "staging", "prod"):
            with self.subTest(overlay=overlay):
                self.assertEqual(self.find(overlay, "StatefulSet", "postgres")["spec"]["replicas"], 1)

    def test_demo_secrets_exist_only_locally(self):
        self.assertEqual({d["metadata"]["name"] for d in self.overlays["local"] if d["kind"]=="Secret"},
                         {"postgres-credentials", "postgres-admin-credentials"})
        for overlay in ("dev", "staging", "prod", "dev-cnpg"):
            self.assertFalse([d for d in self.overlays[overlay] if d["kind"]=="Secret"])
        pod = self.find("prod", "StatefulSet", "postgres")["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(pod["envFrom"][0]["secretRef"]["name"], "postgres-admin-credentials")
        api = self.find("prod", "Deployment", "api")["spec"]["template"]["spec"]["containers"][0]
        user = next(e for e in api["env"] if e["name"] == "DATABASE_USER")
        self.assertEqual(user["valueFrom"]["secretKeyRef"]["name"], "postgres-credentials")

    def test_liveness_is_independent_from_readiness(self):
        for overlay in self.overlays:
            pod = self.find(overlay,"Deployment","api")["spec"]["template"]["spec"]["containers"][0]
            self.assertEqual(pod["livenessProbe"]["httpGet"]["path"], "/livez")
            self.assertEqual(pod["readinessProbe"]["httpGet"]["path"], "/readyz")
            self.assertEqual(pod["startupProbe"]["httpGet"]["path"], "/livez")

    def test_cnpg_replaces_standalone_and_old_backup(self):
        docs = self.overlays["dev-cnpg"]
        self.assertFalse([d for d in docs if d["kind"] in ("StatefulSet", "CronJob", "PersistentVolumeClaim")])
        self.assertFalse([d for d in docs if d["kind"]=="Service" and d["metadata"]["name"]=="postgres"])
        cluster = self.find("dev-cnpg", "Cluster", "cnpg-cluster")
        init = cluster["spec"]["bootstrap"]["initdb"]
        self.assertIn("postInitApplicationSQL", init)
        self.assertNotIn("postInitSQL", init)
        self.assertTrue(any("GRANT SELECT" in sql for sql in init["postInitApplicationSQL"]))

if __name__ == "__main__":
    unittest.main()
