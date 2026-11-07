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
    merged["REALM_SKIP_SUDO"] = "1"
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


class RealmScriptTests(unittest.TestCase):
    def test_manager_version_is_1_0_5(self):
        self.assertIn('SCRIPT_VERSION="1.0.5"', SOURCE)

    def test_deployed_script_has_no_python_dependency(self):
        self.assertNotIn("python3", SOURCE)
        self.assertNotRegex(SOURCE, r"\bpython\b")
        self.assertIn("jq", SOURCE)

    def test_bash_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prompts_stay_on_the_same_line(self):
        self.assertNotRegex(SOURCE, r'read_input\s+\w+\s+"[^"]*\n[^"]*"')
        self.assertNotRegex(SOURCE, r'read\s+-[^\n]*-p\s+"[^"]*\n[^"]*"')
        self.assertIn('read_input choice "请选择 [0-12]："', SOURCE)

    def test_pf_update_routes_to_manager_update_not_core_update(self):
        result = bash(
            "update_manager_script() { printf 'manager-update\\n'; }\n"
            "install_latest() { printf 'core-update\\n'; }\n"
            "main update\n"
            "main install"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["manager-update", "core-update"])

    def test_install_manager_command_creates_executable_pf(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bin" / "pf"
            result = bash("install_manager_command", {"PF_COMMAND": str(target)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(target.exists())
            self.assertTrue(os.access(target, os.X_OK))
            self.assertEqual(target.read_text(), SOURCE)

    def test_core_install_creates_pf_before_release_download(self):
        start = SOURCE.index("install_latest() {")
        end = SOURCE.index("\nvalid_port() {", start)
        install_function = SOURCE[start:end]
        self.assertLess(
            install_function.index('install_manager_command "$SCRIPT_SOURCE"'),
            install_function.index("target=$(detect_target)"),
        )

    def test_manager_version_comparison_uses_numeric_parts(self):
        newer = bash("manager_version_is_newer 1.1.0 1.0.9")
        older = bash("manager_version_is_newer 1.0.9 1.1.0")
        equal = bash("manager_version_is_newer 1.0.5 1.0.5")
        self.assertEqual(newer.returncode, 0, newer.stderr)
        self.assertNotEqual(older.returncode, 0)
        self.assertNotEqual(equal.returncode, 0)

    def test_manager_update_validates_and_atomically_installs_newer_script(self):
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory) / "remote-realm.sh"
            target = Path(directory) / "bin" / "pf"
            remote.write_text(SOURCE.replace(
                'SCRIPT_VERSION="1.0.5"', 'SCRIPT_VERSION="1.0.6"', 1
            ))
            code = r'''
require_root() { return 0; }
curl() {
    local output=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) output=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    cp "$REMOTE_SCRIPT" "$output"
}
update_manager_script
'''
            result = bash(code, {
                "REMOTE_SCRIPT": str(remote),
                "PF_COMMAND": str(target),
                "SCRIPT_UPDATE_URL": "https://example.invalid/realm.sh",
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("v1.0.5 -> v1.0.6", result.stdout)
            self.assertIn('SCRIPT_VERSION="1.0.6"', target.read_text())
            self.assertTrue(os.access(target, os.X_OK))

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

    def test_openrc_service_uses_supervise_daemon_and_is_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            service = Path(directory) / "init.d" / "realm2"
            service.parent.mkdir()
            realm_dir = Path(directory) / "realm2"
            env = {
                "INIT_SYSTEM": "openrc",
                "REALM_DIR": str(realm_dir),
                "REALM_BIN": str(realm_dir / "realm2"),
                "REALM_CONFIG": str(realm_dir / "config.json"),
                "REALM_SERVICE_FILE": str(service),
            }
            result = bash("write_service_unit", env)
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = service.read_text()
            self.assertTrue(unit.startswith("#!/sbin/openrc-run\n"))
            self.assertIn('supervisor="supervise-daemon"', unit)
            self.assertIn("respawn_max=5", unit)
            self.assertTrue(os.access(service, os.X_OK))

    def test_openrc_service_actions_use_rc_tools(self):
        result = bash(
            "RC_SERVICE_BIN=echo\n"
            "RC_UPDATE_BIN=echo\n"
            "service_enable\n"
            "service_start\n"
            "service_restart\n"
            "service_stop",
            {"INIT_SYSTEM": "openrc"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["realm2 start", "realm2 restart", "realm2 stop"],
        )

    def test_alpine_dependency_install_includes_bash_and_openrc(self):
        self.assertIn(
            "apk add --no-cache bash curl ca-certificates tar jq coreutils openrc",
            SOURCE,
        )

    def test_empty_config_disables_service_instead_of_enabling_it(self):
        result = bash(
            "service_daemon_reload() { :; }\n"
            "service_has_rules() { return 1; }\n"
            "service_enable() { printf 'enable\\n'; }\n"
            "service_disable() { printf 'disable\\n'; }\n"
            "restart_for_config"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disable", result.stdout)
        self.assertNotIn("enable", result.stdout)

    def test_port_and_ipv6_format_validation(self):
        result = bash(
            "valid_port 1 && valid_port 65535 && ! valid_port 65536 && "
            "format_host_port 2001:db8::1 443"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "[2001:db8::1]:443")


if __name__ == "__main__":
    unittest.main()
