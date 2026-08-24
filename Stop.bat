@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Stop

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to stop.
  pause
  exit /b 1
)

echo Stopping Local Search containers (data is preserved)...
docker compose down
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to stop. See messages above.
  pause
  exit /b 1
)

echo.
echo Local Search stopped. Data is preserved in Docker volumes.
echo Run Run.bat to start it again.
echo.
pause
exit /b 0
