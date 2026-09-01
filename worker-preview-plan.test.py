import importlib.machinery
import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

COMMAND = Path(__file__).parent / "worker-preview-plan"
SHA = "a" * 40
DIGEST = "sha256:" + "b" * 64


class WorkerPreviewPlanTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.pin = {
            "schema": 1, "repository": "pooriaarab/blogbat", "pull_request": 146,
            "branch": "blo-142-worker-previews", "head_sha": SHA,
            "workflow": "Worker Preview Build", "run_id": 91,
            "artifact": "worker-preview-bundle", "artifact_id": 81,
            "artifact_digest": DIGEST,
        }
        self.config = {
            "schema": 1, "repository": "pooriaarab/blogbat", "prefix": "blo",
            "worker_name": "blogbat-staging", "workers_dev": False,
            "preview_domain": "preview.staging.blogbat.com",
            "bindings": {"d1": ["DB"], "kv": ["CACHE"], "r2": ["ASSETS"]},
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_plan(self, pin=None, config=None):
        pin_path, config_path = self.root / "pin.json", self.root / "config.json"
        pin_path.write_text(json.dumps(pin or self.pin))
        config_path.write_text(json.dumps(config or self.config))
        output = self.root / f"plan-{len(list(self.root.glob('plan-*')))}.json"
        result = subprocess.run([COMMAND, pin_path, config_path, output], text=True, capture_output=True)
        return result, json.loads(output.read_text()) if result.returncode == 0 else None

    def test_derives_exact_host_and_empty_ownership_manifest(self):
        result, manifest = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        intended = manifest["intended"]
        self.assertEqual(intended["target_worker"]["name"], "blogbat-staging")
        self.assertEqual(intended["preview"]["name"], self.pin["branch"])
        self.assertEqual(intended["preview"]["hostname"],
                         "blo-142-worker-previews.preview.staging.blogbat.com")
        self.assertLessEqual(len(intended["d1"][0]["name"]), 32)
        self.assertEqual(manifest["owner"]["artifact_digest"], DIGEST)
        self.assertEqual(manifest["acquired"]["d1"], {"DB": {"id": None}})
        self.assertEqual(manifest["acquired"]["r2"], {"ASSETS": {"name": None}})
        self.assertTrue(all(value is None for value in manifest["acquired"]["access"].values()))
        output = Path(result.stdout.strip())
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_long_names_are_bounded_deterministic_and_collision_resistant(self):
        first = {**self.pin, "branch": "blo-142-" + "a" * 40}
        second = {**self.pin, "branch": "blo-142-" + "a" * 39 + "b"}
        short_domain = {**self.config, "preview_domain": "preview.x.co"}
        one_result, one = self.run_plan(first, short_domain)
        two_result, two = self.run_plan(second, short_domain)
        self.assertEqual((one_result.returncode, two_result.returncode), (0, 0))
        one_name, two_name = one["intended"]["r2"][0]["name"], two["intended"]["r2"][0]["name"]
        self.assertLessEqual(len(one_name), 63)
        self.assertIsNotNone(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", one_name))
        self.assertNotEqual(one_name, two_name)
        self.assertLessEqual(len(one["intended"]["d1"][0]["name"]), 32)
        self.assertLessEqual(len(one["intended"]["kv"][0]["name"]), 512)
        again_result, again = self.run_plan(first, short_domain)
        self.assertEqual(again_result.returncode, 0)
        self.assertEqual(one_name, again["intended"]["r2"][0]["name"])

    def test_rejects_invalid_preview_domains(self):
        domains = ("example.com", "preview.staging", "preview.Example.com",
                   "preview.example.com/path", "staging.preview.example.com")
        for domain in domains:
            with self.subTest(domain=domain):
                result, _ = self.run_plan(config={**self.config, "preview_domain": domain})
                self.assertNotEqual(result.returncode, 0)

    def test_accepts_both_required_preview_domain_forms(self):
        for domain in ("preview.blogbat.com", "preview.staging.blogbat.com"):
            with self.subTest(domain=domain):
                result, manifest = self.run_plan(
                    config={**self.config, "preview_domain": domain})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(manifest["intended"]["preview"]["preview_domain"], domain)

    def test_rejects_preview_hostname_beyond_access_limit(self):
        pin = {**self.pin, "branch": "blo-142-" + "a" * 48}
        result, _ = self.run_plan(pin=pin)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Access application URL limit", result.stderr)

    def test_namespaces_account_resources_by_repository(self):
        first_result, first = self.run_plan()
        other_pin = {**self.pin, "repository": "pooriaarab/other"}
        other_config = {**self.config, "repository": "pooriaarab/other"}
        other_result, other = self.run_plan(other_pin, other_config)
        self.assertEqual((first_result.returncode, other_result.returncode), (0, 0))
        self.assertNotEqual(first["intended"]["r2"][0]["name"],
                            other["intended"]["r2"][0]["name"])
        self.assertIn("c2bc21d0e5d44e9d", first["intended"]["r2"][0]["name"])

    def test_removes_output_when_directory_sync_fails(self):
        loader = importlib.machinery.SourceFileLoader("worker_preview_plan", str(COMMAND))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        output = self.root / "failed-plan.json"
        with mock.patch.object(module.os, "fsync", side_effect=[None, OSError("sync failed")]):
            with self.assertRaises(OSError):
                module.publish(output, {"schema": 1})
        self.assertFalse(output.exists())

    def test_rejects_hostile_pin_fields_and_values(self):
        cases = ({**self.pin, "commands": ["wrangler delete"]},
                 {**self.pin, "bindings": {"DB": "production-id"}},
                 {**self.pin, "routes": ["production.example.com"]},
                 {**self.pin, "preview_domain": "preview.attacker.example"},
                 {**self.pin, "resource_id": "production-id"},
                 {**self.pin, "branch": "blo-142-name; rm -rf x"},
                 {**self.pin, "workflow": "Hostile Build"},
                 {**self.pin, "artifact_digest": "sha256:../../secret"},
                 {**self.pin, "artifact_id": True},
                 {**self.pin, "schema": True})
        for pin in cases:
            with self.subTest(pin=pin):
                result, _ = self.run_plan(pin=pin)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_hostile_or_ambiguous_trusted_config(self):
        cases = ({**self.config, "routes": ["production.example.com"]},
                 {**self.config, "bindings": {"d1": ["DB;DROP"], "kv": [], "r2": []}},
                 {**self.config, "bindings": {"d1": ["DB"], "kv": ["DB"], "r2": []}},
                 {**self.config, "repository": "pooriaarab/other"},
                 {**self.config, "prefix": "evil"},
                 {**self.config, "worker_name": "production/name"},
                 {**self.config, "worker_name": "a" * 256},
                 {**self.config, "worker_name": "a" * 64, "workers_dev": True},
                 {**self.config, "workers_dev": "false"},
                 {**self.config, "schema": True},
                 {**self.config, "cloudflare_account_id": "production-id"})
        for config in cases:
            with self.subTest(config=config):
                result, _ = self.run_plan(config=config)
                self.assertNotEqual(result.returncode, 0)

    def test_accepts_platform_worker_name_when_workers_dev_is_disabled(self):
        config = {**self.config, "worker_name": "WorkerName" + "a" * 245}
        result, manifest = self.run_plan(config=config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(manifest["intended"]["target_worker"]["name"], config["worker_name"])

    def test_rejects_duplicate_json_keys(self):
        pin_path, config_path = self.root / "pin.json", self.root / "config.json"
        pin_path.write_text('{"schema":1,"schema":1}')
        config_path.write_text(json.dumps(self.config))
        result = subprocess.run([COMMAND, pin_path, config_path, self.root / "plan.json"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate JSON key", result.stderr)

    def test_rejects_traceback_inputs_and_preserves_output(self):
        pin_path, config_path, output = self.root / "pin.json", self.root / "config.json", self.root / "owned.json"
        pin_path.write_text('{"schema":' + "9" * 5000 + "}")
        config_path.write_text(json.dumps(self.config))
        output.write_text("keep")
        result = subprocess.run([COMMAND, pin_path, config_path, output], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(output.read_text(), "keep")
        output.unlink()
        output.symlink_to(self.root / "missing")
        pin_path.write_text(json.dumps(self.pin))
        result = subprocess.run([COMMAND, pin_path, config_path, output], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "missing").exists())


if __name__ == "__main__":
    unittest.main()
