"""VikingVale auto-updater.

A standalone tkinter GUI that compares the local version.txt against the
version published on the latest GitHub release. When out of date, downloads
the new VikingVale.exe, replaces the local copy, and launches the game.
When current, launches immediately.

Packaging:
    pyinstaller --onefile --noconsole --name VikingValeUpdater updater.py

Runtime layout (all in the same folder):
    VikingValeUpdater.exe
    VikingVale.exe
    version.txt
"""

from __future__ import annotations

import os
import sys
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk, messagebox
from urllib import error as urlerror
from urllib import request as urlrequest

# ── Configuration ────────────────────────────────────────────────────────────
GAME_EXE_NAME    = "VikingVale.exe"
VERSION_FILE     = "version.txt"
REPO_BASE        = "https://github.com/shrimpey94/VikingVale/releases/latest/download"
REMOTE_VERSION   = f"{REPO_BASE}/{VERSION_FILE}"
REMOTE_GAME_EXE  = f"{REPO_BASE}/{GAME_EXE_NAME}"
HTTP_TIMEOUT_SEC = 15
DOWNLOAD_CHUNK   = 65_536


def app_dir() -> Path:
    """Returns the folder the updater is running from. Works for both a
    PyInstaller --onefile bundle (sys.executable lives in the install dir)
    and a plain `python updater.py` run (the .py file's parent)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).parent


def read_local_version() -> str:
    """Reads the version.txt next to the executable. Returns '0.0.0' if the
    file is missing (i.e. a fresh install) so any remote version wins."""
    f = app_dir() / VERSION_FILE
    if not f.exists():
        return "0.0.0"
    try:
        return f.read_text(encoding="utf-8").strip()
    except Exception:
        return "0.0.0"


def fetch_remote_version() -> str:
    """Pulls the latest version string from the GitHub release. Raises on
    network failure so the caller can display the error and bail."""
    req = urlrequest.Request(REMOTE_VERSION, headers={"User-Agent": "VikingValeUpdater/1.0"})
    with urlrequest.urlopen(req, timeout=HTTP_TIMEOUT_SEC) as resp:
        raw = resp.read().decode("utf-8", errors="replace").strip()
    if not raw:
        raise ValueError("empty version string from server")
    return raw


def write_local_version(v: str) -> None:
    (app_dir() / VERSION_FILE).write_text(v.strip() + "\n", encoding="utf-8")


def version_tuple(v: str) -> tuple:
    """Parse '1.2.3' → (1,2,3). Non-numeric segments become 0 so a malformed
    string never throws — it just sorts to the bottom."""
    parts = []
    for p in v.replace("v", "").strip().split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def needs_update(local: str, remote: str) -> bool:
    return version_tuple(remote) > version_tuple(local)


def launch_game_and_exit() -> None:
    """Spawns VikingVale.exe in the same folder and quits the updater. The
    game becomes its own process group so closing the updater never blocks
    on it."""
    exe = app_dir() / GAME_EXE_NAME
    if not exe.exists():
        messagebox.showerror(
            "VikingVale",
            f"Couldn't find {GAME_EXE_NAME} in {app_dir()}.\n"
            f"Reinstall from the launcher.")
        sys.exit(1)
    # CREATE_NEW_PROCESS_GROUP detaches the game so closing the updater
    # doesn't terminate it (Windows-only flag; harmless if missing).
    flags = 0
    if os.name == "nt":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP    # type: ignore[attr-defined]
    subprocess.Popen([str(exe)], cwd=str(app_dir()), creationflags=flags)
    sys.exit(0)


# ── GUI ──────────────────────────────────────────────────────────────────────

class UpdaterApp:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("VikingVale Updater")
        self.root.geometry("420x220")
        self.root.resizable(False, False)
        try:
            self.root.iconbitmap(default="")   # no icon by default
        except Exception:
            pass

        # Layout
        pad = {"padx": 14, "pady": 4}
        ttk.Label(self.root, text="VikingVale",
                  font=("Segoe UI", 14, "bold")).pack(**pad)
        self.status_var = tk.StringVar(value="Checking for updates…")
        ttk.Label(self.root, textvariable=self.status_var,
                  font=("Segoe UI", 10)).pack(**pad)

        ver_frame = ttk.Frame(self.root)
        ver_frame.pack(**pad)
        self.local_var  = tk.StringVar(value="Local:  —")
        self.remote_var = tk.StringVar(value="Latest: —")
        ttk.Label(ver_frame, textvariable=self.local_var,
                  font=("Consolas", 9)).pack(anchor="w")
        ttk.Label(ver_frame, textvariable=self.remote_var,
                  font=("Consolas", 9)).pack(anchor="w")

        self.progress = ttk.Progressbar(self.root, length=380,
                                        mode="determinate", maximum=100)
        self.progress.pack(**pad)

        self.action_btn = ttk.Button(self.root, text="Launch",
                                     command=launch_game_and_exit,
                                     state="disabled")
        self.action_btn.pack(**pad)

        # Kick off the version check in a background thread so the GUI
        # doesn't freeze while the network call is in flight.
        self.local_version  = read_local_version()
        self.remote_version = ""
        self.local_var.set(f"Local:  {self.local_version}")
        threading.Thread(target=self._check_thread, daemon=True).start()

        self.root.mainloop()

    # All UI mutations from background threads go through root.after so
    # tkinter only sees them from the main thread.
    def _set(self, **kw) -> None:
        for k, v in kw.items():
            if k == "status":
                self.status_var.set(v)
            elif k == "remote":
                self.remote_var.set(f"Latest: {v}")
            elif k == "progress":
                self.progress["value"] = v
            elif k == "btn_text":
                self.action_btn.configure(text=v)
            elif k == "btn_enable":
                self.action_btn.configure(state=("normal" if v else "disabled"))

    def _check_thread(self) -> None:
        try:
            remote = fetch_remote_version()
        except (urlerror.URLError, urlerror.HTTPError, ValueError, OSError) as e:
            self.root.after(0, lambda err=e: self._on_check_failed(err))
            return
        self.remote_version = remote
        self.root.after(0, self._on_check_done)

    def _on_check_failed(self, err: Exception) -> None:
        # Offline / repo unreachable / etc. Fall back to launching whatever
        # we have locally so a flaky network doesn't lock the player out.
        self._set(status=f"Couldn't reach update server: {err}",
                  remote="Latest: ?",
                  btn_text="Launch anyway",
                  btn_enable=True)

    def _on_check_done(self) -> None:
        self._set(remote=self.remote_version)
        if needs_update(self.local_version, self.remote_version):
            self._set(status=f"Update available "
                             f"({self.local_version} → {self.remote_version}). "
                             f"Downloading…")
            threading.Thread(target=self._download_thread, daemon=True).start()
        else:
            self._set(status="You're up to date.",
                      btn_text="Launch", btn_enable=True)
            # Auto-launch when current — no need to make the player click.
            self.root.after(600, launch_game_and_exit)

    def _download_thread(self) -> None:
        target = app_dir() / GAME_EXE_NAME
        tmp    = target.with_suffix(".exe.download")
        try:
            req = urlrequest.Request(
                REMOTE_GAME_EXE,
                headers={"User-Agent": "VikingValeUpdater/1.0"})
            with urlrequest.urlopen(req, timeout=HTTP_TIMEOUT_SEC) as resp:
                total = int(resp.headers.get("Content-Length", 0))
                downloaded = 0
                with open(tmp, "wb") as out:
                    while True:
                        chunk = resp.read(DOWNLOAD_CHUNK)
                        if not chunk:
                            break
                        out.write(chunk)
                        downloaded += len(chunk)
                        if total > 0:
                            pct = downloaded * 100.0 / total
                            self.root.after(0, lambda p=pct:
                                            self._set(progress=p))
            # Replace the live exe with the download. os.replace is atomic
            # on Windows when source + dest are on the same volume — they
            # always are (same folder).
            if target.exists():
                target.unlink()
            os.replace(str(tmp), str(target))
            write_local_version(self.remote_version)
        except (urlerror.URLError, urlerror.HTTPError, OSError) as e:
            self.root.after(0, lambda err=e: self._on_download_failed(err))
            return
        self.root.after(0, self._on_download_done)

    def _on_download_failed(self, err: Exception) -> None:
        self._set(status=f"Download failed: {err}",
                  btn_text="Launch anyway",
                  btn_enable=True)

    def _on_download_done(self) -> None:
        self._set(status="Update installed. Launching…",
                  progress=100, btn_enable=True)
        self.root.after(700, launch_game_and_exit)


if __name__ == "__main__":
    UpdaterApp()
