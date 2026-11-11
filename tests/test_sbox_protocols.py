"""所有协议的本地契约回归；不安装依赖，不访问网络、服务或真实配置。"""
import base64
import json
import os
from pathlib import Path
import shlex
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

from test_sbox import SOURCE, bash


def nodes():
    key = base64.b64encode(bytes(range(16))).decode()
    password = 'sample +/%:@?#=中文'
    base = {"name": "测试 节点/#", "domain": "2001:db8::1", "port": 15608,
            "password": password, "traffic": {"monthly_limit": "unlimited"},
            "outbound": {"type": "direct"}}
    return [
        {**base, "protocol": "anytls"},
        {**base, "protocol": "trojan"},
        {**base, "protocol": "hysteria2"},
        {**base, "protocol": "shadowsocks", "method": "aes-128-gcm"},
        {**base, "protocol": "shadowsocks", "method": "2022-blake3-aes-128-gcm", "password": key},
        {**base, "protocol": "shadowsocks-shadowtls", "method": "2022-blake3-aes-128-gcm", "password": key,
         "shadowtls": {"version": 3, "password": password, "server_name": "www.microsoft.com",
                       "handshake_server": "www.microsoft.com", "handshake_port": 443, "strict_mode": True}},
        {**base, "protocol": "vless-reality", "uuid": "11111111-1111-4111-8111-111111111111",
         "reality": {"private_key": "test-private", "public_key": "test-public", "short_id": "abcd",
                     "handshake_server": "www.microsoft.com", "handshake_port": 443}},
        {**base, "protocol": "socks5", "username": "user:+/@中文"},
        {**base, "protocol": "http", "username": "user:+/@中文", "tls": False},
        {**base, "protocol": "http", "username": "user:+/@中文", "tls": True},
    ]


class ProtocolTests(unittest.TestCase):
    def test_client_fingerprint_defaults_to_safari_and_preserves_explicit_values(self):
        for proto in ("vless-reality", "shadowsocks-shadowtls"):
            for fingerprint in (None, "firefox", "chrome"):
                with self.subTest(protocol=proto, fingerprint=fingerprint):
                    node = next(item for item in nodes() if item["protocol"] == proto)
                    if fingerprint is not None:
                        node["client-fingerprint"] = fingerprint
                    result = bash(f'generate_client_outbound_json {shlex.quote(json.dumps(node))}')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    client = json.loads(result.stdout)
                    if isinstance(client, list):
                        client = client[1]
                    self.assertEqual(client["tls"]["utls"], {"enabled": True, "fingerprint": fingerprint or "safari"})
                    if proto == "vless-reality":
                        result = bash(f'generate_share_link {shlex.quote(json.dumps(node))}')
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(parse_qs(urlsplit(result.stdout.strip()).query)["fp"], [fingerprint or "safari"])

    def test_reality_keypair_parsing_without_positional_arguments(self):
        result = bash('''sing-box() {
  [[ "$*" == "generate reality-keypair" ]] || return 99
  printf '%s\\n' 'PrivateKey: test-private' 'PublicKey: test-public'
}
generate_reality_keypair''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "test-private test-public")
        self.assertEqual(result.stderr, "")

    def test_reality_settings_default_and_existing_handshake_domain(self):
        for server in (None, "www.microsoft.com", "www.example.com"):
            with self.subTest(server=server):
                old = {"uuid": "11111111-1111-4111-8111-111111111111",
                       "reality": {"private_key": "test-private", "public_key": "test-public",
                                   "short_id": "abcd", "handshake_port": 8443}}
                if server is not None:
                    old["reality"]["handshake_server"] = server
                result = bash(f'''NON_INTERACTIVE=1
collect_reality_settings {shlex.quote(json.dumps(old))}
printf '%s\\n' "$NODE_UUID" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$REALITY_HANDSHAKE_SERVER" "$REALITY_HANDSHAKE_PORT"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [old["uuid"], "test-private", "test-public",
                                                              "abcd", server or "www.iq.com", "8443"])

    def test_switch_anytls_to_reality_generates_keys_and_keeps_node_settings(self):
        original = nodes()[:2]
        original[1]["port"] += 1
        original[0]["dns"] = {"mode": "custom", "server": "8.8.8.8"}
        original[0]["backup_outbounds"] = [{"type": "direct"}]
        with tempfile.TemporaryDirectory() as directory:
            saved_file = Path(directory) / "nodes.json"
            inputs = "6\n" + "\n" * 7
            result = bash(f'''current_nodes_json() {{ printf '%s\\n' {shlex.quote(json.dumps(original))}; }}
sing-box() {{ printf '%s\\n' 'PrivateKey: test-private' 'PublicKey: test-public'; }}
ensure_node_certificate() {{ return 0; }}
firewall_remove_port() {{ :; }}
save_nodes_json() {{ printf '%s\\n' "$1" > {shlex.quote(str(saved_file))}; }}
edit_node_protocol 0 <<< {shlex.quote(inputs)}''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("unbound variable", result.stderr)
            self.assertNotIn("[警告]", result.stderr)
            saved = json.loads(saved_file.read_text())
        node = saved[0]
        self.assertEqual(node["protocol"], "vless-reality")
        self.assertEqual(node["reality"]["private_key"], "test-private")
        self.assertEqual(node["reality"]["public_key"], "test-public")
        self.assertEqual(node["reality"]["handshake_server"], "www.iq.com")
        self.assertEqual(node["reality"]["handshake_port"], 443)
        for key in ("name", "domain", "port", "dns", "traffic", "outbound", "backup_outbounds"):
            self.assertEqual(node[key], original[0][key], key)
        self.assertEqual(saved[1], original[1])

    def test_reality_outbound_default_and_existing_sni(self):
        for server in (None, "www.microsoft.com"):
            with self.subTest(server=server):
                outbound = {"type": "vless-reality", "server": "proxy.example.com", "port": 443,
                            "uuid": "11111111-1111-4111-8111-111111111111",
                            "public_key": "test-public", "short_id": "abcd"}
                if server is not None:
                    outbound["server_name"] = server
                result = bash(f'''NON_INTERACTIVE=1
OUTBOUND=vless-reality
collect_outbound_settings {shlex.quote(json.dumps({"outbound": outbound}))} result
printf '%s\\n' "$result"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {**outbound, "server_name": server or "www.iq.com"})

    def test_script_update_rejects_older_or_invalid_versions_before_install(self):
        for version, status in [("0.0.1", 0), ("invalid", 1)]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                remote = Path(directory) / "remote.sh"
                remote.write_text(f'#!/bin/bash\nreadonly SCRIPT_VERSION="{version}"\n')
                result = bash(f'''require_root() {{ :; }}
curl() {{
  [[ "$*" == *purge.jsdelivr.net* ]] && return 0
  cp {shlex.quote(str(remote))} "${{@: -1}}"
}}
install() {{ echo unexpected-install >&2; return 99; }}
FORCE_UPDATE=1
update_self_script silent''')
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertNotIn("unexpected-install", result.stderr)
                self.assertIn("跳过降级" if status == 0 else "版本格式无效", result.stdout + result.stderr)

    def test_all_share_links_roundtrip_special_credentials_and_ipv6(self):
        for node in nodes():
            with self.subTest(protocol=node["protocol"], method=node.get("method"), tls=node.get("tls")):
                encoded = shlex.quote(json.dumps(node))
                result = bash(f'''ensure_python3() {{ :; }}
node={encoded}
generate_share_link "$node"
generate_client_outbound_json "$node" | jq -c .
parse_proxy_link "$(generate_share_link "$node")" parsed >/dev/null
printf '%s\\n' "$parsed"''')
                self.assertEqual(result.returncode, 0, result.stderr)
                uri, client, imported = result.stdout.splitlines()
                client, imported = json.loads(client), json.loads(imported)
                self.assertEqual(urlsplit(uri).hostname, node["domain"])
                self.assertEqual(imported["server"], node["domain"])
                self.assertEqual(imported["port"], node["port"])
                self.assertEqual(imported["type"], node["protocol"])
                self.assertEqual(imported.get("password"), None if node["protocol"] == "vless-reality" else node["password"])
                if node.get("username"):
                    self.assertEqual(imported["username"], node["username"])
                if isinstance(client, list):
                    self.assertEqual(client[0]["password"], node["password"])
                    self.assertEqual(client[1]["password"], node["shadowtls"]["password"])
                    self.assertEqual(imported["shadowtls"]["password"], node["shadowtls"]["password"])
                elif node["protocol"] != "vless-reality":
                    self.assertEqual(client["password"], node["password"])
                if node["protocol"] in ("anytls", "trojan", "hysteria2"):
                    self.assertTrue(client["tls"]["enabled"])
                    self.assertEqual(client["tls"]["server_name"], node["domain"])

    def test_all_inbounds_and_primary_backup_outbounds_generate_together(self):
        fixture = nodes()
        outbounds = [{"type": "direct"}]
        for node in fixture:
            out = {"type": node["protocol"], "server": "proxy.example.com", "port": 443}
            for key in ("password", "method", "username", "shadowtls", "uuid"):
                if key in node:
                    out[key] = node[key]
            if node["protocol"] == "vless-reality":
                out.update(public_key="test-public", short_id="abcd", server_name="www.microsoft.com")
            if node["protocol"] == "http":
                out["tls"] = {"enabled": node["tls"], "server_name": "proxy.example.com"}
            outbounds.append(out)
        fixture.append({**fixture[0]})
        for index, node in enumerate(fixture):
            node.update(name=f"节点{index}", port=20000 + index, outbound=outbounds[index],
                        backup_outbounds=outbounds[1:])
        with tempfile.TemporaryDirectory() as directory:
            state, config = Path(directory) / "state.json", Path(directory) / "config.json"
            state.write_text(json.dumps({"version": 3, "nodes": fixture}))
            result = bash(f'''sing-box() {{ echo 'sing-box version 1.14.4'; }}
ensure_outbound_health_secret() {{ echo test-secret; }}
generate_config_from_state {shlex.quote(str(config))} {shlex.quote(str(state))}''',
                          env=dict(os.environ, STATE_DIR=directory, PADDING_CONF_FILE=directory + "/absent"))
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(config.read_text())
        tags = [out["tag"] for out in output["outbounds"]]
        self.assertEqual(len(tags), len(set(tags)))
        for node in fixture:
            public = [inbound for inbound in output["inbounds"] if inbound.get("listen_port") == node["port"]]
            self.assertTrue(public, node["protocol"])
        self.assertTrue({"anytls", "trojan", "hysteria2", "shadowsocks", "shadowtls", "vless", "socks", "http", "direct", "selector"}.issubset({out["type"] for out in output["outbounds"]}))
        for outbound in output["outbounds"]:
            if outbound["type"] == "vless":
                self.assertEqual(outbound["tls"]["utls"], {"enabled": True, "fingerprint": "safari"})

    def test_unsupported_link_options_fail_instead_of_silent_downgrade(self):
        uris = [
            "trojan://secret@example.com:443?type=ws",
            "anytls://secret@example.com:443?security=reality",
            "trojan://secret@example.com:443?insecure=1",
            "hy2://secret@example.com:443?obfs=salamander&obfs-password=secret",
            "ss://YWVzLTEyOC1nY206c2VjcmV0@example.com:443?plugin=v2ray-plugin",
            "ss://YWVzLTEyOC1nY206c2VjcmV0@example.com:443?shadow-tls-sni=www.example.com",
            "anytls://secret@example.com:0",
            "trojan://secret@example.com:443?sni=a.example&sni=b.example",
        ]
        for uri in uris:
            with self.subTest(uri=uri):
                result = bash(f'ensure_python3() {{ :; }}\nparse_proxy_link {shlex.quote(uri)} parsed')
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('"password":', result.stdout)

    def test_openrc_supervisor_applies_to_all_protocols(self):
        start = SOURCE.index("ensure_service_file() {")
        end = SOURCE.index("\nsync_time_immediately()", start)
        with tempfile.TemporaryDirectory() as directory:
            function = SOURCE[start:end].replace("/etc/init.d/sing-box", directory + "/sing-box").replace("/var/lib/sing-box", directory + "/data").replace("/var/log", directory + "/log")
            result = bash(function + '\nINIT_SYSTEM=openrc\nrc-update() { :; }\nensure_service_file')
            self.assertEqual(result.returncode, 0, result.stderr)
            service = (Path(directory) / "sing-box").read_text()
            self.assertIn('supervisor="supervise-daemon"', service)
            self.assertIn("respawn_max=5", service)
            self.assertIn("respawn_period=60", service)
            self.assertNotIn("command_background=", service)
            self.assertEqual(bash('bash -n ' + shlex.quote(str(Path(directory) / "sing-box"))).returncode, 0)

    def test_core_upgrade_rolls_back_start_failure_and_preserves_stopped_service(self):
        start = SOURCE.index("upgrade_sing_box() (")
        end = SOURCE.index("\nsize_to_bytes()", start)
        old_program = '#!/bin/sh\necho "sing-box version old"\n'
        for package_install, running, failure in [(False, True, True), (True, True, True), (False, False, False), (False, True, False), (False, True, "download")]:
            with self.subTest(package_install=package_install, running=running, failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                local_bin, system_bin = root / "local", root / "system"
                local_bin.mkdir()
                system_bin.mkdir()
                original = (system_bin if package_install else local_bin) / "sing-box"
                original.write_text(old_program)
                original.chmod(0o755)
                if not package_install:
                    (system_bin / "sing-box").symlink_to(original)
                config = root / "config.json"
                config.write_text("{}")
                restart_log = root / "restart.log"
                function = SOURCE[start:end].replace("/usr/local/bin", str(local_bin)).replace("/usr/bin", str(system_bin))
                result = bash(function + f'''
preflight() {{ :; }}
install_dependencies() {{ :; }}
service_is_running() {{ return {0 if running else 1}; }}
service_stop() {{ :; }}
service_restart() {{
  sing-box version >> {shlex.quote(str(restart_log))}
  {"! sing-box version | grep -q new" if failure is True else ":"}
}}
sleep() {{ :; }}
migrate_outbound_health_config() {{ :; }}
sync_outbound_health_service() {{ :; }}
update_self_script() {{ :; }}
install_singbox_binary() {{
  {"return 1" if failure == "download" else ":"}
  printf '%s\\n' '#!/bin/sh' 'echo "sing-box version new"' > {shlex.quote(str(local_bin / "candidate"))}
  chmod 755 {shlex.quote(str(local_bin / "candidate"))}
  mv {shlex.quote(str(local_bin / "candidate"))} {shlex.quote(str(local_bin / "sing-box"))}
  ln -sf {shlex.quote(str(local_bin / "sing-box"))} {shlex.quote(str(system_bin / "sing-box"))}
}}
upgrade_sing_box''', env=dict(os.environ, PATH=str(local_bin) + ":" + str(system_bin) + ":" + os.environ["PATH"], CONFIG_FILE=str(config)))
                if failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(original.read_text(), old_program)
                    if package_install:
                        self.assertFalse((local_bin / "sing-box").exists())
                        self.assertFalse(original.is_symlink())
                    else:
                        self.assertTrue((system_bin / "sing-box").is_symlink())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("new", (local_bin / "sing-box").read_text())
                if not running or failure == "download":
                    self.assertFalse(restart_log.exists())
                self.assertEqual(list(local_bin.glob(".sbox-upgrade.*")), [])


if __name__ == "__main__":
    unittest.main()
