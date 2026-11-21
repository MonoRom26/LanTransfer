"""Transfer queue: uploads/downloads (files and whole folders) one after another in a worker thread."""
import collections
import itertools
import os
import threading
import time

from .client import Cancelled, rjoin


class Job:
    def __init__(self, job_id, kind, name, src, dst, size=0):
        self.id = job_id
        self.kind = kind            # up | down | up_dir | down_dir
        self.name = name
        self.src = src              # up: local file/folder path | down: remote folder path
        self.dst = dst              # up: remote folder path     | down: local folder path
        self.size = size
        self.done = 0
        self.state = "queued"       # queued running done failed cancelled skipped
        self.error = ""
        self.speed = 0.0
        self.shown_name = name
        self.cancel = threading.Event()
        self._t = 0.0
        self._d = 0

    @property
    def is_dir(self):
        return self.kind.endswith("_dir")

    @property
    def percent(self):
        if self.state == "done":
            return 100
        if self.size > 0:
            return min(100, int(self.done * 100 / self.size))
        return 0


def unique_name(name, existing):
    if name not in existing:
        return name
    base, ext = os.path.splitext(name)
    i = 1
    while True:
        candidate = "%s (%d)%s" % (base, i, ext)
        if candidate not in existing:
            return candidate
        i += 1


class TransferManager:
    def __init__(self, get_client, get_policy):
        self._get_client = get_client
        self._get_policy = get_policy
        self.jobs = []
        self._pending = collections.deque()
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._ids = itertools.count(1)
        self._stop = False
        self._had_work = False
        self._cache = {}
        self.on_idle = None
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    # ---- public API
    def add(self, kind, name, src, dst, size=0, front=False):
        with self._lock:
            job = Job(next(self._ids), kind, name, src, dst, size)
            self.jobs.append(job)
            if front:
                self._pending.appendleft(job.id)
            else:
                self._pending.append(job.id)
        self._wake.set()
        return job

    def enqueue_upload(self, paths, remote_dir):
        for p in paths:
            name = os.path.basename(p.rstrip("\\/"))
            if os.path.isdir(p):
                self.add("up_dir", name, p, remote_dir)
            elif os.path.isfile(p):
                self.add("up", name, p, remote_dir, size=os.path.getsize(p))

    def enqueue_download(self, items, remote_dir, local_dir):
        """items: list of client.Item"""
        for it in items:
            if it.is_dir:
                self.add("down_dir", it.name, remote_dir, local_dir)
            else:
                self.add("down", it.name, remote_dir, local_dir, size=it.size)

    def snapshot(self):
        with self._lock:
            return list(self.jobs)

    def cancel(self, job_id):
        with self._lock:
            for j in self.jobs:
                if j.id == job_id:
                    j.cancel.set()
                    if j.state == "queued":
                        j.state = "cancelled"

    def cancel_all(self):
        with self._lock:
            for j in self.jobs:
                if j.state in ("queued", "running"):
                    j.cancel.set()
                    if j.state == "queued":
                        j.state = "cancelled"

    def retry(self, job_id):
        with self._lock:
            for j in self.jobs:
                if j.id == job_id and j.state in ("failed", "cancelled"):
                    j.state = "queued"
                    j.error = ""
                    j.done = 0
                    j.cancel = threading.Event()
                    self._pending.append(j.id)
        self._wake.set()

    def clear_finished(self):
        with self._lock:
            self.jobs = [j for j in self.jobs if j.state in ("queued", "running")]

    def busy(self):
        with self._lock:
            return any(j.state in ("queued", "running") for j in self.jobs)

    def stop(self):
        self._stop = True
        self.cancel_all()
        self._wake.set()

    # ---- worker
    def _next(self):
        with self._lock:
            while self._pending:
                jid = self._pending.popleft()
                for j in self.jobs:
                    if j.id == jid and j.state == "queued":
                        j.state = "running"
                        return j
        return None

    def _loop(self):
        while not self._stop:
            job = self._next()
            if job is None:
                if self._had_work:
                    self._had_work = False
                    self._cache.clear()
                    cb = self.on_idle
                    if cb:
                        try:
                            cb()
                        except Exception:
                            pass
                self._wake.wait(0.4)
                self._wake.clear()
                continue
            self._had_work = True
            try:
                self._run(job)
                if job.state == "running":
                    job.state = "done"
            except Cancelled:
                job.state = "cancelled"
            except Exception as e:  # noqa: BLE001 - show every error to the user
                job.state = "failed"
                job.error = str(e)

    def _run(self, job):
        client = self._get_client()
        if client is None:
            raise RuntimeError("Not connected")
        if job.kind == "up":
            self._up(client, job)
        elif job.kind == "up_dir":
            self._up_dir(client, job)
        elif job.kind == "down":
            self._down(client, job)
        elif job.kind == "down_dir":
            self._down_dir(client, job)

    def _progress(self, job):
        def cb(done, total):
            now = time.time()
            job.done = done
            if total:
                job.size = total
            if now - job._t >= 0.4:
                if job._t:
                    inst = (done - job._d) / (now - job._t)
                    job.speed = inst if job.speed == 0 else 0.6 * job.speed + 0.4 * inst
                job._t = now
                job._d = done
        return cb

    def _remote_names(self, client, folder):
        if folder not in self._cache:
            self._cache[folder] = {i.name for i in client.list(folder)}
        return self._cache[folder]

    def _up(self, client, job):
        name = job.name
        existing = self._remote_names(client, job.dst)
        policy = self._get_policy()
        if name in existing:
            if policy == "skip":
                job.state = "skipped"
                return
            if policy == "rename":
                name = unique_name(name, existing)
        job.shown_name = name
        client.upload(job.src, job.dst, name, self._progress(job), job.cancel)
        existing.add(name)

    def _up_dir(self, client, job):
        client.mkdir(job.dst, job.name)
        remote = rjoin(job.dst, job.name)
        self._cache.pop(job.dst, None)
        entries = [e for e in sorted(os.listdir(job.src)) if not e.startswith(".")]
        for e in reversed(entries):
            path = os.path.join(job.src, e)
            if os.path.isdir(path):
                self.add("up_dir", e, path, remote, front=True)
            elif os.path.isfile(path):
                self.add("up", e, path, remote, size=os.path.getsize(path), front=True)

    def _down(self, client, job):
        os.makedirs(job.dst, exist_ok=True)
        name = job.name
        target = os.path.join(job.dst, name)
        policy = self._get_policy()
        if os.path.exists(target):
            if policy == "skip":
                job.state = "skipped"
                return
            if policy == "rename":
                name = unique_name(name, set(os.listdir(job.dst)))
                target = os.path.join(job.dst, name)
        job.shown_name = name
        client.download(job.src, job.name, target, self._progress(job), job.cancel)

    def _down_dir(self, client, job):
        local = os.path.join(job.dst, job.name)
        os.makedirs(local, exist_ok=True)
        remote = rjoin(job.src, job.name)
        items = client.list(remote)
        for it in reversed(items):
            if it.is_dir:
                self.add("down_dir", it.name, remote, local, front=True)
            else:
                self.add("down", it.name, remote, local, size=it.size, front=True)
