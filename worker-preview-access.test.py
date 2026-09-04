import copy, json, subprocess, tempfile, unittest
import importlib.machinery, importlib.util
from pathlib import Path
COMMAND = Path(__file__).parent / "worker-preview-access"
loader = importlib.machinery.SourceFileLoader("worker_preview_access", str(COMMAND))
spec = importlib.util.spec_from_loader(loader.name, loader)
access = importlib.util.module_from_spec(spec); loader.exec_module(access)
class FakeCloudflare:
    def __init__(self, secret_path=None, ambiguous=None, hidden=0):
        self.items = {"access/service_tokens": [], "access/apps": [], "policies": []}
        self.created, self.deleted, self.secret_path, self.ambiguous, self.hidden, self.subdomain = [], [], secret_path, ambiguous, hidden, {"enabled": False, "previews_enabled": False}
    def key(self, path): return "policies" if path.endswith("/policies") else path
    def list(self, path):
        if path == "access/service_tokens" and self.hidden: self.hidden -= 1; return []
        return copy.deepcopy(self.items[self.key(path)])
    def get(self, path):
        if path.endswith("/subdomain"): return copy.deepcopy(self.subdomain)
        identifier = path.rsplit("/", 1)[-1]
        for items in self.items.values():
            for item in items:
                if item.get("id") == identifier: return copy.deepcopy(item)
        raise access.AccessError("missing")
    def create(self, path, body):
        kind = "service_token" if path == "access/service_tokens" else (
            "application" if path == "access/apps" else body["name"].rsplit("-", 1)[-1] + "_policy")
        if kind == "application" and self.secret_path:
            assert self.secret_path.exists() and self.secret_path.stat().st_mode & 0o777 == 0o600
        ids = {"service_token": "tokenid01", "application": "appid001",
               "service_policy": "service01", "human_policy": "humanid01"}
        if self.ambiguous == kind + "_absent": raise access.AmbiguousCreate("lost before create")
        item = {**copy.deepcopy(body), "id": ids[kind]}
        if kind == "service_token": item.update(client_id="client.example", client_secret="secret_value")
        self.items[self.key(path)].append(item); self.created.append(kind)
        if self.ambiguous == kind: raise access.AmbiguousCreate("lost response")
        return copy.deepcopy(item)
    def delete(self, path):
        identifier = path.rsplit("/", 1)[-1]; self.items["access/service_tokens"] = [item for item in self.items["access/service_tokens"] if item["id"] != identifier]; self.deleted.append(identifier)
class WorkerPreviewAccessTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        owner = {"repository": "pooriaarab/blogbat", "pull_request": 146,
                 "branch": "blo-142-worker-previews", "head_sha": "a" * 40,
                 "workflow": "Worker Preview Build", "run_id": 91,
                 "artifact": "worker-preview-bundle", "artifact_id": 81,
                 "artifact_digest": "sha256:" + "b" * 64}
        branch, repo = owner["branch"], owner["repository"]
        host = branch + ".preview.staging.blogbat.com"
        self.plan = {"schema": 1, "owner": owner, "intended": {
            "target_worker": {"name": "blogbat-staging", "workers_dev": False},
            "preview": {"name": branch, "hostname": host, "preview_domain": "preview.staging.blogbat.com"},
            "d1": [], "kv": [], "r2": [],
            "access": {"application_name": access.resource_name(repo, branch, "access"), "hostname": host,
                       "policy_name": access.resource_name(repo, branch, "policy"),
                       "service_token_name": access.resource_name(repo, branch, "ci")},
            "test_identity": {"name": access.resource_name(repo, branch, "test-user")}},
            "acquired": {"preview": {"version_id": None}, "d1": {}, "kv": {}, "r2": {},
                         "access": {"application_id": None, "policy_id": None, "service_token_id": None},
                         "test_identity": {"id": None}}}
        self.config = {"schema": 1, "repository": repo, "account_id": "c" * 32, "preview_domain": "preview.staging.blogbat.com", "preview_urls": False,
                       "reviewer_emails": ["Reviewer@Example.com"],
                       "identity_provider_id": "identity01"}
        self.plan_path, self.config_path = self.root / "plan.json", self.root / "config.json"
        self.plan_path.write_text(json.dumps(self.plan)); self.config_path.write_text(json.dumps(self.config))
        self.state_dir = self.root / "state"; self.state_dir.mkdir(mode=0o700)
    def tearDown(self): self.temp.cleanup()
    def desired(self): return access.validate(copy.deepcopy(self.plan), copy.deepcopy(self.config))
    def test_dry_run_is_deterministic_exact_and_has_no_side_effects(self):
        command = [COMMAND, self.plan_path, self.config_path, self.root / "unused", "--dry-run"]
        first = subprocess.run(command, text=True, capture_output=True)
        second = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual((first.returncode, first.stdout), (0, second.stdout)); self.assertFalse((self.root / "unused").exists())
        desired = json.loads(first.stdout)["desired"]
        self.assertIs(desired["preview_urls"], False)
        self.assertTrue(desired["application"]["service_auth_401_redirect"])
        self.assertEqual(desired["human_policy"]["include"], [{"email": {"email": "reviewer@example.com"}}])
        self.assertEqual(desired["human_policy"]["require"], [{"login_method": {"id": "identity01"}}])
        self.assertNotIn("any_valid_service_token", first.stdout); self.assertNotIn("everyone", first.stdout)
        (self.root / "repo" / ".git").mkdir(parents=True)
        with self.assertRaisesRegex(access.AccessError, "outside"): access.secure_directory(self.root / "repo" / "secret")
        with self.assertRaisesRegex(access.AccessError, "already exist"): access.secure_directory(self.root / "missing")
        paths = access.scope_paths(self.root, self.config["account_id"], self.plan["owner"])
        variants = [access.scope_paths(self.root, "d" * 32, self.plan["owner"]), access.scope_paths(self.root, self.config["account_id"], {**self.plan["owner"], "repository": "pooriaarab/other"}), access.scope_paths(self.root, self.config["account_id"], {**self.plan["owner"], "pull_request": 147})]
        self.assertEqual(len({paths, *variants}), 4)
    def test_provisions_once_persists_secret_first_and_reconciles_by_id(self):
        state, secret = self.state_dir / "access.json", self.state_dir / "service-token.json"
        api = FakeCloudflare(secret)
        actions = access.provision(self.plan, self.desired(), api, state, secret)
        self.assertEqual(api.created, ["service_token", "application", "service_policy", "human_policy"])
        self.assertTrue(all(item["action"] == "acquired" for item in actions))
        self.assertEqual(access.secret(secret)["service_token_id"], "tokenid01")
        again = access.provision(self.plan, self.desired(), api, state, secret)
        self.assertTrue(all(item["action"] == "unchanged" for item in again)); self.assertEqual(len(api.created), 4)
        updated = copy.deepcopy(self.plan); updated["owner"].update(head_sha="d" * 40, run_id=92, artifact_id=82, artifact_digest="sha256:" + "e" * 64)
        access.provision(updated, self.desired(), api, state, secret)
        self.assertEqual(json.loads(state.read_text())["owner"], updated["owner"]); self.assertEqual(len(api.created), 4)
    def test_recovers_exact_ambiguous_app_but_never_adopts_token_by_name(self):
        state, secret = self.state_dir / "access.json", self.state_dir / "service-token.json"
        api = FakeCloudflare(secret, "application")
        access.provision(self.plan, self.desired(), api, state, secret)
        self.assertEqual(json.loads(state.read_text())["access"]["application_id"], "appid001")
        missing = self.root / "missing-app"; missing.mkdir(mode=0o700); api = FakeCloudflare(missing / "secret.json", "application_absent")
        self.assertRaises(access.AmbiguousCreate, access.provision, self.plan, self.desired(), api, missing / "state.json", missing / "secret.json"); record = json.loads((missing / "state.json").read_text()); record["reconcile_after"] = 1; missing.joinpath("state.json").write_text(json.dumps(record))
        self.assertRaisesRegex(access.AccessError, "retry provisioning once", access.provision, self.plan, self.desired(), api, missing / "state.json", missing / "secret.json"); api.ambiguous = None; access.provision(self.plan, self.desired(), api, missing / "state.json", missing / "secret.json")
        other = self.root / "other"; other.mkdir(mode=0o700)
        api = FakeCloudflare(other / "service-token.json", "service_token")
        with self.assertRaisesRegex(access.AccessError, "retry provisioning once"): access.provision(self.plan, self.desired(), api, other / "access.json", other / "service-token.json")
        self.assertEqual(api.deleted, ["tokenid01"]); self.assertEqual(api.items["access/service_tokens"], []); api.ambiguous = None
        access.provision(self.plan, self.desired(), api, other / "access.json", other / "service-token.json")
        absent = self.root / "absent"; absent.mkdir(mode=0o700); api = FakeCloudflare(absent / "secret.json", "service_token_absent")
        self.assertRaisesRegex(access.AccessError, "not visible", access.provision, self.plan, self.desired(), api, absent / "state.json", absent / "secret.json"); record = json.loads((absent / "state.json").read_text()); record["reconcile_after"] = 1; absent.joinpath("state.json").write_text(json.dumps(record))
        self.assertRaisesRegex(access.AccessError, "after one hour", access.provision, self.plan, self.desired(), api, absent / "state.json", absent / "secret.json")
        api.ambiguous = None; access.provision(self.plan, self.desired(), api, absent / "state.json", absent / "secret.json")
        delayed = self.root / "delayed"; delayed.mkdir(mode=0o700); api = FakeCloudflare(delayed / "secret.json", "service_token", 3)
        self.assertRaisesRegex(access.AccessError, "not visible", access.provision, self.plan, self.desired(), api, delayed / "state.json", delayed / "secret.json"); self.assertRaisesRegex(access.AccessError, "retry provisioning once", access.provision, self.plan, self.desired(), api, delayed / "state.json", delayed / "secret.json"); self.assertEqual(api.deleted, ["tokenid01"])
    def test_rejects_unowned_policy_and_hostile_inputs(self):
        state, secret = self.state_dir / "access.json", self.state_dir / "service-token.json"
        api = FakeCloudflare(secret); access.provision(self.plan, self.desired(), api, state, secret)
        api.items["policies"].append({"id": "attacker1", "name": "bypass", "decision": "bypass"})
        with self.assertRaisesRegex(access.AccessError, "exactly the two"):
            access.provision(self.plan, self.desired(), api, state, secret)
        api.items["policies"].pop(); api.items["access/apps"].append({**api.items["access/apps"][0], "id": "attacker2", "name": "other"})
        with self.assertRaisesRegex(access.AccessError, "exactly one"): access.provision(self.plan, self.desired(), api, state, secret)
        good = json.loads(state.read_text()); bad = copy.deepcopy(good); bad["pending"] = []; state.write_text(json.dumps(bad))
        with self.assertRaises(access.AccessError): access.load_state(state, self.plan["owner"], access.identity(self.desired()))
        bad = copy.deepcopy(good); bad["pending"] = "service_token"; bad["token_snapshot"] = [{}]; bad["reconcile_after"] = 1; state.write_text(json.dumps(bad))
        with self.assertRaises(access.AccessError): access.load_state(state, self.plan["owner"], access.identity(self.desired()))
        bad = copy.deepcopy(good); bad["pending"] = "application"; state.write_text(json.dumps(bad)); self.assertRaises(access.AccessError, access.load_state, state, self.plan["owner"], access.identity(self.desired()))
        bad = copy.deepcopy(good); bad["pending"], bad["reconcile_after"] = "human_policy", 1; state.write_text(json.dumps(bad)); self.assertRaises(access.AccessError, access.load_state, state, self.plan["owner"], access.identity(self.desired()))
        stale = self.root / "stale"; stale.mkdir(mode=0o700); stale_state, stale_secret = stale / "state.json", stale / "secret.json"
        access.write_json(stale_secret, {"schema": 1, "service_token_id": "staletok", "client_id": "client", "client_secret": "secret"}, create=True)
        stale_api = FakeCloudflare(); self.assertRaisesRegex(access.AccessError, "stale", access.provision, self.plan, self.desired(), stale_api, stale_state, stale_secret)
        stale_secret.unlink(); stale_secret.symlink_to(stale / "missing"); self.assertRaises(access.AccessError, access.provision, self.plan, self.desired(), stale_api, stale_state, stale_secret)
        self.assertEqual(stale_api.created, [])
        for field in ("enabled", "previews_enabled"):
            unsafe = FakeCloudflare(); unsafe.subdomain[field] = True
            with self.subTest(field=field): self.assertRaisesRegex(access.AccessError, "both", access.provision, self.plan, self.desired(), unsafe, stale / f"unsafe-{field}.json", stale / f"unsafe-secret-{field}.json")
            self.assertEqual(unsafe.created, [])
        cases = [({**self.plan, "commands": ["delete"]}, self.config),
                 ({**self.plan, "intended": {**self.plan["intended"], "target_worker": {"name": "x", "workers_dev": True}}}, self.config),
                 ({**self.plan, "intended": {**self.plan["intended"], "preview": {**self.plan["intended"]["preview"], "preview_domain": "example.com"}}}, self.config),
                 (self.plan, {**self.config, "reviewer_emails": [1]}),
                 (self.plan, {**self.config, "preview_urls": True}),
                 (self.plan, {**self.config, "any_valid_service_token": True})]
        for plan, config in cases:
            with self.subTest(config=config):
                with self.assertRaises(access.AccessError): access.validate(plan, config)
if __name__ == "__main__": unittest.main()
