@echo off
rem Builds LanTransferPC.exe (run this on Windows with Python 3.9+ installed)
python -m pip install --upgrade pip
python -m pip install -r requirements-build.txt
python -m PyInstaller --noconfirm --onefile --windowed --name LanTransferPC --collect-all tkinterdnd2 run_pc.py
echo.
echo Done: dist\LanTransferPC.exe
pause
