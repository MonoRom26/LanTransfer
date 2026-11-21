# LAN Transfer for PC

Move files between your PC and the **LAN Transfer** iPhone app (version 1.3 or newer) over a **USB cable** or **Wi-Fi**.
Two panes: your PC on the left, the iPhone on the right.

## Use it
1. **USB:** install *Apple Devices* (Microsoft Store) or iTunes on the PC, plug in the iPhone, tap **Trust**.
2. On the iPhone open **LAN Transfer** and tap **Start Server** (keep the app open).
3. Start the PC app. With **USB** selected it connects by itself. For **Wi-Fi** choose Wi-Fi, type the address shown in the iPhone app and press Connect.
4. Drag files from Explorer onto the iPhone side, or select files and press **Send →** / **← Get**.

No iPhone at hand? **Tools → Try demo mode** runs the app against a pretend iPhone.

## Features
- USB (no Wi-Fi needed) or Wi-Fi, with automatic reconnect and a connection heartbeat
- iPhone name, iOS version and free space
- Browse folders on both sides, create folders, rename, delete, search, sort by column
- Send and get whole folders; many files at once; transfer queue with progress, speed, cancel and retry
- If a file already exists: keep both, replace, or skip (Settings)
- Drag and drop from Explorer (needs the optional `tkinterdnd2` package)
- Dark mode, hidden-file toggle, password support (the password set in the iPhone app)
- Shortcuts: F5 refresh, F2 rename, Del delete, Backspace up, Ctrl+A select all

## Run from source
    python run_pc.py
Needs Python 3.9+ with Tkinter (included in the normal Windows installer). `pip install -r requirements.txt` adds drag and drop.

## Build the .exe
Run `build_exe.bat` on Windows, or let GitHub build it (workflow *Build PC app*) and download the artifact.

## Tests
    python -m unittest discover -s tests -v
The tests use a fake iPhone and a fake USB service, so no hardware is needed.

## Troubleshooting
- **"Apple USB driver not found"**: install Apple Devices or iTunes.
- **"No iPhone found"**: unlock the iPhone, tap Trust, try another cable or port.
- **"Open LAN Transfer and tap Start Server"**: the iPhone is connected but the server is off.
- **"iPhone app is too old"**: install LAN Transfer 1.3 or newer.
