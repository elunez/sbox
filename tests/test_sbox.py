"""本地隔离回归：模拟下载、服务和计数器，不访问网络或真实 nftables。"""
import concurrent.futures
import base64
import contextlib
import io
import json
import os
import pty
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

    def test_direct_switch_uses_node_resolver_outbound_and_can_recover(self):
        self.item.update(direct_fallback=True, direct_outbound="direct-1")
        state = self.runtime("primary")
        for _ in range(2):
            state = self.cycle(state, False, [False, False, False])
        self.assertEqual(self.switches, ["direct-1"])
        self.assertEqual(state["8388"]["current"], "direct")
        for _ in range(2):
            state = self.cycle(state, True, [False, False, False])
        self.assertEqual(self.switches, ["direct-1", "out-1"])
        self.assertEqual(state["8388"]["current"], "primary")

    def test_monitor_direct_tags_follow_node_index(self):
        health = module(heredoc("PY_OUTBOUND_HEALTH_EOF"))
        health.read_json = lambda *args: {"nodes": [
            {"outbound": {"type": "direct"}},
            {"port": 8389, "outbound": {"type": "shadowsocks"},
             "backup_outbounds": [{"type": "shadowsocks"}, {"type": "direct"}]}]}
        item = health.configured_nodes()[0]
        self.assertEqual(item["direct_outbound"], "direct-2")
        self.assertEqual(item["selector"], "health-2")
        self.assertEqual(item["backups"], ["backup-2-1"])

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
            if command != ["nft", "-j", "list", "table", "inet", "sing_box_traffic"]:
                return types.SimpleNamespace(returncode=1, stdout="", stderr="syntax error")
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

    def test_table_snapshot_ignores_rules_quotas_and_unrelated_counters(self):
        entries = [
            {"metainfo": {"json_schema_version": 1}},
            {"table": {"family": "inet", "name": "sing_box_traffic"}},
            {"chain": {"family": "inet", "table": "sing_box_traffic", "name": "input"}},
            {"rule": {"expr": [{"counter": {"bytes": 999999}}]}},
            {"quota": {"name": "node_8388_quota", "bytes": 999999}},
            {"counter": {"family": "inet", "table": "other", "name": "node_8388_out", "bytes": 999999}},
            {"counter": {"family": "ip", "table": "sing_box_traffic", "name": "node_8388_out", "bytes": 999999}},
            {"counter": {"family": "inet", "table": "sing_box_traffic", "name": "node_8388_out", "bytes": 1234}},
        ]
        result = types.SimpleNamespace(returncode=0, stdout=json.dumps({"nftables": entries}))
        with patch.object(self.collector.subprocess, "run", side_effect=[result, types.SimpleNamespace(returncode=0)]):
            snapshot = self.collector.collect_traffic_snapshot()
        self.assertEqual(snapshot["nodes"][0]["total_bytes"], 1234)
        self.assertEqual(snapshot["total_traffic"]["total_bytes"], 1234)

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

    def dns_node(self, port=8388, dns=None):
        node = {"name": "DNS", "protocol": "socks5", "domain": "example.com", "port": port,
                "traffic": {"monthly_limit": "unlimited"}, "outbound": {"type": "direct"}}
        if dns is not None:
            node["dns"] = dns
        return node

    def collect_padding(self, text, after=""):
        nodes = [{"name": "other", "protocol": "anytls", "padding_scheme": ["stop=1", "0=30-30"]},
                 {"name": "selected", "protocol": "anytls", "password": "fixture"}]
        saved = self.directory / "padding-nodes.json"
        if saved.exists():
            saved.unlink()
        code = f'''source {shlex.quote(str(SCRIPT))}
current_nodes_json() {{ printf '%s' {shlex.quote(json.dumps(nodes))}; }}
save_nodes_json() {{ printf '%s' "$1" > {shlex.quote(str(saved))}; }}
pause_prompt() {{ :; }}
collect_and_apply_padding_scheme 1
{after}'''
        result = subprocess.run(["bash", "-c", code], input=text, text=True,
                                capture_output=True, timeout=5)
        return result, saved, nodes

    def test_padding_input_keeps_last_rule_with_or_without_final_newline(self):
        expected = ["stop=2", "0=10-30", "1=10-30"]
        for text in ("stop=2\n0=10-30\n1=10-30", "stop=2\n0=10-30\n1=10-30\n",
                     "stop=2\n0=10-30\n1=10-30\n\n", "stop=2\r\n0=10-30\r\n1=10-30",
                     "# custom\n stop=2 \n0=10-30\n1=10-30", "0=10-30\n1=10-30"):
            with self.subTest(text=text):
                result, saved, original = self.collect_padding(text)
                self.assertEqual(result.returncode, 0, result.stderr)
                original[1]["padding_scheme"] = expected
                self.assertEqual(json.loads(saved.read_text()), original)
                self.assertIn("  1=10-30\n", result.stdout)

    def test_padding_cancel_empty_and_invalid_input_do_not_save(self):
        for text in ("", "\n\n", "q", "stop=2\n0=10-30\nq", "stop=2\n0=10-30\nquit\n",
                     "stop=2\n0=10-30\n1=invalid!"):
            with self.subTest(text=text):
                result, saved, _ = self.collect_padding(text)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(saved.exists())

    def test_padding_blank_line_submission_preserves_next_menu_input(self):
        result, saved, _ = self.collect_padding("stop=2\n0=10-30\n1=10-30\n\n0\n",
                                                'IFS= read -r next_choice\nprintf "NEXT:%s\\n" "$next_choice"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(saved.read_text())[1]["padding_scheme"], ["stop=2", "0=10-30", "1=10-30"])
        self.assertTrue(result.stdout.endswith("NEXT:0\n"))

    def test_dns_validation_rejects_invalid_state_before_generation(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        for settings, valid in (({"mode": "system"}, True),
                                ({"mode": "custom", "server": "1.1.1.1"}, True),
                                ({"mode": "custom", "server": "2606:4700:4700::1111"}, True),
                                (None, False), ({"mode": "other"}, False),
                                ({"mode": "custom", "server": "dns.google"}, False),
                                ({"mode": "custom", "server": "udp://1.1.1.1"}, False),
                                ({"mode": "custom", "server": "fe80::1%eth0"}, False),
                                ({"mode": "custom", "server": "999.1.1.1"}, False),
                                ({"mode": "custom", "server": 123}, False)):
            with self.subTest(settings=settings):
                node = self.dns_node()
                node["dns"] = settings
                state.write_text(json.dumps({"nodes": [node]}))
                result = bash(f'generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}')
                self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)

    def test_dns_collection_defaults_preserves_changes_and_cancels(self):
        old = {"dns": {"mode": "custom", "server": "8.8.8.8"}}
        encoded = shlex.quote(json.dumps(old))
        result = bash(f'''NON_INTERACTIVE=1
collect_dns_settings '{{}}' result
echo "$result"
collect_dns_settings {encoded} result
echo "$result"
parse_options --dns-mode custom --dns-server 2606:4700:4700::1111
collect_dns_settings {encoded} result
echo "$result"
parse_options --dns-mode system
collect_dns_settings {encoded} result
echo "$result"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()],
                         [{"mode": "system"}, old["dns"],
                          {"mode": "custom", "server": "2606:4700:4700::1111"}, {"mode": "system"}])
        result = bash('collect_dns_settings \'{}\' result <<< $\'2\\ndns.google\\n1.1.1.1\\n\'\necho "$result"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"mode": "custom", "server": "1.1.1.1"})
        result = bash('result=unchanged\nif collect_dns_settings \'{}\' result <<< 0; then exit 99; fi\necho "$result"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unchanged")

    def test_dns_creation_and_reconfiguration_preserve_choice(self):
        setup = '''NON_INTERACTIVE=1
SKIP_PROTOCOL_PROMPT=1
PROTOCOL=socks5
NODE_DOMAIN=example.com
NODE_PORT=8388
generate_default_node_name() { echo DNS; }
collect_traffic_settings() { printf -v "$2" '%s' '{"monthly_limit":"unlimited"}'; }
collect_outbound_settings() { printf -v "$2" '%s' '{"type":"direct"}'; }
'''
        for settings in (None, {"mode": "custom", "server": "8.8.8.8"},
                         {"mode": "system", "strategy": "ipv4_only"},
                         {"mode": "custom", "server": "8.8.8.8", "strategy": "prefer_ipv6"}):
            with self.subTest(settings=settings):
                old = self.dns_node(dns=settings)
                result = bash(setup + f'collect_node_json {shlex.quote(json.dumps(old))} result\necho "$result"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout.splitlines()[-1])["dns"], settings or {"mode": "system"})

    def test_dns_strategy_cli_preserves_switches_and_resets(self):
        old = {"dns": {"mode": "custom", "server": "8.8.8.8", "strategy": "ipv6_only"}}
        for strategy in ("ipv4_only", "prefer_ipv4", "ipv6_only", "prefer_ipv6"):
            with self.subTest(strategy=strategy):
                result = bash(f'''NON_INTERACTIVE=1
parse_options --dns-strategy {strategy}
collect_dns_settings '{{}}' result
echo "$result"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {"mode": "system", "strategy": strategy})
        result = bash(f'''NON_INTERACTIVE=1
collect_dns_settings {shlex.quote(json.dumps(old))} result
echo "$result"
parse_options --dns-mode system
collect_dns_settings {shlex.quote(json.dumps(old))} result
echo "$result"
parse_options --dns-strategy default
collect_dns_settings {shlex.quote(json.dumps(old))} result
echo "$result"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()],
                         [old["dns"], {"mode": "system", "strategy": "ipv6_only"}, {"mode": "system"}])
        for option in ("--dns-strategy bad", "--dns-strategy", "--dns-strategy ''"):
            result = bash(f"parse_options {option}")
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_dns_strategy_validation_rejects_invalid_values_before_generation(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        for strategy, valid in (("default", True), ("ipv4_only", True), ("prefer_ipv4", True),
                                ("ipv6_only", True), ("prefer_ipv6", True), ("bad", False),
                                ("", False), (None, False), (False, False), (123, False)):
            with self.subTest(strategy=strategy):
                state.write_text(json.dumps({"nodes": [self.dns_node(dns={"mode": "system", "strategy": strategy})]}))
                output.write_text("unchanged")
                result = bash(f'generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}')
                self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
                if not valid:
                    self.assertEqual(output.read_text(), "unchanged")

    def test_dns_strategy_can_be_edited_and_cancelled_without_touching_other_nodes(self):
        nodes = [self.dns_node(dns={"mode": "custom", "server": "8.8.8.8", "strategy": "prefer_ipv6"}),
                 self.dns_node(8389, {"mode": "system", "strategy": "ipv4_only"})]
        setup = f'''current_nodes_json() {{ echo {shlex.quote(json.dumps(nodes))}; }}
save_nodes_json() {{ echo "$1"; }}
'''
        for choice, strategy in ((1, None), (2, "ipv4_only"), (3, "prefer_ipv4"),
                                 (4, "ipv6_only"), (5, "prefer_ipv6")):
            with self.subTest(strategy=strategy):
                result = bash(setup + f"edit_node_dns 0 <<< $'\\n\\n{choice}\\n'")
                self.assertEqual(result.returncode, 0, result.stderr)
                updated = next(json.loads(line) for line in result.stdout.splitlines() if line.startswith("[{"))
                expected = {"mode": "custom", "server": "8.8.8.8"}
                if strategy:
                    expected["strategy"] = strategy
                self.assertEqual(updated[0]["dns"], expected)
                self.assertEqual(updated[1], nodes[1])
        result = bash(setup + "save_nodes_json() { exit 99; }\nedit_node_dns 0 <<< $'\\n\\n0\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        for strategy, label in (("ipv4_only", "仅 IPv4"), ("prefer_ipv4", "IPv4 优先"),
                                ("ipv6_only", "仅 IPv6"), ("prefer_ipv6", "IPv6 优先")):
            node = self.dns_node(dns={"mode": "system", "strategy": strategy})
            result = bash(f'print_node_summary_card {shlex.quote(json.dumps(node))}')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"DNS 设置: 系统 DNS / {label}", result.stdout)

    def test_dns_edit_only_updates_selected_node_and_cancel_does_not_save(self):
        nodes = [self.dns_node(), self.dns_node(8389, {"mode": "custom", "server": "8.8.8.8"})]
        encoded = shlex.quote(json.dumps(nodes))
        result = bash(f'''NON_INTERACTIVE=1
current_nodes_json() {{ echo {encoded}; }}
save_nodes_json() {{ echo "$1"; }}
parse_options --dns-mode custom --dns-server 1.1.1.1
edit_node_dns 0''')
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = json.loads(result.stdout.splitlines()[0])
        expected = json.loads(json.dumps(nodes))
        expected[0]["dns"] = {"mode": "custom", "server": "1.1.1.1"}
        self.assertEqual(updated, expected)
        result = bash(f'''current_nodes_json() {{ echo {encoded}; }}
save_nodes_json() {{ exit 99; }}
edit_node_dns 0 <<< 0''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dns_schema_migration_defaults_only_missing_fields(self):
        state = self.directory / "state.json"
        nodes = [self.dns_node(), self.dns_node(8389, {"mode": "custom", "server": "8.8.8.8"}),
                 self.dns_node(8390)]
        nodes[2]["dns"] = None
        state.write_text(json.dumps({"nodes": nodes}))
        result = bash('ensure_state_schema', dict(os.environ, STATE_FILE=str(state)))
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads(state.read_text())["nodes"]
        self.assertEqual(saved[0]["dns"], {"mode": "system"})
        self.assertEqual(saved[1]["dns"], nodes[1]["dns"])
        self.assertIsNone(saved[2]["dns"])

    def test_dns_protocol_change_preserves_settings_without_reprompting(self):
        node = self.dns_node(dns={"mode": "custom", "server": "8.8.8.8"})
        node.update(username="fixture", password="fixture")
        encoded = shlex.quote(json.dumps([node]))
        result = bash(f'''NON_INTERACTIVE=1
current_nodes_json() {{ echo {encoded}; }}
save_nodes_json() {{ echo "$1"; }}
choose_protocol() {{ printf -v "$1" '%s' http; }}
ensure_node_certificate() {{ return 0; }}
firewall_remove_port() {{ :; }}
collect_dns_settings() {{ exit 99; }}
edit_node_protocol 0 <<< Y''')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = next(json.loads(line) for line in result.stdout.splitlines() if line.startswith("[{"))
        self.assertEqual(saved[0]["dns"], node["dns"])
        self.assertEqual(saved[0]["protocol"], "http")
        self.assertEqual(saved[0]["outbound"], node["outbound"])

    def test_dns_menu_entry_and_summary_show_current_choice(self):
        for protocol, choice in (("socks5", 9), ("shadowsocks", 9), ("anytls", 10)):
            with self.subTest(protocol=protocol):
                node = dict(self.dns_node(dns={"mode": "custom", "server": "8.8.8.8"}), protocol=protocol)
                encoded = shlex.quote(json.dumps([node]))
                result = bash(f'''current_nodes_json() {{ echo {encoded}; }}
print_node_summary_card() {{ :; }}
edit_node_dns() {{ echo EDIT-DNS-$1; }}
edit_single_node_menu 0 <<< $'{choice}\\n0\\n' ''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("EDIT-DNS-0", result.stdout)
        result = bash(f'print_node_summary_card {shlex.quote(json.dumps(self.dns_node(dns={"mode": "custom", "server": "8.8.8.8"})))} 1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DNS 设置: 自定义 (8.8.8.8, UDP 53)", result.stdout)

    def test_dns_generation_and_migration_cover_core_versions_and_backup_exports(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        nodes = [self.dns_node(), self.dns_node(8389, {"mode": "custom", "server": "1.1.1.1"}),
                 self.dns_node(8390, {"mode": "custom", "server": "2606:4700:4700::1111"})]
        nodes[1]["outbound"] = self.ss_outbound()
        nodes[1]["backup_outbounds"] = [self.ss_outbound(True), {"type": "direct"}]
        state.write_text(json.dumps({"nodes": nodes}))
        (self.directory / "outbound_health_api.secret").write_text("test-secret")
        env = dict(os.environ, STATE_DIR=str(self.directory), STATE_FILE=str(state), CONFIG_FILE=str(output))
        for version, level in (("1.11.4", 0), ("1.12.1", 1), ("1.13.14", 2), ("1.14.3", 3)):
            with self.subTest(version=version):
                setup = f'''sing-box() {{ echo 'sing-box version {version}'; }}
generate_config_from_state {shlex.quote(str(output))}
outbound_health_config_ready'''
                result = bash(setup, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                config = json.loads(output.read_text())
                servers = {server["tag"]: server for server in config["dns"]["servers"]}
                outbounds = {outbound["tag"]: outbound for outbound in config["outbounds"]}
                self.assertEqual(outbounds["health-2"]["outbounds"], ["out-2", "backup-2-1", "direct-2"])
                self.assertEqual(config["dns"].get("independent_cache"), True if level < 3 else None)
                if level:
                    self.assertEqual(servers["dns-3"]["server"], "2606:4700:4700::1111")
                    self.assertEqual(config["dns"]["rules"], [])
                    self.assertEqual(servers["sbox-system"].get("prefer_go", False), level >= 2)
                    for tag in ("out-2", "backup-2-1", "direct-2"):
                        self.assertEqual(outbounds[tag]["domain_resolver"], "dns-2")
                    self.assertEqual(outbounds["out-1"]["domain_resolver"], "sbox-system")
                    config["outbounds"][0]["domain_resolver"] = "dns-2"
                else:
                    self.assertEqual(servers["dns-3"]["address"], "udp://[2606:4700:4700::1111]:53")
                    self.assertEqual(config["dns"]["rules"][2], {"inbound": ["in-2"], "server": "dns-2"})
                    self.assertEqual(config["dns"]["rules"][3]["outbound"], ["out-2", "direct-2", "backup-2-1"])
                    self.assertNotIn("default_domain_resolver", config["route"])
                    self.assertNotIn("prefer_go", servers["sbox-system"])
                    config.pop("dns")
                output.write_text(json.dumps(config))
                result = bash(f"sing-box() {{ echo 'sing-box version {version}'; }}\noutbound_health_config_ready", env)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_dns_strategies_apply_per_node_to_all_outbounds_across_core_versions(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        (self.directory / "outbound_health_api.secret").write_text("test-secret")
        env = dict(os.environ, STATE_DIR=str(self.directory), STATE_FILE=str(state), CONFIG_FILE=str(output))
        for version in ("1.11.4", "1.12.1", "1.13.14", "1.14.3"):
            for strategy in ("ipv4_only", "prefer_ipv4", "ipv6_only", "prefer_ipv6"):
                with self.subTest(version=version, strategy=strategy):
                    nodes = [self.dns_node(),
                             self.dns_node(8389, {"mode": "system", "strategy": strategy}),
                             self.dns_node(8390, {"mode": "custom", "server": "1.1.1.1", "strategy": strategy}),
                             self.dns_node(8391, {"mode": "system", "strategy": "default"})]
                    nodes[2]["outbound"] = self.ss_outbound()
                    nodes[2]["backup_outbounds"] = [self.ss_outbound(True), {"type": "direct"}]
                    state.write_text(json.dumps({"nodes": nodes}))
                    result = bash(f'''sing-box() {{ echo 'sing-box version {version}'; }}
generate_config_from_state {shlex.quote(str(output))}
outbound_health_config_ready''', env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    config = json.loads(output.read_text())
                    outbounds = {item["tag"]: item for item in config["outbounds"]}
                    self.assertNotIn("strategy", config["dns"])
                    if version.startswith("1.11."):
                        for tag in ("out-2", "out-3", "backup-3-1", "direct-3"):
                            self.assertEqual(outbounds[tag]["domain_strategy"], strategy)
                            self.assertNotIn("domain_resolver", outbounds[tag])
                        for tag in ("out-1", "out-4", "direct"):
                            self.assertEqual(outbounds[tag]["domain_strategy"], "prefer_ipv4")
                        outbounds["out-2"]["domain_strategy"] = "bad"
                    else:
                        self.assertEqual(outbounds["out-2"]["domain_resolver"],
                                         {"server": "sbox-system", "strategy": strategy})
                        for tag in ("out-3", "backup-3-1", "direct-3"):
                            self.assertEqual(outbounds[tag]["domain_resolver"],
                                             {"server": "dns-3", "strategy": strategy})
                            self.assertNotIn("domain_strategy", outbounds[tag])
                        for tag in ("out-1", "out-4", "direct"):
                            self.assertEqual(outbounds[tag]["domain_resolver"], "sbox-system")
                        outbounds["out-2"]["domain_resolver"] = "sbox-system"
                    output.write_text(json.dumps(config))
                    result = bash(f"sing-box() {{ echo 'sing-box version {version}'; }}\noutbound_health_config_ready", env)
                    self.assertEqual(result.returncode, 1, result.stderr)

    def test_dns_strategy_state_change_migrates_existing_generated_config(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        nodes = [self.dns_node(), self.dns_node(8389)]
        state.write_text(json.dumps({"nodes": nodes}))
        env = dict(os.environ, STATE_DIR=str(self.directory), STATE_FILE=str(state), CONFIG_FILE=str(output))
        setup = "sing-box() { if [[ \"$1\" == version ]]; then echo 'sing-box version 1.14.3'; fi; }\n"
        result = bash(setup + f'generate_config_from_state {shlex.quote(str(output))}', env)
        self.assertEqual(result.returncode, 0, result.stderr)
        nodes[1]["dns"] = {"mode": "system", "strategy": "ipv6_only"}
        state.write_text(json.dumps({"nodes": nodes}))
        result = bash(setup + '''apply_config() { cp "$1" "$CONFIG_FILE"; }
if outbound_health_config_ready; then exit 99; fi
migrate_outbound_health_config
outbound_health_config_ready''', env)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(output.read_text())
        self.assertEqual(config["outbounds"][0]["domain_resolver"], "sbox-system")
        self.assertEqual(config["outbounds"][1]["domain_resolver"],
                         {"server": "sbox-system", "strategy": "ipv6_only"})

    def test_creation_keeps_password_prompt_and_skips_tfo_traffic_and_backup_questions(self):
        for outbound_input in ("", "ss://YWVzLTEyOC1nY206dGVzdA@example.com:8388"):
            with self.subTest(outbound=outbound_input):
                # 协议、名称、地址、端口、SS 加密方式、密码、DNS、出口。
                inputs = "\n".join(["2", "", "", "", "", "my-password", "", outbound_input]) + "\n"
                result = bash(f'''NODE_DOMAIN=192.0.2.1
NODE_PORT=8388
SS_METHOD=aes-128-gcm
generate_default_node_name() {{ echo fixture; }}
ensure_python3() {{ :; }}
collect_node_json '{{}}' created < <(printf '%s' {shlex.quote(inputs)})
echo "$created"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                node = json.loads(result.stdout.splitlines()[-1])
                self.assertEqual(node["password"], "my-password")
                self.assertFalse(node["tcp_fast_open"])
                self.assertEqual(node["traffic"], {"enabled": True, "billing_mode": "single",
                                 "monthly_limit": "unlimited", "reset_day": 1,
                                 "rate_limit": {"enabled": False, "upload": None, "download": None}})
                self.assertEqual(node["backup_outbounds"], [])
                self.assertEqual(node["outbound"], self.ss_outbound(False) if outbound_input else {"type": "direct"})
                self.assertNotIn("TCP Fast Open", result.stdout + result.stderr)
                self.assertNotIn("流量计费统计方式", result.stderr)
                self.assertNotIn("是否添加备用出口", result.stdout)

    def test_traffic_defaults_preserve_existing_settings_and_accept_cli_overrides(self):
        traffic = {"enabled": True, "billing_mode": "double", "monthly_limit": "500GB", "reset_day": None,
                   "rate_limit": {"enabled": True, "upload": "10Mbps", "download": "20Mbps"}}
        old = {"traffic": traffic}
        for option, expected in (("", traffic), ("--traffic-limit 200GB --reset-day 15",
                                                dict(traffic, monthly_limit="200GB", reset_day=15))):
            with self.subTest(option=option):
                result = bash(f'''prompt_value() {{ exit 99; }}
prompt_choice() {{ exit 99; }}
parse_options {option}
collect_traffic_settings {shlex.quote(json.dumps(old))} settings 0
echo "$settings"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)
        for option, valid in (("--reset-day 0", True), ("--reset-day 32", False), ("--traffic-limit invalid", False)):
            result = bash(f'''parse_options {option}
collect_traffic_settings '{{}}' settings 0
echo "$settings"''')
            self.assertEqual(result.returncode == 0, valid, result.stderr)
            if valid:
                self.assertIsNone(json.loads(result.stdout)["reset_day"])

    def test_traffic_can_still_be_edited_interactively(self):
        result = bash('''collect_traffic_settings '{}' settings <<< $'2\\n100GB\\n15\\n'
echo "$settings"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        traffic = json.loads(result.stdout)
        self.assertEqual((traffic["billing_mode"], traffic["monthly_limit"], traffic["reset_day"]),
                         ("double", "100GB", 15))

    def test_outbound_enter_preserves_existing_proxy_and_manual_selection_still_works(self):
        for old, expected in (({}, {"type": "direct"}), ({"outbound": self.ss_outbound(True)}, self.ss_outbound(True))):
            with self.subTest(old=old):
                result = bash(f'''collect_outbound_settings {shlex.quote(json.dumps(old))} result <<< ''
echo "$result"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout.splitlines()[-1]), expected)
                self.assertNotIn("出口协议设置", result.stderr)
                self.assertNotIn("TCP Fast Open", result.stdout + result.stderr)
        inputs = shlex.quote("m\n3\nexample.com\n8388\n5\ntest\n")
        result = bash(f'''collect_outbound_settings '{{}}' result < <(printf '%s' {inputs})
echo "$result"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]), self.ss_outbound(False))

    def test_bad_outbound_link_retries_in_place_and_cli_fails_without_fallback(self):
        bad_link = "vless://invalid@example.com:443?security=none"
        result = bash(f'''ensure_python3() {{ :; }}
collect_outbound_settings '{{}}' result < <(printf '%s' {shlex.quote(bad_link + chr(10) + chr(10))})
echo "$result"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]), {"type": "direct"})
        self.assertIn("解析失败", result.stderr)
        result = bash(f'''NON_INTERACTIVE=1
ensure_python3() {{ :; }}
OUTBOUND={shlex.quote(bad_link)}
collect_outbound_settings '{{}}' result''')
        self.assertNotEqual(result.returncode, 0)

    def test_tfo_is_hidden_from_node_summary_share_output_and_edit_menu(self):
        node = dict(self.dns_node(), protocol="shadowsocks", method="aes-128-gcm", password="test",
                    tcp_fast_open=True, outbound=self.ss_outbound(True))
        result = bash(f'''current_nodes_json() {{ echo {shlex.quote(json.dumps([node]))}; }}
print_node_summary_card {shlex.quote(json.dumps(node))}
show_client
edit_single_node_menu 0 <<< 0''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TFO", result.stdout + result.stderr)
        self.assertNotIn("TCP Fast Open", result.stdout + result.stderr)

    def test_vless_links_require_reality_and_keep_legacy_reality_compatibility(self):
        uuid = "bf000d23-0752-40b4-affe-68f7707a9661"
        base = f"vless://{uuid}@proxy.example.com:443"
        for query in ("", "?security=none&type=tcp", "?security=none&pbk=public",
                      "?security=tls", "?security=reality", "?security=reality&pbk=public&type=ws"):
            with self.subTest(query=query):
                result = bash(f'''ensure_python3() {{ :; }}
imported=unchanged
if parse_proxy_link {shlex.quote(base + query)} imported; then exit 99; fi
echo "$imported"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "unchanged")
                self.assertIn("解析失败", result.stderr)
        for query in ("?security=reality&pbk=public&sid=abcdef12&sni=www.example.com&flow=xtls-rprx-vision&type=tcp",
                      "?pbk=public&sid=abcdef12&sni=www.example.com"):
            with self.subTest(query=query):
                result = bash(f'''ensure_python3() {{ :; }}
parse_proxy_link {shlex.quote(base + query)} imported >/dev/null
echo "$imported"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    "type": "vless-reality", "server": "proxy.example.com", "port": 443,
                    "uuid": uuid, "public_key": "public", "short_id": "abcdef12", "server_name": "www.example.com"})

    def test_plain_vless_state_and_uuid_option_are_no_longer_supported(self):
        state, output = self.directory / "state.json", self.directory / "config.json"
        plain = {"type": "vless", "server": "proxy.example.com", "port": 443,
                 "uuid": "bf000d23-0752-40b4-affe-68f7707a9661"}
        for field in ("protocol", "outbound", "backup_outbounds"):
            with self.subTest(field=field):
                node = self.dns_node()
                node["uuid"] = plain["uuid"]
                node[field] = "vless" if field == "protocol" else plain if field == "outbound" else [plain]
                state.write_text(json.dumps({"nodes": [node]}))
                result = bash(f'generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
        result = bash(f"parse_options --uuid {plain['uuid']}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未知参数：--uuid", result.stderr)

    def test_reality_config_generation_keeps_inbound_outbound_and_client_fields(self):
        node = self.dns_node()
        node.update(protocol="vless-reality", uuid="bf000d23-0752-40b4-affe-68f7707a9661",
                    reality={"private_key": "private", "public_key": "public", "short_id": "abcdef12",
                             "handshake_server": "www.example.com", "handshake_port": 443})
        node["outbound"] = {"type": "vless-reality", "server": "proxy.example.com", "port": 443,
                            "uuid": node["uuid"], "public_key": "public", "short_id": "abcdef12",
                            "server_name": "www.example.com"}
        state, output = self.directory / "state.json", self.directory / "config.json"
        state.write_text(json.dumps({"nodes": [node]}))
        result = bash(f'generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(output.read_text())
        inbound = config["inbounds"][0]
        outbound = next(item for item in config["outbounds"] if item["tag"] == "out-1")
        self.assertEqual(inbound["users"][0]["flow"], "xtls-rprx-vision")
        self.assertEqual(inbound["tls"]["reality"]["private_key"], "private")
        self.assertEqual(outbound["flow"], "xtls-rprx-vision")
        self.assertEqual(outbound["tls"]["reality"]["public_key"], "public")
        result = bash(f'generate_client_outbound_json {shlex.quote(json.dumps(node))}')
        self.assertEqual(result.returncode, 0, result.stderr)
        client = json.loads(result.stdout)
        self.assertEqual(client["flow"], "xtls-rprx-vision")
        self.assertEqual(client["tls"]["reality"]["public_key"], "public")

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

    def test_tfo_preserves_existing_value_without_prompt_and_checks_kernel_read_only(self):
        result = bash('''prompt_choice() { exit 99; }
collect_ss_tfo_settings '{"tcp_fast_open":true}'
echo "$SS_TFO"
sysctl() { [[ "$1" == "-n" ]] || return 99; echo 1; }
warn_ss_tfo_support''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")
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

    def ss_outbound(self, flag=None):
        outbound = {"type": "shadowsocks", "server": "example.com", "port": 8388,
                    "method": "aes-128-gcm", "password": "test"}
        if flag is not None:
            outbound["tcp_fast_open"] = flag
        return outbound

    def test_ss_link_import_needs_one_input_and_can_cancel_before_import(self):
        credentials = base64.urlsafe_b64encode(b"aes-128-gcm:test").decode().rstrip("=")
        link = f"ss://{credentials}@example.com:8388#SS"
        for value in (link, "0"):
            with self.subTest(value=value):
                result = bash(f'''ensure_python3() {{ :; }}
imported=unchanged
if collect_outbound_settings '{{}}' imported <<< {shlex.quote(value)}; then
  echo "$imported"
else
  echo "$imported"
fi''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("TCP Fast Open", result.stdout + result.stderr)
                self.assertNotIn("确认使用", result.stdout + result.stderr)
                output = result.stdout.splitlines()[-1]
                if value == "0":
                    self.assertEqual(output, "unchanged")
                else:
                    self.assertEqual(json.loads(output), self.ss_outbound(False))

    def test_outbound_tfo_cli_import_paths_and_inbound_flags_are_independent(self):
        link = "ss://" + base64.b64encode(b"aes-128-gcm:test@example.com:8388").decode()
        for via_menu in (False, True):
            for option, expected in (("", False), ("--ss-outbound-tfo", True), ("--no-ss-outbound-tfo", False)):
                with self.subTest(via_menu=via_menu, option=option):
                    selector = (f'OUTBOUND=direct\nchoose_outbound_protocol() {{ printf -v "$1" \'%s\' {shlex.quote(link)}; }}'
                                if via_menu else f'OUTBOUND={shlex.quote(link)}')
                    result = bash(f'''NON_INTERACTIVE=1
ensure_python3() {{ :; }}
parse_options --ss-tfo {option}
{selector}
collect_outbound_settings '{{}}' imported
printf '%s\\n' "$imported"
printf '%s\\n' "$SS_TFO"''')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout.splitlines()[-2]), self.ss_outbound(expected))
                    self.assertEqual(result.stdout.splitlines()[-1], "true")

    def test_manual_and_reimported_ss_outbounds_keep_per_export_choice(self):
        link = "ss://" + base64.urlsafe_b64encode(b"aes-128-gcm:test").decode() + "@example.com:8388"
        primary = self.ss_outbound(True)
        backup = self.ss_outbound(False)
        for field, expected in (("outbound", True), ("backup", False)):
            for import_link in (False, True):
                with self.subTest(field=field, import_link=import_link):
                    old = {"outbound": primary, "backup": backup}
                    result = bash(f'''NON_INTERACTIVE=1
ensure_python3() {{ :; }}
OUTBOUND={shlex.quote(link) if import_link else "shadowsocks"}
collect_outbound_settings {shlex.quote(json.dumps(old))} imported {field}
printf '%s\\n' "$imported"''')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout.splitlines()[-1]), self.ss_outbound(expected))
        result = bash(f'''NON_INTERACTIVE=1
ensure_python3() {{ :; }}
OUTBOUND={shlex.quote(link)}
collect_outbound_settings {shlex.quote(json.dumps({"outbound": primary}))} imported backup
printf '%s\\n' "$imported"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1]), backup)

    def test_non_ss_outbound_does_not_prompt_or_receive_tfo(self):
        result = bash('''NON_INTERACTIVE=1
parse_options --ss-outbound-tfo
OUTBOUND=direct
collect_outbound_settings '{}' imported
printf '%s\\n' "$imported"''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"type": "direct"})
        self.assertNotIn("出站 TCP Fast Open", result.stderr)

    def test_outbound_tfo_generation_and_validation_cover_primary_and_backup(self):
        state = self.directory / "state.json"
        output = self.directory / "config.json"
        for field in ("outbound", "backup_outbounds"):
            for flag in ("missing", False, True, "true", None, 1):
                with self.subTest(field=field, flag=flag):
                    outbound = self.ss_outbound()
                    if flag != "missing":
                        outbound["tcp_fast_open"] = flag
                    node = {"name": "SS", "protocol": "shadowsocks", "domain": "example.com", "port": 443,
                            "method": "aes-128-gcm", "password": "test", "tcp_fast_open": False,
                            "traffic": {"monthly_limit": "unlimited"}, "outbound": self.ss_outbound(False),
                            "backup_outbounds": []}
                    node[field] = outbound if field == "outbound" else [outbound]
                    state.write_text(json.dumps({"nodes": [node]}))
                    result = bash(f'''ensure_outbound_health_secret() {{ echo test; }}
generate_config_from_state {shlex.quote(str(output))} {shlex.quote(str(state))}''')
                    valid = flag == "missing" or isinstance(flag, bool)
                    self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
                    if valid:
                        config = json.loads(output.read_text())
                        tag = "out-1" if field == "outbound" else "backup-1-1"
                        selected = next(item for item in config["outbounds"] if item["tag"] == tag)
                        self.assertIs(selected["tcp_fast_open"], flag is True)
                        self.assertFalse(config["inbounds"][0]["tcp_fast_open"])

    def test_outbound_menu_edit_preserves_selected_backup_and_reorder_keeps_flags(self):
        primary, backup = self.ss_outbound(False), self.ss_outbound(True)
        backup["server"] = "backup.example.com"
        node = {"name": "测试", "port": 443, "outbound": primary, "backup_outbounds": [backup]}
        nodes = self.directory / "nodes.json"
        nodes.write_text(json.dumps([node]))
        setup = f'''NON_INTERACTIVE=1
current_nodes_json() {{ cat {shlex.quote(str(nodes))}; }}
save_nodes_json() {{ printf '%s' "$1" > {shlex.quote(str(nodes))}; }}
'''
        result = bash(setup + '''manage_single_node_outbounds 0 < <(printf '2\\n2\\n0\\n')''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(nodes.read_text())[0]["backup_outbounds"], [backup])
        self.assertNotIn("TFO", result.stdout)
        result = bash(setup + '''manage_single_node_outbounds 0 < <(printf '4\\n2\\n1\\n0\\n')''')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads(nodes.read_text())[0]
        self.assertEqual(saved["outbound"], backup)
        self.assertEqual(saved["backup_outbounds"], [primary])

    def test_client_and_server_kernel_tfo_bits_are_checked_read_only(self):
        for value in (0, 1, 2, 3, "unknown"):
            for side, bit in (("client", 1), ("server", 2)):
                with self.subTest(value=value, side=side):
                    result = bash(f'''sysctl() {{ [[ "$1" == -n ]] || return 99; echo {value}; }}
warn_ss_tfo_support {side}''')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected_warning = not isinstance(value, int) or (value & bit) == 0
                    self.assertEqual(bool(result.stderr), expected_warning)
                    if expected_warning and isinstance(value, int):
                        self.assertIn("客户端" if side == "client" else "服务端", result.stderr)

    def test_dependency_transaction_is_not_repeated_and_download_options_are_scoped(self):
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
        for call in calls:
            self.assertIn("Acquire::Retries=3", call)
            self.assertIn("Acquire::http::Timeout=30", call)
            self.assertIn("Acquire::https::Timeout=30", call)
        self.assertIn("软件源、网络", result.stderr)
        self.assertNotIn("不应安装核心", result.stdout)

    def test_apt_download_options_do_not_mask_errors_or_persist(self):
        for operation in ("update", "install", "download"):
            with self.subTest(operation=operation):
                log = self.directory / ("apt-options-" + operation)
                result = bash(f'''apt-get() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; return 42; }}
apt_get_minimal {operation}''')
                self.assertEqual(result.returncode, 42, result.stderr)
                calls = log.read_text().splitlines()
                self.assertEqual(len(calls), 1)
                args = shlex.split(calls[0])
                self.assertEqual(args[-1], operation)
                self.assertEqual(args[::2][:-1], ["-o"] * 8)
                self.assertNotIn("--fix-missing", args)
                self.assertNotIn("--allow-unauthenticated", args)

    def test_update_skips_package_manager_when_dependencies_are_installed(self):
        for manager in ("apt", "dnf", "yum", "apk"):
            with self.subTest(manager=manager):
                result = bash(f'''detect_os() {{ PKG_MGR={manager}; }}
dpkg-query() {{ printf 'install ok installed'; }}
rpm() {{ return 0; }}
apt-get() {{ echo 不应调用APT >&2; return 99; }}
dnf() {{ echo 不应调用DNF >&2; return 99; }}
yum() {{ echo 不应调用YUM >&2; return 99; }}
apk() {{ [[ "$1" == info ]] || {{ echo 不应安装APK依赖 >&2; return 99; }}; }}
systemctl() {{ :; }}
rc-update() {{ :; }}
rc-service() {{ :; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_dependencies update''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertIn("依赖齐全", result.stdout)

    def test_apt_update_installs_only_missing_or_incomplete_dependencies(self):
        log = self.directory / "apt-missing"
        result = bash(f'''detect_os() {{ PKG_MGR=apt; }}
dpkg-query() {{
  case "$3" in
    jq) printf 'deinstall ok config-files' ;;
    python3) return 1 ;;
    *) printf 'install ok installed' ;;
  esac
}}
apt-get() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_dependencies update''')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn(" update ", calls[0])
        install_args = shlex.split(calls[1])
        install_args = install_args[install_args.index("install") + 1:]
        self.assertEqual(install_args, ["-y", "--no-install-recommends", "--no-upgrade", "jq", "python3"])

    def test_rpm_and_apk_update_install_only_missing_dependencies(self):
        for manager in ("dnf", "yum", "apk"):
            with self.subTest(manager=manager):
                log = self.directory / (manager + "-missing")
                result = bash(f'''detect_os() {{ PKG_MGR={manager}; }}
rpm() {{ [[ "$2" != jq ]]; }}
dnf() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; }}
yum() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; }}
apk() {{
  if [[ "$1" == info ]]; then [[ "$3" != jq ]];
  else printf '%s\\n' "$*" >> {shlex.quote(str(log))}; fi
}}
systemctl() {{ :; }}
rc-update() {{ :; }}
rc-service() {{ :; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_dependencies update''')
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = log.read_text().splitlines()
                if manager == "apk":
                    self.assertEqual(calls, ["add --no-cache jq"])
                else:
                    self.assertEqual(calls, ["--setopt=keepcache=0 install -y epel-release",
                                             "--setopt=keepcache=0 install -y jq"])

    def test_update_index_failure_stops_before_core_download(self):
        log = self.directory / "failed-update"
        result = bash(f'''preflight() {{ :; }}
detect_os() {{ PKG_MGR=apt; }}
dpkg-query() {{ [[ "$3" != jq ]] && printf 'install ok installed'; }}
apt-get() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; return 1; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_singbox_binary() {{ echo 不应下载核心; }}
upgrade_sing_box''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(log.read_text().splitlines()), 1)
        self.assertNotIn("不应下载核心", result.stdout)

    def test_initial_install_keeps_full_dependencies_and_installs_core_once(self):
        log = self.directory / "initial-install"
        result = bash(f'''detect_os() {{ PKG_MGR=apt; }}
dpkg-query() {{ echo 首次安装不应筛选依赖 >&2; return 99; }}
apt-get() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; }}
ensure_certbot_environment() {{ :; }}
ensure_time_sync_service() {{ :; }}
install_singbox_binary() {{ echo 安装核心; }}
install_dependencies_and_core''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.count("安装核心"), 1)
        calls = log.read_text().splitlines()
        args = shlex.split(calls[1])
        self.assertEqual(args[args.index("install") + 1:],
                         ["-y", "--no-install-recommends", "ca-certificates", "curl", "gnupg", "jq",
                          "openssl", "certbot", "iproute2", "nftables", "cron", "python3", "tar", "gzip"])

    def test_upgrade_downloads_core_once_without_reinstalling_dependencies(self):
        env = dict(os.environ, CONFIG_FILE=str(self.directory / "absent-config.json"))
        result = bash('''preflight() { :; }
detect_os() { PKG_MGR=apt; }
dpkg-query() { printf 'install ok installed'; }
apt-get() { echo 不应安装依赖 >&2; return 99; }
ensure_certbot_environment() { :; }
ensure_time_sync_service() { :; }
install_singbox_binary() { printf '下载核心:%s\\n' "${1:-}"; }
migrate_outbound_health_config() { :; }
sync_outbound_health_service() { :; }
update_self_script() { :; }
sing-box() { echo 'sing-box version test'; }
upgrade_sing_box''', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith("下载核心:")],
                         ["下载核心:FORCE"])

    def same_version_update_in_terminal(self, mode, non_interactive=0):
        code = f'''source {shlex.quote(str(SCRIPT))}
[[ -t 0 ]] || exit 99
require_root() {{ :; }}
curl() {{
  [[ "$*" == *purge.jsdelivr.net* ]] && return 0
  cp {shlex.quote(str(SCRIPT))} "${{@: -1}}"
}}
NON_INTERACTIVE={non_interactive}
update_self_script {shlex.quote(mode)}
printf '更新检查已返回\\n'
'''
        master, slave = pty.openpty()
        process = subprocess.Popen(["bash", "-c", code], stdin=slave, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        os.close(slave)
        self.addCleanup(os.close, master)

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate()

        self.addCleanup(cleanup)
        return process, master

    def test_silent_same_version_check_returns_without_terminal_input(self):
        for mode in ("silent", "quiet"):
            with self.subTest(mode=mode):
                process, _ = self.same_version_update_in_terminal(mode)
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn("更新检查已返回", stdout)
                self.assertNotIn("是否重新强制", stderr)

    def test_non_interactive_same_version_check_does_not_prompt_on_terminal(self):
        process, _ = self.same_version_update_in_terminal("cli", non_interactive=1)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("更新检查已返回", stdout)
        self.assertNotIn("是否重新强制", stderr)

    def test_manual_same_version_check_keeps_force_reinstall_prompt(self):
        for mode in ("cli", "menu"):
            with self.subTest(mode=mode):
                process, master = self.same_version_update_in_terminal(mode)
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.communicate(timeout=0.3)
                os.write(master, b"\n")
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn("更新检查已返回", stdout)
                self.assertIn("是否重新强制拉取", stderr)

    def test_generated_api_script_and_old_service_migration(self):
        state_dir = self.directory / "state"
        env = dict(os.environ, STATE_DIR=str(state_dir))
        result = bash('install_api_server_script', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        api_path = state_dir / "api/http_server.py"
        api = module(api_path.read_text())
        self.assertTrue(callable(api.get_traffic_snapshot))
        self.assertEqual(api.TRAFFIC_COLLECTOR_VERSION, 2)
        for old in ("old script", "def get_traffic_snapshot():\n    pass\n", "TRAFFIC_COLLECTOR_VERSION = 1\n"):
            for running in (True, False):
                with self.subTest(running=running, old=old):
                    api_path.write_text(old)
                    result = bash(f'''ensure_api_service_file() {{ :; }}
service_is_running() {{ return {0 if running else 1}; }}
service_restart() {{ echo 重启; }}
refresh_api_service
refresh_api_service''', env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.splitlines(), ["重启"] if running else [])
                    self.assertEqual(module(api_path.read_text()).TRAFFIC_COLLECTOR_VERSION, 2)

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

    def test_download_fallback_uses_fresh_stream_and_longer_timeout(self):
        log = self.directory / "downloads"
        archive = shlex.quote(str(self.directory / "core.tar.gz"))
        extra = f'''curl() {{
  printf '%s\\n' "$*" >> {shlex.quote(str(log))}
  if [[ "$*" == *gh.zyun.vip* ]]; then head -c 30 {archive}; return 28; fi
  cat {archive}
}}'''
        result, core = self.installation(b"#!/bin/sh\necho 'sing-box version 1.14.2'\n", extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.14.2", core.read_text())
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn("gh.zyun.vip/https://github.com/", calls[0])
        self.assertTrue(all("--max-time 600 --speed-limit 1024 --speed-time 30" in call for call in calls))
        self.assertNotIn("gh.zyun.vip", calls[1])
        self.assertNotIn("mirror.ghproxy.com", "\n".join(calls))

    def test_custom_mirror_and_timeout(self):
        log = self.directory / "downloads"
        archive = shlex.quote(str(self.directory / "core.tar.gz"))
        extra = f'''SBOX_DOWNLOAD_MIRROR=https://mirror.example/
SBOX_DOWNLOAD_TIMEOUT=1200
curl() {{ printf '%s\\n' "$*" >> {shlex.quote(str(log))}; cat {archive}; }}'''
        result, _ = self.installation(b"#!/bin/sh\necho 'sing-box version 1.14.2'\n", extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertIn("https://mirror.example/https://github.com/", calls[0])
        self.assertIn("--max-time 1200", calls[0])

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
