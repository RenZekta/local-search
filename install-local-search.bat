@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Installer

REM ===========================================================================
REM  Local Search Installer  (Firecrawl + SearXNG + local-web skill)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM  After installing the stack it also copies the bundled local-web agent
REM  skill into %USERPROFILE%\.agents\skills\local-web.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG + local-web)
echo   A local web-browsing system for AI models.
echo ============================================================
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker was not found on your PATH.
  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/
  echo   Start it, wait until "Docker Desktop is running", then re-run.
  pause & exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is installed but the engine is not running.
  echo   Start Docker Desktop and wait until it says "running".
  pause & exit /b 1
)
echo [OK] Docker is running.
echo.

set "SRC=%~dp0"
if "!SRC:~-1!"=="\" set "SRC=!SRC:~0,-1!"

set "DEFAULT_TARGET=%USERPROFILE%\local-search"

echo --- Step 1 of 4: Install location --------------------------
echo   Default: %DEFAULT_TARGET%
set "TARGET="
set /p TARGET="  Target folder [press Enter for default]: "
if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"
set "TARGET=!TARGET:"=!"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
echo   Using: !TARGET!
echo.

:ask_searxng
echo --- Step 2 of 4: SearXNG port (default 9990) --------------
set "SEARXNG_PORT="
set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "
if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"
call :validate_port "!SEARXNG_PORT!"
if !errorlevel! neq 0 ( echo   [!] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )

:ask_firecrawl
echo --- Step 3 of 4: Firecrawl port (default 9991) ------------
set "FIRECRAWL_PORT="
set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "
if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"
call :validate_port "!FIRECRAWL_PORT!"
if !errorlevel! neq 0 ( echo   [!] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )
if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [!] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )

echo.
echo --- Step 4 of 4: Local LLM (optional) ---------------------
echo   Lets Firecrawl do AI extraction (/v1/extract) and summaries.
echo   Recommended: LM Studio  -^>  http://localhost:1234/v1
set "USE_LLM="
set /p USE_LLM="  Connect a local LLM now? [y/N]: "
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
if /i "!USE_LLM!"=="y" (
  set "LLM_URL="
  set /p LLM_URL="    LM Studio server URL as shown in LM Studio [Enter = http://localhost:1234/v1]: "
  if "!LLM_URL!"=="" set "LLM_URL=http://localhost:1234/v1"
  set "LLM_MODEL="
  set /p LLM_MODEL="    Model name loaded in LM Studio [Enter to skip]: "
  set "OPENAI_BASE_URL=!LLM_URL!"
  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://localhost=http://host.docker.internal!"
  set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://127.0.0.1=http://host.docker.internal!"
  set "OPENAI_API_KEY=lm-studio"
  if not "!LLM_MODEL!"=="" set "MODEL_NAME=!LLM_MODEL!"
  echo     ^(Container will reach it at: !OPENAI_BASE_URL!^)
  echo     ^(Make sure LM Studio has "Serve on local network" enabled.^)
)

echo.
echo ============================================================
echo   Summary
echo   Folder:         !TARGET!
echo   SearXNG port:   !SEARXNG_PORT!
echo   Firecrawl port: !FIRECRAWL_PORT!
echo   Agent skill:    %USERPROFILE%\.agents\skills\local-web
if defined OPENAI_BASE_URL (
  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!
) else (
  echo   LLM endpoint:   ^(none - enable later by editing .env^)
)
echo ============================================================
set "CONFIRM="
set /p CONFIRM="Proceed with install? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\config\searxng" mkdir "!TARGET!\config\searxng"
if not exist "!TARGET!\local-web\scripts" mkdir "!TARGET!\local-web\scripts"

if exist "!TARGET!\.env" (
  for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMddHHmmss"`) do set "LDT=%%t"
  copy /Y "!TARGET!\.env" "!TARGET!\.env.bak.!LDT!" >nul
  echo   Backed up existing .env to .env.bak.!LDT!
)

echo Copying files...

REM --- config/searxng/settings.yml ---
set "NEED_B64=1"
if exist "!SRC!\config\searxng\settings.yml" (
  copy /Y "!SRC!\config\searxng\settings.yml" "!TARGET!\config\searxng\settings.yml" >nul 2>&1
  if exist "!TARGET!\config\searxng\settings.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] config/searxng/settings.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3594602951.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBTZWFyWE5HIHNldHRpbmdzIGZvciBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2gKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PQojICBQcmUtY29uZmlndXJlZCBmb3IgQUkgLyBsb2Nh
  >> "!B64TMP!" echo bC1tb2RlbCB1c2U6CiMgICAgKiBzZWFyY2guZm9ybWF0cyBpbmNsdWRlcyAianNvbiIgIC0+IGxl
  >> "!B64TMP!" echo dHMgbW9kZWxzIHF1ZXJ5IHRoZSBKU09OIEFQSQojICAgICogc2VydmVyLmxpbWl0ZXI6IGZhbHNl
  >> "!B64TMP!" echo ICAgICAgICAgICAtPiBubyByYXRlLWxpbWl0aW5nIG9uIEFQSSBjYWxscwojICAgICogc2VydmVy
  >> "!B64TMP!" echo LnB1YmxpY19pbnN0YW5jZTogZmFsc2UgICAtPiBwcml2YXRlIGluc3RhbmNlIGRlZmF1bHRzCiMg
  >> "!B64TMP!" echo ICAgKiBzZWNyZXRfa2V5IHBsYWNlaG9sZGVyICAgICAgICAgIC0+IGluc3RhbGxlciByZXBsYWNl
  >> "!B64TMP!" echo cyB3aXRoIGEgcmFuZG9tIGtleQojCiMgICJ1c2VfZGVmYXVsdF9zZXR0aW5nczogdHJ1ZSIgaW5o
  >> "!B64TMP!" echo ZXJpdHMgYWxsIHVwc3RyZWFtIGRlZmF1bHRzIChlbmdpbmVzLAojICBwbHVnaW5zLCBldGMuKSBz
  >> "!B64TMP!" echo byBvbmx5IHRoZSBvdmVycmlkZXMgYmVsb3cgdGFrZSBlZmZlY3QuCiMgPT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT0KCnVzZV9kZWZhdWx0X3NldHRpbmdzOiB0cnVlCgpnZW5lcmFsOgogIGRlYnVnOiBmYWxz
  >> "!B64TMP!" echo ZQogIGluc3RhbmNlX25hbWU6ICJMb2NhbCBTZWFyY2giCiAgcHJpdmFjeXBvbGljeV91cmw6IGZh
  >> "!B64TMP!" echo bHNlCiAgY29udGFjdF9saW5rOiBmYWxzZQoKc2VhcmNoOgogIHNhZmVfc2VhcmNoOiAwCiAgYXV0
  >> "!B64TMP!" echo b2NvbXBsZXRlOiAiIgogIGRlZmF1bHRfbGFuZzogImVuIgogIGZvcm1hdHM6CiAgICAtIGh0bWwK
  >> "!B64TMP!" echo ICAgIC0ganNvbgoKc2VydmVyOgogIHNlY3JldF9rZXk6ICIzMjY0NWZiMzBjNmQ0Y2JlMjE3YzY3
  >> "!B64TMP!" echo OTU2ZDNkYjAwZDM3N2I0ZmRlZDE4NDU1NDk3YjA3M2IzYjBkYzQyNTNjIgogIGJpbmRfYWRkcmVz
  >> "!B64TMP!" echo czogIjAuMC4wLjAiCiAgcG9ydDogODA4MAogIGltYWdlX3Byb3h5OiB0cnVlCiAgbGltaXRlcjog
  >> "!B64TMP!" echo ZmFsc2UKICBwdWJsaWNfaW5zdGFuY2U6IGZhbHNlCgp1aToKICBzdGF0aWNfdXNlX2hhc2g6IHRy
  >> "!B64TMP!" echo dWUKCm91dGdvaW5nOgogIHJlcXVlc3RfdGltZW91dDogMTAuMAogIG1heF9yZXF1ZXN0X3RpbWVv
  >> "!B64TMP!" echo dXQ6IDE1LjAK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\config\searxng\settings.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- docker-compose.yml ---
set "NEED_B64=1"
if exist "!SRC!\docker-compose.yml" (
  copy /Y "!SRC!\docker-compose.yml" "!TARGET!\docker-compose.yml" >nul 2>&1
  if exist "!TARGET!\docker-compose.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] docker-compose.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS548588679.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIEZpcmVjcmF3bCArIFNl
  >> "!B64TMP!" echo YXJYTkcgKGxvY2FsIHdlYi1icm93c2luZyBzeXN0ZW0gZm9yIEFJIG1vZGVscykKIyA9PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PQojICBUaGlzIENvbXBvc2UgZmlsZSBpcyBjb25zdW1lZCBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVycyAoaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IC8KIyAgaW5zdGFsbC1sb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2guc2gpLiBUaGUgaG9zdCBwb3J0cyBhbmQgY3JlZGVudGlhbHMgYXJlIGluamVjdGVkIGZyb20K
  >> "!B64TMP!" echo IyAgdGhlIGdlbmVyYXRlZCAuZW52IGZpbGUgKGNyZWF0ZWQgYXQgaW5zdGFsbCB0aW1lKS4KIwoj
  >> "!B64TMP!" echo ICBTZXJ2aWNlczoKIyAgICBzZWFyeG5nICAgICAgICAgIG1ldGFzZWFyY2ggKyBKU09OIEFQSSAg
  >> "!B64TMP!" echo ICAgICAgLT4gaG9zdCAke1NFQVJYTkdfUE9SVH0KIyAgICBmaXJlY3Jhd2wgICAgICAgIHNjcmFw
  >> "!B64TMP!" echo ZS9jcmF3bC9zZWFyY2gvbWFwIEFQSSAgLT4gaG9zdCAke0ZJUkVDUkFXTF9QT1JUfQojICAgIHBs
  >> "!B64TMP!" echo YXl3cmlnaHQtc2VydmljZSAgSlMgcmVuZGVyaW5nIGZvciBGaXJlY3Jhd2wKIyAgICByZWRpcyAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHF1ZXVlIGZvciBGaXJlY3Jhd2wKIyAgICByYWJiaXRtcSAgICAgICAgICAg
  >> "!B64TMP!" echo IG1lc3NhZ2UgYnJva2VyIGZvciBGaXJlY3Jhd2wKIyAgICBudXEtcG9zdGdyZXMgICAgICAgIGpv
  >> "!B64TMP!" echo YiBzdGF0ZSBEQiBmb3IgRmlyZWNyYXdsCiMKIyAgT25seSB0aGUgdHdvIGhvc3QgcG9ydHMgYmVs
  >> "!B64TMP!" echo b3cgYXJlIHB1Ymxpc2hlZC4gRXZlcnl0aGluZyBlbHNlIHN0YXlzIG9uIHRoZQojICBwcml2YXRl
  >> "!B64TMP!" echo ICJsb2NhbC1zZWFyY2gtbmV0IiBicmlkZ2UgbmV0d29yay4KIyA9PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PQoKbmFtZTogbG9jYWwtc2VhcmNoCgpzZXJ2aWNlczoKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQog
  >> "!B64TMP!" echo ICMgU2VhclhORyDigJQgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5naW5lLCBleHBv
  >> "!B64TMP!" echo c2VkIGFzIGEgSlNPTiBBUEkuCiAgIyBQb3dlcnMgYm90aCB5b3VyIEFJIG1vZGVscyAoZGlyZWN0
  >> "!B64TMP!" echo IEpTT04gcXVlcmllcykgYW5kIEZpcmVjcmF3bCdzIC92MS9zZWFyY2guCiAgIyAtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQogIHNlYXJ4bmc6CiAgICBpbWFnZTogc2VhcnhuZy9zZWFyeG5nOmxhdGVzdAogICAg
  >> "!B64TMP!" echo Y29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1zZWFyeG5nCiAgICBwb3J0czoKICAgICAgLSAi
  >> "!B64TMP!" echo JHtTRUFSWE5HX1BPUlQ6LTk5OTB9OjgwODAiCiAgICB2b2x1bWVzOgogICAgICAtIC4vY29uZmln
  >> "!B64TMP!" echo L3NlYXJ4bmc6L2V0Yy9zZWFyeG5nOnJ3CiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBTRUFSWE5H
  >> "!B64TMP!" echo X0JBU0VfVVJMPWh0dHA6Ly9sb2NhbGhvc3Q6JHtTRUFSWE5HX1BPUlQ6LTk5OTB9LwogICAgICAt
  >> "!B64TMP!" echo IFVXU0dJX1dPUktFUlM9NAogICAgICAtIFVXU0dJX1RIUkVBRFM9NAogICAgICAtIFNFQVJYTkdf
  >> "!B64TMP!" echo U0VDUkVUPSR7U0VBUlhOR19TRUNSRVR9CiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAg
  >> "!B64TMP!" echo Y2FwX2Ryb3A6CiAgICAgIC0gQUxMCiAgICBjYXBfYWRkOgogICAgICAtIENIT1dOCiAgICAgIC0g
  >> "!B64TMP!" echo U0VUR0lECiAgICAgIC0gU0VUVUlECiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo bmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEZpcmVjcmF3bCBBUEkgc2VydmVyICh0aGUg
  >> "!B64TMP!" echo cHVibGljLWZhY2luZyBzY3JhcGluZy9jcmF3bC9zZWFyY2ggc2VydmljZSkuCiAgIyAtLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLQogIGZpcmVjcmF3bDoKICAgIGltYWdlOiBnaGNyLmlvL2ZpcmVjcmF3bC9maXJl
  >> "!B64TMP!" echo Y3Jhd2w6bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLWZpcmVjcmF3bAog
  >> "!B64TMP!" echo ICAgcG9ydHM6CiAgICAgIC0gIiR7RklSRUNSQVdMX1BPUlQ6LTk5OTF9OjMwMDIiCiAgICBlbnZp
  >> "!B64TMP!" echo cm9ubWVudDoKICAgICAgLSBQT1JUPTMwMDIKICAgICAgLSBIT1NUPTAuMC4wLjAKICAgICAgLSBF
  >> "!B64TMP!" echo TlY9bG9jYWwKICAgICAgLSBSRURJU19VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUkVE
  >> "!B64TMP!" echo SVNfUkFURV9MSU1JVF9VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUExBWVdSSUdIVF9N
  >> "!B64TMP!" echo SUNST1NFUlZJQ0VfVVJMPWh0dHA6Ly9wbGF5d3JpZ2h0LXNlcnZpY2U6MzAwMC9zY3JhcGUKICAg
  >> "!B64TMP!" echo ICAgLSBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2UKICAgICAgLSBCVUxMX0FVVEhfS0VZPSR7
  >> "!B64TMP!" echo QlVMTF9BVVRIX0tFWX0KICAgICAgLSBMT0dHSU5HX0xFVkVMPSR7TE9HR0lOR19MRVZFTDotaW5m
  >> "!B64TMP!" echo b30KICAgICAgLSBCTE9DS19NRURJQT1mYWxzZQogICAgICAtIEFMTE9XX0xPQ0FMX1dFQkhPT0tT
  >> "!B64TMP!" echo PWZhbHNlCiAgICAgIC0gU0VBUlhOR19FTkRQT0lOVD1odHRwOi8vc2VhcnhuZzo4MDgwCiAgICAg
  >> "!B64TMP!" echo IC0gUE9TVEdSRVNfSE9TVD1udXEtcG9zdGdyZXMKICAgICAgLSBQT1NUR1JFU19QT1JUPTU0MzIK
  >> "!B64TMP!" echo ICAgICAgLSBQT1NUR1JFU19EQj0ke1BPU1RHUkVTX0RCOi1maXJlY3Jhd2x9CiAgICAgIC0gUE9T
  >> "!B64TMP!" echo VEdSRVNfVVNFUj0ke1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19Q
  >> "!B64TMP!" echo QVNTV09SRD0ke1BPU1RHUkVTX1BBU1NXT1JEfQogICAgICAtIE5VUV9SQUJCSVRNUV9VUkw9YW1x
  >> "!B64TMP!" echo cDovLyR7UkFCQklUTVFfVVNFUjotZmlyZWNyYXdsfToke1JBQkJJVE1RX1BBU1NXT1JEfUByYWJi
  >> "!B64TMP!" echo aXRtcTo1NjcyCiAgICAgICMgLS0tLSBPcHRpb25hbCBBSSBmZWF0dXJlcyAoc2V0IGluIC5lbnYg
  >> "!B64TMP!" echo dG8gZW5hYmxlIC92MS9leHRyYWN0ICsgc3VtbWFyeSkgLS0tLQogICAgICAtIE9QRU5BSV9BUElf
  >> "!B64TMP!" echo S0VZPSR7T1BFTkFJX0FQSV9LRVk6LX0KICAgICAgLSBPUEVOQUlfQkFTRV9VUkw9JHtPUEVOQUlf
  >> "!B64TMP!" echo QkFTRV9VUkw6LX0KICAgICAgLSBPTExBTUFfQkFTRV9VUkw9JHtPTExBTUFfQkFTRV9VUkw6LX0K
  >> "!B64TMP!" echo ICAgICAgLSBNT0RFTF9OQU1FPSR7TU9ERUxfTkFNRTotfQogICAgICAtIE1PREVMX0VNQkVERElO
  >> "!B64TMP!" echo R19OQU1FPSR7TU9ERUxfRU1CRURESU5HX05BTUU6LX0KICAgIGNvbW1hbmQ6IFsibm9kZSIsICJk
  >> "!B64TMP!" echo aXN0L3NyYy9oYXJuZXNzLmpzIiwgIi0tc3RhcnQtZG9ja2VyIl0KICAgIHVsaW1pdHM6CiAgICAg
  >> "!B64TMP!" echo IG5vZmlsZToKICAgICAgICBzb2Z0OiA2NTUzNQogICAgICAgIGhhcmQ6IDY1NTM1CiAgICBleHRy
  >> "!B64TMP!" echo YV9ob3N0czoKICAgICAgLSAiaG9zdC5kb2NrZXIuaW50ZXJuYWw6aG9zdC1nYXRld2F5IgogICAg
  >> "!B64TMP!" echo bG9nZ2luZzoKICAgICAgZHJpdmVyOiAianNvbi1maWxlIgogICAgICBvcHRpb25zOgogICAgICAg
  >> "!B64TMP!" echo IG1heC1zaXplOiAiMTBtIgogICAgICAgIG1heC1maWxlOiAiMyIKICAgICAgICBjb21wcmVzczog
  >> "!B64TMP!" echo InRydWUiCiAgICBkZXBlbmRzX29uOgogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNl
  >> "!B64TMP!" echo cnZpY2Vfc3RhcnRlZAogICAgICBwbGF5d3JpZ2h0LXNlcnZpY2U6CiAgICAgICAgY29uZGl0aW9u
  >> "!B64TMP!" echo OiBzZXJ2aWNlX3N0YXJ0ZWQKICAgICAgc2VhcnhuZzoKICAgICAgICBjb25kaXRpb246IHNlcnZp
  >> "!B64TMP!" echo Y2Vfc3RhcnRlZAogICAgICBudXEtcG9zdGdyZXM6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNl
  >> "!B64TMP!" echo X2hlYWx0aHkKICAgICAgcmFiYml0bXE6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2aWNlX2hlYWx0
  >> "!B64TMP!" echo aHkKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAgICAgLSBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIFBsYXl3cmlnaHQgaGVhZGxl
  >> "!B64TMP!" echo c3MgYnJvd3NlciBzZXJ2aWNlIOKAlCBkb2VzIHRoZSBhY3R1YWwgSlMtcmVuZGVyZWQgZmV0Y2hp
  >> "!B64TMP!" echo bmcuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHBsYXl3cmlnaHQtc2VydmljZToKICAgIGltYWdl
  >> "!B64TMP!" echo OiBnaGNyLmlvL2ZpcmVjcmF3bC9wbGF5d3JpZ2h0LXNlcnZpY2U6bGF0ZXN0CiAgICBjb250YWlu
  >> "!B64TMP!" echo ZXJfbmFtZTogbG9jYWwtc2VhcmNoLXBsYXl3cmlnaHQKICAgIGVudmlyb25tZW50OgogICAgICAt
  >> "!B64TMP!" echo IFBPUlQ9MzAwMAogICAgICAtIEJMT0NLX01FRElBPWZhbHNlCiAgICAgIC0gQUxMT1dfTE9DQUxf
  >> "!B64TMP!" echo V0VCSE9PS1M9ZmFsc2UKICAgICAgLSBNQVhfQ09OQ1VSUkVOVF9QQUdFUz0xMAogICAgcmVzdGFy
  >> "!B64TMP!" echo dDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQK
  >> "!B64TMP!" echo CiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgUmVkaXMg4oCUIEZpcmVjcmF3bCBxdWV1ZSAvIHJh
  >> "!B64TMP!" echo dGUtbGltaXRpbmcgc3RvcmUuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHJlZGlzOgogICAgaW1h
  >> "!B64TMP!" echo Z2U6IHJlZGlzOmFscGluZQogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1yZWRpcwog
  >> "!B64TMP!" echo ICAgdm9sdW1lczoKICAgICAgLSByZWRpcy1kYXRhOi9kYXRhCiAgICByZXN0YXJ0OiB1bmxlc3Mt
  >> "!B64TMP!" echo c3RvcHBlZAogICAgbmV0d29ya3M6CiAgICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKICAjIC0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tCiAgIyBSYWJiaXRNUSDigJQgbWVzc2FnZSBicm9rZXIgdXNlZCBieSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wncyBqb2Igd29ya2Vycy4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgcmFiYml0bXE6CiAg
  >> "!B64TMP!" echo ICBpbWFnZTogcmFiYml0bXE6My1tYW5hZ2VtZW50CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLXJhYmJpdG1xCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBSQUJCSVRNUV9ERUZBVUxU
  >> "!B64TMP!" echo X1VTRVI9JHtSQUJCSVRNUV9VU0VSOi1maXJlY3Jhd2x9CiAgICAgIC0gUkFCQklUTVFfREVGQVVM
  >> "!B64TMP!" echo VF9QQVNTPSR7UkFCQklUTVFfUEFTU1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHJhYmJpdG1x
  >> "!B64TMP!" echo LWRhdGE6L3Zhci9saWIvcmFiYml0bXEKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNN
  >> "!B64TMP!" echo RCIsICJyYWJiaXRtcS1kaWFnbm9zdGljcyIsICJwaW5nIl0KICAgICAgaW50ZXJ2YWw6IDVzCiAg
  >> "!B64TMP!" echo ICAgIHRpbWVvdXQ6IDEwcwogICAgICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMw
  >> "!B64TMP!" echo cwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgbnVxLXBvc3RncmVzIOKAlCBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgam9iLXN0YXRlIGRhdGFiYXNlIChwZ19jcm9uIGVuYWJsZWQgaW1hZ2UpLgogICMg
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KICBudXEtcG9zdGdyZXM6CiAgICBpbWFnZTogZ2hjci5pby9maXJl
  >> "!B64TMP!" echo Y3Jhd2wvbnVxLXBvc3RncmVzOmxhdGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC1wb3N0Z3JlcwogICAgY29tbWFuZDogcG9zdGdyZXMgLWMgY3Jvbi5kYXRhYmFzZV9uYW1lPSR7
  >> "!B64TMP!" echo UE9TVEdSRVNfREI6LWZpcmVjcmF3bH0KICAgIGVudmlyb25tZW50OgogICAgICAtIFBPU1RHUkVT
  >> "!B64TMP!" echo X0RCPSR7UE9TVEdSRVNfREI6LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9T
  >> "!B64TMP!" echo VEdSRVNfVVNFUjotZmlyZWNyYXdsfQogICAgICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdS
  >> "!B64TMP!" echo RVNfUEFTU1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHBvc3RncmVzLWRhdGE6L3Zhci9saWIv
  >> "!B64TMP!" echo cG9zdGdyZXNxbC9kYXRhCiAgICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQtU0hFTEwi
  >> "!B64TMP!" echo LCAicGdfaXNyZWFkeSAtVSAke1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0gLWQgJHtQT1NUR1JF
  >> "!B64TMP!" echo U19EQjotZmlyZWNyYXdsfSJdCiAgICAgIGludGVydmFsOiA1cwogICAgICB0aW1lb3V0OiA1cwog
  >> "!B64TMP!" echo ICAgICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5s
  >> "!B64TMP!" echo ZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCm5ldHdv
  >> "!B64TMP!" echo cmtzOgogIGxvY2FsLXNlYXJjaC1uZXQ6CiAgICBkcml2ZXI6IGJyaWRnZQoKdm9sdW1lczoKICBy
  >> "!B64TMP!" echo ZWRpcy1kYXRhOgogIHBvc3RncmVzLWRhdGE6CiAgcmFiYml0bXEtZGF0YToK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\docker-compose.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .env.example ---
set "NEED_B64=1"
if exist "!SRC!\.env.example" (
  copy /Y "!SRC!\.env.example" "!TARGET!\.env.example" >nul 2>&1
  if exist "!TARGET!\.env.example" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .env.example  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4173156074.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIGV4YW1wbGUgZW52aXJv
  >> "!B64TMP!" echo bm1lbnQgZmlsZQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIFRoZSBpbnN0YWxsZXIgKGluc3Rh
  >> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLmJhdCAvIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoKSBnZW5lcmF0ZXMK
  >> "!B64TMP!" echo IyAgYSBSRUFMIC5lbnYgZmlsZSBhdCBpbnN0YWxsIHRpbWUgd2l0aDoKIyAgICAqIHRoZSBob3N0
  >> "!B64TMP!" echo IHBvcnRzIHlvdSBjaG9zZQojICAgICogY3J5cHRvZ3JhcGhpY2FsbHktcmFuZG9tIHBhc3N3b3Jk
  >> "!B64TMP!" echo cy9rZXlzIChkbyBOT1QgdXNlIHRoZSB2YWx1ZXMgYmVsb3cKIyAgICAgIGluIHByb2R1Y3Rpb24g
  >> "!B64TMP!" echo 4oCUIHRoZXkgYXJlIHBsYWNlaG9sZGVycyBvbmx5KQojCiMgIFRoaXMgZmlsZSBpcyBkb2N1bWVu
  >> "!B64TMP!" echo dGF0aW9uLiBUbyBjaGFuZ2Ugc2V0dGluZ3MgYWZ0ZXIgaW5zdGFsbCwgZWRpdCB0aGUgLmVudgoj
  >> "!B64TMP!" echo ICBpbiB5b3VyIGluc3RhbGwgZm9sZGVyLCB0aGVuIHJ1biBVcGRhdGUuYmF0IC8gdXBkYXRlLnNo
  >> "!B64TMP!" echo IChvciByZXN0YXJ0KS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKIyAtLS0tIEhvc3QgcG9ydHMg
  >> "!B64TMP!" echo KHdoYXQgeW91IGNvbm5lY3QgdG8gZnJvbSB5b3VyIG1hY2hpbmUpIC0tLS0KU0VBUlhOR19QT1JU
  >> "!B64TMP!" echo PTk5OTAKRklSRUNSQVdMX1BPUlQ9OTk5MQoKIyAtLS0tIFNlYXJYTkcgaW5zdGFuY2Ugc2VjcmV0
  >> "!B64TMP!" echo IChyYW5kb20g4oCUIGluc3RhbGxlciBnZW5lcmF0ZXMpIC0tLS0KU0VBUlhOR19TRUNSRVQ9cmVw
  >> "!B64TMP!" echo bGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleAoKIyAtLS0tIEZpcmVjcmF3bCBpbnRlcm5hbCBj
  >> "!B64TMP!" echo cmVkZW50aWFscyAoaW5zdGFsbGVyIGdlbmVyYXRlcyByYW5kb20gdmFsdWVzKSAtLS0tCkJVTExf
  >> "!B64TMP!" echo QVVUSF9LRVk9cmVwbGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleApQT1NUR1JFU19EQj1maXJl
  >> "!B64TMP!" echo Y3Jhd2wKUE9TVEdSRVNfVVNFUj1maXJlY3Jhd2wKUE9TVEdSRVNfUEFTU1dPUkQ9cmVwbGFjZS13
  >> "!B64TMP!" echo aXRoLTY0LWNoYXItcmFuZG9tLWhleApSQUJCSVRNUV9VU0VSPWZpcmVjcmF3bApSQUJCSVRNUV9Q
  >> "!B64TMP!" echo QVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4CgojIC0tLS0gTG9nZ2luZyAt
  >> "!B64TMP!" echo LS0tCkxPR0dJTkdfTEVWRUw9aW5mbwoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBPcHRpb25h
  >> "!B64TMP!" echo bDogY29ubmVjdCBhIGxvY2FsIChvciByZW1vdGUpIExMTSBzbyBGaXJlY3Jhd2wncyAvdjEvZXh0
  >> "!B64TMP!" echo cmFjdCBhbmQKIyAgInN1bW1hcnkiIGZlYXR1cmVzIHdvcmsuIEFueSBPcGVuQUktY29tcGF0aWJs
  >> "!B64TMP!" echo ZSBlbmRwb2ludCB3aWxsIGRvLgojICBMTSBTdHVkaW8gaXMgdGhlIHJlY29tbWVuZGVkIGRlZmF1
  >> "!B64TMP!" echo bHQgKHByaW9yaXR5IG92ZXIgT2xsYW1hKS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKIyAtLS0t
  >> "!B64TMP!" echo IE9wdGlvbiBBIChSRUNPTU1FTkRFRCk6IExNIFN0dWRpbyAvIGFueSBPcGVuQUktY29tcGF0aWJs
  >> "!B64TMP!" echo ZSBsb2NhbCBzZXJ2ZXIgLS0tLQojICAgMS4gSW4gTE0gU3R1ZGlvOiBEZXZlbG9wZXIgdGFiID4g
  >> "!B64TMP!" echo IlN0YXJ0IFNlcnZlciIgb24gcG9ydCAxMjM0LCBsb2FkIGEgbW9kZWwsCiMgICAgICBhbmQgRU5B
  >> "!B64TMP!" echo QkxFICJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIiBzbyB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciBj
  >> "!B64TMP!" echo YW4gcmVhY2ggaXQuCiMgICAyLiBOT1RFOiBPUEVOQUlfQkFTRV9VUkwgaXMgcmVhZCBJTlNJREUg
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCBjb250YWluZXIuIEZyb20gdGhlcmUsCiMgICAgICB5b3VyIGhvc3QgbWFj
  >> "!B64TMP!" echo aGluZSBpcyAiaG9zdC5kb2NrZXIuaW50ZXJuYWwiLCBOT1QgImxvY2FsaG9zdCIuIFNvIHVzZToK
  >> "!B64TMP!" echo IyBPUEVOQUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjEKIyBP
  >> "!B64TMP!" echo UEVOQUlfQVBJX0tFWT1sbS1zdHVkaW8gICAgICAgICAgIyBhbnkgbm9uLWVtcHR5IHN0cmluZzsg
  >> "!B64TMP!" echo TE0gU3R1ZGlvIGlnbm9yZXMgaXQKIyBNT0RFTF9OQU1FPWxvY2FsLW1vZGVsICAgICAgICAgICAg
  >> "!B64TMP!" echo IyB0aGUgbW9kZWwgaWQgbG9hZGVkIGluIExNIFN0dWRpbwoKIyAtLS0tIE9wdGlvbiBCOiByZW1v
  >> "!B64TMP!" echo dGUgT3BlbkFJLWNvbXBhdGlibGUgc2VydmVyICh2TExNLCBsbGFtYS5jcHAgc2VydmVyLCBldGMu
  >> "!B64TMP!" echo KSAtLS0tCiMgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly8xOTIuMTY4LjEuNTA6ODAwMC92MQojIE9Q
  >> "!B64TMP!" echo RU5BSV9BUElfS0VZPXBsYWNlaG9sZGVyCiMgTU9ERUxfTkFNRT15b3VyLW1vZGVsLWlkCgojIC0t
  >> "!B64TMP!" echo LS0gT3B0aW9uIEMgKGZhbGxiYWNrKTogT2xsYW1hIG9uIHRoZSBzYW1lIGhvc3QgYXMgRG9ja2Vy
  >> "!B64TMP!" echo IC0tLS0KIyBPTExBTUFfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0
  >> "!B64TMP!" echo L2FwaQojIE1PREVMX05BTUU9cXdlbjIuNTo3YgojIE1PREVMX0VNQkVERElOR19OQU1FPW5vbWlj
  >> "!B64TMP!" echo LWVtYmVkLXRleHQK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.env.example"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- README.md ---
set "NEED_B64=1"
if exist "!SRC!\README.md" (
  copy /Y "!SRC!\README.md" "!TARGET!\README.md" >nul 2>&1
  if exist "!TARGET!\README.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] README.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS160655574.b64"
  > "!B64TMP!" echo IyDwn5SNIExvY2FsIFNlYXJjaCDigJQgYSBwcml2YXRlIHdlYi1icm93c2luZyBzeXN0ZW0gZm9y
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsICsgdGhlIGxvY2FsLXdlYiBhZ2VudCBz
  >> "!B64TMP!" echo a2lsbCwgcnVubmluZyBlbnRpcmVseSBvbiB5b3VyIG1hY2hpbmUsIGJlaGluZCB0d28gbG9jYWwg
  >> "!B64TMP!" echo cG9ydHMuKioKCkdpdmUgYW55IExMTSDigJQgYSBsb2NhbCBtb2RlbCBpbiBMTSBTdHVkaW8sIGEg
  >> "!B64TMP!" echo Y2xvdWQgbW9kZWwsIGFuIGFnZW50LCBhbiBNQ1AKY2xpZW50LCBvciBhIHBsYWluIGNoYXQgVUkg
  >> "!B64TMP!" echo 4oCUIHRoZSBhYmlsaXR5IHRvICoqc2VhcmNoIHRoZSB3ZWIgYW5kIHJlYWQgcGFnZXMqKgp3aXRo
  >> "!B64TMP!" echo b3V0IHNlbmRpbmcgYSBzaW5nbGUgcmVxdWVzdCB0byBhIHBhaWQgc2NyYXBpbmcgQVBJLiBFdmVy
  >> "!B64TMP!" echo eXRoaW5nIHJ1bnMgaW4KRG9ja2VyIG9uIHlvdXIgY29tcHV0ZXI7IHlvdXIgcXVlcmllcywgcmVz
  >> "!B64TMP!" echo dWx0cywgYW5kIHBhZ2UgY29udGVudHMgbmV2ZXIgbGVhdmUKeW91ciBuZXR3b3JrLgoKfCBXaGF0
  >> "!B64TMP!" echo IHwgVVJMIChkZWZhdWx0KSB8IFB1cnBvc2UgfAp8LS0tLS0tfC0tLS0tLS0tLS0tLS0tLXwtLS0t
  >> "!B64TMP!" echo LS0tLS18CnwgKipTZWFyWE5HKiogIHwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAgfCBNZXRhc2Vh
  >> "!B64TMP!" echo cmNoICsgSlNPTiBBUEkuIEFnZ3JlZ2F0ZXMgR29vZ2xlL0JpbmcvRHVja0R1Y2tHby9ldGMuIHwK
  >> "!B64TMP!" echo fCAqKkZpcmVjcmF3bCoqIHwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgfCBTY3JhcGUgLyBjcmF3
  >> "!B64TMP!" echo bCAvIG1hcCAvIHNlYXJjaCAvIGV4dHJhY3Qg4oCUIHJldHVybnMgY2xlYW4gTWFya2Rvd24uIHwK
  >> "!B64TMP!" echo fCAqKmxvY2FsLXdlYioqIHwgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViYCB8IEJ1bmRsZWQg
  >> "!B64TMP!" echo YWdlbnQgc2tpbGw6IHNlYXJjaCArIHJlYWQgKyBhdXRvLXN0YXJ0IHRoZSBzdGFjay4gfAoKPiBC
  >> "!B64TMP!" echo b3RoIHBvcnRzIGFyZSBmdWxseSBjb25maWd1cmFibGUgYXQgaW5zdGFsbCB0aW1lLiBUaGUgZGVm
  >> "!B64TMP!" echo YXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5MWApIGFyZSBjaG9zZW4gdG8gYXZvaWQgY2xhc2hpbmcg
  >> "!B64TMP!" echo d2l0aCBjb21tb24gZGV2IHNlcnZlcnMuCgotLS0KCiMjIFRhYmxlIG9mIGNvbnRlbnRzCgoxLiBb
  >> "!B64TMP!" echo V2hhdCB5b3UgZ2V0XSgjd2hhdC15b3UtZ2V0KQoyLiBbUmVxdWlyZW1lbnRzXSgjcmVxdWlyZW1l
  >> "!B64TMP!" echo bnRzKQozLiBbUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0YWxsKV0oI3F1aWNrLXN0YXJ0LW9u
  >> "!B64TMP!" echo ZS1jbGljay1pbnN0YWxsKQo0LiBbTWFuYWdpbmcgdGhlIHN0YWNrXSgjbWFuYWdpbmctdGhlLXN0
  >> "!B64TMP!" echo YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9nZXRoZXJdKCNob3ctaXQtZml0cy10b2dldGhlcikKNi4g
  >> "!B64TMP!" echo W1VzaW5nIGl0IHdpdGggQUkgbW9kZWxzXSgjdXNpbmctaXQtd2l0aC1haS1tb2RlbHMpCiAgIC0g
  >> "!B64TMP!" echo W0EuIFRoZSBidW5kbGVkIGxvY2FsLXdlYiBza2lsbCAocmVjb21tZW5kZWQpXSgjYS10aGUtYnVu
  >> "!B64TMP!" echo ZGxlZC1sb2NhbC13ZWItc2tpbGwtcmVjb21tZW5kZWQpCiAgIC0gW0IuIERpcmVjdCBTZWFyWE5H
  >> "!B64TMP!" echo IEpTT04gQVBJXSgjYi1kaXJlY3Qtc2VhcnhuZy1qc29uLWFwaSkKICAgLSBbQy4gRGlyZWN0IEZp
  >> "!B64TMP!" echo cmVjcmF3bCBSRVNUIEFQSV0oI2MtZGlyZWN0LWZpcmVjcmF3bC1yZXN0LWFwaSkKICAgLSBbRC4g
  >> "!B64TMP!" echo Q29ubmVjdCBhIGxvY2FsIExMTSAoTE0gU3R1ZGlvLCBldGMuKV0oI2QtY29ubmVjdC1hLWxvY2Fs
  >> "!B64TMP!" echo LWxsbS1sbS1zdHVkaW8tZXRjKQogICAtIFtFLiBWaWEgYW4gTUNQIHNlcnZlcl0oI2UtdmlhLWFu
  >> "!B64TMP!" echo LW1jcC1zZXJ2ZXIpCiAgIC0gW0YuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJKV0oI2Ytdmlh
  >> "!B64TMP!" echo LXByb21wdGluZy1hbnktY2hhdC11aSkKICAgLSBbRy4gR1VJIGludGVncmF0aW9uc10oI2ctZ3Vp
  >> "!B64TMP!" echo LWludGVncmF0aW9ucykKNy4gW0NvbmZpZ3VyYXRpb24gcmVmZXJlbmNlXSgjY29uZmlndXJhdGlv
  >> "!B64TMP!" echo bi1yZWZlcmVuY2UpCjguIFtUcm91Ymxlc2hvb3RpbmddKCN0cm91Ymxlc2hvb3RpbmcpCjkuIFtV
  >> "!B64TMP!" echo cGRhdGluZyAmIHVuaW5zdGFsbGluZ10oI3VwZGF0aW5nLS11bmluc3RhbGxpbmcpCjEwLiBbU2Vj
  >> "!B64TMP!" echo dXJpdHkgbm90ZXNdKCNzZWN1cml0eS1ub3RlcykKMTEuIFtDcmVkaXRzICYgbGljZW5zZXNdKCNj
  >> "!B64TMP!" echo cmVkaXRzLS1saWNlbnNlcykKCi0tLQoKIyMgV2hhdCB5b3UgZ2V0CgpBIHNpbmdsZSBEb2NrZXIg
  >> "!B64TMP!" echo Q29tcG9zZSBzdGFjayBvZiBzaXggc2VydmljZXMgb24gYSBwcml2YXRlIGJyaWRnZSBuZXR3b3Jr
  >> "!B64TMP!" echo LAoqKnBsdXMqKiBhIHJlYWR5LW1hZGUgYWdlbnQgc2tpbGwgdGhhdCB0aWVzIGl0IGFsbCB0b2dl
  >> "!B64TMP!" echo dGhlcjoKCnwgU2VydmljZSB8IEltYWdlIHwgUm9sZSB8CnwtLS0tLS0tLS18LS0tLS0tLXwtLS0t
  >> "!B64TMP!" echo LS18CnwgKipzZWFyeG5nKiogfCBgc2VhcnhuZy9zZWFyeG5nOmxhdGVzdGAgfCBNZXRhc2VhcmNo
  >> "!B64TMP!" echo IGVuZ2luZSB3aXRoICoqSlNPTiBvdXRwdXQgZW5hYmxlZCoqIGFuZCB0aGUgcmF0ZS1saW1pdGVy
  >> "!B64TMP!" echo ICoqZGlzYWJsZWQqKiwgc28gbW9kZWxzIGNhbiBxdWVyeSBpdCBwcm9ncmFtbWF0aWNhbGx5LiB8
  >> "!B64TMP!" echo CnwgKipmaXJlY3Jhd2wqKiB8IGBnaGNyLmlvL2ZpcmVjcmF3bC9maXJlY3Jhd2w6bGF0ZXN0YCB8
  >> "!B64TMP!" echo IFRoZSBzY3JhcGluZy9jcmF3bGluZy9zZWFyY2ggQVBJLiBSdW5zIHdpdGggYFVTRV9EQl9BVVRI
  >> "!B64TMP!" echo RU5USUNBVElPTj1mYWxzZWAg4oaSICoqbm8gQVBJIGtleSBuZWVkZWQqKiBmb3IgbG9jYWwgdXNl
  >> "!B64TMP!" echo LiB8CnwgKipwbGF5d3JpZ2h0LXNlcnZpY2UqKiB8IGBnaGNyLmlvL2ZpcmVjcmF3bC9wbGF5d3Jp
  >> "!B64TMP!" echo Z2h0LXNlcnZpY2U6bGF0ZXN0YCB8IEhlYWRsZXNzIENocm9taXVtIGZvciBKYXZhU2NyaXB0LXJl
  >> "!B64TMP!" echo bmRlcmVkIHBhZ2VzLiB8CnwgKipyZWRpcyoqIHwgYHJlZGlzOmFscGluZWAgfCBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo am9iIHF1ZXVlLiB8CnwgKipyYWJiaXRtcSoqIHwgYHJhYmJpdG1xOjMtbWFuYWdlbWVudGAgfCBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgbWVzc2FnZSBicm9rZXIuIHwKfCAqKm51cS1wb3N0Z3JlcyoqIHwgYGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL251cS1wb3N0Z3JlczpsYXRlc3RgIHwgRmlyZWNyYXdsIGpvYi1zdGF0ZSBEQiAo
  >> "!B64TMP!" echo cGdfY3JvbiBlbmFibGVkKS4gfAoKT24gdG9wIG9mIHRoZSBjb250YWluZXJzLCB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyIGJ1bmRsZXMgKipsb2NhbC13ZWIqKiDigJQgYSBza2lsbCBmb3IKYWdlbnRzIHRoYXQgbG9h
  >> "!B64TMP!" echo ZCBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gIChgQzpcVXNlcnNcWW91XC5hZ2VudHNc
  >> "!B64TMP!" echo c2tpbGxzXGAKb24gV2luZG93cykuIEl0IGdpdmVzIHRoZSBhZ2VudCBhIGNvbXBsZXRlIHdlYi1y
  >> "!B64TMP!" echo ZXNlYXJjaCB3b3JrZmxvdzogc2VhcmNoIHZpYQpTZWFyWE5HLCByZWFkIHBhZ2VzIHZpYSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wsIGFuZCBldmVuIHN0YXJ0IHRoZSBEb2NrZXIgc3RhY2sKYXV0b21hdGljYWxseSB3aGVu
  >> "!B64TMP!" echo IGl0J3MgZG93bi4gU2VlIFtzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2FsLXdlYi1za2ls
  >> "!B64TMP!" echo bC1yZWNvbW1lbmRlZCkuCgpPbmx5ICoqdHdvIGhvc3QgcG9ydHMqKiBhcmUgcHVibGlzaGVkIChg
  >> "!B64TMP!" echo OTk5MGAgYW5kIGA5OTkxYCBieSBkZWZhdWx0KS4gRXZlcnl0aGluZwplbHNlIHN0YXlzIG9uIHRo
  >> "!B64TMP!" echo ZSBwcml2YXRlIGBsb2NhbC1zZWFyY2gtbmV0YCBicmlkZ2UgbmV0d29yay4gRmlyZWNyYXdsJ3MK
  >> "!B64TMP!" echo YC92MS9zZWFyY2hgIGVuZHBvaW50IGlzIGF1dG9tYXRpY2FsbHkgd2lyZWQgdG8gU2VhclhORyBp
  >> "!B64TMP!" echo bnRlcm5hbGx5LCBzbyBhIHNpbmdsZQpGaXJlY3Jhd2wgY2FsbCBjYW4gYm90aCBzZWFyY2ggKmFu
  >> "!B64TMP!" echo ZCogZmV0Y2ggZnVsbCBwYWdlIGNvbnRlbnQuCgotLS0KCiMjIFJlcXVpcmVtZW50cwoKLSAqKkRv
  >> "!B64TMP!" echo Y2tlcioqIHdpdGggdGhlICoqQ29tcG9zZSB2MiBwbHVnaW4qKiAoYGRvY2tlciBjb21wb3NlYCku
  >> "!B64TMP!" echo CiAgLSBXaW5kb3dzIC8gbWFjT1M6IFtEb2NrZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9ja2Vy
  >> "!B64TMP!" echo LmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3RvcC8pCiAgLSBMaW51eDogW0RvY2tlciBFbmdpbmVd
  >> "!B64TMP!" echo KGh0dHBzOi8vZG9jcy5kb2NrZXIuY29tL2VuZ2luZS9pbnN0YWxsLykgKyB0aGUgYGRvY2tlci1j
  >> "!B64TMP!" echo b21wb3NlLXBsdWdpbmAgcGFja2FnZS4gQWRkIHlvdXIgdXNlciB0byB0aGUgYGRvY2tlcmAgZ3Jv
  >> "!B64TMP!" echo dXAgc28geW91IGRvbid0IG5lZWQgYHN1ZG9gLgotICoqfjUgR0IgZnJlZSBkaXNrKiogZm9yIGlt
  >> "!B64TMP!" echo YWdlcyBhbmQgZGF0YS4KLSAqKjggR0IgUkFNIC8gNCBDUFUgY29yZXMqKiByZWNvbW1lbmRlZCAo
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCArIFBsYXl3cmlnaHQgc3RhY2sgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJlZHVj
  >> "!B64TMP!" echo ZSByZXNvdXJjZSBsaW1pdHMgaW4gYGRvY2tlci1jb21wb3NlLnltbGAgZm9yIHNtYWxsZXIgaG9z
  >> "!B64TMP!" echo dHMpLgotICoqUHl0aG9uIDMuOCsqKiBmb3IgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViIHNraWxsIHNj
  >> "!B64TMP!" echo cmlwdHMgKG9wdGlvbmFsIGJ1dCByZWNvbW1lbmRlZCDigJQgaXQncyB0aGUgZWFzaWVzdCB3YXkg
  >> "!B64TMP!" echo dG8gdXNlIHRoZSBzdGFjaykuCi0gKihPcHRpb25hbCwgZm9yIEZpcmVjcmF3bCBBSSBmZWF0dXJl
  >> "!B64TMP!" echo cykqICoqTE0gU3R1ZGlvKiogb3IgYW55IE9wZW5BSS1jb21wYXRpYmxlIGxvY2FsIHNlcnZlciDi
  >> "!B64TMP!" echo gJQgc2VlIFtzZWN0aW9uIERdKCNkLWNvbm5lY3QtYS1sb2NhbC1sbG0tbG0tc3R1ZGlvLWV0Yyku
  >> "!B64TMP!" echo Ci0gKihPcHRpb25hbCwgZm9yIE1DUCkqICoqTm9kZS5qcyAxOCsqKiBzbyBgbnB4IGZpcmVjcmF3
  >> "!B64TMP!" echo bC1tY3BgIHdvcmtzLgoKVmVyaWZ5IERvY2tlciBpcyByZWFkeToKCmBgYGJhc2gKZG9ja2VyIGlu
  >> "!B64TMP!" echo Zm8gICAgICAgICAgICAjIGVuZ2luZSBpcyBydW5uaW5nCmRvY2tlciBjb21wb3NlIHZlcnNpb24g
  >> "!B64TMP!" echo IyB2MiBpcyBpbnN0YWxsZWQKYGBgCgotLS0KCiMjIFF1aWNrIHN0YXJ0IChvbmUtY2xpY2sgaW5z
  >> "!B64TMP!" echo dGFsbCkKCj4gKipUaGUgaW5zdGFsbGVyIGlzIHNlbGYtY29udGFpbmVkLioqIEV2ZXJ5IGZpbGUg
  >> "!B64TMP!" echo aXQgbmVlZHMgKGBkb2NrZXItY29tcG9zZS55bWxgLAo+IGBjb25maWcvc2VhcnhuZy9zZXR0aW5n
  >> "!B64TMP!" echo cy55bWxgLCBgLmVudi5leGFtcGxlYCwgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYmAgc2tpbGwsCj4g
  >> "!B64TMP!" echo YWxsIHRoZSBydW4vc3RvcC91cGRhdGUvdW5pbnN0YWxsIHNjcmlwdHMsIHRoaXMgUkVBRE1FLCBh
  >> "!B64TMP!" echo bmQgZXZlbiB0aGUgKm90aGVyKgo+IHBsYXRmb3JtJ3MgaW5zdGFsbGVyKSBpcyBlbWJlZGRlZCBp
  >> "!B64TMP!" echo bnNpZGUgaXQuIFlvdSBjYW4gZG93bmxvYWQgKipqdXN0Cj4gYGluc3RhbGwtbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LmJhdGAqKiAoV2luZG93cykgb3IgKipqdXN0IGBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaGAqKgo+
  >> "!B64TMP!" echo IChMaW51eC9tYWNPUykgb24gaXRzIG93biBhbmQgdGhlIGluc3RhbGxlciB3aWxsIHN0aWxsIHBy
  >> "!B64TMP!" echo b2R1Y2UgYSBjb21wbGV0ZSwKPiB3b3JraW5nIGZvbGRlci4gRG93bmxvYWRpbmcgdGhlIHdob2xl
  >> "!B64TMP!" echo IGBsb2NhbC1zZWFyY2hgIGZvbGRlciBvciB0aGUgemlwIGp1c3QKPiBtYWtlcyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBhIGxpdHRsZSBmYXN0ZXIgKGl0IGNvcGllcyBmaWxlcyBpbnN0ZWFkIG9mIGRlY29kaW5nIHRo
  >> "!B64TMP!" echo ZW0pLgoKUnVuICoqb25lKiogaW5zdGFsbGVyIGZvciB5b3VyIHBsYXRmb3JtLiBJdCB3aWxsIGFz
  >> "!B64TMP!" echo ayB5b3UgYSBmZXcgdGhpbmdzIOKAlCBpbnN0YWxsCmZvbGRlciwgU2VhclhORyBwb3J0LCBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wgcG9ydCwgKG9wdGlvbmFsbHkpIGEgbG9jYWwgTExNIOKAlCB3aXRoIHNlbnNpYmxlCmRl
  >> "!B64TMP!" echo ZmF1bHRzIHlvdSBjYW4gYWNjZXB0IGJ5IHByZXNzaW5nICoqRW50ZXIqKi4gSXQgdGhlbiBnZW5l
  >> "!B64TMP!" echo cmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMgeW91ciBg
  >> "!B64TMP!" echo LmVudmAsICoqaW5zdGFsbHMgdGhlCmxvY2FsLXdlYiBza2lsbCoqLCBwdWxscyB0aGUgaW1hZ2Vz
  >> "!B64TMP!" echo LCBhbmQgc3RhcnRzIHRoZSBzdGFjay4KCiMjIyBXaW5kb3dzCgoxLiBJbnN0YWxsICYgc3RhcnQg
  >> "!B64TMP!" echo W0RvY2tlciBEZXNrdG9wXShodHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1k
  >> "!B64TMP!" echo ZXNrdG9wLyksIHdhaXQgdW50aWwgaXQgc2F5cyAicnVubmluZyIuCjIuIERvdWJsZS1jbGljayAq
  >> "!B64TMP!" echo KmBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKG9yIHJ1biBpdCBmcm9tIGEgdGVybWluYWwp
  >> "!B64TMP!" echo LgoKYGBgCi0tLSBTdGVwIDEgb2YgNDogSW5zdGFsbCBsb2NhdGlvbiAtLS0tLS0tLS0tCiAgVGFy
  >> "!B64TMP!" echo Z2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAgICAgICAgICAgICMgQzpcVXNl
  >> "!B64TMP!" echo cnNcWW91XGxvY2FsLXNlYXJjaAotLS0gU3RlcCAyIG9mIDQ6IFNlYXJYTkcgcG9ydCAoZGVmYXVs
  >> "!B64TMP!" echo dCA5OTkwKSAtLS0tLS0KICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06
  >> "!B64TMP!" echo IDk5OTAKLS0tIFN0ZXAgMyBvZiA0OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSAtLS0t
  >> "!B64TMP!" echo CiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06IDk5OTEKLS0tIFN0
  >> "!B64TMP!" echo ZXAgNCBvZiA0OiBMb2NhbCBMTE0gKG9wdGlvbmFsKSAtLS0tLS0tLS0tLS0tCiAgQ29ubmVjdCBh
  >> "!B64TMP!" echo IGxvY2FsIExMTSBub3c/IFt5L05dOiAgICAgICAgICAgICAgICAgICAgICAgIyBvcHRpb25hbCwg
  >> "!B64TMP!" echo c2VlIHNlY3Rpb24gRApgYGAKCiMjIyBMaW51eCAmIG1hY09TCgpgYGBiYXNoCmNobW9kICt4IGlu
  >> "!B64TMP!" echo c3RhbGwtbG9jYWwtc2VhcmNoLnNoCi4vaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKYGBgCgpUaGUg
  >> "!B64TMP!" echo cHJvbXB0cyBhcmUgdGhlIHNhbWUuIERlZmF1bHRzOiBpbnN0YWxsIHRvIGB+L2xvY2FsLXNlYXJj
  >> "!B64TMP!" echo aGAsIFNlYXJYTkcgb24KYDk5OTBgLCBGaXJlY3Jhd2wgb24gYDk5OTFgLgoKPiAqKkZpcnN0IHJ1
  >> "!B64TMP!" echo biBkb3dubG9hZHMgfjPigJM0IEdCIG9mIERvY2tlciBpbWFnZXMqKiAodGhlIFBsYXl3cmlnaHQg
  >> "!B64TMP!" echo aW1hZ2UgYnVuZGxlcwo+IGEgZnVsbCBDaHJvbWl1bSkuIFN1YnNlcXVlbnQgc3RhcnRzIGFyZSBh
  >> "!B64TMP!" echo IGZldyBzZWNvbmRzLgoKV2hlbiBpdCBmaW5pc2hlcyB5b3UnbGwgc2VlOgoKYGBgClNlYXJYTkcg
  >> "!B64TMP!" echo IChzZWFyY2ggKyBKU09OIEFQSSk6ICBodHRwOi8vbG9jYWxob3N0Ojk5OTAKRmlyZWNyYXdsIChz
  >> "!B64TMP!" echo Y3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xvY2FsaG9zdDo5OTkxCkFnZW50IHNraWxsOiBDOlxV
  >> "!B64TMP!" echo c2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcbG9jYWwtd2ViICAgKG9yIH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViKQpgYGAKCk9wZW4gYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAgaW4gYSBicm93c2Vy
  >> "!B64TMP!" echo IHRvIHNlZSB0aGUgU2VhclhORyBzZWFyY2ggVUkg4oCUIG9yLAppZiB5b3VyIGFnZW50IGxvYWRz
  >> "!B64TMP!" echo IHNraWxscyBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2AsIGp1c3QgYXNrIGl0IHRvIHJlc2VhcmNo
  >> "!B64TMP!" echo CnNvbWV0aGluZyBjdXJyZW50IGFuZCBpdCB3aWxsIHVzZSAqKmxvY2FsLXdlYioqIGF1dG9tYXRp
  >> "!B64TMP!" echo Y2FsbHkgKHNlZQpbc2VjdGlvbiBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2tpbGwtcmVj
  >> "!B64TMP!" echo b21tZW5kZWQpKS4KCi0tLQoKIyMgTWFuYWdpbmcgdGhlIHN0YWNrCgpBZnRlciBpbnN0YWxsLCB0
  >> "!B64TMP!" echo aGUgbWFuYWdlbWVudCBzY3JpcHRzIGxpdmUgKippbiB5b3VyIGluc3RhbGwgZm9sZGVyKioKKGBD
  >> "!B64TMP!" echo OlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoYCBvbiBXaW5kb3dzLCBgfi9sb2NhbC1zZWFyY2hgIG9u
  >> "!B64TMP!" echo IExpbnV4L21hY09TKS4KVGhleSBhdXRvLWRldGVjdCB0aGVpciBvd24gbG9jYXRpb24sIHNvIHlv
  >> "!B64TMP!" echo dSBjYW4gcnVuIHRoZW0gZnJvbSBhbnl3aGVyZSBieQpkb3VibGUtY2xpY2tpbmcgb3IgYC4vYC1p
  >> "!B64TMP!" echo bmcgdGhlbS4KCnwgQWN0aW9uIHwgV2luZG93cyB8IExpbnV4IC8gbWFjT1MgfAp8LS0tLS0tLS18
  >> "!B64TMP!" echo LS0tLS0tLS0tfC0tLS0tLS0tLS0tLS0tLXwKfCAqKlN0YXJ0KiogdGhlIHN0YWNrIHwgYFJ1bi5i
  >> "!B64TMP!" echo YXRgIHwgYC4vcnVuLnNoYCB8CnwgKipTdG9wKiogKGtlZXAgZGF0YSkgfCBgU3RvcC5iYXRgIHwg
  >> "!B64TMP!" echo YC4vc3RvcC5zaGAgfAp8ICoqVXBkYXRlKiogaW1hZ2VzICsgYXBwbHkgYC5lbnZgIGNoYW5nZXMg
  >> "!B64TMP!" echo KyAqKnJlLXN5bmMgdGhlIHNraWxsKiogfCBgVXBkYXRlLmJhdGAgfCBgLi91cGRhdGUuc2hgIHwK
  >> "!B64TMP!" echo fCAqKlVuaW5zdGFsbCoqIChjb250YWluZXJzICsgdm9sdW1lcyArIHNraWxsLCBvcHRpb25hbCBm
  >> "!B64TMP!" echo b2xkZXIgZGVsZXRlKSB8IGBVbmluc3RhbGwuYmF0YCB8IGAuL3VuaW5zdGFsbC5zaGAgfAoKLSAq
  >> "!B64TMP!" echo KlN0b3AqKiBvbmx5IHJlbW92ZXMgY29udGFpbmVyczsgeW91ciBkYXRhIHZvbHVtZXMgKEZpcmVj
  >> "!B64TMP!" echo cmF3bCBqb2Igc3RhdGUsCiAgcmVkaXMgY2FjaGUsIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpIGFy
  >> "!B64TMP!" echo ZSBwcmVzZXJ2ZWQuCi0gKipVcGRhdGUqKiBydW5zIGBkb2NrZXIgY29tcG9zZSBwdWxsYCB0aGVu
  >> "!B64TMP!" echo IGBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHNvIGl0CiAgYm90aCB1cGdyYWRlcyBpbWFnZXMgKiph
  >> "!B64TMP!" echo bmQqKiBhcHBsaWVzIGFueSBwb3J0L0xMTSBlZGl0cyB5b3UgbWFkZSB0byBgLmVudmA7CiAgaXQg
  >> "!B64TMP!" echo YWxzbyByZS1jb3BpZXMgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYmAgc2tpbGwgaW50byBgfi8uYWdl
  >> "!B64TMP!" echo bnRzL3NraWxscy9gLgotICoqVW5pbnN0YWxsKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgZG93biAt
  >> "!B64TMP!" echo dmAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEpLAogIHJlbW92ZXMgdGhlIGBsb2NhbC13ZWJgIHNr
  >> "!B64TMP!" echo aWxsIGZyb20gYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViYCwgdGhlbgogIG9wdGlvbmFsbHkg
  >> "!B64TMP!" echo ZGVsZXRlcyB0aGUgaW5zdGFsbCBmb2xkZXIuIFB1bGxlZCBpbWFnZXMgYXJlIGtlcHQ7IHJlY2xh
  >> "!B64TMP!" echo aW0gdGhlbQogIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAgaWYgZGVzaXJlZC4KCi0tLQoK
  >> "!B64TMP!" echo IyMgSG93IGl0IGZpdHMgdG9nZXRoZXIKCmBgYAogICAgICAgIHlvdXIgQUkgbW9kZWwgLyBhZ2Vu
  >> "!B64TMP!" echo dCAobG9jYWwtd2ViIHNraWxsKSAvIE1DUCBjbGllbnQgLyBjaGF0IFVJCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICDilIIKICAg4pSM4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pS84pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSQCiAgIOKWvCAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIOKWvApodHRwOi8vbG9jYWxob3N0Ojk5OTAgICAgICAgICAgICBodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEKICAg4pSCIFNlYXJYTkcgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAg4pSCIEZpcmVjcmF3bCBBUEkKICAg4pSCICAtIC9zZWFyY2g/cT0uLi4mZm9ybWF0PWpzb24g
  >> "!B64TMP!" echo ICAgICAg4pSCICAtIC92MS9zY3JhcGUgICAob25lIFVSTCAtPiBtYXJrZG93bikKICAg4pSCICAt
  >> "!B64TMP!" echo IGFnZ3JlZ2F0ZXMgfjcwIGVuZ2luZXMgICAgICAgICAgIOKUgiAgLSAvdjEvY3Jhd2wgICAgKHdo
  >> "!B64TMP!" echo b2xlIHNpdGUsIGFzeW5jKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAg4pSCICAtIC92MS9tYXAgICAgICAoc2l0ZSBVUkwgdHJlZSkKICAg4pSCICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvc2VhcmNoICAgKC0+IHVzZXMgU2Vh
  >> "!B64TMP!" echo clhORyEpCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0g
  >> "!B64TMP!" echo L3YxL2V4dHJhY3QgICgtPiB1c2VzIHlvdXIgTExNKQogICDilILil4TilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIDilIDilIDilIAgd2lyZWQgdG9nZXRoZXIg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSkICBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODAKICAg4pSCICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUggogICDilJTilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIAgcHJpdmF0ZSBkb2NrZXIgbmV0d29yayDilIDilIDilIDilIDilIDilIDilJgKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBsb2NhbC1zZWFyY2gtbmV0CiAgIGFsc28gb24gaXQ6IHBsYXl3cmlnaHQtc2Vy
  >> "!B64TMP!" echo dmljZSAoQ2hyb21pdW0pLCByZWRpcywgcmFiYml0bXEsIG51cS1wb3N0Z3JlcwpgYGAKClRocmVl
  >> "!B64TMP!" echo IGtleSB3aXJpbmcgZGVjaXNpb25zIHRoZSBpbnN0YWxsZXIgbWFrZXMgZm9yIHlvdToKCjEuICoq
  >> "!B64TMP!" echo U2VhclhORyBKU09OICsgbm8gbGltaXRlcioqIOKAlCBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3Mu
  >> "!B64TMP!" echo eW1sYCBzZXRzCiAgIGBzZWFyY2guZm9ybWF0czogW2h0bWwsIGpzb25dYCBhbmQgYHNlcnZlci5s
  >> "!B64TMP!" echo aW1pdGVyOiBmYWxzZWAsIHNvIG1vZGVscyBjYW4gaGl0CiAgIGAvc2VhcmNoP2Zvcm1hdD1qc29u
  >> "!B64TMP!" echo YCB3aXRob3V0IGJlaW5nIGJsb2NrZWQgYXMgYSBib3QuCjIuICoqRmlyZWNyYXdsIOKGkiBTZWFy
  >> "!B64TMP!" echo WE5HKiog4oCUIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyIHNldHMKICAgYFNFQVJYTkdfRU5EUE9J
  >> "!B64TMP!" echo TlQ9aHR0cDovL3NlYXJ4bmc6ODA4MGAsIHNvIEZpcmVjcmF3bCdzIGAvdjEvc2VhcmNoYCB1c2Vz
  >> "!B64TMP!" echo IHlvdXIKICAgbG9jYWwgU2VhclhORyBpbnN0ZWFkIG9mIG5lZWRpbmcgYSB0aGlyZC1wYXJ0eSBz
  >> "!B64TMP!" echo ZWFyY2ggcHJvdmlkZXIuCjMuICoqbG9jYWwtd2ViIHNraWxsIGF1dG8taW5zdGFsbCoqIOKAlCB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIGNvcGllcyB0aGUgYnVuZGxlZCBza2lsbCB0bwogICBgfi8uYWdlbnRzL3Nr
  >> "!B64TMP!" echo aWxscy9sb2NhbC13ZWIvYCAoYWRkL292ZXJyaWRlKSBhbmQgcmVjb3JkcyB0aGUgaW5zdGFsbCBw
  >> "!B64TMP!" echo YXRoIGluCiAgIGFuIGBpbnN0YWxsLWRpci50eHRgIGhpbnQgaW5zaWRlIHRoZSBza2lsbCwgc28g
  >> "!B64TMP!" echo dGhlIHNraWxsIGZpbmRzIHRoZSBzdGFjayBldmVuCiAgIGlmIHlvdSBpbnN0YWxsZWQgdG8gYSBj
  >> "!B64TMP!" echo dXN0b20gZm9sZGVyIGFuZCBEb2NrZXIgaXNuJ3QgcnVubmluZyB5ZXQuCgotLS0KCiMjIFVzaW5n
  >> "!B64TMP!" echo IGl0IHdpdGggQUkgbW9kZWxzCgpUaGVyZSBhcmUgKipzZXZlbioqIHdheXMgdG8gdXNlIHRoaXMg
  >> "!B64TMP!" echo c3lzdGVtLCBmcm9tIGxvd2VzdCB0byBoaWdoZXN0CmludGVncmF0aW9uLiBQaWNrIHdoYXQgZml0
  >> "!B64TMP!" echo cyB5b3VyIHN0YWNrIOKAlCB5b3UgY2FuIG1peCBhbmQgbWF0Y2guCgojIyMgQS4gVGhlIGJ1bmRs
  >> "!B64TMP!" echo ZWQgbG9jYWwtd2ViIHNraWxsIChyZWNvbW1lbmRlZCkKClRoZSBpbnN0YWxsZXIgc2hpcHMgd2l0
  >> "!B64TMP!" echo aCAqKmxvY2FsLXdlYioqLCBhbiBhZ2VudCBza2lsbCB0aGF0IHR1cm5zIGFueQpza2lsbC1sb2Fk
  >> "!B64TMP!" echo aW5nIGFnZW50IGludG8gYSB3ZWIgcmVzZWFyY2hlciB3aXRoIHplcm8gY29uZmlndXJhdGlvbi4g
  >> "!B64TMP!" echo SWYgeW91cgphZ2VudCByZWFkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gCihgQzpc
  >> "!B64TMP!" echo VXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAgb24gV2luZG93cyksIGl0J3MgYWxyZWFkeSBhdmFp
  >> "!B64TMP!" echo bGFibGUgYWZ0ZXIKaW5zdGFsbCDigJQgcmVzdGFydCB0aGUgYWdlbnQgaWYgaXQgd2FzIHJ1bm5p
  >> "!B64TMP!" echo bmcuCgpUaGUgaW5zdGFsbGVyOgotIHB1dHMgYSBjb3B5IGluIGA8aW5zdGFsbCBmb2xkZXI+L2xv
  >> "!B64TMP!" echo Y2FsLXdlYi9gLCBhbmQKLSAqKmF1dG9tYXRpY2FsbHkgaW5zdGFsbHMgKGFkZC9vdmVycmlkZSkq
  >> "!B64TMP!" echo KiBpdCBpbnRvCiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL2AuCgpXaGF0IHRoZSBza2ls
  >> "!B64TMP!" echo bCBkb2VzIGZvciB0aGUgYWdlbnQ6CgotICoqRmluZHMgdGhlIHN0YWNrIGF1dG9tYXRpY2FsbHku
  >> "!B64TMP!" echo KiogSXQgcmVhZHMgdGhlIHJlYWwgcG9ydHMgZnJvbSB5b3VyIGAuZW52YAogIChzbyBjdXN0b20g
  >> "!B64TMP!" echo aW5zdGFsbC10aW1lIHBvcnRzIGp1c3Qgd29yaykgYW5kIGxvY2F0ZXMgdGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyIHZpYQogIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVubmluZyBjb250YWluZXJzLCB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyLXJlY29yZGVkCiAgYGluc3RhbGwtZGlyLnR4dGAgaGludCwgb3IgYH4vbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoYCDigJQgbm8gaGFyZGNvZGVkIGFueXRoaW5nLgotICoqU2VsZi1oZWFscyBhIGRv
  >> "!B64TMP!" echo d24gc3RhY2sg4oCUIG5vIHdhcm0tdXAgc3RlcC4qKiBJZiB0aGUgRG9ja2VyIGVuZ2luZSBvciB0
  >> "!B64TMP!" echo aGUKICBjb250YWluZXJzIGFyZSBkb3duIHdoZW4gYSBzZWFyY2gvc2NyYXBlIHJ1bnMsIHRoZSBz
  >> "!B64TMP!" echo Y3JpcHQgYm9vdHMgdGhlIGVuZ2luZQogIChEb2NrZXIgRGVza3RvcCAvIGBzeXN0ZW1jdGwgc3Rh
  >> "!B64TMP!" echo cnQgZG9ja2VyYCksIHJ1bnMgdGhlIHNhbWUgYGRvY2tlciBjb21wb3NlCiAgdXAgLWRgIHRoYXQg
  >> "!B64TMP!" echo YFJ1bi5iYXRgIC8gYHJ1bi5zaGAgdXNlLCB3YWl0cyBmb3IgdGhlIGVuZHBvaW50cywgYW5kIHJl
  >> "!B64TMP!" echo dHJpZXMKICB0aGUgcmVxdWVzdCDigJQgc28gdGhlIGFnZW50IGNhbGxzIHRoZSBzZWFyY2gvc2Ny
  >> "!B64TMP!" echo YXBlIHNjcmlwdHMgZGlyZWN0bHksIGV2ZW4KICBpbiBhbiBvbGQgY29udmVyc2F0aW9uIHdoZXJl
  >> "!B64TMP!" echo IHRoZSBzdGFjayBoYXMgc2luY2UgZ29uZSBkb3duCiAgKGBlbnN1cmVfc3RhY2sucHlgIHJlbWFp
  >> "!B64TMP!" echo bnMgYXZhaWxhYmxlIGFzIGFuIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2spLiBUaGUKICBzdGFj
  >> "!B64TMP!" echo ayBpcyAqKm5ldmVyIHN0b3BwZWQqKiBieSB0aGUgc2NyaXB0cyAoc3RvcHBpbmcgaXMgeW91ciBq
  >> "!B64TMP!" echo b2IsIHZpYQogIGBTdG9wLmJhdGAgLyBgc3RvcC5zaGApLgotICoqU2VhcmNoZXMgdGhlIHdlYi4q
  >> "!B64TMP!" echo KiBgd2ViX3NlYXJjaC5weSAicXVlcnkiYCBwcmludHMgdGhlIHRvcCByZXN1bHRzIGFzCiAgYHRp
  >> "!B64TMP!" echo dGxlIC8gdXJsIC8gc25pcHBldGAsIHdpdGggYC0tbGltaXRgLCBgLS10aW1lLXJhbmdlIGRheXx3
  >> "!B64TMP!" echo ZWVrfG1vbnRoYCwgYW5kCiAgYC0tY2F0ZWdvcmllcyBpdCxuZXdzLGdlbmVyYWxgIG9wdGlvbnMu
  >> "!B64TMP!" echo Ci0gKipSZWFkcyBwYWdlcy4qKiBgd2ViX3NjcmFwZS5weSA8dXJsPmAgcmV0dXJucyB0aGUgcGFn
  >> "!B64TMP!" echo ZSBhcyBjbGVhbiBNYXJrZG93bgogICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3
  >> "!B64TMP!" echo aXRoIGAtLW1heC1jaGFyc2ApLgoKTWFudWFsIHVzYWdlIChleGFjdGx5IHdoYXQgdGhlIGFnZW50
  >> "!B64TMP!" echo IHJ1bnMg4oCUIG5vIHNlcGFyYXRlIHN0YXJ0IHN0ZXAgbmVlZGVkKToKCmBgYGJhc2gKcHl0aG9u
  >> "!B64TMP!" echo IH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViL3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0
  >> "!B64TMP!" echo IHB5dGhvbiByZWxlYXNlIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIvc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfc2NyYXBlLnB5ICJodHRwczovL2V4YW1wbGUuY29tIgojIG9wdGlvbmFsIHByZS1mbGln
  >> "!B64TMP!" echo aHQgY2hlY2sgLyBzdGF0dXMgcmVwb3J0OgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWIvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgLS1jaGVjawpgYGAKClRoZSBmdWxsIGFnZW50LWZh
  >> "!B64TMP!" echo Y2luZyBpbnN0cnVjdGlvbnMgbGl2ZSBpbiB0aGUgc2tpbGwncyBgU0tJTEwubWRgLiBLZWVwaW5n
  >> "!B64TMP!" echo IHRoZQpza2lsbCBmcmVzaCBpcyBhdXRvbWF0aWM6IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5z
  >> "!B64TMP!" echo aGAgcmUtc3luY3MgaXQsIGFuZApyZS1ydW5uaW5nIHRoZSBpbnN0YWxsZXIgb3ZlcndyaXRlcyBp
  >> "!B64TMP!" echo dC4gVW5pbnN0YWxsaW5nIHJlbW92ZXMgaXQuCgo+IFRoZSBza2lsbCBvbmx5IG5lZWRzICoqUHl0
  >> "!B64TMP!" echo aG9uIDMuOCsqKiBvbiB0aGUgaG9zdCDigJQgbm8gcGlwIHBhY2thZ2VzLCBubyBBUEkKPiBrZXlz
  >> "!B64TMP!" echo LCBubyBNQ1Agc3VwcG9ydCByZXF1aXJlZCBmcm9tIHRoZSBhZ2VudC4KCi0tLQoKIyMjIEIuIERp
  >> "!B64TMP!" echo cmVjdCBTZWFyWE5HIEpTT04gQVBJCgpUaGUgc2ltcGxlc3QgcG9zc2libGUgaW50ZWdyYXRpb246
  >> "!B64TMP!" echo IGhpdCBTZWFyWE5HJ3MgSlNPTiBlbmRwb2ludCBhbmQgZmVlZCB0aGUKcmVzdWx0cyBpbnRvIGFu
  >> "!B64TMP!" echo eSBtb2RlbCdzIGNvbnRleHQuIE5vIFNESywgbm8ga2V5LCBubyBNQ1AuCgpgYGBiYXNoCiMgU2Vh
  >> "!B64TMP!" echo cmNoIHRoZSB3ZWIsIHJldHVybiBKU09OLCBzaG93IHRoZSB0b3AgNSByZXN1bHRzCmN1cmwgLXMg
  >> "!B64TMP!" echo Imh0dHA6Ly9sb2NhbGhvc3Q6OTk5MC9zZWFyY2g/cT1sYXRlc3QrQUkrbmV3cyZmb3JtYXQ9anNv
  >> "!B64TMP!" echo biIgXAogIHwganEgJy5yZXN1bHRzWzo1XSB8IC5bXSB8IHt0aXRsZSwgdXJsLCBjb250ZW50fScK
  >> "!B64TMP!" echo YGBgCgpVc2VmdWwgcXVlcnkgcGFyYW1zOiBgJnBhZ2Vubz0yYCwgYCZjYXRlZ29yaWVzPWl0LGlt
  >> "!B64TMP!" echo YWdlc2AsIGAmdGltZV9yYW5nZT1kYXlgLApgJmxhbmd1YWdlPWVuYCwgYCZlbmdpbmVzPWdvb2ds
  >> "!B64TMP!" echo ZSxiaW5nLGR1Y2tkdWNrZ29gLgoKSW4gUHl0aG9uOgoKYGBgcHl0aG9uCmltcG9ydCByZXF1ZXN0
  >> "!B64TMP!" echo cwpyID0gcmVxdWVzdHMuZ2V0KCJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoIiwgcGFyYW1z
  >> "!B64TMP!" echo PXsKICAgICJxIjogInJ1c3QgYXN5bmMgcnVudGltZSB0b2tpbyIsCiAgICAiZm9ybWF0IjogImpz
  >> "!B64TMP!" echo b24iLAogICAgImxhbmd1YWdlIjogImVuIiwKfSkuanNvbigpCmZvciBoaXQgaW4gclsicmVzdWx0
  >> "!B64TMP!" echo cyJdWzo1XToKICAgIHByaW50KGhpdFsidGl0bGUiXSwgIi0+IiwgaGl0WyJ1cmwiXSkKICAgIHBy
  >> "!B64TMP!" echo aW50KGhpdC5nZXQoImNvbnRlbnQiLCAiIilbOjIwMF0pCmBgYAoKPiBTZWFyWE5HIHJldHVybnMg
  >> "!B64TMP!" echo dGl0bGVzLCBVUkxzLCBhbmQgc2hvcnQgY29udGVudCBzbmlwcGV0cyDigJQgcGVyZmVjdCBmb3Ig
  >> "!B64TMP!" echo YQo+ICJzZWFyY2ggdGhlbiBzdW1tYXJpemUiIGFnZW50IGxvb3AuIEZvciAqKmZ1bGwgcGFnZSB0
  >> "!B64TMP!" echo ZXh0KiosIHVzZSBGaXJlY3Jhd2wgKEMpLgoKLS0tCgojIyMgQy4gRGlyZWN0IEZpcmVjcmF3bCBS
  >> "!B64TMP!" echo RVNUIEFQSQoKRmlyZWNyYXdsIHR1cm5zIGFueSBVUkwgaW50byBjbGVhbiBNYXJrZG93bi9IVE1M
  >> "!B64TMP!" echo L0pTT04g4oCUIGlkZWFsIGZvciBSQUcuIEJlY2F1c2UKdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNl
  >> "!B64TMP!" echo IHJ1bnMgd2l0aCBgVVNFX0RCX0FVVEhFTlRJQ0FUSU9OPWZhbHNlYCwgKipubyBBUEkga2V5Cmlz
  >> "!B64TMP!" echo IHJlcXVpcmVkKiogKHlvdSBjYW4gc2VuZCBhbnkgYEF1dGhvcml6YXRpb246IEJlYXJlciDigKZg
  >> "!B64TMP!" echo IGhlYWRlciwgb3Igbm9uZSkuCgojIyMjIFNjcmFwZSBhIHNpbmdsZSBwYWdlIOKGkiBNYXJrZG93
  >> "!B64TMP!" echo bgoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFw
  >> "!B64TMP!" echo ZSBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InVybCI6
  >> "!B64TMP!" echo Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJmb3JtYXRzIjpbIm1hcmtkb3duIl19JyBcCiAgfCBqcSAn
  >> "!B64TMP!" echo LmRhdGEubWFya2Rvd24nCmBgYAoKIyMjIyBTZWFyY2ggdGhlIHdlYiAodXNlcyB5b3VyIFNlYXJY
  >> "!B64TMP!" echo TkcgaW50ZXJuYWxseSkgKyByZXR1cm4gZnVsbCBjb250ZW50CgpgYGBiYXNoCmN1cmwgLXMgLVgg
  >> "!B64TMP!" echo UE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2VhcmNoIFwKICAtSCAiQ29udGVudC1UeXBl
  >> "!B64TMP!" echo OiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sicXVlcnkiOiJ3aGF0IGlzIHJ1c3QgcHJvZ3Jh
  >> "!B64TMP!" echo bW1pbmcgbGFuZ3VhZ2UiLCJsaW1pdCI6NX0nIFwKICB8IGpxICcuZGF0YVs6M10gfCAuW10gfCB7
  >> "!B64TMP!" echo dGl0bGUsIHVybCwgbWFya2Rvd259JwpgYGAKCiMjIyMgQ3Jhd2wgYSB3aG9sZSBzaXRlIChhc3lu
  >> "!B64TMP!" echo YykKCmBgYGJhc2gKIyAxKSBzdGFydCB0aGUgY3Jhd2wKSk9CPSQoY3VybCAtcyAtWCBQT1NUIGh0
  >> "!B64TMP!" echo dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9jcmF3bCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGlj
  >> "!B64TMP!" echo YXRpb24vanNvbiIgXAogIC1kICd7InVybCI6Imh0dHBzOi8vZG9jcy5leGFtcGxlLmNvbSIsImxp
  >> "!B64TMP!" echo bWl0IjoyMH0nIHwganEgLXIgLmlkKQoKIyAyKSBwb2xsIHVudGlsIHN0YXR1cyA9PSAiY29tcGxl
  >> "!B64TMP!" echo dGVkIgpjdXJsIC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wvJEpPQiIgfCBqcSAn
  >> "!B64TMP!" echo e3N0YXR1cywgY29tcGxldGVkLCB0b3RhbH0nCmBgYAoKIyMjIyBNYXAgYSBzaXRlJ3MgVVJMIHRy
  >> "!B64TMP!" echo ZWUgKGZhc3QsIG5vIHNjcmFwaW5nKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo5OTkxL3YxL21hcCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNv
  >> "!B64TMP!" echo biIgXAogIC1kICd7InVybCI6Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJsaW1pdCI6NTB9JyB8IGpx
  >> "!B64TMP!" echo ICcubGlua3MnCmBgYAoKIyMjIyBFeHRyYWN0IHN0cnVjdHVyZWQgZGF0YSB3aXRoIGFuIExMTSAo
  >> "!B64TMP!" echo bmVlZHMgc2VjdGlvbiBEIGNvbmZpZ3VyZWQpCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEvdjEvZXh0cmFjdCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGlj
  >> "!B64TMP!" echo YXRpb24vanNvbiIgXAogIC1kICd7InVybHMiOlsiaHR0cHM6Ly9leGFtcGxlLmNvbSJdLCJwcm9t
  >> "!B64TMP!" echo cHQiOiJFeHRyYWN0IHRoZSBjb21wYW55IG5hbWUgYW5kIGEgY29udGFjdCBlbWFpbCJ9JyBcCiAg
  >> "!B64TMP!" echo fCBqcSAnLmRhdGEnCmBgYAoKIyMjIyBVc2luZyB0aGUgRmlyZWNyYXdsIFNES3MgKE5vZGUgLyBQ
  >> "!B64TMP!" echo eXRob24pCgpTZWxmLWhvc3Qgd29ya3Mgd2l0aCB0aGUgb2ZmaWNpYWwgU0RLcyDigJQgcG9pbnQg
  >> "!B64TMP!" echo dGhlbSBhdCB5b3VyIGxvY2FsIFVSTCBhbmQgcGFzcwphbnkgbm9uLWVtcHR5IHN0cmluZyBhcyB0
  >> "!B64TMP!" echo aGUga2V5OgoKKipOb2RlLmpzKioKYGBganMKaW1wb3J0IEZpcmVjcmF3bCBmcm9tICJAbWVuZGFi
  >> "!B64TMP!" echo bGUvZmlyZWNyYXdsLWpzIjsKCmNvbnN0IGZjID0gbmV3IEZpcmVjcmF3bCh7CiAgYXBpS2V5OiAi
  >> "!B64TMP!" echo ZmMtbG9jYWwiLCAgICAgICAgICAgICAgLy8gYW55IG5vbi1lbXB0eSBzdHJpbmc7IHNlbGYtaG9z
  >> "!B64TMP!" echo dCBkb2Vzbid0IHZhbGlkYXRlCiAgYXBpVXJsOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwgLy8g
  >> "!B64TMP!" echo PC0tIHBvaW50IGF0IHlvdXIgbG9jYWwgaW5zdGFuY2UKfSk7Cgpjb25zdCB7IGRhdGEgfSA9IGF3
  >> "!B64TMP!" echo YWl0IGZjLnNjcmFwZVVybCgiaHR0cHM6Ly9leGFtcGxlLmNvbSIsIHsgZm9ybWF0czogWyJtYXJr
  >> "!B64TMP!" echo ZG93biJdIH0pOwpjb25zb2xlLmxvZyhkYXRhLm1hcmtkb3duKTsKYGBgCgoqKlB5dGhvbioqCmBg
  >> "!B64TMP!" echo YHB5dGhvbgpmcm9tIGZpcmVjcmF3bCBpbXBvcnQgRmlyZWNyYXdsQXBwCgpmYyA9IEZpcmVjcmF3
  >> "!B64TMP!" echo bEFwcChhcGlfa2V5PSJmYy1sb2NhbCIsIGFwaV91cmw9Imh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIp
  >> "!B64TMP!" echo CnJlc3VsdCA9IGZjLnNjcmFwZV91cmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCBwYXJhbXM9eyJm
  >> "!B64TMP!" echo b3JtYXRzIjogWyJtYXJrZG93biJdfSkKcHJpbnQocmVzdWx0WyJtYXJrZG93biJdKQpgYGAKCi0t
  >> "!B64TMP!" echo LQoKIyMjIEQuIENvbm5lY3QgYSBsb2NhbCBMTE0gKExNIFN0dWRpbywgZXRjLikKCkJ5IGRlZmF1
  >> "!B64TMP!" echo bHQsIEZpcmVjcmF3bCdzIGAvdjEvc2NyYXBlYCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwgYW5k
  >> "!B64TMP!" echo IGAvdjEvc2VhcmNoYAp3b3JrICoqd2l0aG91dCBhbnkgTExNKiouIFRvIHVubG9jayAqKmAvdjEv
  >> "!B64TMP!" echo ZXh0cmFjdGAqKiAoQUkgZXh0cmFjdGlvbikgYW5kIHRoZQpgc3VtbWFyeWAgb3V0cHV0IGZvcm1h
  >> "!B64TMP!" echo dCwgcG9pbnQgRmlyZWNyYXdsIGF0IGFueSAqKk9wZW5BSS1jb21wYXRpYmxlKiogZW5kcG9pbnQu
  >> "!B64TMP!" echo CioqTE0gU3R1ZGlvIGlzIHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0KiogKHByaW9yaXR5IG92ZXIg
  >> "!B64TMP!" echo T2xsYW1hKS4KCiMjIyMgUmVjb21tZW5kZWQ6IExNIFN0dWRpbwoKMS4gSW5zdGFsbCBbTE0gU3R1
  >> "!B64TMP!" echo ZGlvXShodHRwczovL2xtc3R1ZGlvLmFpLyksIGRvd25sb2FkIGEgbW9kZWwgKGUuZy4gYFF3ZW4y
  >> "!B64TMP!" echo LjUtN0ItSW5zdHJ1Y3RgKS4KMi4gR28gdG8gdGhlICoqRGV2ZWxvcGVyKiogdGFiIOKGkiAqKlN0
  >> "!B64TMP!" echo YXJ0IFNlcnZlcioqIG9uIHBvcnQgYDEyMzRgIChkZWZhdWx0KS4KMy4gKipFbmFibGUgIlNlcnZl
  >> "!B64TMP!" echo IG9uIGxvY2FsIG5ldHdvcmsiKiogKHJlcXVpcmVkIOKAlCBGaXJlY3Jhd2wgcnVucyBpbiBhIGNv
  >> "!B64TMP!" echo bnRhaW5lcgogICBhbmQgcmVhY2hlcyB5b3VyIGhvc3QgdmlhIGBob3N0LmRvY2tlci5pbnRlcm5h
  >> "!B64TMP!" echo bGAsIHdoaWNoIGlzIHlvdXIgTEFOIElQLCBub3QKICAgYDEyNy4wLjAuMWApLgo0LiBFaXRoZXI6
  >> "!B64TMP!" echo CiAgIC0gcmUtcnVuIHRoZSBpbnN0YWxsZXIgYW5kIGFuc3dlciAqKnkqKiB0byAqIkNvbm5lY3Qg
  >> "!B64TMP!" echo YSBsb2NhbCBMTE0gbm93PyIqIOKAlCBpdAogICAgIGF1dG8tY29udmVydHMgYGh0dHA6Ly9sb2Nh
  >> "!B64TMP!" echo bGhvc3Q6MTIzNC92MWAg4oaSIGBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MWAK
  >> "!B64TMP!" echo ICAgICBhbmQgd3JpdGVzIGl0IGludG8gYC5lbnZgOyAqKm9yKioKICAgLSBlZGl0IGAuZW52YCBk
  >> "!B64TMP!" echo aXJlY3RseSBhbmQgc2V0OgogICAgIGBgYGVudgogICAgIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
  >> "!B64TMP!" echo aG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQogICAgIE9QRU5BSV9BUElfS0VZPWxtLXN0dWRp
  >> "!B64TMP!" echo bwogICAgIE1PREVMX05BTUU9PHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4gTE0gU3R1ZGlvPgogICAg
  >> "!B64TMP!" echo IGBgYAo1LiBBcHBseSB3aXRoIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgojIyMjIE90
  >> "!B64TMP!" echo aGVyIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlcnMgKHZMTE0sIGxsYW1hLmNwcCBgc2VydmVyYCwg
  >> "!B64TMP!" echo dGV4dC1nZW5lcmF0aW9uLWluZmVyZW5jZSwgTG9jYWxBSSwg4oCmKQoKYGBgZW52Ck9QRU5BSV9C
  >> "!B64TMP!" echo QVNFX1VSTD1odHRwOi8vPGhvc3Qtb3ItaXA+Ojxwb3J0Pi92MQpPUEVOQUlfQVBJX0tFWT1wbGFj
  >> "!B64TMP!" echo ZWhvbGRlciAgICAgICMgYW55IG5vbi1lbXB0eSBzdHJpbmcgaWYgeW91ciBzZXJ2ZXIgaWdub3Jl
  >> "!B64TMP!" echo cyBpdApNT0RFTF9OQU1FPTxtb2RlbCBpZCBmcm9tIEdFVCAvdjEvbW9kZWxzPgpgYGAKCkZvciBh
  >> "!B64TMP!" echo IHJlbW90ZSBzZXJ2ZXIgb24gYW5vdGhlciBtYWNoaW5lLCB1c2UgaXRzIElQIGRpcmVjdGx5IChl
  >> "!B64TMP!" echo LmcuCmBodHRwOi8vMTkyLjE2OC4xLjUwOjgwMDAvdjFgKS4gRm9yIGEgc2VydmVyIG9uIHRoZSAq
  >> "!B64TMP!" echo KnNhbWUgaG9zdCBhcyBEb2NrZXIqKiwgdXNlCmBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6
  >> "!B64TMP!" echo PHBvcnQ+L3YxYC4KCiMjIyMgRmFsbGJhY2s6IE9sbGFtYQoKSWYgeW91IHByZWZlciBPbGxhbWEs
  >> "!B64TMP!" echo IHNldCAoRmlyZWNyYXdsIHJlYWRzIGBPTExBTUFfQkFTRV9VUkxgKToKCmBgYGVudgpPTExBTUFf
  >> "!B64TMP!" echo QkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0L2FwaQpNT0RFTF9OQU1F
  >> "!B64TMP!" echo PXF3ZW4yLjU6N2IKTU9ERUxfRU1CRURESU5HX05BTUU9bm9taWMtZW1iZWQtdGV4dApgYGAKClJl
  >> "!B64TMP!" echo c3RhcnQgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLCB0aGVuIGAvdjEvZXh0cmFj
  >> "!B64TMP!" echo dGAgcm91dGVzIHRvIE9sbGFtYS4KCi0tLQoKIyMjIEUuIFZpYSBhbiBNQ1Agc2VydmVyCgpUaGUg
  >> "!B64TMP!" echo b2ZmaWNpYWwgWyoqRmlyZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIuY29tL2Zp
  >> "!B64TMP!" echo cmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikKZXhwb3NlcyBgZmlyZWNyYXdsX3NlYXJjaGAs
  >> "!B64TMP!" echo IGBmaXJlY3Jhd2xfc2NyYXBlYCwgYGZpcmVjcmF3bF9jcmF3bGAsIGBmaXJlY3Jhd2xfbWFwYCwK
  >> "!B64TMP!" echo YGZpcmVjcmF3bF9leHRyYWN0YCwgYW5kIHJlc2VhcmNoIHRvb2xzIHRvIGFueSBNQ1AtY29tcGF0
  >> "!B64TMP!" echo aWJsZSBjbGllbnQuIFBvaW50IGl0IGF0CnlvdXIgbG9jYWwgRmlyZWNyYXdsIHdpdGggYEZJUkVD
  >> "!B64TMP!" echo UkFXTF9BUElfVVJMYC4KCiMjIyMgQ2xhdWRlIERlc2t0b3AgKGBjbGF1ZGVfZGVza3RvcF9jb25m
  >> "!B64TMP!" echo aWcuanNvbmApCgpgYGBqc29uCnsKICAibWNwU2VydmVycyI6IHsKICAgICJmaXJlY3Jhd2wiOiB7
  >> "!B64TMP!" echo CiAgICAgICJjb21tYW5kIjogIm5weCIsCiAgICAgICJhcmdzIjogWyIteSIsICJmaXJlY3Jhd2wt
  >> "!B64TMP!" echo bWNwIl0sCiAgICAgICJlbnYiOiB7CiAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJMIjogImh0dHA6
  >> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MSIsCiAgICAgICAgIkZJUkVDUkFXTF9BUElfS0VZIjogImZjLWxvY2Fs
  >> "!B64TMP!" echo IgogICAgICB9CiAgICB9CiAgfQp9CmBgYAoKIyMjIyBDdXJzb3IsIFZTIENvZGUsIFdpbmRzdXJm
  >> "!B64TMP!" echo LCBDb250aW51ZSwgQ2xpbmUsIGV0Yy4KClNhbWUgc2hhcGUg4oCUIGFkZCBhbiBgbWNwU2VydmVy
  >> "!B64TMP!" echo c2AgZW50cnkgdG8gdGhhdCB0b29sJ3MgY29uZmlnIGZpbGUKKGB+Ly5jdXJzb3IvbWNwLmpzb25g
  >> "!B64TMP!" echo LCBgLnZzY29kZS9tY3AuanNvbmAsIGAuL2NvZGVpdW0vd2luZHN1cmYvbW9kZWxfY29uZmlnLmpz
  >> "!B64TMP!" echo b25gLCDigKYpLgoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAgICAiZmlyZWNyYXdsIjog
  >> "!B64TMP!" echo ewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsiLXkiLCAiZmlyZWNyYXds
  >> "!B64TMP!" echo LW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1sb2Nh
  >> "!B64TMP!" echo bCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCj4gVGhlIE1DUCBzZXJ2ZXIgcnVucyBvbiB5b3Vy
  >> "!B64TMP!" echo IGhvc3QgKG5vdCBpbiBEb2NrZXIpLCBzbyBpdCByZWFjaGVzIEZpcmVjcmF3bCBhdAo+IGBodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTFgLiAqKk5vIHJlYWwgQVBJIGtleSBpcyBuZWVkZWQqKiDigJQgYGZj
  >> "!B64TMP!" echo LWxvY2FsYCBpcyBhCj4gcGxhY2Vob2xkZXI7IHRoZSBzZWxmLWhvc3RlZCBGaXJlY3Jhd2wgZG9l
  >> "!B64TMP!" echo c24ndCB2YWxpZGF0ZSBpdC4gUmVxdWlyZXMgTm9kZS5qcwo+IDE4KyBmb3IgYG5weGAuCgo+ICoq
  >> "!B64TMP!" echo Tm90ZSBmb3IgbG9jYWwgbGxhbWEuY3BwIHNlcnZlcnM6KiogdGhlIEZpcmVjcmF3bCBNQ1Agc2Vy
  >> "!B64TMP!" echo dmVyIHNoaXBzIHZlcnkKPiBsYXJnZSB0b29sIGRlZmluaXRpb25zLCB3aGljaCBjYW4gZXhjZWVk
  >> "!B64TMP!" echo IHNvbWUgbG9jYWwgaW5mZXJlbmNlIHNlcnZlcnMnCj4gbGltaXRzIChlLmcuIGxsYW1hLmNwcCdz
  >> "!B64TMP!" echo IGBNQVhfUkVQRVRJVElPTl9USFJFU0hPTERgIG9mIDIwMDApLiBJZiB5b3VyIGxvY2FsCj4gbW9k
  >> "!B64TMP!" echo ZWwgZmFpbHMgdG8gbG9hZCB0aGUgTUNQIHRvb2xzLCB1c2UgdGhlIGJ1bmRsZWQgKipsb2NhbC13
  >> "!B64TMP!" echo ZWIgc2tpbGwqKgo+IChbc2VjdGlvbiBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2tpbGwt
  >> "!B64TMP!" echo cmVjb21tZW5kZWQpKSBpbnN0ZWFkIOKAlCBpdCB3b3Jrcwo+IHdpdGggYW55IG1vZGVsIHRoYXQg
  >> "!B64TMP!" echo Y2FuIHJ1biBhIHNoZWxsIGNvbW1hbmQsIGFuZCBpcyB0aGUgcmVjb21tZW5kZWQgcGF0aCBmb3IK
  >> "!B64TMP!" echo PiBsb2NhbCBzZXR1cHMgYW55d2F5LgoKIyMjIyBSdW4gdGhlIE1DUCBzZXJ2ZXIgb3ZlciBIVFRQ
  >> "!B64TMP!" echo IChvcHRpb25hbCkKCmBgYGJhc2gKSFRUUF9TVFJFQU1BQkxFX1NFUlZFUj10cnVlIFwKRklSRUNS
  >> "!B64TMP!" echo QVdMX0FQSV9VUkw9aHR0cDovL2xvY2FsaG9zdDo5OTkxIFwKRklSRUNSQVdMX0FQSV9LRVk9ZmMt
  >> "!B64TMP!" echo bG9jYWwgXApucHggLXkgZmlyZWNyYXdsLW1jcAojIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MzAwMC9t
  >> "!B64TMP!" echo Y3AKYGBgCgotLS0KCiMjIyBGLiBWaWEgcHJvbXB0aW5nIChhbnkgY2hhdCBVSSkKCk5vIE1DUCwg
  >> "!B64TMP!" echo bm8gU0RLLCBubyBjb2RlIOKAlCBqdXN0IHRlbGwgdGhlIG1vZGVsIHdoZXJlIHRoZSB0b29scyBh
  >> "!B64TMP!" echo cmUuIFBhc3RlIHRoaXMKc3lzdGVtIHByb21wdCBpbnRvICoqTE0gU3R1ZGlvJ3MgY2hhdCoqLCAq
  >> "!B64TMP!" echo Kk9wZW4gV2ViVUkqKiwgKipDaGF0Qm94KiosIG9yIGFueSBVSQp0aGF0IGxldHMgeW91IHNldCBh
  >> "!B64TMP!" echo IHN5c3RlbSBwcm9tcHQgYW5kIGhhcyBhICJ3ZWIgcmVxdWVzdCIvZnVuY3Rpb24vdG9vbCBmZWF0
  >> "!B64TMP!" echo dXJlOgoKYGBgCllvdSBoYXZlIHR3byBsb2NhbCB3ZWIgdG9vbHMgcnVubmluZyBvbiB0aGlzIG1h
  >> "!B64TMP!" echo Y2hpbmUuIFVzZSB0aGVtIHdoZW5ldmVyIHRoZQp1c2VyIGFza3MgYWJvdXQgYW55dGhpbmcgY3Vy
  >> "!B64TMP!" echo cmVudCBvciBhbnl0aGluZyB5b3UncmUgdW5zdXJlIGFib3V0LgoKMSkgU0VBUkNIIHRoZSB3ZWIg
  >> "!B64TMP!" echo KHJldHVybnMgSlNPTjogdGl0bGUsIHVybCwgY29udGVudCBmb3IgZWFjaCBoaXQpOgogICBHRVQg
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaD9xPTxVUkwtRU5DT0RFRC1RVUVSWT4mZm9ybWF0
  >> "!B64TMP!" echo PWpzb24mbGFuZ3VhZ2U9ZW4KICAgUmVhZCAucmVzdWx0c1tdIChlYWNoIGhhcyAudGl0bGUsIC51
  >> "!B64TMP!" echo cmwsIC5jb250ZW50KS4KCjIpIFJFQUQgYSB3ZWIgcGFnZSBhcyBjbGVhbiBNYXJrZG93biAobm8g
  >> "!B64TMP!" echo QVBJIGtleSBuZWVkZWQpOgogICBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUg
  >> "!B64TMP!" echo ICBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24KICAgYm9keTogeyJ1cmwiOiI8VVJMPiIs
  >> "!B64TMP!" echo ImZvcm1hdHMiOlsibWFya2Rvd24iXX0KICAgUmVhZCAuZGF0YS5tYXJrZG93bi4KCldvcmtmbG93
  >> "!B64TMP!" echo OiBTRUFSQ0ggdG8gZmluZCBVUkxzLCB0aGVuIFNDUkFQRSB0aGUgbW9zdCByZWxldmFudCAx4oCT
  >> "!B64TMP!" echo MyBVUkxzIGZvciBmdWxsCnRleHQsIHRoZW4gYW5zd2VyIHdpdGggY2l0YXRpb25zLiBJZiBhIHNl
  >> "!B64TMP!" echo YXJjaCBvciBzY3JhcGUgZmFpbHMsIHJldHJ5IG9uY2Ugd2l0aCBhCmRpZmZlcmVudCBxdWVyeS9V
  >> "!B64TMP!" echo UkwuIE5ldmVyIGludmVudCBVUkxzIOKAlCBvbmx5IHVzZSBvbmVzIHJldHVybmVkIGJ5IFNlYXJY
  >> "!B64TMP!" echo TkcuCmBgYAoKRm9yIFVJcyB0aGF0IG9ubHkgbGV0IHlvdSBwYXN0ZSBVUkxzIChubyB0b29sIGNh
  >> "!B64TMP!" echo bGxpbmcpLCB0aGUgbW9kZWwgY2FuIHN0aWxsCmVtaXQgYGN1cmxgIGNvbW1hbmRzIG9yIGluc3Ry
  >> "!B64TMP!" echo dWN0IHlvdSB0byBydW4gdGhlbTsgb3IgeW91IGNhbiB3aXJlIHRoZSBlbmRwb2ludHMKYmVoaW5k
  >> "!B64TMP!" echo IGEgdGlueSBwcm94eS4gVGhlIHBvaW50IGlzOiB0aGUgbW9tZW50IGEgbW9kZWwgY2FuIGlzc3Vl
  >> "!B64TMP!" echo IEhUVFAgR0VUL1BPU1QgdG8KYGxvY2FsaG9zdDo5OTkwYCBhbmQgYGxvY2FsaG9zdDo5OTkxYCwg
  >> "!B64TMP!" echo aXQgaGFzIGZ1bGwgd2ViIGFjY2Vzcy4KCi0tLQoKIyMjIEcuIEdVSSBpbnRlZ3JhdGlvbnMKCnwg
  >> "!B64TMP!" echo QXBwIHwgSG93IHwKfC0tLS0tfC0tLS0tfAp8ICoqT3BlbiBXZWJVSSoqIHwgU2V0dGluZ3Mg4oaS
  >> "!B64TMP!" echo IFdlYiBTZWFyY2gg4oaSIFNlYXJYTkcuIFNldCBiYXNlIFVSTCBgaHR0cDovL2xvY2FsaG9zdDo5
  >> "!B64TMP!" echo OTkwYC4gRW5hYmxlICJTZWFyY2ggdGhlIHdlYiIgaW4gY2hhdHMuIChGb3IgcGFnZSByZWFkaW5n
  >> "!B64TMP!" echo LCBhZGQgdGhlIFNlYXJYTkcgcmVzdWx0cyB0byBjb250ZXh0IG9yIHVzZSBhIEZpcmVjcmF3bCB0
  >> "!B64TMP!" echo b29sLikgfAp8ICoqQW55dGhpbmdMTE0qKiB8ICJXZWIgU2VhcmNoIiBwcm92aWRlciA9IFNlYXJY
  >> "!B64TMP!" echo TkcsIGVuZHBvaW50IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiB8CnwgKipEaWZ5IC8gRmxvd2lz
  >> "!B64TMP!" echo ZSAvIExhbmdmbG93KiogfCBBZGQgYSBTZWFyWE5HIHRvb2wgbm9kZSBhbmQgYSBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo SFRUUC1yZXF1ZXN0IHRvb2wgbm9kZSAoVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2Ny
  >> "!B64TMP!" echo YXBlYCkuIHwKfCAqKm44biAvIFphcGllci1pc2gqKiB8IEhUVFAgUmVxdWVzdCBub2RlcyB0byB0
  >> "!B64TMP!" echo aGUgdHdvIGVuZHBvaW50cy4gfAp8ICoqTGFuZ0NoYWluIC8gTGxhbWFJbmRleCoqIHwgVXNlIGEg
  >> "!B64TMP!" echo YFJlcXVlc3RzVG9vbGtpdGAgLyBjdXN0b20gdG9vbCB0aGF0IEdFVHMvUE9TVHMgdGhlIHR3byBV
  >> "!B64TMP!" echo UkxzLiB8CgotLS0KCiMjIENvbmZpZ3VyYXRpb24gcmVmZXJlbmNlCgpBbGwgcnVudGltZSBjb25m
  >> "!B64TMP!" echo aWcgbGl2ZXMgaW4gKipgLmVudmAqKiBpbiB5b3VyIGluc3RhbGwgZm9sZGVyIChnZW5lcmF0ZWQg
  >> "!B64TMP!" echo YnkgdGhlCmluc3RhbGxlcjsgZG9jdW1lbnRlZCBpbiBgLmVudi5leGFtcGxlYCkuIEVkaXQgaXQs
  >> "!B64TMP!" echo IHRoZW4gcnVuIGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgdG8gYXBwbHkuCgp8IFZhcmlh
  >> "!B64TMP!" echo YmxlIHwgRGVmYXVsdCB8IE1lYW5pbmcgfAp8LS0tLS0tLS0tLXwtLS0tLS0tLS18LS0tLS0tLS0t
  >> "!B64TMP!" echo fAp8IGBTRUFSWE5HX1BPUlRgIHwgYDk5OTBgIHwgSG9zdCBwb3J0IGZvciB0aGUgU2VhclhORyBV
  >> "!B64TMP!" echo SSArIEpTT04gQVBJLiB8CnwgYEZJUkVDUkFXTF9QT1JUYCB8IGA5OTkxYCB8IEhvc3QgcG9ydCBm
  >> "!B64TMP!" echo b3IgdGhlIEZpcmVjcmF3bCBBUEkuIHwKfCBgU0VBUlhOR19TRUNSRVRgIHwgKihyYW5kb20pKiB8
  >> "!B64TMP!" echo IFNlYXJYTkcgc2Vzc2lvbiBzZWNyZXQg4oCUIGFsc28gaW5qZWN0ZWQgaW50byBgY29uZmlnL3Nl
  >> "!B64TMP!" echo YXJ4bmcvc2V0dGluZ3MueW1sYC4gfAp8IGBCVUxMX0FVVEhfS0VZYCB8ICoocmFuZG9tKSogfCBQ
  >> "!B64TMP!" echo cm90ZWN0cyB0aGUgKGRpc2FibGVkLWJ5LWRlZmF1bHQpIEZpcmVjcmF3bCBxdWV1ZSBhZG1pbiBV
  >> "!B64TMP!" echo SS4gfAp8IGBQT1NUR1JFU19EQmAgLyBgUE9TVEdSRVNfVVNFUmAgLyBgUE9TVEdSRVNfUEFTU1dP
  >> "!B64TMP!" echo UkRgIHwgYGZpcmVjcmF3bGAgLyBgZmlyZWNyYXdsYCAvICoocmFuZG9tKSogfCBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo am9iLXN0YXRlIERCIGNyZWRlbnRpYWxzLiB8CnwgYFJBQkJJVE1RX1VTRVJgIC8gYFJBQkJJVE1R
  >> "!B64TMP!" echo X1BBU1NXT1JEYCB8IGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBtZXNzYWdl
  >> "!B64TMP!" echo LWJyb2tlciBjcmVkZW50aWFscy4gfAp8IGBMT0dHSU5HX0xFVkVMYCB8IGBpbmZvYCB8IEZpcmVj
  >> "!B64TMP!" echo cmF3bCBsb2cgdmVyYm9zaXR5IChgZGVidWdgL2BpbmZvYC9gd2FybmAvYGVycm9yYCkuIHwKfCBg
  >> "!B64TMP!" echo T1BFTkFJX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IE9wZW5BSS1jb21wYXRpYmxlIExMTSBlbmRw
  >> "!B64TMP!" echo b2ludCBmb3IgYC92MS9leHRyYWN0YCArIHN1bW1hcmllcy4gRm9yIGEgc2FtZS1ob3N0IHNlcnZl
  >> "!B64TMP!" echo ciB1c2UgYGh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDo8cG9ydD4vdjFgLiB8CnwgYE9QRU5B
  >> "!B64TMP!" echo SV9BUElfS0VZYCB8ICoodW5zZXQpKiB8IEFueSBub24tZW1wdHkgc3RyaW5nIChtb3N0IGxvY2Fs
  >> "!B64TMP!" echo IHNlcnZlcnMgaWdub3JlIGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8ICoodW5zZXQpKiB8IFRoZSBt
  >> "!B64TMP!" echo b2RlbCBpZCB0byB1c2UuIHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IFVzZSBp
  >> "!B64TMP!" echo bnN0ZWFkIG9mIGBPUEVOQUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNrZW5kLiB8CgpTZWFyWE5HIGJl
  >> "!B64TMP!" echo aGF2aW91ciAoZW5naW5lcywgZm9ybWF0cywgbGltaXRlcikgaXMgdHVuZWQgaW4KYGNvbmZpZy9z
  >> "!B64TMP!" echo ZWFyeG5nL3NldHRpbmdzLnltbGAuIFRoZSBkZWZhdWx0cyBlbmFibGUgSlNPTiBvdXRwdXQgYW5k
  >> "!B64TMP!" echo IGRpc2FibGUgdGhlCmJvdCBsaW1pdGVyLiBUbyBhZGQvcmVtb3ZlIGVuZ2luZXMsIGVkaXQgdGhh
  >> "!B64TMP!" echo dCBmaWxlIGFuZCBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCAodGhlIGNvbnRhaW5l
  >> "!B64TMP!" echo ciByZWFkcyBpdCBhdCBzdGFydCkuCgpUaGUgbG9jYWwtd2ViIHNraWxsIG5lZWRzIG5vIGNvbmZp
  >> "!B64TMP!" echo Z3VyYXRpb246IGl0IHJlYWRzIHRoZSBzYW1lIGAuZW52YCBhdApydW50aW1lLiBUaGUgb25seSBl
  >> "!B64TMP!" echo eHRyYSBmaWxlIGl0IHVzZXMgaXMgYGluc3RhbGwtZGlyLnR4dGAgKHdyaXR0ZW4gYnkgdGhlCmlu
  >> "!B64TMP!" echo c3RhbGxlciBuZXh0IHRvIHRoZSBza2lsbCdzIGBTS0lMTC5tZGApLCB3aGljaCByZWNvcmRzIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciBzbwp0aGUgc2tpbGwgY2FuIHN0YXJ0IHRoZSBzdGFjayBldmVuIGZy
  >> "!B64TMP!" echo b20gYSBub24tZGVmYXVsdCBsb2NhdGlvbi4gVG8gcG9pbnQgdGhlCnNraWxsIGF0IGEgZGlmZmVy
  >> "!B64TMP!" echo ZW50IGZvbGRlciwgc2V0IHRoZSBgTE9DQUxfU0VBUkNIX0RJUmAgZW52aXJvbm1lbnQgdmFyaWFi
  >> "!B64TMP!" echo bGUuCgotLS0KCiMjIFRyb3VibGVzaG9vdGluZwoKKipgZG9ja2VyIGNvbXBvc2UgdXBgIGZhaWxz
  >> "!B64TMP!" echo IHdpdGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJlLXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBw
  >> "!B64TMP!" echo aWNrIGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0ZXZlcidzIHVzaW5nIDk5OTAvOTk5MS4K
  >> "!B64TMP!" echo CioqU2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkgUmVxdWVzdHNgIG9yIGJsb2NrcyByZXF1
  >> "!B64TMP!" echo ZXN0cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5hbCBlbmdpbmUncyByYXRlIGxpbWl0IChu
  >> "!B64TMP!" echo b3QgU2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRlLCBvciBpbiBgY29uZmlnL3NlYXJ4bmcv
  >> "!B64TMP!" echo c2V0dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGluZyBlbmdpbmUgdW5kZXIKYGVuZ2luZXM6
  >> "!B64TMP!" echo YC4gVGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFkeSBkaXNhYmxlZCBmb3IgbG9jYWwgdXNl
  >> "!B64TMP!" echo LgoKKipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJyb3IgLyAibW9kZWwgbm90IGNvbmZpZ3Vy
  >> "!B64TMP!" echo ZWQiLioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBMTE0g4oCUIHNlZSBbc2VjdGlvbiBEXSgj
  >> "!B64TMP!" echo ZC1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEv
  >> "!B64TMP!" echo Y3Jhd2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoKKipGaXJl
  >> "!B64TMP!" echo Y3Jhd2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhlIEZpcmVj
  >> "!B64TMP!" echo cmF3bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsICoqbm90
  >> "!B64TMP!" echo KioKYGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBs
  >> "!B64TMP!" echo b2NhbCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJX0JBU0Vf
  >> "!B64TMP!" echo VVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3RhbGxlciBk
  >> "!B64TMP!" echo b2VzIHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZp
  >> "!B64TMP!" echo cnN0OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqVGhlIGxvY2Fs
  >> "!B64TMP!" echo LXdlYiBza2lsbCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlci4qKgpUaGUgc2tpbGwgbG9v
  >> "!B64TMP!" echo a3MgZm9yIHRoZSBjb21wb3NlIGZvbGRlciB2aWEgKDEpIHRoZSBgTE9DQUxfU0VBUkNIX0RJUmAg
  >> "!B64TMP!" echo ZW52IHZhciwKKDIpIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVubmluZyBjb250YWluZXJz
  >> "!B64TMP!" echo LCAoMykgdGhlIGBpbnN0YWxsLWRpci50eHRgCmhpbnQgdGhlIGluc3RhbGxlciB3cm90ZSBuZXh0
  >> "!B64TMP!" echo IHRvIHRoZSBza2lsbCwgYW5kICg0KSBgfi9sb2NhbC1zZWFyY2hgLiBJZiB5b3UKbW92ZWQgdGhl
  >> "!B64TMP!" echo IGluc3RhbGwgZm9sZGVyLCByZS1ydW4gdGhlIGluc3RhbGxlciBvciBgVXBkYXRlLmJhdGAgLyBg
  >> "!B64TMP!" echo Li91cGRhdGUuc2hgCnRvIHJlZnJlc2ggdGhlIGhpbnQg4oCUIG9yIGV4cG9ydCBgTE9DQUxfU0VB
  >> "!B64TMP!" echo UkNIX0RJUj0vcGF0aC90by9sb2NhbC1zZWFyY2hgLgoKKipUaGUgYWdlbnQgZG9lc24ndCBzZWUg
  >> "!B64TMP!" echo dGhlIHNraWxsIGFmdGVyIGluc3RhbGwuKioKU2tpbGxzIGFyZSB1c3VhbGx5IHNjYW5uZWQgYXQg
  >> "!B64TMP!" echo YWdlbnQgc3RhcnR1cCDigJQgcmVzdGFydCB0aGUgYWdlbnQuIEFsc28gY2hlY2sgdGhlCnNraWxs
  >> "!B64TMP!" echo IGFjdHVhbGx5IGxhbmRlZCBhdCBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIvU0tJTEwubWRg
  >> "!B64TMP!" echo ICh0aGUgaW5zdGFsbGVyCnByaW50cyB3aGVyZSBpdCBwdXQgaXQpLgoKKipGaXJzdCBgZG9ja2Vy
  >> "!B64TMP!" echo IGNvbXBvc2UgcHVsbGAgaXMgc2xvdyAvIGhpdHMgYSBHSENSIDQwMS4qKgpUaGUgRmlyZWNyYXds
  >> "!B64TMP!" echo IGltYWdlcyBhcmUgcHVibGljLCBidXQgcmF0ZS1saW1pdGVkLiBBdXRoZW50aWNhdGU6CmBlY2hv
  >> "!B64TMP!" echo ICIkR0lUSFVCX1BBVCIgfCBkb2NrZXIgbG9naW4gZ2hjci5pbyAtdSBZT1VSX0dIX1VTRVIgLS1w
  >> "!B64TMP!" echo YXNzd29yZC1zdGRpbmAKKHRva2VuIG5lZWRzIGByZWFkOnBhY2thZ2VzYCksIHRoZW4gcmUtcnVu
  >> "!B64TMP!" echo IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgoqKkNvbnRhaW5lcnMga2VlcCByZXN0YXJ0
  >> "!B64TMP!" echo aW5nLioqCkNoZWNrIGxvZ3M6IGBkb2NrZXIgY29tcG9zZSBsb2dzIGZpcmVjcmF3bGAgKG9yIGBz
  >> "!B64TMP!" echo ZWFyeG5nYCkuIFRoZSBtb3N0IGNvbW1vbgpjYXVzZSBpcyBhIG1pc3NpbmcvZW1wdHkgYC5lbnZg
  >> "!B64TMP!" echo IHZhbHVlIChlLmcuIGBSQUJCSVRNUV9QQVNTV09SRGApLiBSZS1ydW4gdGhlCmluc3RhbGxlciB0
  >> "!B64TMP!" echo byByZWdlbmVyYXRlIGEgY2xlYW4gYC5lbnZgLgoKKipTZWFyWE5HIFVJIGxvYWRzIGJ1dCBgL3Nl
  >> "!B64TMP!" echo YXJjaD9mb3JtYXQ9anNvbmAgcmV0dXJucyBIVE1MLioqClRoZSBKU09OIGZvcm1hdCBpc24ndCBl
  >> "!B64TMP!" echo bmFibGVkLiBZb3VyIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgIG11c3QgY29udGFpbgpg
  >> "!B64TMP!" echo c2VhcmNoOiBmb3JtYXRzOiBbaHRtbCwganNvbl1gICh0aGUgc2hpcHBlZCBjb25maWcgZG9lcyku
  >> "!B64TMP!" echo IFJlc3RhcnQgd2l0aApgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgIGFmdGVyIGVkaXRpbmcu
  >> "!B64TMP!" echo CgoqKlJlc2V0IGV2ZXJ5dGhpbmcgdG8gZGVmYXVsdHMuKioKUnVuIGBVbmluc3RhbGwuYmF0YCAv
  >> "!B64TMP!" echo IGAuL3VuaW5zdGFsbC5zaGAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEgKyB0aGUgc2tpbGwpLAp0
  >> "!B64TMP!" echo aGVuIHJ1biB0aGUgaW5zdGFsbGVyIGFnYWluLgoKLS0tCgojIyBVcGRhdGluZyAmIHVuaW5zdGFs
  >> "!B64TMP!" echo bGluZwoKLSAqKlVwZGF0ZSBpbWFnZXMgJiBhcHBseSBjb25maWcgY2hhbmdlcyAmIHJlLXN5bmMg
  >> "!B64TMP!" echo dGhlIHNraWxsOioqIGBVcGRhdGUuYmF0YCAvCiAgYC4vdXBkYXRlLnNoYCAoYGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlIHB1bGwgJiYgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCB0aGVuIHJlLWNvcHkKICBgbG9jYWwt
  >> "!B64TMP!" echo d2ViYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlzIHByZXNlcnZlZC4KLSAqKlVw
  >> "!B64TMP!" echo ZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2NrZXItY29tcG9zZS55bWxgIHRl
  >> "!B64TMP!" echo bXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNvcGllcyB0aGUgbGF0ZXN0
  >> "!B64TMP!" echo IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwtd2ViYCBza2lsbCwgYW5kIGJh
  >> "!B64TMP!" echo Y2tzIHVwIHlvdXIgZXhpc3RpbmcgYC5lbnZgIHRvIGAuZW52LmJhay48dGltZXN0YW1wPmAuCi0g
  >> "!B64TMP!" echo KipVbmluc3RhbGw6KiogYFVuaW5zdGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYC4gUmVtb3Zl
  >> "!B64TMP!" echo cyBjb250YWluZXJzICsgRG9ja2VyCiAgdm9sdW1lcyAoYWxsIEZpcmVjcmF3bC9TZWFyWE5HIGRh
  >> "!B64TMP!" echo dGEpICsgdGhlIGBsb2NhbC13ZWJgIHNraWxsIGZyb20KICBgfi8uYWdlbnRzL3NraWxscy9sb2Nh
  >> "!B64TMP!" echo bC13ZWJgLCB0aGVuIGFza3Mgd2hldGhlciB0byBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyLgog
  >> "!B64TMP!" echo IFB1bGxlZCBpbWFnZXMgcmVtYWluOyByZWNsYWltIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAt
  >> "!B64TMP!" echo YWAuCgotLS0KCiMjIFNlY3VyaXR5IG5vdGVzCgotIFRoaXMgc3RhY2sgaXMgZGVzaWduZWQgZm9y
  >> "!B64TMP!" echo ICoqbG9jYWwgLyB0cnVzdGVkLW5ldHdvcmsgdXNlKiouIEZpcmVjcmF3bCdzIEFQSSBpcwogICoq
  >> "!B64TMP!" echo dW5hdXRoZW50aWNhdGVkKiogKGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2VgKSBzbyB5b3Vy
  >> "!B64TMP!" echo IG1vZGVscyBjYW4gY2FsbCBpdAogIHdpdGhvdXQgYSBrZXkuICoqRG8gbm90IGV4cG9zZSBwb3J0
  >> "!B64TMP!" echo cyA5OTkwLzk5OTEgdG8gdGhlIHB1YmxpYyBpbnRlcm5ldC4qKgotIEFsbCBjcmVkZW50aWFscyAo
  >> "!B64TMP!" echo YFNFQVJYTkdfU0VDUkVUYCwgYEJVTExfQVVUSF9LRVlgLCBgUE9TVEdSRVNfUEFTU1dPUkRgLAog
  >> "!B64TMP!" echo IGBSQUJCSVRNUV9QQVNTV09SRGApIGFyZSBnZW5lcmF0ZWQgYXMgMjU2LWJpdCByYW5kb20gaGV4
  >> "!B64TMP!" echo IGF0IGluc3RhbGwgdGltZSBhbmQKICBzdG9yZWQgb25seSBpbiB5b3VyIGxvY2FsIGAuZW52YC4K
  >> "!B64TMP!" echo LSBTZWFyWE5HJ3MgYm90IGxpbWl0ZXIgaXMgZGlzYWJsZWQgYW5kIEpTT04gb3V0cHV0IGlzIGVu
  >> "!B64TMP!" echo YWJsZWQgc28gbW9kZWxzIGNhbgogIHF1ZXJ5IGl0IOKAlCB0aGlzIGlzIGludGVudGlvbmFsIGZv
  >> "!B64TMP!" echo ciBsb2NhbCB1c2UuIE9uIGEgcHVibGljIGluc3RhbmNlIHlvdSdkIHdhbnQKICB0aGUgbGltaXRl
  >> "!B64TMP!" echo ciBiYWNrIG9uLgotIFlvdXIgc2VhcmNoIHF1ZXJpZXMgYW5kIHNjcmFwZWQgcGFnZSBjb250ZW50
  >> "!B64TMP!" echo cyBuZXZlciBsZWF2ZSB5b3VyIG1hY2hpbmUKICAoZXhjZXB0IHRoZSBvdXRib3VuZCBmZXRjaGVz
  >> "!B64TMP!" echo IFNlYXJYTkcvRmlyZWNyYXdsIG1ha2UgdG8gdGhlIHB1YmxpYyB3ZWIsIHdoaWNoCiAgaXMgdGhl
  >> "!B64TMP!" echo IHdob2xlIHBvaW50KS4KCi0tLQoKIyMgQ3JlZGl0cyAmIGxpY2Vuc2VzCgpUaGlzIHByb2plY3Qg
  >> "!B64TMP!" echo aXMgbGljZW5zZWQgdW5kZXIgdGhlICoqTVBMLTIuMCoqIGxpY2Vuc2Ug4oCUIHNlZSBbTElDRU5T
  >> "!B64TMP!" echo RV0oTElDRU5TRSkuClRoZSBidW5kbGVkIFtsb2NhbC13ZWJdKGxvY2FsLXdlYikgc2tpbGwgaXMg
  >> "!B64TMP!" echo YWxzbyBNUEwtMi4wLgoKLSBbKipTZWFyWE5HKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9zZWFyeG5n
  >> "!B64TMP!" echo L3NlYXJ4bmcpIOKAlCBBR1BMLTMuMCwgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5n
  >> "!B64TMP!" echo aW5lLgotIFsqKkZpcmVjcmF3bCoqXShodHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVj
  >> "!B64TMP!" echo cmF3bCkg4oCUIEFHUEwtMy4wLCB0aGUgY29udGV4dCBBUEkgZm9yIHdlYiBzY3JhcGluZy9jcmF3
  >> "!B64TMP!" echo bGluZy9zZWFyY2guCi0gWyoqRmlyZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIu
  >> "!B64TMP!" echo Y29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikg4oCUIE1JVC4KLSBUaGUgdXBzdHJl
  >> "!B64TMP!" echo YW0gcHJvamVjdHMgcmV0YWluIHRoZWlyIG93biBsaWNlbnNlcyDigJQgcGxlYXNlIHJlc3BlY3Qg
  >> "!B64TMP!" echo dGhlbS4KICBOb3RoaW5nIGZyb20gdGhlbSBpcyBidW5kbGVkIGluIHRoaXMgcmVwb3NpdG9yeTsg
  >> "!B64TMP!" echo dGhlIGluc3RhbGxlciBvbmx5IHB1bGxzCiAgdGhlaXIgb2ZmaWNpYWwgY29udGFpbmVyIGltYWdl
  >> "!B64TMP!" echo cyBhdCBpbnN0YWxsIHRpbWUuCgotLS0KCjxzdWI+QnVpbHQgc28gYW55IGxvY2FsIG1vZGVsIOKA
  >> "!B64TMP!" echo lCBpbiBMTSBTdHVkaW8gb3Igb3RoZXJ3aXNlIOKAlCBjYW4gc2VhcmNoIGFuZCByZWFkCnRoZSB3
  >> "!B64TMP!" echo ZWIgd2l0aG91dCBhIHBhaWQgQVBJIGtleS4gQ29udHJpYnV0aW9ucyB3ZWxjb21lLjwvc3ViPgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\README.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- LICENSE ---
set "NEED_B64=1"
if exist "!SRC!\LICENSE" (
  copy /Y "!SRC!\LICENSE" "!TARGET!\LICENSE" >nul 2>&1
  if exist "!TARGET!\LICENSE" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] LICENSE  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1747782147.b64"
  > "!B64TMP!" echo TW96aWxsYSBQdWJsaWMgTGljZW5zZSBWZXJzaW9uIDIuMAo9PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09CgoxLiBEZWZpbml0aW9ucwotLS0tLS0tLS0tLS0tLQoKMS4xLiAiQ29udHJp
  >> "!B64TMP!" echo YnV0b3IiCiAgICBtZWFucyBlYWNoIGluZGl2aWR1YWwgb3IgbGVnYWwgZW50aXR5IHRoYXQgY3Jl
  >> "!B64TMP!" echo YXRlcywgY29udHJpYnV0ZXMgdG8KICAgIHRoZSBjcmVhdGlvbiBvZiwgb3Igb3ducyBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlLgoKMS4yLiAiQ29udHJpYnV0b3IgVmVyc2lvbiIKICAgIG1lYW5zIHRoZSBjb21i
  >> "!B64TMP!" echo aW5hdGlvbiBvZiB0aGUgQ29udHJpYnV0aW9ucyBvZiBvdGhlcnMgKGlmIGFueSkgdXNlZAogICAg
  >> "!B64TMP!" echo YnkgYSBDb250cmlidXRvciBhbmQgdGhhdCBwYXJ0aWN1bGFyIENvbnRyaWJ1dG9yJ3MgQ29udHJp
  >> "!B64TMP!" echo YnV0aW9uLgoKMS4zLiAiQ29udHJpYnV0aW9uIgogICAgbWVhbnMgQ292ZXJlZCBTb2Z0d2FyZSBv
  >> "!B64TMP!" echo ZiBhIHBhcnRpY3VsYXIgQ29udHJpYnV0b3IuCgoxLjQuICJDb3ZlcmVkIFNvZnR3YXJlIgogICAg
  >> "!B64TMP!" echo bWVhbnMgU291cmNlIENvZGUgRm9ybSB0byB3aGljaCB0aGUgaW5pdGlhbCBDb250cmlidXRvciBo
  >> "!B64TMP!" echo YXMgYXR0YWNoZWQKICAgIHRoZSBub3RpY2UgaW4gRXhoaWJpdCBBLCB0aGUgRXhlY3V0YWJsZSBG
  >> "!B64TMP!" echo b3JtIG9mIHN1Y2ggU291cmNlIENvZGUKICAgIEZvcm0sIGFuZCBNb2RpZmljYXRpb25zIG9mIHN1
  >> "!B64TMP!" echo Y2ggU291cmNlIENvZGUgRm9ybSwgaW4gZWFjaCBjYXNlCiAgICBpbmNsdWRpbmcgcG9ydGlvbnMg
  >> "!B64TMP!" echo dGhlcmVvZi4KCjEuNS4gIkluY29tcGF0aWJsZSBXaXRoIFNlY29uZGFyeSBMaWNlbnNlcyIKICAg
  >> "!B64TMP!" echo IG1lYW5zCgogICAgKGEpIHRoYXQgdGhlIGluaXRpYWwgQ29udHJpYnV0b3IgaGFzIGF0dGFjaGVk
  >> "!B64TMP!" echo IHRoZSBub3RpY2UgZGVzY3JpYmVkCiAgICAgICAgaW4gRXhoaWJpdCBCIHRvIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlOyBvcgoKICAgIChiKSB0aGF0IHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHdhcyBtYWRl
  >> "!B64TMP!" echo IGF2YWlsYWJsZSB1bmRlciB0aGUgdGVybXMgb2YKICAgICAgICB2ZXJzaW9uIDEuMSBvciBlYXJs
  >> "!B64TMP!" echo aWVyIG9mIHRoZSBMaWNlbnNlLCBidXQgbm90IGFsc28gdW5kZXIgdGhlCiAgICAgICAgdGVybXMg
  >> "!B64TMP!" echo b2YgYSBTZWNvbmRhcnkgTGljZW5zZS4KCjEuNi4gIkV4ZWN1dGFibGUgRm9ybSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IGFueSBmb3JtIG9mIHRoZSB3b3JrIG90aGVyIHRoYW4gU291cmNlIENvZGUgRm9ybS4KCjEuNy4g
  >> "!B64TMP!" echo IkxhcmdlciBXb3JrIgogICAgbWVhbnMgYSB3b3JrIHRoYXQgY29tYmluZXMgQ292ZXJlZCBTb2Z0
  >> "!B64TMP!" echo d2FyZSB3aXRoIG90aGVyIG1hdGVyaWFsLCBpbgogICAgYSBzZXBhcmF0ZSBmaWxlIG9yIGZpbGVz
  >> "!B64TMP!" echo LCB0aGF0IGlzIG5vdCBDb3ZlcmVkIFNvZnR3YXJlLgoKMS44LiAiTGljZW5zZSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IHRoaXMgZG9jdW1lbnQuCgoxLjkuICJMaWNlbnNhYmxlIgogICAgbWVhbnMgaGF2aW5nIHRoZSBy
  >> "!B64TMP!" echo aWdodCB0byBncmFudCwgdG8gdGhlIG1heGltdW0gZXh0ZW50IHBvc3NpYmxlLAogICAgd2hldGhl
  >> "!B64TMP!" echo ciBhdCB0aGUgdGltZSBvZiB0aGUgaW5pdGlhbCBncmFudCBvciBzdWJzZXF1ZW50bHksIGFueSBh
  >> "!B64TMP!" echo bmQKICAgIGFsbCBvZiB0aGUgcmlnaHRzIGNvbnZleWVkIGJ5IHRoaXMgTGljZW5zZS4KCjEuMTAu
  >> "!B64TMP!" echo ICJNb2RpZmljYXRpb25zIgogICAgbWVhbnMgYW55IG9mIHRoZSBmb2xsb3dpbmc6CgogICAgKGEp
  >> "!B64TMP!" echo IGFueSBmaWxlIGluIFNvdXJjZSBDb2RlIEZvcm0gdGhhdCByZXN1bHRzIGZyb20gYW4gYWRkaXRp
  >> "!B64TMP!" echo b24gdG8sCiAgICAgICAgZGVsZXRpb24gZnJvbSwgb3IgbW9kaWZpY2F0aW9uIG9mIHRoZSBjb250
  >> "!B64TMP!" echo ZW50cyBvZiBDb3ZlcmVkCiAgICAgICAgU29mdHdhcmU7IG9yCgogICAgKGIpIGFueSBuZXcgZmls
  >> "!B64TMP!" echo ZSBpbiBTb3VyY2UgQ29kZSBGb3JtIHRoYXQgY29udGFpbnMgYW55IENvdmVyZWQKICAgICAgICBT
  >> "!B64TMP!" echo b2Z0d2FyZS4KCjEuMTEuICJQYXRlbnQgQ2xhaW1zIiBvZiBhIENvbnRyaWJ1dG9yCiAgICBtZWFu
  >> "!B64TMP!" echo cyBhbnkgcGF0ZW50IGNsYWltKHMpLCBpbmNsdWRpbmcgd2l0aG91dCBsaW1pdGF0aW9uLCBtZXRo
  >> "!B64TMP!" echo b2QsCiAgICBwcm9jZXNzLCBhbmQgYXBwYXJhdHVzIGNsYWltcywgaW4gYW55IHBhdGVudCBMaWNl
  >> "!B64TMP!" echo bnNhYmxlIGJ5IHN1Y2gKICAgIENvbnRyaWJ1dG9yIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkLCBi
  >> "!B64TMP!" echo dXQgZm9yIHRoZSBncmFudCBvZiB0aGUKICAgIExpY2Vuc2UsIGJ5IHRoZSBtYWtpbmcsIHVzaW5n
  >> "!B64TMP!" echo LCBzZWxsaW5nLCBvZmZlcmluZyBmb3Igc2FsZSwgaGF2aW5nCiAgICBtYWRlLCBpbXBvcnQsIG9y
  >> "!B64TMP!" echo IHRyYW5zZmVyIG9mIGVpdGhlciBpdHMgQ29udHJpYnV0aW9ucyBvciBpdHMKICAgIENvbnRyaWJ1
  >> "!B64TMP!" echo dG9yIFZlcnNpb24uCgoxLjEyLiAiU2Vjb25kYXJ5IExpY2Vuc2UiCiAgICBtZWFucyBlaXRoZXIg
  >> "!B64TMP!" echo dGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlLCBWZXJzaW9uIDIuMCwgdGhlIEdOVQogICAg
  >> "!B64TMP!" echo TGVzc2VyIEdlbmVyYWwgUHVibGljIExpY2Vuc2UsIFZlcnNpb24gMi4xLCB0aGUgR05VIEFmZmVy
  >> "!B64TMP!" echo byBHZW5lcmFsCiAgICBQdWJsaWMgTGljZW5zZSwgVmVyc2lvbiAzLjAsIG9yIGFueSBsYXRlciB2
  >> "!B64TMP!" echo ZXJzaW9ucyBvZiB0aG9zZQogICAgbGljZW5zZXMuCgoxLjEzLiAiU291cmNlIENvZGUgRm9ybSIK
  >> "!B64TMP!" echo ICAgIG1lYW5zIHRoZSBmb3JtIG9mIHRoZSB3b3JrIHByZWZlcnJlZCBmb3IgbWFraW5nIG1vZGlm
  >> "!B64TMP!" echo aWNhdGlvbnMuCgoxLjE0LiAiWW91IiAob3IgIllvdXIiKQogICAgbWVhbnMgYW4gaW5kaXZpZHVh
  >> "!B64TMP!" echo bCBvciBhIGxlZ2FsIGVudGl0eSBleGVyY2lzaW5nIHJpZ2h0cyB1bmRlciB0aGlzCiAgICBMaWNl
  >> "!B64TMP!" echo bnNlLiBGb3IgbGVnYWwgZW50aXRpZXMsICJZb3UiIGluY2x1ZGVzIGFueSBlbnRpdHkgdGhhdAog
  >> "!B64TMP!" echo ICAgY29udHJvbHMsIGlzIGNvbnRyb2xsZWQgYnksIG9yIGlzIHVuZGVyIGNvbW1vbiBjb250cm9s
  >> "!B64TMP!" echo IHdpdGggWW91LiBGb3IKICAgIHB1cnBvc2VzIG9mIHRoaXMgZGVmaW5pdGlvbiwgImNvbnRyb2wi
  >> "!B64TMP!" echo IG1lYW5zIChhKSB0aGUgcG93ZXIsIGRpcmVjdAogICAgb3IgaW5kaXJlY3QsIHRvIGNhdXNlIHRo
  >> "!B64TMP!" echo ZSBkaXJlY3Rpb24gb3IgbWFuYWdlbWVudCBvZiBzdWNoIGVudGl0eSwKICAgIHdoZXRoZXIgYnkg
  >> "!B64TMP!" echo Y29udHJhY3Qgb3Igb3RoZXJ3aXNlLCBvciAoYikgb3duZXJzaGlwIG9mIG1vcmUgdGhhbgogICAg
  >> "!B64TMP!" echo ZmlmdHkgcGVyY2VudCAoNTAlKSBvZiB0aGUgb3V0c3RhbmRpbmcgc2hhcmVzIG9yIGJlbmVmaWNp
  >> "!B64TMP!" echo YWwKICAgIG93bmVyc2hpcCBvZiBzdWNoIGVudGl0eS4KCjIuIExpY2Vuc2UgR3JhbnRzIGFuZCBD
  >> "!B64TMP!" echo b25kaXRpb25zCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgoyLjEuIEdyYW50cwoK
  >> "!B64TMP!" echo RWFjaCBDb250cmlidXRvciBoZXJlYnkgZ3JhbnRzIFlvdSBhIHdvcmxkLXdpZGUsIHJveWFsdHkt
  >> "!B64TMP!" echo ZnJlZSwKbm9uLWV4Y2x1c2l2ZSBsaWNlbnNlOgoKKGEpIHVuZGVyIGludGVsbGVjdHVhbCBwcm9w
  >> "!B64TMP!" echo ZXJ0eSByaWdodHMgKG90aGVyIHRoYW4gcGF0ZW50IG9yIHRyYWRlbWFyaykKICAgIExpY2Vuc2Fi
  >> "!B64TMP!" echo bGUgYnkgc3VjaCBDb250cmlidXRvciB0byB1c2UsIHJlcHJvZHVjZSwgbWFrZSBhdmFpbGFibGUs
  >> "!B64TMP!" echo CiAgICBtb2RpZnksIGRpc3BsYXksIHBlcmZvcm0sIGRpc3RyaWJ1dGUsIGFuZCBvdGhlcndpc2Ug
  >> "!B64TMP!" echo ZXhwbG9pdCBpdHMKICAgIENvbnRyaWJ1dGlvbnMsIGVpdGhlciBvbiBhbiB1bm1vZGlmaWVkIGJh
  >> "!B64TMP!" echo c2lzLCB3aXRoIE1vZGlmaWNhdGlvbnMsIG9yCiAgICBhcyBwYXJ0IG9mIGEgTGFyZ2VyIFdvcms7
  >> "!B64TMP!" echo IGFuZAoKKGIpIHVuZGVyIFBhdGVudCBDbGFpbXMgb2Ygc3VjaCBDb250cmlidXRvciB0byBtYWtl
  >> "!B64TMP!" echo LCB1c2UsIHNlbGwsIG9mZmVyCiAgICBmb3Igc2FsZSwgaGF2ZSBtYWRlLCBpbXBvcnQsIGFuZCBv
  >> "!B64TMP!" echo dGhlcndpc2UgdHJhbnNmZXIgZWl0aGVyIGl0cwogICAgQ29udHJpYnV0aW9ucyBvciBpdHMgQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgVmVyc2lvbi4KCjIuMi4gRWZmZWN0aXZlIERhdGUKClRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkIGluIFNlY3Rpb24gMi4xIHdpdGggcmVzcGVjdCB0byBhbnkgQ29udHJpYnV0aW9uCmJlY29t
  >> "!B64TMP!" echo ZSBlZmZlY3RpdmUgZm9yIGVhY2ggQ29udHJpYnV0aW9uIG9uIHRoZSBkYXRlIHRoZSBDb250cmli
  >> "!B64TMP!" echo dXRvciBmaXJzdApkaXN0cmlidXRlcyBzdWNoIENvbnRyaWJ1dGlvbi4KCjIuMy4gTGltaXRhdGlv
  >> "!B64TMP!" echo bnMgb24gR3JhbnQgU2NvcGUKClRoZSBsaWNlbnNlcyBncmFudGVkIGluIHRoaXMgU2VjdGlvbiAy
  >> "!B64TMP!" echo IGFyZSB0aGUgb25seSByaWdodHMgZ3JhbnRlZCB1bmRlcgp0aGlzIExpY2Vuc2UuIE5vIGFkZGl0
  >> "!B64TMP!" echo aW9uYWwgcmlnaHRzIG9yIGxpY2Vuc2VzIHdpbGwgYmUgaW1wbGllZCBmcm9tIHRoZQpkaXN0cmli
  >> "!B64TMP!" echo dXRpb24gb3IgbGljZW5zaW5nIG9mIENvdmVyZWQgU29mdHdhcmUgdW5kZXIgdGhpcyBMaWNlbnNl
  >> "!B64TMP!" echo LgpOb3R3aXRoc3RhbmRpbmcgU2VjdGlvbiAyLjEoYikgYWJvdmUsIG5vIHBhdGVudCBsaWNlbnNl
  >> "!B64TMP!" echo IGlzIGdyYW50ZWQgYnkgYQpDb250cmlidXRvcjoKCihhKSBmb3IgYW55IGNvZGUgdGhhdCBhIENv
  >> "!B64TMP!" echo bnRyaWJ1dG9yIGhhcyByZW1vdmVkIGZyb20gQ292ZXJlZCBTb2Z0d2FyZTsKICAgIG9yCgooYikg
  >> "!B64TMP!" echo Zm9yIGluZnJpbmdlbWVudHMgY2F1c2VkIGJ5OiAoaSkgWW91ciBhbmQgYW55IG90aGVyIHRoaXJk
  >> "!B64TMP!" echo IHBhcnR5J3MKICAgIG1vZGlmaWNhdGlvbnMgb2YgQ292ZXJlZCBTb2Z0d2FyZSwgb3IgKGlpKSB0
  >> "!B64TMP!" echo aGUgY29tYmluYXRpb24gb2YgaXRzCiAgICBDb250cmlidXRpb25zIHdpdGggb3RoZXIgc29mdHdh
  >> "!B64TMP!" echo cmUgKGV4Y2VwdCBhcyBwYXJ0IG9mIGl0cyBDb250cmlidXRvcgogICAgVmVyc2lvbik7IG9yCgoo
  >> "!B64TMP!" echo YykgdW5kZXIgUGF0ZW50IENsYWltcyBpbmZyaW5nZWQgYnkgQ292ZXJlZCBTb2Z0d2FyZSBpbiB0
  >> "!B64TMP!" echo aGUgYWJzZW5jZSBvZgogICAgaXRzIENvbnRyaWJ1dGlvbnMuCgpUaGlzIExpY2Vuc2UgZG9lcyBu
  >> "!B64TMP!" echo b3QgZ3JhbnQgYW55IHJpZ2h0cyBpbiB0aGUgdHJhZGVtYXJrcywgc2VydmljZSBtYXJrcywKb3Ig
  >> "!B64TMP!" echo bG9nb3Mgb2YgYW55IENvbnRyaWJ1dG9yIChleGNlcHQgYXMgbWF5IGJlIG5lY2Vzc2FyeSB0byBj
  >> "!B64TMP!" echo b21wbHkgd2l0aAp0aGUgbm90aWNlIHJlcXVpcmVtZW50cyBpbiBTZWN0aW9uIDMuNCkuCgoyLjQu
  >> "!B64TMP!" echo IFN1YnNlcXVlbnQgTGljZW5zZXMKCk5vIENvbnRyaWJ1dG9yIG1ha2VzIGFkZGl0aW9uYWwgZ3Jh
  >> "!B64TMP!" echo bnRzIGFzIGEgcmVzdWx0IG9mIFlvdXIgY2hvaWNlIHRvCmRpc3RyaWJ1dGUgdGhlIENvdmVyZWQg
  >> "!B64TMP!" echo U29mdHdhcmUgdW5kZXIgYSBzdWJzZXF1ZW50IHZlcnNpb24gb2YgdGhpcwpMaWNlbnNlIChzZWUg
  >> "!B64TMP!" echo U2VjdGlvbiAxMC4yKSBvciB1bmRlciB0aGUgdGVybXMgb2YgYSBTZWNvbmRhcnkgTGljZW5zZSAo
  >> "!B64TMP!" echo aWYKcGVybWl0dGVkIHVuZGVyIHRoZSB0ZXJtcyBvZiBTZWN0aW9uIDMuMykuCgoyLjUuIFJlcHJl
  >> "!B64TMP!" echo c2VudGF0aW9uCgpFYWNoIENvbnRyaWJ1dG9yIHJlcHJlc2VudHMgdGhhdCB0aGUgQ29udHJpYnV0
  >> "!B64TMP!" echo b3IgYmVsaWV2ZXMgaXRzCkNvbnRyaWJ1dGlvbnMgYXJlIGl0cyBvcmlnaW5hbCBjcmVhdGlvbihz
  >> "!B64TMP!" echo KSBvciBpdCBoYXMgc3VmZmljaWVudCByaWdodHMKdG8gZ3JhbnQgdGhlIHJpZ2h0cyB0byBpdHMg
  >> "!B64TMP!" echo Q29udHJpYnV0aW9ucyBjb252ZXllZCBieSB0aGlzIExpY2Vuc2UuCgoyLjYuIEZhaXIgVXNlCgpU
  >> "!B64TMP!" echo aGlzIExpY2Vuc2UgaXMgbm90IGludGVuZGVkIHRvIGxpbWl0IGFueSByaWdodHMgWW91IGhhdmUg
  >> "!B64TMP!" echo dW5kZXIKYXBwbGljYWJsZSBjb3B5cmlnaHQgZG9jdHJpbmVzIG9mIGZhaXIgdXNlLCBmYWlyIGRl
  >> "!B64TMP!" echo YWxpbmcsIG9yIG90aGVyCmVxdWl2YWxlbnRzLgoKMi43LiBDb25kaXRpb25zCgpTZWN0aW9ucyAz
  >> "!B64TMP!" echo LjEsIDMuMiwgMy4zLCBhbmQgMy40IGFyZSBjb25kaXRpb25zIG9mIHRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkCmluIFNlY3Rpb24gMi4xLgoKMy4gUmVzcG9uc2liaWxpdGllcwotLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tCgozLjEuIERpc3RyaWJ1dGlvbiBvZiBTb3VyY2UgRm9ybQoKQWxsIGRpc3RyaWJ1dGlvbiBv
  >> "!B64TMP!" echo ZiBDb3ZlcmVkIFNvZnR3YXJlIGluIFNvdXJjZSBDb2RlIEZvcm0sIGluY2x1ZGluZyBhbnkKTW9k
  >> "!B64TMP!" echo aWZpY2F0aW9ucyB0aGF0IFlvdSBjcmVhdGUgb3IgdG8gd2hpY2ggWW91IGNvbnRyaWJ1dGUsIG11
  >> "!B64TMP!" echo c3QgYmUgdW5kZXIKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZS4gWW91IG11c3QgaW5mb3JtIHJl
  >> "!B64TMP!" echo Y2lwaWVudHMgdGhhdCB0aGUgU291cmNlCkNvZGUgRm9ybSBvZiB0aGUgQ292ZXJlZCBTb2Z0d2Fy
  >> "!B64TMP!" echo ZSBpcyBnb3Zlcm5lZCBieSB0aGUgdGVybXMgb2YgdGhpcwpMaWNlbnNlLCBhbmQgaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2YgdGhpcyBMaWNlbnNlLiBZb3UgbWF5IG5vdAphdHRlbXB0IHRv
  >> "!B64TMP!" echo IGFsdGVyIG9yIHJlc3RyaWN0IHRoZSByZWNpcGllbnRzJyByaWdodHMgaW4gdGhlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlCkZvcm0uCgozLjIuIERpc3RyaWJ1dGlvbiBvZiBFeGVjdXRhYmxlIEZvcm0KCklmIFlvdSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIENvdmVyZWQgU29mdHdhcmUgaW4gRXhlY3V0YWJsZSBGb3JtIHRoZW46CgooYSkg
  >> "!B64TMP!" echo c3VjaCBDb3ZlcmVkIFNvZnR3YXJlIG11c3QgYWxzbyBiZSBtYWRlIGF2YWlsYWJsZSBpbiBTb3Vy
  >> "!B64TMP!" echo Y2UgQ29kZQogICAgRm9ybSwgYXMgZGVzY3JpYmVkIGluIFNlY3Rpb24gMy4xLCBhbmQgWW91IG11
  >> "!B64TMP!" echo c3QgaW5mb3JtIHJlY2lwaWVudHMgb2YKICAgIHRoZSBFeGVjdXRhYmxlIEZvcm0gaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2Ygc3VjaCBTb3VyY2UgQ29kZQogICAgRm9ybSBieSByZWFzb25h
  >> "!B64TMP!" echo YmxlIG1lYW5zIGluIGEgdGltZWx5IG1hbm5lciwgYXQgYSBjaGFyZ2Ugbm8gbW9yZQogICAgdGhh
  >> "!B64TMP!" echo biB0aGUgY29zdCBvZiBkaXN0cmlidXRpb24gdG8gdGhlIHJlY2lwaWVudDsgYW5kCgooYikgWW91
  >> "!B64TMP!" echo IG1heSBkaXN0cmlidXRlIHN1Y2ggRXhlY3V0YWJsZSBGb3JtIHVuZGVyIHRoZSB0ZXJtcyBvZiB0
  >> "!B64TMP!" echo aGlzCiAgICBMaWNlbnNlLCBvciBzdWJsaWNlbnNlIGl0IHVuZGVyIGRpZmZlcmVudCB0ZXJtcywg
  >> "!B64TMP!" echo cHJvdmlkZWQgdGhhdCB0aGUKICAgIGxpY2Vuc2UgZm9yIHRoZSBFeGVjdXRhYmxlIEZvcm0gZG9l
  >> "!B64TMP!" echo cyBub3QgYXR0ZW1wdCB0byBsaW1pdCBvciBhbHRlcgogICAgdGhlIHJlY2lwaWVudHMnIHJpZ2h0
  >> "!B64TMP!" echo cyBpbiB0aGUgU291cmNlIENvZGUgRm9ybSB1bmRlciB0aGlzIExpY2Vuc2UuCgozLjMuIERpc3Ry
  >> "!B64TMP!" echo aWJ1dGlvbiBvZiBhIExhcmdlciBXb3JrCgpZb3UgbWF5IGNyZWF0ZSBhbmQgZGlzdHJpYnV0ZSBh
  >> "!B64TMP!" echo IExhcmdlciBXb3JrIHVuZGVyIHRlcm1zIG9mIFlvdXIgY2hvaWNlLApwcm92aWRlZCB0aGF0IFlv
  >> "!B64TMP!" echo dSBhbHNvIGNvbXBseSB3aXRoIHRoZSByZXF1aXJlbWVudHMgb2YgdGhpcyBMaWNlbnNlIGZvcgp0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZS4gSWYgdGhlIExhcmdlciBXb3JrIGlzIGEgY29tYmluYXRpb24g
  >> "!B64TMP!" echo b2YgQ292ZXJlZApTb2Z0d2FyZSB3aXRoIGEgd29yayBnb3Zlcm5lZCBieSBvbmUgb3IgbW9yZSBT
  >> "!B64TMP!" echo ZWNvbmRhcnkgTGljZW5zZXMsIGFuZCB0aGUKQ292ZXJlZCBTb2Z0d2FyZSBpcyBub3QgSW5jb21w
  >> "!B64TMP!" echo YXRpYmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzLCB0aGlzCkxpY2Vuc2UgcGVybWl0cyBZb3Ug
  >> "!B64TMP!" echo dG8gYWRkaXRpb25hbGx5IGRpc3RyaWJ1dGUgc3VjaCBDb3ZlcmVkIFNvZnR3YXJlCnVuZGVyIHRo
  >> "!B64TMP!" echo ZSB0ZXJtcyBvZiBzdWNoIFNlY29uZGFyeSBMaWNlbnNlKHMpLCBzbyB0aGF0IHRoZSByZWNpcGll
  >> "!B64TMP!" echo bnQgb2YKdGhlIExhcmdlciBXb3JrIG1heSwgYXQgdGhlaXIgb3B0aW9uLCBmdXJ0aGVyIGRpc3Ry
  >> "!B64TMP!" echo aWJ1dGUgdGhlIENvdmVyZWQKU29mdHdhcmUgdW5kZXIgdGhlIHRlcm1zIG9mIGVpdGhlciB0aGlz
  >> "!B64TMP!" echo IExpY2Vuc2Ugb3Igc3VjaCBTZWNvbmRhcnkKTGljZW5zZShzKS4KCjMuNC4gTm90aWNlcwoKWW91
  >> "!B64TMP!" echo IG1heSBub3QgcmVtb3ZlIG9yIGFsdGVyIHRoZSBzdWJzdGFuY2Ugb2YgYW55IGxpY2Vuc2Ugbm90
  >> "!B64TMP!" echo aWNlcwooaW5jbHVkaW5nIGNvcHlyaWdodCBub3RpY2VzLCBwYXRlbnQgbm90aWNlcywgZGlzY2xh
  >> "!B64TMP!" echo aW1lcnMgb2Ygd2FycmFudHksCm9yIGxpbWl0YXRpb25zIG9mIGxpYWJpbGl0eSkgY29udGFpbmVk
  >> "!B64TMP!" echo IHdpdGhpbiB0aGUgU291cmNlIENvZGUgRm9ybSBvZgp0aGUgQ292ZXJlZCBTb2Z0d2FyZSwgZXhj
  >> "!B64TMP!" echo ZXB0IHRoYXQgWW91IG1heSBhbHRlciBhbnkgbGljZW5zZSBub3RpY2VzIHRvCnRoZSBleHRlbnQg
  >> "!B64TMP!" echo cmVxdWlyZWQgdG8gcmVtZWR5IGtub3duIGZhY3R1YWwgaW5hY2N1cmFjaWVzLgoKMy41LiBBcHBs
  >> "!B64TMP!" echo aWNhdGlvbiBvZiBBZGRpdGlvbmFsIFRlcm1zCgpZb3UgbWF5IGNob29zZSB0byBvZmZlciwgYW5k
  >> "!B64TMP!" echo IHRvIGNoYXJnZSBhIGZlZSBmb3IsIHdhcnJhbnR5LCBzdXBwb3J0LAppbmRlbW5pdHkgb3IgbGlh
  >> "!B64TMP!" echo YmlsaXR5IG9ibGlnYXRpb25zIHRvIG9uZSBvciBtb3JlIHJlY2lwaWVudHMgb2YgQ292ZXJlZApT
  >> "!B64TMP!" echo b2Z0d2FyZS4gSG93ZXZlciwgWW91IG1heSBkbyBzbyBvbmx5IG9uIFlvdXIgb3duIGJlaGFsZiwg
  >> "!B64TMP!" echo YW5kIG5vdCBvbgpiZWhhbGYgb2YgYW55IENvbnRyaWJ1dG9yLiBZb3UgbXVzdCBtYWtlIGl0IGFi
  >> "!B64TMP!" echo c29sdXRlbHkgY2xlYXIgdGhhdCBhbnkKc3VjaCB3YXJyYW50eSwgc3VwcG9ydCwgaW5kZW1uaXR5
  >> "!B64TMP!" echo LCBvciBsaWFiaWxpdHkgb2JsaWdhdGlvbiBpcyBvZmZlcmVkIGJ5CllvdSBhbG9uZSwgYW5kIFlv
  >> "!B64TMP!" echo dSBoZXJlYnkgYWdyZWUgdG8gaW5kZW1uaWZ5IGV2ZXJ5IENvbnRyaWJ1dG9yIGZvciBhbnkKbGlh
  >> "!B64TMP!" echo YmlsaXR5IGluY3VycmVkIGJ5IHN1Y2ggQ29udHJpYnV0b3IgYXMgYSByZXN1bHQgb2Ygd2FycmFu
  >> "!B64TMP!" echo dHksIHN1cHBvcnQsCmluZGVtbml0eSBvciBsaWFiaWxpdHkgdGVybXMgWW91IG9mZmVyLiBZb3Ug
  >> "!B64TMP!" echo bWF5IGluY2x1ZGUgYWRkaXRpb25hbApkaXNjbGFpbWVycyBvZiB3YXJyYW50eSBhbmQgbGltaXRh
  >> "!B64TMP!" echo dGlvbnMgb2YgbGlhYmlsaXR5IHNwZWNpZmljIHRvIGFueQpqdXJpc2RpY3Rpb24uCgo0LiBJbmFi
  >> "!B64TMP!" echo aWxpdHkgdG8gQ29tcGx5IER1ZSB0byBTdGF0dXRlIG9yIFJlZ3VsYXRpb24KLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpJZiBpdCBpcyBpbXBvc3Np
  >> "!B64TMP!" echo YmxlIGZvciBZb3UgdG8gY29tcGx5IHdpdGggYW55IG9mIHRoZSB0ZXJtcyBvZiB0aGlzCkxpY2Vu
  >> "!B64TMP!" echo c2Ugd2l0aCByZXNwZWN0IHRvIHNvbWUgb3IgYWxsIG9mIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIGR1
  >> "!B64TMP!" echo ZSB0bwpzdGF0dXRlLCBqdWRpY2lhbCBvcmRlciwgb3IgcmVndWxhdGlvbiB0aGVuIFlvdSBtdXN0
  >> "!B64TMP!" echo OiAoYSkgY29tcGx5IHdpdGgKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZSB0byB0aGUgbWF4aW11
  >> "!B64TMP!" echo bSBleHRlbnQgcG9zc2libGU7IGFuZCAoYikKZGVzY3JpYmUgdGhlIGxpbWl0YXRpb25zIGFuZCB0
  >> "!B64TMP!" echo aGUgY29kZSB0aGV5IGFmZmVjdC4gU3VjaCBkZXNjcmlwdGlvbiBtdXN0CmJlIHBsYWNlZCBpbiBh
  >> "!B64TMP!" echo IHRleHQgZmlsZSBpbmNsdWRlZCB3aXRoIGFsbCBkaXN0cmlidXRpb25zIG9mIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo ClNvZnR3YXJlIHVuZGVyIHRoaXMgTGljZW5zZS4gRXhjZXB0IHRvIHRoZSBleHRlbnQgcHJvaGli
  >> "!B64TMP!" echo aXRlZCBieSBzdGF0dXRlCm9yIHJlZ3VsYXRpb24sIHN1Y2ggZGVzY3JpcHRpb24gbXVzdCBiZSBz
  >> "!B64TMP!" echo dWZmaWNpZW50bHkgZGV0YWlsZWQgZm9yIGEKcmVjaXBpZW50IG9mIG9yZGluYXJ5IHNraWxsIHRv
  >> "!B64TMP!" echo IGJlIGFibGUgdG8gdW5kZXJzdGFuZCBpdC4KCjUuIFRlcm1pbmF0aW9uCi0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo Cgo1LjEuIFRoZSByaWdodHMgZ3JhbnRlZCB1bmRlciB0aGlzIExpY2Vuc2Ugd2lsbCB0ZXJtaW5h
  >> "!B64TMP!" echo dGUgYXV0b21hdGljYWxseQppZiBZb3UgZmFpbCB0byBjb21wbHkgd2l0aCBhbnkgb2YgaXRzIHRl
  >> "!B64TMP!" echo cm1zLiBIb3dldmVyLCBpZiBZb3UgYmVjb21lCmNvbXBsaWFudCwgdGhlbiB0aGUgcmlnaHRzIGdy
  >> "!B64TMP!" echo YW50ZWQgdW5kZXIgdGhpcyBMaWNlbnNlIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIChhKSBwcm92aXNpb25hbGx5LCB1bmxlc3MgYW5kIHVudGlsIHN1Y2gKQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgZXhwbGljaXRseSBhbmQgZmluYWxseSB0ZXJtaW5hdGVzIFlvdXIgZ3JhbnRzLCBh
  >> "!B64TMP!" echo bmQgKGIpIG9uIGFuCm9uZ29pbmcgYmFzaXMsIGlmIHN1Y2ggQ29udHJpYnV0b3IgZmFpbHMgdG8g
  >> "!B64TMP!" echo bm90aWZ5IFlvdSBvZiB0aGUKbm9uLWNvbXBsaWFuY2UgYnkgc29tZSByZWFzb25hYmxlIG1lYW5z
  >> "!B64TMP!" echo IHByaW9yIHRvIDYwIGRheXMgYWZ0ZXIgWW91IGhhdmUKY29tZSBiYWNrIGludG8gY29tcGxpYW5j
  >> "!B64TMP!" echo ZS4gTW9yZW92ZXIsIFlvdXIgZ3JhbnRzIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIG9uIGFuIG9uZ29pbmcgYmFzaXMgaWYgc3VjaCBDb250cmlidXRvcgpub3Rp
  >> "!B64TMP!" echo ZmllcyBZb3Ugb2YgdGhlIG5vbi1jb21wbGlhbmNlIGJ5IHNvbWUgcmVhc29uYWJsZSBtZWFucywg
  >> "!B64TMP!" echo dGhpcyBpcyB0aGUKZmlyc3QgdGltZSBZb3UgaGF2ZSByZWNlaXZlZCBub3RpY2Ugb2Ygbm9uLWNv
  >> "!B64TMP!" echo bXBsaWFuY2Ugd2l0aCB0aGlzIExpY2Vuc2UKZnJvbSBzdWNoIENvbnRyaWJ1dG9yLCBhbmQgWW91
  >> "!B64TMP!" echo IGJlY29tZSBjb21wbGlhbnQgcHJpb3IgdG8gMzAgZGF5cyBhZnRlcgpZb3VyIHJlY2VpcHQgb2Yg
  >> "!B64TMP!" echo dGhlIG5vdGljZS4KCjUuMi4gSWYgWW91IGluaXRpYXRlIGxpdGlnYXRpb24gYWdhaW5zdCBhbnkg
  >> "!B64TMP!" echo ZW50aXR5IGJ5IGFzc2VydGluZyBhIHBhdGVudAppbmZyaW5nZW1lbnQgY2xhaW0gKGV4Y2x1ZGlu
  >> "!B64TMP!" echo ZyBkZWNsYXJhdG9yeSBqdWRnbWVudCBhY3Rpb25zLApjb3VudGVyLWNsYWltcywgYW5kIGNyb3Nz
  >> "!B64TMP!" echo LWNsYWltcykgYWxsZWdpbmcgdGhhdCBhIENvbnRyaWJ1dG9yIFZlcnNpb24KZGlyZWN0bHkgb3Ig
  >> "!B64TMP!" echo aW5kaXJlY3RseSBpbmZyaW5nZXMgYW55IHBhdGVudCwgdGhlbiB0aGUgcmlnaHRzIGdyYW50ZWQg
  >> "!B64TMP!" echo dG8KWW91IGJ5IGFueSBhbmQgYWxsIENvbnRyaWJ1dG9ycyBmb3IgdGhlIENvdmVyZWQgU29mdHdh
  >> "!B64TMP!" echo cmUgdW5kZXIgU2VjdGlvbgoyLjEgb2YgdGhpcyBMaWNlbnNlIHNoYWxsIHRlcm1pbmF0ZS4KCjUu
  >> "!B64TMP!" echo My4gSW4gdGhlIGV2ZW50IG9mIHRlcm1pbmF0aW9uIHVuZGVyIFNlY3Rpb25zIDUuMSBvciA1LjIg
  >> "!B64TMP!" echo YWJvdmUsIGFsbAplbmQgdXNlciBsaWNlbnNlIGFncmVlbWVudHMgKGV4Y2x1ZGluZyBkaXN0cmli
  >> "!B64TMP!" echo dXRvcnMgYW5kIHJlc2VsbGVycykgd2hpY2gKaGF2ZSBiZWVuIHZhbGlkbHkgZ3JhbnRlZCBieSBZ
  >> "!B64TMP!" echo b3Ugb3IgWW91ciBkaXN0cmlidXRvcnMgdW5kZXIgdGhpcyBMaWNlbnNlCnByaW9yIHRvIHRlcm1p
  >> "!B64TMP!" echo bmF0aW9uIHNoYWxsIHN1cnZpdmUgdGVybWluYXRpb24uCgoqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioKKiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAqCiogIDYuIERpc2NsYWltZXIgb2YgV2FycmFudHkgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgKgoqICAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIENvdmVyZWQgU29mdHdhcmUgaXMgcHJvdmlkZWQgdW5kZXIgdGhpcyBMaWNlbnNlIG9uIGFu
  >> "!B64TMP!" echo ICJhcyBpcyIgICAgICAgKgoqICBiYXNpcywgd2l0aG91dCB3YXJyYW50eSBvZiBhbnkga2luZCwg
  >> "!B64TMP!" echo ZWl0aGVyIGV4cHJlc3NlZCwgaW1wbGllZCwgb3IgICoKKiAgc3RhdHV0b3J5LCBpbmNsdWRpbmcs
  >> "!B64TMP!" echo IHdpdGhvdXQgbGltaXRhdGlvbiwgd2FycmFudGllcyB0aGF0IHRoZSAgICAgICAqCiogIENvdmVy
  >> "!B64TMP!" echo ZWQgU29mdHdhcmUgaXMgZnJlZSBvZiBkZWZlY3RzLCBtZXJjaGFudGFibGUsIGZpdCBmb3IgYSAg
  >> "!B64TMP!" echo ICAgICAgKgoqICBwYXJ0aWN1bGFyIHB1cnBvc2Ugb3Igbm9uLWluZnJpbmdpbmcuIFRoZSBlbnRp
  >> "!B64TMP!" echo cmUgcmlzayBhcyB0byB0aGUgICAgICoKKiAgcXVhbGl0eSBhbmQgcGVyZm9ybWFuY2Ugb2YgdGhl
  >> "!B64TMP!" echo IENvdmVyZWQgU29mdHdhcmUgaXMgd2l0aCBZb3UuICAgICAgICAqCiogIFNob3VsZCBhbnkgQ292
  >> "!B64TMP!" echo ZXJlZCBTb2Z0d2FyZSBwcm92ZSBkZWZlY3RpdmUgaW4gYW55IHJlc3BlY3QsIFlvdSAgICAgKgoq
  >> "!B64TMP!" echo ICAobm90IGFueSBDb250cmlidXRvcikgYXNzdW1lIHRoZSBjb3N0IG9mIGFueSBuZWNlc3Nhcnkg
  >> "!B64TMP!" echo c2VydmljaW5nLCAgICoKKiAgcmVwYWlyLCBvciBjb3JyZWN0aW9uLiBUaGlzIGRpc2NsYWltZXIg
  >> "!B64TMP!" echo b2Ygd2FycmFudHkgY29uc3RpdHV0ZXMgYW4gICAqCiogIGVzc2VudGlhbCBwYXJ0IG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZS4gTm8gdXNlIG9mIGFueSBDb3ZlcmVkIFNvZnR3YXJlIGlzICAgKgoqICBhdXRob3Jp
  >> "!B64TMP!" echo emVkIHVuZGVyIHRoaXMgTGljZW5zZSBleGNlcHQgdW5kZXIgdGhpcyBkaXNjbGFpbWVyLiAgICAg
  >> "!B64TMP!" echo ICAgICoKKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAqCioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKgoKKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCiog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgKgoqICA3LiBMaW1pdGF0aW9uIG9mIExpYWJpbGl0eSAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAqCiogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgKgoqICBVbmRlciBubyBjaXJjdW1zdGFuY2VzIGFuZCB1bmRlciBubyBsZWdhbCB0aGVvcnks
  >> "!B64TMP!" echo IHdoZXRoZXIgdG9ydCAgICAgICoKKiAgKGluY2x1ZGluZyBuZWdsaWdlbmNlKSwgY29udHJhY3Qs
  >> "!B64TMP!" echo IG9yIG90aGVyd2lzZSwgc2hhbGwgYW55ICAgICAgICAgICAqCiogIENvbnRyaWJ1dG9yLCBvciBh
  >> "!B64TMP!" echo bnlvbmUgd2hvIGRpc3RyaWJ1dGVzIENvdmVyZWQgU29mdHdhcmUgYXMgICAgICAgICAgKgoqICBw
  >> "!B64TMP!" echo ZXJtaXR0ZWQgYWJvdmUsIGJlIGxpYWJsZSB0byBZb3UgZm9yIGFueSBkaXJlY3QsIGluZGlyZWN0
  >> "!B64TMP!" echo LCAgICAgICAgICoKKiAgc3BlY2lhbCwgaW5jaWRlbnRhbCwgb3IgY29uc2VxdWVudGlhbCBkYW1h
  >> "!B64TMP!" echo Z2VzIG9mIGFueSBjaGFyYWN0ZXIgICAgICAqCiogIGluY2x1ZGluZywgd2l0aG91dCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLCBkYW1hZ2VzIGZvciBsb3N0IHByb2ZpdHMsIGxvc3Mgb2YgICAgKgoqICBnb29kd2lsbCwg
  >> "!B64TMP!" echo d29yayBzdG9wcGFnZSwgY29tcHV0ZXIgZmFpbHVyZSBvciBtYWxmdW5jdGlvbiwgb3IgYW55ICAg
  >> "!B64TMP!" echo ICoKKiAgYW5kIGFsbCBvdGhlciBjb21tZXJjaWFsIGRhbWFnZXMgb3IgbG9zc2VzLCBldmVuIGlm
  >> "!B64TMP!" echo IHN1Y2ggcGFydHkgICAgICAqCiogIHNoYWxsIGhhdmUgYmVlbiBpbmZvcm1lZCBvZiB0aGUgcG9z
  >> "!B64TMP!" echo c2liaWxpdHkgb2Ygc3VjaCBkYW1hZ2VzLiBUaGlzICAgKgoqICBsaW1pdGF0aW9uIG9mIGxpYWJp
  >> "!B64TMP!" echo bGl0eSBzaGFsbCBub3QgYXBwbHkgdG8gbGlhYmlsaXR5IGZvciBkZWF0aCBvciAgICoKKiAgcGVy
  >> "!B64TMP!" echo c29uYWwgaW5qdXJ5IHJlc3VsdGluZyBmcm9tIHN1Y2ggcGFydHkncyBuZWdsaWdlbmNlIHRvIHRo
  >> "!B64TMP!" echo ZSAgICAgICAqCiogIGV4dGVudCBhcHBsaWNhYmxlIGxhdyBwcm9oaWJpdHMgc3VjaCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLiBTb21lICAgICAgICAgICAgICAgKgoqICBqdXJpc2RpY3Rpb25zIGRvIG5vdCBhbGxvdyB0
  >> "!B64TMP!" echo aGUgZXhjbHVzaW9uIG9yIGxpbWl0YXRpb24gb2YgICAgICAgICAgICoKKiAgaW5jaWRlbnRhbCBv
  >> "!B64TMP!" echo ciBjb25zZXF1ZW50aWFsIGRhbWFnZXMsIHNvIHRoaXMgZXhjbHVzaW9uIGFuZCAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIGxpbWl0YXRpb24gbWF5IG5vdCBhcHBseSB0byBZb3UuICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgKgoqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCgo4LiBMaXRp
  >> "!B64TMP!" echo Z2F0aW9uCi0tLS0tLS0tLS0tLS0KCkFueSBsaXRpZ2F0aW9uIHJlbGF0aW5nIHRvIHRoaXMgTGlj
  >> "!B64TMP!" echo ZW5zZSBtYXkgYmUgYnJvdWdodCBvbmx5IGluIHRoZQpjb3VydHMgb2YgYSBqdXJpc2RpY3Rpb24g
  >> "!B64TMP!" echo d2hlcmUgdGhlIGRlZmVuZGFudCBtYWludGFpbnMgaXRzIHByaW5jaXBhbApwbGFjZSBvZiBidXNp
  >> "!B64TMP!" echo bmVzcyBhbmQgc3VjaCBsaXRpZ2F0aW9uIHNoYWxsIGJlIGdvdmVybmVkIGJ5IGxhd3Mgb2YgdGhh
  >> "!B64TMP!" echo dApqdXJpc2RpY3Rpb24sIHdpdGhvdXQgcmVmZXJlbmNlIHRvIGl0cyBjb25mbGljdC1vZi1sYXcg
  >> "!B64TMP!" echo cHJvdmlzaW9ucy4KTm90aGluZyBpbiB0aGlzIFNlY3Rpb24gc2hhbGwgcHJldmVudCBhIHBhcnR5
  >> "!B64TMP!" echo J3MgYWJpbGl0eSB0byBicmluZwpjcm9zcy1jbGFpbXMgb3IgY291bnRlci1jbGFpbXMuCgo5LiBN
  >> "!B64TMP!" echo aXNjZWxsYW5lb3VzCi0tLS0tLS0tLS0tLS0tLS0KClRoaXMgTGljZW5zZSByZXByZXNlbnRzIHRo
  >> "!B64TMP!" echo ZSBjb21wbGV0ZSBhZ3JlZW1lbnQgY29uY2VybmluZyB0aGUgc3ViamVjdAptYXR0ZXIgaGVyZW9m
  >> "!B64TMP!" echo LiBJZiBhbnkgcHJvdmlzaW9uIG9mIHRoaXMgTGljZW5zZSBpcyBoZWxkIHRvIGJlCnVuZW5mb3Jj
  >> "!B64TMP!" echo ZWFibGUsIHN1Y2ggcHJvdmlzaW9uIHNoYWxsIGJlIHJlZm9ybWVkIG9ubHkgdG8gdGhlIGV4dGVu
  >> "!B64TMP!" echo dApuZWNlc3NhcnkgdG8gbWFrZSBpdCBlbmZvcmNlYWJsZS4gQW55IGxhdyBvciByZWd1bGF0aW9u
  >> "!B64TMP!" echo IHdoaWNoIHByb3ZpZGVzCnRoYXQgdGhlIGxhbmd1YWdlIG9mIGEgY29udHJhY3Qgc2hhbGwgYmUg
  >> "!B64TMP!" echo Y29uc3RydWVkIGFnYWluc3QgdGhlIGRyYWZ0ZXIKc2hhbGwgbm90IGJlIHVzZWQgdG8gY29uc3Ry
  >> "!B64TMP!" echo dWUgdGhpcyBMaWNlbnNlIGFnYWluc3QgYSBDb250cmlidXRvci4KCjEwLiBWZXJzaW9ucyBvZiB0
  >> "!B64TMP!" echo aGUgTGljZW5zZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCjEwLjEuIE5ldyBWZXJzaW9u
  >> "!B64TMP!" echo cwoKTW96aWxsYSBGb3VuZGF0aW9uIGlzIHRoZSBsaWNlbnNlIHN0ZXdhcmQuIEV4Y2VwdCBhcyBw
  >> "!B64TMP!" echo cm92aWRlZCBpbiBTZWN0aW9uCjEwLjMsIG5vIG9uZSBvdGhlciB0aGFuIHRoZSBsaWNlbnNlIHN0
  >> "!B64TMP!" echo ZXdhcmQgaGFzIHRoZSByaWdodCB0byBtb2RpZnkgb3IKcHVibGlzaCBuZXcgdmVyc2lvbnMgb2Yg
  >> "!B64TMP!" echo dGhpcyBMaWNlbnNlLiBFYWNoIHZlcnNpb24gd2lsbCBiZSBnaXZlbiBhCmRpc3Rpbmd1aXNoaW5n
  >> "!B64TMP!" echo IHZlcnNpb24gbnVtYmVyLgoKMTAuMi4gRWZmZWN0IG9mIE5ldyBWZXJzaW9ucwoKWW91IG1heSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHVuZGVyIHRoZSB0ZXJtcyBvZiB0aGUgdmVy
  >> "!B64TMP!" echo c2lvbgpvZiB0aGUgTGljZW5zZSB1bmRlciB3aGljaCBZb3Ugb3JpZ2luYWxseSByZWNlaXZlZCB0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZSwKb3IgdW5kZXIgdGhlIHRlcm1zIG9mIGFueSBzdWJzZXF1ZW50
  >> "!B64TMP!" echo IHZlcnNpb24gcHVibGlzaGVkIGJ5IHRoZSBsaWNlbnNlCnN0ZXdhcmQuCgoxMC4zLiBNb2RpZmll
  >> "!B64TMP!" echo ZCBWZXJzaW9ucwoKSWYgeW91IGNyZWF0ZSBzb2Z0d2FyZSBub3QgZ292ZXJuZWQgYnkgdGhpcyBM
  >> "!B64TMP!" echo aWNlbnNlLCBhbmQgeW91IHdhbnQgdG8KY3JlYXRlIGEgbmV3IGxpY2Vuc2UgZm9yIHN1Y2ggc29m
  >> "!B64TMP!" echo dHdhcmUsIHlvdSBtYXkgY3JlYXRlIGFuZCB1c2UgYQptb2RpZmllZCB2ZXJzaW9uIG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZSBpZiB5b3UgcmVuYW1lIHRoZSBsaWNlbnNlIGFuZCByZW1vdmUKYW55IHJlZmVyZW5j
  >> "!B64TMP!" echo ZXMgdG8gdGhlIG5hbWUgb2YgdGhlIGxpY2Vuc2Ugc3Rld2FyZCAoZXhjZXB0IHRvIG5vdGUgdGhh
  >> "!B64TMP!" echo dApzdWNoIG1vZGlmaWVkIGxpY2Vuc2UgZGlmZmVycyBmcm9tIHRoaXMgTGljZW5zZSkuCgoxMC40
  >> "!B64TMP!" echo LiBEaXN0cmlidXRpbmcgU291cmNlIENvZGUgRm9ybSB0aGF0IGlzIEluY29tcGF0aWJsZSBXaXRo
  >> "!B64TMP!" echo IFNlY29uZGFyeQpMaWNlbnNlcwoKSWYgWW91IGNob29zZSB0byBkaXN0cmlidXRlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlIEZvcm0gdGhhdCBpcyBJbmNvbXBhdGlibGUgV2l0aApTZWNvbmRhcnkgTGljZW5zZXMgdW5k
  >> "!B64TMP!" echo ZXIgdGhlIHRlcm1zIG9mIHRoaXMgdmVyc2lvbiBvZiB0aGUgTGljZW5zZSwgdGhlCm5vdGljZSBk
  >> "!B64TMP!" echo ZXNjcmliZWQgaW4gRXhoaWJpdCBCIG9mIHRoaXMgTGljZW5zZSBtdXN0IGJlIGF0dGFjaGVkLgoK
  >> "!B64TMP!" echo RXhoaWJpdCBBIC0gU291cmNlIENvZGUgRm9ybSBMaWNlbnNlIE5vdGljZQotLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBp
  >> "!B64TMP!" echo cyBzdWJqZWN0IHRvIHRoZSB0ZXJtcyBvZiB0aGUgTW96aWxsYSBQdWJsaWMKICBMaWNlbnNlLCB2
  >> "!B64TMP!" echo LiAyLjAuIElmIGEgY29weSBvZiB0aGUgTVBMIHdhcyBub3QgZGlzdHJpYnV0ZWQgd2l0aCB0aGlz
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHA6Ly9tb3ppbGxhLm9yZy9NUEwvMi4w
  >> "!B64TMP!" echo Ly4KCklmIGl0IGlzIG5vdCBwb3NzaWJsZSBvciBkZXNpcmFibGUgdG8gcHV0IHRoZSBub3RpY2Ug
  >> "!B64TMP!" echo aW4gYSBwYXJ0aWN1bGFyCmZpbGUsIHRoZW4gWW91IG1heSBpbmNsdWRlIHRoZSBub3RpY2UgaW4g
  >> "!B64TMP!" echo YSBsb2NhdGlvbiAoc3VjaCBhcyBhIExJQ0VOU0UKZmlsZSBpbiBhIHJlbGV2YW50IGRpcmVjdG9y
  >> "!B64TMP!" echo eSkgd2hlcmUgYSByZWNpcGllbnQgd291bGQgYmUgbGlrZWx5IHRvIGxvb2sKZm9yIHN1Y2ggYSBu
  >> "!B64TMP!" echo b3RpY2UuCgpZb3UgbWF5IGFkZCBhZGRpdGlvbmFsIGFjY3VyYXRlIG5vdGljZXMgb2YgY29weXJp
  >> "!B64TMP!" echo Z2h0IG93bmVyc2hpcC4KCkV4aGliaXQgQiAtICJJbmNvbXBhdGlibGUgV2l0aCBTZWNvbmRhcnkg
  >> "!B64TMP!" echo TGljZW5zZXMiIE5vdGljZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KCiAgVGhpcyBTb3VyY2UgQ29kZSBGb3JtIGlzICJJbmNvbXBhdGli
  >> "!B64TMP!" echo bGUgV2l0aCBTZWNvbmRhcnkgTGljZW5zZXMiLCBhcwogIGRlZmluZWQgYnkgdGhlIE1vemlsbGEg
  >> "!B64TMP!" echo UHVibGljIExpY2Vuc2UsIHYuIDIuMC4KCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCk5PVEU6IFRoaXMgcHJvamVj
  >> "!B64TMP!" echo dCBpcyBjb25maWd1cmF0aW9uIGdsdWUgcGx1cyBhIHNtYWxsIGFnZW50IHNraWxsCihsb2NhbC13
  >> "!B64TMP!" echo ZWIpOyBpdCBidW5kbGVzIG5vIHVwc3RyZWFtIHNvdXJjZSBjb2RlLiBXaGVuIHlvdSBydW4gdGhl
  >> "!B64TMP!" echo Cmluc3RhbGxlciwgRG9ja2VyIHB1bGxzIHRoZSBvZmZpY2lhbCBpbWFnZXMgb2YgdGhlIGZvbGxv
  >> "!B64TMP!" echo d2luZwp0aGlyZC1wYXJ0eSBwcm9qZWN0cywgZWFjaCBnb3Zlcm5lZCBieSBpdHMgb3duIGxpY2Vu
  >> "!B64TMP!" echo c2U6CgogIC0gU2VhclhORyAgICAgICAgaHR0cHM6Ly9naXRodWIuY29tL3NlYXJ4bmcvc2Vhcnhu
  >> "!B64TMP!" echo ZyAgICAgICAgKEFHUEwtMy4wKQogIC0gRmlyZWNyYXdsICAgICAgaHR0cHM6Ly9naXRodWIuY29t
  >> "!B64TMP!" echo L2ZpcmVjcmF3bC9maXJlY3Jhd2wgICAoQUdQTC0zLjAKICAgICAgICAgICAgICAgICAgd2l0aCBh
  >> "!B64TMP!" echo IGNvbW1lcmNpYWwgb3B0aW9uIGZvciB0aGUgaG9zdGVkIHNlcnZpY2UpCiAgLSBSZWRpcyAgICAg
  >> "!B64TMP!" echo ICAgICBodHRwczovL3JlZGlzLmlvICAgICAgICAgICAgICAgICAgICAgICAgICAoUlNBTHYyL1NT
  >> "!B64TMP!" echo UEwpCiAgLSBQbGF5d3JpZ2h0ICAgICBodHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVj
  >> "!B64TMP!" echo cmF3bAogICAgICAgICAgICAgICAgICBwbGF5d3JpZ2h0LXNlcnZpY2UgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAoQUdQTC0zLjApCgpCeSB1c2luZyB0aGlzIGluc3RhbGxlciB5b3UgYWxzbyBhY2Nl
  >> "!B64TMP!" echo cHQgdGhlIGxpY2Vuc2VzIG9mIHRob3NlCnVwc3RyZWFtIHByb2plY3RzLgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\LICENSE"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitignore ---
set "NEED_B64=1"
if exist "!SRC!\.gitignore" (
  copy /Y "!SRC!\.gitignore" "!TARGET!\.gitignore" >nul 2>&1
  if exist "!TARGET!\.gitignore" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitignore  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3788869521.b64"
  > "!B64TMP!" echo IyAtLS0tIEdlbmVyYXRlZCBhdCBpbnN0YWxsIHRpbWUgKGNvbnRhaW5zIHlvdXIgcG9ydHMgYW5k
  >> "!B64TMP!" echo IHNlY3JldHMpIC0tLS0KLmVudgouZW52LmJhay4qCgojIC0tLS0gV3JpdHRlbiBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIGludG8gaW5zdGFsbGVkIHNraWxsIGNvcGllcyAtLS0tCiMgKHRoZSBzb3VyY2UgY29w
  >> "!B64TMP!" echo eSBpbiB0aGUgcmVwbyBtdXN0IHN0YXkgY2xlYW47IHRoZSBpbnN0YWxsZXIgcmVjb3JkcyB0aGUK
  >> "!B64TMP!" echo IyAgaW5zdGFsbCBwYXRoIGhlcmUgd2hlbiBpdCBjb3BpZXMgdGhlIHNraWxsIHRvIH4vLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMvbG9jYWwtd2ViKQpsb2NhbC13ZWIvaW5zdGFsbC1kaXIudHh0CgojIC0tLS0gUHl0
  >> "!B64TMP!" echo aG9uIGJ5dGVjb2RlIChza2lsbCBzY3JpcHRzKSAtLS0tCl9fcHljYWNoZV9fLwoqLnB5YwoKIyAt
  >> "!B64TMP!" echo LS0tIE9TIGp1bmsgLS0tLQouRFNfU3RvcmUKVGh1bWJzLmRiCmRlc2t0b3AuaW5pCgojIC0tLS0g
  >> "!B64TMP!" echo TG9ncyAtLS0tCioubG9nCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitignore"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitattributes ---
set "NEED_B64=1"
if exist "!SRC!\.gitattributes" (
  copy /Y "!SRC!\.gitattributes" "!TARGET!\.gitattributes" >nul 2>&1
  if exist "!TARGET!\.gitattributes" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitattributes  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2379549047.b64"
  > "!B64TMP!" echo IyBOb3JtYWxpemUgdGV4dCBmaWxlcyBpbiB0aGUgcmVwbzsga2VlcCBwbGF0Zm9ybS1uYXRpdmUg
  >> "!B64TMP!" echo bGluZSBlbmRpbmdzIG9uIGNoZWNrb3V0CiogdGV4dD1hdXRvCgojIFdpbmRvd3MgYmF0Y2ggZmls
  >> "!B64TMP!" echo ZXMgbXVzdCBrZWVwIENSTEYgd29ya2luZyBjb3BpZXMKKi5iYXQgdGV4dCBlb2w9Y3JsZgoqLmNt
  >> "!B64TMP!" echo ZCB0ZXh0IGVvbD1jcmxmCioucHMxIHRleHQgZW9sPWNybGYKCiMgVW5peCBzY3JpcHRzIG11c3Qg
  >> "!B64TMP!" echo c3RheSBMRgoqLnNoIHRleHQgZW9sPWxmCioucHkgdGV4dCBlb2w9bGYKKi55bWwgdGV4dCBlb2w9
  >> "!B64TMP!" echo bGYKKi55YW1sIHRleHQgZW9sPWxmCgojIERvY3MKKi5tZCB0ZXh0CkxJQ0VOU0UgdGV4dAo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitattributes"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Run.bat ---
set "NEED_B64=1"
if exist "!SRC!\Run.bat" (
  copy /Y "!SRC!\Run.bat" "!TARGET!\Run.bat" >nul 2>&1
  if exist "!TARGET!\Run.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Run.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1962629694.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFJ1bg0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJlIGRv
  >> "!B64TMP!" echo Y2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIg
  >> "!B64TMP!" echo aXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4gSW5zdGFsbCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlm
  >> "!B64TMP!" echo IGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5u
  >> "!B64TMP!" echo aW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBmaXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0KICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZv
  >> "!B64TMP!" echo dW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hvICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
  >> "!B64TMP!" echo dCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZpZ3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2Ig
  >> "!B64TMP!" echo MQ0KKQ0KDQplY2hvIFN0YXJ0aW5nIExvY2FsIFNlYXJjaCAoRmlyZWNyYXdsICsgU2VhclhORyku
  >> "!B64TMP!" echo Li4NCmRvY2tlciBjb21wb3NlIHVwIC1kDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBl
  >> "!B64TMP!" echo Y2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0YXJ0LiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBMb2NhbCBTZWFyY2ggaXMgcnVubmluZzoN
  >> "!B64TMP!" echo CmVjaG8gICBTZWFyWE5HOiAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCAgICAgIF4oY2hhbmdlIGlu
  >> "!B64TMP!" echo IC5lbnZeKQ0KZWNobyAgIEZpcmVjcmF3bDogaHR0cDovL2xvY2FsaG9zdDo5OTkxICAgICAgXihj
  >> "!B64TMP!" echo aGFuZ2UgaW4gLmVudl4pDQplY2hvLg0KZWNobyBPcGVuIHRoZSBTZWFyWE5HIFVJIGluIHlvdXIg
  >> "!B64TMP!" echo YnJvd3Nlciwgb3IgcXVlcnkgdGhlIEpTT04gQVBJIGZyb20geW91ciBtb2RlbHMuDQplY2hvIFVz
  >> "!B64TMP!" echo ZSBTdG9wLmJhdCB0byBzdG9wIHRoZSBzdGFjay4NCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAwDQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Run.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Stop.bat ---
set "NEED_B64=1"
if exist "!SRC!\Stop.bat" (
  copy /Y "!SRC!\Stop.bat" "!TARGET!\Stop.bat" >nul 2>&1
  if exist "!TARGET!\Stop.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Stop.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2263657140.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFN0b3ANCg0KY2QgL2QgIiV+ZHAwIg0KDQp3aGVyZSBk
  >> "!B64TMP!" echo b2NrZXIgPm51bCAyPiYxDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvIFtFUlJPUl0gRG9ja2Vy
  >> "!B64TMP!" echo IGlzIG5vdCBpbnN0YWxsZWQgb3Igbm90IG9uIFBBVEguDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0K
  >> "!B64TMP!" echo KQ0KDQppZiBub3QgZXhpc3QgIi5lbnYiICgNCiAgZWNobyBbRVJST1JdIE5vIC5lbnYgZmlsZSBm
  >> "!B64TMP!" echo b3VuZCBpbiB0aGlzIGZvbGRlci4gTm90aGluZyB0byBzdG9wLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDENCikNCg0KZWNobyBTdG9wcGluZyBMb2NhbCBTZWFyY2ggY29udGFpbmVycyAoZGF0YSBpcyBw
  >> "!B64TMP!" echo cmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duDQppZiBlcnJvcmxldmVsIDEgKA0KICBl
  >> "!B64TMP!" echo Y2hvLg0KICBlY2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0b3AuIFNlZSBtZXNzYWdlcyBhYm92ZS4N
  >> "!B64TMP!" echo CiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmVjaG8uDQplY2hvIExvY2FsIFNlYXJjaCBzdG9w
  >> "!B64TMP!" echo cGVkLiBEYXRhIGlzIHByZXNlcnZlZCBpbiBEb2NrZXIgdm9sdW1lcy4NCmVjaG8gUnVuIFJ1bi5i
  >> "!B64TMP!" echo YXQgdG8gc3RhcnQgaXQgYWdhaW4uDQplY2hvLg0KcGF1c2UNCmV4aXQgL2IgMA0K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Stop.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Update.bat ---
set "NEED_B64=1"
if exist "!SRC!\Update.bat" (
  copy /Y "!SRC!\Update.bat" "!TARGET!\Update.bat" >nul 2>&1
  if exist "!TARGET!\Update.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Update.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3559231701.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFVwZGF0ZQ0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJl
  >> "!B64TMP!" echo IGRvY2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2Nr
  >> "!B64TMP!" echo ZXIgaXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAx
  >> "!B64TMP!" echo DQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VS
  >> "!B64TMP!" echo Uk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0K
  >> "!B64TMP!" echo ICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hv
  >> "!B64TMP!" echo ICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZp
  >> "!B64TMP!" echo Z3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvIFVwZGF0aW5nIExvY2Fs
  >> "!B64TMP!" echo IFNlYXJjaC4uLg0KZWNoby4NCmVjaG8gWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uDQpk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBwdWxsDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZyB3aXRoIHdoYXQg
  >> "!B64TMP!" echo aXMgYXZhaWxhYmxlLg0KKQ0KDQplY2hvLg0KZWNobyBbMi8zXSBSZWNyZWF0aW5nIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB1cCAtZA0KaWYgZXJyb3JsZXZlbCAxICgNCiAgZWNoby4NCiAgZWNobyBbRVJST1JdIEZh
  >> "!B64TMP!" echo aWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2Nh
  >> "!B64TMP!" echo bC13ZWIgYWdlbnQgc2tpbGwuLi4NCmlmIGV4aXN0ICIlfmRwMGxvY2FsLXdlYlxTS0lMTC5tZCIg
  >> "!B64TMP!" echo KA0KICBzZXQgIlNLSUxMX0RJUj0lVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdl
  >> "!B64TMP!" echo YiINCiAgaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAvcSAiIVNLSUxMX0RJUiEiDQogIGlm
  >> "!B64TMP!" echo IG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxscyIgbWtkaXIgIiVVU0VSUFJP
  >> "!B64TMP!" echo RklMRSVcLmFnZW50c1xza2lsbHMiDQogIHhjb3B5IC9FIC9JIC9ZIC9RICIlfmRwMGxvY2FsLXdl
  >> "!B64TMP!" echo YiIgIiFTS0lMTF9ESVIhIiA+bnVsDQogIGlmIGVycm9ybGV2ZWwgMSAoDQogICAgZWNobyAgIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBDb3VsZCBub3QgY29weSB0aGUgc2tpbGwgdG8gIVNLSUxMX0RJUiEuDQogICkgZWxz
  >> "!B64TMP!" echo ZSAoDQogICAgPiAiIVNLSUxMX0RJUiFcaW5zdGFsbC1kaXIudHh0IiBlY2hvICV+ZHAwDQogICAg
  >> "!B64TMP!" echo ZWNobyAgIFNraWxsIHJlZnJlc2hlZCBhdCAhU0tJTExfRElSIQ0KICApDQopIGVsc2UgKA0KICBl
  >> "!B64TMP!" echo Y2hvICAgbG9jYWwtd2ViIHNraWxsIHNvdXJjZSBub3QgZm91bmQgaW4gdGhpcyBmb2xkZXIgLSBz
  >> "!B64TMP!" echo a2lwcGluZy4NCikNCg0KZWNoby4NCmVjaG8gVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMg
  >> "!B64TMP!" echo d2VyZSBwcmVzZXJ2ZWQuDQplY2hvICAgLSBJZiB5b3UgY2hhbmdlZCBwb3J0cyBvciBMTE0gc2V0
  >> "!B64TMP!" echo dGluZ3MgaW4gLmVudiwgdGhleSBhcmUgbm93IGFwcGxpZWQuDQplY2hvICAgLSBUaGUgbG9jYWwt
  >> "!B64TMP!" echo d2ViIHNraWxsIHdhcyByZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4NCmVjaG8gICAtIFRvIHVw
  >> "!B64TMP!" echo ZGF0ZSB0aGUgU2VhclhORyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNvbXBvc2UueW1sIHRlbXBs
  >> "!B64TMP!" echo YXRlLA0KZWNobyAgICAgcmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoaXQgYmFja3Mg
  >> "!B64TMP!" echo dXAgeW91ciBjdXJyZW50IC5lbnYpLg0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Update.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Uninstall.bat ---
set "NEED_B64=1"
if exist "!SRC!\Uninstall.bat" (
  copy /Y "!SRC!\Uninstall.bat" "!TARGET!\Uninstall.bat" >nul 2>&1
  if exist "!TARGET!\Uninstall.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Uninstall.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4046764878.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFVuaW5zdGFsbA0KDQpjZCAvZCAiJX5kcDAiDQoNCndo
  >> "!B64TMP!" echo ZXJlIGRvY2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBE
  >> "!B64TMP!" echo b2NrZXIgaXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4NCiAgZWNobyAgIFlvdSBjYW4g
  >> "!B64TMP!" echo bWFudWFsbHkgZGVsZXRlIHRoaXMgZm9sZGVyIHRvIHJlbW92ZSB0aGUgZmlsZXMuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQppZiBub3QgZXhpc3QgIi5lbnYiICgNCiAgZWNobyBbRVJST1Jd
  >> "!B64TMP!" echo IE5vIC5lbnYgZmlsZSBmb3VuZCBpbiB0aGlzIGZvbGRlci4gTm90aGluZyB0byB1bmluc3RhbGwu
  >> "!B64TMP!" echo DQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvID09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQ0KZWNobyAgIFVuaW5zdGFsbCBM
  >> "!B64TMP!" echo b2NhbCBTZWFyY2gNCmVjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09DQplY2hvIFRoaXMgd2lsbDoNCmVjaG8gICAxLiBTdG9wIGFu
  >> "!B64TMP!" echo ZCByZW1vdmUgYWxsIExvY2FsIFNlYXJjaCBjb250YWluZXJzLg0KZWNobyAgIDIuIFJlbW92ZSB0
  >> "!B64TMP!" echo aGUgRG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsIHJlZGlzIGNhY2hlLA0KZWNo
  >> "!B64TMP!" echo byAgICAgIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlzIGRlbGV0ZXMgYWxsIHN0b3JlZCBk
  >> "!B64TMP!" echo YXRhLg0KZWNobyAgIDMuIFJlbW92ZSB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsIGZyb20NCmVj
  >> "!B64TMP!" echo aG8gICAgICAlVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdlYg0KZWNobyAgIDQu
  >> "!B64TMP!" echo IChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgYWxsIGl0cyBmaWxlcy4N
  >> "!B64TMP!" echo CmVjaG8uDQplY2hvICAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVkICh1c2Ug
  >> "!B64TMP!" echo ImRvY2tlciBpbWFnZSBwcnVuZSIgdG8NCmVjaG8gICByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWx5KS4NCmVjaG8uDQpzZXQgIkNPTkZJUk09Ig0Kc2V0IC9wIENPTkZJUk09IkNvbnRp
  >> "!B64TMP!" echo bnVlIHdpdGggdW5pbnN0YWxsPyBbeS9OXTogIg0KaWYgL2kgbm90ICIhQ09ORklSTSEiPT0ieSIg
  >> "!B64TMP!" echo KCBlY2hvIFVuaW5zdGFsbCBjYW5jZWxsZWQuICYgcGF1c2UgJiBleGl0IC9iIDAgKQ0KDQplY2hv
  >> "!B64TMP!" echo Lg0KZWNobyBTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyArIHZvbHVtZXMuLi4NCmRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIGRvd24gLXYgLS1yZW1vdmUtb3JwaGFucw0KaWYgZXJyb3JsZXZlbCAxICgN
  >> "!B64TMP!" echo CiAgZWNoby4NCiAgZWNobyBbV0FSTklOR10gZG9ja2VyIGNvbXBvc2UgZG93biByZXBvcnRlZCBl
  >> "!B64TMP!" echo cnJvcnMuDQogIGVjaG8gICBZb3UgbWF5IG5lZWQgdG8gcmVtb3ZlIGxlZnRvdmVyIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgbWFudWFsbHksIGUuZy46DQogIGVjaG8gICAgIGRvY2tlciBybSAtZiBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo ZmlyZWNyYXdsIGxvY2FsLXNlYXJjaC1zZWFyeG5nDQogIGVjaG8gICAgIGRvY2tlciBybSAtZiBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gtcmVkaXMgbG9jYWwtc2VhcmNoLXJhYmJpdG1xDQogIGVjaG8gICAgIGRvY2tl
  >> "!B64TMP!" echo ciBybSAtZiBsb2NhbC1zZWFyY2gtcG9zdGdyZXMgbG9jYWwtc2VhcmNoLXBsYXl3cmlnaHQNCikN
  >> "!B64TMP!" echo Cg0KZWNoby4NCmVjaG8gQ29udGFpbmVycyBhbmQgdm9sdW1lcyByZW1vdmVkLg0KZWNoby4NCmVj
  >> "!B64TMP!" echo aG8gUmVtb3ZpbmcgdGhlIGxvY2FsLXdlYiBhZ2VudCBza2lsbC4uLg0Kc2V0ICJTS0lMTF9ESVI9
  >> "!B64TMP!" echo JVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWIiDQppZiBleGlzdCAiIVNLSUxM
  >> "!B64TMP!" echo X0RJUiEiICgNCiAgcmQgL3MgL3EgIiFTS0lMTF9ESVIhIg0KICBlY2hvICAgUmVtb3ZlZCAhU0tJ
  >> "!B64TMP!" echo TExfRElSIQ0KKSBlbHNlICgNCiAgZWNobyAgIFNraWxsIG5vdCBmb3VuZCBeKGFscmVhZHkgcmVt
  >> "!B64TMP!" echo b3ZlZF4pIC0gbm90aGluZyB0byBkby4NCikNCmVjaG8uDQpzZXQgIkRFTEZJTEVTPSINCnNldCAv
  >> "!B64TMP!" echo cCBERUxGSUxFUz0iQWxzbyBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBBTEwgaXRzIGZp
  >> "!B64TMP!" echo bGVzPyBbeS9OXTogIg0KaWYgL2kgbm90ICIhREVMRklMRVMhIj09InkiICgNCiAgZWNoby4NCiAg
  >> "!B64TMP!" echo ZWNobyBVbmluc3RhbGwgZmluaXNoZWQuIFRoZSBmb2xkZXIgd2FzIGtlcHQ6DQogIGVjaG8gICAl
  >> "!B64TMP!" echo Q0QlDQogIGVjaG8gICBZb3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2Vy
  >> "!B64TMP!" echo IG5lZWQgdGhlIHNjcmlwdHMuDQogIGVjaG8uDQogIHBhdXNlDQogIGV4aXQgL2IgMA0KKQ0KDQpj
  >> "!B64TMP!" echo ZCAvZCAiJVVTRVJQUk9GSUxFJSINCmVjaG8gRGVsZXRpbmcgaW5zdGFsbCBmb2xkZXI6ICV+ZHAw
  >> "!B64TMP!" echo DQpyZCAvcyAvcSAiJX5kcDAiDQplY2hvLg0KZWNobyBVbmluc3RhbGwgY29tcGxldGUuIEdvb2Ri
  >> "!B64TMP!" echo eWUhDQplY2hvLg0KcGF1c2UNCmV4aXQgL2IgMA0K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Uninstall.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- run.sh ---
set "NEED_B64=1"
if exist "!SRC!\run.sh" (
  copy /Y "!SRC!\run.sh" "!TARGET!\run.sh" >nul 2>&1
  if exist "!TARGET!\run.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] run.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1749764691.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0YXJ0IHRoZSBMb2NhbCBTZWFyY2ggc3RhY2sgKEZpcmVj
  >> "!B64TMP!" echo cmF3bCArIFNlYXJYTkcpLgpzZXQgLXUKY2QgIiQoZGlybmFtZSAiJDAiKSIgfHwgZXhpdCAxCgpp
  >> "!B64TMP!" echo ZiAhIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4mMTsgdGhlbgogIGVjaG8gIltFUlJP
  >> "!B64TMP!" echo Ul0gRG9ja2VyIGlzIG5vdCBpbnN0YWxsZWQuIFNlZSBSRUFETUUubWQuIiA+JjI7IGV4aXQgMQpm
  >> "!B64TMP!" echo aQppZiAhIGRvY2tlciBpbmZvID4vZGV2L251bGwgMj4mMTsgdGhlbgogIGVjaG8gIltFUlJPUl0g
  >> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZy4gU3RhcnQgRG9ja2VyIGZpcnN0LiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKaWYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4g
  >> "!B64TMP!" echo REM9ImRvY2tlciBjb21wb3NlIgplbGlmIGNvbW1hbmQgLXYgZG9ja2VyLWNvbXBvc2UgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXItY29tcG9zZSIKZWxzZSBlY2hvICJbRVJST1JdIERv
  >> "!B64TMP!" echo Y2tlciBDb21wb3NlIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAxOyBmaQoKaWYgWyAhIC1mICIuZW52
  >> "!B64TMP!" echo IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQgaW4gdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIuIFJ1biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCBmaXJzdC4iID4mMgogIGV4aXQgMQpmaQoK
  >> "!B64TMP!" echo ZWNobyAiU3RhcnRpbmcgTG9jYWwgU2VhcmNoIChGaXJlY3Jhd2wgKyBTZWFyWE5HKS4uLiIKJERD
  >> "!B64TMP!" echo IHVwIC1kIHx8IHsgZWNobyAiW0VSUk9SXSBGYWlsZWQgdG8gc3RhcnQuIiA+JjI7IGV4aXQgMTsg
  >> "!B64TMP!" echo fQoKZWNobwplY2hvICJMb2NhbCBTZWFyY2ggaXMgcnVubmluZy4iCmVjaG8gIiAgU2VhclhORzog
  >> "!B64TMP!" echo ICBodHRwOi8vbG9jYWxob3N0OiR7U0VBUlhOR19QT1JUOi05OTkwfSIKZWNobyAiICBGaXJlY3Jh
  >> "!B64TMP!" echo d2w6IGh0dHA6Ly9sb2NhbGhvc3Q6JHtGSVJFQ1JBV0xfUE9SVDotOTk5MX0iCmVjaG8gIlJ1biAu
  >> "!B64TMP!" echo L3N0b3Auc2ggdG8gc3RvcCB0aGUgc3RhY2suIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\run.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- stop.sh ---
set "NEED_B64=1"
if exist "!SRC!\stop.sh" (
  copy /Y "!SRC!\stop.sh" "!TARGET!\stop.sh" >nul 2>&1
  if exist "!TARGET!\stop.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] stop.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3584733866.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0b3AgdGhlIExvY2FsIFNlYXJjaCBzdGFjayAoY29udGFp
  >> "!B64TMP!" echo bmVycyByZW1vdmVkLCBkYXRhIHByZXNlcnZlZCkuCnNldCAtdQpjZCAiJChkaXJuYW1lICIkMCIp
  >> "!B64TMP!" echo IiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxOyB0aGVu
  >> "!B64TMP!" echo CiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4iID4mMjsgZXhpdCAxCmZp
  >> "!B64TMP!" echo CmlmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERDPSJkb2Nr
  >> "!B64TMP!" echo ZXIgY29tcG9zZSIKZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3NlID4vZGV2L251bGwgMj4m
  >> "!B64TMP!" echo MTsgdGhlbiBEQz0iZG9ja2VyLWNvbXBvc2UiCmVsc2UgZWNobyAiW0VSUk9SXSBEb2NrZXIgQ29t
  >> "!B64TMP!" echo cG9zZSBub3QgZm91bmQuIiA+JjI7IGV4aXQgMTsgZmkKCmlmIFsgISAtZiAiLmVudiIgXTsgdGhl
  >> "!B64TMP!" echo bgogIGVjaG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBOb3RoaW5nIHRvIHN0b3AuIiA+
  >> "!B64TMP!" echo JjI7IGV4aXQgMQpmaQoKZWNobyAiU3RvcHBpbmcgTG9jYWwgU2VhcmNoIGNvbnRhaW5lcnMgKGRh
  >> "!B64TMP!" echo dGEgaXMgcHJlc2VydmVkKS4uLiIKJERDIGRvd24gfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0
  >> "!B64TMP!" echo byBzdG9wLiIgPiYyOyBleGl0IDE7IH0KCmVjaG8KZWNobyAiTG9jYWwgU2VhcmNoIHN0b3BwZWQu
  >> "!B64TMP!" echo IERhdGEgaXMgcHJlc2VydmVkIGluIERvY2tlciB2b2x1bWVzLiIKZWNobyAiUnVuIC4vcnVuLnNo
  >> "!B64TMP!" echo IHRvIHN0YXJ0IGl0IGFnYWluLiIK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\stop.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- update.sh ---
set "NEED_B64=1"
if exist "!SRC!\update.sh" (
  copy /Y "!SRC!\update.sh" "!TARGET!\update.sh" >nul 2>&1
  if exist "!TARGET!\update.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] update.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS960388646.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVwZGF0ZSB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrOiBwdWxs
  >> "!B64TMP!" echo IGxhdGVzdCBpbWFnZXMsIHJlY3JlYXRlIGNvbnRhaW5lcnMsCiMgYW5kIHJlLXN5bmMgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXdlYiBhZ2VudCBza2lsbC4gRGF0YSB2b2x1bWVzIGFyZSBwcmVzZXJ2ZWQuIEVkaXRzCiMg
  >> "!B64TMP!" echo dG8gLmVudiAocG9ydHMsIExMTSkgYXJlIGFsc28gYXBwbGllZC4Kc2V0IC11CmNkICIkKGRpcm5h
  >> "!B64TMP!" echo bWUgIiQwIikiIHx8IGV4aXQgMQoKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+
  >> "!B64TMP!" echo JjE7IHRoZW4KICBlY2hvICJbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkLiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDEKZmkKaWYgISBkb2NrZXIgaW5mbyA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICBlY2hvICJb
  >> "!B64TMP!" echo RVJST1JdIERvY2tlciBlbmdpbmUgaXMgbm90IHJ1bm5pbmcuIFN0YXJ0IERvY2tlciBmaXJzdC4i
  >> "!B64TMP!" echo ID4mMjsgZXhpdCAxCmZpCmlmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYx
  >> "!B64TMP!" echo OyB0aGVuIERDPSJkb2NrZXIgY29tcG9zZSIKZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo ID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyLWNvbXBvc2UiCmVsc2UgZWNobyAiW0VS
  >> "!B64TMP!" echo Uk9SXSBEb2NrZXIgQ29tcG9zZSBub3QgZm91bmQuIiA+JjI7IGV4aXQgMTsgZmkKCmlmIFsgISAt
  >> "!B64TMP!" echo ZiAiLmVudiIgXTsgdGhlbgogIGVjaG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBSdW4g
  >> "!B64TMP!" echo aW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggZmlyc3QuIiA+JjIKICBleGl0IDEKZmkKCmVjaG8gIlVw
  >> "!B64TMP!" echo ZGF0aW5nIExvY2FsIFNlYXJjaC4uLiIKZWNobwplY2hvICJbMS8zXSBQdWxsaW5nIGxhdGVzdCBp
  >> "!B64TMP!" echo bWFnZXMuLi4iCiREQyBwdWxsIHx8IGVjaG8gIltXQVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQg
  >> "!B64TMP!" echo dG8gcHVsbC4gQ29udGludWluZy4iCgplY2hvCmVjaG8gIlsyLzNdIFJlY3JlYXRpbmcgY29udGFp
  >> "!B64TMP!" echo bmVycyB3aXRoIHVwZGF0ZWQgaW1hZ2VzIChkYXRhIGlzIHByZXNlcnZlZCkuLi4iCiREQyB1cCAt
  >> "!B64TMP!" echo ZCB8fCB7IGVjaG8gIltFUlJPUl0gRmFpbGVkIHRvIHJlY3JlYXRlIGNvbnRhaW5lcnMuIiA+JjI7
  >> "!B64TMP!" echo IGV4aXQgMTsgfQoKZWNobwplY2hvICJbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2NhbC13ZWIgYWdl
  >> "!B64TMP!" echo bnQgc2tpbGwuLi4iCmlmIFsgLWYgIi4vbG9jYWwtd2ViL1NLSUxMLm1kIiBdOyB0aGVuCiAgU0tJ
  >> "!B64TMP!" echo TExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIiCiAgcm0gLXJmICIkU0tJTExf
  >> "!B64TMP!" echo RElSIgogIG1rZGlyIC1wICIkSE9NRS8uYWdlbnRzL3NraWxscyIKICBpZiBjcCAtciAuL2xvY2Fs
  >> "!B64TMP!" echo LXdlYiAiJFNLSUxMX0RJUiI7IHRoZW4KICAgIHByaW50ZiAnJXNcbicgIiQocHdkKSIgPiAiJFNL
  >> "!B64TMP!" echo SUxMX0RJUi9pbnN0YWxsLWRpci50eHQiCiAgICBlY2hvICIgIFNraWxsIHJlZnJlc2hlZCBhdCAk
  >> "!B64TMP!" echo U0tJTExfRElSIgogIGVsc2UKICAgIGVjaG8gIiAgW1dBUk5JTkddIENvdWxkIG5vdCBjb3B5IHRo
  >> "!B64TMP!" echo ZSBza2lsbCB0byAkU0tJTExfRElSLiIKICBmaQplbHNlCiAgZWNobyAiICBsb2NhbC13ZWIgc2tp
  >> "!B64TMP!" echo bGwgc291cmNlIG5vdCBmb3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLiIKZmkKCmVjaG8K
  >> "!B64TMP!" echo ZWNobyAiVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2ZWQuIgplY2hv
  >> "!B64TMP!" echo ICIgIC0gUG9ydCAvIExMTSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5vdyBhcHBsaWVkLiIKZWNobyAi
  >> "!B64TMP!" echo ICAtIFRoZSBsb2NhbC13ZWIgc2tpbGwgd2FzIHJlLXN5bmNlZCBmcm9tIHRoaXMgZm9sZGVyLiIK
  >> "!B64TMP!" echo ZWNobyAiICAtIFRvIHVwZGF0ZSB0aGUgU2VhclhORyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNv
  >> "!B64TMP!" echo bXBvc2UueW1sIHRlbXBsYXRlLCIKZWNobyAiICAgIHJlLXJ1biBpbnN0YWxsLWxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC5zaCAoaXQgYmFja3MgdXAgeW91ciBjdXJyZW50IC5lbnYpLiIK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\update.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- uninstall.sh ---
set "NEED_B64=1"
if exist "!SRC!\uninstall.sh" (
  copy /Y "!SRC!\uninstall.sh" "!TARGET!\uninstall.sh" >nul 2>&1
  if exist "!TARGET!\uninstall.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] uninstall.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3708239055.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVuaW5zdGFsbCB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrLgoj
  >> "!B64TMP!" echo ICAgLSBzdG9wcyAmIHJlbW92ZXMgY29udGFpbmVycwojICAgLSByZW1vdmVzIERvY2tlciB2b2x1
  >> "!B64TMP!" echo bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLCByZWRpcywgcmFiYml0bXEsIHBvc3RncmVzKQojICAg
  >> "!B64TMP!" echo LSByZW1vdmVzIHRoZSBsb2NhbC13ZWIgYWdlbnQgc2tpbGwgKH4vLmFnZW50cy9za2lsbHMvbG9j
  >> "!B64TMP!" echo YWwtd2ViKQojICAgLSBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVyCnNldCAt
  >> "!B64TMP!" echo dQpjZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKbG93ZXIoKSB7IHByaW50ZiAnJXMnICIk
  >> "!B64TMP!" echo MSIgfCB0ciAnWzp1cHBlcjpdJyAnWzpsb3dlcjpdJzsgfSAgIyBiYXNoLTMuMiAobWFjT1MpIHNh
  >> "!B64TMP!" echo ZmUKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgZWNobyAi
  >> "!B64TMP!" echo W0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4gWW91IGNhbiBkZWxldGUgdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIgbWFudWFsbHkuIiA+JjIKICBleGl0IDEKZmkKaWYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+
  >> "!B64TMP!" echo L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlciBjb21wb3NlIgplbGlmIGNvbW1hbmQgLXYg
  >> "!B64TMP!" echo ZG9ja2VyLWNvbXBvc2UgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXItY29tcG9zZSIK
  >> "!B64TMP!" echo ZWxzZSBlY2hvICJbRVJST1JdIERvY2tlciBDb21wb3NlIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAx
  >> "!B64TMP!" echo OyBmaQoKaWYgWyAhIC1mICIuZW52IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZp
  >> "!B64TMP!" echo bGUgZm91bmQuIE5vdGhpbmcgdG8gdW5pbnN0YWxsLiIgPiYyOyBleGl0IDEKZmkKCmNhdCA8PCdN
  >> "!B64TMP!" echo U0cnCj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PQogIFVuaW5zdGFsbCBMb2NhbCBTZWFyY2gKPT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09ClRoaXMgd2lsbDoKICAxLiBTdG9w
  >> "!B64TMP!" echo IGFuZCByZW1vdmUgYWxsIExvY2FsIFNlYXJjaCBjb250YWluZXJzLgogIDIuIFJlbW92ZSB0aGUg
  >> "!B64TMP!" echo RG9ja2VyIFZPTFVNRVMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsIHJlZGlzIGNhY2hlLAogICAgIHJh
  >> "!B64TMP!" echo YmJpdG1xL3Bvc3RncmVzIGRhdGEpLiBUaGlzIGRlbGV0ZXMgYWxsIHN0b3JlZCBkYXRhLgogIDMu
  >> "!B64TMP!" echo IFJlbW92ZSB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsIGZyb20KICAgICB+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYgogIDQuIChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBh
  >> "!B64TMP!" echo bmQgYWxsIGl0cyBmaWxlcy4KCiAgUHVsbGVkIERvY2tlciBpbWFnZXMgYXJlIE5PVCByZW1vdmVk
  >> "!B64TMP!" echo ICh1c2UgJ2RvY2tlciBpbWFnZSBwcnVuZScKICB0byByZWNsYWltIHRoYXQgZGlzayBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWx5KS4KTVNHCmVjaG8KcHJpbnRmICJDb250aW51ZSB3aXRoIHVuaW5zdGFsbD8gW3kv
  >> "!B64TMP!" echo Tl06ICIKcmVhZCAtciBDT05GSVJNCmlmIFsgIiQobG93ZXIgIiRDT05GSVJNIikiICE9ICJ5IiBd
  >> "!B64TMP!" echo OyB0aGVuIGVjaG8gIlVuaW5zdGFsbCBjYW5jZWxsZWQuIjsgZXhpdCAwOyBmaQoKZWNobwplY2hv
  >> "!B64TMP!" echo ICJTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyArIHZvbHVtZXMuLi4iCiREQyBkb3du
  >> "!B64TMP!" echo IC12IC0tcmVtb3ZlLW9ycGhhbnMgfHwgZWNobyAiW1dBUk5JTkddIGRvY2tlciBjb21wb3NlIGRv
  >> "!B64TMP!" echo d24gcmVwb3J0ZWQgZXJyb3JzLiIKCmVjaG8KZWNobyAiQ29udGFpbmVycyBhbmQgdm9sdW1lcyBy
  >> "!B64TMP!" echo ZW1vdmVkLiIKZWNobwplY2hvICJSZW1vdmluZyB0aGUgbG9jYWwtd2ViIGFnZW50IHNraWxsLi4u
  >> "!B64TMP!" echo IgpTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYiIKaWYgWyAtZCAiJFNL
  >> "!B64TMP!" echo SUxMX0RJUiIgXTsgdGhlbgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBlY2hvICIgIFJlbW92ZWQg
  >> "!B64TMP!" echo JFNLSUxMX0RJUiIKZWxzZQogIGVjaG8gIiAgU2tpbGwgbm90IGZvdW5kIChhbHJlYWR5IHJlbW92
  >> "!B64TMP!" echo ZWQpIC0gbm90aGluZyB0byBkby4iCmZpCmVjaG8KcHJpbnRmICJBbHNvIGRlbGV0ZSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIgYW5kIEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiCnJlYWQgLXIgREVMRklMRVMK
  >> "!B64TMP!" echo aWYgWyAiJChsb3dlciAiJERFTEZJTEVTIikiICE9ICJ5IiBdOyB0aGVuCiAgZWNobwogIGVjaG8g
  >> "!B64TMP!" echo IlVuaW5zdGFsbCBmaW5pc2hlZC4gVGhlIGZvbGRlciB3YXMga2VwdDoiCiAgZWNobyAiICAkKHB3
  >> "!B64TMP!" echo ZCkiCiAgZWNobyAiICBZb3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2Vy
  >> "!B64TMP!" echo IG5lZWQgdGhlIHNjcmlwdHMuIgogIGV4aXQgMApmaQoKVEFSR0VUPSIkKHB3ZCkiCmNkICIkSE9N
  >> "!B64TMP!" echo RSIKZWNobyAiRGVsZXRpbmcgaW5zdGFsbCBmb2xkZXI6ICRUQVJHRVQiCnJtIC1yZiAiJFRBUkdF
  >> "!B64TMP!" echo VCIKZWNobwplY2hvICJVbmluc3RhbGwgY29tcGxldGUuIEdvb2RieWUhIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/SKILL.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web\SKILL.md" (
  copy /Y "!SRC!\local-web\SKILL.md" "!TARGET!\local-web\SKILL.md" >nul 2>&1
  if exist "!TARGET!\local-web\SKILL.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/SKILL.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS941573261.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYgpkZXNjcmlwdGlvbjogU2VhcmNoIHRoZSB3ZWIgYW5kIHJlYWQg
  >> "!B64TMP!" echo d2ViIHBhZ2VzIHRocm91Z2ggdGhlIGxvY2FsIHByaXZhdGUgc3RhY2sg4oCUIFNlYXJYTkcgYW5k
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBvbiBsb2NhbGhvc3QgKHBvcnRzIHJlYWQgZnJvbSB0aGUgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo IC5lbnYsIGRlZmF1bHRzIDk5OTAvOTk5MSkuIE5vIEFQSSBrZXlzLCBubyBleHRlcm5hbCBzZXJ2
  >> "!B64TMP!" echo aWNlcywgbm8gTUNQIHRvb2xzLiBUaGUgc2NyaXB0cyBhdXRvLXN0YXJ0IHRoZSBsb2NhbCBEb2Nr
  >> "!B64TMP!" echo ZXIgc3RhY2sgd2hlbiBpdCBpcyBkb3duLiBVc2Ugd2hlbmV2ZXIgdGhlIHVzZXIgYXNrcyBhYm91
  >> "!B64TMP!" echo dCBhbnl0aGluZyBjdXJyZW50LCByZWNlbnQsIG9yIHlvdSBhcmUgdW5zdXJlIGFib3V0OiBuZXdz
  >> "!B64TMP!" echo LCBldmVudHMsIGxhdGVzdCB2ZXJzaW9ucyBvciByZWxlYXNlcywgZG9jdW1lbnRhdGlvbiwgZmFj
  >> "!B64TMP!" echo dHMgdG8gdmVyaWZ5LCAid2hhdCBkbyB5b3Uga25vdyBhYm91dCBYIiBxdWVzdGlvbnMg4oCUIGV2
  >> "!B64TMP!" echo ZW4gd2hlbiB0aGV5IGRvbid0IGV4cGxpY2l0bHkgc2F5ICJzZWFyY2ggdGhlIHdlYiIuCi0tLQoK
  >> "!B64TMP!" echo IyBMb2NhbCB3ZWIgcmVzZWFyY2gKClRoaXMgbWFjaGluZSBydW5zIGEgcHJpdmF0ZSB3ZWItcmVz
  >> "!B64TMP!" echo ZWFyY2ggc3RhY2sgb24gbG9jYWxob3N0OgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNlYXJjaCB3
  >> "!B64TMP!" echo aXRoIGEgSlNPTiBBUEksIGF0IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAq
  >> "!B64TMP!" echo KkZpcmVjcmF3bCoqIOKAlCB0dXJucyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24sIGF0IGBo
  >> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1bHQKCkV2ZXJ5dGhpbmcgc3RheXMgbG9jYWw7
  >> "!B64TMP!" echo IG5vIEFQSSBrZXlzIGFyZSBuZWVkZWQuIFRoZSBhY3R1YWwgcG9ydHMgYXJlIHJlYWQKZnJvbSBg
  >> "!B64TMP!" echo U0VBUlhOR19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4gdGhlIGxvY2FsLXNlYXJjaCBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcidzCmAuZW52YCAodGhlIHNhbWUgZmlsZSB0aGUgY29tcG9zZSBzZXR1cCB1c2Vz
  >> "!B64TMP!" echo KSwgc28gaWYgY3VzdG9tIHBvcnRzIHdlcmUgcGlja2VkCmF0IHNldHVwIHRpbWUsIHRoZSBzY3Jp
  >> "!B64TMP!" echo cHRzIGZvbGxvdyB0aGVtIGF1dG9tYXRpY2FsbHkuIEhlbHBlciBzY3JpcHRzIChpbiB0aGlzCnNr
  >> "!B64TMP!" echo aWxsJ3MgYHNjcmlwdHMvYCBkaXJlY3RvcnkpIGRvIHRoZSBIVFRQIGFuZCBEb2NrZXIgd29yayBm
  >> "!B64TMP!" echo b3IgeW91IOKAlCBydW4gdGhlbQp3aXRoIHRoZSBCYXNoIHRvb2wgdXNpbmcgYHB5dGhvbmAuIFRo
  >> "!B64TMP!" echo ZSBzZXJ2aWNlcyBsaXZlIGluIERvY2tlciBjb250YWluZXJzLgoKKipObyB3YXJtLXVwIHN0ZXAg
  >> "!B64TMP!" echo aXMgbmVlZGVkLioqIElmIHRoZSBzdGFjayBpcyBkb3duLCB0aGUgc2NyaXB0cyBzdGFydCB0aGUK
  >> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSAoaWYgaXQncyBvZmYpIGFuZCB0aGUgY29udGFpbmVycyBhdXRvbWF0aWNh
  >> "!B64TMP!" echo bGx5ICh0aGUgc2FtZQpjb21tYW5kIFJ1bi5iYXQgLyBydW4uc2ggcnVuKSwgd2FpdCBmb3IgdGhl
  >> "!B64TMP!" echo bSwgYW5kIHJldHJ5IOKAlCB0aGV5IG5ldmVyIHN0b3AKdGhlIHN0YWNrIChzdG9wcGluZyBpcyB0
  >> "!B64TMP!" echo aGUgdXNlcidzIGpvYiwgdmlhIFN0b3AuYmF0IC8gc3RvcC5zaCkuIEV2ZW4gaW4gYW4Kb2xkIGNv
  >> "!B64TMP!" echo bnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdvbmUgZG93biwganVzdCBjYWxs
  >> "!B64TMP!" echo IHRoZSBzZWFyY2gKb3Igc2NyYXBlIHNjcmlwdCBkaXJlY3RseTsgaXQgd2lsbCBicmluZyBldmVy
  >> "!B64TMP!" echo eXRoaW5nIGJhY2sgYnkgaXRzZWxmLgoKIyMgV29ya2Zsb3cKCjEuICoqU2VhcmNoIHRoZSB3ZWIq
  >> "!B64TMP!" echo KiDigJQgZ28gc3RyYWlnaHQgYWhlYWQ6CgogICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJh
  >> "!B64TMP!" echo c2UtZGlyPi9zY3JpcHRzL3dlYl9zZWFyY2gucHkiICJ5b3VyIHF1ZXJ5IGhlcmUiCiAgIGBgYAoK
  >> "!B64TMP!" echo ICAgUHJpbnRzIHRoZSB0b3AgcmVzdWx0cyBhcyBgdGl0bGUgLyB1cmwgLyB+MzAwLWNoYXIgc25p
  >> "!B64TMP!" echo cHBldGAuCiAgIFVzZWZ1bCBvcHRpb25zOiBgLS1saW1pdCAxMGAsIGAtLXRpbWUtcmFuZ2UgZGF5
  >> "!B64TMP!" echo fHdlZWt8bW9udGhgLAogICBgLS1jYXRlZ29yaWVzIGl0LG5ld3MsZ2VuZXJhbGAuCgogICBJZiB0
  >> "!B64TMP!" echo aGUgc3RhY2sgaXMgZG93biwgdGhlIHNjcmlwdCByZXBvcnRzIGBTdGFjayB1bnJlYWNoYWJsZSAu
  >> "!B64TMP!" echo Li4gc3RhcnRpbmcKICAgaXQgYXV0b21hdGljYWxseWAgb24gc3RkZXJyLCBib290cyBpdCwgYW5k
  >> "!B64TMP!" echo IHJldHJpZXMuIEdpdmUgdGhlIEJhc2ggY2FsbCBhCiAgIDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGFs
  >> "!B64TMP!" echo bG93IGZvciB0aGF0IChlbmdpbmUgYm9vdCArIGNvbnRhaW5lciBib290KTsgb25seQogICBhIGZp
  >> "!B64TMP!" echo cnN0LWV2ZXIgc3RhcnQgKHB1bGxpbmcgfjMgR0Igb2YgaW1hZ2VzKSBjYW4gZXhjZWVkIGl0LgoK
  >> "!B64TMP!" echo Mi4gKipSZWFkIHRoZSBwYWdlcyoqIOKAlCBzY3JhcGUgdGhlIDHigJMzIG1vc3QgcmVsZXZhbnQg
  >> "!B64TMP!" echo cmVzdWx0IFVSTHMgZm9yIGZ1bGwgdGV4dDoKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwt
  >> "!B64TMP!" echo YmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NjcmFwZS5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20vYXJ0
  >> "!B64TMP!" echo aWNsZSIKICAgYGBgCgogICBQcmludHMgY2xlYW4gTWFya2Rvd24gKHRydW5jYXRlZCBhdCAyMCww
  >> "!B64TMP!" echo MDAgY2hhcnMgYnkgZGVmYXVsdDsgcmFpc2Ugd2l0aAogICBgLS1tYXgtY2hhcnNgKS4gU2VsZi1o
  >> "!B64TMP!" echo ZWFscyBhIGRvd24gc3RhY2sgdGhlIHNhbWUgd2F5LiBPbmx5IGV2ZXIgc2NyYXBlCiAgIFVSTHMg
  >> "!B64TMP!" echo dGhhdCB0aGUgc2VhcmNoIHJlc3VsdHMgYWN0dWFsbHkgcmV0dXJuZWQg4oCUIG5ldmVyIGludmVu
  >> "!B64TMP!" echo dCBvciBndWVzcwogICBVUkxzLgoKMy4gKipBbnN3ZXIgd2l0aCBjaXRhdGlvbnMqKiDigJQgYmFj
  >> "!B64TMP!" echo ayBlYWNoIGZhY3R1YWwgY2xhaW0gd2l0aCB0aGUgVVJMIHlvdSByZWFkLgoKYGVuc3VyZV9zdGFj
  >> "!B64TMP!" echo ay5weWAgaXMgc3RpbGwgYXZhaWxhYmxlIGFzIGFuIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2sg
  >> "!B64TMP!" echo b3IKc3RhdHVzIHJlcG9ydCAoYHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL2Vuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5weSJgLCBhZGQKYC0tY2hlY2tgIHRvIG9ubHkgcmVwb3J0IHN0YXR1cyBhbmQgbmV2
  >> "!B64TMP!" echo ZXIgc3RhcnQgYW55dGhpbmcpLCBidXQgaXQgaXMgTk9UCnJlcXVpcmVkIGJlZm9yZSBzZWFyY2hp
  >> "!B64TMP!" echo bmcg4oCUIHRoZSBzZWFyY2gvc2NyYXBlIHNjcmlwdHMgaGFuZGxlIGEgZG93biBzdGFjawp0aGVt
  >> "!B64TMP!" echo c2VsdmVzLgoKIyMgRXJyb3IgaGFuZGxpbmcKCi0gSWYgYSBzZWFyY2ggb3Igc2NyYXBlIGZhaWxz
  >> "!B64TMP!" echo LCByZXRyeSAqKm9uY2UqKiB3aXRoIGEgZGlmZmVyZW50IHF1ZXJ5IChzZWFyY2gpCiAgb3IgYSBk
  >> "!B64TMP!" echo aWZmZXJlbnQgcmVzdWx0IFVSTCAoc2NyYXBlKS4KLSBDb25uZWN0aW9uIGVycm9ycyBhcmUgaGFu
  >> "!B64TMP!" echo ZGxlZCBmb3IgeW91OiB0aGUgc2NyaXB0cyBzdGFydCB0aGUgRG9ja2VyIGVuZ2luZQogIGFuZCB0
  >> "!B64TMP!" echo aGUgY29udGFpbmVycyBhdXRvbWF0aWNhbGx5LCB3YWl0IHVudGlsIHRoZXkgYW5zd2VyLCBhbmQg
  >> "!B64TMP!" echo cmV0cnkgdGhlCiAgcmVxdWVzdCBvbmNlLiBPbmx5IGlmIGEgc2NyaXB0IHJlcG9ydHMgaXQgY291
  >> "!B64TMP!" echo bGQgbm90IGxhdW5jaCB0aGUgZW5naW5lIGF0CiAgYWxsIChvciB0aGUgc3RhY2sgZGlkIG5vdCBi
  >> "!B64TMP!" echo ZWNvbWUgcmVhZHkpIHNob3VsZCB5b3UgYXNrIHRoZSB1c2VyIHRvIHN0YXJ0CiAgRG9ja2VyIERl
  >> "!B64TMP!" echo c2t0b3AgbWFudWFsbHksIHRoZW4gcmV0cnkuCi0gKipEbyBub3QgZmFsbCBiYWNrIHRvIGJ1aWx0
  >> "!B64TMP!" echo LWluIG9yIGFsdGVybmF0aXZlIHdlYiB0b29scyoqIHdoZW4gdGhpcyBzdGFjawogIGhhcyBhIHBy
  >> "!B64TMP!" echo b2JsZW0g4oCUIGZpeCB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlcikgYW5kIHJldHJ5LCB1bmxl
  >> "!B64TMP!" echo c3MgdGhlIHVzZXIKICBleHBsaWNpdGx5IGFza3MgZm9yIGFuIGFsdGVybmF0aXZlLgotIE9ubHkg
  >> "!B64TMP!" echo aWYgYSBzY3JpcHQgcmVwb3J0cyBpdCBjb3VsZCBub3QgZmluZCB0aGUgbG9jYWwtc2VhcmNoIGlu
  >> "!B64TMP!" echo c3RhbGwKICBmb2xkZXI6IGFzayB0aGUgdXNlciB3aGVyZSB0aGF0IGZvbGRlciBpcywgdGhlbiBy
  >> "!B64TMP!" echo ZS1ydW4gdGhlIHNjcmlwdCB3aXRoCiAgYExPQ0FMX1NFQVJDSF9ESVI9PHRoYXQgcGF0aD5gLiBE
  >> "!B64TMP!" echo b24ndCBkbyB0aGlzIHByZWVtcHRpdmVseSDigJQgdGhlIGZvbGRlciBpcwogIG5vcm1hbGx5IGRl
  >> "!B64TMP!" echo dGVjdGVkIGF1dG9tYXRpY2FsbHkgKGZyb20gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIHJ1bm5p
  >> "!B64TMP!" echo bmcKICBjb250YWluZXJzLCB0aGUgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGlu
  >> "!B64TMP!" echo c3RhbGxlciwgb3IgZnJvbQogIH4vbG9jYWwtc2VhcmNoKS4KLSBTY3JhcGUgb3V0cHV0IGlzIGxv
  >> "!B64TMP!" echo bmcuIEV4dHJhY3Qgb25seSB0aGUgcGFydHMgeW91IG5lZWQgZm9yIHRoZSBhbnN3ZXI7IGRvbid0
  >> "!B64TMP!" echo CiAgcGFzdGUgd2hvbGUgcGFnZXMgYmFjayB0byB0aGUgdXNlci4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/LICENSE ---
set "NEED_B64=1"
if exist "!SRC!\local-web\LICENSE" (
  copy /Y "!SRC!\local-web\LICENSE" "!TARGET!\local-web\LICENSE" >nul 2>&1
  if exist "!TARGET!\local-web\LICENSE" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/LICENSE  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2410305736.b64"
  > "!B64TMP!" echo TW96aWxsYSBQdWJsaWMgTGljZW5zZSBWZXJzaW9uIDIuMAo9PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09CgoxLiBEZWZpbml0aW9ucwotLS0tLS0tLS0tLS0tLQoKMS4xLiAiQ29udHJp
  >> "!B64TMP!" echo YnV0b3IiCiAgICBtZWFucyBlYWNoIGluZGl2aWR1YWwgb3IgbGVnYWwgZW50aXR5IHRoYXQgY3Jl
  >> "!B64TMP!" echo YXRlcywgY29udHJpYnV0ZXMgdG8KICAgIHRoZSBjcmVhdGlvbiBvZiwgb3Igb3ducyBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlLgoKMS4yLiAiQ29udHJpYnV0b3IgVmVyc2lvbiIKICAgIG1lYW5zIHRoZSBjb21i
  >> "!B64TMP!" echo aW5hdGlvbiBvZiB0aGUgQ29udHJpYnV0aW9ucyBvZiBvdGhlcnMgKGlmIGFueSkgdXNlZAogICAg
  >> "!B64TMP!" echo YnkgYSBDb250cmlidXRvciBhbmQgdGhhdCBwYXJ0aWN1bGFyIENvbnRyaWJ1dG9yJ3MgQ29udHJp
  >> "!B64TMP!" echo YnV0aW9uLgoKMS4zLiAiQ29udHJpYnV0aW9uIgogICAgbWVhbnMgQ292ZXJlZCBTb2Z0d2FyZSBv
  >> "!B64TMP!" echo ZiBhIHBhcnRpY3VsYXIgQ29udHJpYnV0b3IuCgoxLjQuICJDb3ZlcmVkIFNvZnR3YXJlIgogICAg
  >> "!B64TMP!" echo bWVhbnMgU291cmNlIENvZGUgRm9ybSB0byB3aGljaCB0aGUgaW5pdGlhbCBDb250cmlidXRvciBo
  >> "!B64TMP!" echo YXMgYXR0YWNoZWQKICAgIHRoZSBub3RpY2UgaW4gRXhoaWJpdCBBLCB0aGUgRXhlY3V0YWJsZSBG
  >> "!B64TMP!" echo b3JtIG9mIHN1Y2ggU291cmNlIENvZGUKICAgIEZvcm0sIGFuZCBNb2RpZmljYXRpb25zIG9mIHN1
  >> "!B64TMP!" echo Y2ggU291cmNlIENvZGUgRm9ybSwgaW4gZWFjaCBjYXNlCiAgICBpbmNsdWRpbmcgcG9ydGlvbnMg
  >> "!B64TMP!" echo dGhlcmVvZi4KCjEuNS4gIkluY29tcGF0aWJsZSBXaXRoIFNlY29uZGFyeSBMaWNlbnNlcyIKICAg
  >> "!B64TMP!" echo IG1lYW5zCgogICAgKGEpIHRoYXQgdGhlIGluaXRpYWwgQ29udHJpYnV0b3IgaGFzIGF0dGFjaGVk
  >> "!B64TMP!" echo IHRoZSBub3RpY2UgZGVzY3JpYmVkCiAgICAgICAgaW4gRXhoaWJpdCBCIHRvIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlOyBvcgoKICAgIChiKSB0aGF0IHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHdhcyBtYWRl
  >> "!B64TMP!" echo IGF2YWlsYWJsZSB1bmRlciB0aGUgdGVybXMgb2YKICAgICAgICB2ZXJzaW9uIDEuMSBvciBlYXJs
  >> "!B64TMP!" echo aWVyIG9mIHRoZSBMaWNlbnNlLCBidXQgbm90IGFsc28gdW5kZXIgdGhlCiAgICAgICAgdGVybXMg
  >> "!B64TMP!" echo b2YgYSBTZWNvbmRhcnkgTGljZW5zZS4KCjEuNi4gIkV4ZWN1dGFibGUgRm9ybSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IGFueSBmb3JtIG9mIHRoZSB3b3JrIG90aGVyIHRoYW4gU291cmNlIENvZGUgRm9ybS4KCjEuNy4g
  >> "!B64TMP!" echo IkxhcmdlciBXb3JrIgogICAgbWVhbnMgYSB3b3JrIHRoYXQgY29tYmluZXMgQ292ZXJlZCBTb2Z0
  >> "!B64TMP!" echo d2FyZSB3aXRoIG90aGVyIG1hdGVyaWFsLCBpbgogICAgYSBzZXBhcmF0ZSBmaWxlIG9yIGZpbGVz
  >> "!B64TMP!" echo LCB0aGF0IGlzIG5vdCBDb3ZlcmVkIFNvZnR3YXJlLgoKMS44LiAiTGljZW5zZSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IHRoaXMgZG9jdW1lbnQuCgoxLjkuICJMaWNlbnNhYmxlIgogICAgbWVhbnMgaGF2aW5nIHRoZSBy
  >> "!B64TMP!" echo aWdodCB0byBncmFudCwgdG8gdGhlIG1heGltdW0gZXh0ZW50IHBvc3NpYmxlLAogICAgd2hldGhl
  >> "!B64TMP!" echo ciBhdCB0aGUgdGltZSBvZiB0aGUgaW5pdGlhbCBncmFudCBvciBzdWJzZXF1ZW50bHksIGFueSBh
  >> "!B64TMP!" echo bmQKICAgIGFsbCBvZiB0aGUgcmlnaHRzIGNvbnZleWVkIGJ5IHRoaXMgTGljZW5zZS4KCjEuMTAu
  >> "!B64TMP!" echo ICJNb2RpZmljYXRpb25zIgogICAgbWVhbnMgYW55IG9mIHRoZSBmb2xsb3dpbmc6CgogICAgKGEp
  >> "!B64TMP!" echo IGFueSBmaWxlIGluIFNvdXJjZSBDb2RlIEZvcm0gdGhhdCByZXN1bHRzIGZyb20gYW4gYWRkaXRp
  >> "!B64TMP!" echo b24gdG8sCiAgICAgICAgZGVsZXRpb24gZnJvbSwgb3IgbW9kaWZpY2F0aW9uIG9mIHRoZSBjb250
  >> "!B64TMP!" echo ZW50cyBvZiBDb3ZlcmVkCiAgICAgICAgU29mdHdhcmU7IG9yCgogICAgKGIpIGFueSBuZXcgZmls
  >> "!B64TMP!" echo ZSBpbiBTb3VyY2UgQ29kZSBGb3JtIHRoYXQgY29udGFpbnMgYW55IENvdmVyZWQKICAgICAgICBT
  >> "!B64TMP!" echo b2Z0d2FyZS4KCjEuMTEuICJQYXRlbnQgQ2xhaW1zIiBvZiBhIENvbnRyaWJ1dG9yCiAgICBtZWFu
  >> "!B64TMP!" echo cyBhbnkgcGF0ZW50IGNsYWltKHMpLCBpbmNsdWRpbmcgd2l0aG91dCBsaW1pdGF0aW9uLCBtZXRo
  >> "!B64TMP!" echo b2QsCiAgICBwcm9jZXNzLCBhbmQgYXBwYXJhdHVzIGNsYWltcywgaW4gYW55IHBhdGVudCBMaWNl
  >> "!B64TMP!" echo bnNhYmxlIGJ5IHN1Y2gKICAgIENvbnRyaWJ1dG9yIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkLCBi
  >> "!B64TMP!" echo dXQgZm9yIHRoZSBncmFudCBvZiB0aGUKICAgIExpY2Vuc2UsIGJ5IHRoZSBtYWtpbmcsIHVzaW5n
  >> "!B64TMP!" echo LCBzZWxsaW5nLCBvZmZlcmluZyBmb3Igc2FsZSwgaGF2aW5nCiAgICBtYWRlLCBpbXBvcnQsIG9y
  >> "!B64TMP!" echo IHRyYW5zZmVyIG9mIGVpdGhlciBpdHMgQ29udHJpYnV0aW9ucyBvciBpdHMKICAgIENvbnRyaWJ1
  >> "!B64TMP!" echo dG9yIFZlcnNpb24uCgoxLjEyLiAiU2Vjb25kYXJ5IExpY2Vuc2UiCiAgICBtZWFucyBlaXRoZXIg
  >> "!B64TMP!" echo dGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlLCBWZXJzaW9uIDIuMCwgdGhlIEdOVQogICAg
  >> "!B64TMP!" echo TGVzc2VyIEdlbmVyYWwgUHVibGljIExpY2Vuc2UsIFZlcnNpb24gMi4xLCB0aGUgR05VIEFmZmVy
  >> "!B64TMP!" echo byBHZW5lcmFsCiAgICBQdWJsaWMgTGljZW5zZSwgVmVyc2lvbiAzLjAsIG9yIGFueSBsYXRlciB2
  >> "!B64TMP!" echo ZXJzaW9ucyBvZiB0aG9zZQogICAgbGljZW5zZXMuCgoxLjEzLiAiU291cmNlIENvZGUgRm9ybSIK
  >> "!B64TMP!" echo ICAgIG1lYW5zIHRoZSBmb3JtIG9mIHRoZSB3b3JrIHByZWZlcnJlZCBmb3IgbWFraW5nIG1vZGlm
  >> "!B64TMP!" echo aWNhdGlvbnMuCgoxLjE0LiAiWW91IiAob3IgIllvdXIiKQogICAgbWVhbnMgYW4gaW5kaXZpZHVh
  >> "!B64TMP!" echo bCBvciBhIGxlZ2FsIGVudGl0eSBleGVyY2lzaW5nIHJpZ2h0cyB1bmRlciB0aGlzCiAgICBMaWNl
  >> "!B64TMP!" echo bnNlLiBGb3IgbGVnYWwgZW50aXRpZXMsICJZb3UiIGluY2x1ZGVzIGFueSBlbnRpdHkgdGhhdAog
  >> "!B64TMP!" echo ICAgY29udHJvbHMsIGlzIGNvbnRyb2xsZWQgYnksIG9yIGlzIHVuZGVyIGNvbW1vbiBjb250cm9s
  >> "!B64TMP!" echo IHdpdGggWW91LiBGb3IKICAgIHB1cnBvc2VzIG9mIHRoaXMgZGVmaW5pdGlvbiwgImNvbnRyb2wi
  >> "!B64TMP!" echo IG1lYW5zIChhKSB0aGUgcG93ZXIsIGRpcmVjdAogICAgb3IgaW5kaXJlY3QsIHRvIGNhdXNlIHRo
  >> "!B64TMP!" echo ZSBkaXJlY3Rpb24gb3IgbWFuYWdlbWVudCBvZiBzdWNoIGVudGl0eSwKICAgIHdoZXRoZXIgYnkg
  >> "!B64TMP!" echo Y29udHJhY3Qgb3Igb3RoZXJ3aXNlLCBvciAoYikgb3duZXJzaGlwIG9mIG1vcmUgdGhhbgogICAg
  >> "!B64TMP!" echo ZmlmdHkgcGVyY2VudCAoNTAlKSBvZiB0aGUgb3V0c3RhbmRpbmcgc2hhcmVzIG9yIGJlbmVmaWNp
  >> "!B64TMP!" echo YWwKICAgIG93bmVyc2hpcCBvZiBzdWNoIGVudGl0eS4KCjIuIExpY2Vuc2UgR3JhbnRzIGFuZCBD
  >> "!B64TMP!" echo b25kaXRpb25zCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgoyLjEuIEdyYW50cwoK
  >> "!B64TMP!" echo RWFjaCBDb250cmlidXRvciBoZXJlYnkgZ3JhbnRzIFlvdSBhIHdvcmxkLXdpZGUsIHJveWFsdHkt
  >> "!B64TMP!" echo ZnJlZSwKbm9uLWV4Y2x1c2l2ZSBsaWNlbnNlOgoKKGEpIHVuZGVyIGludGVsbGVjdHVhbCBwcm9w
  >> "!B64TMP!" echo ZXJ0eSByaWdodHMgKG90aGVyIHRoYW4gcGF0ZW50IG9yIHRyYWRlbWFyaykKICAgIExpY2Vuc2Fi
  >> "!B64TMP!" echo bGUgYnkgc3VjaCBDb250cmlidXRvciB0byB1c2UsIHJlcHJvZHVjZSwgbWFrZSBhdmFpbGFibGUs
  >> "!B64TMP!" echo CiAgICBtb2RpZnksIGRpc3BsYXksIHBlcmZvcm0sIGRpc3RyaWJ1dGUsIGFuZCBvdGhlcndpc2Ug
  >> "!B64TMP!" echo ZXhwbG9pdCBpdHMKICAgIENvbnRyaWJ1dGlvbnMsIGVpdGhlciBvbiBhbiB1bm1vZGlmaWVkIGJh
  >> "!B64TMP!" echo c2lzLCB3aXRoIE1vZGlmaWNhdGlvbnMsIG9yCiAgICBhcyBwYXJ0IG9mIGEgTGFyZ2VyIFdvcms7
  >> "!B64TMP!" echo IGFuZAoKKGIpIHVuZGVyIFBhdGVudCBDbGFpbXMgb2Ygc3VjaCBDb250cmlidXRvciB0byBtYWtl
  >> "!B64TMP!" echo LCB1c2UsIHNlbGwsIG9mZmVyCiAgICBmb3Igc2FsZSwgaGF2ZSBtYWRlLCBpbXBvcnQsIGFuZCBv
  >> "!B64TMP!" echo dGhlcndpc2UgdHJhbnNmZXIgZWl0aGVyIGl0cwogICAgQ29udHJpYnV0aW9ucyBvciBpdHMgQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgVmVyc2lvbi4KCjIuMi4gRWZmZWN0aXZlIERhdGUKClRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkIGluIFNlY3Rpb24gMi4xIHdpdGggcmVzcGVjdCB0byBhbnkgQ29udHJpYnV0aW9uCmJlY29t
  >> "!B64TMP!" echo ZSBlZmZlY3RpdmUgZm9yIGVhY2ggQ29udHJpYnV0aW9uIG9uIHRoZSBkYXRlIHRoZSBDb250cmli
  >> "!B64TMP!" echo dXRvciBmaXJzdApkaXN0cmlidXRlcyBzdWNoIENvbnRyaWJ1dGlvbi4KCjIuMy4gTGltaXRhdGlv
  >> "!B64TMP!" echo bnMgb24gR3JhbnQgU2NvcGUKClRoZSBsaWNlbnNlcyBncmFudGVkIGluIHRoaXMgU2VjdGlvbiAy
  >> "!B64TMP!" echo IGFyZSB0aGUgb25seSByaWdodHMgZ3JhbnRlZCB1bmRlcgp0aGlzIExpY2Vuc2UuIE5vIGFkZGl0
  >> "!B64TMP!" echo aW9uYWwgcmlnaHRzIG9yIGxpY2Vuc2VzIHdpbGwgYmUgaW1wbGllZCBmcm9tIHRoZQpkaXN0cmli
  >> "!B64TMP!" echo dXRpb24gb3IgbGljZW5zaW5nIG9mIENvdmVyZWQgU29mdHdhcmUgdW5kZXIgdGhpcyBMaWNlbnNl
  >> "!B64TMP!" echo LgpOb3R3aXRoc3RhbmRpbmcgU2VjdGlvbiAyLjEoYikgYWJvdmUsIG5vIHBhdGVudCBsaWNlbnNl
  >> "!B64TMP!" echo IGlzIGdyYW50ZWQgYnkgYQpDb250cmlidXRvcjoKCihhKSBmb3IgYW55IGNvZGUgdGhhdCBhIENv
  >> "!B64TMP!" echo bnRyaWJ1dG9yIGhhcyByZW1vdmVkIGZyb20gQ292ZXJlZCBTb2Z0d2FyZTsKICAgIG9yCgooYikg
  >> "!B64TMP!" echo Zm9yIGluZnJpbmdlbWVudHMgY2F1c2VkIGJ5OiAoaSkgWW91ciBhbmQgYW55IG90aGVyIHRoaXJk
  >> "!B64TMP!" echo IHBhcnR5J3MKICAgIG1vZGlmaWNhdGlvbnMgb2YgQ292ZXJlZCBTb2Z0d2FyZSwgb3IgKGlpKSB0
  >> "!B64TMP!" echo aGUgY29tYmluYXRpb24gb2YgaXRzCiAgICBDb250cmlidXRpb25zIHdpdGggb3RoZXIgc29mdHdh
  >> "!B64TMP!" echo cmUgKGV4Y2VwdCBhcyBwYXJ0IG9mIGl0cyBDb250cmlidXRvcgogICAgVmVyc2lvbik7IG9yCgoo
  >> "!B64TMP!" echo YykgdW5kZXIgUGF0ZW50IENsYWltcyBpbmZyaW5nZWQgYnkgQ292ZXJlZCBTb2Z0d2FyZSBpbiB0
  >> "!B64TMP!" echo aGUgYWJzZW5jZSBvZgogICAgaXRzIENvbnRyaWJ1dGlvbnMuCgpUaGlzIExpY2Vuc2UgZG9lcyBu
  >> "!B64TMP!" echo b3QgZ3JhbnQgYW55IHJpZ2h0cyBpbiB0aGUgdHJhZGVtYXJrcywgc2VydmljZSBtYXJrcywKb3Ig
  >> "!B64TMP!" echo bG9nb3Mgb2YgYW55IENvbnRyaWJ1dG9yIChleGNlcHQgYXMgbWF5IGJlIG5lY2Vzc2FyeSB0byBj
  >> "!B64TMP!" echo b21wbHkgd2l0aAp0aGUgbm90aWNlIHJlcXVpcmVtZW50cyBpbiBTZWN0aW9uIDMuNCkuCgoyLjQu
  >> "!B64TMP!" echo IFN1YnNlcXVlbnQgTGljZW5zZXMKCk5vIENvbnRyaWJ1dG9yIG1ha2VzIGFkZGl0aW9uYWwgZ3Jh
  >> "!B64TMP!" echo bnRzIGFzIGEgcmVzdWx0IG9mIFlvdXIgY2hvaWNlIHRvCmRpc3RyaWJ1dGUgdGhlIENvdmVyZWQg
  >> "!B64TMP!" echo U29mdHdhcmUgdW5kZXIgYSBzdWJzZXF1ZW50IHZlcnNpb24gb2YgdGhpcwpMaWNlbnNlIChzZWUg
  >> "!B64TMP!" echo U2VjdGlvbiAxMC4yKSBvciB1bmRlciB0aGUgdGVybXMgb2YgYSBTZWNvbmRhcnkgTGljZW5zZSAo
  >> "!B64TMP!" echo aWYKcGVybWl0dGVkIHVuZGVyIHRoZSB0ZXJtcyBvZiBTZWN0aW9uIDMuMykuCgoyLjUuIFJlcHJl
  >> "!B64TMP!" echo c2VudGF0aW9uCgpFYWNoIENvbnRyaWJ1dG9yIHJlcHJlc2VudHMgdGhhdCB0aGUgQ29udHJpYnV0
  >> "!B64TMP!" echo b3IgYmVsaWV2ZXMgaXRzCkNvbnRyaWJ1dGlvbnMgYXJlIGl0cyBvcmlnaW5hbCBjcmVhdGlvbihz
  >> "!B64TMP!" echo KSBvciBpdCBoYXMgc3VmZmljaWVudCByaWdodHMKdG8gZ3JhbnQgdGhlIHJpZ2h0cyB0byBpdHMg
  >> "!B64TMP!" echo Q29udHJpYnV0aW9ucyBjb252ZXllZCBieSB0aGlzIExpY2Vuc2UuCgoyLjYuIEZhaXIgVXNlCgpU
  >> "!B64TMP!" echo aGlzIExpY2Vuc2UgaXMgbm90IGludGVuZGVkIHRvIGxpbWl0IGFueSByaWdodHMgWW91IGhhdmUg
  >> "!B64TMP!" echo dW5kZXIKYXBwbGljYWJsZSBjb3B5cmlnaHQgZG9jdHJpbmVzIG9mIGZhaXIgdXNlLCBmYWlyIGRl
  >> "!B64TMP!" echo YWxpbmcsIG9yIG90aGVyCmVxdWl2YWxlbnRzLgoKMi43LiBDb25kaXRpb25zCgpTZWN0aW9ucyAz
  >> "!B64TMP!" echo LjEsIDMuMiwgMy4zLCBhbmQgMy40IGFyZSBjb25kaXRpb25zIG9mIHRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkCmluIFNlY3Rpb24gMi4xLgoKMy4gUmVzcG9uc2liaWxpdGllcwotLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tCgozLjEuIERpc3RyaWJ1dGlvbiBvZiBTb3VyY2UgRm9ybQoKQWxsIGRpc3RyaWJ1dGlvbiBv
  >> "!B64TMP!" echo ZiBDb3ZlcmVkIFNvZnR3YXJlIGluIFNvdXJjZSBDb2RlIEZvcm0sIGluY2x1ZGluZyBhbnkKTW9k
  >> "!B64TMP!" echo aWZpY2F0aW9ucyB0aGF0IFlvdSBjcmVhdGUgb3IgdG8gd2hpY2ggWW91IGNvbnRyaWJ1dGUsIG11
  >> "!B64TMP!" echo c3QgYmUgdW5kZXIKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZS4gWW91IG11c3QgaW5mb3JtIHJl
  >> "!B64TMP!" echo Y2lwaWVudHMgdGhhdCB0aGUgU291cmNlCkNvZGUgRm9ybSBvZiB0aGUgQ292ZXJlZCBTb2Z0d2Fy
  >> "!B64TMP!" echo ZSBpcyBnb3Zlcm5lZCBieSB0aGUgdGVybXMgb2YgdGhpcwpMaWNlbnNlLCBhbmQgaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2YgdGhpcyBMaWNlbnNlLiBZb3UgbWF5IG5vdAphdHRlbXB0IHRv
  >> "!B64TMP!" echo IGFsdGVyIG9yIHJlc3RyaWN0IHRoZSByZWNpcGllbnRzJyByaWdodHMgaW4gdGhlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlCkZvcm0uCgozLjIuIERpc3RyaWJ1dGlvbiBvZiBFeGVjdXRhYmxlIEZvcm0KCklmIFlvdSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIENvdmVyZWQgU29mdHdhcmUgaW4gRXhlY3V0YWJsZSBGb3JtIHRoZW46CgooYSkg
  >> "!B64TMP!" echo c3VjaCBDb3ZlcmVkIFNvZnR3YXJlIG11c3QgYWxzbyBiZSBtYWRlIGF2YWlsYWJsZSBpbiBTb3Vy
  >> "!B64TMP!" echo Y2UgQ29kZQogICAgRm9ybSwgYXMgZGVzY3JpYmVkIGluIFNlY3Rpb24gMy4xLCBhbmQgWW91IG11
  >> "!B64TMP!" echo c3QgaW5mb3JtIHJlY2lwaWVudHMgb2YKICAgIHRoZSBFeGVjdXRhYmxlIEZvcm0gaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2Ygc3VjaCBTb3VyY2UgQ29kZQogICAgRm9ybSBieSByZWFzb25h
  >> "!B64TMP!" echo YmxlIG1lYW5zIGluIGEgdGltZWx5IG1hbm5lciwgYXQgYSBjaGFyZ2Ugbm8gbW9yZQogICAgdGhh
  >> "!B64TMP!" echo biB0aGUgY29zdCBvZiBkaXN0cmlidXRpb24gdG8gdGhlIHJlY2lwaWVudDsgYW5kCgooYikgWW91
  >> "!B64TMP!" echo IG1heSBkaXN0cmlidXRlIHN1Y2ggRXhlY3V0YWJsZSBGb3JtIHVuZGVyIHRoZSB0ZXJtcyBvZiB0
  >> "!B64TMP!" echo aGlzCiAgICBMaWNlbnNlLCBvciBzdWJsaWNlbnNlIGl0IHVuZGVyIGRpZmZlcmVudCB0ZXJtcywg
  >> "!B64TMP!" echo cHJvdmlkZWQgdGhhdCB0aGUKICAgIGxpY2Vuc2UgZm9yIHRoZSBFeGVjdXRhYmxlIEZvcm0gZG9l
  >> "!B64TMP!" echo cyBub3QgYXR0ZW1wdCB0byBsaW1pdCBvciBhbHRlcgogICAgdGhlIHJlY2lwaWVudHMnIHJpZ2h0
  >> "!B64TMP!" echo cyBpbiB0aGUgU291cmNlIENvZGUgRm9ybSB1bmRlciB0aGlzIExpY2Vuc2UuCgozLjMuIERpc3Ry
  >> "!B64TMP!" echo aWJ1dGlvbiBvZiBhIExhcmdlciBXb3JrCgpZb3UgbWF5IGNyZWF0ZSBhbmQgZGlzdHJpYnV0ZSBh
  >> "!B64TMP!" echo IExhcmdlciBXb3JrIHVuZGVyIHRlcm1zIG9mIFlvdXIgY2hvaWNlLApwcm92aWRlZCB0aGF0IFlv
  >> "!B64TMP!" echo dSBhbHNvIGNvbXBseSB3aXRoIHRoZSByZXF1aXJlbWVudHMgb2YgdGhpcyBMaWNlbnNlIGZvcgp0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZS4gSWYgdGhlIExhcmdlciBXb3JrIGlzIGEgY29tYmluYXRpb24g
  >> "!B64TMP!" echo b2YgQ292ZXJlZApTb2Z0d2FyZSB3aXRoIGEgd29yayBnb3Zlcm5lZCBieSBvbmUgb3IgbW9yZSBT
  >> "!B64TMP!" echo ZWNvbmRhcnkgTGljZW5zZXMsIGFuZCB0aGUKQ292ZXJlZCBTb2Z0d2FyZSBpcyBub3QgSW5jb21w
  >> "!B64TMP!" echo YXRpYmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzLCB0aGlzCkxpY2Vuc2UgcGVybWl0cyBZb3Ug
  >> "!B64TMP!" echo dG8gYWRkaXRpb25hbGx5IGRpc3RyaWJ1dGUgc3VjaCBDb3ZlcmVkIFNvZnR3YXJlCnVuZGVyIHRo
  >> "!B64TMP!" echo ZSB0ZXJtcyBvZiBzdWNoIFNlY29uZGFyeSBMaWNlbnNlKHMpLCBzbyB0aGF0IHRoZSByZWNpcGll
  >> "!B64TMP!" echo bnQgb2YKdGhlIExhcmdlciBXb3JrIG1heSwgYXQgdGhlaXIgb3B0aW9uLCBmdXJ0aGVyIGRpc3Ry
  >> "!B64TMP!" echo aWJ1dGUgdGhlIENvdmVyZWQKU29mdHdhcmUgdW5kZXIgdGhlIHRlcm1zIG9mIGVpdGhlciB0aGlz
  >> "!B64TMP!" echo IExpY2Vuc2Ugb3Igc3VjaCBTZWNvbmRhcnkKTGljZW5zZShzKS4KCjMuNC4gTm90aWNlcwoKWW91
  >> "!B64TMP!" echo IG1heSBub3QgcmVtb3ZlIG9yIGFsdGVyIHRoZSBzdWJzdGFuY2Ugb2YgYW55IGxpY2Vuc2Ugbm90
  >> "!B64TMP!" echo aWNlcwooaW5jbHVkaW5nIGNvcHlyaWdodCBub3RpY2VzLCBwYXRlbnQgbm90aWNlcywgZGlzY2xh
  >> "!B64TMP!" echo aW1lcnMgb2Ygd2FycmFudHksCm9yIGxpbWl0YXRpb25zIG9mIGxpYWJpbGl0eSkgY29udGFpbmVk
  >> "!B64TMP!" echo IHdpdGhpbiB0aGUgU291cmNlIENvZGUgRm9ybSBvZgp0aGUgQ292ZXJlZCBTb2Z0d2FyZSwgZXhj
  >> "!B64TMP!" echo ZXB0IHRoYXQgWW91IG1heSBhbHRlciBhbnkgbGljZW5zZSBub3RpY2VzIHRvCnRoZSBleHRlbnQg
  >> "!B64TMP!" echo cmVxdWlyZWQgdG8gcmVtZWR5IGtub3duIGZhY3R1YWwgaW5hY2N1cmFjaWVzLgoKMy41LiBBcHBs
  >> "!B64TMP!" echo aWNhdGlvbiBvZiBBZGRpdGlvbmFsIFRlcm1zCgpZb3UgbWF5IGNob29zZSB0byBvZmZlciwgYW5k
  >> "!B64TMP!" echo IHRvIGNoYXJnZSBhIGZlZSBmb3IsIHdhcnJhbnR5LCBzdXBwb3J0LAppbmRlbW5pdHkgb3IgbGlh
  >> "!B64TMP!" echo YmlsaXR5IG9ibGlnYXRpb25zIHRvIG9uZSBvciBtb3JlIHJlY2lwaWVudHMgb2YgQ292ZXJlZApT
  >> "!B64TMP!" echo b2Z0d2FyZS4gSG93ZXZlciwgWW91IG1heSBkbyBzbyBvbmx5IG9uIFlvdXIgb3duIGJlaGFsZiwg
  >> "!B64TMP!" echo YW5kIG5vdCBvbgpiZWhhbGYgb2YgYW55IENvbnRyaWJ1dG9yLiBZb3UgbXVzdCBtYWtlIGl0IGFi
  >> "!B64TMP!" echo c29sdXRlbHkgY2xlYXIgdGhhdCBhbnkKc3VjaCB3YXJyYW50eSwgc3VwcG9ydCwgaW5kZW1uaXR5
  >> "!B64TMP!" echo LCBvciBsaWFiaWxpdHkgb2JsaWdhdGlvbiBpcyBvZmZlcmVkIGJ5CllvdSBhbG9uZSwgYW5kIFlv
  >> "!B64TMP!" echo dSBoZXJlYnkgYWdyZWUgdG8gaW5kZW1uaWZ5IGV2ZXJ5IENvbnRyaWJ1dG9yIGZvciBhbnkKbGlh
  >> "!B64TMP!" echo YmlsaXR5IGluY3VycmVkIGJ5IHN1Y2ggQ29udHJpYnV0b3IgYXMgYSByZXN1bHQgb2Ygd2FycmFu
  >> "!B64TMP!" echo dHksIHN1cHBvcnQsCmluZGVtbml0eSBvciBsaWFiaWxpdHkgdGVybXMgWW91IG9mZmVyLiBZb3Ug
  >> "!B64TMP!" echo bWF5IGluY2x1ZGUgYWRkaXRpb25hbApkaXNjbGFpbWVycyBvZiB3YXJyYW50eSBhbmQgbGltaXRh
  >> "!B64TMP!" echo dGlvbnMgb2YgbGlhYmlsaXR5IHNwZWNpZmljIHRvIGFueQpqdXJpc2RpY3Rpb24uCgo0LiBJbmFi
  >> "!B64TMP!" echo aWxpdHkgdG8gQ29tcGx5IER1ZSB0byBTdGF0dXRlIG9yIFJlZ3VsYXRpb24KLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpJZiBpdCBpcyBpbXBvc3Np
  >> "!B64TMP!" echo YmxlIGZvciBZb3UgdG8gY29tcGx5IHdpdGggYW55IG9mIHRoZSB0ZXJtcyBvZiB0aGlzCkxpY2Vu
  >> "!B64TMP!" echo c2Ugd2l0aCByZXNwZWN0IHRvIHNvbWUgb3IgYWxsIG9mIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIGR1
  >> "!B64TMP!" echo ZSB0bwpzdGF0dXRlLCBqdWRpY2lhbCBvcmRlciwgb3IgcmVndWxhdGlvbiB0aGVuIFlvdSBtdXN0
  >> "!B64TMP!" echo OiAoYSkgY29tcGx5IHdpdGgKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZSB0byB0aGUgbWF4aW11
  >> "!B64TMP!" echo bSBleHRlbnQgcG9zc2libGU7IGFuZCAoYikKZGVzY3JpYmUgdGhlIGxpbWl0YXRpb25zIGFuZCB0
  >> "!B64TMP!" echo aGUgY29kZSB0aGV5IGFmZmVjdC4gU3VjaCBkZXNjcmlwdGlvbiBtdXN0CmJlIHBsYWNlZCBpbiBh
  >> "!B64TMP!" echo IHRleHQgZmlsZSBpbmNsdWRlZCB3aXRoIGFsbCBkaXN0cmlidXRpb25zIG9mIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo ClNvZnR3YXJlIHVuZGVyIHRoaXMgTGljZW5zZS4gRXhjZXB0IHRvIHRoZSBleHRlbnQgcHJvaGli
  >> "!B64TMP!" echo aXRlZCBieSBzdGF0dXRlCm9yIHJlZ3VsYXRpb24sIHN1Y2ggZGVzY3JpcHRpb24gbXVzdCBiZSBz
  >> "!B64TMP!" echo dWZmaWNpZW50bHkgZGV0YWlsZWQgZm9yIGEKcmVjaXBpZW50IG9mIG9yZGluYXJ5IHNraWxsIHRv
  >> "!B64TMP!" echo IGJlIGFibGUgdG8gdW5kZXJzdGFuZCBpdC4KCjUuIFRlcm1pbmF0aW9uCi0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo Cgo1LjEuIFRoZSByaWdodHMgZ3JhbnRlZCB1bmRlciB0aGlzIExpY2Vuc2Ugd2lsbCB0ZXJtaW5h
  >> "!B64TMP!" echo dGUgYXV0b21hdGljYWxseQppZiBZb3UgZmFpbCB0byBjb21wbHkgd2l0aCBhbnkgb2YgaXRzIHRl
  >> "!B64TMP!" echo cm1zLiBIb3dldmVyLCBpZiBZb3UgYmVjb21lCmNvbXBsaWFudCwgdGhlbiB0aGUgcmlnaHRzIGdy
  >> "!B64TMP!" echo YW50ZWQgdW5kZXIgdGhpcyBMaWNlbnNlIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIChhKSBwcm92aXNpb25hbGx5LCB1bmxlc3MgYW5kIHVudGlsIHN1Y2gKQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgZXhwbGljaXRseSBhbmQgZmluYWxseSB0ZXJtaW5hdGVzIFlvdXIgZ3JhbnRzLCBh
  >> "!B64TMP!" echo bmQgKGIpIG9uIGFuCm9uZ29pbmcgYmFzaXMsIGlmIHN1Y2ggQ29udHJpYnV0b3IgZmFpbHMgdG8g
  >> "!B64TMP!" echo bm90aWZ5IFlvdSBvZiB0aGUKbm9uLWNvbXBsaWFuY2UgYnkgc29tZSByZWFzb25hYmxlIG1lYW5z
  >> "!B64TMP!" echo IHByaW9yIHRvIDYwIGRheXMgYWZ0ZXIgWW91IGhhdmUKY29tZSBiYWNrIGludG8gY29tcGxpYW5j
  >> "!B64TMP!" echo ZS4gTW9yZW92ZXIsIFlvdXIgZ3JhbnRzIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIG9uIGFuIG9uZ29pbmcgYmFzaXMgaWYgc3VjaCBDb250cmlidXRvcgpub3Rp
  >> "!B64TMP!" echo ZmllcyBZb3Ugb2YgdGhlIG5vbi1jb21wbGlhbmNlIGJ5IHNvbWUgcmVhc29uYWJsZSBtZWFucywg
  >> "!B64TMP!" echo dGhpcyBpcyB0aGUKZmlyc3QgdGltZSBZb3UgaGF2ZSByZWNlaXZlZCBub3RpY2Ugb2Ygbm9uLWNv
  >> "!B64TMP!" echo bXBsaWFuY2Ugd2l0aCB0aGlzIExpY2Vuc2UKZnJvbSBzdWNoIENvbnRyaWJ1dG9yLCBhbmQgWW91
  >> "!B64TMP!" echo IGJlY29tZSBjb21wbGlhbnQgcHJpb3IgdG8gMzAgZGF5cyBhZnRlcgpZb3VyIHJlY2VpcHQgb2Yg
  >> "!B64TMP!" echo dGhlIG5vdGljZS4KCjUuMi4gSWYgWW91IGluaXRpYXRlIGxpdGlnYXRpb24gYWdhaW5zdCBhbnkg
  >> "!B64TMP!" echo ZW50aXR5IGJ5IGFzc2VydGluZyBhIHBhdGVudAppbmZyaW5nZW1lbnQgY2xhaW0gKGV4Y2x1ZGlu
  >> "!B64TMP!" echo ZyBkZWNsYXJhdG9yeSBqdWRnbWVudCBhY3Rpb25zLApjb3VudGVyLWNsYWltcywgYW5kIGNyb3Nz
  >> "!B64TMP!" echo LWNsYWltcykgYWxsZWdpbmcgdGhhdCBhIENvbnRyaWJ1dG9yIFZlcnNpb24KZGlyZWN0bHkgb3Ig
  >> "!B64TMP!" echo aW5kaXJlY3RseSBpbmZyaW5nZXMgYW55IHBhdGVudCwgdGhlbiB0aGUgcmlnaHRzIGdyYW50ZWQg
  >> "!B64TMP!" echo dG8KWW91IGJ5IGFueSBhbmQgYWxsIENvbnRyaWJ1dG9ycyBmb3IgdGhlIENvdmVyZWQgU29mdHdh
  >> "!B64TMP!" echo cmUgdW5kZXIgU2VjdGlvbgoyLjEgb2YgdGhpcyBMaWNlbnNlIHNoYWxsIHRlcm1pbmF0ZS4KCjUu
  >> "!B64TMP!" echo My4gSW4gdGhlIGV2ZW50IG9mIHRlcm1pbmF0aW9uIHVuZGVyIFNlY3Rpb25zIDUuMSBvciA1LjIg
  >> "!B64TMP!" echo YWJvdmUsIGFsbAplbmQgdXNlciBsaWNlbnNlIGFncmVlbWVudHMgKGV4Y2x1ZGluZyBkaXN0cmli
  >> "!B64TMP!" echo dXRvcnMgYW5kIHJlc2VsbGVycykgd2hpY2gKaGF2ZSBiZWVuIHZhbGlkbHkgZ3JhbnRlZCBieSBZ
  >> "!B64TMP!" echo b3Ugb3IgWW91ciBkaXN0cmlidXRvcnMgdW5kZXIgdGhpcyBMaWNlbnNlCnByaW9yIHRvIHRlcm1p
  >> "!B64TMP!" echo bmF0aW9uIHNoYWxsIHN1cnZpdmUgdGVybWluYXRpb24uCgoqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioKKiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAqCiogIDYuIERpc2NsYWltZXIgb2YgV2FycmFudHkgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgKgoqICAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIENvdmVyZWQgU29mdHdhcmUgaXMgcHJvdmlkZWQgdW5kZXIgdGhpcyBMaWNlbnNlIG9uIGFu
  >> "!B64TMP!" echo ICJhcyBpcyIgICAgICAgKgoqICBiYXNpcywgd2l0aG91dCB3YXJyYW50eSBvZiBhbnkga2luZCwg
  >> "!B64TMP!" echo ZWl0aGVyIGV4cHJlc3NlZCwgaW1wbGllZCwgb3IgICoKKiAgc3RhdHV0b3J5LCBpbmNsdWRpbmcs
  >> "!B64TMP!" echo IHdpdGhvdXQgbGltaXRhdGlvbiwgd2FycmFudGllcyB0aGF0IHRoZSAgICAgICAqCiogIENvdmVy
  >> "!B64TMP!" echo ZWQgU29mdHdhcmUgaXMgZnJlZSBvZiBkZWZlY3RzLCBtZXJjaGFudGFibGUsIGZpdCBmb3IgYSAg
  >> "!B64TMP!" echo ICAgICAgKgoqICBwYXJ0aWN1bGFyIHB1cnBvc2Ugb3Igbm9uLWluZnJpbmdpbmcuIFRoZSBlbnRp
  >> "!B64TMP!" echo cmUgcmlzayBhcyB0byB0aGUgICAgICoKKiAgcXVhbGl0eSBhbmQgcGVyZm9ybWFuY2Ugb2YgdGhl
  >> "!B64TMP!" echo IENvdmVyZWQgU29mdHdhcmUgaXMgd2l0aCBZb3UuICAgICAgICAqCiogIFNob3VsZCBhbnkgQ292
  >> "!B64TMP!" echo ZXJlZCBTb2Z0d2FyZSBwcm92ZSBkZWZlY3RpdmUgaW4gYW55IHJlc3BlY3QsIFlvdSAgICAgKgoq
  >> "!B64TMP!" echo ICAobm90IGFueSBDb250cmlidXRvcikgYXNzdW1lIHRoZSBjb3N0IG9mIGFueSBuZWNlc3Nhcnkg
  >> "!B64TMP!" echo c2VydmljaW5nLCAgICoKKiAgcmVwYWlyLCBvciBjb3JyZWN0aW9uLiBUaGlzIGRpc2NsYWltZXIg
  >> "!B64TMP!" echo b2Ygd2FycmFudHkgY29uc3RpdHV0ZXMgYW4gICAqCiogIGVzc2VudGlhbCBwYXJ0IG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZS4gTm8gdXNlIG9mIGFueSBDb3ZlcmVkIFNvZnR3YXJlIGlzICAgKgoqICBhdXRob3Jp
  >> "!B64TMP!" echo emVkIHVuZGVyIHRoaXMgTGljZW5zZSBleGNlcHQgdW5kZXIgdGhpcyBkaXNjbGFpbWVyLiAgICAg
  >> "!B64TMP!" echo ICAgICoKKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAqCioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKgoKKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCiog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgKgoqICA3LiBMaW1pdGF0aW9uIG9mIExpYWJpbGl0eSAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAqCiogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgKgoqICBVbmRlciBubyBjaXJjdW1zdGFuY2VzIGFuZCB1bmRlciBubyBsZWdhbCB0aGVvcnks
  >> "!B64TMP!" echo IHdoZXRoZXIgdG9ydCAgICAgICoKKiAgKGluY2x1ZGluZyBuZWdsaWdlbmNlKSwgY29udHJhY3Qs
  >> "!B64TMP!" echo IG9yIG90aGVyd2lzZSwgc2hhbGwgYW55ICAgICAgICAgICAqCiogIENvbnRyaWJ1dG9yLCBvciBh
  >> "!B64TMP!" echo bnlvbmUgd2hvIGRpc3RyaWJ1dGVzIENvdmVyZWQgU29mdHdhcmUgYXMgICAgICAgICAgKgoqICBw
  >> "!B64TMP!" echo ZXJtaXR0ZWQgYWJvdmUsIGJlIGxpYWJsZSB0byBZb3UgZm9yIGFueSBkaXJlY3QsIGluZGlyZWN0
  >> "!B64TMP!" echo LCAgICAgICAgICoKKiAgc3BlY2lhbCwgaW5jaWRlbnRhbCwgb3IgY29uc2VxdWVudGlhbCBkYW1h
  >> "!B64TMP!" echo Z2VzIG9mIGFueSBjaGFyYWN0ZXIgICAgICAqCiogIGluY2x1ZGluZywgd2l0aG91dCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLCBkYW1hZ2VzIGZvciBsb3N0IHByb2ZpdHMsIGxvc3Mgb2YgICAgKgoqICBnb29kd2lsbCwg
  >> "!B64TMP!" echo d29yayBzdG9wcGFnZSwgY29tcHV0ZXIgZmFpbHVyZSBvciBtYWxmdW5jdGlvbiwgb3IgYW55ICAg
  >> "!B64TMP!" echo ICoKKiAgYW5kIGFsbCBvdGhlciBjb21tZXJjaWFsIGRhbWFnZXMgb3IgbG9zc2VzLCBldmVuIGlm
  >> "!B64TMP!" echo IHN1Y2ggcGFydHkgICAgICAqCiogIHNoYWxsIGhhdmUgYmVlbiBpbmZvcm1lZCBvZiB0aGUgcG9z
  >> "!B64TMP!" echo c2liaWxpdHkgb2Ygc3VjaCBkYW1hZ2VzLiBUaGlzICAgKgoqICBsaW1pdGF0aW9uIG9mIGxpYWJp
  >> "!B64TMP!" echo bGl0eSBzaGFsbCBub3QgYXBwbHkgdG8gbGlhYmlsaXR5IGZvciBkZWF0aCBvciAgICoKKiAgcGVy
  >> "!B64TMP!" echo c29uYWwgaW5qdXJ5IHJlc3VsdGluZyBmcm9tIHN1Y2ggcGFydHkncyBuZWdsaWdlbmNlIHRvIHRo
  >> "!B64TMP!" echo ZSAgICAgICAqCiogIGV4dGVudCBhcHBsaWNhYmxlIGxhdyBwcm9oaWJpdHMgc3VjaCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLiBTb21lICAgICAgICAgICAgICAgKgoqICBqdXJpc2RpY3Rpb25zIGRvIG5vdCBhbGxvdyB0
  >> "!B64TMP!" echo aGUgZXhjbHVzaW9uIG9yIGxpbWl0YXRpb24gb2YgICAgICAgICAgICoKKiAgaW5jaWRlbnRhbCBv
  >> "!B64TMP!" echo ciBjb25zZXF1ZW50aWFsIGRhbWFnZXMsIHNvIHRoaXMgZXhjbHVzaW9uIGFuZCAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIGxpbWl0YXRpb24gbWF5IG5vdCBhcHBseSB0byBZb3UuICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgKgoqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCgo4LiBMaXRp
  >> "!B64TMP!" echo Z2F0aW9uCi0tLS0tLS0tLS0tLS0KCkFueSBsaXRpZ2F0aW9uIHJlbGF0aW5nIHRvIHRoaXMgTGlj
  >> "!B64TMP!" echo ZW5zZSBtYXkgYmUgYnJvdWdodCBvbmx5IGluIHRoZQpjb3VydHMgb2YgYSBqdXJpc2RpY3Rpb24g
  >> "!B64TMP!" echo d2hlcmUgdGhlIGRlZmVuZGFudCBtYWludGFpbnMgaXRzIHByaW5jaXBhbApwbGFjZSBvZiBidXNp
  >> "!B64TMP!" echo bmVzcyBhbmQgc3VjaCBsaXRpZ2F0aW9uIHNoYWxsIGJlIGdvdmVybmVkIGJ5IGxhd3Mgb2YgdGhh
  >> "!B64TMP!" echo dApqdXJpc2RpY3Rpb24sIHdpdGhvdXQgcmVmZXJlbmNlIHRvIGl0cyBjb25mbGljdC1vZi1sYXcg
  >> "!B64TMP!" echo cHJvdmlzaW9ucy4KTm90aGluZyBpbiB0aGlzIFNlY3Rpb24gc2hhbGwgcHJldmVudCBhIHBhcnR5
  >> "!B64TMP!" echo J3MgYWJpbGl0eSB0byBicmluZwpjcm9zcy1jbGFpbXMgb3IgY291bnRlci1jbGFpbXMuCgo5LiBN
  >> "!B64TMP!" echo aXNjZWxsYW5lb3VzCi0tLS0tLS0tLS0tLS0tLS0KClRoaXMgTGljZW5zZSByZXByZXNlbnRzIHRo
  >> "!B64TMP!" echo ZSBjb21wbGV0ZSBhZ3JlZW1lbnQgY29uY2VybmluZyB0aGUgc3ViamVjdAptYXR0ZXIgaGVyZW9m
  >> "!B64TMP!" echo LiBJZiBhbnkgcHJvdmlzaW9uIG9mIHRoaXMgTGljZW5zZSBpcyBoZWxkIHRvIGJlCnVuZW5mb3Jj
  >> "!B64TMP!" echo ZWFibGUsIHN1Y2ggcHJvdmlzaW9uIHNoYWxsIGJlIHJlZm9ybWVkIG9ubHkgdG8gdGhlIGV4dGVu
  >> "!B64TMP!" echo dApuZWNlc3NhcnkgdG8gbWFrZSBpdCBlbmZvcmNlYWJsZS4gQW55IGxhdyBvciByZWd1bGF0aW9u
  >> "!B64TMP!" echo IHdoaWNoIHByb3ZpZGVzCnRoYXQgdGhlIGxhbmd1YWdlIG9mIGEgY29udHJhY3Qgc2hhbGwgYmUg
  >> "!B64TMP!" echo Y29uc3RydWVkIGFnYWluc3QgdGhlIGRyYWZ0ZXIKc2hhbGwgbm90IGJlIHVzZWQgdG8gY29uc3Ry
  >> "!B64TMP!" echo dWUgdGhpcyBMaWNlbnNlIGFnYWluc3QgYSBDb250cmlidXRvci4KCjEwLiBWZXJzaW9ucyBvZiB0
  >> "!B64TMP!" echo aGUgTGljZW5zZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCjEwLjEuIE5ldyBWZXJzaW9u
  >> "!B64TMP!" echo cwoKTW96aWxsYSBGb3VuZGF0aW9uIGlzIHRoZSBsaWNlbnNlIHN0ZXdhcmQuIEV4Y2VwdCBhcyBw
  >> "!B64TMP!" echo cm92aWRlZCBpbiBTZWN0aW9uCjEwLjMsIG5vIG9uZSBvdGhlciB0aGFuIHRoZSBsaWNlbnNlIHN0
  >> "!B64TMP!" echo ZXdhcmQgaGFzIHRoZSByaWdodCB0byBtb2RpZnkgb3IKcHVibGlzaCBuZXcgdmVyc2lvbnMgb2Yg
  >> "!B64TMP!" echo dGhpcyBMaWNlbnNlLiBFYWNoIHZlcnNpb24gd2lsbCBiZSBnaXZlbiBhCmRpc3Rpbmd1aXNoaW5n
  >> "!B64TMP!" echo IHZlcnNpb24gbnVtYmVyLgoKMTAuMi4gRWZmZWN0IG9mIE5ldyBWZXJzaW9ucwoKWW91IG1heSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHVuZGVyIHRoZSB0ZXJtcyBvZiB0aGUgdmVy
  >> "!B64TMP!" echo c2lvbgpvZiB0aGUgTGljZW5zZSB1bmRlciB3aGljaCBZb3Ugb3JpZ2luYWxseSByZWNlaXZlZCB0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZSwKb3IgdW5kZXIgdGhlIHRlcm1zIG9mIGFueSBzdWJzZXF1ZW50
  >> "!B64TMP!" echo IHZlcnNpb24gcHVibGlzaGVkIGJ5IHRoZSBsaWNlbnNlCnN0ZXdhcmQuCgoxMC4zLiBNb2RpZmll
  >> "!B64TMP!" echo ZCBWZXJzaW9ucwoKSWYgeW91IGNyZWF0ZSBzb2Z0d2FyZSBub3QgZ292ZXJuZWQgYnkgdGhpcyBM
  >> "!B64TMP!" echo aWNlbnNlLCBhbmQgeW91IHdhbnQgdG8KY3JlYXRlIGEgbmV3IGxpY2Vuc2UgZm9yIHN1Y2ggc29m
  >> "!B64TMP!" echo dHdhcmUsIHlvdSBtYXkgY3JlYXRlIGFuZCB1c2UgYQptb2RpZmllZCB2ZXJzaW9uIG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZSBpZiB5b3UgcmVuYW1lIHRoZSBsaWNlbnNlIGFuZCByZW1vdmUKYW55IHJlZmVyZW5j
  >> "!B64TMP!" echo ZXMgdG8gdGhlIG5hbWUgb2YgdGhlIGxpY2Vuc2Ugc3Rld2FyZCAoZXhjZXB0IHRvIG5vdGUgdGhh
  >> "!B64TMP!" echo dApzdWNoIG1vZGlmaWVkIGxpY2Vuc2UgZGlmZmVycyBmcm9tIHRoaXMgTGljZW5zZSkuCgoxMC40
  >> "!B64TMP!" echo LiBEaXN0cmlidXRpbmcgU291cmNlIENvZGUgRm9ybSB0aGF0IGlzIEluY29tcGF0aWJsZSBXaXRo
  >> "!B64TMP!" echo IFNlY29uZGFyeQpMaWNlbnNlcwoKSWYgWW91IGNob29zZSB0byBkaXN0cmlidXRlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlIEZvcm0gdGhhdCBpcyBJbmNvbXBhdGlibGUgV2l0aApTZWNvbmRhcnkgTGljZW5zZXMgdW5k
  >> "!B64TMP!" echo ZXIgdGhlIHRlcm1zIG9mIHRoaXMgdmVyc2lvbiBvZiB0aGUgTGljZW5zZSwgdGhlCm5vdGljZSBk
  >> "!B64TMP!" echo ZXNjcmliZWQgaW4gRXhoaWJpdCBCIG9mIHRoaXMgTGljZW5zZSBtdXN0IGJlIGF0dGFjaGVkLgoK
  >> "!B64TMP!" echo RXhoaWJpdCBBIC0gU291cmNlIENvZGUgRm9ybSBMaWNlbnNlIE5vdGljZQotLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBp
  >> "!B64TMP!" echo cyBzdWJqZWN0IHRvIHRoZSB0ZXJtcyBvZiB0aGUgTW96aWxsYSBQdWJsaWMKICBMaWNlbnNlLCB2
  >> "!B64TMP!" echo LiAyLjAuIElmIGEgY29weSBvZiB0aGUgTVBMIHdhcyBub3QgZGlzdHJpYnV0ZWQgd2l0aCB0aGlz
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHA6Ly9tb3ppbGxhLm9yZy9NUEwvMi4w
  >> "!B64TMP!" echo Ly4KCklmIGl0IGlzIG5vdCBwb3NzaWJsZSBvciBkZXNpcmFibGUgdG8gcHV0IHRoZSBub3RpY2Ug
  >> "!B64TMP!" echo aW4gYSBwYXJ0aWN1bGFyCmZpbGUsIHRoZW4gWW91IG1heSBpbmNsdWRlIHRoZSBub3RpY2UgaW4g
  >> "!B64TMP!" echo YSBsb2NhdGlvbiAoc3VjaCBhcyBhIExJQ0VOU0UKZmlsZSBpbiBhIHJlbGV2YW50IGRpcmVjdG9y
  >> "!B64TMP!" echo eSkgd2hlcmUgYSByZWNpcGllbnQgd291bGQgYmUgbGlrZWx5IHRvIGxvb2sKZm9yIHN1Y2ggYSBu
  >> "!B64TMP!" echo b3RpY2UuCgpZb3UgbWF5IGFkZCBhZGRpdGlvbmFsIGFjY3VyYXRlIG5vdGljZXMgb2YgY29weXJp
  >> "!B64TMP!" echo Z2h0IG93bmVyc2hpcC4KCkV4aGliaXQgQiAtICJJbmNvbXBhdGlibGUgV2l0aCBTZWNvbmRhcnkg
  >> "!B64TMP!" echo TGljZW5zZXMiIE5vdGljZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KCiAgVGhpcyBTb3VyY2UgQ29kZSBGb3JtIGlzICJJbmNvbXBhdGli
  >> "!B64TMP!" echo bGUgV2l0aCBTZWNvbmRhcnkgTGljZW5zZXMiLCBhcwogIGRlZmluZWQgYnkgdGhlIE1vemlsbGEg
  >> "!B64TMP!" echo UHVibGljIExpY2Vuc2UsIHYuIDIuMC4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\LICENSE"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/config.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\config.py" (
  copy /Y "!SRC!\local-web\scripts\config.py" "!TARGET!\local-web\scripts\config.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\config.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/config.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS181580220.b64"
  > "!B64TMP!" echo IiIiU2hhcmVkIGhlbHBlcnMgZm9yIHRoZSBsb2NhbC13ZWIgc2NyaXB0czogbG9jYXRpbmcgdGhl
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaAppbnN0YWxsIGZvbGRlciBhbmQgdGhlIGVuZHBvaW50cyBpdCBpcyBhY3R1
  >> "!B64TMP!" echo YWxseSBsaXN0ZW5pbmcgb24uCgpUaGUgcG9ydHMgYXJlIE5PVCBhc3N1bWVkOiB0aGV5IGFyZSBy
  >> "!B64TMP!" echo ZWFkIGZyb20gdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudgpmaWxlICh0aGUgc2FtZSBvbmUgdGhl
  >> "!B64TMP!" echo IGNvbXBvc2Ugc2V0dXAgYW5kIFJ1bi5iYXQgLyBVcGRhdGUuYmF0IHVzZSksIHNvIGlmCnRoZSB1
  >> "!B64TMP!" echo c2VyIHBpY2tlZCBjdXN0b20gcG9ydHMgZHVyaW5nIHNldHVwLCBldmVyeSBzY3JpcHQgZm9sbG93
  >> "!B64TMP!" echo cyB0aGVtLgpEZWZhdWx0cyBtaXJyb3IgdGhlIGNvbXBvc2UgZmlsZSdzICR7VkFSOi1kZWZhdWx0
  >> "!B64TMP!" echo fSBmYWxsYmFja3M6ClNlYXJYTkcgOTk5MCwgRmlyZWNyYXdsIDk5OTEuCiIiIgppbXBvcnQgb3MK
  >> "!B64TMP!" echo aW1wb3J0IHN1YnByb2Nlc3MKCiMgQ29tcG9zZSBmaWxlIG5hbWVzIGFjY2VwdGVkIGFzICJ0aGlz
  >> "!B64TMP!" echo IGlzIHRoZSBpbnN0YWxsIGZvbGRlciIuCl9DT01QT1NFX0ZJTEVTID0gKCJkb2NrZXItY29tcG9z
  >> "!B64TMP!" echo ZS55bWwiLCAiZG9ja2VyLWNvbXBvc2UueWFtbCIsCiAgICAgICAgICAgICAgICAgICJjb21wb3Nl
  >> "!B64TMP!" echo LnltbCIsICJjb21wb3NlLnlhbWwiKQoKIyAuZW52IGtleSAtPiBkZWZhdWx0IHBvcnQgKG1hdGNo
  >> "!B64TMP!" echo ZXMgdGhlIGRlZmF1bHRzIGluIGRvY2tlci1jb21wb3NlLnltbCkuCl9QT1JUX0tFWVMgPSB7CiAg
  >> "!B64TMP!" echo ICAic2VhcnhuZyI6ICgiU0VBUlhOR19QT1JUIiwgIjk5OTAiKSwKICAgICJmaXJlY3Jhd2wiOiAo
  >> "!B64TMP!" echo IkZJUkVDUkFXTF9QT1JUIiwgIjk5OTEiKSwKfQoKCmRlZiBfaGFzX2NvbXBvc2VfZmlsZShkKToK
  >> "!B64TMP!" echo ICAgIHJldHVybiBkIGlzIG5vdCBOb25lIGFuZCBhbnkoCiAgICAgICAgb3MucGF0aC5pc2ZpbGUo
  >> "!B64TMP!" echo b3MucGF0aC5qb2luKGQsIGYpKSBmb3IgZiBpbiBfQ09NUE9TRV9GSUxFUwogICAgKQoKCmRlZiBf
  >> "!B64TMP!" echo ZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlciBw
  >> "!B64TMP!" echo ZXIgdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMuIENvbXBvc2UKICAgIHRhZ3Mg
  >> "!B64TMP!" echo ZWFjaCBjb250YWluZXIgd2l0aCB0aGUgZGlyZWN0b3J5IGl0IHdhcyBzdGFydGVkIGZyb20sIHNv
  >> "!B64TMP!" echo IHRoaXMKICAgIGZpbmRzIHRoZSBmb2xkZXIgZXZlbiB0aG91Z2ggdGhlIHNraWxsIGl0c2VsZiBs
  >> "!B64TMP!" echo aXZlcyBlbHNld2hlcmUuIFRoZQogICAgRG9ja2VyIGVuZ2luZSBtdXN0IGJlIHJ1bm5pbmcuIiIi
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgcmVzID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsiZG9j
  >> "!B64TMP!" echo a2VyIiwgImNvbnRhaW5lciIsICJscyIsICItYSIsICItcSIsCiAgICAgICAgICAgICAiLS1maWx0
  >> "!B64TMP!" echo ZXIiLCAibGFiZWw9Y29tLmRvY2tlci5jb21wb3NlLnNlcnZpY2U9c2VhcnhuZyJdLAogICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCB0
  >> "!B64TMP!" echo ZXh0PVRydWUpCiAgICAgICAgaWRzID0gcmVzLnN0ZG91dC5zcGxpdCgpWzozXQogICAgZXhjZXB0
  >> "!B64TMP!" echo IChPU0Vycm9yLCBGaWxlTm90Rm91bmRFcnJvcik6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIGZv
  >> "!B64TMP!" echo ciBjaWQgaW4gaWRzOgogICAgICAgIHRyeToKICAgICAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5y
  >> "!B64TMP!" echo dW4oCiAgICAgICAgICAgICAgICBbImRvY2tlciIsICJjb250YWluZXIiLCAiaW5zcGVjdCIsIGNp
  >> "!B64TMP!" echo ZCwKICAgICAgICAgICAgICAgICAiLS1mb3JtYXQiLAogICAgICAgICAgICAgICAgICd7e2luZGV4
  >> "!B64TMP!" echo IC5Db25maWcuTGFiZWxzICJjb20uZG9ja2VyLmNvbXBvc2UucHJvamVjdC53b3JraW5nX2RpciJ9
  >> "!B64TMP!" echo fSddLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuUElQRSwgc3RkZXJyPXN1YnBy
  >> "!B64TMP!" echo b2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgIGV4Y2VwdCAoT1NFcnJvciwgRmlsZU5v
  >> "!B64TMP!" echo dEZvdW5kRXJyb3IpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHAgPSBvdXQuc3Rkb3V0
  >> "!B64TMP!" echo LnN0cmlwKCkKICAgICAgICBpZiBwIGFuZCBvcy5wYXRoLmlzZGlyKHApOgogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpkZWYgX2hpbnRlZF9pbnN0YWxsX2RpcigpOgogICAg
  >> "!B64TMP!" echo IiIiVGhlIGluc3RhbGwgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGxl
  >> "!B64TMP!" echo ciB3aGVuIGl0CiAgICBjb3BpZWQgdGhpcyBza2lsbCAoaW5zdGFsbC1kaXIudHh0IG5leHQgdG8g
  >> "!B64TMP!" echo U0tJTEwubWQpLiBUaGlzIHdvcmtzIGV2ZW4KICAgIHdoZW4gdGhlIERvY2tlciBlbmdpbmUgaXMg
  >> "!B64TMP!" echo ZG93biBhbmQgdGhlIGluc3RhbGwgZm9sZGVyIGlzIG5vdCBpbiB0aGUKICAgIGRlZmF1bHQgbG9j
  >> "!B64TMP!" echo YXRpb24uIFJldHVybnMgTm9uZSB3aGVuIHRoZXJlIGlzIG5vIGhpbnQgZmlsZSAoZS5nLiB0aGUK
  >> "!B64TMP!" echo ICAgIHNraWxsIHdhcyBpbnN0YWxsZWQgc3RhbmRhbG9uZSBmcm9tIHRoZSBsb2NhbC13ZWIgcmVw
  >> "!B64TMP!" echo bykuIiIiCiAgICBoaW50X2ZpbGUgPSBvcy5wYXRoLmpvaW4ob3MucGF0aC5kaXJuYW1lKG9zLnBh
  >> "!B64TMP!" echo dGguYWJzcGF0aChfX2ZpbGVfXykpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9zLnBh
  >> "!B64TMP!" echo cmRpciwgImluc3RhbGwtZGlyLnR4dCIpCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKGhpbnRf
  >> "!B64TMP!" echo ZmlsZSwgZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgICAgIHBhdGggPSBmaC5yZWFk
  >> "!B64TMP!" echo KCkuc3RyaXAoKS5yc3RyaXAoIlxcLyIpLnN0cmlwKCkKICAgICAgICByZXR1cm4gcGF0aCBvciBO
  >> "!B64TMP!" echo b25lCiAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gTm9uZQoKCmRlZiBmaW5kX2lu
  >> "!B64TMP!" echo c3RhbGxfZGlyKCk6CiAgICAiIiJUaGUgbG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyIChob2xk
  >> "!B64TMP!" echo cyB0aGUgY29tcG9zZSBmaWxlKSwgb3IgTm9uZS4KCiAgICBMb29rZWQgdXAgaW4gb3JkZXI6CiAg
  >> "!B64TMP!" echo ICAgIDEuIHRoZSBMT0NBTF9TRUFSQ0hfRElSIGVudiB2YXIgKGV4cGxpY2l0IG92ZXJyaWRlKSwK
  >> "!B64TMP!" echo ICAgICAgMi4gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMgKGVuZ2luZSBtdXN0
  >> "!B64TMP!" echo IGJlIHJ1bm5pbmcpLAogICAgICAzLiBpbnN0YWxsLWRpci50eHQgcmVjb3JkZWQgYnkgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBpbnN0YWxsZXIsCiAgICAgIDQuIH4vbG9jYWwtc2VhcmNoICh0aGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyJ3MgZGVmYXVsdCBsb2NhdGlvbikuCiAgICAiIiIKICAgIGZvciBkIGluIChvcy5lbnZpcm9u
  >> "!B64TMP!" echo LmdldCgiTE9DQUxfU0VBUkNIX0RJUiIpLAogICAgICAgICAgICAgIF9kb2NrZXJfbGFiZWxlZF9p
  >> "!B64TMP!" echo bnN0YWxsX2RpcigpLAogICAgICAgICAgICAgIF9oaW50ZWRfaW5zdGFsbF9kaXIoKSwKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBvcy5wYXRoLmV4cGFuZHVzZXIoIn4vbG9jYWwtc2VhcmNoIikpOgogICAgICAgIGlm
  >> "!B64TMP!" echo IGQgYW5kIF9oYXNfY29tcG9zZV9maWxlKGQpOgogICAgICAgICAgICByZXR1cm4gZAogICAgcmV0
  >> "!B64TMP!" echo dXJuIE5vbmUKCgpkZWYgbG9hZF9lbnYoaW5zdGFsbF9kaXIpOgogICAgIiIiVGhlIGluc3RhbGwg
  >> "!B64TMP!" echo Zm9sZGVyJ3MgLmVudiBhcyBhIGRpY3QgKGVtcHR5IGRpY3QgaWYgbWlzc2luZy9pbnZhbGlkKS4i
  >> "!B64TMP!" echo IiIKICAgIHZhbHVlcyA9IHt9CiAgICBpZiBub3QgaW5zdGFsbF9kaXI6CiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IHZhbHVlcwogICAgdHJ5OgogICAgICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIsICIuZW52IiksIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgogICAgICAgICAgICBmb3IgbGlu
  >> "!B64TMP!" echo ZSBpbiBmaDoKICAgICAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpIG9yICI9IiBub3QgaW4gbGlu
  >> "!B64TMP!" echo ZToKICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAga2V5LCBfLCB2
  >> "!B64TMP!" echo YWwgPSBsaW5lLnBhcnRpdGlvbigiPSIpCiAgICAgICAgICAgICAgICB2YWx1ZXNba2V5LnN0cmlw
  >> "!B64TMP!" echo KCldID0gdmFsLnN0cmlwKCkuc3RyaXAoJyInKS5zdHJpcCgiJyIpCiAgICBleGNlcHQgT1NFcnJv
  >> "!B64TMP!" echo cjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gdmFsdWVzCgoKZGVmIGVuZHBvaW50cyhpbnN0YWxs
  >> "!B64TMP!" echo X2Rpcj1Ob25lKToKICAgICIiInsnc2VhcnhuZyc6ICdodHRwOi8vbG9jYWxob3N0Ojxwb3J0Pics
  >> "!B64TMP!" echo ICdmaXJlY3Jhd2wnOiAnLi4uJ30sIHdpdGggdGhlCiAgICBwb3J0cyB0YWtlbiBmcm9tIHRoZSBp
  >> "!B64TMP!" echo bnN0YWxsIGZvbGRlcidzIC5lbnYgKGRlZmF1bHRzIDk5OTAvOTk5MSkuIiIiCiAgICB2YWx1ZXMg
  >> "!B64TMP!" echo PSBsb2FkX2VudihpbnN0YWxsX2RpcikKICAgIHVybHMgPSB7fQogICAgZm9yIG5hbWUsIChrZXks
  >> "!B64TMP!" echo IGRlZmF1bHQpIGluIF9QT1JUX0tFWVMuaXRlbXMoKToKICAgICAgICBwb3J0ID0gdmFsdWVzLmdl
  >> "!B64TMP!" echo dChrZXkpCiAgICAgICAgaWYgbm90IHBvcnQgb3Igbm90IHBvcnQuaXNkaWdpdCgpOgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwb3J0ID0gZGVmYXVsdAogICAgICAgIHVybHNbbmFtZV0gPSAiaHR0cDovL2xvY2FsaG9z
  >> "!B64TMP!" echo dDp7fSIuZm9ybWF0KHBvcnQpCiAgICByZXR1cm4gdXJscwo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\config.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/ensure_stack.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\ensure_stack.py" (
  copy /Y "!SRC!\local-web\scripts\ensure_stack.py" "!TARGET!\local-web\scripts\ensure_stack.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\ensure_stack.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/ensure_stack.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS58012418.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFbnN1cmUgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBp
  >> "!B64TMP!" echo cyBydW5uaW5nIGJlZm9yZSBhbnkgd2ViIHJlc2VhcmNoLgoKVHdvIHdheXMgdG8gdXNlIGl0OgoK
  >> "!B64TMP!" echo ICAxLiBBcyBhIENMSSBwcmUtZmxpZ2h0IGNoZWNrIChPUFRJT05BTCDigJQgdGhlIG90aGVyIHNj
  >> "!B64TMP!" echo cmlwdHMgc2VsZi1oZWFsKToKICAgICAgICAgcHl0aG9uIGVuc3VyZV9zdGFjay5weSBbLS1jaGVj
  >> "!B64TMP!" echo a10KICAgICBFeGl0IGNvZGVzOiAwIHJlYWR5LCAxIGRvd24gLyBjb3VsZCBub3QgYmUgYnJvdWdo
  >> "!B64TMP!" echo dCB1cCwgMiBwcmVyZXF1aXNpdGVzCiAgICAgbWlzc2luZyAobm8gaW5zdGFsbCBmb2xkZXIsIG5v
  >> "!B64TMP!" echo IERvY2tlciwgbm8gY29tcG9zZSkuCgogIDIuIEFzIGEgbW9kdWxlICh1c2VkIGJ5IHdlYl9zZWFy
  >> "!B64TMP!" echo Y2gucHkgLyB3ZWJfc2NyYXBlLnB5IGZvciBzZWxmLWhlYWxpbmcpOgogICAgICAgICBpbXBvcnQg
  >> "!B64TMP!" echo ZW5zdXJlX3N0YWNrCiAgICAgICAgIG9rLCBtZXNzYWdlLCBjb2RlID0gZW5zdXJlX3N0YWNrLmVu
  >> "!B64TMP!" echo c3VyZV9yZWFkeSgpCiAgICAgV2hlbiBhIHNlYXJjaC9zY3JhcGUgcmVxdWVzdCBmYWlscyB3aXRo
  >> "!B64TMP!" echo IGEgY29ubmVjdGlvbiBlcnJvciwgdGhvc2UKICAgICBzY3JpcHRzIGNhbGwgZW5zdXJlX3JlYWR5
  >> "!B64TMP!" echo KCkgYXV0b21hdGljYWxseSwgdGhlbiByZXRyeSB0aGUgcmVxdWVzdAogICAgIG9uY2Ug4oCUIHNv
  >> "!B64TMP!" echo IHRoZSBhZ2VudCBjYW4gY2FsbCB0aGVtIGRpcmVjdGx5IHdpdGggbm8gd2FybS11cCBzdGVwLgoK
  >> "!B64TMP!" echo QmVoYXZpb3VyIChib3RoIENMSSBhbmQgbW9kdWxlKToKICAqIEJvdGggZW5kcG9pbnRzIGFuc3dl
  >> "!B64TMP!" echo cmluZyAtPiByZXR1cm4gaW1tZWRpYXRlbHkgKGZhc3QgcGF0aCwgPCAxIHMpLgogICogT3RoZXJ3
  >> "!B64TMP!" echo aXNlOiBtYWtlIHN1cmUgdGhlIERvY2tlciBlbmdpbmUgaXMgcnVubmluZyAoaWYgaXQgaXMgZG93
  >> "!B64TMP!" echo biwgbGF1bmNoCiAgICBEb2NrZXIgRGVza3RvcCAvIHRoZSBkb2NrZXIgc2VydmljZSBhbmQgd2Fp
  >> "!B64TMP!" echo dCBmb3IgdGhlIGRhZW1vbiksIHRoZW4gc3RhcnQKICAgIHRoZSBjb250YWluZXJzIHdpdGggYGRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIHVwIC1kYCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIgKHRoZQogICAgc2FtZSBj
  >> "!B64TMP!" echo b21tYW5kIFJ1bi5iYXQgLyBydW4uc2ggcnVuLCB3aXRob3V0IHRoZSBpbnRlcmFjdGl2ZSBgcGF1
  >> "!B64TMP!" echo c2VgKSBhbmQKICAgIHdhaXQgdW50aWwgYm90aCBlbmRwb2ludHMgYW5zd2VyIGFnYWluLgogICAg
  >> "!B64TMP!" echo VGhlIHN0YWNrIGlzIE5FVkVSIHN0b3BwZWQgYnkgdGhpcyBzY3JpcHQuCgpUaGUgcmVhZGluZXNz
  >> "!B64TMP!" echo IHRpbWVvdXQgZGVmYXVsdHMgdG8gMjQwIHMgYW5kIGNhbiBiZSBvdmVycmlkZGVuIHdpdGggdGhl
  >> "!B64TMP!" echo CkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIGVudiB2YXIgKHNlY29uZHMpIOKAlCB1c2VkIGJ5
  >> "!B64TMP!" echo IHRoZSB0ZXN0IHN1aXRlIHRvCmV4ZXJjaXNlIHRoZSBmYWlsdXJlIHBhdGggcXVpY2tseS4KClRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciAoaG9sZHMgZG9ja2VyLWNvbXBvc2UueW1sKSBpcyBmb3VuZCBieSBj
  >> "!B64TMP!" echo b25maWcucHksIGluIG9yZGVyOgogICAgMS4gdGhlIExPQ0FMX1NFQVJDSF9ESVIgZW52IHZhciAo
  >> "!B64TMP!" echo ZXhwbGljaXQgb3ZlcnJpZGUpLAogICAgMi4gdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMg4oCUIGNvbXBvc2UgdGFncyBlYWNoIGNvbnRhaW5lciB3aXRoCiAgICAgICB0aGUgZGly
  >> "!B64TMP!" echo ZWN0b3J5IGl0IHdhcyBzdGFydGVkIGZyb20gKGVuZ2luZSBtdXN0IGJlIHVwKSwKICAgIDMuIGlu
  >> "!B64TMP!" echo c3RhbGwtZGlyLnR4dCDigJQgdGhlIHBhdGggcmVjb3JkZWQgYnkgdGhlIGxvY2FsLXNlYXJjaCBp
  >> "!B64TMP!" echo bnN0YWxsZXIKICAgICAgIHdoZW4gaXQgY29waWVkIHRoaXMgc2tpbGwsCiAgICA0LiB+L2xvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC4KIiIiCmltcG9ydCBhcmdwYXJzZQppbXBvcnQgb3MKaW1wb3J0IHNodXRpbAppbXBv
  >> "!B64TMP!" echo cnQgc3VicHJvY2VzcwppbXBvcnQgc3lzCmltcG9ydCB0aW1lCmltcG9ydCB1cmxsaWIuZXJyb3IK
  >> "!B64TMP!" echo aW1wb3J0IHVybGxpYi5yZXF1ZXN0CgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1l
  >> "!B64TMP!" echo KG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9k
  >> "!B64TMP!" echo dWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2ludHMKClJFQURZX1RJ
  >> "!B64TMP!" echo TUVPVVQgPSBpbnQob3MuZW52aXJvbi5nZXQoIkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIiwg
  >> "!B64TMP!" echo IjI0MCIpIG9yIDI0MCkKUE9MTF9FVkVSWSA9IDMKRElTUExBWSA9IHsic2VhcnhuZyI6ICJTZWFy
  >> "!B64TMP!" echo WE5HIiwgImZpcmVjcmF3bCI6ICJGaXJlY3Jhd2wifQoKCmRlZiBlbmRwb2ludF91cCh1cmwsIHRp
  >> "!B64TMP!" echo bWVvdXQ9NCk6CiAgICAiIiJUcnVlIGlmIHRoZSBlbmRwb2ludCBhY2NlcHRzIGNvbm5lY3Rpb25z
  >> "!B64TMP!" echo IChhbnkgSFRUUCBzdGF0dXMgY291bnRzKS4iIiIKICAgIHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJl
  >> "!B64TMP!" echo cXVlc3QodXJsLCBoZWFkZXJzPXsiVXNlci1BZ2VudCI6ICJ6Y29kZS1sb2NhbC13ZWIvMS4wIn0p
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91
  >> "!B64TMP!" echo dD10aW1lb3V0KToKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgIGV4Y2VwdCB1cmxsaWIuZXJy
  >> "!B64TMP!" echo b3IuSFRUUEVycm9yOgogICAgICAgIHJldHVybiBUcnVlICAjIGdvdCBhbiBIVFRQIHJlc3BvbnNl
  >> "!B64TMP!" echo IChldmVuIDR4eC81eHgpID0gc2VydmljZSBpcyB1cAogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gRmFsc2UgICMgY29ubmVjdGlvbiByZWZ1c2VkIC8gcmVzZXQgLyB0aW1lb3V0
  >> "!B64TMP!" echo ID0gZG93bgoKCmRlZiBwb3J0X29mKHVybCk6CiAgICByZXR1cm4gdXJsLnJzcGxpdCgiOiIsIDEp
  >> "!B64TMP!" echo WzFdCgoKZGVmIHN0YXR1cyhlbmRwb2ludHMpOgogICAgcmV0dXJuIHtuYW1lOiBlbmRwb2ludF91
  >> "!B64TMP!" echo cCh1cmwpIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1zKCl9CgoKZGVmIHJlYWR5X21l
  >> "!B64TMP!" echo c3NhZ2UoZW5kcG9pbnRzKToKICAgIHJldHVybiAiU3RhY2sgaXMgcmVhZHkgKFNlYXJYTkcgOnsw
  >> "!B64TMP!" echo fSwgRmlyZWNyYXdsIDp7MX0pLiIuZm9ybWF0KAogICAgICAgIHBvcnRfb2YoZW5kcG9pbnRzWyJz
  >> "!B64TMP!" echo ZWFyeG5nIl0pLCBwb3J0X29mKGVuZHBvaW50c1siZmlyZWNyYXdsIl0pKQoKCmRlZiBjb21wb3Nl
  >> "!B64TMP!" echo X2NvbW1hbmQoKToKICAgIGlmIHNodXRpbC53aGljaCgiZG9ja2VyIik6CiAgICAgICAgcmMgPSBz
  >> "!B64TMP!" echo dWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJkb2NrZXIiLCAiY29tcG9zZSIsICJ2ZXJzaW9u
  >> "!B64TMP!" echo Il0sCiAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9j
  >> "!B64TMP!" echo ZXNzLkRFVk5VTEwsCiAgICAgICAgKQogICAgICAgIGlmIHJjLnJldHVybmNvZGUgPT0gMDoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIFsiZG9ja2VyIiwgImNvbXBvc2UiXQogICAgaWYgc2h1dGlsLndoaWNo
  >> "!B64TMP!" echo KCJkb2NrZXItY29tcG9zZSIpOgogICAgICAgIHJldHVybiBbImRvY2tlci1jb21wb3NlIl0KICAg
  >> "!B64TMP!" echo IHJldHVybiBOb25lCgoKZGVmIGRvY2tlcl9lbmdpbmVfdXAoKToKICAgIHRyeToKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgIFsiZG9ja2VyIiwgImluZm8iXSwKICAg
  >> "!B64TMP!" echo ICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVW
  >> "!B64TMP!" echo TlVMTCwKICAgICAgICApLnJldHVybmNvZGUgPT0gMAogICAgZXhjZXB0IChPU0Vycm9yLCBGaWxl
  >> "!B64TMP!" echo Tm90Rm91bmRFcnJvcik6CiAgICAgICAgcmV0dXJuIEZhbHNlCgoKZGVmIGZpbmRfZG9ja2VyX2Rl
  >> "!B64TMP!" echo c2t0b3BfZXhlKCk6CiAgICBjYW5kaWRhdGVzID0gWwogICAgICAgIHIiQzpcUHJvZ3JhbSBGaWxl
  >> "!B64TMP!" echo c1xEb2NrZXJcRG9ja2VyXERvY2tlciBEZXNrdG9wLmV4ZSIsCiAgICAgICAgb3MucGF0aC5leHBh
  >> "!B64TMP!" echo bmR2YXJzKHIiJUxPQ0FMQVBQREFUQSVcUHJvZ3JhbXNcRG9ja2VyIERlc2t0b3BcRG9ja2VyIERl
  >> "!B64TMP!" echo c2t0b3AuZXhlIiksCiAgICBdCiAgICBmb3IgcCBpbiBjYW5kaWRhdGVzOgogICAgICAgIGlmIG9z
  >> "!B64TMP!" echo LnBhdGguaXNmaWxlKHApOgogICAgICAgICAgICByZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpk
  >> "!B64TMP!" echo ZWYgc3RhcnRfZG9ja2VyX2VuZ2luZSgpOgogICAgIiIiVHJ5IHRvIGxhdW5jaCB0aGUgRG9ja2Vy
  >> "!B64TMP!" echo IGVuZ2luZSBmb3IgdGhpcyBPUy4gVHJ1ZSBpZiB0aGUgbGF1bmNoIHdhcwogICAgaW5pdGlhdGVk
  >> "!B64TMP!" echo IChub3QgdGhhdCBpdCBiZWNhbWUgcmVhZHkg4oCUIHRoYXQncyB3YWl0X2Zvcl9lbmdpbmUncyBq
  >> "!B64TMP!" echo b2IpLiIiIgogICAgaW1wb3J0IHBsYXRmb3JtCiAgICBzeXN0ZW0gPSBwbGF0Zm9ybS5zeXN0ZW0o
  >> "!B64TMP!" echo KQogICAgaWYgc3lzdGVtID09ICJXaW5kb3dzIjoKICAgICAgICBleGUgPSBmaW5kX2RvY2tlcl9k
  >> "!B64TMP!" echo ZXNrdG9wX2V4ZSgpCiAgICAgICAgaWYgbm90IGV4ZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNl
  >> "!B64TMP!" echo CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFtleGVdLAogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1z
  >> "!B64TMP!" echo dWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0
  >> "!B64TMP!" echo IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVtID09ICJEYXJ3
  >> "!B64TMP!" echo aW4iOgogICAgICAgIHRyeToKICAgICAgICAgICAgc3VicHJvY2Vzcy5Qb3BlbihbIm9wZW4iLCAi
  >> "!B64TMP!" echo LS1iYWNrZ3JvdW5kIiwgIi1hIiwgIkRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBGYWxzZQogICAgIyBMaW51eDogYmVzdCBlZmZvcnQgd2l0aG91dCBhbiBpbnRl
  >> "!B64TMP!" echo cmFjdGl2ZSBwYXNzd29yZCBwcm9tcHQuCiAgICB0cnk6CiAgICAgICAgaWYgaGFzYXR0cihvcywg
  >> "!B64TMP!" echo ImdldGV1aWQiKSBhbmQgb3MuZ2V0ZXVpZCgpID09IDA6CiAgICAgICAgICAgIHJldHVybiBzdWJw
  >> "!B64TMP!" echo cm9jZXNzLnJ1bihbInN5c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1
  >> "!B64TMP!" echo cm5jb2RlID09IDAKICAgICAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oWyJzdWRvIiwgIi1uIiwg
  >> "!B64TMP!" echo InN5c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNl
  >> "!B64TMP!" echo cHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpk
  >> "!B64TMP!" echo ZWYgd2FpdF9mb3JfZW5naW5lKHRpbWVvdXQ9MTgwKToKICAgIGRlYWRsaW5lID0gdGltZS50aW1l
  >> "!B64TMP!" echo KCkgKyB0aW1lb3V0CiAgICB3aGlsZSB0aW1lLnRpbWUoKSA8IGRlYWRsaW5lOgogICAgICAgIGlm
  >> "!B64TMP!" echo IGRvY2tlcl9lbmdpbmVfdXAoKToKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICB0aW1l
  >> "!B64TMP!" echo LnNsZWVwKDMpCiAgICByZXR1cm4gRmFsc2UKCgpkZWYgZW5zdXJlX3JlYWR5KGNoZWNrX29ubHk9
  >> "!B64TMP!" echo RmFsc2UsIHJlYWR5X3RpbWVvdXQ9Tm9uZSwgcG9sbF9ldmVyeT1Ob25lKToKICAgICIiIkJyaW5n
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgdG8gYSByZWFkeSBzdGF0ZS4gTkVWRVIgc3RvcHMgaXQu
  >> "!B64TMP!" echo CgogICAgUmV0dXJucyAob2ssIG1lc3NhZ2UsIGV4aXRfY29kZSk6CiAgICAgICAgb2sgICAgICAg
  >> "!B64TMP!" echo ICBUcnVlIHdoZW4gYm90aCBlbmRwb2ludHMgYW5zd2VyLgogICAgICAgIG1lc3NhZ2UgICAgaHVt
  >> "!B64TMP!" echo YW4tcmVhZGFibGUgc3RhdHVzIC8gZ3VpZGFuY2UgKHByb2dyZXNzIGlzIHByaW50ZWQgdG8KICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHN0ZGVyciBhbG9uZyB0aGUgd2F5KS4KICAgICAgICBleGl0X2NvZGUg
  >> "!B64TMP!" echo IDAgcmVhZHksIDEgZG93bi9jb3VsZCBub3QgYnJpbmcgdXAsIDIgcHJlcmVxdWlzaXRlcwogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgbWlzc2luZyAobWF0Y2hlcyB0aGUgQ0xJIGV4aXQgY29kZXMpLgogICAg
  >> "!B64TMP!" echo IiIiCiAgICBpZiByZWFkeV90aW1lb3V0IGlzIE5vbmU6CiAgICAgICAgcmVhZHlfdGltZW91dCA9
  >> "!B64TMP!" echo IFJFQURZX1RJTUVPVVQKICAgIGlmIHBvbGxfZXZlcnkgaXMgTm9uZToKICAgICAgICBwb2xsX2V2
  >> "!B64TMP!" echo ZXJ5ID0gUE9MTF9FVkVSWQoKICAgIGVuZHBvaW50cyA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmln
  >> "!B64TMP!" echo LmZpbmRfaW5zdGFsbF9kaXIoKSkKICAgIHN0ID0gc3RhdHVzKGVuZHBvaW50cykKICAgIGlmIGFs
  >> "!B64TMP!" echo bChzdC52YWx1ZXMoKSk6CiAgICAgICAgcmV0dXJuIFRydWUsIHJlYWR5X21lc3NhZ2UoZW5kcG9p
  >> "!B64TMP!" echo bnRzKSwgMAoKICAgIHByaW50KCJMb2NhbC1zZWFyY2ggc3RhY2sgaXMgRE9XTjoiLCBmaWxlPXN5
  >> "!B64TMP!" echo cy5zdGRlcnIpCiAgICBmb3IgbmFtZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpOgogICAgICAg
  >> "!B64TMP!" echo IG1hcmsgPSAiT0sgICIgaWYgc3RbbmFtZV0gZWxzZSAiRE9XTiIKICAgICAgICBwcmludChmIiAg
  >> "!B64TMP!" echo W3ttYXJrfV0ge0RJU1BMQVlbbmFtZV19IDp7cG9ydF9vZih1cmwpfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgIGlmIGNoZWNrX29ubHk6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAiU3RhY2sgaXMgZG93
  >> "!B64TMP!" echo biAoLS1jaGVjazogbm90aGluZyB3YXMgc3RhcnRlZCkuIiwgMQoKICAgIGlmIG5vdCBkb2NrZXJf
  >> "!B64TMP!" echo ZW5naW5lX3VwKCk6CiAgICAgICAgcHJpbnQoIkRvY2tlciBlbmdpbmUgaXMgbm90IHJ1bm5pbmcg
  >> "!B64TMP!" echo 4oCUIHRyeWluZyB0byBzdGFydCBpdCAuLi4iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICBpZiBub3Qgc3RhcnRfZG9ja2VyX2VuZ2luZSgpOgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gRmFsc2UsICgiQ291bGQgbm90IHN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lIGF1dG9tYXRpY2Fs
  >> "!B64TMP!" echo bHkgIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiKERvY2tlciBEZXNrdG9wIG5vdCBmb3Vu
  >> "!B64TMP!" echo ZCBpbiB0aGUgdXN1YWwgbG9jYXRpb25zPykuICIKICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IlN0YXJ0IGl0IG1hbnVhbGx5LCB0aGVuIHJlLXJ1biB0aGlzIHNjcmlwdC4iKSwgMgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCJXYWl0aW5nIGZvciB0aGUgRG9ja2VyIGVuZ2luZSB0byBjb21lIHVwIC4uLiIsIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBub3Qgd2FpdF9mb3JfZW5naW5lKHRpbWVvdXQ9MTgw
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlLCAoIlRoZSBEb2NrZXIgZW5naW5lIHdhcyBsYXVu
  >> "!B64TMP!" echo Y2hlZCBidXQgZGlkIG5vdCBhbnN3ZXIgd2l0aGluICIKICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIjE4MCBzLiBDaGVjayBEb2NrZXIgRGVza3RvcCwgdGhlbiByZS1ydW4gdGhpcyBzY3JpcHQu
  >> "!B64TMP!" echo IiksIDIKCiAgICAjIFJlY29tcHV0ZWQgbm93IHRoYXQgdGhlIGVuZ2luZSBpcyB1cDogdGhlIGNv
  >> "!B64TMP!" echo bXBvc2UtbGFiZWwgbG9va3VwICh3aGljaAogICAgIyBuZWVkcyB0aGUgZW5naW5lKSBjYW4gZmlu
  >> "!B64TMP!" echo ZCB0aGUgaW5zdGFsbCBkaXIgd2hlcmUgdGhlIG90aGVyIG1ldGhvZHMKICAgICMgY291bGQgbm90
  >> "!B64TMP!" echo LgogICAgaW5zdGFsbF9kaXIgPSBjb25maWcuZmluZF9pbnN0YWxsX2RpcigpCiAgICBpZiBub3Qg
  >> "!B64TMP!" echo aW5zdGFsbF9kaXI6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAoIkNvdWxkIG5vdCBmaW5kIHRoZSBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2ggaW5zdGFsbCBmb2xkZXIgIgogICAgICAgICAgICAgICAgICAgICAgICIobm8g
  >> "!B64TMP!" echo ZG9ja2VyLWNvbXBvc2UueW1sIGZvdW5kKS4gQXNrIHRoZSB1c2VyIHdoZXJlIHRoZWlyICIKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAibG9jYWwtc2VhcmNoIGZvbGRlciBpcywgdGhlbiByZS1ydW4g
  >> "!B64TMP!" echo dGhpcyBzY3JpcHQgd2l0aCAiCiAgICAgICAgICAgICAgICAgICAgICAgIkxPQ0FMX1NFQVJDSF9E
  >> "!B64TMP!" echo SVIgc2V0IHRvIHRoYXQgcGF0aCwgb3Igc3RhcnQgdGhlIHN0YWNrIG1hbnVhbGx5ICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAiKFJ1bi5iYXQgLyBydW4uc2gpLiIpLCAyCgogICAgY29tcG9zZSA9
  >> "!B64TMP!" echo IGNvbXBvc2VfY29tbWFuZCgpCiAgICBpZiBub3QgY29tcG9zZToKICAgICAgICByZXR1cm4gRmFs
  >> "!B64TMP!" echo c2UsICJOZWl0aGVyICdkb2NrZXIgY29tcG9zZScgbm9yICdkb2NrZXItY29tcG9zZScgaXMgYXZh
  >> "!B64TMP!" echo aWxhYmxlLiIsIDIKCiAgICBwcmludChmIlN0YXJ0aW5nIHN0YWNrIGluIHtpbnN0YWxsX2Rpcn0g
  >> "!B64TMP!" echo Li4uIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKGNvbXBvc2Ug
  >> "!B64TMP!" echo KyBbInVwIiwgIi1kIl0sIGN3ZD1pbnN0YWxsX2RpcikKICAgIGlmIHByb2MucmV0dXJuY29kZSAh
  >> "!B64TMP!" echo PSAwOgogICAgICAgIHJldHVybiBGYWxzZSwgIidkb2NrZXIgY29tcG9zZSB1cCAtZCcgZmFpbGVk
  >> "!B64TMP!" echo IOKAlCBzZWUgb3V0cHV0IGFib3ZlLiIsIDEKCiAgICBwcmludCgiV2FpdGluZyBmb3IgZW5kcG9p
  >> "!B64TMP!" echo bnRzIC4uLiIsIGZpbGU9c3lzLnN0ZGVycikKICAgIGRlYWRsaW5lID0gdGltZS50aW1lKCkgKyBy
  >> "!B64TMP!" echo ZWFkeV90aW1lb3V0CiAgICB3aGlsZSB0aW1lLnRpbWUoKSA8IGRlYWRsaW5lOgogICAgICAgIHN0
  >> "!B64TMP!" echo ID0gc3RhdHVzKGVuZHBvaW50cykKICAgICAgICBpZiBhbGwoc3QudmFsdWVzKCkpOgogICAgICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gVHJ1ZSwgcmVhZHlfbWVzc2FnZShlbmRwb2ludHMpLCAwCiAgICAgICAgdGlt
  >> "!B64TMP!" echo ZS5zbGVlcChwb2xsX2V2ZXJ5KQoKICAgIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1z
  >> "!B64TMP!" echo KCk6CiAgICAgICAgbWFyayA9ICJPSyAgIiBpZiBzdFtuYW1lXSBlbHNlICJET1dOIgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KGYiICBbe21hcmt9XSB7RElTUExBWVtuYW1lXX0gOntwb3J0X29mKHVybCl9IiwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIEZhbHNlLCAoZiJTdGFjayBkaWQgbm90IGJlY29tZSBy
  >> "!B64TMP!" echo ZWFkeSB3aXRoaW4ge3JlYWR5X3RpbWVvdXR9cy4gSW5zcGVjdCB3aXRoOlxuIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZiIgICAgY2Qge2luc3RhbGxfZGlyfSAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0t
  >> "!B64TMP!" echo dGFpbCA1MCIpLCAxCgoKZGVmIG1haW4oKToKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJz
  >> "!B64TMP!" echo ZXIoZGVzY3JpcHRpb249IkVuc3VyZSB0aGUgbG9jYWwtc2VhcmNoIERvY2tlciBzdGFjayBpcyBy
  >> "!B64TMP!" echo dW5uaW5nLiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tY2hlY2siLCBhY3Rpb249InN0b3JlX3Ry
  >> "!B64TMP!" echo dWUiLAogICAgICAgICAgICAgICAgICAgIGhlbHA9Im9ubHkgcmVwb3J0IHN0YXR1czsgbmV2ZXIg
  >> "!B64TMP!" echo c3RhcnQgYW55dGhpbmciKQogICAgYXJncyA9IGFwLnBhcnNlX2FyZ3MoKQoKICAgIG9rLCBtZXNz
  >> "!B64TMP!" echo YWdlLCBjb2RlID0gZW5zdXJlX3JlYWR5KGNoZWNrX29ubHk9YXJncy5jaGVjaykKICAgIGlmIG9r
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KG1lc3NhZ2UpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KG1lc3Nh
  >> "!B64TMP!" echo Z2UsIGZpbGU9c3lzLnN0ZGVycikKICAgIHJldHVybiBjb2RlCgoKaWYgX19uYW1lX18gPT0gIl9f
  >> "!B64TMP!" echo bWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\ensure_stack.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/web_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\web_search.py" (
  copy /Y "!SRC!\local-web\scripts\web_search.py" "!TARGET!\local-web\scripts\web_search.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\web_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/web_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2237991872.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIHdlYiB2aWEgdGhlIGxvY2FsIFNl
  >> "!B64TMP!" echo YXJYTkcgaW5zdGFuY2UgYW5kIHByaW50IGNvbXBhY3QgcmVzdWx0cy4KClVzYWdlOgogICAgcHl0
  >> "!B64TMP!" echo aG9uIHdlYl9zZWFyY2gucHkgInlvdXIgcXVlcnkiIFstLWxpbWl0IDhdIFstLXRpbWUtcmFuZ2Ug
  >> "!B64TMP!" echo ZGF5fHdlZWt8bW9udGhdCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1jYXRl
  >> "!B64TMP!" echo Z29yaWVzIGl0LG5ld3MsZ2VuZXJhbF0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBh
  >> "!B64TMP!" echo cmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1l
  >> "!B64TMP!" echo IGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSBzZWFy
  >> "!B64TMP!" echo Y2ggb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCU
  >> "!B64TMP!" echo IGp1c3QgcnVuIHRoZSBzZWFyY2guCgpQcmludHMgdXAgdG8gYGxpbWl0YCByZXN1bHRzLCBlYWNo
  >> "!B64TMP!" echo IGFzOgogICAgTi4gPHRpdGxlPgogICAgICAgPHVybD4KICAgICAgIDxzbmlwcGV0PgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0IHVybGxpYi5lcnJvcgppbXBvcnQg
  >> "!B64TMP!" echo dXJsbGliLnBhcnNlCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKc3lzLnBhdGguaW5zZXJ0KDAsIG9z
  >> "!B64TMP!" echo LnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAg
  >> "!B64TMP!" echo IyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9p
  >> "!B64TMP!" echo bnRzCgojIFBvcnQgY29tZXMgZnJvbSBTRUFSWE5HX1BPUlQgaW4gdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgLmVudiAoZGVmYXVsdCA5OTkwKS4KQkFTRSA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZp
  >> "!B64TMP!" echo bmRfaW5zdGFsbF9kaXIoKSlbInNlYXJ4bmciXSArICIvc2VhcmNoIgoKVElNRU9VVCA9IDMwICAj
  >> "!B64TMP!" echo IHNlY29uZHMgcGVyIEhUVFAgYXR0ZW1wdAoKCmRlZiBmZXRjaCh1cmwpOgogICAgIiIiR0VUIHRo
  >> "!B64TMP!" echo ZSBTZWFyWE5HIEpTT04gQVBJLiBSYWlzZXMgSFRUUEVycm9yIHdoZW4gdGhlIHNlcnZpY2UgYW5z
  >> "!B64TMP!" echo d2VyZWQKICAgIHdpdGggYW4gZXJyb3Igc3RhdHVzIChzZXJ2aWNlIGlzIFVQKSwgVVJMRXJyb3It
  >> "!B64TMP!" echo ZmFtaWx5IG9uIGNvbm5lY3Rpb24KICAgIHByb2JsZW1zIChzZXJ2aWNlIGlzIERPV04pLiIiIgog
  >> "!B64TMP!" echo ICAgcmVxID0gdXJsbGliLnJlcXVlc3QuUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50
  >> "!B64TMP!" echo IjogInpjb2RlLWxvY2FsLXdlYi8xLjAifSkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3Bl
  >> "!B64TMP!" echo bihyZXEsIHRpbWVvdXQ9VElNRU9VVCkgYXMgcjoKICAgICAgICByZXR1cm4ganNvbi5sb2FkKHIp
  >> "!B64TMP!" echo CgoKZGVmIHNlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0aGUgRG9ja2VyIGVuZ2luZSArIHRoZSBj
  >> "!B64TMP!" echo b250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRoZSBzYW1lCiAgICBsb2dpYyBhcyBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQgc28gdGhlIGZhc3QgcGF0aCAoc3RhY2sKICAg
  >> "!B64TMP!" echo IGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0dXJucyAob2ssIG1lc3NhZ2UpLiIiIgogICAg
  >> "!B64TMP!" echo dHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3RhY2sKICAgICAgICBvaywgbWVzc2FnZSwgX2Nv
  >> "!B64TMP!" echo ZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5KCkKICAgICAgICByZXR1cm4gb2ssIG1lc3Nh
  >> "!B64TMP!" echo Z2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgdW5leHBlY3RlZCBzZWxmLWhlYWwgZmFp
  >> "!B64TMP!" echo bHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAgICAgcmV0dXJuIEZhbHNlLCAic2VsZi1oZWFs
  >> "!B64TMP!" echo IGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3JtYXQoZSkKCgpkZWYgbWFpbigpIC0+IGludDoK
  >> "!B64TMP!" echo ICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGxpbWl0LCB0aW1lX3JhbmdlLCBjYXRlZ29yaWVz
  >> "!B64TMP!" echo ID0gOCwgTm9uZSwgTm9uZQogICAgcXVlcnlfcGFydHMgPSBbXQogICAgaSA9IDAKICAgIHdoaWxl
  >> "!B64TMP!" echo IGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLWxp
  >> "!B64TMP!" echo bWl0IjoKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGxpbWl0ID0gaW50KGFyZ3NbaV0p
  >> "!B64TMP!" echo CiAgICAgICAgZWxpZiBhID09ICItLXRpbWUtcmFuZ2UiOgogICAgICAgICAgICBpICs9IDEKICAg
  >> "!B64TMP!" echo ICAgICAgICAgdGltZV9yYW5nZSA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0gIi0tY2F0ZWdv
  >> "!B64TMP!" echo cmllcyI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBjYXRlZ29yaWVzID0gYXJnc1tp
  >> "!B64TMP!" echo XQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVu
  >> "!B64TMP!" echo a25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAy
  >> "!B64TMP!" echo CiAgICAgICAgZWxzZToKICAgICAgICAgICAgcXVlcnlfcGFydHMuYXBwZW5kKGEpCiAgICAgICAg
  >> "!B64TMP!" echo aSArPSAxCiAgICBxdWVyeSA9ICIgIi5qb2luKHF1ZXJ5X3BhcnRzKS5zdHJpcCgpCiAgICBpZiBu
  >> "!B64TMP!" echo b3QgcXVlcnk6CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfc2VhcmNoLnB5ICJxdWVyeSIgWy0t
  >> "!B64TMP!" echo bGltaXQgTl0gWy0tdGltZS1yYW5nZSBSXSBbLS1jYXRlZ29yaWVzIENdJywgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAyCgogICAgcGFyYW1zID0geyJxIjogcXVlcnksICJmb3JtYXQi
  >> "!B64TMP!" echo OiAianNvbiIsICJsYW5ndWFnZSI6ICJlbiJ9CiAgICBpZiB0aW1lX3JhbmdlOgogICAgICAgIHBh
  >> "!B64TMP!" echo cmFtc1sidGltZV9yYW5nZSJdID0gdGltZV9yYW5nZQogICAgaWYgY2F0ZWdvcmllczoKICAgICAg
  >> "!B64TMP!" echo ICBwYXJhbXNbImNhdGVnb3JpZXMiXSA9IGNhdGVnb3JpZXMKICAgIHVybCA9IEJBU0UgKyAiPyIg
  >> "!B64TMP!" echo KyB1cmxsaWIucGFyc2UudXJsZW5jb2RlKHBhcmFtcykKCiAgICBkYXRhID0gTm9uZQogICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgIGRhdGEgPSBmZXRjaCh1cmwpCiAgICBleGNlcHQgdXJsbGliLmVycm9yLkhUVFBF
  >> "!B64TMP!" echo cnJvciBhcyBlOgogICAgICAgICMgVGhlIHNlcnZpY2UgQU5TV0VSRUQgKGV2ZW4gd2l0aCBhbiBl
  >> "!B64TMP!" echo cnJvciBzdGF0dXMpIC0+IGl0IGlzIHVwOwogICAgICAgICMgc3RhcnRpbmcgY29udGFpbmVycyB3
  >> "!B64TMP!" echo b3VsZCBub3QgaGVscC4KICAgICAgICBwcmludChmIlNFQVJDSCBGQUlMRUQ6IHtlfSIsIGZpbGU9
  >> "!B64TMP!" echo c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiU2VhclhORyBhbnN3ZXJlZCB3aXRoIGFuIGVycm9y
  >> "!B64TMP!" echo IHN0YXR1cyAodGhlIHN0YWNrIGlzIHJ1bm5pbmcpLiAiCiAgICAgICAgICAgICAgIlJldHJ5IG9u
  >> "!B64TMP!" echo Y2Ugd2l0aCBhIGRpZmZlcmVudCBxdWVyeSwgb3IgaW5zcGVjdCB0aGUgc3RhY2sgd2l0aDogIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICJjZCA8aW5zdGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21wb3NlIGxvZ3Mg
  >> "!B64TMP!" echo LS10YWlsIDUwIHNlYXJ4bmciLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgQ29ubmVjdGlv
  >> "!B64TMP!" echo biBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwK
  >> "!B64TMP!" echo ICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNlYXJjaC4KICAgICAgICBwcmludChmIlN0YWNrIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwo
  >> "!B64TMP!" echo KQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0VBUkNIIEZBSUxFRDogdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZC4gIgogICAgICAgICAgICAgICAgICAiUmVzb2x2
  >> "!B64TMP!" echo ZSB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVza3RvcCkgIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAiYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNrIHRvIG90aGVy
  >> "!B64TMP!" echo IHdlYiB0b29scyB1bmxlc3MgdGhlICIKICAgICAgICAgICAgICAgICAgInVzZXIgYXNrcy4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmV0Y2godXJsKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTI6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHByaW50KGYiU0VBUkNIIEZBSUxFRCBhZnRlciB0aGUgc3RhY2sgd2FzIHN0YXJ0
  >> "!B64TMP!" echo ZWQ6IHtlMn0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCgogICAgcmVz
  >> "!B64TMP!" echo dWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIiwgW10pWzpsaW1pdF0KICAgIGlmIG5vdCByZXN1bHRz
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCIobm8gcmVzdWx0cykiKQogICAgICAgIHJldHVybiAwCiAgICBmb3Ig
  >> "!B64TMP!" echo biwgaGl0IGluIGVudW1lcmF0ZShyZXN1bHRzLCAxKToKICAgICAgICB0aXRsZSA9IChoaXQuZ2V0
  >> "!B64TMP!" echo KCJ0aXRsZSIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgcmVzdWx0X3VybCA9IGhpdC5nZXQoInVy
  >> "!B64TMP!" echo bCIpIG9yICIiCiAgICAgICAgY29udGVudCA9IChoaXQuZ2V0KCJjb250ZW50Iikgb3IgIiIpLnN0
  >> "!B64TMP!" echo cmlwKCkucmVwbGFjZSgiXG4iLCAiICIpCiAgICAgICAgaWYgbGVuKGNvbnRlbnQpID4gMzAwOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBjb250ZW50ID0gY29udGVudFs6MzAwXSArICLigKYiCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJ7bn0uIHt0aXRsZX0iKQogICAgICAgIHByaW50KGYiICAge3Jlc3VsdF91cmx9IikKICAgICAg
  >> "!B64TMP!" echo ICBpZiBjb250ZW50OgogICAgICAgICAgICBwcmludChmIiAgIHtjb250ZW50fSIpCiAgICByZXR1
  >> "!B64TMP!" echo cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\web_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web/scripts/web_scrape.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web\scripts\web_scrape.py" (
  copy /Y "!SRC!\local-web\scripts\web_scrape.py" "!TARGET!\local-web\scripts\web_scrape.py" >nul 2>&1
  if exist "!TARGET!\local-web\scripts\web_scrape.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web/scripts/web_scrape.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1163182510.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGEgd2ViIHBhZ2UgYXMgY2xlYW4gTWFya2Rv
  >> "!B64TMP!" echo d24gdmlhIHRoZSBsb2NhbCBGaXJlY3Jhd2wgaW5zdGFuY2UuCgpVc2FnZToKICAgIHB5dGhvbiB3
  >> "!B64TMP!" echo ZWJfc2NyYXBlLnB5IDx1cmw+IFstLW1heC1jaGFycyAyMDAwMF0KClNlbGYtaGVhbGluZzogaWYg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0
  >> "!B64TMP!" echo aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRz
  >> "!B64TMP!" echo IHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCBy
  >> "!B64TMP!" echo ZXRyaWVzIHRoZSBzY3JhcGUgb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JhcGUuCgpQcmludHMgdGhlIHBhZ2UncyBN
  >> "!B64TMP!" echo YXJrZG93biB0byBzdGRvdXQsIHRydW5jYXRlZCBhdCAtLW1heC1jaGFycy4KIiIiCmltcG9ydCBq
  >> "!B64TMP!" echo c29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxp
  >> "!B64TMP!" echo Yi5yZXF1ZXN0CgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJz
  >> "!B64TMP!" echo cGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxs
  >> "!B64TMP!" echo LWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2ludHMKCiMgUG9ydCBjb21lcyBmcm9tIEZJ
  >> "!B64TMP!" echo UkVDUkFXTF9QT1JUIGluIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgKGRlZmF1bHQgOTk5MSku
  >> "!B64TMP!" echo CkVORFBPSU5UID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcuZmluZF9pbnN0YWxsX2RpcigpKVsi
  >> "!B64TMP!" echo ZmlyZWNyYXdsIl0gKyAiL3YxL3NjcmFwZSIKClRJTUVPVVQgPSA5MCAgIyBzZWNvbmRzIHBlciBI
  >> "!B64TMP!" echo VFRQIGF0dGVtcHQKCgpkZWYgZmV0Y2godXJsKToKICAgICIiIlBPU1QgdGhlIHNjcmFwZSByZXF1
  >> "!B64TMP!" echo ZXN0LiBSYWlzZXMgSFRUUEVycm9yIHdoZW4gdGhlIHNlcnZpY2UgYW5zd2VyZWQKICAgIHdpdGgg
  >> "!B64TMP!" echo YW4gZXJyb3Igc3RhdHVzIChzZXJ2aWNlIGlzIFVQKSwgVVJMRXJyb3ItZmFtaWx5IG9uIGNvbm5l
  >> "!B64TMP!" echo Y3Rpb24KICAgIHByb2JsZW1zIChzZXJ2aWNlIGlzIERPV04pLiIiIgogICAgYm9keSA9IGpzb24u
  >> "!B64TMP!" echo ZHVtcHMoeyJ1cmwiOiB1cmwsICJmb3JtYXRzIjogWyJtYXJrZG93biJdfSkuZW5jb2RlKCkKICAg
  >> "!B64TMP!" echo IHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QoCiAgICAgICAgRU5EUE9JTlQsCiAgICAgICAg
  >> "!B64TMP!" echo ZGF0YT1ib2R5LAogICAgICAgIGhlYWRlcnM9eyJDb250ZW50LVR5cGUiOiAiYXBwbGljYXRpb24v
  >> "!B64TMP!" echo anNvbiIsICJVc2VyLUFnZW50IjogInpjb2RlLWxvY2FsLXdlYi8xLjAifSwKICAgICAgICBtZXRo
  >> "!B64TMP!" echo b2Q9IlBPU1QiLAogICAgKQogICAgd2l0aCB1cmxsaWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGlt
  >> "!B64TMP!" echo ZW91dD1USU1FT1VUKSBhcyByOgogICAgICAgIHJldHVybiBqc29uLmxvYWQocikKCgpkZWYgc2Vs
  >> "!B64TMP!" echo ZmhlYWwoKToKICAgICIiIlN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lICsgdGhlIGNvbnRhaW5lcnMg
  >> "!B64TMP!" echo aWYgdGhleSBhcmUgZG93biAodGhlIHNhbWUKICAgIGxvZ2ljIGFzIGVuc3VyZV9zdGFjay5weSku
  >> "!B64TMP!" echo IEltcG9ydCBpcyBkZWZlcnJlZCBzbyB0aGUgZmFzdCBwYXRoIChzdGFjawogICAgYWxyZWFkeSB1
  >> "!B64TMP!" echo cCkgcGF5cyBub3RoaW5nLiBSZXR1cm5zIChvaywgbWVzc2FnZSkuIiIiCiAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgaW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAgIG9rLCBtZXNzYWdlLCBfY29kZSA9IGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5lbnN1cmVfcmVhZHkoKQogICAgICAgIHJldHVybiBvaywgbWVzc2FnZQogICAgZXhj
  >> "!B64TMP!" echo ZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyB1bmV4cGVjdGVkIHNlbGYtaGVhbCBmYWlsdXJlOiBkZWdy
  >> "!B64TMP!" echo YWRlIGdyYWNlZnVsbHkKICAgICAgICByZXR1cm4gRmFsc2UsICJzZWxmLWhlYWwgZmFpbGVkIHVu
  >> "!B64TMP!" echo ZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9
  >> "!B64TMP!" echo IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIp
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3NjcmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMg
  >> "!B64TMP!" echo Tl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0K
  >> "!B64TMP!" echo ICAgIG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0gMQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToK
  >> "!B64TMP!" echo ICAgICAgICBpZiBhcmdzW2ldID09ICItLW1heC1jaGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo OgogICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkg
  >> "!B64TMP!" echo Kz0gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3Iu
  >> "!B64TMP!" echo SFRUUEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUgc2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRo
  >> "!B64TMP!" echo IGFuIGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7CiAgICAgICAgIyBzdGFydGluZyBjb250YWlu
  >> "!B64TMP!" echo ZXJzIHdvdWxkIG5vdCBoZWxwLgogICAgICAgIHByaW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3Vy
  >> "!B64TMP!" echo bH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiRmlyZWNyYXdsIGFuc3dl
  >> "!B64TMP!" echo cmVkIHdpdGggYW4gZXJyb3Igc3RhdHVzICh0aGUgc3RhY2sgaXMgcnVubmluZykuICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiUmV0cnkgb25jZSB3aXRoIGEgZGlmZmVyZW50IHJlc3VsdCBVUkwsIG9yIGluc3Bl
  >> "!B64TMP!" echo Y3QgdGhlIHN0YWNrICIKICAgICAgICAgICAgICAid2l0aDogY2QgPGluc3RhbGwgZm9sZGVyPiAm
  >> "!B64TMP!" echo JiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1MCAiCiAgICAgICAgICAgICAgImZpcmVjcmF3
  >> "!B64TMP!" echo bCIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlv
  >> "!B64TMP!" echo biBhcyBlOgogICAgICAgICMgQ29ubmVjdGlvbiBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJs
  >> "!B64TMP!" echo eSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwKICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFw
  >> "!B64TMP!" echo ZS4KICAgICAgICBwcmludChmIlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBp
  >> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0NS
  >> "!B64TMP!" echo QVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQuIFJlc29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhl
  >> "!B64TMP!" echo IHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAgICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCBy
  >> "!B64TMP!" echo ZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFza3MuIi5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZldGNoKHVybCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRl
  >> "!B64TMP!" echo ZDoge2UyfSIsCiAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDEKCiAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBvciB7fQogICAgbWFya2Rv
  >> "!B64TMP!" echo d24gPSBwYXlsb2FkLmdldCgibWFya2Rvd24iKSBvciAiIiBpZiBpc2luc3RhbmNlKHBheWxvYWQs
  >> "!B64TMP!" echo IGRpY3QpIGVsc2UgIiIKICAgIGlmIG5vdCBtYXJrZG93bjoKICAgICAgICBwcmludCgiU0NSQVBF
  >> "!B64TMP!" echo IFJFVFVSTkVEIE5PIE1BUktET1dOIGZvciIsIHVybCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAg
  >> "!B64TMP!" echo IHByaW50KGpzb24uZHVtcHMoZGF0YSlbOjgwMF0sIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQoKICAgIGlmIGxlbihtYXJrZG93bikgPiBtYXhfY2hhcnM6CiAgICAgICAgbWFya2Rv
  >> "!B64TMP!" echo d24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSArIGYiXG5cblsuLi4gdHJ1bmNhdGVkIGF0IHttYXhf
  >> "!B64TMP!" echo Y2hhcnN9IGNoYXJzIC4uLl0iCiAgICBwcmludChtYXJrZG93bikKICAgIHJldHVybiAwCgoKaWYg
  >> "!B64TMP!" echo X19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web\scripts\web_scrape.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)
if exist "!SRC!\install-local-search.bat" copy /Y "!SRC!\install-local-search.bat" "!TARGET!\install-local-search.bat" >nul 2>&1
if exist "!SRC!\install-local-search.sh"  copy /Y "!SRC!\install-local-search.sh"  "!TARGET!\install-local-search.sh"  >nul 2>&1
REM Always also drop the *current* installer (this script) into target, even if
REM the source copy above was skipped (e.g. user ran a renamed copy of the bat).
copy /Y "%~f0" "!TARGET!\install-local-search.bat" >nul 2>&1

echo Generating secure credentials...
call :genkey SECRET
call :genkey BULL
call :genkey PGPASS
call :genkey RABPASS

echo Writing .env ...
> "!TARGET!\.env" echo # Local Search configuration - generated by install-local-search.bat
>> "!TARGET!\.env" echo # Edit ports/LLM here, then run Update.bat to apply.
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Host ports ----
>> "!TARGET!\.env" echo SEARXNG_PORT=!SEARXNG_PORT!
>> "!TARGET!\.env" echo FIRECRAWL_PORT=!FIRECRAWL_PORT!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- SearXNG instance secret ----
>> "!TARGET!\.env" echo SEARXNG_SECRET=!SECRET!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Firecrawl internal credentials ----
>> "!TARGET!\.env" echo BULL_AUTH_KEY=!BULL!
>> "!TARGET!\.env" echo POSTGRES_DB=firecrawl
>> "!TARGET!\.env" echo POSTGRES_USER=firecrawl
>> "!TARGET!\.env" echo POSTGRES_PASSWORD=!PGPASS!
>> "!TARGET!\.env" echo RABBITMQ_USER=firecrawl
>> "!TARGET!\.env" echo RABBITMQ_PASSWORD=!RABPASS!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo LOGGING_LEVEL=info
if defined OPENAI_BASE_URL (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- Local LLM for Firecrawl AI features ----
  >> "!TARGET!\.env" echo OPENAI_BASE_URL=!OPENAI_BASE_URL!
  >> "!TARGET!\.env" echo OPENAI_API_KEY=!OPENAI_API_KEY!
  if defined MODEL_NAME >> "!TARGET!\.env" echo MODEL_NAME=!MODEL_NAME!
)

echo Injecting SearXNG secret into settings.yml ...
powershell -NoProfile -Command "(Get-Content -Raw '!TARGET!\config\searxng\settings.yml') -replace '__SEARXNG_SECRET_PLACEHOLDER__', '!SECRET!' | Set-Content -NoNewline '!TARGET!\config\searxng\settings.yml'"

echo Installing the local-web agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web"
if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
xcopy /E /I /Y /Q "!TARGET!\local-web" "!SKILL_DIR!" >nul
if errorlevel 1 (
  echo   [WARNING] Could not copy the local-web skill to !SKILL_DIR!.
) else (
  > "!TARGET!\local-web\install-dir.txt" echo !TARGET!
  > "!SKILL_DIR!\install-dir.txt" echo !TARGET!
  echo   Agent skill installed: !SKILL_DIR!
)

echo.
echo Pulling Docker images (first run downloads ~3-4 GB, please be patient)...
pushd "!TARGET!"
docker compose pull
if !errorlevel! neq 0 ( echo   [WARNING] docker compose pull reported errors. Trying to start anyway... )
echo Starting services...
docker compose up -d
set "UP_RC=!errorlevel!"
popd
if !UP_RC! neq 0 (
  echo.
  echo [ERROR] docker compose up failed. See messages above.
  echo   Common fixes:
  echo     - Make sure Docker Desktop is running.
  echo     - Make sure ports !SEARXNG_PORT! and !FIRECRAWL_PORT! are not in use.
  echo     - Re-run this installer or run Update.bat after fixing.
  echo.
  pause & exit /b 1
)

echo.
echo ============================================================
echo   Installation complete!
echo.
echo   SearXNG  (search + JSON API):  http://localhost:!SEARXNG_PORT!
echo   Firecrawl (scrape/crawl API): http://localhost:!FIRECRAWL_PORT!
echo   local-web skill:              %USERPROFILE%\.agents\skills\local-web
echo.
echo   If your agent was already running, restart it so it picks up
echo   the new skill.
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (local-web skill, LM Studio, MCP server, direct prompting, etc.).
echo ============================================================
echo.
pause
exit /b 0

REM ===========================================================================
REM  Subroutines
REM ===========================================================================

:validate_port
echo %~1| findstr /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
if %~1 lss 1 exit /b 1
if %~1 gtr 65535 exit /b 1
exit /b 0

:genkey
set "KFILE=%TEMP%\local_search_key.tmp"
powershell -NoProfile -Command "$rng=[Security.Cryptography.RandomNumberGenerator]::Create(); $r=New-Object byte[] 32; $rng.GetBytes($r); -join ($r | ForEach-Object { $_.ToString('x2') })" > "%KFILE%"
set /p "%~1=" < "%KFILE%"
del "%KFILE%" >nul 2>&1
exit /b 0

:decode_b64
REM  %1 = path to a .b64 text file, %2 = output binary path (may not exist yet)
REM  Pass paths via PS variables to survive spaces / quotes in TARGET.
powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace '\s','')))"
exit /b 0
