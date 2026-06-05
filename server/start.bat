@echo off
echo VikingVale Multiplayer Server
echo ================================
cd /d "%~dp0"

:: Install dependencies if needed
pip show websockets >nul 2>&1
if errorlevel 1 (
    echo Installing dependencies...
    pip install -r requirements.txt
)

:loop
echo Starting server on ws://localhost:8765
python server.py
echo.
echo Server stopped (code %errorlevel%). Restarting in 3 seconds...
timeout /t 3 /nobreak >nul
goto loop
