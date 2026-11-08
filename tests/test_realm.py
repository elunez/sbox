"""Realm2 极简安装脚本的本地隔离回归，不访问网络或真实服务。"""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "realm.sh"
SOURCE = SCRIPT.read_text()


def bash(code, env=None):
    merged = os.environ.copy()
    merged["INIT_SYSTEM"] = "systemd"
    if env:
        merged.update(env)
    return subprocess.run(
        ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n{code}"],
        text=True,
        capture_output=True,
        env=merged,
        timeout=15,
    )


class RealmMinimalInstallerTests(unittest.TestCase):
    def test_bash_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_version_is_1_0_7(self):
        self.assertIn('SCRIPT_VERSION="1.0.7"', SOURCE)
        self.assertIn('REALM_VERSION="v2.9.6"', SOURCE)

    def test_no_pf_jq_or_python_dependency(self):
        self.assertNotIn('PF_COMMAND="${PF_COMMAND:-', SOURCE)
        self.assertNotIn("install_manager_command", SOURCE)
        self.assertNotRegex(SOURCE, r"\bjq\b")
        self.assertNotIn("python3", SOURCE)
        self.assertNotRegex(SOURCE, r"\bpython\b")
        self.assertIn('OLD_PF_COMMAND="${OLD_PF_COMMAND:-/usr/local/bin/pf}"', SOURCE)

    def test_dependency_commands_are_minimal(self):
        self.assertIn(
            "apk add --no-cache bash curl ca-certificates tar coreutils openrc",
            SOURCE,
        )
        self.assertNotIn("apt-get install -y curl ca-certificates tar jq", SOURCE)
        self.assertNotIn("apt-get install -y curl ca-certificates tar python3", SOURCE)

    def test_release_assets_and_hashes_are_pinned(self):
        cases = {
            "x86_64": (
                "realm-x86_64-unknown-linux-musl.tar.gz",
                "b1cc335547bea8bb2a88178bef12ec7f2363e36200e7ea1d4e1e67627929bf65",
            ),
            "aarch64": (
                "realm-aarch64-unknown-linux-musl.tar.gz",
                "f4c0318dd86854da483dcb7645b4f39cae2cc3f91c688fef969d53220b949488",
            ),
            "armv7l": (
                "realm-armv7-unknown-linux-musleabihf.tar.gz",
                "ceedaf367c78f911eac227b2b88b3132f964d05a8b71f7a6a7e429dc78ec1862",
            ),
        }
        for machine, expected in cases.items():
            with self.subTest(machine=machine):
                result = bash(
                    "detect_release_asset && printf '%s|%s|%s' "
                    '"$REALM_ASSET" "$REALM_SHA256" "$REALM_DOWNLOAD_URL"',
                    {"REALM_MACHINE_OVERRIDE": machine},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                asset, digest, url = result.stdout.split("|")
                self.assertEqual((asset, digest), expected)
                self.assertEqual(
                    url,
                    f"https://github.com/zhboner/realm/releases/download/v2.9.6/{asset}",
                )

    def test_version_comparison_prevents_core_downgrade(self):
        newer = bash("version_is_newer 2.10.0 2.9.6")
        older = bash("version_is_newer 2.9.5 2.9.6")
        equal = bash("version_is_newer 2.9.6 2.9.6")
        self.assertEqual(newer.returncode, 0, newer.stderr)
        self.assertNotEqual(older.returncode, 0)
        self.assertNotEqual(equal.returncode, 0)

    def test_config_template_is_a_complete_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            env = {
                "REALM_DIR": str(realm_dir),
                "REALM_CONFIG_DIR": str(realm_dir / "config"),
                "REALM_RULE_DIR": str(realm_dir / "config" / "rules"),
                "REALM_LEGACY_CONFIG": str(realm_dir / "config.json"),
            }
            result = bash("prepare_config_dir", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            example = (realm_dir / "config" / "rules" / ".rule.example.toml").read_text()
            self.assertFalse((realm_dir / "config" / "00-global.toml").exists())
            self.assertIn("use_udp = true", example)
            self.assertIn("tcp_timeout = 10", example)
            self.assertIn("[[endpoints]]", example)
            has_rules = bash("prepare_config_dir && has_rules", env)
            self.assertNotEqual(has_rules.returncode, 0)

    def test_v1_0_6_config_is_migrated(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            rule_dir = realm_dir / "config" / "rules"
            rule_dir.mkdir(parents=True)
            global_file = realm_dir / "config" / "00-global.toml"
            global_file.write_text('[network]\nuse_udp = true\n')
            rule_file = rule_dir / "15608.toml"
            rule_file.write_text(
                '[[endpoints]]\nlisten = "0.0.0.0:15608"\nremote = "sg.example:15606"\n'
            )
            env = {
                "REALM_DIR": str(realm_dir),
                "REALM_CONFIG_DIR": str(realm_dir / "config"),
                "REALM_RULE_DIR": str(rule_dir),
                "REALM_LEGACY_CONFIG": str(realm_dir / "config.json"),
            }
            result = bash("prepare_config_dir", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(global_file.exists())
            self.assertEqual(
                len(list((realm_dir / "config").glob(".00-global.toml.v1.0.6.disabled.*"))),
                1,
            )
            migrated = rule_file.read_text()
            self.assertIn("[network]", migrated)
            self.assertIn("use_udp = true", migrated)
            self.assertIn("[[endpoints]]", migrated)

    def test_visible_toml_rule_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            rule_dir = Path(directory) / "rules"
            rule_dir.mkdir()
            (rule_dir / ".rule.example.toml").write_text("[[endpoints]]\n")
            (rule_dir / "15608.toml").write_text("[[endpoints]]\n")
            result = bash(
                "has_rules",
                {
                    "REALM_RULE_DIR": str(rule_dir),
                    "REALM_LEGACY_CONFIG": str(Path(directory) / "missing.json"),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_json_config_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            realm_dir = Path(directory) / "realm2"
            realm_dir.mkdir()
            legacy = realm_dir / "config.json"
            legacy.write_text('{"endpoints":[]}\n')
            result = bash(
                "active_config_path",
                {
                    "REALM_DIR": str(realm_dir),
                    "REALM_CONFIG_DIR": str(realm_dir / "config"),
                    "REALM_RULE_DIR": str(realm_dir / "config" / "rules"),
                    "REALM_LEGACY_CONFIG": str(legacy),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(legacy))
            self.assertEqual(legacy.read_text(), '{"endpoints":[]}\n')

    def test_empty_legacy_json_is_not_treated_as_a_rule(self):
        with tempfile.TemporaryDirectory() as directory:
            legacy = Path(directory) / "config.json"
            legacy.write_text('{"endpoints":[]}\n')
            result = bash(
                "has_rules",
                {
                    "REALM_LEGACY_CONFIG": str(legacy),
                    "REALM_RULE_DIR": str(Path(directory) / "rules"),
                },
            )
            self.assertNotEqual(result.returncode, 0)

    def test_systemd_service_loads_config_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = root / "realm2.service"
            config_dir = root / "config"
            result = bash(
                "write_service_file",
                {
                    "INIT_SYSTEM": "systemd",
                    "REALM_BIN": str(root / "realm2"),
                    "REALM_CONFIG_DIR": str(config_dir),
                    "REALM_RULE_DIR": str(config_dir / "rules"),
                    "REALM_LEGACY_CONFIG": str(root / "missing.json"),
                    "REALM_SERVICE_FILE": str(service),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = service.read_text()
            self.assertIn(f"ExecStart={root / 'realm2'} -c {config_dir}", unit)
            self.assertIn("Restart=on-failure", unit)
            self.assertIn("StartLimitBurst=5", unit)
            self.assertNotIn("ExecStop=", unit)

    def test_openrc_service_uses_supervise_daemon(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = root / "init.d" / "realm2"
            service.parent.mkdir()
            config_dir = root / "config"
            result = bash(
                "write_service_file",
                {
                    "INIT_SYSTEM": "openrc",
                    "REALM_BIN": str(root / "realm2"),
                    "REALM_CONFIG_DIR": str(config_dir),
                    "REALM_RULE_DIR": str(config_dir / "rules"),
                    "REALM_LEGACY_CONFIG": str(root / "missing.json"),
                    "REALM_SERVICE_FILE": str(service),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = service.read_text()
            self.assertTrue(unit.startswith("#!/sbin/openrc-run\n"))
            self.assertIn('supervisor="supervise-daemon"', unit)
            self.assertTrue(os.access(service, os.X_OK))

    def test_rule_input_is_kept_on_same_line(self):
        self.assertIn('read_input listen_port "本地监听端口 [1-65535]："', SOURCE)
        self.assertIn('read_input remote_host "落地域名或 IP："', SOURCE)
        self.assertNotRegex(SOURCE, r'read_input\s+\w+\s+"[^"]*\n[^"]*"')

    def test_help_exposes_only_minimal_commands(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "--help"], text=True, capture_output=True, timeout=15
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bash realm.sh install", result.stdout)
        self.assertNotIn("pf update", result.stdout)
        self.assertNotIn("添加转发规则", result.stdout)


if __name__ == "__main__":
    unittest.main()
