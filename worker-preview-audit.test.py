import json
import subprocess
import tempfile
import unittest
from pathlib import Path

AUDIT = Path(__file__).parent / "worker-preview-audit"
GUARD = "head.repo.full_name == github.repository && github.repository_owner"
PACKAGE = '{"devDependencies":{"wrangler":"4.127.1"}}'
CONTROLLER = json.dumps({"schema": 1, "mode": "external",
                         "build_workflow": "Worker Preview Build",
                         "artifact": "worker-preview-bundle",
                         "status_context": "worker-preview/live"})


def external_build(extra="", permissions="  contents: read", persist="false", artifact="worker-preview-bundle",
                   ref="${{ github.event.pull_request.head.sha }}", job_permissions=""):
    return ("name: Worker Preview Build\non:\n  pull_request:\npermissions:\n"
            f"{permissions}\njobs:\n  build:\n    runs-on: ubuntu-latest\n{job_permissions}    steps:\n"
            f"      - uses: actions/checkout@v4\n        with:\n          persist-credentials: {persist}\n          ref: {ref}\n"
            f"      - run: npm run build\n{extra}"
            f"      - uses: actions/upload-artifact@v4\n        with:\n          name: {artifact}\n          path: dist\n")


def workflow(deploy, cleanup, deploy_if=None, cleanup_if=None, concurrent=True):
    prefix = "concurrency:\n  group: g\n  cancel-in-progress: false\n" if concurrent else ""
    deploy_if = f"    if: {deploy_if}\n" if deploy_if else ""
    cleanup_if = f"    if: {cleanup_if}\n" if cleanup_if else ""
    return (f"{prefix}jobs:\n  preview:\n{deploy_if}    run: {deploy}\n"
            f"  cleanup:\n{cleanup_if}    run: {cleanup}")


class WorkerPreviewAuditTest(unittest.TestCase):
    def run_audit(self, files, untracked=()):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            for name in set(files) - set(untracked):
                subprocess.run(["git", "add", "--", name], cwd=root, check=True)
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
        result, report = self.run_audit({"wrangler.preview.jsonc": "// safe\n" + json.dumps(config),
                                         "package.json": '{"devDependencies":{"wrangler":"4.127.1"}}',
                                         ".github/workflows/preview-build.yml": external_build(),
                                         ".github/worker-preview-controller.json": CONTROLLER})
        self.assertEqual(result.returncode, 0, report["blockers"])
        self.assertEqual(report["deployment_boundary"], "external controller")
    def test_rejects_secret_bearing_pull_request_preview_deployment(self):
        env = 'CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}\n      CLOUDFLARE_ACCOUNT_ID: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}'
        contents = (
            "name: Unsafe Preview\non:\n  pull_request:\nconcurrency:\n  group: preview\n  cancel-in-progress: false\njobs:\n"
            f"  preview:\n    if: {GUARD} && github.event.action != 'closed'\n    env:\n      {env}\n"
            '    run: GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x\n'
            f"  cleanup:\n    if: {GUARD} && github.event.action == 'closed'\n    env:\n      {env}\n"
            '    run: GITHUB_HEAD_REF; wrangler preview delete --config x --name "$preview_name"')
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        self.assertEqual(result.returncode, 1)
        self.assertIn("pull_request workflow deploys PR-controlled code with Preview credentials",
                      "\n".join(report["blockers"]))
    def test_rejects_credentials_in_external_artifact_build(self):
        build = external_build("      - run: echo x\n        env:\n          API_TOKEN: ${{ secrets.API_TOKEN }}\n")
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": build,
                                         ".github/worker-preview-controller.json": CONTROLLER})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Worker Preview Build contains secrets or sensitive environment values",
                      "\n".join(report["blockers"]))
    def test_rejects_external_build_without_read_only_checkout_contract(self):
        build = external_build(permissions="  contents: read\n  pull-requests: write", persist="true", ref="main",
                               job_permissions="    permissions: write-all\n")
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": build,
                                         ".github/worker-preview-controller.json": CONTROLLER})
        joined = "\n".join(report["blockers"])
        self.assertIn("Worker Preview Build permissions must be contents: read", joined)
        self.assertIn("Worker Preview Build checkout must set persist-credentials: false", joined)
        self.assertIn("Worker Preview Build checkout must use the exact pull_request head SHA", joined)
    def test_bounds_checkout_options_to_the_checkout_step(self):
        build = external_build().replace(
            "        with:\n          persist-credentials: false\n          ref: ${{ github.event.pull_request.head.sha }}\n", "").replace(
            "          name: worker-preview-bundle\n", "          persist-credentials: false\n          name: worker-preview-bundle\n")
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": build,
                                         ".github/worker-preview-controller.json": CONTROLLER})
        joined = "\n".join(report["blockers"])
        self.assertIn("Worker Preview Build checkout must set persist-credentials: false", joined)
        self.assertIn("Worker Preview Build checkout must use the exact pull_request head SHA", joined)
    def test_rejects_bare_and_bracket_credential_contexts(self):
        for expression in ("${{ toJSON(secrets) }}", "${{ secrets['API_TOKEN'] }}",
                           "${{ github['token'] }}", "${{ vars['API_TOKEN'] }}",
                           "${{ env['PREVIEW_USER'] }}"):
            with self.subTest(expression=expression):
                build = external_build(f'      - run: echo x\n        env:\n          "X": {expression}\n')
                result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                                 ".github/workflows/preview-build.yml": build,
                                                 ".github/worker-preview-controller.json": CONTROLLER})
                self.assertEqual(result.returncode, 1)
                self.assertIn("pull_request workflow exposes source-repository credentials",
                              "\n".join(report["blockers"]))
    def test_rejects_quoted_sensitive_env_and_credentials_in_other_pr_workflows(self):
        for trigger in ('"on": pull_request', "'on': pull_request", '"on" : pull_request'):
            with self.subTest(trigger=trigger):
                tests = (f"name: Tests\n{trigger}\npermissions:\n  contents: read\njobs:\n  test:\n"
                         "    env:\n      X: ${{ secrets.MODEL_KEY }}\n    run: npm test\n")
                build = external_build('      - run: echo x\n        env: { "API_TOKEN": example_placeholder }\n')
                result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                                 ".github/workflows/preview-build.yml": build,
                                                 ".github/workflows/tests.yml": tests,
                                                 ".github/worker-preview-controller.json": CONTROLLER})
                joined = "\n".join(report["blockers"])
                self.assertIn("preview-build.yml: pull_request workflow exposes source-repository credentials", joined)
                self.assertIn("tests.yml: pull_request workflow exposes source-repository credentials", joined)

    def test_rejects_extra_trigger_and_writable_pull_request_checkout(self):
        build = external_build().replace("on:\n  pull_request:", "on: [pull_request, push]")
        tests = "name: Tests\non: pull_request\npermissions: read-all\njobs:\n  t:\n    'permissions': write-all\n    steps:\n      - uses: actions/checkout@v4\n"
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": build,
                                         ".github/workflows/tests.yml": tests,
                                         ".github/worker-preview-controller.json": CONTROLLER})
        joined = "\n".join(report["blockers"])
        self.assertIn("Worker Preview Build must use only the pull_request event", joined)
        self.assertIn("pull_request workflow permissions must be explicitly read-only", joined)
        self.assertIn("pull_request checkout must set persist-credentials: false", joined)

    def test_parses_quoted_spaced_keys_and_mixed_case_checkout(self):
        tests = ('name: Tests\n"on" : pull_request\n"permissions" : read-all\njobs:\n  t:\n'
                 "    steps:\n      - 'uses' : \"Actions/Checkout@v4\"\n")
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": external_build(),
                                         ".github/workflows/tests.yml": tests,
                                         ".github/worker-preview-controller.json": CONTROLLER})
        joined = "\n".join(report["blockers"])
        self.assertNotIn("pull_request workflow permissions must be explicitly read-only", joined)
        self.assertIn("pull_request checkout must set persist-credentials: false", joined)
    def test_fails_closed_for_unverified_source_hosted_deployer(self):
        deploy = ("name: Worker Preview Deploy\non:\n  workflow_run:\n    workflows: [Worker Preview Build]\n"
                  "jobs:\n  deploy:\n    environment: worker-previews\n    env:\n"
                  "      API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}\n    run: ./deploy-preview\n")
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-deploy.yml": deploy})
        self.assertEqual(result.returncode, 1)
        self.assertIn("source-hosted trusted deployer needs a verified branch-restricted environment",
                      "\n".join(report["blockers"]))
    def test_rejects_inexact_external_controller_contract(self):
        controller = json.loads(CONTROLLER)
        controller["artifact"] = "preview-output"
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         ".github/workflows/preview-build.yml": external_build(),
                                         ".github/worker-preview-controller.json": json.dumps(controller)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("external controller contract must match the required schema",
                      "\n".join(report["blockers"]))
    def test_rejects_untracked_external_controller_contract(self):
        files = {"wrangler.jsonc": "{}", "package.json": PACKAGE,
                 ".github/workflows/preview-build.yml": external_build(),
                 ".github/worker-preview-controller.json": CONTROLLER}
        result, report = self.run_audit(files, {".github/worker-preview-controller.json"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("external controller contract must be tracked", "\n".join(report["blockers"]))
    def test_delegates_authenticated_preview_verification_to_external_controller(self):
        result, report = self.run_audit({"wrangler.jsonc": "{}", "package.json": PACKAGE,
                                         "src/auth.ts": "import 'better-auth';",
                                         ".github/workflows/preview-build.yml": external_build(),
                                         ".github/worker-preview-controller.json": CONTROLLER})
        self.assertEqual(result.returncode, 0, report["blockers"])
        self.assertIn("verify Preview bindings, URL, indexing, and authentication",
                      report["controller_requirements"])
    def test_flags_deploy_and_cleanup_without_mutually_exclusive_pr_actions(self):
        contents = workflow('GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x',
                            'GITHUB_HEAD_REF; wrangler preview delete --config x --name "$preview_name"',
                            GUARD, GUARD)
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        self.assertIn("deploy and cleanup need mutually exclusive PR action conditions", "\n".join(report["blockers"]))
    def test_flags_missing_cloudflare_credential_passthrough(self):
        contents = workflow('echo secrets.CLOUDFLARE_API_TOKEN vars.CLOUDFLARE_ACCOUNT_ID; GITHUB_HEAD_REF; '
                            'wrangler preview --config x --name "$preview_name"; curl x',
                            'echo secrets.CLOUDFLARE_API_TOKEN vars.CLOUDFLARE_ACCOUNT_ID; GITHUB_HEAD_REF; '
                            'wrangler preview delete --config x --name "$preview_name"',
                            f"{GUARD} && github.event.action != 'closed'",
                            f"{GUARD} && github.event.action == 'closed'")
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        joined = "\n".join(report["blockers"])
        self.assertIn("deploy does not pass CLOUDFLARE_API_TOKEN to Wrangler", joined)
        self.assertIn("cleanup does not pass CLOUDFLARE_ACCOUNT_ID to Wrangler", joined)
    def test_rejects_workflow_faking_serialization_in_a_run_step(self):
        contents = workflow('echo "cancel-in-progress: false"; GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x',
                            'GITHUB_HEAD_REF; wrangler preview delete --config x --name "$preview_name"',
                            GUARD, GUARD, concurrent=False)
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        self.assertIn("Preview lifecycle jobs are not serialized", "\n".join(report["blockers"]))
        self.assertIn("workflow does not probe the live Preview", "\n".join(report["blockers"]))
    def test_flags_mismatched_deploy_and_cleanup_name_source(self):
        contents = workflow('GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x',
                            'pull_request.head.ref; wrangler preview delete --config x --name "$BRANCH_NAME"',
                            GUARD, GUARD)
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
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
        contents = workflow('GITHUB_HEAD_REF; wrangler preview --config x --env "${{ inputs.deploy_env }}" '
                            '--name "$preview_name"; curl x',
                            'GITHUB_HEAD_REF; wrangler preview delete --config x --env "${{ inputs.deploy_env }}" '
                            '--name "$preview_name"', GUARD, GUARD)
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        self.assertIn("dynamic Wrangler environments need manual Preview verification", "\n".join(report["blockers"]))
    def test_flags_mismatched_unquoted_env_expression(self):
        contents = workflow('GITHUB_HEAD_REF; wrangler preview --config x --env ${{ inputs.deploy_env }} '
                            '--name "$preview_name"; curl x',
                            'GITHUB_HEAD_REF; wrangler preview delete --config x --env ${{ inputs.cleanup_env }} '
                            '--name "$preview_name"', GUARD, GUARD)
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        self.assertIn("deploy and cleanup use different Wrangler config or environment", "\n".join(report["blockers"]))
    def test_rejects_fork_guard_only_present_in_a_run_step(self):
        contents = workflow('echo "head.repo.full_name == github.repository github.repository_owner"; '
                            'GITHUB_HEAD_REF; wrangler preview --config x --name "$preview_name"; curl x',
                            'GITHUB_HEAD_REF; wrangler preview delete --config x --name "$preview_name"')
        result, report = self.run_audit({"wrangler.jsonc": "{}",
                                         "package.json": PACKAGE,
                                         ".github/workflows/preview.yml": contents})
        joined = "\n".join(report["blockers"])
        self.assertIn("deploy and cleanup need the same fork guard", joined)
        self.assertIn("deploy and cleanup need the same owner guard", joined)
if __name__ == "__main__":
    unittest.main()
