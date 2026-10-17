"""本地隔离测试：仅操作临时目录的 gai.conf，不调用 main，不访问真实系统或网络。"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ip-priority.sh"


class PriorityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = Path(self.tmp.name) / "gai.conf"

    def run_script(self, command):
        # source 不执行 main，所有读写均定向到一次性临时文件。
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n"
             f"GAI_FILE={shlex.quote(str(self.config))}\n"
             "trap cleanup EXIT\n" + command],
            capture_output=True, text=True, timeout=5,
        )

    def apply(self, mode):
        result = self.run_script(f"set_priority {shlex.quote(mode)}")
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.config.read_text()

    def test_switch_idempotence_and_restore_custom_rules(self):
        original = ("# original\nlabel ::/0 1\nreload no\n"
                    "  precedence ::ffff:0:0/96 70 # custom\n"
                    "precedence 2001:db8::/32 60\n")
        self.config.write_text(original)
        self.config.chmod(0o640)
        ipv4 = self.apply("ipv4")
        self.assertIn("# ip-priority saved:   precedence", ipv4)
        self.assertIn("label ::/0 1\nreload no\n", ipv4)
        self.assertEqual(sum(line.startswith("precedence ") for line in ipv4.splitlines()), 5)
        self.assertIn("precedence ::ffff:0:0/96 100\n", ipv4)
        backups = list(Path(self.tmp.name).glob("gai.conf.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual(os.stat(self.config).st_mode & 0o777, 0o640)
        self.assertEqual(self.apply("ipv4"), ipv4)
        self.assertEqual(len(list(Path(self.tmp.name).glob("gai.conf.bak.*"))), 1)
        ipv6 = self.apply("ipv6")
        self.assertIn("precedence ::ffff:0:0/96 10\n", ipv6)
        self.assertEqual(ipv6.count("# BEGIN ip-priority managed"), 1)
        self.assertEqual(ipv6.count("# ip-priority saved: "), 2)
        self.assertEqual(self.apply("restore"), original)
        self.assertEqual(self.apply("restore"), original)
        self.assertEqual(list(Path(self.tmp.name).glob("*.tmp.*")), [])

    def test_restore_preserves_later_unmanaged_edits(self):
        self.config.write_text("# existing\n")
        self.apply("ipv4")
        with self.config.open("a") as stream:
            stream.write("# later edit\nlabel 2001:db8::/32 9\n")
        self.assertEqual(self.apply("restore"), "# existing\n# later edit\nlabel 2001:db8::/32 9\n")

    def test_missing_config_and_default_status(self):
        result = self.run_script("show_status; set_priority restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("glibc 默认", result.stdout)
        self.assertFalse(self.config.exists())
        self.apply("ipv6")
        self.assertEqual(os.stat(self.config).st_mode & 0o777, 0o644)
        self.assertEqual(self.apply("restore"), "")

    def test_malformed_markers_leave_file_untouched(self):
        for content in (
            "# BEGIN ip-priority managed\nprecedence ::/0 40\n",
            "# END ip-priority managed\n",
            "# ip-priority saved: precedence ::/0 40\n",
            "# BEGIN ip-priority managed\n# BEGIN ip-priority managed\n# END ip-priority managed\n",
            "# BEGIN ip-priority managed\n# END ip-priority managed\n" * 2,
        ):
            with self.subTest(content=content):
                self.config.write_text(content)
                result = self.run_script("set_priority ipv4")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.config.read_text(), content)
        self.assertEqual(list(Path(self.tmp.name).glob("gai.conf.bak.*")), [])

    def test_symlink_and_invalid_mode_rejected(self):
        target = Path(self.tmp.name) / "target"
        target.write_text("# untouched\n")
        self.config.symlink_to(target)
        result = self.run_script("set_priority ipv4")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "# untouched\n")
        self.config.unlink()
        result = self.run_script("set_priority invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())


if __name__ == "__main__":
    unittest.main()
