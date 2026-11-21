"""A fake iPhone server with the same API as the LAN Transfer app. Used for Demo mode and tests."""
import base64
import json
import os
import shutil
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


class MockPhone:
    def __init__(self, root, port=0, password=""):
        self.root = os.path.abspath(root)
        self.password = password
        os.makedirs(self.root, exist_ok=True)
        phone = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *args):
                pass

            # ---- helpers
            def _q(self):
                return {k: v[0] for k, v in parse_qs(urlparse(self.path).query, keep_blank_values=True).items()}

            def _send(self, status, body=b"", ctype="application/json"):
                if isinstance(body, (dict, list)):
                    body = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def _authorized(self):
                if not phone.password:
                    return True
                want = "Basic " + base64.b64encode(("admin:" + phone.password).encode()).decode()
                if self.headers.get("Authorization") == want:
                    return True
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="LAN Transfer"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return False

            @staticmethod
            def _name(n):
                n = (n or "").strip()
                n = os.path.basename(n)
                return None if (not n or n.startswith(".")) else n

            def _dir(self, rel):
                rel = (rel or "").strip("/ ")
                path = phone.root
                for part in [p for p in rel.split("/") if p]:
                    if part.startswith("."):
                        return None
                    path = os.path.join(path, part)
                return path if os.path.isdir(path) else None

            # ---- routes
            def do_GET(self):
                if not self._authorized():
                    return
                url = urlparse(self.path).path
                q = self._q()
                if url == "/api/info":
                    st = shutil.disk_usage(phone.root)
                    return self._send(200, {"app": "LanTransfer", "api": 2, "version": "1.3",
                                            "device": "Demo iPhone", "model": "iPhone", "system": "16.3.1",
                                            "free": st.free, "total": st.total})
                if url == "/api/list":
                    d = self._dir(q.get("dir"))
                    if d is None:
                        return self._send(404, b"No such folder", "text/plain")
                    items = []
                    for e in os.scandir(d):
                        if e.name.startswith("."):
                            continue
                        is_dir = e.is_dir()
                        if is_dir and q.get("all") != "1":
                            continue
                        st = e.stat()
                        items.append({"name": e.name, "size": 0 if is_dir else st.st_size,
                                      "date": st.st_mtime, "dir": is_dir})
                    return self._send(200, items)
                if url == "/download":
                    d, n = self._dir(q.get("dir")), self._name(q.get("name"))
                    if d is None or n is None or not os.path.isfile(os.path.join(d, n)):
                        return self._send(404, b"No such file", "text/plain")
                    path = os.path.join(d, n)
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(os.path.getsize(path)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    with open(path, "rb") as f:
                        shutil.copyfileobj(f, self.wfile, 256 * 1024)
                    return
                self._send(404, b"Not found", "text/plain")

            def do_POST(self):
                if not self._authorized():
                    return
                url = urlparse(self.path).path
                q = self._q()
                d = self._dir(q.get("dir"))
                if d is None:
                    return self._send(404, b"No such folder", "text/plain")
                n = self._name(q.get("name"))
                if n is None:
                    return self._send(400, b"Bad name", "text/plain")
                if url == "/upload":
                    length = self.headers.get("Content-Length")
                    if length is None:
                        return self._send(411, b"Length required", "text/plain")
                    target = os.path.join(d, n)
                    if os.path.isdir(target):
                        return self._send(409, b"A folder has that name", "text/plain")
                    tmp = os.path.join(phone.root, ".upload-" + uuid.uuid4().hex)
                    left = int(length)
                    with open(tmp, "wb") as f:
                        while left > 0:
                            chunk = self.rfile.read(min(256 * 1024, left))
                            if not chunk:
                                break
                            f.write(chunk)
                            left -= len(chunk)
                    if left > 0:
                        os.remove(tmp)
                        return
                    os.replace(tmp, target)
                    return self._send(200, {"ok": True})
                if url == "/mkdir":
                    path = os.path.join(d, n)
                    if os.path.exists(path):
                        return self._send(200, {"ok": True, "existed": True})
                    os.mkdir(path)
                    return self._send(200, {"ok": True})
                if url == "/delete":
                    path = os.path.join(d, n)
                    if os.path.isdir(path):
                        shutil.rmtree(path)
                    elif os.path.exists(path):
                        os.remove(path)
                    return self._send(200, {"ok": True})
                if url == "/rename":
                    new = self._name(q.get("to"))
                    if new is None:
                        return self._send(400, b"Bad name", "text/plain")
                    dest = os.path.join(d, new)
                    if os.path.exists(dest):
                        return self._send(409, b"Name exists", "text/plain")
                    os.rename(os.path.join(d, n), dest)
                    return self._send(200, {"ok": True})
                self._send(404, b"Not found", "text/plain")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.httpd.server_address[1]
        self._thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def make_demo_folder(path):
    os.makedirs(path, exist_ok=True)
    for name, text in [("photo.jpg", "x" * 2400), ("notes.txt", "Hello from the demo iPhone\n"),
                       ("holiday.mp4", "v" * 120000)]:
        with open(os.path.join(path, name), "w") as f:
            f.write(text)
    sub = os.path.join(path, "Zips")
    os.makedirs(sub, exist_ok=True)
    with open(os.path.join(sub, "readme.txt"), "w") as f:
        f.write("a file inside a folder\n")
    return path
