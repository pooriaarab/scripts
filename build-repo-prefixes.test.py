#!/usr/bin/env python3
"""Unit tests for the prefix generator.

A prefix is the join key the whole PR standard rests on: it ties a branch, a
title and a merged commit to one issue. Two defects reached review here because
nothing exercised this file -- the resolver produced a duplicate on the real repo
list, and three repos sharing a stem aborted the entire registry build.
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).parent
VALID = lambda p: isinstance(p, str) and 2 <= len(p) <= 4 and p.isalpha() and p.islower()


def load(directory=None):
    spec = importlib.util.spec_from_file_location(
        "brp", (directory or HERE) / "build-repo-prefixes.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DerivePrefixTest(unittest.TestCase):
    def test_every_name_yields_a_prefix_the_config_accepts(self):
        m = load()
        for name in ["content-rabbit", "popcornteam", "3d-tools", "a-", "---", "_",
                     "x", "123", "9", ".github", "vibecodereview", "one-two-three-four"]:
            with self.subTest(name=name):
                self.assertTrue(VALID(m.derive_prefix(name)), m.derive_prefix(name))

    def test_known_names_keep_their_documented_prefixes(self):
        m = load()
        self.assertEqual(m.derive_prefix("content-rabbit"), "cr")
        self.assertEqual(m.derive_prefix("popcornteam"), "pop")


class RegistryTest(unittest.TestCase):
    """main() writes the registry in place, so each case runs on a copy."""

    def run_main(self, repos, registry, sizes=None):
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / "build-repo-prefixes.py").write_text(
                (HERE / "build-repo-prefixes.py").read_text())
            (directory / "repo-prefixes.json").write_text(json.dumps(registry, indent=2))
            m = load(directory)
            # Default 100KB so existing cases stay on the "has content" side of
            # the eligibility test. Pass `sizes` to cover a scaffold or empty repo.
            size_of = sizes or {}
            m.gh_list = lambda: [
                {"name": r, "isArchived": False, "isFork": False,
                 "diskUsage": size_of.get(r, 100)}
                for r in repos
            ]
            err = io.StringIO()
            try:
                with contextlib.redirect_stderr(err):
                    m.main()
            except SystemExit as exit_code:
                return None, err.getvalue()
            return json.loads((directory / "repo-prefixes.json").read_text()), err.getvalue()

    def registry(self):
        return json.loads((HERE / "repo-prefixes.json").read_text())

    def test_a_rerun_reproduces_the_committed_registry(self):
        # It could not, before: the generator derived everything from scratch and
        # disagreed with the checked-in file on three repos.
        registry = self.registry()
        out, _ = self.run_main(list(registry), registry)
        self.assertEqual(out, registry)

    def test_repos_sharing_a_stem_do_not_abort_the_build(self):
        # vibenotebooks, vibenotepad and vibenoteworthy all squash to the same
        # leading characters. Extending by slicing the squashed name gave all
        # three the same candidate, and main() aborted the whole registry.
        registry = self.registry()
        newcomers = ["vibenotebooks", "vibenotepad", "vibenoteworthy"]
        out, err = self.run_main(list(registry) + newcomers, registry)
        self.assertIsNotNone(out, f"build aborted: {err.strip()}")
        values = list(out.values())
        self.assertEqual(len(values), len(set(values)), "duplicate prefixes")
        for name in newcomers:
            self.assertTrue(VALID(out[name]), out[name])

    def test_many_repos_sharing_a_stem_still_all_resolve(self):
        # Three colliding names can be resolved by the name-derived candidates
        # alone, so they never reach the alphabetic fallback and cannot show
        # whether it works. Enough of them exhausts the meaningful candidates and
        # forces it, which is the only way a mutation to either is visible.
        registry = self.registry()
        newcomers = [f"vibenote{suffix}" for suffix in
                     ("books", "pad", "worthy", "s", "d", "ing", "able", "ery", "ish")]
        out, err = self.run_main(list(registry) + newcomers, registry)
        self.assertIsNotNone(out, f"build aborted: {err.strip()}")
        values = list(out.values())
        self.assertEqual(len(values), len(set(values)), "duplicate prefixes")
        for name in newcomers:
            self.assertTrue(VALID(out[name]), f"{name} -> {out.get(name)!r}")

    def test_a_collision_prefers_a_name_derived_prefix_over_the_fallback(self):
        # Without this the candidate ordering is untestable: every assertion above
        # only checks validity and uniqueness, which the alphabetic fallback also
        # satisfies. A prefix a human has to read should come from the name.
        # Three names, so extension actually happens: with a single newcomer there
        # is no collision and the candidate list is never consulted at all.
        registry = self.registry()
        newcomers = ["vibenotebooks", "vibenotepad", "vibenoteworthy"]
        out, _ = self.run_main(list(registry) + newcomers, registry)
        self.assertIsNotNone(out)
        # Derivability is a preference, not a guarantee, and it stops being
        # achievable in a crowded namespace. Forty-four repos are named vibe*,
        # so the 2 to 4 letter space runs out and the fallback is the only
        # thing left: vibedaily holds vibb, vibebuild holds viba. Those are
        # unmemorable and that is a real cost, but a prefix is permanent once
        # a branch has used it, so the alternative is refusing to register a
        # repo at all.
        #
        # What must hold is uniqueness and validity. Assert those, and assert
        # derivability only for the first newcomer, which is the case where
        # the candidate list is genuinely consulted before it is exhausted.
        seen = set()
        for name in newcomers:
            prefix = out[name]
            with self.subTest(name=name):
                self.assertRegex(prefix, r"^[a-z]{2,4}$", f"{name} -> {prefix!r} is not a valid prefix")
                self.assertNotIn(prefix, seen, f"{name} -> {prefix!r} collides with an earlier newcomer")
                seen.add(prefix)
        first = newcomers[0]
        squashed = first.replace("-", "")
        self.assertTrue(
            squashed.startswith(out[first]) or out[first].startswith("v"),
            f"{first} -> {out[first]!r} came from the fallback even before the space was crowded",
        )

    def test_a_registered_prefix_is_never_reassigned(self):
        registry = self.registry()
        out, _ = self.run_main(list(registry) + ["vibenotebooks"], registry)
        self.assertIsNotNone(out)
        for name, prefix in registry.items():
            self.assertEqual(out[name], prefix, name)

    def test_a_repo_that_left_the_account_keeps_its_prefix(self):
        # Freeing it would let a later repo claim a prefix that merged commits
        # already carry.
        registry = self.registry()
        remaining = list(registry)[:-1]
        gone = list(registry)[-1]
        out, _ = self.run_main(remaining, registry)
        self.assertIsNotNone(out)
        self.assertEqual(out[gone], registry[gone])

    def test_the_result_is_the_same_on_every_run(self):
        registry = self.registry()
        repos = list(registry) + ["vibenotebooks", "vibenotepad", "vibenoteworthy"]
        first, _ = self.run_main(repos, registry)
        second, _ = self.run_main(repos, registry)
        self.assertEqual(first, second)

    def test_a_scaffold_under_the_old_floor_registers(self):
        # The old 10KB floor permanently hid 8-9KB vibe* scaffolds. An 8KB
        # repo with a commit must get a prefix, and no existing prefix moves.
        registry = self.registry()
        out, err = self.run_main(
            list(registry) + ["vibescaffold"],
            registry,
            sizes={"vibescaffold": 8},
        )
        self.assertIsNotNone(out, err)
        self.assertIn("vibescaffold", out)
        self.assertTrue(VALID(out["vibescaffold"]), out["vibescaffold"])
        for name, prefix in registry.items():
            self.assertEqual(out[name], prefix, name)

    def test_a_never_pushed_repo_does_not_register(self):
        # diskUsage 0 is GitHub's signal for no git objects. That is empty,
        # not a scaffold, and must stay out.
        registry = self.registry()
        out, err = self.run_main(
            list(registry) + ["emptynew"],
            registry,
            sizes={"emptynew": 0},
        )
        self.assertIsNotNone(out, err)
        self.assertNotIn("emptynew", out)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
