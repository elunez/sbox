"""Realm2 管理脚本的本地隔离回归，不访问网络或 systemd。"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "realm.sh"
SOURCE = SCRIPT.read_text()


def bash(code, env=None):
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n{code}"],
        text=True,
        capture_output=True,
        env=merged,
        timeout=15,
    )


class RealmScriptTests(unittest.TestCase):
    def test_manager_version_starts_at_1_0_1(self):
        self.assertIn('SCRIPT_VERSION="1.0.1"', SOURCE)

    def test_bash_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prompts_stay_on_the_same_line(self):
        self.assertNotRegex(SOURCE, r'read_input\s+\w+\s+"[^"]*\n[^"]*"')
        self.assertNotRegex(SOURCE, r'read\s+-[^\n]*-p\s+"[^"]*\n[^"]*"')
        self.assertIn('read_input choice "请选择 [0-11]："', SOURCE)

    def test_target_mapping_uses_portable_musl_assets(self):
        cases = {
            "x86_64": "x86_64-unknown-linux-musl",
            "amd64": "x86_64-unknown-linux-musl",
            "aarch64": "aarch64-unknown-linux-musl",
            "arm64": "aarch64-unknown-linux-musl",
            "armv7l": "armv7-unknown-linux-musleabihf",
        }
        for machine, expected in cases.items():
            with self.subTest(machine=machine):
                result = bash("detect_target", {"REALM_MACHINE_OVERRIDE": machine})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_release_metadata_requires_official_url_and_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "release.json"
            digest = "a" * 64
            asset = "realm-x86_64-unknown-linux-musl.tar.gz"
            metadata.write_text(json.dumps({
                "tag_name": "v2.9.6",
                "assets": [{
                    "name": asset,
                    "browser_download_url": (
                        "https://github.com/zhboner/realm/releases/download/v2.9.6/" + asset
                    ),
                    "digest": "sha256:" + digest,
                }],
            }))
            result = bash(
                f"select_release_info {shlex.quote(str(metadata))} {shlex.quote(asset)}"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.strip(),
                "|".join((
                    "v2.9.6",
                    "https://github.com/zhboner/realm/releases/download/v2.9.6/" + asset,
                    digest,
                )),
            )

            data = json.loads(metadata.read_text())
            data["assets"][0]["browser_download_url"] = "https://example.com/realm.tar.gz"
            metadata.write_text(json.dumps(data))
            rejected = bash(
                f"select_release_info {shlex.quote(str(metadata))} {shlex.quote(asset)}"
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("不是 zhboner/realm 官方 Release", rejected.stderr)

    def test_add_and_delete_last_rule_keep_valid_config(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            config = realm_dir / "config.json"
            env = {
                "REALM_DIR": str(realm_dir),
                "REALM_CONFIG": str(config),
                "REALM_BACKUP_DIR": str(realm_dir / "backups"),
            }
            result = bash(
                "create_default_config\n"
                "config_action add 0.0.0.0:15608 sg1.example:15606\n"
                "config_action delete 1\n"
                "config_action validate",
                env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(config.read_text())
            self.assertEqual(data["endpoints"], [])
            self.assertEqual(data["network"]["use_udp"], True)
            self.assertEqual(list(realm_dir.glob(".config.*.tmp")), [])

    def test_endpoint_edit_preserves_existing_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            realm_dir.mkdir()
            config = realm_dir / "config.json"
            original = {
                "log": {"level": "error"},
                "network": {"use_udp": True, "tcp_timeout": 123, "custom": "keep"},
                "endpoints": [{"listen": "0.0.0.0:1000", "remote": "a.example:2000"}],
            }
            config.write_text(json.dumps(original))
            env = {"REALM_DIR": str(realm_dir), "REALM_CONFIG": str(config)}
            result = bash("config_action add 0.0.0.0:1001 b.example:2001", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            updated = json.loads(config.read_text())
            self.assertEqual(updated["network"], original["network"])
            self.assertEqual(updated["log"], original["log"])
            self.assertEqual(len(updated["endpoints"]), 2)

    def test_duplicate_listen_is_rejected_without_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            config = realm_dir / "config.json"
            env = {"REALM_DIR": str(realm_dir), "REALM_CONFIG": str(config)}
            first = bash(
                "create_default_config\nconfig_action add 0.0.0.0:15606 tw.example:15606",
                env,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            before = config.read_bytes()
            duplicate = bash("config_action add 0.0.0.0:15606 sg.example:15606", env)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertEqual(config.read_bytes(), before)

    def test_service_unit_avoids_empty_pid_execstop_and_restart_loop(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Path(directory) / "realm2.service"
            realm_dir = Path(directory) / "realm2"
            env = {
                "REALM_DIR": str(realm_dir),
                "REALM_BIN": str(realm_dir / "realm2"),
                "REALM_CONFIG": str(realm_dir / "config.json"),
                "REALM_SERVICE_FILE": str(service),
            }
            result = bash("write_service_unit", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = service.read_text()
            self.assertIn("Restart=on-failure", unit)
            self.assertNotIn("Restart=always", unit)
            self.assertNotIn("ExecStop=", unit)
            self.assertIn(str(realm_dir / "realm2"), unit)

    def test_port_and_ipv6_format_validation(self):
        result = bash(
            "valid_port 1 && valid_port 65535 && ! valid_port 65536 && "
            "format_host_port 2001:db8::1 443"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[2001:db8::1]:443")


if __name__ == "__main__":
    unittest.main()
