"""Runs the PC app's logic against a fake iPhone and a fake usbmuxd (no hardware needed)."""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

from fake_usbmuxd import FakeUsbmuxd                      # noqa: E402
from lantransfer_pc import usbmux                         # noqa: E402
from lantransfer_pc.client import PhoneClient, PhoneError, Unauthorized, rjoin   # noqa: E402
from lantransfer_pc.mock_phone import MockPhone           # noqa: E402
from lantransfer_pc.transfers import TransferManager, unique_name   # noqa: E402


def wait_idle(mgr, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if not mgr.busy():
            return
        time.sleep(0.05)
    raise AssertionError("transfers did not finish")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.phone_dir = os.path.join(self.tmp, "phone")
        self.pc_dir = os.path.join(self.tmp, "pc")
        os.makedirs(self.pc_dir)
        self.phone = MockPhone(self.phone_dir).start()
        self.mux = FakeUsbmuxd(self.phone.port)
        os.environ["USBMUXD_SOCKET_ADDRESS"] = "127.0.0.1:%d" % self.mux.port

    def tearDown(self):
        self.phone.stop()
        os.environ.pop("USBMUXD_SOCKET_ADDRESS", None)

    def usb_client(self, password=""):
        dev = usbmux.list_devices()[0]
        return PhoneClient(usb_device=dev, port=8080, password=password)

    def wifi_client(self, password=""):
        return PhoneClient(host="127.0.0.1", port=self.phone.port, password=password)


class UsbTests(Base):
    def test_list_devices(self):
        devs = usbmux.list_devices()
        self.assertEqual(len(devs), 1)
        self.assertEqual(devs[0].short, "1234")

    def test_wifi_devices_ignored(self):
        self.mux.devices[0]["Properties"]["ConnectionType"] = "Network"
        self.assertEqual(usbmux.list_devices(), [])

    def test_info_over_usb(self):
        info = self.usb_client().info()
        self.assertEqual(info["app"], "LanTransfer")
        self.assertEqual(info["system"], "16.3.1")

    def test_port_refused_message(self):
        self.mux.listening_port = 9999            # server "not started"
        with self.assertRaises(PhoneError) as cm:
            self.usb_client().info()
        self.assertIn("Start Server", str(cm.exception))

    def test_no_usbmuxd(self):
        os.environ["USBMUXD_SOCKET_ADDRESS"] = "127.0.0.1:1"
        with self.assertRaises(usbmux.NoUsbmuxd):
            usbmux.list_devices()

    def test_password(self):
        self.phone.password = "secret"
        with self.assertRaises(Unauthorized):
            self.usb_client().info()
        self.assertEqual(self.usb_client("secret").info()["app"], "LanTransfer")


class ClientTests(Base):
    def test_upload_download_roundtrip(self):
        for c in (self.usb_client(), self.wifi_client()):
            src = os.path.join(self.pc_dir, "big.bin")
            data = os.urandom(1_500_000)
            with open(src, "wb") as f:
                f.write(data)
            seen = []
            c.upload(src, "", "big.bin", lambda d, t: seen.append((d, t)))
            self.assertEqual(seen[-1], (1_500_000, 1_500_000))
            out = os.path.join(self.pc_dir, "back-%s.bin" % c.mode)
            c.download("", "big.bin", out)
            with open(out, "rb") as f:
                self.assertEqual(f.read(), data)
            c.delete("", "big.bin")
            self.assertEqual([i.name for i in c.list("")], [])

    def test_folders_rename_unicode(self):
        c = self.usb_client()
        c.mkdir("", "Photos")
        c.mkdir("Photos", "2026")
        c.mkdir("Photos", "2026")                 # again: fine
        src = os.path.join(self.pc_dir, "ហេតុ 한국어 中文 & x.txt")
        with open(src, "w", encoding="utf-8") as f:
            f.write("hi")
        c.upload(src, "Photos/2026", os.path.basename(src))
        items = c.list("Photos/2026")
        self.assertEqual([i.name for i in items], [os.path.basename(src)])
        c.rename("Photos/2026", os.path.basename(src), "new name.txt")
        self.assertEqual(c.list("Photos/2026")[0].name, "new name.txt")
        self.assertTrue(c.list("")[0].is_dir)

    def test_bad_paths(self):
        c = self.wifi_client()
        with self.assertRaises(PhoneError):
            c.list("../etc")
        with self.assertRaises(PhoneError):
            c.mkdir("", ".hidden")

    def test_upload_empty_and_cancel(self):
        import threading
        c = self.wifi_client()
        empty = os.path.join(self.pc_dir, "empty.txt")
        open(empty, "w").close()
        c.upload(empty, "", "empty.txt")
        self.assertEqual(c.list("")[0].size, 0)
        big = os.path.join(self.pc_dir, "big.bin")
        with open(big, "wb") as f:
            f.write(os.urandom(2_000_000))
        ev = threading.Event()
        ev.set()
        from lantransfer_pc.client import Cancelled
        with self.assertRaises(Cancelled):
            c.upload(big, "", "big.bin", cancel=ev)


class ManagerTests(Base):
    def make_tree(self):
        root = os.path.join(self.pc_dir, "Album")
        os.makedirs(os.path.join(root, "sub", "deep"))
        for rel, n in [("a.txt", 10), ("sub/b.bin", 300000), ("sub/deep/c.txt", 5), (".hidden", 3)]:
            with open(os.path.join(root, rel), "wb") as f:
                f.write(os.urandom(n))
        return root

    def test_folder_upload_and_download(self):
        client = self.usb_client()
        mgr = TransferManager(lambda: client, lambda: "rename")
        album = self.make_tree()
        mgr.enqueue_upload([album], "")
        wait_idle(mgr)
        self.assertTrue(all(j.state == "done" for j in mgr.snapshot()), [(j.name, j.state, j.error) for j in mgr.snapshot()])
        self.assertTrue(os.path.isfile(os.path.join(self.phone_dir, "Album", "sub", "deep", "c.txt")))
        self.assertFalse(os.path.exists(os.path.join(self.phone_dir, "Album", ".hidden")))

        dest = os.path.join(self.tmp, "dl")
        mgr.clear_finished()
        mgr.enqueue_download([i for i in client.list("") if i.name == "Album"], "", dest)
        wait_idle(mgr)
        self.assertTrue(all(j.state == "done" for j in mgr.snapshot()), [(j.name, j.state, j.error) for j in mgr.snapshot()])
        with open(os.path.join(dest, "Album", "sub", "b.bin"), "rb") as a, \
                open(os.path.join(album, "sub", "b.bin"), "rb") as b:
            self.assertEqual(a.read(), b.read())
        mgr.stop()

    def test_conflict_policies(self):
        client = self.wifi_client()
        f = os.path.join(self.pc_dir, "same.txt")
        with open(f, "w") as fh:
            fh.write("one")
        policy = {"v": "rename"}
        mgr = TransferManager(lambda: client, lambda: policy["v"])
        for _ in range(2):
            mgr.enqueue_upload([f], "")
            wait_idle(mgr)
        self.assertEqual(sorted(i.name for i in client.list("")), ["same (1).txt", "same.txt"])
        policy["v"] = "skip"
        mgr.enqueue_upload([f], "")
        wait_idle(mgr)
        self.assertEqual(mgr.snapshot()[-1].state, "skipped")
        policy["v"] = "overwrite"
        with open(f, "w") as fh:
            fh.write("twotwo")
        mgr.enqueue_upload([f], "")
        wait_idle(mgr)
        sizes = {i.name: i.size for i in client.list("")}
        self.assertEqual(sizes["same.txt"], 6)
        mgr.stop()

    def test_failure_is_reported(self):
        client = self.wifi_client()
        mgr = TransferManager(lambda: client, lambda: "rename")
        mgr.enqueue_upload([os.path.join(self.pc_dir, "missing.txt")], "")   # ignored: not a file
        f = os.path.join(self.pc_dir, "x.txt")
        open(f, "w").write("x")
        mgr.enqueue_upload([f], "nope/folder")
        wait_idle(mgr)
        job = mgr.snapshot()[-1]
        self.assertEqual(job.state, "failed")
        self.assertTrue(job.error)
        mgr.stop()


class Helpers(unittest.TestCase):
    def test_unique_name(self):
        self.assertEqual(unique_name("a.txt", {"a.txt", "a (1).txt"}), "a (2).txt")
        self.assertEqual(unique_name("a", {"a"}), "a (1)")
        self.assertEqual(rjoin("", "x"), "x")
        self.assertEqual(rjoin("a/b", "c"), "a/b/c")


if __name__ == "__main__":
    unittest.main(verbosity=2)
