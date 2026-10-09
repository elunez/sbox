"""本地隔离回归：模拟下载、服务和计数器，不访问网络或真实 nftables。"""
import concurrent.futures
import contextlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sbox.sh"
SOURCE = SCRIPT.read_text()


def heredoc(marker):
    start = re.search(r"<<\s*'" + marker + "'", SOURCE).start()
    start = SOURCE.index("\n", start) + 1
    return SOURCE[start:SOURCE.index("\n" + marker + "\n", start)]


def module(code):
    result = types.ModuleType("sbox_test")
    exec(compile(code, str(SCRIPT), "exec"), result.__dict__)
    return result


def bash(code, env=None):
    return subprocess.run(["bash", "-c", "source " + shlex.quote(str(SCRIPT)) + "\n" + code],
                          text=True, capture_output=True, env=env, timeout=15)


class HealthTests(unittest.TestCase):
    def setUp(self):
        self.health = module(heredoc("PY_OUTBOUND_HEALTH_EOF"))
        self.tags = ["backup-1-1", "backup-1-2", "backup-1-3"]
        self.item = {"key": "8388", "name": "测试", "outbound": "out-1", "backups": self.tags,
                     "selector": "health-1", "direct_fallback": False}
        self.health.configured_nodes = lambda: [self.item]
        self.health.write_runtime_state = lambda state: None
        self.switches = []
        self.health.switch = lambda selector, target: self.switches.append(target) or True

    def cycle(self, runtime, primary, backups):
        values = dict(zip(["out-1"] + self.tags, [primary] + backups))
        self.health.probe = lambda tag: (values[tag], 10 if values[tag] is True else None, "test")
        return self.health.run_cycle(runtime)

    def runtime(self, current):
        return {"8388": {"current": current}}

    def test_backup_three_recovers_to_two_then_primary(self):
        state = self.runtime(self.tags[2])
        state = self.cycle(state, False, [False, True, True])
        self.assertEqual(self.switches, [])
        state = self.cycle(state, False, [False, True, True])
        self.assertEqual(self.switches, [self.tags[1]])
        state = self.cycle(state, True, [False, True, True])
        self.assertEqual(state["8388"]["current"], self.tags[1])
        state = self.cycle(state, True, [True, True, True])
        self.assertEqual(state["8388"]["current"], "primary")

    def test_highest_stable_backup_wins(self):
        state = self.runtime(self.tags[2])
        for _ in range(2):
            state = self.cycle(state, False, [True, True, True])
        self.assertEqual(self.switches, [self.tags[0]])

    def test_unknown_breaks_recovery_and_failure_streaks(self):
        state = self.runtime(self.tags[2])
        for ok in (True, None, True):
            state = self.cycle(state, None, [False, ok, True])
        self.assertEqual(self.switches, [])
        state = self.cycle(state, None, [False, True, True])
        self.assertEqual(self.switches, [self.tags[1]])
        self.switches.clear()
        state = self.runtime("primary")
        for ok in (False, None, False):
            state = self.cycle(state, ok, [True, True, True])
        self.assertEqual(self.switches, [])

    def test_failure_uses_available_backup_without_recovery_delay(self):
        state = self.runtime(self.tags[2])
        state = self.cycle(state, False, [False, False, False])
        state = self.cycle(state, False, [False, True, False])
        self.assertEqual(self.switches, [self.tags[1]])

    def test_direct_requires_explicit_configuration_and_known_failures(self):
        state = self.runtime("primary")
        for _ in range(2):
            state = self.cycle(state, False, [False, False, False])
        self.assertEqual(self.switches, [])
        self.item["direct_fallback"] = True
        state = self.cycle(state, False, [False, None, False])
        self.assertEqual(self.switches, [])
        state = self.cycle(state, False, [False, False, False])
        self.assertEqual(self.switches, ["direct"])
        state = self.cycle(state, False, [False, True, False])
        self.assertEqual(state["8388"]["current"], "direct")
        state = self.cycle(state, False, [False, True, False])
        self.assertEqual(state["8388"]["current"], self.tags[1])

    def test_switch_failure_keeps_current_exit(self):
        self.health.switch = lambda selector, target: False
        state = self.runtime(self.tags[2])
        for _ in range(2):
            state = self.cycle(state, False, [False, True, True])
        self.assertEqual(state["8388"]["current"], self.tags[2])

    def test_probe_classifies_api_errors_as_unknown(self):
        for status, expected in ((200, True), (408, False), (504, False), (503, None), (401, None)):
            with self.subTest(status=status):
                self.health.api_request = lambda *args: (status, {"delay": 12})
                self.assertIs(self.health.probe("out-1")[0], expected)


class TrafficTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state_file = Path(self.tmp.name) / "state.json"
        self.state = {"nodes": [
            {"name": "SS", "protocol": "shadowsocks", "domain": "example.com", "port": 8388,
             "traffic": {"billing_mode": "single", "monthly_limit": "1KB", "reset_day": 1}},
            {"name": "HTTP", "protocol": "http", "domain": "example.net", "port": 8080,
             "traffic": {"billing_mode": "double", "monthly_limit": "unlimited", "reset_day": None}},
        ]}
        self.state_file.write_text(json.dumps(self.state))
        self.collector = module(heredoc("PY_TRAFFIC_EOF"))
        self.calls = []
        self.env = patch.dict(os.environ, {"SBOX_STATE_FILE": str(self.state_file)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_command(self, command, **kwargs):
        self.calls.append(command)
        if command[0] == "nft":
            counters = []
            for port, incoming, outgoing in ((8388, 512, 1024), (8080, 2048, 4096)):
                for direction, value in (("in", incoming), ("out", outgoing)):
                    counters.append({"counter": {"family": "inet", "table": "sing_box_traffic",
                                                  "name": f"node_{port}_{direction}", "bytes": value}})
            return types.SimpleNamespace(returncode=0, stdout=json.dumps({"nftables": counters}))
        return types.SimpleNamespace(returncode=0)

    def test_batch_snapshot_preserves_fields_and_billing(self):
        with patch.object(self.collector.subprocess, "run", side_effect=self.run_command):
            result = self.collector.collect_traffic_snapshot()
        self.assertEqual(sum(command[0] == "nft" for command in self.calls), 1)
        self.assertEqual(result["total_nodes"], 2)
        self.assertEqual(result["total_traffic"]["total_bytes"], 7168)
        first, second = result["nodes"]
        self.assertEqual(first, {
            "name": "SS", "protocol": "shadowsocks", "domain": "example.com", "port": 8388,
            "input_bytes": 512, "output_bytes": 1024, "total_bytes": 1024,
            "input_formatted": "512 B", "output_formatted": "1.00 KB", "total_formatted": "1.00 KB",
            "billing_mode": "single",
            "quota": {"enabled": True, "monthly_limit": "1KB", "monthly_limit_bytes": 1024,
                      "reset_day": 1, "used_percent": 100}, "is_blocked": True})
        self.assertEqual(second["total_bytes"], 6144)
        self.assertIsNone(second["quota"]["used_percent"])

    def test_port_filter_and_legacy_defaults(self):
        self.state["domain"] = "legacy.example"
        self.state["nodes"] = [{"name": "旧节点", "port": 8388}]
        self.state_file.write_text(json.dumps(self.state))
        with patch.object(self.collector.subprocess, "run", side_effect=self.run_command):
            result = self.collector.collect_traffic_snapshot("8388")
            empty = self.collector.collect_traffic_snapshot("9999")
        self.assertEqual(result["nodes"][0]["domain"], "legacy.example")
        self.assertEqual(result["nodes"][0]["protocol"], "anytls")
        self.assertEqual(empty["total_nodes"], 0)

    def test_nft_failure_is_reported_not_zero_traffic(self):
        with patch.object(self.collector.subprocess, "run", return_value=types.SimpleNamespace(returncode=1)):
            with self.assertRaises(RuntimeError):
                self.collector.collect_traffic_snapshot()

    def test_cache_merges_concurrent_queries_and_expires(self):
        api = module(heredoc("PY_TRAFFIC_EOF") + "\n" + heredoc("PY_SERVER_EOF"))
        count = []
        def collect():
            count.append(1)
            time.sleep(0.03)
            return {"nodes": []}
        api.collect_traffic_snapshot = collect
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            results = list(pool.map(lambda _: api.get_traffic_snapshot(), range(16)))
        self.assertEqual(len(count), 1)
        self.assertTrue(all(item is results[0] for item in results))
        api._CACHE_TIME -= 3
        api.get_traffic_snapshot()
        self.assertEqual(len(count), 2)

    def test_api_routes_auth_errors_and_port_queries_share_cache(self):
        api = module(heredoc("PY_TRAFFIC_EOF") + "\n" + heredoc("PY_SERVER_EOF"))
        with patch.object(api.subprocess, "run", side_effect=self.run_command):
            snapshot = api.collect_traffic_snapshot()
        calls = []
        api.collect_traffic_snapshot = lambda: calls.append(1) or snapshot
        api.load_api_config = lambda: {"token": "test-token"}
        def request(path, authorized=True):
            handler = object.__new__(api.APIHandler)
            handler.path = path
            handler.headers = {"Authorization": "Bearer test-token"} if authorized else {}
            responses = []
            handler.send_json = lambda data, code=200: responses.append((data, code))
            handler.do_GET()
            return responses[0]
        self.assertEqual(request("/api/traffic", False)[1], 401)
        self.assertEqual(calls, [])
        self.assertEqual(request("/api/traffic/8388")[0]["total_bytes"], 1024)
        self.assertEqual(request("/api/traffic/8080")[0]["total_bytes"], 6144)
        self.assertEqual(request("/api/traffic")[0]["total_nodes"], 2)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("instance_id", snapshot["nodes"][0])
        self.assertEqual(request("/api/traffic/9999")[1], 404)
        self.assertEqual(request("/api/traffic/invalid")[1], 400)
        api._CACHE_TIME -= 3
        api.collect_traffic_snapshot = lambda: (_ for _ in ()).throw(RuntimeError("模拟采集失败"))
        with contextlib.redirect_stderr(io.StringIO()):
            for path in ("/api/health", "/api/traffic", "/api/traffic/8388"):
                self.assertEqual(request(path)[1], 503)


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)

    def test_tfo_defaults_cli_generation_and_type_validation(self):
        node = {"name": "SS", "protocol": "shadowsocks", "domain": "example.com", "port": 8388,
                "method": "aes-128-gcm", "password": "test", "traffic": {"monthly_limit": "unlimited"},
                "outbound": {"type": "direct"}}
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        for flag in (None, False, True, "true"):
            with self.subTest(flag=flag):
                item = dict(node)
                if flag is not None:
                    item["tcp_fast_open"] = flag
                state.write_text(json.dumps({"nodes": [item]}))
                result = bash(f'generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}')
                self.assertEqual(result.returncode, 1 if isinstance(flag, str) else 0, result.stderr)
                if result.returncode == 0:
                    self.assertIs(json.loads(output.read_text())["inbounds"][0]["tcp_fast_open"], flag is True)
        result = bash('NON_INTERACTIVE=1\ncollect_ss_tfo_settings \'{"tcp_fast_open":true}\'\nprintf "%s\\n" "$SS_TFO"\nparse_options --no-ss-tfo\nprintf "%s\\n" "$SS_TFO"\nparse_options --ss-tfo\nprintf "%s\\n" "$SS_TFO"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["true", "false", "true"])

    def test_tfo_edit_preserves_other_fields_and_checks_kernel_read_only(self):
        nodes = [{"protocol": "shadowsocks", "port": 8388, "tcp_fast_open": True, "password": "test"}]
        encoded = shlex.quote(json.dumps(nodes))
        result = bash(f'''current_nodes_json() {{ printf '%s' {encoded}; }}
save_nodes_json() {{ printf '%s\\n' "$1"; }}
NON_INTERACTIVE=1
edit_node_tfo 0
sysctl() {{ [[ "$1" == "-n" ]] || return 99; echo 1; }}
warn_ss_tfo_support''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[0]), nodes)
        self.assertIn("内核尚未启用", result.stderr)

    def test_tfo_creation_reconfiguration_and_protocol_change(self):
        old = {"name": "SS", "protocol": "shadowsocks", "domain": "example.com", "port": 8388,
               "method": "aes-128-gcm", "password": "test", "tcp_fast_open": True}
        setup = '''NON_INTERACTIVE=1
SKIP_PROTOCOL_PROMPT=1
SS_METHOD=aes-128-gcm
NODE_DOMAIN=example.com
NODE_PORT=8388
generate_default_node_name() { echo 测试; }
collect_traffic_settings() { printf -v "$2" '%s' '{"monthly_limit":"unlimited"}'; }
collect_outbound_settings() { printf -v "$2" '%s' '{"type":"direct"}'; }
'''
        for protocol, option, expected in (("shadowsocks", "", True),
                                           ("shadowsocks", "parse_options --no-ss-tfo", False),
                                           ("socks5", "", None)):
            with self.subTest(protocol=protocol, option=option):
                result = bash(setup + f'PROTOCOL={protocol}\n{option}\ncollect_node_json {shlex.quote(json.dumps(old))} result\nprintf "%s\\n" "$result"')
                self.assertEqual(result.returncode, 0, result.stderr)
                node = json.loads(result.stdout.splitlines()[-1])
                self.assertIs(node.get("tcp_fast_open"), expected)
                self.assertEqual(node["protocol"], protocol)

    def test_dependency_failure_is_not_retried_and_cache_options_are_scoped(self):
        log = self.directory / "apt-calls"
        result = bash(f'''detect_os() {{ PKG_MGR=apt; }}
apt-get() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; [[ "$*" != *" install "* ]]; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_singbox_binary() {{ echo 不应安装核心; }}
install_dependencies_and_core''')
        self.assertNotEqual(result.returncode, 0)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertEqual(sum(" install " in call for call in calls), 1)
        self.assertTrue(all("APT::Keep-Downloaded-Packages=false" in call for call in calls))
        self.assertNotIn("不应安装核心", result.stdout)

    def test_generated_api_script_and_old_service_migration(self):
        state_dir = self.directory / "state"
        env = dict(os.environ, STATE_DIR=str(state_dir))
        result = bash('install_api_server_script', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        api_path = state_dir / "api/http_server.py"
        api = module(api_path.read_text())
        self.assertTrue(callable(api.get_traffic_snapshot))
        for running in (True, False):
            with self.subTest(running=running):
                api_path.write_text("old script")
                result = bash(f'''ensure_api_service_file() {{ :; }}
service_is_running() {{ return {0 if running else 1}; }}
service_restart() {{ echo 重启; }}
refresh_api_service
refresh_api_service''', env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), ["重启"] if running else [])

    def test_health_service_restarts_only_when_monitor_changes(self):
        env = dict(os.environ, STATE_DIR=str(self.directory / "state"), CONFIG_FILE=str(self.directory / "config"))
        (self.directory / "config").write_text("test")
        result = bash('''outbound_health_node_count() { echo 1; }
outbound_health_config_ready() { return 0; }
ensure_outbound_health_secret() { :; }
ensure_outbound_health_service_file() { mkdir -p "$STATE_DIR"; echo new > "$OUTBOUND_HEALTH_SCRIPT"; }
service_enable() { :; }
service_is_running() { return 0; }
service_restart() { echo 重启; }
service_start() { :; }
sync_outbound_health_service
sync_outbound_health_service''', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["重启"])

    def installation(self, archive_content, extra=""):
        install_dir = self.directory / "install"
        link_dir = self.directory / "links"
        install_dir.mkdir()
        link_dir.mkdir()
        old = install_dir / "sing-box"
        old.write_text("old core")
        archive = self.directory / "core.tar.gz"
        with tarfile.open(archive, "w:gz") as fh:
            for name, content in (("sing-box-1.14.2-linux-amd64/sing-box", archive_content),
                                  ("sing-box-1.14.2-linux-amd64/LICENSE", b"unused" * 10000)):
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                fh.addfile(entry, io.BytesIO(content))
        start = SOURCE.index("install_singbox_binary() (")
        end = SOURCE.index("\napt_get_minimal()", start)
        function = SOURCE[start:end].replace("/usr/local/bin", str(install_dir)).replace("/usr/bin", str(link_dir))
        code = function + f'''\nuname() {{ echo x86_64; }}
curl() {{ cat {shlex.quote(str(archive))}; }}
ensure_service_file() {{ :; }}
{extra}
install_singbox_binary 1.14.2'''
        result = bash(code)
        self.assertEqual(list(install_dir.glob(".sing-box.*")), [])
        self.assertEqual(sorted(path.name for path in install_dir.iterdir()), ["sing-box"])
        return result, old

    def test_stream_install_extracts_only_core(self):
        result, core = self.installation(b"#!/bin/sh\necho 'sing-box version 1.14.2'\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.14.2", core.read_text())

    def test_invalid_core_keeps_old_binary(self):
        result, core = self.installation(b"invalid binary")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(core.read_text(), "old core")

    def test_download_failure_even_after_complete_payload_keeps_old_binary(self):
        result, core = self.installation(b"#!/bin/sh\necho version\n", "curl() { command cat " + shlex.quote(str(self.directory / "core.tar.gz")) + "; return 23; }")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(core.read_text(), "old core")

    def test_write_failure_keeps_old_binary(self):
        result, core = self.installation(b"#!/bin/sh\necho version\n", 'tar() { cat >/dev/null; echo "模拟磁盘写入失败" >&2; return 2; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(core.read_text(), "old core")

    def test_corrupt_archive_keeps_old_binary(self):
        result, core = self.installation(b"#!/bin/sh\necho version\n", 'curl() { printf "corrupt archive"; }')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(core.read_text(), "old core")


if __name__ == "__main__":
    unittest.main()
