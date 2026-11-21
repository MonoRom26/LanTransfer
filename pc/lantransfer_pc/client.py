"""HTTP client for the LAN Transfer iPhone server (works over USB tunnel or Wi-Fi)."""
import base64
import http.client
import json
import os
from dataclasses import dataclass
from urllib.parse import quote, urlencode

from . import usbmux

CHUNK = 256 * 1024


class PhoneError(Exception):
    pass


class Unauthorized(PhoneError):
    pass


class OutdatedApp(PhoneError):
    pass


class Cancelled(PhoneError):
    pass


@dataclass
class Item:
    name: str
    is_dir: bool
    size: int
    mtime: float


class _UsbHTTPConnection(http.client.HTTPConnection):
    """HTTP connection that goes through the USB tunnel instead of the network."""

    def __init__(self, device_id: int, port: int, timeout: float):
        super().__init__("localhost", port, timeout=timeout)
        self._device_id = device_id
        self._phone_port = port

    def connect(self):
        self.sock = usbmux.connect(self._device_id, self._phone_port, self.timeout)


def rjoin(a: str, b: str) -> str:
    """Join two paths on the iPhone ('/' separated, relative to the app folder)."""
    return b if not a else a + "/" + b


class PhoneClient:
    def __init__(self, usb_device=None, host: str = "", port: int = 8080, password: str = ""):
        self.usb_device = usb_device
        self.host = host
        self.port = port
        self.password = password

    @property
    def mode(self) -> str:
        return "usb" if self.usb_device is not None else "wifi"

    def describe(self) -> str:
        if self.usb_device is not None:
            return "USB"
        return "Wi-Fi %s:%s" % (self.host, self.port)

    # ---- plumbing
    def _conn(self, timeout: float):
        if self.usb_device is not None:
            return _UsbHTTPConnection(self.usb_device.device_id, self.port, timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def _headers(self) -> dict:
        h = {}
        if self.password:
            token = base64.b64encode(("admin:" + self.password).encode()).decode()
            h["Authorization"] = "Basic " + token
        return h

    @staticmethod
    def _url(path: str, params: dict) -> str:
        return path + "?" + urlencode(params, quote_via=quote) if params else path

    def _wrap(self, e: Exception) -> PhoneError:
        if isinstance(e, usbmux.PortRefused):
            return PhoneError("The iPhone app is not running its server. Open LAN Transfer and tap Start Server.")
        if isinstance(e, usbmux.DeviceGone):
            return PhoneError("The iPhone was unplugged.")
        if isinstance(e, usbmux.NoUsbmuxd):
            return PhoneError("Apple USB driver not found. Install 'Apple Devices' (Microsoft Store) or iTunes.")
        if isinstance(e, PhoneError):
            return e
        return PhoneError("Connection problem: %s" % e)

    def request(self, method: str, path: str, params: dict = None, timeout: float = 15):
        conn = self._conn(timeout)
        try:
            conn.request(method, self._url(path, params or {}), headers=self._headers())
            resp = conn.getresponse()
            body = resp.read()
        except (OSError, http.client.HTTPException, usbmux.UsbmuxError) as e:
            raise self._wrap(e) from e
        finally:
            conn.close()
        if resp.status == 401:
            raise Unauthorized("Wrong or missing password.")
        return resp.status, body

    def _ok(self, method: str, path: str, params: dict = None) -> bytes:
        status, body = self.request(method, path, params)
        if status != 200:
            raise PhoneError("iPhone said %s: %s" % (status, body[:120].decode("utf-8", "replace")))
        return body

    # ---- API
    def info(self) -> dict:
        status, body = self.request("GET", "/api/info")
        if status == 404:
            raise OutdatedApp("The iPhone app is too old. Update LAN Transfer to version 1.3 or newer.")
        if status != 200:
            raise PhoneError("iPhone said %s" % status)
        try:
            return json.loads(body)
        except ValueError as e:
            raise PhoneError("Unexpected answer from the iPhone") from e

    def list(self, path: str = "") -> list:
        body = self._ok("GET", "/api/list", {"dir": path, "all": "1"})
        out = []
        for d in json.loads(body):
            out.append(Item(d["name"], bool(d.get("dir")), int(d.get("size", 0)), float(d.get("date", 0))))
        return out

    def mkdir(self, path: str, name: str) -> None:
        self._ok("POST", "/mkdir", {"dir": path, "name": name})

    def delete(self, path: str, name: str) -> None:
        self._ok("POST", "/delete", {"dir": path, "name": name})

    def rename(self, path: str, name: str, new_name: str) -> None:
        self._ok("POST", "/rename", {"dir": path, "name": name, "to": new_name})

    def upload(self, local_path: str, remote_dir: str, remote_name: str, progress=None, cancel=None) -> None:
        size = os.path.getsize(local_path)
        conn = self._conn(60)
        try:
            conn.putrequest("POST", self._url("/upload", {"dir": remote_dir, "name": remote_name}))
            for k, v in self._headers().items():
                conn.putheader(k, v)
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("Content-Length", str(size))
            conn.endheaders()
            sent = 0
            with open(local_path, "rb") as f:
                while True:
                    if cancel is not None and cancel.is_set():
                        raise Cancelled()
                    chunk = f.read(CHUNK)
                    if not chunk:
                        break
                    conn.send(chunk)
                    sent += len(chunk)
                    if progress:
                        progress(sent, size)
            resp = conn.getresponse()
            body = resp.read()
        except Cancelled:
            raise
        except (OSError, http.client.HTTPException, usbmux.UsbmuxError) as e:
            raise self._wrap(e) from e
        finally:
            conn.close()
        if resp.status == 401:
            raise Unauthorized("Wrong or missing password.")
        if resp.status != 200:
            raise PhoneError("Upload failed (%s): %s" % (resp.status, body[:120].decode("utf-8", "replace")))

    def download(self, remote_dir: str, remote_name: str, local_path: str, progress=None, cancel=None) -> None:
        part = local_path + ".part"
        conn = self._conn(60)
        try:
            conn.request("GET", self._url("/download", {"dir": remote_dir, "name": remote_name}),
                         headers=self._headers())
            resp = conn.getresponse()
            if resp.status == 401:
                raise Unauthorized("Wrong or missing password.")
            if resp.status != 200:
                raise PhoneError("Download failed (%s)" % resp.status)
            total = int(resp.getheader("Content-Length") or 0)
            got = 0
            with open(part, "wb") as f:
                while True:
                    if cancel is not None and cancel.is_set():
                        raise Cancelled()
                    chunk = resp.read(CHUNK)
                    if not chunk:
                        break
                    f.write(chunk)
                    got += len(chunk)
                    if progress:
                        progress(got, total)
            if total and got != total:
                raise PhoneError("Download incomplete (%d of %d bytes)" % (got, total))
            os.replace(part, local_path)
        except (OSError, http.client.HTTPException, usbmux.UsbmuxError) as e:
            raise self._wrap(e) from e
        except BaseException:
            raise
        finally:
            conn.close()
            if os.path.exists(part):
                try:
                    os.remove(part)
                except OSError:
                    pass
