"""A fake usbmuxd (TCP) that tunnels 'Connect' requests to a local port. For tests only."""
import plistlib
import select
import socket
import struct
import threading


class FakeUsbmuxd:
    def __init__(self, phone_port, listening_port=8080):
        self.phone_port = phone_port
        self.listening_port = listening_port      # the "iPhone port" the app listens on
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(8)
        self.port = self.srv.getsockname()[1]
        self.devices = [{"DeviceID": 7, "MessageType": "Attached",
                         "Properties": {"ConnectionType": "USB", "DeviceID": 7, "SerialNumber": "00008101TEST1234"}}]
        threading.Thread(target=self._accept, daemon=True).start()

    def _read(self, c, n):
        b = b""
        while len(b) < n:
            d = c.recv(n - len(b))
            if not d:
                raise EOFError
            b += d
        return b

    def _reply(self, c, obj, tag):
        data = plistlib.dumps(obj)
        c.sendall(struct.pack("<IIII", 16 + len(data), 1, 8, tag) + data)

    def _accept(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            length, _v, _r, tag = struct.unpack("<IIII", self._read(c, 16))
            msg = plistlib.loads(self._read(c, length - 16))
            kind = msg.get("MessageType")
            if kind == "ListDevices":
                self._reply(c, {"DeviceList": self.devices}, tag)
                c.close()
            elif kind == "Connect":
                port = socket.ntohs(msg["PortNumber"])
                if port != self.listening_port:
                    self._reply(c, {"MessageType": "Result", "Number": 3}, tag)
                    c.close()
                    return
                up = socket.create_connection(("127.0.0.1", self.phone_port))
                self._reply(c, {"MessageType": "Result", "Number": 0}, tag)
                socks = [c, up]
                while True:
                    r, _, _ = select.select(socks, [], [], 30)
                    if not r:
                        break
                    done = False
                    for s in r:
                        data = s.recv(65536)
                        if not data:
                            done = True
                            break
                        (up if s is c else c).sendall(data)
                    if done:
                        break
                up.close()
                c.close()
        except Exception:
            try:
                c.close()
            except OSError:
                pass
