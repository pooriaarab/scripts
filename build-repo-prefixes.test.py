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

    def run_main(self, repos, registry):
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / "build-repo-prefixes.py").write_text(
                (HERE / "build-repo-prefixes.py").read_text())
            (directory / "repo-prefixes.json").write_text(json.dumps(registry, indent=2))
            m = load(directory)
            m.gh_list = lambda: [
                {"name": r, "isArchived": False, "isFork": False, "diskUsage": 100}
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
        # Every one should be a prefix of the squashed name or of its initials,
        # not a letter the alphabetic fallback picked out of the air.
        for name in newcomers:
            prefix = out[name]
            squashed = name.replace("-", "")
            initials = "v" + "".join(c for c in name[4:5])
            with self.subTest(name=name):
                self.assertTrue(
                    squashed.startswith(prefix) or prefix.startswith(initials),
                    f"{name} -> {prefix!r} came from the fallback, not the name",
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


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
