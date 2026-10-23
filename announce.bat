@echo off
REM ─── Manually (re)post a version's changelog to Discord ─────────────────────
REM Use this if the auto-post during release.bat ever fails, or to re-send an
REM announcement. It reads the webhook from VIKINGVALE_DISCORD_WEBHOOK or the
REM gitignored .discord_webhook file and pulls the notes from Changelog.gd.
REM
REM Usage:  announce.bat 1.5.5      (post a specific version)
REM         announce.bat            (post the current version.txt)

python "%~dp0tools\announce_release.py" %1
if errorlevel 1 (
    echo.
    echo Failed. Check that a webhook is set:
    echo   - VIKINGVALE_DISCORD_WEBHOOK env var, or
    echo   - a .discord_webhook file in the repo root
)
