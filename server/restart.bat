@echo off
echo Sending reset signal to VikingVale server...

:: Change ADMIN_KEY to match the value set in start.bat
set ADMIN_KEY=change_me_before_deploy
set PORT=5000

curl -s -X POST http://localhost:%PORT%/admin/reset ^
     -H "Content-Type: application/json" ^
     -d "{\"key\": \"%ADMIN_KEY%\"}"

echo.
echo Reset signal sent. The server will flush thrall data and restart.
echo Watch the server window for confirmation.
pause
