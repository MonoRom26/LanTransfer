"""Tiny usbmuxd client.

On Windows the "Apple Mobile Device Service" (installed with iTunes or the Microsoft Store app
"Apple Devices") listens on 127.0.0.1:27015. On macOS/Linux usbmuxd uses /var/run/usbmuxd.
With it we can open a TCP connection to a port on a USB-connected iPhone - no Wi-Fi needed.
"""
import os
import plistlib
import socket
import struct
import sys
from dataclasses import dataclass

WIN_ADDR = ("127.0.0.1", 27015)
UNIX_PATH = "/var/run/usbmuxd"
PROG = "lantransfer-pc"


class UsbmuxError(Exception):
    pass


class NoUsbmuxd(UsbmuxError):
    """The Apple USB service is not installed or not running."""


class DeviceGone(UsbmuxError):
    """The iPhone was unplugged."""


class PortRefused(UsbmuxError):
    """The iPhone is connected, but nothing listens on that port (server not started)."""


@dataclass
class Device:
    device_id: int
    serial: str

    @property
    def short(self) -> str:
        return self.serial[-4:] if self.serial else str(self.device_id)


def _open() -> socket.socket:
    override = os.environ.get("USBMUXD_SOCKET_ADDRESS", "")
    try:
        if override and ":" in override and not override.startswith("/"):
            host, port = override.rsplit(":", 1)
            s = socket.create_connection((host, int(port)), timeout=3)
        elif override:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3)
            s.connect(override)
        elif sys.platform.startswith("win"):
            s = socket.create_connection(WIN_ADDR, timeout=3)
        else:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3)
            s.connect(UNIX_PATH)
    except OSError as e:
        raise NoUsbmuxd("Apple USB service not found") from e
    return s


def _read(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise UsbmuxError("usbmuxd closed the connection")
        buf += chunk
    return buf


def _send(sock: socket.socket, message: dict, tag: int = 1) -> None:
    message = dict(message, ClientVersionString=PROG, ProgName=PROG)
    data = plistlib.dumps(message)
    sock.sendall(struct.pack("<IIII", 16 + len(data), 1, 8, tag) + data)


def _recv(sock: socket.socket) -> dict:
    length, _version, _request, _tag = struct.unpack("<IIII", _read(sock, 16))
    return plistlib.loads(_read(sock, length - 16))


def list_devices() -> list:
    """USB-connected iPhones (Wi-Fi sync devices are ignored)."""
    s = _open()
    try:
        _send(s, {"MessageType": "ListDevices"})
        resp = _recv(s)
    except (OSError, struct.error) as e:
        raise UsbmuxError(str(e)) from e
    finally:
        s.close()
    out = []
    for d in resp.get("DeviceList", []):
        props = d.get("Properties", {})
        if props.get("ConnectionType", "USB") != "USB":
            continue
        out.append(Device(int(d.get("DeviceID", props.get("DeviceID", 0))), props.get("SerialNumber", "")))
    return out


def connect(device_id: int, port: int, timeout: float = 15) -> socket.socket:
    """Open a TCP tunnel to `port` on the iPhone. The returned socket is a normal socket."""
    s = _open()
    try:
        _send(s, {"MessageType": "Connect", "DeviceID": device_id, "PortNumber": socket.htons(port)})
        resp = _recv(s)
    except (OSError, struct.error) as e:
        s.close()
        raise UsbmuxError(str(e)) from e
    number = resp.get("Number", -1)
    if number != 0:
        s.close()
        if number == 3:
            raise PortRefused("Nothing is listening on the iPhone")
        if number == 2:
            raise DeviceGone("The iPhone is not connected")
        raise UsbmuxError("usbmuxd error %s" % number)
    s.settimeout(timeout)
    return s
