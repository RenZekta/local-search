@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Uninstall

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  echo   You can manually delete this folder to remove the files.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to uninstall.
  pause
  exit /b 1
)

echo ============================================================
echo   Uninstall Local Search
echo ============================================================
echo This will:
echo   1. Stop and remove all Local Search containers.
echo   2. Remove the Docker VOLUMES (Firecrawl job state, redis cache,
echo      rabbitmq/postgres data). This deletes all stored data.
echo   3. (Optional) Delete the install folder and all its files.
echo.
echo   Pulled Docker images are NOT removed (use "docker image prune" to
echo   reclaim that disk space separately).
echo.
set "CONFIRM="
set /p CONFIRM="Continue with uninstall? [y/N]: "
if /i not "!CONFIRM!"=="y" ( echo Uninstall cancelled. & pause & exit /b 0 )

echo.
echo Stopping and removing containers + volumes...
docker compose down -v --remove-orphans
if errorlevel 1 (
  echo.
  echo [WARNING] docker compose down reported errors.
  echo   You may need to remove leftover containers manually, e.g.:
  echo     docker rm -f local-search-firecrawl local-search-searxng
  echo     docker rm -f local-search-redis local-search-rabbitmq
  echo     docker rm -f local-search-postgres local-search-playwright
)

echo.
echo Containers and volumes removed.
echo.
set "DELFILES="
set /p DELFILES="Also delete the install folder and ALL its files? [y/N]: "
if /i not "!DELFILES!"=="y" (
  echo.
  echo Uninstall finished. The folder was kept:
  echo   %CD%
  echo   You can delete it manually if you no longer need the scripts.
  echo.
  pause
  exit /b 0
)

cd /d "%USERPROFILE%"
echo Deleting install folder: %~dp0
rd /s /q "%~dp0"
echo.
echo Uninstall complete. Goodbye!
echo.
pause
exit /b 0
