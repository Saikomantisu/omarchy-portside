"""Unit tests for bin/portside. Run: python3 -m unittest discover tests"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("portside", os.path.join(HERE, "..", "bin", "portside"))
_spec = importlib.util.spec_from_loader("portside", _loader)
ps = importlib.util.module_from_spec(_spec)
_loader.exec_module(ps)


def fixture(name):
    with open(os.path.join(HERE, "fixtures", name)) as fh:
        return fh.read()


class ProcNet(unittest.TestCase):
    TCP = (
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        "   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1\n"
        "   1: 00000000:10E1 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222 1\n"
        "   2: 0100007F:1435 0100007F:A000 01 00000000:00000000 00:00000000 00000000  1000        0 333 1\n"
    )
    TCP6 = (
        "  sl  local_address                         remote_address                        st\n"
        "   0: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A "
        "00000000:00000000 00:00000000 00000000     0        0 444 1\n"
        "   1: 0000000000000000FFFF00000100007F:1F90 00000000000000000000000000000000:0000 0A "
        "00000000:00000000 00:00000000 00000000  1000        0 555 1\n"
    )

    def test_ipv4_listeners_only(self):
        rows = ps.parse_proc_net(self.TCP, "tcp", ps.TCP_LISTEN)
        self.assertEqual([(r["ip"], r["port"], r["inode"]) for r in rows],
                         [("127.0.0.1", 5173, 111), ("0.0.0.0", 4321, 222)])

    def test_ipv6_and_mapped(self):
        rows = ps.parse_proc_net(self.TCP6, "tcp", ps.TCP_LISTEN)
        self.assertEqual(rows[0]["ip"], "::1")
        self.assertEqual(rows[0]["port"], 631)
        self.assertEqual(rows[0]["uid"], 0)
        self.assertEqual(rows[1]["ip"], "127.0.0.1")


class Scope(unittest.TestCase):
    IFACES = {"172.17.0.1": "docker0", "100.101.1.2": "tailscale0", "10.8.0.2": "wg0",
              "192.168.8.148": "wlo1"}

    def test_scopes(self):
        cases = {"127.0.0.1": "local", "::1": "local", "0.0.0.0": "lan", "::": "lan",
                 "172.17.0.1": "bridge", "100.101.1.2": "vpn", "10.8.0.2": "vpn",
                 "192.168.8.148": "lan", "127.0.0.53%lo": "local", "224.0.0.251": "local"}
        for ip, want in cases.items():
            self.assertEqual(ps.addr_scope(ip, self.IFACES), want, ip)

    def test_tailscale_range_without_interface_map(self):
        self.assertEqual(ps.addr_scope("100.100.100.100"), "vpn")


class Ufw(unittest.TestCase):
    def setUp(self):
        self.ufw = ps.parse_ufw(fixture("ufw.conf"), fixture("default-ufw"),
                                fixture("user.rules"), fixture("user6.rules"))

    def test_state(self):
        self.assertTrue(self.ufw["enabled"])
        self.assertEqual(self.ufw["policy"], "DROP")

    def test_verdicts(self):
        self.assertEqual(ps.firewall_verdict(self.ufw, "tcp", 53317)[0], "open")
        self.assertEqual(ps.firewall_verdict(self.ufw, "tcp", 8005)[0], "open")      # range 8000:8010
        self.assertEqual(ps.firewall_verdict(self.ufw, "tcp", 443)[0], "open")       # list 80,443
        self.assertEqual(ps.firewall_verdict(self.ufw, "udp", 443)[0], "blocked")    # tcp-only rule
        self.assertEqual(ps.firewall_verdict(self.ufw, "tcp", 5173)[0], "blocked")
        verdict, note = ps.firewall_verdict(self.ufw, "udp", 53)
        self.assertEqual(verdict, "open")
        self.assertIn("172.16.0.0/12", note)

    def test_deny_rules_do_not_open(self):
        self.assertEqual(ps.firewall_verdict(self.ufw, "tcp", 23)[0], "blocked")

    def test_disabled_and_accepting(self):
        off = ps.parse_ufw("ENABLED=no\n", "", "", "")
        self.assertEqual(ps.firewall_verdict(off, "tcp", 3000)[0], "unknown")
        accepting = ps.parse_ufw("ENABLED=yes\n", 'DEFAULT_INPUT_POLICY="ACCEPT"\n', "", "")
        self.assertEqual(ps.firewall_verdict(accepting, "tcp", 3000)[0], "open")


class Naming(unittest.TestCase):
    def test_frameworks(self):
        f = ps.detect_framework
        self.assertEqual(f("node", ["node", "/p/node_modules/.bin/vite"]), "Vite")
        self.assertEqual(f("node", ["node", "/p/node_modules/next/dist/bin/next", "dev"]), "Next.js")
        self.assertEqual(f("python3", ["python3", "manage.py", "runserver"]), "Django")
        self.assertEqual(f("python3", ["python3", "-m", "http.server"]), "http.server")
        self.assertEqual(f("node", ["node", "server.js"], "express vite"), "Vite")
        self.assertEqual(f("node", ["node", "server.js"], "express"), "Node")
        self.assertIsNone(f("spotify", ["/opt/spotify/spotify"]))

    def test_supervisor(self):
        self.assertTrue(ps.is_supervisor("node", ["node", "/usr/bin/pnpm", "dev"]))
        self.assertTrue(ps.is_supervisor("npm run dev", ["npm", "run", "dev"]))
        self.assertFalse(ps.is_supervisor("bash", ["bash"]))
        self.assertFalse(ps.is_supervisor("ghostty", ["/usr/bin/ghostty"]))

    def test_publish_parse(self):
        got = ps._parse_publish("0.0.0.0:8080->80/tcp, :::8080->80/tcp, 127.0.0.1:5432->5432/tcp")
        self.assertEqual(got, [("0.0.0.0", 8080, "tcp", 80), ("::", 8080, "tcp", 80),
                               ("127.0.0.1", 5432, "tcp", 5432)])

    def test_project_walks_up_to_git(self):
        import tempfile
        with tempfile.TemporaryDirectory(dir=ps.HOME) as root:
            os.makedirs(os.path.join(root, ".git"))
            os.makedirs(os.path.join(root, "packages", "web", "src"))
            open(os.path.join(root, "packages", "web", "package.json"), "w").close()
            self.assertEqual(ps.find_project(os.path.join(root, "packages", "web", "src")), root)
        self.assertIsNone(ps.find_project("/proc/self (deleted)"))


def row(name, port, reach="local", mine=True):
    return {"key": "pid:%d" % port, "projectName": name, "ports": [port], "reach": reach, "mine": mine}


class EventsTest(unittest.TestCase):
    def test_first_snapshot_is_silent(self):
        ev = ps.Events(3)
        self.assertEqual(ev.step([row("a", 3000)], 0), [])
        self.assertEqual(ev.step([row("a", 3000)], 10), [])

    def test_new_after_settle(self):
        ev = ps.Events(3)
        ev.step([], 0)
        self.assertEqual(ev.step([row("a", 3000)], 1), [])
        self.assertEqual(ev.step([row("a", 3000)], 2), [])
        self.assertEqual([e["kind"] for e in ev.step([row("a", 3000)], 4.5)], ["new"])
        self.assertEqual(ev.step([row("a", 3000)], 6), [])

    def test_short_lived_never_announced(self):
        ev = ps.Events(3)
        ev.step([], 0)
        ev.step([row("a", 3000)], 1)
        self.assertEqual(ev.step([], 2), [])
        self.assertEqual(ev.step([], 10), [])

    def test_restart_is_silent(self):
        ev = ps.Events(3)
        ev.step([], 0)
        ev.step([row("a", 3000)], 1)
        ev.step([row("a", 3000)], 5)
        self.assertEqual(ev.step([], 6), [])
        self.assertEqual(ev.step([row("a", 3000)], 7), [])
        self.assertEqual(ev.step([row("a", 3000)], 12), [])

    def test_down(self):
        ev = ps.Events(3)
        ev.step([], 0)
        ev.step([row("a", 3000)], 1)
        ev.step([row("a", 3000)], 5)
        self.assertEqual(ev.step([], 6), [])
        self.assertEqual([e["kind"] for e in ev.step([], 9.5)], ["down"])

    def test_exposed_on_new_and_on_change(self):
        ev = ps.Events(3)
        ev.step([], 0)
        ev.step([row("a", 3000, "open")], 1)
        self.assertEqual([e["kind"] for e in ev.step([row("a", 3000, "open")], 5)], ["new", "exposed"])
        ev.step([row("b", 4000, "blocked")], 5)
        ev.step([row("b", 4000, "blocked")], 9)
        self.assertEqual([e["kind"] for e in ev.step([row("b", 4000, "published")], 10)], ["exposed"])

    def test_other_users_ignored(self):
        ev = ps.Events(3)
        ev.step([], 0)
        ev.step([row("x", 53, "open", mine=False)], 1)
        self.assertEqual(ev.step([row("x", 53, "open", mine=False)], 9), [])


class Identity(unittest.TestCase):
    def test_refusals(self):
        self.assertFalse(ps._identity_ok(1, 0)[0])
        self.assertFalse(ps._identity_ok(os.getpid(), 0)[0])
        self.assertFalse(ps._identity_ok(os.getppid(), 0)[0])

    def test_start_time_mismatch(self):
        import subprocess
        child = subprocess.Popen(["sleep", "30"])
        try:
            start = ps.proc_stat(child.pid)[2]
            self.assertFalse(ps._identity_ok(child.pid, start + 1)[0])
            res = ps.signal_process(child.pid, start + 1, 15)
            self.assertFalse(res["ok"])
            self.assertIsNone(child.poll())
            res = ps.signal_process(child.pid, start, 15)
            res["start"] = start
            self.assertTrue(res["ok"])
            self.assertEqual(ps.wait_exit([res], 2), [])
        finally:
            child.kill()
            child.wait()


if __name__ == "__main__":
    unittest.main()
