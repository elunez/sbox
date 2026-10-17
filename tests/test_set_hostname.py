"""本地隔离测试：配置与模拟的运行时名称均位于临时目录，不修改真实主机名。"""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "set-hostname.sh"


class HostnameTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.hostname_file = self.directory / "hostname"
        self.hosts = self.directory / "hosts"
        self.runtime = self.directory / "runtime"
        self.runtime.write_text("old.example.com\n")

    def run_script(self, command):
        setup = f"source {shlex.quote(str(SCRIPT))}\n"
        for name, value in (("HOSTNAME_FILE", self.hostname_file),
                            ("HOSTS_FILE", self.hosts), ("RUNTIME_FILE", self.runtime)):
            setup += f"{name}={shlex.quote(str(value))}\n"
        # 所有 hostname 调用均被替换，禁止触碰真实系统名称。
        setup += '''
hostname() {
  if [[ $# -eq 0 ]]; then cat "$RUNTIME_FILE"
  elif [[ "$1" == blocked ]]; then echo '模拟无权限' >&2; return 1
  else printf '%s\\n' "$1" > "$RUNTIME_FILE"
  fi
}
trap 'finish $?' EXIT
'''
        return subprocess.run(["bash", "-c", setup + command], capture_output=True,
                              text=True, timeout=5)

    def change(self, name, prefix=""):
        return self.run_script(prefix + "\nchange_hostname " + shlex.quote(name))

    def test_sync_and_preserve_unrelated_entries(self):
        self.hostname_file.write_text("static.example.com\n")
        self.hostname_file.chmod(0o640)
        self.hosts.write_text("# header\n127.0.0.1 localhost\n"
                              "127.0.1.1 old.example.com old static.example.com static alias # local\n"
                              "127.0.1.1 old # legacy\n"
                              "::1 localhost ip6-localhost ip6-loopback\n"
                              "192.0.2.1 database.example.com database\n")
        result = self.change("new.example.net")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.runtime.read_text(), "new.example.net\n")
        self.assertEqual(self.hostname_file.read_text(), "new.example.net\n")
        self.assertEqual(self.hostname_file.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.hosts.read_text(), "# header\n127.0.0.1 localhost\n"
                         "127.0.1.1\tnew.example.net new alias # local\n# legacy\n"
                         "::1 localhost ip6-localhost ip6-loopback\n"
                         "192.0.2.1 database.example.com database\n")
        content = self.hosts.read_bytes()
        result = self.change("new.example.net")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("无需修改", result.stdout)
        self.assertEqual(self.hosts.read_bytes(), content)
        self.assertEqual({p.name for p in self.directory.iterdir()}, {"runtime", "hostname", "hosts"})

    def test_missing_files_create_localhost_and_mapping(self):
        result = self.change("vps-01")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.hostname_file.read_text(), "vps-01\n")
        self.assertEqual(self.hosts.read_text(), "127.0.0.1\tlocalhost\n"
                         "::1\tlocalhost ip6-localhost ip6-loopback\n127.0.1.1\tvps-01\n")
        self.assertEqual(self.hosts.stat().st_mode & 0o777, 0o644)

    def test_rejected_names_leave_everything_untouched(self):
        for name in ("", "UPPER", "bad name", "-bad", "bad-", ".bad", "bad.", "bad..name",
                     "123", "127.0.0.1", "localhost", "localhost.localdomain", "a" * 64,
                     "a." + "b" * 63, "valid\ninjected", "valid\talias", "bad/name"):
            with self.subTest(name=name):
                result = self.change(name)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.runtime.read_text(), "old.example.com\n")
                self.assertFalse(self.hostname_file.exists())
                self.assertFalse(self.hosts.exists())
        result = self.run_script("validate_hostname " + shlex.quote("a" * 61 + ".bc"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_failure_rolls_back_without_backup_files(self):
        self.hostname_file.write_bytes(b"old.example.com\n\n")
        self.hosts.write_bytes(b"127.0.0.1 localhost\n# keep\n\n")
        result = self.change("blocked")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("已回滚", result.stderr)
        self.assertEqual(self.runtime.read_text(), "old.example.com\n")
        self.assertEqual(self.hostname_file.read_bytes(), b"old.example.com\n\n")
        self.assertEqual(self.hosts.read_bytes(), b"127.0.0.1 localhost\n# keep\n\n")
        self.assertEqual({p.name for p in self.directory.iterdir()}, {"runtime", "hostname", "hosts"})

    def test_partial_file_failure_rolls_back_both_files_and_runtime(self):
        self.hostname_file.write_text("old.example.com\n")
        original_hosts = "127.0.0.1 localhost\n127.0.1.1 old.example.com old\n"
        self.hosts.write_text(original_hosts)
        fail_move = '''mv() {
  if [[ "${!#}" == "$HOSTNAME_FILE" ]]; then return 1; fi
  command mv "$@"
}'''
        result = self.change("new", fail_move)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.runtime.read_text(), "old.example.com\n")
        self.assertEqual(self.hostname_file.read_text(), "old.example.com\n")
        self.assertEqual(self.hosts.read_text(), original_hosts)
        self.assertEqual({p.name for p in self.directory.iterdir()}, {"runtime", "hostname", "hosts"})

    def test_failure_removes_files_that_did_not_exist(self):
        result = self.change("blocked")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual({p.name for p in self.directory.iterdir()}, {"runtime"})

    def test_symlink_refused_and_status_readonly(self):
        self.hostname_file.symlink_to(self.runtime)
        result = self.change("new")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.runtime.read_text(), "old.example.com\n")
        result = self.run_script("show_status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("old.example.com", result.stdout)
        self.assertFalse(self.hosts.exists())


if __name__ == "__main__":
    unittest.main()
