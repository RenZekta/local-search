@echo off
setlocal enableDelayedExpansion
title Local Search - Installer
REM  Prompts run on a code page other than 65001: while the console is on 65001
REM  (UTF-8), set /p returns an empty line for redirected or piped stdin, so
REM  scripted answers are lost. The code page the console started on is used, or
REM  437 when it is already 65001 (chcp persists after a script ends). UTF-8 is
REM  enabled after the last prompt.
set "LS_PROMPT_CP=437"
for /f "tokens=2 delims=:" %%c in ('chcp') do for /f %%n in ("%%c") do set "LS_PROMPT_CP=%%n"
if "!LS_PROMPT_CP!"=="65001" set "LS_PROMPT_CP=437"
chcp !LS_PROMPT_CP! >nul 2>&1

REM ===========================================================================
REM  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM  After installing the stack it also copies the bundled local-web-search agent
REM  skill into %USERPROFILE%\.agents\skills\local-web-search.
REM  It also asks which browser rendering engine Firecrawl should use -
REM  Playwright (default) or Browserless (stealth mode, better block
REM  avoidance) - and writes COMPOSE_PROFILES so only that one starts.
REM  The installer asks a y/N "Add a Firecrawl account?" question (default N):
REM  without an account only the free local skill tools are installed (the
REM  19 account-gated scripts are skipped and a core-only SKILL.md is used);
REM  with one the credentials are written to .env and all 25 tools install (26 with an LLM).
REM  If the Docker engine is not running, the installer launches Docker
REM  Desktop automatically and waits for it before pulling images.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG + local-web-search)
echo   A local web-browsing system for AI models.
echo ============================================================
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker was not found on your PATH.
  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/
  echo   Then re-run this installer.
  pause & exit /b 1
)
docker info >nul 2>&1
if not errorlevel 1 goto docker_ok
echo [NOTE] The Docker engine is not running - trying to start Docker Desktop...
set "DD_EXE="
if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe" set "DD_EXE=%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"
if not defined DD_EXE (
  echo [ERROR] Docker Desktop was not found in the usual install locations.
  echo   Start it manually, wait until it says "running", then re-run
  echo   this installer.
  pause & exit /b 1
)
echo     Launching: "!DD_EXE!"
start "" "!DD_EXE!"
set "DD_LAUNCHED=1"
echo     Docker Desktop is starting in the background. Answer the next
echo     questions while it boots - the installer waits for the engine
echo     before pulling images.
:docker_ok
if not defined DD_LAUNCHED echo [OK] Docker is running.
echo.

set "SRC=%~dp0"
if "!SRC:~-1!"=="\" set "SRC=!SRC:~0,-1!"

set "DEFAULT_TARGET=%USERPROFILE%\local-search"

echo ============================================================
echo   Setup type
echo ============================================================
echo   1) Minimal installation
echo   2) Minimal + LLM Extraction
echo   3) Full installation
echo   Options 1 and 2 use: %DEFAULT_TARGET%, SearXNG 9990, Firecrawl 9991,
echo   Playwright engine, no Firecrawl account. Option 2 also asks for an LLM.
echo   You can change any of this later by editing .env and running
echo   Update.bat.
:ask_setup_type
set "SETUP_MODE="
set /p SETUP_MODE="  Choose 1, 2 or 3 [Enter = 1]: "
if not defined SETUP_MODE set "SETUP_MODE=1"
if "!SETUP_MODE!"=="3" goto full_setup
if "!SETUP_MODE!"=="1" goto defaults_chosen
if "!SETUP_MODE!"=="2" goto defaults_chosen
echo   Please enter 1, 2 or 3.
goto ask_setup_type
:defaults_chosen

set "TARGET=%DEFAULT_TARGET%"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
set "SEARXNG_PORT=9990"
set "FIRECRAWL_PORT=9991"
set "BROWSER_ENGINE=playwright"
set "PW_URL=http://playwright-service:3000/scrape"
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
set "FC_API_KEY="
set "FC_API_URL="
if not "!SETUP_MODE!"=="2" goto defaults_applied
echo.
echo --- LLM extraction ---------------------------------------
call :llm_intro
call :ask_llm
:defaults_applied
echo   Using defaults - see summary below.
echo.
goto setup_done

:full_setup
echo --- Step 1 of 6: Install location --------------------------
echo   Default: %DEFAULT_TARGET%
set "TARGET="
set /p TARGET="  Target folder [press Enter for default]: "
if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"
set "TARGET=!TARGET:"=!"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
echo   Using: !TARGET!
echo.

:ask_searxng
echo --- Step 2 of 6: SearXNG port (default 9990) --------------
set "SEARXNG_PORT="
set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "
if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"
call :validate_port "!SEARXNG_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )

:ask_firecrawl
echo --- Step 3 of 6: Firecrawl port (default 9991) ------------
set "FIRECRAWL_PORT="
set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "
if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"
call :validate_port "!FIRECRAWL_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )
if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [WARNING] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )

echo.
echo --- Step 4 of 6: Browser rendering engine (default: Playwright) ---
echo   Firecrawl needs a headless-browser service for JS-rendered pages.
echo   Playwright  - the classic Firecrawl engine ^(default^).
echo   Browserless - stealth mode ^(masks automation fingerprints^);
echo                 better at avoiding Cloudflare/bot-check blocks.
set "USE_BROWSERLESS="
set /p USE_BROWSERLESS="  Use Browserless instead of Playwright? [y/N]: "
if /i "!USE_BROWSERLESS!"=="y" (
  set "BROWSER_ENGINE=browserless"
  set "PW_URL=http://browserless:3000/scrape"
) else (
  set "BROWSER_ENGINE=playwright"
  set "PW_URL=http://playwright-service:3000/scrape"
)
echo     ^(Engine: !BROWSER_ENGINE!^)

echo.
echo --- Step 5 of 6: LLM (optional) ---------------------
call :llm_intro
set "USE_LLM="
set /p USE_LLM="  Connect LLM now? [y/N]: "
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
if /i not "!USE_LLM!"=="y" goto llm_done
call :ask_llm
:llm_done

echo --- Step 6 of 6: Firecrawl account (optional) -------------
echo   The extra tools ^(research agent, live-page interact, file parse,
echo   monitors, paper research, GitHub/developer search^) only work
echo   with a Firecrawl account API key ^(paid cloud service^):
echo     https://www.firecrawl.dev
echo   Answer N to install only the free local tools ^(default^).
set "USE_FC="
set /p USE_FC="  Add a Firecrawl account now? [y/N]: "
set "FC_API_KEY="
set "FC_API_URL="
if /i not "!USE_FC!"=="y" goto fc_done
set "FC_TRIES=0"
:ask_fckey
set "FC_API_KEY="
set /p FC_API_KEY="    Firecrawl API key (from https://www.firecrawl.dev): "
if not "!FC_API_KEY!"=="" goto fckey_ok
set /a FC_TRIES+=1
if !FC_TRIES! geq 3 (
  echo     [WARNING] No API key entered - continuing WITHOUT a Firecrawl account.
  goto fc_done
)
echo     [WARNING] The API key cannot be empty - try again.
goto ask_fckey
:fckey_ok
set "FC_API_URL="
set /p FC_API_URL="    Firecrawl API URL [press Enter for https://api.firecrawl.dev]: "
if "!FC_API_URL!"=="" set "FC_API_URL=https://api.firecrawl.dev"
:fc_done
echo.

:setup_done
echo.
echo ============================================================
echo   Summary
echo   Folder:         !TARGET!
echo   SearXNG port:   !SEARXNG_PORT!
echo   Firecrawl port: !FIRECRAWL_PORT!
echo   Browser engine: !BROWSER_ENGINE!
echo   Agent skill:    %USERPROFILE%\.agents\skills\local-web-search
if defined OPENAI_BASE_URL (
  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!
) else (
  echo   LLM endpoint:   ^(none - enable later by editing .env^)
)
if defined FC_API_KEY (
  echo   Firecrawl acct: !FC_API_URL!  ^(account tools installed^)
) else (
  echo   Firecrawl acct: ^(none - free local tools only^)
)
echo ============================================================
set "CONFIRM="
set /p CONFIRM="Proceed with install? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )
REM  All prompts are answered - safe to switch to UTF-8 for the output phase.
chcp 65001 >nul

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\config\searxng" mkdir "!TARGET!\config\searxng"
if not exist "!TARGET!\local-web-search\scripts" mkdir "!TARGET!\local-web-search\scripts"

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
  >> "!B64TMP!" echo ICBTZXJ2aWNlczoKIyAgICBzZWFyeG5nICAgICAgICAgICAgIG1ldGFzZWFyY2ggKyBKU09OIEFQ
  >> "!B64TMP!" echo SSAgICAgICAgLT4gaG9zdCAke1NFQVJYTkdfUE9SVH0KIyAgICBmaXJlY3Jhd2wgICAgICAgICAg
  >> "!B64TMP!" echo IHNjcmFwZS9jcmF3bC9zZWFyY2gvbWFwIEFQSSAgLT4gaG9zdCAke0ZJUkVDUkFXTF9QT1JUfQoj
  >> "!B64TMP!" echo ICAgIHBsYXl3cmlnaHQtc2VydmljZSAgSlMgcmVuZGVyaW5nIGZvciBGaXJlY3Jhd2wgKHByb2Zp
  >> "!B64TMP!" echo bGU6IHBsYXl3cmlnaHQpCiMgICAgYnJvd3Nlcmxlc3MgICAgICAgICBzdGVhbHRoIEpTIHJlbmRl
  >> "!B64TMP!" echo cmluZyBmb3IgRmlyZWNyYXdsIChwcm9maWxlOiBicm93c2VybGVzcykKIyAgICByZWRpcyAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIHF1ZXVlIGZvciBGaXJlY3Jhd2wKIyAgICByYWJiaXRtcSAgICAgICAgICAgIG1l
  >> "!B64TMP!" echo c3NhZ2UgYnJva2VyIGZvciBGaXJlY3Jhd2wKIyAgICBudXEtcG9zdGdyZXMgICAgICAgIGpvYiBz
  >> "!B64TMP!" echo dGF0ZSBEQiBmb3IgRmlyZWNyYXdsCiMKIyAgT25seSBPTkUgb2YgcGxheXdyaWdodC1zZXJ2aWNl
  >> "!B64TMP!" echo IC8gYnJvd3Nlcmxlc3MgYWN0dWFsbHkgc3RhcnRzOiB0aGUKIyAgaW5zdGFsbGVyJ3MgIkJyb3dz
  >> "!B64TMP!" echo ZXIgcmVuZGVyaW5nIGVuZ2luZSIgcXVlc3Rpb24gd3JpdGVzIENPTVBPU0VfUFJPRklMRVMKIyAg
  >> "!B64TMP!" echo dG8gLmVudiAoZGVmYXVsdCAicGxheXdyaWdodCIpIHRvIHBpY2sgd2hpY2ggb25lLCBhbmQgcG9p
  >> "!B64TMP!" echo bnRzCiMgIFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTCBhdCBpdC4gVGhlIG90aGVyIHN0YXlz
  >> "!B64TMP!" echo IGRlZmluZWQgYnV0IGRvcm1hbnQuCiMKIyAgT25seSB0aGUgdHdvIGhvc3QgcG9ydHMgYmVsb3cg
  >> "!B64TMP!" echo YXJlIHB1Ymxpc2hlZC4gRXZlcnl0aGluZyBlbHNlIHN0YXlzIG9uIHRoZQojICBwcml2YXRlICJs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gtbmV0IiBicmlkZ2UgbmV0d29yay4KIyA9PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoK
  >> "!B64TMP!" echo bmFtZTogbG9jYWwtc2VhcmNoCgpzZXJ2aWNlczoKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMg
  >> "!B64TMP!" echo U2VhclhORyDigJQgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5naW5lLCBleHBvc2Vk
  >> "!B64TMP!" echo IGFzIGEgSlNPTiBBUEkuCiAgIyBQb3dlcnMgYm90aCB5b3VyIEFJIG1vZGVscyAoZGlyZWN0IEpT
  >> "!B64TMP!" echo T04gcXVlcmllcykgYW5kIEZpcmVjcmF3bCdzIC92MS9zZWFyY2guCiAgIyAtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLQogIHNlYXJ4bmc6CiAgICBpbWFnZTogc2VhcnhuZy9zZWFyeG5nOmxhdGVzdAogICAgY29u
  >> "!B64TMP!" echo dGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1zZWFyeG5nCiAgICBwb3J0czoKICAgICAgLSAiJHtT
  >> "!B64TMP!" echo RUFSWE5HX1BPUlQ6LTk5OTB9OjgwODAiCiAgICB2b2x1bWVzOgogICAgICAtIC4vY29uZmlnL3Nl
  >> "!B64TMP!" echo YXJ4bmc6L2V0Yy9zZWFyeG5nOnJ3CiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBTRUFSWE5HX0JB
  >> "!B64TMP!" echo U0VfVVJMPWh0dHA6Ly9sb2NhbGhvc3Q6JHtTRUFSWE5HX1BPUlQ6LTk5OTB9LwogICAgICAtIFVX
  >> "!B64TMP!" echo U0dJX1dPUktFUlM9NAogICAgICAtIFVXU0dJX1RIUkVBRFM9NAogICAgICAtIFNFQVJYTkdfU0VD
  >> "!B64TMP!" echo UkVUPSR7U0VBUlhOR19TRUNSRVR9CiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgY2Fw
  >> "!B64TMP!" echo X2Ryb3A6CiAgICAgIC0gQUxMCiAgICBjYXBfYWRkOgogICAgICAtIENIT1dOCiAgICAgIC0gU0VU
  >> "!B64TMP!" echo R0lECiAgICAgIC0gU0VUVUlECiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0
  >> "!B64TMP!" echo CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEZpcmVjcmF3bCBBUEkgc2VydmVyICh0aGUgcHVi
  >> "!B64TMP!" echo bGljLWZhY2luZyBzY3JhcGluZy9jcmF3bC9zZWFyY2ggc2VydmljZSkuCiAgIyAtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQogIGZpcmVjcmF3bDoKICAgIGltYWdlOiBnaGNyLmlvL2ZpcmVjcmF3bC9maXJlY3Jh
  >> "!B64TMP!" echo d2w6bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLWZpcmVjcmF3bAogICAg
  >> "!B64TMP!" echo cG9ydHM6CiAgICAgIC0gIiR7RklSRUNSQVdMX1BPUlQ6LTk5OTF9OjMwMDIiCiAgICBlbnZpcm9u
  >> "!B64TMP!" echo bWVudDoKICAgICAgLSBQT1JUPTMwMDIKICAgICAgLSBIT1NUPTAuMC4wLjAKICAgICAgLSBFTlY9
  >> "!B64TMP!" echo bG9jYWwKICAgICAgLSBSRURJU19VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUkVESVNf
  >> "!B64TMP!" echo UkFURV9MSU1JVF9VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUExBWVdSSUdIVF9NSUNS
  >> "!B64TMP!" echo T1NFUlZJQ0VfVVJMPSR7UExBWVdSSUdIVF9NSUNST1NFUlZJQ0VfVVJMOi1odHRwOi8vcGxheXdy
  >> "!B64TMP!" echo aWdodC1zZXJ2aWNlOjMwMDAvc2NyYXBlfQogICAgICAtIFVTRV9EQl9BVVRIRU5USUNBVElPTj1m
  >> "!B64TMP!" echo YWxzZQogICAgICAtIEJVTExfQVVUSF9LRVk9JHtCVUxMX0FVVEhfS0VZfQogICAgICAtIExPR0dJ
  >> "!B64TMP!" echo TkdfTEVWRUw9JHtMT0dHSU5HX0xFVkVMOi1pbmZvfQogICAgICAtIEJMT0NLX01FRElBPWZhbHNl
  >> "!B64TMP!" echo CiAgICAgIC0gQUxMT1dfTE9DQUxfV0VCSE9PS1M9ZmFsc2UKICAgICAgLSBTRUFSWE5HX0VORFBP
  >> "!B64TMP!" echo SU5UPWh0dHA6Ly9zZWFyeG5nOjgwODAKICAgICAgLSBQT1NUR1JFU19IT1NUPW51cS1wb3N0Z3Jl
  >> "!B64TMP!" echo cwogICAgICAtIFBPU1RHUkVTX1BPUlQ9NTQzMgogICAgICAtIFBPU1RHUkVTX0RCPSR7UE9TVEdS
  >> "!B64TMP!" echo RVNfREI6LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9TVEdSRVNfVVNFUjot
  >> "!B64TMP!" echo ZmlyZWNyYXdsfQogICAgICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdSRVNfUEFTU1dPUkR9
  >> "!B64TMP!" echo CiAgICAgIC0gTlVRX1JBQkJJVE1RX1VSTD1hbXFwOi8vJHtSQUJCSVRNUV9VU0VSOi1maXJlY3Jh
  >> "!B64TMP!" echo d2x9OiR7UkFCQklUTVFfUEFTU1dPUkR9QHJhYmJpdG1xOjU2NzIKICAgICAgIyAtLS0tIE9wdGlv
  >> "!B64TMP!" echo bmFsIEFJIGZlYXR1cmVzIChzZXQgaW4gLmVudiB0byBlbmFibGUgL3YxL2V4dHJhY3QgKyBzdW1t
  >> "!B64TMP!" echo YXJ5KSAtLS0tCiAgICAgIC0gT1BFTkFJX0FQSV9LRVk9JHtPUEVOQUlfQVBJX0tFWTotfQogICAg
  >> "!B64TMP!" echo ICAtIE9QRU5BSV9CQVNFX1VSTD0ke09QRU5BSV9CQVNFX1VSTDotfQogICAgICAtIE9MTEFNQV9C
  >> "!B64TMP!" echo QVNFX1VSTD0ke09MTEFNQV9CQVNFX1VSTDotfQogICAgICAtIE1PREVMX05BTUU9JHtNT0RFTF9O
  >> "!B64TMP!" echo QU1FOi19CiAgICAgIC0gTU9ERUxfRU1CRURESU5HX05BTUU9JHtNT0RFTF9FTUJFRERJTkdfTkFN
  >> "!B64TMP!" echo RTotfQogICAgY29tbWFuZDogWyJub2RlIiwgImRpc3Qvc3JjL2hhcm5lc3MuanMiLCAiLS1zdGFy
  >> "!B64TMP!" echo dC1kb2NrZXIiXQogICAgdWxpbWl0czoKICAgICAgbm9maWxlOgogICAgICAgIHNvZnQ6IDY1NTM1
  >> "!B64TMP!" echo CiAgICAgICAgaGFyZDogNjU1MzUKICAgIGV4dHJhX2hvc3RzOgogICAgICAtICJob3N0LmRvY2tl
  >> "!B64TMP!" echo ci5pbnRlcm5hbDpob3N0LWdhdGV3YXkiCiAgICBsb2dnaW5nOgogICAgICBkcml2ZXI6ICJqc29u
  >> "!B64TMP!" echo LWZpbGUiCiAgICAgIG9wdGlvbnM6CiAgICAgICAgbWF4LXNpemU6ICIxMG0iCiAgICAgICAgbWF4
  >> "!B64TMP!" echo LWZpbGU6ICIzIgogICAgICAgIGNvbXByZXNzOiAidHJ1ZSIKICAgIGRlcGVuZHNfb246CiAgICAg
  >> "!B64TMP!" echo IHJlZGlzOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9zdGFydGVkCiAgICAgIHBsYXl3cmln
  >> "!B64TMP!" echo aHQtc2VydmljZToKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICAgIHJl
  >> "!B64TMP!" echo cXVpcmVkOiBmYWxzZQogICAgICBicm93c2VybGVzczoKICAgICAgICBjb25kaXRpb246IHNlcnZp
  >> "!B64TMP!" echo Y2Vfc3RhcnRlZAogICAgICAgIHJlcXVpcmVkOiBmYWxzZQogICAgICBzZWFyeG5nOgogICAgICAg
  >> "!B64TMP!" echo IGNvbmRpdGlvbjogc2VydmljZV9zdGFydGVkCiAgICAgIG51cS1wb3N0Z3JlczoKICAgICAgICBj
  >> "!B64TMP!" echo b25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICByYWJiaXRtcToKICAgICAgICBjb25kaXRp
  >> "!B64TMP!" echo b246IHNlcnZpY2VfaGVhbHRoeQogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdv
  >> "!B64TMP!" echo cmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMg
  >> "!B64TMP!" echo UGxheXdyaWdodCBoZWFkbGVzcyBicm93c2VyIHNlcnZpY2Ug4oCUIGRvZXMgdGhlIGFjdHVhbCBK
  >> "!B64TMP!" echo Uy1yZW5kZXJlZAogICMgZmV0Y2hpbmcuIE9ubHkgc3RhcnRzIHdoZW4gQ09NUE9TRV9QUk9GSUxF
  >> "!B64TMP!" echo Uz1wbGF5d3JpZ2h0ICh0aGUgaW5zdGFsbGVyJ3MKICAjIGRlZmF1bHQgYW5zd2VyIHRvICJCcm93
  >> "!B64TMP!" echo c2VyIHJlbmRlcmluZyBlbmdpbmUiKS4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgcGxheXdyaWdo
  >> "!B64TMP!" echo dC1zZXJ2aWNlOgogICAgaW1hZ2U6IGdoY3IuaW8vZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2Vydmlj
  >> "!B64TMP!" echo ZTpsYXRlc3QKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtcGxheXdyaWdodAogICAg
  >> "!B64TMP!" echo cHJvZmlsZXM6IFsicGxheXdyaWdodCJdCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBQT1JUPTMw
  >> "!B64TMP!" echo MDAKICAgICAgLSBCTE9DS19NRURJQT1mYWxzZQogICAgICAtIEFMTE9XX0xPQ0FMX1dFQkhPT0tT
  >> "!B64TMP!" echo PWZhbHNlCiAgICAgIC0gTUFYX0NPTkNVUlJFTlRfUEFHRVM9MTAKICAgIHJlc3RhcnQ6IHVubGVz
  >> "!B64TMP!" echo cy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0KICAjIEJyb3dzZXJsZXNzIChjb21tdW5pdHkgZWRpdGlvbikg4oCUIHN0
  >> "!B64TMP!" echo ZWFsdGggaGVhZGxlc3MgQ2hyb21pdW0gdGhhdCBkb2VzIHRoZQogICMgYWN0dWFsIEpTLXJlbmRl
  >> "!B64TMP!" echo cmVkIGZldGNoaW5nIGZvciBGaXJlY3Jhd2wuIERFRkFVTFRfU1RFQUxUSD10cnVlIGFwcGxpZXMK
  >> "!B64TMP!" echo ICAjIHRoZSBidWlsdC1pbiBzdGVhbHRoIHBhdGNoZXMgKG1hc2tzIGF1dG9tYXRpb24gZmluZ2Vy
  >> "!B64TMP!" echo cHJpbnRzIHN1Y2ggYXMKICAjIG5hdmlnYXRvci53ZWJkcml2ZXIpIHRvIGV2ZXJ5IHJlcXVlc3Qg
  >> "!B64TMP!" echo d2l0aG91dCBuZWVkaW5nIGEgP3N0ZWFsdGggcXVlcnkKICAjIHBhcmFtLCB3aGljaCBoZWxwcyBw
  >> "!B64TMP!" echo YWdlcyBmcm9udGVkIGJ5IENsb3VkZmxhcmUgYW5kIHNpbWlsYXIgYm90IGNoZWNrcy4KICAjIE9u
  >> "!B64TMP!" echo bHkgc3RhcnRzIHdoZW4gQ09NUE9TRV9QUk9GSUxFUz1icm93c2VybGVzcyAodGhlIGluc3RhbGxl
  >> "!B64TMP!" echo cidzICJVc2UKICAjIEJyb3dzZXJsZXNzIGluc3RlYWQ/IiBhbnN3ZXIpLgogICMgLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0KICBicm93c2VybGVzczoKICAgIGltYWdlOiBnaGNyLmlvL2Jyb3dzZXJsZXNzL2No
  >> "!B64TMP!" echo cm9taXVtOmxhdGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1icm93c2VybGVz
  >> "!B64TMP!" echo cwogICAgcHJvZmlsZXM6IFsiYnJvd3Nlcmxlc3MiXQogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0g
  >> "!B64TMP!" echo UE9SVD0zMDAwCiAgICAgIC0gVE9LRU49JHtCUk9XU0VSTEVTU19UT0tFTjotfQogICAgICAtIERF
  >> "!B64TMP!" echo RkFVTFRfU1RFQUxUSD10cnVlCiAgICAgIC0gQ09OQ1VSUkVOVD0xMAogICAgICAtIE1BWF9DT05D
  >> "!B64TMP!" echo VVJSRU5UX1NFU1NJT05TPTEwCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgbmV0d29y
  >> "!B64TMP!" echo a3M6CiAgICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgIyBS
  >> "!B64TMP!" echo ZWRpcyDigJQgRmlyZWNyYXdsIHF1ZXVlIC8gcmF0ZS1saW1pdGluZyBzdG9yZS4KICAjIC0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tCiAgcmVkaXM6CiAgICBpbWFnZTogcmVkaXM6YWxwaW5lCiAgICBjb250YWlu
  >> "!B64TMP!" echo ZXJfbmFtZTogbG9jYWwtc2VhcmNoLXJlZGlzCiAgICB2b2x1bWVzOgogICAgICAtIHJlZGlzLWRh
  >> "!B64TMP!" echo dGE6L2RhdGEKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAgICAg
  >> "!B64TMP!" echo LSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIFJhYmJpdE1RIOKA
  >> "!B64TMP!" echo lCBtZXNzYWdlIGJyb2tlciB1c2VkIGJ5IEZpcmVjcmF3bCdzIGpvYiB3b3JrZXJzLgogICMgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0KICByYWJiaXRtcToKICAgIGltYWdlOiByYWJiaXRtcTozLW1hbmFnZW1l
  >> "!B64TMP!" echo bnQKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtcmFiYml0bXEKICAgIGVudmlyb25t
  >> "!B64TMP!" echo ZW50OgogICAgICAtIFJBQkJJVE1RX0RFRkFVTFRfVVNFUj0ke1JBQkJJVE1RX1VTRVI6LWZpcmVj
  >> "!B64TMP!" echo cmF3bH0KICAgICAgLSBSQUJCSVRNUV9ERUZBVUxUX1BBU1M9JHtSQUJCSVRNUV9QQVNTV09SRH0K
  >> "!B64TMP!" echo ICAgIHZvbHVtZXM6CiAgICAgIC0gcmFiYml0bXEtZGF0YTovdmFyL2xpYi9yYWJiaXRtcQogICAg
  >> "!B64TMP!" echo aGVhbHRoY2hlY2s6CiAgICAgIHRlc3Q6IFsiQ01EIiwgInJhYmJpdG1xLWRpYWdub3N0aWNzIiwg
  >> "!B64TMP!" echo InBpbmciXQogICAgICBpbnRlcnZhbDogNXMKICAgICAgdGltZW91dDogMTBzCiAgICAgIHJldHJp
  >> "!B64TMP!" echo ZXM6IDEwCiAgICAgIHN0YXJ0X3BlcmlvZDogMzBzCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBl
  >> "!B64TMP!" echo ZAogICAgbmV0d29ya3M6CiAgICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKICAjIC0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tCiAgIyBudXEtcG9zdGdyZXMg4oCUIEZpcmVjcmF3bCBqb2Itc3RhdGUgZGF0YWJhc2Ug
  >> "!B64TMP!" echo KHBnX2Nyb24gZW5hYmxlZCBpbWFnZSkuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIG51cS1wb3N0
  >> "!B64TMP!" echo Z3JlczoKICAgIGltYWdlOiBnaGNyLmlvL2ZpcmVjcmF3bC9udXEtcG9zdGdyZXM6bGF0ZXN0CiAg
  >> "!B64TMP!" echo ICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLXBvc3RncmVzCiAgICBjb21tYW5kOiBwb3N0
  >> "!B64TMP!" echo Z3JlcyAtYyBjcm9uLmRhdGFiYXNlX25hbWU9JHtQT1NUR1JFU19EQjotZmlyZWNyYXdsfQogICAg
  >> "!B64TMP!" echo ZW52aXJvbm1lbnQ6CiAgICAgIC0gUE9TVEdSRVNfREI9JHtQT1NUR1JFU19EQjotZmlyZWNyYXds
  >> "!B64TMP!" echo fQogICAgICAtIFBPU1RHUkVTX1VTRVI9JHtQT1NUR1JFU19VU0VSOi1maXJlY3Jhd2x9CiAgICAg
  >> "!B64TMP!" echo IC0gUE9TVEdSRVNfUEFTU1dPUkQ9JHtQT1NUR1JFU19QQVNTV09SRH0KICAgIHZvbHVtZXM6CiAg
  >> "!B64TMP!" echo ICAgIC0gcG9zdGdyZXMtZGF0YTovdmFyL2xpYi9wb3N0Z3Jlc3FsL2RhdGEKICAgIGhlYWx0aGNo
  >> "!B64TMP!" echo ZWNrOgogICAgICB0ZXN0OiBbIkNNRC1TSEVMTCIsICJwZ19pc3JlYWR5IC1VICR7UE9TVEdSRVNf
  >> "!B64TMP!" echo VVNFUjotZmlyZWNyYXdsfSAtZCAke1BPU1RHUkVTX0RCOi1maXJlY3Jhd2x9Il0KICAgICAgaW50
  >> "!B64TMP!" echo ZXJ2YWw6IDVzCiAgICAgIHRpbWVvdXQ6IDVzCiAgICAgIHJldHJpZXM6IDEwCiAgICAgIHN0YXJ0
  >> "!B64TMP!" echo X3BlcmlvZDogMzBzCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgbmV0d29ya3M6CiAg
  >> "!B64TMP!" echo ICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKbmV0d29ya3M6CiAgbG9jYWwtc2VhcmNoLW5ldDoKICAg
  >> "!B64TMP!" echo IGRyaXZlcjogYnJpZGdlCgp2b2x1bWVzOgogIHJlZGlzLWRhdGE6CiAgcG9zdGdyZXMtZGF0YToK
  >> "!B64TMP!" echo ICByYWJiaXRtcS1kYXRhOgo=
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
  >> "!B64TMP!" echo QVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4CgojIC0tLS0gQnJvd3NlciBy
  >> "!B64TMP!" echo ZW5kZXJpbmcgZW5naW5lIGZvciBGaXJlY3Jhd2wgKGluc3RhbGxlciBTdGVwIDQpIC0tLS0KIyAg
  >> "!B64TMP!" echo IHBsYXl3cmlnaHQgKGRlZmF1bHQpOiBnaGNyLmlvL2ZpcmVjcmF3bC9wbGF5d3JpZ2h0LXNlcnZp
  >> "!B64TMP!" echo Y2UKIyAgIGJyb3dzZXJsZXNzOiAgICAgICAgICBnaGNyLmlvL2Jyb3dzZXJsZXNzL2Nocm9taXVt
  >> "!B64TMP!" echo IChzdGVhbHRoIG1vZGUsIGJldHRlcgojICAgICAgICAgICAgICAgICAgICAgICAgICBibG9jayBh
  >> "!B64TMP!" echo dm9pZGFuY2Ugb24gQ2xvdWRmbGFyZS1mcm9udGVkIHNpdGVzKQojICAgQ09NUE9TRV9QUk9GSUxF
  >> "!B64TMP!" echo UyBzZWxlY3RzIHdoaWNoIHNlcnZpY2UgYWN0dWFsbHkgc3RhcnRzOyBQTEFZV1JJR0hUX01JQ1JP
  >> "!B64TMP!" echo U0VSVklDRV9VUkwKIyAgIG11c3QgcG9pbnQgYXQgdGhlIHNhbWUgb25lLiBUbyBzd2l0Y2ggbGF0
  >> "!B64TMP!" echo ZXIsIGNoYW5nZSBib3RoIGxpbmVzIGFuZCBydW4gVXBkYXRlLmJhdC91cGRhdGUuc2guCkNPTVBP
  >> "!B64TMP!" echo U0VfUFJPRklMRVM9cGxheXdyaWdodApQTEFZV1JJR0hUX01JQ1JPU0VSVklDRV9VUkw9aHR0cDov
  >> "!B64TMP!" echo L3BsYXl3cmlnaHQtc2VydmljZTozMDAwL3NjcmFwZQoKIyAtLS0tIEJyb3dzZXJsZXNzIHRva2Vu
  >> "!B64TMP!" echo IChvbmx5IHVzZWQgaWYgQ09NUE9TRV9QUk9GSUxFUz1icm93c2VybGVzcyBhYm92ZTsgaW5zdGFs
  >> "!B64TMP!" echo bGVyIGdlbmVyYXRlcyBhIHJhbmRvbSB2YWx1ZSByZWdhcmRsZXNzKSAtLS0tCkJST1dTRVJMRVNT
  >> "!B64TMP!" echo X1RPS0VOPXJlcGxhY2Utd2l0aC02NC1jaGFyLXJhbmRvbS1oZXgKCiMgLS0tLSBMb2dnaW5nIC0t
  >> "!B64TMP!" echo LS0KTE9HR0lOR19MRVZFTD1pbmZvCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIE9wdGlvbmFs
  >> "!B64TMP!" echo OiBjb25uZWN0IGEgbG9jYWwgKG9yIHJlbW90ZSkgTExNIHNvIEZpcmVjcmF3bCdzIC92MS9leHRy
  >> "!B64TMP!" echo YWN0IGFuZAojICAic3VtbWFyeSIgZmVhdHVyZXMgd29yay4gQW55IE9wZW5BSS1jb21wYXRpYmxl
  >> "!B64TMP!" echo IGVuZHBvaW50IHdpbGwgZG8uCiMgIExNIFN0dWRpbyBpcyB0aGUgcmVjb21tZW5kZWQgZGVmYXVs
  >> "!B64TMP!" echo dCAocHJpb3JpdHkgb3ZlciBPbGxhbWEpLgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CgojIC0tLS0g
  >> "!B64TMP!" echo T3B0aW9uIEEgKFJFQ09NTUVOREVEKTogTE0gU3R1ZGlvIC8gYW55IE9wZW5BSS1jb21wYXRpYmxl
  >> "!B64TMP!" echo IGxvY2FsIHNlcnZlciAtLS0tCiMgICAxLiBJbiBMTSBTdHVkaW86IERldmVsb3BlciB0YWIgPiAi
  >> "!B64TMP!" echo U3RhcnQgU2VydmVyIiBvbiBwb3J0IDEyMzQsIGxvYWQgYSBtb2RlbCwKIyAgICAgIGFuZCBFTkFC
  >> "!B64TMP!" echo TEUgIlNlcnZlIG9uIGxvY2FsIG5ldHdvcmsiIHNvIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyIGNh
  >> "!B64TMP!" echo biByZWFjaCBpdC4KIyAgIDIuIE5PVEU6IE9QRU5BSV9CQVNFX1VSTCBpcyByZWFkIElOU0lERSB0
  >> "!B64TMP!" echo aGUgRmlyZWNyYXdsIGNvbnRhaW5lci4gRnJvbSB0aGVyZSwKIyAgICAgIHlvdXIgaG9zdCBtYWNo
  >> "!B64TMP!" echo aW5lIGlzICJob3N0LmRvY2tlci5pbnRlcm5hbCIsIE5PVCAibG9jYWxob3N0Ii4gU28gdXNlOgoj
  >> "!B64TMP!" echo IE9QRU5BSV9CQVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQojIE9Q
  >> "!B64TMP!" echo RU5BSV9BUElfS0VZPWxtLXN0dWRpbyAgICAgICAgICAjIGFueSBub24tZW1wdHkgc3RyaW5nOyBM
  >> "!B64TMP!" echo TSBTdHVkaW8gaWdub3JlcyBpdAojIE1PREVMX05BTUU9bG9jYWwtbW9kZWwgICAgICAgICAgICAj
  >> "!B64TMP!" echo IHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4gTE0gU3R1ZGlvCgojIC0tLS0gT3B0aW9uIEI6IHJlbW90
  >> "!B64TMP!" echo ZSBPcGVuQUktY29tcGF0aWJsZSBzZXJ2ZXIgKHZMTE0sIGxsYW1hLmNwcCBzZXJ2ZXIsIGV0Yy4p
  >> "!B64TMP!" echo IC0tLS0KIyBPUEVOQUlfQkFTRV9VUkw9aHR0cDovLzE5Mi4xNjguMS41MDo4MDAwL3YxCiMgT1BF
  >> "!B64TMP!" echo TkFJX0FQSV9LRVk9cGxhY2Vob2xkZXIKIyBNT0RFTF9OQU1FPXlvdXItbW9kZWwtaWQKCiMgLS0t
  >> "!B64TMP!" echo LSBPcHRpb24gQyAoZmFsbGJhY2spOiBPbGxhbWEgb24gdGhlIHNhbWUgaG9zdCBhcyBEb2NrZXIg
  >> "!B64TMP!" echo LS0tLQojIE9MTEFNQV9CQVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTE0MzQv
  >> "!B64TMP!" echo YXBpCiMgTU9ERUxfTkFNRT1xd2VuMi41OjdiCiMgTU9ERUxfRU1CRURESU5HX05BTUU9bm9taWMt
  >> "!B64TMP!" echo ZW1iZWQtdGV4dAoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBPcHRpb25hbDogRmlyZWNyYXds
  >> "!B64TMP!" echo IGFjY291bnQgKHBhaWQgY2xvdWQgc2VydmljZSkgZm9yIHRoZSBhY2NvdW50LW9ubHkKIyAgbG9j
  >> "!B64TMP!" echo YWwtd2ViLXNlYXJjaCB0b29scyAocmVzZWFyY2ggYWdlbnQsIGludGVyYWN0LCBwYXJzZSwgbW9u
  >> "!B64TMP!" echo aXRvcnMsIHBhcGVyCiMgIHJlc2VhcmNoLCBHaXRIdWIvZGV2ZWxvcGVyIHNlYXJjaCkuCiMKIyAg
  >> "!B64TMP!" echo VGhlIGluc3RhbGxlciBvZmZlcnMgdG8gd3JpdGUgdGhlc2UgZm9yIHlvdSAoYW5zd2VyICd5JyBh
  >> "!B64TMP!" echo dCB0aGUKIyAgIkFkZCBhIEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24sIHRoZW4gcGFzdGUg
  >> "!B64TMP!" echo eW91ciBrZXkpLiBXaXRob3V0IHRoZW0KIyAgdGhlIGluc3RhbGxlciBza2lwcyB0aG9zZSB0b29s
  >> "!B64TMP!" echo cyBhbmQgaW5zdGFsbHMgb25seSB0aGUgZnJlZSBsb2NhbCBvbmVzLgojICBUaGUgbG9jYWwtd2Vi
  >> "!B64TMP!" echo LXNlYXJjaCBzY3JpcHRzIHJlYWQgdGhlc2Uga2V5cyBmcm9tIFRISVMgZmlsZTsKIyAgRklSRUNS
  >> "!B64TMP!" echo QVdMX0FQSV9VUkwgLyBGSVJFQ1JBV0xfQVBJX0tFWSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgb3Zl
  >> "!B64TMP!" echo cnJpZGUgdGhlbS4KIyAgKFRoZSBEb2NrZXIgY29udGFpbmVycyBpZ25vcmUgdGhlc2Uga2V5cyBl
  >> "!B64TMP!" echo bnRpcmVseS4pCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyBGSVJFQ1JBV0xfQVBJX1VSTD1odHRw
  >> "!B64TMP!" echo czovL2FwaS5maXJlY3Jhd2wuZGV2CiMgRklSRUNSQVdMX0FQSV9LRVk9ZmMteW91ci1rZXktaGVy
  >> "!B64TMP!" echo ZQo=
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
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsICsgdGhlIGxvY2FsLXdlYi1zZWFyY2gg
  >> "!B64TMP!" echo YWdlbnQgc2tpbGwsIHJ1bm5pbmcgZW50aXJlbHkgb24geW91ciBtYWNoaW5lLCBiZWhpbmQgdHdv
  >> "!B64TMP!" echo IGxvY2FsIHBvcnRzLioqCgpHaXZlIGFueSBMTE0g4oCUIGEgbG9jYWwgbW9kZWwgaW4gTE0gU3R1
  >> "!B64TMP!" echo ZGlvLCBhIGNsb3VkIG1vZGVsLCBhbiBhZ2VudCwgYW4gTUNQCmNsaWVudCwgb3IgYSBwbGFpbiBj
  >> "!B64TMP!" echo aGF0IFVJIOKAlCB0aGUgYWJpbGl0eSB0byAqKnNlYXJjaCB0aGUgd2ViIGFuZCByZWFkIHBhZ2Vz
  >> "!B64TMP!" echo KioKd2l0aG91dCBzZW5kaW5nIGEgc2luZ2xlIHJlcXVlc3QgdG8gYSBwYWlkIHNjcmFwaW5nIEFQ
  >> "!B64TMP!" echo SS4gRXZlcnl0aGluZyBydW5zIGluCkRvY2tlciBvbiB5b3VyIGNvbXB1dGVyOyB5b3VyIHF1ZXJp
  >> "!B64TMP!" echo ZXMsIHJlc3VsdHMsIGFuZCBwYWdlIGNvbnRlbnRzIG5ldmVyIGxlYXZlCnlvdXIgbmV0d29yay4K
  >> "!B64TMP!" echo CnwgV2hhdCB8IFVSTCAoZGVmYXVsdCkgfCBQdXJwb3NlIHwKfC0tLS0tLXwtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS18LS0tLS0tLS0tfAp8ICoqU2VhclhORyoqICB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIHwg
  >> "!B64TMP!" echo TWV0YXNlYXJjaCArIEpTT04gQVBJLiBBZ2dyZWdhdGVzIEdvb2dsZS9CaW5nL0R1Y2tEdWNrR28v
  >> "!B64TMP!" echo ZXRjLiB8CnwgKipGaXJlY3Jhd2wqKiB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIHwgU2NyYXBl
  >> "!B64TMP!" echo IC8gY3Jhd2wgLyBtYXAgLyBzZWFyY2ggLyBleHRyYWN0IOKAlCByZXR1cm5zIGNsZWFuIE1hcmtk
  >> "!B64TMP!" echo b3duLiB8CnwgKipsb2NhbC13ZWItc2VhcmNoKiogfCBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoYCB8IEJ1bmRsZWQgYWdlbnQgc2tpbGw6IHNlYXJjaCArIHJlYWQgKyBhdXRvLXN0
  >> "!B64TMP!" echo YXJ0IHRoZSBzdGFjay4gfAoKPiBCb3RoIHBvcnRzIGFyZSBmdWxseSBjb25maWd1cmFibGUgYXQg
  >> "!B64TMP!" echo aW5zdGFsbCB0aW1lLiBUaGUgZGVmYXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5MWApIGFyZSBjaG9z
  >> "!B64TMP!" echo ZW4gdG8gYXZvaWQgY2xhc2hpbmcgd2l0aCBjb21tb24gZGV2IHNlcnZlcnMuCgotLS0KCiMjIFRh
  >> "!B64TMP!" echo YmxlIG9mIGNvbnRlbnRzCgoxLiBbV2hhdCB5b3UgZ2V0XSgjd2hhdC15b3UtZ2V0KQoyLiBbUmVx
  >> "!B64TMP!" echo dWlyZW1lbnRzXSgjcmVxdWlyZW1lbnRzKQozLiBbUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0
  >> "!B64TMP!" echo YWxsKV0oI3F1aWNrLXN0YXJ0LW9uZS1jbGljay1pbnN0YWxsKQo0LiBbTWFuYWdpbmcgdGhlIHN0
  >> "!B64TMP!" echo YWNrXSgjbWFuYWdpbmctdGhlLXN0YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9nZXRoZXJdKCNob3ct
  >> "!B64TMP!" echo aXQtZml0cy10b2dldGhlcikKNi4gW1VzaW5nIGl0IHdpdGggQUkgbW9kZWxzXSgjdXNpbmctaXQt
  >> "!B64TMP!" echo d2l0aC1haS1tb2RlbHMpCiAgIC0gW0EuIFRoZSBidW5kbGVkIGxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwgKHJlY29tbWVuZGVkKV0oI2EtdGhlLWJ1bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1y
  >> "!B64TMP!" echo ZWNvbW1lbmRlZCkKICAgLSBbQi4gRGlyZWN0IFNlYXJYTkcgSlNPTiBBUEldKCNiLWRpcmVjdC1z
  >> "!B64TMP!" echo ZWFyeG5nLWpzb24tYXBpKQogICAtIFtDLiBEaXJlY3QgRmlyZWNyYXdsIFJFU1QgQVBJXSgjYy1k
  >> "!B64TMP!" echo aXJlY3QtZmlyZWNyYXdsLXJlc3QtYXBpKQogICAtIFtELiBDb25uZWN0IGFuIExMTSAoTE0gU3R1
  >> "!B64TMP!" echo ZGlvLCBldGMuKV0oI2QtY29ubmVjdC1hbi1sbG0tbG0tc3R1ZGlvLWV0YykKICAgLSBbRS4gVmlh
  >> "!B64TMP!" echo IGFuIE1DUCBzZXJ2ZXJdKCNlLXZpYS1hbi1tY3Atc2VydmVyKQogICAtIFtGLiBWaWEgcHJvbXB0
  >> "!B64TMP!" echo aW5nIChhbnkgY2hhdCBVSSldKCNmLXZpYS1wcm9tcHRpbmctYW55LWNoYXQtdWkpCiAgIC0gW0cu
  >> "!B64TMP!" echo IEdVSSBpbnRlZ3JhdGlvbnNdKCNnLWd1aS1pbnRlZ3JhdGlvbnMpCjcuIFtDb25maWd1cmF0aW9u
  >> "!B64TMP!" echo IHJlZmVyZW5jZV0oI2NvbmZpZ3VyYXRpb24tcmVmZXJlbmNlKQo4LiBbVHJvdWJsZXNob290aW5n
  >> "!B64TMP!" echo XSgjdHJvdWJsZXNob290aW5nKQo5LiBbVXBkYXRpbmcgJiB1bmluc3RhbGxpbmddKCN1cGRhdGlu
  >> "!B64TMP!" echo Zy0tdW5pbnN0YWxsaW5nKQoxMC4gW0RldmVsb3BtZW50OiBmdWxsIGRldiByaWcgKHJlYnVpbGRp
  >> "!B64TMP!" echo bmcgZXZlcnl0aGluZyldKCNkZXZlbG9wbWVudC1mdWxsLWRldi1yaWctcmVidWlsZGluZy1ldmVy
  >> "!B64TMP!" echo eXRoaW5nKQoxMS4gW1NlY3VyaXR5IG5vdGVzXSgjc2VjdXJpdHktbm90ZXMpCjEyLiBbQ3JlZGl0
  >> "!B64TMP!" echo cyAmIGxpY2Vuc2VzXSgjY3JlZGl0cy0tbGljZW5zZXMpCgotLS0KCiMjIFdoYXQgeW91IGdldAoK
  >> "!B64TMP!" echo QSBzaW5nbGUgRG9ja2VyIENvbXBvc2Ugc3RhY2sgb2Ygc2l4IHJ1bm5pbmcgc2VydmljZXMgb24g
  >> "!B64TMP!" echo YSBwcml2YXRlIGJyaWRnZQpuZXR3b3JrIChzZXZlbiBhcmUgZGVmaW5lZCwgYnV0IHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsZXIgb25seSBzdGFydHMgb25lIG9mIHRoZSB0d28KYnJvd3NlciBlbmdpbmVzIGJlbG93KSwg
  >> "!B64TMP!" echo KipwbHVzKiogYSByZWFkeS1tYWRlIGFnZW50IHNraWxsIHRoYXQgdGllcyBpdCBhbGwKdG9nZXRo
  >> "!B64TMP!" echo ZXI6Cgp8IFNlcnZpY2UgfCBJbWFnZSB8IFJvbGUgfAp8LS0tLS0tLS0tfC0tLS0tLS18LS0tLS0t
  >> "!B64TMP!" echo fAp8ICoqc2VhcnhuZyoqIHwgYHNlYXJ4bmcvc2VhcnhuZzpsYXRlc3RgIHwgTWV0YXNlYXJjaCBl
  >> "!B64TMP!" echo bmdpbmUgd2l0aCAqKkpTT04gb3V0cHV0IGVuYWJsZWQqKiBhbmQgdGhlIHJhdGUtbGltaXRlciAq
  >> "!B64TMP!" echo KmRpc2FibGVkKiosIHNvIG1vZGVscyBjYW4gcXVlcnkgaXQgcHJvZ3JhbW1hdGljYWxseS4gfAp8
  >> "!B64TMP!" echo ICoqZmlyZWNyYXdsKiogfCBgZ2hjci5pby9maXJlY3Jhd2wvZmlyZWNyYXdsOmxhdGVzdGAgfCBU
  >> "!B64TMP!" echo aGUgc2NyYXBpbmcvY3Jhd2xpbmcvc2VhcmNoIEFQSS4gUnVucyB3aXRoIGBVU0VfREJfQVVUSEVO
  >> "!B64TMP!" echo VElDQVRJT049ZmFsc2VgIOKGkiAqKm5vIEFQSSBrZXkgbmVlZGVkKiogZm9yIGxvY2FsIHVzZS4g
  >> "!B64TMP!" echo fAp8ICoqcGxheXdyaWdodC1zZXJ2aWNlKiogKihkZWZhdWx0IGVuZ2luZSkqIHwgYGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZTpsYXRlc3RgIHwgSGVhZGxlc3MgQ2hyb21pdW0g
  >> "!B64TMP!" echo Zm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFnZXMg4oCUIHRoZSBjbGFzc2ljIEZpcmVjcmF3bCBl
  >> "!B64TMP!" echo bmdpbmUuIFN0YXJ0cyB3aGVuIHRoZSBpbnN0YWxsZXIncyBTdGVwIDQgYW5zd2VyIGlzIFBsYXl3
  >> "!B64TMP!" echo cmlnaHQgKHRoZSBkZWZhdWx0KS4gfAp8ICoqYnJvd3Nlcmxlc3MqKiAqKGFsdGVybmF0ZSBlbmdp
  >> "!B64TMP!" echo bmUpKiB8IGBnaGNyLmlvL2Jyb3dzZXJsZXNzL2Nocm9taXVtOmxhdGVzdGAgfCBTdGVhbHRoIGhl
  >> "!B64TMP!" echo YWRsZXNzIENocm9taXVtIChCcm93c2VybGVzcyBDRSwgYERFRkFVTFRfU1RFQUxUSD10cnVlYCkg
  >> "!B64TMP!" echo Zm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFnZXM7IGJldHRlciBhdCBhdm9pZGluZyBDbG91ZGZs
  >> "!B64TMP!" echo YXJlLXN0eWxlIGJvdCBjaGVja3MuIFN0YXJ0cyBpbnN0ZWFkIG9mIFBsYXl3cmlnaHQgd2hlbiBT
  >> "!B64TMP!" echo dGVwIDQgaXMgYW5zd2VyZWQgKip5KiouIHwKfCAqKnJlZGlzKiogfCBgcmVkaXM6YWxwaW5lYCB8
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBqb2IgcXVldWUuIHwKfCAqKnJhYmJpdG1xKiogfCBgcmFiYml0bXE6My1tYW5h
  >> "!B64TMP!" echo Z2VtZW50YCB8IEZpcmVjcmF3bCBtZXNzYWdlIGJyb2tlci4gfAp8ICoqbnVxLXBvc3RncmVzKiog
  >> "!B64TMP!" echo fCBgZ2hjci5pby9maXJlY3Jhd2wvbnVxLXBvc3RncmVzOmxhdGVzdGAgfCBGaXJlY3Jhd2wgam9i
  >> "!B64TMP!" echo LXN0YXRlIERCIChwZ19jcm9uIGVuYWJsZWQpLiB8CgpPbiB0b3Agb2YgdGhlIGNvbnRhaW5lcnMs
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIgYnVuZGxlcyAqKmxvY2FsLXdlYi1zZWFyY2gqKiDigJQgYSBza2lsbCBm
  >> "!B64TMP!" echo b3IKYWdlbnRzIHRoYXQgbG9hZCBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gIChgQzpc
  >> "!B64TMP!" echo VXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAKb24gV2luZG93cykuIEl0IGdpdmVzIHRoZSBhZ2Vu
  >> "!B64TMP!" echo dCBhIGNvbXBsZXRlIHdlYi1yZXNlYXJjaCB3b3JrZmxvdzogc2VhcmNoIHZpYQpTZWFyWE5HLCBy
  >> "!B64TMP!" echo ZWFkIHBhZ2VzIHZpYSBGaXJlY3Jhd2wsIGFuZCBldmVuIHN0YXJ0IHRoZSBEb2NrZXIgc3RhY2sK
  >> "!B64TMP!" echo YXV0b21hdGljYWxseSB3aGVuIGl0J3MgZG93bi4gU2VlIFtzZWN0aW9uIEFdKCNhLXRoZS1idW5k
  >> "!B64TMP!" echo bGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpLgoKT25seSAqKnR3byBob3N0
  >> "!B64TMP!" echo IHBvcnRzKiogYXJlIHB1Ymxpc2hlZCAoYDk5OTBgIGFuZCBgOTk5MWAgYnkgZGVmYXVsdCkuIEV2
  >> "!B64TMP!" echo ZXJ5dGhpbmcKZWxzZSBzdGF5cyBvbiB0aGUgcHJpdmF0ZSBgbG9jYWwtc2VhcmNoLW5ldGAgYnJp
  >> "!B64TMP!" echo ZGdlIG5ldHdvcmsuIEZpcmVjcmF3bCdzCmAvdjEvc2VhcmNoYCBlbmRwb2ludCBpcyBhdXRvbWF0
  >> "!B64TMP!" echo aWNhbGx5IHdpcmVkIHRvIFNlYXJYTkcgaW50ZXJuYWxseSwgc28gYSBzaW5nbGUKRmlyZWNyYXds
  >> "!B64TMP!" echo IGNhbGwgY2FuIGJvdGggc2VhcmNoICphbmQqIGZldGNoIGZ1bGwgcGFnZSBjb250ZW50LgoKLS0t
  >> "!B64TMP!" echo CgojIyBSZXF1aXJlbWVudHMKCi0gKipEb2NrZXIqKiB3aXRoIHRoZSAqKkNvbXBvc2UgdjIgcGx1
  >> "!B64TMP!" echo Z2luKiogKGBkb2NrZXIgY29tcG9zZWApLgogIC0gV2luZG93cyAvIG1hY09TOiBbRG9ja2VyIERl
  >> "!B64TMP!" echo c2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJvZHVjdHMvZG9ja2VyLWRlc2t0b3AvKQog
  >> "!B64TMP!" echo IC0gTGludXg6IFtEb2NrZXIgRW5naW5lXShodHRwczovL2RvY3MuZG9ja2VyLmNvbS9lbmdpbmUv
  >> "!B64TMP!" echo aW5zdGFsbC8pICsgdGhlIGBkb2NrZXItY29tcG9zZS1wbHVnaW5gIHBhY2thZ2UuIEFkZCB5b3Vy
  >> "!B64TMP!" echo IHVzZXIgdG8gdGhlIGBkb2NrZXJgIGdyb3VwIHNvIHlvdSBkb24ndCBuZWVkIGBzdWRvYC4KLSAq
  >> "!B64TMP!" echo Kn41IEdCIGZyZWUgZGlzayoqIGZvciBpbWFnZXMgYW5kIGRhdGEuCi0gKio4IEdCIFJBTSAvIDQg
  >> "!B64TMP!" echo Q1BVIGNvcmVzKiogcmVjb21tZW5kZWQgKEZpcmVjcmF3bCBwbHVzIGl0cyBicm93c2VyIGVuZ2lu
  >> "!B64TMP!" echo ZSDigJQgUGxheXdyaWdodCBvciBCcm93c2VybGVzcyDigJQgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJl
  >> "!B64TMP!" echo ZHVjZSByZXNvdXJjZSBsaW1pdHMgaW4gYGRvY2tlci1jb21wb3NlLnltbGAgZm9yIHNtYWxsZXIg
  >> "!B64TMP!" echo aG9zdHMpLgotICoqUHl0aG9uIDMuOCsqKiBmb3IgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJj
  >> "!B64TMP!" echo aCBza2lsbCBzY3JpcHRzIChvcHRpb25hbCBidXQgcmVjb21tZW5kZWQg4oCUIGl0J3MgdGhlIGVh
  >> "!B64TMP!" echo c2llc3Qgd2F5IHRvIHVzZSB0aGUgc3RhY2spLgotICooT3B0aW9uYWwsIGZvciBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo QUkgZmVhdHVyZXMpKiAqKkxNIFN0dWRpbyoqIG9yIGFueSBPcGVuQUktY29tcGF0aWJsZSBlbmRw
  >> "!B64TMP!" echo b2ludCwgbG9jYWwgb3IgcmVtb3RlIOKAlCBzZWUgW3NlY3Rpb24gRF0oI2QtY29ubmVjdC1hbi1s
  >> "!B64TMP!" echo bG0tbG0tc3R1ZGlvLWV0YykuCi0gKihPcHRpb25hbCwgZm9yIE1DUCkqICoqTm9kZS5qcyAxOCsq
  >> "!B64TMP!" echo KiBzbyBgbnB4IGZpcmVjcmF3bC1tY3BgIHdvcmtzLgoKVmVyaWZ5IERvY2tlciBpcyByZWFkeToK
  >> "!B64TMP!" echo CmBgYGJhc2gKZG9ja2VyIGluZm8gICAgICAgICAgICAjIGVuZ2luZSBpcyBydW5uaW5nCmRvY2tl
  >> "!B64TMP!" echo ciBjb21wb3NlIHZlcnNpb24gIyB2MiBpcyBpbnN0YWxsZWQKYGBgCgotLS0KCiMjIFF1aWNrIHN0
  >> "!B64TMP!" echo YXJ0IChvbmUtY2xpY2sgaW5zdGFsbCkKCj4gKipUaGUgaW5zdGFsbGVyIGlzIHNlbGYtY29udGFp
  >> "!B64TMP!" echo bmVkLioqIEV2ZXJ5IGZpbGUgaXQgbmVlZHMgKGBkb2NrZXItY29tcG9zZS55bWxgLAo+IGBjb25m
  >> "!B64TMP!" echo aWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgLCBgLmVudi5leGFtcGxlYCwgdGhlIGJ1bmRsZWQgYGxv
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2hgIHNraWxsLAo+IGFsbCB0aGUgcnVuL3N0b3AvdXBkYXRlL3VuaW5zdGFs
  >> "!B64TMP!" echo bCBzY3JpcHRzLCB0aGlzIFJFQURNRSwgYW5kIGV2ZW4gdGhlICpvdGhlcioKPiBwbGF0Zm9ybSdz
  >> "!B64TMP!" echo IGluc3RhbGxlcikgaXMgZW1iZWRkZWQgaW5zaWRlIGl0LiBZb3UgY2FuIGRvd25sb2FkICoqanVz
  >> "!B64TMP!" echo dAo+IGBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKFdpbmRvd3MpIG9yICoqanVzdCBgaW5z
  >> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guc2hgKioKPiAoTGludXgvbWFjT1MpIG9uIGl0cyBvd24gYW5kIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsZXIgd2lsbCBzdGlsbCBwcm9kdWNlIGEgY29tcGxldGUsCj4gd29ya2luZyBmb2xk
  >> "!B64TMP!" echo ZXIuIERvd25sb2FkaW5nIHRoZSB3aG9sZSBgbG9jYWwtc2VhcmNoYCBmb2xkZXIgb3IgdGhlIHpp
  >> "!B64TMP!" echo cCBqdXN0Cj4gbWFrZXMgdGhlIGluc3RhbGwgYSBsaXR0bGUgZmFzdGVyIChpdCBjb3BpZXMgZmls
  >> "!B64TMP!" echo ZXMgaW5zdGVhZCBvZiBkZWNvZGluZyB0aGVtKS4KClJ1biAqKm9uZSoqIGluc3RhbGxlciBmb3Ig
  >> "!B64TMP!" echo eW91ciBwbGF0Zm9ybS4gRmlyc3QgaXQgYXNrcyB3aGljaCBzZXR1cCB5b3Ugd2FudCDigJQKdHlw
  >> "!B64TMP!" echo ZSAqKjEqKiwgKioyKiogb3IgKiozKiogKG9yIHByZXNzICoqRW50ZXIqKiBmb3IgKioxKiopOgoK
  >> "!B64TMP!" echo fCBDaG9pY2UgfCBTZXR1cCB8IFdoYXQgaXQgZG9lcyB8CnwgLS0tIHwgLS0tIHwgLS0tIHwKfCAq
  >> "!B64TMP!" echo KjEqKiAoZGVmYXVsdCkgfCBNaW5pbWFsIGluc3RhbGxhdGlvbiB8IERlZmF1bHQgZm9sZGVyLCBT
  >> "!B64TMP!" echo ZWFyWE5HIG9uIGA5OTkwYCwgRmlyZWNyYXdsIG9uIGA5OTkxYCwgdGhlIFBsYXl3cmlnaHQgYnJv
  >> "!B64TMP!" echo d3NlciBlbmdpbmUsIG5vIHF1ZXN0aW9ucyBhdCBhbGwsIG5vIExMTSwgbm8gRmlyZWNyYXdsIGFj
  >> "!B64TMP!" echo Y291bnQ6IGEgdHJ1ZSBvbmUtY2xpY2sgaW5zdGFsbC4gfAp8ICoqMioqIHwgTWluaW1hbCArIExM
  >> "!B64TMP!" echo TSBleHRyYWN0aW9uIHwgVGhlIHNhbWUgZGVmYXVsdHMsIHBsdXMgdGhyZWUgcXVlc3Rpb25zIHRv
  >> "!B64TMP!" echo IGNvbm5lY3QgYW4gTExNIChiYXNlIFVSTCwgQVBJIGtleSwgbW9kZWwpLiB8CnwgKiozKiogfCBG
  >> "!B64TMP!" echo dWxsIGluc3RhbGxhdGlvbiB8IFRoZSBmdWxsIHNpeC1zdGVwIHNldHVwIOKAlCBpbnN0YWxsIGZv
  >> "!B64TMP!" echo bGRlciwgU2VhclhORyBwb3J0LCBGaXJlY3Jhd2wgcG9ydCwgYSBicm93c2VyIHJlbmRlcmluZyBl
  >> "!B64TMP!" echo bmdpbmUgKFBsYXl3cmlnaHQgb3IgQnJvd3Nlcmxlc3MpLCAob3B0aW9uYWxseSkgYW4gTExNLCBh
  >> "!B64TMP!" echo bmQgKG9wdGlvbmFsbHkpIGEgRmlyZWNyYXdsIGFjY291bnQg4oCUIHdpdGggdGhlIHNhbWUgZGVm
  >> "!B64TMP!" echo YXVsdHMgb2ZmZXJlZCBhdCBlYWNoIHN0ZXAgaWYgeW91IGp1c3QgcHJlc3MgKipFbnRlcioqLiB8
  >> "!B64TMP!" echo CgpFaXRoZXIgd2F5IGl0IHRoZW4gZ2VuZXJhdGVzCmNyeXB0b2dyYXBoaWNhbGx5LXNlY3VyZSBj
  >> "!B64TMP!" echo cmVkZW50aWFscywgd3JpdGVzIHlvdXIgYC5lbnZgLCAqKmluc3RhbGxzIHRoZQpsb2NhbC13ZWIt
  >> "!B64TMP!" echo c2VhcmNoIHNraWxsKiosIHB1bGxzIHRoZSBpbWFnZXMsIGFuZCBzdGFydHMgdGhlIHN0YWNrLgoK
  >> "!B64TMP!" echo PiAqKkRvY2tlciBpc24ndCBydW5uaW5nPyoqIE5vIHByb2JsZW0g4oCUIHRoZSBpbnN0YWxsZXIg
  >> "!B64TMP!" echo c3RhcnRzIGl0IGZvciB5b3U6IGl0Cj4gbGF1bmNoZXMgRG9ja2VyIERlc2t0b3AgKFdpbmRvd3Mv
  >> "!B64TMP!" echo bWFjT1MpIG9yIHRoZSBEb2NrZXIgc2VydmljZQo+IChgc3lzdGVtY3RsYC9gc2VydmljZWAsIExp
  >> "!B64TMP!" echo bnV4KSBhbmQgd2FpdHMgdXAgdG8gNSBtaW51dGVzIGZvciB0aGUgZW5naW5lIHdoaWxlCj4geW91
  >> "!B64TMP!" echo IGFuc3dlciB0aGUgcHJvbXB0cy4gKE92ZXJyaWRlIHRoZSB3YWl0IHdpdGggdGhlCj4gYExPQ0FM
  >> "!B64TMP!" echo X1NFQVJDSF9ET0NLRVJfVElNRU9VVGAgZW52IHZhciwgaW4gc2Vjb25kcy4pCgojIyMgV2luZG93
  >> "!B64TMP!" echo cwoKMS4gSW5zdGFsbCBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJv
  >> "!B64TMP!" echo ZHVjdHMvZG9ja2VyLWRlc2t0b3AvKSDigJQgbm8gbmVlZCB0byBvcGVuIGl0IGZpcnN0OyB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyIGxhdW5jaGVzIGl0IGF1dG9tYXRpY2FsbHkuCjIuIERvdWJsZS1jbGljayAqKmBp
  >> "!B64TMP!" echo bnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKG9yIHJ1biBpdCBmcm9tIGEgdGVybWluYWwpLgoK
  >> "!B64TMP!" echo YGBgCj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PQogIFNldHVwIHR5cGUKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09CiAgMSkgTWluaW1hbCBpbnN0YWxsYXRpb24KICAyKSBN
  >> "!B64TMP!" echo aW5pbWFsICsgTExNIGV4dHJhY3Rpb24KICAzKSBGdWxsIGluc3RhbGxhdGlvbgogIERlZmF1bHRz
  >> "!B64TMP!" echo OiBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoLCBTZWFyWE5HIDk5OTAsIEZpcmVjcmF3bCA5OTkx
  >> "!B64TMP!" echo LAogIFBsYXl3cmlnaHQgZW5naW5lLCBubyBGaXJlY3Jhd2wgYWNjb3VudC4KICBDaG9vc2UgMSwg
  >> "!B64TMP!" echo MiBvciAzIFtFbnRlciA9IDFdOgpgYGAKCioqMSoqIHNraXBzIGV2ZXJ5IHF1ZXN0aW9uIGFuZCBp
  >> "!B64TMP!" echo bnN0YWxscy4gKioyKiogYXNrcyBvbmx5IGZvciB0aGUgTExNIChiYXNlIFVSTCwKQVBJIGtleSwg
  >> "!B64TMP!" echo bW9kZWwpLCB0aGVuIGluc3RhbGxzLiAqKjMqKiB3YWxrcyB0aHJvdWdoIHRoZSBmdWxsIHNldHVw
  >> "!B64TMP!" echo OgoKYGBgCi0tLSBTdGVwIDEgb2YgNjogSW5zdGFsbCBsb2NhdGlvbiAtLS0tLS0tLS0tCiAgVGFy
  >> "!B64TMP!" echo Z2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAgICAgICAgICAgICMgQzpcVXNl
  >> "!B64TMP!" echo cnNcWW91XGxvY2FsLXNlYXJjaAotLS0gU3RlcCAyIG9mIDY6IFNlYXJYTkcgcG9ydCAoZGVmYXVs
  >> "!B64TMP!" echo dCA5OTkwKSAtLS0tLS0KICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06
  >> "!B64TMP!" echo IDk5OTAKLS0tIFN0ZXAgMyBvZiA2OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSAtLS0t
  >> "!B64TMP!" echo CiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06IDk5OTEKLS0tIFN0
  >> "!B64TMP!" echo ZXAgNCBvZiA2OiBCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUgKGRlZmF1bHQ6IFBsYXl3cmlnaHQp
  >> "!B64TMP!" echo IC0tLQogIFVzZSBCcm93c2VybGVzcyBpbnN0ZWFkIG9mIFBsYXl3cmlnaHQ/IFt5L05dOiAgICAg
  >> "!B64TMP!" echo ICAgICMgZGVmYXVsdDogUGxheXdyaWdodCwgc2VlIGJlbG93Ci0tLSBTdGVwIDUgb2YgNjogTExN
  >> "!B64TMP!" echo IChvcHRpb25hbCkgLS0tLS0tLS0tLS0tLS0tLS0tLQogIENvbm5lY3QgTExNIG5vdz8gW3kvTl06
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICMgZGVmYXVsdDogbm8sIHNlZSBzZWN0aW9u
  >> "!B64TMP!" echo IEQKLS0tIFN0ZXAgNiBvZiA2OiBGaXJlY3Jhd2wgYWNjb3VudCAob3B0aW9uYWwpIC0tLS0tCiAg
  >> "!B64TMP!" echo QWRkIGEgRmlyZWNyYXdsIGFjY291bnQgbm93PyBbeS9OXTogbiAgICAgICAgICAgICAgICAgIyBk
  >> "!B64TMP!" echo ZWZhdWx0OiBza2lwLCBzZWUgYmVsb3cKYGBgCgojIyMgTGludXggJiBtYWNPUwoKYGBgYmFzaApj
  >> "!B64TMP!" echo aG1vZCAreCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaAouL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNo
  >> "!B64TMP!" echo CmBgYAoKVGhlIHByb21wdHMgYXJlIHRoZSBzYW1lLiBEZWZhdWx0czogaW5zdGFsbCB0byBgfi9s
  >> "!B64TMP!" echo b2NhbC1zZWFyY2hgLCBTZWFyWE5HIG9uCmA5OTkwYCwgRmlyZWNyYXdsIG9uIGA5OTkxYCwgUGxh
  >> "!B64TMP!" echo eXdyaWdodCBhcyB0aGUgYnJvd3NlciBlbmdpbmUsIG5vIEZpcmVjcmF3bAphY2NvdW50IChhbmQg
  >> "!B64TMP!" echo YW4gTExNIG9ubHkgaWYgeW91IHBpY2sgc2V0dXAgKioyKiogb3IgYW5zd2VyICoqeSoqIGluIHNl
  >> "!B64TMP!" echo dHVwICoqMyoqKS4gQSBzdG9wcGVkIERvY2tlciBlbmdpbmUgaXMgc3RhcnRlZCBhdXRvbWF0aWNh
  >> "!B64TMP!" echo bGx5CihEb2NrZXIgRGVza3RvcCBvbiBtYWNPUywgYHN5c3RlbWN0bGAvYHNlcnZpY2VgIG9uIExp
  >> "!B64TMP!" echo bnV4KS4KCj4gKipPbmUtY2xpY2sgaW5zdGFsbC4qKiBUaGUgdmVyeSBmaXJzdCBxdWVzdGlvbiBp
  >> "!B64TMP!" echo cyB0aGUgc2V0dXAgdHlwZS4gQ2hvaWNlCj4gKioxKiogKHRoZSBFbnRlciBkZWZhdWx0KSBza2lw
  >> "!B64TMP!" echo cyBldmVyeSBxdWVzdGlvbiBhbmQgaW5zdGFsbHMgd2l0aCB0aGUgZGVmYXVsdHMKPiBzaG93biBh
  >> "!B64TMP!" echo Ym92ZTsgY2hvaWNlICoqMioqIGFza3Mgb25seSB0aGUgdGhyZWUgTExNIHF1ZXN0aW9uczsgY2hv
  >> "!B64TMP!" echo aWNlCj4gKiozKiogZ29lcyB0aHJvdWdoIGFsbCBzaXggbnVtYmVyZWQgc3RlcHMgYmVsb3cgc28g
  >> "!B64TMP!" echo eW91IGNhbiBjdXN0b21pemUKPiBhbnl0aGluZy4gRWl0aGVyIHdheSB5b3UgY2FuIHN0aWxsIGNo
  >> "!B64TMP!" echo YW5nZSB5b3VyIG1pbmQgYWZ0ZXJ3YXJkIGJ5IGVkaXRpbmcKPiBgLmVudmAgYW5kIHJ1bm5pbmcg
  >> "!B64TMP!" echo YFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCj4gKipUaGUgb3B0aW9uYWwgTExNIChTdGVw
  >> "!B64TMP!" echo IDUsIG9yIHNldHVwIDIpLioqIEFueSBPcGVuQUktY29tcGF0aWJsZSBlbmRwb2ludAo+IHdvcmtz
  >> "!B64TMP!" echo LCBsb2NhbCBvciByZW1vdGU6IHRoZSBpbnN0YWxsZXIgYXNrcyBmb3IgaXRzIGJhc2UgVVJMIChk
  >> "!B64TMP!" echo ZWZhdWx0Cj4gYGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MWAsIExNIFN0dWRpbyksIGFuIEFQSSBr
  >> "!B64TMP!" echo ZXkgKEVudGVyIHRvIHNraXApIGFuZCBhCj4gbW9kZWwgbmFtZSAoRW50ZXIgdG8gc2tpcCksIGFu
  >> "!B64TMP!" echo ZCB3cml0ZXMgdGhlbSB0byBgLmVudmAuIFRoZSBleHRyYWN0aW9uIHRvb2wKPiBgd2ViX2V4dHJh
  >> "!B64TMP!" echo Y3QucHlgIGFuZCB0aGUgc2tpbGwncyAiTExNIGV4dHJhY3Rpb24iIHNlY3Rpb24gYXJlIGluc3Rh
  >> "!B64TMP!" echo bGxlZAo+ICoqb25seSoqIHdoZW4gYW4gTExNIGlzIGNvbm5lY3RlZDsgd2l0aG91dCBvbmUgdGhl
  >> "!B64TMP!" echo IGluc3RhbGxlZCBza2lsbCBkb2VzIG5vdAo+IG1lbnRpb24gdGhlbS4gU2VlIFtzZWN0aW9uIERd
  >> "!B64TMP!" echo KCNkLWNvbm5lY3QtYW4tbGxtLWxtLXN0dWRpby1ldGMpLgoKPiAqKlRoZSBicm93c2VyIHJlbmRl
  >> "!B64TMP!" echo cmluZyBlbmdpbmUgKFN0ZXAgNCkuKiogRmlyZWNyYXdsIG5lZWRzIGEgaGVhZGxlc3MKPiBicm93
  >> "!B64TMP!" echo c2VyIHRvIGZldGNoIEpTLXJlbmRlcmVkIHBhZ2VzLiBUaGUgZGVmYXVsdCBhbnN3ZXIsICoqTioq
  >> "!B64TMP!" echo LCBrZWVwcwo+ICoqUGxheXdyaWdodCoqIOKAlCB0aGUgY2xhc3NpYyBGaXJlY3Jhd2wgZW5naW5l
  >> "!B64TMP!" echo IChgZ2hjci5pby9maXJlY3Jhd2wvcGxheXdyaWdodC1zZXJ2aWNlYCkuCj4gQW5zd2VyaW5nICoq
  >> "!B64TMP!" echo eSoqIHN3aXRjaGVzIHRvICoqQnJvd3Nlcmxlc3MqKiAoYGdoY3IuaW8vYnJvd3Nlcmxlc3MvY2hy
  >> "!B64TMP!" echo b21pdW1gKQo+IGluc3RlYWQsIHJ1biBpbiBpdHMgYnVpbHQtaW4gc3RlYWx0aCBtb2RlLCB3aGlj
  >> "!B64TMP!" echo aCBtYXNrcyBjb21tb24gYXV0b21hdGlvbgo+IGZpbmdlcnByaW50cyAoZS5nLiBgbmF2aWdhdG9y
  >> "!B64TMP!" echo LndlYmRyaXZlcmApIGFuZCB0ZW5kcyB0byBnZXQgYmxvY2tlZCBsZXNzCj4gb2Z0ZW4gYnkgQ2xv
  >> "!B64TMP!" echo dWRmbGFyZS1zdHlsZSBib3QgY2hlY2tzLiBPbmx5IHRoZSBlbmdpbmUgeW91IHBpY2sgaXMgYWN0
  >> "!B64TMP!" echo dWFsbHkKPiBzdGFydGVkIOKAlCB0aGUgaW5zdGFsbGVyIHdyaXRlcyBgQ09NUE9TRV9QUk9GSUxF
  >> "!B64TMP!" echo U2AgYW5kCj4gYFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTGAgdG8gYC5lbnZgIGFjY29yZGlu
  >> "!B64TMP!" echo Z2x5LiBUbyBzd2l0Y2ggbGF0ZXIsIGVkaXQKPiB0aG9zZSB0d28gbGluZXMgaW4gYC5lbnZgIGFu
  >> "!B64TMP!" echo ZCBydW4gYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCj4gKipUaGUgb3B0aW9uYWwgRmly
  >> "!B64TMP!" echo ZWNyYXdsIGFjY291bnQgKFN0ZXAgNikuKiogQSBmZXcgb2YgdGhlIGJ1bmRsZWQgc2tpbGwncwo+
  >> "!B64TMP!" echo IHRvb2xzIOKAlCB0aGUgcmVzZWFyY2ggYWdlbnQsIGxpdmUtcGFnZSBgaW50ZXJhY3RgLCBmaWxl
  >> "!B64TMP!" echo IGBwYXJzZWAsIG1vbml0b3JzLAo+IHBhcGVyIHJlc2VhcmNoLCBhbmQgR2l0SHViL2RldmVsb3Bl
  >> "!B64TMP!" echo ciBzZWFyY2gg4oCUIG9ubHkgd29yayBhZ2FpbnN0IEZpcmVjcmF3bCdzCj4gcGFpZCBjbG91ZCBB
  >> "!B64TMP!" echo UEkuIFRoZSBkZWZhdWx0IGFuc3dlciBpcyAqKk4qKjogdGhvc2UgdG9vbHMgYXJlIHNpbXBseSAq
  >> "!B64TMP!" echo bm90Cj4gaW5zdGFsbGVkKiwgYW5kIHRoZSBza2lsbCBzaGlwcyBhIGxlYW5lciBgU0tJTEwubWRg
  >> "!B64TMP!" echo IGNvdmVyaW5nIGp1c3QgdGhlIGZyZWUKPiBsb2NhbCB0b29scy4gQW5zd2VyICoqeSoqIGluc3Rl
  >> "!B64TMP!" echo YWQgYW5kIHRoZSBpbnN0YWxsZXIgYXNrcyBmb3IgeW91ciBBUEkga2V5Cj4gKGFuZCBBUEkgVVJM
  >> "!B64TMP!" echo LCBkZWZhdWx0IGBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2YCksIHN0b3JlcyB0aGVtIGluIHlv
  >> "!B64TMP!" echo dXIKPiBgLmVudmAsIGFuZCBpbnN0YWxscyBhbGwgMjUgdG9vbHMgKDI2IHdpdGggTExNIGV4dHJh
  >> "!B64TMP!" echo Y3Rpb24pLiBZb3UgY2FuIGNoYW5nZSB5b3VyIG1pbmQgbGF0ZXIKPiBieSByZS1ydW5uaW5nIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsZXIgYW5kIGFuc3dlcmluZyBkaWZmZXJlbnRseS4KCj4gKipGaXJzdCBydW4gZG93
  >> "!B64TMP!" echo bmxvYWRzIH4z4oCTNCBHQiBvZiBEb2NrZXIgaW1hZ2VzKiogKFBsYXl3cmlnaHQncyBhbmQgQnJv
  >> "!B64TMP!" echo d3Nlcmxlc3Mncwo+IGltYWdlcyBlYWNoIGJ1bmRsZSBhIGZ1bGwgQ2hyb21pdW0sIHNvIG9ubHkg
  >> "!B64TMP!" echo dGhlIG9uZSB5b3UgcGlja2VkIGlzIHB1bGxlZCkuCj4gU3Vic2VxdWVudCBzdGFydHMgYXJlIGEg
  >> "!B64TMP!" echo ZmV3IHNlY29uZHMuCgpXaGVuIGl0IGZpbmlzaGVzIHlvdSdsbCBzZWU6CgpgYGAKU2VhclhORyAg
  >> "!B64TMP!" echo KHNlYXJjaCArIEpTT04gQVBJKTogIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MApGaXJlY3Jhd2wgKHNj
  >> "!B64TMP!" echo cmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9jYWxob3N0Ojk5OTEKQWdlbnQgc2tpbGw6IEM6XFVz
  >> "!B64TMP!" echo ZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWItc2VhcmNoICAgKG9yIH4vLmFnZW50cy9z
  >> "!B64TMP!" echo a2lsbHMvbG9jYWwtd2ViLXNlYXJjaCkKYGBgCgpPcGVuIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBg
  >> "!B64TMP!" echo IGluIGEgYnJvd3NlciB0byBzZWUgdGhlIFNlYXJYTkcgc2VhcmNoIFVJIOKAlCBvciwKaWYgeW91
  >> "!B64TMP!" echo ciBhZ2VudCBsb2FkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gLCBqdXN0IGFzayBp
  >> "!B64TMP!" echo dCB0byByZXNlYXJjaApzb21ldGhpbmcgY3VycmVudCBhbmQgaXQgd2lsbCB1c2UgKipsb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoKiogYXV0b21hdGljYWxseSAoc2VlCltzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVk
  >> "!B64TMP!" echo LWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpKS4KCi0tLQoKIyMgTWFuYWdpbmcg
  >> "!B64TMP!" echo dGhlIHN0YWNrCgpBZnRlciBpbnN0YWxsLCB0aGUgbWFuYWdlbWVudCBzY3JpcHRzIGxpdmUgKipp
  >> "!B64TMP!" echo biB5b3VyIGluc3RhbGwgZm9sZGVyKioKKGBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoYCBvbiBX
  >> "!B64TMP!" echo aW5kb3dzLCBgfi9sb2NhbC1zZWFyY2hgIG9uIExpbnV4L21hY09TKS4KVGhleSBhdXRvLWRldGVj
  >> "!B64TMP!" echo dCB0aGVpciBvd24gbG9jYXRpb24sIHNvIHlvdSBjYW4gcnVuIHRoZW0gZnJvbSBhbnl3aGVyZSBi
  >> "!B64TMP!" echo eQpkb3VibGUtY2xpY2tpbmcgb3IgYC4vYC1pbmcgdGhlbS4KCnwgQWN0aW9uIHwgV2luZG93cyB8
  >> "!B64TMP!" echo IExpbnV4IC8gbWFjT1MgfAp8LS0tLS0tLS18LS0tLS0tLS0tfC0tLS0tLS0tLS0tLS0tLXwKfCAq
  >> "!B64TMP!" echo KlN0YXJ0KiogdGhlIHN0YWNrIHwgYFJ1bi5iYXRgIHwgYC4vcnVuLnNoYCB8CnwgKipTdG9wKiog
  >> "!B64TMP!" echo KGtlZXAgZGF0YSkgfCBgU3RvcC5iYXRgIHwgYC4vc3RvcC5zaGAgfAp8ICoqVXBkYXRlKiogaW1h
  >> "!B64TMP!" echo Z2VzICsgYXBwbHkgYC5lbnZgIGNoYW5nZXMgKyAqKnJlLXN5bmMgdGhlIHNraWxsKiogfCBgVXBk
  >> "!B64TMP!" echo YXRlLmJhdGAgfCBgLi91cGRhdGUuc2hgIHwKfCAqKlVuaW5zdGFsbCoqIChjb250YWluZXJzICsg
  >> "!B64TMP!" echo dm9sdW1lcyArIHNraWxsLCBvcHRpb25hbCBmb2xkZXIgZGVsZXRlKSB8IGBVbmluc3RhbGwuYmF0
  >> "!B64TMP!" echo YCB8IGAuL3VuaW5zdGFsbC5zaGAgfAoKLSAqKlN0b3AqKiBvbmx5IHJlbW92ZXMgY29udGFpbmVy
  >> "!B64TMP!" echo czsgeW91ciBkYXRhIHZvbHVtZXMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsCiAgcmVkaXMgY2FjaGUs
  >> "!B64TMP!" echo IHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpIGFyZSBwcmVzZXJ2ZWQuCi0gKipVcGRhdGUqKiBydW5z
  >> "!B64TMP!" echo IGBkb2NrZXIgY29tcG9zZSBwdWxsYCB0aGVuIGBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHNvIGl0
  >> "!B64TMP!" echo CiAgYm90aCB1cGdyYWRlcyBpbWFnZXMgKiphbmQqKiBhcHBsaWVzIGFueSBwb3J0L0xMTSBlZGl0
  >> "!B64TMP!" echo cyB5b3UgbWFkZSB0byBgLmVudmA7CiAgaXQgYWxzbyByZS1jb3BpZXMgdGhlIGJ1bmRsZWQgYGxv
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2hgIHNraWxsIGludG8gYH4vLmFnZW50cy9za2lsbHMvYC4KLSAqKlVuaW5z
  >> "!B64TMP!" echo dGFsbCoqIHJ1bnMgYGRvY2tlciBjb21wb3NlIGRvd24gLXZgIChkZWxldGVzIHZvbHVtZXMgKyBk
  >> "!B64TMP!" echo YXRhKSwKICByZW1vdmVzIHRoZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tpbGwgZnJvbSBgfi8uYWdl
  >> "!B64TMP!" echo bnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoYCwgdGhlbgogIG9wdGlvbmFsbHkgZGVsZXRlcyB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbCBmb2xkZXIuIFB1bGxlZCBpbWFnZXMgYXJlIGtlcHQ7IHJlY2xhaW0gdGhlbQog
  >> "!B64TMP!" echo IHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAgaWYgZGVzaXJlZC4KCi0tLQoKIyMgSG93IGl0
  >> "!B64TMP!" echo IGZpdHMgdG9nZXRoZXIKCmBgYAogICAgICAgIHlvdXIgQUkgbW9kZWwgLyBhZ2VudCAobG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaCBza2lsbCkgLyBNQ1AgY2xpZW50IC8gY2hhdCBVSQogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAg4pSCCiAgIOKUjOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUvOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUkAogICDilrwgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICDilrwKaHR0cDovL2xvY2FsaG9zdDo5OTkwICAgICAgICAgICAgaHR0cDov
  >> "!B64TMP!" echo L2xvY2FsaG9zdDo5OTkxCiAgIOKUgiBTZWFyWE5HICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IOKUgiBGaXJlY3Jhd2wgQVBJCiAgIOKUgiAgLSAvc2VhcmNoP3E9Li4uJmZvcm1hdD1qc29uICAg
  >> "!B64TMP!" echo ICAgIOKUgiAgLSAvdjEvc2NyYXBlICAgKG9uZSBVUkwgLT4gbWFya2Rvd24pCiAgIOKUgiAgLSBh
  >> "!B64TMP!" echo Z2dyZWdhdGVzIH43MCBlbmdpbmVzICAgICAgICAgICDilIIgIC0gL3YxL2NyYXdsICAgICh3aG9s
  >> "!B64TMP!" echo ZSBzaXRlLCBhc3luYykKICAg4pSCICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IOKUgiAgLSAvdjEvbWFwICAgICAgKHNpdGUgVVJMIHRyZWUpCiAgIOKUgiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3YxL3NlYXJjaCAgICgtPiB1c2VzIFNlYXJY
  >> "!B64TMP!" echo TkchKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCICAtIC92
  >> "!B64TMP!" echo MS9leHRyYWN0ICAoLT4gdXNlcyB5b3VyIExMTSkKICAg4pSC4peE4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSA4pSA4pSA4pSAIHdpcmVkIHRvZ2V0aGVyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUpCAgU0VBUlhOR19FTkRQT0lOVD1odHRwOi8vc2VhcnhuZzo4MDgwCiAgIOKUgiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIKICAg4pSU4pSA4pSA4pSA4pSA4pSA4pSA
  >> "!B64TMP!" echo 4pSAIHByaXZhdGUgZG9ja2VyIG5ldHdvcmsg4pSA4pSA4pSA4pSA4pSA4pSA4pSYCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgbG9jYWwtc2VhcmNoLW5ldAogICBhbHNvIG9uIGl0OiBwbGF5d3JpZ2h0LXNlcnZp
  >> "!B64TMP!" echo Y2UgT1IgYnJvd3Nlcmxlc3MgKHdoaWNoZXZlciB5b3UgcGlja2VkIGluIFN0ZXAgNCksIHJlZGlz
  >> "!B64TMP!" echo LCByYWJiaXRtcSwgbnVxLXBvc3RncmVzCmBgYAoKRm91ciBrZXkgd2lyaW5nIGRlY2lzaW9ucyB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIG1ha2VzIGZvciB5b3U6CgoxLiAqKlNlYXJYTkcgSlNPTiArIG5vIGxpbWl0
  >> "!B64TMP!" echo ZXIqKiDigJQgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgc2V0cwogICBgc2VhcmNoLmZv
  >> "!B64TMP!" echo cm1hdHM6IFtodG1sLCBqc29uXWAgYW5kIGBzZXJ2ZXIubGltaXRlcjogZmFsc2VgLCBzbyBtb2Rl
  >> "!B64TMP!" echo bHMgY2FuIGhpdAogICBgL3NlYXJjaD9mb3JtYXQ9anNvbmAgd2l0aG91dCBiZWluZyBibG9ja2Vk
  >> "!B64TMP!" echo IGFzIGEgYm90LgoyLiAqKkZpcmVjcmF3bCDihpIgU2VhclhORyoqIOKAlCB0aGUgRmlyZWNyYXds
  >> "!B64TMP!" echo IGNvbnRhaW5lciBzZXRzCiAgIGBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODBg
  >> "!B64TMP!" echo LCBzbyBGaXJlY3Jhd2wncyBgL3YxL3NlYXJjaGAgdXNlcyB5b3VyCiAgIGxvY2FsIFNlYXJYTkcg
  >> "!B64TMP!" echo aW5zdGVhZCBvZiBuZWVkaW5nIGEgdGhpcmQtcGFydHkgc2VhcmNoIHByb3ZpZGVyLgozLiAqKkZp
  >> "!B64TMP!" echo cmVjcmF3bCDihpIgYnJvd3NlciBlbmdpbmUqKiDigJQgYGRvY2tlci1jb21wb3NlLnltbGAgZGVm
  >> "!B64TMP!" echo aW5lcyBib3RoCiAgIGBwbGF5d3JpZ2h0LXNlcnZpY2VgIGFuZCBgYnJvd3Nlcmxlc3NgIGJlaGlu
  >> "!B64TMP!" echo ZCBDb21wb3NlIHByb2ZpbGVzOyBgLmVudmAncwogICBgQ09NUE9TRV9QUk9GSUxFU2AgKHNldCBi
  >> "!B64TMP!" echo eSBTdGVwIDQpIGVuYWJsZXMganVzdCBvbmUsIGFuZAogICBgUExBWVdSSUdIVF9NSUNST1NFUlZJ
  >> "!B64TMP!" echo Q0VfVVJMYCBwb2ludHMgRmlyZWNyYXdsIGF0IGl0Lgo0LiAqKmxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwgYXV0by1pbnN0YWxsKiog4oCUIHRoZSBpbnN0YWxsZXIgY29waWVzIHRoZSBidW5kbGVkIHNr
  >> "!B64TMP!" echo aWxsIHRvCiAgIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvYCAoYWRkL292ZXJy
  >> "!B64TMP!" echo aWRlKSBhbmQgcmVjb3JkcyB0aGUgaW5zdGFsbCBwYXRoIGluCiAgIGFuIGBpbnN0YWxsLWRpci50
  >> "!B64TMP!" echo eHRgIGhpbnQgaW5zaWRlIHRoZSBza2lsbCwgc28gdGhlIHNraWxsIGZpbmRzIHRoZSBzdGFjayBl
  >> "!B64TMP!" echo dmVuCiAgIGlmIHlvdSBpbnN0YWxsZWQgdG8gYSBjdXN0b20gZm9sZGVyIGFuZCBEb2NrZXIgaXNu
  >> "!B64TMP!" echo J3QgcnVubmluZyB5ZXQuIFdpdGhvdXQgYQogICBjb25maWd1cmVkIEZpcmVjcmF3bCBhY2NvdW50
  >> "!B64TMP!" echo IGl0IGluc3RhbGxzIG9ubHkgdGhlIGZyZWUgbG9jYWwgdG9vbHMgYW5kIGEKICAgbWF0Y2hpbmcg
  >> "!B64TMP!" echo Y29yZS1vbmx5IGBTS0lMTC5tZGAuCgotLS0KCiMjIFVzaW5nIGl0IHdpdGggQUkgbW9kZWxzCgpU
  >> "!B64TMP!" echo aGVyZSBhcmUgKipzZXZlbioqIHdheXMgdG8gdXNlIHRoaXMgc3lzdGVtLCBmcm9tIGxvd2VzdCB0
  >> "!B64TMP!" echo byBoaWdoZXN0CmludGVncmF0aW9uLiBQaWNrIHdoYXQgZml0cyB5b3VyIHN0YWNrIOKAlCB5b3Ug
  >> "!B64TMP!" echo Y2FuIG1peCBhbmQgbWF0Y2guCgojIyMgQS4gVGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBz
  >> "!B64TMP!" echo a2lsbCAocmVjb21tZW5kZWQpCgpUaGUgaW5zdGFsbGVyIHNoaXBzIHdpdGggKipsb2NhbC13ZWIt
  >> "!B64TMP!" echo c2VhcmNoKiosIGFuIGFnZW50IHNraWxsIHRoYXQgdHVybnMgYW55CnNraWxsLWxvYWRpbmcgYWdl
  >> "!B64TMP!" echo bnQgaW50byBhIHdlYiByZXNlYXJjaGVyIHdpdGggemVybyBjb25maWd1cmF0aW9uLiBJZiB5b3Vy
  >> "!B64TMP!" echo CmFnZW50IHJlYWRzIHNraWxscyBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2AKKGBDOlxVc2Vyc1xZ
  >> "!B64TMP!" echo b3VcLmFnZW50c1xza2lsbHNcYCBvbiBXaW5kb3dzKSwgaXQncyBhbHJlYWR5IGF2YWlsYWJsZSBh
  >> "!B64TMP!" echo ZnRlcgppbnN0YWxsIOKAlCByZXN0YXJ0IHRoZSBhZ2VudCBpZiBpdCB3YXMgcnVubmluZy4KClRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsZXI6Ci0gcHV0cyBhIGNvcHkgaW4gYDxpbnN0YWxsIGZvbGRlcj4vbG9jYWwtd2Vi
  >> "!B64TMP!" echo LXNlYXJjaC9gLCBhbmQKLSAqKmF1dG9tYXRpY2FsbHkgaW5zdGFsbHMgKGFkZC9vdmVycmlkZSkq
  >> "!B64TMP!" echo KiBpdCBpbnRvCiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9gLgoKV2hhdCB0
  >> "!B64TMP!" echo aGUgc2tpbGwgZG9lcyBmb3IgdGhlIGFnZW50OgoKLSAqKkZpbmRzIHRoZSBzdGFjayBhdXRvbWF0
  >> "!B64TMP!" echo aWNhbGx5LioqIEl0IHJlYWRzIHRoZSByZWFsIHBvcnRzIGZyb20geW91ciBgLmVudmAKICAoc28g
  >> "!B64TMP!" echo Y3VzdG9tIGluc3RhbGwtdGltZSBwb3J0cyBqdXN0IHdvcmspIGFuZCBsb2NhdGVzIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlciB2aWEKICB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFp
  >> "!B64TMP!" echo bmVycywgdGhlIGluc3RhbGxlci1yZWNvcmRlZAogIGBpbnN0YWxsLWRpci50eHRgIGhpbnQsIG9y
  >> "!B64TMP!" echo IGB+L2xvY2FsLXNlYXJjaGAg4oCUIG5vIGhhcmRjb2RlZCBhbnl0aGluZy4KLSAqKlNlbGYtaGVh
  >> "!B64TMP!" echo bHMgYSBkb3duIHN0YWNrIOKAlCBubyB3YXJtLXVwIHN0ZXAuKiogSWYgdGhlIERvY2tlciBlbmdp
  >> "!B64TMP!" echo bmUgb3IgdGhlCiAgY29udGFpbmVycyBhcmUgZG93biB3aGVuIGEgc2VhcmNoL3NjcmFwZSBydW5z
  >> "!B64TMP!" echo LCB0aGUgc2NyaXB0IGJvb3RzIHRoZSBlbmdpbmUKICAoRG9ja2VyIERlc2t0b3AgLyBgc3lzdGVt
  >> "!B64TMP!" echo Y3RsIHN0YXJ0IGRvY2tlcmApLCBydW5zIHRoZSBzYW1lIGBkb2NrZXIgY29tcG9zZQogIHVwIC1k
  >> "!B64TMP!" echo YCB0aGF0IGBSdW4uYmF0YCAvIGBydW4uc2hgIHVzZSwgd2FpdHMgZm9yIHRoZSBlbmRwb2ludHMs
  >> "!B64TMP!" echo IGFuZCByZXRyaWVzCiAgdGhlIHJlcXVlc3Qg4oCUIHNvIHRoZSBhZ2VudCBjYWxscyB0aGUgc2Vh
  >> "!B64TMP!" echo cmNoL3NjcmFwZSBzY3JpcHRzIGRpcmVjdGx5LCBldmVuCiAgaW4gYW4gb2xkIGNvbnZlcnNhdGlv
  >> "!B64TMP!" echo biB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdvbmUgZG93bgogIChgZW5zdXJlX3N0YWNrLnB5
  >> "!B64TMP!" echo YCByZW1haW5zIGF2YWlsYWJsZSBhcyBhbiBvcHRpb25hbCBwcmUtZmxpZ2h0IGNoZWNrKS4gVGhl
  >> "!B64TMP!" echo CiAgc3RhY2sgaXMgKipuZXZlciBzdG9wcGVkKiogYnkgdGhlIHNjcmlwdHMgKHN0b3BwaW5nIGlz
  >> "!B64TMP!" echo IHlvdXIgam9iLCB2aWEKICBgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KLSAqKlNlYXJjaGVzIHRo
  >> "!B64TMP!" echo ZSB3ZWIuKiogYHdlYl9zZWFyY2gucHkgInF1ZXJ5ImAgcHJpbnRzIHRoZSB0b3AgcmVzdWx0cyBh
  >> "!B64TMP!" echo cwogIGB0aXRsZSAvIHVybCAvIHNuaXBwZXRgLCB3aXRoIGAtLWxpbWl0YCwgYC0tdGltZS1yYW5n
  >> "!B64TMP!" echo ZSBkYXl8d2Vla3xtb250aGAsIGFuZAogIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYCBv
  >> "!B64TMP!" echo cHRpb25zLgotICoqUmVhZHMgcGFnZXMuKiogYHdlYl9zY3JhcGUucHkgPHVybD5gIHJldHVybnMg
  >> "!B64TMP!" echo dGhlIHBhZ2UgYXMgY2xlYW4gTWFya2Rvd24KICAodHJ1bmNhdGVkIGF0IDIwLDAwMCBjaGFyczsg
  >> "!B64TMP!" echo cmFpc2Ugd2l0aCBgLS1tYXgtY2hhcnNgKS4KLSAqKlJlYWRzIFlvdVR1YmUgdHJhbnNjcmlwdHMu
  >> "!B64TMP!" echo KiogYHdlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkgPHZpZGVvX2lkPmAKICBwcmludHMgYSB2aWRl
  >> "!B64TMP!" echo bydzIGNhcHRpb25zIGFzIGBbTU06U1NdIHRleHRgIGxpbmVzLiBJdCB0YWxrcyBkaXJlY3RseSB0
  >> "!B64TMP!" echo bwogIFlvdVR1YmUg4oCUIG5vIERvY2tlciBzdGFjaywgbm8gc2VsZi1oZWFsLCBubyBhY2NvdW50
  >> "!B64TMP!" echo IG5lZWRlZCDigJQgdmlhIHRoZQogIGB5b3V0dWJlLXRyYW5zY3JpcHQtYXBpYCBwaXAgcGFja2Fn
  >> "!B64TMP!" echo ZSAoYHBpcCBpbnN0YWxsIHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgOwogIHRoZSBvbmx5IHRvb2wg
  >> "!B64TMP!" echo aGVyZSB3aXRoIGEgcGlwIGRlcGVuZGVuY3kpLgotICoqRXhwb3NlcyB0aGUgZnVsbCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgTUNQIHN1cmZhY2Ug4oCUIDI0IHRvb2xzLioqIEJlc2lkZXMgc2VhcmNoIGFuZAogIHNjcmFw
  >> "!B64TMP!" echo ZSwgdGhlIHNraWxsIHNoaXBzIHNjcmlwdHMgbWlycm9yaW5nIGV2ZXJ5IEZpcmVjcmF3bCBNQ1Ag
  >> "!B64TMP!" echo dG9vbDoKICBgd2ViX21hcC5weWAgKGVudW1lcmF0ZSBhIHNpdGUncyBVUkxzKSwgYHdlYl9jcmF3
  >> "!B64TMP!" echo bC5weWAgLwogIGB3ZWJfY3Jhd2xfc3RhdHVzLnB5YCAobXVsdGktcGFnZSBjcmF3bHMpLCBgd2Vi
  >> "!B64TMP!" echo X2FnZW50LnB5YCAvCiAgYHdlYl9hZ2VudF9zdGF0dXMucHlgIChhc3luYyByZXNlYXJjaCBhZ2Vu
  >> "!B64TMP!" echo dCksIGB3ZWJfaW50ZXJhY3QucHlgIC8KICBgd2ViX2ludGVyYWN0X3N0b3AucHlgIChsaXZlIGJy
  >> "!B64TMP!" echo b3dzZXIgc2Vzc2lvbnMpLCBgd2ViX3BhcnNlLnB5YCAobG9jYWwKICBQREYvV29yZC9IVE1MLy4u
  >> "!B64TMP!" echo LiBkb2N1bWVudHMpLCBlaWdodCBgd2ViX21vbml0b3JfKi5weWAgc2NyaXB0cyAocmVjdXJyaW5n
  >> "!B64TMP!" echo CiAgY2hhbmdlIHRyYWNraW5nKSwgZml2ZSBgd2ViX3Jlc2VhcmNoXyoucHlgIHNjcmlwdHMgKGJp
  >> "!B64TMP!" echo b21lZGljYWwgKyBhclhpdgogIHBhcGVyIHNlYXJjaCwgY2l0YXRpb24gZ3JhcGgsIGZ1bGwtdGV4
  >> "!B64TMP!" echo dCByZWFkaW5nKSwgYHdlYl9naXRodWJfc2VhcmNoLnB5YAogIChpbmRleGVkIEdpdEh1YiBpc3N1
  >> "!B64TMP!" echo ZXMvUFJzL1JFQURNRXMpLCBhbmQgYHdlYl9kZXZlbG9wZXJfc2VhcmNoLnB5YCAoYW4KICBpbmRl
  >> "!B64TMP!" echo eCBidWlsdCBmb3IgY29kaW5nIGFnZW50cykuIEV2ZXJ5IHNjcmlwdCBzZWxmLWhlYWxzIHRoZSBz
  >> "!B64TMP!" echo dGFjaywgcHJpbnRzCiAgY2xlYW4gb3V0cHV0LCBhbmQgc3VwcG9ydHMgYC0tanNvbmAgZm9yIHRo
  >> "!B64TMP!" echo ZSByYXcgQVBJIHJlc3BvbnNlLgotICoqT3B0aW9uYWwgYWNjb3VudCBmZWF0dXJlcy4qKiBUaGUg
  >> "!B64TMP!" echo cmVzZWFyY2ggYWdlbnQsIGludGVyYWN0LCBwYXJzZSwKICBtb25pdG9ycywgcGFwZXIgcmVzZWFy
  >> "!B64TMP!" echo Y2gsIGFuZCBkZXZlbG9wZXIgc2VhcmNoIGFyZSBGaXJlY3Jhd2wgYWNjb3VudAogIGZlYXR1cmVz
  >> "!B64TMP!" echo IChwYWlkIGNsb3VkIEFQSSkuIFRoZSBpbnN0YWxsZXIncyAiQWRkIGEgRmlyZWNyYXdsIGFjY291
  >> "!B64TMP!" echo bnQ/IgogIHF1ZXN0aW9uIGRlY2lkZXMgaG93IHRoZXkncmUgaGFuZGxlZDogKipOKiogKGRlZmF1
  >> "!B64TMP!" echo bHQpIHNraXBzIHRoZW0g4oCUIHRoZQogIHNraWxsIGlzIGluc3RhbGxlZCB3aXRoIG9ubHkgdGhl
  >> "!B64TMP!" echo IGZyZWUgbG9jYWwgdG9vbHMgKHNlYXJjaCwgc2NyYXBlLCBtYXAsCiAgY3Jhd2wsIGNyYXdsIHN0
  >> "!B64TMP!" echo YXR1cywgWW91VHViZSB0cmFuc2NyaXB0cykgYW5kIGEgY29yZS1vbmx5IGBTS0lMTC5tZGAgdGhh
  >> "!B64TMP!" echo dAogIGRvZXNuJ3QgbWVudGlvbiB0aGUgYWNjb3VudCB0b29sczsgKip5KiogaW5zdGFsbHMgYWxs
  >> "!B64TMP!" echo IDI1IHRvb2xzICgyNiB3aXRoIExMTSBleHRyYWN0aW9uKSBhbmQgd3JpdGVzCiAgYEZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfVVJMYCArIGBGSVJFQ1JBV0xfQVBJX0tFWWAgaW50byB5b3VyIGAuZW52YCBzbyB0aG9z
  >> "!B64TMP!" echo ZQogIHNjcmlwdHMgY2FsbCB0aGUgY2xvdWQgQVBJIGF1dG9tYXRpY2FsbHkgKHRoZSBzYW1lIGVu
  >> "!B64TMP!" echo diB2YXIgbmFtZXMgdGhlCiAgb2ZmaWNpYWwgZmlyZWNyYXdsLW1jcCBzZXJ2ZXIgdXNlcywgaWYg
  >> "!B64TMP!" echo eW91IHByZWZlciBgZXhwb3J0YGluZyB0aGVtKS4KCk1hbnVhbCB1c2FnZSAoZXhhY3RseSB3aGF0
  >> "!B64TMP!" echo IHRoZSBhZ2VudCBydW5zIOKAlCBubyBzZXBhcmF0ZSBzdGFydCBzdGVwIG5lZWRlZCk6CgpgYGBi
  >> "!B64TMP!" echo YXNoCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJf
  >> "!B64TMP!" echo c2VhcmNoLnB5ICJsYXRlc3QgcHl0aG9uIHJlbGVhc2UiCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxz
  >> "!B64TMP!" echo L2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfc2NyYXBlLnB5ICJodHRwczovL2V4YW1wbGUu
  >> "!B64TMP!" echo Y29tIgojIGEgZmV3IG9mIHRoZSBvdGhlciB0b29sczoKcHl0aG9uIH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tYXAucHkgImh0dHBzOi8vZXhhbXBsZS5jb20i
  >> "!B64TMP!" echo CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfY3Jh
  >> "!B64TMP!" echo d2wucHkgImh0dHBzOi8vZXhhbXBsZS5jb20iIC0tbWF4LXBhZ2VzIDEwCnB5dGhvbiB+Ly5hZ2Vu
  >> "!B64TMP!" echo dHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcGFyc2UucHkgInJlcG9ydC5w
  >> "!B64TMP!" echo ZGYiCnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJf
  >> "!B64TMP!" echo eW91dHViZV90cmFuc2NyaXB0LnB5ICJkUXc0dzlXZ1hjUSIKIyBvcHRpb25hbCBwcmUtZmxpZ2h0
  >> "!B64TMP!" echo IGNoZWNrIC8gc3RhdHVzIHJlcG9ydDoKcHl0aG9uIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2Vi
  >> "!B64TMP!" echo LXNlYXJjaC9zY3JpcHRzL2Vuc3VyZV9zdGFjay5weSAtLWNoZWNrCmBgYAoKVGhlIGZ1bGwgYWdl
  >> "!B64TMP!" echo bnQtZmFjaW5nIGluc3RydWN0aW9ucyBsaXZlIGluIHRoZSBza2lsbCdzIGBTS0lMTC5tZGAuIEtl
  >> "!B64TMP!" echo ZXBpbmcgdGhlCnNraWxsIGZyZXNoIGlzIGF1dG9tYXRpYzogYFVwZGF0ZS5iYXRgIC8gYC4vdXBk
  >> "!B64TMP!" echo YXRlLnNoYCByZS1zeW5jcyBpdCwgYW5kCnJlLXJ1bm5pbmcgdGhlIGluc3RhbGxlciBvdmVyd3Jp
  >> "!B64TMP!" echo dGVzIGl0LiBVbmluc3RhbGxpbmcgcmVtb3ZlcyBpdC4KCj4gVGhlIHNraWxsIG9ubHkgbmVlZHMg
  >> "!B64TMP!" echo KipQeXRob24gMy44KyoqIG9uIHRoZSBob3N0IOKAlCBubyBBUEkga2V5cywgbm8gTUNQCj4gc3Vw
  >> "!B64TMP!" echo cG9ydCByZXF1aXJlZCBmcm9tIHRoZSBhZ2VudC4gRXZlcnkgdG9vbCBpcyBzdGRsaWItb25seSBl
  >> "!B64TMP!" echo eGNlcHQKPiBgd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weWAsIHdoaWNoIG5lZWRzIG9uZSBwaXAg
  >> "!B64TMP!" echo cGFja2FnZQo+IChgcGlwIGluc3RhbGwgeW91dHViZS10cmFuc2NyaXB0LWFwaWApLgoKLS0tCgoj
  >> "!B64TMP!" echo IyMgQi4gRGlyZWN0IFNlYXJYTkcgSlNPTiBBUEkKClRoZSBzaW1wbGVzdCBwb3NzaWJsZSBpbnRl
  >> "!B64TMP!" echo Z3JhdGlvbjogaGl0IFNlYXJYTkcncyBKU09OIGVuZHBvaW50IGFuZCBmZWVkIHRoZQpyZXN1bHRz
  >> "!B64TMP!" echo IGludG8gYW55IG1vZGVsJ3MgY29udGV4dC4gTm8gU0RLLCBubyBrZXksIG5vIE1DUC4KCmBgYGJh
  >> "!B64TMP!" echo c2gKIyBTZWFyY2ggdGhlIHdlYiwgcmV0dXJuIEpTT04sIHNob3cgdGhlIHRvcCA1IHJlc3VsdHMK
  >> "!B64TMP!" echo Y3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaD9xPWxhdGVzdCtBSStuZXdzJmZv
  >> "!B64TMP!" echo cm1hdD1qc29uIiBcCiAgfCBqcSAnLnJlc3VsdHNbOjVdIHwgLltdIHwge3RpdGxlLCB1cmwsIGNv
  >> "!B64TMP!" echo bnRlbnR9JwpgYGAKClVzZWZ1bCBxdWVyeSBwYXJhbXM6IGAmcGFnZW5vPTJgLCBgJmNhdGVnb3Jp
  >> "!B64TMP!" echo ZXM9aXQsaW1hZ2VzYCwgYCZ0aW1lX3JhbmdlPWRheWAsCmAmbGFuZ3VhZ2U9ZW5gLCBgJmVuZ2lu
  >> "!B64TMP!" echo ZXM9Z29vZ2xlLGJpbmcsZHVja2R1Y2tnb2AuCgpJbiBQeXRob246CgpgYGBweXRob24KaW1wb3J0
  >> "!B64TMP!" echo IHJlcXVlc3RzCnIgPSByZXF1ZXN0cy5nZXQoImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MC9zZWFyY2gi
  >> "!B64TMP!" echo LCBwYXJhbXM9ewogICAgInEiOiAicnVzdCBhc3luYyBydW50aW1lIHRva2lvIiwKICAgICJmb3Jt
  >> "!B64TMP!" echo YXQiOiAianNvbiIsCiAgICAibGFuZ3VhZ2UiOiAiZW4iLAp9KS5qc29uKCkKZm9yIGhpdCBpbiBy
  >> "!B64TMP!" echo WyJyZXN1bHRzIl1bOjVdOgogICAgcHJpbnQoaGl0WyJ0aXRsZSJdLCAiLT4iLCBoaXRbInVybCJd
  >> "!B64TMP!" echo KQogICAgcHJpbnQoaGl0LmdldCgiY29udGVudCIsICIiKVs6MjAwXSkKYGBgCgo+IFNlYXJYTkcg
  >> "!B64TMP!" echo cmV0dXJucyB0aXRsZXMsIFVSTHMsIGFuZCBzaG9ydCBjb250ZW50IHNuaXBwZXRzIOKAlCBwZXJm
  >> "!B64TMP!" echo ZWN0IGZvciBhCj4gInNlYXJjaCB0aGVuIHN1bW1hcml6ZSIgYWdlbnQgbG9vcC4gRm9yICoqZnVs
  >> "!B64TMP!" echo bCBwYWdlIHRleHQqKiwgdXNlIEZpcmVjcmF3bCAoQykuCgotLS0KCiMjIyBDLiBEaXJlY3QgRmly
  >> "!B64TMP!" echo ZWNyYXdsIFJFU1QgQVBJCgpGaXJlY3Jhd2wgdHVybnMgYW55IFVSTCBpbnRvIGNsZWFuIE1hcmtk
  >> "!B64TMP!" echo b3duL0hUTUwvSlNPTiDigJQgaWRlYWwgZm9yIFJBRy4gQmVjYXVzZQp0aGUgc2VsZi1ob3N0ZWQg
  >> "!B64TMP!" echo aW5zdGFuY2UgcnVucyB3aXRoIGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2VgLCAqKm5vIEFQ
  >> "!B64TMP!" echo SSBrZXkKaXMgcmVxdWlyZWQqKiAoeW91IGNhbiBzZW5kIGFueSBgQXV0aG9yaXphdGlvbjogQmVh
  >> "!B64TMP!" echo cmVyIOKApmAgaGVhZGVyLCBvciBub25lKS4KCiMjIyMgU2NyYXBlIGEgc2luZ2xlIHBhZ2Ug4oaS
  >> "!B64TMP!" echo IE1hcmtkb3duCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEv
  >> "!B64TMP!" echo djEvc2NyYXBlIFwKICAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQg
  >> "!B64TMP!" echo J3sidXJsIjoiaHR0cHM6Ly9leGFtcGxlLmNvbSIsImZvcm1hdHMiOlsibWFya2Rvd24iXX0nIFwK
  >> "!B64TMP!" echo ICB8IGpxICcuZGF0YS5tYXJrZG93bicKYGBgCgojIyMjIFNlYXJjaCB0aGUgd2ViICh1c2VzIHlv
  >> "!B64TMP!" echo dXIgU2VhclhORyBpbnRlcm5hbGx5KSArIHJldHVybiBmdWxsIGNvbnRlbnQKCmBgYGJhc2gKY3Vy
  >> "!B64TMP!" echo bCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zZWFyY2ggXAogIC1IICJDb250
  >> "!B64TMP!" echo ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJxdWVyeSI6IndoYXQgaXMgcnVz
  >> "!B64TMP!" echo dCBwcm9ncmFtbWluZyBsYW5ndWFnZSIsImxpbWl0Ijo1fScgXAogIHwganEgJy5kYXRhWzozXSB8
  >> "!B64TMP!" echo IC5bXSB8IHt0aXRsZSwgdXJsLCBtYXJrZG93bn0nCmBgYAoKIyMjIyBDcmF3bCBhIHdob2xlIHNp
  >> "!B64TMP!" echo dGUgKGFzeW5jKQoKYGBgYmFzaAojIDEpIHN0YXJ0IHRoZSBjcmF3bApKT0I9JChjdXJsIC1zIC1Y
  >> "!B64TMP!" echo IFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2NyYXdsIFwKICAtSCAiQ29udGVudC1UeXBl
  >> "!B64TMP!" echo OiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sidXJsIjoiaHR0cHM6Ly9kb2NzLmV4YW1wbGUu
  >> "!B64TMP!" echo Y29tIiwibGltaXQiOjIwfScgfCBqcSAtciAuaWQpCgojIDIpIHBvbGwgdW50aWwgc3RhdHVzID09
  >> "!B64TMP!" echo ICJjb21wbGV0ZWQiCmN1cmwgLXMgImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9jcmF3bC8kSk9C
  >> "!B64TMP!" echo IiB8IGpxICd7c3RhdHVzLCBjb21wbGV0ZWQsIHRvdGFsfScKYGBgCgojIyMjIE1hcCBhIHNpdGUn
  >> "!B64TMP!" echo cyBVUkwgdHJlZSAoZmFzdCwgbm8gc2NyYXBpbmcpCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBo
  >> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvbWFwIFwKICAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNh
  >> "!B64TMP!" echo dGlvbi9qc29uIiBcCiAgLWQgJ3sidXJsIjoiaHR0cHM6Ly9leGFtcGxlLmNvbSIsImxpbWl0Ijo1
  >> "!B64TMP!" echo MH0nIHwganEgJy5saW5rcycKYGBgCgojIyMjIEV4dHJhY3Qgc3RydWN0dXJlZCBkYXRhIHdpdGgg
  >> "!B64TMP!" echo YW4gTExNIChuZWVkcyBzZWN0aW9uIEQgY29uZmlndXJlZCkKCmBgYGJhc2gKY3VybCAtcyAtWCBQ
  >> "!B64TMP!" echo T1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9leHRyYWN0IFwKICAtSCAiQ29udGVudC1UeXBl
  >> "!B64TMP!" echo OiBhcHBsaWNhdGlvbi9qc29uIiBcCiAgLWQgJ3sidXJscyI6WyJodHRwczovL2V4YW1wbGUuY29t
  >> "!B64TMP!" echo Il0sInByb21wdCI6IkV4dHJhY3QgdGhlIGNvbXBhbnkgbmFtZSBhbmQgYSBjb250YWN0IGVtYWls
  >> "!B64TMP!" echo In0nIFwKICB8IGpxICcuZGF0YScKYGBgCgojIyMjIFVzaW5nIHRoZSBGaXJlY3Jhd2wgU0RLcyAo
  >> "!B64TMP!" echo Tm9kZSAvIFB5dGhvbikKClNlbGYtaG9zdCB3b3JrcyB3aXRoIHRoZSBvZmZpY2lhbCBTREtzIOKA
  >> "!B64TMP!" echo lCBwb2ludCB0aGVtIGF0IHlvdXIgbG9jYWwgVVJMIGFuZCBwYXNzCmFueSBub24tZW1wdHkgc3Ry
  >> "!B64TMP!" echo aW5nIGFzIHRoZSBrZXk6CgoqKk5vZGUuanMqKgpgYGBqcwppbXBvcnQgRmlyZWNyYXdsIGZyb20g
  >> "!B64TMP!" echo IkBtZW5kYWJsZS9maXJlY3Jhd2wtanMiOwoKY29uc3QgZmMgPSBuZXcgRmlyZWNyYXdsKHsKICBh
  >> "!B64TMP!" echo cGlLZXk6ICJmYy1sb2NhbCIsICAgICAgICAgICAgICAvLyBhbnkgbm9uLWVtcHR5IHN0cmluZzsg
  >> "!B64TMP!" echo c2VsZi1ob3N0IGRvZXNuJ3QgdmFsaWRhdGUKICBhcGlVcmw6ICJodHRwOi8vbG9jYWxob3N0Ojk5
  >> "!B64TMP!" echo OTEiLCAvLyA8LS0gcG9pbnQgYXQgeW91ciBsb2NhbCBpbnN0YW5jZQp9KTsKCmNvbnN0IHsgZGF0
  >> "!B64TMP!" echo YSB9ID0gYXdhaXQgZmMuc2NyYXBlVXJsKCJodHRwczovL2V4YW1wbGUuY29tIiwgeyBmb3JtYXRz
  >> "!B64TMP!" echo OiBbIm1hcmtkb3duIl0gfSk7CmNvbnNvbGUubG9nKGRhdGEubWFya2Rvd24pOwpgYGAKCioqUHl0
  >> "!B64TMP!" echo aG9uKioKYGBgcHl0aG9uCmZyb20gZmlyZWNyYXdsIGltcG9ydCBGaXJlY3Jhd2xBcHAKCmZjID0g
  >> "!B64TMP!" echo RmlyZWNyYXdsQXBwKGFwaV9rZXk9ImZjLWxvY2FsIiwgYXBpX3VybD0iaHR0cDovL2xvY2FsaG9z
  >> "!B64TMP!" echo dDo5OTkxIikKcmVzdWx0ID0gZmMuc2NyYXBlX3VybCgiaHR0cHM6Ly9leGFtcGxlLmNvbSIsIHBh
  >> "!B64TMP!" echo cmFtcz17ImZvcm1hdHMiOiBbIm1hcmtkb3duIl19KQpwcmludChyZXN1bHRbIm1hcmtkb3duIl0p
  >> "!B64TMP!" echo CmBgYAoKLS0tCgojIyMgRC4gQ29ubmVjdCBhbiBMTE0gKExNIFN0dWRpbywgZXRjLikKCkJ5IGRl
  >> "!B64TMP!" echo ZmF1bHQsIEZpcmVjcmF3bCdzIGAvdjEvc2NyYXBlYCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwg
  >> "!B64TMP!" echo YW5kIGAvdjEvc2VhcmNoYAp3b3JrICoqd2l0aG91dCBhbnkgTExNKiouIFRvIHVubG9jayAqKmAv
  >> "!B64TMP!" echo djEvZXh0cmFjdGAqKiAoQUkgZXh0cmFjdGlvbikgYW5kIHRoZQpgc3VtbWFyeWAgb3V0cHV0IGZv
  >> "!B64TMP!" echo cm1hdCwgcG9pbnQgRmlyZWNyYXdsIGF0IGFueSAqKk9wZW5BSS1jb21wYXRpYmxlKiogZW5kcG9p
  >> "!B64TMP!" echo bnQuCioqTE0gU3R1ZGlvIGlzIHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0KiogKHByaW9yaXR5IG92
  >> "!B64TMP!" echo ZXIgT2xsYW1hKS4KCiMjIyMgUmVjb21tZW5kZWQ6IExNIFN0dWRpbwoKMS4gSW5zdGFsbCBbTE0g
  >> "!B64TMP!" echo U3R1ZGlvXShodHRwczovL2xtc3R1ZGlvLmFpLyksIGRvd25sb2FkIGEgbW9kZWwgKGUuZy4gYFF3
  >> "!B64TMP!" echo ZW4yLjUtN0ItSW5zdHJ1Y3RgKS4KMi4gR28gdG8gdGhlICoqRGV2ZWxvcGVyKiogdGFiIOKGkiAq
  >> "!B64TMP!" echo KlN0YXJ0IFNlcnZlcioqIG9uIHBvcnQgYDEyMzRgIChkZWZhdWx0KS4KMy4gKipFbmFibGUgIlNl
  >> "!B64TMP!" echo cnZlIG9uIGxvY2FsIG5ldHdvcmsiKiogKHJlcXVpcmVkIOKAlCBGaXJlY3Jhd2wgcnVucyBpbiBh
  >> "!B64TMP!" echo IGNvbnRhaW5lcgogICBhbmQgcmVhY2hlcyB5b3VyIGhvc3QgdmlhIGBob3N0LmRvY2tlci5pbnRl
  >> "!B64TMP!" echo cm5hbGAsIHdoaWNoIGlzIHlvdXIgTEFOIElQLCBub3QKICAgYDEyNy4wLjAuMWApLgo0LiBFaXRo
  >> "!B64TMP!" echo ZXI6CiAgIC0gcmUtcnVuIHRoZSBpbnN0YWxsZXIgKHNldHVwICoqMioqLCBvciAqKjMqKiBhbmQg
  >> "!B64TMP!" echo YW5zd2VyICoqeSoqIHRvICoiQ29ubmVjdAogICAgIExMTSBub3c/IiopIOKAlCBpdCBhdXRvLWNv
  >> "!B64TMP!" echo bnZlcnRzIGBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjFgIOKGkgogICAgIGBodHRwOi8vaG9zdC5k
  >> "!B64TMP!" echo b2NrZXIuaW50ZXJuYWw6MTIzNC92MWAgYW5kIHdyaXRlcyBpdCBpbnRvIGAuZW52YDsgKipvcioq
  >> "!B64TMP!" echo CiAgIC0gZWRpdCBgLmVudmAgZGlyZWN0bHkgYW5kIHNldDoKICAgICBgYGBlbnYKICAgICBPUEVO
  >> "!B64TMP!" echo QUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjEKICAgICBPUEVO
  >> "!B64TMP!" echo QUlfQVBJX0tFWT1sbS1zdHVkaW8KICAgICBNT0RFTF9OQU1FPTx0aGUgbW9kZWwgaWQgbG9hZGVk
  >> "!B64TMP!" echo IGluIExNIFN0dWRpbz4KICAgICBgYGAKNS4gQXBwbHkgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91
  >> "!B64TMP!" echo cGRhdGUuc2hgLgoKIyMjIyBPdGhlciBPcGVuQUktY29tcGF0aWJsZSBzZXJ2ZXJzICh2TExNLCBs
  >> "!B64TMP!" echo bGFtYS5jcHAgYHNlcnZlcmAsIHRleHQtZ2VuZXJhdGlvbi1pbmZlcmVuY2UsIExvY2FsQUksIOKA
  >> "!B64TMP!" echo pikKCmBgYGVudgpPUEVOQUlfQkFTRV9VUkw9aHR0cDovLzxob3N0LW9yLWlwPjo8cG9ydD4vdjEK
  >> "!B64TMP!" echo T1BFTkFJX0FQSV9LRVk9cGxhY2Vob2xkZXIgICAgICAjIGFueSBub24tZW1wdHkgc3RyaW5nIGlm
  >> "!B64TMP!" echo IHlvdXIgc2VydmVyIGlnbm9yZXMgaXQKTU9ERUxfTkFNRT08bW9kZWwgaWQgZnJvbSBHRVQgL3Yx
  >> "!B64TMP!" echo L21vZGVscz4KYGBgCgpGb3IgYSByZW1vdGUgc2VydmVyIG9uIGFub3RoZXIgbWFjaGluZSwgdXNl
  >> "!B64TMP!" echo IGl0cyBJUCBkaXJlY3RseSAoZS5nLgpgaHR0cDovLzE5Mi4xNjguMS41MDo4MDAwL3YxYCkuIEZv
  >> "!B64TMP!" echo ciBhIHNlcnZlciBvbiB0aGUgKipzYW1lIGhvc3QgYXMgRG9ja2VyKiosIHVzZQpgaHR0cDovL2hv
  >> "!B64TMP!" echo c3QuZG9ja2VyLmludGVybmFsOjxwb3J0Pi92MWAuCgojIyMjIEZhbGxiYWNrOiBPbGxhbWEKCklm
  >> "!B64TMP!" echo IHlvdSBwcmVmZXIgT2xsYW1hLCBzZXQgKEZpcmVjcmF3bCByZWFkcyBgT0xMQU1BX0JBU0VfVVJM
  >> "!B64TMP!" echo YCk6CgpgYGBlbnYKT0xMQU1BX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDox
  >> "!B64TMP!" echo MTQzNC9hcGkKTU9ERUxfTkFNRT1xd2VuMi41OjdiCk1PREVMX0VNQkVERElOR19OQU1FPW5vbWlj
  >> "!B64TMP!" echo LWVtYmVkLXRleHQKYGBgCgpSZXN0YXJ0IHdpdGggYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNo
  >> "!B64TMP!" echo YCwgdGhlbiBgL3YxL2V4dHJhY3RgIHJvdXRlcyB0byBPbGxhbWEuCgotLS0KCiMjIyBFLiBWaWEg
  >> "!B64TMP!" echo YW4gTUNQIHNlcnZlcgoKVGhlIG9mZmljaWFsIFsqKkZpcmVjcmF3bCBNQ1Agc2VydmVyKipdKGh0
  >> "!B64TMP!" echo dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1zZXJ2ZXIpCmV4cG9zZXMg
  >> "!B64TMP!" echo YGZpcmVjcmF3bF9zZWFyY2hgLCBgZmlyZWNyYXdsX3NjcmFwZWAsIGBmaXJlY3Jhd2xfY3Jhd2xg
  >> "!B64TMP!" echo LCBgZmlyZWNyYXdsX21hcGAsCmBmaXJlY3Jhd2xfZXh0cmFjdGAsIGFuZCByZXNlYXJjaCB0b29s
  >> "!B64TMP!" echo cyB0byBhbnkgTUNQLWNvbXBhdGlibGUgY2xpZW50LiBQb2ludCBpdCBhdAp5b3VyIGxvY2FsIEZp
  >> "!B64TMP!" echo cmVjcmF3bCB3aXRoIGBGSVJFQ1JBV0xfQVBJX1VSTGAuCgojIyMjIENsYXVkZSBEZXNrdG9wIChg
  >> "!B64TMP!" echo Y2xhdWRlX2Rlc2t0b3BfY29uZmlnLmpzb25gKQoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7
  >> "!B64TMP!" echo CiAgICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6
  >> "!B64TMP!" echo IFsiLXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JB
  >> "!B64TMP!" echo V0xfQVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xf
  >> "!B64TMP!" echo QVBJX0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCiMjIyMgQ3Vyc29y
  >> "!B64TMP!" echo LCBWUyBDb2RlLCBXaW5kc3VyZiwgQ29udGludWUsIENsaW5lLCBldGMuCgpTYW1lIHNoYXBlIOKA
  >> "!B64TMP!" echo lCBhZGQgYW4gYG1jcFNlcnZlcnNgIGVudHJ5IHRvIHRoYXQgdG9vbCdzIGNvbmZpZyBmaWxlCihg
  >> "!B64TMP!" echo fi8uY3Vyc29yL21jcC5qc29uYCwgYC52c2NvZGUvbWNwLmpzb25gLCBgLi9jb2RlaXVtL3dpbmRz
  >> "!B64TMP!" echo dXJmL21vZGVsX2NvbmZpZy5qc29uYCwg4oCmKS4KCmBgYGpzb24KewogICJtY3BTZXJ2ZXJzIjog
  >> "!B64TMP!" echo ewogICAgImZpcmVjcmF3bCI6IHsKICAgICAgImNvbW1hbmQiOiAibnB4IiwKICAgICAgImFyZ3Mi
  >> "!B64TMP!" echo OiBbIi15IiwgImZpcmVjcmF3bC1tY3AiXSwKICAgICAgImVudiI6IHsKICAgICAgICAiRklSRUNS
  >> "!B64TMP!" echo QVdMX0FQSV9VUkwiOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwKICAgICAgICAiRklSRUNSQVdM
  >> "!B64TMP!" echo X0FQSV9LRVkiOiAiZmMtbG9jYWwiCiAgICAgIH0KICAgIH0KICB9Cn0KYGBgCgo+IFRoZSBNQ1Ag
  >> "!B64TMP!" echo c2VydmVyIHJ1bnMgb24geW91ciBob3N0IChub3QgaW4gRG9ja2VyKSwgc28gaXQgcmVhY2hlcyBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgYXQKPiBgaHR0cDovL2xvY2FsaG9zdDo5OTkxYC4gKipObyByZWFsIEFQSSBrZXkg
  >> "!B64TMP!" echo aXMgbmVlZGVkKiog4oCUIGBmYy1sb2NhbGAgaXMgYQo+IHBsYWNlaG9sZGVyOyB0aGUgc2VsZi1o
  >> "!B64TMP!" echo b3N0ZWQgRmlyZWNyYXdsIGRvZXNuJ3QgdmFsaWRhdGUgaXQuIFJlcXVpcmVzIE5vZGUuanMKPiAx
  >> "!B64TMP!" echo OCsgZm9yIGBucHhgLgoKPiAqKk5vdGUgZm9yIGxvY2FsIGxsYW1hLmNwcCBzZXJ2ZXJzOioqIHRo
  >> "!B64TMP!" echo ZSBGaXJlY3Jhd2wgTUNQIHNlcnZlciBzaGlwcyB2ZXJ5Cj4gbGFyZ2UgdG9vbCBkZWZpbml0aW9u
  >> "!B64TMP!" echo cywgd2hpY2ggY2FuIGV4Y2VlZCBzb21lIGxvY2FsIGluZmVyZW5jZSBzZXJ2ZXJzJwo+IGxpbWl0
  >> "!B64TMP!" echo cyAoZS5nLiBsbGFtYS5jcHAncyBgTUFYX1JFUEVUSVRJT05fVEhSRVNIT0xEYCBvZiAyMDAwKS4g
  >> "!B64TMP!" echo SWYgeW91ciBsb2NhbAo+IG1vZGVsIGZhaWxzIHRvIGxvYWQgdGhlIE1DUCB0b29scywgdXNlIHRo
  >> "!B64TMP!" echo ZSBidW5kbGVkICoqbG9jYWwtd2ViLXNlYXJjaCBza2lsbCoqCj4gKFtzZWN0aW9uIEFdKCNhLXRo
  >> "!B64TMP!" echo ZS1idW5kbGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpKSBpbnN0ZWFkIOKA
  >> "!B64TMP!" echo lCBpdCB3b3Jrcwo+IHdpdGggYW55IG1vZGVsIHRoYXQgY2FuIHJ1biBhIHNoZWxsIGNvbW1hbmQs
  >> "!B64TMP!" echo IGFuZCBpcyB0aGUgcmVjb21tZW5kZWQgcGF0aCBmb3IKPiBsb2NhbCBzZXR1cHMgYW55d2F5LgoK
  >> "!B64TMP!" echo IyMjIyBSdW4gdGhlIE1DUCBzZXJ2ZXIgb3ZlciBIVFRQIChvcHRpb25hbCkKCmBgYGJhc2gKSFRU
  >> "!B64TMP!" echo UF9TVFJFQU1BQkxFX1NFUlZFUj10cnVlIFwKRklSRUNSQVdMX0FQSV9VUkw9aHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkxIFwKRklSRUNSQVdMX0FQSV9LRVk9ZmMtbG9jYWwgXApucHggLXkgZmlyZWNyYXds
  >> "!B64TMP!" echo LW1jcAojIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MzAwMC9tY3AKYGBgCgotLS0KCiMjIyBGLiBWaWEg
  >> "!B64TMP!" echo cHJvbXB0aW5nIChhbnkgY2hhdCBVSSkKCk5vIE1DUCwgbm8gU0RLLCBubyBjb2RlIOKAlCBqdXN0
  >> "!B64TMP!" echo IHRlbGwgdGhlIG1vZGVsIHdoZXJlIHRoZSB0b29scyBhcmUuIFBhc3RlIHRoaXMKc3lzdGVtIHBy
  >> "!B64TMP!" echo b21wdCBpbnRvICoqTE0gU3R1ZGlvJ3MgY2hhdCoqLCAqKk9wZW4gV2ViVUkqKiwgKipDaGF0Qm94
  >> "!B64TMP!" echo KiosIG9yIGFueSBVSQp0aGF0IGxldHMgeW91IHNldCBhIHN5c3RlbSBwcm9tcHQgYW5kIGhhcyBh
  >> "!B64TMP!" echo ICJ3ZWIgcmVxdWVzdCIvZnVuY3Rpb24vdG9vbCBmZWF0dXJlOgoKYGBgCllvdSBoYXZlIHR3byBs
  >> "!B64TMP!" echo b2NhbCB3ZWIgdG9vbHMgcnVubmluZyBvbiB0aGlzIG1hY2hpbmUuIFVzZSB0aGVtIHdoZW5ldmVy
  >> "!B64TMP!" echo IHRoZQp1c2VyIGFza3MgYWJvdXQgYW55dGhpbmcgY3VycmVudCBvciBhbnl0aGluZyB5b3UncmUg
  >> "!B64TMP!" echo dW5zdXJlIGFib3V0LgoKMSkgU0VBUkNIIHRoZSB3ZWIgKHJldHVybnMgSlNPTjogdGl0bGUsIHVy
  >> "!B64TMP!" echo bCwgY29udGVudCBmb3IgZWFjaCBoaXQpOgogICBHRVQgaHR0cDovL2xvY2FsaG9zdDo5OTkwL3Nl
  >> "!B64TMP!" echo YXJjaD9xPTxVUkwtRU5DT0RFRC1RVUVSWT4mZm9ybWF0PWpzb24mbGFuZ3VhZ2U9ZW4KICAgUmVh
  >> "!B64TMP!" echo ZCAucmVzdWx0c1tdIChlYWNoIGhhcyAudGl0bGUsIC51cmwsIC5jb250ZW50KS4KCjIpIFJFQUQg
  >> "!B64TMP!" echo YSB3ZWIgcGFnZSBhcyBjbGVhbiBNYXJrZG93biAobm8gQVBJIGtleSBuZWVkZWQpOgogICBQT1NU
  >> "!B64TMP!" echo IGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGUgICBDb250ZW50LVR5cGU6IGFwcGxpY2F0
  >> "!B64TMP!" echo aW9uL2pzb24KICAgYm9keTogeyJ1cmwiOiI8VVJMPiIsImZvcm1hdHMiOlsibWFya2Rvd24iXX0K
  >> "!B64TMP!" echo ICAgUmVhZCAuZGF0YS5tYXJrZG93bi4KCldvcmtmbG93OiBTRUFSQ0ggdG8gZmluZCBVUkxzLCB0
  >> "!B64TMP!" echo aGVuIFNDUkFQRSB0aGUgbW9zdCByZWxldmFudCAx4oCTMyBVUkxzIGZvciBmdWxsCnRleHQsIHRo
  >> "!B64TMP!" echo ZW4gYW5zd2VyIHdpdGggY2l0YXRpb25zLiBJZiBhIHNlYXJjaCBvciBzY3JhcGUgZmFpbHMsIHJl
  >> "!B64TMP!" echo dHJ5IG9uY2Ugd2l0aCBhCmRpZmZlcmVudCBxdWVyeS9VUkwuIE5ldmVyIGludmVudCBVUkxzIOKA
  >> "!B64TMP!" echo lCBvbmx5IHVzZSBvbmVzIHJldHVybmVkIGJ5IFNlYXJYTkcuCmBgYAoKRm9yIFVJcyB0aGF0IG9u
  >> "!B64TMP!" echo bHkgbGV0IHlvdSBwYXN0ZSBVUkxzIChubyB0b29sIGNhbGxpbmcpLCB0aGUgbW9kZWwgY2FuIHN0
  >> "!B64TMP!" echo aWxsCmVtaXQgYGN1cmxgIGNvbW1hbmRzIG9yIGluc3RydWN0IHlvdSB0byBydW4gdGhlbTsgb3Ig
  >> "!B64TMP!" echo eW91IGNhbiB3aXJlIHRoZSBlbmRwb2ludHMKYmVoaW5kIGEgdGlueSBwcm94eS4gVGhlIHBvaW50
  >> "!B64TMP!" echo IGlzOiB0aGUgbW9tZW50IGEgbW9kZWwgY2FuIGlzc3VlIEhUVFAgR0VUL1BPU1QgdG8KYGxvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkwYCBhbmQgYGxvY2FsaG9zdDo5OTkxYCwgaXQgaGFzIGZ1bGwgd2ViIGFjY2Vzcy4K
  >> "!B64TMP!" echo Ci0tLQoKIyMjIEcuIEdVSSBpbnRlZ3JhdGlvbnMKCnwgQXBwIHwgSG93IHwKfC0tLS0tfC0tLS0t
  >> "!B64TMP!" echo fAp8ICoqT3BlbiBXZWJVSSoqIHwgU2V0dGluZ3Mg4oaSIFdlYiBTZWFyY2gg4oaSIFNlYXJYTkcu
  >> "!B64TMP!" echo IFNldCBiYXNlIFVSTCBgaHR0cDovL2xvY2FsaG9zdDo5OTkwYC4gRW5hYmxlICJTZWFyY2ggdGhl
  >> "!B64TMP!" echo IHdlYiIgaW4gY2hhdHMuIChGb3IgcGFnZSByZWFkaW5nLCBhZGQgdGhlIFNlYXJYTkcgcmVzdWx0
  >> "!B64TMP!" echo cyB0byBjb250ZXh0IG9yIHVzZSBhIEZpcmVjcmF3bCB0b29sLikgfAp8ICoqQW55dGhpbmdMTE0q
  >> "!B64TMP!" echo KiB8ICJXZWIgU2VhcmNoIiBwcm92aWRlciA9IFNlYXJYTkcsIGVuZHBvaW50IGBodHRwOi8vbG9j
  >> "!B64TMP!" echo YWxob3N0Ojk5OTBgLiB8CnwgKipEaWZ5IC8gRmxvd2lzZSAvIExhbmdmbG93KiogfCBBZGQgYSBT
  >> "!B64TMP!" echo ZWFyWE5HIHRvb2wgbm9kZSBhbmQgYSBGaXJlY3Jhd2wgSFRUUC1yZXF1ZXN0IHRvb2wgbm9kZSAo
  >> "!B64TMP!" echo VVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvc2NyYXBlYCkuIHwKfCAqKm44biAvIFphcGll
  >> "!B64TMP!" echo ci1pc2gqKiB8IEhUVFAgUmVxdWVzdCBub2RlcyB0byB0aGUgdHdvIGVuZHBvaW50cy4gfAp8ICoq
  >> "!B64TMP!" echo TGFuZ0NoYWluIC8gTGxhbWFJbmRleCoqIHwgVXNlIGEgYFJlcXVlc3RzVG9vbGtpdGAgLyBjdXN0
  >> "!B64TMP!" echo b20gdG9vbCB0aGF0IEdFVHMvUE9TVHMgdGhlIHR3byBVUkxzLiB8CgotLS0KCiMjIENvbmZpZ3Vy
  >> "!B64TMP!" echo YXRpb24gcmVmZXJlbmNlCgpBbGwgcnVudGltZSBjb25maWcgbGl2ZXMgaW4gKipgLmVudmAqKiBp
  >> "!B64TMP!" echo biB5b3VyIGluc3RhbGwgZm9sZGVyIChnZW5lcmF0ZWQgYnkgdGhlCmluc3RhbGxlcjsgZG9jdW1l
  >> "!B64TMP!" echo bnRlZCBpbiBgLmVudi5leGFtcGxlYCkuIEVkaXQgaXQsIHRoZW4gcnVuIGBVcGRhdGUuYmF0YCAv
  >> "!B64TMP!" echo CmAuL3VwZGF0ZS5zaGAgdG8gYXBwbHkuCgp8IFZhcmlhYmxlIHwgRGVmYXVsdCB8IE1lYW5pbmcg
  >> "!B64TMP!" echo fAp8LS0tLS0tLS0tLXwtLS0tLS0tLS18LS0tLS0tLS0tfAp8IGBTRUFSWE5HX1BPUlRgIHwgYDk5
  >> "!B64TMP!" echo OTBgIHwgSG9zdCBwb3J0IGZvciB0aGUgU2VhclhORyBVSSArIEpTT04gQVBJLiB8CnwgYEZJUkVD
  >> "!B64TMP!" echo UkFXTF9QT1JUYCB8IGA5OTkxYCB8IEhvc3QgcG9ydCBmb3IgdGhlIEZpcmVjcmF3bCBBUEkuIHwK
  >> "!B64TMP!" echo fCBgU0VBUlhOR19TRUNSRVRgIHwgKihyYW5kb20pKiB8IFNlYXJYTkcgc2Vzc2lvbiBzZWNyZXQg
  >> "!B64TMP!" echo 4oCUIGFsc28gaW5qZWN0ZWQgaW50byBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYC4gfAp8
  >> "!B64TMP!" echo IGBCVUxMX0FVVEhfS0VZYCB8ICoocmFuZG9tKSogfCBQcm90ZWN0cyB0aGUgKGRpc2FibGVkLWJ5
  >> "!B64TMP!" echo LWRlZmF1bHQpIEZpcmVjcmF3bCBxdWV1ZSBhZG1pbiBVSS4gfAp8IGBQT1NUR1JFU19EQmAgLyBg
  >> "!B64TMP!" echo UE9TVEdSRVNfVVNFUmAgLyBgUE9TVEdSRVNfUEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyBgZmly
  >> "!B64TMP!" echo ZWNyYXdsYCAvICoocmFuZG9tKSogfCBGaXJlY3Jhd2wgam9iLXN0YXRlIERCIGNyZWRlbnRpYWxz
  >> "!B64TMP!" echo LiB8CnwgYFJBQkJJVE1RX1VTRVJgIC8gYFJBQkJJVE1RX1BBU1NXT1JEYCB8IGBmaXJlY3Jhd2xg
  >> "!B64TMP!" echo IC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBtZXNzYWdlLWJyb2tlciBjcmVkZW50aWFscy4gfAp8
  >> "!B64TMP!" echo IGBDT01QT1NFX1BST0ZJTEVTYCB8IGBwbGF5d3JpZ2h0YCB8IFdoaWNoIGJyb3dzZXIgZW5naW5l
  >> "!B64TMP!" echo IGFjdHVhbGx5IHN0YXJ0czogYHBsYXl3cmlnaHRgIG9yIGBicm93c2VybGVzc2AgKGluc3RhbGxl
  >> "!B64TMP!" echo ciBTdGVwIDQpLiB8CnwgYFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTGAgfCBgaHR0cDovL3Bs
  >> "!B64TMP!" echo YXl3cmlnaHQtc2VydmljZTozMDAwL3NjcmFwZWAgfCBGaXJlY3Jhd2wncyBVUkwgZm9yIGl0cyBi
  >> "!B64TMP!" echo cm93c2VyIGVuZ2luZSDigJQgbXVzdCBtYXRjaCBgQ09NUE9TRV9QUk9GSUxFU2AgKGBodHRwOi8v
  >> "!B64TMP!" echo YnJvd3Nlcmxlc3M6MzAwMC9zY3JhcGVgIHdoZW4gdGhhdCdzIGBicm93c2VybGVzc2ApLiB8Cnwg
  >> "!B64TMP!" echo YEJST1dTRVJMRVNTX1RPS0VOYCB8ICoocmFuZG9tKSogfCBBdXRoIHRva2VuIGZvciB0aGUgQnJv
  >> "!B64TMP!" echo d3Nlcmxlc3Mgc2VydmljZS4gT25seSB1c2VkIHdoZW4gYENPTVBPU0VfUFJPRklMRVM9YnJvd3Nl
  >> "!B64TMP!" echo cmxlc3NgOyBoYXJtbGVzcyBpZiB1bnVzZWQuIHwKfCBgTE9HR0lOR19MRVZFTGAgfCBgaW5mb2Ag
  >> "!B64TMP!" echo fCBGaXJlY3Jhd2wgbG9nIHZlcmJvc2l0eSAoYGRlYnVnYC9gaW5mb2AvYHdhcm5gL2BlcnJvcmAp
  >> "!B64TMP!" echo LiB8CnwgYE9QRU5BSV9CQVNFX1VSTGAgfCAqKHVuc2V0KSogfCBPcGVuQUktY29tcGF0aWJsZSBM
  >> "!B64TMP!" echo TE0gZW5kcG9pbnQgZm9yIGAvdjEvZXh0cmFjdGAgKyBzdW1tYXJpZXMuIEZvciBhIHNhbWUtaG9z
  >> "!B64TMP!" echo dCBzZXJ2ZXIgdXNlIGBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6PHBvcnQ+L3YxYC4gfAp8
  >> "!B64TMP!" echo IGBPUEVOQUlfQVBJX0tFWWAgfCAqKHVuc2V0KSogfCBBbnkgbm9uLWVtcHR5IHN0cmluZyAobW9z
  >> "!B64TMP!" echo dCBsb2NhbCBzZXJ2ZXJzIGlnbm9yZSBpdCkuIHwKfCBgTU9ERUxfTkFNRWAgfCAqKHVuc2V0KSog
  >> "!B64TMP!" echo fCBUaGUgbW9kZWwgaWQgdG8gdXNlLiB8CnwgYE9MTEFNQV9CQVNFX1VSTGAgfCAqKHVuc2V0KSog
  >> "!B64TMP!" echo fCBVc2UgaW5zdGVhZCBvZiBgT1BFTkFJXypgIGZvciBhbiBPbGxhbWEgYmFja2VuZC4gfAoKU2Vh
  >> "!B64TMP!" echo clhORyBiZWhhdmlvdXIgKGVuZ2luZXMsIGZvcm1hdHMsIGxpbWl0ZXIpIGlzIHR1bmVkIGluCmBj
  >> "!B64TMP!" echo b25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgLiBUaGUgZGVmYXVsdHMgZW5hYmxlIEpTT04gb3V0
  >> "!B64TMP!" echo cHV0IGFuZCBkaXNhYmxlIHRoZQpib3QgbGltaXRlci4gVG8gYWRkL3JlbW92ZSBlbmdpbmVzLCBl
  >> "!B64TMP!" echo ZGl0IHRoYXQgZmlsZSBhbmQgcnVuIGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgKHRoZSBj
  >> "!B64TMP!" echo b250YWluZXIgcmVhZHMgaXQgYXQgc3RhcnQpLgoKVGhlIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwg
  >> "!B64TMP!" echo bmVlZHMgbm8gY29uZmlndXJhdGlvbjogaXQgcmVhZHMgdGhlIHNhbWUgYC5lbnZgIGF0CnJ1bnRp
  >> "!B64TMP!" echo bWUuIFRoZSBvbmx5IGV4dHJhIGZpbGUgaXQgdXNlcyBpcyBgaW5zdGFsbC1kaXIudHh0YCAod3Jp
  >> "!B64TMP!" echo dHRlbiBieSB0aGUKaW5zdGFsbGVyIG5leHQgdG8gdGhlIHNraWxsJ3MgYFNLSUxMLm1kYCksIHdo
  >> "!B64TMP!" echo aWNoIHJlY29yZHMgdGhlIGluc3RhbGwgZm9sZGVyIHNvCnRoZSBza2lsbCBjYW4gc3RhcnQgdGhl
  >> "!B64TMP!" echo IHN0YWNrIGV2ZW4gZnJvbSBhIG5vbi1kZWZhdWx0IGxvY2F0aW9uLiBUbyBwb2ludCB0aGUKc2tp
  >> "!B64TMP!" echo bGwgYXQgYSBkaWZmZXJlbnQgZm9sZGVyLCBzZXQgdGhlIGBMT0NBTF9TRUFSQ0hfRElSYCBlbnZp
  >> "!B64TMP!" echo cm9ubWVudCB2YXJpYWJsZS4KCi0tLQoKIyMgVHJvdWJsZXNob290aW5nCgoqKlRoZSBpbnN0YWxs
  >> "!B64TMP!" echo ZXIgc2F5cyB0aGUgRG9ja2VyIGVuZ2luZSAiZGlkIG5vdCBjb21lIG9ubGluZSIuKioKVGhlIGlu
  >> "!B64TMP!" echo c3RhbGxlciBsYXVuY2hlcyBEb2NrZXIgRGVza3RvcCAvIHRoZSBkb2NrZXIgc2VydmljZSB3aGVu
  >> "!B64TMP!" echo IHRoZSBlbmdpbmUgaXMKZG93biwgdGhlbiB3YWl0cyB1cCB0byA1IG1pbnV0ZXMgKG92ZXJyaWRl
  >> "!B64TMP!" echo IHdpdGggdGhlIGBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVRgCmVudiB2YXIsIGluIHNlY29u
  >> "!B64TMP!" echo ZHMpLiBJZiBpdCB0aW1lcyBvdXQsIHN0YXJ0IERvY2tlciB5b3Vyc2VsZiwgd2FpdCB1bnRpbCBp
  >> "!B64TMP!" echo dApyZXBvcnRzICJydW5uaW5nIiwgYW5kIHJlLXJ1biB0aGUgaW5zdGFsbGVyIOKAlCBhbnl0aGlu
  >> "!B64TMP!" echo ZyBpdCBhbHJlYWR5IHdyb3RlIGlzCnNhZmVseSBvdmVyd3JpdHRlbi4KCioqYGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlIHVwYCBmYWlscyB3aXRoIGEgcG9ydCBhbHJlYWR5IGluIHVzZS4qKgpSZS1ydW4gdGhlIGlu
  >> "!B64TMP!" echo c3RhbGxlciBhbmQgcGljayBkaWZmZXJlbnQgcG9ydHMsIG9yIHN0b3Agd2hhdGV2ZXIncyB1c2lu
  >> "!B64TMP!" echo ZyA5OTkwLzk5OTEuCgoqKlNlYXJYTkcgcmV0dXJucyBgNDI5IFRvbyBNYW55IFJlcXVlc3RzYCBv
  >> "!B64TMP!" echo ciBibG9ja3MgcmVxdWVzdHMuKioKWW91J3JlIGhpdHRpbmcgYW4gZXh0ZXJuYWwgZW5naW5lJ3Mg
  >> "!B64TMP!" echo cmF0ZSBsaW1pdCAobm90IFNlYXJYTkcgaXRzZWxmKS4gV2FpdCBhCm1pbnV0ZSwgb3IgaW4gYGNv
  >> "!B64TMP!" echo bmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgcmVtb3ZlIHRoZSBvZmZlbmRpbmcgZW5naW5lIHVu
  >> "!B64TMP!" echo ZGVyCmBlbmdpbmVzOmAuIFRoZSBpbnRlcm5hbCBsaW1pdGVyIGlzIGFscmVhZHkgZGlzYWJsZWQg
  >> "!B64TMP!" echo Zm9yIGxvY2FsIHVzZS4KCioqYC92MS9leHRyYWN0YCByZXR1cm5zIGFuIGVycm9yIC8gIm1vZGVs
  >> "!B64TMP!" echo IG5vdCBjb25maWd1cmVkIi4qKgpZb3UgaGF2ZW4ndCBjb25uZWN0ZWQgYW4gTExNIOKAlCBzZWUg
  >> "!B64TMP!" echo W3NlY3Rpb24gRF0oI2QtY29ubmVjdC1hbi1sbG0tbG0tc3R1ZGlvLWV0YykuCmAvdjEvc2NyYXBl
  >> "!B64TMP!" echo YCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwgYC92MS9zZWFyY2hgIHdvcmsgd2l0aG91dCBvbmUu
  >> "!B64TMP!" echo CgoqKkZpcmVjcmF3bCBjYW4ndCByZWFjaCB5b3VyIExNIFN0dWRpby4qKgpGcm9tIGluc2lkZSB0
  >> "!B64TMP!" echo aGUgRmlyZWNyYXdsIGNvbnRhaW5lciB5b3VyIGhvc3QgaXMgYGhvc3QuZG9ja2VyLmludGVybmFs
  >> "!B64TMP!" echo YCwgKipub3QqKgpgbG9jYWxob3N0YC4gTWFrZSBzdXJlIChhKSBMTSBTdHVkaW8gaGFzICoqIlNl
  >> "!B64TMP!" echo cnZlIG9uIGxvY2FsIG5ldHdvcmsiKiogZW5hYmxlZCwKYW5kIChiKSBgLmVudmAgaGFzIGBPUEVO
  >> "!B64TMP!" echo QUlfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjFgCih0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIGRvZXMgdGhpcyBjb252ZXJzaW9uIGF1dG9tYXRpY2FsbHkpLiBUZXN0IGZyb20gdGhl
  >> "!B64TMP!" echo IGhvc3QgZmlyc3Q6CmBjdXJsIGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MS9tb2RlbHNgLgoKKipU
  >> "!B64TMP!" echo aGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlci4q
  >> "!B64TMP!" echo KgpUaGUgc2tpbGwgbG9va3MgZm9yIHRoZSBjb21wb3NlIGZvbGRlciB2aWEgKDEpIHRoZSBgTE9D
  >> "!B64TMP!" echo QUxfU0VBUkNIX0RJUmAgZW52IHZhciwKKDIpIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVu
  >> "!B64TMP!" echo bmluZyBjb250YWluZXJzLCAoMykgdGhlIGBpbnN0YWxsLWRpci50eHRgCmhpbnQgdGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciB3cm90ZSBuZXh0IHRvIHRoZSBza2lsbCwgYW5kICg0KSBgfi9sb2NhbC1zZWFyY2hgLiBJ
  >> "!B64TMP!" echo ZiB5b3UKbW92ZWQgdGhlIGluc3RhbGwgZm9sZGVyLCByZS1ydW4gdGhlIGluc3RhbGxlciBvciBg
  >> "!B64TMP!" echo VXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgCnRvIHJlZnJlc2ggdGhlIGhpbnQg4oCUIG9yIGV4
  >> "!B64TMP!" echo cG9ydCBgTE9DQUxfU0VBUkNIX0RJUj0vcGF0aC90by9sb2NhbC1zZWFyY2hgLgoKKipUaGUgYWdl
  >> "!B64TMP!" echo bnQgZG9lc24ndCBzZWUgdGhlIHNraWxsIGFmdGVyIGluc3RhbGwuKioKU2tpbGxzIGFyZSB1c3Vh
  >> "!B64TMP!" echo bGx5IHNjYW5uZWQgYXQgYWdlbnQgc3RhcnR1cCDigJQgcmVzdGFydCB0aGUgYWdlbnQuIEFsc28g
  >> "!B64TMP!" echo Y2hlY2sgdGhlCnNraWxsIGFjdHVhbGx5IGxhbmRlZCBhdCBgfi8uYWdlbnRzL3NraWxscy9sb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoL1NLSUxMLm1kYCAodGhlIGluc3RhbGxlcgpwcmludHMgd2hlcmUgaXQgcHV0
  >> "!B64TMP!" echo IGl0KS4KCioqRmlyc3QgYGRvY2tlciBjb21wb3NlIHB1bGxgIGlzIHNsb3cgLyBoaXRzIGEgR0hD
  >> "!B64TMP!" echo UiA0MDEuKioKVGhlIEZpcmVjcmF3bCBpbWFnZXMgYXJlIHB1YmxpYywgYnV0IHJhdGUtbGltaXRl
  >> "!B64TMP!" echo ZC4gQXV0aGVudGljYXRlOgpgZWNobyAiJEdJVEhVQl9QQVQiIHwgZG9ja2VyIGxvZ2luIGdoY3Iu
  >> "!B64TMP!" echo aW8gLXUgWU9VUl9HSF9VU0VSIC0tcGFzc3dvcmQtc3RkaW5gCih0b2tlbiBuZWVkcyBgcmVhZDpw
  >> "!B64TMP!" echo YWNrYWdlc2ApLCB0aGVuIHJlLXJ1biBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLgoKKipD
  >> "!B64TMP!" echo b250YWluZXJzIGtlZXAgcmVzdGFydGluZy4qKgpDaGVjayBsb2dzOiBgZG9ja2VyIGNvbXBvc2Ug
  >> "!B64TMP!" echo bG9ncyBmaXJlY3Jhd2xgIChvciBgc2VhcnhuZ2ApLiBUaGUgbW9zdCBjb21tb24KY2F1c2UgaXMg
  >> "!B64TMP!" echo YSBtaXNzaW5nL2VtcHR5IGAuZW52YCB2YWx1ZSAoZS5nLiBgUkFCQklUTVFfUEFTU1dPUkRgKS4g
  >> "!B64TMP!" echo UmUtcnVuIHRoZQppbnN0YWxsZXIgdG8gcmVnZW5lcmF0ZSBhIGNsZWFuIGAuZW52YC4KCioqU2Vh
  >> "!B64TMP!" echo clhORyBVSSBsb2FkcyBidXQgYC9zZWFyY2g/Zm9ybWF0PWpzb25gIHJldHVybnMgSFRNTC4qKgpU
  >> "!B64TMP!" echo aGUgSlNPTiBmb3JtYXQgaXNuJ3QgZW5hYmxlZC4gWW91ciBgY29uZmlnL3NlYXJ4bmcvc2V0dGlu
  >> "!B64TMP!" echo Z3MueW1sYCBtdXN0IGNvbnRhaW4KYHNlYXJjaDogZm9ybWF0czogW2h0bWwsIGpzb25dYCAodGhl
  >> "!B64TMP!" echo IHNoaXBwZWQgY29uZmlnIGRvZXMpLiBSZXN0YXJ0IHdpdGgKYFVwZGF0ZS5iYXRgIC8gYC4vdXBk
  >> "!B64TMP!" echo YXRlLnNoYCBhZnRlciBlZGl0aW5nLgoKKipSZXNldCBldmVyeXRoaW5nIHRvIGRlZmF1bHRzLioq
  >> "!B64TMP!" echo ClJ1biBgVW5pbnN0YWxsLmJhdGAgLyBgLi91bmluc3RhbGwuc2hgIChkZWxldGVzIHZvbHVtZXMg
  >> "!B64TMP!" echo KyBkYXRhICsgdGhlIHNraWxsKSwKdGhlbiBydW4gdGhlIGluc3RhbGxlciBhZ2Fpbi4KCi0tLQoK
  >> "!B64TMP!" echo IyMgVXBkYXRpbmcgJiB1bmluc3RhbGxpbmcKCi0gKipVcGRhdGUgaW1hZ2VzICYgYXBwbHkgY29u
  >> "!B64TMP!" echo ZmlnIGNoYW5nZXMgJiByZS1zeW5jIHRoZSBza2lsbDoqKiBgVXBkYXRlLmJhdGAgLwogIGAuL3Vw
  >> "!B64TMP!" echo ZGF0ZS5zaGAgKGBkb2NrZXIgY29tcG9zZSBwdWxsICYmIGRvY2tlciBjb21wb3NlIHVwIC1kYCwg
  >> "!B64TMP!" echo dGhlbiByZS1jb3B5CiAgYGxvY2FsLXdlYi1zZWFyY2hgIGludG8gYH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo YCkuIERhdGEgaXMgcHJlc2VydmVkLgotICoqVXBkYXRlIHRoZSBTZWFyWE5HIGBzZXR0aW5ncy55
  >> "!B64TMP!" echo bWxgIC8gYGRvY2tlci1jb21wb3NlLnltbGAgdGVtcGxhdGU6KiogcmUtcnVuCiAgdGhlIGluc3Rh
  >> "!B64TMP!" echo bGxlciDigJQgaXQgY29waWVzIHRoZSBsYXRlc3QgdGVtcGxhdGUgb3ZlciwgcmVmcmVzaGVzIHRo
  >> "!B64TMP!" echo ZQogIGBsb2NhbC13ZWItc2VhcmNoYCBza2lsbCwgYW5kIGJhY2tzIHVwIHlvdXIgZXhpc3Rpbmcg
  >> "!B64TMP!" echo YC5lbnZgIHRvIGAuZW52LmJhay48dGltZXN0YW1wPmAuCi0gKipVbmluc3RhbGw6KiogYFVuaW5z
  >> "!B64TMP!" echo dGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYC4gUmVtb3ZlcyBjb250YWluZXJzICsgRG9ja2Vy
  >> "!B64TMP!" echo CiAgdm9sdW1lcyAoYWxsIEZpcmVjcmF3bC9TZWFyWE5HIGRhdGEpICsgdGhlIGBsb2NhbC13ZWIt
  >> "!B64TMP!" echo c2VhcmNoYCBza2lsbCBmcm9tCiAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaGAs
  >> "!B64TMP!" echo IHRoZW4gYXNrcyB3aGV0aGVyIHRvIGRlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIuCiAgUHVsbGVk
  >> "!B64TMP!" echo IGltYWdlcyByZW1haW47IHJlY2xhaW0gd2l0aCBgZG9ja2VyIGltYWdlIHBydW5lIC1hYC4KCi0t
  >> "!B64TMP!" echo LQoKIyMgRGV2ZWxvcG1lbnQ6IGZ1bGwgZGV2IHJpZyAocmVidWlsZGluZyBldmVyeXRoaW5nKQoK
  >> "!B64TMP!" echo VGhlIGBmdWxsLWRldi1yaWcvYCBmb2xkZXIgaG9sZHMgdHdvIHNlbGYtY29udGFpbmVkIHBhY2tl
  >> "!B64TMP!" echo cnMg4oCUCmBsb2NhbC1zZWFyY2gtcmlnLmJhdGAgKFdpbmRvd3MpIGFuZCBgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LXJpZy5zaGAgKExpbnV4L21hY09TKSDigJQKdGhhdCB1bnBhY2sgdGhlIGNvbXBsZXRlIGJ1aWxk
  >> "!B64TMP!" echo L3Rlc3QgZW52aXJvbm1lbnQgaW4gb25lIHNob3Q6IHRoZQpsb2NhbC1zZWFyY2ggc291cmNlIHRy
  >> "!B64TMP!" echo ZWUsIGBnZW5faW5zdGFsbGVycy5weWAgLyBgZ2VuX3JpZy5weWAsIGV2ZXJ5IHRlc3QKc2NyaXB0
  >> "!B64TMP!" echo LCBhbmQgYEJVSUxELm1kYC4KCjEuICoqVW5wYWNrIHRoZSByaWcqKiBpbnRvIGEgZnJlc2ggZm9s
  >> "!B64TMP!" echo ZGVyIChkZWZhdWx0OgogICBgPHJpZyBmb2xkZXI+XGxvY2FsLXNlYXJjaC1kZXZgKToKCiAgIGBg
  >> "!B64TMP!" echo YGJhdAogICBmdWxsLWRldi1yaWdcbG9jYWwtc2VhcmNoLXJpZy5iYXQKICAgYGBgCgogICBgYGBz
  >> "!B64TMP!" echo aAogICAuL2Z1bGwtZGV2LXJpZy9sb2NhbC1zZWFyY2gtcmlnLnNoCiAgIGBgYAoKICAgQW5zd2Vy
  >> "!B64TMP!" echo czogdGFyZ2V0IGZvbGRlciAoRW50ZXIgPSBkZWZhdWx0KSwgYHlgID0gYnVpbGQgcmlnaHQgYXdh
  >> "!B64TMP!" echo eSwKICAgYHlgID0gY29uZmlybS4gVW5wYWNraW5nIHJ1bnMgYGdlbl9pbnN0YWxsZXJzLnB5YCBp
  >> "!B64TMP!" echo biB0aGUgdGFyZ2V0IGZvbGRlcgogICB3aGVuIHlvdSBhbnN3ZXJlZCBgeWAuCgoyLiAqKlJlZ2Vu
  >> "!B64TMP!" echo ZXJhdGUgZXZlcnl0aGluZyoqIGluc2lkZSB0aGUgdW5wYWNrZWQgZm9sZGVyOgoKICAgYGBgc2gK
  >> "!B64TMP!" echo ICAgcHl0aG9uIGdlbl9pbnN0YWxsZXJzLnB5ICAgIyByZWJ1aWxkIGluc3RhbGwtbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoLmJhdC8uc2gKICAgcHl0aG9uIGdlbl9yaWcucHkgICAgICAgICAgIyByZWJ1aWxkIHRoZSB0
  >> "!B64TMP!" echo d28gcGFja2VycyBieXRlLWZvci1ieXRlCiAgIGBgYAoKICAgRnJlc2ggaW5zdGFsbGVycyBhcmUg
  >> "!B64TMP!" echo d3JpdHRlbiB0byBgPHRhcmdldD5cbG9jYWwtc2VhcmNoXGAsIGFuZCBmcmVzaAogICBwYWNrZXJz
  >> "!B64TMP!" echo IHJlcGxhY2UgdGhlIHVucGFja2VkIGBsb2NhbC1zZWFyY2gtcmlnLipgIGNvcGllcy4gYEJVSUxE
  >> "!B64TMP!" echo Lm1kYAogICAoaW5zaWRlIHRoZSB1bnBhY2tlZCBmb2xkZXIpIGRvY3VtZW50cyB0aGUgdGVzdCBz
  >> "!B64TMP!" echo Y3JpcHRzCiAgIChgdGVzdF9iNjQucHlgLCBgdGVzdF9yaWcucHlgLCBgZTJlX3Rlc3Quc2hgLCAu
  >> "!B64TMP!" echo Li4pLgoKTm90ZTogdGhlIHBhY2tlcnMgZW1iZWQgdGhlIHNvdXJjZSB0cmVlICoqYXMgb2Ygd2hl
  >> "!B64TMP!" echo biB0aGV5IHdlcmUKZ2VuZXJhdGVkKiouIE1ha2Ugc291cmNlIGVkaXRzIGZpcnN0LCBvciBjb3B5
  >> "!B64TMP!" echo IHRoZSBlZGl0ZWQgZmlsZXMgaW50byB0aGUKdW5wYWNrZWQgYGxvY2FsLXNlYXJjaC9gIGZvbGRl
  >> "!B64TMP!" echo ciwgYmVmb3JlIHJ1bm5pbmcgdGhlIGdlbmVyYXRvcnMuCgojIyBTZWN1cml0eSBub3RlcwoKLSBU
  >> "!B64TMP!" echo aGlzIHN0YWNrIGlzIGRlc2lnbmVkIGZvciAqKmxvY2FsIC8gdHJ1c3RlZC1uZXR3b3JrIHVzZSoq
  >> "!B64TMP!" echo LiBGaXJlY3Jhd2wncyBBUEkgaXMKICAqKnVuYXV0aGVudGljYXRlZCoqIChgVVNFX0RCX0FVVEhF
  >> "!B64TMP!" echo TlRJQ0FUSU9OPWZhbHNlYCkgc28geW91ciBtb2RlbHMgY2FuIGNhbGwgaXQKICB3aXRob3V0IGEg
  >> "!B64TMP!" echo a2V5LiAqKkRvIG5vdCBleHBvc2UgcG9ydHMgOTk5MC85OTkxIHRvIHRoZSBwdWJsaWMgaW50ZXJu
  >> "!B64TMP!" echo ZXQuKioKLSBBbGwgY3JlZGVudGlhbHMgKGBTRUFSWE5HX1NFQ1JFVGAsIGBCVUxMX0FVVEhfS0VZ
  >> "!B64TMP!" echo YCwgYFBPU1RHUkVTX1BBU1NXT1JEYCwKICBgUkFCQklUTVFfUEFTU1dPUkRgLCBgQlJPV1NFUkxF
  >> "!B64TMP!" echo U1NfVE9LRU5gKSBhcmUgZ2VuZXJhdGVkIGFzIDI1Ni1iaXQgcmFuZG9tIGhleAogIGF0IGluc3Rh
  >> "!B64TMP!" echo bGwgdGltZSBhbmQgc3RvcmVkIG9ubHkgaW4geW91ciBsb2NhbCBgLmVudmAuCi0gU2VhclhORydz
  >> "!B64TMP!" echo IGJvdCBsaW1pdGVyIGlzIGRpc2FibGVkIGFuZCBKU09OIG91dHB1dCBpcyBlbmFibGVkIHNvIG1v
  >> "!B64TMP!" echo ZGVscyBjYW4KICBxdWVyeSBpdCDigJQgdGhpcyBpcyBpbnRlbnRpb25hbCBmb3IgbG9jYWwgdXNl
  >> "!B64TMP!" echo LiBPbiBhIHB1YmxpYyBpbnN0YW5jZSB5b3UnZCB3YW50CiAgdGhlIGxpbWl0ZXIgYmFjayBvbi4K
  >> "!B64TMP!" echo LSBZb3VyIHNlYXJjaCBxdWVyaWVzIGFuZCBzY3JhcGVkIHBhZ2UgY29udGVudHMgbmV2ZXIgbGVh
  >> "!B64TMP!" echo dmUgeW91ciBtYWNoaW5lCiAgKGV4Y2VwdCB0aGUgb3V0Ym91bmQgZmV0Y2hlcyBTZWFyWE5HL0Zp
  >> "!B64TMP!" echo cmVjcmF3bCBtYWtlIHRvIHRoZSBwdWJsaWMgd2ViLCB3aGljaAogIGlzIHRoZSB3aG9sZSBwb2lu
  >> "!B64TMP!" echo dCkuCgotLS0KCiMjIENyZWRpdHMgJiBsaWNlbnNlcwoKVGhpcyBwcm9qZWN0IGlzIGxpY2Vuc2Vk
  >> "!B64TMP!" echo IHVuZGVyIHRoZSAqKk1QTC0yLjAqKiBsaWNlbnNlIOKAlCBzZWUgW0xJQ0VOU0VdKExJQ0VOU0Up
  >> "!B64TMP!" echo CihpdCBjb3ZlcnMgdGhlIGJ1bmRsZWQgW2xvY2FsLXdlYi1zZWFyY2hdKGxvY2FsLXdlYi1zZWFy
  >> "!B64TMP!" echo Y2gpIHNraWxsIHRvbykuCgotIFsqKlNlYXJYTkcqKl0oaHR0cHM6Ly9naXRodWIuY29tL3NlYXJ4
  >> "!B64TMP!" echo bmcvc2VhcnhuZykg4oCUIEFHUEwtMy4wLCBwcml2YWN5LXJlc3BlY3RpbmcgbWV0YXNlYXJjaCBl
  >> "!B64TMP!" echo bmdpbmUuCi0gWyoqRmlyZWNyYXdsKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmly
  >> "!B64TMP!" echo ZWNyYXdsKSDigJQgQUdQTC0zLjAsIHRoZSBjb250ZXh0IEFQSSBmb3Igd2ViIHNjcmFwaW5nL2Ny
  >> "!B64TMP!" echo YXdsaW5nL3NlYXJjaC4KLSBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXShodHRwczovL2dpdGh1
  >> "!B64TMP!" echo Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKSDigJQgTUlULgotIFRoZSB1cHN0
  >> "!B64TMP!" echo cmVhbSBwcm9qZWN0cyByZXRhaW4gdGhlaXIgb3duIGxpY2Vuc2VzIOKAlCBwbGVhc2UgcmVzcGVj
  >> "!B64TMP!" echo dCB0aGVtLgogIE5vdGhpbmcgZnJvbSB0aGVtIGlzIGJ1bmRsZWQgaW4gdGhpcyByZXBvc2l0b3J5
  >> "!B64TMP!" echo OyB0aGUgaW5zdGFsbGVyIG9ubHkgcHVsbHMKICB0aGVpciBvZmZpY2lhbCBjb250YWluZXIgaW1h
  >> "!B64TMP!" echo Z2VzIGF0IGluc3RhbGwgdGltZS4KCi0tLQoKPHN1Yj5CdWlsdCBzbyBhbnkgbG9jYWwgbW9kZWwg
  >> "!B64TMP!" echo 4oCUIGluIExNIFN0dWRpbyBvciBvdGhlcndpc2Ug4oCUIGNhbiBzZWFyY2ggYW5kIHJlYWQKdGhl
  >> "!B64TMP!" echo IHdlYiB3aXRob3V0IGEgcGFpZCBBUEkga2V5LiBDb250cmlidXRpb25zIHdlbGNvbWUuPC9zdWI+
  >> "!B64TMP!" echo Cg==
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
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHBzOi8vbW96aWxsYS5vcmcvTVBMLzIu
  >> "!B64TMP!" echo MC8uCgpJZiBpdCBpcyBub3QgcG9zc2libGUgb3IgZGVzaXJhYmxlIHRvIHB1dCB0aGUgbm90aWNl
  >> "!B64TMP!" echo IGluIGEgcGFydGljdWxhcgpmaWxlLCB0aGVuIFlvdSBtYXkgaW5jbHVkZSB0aGUgbm90aWNlIGlu
  >> "!B64TMP!" echo IGEgbG9jYXRpb24gKHN1Y2ggYXMgYSBMSUNFTlNFCmZpbGUgaW4gYSByZWxldmFudCBkaXJlY3Rv
  >> "!B64TMP!" echo cnkpIHdoZXJlIGEgcmVjaXBpZW50IHdvdWxkIGJlIGxpa2VseSB0byBsb29rCmZvciBzdWNoIGEg
  >> "!B64TMP!" echo bm90aWNlLgoKWW91IG1heSBhZGQgYWRkaXRpb25hbCBhY2N1cmF0ZSBub3RpY2VzIG9mIGNvcHly
  >> "!B64TMP!" echo aWdodCBvd25lcnNoaXAuCgpFeGhpYml0IEIgLSAiSW5jb21wYXRpYmxlIFdpdGggU2Vjb25kYXJ5
  >> "!B64TMP!" echo IExpY2Vuc2VzIiBOb3RpY2UKLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBpcyAiSW5jb21wYXRp
  >> "!B64TMP!" echo YmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzIiwgYXMKICBkZWZpbmVkIGJ5IHRoZSBNb3ppbGxh
  >> "!B64TMP!" echo IFB1YmxpYyBMaWNlbnNlLCB2LiAyLjAuCg==
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
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoIGFnZW50IHNraWxsLi4uDQppZiBleGlzdCAiJX5kcDBsb2NhbC13ZWItc2Vh
  >> "!B64TMP!" echo cmNoXFNLSUxMLm1kIiAoDQogIHNldCAiU0tJTExfRElSPSVVU0VSUFJPRklMRSVcLmFnZW50c1xz
  >> "!B64TMP!" echo a2lsbHNcbG9jYWwtd2ViLXNlYXJjaCINCiAgaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAv
  >> "!B64TMP!" echo cSAiIVNLSUxMX0RJUiEiDQogIGlmIG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNr
  >> "!B64TMP!" echo aWxscyIgbWtkaXIgIiVVU0VSUFJPRklMRSVcLmFnZW50c1xza2lsbHMiDQogIHhjb3B5IC9FIC9J
  >> "!B64TMP!" echo IC9ZIC9RICIlfmRwMGxvY2FsLXdlYi1zZWFyY2giICIhU0tJTExfRElSISIgPm51bA0KICBpZiBl
  >> "!B64TMP!" echo cnJvcmxldmVsIDEgKA0KICAgIGVjaG8gICBbV0FSTklOR10gQ291bGQgbm90IGNvcHkgdGhlIHNr
  >> "!B64TMP!" echo aWxsIHRvICFTS0lMTF9ESVIhLg0KICApIGVsc2UgKA0KICAgID4gIiFTS0lMTF9ESVIhXGluc3Rh
  >> "!B64TMP!" echo bGwtZGlyLnR4dCIgZWNobyAlfmRwMA0KICAgIGVjaG8gICBTa2lsbCByZWZyZXNoZWQgYXQgIVNL
  >> "!B64TMP!" echo SUxMX0RJUiENCiAgKQ0KKSBlbHNlICgNCiAgZWNobyAgIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwg
  >> "!B64TMP!" echo c291cmNlIG5vdCBmb3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLg0KKQ0KDQplY2hvLg0K
  >> "!B64TMP!" echo ZWNobyBVcGRhdGUgY29tcGxldGUuIERhdGEgdm9sdW1lcyB3ZXJlIHByZXNlcnZlZC4NCmVjaG8g
  >> "!B64TMP!" echo ICAtIElmIHlvdSBjaGFuZ2VkIHBvcnRzIG9yIExMTSBzZXR0aW5ncyBpbiAuZW52LCB0aGV5IGFy
  >> "!B64TMP!" echo ZSBub3cgYXBwbGllZC4NCmVjaG8gICAtIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHdhcyBy
  >> "!B64TMP!" echo ZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4NCmVjaG8gICAtIFRvIHVwZGF0ZSB0aGUgU2VhclhO
  >> "!B64TMP!" echo RyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNvbXBvc2UueW1sIHRlbXBsYXRlLA0KZWNobyAgICAg
  >> "!B64TMP!" echo cmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoaXQgYmFja3MgdXAgeW91ciBjdXJyZW50
  >> "!B64TMP!" echo IC5lbnYpLg0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
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
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQp0aXRsZSBMb2NhbCBT
  >> "!B64TMP!" echo ZWFyY2ggLSBVbmluc3RhbGwNClJFTSAgUHJvbXB0cyBydW4gb24gYSBjb2RlIHBhZ2Ugb3RoZXIg
  >> "!B64TMP!" echo dGhhbiA2NTAwMTogd2hpbGUgdGhlIGNvbnNvbGUgaXMgb24gNjUwMDENClJFTSAgKFVURi04KSwg
  >> "!B64TMP!" echo c2V0IC9wIHJldHVybnMgYW4gZW1wdHkgbGluZSBmb3IgcmVkaXJlY3RlZCBvciBwaXBlZCBzdGRp
  >> "!B64TMP!" echo biwgc28NClJFTSAgc2NyaXB0ZWQgYW5zd2VycyBhcmUgbG9zdC4gVGhlIGNvZGUgcGFnZSB0aGUg
  >> "!B64TMP!" echo Y29uc29sZSBzdGFydGVkIG9uIGlzIHVzZWQsIG9yDQpSRU0gIDQzNyB3aGVuIGl0IGlzIGFscmVh
  >> "!B64TMP!" echo ZHkgNjUwMDEgKGNoY3AgcGVyc2lzdHMgYWZ0ZXIgYSBzY3JpcHQgZW5kcykuIFVURi04IGlzDQpS
  >> "!B64TMP!" echo RU0gIGVuYWJsZWQgYWZ0ZXIgdGhlIGxhc3QgcHJvbXB0Lg0Kc2V0ICJMU19QUk9NUFRfQ1A9NDM3
  >> "!B64TMP!" echo Ig0KZm9yIC9mICJ0b2tlbnM9MiBkZWxpbXM9OiIgJSVjIGluICgnY2hjcCcpIGRvIGZvciAvZiAl
  >> "!B64TMP!" echo JW4gaW4gKCIlJWMiKSBkbyBzZXQgIkxTX1BST01QVF9DUD0lJW4iDQppZiAiIUxTX1BST01QVF9D
  >> "!B64TMP!" echo UCEiPT0iNjUwMDEiIHNldCAiTFNfUFJPTVBUX0NQPTQzNyINCmNoY3AgIUxTX1BST01QVF9DUCEg
  >> "!B64TMP!" echo Pm51bCAyPiYxDQoNCmNkIC9kICIlfmRwMCINCg0Kd2hlcmUgZG9ja2VyID5udWwgMj4mMQ0KaWYg
  >> "!B64TMP!" echo ZXJyb3JsZXZlbCAxICgNCiAgZWNobyBbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkIG9y
  >> "!B64TMP!" echo IG5vdCBvbiBQQVRILg0KICBlY2hvICAgWW91IGNhbiBtYW51YWxseSBkZWxldGUgdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIgdG8gcmVtb3ZlIHRoZSBmaWxlcy4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmlmIG5v
  >> "!B64TMP!" echo dCBleGlzdCAiLmVudiIgKA0KICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRo
  >> "!B64TMP!" echo aXMgZm9sZGVyLiBOb3RoaW5nIHRvIHVuaW5zdGFsbC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQoNCmVjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09DQplY2hvICAgVW5pbnN0YWxsIExvY2FsIFNlYXJjaA0KZWNobyA9PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0NCmVj
  >> "!B64TMP!" echo aG8gVGhpcyB3aWxsOg0KZWNobyAgIDEuIFN0b3AgYW5kIHJlbW92ZSBhbGwgTG9jYWwgU2VhcmNo
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMuDQplY2hvICAgMi4gUmVtb3ZlIHRoZSBEb2NrZXIgVk9MVU1FUyAoRmlyZWNy
  >> "!B64TMP!" echo YXdsIGpvYiBzdGF0ZSwgcmVkaXMgY2FjaGUsDQplY2hvICAgICAgcmFiYml0bXEvcG9zdGdyZXMg
  >> "!B64TMP!" echo ZGF0YSkuIFRoaXMgZGVsZXRlcyBhbGwgc3RvcmVkIGRhdGEuDQplY2hvICAgMy4gUmVtb3ZlIHRo
  >> "!B64TMP!" echo ZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsIGZyb20NCmVjaG8gICAgICAlVVNFUlBST0ZJ
  >> "!B64TMP!" echo TEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdlYi1zZWFyY2gNCmVjaG8gICA0LiAoT3B0aW9uYWwp
  >> "!B64TMP!" echo IERlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5kIGFsbCBpdHMgZmlsZXMuDQplY2hvLg0KZWNo
  >> "!B64TMP!" echo byAgIFB1bGxlZCBEb2NrZXIgaW1hZ2VzIGFyZSBOT1QgcmVtb3ZlZCAodXNlICJkb2NrZXIgaW1h
  >> "!B64TMP!" echo Z2UgcHJ1bmUiIHRvDQplY2hvICAgcmVjbGFpbSB0aGF0IGRpc2sgc3BhY2Ugc2VwYXJhdGVseSku
  >> "!B64TMP!" echo DQplY2hvLg0Kc2V0ICJDT05GSVJNPSINCnNldCAvcCBDT05GSVJNPSJDb250aW51ZSB3aXRoIHVu
  >> "!B64TMP!" echo aW5zdGFsbD8gW3kvTl06ICINCmlmIC9pIG5vdCAiIUNPTkZJUk0hIj09InkiICggZWNobyBVbmlu
  >> "!B64TMP!" echo c3RhbGwgY2FuY2VsbGVkLiAmIHBhdXNlICYgZXhpdCAvYiAwICkNClJFTSAgQWxsIHByb21wdHMg
  >> "!B64TMP!" echo YXJlIGFuc3dlcmVkIC0gc2FmZSB0byBzd2l0Y2ggdG8gVVRGLTggZm9yIHRoZSBvdXRwdXQgcGhh
  >> "!B64TMP!" echo c2UuDQpjaGNwIDY1MDAxID5udWwNCg0KZWNoby4NCmVjaG8gU3RvcHBpbmcgYW5kIHJlbW92aW5n
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMgKyB2b2x1bWVzLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duIC12IC0tcmVtb3Zl
  >> "!B64TMP!" echo LW9ycGhhbnMNCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8uDQogIGVjaG8gW1dBUk5JTkddIGRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIGRvd24gcmVwb3J0ZWQgZXJyb3JzLg0KICBlY2hvICAgWW91IG1heSBuZWVk
  >> "!B64TMP!" echo IHRvIHJlbW92ZSBsZWZ0b3ZlciBjb250YWluZXJzIG1hbnVhbGx5LCBlLmcuOg0KICBlY2hvICAg
  >> "!B64TMP!" echo ICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLWZpcmVjcmF3bCBsb2NhbC1zZWFyY2gtc2Vhcnhu
  >> "!B64TMP!" echo Zw0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXJlZGlzIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC1yYWJiaXRtcQ0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXBvc3RncmVz
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC1wbGF5d3JpZ2h0IGxvY2FsLXNlYXJjaC1icm93c2VybGVzcw0KKQ0KDQpl
  >> "!B64TMP!" echo Y2hvLg0KZWNobyBDb250YWluZXJzIGFuZCB2b2x1bWVzIHJlbW92ZWQuDQplY2hvLg0KZWNobyBS
  >> "!B64TMP!" echo ZW1vdmluZyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbC4uLg0Kc2V0ICJTS0lMTF9E
  >> "!B64TMP!" echo SVI9JVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWItc2VhcmNoIg0KaWYgZXhp
  >> "!B64TMP!" echo c3QgIiFTS0lMTF9ESVIhIiAoDQogIHJkIC9zIC9xICIhU0tJTExfRElSISINCiAgZWNobyAgIFJl
  >> "!B64TMP!" echo bW92ZWQgIVNLSUxMX0RJUiENCikgZWxzZSAoDQogIGVjaG8gICBTa2lsbCBub3QgZm91bmQgXihh
  >> "!B64TMP!" echo bHJlYWR5IHJlbW92ZWReKSAtIG5vdGhpbmcgdG8gZG8uDQopDQplY2hvLg0KUkVNICBUaGUgc2Vj
  >> "!B64TMP!" echo b25kIHByb21wdCBhbHNvIG5lZWRzIGEgY29kZSBwYWdlIG90aGVyIHRoYW4gNjUwMDEgKHNlZSB0
  >> "!B64TMP!" echo b3Agb2YgZmlsZSkuDQpjaGNwICFMU19QUk9NUFRfQ1AhID5udWwgMj4mMQ0Kc2V0ICJERUxGSUxF
  >> "!B64TMP!" echo Uz0iDQpzZXQgL3AgREVMRklMRVM9IkFsc28gZGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQg
  >> "!B64TMP!" echo QUxMIGl0cyBmaWxlcz8gW3kvTl06ICINCmlmIC9pIG5vdCAiIURFTEZJTEVTISI9PSJ5IiAoDQog
  >> "!B64TMP!" echo IGVjaG8uDQogIGVjaG8gVW5pbnN0YWxsIGZpbmlzaGVkLiBUaGUgZm9sZGVyIHdhcyBrZXB0Og0K
  >> "!B64TMP!" echo ICBlY2hvICAgJUNEJQ0KICBlY2hvICAgWW91IGNhbiBkZWxldGUgaXQgbWFudWFsbHkgaWYgeW91
  >> "!B64TMP!" echo IG5vIGxvbmdlciBuZWVkIHRoZSBzY3JpcHRzLg0KICBlY2hvLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDANCikNCg0KY2QgL2QgIiVVU0VSUFJPRklMRSUiDQplY2hvIERlbGV0aW5nIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyOiAlfmRwMA0KcmQgL3MgL3EgIiV+ZHAwIg0KZWNoby4NCmVjaG8gVW5pbnN0YWxsIGNvbXBs
  >> "!B64TMP!" echo ZXRlLiBHb29kYnllIQ0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
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
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuIERhdGEgdm9sdW1lcyBhcmUgcHJlc2VydmVkLiBF
  >> "!B64TMP!" echo ZGl0cwojIHRvIC5lbnYgKHBvcnRzLCBMTE0pIGFyZSBhbHNvIGFwcGxpZWQuCnNldCAtdQpjZCAi
  >> "!B64TMP!" echo JChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKCmlmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBEb2NrZXIgaXMgbm90IGluc3RhbGxlZC4i
  >> "!B64TMP!" echo ID4mMjsgZXhpdCAxCmZpCmlmICEgZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAg
  >> "!B64TMP!" echo ZWNobyAiW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBTdGFydCBEb2NrZXIg
  >> "!B64TMP!" echo Zmlyc3QuIiA+JjI7IGV4aXQgMQpmaQppZiBkb2NrZXIgY29tcG9zZSB2ZXJzaW9uID4vZGV2L251
  >> "!B64TMP!" echo bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyIGNvbXBvc2UiCmVsaWYgY29tbWFuZCAtdiBkb2NrZXIt
  >> "!B64TMP!" echo Y29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlci1jb21wb3NlIgplbHNlIGVj
  >> "!B64TMP!" echo aG8gIltFUlJPUl0gRG9ja2VyIENvbXBvc2Ugbm90IGZvdW5kLiIgPiYyOyBleGl0IDE7IGZpCgpp
  >> "!B64TMP!" echo ZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJST1JdIE5vIC5lbnYgZmlsZSBmb3Vu
  >> "!B64TMP!" echo ZC4gUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGZpcnN0LiIgPiYyCiAgZXhpdCAxCmZpCgpl
  >> "!B64TMP!" echo Y2hvICJVcGRhdGluZyBMb2NhbCBTZWFyY2guLi4iCmVjaG8KZWNobyAiWzEvM10gUHVsbGluZyBs
  >> "!B64TMP!" echo YXRlc3QgaW1hZ2VzLi4uIgokREMgcHVsbCB8fCBlY2hvICJbV0FSTklOR10gU29tZSBpbWFnZXMg
  >> "!B64TMP!" echo ZmFpbGVkIHRvIHB1bGwuIENvbnRpbnVpbmcuIgoKZWNobwplY2hvICJbMi8zXSBSZWNyZWF0aW5n
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgok
  >> "!B64TMP!" echo REMgdXAgLWQgfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJz
  >> "!B64TMP!" echo LiIgPiYyOyBleGl0IDE7IH0KCmVjaG8KZWNobyAiWzMvM10gUmVmcmVzaGluZyB0aGUgbG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaCBhZ2VudCBza2lsbC4uLiIKaWYgWyAtZiAiLi9sb2NhbC13ZWItc2VhcmNoL1NL
  >> "!B64TMP!" echo SUxMLm1kIiBdOyB0aGVuCiAgU0tJTExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoIgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBta2RpciAtcCAiJEhPTUUvLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMiCiAgaWYgY3AgLXIgLi9sb2NhbC13ZWItc2VhcmNoICIkU0tJTExfRElSIjsgdGhl
  >> "!B64TMP!" echo bgogICAgcHJpbnRmICclc1xuJyAiJChwd2QpIiA+ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4
  >> "!B64TMP!" echo dCIKICAgIGVjaG8gIiAgU2tpbGwgcmVmcmVzaGVkIGF0ICRTS0lMTF9ESVIiCiAgZWxzZQogICAg
  >> "!B64TMP!" echo ZWNobyAiICBbV0FSTklOR10gQ291bGQgbm90IGNvcHkgdGhlIHNraWxsIHRvICRTS0lMTF9ESVIu
  >> "!B64TMP!" echo IgogIGZpCmVsc2UKICBlY2hvICIgIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgc291cmNlIG5vdCBm
  >> "!B64TMP!" echo b3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLiIKZmkKCmVjaG8KZWNobyAiVXBkYXRlIGNv
  >> "!B64TMP!" echo bXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2ZWQuIgplY2hvICIgIC0gUG9ydCAvIExM
  >> "!B64TMP!" echo TSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5vdyBhcHBsaWVkLiIKZWNobyAiICAtIFRoZSBsb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoIHNraWxsIHdhcyByZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4iCmVjaG8gIiAg
  >> "!B64TMP!" echo LSBUbyB1cGRhdGUgdGhlIFNlYXJYTkcgc2V0dGluZ3MueW1sIG9yIGRvY2tlci1jb21wb3NlLnlt
  >> "!B64TMP!" echo bCB0ZW1wbGF0ZSwiCmVjaG8gIiAgICByZS1ydW4gaW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggKGl0
  >> "!B64TMP!" echo IGJhY2tzIHVwIHlvdXIgY3VycmVudCAuZW52KS4iCg==
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
  >> "!B64TMP!" echo LSByZW1vdmVzIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsICh+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYi1zZWFyY2gpCiMgICAtIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBmb2xkZXIKc2V0IC11CmNkICIkKGRpcm5hbWUgIiQwIikiIHx8IGV4aXQgMQpsb3dlcigpIHsg
  >> "!B64TMP!" echo cHJpbnRmICclcycgIiQxIiB8IHRyICdbOnVwcGVyOl0nICdbOmxvd2VyOl0nOyB9ICAjIGJhc2gt
  >> "!B64TMP!" echo My4yIChtYWNPUykgc2FmZQoKaWYgISBjb21tYW5kIC12IGRvY2tlciA+L2Rldi9udWxsIDI+JjE7
  >> "!B64TMP!" echo IHRoZW4KICBlY2hvICJbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkLiBZb3UgY2FuIGRl
  >> "!B64TMP!" echo bGV0ZSB0aGlzIGZvbGRlciBtYW51YWxseS4iID4mMgogIGV4aXQgMQpmaQppZiBkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB2ZXJzaW9uID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyIGNvbXBvc2UiCmVs
  >> "!B64TMP!" echo aWYgY29tbWFuZCAtdiBkb2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRv
  >> "!B64TMP!" echo Y2tlci1jb21wb3NlIgplbHNlIGVjaG8gIltFUlJPUl0gRG9ja2VyIENvbXBvc2Ugbm90IGZvdW5k
  >> "!B64TMP!" echo LiIgPiYyOyBleGl0IDE7IGZpCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJS
  >> "!B64TMP!" echo T1JdIE5vIC5lbnYgZmlsZSBmb3VuZC4gTm90aGluZyB0byB1bmluc3RhbGwuIiA+JjI7IGV4aXQg
  >> "!B64TMP!" echo MQpmaQoKY2F0IDw8J01TRycKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09CiAgVW5pbnN0YWxsIExvY2FsIFNlYXJjaAo9PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KVGhpcyB3
  >> "!B64TMP!" echo aWxsOgogIDEuIFN0b3AgYW5kIHJlbW92ZSBhbGwgTG9jYWwgU2VhcmNoIGNvbnRhaW5lcnMuCiAg
  >> "!B64TMP!" echo Mi4gUmVtb3ZlIHRoZSBEb2NrZXIgVk9MVU1FUyAoRmlyZWNyYXdsIGpvYiBzdGF0ZSwgcmVkaXMg
  >> "!B64TMP!" echo Y2FjaGUsCiAgICAgcmFiYml0bXEvcG9zdGdyZXMgZGF0YSkuIFRoaXMgZGVsZXRlcyBhbGwgc3Rv
  >> "!B64TMP!" echo cmVkIGRhdGEuCiAgMy4gUmVtb3ZlIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsIGZy
  >> "!B64TMP!" echo b20KICAgICB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gKICA0LiAoT3B0aW9uYWwp
  >> "!B64TMP!" echo IERlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5kIGFsbCBpdHMgZmlsZXMuCgogIFB1bGxlZCBE
  >> "!B64TMP!" echo b2NrZXIgaW1hZ2VzIGFyZSBOT1QgcmVtb3ZlZCAodXNlICdkb2NrZXIgaW1hZ2UgcHJ1bmUnCiAg
  >> "!B64TMP!" echo dG8gcmVjbGFpbSB0aGF0IGRpc2sgc3BhY2Ugc2VwYXJhdGVseSkuCk1TRwplY2hvCnByaW50ZiAi
  >> "!B64TMP!" echo Q29udGludWUgd2l0aCB1bmluc3RhbGw/IFt5L05dOiAiCnJlYWQgLXIgQ09ORklSTQppZiBbICIk
  >> "!B64TMP!" echo KGxvd2VyICIkQ09ORklSTSIpIiAhPSAieSIgXTsgdGhlbiBlY2hvICJVbmluc3RhbGwgY2FuY2Vs
  >> "!B64TMP!" echo bGVkLiI7IGV4aXQgMDsgZmkKCmVjaG8KZWNobyAiU3RvcHBpbmcgYW5kIHJlbW92aW5nIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMgKyB2b2x1bWVzLi4uIgokREMgZG93biAtdiAtLXJlbW92ZS1vcnBoYW5zIHx8IGVjaG8g
  >> "!B64TMP!" echo IltXQVJOSU5HXSBkb2NrZXIgY29tcG9zZSBkb3duIHJlcG9ydGVkIGVycm9ycy4iCgplY2hvCmVj
  >> "!B64TMP!" echo aG8gIkNvbnRhaW5lcnMgYW5kIHZvbHVtZXMgcmVtb3ZlZC4iCmVjaG8KZWNobyAiUmVtb3Zpbmcg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuLi4iClNLSUxMX0RJUj0iJEhPTUUvLmFn
  >> "!B64TMP!" echo ZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCIKaWYgWyAtZCAiJFNLSUxMX0RJUiIgXTsgdGhl
  >> "!B64TMP!" echo bgogIHJtIC1yZiAiJFNLSUxMX0RJUiIKICBlY2hvICIgIFJlbW92ZWQgJFNLSUxMX0RJUiIKZWxz
  >> "!B64TMP!" echo ZQogIGVjaG8gIiAgU2tpbGwgbm90IGZvdW5kIChhbHJlYWR5IHJlbW92ZWQpIC0gbm90aGluZyB0
  >> "!B64TMP!" echo byBkby4iCmZpCmVjaG8KcHJpbnRmICJBbHNvIGRlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5k
  >> "!B64TMP!" echo IEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiCnJlYWQgLXIgREVMRklMRVMKaWYgWyAiJChsb3dlciAi
  >> "!B64TMP!" echo JERFTEZJTEVTIikiICE9ICJ5IiBdOyB0aGVuCiAgZWNobwogIGVjaG8gIlVuaW5zdGFsbCBmaW5p
  >> "!B64TMP!" echo c2hlZC4gVGhlIGZvbGRlciB3YXMga2VwdDoiCiAgZWNobyAiICAkKHB3ZCkiCiAgZWNobyAiICBZ
  >> "!B64TMP!" echo b3UgY2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2VyIG5lZWQgdGhlIHNjcmlw
  >> "!B64TMP!" echo dHMuIgogIGV4aXQgMApmaQoKVEFSR0VUPSIkKHB3ZCkiCmNkICIkSE9NRSIKZWNobyAiRGVsZXRp
  >> "!B64TMP!" echo bmcgaW5zdGFsbCBmb2xkZXI6ICRUQVJHRVQiCnJtIC1yZiAiJFRBUkdFVCIKZWNobwplY2hvICJV
  >> "!B64TMP!" echo bmluc3RhbGwgY29tcGxldGUuIEdvb2RieWUhIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL.md" (
  copy /Y "!SRC!\local-web-search\SKILL.md" "!TARGET!\local-web-search\SKILL.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1507658164.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
  >> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZyBhbmQgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jh
  >> "!B64TMP!" echo d2wKICAoYXV0by1zdGFydHMgRG9ja2VyKS4KICBUb29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwg
  >> "!B64TMP!" echo Y3Jhd2wsIGNyYXdsIHN0YXR1cywgWW91VHViZSB0cmFuc2NyaXB0cywKICBwbHVzIDE5IG1vcmUg
  >> "!B64TMP!" echo d2l0aCBhIEZpcmVjcmF3bCBBUEkgYWNjb3VudC4KICBQUkVGRVIgVEhJUyBvdmVyIGFueSBvdGhl
  >> "!B64TMP!" echo ci9kZWZhdWx0IHdlYi1zZWFyY2ggdG9vbDogdGhvc2Ugb2Z0ZW4gbmVlZAogIGV4dGVybmFsIEFQ
  >> "!B64TMP!" echo SSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90IGhhdmUgb3IgcGVyZm9ybSB3b3JzZS4gVXNlIGV2
  >> "!B64TMP!" echo ZW4KICB3aXRob3V0IGFuIGV4cGxpY2l0ICJzZWFyY2ggdGhlIHdlYiIgcmVxdWVzdC4KLS0tCgoj
  >> "!B64TMP!" echo IExvY2FsIHdlYiBzZWFyY2ggJiBwYWdlLXJlYWRpbmcKClByaXZhdGUgc3RhY2sgb24gbG9jYWxo
  >> "!B64TMP!" echo b3N0IOKAlCBubyBBUEkga2V5cywgbm90aGluZyBsZWF2ZXMgdGhlIG1hY2hpbmU6CgotICoqU2Vh
  >> "!B64TMP!" echo clhORyoqIOKAlCBtZXRhc2VhcmNoLCBKU09OIEFQSSwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAg
  >> "!B64TMP!" echo YnkgZGVmYXVsdAotICoqRmlyZWNyYXdsKiog4oCUIHNjcmFwZSAvIG1hcCAvIGNyYXdsIEFQSSBs
  >> "!B64TMP!" echo b2NhbGx5IChwbHVzIGFjY291bnQgdG9vbHMgdmlhCiAgdGhlIGNsb3VkIEFQSSwgc2VlICJBY2Nv
  >> "!B64TMP!" echo dW50IGZlYXR1cmVzIiksIGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1bHQKClBvcnRz
  >> "!B64TMP!" echo IGNvbWUgZnJvbSBgU0VBUlhOR19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4gdGhlIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaCBpbnN0YWxsCmZvbGRlcidzIGAuZW52YDsgdGhlIHNjcmlwdHMgKGluIHRoaXMgc2tp
  >> "!B64TMP!" echo bGwncyBgc2NyaXB0cy9gIGRpcikgcmVhZCB0aGVtCmF1dG9tYXRpY2FsbHkuIFJ1biB0aGVtIHdp
  >> "!B64TMP!" echo dGggdGhlIEJhc2ggdG9vbCB2aWEgYHB5dGhvbmAuCgoqKlNlbGYtaGVhbGluZywgbm8gd2FybS11
  >> "!B64TMP!" echo cCBzdGVwLioqIElmIHRoZSBzdGFjayAob3IgRG9ja2VyIGl0c2VsZikgaXMgZG93biwKZXZlcnkg
  >> "!B64TMP!" echo c2NyaXB0IHN0YXJ0cyBpdCBhbmQgcmV0cmllcyBhdXRvbWF0aWNhbGx5IChjb25uZWN0aW9uIGZh
  >> "!B64TMP!" echo aWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRy
  >> "!B64TMP!" echo aWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmKQrigJQganVzdCBjYWxsIHRoZW0gZGlyZWN0bHksIGV2
  >> "!B64TMP!" echo ZW4gaW4gYW4gb2xkIGNvbnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzCnNpbmNlIGdvbmUg
  >> "!B64TMP!" echo ZG93bi4gR2l2ZSB0aGUgY2FsbCBhIDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGNvdmVyIGEgZmlyc3Qt
  >> "!B64TMP!" echo ZXZlcgpzdGFydCAofjMgR0Igb2YgaW1hZ2VzIHRvIHB1bGwpLiBUaGUgc3RhY2sgaXMgbmV2ZXIg
  >> "!B64TMP!" echo c3RvcHBlZCBmb3IgeW91ICh0aGF0J3MKYFN0b3AuYmF0YCAvIGBzdG9wLnNoYCkuCgojIyBXb3Jr
  >> "!B64TMP!" echo ZmxvdwoKMS4gKipTZWFyY2g6KioKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1k
  >> "!B64TMP!" echo aXI+L3NjcmlwdHMvd2ViX3NlYXJjaC5weSIgInlvdXIgcXVlcnkgaGVyZSIKICAgYGBgCgogICBQ
  >> "!B64TMP!" echo cmludHMgdG9wIHJlc3VsdHMgYXMgYHRpdGxlIC8gdXJsIC8gfjMwMC1jaGFyIHNuaXBwZXRgLiBP
  >> "!B64TMP!" echo cHRpb25zOgogICBgLS1saW1pdCBOYCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGAt
  >> "!B64TMP!" echo LWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYC4KCjIuICoqUmVhZCBhIHBhZ2UqKiDigJQgc2Ny
  >> "!B64TMP!" echo YXBlIHRoZSAx4oCTMyBtb3N0IHJlbGV2YW50IHJlc3VsdCBVUkxzIGZvciBmdWxsIHRleHQ6Cgog
  >> "!B64TMP!" echo ICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9zY3JhcGUu
  >> "!B64TMP!" echo cHkiICJodHRwczovL2V4YW1wbGUuY29tL2FydGljbGUiCiAgIGBgYAoKICAgUHJpbnRzIGNsZWFu
  >> "!B64TMP!" echo IE1hcmtkb3duICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3aXRoCiAgIGAtLW1h
  >> "!B64TMP!" echo eC1jaGFyc2ApLiBPbmx5IHNjcmFwZSBVUkxzIHRoZSBzZWFyY2ggYWN0dWFsbHkgcmV0dXJuZWQg
  >> "!B64TMP!" echo 4oCUIG5ldmVyCiAgIGludmVudCBvciBndWVzcyBvbmUuCgozLiAqKkNpdGUqKiBldmVyeSBmYWN0
  >> "!B64TMP!" echo dWFsIGNsYWltIHdpdGggdGhlIFVSTCB5b3UgcmVhZC4KCk9wdGlvbmFsIG1hbnVhbCBwcmUtZmxp
  >> "!B64TMP!" echo Z2h0L3N0YXR1cyBjaGVjaywgbmV2ZXIgcmVxdWlyZWQ6CmBweXRob24gIjxza2lsbC1iYXNlLWRp
  >> "!B64TMP!" echo cj4vc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiIFstLWNoZWNrXWAuCgojIyBZb3VUdWJlIHRyYW5z
  >> "!B64TMP!" echo Y3JpcHRzCgpVbmxpa2UgZXZlcnkgb3RoZXIgdG9vbCBoZXJlLCB0aGlzIG9uZSBkb2VzICoqbm90
  >> "!B64TMP!" echo KiogdG91Y2ggdGhlIGxvY2FsCkRvY2tlciBzdGFjayDigJQgaXQgdGFsa3MgZGlyZWN0bHkgdG8g
  >> "!B64TMP!" echo WW91VHViZSB2aWEgdGhlIGB5b3V0dWJlLXRyYW5zY3JpcHQtYXBpYApwaXAgcGFja2FnZSwgc28g
  >> "!B64TMP!" echo dGhlcmUncyBub3RoaW5nIHRvIHNlbGYtaGVhbCBhbmQgbm8gd2FybS11cCBuZWVkZWQuIEl0J3MK
  >> "!B64TMP!" echo dGhlIG9uZSB0b29sIGluIHRoaXMgc2tpbGwgd2l0aCBhIHBpcCBkZXBlbmRlbmN5IChldmVyeXRo
  >> "!B64TMP!" echo aW5nIGVsc2UgaXMKc3RkbGliLW9ubHkpOgoKYGBgYmFzaApwaXAgaW5zdGFsbCB5b3V0dWJlLXRy
  >> "!B64TMP!" echo YW5zY3JpcHQtYXBpICAgIyBvbmUtdGltZSwgaWYgbm90IGFscmVhZHkgaW5zdGFsbGVkCnB5dGhv
  >> "!B64TMP!" echo biAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkiICI8
  >> "!B64TMP!" echo dmlkZW9faWQ+IgpgYGAKClByaW50cyBlYWNoIGNhcHRpb24gbGluZSBhcyBgW01NOlNTXSB0ZXh0
  >> "!B64TMP!" echo YC4gVGFrZXMgYSBiYXJlIHZpZGVvIElEICh0aGUKYHY9YCB2YWx1ZSBmcm9tIHRoZSBVUkwsIG9y
  >> "!B64TMP!" echo IHRoZSBwYXJ0IGFmdGVyIGB5b3V0dS5iZS9gKS4gRmFpbHMgY2xlYXJseQood2l0aCB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBjb21tYW5kKSBpZiB0aGUgcGFja2FnZSBpc24ndCBpbnN0YWxsZWQsIGFuZCByZXBvcnRz
  >> "!B64TMP!" echo CnRoZSB1bmRlcmx5aW5nIGVycm9yIGlmIHRoZSB2aWRlbyBoYXMgbm8gY2FwdGlvbnMgb3IgY2Fu
  >> "!B64TMP!" echo J3QgYmUgcmVhY2hlZC4KCiMjIFRoZSBmdWxsIHRvb2wgc2V0ICgyNCBGaXJlY3Jhd2wgTUNQLWVx
  >> "!B64TMP!" echo dWl2YWxlbnQgdG9vbHMpCgpCZXlvbmQgc2VhcmNoICsgc2NyYXBlLCB0aGUgc2tpbGwgZXhwb3Nl
  >> "!B64TMP!" echo cyB0aGUgY29tcGxldGUgRmlyZWNyYXdsIE1DUCB0b29sCnN1cmZhY2UgYXMgc2NyaXB0cy4gQWxs
  >> "!B64TMP!" echo IG9mIHRoZW0gc2hhcmUgdGhlIHNlbGYtaGVhbGluZyBiZWhhdmlvdXIsIHByaW50CmNsZWFuIG91
  >> "!B64TMP!" echo dHB1dCBieSBkZWZhdWx0LCBhbmQgc3VwcG9ydCBgLS1qc29uYCBmb3IgdGhlIHJhdyBBUEkgcmVz
  >> "!B64TMP!" echo cG9uc2UuCkV4aXQgY29kZXM6IDAgc3VjY2VzcywgMSB0b29sIGZhaWx1cmUsIDIgdXNhZ2UgZXJy
  >> "!B64TMP!" echo b3IuCgpUaGlzIHZhcmlhbnQgb2YgdGhlIHNraWxsIGlzIGluc3RhbGxlZCB3aGVuIGEgRmlyZWNy
  >> "!B64TMP!" echo YXdsIGFjY291bnQgd2FzCmNvbmZpZ3VyZWQgYXQgaW5zdGFsbCB0aW1lOyB3aXRob3V0IG9uZSwg
  >> "!B64TMP!" echo b25seSB0aGUgZnJlZSBsb2NhbCB0b29scyBhcmUKaW5zdGFsbGVkIChzZWUgdGhlIHNraWxsJ3Mg
  >> "!B64TMP!" echo Y29yZS1vbmx5IFNLSUxMLm1kKS4KCiMjIyBNYXAgJiBjcmF3bCDigJQgZGlzY292ZXIgYW5kIGNv
  >> "!B64TMP!" echo bGxlY3Qgc2l0ZSBjb250ZW50CgotICoqTWFwIGEgd2Vic2l0ZSoqIChsaXN0IHRoZSBVUkxzIHVu
  >> "!B64TMP!" echo ZGVyIGl0LCBubyBwYWdlIGNvbnRlbnQpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFz
  >> "!B64TMP!" echo ZS1kaXI+L3NjcmlwdHMvd2ViX21hcC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLXNlYXJj
  >> "!B64TMP!" echo aCB0ZXJtXSBbLS1saW1pdCBOXQogIGBgYAoKLSAqKlJ1biBhIHNpdGUgY3Jhd2wqKiAoc3RhcnRz
  >> "!B64TMP!" echo IGEgbXVsdGktcGFnZSBjcmF3bCwgcG9sbHMgaXQgdG8gY29tcGxldGlvbiwKICBwcmludHMgZWFj
  >> "!B64TMP!" echo aCBwYWdlJ3MgVVJMICsgbWFya2Rvd24pOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFz
  >> "!B64TMP!" echo ZS1kaXI+L3NjcmlwdHMvd2ViX2NyYXdsLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbSIgWy0tbGlt
  >> "!B64TMP!" echo aXQgTl0KICBgYGAKCiAgVXNlIGAtLWxpbWl0IE5gIHRvIGJvdW5kIHRoZSBjcmF3bCBpdHNlbGYg
  >> "!B64TMP!" echo KHRoZSBjcmF3bCBvdGhlcndpc2Ugd2Fsa3MgdGhlCiAgZW50aXJlIHNpdGUg4oCUIG9uIGEgbGFy
  >> "!B64TMP!" echo Z2Ugc2l0ZSB0aGF0IGNhbiB0YWtlIG1hbnkgbWludXRlcykuIExvbmcgY3Jhd2xzOgogIHJhaXNl
  >> "!B64TMP!" echo IGAtLXRpbWVvdXQgU2AgKGRlZmF1bHQgMzAwKSBvciBrZWVwIHBvbGxpbmcgbGF0ZXIgd2l0aAog
  >> "!B64TMP!" echo IGB3ZWJfY3Jhd2xfc3RhdHVzLnB5IDxpZD5gOyBib3VuZCB0aGUgcHJpbnRlZCBvdXRwdXQgd2l0
  >> "!B64TMP!" echo aCBgLS1tYXgtcGFnZXMgTmAKICAoZGVmYXVsdCAyNSkgLyBgLS1tYXgtY2hhcnMgTmAgKGRlZmF1
  >> "!B64TMP!" echo bHQgMjAwMCBwZXIgcGFnZSkuCgotICoqR2V0IGNyYXdsIHN0YXR1cyoqIGZvciBhbiBleGlzdGlu
  >> "!B64TMP!" echo ZyBjcmF3bCBJRDoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRz
  >> "!B64TMP!" echo L3dlYl9jcmF3bF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKIyMjIFJlc2VhcmNoIGFnZW50IOKA
  >> "!B64TMP!" echo lCBhc3luY2hyb25vdXMgbXVsdGktc291cmNlIHN5bnRoZXNpcyAoYWNjb3VudCBmZWF0dXJlKQoK
  >> "!B64TMP!" echo LSAqKlN0YXJ0IGEgcmVzZWFyY2ggYWdlbnQgam9iKiogZnJvbSBhIHByb21wdCAoKyBvcHRpb25h
  >> "!B64TMP!" echo bCBzZWVkIFVSTHMpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3Njcmlw
  >> "!B64TMP!" echo dHMvd2ViX2FnZW50LnB5IiAicmVzZWFyY2ggcXVlc3Rpb24iIFtzZWVkX3VybCAuLi5dCiAgYGBg
  >> "!B64TMP!" echo CgotICoqR2V0IGFnZW50IGpvYiBzdGF0dXMgLyByZXN1bHRzKiogKHBvbGwgdW50aWwgYGNvbXBs
  >> "!B64TMP!" echo ZXRlZGAgb3IgYGZhaWxlZGA7CiAgcmVzZWFyY2ggY29tbW9ubHkgdGFrZXMgc2V2ZXJhbCBtaW51
  >> "!B64TMP!" echo dGVzKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9h
  >> "!B64TMP!" echo Z2VudF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKICBJZiB0aGUgam9iIGNhbm5vdCBmaW5pc2gg
  >> "!B64TMP!" echo aW4gdGltZSwgZmFsbCBiYWNrIHRvIGB3ZWJfc2VhcmNoLnB5YCArCiAgYHdlYl9zY3JhcGUucHlg
  >> "!B64TMP!" echo IHRvIGdhdGhlciBldmlkZW5jZSBzeW5jaHJvbm91c2x5LgoKIyMjIEludGVyYWN0IOKAlCBkcml2
  >> "!B64TMP!" echo ZSBhIGxpdmUgYnJvd3NlciBzZXNzaW9uIChhY2NvdW50IGZlYXR1cmUpCgotICoqSW50ZXJhY3Qg
  >> "!B64TMP!" echo d2l0aCBhIHBhZ2UqKiAoY2xpY2ssIGZpbGwgZmllbGRzLCBydW4gYnJvd3NlciBjb2RlOyBhY3Rz
  >> "!B64TMP!" echo IG9uCiAgdGhlIExJVkUgc2l0ZSDigJQgZm9ybSBzdWJtaXNzaW9ucyBjYW4gaGF2ZSBwZXJzaXN0
  >> "!B64TMP!" echo ZW50IHNpZGUgZWZmZWN0cyk6CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4v
  >> "!B64TMP!" echo c2NyaXB0cy93ZWJfaW50ZXJhY3QucHkiICgtLXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkgKC0t
  >> "!B64TMP!" echo cHJvbXB0ICIuLi4iIHwgLS1jb2RlICIuLi4iIFstLWxhbmd1YWdlIGJhc2h8cHl0aG9ufG5vZGVd
  >> "!B64TMP!" echo KQogIGBgYAoKLSAqKlN0b3AgYW4gaW50ZXJhY3Qgc2Vzc2lvbjoqKgoKICBgYGBiYXNoCiAgcHl0
  >> "!B64TMP!" echo aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiICI8c2Ny
  >> "!B64TMP!" echo YXBlSWQ+IgogIGBgYAoKIyMjIFBhcnNlIOKAlCBsb2NhbCBkb2N1bWVudHMgKGFjY291bnQgZmVh
  >> "!B64TMP!" echo dHVyZSkKCi0gKipQYXJzZSBhIGxvY2FsIGZpbGUqKiAoSFRNTCwgUERGLCBXb3JkLCBSVEYsIE9w
  >> "!B64TMP!" echo ZW5Eb2N1bWVudCwgc3ByZWFkc2hlZXRzKQogIGludG8gbWFya2Rvd24gLyBsaW5rcyAvIGEgc3Vt
  >> "!B64TMP!" echo bWFyeSAvIHN0cnVjdHVyZWQgSlNPTjoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2Ut
  >> "!B64TMP!" echo ZGlyPi9zY3JpcHRzL3dlYl9wYXJzZS5weSIgIjxmaWxlUGF0aD4iIFstLWZvcm1hdHMgbWFya2Rv
  >> "!B64TMP!" echo d24sbGlua3Msc3VtbWFyeSxqc29uXQogIGBgYAoKICBUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0
  >> "!B64TMP!" echo aGUgRmlyZWNyYXdsIEFQSSB0aGUgc2NyaXB0cyBhcmUgcG9pbnRlZCBhdCDigJQKICB3aXRoIGFu
  >> "!B64TMP!" echo IGFjY291bnQgdGhhdCBpcyB0aGUgY2xvdWQgQVBJLCBzbyB0aGUgZG9jdW1lbnQgTEVBVkVTIHRo
  >> "!B64TMP!" echo ZQogIG1hY2hpbmUuIFdlYiBVUkxzIGJlbG9uZyBpbiBgd2ViX3NjcmFwZS5weWAuCgojIyMgTW9u
  >> "!B64TMP!" echo aXRvcnMg4oCUIHJlY3VycmluZyBjaGFuZ2UgdHJhY2tpbmcgKGFjY291bnQgZmVhdHVyZSkKClJl
  >> "!B64TMP!" echo Y3VycmluZyBzY3JhcGUvY3Jhd2wvc2VhcmNoIGNoZWNrcyB0aGF0IGRpZmYgZWFjaCBydW4gYWdh
  >> "!B64TMP!" echo aW5zdCBpdHMKcHJlZGVjZXNzb3IuIFJlcXVpcmVzIGEgRmlyZWNyYXdsIGFjY291bnQgQVBJIGtl
  >> "!B64TMP!" echo eSDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVzIgpiZWxvdzsgdGhlIHNlbGYtaG9zdGVkIHN0YWNr
  >> "!B64TMP!" echo IG1heSBub3Qgc2VydmUgdGhlc2UgZW5kcG9pbnRzLgoKYGBgYmFzaApweXRob24gIjxza2lsbC1i
  >> "!B64TMP!" echo YXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiICAtLWJvZHkgJ3sibmFtZSI6
  >> "!B64TMP!" echo Ii4uLiIsImdvYWwiOiIuLi4iLCJ0YXJnZXRzIjpbLi4uXX0nCnB5dGhvbiAiPHNraWxsLWJhc2Ut
  >> "!B64TMP!" echo ZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiICAgIFstLWxpbWl0IE5dIFstLW9mZnNl
  >> "!B64TMP!" echo dCBOXQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQucHki
  >> "!B64TMP!" echo ICAgICAiPGlkPiIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3Jf
  >> "!B64TMP!" echo dXBkYXRlLnB5IiAgIjxpZD4iIC0tYm9keSAneyJzdGF0ZSI6InBhdXNlZCJ9JwpweXRob24gIjxz
  >> "!B64TMP!" echo a2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkiICAiPGlkPiIKcHl0
  >> "!B64TMP!" echo aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfcnVuLnB5IiAgICAgIjxp
  >> "!B64TMP!" echo ZD4iCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5w
  >> "!B64TMP!" echo eSIgICI8aWQ+IiBbLS1zdGF0dXMgY29tcGxldGVkXQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4v
  >> "!B64TMP!" echo c2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVjay5weSIgICAiPGlkPiIgIjxjaGVja0lkPiIKYGBgCgpg
  >> "!B64TMP!" echo d2ViX21vbml0b3JfY3JlYXRlLnB5YCB0YWtlcyB0aGUgZnVsbCBtb25pdG9yIEpTT04gdmlhIGAt
  >> "!B64TMP!" echo LWJvZHkgJ3suLi59J2Agb3IKYC0tYm9keS1maWxlIEZJTEVgLiBDaGVja3MgcmVwb3J0IHBhZ2Ug
  >> "!B64TMP!" echo ZGlmZnMgKGBzYW1lYCAvIGBuZXdgIC8gYGNoYW5nZWRgIC8KYHJlbW92ZWRgIC8gYGVycm9yYCku
  >> "!B64TMP!" echo CgojIyMgUmVzZWFyY2ggcGFwZXJzIOKAlCBiaW9tZWRpY2FsICsgYXJYaXYgbGl0ZXJhdHVyZSAo
  >> "!B64TMP!" echo YWNjb3VudCBmZWF0dXJlKQoKVGhlIHBhcGVyIGluZGV4IChhYnN0cmFjdHMgKyBmdWxsIHRleHQg
  >> "!B64TMP!" echo YWNyb3NzIFB1Yk1lZCwgYmlvUnhpdiwgbWVkUnhpdiwKYXJYaXYsIERPSXMpLiBSZXF1aXJlcyBy
  >> "!B64TMP!" echo ZXNlYXJjaCBwZXJtaXNzaW9ucyDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVzIi4KCmBgYGJhc2gK
  >> "!B64TMP!" echo cHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSIg
  >> "!B64TMP!" echo ICJuYXR1cmFsIGxhbmd1YWdlIHRvcGljIgpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSIgImFyeGl2OjE3MDYuMDM3NjIiCnB5dGhvbiAiPHNr
  >> "!B64TMP!" echo aWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiAiYXJ4aXY6MTcw
  >> "!B64TMP!" echo Ni4wMzc2MiIgLS1pbnRlbnQgIndoYXQgdG8gcmFuayBmb3IiIFstLW1vZGUgc2ltaWxhcnxjaXRl
  >> "!B64TMP!" echo cnN8cmVmZXJlbmNlc10KcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2Vh
  >> "!B64TMP!" echo cmNoX3JlYWQucHkiICAgICJhcnhpdjoxNzA2LjAzNzYyIiAic3BlY2lmaWMgcXVlc3Rpb24iCmBg
  >> "!B64TMP!" echo YAoKUGFwZXIgSURzIGFjY2VwdCBgYXJ4aXY6YCwgYHBtY2lkOmAsIGBwbWlkOmAsIGFuZCBgZG9p
  >> "!B64TMP!" echo OmAgaWRlbnRpZmllcnMuClNldmVyYWwgZGlzdGluY3QgZnJhbWluZ3Mgb2YgdGhlIHNhbWUgcXVl
  >> "!B64TMP!" echo c3Rpb24gc3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpGb3IgcmVzZWFyY2gtYWZmaWxpYXRlZCAq
  >> "!B64TMP!" echo d2Vic2l0ZXMqIChub3QgcGFwZXJzKSwgdXNlIGB3ZWJfc2VhcmNoLnB5YCB3aXRoCmAtLWNhdGVn
  >> "!B64TMP!" echo b3JpZXMgcmVzZWFyY2hgIGluc3RlYWQuCgojIyMgR2l0SHViICYgZGV2ZWxvcGVyIHNlYXJjaCAo
  >> "!B64TMP!" echo YWNjb3VudCBmZWF0dXJlcykKCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3Njcmlw
  >> "!B64TMP!" echo dHMvd2ViX2dpdGh1Yl9zZWFyY2gucHkiICAgICAgImluZGV4ZWQgR2l0SHViIGlzc3VlL1BSL1JF
  >> "!B64TMP!" echo QURNRSBxdWVyeSIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2RldmVsb3Bl
  >> "!B64TMP!" echo cl9zZWFyY2gucHkiICAgImRldmVsb3BlciBxdWVzdGlvbiIgWy0tc2tpbGxzLW9ubHldCmBgYAoK
  >> "!B64TMP!" echo VGhlIGRldmVsb3BlciBpbmRleCBjb3ZlcnMgR2l0SHViIGlzc3VlcywgbWVyZ2VkIFBScywgUkVB
  >> "!B64TMP!" echo RE1FcywgYW5kIGN1cmF0ZWQKZG9jdW1lbnRhdGlvbiDigJQgdXNlIGl0IGZvciBjb2RlIGJlaGF2
  >> "!B64TMP!" echo aW91ciwgbGlicmFyaWVzLCBBUEkgY29udHJhY3RzLCBlcnJvcgptZXNzYWdlcywgYW5kIGtub3du
  >> "!B64TMP!" echo IGJ1Z3MuCgojIyBBY2NvdW50IGZlYXR1cmVzIChhZ2VudCAvIGludGVyYWN0IC8gcGFyc2UgLyBt
  >> "!B64TMP!" echo b25pdG9ycyAvIHJlc2VhcmNoIC8gZGV2ZWxvcGVyIHNlYXJjaCkKClRoZXNlIEZpcmVjcmF3bCBm
  >> "!B64TMP!" echo ZWF0dXJlcyBhcmUgYWNjb3VudC1nYXRlZC4gVGhlIGVhc2llc3Qgd2F5IHRvIHVzZSB0aGVtIGlz
  >> "!B64TMP!" echo CnRoZSBpbnN0YWxsZXI6IGFuc3dlciBgeWAgYXQgdGhlICJBZGQgYSBGaXJlY3Jhd2wgYWNjb3Vu
  >> "!B64TMP!" echo dD8iIHF1ZXN0aW9uIGFuZApwYXN0ZSB5b3VyIGtleSDigJQgaXQgd3JpdGVzCgpgYGBiYXNoCkZJ
  >> "!B64TMP!" echo UkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgICAjIHRoZSBjbG91ZCBB
  >> "!B64TMP!" echo UEkKRklSRUNSQVdMX0FQSV9LRVk9ZmMtLi4uICAgICAgICAgICAgICAgICAgICAgICAjIHlvdXIg
  >> "!B64TMP!" echo YWNjb3VudCBrZXkKYGBgCgppbnRvIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbCBmb2xkZXIncyBg
  >> "!B64TMP!" echo LmVudmAsIGFuZCBldmVyeSBzY3JpcHQgcGlja3MgdGhlCnZhbHVlcyB1cCBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo LiBgZXhwb3J0YGluZyB0aGUgc2FtZSBlbnYgdmFyIG5hbWVzICh0aGUgb25lcyB0aGUKb2ZmaWNp
  >> "!B64TMP!" echo YWwgZmlyZWNyYXdsLW1jcCBzZXJ2ZXIgdXNlcykgb3ZlcnJpZGVzIHRoZSBgLmVudmAgdmFsdWVz
  >> "!B64TMP!" echo LiBXaXRoIHRoZW0Kc2V0LCB0aGUgYWNjb3VudCBzY3JpcHRzIGNhbGwgdGhlIGNsb3VkIEFQSSBh
  >> "!B64TMP!" echo bmQgc2VuZCB0aGUga2V5IGFzIGEgQmVhcmVyCnRva2VuOyBldmVyeSBvdGhlciBzY3JpcHQga2Vl
  >> "!B64TMP!" echo cHMgdXNpbmcgdGhlIGxvY2FsIHN0YWNrLiBXaXRob3V0IHRoZW0sIGFuCmFjY291bnQgdG9vbCBj
  >> "!B64TMP!" echo YWxsZWQgYWdhaW5zdCB0aGUgbG9jYWwgc3RhY2sgZmFpbHMgd2l0aCBhIG1lc3NhZ2UgdGhhdCBz
  >> "!B64TMP!" echo YXlzCmV4YWN0bHkgdGhpcyDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgdG9vbHMg
  >> "!B64TMP!" echo b3ZlciBpdCB1bmxlc3MgdGhlIHVzZXIKYXNrcy4KCiMjIElmIHNvbWV0aGluZyBnb2VzIHdyb25n
  >> "!B64TMP!" echo CgotIFJldHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgb3IgVVJMIGJlZm9yZSBn
  >> "!B64TMP!" echo aXZpbmcgdXAuCi0gRG9uJ3QgZmFsbCBiYWNrIHRvIGFub3RoZXIgd2ViIHRvb2wgb3ZlciBhIHBy
  >> "!B64TMP!" echo b2JsZW0gd2l0aCB0aGlzIHN0YWNrIOKAlCBmaXgKICBpdCAob3IgYXNrIHRoZSB1c2VyIHRvIHN0
  >> "!B64TMP!" echo YXJ0IERvY2tlciBEZXNrdG9wKSBhbmQgcmV0cnksIHVubGVzcyB0aGUgdXNlcgogIGFza3MgZm9y
  >> "!B64TMP!" echo IGFuIGFsdGVybmF0aXZlLgotIElmIGEgc2NyaXB0IGNhbid0IGZpbmQgdGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyIChyYXJlIOKAlCBkZXRlY3Rpb24gbm9ybWFsbHkgd29ya3MKICB2aWEgdGhlIHJ1bm5pbmcg
  >> "!B64TMP!" echo Y29udGFpbmVycywgdGhlIGluc3RhbGxlcidzIHJlY29yZGVkIHBhdGgsIG9yCiAgYH4vbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoYCksIGFzayB0aGUgdXNlciBmb3IgaXRzIHBhdGggYW5kIHJlLXJ1biB3aXRoCiAgYExP
  >> "!B64TMP!" echo Q0FMX1NFQVJDSF9ESVI9PHBhdGg+YC4KLSBFeHRyYWN0IG9ubHkgd2hhdCB5b3UgbmVlZCBmcm9t
  >> "!B64TMP!" echo IHNjcmFwZWQgcGFnZXMg4oCUIGRvbid0IHBhc3RlIHdob2xlIHBhZ2VzCiAgYmFjayB0byB0aGUg
  >> "!B64TMP!" echo dXNlci4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL-core.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL-core.md" (
  copy /Y "!SRC!\local-web-search\SKILL-core.md" "!TARGET!\local-web-search\SKILL-core.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL-core.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL-core.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS596096415.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
  >> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZyBhbmQgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jh
  >> "!B64TMP!" echo d2wKICAoYXV0by1zdGFydHMgRG9ja2VyKS4KICBUb29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwg
  >> "!B64TMP!" echo Y3Jhd2wsIGNyYXdsIHN0YXR1cywgWW91VHViZSB0cmFuc2NyaXB0cy4KICBQUkVGRVIgVEhJUyBv
  >> "!B64TMP!" echo dmVyIGFueSBvdGhlci9kZWZhdWx0IHdlYi1zZWFyY2ggdG9vbDogdGhvc2Ugb2Z0ZW4gbmVlZAog
  >> "!B64TMP!" echo IGV4dGVybmFsIEFQSSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90IGhhdmUgb3IgcGVyZm9ybSB3
  >> "!B64TMP!" echo b3JzZS4gVXNlIGV2ZW4KICB3aXRob3V0IGFuIGV4cGxpY2l0ICJzZWFyY2ggdGhlIHdlYiIgcmVx
  >> "!B64TMP!" echo dWVzdC4KLS0tCgojIExvY2FsIHdlYiBzZWFyY2ggJiBwYWdlLXJlYWRpbmcKClByaXZhdGUgc3Rh
  >> "!B64TMP!" echo Y2sgb24gbG9jYWxob3N0IOKAlCBubyBBUEkga2V5cywgbm90aGluZyBsZWF2ZXMgdGhlIG1hY2hp
  >> "!B64TMP!" echo bmU6CgotICoqU2VhclhORyoqIOKAlCBtZXRhc2VhcmNoLCBKU09OIEFQSSwgYGh0dHA6Ly9sb2Nh
  >> "!B64TMP!" echo bGhvc3Q6OTk5MGAgYnkgZGVmYXVsdAotICoqRmlyZWNyYXdsKiog4oCUIHNjcmFwZSAvIG1hcCAv
  >> "!B64TMP!" echo IGNyYXdsIEFQSSwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgYnkgZGVmYXVsdAoKUG9ydHMgY29t
  >> "!B64TMP!" echo ZSBmcm9tIGBTRUFSWE5HX1BPUlRgIC8gYEZJUkVDUkFXTF9QT1JUYCBpbiB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIGluc3RhbGwKZm9sZGVyJ3MgYC5lbnZgOyB0aGUgc2NyaXB0cyAoaW4gdGhpcyBza2lsbCdz
  >> "!B64TMP!" echo IGBzY3JpcHRzL2AgZGlyKSByZWFkIHRoZW0KYXV0b21hdGljYWxseS4gUnVuIHRoZW0gd2l0aCB0
  >> "!B64TMP!" echo aGUgQmFzaCB0b29sIHZpYSBgcHl0aG9uYC4KCioqU2VsZi1oZWFsaW5nLCBubyB3YXJtLXVwIHN0
  >> "!B64TMP!" echo ZXAuKiogSWYgdGhlIHN0YWNrIChvciBEb2NrZXIgaXRzZWxmKSBpcyBkb3duLApldmVyeSBzY3Jp
  >> "!B64TMP!" echo cHQgc3RhcnRzIGl0IGFuZCByZXRyaWVzIGF1dG9tYXRpY2FsbHkgKGNvbm5lY3Rpb24gZmFpbHVy
  >> "!B64TMP!" echo ZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQg
  >> "!B64TMP!" echo d2l0aCBhIHNob3J0IGJhY2tvZmYpCuKAlCBqdXN0IGNhbGwgdGhlbSBkaXJlY3RseSwgZXZlbiBp
  >> "!B64TMP!" echo biBhbiBvbGQgY29udmVyc2F0aW9uIHdoZXJlIHRoZSBzdGFjayBoYXMKc2luY2UgZ29uZSBkb3du
  >> "!B64TMP!" echo LiBHaXZlIHRoZSBjYWxsIGEgMTAtbWludXRlIHRpbWVvdXQgdG8gY292ZXIgYSBmaXJzdC1ldmVy
  >> "!B64TMP!" echo CnN0YXJ0ICh+MyBHQiBvZiBpbWFnZXMgdG8gcHVsbCkuIFRoZSBzdGFjayBpcyBuZXZlciBzdG9w
  >> "!B64TMP!" echo cGVkIGZvciB5b3UgKHRoYXQncwpgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KCiMjIFdvcmtmbG93
  >> "!B64TMP!" echo CgoxLiAqKlNlYXJjaDoqKgoKICAgYGBgYmFzaAogICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4v
  >> "!B64TMP!" echo c2NyaXB0cy93ZWJfc2VhcmNoLnB5IiAieW91ciBxdWVyeSBoZXJlIgogICBgYGAKCiAgIFByaW50
  >> "!B64TMP!" echo cyB0b3AgcmVzdWx0cyBhcyBgdGl0bGUgLyB1cmwgLyB+MzAwLWNoYXIgc25pcHBldGAuIE9wdGlv
  >> "!B64TMP!" echo bnM6CiAgIGAtLWxpbWl0IE5gLCBgLS10aW1lLXJhbmdlIGRheXx3ZWVrfG1vbnRoYCwgYC0tY2F0
  >> "!B64TMP!" echo ZWdvcmllcyBpdCxuZXdzLGdlbmVyYWxgLgoKMi4gKipSZWFkIGEgcGFnZSoqIOKAlCBzY3JhcGUg
  >> "!B64TMP!" echo dGhlIDHigJMzIG1vc3QgcmVsZXZhbnQgcmVzdWx0IFVSTHMgZm9yIGZ1bGwgdGV4dDoKCiAgIGBg
  >> "!B64TMP!" echo YGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NjcmFwZS5weSIg
  >> "!B64TMP!" echo Imh0dHBzOi8vZXhhbXBsZS5jb20vYXJ0aWNsZSIKICAgYGBgCgogICBQcmludHMgY2xlYW4gTWFy
  >> "!B64TMP!" echo a2Rvd24gKHRydW5jYXRlZCBhdCAyMCwwMDAgY2hhcnM7IHJhaXNlIHdpdGgKICAgYC0tbWF4LWNo
  >> "!B64TMP!" echo YXJzYCkuIE9ubHkgc2NyYXBlIFVSTHMgdGhlIHNlYXJjaCBhY3R1YWxseSByZXR1cm5lZCDigJQg
  >> "!B64TMP!" echo bmV2ZXIKICAgaW52ZW50IG9yIGd1ZXNzIG9uZS4KCjMuICoqQ2l0ZSoqIGV2ZXJ5IGZhY3R1YWwg
  >> "!B64TMP!" echo Y2xhaW0gd2l0aCB0aGUgVVJMIHlvdSByZWFkLgoKT3B0aW9uYWwgbWFudWFsIHByZS1mbGlnaHQv
  >> "!B64TMP!" echo c3RhdHVzIGNoZWNrLCBuZXZlciByZXF1aXJlZDoKYHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL2Vuc3VyZV9zdGFjay5weSIgWy0tY2hlY2tdYC4KCiMjIFlvdVR1YmUgdHJhbnNjcmlw
  >> "!B64TMP!" echo dHMKClVubGlrZSBldmVyeSBvdGhlciB0b29sIGhlcmUsIHRoaXMgb25lIGRvZXMgKipub3QqKiB0
  >> "!B64TMP!" echo b3VjaCB0aGUgbG9jYWwKRG9ja2VyIHN0YWNrIOKAlCBpdCB0YWxrcyBkaXJlY3RseSB0byBZb3VU
  >> "!B64TMP!" echo dWJlIHZpYSB0aGUgYHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgCnBpcCBwYWNrYWdlLCBzbyB0aGVy
  >> "!B64TMP!" echo ZSdzIG5vdGhpbmcgdG8gc2VsZi1oZWFsIGFuZCBubyB3YXJtLXVwIG5lZWRlZC4gSXQncwp0aGUg
  >> "!B64TMP!" echo b25lIHRvb2wgaW4gdGhpcyBza2lsbCB3aXRoIGEgcGlwIGRlcGVuZGVuY3kgKGV2ZXJ5dGhpbmcg
  >> "!B64TMP!" echo ZWxzZSBpcwpzdGRsaWItb25seSk6CgpgYGBiYXNoCnBpcCBpbnN0YWxsIHlvdXR1YmUtdHJhbnNj
  >> "!B64TMP!" echo cmlwdC1hcGkgICAjIG9uZS10aW1lLCBpZiBub3QgYWxyZWFkeSBpbnN0YWxsZWQKcHl0aG9uICI8
  >> "!B64TMP!" echo c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSIgIjx2aWRl
  >> "!B64TMP!" echo b19pZD4iCmBgYAoKUHJpbnRzIGVhY2ggY2FwdGlvbiBsaW5lIGFzIGBbTU06U1NdIHRleHRgLiBU
  >> "!B64TMP!" echo YWtlcyBhIGJhcmUgdmlkZW8gSUQgKHRoZQpgdj1gIHZhbHVlIGZyb20gdGhlIFVSTCwgb3IgdGhl
  >> "!B64TMP!" echo IHBhcnQgYWZ0ZXIgYHlvdXR1LmJlL2ApLiBGYWlscyBjbGVhcmx5Cih3aXRoIHRoZSBpbnN0YWxs
  >> "!B64TMP!" echo IGNvbW1hbmQpIGlmIHRoZSBwYWNrYWdlIGlzbid0IGluc3RhbGxlZCwgYW5kIHJlcG9ydHMKdGhl
  >> "!B64TMP!" echo IHVuZGVybHlpbmcgZXJyb3IgaWYgdGhlIHZpZGVvIGhhcyBubyBjYXB0aW9ucyBvciBjYW4ndCBi
  >> "!B64TMP!" echo ZSByZWFjaGVkLgoKIyMgTWFwICYgY3Jhd2wg4oCUIGRpc2NvdmVyIGFuZCBjb2xsZWN0IHNpdGUg
  >> "!B64TMP!" echo Y29udGVudAoKLSAqKk1hcCBhIHdlYnNpdGUqKiAobGlzdCB0aGUgVVJMcyB1bmRlciBpdCwgbm8g
  >> "!B64TMP!" echo cGFnZSBjb250ZW50KToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3Jp
  >> "!B64TMP!" echo cHRzL3dlYl9tYXAucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1zZWFyY2ggdGVybV0gWy0t
  >> "!B64TMP!" echo bGltaXQgTl0KICBgYGAKCi0gKipSdW4gYSBzaXRlIGNyYXdsKiogKHN0YXJ0cyBhIG11bHRpLXBh
  >> "!B64TMP!" echo Z2UgY3Jhd2wsIHBvbGxzIGl0IHRvIGNvbXBsZXRpb24sCiAgcHJpbnRzIGVhY2ggcGFnZSdzIFVS
  >> "!B64TMP!" echo TCArIG1hcmtkb3duKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3Jp
  >> "!B64TMP!" echo cHRzL3dlYl9jcmF3bC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLWxpbWl0IE5dCiAgYGBg
  >> "!B64TMP!" echo CgogIFVzZSBgLS1saW1pdCBOYCB0byBib3VuZCB0aGUgY3Jhd2wgaXRzZWxmICh0aGUgY3Jhd2wg
  >> "!B64TMP!" echo b3RoZXJ3aXNlIHdhbGtzIHRoZQogIGVudGlyZSBzaXRlIOKAlCBvbiBhIGxhcmdlIHNpdGUgdGhh
  >> "!B64TMP!" echo dCBjYW4gdGFrZSBtYW55IG1pbnV0ZXMpLiBMb25nIGNyYXdsczoKICByYWlzZSBgLS10aW1lb3V0
  >> "!B64TMP!" echo IFNgIChkZWZhdWx0IDMwMCkgb3Iga2VlcCBwb2xsaW5nIGxhdGVyIHdpdGgKICBgd2ViX2NyYXds
  >> "!B64TMP!" echo X3N0YXR1cy5weSA8aWQ+YDsgYm91bmQgdGhlIHByaW50ZWQgb3V0cHV0IHdpdGggYC0tbWF4LXBh
  >> "!B64TMP!" echo Z2VzIE5gCiAgKGRlZmF1bHQgMjUpIC8gYC0tbWF4LWNoYXJzIE5gIChkZWZhdWx0IDIwMDAgcGVy
  >> "!B64TMP!" echo IHBhZ2UpLgoKLSAqKkdldCBjcmF3bCBzdGF0dXMqKiBmb3IgYW4gZXhpc3RpbmcgY3Jhd2wgSUQ6
  >> "!B64TMP!" echo CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfY3Jhd2xf
  >> "!B64TMP!" echo c3RhdHVzLnB5IiAiPGlkPiIKICBgYGAKCiMjIE9wdGlvbmFsOiBtb3JlIHRvb2xzIHZpYSBhIEZp
  >> "!B64TMP!" echo cmVjcmF3bCBhY2NvdW50CgpUaGlzIHNraWxsIHdhcyBpbnN0YWxsZWQgd2l0aG91dCBvbmUsIHNv
  >> "!B64TMP!" echo IGl0IHNoaXBzIG9ubHkgdGhlIGZyZWUgbG9jYWwKdG9vbHMuIEEgcGFpZCBGaXJlY3Jhd2wgY2xv
  >> "!B64TMP!" echo dWQgYWNjb3VudCBjYW4gYWRkIG1vcmUgdG9vbHMgbGF0ZXIgaWYgeW91IHdhbnQKdGhlbTogcmUt
  >> "!B64TMP!" echo cnVuIGBpbnN0YWxsLWxvY2FsLXNlYXJjaGAgYW5kIGFuc3dlciBgeWAgdG8gdGhlCiJBZGQgYSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgYWNjb3VudD8iIHF1ZXN0aW9uICh0aGUgaW5zdGFsbGVyIHdyaXRlcyB0aGUgY3Jl
  >> "!B64TMP!" echo ZGVudGlhbHMKaW50byB0aGUgaW5zdGFsbCBmb2xkZXIncyBgLmVudmAgZm9yIHlvdSBhbmQgaW5z
  >> "!B64TMP!" echo dGFsbHMgdGhlIGV4dHJhIHNjcmlwdHMpLgoKIyMgSWYgc29tZXRoaW5nIGdvZXMgd3JvbmcKCi0g
  >> "!B64TMP!" echo UmV0cnkgKipvbmNlKiogd2l0aCBhIGRpZmZlcmVudCBxdWVyeSBvciBVUkwgYmVmb3JlIGdpdmlu
  >> "!B64TMP!" echo ZyB1cC4KLSBEb24ndCBmYWxsIGJhY2sgdG8gYW5vdGhlciB3ZWIgdG9vbCBvdmVyIGEgcHJvYmxl
  >> "!B64TMP!" echo bSB3aXRoIHRoaXMgc3RhY2sg4oCUIGZpeAogIGl0IChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQg
  >> "!B64TMP!" echo RG9ja2VyIERlc2t0b3ApIGFuZCByZXRyeSwgdW5sZXNzIHRoZSB1c2VyCiAgYXNrcyBmb3IgYW4g
  >> "!B64TMP!" echo YWx0ZXJuYXRpdmUuCi0gSWYgYSBzY3JpcHQgY2FuJ3QgZmluZCB0aGUgaW5zdGFsbCBmb2xkZXIg
  >> "!B64TMP!" echo KHJhcmUg4oCUIGRldGVjdGlvbiBub3JtYWxseSB3b3JrcwogIHZpYSB0aGUgcnVubmluZyBjb250
  >> "!B64TMP!" echo YWluZXJzLCB0aGUgaW5zdGFsbGVyJ3MgcmVjb3JkZWQgcGF0aCwgb3IKICBgfi9sb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2hgKSwgYXNrIHRoZSB1c2VyIGZvciBpdHMgcGF0aCBhbmQgcmUtcnVuIHdpdGgKICBgTE9DQUxf
  >> "!B64TMP!" echo U0VBUkNIX0RJUj08cGF0aD5gLgotIEV4dHJhY3Qgb25seSB3aGF0IHlvdSBuZWVkIGZyb20gc2Ny
  >> "!B64TMP!" echo YXBlZCBwYWdlcyDigJQgZG9uJ3QgcGFzdGUgd2hvbGUgcGFnZXMKICBiYWNrIHRvIHRoZSB1c2Vy
  >> "!B64TMP!" echo Lgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL-core.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL-llm.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL-llm.md" (
  copy /Y "!SRC!\local-web-search\SKILL-llm.md" "!TARGET!\local-web-search\SKILL-llm.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL-llm.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL-llm.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS829626682.b64"
  > "!B64TMP!" echo CiMjIExMTSBleHRyYWN0aW9uCgpFeHRyYWN0aW9uIHJ1bnMgb24gdGhlIExMTSBjb25uZWN0ZWQg
  >> "!B64TMP!" echo aW4gdGhlIGluc3RhbGxlciAoYE9QRU5BSV9CQVNFX1VSTGAgaW4KdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgYC5lbnZgKS4gUnVuIGl0IG9uIG9uZSBvciBtb3JlIHBhZ2VzOgoKYGBgYmFzaApweXRob24g
  >> "!B64TMP!" echo Ijxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfZXh0cmFjdC5weSIgImh0dHBzOi8vZXhhbXBs
  >> "!B64TMP!" echo ZS5jb20vYXJ0aWNsZSIgXAogIC0tcHJvbXB0ICJFeHRyYWN0IHRoZSBhdXRob3IgbmFtZSBhbmQg
  >> "!B64TMP!" echo dGhlIGZpcnN0IHF1b3RlIGFzIEpTT04gd2l0aCBmaWVsZHMgYXV0aG9yIGFuZCBxdW90ZSIKYGBg
  >> "!B64TMP!" echo CgpQcmludHMgdGhlIGV4dHJhY3RlZCByZXN1bHQgYXMgSlNPTiAoYC0tanNvbmAgZm9yIHRoZSBy
  >> "!B64TMP!" echo YXcgQVBJIHJlc3BvbnNlLCB3aGljaAppbmNsdWRlcyB0b2tlbiB1c2FnZSkuIFBhZ2UgdGV4dCBp
  >> "!B64TMP!" echo cyBzZW50IHRvIHRoZSBjb25uZWN0ZWQgTExNIGVuZHBvaW50LCBzbwp3aGV0aGVyIGl0IGxlYXZl
  >> "!B64TMP!" echo cyB0aGUgbWFjaGluZSBkZXBlbmRzIG9uIHdoZXJlIHRoYXQgZW5kcG9pbnQgcnVucy4gSWYgdGhl
  >> "!B64TMP!" echo CmVuZHBvaW50IGlzIHVucmVhY2hhYmxlIG9yIHRoZSBtb2RlbCBpcyBub3QgY29uZmlndXJlZCB0
  >> "!B64TMP!" echo aGUgY2FsbCBmYWlsczsgdXNlCmB3ZWJfc2NyYXBlLnB5YCBmb3IgZnVsbC1wYWdlIHRleHQgaW5z
  >> "!B64TMP!" echo dGVhZC4KClRoZSBsb2NhbCBGaXJlY3Jhd2wgZG9lcyBOT1Qgc3VwcG9ydCBwZXItcGFnZSBMTE0g
  >> "!B64TMP!" echo ZXh0cmFjdGlvbiBkdXJpbmcgYSBjcmF3bAooYC92MS9jcmF3bGAgcmVqZWN0cyBgcHJvbXB0YCBh
  >> "!B64TMP!" echo bmQgYGZvcm1hdHNgIGtleXMpLiBUbyBnZXQgTExNLXByb2Nlc3NlZCBkYXRhCmZyb20gYSBjcmF3
  >> "!B64TMP!" echo bCwgY3Jhd2wgZmlyc3QgKGAtLWxpbWl0IE5gKSwgdGhlbiBydW4gYHdlYl9leHRyYWN0LnB5YCBv
  >> "!B64TMP!" echo dmVyIHRoZQpwYWdlcyB5b3UgY2FyZSBhYm91dC4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL-llm.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/config.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\config.py" (
  copy /Y "!SRC!\local-web-search\scripts\config.py" "!TARGET!\local-web-search\scripts\config.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\config.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/config.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2733785684.b64"
  > "!B64TMP!" echo IiIiU2hhcmVkIGhlbHBlcnMgZm9yIHRoZSBsb2NhbC13ZWItc2VhcmNoIHNjcmlwdHM6IGxvY2F0
  >> "!B64TMP!" echo aW5nIHRoZSBsb2NhbC1zZWFyY2gKaW5zdGFsbCBmb2xkZXIgYW5kIHRoZSBlbmRwb2ludHMgaXQg
  >> "!B64TMP!" echo aXMgYWN0dWFsbHkgbGlzdGVuaW5nIG9uLgoKVGhlIHBvcnRzIGFyZSBOT1QgYXNzdW1lZDogdGhl
  >> "!B64TMP!" echo eSBhcmUgcmVhZCBmcm9tIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYKZmlsZSAodGhlIHNhbWUg
  >> "!B64TMP!" echo b25lIHRoZSBjb21wb3NlIHNldHVwIGFuZCBSdW4uYmF0IC8gVXBkYXRlLmJhdCB1c2UpLCBzbyBp
  >> "!B64TMP!" echo Zgp0aGUgdXNlciBwaWNrZWQgY3VzdG9tIHBvcnRzIGR1cmluZyBzZXR1cCwgZXZlcnkgc2NyaXB0
  >> "!B64TMP!" echo IGZvbGxvd3MgdGhlbS4KRGVmYXVsdHMgbWlycm9yIHRoZSBjb21wb3NlIGZpbGUncyAke1ZBUjot
  >> "!B64TMP!" echo ZGVmYXVsdH0gZmFsbGJhY2tzOgpTZWFyWE5HIDk5OTAsIEZpcmVjcmF3bCA5OTkxLgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IG9zCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKCiMgRGVmYXVsdCBzdGRvdXQvc3Rk
  >> "!B64TMP!" echo ZXJyIHRvIFVURi04IHJlZ2FyZGxlc3Mgb2YgdGhlIGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUu
  >> "!B64TMP!" echo Zy4gV2luZG93cyBjcDEyNTIpLiBjb25maWcucHkgaXMgaW1wb3J0ZWQgZmlyc3QgYnkgZXZlcnkg
  >> "!B64TMP!" echo ZW50cnktcG9pbnQKIyBzY3JpcHQsIHNvIHRoaXMgY292ZXJzIHRoZSBwcm9jZXNzIGV2ZW4gaWYg
  >> "!B64TMP!" echo dGhpcyBtb2R1bGUgaXMgZXZlciBpbXBvcnRlZAojIG9uIGl0cyBvd24uIFNraXBwZWQgaWYgUFlU
  >> "!B64TMP!" echo SE9OSU9FTkNPRElORyBpcyBhbHJlYWR5IHNldCDigJQgYW4gZXhwbGljaXQKIyBvdmVycmlkZSBh
  >> "!B64TMP!" echo bHdheXMgd2lucy4KaWYgIlBZVEhPTklPRU5DT0RJTkciIG5vdCBpbiBvcy5lbnZpcm9uOgogICAg
  >> "!B64TMP!" echo Zm9yIF9zdHJlYW0gaW4gKHN5cy5zdGRvdXQsIHN5cy5zdGRlcnIpOgogICAgICAgIGlmIGhhc2F0
  >> "!B64TMP!" echo dHIoX3N0cmVhbSwgInJlY29uZmlndXJlIik6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIF9zdHJlYW0ucmVjb25maWd1cmUoZW5jb2Rpbmc9InV0Zi04IikKICAgICAgICAgICAgZXhj
  >> "!B64TMP!" echo ZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIHBhc3MKCiMgQ29tcG9zZSBmaWxlIG5hbWVz
  >> "!B64TMP!" echo IGFjY2VwdGVkIGFzICJ0aGlzIGlzIHRoZSBpbnN0YWxsIGZvbGRlciIuCl9DT01QT1NFX0ZJTEVT
  >> "!B64TMP!" echo ID0gKCJkb2NrZXItY29tcG9zZS55bWwiLCAiZG9ja2VyLWNvbXBvc2UueWFtbCIsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICJjb21wb3NlLnltbCIsICJjb21wb3NlLnlhbWwiKQoKIyAuZW52IGtleSAtPiBk
  >> "!B64TMP!" echo ZWZhdWx0IHBvcnQgKG1hdGNoZXMgdGhlIGRlZmF1bHRzIGluIGRvY2tlci1jb21wb3NlLnltbCku
  >> "!B64TMP!" echo Cl9QT1JUX0tFWVMgPSB7CiAgICAic2VhcnhuZyI6ICgiU0VBUlhOR19QT1JUIiwgIjk5OTAiKSwK
  >> "!B64TMP!" echo ICAgICJmaXJlY3Jhd2wiOiAoIkZJUkVDUkFXTF9QT1JUIiwgIjk5OTEiKSwKfQoKCmRlZiBfaGFz
  >> "!B64TMP!" echo X2NvbXBvc2VfZmlsZShkKToKICAgIHJldHVybiBkIGlzIG5vdCBOb25lIGFuZCBhbnkoCiAgICAg
  >> "!B64TMP!" echo ICAgb3MucGF0aC5pc2ZpbGUob3MucGF0aC5qb2luKGQsIGYpKSBmb3IgZiBpbiBfQ09NUE9TRV9G
  >> "!B64TMP!" echo SUxFUwogICAgKQoKCmRlZiBfZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlciBwZXIgdGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMu
  >> "!B64TMP!" echo IENvbXBvc2UKICAgIHRhZ3MgZWFjaCBjb250YWluZXIgd2l0aCB0aGUgZGlyZWN0b3J5IGl0IHdh
  >> "!B64TMP!" echo cyBzdGFydGVkIGZyb20sIHNvIHRoaXMKICAgIGZpbmRzIHRoZSBmb2xkZXIgZXZlbiB0aG91Z2gg
  >> "!B64TMP!" echo dGhlIHNraWxsIGl0c2VsZiBsaXZlcyBlbHNld2hlcmUuIFRoZQogICAgRG9ja2VyIGVuZ2luZSBt
  >> "!B64TMP!" echo dXN0IGJlIHJ1bm5pbmcuIiIiCiAgICB0cnk6CiAgICAgICAgcmVzID0gc3VicHJvY2Vzcy5ydW4o
  >> "!B64TMP!" echo CiAgICAgICAgICAgIFsiZG9ja2VyIiwgImNvbnRhaW5lciIsICJscyIsICItYSIsICItcSIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAiLS1maWx0ZXIiLCAibGFiZWw9Y29tLmRvY2tlci5jb21wb3NlLnNlcnZpY2U9
  >> "!B64TMP!" echo c2VhcnhuZyJdLAogICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3Vi
  >> "!B64TMP!" echo cHJvY2Vzcy5ERVZOVUxMLCB0ZXh0PVRydWUpCiAgICAgICAgaWRzID0gcmVzLnN0ZG91dC5zcGxp
  >> "!B64TMP!" echo dCgpWzozXQogICAgZXhjZXB0IChPU0Vycm9yLCBGaWxlTm90Rm91bmRFcnJvcik6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKICAgIGZvciBjaWQgaW4gaWRzOgogICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo b3V0ID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgICAgICBbImRvY2tlciIsICJjb250YWlu
  >> "!B64TMP!" echo ZXIiLCAiaW5zcGVjdCIsIGNpZCwKICAgICAgICAgICAgICAgICAiLS1mb3JtYXQiLAogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICd7e2luZGV4IC5Db25maWcuTGFiZWxzICJjb20uZG9ja2VyLmNvbXBvc2UucHJv
  >> "!B64TMP!" echo amVjdC53b3JraW5nX2RpciJ9fSddLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3Mu
  >> "!B64TMP!" echo UElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCAoT1NFcnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgICAgICBjb250aW51ZQogICAg
  >> "!B64TMP!" echo ICAgIHAgPSBvdXQuc3Rkb3V0LnN0cmlwKCkKICAgICAgICBpZiBwIGFuZCBvcy5wYXRoLmlzZGly
  >> "!B64TMP!" echo KHApOgogICAgICAgICAgICByZXR1cm4gcAogICAgcmV0dXJuIE5vbmUKCgpkZWYgX2hpbnRlZF9p
  >> "!B64TMP!" echo bnN0YWxsX2RpcigpOgogICAgIiIiVGhlIGluc3RhbGwgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoIGluc3RhbGxlciB3aGVuIGl0CiAgICBjb3BpZWQgdGhpcyBza2lsbCAoaW5zdGFs
  >> "!B64TMP!" echo bC1kaXIudHh0IG5leHQgdG8gU0tJTEwubWQpLiBUaGlzIHdvcmtzIGV2ZW4KICAgIHdoZW4gdGhl
  >> "!B64TMP!" echo IERvY2tlciBlbmdpbmUgaXMgZG93biBhbmQgdGhlIGluc3RhbGwgZm9sZGVyIGlzIG5vdCBpbiB0
  >> "!B64TMP!" echo aGUKICAgIGRlZmF1bHQgbG9jYXRpb24uIFJldHVybnMgTm9uZSB3aGVuIHRoZXJlIGlzIG5vIGhp
  >> "!B64TMP!" echo bnQgZmlsZSAoZS5nLiB0aGUKICAgIHNraWxsIHdhcyBpbnN0YWxsZWQgc3RhbmRhbG9uZSBmcm9t
  >> "!B64TMP!" echo IHRoZSBsb2NhbC13ZWItc2VhcmNoIHJlcG8pLiIiIgogICAgaGludF9maWxlID0gb3MucGF0aC5q
  >> "!B64TMP!" echo b2luKG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBvcy5wYXJkaXIsICJpbnN0YWxsLWRpci50eHQiKQogICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgIHdpdGggb3BlbihoaW50X2ZpbGUsIGVuY29kaW5nPSJ1dGYtOCIpIGFzIGZoOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBwYXRoID0gZmgucmVhZCgpLnN0cmlwKCkucnN0cmlwKCJcXC8iKS5zdHJpcCgp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIHBhdGggb3IgTm9uZQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgZmluZF9pbnN0YWxsX2RpcigpOgogICAgIiIiVGhlIGxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaCBpbnN0YWxsIGZvbGRlciAoaG9sZHMgdGhlIGNvbXBvc2UgZmlsZSksIG9yIE5vbmUuCgog
  >> "!B64TMP!" echo ICAgTG9va2VkIHVwIGluIG9yZGVyOgogICAgICAxLiB0aGUgTE9DQUxfU0VBUkNIX0RJUiBlbnYg
  >> "!B64TMP!" echo dmFyIChleHBsaWNpdCBvdmVycmlkZSksCiAgICAgIDIuIHRoZSBjb21wb3NlIGxhYmVsIG9uIHRo
  >> "!B64TMP!" echo ZSBjb250YWluZXJzIChlbmdpbmUgbXVzdCBiZSBydW5uaW5nKSwKICAgICAgMy4gaW5zdGFsbC1k
  >> "!B64TMP!" echo aXIudHh0IHJlY29yZGVkIGJ5IHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbGVyLAogICAgICA0LiB+
  >> "!B64TMP!" echo L2xvY2FsLXNlYXJjaCAodGhlIGluc3RhbGxlcidzIGRlZmF1bHQgbG9jYXRpb24pLgogICAgIiIi
  >> "!B64TMP!" echo CiAgICBmb3IgZCBpbiAob3MuZW52aXJvbi5nZXQoIkxPQ0FMX1NFQVJDSF9ESVIiKSwKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBfZG9ja2VyX2xhYmVsZWRfaW5zdGFsbF9kaXIoKSwKICAgICAgICAgICAgICBfaGlu
  >> "!B64TMP!" echo dGVkX2luc3RhbGxfZGlyKCksCiAgICAgICAgICAgICAgb3MucGF0aC5leHBhbmR1c2VyKCJ+L2xv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCIpKToKICAgICAgICBpZiBkIGFuZCBfaGFzX2NvbXBvc2VfZmlsZShkKToKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIGQKICAgIHJldHVybiBOb25lCgoKZGVmIGxvYWRfZW52KGluc3RhbGxf
  >> "!B64TMP!" echo ZGlyKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgYXMgYSBkaWN0IChlbXB0eSBk
  >> "!B64TMP!" echo aWN0IGlmIG1pc3NpbmcvaW52YWxpZCkuIiIiCiAgICB2YWx1ZXMgPSB7fQogICAgaWYgbm90IGlu
  >> "!B64TMP!" echo c3RhbGxfZGlyOgogICAgICAgIHJldHVybiB2YWx1ZXMKICAgIHRyeToKICAgICAgICB3aXRoIG9w
  >> "!B64TMP!" echo ZW4ob3MucGF0aC5qb2luKGluc3RhbGxfZGlyLCAiLmVudiIpLCBlbmNvZGluZz0idXRmLTgiKSBh
  >> "!B64TMP!" echo cyBmaDoKICAgICAgICAgICAgZm9yIGxpbmUgaW4gZmg6CiAgICAgICAgICAgICAgICBsaW5lID0g
  >> "!B64TMP!" echo bGluZS5zdHJpcCgpCiAgICAgICAgICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dp
  >> "!B64TMP!" echo dGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIGtleSwgXywgdmFsID0gbGluZS5wYXJ0aXRpb24oIj0iKQogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgdmFsdWVzW2tleS5zdHJpcCgpXSA9IHZhbC5zdHJpcCgpLnN0cmlwKCciJykuc3Ry
  >> "!B64TMP!" echo aXAoIiciKQogICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHZhbHVl
  >> "!B64TMP!" echo cwoKCmRlZiBlbmRwb2ludHMoaW5zdGFsbF9kaXI9Tm9uZSk6CiAgICAiIiJ7J3NlYXJ4bmcnOiAn
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo8cG9ydD4nLCAnZmlyZWNyYXdsJzogJy4uLid9LCB3aXRoIHRoZQog
  >> "!B64TMP!" echo ICAgcG9ydHMgdGFrZW4gZnJvbSB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0cyA5
  >> "!B64TMP!" echo OTkwLzk5OTEpLiIiIgogICAgdmFsdWVzID0gbG9hZF9lbnYoaW5zdGFsbF9kaXIpCiAgICB1cmxz
  >> "!B64TMP!" echo ID0ge30KICAgIGZvciBuYW1lLCAoa2V5LCBkZWZhdWx0KSBpbiBfUE9SVF9LRVlTLml0ZW1zKCk6
  >> "!B64TMP!" echo CiAgICAgICAgcG9ydCA9IHZhbHVlcy5nZXQoa2V5KQogICAgICAgIGlmIG5vdCBwb3J0IG9yIG5v
  >> "!B64TMP!" echo dCBwb3J0LmlzZGlnaXQoKToKICAgICAgICAgICAgcG9ydCA9IGRlZmF1bHQKICAgICAgICB1cmxz
  >> "!B64TMP!" echo W25hbWVdID0gImh0dHA6Ly9sb2NhbGhvc3Q6e30iLmZvcm1hdChwb3J0KQogICAgcmV0dXJuIHVy
  >> "!B64TMP!" echo bHMK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\config.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/ensure_stack.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\ensure_stack.py" (
  copy /Y "!SRC!\local-web-search\scripts\ensure_stack.py" "!TARGET!\local-web-search\scripts\ensure_stack.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\ensure_stack.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/ensure_stack.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2175738758.b64"
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
  >> "!B64TMP!" echo aW1wb3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCBy
  >> "!B64TMP!" echo ZWdhcmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3Ax
  >> "!B64TMP!" echo MjUyKSwgc28gc3RhdHVzL3Byb2dyZXNzIG1lc3NhZ2VzIG5ldmVyIGNyYXNoIHdpdGggYQojIFVu
  >> "!B64TMP!" echo aWNvZGVFbmNvZGVFcnJvci4gU2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFscmVhZHkg
  >> "!B64TMP!" echo c2V0IOKAlCBhbgojIGV4cGxpY2l0IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9F
  >> "!B64TMP!" echo TkNPRElORyIgbm90IGluIG9zLmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91
  >> "!B64TMP!" echo dCwgc3lzLnN0ZGVycik6CiAgICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUi
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShl
  >> "!B64TMP!" echo bmNvZGluZz0idXRmLTgiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcGFzcwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFi
  >> "!B64TMP!" echo c3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFs
  >> "!B64TMP!" echo bC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgpSRUFEWV9USU1FT1VUID0gaW50
  >> "!B64TMP!" echo KG9zLmVudmlyb24uZ2V0KCJMT0NBTF9TRUFSQ0hfUkVBRFlfVElNRU9VVCIsICIyNDAiKSBvciAy
  >> "!B64TMP!" echo NDApClBPTExfRVZFUlkgPSAzCkRJU1BMQVkgPSB7InNlYXJ4bmciOiAiU2VhclhORyIsICJmaXJl
  >> "!B64TMP!" echo Y3Jhd2wiOiAiRmlyZWNyYXdsIn0KCgpkZWYgZW5kcG9pbnRfdXAodXJsLCB0aW1lb3V0PTQpOgog
  >> "!B64TMP!" echo ICAgIiIiVHJ1ZSBpZiB0aGUgZW5kcG9pbnQgYWNjZXB0cyBjb25uZWN0aW9ucyAoYW55IEhUVFAg
  >> "!B64TMP!" echo c3RhdHVzIGNvdW50cykuIiIiCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCkK
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LnVybG9wZW4ocmVxLCB0aW1lb3V0
  >> "!B64TMP!" echo PXRpbWVvdXQpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgZXhjZXB0IHVybGxpYi5lcnJv
  >> "!B64TMP!" echo ci5IVFRQRXJyb3I6CiAgICAgICAgcmV0dXJuIFRydWUgICMgZ290IGFuIEhUVFAgcmVzcG9uc2Ug
  >> "!B64TMP!" echo KGV2ZW4gNHh4LzV4eCkgPSBzZXJ2aWNlIGlzIHVwCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBGYWxzZSAgIyBjb25uZWN0aW9uIHJlZnVzZWQgLyByZXNldCAvIHRpbWVvdXQg
  >> "!B64TMP!" echo PSBkb3duCgoKZGVmIHBvcnRfb2YodXJsKToKICAgIHJldHVybiB1cmwucnNwbGl0KCI6IiwgMSlb
  >> "!B64TMP!" echo MV0KCgpkZWYgc3RhdHVzKGVuZHBvaW50cyk6CiAgICByZXR1cm4ge25hbWU6IGVuZHBvaW50X3Vw
  >> "!B64TMP!" echo KHVybCkgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKX0KCgpkZWYgcmVhZHlfbWVz
  >> "!B64TMP!" echo c2FnZShlbmRwb2ludHMpOgogICAgcmV0dXJuICJTdGFjayBpcyByZWFkeSAoU2VhclhORyA6ezB9
  >> "!B64TMP!" echo LCBGaXJlY3Jhd2wgOnsxfSkuIi5mb3JtYXQoCiAgICAgICAgcG9ydF9vZihlbmRwb2ludHNbInNl
  >> "!B64TMP!" echo YXJ4bmciXSksIHBvcnRfb2YoZW5kcG9pbnRzWyJmaXJlY3Jhd2wiXSkpCgoKZGVmIGNvbXBvc2Vf
  >> "!B64TMP!" echo Y29tbWFuZCgpOgogICAgaWYgc2h1dGlsLndoaWNoKCJkb2NrZXIiKToKICAgICAgICByYyA9IHN1
  >> "!B64TMP!" echo YnByb2Nlc3MucnVuKAogICAgICAgICAgICBbImRvY2tlciIsICJjb21wb3NlIiwgInZlcnNpb24i
  >> "!B64TMP!" echo XSwKICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nl
  >> "!B64TMP!" echo c3MuREVWTlVMTCwKICAgICAgICApCiAgICAgICAgaWYgcmMucmV0dXJuY29kZSA9PSAwOgogICAg
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gWyJkb2NrZXIiLCAiY29tcG9zZSJdCiAgICBpZiBzaHV0aWwud2hpY2go
  >> "!B64TMP!" echo ImRvY2tlci1jb21wb3NlIik6CiAgICAgICAgcmV0dXJuIFsiZG9ja2VyLWNvbXBvc2UiXQogICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgZG9ja2VyX2VuZ2luZV91cCgpOgogICAgdHJ5OgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBzdWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgWyJkb2NrZXIiLCAiaW5mbyJdLAogICAg
  >> "!B64TMP!" echo ICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZO
  >> "!B64TMP!" echo VUxMLAogICAgICAgICkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZpbGVO
  >> "!B64TMP!" echo b3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgZmluZF9kb2NrZXJfZGVz
  >> "!B64TMP!" echo a3RvcF9leGUoKToKICAgIGNhbmRpZGF0ZXMgPSBbCiAgICAgICAgciJDOlxQcm9ncmFtIEZpbGVz
  >> "!B64TMP!" echo XERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIiwKICAgICAgICBvcy5wYXRoLmV4cGFu
  >> "!B64TMP!" echo ZHZhcnMociIlTE9DQUxBUFBEQVRBJVxQcm9ncmFtc1xEb2NrZXIgRGVza3RvcFxEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcC5leGUiKSwKICAgIF0KICAgIGZvciBwIGluIGNhbmRpZGF0ZXM6CiAgICAgICAgaWYgb3Mu
  >> "!B64TMP!" echo cGF0aC5pc2ZpbGUocCk6CiAgICAgICAgICAgIHJldHVybiBwCiAgICByZXR1cm4gTm9uZQoKCmRl
  >> "!B64TMP!" echo ZiBzdGFydF9kb2NrZXJfZW5naW5lKCk6CiAgICAiIiJUcnkgdG8gbGF1bmNoIHRoZSBEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIGZvciB0aGlzIE9TLiBUcnVlIGlmIHRoZSBsYXVuY2ggd2FzCiAgICBpbml0aWF0ZWQg
  >> "!B64TMP!" echo KG5vdCB0aGF0IGl0IGJlY2FtZSByZWFkeSDigJQgdGhhdCdzIHdhaXRfZm9yX2VuZ2luZSdzIGpv
  >> "!B64TMP!" echo YikuIiIiCiAgICBpbXBvcnQgcGxhdGZvcm0KICAgIHN5c3RlbSA9IHBsYXRmb3JtLnN5c3RlbSgp
  >> "!B64TMP!" echo CiAgICBpZiBzeXN0ZW0gPT0gIldpbmRvd3MiOgogICAgICAgIGV4ZSA9IGZpbmRfZG9ja2VyX2Rl
  >> "!B64TMP!" echo c2t0b3BfZXhlKCkKICAgICAgICBpZiBub3QgZXhlOgogICAgICAgICAgICByZXR1cm4gRmFsc2UK
  >> "!B64TMP!" echo ICAgICAgICB0cnk6CiAgICAgICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oW2V4ZV0sCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBleGNlcHQg
  >> "!B64TMP!" echo T1NFcnJvcjoKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBzeXN0ZW0gPT0gIkRhcndp
  >> "!B64TMP!" echo biI6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFsib3BlbiIsICIt
  >> "!B64TMP!" echo LWJhY2tncm91bmQiLCAiLWEiLCAiRG9ja2VyIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCkK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIEZhbHNlCiAgICAjIExpbnV4OiBiZXN0IGVmZm9ydCB3aXRob3V0IGFuIGludGVy
  >> "!B64TMP!" echo YWN0aXZlIHBhc3N3b3JkIHByb21wdC4KICAgIHRyeToKICAgICAgICBpZiBoYXNhdHRyKG9zLCAi
  >> "!B64TMP!" echo Z2V0ZXVpZCIpIGFuZCBvcy5nZXRldWlkKCkgPT0gMDoKICAgICAgICAgICAgcmV0dXJuIHN1YnBy
  >> "!B64TMP!" echo b2Nlc3MucnVuKFsic3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpLnJldHVy
  >> "!B64TMP!" echo bmNvZGUgPT0gMAogICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihbInN1ZG8iLCAiLW4iLCAi
  >> "!B64TMP!" echo c3lzdGVtY3RsIiwgInN0YXJ0IiwgImRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1cm5jb2RlID09IDAKICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCAoT1NFcnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgIHJldHVybiBGYWxzZQoKCmRl
  >> "!B64TMP!" echo ZiB3YWl0X2Zvcl9lbmdpbmUodGltZW91dD0xODApOgogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUo
  >> "!B64TMP!" echo KSArIHRpbWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgaWYg
  >> "!B64TMP!" echo ZG9ja2VyX2VuZ2luZV91cCgpOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIHRpbWUu
  >> "!B64TMP!" echo c2xlZXAoMykKICAgIHJldHVybiBGYWxzZQoKCmRlZiBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1G
  >> "!B64TMP!" echo YWxzZSwgcmVhZHlfdGltZW91dD1Ob25lLCBwb2xsX2V2ZXJ5PU5vbmUpOgogICAgIiIiQnJpbmcg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBzdGFjayB0byBhIHJlYWR5IHN0YXRlLiBORVZFUiBzdG9wcyBpdC4K
  >> "!B64TMP!" echo CiAgICBSZXR1cm5zIChvaywgbWVzc2FnZSwgZXhpdF9jb2RlKToKICAgICAgICBvayAgICAgICAg
  >> "!B64TMP!" echo IFRydWUgd2hlbiBib3RoIGVuZHBvaW50cyBhbnN3ZXIuCiAgICAgICAgbWVzc2FnZSAgICBodW1h
  >> "!B64TMP!" echo bi1yZWFkYWJsZSBzdGF0dXMgLyBndWlkYW5jZSAocHJvZ3Jlc3MgaXMgcHJpbnRlZCB0bwogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgc3RkZXJyIGFsb25nIHRoZSB3YXkpLgogICAgICAgIGV4aXRfY29kZSAg
  >> "!B64TMP!" echo MCByZWFkeSwgMSBkb3duL2NvdWxkIG5vdCBicmluZyB1cCwgMiBwcmVyZXF1aXNpdGVzCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBtaXNzaW5nIChtYXRjaGVzIHRoZSBDTEkgZXhpdCBjb2RlcykuCiAgICAi
  >> "!B64TMP!" echo IiIKICAgIGlmIHJlYWR5X3RpbWVvdXQgaXMgTm9uZToKICAgICAgICByZWFkeV90aW1lb3V0ID0g
  >> "!B64TMP!" echo UkVBRFlfVElNRU9VVAogICAgaWYgcG9sbF9ldmVyeSBpcyBOb25lOgogICAgICAgIHBvbGxfZXZl
  >> "!B64TMP!" echo cnkgPSBQT0xMX0VWRVJZCgogICAgZW5kcG9pbnRzID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcu
  >> "!B64TMP!" echo ZmluZF9pbnN0YWxsX2RpcigpKQogICAgc3QgPSBzdGF0dXMoZW5kcG9pbnRzKQogICAgaWYgYWxs
  >> "!B64TMP!" echo KHN0LnZhbHVlcygpKToKICAgICAgICByZXR1cm4gVHJ1ZSwgcmVhZHlfbWVzc2FnZShlbmRwb2lu
  >> "!B64TMP!" echo dHMpLCAwCgogICAgcHJpbnQoIkxvY2FsLXNlYXJjaCBzdGFjayBpcyBET1dOOiIsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgIGZvciBuYW1lLCB1cmwgaW4gZW5kcG9pbnRzLml0ZW1zKCk6CiAgICAgICAg
  >> "!B64TMP!" echo bWFyayA9ICJPSyAgIiBpZiBzdFtuYW1lXSBlbHNlICJET1dOIgogICAgICAgIHByaW50KGYiICBb
  >> "!B64TMP!" echo e21hcmt9XSB7RElTUExBWVtuYW1lXX0gOntwb3J0X29mKHVybCl9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgaWYgY2hlY2tfb25seToKICAgICAgICByZXR1cm4gRmFsc2UsICJTdGFjayBpcyBkb3du
  >> "!B64TMP!" echo ICgtLWNoZWNrOiBub3RoaW5nIHdhcyBzdGFydGVkKS4iLCAxCgogICAgaWYgbm90IGRvY2tlcl9l
  >> "!B64TMP!" echo bmdpbmVfdXAoKToKICAgICAgICBwcmludCgiRG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZyDi
  >> "!B64TMP!" echo gJQgdHJ5aW5nIHRvIHN0YXJ0IGl0IC4uLiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIGlmIG5vdCBzdGFydF9kb2NrZXJfZW5naW5lKCk6CiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBGYWxzZSwgKCJDb3VsZCBub3Qgc3RhcnQgdGhlIERvY2tlciBlbmdpbmUgYXV0b21hdGljYWxs
  >> "!B64TMP!" echo eSAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICIoRG9ja2VyIERlc2t0b3Agbm90IGZvdW5k
  >> "!B64TMP!" echo IGluIHRoZSB1c3VhbCBsb2NhdGlvbnM/KS4gIgogICAgICAgICAgICAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo U3RhcnQgaXQgbWFudWFsbHksIHRoZW4gcmUtcnVuIHRoaXMgc2NyaXB0LiIpLCAyCiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoIldhaXRpbmcgZm9yIHRoZSBEb2NrZXIgZW5naW5lIHRvIGNvbWUgdXAgLi4uIiwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIGlmIG5vdCB3YWl0X2Zvcl9lbmdpbmUodGltZW91dD0xODAp
  >> "!B64TMP!" echo OgogICAgICAgICAgICByZXR1cm4gRmFsc2UsICgiVGhlIERvY2tlciBlbmdpbmUgd2FzIGxhdW5j
  >> "!B64TMP!" echo aGVkIGJ1dCBkaWQgbm90IGFuc3dlciB3aXRoaW4gIgogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiMTgwIHMuIENoZWNrIERvY2tlciBEZXNrdG9wLCB0aGVuIHJlLXJ1biB0aGlzIHNjcmlwdC4i
  >> "!B64TMP!" echo KSwgMgoKICAgICMgUmVjb21wdXRlZCBub3cgdGhhdCB0aGUgZW5naW5lIGlzIHVwOiB0aGUgY29t
  >> "!B64TMP!" echo cG9zZS1sYWJlbCBsb29rdXAgKHdoaWNoCiAgICAjIG5lZWRzIHRoZSBlbmdpbmUpIGNhbiBmaW5k
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGRpciB3aGVyZSB0aGUgb3RoZXIgbWV0aG9kcwogICAgIyBjb3VsZCBub3Qu
  >> "!B64TMP!" echo CiAgICBpbnN0YWxsX2RpciA9IGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkKICAgIGlmIG5vdCBp
  >> "!B64TMP!" echo bnN0YWxsX2RpcjoKICAgICAgICByZXR1cm4gRmFsc2UsICgiQ291bGQgbm90IGZpbmQgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBpbnN0YWxsIGZvbGRlciAiCiAgICAgICAgICAgICAgICAgICAgICAgIihubyBk
  >> "!B64TMP!" echo b2NrZXItY29tcG9zZS55bWwgZm91bmQpLiBBc2sgdGhlIHVzZXIgd2hlcmUgdGhlaXIgIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICJsb2NhbC1zZWFyY2ggZm9sZGVyIGlzLCB0aGVuIHJlLXJ1biB0
  >> "!B64TMP!" echo aGlzIHNjcmlwdCB3aXRoICIKICAgICAgICAgICAgICAgICAgICAgICAiTE9DQUxfU0VBUkNIX0RJ
  >> "!B64TMP!" echo UiBzZXQgdG8gdGhhdCBwYXRoLCBvciBzdGFydCB0aGUgc3RhY2sgbWFudWFsbHkgIgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICIoUnVuLmJhdCAvIHJ1bi5zaCkuIiksIDIKCiAgICBjb21wb3NlID0g
  >> "!B64TMP!" echo Y29tcG9zZV9jb21tYW5kKCkKICAgIGlmIG5vdCBjb21wb3NlOgogICAgICAgIHJldHVybiBGYWxz
  >> "!B64TMP!" echo ZSwgIk5laXRoZXIgJ2RvY2tlciBjb21wb3NlJyBub3IgJ2RvY2tlci1jb21wb3NlJyBpcyBhdmFp
  >> "!B64TMP!" echo bGFibGUuIiwgMgoKICAgIHByaW50KGYiU3RhcnRpbmcgc3RhY2sgaW4ge2luc3RhbGxfZGlyfSAu
  >> "!B64TMP!" echo Li4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY29tcG9zZSAr
  >> "!B64TMP!" echo IFsidXAiLCAiLWQiXSwgY3dkPWluc3RhbGxfZGlyKQogICAgaWYgcHJvYy5yZXR1cm5jb2RlICE9
  >> "!B64TMP!" echo IDA6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAiJ2RvY2tlciBjb21wb3NlIHVwIC1kJyBmYWlsZWQg
  >> "!B64TMP!" echo 4oCUIHNlZSBvdXRwdXQgYWJvdmUuIiwgMQoKICAgIHByaW50KCJXYWl0aW5nIGZvciBlbmRwb2lu
  >> "!B64TMP!" echo dHMgLi4uIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUoKSArIHJl
  >> "!B64TMP!" echo YWR5X3RpbWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgc3Qg
  >> "!B64TMP!" echo PSBzdGF0dXMoZW5kcG9pbnRzKQogICAgICAgIGlmIGFsbChzdC52YWx1ZXMoKSk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBUcnVlLCByZWFkeV9tZXNzYWdlKGVuZHBvaW50cyksIDAKICAgICAgICB0aW1l
  >> "!B64TMP!" echo LnNsZWVwKHBvbGxfZXZlcnkpCgogICAgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMo
  >> "!B64TMP!" echo KToKICAgICAgICBtYXJrID0gIk9LICAiIGlmIHN0W25hbWVdIGVsc2UgIkRPV04iCiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoZiIgIFt7bWFya31dIHtESVNQTEFZW25hbWVdfSA6e3BvcnRfb2YodXJsKX0iLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICByZXR1cm4gRmFsc2UsIChmIlN0YWNrIGRpZCBub3QgYmVjb21lIHJl
  >> "!B64TMP!" echo YWR5IHdpdGhpbiB7cmVhZHlfdGltZW91dH1zLiBJbnNwZWN0IHdpdGg6XG4iCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBmIiAgICBjZCB7aW5zdGFsbF9kaXJ9ICYmIGRvY2tlciBjb21wb3NlIGxvZ3MgLS10
  >> "!B64TMP!" echo YWlsIDUwIiksIDEKCgpkZWYgbWFpbigpOgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNl
  >> "!B64TMP!" echo cihkZXNjcmlwdGlvbj0iRW5zdXJlIHRoZSBsb2NhbC1zZWFyY2ggRG9ja2VyIHN0YWNrIGlzIHJ1
  >> "!B64TMP!" echo bm5pbmcuIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1jaGVjayIsIGFjdGlvbj0ic3RvcmVfdHJ1
  >> "!B64TMP!" echo ZSIsCiAgICAgICAgICAgICAgICAgICAgaGVscD0ib25seSByZXBvcnQgc3RhdHVzOyBuZXZlciBz
  >> "!B64TMP!" echo dGFydCBhbnl0aGluZyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgb2ssIG1lc3Nh
  >> "!B64TMP!" echo Z2UsIGNvZGUgPSBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1hcmdzLmNoZWNrKQogICAgaWYgb2s6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQobWVzc2FnZSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQobWVzc2Fn
  >> "!B64TMP!" echo ZSwgZmlsZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIGNvZGUKCgppZiBfX25hbWVfXyA9PSAiX19t
  >> "!B64TMP!" echo YWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\ensure_stack.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/firecrawl_api.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\firecrawl_api.py" (
  copy /Y "!SRC!\local-web-search\scripts\firecrawl_api.py" "!TARGET!\local-web-search\scripts\firecrawl_api.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\firecrawl_api.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/firecrawl_api.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3812617029.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTaGFyZWQgRmlyZWNyYXdsIEhUVFAgY2xpZW50IGZv
  >> "!B64TMP!" echo ciB0aGUgbG9jYWwtd2ViLXNlYXJjaCB3ZWJfKiBzY3JpcHRzLgoKRXZlcnkgc2NyaXB0IHRoYXQg
  >> "!B64TMP!" echo dGFsa3MgdG8gdGhlIEZpcmVjcmF3bCBBUEkgKHdlYl9zY3JhcGUucHksIHdlYl9tYXAucHksCndl
  >> "!B64TMP!" echo Yl9jcmF3bC5weSwgLi4uIHdlYl9kZXZlbG9wZXJfc2VhcmNoLnB5KSBnb2VzIHRocm91Z2ggdGhp
  >> "!B64TMP!" echo cyBtb2R1bGUsIHdoaWNoCmFkZHMgdGhlIHNhbWUgc2VsZi1oZWFsaW5nIGJlaGF2aW91ciBhcyB3
  >> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IC8gd2ViX3NjcmFwZS5weToKCiAgKiBvbiBhIENPTk5FQ1RJT04gZXJyb3Ig
  >> "!B64TMP!" echo KHN0YWNrIGRvd24pLCB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHN0YXJ0ZWQKICAgIGF1dG9t
  >> "!B64TMP!" echo YXRpY2FsbHkgKGVuc3VyZV9zdGFjay5weSBsb2dpYzogRG9ja2VyIGVuZ2luZSArIGBkb2NrZXIg
  >> "!B64TMP!" echo Y29tcG9zZQogICAgdXAgLWRgKSBhbmQgdGhlIHJlcXVlc3QgaXMgcmV0cmllZCBvbmNlIOKAlCBv
  >> "!B64TMP!" echo bmx5IHdoZW4gdGFsa2luZyB0byB0aGUgTE9DQUwKICAgIHN0YWNrLCBuZXZlciBmb3IgYSByZW1v
  >> "!B64TMP!" echo dGUgRklSRUNSQVdMX0FQSV9VUkwsCiAgKiB0cmFuc2llbnQgSFRUUCBzdGF0dXNlcyAoNDI5IC8g
  >> "!B64TMP!" echo NXh4KSBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZiwKICAqIGV2ZXJ5IGZhaWx1cmUg
  >> "!B64TMP!" echo aXMgcmVwb3J0ZWQgYXMgYW4gRmNFcnJvciB3aXRoIGEgY2xlYXIsIGFjdGlvbmFibGUgbWVzc2Fn
  >> "!B64TMP!" echo ZS4KCkVuZHBvaW50czogdGhlIGJhc2UgVVJMIGRlZmF1bHRzIHRvIHRoZSBsb2NhbCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgaW5zdGFuY2UgKHBvcnQgZnJvbQpGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xk
  >> "!B64TMP!" echo ZXIncyAuZW52LCBkZWZhdWx0IDk5OTEpLiBUd28gc2V0dGluZ3Mg4oCUCnRoZSBzYW1lIG5hbWVz
  >> "!B64TMP!" echo IHRoZSBvZmZpY2lhbCBmaXJlY3Jhd2wtbWNwIHNlcnZlciB1c2VzIOKAlCBvdmVycmlkZSBpdC4g
  >> "!B64TMP!" echo RWFjaAppcyByZWFkIGZyb20gdGhlIHByb2Nlc3MgZW52aXJvbm1lbnQgRklSU1QsIHRoZW4gZnJv
  >> "!B64TMP!" echo bSB0aGUgaW5zdGFsbCBmb2xkZXIncwouZW52ICh3aGVyZSBpbnN0YWxsLWxvY2FsLXNlYXJjaCBw
  >> "!B64TMP!" echo ZXJzaXN0cyB0aGUgY3JlZGVudGlhbHMgd2hlbiB5b3UgYW5zd2VyCid5JyB0byBpdHMgIkFkZCBh
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24pOgoKICBGSVJFQ1JBV0xfQVBJX1VSTCAgICBi
  >> "!B64TMP!" echo YXNlIFVSTCBvZiBhIEZpcmVjcmF3bCBBUEkgKGUuZy4gdGhlIGNsb3VkIEFQSSwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2KS4gU2V0IHRoaXMgdG8gdXNl
  >> "!B64TMP!" echo IGFjY291bnQKICAgICAgICAgICAgICAgICAgICAgICBmZWF0dXJlcyAoYWdlbnQsIGludGVyYWN0
  >> "!B64TMP!" echo LCBwYXJzZSwgbW9uaXRvcnMsIHJlc2VhcmNoLAogICAgICAgICAgICAgICAgICAgICAgIGRldmVs
  >> "!B64TMP!" echo b3BlciBzZWFyY2gpIHRoYXQgdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNlIGRvZXMKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBub3QgZXhwb3NlLgogIEZJUkVDUkFXTF9BUElfS0VZICAgIHNlbnQgYXMg
  >> "!B64TMP!" echo YEF1dGhvcml6YXRpb246IEJlYXJlciA8a2V5PmAgd2hlbiBzZXQg4oCUCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmVxdWlyZWQgYnkgdGhlIGNsb3VkIEFQSSBhbmQgYWNjb3VudCBmZWF0dXJlcy4K
  >> "!B64TMP!" echo ClVzYWdlIGZyb20gYSBzaWJsaW5nIHNjcmlwdDoKCiAgICBpbXBvcnQgZmlyZWNyYXdsX2FwaSBh
  >> "!B64TMP!" echo cyBmYwogICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PXsi
  >> "!B64TMP!" echo dXJsIjogdXJsfSkKCmBjYWxsKClgIHJldHVybnMgdGhlIHBhcnNlZCBKU09OIHJlc3BvbnNlIGFz
  >> "!B64TMP!" echo IGEgZGljdCBhbmQgcmFpc2VzIEZjRXJyb3Igb24KYW55IGZhaWx1cmUgKGFmdGVyIHRoZSByZXRy
  >> "!B64TMP!" echo aWVzIGRlc2NyaWJlZCBhYm92ZSkuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5
  >> "!B64TMP!" echo cwppbXBvcnQgdGltZQppbXBvcnQgdXJsbGliLmVycm9yCmltcG9ydCB1cmxsaWIucGFyc2UKaW1w
  >> "!B64TMP!" echo b3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdh
  >> "!B64TMP!" echo cmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUy
  >> "!B64TMP!" echo KSwgc28gZXJyb3IgbWVzc2FnZXMgYW5kIHByb2dyZXNzIG91dHB1dCBjb250YWluaW5nCiMgbm9u
  >> "!B64TMP!" echo LUFTQ0lJIHRleHQgbmV2ZXIgY3Jhc2ggd2l0aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBl
  >> "!B64TMP!" echo ZCBpZgojIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUIGFuIGV4cGxpY2l0IG92
  >> "!B64TMP!" echo ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmly
  >> "!B64TMP!" echo b246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAg
  >> "!B64TMP!" echo aWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAg
  >> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5z
  >> "!B64TMP!" echo ZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0
  >> "!B64TMP!" echo IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2
  >> "!B64TMP!" echo ZW4gZW5kcG9pbnRzCgojIERlZmF1bHQgdGltZW91dCBwZXIgSFRUUCBhdHRlbXB0IChzZWNvbmRz
  >> "!B64TMP!" echo KTsgY2FsbGVycyBjYW4gb3ZlcnJpZGUuClRJTUVPVVQgPSA5MAoKIyBUcmFuc2llbnQgc3RhdHVz
  >> "!B64TMP!" echo ZXMgd29ydGggcmV0cnlpbmc6IHJhdGUgbGltaXQgKyBjb21tb24gc2VydmVyIGVycm9ycy4KUkVU
  >> "!B64TMP!" echo UllfU1RBVFVTRVMgPSAoNDI5LCA1MDAsIDUwMiwgNTAzLCA1MDQpCiMgQmFja29mZiBiZWZvcmUg
  >> "!B64TMP!" echo ZWFjaCByZXRyeSAoc2Vjb25kcyk6IG9uZSBlbnRyeSBwZXIgcmV0cnkuClJFVFJZX0JBQ0tPRkYg
  >> "!B64TMP!" echo PSAoMSwgMykKCiMgQ2FjaGVkIHZpZXcgb2YgdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudiAobGF6
  >> "!B64TMP!" echo aWx5IGNvbXB1dGVkIG9uY2U6IHJlc29sdmluZwojIHRoZSBpbnN0YWxsIGZvbGRlciBtYXkgcXVl
  >> "!B64TMP!" echo cnkgRG9ja2VyKS4gSG9sZHMgdGhlIEZJUkVDUkFXTF9BUElfVVJMIC8KIyBGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSB2YWx1ZXMgdGhlIGluc3RhbGxlciB3cm90ZSB3aGVuIGEgRmlyZWNyYXdsIGFjY291bnQg
  >> "!B64TMP!" echo d2FzCiMgY29uZmlndXJlZCBhdCBpbnN0YWxsIHRpbWUuCl9JTlNUQUxMX0VOViA9IE5vbmUKCgpk
  >> "!B64TMP!" echo ZWYgX2luc3RhbGxfZW52KCk6CiAgICAiIiJUaGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IGFzIGEg
  >> "!B64TMP!" echo ZGljdCAoc2VlIGNvbmZpZy5sb2FkX2VudiksIGNhY2hlZC4iIiIKICAgIGdsb2JhbCBfSU5TVEFM
  >> "!B64TMP!" echo TF9FTlYKICAgIGlmIF9JTlNUQUxMX0VOViBpcyBOb25lOgogICAgICAgIHRyeToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgX0lOU1RBTExfRU5WID0gY29uZmlnLmxvYWRfZW52KGNvbmZpZy5maW5kX2luc3RhbGxfZGly
  >> "!B64TMP!" echo KCkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgX0lOU1RBTExfRU5WID0g
  >> "!B64TMP!" echo e30KICAgIHJldHVybiBfSU5TVEFMTF9FTlYKCgpkZWYgX3NldHRpbmcobmFtZSk6CiAgICAiIiJW
  >> "!B64TMP!" echo YWx1ZSBvZiBGSVJFQ1JBV0xfQVBJX1VSTCAvIEZJUkVDUkFXTF9BUElfS0VZOiB0aGUgcHJvY2Vz
  >> "!B64TMP!" echo cwogICAgZW52aXJvbm1lbnQgZmlyc3QgKHRoZSBzYW1lIG92ZXJyaWRlIHRoZSBvZmZpY2lhbCBm
  >> "!B64TMP!" echo aXJlY3Jhd2wtbWNwIHNlcnZlcgogICAgaG9ub3VycyksIHRoZW4gdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgLmVudi4gU3RyaXBwZWQsIHBvc3NpYmx5IGVtcHR5LiIiIgogICAgdmFsID0gKG9zLmVudmly
  >> "!B64TMP!" echo b24uZ2V0KG5hbWUpIG9yICIiKS5zdHJpcCgpCiAgICBpZiB2YWw6CiAgICAgICAgcmV0dXJuIHZh
  >> "!B64TMP!" echo bAogICAgcmV0dXJuIChfaW5zdGFsbF9lbnYoKS5nZXQobmFtZSkgb3IgIiIpLnN0cmlwKCkKCgpj
  >> "!B64TMP!" echo bGFzcyBGY0Vycm9yKEV4Y2VwdGlvbik6CiAgICAiIiJBIEZpcmVjcmF3bCBBUEkgZmFpbHVyZSBh
  >> "!B64TMP!" echo ZnRlciBhbGwgcmV0cmllcywgd2l0aCBhIHVzZXItZmFjaW5nIGhpbnQuCgogICAgQXR0cmlidXRl
  >> "!B64TMP!" echo czoKICAgICAgICBtZXNzYWdlICB3aGF0IHdlbnQgd3JvbmcgKHNpbmdsZSBsaW5lKQogICAgICAg
  >> "!B64TMP!" echo IHN0YXR1cyAgIEhUVFAgc3RhdHVzIGNvZGUsIG9yIE5vbmUgZm9yIGNvbm5lY3Rpb24vcHJvdG9j
  >> "!B64TMP!" echo b2wgZXJyb3JzCiAgICAgICAgaGludCAgICAgb3B0aW9uYWwgZXh0cmEgZ3VpZGFuY2UgcHJpbnRl
  >> "!B64TMP!" echo ZCBieSB0aGUgQ0xJIHNjcmlwdHMKICAgICIiIgoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBtZXNz
  >> "!B64TMP!" echo YWdlLCBzdGF0dXM9Tm9uZSwgaGludD1Ob25lKToKICAgICAgICBzdXBlcigpLl9faW5pdF9fKG1l
  >> "!B64TMP!" echo c3NhZ2UpCiAgICAgICAgc2VsZi5zdGF0dXMgPSBzdGF0dXMKICAgICAgICBzZWxmLmhpbnQgPSBo
  >> "!B64TMP!" echo aW50CgoKZGVmIGJhc2VfdXJsKCk6CiAgICAiIiJUaGUgRmlyZWNyYXdsIGJhc2UgVVJMOiBGSVJF
  >> "!B64TMP!" echo Q1JBV0xfQVBJX1VSTCB3aGVuIHNldCBpbiB0aGUgZW52aXJvbm1lbnQKICAgIG9yIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYgKHNlbGYtaG9zdGVkIHJlbW90ZSBvciB0aGUgY2xvdWQgQVBJKSwK
  >> "!B64TMP!" echo ICAgIG90aGVyd2lzZSB0aGUgbG9jYWwgc3RhY2sncyBlbmRwb2ludCAoRklSRUNSQVdMX1BPUlQg
  >> "!B64TMP!" echo ZnJvbSB0aGUgaW5zdGFsbAogICAgZm9sZGVyJ3MgLmVudiwgZGVmYXVsdCA5OTkxKS4iIiIKICAg
  >> "!B64TMP!" echo IG92ZXJyaWRlID0gX3NldHRpbmcoIkZJUkVDUkFXTF9BUElfVVJMIikKICAgIGlmIG92ZXJyaWRl
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiBvdmVycmlkZS5yc3RyaXAoIi8iKQogICAgcmV0dXJuIGNvbmZpZy5l
  >> "!B64TMP!" echo bmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSlbImZpcmVjcmF3bCJdCgoKZGVmIGlz
  >> "!B64TMP!" echo X2xvY2FsKCk6CiAgICAiIiJUcnVlIHdoZW4gcmVxdWVzdHMgZ28gdG8gdGhlIExPQ0FMIHN0YWNr
  >> "!B64TMP!" echo IChubyBGSVJFQ1JBV0xfQVBJX1VSTCBpbiB0aGUKICAgIGVudmlyb25tZW50IG9yIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYpLCBpLmUuIHNlbGYtaGVhbGluZyBhIGRvd24KICAgIHN0YWNrIGNh
  >> "!B64TMP!" echo biBoZWxwLiIiIgogICAgcmV0dXJuIG5vdCBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9VUkwiKQoK
  >> "!B64TMP!" echo CmRlZiB1cmwocGF0aCk6CiAgICAiIiJBYnNvbHV0ZSBVUkwgZm9yIGFuIEFQSSBwYXRoIGxpa2Ug
  >> "!B64TMP!" echo Jy92MS9tYXAnIChzZWUgYmFzZV91cmwoKSkuIiIiCiAgICByZXR1cm4gYmFzZV91cmwoKSArIHBh
  >> "!B64TMP!" echo dGgKCgpkZWYgYXV0aF9oZWFkZXJzKCk6CiAgICAiIiJIZWFkZXJzIGZvciBhIEpTT04gcmVxdWVz
  >> "!B64TMP!" echo dDogY29udGVudCB0eXBlICsgb3B0aW9uYWwgQmVhcmVyIGF1dGggZnJvbQogICAgRklSRUNSQVdM
  >> "!B64TMP!" echo X0FQSV9LRVkgKGVudmlyb25tZW50IG9yIGluc3RhbGwgLmVudjsgbmVlZGVkIGZvciBhY2NvdW50
  >> "!B64TMP!" echo CiAgICBmZWF0dXJlcyAvIHRoZSBjbG91ZCBBUEkpLiIiIgogICAgaGVhZGVycyA9IHsiQ29udGVu
  >> "!B64TMP!" echo dC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24ifQogICAga2V5ID0gX3NldHRpbmcoIkZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfS0VZIikKICAgIGlmIGtleToKICAgICAgICBoZWFkZXJzWyJBdXRob3JpemF0aW9uIl0g
  >> "!B64TMP!" echo PSAiQmVhcmVyICIgKyBrZXkKICAgIHJldHVybiBoZWFkZXJzCgoKZGVmIF9zZWxmaGVhbCgpOgog
  >> "!B64TMP!" echo ICAgIiIiU3RhcnQgdGhlIERvY2tlciBlbmdpbmUgKyB0aGUgY29udGFpbmVycyBpZiB0aGV5IGFy
  >> "!B64TMP!" echo ZSBkb3duICh0aGUgc2FtZQogICAgbG9naWMgYXMgZW5zdXJlX3N0YWNrLnB5KS4gSW1wb3J0IGlz
  >> "!B64TMP!" echo IGRlZmVycmVkIHNvIHRoZSBmYXN0IHBhdGggKHN0YWNrCiAgICBhbHJlYWR5IHVwKSBwYXlzIG5v
  >> "!B64TMP!" echo dGhpbmcuIFJldHVybnMgKG9rLCBtZXNzYWdlKS4iIiIKICAgIHRyeToKICAgICAgICBpbXBvcnQg
  >> "!B64TMP!" echo ZW5zdXJlX3N0YWNrCiAgICAgICAgb2ssIG1lc3NhZ2UsIF9jb2RlID0gZW5zdXJlX3N0YWNrLmVu
  >> "!B64TMP!" echo c3VyZV9yZWFkeSgpCiAgICAgICAgcmV0dXJuIG9rLCBtZXNzYWdlCiAgICBleGNlcHQgRXhjZXB0
  >> "!B64TMP!" echo aW9uIGFzIGU6ICAjIHVuZXhwZWN0ZWQgc2VsZi1oZWFsIGZhaWx1cmU6IGRlZ3JhZGUgZ3JhY2Vm
  >> "!B64TMP!" echo dWxseQogICAgICAgIHJldHVybiBGYWxzZSwgInNlbGYtaGVhbCBmYWlsZWQgdW5leHBlY3RlZGx5
  >> "!B64TMP!" echo OiB7fSIuZm9ybWF0KGUpCgoKZGVmIF9yZWFkX2JvZHkoZSk6CiAgICAiIiJCZXN0LWVmZm9ydCBl
  >> "!B64TMP!" echo cnJvciBib2R5IGZyb20gYW4gSFRUUEVycm9yIChKU09OIG1lc3NhZ2Ugb3IgcmF3IHRleHQpLiIi
  >> "!B64TMP!" echo IgogICAgdHJ5OgogICAgICAgIHJhdyA9IGUucmVhZCgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgog
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiAiIgogICAgdGV4dCA9IHJhdy5kZWNvZGUoInV0Zi04IiwgInJlcGxhY2Ui
  >> "!B64TMP!" echo KVs6ODAwXQogICAgdHJ5OgogICAgICAgIHBheWxvYWQgPSBqc29uLmxvYWRzKHRleHQpCiAgICAg
  >> "!B64TMP!" echo ICAgbXNnID0gcGF5bG9hZC5nZXQoImVycm9yIikgb3IgcGF5bG9hZC5nZXQoIm1lc3NhZ2UiKQog
  >> "!B64TMP!" echo ICAgICAgIGlmIGlzaW5zdGFuY2UobXNnLCBzdHIpIGFuZCBtc2c6CiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBtc2cKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHRleHQK
  >> "!B64TMP!" echo CgpkZWYgX2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpOgogICAgIiIiQWN0aW9uYWJsZSBndWlkYW5j
  >> "!B64TMP!" echo ZSBmb3IgdGhlIHN0YXR1c2VzIGFjY291bnQtZ2F0ZWQgZW5kcG9pbnRzIHJldHVybi4iIiIKICAg
  >> "!B64TMP!" echo IGlmIHN0YXR1cyBpbiAoNDAxLCA0MDMpOgogICAgICAgIHJldHVybiAoIlRoaXMgdG9vbCBuZWVk
  >> "!B64TMP!" echo cyBhbiBhdXRoZW50aWNhdGVkIEZpcmVjcmF3bCBhY2NvdW50OiBzZXQgIgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIkZJUkVDUkFXTF9BUElfS0VZIChhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
  >> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiAiCiAgICAgICAgICAgICAgICAidG8gdXNlIHRoZSBjbG91ZCBBUEkpIGFu
  >> "!B64TMP!" echo ZCByZXRyeS4iKQogICAgaWYgc3RhdHVzID09IDQwNDoKICAgICAgICByZXR1cm4gKCJUaGlzIGVu
  >> "!B64TMP!" echo ZHBvaW50IGlzIG5vdCBhdmFpbGFibGUgb24gdGhlIEZpcmVjcmF3bCBpbnN0YW5jZSBpdCAiCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAid2FzIGNhbGxlZCBhZ2FpbnN0LiBBY2NvdW50IHRvb2xzIChtb25pdG9y
  >> "!B64TMP!" echo IC8gcmVzZWFyY2ggLyAiCiAgICAgICAgICAgICAgICAiZGV2ZWxvcGVyIHNlYXJjaCkgbmVlZCB0
  >> "!B64TMP!" echo aGUgY2xvdWQgQVBJOiBzZXQgIgogICAgICAgICAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJMPWh0
  >> "!B64TMP!" echo dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgYW5kICIKICAgICAgICAgICAgICAgICJGSVJFQ1JBV0xf
  >> "!B64TMP!" echo QVBJX0tFWSwgdGhlbiByZXRyeS4iKQogICAgaWYgc3RhdHVzIGluIFJFVFJZX1NUQVRVU0VTOgog
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiAoIlRoZSBGaXJlY3Jhd2wgc2VydmljZSBhbnN3ZXJlZCB3aXRoIGEgc2Vy
  >> "!B64TMP!" echo dmVyIGVycm9yLiBXYWl0IGEgIgogICAgICAgICAgICAgICAgIm1vbWVudCBhbmQgcmV0cnk7IGlm
  >> "!B64TMP!" echo IGl0IHBlcnNpc3RzLCBpbnNwZWN0IHRoZSBzdGFjayB3aXRoOiAiCiAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo Y2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1MCBmaXJl
  >> "!B64TMP!" echo Y3Jhd2wiKQogICAgcmV0dXJuIE5vbmUKCgpkZWYgX3JlcXVlc3QoZW5kcG9pbnQsIG1ldGhvZCwg
  >> "!B64TMP!" echo Ym9keV9ieXRlcywgaGVhZGVycywgdGltZW91dCk6CiAgICAiIiJPbmUgcmF3IEhUVFAgYXR0ZW1w
  >> "!B64TMP!" echo dC4gUmFpc2VzIEhUVFBFcnJvciAoc2VydmljZSBhbnN3ZXJlZCB3aXRoIGFuCiAgICBlcnJvciBz
  >> "!B64TMP!" echo dGF0dXMg4oCUIHNlcnZpY2UgaXMgVVApIG9yIFVSTEVycm9yLWZhbWlseSAoY29ubmVjdGlvbiBw
  >> "!B64TMP!" echo cm9ibGVtIOKAlAogICAgc2VydmljZSBpcyBET1dOKS4gUmV0dXJucyB0aGUgcGFyc2VkIEpTT04g
  >> "!B64TMP!" echo cmVzcG9uc2UuIiIiCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KGVuZHBvaW50LCBk
  >> "!B64TMP!" echo YXRhPWJvZHlfYnl0ZXMsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9
  >> "!B64TMP!" echo aGVhZGVycywgbWV0aG9kPW1ldGhvZCkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3Blbihy
  >> "!B64TMP!" echo ZXEsIHRpbWVvdXQ9dGltZW91dCkgYXMgcjoKICAgICAgICB0ZXh0ID0gci5yZWFkKCkuZGVjb2Rl
  >> "!B64TMP!" echo KCJ1dGYtOCIsICJyZXBsYWNlIikKICAgIGlmIG5vdCB0ZXh0LnN0cmlwKCk6CiAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIHt9CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGpzb24ubG9hZHModGV4dCkKICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBWYWx1ZUVycm9yOgogICAgICAgIHJhaXNlIEZjRXJyb3IoIkZpcmVjcmF3bCByZXR1cm5lZCBh
  >> "!B64TMP!" echo IG5vbi1KU09OIHJlc3BvbnNlOiAiCiAgICAgICAgICAgICAgICAgICAgICArIHRleHRbOjMwMF0p
  >> "!B64TMP!" echo CgoKZGVmIGNhbGwocGF0aCwgbWV0aG9kPSJHRVQiLCBib2R5PU5vbmUsIHF1ZXJ5PU5vbmUsIHRp
  >> "!B64TMP!" echo bWVvdXQ9VElNRU9VVCk6CiAgICAiIiJDYWxsIHRoZSBGaXJlY3Jhd2wgQVBJIHdpdGggcmV0cmll
  >> "!B64TMP!" echo cyArIHNlbGYtaGVhbGluZy4KCiAgICBwYXRoICAgIEFQSSBwYXRoLCBlLmcuICIvdjEvbWFwIiBv
  >> "!B64TMP!" echo ciAiL3YxL2NyYXdsLzxpZD4iIChhbHJlYWR5IGVuY29kZWQpCiAgICBtZXRob2QgIEhUVFAgbWV0
  >> "!B64TMP!" echo aG9kIChHRVQgLyBQT1NUIC8gUEFUQ0ggLyBERUxFVEUpCiAgICBib2R5ICAgIEpTT04tc2VyaWFs
  >> "!B64TMP!" echo aXNhYmxlIHJlcXVlc3QgYm9keSAoZGljdCkgb3IgTm9uZQogICAgcXVlcnkgICBkaWN0IG9mIHF1
  >> "!B64TMP!" echo ZXJ5LXN0cmluZyBwYXJhbWV0ZXJzIChza2lwcGVkIHdoZW4gZW1wdHkvTm9uZSkKICAgIHRpbWVv
  >> "!B64TMP!" echo dXQgc2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgogICAgUmV0dXJucyB0aGUgcGFyc2VkIEpTT04g
  >> "!B64TMP!" echo cmVzcG9uc2UgKGRpY3QpLiBSYWlzZXMgRmNFcnJvciBhZnRlciB0aGUKICAgIHJldHJpZXMgYXJl
  >> "!B64TMP!" echo IGV4aGF1c3RlZCAoc2VlIG1vZHVsZSBkb2NzdHJpbmcgZm9yIHRoZSByZXRyeSBwb2xpY3kpLiIi
  >> "!B64TMP!" echo IgogICAgZW5kcG9pbnQgPSB1cmwocGF0aCkKICAgIGlmIHF1ZXJ5OgogICAgICAgIHBhaXJzID0g
  >> "!B64TMP!" echo WyhrLCB2KSBmb3IgaywgdiBpbiBxdWVyeS5pdGVtcygpIGlmIHYgaXMgbm90IE5vbmVdCiAgICAg
  >> "!B64TMP!" echo ICAgaWYgcGFpcnM6CiAgICAgICAgICAgIGVuZHBvaW50ICs9ICI/IiArIHVybGxpYi5wYXJzZS51
  >> "!B64TMP!" echo cmxlbmNvZGUocGFpcnMpCiAgICBib2R5X2J5dGVzID0gTm9uZQogICAgaGVhZGVycyA9IGF1dGhf
  >> "!B64TMP!" echo aGVhZGVycygpCiAgICBpZiBib2R5IGlzIG5vdCBOb25lOgogICAgICAgIGJvZHlfYnl0ZXMgPSBq
  >> "!B64TMP!" echo c29uLmR1bXBzKGJvZHkpLmVuY29kZSgidXRmLTgiKQoKICAgIGF0dGVtcHRzID0gMSArIGxlbihS
  >> "!B64TMP!" echo RVRSWV9CQUNLT0ZGKSAgIyBpbml0aWFsICsgcmV0cmllcwogICAgZm9yIGF0dGVtcHQgaW4gcmFu
  >> "!B64TMP!" echo Z2UoMSwgYXR0ZW1wdHMgKyAxKToKICAgICAgICAjIC0tLS0gb25lIGF0dGVtcHQsIGNsYXNzaWZ5
  >> "!B64TMP!" echo aW5nIGV2ZXJ5IGZhaWx1cmUgbW9kZSAtLS0tLS0tLS0tLS0tLS0tLQogICAgICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50LCBtZXRob2QsIGJvZHlfYnl0ZXMsIGhl
  >> "!B64TMP!" echo YWRlcnMsIHRpbWVvdXQpCiAgICAgICAgZXhjZXB0IHVybGxpYi5lcnJvci5IVFRQRXJyb3IgYXMg
  >> "!B64TMP!" echo ZToKICAgICAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAgICAgICAgICAgIGRldGFpbCA9IF9yZWFk
  >> "!B64TMP!" echo X2JvZHkoZSkKICAgICAgICAgICAgaWYgc3RhdHVzIGluIFJFVFJZX1NUQVRVU0VTIGFuZCBhdHRl
  >> "!B64TMP!" echo bXB0IDwgYXR0ZW1wdHM6CiAgICAgICAgICAgICAgICB3YWl0ID0gUkVUUllfQkFDS09GRlthdHRl
  >> "!B64TMP!" echo bXB0IC0gMV0KICAgICAgICAgICAgICAgIHByaW50KGYiRmlyZWNyYXdsIGFuc3dlcmVkIHtzdGF0
  >> "!B64TMP!" echo dXN9ICh7ZGV0YWlsIG9yICdzZXJ2ZXIgZXJyb3InfSkgIgogICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ZiLigJQgcmV0cnlpbmcgaW4ge3dhaXR9cyAuLi4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICB0aW1lLnNsZWVwKHdhaXQpCiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAg
  >> "!B64TMP!" echo ICAgICByYWlzZSBGY0Vycm9yKCJIVFRQIHt9e317fSIuZm9ybWF0KAogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo c3RhdHVzLCAiOiAiICsgZGV0YWlsIGlmIGRldGFpbCBlbHNlICIiLAogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IiIgaWYgYXR0ZW1wdCA9PSAxIGVsc2UgZiIgKGFmdGVyIHthdHRlbXB0fSBhdHRlbXB0cykiKSwK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHN0YXR1cz1zdGF0dXMsIGhpbnQ9X2hpbnRfZm9yX3N0YXR1cyhzdGF0
  >> "!B64TMP!" echo dXMpKSBmcm9tIGUKICAgICAgICBleGNlcHQgRmNFcnJvcjoKICAgICAgICAgICAgcmFpc2UKICAg
  >> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6ICAjIFVSTEVycm9yIC8gQ29ubmVjdGlvbkVycm9y
  >> "!B64TMP!" echo IC8gdGltZW91dDogRE9XTgogICAgICAgICAgICBpZiBub3QgaXNfbG9jYWwoKToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAgICAgICAgICAgICAgImNvdWxkIG5vdCByZWFj
  >> "!B64TMP!" echo aCB7fSAoe30pLiBDaGVjayB0aGUgVVJMIGFuZCB5b3VyICIKICAgICAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo bmV0d29yaywgdGhlbiByZXRyeS4iLmZvcm1hdChiYXNlX3VybCgpLCBlKSkgZnJvbSBlCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIGlmIGF0dGVtcHQgPCBhdHRlbXB0czoKICAgICAgICAgICAgICAgICMgTG9jYWwgc3Rh
  >> "!B64TMP!" echo Y2s6IHRyeSB0byBicmluZyBpdCB1cCwgdGhlbiByZXRyeSB0aGUgcmVxdWVzdC4KICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYiU3RhY2sgdW5yZWFjaGFibGUgKHtlfSkg4oCUIHN0YXJ0aW5nIGl0IGF1
  >> "!B64TMP!" echo dG9tYXRpY2FsbHkgLi4uIiwKICAgICAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIG9rLCBtZXNzYWdlID0gX3NlbGZoZWFsKCkKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IGlmIG5vdCBvazoKICAgICAgICAgICAgICAgICAgICByYWlzZSBGY0Vycm9yKAogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAidGhlIGxvY2FsLXNlYXJjaCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRl
  >> "!B64TMP!" echo ZDogIiArIG1lc3NhZ2UKICAgICAgICAgICAgICAgICAgICAgICAgKyAiIFJlc29sdmUgdGhlIHN0
  >> "!B64TMP!" echo YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiRGVza3RvcCkgYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNrIHRvIG90aGVy
  >> "!B64TMP!" echo IHdlYiAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgInRvb2xzIHVubGVzcyB0aGUgdXNlciBh
  >> "!B64TMP!" echo c2tzLiIpIGZyb20gZQogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgcmFpc2Ug
  >> "!B64TMP!" echo RmNFcnJvcigKICAgICAgICAgICAgICAgICJyZXF1ZXN0IGZhaWxlZCBhZnRlciB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2FzIHN0YXJ0ZWQ6IHt9Ii5mb3JtYXQoZSkpIGZyb20gZQogICAgIyB1bnJlYWNoYWJsZTogdGhl
  >> "!B64TMP!" echo IGxvb3AgZWl0aGVyIHJldHVybnMgb3IgcmFpc2VzCiAgICByYWlzZSBGY0Vycm9yKCJyZXF1ZXN0
  >> "!B64TMP!" echo IGZhaWxlZCB1bmV4cGVjdGVkbHkiKQoKCmRlZiBjYWxsX2Zvcm0ocGF0aCwgZmllbGRzLCBmaWxl
  >> "!B64TMP!" echo X3BhdGgsIGZpbGVfZmllbGQ9ImZpbGUiLCB0aW1lb3V0PVRJTUVPVVQpOgogICAgIiIiQ2FsbCB0
  >> "!B64TMP!" echo aGUgRmlyZWNyYXdsIEFQSSB3aXRoIGEgbXVsdGlwYXJ0L2Zvcm0tZGF0YSBib2R5ICh1c2VkIGJ5
  >> "!B64TMP!" echo CiAgICB3ZWJfcGFyc2UucHkgdG8gdXBsb2FkIGEgbG9jYWwgZG9jdW1lbnQpLgoKICAgIGZpZWxk
  >> "!B64TMP!" echo cyAgICAgIGRpY3Qgb2YgZm9ybSBmaWVsZHMgKHZhbHVlcyBhcmUgc3RyIC8gaW50IC8gbGlzdCkK
  >> "!B64TMP!" echo ICAgIGZpbGVfcGF0aCAgIHRoZSBmaWxlIHRvIHVwbG9hZCAocmVhZCBpbiBiaW5hcnkgbW9kZSkK
  >> "!B64TMP!" echo ICAgIGZpbGVfZmllbGQgIHRoZSBmb3JtIGZpZWxkIG5hbWUgZm9yIHRoZSBmaWxlIChGaXJlY3Jh
  >> "!B64TMP!" echo d2w6ICJmaWxlIikKICAgICIiIgogICAgYm91bmRhcnkgPSAiLS0tLWxvY2Fsd2Vic2VhcmNoIiAr
  >> "!B64TMP!" echo IGZvcm1hdChpbnQodGltZS50aW1lKCkgKiAxMDAwKSwgIngiKQogICAgcGFydHMgPSBbXQogICAg
  >> "!B64TMP!" echo Zm9yIGtleSwgdmFsIGluIChmaWVsZHMgb3Ige30pLml0ZW1zKCk6CiAgICAgICAgaWYgdmFsIGlz
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgdmFsdWVzID0gdmFsIGlmIGlzaW5z
  >> "!B64TMP!" echo dGFuY2UodmFsLCBsaXN0KSBlbHNlIFt2YWxdCiAgICAgICAgZm9yIHYgaW4gdmFsdWVzOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBwYXJ0cy5hcHBlbmQoKCItLSIgKyBib3VuZGFyeSkuZW5jb2RlKCJ1dGYtOCIpKQog
  >> "!B64TMP!" echo ICAgICAgICAgICBwYXJ0cy5hcHBlbmQoKCdDb250ZW50LURpc3Bvc2l0aW9uOiBmb3JtLWRhdGE7
  >> "!B64TMP!" echo IG5hbWU9Int9IicKICAgICAgICAgICAgICAgICAgICAgICAgICAuZm9ybWF0KGtleSkpLmVuY29k
  >> "!B64TMP!" echo ZSgidXRmLTgiKSkKICAgICAgICAgICAgcGFydHMuYXBwZW5kKGIiIikKICAgICAgICAgICAgcGFy
  >> "!B64TMP!" echo dHMuYXBwZW5kKHN0cih2KS5lbmNvZGUoInV0Zi04IikpCiAgICB0cnk6CiAgICAgICAgd2l0aCBv
  >> "!B64TMP!" echo cGVuKGZpbGVfcGF0aCwgInJiIikgYXMgZmg6CiAgICAgICAgICAgIHBheWxvYWQgPSBmaC5yZWFk
  >> "!B64TMP!" echo KCkKICAgIGV4Y2VwdCBPU0Vycm9yIGFzIGU6CiAgICAgICAgcmFpc2UgRmNFcnJvcigiY291bGQg
  >> "!B64TMP!" echo bm90IHJlYWQge306IHt9Ii5mb3JtYXQoZmlsZV9wYXRoLCBlKSkKICAgIGZpbGVuYW1lID0gb3Mu
  >> "!B64TMP!" echo cGF0aC5iYXNlbmFtZShmaWxlX3BhdGgpCiAgICBwYXJ0cy5hcHBlbmQoKCItLSIgKyBib3VuZGFy
  >> "!B64TMP!" echo eSkuZW5jb2RlKCJ1dGYtOCIpKQogICAgcGFydHMuYXBwZW5kKCgnQ29udGVudC1EaXNwb3NpdGlv
  >> "!B64TMP!" echo bjogZm9ybS1kYXRhOyBuYW1lPSJ7fSI7IGZpbGVuYW1lPSJ7fSInCiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IC5mb3JtYXQoZmlsZV9maWVsZCwgZmlsZW5hbWUpKS5lbmNvZGUoInV0Zi04IikpCiAgICBwYXJ0
  >> "!B64TMP!" echo cy5hcHBlbmQoYiJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL29jdGV0LXN0cmVhbSIpCiAgICBw
  >> "!B64TMP!" echo YXJ0cy5hcHBlbmQoYiIiKQogICAgcGFydHMuYXBwZW5kKHBheWxvYWQpCiAgICBwYXJ0cy5hcHBl
  >> "!B64TMP!" echo bmQoKCItLSIgKyBib3VuZGFyeSArICItLSIpLmVuY29kZSgidXRmLTgiKSkKICAgIGJvZHkgPSBi
  >> "!B64TMP!" echo IlxyXG4iLmpvaW4ocGFydHMpCgogICAgZW5kcG9pbnQgPSB1cmwocGF0aCkKICAgIGhlYWRlcnMg
  >> "!B64TMP!" echo PSB7CiAgICAgICAgIkNvbnRlbnQtVHlwZSI6ICJtdWx0aXBhcnQvZm9ybS1kYXRhOyBib3VuZGFy
  >> "!B64TMP!" echo eT0iICsgYm91bmRhcnksCiAgICB9CiAgICBrZXkgPSBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9L
  >> "!B64TMP!" echo RVkiKQogICAgaWYga2V5OgogICAgICAgIGhlYWRlcnNbIkF1dGhvcml6YXRpb24iXSA9ICJCZWFy
  >> "!B64TMP!" echo ZXIgIiArIGtleQoKICAgIHRyeToKICAgICAgICByZXR1cm4gX3JlcXVlc3QoZW5kcG9pbnQsICJQ
  >> "!B64TMP!" echo T1NUIiwgYm9keSwgaGVhZGVycywgdGltZW91dCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRU
  >> "!B64TMP!" echo UEVycm9yIGFzIGU6CiAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAgICAgICAgZGV0YWlsID0gX3Jl
  >> "!B64TMP!" echo YWRfYm9keShlKQogICAgICAgIHJhaXNlIEZjRXJyb3IoIkhUVFAge317fXt9Ii5mb3JtYXQoCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHN0YXR1cywgIjogIiArIGRldGFpbCBpZiBkZXRhaWwgZWxzZSAiIiksCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHN0YXR1cz1zdGF0dXMsIGhpbnQ9X2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpKSBmcm9t
  >> "!B64TMP!" echo IGUKICAgIGV4Y2VwdCBGY0Vycm9yOgogICAgICAgIHJhaXNlCiAgICBleGNlcHQgRXhjZXB0aW9u
  >> "!B64TMP!" echo IGFzIGU6ICAjIGNvbm5lY3Rpb24gcHJvYmxlbTogc3RhY2sgKHByb2JhYmx5KSBkb3duCiAgICAg
  >> "!B64TMP!" echo ICAgaWYgbm90IGlzX2xvY2FsKCk6CiAgICAgICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiY291bGQgbm90IHJlYWNoIHt9ICh7fSkuIENoZWNrIHRoZSBVUkwgYW5kIHlvdXIg
  >> "!B64TMP!" echo bmV0d29yaywgIgogICAgICAgICAgICAgICAgInRoZW4gcmV0cnkuIi5mb3JtYXQoYmFzZV91cmwo
  >> "!B64TMP!" echo KSwgZSkpIGZyb20gZQogICAgICAgIHByaW50KGYiU3RhY2sgdW5yZWFjaGFibGUgKHtlfSkg4oCU
  >> "!B64TMP!" echo IHN0YXJ0aW5nIGl0IGF1dG9tYXRpY2FsbHkgLi4uIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgb2ssIG1lc3NhZ2UgPSBfc2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBv
  >> "!B64TMP!" echo azoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigidGhlIGxvY2FsLXNlYXJjaCBzdGFjayBjb3Vs
  >> "!B64TMP!" echo ZCBub3QgYmUgc3RhcnRlZDogIgogICAgICAgICAgICAgICAgICAgICAgICAgICsgbWVzc2FnZSkg
  >> "!B64TMP!" echo ZnJvbSBlCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1cm4gX3JlcXVlc3QoZW5kcG9pbnQs
  >> "!B64TMP!" echo ICJQT1NUIiwgYm9keSwgaGVhZGVycywgdGltZW91dCkKICAgICAgICBleGNlcHQgdXJsbGliLmVy
  >> "!B64TMP!" echo cm9yLkhUVFBFcnJvciBhcyBlMjoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigiSFRUUCB7fTog
  >> "!B64TMP!" echo e30iLmZvcm1hdChlMi5jb2RlLCBfcmVhZF9ib2R5KGUyKSksCiAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3RhdHVzPWUyLmNvZGUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgaGludD1faGlu
  >> "!B64TMP!" echo dF9mb3Jfc3RhdHVzKGUyLmNvZGUpKSBmcm9tIGUyCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBh
  >> "!B64TMP!" echo cyBlMjoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigicmVxdWVzdCBmYWlsZWQgYWZ0ZXIgdGhl
  >> "!B64TMP!" echo IHN0YWNrIHdhcyBzdGFydGVkOiAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgInt9Ii5mb3Jt
  >> "!B64TMP!" echo YXQoZTIpKSBmcm9tIGUyCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\firecrawl_api.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_search.py" "!TARGET!\local-web-search\scripts\web_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1822793958.b64"
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
  >> "!B64TMP!" echo dXJsbGliLnBhcnNlCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKIyBEZWZhdWx0IHN0ZG91dC9zdGRl
  >> "!B64TMP!" echo cnIgdG8gVVRGLTggcmVnYXJkbGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUvY29kZXBhZ2UKIyAoZS5n
  >> "!B64TMP!" echo LiBXaW5kb3dzIGNwMTI1MiksIHNvIHNlYXJjaCByZXN1bHRzIHdpdGggbm9uLUFTQ0lJIHRleHQg
  >> "!B64TMP!" echo bmV2ZXIgY3Jhc2gKIyB3aXRoIGEgVW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmIFBZVEhP
  >> "!B64TMP!" echo TklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUCiMgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3
  >> "!B64TMP!" echo YXlzIHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZv
  >> "!B64TMP!" echo ciBfc3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRy
  >> "!B64TMP!" echo KF9zdHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBfc3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
  >> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAj
  >> "!B64TMP!" echo IHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2lu
  >> "!B64TMP!" echo dHMKCiMgUG9ydCBjb21lcyBmcm9tIFNFQVJYTkdfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIn
  >> "!B64TMP!" echo cyAuZW52IChkZWZhdWx0IDk5OTApLgpCQVNFID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcuZmlu
  >> "!B64TMP!" echo ZF9pbnN0YWxsX2RpcigpKVsic2VhcnhuZyJdICsgIi9zZWFyY2giCgpUSU1FT1VUID0gMzAgICMg
  >> "!B64TMP!" echo c2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJHRVQgdGhl
  >> "!B64TMP!" echo IFNlYXJYTkcgSlNPTiBBUEkuIFJhaXNlcyBIVFRQRXJyb3Igd2hlbiB0aGUgc2VydmljZSBhbnN3
  >> "!B64TMP!" echo ZXJlZAogICAgd2l0aCBhbiBlcnJvciBzdGF0dXMgKHNlcnZpY2UgaXMgVVApLCBVUkxFcnJvci1m
  >> "!B64TMP!" echo YW1pbHkgb24gY29ubmVjdGlvbgogICAgcHJvYmxlbXMgKHNlcnZpY2UgaXMgRE9XTikuIiIiCiAg
  >> "!B64TMP!" echo ICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCkKICAgIHdpdGggdXJsbGliLnJlcXVl
  >> "!B64TMP!" echo c3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9VElNRU9VVCkgYXMgcjoKICAgICAgICByZXR1cm4ganNv
  >> "!B64TMP!" echo bi5sb2FkKHIpCgoKZGVmIHNlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0aGUgRG9ja2VyIGVuZ2lu
  >> "!B64TMP!" echo ZSArIHRoZSBjb250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRoZSBzYW1lCiAgICBsb2dpYyBh
  >> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQgc28gdGhlIGZhc3QgcGF0aCAo
  >> "!B64TMP!" echo c3RhY2sKICAgIGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0dXJucyAob2ssIG1lc3NhZ2Up
  >> "!B64TMP!" echo LiIiIgogICAgdHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3RhY2sKICAgICAgICBvaywgbWVz
  >> "!B64TMP!" echo c2FnZSwgX2NvZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5KCkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo b2ssIG1lc3NhZ2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgdW5leHBlY3RlZCBzZWxm
  >> "!B64TMP!" echo LWhlYWwgZmFpbHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAgICAgcmV0dXJuIEZhbHNlLCAi
  >> "!B64TMP!" echo c2VsZi1oZWFsIGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3JtYXQoZSkKCgpkZWYgbWFpbigp
  >> "!B64TMP!" echo IC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGxpbWl0LCB0aW1lX3JhbmdlLCBj
  >> "!B64TMP!" echo YXRlZ29yaWVzID0gOCwgTm9uZSwgTm9uZQogICAgcXVlcnlfcGFydHMgPSBbXQogICAgaSA9IDAK
  >> "!B64TMP!" echo ICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBh
  >> "!B64TMP!" echo ID09ICItLWxpbWl0IjoKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGxpbWl0ID0gaW50
  >> "!B64TMP!" echo KGFyZ3NbaV0pCiAgICAgICAgZWxpZiBhID09ICItLXRpbWUtcmFuZ2UiOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdGltZV9yYW5nZSA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0g
  >> "!B64TMP!" echo Ii0tY2F0ZWdvcmllcyI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBjYXRlZ29yaWVz
  >> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcXVlcnlfcGFydHMuYXBwZW5kKGEp
  >> "!B64TMP!" echo CiAgICAgICAgaSArPSAxCiAgICBxdWVyeSA9ICIgIi5qb2luKHF1ZXJ5X3BhcnRzKS5zdHJpcCgp
  >> "!B64TMP!" echo CiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfc2VhcmNoLnB5ICJx
  >> "!B64TMP!" echo dWVyeSIgWy0tbGltaXQgTl0gWy0tdGltZS1yYW5nZSBSXSBbLS1jYXRlZ29yaWVzIENdJywgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgcGFyYW1zID0geyJxIjogcXVlcnks
  >> "!B64TMP!" echo ICJmb3JtYXQiOiAianNvbiIsICJsYW5ndWFnZSI6ICJlbiJ9CiAgICBpZiB0aW1lX3JhbmdlOgog
  >> "!B64TMP!" echo ICAgICAgIHBhcmFtc1sidGltZV9yYW5nZSJdID0gdGltZV9yYW5nZQogICAgaWYgY2F0ZWdvcmll
  >> "!B64TMP!" echo czoKICAgICAgICBwYXJhbXNbImNhdGVnb3JpZXMiXSA9IGNhdGVnb3JpZXMKICAgIHVybCA9IEJB
  >> "!B64TMP!" echo U0UgKyAiPyIgKyB1cmxsaWIucGFyc2UudXJsZW5jb2RlKHBhcmFtcykKCiAgICBkYXRhID0gTm9u
  >> "!B64TMP!" echo ZQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmZXRjaCh1cmwpCiAgICBleGNlcHQgdXJsbGliLmVy
  >> "!B64TMP!" echo cm9yLkhUVFBFcnJvciBhcyBlOgogICAgICAgICMgVGhlIHNlcnZpY2UgQU5TV0VSRUQgKGV2ZW4g
  >> "!B64TMP!" echo d2l0aCBhbiBlcnJvciBzdGF0dXMpIC0+IGl0IGlzIHVwOwogICAgICAgICMgc3RhcnRpbmcgY29u
  >> "!B64TMP!" echo dGFpbmVycyB3b3VsZCBub3QgaGVscC4KICAgICAgICBwcmludChmIlNFQVJDSCBGQUlMRUQ6IHtl
  >> "!B64TMP!" echo fSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiU2VhclhORyBhbnN3ZXJlZCB3aXRo
  >> "!B64TMP!" echo IGFuIGVycm9yIHN0YXR1cyAodGhlIHN0YWNrIGlzIHJ1bm5pbmcpLiAiCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IlJldHJ5IG9uY2Ugd2l0aCBhIGRpZmZlcmVudCBxdWVyeSwgb3IgaW5zcGVjdCB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2l0aDogIgogICAgICAgICAgICAgICJjZCA8aW5zdGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlIGxvZ3MgLS10YWlsIDUwIHNlYXJ4bmciLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMg
  >> "!B64TMP!" echo Q29ubmVjdGlvbiBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhl
  >> "!B64TMP!" echo YWwgb25jZSwKICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNlYXJjaC4KICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4u
  >> "!B64TMP!" echo LiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0g
  >> "!B64TMP!" echo c2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0VBUkNIIEZBSUxFRDogdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZC4gIgogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiUmVzb2x2ZSB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcCkgIgogICAgICAgICAgICAgICAgICAiYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNr
  >> "!B64TMP!" echo IHRvIG90aGVyIHdlYiB0b29scyB1bmxlc3MgdGhlICIKICAgICAgICAgICAgICAgICAgInVzZXIg
  >> "!B64TMP!" echo YXNrcy4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgICAgICBkYXRhID0gZmV0Y2godXJsKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g
  >> "!B64TMP!" echo YXMgZTI6CiAgICAgICAgICAgIHByaW50KGYiU0VBUkNIIEZBSUxFRCBhZnRlciB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2FzIHN0YXJ0ZWQ6IHtlMn0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAx
  >> "!B64TMP!" echo CgogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIiwgW10pWzpsaW1pdF0KICAgIGlmIG5v
  >> "!B64TMP!" echo dCByZXN1bHRzOgogICAgICAgIHByaW50KCIobm8gcmVzdWx0cykiKQogICAgICAgIHJldHVybiAw
  >> "!B64TMP!" echo CiAgICBmb3IgbiwgaGl0IGluIGVudW1lcmF0ZShyZXN1bHRzLCAxKToKICAgICAgICB0aXRsZSA9
  >> "!B64TMP!" echo IChoaXQuZ2V0KCJ0aXRsZSIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgcmVzdWx0X3VybCA9IGhp
  >> "!B64TMP!" echo dC5nZXQoInVybCIpIG9yICIiCiAgICAgICAgY29udGVudCA9IChoaXQuZ2V0KCJjb250ZW50Iikg
  >> "!B64TMP!" echo b3IgIiIpLnN0cmlwKCkucmVwbGFjZSgiXG4iLCAiICIpCiAgICAgICAgaWYgbGVuKGNvbnRlbnQp
  >> "!B64TMP!" echo ID4gMzAwOgogICAgICAgICAgICBjb250ZW50ID0gY29udGVudFs6MzAwXSArICLigKYiCiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoZiJ7bn0uIHt0aXRsZX0iKQogICAgICAgIHByaW50KGYiICAge3Jlc3VsdF91cmx9
  >> "!B64TMP!" echo IikKICAgICAgICBpZiBjb250ZW50OgogICAgICAgICAgICBwcmludChmIiAgIHtjb250ZW50fSIp
  >> "!B64TMP!" echo CiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdCht
  >> "!B64TMP!" echo YWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_scrape.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_scrape.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_scrape.py" "!TARGET!\local-web-search\scripts\web_scrape.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_scrape.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_scrape.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2895407752.b64"
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
  >> "!B64TMP!" echo Yi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9m
  >> "!B64TMP!" echo IHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gc2Ny
  >> "!B64TMP!" echo YXBlZCBwYWdlIGNvbnRlbnQgd2l0aCBub24tQVNDSUkgdGV4dCBuZXZlcgojIGNyYXNoZXMgd2l0
  >> "!B64TMP!" echo aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFs
  >> "!B64TMP!" echo cmVhZHkKIyBzZXQg4oCUIGFuIGV4cGxpY2l0IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlU
  >> "!B64TMP!" echo SE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lz
  >> "!B64TMP!" echo LnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25m
  >> "!B64TMP!" echo aWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZp
  >> "!B64TMP!" echo Z3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5w
  >> "!B64TMP!" echo YXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTog
  >> "!B64TMP!" echo aW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgojIFBvcnQgY29tZXMg
  >> "!B64TMP!" echo ZnJvbSBGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0
  >> "!B64TMP!" echo IDk5OTEpLgpFTkRQT0lOVCA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIoKSlbImZpcmVjcmF3bCJdICsgIi92MS9zY3JhcGUiCgpUSU1FT1VUID0gOTAgICMgc2Vjb25k
  >> "!B64TMP!" echo cyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJQT1NUIHRoZSBzY3Jh
  >> "!B64TMP!" echo cGUgcmVxdWVzdC4gUmFpc2VzIEhUVFBFcnJvciB3aGVuIHRoZSBzZXJ2aWNlIGFuc3dlcmVkCiAg
  >> "!B64TMP!" echo ICB3aXRoIGFuIGVycm9yIHN0YXR1cyAoc2VydmljZSBpcyBVUCksIFVSTEVycm9yLWZhbWlseSBv
  >> "!B64TMP!" echo biBjb25uZWN0aW9uCiAgICBwcm9ibGVtcyAoc2VydmljZSBpcyBET1dOKS4iIiIKICAgIGJvZHkg
  >> "!B64TMP!" echo PSBqc29uLmR1bXBzKHsidXJsIjogdXJsLCAiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pLmVuY29k
  >> "!B64TMP!" echo ZSgpCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KAogICAgICAgIEVORFBPSU5ULAog
  >> "!B64TMP!" echo ICAgICAgIGRhdGE9Ym9keSwKICAgICAgICBoZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxp
  >> "!B64TMP!" echo Y2F0aW9uL2pzb24ifSwKICAgICAgICBtZXRob2Q9IlBPU1QiLAogICAgKQogICAgd2l0aCB1cmxs
  >> "!B64TMP!" echo aWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91dD1USU1FT1VUKSBhcyByOgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBqc29uLmxvYWQocikKCgpkZWYgc2VsZmhlYWwoKToKICAgICIiIlN0YXJ0IHRoZSBEb2Nr
  >> "!B64TMP!" echo ZXIgZW5naW5lICsgdGhlIGNvbnRhaW5lcnMgaWYgdGhleSBhcmUgZG93biAodGhlIHNhbWUKICAg
  >> "!B64TMP!" echo IGxvZ2ljIGFzIGVuc3VyZV9zdGFjay5weSkuIEltcG9ydCBpcyBkZWZlcnJlZCBzbyB0aGUgZmFz
  >> "!B64TMP!" echo dCBwYXRoIChzdGFjawogICAgYWxyZWFkeSB1cCkgcGF5cyBub3RoaW5nLiBSZXR1cm5zIChvaywg
  >> "!B64TMP!" echo bWVzc2FnZSkuIiIiCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAg
  >> "!B64TMP!" echo IG9rLCBtZXNzYWdlLCBfY29kZSA9IGVuc3VyZV9zdGFjay5lbnN1cmVfcmVhZHkoKQogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBvaywgbWVzc2FnZQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyB1bmV4cGVj
  >> "!B64TMP!" echo dGVkIHNlbGYtaGVhbCBmYWlsdXJlOiBkZWdyYWRlIGdyYWNlZnVsbHkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UsICJzZWxmLWhlYWwgZmFpbGVkIHVuZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRl
  >> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
  >> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3Nj
  >> "!B64TMP!" echo cmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMgTl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0KICAgIG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0g
  >> "!B64TMP!" echo MQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBpZiBhcmdzW2ldID09ICItLW1heC1j
  >> "!B64TMP!" echo aGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
  >> "!B64TMP!" echo YXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkgKz0gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVy
  >> "!B64TMP!" echo bCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUg
  >> "!B64TMP!" echo c2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRoIGFuIGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7
  >> "!B64TMP!" echo CiAgICAgICAgIyBzdGFydGluZyBjb250YWluZXJzIHdvdWxkIG5vdCBoZWxwLgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICBwcmludCgiRmlyZWNyYXdsIGFuc3dlcmVkIHdpdGggYW4gZXJyb3Igc3RhdHVzICh0aGUg
  >> "!B64TMP!" echo c3RhY2sgaXMgcnVubmluZykuICIKICAgICAgICAgICAgICAiUmV0cnkgb25jZSB3aXRoIGEgZGlm
  >> "!B64TMP!" echo ZmVyZW50IHJlc3VsdCBVUkwsIG9yIGluc3BlY3QgdGhlIHN0YWNrICIKICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo d2l0aDogY2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1
  >> "!B64TMP!" echo MCAiCiAgICAgICAgICAgICAgImZpcmVjcmF3bCIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgQ29ubmVjdGlvbiBl
  >> "!B64TMP!" echo cnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwKICAg
  >> "!B64TMP!" echo ICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFwZS4KICAgICAgICBwcmludChmIlN0YWNrIHVucmVh
  >> "!B64TMP!" echo Y2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwoKQog
  >> "!B64TMP!" echo ICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgICAgICBwcmludCgiU0NSQVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIKICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQuIFJl
  >> "!B64TMP!" echo c29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCByZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBv
  >> "!B64TMP!" echo dGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAgICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFza3Mu
  >> "!B64TMP!" echo Ii5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAg
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgICAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBwcmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9
  >> "!B64TMP!" echo IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDoge2UyfSIsCiAgICAgICAgICAgICAgICAgIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEKCiAgICBwYXlsb2FkID0gZGF0YS5n
  >> "!B64TMP!" echo ZXQoImRhdGEiKSBvciB7fQogICAgbWFya2Rvd24gPSBwYXlsb2FkLmdldCgibWFya2Rvd24iKSBv
  >> "!B64TMP!" echo ciAiIiBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGVsc2UgIiIKICAgIGlmIG5vdCBtYXJr
  >> "!B64TMP!" echo ZG93bjoKICAgICAgICBwcmludCgiU0NSQVBFIFJFVFVSTkVEIE5PIE1BUktET1dOIGZvciIsIHVy
  >> "!B64TMP!" echo bCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSlbOjgwMF0s
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGxlbihtYXJrZG93bikg
  >> "!B64TMP!" echo PiBtYXhfY2hhcnM6CiAgICAgICAgbWFya2Rvd24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSArIGYi
  >> "!B64TMP!" echo XG5cblsuLi4gdHJ1bmNhdGVkIGF0IHttYXhfY2hhcnN9IGNoYXJzIC4uLl0iCiAgICBwcmludCht
  >> "!B64TMP!" echo YXJrZG93bikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5
  >> "!B64TMP!" echo cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_scrape.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_extract.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_extract.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_extract.py" "!TARGET!\local-web-search\scripts\web_extract.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_extract.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_extract.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3639765009.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMTE0gZXh0cmFjdGlvbiBmcm9tIG9uZSBvciBtb3Jl
  >> "!B64TMP!" echo IFVSTHMgdmlhIHRoZSBsb2NhbCBGaXJlY3Jhd2wgL3YxL2V4dHJhY3QKZW5kcG9pbnQuCgpSdW5z
  >> "!B64TMP!" echo IG9uIHRoZSBPcGVuQUktY29tcGF0aWJsZSBMTE0gY29ubmVjdGVkIGluIHRoZSBpbnN0YWxsZXIK
  >> "!B64TMP!" echo KE9QRU5BSV9CQVNFX1VSTCAvIE9QRU5BSV9BUElfS0VZIC8gTU9ERUxfTkFNRSBpbiB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIncwouZW52KTsgdGhlIGVuZHBvaW50IG1heSBiZSBsb2NhbCBvciByZW1vdGUu
  >> "!B64TMP!" echo IFdpdGhvdXQgYSBjb25maWd1cmVkIExMTSB0aGUKZW5kcG9pbnQgZmFpbHMgd2l0aCBhICJtb2Rl
  >> "!B64TMP!" echo bCBub3QgY29uZmlndXJlZCIgZXJyb3IsIHdoaWNoIGlzIGV4cGVjdGVkIGFuZApub3QgYSBzdGFj
  >> "!B64TMP!" echo ayBmYWlsdXJlLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2V4dHJhY3QucHkgPHVybD4gW3VybCAu
  >> "!B64TMP!" echo Li5dIC0tcHJvbXB0ICJ3aGF0IHRvIGV4dHJhY3QiIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlm
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IK
  >> "!B64TMP!" echo dGhlIGNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0
  >> "!B64TMP!" echo cyB0aGVtICh0aGUgc2FtZQpsb2dpYyBhcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQg
  >> "!B64TMP!" echo cmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbgpmYWlsdXJlcyBzZWxmLWhlYWwgb25jZTsg
  >> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQKYmFja29m
  >> "!B64TMP!" echo Zi4gWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3Qg
  >> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgpQcmludHMgdGhlIGV4dHJhY3RlZCByZXN1bHQgKHRoZSBgZGF0YWAg
  >> "!B64TMP!" echo ZmllbGQgb2YgdGhlIHJlc3BvbnNlKS4gYC0tanNvbmAKcHJpbnRzIHRoZSBmdWxsIHJhdyBBUEkg
  >> "!B64TMP!" echo cmVzcG9uc2UgaW5zdGVhZC4KRXhpdCBjb2RlczogMCBzdWNjZXNzLCAxIHRvb2wgZmFpbHVyZSwg
  >> "!B64TMP!" echo MiB1c2FnZSBlcnJvci4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJn
  >> "!B64TMP!" echo dlsxOl0KICAgIHVybHMgPSBbXQogICAgcHJvbXB0ID0gTm9uZQogICAgYXNfanNvbiA9IEZhbHNl
  >> "!B64TMP!" echo CiAgICBpID0gMAogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBhID0gYXJnc1tpXQog
  >> "!B64TMP!" echo ICAgICAgIGlmIGEgPT0gIi0tcHJvbXB0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICBwcm9tcHQgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09
  >> "!B64TMP!" echo ICItLWpzb24iOgogICAgICAgICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFy
  >> "!B64TMP!" echo dHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgdXJscy5hcHBlbmQoYSkKICAgICAgICBpICs9IDEKCiAgICBpZiBub3QgdXJscyBvciBu
  >> "!B64TMP!" echo b3QgcHJvbXB0OgogICAgICAgIHByaW50KCd1c2FnZTogd2ViX2V4dHJhY3QucHkgPHVybD4gW3Vy
  >> "!B64TMP!" echo bCAuLi5dIC0tcHJvbXB0ICJ3aGF0IHRvIGV4dHJhY3QiIFstLWpzb25dJywKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKCiAgICB0cnk6CiAgICAgICAgZGF0
  >> "!B64TMP!" echo YSA9IGZjLmNhbGwoIi92MS9leHRyYWN0IiwgbWV0aG9kPSJQT1NUIiwKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBib2R5PXsidXJscyI6IHVybHMsICJwcm9tcHQiOiBwcm9tcHR9KQogICAgZXhjZXB0
  >> "!B64TMP!" echo IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkVYVFJBQ1QgRkFJTEVEIGZvciB7Jywg
  >> "!B64TMP!" echo Jy5qb2luKHVybHMpfToge2V9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGlmIGUuaGludDoK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDEKCiAgICBpZiBub3QgZGF0YS5nZXQoInN1Y2Nlc3MiLCBUcnVlKSBhbmQgbm90IGRhdGEuZ2V0
  >> "!B64TMP!" echo KCJkYXRhIik6CiAgICAgICAgcHJpbnQoIkVYVFJBQ1QgRkFJTEVEIGZvciB7fTogbm8gZGF0YSBy
  >> "!B64TMP!" echo ZXR1cm5lZC4gUmVzcG9uc2U6ICIKICAgICAgICAgICAgICAuZm9ybWF0KCIsICIuam9pbih1cmxz
  >> "!B64TMP!" echo KSksIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpWzo4MDBd
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KGpzb24u
  >> "!B64TMP!" echo ZHVtcHMoZGF0YS5nZXQoImRhdGEiKSwgaW5kZW50PTIsIGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAg
  >> "!B64TMP!" echo ICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWlu
  >> "!B64TMP!" echo KCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_extract.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_youtube_transcript.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_youtube_transcript.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_youtube_transcript.py" "!TARGET!\local-web-search\scripts\web_youtube_transcript.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_youtube_transcript.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_youtube_transcript.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1252984784.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGZXRjaCBhIFlvdVR1YmUgdmlkZW8ncyB0cmFuc2Ny
  >> "!B64TMP!" echo aXB0IGFuZCBwcmludCBpdCB3aXRoIHRpbWVzdGFtcHMuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo eW91dHViZV90cmFuc2NyaXB0LnB5IDx2aWRlb19pZD4KClJlcXVpcmVzIHRoZSB5b3V0dWJlLXRy
  >> "!B64TMP!" echo YW5zY3JpcHQtYXBpIHBhY2thZ2U6CiAgICBwaXAgaW5zdGFsbCB5b3V0dWJlLXRyYW5zY3JpcHQt
  >> "!B64TMP!" echo YXBpCgpQcmludHMgZWFjaCBjYXB0aW9uIGxpbmUgYXMgYFtNTTpTU10gdGV4dGAuCiIiIgppbXBv
  >> "!B64TMP!" echo cnQgb3MKaW1wb3J0IHN5cwoKIyBEZWZhdWx0IHN0ZG91dC9zdGRlcnIgdG8gVVRGLTggcmVnYXJk
  >> "!B64TMP!" echo bGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUvY29kZXBhZ2UKIyAoZS5nLiBXaW5kb3dzIGNwMTI1Miks
  >> "!B64TMP!" echo IHNvIHRyYW5zY3JpcHRzIHdpdGggbm9uLUFTQ0lJIHRleHQgbmV2ZXIgY3Jhc2gKIyB3aXRoIGEg
  >> "!B64TMP!" echo VW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFk
  >> "!B64TMP!" echo eSBzZXQg4oCUCiMgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3YXlzIHdpbnMuCmlmICJQWVRIT05J
  >> "!B64TMP!" echo T0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZvciBfc3RyZWFtIGluIChzeXMuc3Rk
  >> "!B64TMP!" echo b3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRyKF9zdHJlYW0sICJyZWNvbmZpZ3Vy
  >> "!B64TMP!" echo ZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBfc3RyZWFtLnJlY29uZmlndXJl
  >> "!B64TMP!" echo KGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBwYXNzCgp0cnk6CiAgICBmcm9tIHlvdXR1YmVfdHJhbnNjcmlwdF9hcGkgaW1wb3J0
  >> "!B64TMP!" echo IFlvdVR1YmVUcmFuc2NyaXB0QXBpCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIFlvdVR1YmVUcmFu
  >> "!B64TMP!" echo c2NyaXB0QXBpID0gTm9uZQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2
  >> "!B64TMP!" echo WzE6XQogICAgaWYgbm90IGFyZ3M6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfeW91dHViZV90
  >> "!B64TMP!" echo cmFuc2NyaXB0LnB5IDx2aWRlb19pZD4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDIKICAgIHZpZGVvX2lkID0gYXJnc1swXQoKICAgIGlmIFlvdVR1YmVUcmFuc2NyaXB0QXBpIGlz
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcHJpbnQoIlRSQU5TQ1JJUFQgRkFJTEVEOiB0aGUgeW91dHViZS10cmFu
  >> "!B64TMP!" echo c2NyaXB0LWFwaSBwYWNrYWdlIGlzIG5vdCAiCiAgICAgICAgICAgICAgImluc3RhbGxlZC4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcHJpbnQoIkluc3RhbGwgaXQgd2l0aDogcGlwIGluc3Rh
  >> "!B64TMP!" echo bGwgeW91dHViZS10cmFuc2NyaXB0LWFwaSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAxCgogICAgdHJ5OgogICAgICAgIHlvdXR1YmVfdHJhbnNjcmlwdF9h
  >> "!B64TMP!" echo cGkgPSBZb3VUdWJlVHJhbnNjcmlwdEFwaSgpCiAgICAgICAgdHJhbnNjcmlwdCA9IHlvdXR1YmVf
  >> "!B64TMP!" echo dHJhbnNjcmlwdF9hcGkuZmV0Y2godmlkZW9faWQpCiAgICAgICAgZm9yIHNlZ21lbnQgaW4gdHJh
  >> "!B64TMP!" echo bnNjcmlwdC5zbmlwcGV0czoKICAgICAgICAgICAgbWlucyA9IGludChzZWdtZW50LnN0YXJ0KSAv
  >> "!B64TMP!" echo LyA2MAogICAgICAgICAgICBzZWNzID0gaW50KHNlZ21lbnQuc3RhcnQpICUgNjAKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoZiJbe21pbnM6MDJkfTp7c2VjczowMmR9XSB7c2VnbWVudC50ZXh0fSIpCiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIDAKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBwcmludChmIkVy
  >> "!B64TMP!" echo cm9yOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCgppZiBfX25hbWVf
  >> "!B64TMP!" echo XyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_youtube_transcript.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_map.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_map.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_map.py" "!TARGET!\local-web-search\scripts\web_map.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_map.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_map.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3466815660.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJNYXAgYSB3ZWJzaXRlOiBlbnVtZXJhdGUgdGhlIFVS
  >> "!B64TMP!" echo THMgRmlyZWNyYXdsIGluZGV4ZXMgdW5kZXIgaXQsIHdpdGhvdXQKZmV0Y2hpbmcgZWFjaCBwYWdl
  >> "!B64TMP!" echo J3MgY29udGVudCAodGhlIGZpcmVjcmF3bF9tYXAgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRo
  >> "!B64TMP!" echo b24gd2ViX21hcC5weSA8dXJsPiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQgTl0gWy0tanNvbl0K
  >> "!B64TMP!" echo ClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAo
  >> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1
  >> "!B64TMP!" echo dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5w
  >> "!B64TMP!" echo eSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVz
  >> "!B64TMP!" echo CnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdp
  >> "!B64TMP!" echo dGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5w
  >> "!B64TMP!" echo eSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KCmAtLXNlYXJjaGAgZmlsdGVycy9ib29z
  >> "!B64TMP!" echo dHMgVVJMcyBjb250YWluaW5nIHRoZSB0ZXJtIChzZXJ2ZXItc2lkZSkuIFByaW50cyB1cAp0byBg
  >> "!B64TMP!" echo bGltaXRgIFVSTHMgKGRlZmF1bHQgMTAwKSwgb25lIHBlciBsaW5lLCBudW1iZXJlZC4gYC0tanNv
  >> "!B64TMP!" echo bmAgcHJpbnRzIHRoZQpyYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgpp
  >> "!B64TMP!" echo bXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShv
  >> "!B64TMP!" echo cy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMg
  >> "!B64TMP!" echo c2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZj
  >> "!B64TMP!" echo LnVybCgiL3YxL21hcCIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3Zb
  >> "!B64TMP!" echo MTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoInVzYWdlOiB3ZWJfbWFwLnB5IDx1cmw+IFstLXNlYXJjaCB0ZXJtXSBbLS1saW1pdCBO
  >> "!B64TMP!" echo XSBbLS1qc29uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVy
  >> "!B64TMP!" echo biAyCiAgICB1cmwgPSBhcmdzWzBdCiAgICBzZWFyY2gsIGxpbWl0LCBhc19qc29uID0gTm9uZSwg
  >> "!B64TMP!" echo MTAwLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9
  >> "!B64TMP!" echo IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXNlYXJjaCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo OgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2VhcmNoID0gYXJnc1tpXQogICAgICAg
  >> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgbGltaXQgPSBpbnQoYXJnc1tp
  >> "!B64TMP!" echo XSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChm
  >> "!B64TMP!" echo ImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAgICAgIGFz
  >> "!B64TMP!" echo X2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhwZWN0ZWQg
  >> "!B64TMP!" echo YXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDIKICAg
  >> "!B64TMP!" echo ICAgICBpICs9IDEKCiAgICBib2R5ID0geyJ1cmwiOiB1cmx9CiAgICBpZiBzZWFyY2g6CiAgICAg
  >> "!B64TMP!" echo ICAgYm9keVsic2VhcmNoIl0gPSBzZWFyY2gKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNh
  >> "!B64TMP!" echo bGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNF
  >> "!B64TMP!" echo cnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTUFQIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGlu
  >> "!B64TMP!" echo dCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAg
  >> "!B64TMP!" echo ICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbGlua3Mg
  >> "!B64TMP!" echo PSBkYXRhLmdldCgibGlua3MiKQogICAgaWYgbGlua3MgaXMgTm9uZToKICAgICAgICBwYXlsb2Fk
  >> "!B64TMP!" echo ID0gZGF0YS5nZXQoImRhdGEiKQogICAgICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCk6
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGxpbmtzID0gcGF5bG9hZC5nZXQoImxpbmtzIikKICAgIGlmIG5vdCBpc2lu
  >> "!B64TMP!" echo c3RhbmNlKGxpbmtzLCBsaXN0KToKICAgICAgICBsaW5rcyA9IFtdCiAgICBpZiBub3QgbGlua3M6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoIihubyBVUkxzIGZvdW5kKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZv
  >> "!B64TMP!" echo ciBuLCBsaW5rIGluIGVudW1lcmF0ZShsaW5rc1s6bGltaXRdLCAxKToKICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IntufS4ge2xpbmt9IikKICAgIGlmIGxlbihsaW5rcykgPiBsaW1pdDoKICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IlsuLi4ge2xlbihsaW5rcykgLSBsaW1pdH0gbW9yZSBVUkxzOyByYWlzZSAtLWxpbWl0IG9yIHVz
  >> "!B64TMP!" echo ZSAtLWpzb24gLi4uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgcmV0dXJu
  >> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_map.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_crawl.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_crawl.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_crawl.py" "!TARGET!\local-web-search\scripts\web_crawl.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_crawl.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_crawl.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3421326922.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSdW4gYSBzaXRlIGNyYXdsOiBzdGFydCBhIG11bHRp
  >> "!B64TMP!" echo LXBhZ2UgRmlyZWNyYXdsIGNyYXdsIGF0IGEgVVJMLCBwb2xsIGl0IHRvCmEgdGVybWluYWwgc3Rh
  >> "!B64TMP!" echo dGUsIGFuZCByZXBvcnQgdGhlIGZpbmFsIHN0YXR1cyBhbmQgY29sbGVjdGVkIGRhdGEgKHRoZQpm
  >> "!B64TMP!" echo aXJlY3Jhd2xfY3Jhd2wgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2NyYXdsLnB5
  >> "!B64TMP!" echo IDx1cmw+IFstLWxpbWl0IE5dIFstLXRpbWVvdXQgU10gWy0tcG9sbC1pbnRlcnZhbCBTXQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dIFstLWpz
  >> "!B64TMP!" echo b25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFi
  >> "!B64TMP!" echo bGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlw
  >> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWls
  >> "!B64TMP!" echo dXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmll
  >> "!B64TMP!" echo ZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQb2xscyB0aGUgY3Jhd2wgZXZl
  >> "!B64TMP!" echo cnkgLS1wb2xsLWludGVydmFsIHNlY29uZHMgKGRlZmF1bHQgMikgdW50aWwgaXQgcmVhY2hlcyBh
  >> "!B64TMP!" echo CnRlcm1pbmFsIHN0YXRlIChjb21wbGV0ZWQgLyBmYWlsZWQgLyBjYW5jZWxsZWQpIG9yIC0tdGlt
  >> "!B64TMP!" echo ZW91dCBzZWNvbmRzIGVsYXBzZQooZGVmYXVsdCAzMDApLiBQcm9ncmVzcyBpcyBwcmludGVkIHRv
  >> "!B64TMP!" echo IHN0ZGVyci4gV2hlbiB0aGUgY3Jhd2wgY29tcGxldGVzLCBlYWNoCmNvbGxlY3RlZCBwYWdlIHBy
  >> "!B64TMP!" echo aW50cyBhcyBgTi4gPHVybD5gIGZvbGxvd2VkIGJ5IGl0cyBtYXJrZG93biB0cnVuY2F0ZWQgYXQK
  >> "!B64TMP!" echo LS1tYXgtY2hhcnMgY2hhcnMgKGRlZmF1bHQgMjAwMDsgdXAgdG8gLS1tYXgtcGFnZXMgcGFnZXMs
  >> "!B64TMP!" echo IGRlZmF1bHQgMjUpLgpgLS1qc29uYCBwcmludHMgdGhlIGZpbmFsIHN0YXR1cyByZXNwb25zZSBp
  >> "!B64TMP!" echo bnN0ZWFkLgoKSWYgdGhlIGNyYXdsIGhhcyBub3QgZmluaXNoZWQgd2l0aGluIC0tdGltZW91dCwg
  >> "!B64TMP!" echo dGhlIGNyYXdsIElEIGFuZCBjdXJyZW50CnByb2dyZXNzIGFyZSBwcmludGVkIOKAlCBrZWVwIHBv
  >> "!B64TMP!" echo bGxpbmcgd2l0aCB3ZWJfY3Jhd2xfc3RhdHVzLnB5IDxpZD4uCiIiIgppbXBvcnQganNvbgppbXBv
  >> "!B64TMP!" echo cnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGgu
  >> "!B64TMP!" echo ZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkg
  >> "!B64TMP!" echo YXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQ
  >> "!B64TMP!" echo T0lOVCA9IGZjLnVybCgiL3YxL2NyYXdsIikKCiMgQ3Jhd2wtam9iIHN0YXRlcyB0aGF0IG1lYW4g
  >> "!B64TMP!" echo Im5vIG1vcmUgcG9sbGluZyIuClRFUk1JTkFMID0gKCJjb21wbGV0ZWQiLCAiZmFpbGVkIiwgImNh
  >> "!B64TMP!" echo bmNlbGxlZCIsICJzdG9wcGVkIikKCgpkZWYgY3Jhd2xfc3VtbWFyeShkYXRhKToKICAgICIiIk9u
  >> "!B64TMP!" echo ZS1saW5lIHN0YXR1cyBzdW1tYXJ5IGZyb20gYSBjcmF3bC1zdGF0dXMgcGF5bG9hZC4iIiIKICAg
  >> "!B64TMP!" echo IHN0YXR1cyA9IGRhdGEuZ2V0KCJzdGF0dXMiKSBvciAidW5rbm93biIKICAgIGNvbXBsZXRlZCA9
  >> "!B64TMP!" echo IGRhdGEuZ2V0KCJjb21wbGV0ZWQiKQogICAgdG90YWwgPSBkYXRhLmdldCgidG90YWwiKQogICAg
  >> "!B64TMP!" echo aWYgY29tcGxldGVkIGlzIG5vdCBOb25lIGFuZCB0b3RhbCBpcyBub3QgTm9uZToKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gZiJ7c3RhdHVzfSAoe2NvbXBsZXRlZH0ve3RvdGFsfSBwYWdlcykiCiAgICByZXR1cm4g
  >> "!B64TMP!" echo c3RyKHN0YXR1cykKCgpkZWYgcHJpbnRfcGFnZXMoZGF0YSwgbWF4X3BhZ2VzLCBtYXhfY2hhcnMp
  >> "!B64TMP!" echo OgogICAgIiIiUHJpbnQgdGhlIGNvbGxlY3RlZCBwYWdlczogYE4uIDx1cmw+YCArIHRydW5jYXRl
  >> "!B64TMP!" echo ZCBtYXJrZG93bi4iIiIKICAgIHBhZ2VzID0gZGF0YS5nZXQoImRhdGEiKQogICAgaWYgbm90IGlz
  >> "!B64TMP!" echo aW5zdGFuY2UocGFnZXMsIGxpc3QpIG9yIG5vdCBwYWdlczoKICAgICAgICByZXR1cm4KICAgIHNo
  >> "!B64TMP!" echo b3duID0gcGFnZXNbOm1heF9wYWdlc10KICAgIGZvciBuLCBwYWdlIGluIGVudW1lcmF0ZShzaG93
  >> "!B64TMP!" echo biwgMSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UocGFnZSwgZGljdCk6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGNvbnRpbnVlCiAgICAgICAgbWV0YWRhdGEgPSBwYWdlLmdldCgibWV0YWRhdGEiKQogICAgICAg
  >> "!B64TMP!" echo IGlmIG5vdCBpc2luc3RhbmNlKG1ldGFkYXRhLCBkaWN0KToKICAgICAgICAgICAgbWV0YWRhdGEg
  >> "!B64TMP!" echo PSB7fQogICAgICAgIHVybCA9IHBhZ2UuZ2V0KCJ1cmwiKSBvciBwYWdlLmdldCgic291cmNlVVJM
  >> "!B64TMP!" echo IikgXAogICAgICAgICAgICBvciBtZXRhZGF0YS5nZXQoInVybCIpIG9yIG1ldGFkYXRhLmdldCgi
  >> "!B64TMP!" echo c291cmNlVVJMIikgb3IgIihubyB1cmwpIgogICAgICAgIHByaW50KGYie259LiB7dXJsfSIpCiAg
  >> "!B64TMP!" echo ICAgICAgbWFya2Rvd24gPSBwYWdlLmdldCgibWFya2Rvd24iKSBvciAiIgogICAgICAgIGlmIG1h
  >> "!B64TMP!" echo cmtkb3duOgogICAgICAgICAgICBpZiBsZW4obWFya2Rvd24pID4gbWF4X2NoYXJzOgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgbWFya2Rvd24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSBcCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgKyBmIlxuICAgWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIK
  >> "!B64TMP!" echo ICAgICAgICAgICAgZm9yIGxpbmUgaW4gbWFya2Rvd24uc3BsaXRsaW5lcygpIG9yIFsiIl06CiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludChmIiAgIHtsaW5lfSIpCiAgICBpZiBsZW4ocGFnZXMpID4gbWF4
  >> "!B64TMP!" echo X3BhZ2VzOgogICAgICAgIHByaW50KGYiWy4uLiB7bGVuKHBhZ2VzKSAtIG1heF9wYWdlc30gbW9y
  >> "!B64TMP!" echo ZSBwYWdlczsgcmFpc2UgLS1tYXgtcGFnZXMgIgogICAgICAgICAgICAgIGYib3IgdXNlIC0tanNv
  >> "!B64TMP!" echo biAuLi5dIiwgZmlsZT1zeXMuc3RkZXJyKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9
  >> "!B64TMP!" echo IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIp
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2NyYXdsLnB5IDx1cmw+IFstLWxpbWl0IE5dIFst
  >> "!B64TMP!" echo LXRpbWVvdXQgU10gIgogICAgICAgICAgICAgICJbLS1wb2xsLWludGVydmFsIFNdIFstLW1heC1w
  >> "!B64TMP!" echo YWdlcyBOXSBbLS1tYXgtY2hhcnMgTl0gWy0tanNvbl0iLAogICAgICAgICAgICAgIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgdXJsID0gYXJnc1swXQogICAgbGltaXQgPSBO
  >> "!B64TMP!" echo b25lCiAgICB0aW1lb3V0LCBwb2xsX2V2ZXJ5ID0gMzAwLCAyCiAgICBtYXhfcGFnZXMsIG1heF9j
  >> "!B64TMP!" echo aGFycywgYXNfanNvbiA9IDI1LCAyMDAwLCBGYWxzZQogICAgaSA9IDEKCiAgICBkZWYgbnVtKG5h
  >> "!B64TMP!" echo bWUpOgogICAgICAgICMgYGlgIGFscmVhZHkgcG9pbnRzIGF0IHRoZSBvcHRpb24ncyB2YWx1ZSAo
  >> "!B64TMP!" echo dGhlIGJyYW5jaCBpbmNyZW1lbnRlZCBpdCkuCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gaW50KGFyZ3NbaV0pCiAgICAgICAgZXhjZXB0IChWYWx1ZUVycm9yLCBJbmRleEVycm9yKToK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcHJpbnQoZiJpbnZhbGlkIHtuYW1lfToge2FyZ3NbaV0gaWYgaSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKSBlbHNlICcnfSIsCiAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3lzLmV4aXQoMikKCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAgIGEgPSBh
  >> "!B64TMP!" echo cmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgbGltaXQgPSBudW0oIi0tbGltaXQiKQogICAg
  >> "!B64TMP!" echo ICAgIGVsaWYgYSA9PSAiLS10aW1lb3V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICB0aW1lb3V0ID0gbnVtKCItLXRpbWVvdXQiKQogICAgICAg
  >> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1wb2xsLWludGVydmFsIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIGkgKz0gMQogICAgICAgICAgICBwb2xsX2V2ZXJ5ID0gbnVtKCItLXBvbGwtaW50ZXJ2
  >> "!B64TMP!" echo YWwiKQogICAgICAgIGVsaWYgYSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8IGxlbihhcmdz
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIG1heF9wYWdlcyA9IG51bSgiLS1tYXgt
  >> "!B64TMP!" echo cGFnZXMiKQogICAgICAgIGVsaWYgYSA9PSAiLS1tYXgtY2hhcnMiIGFuZCBpICsgMSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIG1heF9jaGFycyA9IG51bSgiLS1t
  >> "!B64TMP!" echo YXgtY2hhcnMiKQogICAgICAgIGVsaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNv
  >> "!B64TMP!" echo biA9IFRydWUKICAgICAgICBlbGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJp
  >> "!B64TMP!" echo bnQoZiJ1bmtub3duIG9wdGlvbjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1
  >> "!B64TMP!" echo bWVudDoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQoKICAgIGJvZHkgPSB7InVybCI6IHVybH0KICAgIGlmIGxpbWl0OgogICAgICAgIGJv
  >> "!B64TMP!" echo ZHlbImxpbWl0Il0gPSBsaW1pdAoKICAgICMgLS0tLSBzdGFydCB0aGUgY3Jhd2wgLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICB0cnk6CiAgICAgICAg
  >> "!B64TMP!" echo c3RhcnRlZCA9IGZjLmNhbGwoIi92MS9jcmF3bCIsIG1ldGhvZD0iUE9TVCIsIGJvZHk9Ym9keSkK
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBGQUlMRUQg
  >> "!B64TMP!" echo Zm9yIHt1cmx9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAg
  >> "!B64TMP!" echo ICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQog
  >> "!B64TMP!" echo ICAgY3Jhd2xfaWQgPSBzdGFydGVkLmdldCgiaWQiKSBvciAoc3RhcnRlZC5nZXQoImRhdGEiKSBv
  >> "!B64TMP!" echo ciB7fSkuZ2V0KCJpZCIpCiAgICBpZiBub3QgY3Jhd2xfaWQ6CiAgICAgICAgcHJpbnQoIkNSQVdM
  >> "!B64TMP!" echo IEZBSUxFRCBmb3Ige306IHRoZSBBUEkgZGlkIG5vdCByZXR1cm4gYSBjcmF3bCBpZC4gIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICJSZXNwb25zZToiLmZvcm1hdCh1cmwpLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoanNvbi5kdW1wcyhzdGFydGVkKVs6ODAwXSwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCiAgICBwcmludChmIkNyYXdsIHN0YXJ0ZWQ6IHtjcmF3bF9pZH0iLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCgogICAgIyAtLS0tIHBvbGwgdG8gYSB0ZXJtaW5hbCBzdGF0ZSAtLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgIGRlYWRsaW5lID0gdGltZS50aW1l
  >> "!B64TMP!" echo KCkgKyB0aW1lb3V0CiAgICB3aGlsZSBUcnVlOgogICAgICAgIHRyeToKICAgICAgICAgICAgZGF0
  >> "!B64TMP!" echo YSA9IGZjLmNhbGwoIi92MS9jcmF3bC8iICsgc3RyKGNyYXdsX2lkKSwgbWV0aG9kPSJHRVQiKQog
  >> "!B64TMP!" echo ICAgICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgICAgIHByaW50KGYiQ1JBV0wg
  >> "!B64TMP!" echo RkFJTEVEIGZvciB7dXJsfTogc3RhdHVzIGNoZWNrIGZhaWxlZDoge2V9IiwKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEK
  >> "!B64TMP!" echo ICAgICAgICBzdGF0dXMgPSBzdHIoZGF0YS5nZXQoInN0YXR1cyIpIG9yICJ1bmtub3duIikKICAg
  >> "!B64TMP!" echo ICAgICBpZiBzdGF0dXMgaW4gVEVSTUlOQUwgb3IgKHN0YXR1cyBub3QgaW4KICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICgiYWN0aXZlIiwgInNjcmFwaW5nIiwgInF1ZXVlZCIsICJw
  >> "!B64TMP!" echo cm9jZXNzaW5nIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAid2FpdGluZyIs
  >> "!B64TMP!" echo ICJydW5uaW5nIikgYW5kIGRhdGEuZ2V0KCJkYXRhIikpOgogICAgICAgICAgICBicmVhawogICAg
  >> "!B64TMP!" echo ICAgIGlmIHRpbWUudGltZSgpID49IGRlYWRsaW5lOgogICAgICAgICAgICBwcmludChmIkNyYXds
  >> "!B64TMP!" echo IHtjcmF3bF9pZH0gc3RpbGwge2NyYXdsX3N1bW1hcnkoZGF0YSl9IGFmdGVyICIKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZiJ7dGltZW91dH1zIOKAlCBrZWVwaW5nIHBvbGxpbmcgd2l0aDoiLCBmaWxlPXN5
  >> "!B64TMP!" echo cy5zdGRlcnIpCiAgICAgICAgICAgIHByaW50KGYiICAgIHB5dGhvbiB3ZWJfY3Jhd2xfc3RhdHVz
  >> "!B64TMP!" echo LnB5IHtjcmF3bF9pZH0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIGFzX2pzb246
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgICAgICBlbHNl
  >> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgcHJpbnQoZiJDcmF3bCB7Y3Jhd2xfaWR9OiB7Y3Jhd2xfc3VtbWFy
  >> "!B64TMP!" echo eShkYXRhKX0gKHRpbWVkIG91dCkiKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHByaW50
  >> "!B64TMP!" echo KGYiICBjcmF3bCB7Y3Jhd2xfaWR9OiB7Y3Jhd2xfc3VtbWFyeShkYXRhKX0iLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgdGltZS5zbGVlcChtYXgocG9sbF9ldmVyeSwgMSkpCgogICAgaWYgYXNf
  >> "!B64TMP!" echo anNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwIGlm
  >> "!B64TMP!" echo IHN0YXR1cyA9PSAiY29tcGxldGVkIiBlbHNlIDEKCiAgICBpZiBzdGF0dXMgIT0gImNvbXBsZXRl
  >> "!B64TMP!" echo ZCI6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBGQUlMRUQgZm9yIHt1cmx9OiBjcmF3bCB7Y3Jhd2xf
  >> "!B64TMP!" echo aWR9IGVuZGVkIGFzICIKICAgICAgICAgICAgICBmIlwie3N0YXR1c31cIi4iLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKVs6ODAwXSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAxCgogICAgY3JlZGl0cyA9IGRhdGEuZ2V0KCJjcmVkaXRzVXNl
  >> "!B64TMP!" echo ZCIpCiAgICBzdWZmaXggPSBmIiwge2NyZWRpdHN9IGNyZWRpdHMgdXNlZCIgaWYgY3JlZGl0cyBp
  >> "!B64TMP!" echo cyBub3QgTm9uZSBlbHNlICIiCiAgICBwcmludChmIkNyYXdsIHtjcmF3bF9pZH06IHtjcmF3bF9z
  >> "!B64TMP!" echo dW1tYXJ5KGRhdGEpfXtzdWZmaXh9IikKICAgIHByaW50X3BhZ2VzKGRhdGEsIG1heF9wYWdlcywg
  >> "!B64TMP!" echo bWF4X2NoYXJzKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAg
  >> "!B64TMP!" echo c3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_crawl.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_crawl_status.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_crawl_status.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_crawl_status.py" "!TARGET!\local-web-search\scripts\web_crawl_status.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_crawl_status.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_crawl_status.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1135706177.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHN0YXR1cywgcHJvZ3Jlc3MsIGFuZCBh
  >> "!B64TMP!" echo dmFpbGFibGUgcmVzdWx0cyBvZiBhbiBleGlzdGluZyBGaXJlY3Jhd2wKY3Jhd2wgKHRoZSBmaXJl
  >> "!B64TMP!" echo Y3Jhd2xfY2hlY2tfY3Jhd2xfc3RhdHVzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdl
  >> "!B64TMP!" echo Yl9jcmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dIFst
  >> "!B64TMP!" echo LWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFj
  >> "!B64TMP!" echo aGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNj
  >> "!B64TMP!" echo cmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBm
  >> "!B64TMP!" echo YWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0
  >> "!B64TMP!" echo cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMgYENyYXdsIDxp
  >> "!B64TMP!" echo ZD46IDxzdGF0dXM+IChjb21wbGV0ZWQvdG90YWwgcGFnZXMpYDsgd2hlbiB0aGUgY3Jhd2wgaGFz
  >> "!B64TMP!" echo CmZpbmlzaGVkLCB0aGUgY29sbGVjdGVkIHBhZ2VzIGZvbGxvdyBhcyBgTi4gPHVybD5gICsgbWFy
  >> "!B64TMP!" echo a2Rvd24gdHJ1bmNhdGVkIGF0Ci0tbWF4LWNoYXJzIGNoYXJzIChkZWZhdWx0IDIwMDA7IHVwIHRv
  >> "!B64TMP!" echo IC0tbWF4LXBhZ2VzIHBhZ2VzLCBkZWZhdWx0IDI1KS4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcg
  >> "!B64TMP!" echo QVBJIHJlc3BvbnNlIGluc3RlYWQuIFRoZSBzdGF0dXMgcXVlcnkgaXRzZWxmIG9ubHkKZmFpbHMg
  >> "!B64TMP!" echo KGV4aXQgMSkgd2hlbiB0aGUgQVBJIGNhbm5vdCBiZSByZWFjaGVkOyBhIGBmYWlsZWRgIGNyYXds
  >> "!B64TMP!" echo IHN0aWxsIGV4aXRzIDAuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lz
  >> "!B64TMP!" echo LnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18p
  >> "!B64TMP!" echo KSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAg
  >> "!B64TMP!" echo Y2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfY3Jhd2wgICMgc2libGluZzogc2hhcmVkIGNy
  >> "!B64TMP!" echo YXdsIG91dHB1dCBmb3JtYXR0aW5nCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2NyYXdsIikKCgpk
  >> "!B64TMP!" echo ZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdz
  >> "!B64TMP!" echo IG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9j
  >> "!B64TMP!" echo cmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dICIKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAiWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
  >> "!B64TMP!" echo ICAgIGNyYXdsX2lkID0gYXJnc1swXQogICAgbWF4X3BhZ2VzLCBtYXhfY2hhcnMsIGFzX2pzb24g
  >> "!B64TMP!" echo PSAyNSwgMjAwMCwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgIGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8
  >> "!B64TMP!" echo IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIG1heF9wYWdlcyA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVF
  >> "!B64TMP!" echo cnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1heC1wYWdlczoge2FyZ3Nb
  >> "!B64TMP!" echo aV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBl
  >> "!B64TMP!" echo bGlmIGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
  >> "!B64TMP!" echo YXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1
  >> "!B64TMP!" echo bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiAyCiAgICAgICAgaSArPSAxCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIv
  >> "!B64TMP!" echo djEvY3Jhd2wvIiArIHN0cihjcmF3bF9pZCksIG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5G
  >> "!B64TMP!" echo Y0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBTVEFUVVMgRkFJTEVEIGZvciB7Y3Jh
  >> "!B64TMP!" echo d2xfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAoKICAgIHByaW50KGYiQ3Jhd2wge2NyYXdsX2lkfToge3dlYl9jcmF3bC5jcmF3bF9zdW1t
  >> "!B64TMP!" echo YXJ5KGRhdGEpfSIpCiAgICB3ZWJfY3Jhd2wucHJpbnRfcGFnZXMoZGF0YSwgbWF4X3BhZ2VzLCBt
  >> "!B64TMP!" echo YXhfY2hhcnMpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBz
  >> "!B64TMP!" echo eXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_crawl_status.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_agent.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_agent.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_agent.py" "!TARGET!\local-web-search\scripts\web_agent.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_agent.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_agent.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3756143307.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdGFydCBhbiBhc3luY2hyb25vdXMgRmlyZWNyYXds
  >> "!B64TMP!" echo IHJlc2VhcmNoIGFnZW50IGpvYiAodGhlIGZpcmVjcmF3bF9hZ2VudApNQ1AgdG9vbCk6IGdpdmUg
  >> "!B64TMP!" echo aXQgYSBwcm9tcHQsIG9wdGlvbmFsIHNlZWQgVVJMcywgYW5kIHJlYWQgdGhlIHJlc3VsdCBsYXRl
  >> "!B64TMP!" echo cgp3aXRoIHdlYl9hZ2VudF9zdGF0dXMucHkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfYWdlbnQu
  >> "!B64TMP!" echo cHkgIjxwcm9tcHQ+IiBbc2VlZF91cmwgLi4uXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0
  >> "!B64TMP!" echo aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRo
  >> "!B64TMP!" echo ZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMg
  >> "!B64TMP!" echo dGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJl
  >> "!B64TMP!" echo dHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRy
  >> "!B64TMP!" echo YW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYu
  >> "!B64TMP!" echo CllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1
  >> "!B64TMP!" echo biB0aGUgc2NyaXB0LgoKVGhlIGZpcnN0IGFyZ3VtZW50IGlzIHRoZSByZXNlYXJjaCBwcm9tcHQg
  >> "!B64TMP!" echo KHF1b3RlIGl0KTsgYW55IGZ1cnRoZXIgcG9zaXRpb25hbAphcmd1bWVudHMgYXJlIHNlZWQgVVJM
  >> "!B64TMP!" echo cyB0aGUgYWdlbnQgc2hvdWxkIHN0YXJ0IGZyb20uIFRoaXMgY2FsbCBvbmx5IFNUQVJUUwp0aGUg
  >> "!B64TMP!" echo am9iIGFuZCBwcmludHMgaXRzIElEIOKAlCB0aGUgcmVzZWFyY2ggaXRzZWxmIGNvbW1vbmx5IHRh
  >> "!B64TMP!" echo a2VzIHNldmVyYWwKbWludXRlcywgc28gcG9sbCB0aGUgam9iIHVudGlsIGl0IGlzIGNvbXBsZXRl
  >> "!B64TMP!" echo ZCBvciBmYWlsZWQ6CgogICAgcHl0aG9uIHdlYl9hZ2VudF9zdGF0dXMucHkgPGlkPgoKYC0tanNv
  >> "!B64TMP!" echo bmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQgb2YgdGhlIHN1bW1hcnkuCiIi
  >> "!B64TMP!" echo IgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9z
  >> "!B64TMP!" echo LnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3
  >> "!B64TMP!" echo bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFs
  >> "!B64TMP!" echo CgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpkZWYgbWFpbigpIC0+IGludDoKICAg
  >> "!B64TMP!" echo IGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0
  >> "!B64TMP!" echo aCgiLS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9hZ2VudC5weSAiPHByb21wdD4iIFtz
  >> "!B64TMP!" echo ZWVkX3VybCAuLi5dIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIHByb21wdCA9IGFyZ3NbMF0KICAgIHVybHMsIGFzX2pzb24gPSBb
  >> "!B64TMP!" echo XSwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAgIGEgPSBh
  >> "!B64TMP!" echo cmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRy
  >> "!B64TMP!" echo dWUKICAgICAgICBlbGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1
  >> "!B64TMP!" echo bmtub3duIG9wdGlvbjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHVybHMuYXBwZW5kKGEpCiAgICAgICAgaSArPSAx
  >> "!B64TMP!" echo CgogICAgYm9keSA9IHsicHJvbXB0IjogcHJvbXB0fQogICAgaWYgdXJsczoKICAgICAgICBib2R5
  >> "!B64TMP!" echo WyJ1cmxzIl0gPSB1cmxzCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvYWdl
  >> "!B64TMP!" echo bnQiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiQUdFTlQgU1RBUlQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
  >> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
  >> "!B64TMP!" echo CiAgICBqb2JfaWQgPSBwYXlsb2FkLmdldCgiaWQiKSBvciBkYXRhLmdldCgiaWQiKQogICAgaWYg
  >> "!B64TMP!" echo bm90IGpvYl9pZDoKICAgICAgICBwcmludCgiQUdFTlQgU1RBUlQgRkFJTEVEOiB0aGUgQVBJIGRp
  >> "!B64TMP!" echo ZCBub3QgcmV0dXJuIGEgam9iIGlkLiBSZXNwb25zZToiLAogICAgICAgICAgICAgIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHByaW50KGYiQWdlbnQgam9iIHN0YXJ0ZWQ6IHtq
  >> "!B64TMP!" echo b2JfaWR9IikKICAgIGlmIHVybHM6CiAgICAgICAgcHJpbnQoZiJTZWVkIFVSTHM6IHsnLCAnLmpv
  >> "!B64TMP!" echo aW4odXJscyl9IikKICAgIHByaW50KCJSZXNlYXJjaCBjb21tb25seSB0YWtlcyBzZXZlcmFsIG1p
  >> "!B64TMP!" echo bnV0ZXMg4oCUIHBvbGwgd2l0aDoiKQogICAgcHJpbnQoZiIgICAgcHl0aG9uIHdlYl9hZ2VudF9z
  >> "!B64TMP!" echo dGF0dXMucHkge2pvYl9pZH0iKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWlu
  >> "!B64TMP!" echo X18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_agent.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_agent_status.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_agent_status.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_agent_status.py" "!TARGET!\local-web-search\scripts\web_agent_status.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_agent_status.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_agent_status.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1276902308.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHByb2dyZXNzIG9yIGZpbmFsIHJlc3Vs
  >> "!B64TMP!" echo dHMgb2YgYSBGaXJlY3Jhd2wgcmVzZWFyY2ggYWdlbnQgam9iICh0aGUKZmlyZWNyYXdsX2FnZW50
  >> "!B64TMP!" echo X3N0YXR1cyBNQ1AgdG9vbCksIHN0YXJ0ZWQgd2l0aCB3ZWJfYWdlbnQucHkuCgpVc2FnZToKICAg
  >> "!B64TMP!" echo IHB5dGhvbiB3ZWJfYWdlbnRfc3RhdHVzLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVhbGluZzog
  >> "!B64TMP!" echo aWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBv
  >> "!B64TMP!" echo ciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3Rh
  >> "!B64TMP!" echo cnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFu
  >> "!B64TMP!" echo ZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNl
  >> "!B64TMP!" echo OyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNr
  >> "!B64TMP!" echo b2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVz
  >> "!B64TMP!" echo dCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBgQWdlbnQgPGlkPjogPHN0YXR1cz5gLiBBIGBwcm9j
  >> "!B64TMP!" echo ZXNzaW5nYC9gYWN0aXZlYCBzdGF0dXMgaXMgbm9uLXRlcm1pbmFsCuKAlCBjaGVjayBhZ2FpbiBh
  >> "!B64TMP!" echo ZnRlciAxNS0zMCBzLiBXaGVuIHRoZSBqb2IgaXMgYGNvbXBsZXRlZGAsIHRoZSByZXNlYXJjaCBy
  >> "!B64TMP!" echo ZXN1bHQKZm9sbG93cyAoc3RlcHMsIHNvdXJjZXMsIGFuZCB0aGUgZmluYWwgYW5zd2VyL3JlcG9y
  >> "!B64TMP!" echo dCBhcyByZXR1cm5lZCBieSB0aGUgQVBJKTsKYGZhaWxlZGAgam9icyBwcmludCB0aGUgYXZhaWxh
  >> "!B64TMP!" echo YmxlIGVycm9yIGRldGFpbHMgYW5kIGV4aXQgMS4gYC0tanNvbmAgcHJpbnRzCnRoZSByYXcgQVBJ
  >> "!B64TMP!" echo IHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoK
  >> "!B64TMP!" echo c3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxl
  >> "!B64TMP!" echo X18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhU
  >> "!B64TMP!" echo VFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpk
  >> "!B64TMP!" echo ZWYgcHJpbnRfcmVzdWx0KHJlc3VsdCwgaW5kZW50PTApOgogICAgIiIiUmVjdXJzaXZlbHkgcHJp
  >> "!B64TMP!" echo bnQgdGhlIGFnZW50IHJlc3VsdCBpbiBhIHJlYWRhYmxlIG91dGxpbmUuIiIiCiAgICBwYWQgPSAi
  >> "!B64TMP!" echo ICIgKiBpbmRlbnQKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0LCBkaWN0KToKICAgICAgICBmb3Ig
  >> "!B64TMP!" echo a2V5LCB2YWwgaW4gcmVzdWx0Lml0ZW1zKCk6CiAgICAgICAgICAgIGlmIGlzaW5zdGFuY2UodmFs
  >> "!B64TMP!" echo LCAoZGljdCwgbGlzdCkpOgogICAgICAgICAgICAgICAgcHJpbnQoZiJ7cGFkfXtrZXl9OiIpCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludF9yZXN1bHQodmFsLCBpbmRlbnQgKyAyKQogICAgICAgICAgICBl
  >> "!B64TMP!" echo bHNlOgogICAgICAgICAgICAgICAgdGV4dCA9IHN0cih2YWwpCiAgICAgICAgICAgICAgICBpZiBs
  >> "!B64TMP!" echo ZW4odGV4dCkgPiA0MDAwOgogICAgICAgICAgICAgICAgICAgIHRleHQgPSB0ZXh0Wzo0MDAwXSAr
  >> "!B64TMP!" echo IGYiXG57cGFkfVsuLi4gdHJ1bmNhdGVkIC4uLl0iCiAgICAgICAgICAgICAgICBwcmludChmIntw
  >> "!B64TMP!" echo YWR9e2tleX06IHt0ZXh0fSIpCiAgICBlbGlmIGlzaW5zdGFuY2UocmVzdWx0LCBsaXN0KToKICAg
  >> "!B64TMP!" echo ICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJhdGUocmVzdWx0LCAxKToKICAgICAgICAgICAgcHJp
  >> "!B64TMP!" echo bnQoZiJ7cGFkfXtufS4iKQogICAgICAgICAgICBwcmludF9yZXN1bHQoaXRlbSwgaW5kZW50ICsg
  >> "!B64TMP!" echo MikKICAgIGVsc2U6CiAgICAgICAgdGV4dCA9IHN0cihyZXN1bHQpCiAgICAgICAgaWYgbGVuKHRl
  >> "!B64TMP!" echo eHQpID4gNDAwMDoKICAgICAgICAgICAgdGV4dCA9IHRleHRbOjQwMDBdICsgZiJcbntwYWR9Wy4u
  >> "!B64TMP!" echo LiB0cnVuY2F0ZWQgLi4uXSIKICAgICAgICBwcmludChwYWQgKyB0ZXh0KQoKCmRlZiBtYWluKCkg
  >> "!B64TMP!" echo LT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1sw
  >> "!B64TMP!" echo XS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2FnZW50X3N0YXR1
  >> "!B64TMP!" echo cy5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAg
  >> "!B64TMP!" echo ICBqb2JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJnc1sxOl0KCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9hZ2VudC8iICsgc3RyKGpvYl9pZCks
  >> "!B64TMP!" echo IG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJBR0VOVCBTVEFUVVMgRkFJTEVEIGZvciB7am9iX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpz
  >> "!B64TMP!" echo b24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAgaWYgZGF0YS5nZXQoInN0YXR1cyIpICE9
  >> "!B64TMP!" echo ICJmYWlsZWQiIGVsc2UgMQoKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5z
  >> "!B64TMP!" echo dGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBzdGF0dXMgPSBzdHIo
  >> "!B64TMP!" echo cGF5bG9hZC5nZXQoInN0YXR1cyIpIG9yIGRhdGEuZ2V0KCJzdGF0dXMiKSBvciAidW5rbm93biIp
  >> "!B64TMP!" echo CiAgICBwcmludChmIkFnZW50IHtqb2JfaWR9OiB7c3RhdHVzfSIpCiAgICBpZiBzdGF0dXMgbm90
  >> "!B64TMP!" echo IGluICgiY29tcGxldGVkIiwgImZhaWxlZCIsICJjYW5jZWxsZWQiLCAic3RvcHBlZCIpOgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KCIobm9uLXRlcm1pbmFsIOKAlCBjaGVjayBhZ2FpbiBhZnRlciAxNS0zMCBzKSIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDAKICAgIHJlc3VsdCA9IHBheWxvYWQuZ2V0KCJyZXN1bHQiKQogICAg
  >> "!B64TMP!" echo aWYgcmVzdWx0IGlzIE5vbmU6CiAgICAgICAgcmVzdWx0ID0gZGF0YS5nZXQoInJlc3VsdCIpCiAg
  >> "!B64TMP!" echo ICBpZiByZXN1bHQgaXMgbm90IE5vbmU6CiAgICAgICAgcHJpbnQoKQogICAgICAgIHByaW50X3Jl
  >> "!B64TMP!" echo c3VsdChyZXN1bHQpCiAgICBlbGlmIHN0YXR1cyA9PSAiZmFpbGVkIjoKICAgICAgICBlcnJvciA9
  >> "!B64TMP!" echo IHBheWxvYWQuZ2V0KCJlcnJvciIpIG9yIGRhdGEuZ2V0KCJlcnJvciIpCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJlcnJvcjoge2Vycm9yIG9yICcobm8gZGV0YWlscyByZXR1cm5lZCknfSIpCiAgICByZXR1cm4g
  >> "!B64TMP!" echo MCBpZiBzdGF0dXMgPT0gImNvbXBsZXRlZCIgZWxzZSAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFp
  >> "!B64TMP!" echo bl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_agent_status.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_interact.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_interact.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_interact.py" "!TARGET!\local-web-search\scripts\web_interact.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_interact.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_interact.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS487167018.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnRlcmFjdCB3aXRoIGEgc2NyYXBlZCBwYWdlIHRo
  >> "!B64TMP!" echo cm91Z2ggYSBsaXZlIEZpcmVjcmF3bCBicm93c2VyIHNlc3Npb24KKHRoZSBmaXJlY3Jhd2xfaW50
  >> "!B64TMP!" echo ZXJhY3QgTUNQIHRvb2wpOiBuYXZpZ2F0ZSwgY2xpY2sgY29udHJvbHMsIGZpbGwgZmllbGRzLCBv
  >> "!B64TMP!" echo cgpydW4gYnJvd3NlciBjb2RlLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2ludGVyYWN0LnB5ICgt
  >> "!B64TMP!" echo LXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgKC0t
  >> "!B64TMP!" echo cHJvbXB0IFRFWFQgfCAtLWNvZGUgVEVYVCBbLS1sYW5ndWFnZSBiYXNofHB5dGhvbnxub2RlXSkK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tdGltZW91dCBTXSBbLS1qc29uXQoKU2VsZi1o
  >> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
  >> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
  >> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
  >> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
  >> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
  >> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJvdmlkZSBFSVRIRVIgLS1zY3JhcGUtaWQgKHJl
  >> "!B64TMP!" echo dXNlIGEgcHJldmlvdXMgc2NyYXBlJ3Mgc2Vzc2lvbikgb3IgLS11cmwKKG9wZW4gYSBmcmVzaCBz
  >> "!B64TMP!" echo ZXNzaW9uKSwgYW5kIEVJVEhFUiAtLXByb21wdCAobmF0dXJhbC1sYW5ndWFnZSBpbnN0cnVjdGlv
  >> "!B64TMP!" echo bnMpCm9yIC0tY29kZSAod2l0aCAtLWxhbmd1YWdlLCBkZWZhdWx0IGJhc2gpLiBOT1RFOiB0aGlz
  >> "!B64TMP!" echo IGFjdHMgb24gdGhlIExJVkUgc2l0ZSDigJQKYWN0aW9ucyBzdWNoIGFzIGZvcm0gc3VibWlzc2lv
  >> "!B64TMP!" echo biBjYW4gY3JlYXRlIHBlcnNpc3RlbnQgZXh0ZXJuYWwgc2lkZSBlZmZlY3RzLgoKUHJpbnRzIHRo
  >> "!B64TMP!" echo ZSBBUEkncyBKU09OIHJlc3BvbnNlOiBleGVjdXRpb24gb3V0cHV0LCBzdGRvdXQvc3RkZXJyLCBl
  >> "!B64TMP!" echo eGl0CnN0YXR1cywgYW5kIHRoZSBzZXNzaW9uIHZpZXdpbmcgVVJMcy4gYC0tanNvbmAgcHJpbnRz
  >> "!B64TMP!" echo IGl0IGNvbXBhY3Qgb24gb25lIGxpbmUKaW5zdGVhZCBvZiBwcmV0dHktcHJpbnRlZC4KIiIiCmlt
  >> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
  >> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
  >> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
  >> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKTEFOR1VBR0VTID0gKCJiYXNoIiwgInB5
  >> "!B64TMP!" echo dGhvbiIsICJub2RlIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsx
  >> "!B64TMP!" echo Ol0KICAgIHNjcmFwZV9pZCwgdXJsID0gTm9uZSwgTm9uZQogICAgcHJvbXB0LCBjb2RlLCBsYW5n
  >> "!B64TMP!" echo dWFnZSA9IE5vbmUsIE5vbmUsIE5vbmUKICAgIHRpbWVvdXQsIGFzX2pzb24gPSBOb25lLCBGYWxz
  >> "!B64TMP!" echo ZQogICAgaSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0K
  >> "!B64TMP!" echo ICAgICAgICBpZiBhID09ICItLXNjcmFwZS1pZCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2NyYXBlX2lkID0gYXJnc1tpXQogICAgICAgIGVs
  >> "!B64TMP!" echo aWYgYSA9PSAiLS11cmwiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAx
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHVybCA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0gIi0tcHJvbXB0IiBh
  >> "!B64TMP!" echo bmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBwcm9t
  >> "!B64TMP!" echo cHQgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWNvZGUiIGFuZCBpICsgMSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGNvZGUgPSBhcmdzW2ldCiAgICAg
  >> "!B64TMP!" echo ICAgZWxpZiBhID09ICItLWxhbmd1YWdlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICBsYW5ndWFnZSA9IGFyZ3NbaV0KICAgICAgICAgICAgaWYg
  >> "!B64TMP!" echo bGFuZ3VhZ2Ugbm90IGluIExBTkdVQUdFUzoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxp
  >> "!B64TMP!" echo ZCAtLWxhbmd1YWdlOiB7bGFuZ3VhZ2V9ICIKICAgICAgICAgICAgICAgICAgICAgIGYiKG9uZSBv
  >> "!B64TMP!" echo ZiB7JywgJy5qb2luKExBTkdVQUdFUyl9KSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLXRpbWVvdXQiIGFuZCBpICsgMSA8IGxl
  >> "!B64TMP!" echo bihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHRpbWVvdXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS10aW1lb3V0OiB7YXJnc1tpXX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsaWYgYSA9
  >> "!B64TMP!" echo PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRydWUKICAgICAgICBlbGlmIGEuc3Rh
  >> "!B64TMP!" echo cnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1bmtub3duIG9wdGlvbjoge2F9Iiwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsc2U6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1bWVudDoge2F9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGkgKz0gMQoKICAgIGlmIGJvb2woc2NyYXBl
  >> "!B64TMP!" echo X2lkKSA9PSBib29sKHVybCk6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgZXhhY3RseSBvbmUgb2Yg
  >> "!B64TMP!" echo LS1zY3JhcGUtaWQgKHJldXNlIGEgc2NyYXBlJ3Mgc2Vzc2lvbikgIgogICAgICAgICAgICAgICJv
  >> "!B64TMP!" echo ciAtLXVybCAob3BlbiBhIG5ldyBzZXNzaW9uKSwgbm90IGJvdGgiLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCBwcm9tcHQgYW5kIG5vdCBjb2RlOgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCJwcm92aWRlIGVpdGhlciAtLXByb21wdCAobmF0dXJhbCBsYW5ndWFnZSkgb3IgLS1j
  >> "!B64TMP!" echo b2RlICIKICAgICAgICAgICAgICAiKGV4ZWN1dGFibGUsIHdpdGggLS1sYW5ndWFnZSkiLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIGxhbmd1YWdlIGFuZCBub3QgY29k
  >> "!B64TMP!" echo ZToKICAgICAgICBwcmludCgiLS1sYW5ndWFnZSBjYW4gb25seSBiZSB1c2VkIHRvZ2V0aGVyIHdp
  >> "!B64TMP!" echo dGggLS1jb2RlIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDIKCiAgICBib2R5ID0ge30KICAgIGlmIHNjcmFwZV9pZDoKICAgICAgICBib2R5WyJzY3JhcGVJ
  >> "!B64TMP!" echo ZCJdID0gc2NyYXBlX2lkCiAgICBlbHNlOgogICAgICAgIGJvZHlbInVybCJdID0gdXJsCiAgICBp
  >> "!B64TMP!" echo ZiBwcm9tcHQ6CiAgICAgICAgYm9keVsicHJvbXB0Il0gPSBwcm9tcHQKICAgIGlmIGNvZGU6CiAg
  >> "!B64TMP!" echo ICAgICAgYm9keVsiY29kZSJdID0gY29kZQogICAgICAgIGJvZHlbImxhbmd1YWdlIl0gPSBsYW5n
  >> "!B64TMP!" echo dWFnZSBvciAiYmFzaCIKICAgIGlmIHRpbWVvdXQgaXMgbm90IE5vbmU6CiAgICAgICAgYm9keVsi
  >> "!B64TMP!" echo dGltZW91dCJdID0gdGltZW91dAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
  >> "!B64TMP!" echo L2ludGVyYWN0IiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJy
  >> "!B64TMP!" echo b3IgYXMgZToKICAgICAgICBwcmludChmIklOVEVSQUNUIEZBSUxFRDoge2V9IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEp
  >> "!B64TMP!" echo IGlmIGFzX2pzb24gZWxzZSBqc29uLmR1bXBzKGRhdGEsIGluZGVudD0yKSkKICAgIHJldHVybiAw
  >> "!B64TMP!" echo CgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_interact.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_interact_stop.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_interact_stop.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_interact_stop.py" "!TARGET!\local-web-search\scripts\web_interact_stop.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_interact_stop.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_interact_stop.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS640213521.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdG9wIHRoZSBsaXZlIEZpcmVjcmF3bCBpbnRlcmFj
  >> "!B64TMP!" echo dCBzZXNzaW9uIGZvciBhIHNjcmFwZUlkIGFuZCByZWxlYXNlIGl0cwpyZXNvdXJjZXMgKHRoZSBm
  >> "!B64TMP!" echo aXJlY3Jhd2xfaW50ZXJhY3Rfc3RvcCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo aW50ZXJhY3Rfc3RvcC5weSA8c2NyYXBlSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRo
  >> "!B64TMP!" echo ZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhl
  >> "!B64TMP!" echo CmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0
  >> "!B64TMP!" echo aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0
  >> "!B64TMP!" echo cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJh
  >> "!B64TMP!" echo bnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4K
  >> "!B64TMP!" echo WW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVu
  >> "!B64TMP!" echo IHRoZSBzY3JpcHQuCgpQcmludHMgYSBjb25maXJtYXRpb24gKHBsdXMgdGhlIEFQSSdzIHJlc3Bv
  >> "!B64TMP!" echo bnNlIGJvZHkgd2hlbiBvbmUgaXMgcmV0dXJuZWQpLgpgLS1qc29uYCBwcmludHMgdGhlIHJhdyBB
  >> "!B64TMP!" echo UEkgcmVzcG9uc2UgaW5zdGVhZC4gVGhlIHNlc3Npb24gY2Fubm90IGJlIHJlc3VtZWQKYWZ0ZXIg
  >> "!B64TMP!" echo aXQgaXMgc3RvcHBlZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKCmRl
  >> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
  >> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2lu
  >> "!B64TMP!" echo dGVyYWN0X3N0b3AucHkgPHNjcmFwZUlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gMgogICAgc2NyYXBlX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpz
  >> "!B64TMP!" echo b24iIGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvaW50
  >> "!B64TMP!" echo ZXJhY3QvIiArIHN0cihzY3JhcGVfaWQpICsgIi9zdG9wIiwKICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBtZXRob2Q9IlBPU1QiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmIklOVEVSQUNUIFNUT1AgRkFJTEVEIGZvciB7c2NyYXBlX2lkfToge2V9IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KGYiSW50ZXJh
  >> "!B64TMP!" echo Y3Qgc2Vzc2lvbiB7c2NyYXBlX2lkfSBzdG9wcGVkLiIpCiAgICBpZiBkYXRhOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVf
  >> "!B64TMP!" echo XyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_interact_stop.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_parse.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_parse.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_parse.py" "!TARGET!\local-web-search\scripts\web_parse.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_parse.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_parse.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1646618542.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXJzZSBhIGxvY2FsIGRvY3VtZW50IGludG8gbWFy
  >> "!B64TMP!" echo a2Rvd24gLyBIVE1MIC8gbGlua3MgLyBhIHN1bW1hcnkgLyB0YXJnZXRlZAphbnN3ZXJzIC8gc3Ry
  >> "!B64TMP!" echo dWN0dXJlZCBKU09OICh0aGUgZmlyZWNyYXdsX3BhcnNlIE1DUCB0b29sKS4gU3VwcG9ydGVkIGlu
  >> "!B64TMP!" echo cHV0cwppbmNsdWRlIGNvbW1vbiBIVE1MLCBQREYsIFdvcmQsIFJURiwgT3BlbkRvY3VtZW50LCBh
  >> "!B64TMP!" echo bmQgc3ByZWFkc2hlZXQgZmlsZXMuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfcGFyc2UucHkgPGZp
  >> "!B64TMP!" echo bGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0gWy0tbWF4LWNoYXJzIE5dCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRh
  >> "!B64TMP!" echo aW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0
  >> "!B64TMP!" echo aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0
  >> "!B64TMP!" echo aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZS4gWW91IGRvIE5P
  >> "!B64TMP!" echo VCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZQpzY3Jp
  >> "!B64TMP!" echo cHQuCgpUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0aGUgbG9jYWwgRmlyZWNyYXdsIGluc3RhbmNl
  >> "!B64TMP!" echo IChpdCBuZXZlciBsZWF2ZXMgeW91cgptYWNoaW5lKS4gYC0tZm9ybWF0c2AgdGFrZXMgYSBjb21t
  >> "!B64TMP!" echo YS1zZXBhcmF0ZWQgbGlzdCBmcm9tOiBtYXJrZG93biwgaHRtbCwKcmF3SHRtbCwgbGlua3MsIHN1
  >> "!B64TMP!" echo bW1hcnksIGpzb24sIHF1ZXJ5IChkZWZhdWx0OiBtYXJrZG93bikuIFByaW50cyB0aGUgcGFyc2Vk
  >> "!B64TMP!" echo CmNvbnRlbnQ7IHdpdGggc2V2ZXJhbCBmb3JtYXRzIGVhY2ggaXMgcHJpbnRlZCB1bmRlciBhIGAj
  >> "!B64TMP!" echo IyA8Zm9ybWF0PmAgaGVhZGVyLgpNYXJrZG93bi9IVE1MIHRydW5jYXRlIGF0IC0tbWF4LWNoYXJz
  >> "!B64TMP!" echo IGNoYXJzIChkZWZhdWx0IDIwMDAwLCBsaWtlCndlYl9zY3JhcGUucHkpLiBgLS1qc29uYCBwcmlu
  >> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
  >> "!B64TMP!" echo cwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGgu
  >> "!B64TMP!" echo YWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5n
  >> "!B64TMP!" echo OiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIv
  >> "!B64TMP!" echo djEvcGFyc2UiKQoKRk9STUFUUyA9ICgibWFya2Rvd24iLCAiaHRtbCIsICJyYXdIdG1sIiwgImxp
  >> "!B64TMP!" echo bmtzIiwgInN1bW1hcnkiLCAianNvbiIsICJxdWVyeSIpCgojIEV4dGVuc2lvbiAtPiBNSU1FIHR5
  >> "!B64TMP!" echo cGUgZm9yIHRoZSB1cGxvYWQgKGV2ZXJ5dGhpbmcgZWxzZSBpcyBzZW50IGFzIGEKIyBnZW5lcmlj
  >> "!B64TMP!" echo IG9jdGV0IHN0cmVhbSBhbmQgRmlyZWNyYXdsIHNuaWZmcyB0aGUgcmVhbCB0eXBlIHNlcnZlci1z
  >> "!B64TMP!" echo aWRlKS4KTUlNRV9UWVBFUyA9IHsKICAgICIuaHRtbCI6ICJ0ZXh0L2h0bWwiLCAiLmh0bSI6ICJ0
  >> "!B64TMP!" echo ZXh0L2h0bWwiLAogICAgIi5wZGYiOiAiYXBwbGljYXRpb24vcGRmIiwKICAgICIuZG9jIjogImFw
  >> "!B64TMP!" echo cGxpY2F0aW9uL21zd29yZCIsCiAgICAiLmRvY3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxm
  >> "!B64TMP!" echo b3JtYXRzLW9mZmljZWRvY3VtZW50LndvcmRwcm9jZXNzaW5nbWwuZG9jdW1lbnQiLAogICAgIi5y
  >> "!B64TMP!" echo dGYiOiAiYXBwbGljYXRpb24vcnRmIiwKICAgICIub2R0IjogImFwcGxpY2F0aW9uL3ZuZC5vYXNp
  >> "!B64TMP!" echo cy5vcGVuZG9jdW1lbnQudGV4dCIsCiAgICAiLm9kcyI6ICJhcHBsaWNhdGlvbi92bmQub2FzaXMu
  >> "!B64TMP!" echo b3BlbmRvY3VtZW50LnNwcmVhZHNoZWV0IiwKICAgICIueGxzIjogImFwcGxpY2F0aW9uL3ZuZC5t
  >> "!B64TMP!" echo cy1leGNlbCIsCiAgICAiLnhsc3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxmb3JtYXRzLW9m
  >> "!B64TMP!" echo ZmljZWRvY3VtZW50LnNwcmVhZHNoZWV0bWwuc2hlZXQiLAogICAgIi5jc3YiOiAidGV4dC9jc3Yi
  >> "!B64TMP!" echo LAogICAgIi50eHQiOiAidGV4dC9wbGFpbiIsCiAgICAiLm1kIjogInRleHQvbWFya2Rvd24iLAp9
  >> "!B64TMP!" echo CgojIEZvcm1hdHMgd2hvc2UgY29udGVudCBpcyBwbGFpbiB0ZXh0IGFuZCBjYW4gYmUgdHJ1bmNh
  >> "!B64TMP!" echo dGVkIHNhZmVseS4KVEVYVF9GT1JNQVRTID0gKCJtYXJrZG93biIsICJodG1sIiwgInJhd0h0bWwi
  >> "!B64TMP!" echo LCAic3VtbWFyeSIsICJxdWVyeSIpCgoKZGVmIGNvbnRlbnRfdHlwZV9mb3IocGF0aCk6CiAgICBy
  >> "!B64TMP!" echo ZXR1cm4gTUlNRV9UWVBFUy5nZXQob3MucGF0aC5zcGxpdGV4dChwYXRoKVsxXS5sb3dlcigpLAog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICJhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0iKQoKCmRl
  >> "!B64TMP!" echo ZiBwcmludF9maWVsZChuYW1lLCB2YWx1ZSwgbWF4X2NoYXJzKToKICAgICIiIlByaW50IG9uZSBw
  >> "!B64TMP!" echo YXJzZWQgZm9ybWF0IHVuZGVyIGEgaGVhZGVyLCB0cnVuY2F0aW5nIGxvbmcgdGV4dC4iIiIKICAg
  >> "!B64TMP!" echo IGlmIG5hbWUgIT0gIm1hcmtkb3duIjoKICAgICAgICBwcmludChmIiMjIHtuYW1lfSIpCiAgICBp
  >> "!B64TMP!" echo ZiBpc2luc3RhbmNlKHZhbHVlLCBsaXN0KToKICAgICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJh
  >> "!B64TMP!" echo dGUodmFsdWUsIDEpOgogICAgICAgICAgICBwcmludChmIntufS4ge2l0ZW19IikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4KICAgIGlmIGlzaW5zdGFuY2UodmFsdWUsIChkaWN0LCBib29sLCBpbnQsIGZsb2F0KSk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyh2YWx1ZSwgaW5kZW50PTIpKQogICAgICAgIHJldHVy
  >> "!B64TMP!" echo bgogICAgdGV4dCA9IHN0cih2YWx1ZSkKICAgIGlmIG5vdCB0ZXh0OgogICAgICAgIHByaW50KCIo
  >> "!B64TMP!" echo ZW1wdHkpIikKICAgICAgICByZXR1cm4KICAgIGlmIG5hbWUgaW4gVEVYVF9GT1JNQVRTIGFuZCBs
  >> "!B64TMP!" echo ZW4odGV4dCkgPiBtYXhfY2hhcnM6CiAgICAgICAgdGV4dCA9IHRleHRbOm1heF9jaGFyc10gKyBm
  >> "!B64TMP!" echo IlxuWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIKICAgIHByaW50KHRl
  >> "!B64TMP!" echo eHQpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBu
  >> "!B64TMP!" echo b3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdl
  >> "!B64TMP!" echo OiB3ZWJfcGFyc2UucHkgPGZpbGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0g
  >> "!B64TMP!" echo IgogICAgICAgICAgICAgICJbLS1tYXgtY2hhcnMgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGZpbGVfcGF0aCA9IGFyZ3NbMF0KICAgIGZvcm1hdHMg
  >> "!B64TMP!" echo PSBbIm1hcmtkb3duIl0KICAgIG1heF9jaGFycywgYXNfanNvbiA9IDIwMDAwLCBGYWxzZQogICAg
  >> "!B64TMP!" echo aSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
  >> "!B64TMP!" echo ICBpZiBhID09ICItLWZvcm1hdHMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAg
  >> "!B64TMP!" echo aSArPSAxCiAgICAgICAgICAgIGZvcm1hdHMgPSBbZi5zdHJpcCgpIGZvciBmIGluIGFyZ3NbaV0u
  >> "!B64TMP!" echo c3BsaXQoIiwiKSBpZiBmLnN0cmlwKCldCiAgICAgICAgICAgIGJhZCA9IFtmIGZvciBmIGluIGZv
  >> "!B64TMP!" echo cm1hdHMgaWYgZiBub3QgaW4gRk9STUFUU10KICAgICAgICAgICAgaWYgYmFkOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tZm9ybWF0cyB2YWx1ZShzKTogeycsICcuam9pbihiYWQp
  >> "!B64TMP!" echo fSAiCiAgICAgICAgICAgICAgICAgICAgICBmIih2YWxpZDogeycsICcuam9pbihGT1JNQVRTKX0p
  >> "!B64TMP!" echo IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlm
  >> "!B64TMP!" echo IGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkg
  >> "!B64TMP!" echo Kz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJn
  >> "!B64TMP!" echo c1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAg
  >> "!B64TMP!" echo ICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4
  >> "!B64TMP!" echo cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biAyCiAgICAgICAgaSArPSAxCgogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKGZpbGVfcGF0aCk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoZiJQQVJTRSBGQUlMRUQ6IG5vIHN1Y2ggZmlsZToge2ZpbGVfcGF0aH0i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBvcHRpb25zID0geyJmb3Jt
  >> "!B64TMP!" echo YXRzIjogZm9ybWF0c30KICAgIGZpZWxkcyA9IHsib3B0aW9ucyI6IGpzb24uZHVtcHMob3B0aW9u
  >> "!B64TMP!" echo cyksCiAgICAgICAgICAgICAgImNvbnRlbnRUeXBlIjogY29udGVudF90eXBlX2ZvcihmaWxlX3Bh
  >> "!B64TMP!" echo dGgpfQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsX2Zvcm0oIi92MS9wYXJzZSIsIGZp
  >> "!B64TMP!" echo ZWxkcywgZmlsZV9wYXRoKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmIlBBUlNFIEZBSUxFRCBmb3Ige2ZpbGVfcGF0aH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29u
  >> "!B64TMP!" echo LmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgcGF5bG9hZCA9IGRhdGEuZ2V0KCJk
  >> "!B64TMP!" echo YXRhIikgaWYgaXNpbnN0YW5jZShkYXRhLmdldCgiZGF0YSIpLCBkaWN0KSBlbHNlIGRhdGEKICAg
  >> "!B64TMP!" echo IHByaW50ZWQgPSAwCiAgICBmb3IgZm10IGluIGZvcm1hdHM6CiAgICAgICAgdmFsdWUgPSBwYXls
  >> "!B64TMP!" echo b2FkLmdldChmbXQpCiAgICAgICAgaWYgdmFsdWUgaXMgTm9uZToKICAgICAgICAgICAgY29udGlu
  >> "!B64TMP!" echo dWUKICAgICAgICBpZiBwcmludGVkOgogICAgICAgICAgICBwcmludCgpCiAgICAgICAgcHJpbnRf
  >> "!B64TMP!" echo ZmllbGQoZm10LCB2YWx1ZSwgbWF4X2NoYXJzKQogICAgICAgIHByaW50ZWQgKz0gMQogICAgaWYg
  >> "!B64TMP!" echo bm90IHByaW50ZWQ6CiAgICAgICAgcHJpbnQoZiJQQVJTRSBSRVRVUk5FRCBOTyBDT05URU5UIGZv
  >> "!B64TMP!" echo ciB7ZmlsZV9wYXRofSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBz
  >> "!B64TMP!" echo KGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_parse.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_create.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_create.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_create.py" "!TARGET!\local-web-search\scripts\web_monitor_create.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_create.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_create.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS635240605.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJDcmVhdGUgYSByZWN1cnJpbmcgRmlyZWNyYXdsIG1v
  >> "!B64TMP!" echo bml0b3Ig4oCUIGEgc2NyYXBlLCBjcmF3bCwgb3Igc2VhcmNoIGNoZWNrCnRoYXQgY29tcGFyZXMg
  >> "!B64TMP!" echo ZWFjaCBydW4gd2l0aCBpdHMgcmV0YWluZWQgcHJlZGVjZXNzb3IgKHRoZQpmaXJlY3Jhd2xfbW9u
  >> "!B64TMP!" echo aXRvcl9jcmVhdGUgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX21vbml0b3JfY3Jl
  >> "!B64TMP!" echo YXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8IC0tYm9keS1maWxlIG1vbml0b3IuanNvbikKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhl
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUK
  >> "!B64TMP!" echo Y29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRo
  >> "!B64TMP!" echo ZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRy
  >> "!B64TMP!" echo aWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFu
  >> "!B64TMP!" echo c2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZ
  >> "!B64TMP!" echo b3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4g
  >> "!B64TMP!" echo dGhlIHNjcmlwdC4KCmAtLWJvZHlgIGlzIHRoZSBmdWxsIG1vbml0b3IgY29uZmlndXJhdGlvbiBh
  >> "!B64TMP!" echo cyBKU09OIChzYW1lIG9iamVjdCB0aGUgTUNQCnRvb2wncyBgYm9keWAgcGFyYW1ldGVyIHRha2Vz
  >> "!B64TMP!" echo OiBuYW1lLCBzY2hlZHVsZSwgZ29hbCwgdGFyZ2V0cywgd2ViaG9vaywKbm90aWZpY2F0aW9uLCBy
  >> "!B64TMP!" echo ZXRlbnRpb24sIC4uLikuIGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVh
  >> "!B64TMP!" echo ZC4KUHJpbnRzIHRoZSBjcmVhdGVkIG1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHBy
  >> "!B64TMP!" echo aW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApG
  >> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVj
  >> "!B64TMP!" echo cmF3bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5v
  >> "!B64TMP!" echo dCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVm
  >> "!B64TMP!" echo IHJlYWRfYm9keV9hcmcoYXJncyk6CiAgICAiIiJSZXR1cm4gdGhlIG1vbml0b3IgYm9keSBhcyBh
  >> "!B64TMP!" echo IGRpY3QgZnJvbSAtLWJvZHkgLyAtLWJvZHktZmlsZSwgb3IKICAgIChOb25lLCBlcnJvci1tZXNz
  >> "!B64TMP!" echo YWdlKS4iIiIKICAgIGJvZHlfcmF3LCBib2R5X2ZpbGUgPSBOb25lLCBOb25lCiAgICBpID0gMAog
  >> "!B64TMP!" echo ICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBhID0gYXJnc1tpXQogICAgICAgIGlmIGEg
  >> "!B64TMP!" echo PT0gIi0tYm9keSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAg
  >> "!B64TMP!" echo ICAgICAgICAgYm9keV9yYXcgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWJvZHktZmls
  >> "!B64TMP!" echo ZSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAg
  >> "!B64TMP!" echo Ym9keV9maWxlID0gYXJnc1tpXQogICAgICAgIGkgKz0gMQogICAgaWYgYm9keV9yYXcgaXMgbm90
  >> "!B64TMP!" echo IE5vbmUgYW5kIGJvZHlfZmlsZSBpcyBub3QgTm9uZToKICAgICAgICByZXR1cm4gTm9uZSwgInBy
  >> "!B64TMP!" echo b3ZpZGUgZWl0aGVyIC0tYm9keSBvciAtLWJvZHktZmlsZSwgbm90IGJvdGgiCiAgICBpZiBib2R5
  >> "!B64TMP!" echo X2ZpbGUgaXMgbm90IE5vbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICB3aXRoIG9wZW4oYm9k
  >> "!B64TMP!" echo eV9maWxlLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoKICAgICAgICAgICAgICAgIGJvZHlfcmF3
  >> "!B64TMP!" echo ID0gZmgucmVhZCgpCiAgICAgICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIE5vbmUsICJjb3VsZCBub3QgcmVhZCB7fToge30iLmZvcm1hdChib2R5X2ZpbGUsIGUpCiAg
  >> "!B64TMP!" echo ICBpZiBib2R5X3JhdyBpcyBOb25lOgogICAgICAgIHJldHVybiBOb25lLCAoImEgbW9uaXRvciBi
  >> "!B64TMP!" echo b2R5IGlzIHJlcXVpcmVkOiAtLWJvZHkgJ3suLi59JyAiCiAgICAgICAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo KGZ1bGwgbW9uaXRvciBKU09OKSBvciAtLWJvZHktZmlsZSBGSUxFIikKICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICBib2R5ID0ganNvbi5sb2Fkcyhib2R5X3JhdykKICAgIGV4Y2VwdCBWYWx1ZUVycm9yIGFzIGU6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIE5vbmUsICJ0aGUgYm9keSBpcyBub3QgdmFsaWQgSlNPTjoge30iLmZv
  >> "!B64TMP!" echo cm1hdChlKQogICAgaWYgbm90IGlzaW5zdGFuY2UoYm9keSwgZGljdCk6CiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IE5vbmUsICJ0aGUgbW9uaXRvciBib2R5IG11c3QgYmUgYSBKU09OIG9iamVjdCIKICAgIHJldHVy
  >> "!B64TMP!" echo biBib2R5LCBOb25lCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpd
  >> "!B64TMP!" echo CiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gcmVhZF9ib2R5
  >> "!B64TMP!" echo X2FyZyhhcmdzKQogICAgaWYgZXJyOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX21vbml0b3Jf
  >> "!B64TMP!" echo Y3JlYXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAgICAiLS1ib2R5LWZpbGUg
  >> "!B64TMP!" echo bW9uaXRvci5qc29uKSBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChl
  >> "!B64TMP!" echo cnIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBk
  >> "!B64TMP!" echo YXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAg
  >> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDUkVBVEUg
  >> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoK
  >> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_create.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_list.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_list.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_list.py" "!TARGET!\local-web-search\scripts\web_monitor_list.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_list.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_list.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3195686845.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBGaXJlY3Jhd2wgbW9uaXRvcnMgb2Yg
  >> "!B64TMP!" echo dGhlIGF1dGhlbnRpY2F0ZWQgYWNjb3VudCAodGhlCmZpcmVjcmF3bF9tb25pdG9yX2xpc3QgTUNQ
  >> "!B64TMP!" echo IHRvb2wpLCB3aXRoIG9wdGlvbmFsIHBhZ2luYXRpb24uCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo bW9uaXRvcl9saXN0LnB5IFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1o
  >> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
  >> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
  >> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
  >> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
  >> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
  >> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBtb25pdG9yOiBg
  >> "!B64TMP!" echo Ti4gPGlkPiDigJQgPG5hbWU+ICg8c3RhdGU+KWAuIGAtLWpzb25gIHByaW50cwp0aGUgcmF3IEFQ
  >> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
  >> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
  >> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
  >> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
  >> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
  >> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6
  >> "!B64TMP!" echo CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBsaW1pdCwgb2Zmc2V0LCBhc19qc29uID0gTm9u
  >> "!B64TMP!" echo ZSwgTm9uZSwgRmFsc2UKICAgIGkgPSAwCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAg
  >> "!B64TMP!" echo IGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFy
  >> "!B64TMP!" echo Z3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo bGltaXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tb2Zm
  >> "!B64TMP!" echo c2V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgICAgICAgICBvZmZzZXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAg
  >> "!B64TMP!" echo ZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS1vZmZz
  >> "!B64TMP!" echo ZXQ6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAy
  >> "!B64TMP!" echo CiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAgICAgICBhc19qc29uID0gVHJ1ZQog
  >> "!B64TMP!" echo ICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVua25v
  >> "!B64TMP!" echo d24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAg
  >> "!B64TMP!" echo ICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgaSArPSAxCgog
  >> "!B64TMP!" echo ICAgcXVlcnkgPSB7fQogICAgaWYgbGltaXQgaXMgbm90IE5vbmU6CiAgICAgICAgcXVlcnlbImxp
  >> "!B64TMP!" echo bWl0Il0gPSBsaW1pdAogICAgaWYgb2Zmc2V0IGlzIG5vdCBOb25lOgogICAgICAgIHF1ZXJ5WyJv
  >> "!B64TMP!" echo ZmZzZXQiXSA9IG9mZnNldAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21v
  >> "!B64TMP!" echo bml0b3IiLCBtZXRob2Q9IkdFVCIsIHF1ZXJ5PXF1ZXJ5KQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
  >> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgTElTVCBGQUlMRUQ6IHtlfSIsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBw
  >> "!B64TMP!" echo cmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbW9uaXRvcnMgPSBk
  >> "!B64TMP!" echo YXRhLmdldCgibW9uaXRvcnMiKQogICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvcnMsIGxpc3Qp
  >> "!B64TMP!" echo OgogICAgICAgIG1vbml0b3JzID0gZGF0YS5nZXQoImRhdGEiKQogICAgaWYgbm90IGlzaW5zdGFu
  >> "!B64TMP!" echo Y2UobW9uaXRvcnMsIGxpc3QpOgogICAgICAgIG1vbml0b3JzID0gZGF0YSBpZiBpc2luc3RhbmNl
  >> "!B64TMP!" echo KGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5vdCBtb25pdG9yczoKICAgICAgICBwcmludCgi
  >> "!B64TMP!" echo KG5vIG1vbml0b3JzKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZvciBuLCBtb25pdG9yIGluIGVu
  >> "!B64TMP!" echo dW1lcmF0ZShtb25pdG9ycywgMSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvciwg
  >> "!B64TMP!" echo ZGljdCk6CiAgICAgICAgICAgIHByaW50KGYie259LiB7bW9uaXRvcn0iKQogICAgICAgICAgICBj
  >> "!B64TMP!" echo b250aW51ZQogICAgICAgIG1pZCA9IG1vbml0b3IuZ2V0KCJpZCIpIG9yIG1vbml0b3IuZ2V0KCJt
  >> "!B64TMP!" echo b25pdG9ySWQiKSBvciAiPyIKICAgICAgICBuYW1lID0gbW9uaXRvci5nZXQoIm5hbWUiKSBvciAi
  >> "!B64TMP!" echo KHVubmFtZWQpIgogICAgICAgIHN0YXRlID0gKG1vbml0b3IuZ2V0KCJzdGF0ZSIpIG9yIG1vbml0
  >> "!B64TMP!" echo b3IuZ2V0KCJzdGF0dXMiKQogICAgICAgICAgICAgICAgIG9yICgiYWN0aXZlIiBpZiBtb25pdG9y
  >> "!B64TMP!" echo LmdldCgiYWN0aXZlIikgZWxzZSAicGF1c2VkIikpCiAgICAgICAgcHJpbnQoZiJ7bn0uIHttaWR9
  >> "!B64TMP!" echo IOKAlCB7bmFtZX0gKHtzdGF0ZX0pIikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9f
  >> "!B64TMP!" echo bWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_list.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_get.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_get.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_get.py" "!TARGET!\local-web-search\scripts\web_monitor_get.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_get.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_get.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1880791886.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
  >> "!B64TMP!" echo YnkgSUQsIGluY2x1ZGluZyBpdHMgY29uZmlndXJhdGlvbiBhbmQKY3VycmVudCBzdGF0ZSAodGhl
  >> "!B64TMP!" echo IGZpcmVjcmF3bF9tb25pdG9yX2dldCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo bW9uaXRvcl9nZXQucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWlu
  >> "!B64TMP!" echo ZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhl
  >> "!B64TMP!" echo IHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhl
  >> "!B64TMP!" echo IHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0
  >> "!B64TMP!" echo MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBO
  >> "!B64TMP!" echo T1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2Ny
  >> "!B64TMP!" echo aXB0LgoKUHJpbnRzIHRoZSBtb25pdG9yIGFzIHByZXR0eSBKU09OLiBgLS1qc29uYCBwcmludHMg
  >> "!B64TMP!" echo dGhlIHJhdyBBUEkgcmVzcG9uc2UKaW5zdGVhZC4gVGhpcyBkb2VzIG5vdCBydW4gb3IgbW9kaWZ5
  >> "!B64TMP!" echo IHRoZSBtb25pdG9yLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09VTlQgZmVh
  >> "!B64TMP!" echo dHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tFWSwgYW5k
  >> "!B64TMP!" echo IEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRoZQpjbG91
  >> "!B64TMP!" echo ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmlt
  >> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
  >> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
  >> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
  >> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBh
  >> "!B64TMP!" echo cmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgo
  >> "!B64TMP!" echo Ii0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRvcl9nZXQucHkgPGlkPiBbLS1q
  >> "!B64TMP!" echo c29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgbW9uaXRvcl9pZCA9
  >> "!B64TMP!" echo IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBhcmdzWzE6XQoKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0
  >> "!B64TMP!" echo aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIk1P
  >> "!B64TMP!" echo TklUT1IgR0VUIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNv
  >> "!B64TMP!" echo bi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRh
  >> "!B64TMP!" echo LCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAg
  >> "!B64TMP!" echo ICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_get.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_update.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_update.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_update.py" "!TARGET!\local-web-search\scripts\web_monitor_update.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_update.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_update.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS508901295.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXRjaCBhbiBleGlzdGluZyBGaXJlY3Jhd2wgbW9u
  >> "!B64TMP!" echo aXRvciBieSBJRCAodGhlIGZpcmVjcmF3bF9tb25pdG9yX3VwZGF0ZQpNQ1AgdG9vbCk6IGNoYW5n
  >> "!B64TMP!" echo ZSBpdHMgbmFtZSwgYWN0aXZlL3BhdXNlZCBzdGF0dXMsIHNjaGVkdWxlLCB0YXJnZXRzLCBnb2Fs
  >> "!B64TMP!" echo LApqdWRnaW5nLCB3ZWJob29rLCBub3RpZmljYXRpb25zLCBvciByZXRlbnRpb24g4oCUIHRoZXNl
  >> "!B64TMP!" echo IGNoYW5nZXMgYWZmZWN0IGZ1dHVyZQpzY2hlZHVsZWQgY2hlY2tzLgoKVXNhZ2U6CiAgICBweXRo
  >> "!B64TMP!" echo b24gd2ViX21vbml0b3JfdXBkYXRlLnB5IDxpZD4gKC0tYm9keSAney4uLn0nIHwgLS1ib2R5LWZp
  >> "!B64TMP!" echo bGUgcGF0Y2guanNvbikKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25d
  >> "!B64TMP!" echo CgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUg
  >> "!B64TMP!" echo KERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBh
  >> "!B64TMP!" echo dXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2su
  >> "!B64TMP!" echo cHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJl
  >> "!B64TMP!" echo cwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3
  >> "!B64TMP!" echo aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2su
  >> "!B64TMP!" echo cHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpgLS1ib2R5YCBpcyB0aGUgcGF0Y2gg
  >> "!B64TMP!" echo YXMgSlNPTiAoc2FtZSBvYmplY3QgdGhlIE1DUCB0b29sJ3MgYGJvZHlgIHBhcmFtZXRlcgp0YWtl
  >> "!B64TMP!" echo cyk7IGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVhZC4gUHJpbnRzIHRo
  >> "!B64TMP!" echo ZSB1cGRhdGVkCm1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHByaW50cyB0aGUgcmF3
  >> "!B64TMP!" echo IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFD
  >> "!B64TMP!" echo Q09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9y
  >> "!B64TMP!" echo IHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhl
  >> "!B64TMP!" echo bS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQo
  >> "!B64TMP!" echo MCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmly
  >> "!B64TMP!" echo ZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxm
  >> "!B64TMP!" echo LWhlYWwKaW1wb3J0IHdlYl9tb25pdG9yX2NyZWF0ZSAgIyBzaWJsaW5nOiBzaGFyZWQgLS1ib2R5
  >> "!B64TMP!" echo IC8gLS1ib2R5LWZpbGUgcmVhZGluZwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
  >> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX3VwZGF0ZS5weSA8aWQ+ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiLS1ib2R5LWZpbGUgcGF0Y2guanNvbikgWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0t
  >> "!B64TMP!" echo anNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gd2ViX21vbml0b3JfY3JlYXRlLnJlYWRfYm9k
  >> "!B64TMP!" echo eV9hcmcoYXJncykKICAgIGlmIGVycjoKICAgICAgICBwcmludChlcnIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
  >> "!B64TMP!" echo L21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJQQVRDSCIsCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAg
  >> "!B64TMP!" echo ICBwcmludChmIk1PTklUT1IgVVBEQVRFIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhp
  >> "!B64TMP!" echo bnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAg
  >> "!B64TMP!" echo ICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09
  >> "!B64TMP!" echo ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_update.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_delete.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_delete.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_delete.py" "!TARGET!\local-web-search\scripts\web_monitor_delete.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_delete.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_delete.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS969626275.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQZXJtYW5lbnRseSBkZWxldGUgYSBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo bW9uaXRvciBieSBJRCBhbmQgc3RvcCBpdHMgZnV0dXJlIHNjaGVkdWxlCih0aGUgZmlyZWNyYXds
  >> "!B64TMP!" echo X21vbml0b3JfZGVsZXRlIE1DUCB0b29sKS4gVGhpcyBjYW5ub3QgYmUgdW5kb25lLgoKVXNhZ2U6
  >> "!B64TMP!" echo CiAgICBweXRob24gd2ViX21vbml0b3JfZGVsZXRlLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVh
  >> "!B64TMP!" echo bGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVu
  >> "!B64TMP!" echo Z2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2Fs
  >> "!B64TMP!" echo bHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5i
  >> "!B64TMP!" echo YXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVh
  >> "!B64TMP!" echo bCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9y
  >> "!B64TMP!" echo dCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDi
  >> "!B64TMP!" echo gJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBhIGNvbmZpcm1hdGlvbiAocGx1cyB0aGUg
  >> "!B64TMP!" echo QVBJJ3MgcmVzcG9uc2UgYm9keSB3aGVuIG9uZSBpcyByZXR1cm5lZCkuCmAtLWpzb25gIHByaW50
  >> "!B64TMP!" echo cyB0aGUgcmF3IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmly
  >> "!B64TMP!" echo ZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJF
  >> "!B64TMP!" echo Q1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3
  >> "!B64TMP!" echo bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBl
  >> "!B64TMP!" echo eHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0
  >> "!B64TMP!" echo aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQpp
  >> "!B64TMP!" echo bXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGll
  >> "!B64TMP!" echo bnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1h
  >> "!B64TMP!" echo aW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBh
  >> "!B64TMP!" echo cmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRv
  >> "!B64TMP!" echo cl9kZWxldGUucHkgPGlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMgogICAgbW9uaXRvcl9pZCA9IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBh
  >> "!B64TMP!" echo cmdzWzE6XQoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiAr
  >> "!B64TMP!" echo IHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJERUxFVEUiKQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
  >> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgREVMRVRFIEZBSUxFRCBmb3Ige21vbml0b3Jf
  >> "!B64TMP!" echo aWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAg
  >> "!B64TMP!" echo ICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlm
  >> "!B64TMP!" echo IGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MAogICAgcHJpbnQoZiJNb25pdG9yIHttb25pdG9yX2lkfSBkZWxldGVkLiIpCiAgICBpZiBkYXRh
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAK
  >> "!B64TMP!" echo CgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_delete.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_run.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_run.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_run.py" "!TARGET!\local-web-search\scripts\web_monitor_run.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_run.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_run.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2084907039.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJRdWV1ZSBhbiBpbW1lZGlhdGUgY2hlY2sgZm9yIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIG1vbml0b3IsIG91dHNpZGUgaXRzIG5vcm1hbApzY2hlZHVsZSAodGhlIGZpcmVj
  >> "!B64TMP!" echo cmF3bF9tb25pdG9yX3J1biBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfbW9uaXRv
  >> "!B64TMP!" echo cl9ydW4ucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo IHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFy
  >> "!B64TMP!" echo ZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUg
  >> "!B64TMP!" echo bG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVl
  >> "!B64TMP!" echo c3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4
  >> "!B64TMP!" echo IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVl
  >> "!B64TMP!" echo ZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoK
  >> "!B64TMP!" echo UHJpbnRzIHRoZSBxdWV1ZWQgY2hlY2sgYXMgcHJldHR5IEpTT04uIGAtLWpzb25gIHByaW50cyB0
  >> "!B64TMP!" echo aGUgcmF3IEFQSSByZXNwb25zZQppbnN0ZWFkLiBGb2xsb3cgdGhlIGNoZWNrIHdpdGggd2ViX21v
  >> "!B64TMP!" echo bml0b3JfY2hlY2tzLnB5IC8gd2ViX21vbml0b3JfY2hlY2sucHkuCgpOT1RFOiBtb25pdG9ycyBh
  >> "!B64TMP!" echo cmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQgYW4gQVBJIGtleSAo
  >> "!B64TMP!" echo c2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
  >> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhvc3RlZCBzdGFjayBt
  >> "!B64TMP!" echo YXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMK
  >> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
  >> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
  >> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
  >> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX3J1bi5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAyCiAgICBtb25pdG9yX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpzb24i
  >> "!B64TMP!" echo IGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRv
  >> "!B64TMP!" echo ci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9ydW4iLAogICAgICAgICAgICAgICAgICAgICAgIG1l
  >> "!B64TMP!" echo dGhvZD0iUE9TVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYi
  >> "!B64TMP!" echo TU9OSVRPUiBSVU4gRkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChq
  >> "!B64TMP!" echo c29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEsIGluZGVudD0yKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
  >> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_run.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_checks.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_checks.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_checks.py" "!TARGET!\local-web-search\scripts\web_monitor_checks.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_checks.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_checks.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS313295973.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBoaXN0b3JpY2FsIGNoZWNrcyBvZiBh
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBtb25pdG9yICh0aGUKZmlyZWNyYXdsX21vbml0b3JfY2hlY2tzIE1DUCB0b29s
  >> "!B64TMP!" echo KSwgb3B0aW9uYWxseSBmaWx0ZXJlZCBieSBzdGF0dXMgYW5kCnBhZ2luYXRlZC4KClVzYWdlOgog
  >> "!B64TMP!" echo ICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrcy5weSA8aWQ+IFstLXN0YXR1cyBxdWV1ZWR8cnVu
  >> "!B64TMP!" echo bmluZ3xjb21wbGV0ZWR8ZmFpbGVkfHBhcnRpYWxdCiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBp
  >> "!B64TMP!" echo ZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9y
  >> "!B64TMP!" echo IHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFy
  >> "!B64TMP!" echo dHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5k
  >> "!B64TMP!" echo IHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7
  >> "!B64TMP!" echo IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tv
  >> "!B64TMP!" echo ZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0
  >> "!B64TMP!" echo IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBjaGVjazogYE4uIDxjaGVja0lk
  >> "!B64TMP!" echo PiA8c3RhdHVzPiA8Y3JlYXRlZEF0PmAuIGAtLWpzb25gCnByaW50cyB0aGUgcmF3IEFQSSByZXNw
  >> "!B64TMP!" echo b25zZSBpbnN0ZWFkLiBSZWFkIG9uZSBjaGVjaydzIHBhZ2UtbGV2ZWwgcmVzdWx0cwp3aXRoIHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX2NoZWNrLnB5LgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
  >> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
  >> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
  >> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
  >> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
  >> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgpTVEFUVVNFUyA9ICgicXVldWVk
  >> "!B64TMP!" echo IiwgInJ1bm5pbmciLCAiY29tcGxldGVkIiwgImZhaWxlZCIsICJwYXJ0aWFsIikKCgpkZWYgbWFp
  >> "!B64TMP!" echo bigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFy
  >> "!B64TMP!" echo Z3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9tb25pdG9y
  >> "!B64TMP!" echo X2NoZWNrcy5weSA8aWQ+ICIKICAgICAgICAgICAgICAiWy0tc3RhdHVzIHF1ZXVlZHxydW5uaW5n
  >> "!B64TMP!" echo fGNvbXBsZXRlZHxmYWlsZWR8cGFydGlhbF0gIgogICAgICAgICAgICAgICJbLS1saW1pdCBOXSBb
  >> "!B64TMP!" echo LS1vZmZzZXQgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
  >> "!B64TMP!" echo ICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBzdGF0dXMsIGxpbWl0LCBvZmZzZXQsIGFzX2pz
  >> "!B64TMP!" echo b24gPSBOb25lLCBOb25lLCBOb25lLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4o
  >> "!B64TMP!" echo YXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXN0YXR1cyIgYW5k
  >> "!B64TMP!" echo IGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc3RhdHVz
  >> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgICAgICBpZiBzdGF0dXMgbm90IGluIFNUQVRVU0VTOgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tc3RhdHVzOiB7c3RhdHVzfSAiCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBmIihvbmUgb2YgeycsICcuam9pbihTVEFUVVNFUyl9KSIsIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWxpbWl0
  >> "!B64TMP!" echo IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICB0
  >> "!B64TMP!" echo cnk6CiAgICAgICAgICAgICAgICBsaW1pdCA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNl
  >> "!B64TMP!" echo cHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLWxpbWl0OiB7
  >> "!B64TMP!" echo YXJnc1tpXX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAg
  >> "!B64TMP!" echo ICAgIGVsaWYgYSA9PSAiLS1vZmZzZXQiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG9mZnNldCA9IGludChh
  >> "!B64TMP!" echo cmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGYiaW52YWxpZCAtLW9mZnNldDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhw
  >> "!B64TMP!" echo ZWN0ZWQgYXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDIKICAgICAgICBpICs9IDEKCiAgICBxdWVyeSA9IHt9CiAgICBpZiBzdGF0dXMgaXMgbm90IE5v
  >> "!B64TMP!" echo bmU6CiAgICAgICAgcXVlcnlbInN0YXR1cyJdID0gc3RhdHVzCiAgICBpZiBsaW1pdCBpcyBub3Qg
  >> "!B64TMP!" echo Tm9uZToKICAgICAgICBxdWVyeVsibGltaXQiXSA9IGxpbWl0CiAgICBpZiBvZmZzZXQgaXMgbm90
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcXVlcnlbIm9mZnNldCJdID0gb2Zmc2V0CgogICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo IGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRvci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9jaGVj
  >> "!B64TMP!" echo a3MiLAogICAgICAgICAgICAgICAgICAgICAgIG1ldGhvZD0iR0VUIiwgcXVlcnk9cXVlcnkpCiAg
  >> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDS1Mg
  >> "!B64TMP!" echo RkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
  >> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCgogICAgY2hlY2tzID0gZGF0YS5nZXQoImNoZWNrcyIpCiAg
  >> "!B64TMP!" echo ICBpZiBub3QgaXNpbnN0YW5jZShjaGVja3MsIGxpc3QpOgogICAgICAgIGNoZWNrcyA9IGRhdGEu
  >> "!B64TMP!" echo Z2V0KCJkYXRhIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKGNoZWNrcywgbGlzdCk6CiAgICAgICAg
  >> "!B64TMP!" echo Y2hlY2tzID0gZGF0YSBpZiBpc2luc3RhbmNlKGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5v
  >> "!B64TMP!" echo dCBjaGVja3M6CiAgICAgICAgcHJpbnQoIihubyBjaGVja3MpIikKICAgICAgICByZXR1cm4gMAog
  >> "!B64TMP!" echo ICAgZm9yIG4sIGNoZWNrIGluIGVudW1lcmF0ZShjaGVja3MsIDEpOgogICAgICAgIGlmIG5vdCBp
  >> "!B64TMP!" echo c2luc3RhbmNlKGNoZWNrLCBkaWN0KToKICAgICAgICAgICAgcHJpbnQoZiJ7bn0uIHtjaGVja30i
  >> "!B64TMP!" echo KQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGNpZCA9IGNoZWNrLmdldCgiaWQiKSBvciBj
  >> "!B64TMP!" echo aGVjay5nZXQoImNoZWNrSWQiKSBvciAiPyIKICAgICAgICBjc3RhdHVzID0gY2hlY2suZ2V0KCJz
  >> "!B64TMP!" echo dGF0dXMiKSBvciAiPyIKICAgICAgICB3aGVuID0gKGNoZWNrLmdldCgiY3JlYXRlZEF0Iikgb3Ig
  >> "!B64TMP!" echo Y2hlY2suZ2V0KCJzdGFydGVkQXQiKQogICAgICAgICAgICAgICAgb3IgY2hlY2suZ2V0KCJjb21w
  >> "!B64TMP!" echo bGV0ZWRBdCIpIG9yICIiKQogICAgICAgIHByaW50KGYie259LiB7Y2lkfSB7Y3N0YXR1c30ge3do
  >> "!B64TMP!" echo ZW59Ii5yc3RyaXAoKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
  >> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_checks.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_check.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_check.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_check.py" "!TARGET!\local-web-search\scripts\web_monitor_check.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_check.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_check.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS763834523.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
  >> "!B64TMP!" echo Y2hlY2sgYW5kIGl0cyBwYWdlLWxldmVsIHJlc3VsdHMgKHRoZQpmaXJlY3Jhd2xfbW9uaXRvcl9j
  >> "!B64TMP!" echo aGVjayBNQ1AgdG9vbCkuIFBhZ2VzIHJlcG9ydCBgc2FtZWAsIGBuZXdgLCBgY2hhbmdlZGAsCmBy
  >> "!B64TMP!" echo ZW1vdmVkYCwgb3IgYGVycm9yYDsgZ29hbCBqdWRnaW5nIGFkZHMgYSBtZWFuaW5nZnVsLWNoYW5n
  >> "!B64TMP!" echo ZSBkZWNpc2lvbi4KTWFya2Rvd24gdHJhY2tpbmcgcmV0dXJucyBhIHVuaWZpZWQgdGV4dCBkaWZm
  >> "!B64TMP!" echo OyBKU09OIHRyYWNraW5nIHJldHVybnMgZmllbGQKcGF0aHMgd2l0aCBwcmV2aW91cy9jdXJyZW50
  >> "!B64TMP!" echo IHZhbHVlcy4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrLnB5IDxpZD4gPGNo
  >> "!B64TMP!" echo ZWNrSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sg
  >> "!B64TMP!" echo aXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24p
  >> "!B64TMP!" echo LCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwph
  >> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29u
  >> "!B64TMP!" echo bmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2Vy
  >> "!B64TMP!" echo cyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1
  >> "!B64TMP!" echo biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMg
  >> "!B64TMP!" echo dGhlIGNoZWNrIChjb25maWd1cmF0aW9uLCBwYWdlIHJlc3VsdHMsIGRpZmZzKSBhcyBwcmV0dHkg
  >> "!B64TMP!" echo SlNPTi4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCgpOT1RF
  >> "!B64TMP!" echo OiBtb25pdG9ycyBhcmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQg
  >> "!B64TMP!" echo YW4gQVBJIGtleSAoc2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9
  >> "!B64TMP!" echo aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhv
  >> "!B64TMP!" echo c3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9z
  >> "!B64TMP!" echo CmltcG9ydCBzeXMKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5h
  >> "!B64TMP!" echo YnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92
  >> "!B64TMP!" echo MS9tb25pdG9yIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAyIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKSBvciBhcmdzWzFdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3
  >> "!B64TMP!" echo ZWJfbW9uaXRvcl9jaGVjay5weSA8aWQ+IDxjaGVja0lkPiBbLS1qc29uXSIsCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAgICBtb25pdG9yX2lkLCBjaGVj
  >> "!B64TMP!" echo a19pZCA9IGFyZ3MKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tb25pdG9y
  >> "!B64TMP!" echo LyIgKyBzdHIobW9uaXRvcl9pZCkgKyAiL2NoZWNrcy8iCiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo KyBzdHIoY2hlY2tfaWQpLCBtZXRob2Q9IkdFVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDSyBGQUlMRUQgZm9yIHttb25pdG9yX2lkfS97
  >> "!B64TMP!" echo Y2hlY2tfaWR9OiB7ZX0iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
  >> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEsIGluZGVudD0y
  >> "!B64TMP!" echo KSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0
  >> "!B64TMP!" echo KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_check.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_search.py" "!TARGET!\local-web-search\scripts\web_research_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2278314517.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggcmVzZWFyY2ggcGFwZXJzIHZpYSB0aGUg
  >> "!B64TMP!" echo RmlyZWNyYXdsIHJlc2VhcmNoIGluZGV4ICh0aGUKZmlyZWNyYXdsX3Jlc2VhcmNoX3NlYXJjaF9w
  >> "!B64TMP!" echo YXBlcnMgTUNQIHRvb2wpOiBwYXBlciBtZXRhZGF0YSBhbmQgYWJzdHJhY3RzCmFjcm9zcyBiaW9t
  >> "!B64TMP!" echo ZWRpY2FsLCBsaWZlLXNjaWVuY2UsIGFuZCBjbGluaWNhbCBsaXRlcmF0dXJlIChQdWJNZWQsIGJp
  >> "!B64TMP!" echo b1J4aXYsCm1lZFJ4aXYpIGFsb25nc2lkZSBhclhpdiBhbmQgb3RoZXIgc2NpZW50aWZpYyBzb3Vy
  >> "!B64TMP!" echo Y2VzLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSAiPHF1ZXJ5PiIg
  >> "!B64TMP!" echo Wy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJl
  >> "!B64TMP!" echo YWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMg
  >> "!B64TMP!" echo c2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9u
  >> "!B64TMP!" echo IGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSBy
  >> "!B64TMP!" echo ZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyB0aGUgcmFu
  >> "!B64TMP!" echo a2VkIHBhcGVycyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIHBh
  >> "!B64TMP!" echo cGVyOgoKICAgICMjIFtwYXBlcklkXSB0aXRsZQogICAgQXV0aG9yczogbmFtZTsgbmFtZTsgK04g
  >> "!B64TMP!" echo bW9yZQogICAgYWJzdHJhY3QgKHVwIHRvIDYwMCBjaGFycykKClNldmVyYWwgZGlzdGluY3QgZnJh
  >> "!B64TMP!" echo bWluZ3Mgb2YgdGhlIHNhbWUgcXVlc3Rpb24gc3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpJbnNw
  >> "!B64TMP!" echo ZWN0IG9uZSBwYXBlciB3aXRoIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5LiBgLS1qc29uYCBwcmlu
  >> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2VhcmNoIHRvb2xzIG5l
  >> "!B64TMP!" echo ZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Npb25zCihzZXQgRklS
  >> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jh
  >> "!B64TMP!" echo d2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0YWNrIG1heSBub3Qg
  >> "!B64TMP!" echo ZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBh
  >> "!B64TMP!" echo dGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkK
  >> "!B64TMP!" echo aW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xp
  >> "!B64TMP!" echo ZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9w
  >> "!B64TMP!" echo YXBlcnMiKQoKTUFYX0FVVEhPUlMgPSAxNQpNQVhfQUJTVFJBQ1RfQ0hBUlMgPSA2MDAKTUFYX0FG
  >> "!B64TMP!" echo RklMX0NIQVJTID0gNjAKTUFYX0FVVEhPUlNfTElORV9DSEFSUyA9IDQwMAoKCmRlZiBkaXNwbGF5
  >> "!B64TMP!" echo X2lkKHBhcGVyKToKICAgIHJldHVybiBwYXBlci5nZXQoInByaW1hcnlJZCIpIG9yIHBhcGVyLmdl
  >> "!B64TMP!" echo dCgicGFwZXJJZCIpIG9yICJtaXNzaW5nLXByaW1hcnktaWQiCgoKZGVmIGZtdF9hdXRob3JzKGF1
  >> "!B64TMP!" echo dGhvcnMpOgogICAgIiIiYEF1dGhvcnM6IGE7IGIgKGFmZmlsaWF0aW9uKTsgK04gbW9yZWAgb3Ig
  >> "!B64TMP!" echo Tm9uZSAobWlycm9ycyB0aGUgTUNQIHRvb2wpLiIiIgogICAgaWYgbm90IGF1dGhvcnM6CiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIE5vbmUKICAgIGlmIGlzaW5zdGFuY2UoYXV0aG9ycywgc3RyKToKICAgICAgICBu
  >> "!B64TMP!" echo YW1lcyA9IFtzLnN0cmlwKCkgZm9yIHMgaW4gYXV0aG9ycy5zcGxpdCgiLCIpIGlmIHMuc3RyaXAo
  >> "!B64TMP!" echo KV0KICAgICAgICBpZiBub3QgbmFtZXM6CiAgICAgICAgICAgIHJldHVybiBOb25lCiAgICAgICAg
  >> "!B64TMP!" echo dG90YWwsIHNob3duID0gbGVuKG5hbWVzKSwgbmFtZXNbOk1BWF9BVVRIT1JTXQogICAgZWxzZToK
  >> "!B64TMP!" echo ICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShhdXRob3JzLCBsaXN0KSBvciBub3QgYXV0aG9yczoK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICB0b3RhbCA9IGxlbihhdXRob3JzKQogICAg
  >> "!B64TMP!" echo ICAgIHNob3duID0gW10KICAgICAgICBmb3IgYSBpbiBhdXRob3JzWzpNQVhfQVVUSE9SU106CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIGlmIGlzaW5zdGFuY2UoYSwgZGljdCk6CiAgICAgICAgICAgICAgICBhZmYgPSAo
  >> "!B64TMP!" echo YS5nZXQoImFmZmlsaWF0aW9uIikgb3IgIiIpLnN0cmlwKCkKICAgICAgICAgICAgICAgIG5hbWUg
  >> "!B64TMP!" echo PSBhLmdldCgibmFtZSIpIG9yICI/IgogICAgICAgICAgICAgICAgc2hvd24uYXBwZW5kKCJ7fSAo
  >> "!B64TMP!" echo e30pIi5mb3JtYXQobmFtZSwgYWZmWzpNQVhfQUZGSUxfQ0hBUlNdKQogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIGlmIGFmZiBlbHNlIG5hbWUpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBzaG93bi5hcHBlbmQoc3RyKGEpKQogICAgZXh0cmEgPSAiOyAre30gbW9yZSIuZm9y
  >> "!B64TMP!" echo bWF0KHRvdGFsIC0gTUFYX0FVVEhPUlMpIGlmIHRvdGFsID4gTUFYX0FVVEhPUlMgXAogICAgICAg
  >> "!B64TMP!" echo IGVsc2UgIiIKICAgIHJldHVybiAoIkF1dGhvcnM6ICIgKyAiOyAiLmpvaW4oc2hvd24pICsgZXh0
  >> "!B64TMP!" echo cmEpWzpNQVhfQVVUSE9SU19MSU5FX0NIQVJTXQoKCmRlZiBmbXRfaGl0cyhyZXN1bHRzKToKICAg
  >> "!B64TMP!" echo ICIiIkZvcm1hdCByYW5rZWQgcGFwZXIgcmVzdWx0cyAobWlycm9ycyB0aGUgTUNQIHRvb2wncyBm
  >> "!B64TMP!" echo b3JtYXR0ZXIpLiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVz
  >> "!B64TMP!" echo dWx0cykiCiAgICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBu
  >> "!B64TMP!" echo b3QgaXNpbnN0YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbGluZXMgPSBbIiMjIFt7fV0ge30iLmZvcm1h
  >> "!B64TMP!" echo dChkaXNwbGF5X2lkKHIpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgci5n
  >> "!B64TMP!" echo ZXQoInRpdGxlIikgb3IgIih1bnRpdGxlZCkiKV0KICAgICAgICBhdXRob3JzID0gZm10X2F1dGhv
  >> "!B64TMP!" echo cnMoci5nZXQoImF1dGhvcnMiKSkKICAgICAgICBpZiBhdXRob3JzOgogICAgICAgICAgICBsaW5l
  >> "!B64TMP!" echo cy5hcHBlbmQoYXV0aG9ycykKICAgICAgICBhYnN0cmFjdCA9IChyLmdldCgiYWJzdHJhY3QiKSBv
  >> "!B64TMP!" echo ciAiKG5vIGFic3RyYWN0KSIpCiAgICAgICAgYWJzdHJhY3QgPSAiICIuam9pbihhYnN0cmFjdC5z
  >> "!B64TMP!" echo cGxpdCgpKVs6TUFYX0FCU1RSQUNUX0NIQVJTXQogICAgICAgIGxpbmVzLmFwcGVuZChhYnN0cmFj
  >> "!B64TMP!" echo dCkKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5lcykpCiAgICByZXR1cm4gIlxu
  >> "!B64TMP!" echo XG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBleHRyYWN0X3Jlc3VsdHMoZGF0YSk6CiAgICAiIiJGaW5k
  >> "!B64TMP!" echo IHRoZSBwYXBlci1yZXN1bHQgbGlzdCBpbiB0aGUgQVBJIHJlc3BvbnNlLiIiIgogICAgcmVzdWx0
  >> "!B64TMP!" echo cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0cywgbGlzdCk6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIHJlc3VsdHMKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpCiAg
  >> "!B64TMP!" echo ICBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGFuZCBpc2luc3RhbmNlKHBheWxvYWQuZ2V0
  >> "!B64TMP!" echo KCJyZXN1bHRzIiksIGxpc3QpOgogICAgICAgIHJldHVybiBwYXlsb2FkWyJyZXN1bHRzIl0KICAg
  >> "!B64TMP!" echo IGlmIGlzaW5zdGFuY2UoZGF0YSwgbGlzdCk6CiAgICAgICAgcmV0dXJuIGRhdGEKICAgIHJldHVy
  >> "!B64TMP!" echo biBbXQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2
  >> "!B64TMP!" echo WzE6XSBpZiBhICE9ICItLWpzb24iXQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2
  >> "!B64TMP!" echo WzE6XQogICAgcXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfcmVzZWFyY2hfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
  >> "!B64TMP!" echo LS1qc29uXScsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9wYXBlcnMiLCBtZXRob2Q9
  >> "!B64TMP!" echo IlBPU1QiLAogICAgICAgICAgICAgICAgICAgICAgIGJvZHk9eyJxdWVyeSI6IHF1ZXJ5fSkKICAg
  >> "!B64TMP!" echo IGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBTRUFSQ0gg
  >> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoZm10X2hpdHMoZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_inspect.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_inspect.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_inspect.py" "!TARGET!\local-web-search\scripts\web_research_inspect.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_inspect.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_inspect.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1065362198.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnNwZWN0IG9uZSByZXNlYXJjaCBwYXBlciB2aWEg
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCByZXNlYXJjaCBpbmRleCAodGhlCmZpcmVjcmF3bF9yZXNlYXJjaF9pbnNw
  >> "!B64TMP!" echo ZWN0X3BhcGVyIE1DUCB0b29sKTogY2Fub25pY2FsIG1ldGFkYXRhIGZvciBhIHBhcGVyCklEIHN1
  >> "!B64TMP!" echo Y2ggYXMgYW4gYXJYaXYsIFBNQywgUE1JRCwgb3IgRE9JIGlkZW50aWZpZXIuCgpVc2FnZToKICAg
  >> "!B64TMP!" echo IHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSA8cGFwZXJJZD4gWy0tanNvbl0KCkV4YW1w
  >> "!B64TMP!" echo bGVzOgogICAgcHl0aG9uIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IGFyeGl2OjE3MDYuMDM3NjIK
  >> "!B64TMP!" echo ICAgIHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSBkb2k6MTAuMTAxNi9qLm5ldW5ldC4y
  >> "!B64TMP!" echo MDI1LjEwODA5NQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhp
  >> "!B64TMP!" echo cyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5z
  >> "!B64TMP!" echo dXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rp
  >> "!B64TMP!" echo b24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJl
  >> "!B64TMP!" echo IHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5z
  >> "!B64TMP!" echo dXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSBw
  >> "!B64TMP!" echo YXBlcidzIG1ldGFkYXRhIGV4YWN0bHkgbGlrZSB0aGUgTUNQIHRvb2wgZG9lczoKCiAgICAjIHRp
  >> "!B64TMP!" echo dGxlCiAgICBQYXBlciBJRDogLi4uCiAgICBJRHM6IG5hbWVzcGFjZTp2YWx1ZSwgLi4uCiAgICBB
  >> "!B64TMP!" echo dXRob3JzOiAuLi4KICAgIENhdGVnb3JpZXM6IC4uLgogICAgRGF0ZXM6IGNyZWF0ZWQgLi4uOyB1
  >> "!B64TMP!" echo cGRhdGVkIC4uLgogICAgIyMgQWJzdHJhY3QKICAgIC4uLgoKRmluZCBwYXBlcnMgdG8gaW5zcGVj
  >> "!B64TMP!" echo dCB3aXRoIHdlYl9yZXNlYXJjaF9zZWFyY2gucHkuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3CkFQ
  >> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBhY2NvdW50IHdpdGggcmVzZWFyY2ggcGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRo
  >> "!B64TMP!" echo ZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UK
  >> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
  >> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
  >> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAppbXBvcnQgd2ViX3Jlc2VhcmNoX3NlYXJjaCAgIyBzaWJs
  >> "!B64TMP!" echo aW5nOiBzaGFyZWQgcGFwZXIgZm9ybWF0dGVycwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNl
  >> "!B64TMP!" echo YXJjaC9wYXBlcnMiKQoKCmRlZiBmbXRfcGFwZXJfbWV0YWRhdGEocGFwZXIpOgogICAgIiIiRm9y
  >> "!B64TMP!" echo bWF0IG9uZSBwYXBlcidzIG1ldGFkYXRhIChtaXJyb3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRl
  >> "!B64TMP!" echo cikuIiIiCiAgICBpZiBub3QgcGFwZXI6CiAgICAgICAgcmV0dXJuICIocGFwZXIgbm90IGZvdW5k
  >> "!B64TMP!" echo KSIKICAgIGxpbmVzID0gWyIjICIgKyAocGFwZXIuZ2V0KCJ0aXRsZSIpIG9yICIodW50aXRsZWQp
  >> "!B64TMP!" echo IiksICIiXQogICAgbGluZXMuYXBwZW5kKCJQYXBlciBJRDoge30iLmZvcm1hdChwYXBlci5nZXQo
  >> "!B64TMP!" echo InBhcGVySWQiKSBvciAiPyIpKQogICAgaWRzID0gW10KICAgIGZvciBuYW1lc3BhY2UsIHZhbHVl
  >> "!B64TMP!" echo cyBpbiAocGFwZXIuZ2V0KCJpZHMiKSBvciB7fSkuaXRlbXMoKToKICAgICAgICBpZiBpc2luc3Rh
  >> "!B64TMP!" echo bmNlKHZhbHVlcywgbGlzdCk6CiAgICAgICAgICAgIGlkcy5leHRlbmQoInt9Ont9Ii5mb3JtYXQo
  >> "!B64TMP!" echo bmFtZXNwYWNlLCB2KSBmb3IgdiBpbiB2YWx1ZXMpCiAgICAgICAgZWxpZiB2YWx1ZXMgaXMgbm90
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgICAgIGlkcy5hcHBlbmQoInt9Ont9Ii5mb3JtYXQobmFtZXNwYWNlLCB2
  >> "!B64TMP!" echo YWx1ZXMpKQogICAgaWYgaWRzOgogICAgICAgIGxpbmVzLmFwcGVuZCgiSURzOiAiICsgIiwgIi5q
  >> "!B64TMP!" echo b2luKGlkcykpCiAgICBhdXRob3JzID0gd2ViX3Jlc2VhcmNoX3NlYXJjaC5mbXRfYXV0aG9ycyhw
  >> "!B64TMP!" echo YXBlci5nZXQoImF1dGhvcnMiKSkKICAgIGlmIGF1dGhvcnM6CiAgICAgICAgbGluZXMuYXBwZW5k
  >> "!B64TMP!" echo KGF1dGhvcnMpCiAgICBjYXRlZ29yaWVzID0gcGFwZXIuZ2V0KCJjYXRlZ29yaWVzIikKICAgIGlm
  >> "!B64TMP!" echo IGlzaW5zdGFuY2UoY2F0ZWdvcmllcywgbGlzdCkgYW5kIGNhdGVnb3JpZXM6CiAgICAgICAgbGlu
  >> "!B64TMP!" echo ZXMuYXBwZW5kKCJDYXRlZ29yaWVzOiAiICsgIiwgIi5qb2luKHN0cihjKSBmb3IgYyBpbiBjYXRl
  >> "!B64TMP!" echo Z29yaWVzKSkKICAgIGRhdGVzID0gW10KICAgIGlmIHBhcGVyLmdldCgiY3JlYXRlZERhdGUiKToK
  >> "!B64TMP!" echo ICAgICAgICBkYXRlcy5hcHBlbmQoImNyZWF0ZWQgIiArIHN0cihwYXBlclsiY3JlYXRlZERhdGUi
  >> "!B64TMP!" echo XSkpCiAgICBpZiBwYXBlci5nZXQoInVwZGF0ZURhdGUiKToKICAgICAgICBkYXRlcy5hcHBlbmQo
  >> "!B64TMP!" echo InVwZGF0ZWQgIiArIHN0cihwYXBlclsidXBkYXRlRGF0ZSJdKSkKICAgIGlmIGRhdGVzOgogICAg
  >> "!B64TMP!" echo ICAgIGxpbmVzLmFwcGVuZCgiRGF0ZXM6ICIgKyAiOyAiLmpvaW4oZGF0ZXMpKQogICAgbGluZXMu
  >> "!B64TMP!" echo YXBwZW5kKCIiKQogICAgbGluZXMuYXBwZW5kKCIjIyBBYnN0cmFjdCIpCiAgICBsaW5lcy5hcHBl
  >> "!B64TMP!" echo bmQoIiAiLmpvaW4oKHBhcGVyLmdldCgiYWJzdHJhY3QiKSBvciAiKG5vIGFic3RyYWN0KSIpLnNw
  >> "!B64TMP!" echo bGl0KCkpKQogICAgcmV0dXJuICJcbiIuam9pbihsaW5lcykKCgpkZWYgZXh0cmFjdF9wYXBlcihk
  >> "!B64TMP!" echo YXRhKToKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5n
  >> "!B64TMP!" echo ZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBwYXBlciA9IHBheWxvYWQuZ2V0KCJwYXBl
  >> "!B64TMP!" echo ciIpCiAgICBpZiBpc2luc3RhbmNlKHBhcGVyLCBkaWN0KToKICAgICAgICByZXR1cm4gcGFwZXIK
  >> "!B64TMP!" echo ICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCkgYW5kIChwYXlsb2FkLmdldCgicGFwZXJJ
  >> "!B64TMP!" echo ZCIpIG9yIHBheWxvYWQuZ2V0KCJ0aXRsZSIpKToKICAgICAgICByZXR1cm4gcGF5bG9hZAogICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAxIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IDxwYXBl
  >> "!B64TMP!" echo cklkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgcGFw
  >> "!B64TMP!" echo ZXJfaWQgPSBhcmdzWzBdCgogICAgcGF0aCA9ICIvdjEvcmVzZWFyY2gvcGFwZXJzLyIgKyB1cmxs
  >> "!B64TMP!" echo aWIucGFyc2UucXVvdGUocGFwZXJfaWQsIHNhZmU9IiIpCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZjLmNhbGwocGF0aCwgbWV0aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToK
  >> "!B64TMP!" echo ICAgICAgICBwcmludChmIlJFU0VBUkNIIElOU1BFQ1QgRkFJTEVEIGZvciB7cGFwZXJfaWR9OiB7
  >> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
  >> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
  >> "!B64TMP!" echo cHJpbnQoZm10X3BhcGVyX21ldGFkYXRhKGV4dHJhY3RfcGFwZXIoZGF0YSkpKQogICAgcmV0dXJu
  >> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_inspect.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_related.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_related.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_related.py" "!TARGET!\local-web-search\scripts\web_research_related.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_related.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_related.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS293208104.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGaW5kIHJlc2VhcmNoIHBhcGVycyByZWxhdGVkIHRv
  >> "!B64TMP!" echo IHNlZWQgcGFwZXJzIHZpYSB0aGUgRmlyZWNyYXdsIGNpdGF0aW9uCmdyYXBoICh0aGUgZmlyZWNy
  >> "!B64TMP!" echo YXdsX3Jlc2VhcmNoX3JlbGF0ZWRfcGFwZXJzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9u
  >> "!B64TMP!" echo IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQgLi4uXSAtLWludGVudCAi
  >> "!B64TMP!" echo d2hhdCB0byByYW5rIGZvciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1t
  >> "!B64TMP!" echo b2RlIHNpbWlsYXJ8Y2l0ZXJzfHJlZmVyZW5jZXNdIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlm
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3Ig
  >> "!B64TMP!" echo dGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0
  >> "!B64TMP!" echo cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQg
  >> "!B64TMP!" echo cmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsg
  >> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29m
  >> "!B64TMP!" echo Zi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3Qg
  >> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgpPbmUgdG8gdGVuIHNlZWQgcGFwZXIgSURzIChwb3NpdGlvbmFsKTsg
  >> "!B64TMP!" echo dGhlIGZpcnN0IGlzIHRoZSBwcmltYXJ5IHNlZWQsIHRoZQpyZXN0IGFyZSBhbmNob3JzLiBgLS1p
  >> "!B64TMP!" echo bnRlbnRgIChyZXF1aXJlZCkgaXMgYSBzaG9ydCBuYXR1cmFsLWxhbmd1YWdlCmRlc2NyaXB0aW9u
  >> "!B64TMP!" echo IHRoYXQgcmFua3MgdGhlIGNhbmRpZGF0ZXMuIGAtLW1vZGVgIGRlZmF1bHRzIHRvIGBzaW1pbGFy
  >> "!B64TMP!" echo YAooY28tY2l0YXRpb24gLyBiaWJsaW9ncmFwaGljIGNvdXBsaW5nKTsgYGNpdGVyc2AgcmV0dXJu
  >> "!B64TMP!" echo cyBwYXBlcnMgY2l0aW5nIGEKc2VlZCwgYHJlZmVyZW5jZXNgIHBhcGVycyBjaXRlZCBieSBhIHNl
  >> "!B64TMP!" echo ZWQuCgpQcmludHMgdGhlIHJhbmtlZCBjYW5kaWRhdGVzIGxpa2Ugd2ViX3Jlc2VhcmNoX3NlYXJj
  >> "!B64TMP!" echo aC5weSwgdGhlbgpgKHBvb2xTaXplPU4pYCBhbmQgYW55IGBub3RlOmAgZnJvbSB0aGUgQVBJLiBg
  >> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
  >> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
  >> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
  >> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
  >> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
  >> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
  >> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
  >> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfcmVzZWFyY2hfc2VhcmNoICAj
  >> "!B64TMP!" echo IHNpYmxpbmc6IHNoYXJlZCBwYXBlciBmb3JtYXR0ZXJzCgpFTkRQT0lOVCA9IGZjLnVybCgiL3Yx
  >> "!B64TMP!" echo L3Jlc2VhcmNoL3JlbGF0ZWQiKQoKTU9ERVMgPSAoInNpbWlsYXIiLCAiY2l0ZXJzIiwgInJlZmVy
  >> "!B64TMP!" echo ZW5jZXMiKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAg
  >> "!B64TMP!" echo c2VlZHMsIGludGVudCwgbW9kZSwgYXNfanNvbiA9IFtdLCBOb25lLCBOb25lLCBGYWxzZQogICAg
  >> "!B64TMP!" echo aSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
  >> "!B64TMP!" echo ICBpZiBhID09ICItLWludGVudCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgaW50ZW50ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYSA9PSAiLS1t
  >> "!B64TMP!" echo b2RlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
  >> "!B64TMP!" echo ICBtb2RlID0gYXJnc1tpXQogICAgICAgICAgICBpZiBtb2RlIG5vdCBpbiBNT0RFUzoKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1vZGU6IHttb2RlfSAob25lIG9mIHsnLCAnLmpv
  >> "!B64TMP!" echo aW4oTU9ERVMpfSkiLAogICAgICAgICAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWVkcy5hcHBlbmQo
  >> "!B64TMP!" echo YSkKICAgICAgICBpICs9IDEKCiAgICBpZiBub3Qgc2VlZHMgb3Igbm90IGludGVudDoKICAgICAg
  >> "!B64TMP!" echo ICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQg
  >> "!B64TMP!" echo Li4uXSAnCiAgICAgICAgICAgICAgJy0taW50ZW50ICJ3aGF0IHRvIHJhbmsgZm9yIiAnCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgJ1stLW1vZGUgc2ltaWxhcnxjaXRlcnN8cmVmZXJlbmNlc10gWy0tanNvbl0nLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCAxIDw9IGxlbihzZWVk
  >> "!B64TMP!" echo cykgPD0gMTA6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgb25lIHRvIHRlbiBzZWVkIHBhcGVyIElE
  >> "!B64TMP!" echo cyAoZmlyc3QgaXMgdGhlIHByaW1hcnkgc2VlZCkiLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIGJvZHkgPSB7InNlZWRfaWRzIjogc2VlZHMsICJp
  >> "!B64TMP!" echo bnRlbnQiOiBpbnRlbnR9CiAgICBpZiBtb2RlOgogICAgICAgIGJvZHlbIm1vZGUiXSA9IG1vZGUK
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9yZXNlYXJjaC9yZWxhdGVkIiwg
  >> "!B64TMP!" echo bWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAg
  >> "!B64TMP!" echo ICAgICBwcmludChmIlJFU0VBUkNIIFJFTEFURUQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
  >> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
  >> "!B64TMP!" echo CiAgICBwcmludCh3ZWJfcmVzZWFyY2hfc2VhcmNoLmZtdF9oaXRzKAogICAgICAgIHdlYl9yZXNl
  >> "!B64TMP!" echo YXJjaF9zZWFyY2guZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHBvb2xfc2l6ZSA9IHBheWxv
  >> "!B64TMP!" echo YWQuZ2V0KCJwb29sU2l6ZSIpIG9yIDAKICAgIHByaW50KGYiKHBvb2xTaXplPXtwb29sX3NpemV9
  >> "!B64TMP!" echo KSIpCiAgICBub3RlID0gcGF5bG9hZC5nZXQoIm5vdGUiKQogICAgaWYgbm90ZToKICAgICAgICBw
  >> "!B64TMP!" echo cmludChmIm5vdGU6IHtub3RlfSIpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21h
  >> "!B64TMP!" echo aW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_related.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_read.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_read.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_read.py" "!TARGET!\local-web-search\scripts\web_research_read.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_read.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_read.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS691893132.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGluLWJvZHkgcGFzc2FnZXMgZnJvbSBvbmUg
  >> "!B64TMP!" echo cmVzZWFyY2ggcGFwZXIgdGhhdCBhcmUgcmVsZXZhbnQgdG8gYQpzcGVjaWZpYyBxdWVzdGlvbiAo
  >> "!B64TMP!" echo dGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9yZWFkX3BhcGVyIE1DUCB0b29sKS4gRnVsbCB0ZXh0IGlz
  >> "!B64TMP!" echo CmF2YWlsYWJsZSBvbmx5IGZvciBpbmRleGVkIHBhcGVycy4KClVzYWdlOgogICAgcHl0aG9uIHdl
  >> "!B64TMP!" echo Yl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklkPiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0KCkV4YW1w
  >> "!B64TMP!" echo bGU6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3JlYWQucHkgYXJ4aXY6MTcwNi4wMzc2MiAiaG93
  >> "!B64TMP!" echo IGlzIGF0dGVudGlvbiBjb21wdXRlZD8iCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMg
  >> "!B64TMP!" echo YXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2Ft
  >> "!B64TMP!" echo ZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVx
  >> "!B64TMP!" echo dWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81
  >> "!B64TMP!" echo eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBu
  >> "!B64TMP!" echo ZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQu
  >> "!B64TMP!" echo CgpQcmludHMgdGhlIG1hdGNoaW5nIHBhc3NhZ2VzIHNlcGFyYXRlZCBieSBgLS0tYCBsaW5lcyAo
  >> "!B64TMP!" echo bGlrZSB0aGUgTUNQIHRvb2wpLCBvcgphIG5vdGljZSB3aGVuIG5vIGZ1bGwgdGV4dCBpcyBhdmFp
  >> "!B64TMP!" echo bGFibGUuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9U
  >> "!B64TMP!" echo RTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3bCBhY2NvdW50IHdpdGggcmVzZWFyY2gg
  >> "!B64TMP!" echo cGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJM
  >> "!B64TMP!" echo PWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRoZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1o
  >> "!B64TMP!" echo b3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
  >> "!B64TMP!" echo cwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5w
  >> "!B64TMP!" echo YXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xf
  >> "!B64TMP!" echo YXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoK
  >> "!B64TMP!" echo RU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNlYXJjaC9wYXBlcnMiKQoKCmRlZiBtYWluKCkgLT4g
  >> "!B64TMP!" echo aW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24i
  >> "!B64TMP!" echo XQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2WzE6XQogICAgaWYgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo ICE9IDIgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpIG9yIGFyZ3NbMV0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklk
  >> "!B64TMP!" echo PiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0nLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gMgogICAgcGFwZXJfaWQsIHF1ZXN0aW9uID0gYXJncwoKICAgIHBhdGgg
  >> "!B64TMP!" echo PSAoIi92MS9yZXNlYXJjaC9wYXBlcnMvIiArIHVybGxpYi5wYXJzZS5xdW90ZShwYXBlcl9pZCwg
  >> "!B64TMP!" echo c2FmZT0iIikKICAgICAgICAgICAgKyAiL3JlYWQiKQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBm
  >> "!B64TMP!" echo Yy5jYWxsKHBhdGgsIG1ldGhvZD0iUE9TVCIsIGJvZHk9eyJxdWVzdGlvbiI6IHF1ZXN0aW9ufSkK
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBSRUFE
  >> "!B64TMP!" echo IEZBSUxFRCBmb3Ige3BhcGVyX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGlm
  >> "!B64TMP!" echo IGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0
  >> "!B64TMP!" echo YSkpCiAgICAgICAgcmV0dXJuIDAKCiAgICBwYXNzYWdlcyA9IGRhdGEuZ2V0KCJwYXNzYWdlcyIp
  >> "!B64TMP!" echo CiAgICBpZiBwYXNzYWdlcyBpcyBOb25lOgogICAgICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0
  >> "!B64TMP!" echo YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgXAogICAgICAgICAgICBl
  >> "!B64TMP!" echo bHNlIGRhdGEKICAgICAgICBwYXNzYWdlcyA9IHBheWxvYWQuZ2V0KCJwYXNzYWdlcyIpCiAgICBp
  >> "!B64TMP!" echo ZiBub3QgaXNpbnN0YW5jZShwYXNzYWdlcywgbGlzdCkgb3Igbm90IHBhc3NhZ2VzOgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCIobm8gZnVsbC10ZXh0IHBhc3NhZ2VzIGF2YWlsYWJsZSBmb3IgdGhpcyBwYXBlciki
  >> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAwCiAgICB0ZXh0cyA9IFtwLmdldCgidGV4dCIpIGlmIGlzaW5zdGFu
  >> "!B64TMP!" echo Y2UocCwgZGljdCkgZWxzZSBzdHIocCkKICAgICAgICAgICAgIGZvciBwIGluIHBhc3NhZ2VzXQog
  >> "!B64TMP!" echo ICAgcHJpbnQoIlxuLS0tXG4iLmpvaW4odCBmb3IgdCBpbiB0ZXh0cyBpZiB0KSkKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_read.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_github_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_github_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_github_search.py" "!TARGET!\local-web-search\scripts\web_github_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_github_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_github_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1125861393.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggaW5kZXhlZCBwdWJsaWMgR2l0SHViIGlz
  >> "!B64TMP!" echo c3VlLCBwdWxsLXJlcXVlc3QsIGFuZCBSRUFETUUgY29udGVudCB2aWEKdGhlIEZpcmVjcmF3bCBy
  >> "!B64TMP!" echo ZXNlYXJjaCBpbmRleCAodGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9zZWFyY2hfZ2l0aHViIE1DUAp0
  >> "!B64TMP!" echo b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9naXRodWJfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
  >> "!B64TMP!" echo LS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVh
  >> "!B64TMP!" echo Y2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBz
  >> "!B64TMP!" echo Y3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24g
  >> "!B64TMP!" echo ZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJl
  >> "!B64TMP!" echo dHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSByYW5r
  >> "!B64TMP!" echo ZWQgbWF0Y2hlcyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIGhp
  >> "!B64TMP!" echo dDoKCiAgICBbcmVwbyMxMjNdIChwdWxsX3JlcXVlc3QsIDUgc2VnbWVudHMpCiAgICBodHRwczov
  >> "!B64TMP!" echo L2dpdGh1Yi5jb20vLi4uCiAgICBtYXRjaGVkIGNvbnRlbnQgKHVwIHRvIDEyMDAgY2hhcnMpCgpg
  >> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
  >> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
  >> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
  >> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
  >> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
  >> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
  >> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
  >> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2Vh
  >> "!B64TMP!" echo cmNoL3NlYXJjaC9naXRodWIiKQoKTUFYX0NPTlRFTlRfQ0hBUlMgPSAxMjAwCgoKZGVmIGZtdF9n
  >> "!B64TMP!" echo aXRodWIocmVzdWx0cyk6CiAgICAiIiJGb3JtYXQgcmFua2VkIEdpdEh1YiBtYXRjaGVzIChtaXJy
  >> "!B64TMP!" echo b3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRlcikuIiIiCiAgICBpZiBub3QgcmVzdWx0czoKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gIihubyByZXN1bHRzKSIKICAgIGJsb2NrcyA9IFtdCiAgICBmb3IgciBpbiBy
  >> "!B64TMP!" echo ZXN1bHRzOgogICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHIsIGRpY3QpOgogICAgICAgICAgICBi
  >> "!B64TMP!" echo bG9ja3MuYXBwZW5kKHN0cihyKSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBsaW5lcyA9
  >> "!B64TMP!" echo IFtdCiAgICAgICAgcmVwbyA9IHIuZ2V0KCJyZXBvIikgb3IgIj8iCiAgICAgICAgbnVtYmVyID0g
  >> "!B64TMP!" echo ci5nZXQoIm51bWJlciIpCiAgICAgICAgaWYgbnVtYmVyIGlzIE5vbmUgYW5kIHIuZ2V0KCJwYWdl
  >> "!B64TMP!" echo VHlwZSIpIGlzIE5vbmU6CiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChmIlt7cmVwb31dIFJFQURN
  >> "!B64TMP!" echo RSIpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcmVmID0gZiIje251bWJlcn0iIGlmIG51bWJl
  >> "!B64TMP!" echo ciBpcyBub3QgTm9uZSBlbHNlICIiCiAgICAgICAgICAgIG1ldGFfcGFydHMgPSBbc3RyKHIuZ2V0
  >> "!B64TMP!" echo KCJwYWdlVHlwZSIpIG9yICIiKV0KICAgICAgICAgICAgaWYgci5nZXQoInNlZ21lbnRDb3VudCIp
  >> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgbWV0YV9wYXJ0cy5hcHBlbmQoZiJ7clsnc2VnbWVudENvdW50J119
  >> "!B64TMP!" echo IHNlZ21lbnRzIikKICAgICAgICAgICAgbWV0YSA9ICIsICIuam9pbihwIGZvciBwIGluIG1ldGFf
  >> "!B64TMP!" echo cGFydHMgaWYgcCkKICAgICAgICAgICAgbGluZXMuYXBwZW5kKGYiW3tyZXBvfXtyZWZ9XSIgKyAo
  >> "!B64TMP!" echo ZiIgKHttZXRhfSkiIGlmIG1ldGEgZWxzZSAiIikpCiAgICAgICAgdXJsID0gci5nZXQoInJlYWRt
  >> "!B64TMP!" echo ZVVybCIpIG9yIHIuZ2V0KCJ1cmwiKQogICAgICAgIGlmIHVybDoKICAgICAgICAgICAgbGluZXMu
  >> "!B64TMP!" echo YXBwZW5kKHVybCkKICAgICAgICBib2R5ID0gKHIuZ2V0KCJjb250ZW50TWQiKSBvciByLmdldCgi
  >> "!B64TMP!" echo c25pcHBldCIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgbGluZXMuYXBwZW5kKGJvZHlbOk1BWF9D
  >> "!B64TMP!" echo T05URU5UX0NIQVJTXSBpZiBib2R5IGVsc2UgIihubyBjb250ZW50KSIpCiAgICAgICAgYmxvY2tz
  >> "!B64TMP!" echo LmFwcGVuZCgiXG4iLmpvaW4obGluZXMpKQogICAgcmV0dXJuICJcblxuIi5qb2luKGJsb2NrcykK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBzeXMuYXJndlsxOl0g
  >> "!B64TMP!" echo aWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsxOl0K
  >> "!B64TMP!" echo ICAgIHF1ZXJ5ID0gIiAiLmpvaW4oYXJncykuc3RyaXAoKQogICAgaWYgbm90IHF1ZXJ5OgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KCd1c2FnZTogd2ViX2dpdGh1Yl9zZWFyY2gucHkgIjxxdWVyeT4iIFstLWpzb25d
  >> "!B64TMP!" echo JywgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgdHJ5OgogICAgICAgIGRh
  >> "!B64TMP!" echo dGEgPSBmYy5jYWxsKCIvdjEvcmVzZWFyY2gvc2VhcmNoL2dpdGh1YiIsIG1ldGhvZD0iUE9TVCIs
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICAgICAgICAgYm9keT17InF1ZXJ5IjogcXVlcnl9KQogICAgZXhjZXB0
  >> "!B64TMP!" echo IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkdJVEhVQiBTRUFSQ0ggRkFJTEVEOiB7
  >> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
  >> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
  >> "!B64TMP!" echo cmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3VsdHMgaXMgTm9uZToKICAg
  >> "!B64TMP!" echo ICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3RhbmNlKGRhdGEuZ2V0KCJk
  >> "!B64TMP!" echo YXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAgICAgcmVzdWx0cyA9IHBh
  >> "!B64TMP!" echo eWxvYWQuZ2V0KCJyZXN1bHRzIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKHJlc3VsdHMsIGxpc3Qp
  >> "!B64TMP!" echo OgogICAgICAgIHJlc3VsdHMgPSBbXQogICAgcHJpbnQoZm10X2dpdGh1YihyZXN1bHRzKSkKICAg
  >> "!B64TMP!" echo IHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4o
  >> "!B64TMP!" echo KSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_github_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_developer_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_developer_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_developer_search.py" "!TARGET!\local-web-search\scripts\web_developer_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_developer_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_developer_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4120898073.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIEZpcmVjcmF3bCBkZXZlbG9wZXIg
  >> "!B64TMP!" echo aW5kZXgg4oCUIGJ1aWx0IGZvciBjb2RpbmcgYWdlbnRzLCBjb3ZlcmluZwpHaXRIdWIgaXNzdWVz
  >> "!B64TMP!" echo LCBtZXJnZWQgcHVsbCByZXF1ZXN0cywgcmVwb3NpdG9yeSBSRUFETUVzLCBhbmQgY3VyYXRlZApk
  >> "!B64TMP!" echo b2N1bWVudGF0aW9uIHNpdGVzICh0aGUgZmlyZWNyYXdsX2RldmVsb3Blcl9zZWFyY2ggTUNQIHRv
  >> "!B64TMP!" echo b2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2RldmVsb3Blcl9zZWFyY2gucHkgIjxxdWVyeT4i
  >> "!B64TMP!" echo IFstLXNraWxscy1vbmx5XSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJz
  >> "!B64TMP!" echo IGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNh
  >> "!B64TMP!" echo bWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJl
  >> "!B64TMP!" echo cXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0Mjkv
  >> "!B64TMP!" echo NXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1Qg
  >> "!B64TMP!" echo bmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0
  >> "!B64TMP!" echo LgoKVXNlIGl0IGZvciBkZXZlbG9wZXIgcXVlc3Rpb25zIOKAlCBjb2RlIGJlaGF2aW91ciwgYSBs
  >> "!B64TMP!" echo aWJyYXJ5IG9yIGZyYW1ld29yaywgYW4KQVBJIGNvbnRyYWN0LCBhbiBlcnJvciBtZXNzYWdlLCBv
  >> "!B64TMP!" echo ciBhIGtub3duIGJ1Zy4gYC0tc2tpbGxzLW9ubHlgIGxpbWl0cyB0aGUKc2VhcmNoIHRvIGFnZW50
  >> "!B64TMP!" echo LXNraWxsIGZpbGVzLiBQcmludHMgdGhlIHJhbmtlZCByZXN1bHRzIGV4YWN0bHkgbGlrZSB0aGUg
  >> "!B64TMP!" echo TUNQCnRvb2wgZG9lcyDigJQgZm9yIGVhY2ggaGl0OgoKICAgICMjIFtpZF0gKGtpbmQpIHRpdGxl
  >> "!B64TMP!" echo CiAgICBodHRwczovLy4uLgogICAgbWF0Y2hlZCBwYXNzYWdlcyAodXAgdG8gMTIwMCBjaGFycywg
  >> "!B64TMP!" echo c2VwYXJhdGVkIGJ5IC0tLSkKCmAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSSByZXNwb25zZSBp
  >> "!B64TMP!" echo bnN0ZWFkLgoKTk9URTogZGV2ZWxvcGVyIHNlYXJjaCBuZWVkcyBhIEZpcmVjcmF3bCBhY2NvdW50
  >> "!B64TMP!" echo IHdpdGggZGV2ZWxvcGVyLXNlYXJjaApwZXJtaXNzaW9ucyAoc2V0IEZJUkVDUkFXTF9BUElfS0VZ
  >> "!B64TMP!" echo LCBhbmQKRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhl
  >> "!B64TMP!" echo IGNsb3VkIEFQSSk7IHRoZQpzZWxmLWhvc3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSBpdC4KIiIi
  >> "!B64TMP!" echo CmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
  >> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXds
  >> "!B64TMP!" echo X2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwK
  >> "!B64TMP!" echo CkVORFBPSU5UID0gZmMudXJsKCIvdjEvZGV2ZWxvcGVyL3NlYXJjaCIpCgpNQVhfUEFTU0FHRV9D
  >> "!B64TMP!" echo SEFSUyA9IDEyMDAKCgpkZWYgZm10X2RldmVsb3BlcihyZXN1bHRzKToKICAgICIiIkZvcm1hdCBy
  >> "!B64TMP!" echo YW5rZWQgZGV2ZWxvcGVyLWluZGV4IHJlc3VsdHMgKG1pcnJvcnMgdGhlIE1DUCBmb3JtYXR0ZXIp
  >> "!B64TMP!" echo LiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVzdWx0cykiCiAg
  >> "!B64TMP!" echo ICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBub3QgaXNpbnN0
  >> "!B64TMP!" echo YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGNvbnRpbnVlCiAgICAgICAgcmlkID0gci5nZXQoImlkIikgb3IgIj8iCiAgICAgICAga2lu
  >> "!B64TMP!" echo ZCA9IHN0cihyaWQpLnNwbGl0KCI6IiwgMSlbMF0KICAgICAgICBsaW5lcyA9IFsiIyMgW3t9XXt9
  >> "!B64TMP!" echo IHt9Ii5mb3JtYXQocmlkLCBmIiAoe2tpbmR9KSIgaWYga2luZCBlbHNlICIiLAogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICByLmdldCgidGl0bGUiKSBvciAiKHVudGl0bGVk
  >> "!B64TMP!" echo KSIpXQogICAgICAgIGlmIHIuZ2V0KCJ1cmwiKToKICAgICAgICAgICAgbGluZXMuYXBwZW5kKHJb
  >> "!B64TMP!" echo InVybCJdKQogICAgICAgIHBhc3NhZ2VzID0gci5nZXQoInBhc3NhZ2VzIikKICAgICAgICBib2R5
  >> "!B64TMP!" echo ID0gIiIKICAgICAgICBpZiBpc2luc3RhbmNlKHBhc3NhZ2VzLCBsaXN0KToKICAgICAgICAgICAg
  >> "!B64TMP!" echo Ym9keSA9ICJcbi0tLVxuIi5qb2luKChwLmdldCgidGV4dCIpIG9yICIiKQogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgaWYgaXNpbnN0YW5jZShwLCBkaWN0KSBlbHNlIHN0cihwKQog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZm9yIHAgaW4gcGFzc2FnZXMpLnN0cmlw
  >> "!B64TMP!" echo KCkKICAgICAgICBsaW5lcy5hcHBlbmQoYm9keVs6TUFYX1BBU1NBR0VfQ0hBUlNdIGlmIGJvZHkg
  >> "!B64TMP!" echo ZWxzZSAiKG5vIGNvbnRlbnQpIikKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5l
  >> "!B64TMP!" echo cykpCiAgICByZXR1cm4gIlxuXG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBtYWluKCkgLT4gaW50Ogog
  >> "!B64TMP!" echo ICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24iIGFuZCBh
  >> "!B64TMP!" echo ICE9ICItLXNraWxscy1vbmx5Il0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsx
  >> "!B64TMP!" echo Ol0KICAgIHNraWxsc19vbmx5ID0gIi0tc2tpbGxzLW9ubHkiIGluIHN5cy5hcmd2WzE6XQogICAg
  >> "!B64TMP!" echo cXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoJ3VzYWdlOiB3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSAiPHF1ZXJ5PiIgWy0tc2tpbGxz
  >> "!B64TMP!" echo LW9ubHldIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKCiAgICBib2R5ID0geyJxdWVyeSI6IHF1ZXJ5fQogICAgaWYgc2tpbGxzX29ubHk6
  >> "!B64TMP!" echo CiAgICAgICAgYm9keVsic2tpbGxzIl0gPSAib25seSIKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZjLmNhbGwoIi92MS9kZXZlbG9wZXIvc2VhcmNoIiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5
  >> "!B64TMP!" echo KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkRFVkVMT1BFUiBT
  >> "!B64TMP!" echo RUFSQ0ggRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gMAogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3Vs
  >> "!B64TMP!" echo dHMgaXMgTm9uZToKICAgICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3Rh
  >> "!B64TMP!" echo bmNlKGRhdGEuZ2V0KCJkYXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAg
  >> "!B64TMP!" echo ICAgcmVzdWx0cyA9IHBheWxvYWQuZ2V0KCJyZXN1bHRzIikgb3IgcGF5bG9hZC5nZXQoImRldmVs
  >> "!B64TMP!" echo b3BlciIpCiAgICBpZiBub3QgaXNpbnN0YW5jZShyZXN1bHRzLCBsaXN0KToKICAgICAgICByZXN1
  >> "!B64TMP!" echo bHRzID0gW10KICAgIHByaW50KGZtdF9kZXZlbG9wZXIocmVzdWx0cykpCiAgICByZXR1cm4gMAoK
  >> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_developer_search.py"
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
call :genkey BLESSTOKEN

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
>> "!TARGET!\.env" echo # ---- Browser rendering engine for Firecrawl ^(installer Step 4^) ----
>> "!TARGET!\.env" echo COMPOSE_PROFILES=!BROWSER_ENGINE!
>> "!TARGET!\.env" echo PLAYWRIGHT_MICROSERVICE_URL=!PW_URL!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Browserless token ^(only used if COMPOSE_PROFILES=browserless above^) ----
>> "!TARGET!\.env" echo BROWSERLESS_TOKEN=!BLESSTOKEN!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo LOGGING_LEVEL=info
if defined OPENAI_BASE_URL (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- LLM for Firecrawl AI features ----
  >> "!TARGET!\.env" echo OPENAI_BASE_URL=!OPENAI_BASE_URL!
  >> "!TARGET!\.env" echo OPENAI_API_KEY=!OPENAI_API_KEY!
  if defined MODEL_NAME >> "!TARGET!\.env" echo MODEL_NAME=!MODEL_NAME!
)
if defined FC_API_KEY (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- Firecrawl account ^(cloud API^) for account-only tools ----
  >> "!TARGET!\.env" echo FIRECRAWL_API_URL=!FC_API_URL!
  >> "!TARGET!\.env" echo FIRECRAWL_API_KEY=!FC_API_KEY!
)

echo Injecting SearXNG secret into settings.yml ...
powershell -NoProfile -Command "(Get-Content -Raw '!TARGET!\config\searxng\settings.yml') -replace '__SEARXNG_SECRET_PLACEHOLDER__', '!SECRET!' | Set-Content -NoNewline '!TARGET!\config\searxng\settings.yml'"

if defined FC_API_KEY goto skill_full
echo Installing the core-only local-web-search skill (no Firecrawl account)...
if exist "!TARGET!\local-web-search\scripts\web_agent.py" del /Q "!TARGET!\local-web-search\scripts\web_agent.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_agent_status.py" del /Q "!TARGET!\local-web-search\scripts\web_agent_status.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_interact.py" del /Q "!TARGET!\local-web-search\scripts\web_interact.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_interact_stop.py" del /Q "!TARGET!\local-web-search\scripts\web_interact_stop.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_parse.py" del /Q "!TARGET!\local-web-search\scripts\web_parse.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_create.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_create.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_list.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_list.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_get.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_get.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_update.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_update.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_delete.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_delete.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_run.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_run.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_checks.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_checks.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_check.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_check.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_search.py" del /Q "!TARGET!\local-web-search\scripts\web_research_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_inspect.py" del /Q "!TARGET!\local-web-search\scripts\web_research_inspect.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_related.py" del /Q "!TARGET!\local-web-search\scripts\web_research_related.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_read.py" del /Q "!TARGET!\local-web-search\scripts\web_research_read.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_github_search.py" del /Q "!TARGET!\local-web-search\scripts\web_github_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_developer_search.py" del /Q "!TARGET!\local-web-search\scripts\web_developer_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\SKILL-core.md" copy /Y "!TARGET!\local-web-search\SKILL-core.md" "!TARGET!\local-web-search\SKILL.md" >nul
:skill_full
REM SKILL-core.md is a build-time variant - never part of an installed skill.
if exist "!TARGET!\local-web-search\SKILL-core.md" del /Q "!TARGET!\local-web-search\SKILL-core.md" >nul 2>&1
REM LLM tools and the SKILL-llm.md section are kept only when an LLM is connected.
if defined OPENAI_BASE_URL goto llm_skill_keep
echo Skipping LLM extraction in the skill (no LLM connected)...
if exist "!TARGET!\local-web-search\scripts\web_extract.py" del /Q "!TARGET!\local-web-search\scripts\web_extract.py" >nul 2>&1
goto llm_skill_done
:llm_skill_keep
if exist "!TARGET!\local-web-search\SKILL-llm.md" type "!TARGET!\local-web-search\SKILL-llm.md" >> "!TARGET!\local-web-search\SKILL.md"
:llm_skill_done
if exist "!TARGET!\local-web-search\SKILL-llm.md" del /Q "!TARGET!\local-web-search\SKILL-llm.md" >nul 2>&1

echo Installing the local-web-search agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
xcopy /E /I /Y /Q "!TARGET!\local-web-search" "!SKILL_DIR!" >nul
if errorlevel 1 (
  echo   [WARNING] Could not copy the local-web-search skill to !SKILL_DIR!.
) else (
  > "!TARGET!\local-web-search\install-dir.txt" echo !TARGET!
  > "!SKILL_DIR!\install-dir.txt" echo !TARGET!
  echo   Agent skill installed: !SKILL_DIR!
)

REM How long to wait for a just-launched Docker engine to come online (seconds).
set "DD_TIMEOUT=300"
if defined LOCAL_SEARCH_DOCKER_TIMEOUT set "DD_TIMEOUT=!LOCAL_SEARCH_DOCKER_TIMEOUT!"
if not defined DD_LAUNCHED goto docker_engine_ready
echo Waiting for the Docker engine to come online - up to !DD_TIMEOUT! seconds...
set /a DD_WAIT=0
:docker_wait
timeout /t 5 /nobreak >nul 2>&1
if errorlevel 1 ping -n 6 127.0.0.1 >nul 2>&1
set /a DD_WAIT+=5
docker info >nul 2>&1
if not errorlevel 1 goto docker_engine_ready
if !DD_WAIT! geq !DD_TIMEOUT! (
  echo [ERROR] The Docker engine did not come online within !DD_TIMEOUT! seconds.
  echo   Check Docker Desktop for errors, wait until it says "running",
  echo   then re-run this installer.
  pause & exit /b 1
)
set /a "DD_MOD=DD_WAIT %% 15"
if !DD_MOD! equ 0 echo     ... still waiting !DD_WAIT!s
goto docker_wait
:docker_engine_ready
if defined DD_LAUNCHED echo [OK] Docker engine is online after !DD_WAIT!s.

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
echo   local-web-search skill:              %USERPROFILE%\.agents\skills\local-web-search
echo.
echo   If your agent was already running, restart it so it picks up
echo   the new skill.
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (local-web-search skill, LM Studio, MCP server, direct prompting, etc.).
echo ============================================================
echo.
pause
exit /b 0

REM ===========================================================================
REM  Subroutines
REM ===========================================================================

:llm_intro
echo   Lets Firecrawl do AI extraction ^(/v1/extract^) and summaries.
echo   Recommended: LM Studio  -^>  http://localhost:1234/v1
exit /b 0

:ask_llm
REM  The Firecrawl container reaches a host-side server through host.docker.internal.
set "LLM_URL="
set /p LLM_URL="    Base URL Endpoint [Enter = http://localhost:1234/v1]: "
if "!LLM_URL!"=="" set "LLM_URL=http://localhost:1234/v1"
set "LLM_KEY="
set /p LLM_KEY="    API Key [Enter to skip]: "
set "LLM_MODEL="
set /p LLM_MODEL="    Model name [Enter to skip]: "
set "OPENAI_BASE_URL=!LLM_URL!"
set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://localhost=http://host.docker.internal!"
set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://127.0.0.1=http://host.docker.internal!"
set "OPENAI_API_KEY=!LLM_KEY!"
if "!OPENAI_API_KEY!"=="" set "OPENAI_API_KEY=placeholder"
set "MODEL_NAME="
if not "!LLM_MODEL!"=="" set "MODEL_NAME=!LLM_MODEL!"
echo     ^(Container will reach it at: !OPENAI_BASE_URL!^)
exit /b 0

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
