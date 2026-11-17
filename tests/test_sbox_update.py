"""脚本更新隔离回归：仅临时目录，模拟下载、核心和服务，不连接真实服务器。"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

from test_sbox import SOURCE, bash
from test_sbox_protocols import nodes


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state.json"
        self.config = self.root / "config.json"
        self.padding = self.root / "padding.conf"
        self.log = self.root / "calls"
        self.env = dict(os.environ, STATE_DIR=str(self.root), STATE_FILE=str(self.state),
                        CONFIG_DIR=str(self.root), CONFIG_FILE=str(self.config),
                        PADDING_CONF_FILE=str(self.padding), TEST_ROOT=str(self.root),
                        OUTBOUND_HEALTH_RUNTIME_DIR=str(self.root / "runtime"))
        self.stubs = '''
require_root() { :; }
detect_os() { :; }
migrate_legacy_state() { :; }
ensure_service_file() { CORE_SERVICE_FILE_CHANGED=0; }
install_deploy_hook() { echo hook >> "$TEST_ROOT/calls"; }
sync_traffic_cron() { echo cron >> "$TEST_ROOT/calls"; }
sync_outbound_health_service() { echo "health $*" >> "$TEST_ROOT/calls"; }
refresh_api_service() { echo api >> "$TEST_ROOT/calls"; }
is_ntp_service_active() { return 0; }
ensure_time_sync_service() { echo FORBIDDEN >> "$TEST_ROOT/calls"; return 99; }
sync_traffic_rules() { echo FORBIDDEN >> "$TEST_ROOT/calls"; return 99; }
auto_heal_service() { echo FORBIDDEN >> "$TEST_ROOT/calls"; return 99; }
ensure_sbox_cli() { :; }
service_is_running() { [[ -f "$TEST_ROOT/running-${1:-$SYSTEMD_SERVICE}" ]]; }
service_restart() {
  echo "restart $1" >> "$TEST_ROOT/calls"
  if [[ "${TEST_FAIL_RESTART:-0}" == 1 && ! -f "$TEST_ROOT/restart-failed" ]]; then
    touch "$TEST_ROOT/restart-failed"; return 1
  fi
  touch "$TEST_ROOT/running-$1"
}
service_start() { echo "start $1" >> "$TEST_ROOT/calls"; touch "$TEST_ROOT/running-$1"; }
service_stop() { echo "stop $1" >> "$TEST_ROOT/calls"; rm -f "$TEST_ROOT/running-$1"; }
service_enable() { echo "enable $1" >> "$TEST_ROOT/calls"; }
service_daemon_reload() { :; }
service_group() { id -gn; }
journalctl() { :; }
sleep() { :; }
sing-box() {
  if [[ "$1" == version ]]; then echo 'sing-box version 1.11.4'; else return "${TEST_CHECK_RESULT:-0}"; fi
}
install() {
  local args=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac
  done
  command install "${args[@]}"
}
'''

    def run_bash(self, code, extra="", env=None):
        return bash(self.stubs + extra + "\n" + code, env or self.env)

    def prepare(self, configured=None, running=True):
        self.state.write_text(json.dumps({"nodes": configured or [nodes()[0]]}))
        self.padding.write_text("stop=1\n0=10-20\n")
        if running:
            (self.root / "running-sing-box.service").touch()
        result = self.run_bash('generate_config_from_state "$CONFIG_FILE"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_unchanged_config_keeps_file_and_does_not_restart(self):
        self.prepare()
        self.config.write_text(json.dumps(json.loads(self.config.read_text()), sort_keys=True))
        before = self.config.stat().st_mtime_ns
        result = self.run_bash("sync_after_script_update\nsync_after_script_update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.config.stat().st_mtime_ns, before)
        self.assertFalse(any(line.startswith(("start ", "stop ", "restart ", "enable ")) for line in self.calls()))
        self.assertNotIn("FORBIDDEN", self.calls())
        self.assertEqual(self.calls().count("health 1 0"), 2)

    def test_padding_and_reality_migrate_with_one_restart_and_keep_custom_rules(self):
        configured = [nodes()[0], nodes()[0], nodes()[6]]
        configured[1]["port"] += 1
        configured[1]["padding_scheme"] = ["stop=1", "0=0-0"]
        configured[2]["port"] += 2
        self.prepare(configured)
        old = json.loads(self.config.read_text())
        del old["inbounds"][2]["tls"]["reality"]["max_time_difference"]
        self.config.write_text(json.dumps(old))
        self.padding.write_text("stop=2\n0=50-80\n1=90-120\n")
        result = self.run_bash("sync_after_script_update\nsync_after_script_update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        saved = json.loads(self.config.read_text())["inbounds"]
        self.assertEqual(saved[0]["padding_scheme"], ["stop=2", "0=50-80", "1=90-120"])
        self.assertEqual(saved[1]["padding_scheme"], configured[1]["padding_scheme"])
        self.assertEqual(saved[2]["tls"]["reality"]["max_time_difference"], "1m")
        self.assertEqual(self.calls().count("restart sing-box.service"), 1)
        self.assertEqual(len(list((self.root / "backups").glob("config.*"))), 1)
        self.assertFalse(any(line.startswith("enable ") for line in self.calls()))
        self.assertNotIn("FORBIDDEN", self.calls())
        state = json.loads(self.state.read_text())["nodes"]
        self.assertEqual(state[2]["uuid"], configured[2]["uuid"])
        self.assertEqual(state[2]["reality"]["private_key"], configured[2]["reality"]["private_key"])

    def test_changed_config_keeps_stopped_service_stopped(self):
        self.prepare(running=False)
        self.padding.write_text("stop=1\n0=50-80\n")
        result = self.run_bash("sync_after_script_update")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["padding_scheme"], ["stop=1", "0=50-80"])
        self.assertFalse(any(line.startswith(("start ", "stop ", "restart ", "enable ")) for line in self.calls()))
        self.assertFalse((self.root / "running-sing-box.service").exists())

    def test_failed_core_check_or_restart_rolls_back_config_and_state(self):
        for failure in ("check", "restart"):
            with self.subTest(failure=failure):
                self.prepare([nodes()[6]])
                (self.root / "running-sbox-outbound-monitor.service").touch()
                old = json.loads(self.config.read_text())
                del old["inbounds"][0]["tls"]["reality"]["max_time_difference"]
                self.config.write_text(json.dumps(old))
                state_before, config_before = self.state.read_bytes(), self.config.read_bytes()
                env = dict(self.env, **({"TEST_CHECK_RESULT": "1"} if failure == "check" else {"TEST_FAIL_RESTART": "1"}))
                result = self.run_bash("sync_after_script_update", env=env)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.state.read_bytes(), state_before)
                self.assertEqual(self.config.read_bytes(), config_before)
                self.assertTrue((self.root / "running-sing-box.service").exists())
                self.assertTrue((self.root / "running-sbox-outbound-monitor.service").exists())

    def test_ntp_check_only_warns_and_updated_menu_skips_repeated_healing(self):
        self.prepare()
        result = self.run_bash('''sync_after_script_update
SBOX_UPDATE_SYNC_DONE=1
preflight
[[ -z "${SBOX_UPDATE_SYNC_DONE:-}" ]]''', extra="is_ntp_service_active() { return 1; }")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("未检测到运行中的校时服务", result.stderr)
        self.assertNotIn("FORBIDDEN", self.calls())

    def test_cron_compares_content_and_preserves_other_jobs(self):
        self.state.write_text(json.dumps({"nodes": [{"traffic": {"reset_day": 1}}]}))
        cron = self.root / "cron"
        other = "0 * * * * /some/other/job\n"
        cron.write_text(other + "0 0 1 * * old # sing-box-traffic-old\n")
        result = bash('''crontab() {
  if [[ "$1" == -l ]]; then cat "$TEST_ROOT/cron";
  else echo write >> "$TEST_ROOT/calls"; cp "$1" "$TEST_ROOT/cron"; fi
}
sync_traffic_cron
sync_traffic_cron''', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["write"])
        self.assertTrue(cron.read_text().startswith(other))
        self.assertEqual(cron.read_text().count("sing-box-traffic"), 1)
        self.assertIn("--check-traffic-reset", cron.read_text())

    def test_known_legacy_files_migrate_once_without_deleting_other_json(self):
        old = self.root / "old"
        old.mkdir()
        (old / "state.json").write_text('{"nodes":[]}')
        (old / "custom.json").write_text('{"keep":true}')
        (old / "backups").mkdir()
        (old / "backups/config.old").write_text("backup")
        start = SOURCE.index("migrate_legacy_state() {")
        migration = SOURCE[start:SOURCE.index("\nis_ntp_service_active()", start)]
        migration = migration.replace("/etc/sing-box", str(old))
        result = bash(migration + '''
migrate_legacy_state
echo later > "''' + str(old / "traffic_data.json") + '''"
migrate_legacy_state''', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.state.exists())
        self.assertTrue((old / "custom.json").exists())
        self.assertTrue((old / "traffic_data.json").exists())
        self.assertTrue((self.root / "backups/config.old").exists())
        self.assertTrue((self.root / "legacy-layout-v1.done").exists())

    def test_hooks_and_auxiliary_scripts_are_not_rewritten_when_unchanged(self):
        result = bash('install_dnspod_hooks\ninstall_cf_hooks\ninstall_api_server_script\ninstall_outbound_health_monitor_script', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = [self.root / name for name in ("dnspod-hook", "dnspod-auth", "dnspod-cleanup",
                 "cf-hook", "cf-auth", "cf-cleanup", "api/http_server.py", "outbound_health_monitor.py")]
        before = [path.stat().st_mtime_ns for path in files]
        result = bash('install_dnspod_hooks\ninstall_cf_hooks\ninstall_api_server_script\ninstall_outbound_health_monitor_script', self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.stat().st_mtime_ns for path in files], before)
        for path in files:
            if path.suffix == ".py":
                compile(path.read_text(), str(path), "exec")
            else:
                self.assertEqual(subprocess.run(["bash", "-n", str(path)], capture_output=True).returncode, 0)

    def test_remote_padding_still_overwrites_local_and_new_script_syncs_once(self):
        self.prepare()
        remote_padding = self.root / "remote-padding.conf"
        remote_padding.write_text("# remote\nstop=2\n0=90-120\n1=130-160\n")
        installed = self.root / "sbox"
        source = SOURCE.replace('readonly SCRIPT_INSTALL_PATH="/usr/local/bin/sbox"',
                                f'readonly SCRIPT_INSTALL_PATH={shlex.quote(str(installed))}')
        source = source.replace('readonly SCRIPT_SYMLINK_PATH="/usr/bin/sbox"',
                                f'readonly SCRIPT_SYMLINK_PATH={shlex.quote(str(self.root / "sbox-link"))}')
        overrides = self.stubs.replace('  local args=()', '''  [[ "$*" != '-d -m 0755 /usr/local/bin /usr/bin' ]] || return 0
  local args=()''') + '''
curl() {
  if [[ "$*" == *purge.jsdelivr.net* ]]; then echo FORBIDDEN >> "$TEST_ROOT/calls"; return 99; fi
  if [[ "$*" == *anytls_padding.conf* ]]; then cp "$TEST_REMOTE_PAD" "${@: -1}";
  else cp "$TEST_REMOTE_SCRIPT" "${@: -1}"; fi
}
'''
        guard = 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'
        remote = self.root / "remote.sh"
        remote.write_text(source.replace(guard, overrides + "\n" + guard))
        old = self.root / "old.sh"
        old.write_text(re.sub(r'^readonly SCRIPT_VERSION="[0-9.]+"', 'readonly SCRIPT_VERSION="0.0.0"',
                              remote.read_text(), count=1, flags=re.MULTILINE).replace(
            guard, 'sync_after_script_update() { die "旧进程不应执行迁移"; }\n' + guard))
        env = dict(self.env, TEST_REMOTE_PAD=str(remote_padding), TEST_REMOTE_SCRIPT=str(remote))
        result = subprocess.run(["bash", "-c", f'source {shlex.quote(str(old))}\nupdate_self_script silent\nupdate_self_script silent'],
                                env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.padding.read_bytes(), remote_padding.read_bytes())
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["padding_scheme"],
                         ["stop=2", "0=90-120", "1=130-160"])
        self.assertEqual(self.calls().count("restart sing-box.service"), 1)
        self.assertEqual(self.calls().count("cron"), 2)
        self.assertNotIn("FORBIDDEN", self.calls())

    def test_auxiliary_unit_changes_restart_only_running_services(self):
        definitions = ""
        for name, following in (("ensure_outbound_health_service_file", "sync_outbound_health_service"),
                                ("ensure_api_service_file", "install_api_service")):
            start = SOURCE.index(name + "() {")
            definitions += SOURCE[start:SOURCE.index("\n" + following + "()", start)]
        units = self.root / "units"
        units.mkdir()
        definitions = definitions.replace("/etc/systemd/system", str(units))
        for running in (False, True):
            with self.subTest(running=running):
                self.log.unlink(missing_ok=True)
                result = self.run_bash(definitions + '''
outbound_health_node_count() { echo 1; }
outbound_health_config_ready() { return 0; }
ensure_outbound_health_secret() { echo fixture; }
ensure_outbound_health_service_file
install_api_server_script
ensure_api_service_file
echo old > "''' + str(units / "sbox-outbound-monitor.service") + '''"
echo old > "''' + str(units / "sbox-api.service") + '''"
echo fixture > "$CONFIG_FILE"
''' + ('''touch "$TEST_ROOT/running-sbox-api.service" "$TEST_ROOT/running-sbox-outbound-monitor.service"
''' if running else "") + f'''
sync_outbound_health_service 1 {1 if running else 0}
refresh_api_service
sync_outbound_health_service 1 {1 if running else 0}
refresh_api_service
''', extra="sync_outbound_health_service() " + SOURCE.split("sync_outbound_health_service() ", 1)[1].split("\noutbound_health_config_ready()", 1)[0]
                    + "\nrefresh_api_service() " + SOURCE.split("refresh_api_service() ", 1)[1].split("\nuninstall_api_service()", 1)[0])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.calls(), ["restart sbox-outbound-monitor.service", "restart sbox-api.service"] if running else [])

    def test_systemd_and_openrc_template_updates_keep_service_disabled_and_stopped(self):
        start = SOURCE.index("ensure_service_file() {")
        definition = SOURCE[start:SOURCE.index("\nsync_time_immediately()", start)]
        for init_system in ("systemd", "openrc"):
            with self.subTest(init_system=init_system):
                self.prepare(running=False)
                self.log.unlink(missing_ok=True)
                unit_dir = self.root / init_system
                unit_dir.mkdir()
                isolated = definition.replace("/etc/systemd/system", str(unit_dir))
                isolated = isolated.replace("/etc/init.d", str(unit_dir))
                isolated = isolated.replace("/var/lib/sing-box", str(self.root / "data"))
                isolated = isolated.replace("/var/log", str(self.root / "logs"))
                extra = f'INIT_SYSTEM={init_system}\n' + isolated
                self.padding.write_text("stop=1\n0=80-120\n")
                result = self.run_bash("sync_after_script_update", extra=extra)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                unit = unit_dir / ("sing-box.service" if init_system == "systemd" else "sing-box")
                self.assertIn(str(self.config), unit.read_text())
                before = unit.stat().st_mtime_ns
                result = self.run_bash("sync_after_script_update", extra=extra)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(unit.stat().st_mtime_ns, before)
                self.assertFalse(any(line.startswith(("enable ", "start ", "stop ", "restart ")) for line in self.calls()))


if __name__ == "__main__":
    unittest.main()
