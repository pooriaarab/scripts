import json
import subprocess
import tempfile
import unittest
from pathlib import Path

AUDIT = Path(__file__).parent / "worker-preview-audit"
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
        expected = ("shares a production resource", "same fork guard", "without a custom Preview domain",
                    "Preview vars are missing", "Containers are missing", "target an external production Worker",
                    "Durable Object Preview bindings are missing: MISSING", "Queue Preview producers are missing: MISSING_QUEUE")
        self.assertTrue(all(message in joined for message in expected))
    def test_accepts_isolated_preview_configuration(self):
        config = {"preview_urls": True, "vars": {"MESSAGE": 'quote: prod,}'},
                  "d1_databases": [{"binding": "DB", "database_id": "prod"}],
                  "previews": {"vars": {"MESSAGE": "preview"},
                               "d1_databases": [{"binding": "DB", "database_id": "preview"}]}}
        guard = "head.repo.full_name == github.repository && github.repository_owner"
        workflow = f"concurrency:\n  cancel-in-progress: false\njobs:\n  preview:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview --config x --name \"$preview_name\"; curl x\n  cleanup:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview delete --config x --name \"$preview_name\""
        result, report = self.run_audit({"wrangler.preview.jsonc": "// safe\n" + json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": workflow})
        self.assertEqual(result.returncode, 0, report["blockers"])
    def test_rejects_workflow_faking_serialization_in_a_run_step(self):
        guard = "head.repo.full_name == github.repository && github.repository_owner"
        workflow = (
            f"jobs:\n"
            f'  preview:\n    if: {guard}\n    run: echo "cancel-in-progress: false"; GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x\n'
            f'  cleanup:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview delete --config x --name "$preview_name"'
        )
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": workflow})
        self.assertIn("Preview lifecycle jobs are not serialized", "\n".join(report["blockers"]))
    def test_flags_mismatched_deploy_and_cleanup_name_source(self):
        guard = "head.repo.full_name == github.repository && github.repository_owner"
        workflow = (
            f"cancel-in-progress: false\njobs:\n"
            f'  preview:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x\n'
            f'  cleanup:\n    if: {guard}\n    run: pull_request.head.ref; wrangler preview delete --config x --name "$BRANCH_NAME"'
        )
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": workflow})
        joined = "\n".join(report["blockers"])
        self.assertIn("deploy and cleanup need the same PR branch source", joined)
        self.assertIn("deploy and cleanup need the same exact Preview name", joined)
    def test_flags_incomplete_multi_field_preview_binding(self):
        config = {"send_email": [{"binding": "EMAIL", "destination_address": "prod@example.com"}],
                  "previews": {"send_email": [{"binding": "EMAIL"}]}}
        result, report = self.run_audit({"wrangler.json": json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}'})
        self.assertIn("send_email has an incomplete Preview binding", "\n".join(report["blockers"]))
    def test_accepts_send_email_preview_binding_with_only_one_recipient_field(self):
        config = {"send_email": [{"binding": "EMAIL", "destination_address": "prod@example.com"}],
                  "previews": {"send_email": [{"binding": "EMAIL", "destination_address": "preview@example.com"}]}}
        result, report = self.run_audit({"wrangler.json": json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}'})
        self.assertNotIn("send_email has an incomplete Preview binding", "\n".join(report["blockers"]))
    def test_parses_jsonc_with_a_comment_between_a_trailing_comma_and_close(self):
        text = '{\n  "vars": {"A": "1"}, // trailing comment before close\n}\n'
        result, report = self.run_audit({"wrangler.jsonc": text,
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}'})
        self.assertNotIn("cannot parse", "\n".join(report["blockers"]))
    def test_blocks_malformed_package_json_instead_of_crashing(self):
        result, report = self.run_audit({"wrangler.json": "{}",
                                         "package.json": '{"devDependencies": null}'})
        self.assertEqual(result.returncode, 1)
        self.assertNotEqual(report["blockers"], [])
    def test_flags_mismatched_deploy_and_cleanup_env_expression(self):
        guard = "head.repo.full_name == github.repository && github.repository_owner"
        deploy = (f'  preview:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview --config x '
                  '--env "${{ inputs.deploy_env }}" --name "$preview_name"; curl x\n')
        cleanup = (f'  cleanup:\n    if: {guard}\n    run: GITHUB_HEAD_REF; wrangler preview delete --config x '
                   '--env "${{ inputs.cleanup_env }}" --name "$preview_name"')
        workflow = "cancel-in-progress: false\njobs:\n" + deploy + cleanup
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview.yml": workflow})
        self.assertIn("deploy and cleanup use different Wrangler config or environment", "\n".join(report["blockers"]))
if __name__ == "__main__":
    unittest.main()
