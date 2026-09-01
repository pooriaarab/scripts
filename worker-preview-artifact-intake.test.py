import hashlib
import json
import os
import subprocess
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
COMMAND = Path(__file__).parent / "worker-preview-artifact-intake"
REPO = "pooriaarab/blogbat"
BRANCH = "blo-142-worker-previews"
SHA = "a" * 40
BASE_SHA = "c" * 40
WORKFLOW_PATH = ".github/workflows/worker-preview-build.yml"
class ArtifactIntakeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.api = self.root / "api"
        self.api.mkdir()
        fake = self.root / "gh"
        fake.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ["FAKE_GH_API"])
endpoint = sys.argv[2]
if endpoint.endswith("/pulls/146"): name = "pr.json"
elif endpoint.endswith("/actions/workflows"): name = "workflows.json"
elif endpoint.endswith("/actions/workflows/17/runs"): name = "runs.json"
elif endpoint.endswith("/runs/91/artifacts"): name = "artifacts.json"
elif endpoint.endswith("/contents/.github/workflows/worker-preview-build.yml"):
    ref = next(value.split("=", 1)[1] for value in sys.argv if value.startswith("ref="))
    name = "head-workflow.json" if ref == "a" * 40 else "base-workflow.json"
elif endpoint.endswith("/artifacts/81/zip"):
    sys.stdout.buffer.write((root / "bundle.zip").read_bytes())
    if os.environ.get("FAKE_GH_RACE"): (root / "pr.json").write_text((root / "moved-pr.json").read_text())
    raise SystemExit
else: print(f"unexpected endpoint: {endpoint}", file=sys.stderr); raise SystemExit(3)
sys.stdout.write((root / name).read_text())
""")
        fake.chmod(0o755)
        self.env = {**os.environ, "FAKE_GH_API": str(self.api),
                    "PATH": f"{self.root}:{os.environ['PATH']}"}
        self.write_api()
    def tearDown(self):
        self.temp.cleanup()
    def write_api(self, *, pr=None, runs=None, artifact=None):
        pr = pr or {"state": "open", "title": "[BLO-142] Add Worker Previews", "head": {"sha": SHA, "ref": BRANCH,
                    "repo": {"full_name": REPO}}, "base": {"sha": BASE_SHA, "repo": {"full_name": REPO}}}
        run = {"id": 91, "workflow_id": 17, "name": "Worker Preview Build", "event": "pull_request",
               "status": "completed", "conclusion": "success", "head_sha": SHA,
               "head_branch": BRANCH, "head_repository": {"full_name": REPO},
               "pull_requests": [{"number": 146}]}
        self.write_bundle({"worker/worker.js": b"export default {};",
                           "assets/index.html": b"preview", "migrations/0001_init.sql": b"SELECT 1;"})
        digest = hashlib.sha256((self.api / "bundle.zip").read_bytes()).hexdigest()
        artifact = artifact or {"id": 81, "name": "worker-preview-bundle", "expired": False,
                                "size_in_bytes": (self.api / "bundle.zip").stat().st_size,
                                "digest": f"sha256:{digest}"}
        (self.api / "pr.json").write_text(json.dumps(pr))
        (self.api / "moved-pr.json").write_text(json.dumps({**pr, "head": {**pr["head"], "sha": "b" * 40}}))
        (self.api / "workflows.json").write_text(json.dumps({"workflows": [
            {"id": 17, "name": "Worker Preview Build", "path": WORKFLOW_PATH, "state": "active"},
            {"id": 99, "name": "Worker Preview Build",
             "path": ".github/workflows/hostile.yml", "state": "active"},
        ]}))
        blob = {"type": "file", "path": WORKFLOW_PATH, "sha": "d" * 40}
        (self.api / "head-workflow.json").write_text(json.dumps(blob))
        (self.api / "base-workflow.json").write_text(json.dumps(blob))
        (self.api / "runs.json").write_text(json.dumps({"workflow_runs": runs or [run]}))
        (self.api / "artifacts.json").write_text(json.dumps({"artifacts": [artifact]}))
    def write_bundle(self, files, *, record=None, mutate=None):
        record = record or {"schema": 1, "repository": REPO, "pull_request": 146,
                            "head_sha": SHA, "branch": BRANCH,
                            "files": {name: f"sha256:{hashlib.sha256(data).hexdigest()}"
                                      for name, data in files.items()}}
        with warnings.catch_warnings(), zipfile.ZipFile(self.api / "bundle.zip", "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr("artifact-manifest.json", json.dumps(record))
            for name, data in files.items(): archive.writestr(name, data)
            if mutate: mutate(archive)
    def refresh_artifact(self, **changes):
        path = self.api / "bundle.zip"
        value = {"id": 81, "name": "worker-preview-bundle", "expired": False,
                 "size_in_bytes": path.stat().st_size,
                 "digest": f"sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}"}
        value.update(changes)
        (self.api / "artifacts.json").write_text(json.dumps({"artifacts": [value]}))
    def run_intake(self, workflow_path=WORKFLOW_PATH):
        output = self.root / "accepted"
        result = subprocess.run([COMMAND, REPO, "146", "--prefix", "blo",
                                 "--workflow-path", workflow_path, output], env=self.env,
                                text=True, capture_output=True)
        return result, output
    def test_accepts_current_verified_bundle_and_pins_it_atomically(self):
        result, output = self.run_intake()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / "bundle/worker/worker.js").read_text(), "export default {};")
        pin = json.loads((output / "intake.json").read_text())
        self.assertEqual((pin["run_id"], pin["artifact_id"], pin["head_sha"]), (91, 81, SHA))
        self.assertTrue(pin["artifact_digest"].startswith("sha256:"))
        self.assertEqual((output / "bundle/worker/worker.js").stat().st_mode & 0o111, 0)
    def test_rejects_untrusted_pull_request_and_workflow_state(self):
        pr_path, runs_path = self.api / "pr.json", self.api / "runs.json"
        original_pr, original_runs = pr_path.read_text(), runs_path.read_text()
        cases = {
            "closed PR": ({**json.loads(original_pr), "state": "closed"}, None),
            "fork PR": ({**json.loads(original_pr), "head": {"sha": SHA, "ref": BRANCH,
                                                                "repo": {"full_name": "other/blogbat"}}}, None),
            "invalid branch": ({**json.loads(original_pr), "head": {"sha": SHA, "ref": "feature/x",
                                                                       "repo": {"full_name": REPO}}}, None),
            "wrong prefix": ({**json.loads(original_pr), "head": {"sha": SHA, "ref": "evil-142-name", "repo": {"full_name": REPO}}}, None),
            "wrong issue": ({**json.loads(original_pr), "head": {"sha": SHA, "ref": "blo-999-name", "repo": {"full_name": REPO}}}, None),
            "stale run": (None, [{**json.loads(original_runs)["workflow_runs"][0], "head_sha": "b" * 40}]),
            "failed run": (None, [{**json.loads(original_runs)["workflow_runs"][0], "conclusion": "failure"}]),
            "wrong workflow": (None, [{**json.loads(original_runs)["workflow_runs"][0], "name": "Other"}]),
            "duplicate run": (None, json.loads(original_runs)["workflow_runs"] * 2),
        }
        for label, (pr, runs) in cases.items():
            with self.subTest(label):
                pr_path.write_text(json.dumps(pr) if pr else original_pr)
                runs_path.write_text(json.dumps({"workflow_runs": runs}) if runs else original_runs)
                result, output = self.run_intake()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
        pr_path.write_text(original_pr)
        runs_path.write_text(original_runs)
    def test_pins_exact_workflow_path_and_stable_id(self):
        workflows = self.api / "workflows.json"
        runs = self.api / "runs.json"
        exact = json.loads(workflows.read_text())["workflows"][0]
        hostile = json.loads(workflows.read_text())["workflows"][1]
        workflows.write_text(json.dumps({"workflows": [hostile]}))
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        result, output = self.run_intake(".github/workflows/../hostile.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        workflows.write_text(json.dumps({"workflows": [exact, hostile]}))
        value = json.loads(runs.read_text())["workflow_runs"][0]
        runs.write_text(json.dumps({"workflow_runs": [{**value, "workflow_id": 99}]}))
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
    def test_rejects_modified_workflow_blob(self):
        path = self.api / "head-workflow.json"
        value = json.loads(path.read_text())
        path.write_text(json.dumps({**value, "sha": "e" * 40}))
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("workflow differs from the base", result.stderr)
        self.assertFalse(output.exists())
    def test_rejects_untrusted_artifact_metadata(self):
        original = (self.api / "artifacts.json").read_text()
        cases = ({"expired": True}, {"digest": "sha256:" + "0" * 64},
                 {"size_in_bytes": 512 * 1024 * 1024 + 1}, {"name": "other"})
        for changes in cases:
            with self.subTest(changes=changes):
                (self.api / "artifacts.json").write_text(original)
                value = json.loads(original)["artifacts"][0]
                value.update(changes)
                (self.api / "artifacts.json").write_text(json.dumps({"artifacts": [value]}))
                result, output = self.run_intake()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
    def test_rejects_unsafe_or_unrecorded_archive_entries(self):
        base = {"worker/worker.js": b"export default {};"}
        link = zipfile.ZipInfo("assets/link")
        link.create_system = 3
        link.external_attr = (0o120777 << 16)
        cases = {
            "traversal": lambda archive: archive.writestr("../escape", b"x"),
            "non-canonical": lambda archive: archive.writestr("worker//other.js", b"x"),
            "linked": lambda archive: archive.writestr(link, "target"),
            "unknown": lambda archive: archive.writestr("secret.env", b"x"),
            "duplicate": lambda archive: archive.writestr("worker/worker.js", b"other"),
            "case collision": lambda archive: (archive.writestr("assets/A", b"a"),
                                                  archive.writestr("assets/a", b"b")),
            "control character": lambda archive: archive.writestr("assets/bad\n\x1b", b"x"),
            "LZMA": lambda archive: archive.writestr("assets/lzma", b"x", compress_type=zipfile.ZIP_LZMA),
            "non-SQL migration": lambda archive: archive.writestr("migrations/meta.json", b"{}"),
        }
        for label, mutate in cases.items():
            with self.subTest(label):
                self.write_bundle(base, mutate=mutate)
                self.refresh_artifact()
                result, output = self.run_intake()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
    def test_rejects_manifest_mismatch_and_preserves_existing_output(self):
        files = {"worker/worker.js": b"export default {};"}
        good_digest = f"sha256:{hashlib.sha256(files['worker/worker.js']).hexdigest()}"
        record = {"schema": 1, "repository": REPO, "pull_request": 146,
                  "head_sha": "b" * 40, "branch": BRANCH,
                  "files": {"worker/worker.js": good_digest}}
        self.write_bundle(files, record=record)
        self.refresh_artifact()
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        record["head_sha"] = SHA
        record["files"]["worker/worker.js"] = "sha256:" + "0" * 64
        self.write_bundle(files, record=record)
        self.refresh_artifact()
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        output.mkdir()
        (output / "sentinel").write_text("keep")
        result, _ = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((output / "sentinel").read_text(), "keep")
        (output / "sentinel").unlink()
        output.rmdir()
        output.symlink_to(self.root / "missing-target", target_is_directory=True)
        result, _ = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "missing-target").exists())
    def test_revalidates_pull_request_before_atomic_pin(self):
        self.env["FAKE_GH_RACE"] = "1"
        result, output = self.run_intake()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
if __name__ == "__main__":
    unittest.main()
