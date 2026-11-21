import json
import os

DEFAULTS = {
    "mode": "usb",              # "usb" or "wifi"
    "host": "",
    "port": 8080,
    "password": "",
    "auto_connect": True,
    "conflict": "rename",       # rename | overwrite | skip
    "dark": False,
    "show_hidden": False,
    "download_dir": os.path.join(os.path.expanduser("~"), "Downloads"),
    "pc_dir": os.path.expanduser("~"),
    "geometry": "1100x700",
}


def config_path() -> str:
    base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "LanTransferPC", "settings.json")


def load() -> dict:
    data = dict(DEFAULTS)
    try:
        with open(config_path(), "r", encoding="utf-8") as f:
            saved = json.load(f)
        for k in DEFAULTS:
            if k in saved:
                data[k] = saved[k]
    except (OSError, ValueError):
        pass
    return data


def save(data: dict) -> None:
    path = config_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except OSError:
        pass
