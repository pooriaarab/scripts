import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent
AUDIT = ROOT / "worker-preview-audit"


class WorkerPreviewAuditTest(unittest.TestCase):
    def run_audit(self, files):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            result = subprocess.run([AUDIT, "--json", root], text=True, capture_output=True)
            return result, json.loads(result.stdout)

    def test_normalizes_pr_standard_branch_names(self):
        result = subprocess.run([AUDIT, "--normalize", "scr-130-add-worker-preview"], text=True, capture_output=True)
        self.assertEqual(result.stdout.strip(), "scr-130-add-worker-preview")
        invalid = subprocess.run([AUDIT, "--normalize", "SCR-130/Add Worker Preview!"], capture_output=True)
        self.assertEqual(invalid.returncode, 2)
        long = subprocess.run([AUDIT, "--normalize", "scr-130-" + "feature-" * 20], capture_output=True)
        self.assertEqual(long.returncode, 2)

    def test_blocks_shared_resources_and_unsafe_workflow(self):
        config = {"preview_urls": False, "containers": [{"class_name": "App"}],
                  "vars": {"API_ORIGIN": "https://production.example"},
                  "d1_databases": [{"binding": "DB", "database_id": "prod"}],
                  "durable_objects": {"bindings": [{"name": "DO", "script_name": "prod-do"}, {"name": "MISSING", "class_name": "Missing"}]},
                  "queues": {"producers": [{"binding": "QUEUE", "queue": "prod"}, {"binding": "MISSING_QUEUE", "queue": "missing"}]},
                  "previews": {"d1_databases": [{"binding": "DB", "database_id": "prod"}],
                               "durable_objects": {"bindings": [{"name": "DO", "script_name": "prod-do"}]}, "queues": {"producers": [{"binding": "QUEUE", "queue": "preview"}]}}}
        result, report = self.run_audit({"wrangler.json": json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": "jobs:\n  preview:\n    run: wrangler preview\n  cleanup:\n    run: wrangler preview delete"})
        self.assertEqual(result.returncode, 1)
        joined = "\n".join(report["blockers"])
        self.assertIn("shares a production resource", joined)
        self.assertIn("same fork guard", joined)
        self.assertIn("without a custom Preview domain", joined)
        self.assertIn("Preview vars are missing", joined)
        self.assertIn("Containers are missing", joined)
        self.assertIn("target an external production Worker", joined)
        self.assertTrue(all(message in joined for message in ("Durable Object Preview bindings are missing: MISSING", "Queue Preview producers are missing: MISSING_QUEUE")))

    def test_accepts_isolated_preview_configuration(self):
        config = {"preview_urls": True, "vars": {"MESSAGE": 'quote: prod,}'},
                  "d1_databases": [{"binding": "DB", "database_id": "prod"}],
                  "previews": {"vars": {"MESSAGE": "preview"},
                               "d1_databases": [{"binding": "DB", "database_id": "preview"}]}}
        guard = "head.repo.full_name == github.repository && github.repository_owner"
        workflow = f"cancel-in-progress: false\njobs:\n  preview:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview --config x --name \"$preview_name\"; curl x\n  cleanup:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview delete --config x --name \"$preview_name\""
        result, report = self.run_audit({"wrangler.preview.jsonc": "// safe\n" + json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": workflow})
        self.assertEqual(result.returncode, 0, report["blockers"])


if __name__ == "__main__":
    unittest.main()
