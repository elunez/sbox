"""隔离测试：配置和快照仅写入临时目录，模拟解析与网络管理命令，不访问网络。"""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "dns-manager.sh"


class DnsManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.resolv = self.root / "resolv.conf"
        self.hook = self.root / "dhcpcd.exit-hook"
        self.state = self.root / "state"
        self.original = "# DHCP\nsearch lan\nnameserver 10.88.0.1\n"
        self.resolv.write_text(self.original)

    def run_script(self, command, success=True):
        variables = {
            "STATE_DIR": self.state,
            "SNAPSHOT_DIR": self.state / "original",
            "RESOLV_CONF": self.resolv,
            "DHCPCD_EXIT_HOOK_FILE": self.hook,
            "LOCK_DIR": self.root / "lock",
        }
        setup = f"source {shlex.quote(str(SCRIPT))}\n"
        setup += "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in variables.items())
        # 所有测试仅显式选择 dhcpcd、dhclient、static 或模拟自动检测。
        # 锁和权限检查不碰真实系统；禁止调用真实网络服务或解析工具。
        setup += """
require_root() { :; }
acquire_lock() { :; }
default_iface() { echo eth0; }
service_active() { return 1; }
getent() { return 0; }
systemctl() { exit 99; }
nmcli() { exit 99; }
resolvectl() { exit 99; }
dhcpcd() { exit 99; }
dhclient() { exit 99; }
resolvconf() { exit 99; }
netconfig() { exit 99; }
"""
        result = subprocess.run(["bash", "-c", setup + command], capture_output=True,
                                text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def apply(self, dns="1.1.1.1 8.8.8.8", extra=""):
        return self.run_script(f"main --backend dhcpcd --set {shlex.quote(dns)} {extra}")

    def run_hook(self, interface="eth0", reason="RENEW"):
        result = subprocess.run(
            ["sh", "-c", 'interface=$1; reason=$2; . "$3"', "sh", interface, reason, str(self.hook)],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_detects_alpine_dhcpcd_process_titles_before_resolvconf(self):
        result = self.run_script("""
have() { case "$1" in dhcpcd|pgrep|resolvconf) return 0;; *) return 1;; esac; }
service_active() { return 1; }
pgrep() {
    [[ "$1" == -f ]] || return 1
    local title
    for title in 'dhcpcd: eth0 [ip4] [ip6]' '/usr/sbin/dhcpcd -q eth0'; do
        [[ "$title" =~ $2 ]] || return 1
    done
}
detect_backend
echo "$BACKEND"
""")
        self.assertEqual(result.stdout.strip(), "dhcpcd")

    def test_active_system_manager_takes_precedence(self):
        for backend, command, service in (("nm", "nmcli", "NetworkManager"),
                                          ("resolved", "resolvectl", "systemd-resolved")):
            with self.subTest(backend=backend):
                result = self.run_script(f"""
have() {{ [[ "$1" == {command} || "$1" == dhcpcd ]]; }}
service_active() {{ [[ "$1" == {service} || "$1" == dhcpcd ]]; }}
detect_backend
echo "$BACKEND"
""")
                self.assertEqual(result.stdout.strip(), backend)

    def test_apply_normalizes_dns_and_preserves_existing_hook(self):
        custom = "# existing hook\ncustom_hook_ran=yes\n"
        self.hook.write_text(custom)
        self.apply("1.1.1.1,8.8.8.8;1.1.1.1")
        self.assertTrue(self.hook.read_text().startswith(custom))
        self.assertEqual(self.hook.read_text().count("# BEGIN DNS-MANAGER"), 1)
        self.assertIn("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", self.resolv.read_text())
        self.assertEqual(self.resolv.stat().st_mode & 0o777, 0o644)
        result = subprocess.run(["sh", "-n", str(self.hook)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dhcp_events_restore_selected_dns_only_on_target_interface(self):
        self.apply()
        expected = self.resolv.read_text()
        for reason in ("BOUND", "RENEW", "REBIND", "REBOOT", "ROUTERADVERT"):
            with self.subTest(reason=reason):
                self.resolv.write_text(self.original)
                self.run_hook(reason=reason)
                self.assertEqual(self.resolv.read_text(), expected)
                self.assertEqual(list(self.root.glob("resolv.conf.dns-manager.*")), [])
        self.resolv.write_text(self.original)
        self.run_hook(interface="eth1")
        self.assertEqual(self.resolv.read_text(), self.original)

    def test_custom_interface_and_hook_shell_state_are_preserved(self):
        self.hook.write_text("custom_hook_ran=yes\n")
        self.apply(extra="--interface enp1s0.2")
        self.resolv.write_text(self.original)
        self.run_hook()
        self.assertEqual(self.resolv.read_text(), self.original)
        result = subprocess.run(
            ["sh", "-c", 'interface=enp1s0.2; _dns_manager_tmp=keep; . "$1"; '
             'printf "%s %s" "$_dns_manager_tmp" "$custom_hook_ran"', "sh", str(self.hook)],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "keep yes")
        self.assertIn("nameserver 1.1.1.1", self.resolv.read_text())

    def test_repeated_apply_keeps_first_snapshot_and_restores_custom_hook(self):
        custom = "# original hook\noriginal_hook=yes\n"
        self.hook.write_text(custom)
        self.hook.chmod(0o640)
        self.apply()
        self.apply("9.9.9.9")
        self.assertEqual(self.hook.read_text().count("# BEGIN DNS-MANAGER"), 1)
        self.assertNotIn("nameserver 1.1.1.1", self.hook.read_text())
        manifest = self.state / "original" / "manifest"
        self.assertEqual(len(manifest.read_text().splitlines()), 2)
        self.run_script("main --backend dhcpcd --restore")
        self.assertEqual(self.hook.read_text(), custom)
        self.assertEqual(self.hook.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.resolv.read_text(), self.original)
        self.assertFalse(manifest.exists())
        self.assertEqual(len(list(self.state.glob("restored-*"))), 1)

    def test_restore_removes_new_hook_and_restores_resolver_symlink(self):
        target = self.root / "dhcp-resolv.conf"
        target.write_text(self.original)
        self.resolv.unlink()
        self.resolv.symlink_to(target)
        self.apply()
        self.assertFalse(self.resolv.is_symlink())
        self.run_script("main --backend dhcpcd --restore")
        self.assertTrue(self.resolv.is_symlink())
        self.assertEqual(self.resolv.readlink(), target)
        self.assertEqual(self.resolv.read_text(), self.original)
        self.assertEqual(target.read_text(), self.original)
        self.assertFalse(self.hook.exists())

    def test_migrating_old_static_snapshot_keeps_original_dns(self):
        self.run_script("main --backend static --set 8.8.8.8")
        self.apply()
        self.run_script("main --backend dhcpcd --restore")
        self.assertEqual(self.resolv.read_text(), self.original)
        self.assertFalse(self.hook.exists())

    def test_missing_backup_reports_failure_and_keeps_snapshot(self):
        self.apply()
        current = self.resolv.read_text()
        snapshot = self.state / "original"
        (snapshot / "root" / str(self.resolv).lstrip("/")).unlink()
        result = self.run_script("main --backend dhcpcd --restore", success=False)
        self.assertIn("备份文件缺失", result.stderr)
        self.assertEqual(self.resolv.read_text(), current)
        self.assertTrue((snapshot / "manifest").exists())
        self.assertEqual(list(self.state.glob("restored-*")), [])

    def test_restore_without_snapshot_only_cleans_managed_hook(self):
        custom = "# user hook\nuser_hook=yes\n"
        self.hook.write_text(custom + "# BEGIN DNS-MANAGER\nmanaged=yes\n# END DNS-MANAGER\n")
        result = self.run_script("main --backend dhcpcd --restore")
        self.assertEqual(self.hook.read_text(), custom)
        self.assertEqual(self.resolv.read_text(), self.original)
        self.assertIn("下次 DHCP 续租或重启", result.stderr)

    def test_invalid_dns_or_interface_does_not_change_files(self):
        for args in ("--set 999.1.1.1", "--set dns.example.com", "--set ''",
                     "--set 1.1.1.1 --interface 'eth0;false'", "--set 1.1.1.1 --interface ''"):
            with self.subTest(args=args):
                prefix = "default_iface() { :; }\n" if args.endswith("--interface ''") else ""
                self.run_script(prefix + f"main --backend dhcpcd {args}", success=False)
                self.assertEqual(self.resolv.read_text(), self.original)
                self.assertFalse(self.hook.exists())
                self.assertFalse(self.state.exists())

    def test_existing_invalid_hook_is_rejected_before_writing(self):
        original_hook = "if broken syntax\n"
        self.hook.write_text(original_hook)
        self.run_script("main --backend dhcpcd --set 1.1.1.1", success=False)
        self.assertEqual(self.hook.read_text(), original_hook)
        self.assertEqual(self.resolv.read_text(), self.original)
        self.assertFalse(self.state.exists())

    def test_existing_dhclient_backend_still_applies_and_restores(self):
        config = self.root / "dhclient.conf"
        original = "# original\ntimeout 60;\n"
        config.write_text(original)
        override = f"dhclient_conf_path() {{ echo {shlex.quote(str(config))}; }}\n"
        self.run_script(override + "main --backend dhclient --set '1.1.1.1 8.8.8.8'")
        self.assertIn("supersede domain-name-servers 1.1.1.1, 8.8.8.8;", config.read_text())
        self.run_script("main --backend dhclient --restore")
        self.assertEqual(config.read_text(), original)
        self.assertEqual(self.resolv.read_text(), self.original)

    def test_status_and_help_do_not_write_configuration(self):
        result = self.run_script("main --backend dhcpcd --status")
        self.assertIn("检测后端：dhcpcd", result.stdout)
        self.assertIn("10.88.0.1", result.stdout)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.hook.exists())
        result = self.run_script("main --help")
        self.assertIn("dhcpcd", result.stdout)


if __name__ == "__main__":
    unittest.main()
