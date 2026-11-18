#!/usr/bin/env python3
"""Hermetic tests for tools/install_zed_extension.sh.

All runs use a throwaway temp root with its own HOME / XDG_DATA_HOME /
ZED_DATA_DIR. The installer copies prebuilt artifacts into the (temporary)
Zed data dir, so the real user data and the repository are never modified.
"""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tools" / "install_zed_extension.sh"
EXT = REPO / "zed-extension"


def manifest_rev() -> str:
    with open(EXT / "extension.toml", "rb") as f:
        return tomllib.load(f)["grammars"]["basic_plus"]["rev"]


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="zed-installer-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.xdg = self.tmp / "xdg"
        self.override = self.tmp / "override"
        self.home.mkdir()

    def env(self, **extra):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.xdg),
        }
        env.pop("ZED_DATA_DIR", None)
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def run_installer(self, **extra):
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env=self.env(**extra),
            cwd=str(self.tmp),
            capture_output=True,
            text=True,
            timeout=120,
        )

    def read_index(self, data_dir: Path):
        with open(data_dir / "extensions" / "index.json", encoding="utf-8") as f:
            return json.load(f)

    def lock_lib_version(self) -> str:
        with open(EXT / "Cargo.lock", "rb") as f:
            lock = tomllib.load(f)
        versions = [
            p["version"] for p in lock["package"]
            if isinstance(p, dict) and p.get("name") == "zed_extension_api"
        ]
        self.assertEqual(len(versions), 1)
        return versions[0]

    def write_index(self, data_dir: Path, data):
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True, exist_ok=True)
        (ext_dir / "index.json").write_text(json.dumps(data), encoding="utf-8")

    def assert_no_repo_writes(self):
        # Nothing under the repository's zed-extension/ may change.
        for name in ("extension.toml", "tasks.json"):
            self.assertTrue((EXT / name).is_file())

    def test_xdg_data_home_route(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        data_dir = self.xdg / "zed"
        self.assertTrue((data_dir / "extensions/index.json").is_file())
        dst = data_dir / "extensions/installed/basic_plus"
        self.assertTrue((dst / "extension.wasm").is_file())
        self.assertTrue((dst / "grammars/basic_plus.wasm").is_file())
        self.assertTrue((dst / "languages/basic_plus/config.toml").is_file())
        # HOME fallback must not have been used.
        self.assertFalse((self.home / ".local/share/zed").exists())
        self.assert_no_repo_writes()

    def test_home_fallback_without_xdg(self):
        env = self.env()
        del env["XDG_DATA_HOME"]
        r = subprocess.run(
            ["bash", str(SCRIPT)], env=env, cwd=str(self.tmp),
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.home / ".local/share/zed/extensions/index.json").is_file())

    def test_zed_data_dir_override_precedence(self):
        r = self.run_installer(ZED_DATA_DIR=self.override)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.override / "extensions/index.json").is_file())
        self.assertFalse((self.xdg / "zed").exists())

    def test_rev_matches_manifest(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = self.read_index(self.xdg / "zed")
        got = data["extensions"]["basic_plus"]["manifest"]["grammars"]["basic_plus"]["rev"]
        self.assertEqual(got, manifest_rev())
        self.assertEqual(got, "76081a635ac2fa0dbb6d0727c043a996a599603d")

    def test_lib_version_is_complete_semver_from_cargo_lock(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        man = self.read_index(self.xdg / "zed")["extensions"]["basic_plus"]["manifest"]
        version = man["lib"]["version"]
        # Cargo.toml contains the range "0.7"; the index needs the resolved
        # full version (ABI of the prebuilt wasm), not the range.
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        self.assertEqual(version, self.lock_lib_version())
        self.assertEqual(version, "0.7.0")

    def test_existing_index_mode_is_preserved(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        index = ext_dir / "index.json"
        for mode in (0o644, 0o640, 0o600):
            with self.subTest(mode=oct(mode)):
                index.write_text(json.dumps({"extensions": {}}), encoding="utf-8")
                os.chmod(index, mode)
                r = self.run_installer()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(
                    stat.S_IMODE(index.stat().st_mode), mode,
                    f"index mode changed to {oct(stat.S_IMODE(index.stat().st_mode))}",
                )

    def test_new_index_mode_matches_umask(self):
        old_umask = os.umask(0o027)
        self.addCleanup(os.umask, old_umask)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        index = self.xdg / "zed/extensions/index.json"
        expected = 0o666 & ~0o027
        self.assertEqual(stat.S_IMODE(index.stat().st_mode), expected)

    def test_absolute_symlinked_index_preserved(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        managed = self.tmp / "managed"
        managed.mkdir()
        target = managed / "index.json"
        target.write_text(
            json.dumps({"extensions": {"other_ext": {"manifest": {"id": "other_ext"}}}}),
            encoding="utf-8",
        )
        os.chmod(target, 0o640)
        link = ext_dir / "index.json"
        link.symlink_to(target)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(target))
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
        data = json.loads(target.read_text(encoding="utf-8"))
        self.assertIn("other_ext", data["extensions"])
        self.assertIn("basic_plus", data["extensions"])
        self.assertTrue((managed / "index.json.bak").is_file())
        self.assertEqual(list(ext_dir.glob(".index.*")), [])

    def test_relative_symlinked_index_preserved(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        managed = self.tmp / "managed"
        managed.mkdir()
        target = managed / "index.json"
        target.write_text(json.dumps({"extensions": {}}), encoding="utf-8")
        os.chmod(target, 0o600)
        link = ext_dir / "index.json"
        rel_target = os.path.relpath(target, ext_dir)
        link.symlink_to(rel_target)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), rel_target)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertIn("basic_plus", json.loads(target.read_text())["extensions"])

    def test_chained_symlinked_index_preserved(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        managed = self.tmp / "managed"
        managed.mkdir()
        target = managed / "index.json"
        target.write_text(json.dumps({"extensions": {}}), encoding="utf-8")
        os.chmod(target, 0o644)
        links = self.tmp / "links"
        links.mkdir()
        middle = links / "middle.json"
        middle_rel = os.path.relpath(target, links)
        middle.symlink_to(middle_rel)
        link = ext_dir / "index.json"
        link_rel = os.path.relpath(middle, ext_dir)
        link.symlink_to(link_rel)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(link.is_symlink())
        self.assertTrue(middle.is_symlink())
        self.assertEqual(os.readlink(link), link_rel)
        self.assertEqual(os.readlink(middle), middle_rel)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
        self.assertIn("basic_plus", json.loads(target.read_text())["extensions"])

    def test_malformed_symlinked_target_fails_safe(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        managed = self.tmp / "managed"
        managed.mkdir()
        target = managed / "index.json"
        corrupt = '{"extensions": {"other_ext": '
        target.write_text(corrupt, encoding="utf-8")
        link = ext_dir / "index.json"
        link.symlink_to(target)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(target.read_text(encoding="utf-8"), corrupt)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(target))
        self.assertFalse((managed / "index.json.bak").exists())
        self.assertFalse((data_dir / "extensions/installed/basic_plus").exists())

    def test_dangling_index_symlink_fails_clear(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        missing = self.tmp / "missing" / "index.json"
        link = ext_dir / "index.json"
        link.symlink_to(missing)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        self.assertTrue(link.is_symlink())
        self.assertFalse(missing.exists())
        self.assertFalse((data_dir / "extensions/installed/basic_plus").exists())

    def test_missing_rev_fails_before_installed_copy(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        marker = {"extensions": {"keep_me": {"manifest": {"id": "keep_me"}}}}
        index = ext_dir / "index.json"
        index.write_text(json.dumps(marker), encoding="utf-8")
        src = self.tmp / "src"
        shutil.copytree(EXT, src / "zed-extension")
        manifest = src / "zed-extension/extension.toml"
        manifest.write_text(
            "\n".join(
                line for line in manifest.read_text(encoding="utf-8").splitlines()
                if not line.strip().startswith("rev =")
            ) + "\n",
            encoding="utf-8",
        )
        (src / "tools").mkdir()
        copied = src / "tools/install_zed_extension.sh"
        shutil.copy(SCRIPT, copied)
        r = subprocess.run(
            ["bash", str(copied)], env=self.env(), cwd=str(self.tmp),
            capture_output=True, text=True, timeout=120,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rev", r.stderr)
        self.assertEqual(json.loads(index.read_text(encoding="utf-8")), marker)
        self.assertFalse((data_dir / "extensions/installed/basic_plus").exists())

    def test_language_metadata_matches_manifest(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        man = self.read_index(self.xdg / "zed")["extensions"]["basic_plus"]["manifest"]
        with open(EXT / "extension.toml", "rb") as f:
            src = tomllib.load(f)
        self.assertEqual(man["id"], src["id"])
        self.assertEqual(man["version"], src["version"])
        self.assertEqual(
            man["languages"], list(src.get("languages") or ["languages/basic_plus"])
        )
        for server_id, server in (src.get("language_servers") or {}).items():
            self.assertIn(server_id, man["language_servers"])
            self.assertEqual(
                man["language_servers"][server_id]["languages"],
                list(server.get("languages") or []),
            )
        self.assertEqual(man["lib"]["kind"], "Rust")

    def test_preserves_unrelated_keys_and_extensions(self):
        data_dir = self.xdg / "zed"
        existing = {
            "extensions": {
                "other_ext": {
                    "manifest": {"id": "other_ext", "version": "9.9.9"},
                    "dev": False,
                }
            },
            "unrelated_top_level": {"keep": [1, 2, 3]},
        }
        self.write_index(data_dir, existing)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = self.read_index(data_dir)
        self.assertEqual(data["unrelated_top_level"], {"keep": [1, 2, 3]})
        self.assertIn("other_ext", data["extensions"])
        self.assertEqual(
            data["extensions"]["other_ext"],
            {"manifest": {"id": "other_ext", "version": "9.9.9"}, "dev": False},
        )
        self.assertIn("basic_plus", data["extensions"])
        self.assertTrue((data_dir / "extensions/index.json.bak").is_file())

    def test_malformed_existing_index_fails_safe(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        corrupt = '{"extensions": {"other_ext": '
        (ext_dir / "index.json").write_text(corrupt, encoding="utf-8")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((ext_dir / "index.json").read_text(encoding="utf-8"), corrupt)
        self.assertFalse((ext_dir / "index.json.bak").exists())

    def test_non_object_index_fails_safe(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        (ext_dir / "index.json").write_text("[1, 2, 3]", encoding="utf-8")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((ext_dir / "index.json").read_text(encoding="utf-8"), "[1, 2, 3]")

    def test_repeat_install_idempotent(self):
        r1 = self.run_installer()
        self.assertEqual(r1.returncode, 0, r1.stderr)
        data_dir = self.xdg / "zed"
        first = self.read_index(data_dir)
        r2 = self.run_installer()
        self.assertEqual(r2.returncode, 0, r2.stderr)
        second = self.read_index(data_dir)
        self.assertEqual(first, second)
        # Backup is refreshed from the first install but content is equivalent.
        self.assertTrue((data_dir / "extensions/index.json.bak").is_file())
        with open(data_dir / "extensions/index.json.bak", encoding="utf-8") as f:
            backup = json.load(f)
        self.assertEqual(backup["extensions"]["basic_plus"], second["extensions"]["basic_plus"])

    def test_missing_prebuilt_fails_without_index_change(self):
        data_dir = self.xdg / "zed"
        ext_dir = data_dir / "extensions"
        ext_dir.mkdir(parents=True)
        marker = {"extensions": {"keep_me": {"manifest": {"id": "keep_me"}}}}
        (ext_dir / "index.json").write_text(json.dumps(marker), encoding="utf-8")
        src = self.tmp / "src"
        shutil.copytree(EXT, src / "zed-extension")
        (src / "zed-extension/prebuilt/grammars/basic_plus.wasm").unlink()
        (src / "tools").mkdir(parents=True)
        # Run a copy whose ROOT resolves to the temp source tree (missing wasm).
        copied = src / "tools/install_zed_extension.sh"
        shutil.copy(SCRIPT, copied)
        r = subprocess.run(
            ["bash", str(copied)], env=self.env(), cwd=str(self.tmp),
            capture_output=True, text=True, timeout=120,
        )
        self.assertNotEqual(r.returncode, 0)
        with open(ext_dir / "index.json", encoding="utf-8") as f:
            self.assertEqual(json.load(f), marker)


class CorpusGateTest(unittest.TestCase):
    """Fail-closed behaviour of tools/grammar/check_corpus.sh."""

    SCRIPT = REPO / "tools" / "grammar" / "check_corpus.sh"
    GOOD = REPO / "tests" / "corpus" / "Time" / "Time.bp"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="corpus-gate-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def run_gate(self, *args, cwd=None, cli=None):
        env = dict(os.environ)
        env.pop("TREE_SITTER_CLI", None)
        if cli is not None:
            env["TREE_SITTER_CLI"] = cli
        return subprocess.run(
            ["bash", str(self.SCRIPT), *[str(a) for a in args]],
            cwd=str(cwd or self.tmp),
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )

    def test_false_cli_fails_closed(self):
        r = self.run_gate(self.GOOD, cli="/bin/false")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("CLI failures: 1", r.stdout)

    def test_missing_cli_fails_closed(self):
        r = self.run_gate(self.GOOD, cli="/nonexistent/tree-sitter-binary")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)

    def test_missing_file_is_usage_error(self):
        r = self.run_gate(self.tmp / "absent.bp")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_directory_argument_is_usage_error(self):
        d = self.tmp / "dir.bp"
        d.mkdir()
        r = self.run_gate(d)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_missing_grammar_dir_fails_closed(self):
        root = self.tmp / "repo"
        (root / "tools/grammar").mkdir(parents=True)
        copied = root / "tools/grammar/check_corpus.sh"
        shutil.copy(self.SCRIPT, copied)
        target = self.tmp / "a.bp"
        target.write_text("x = 1\n", encoding="utf-8")
        r = subprocess.run(
            ["bash", str(copied), str(target)],
            cwd=str(self.tmp), capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_parse_error_file_nonzero(self):
        bad = self.tmp / "bad.bp"
        bad.write_text("If True Then\nEnd If\n", encoding="utf-8")
        r = self.run_gate(bad)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_clean_file_and_relative_arg_from_caller_cwd(self):
        rel = os.path.relpath(self.GOOD, self.tmp)
        r = self.run_gate(rel)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("clean: 1", r.stdout)

    def test_wrong_cwd_false_green_is_gone(self):
        # A repo-relative argument resolved from an unrelated cwd does not exist:
        # the old gate suppressed stderr and reported rc0/50 clean.
        r = self.run_gate("tests/corpus/Time/Time.bp", cwd=self.tmp)
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertNotIn("clean: 1", r.stdout)

    def test_grammar_dir_as_cwd_does_not_false_green(self):
        r = self.run_gate("tests/corpus/Time/Time.bp", cwd=REPO / "grammar")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)

    def test_any_cwd_works_with_absolute_arg(self):
        r = self.run_gate(self.GOOD, cwd=self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
