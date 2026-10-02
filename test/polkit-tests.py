"""Unprivileged integration tests. No host sudo, pkexec, systemctl or VPN data.

Production scripts run in copies with an exclusive command PATH and isolated
targets. Root ownership and real Polkit dialogs are NOT tested by these stubs.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, signal, subprocess, sys, time
box = pathlib.Path(os.environ["BOX"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (box / "events").open("a") as f: f.write(json.dumps([name] + args) + "\n")
if name == "sudo":
    if not args or args[0] != "env": sys.exit(99)
    sys.exit(subprocess.call(args))
if name == "pkexec":
    if os.environ.get("PK_CANCEL"): sys.exit(int(os.environ["PK_CANCEL"]))
    if not str(args[0]).startswith(str(box) + "/"): sys.exit(99)
    sys.exit(subprocess.call(args))
if name == "systemctl":
    verb, unit = args[0], args[-1].removesuffix(".service")
    statefile = box / "states.json"
    states = json.loads(statefile.read_text())
    if verb == "is-active":
        print(states.get(unit, "inactive")); sys.exit(0 if states.get(unit) == "active" else 3)
    if os.environ.get("HANG_UNIT") == unit: time.sleep(10)
    if os.environ.get("FAIL_" + verb.upper()) == unit: print("simulated failure", file=sys.stderr); sys.exit(1)
    if verb not in ("start", "stop"): sys.exit(99)
    states[unit] = "active" if verb == "start" else "inactive"
    statefile.write_text(json.dumps(states)); sys.exit(0)
if name == "install":
    mode, files = "755", []
    while args:
        arg = args.pop(0)
        if arg in ("-o", "-g", "-m"):
            val = args.pop(0)
            if arg == "-m": mode = val
        else: files.append(arg)
    src, dst = map(pathlib.Path, files)
    if not str(dst).startswith(str(box) + "/"): sys.exit(99)
    if os.environ.get("FAIL_DEST") and os.environ["FAIL_DEST"] in str(dst): sys.exit(1)
    shutil.copyfile(src, dst); dst.chmod(int(mode, 8))
    if os.environ.get("SIGNAL_DEST") and os.environ["SIGNAL_DEST"] in str(dst):
        os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(0)
if name == "stat":
    if args[:2] == ["-c", "%u:%g:%a"]:
        print("0:0:" + oct(pathlib.Path(args[2]).stat().st_mode & 0o777)[2:]); sys.exit(0)
    sys.exit(subprocess.call(["/usr/bin/stat"] + args))
sys.exit(99)
'''


class PolkitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="vpn-polkit-")
        self.addCleanup(self.tmp.cleanup)
        self.box = Path(self.tmp.name)
        self.repo = self.box / "plugin"
        self.repo.mkdir()
        for name in ("bin", "share"):
            shutil.copytree(ROOT / name, self.repo / name,
                            ignore=shutil.ignore_patterns(".git", "node_modules", ".superpowers"))
        for name in ("install", "uninstall"):
            shutil.copy2(ROOT / name, self.repo / name)
        self.tools = self.box / "tools"
        self.tools.mkdir()
        for tool in ("bash", "env", "dirname", "readlink", "basename", "jq", "chmod",
                     "mkdir", "cat", "cmp", "id", "mktemp", "rm", "sha256sum", "tar", "mv", "head", "timeout"):
            path = shutil.which(tool, path="/usr/bin:/bin")
            self.assertIsNotNone(path, tool)
            (self.tools / tool).symlink_to(path)
        for name in ("sudo", "pkexec", "systemctl", "install", "stat"):
            (self.tools / name).write_text(STUB)
            (self.tools / name).chmod(0o755)
        for name in ("home", "tmp", "system"):
            (self.box / name).mkdir()
        self.conf = self.box / "connections.json"
        self.conf.write_text(json.dumps([
            {"id": "a", "unit": "wg-quick@a", "group": "work"},
            {"id": "b", "unit": "openvpn-client@b", "group": "work"},
            {"id": "c", "unit": "wg-quick@c", "group": "other"}]))
        (self.box / "states.json").write_text(json.dumps({"openvpn-client@b": "active", "wg-quick@c": "active"}))
        (self.box / "events").write_text("")
        self.helper = self.box / "test-helper"
        code = (ROOT / "share/omarchy-vpn-privileged").read_text()
        self.assertEqual(code.count("SYSTEMCTL=/usr/bin/systemctl"), 1)
        code = code.replace("SYSTEMCTL=/usr/bin/systemctl", f"SYSTEMCTL={self.tools}/systemctl")
        code = code.replace("LOCK=/run/omarchy-vpn-switch.lock", f"LOCK={self.box}/switch.lock")
        code = code.replace("MAX_SECONDS=90", "MAX_SECONDS=2")
        self.assertNotIn("/usr/bin/systemctl", code)
        self.assertNotIn("LOCK=/run/", code)
        self.helper.write_text(code)
        self.helper.chmod(0o755)
        self.env = {
            "PATH": str(self.tools), "HOME": str(self.box / "home"), "TMPDIR": str(self.box / "tmp"),
            "LC_ALL": "C", "BOX": str(self.box), "OMARCHY_VPN_CONNECTIONS": str(self.conf),
            "OMARCHY_VPN_PRIVILEGED": str(self.helper),
            "OMARCHY_VPN_IMPORT": str(self.box / "system/import"),
            "OMARCHY_VPN_POLICY": str(self.box / "system/import.policy"),
            "OMARCHY_VPN_SWITCH_POLICY": str(self.box / "system/switch.policy"),
            "OMARCHY_VPN_SUDOERS": str(self.box / "system/sudoers"),
            "OMARCHY_VPN_LEGACY_PRIVILEGED": str(self.box / "system/legacy-helper"),
        }

    def run_script(self, file, *args):
        return subprocess.run(["/bin/bash", str(file), *args], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def events(self, name):
        return [e for e in map(json.loads, (self.box / "events").read_text().splitlines()) if e[0] == name]

    def mutations(self):
        return [e for e in self.events("systemctl") if e[1] in ("start", "stop")]

    def toggle(self, target="a"):
        return self.run_script(self.repo / "bin/omarchy-vpn-toggle", target)

    def setup_install(self):
        # Never execute an installed production helper in this suite.
        self.env["OMARCHY_VPN_PRIVILEGED"] = str(self.box / "system/switch")

    def test_group_has_one_authentication(self):
        r = self.toggle()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.events("pkexec")), 1)
        self.assertEqual(self.events("sudo"), [])
        self.assertEqual(self.mutations(), [["systemctl", "stop", "--", "openvpn-client@b.service"],
                                          ["systemctl", "start", "--", "wg-quick@a.service"]])

    def test_stop_and_repeat_authenticate_each_time(self):
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(len(self.events("pkexec")), 2)
        self.assertEqual(self.mutations()[-1], ["systemctl", "stop", "--", "wg-quick@a.service"])

    def test_cancel_and_deny_do_not_mutate(self):
        for code in ("126", "127"):
            self.env["PK_CANCEL"] = code
            self.assertEqual(self.toggle().returncode, 4)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.events("sudo"), [])

    def test_missing_helper_no_fallback(self):
        self.helper.unlink()
        self.assertIn("migration", self.toggle().stderr)
        self.assertEqual(self.events("sudo") + self.events("pkexec"), [])

    def test_invalid_late_peer_rejected_before_auth(self):
        data = json.loads(self.conf.read_text())
        data.append({"id": "bad", "unit": "sshd", "group": "work"})
        self.conf.write_text(json.dumps(data))
        self.assertEqual(self.toggle().returncode, 5)
        self.assertEqual(self.events("pkexec") + self.mutations(), [])

    def test_root_revalidates_entire_request(self):
        r = self.run_script(self.helper, "switch", "wg-quick@a", "openvpn-client@b", "sshd")
        self.assertEqual(r.returncode, 66)
        self.assertEqual(self.mutations(), [])

    def test_duplicate_alias_rejected_by_helper(self):
        self.assertEqual(self.run_script(self.helper, "switch", "wg-quick@a", "wg-quick@a.service").returncode, 66)
        self.assertEqual(self.mutations(), [])

    def test_instance_ending_service_is_not_stripped_twice(self):
        self.conf.write_text(json.dumps([
            {"id": "a", "unit": "wg-quick@a.service.service", "group": "work"},
            {"id": "b", "unit": "openvpn-client@b.service.service", "group": "work"}]))
        (self.box / "states.json").write_text(json.dumps({"openvpn-client@b.service": "active"}))
        self.assertEqual(self.toggle().returncode, 0)
        self.assertEqual(self.mutations(), [["systemctl", "stop", "--", "openvpn-client@b.service.service"],
                                          ["systemctl", "start", "--", "wg-quick@a.service.service"]])

    def test_unknown_state_never_starts_target(self):
        (self.box / "states.json").write_text(json.dumps({"wg-quick@a": "unknown"}))
        self.assertEqual(self.toggle().returncode, 4)
        self.assertEqual(self.mutations(), [])

    def test_group_stop_failure_blocks_start(self):
        self.env["FAIL_STOP"] = "openvpn-client@b"
        self.assertEqual(self.toggle().returncode, 4)
        self.assertEqual([e[1] for e in self.mutations()], ["stop"])

    def test_operation_timeout(self):
        self.env["HANG_UNIT"] = "openvpn-client@b"
        self.assertEqual(self.toggle().returncode, 6)
        self.assertNotIn("start", [e[1] for e in self.mutations()])

    def test_policy_requires_admin_without_retention(self):
        for name, helper in (("switch", "switch"), ("import", "import")):
            policy = ET.parse(ROOT / f"share/omarchy-vpn-{name}.policy").getroot()
            actions = policy.findall("action")
            self.assertEqual(len(actions), 1)
            self.assertEqual(actions[0].attrib["id"], f"org.omarchy.smartalbvpn.{name}")
            self.assertEqual([x.text for x in actions[0].find("defaults")], ["auth_admin"] * 3)
            self.assertEqual(actions[0].find("annotate").text, f"/usr/local/bin/omarchy-vpn-{helper}")

    def test_install_creates_no_sudoers_and_no_service_changes(self):
        self.setup_install()
        before = self.conf.read_bytes()
        r = self.run_script(self.repo / "install", "--system")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(Path(self.env["OMARCHY_VPN_SUDOERS"]).exists())
        self.assertEqual(len(self.events("sudo")), 1)
        self.assertEqual(self.conf.read_bytes(), before)
        self.assertEqual(self.events("systemctl"), [])
        for key, source, mode in (("OMARCHY_VPN_PRIVILEGED", "omarchy-vpn-privileged", 0o755),
                                  ("OMARCHY_VPN_SWITCH_POLICY", "omarchy-vpn-switch.policy", 0o644)):
            dest = Path(self.env[key])
            self.assertEqual(dest.read_bytes(), (ROOT / "share" / source).read_bytes())
            self.assertEqual(dest.stat().st_mode & 0o777, mode)

    def test_install_repairs_mode_even_if_contents_match(self):
        self.setup_install()
        self.assertEqual(self.run_script(self.repo / "install", "--system").returncode, 0)
        helper = Path(self.env["OMARCHY_VPN_PRIVILEGED"])
        helper.chmod(0o777)
        self.assertEqual(self.run_script(self.repo / "install", "--system").returncode, 0)
        self.assertEqual(helper.stat().st_mode & 0o777, 0o755)

    def test_legacy_exact_rule_revoked(self):
        self.setup_install()
        legacy = Path(self.env["OMARCHY_VPN_SUDOERS"])
        legacy.write_text(f'#{os.getuid()} ALL=(root) NOPASSWD: {self.env["OMARCHY_VPN_LEGACY_PRIVILEGED"]}\n')
        r = self.run_script(self.repo / "install", "--system")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(legacy.exists())
        self.assertEqual(self.events("systemctl"), [])

    def test_custom_legacy_rule_preserved_by_install_and_uninstall(self):
        self.setup_install()
        legacy = Path(self.env["OMARCHY_VPN_SUDOERS"])
        content = f'#{os.getuid()} ALL=(root) NOPASSWD: {self.env["OMARCHY_VPN_LEGACY_PRIVILEGED"]}\nother ALL=(root) /bin/true\n'
        legacy.write_text(content)
        for script in ("install", "uninstall"):
            r = self.run_script(self.repo / script, "--system")
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(legacy.read_text(), content)

    def test_failed_install_does_not_restore_passwordless_grant(self):
        self.setup_install()
        legacy = Path(self.env["OMARCHY_VPN_SUDOERS"])
        legacy.write_text(f'#{os.getuid()} ALL=(root) NOPASSWD: {self.env["OMARCHY_VPN_LEGACY_PRIVILEGED"]}\n')
        self.env["FAIL_DEST"] = "switch.policy"
        self.assertNotEqual(self.run_script(self.repo / "install", "--system").returncode, 0)
        self.assertFalse(legacy.exists())
        self.assertFalse(Path(self.env["OMARCHY_VPN_PRIVILEGED"]).exists())

    def test_interrupted_publication_restores_previous_helpers(self):
        self.setup_install()
        helper = Path(self.env["OMARCHY_VPN_PRIVILEGED"])
        helper.write_text("previous helper\n")
        self.env["SIGNAL_DEST"] = "import.policy.new."
        r = self.run_script(self.repo / "install", "--system")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(helper.read_text(), "previous helper\n")
        self.assertFalse(Path(self.env["OMARCHY_VPN_SWITCH_POLICY"]).exists())
        self.assertEqual(list((self.box / "tmp").iterdir()), [])

    def test_symlink_legacy_rule_preserved_and_migration_refused(self):
        self.setup_install()
        legacy = Path(self.env["OMARCHY_VPN_SUDOERS"])
        target = self.box / "innocent"
        target.write_text("unrelated\n")
        legacy.symlink_to(target)
        self.assertNotEqual(self.run_script(self.repo / "install", "--system").returncode, 0)
        self.assertTrue(legacy.is_symlink())
        self.assertEqual(target.read_text(), "unrelated\n")

    def test_uninstall_keeps_connections_and_tunnels(self):
        self.setup_install()
        self.assertEqual(self.run_script(self.repo / "install", "--system").returncode, 0)
        before = (self.conf.read_bytes(), (self.box / "states.json").read_bytes())
        self.assertEqual(self.run_script(self.repo / "uninstall", "--system").returncode, 0)
        self.assertEqual(before, (self.conf.read_bytes(), (self.box / "states.json").read_bytes()))
        self.assertEqual(self.events("systemctl"), [])
        for key in ("OMARCHY_VPN_PRIVILEGED", "OMARCHY_VPN_IMPORT", "OMARCHY_VPN_POLICY", "OMARCHY_VPN_SWITCH_POLICY"):
            self.assertFalse(Path(self.env[key]).exists())

    def test_unprivileged_install_and_uninstall_never_elevate(self):
        self.assertEqual(self.run_script(self.repo / "install").returncode, 0)
        self.assertEqual(self.run_script(self.repo / "uninstall").returncode, 0)
        self.assertEqual(self.events("sudo") + self.events("pkexec"), [])


if __name__ == "__main__":
    if os.geteuid() == 0:
        raise SystemExit("Refusing tests as root")
    unittest.main(verbosity=2)
