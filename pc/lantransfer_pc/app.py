"""LAN Transfer for PC - two-pane file manager (PC on the left, iPhone on the right)."""
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

from . import __version__, usbmux
from . import settings as cfg
from .client import Item, OutdatedApp, PhoneClient, PhoneError, Unauthorized, rjoin
from .transfers import TransferManager

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
    HAS_DND = True
except Exception:  # drag and drop from Explorer is optional
    TkinterDnD = None
    DND_FILES = None
    HAS_DND = False

LIGHT = dict(bg="#f2f2f2", fg="#1b1b1b", field="#ffffff", sel="#cfe3ff", sel_fg="#000000", sub="#666666")
DARK = dict(bg="#1f2125", fg="#e8e8e8", field="#2a2d33", sel="#3b6ea5", sel_fg="#ffffff", sub="#9aa0a6")
PILL = {"connected": "#2e7d32", "waiting": "#ef6c00", "error": "#c62828", "idle": "#757575"}
CONFLICT_LABELS = {"rename": "Keep both (add a number)", "overwrite": "Replace the old file", "skip": "Skip it"}


# ---------------------------------------------------------------- helpers
def fmt_size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024


def fmt_time(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else ""


def open_path(path):
    try:
        if sys.platform.startswith("win"):
            os.startfile(path)  # noqa: S606
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])
    except OSError:
        pass


def list_pc(path, show_hidden=False):
    if path == "" and os.name == "nt":
        return [Item("%s:\\" % c, True, 0, 0) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" if os.path.exists("%s:\\" % c)]
    items = []
    with os.scandir(path) as it:
        for e in it:
            try:
                st = e.stat()
                hidden = e.name.startswith(".") or bool(getattr(st, "st_file_attributes", 0) & 2)
                if hidden and not show_hidden:
                    continue
                is_dir = e.is_dir()
                items.append(Item(e.name, is_dir, 0 if is_dir else st.st_size, st.st_mtime))
            except OSError:
                continue
    return items


def pc_parent(path):
    if path == "":
        return ""
    parent = os.path.dirname(path.rstrip("\\/"))
    if parent == path or parent == "":
        return "" if os.name == "nt" else path
    if os.name == "nt" and len(parent) == 2 and parent[1] == ":":
        return parent + "\\"
    return parent


# ---------------------------------------------------------------- one file pane
class FilePane(ttk.Frame):
    def __init__(self, master, app, kind):
        super().__init__(master)
        self.app = app
        self.kind = kind                  # "pc" or "phone"
        self.path = ""
        self.items = []
        self.shown = []
        self.sort_col = "name"
        self.sort_rev = False
        self.filter_var = tk.StringVar()
        self.path_var = tk.StringVar()
        self._build()

    def _build(self):
        title = "🖥  This PC" if self.kind == "pc" else "📱  iPhone"
        head = ttk.Frame(self)
        head.pack(fill="x")
        ttk.Label(head, text=title, font=("Segoe UI", 11, "bold")).pack(side="left")
        self.count_lbl = ttk.Label(head, text="")
        self.count_lbl.pack(side="right")

        bar = ttk.Frame(self)
        bar.pack(fill="x", pady=(4, 2))
        ttk.Button(bar, text="⬆", width=3, command=self.up).pack(side="left")
        ttk.Button(bar, text="⟳", width=3, command=self.refresh).pack(side="left", padx=2)
        entry = ttk.Entry(bar, textvariable=self.path_var)
        entry.pack(side="left", fill="x", expand=True, padx=2)
        entry.bind("<Return>", lambda e: self.go_typed())
        ttk.Button(bar, text="＋ Folder", command=self.new_folder).pack(side="left")

        flt = ttk.Frame(self)
        flt.pack(fill="x", pady=(0, 4))
        ttk.Label(flt, text="Search:").pack(side="left")
        ttk.Entry(flt, textvariable=self.filter_var).pack(side="left", fill="x", expand=True, padx=4)
        self.filter_var.trace_add("write", lambda *a: self.render())

        frame = ttk.Frame(self)
        frame.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(frame, columns=("name", "size", "date"), show="headings", selectmode="extended")
        for col, text, width, anchor in (("name", "Name", 260, "w"), ("size", "Size", 80, "e"),
                                         ("date", "Modified", 130, "w")):
            self.tree.heading(col, text=text, command=lambda c=col: self.sort_by(c))
            self.tree.column(col, width=width, anchor=anchor, stretch=(col == "name"))
        sb = ttk.Scrollbar(frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

        self.tree.bind("<Double-1>", lambda e: self.open_selected())
        self.tree.bind("<Return>", lambda e: self.open_selected())
        self.tree.bind("<BackSpace>", lambda e: self.up())
        self.tree.bind("<Button-3>", self.popup)
        self.tree.bind("<Button-2>", self.popup)
        self.tree.bind("<FocusIn>", lambda e: self.app.set_active(self))
        self.tree.bind("<Control-a>", self.select_all)

        self.menu = tk.Menu(self, tearoff=0)

    # ---- data
    def set_items(self, items):
        self.items = items
        self.render()

    def render(self):
        text = self.filter_var.get().strip().lower()
        items = [i for i in self.items if not text or text in i.name.lower()]
        keys = {"name": lambda i: i.name.lower(), "size": lambda i: i.size, "date": lambda i: i.mtime}
        key = keys[self.sort_col]
        dirs = sorted([i for i in items if i.is_dir], key=key, reverse=self.sort_rev)
        files = sorted([i for i in items if not i.is_dir], key=key, reverse=self.sort_rev)
        self.shown = dirs + files
        self.tree.delete(*self.tree.get_children())
        for idx, it in enumerate(self.shown):
            icon = "📁 " if it.is_dir else "📄 "
            self.tree.insert("", "end", iid=str(idx),
                             values=(icon + it.name, "" if it.is_dir else fmt_size(it.size), fmt_time(it.mtime)))
        total = sum(i.size for i in self.items if not i.is_dir)
        self.count_lbl.configure(text="%d items • %s" % (len(self.items), fmt_size(total)))
        if self.kind == "pc":
            self.path_var.set(self.path if self.path else "This PC")
        else:
            self.path_var.set("/" + self.path)

    def selected(self):
        return [self.shown[int(i)] for i in self.tree.selection() if int(i) < len(self.shown)]

    def select_all(self, event=None):
        self.tree.selection_set(self.tree.get_children())
        return "break"

    def sort_by(self, col):
        if self.sort_col == col:
            self.sort_rev = not self.sort_rev
        else:
            self.sort_col, self.sort_rev = col, False
        self.render()

    # ---- navigation
    def navigate(self, path):
        self.path = path
        if self.kind == "pc":
            self.app.settings["pc_dir"] = path
        self.refresh()

    def refresh(self):
        if self.kind == "pc":
            try:
                self.set_items(list_pc(self.path, self.app.settings["show_hidden"]))
            except OSError as e:
                self.app.say("Cannot open that folder: %s" % e, error=True)
                if self.path:
                    self.path = pc_parent(self.path)
                    self.set_items([])
        else:
            self.app.refresh_phone()

    def up(self):
        if self.kind == "pc":
            self.navigate(pc_parent(self.path))
        elif self.path:
            self.navigate(self.path.rsplit("/", 1)[0] if "/" in self.path else "")

    def go_typed(self):
        text = self.path_var.get().strip()
        if self.kind == "pc":
            if os.path.isdir(text):
                self.navigate(text)
            else:
                self.app.say("That folder does not exist.", error=True)
                self.render()
        else:
            self.navigate(text.strip("/ "))

    def open_selected(self):
        sel = self.selected()
        if not sel:
            return
        it = sel[0]
        if it.is_dir:
            if self.kind == "pc":
                self.navigate(os.path.join(self.path, it.name) if self.path else it.name)
            else:
                self.navigate(rjoin(self.path, it.name))
        elif self.kind == "pc":
            open_path(os.path.join(self.path, it.name))
        else:
            self.app.get_selected()

    def new_folder(self):
        name = simpledialog.askstring("New folder", "Folder name:", parent=self.winfo_toplevel())
        if not name or not name.strip():
            return
        name = name.strip()
        if self.kind == "pc":
            if not self.path:
                self.app.say("Open a folder first.", error=True)
                return
            try:
                os.makedirs(os.path.join(self.path, name), exist_ok=True)
            except OSError as e:
                self.app.say("Could not create the folder: %s" % e, error=True)
            self.refresh()
        else:
            self.app.phone_task(lambda c: c.mkdir(self.path, name), "Folder created.")

    # ---- context menu
    def popup(self, event):
        row = self.tree.identify_row(event.y)
        if row and row not in self.tree.selection():
            self.tree.selection_set(row)
        self.app.set_active(self)
        m = self.menu
        m.delete(0, "end")
        m.add_command(label="Open", command=self.open_selected)
        if self.kind == "pc":
            m.add_command(label="Send to iPhone  →", command=self.app.send_selected)
        else:
            m.add_command(label="←  Get to PC", command=self.app.get_selected)
        m.add_separator()
        m.add_command(label="Rename (F2)", command=lambda: self.app.rename_selected(self))
        m.add_command(label="Delete (Del)", command=lambda: self.app.delete_selected(self))
        m.add_command(label="New folder", command=self.new_folder)
        m.add_command(label="Refresh (F5)", command=self.refresh)
        try:
            m.tk_popup(event.x_root, event.y_root)
        finally:
            m.grab_release()


# ---------------------------------------------------------------- main window
class App:
    def __init__(self):
        try:  # sharp text on Windows
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
        self.settings = cfg.load()
        self.root = TkinterDnD.Tk() if HAS_DND else tk.Tk()
        self.root.title("LAN Transfer for PC  %s" % __version__)
        self.root.geometry(self.settings.get("geometry", "1100x700"))
        self.root.minsize(900, 560)

        self.client = None
        self.info = {}
        self.connecting = False
        self.heartbeating = False
        self.demo = None
        self.active = None
        self._ui = queue.Queue()

        self.mode_var = tk.StringVar(value=self.settings["mode"])
        self.host_var = tk.StringVar(value=self.settings["host"])
        self.port_var = tk.StringVar(value=str(self.settings["port"]))
        self.pw_var = tk.StringVar(value=self.settings["password"])
        self.auto_var = tk.BooleanVar(value=self.settings["auto_connect"])
        self.dark_var = tk.BooleanVar(value=self.settings["dark"])
        self.hidden_var = tk.BooleanVar(value=self.settings["show_hidden"])

        self.manager = TransferManager(lambda: self.client, lambda: self.settings["conflict"])
        self.manager.on_idle = lambda: self._ui.put(self.after_batch)

        self.apply_theme()
        self.build_menu()
        self.build_ui()
        self.on_mode()
        self.set_pill("idle", "Not connected")

        start = self.settings.get("pc_dir") or os.path.expanduser("~")
        self.pc_pane.path = start if os.path.isdir(start) else os.path.expanduser("~")
        self.pc_pane.refresh()

        self.root.bind("<F5>", lambda e: self.key(lambda: self.active_pane().refresh()))
        self.root.bind("<Delete>", lambda e: self.key(lambda: self.delete_selected(self.active_pane())))
        self.root.bind("<F2>", lambda e: self.key(lambda: self.rename_selected(self.active_pane())))
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.pump()
        self.update_queue()
        self.root.after(1200, self.tick)

    # ---- plumbing
    def key(self, fn):
        if isinstance(self.root.focus_get(), (tk.Entry, ttk.Entry)):
            return
        fn()

    def active_pane(self):
        return self.active or self.pc_pane

    def set_active(self, pane):
        self.active = pane

    def pump(self):
        try:
            while True:
                fn = self._ui.get_nowait()
                fn()
        except queue.Empty:
            pass
        self.root.after(60, self.pump)

    def run_bg(self, work, done=None):
        def target():
            try:
                res, err = work(), None
            except Exception as e:  # noqa: BLE001
                res, err = None, e
            if done:
                self._ui.put(lambda: done(res, err))
        threading.Thread(target=target, daemon=True).start()

    def say(self, text, error=False):
        self.status.configure(text=text, foreground="#d32f2f" if error else self.palette["fg"])

    def explain(self, err):
        if isinstance(err, usbmux.NoUsbmuxd):
            return "Apple USB driver not found. Install 'Apple Devices' (Microsoft Store) or iTunes."
        if isinstance(err, usbmux.PortRefused):
            return "iPhone found. Open LAN Transfer on it and tap Start Server."
        return str(err) or err.__class__.__name__

    # ---- theme
    def apply_theme(self):
        self.palette = DARK if self.dark_var.get() else LIGHT
        P = self.palette
        s = ttk.Style()
        try:
            s.theme_use("clam")
        except tk.TclError:
            pass
        s.configure(".", background=P["bg"], foreground=P["fg"], fieldbackground=P["field"])
        for name in ("TFrame", "TLabel", "TCheckbutton", "TRadiobutton", "TLabelframe"):
            s.configure(name, background=P["bg"], foreground=P["fg"])
        s.configure("TLabelframe.Label", background=P["bg"], foreground=P["fg"])
        s.configure("TButton", padding=4)
        s.configure("TEntry", fieldbackground=P["field"], foreground=P["fg"])
        s.configure("Treeview", background=P["field"], fieldbackground=P["field"], foreground=P["fg"],
                    rowheight=24, borderwidth=0)
        s.map("Treeview", background=[("selected", P["sel"])], foreground=[("selected", P["sel_fg"])])
        s.configure("Treeview.Heading", background=P["bg"], foreground=P["fg"], relief="flat")
        self.root.configure(bg=P["bg"])
        if hasattr(self, "pill"):
            self.status.configure(background=P["bg"], foreground=P["fg"])
            self.info_lbl.configure(foreground=P["sub"])

    # ---- menu
    def build_menu(self):
        bar = tk.Menu(self.root)
        file_m = tk.Menu(bar, tearoff=0)
        file_m.add_command(label="Open download folder", command=lambda: open_path(self.download_dir()))
        file_m.add_command(label="Settings…", command=self.open_settings)
        file_m.add_separator()
        file_m.add_command(label="Quit", command=self.on_close)
        bar.add_cascade(label="File", menu=file_m)
        view_m = tk.Menu(bar, tearoff=0)
        view_m.add_checkbutton(label="Dark mode", variable=self.dark_var, command=self.on_theme)
        view_m.add_checkbutton(label="Show hidden files (PC)", variable=self.hidden_var, command=self.on_hidden)
        bar.add_cascade(label="View", menu=view_m)
        tools_m = tk.Menu(bar, tearoff=0)
        tools_m.add_command(label="Try demo mode (no iPhone needed)", command=self.start_demo)
        tools_m.add_command(label="USB help…", command=self.usb_help)
        bar.add_cascade(label="Tools", menu=tools_m)
        help_m = tk.Menu(bar, tearoff=0)
        help_m.add_command(label="About", command=self.about)
        bar.add_cascade(label="Help", menu=help_m)
        self.root.configure(menu=bar)

    def on_theme(self):
        self.settings["dark"] = self.dark_var.get()
        self.apply_theme()

    def on_hidden(self):
        self.settings["show_hidden"] = self.hidden_var.get()
        self.pc_pane.refresh()

    # ---- layout
    def build_ui(self):
        top = ttk.Frame(self.root)
        top.pack(fill="x", padx=8, pady=(8, 2))
        ttk.Label(top, text="Connection:").pack(side="left")
        ttk.Radiobutton(top, text="USB", variable=self.mode_var, value="usb", command=self.on_mode).pack(side="left", padx=(6, 0))
        ttk.Radiobutton(top, text="Wi-Fi", variable=self.mode_var, value="wifi", command=self.on_mode).pack(side="left", padx=6)
        ttk.Label(top, text="Address:").pack(side="left")
        self.host_entry = ttk.Entry(top, textvariable=self.host_var, width=16)
        self.host_entry.pack(side="left", padx=(4, 2))
        ttk.Label(top, text=":").pack(side="left")
        self.port_entry = ttk.Entry(top, textvariable=self.port_var, width=6)
        self.port_entry.pack(side="left", padx=(2, 8))
        ttk.Label(top, text="Password:").pack(side="left")
        ttk.Entry(top, textvariable=self.pw_var, show="•", width=12).pack(side="left", padx=(4, 8))
        self.connect_btn = ttk.Button(top, text="Connect", command=self.connect)
        self.connect_btn.pack(side="left")
        ttk.Button(top, text="Disconnect", command=self.disconnect).pack(side="left", padx=4)
        self.pill = tk.Label(top, text="", fg="white", padx=10, pady=2, font=("Segoe UI", 9, "bold"))
        self.pill.pack(side="right")

        sub = ttk.Frame(self.root)
        sub.pack(fill="x", padx=8)
        self.auto_chk = ttk.Checkbutton(sub, text="Connect automatically when an iPhone is plugged in",
                                        variable=self.auto_var)
        self.auto_chk.pack(side="left")
        self.info_lbl = ttk.Label(sub, text="", foreground=self.palette["sub"])
        self.info_lbl.pack(side="right")

        main = ttk.Frame(self.root)
        main.pack(fill="both", expand=True, padx=8, pady=6)
        main.columnconfigure(0, weight=1)
        main.columnconfigure(2, weight=1)
        main.rowconfigure(0, weight=1)
        self.pc_pane = FilePane(main, self, "pc")
        self.pc_pane.grid(row=0, column=0, sticky="nsew")
        mid = ttk.Frame(main)
        mid.grid(row=0, column=1, padx=8)
        ttk.Button(mid, text="Send  →", width=14, command=self.send_selected).pack(pady=(60, 6))
        ttk.Button(mid, text="←  Get", width=14, command=self.get_selected).pack(pady=6)
        ttk.Separator(mid).pack(fill="x", pady=10)
        ttk.Button(mid, text="Upload files…", width=14, command=self.upload_files_dialog).pack(pady=6)
        ttk.Button(mid, text="Upload folder…", width=14, command=self.upload_folder_dialog).pack(pady=6)
        self.phone_pane = FilePane(main, self, "phone")
        self.phone_pane.grid(row=0, column=2, sticky="nsew")
        self.active = self.pc_pane

        box = ttk.LabelFrame(self.root, text="Transfers")
        box.pack(fill="x", padx=8, pady=(0, 4))
        cols = ("name", "dir", "size", "progress", "speed", "status")
        self.queue_tree = ttk.Treeview(box, columns=cols, show="headings", height=5, selectmode="extended")
        for col, text, width, anchor in (("name", "Name", 300, "w"), ("dir", "", 40, "center"),
                                         ("size", "Size", 80, "e"), ("progress", "Progress", 80, "e"),
                                         ("speed", "Speed", 90, "e"), ("status", "Status", 220, "w")):
            self.queue_tree.heading(col, text=text)
            self.queue_tree.column(col, width=width, anchor=anchor, stretch=(col in ("name", "status")))
        self.queue_tree.pack(side="left", fill="x", expand=True, padx=(4, 0), pady=4)
        btns = ttk.Frame(box)
        btns.pack(side="right", padx=6)
        ttk.Button(btns, text="Cancel selected", command=self.cancel_selected).pack(fill="x", pady=1)
        ttk.Button(btns, text="Cancel all", command=self.manager.cancel_all).pack(fill="x", pady=1)
        ttk.Button(btns, text="Retry selected", command=self.retry_selected).pack(fill="x", pady=1)
        ttk.Button(btns, text="Clear finished", command=self.clear_finished).pack(fill="x", pady=1)

        self.summary = ttk.Label(self.root, text="")
        self.summary.pack(fill="x", padx=10)
        self.status = ttk.Label(self.root, text="Ready.", anchor="w")
        self.status.pack(fill="x", padx=10, pady=(0, 6))

        if HAS_DND:
            for w in (self.phone_pane.tree, self.phone_pane):
                try:
                    w.drop_target_register(DND_FILES)
                    w.dnd_bind("<<Drop>>", self.on_drop)
                except Exception:
                    pass

    # ---- connection
    def on_mode(self):
        wifi = self.mode_var.get() == "wifi"
        state = "normal" if wifi else "disabled"
        self.host_entry.configure(state=state)
        self.auto_chk.configure(state="disabled" if wifi else "normal")
        self.settings["mode"] = self.mode_var.get()

    def set_pill(self, state, text):
        self.pill.configure(text=text, bg=PILL[state])

    def connect(self, silent=False):
        if self.connecting:
            return
        mode = self.mode_var.get()
        pw = self.pw_var.get()
        try:
            port = int(self.port_var.get() or 8080)
        except ValueError:
            self.say("The port must be a number.", error=True)
            return
        host = self.host_var.get().strip()
        self.connecting = True
        if not silent:
            self.set_pill("waiting", "Connecting…")

        def work():
            if mode == "usb":
                devices = usbmux.list_devices()
                if not devices:
                    raise PhoneError("No iPhone found. Plug it in, unlock it and tap Trust.")
                client = PhoneClient(usb_device=devices[0], port=port, password=pw)
            else:
                if not host:
                    raise PhoneError("Type the address shown in the iPhone app (for example 192.168.1.23).")
                client = PhoneClient(host=host, port=port, password=pw)
            return client, client.info()

        self.run_bg(work, lambda res, err: self.on_connected(res, err, silent))

    def on_connected(self, res, err, silent):
        self.connecting = False
        if err is not None:
            msg = self.explain(err)
            if self.mode_var.get() == "usb" and not isinstance(err, (Unauthorized, OutdatedApp)):
                self.set_pill("error" if isinstance(err, usbmux.NoUsbmuxd) else "waiting",
                              "USB driver missing" if isinstance(err, usbmux.NoUsbmuxd) else "Waiting for iPhone…")
            else:
                self.set_pill("error", "Not connected")
            if not silent or isinstance(err, (Unauthorized, OutdatedApp)):
                self.say(msg, error=True)
            else:
                self.info_lbl.configure(text=msg)
            return
        client, info = res
        self.client = client
        self.info = info
        self.set_pill("connected", "● Connected • " + client.describe())
        self.show_info()
        self.say("Connected. Drag files onto the iPhone side, or select files and press Send →")
        self.phone_pane.path = ""
        self.refresh_phone()
        self.settings["host"] = self.host_var.get().strip()
        self.settings["password"] = self.pw_var.get()
        try:
            self.settings["port"] = int(self.port_var.get() or 8080)
        except ValueError:
            pass

    def show_info(self):
        i = self.info
        parts = [i.get("device", "iPhone")]
        if i.get("system"):
            parts.append("iOS " + i["system"])
        if i.get("free") is not None and i.get("total"):
            parts.append("%s free of %s" % (fmt_size(i["free"]), fmt_size(i["total"])))
        if i.get("version"):
            parts.append("app " + i["version"])
        self.info_lbl.configure(text="  •  ".join(parts))

    def disconnect(self, reason=None):
        self.client = None
        self.manager.cancel_all()
        self.phone_pane.set_items([])
        self.set_pill("idle", "Not connected")
        self.info_lbl.configure(text="")
        if reason:
            self.say(reason, error=True)

    def tick(self):
        usb = self.mode_var.get() == "usb"
        if self.client is None:
            if usb and self.auto_var.get() and not self.connecting:
                self.connect(silent=True)
        elif not self.connecting and not self.heartbeating:
            self.heartbeating = True
            c = self.client

            def done(res, err):
                self.heartbeating = False
                if c is not self.client:
                    return
                if err is not None:
                    self.disconnect("Lost the connection: " + self.explain(err))
                else:
                    self.info = res
                    self.show_info()

            self.run_bg(c.info, done)
        self.root.after(3000, self.tick)

    # ---- iPhone listing and tasks
    def refresh_phone(self):
        if self.client is None:
            self.phone_pane.set_items([])
            return
        client, path = self.client, self.phone_pane.path

        def done(items, err):
            if client is not self.client:
                return
            if err is not None:
                if "No such folder" in str(err) and path:
                    self.phone_pane.navigate("")
                else:
                    self.say(self.explain(err), error=True)
                return
            self.phone_pane.set_items(items)

        self.run_bg(lambda: client.list(path), done)

    def phone_task(self, fn, ok_text=None):
        if self.client is None:
            self.say("Connect to the iPhone first.", error=True)
            return
        client = self.client

        def done(_res, err):
            if err is not None:
                self.say(self.explain(err), error=True)
            elif ok_text:
                self.say(ok_text)
            self.refresh_phone()

        self.run_bg(lambda: fn(client), done)

    # ---- transfers
    def download_dir(self):
        d = self.settings.get("download_dir") or os.path.expanduser("~")
        os.makedirs(d, exist_ok=True)
        return d

    def send_paths(self, paths):
        if self.client is None:
            self.say("Connect to the iPhone first.", error=True)
            return
        paths = [p for p in paths if os.path.exists(p)]
        if not paths:
            return
        self.manager.enqueue_upload(paths, self.phone_pane.path)
        self.say("Queued %d item(s) for the iPhone." % len(paths))

    def send_selected(self):
        sel = self.pc_pane.selected()
        if not sel:
            self.say("Select files or folders on the PC side first.", error=True)
            return
        if not self.pc_pane.path:
            self.say("Open a folder first.", error=True)
            return
        self.send_paths([os.path.join(self.pc_pane.path, i.name) for i in sel])

    def get_selected(self):
        if self.client is None:
            self.say("Connect to the iPhone first.", error=True)
            return
        sel = self.phone_pane.selected()
        if not sel:
            self.say("Select files or folders on the iPhone side first.", error=True)
            return
        dest = self.pc_pane.path or self.download_dir()
        self.manager.enqueue_download(sel, self.phone_pane.path, dest)
        self.say("Queued %d item(s) for %s" % (len(sel), dest))

    def upload_files_dialog(self):
        paths = filedialog.askopenfilenames(parent=self.root, title="Choose files to send to the iPhone")
        if paths:
            self.send_paths(list(paths))

    def upload_folder_dialog(self):
        path = filedialog.askdirectory(parent=self.root, title="Choose a folder to send to the iPhone")
        if path:
            self.send_paths([path])

    def on_drop(self, event):
        try:
            paths = list(self.root.tk.splitlist(event.data))
        except Exception:
            paths = []
        self.send_paths(paths)

    def after_batch(self):
        self.pc_pane.refresh()
        self.refresh_phone()
        failed = [j for j in self.manager.snapshot() if j.state == "failed"]
        if failed:
            self.say("%d transfer(s) failed. Select one in the list to see why, then press Retry." % len(failed), error=True)
        else:
            self.say("All transfers finished.")

    def cancel_selected(self):
        for iid in self.queue_tree.selection():
            self.manager.cancel(int(iid))

    def retry_selected(self):
        for iid in self.queue_tree.selection():
            self.manager.retry(int(iid))

    def clear_finished(self):
        self.manager.clear_finished()
        self.queue_tree.delete(*self.queue_tree.get_children())

    def update_queue(self):
        jobs = self.manager.snapshot()
        existing = set(self.queue_tree.get_children())
        wanted = set()
        running = queued = done = failed = 0
        speed = 0.0
        for j in jobs:
            iid = str(j.id)
            wanted.add(iid)
            if j.state == "running":
                running += 1
                speed += j.speed
            elif j.state == "queued":
                queued += 1
            elif j.state == "done":
                done += 1
            elif j.state == "failed":
                failed += 1
            arrow = "↑" if j.kind.startswith("up") else "↓"
            name = ("📁 " if j.is_dir else "") + j.shown_name
            size = "" if j.is_dir else fmt_size(j.size)
            pct = "" if j.is_dir else "%d%%" % j.percent
            spd = "%s/s" % fmt_size(j.speed) if j.state == "running" and j.speed else ""
            status = {"queued": "Waiting", "running": "Working…", "done": "Done", "failed": "Failed: " + j.error,
                      "cancelled": "Cancelled", "skipped": "Skipped (already there)"}[j.state]
            values = (name, arrow, size, pct, spd, status)
            if iid in existing:
                self.queue_tree.item(iid, values=values)
            else:
                self.queue_tree.insert("", "end", iid=iid, values=values)
        for iid in existing - wanted:
            self.queue_tree.delete(iid)
        text = "Working: %d   Waiting: %d   Done: %d   Failed: %d" % (running, queued, done, failed)
        if speed:
            text += "   •   %s/s" % fmt_size(speed)
        self.summary.configure(text=text)
        self.root.after(300, self.update_queue)

    # ---- file actions
    def delete_selected(self, pane):
        sel = pane.selected()
        if not sel:
            return
        what = sel[0].name if len(sel) == 1 else "%d items" % len(sel)
        place = "the iPhone" if pane.kind == "phone" else "this PC"
        if not messagebox.askyesno("Delete", "Delete %s from %s?\nThis cannot be undone." % (what, place), parent=self.root):
            return
        if pane.kind == "pc":
            for it in sel:
                p = os.path.join(pane.path, it.name)
                try:
                    shutil.rmtree(p) if it.is_dir else os.remove(p)
                except OSError as e:
                    self.say("Could not delete %s: %s" % (it.name, e), error=True)
            pane.refresh()
        else:
            path = pane.path
            self.phone_task(lambda c: [c.delete(path, it.name) for it in sel], "Deleted.")

    def rename_selected(self, pane):
        sel = pane.selected()
        if len(sel) != 1:
            self.say("Select exactly one item to rename.", error=True)
            return
        it = sel[0]
        new = simpledialog.askstring("Rename", "New name:", initialvalue=it.name, parent=self.root)
        if not new or not new.strip() or new.strip() == it.name:
            return
        new = new.strip()
        if pane.kind == "pc":
            try:
                os.rename(os.path.join(pane.path, it.name), os.path.join(pane.path, new))
            except OSError as e:
                self.say("Could not rename: %s" % e, error=True)
            pane.refresh()
        else:
            path = pane.path
            self.phone_task(lambda c: c.rename(path, it.name, new), "Renamed.")

    # ---- dialogs
    def open_settings(self):
        win = tk.Toplevel(self.root)
        win.title("Settings")
        win.transient(self.root)
        win.configure(bg=self.palette["bg"])
        pad = dict(padx=10, pady=5)
        dl = tk.StringVar(value=self.settings["download_dir"])
        port = tk.StringVar(value=str(self.settings["port"]))
        conflict = tk.StringVar(value=CONFLICT_LABELS[self.settings["conflict"]])

        ttk.Label(win, text="Default download folder:").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(win, textvariable=dl, width=42).grid(row=0, column=1, **pad)
        ttk.Button(win, text="Browse…", command=lambda: dl.set(filedialog.askdirectory(parent=win) or dl.get())).grid(row=0, column=2, **pad)
        ttk.Label(win, text="If a file already exists:").grid(row=1, column=0, sticky="w", **pad)
        ttk.Combobox(win, textvariable=conflict, values=list(CONFLICT_LABELS.values()), state="readonly",
                     width=38).grid(row=1, column=1, **pad)
        ttk.Label(win, text="iPhone server port:").grid(row=2, column=0, sticky="w", **pad)
        ttk.Entry(win, textvariable=port, width=8).grid(row=2, column=1, sticky="w", **pad)

        def save():
            self.settings["download_dir"] = dl.get() or self.settings["download_dir"]
            for key, label in CONFLICT_LABELS.items():
                if label == conflict.get():
                    self.settings["conflict"] = key
            try:
                self.settings["port"] = int(port.get())
                self.port_var.set(port.get())
            except ValueError:
                pass
            cfg.save(self.settings)
            win.destroy()

        ttk.Button(win, text="Save", command=save).grid(row=3, column=1, sticky="e", **pad)

    def usb_help(self):
        messagebox.showinfo(
            "USB help",
            "To transfer over a USB cable:\n\n"
            "1. Install 'Apple Devices' from the Microsoft Store (or iTunes) on this PC.\n"
            "2. Plug in the iPhone, unlock it and tap Trust.\n"
            "3. On the iPhone open LAN Transfer and tap Start Server.\n"
            "4. Here, choose USB. It connects by itself.\n\n"
            "No Wi-Fi is needed. If it says 'Waiting for iPhone', check steps 2 and 3.",
            parent=self.root)

    def about(self):
        messagebox.showinfo("About", "LAN Transfer for PC %s\nTransfers files with the LAN Transfer iPhone app "
                            "over USB or Wi-Fi." % __version__, parent=self.root)

    def start_demo(self):
        from .mock_phone import MockPhone, make_demo_folder
        if self.demo:
            self.demo.stop()
        folder = make_demo_folder(os.path.join(tempfile.gettempdir(), "lantransfer_demo_phone"))
        self.demo = MockPhone(folder).start()
        self.disconnect()
        self.mode_var.set("wifi")
        self.on_mode()
        self.host_var.set("127.0.0.1")
        self.port_var.set(str(self.demo.port))
        self.pw_var.set("")
        self.connect()

    def on_close(self):
        self.settings["geometry"] = self.root.geometry().split("+")[0]
        self.settings["dark"] = self.dark_var.get()
        self.settings["auto_connect"] = self.auto_var.get()
        self.settings["mode"] = self.mode_var.get()
        if self.mode_var.get() == "wifi" and self.host_var.get().strip() != "127.0.0.1":
            self.settings["host"] = self.host_var.get().strip()
        cfg.save(self.settings)
        self.manager.stop()
        if self.demo:
            self.demo.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def main():
    App().run()


if __name__ == "__main__":
    main()
