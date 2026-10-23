@echo off
REM ── Launch the 1.5.6 Billboard 2.5D prototype SANDBOX (NOT the live game) ──
REM Double-click this file, or run it from any terminal. It targets the proto
REM scene directly, so it won't boot into the normal login/world screen.
REM
REM Controls once it opens:
REM   WASD/arrows = move · mouse wheel = zoom · Q/E = orbit camera
REM   B = toggle billboard mode (upright vs full-face) · Esc = quit

set "GODOT=D:\GoDot\Godot_v4.6.2-stable_win64_console.exe"
if not exist "%GODOT%" set "GODOT=godot"

pushd "%~dp0"
"%GODOT%" --path . res://proto/Billboard3D.tscn
popd
pause
