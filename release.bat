@echo off
REM ─── VikingVale release script ─────────────────────────────────────────────
REM Usage: release.bat <version>     e.g.  release.bat 1.0.1
REM
REM Bumps version.txt, creates a GitHub release tagged v<version>, uploads
REM VikingVale.exe + version.txt as release assets. The updater downloads
REM from these exact URLs:
REM   https://github.com/shrimpey94/VikingVale/releases/latest/download/version.txt
REM   https://github.com/shrimpey94/VikingVale/releases/latest/download/VikingVale.exe
REM
REM Requires GitHub CLI (gh) authenticated to the shrimpey94/VikingVale repo.

setlocal

if "%~1"=="" (
    echo Usage: release.bat ^<version^>
    echo Example: release.bat 1.0.1
    exit /b 1
)

set "VERSION=%~1"
set "TAG=v%VERSION%"

REM Sanity check: the game .exe must exist before we publish a release.
if not exist "VikingVale.exe" (
    echo ERROR: VikingVale.exe not found in current directory.
    echo Build the game first, then re-run release.bat.
    exit /b 1
)

REM Write version.txt WITHOUT a trailing CRLF preamble. Using `<nul set /p`
REM avoids the trailing newline `echo` would otherwise add — keeps the file
REM exactly equal to the tag the updater will compare against.
<nul set /p="%VERSION%" > version.txt

echo Publishing release %TAG%...
gh release create %TAG% VikingVale.exe version.txt ^
    --title "VikingVale %TAG%" ^
    --notes "VikingVale release %TAG%."
if errorlevel 1 (
    echo.
    echo ERROR: gh release create failed.
    echo Check that GitHub CLI is installed and authenticated:
    echo   gh auth status
    exit /b 1
)

echo.
echo === Release %TAG% published successfully ===
echo The updater will pick this up on next launch.
endlocal
