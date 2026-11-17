"""REALITY 时间校验隔离回归：仅临时文件，模拟核心与服务，不访问真实配置或网络。"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_sbox import SOURCE, bash
from test_sbox_protocols import nodes


class RealityTimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state.json"
        self.config = self.root / "config.json"
        self.env = dict(os.environ, STATE_DIR=str(self.root), STATE_FILE=str(self.state),
                        CONFIG_FILE=str(self.config), PADDING_CONF_FILE=str(self.root / "padding.conf"))
        self.node = next(node for node in nodes() if node["protocol"] == "vless-reality")

    def save(self, value=None, present=False):
        node = json.loads(json.dumps(self.node))
        if present:
            node["reality"]["max_time_difference"] = value
        self.state.write_text(json.dumps({"nodes": [node]}))
        return node

    def test_schema_migration_only_defaults_missing_reality_fields(self):
        mixed = []
        for i, value in enumerate((None, "30s", "0s", "", None)):
            node = json.loads(json.dumps(self.node))
            node["port"] += i
            if i:
                node["reality"]["max_time_difference"] = value
            mixed.append(node)
        mixed.append(nodes()[0])
        self.state.write_text(json.dumps({"nodes": mixed}))
        result = bash("ensure_state_schema\nensure_state_schema", self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads(self.state.read_text())["nodes"]
        self.assertEqual([node["reality"]["max_time_difference"] for node in saved[:5]],
                         ["1m", "30s", "0s", "", None])
        self.assertNotIn("reality", saved[-1])
        for old, new in zip(mixed[:5], saved):
            self.assertEqual(new["uuid"], old["uuid"])
            for key in ("private_key", "public_key", "short_id", "handshake_server"):
                self.assertEqual(new["reality"][key], old["reality"][key])

    def test_generation_defaults_overrides_and_invalid_state(self):
        for value, present, valid in ((None, False, True), ("1m", True, True), ("30s", True, True),
                                     ("2m30s", True, True), ("0s", True, True), ("", True, True),
                                     (None, True, False), (0, True, False), (False, True, False),
                                     ("-1m", True, False), ("bad", True, False)):
            with self.subTest(value=value, present=present):
                node = self.save(value, present)
                self.config.write_text("unchanged")
                result = bash(f'generate_config_from_state {shlex.quote(str(self.config))}', self.env)
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                if valid:
                    config = json.loads(self.config.read_text())
                    self.assertEqual(config["inbounds"][0]["tls"]["reality"]["max_time_difference"],
                                     value if present else "1m")
                    client = bash(f'generate_client_outbound_json {shlex.quote(json.dumps(node))}')
                    self.assertEqual(client.returncode, 0, client.stderr)
                    self.assertNotIn("max_time_difference", client.stdout)
                    self.assertNotIn("max_time_difference", json.dumps(config["outbounds"]))
                else:
                    self.assertEqual(self.config.read_text(), "unchanged")

    def test_collection_cli_and_reconfiguration_preserve_custom_values(self):
        for value, option, expected in ((None, "", "1m"), ("30s", "", "30s"),
                                        ("0s", "", "0s"), ("", "", ""),
                                        ("30s", "--reality-max-time-difference 2m", "2m")):
            with self.subTest(value=value, option=option):
                node = self.save(value, value is not None)
                result = bash(f'''NON_INTERACTIVE=1
parse_options {option}
SKIP_PROTOCOL_PROMPT=1
generate_default_node_name() {{ echo fixture; }}
collect_node_json {shlex.quote(json.dumps(node))} result
echo "$result"''', self.env)
                self.assertEqual(result.returncode, 0, result.stderr)
                saved = json.loads(result.stdout.splitlines()[-1])
                self.assertEqual(saved["reality"]["max_time_difference"], expected)
                self.assertEqual(saved["uuid"], node["uuid"])
                self.assertEqual(saved["reality"]["private_key"], node["reality"]["private_key"])
        for option in ("--reality-max-time-difference", "--reality-max-time-difference ''",
                       "--reality-max-time-difference invalid", "--reality-max-time-difference -1s"):
            self.assertNotEqual(bash(f"parse_options {option}").returncode, 0)

    def test_credentials_edit_updates_time_only_and_summary_displays_it(self):
        for value in ("30s", "0s", "invalid"):
            with self.subTest(value=value):
                node = self.save()
                saved = self.root / "saved.json"
                saved.unlink(missing_ok=True)
                result = bash(f'''current_nodes_json() {{ cat {shlex.quote(str(self.state))} | jq -c .nodes; }}
save_nodes_json() {{ echo "$1" > {shlex.quote(str(saved))}; }}
edit_node_credentials 0 <<< {shlex.quote('5' + chr(10) + value + chr(10))}''', self.env)
                self.assertEqual(result.returncode, 0, result.stderr)
                if value == "invalid":
                    self.assertFalse(saved.exists())
                    continue
                node["reality"]["max_time_difference"] = value
                self.assertEqual(json.loads(saved.read_text()), [node])
                summary = bash(f'print_node_summary_card {shlex.quote(json.dumps(node))}')
                self.assertEqual(summary.returncode, 0, summary.stderr)
                self.assertIn("REALITY 时间偏差: " + ("关闭" if value == "0s" else value), summary.stdout)

    def test_existing_config_migrates_once_and_failed_check_keeps_old_config(self):
        self.save()
        result = bash(f'generate_config_from_state {shlex.quote(str(self.config))}', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        old_config = json.loads(self.config.read_text())
        del old_config["inbounds"][0]["tls"]["reality"]["max_time_difference"]
        for valid in (False, True):
            with self.subTest(valid=valid):
                self.config.write_text(json.dumps(old_config))
                result = bash(f'''sing-box() {{
  if [[ "$1" == version ]]; then echo 'sing-box version 1.11.4'; else return {0 if valid else 1}; fi
}}
apply_config() {{ echo APPLIED; cp "$1" "$CONFIG_FILE"; }}
if outbound_health_config_ready; then exit 99; fi
migrate_outbound_health_config
outbound_health_config_ready
migrate_outbound_health_config''', self.env)
                if valid:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.count("APPLIED"), 1)
                    config = json.loads(self.config.read_text())
                    self.assertEqual(config["inbounds"][0]["tls"]["reality"]["max_time_difference"], "1m")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(json.loads(self.config.read_text()), old_config)
                    self.assertNotIn("APPLIED", result.stdout)

    def test_script_update_invokes_new_script_migration(self):
        self.save()
        updated_script = self.root / "sbox"
        source = SOURCE.replace('readonly SCRIPT_INSTALL_PATH="/usr/local/bin/sbox"',
                                f'readonly SCRIPT_INSTALL_PATH={shlex.quote(str(updated_script))}')
        source = source.replace('readonly SCRIPT_SYMLINK_PATH="/usr/bin/sbox"',
                                f'readonly SCRIPT_SYMLINK_PATH={shlex.quote(str(self.root / "sbox-link"))}')
        # 新旧两版都只操作测试目录；真实安装、服务和核心命令全部替换。
        overrides = '''
require_root() { :; }
detect_os() { :; }
migrate_legacy_state() { :; }
sync_outbound_health_service() { :; }
refresh_api_service() { :; }
ensure_time_sync_service() { :; }
install_deploy_hook() { :; }
sync_traffic_cron() { :; }
sync_traffic_rules() { :; }
sync_anytls_default_padding() { :; }
service_is_installed() { return 1; }
sing-box() {
  if [[ "$1" == version ]]; then echo 'sing-box version 1.11.4'; fi
}
apply_config() { cp "$1" "$CONFIG_FILE"; echo APPLIED; }
install() {
  if [[ "$*" == '-d -m 0755 /usr/local/bin /usr/bin' ]]; then return 0; fi
  command install "$@"
}
curl() {
  [[ "$*" == *purge.jsdelivr.net* ]] && return 0
  [[ "$*" == *anytls_padding.conf* ]] && return 1
  cp "$TEST_DOWNLOAD_SCRIPT" "${@: -1}"
}
'''
        guarded_main = 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'
        remote = self.root / "remote.sh"
        remote.write_text(source.replace(guarded_main, overrides + "\n" + guarded_main))
        old = self.root / "old.sh"
        old_source = remote.read_text().replace('readonly SCRIPT_VERSION="0.0.50"', 'readonly SCRIPT_VERSION="0.0.49"')
        # 模拟旧脚本本身不懂新字段，只能由安装的新脚本执行迁移。
        old.write_text(old_source.replace(guarded_main,
                                         'migrate_outbound_health_config() { :; }\n' + guarded_main))
        result = bash(f'generate_config_from_state {shlex.quote(str(self.config))}', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = json.loads(self.config.read_text())
        del original["inbounds"][0]["tls"]["reality"]["max_time_difference"]
        self.config.write_text(json.dumps(original))
        env = dict(self.env, TEST_DOWNLOAD_SCRIPT=str(remote))
        result = subprocess.run(["bash", "-c", f'source {shlex.quote(str(old))}\nupdate_self_script silent'],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("APPLIED"), 1)
        self.assertTrue(updated_script.exists())
        self.assertEqual(json.loads(self.state.read_text())["nodes"][0]["reality"]["max_time_difference"], "1m")
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["tls"]["reality"]["max_time_difference"], "1m")


if __name__ == "__main__":
    unittest.main()
