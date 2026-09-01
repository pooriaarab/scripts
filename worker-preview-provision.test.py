import hashlib
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
SCRIPT = Path(__file__).parent / "worker-preview-provision"
loader = importlib.machinery.SourceFileLoader("provisioner", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
provisioner = importlib.util.module_from_spec(spec)
loader.exec_module(provisioner)
def plan():
    owner = {"repository": "pooriaarab/example", "pull_request": 999,
             "branch": "scr-163-provision-preview-data", "head_sha": "a" * 40,
             "workflow": "Worker Preview Build", "run_id": 12,
             "artifact": "worker-preview-bundle", "artifact_id": 13,
             "artifact_digest": "sha256:" + "b" * 64}
    intended = {kind: [{"binding": binding,
                        "name": provisioner.resource_name(owner["repository"], owner["branch"], kind, binding)}]
                for kind, binding in (("d1", "DB"), ("kv", "CACHE"), ("r2", "FILES"))}
    intended.update({"target_worker": {"name": "example", "workers_dev": False},
                     "preview": {"name": owner["branch"], "hostname": owner["branch"] + ".preview.example.com",
                                 "preview_domain": "preview.example.com"},
                     "access": {"application_name": provisioner.resource_name(owner["repository"], owner["branch"], "access"),
                                "hostname": owner["branch"] + ".preview.example.com", "policy_name": provisioner.resource_name(owner["repository"], owner["branch"], "policy"),
                                "service_token_name": provisioner.resource_name(owner["repository"], owner["branch"], "ci")},
                     "test_identity": {"name": provisioner.resource_name(owner["repository"], owner["branch"], "test-user")}})
    acquired = {"preview": {"version_id": None},
                "access": {"application_id": None, "policy_id": None, "service_token_id": None},
                "test_identity": {"id": None},
                "d1": {"DB": {"id": None}}, "kv": {"CACHE": {"id": None}},
                "r2": {"FILES": {"name": None}}}
    return {"schema": 1, "owner": owner, "intended": intended, "acquired": acquired}
class FakeApi:
    account = "f" * 32
    ids = {"d1": "12345678-1234-1234-1234-123456789abc",
           "kv": "1" * 32}
    def __init__(self):
        self.items = {kind: [] for kind in provisioner.KINDS}
        self.creates = []
        self.ambiguous = set()
        self.definite = set()
    def list(self, kind): return list(self.items[kind])
    def create(self, kind, name):
        self.creates.append((kind, name))
        if kind in self.definite: raise provisioner.ProvisionError("rejected")
        item = {"name": name} if kind != "kv" else {"title": name}
        if kind == "d1": item["uuid"] = self.ids[kind]
        if kind == "kv": item["id"] = self.ids[kind]
        self.items[kind].append(item)
        if kind in self.ambiguous: raise provisioner.AmbiguousCreate("lost response")
        return item
class ProvisionTest(unittest.TestCase):
    def invoke(self, value, api=None, dry=False, root=None):
        root = root or Path(self.enterContext(tempfile.TemporaryDirectory()))
        source, states = root / "plan.json", root / "states"; states.mkdir(mode=0o700, exist_ok=True)
        source.write_text(json.dumps(value))
        result = provisioner.run(source, states, api or FakeApi(), dry)
        return root, result
    def test_creates_resources_and_persists_each_identifier(self):
        api = FakeApi()
        root, result = self.invoke(plan(), api)
        state = json.loads(Path(result["state"]).read_text())
        self.assertEqual(state["acquired"]["d1"]["DB"]["id"], api.ids["d1"])
        self.assertEqual(state["acquired"]["kv"]["CACHE"]["id"], api.ids["kv"])
        self.assertEqual(state["acquired"]["r2"]["FILES"]["name"], plan()["intended"]["r2"][0]["name"])
        self.assertFalse(next(root.joinpath("states").glob("*.pending"), None))
        self.assertEqual([item["action"] for item in result["actions"]], ["acquired"] * 3)
    def test_matches_the_reviewed_planner_namespace(self):
        value = plan()
        self.assertEqual(value["intended"]["d1"][0]["name"], "scr-163-prov-d1-fbb5becca9acbbd8")
        self.assertEqual(value["intended"]["kv"][0]["name"],
                         "scr-163-provision-preview-data-11ce1b37d5a55e80-kv-cache")
    def test_reconciles_ambiguous_create_and_is_idempotent(self):
        api = FakeApi(); api.ambiguous.add("d1")
        root, first = self.invoke(plan(), api)
        source, states = root / "plan.json", root / "states"
        key = hashlib.sha256(plan()["owner"]["repository"].encode()).hexdigest()[:16]
        provisioner.atomic_write(states / f"{api.account}-{key}-pr-999.pending",
                                 {"kind": "d1", "binding": "DB", "name": plan()["intended"]["d1"][0]["name"]}, create=True)
        second = provisioner.run(source, states, api)
        self.assertEqual(len(api.creates), 3)
        self.assertEqual([item["action"] for item in second["actions"]], ["unchanged"] * 3)
        self.assertEqual(json.loads(Path(first["state"]).read_text())["acquired"]["d1"]["DB"]["id"], api.ids["d1"])
        self.assertFalse(next(states.glob("*.pending"), None))
    def test_recovers_persisted_pending_attempt(self):
        api = FakeApi(); value = plan()
        root, result = self.invoke(value, api, dry=True)
        states = root / "states"
        key = hashlib.sha256(value["owner"]["repository"].encode()).hexdigest()[:16]
        state_path = states / f"{api.account}-{key}-pr-999.json"
        provisioner.atomic_write(state_path, value, create=True)
        intended = value["intended"]["d1"][0]
        pending = {"kind": "d1", "binding": "DB", "name": intended["name"]}
        provisioner.atomic_write(states / f"{api.account}-{key}-pr-999.pending", pending, create=True)
        api.create("d1", intended["name"])
        recovered = provisioner.run(root / "plan.json", states, api)
        self.assertEqual(recovered["actions"][0]["action"], "acquired")
        self.assertEqual(api.creates.count(("d1", intended["name"])), 1)
    def test_definite_failure_does_not_adopt_a_later_collision(self):
        api = FakeApi(); api.definite.add("d1"); value = plan(); item = value["intended"]["d1"][0]
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        with self.assertRaisesRegex(provisioner.ProvisionError, "rejected"): self.invoke(value, api, root=root)
        self.assertFalse(next((root / "states").glob("*.pending"), None))
        api.definite.clear(); api.create("d1", item["name"])
        with self.assertRaisesRegex(provisioner.ProvisionError, "not owned"):
            self.invoke(value, api, root=root)
    def test_dry_run_does_not_create_or_write_state(self):
        api = FakeApi()
        root, result = self.invoke(plan(), api, True)
        self.assertFalse(api.creates)
        self.assertFalse(Path(result["state"]).exists())
        self.assertEqual([item["action"] for item in result["actions"]], ["create"] * 3)
        self.assertTrue(next((root / "states").glob("*.lock"), None))
    def test_rejects_artifact_commands_ids_and_changed_names(self):
        cases = []
        command = plan(); command["command"] = "delete production"; cases.append(command)
        acquired = plan(); acquired["acquired"]["kv"]["CACHE"]["id"] = "1" * 32; cases.append(acquired)
        renamed = plan(); renamed["intended"]["r2"][0]["name"] = "artifact-controlled"; cases.append(renamed)
        domain = plan(); domain["intended"]["preview"]["preview_domain"] = "preview.staging.com"; cases.append(domain)
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(provisioner.ProvisionError): self.invoke(value)
if __name__ == "__main__":
    unittest.main()
