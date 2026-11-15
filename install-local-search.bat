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
echo   1^) Playwright  - the classic Firecrawl engine ^(default^).
echo   2^) Browserless - stealth mode ^(masks automation fingerprints^);
echo                    better at avoiding Cloudflare/bot-check blocks.
echo   3^) Invisible Playwright - a patched Firefox ^(oss-invisible/playwright^)
echo                    whose fingerprint is generated inside the browser.
echo                    Built locally on first start: ~10 min, ~2 GB.
:ask_engine
set "ENGINE_CHOICE="
set /p ENGINE_CHOICE="  Engine [1=Playwright, 2=Browserless, 3=Invisible; Enter=1]: "
set "BROWSER_ENGINE=playwright"
set "PW_URL=http://playwright-service:3000/scrape"
set "ENGINE_OK="
if "!ENGINE_CHOICE!"=="" set "ENGINE_OK=1"
for %%E in (1 n p) do if /i "!ENGINE_CHOICE!"=="%%E" set "ENGINE_OK=1"
for %%E in (2 y b) do if /i "!ENGINE_CHOICE!"=="%%E" (
  set "ENGINE_OK=1"
  set "BROWSER_ENGINE=browserless"
  set "PW_URL=http://browserless:3000/scrape"
)
for %%E in (3 i) do if /i "!ENGINE_CHOICE!"=="%%E" (
  set "ENGINE_OK=1"
  set "BROWSER_ENGINE=invisible"
  set "PW_URL=http://invisible-playwright:3000/scrape"
)
if not defined ENGINE_OK ( echo   [WARNING] Please enter 1, 2 or 3. & echo. & goto ask_engine )
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
if not exist "!TARGET!\invisible-playwright" mkdir "!TARGET!\invisible-playwright"

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
  >> "!B64TMP!" echo cmluZyBmb3IgRmlyZWNyYXdsIChwcm9maWxlOiBicm93c2VybGVzcykKIyAgICBpbnZpc2libGUt
  >> "!B64TMP!" echo cGxheXdyaWdodCAgcGF0Y2hlZC1GaXJlZm94IHJlbmRlcmluZyBmb3IgRmlyZWNyYXdsLCBidWls
  >> "!B64TMP!" echo dCBsb2NhbGx5CiMgICAgICAgICAgICAgICAgICAgICAgICAgIGZyb20gLi9pbnZpc2libGUtcGxh
  >> "!B64TMP!" echo eXdyaWdodCAocHJvZmlsZTogaW52aXNpYmxlKQojICAgIHJlZGlzICAgICAgICAgICAgICAgcXVl
  >> "!B64TMP!" echo dWUgZm9yIEZpcmVjcmF3bAojICAgIHJhYmJpdG1xICAgICAgICAgICAgbWVzc2FnZSBicm9rZXIg
  >> "!B64TMP!" echo Zm9yIEZpcmVjcmF3bAojICAgIG51cS1wb3N0Z3JlcyAgICAgICAgam9iIHN0YXRlIERCIGZvciBG
  >> "!B64TMP!" echo aXJlY3Jhd2wKIwojICBPbmx5IE9ORSBvZiBwbGF5d3JpZ2h0LXNlcnZpY2UgLyBicm93c2VybGVz
  >> "!B64TMP!" echo cyAvIGludmlzaWJsZS1wbGF5d3JpZ2h0IGFjdHVhbGx5CiMgIHN0YXJ0czogdGhlIGluc3RhbGxl
  >> "!B64TMP!" echo cidzICJCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUiIHF1ZXN0aW9uIHdyaXRlcwojICBDT01QT1NF
  >> "!B64TMP!" echo X1BST0ZJTEVTIHRvIC5lbnYgKGRlZmF1bHQgInBsYXl3cmlnaHQiKSB0byBwaWNrIHdoaWNoIG9u
  >> "!B64TMP!" echo ZSwgYW5kIHBvaW50cwojICBQTEFZV1JJR0hUX01JQ1JPU0VSVklDRV9VUkwgYXQgaXQuIFRoZSBv
  >> "!B64TMP!" echo dGhlcnMgc3RheSBkZWZpbmVkIGJ1dCBkb3JtYW50LgojCiMgIE9ubHkgdGhlIHR3byBob3N0IHBv
  >> "!B64TMP!" echo cnRzIGJlbG93IGFyZSBwdWJsaXNoZWQuIEV2ZXJ5dGhpbmcgZWxzZSBzdGF5cyBvbiB0aGUKIyAg
  >> "!B64TMP!" echo cHJpdmF0ZSAibG9jYWwtc2VhcmNoLW5ldCIgYnJpZGdlIG5ldHdvcmsuCiMKIyAgV29ya3Mgd2l0
  >> "!B64TMP!" echo aCBEb2NrZXIgQU5EIFBvZG1hbiAodGhlIExpbnV4L21hY09TIGluc3RhbGxlciBwcmVmZXJzIFBv
  >> "!B64TMP!" echo ZG1hbiB3aGVuCiMgIGJvdGggYXJlIGluc3RhbGxlZCkuIFR3byB0aGluZ3MgbWFrZSB0aGF0IHNh
  >> "!B64TMP!" echo ZmU6CiMgICAgKiBFdmVyeSBpbWFnZSBpcyBmdWxseSBxdWFsaWZpZWQgKGRvY2tlci5pby8uLi4s
  >> "!B64TMP!" echo IGdoY3IuaW8vLi4uKSwgc28gUG9kbWFuCiMgICAgICBuZXZlciBoYXMgdG8gZ3Vlc3MgYSByZWdp
  >> "!B64TMP!" echo c3RyeSBvciBhc2sgIndoaWNoIG9uZT8iIGZvciBhIHNob3J0IG5hbWUgLQojICAgICAgaW1hZ2Vz
  >> "!B64TMP!" echo IG9ubHkgZXZlciBjb21lIGZyb20gRG9ja2VyIEh1YiBhbmQgR0hDUi4KIyAgICAqIFNlYXJYTkcn
  >> "!B64TMP!" echo cyBiaW5kLW1vdW50ZWQgY29uZmlnIGZvbGRlciBpcyB0dW5lZCBmcm9tIC5lbnYgKHdyaXR0ZW4g
  >> "!B64TMP!" echo YnkKIyAgICAgIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoKSAtIHNlZSB0aGUgU0VBUlhOR19NT1VO
  >> "!B64TMP!" echo VF9PUFRTIC8KIyAgICAgIFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQIG5vdGVzIG9uIHRoZSBzZWFy
  >> "!B64TMP!" echo eG5nIHNlcnZpY2UuCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCm5hbWU6IGxvY2FsLXNlYXJjaAoK
  >> "!B64TMP!" echo c2VydmljZXM6CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIFNlYXJYTkcg4oCUIHByaXZhY3kt
  >> "!B64TMP!" echo cmVzcGVjdGluZyBtZXRhc2VhcmNoIGVuZ2luZSwgZXhwb3NlZCBhcyBhIEpTT04gQVBJLgogICMg
  >> "!B64TMP!" echo UG93ZXJzIGJvdGggeW91ciBBSSBtb2RlbHMgKGRpcmVjdCBKU09OIHF1ZXJpZXMpIGFuZCBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wncyAvdjEvc2VhcmNoLgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICBzZWFyeG5nOgogICAg
  >> "!B64TMP!" echo aW1hZ2U6IGRvY2tlci5pby9zZWFyeG5nL3NlYXJ4bmc6bGF0ZXN0CiAgICBjb250YWluZXJfbmFt
  >> "!B64TMP!" echo ZTogbG9jYWwtc2VhcmNoLXNlYXJ4bmcKICAgIHBvcnRzOgogICAgICAtICIke1NFQVJYTkdfUE9S
  >> "!B64TMP!" echo VDotOTk5MH06ODA4MCIKICAgICMgU0VBUlhOR19NT1VOVF9PUFRTIChmcm9tIC5lbnYpIGFwcGVu
  >> "!B64TMP!" echo ZHMgZXh0cmEgYmluZC1tb3VudCBvcHRpb25zLiBPbiBob3N0cwogICAgIyB3aXRoIFNFTGludXgg
  >> "!B64TMP!" echo KEZlZG9yYSwgUkhFTCwgLi4uKSB0aGUgaW5zdGFsbGVyIHNldHMgaXQgdG8gIix6IiBzbyB0aGUK
  >> "!B64TMP!" echo ICAgICMgY29udGFpbmVyIG1heSByZWFkIC9ldGMvc2VhcnhuZzsgd2l0aG91dCB0aGF0IGxhYmVs
  >> "!B64TMP!" echo IFNlYXJYTkcgZGllcyBhdAogICAgIyBzdGFydC11cCB3aXRoICJjaG93bi9jcC9zZWQ6IC4uLiBQ
  >> "!B64TMP!" echo ZXJtaXNzaW9uIGRlbmllZCIgYW5kIHJlc3RhcnQtbG9vcHMuCiAgICAjIEl0IGlzIGVtcHR5IGV2
  >> "!B64TMP!" echo ZXJ5d2hlcmUgZWxzZSAoV2luZG93cywgbWFjT1MsIFVidW50dSwgLi4uKS4KICAgIHZvbHVtZXM6
  >> "!B64TMP!" echo CiAgICAgIC0gLi9jb25maWcvc2VhcnhuZzovZXRjL3NlYXJ4bmc6cncke1NFQVJYTkdfTU9VTlRf
  >> "!B64TMP!" echo T1BUUzotfQogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0gU0VBUlhOR19CQVNFX1VSTD1odHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0OiR7U0VBUlhOR19QT1JUOi05OTkwfS8KICAgICAgLSBVV1NHSV9XT1JLRVJTPTQK
  >> "!B64TMP!" echo ICAgICAgLSBVV1NHSV9USFJFQURTPTQKICAgICAgLSBTRUFSWE5HX1NFQ1JFVD0ke1NFQVJYTkdf
  >> "!B64TMP!" echo U0VDUkVUfQogICAgICAjIFRoZSBpbWFnZSdzIGVudHJ5cG9pbnQgY2hvd25zIHRoZSBtb3VudGVk
  >> "!B64TMP!" echo IGNvbmZpZyBmb2xkZXIgdG8gaXRzIG93bgogICAgICAjICJzZWFyeG5nIiB1c2VyIHVubGVzcyB0
  >> "!B64TMP!" echo aGlzIGlzICJmYWxzZSIuIFJvb3RsZXNzIFBvZG1hbiB3b3VsZCB0dXJuIHRoZQogICAgICAjIGhv
  >> "!B64TMP!" echo c3QgZmlsZXMgaW50byBhIHN1Yi1VSUQgeW91IGNhbm5vdCBlZGl0IG9yIGRlbGV0ZSwgc28gdGhl
  >> "!B64TMP!" echo IGluc3RhbGxlcgogICAgICAjIHNldHMgImZhbHNlIiB0aGVyZTsgaXQgc3RheXMgInRydWUiICh0
  >> "!B64TMP!" echo aGUgaW1hZ2UgZGVmYXVsdCkgb3RoZXJ3aXNlLgogICAgICAtIEZPUkNFX09XTkVSU0hJUD0ke1NF
  >> "!B64TMP!" echo QVJYTkdfRk9SQ0VfT1dORVJTSElQOi10cnVlfQogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQK
  >> "!B64TMP!" echo ICAgIGNhcF9kcm9wOgogICAgICAtIEFMTAogICAgY2FwX2FkZDoKICAgICAgLSBDSE9XTgogICAg
  >> "!B64TMP!" echo ICAtIFNFVEdJRAogICAgICAtIFNFVFVJRAogICAgbmV0d29ya3M6CiAgICAgIC0gbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoLW5ldAoKICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgIyBGaXJlY3Jhd2wgQVBJIHNlcnZlciAo
  >> "!B64TMP!" echo dGhlIHB1YmxpYy1mYWNpbmcgc2NyYXBpbmcvY3Jhd2wvc2VhcmNoIHNlcnZpY2UpLgogICMgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0KICBmaXJlY3Jhd2w6CiAgICBpbWFnZTogZ2hjci5pby9maXJlY3Jhd2wv
  >> "!B64TMP!" echo ZmlyZWNyYXdsOmxhdGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1maXJlY3Jh
  >> "!B64TMP!" echo d2wKICAgIHBvcnRzOgogICAgICAtICIke0ZJUkVDUkFXTF9QT1JUOi05OTkxfTozMDAyIgogICAg
  >> "!B64TMP!" echo ZW52aXJvbm1lbnQ6CiAgICAgIC0gUE9SVD0zMDAyCiAgICAgIC0gSE9TVD0wLjAuMC4wCiAgICAg
  >> "!B64TMP!" echo IC0gRU5WPWxvY2FsCiAgICAgIC0gUkVESVNfVVJMPXJlZGlzOi8vcmVkaXM6NjM3OQogICAgICAt
  >> "!B64TMP!" echo IFJFRElTX1JBVEVfTElNSVRfVVJMPXJlZGlzOi8vcmVkaXM6NjM3OQogICAgICAtIFBMQVlXUklH
  >> "!B64TMP!" echo SFRfTUlDUk9TRVJWSUNFX1VSTD0ke1BMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTDotaHR0cDov
  >> "!B64TMP!" echo L3BsYXl3cmlnaHQtc2VydmljZTozMDAwL3NjcmFwZX0KICAgICAgLSBVU0VfREJfQVVUSEVOVElD
  >> "!B64TMP!" echo QVRJT049ZmFsc2UKICAgICAgLSBCVUxMX0FVVEhfS0VZPSR7QlVMTF9BVVRIX0tFWX0KICAgICAg
  >> "!B64TMP!" echo LSBMT0dHSU5HX0xFVkVMPSR7TE9HR0lOR19MRVZFTDotaW5mb30KICAgICAgLSBCTE9DS19NRURJ
  >> "!B64TMP!" echo QT1mYWxzZQogICAgICAjIEZpcmVjcmF3bCdzIFNTUkYgZ3VhcmQgcmVmdXNlcyBwcml2YXRlL3Jl
  >> "!B64TMP!" echo c2VydmVkIGFkZHJlc3NlcywgYnV0IHByb3h5IGFuZCBWUE4gdG9vbHMgKENsYXNoCiAgICAgICMg
  >> "!B64TMP!" echo ZmFrZS1JUCwgV0FSUCwgLi4uKSBoYW5kIHRob3NlIG91dCBmb3IgcHVibGljIHNpdGVzLCBzbyBl
  >> "!B64TMP!" echo dmVyeSBzY3JhcGUgd291bGQgZmFpbC4gVGhpcyBzdGFjawogICAgICAjIGlzIGxvY2FsaG9zdC1v
  >> "!B64TMP!" echo bmx5OiB0aGUgZ3VhcmQgaXMgb2ZmIGhlcmUgYW5kIGluIHBsYXl3cmlnaHQtc2VydmljZS4KICAg
  >> "!B64TMP!" echo ICAgLSBBTExPV19MT0NBTF9XRUJIT09LUz10cnVlCiAgICAgIC0gU0VBUlhOR19FTkRQT0lOVD1o
  >> "!B64TMP!" echo dHRwOi8vc2VhcnhuZzo4MDgwCiAgICAgIC0gUE9TVEdSRVNfSE9TVD1udXEtcG9zdGdyZXMKICAg
  >> "!B64TMP!" echo ICAgLSBQT1NUR1JFU19QT1JUPTU0MzIKICAgICAgLSBQT1NUR1JFU19EQj0ke1BPU1RHUkVTX0RC
  >> "!B64TMP!" echo Oi1maXJlY3Jhd2x9CiAgICAgIC0gUE9TVEdSRVNfVVNFUj0ke1BPU1RHUkVTX1VTRVI6LWZpcmVj
  >> "!B64TMP!" echo cmF3bH0KICAgICAgLSBQT1NUR1JFU19QQVNTV09SRD0ke1BPU1RHUkVTX1BBU1NXT1JEfQogICAg
  >> "!B64TMP!" echo ICAtIE5VUV9SQUJCSVRNUV9VUkw9YW1xcDovLyR7UkFCQklUTVFfVVNFUjotZmlyZWNyYXdsfTok
  >> "!B64TMP!" echo e1JBQkJJVE1RX1BBU1NXT1JEfUByYWJiaXRtcTo1NjcyCiAgICAgICMgLS0tLSBPcHRpb25hbCBB
  >> "!B64TMP!" echo SSBmZWF0dXJlcyAoc2V0IGluIC5lbnYgdG8gZW5hYmxlIC92MS9leHRyYWN0ICsgc3VtbWFyeSkg
  >> "!B64TMP!" echo LS0tLQogICAgICAtIE9QRU5BSV9BUElfS0VZPSR7T1BFTkFJX0FQSV9LRVk6LX0KICAgICAgLSBP
  >> "!B64TMP!" echo UEVOQUlfQkFTRV9VUkw9JHtPUEVOQUlfQkFTRV9VUkw6LX0KICAgICAgLSBPTExBTUFfQkFTRV9V
  >> "!B64TMP!" echo Ukw9JHtPTExBTUFfQkFTRV9VUkw6LX0KICAgICAgLSBNT0RFTF9OQU1FPSR7TU9ERUxfTkFNRTot
  >> "!B64TMP!" echo fQogICAgICAtIE1PREVMX0VNQkVERElOR19OQU1FPSR7TU9ERUxfRU1CRURESU5HX05BTUU6LX0K
  >> "!B64TMP!" echo ICAgIGNvbW1hbmQ6IFsibm9kZSIsICJkaXN0L3NyYy9oYXJuZXNzLmpzIiwgIi0tc3RhcnQtZG9j
  >> "!B64TMP!" echo a2VyIl0KICAgIHVsaW1pdHM6CiAgICAgIG5vZmlsZToKICAgICAgICBzb2Z0OiA2NTUzNQogICAg
  >> "!B64TMP!" echo ICAgIGhhcmQ6IDY1NTM1CiAgICBleHRyYV9ob3N0czoKICAgICAgLSAiaG9zdC5kb2NrZXIuaW50
  >> "!B64TMP!" echo ZXJuYWw6aG9zdC1nYXRld2F5IgogICAgbG9nZ2luZzoKICAgICAgZHJpdmVyOiAianNvbi1maWxl
  >> "!B64TMP!" echo IgogICAgICBvcHRpb25zOgogICAgICAgIG1heC1zaXplOiAiMTBtIgogICAgICAgIG1heC1maWxl
  >> "!B64TMP!" echo OiAiMyIKICAgICAgICBjb21wcmVzczogInRydWUiCiAgICAjIE5PVEU6IHBsYXl3cmlnaHQtc2Vy
  >> "!B64TMP!" echo dmljZSAvIGJyb3dzZXJsZXNzIC8gaW52aXNpYmxlLXBsYXl3cmlnaHQgYXJlIGRlbGliZXJhdGVs
  >> "!B64TMP!" echo eSBOT1QgbGlzdGVkIGhlcmUuCiAgICAjIFRoZXkgYXJlIHByb2ZpbGUtZ2F0ZWQgKG9ubHkgb25l
  >> "!B64TMP!" echo IG9mIHRoZW0gcnVucyksIGFuZCBwb2RtYW4tY29tcG9zZSBjcmFzaGVzCiAgICAjIHdpdGggIktl
  >> "!B64TMP!" echo eUVycm9yOiAnYnJvd3Nlcmxlc3MnIiB3aGVuIGEgc2VydmljZSBkZXBlbmRzIG9uIG9uZSB0aGF0
  >> "!B64TMP!" echo IGl0cwogICAgIyBwcm9maWxlIGRpc2FibGVkLiBEb2NrZXIgb25seSBldmVyIGhvbm91cmVkIHRo
  >> "!B64TMP!" echo YXQgZGVwZW5kZW5jeSBhcyBzdGFydAogICAgIyBPUkRFUiAoc2VydmljZV9zdGFydGVkICsgcmVx
  >> "!B64TMP!" echo dWlyZWQ6IGZhbHNlLCBuZXZlciByZWFkaW5lc3MpLCBhbmQgRmlyZWNyYXdsCiAgICAjIHJlYWNo
  >> "!B64TMP!" echo ZXMgdGhlIGJyb3dzZXIgc2VydmljZSBwZXIgc2NyYXBlIHJlcXVlc3QsIG5vdCBhdCBzdGFydC11
  >> "!B64TMP!" echo cCwgc28KICAgICMgbm90aGluZyBpcyBsb3N0LiBLZWVwIHByb2ZpbGUtZ2F0ZWQgc2VydmljZXMg
  >> "!B64TMP!" echo b3V0IG9mIGV2ZXJ5IGRlcGVuZHNfb24uCiAgICBkZXBlbmRzX29uOgogICAgICByZWRpczoKICAg
  >> "!B64TMP!" echo ICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAogICAgICBzZWFyeG5nOgogICAgICAgIGNv
  >> "!B64TMP!" echo bmRpdGlvbjogc2VydmljZV9zdGFydGVkCiAgICAgIG51cS1wb3N0Z3JlczoKICAgICAgICBjb25k
  >> "!B64TMP!" echo aXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICByYWJiaXRtcToKICAgICAgICBjb25kaXRpb246
  >> "!B64TMP!" echo IHNlcnZpY2VfaGVhbHRoeQogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtz
  >> "!B64TMP!" echo OgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgUGxh
  >> "!B64TMP!" echo eXdyaWdodCBoZWFkbGVzcyBicm93c2VyIHNlcnZpY2Ug4oCUIGRvZXMgdGhlIGFjdHVhbCBKUy1y
  >> "!B64TMP!" echo ZW5kZXJlZAogICMgZmV0Y2hpbmcuIE9ubHkgc3RhcnRzIHdoZW4gQ09NUE9TRV9QUk9GSUxFUz1w
  >> "!B64TMP!" echo bGF5d3JpZ2h0ICh0aGUgaW5zdGFsbGVyJ3MKICAjIGRlZmF1bHQgYW5zd2VyIHRvICJCcm93c2Vy
  >> "!B64TMP!" echo IHJlbmRlcmluZyBlbmdpbmUiKS4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgcGxheXdyaWdodC1z
  >> "!B64TMP!" echo ZXJ2aWNlOgogICAgaW1hZ2U6IGdoY3IuaW8vZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZTps
  >> "!B64TMP!" echo YXRlc3QKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtcGxheXdyaWdodAogICAgcHJv
  >> "!B64TMP!" echo ZmlsZXM6IFsicGxheXdyaWdodCJdCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBQT1JUPTMwMDAK
  >> "!B64TMP!" echo ICAgICAgLSBCTE9DS19NRURJQT1mYWxzZQogICAgICAtIEFMTE9XX0xPQ0FMX1dFQkhPT0tTPXRy
  >> "!B64TMP!" echo dWUKICAgICAgLSBNQVhfQ09OQ1VSUkVOVF9QQUdFUz0xMAogICAgcmVzdGFydDogdW5sZXNzLXN0
  >> "!B64TMP!" echo b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLQogICMgQnJvd3Nlcmxlc3MgKGNvbW11bml0eSBlZGl0aW9uKSDigJQgc3RlYWx0
  >> "!B64TMP!" echo aCBoZWFkbGVzcyBDaHJvbWl1bSB0aGF0IGRvZXMgdGhlCiAgIyBhY3R1YWwgSlMtcmVuZGVyZWQg
  >> "!B64TMP!" echo ZmV0Y2hpbmcgZm9yIEZpcmVjcmF3bC4gREVGQVVMVF9TVEVBTFRIPXRydWUgYXBwbGllcwogICMg
  >> "!B64TMP!" echo dGhlIGJ1aWx0LWluIHN0ZWFsdGggcGF0Y2hlcyAobWFza3MgYXV0b21hdGlvbiBmaW5nZXJwcmlu
  >> "!B64TMP!" echo dHMgc3VjaCBhcwogICMgbmF2aWdhdG9yLndlYmRyaXZlcikgdG8gZXZlcnkgcmVxdWVzdCB3aXRo
  >> "!B64TMP!" echo b3V0IG5lZWRpbmcgYSA/c3RlYWx0aCBxdWVyeQogICMgcGFyYW0sIHdoaWNoIGhlbHBzIHBhZ2Vz
  >> "!B64TMP!" echo IGZyb250ZWQgYnkgQ2xvdWRmbGFyZSBhbmQgc2ltaWxhciBib3QgY2hlY2tzLgogICMgT25seSBz
  >> "!B64TMP!" echo dGFydHMgd2hlbiBDT01QT1NFX1BST0ZJTEVTPWJyb3dzZXJsZXNzICh0aGUgaW5zdGFsbGVyJ3Mg
  >> "!B64TMP!" echo IlVzZQogICMgQnJvd3Nlcmxlc3MgaW5zdGVhZD8iIGFuc3dlcikuCiAgIyAtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLQogIGJyb3dzZXJsZXNzOgogICAgaW1hZ2U6IGdoY3IuaW8vYnJvd3Nlcmxlc3MvY2hyb21p
  >> "!B64TMP!" echo dW06bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLWJyb3dzZXJsZXNzCiAg
  >> "!B64TMP!" echo ICBwcm9maWxlczogWyJicm93c2VybGVzcyJdCiAgICBlbnZpcm9ubWVudDoKICAgICAgLSBQT1JU
  >> "!B64TMP!" echo PTMwMDAKICAgICAgLSBUT0tFTj0ke0JST1dTRVJMRVNTX1RPS0VOOi19CiAgICAgIC0gREVGQVVM
  >> "!B64TMP!" echo VF9TVEVBTFRIPXRydWUKICAgICAgLSBDT05DVVJSRU5UPTEwCiAgICAgIC0gTUFYX0NPTkNVUlJF
  >> "!B64TMP!" echo TlRfU0VTU0lPTlM9MTAKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoK
  >> "!B64TMP!" echo ICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEludmlz
  >> "!B64TMP!" echo aWJsZSBQbGF5d3JpZ2h0IChodHRwczovL2dpdGh1Yi5jb20vb3NzLWludmlzaWJsZS9wbGF5d3Jp
  >> "!B64TMP!" echo Z2h0KSAtIGEKICAjIHBhdGNoZWQgRmlyZWZveCB3aG9zZSBmaW5nZXJwcmludCAobmF2aWdhdG9y
  >> "!B64TMP!" echo LCBzY3JlZW4sIFdlYkdMLCBmb250cywgdGltZXpvbmUsCiAgIyAuLi4pIGlzIGdlbmVyYXRlZCBp
  >> "!B64TMP!" echo bnNpZGUgdGhlIGVuZ2luZSwgbm90IGluamVjdGVkIHRocm91Z2ggSmF2YVNjcmlwdCwgYmVoaW5k
  >> "!B64TMP!" echo CiAgIyB0aGUgc2FtZSB0d28gSFRUUCByb3V0ZXMgYXMgRmlyZWNyYXdsJ3MgcGxheXdyaWdodC1z
  >> "!B64TMP!" echo ZXJ2aWNlLiBUaGVyZSBpcyBubwogICMgcHVibGlzaGVkIGltYWdlOiBpdCBpcyBCVUlMVCBsb2Nh
  >> "!B64TMP!" echo bGx5IGZyb20gLi9pbnZpc2libGUtcGxheXdyaWdodCBvbiB0aGUgZmlyc3QKICAjIHN0YXJ0IChh
  >> "!B64TMP!" echo Ym91dCAxMCBtaW51dGVzIGFuZCB+MiBHQjogYmFzZSBpbWFnZSArIFB5dGhvbiArIHRoZSB+MjYw
  >> "!B64TMP!" echo IE1CIGVuZ2luZSkuCiAgIyBPbmx5IHN0YXJ0cyB3aGVuIENPTVBPU0VfUFJPRklMRVM9aW52aXNp
  >> "!B64TMP!" echo YmxlICh0aGUgaW5zdGFsbGVyJ3MgIkludmlzaWJsZQogICMgUGxheXdyaWdodCIgYW5zd2VyKS4g
  >> "!B64TMP!" echo T3B0aW9uYWwgdHVuaW5nIChhbGwgaW4gLmVudik6IElOVklTSUJMRV9HSVRIVUJfVE9LRU4KICAj
  >> "!B64TMP!" echo IChidWlsZCksIElOVklTSUJMRV9QUk9YWV8qLCBJTlZJU0lCTEVfQkxPQ0tfQURTLgogICMgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0KICBpbnZpc2libGUtcGxheXdyaWdodDoKICAgIGJ1aWxkOgogICAgICBj
  >> "!B64TMP!" echo b250ZXh0OiAuL2ludmlzaWJsZS1wbGF5d3JpZ2h0CiAgICAgIGFyZ3M6CiAgICAgICAgLSBTVEVB
  >> "!B64TMP!" echo TFRIRk9YX0dJVEhVQl9UT0tFTj0ke0lOVklTSUJMRV9HSVRIVUJfVE9LRU46LX0KICAgIGNvbnRh
  >> "!B64TMP!" echo aW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtaW52aXNpYmxlCiAgICBwcm9maWxlczogWyJpbnZpc2li
  >> "!B64TMP!" echo bGUiXQogICAgZW52aXJvbm1lbnQ6CiAgICAgIC0gUE9SVD0zMDAwCiAgICAgIC0gQkxPQ0tfTUVE
  >> "!B64TMP!" echo SUE9ZmFsc2UKICAgICAgLSBCTE9DS19BRFM9JHtJTlZJU0lCTEVfQkxPQ0tfQURTOi1mYWxzZX0K
  >> "!B64TMP!" echo ICAgICAgLSBBTExPV19MT0NBTF9XRUJIT09LUz10cnVlCiAgICAgIC0gTUFYX0NPTkNVUlJFTlRf
  >> "!B64TMP!" echo UEFHRVM9JHtJTlZJU0lCTEVfTUFYX1BBR0VTOi00fQogICAgICAtIFBST1hZX1NFUlZFUj0ke0lO
  >> "!B64TMP!" echo VklTSUJMRV9QUk9YWV9TRVJWRVI6LX0KICAgICAgLSBQUk9YWV9VU0VSTkFNRT0ke0lOVklTSUJM
  >> "!B64TMP!" echo RV9QUk9YWV9VU0VSTkFNRTotfQogICAgICAtIFBST1hZX1BBU1NXT1JEPSR7SU5WSVNJQkxFX1BS
  >> "!B64TMP!" echo T1hZX1BBU1NXT1JEOi19CiAgICAjIEZpcmVmb3gga2VlcHMgc2hhcmVkIG1lbW9yeSBmb3IgZXZl
  >> "!B64TMP!" echo cnkgb3BlbiBwYWdlOyBEb2NrZXIncyA2NCBNQiBkZWZhdWx0CiAgICAjIGNyYXNoZXMgdGFicyBv
  >> "!B64TMP!" echo biBoZWF2eSBwYWdlcy4KICAgIHNobV9zaXplOiAiMmdiIgogICAgaW5pdDogdHJ1ZQogICAgcmVz
  >> "!B64TMP!" echo dGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1u
  >> "!B64TMP!" echo ZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgUmVkaXMg4oCUIEZpcmVjcmF3bCBxdWV1ZSAv
  >> "!B64TMP!" echo IHJhdGUtbGltaXRpbmcgc3RvcmUuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHJlZGlzOgogICAg
  >> "!B64TMP!" echo aW1hZ2U6IGRvY2tlci5pby9saWJyYXJ5L3JlZGlzOmFscGluZQogICAgY29udGFpbmVyX25hbWU6
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC1yZWRpcwogICAgdm9sdW1lczoKICAgICAgLSByZWRpcy1kYXRhOi9kYXRh
  >> "!B64TMP!" echo CiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgbmV0d29ya3M6CiAgICAgIC0gbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLW5ldAoKICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgIyBSYWJiaXRNUSDigJQgbWVzc2Fn
  >> "!B64TMP!" echo ZSBicm9rZXIgdXNlZCBieSBGaXJlY3Jhd2wncyBqb2Igd29ya2Vycy4KICAjIC0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tCiAgcmFiYml0bXE6CiAgICBpbWFnZTogZG9ja2VyLmlvL2xpYnJhcnkvcmFiYml0bXE6
  >> "!B64TMP!" echo My1tYW5hZ2VtZW50CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLXJhYmJpdG1xCiAg
  >> "!B64TMP!" echo ICBlbnZpcm9ubWVudDoKICAgICAgLSBSQUJCSVRNUV9ERUZBVUxUX1VTRVI9JHtSQUJCSVRNUV9V
  >> "!B64TMP!" echo U0VSOi1maXJlY3Jhd2x9CiAgICAgIC0gUkFCQklUTVFfREVGQVVMVF9QQVNTPSR7UkFCQklUTVFf
  >> "!B64TMP!" echo UEFTU1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHJhYmJpdG1xLWRhdGE6L3Zhci9saWIvcmFi
  >> "!B64TMP!" echo Yml0bXEKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNNRCIsICJyYWJiaXRtcS1kaWFn
  >> "!B64TMP!" echo bm9zdGljcyIsICJwaW5nIl0KICAgICAgaW50ZXJ2YWw6IDVzCiAgICAgIHRpbWVvdXQ6IDEwcwog
  >> "!B64TMP!" echo ICAgICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5s
  >> "!B64TMP!" echo ZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAt
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLQogICMgbnVxLXBvc3RncmVzIOKAlCBGaXJlY3Jhd2wgam9iLXN0YXRl
  >> "!B64TMP!" echo IGRhdGFiYXNlIChwZ19jcm9uIGVuYWJsZWQgaW1hZ2UpLgogICMgLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0K
  >> "!B64TMP!" echo ICBudXEtcG9zdGdyZXM6CiAgICBpbWFnZTogZ2hjci5pby9maXJlY3Jhd2wvbnVxLXBvc3RncmVz
  >> "!B64TMP!" echo OmxhdGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1wb3N0Z3JlcwogICAgY29t
  >> "!B64TMP!" echo bWFuZDogcG9zdGdyZXMgLWMgY3Jvbi5kYXRhYmFzZV9uYW1lPSR7UE9TVEdSRVNfREI6LWZpcmVj
  >> "!B64TMP!" echo cmF3bH0KICAgIGVudmlyb25tZW50OgogICAgICAtIFBPU1RHUkVTX0RCPSR7UE9TVEdSRVNfREI6
  >> "!B64TMP!" echo LWZpcmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9TVEdSRVNfVVNFUjotZmlyZWNy
  >> "!B64TMP!" echo YXdsfQogICAgICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdSRVNfUEFTU1dPUkR9CiAgICB2
  >> "!B64TMP!" echo b2x1bWVzOgogICAgICAtIHBvc3RncmVzLWRhdGE6L3Zhci9saWIvcG9zdGdyZXNxbC9kYXRhCiAg
  >> "!B64TMP!" echo ICBoZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQtU0hFTEwiLCAicGdfaXNyZWFkeSAtVSAk
  >> "!B64TMP!" echo e1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0gLWQgJHtQT1NUR1JFU19EQjotZmlyZWNyYXdsfSJd
  >> "!B64TMP!" echo CiAgICAgIGludGVydmFsOiA1cwogICAgICB0aW1lb3V0OiA1cwogICAgICByZXRyaWVzOiAxMAog
  >> "!B64TMP!" echo ICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5l
  >> "!B64TMP!" echo dHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCm5ldHdvcmtzOgogIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC1uZXQ6CiAgICBkcml2ZXI6IGJyaWRnZQoKdm9sdW1lczoKICByZWRpcy1kYXRhOgogIHBvc3Rn
  >> "!B64TMP!" echo cmVzLWRhdGE6CiAgcmFiYml0bXEtZGF0YToK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\docker-compose.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- invisible-playwright/Dockerfile ---
set "NEED_B64=1"
if exist "!SRC!\invisible-playwright\Dockerfile" (
  copy /Y "!SRC!\invisible-playwright\Dockerfile" "!TARGET!\invisible-playwright\Dockerfile" >nul 2>&1
  if exist "!TARGET!\invisible-playwright\Dockerfile" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] invisible-playwright/Dockerfile  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4024055255.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBJbnZpc2libGUgUGxheXdyaWdodCBlbmdpbmUgZm9y
  >> "!B64TMP!" echo IExvY2FsIFNlYXJjaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIEJ1aWx0IGxvY2FsbHkgYnkg
  >> "!B64TMP!" echo YGRvY2tlciBjb21wb3NlIHVwYCAodGhlcmUgaXMgbm8gcHVibGlzaGVkIGltYWdlKSB3aGVuIHRo
  >> "!B64TMP!" echo ZQojICBpbnN0YWxsZXIncyBTdGVwIDQgYW5zd2VyIGlzICJJbnZpc2libGUgUGxheXdyaWdodCIg
  >> "!B64TMP!" echo KENPTVBPU0VfUFJPRklMRVM9aW52aXNpYmxlKS4KIwojICBXaGF0IGl0IHJ1bnM6IHNlcnZlci5w
  >> "!B64TMP!" echo eSwgYSBzbWFsbCBIVFRQIHNlcnZpY2Ugd2l0aCB0aGUgc2FtZSB0d28gcm91dGVzIGFzCiMgIEZp
  >> "!B64TMP!" echo cmVjcmF3bCdzIHBsYXl3cmlnaHQtc2VydmljZSAoUE9TVCAvc2NyYXBlLCBHRVQgL2hlYWx0aCks
  >> "!B64TMP!" echo IGRyaXZpbmcKIyAgaW52aXNpYmxlLXBsYXl3cmlnaHQgLSBhIHBhdGNoZWQgRmlyZWZveCAtIGh0
  >> "!B64TMP!" echo dHBzOi8vZ2l0aHViLmNvbS9vc3MtaW52aXNpYmxlL3BsYXl3cmlnaHQKIwojICBUaGUgYmFzZSBp
  >> "!B64TMP!" echo bWFnZSBhbmQgdGhlIHV2L3ZlbnYgcmVjaXBlIGFyZSB0aGUgb25lcyBmcm9tIHRoYXQgcHJvamVj
  >> "!B64TMP!" echo dCdzIG93bgojICAidXNlIGluIERvY2tlciIgZ3VpZGU6IHRoZSBiYXNlIHN1cHBsaWVzIEZpcmVm
  >> "!B64TMP!" echo b3gncyBzeXN0ZW0gbGlicmFyaWVzIChhbmQKIyAgWHZmYiwgd2hpY2ggdGhlIHBhY2thZ2UgdXNl
  >> "!B64TMP!" echo cyB0byBydW4gRmlyZWZveCBoZWFkZWQgb24gYSBoaWRkZW4gc2NyZWVuKTsgdXYKIyAgc3VwcGxp
  >> "!B64TMP!" echo ZXMgdGhlIFB5dGhvbiA+PSAzLjExIHRoZSBwYWNrYWdlIG5lZWRzLgojCiMgIEJ1aWxkIHRpbWUg
  >> "!B64TMP!" echo bmVlZHM6IG1jci5taWNyb3NvZnQuY29tLCBnaGNyLmlvLCBQeVBJLCBhbmQgR2l0SHViICh1didz
  >> "!B64TMP!" echo IFB5dGhvbgojICBkb3dubG9hZCBhbmQgdGhlIH4yNjAgTUIgZW5naW5lKS4gSWYgR2l0SHViIHJh
  >> "!B64TMP!" echo dGUtbGltaXRzIHRoZSBlbmdpbmUgZG93bmxvYWQsCiMgIHB1dCBhIHRva2VuIGluIC5lbnYgYXMg
  >> "!B64TMP!" echo SU5WSVNJQkxFX0dJVEhVQl9UT0tFTiAoc2VlIC5lbnYuZXhhbXBsZSk7IGNvbXBvc2UKIyAgcGFz
  >> "!B64TMP!" echo c2VzIGl0IGFzIHRoZSBTVEVBTFRIRk9YX0dJVEhVQl9UT0tFTiBidWlsZCBhcmd1bWVudCBiZWxv
  >> "!B64TMP!" echo dy4gKEJ1aWxkCiMgIGFyZ3VtZW50cyBhcmUgdmlzaWJsZSBpbiBgZG9ja2VyIGhpc3RvcnlgIG9m
  >> "!B64TMP!" echo IHRoaXMgbG9jYWwgaW1hZ2UgLSB1c2UgYSB0b2tlbgojICB3aXRoIG5vIHNjb3Blcy4pCiMgPT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0KRlJPTSBtY3IubWljcm9zb2Z0LmNvbS9wbGF5d3JpZ2h0L3B5dGhv
  >> "!B64TMP!" echo bjp2MS40Ny4wLWphbW15CgpDT1BZIC0tZnJvbT1naGNyLmlvL2FzdHJhbC1zaC91djowLjEyLjEw
  >> "!B64TMP!" echo IC91diAvdXZ4IC9iaW4vCgpBUkcgU1RFQUxUSEZPWF9HSVRIVUJfVE9LRU49IiIKCkVOViBJTlZJ
  >> "!B64TMP!" echo U0lCTEVfUExBWVdSSUdIVF9DQUNIRV9ESVI9L29wdC9pbnZpc2libGUtcGxheXdyaWdodC1jYWNo
  >> "!B64TMP!" echo ZSBcCiAgICBWSVJUVUFMX0VOVj0vb3B0L3ZlbnYgXAogICAgUEFUSD0iL29wdC92ZW52L2Jpbjok
  >> "!B64TMP!" echo UEFUSCIgXAogICAgTUFMTE9DX0FSRU5BX01BWD0yIFwKICAgIFBZVEhPTlVOQlVGRkVSRUQ9MQoK
  >> "!B64TMP!" echo IyBYdmZiIGlzIGFscmVhZHkgcGFydCBvZiB0aGUgYmFzZSBpbWFnZTsgdGhpcyBtYWtlcyBzdXJl
  >> "!B64TMP!" echo IG9mIGl0IChuby1vcCBpZiBzbykuClJVTiBhcHQtZ2V0IHVwZGF0ZSBcCiAmJiBhcHQtZ2V0IGlu
  >> "!B64TMP!" echo c3RhbGwgLXkgLS1uby1pbnN0YWxsLXJlY29tbWVuZHMgeHZmYiBjYS1jZXJ0aWZpY2F0ZXMgXAog
  >> "!B64TMP!" echo JiYgcm0gLXJmIC92YXIvbGliL2FwdC9saXN0cy8qCgpSVU4gdXYgdmVudiAtLXB5dGhvbiAiPj0z
  >> "!B64TMP!" echo LjExIiAvb3B0L3ZlbnYgXAogJiYgdXYgcGlwIGluc3RhbGwgLS1uby1jYWNoZSBpbnZpc2libGUt
  >> "!B64TMP!" echo cGxheXdyaWdodCBhaW9odHRwCgojIERvd25sb2FkICsgdmVyaWZ5IHRoZSBwYXRjaGVkIEZpcmVm
  >> "!B64TMP!" echo b3ggZW5naW5lIG9uY2UsIGF0IGJ1aWxkIHRpbWUuIFRoZSBBUkcgaXMKIyBub3QgdHVybmVkIGlu
  >> "!B64TMP!" echo dG8gYW4gRU5WLCBzbyB0aGUgdG9rZW4gaXMgbm90IHBhcnQgb2YgdGhlIHJ1bm5pbmcgY29udGFp
  >> "!B64TMP!" echo bmVyLgpSVU4gcHl0aG9uIC1tIGludmlzaWJsZV9wbGF5d3JpZ2h0IGZldGNoCgojIFByZS1sb2Fk
  >> "!B64TMP!" echo IHRoZSBHZW9JUCBkYXRhYmFzZSB0aGUgYXV0b21hdGljIHRpbWV6b25lIHVzZXMsIHNvIHRoZSBm
  >> "!B64TMP!" echo aXJzdCBzdGFydAojIGRvZXMgbm90IGRlcGVuZCBvbiByZWFjaGluZyBHaXRIdWIuIEJlc3QgZWZm
  >> "!B64TMP!" echo b3J0OiB0aGUgc2VydmljZSBmYWxscyBiYWNrIHRvIGEKIyBmaXhlZCB0aW1lem9uZSBpZiBpdCBp
  >> "!B64TMP!" echo cyBtaXNzaW5nLgpSVU4gcHl0aG9uIC1jICJmcm9tIGludmlzaWJsZV9jb3JlLmRvd25sb2FkIGlt
  >> "!B64TMP!" echo cG9ydCBlbnN1cmVfZ2VvaXBfbW1kYjsgZW5zdXJlX2dlb2lwX21tZGIoKSIgXAogfHwgZWNobyAi
  >> "!B64TMP!" echo R2VvSVAgcHJlLWxvYWQgc2tpcHBlZCAodGhlIHNlcnZpY2Ugd2lsbCBmZXRjaCBpdCBvbiBmaXJz
  >> "!B64TMP!" echo dCBzdGFydCkiCgpXT1JLRElSIC9hcHAKQ09QWSBzZXJ2ZXIucHkgL2FwcC9zZXJ2ZXIucHkKCkVO
  >> "!B64TMP!" echo ViBQT1JUPTMwMDAKRVhQT1NFIDMwMDAKCkNNRCBbInB5dGhvbiIsICIvYXBwL3NlcnZlci5weSJd
  >> "!B64TMP!" echo Cg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\invisible-playwright\Dockerfile"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- invisible-playwright/server.py ---
set "NEED_B64=1"
if exist "!SRC!\invisible-playwright\server.py" (
  copy /Y "!SRC!\invisible-playwright\server.py" "!TARGET!\invisible-playwright\server.py" >nul 2>&1
  if exist "!TARGET!\invisible-playwright\server.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] invisible-playwright/server.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS761932647.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKSW52aXNpYmxlIFBsYXl3cmlnaHQgc2VydmljZSBm
  >> "!B64TMP!" echo b3IgTG9jYWwgU2VhcmNoLgoKQSBkcm9wLWluIHJlcGxhY2VtZW50IGZvciBGaXJlY3Jhd2wncyBw
  >> "!B64TMP!" echo bGF5d3JpZ2h0LXNlcnZpY2U6IGl0IHNwZWFrcyB0aGUgc2FtZQp0d28gSFRUUCByb3V0ZXMsIHNv
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBvbmx5IG5lZWRzIFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTCBwb2ludGVk
  >> "!B64TMP!" echo IGF0Cml0LCBidXQgdGhlIHBhZ2VzIGFyZSByZW5kZXJlZCBieSBpbnZpc2libGUtcGxheXdyaWdo
  >> "!B64TMP!" echo dAooaHR0cHM6Ly9naXRodWIuY29tL29zcy1pbnZpc2libGUvcGxheXdyaWdodCksIGEgcGF0Y2hl
  >> "!B64TMP!" echo ZCBGaXJlZm94IHdob3NlCmZpbmdlcnByaW50IGlzIGdlbmVyYXRlZCBpbnNpZGUgdGhlIGVuZ2lu
  >> "!B64TMP!" echo ZSBpbnN0ZWFkIG9mIGJlaW5nIGluamVjdGVkIHRocm91Z2gKSmF2YVNjcmlwdC4KClJvdXRlcwog
  >> "!B64TMP!" echo IEdFVCAgL2hlYWx0aCAgIDIwMCB7InN0YXR1cyI6ICJoZWFsdGh5IiwgLi4ufSAgfCAgNTAzIHsi
  >> "!B64TMP!" echo c3RhdHVzIjogInVuaGVhbHRoeSIsIC4uLn0KICBQT1NUIC9zY3JhcGUgICBib2R5OiB7dXJsLCB3
  >> "!B64TMP!" echo YWl0X2FmdGVyX2xvYWQsIHRpbWVvdXQsIGhlYWRlcnMsIGNoZWNrX3NlbGVjdG9yLAogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICBza2lwX3Rsc192ZXJpZmljYXRpb259CiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo MjAwIHtjb250ZW50LCBwYWdlU3RhdHVzQ29kZSwgY29udGVudFR5cGUsIHBhZ2VFcnJvcj99CiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgNDAwIHsiZXJyb3IiOiAiVVJMIGlzIHJlcXVpcmVkIiB8ICJJbnZhbGlk
  >> "!B64TMP!" echo IFVSTCJ9CiAgICAgICAgICAgICAgICAgNTAwIHsiZXJyb3IiOiAiQW4gZXJyb3Igb2NjdXJyZWQg
  >> "!B64TMP!" echo d2hpbGUgZmV0Y2hpbmcgdGhlIHBhZ2UuIiwgImRldGFpbCI6IC4uLn0KICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBBIHRhcmdldCB0aGUgU1NSRiBndWFyZCByZWZ1c2VzIGFuc3dlcnMgMjAwIHdpdGgKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICB7Y29udGVudDogIiIsIHBhZ2VTdGF0dXNDb2RlOiA0MDMsIHBhZ2VFcnJvcjog
  >> "!B64TMP!" echo Li4ufSwgZXhhY3RseSBsaWtlCiAgICAgICAgICAgICAgICAgRmlyZWNyYXdsJ3Mgb3duIHNlcnZp
  >> "!B64TMP!" echo Y2UuCgpFbnZpcm9ubWVudCAoYWxsIG9wdGlvbmFsKQogIFBPUlQgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IGxpc3RlbiBwb3J0IChkZWZhdWx0IDMwMDApCiAgTUFYX0NPTkNVUlJFTlRfUEFHRVMgICAgc2Ny
  >> "!B64TMP!" echo YXBlcyBydW5uaW5nIGF0IG9uY2UgKGRlZmF1bHQgNDsgRmlyZWZveCBpcyBoZWF2eSkKICBCTE9D
  >> "!B64TMP!" echo S19NRURJQSAgICAgICAgICAgICAidHJ1ZSIgYWJvcnRzIGltYWdlL21lZGlhIHJlcXVlc3RzIChk
  >> "!B64TMP!" echo ZWZhdWx0IGZhbHNlKQogIEJMT0NLX0FEUyAgICAgICAgICAgICAgICJ0cnVlIiBhYm9ydHMgYSBz
  >> "!B64TMP!" echo aG9ydCBsaXN0IG9mIGFkL3RyYWNrZXIgaG9zdHMgKGRlZmF1bHQgZmFsc2UpCiAgQUxMT1dfTE9D
  >> "!B64TMP!" echo QUxfV0VCSE9PS1MgICAgInRydWUiIHR1cm5zIHRoZSBwcml2YXRlLWFkZHJlc3MgKFNTUkYpIGd1
  >> "!B64TMP!" echo YXJkIG9mZgogIFBST1hZX1NFUlZFUiAvIFBST1hZX1VTRVJOQU1FIC8gUFJPWFlfUEFTU1dPUkQg
  >> "!B64TMP!" echo ICB1cHN0cmVhbSBwcm94eSAoaHR0cC9odHRwcy9zb2NrcykKICBJTlZQV19TRUVEICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBmaXhlZCBmaW5nZXJwcmludCBzZWVkIChkZWZhdWx0OiByYW5kb20gcGVyIHN0YXJ0KQog
  >> "!B64TMP!" echo IElOVlBXX1RJTUVaT05FICAgICAgICAgIGZpeGVkIElBTkEgdGltZXpvbmUgKGRlZmF1bHQ6IGRl
  >> "!B64TMP!" echo cml2ZWQgZnJvbSB0aGUgZXhpdCBJUDsgaWYgdGhhdAogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IGxvb2t1cCBmYWlscyBhbmQgTk8gcHJveHkgaXMgc2V0IHRoZSBzZXJ2aWNlIHN0YXJ0cyB3aXRo
  >> "!B64TMP!" echo IFVUQywKICAgICAgICAgICAgICAgICAgICAgICAgICB3aXRoIGEgcHJveHkgaXQgcmVmdXNlcyB0
  >> "!B64TMP!" echo byBzdGFydCByYXRoZXIgdGhhbiBtaXNtYXRjaCB0aGUgSVApCiAgSU5WUFdfTE9DQUxFICAgICAg
  >> "!B64TMP!" echo ICAgICAgZml4ZWQgbG9jYWxlIHRhZyAoZGVmYXVsdCAiYXV0byIpCiAgSU5WUFdfSE9OT1JfVVNF
  >> "!B64TMP!" echo Ul9BR0VOVCAgInRydWUiIGFwcGxpZXMgYSBVc2VyLUFnZW50IGhlYWRlciBzZW50IGJ5IHRoZSBj
  >> "!B64TMP!" echo YWxsZXIuCiAgICAgICAgICAgICAgICAgICAgICAgICAgT2ZmIGJ5IGRlZmF1bHQ6IHRoZSBlbmdp
  >> "!B64TMP!" echo bmUgYWxyZWFkeSBwcmVzZW50cyBhIGNvaGVyZW50CiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo dXNlciBhZ2VudCwgYW5kIG92ZXJyaWRpbmcgaXQgYnJlYWtzIHRoYXQgY29oZXJlbmNlLgoKUmVx
  >> "!B64TMP!" echo dWVzdHMgYXJlIG9ubHkgaW50ZXJjZXB0ZWQgKHBhZ2Uucm91dGUpIHdoZW4gQkxPQ0tfTUVESUEs
  >> "!B64TMP!" echo IEJMT0NLX0FEUyBvciB0aGUKU1NSRiBndWFyZCBuZWVkcyBpdCwgc28gdGhlIGRlZmF1bHQgY29u
  >> "!B64TMP!" echo ZmlndXJhdGlvbiB0b3VjaGVzIG5vdGhpbmcgYmV0d2VlbiB0aGUKcGFnZSBhbmQgdGhlIG5ldHdv
  >> "!B64TMP!" echo cmsuCgpDb21wYXRpYmxlIHdpdGggUHl0aG9uIDMuOCsgKHRoZSBjb250YWluZXIgdXNlcyAzLjEx
  >> "!B64TMP!" echo KykuCiIiIgpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXN5bmNp
  >> "!B64TMP!" echo bwppbXBvcnQgaHR0cAppbXBvcnQgaXBhZGRyZXNzCmltcG9ydCBsb2dnaW5nCmltcG9ydCBvcwpp
  >> "!B64TMP!" echo bXBvcnQgc3lzCmltcG9ydCB0aW1lCmZyb20gY29udGV4dGxpYiBpbXBvcnQgQXN5bmNFeGl0U3Rh
  >> "!B64TMP!" echo Y2sKZnJvbSB0eXBpbmcgaW1wb3J0IEFueSwgQXdhaXRhYmxlLCBDYWxsYWJsZSwgRGljdCwgTGlz
  >> "!B64TMP!" echo dCwgT3B0aW9uYWwsIFR1cGxlCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCB1cmxwYXJzZQoKZnJv
  >> "!B64TMP!" echo bSBhaW9odHRwIGltcG9ydCB3ZWIKCmxvZyA9IGxvZ2dpbmcuZ2V0TG9nZ2VyKCJpbnZpc2libGUt
  >> "!B64TMP!" echo cGxheXdyaWdodC1zZXJ2aWNlIikKCkdFTkVSSUNfRVJST1IgPSAiQW4gZXJyb3Igb2NjdXJyZWQg
  >> "!B64TMP!" echo d2hpbGUgZmV0Y2hpbmcgdGhlIHBhZ2UuIgoKIyBBIHNob3J0LCBjb25zZXJ2YXRpdmUgbGlzdC4g
  >> "!B64TMP!" echo T25seSB1c2VkIHdoZW4gQkxPQ0tfQURTPXRydWUuCkFEX0hPU1RTID0gKAogICAgImRvdWJsZWNs
  >> "!B64TMP!" echo aWNrLm5ldCIsICJnb29nbGVzeW5kaWNhdGlvbi5jb20iLCAiZ29vZ2xlYWRzZXJ2aWNlcy5jb20i
  >> "!B64TMP!" echo LAogICAgImFkc2VydmljZS5nb29nbGUuY29tIiwgImdvb2dsZS1hbmFseXRpY3MuY29tIiwgImFk
  >> "!B64TMP!" echo c3J2ci5vcmciLCAiYWRueHMuY29tIiwKICAgICJ0YWJvb2xhLmNvbSIsICJvdXRicmFpbi5jb20i
  >> "!B64TMP!" echo LCAiY3JpdGVvLmNvbSIsICJzY29yZWNhcmRyZXNlYXJjaC5jb20iLAogICAgImhvdGphci5jb20i
  >> "!B64TMP!" echo LCAiYW1hem9uLWFkc3lzdGVtLmNvbSIsICJtb2F0YWRzLmNvbSIsICJxdWFudHNlcnZlLmNvbSIs
  >> "!B64TMP!" echo CikKCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBjb25maWd1cmF0aW9uCiMgLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQpkZWYgX2Vudl9ib29sKG5hbWU6IHN0ciwgZGVmYXVsdDogYm9vbCA9IEZhbHNlKSAt
  >> "!B64TMP!" echo PiBib29sOgogICAgcmF3ID0gb3MuZW52aXJvbi5nZXQobmFtZSkKICAgIGlmIHJhdyBpcyBOb25l
  >> "!B64TMP!" echo IG9yIHJhdy5zdHJpcCgpID09ICIiOgogICAgICAgIHJldHVybiBkZWZhdWx0CiAgICByZXR1cm4g
  >> "!B64TMP!" echo cmF3LnN0cmlwKCkubG93ZXIoKSBpbiAoIjEiLCAidHJ1ZSIsICJ5ZXMiLCAib24iKQoKCmRlZiBf
  >> "!B64TMP!" echo ZW52X2ludChuYW1lOiBzdHIsIGRlZmF1bHQ6IGludCwgbWluaW11bTogaW50ID0gMSkgLT4gaW50
  >> "!B64TMP!" echo OgogICAgcmF3ID0gb3MuZW52aXJvbi5nZXQobmFtZSkKICAgIHRyeToKICAgICAgICB2YWx1ZSA9
  >> "!B64TMP!" echo IGludChyYXcpIGlmIHJhdyBub3QgaW4gKE5vbmUsICIiKSBlbHNlIGRlZmF1bHQKICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBWYWx1ZUVycm9yOgogICAgICAgIHZhbHVlID0gZGVmYXVsdAogICAgcmV0dXJuIG1heChtaW5p
  >> "!B64TMP!" echo bXVtLCB2YWx1ZSkKCgpkZWYgX3Byb3h5X2Zyb21fZW52KCkgLT4gT3B0aW9uYWxbRGljdFtzdHIs
  >> "!B64TMP!" echo IHN0cl1dOgogICAgc2VydmVyID0gKG9zLmVudmlyb24uZ2V0KCJQUk9YWV9TRVJWRVIiKSBvciAi
  >> "!B64TMP!" echo Iikuc3RyaXAoKQogICAgaWYgbm90IHNlcnZlcjoKICAgICAgICByZXR1cm4gTm9uZQogICAgaWYg
  >> "!B64TMP!" echo IjovLyIgbm90IGluIHNlcnZlcjoKICAgICAgICBzZXJ2ZXIgPSAiaHR0cDovLyIgKyBzZXJ2ZXIK
  >> "!B64TMP!" echo ICAgIHByb3h5ID0geyJzZXJ2ZXIiOiBzZXJ2ZXJ9CiAgICB1c2VyID0gb3MuZW52aXJvbi5nZXQo
  >> "!B64TMP!" echo IlBST1hZX1VTRVJOQU1FIikgb3IgIiIKICAgIHBhc3N3b3JkID0gb3MuZW52aXJvbi5nZXQoIlBS
  >> "!B64TMP!" echo T1hZX1BBU1NXT1JEIikgb3IgIiIKICAgIGlmIHVzZXI6CiAgICAgICAgcHJveHlbInVzZXJuYW1l
  >> "!B64TMP!" echo Il0gPSB1c2VyCiAgICBpZiBwYXNzd29yZDoKICAgICAgICBwcm94eVsicGFzc3dvcmQiXSA9IHBh
  >> "!B64TMP!" echo c3N3b3JkCiAgICByZXR1cm4gcHJveHkKCgpjbGFzcyBDb25maWc6CiAgICBkZWYgX19pbml0X18o
  >> "!B64TMP!" echo c2VsZikgLT4gTm9uZToKICAgICAgICBzZWxmLnBvcnQgPSBfZW52X2ludCgiUE9SVCIsIDMwMDAp
  >> "!B64TMP!" echo CiAgICAgICAgc2VsZi5tYXhfcGFnZXMgPSBfZW52X2ludCgiTUFYX0NPTkNVUlJFTlRfUEFHRVMi
  >> "!B64TMP!" echo LCA0KQogICAgICAgIHNlbGYuYmxvY2tfbWVkaWEgPSBfZW52X2Jvb2woIkJMT0NLX01FRElBIiwg
  >> "!B64TMP!" echo RmFsc2UpCiAgICAgICAgc2VsZi5ibG9ja19hZHMgPSBfZW52X2Jvb2woIkJMT0NLX0FEUyIsIEZh
  >> "!B64TMP!" echo bHNlKQogICAgICAgIHNlbGYuc3NyZl9ndWFyZCA9IG5vdCBfZW52X2Jvb2woIkFMTE9XX0xPQ0FM
  >> "!B64TMP!" echo X1dFQkhPT0tTIiwgRmFsc2UpCiAgICAgICAgc2VsZi5ob25vcl91c2VyX2FnZW50ID0gX2Vudl9i
  >> "!B64TMP!" echo b29sKCJJTlZQV19IT05PUl9VU0VSX0FHRU5UIiwgRmFsc2UpCiAgICAgICAgc2VsZi5wcm94eSA9
  >> "!B64TMP!" echo IF9wcm94eV9mcm9tX2VudigpCiAgICAgICAgc2VlZCA9IChvcy5lbnZpcm9uLmdldCgiSU5WUFdf
  >> "!B64TMP!" echo U0VFRCIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgc2VsZi5zZWVkOiBPcHRpb25hbFtpbnRdID0g
  >> "!B64TMP!" echo aW50KHNlZWQpIGlmIHNlZWQubHN0cmlwKCItIikuaXNkaWdpdCgpIGVsc2UgTm9uZQogICAgICAg
  >> "!B64TMP!" echo IHNlbGYudGltZXpvbmUgPSAob3MuZW52aXJvbi5nZXQoIklOVlBXX1RJTUVaT05FIikgb3IgIiIp
  >> "!B64TMP!" echo LnN0cmlwKCkKICAgICAgICBzZWxmLmxvY2FsZSA9IChvcy5lbnZpcm9uLmdldCgiSU5WUFdfTE9D
  >> "!B64TMP!" echo QUxFIikgb3IgIiIpLnN0cmlwKCkgb3IgImF1dG8iCiAgICAgICAgc2VsZi5mYWxsYmFja190aW1l
  >> "!B64TMP!" echo em9uZSA9ICJVVEMiCiAgICAgICAgIyBzdGFydCB0aGUgYnJvd3NlciB3aGVuIHRoZSBhcHAgc3Rh
  >> "!B64TMP!" echo cnRzICh0ZXN0cyB0dXJuIHRoaXMgb2ZmKQogICAgICAgIHNlbGYuZWFnZXJfc3RhcnQgPSBUcnVl
  >> "!B64TMP!" echo CgogICAgQHByb3BlcnR5CiAgICBkZWYgaW50ZXJjZXB0KHNlbGYpIC0+IGJvb2w6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIHNlbGYuYmxvY2tfbWVkaWEgb3Igc2VsZi5ibG9ja19hZHMgb3Igc2VsZi5zc3JmX2d1
  >> "!B64TMP!" echo YXJkCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiMgVVJMIC8gU1NSRiBoZWxwZXJzCiMgLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLQpkZWYgX2lzX3B1YmxpY19hZGRyZXNzKGFkZHI6IHN0cikgLT4gYm9vbDoK
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICBpcCA9IGlwYWRkcmVzcy5pcF9hZGRyZXNzKGFkZHIuc3BsaXQoIiUi
  >> "!B64TMP!" echo LCAxKVswXSkKICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgIHJldHVybiBGYWxzZQogICAg
  >> "!B64TMP!" echo cmV0dXJuIGlwLmlzX2dsb2JhbCBhbmQgbm90IGlwLmlzX211bHRpY2FzdAoKCmFzeW5jIGRlZiBy
  >> "!B64TMP!" echo ZXNvbHZlX2hvc3QoaG9zdDogc3RyKSAtPiBMaXN0W3N0cl06CiAgICAiIiJFdmVyeSBhZGRyZXNz
  >> "!B64TMP!" echo IGEgaG9zdG5hbWUgcmVzb2x2ZXMgdG8gKFtdIHdoZW4gaXQgZG9lcyBub3QgcmVzb2x2ZSkuIiIi
  >> "!B64TMP!" echo CiAgICBsb29wID0gYXN5bmNpby5nZXRfcnVubmluZ19sb29wKCkKICAgIHRyeToKICAgICAgICBp
  >> "!B64TMP!" echo bmZvcyA9IGF3YWl0IGxvb3AuZ2V0YWRkcmluZm8oaG9zdCwgTm9uZSkKICAgIGV4Y2VwdCBPU0Vy
  >> "!B64TMP!" echo cm9yOgogICAgICAgIHJldHVybiBbXQogICAgcmV0dXJuIHNvcnRlZCh7aW5mb1s0XVswXSBmb3Ig
  >> "!B64TMP!" echo aW5mbyBpbiBpbmZvc30pCgoKYXN5bmMgZGVmIGhvc3RfaXNfcHVibGljKGhvc3Q6IHN0cikgLT4g
  >> "!B64TMP!" echo Ym9vbDoKICAgICIiIlRydWUgd2hlbiBldmVyeSBhZGRyZXNzIHRoZSBob3N0IHJlc29sdmVzIHRv
  >> "!B64TMP!" echo IGlzIGEgcHVibGljIHVuaWNhc3Qgb25lLiIiIgogICAgaWYgbm90IGhvc3Q6CiAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIEZhbHNlCiAgICB0cnk6CiAgICAgICAgaXBhZGRyZXNzLmlwX2FkZHJlc3MoaG9zdCkKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gX2lzX3B1YmxpY19hZGRyZXNzKGhvc3QpCiAgICBleGNlcHQgVmFsdWVFcnJv
  >> "!B64TMP!" echo cjoKICAgICAgICBwYXNzCiAgICBhZGRycyA9IGF3YWl0IHJlc29sdmVfaG9zdChob3N0KQogICAg
  >> "!B64TMP!" echo cmV0dXJuIGJvb2woYWRkcnMpIGFuZCBhbGwoX2lzX3B1YmxpY19hZGRyZXNzKGEpIGZvciBhIGlu
  >> "!B64TMP!" echo IGFkZHJzKQoKCmRlZiBwYXJzZV90YXJnZXQodXJsOiBBbnkpIC0+IFR1cGxlW09wdGlvbmFsW0Fu
  >> "!B64TMP!" echo eV0sIE9wdGlvbmFsW3N0cl1dOgogICAgIiIiLT4gKHBhcnNlZCwgcHJvYmxlbSkuIHByb2JsZW0g
  >> "!B64TMP!" echo aXMgJ2ludmFsaWQnIG9yICdzY2hlbWUnIHdoZW4gdW51c2FibGUuIiIiCiAgICBpZiBub3QgaXNp
  >> "!B64TMP!" echo bnN0YW5jZSh1cmwsIHN0cikgb3Igbm90IHVybC5zdHJpcCgpOgogICAgICAgIHJldHVybiBOb25l
  >> "!B64TMP!" echo LCAiaW52YWxpZCIKICAgIHRyeToKICAgICAgICBwYXJzZWQgPSB1cmxwYXJzZSh1cmwuc3RyaXAo
  >> "!B64TMP!" echo KSkKICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgIHJldHVybiBOb25lLCAiaW52YWxpZCIK
  >> "!B64TMP!" echo ICAgIGlmIG5vdCBwYXJzZWQuc2NoZW1lOgogICAgICAgIHJldHVybiBOb25lLCAiaW52YWxpZCIK
  >> "!B64TMP!" echo ICAgIGlmIHBhcnNlZC5zY2hlbWUgbm90IGluICgiaHR0cCIsICJodHRwcyIpOgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBwYXJzZWQsICJzY2hlbWUiCiAgICBpZiBub3QgcGFyc2VkLmhvc3RuYW1lOgogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBOb25lLCAiaW52YWxpZCIKICAgIHJldHVybiBwYXJzZWQsIE5vbmUKCgpkZWYgcGFy
  >> "!B64TMP!" echo c2VfY29va2llX2hlYWRlcih2YWx1ZTogc3RyKSAtPiBMaXN0W1R1cGxlW3N0ciwgc3RyXV06CiAg
  >> "!B64TMP!" echo ICBwYWlycyA9IFtdCiAgICBmb3IgcGFydCBpbiB2YWx1ZS5zcGxpdCgiOyIpOgogICAgICAgIGlm
  >> "!B64TMP!" echo ICI9IiBub3QgaW4gcGFydDoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBuYW1lLCBfLCB2
  >> "!B64TMP!" echo YWwgPSBwYXJ0LnBhcnRpdGlvbigiPSIpCiAgICAgICAgbmFtZSA9IG5hbWUuc3RyaXAoKQogICAg
  >> "!B64TMP!" echo ICAgIGlmIG5hbWU6CiAgICAgICAgICAgIHBhaXJzLmFwcGVuZCgobmFtZSwgdmFsLnN0cmlwKCkp
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIHBhaXJzCgoKZGVmIGNvb2tpZV9kb21haW5zKGhvc3Q6IHN0cikgLT4gTGlz
  >> "!B64TMP!" echo dFtzdHJdOgogICAgIiIiRG9tYWlucyBhIGNhbGxlci1zdXBwbGllZCBjb29raWUgaXMgc3RvcmVk
  >> "!B64TMP!" echo IHVuZGVyLgoKICAgIFRoZSBob3N0IGl0c2VsZiwgcGx1cyB0aGUgcGFyZW50IG9mIGEgbGVhZGlu
  >> "!B64TMP!" echo ZyAnd3d3Licgc28gYSByZWRpcmVjdCBmcm9tCiAgICB3d3cuZXhhbXBsZS5jb20gdG8gZXhhbXBs
  >> "!B64TMP!" echo ZS5jb20gKG9yIGJhY2spIGtlZXBzIHRoZSBjb29raWUuIENvb2tpZXMgYXJlIG5ldmVyCiAgICB3
  >> "!B64TMP!" echo aWRlbmVkIHRvIHRoZSBsYXN0IHR3byBsYWJlbHM6IHRoYXQgd291bGQgYmUgYSBwdWJsaWMgc3Vm
  >> "!B64TMP!" echo Zml4IGZvciBob3N0cyBsaWtlCiAgICBleGFtcGxlLmNvLnVrLCBhbmQgYnJvd3NlcnMgcmVmdXNl
  >> "!B64TMP!" echo IHRob3NlLgogICAgIiIiCiAgICB0cnk6CiAgICAgICAgaXBhZGRyZXNzLmlwX2FkZHJlc3MoaG9z
  >> "!B64TMP!" echo dCkKICAgICAgICByZXR1cm4gW2hvc3RdCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICBw
  >> "!B64TMP!" echo YXNzCiAgICBkb21haW5zID0gWyIuIiArIGhvc3RdCiAgICBpZiBob3N0LnN0YXJ0c3dpdGgoInd3
  >> "!B64TMP!" echo dy4iKSBhbmQgaG9zdC5jb3VudCgiLiIpID49IDI6CiAgICAgICAgZG9tYWlucy5hcHBlbmQoIi4i
  >> "!B64TMP!" echo ICsgaG9zdFs0Ol0pCiAgICByZXR1cm4gZG9tYWlucwoKCmRlZiBpc19hZF9ob3N0KGhvc3Q6IHN0
  >> "!B64TMP!" echo cikgLT4gYm9vbDoKICAgIGhvc3QgPSBob3N0Lmxvd2VyKCkKICAgIHJldHVybiBhbnkoaG9zdCA9
  >> "!B64TMP!" echo PSBoIG9yIGhvc3QuZW5kc3dpdGgoIi4iICsgaCkgZm9yIGggaW4gQURfSE9TVFMpCgoKZGVmIHN0
  >> "!B64TMP!" echo YXR1c19waHJhc2Uoc3RhdHVzOiBpbnQpIC0+IHN0cjoKICAgIHRyeToKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo aHR0cC5IVFRQU3RhdHVzKHN0YXR1cykucGhyYXNlCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gIkhUVFAgIiArIHN0cihzdGF0dXMpCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo CiMgYnJvd3NlciBsaWZlY3ljbGUKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCkJyb3dzZXJGYWN0b3J5
  >> "!B64TMP!" echo ID0gQ2FsbGFibGVbW0FzeW5jRXhpdFN0YWNrLCBDb25maWddLCBBd2FpdGFibGVbQW55XV0KCgph
  >> "!B64TMP!" echo c3luYyBkZWYgbGF1bmNoX2ludmlzaWJsZShzdGFjazogQXN5bmNFeGl0U3RhY2ssIGNmZzogQ29u
  >> "!B64TMP!" echo ZmlnKSAtPiBBbnk6CiAgICAiIiJTdGFydCBpbnZpc2libGUtcGxheXdyaWdodCBhbmQgcmV0dXJu
  >> "!B64TMP!" echo IGl0cyBQbGF5d3JpZ2h0IEJyb3dzZXIuIiIiCiAgICBmcm9tIGludmlzaWJsZV9wbGF5d3JpZ2h0
  >> "!B64TMP!" echo LmFzeW5jX2FwaSBpbXBvcnQgSW52aXNpYmxlUGxheXdyaWdodAoKICAgIGt3YXJnczogRGljdFtz
  >> "!B64TMP!" echo dHIsIEFueV0gPSB7ImhlYWRsZXNzIjogVHJ1ZSwgImxvY2FsZSI6IGNmZy5sb2NhbGV9CiAgICBp
  >> "!B64TMP!" echo ZiBjZmcuc2VlZCBpcyBub3QgTm9uZToKICAgICAgICBrd2FyZ3NbInNlZWQiXSA9IGNmZy5zZWVk
  >> "!B64TMP!" echo CiAgICBpZiBjZmcucHJveHk6CiAgICAgICAga3dhcmdzWyJwcm94eSJdID0gY2ZnLnByb3h5CiAg
  >> "!B64TMP!" echo ICBpZiBjZmcudGltZXpvbmU6CiAgICAgICAga3dhcmdzWyJ0aW1lem9uZSJdID0gY2ZnLnRpbWV6
  >> "!B64TMP!" echo b25lCiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGF3YWl0IHN0YWNrLmVudGVyX2FzeW5jX2NvbnRl
  >> "!B64TMP!" echo eHQoSW52aXNpYmxlUGxheXdyaWdodCgqKmt3YXJncykpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFz
  >> "!B64TMP!" echo IGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgaWYgY2ZnLnRpbWV6b25lIG9yIGNmZy5wcm94
  >> "!B64TMP!" echo eToKICAgICAgICAgICAgIyBBbiBleHBsaWNpdCB0aW1lem9uZSBoYXMgbm90aGluZyB0byBmYWxs
  >> "!B64TMP!" echo IGJhY2sgdG8uIEJlaGluZCBhIHByb3h5IHRoZQogICAgICAgICAgICAjIHRpbWV6b25lIE1VU1Qg
  >> "!B64TMP!" echo bWF0Y2ggdGhlIHByb3h5J3MgZXhpdCBJUCBhbmQgdGhlIGVuZ2luZSByZWZ1c2VzIHRvCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICMgZ3Vlc3MsIHNvIGEgZmFpbHVyZSBoZXJlIGlzIHJlcG9ydGVkLCBuZXZlciBwYXBl
  >> "!B64TMP!" echo cmVkIG92ZXIgd2l0aCBVVEMuCiAgICAgICAgICAgIHJhaXNlCiAgICAgICAgIyBObyBwcm94eTog
  >> "!B64TMP!" echo ImF1dG8iIGRlcml2ZXMgdGhlIHRpbWV6b25lIGZyb20gdGhpcyBtYWNoaW5lJ3MgcHVibGljIElQ
  >> "!B64TMP!" echo IGFuZAogICAgICAgICMgbmVlZHMgYSBHZW9JUCBkYXRhYmFzZTsgb24gYSBjb2xkIGNhY2hlIHdp
  >> "!B64TMP!" echo dGggbm8gcm91dGUgdG8gR2l0SHViIHRoYXQKICAgICAgICAjIGZhaWxzLiBBIGZpeGVkIHRpbWV6
  >> "!B64TMP!" echo b25lIGtlZXBzIHRoZSBzZXJ2aWNlIHVwLCBhdCB0aGUgY29zdCBvZiBvbmUKICAgICAgICAjIGZp
  >> "!B64TMP!" echo bmdlcnByaW50IGRldGFpbCAodGhlIHRpbWV6b25lIHRoZW4gbWF5IG5vdCBtYXRjaCB0aGUgSVAn
  >> "!B64TMP!" echo cyBsb2NhdGlvbikuCiAgICAgICAgbG9nLndhcm5pbmcoImxhdW5jaCB3aXRoIGF1dG9tYXRpYyB0
  >> "!B64TMP!" echo aW1lem9uZSBmYWlsZWQgKCVzKTsgcmV0cnlpbmcgd2l0aCAlcyIsCiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgZXhjLCBjZmcuZmFsbGJhY2tfdGltZXpvbmUpCiAgICAgICAga3dhcmdzWyJ0aW1lem9uZSJd
  >> "!B64TMP!" echo ID0gY2ZnLmZhbGxiYWNrX3RpbWV6b25lCiAgICAgICAgcmV0dXJuIGF3YWl0IHN0YWNrLmVudGVy
  >> "!B64TMP!" echo X2FzeW5jX2NvbnRleHQoSW52aXNpYmxlUGxheXdyaWdodCgqKmt3YXJncykpCgoKY2xhc3MgQnJv
  >> "!B64TMP!" echo d3NlckhvbGRlcjoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBjZmc6IENvbmZpZywgZmFjdG9yeTog
  >> "!B64TMP!" echo QnJvd3NlckZhY3RvcnkpIC0+IE5vbmU6CiAgICAgICAgc2VsZi5fY2ZnID0gY2ZnCiAgICAgICAg
  >> "!B64TMP!" echo c2VsZi5fZmFjdG9yeSA9IGZhY3RvcnkKICAgICAgICBzZWxmLl9icm93c2VyOiBBbnkgPSBOb25l
  >> "!B64TMP!" echo CiAgICAgICAgc2VsZi5fc3RhY2s6IE9wdGlvbmFsW0FzeW5jRXhpdFN0YWNrXSA9IE5vbmUKICAg
  >> "!B64TMP!" echo ICAgICBzZWxmLl9sb2NrID0gYXN5bmNpby5Mb2NrKCkKCiAgICBAc3RhdGljbWV0aG9kCiAgICBk
  >> "!B64TMP!" echo ZWYgX2Nvbm5lY3RlZChicm93c2VyOiBBbnkpIC0+IGJvb2w6CiAgICAgICAgY2hlY2sgPSBnZXRh
  >> "!B64TMP!" echo dHRyKGJyb3dzZXIsICJpc19jb25uZWN0ZWQiLCBOb25lKQogICAgICAgIHRyeToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIGJvb2woY2hlY2soKSkgaWYgY2FsbGFibGUoY2hlY2spIGVsc2UgVHJ1ZQogICAg
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBFeGNlcHRpb246ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UKCiAgICBhc3luYyBkZWYgZ2V0KHNlbGYpIC0+IEFueToKICAgICAgICBhc3luYyB3aXRo
  >> "!B64TMP!" echo IHNlbGYuX2xvY2s6CiAgICAgICAgICAgIGlmIHNlbGYuX2Jyb3dzZXIgaXMgbm90IE5vbmUgYW5k
  >> "!B64TMP!" echo IHNlbGYuX2Nvbm5lY3RlZChzZWxmLl9icm93c2VyKToKICAgICAgICAgICAgICAgIHJldHVybiBz
  >> "!B64TMP!" echo ZWxmLl9icm93c2VyCiAgICAgICAgICAgIGlmIHNlbGYuX2Jyb3dzZXIgaXMgbm90IE5vbmU6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBsb2cud2FybmluZygidGhlIGJyb3dzZXIgd2VudCBhd2F5OyBzdGFydGlu
  >> "!B64TMP!" echo ZyBhIG5ldyBvbmUiKQogICAgICAgICAgICBhd2FpdCBzZWxmLl9jbG9zZV9sb2NrZWQoKQogICAg
  >> "!B64TMP!" echo ICAgICAgICBzdGFjayA9IEFzeW5jRXhpdFN0YWNrKCkKICAgICAgICAgICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgYnJvd3NlciA9IGF3YWl0IHNlbGYuX2ZhY3Rvcnkoc3RhY2ssIHNlbGYuX2NmZykK
  >> "!B64TMP!" echo ICAgICAgICAgICAgZXhjZXB0IEJhc2VFeGNlcHRpb246CiAgICAgICAgICAgICAgICB0cnk6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgYXdhaXQgc3RhY2suYWNsb3NlKCkKICAgICAgICAgICAgICAgIGV4
  >> "!B64TMP!" echo Y2VwdCBFeGNlcHRpb246ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICAgICAgICAgIHBhc3MK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHJhaXNlCiAgICAgICAgICAgIHNlbGYuX3N0YWNrLCBzZWxmLl9icm93
  >> "!B64TMP!" echo c2VyID0gc3RhY2ssIGJyb3dzZXIKICAgICAgICAgICAgbG9nLmluZm8oImJyb3dzZXIgcmVhZHki
  >> "!B64TMP!" echo KQogICAgICAgICAgICByZXR1cm4gYnJvd3NlcgoKICAgIGFzeW5jIGRlZiBfY2xvc2VfbG9ja2Vk
  >> "!B64TMP!" echo KHNlbGYpIC0+IE5vbmU6CiAgICAgICAgc3RhY2ssIHNlbGYuX3N0YWNrLCBzZWxmLl9icm93c2Vy
  >> "!B64TMP!" echo ID0gc2VsZi5fc3RhY2ssIE5vbmUsIE5vbmUKICAgICAgICBpZiBzdGFjayBpcyBub3QgTm9uZToK
  >> "!B64TMP!" echo ICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgYXdhaXQgc3RhY2suYWNsb3NlKCkKICAg
  >> "!B64TMP!" echo ICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgbG9nLndhcm5pbmcoImVycm9yIHdoaWxlIGNsb3NpbmcgdGhlIGJyb3dzZXI6ICVz
  >> "!B64TMP!" echo IiwgZXhjKQoKICAgIGFzeW5jIGRlZiBjbG9zZShzZWxmKSAtPiBOb25lOgogICAgICAgIGFzeW5j
  >> "!B64TMP!" echo IHdpdGggc2VsZi5fbG9jazoKICAgICAgICAgICAgYXdhaXQgc2VsZi5fY2xvc2VfbG9ja2VkKCkK
  >> "!B64TMP!" echo CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyByZXF1ZXN0IGhhbmRsaW5nCiMgLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQpjbGFzcyBTZXJ2aWNlOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGNmZzogQ29uZmln
  >> "!B64TMP!" echo LCBmYWN0b3J5OiBCcm93c2VyRmFjdG9yeSkgLT4gTm9uZToKICAgICAgICBzZWxmLmNmZyA9IGNm
  >> "!B64TMP!" echo ZwogICAgICAgIHNlbGYuaG9sZGVyID0gQnJvd3NlckhvbGRlcihjZmcsIGZhY3RvcnkpCiAgICAg
  >> "!B64TMP!" echo ICAgc2VsZi5zZW0gPSBhc3luY2lvLlNlbWFwaG9yZShjZmcubWF4X3BhZ2VzKQogICAgICAgIHNl
  >> "!B64TMP!" echo bGYuYWN0aXZlID0gMAoKICAgICMgLS0gL2hlYWx0aCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICBhc3luYyBkZWYgaGVhbHRo
  >> "!B64TMP!" echo KHNlbGYsIHJlcXVlc3Q6IHdlYi5SZXF1ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgICAgICBicm93c2VyID0gYXdhaXQgc2VsZi5ob2xkZXIuZ2V0KCkKICAgICAgICAg
  >> "!B64TMP!" echo ICAgY29udGV4dCA9IGF3YWl0IGJyb3dzZXIubmV3X2NvbnRleHQoKQogICAgICAgICAgICB0cnk6
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwYWdlID0gYXdhaXQgY29udGV4dC5uZXdfcGFnZSgpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBhd2FpdCBwYWdlLmNsb3NlKCkKICAgICAgICAgICAgZmluYWxseToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIGF3YWl0IGNvbnRleHQuY2xvc2UoKQogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25f
  >> "!B64TMP!" echo cmVzcG9uc2UoewogICAgICAgICAgICAgICAgInN0YXR1cyI6ICJoZWFsdGh5IiwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICJtYXhDb25jdXJyZW50UGFnZXMiOiBzZWxmLmNmZy5tYXhfcGFnZXMsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiYWN0aXZlUGFnZXMiOiBzZWxmLmFjdGl2ZSwKICAgICAgICAgICAgfSkKICAgICAg
  >> "!B64TMP!" echo ICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgIGxv
  >> "!B64TMP!" echo Zy53YXJuaW5nKCJoZWFsdGggY2hlY2sgZmFpbGVkOiAlcyIsIGV4YykKICAgICAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIHdlYi5qc29uX3Jlc3BvbnNlKHsic3RhdHVzIjogInVuaGVhbHRoeSIsICJlcnJvciI6IHN0
  >> "!B64TMP!" echo cihleGMpWzozMDBdfSwgc3RhdHVzPTUwMykKCiAgICAjIC0tIC9zY3JhcGUgLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgYXN5
  >> "!B64TMP!" echo bmMgZGVmIHNjcmFwZShzZWxmLCByZXF1ZXN0OiB3ZWIuUmVxdWVzdCkgLT4gd2ViLlJlc3BvbnNl
  >> "!B64TMP!" echo OgogICAgICAgIHRyeToKICAgICAgICAgICAgYm9keSA9IGF3YWl0IHJlcXVlc3QuanNvbigpCiAg
  >> "!B64TMP!" echo ICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgIGJvZHkg
  >> "!B64TMP!" echo PSBOb25lCiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UoYm9keSwgZGljdCk6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImVycm9yIjogIlVSTCBpcyByZXF1aXJlZCJ9LCBz
  >> "!B64TMP!" echo dGF0dXM9NDAwKQoKICAgICAgICB1cmwgPSBib2R5LmdldCgidXJsIikKICAgICAgICBpZiBub3Qg
  >> "!B64TMP!" echo dXJsOgogICAgICAgICAgICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6ICJVUkwg
  >> "!B64TMP!" echo aXMgcmVxdWlyZWQifSwgc3RhdHVzPTQwMCkKICAgICAgICBwYXJzZWQsIHByb2JsZW0gPSBwYXJz
  >> "!B64TMP!" echo ZV90YXJnZXQodXJsKQogICAgICAgIGlmIHByb2JsZW0gPT0gImludmFsaWQiOgogICAgICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6ICJJbnZhbGlkIFVSTCJ9LCBzdGF0
  >> "!B64TMP!" echo dXM9NDAwKQogICAgICAgIGlmIHByb2JsZW0gPT0gInNjaGVtZSI6CiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBzZWxmLl9ibG9ja2VkKCJPbmx5IGh0dHAgYW5kIGh0dHBzIFVSTHMgY2FuIGJlIGZldGNoZWQu
  >> "!B64TMP!" echo IikKCiAgICAgICAgd2FpdF9hZnRlcl9sb2FkID0gc2VsZi5faW50KGJvZHkuZ2V0KCJ3YWl0X2Fm
  >> "!B64TMP!" echo dGVyX2xvYWQiKSwgMCwgMCwgMTIwMDAwKQogICAgICAgIHRpbWVvdXQgPSBzZWxmLl9pbnQoYm9k
  >> "!B64TMP!" echo eS5nZXQoInRpbWVvdXQiKSwgMTUwMDAsIDEsIDYwMDAwMCkKICAgICAgICBoZWFkZXJzID0gYm9k
  >> "!B64TMP!" echo eS5nZXQoImhlYWRlcnMiKSBpZiBpc2luc3RhbmNlKGJvZHkuZ2V0KCJoZWFkZXJzIiksIGRpY3Qp
  >> "!B64TMP!" echo IGVsc2Uge30KICAgICAgICBjaGVja19zZWxlY3RvciA9IGJvZHkuZ2V0KCJjaGVja19zZWxlY3Rv
  >> "!B64TMP!" echo ciIpIG9yIE5vbmUKICAgICAgICBza2lwX3RscyA9IGJvb2woYm9keS5nZXQoInNraXBfdGxzX3Zl
  >> "!B64TMP!" echo cmlmaWNhdGlvbiIpKQoKICAgICAgICBob3N0ID0gKHBhcnNlZC5ob3N0bmFtZSBvciAiIikubG93
  >> "!B64TMP!" echo ZXIoKQogICAgICAgIGlmIHNlbGYuY2ZnLnNzcmZfZ3VhcmQgYW5kIG5vdCBhd2FpdCBob3N0X2lz
  >> "!B64TMP!" echo X3B1YmxpYyhob3N0KToKICAgICAgICAgICAgcmV0dXJuIHNlbGYuX2Jsb2NrZWQoIlJlcXVlc3Rz
  >> "!B64TMP!" echo IHRvIHByaXZhdGUgb3IgdW5yZXNvbHZhYmxlIGFkZHJlc3NlcyBhcmUgbm90IGFsbG93ZWQuIikK
  >> "!B64TMP!" echo CiAgICAgICAgIyBvbmUgc2xvdyBwYWdlIGNhbiBuZXZlciBob2xkIG1vcmUgdGhhbiB0aGUgbmF2
  >> "!B64TMP!" echo aWdhdGlvbiBidWRnZXQgcGx1cyBzbGFjawogICAgICAgIGJ1ZGdldCA9ICh0aW1lb3V0ICsgd2Fp
  >> "!B64TMP!" echo dF9hZnRlcl9sb2FkKSAvIDEwMDAuMCArIDMwLjAKICAgICAgICBzdGFydGVkID0gdGltZS5tb25v
  >> "!B64TMP!" echo dG9uaWMoKQogICAgICAgIGFzeW5jIHdpdGggc2VsZi5zZW06CiAgICAgICAgICAgIHNlbGYuYWN0
  >> "!B64TMP!" echo aXZlICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgcmV0dXJuIGF3YWl0IGFz
  >> "!B64TMP!" echo eW5jaW8ud2FpdF9mb3IoCiAgICAgICAgICAgICAgICAgICAgc2VsZi5fZmV0Y2gocGFyc2VkLCBz
  >> "!B64TMP!" echo dHIodXJsKS5zdHJpcCgpLCB3YWl0X2FmdGVyX2xvYWQsIHRpbWVvdXQsCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgaGVhZGVycywgY2hlY2tfc2VsZWN0b3IsIHNraXBfdGxzKSwKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICB0aW1lb3V0PWJ1ZGdldCkKICAgICAgICAgICAgZXhjZXB0IGFzeW5j
  >> "!B64TMP!" echo aW8uVGltZW91dEVycm9yOgogICAgICAgICAgICAgICAgbG9nLndhcm5pbmcoInNjcmFwZSBvZiAl
  >> "!B64TMP!" echo cyB0aW1lZCBvdXQgYWZ0ZXIgJS4wZnMiLCBzZWxmLl9zYWZlKHBhcnNlZCksIGJ1ZGdldCkKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHJldHVybiBzZWxmLl9mYWlsZWQoInRpbWVkIG91dCIpCiAgICAgICAgICAg
  >> "!B64TMP!" echo IGZpbmFsbHk6CiAgICAgICAgICAgICAgICBzZWxmLmFjdGl2ZSAtPSAxCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBsb2cuaW5mbygic2NyYXBlICVzIHRvb2sgJS4xZnMiLCBzZWxmLl9zYWZlKHBhcnNlZCksIHRp
  >> "!B64TMP!" echo bWUubW9ub3RvbmljKCkgLSBzdGFydGVkKQoKICAgIGFzeW5jIGRlZiBfZmV0Y2goc2VsZiwgcGFy
  >> "!B64TMP!" echo c2VkOiBBbnksIHVybDogc3RyLCB3YWl0X2FmdGVyX2xvYWQ6IGludCwgdGltZW91dDogaW50LAog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBoZWFkZXJzOiBEaWN0W3N0ciwgQW55XSwgY2hlY2tfc2VsZWN0
  >> "!B64TMP!" echo b3I6IE9wdGlvbmFsW3N0cl0sCiAgICAgICAgICAgICAgICAgICAgIHNraXBfdGxzOiBib29sKSAt
  >> "!B64TMP!" echo PiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgYmxvY2tlZDogTGlzdFtzdHJdID0gW10KICAgICAgICBj
  >> "!B64TMP!" echo b250ZXh0ID0gTm9uZQogICAgICAgIHRyeToKICAgICAgICAgICAgYnJvd3NlciA9IGF3YWl0IHNl
  >> "!B64TMP!" echo bGYuaG9sZGVyLmdldCgpCiAgICAgICAgICAgIGN0eF9rd2FyZ3M6IERpY3Rbc3RyLCBBbnldID0g
  >> "!B64TMP!" echo e30KICAgICAgICAgICAgaWYgc2tpcF90bHM6CiAgICAgICAgICAgICAgICBjdHhfa3dhcmdzWyJp
  >> "!B64TMP!" echo Z25vcmVfaHR0cHNfZXJyb3JzIl0gPSBUcnVlCiAgICAgICAgICAgIHVhID0gc2VsZi5faGVhZGVy
  >> "!B64TMP!" echo KGhlYWRlcnMsICJ1c2VyLWFnZW50IikKICAgICAgICAgICAgaWYgdWEgYW5kIHNlbGYuY2ZnLmhv
  >> "!B64TMP!" echo bm9yX3VzZXJfYWdlbnQ6CiAgICAgICAgICAgICAgICBjdHhfa3dhcmdzWyJ1c2VyX2FnZW50Il0g
  >> "!B64TMP!" echo PSB1YQogICAgICAgICAgICAjIEV4dHJhIGhlYWRlcnMgTVVTVCBiZSBnaXZlbiB3aGVuIHRoZSBj
  >> "!B64TMP!" echo b250ZXh0IGlzIGNyZWF0ZWQ6IHRoaXMgZW5naW5lCiAgICAgICAgICAgICMgZG9lcyBub3QgaW1w
  >> "!B64TMP!" echo bGVtZW50IEJyb3dzZXJDb250ZXh0LnNldF9leHRyYV9odHRwX2hlYWRlcnMoKSAoIm5vdAogICAg
  >> "!B64TMP!" echo ICAgICAgICAjIHdpcmVkIHlldCIpLCBzbyBjYWxsaW5nIGl0IGFmdGVyd2FyZHMgZmFpbHMgZXZl
  >> "!B64TMP!" echo cnkgcmVxdWVzdCB0aGF0CiAgICAgICAgICAgICMgY2FycmllcyBvbmUuIFVzZXItQWdlbnQgYW5k
  >> "!B64TMP!" echo IENvb2tpZSBhcmUgaGFuZGxlZCBzZXBhcmF0ZWx5LgogICAgICAgICAgICBleHRyYSA9IHtzdHIo
  >> "!B64TMP!" echo ayk6IHN0cih2KSBmb3IgaywgdiBpbiBoZWFkZXJzLml0ZW1zKCkKICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgaWYgc3RyKGspLmxvd2VyKCkgbm90IGluICgidXNlci1hZ2VudCIsICJjb29raWUiKX0KICAg
  >> "!B64TMP!" echo ICAgICAgICAgaWYgZXh0cmE6CiAgICAgICAgICAgICAgICBjdHhfa3dhcmdzWyJleHRyYV9odHRw
  >> "!B64TMP!" echo X2hlYWRlcnMiXSA9IGV4dHJhCiAgICAgICAgICAgIGNvbnRleHQgPSBhd2FpdCBicm93c2VyLm5l
  >> "!B64TMP!" echo d19jb250ZXh0KCoqY3R4X2t3YXJncykKCiAgICAgICAgICAgIGNvb2tpZSA9IHNlbGYuX2hlYWRl
  >> "!B64TMP!" echo cihoZWFkZXJzLCAiY29va2llIikKICAgICAgICAgICAgaWYgY29va2llOgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgY29va2llcyA9IFtdCiAgICAgICAgICAgICAgICBmb3IgbmFtZSwgdmFsdWUgaW4gcGFyc2Vf
  >> "!B64TMP!" echo Y29va2llX2hlYWRlcihjb29raWUpOgogICAgICAgICAgICAgICAgICAgIGZvciBkb21haW4gaW4g
  >> "!B64TMP!" echo Y29va2llX2RvbWFpbnMoKHBhcnNlZC5ob3N0bmFtZSBvciAiIikubG93ZXIoKSk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIGNvb2tpZXMuYXBwZW5kKHsibmFtZSI6IG5hbWUsICJ2YWx1ZSI6IHZh
  >> "!B64TMP!" echo bHVlLCAiZG9tYWluIjogZG9tYWluLCAicGF0aCI6ICIvIn0pCiAgICAgICAgICAgICAgICBpZiBj
  >> "!B64TMP!" echo b29raWVzOgogICAgICAgICAgICAgICAgICAgIGF3YWl0IGNvbnRleHQuYWRkX2Nvb2tpZXMoY29v
  >> "!B64TMP!" echo a2llcykKCgogICAgICAgICAgICBpZiBzZWxmLmNmZy5pbnRlcmNlcHQ6CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBhd2FpdCBjb250ZXh0LnJvdXRlKCIqKi8qIiwgc2VsZi5fbWFrZV9yb3V0ZXIoYmxvY2tlZCkp
  >> "!B64TMP!" echo CgogICAgICAgICAgICBwYWdlID0gYXdhaXQgY29udGV4dC5uZXdfcGFnZSgpCiAgICAgICAgICAg
  >> "!B64TMP!" echo IHBhZ2Uuc2V0X2RlZmF1bHRfdGltZW91dCh0aW1lb3V0KQogICAgICAgICAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICByZXNwb25zZSA9IGF3YWl0IHBhZ2UuZ290byh1cmwsIHdhaXRfdW50aWw9Imxv
  >> "!B64TMP!" echo YWQiLCB0aW1lb3V0PXRpbWVvdXQpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBpZiBibG9ja2VkOgogICAgICAgICAgICAgICAgICAgIHJldHVybiBzZWxmLl9i
  >> "!B64TMP!" echo bG9ja2VkKGJsb2NrZWRbMF0pCiAgICAgICAgICAgICAgICByYWlzZQogICAgICAgICAgICBpZiBi
  >> "!B64TMP!" echo bG9ja2VkIGFuZCByZXNwb25zZSBpcyBOb25lOgogICAgICAgICAgICAgICAgcmV0dXJuIHNlbGYu
  >> "!B64TMP!" echo X2Jsb2NrZWQoYmxvY2tlZFswXSkKCiAgICAgICAgICAgIGlmIHdhaXRfYWZ0ZXJfbG9hZCA+IDA6
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBhd2FpdCBwYWdlLndhaXRfZm9yX3RpbWVvdXQod2FpdF9hZnRlcl9s
  >> "!B64TMP!" echo b2FkKQogICAgICAgICAgICBpZiBjaGVja19zZWxlY3RvcjoKICAgICAgICAgICAgICAgIGF3YWl0
  >> "!B64TMP!" echo IHBhZ2Uud2FpdF9mb3Jfc2VsZWN0b3Ioc3RyKGNoZWNrX3NlbGVjdG9yKSwgdGltZW91dD10aW1l
  >> "!B64TMP!" echo b3V0KQoKICAgICAgICAgICAgc3RhdHVzID0gcmVzcG9uc2Uuc3RhdHVzIGlmIHJlc3BvbnNlIGlz
  >> "!B64TMP!" echo IG5vdCBOb25lIGVsc2UgMjAwCiAgICAgICAgICAgIGNvbnRlbnRfdHlwZSA9IE5vbmUKICAgICAg
  >> "!B64TMP!" echo ICAgICAgaWYgcmVzcG9uc2UgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICBjb250ZW50X3R5
  >> "!B64TMP!" echo cGUgPSAocmVzcG9uc2UuaGVhZGVycyBvciB7fSkuZ2V0KCJjb250ZW50LXR5cGUiKQogICAgICAg
  >> "!B64TMP!" echo ICAgICBsb3dlcmVkID0gKGNvbnRlbnRfdHlwZSBvciAiIikubG93ZXIoKQogICAgICAgICAgICBp
  >> "!B64TMP!" echo ZiAiYXBwbGljYXRpb24vanNvbiIgaW4gbG93ZXJlZCBvciAidGV4dC9wbGFpbiIgaW4gbG93ZXJl
  >> "!B64TMP!" echo ZDoKICAgICAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCByZXNwb25zZS50ZXh0KCkKICAgICAg
  >> "!B64TMP!" echo ICAgICAgZWxzZToKICAgICAgICAgICAgICAgIGNvbnRlbnQgPSBhd2FpdCBwYWdlLmNvbnRlbnQo
  >> "!B64TMP!" echo KQoKICAgICAgICAgICAgcGF5bG9hZDogRGljdFtzdHIsIEFueV0gPSB7CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiY29udGVudCI6IGNvbnRlbnQsCiAgICAgICAgICAgICAgICAicGFnZVN0YXR1c0NvZGUiOiBz
  >> "!B64TMP!" echo dGF0dXMsCiAgICAgICAgICAgICAgICAiY29udGVudFR5cGUiOiBjb250ZW50X3R5cGUsCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIH0KICAgICAgICAgICAgaWYgc3RhdHVzICE9IDIwMDoKICAgICAgICAgICAgICAgIHBh
  >> "!B64TMP!" echo eWxvYWRbInBhZ2VFcnJvciJdID0gc3RhdHVzX3BocmFzZShzdGF0dXMpCiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiB3ZWIuanNvbl9yZXNwb25zZShwYXlsb2FkKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g
  >> "!B64TMP!" echo YXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgaWYgYmxvY2tlZDoKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBzZWxmLl9ibG9ja2VkKGJsb2NrZWRbMF0pCiAgICAgICAgICAgIGxvZy53
  >> "!B64TMP!" echo YXJuaW5nKCJzY3JhcGUgb2YgJXMgZmFpbGVkOiAlcyIsIHNlbGYuX3NhZmUocGFyc2VkKSwgZXhj
  >> "!B64TMP!" echo KQogICAgICAgICAgICByZXR1cm4gc2VsZi5fZmFpbGVkKHN0cihleGMpKQogICAgICAgIGZpbmFs
  >> "!B64TMP!" echo bHk6CiAgICAgICAgICAgIGlmIGNvbnRleHQgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICB0
  >> "!B64TMP!" echo cnk6CiAgICAgICAgICAgICAgICAgICAgYXdhaXQgY29udGV4dC5jbG9zZSgpCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBwYXNzCgogICAgZGVmIF9tYWtlX3JvdXRlcihzZWxmLCBibG9ja2VkOiBMaXN0W3N0cl0pIC0+
  >> "!B64TMP!" echo IENhbGxhYmxlW1tBbnldLCBBd2FpdGFibGVbTm9uZV1dOgogICAgICAgIGNmZyA9IHNlbGYuY2Zn
  >> "!B64TMP!" echo CgogICAgICAgIGFzeW5jIGRlZiByb3V0ZShyb3V0ZV9vYmo6IEFueSkgLT4gTm9uZToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgcmVxdWVzdCA9IHJvdXRlX29iai5yZXF1ZXN0CiAgICAgICAgICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIHRhcmdldCA9IHVybHBhcnNlKHJlcXVlc3QudXJsKQogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo aG9zdCA9ICh0YXJnZXQuaG9zdG5hbWUgb3IgIiIpLmxvd2VyKCkKICAgICAgICAgICAgICAgIGlm
  >> "!B64TMP!" echo IGNmZy5zc3JmX2d1YXJkIGFuZCB0YXJnZXQuc2NoZW1lIGluICgiaHR0cCIsICJodHRwcyIpIFwK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgYW5kIG5vdCBhd2FpdCBob3N0X2lzX3B1YmxpYyhob3N0
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgICAgICAgICBibG9ja2VkLmFwcGVuZCgiUmVxdWVzdHMgdG8gcHJpdmF0
  >> "!B64TMP!" echo ZSBvciB1bnJlc29sdmFibGUgYWRkcmVzc2VzIGFyZSBub3QgYWxsb3dlZC4iKQogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIGF3YWl0IHJvdXRlX29iai5hYm9ydCgiYmxvY2tlZGJ5Y2xpZW50IikKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgICAgIGlmIGNmZy5ibG9ja19hZHMgYW5k
  >> "!B64TMP!" echo IGlzX2FkX2hvc3QoaG9zdCk6CiAgICAgICAgICAgICAgICAgICAgYXdhaXQgcm91dGVfb2JqLmFi
  >> "!B64TMP!" echo b3J0KCJibG9ja2VkYnljbGllbnQiKQogICAgICAgICAgICAgICAgICAgIHJldHVybgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgaWYgY2ZnLmJsb2NrX21lZGlhIGFuZCByZXF1ZXN0LnJlc291cmNlX3R5cGUgaW4g
  >> "!B64TMP!" echo KCJpbWFnZSIsICJtZWRpYSIpOgogICAgICAgICAgICAgICAgICAgIGF3YWl0IHJvdXRlX29iai5h
  >> "!B64TMP!" echo Ym9ydCgiYmxvY2tlZGJ5Y2xpZW50IikKICAgICAgICAgICAgICAgICAgICByZXR1cm4KICAgICAg
  >> "!B64TMP!" echo ICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgbG9nLmRlYnVnKCJyb3V0ZSBjaGVjayBmYWlsZWQsIGxldHRpbmcgdGhlIHJlcXVlc3Qg
  >> "!B64TMP!" echo dGhyb3VnaDogJXMiLCBleGMpCiAgICAgICAgICAgIGF3YWl0IHJvdXRlX29iai5jb250aW51ZV8o
  >> "!B64TMP!" echo KQoKICAgICAgICByZXR1cm4gcm91dGUKCiAgICAjIC0tIHNtYWxsIGhlbHBlcnMgLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgQHN0YXRp
  >> "!B64TMP!" echo Y21ldGhvZAogICAgZGVmIF9pbnQodmFsdWU6IEFueSwgZGVmYXVsdDogaW50LCBsbzogaW50LCBo
  >> "!B64TMP!" echo aTogaW50KSAtPiBpbnQ6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBudW1iZXIgPSBpbnQoZmxv
  >> "!B64TMP!" echo YXQodmFsdWUpKSBpZiB2YWx1ZSBub3QgaW4gKE5vbmUsICIiKSBlbHNlIGRlZmF1bHQKICAgICAg
  >> "!B64TMP!" echo ICBleGNlcHQgKFR5cGVFcnJvciwgVmFsdWVFcnJvcik6CiAgICAgICAgICAgIG51bWJlciA9IGRl
  >> "!B64TMP!" echo ZmF1bHQKICAgICAgICByZXR1cm4gbWF4KGxvLCBtaW4oaGksIG51bWJlcikpCgogICAgQHN0YXRp
  >> "!B64TMP!" echo Y21ldGhvZAogICAgZGVmIF9oZWFkZXIoaGVhZGVyczogRGljdFtzdHIsIEFueV0sIG5hbWU6IHN0
  >> "!B64TMP!" echo cikgLT4gT3B0aW9uYWxbc3RyXToKICAgICAgICBmb3Iga2V5LCB2YWx1ZSBpbiBoZWFkZXJzLml0
  >> "!B64TMP!" echo ZW1zKCk6CiAgICAgICAgICAgIGlmIHN0cihrZXkpLmxvd2VyKCkgPT0gbmFtZSBhbmQgdmFsdWUg
  >> "!B64TMP!" echo bm90IGluIChOb25lLCAiIik6CiAgICAgICAgICAgICAgICByZXR1cm4gc3RyKHZhbHVlKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBOb25lCgogICAgQHN0YXRpY21ldGhvZAogICAgZGVmIF9zYWZlKHBhcnNlZDog
  >> "!B64TMP!" echo QW55KSAtPiBzdHI6CiAgICAgICAgcmV0dXJuICIlczovLyVzJXMiICUgKHBhcnNlZC5zY2hlbWUs
  >> "!B64TMP!" echo IHBhcnNlZC5uZXRsb2MsIHBhcnNlZC5wYXRoKSAgIyBuZXZlciBsb2cgdGhlIHF1ZXJ5CgogICAg
  >> "!B64TMP!" echo QHN0YXRpY21ldGhvZAogICAgZGVmIF9ibG9ja2VkKG1lc3NhZ2U6IHN0cikgLT4gd2ViLlJlc3Bv
  >> "!B64TMP!" echo bnNlOgogICAgICAgIHJldHVybiB3ZWIuanNvbl9yZXNwb25zZSh7ImNvbnRlbnQiOiAiIiwgInBh
  >> "!B64TMP!" echo Z2VTdGF0dXNDb2RlIjogNDAzLCAicGFnZUVycm9yIjogbWVzc2FnZX0pCgogICAgQHN0YXRpY21l
  >> "!B64TMP!" echo dGhvZAogICAgZGVmIF9mYWlsZWQoZGV0YWlsOiBzdHIpIC0+IHdlYi5SZXNwb25zZToKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gd2ViLmpzb25fcmVzcG9uc2UoeyJlcnJvciI6IEdFTkVSSUNfRVJST1IsICJkZXRh
  >> "!B64TMP!" echo aWwiOiBkZXRhaWxbOjMwMF19LCBzdGF0dXM9NTAwKQoKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoj
  >> "!B64TMP!" echo IGFwcGxpY2F0aW9uCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpkZWYgY3JlYXRlX2FwcChjZmc6IE9w
  >> "!B64TMP!" echo dGlvbmFsW0NvbmZpZ10gPSBOb25lLCBicm93c2VyX2ZhY3Rvcnk6IE9wdGlvbmFsW0Jyb3dzZXJG
  >> "!B64TMP!" echo YWN0b3J5XSA9IE5vbmUpIC0+IHdlYi5BcHBsaWNhdGlvbjoKICAgIGNmZyA9IGNmZyBvciBDb25m
  >> "!B64TMP!" echo aWcoKQogICAgYXBwID0gd2ViLkFwcGxpY2F0aW9uKCkKICAgIGhvbGRlcjogRGljdFtzdHIsIFNl
  >> "!B64TMP!" echo cnZpY2VdID0ge30KCiAgICBhc3luYyBkZWYgb25fc3RhcnR1cChfYXBwOiB3ZWIuQXBwbGljYXRp
  >> "!B64TMP!" echo b24pIC0+IE5vbmU6CiAgICAgICAgIyBhc3luY2lvIHByaW1pdGl2ZXMgYXJlIGNyZWF0ZWQgaGVy
  >> "!B64TMP!" echo ZSwgaW5zaWRlIHRoZSBydW5uaW5nIGxvb3AKICAgICAgICBzZXJ2aWNlID0gU2VydmljZShjZmcs
  >> "!B64TMP!" echo IGJyb3dzZXJfZmFjdG9yeSBvciBsYXVuY2hfaW52aXNpYmxlKQogICAgICAgIGhvbGRlclsic2Vy
  >> "!B64TMP!" echo dmljZSJdID0gc2VydmljZQogICAgICAgIGlmIGNmZy5lYWdlcl9zdGFydDoKICAgICAgICAgICAg
  >> "!B64TMP!" echo dHJ5OgogICAgICAgICAgICAgICAgYXdhaXQgc2VydmljZS5ob2xkZXIuZ2V0KCkKICAgICAgICAg
  >> "!B64TMP!" echo ICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgbG9nLmVycm9yKCJjb3VsZCBub3Qgc3RhcnQgdGhlIGJyb3dzZXI6ICVzIiwgZXhjKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmFpc2UKCiAgICBhc3luYyBkZWYgb25fY2xlYW51cChfYXBwOiB3ZWIuQXBw
  >> "!B64TMP!" echo bGljYXRpb24pIC0+IE5vbmU6CiAgICAgICAgc2VydmljZSA9IGhvbGRlci5nZXQoInNlcnZpY2Ui
  >> "!B64TMP!" echo KQogICAgICAgIGlmIHNlcnZpY2UgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGF3YWl0IHNlcnZp
  >> "!B64TMP!" echo Y2UuaG9sZGVyLmNsb3NlKCkKCiAgICBhc3luYyBkZWYgaGVhbHRoKHJlcXVlc3Q6IHdlYi5SZXF1
  >> "!B64TMP!" echo ZXN0KSAtPiB3ZWIuUmVzcG9uc2U6CiAgICAgICAgcmV0dXJuIGF3YWl0IGhvbGRlclsic2Vydmlj
  >> "!B64TMP!" echo ZSJdLmhlYWx0aChyZXF1ZXN0KQoKICAgIGFzeW5jIGRlZiBzY3JhcGUocmVxdWVzdDogd2ViLlJl
  >> "!B64TMP!" echo cXVlc3QpIC0+IHdlYi5SZXNwb25zZToKICAgICAgICByZXR1cm4gYXdhaXQgaG9sZGVyWyJzZXJ2
  >> "!B64TMP!" echo aWNlIl0uc2NyYXBlKHJlcXVlc3QpCgogICAgYXBwLnJvdXRlci5hZGRfZ2V0KCIvaGVhbHRoIiwg
  >> "!B64TMP!" echo aGVhbHRoKQogICAgYXBwLnJvdXRlci5hZGRfcG9zdCgiL3NjcmFwZSIsIHNjcmFwZSkKICAgIGFw
  >> "!B64TMP!" echo cC5vbl9zdGFydHVwLmFwcGVuZChvbl9zdGFydHVwKQogICAgYXBwLm9uX2NsZWFudXAuYXBwZW5k
  >> "!B64TMP!" echo KG9uX2NsZWFudXApCiAgICBhcHBbInNlcnZpY2VfaG9sZGVyIl0gPSBob2xkZXIKICAgIHJldHVy
  >> "!B64TMP!" echo biBhcHAKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGxvZ2dpbmcuYmFzaWNDb25maWcobGV2ZWw9
  >> "!B64TMP!" echo b3MuZW52aXJvbi5nZXQoIkxPR0dJTkdfTEVWRUwiLCAiSU5GTyIpLnVwcGVyKCksCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIGZvcm1hdD0iJShhc2N0aW1lKXMgJShsZXZlbG5hbWUpcyAlKG1lc3Nh
  >> "!B64TMP!" echo Z2UpcyIsIHN0cmVhbT1zeXMuc3Rkb3V0KQogICAgY2ZnID0gQ29uZmlnKCkKICAgIGlmIGNmZy5w
  >> "!B64TMP!" echo cm94eSBpcyBOb25lOgogICAgICAgIGxvZy53YXJuaW5nKCJubyBQUk9YWV9TRVJWRVIgc2V0OiBy
  >> "!B64TMP!" echo ZXF1ZXN0cyBsZWF2ZSBmcm9tIHRoaXMgbWFjaGluZSdzIG93biBhZGRyZXNzIikKICAgIGxvZy5p
  >> "!B64TMP!" echo bmZvKCJzdGFydGluZyBvbiBwb3J0ICVkIChtYXggJWQgcGFnZXMsIHNzcmYgZ3VhcmQgJXMpIiwK
  >> "!B64TMP!" echo ICAgICAgICAgICAgIGNmZy5wb3J0LCBjZmcubWF4X3BhZ2VzLCAib24iIGlmIGNmZy5zc3JmX2d1
  >> "!B64TMP!" echo YXJkIGVsc2UgIm9mZiIpCiAgICB0cnk6CiAgICAgICAgd2ViLnJ1bl9hcHAoY3JlYXRlX2FwcChj
  >> "!B64TMP!" echo ZmcpLCBob3N0PSIwLjAuMC4wIiwgcG9ydD1jZmcucG9ydCwgcHJpbnQ9Tm9uZSwgYWNjZXNzX2xv
  >> "!B64TMP!" echo Zz1Ob25lKQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAg
  >> "!B64TMP!" echo ICAgIGxvZy5lcnJvcigic3RhcnR1cCBmYWlsZWQ6ICVzIiwgZXhjKQogICAgICAgIHJldHVybiAx
  >> "!B64TMP!" echo CiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdCht
  >> "!B64TMP!" echo YWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\invisible-playwright\server.py"
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
  >> "!B64TMP!" echo bGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleAoKIyAtLS0tIENvbnRhaW5lciBlbmdpbmUgKExp
  >> "!B64TMP!" echo bnV4L21hY09TIGluc3RhbGxlcjogaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gpIC0tLS0KIyAgIHBv
  >> "!B64TMP!" echo ZG1hbiBvciBkb2NrZXIuIFRoZSBpbnN0YWxsZXIgcHJlZmVycyBQb2RtYW4gd2hlbiBpdCBpcyBp
  >> "!B64TMP!" echo bnN0YWxsZWQgKGV2ZW4gaWYKIyAgIERvY2tlciBpcyB0b28pIGFuZCByZWNvcmRzIHdoYXQgaXQg
  >> "!B64TMP!" echo dXNlZCBoZXJlLCBzbyBydW4uc2ggLyBzdG9wLnNoIC8gdXBkYXRlLnNoCiMgICBrZWVwIHVzaW5n
  >> "!B64TMP!" echo IHRoZSBzYW1lIGVuZ2luZS4gU2V0IGl0IHlvdXJzZWxmIHRvIHN3aXRjaCwgdGhlbiBydW4gdXBk
  >> "!B64TMP!" echo YXRlLnNoLgojICAgVG8gZm9yY2UgdGhlIGNob2ljZSBmb3Igb25lIHJ1bjogIExPQ0FMX1NFQVJD
  >> "!B64TMP!" echo SF9FTkdJTkU9ZG9ja2VyIC4vaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKTE9DQUxfU0VBUkNIX0VO
  >> "!B64TMP!" echo R0lORT1wb2RtYW4KCiMgLS0tLSBTZWFyWE5HIGNvbmZpZy1mb2xkZXIgbW91bnQgKGluc3RhbGxl
  >> "!B64TMP!" echo ciBkZWNpZGVzOyBsZWF2ZSBhcyB3cml0dGVuKSAtLS0tCiMgICBTRUFSWE5HX01PVU5UX09QVFM9
  >> "!B64TMP!" echo LHogICAgICAgICAgICBob3N0cyB3aXRoIFNFTGludXggKEZlZG9yYSwgUkhFTCwgLi4uKTogcmVs
  >> "!B64TMP!" echo YWJlbHMKIyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbmZpZy9zZWFyeG5n
  >> "!B64TMP!" echo IHNvIHRoZSBjb250YWluZXIgbWF5IHJlYWQgaXQuCiMgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBXaXRob3V0IGl0IFNlYXJYTkcgcmVzdGFydC1sb29wcyB3aXRoCiMgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiY2hvd24vY3Avc2VkIC4uLiBQZXJtaXNzaW9u
  >> "!B64TMP!" echo IGRlbmllZCIuIEVtcHR5IGVsc2V3aGVyZS4KIyAgIFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQPWZh
  >> "!B64TMP!" echo bHNlICAgIHJvb3RsZXNzIFBvZG1hbjogc3RvcHMgU2VhclhORydzIGVudHJ5cG9pbnQgZnJvbQoj
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcmUtb3duaW5nIHRoZSBmb2xkZXIg
  >> "!B64TMP!" echo KGl0IHdvdWxkIGJlY29tZSBhIHN1Yi1VSUQgeW91CiMgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBjYW5ub3QgZWRpdCkuICJ0cnVlIiAodGhlIGltYWdlIGRlZmF1bHQpIGVsc2V3
  >> "!B64TMP!" echo aGVyZS4KU0VBUlhOR19NT1VOVF9PUFRTPQpTRUFSWE5HX0ZPUkNFX09XTkVSU0hJUD10cnVlCgoj
  >> "!B64TMP!" echo IC0tLS0gRmlyZWNyYXdsIGludGVybmFsIGNyZWRlbnRpYWxzIChpbnN0YWxsZXIgZ2VuZXJhdGVz
  >> "!B64TMP!" echo IHJhbmRvbSB2YWx1ZXMpIC0tLS0KQlVMTF9BVVRIX0tFWT1yZXBsYWNlLXdpdGgtNjQtY2hhci1y
  >> "!B64TMP!" echo YW5kb20taGV4ClBPU1RHUkVTX0RCPWZpcmVjcmF3bApQT1NUR1JFU19VU0VSPWZpcmVjcmF3bApQ
  >> "!B64TMP!" echo T1NUR1JFU19QQVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4ClJBQkJJVE1R
  >> "!B64TMP!" echo X1VTRVI9ZmlyZWNyYXdsClJBQkJJVE1RX1BBU1NXT1JEPXJlcGxhY2Utd2l0aC02NC1jaGFyLXJh
  >> "!B64TMP!" echo bmRvbS1oZXgKCiMgLS0tLSBCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUgZm9yIEZpcmVjcmF3bCAo
  >> "!B64TMP!" echo aW5zdGFsbGVyIFN0ZXAgNCkgLS0tLQojICAgcGxheXdyaWdodCAoZGVmYXVsdCk6IGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZQojICAgYnJvd3Nlcmxlc3M6ICAgICAgICAgIGdo
  >> "!B64TMP!" echo Y3IuaW8vYnJvd3Nlcmxlc3MvY2hyb21pdW0gKHN0ZWFsdGggbW9kZSwgYmV0dGVyCiMgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIGJsb2NrIGF2b2lkYW5jZSBvbiBDbG91ZGZsYXJlLWZyb250ZWQg
  >> "!B64TMP!" echo c2l0ZXMpCiMgICBpbnZpc2libGU6ICAgICAgICAgICAgYSBwYXRjaGVkIEZpcmVmb3ggKGh0dHBz
  >> "!B64TMP!" echo Oi8vZ2l0aHViLmNvbS9vc3MtaW52aXNpYmxlL3BsYXl3cmlnaHQpLAojICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBCVUlMVCBsb2NhbGx5IGZyb20gLi9pbnZpc2libGUtcGxheXdyaWdodCBvbiBm
  >> "!B64TMP!" echo aXJzdCBzdGFydAojICAgICAgICAgICAgICAgICAgICAgICAgICAofjEwIG1pbiwgfjIgR0IpLiBD
  >> "!B64TMP!" echo T01QT1NFX1BST0ZJTEVTPWludmlzaWJsZSBhbmQKIyAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo UExBWVdSSUdIVF9NSUNST1NFUlZJQ0VfVVJMPWh0dHA6Ly9pbnZpc2libGUtcGxheXdyaWdodDoz
  >> "!B64TMP!" echo MDAwL3NjcmFwZQojICAgQ09NUE9TRV9QUk9GSUxFUyBzZWxlY3RzIHdoaWNoIHNlcnZpY2UgYWN0
  >> "!B64TMP!" echo dWFsbHkgc3RhcnRzOyBQTEFZV1JJR0hUX01JQ1JPU0VSVklDRV9VUkwKIyAgIG11c3QgcG9pbnQg
  >> "!B64TMP!" echo YXQgdGhlIHNhbWUgb25lLiBUbyBzd2l0Y2ggbGF0ZXIsIGNoYW5nZSBib3RoIGxpbmVzIGFuZCBy
  >> "!B64TMP!" echo dW4gVXBkYXRlLmJhdC91cGRhdGUuc2guCkNPTVBPU0VfUFJPRklMRVM9cGxheXdyaWdodApQTEFZ
  >> "!B64TMP!" echo V1JJR0hUX01JQ1JPU0VSVklDRV9VUkw9aHR0cDovL3BsYXl3cmlnaHQtc2VydmljZTozMDAwL3Nj
  >> "!B64TMP!" echo cmFwZQoKIyAtLS0tIEJyb3dzZXJsZXNzIHRva2VuIChvbmx5IHVzZWQgaWYgQ09NUE9TRV9QUk9G
  >> "!B64TMP!" echo SUxFUz1icm93c2VybGVzcyBhYm92ZTsgaW5zdGFsbGVyIGdlbmVyYXRlcyBhIHJhbmRvbSB2YWx1
  >> "!B64TMP!" echo ZSByZWdhcmRsZXNzKSAtLS0tCkJST1dTRVJMRVNTX1RPS0VOPXJlcGxhY2Utd2l0aC02NC1jaGFy
  >> "!B64TMP!" echo LXJhbmRvbS1oZXgKCiMgLS0tLSBJbnZpc2libGUgUGxheXdyaWdodCAob25seSB1c2VkIGlmIENP
  >> "!B64TMP!" echo TVBPU0VfUFJPRklMRVM9aW52aXNpYmxlIGFib3ZlOyBhbGwgb3B0aW9uYWwpIC0tLS0KIyBHaXRI
  >> "!B64TMP!" echo dWIgdG9rZW4gKG5vIHNjb3BlcyBuZWVkZWQpIGZvciBCVUlMRElORyB0aGUgaW1hZ2UsIGlmIEdp
  >> "!B64TMP!" echo dEh1YiByYXRlLWxpbWl0cyB0aGUgZW5naW5lIGRvd25sb2FkLgojIEJ1aWxkIGFyZ3VtZW50cyBh
  >> "!B64TMP!" echo cmUgdmlzaWJsZSBpbiBgZG9ja2VyIGhpc3RvcnlgIG9mIHRoZSBsb2NhbCBpbWFnZS4KSU5WSVNJ
  >> "!B64TMP!" echo QkxFX0dJVEhVQl9UT0tFTj0KIyBVcHN0cmVhbSBwcm94eSBmb3IgdGhlIGVuZ2luZSAoZS5nLiBo
  >> "!B64TMP!" echo dHRwOi8vaG9zdDo4MDgwIG9yIHNvY2tzNTovL2hvc3Q6MTA4MCkuIFdpdGggb25lIHNldCwgdGhl
  >> "!B64TMP!" echo CiMgZW5naW5lIGRlcml2ZXMgaXRzIHRpbWV6b25lIGFuZCBsYW5ndWFnZSBmcm9tIHRoZSBwcm94
  >> "!B64TMP!" echo eSdzIGV4aXQgSVAuCklOVklTSUJMRV9QUk9YWV9TRVJWRVI9CklOVklTSUJMRV9QUk9YWV9VU0VS
  >> "!B64TMP!" echo TkFNRT0KSU5WSVNJQkxFX1BST1hZX1BBU1NXT1JEPQojIFBhZ2VzIHJlbmRlcmVkIGF0IG9uY2Ug
  >> "!B64TMP!" echo KGEgZnVsbCBGaXJlZm94IGlzIGhlYXZ5LCBoZW5jZSB0aGUgbG93IGRlZmF1bHQpIGFuZCBhZC90
  >> "!B64TMP!" echo cmFja2VyIGJsb2NraW5nLgojIElOVklTSUJMRV9NQVhfUEFHRVM9NAojIElOVklTSUJMRV9CTE9D
  >> "!B64TMP!" echo S19BRFM9ZmFsc2UKCiMgLS0tLSBMb2dnaW5nIC0tLS0KTE9HR0lOR19MRVZFTD1pbmZvCgojID09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09CiMgIE9wdGlvbmFsOiBjb25uZWN0IGEgbG9jYWwgKG9yIHJlbW90
  >> "!B64TMP!" echo ZSkgTExNIHNvIEZpcmVjcmF3bCdzIC92MS9leHRyYWN0IGFuZAojICAic3VtbWFyeSIgZmVhdHVy
  >> "!B64TMP!" echo ZXMgd29yay4gQW55IE9wZW5BSS1jb21wYXRpYmxlIGVuZHBvaW50IHdpbGwgZG8uCiMgIExNIFN0
  >> "!B64TMP!" echo dWRpbyBpcyB0aGUgcmVjb21tZW5kZWQgZGVmYXVsdCAocHJpb3JpdHkgb3ZlciBPbGxhbWEpLgoj
  >> "!B64TMP!" echo ID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09CgojIC0tLS0gT3B0aW9uIEEgKFJFQ09NTUVOREVEKTogTE0g
  >> "!B64TMP!" echo U3R1ZGlvIC8gYW55IE9wZW5BSS1jb21wYXRpYmxlIGxvY2FsIHNlcnZlciAtLS0tCiMgICAxLiBJ
  >> "!B64TMP!" echo biBMTSBTdHVkaW86IERldmVsb3BlciB0YWIgPiAiU3RhcnQgU2VydmVyIiBvbiBwb3J0IDEyMzQs
  >> "!B64TMP!" echo IGxvYWQgYSBtb2RlbCwKIyAgICAgIGFuZCBFTkFCTEUgIlNlcnZlIG9uIGxvY2FsIG5ldHdvcmsi
  >> "!B64TMP!" echo IHNvIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyIGNhbiByZWFjaCBpdC4KIyAgIDIuIE5PVEU6IE9Q
  >> "!B64TMP!" echo RU5BSV9CQVNFX1VSTCBpcyByZWFkIElOU0lERSB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lci4gRnJv
  >> "!B64TMP!" echo bSB0aGVyZSwKIyAgICAgIHlvdXIgaG9zdCBtYWNoaW5lIGlzICJob3N0LmRvY2tlci5pbnRlcm5h
  >> "!B64TMP!" echo bCIsIE5PVCAibG9jYWxob3N0Ii4gU28gdXNlOgojIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8vaG9z
  >> "!B64TMP!" echo dC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQojIE9QRU5BSV9BUElfS0VZPWxtLXN0dWRpbyAgICAg
  >> "!B64TMP!" echo ICAgICAjIGFueSBub24tZW1wdHkgc3RyaW5nOyBMTSBTdHVkaW8gaWdub3JlcyBpdAojIE1PREVM
  >> "!B64TMP!" echo X05BTUU9bG9jYWwtbW9kZWwgICAgICAgICAgICAjIHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4gTE0g
  >> "!B64TMP!" echo U3R1ZGlvCgojIC0tLS0gT3B0aW9uIEI6IHJlbW90ZSBPcGVuQUktY29tcGF0aWJsZSBzZXJ2ZXIg
  >> "!B64TMP!" echo KHZMTE0sIGxsYW1hLmNwcCBzZXJ2ZXIsIGV0Yy4pIC0tLS0KIyBPUEVOQUlfQkFTRV9VUkw9aHR0
  >> "!B64TMP!" echo cDovLzE5Mi4xNjguMS41MDo4MDAwL3YxCiMgT1BFTkFJX0FQSV9LRVk9cGxhY2Vob2xkZXIKIyBN
  >> "!B64TMP!" echo T0RFTF9OQU1FPXlvdXItbW9kZWwtaWQKCiMgLS0tLSBPcHRpb24gQyAoZmFsbGJhY2spOiBPbGxh
  >> "!B64TMP!" echo bWEgb24gdGhlIHNhbWUgaG9zdCBhcyBEb2NrZXIgLS0tLQojIE9MTEFNQV9CQVNFX1VSTD1odHRw
  >> "!B64TMP!" echo Oi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTE0MzQvYXBpCiMgTU9ERUxfTkFNRT1xd2VuMi41Ojdi
  >> "!B64TMP!" echo CiMgTU9ERUxfRU1CRURESU5HX05BTUU9bm9taWMtZW1iZWQtdGV4dAoKIyA9PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PQojICBPcHRpb25hbDogRmlyZWNyYXdsIGFjY291bnQgKHBhaWQgY2xvdWQgc2Vydmlj
  >> "!B64TMP!" echo ZSkgZm9yIHRoZSBhY2NvdW50LW9ubHkKIyAgbG9jYWwtd2ViLXNlYXJjaCB0b29scyAocmVzZWFy
  >> "!B64TMP!" echo Y2ggYWdlbnQsIGludGVyYWN0LCBwYXJzZSwgbW9uaXRvcnMsIHBhcGVyCiMgIHJlc2VhcmNoLCBH
  >> "!B64TMP!" echo aXRIdWIvZGV2ZWxvcGVyIHNlYXJjaCkuCiMKIyAgVGhlIGluc3RhbGxlciBvZmZlcnMgdG8gd3Jp
  >> "!B64TMP!" echo dGUgdGhlc2UgZm9yIHlvdSAoYW5zd2VyICd5JyBhdCB0aGUKIyAgIkFkZCBhIEZpcmVjcmF3bCBh
  >> "!B64TMP!" echo Y2NvdW50PyIgcXVlc3Rpb24sIHRoZW4gcGFzdGUgeW91ciBrZXkpLiBXaXRob3V0IHRoZW0KIyAg
  >> "!B64TMP!" echo dGhlIGluc3RhbGxlciBza2lwcyB0aG9zZSB0b29scyBhbmQgaW5zdGFsbHMgb25seSB0aGUgZnJl
  >> "!B64TMP!" echo ZSBsb2NhbCBvbmVzLgojICBUaGUgbG9jYWwtd2ViLXNlYXJjaCBzY3JpcHRzIHJlYWQgdGhlc2Ug
  >> "!B64TMP!" echo a2V5cyBmcm9tIFRISVMgZmlsZTsKIyAgRklSRUNSQVdMX0FQSV9VUkwgLyBGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSBlbnZpcm9ubWVudCB2YXJpYWJsZXMgb3ZlcnJpZGUgdGhlbS4KIyAgKFRoZSBEb2NrZXIg
  >> "!B64TMP!" echo Y29udGFpbmVycyBpZ25vcmUgdGhlc2Uga2V5cyBlbnRpcmVseS4pCiMgPT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT0KIyBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jhd2wuZGV2CiMgRklS
  >> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVk9ZmMteW91ci1rZXktaGVyZQo=
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
  >> "!B64TMP!" echo dGVwIDQgaXMgYW5zd2VyZWQgKioyKiogKG9yICoqeSoqKS4gfAp8ICoqaW52aXNpYmxlLXBsYXl3
  >> "!B64TMP!" echo cmlnaHQqKiAqKGFsdGVybmF0ZSBlbmdpbmUpKiB8IGJ1aWx0IGxvY2FsbHkgZnJvbSBbYGludmlz
  >> "!B64TMP!" echo aWJsZS1wbGF5d3JpZ2h0L2BdKGludmlzaWJsZS1wbGF5d3JpZ2h0Lykg4oCUIG5vIHB1Ymxpc2hl
  >> "!B64TMP!" echo ZCBpbWFnZSB8IEEgcGF0Y2hlZCAqKkZpcmVmb3gqKiAoW29zcy1pbnZpc2libGUvcGxheXdyaWdo
  >> "!B64TMP!" echo dF0oaHR0cHM6Ly9naXRodWIuY29tL29zcy1pbnZpc2libGUvcGxheXdyaWdodCkpIHdob3NlIGZp
  >> "!B64TMP!" echo bmdlcnByaW50IChuYXZpZ2F0b3IsIHNjcmVlbiwgV2ViR0wsIGZvbnRzLCB0aW1lem9uZSwg4oCm
  >> "!B64TMP!" echo KSBpcyBnZW5lcmF0ZWQgaW5zaWRlIHRoZSBlbmdpbmUgcmF0aGVyIHRoYW4gaW5qZWN0ZWQgdGhy
  >> "!B64TMP!" echo b3VnaCBKYXZhU2NyaXB0LCBiZWhpbmQgdGhlIHNhbWUgYFBPU1QgL3NjcmFwZWAgKyBgR0VUIC9o
  >> "!B64TMP!" echo ZWFsdGhgIHJvdXRlcyBhcyBGaXJlY3Jhd2wncyBvd24gc2VydmljZS4gU3RhcnRzIGluc3RlYWQg
  >> "!B64TMP!" echo b2YgUGxheXdyaWdodCB3aGVuIFN0ZXAgNCBpcyBhbnN3ZXJlZCAqKjMqKi4gKipUaGUgZmlyc3Qg
  >> "!B64TMP!" echo c3RhcnQgYnVpbGRzIHRoZSBpbWFnZTogfjEwIG1pbnV0ZXMsIH4yIEdCKiosIGFuZCBuZWVkcyBH
  >> "!B64TMP!" echo aXRIdWIsIFB5UEkgYW5kIE1pY3Jvc29mdCdzIHJlZ2lzdHJ5LiB8CnwgKipyZWRpcyoqIHwgYHJl
  >> "!B64TMP!" echo ZGlzOmFscGluZWAgfCBGaXJlY3Jhd2wgam9iIHF1ZXVlLiB8CnwgKipyYWJiaXRtcSoqIHwgYHJh
  >> "!B64TMP!" echo YmJpdG1xOjMtbWFuYWdlbWVudGAgfCBGaXJlY3Jhd2wgbWVzc2FnZSBicm9rZXIuIHwKfCAqKm51
  >> "!B64TMP!" echo cS1wb3N0Z3JlcyoqIHwgYGdoY3IuaW8vZmlyZWNyYXdsL251cS1wb3N0Z3JlczpsYXRlc3RgIHwg
  >> "!B64TMP!" echo RmlyZWNyYXdsIGpvYi1zdGF0ZSBEQiAocGdfY3JvbiBlbmFibGVkKS4gfAoKT24gdG9wIG9mIHRo
  >> "!B64TMP!" echo ZSBjb250YWluZXJzLCB0aGUgaW5zdGFsbGVyIGJ1bmRsZXMgKipsb2NhbC13ZWItc2VhcmNoKiog
  >> "!B64TMP!" echo 4oCUIGEgc2tpbGwgZm9yCmFnZW50cyB0aGF0IGxvYWQgc2tpbGxzIGZyb20gYH4vLmFnZW50cy9z
  >> "!B64TMP!" echo a2lsbHMvYCAoYEM6XFVzZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xgCm9uIFdpbmRvd3MpLiBJdCBn
  >> "!B64TMP!" echo aXZlcyB0aGUgYWdlbnQgYSBjb21wbGV0ZSB3ZWItcmVzZWFyY2ggd29ya2Zsb3c6IHNlYXJjaCB2
  >> "!B64TMP!" echo aWEKU2VhclhORywgcmVhZCBwYWdlcyB2aWEgRmlyZWNyYXdsLCBhbmQgZXZlbiBzdGFydCB0aGUg
  >> "!B64TMP!" echo RG9ja2VyIHN0YWNrCmF1dG9tYXRpY2FsbHkgd2hlbiBpdCdzIGRvd24uIFNlZSBbc2VjdGlvbiBB
  >> "!B64TMP!" echo XSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2VhcmNoLXNraWxsLXJlY29tbWVuZGVkKS4KCk9u
  >> "!B64TMP!" echo bHkgKip0d28gaG9zdCBwb3J0cyoqIGFyZSBwdWJsaXNoZWQgKGA5OTkwYCBhbmQgYDk5OTFgIGJ5
  >> "!B64TMP!" echo IGRlZmF1bHQpLiBFdmVyeXRoaW5nCmVsc2Ugc3RheXMgb24gdGhlIHByaXZhdGUgYGxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaC1uZXRgIGJyaWRnZSBuZXR3b3JrLiBGaXJlY3Jhd2wncwpgL3YxL3NlYXJjaGAgZW5kcG9p
  >> "!B64TMP!" echo bnQgaXMgYXV0b21hdGljYWxseSB3aXJlZCB0byBTZWFyWE5HIGludGVybmFsbHksIHNvIGEgc2lu
  >> "!B64TMP!" echo Z2xlCkZpcmVjcmF3bCBjYWxsIGNhbiBib3RoIHNlYXJjaCAqYW5kKiBmZXRjaCBmdWxsIHBhZ2Ug
  >> "!B64TMP!" echo Y29udGVudC4KCi0tLQoKIyMgUmVxdWlyZW1lbnRzCgotICoqRG9ja2VyKiogd2l0aCB0aGUgKipD
  >> "!B64TMP!" echo b21wb3NlIHYyIHBsdWdpbioqIChgZG9ja2VyIGNvbXBvc2VgKSDigJQgKipvciBQb2RtYW4qKiAo
  >> "!B64TMP!" echo TGludXgvbWFjT1MpIHdpdGggYSBjb21wb3NlIHByb3ZpZGVyLgogIC0gV2luZG93czogW0RvY2tl
  >> "!B64TMP!" echo ciBEZXNrdG9wXShodHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9w
  >> "!B64TMP!" echo LykKICAtIG1hY09TOiBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJv
  >> "!B64TMP!" echo ZHVjdHMvZG9ja2VyLWRlc2t0b3AvKSwgb3IgUG9kbWFuIChgYnJldyBpbnN0YWxsIHBvZG1hbiBk
  >> "!B64TMP!" echo b2NrZXItY29tcG9zZWAsIHRoZW4gYHBvZG1hbiBtYWNoaW5lIGluaXQgJiYgcG9kbWFuIG1hY2hp
  >> "!B64TMP!" echo bmUgc3RhcnRgKQogIC0gTGludXgsIERvY2tlcjogW0RvY2tlciBFbmdpbmVdKGh0dHBzOi8vZG9j
  >> "!B64TMP!" echo cy5kb2NrZXIuY29tL2VuZ2luZS9pbnN0YWxsLykgKyB0aGUgYGRvY2tlci1jb21wb3NlLXBsdWdp
  >> "!B64TMP!" echo bmAgcGFja2FnZS4gQWRkIHlvdXIgdXNlciB0byB0aGUgYGRvY2tlcmAgZ3JvdXAgc28geW91IGRv
  >> "!B64TMP!" echo bid0IG5lZWQgYHN1ZG9gLgogIC0gTGludXgsIFBvZG1hbiAoRmVkb3JhIC8gUkhFTCAvIERlYmlh
  >> "!B64TMP!" echo biAvIFVidW50dSk6IGBzdWRvIGRuZiBpbnN0YWxsIHBvZG1hbiBkb2NrZXItY29tcG9zZWAgKERl
  >> "!B64TMP!" echo Ymlhbi9VYnVudHU6IGBzdWRvIGFwdCBpbnN0YWxsIHBvZG1hbiBkb2NrZXItY29tcG9zZS12MmAp
  >> "!B64TMP!" echo LiBCb3RoIGNvbXBvc2UgcHJvdmlkZXJzIHdvcmsg4oCUIENvbXBvc2UgdjIgKGBkb2NrZXItY29t
  >> "!B64TMP!" echo cG9zZWApIGFuZCBgcG9kbWFuLWNvbXBvc2VgICh0ZXN0ZWQgd2l0aCAxLjYuMCkuIFJvb3RsZXNz
  >> "!B64TMP!" echo IGlzIGZpbmUuCiAgLSAqKklmIGJvdGggUG9kbWFuIGFuZCBEb2NrZXIgYXJlIGluc3RhbGxlZCwg
  >> "!B64TMP!" echo dGhlIExpbnV4L21hY09TIGluc3RhbGxlciB1c2VzIFBvZG1hbi4qKiBGb3JjZSB0aGUgb3RoZXIg
  >> "!B64TMP!" echo b25lIHdpdGggYExPQ0FMX1NFQVJDSF9FTkdJTkU9ZG9ja2VyIC4vaW5zdGFsbC1sb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2guc2hgLiBUaGUgaW5zdGFsbGVyIHJlY29yZHMgaXRzIGNob2ljZSBpbiBgLmVudmAgKGBMT0NB
  >> "!B64TMP!" echo TF9TRUFSQ0hfRU5HSU5FYCkgc28gYHJ1bi5zaGAgLyBgdXBkYXRlLnNoYCBrZWVwIHVzaW5nIHRo
  >> "!B64TMP!" echo ZSBzYW1lIGVuZ2luZS4gVGhlIFdpbmRvd3MgaW5zdGFsbGVyIHVzZXMgRG9ja2VyIERlc2t0b3Au
  >> "!B64TMP!" echo Ci0gKip+NSBHQiBmcmVlIGRpc2sqKiBmb3IgaW1hZ2VzIGFuZCBkYXRhLgotICoqOCBHQiBSQU0g
  >> "!B64TMP!" echo LyA0IENQVSBjb3JlcyoqIHJlY29tbWVuZGVkIChGaXJlY3Jhd2wgcGx1cyBpdHMgYnJvd3NlciBl
  >> "!B64TMP!" echo bmdpbmUg4oCUIFBsYXl3cmlnaHQsIEJyb3dzZXJsZXNzIG9yIEludmlzaWJsZSBQbGF5d3JpZ2h0
  >> "!B64TMP!" echo IOKAlCBpcyB0aGUgaGVhdnkgcGFydDsgcmVkdWNlIHJlc291cmNlIGxpbWl0cyBpbiBgZG9ja2Vy
  >> "!B64TMP!" echo LWNvbXBvc2UueW1sYCBmb3Igc21hbGxlciBob3N0cykuCi0gKipQeXRob24gMy44KyoqIGZvciB0
  >> "!B64TMP!" echo aGUgYnVuZGxlZCBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHNjcmlwdHMgKG9wdGlvbmFsIGJ1dCBy
  >> "!B64TMP!" echo ZWNvbW1lbmRlZCDigJQgaXQncyB0aGUgZWFzaWVzdCB3YXkgdG8gdXNlIHRoZSBzdGFjaykuCi0g
  >> "!B64TMP!" echo KihPcHRpb25hbCwgZm9yIEZpcmVjcmF3bCBBSSBmZWF0dXJlcykqICoqTE0gU3R1ZGlvKiogb3Ig
  >> "!B64TMP!" echo YW55IE9wZW5BSS1jb21wYXRpYmxlIGVuZHBvaW50LCBsb2NhbCBvciByZW1vdGUg4oCUIHNlZSBb
  >> "!B64TMP!" echo c2VjdGlvbiBEXSgjZC1jb25uZWN0LWFuLWxsbS1sbS1zdHVkaW8tZXRjKS4KLSAqKE9wdGlvbmFs
  >> "!B64TMP!" echo LCBmb3IgTUNQKSogKipOb2RlLmpzIDE4KyoqIHNvIGBucHggZmlyZWNyYXdsLW1jcGAgd29ya3Mu
  >> "!B64TMP!" echo CgpWZXJpZnkgeW91ciBlbmdpbmUgaXMgcmVhZHk6CgpgYGBiYXNoCmRvY2tlciBpbmZvICAgICAg
  >> "!B64TMP!" echo ICAgICAgIyBlbmdpbmUgaXMgcnVubmluZyAgICAgICAgKFBvZG1hbjogcG9kbWFuIGluZm8pCmRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIHZlcnNpb24gIyB2MiBpcyBpbnN0YWxsZWQgICAgICAgICAoUG9kbWFuOiBw
  >> "!B64TMP!" echo b2RtYW4gY29tcG9zZSB2ZXJzaW9uKQpgYGAKCi0tLQoKIyMgUXVpY2sgc3RhcnQgKG9uZS1jbGlj
  >> "!B64TMP!" echo ayBpbnN0YWxsKQoKPiAqKlRoZSBpbnN0YWxsZXIgaXMgc2VsZi1jb250YWluZWQuKiogRXZlcnkg
  >> "!B64TMP!" echo ZmlsZSBpdCBuZWVkcyAoYGRvY2tlci1jb21wb3NlLnltbGAsIGBjb25maWcvc2VhcnhuZy9zZXR0
  >> "!B64TMP!" echo aW5ncy55bWxgLCBgLmVudi5leGFtcGxlYCwgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYi1zZWFyY2hg
  >> "!B64TMP!" echo IHNraWxsLCBhbGwgdGhlIHJ1bi9zdG9wL3VwZGF0ZS91bmluc3RhbGwgc2NyaXB0cywgdGhpcyBS
  >> "!B64TMP!" echo RUFETUUsIGFuZCBldmVuIHRoZSAqb3RoZXIqIHBsYXRmb3JtJ3MgaW5zdGFsbGVyKSBpcyBlbWJl
  >> "!B64TMP!" echo ZGRlZCBpbnNpZGUgaXQuIERvd25sb2FkICoqYGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdGAqKiAo
  >> "!B64TMP!" echo V2luZG93cykgb3IgKipgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2hgKiogKExpbnV4L21hY09TKSBv
  >> "!B64TMP!" echo biBpdHMgb3duIGFuZCB0aGUgaW5zdGFsbGVyIHdpbGwgcHJvZHVjZSBhIGNvbXBsZXRlLCB3b3Jr
  >> "!B64TMP!" echo aW5nIGZvbGRlciBhbmQgYSBydW4gdGhlIHN0YWNrLgoKUnVuICoqb25lKiogaW5zdGFsbGVyIGZv
  >> "!B64TMP!" echo ciB5b3VyIHBsYXRmb3JtLiBGaXJzdCBpdCBhc2tzIHdoaWNoIHNldHVwIHlvdSB3YW50IOKAlAp0
  >> "!B64TMP!" echo eXBlICoqMSoqLCAqKjIqKiBvciAqKjMqKiAob3IgcHJlc3MgKipFbnRlcioqIGZvciAqKjEqKik6
  >> "!B64TMP!" echo Cgp8IENob2ljZSAgICAgICAgICB8IFNldHVwICAgICAgICAgICAgICAgICAgICB8IFdoYXQgaXQg
  >> "!B64TMP!" echo ZG9lcyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgIHwKfCAtLS0tLS0tLS0tLS0tLS0gfCAtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0gfCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSB8CnwgKiox
  >> "!B64TMP!" echo KiogKGRlZmF1bHQpIHwgTWluaW1hbCBpbnN0YWxsYXRpb24gICAgIHwgRGVmYXVsdCBmb2xkZXIs
  >> "!B64TMP!" echo IFNlYXJYTkcgb24gYDk5OTBgLCBGaXJlY3Jhd2wgb24gYDk5OTFgLCB0aGUgUGxheXdyaWdodCBi
  >> "!B64TMP!" echo cm93c2VyIGVuZ2luZSwgbm8gcXVlc3Rpb25zIGF0IGFsbCwgbm8gTExNLCBubyBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo YWNjb3VudDogYSB0cnVlIG9uZS1jbGljayBpbnN0YWxsLiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgfAp8ICoqMioqICAgICAgICAgICB8IE1pbmltYWwgKyBMTE0gZXh0
  >> "!B64TMP!" echo cmFjdGlvbiB8IFRoZSBzYW1lIGRlZmF1bHRzLCBwbHVzIHRocmVlIHF1ZXN0aW9ucyB0byBjb25u
  >> "!B64TMP!" echo ZWN0IGFuIExMTSAoYmFzZSBVUkwsIEFQSSBrZXksIG1vZGVsKS4gICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHwKfCAqKjMqKiAgICAg
  >> "!B64TMP!" echo ICAgICAgfCBGdWxsIGluc3RhbGxhdGlvbiAgICAgICAgfCBUaGUgZnVsbCBzaXgtc3RlcCBzZXR1
  >> "!B64TMP!" echo cCDigJQgaW5zdGFsbCBmb2xkZXIsIFNlYXJYTkcgcG9ydCwgRmlyZWNyYXdsIHBvcnQsIGEgYnJv
  >> "!B64TMP!" echo d3NlciByZW5kZXJpbmcgZW5naW5lIChQbGF5d3JpZ2h0LCBCcm93c2VybGVzcyBvciBJbnZpc2li
  >> "!B64TMP!" echo bGUgUGxheXdyaWdodCksIChvcHRpb25hbGx5KSBhbiBMTE0sIGFuZCAob3B0aW9uYWxseSkgYSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgYWNjb3VudCDigJQgd2l0aCB0aGUgc2FtZSBkZWZhdWx0cyBvZmZlcmVkIGF0IGVh
  >> "!B64TMP!" echo Y2ggc3RlcCBpZiB5b3UganVzdCBwcmVzcyAqKkVudGVyKiouIHwKCkVpdGhlciB3YXkgaXQgdGhl
  >> "!B64TMP!" echo biBnZW5lcmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMg
  >> "!B64TMP!" echo eW91ciBgLmVudmAsICoqaW5zdGFsbHMgdGhlCmxvY2FsLXdlYi1zZWFyY2ggc2tpbGwqKiwgcHVs
  >> "!B64TMP!" echo bHMgdGhlIGltYWdlcywgYW5kIHN0YXJ0cyB0aGUgc3RhY2suCgo+ICoqRW5naW5lIGlzbid0IHJ1
  >> "!B64TMP!" echo bm5pbmc/KiogTm8gcHJvYmxlbSDigJQgdGhlIGluc3RhbGxlciBzdGFydHMgaXQgZm9yIHlvdTog
  >> "!B64TMP!" echo aXQKPiBsYXVuY2hlcyBEb2NrZXIgRGVza3RvcCAoV2luZG93cy9tYWNPUyksIHRoZSBEb2NrZXIg
  >> "!B64TMP!" echo c2VydmljZQo+IChgc3lzdGVtY3RsYC9gc2VydmljZWAsIExpbnV4KSBvciB0aGUgUG9kbWFuIG1h
  >> "!B64TMP!" echo Y2hpbmUgKG1hY09TKSBhbmQgd2FpdHMgdXAgdG8KPiA1IG1pbnV0ZXMgZm9yIHRoZSBlbmdpbmUg
  >> "!B64TMP!" echo d2hpbGUgeW91IGFuc3dlciB0aGUgcHJvbXB0cy4gKE92ZXJyaWRlIHRoZSB3YWl0IHdpdGgKPiB0
  >> "!B64TMP!" echo aGUgYExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVGAgZW52IHZhciwgaW4gc2Vjb25kcy4pIFJv
  >> "!B64TMP!" echo b3RsZXNzIFBvZG1hbiBvbgo+IExpbnV4IGhhcyBubyBkYWVtb24gdG8gc3RhcnQuCj4KPiBUaGUg
  >> "!B64TMP!" echo c2FtZSBnb2VzIGZvciAqKmBydW4uc2hgIC8gYFJ1bi5iYXRgKiosICoqYHVwZGF0ZS5zaGAgLyBg
  >> "!B64TMP!" echo VXBkYXRlLmJhdGAqKiBhbmQKPiAqKmB1bmluc3RhbGwuc2hgIC8gYFVuaW5zdGFsbC5iYXRgKio6
  >> "!B64TMP!" echo IGlmIHRoZSBlbmdpbmUgaXMgZG93biB0aGV5IGxhdW5jaCBpdCBhbmQgd2FpdAo+IChzYW1lIGBM
  >> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVRgKSBpbnN0ZWFkIG9mIGFza2luZyB5b3UgdG8gc3Rh
  >> "!B64TMP!" echo cnQgaXQuIFRoZQo+IHVuaW5zdGFsbGVyIGFza3MgaXRzIGNvbmZpcm1hdGlvbiBxdWVzdGlvbiBm
  >> "!B64TMP!" echo aXJzdCBhbmQgb25seSB0aGVuIHN0YXJ0cyB0aGUgZW5naW5lOwo+IGlmIHRoZSBlbmdpbmUgY2Fu
  >> "!B64TMP!" echo bm90IGJlIHN0YXJ0ZWQgaXQgcmVtb3ZlcyBub3RoaW5nLiBgc3RvcGAgZG9lcyBub3Qgc3RhcnQg
  >> "!B64TMP!" echo YW55dGhpbmcKPiAoYSBzdG9wcGVkIGVuZ2luZSBoYXMgbm8gY29udGFpbmVycyB0byBzdG9wKS4K
  >> "!B64TMP!" echo CiMjIyBXaW5kb3dzCgoxLiBJbnN0YWxsIFtEb2NrZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9j
  >> "!B64TMP!" echo a2VyLmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3RvcC8pIOKAlCBubyBuZWVkIHRvIG9wZW4gaXQg
  >> "!B64TMP!" echo Zmlyc3Q7IHRoZSBpbnN0YWxsZXIgbGF1bmNoZXMgaXQgYXV0b21hdGljYWxseS4KMi4gRG91Ymxl
  >> "!B64TMP!" echo LWNsaWNrICoqYGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdGAqKiAob3IgcnVuIGl0IGZyb20gYSB0
  >> "!B64TMP!" echo ZXJtaW5hbCkuCgpgYGAKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09CiAgU2V0dXAgdHlwZQo9PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KICAxKSBNaW5pbWFsIGluc3RhbGxh
  >> "!B64TMP!" echo dGlvbgogIDIpIE1pbmltYWwgKyBMTE0gZXh0cmFjdGlvbgogIDMpIEZ1bGwgaW5zdGFsbGF0aW9u
  >> "!B64TMP!" echo CiAgRGVmYXVsdHM6IEM6XFVzZXJzXFlvdVxsb2NhbC1zZWFyY2gsIFNlYXJYTkcgOTk5MCwgRmly
  >> "!B64TMP!" echo ZWNyYXdsIDk5OTEsCiAgUGxheXdyaWdodCBlbmdpbmUsIG5vIEZpcmVjcmF3bCBhY2NvdW50Lgog
  >> "!B64TMP!" echo IENob29zZSAxLCAyIG9yIDMgW0VudGVyID0gMV06CmBgYAoKKioxKiogc2tpcHMgZXZlcnkgcXVl
  >> "!B64TMP!" echo c3Rpb24gYW5kIGluc3RhbGxzLiAqKjIqKiBhc2tzIG9ubHkgZm9yIHRoZSBMTE0gKGJhc2UgVVJM
  >> "!B64TMP!" echo LApBUEkga2V5LCBtb2RlbCksIHRoZW4gaW5zdGFsbHMuICoqMyoqIHdhbGtzIHRocm91Z2ggdGhl
  >> "!B64TMP!" echo IGZ1bGwgc2V0dXA6CgpgYGAKLS0tIFN0ZXAgMSBvZiA2OiBJbnN0YWxsIGxvY2F0aW9uIC0tLS0t
  >> "!B64TMP!" echo LS0tLS0KICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRlciBmb3IgZGVmYXVsdF06ICAgICAgICAg
  >> "!B64TMP!" echo ICAgIyBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoCi0tLSBTdGVwIDIgb2YgNjogU2VhclhORyBw
  >> "!B64TMP!" echo b3J0IChkZWZhdWx0IDk5OTApIC0tLS0tLQogIFBvcnQgZm9yIFNlYXJYTkcgW3ByZXNzIEVudGVy
  >> "!B64TMP!" echo IGZvciA5OTkwXTogOTk5MAotLS0gU3RlcCAzIG9mIDY6IEZpcmVjcmF3bCBwb3J0IChkZWZhdWx0
  >> "!B64TMP!" echo IDk5OTEpIC0tLS0KICBQb3J0IGZvciBGaXJlY3Jhd2wgW3ByZXNzIEVudGVyIGZvciA5OTkxXTog
  >> "!B64TMP!" echo OTk5MQotLS0gU3RlcCA0IG9mIDY6IEJyb3dzZXIgcmVuZGVyaW5nIGVuZ2luZSAoZGVmYXVsdDog
  >> "!B64TMP!" echo UGxheXdyaWdodCkgLS0tCiAgRW5naW5lIFsxPVBsYXl3cmlnaHQsIDI9QnJvd3Nlcmxlc3MsIDM9
  >> "!B64TMP!" echo SW52aXNpYmxlOyBFbnRlcj0xXTogICAjIGRlZmF1bHQ6IFBsYXl3cmlnaHQsIHNlZSBiZWxvdwot
  >> "!B64TMP!" echo LS0gU3RlcCA1IG9mIDY6IExMTSAob3B0aW9uYWwpIC0tLS0tLS0tLS0tLS0tLS0tLS0KICBDb25u
  >> "!B64TMP!" echo ZWN0IExMTSBub3c/IFt5L05dOiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAjIGRlZmF1
  >> "!B64TMP!" echo bHQ6IG5vLCBzZWUgc2VjdGlvbiBECi0tLSBTdGVwIDYgb2YgNjogRmlyZWNyYXdsIGFjY291bnQg
  >> "!B64TMP!" echo KG9wdGlvbmFsKSAtLS0tLQogIEFkZCBhIEZpcmVjcmF3bCBhY2NvdW50IG5vdz8gW3kvTl06IG4g
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICMgZGVmYXVsdDogc2tpcCwgc2VlIGJlbG93CmBgYAoKIyMjIExpbnV4
  >> "!B64TMP!" echo ICYgbWFjT1MKCmBgYGJhc2gKY2htb2QgK3ggaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKLi9pbnN0
  >> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5zaApgYGAKClRoZSBwcm9tcHRzIGFyZSB0aGUgc2FtZS4gRGVmYXVs
  >> "!B64TMP!" echo dHM6IGluc3RhbGwgdG8gYH4vbG9jYWwtc2VhcmNoYCwgU2VhclhORyBvbgpgOTk5MGAsIEZpcmVj
  >> "!B64TMP!" echo cmF3bCBvbiBgOTk5MWAsIFBsYXl3cmlnaHQgYXMgdGhlIGJyb3dzZXIgZW5naW5lLCBubyBGaXJl
  >> "!B64TMP!" echo Y3Jhd2wKYWNjb3VudCAoYW5kIGFuIExMTSBvbmx5IGlmIHlvdSBwaWNrIHNldHVwICoqMioqIG9y
  >> "!B64TMP!" echo IGFuc3dlciAqKnkqKiBpbiBzZXR1cCAqKjMqKikuIEEgc3RvcHBlZCBlbmdpbmUgaXMgc3RhcnRl
  >> "!B64TMP!" echo ZCBhdXRvbWF0aWNhbGx5CihEb2NrZXIgRGVza3RvcCAvIFBvZG1hbiBtYWNoaW5lIG9uIG1hY09T
  >> "!B64TMP!" echo LCBgc3lzdGVtY3RsYC9gc2VydmljZWAgb24gTGludXgpLgoKVGhlIGluc3RhbGxlciAqKnByZWZl
  >> "!B64TMP!" echo cnMgUG9kbWFuKiogd2hlbiBpdCBpcyBpbnN0YWxsZWQgKGV2ZW4gaWYgRG9ja2VyIGlzIHRvbyks
  >> "!B64TMP!" echo CnB1bGxzIGV2ZXJ5IGltYWdlIG9ubHkgZnJvbSAqKkRvY2tlciBIdWIgKGBkb2NrZXIuaW9gKSBh
  >> "!B64TMP!" echo bmQgR0hDUiAoYGdoY3IuaW9gKSoqIOKAlAp0aGUgY29tcG9zZSBmaWxlIHVzZXMgZnVsbHktcXVh
  >> "!B64TMP!" echo bGlmaWVkIG5hbWVzLCBzbyBQb2RtYW4gbmV2ZXIgYXNrcyB3aGljaCByZWdpc3RyeQp0byB1c2Ug
  >> "!B64TMP!" echo 4oCUIGFuZCwgb25jZSB0aGUgc3RhY2sgaXMgdXAsICoqY2hlY2tzIHRoYXQgU2VhclhORyByZWFs
  >> "!B64TMP!" echo bHkgYW5zd2VycyoqLApwcmludGluZyBpdHMgY29udGFpbmVyIHN0YXRlIGFuZCBsYXN0IGxvZyBs
  >> "!B64TMP!" echo aW5lcyB3aGVuIGl0IGRvZXMgbm90LiBPbgpTRUxpbnV4IGhvc3RzIChGZWRvcmEsIFJIRUwsIOKA
  >> "!B64TMP!" echo pikgYW5kIHdpdGggcm9vdGxlc3MgUG9kbWFuIGl0IGFsc28gc2V0cyBob3cKU2VhclhORydzIGNv
  >> "!B64TMP!" echo bmZpZyBmb2xkZXIgaXMgbW91bnRlZCAoc2VlIGBTRUFSWE5HX01PVU5UX09QVFNgIC8KYFNFQVJY
  >> "!B64TMP!" echo TkdfRk9SQ0VfT1dORVJTSElQYCBiZWxvdykuCgo+ICoqT25lLWNsaWNrIGluc3RhbGwuKiogVGhl
  >> "!B64TMP!" echo IHZlcnkgZmlyc3QgcXVlc3Rpb24gaXMgdGhlIHNldHVwIHR5cGUuIENob2ljZQo+ICoqMSoqICh0
  >> "!B64TMP!" echo aGUgRW50ZXIgZGVmYXVsdCkgc2tpcHMgZXZlcnkgcXVlc3Rpb24gYW5kIGluc3RhbGxzIHdpdGgg
  >> "!B64TMP!" echo dGhlIGRlZmF1bHRzCj4gc2hvd24gYWJvdmU7IGNob2ljZSAqKjIqKiBhc2tzIG9ubHkgdGhlIHRo
  >> "!B64TMP!" echo cmVlIExMTSBxdWVzdGlvbnM7IGNob2ljZQo+ICoqMyoqIGdvZXMgdGhyb3VnaCBhbGwgc2l4IG51
  >> "!B64TMP!" echo bWJlcmVkIHN0ZXBzIGJlbG93IHNvIHlvdSBjYW4gY3VzdG9taXplCj4gYW55dGhpbmcuIEVpdGhl
  >> "!B64TMP!" echo ciB3YXkgeW91IGNhbiBzdGlsbCBjaGFuZ2UgeW91ciBtaW5kIGFmdGVyd2FyZCBieSBlZGl0aW5n
  >> "!B64TMP!" echo Cj4gYC5lbnZgIGFuZCBydW5uaW5nIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgo+ICoq
  >> "!B64TMP!" echo VGhlIG9wdGlvbmFsIExMTSAoU3RlcCA1LCBvciBzZXR1cCAyKS4qKiBBbnkgT3BlbkFJLWNvbXBh
  >> "!B64TMP!" echo dGlibGUgZW5kcG9pbnQKPiB3b3JrcywgbG9jYWwgb3IgcmVtb3RlOiB0aGUgaW5zdGFsbGVyIGFz
  >> "!B64TMP!" echo a3MgZm9yIGl0cyBiYXNlIFVSTCAoZGVmYXVsdAo+IGBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjFg
  >> "!B64TMP!" echo LCBMTSBTdHVkaW8pLCBhbiBBUEkga2V5IChFbnRlciB0byBza2lwKSBhbmQgYQo+IG1vZGVsIG5h
  >> "!B64TMP!" echo bWUgKEVudGVyIHRvIHNraXApLCBhbmQgd3JpdGVzIHRoZW0gdG8gYC5lbnZgLiBUaGUgZXh0cmFj
  >> "!B64TMP!" echo dGlvbiB0b29sCj4gYHdlYl9leHRyYWN0LnB5YCBhbmQgdGhlIHNraWxsJ3MgIkxMTSBleHRyYWN0
  >> "!B64TMP!" echo aW9uIiBzZWN0aW9uIGFyZSBpbnN0YWxsZWQKPiAqKm9ubHkqKiB3aGVuIGFuIExMTSBpcyBjb25u
  >> "!B64TMP!" echo ZWN0ZWQ7IHdpdGhvdXQgb25lIHRoZSBpbnN0YWxsZWQgc2tpbGwgZG9lcyBub3QKPiBtZW50aW9u
  >> "!B64TMP!" echo IHRoZW0uIFNlZSBbc2VjdGlvbiBEXSgjZC1jb25uZWN0LWFuLWxsbS1sbS1zdHVkaW8tZXRjKS4K
  >> "!B64TMP!" echo Cj4gKipUaGUgYnJvd3NlciByZW5kZXJpbmcgZW5naW5lIChTdGVwIDQpLioqIEZpcmVjcmF3bCBu
  >> "!B64TMP!" echo ZWVkcyBhIGhlYWRsZXNzCj4gYnJvd3NlciB0byBmZXRjaCBKUy1yZW5kZXJlZCBwYWdlcy4gVGhl
  >> "!B64TMP!" echo IGRlZmF1bHQgYW5zd2VyLCAqKjEqKiAob3IganVzdAo+IEVudGVyKSwga2VlcHMgKipQbGF5d3Jp
  >> "!B64TMP!" echo Z2h0Kiog4oCUIHRoZSBjbGFzc2ljIEZpcmVjcmF3bCBlbmdpbmUKPiAoYGdoY3IuaW8vZmlyZWNy
  >> "!B64TMP!" echo YXdsL3BsYXl3cmlnaHQtc2VydmljZWApLiAqKjIqKiAob3IgKip5KiopIHN3aXRjaGVzIHRvCj4g
  >> "!B64TMP!" echo KipCcm93c2VybGVzcyoqIChgZ2hjci5pby9icm93c2VybGVzcy9jaHJvbWl1bWApIGluc3RlYWQs
  >> "!B64TMP!" echo IHJ1biBpbiBpdHMgYnVpbHQtaW4KPiBzdGVhbHRoIG1vZGUsIHdoaWNoIG1hc2tzIGNvbW1vbiBh
  >> "!B64TMP!" echo dXRvbWF0aW9uIGZpbmdlcnByaW50cyAoZS5nLgo+IGBuYXZpZ2F0b3Iud2ViZHJpdmVyYCkgYW5k
  >> "!B64TMP!" echo IHRlbmRzIHRvIGdldCBibG9ja2VkIGxlc3Mgb2Z0ZW4gYnkKPiBDbG91ZGZsYXJlLXN0eWxlIGJv
  >> "!B64TMP!" echo dCBjaGVja3MuICoqMyoqIHN3aXRjaGVzIHRvICoqSW52aXNpYmxlIFBsYXl3cmlnaHQqKiwgYQo+
  >> "!B64TMP!" echo IHBhdGNoZWQgRmlyZWZveCB3aG9zZSBmaW5nZXJwcmludCBpcyBnZW5lcmF0ZWQgaW5zaWRlIHRo
  >> "!B64TMP!" echo ZSBicm93c2VyIGl0c2VsZgo+IChzZWUgW2JlbG93XSgjaW52aXNpYmxlLXBsYXl3cmlnaHQtZW5n
  >> "!B64TMP!" echo aW5lKSkuIE9ubHkgdGhlIGVuZ2luZSB5b3UgcGljayBpcwo+IGFjdHVhbGx5IHN0YXJ0ZWQg4oCU
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIgd3JpdGVzIGBDT01QT1NFX1BST0ZJTEVTYCBhbmQKPiBgUExBWVdSSUdI
  >> "!B64TMP!" echo VF9NSUNST1NFUlZJQ0VfVVJMYCB0byBgLmVudmAgYWNjb3JkaW5nbHkuIFRvIHN3aXRjaCBsYXRl
  >> "!B64TMP!" echo ciwgZWRpdAo+IHRob3NlIHR3byBsaW5lcyBpbiBgLmVudmAgKGBpbnZpc2libGVgIC8gYGh0dHA6
  >> "!B64TMP!" echo Ly9pbnZpc2libGUtcGxheXdyaWdodDozMDAwL3NjcmFwZWAKPiBmb3IgdGhlIHRoaXJkIGVuZ2lu
  >> "!B64TMP!" echo ZSkgYW5kIHJ1biBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLgo+Cj4gPGEgaWQ9Imludmlz
  >> "!B64TMP!" echo aWJsZS1wbGF5d3JpZ2h0LWVuZ2luZSI+PC9hPioqSW52aXNpYmxlIFBsYXl3cmlnaHQgZW5naW5l
  >> "!B64TMP!" echo LioqIFRoZXJlCj4gaXMgbm8gcHVibGlzaGVkIGltYWdlIGZvciBpdCwgc28gdGhlIGluc3RhbGxl
  >> "!B64TMP!" echo ciAqKmJ1aWxkcyoqIGl0IGZyb20KPiBbYGludmlzaWJsZS1wbGF5d3JpZ2h0L2BdKGludmlzaWJs
  >> "!B64TMP!" echo ZS1wbGF5d3JpZ2h0Lykgb24gdGhlIGZpcnN0IHN0YXJ0OiBhYm91dAo+IDEwIG1pbnV0ZXMgYW5k
  >> "!B64TMP!" echo IH4yIEdCIChNaWNyb3NvZnQncyBQbGF5d3JpZ2h0IGJhc2UgaW1hZ2UsIFB5dGhvbiAzLjExKyB2
  >> "!B64TMP!" echo aWEKPiBgdXZgLCBhbmQgdGhlIH4yNjAgTUIgZW5naW5lKSwgd2hpY2ggbmVlZHMgYWNjZXNzIHRv
  >> "!B64TMP!" echo IGBtY3IubWljcm9zb2Z0LmNvbWAsCj4gYGdoY3IuaW9gLCBQeVBJIGFuZCBHaXRIdWIuIElmIEdp
  >> "!B64TMP!" echo dEh1YiByYXRlLWxpbWl0cyB0aGF0IGRvd25sb2FkLCBwdXQgYSB0b2tlbgo+IChubyBzY29wZXMg
  >> "!B64TMP!" echo bmVlZGVkKSBpbiBgLmVudmAgYXMgYElOVklTSUJMRV9HSVRIVUJfVE9LRU5gIGFuZCByZS1ydW4K
  >> "!B64TMP!" echo PiBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLiBUaGUgc2VydmljZSBzcGVha3MgRmlyZWNy
  >> "!B64TMP!" echo YXdsJ3MgdHdvIHJvdXRlcwo+IChgUE9TVCAvc2NyYXBlYCwgYEdFVCAvaGVhbHRoYCksIHJ1bnMg
  >> "!B64TMP!" echo RmlyZWZveCBvbiBhIHZpcnR1YWwgZGlzcGxheQo+IChgaGVhZGxlc3M9VHJ1ZWAgb24gTGludXgg
  >> "!B64TMP!" echo bWVhbnMgYSByZWFsIHdpbmRvd2VkIEZpcmVmb3ggb24gWHZmYikgYW5kIG5lZWRzCj4gYHNobV9z
  >> "!B64TMP!" echo aXplOiAyZ2JgLCB3aGljaCBgZG9ja2VyLWNvbXBvc2UueW1sYCBzZXRzLiBBIGZ1bGwgRmlyZWZv
  >> "!B64TMP!" echo eCBpcwo+IGhlYXZpZXIgdGhhbiB0aGUgb3RoZXIgdHdvLCBzbyBpdCByZW5kZXJzIDQgcGFnZXMg
  >> "!B64TMP!" echo YXQgYSB0aW1lIGJ5IGRlZmF1bHQKPiAoYElOVklTSUJMRV9NQVhfUEFHRVNgKS4gYFVwZGF0ZS5i
  >> "!B64TMP!" echo YXRgIC8gYC4vdXBkYXRlLnNoYCByZWJ1aWxkIGl0IHdpdGhvdXQgdGhlCj4gY2FjaGUgdG8gcGlj
  >> "!B64TMP!" echo ayB1cCBhIG5ld2VyIGVuZ2luZS4gVGhlIGVuZ2luZSBpcyBNSVQgLyBBcGFjaGUtMi4wIGxpY2Vu
  >> "!B64TMP!" echo c2VkOyBzZWUKPiBpdHMgcmVwb3NpdG9yeSBmb3IgZGV0YWlscy4KCj4gKipUaGUgb3B0aW9uYWwg
  >> "!B64TMP!" echo RmlyZWNyYXdsIGFjY291bnQgKFN0ZXAgNikuKiogQSBmZXcgb2YgdGhlIGJ1bmRsZWQgc2tpbGwn
  >> "!B64TMP!" echo cwo+IHRvb2xzIOKAlCB0aGUgcmVzZWFyY2ggYWdlbnQsIGxpdmUtcGFnZSBgaW50ZXJhY3RgLCBm
  >> "!B64TMP!" echo aWxlIGBwYXJzZWAsIG1vbml0b3JzLAo+IHBhcGVyIHJlc2VhcmNoLCBhbmQgR2l0SHViL2RldmVs
  >> "!B64TMP!" echo b3BlciBzZWFyY2gg4oCUIG9ubHkgd29yayBhZ2FpbnN0IEZpcmVjcmF3bCdzCj4gcGFpZCBjbG91
  >> "!B64TMP!" echo ZCBBUEkuIFRoZSBkZWZhdWx0IGFuc3dlciBpcyAqKk4qKjogdGhvc2UgdG9vbHMgYXJlIHNpbXBs
  >> "!B64TMP!" echo eSAqbm90Cj4gaW5zdGFsbGVkKiwgYW5kIHRoZSBza2lsbCBzaGlwcyBhIGxlYW5lciBgU0tJTEwu
  >> "!B64TMP!" echo bWRgIGNvdmVyaW5nIGp1c3QgdGhlIGZyZWUKPiBsb2NhbCB0b29scy4gQW5zd2VyICoqeSoqIGlu
  >> "!B64TMP!" echo c3RlYWQgYW5kIHRoZSBpbnN0YWxsZXIgYXNrcyBmb3IgeW91ciBBUEkga2V5Cj4gKGFuZCBBUEkg
  >> "!B64TMP!" echo VVJMLCBkZWZhdWx0IGBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2YCksIHN0b3JlcyB0aGVtIGlu
  >> "!B64TMP!" echo IHlvdXIKPiBgLmVudmAsIGFuZCBpbnN0YWxscyBhbGwgMjUgdG9vbHMgKDI2IHdpdGggTExNIGV4
  >> "!B64TMP!" echo dHJhY3Rpb24pLiBZb3UgY2FuIGNoYW5nZSB5b3VyIG1pbmQgbGF0ZXIKPiBieSByZS1ydW5uaW5n
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIgYW5kIGFuc3dlcmluZyBkaWZmZXJlbnRseS4KCj4gKipGaXJzdCBydW4g
  >> "!B64TMP!" echo ZG93bmxvYWRzIH4z4oCTNCBHQiBvZiBEb2NrZXIgaW1hZ2VzKiogKFBsYXl3cmlnaHQncyBhbmQg
  >> "!B64TMP!" echo QnJvd3Nlcmxlc3Mncwo+IGltYWdlcyBlYWNoIGJ1bmRsZSBhIGZ1bGwgQ2hyb21pdW0sIHNvIG9u
  >> "!B64TMP!" echo bHkgdGhlIG9uZSB5b3UgcGlja2VkIGlzIHB1bGxlZDsKPiBJbnZpc2libGUgUGxheXdyaWdodCBp
  >> "!B64TMP!" echo cyBidWlsdCBsb2NhbGx5IGluc3RlYWQg4oCUIHNlZSBTdGVwIDQpLgo+IFN1YnNlcXVlbnQgc3Rh
  >> "!B64TMP!" echo cnRzIGFyZSBhIGZldyBzZWNvbmRzLgoKV2hlbiBpdCBmaW5pc2hlcyB5b3UnbGwgc2VlOgoKYGBg
  >> "!B64TMP!" echo ClNlYXJYTkcgIChzZWFyY2ggKyBKU09OIEFQSSk6ICBodHRwOi8vbG9jYWxob3N0Ojk5OTAKRmly
  >> "!B64TMP!" echo ZWNyYXdsIChzY3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xvY2FsaG9zdDo5OTkxCkFnZW50IHNr
  >> "!B64TMP!" echo aWxsOiBDOlxVc2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcbG9jYWwtd2ViLXNlYXJjaCAgIChvciB+
  >> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gpCmBgYAoKT3BlbiBgaHR0cDovL2xvY2Fs
  >> "!B64TMP!" echo aG9zdDo5OTkwYCBpbiBhIGJyb3dzZXIgdG8gc2VlIHRoZSBTZWFyWE5HIHNlYXJjaCBVSSDigJQg
  >> "!B64TMP!" echo b3IsCmlmIHlvdXIgYWdlbnQgbG9hZHMgc2tpbGxzIGZyb20gYH4vLmFnZW50cy9za2lsbHMvYCwg
  >> "!B64TMP!" echo anVzdCBhc2sgaXQgdG8gcmVzZWFyY2gKc29tZXRoaW5nIGN1cnJlbnQgYW5kIGl0IHdpbGwgdXNl
  >> "!B64TMP!" echo ICoqbG9jYWwtd2ViLXNlYXJjaCoqIGF1dG9tYXRpY2FsbHkgKHNlZQpbc2VjdGlvbiBBXSgjYS10
  >> "!B64TMP!" echo aGUtYnVuZGxlZC1sb2NhbC13ZWItc2VhcmNoLXNraWxsLXJlY29tbWVuZGVkKSkuCgotLS0KCiMj
  >> "!B64TMP!" echo IE1hbmFnaW5nIHRoZSBzdGFjawoKQWZ0ZXIgaW5zdGFsbCwgdGhlIG1hbmFnZW1lbnQgc2NyaXB0
  >> "!B64TMP!" echo cyBsaXZlICoqaW4geW91ciBpbnN0YWxsIGZvbGRlcioqCihgQzpcVXNlcnNcWW91XGxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaGAgb24gV2luZG93cywgYH4vbG9jYWwtc2VhcmNoYCBvbiBMaW51eC9tYWNPUykuClRoZXkg
  >> "!B64TMP!" echo YXV0by1kZXRlY3QgdGhlaXIgb3duIGxvY2F0aW9uLCBzbyB5b3UgY2FuIHJ1biB0aGVtIGZyb20g
  >> "!B64TMP!" echo YW55d2hlcmUgYnkKZG91YmxlLWNsaWNraW5nIG9yIGAuL2AtaW5nIHRoZW0uCgp8IEFjdGlvbiB8
  >> "!B64TMP!" echo IFdpbmRvd3MgfCBMaW51eCAvIG1hY09TIHwKfC0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS18CnwgKipTdGFydCoqIHRoZSBzdGFjayB8IGBSdW4uYmF0YCB8IGAuL3J1bi5zaGAgfAp8
  >> "!B64TMP!" echo ICoqU3RvcCoqIChrZWVwIGRhdGEpIHwgYFN0b3AuYmF0YCB8IGAuL3N0b3Auc2hgIHwKfCAqKlVw
  >> "!B64TMP!" echo ZGF0ZSoqIGltYWdlcyArIGFwcGx5IGAuZW52YCBjaGFuZ2VzICsgKipyZS1zeW5jIHRoZSBza2ls
  >> "!B64TMP!" echo bCoqIHwgYFVwZGF0ZS5iYXRgIHwgYC4vdXBkYXRlLnNoYCB8CnwgKipVbmluc3RhbGwqKiAoY29u
  >> "!B64TMP!" echo dGFpbmVycyArIHZvbHVtZXMgKyBza2lsbCwgb3B0aW9uYWwgZm9sZGVyIGRlbGV0ZSkgfCBgVW5p
  >> "!B64TMP!" echo bnN0YWxsLmJhdGAgfCBgLi91bmluc3RhbGwuc2hgIHwKCi0gKipTdG9wKiogb25seSByZW1vdmVz
  >> "!B64TMP!" echo IGNvbnRhaW5lcnM7IHlvdXIgZGF0YSB2b2x1bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLAogIHJl
  >> "!B64TMP!" echo ZGlzIGNhY2hlLCByYWJiaXRtcS9wb3N0Z3JlcyBkYXRhKSBhcmUgcHJlc2VydmVkLgotICoqVXBk
  >> "!B64TMP!" echo YXRlKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgcHVsbGAgdGhlbiBgZG9ja2VyIGNvbXBvc2UgdXAg
  >> "!B64TMP!" echo LWRgIChgcG9kbWFuIGNvbXBvc2Ug4oCmYCBvbiBQb2RtYW4pLCBzbyBpdAogIGJvdGggdXBncmFk
  >> "!B64TMP!" echo ZXMgaW1hZ2VzICoqYW5kKiogYXBwbGllcyBhbnkgcG9ydC9MTE0gZWRpdHMgeW91IG1hZGUgdG8g
  >> "!B64TMP!" echo YC5lbnZgOwogIGl0IGFsc28gcmUtY29waWVzIHRoZSBidW5kbGVkIGBsb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo YCBza2lsbCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2AuCi0gKipVbmluc3RhbGwqKiBydW5zIGBk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBkb3duIC12YCAoZGVsZXRlcyB2b2x1bWVzICsgZGF0YSksCiAgcmVtb3Zl
  >> "!B64TMP!" echo cyB0aGUgYGxvY2FsLXdlYi1zZWFyY2hgIHNraWxsIGZyb20gYH4vLmFnZW50cy9za2lsbHMvbG9j
  >> "!B64TMP!" echo YWwtd2ViLXNlYXJjaGAsIHRoZW4KICBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyLiBQdWxsZWQgaW1hZ2VzIGFyZSBrZXB0OyByZWNsYWltIHRoZW0KICB3aXRoIGBkb2NrZXIg
  >> "!B64TMP!" echo aW1hZ2UgcHJ1bmUgLWFgIGlmIGRlc2lyZWQuCgotLS0KCiMjIEhvdyBpdCBmaXRzIHRvZ2V0aGVy
  >> "!B64TMP!" echo CgpgYGAKICAgICAgICB5b3VyIEFJIG1vZGVsIC8gYWdlbnQgKGxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwpIC8gTUNQIGNsaWVudCAvIGNoYXQgVUkKICAgICAgICAgICAgICAgICAgICAgIOKUggogICDi
  >> "!B64TMP!" echo lIzilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lLzilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
  >> "!B64TMP!" echo lIDilIDilIDilJAKICAg4pa8ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo 4pa8Cmh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCAgICAgICAgICAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5
  >> "!B64TMP!" echo MQogICDilIIgU2VhclhORyAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgRmlyZWNyYXds
  >> "!B64TMP!" echo IEFQSQogICDilIIgIC0gL3NlYXJjaD9xPS4uLiZmb3JtYXQ9anNvbiAgICAgICDilIIgIC0gL3Yx
  >> "!B64TMP!" echo L3NjcmFwZSAgIChvbmUgVVJMIC0+IG1hcmtkb3duKQogICDilIIgIC0gYWdncmVnYXRlcyB+NzAg
  >> "!B64TMP!" echo ZW5naW5lcyAgICAgICAgICAg4pSCICAtIC92MS9jcmF3bCAgICAod2hvbGUgc2l0ZSwgYXN5bmMp
  >> "!B64TMP!" echo CiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3YxL21h
  >> "!B64TMP!" echo cCAgICAgIChzaXRlIFVSTCB0cmVlKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAg4pSCICAtIC92MS9zZWFyY2ggICAoLT4gdXNlcyBTZWFyWE5HISkKICAg4pSCICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvZXh0cmFjdCAgKC0+
  >> "!B64TMP!" echo IHVzZXMgeW91ciBMTE0pCiAgIOKUguKXhOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCB3
  >> "!B64TMP!" echo aXJlZCB0b2dldGhlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilKQgIFNFQVJYTkdf
  >> "!B64TMP!" echo RU5EUE9JTlQ9aHR0cDovL3NlYXJ4bmc6ODA4MAogICDilIIgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAg4pSCCiAgIOKUlOKUgOKUgOKUgOKUgOKUgOKUgOKUgCBwcml2YXRlIGRv
  >> "!B64TMP!" echo Y2tlciBuZXR3b3JrIOKUgOKUgOKUgOKUgOKUgOKUgOKUmAogICAgICAgICAgICAgICAgIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC1uZXQKICAgYWxzbyBvbiBpdDogcGxheXdyaWdodC1zZXJ2aWNlLCBicm93c2VybGVz
  >> "!B64TMP!" echo cyBPUiBpbnZpc2libGUtcGxheXdyaWdodCAod2hpY2hldmVyIHlvdSBwaWNrZWQgaW4gU3RlcCA0
  >> "!B64TMP!" echo KSwgcmVkaXMsIHJhYmJpdG1xLCBudXEtcG9zdGdyZXMKYGBgCgpGb3VyIGtleSB3aXJpbmcgZGVj
  >> "!B64TMP!" echo aXNpb25zIHRoZSBpbnN0YWxsZXIgbWFrZXMgZm9yIHlvdToKCjEuICoqU2VhclhORyBKU09OICsg
  >> "!B64TMP!" echo bm8gbGltaXRlcioqIOKAlCBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCBzZXRzCiAgIGBz
  >> "!B64TMP!" echo ZWFyY2guZm9ybWF0czogW2h0bWwsIGpzb25dYCBhbmQgYHNlcnZlci5saW1pdGVyOiBmYWxzZWAs
  >> "!B64TMP!" echo IHNvIG1vZGVscyBjYW4gaGl0CiAgIGAvc2VhcmNoP2Zvcm1hdD1qc29uYCB3aXRob3V0IGJlaW5n
  >> "!B64TMP!" echo IGJsb2NrZWQgYXMgYSBib3QuCjIuICoqRmlyZWNyYXdsIOKGkiBTZWFyWE5HKiog4oCUIHRoZSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgY29udGFpbmVyIHNldHMKICAgYFNFQVJYTkdfRU5EUE9JTlQ9aHR0cDovL3NlYXJ4
  >> "!B64TMP!" echo bmc6ODA4MGAsIHNvIEZpcmVjcmF3bCdzIGAvdjEvc2VhcmNoYCB1c2VzIHlvdXIKICAgbG9jYWwg
  >> "!B64TMP!" echo U2VhclhORyBpbnN0ZWFkIG9mIG5lZWRpbmcgYSB0aGlyZC1wYXJ0eSBzZWFyY2ggcHJvdmlkZXIu
  >> "!B64TMP!" echo CjMuICoqRmlyZWNyYXdsIOKGkiBicm93c2VyIGVuZ2luZSoqIOKAlCBgZG9ja2VyLWNvbXBvc2Uu
  >> "!B64TMP!" echo eW1sYCBkZWZpbmVzCiAgIGBwbGF5d3JpZ2h0LXNlcnZpY2VgLCBgYnJvd3Nlcmxlc3NgIGFuZCBg
  >> "!B64TMP!" echo aW52aXNpYmxlLXBsYXl3cmlnaHRgIGJlaGluZCBDb21wb3NlIHByb2ZpbGVzOyBgLmVudmAncwog
  >> "!B64TMP!" echo ICBgQ09NUE9TRV9QUk9GSUxFU2AgKHNldCBieSBTdGVwIDQpIGVuYWJsZXMganVzdCBvbmUsIGFu
  >> "!B64TMP!" echo ZAogICBgUExBWVdSSUdIVF9NSUNST1NFUlZJQ0VfVVJMYCBwb2ludHMgRmlyZWNyYXdsIGF0IGl0
  >> "!B64TMP!" echo Lgo0LiAqKmxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgYXV0by1pbnN0YWxsKiog4oCUIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsZXIgY29waWVzIHRoZSBidW5kbGVkIHNraWxsIHRvCiAgIGB+Ly5hZ2VudHMvc2tpbGxzL2xv
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvYCAoYWRkL292ZXJyaWRlKSBhbmQgcmVjb3JkcyB0aGUgaW5zdGFsbCBw
  >> "!B64TMP!" echo YXRoIGluCiAgIGFuIGBpbnN0YWxsLWRpci50eHRgIGhpbnQgaW5zaWRlIHRoZSBza2lsbCwgc28g
  >> "!B64TMP!" echo dGhlIHNraWxsIGZpbmRzIHRoZSBzdGFjayBldmVuCiAgIGlmIHlvdSBpbnN0YWxsZWQgdG8gYSBj
  >> "!B64TMP!" echo dXN0b20gZm9sZGVyIGFuZCBEb2NrZXIgaXNuJ3QgcnVubmluZyB5ZXQuIFdpdGhvdXQgYQogICBj
  >> "!B64TMP!" echo b25maWd1cmVkIEZpcmVjcmF3bCBhY2NvdW50IGl0IGluc3RhbGxzIG9ubHkgdGhlIGZyZWUgbG9j
  >> "!B64TMP!" echo YWwgdG9vbHMgYW5kIGEKICAgbWF0Y2hpbmcgY29yZS1vbmx5IGBTS0lMTC5tZGAuCgotLS0KCiMj
  >> "!B64TMP!" echo IFVzaW5nIGl0IHdpdGggQUkgbW9kZWxzCgpUaGVyZSBhcmUgKipzZXZlbioqIHdheXMgdG8gdXNl
  >> "!B64TMP!" echo IHRoaXMgc3lzdGVtLCBmcm9tIGxvd2VzdCB0byBoaWdoZXN0CmludGVncmF0aW9uLiBQaWNrIHdo
  >> "!B64TMP!" echo YXQgZml0cyB5b3VyIHN0YWNrIOKAlCB5b3UgY2FuIG1peCBhbmQgbWF0Y2guCgojIyMgQS4gVGhl
  >> "!B64TMP!" echo IGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCAocmVjb21tZW5kZWQpCgpUaGUgaW5zdGFs
  >> "!B64TMP!" echo bGVyIHNoaXBzIHdpdGggKipsb2NhbC13ZWItc2VhcmNoKiosIGFuIGFnZW50IHNraWxsIHRoYXQg
  >> "!B64TMP!" echo dHVybnMgYW55CnNraWxsLWxvYWRpbmcgYWdlbnQgaW50byBhIHdlYiByZXNlYXJjaGVyIHdpdGgg
  >> "!B64TMP!" echo emVybyBjb25maWd1cmF0aW9uLiBJZiB5b3VyCmFnZW50IHJlYWRzIHNraWxscyBmcm9tIGB+Ly5h
  >> "!B64TMP!" echo Z2VudHMvc2tpbGxzL2AKKGBDOlxVc2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcYCBvbiBXaW5kb3dz
  >> "!B64TMP!" echo KSwgaXQncyBhbHJlYWR5IGF2YWlsYWJsZSBhZnRlcgppbnN0YWxsIOKAlCByZXN0YXJ0IHRoZSBh
  >> "!B64TMP!" echo Z2VudCBpZiBpdCB3YXMgcnVubmluZy4KClRoZSBpbnN0YWxsZXI6Ci0gcHV0cyBhIGNvcHkgaW4g
  >> "!B64TMP!" echo YDxpbnN0YWxsIGZvbGRlcj4vbG9jYWwtd2ViLXNlYXJjaC9gLCBhbmQKLSAqKmF1dG9tYXRpY2Fs
  >> "!B64TMP!" echo bHkgaW5zdGFsbHMgKGFkZC9vdmVycmlkZSkqKiBpdCBpbnRvCiAgYH4vLmFnZW50cy9za2lsbHMv
  >> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9gLgoKV2hhdCB0aGUgc2tpbGwgZG9lcyBmb3IgdGhlIGFnZW50OgoK
  >> "!B64TMP!" echo LSAqKkZpbmRzIHRoZSBzdGFjayBhdXRvbWF0aWNhbGx5LioqIEl0IHJlYWRzIHRoZSByZWFsIHBv
  >> "!B64TMP!" echo cnRzIGZyb20geW91ciBgLmVudmAKICAoc28gY3VzdG9tIGluc3RhbGwtdGltZSBwb3J0cyBqdXN0
  >> "!B64TMP!" echo IHdvcmspIGFuZCBsb2NhdGVzIHRoZSBpbnN0YWxsIGZvbGRlciB2aWEKICB0aGUgY29tcG9zZSBs
  >> "!B64TMP!" echo YWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFpbmVycywgdGhlIGluc3RhbGxlci1yZWNvcmRlZAog
  >> "!B64TMP!" echo IGBpbnN0YWxsLWRpci50eHRgIGhpbnQsIG9yIGB+L2xvY2FsLXNlYXJjaGAg4oCUIG5vIGhhcmRj
  >> "!B64TMP!" echo b2RlZCBhbnl0aGluZy4KLSAqKlNlbGYtaGVhbHMgYSBkb3duIHN0YWNrIOKAlCBubyB3YXJtLXVw
  >> "!B64TMP!" echo IHN0ZXAuKiogSWYgdGhlIERvY2tlciBlbmdpbmUgb3IgdGhlCiAgY29udGFpbmVycyBhcmUgZG93
  >> "!B64TMP!" echo biB3aGVuIGEgc2VhcmNoL3NjcmFwZSBydW5zLCB0aGUgc2NyaXB0IGJvb3RzIHRoZSBlbmdpbmUK
  >> "!B64TMP!" echo ICAoRG9ja2VyIERlc2t0b3AgLyBgc3lzdGVtY3RsIHN0YXJ0IGRvY2tlcmApLCBydW5zIHRoZSBz
  >> "!B64TMP!" echo YW1lIGBkb2NrZXIgY29tcG9zZQogIHVwIC1kYCB0aGF0IGBSdW4uYmF0YCAvIGBydW4uc2hgIHVz
  >> "!B64TMP!" echo ZSwgd2FpdHMgZm9yIHRoZSBlbmRwb2ludHMsIGFuZCByZXRyaWVzCiAgdGhlIHJlcXVlc3Qg4oCU
  >> "!B64TMP!" echo IHNvIHRoZSBhZ2VudCBjYWxscyB0aGUgc2VhcmNoL3NjcmFwZSBzY3JpcHRzIGRpcmVjdGx5LCBl
  >> "!B64TMP!" echo dmVuCiAgaW4gYW4gb2xkIGNvbnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzIHNpbmNlIGdv
  >> "!B64TMP!" echo bmUgZG93bgogIChgZW5zdXJlX3N0YWNrLnB5YCByZW1haW5zIGF2YWlsYWJsZSBhcyBhbiBvcHRp
  >> "!B64TMP!" echo b25hbCBwcmUtZmxpZ2h0IGNoZWNrKS4gVGhlCiAgc3RhY2sgaXMgKipuZXZlciBzdG9wcGVkKiog
  >> "!B64TMP!" echo YnkgdGhlIHNjcmlwdHMgKHN0b3BwaW5nIGlzIHlvdXIgam9iLCB2aWEKICBgU3RvcC5iYXRgIC8g
  >> "!B64TMP!" echo YHN0b3Auc2hgKS4KLSAqKlNlYXJjaGVzIHRoZSB3ZWIuKiogYHdlYl9zZWFyY2gucHkgInF1ZXJ5
  >> "!B64TMP!" echo ImAgcHJpbnRzIHRoZSB0b3AgcmVzdWx0cyBhcwogIGB0aXRsZSAvIHVybCAvIHNuaXBwZXRgLCB3
  >> "!B64TMP!" echo aXRoIGAtLWxpbWl0YCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGFuZAogIGAtLWNh
  >> "!B64TMP!" echo dGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYCBvcHRpb25zLgotICoqUmVhZHMgcGFnZXMuKiogYHdl
  >> "!B64TMP!" echo Yl9zY3JhcGUucHkgPHVybD5gIHJldHVybnMgdGhlIHBhZ2UgYXMgY2xlYW4gTWFya2Rvd24KICAo
  >> "!B64TMP!" echo dHJ1bmNhdGVkIGF0IDIwLDAwMCBjaGFyczsgcmFpc2Ugd2l0aCBgLS1tYXgtY2hhcnNgKS4KLSAq
  >> "!B64TMP!" echo KlJlYWRzIFlvdVR1YmUgdHJhbnNjcmlwdHMuKiogYHdlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkg
  >> "!B64TMP!" echo PHZpZGVvX2lkIHwgdXJsPiBbLS1sYW5nIGVuLGRlXWAKICBwcmludHMgYSB2aWRlbydzIGNhcHRp
  >> "!B64TMP!" echo b25zIGFzIGBbTU06U1NdIHRleHRgIGxpbmVzLiBJdCB0YWxrcyBkaXJlY3RseSB0bwogIFlvdVR1
  >> "!B64TMP!" echo YmUg4oCUIG5vIERvY2tlciBzdGFjaywgbm8gc2VsZi1oZWFsLCBubyBhY2NvdW50IG5lZWRlZCDi
  >> "!B64TMP!" echo gJQgdGhyb3VnaAogICoqeXQtZGxwKiogKGBwaXAgaW5zdGFsbCAtVSAieXQtZGxwW2RlZmF1bHRd
  >> "!B64TMP!" echo ImAsIHBsdXMgRGVubyBvciBOb2RlLmpzIDIyKyBvbgogIGBQQVRIYCkuIFlvdVR1YmUgbm93IGd1
  >> "!B64TMP!" echo YXJkcyB0aGUgY2FwdGlvbnMgb2YgYSBncm93aW5nIHNoYXJlIG9mIHZpZGVvcyB3aXRoIGEKICAi
  >> "!B64TMP!" echo UE8gdG9rZW4iIHRoYXQgcGxhaW4gc2NyYXBlcnMgc3VjaCBhcyBgeW91dHViZS10cmFuc2NyaXB0
  >> "!B64TMP!" echo LWFwaWAgY2Fubm90IHByb2R1Y2UKICAodGhleSBnZXQgYW4gZW1wdHkgYW5zd2VyKTsgeXQtZGxw
  >> "!B64TMP!" echo IGNhbi4gVGhlIG9sZGVyIHBhY2thZ2UgaXMga2VwdCBvbmx5IGFzIGEKICBmYWxsYmFjayBmb3Ig
  >> "!B64TMP!" echo dmlkZW9zIHRoYXQgYXJlIG5vdCBiZWhpbmQgdGhlIHRva2VuIHlldC4KLSAqKkV4cG9zZXMgdGhl
  >> "!B64TMP!" echo IGZ1bGwgRmlyZWNyYXdsIE1DUCBzdXJmYWNlIOKAlCAyNCB0b29scy4qKiBCZXNpZGVzIHNlYXJj
  >> "!B64TMP!" echo aCBhbmQKICBzY3JhcGUsIHRoZSBza2lsbCBzaGlwcyBzY3JpcHRzIG1pcnJvcmluZyBldmVyeSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgTUNQIHRvb2w6CiAgYHdlYl9tYXAucHlgIChlbnVtZXJhdGUgYSBzaXRlJ3MgVVJM
  >> "!B64TMP!" echo cyksIGB3ZWJfY3Jhd2wucHlgIC8KICBgd2ViX2NyYXdsX3N0YXR1cy5weWAgKG11bHRpLXBhZ2Ug
  >> "!B64TMP!" echo Y3Jhd2xzKSwgYHdlYl9hZ2VudC5weWAgLwogIGB3ZWJfYWdlbnRfc3RhdHVzLnB5YCAoYXN5bmMg
  >> "!B64TMP!" echo cmVzZWFyY2ggYWdlbnQpLCBgd2ViX2ludGVyYWN0LnB5YCAvCiAgYHdlYl9pbnRlcmFjdF9zdG9w
  >> "!B64TMP!" echo LnB5YCAobGl2ZSBicm93c2VyIHNlc3Npb25zKSwgYHdlYl9wYXJzZS5weWAgKGxvY2FsCiAgUERG
  >> "!B64TMP!" echo L1dvcmQvSFRNTC8uLi4gZG9jdW1lbnRzKSwgZWlnaHQgYHdlYl9tb25pdG9yXyoucHlgIHNjcmlw
  >> "!B64TMP!" echo dHMgKHJlY3VycmluZwogIGNoYW5nZSB0cmFja2luZyksIGZpdmUgYHdlYl9yZXNlYXJjaF8qLnB5
  >> "!B64TMP!" echo YCBzY3JpcHRzIChiaW9tZWRpY2FsICsgYXJYaXYKICBwYXBlciBzZWFyY2gsIGNpdGF0aW9uIGdy
  >> "!B64TMP!" echo YXBoLCBmdWxsLXRleHQgcmVhZGluZyksIGB3ZWJfZ2l0aHViX3NlYXJjaC5weWAKICAoaW5kZXhl
  >> "!B64TMP!" echo ZCBHaXRIdWIgaXNzdWVzL1BScy9SRUFETUVzKSwgYW5kIGB3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5w
  >> "!B64TMP!" echo eWAgKGFuCiAgaW5kZXggYnVpbHQgZm9yIGNvZGluZyBhZ2VudHMpLiBFdmVyeSBzY3JpcHQgc2Vs
  >> "!B64TMP!" echo Zi1oZWFscyB0aGUgc3RhY2ssIHByaW50cwogIGNsZWFuIG91dHB1dCwgYW5kIHN1cHBvcnRzIGAt
  >> "!B64TMP!" echo LWpzb25gIGZvciB0aGUgcmF3IEFQSSByZXNwb25zZS4KLSAqKk9wdGlvbmFsIGFjY291bnQgZmVh
  >> "!B64TMP!" echo dHVyZXMuKiogVGhlIHJlc2VhcmNoIGFnZW50LCBpbnRlcmFjdCwgcGFyc2UsCiAgbW9uaXRvcnMs
  >> "!B64TMP!" echo IHBhcGVyIHJlc2VhcmNoLCBhbmQgZGV2ZWxvcGVyIHNlYXJjaCBhcmUgRmlyZWNyYXdsIGFjY291
  >> "!B64TMP!" echo bnQKICBmZWF0dXJlcyAocGFpZCBjbG91ZCBBUEkpLiBUaGUgaW5zdGFsbGVyJ3MgIkFkZCBhIEZp
  >> "!B64TMP!" echo cmVjcmF3bCBhY2NvdW50PyIKICBxdWVzdGlvbiBkZWNpZGVzIGhvdyB0aGV5J3JlIGhhbmRsZWQ6
  >> "!B64TMP!" echo ICoqTioqIChkZWZhdWx0KSBza2lwcyB0aGVtIOKAlCB0aGUKICBza2lsbCBpcyBpbnN0YWxsZWQg
  >> "!B64TMP!" echo d2l0aCBvbmx5IHRoZSBmcmVlIGxvY2FsIHRvb2xzIChzZWFyY2gsIHNjcmFwZSwgbWFwLAogIGNy
  >> "!B64TMP!" echo YXdsLCBjcmF3bCBzdGF0dXMsIFlvdVR1YmUgdHJhbnNjcmlwdHMpIGFuZCBhIGNvcmUtb25seSBg
  >> "!B64TMP!" echo U0tJTEwubWRgIHRoYXQKICBkb2Vzbid0IG1lbnRpb24gdGhlIGFjY291bnQgdG9vbHM7ICoqeSoq
  >> "!B64TMP!" echo IGluc3RhbGxzIGFsbCAyNSB0b29scyAoMjYgd2l0aCBMTE0gZXh0cmFjdGlvbikgYW5kIHdyaXRl
  >> "!B64TMP!" echo cwogIGBGSVJFQ1JBV0xfQVBJX1VSTGAgKyBgRklSRUNSQVdMX0FQSV9LRVlgIGludG8geW91ciBg
  >> "!B64TMP!" echo LmVudmAgc28gdGhvc2UKICBzY3JpcHRzIGNhbGwgdGhlIGNsb3VkIEFQSSBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo ICh0aGUgc2FtZSBlbnYgdmFyIG5hbWVzIHRoZQogIG9mZmljaWFsIGZpcmVjcmF3bC1tY3Agc2Vy
  >> "!B64TMP!" echo dmVyIHVzZXMsIGlmIHlvdSBwcmVmZXIgYGV4cG9ydGBpbmcgdGhlbSkuCgpNYW51YWwgdXNhZ2Ug
  >> "!B64TMP!" echo KGV4YWN0bHkgd2hhdCB0aGUgYWdlbnQgcnVucyDigJQgbm8gc2VwYXJhdGUgc3RhcnQgc3RlcCBu
  >> "!B64TMP!" echo ZWVkZWQpOgoKYGBgYmFzaApweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0IHB5dGhvbiByZWxlYXNlIgpweXRob24gfi8u
  >> "!B64TMP!" echo YWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NjcmFwZS5weSAiaHR0
  >> "!B64TMP!" echo cHM6Ly9leGFtcGxlLmNvbSIKIyBhIGZldyBvZiB0aGUgb3RoZXIgdG9vbHM6CnB5dGhvbiB+Ly5h
  >> "!B64TMP!" echo Z2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbWFwLnB5ICJodHRwczov
  >> "!B64TMP!" echo L2V4YW1wbGUuY29tIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3Nj
  >> "!B64TMP!" echo cmlwdHMvd2ViX2NyYXdsLnB5ICJodHRwczovL2V4YW1wbGUuY29tIiAtLW1heC1wYWdlcyAxMApw
  >> "!B64TMP!" echo eXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3BhcnNl
  >> "!B64TMP!" echo LnB5ICJyZXBvcnQucGRmIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSAiZFF3NHc5V2dYY1EiCiMgb3B0aW9u
  >> "!B64TMP!" echo YWwgcHJlLWZsaWdodCBjaGVjayAvIHN0YXR1cyByZXBvcnQ6CnB5dGhvbiB+Ly5hZ2VudHMvc2tp
  >> "!B64TMP!" echo bGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkgLS1jaGVjawpgYGAK
  >> "!B64TMP!" echo ClRoZSBmdWxsIGFnZW50LWZhY2luZyBpbnN0cnVjdGlvbnMgbGl2ZSBpbiB0aGUgc2tpbGwncyBg
  >> "!B64TMP!" echo U0tJTEwubWRgLiBLZWVwaW5nIHRoZQpza2lsbCBmcmVzaCBpcyBhdXRvbWF0aWM6IGBVcGRhdGUu
  >> "!B64TMP!" echo YmF0YCAvIGAuL3VwZGF0ZS5zaGAgcmUtc3luY3MgaXQsIGFuZApyZS1ydW5uaW5nIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsZXIgb3ZlcndyaXRlcyBpdC4gVW5pbnN0YWxsaW5nIHJlbW92ZXMgaXQuCgo+IFRoZSBza2ls
  >> "!B64TMP!" echo bCBvbmx5IG5lZWRzICoqUHl0aG9uIDMuOCsqKiBvbiB0aGUgaG9zdCDigJQgbm8gQVBJIGtleXMs
  >> "!B64TMP!" echo IG5vIE1DUAo+IHN1cHBvcnQgcmVxdWlyZWQgZnJvbSB0aGUgYWdlbnQuIEV2ZXJ5IHRvb2wgaXMg
  >> "!B64TMP!" echo c3RkbGliLW9ubHkgZXhjZXB0Cj4gYHdlYl95b3V0dWJlX3RyYW5zY3JpcHQucHlgLCB3aGljaCBu
  >> "!B64TMP!" echo ZWVkcyAqKnl0LWRscCoqCj4gKGBwaXAgaW5zdGFsbCAtVSAieXQtZGxwW2RlZmF1bHRdImApIGFu
  >> "!B64TMP!" echo ZCBhIEphdmFTY3JpcHQgcnVudGltZSAoRGVubyBvciBOb2RlLmpzIDIyKykuCgotLS0KCiMjIyBC
  >> "!B64TMP!" echo LiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoKVGhlIHNpbXBsZXN0IHBvc3NpYmxlIGludGVncmF0
  >> "!B64TMP!" echo aW9uOiBoaXQgU2VhclhORydzIEpTT04gZW5kcG9pbnQgYW5kIGZlZWQgdGhlCnJlc3VsdHMgaW50
  >> "!B64TMP!" echo byBhbnkgbW9kZWwncyBjb250ZXh0LiBObyBTREssIG5vIGtleSwgbm8gTUNQLgoKYGBgYmFzaAoj
  >> "!B64TMP!" echo IFNlYXJjaCB0aGUgd2ViLCByZXR1cm4gSlNPTiwgc2hvdyB0aGUgdG9wIDUgcmVzdWx0cwpjdXJs
  >> "!B64TMP!" echo IC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9bGF0ZXN0K0FJK25ld3MmZm9ybWF0
  >> "!B64TMP!" echo PWpzb24iIFwKICB8IGpxICcucmVzdWx0c1s6NV0gfCAuW10gfCB7dGl0bGUsIHVybCwgY29udGVu
  >> "!B64TMP!" echo dH0nCmBgYAoKVXNlZnVsIHF1ZXJ5IHBhcmFtczogYCZwYWdlbm89MmAsIGAmY2F0ZWdvcmllcz1p
  >> "!B64TMP!" echo dCxpbWFnZXNgLCBgJnRpbWVfcmFuZ2U9ZGF5YCwKYCZsYW5ndWFnZT1lbmAsIGAmZW5naW5lcz1n
  >> "!B64TMP!" echo b29nbGUsYmluZyxkdWNrZHVja2dvYC4KCkluIFB5dGhvbjoKCmBgYHB5dGhvbgppbXBvcnQgcmVx
  >> "!B64TMP!" echo dWVzdHMKciA9IHJlcXVlc3RzLmdldCgiaHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaCIsIHBh
  >> "!B64TMP!" echo cmFtcz17CiAgICAicSI6ICJydXN0IGFzeW5jIHJ1bnRpbWUgdG9raW8iLAogICAgImZvcm1hdCI6
  >> "!B64TMP!" echo ICJqc29uIiwKICAgICJsYW5ndWFnZSI6ICJlbiIsCn0pLmpzb24oKQpmb3IgaGl0IGluIHJbInJl
  >> "!B64TMP!" echo c3VsdHMiXVs6NV06CiAgICBwcmludChoaXRbInRpdGxlIl0sICItPiIsIGhpdFsidXJsIl0pCiAg
  >> "!B64TMP!" echo ICBwcmludChoaXQuZ2V0KCJjb250ZW50IiwgIiIpWzoyMDBdKQpgYGAKCj4gU2VhclhORyByZXR1
  >> "!B64TMP!" echo cm5zIHRpdGxlcywgVVJMcywgYW5kIHNob3J0IGNvbnRlbnQgc25pcHBldHMg4oCUIHBlcmZlY3Qg
  >> "!B64TMP!" echo Zm9yIGEKPiAic2VhcmNoIHRoZW4gc3VtbWFyaXplIiBhZ2VudCBsb29wLiBGb3IgKipmdWxsIHBh
  >> "!B64TMP!" echo Z2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChDKS4KCi0tLQoKIyMjIEMuIERpcmVjdCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgUkVTVCBBUEkKCkZpcmVjcmF3bCB0dXJucyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24v
  >> "!B64TMP!" echo SFRNTC9KU09OIOKAlCBpZGVhbCBmb3IgUkFHLiBCZWNhdXNlCnRoZSBzZWxmLWhvc3RlZCBpbnN0
  >> "!B64TMP!" echo YW5jZSBydW5zIHdpdGggYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWAsICoqbm8gQVBJIGtl
  >> "!B64TMP!" echo eQppcyByZXF1aXJlZCoqICh5b3UgY2FuIHNlbmQgYW55IGBBdXRob3JpemF0aW9uOiBCZWFyZXIg
  >> "!B64TMP!" echo 4oCmYCBoZWFkZXIsIG9yIG5vbmUpLgoKIyMjIyBTY3JhcGUgYSBzaW5nbGUgcGFnZSDihpIgTWFy
  >> "!B64TMP!" echo a2Rvd24KCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9z
  >> "!B64TMP!" echo Y3JhcGUgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1
  >> "!B64TMP!" echo cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwiZm9ybWF0cyI6WyJtYXJrZG93biJdfScgXAogIHwg
  >> "!B64TMP!" echo anEgJy5kYXRhLm1hcmtkb3duJwpgYGAKCiMjIyMgU2VhcmNoIHRoZSB3ZWIgKHVzZXMgeW91ciBT
  >> "!B64TMP!" echo ZWFyWE5HIGludGVybmFsbHkpICsgcmV0dXJuIGZ1bGwgY29udGVudAoKYGBgYmFzaApjdXJsIC1z
  >> "!B64TMP!" echo IC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NlYXJjaCBcCiAgLUggIkNvbnRlbnQt
  >> "!B64TMP!" echo VHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InF1ZXJ5Ijoid2hhdCBpcyBydXN0IHBy
  >> "!B64TMP!" echo b2dyYW1taW5nIGxhbmd1YWdlIiwibGltaXQiOjV9JyBcCiAgfCBqcSAnLmRhdGFbOjNdIHwgLltd
  >> "!B64TMP!" echo IHwge3RpdGxlLCB1cmwsIG1hcmtkb3dufScKYGBgCgojIyMjIENyYXdsIGEgd2hvbGUgc2l0ZSAo
  >> "!B64TMP!" echo YXN5bmMpCgpgYGBiYXNoCiMgMSkgc3RhcnQgdGhlIGNyYXdsCkpPQj0kKGN1cmwgLXMgLVggUE9T
  >> "!B64TMP!" echo VCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wgXAogIC1IICJDb250ZW50LVR5cGU6IGFw
  >> "!B64TMP!" echo cGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2RvY3MuZXhhbXBsZS5jb20i
  >> "!B64TMP!" echo LCJsaW1pdCI6MjB9JyB8IGpxIC1yIC5pZCkKCiMgMikgcG9sbCB1bnRpbCBzdGF0dXMgPT0gImNv
  >> "!B64TMP!" echo bXBsZXRlZCIKY3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2NyYXdsLyRKT0IiIHwg
  >> "!B64TMP!" echo anEgJ3tzdGF0dXMsIGNvbXBsZXRlZCwgdG90YWx9JwpgYGAKCiMjIyMgTWFwIGEgc2l0ZSdzIFVS
  >> "!B64TMP!" echo TCB0cmVlIChmYXN0LCBubyBzY3JhcGluZykKCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6
  >> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MS92MS9tYXAgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9u
  >> "!B64TMP!" echo L2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwibGltaXQiOjUwfScg
  >> "!B64TMP!" echo fCBqcSAnLmxpbmtzJwpgYGAKCiMjIyMgRXh0cmFjdCBzdHJ1Y3R1cmVkIGRhdGEgd2l0aCBhbiBM
  >> "!B64TMP!" echo TE0gKG5lZWRzIHNlY3Rpb24gRCBjb25maWd1cmVkKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1Qg
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2V4dHJhY3QgXAogIC1IICJDb250ZW50LVR5cGU6IGFw
  >> "!B64TMP!" echo cGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmxzIjpbImh0dHBzOi8vZXhhbXBsZS5jb20iXSwi
  >> "!B64TMP!" echo cHJvbXB0IjoiRXh0cmFjdCB0aGUgY29tcGFueSBuYW1lIGFuZCBhIGNvbnRhY3QgZW1haWwifScg
  >> "!B64TMP!" echo XAogIHwganEgJy5kYXRhJwpgYGAKCiMjIyMgVXNpbmcgdGhlIEZpcmVjcmF3bCBTREtzIChOb2Rl
  >> "!B64TMP!" echo IC8gUHl0aG9uKQoKU2VsZi1ob3N0IHdvcmtzIHdpdGggdGhlIG9mZmljaWFsIFNES3Mg4oCUIHBv
  >> "!B64TMP!" echo aW50IHRoZW0gYXQgeW91ciBsb2NhbCBVUkwgYW5kIHBhc3MKYW55IG5vbi1lbXB0eSBzdHJpbmcg
  >> "!B64TMP!" echo YXMgdGhlIGtleToKCioqTm9kZS5qcyoqCmBgYGpzCmltcG9ydCBGaXJlY3Jhd2wgZnJvbSAiQG1l
  >> "!B64TMP!" echo bmRhYmxlL2ZpcmVjcmF3bC1qcyI7Cgpjb25zdCBmYyA9IG5ldyBGaXJlY3Jhd2woewogIGFwaUtl
  >> "!B64TMP!" echo eTogImZjLWxvY2FsIiwgICAgICAgICAgICAgIC8vIGFueSBub24tZW1wdHkgc3RyaW5nOyBzZWxm
  >> "!B64TMP!" echo LWhvc3QgZG9lc24ndCB2YWxpZGF0ZQogIGFwaVVybDogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIs
  >> "!B64TMP!" echo IC8vIDwtLSBwb2ludCBhdCB5b3VyIGxvY2FsIGluc3RhbmNlCn0pOwoKY29uc3QgeyBkYXRhIH0g
  >> "!B64TMP!" echo PSBhd2FpdCBmYy5zY3JhcGVVcmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCB7IGZvcm1hdHM6IFsi
  >> "!B64TMP!" echo bWFya2Rvd24iXSB9KTsKY29uc29sZS5sb2coZGF0YS5tYXJrZG93bik7CmBgYAoKKipQeXRob24q
  >> "!B64TMP!" echo KgpgYGBweXRob24KZnJvbSBmaXJlY3Jhd2wgaW1wb3J0IEZpcmVjcmF3bEFwcAoKZmMgPSBGaXJl
  >> "!B64TMP!" echo Y3Jhd2xBcHAoYXBpX2tleT0iZmMtbG9jYWwiLCBhcGlfdXJsPSJodHRwOi8vbG9jYWxob3N0Ojk5
  >> "!B64TMP!" echo OTEiKQpyZXN1bHQgPSBmYy5zY3JhcGVfdXJsKCJodHRwczovL2V4YW1wbGUuY29tIiwgcGFyYW1z
  >> "!B64TMP!" echo PXsiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pCnByaW50KHJlc3VsdFsibWFya2Rvd24iXSkKYGBg
  >> "!B64TMP!" echo CgotLS0KCiMjIyBELiBDb25uZWN0IGFuIExMTSAoTE0gU3R1ZGlvLCBldGMuKQoKQnkgZGVmYXVs
  >> "!B64TMP!" echo dCwgRmlyZWNyYXdsJ3MgYC92MS9zY3JhcGVgLCBgL3YxL2NyYXdsYCwgYC92MS9tYXBgLCBhbmQg
  >> "!B64TMP!" echo YC92MS9zZWFyY2hgCndvcmsgKip3aXRob3V0IGFueSBMTE0qKi4gVG8gdW5sb2NrICoqYC92MS9l
  >> "!B64TMP!" echo eHRyYWN0YCoqIChBSSBleHRyYWN0aW9uKSBhbmQgdGhlCmBzdW1tYXJ5YCBvdXRwdXQgZm9ybWF0
  >> "!B64TMP!" echo LCBwb2ludCBGaXJlY3Jhd2wgYXQgYW55ICoqT3BlbkFJLWNvbXBhdGlibGUqKiBlbmRwb2ludC4K
  >> "!B64TMP!" echo KipMTSBTdHVkaW8gaXMgdGhlIHJlY29tbWVuZGVkIGRlZmF1bHQqKiAocHJpb3JpdHkgb3ZlciBP
  >> "!B64TMP!" echo bGxhbWEpLgoKIyMjIyBSZWNvbW1lbmRlZDogTE0gU3R1ZGlvCgoxLiBJbnN0YWxsIFtMTSBTdHVk
  >> "!B64TMP!" echo aW9dKGh0dHBzOi8vbG1zdHVkaW8uYWkvKSwgZG93bmxvYWQgYSBtb2RlbCAoZS5nLiBgUXdlbjIu
  >> "!B64TMP!" echo NS03Qi1JbnN0cnVjdGApLgoyLiBHbyB0byB0aGUgKipEZXZlbG9wZXIqKiB0YWIg4oaSICoqU3Rh
  >> "!B64TMP!" echo cnQgU2VydmVyKiogb24gcG9ydCBgMTIzNGAgKGRlZmF1bHQpLgozLiAqKkVuYWJsZSAiU2VydmUg
  >> "!B64TMP!" echo b24gbG9jYWwgbmV0d29yayIqKiAocmVxdWlyZWQg4oCUIEZpcmVjcmF3bCBydW5zIGluIGEgY29u
  >> "!B64TMP!" echo dGFpbmVyCiAgIGFuZCByZWFjaGVzIHlvdXIgaG9zdCB2aWEgYGhvc3QuZG9ja2VyLmludGVybmFs
  >> "!B64TMP!" echo YCwgd2hpY2ggaXMgeW91ciBMQU4gSVAsIG5vdAogICBgMTI3LjAuMC4xYCkuCjQuIEVpdGhlcjoK
  >> "!B64TMP!" echo ICAgLSByZS1ydW4gdGhlIGluc3RhbGxlciAoc2V0dXAgKioyKiosIG9yICoqMyoqIGFuZCBhbnN3
  >> "!B64TMP!" echo ZXIgKip5KiogdG8gKiJDb25uZWN0CiAgICAgTExNIG5vdz8iKikg4oCUIGl0IGF1dG8tY29udmVy
  >> "!B64TMP!" echo dHMgYGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MWAg4oaSCiAgICAgYGh0dHA6Ly9ob3N0LmRvY2tl
  >> "!B64TMP!" echo ci5pbnRlcm5hbDoxMjM0L3YxYCBhbmQgd3JpdGVzIGl0IGludG8gYC5lbnZgOyAqKm9yKioKICAg
  >> "!B64TMP!" echo LSBlZGl0IGAuZW52YCBkaXJlY3RseSBhbmQgc2V0OgogICAgIGBgYGVudgogICAgIE9QRU5BSV9C
  >> "!B64TMP!" echo QVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQogICAgIE9QRU5BSV9B
  >> "!B64TMP!" echo UElfS0VZPWxtLXN0dWRpbwogICAgIE1PREVMX05BTUU9PHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4g
  >> "!B64TMP!" echo TE0gU3R1ZGlvPgogICAgIGBgYAo1LiBBcHBseSB3aXRoIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0
  >> "!B64TMP!" echo ZS5zaGAuCgojIyMjIE90aGVyIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlcnMgKHZMTE0sIGxsYW1h
  >> "!B64TMP!" echo LmNwcCBgc2VydmVyYCwgdGV4dC1nZW5lcmF0aW9uLWluZmVyZW5jZSwgTG9jYWxBSSwg4oCmKQoK
  >> "!B64TMP!" echo YGBgZW52Ck9QRU5BSV9CQVNFX1VSTD1odHRwOi8vPGhvc3Qtb3ItaXA+Ojxwb3J0Pi92MQpPUEVO
  >> "!B64TMP!" echo QUlfQVBJX0tFWT1wbGFjZWhvbGRlciAgICAgICMgYW55IG5vbi1lbXB0eSBzdHJpbmcgaWYgeW91
  >> "!B64TMP!" echo ciBzZXJ2ZXIgaWdub3JlcyBpdApNT0RFTF9OQU1FPTxtb2RlbCBpZCBmcm9tIEdFVCAvdjEvbW9k
  >> "!B64TMP!" echo ZWxzPgpgYGAKCkZvciBhIHJlbW90ZSBzZXJ2ZXIgb24gYW5vdGhlciBtYWNoaW5lLCB1c2UgaXRz
  >> "!B64TMP!" echo IElQIGRpcmVjdGx5IChlLmcuCmBodHRwOi8vMTkyLjE2OC4xLjUwOjgwMDAvdjFgKS4gRm9yIGEg
  >> "!B64TMP!" echo c2VydmVyIG9uIHRoZSAqKnNhbWUgaG9zdCBhcyBEb2NrZXIqKiwgdXNlCmBodHRwOi8vaG9zdC5k
  >> "!B64TMP!" echo b2NrZXIuaW50ZXJuYWw6PHBvcnQ+L3YxYC4KCiMjIyMgRmFsbGJhY2s6IE9sbGFtYQoKSWYgeW91
  >> "!B64TMP!" echo IHByZWZlciBPbGxhbWEsIHNldCAoRmlyZWNyYXdsIHJlYWRzIGBPTExBTUFfQkFTRV9VUkxgKToK
  >> "!B64TMP!" echo CmBgYGVudgpPTExBTUFfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0
  >> "!B64TMP!" echo L2FwaQpNT0RFTF9OQU1FPXF3ZW4yLjU6N2IKTU9ERUxfRU1CRURESU5HX05BTUU9bm9taWMtZW1i
  >> "!B64TMP!" echo ZWQtdGV4dApgYGAKClJlc3RhcnQgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLCB0
  >> "!B64TMP!" echo aGVuIGAvdjEvZXh0cmFjdGAgcm91dGVzIHRvIE9sbGFtYS4KCi0tLQoKIyMjIEUuIFZpYSBhbiBN
  >> "!B64TMP!" echo Q1Agc2VydmVyCgpUaGUgb2ZmaWNpYWwgWyoqRmlyZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6
  >> "!B64TMP!" echo Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikKZXhwb3NlcyBgZmly
  >> "!B64TMP!" echo ZWNyYXdsX3NlYXJjaGAsIGBmaXJlY3Jhd2xfc2NyYXBlYCwgYGZpcmVjcmF3bF9jcmF3bGAsIGBm
  >> "!B64TMP!" echo aXJlY3Jhd2xfbWFwYCwKYGZpcmVjcmF3bF9leHRyYWN0YCwgYW5kIHJlc2VhcmNoIHRvb2xzIHRv
  >> "!B64TMP!" echo IGFueSBNQ1AtY29tcGF0aWJsZSBjbGllbnQuIFBvaW50IGl0IGF0CnlvdXIgbG9jYWwgRmlyZWNy
  >> "!B64TMP!" echo YXdsIHdpdGggYEZJUkVDUkFXTF9BUElfVVJMYC4KCiMjIyMgQ2xhdWRlIERlc2t0b3AgKGBjbGF1
  >> "!B64TMP!" echo ZGVfZGVza3RvcF9jb25maWcuanNvbmApCgpgYGBqc29uCnsKICAibWNwU2VydmVycyI6IHsKICAg
  >> "!B64TMP!" echo ICJmaXJlY3Jhd2wiOiB7CiAgICAgICJjb21tYW5kIjogIm5weCIsCiAgICAgICJhcmdzIjogWyIt
  >> "!B64TMP!" echo eSIsICJmaXJlY3Jhd2wtbWNwIl0sCiAgICAgICJlbnYiOiB7CiAgICAgICAgIkZJUkVDUkFXTF9B
  >> "!B64TMP!" echo UElfVVJMIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIsCiAgICAgICAgIkZJUkVDUkFXTF9BUElf
  >> "!B64TMP!" echo S0VZIjogImZjLWxvY2FsIgogICAgICB9CiAgICB9CiAgfQp9CmBgYAoKIyMjIyBDdXJzb3IsIFZT
  >> "!B64TMP!" echo IENvZGUsIFdpbmRzdXJmLCBDb250aW51ZSwgQ2xpbmUsIGV0Yy4KClNhbWUgc2hhcGUg4oCUIGFk
  >> "!B64TMP!" echo ZCBhbiBgbWNwU2VydmVyc2AgZW50cnkgdG8gdGhhdCB0b29sJ3MgY29uZmlnIGZpbGUKKGB+Ly5j
  >> "!B64TMP!" echo dXJzb3IvbWNwLmpzb25gLCBgLnZzY29kZS9tY3AuanNvbmAsIGAuL2NvZGVpdW0vd2luZHN1cmYv
  >> "!B64TMP!" echo bW9kZWxfY29uZmlnLmpzb25gLCDigKYpLgoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAg
  >> "!B64TMP!" echo ICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsi
  >> "!B64TMP!" echo LXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JBV0xf
  >> "!B64TMP!" echo QVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCj4gVGhlIE1DUCBzZXJ2
  >> "!B64TMP!" echo ZXIgcnVucyBvbiB5b3VyIGhvc3QgKG5vdCBpbiBEb2NrZXIpLCBzbyBpdCByZWFjaGVzIEZpcmVj
  >> "!B64TMP!" echo cmF3bCBhdAo+IGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgLiAqKk5vIHJlYWwgQVBJIGtleSBpcyBu
  >> "!B64TMP!" echo ZWVkZWQqKiDigJQgYGZjLWxvY2FsYCBpcyBhCj4gcGxhY2Vob2xkZXI7IHRoZSBzZWxmLWhvc3Rl
  >> "!B64TMP!" echo ZCBGaXJlY3Jhd2wgZG9lc24ndCB2YWxpZGF0ZSBpdC4gUmVxdWlyZXMgTm9kZS5qcwo+IDE4KyBm
  >> "!B64TMP!" echo b3IgYG5weGAuCgo+ICoqTm90ZSBmb3IgbG9jYWwgbGxhbWEuY3BwIHNlcnZlcnM6KiogdGhlIEZp
  >> "!B64TMP!" echo cmVjcmF3bCBNQ1Agc2VydmVyIHNoaXBzIHZlcnkKPiBsYXJnZSB0b29sIGRlZmluaXRpb25zLCB3
  >> "!B64TMP!" echo aGljaCBjYW4gZXhjZWVkIHNvbWUgbG9jYWwgaW5mZXJlbmNlIHNlcnZlcnMnCj4gbGltaXRzIChl
  >> "!B64TMP!" echo LmcuIGxsYW1hLmNwcCdzIGBNQVhfUkVQRVRJVElPTl9USFJFU0hPTERgIG9mIDIwMDApLiBJZiB5
  >> "!B64TMP!" echo b3VyIGxvY2FsCj4gbW9kZWwgZmFpbHMgdG8gbG9hZCB0aGUgTUNQIHRvb2xzLCB1c2UgdGhlIGJ1
  >> "!B64TMP!" echo bmRsZWQgKipsb2NhbC13ZWItc2VhcmNoIHNraWxsKioKPiAoW3NlY3Rpb24gQV0oI2EtdGhlLWJ1
  >> "!B64TMP!" echo bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1yZWNvbW1lbmRlZCkpIGluc3RlYWQg4oCUIGl0
  >> "!B64TMP!" echo IHdvcmtzCj4gd2l0aCBhbnkgbW9kZWwgdGhhdCBjYW4gcnVuIGEgc2hlbGwgY29tbWFuZCwgYW5k
  >> "!B64TMP!" echo IGlzIHRoZSByZWNvbW1lbmRlZCBwYXRoIGZvcgo+IGxvY2FsIHNldHVwcyBhbnl3YXkuCgojIyMj
  >> "!B64TMP!" echo IFJ1biB0aGUgTUNQIHNlcnZlciBvdmVyIEhUVFAgKG9wdGlvbmFsKQoKYGBgYmFzaApIVFRQX1NU
  >> "!B64TMP!" echo UkVBTUFCTEVfU0VSVkVSPXRydWUgXApGSVJFQ1JBV0xfQVBJX1VSTD1odHRwOi8vbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTEgXApGSVJFQ1JBV0xfQVBJX0tFWT1mYy1sb2NhbCBcCm5weCAteSBmaXJlY3Jhd2wtbWNw
  >> "!B64TMP!" echo CiMgLT4gaHR0cDovL2xvY2FsaG9zdDozMDAwL21jcApgYGAKCi0tLQoKIyMjIEYuIFZpYSBwcm9t
  >> "!B64TMP!" echo cHRpbmcgKGFueSBjaGF0IFVJKQoKTm8gTUNQLCBubyBTREssIG5vIGNvZGUg4oCUIGp1c3QgdGVs
  >> "!B64TMP!" echo bCB0aGUgbW9kZWwgd2hlcmUgdGhlIHRvb2xzIGFyZS4gUGFzdGUgdGhpcwpzeXN0ZW0gcHJvbXB0
  >> "!B64TMP!" echo IGludG8gKipMTSBTdHVkaW8ncyBjaGF0KiosICoqT3BlbiBXZWJVSSoqLCAqKkNoYXRCb3gqKiwg
  >> "!B64TMP!" echo b3IgYW55IFVJCnRoYXQgbGV0cyB5b3Ugc2V0IGEgc3lzdGVtIHByb21wdCBhbmQgaGFzIGEgIndl
  >> "!B64TMP!" echo YiByZXF1ZXN0Ii9mdW5jdGlvbi90b29sIGZlYXR1cmU6CgpgYGAKWW91IGhhdmUgdHdvIGxvY2Fs
  >> "!B64TMP!" echo IHdlYiB0b29scyBydW5uaW5nIG9uIHRoaXMgbWFjaGluZS4gVXNlIHRoZW0gd2hlbmV2ZXIgdGhl
  >> "!B64TMP!" echo CnVzZXIgYXNrcyBhYm91dCBhbnl0aGluZyBjdXJyZW50IG9yIGFueXRoaW5nIHlvdSdyZSB1bnN1
  >> "!B64TMP!" echo cmUgYWJvdXQuCgoxKSBTRUFSQ0ggdGhlIHdlYiAocmV0dXJucyBKU09OOiB0aXRsZSwgdXJsLCBj
  >> "!B64TMP!" echo b250ZW50IGZvciBlYWNoIGhpdCk6CiAgIEdFVCBodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNo
  >> "!B64TMP!" echo P3E9PFVSTC1FTkNPREVELVFVRVJZPiZmb3JtYXQ9anNvbiZsYW5ndWFnZT1lbgogICBSZWFkIC5y
  >> "!B64TMP!" echo ZXN1bHRzW10gKGVhY2ggaGFzIC50aXRsZSwgLnVybCwgLmNvbnRlbnQpLgoKMikgUkVBRCBhIHdl
  >> "!B64TMP!" echo YiBwYWdlIGFzIGNsZWFuIE1hcmtkb3duIChubyBBUEkga2V5IG5lZWRlZCk6CiAgIFBPU1QgaHR0
  >> "!B64TMP!" echo cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFwZSAgIENvbnRlbnQtVHlwZTogYXBwbGljYXRpb24v
  >> "!B64TMP!" echo anNvbgogICBib2R5OiB7InVybCI6IjxVUkw+IiwiZm9ybWF0cyI6WyJtYXJrZG93biJdfQogICBS
  >> "!B64TMP!" echo ZWFkIC5kYXRhLm1hcmtkb3duLgoKV29ya2Zsb3c6IFNFQVJDSCB0byBmaW5kIFVSTHMsIHRoZW4g
  >> "!B64TMP!" echo U0NSQVBFIHRoZSBtb3N0IHJlbGV2YW50IDHigJMzIFVSTHMgZm9yIGZ1bGwKdGV4dCwgdGhlbiBh
  >> "!B64TMP!" echo bnN3ZXIgd2l0aCBjaXRhdGlvbnMuIElmIGEgc2VhcmNoIG9yIHNjcmFwZSBmYWlscywgcmV0cnkg
  >> "!B64TMP!" echo b25jZSB3aXRoIGEKZGlmZmVyZW50IHF1ZXJ5L1VSTC4gTmV2ZXIgaW52ZW50IFVSTHMg4oCUIG9u
  >> "!B64TMP!" echo bHkgdXNlIG9uZXMgcmV0dXJuZWQgYnkgU2VhclhORy4KYGBgCgpGb3IgVUlzIHRoYXQgb25seSBs
  >> "!B64TMP!" echo ZXQgeW91IHBhc3RlIFVSTHMgKG5vIHRvb2wgY2FsbGluZyksIHRoZSBtb2RlbCBjYW4gc3RpbGwK
  >> "!B64TMP!" echo ZW1pdCBgY3VybGAgY29tbWFuZHMgb3IgaW5zdHJ1Y3QgeW91IHRvIHJ1biB0aGVtOyBvciB5b3Ug
  >> "!B64TMP!" echo Y2FuIHdpcmUgdGhlIGVuZHBvaW50cwpiZWhpbmQgYSB0aW55IHByb3h5LiBUaGUgcG9pbnQgaXM6
  >> "!B64TMP!" echo IHRoZSBtb21lbnQgYSBtb2RlbCBjYW4gaXNzdWUgSFRUUCBHRVQvUE9TVCB0bwpgbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTBgIGFuZCBgbG9jYWxob3N0Ojk5OTFgLCBpdCBoYXMgZnVsbCB3ZWIgYWNjZXNzLgoKLS0t
  >> "!B64TMP!" echo CgojIyMgRy4gR1VJIGludGVncmF0aW9ucwoKfCBBcHAgfCBIb3cgfAp8LS0tLS18LS0tLS18Cnwg
  >> "!B64TMP!" echo KipPcGVuIFdlYlVJKiogfCBTZXR0aW5ncyDihpIgV2ViIFNlYXJjaCDihpIgU2VhclhORy4gU2V0
  >> "!B64TMP!" echo IGJhc2UgVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiBFbmFibGUgIlNlYXJjaCB0aGUgd2Vi
  >> "!B64TMP!" echo IiBpbiBjaGF0cy4gKEZvciBwYWdlIHJlYWRpbmcsIGFkZCB0aGUgU2VhclhORyByZXN1bHRzIHRv
  >> "!B64TMP!" echo IGNvbnRleHQgb3IgdXNlIGEgRmlyZWNyYXdsIHRvb2wuKSB8CnwgKipBbnl0aGluZ0xMTSoqIHwg
  >> "!B64TMP!" echo IldlYiBTZWFyY2giIHByb3ZpZGVyID0gU2VhclhORywgZW5kcG9pbnQgYGh0dHA6Ly9sb2NhbGhv
  >> "!B64TMP!" echo c3Q6OTk5MGAuIHwKfCAqKkRpZnkgLyBGbG93aXNlIC8gTGFuZ2Zsb3cqKiB8IEFkZCBhIFNlYXJY
  >> "!B64TMP!" echo TkcgdG9vbCBub2RlIGFuZCBhIEZpcmVjcmF3bCBIVFRQLXJlcXVlc3QgdG9vbCBub2RlIChVUkwg
  >> "!B64TMP!" echo YGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGVgKS4gfAp8ICoqbjhuIC8gWmFwaWVyLWlz
  >> "!B64TMP!" echo aCoqIHwgSFRUUCBSZXF1ZXN0IG5vZGVzIHRvIHRoZSB0d28gZW5kcG9pbnRzLiB8CnwgKipMYW5n
  >> "!B64TMP!" echo Q2hhaW4gLyBMbGFtYUluZGV4KiogfCBVc2UgYSBgUmVxdWVzdHNUb29sa2l0YCAvIGN1c3RvbSB0
  >> "!B64TMP!" echo b29sIHRoYXQgR0VUcy9QT1NUcyB0aGUgdHdvIFVSTHMuIHwKCi0tLQoKIyMgQ29uZmlndXJhdGlv
  >> "!B64TMP!" echo biByZWZlcmVuY2UKCkFsbCBydW50aW1lIGNvbmZpZyBsaXZlcyBpbiAqKmAuZW52YCoqIGluIHlv
  >> "!B64TMP!" echo dXIgaW5zdGFsbCBmb2xkZXIgKGdlbmVyYXRlZCBieSB0aGUKaW5zdGFsbGVyOyBkb2N1bWVudGVk
  >> "!B64TMP!" echo IGluIGAuZW52LmV4YW1wbGVgKS4gRWRpdCBpdCwgdGhlbiBydW4gYFVwZGF0ZS5iYXRgIC8KYC4v
  >> "!B64TMP!" echo dXBkYXRlLnNoYCB0byBhcHBseS4KCnwgVmFyaWFibGUgfCBEZWZhdWx0IHwgTWVhbmluZyB8Cnwt
  >> "!B64TMP!" echo LS0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS18CnwgYFNFQVJYTkdfUE9SVGAgfCBgOTk5MGAg
  >> "!B64TMP!" echo fCBIb3N0IHBvcnQgZm9yIHRoZSBTZWFyWE5HIFVJICsgSlNPTiBBUEkuIHwKfCBgRklSRUNSQVdM
  >> "!B64TMP!" echo X1BPUlRgIHwgYDk5OTFgIHwgSG9zdCBwb3J0IGZvciB0aGUgRmlyZWNyYXdsIEFQSS4gfAp8IGBT
  >> "!B64TMP!" echo RUFSWE5HX1NFQ1JFVGAgfCAqKHJhbmRvbSkqIHwgU2VhclhORyBzZXNzaW9uIHNlY3JldCDigJQg
  >> "!B64TMP!" echo YWxzbyBpbmplY3RlZCBpbnRvIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgLiB8CnwgYExP
  >> "!B64TMP!" echo Q0FMX1NFQVJDSF9FTkdJTkVgIHwgKihzZXQgYnkgdGhlIGluc3RhbGxlcikqIHwgYHBvZG1hbmAg
  >> "!B64TMP!" echo b3IgYGRvY2tlcmA6IHRoZSBjb250YWluZXIgZW5naW5lIGBydW4uc2hgIC8gYHN0b3Auc2hgIC8g
  >> "!B64TMP!" echo YHVwZGF0ZS5zaGAgLyBgdW5pbnN0YWxsLnNoYCBhbmQgdGhlIHNraWxsIHVzZS4gV2l0aG91dCBp
  >> "!B64TMP!" echo dDogUG9kbWFuIGlmIGluc3RhbGxlZCwgZWxzZSBEb2NrZXIuIEFuIGVudmlyb25tZW50IHZhcmlh
  >> "!B64TMP!" echo YmxlIG9mIHRoZSBzYW1lIG5hbWUgb3ZlcnJpZGVzIGl0LiB8CnwgYFNFQVJYTkdfTU9VTlRfT1BU
  >> "!B64TMP!" echo U2AgfCAqKGVtcHR5OyBgLHpgIG9uIFNFTGludXggaG9zdHMpKiB8IEV4dHJhIGJpbmQtbW91bnQg
  >> "!B64TMP!" echo b3B0aW9ucyBmb3IgU2VhclhORydzIGBjb25maWcvc2VhcnhuZ2AgZm9sZGVyLiBgLHpgIHJlbGFi
  >> "!B64TMP!" echo ZWxzIGl0IHNvIHRoZSBjb250YWluZXIgY2FuIHJlYWQgaXQgb24gRmVkb3JhL1JIRUw7IHdpdGhv
  >> "!B64TMP!" echo dXQgdGhhdCwgU2VhclhORyByZXN0YXJ0LWxvb3BzIHdpdGggYFBlcm1pc3Npb24gZGVuaWVkYC4g
  >> "!B64TMP!" echo fAp8IGBMT0NBTF9TRUFSQ0hfUEFVU0VgICooZW52aXJvbm1lbnQpKiB8IGBhdXRvYCB8IGBhdXRv
  >> "!B64TMP!" echo YDogdGhlIExpbnV4L21hY09TIHNjcmlwdHMgd2FpdCBmb3IgYSBrZXkgcHJlc3MgYmVmb3JlIGNs
  >> "!B64TMP!" echo b3Npbmcgd2hlbiBhIGxhdW5jaGVyIChmaWxlIG1hbmFnZXIsIGRlc2t0b3AgaWNvbikgb3BlbmVk
  >> "!B64TMP!" echo IHRoZWlyIHRlcm1pbmFsIHdpbmRvdzsgYDBgIG5ldmVyIHdhaXRzLCBgMWAgYWx3YXlzIHdhaXRz
  >> "!B64TMP!" echo LiB8CnwgYFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQYCB8IGB0cnVlYCAqKGBmYWxzZWAgb24gcm9v
  >> "!B64TMP!" echo dGxlc3MgUG9kbWFuKSogfCBXaGV0aGVyIFNlYXJYTkcncyBlbnRyeXBvaW50IHJlLW93bnMgdGhl
  >> "!B64TMP!" echo IG1vdW50ZWQgY29uZmlnIGZvbGRlci4gYGZhbHNlYCBrZWVwcyB0aGUgZmlsZXMgeW91cnMgdW5k
  >> "!B64TMP!" echo ZXIgcm9vdGxlc3MgUG9kbWFuLiB8CnwgYEJVTExfQVVUSF9LRVlgIHwgKihyYW5kb20pKiB8IFBy
  >> "!B64TMP!" echo b3RlY3RzIHRoZSAoZGlzYWJsZWQtYnktZGVmYXVsdCkgRmlyZWNyYXdsIHF1ZXVlIGFkbWluIFVJ
  >> "!B64TMP!" echo LiB8CnwgYFBPU1RHUkVTX0RCYCAvIGBQT1NUR1JFU19VU0VSYCAvIGBQT1NUR1JFU19QQVNTV09S
  >> "!B64TMP!" echo RGAgfCBgZmlyZWNyYXdsYCAvIGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBq
  >> "!B64TMP!" echo b2Itc3RhdGUgREIgY3JlZGVudGlhbHMuIHwKfCBgUkFCQklUTVFfVVNFUmAgLyBgUkFCQklUTVFf
  >> "!B64TMP!" echo UEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyAqKHJhbmRvbSkqIHwgRmlyZWNyYXdsIG1lc3NhZ2Ut
  >> "!B64TMP!" echo YnJva2VyIGNyZWRlbnRpYWxzLiB8CnwgYENPTVBPU0VfUFJPRklMRVNgIHwgYHBsYXl3cmlnaHRg
  >> "!B64TMP!" echo IHwgV2hpY2ggYnJvd3NlciBlbmdpbmUgYWN0dWFsbHkgc3RhcnRzOiBgcGxheXdyaWdodGAsIGBi
  >> "!B64TMP!" echo cm93c2VybGVzc2Agb3IgYGludmlzaWJsZWAgKGluc3RhbGxlciBTdGVwIDQpLiB8CnwgYFBMQVlX
  >> "!B64TMP!" echo UklHSFRfTUlDUk9TRVJWSUNFX1VSTGAgfCBgaHR0cDovL3BsYXl3cmlnaHQtc2VydmljZTozMDAw
  >> "!B64TMP!" echo L3NjcmFwZWAgfCBGaXJlY3Jhd2wncyBVUkwgZm9yIGl0cyBicm93c2VyIGVuZ2luZSDigJQgbXVz
  >> "!B64TMP!" echo dCBtYXRjaCBgQ09NUE9TRV9QUk9GSUxFU2AgKGBodHRwOi8vYnJvd3Nlcmxlc3M6MzAwMC9zY3Jh
  >> "!B64TMP!" echo cGVgIHdoZW4gdGhhdCdzIGBicm93c2VybGVzc2AsIGBodHRwOi8vaW52aXNpYmxlLXBsYXl3cmln
  >> "!B64TMP!" echo aHQ6MzAwMC9zY3JhcGVgIHdoZW4gaXQncyBgaW52aXNpYmxlYCkuIHwKfCBgQlJPV1NFUkxFU1Nf
  >> "!B64TMP!" echo VE9LRU5gIHwgKihyYW5kb20pKiB8IEF1dGggdG9rZW4gZm9yIHRoZSBCcm93c2VybGVzcyBzZXJ2
  >> "!B64TMP!" echo aWNlLiBPbmx5IHVzZWQgd2hlbiBgQ09NUE9TRV9QUk9GSUxFUz1icm93c2VybGVzc2A7IGhhcm1s
  >> "!B64TMP!" echo ZXNzIGlmIHVudXNlZC4gfAp8IGBJTlZJU0lCTEVfR0lUSFVCX1RPS0VOYCB8ICooZW1wdHkpKiB8
  >> "!B64TMP!" echo IE9wdGlvbmFsIEdpdEh1YiB0b2tlbiAobm8gc2NvcGVzKSB1c2VkIG9ubHkgd2hpbGUgKipidWls
  >> "!B64TMP!" echo ZGluZyoqIHRoZSBJbnZpc2libGUgUGxheXdyaWdodCBpbWFnZSwgdG8gYXZvaWQgR2l0SHViJ3Mg
  >> "!B64TMP!" echo YW5vbnltb3VzIHJhdGUgbGltaXQuIEJ1aWxkIGFyZ3VtZW50cyBhcmUgdmlzaWJsZSBpbiBgZG9j
  >> "!B64TMP!" echo a2VyIGhpc3RvcnlgIG9mIHRoYXQgbG9jYWwgaW1hZ2UuIHwKfCBgSU5WSVNJQkxFX1BST1hZX1NF
  >> "!B64TMP!" echo UlZFUmAgLyBgX1VTRVJOQU1FYCAvIGBfUEFTU1dPUkRgIHwgKihlbXB0eSkqIHwgT3B0aW9uYWwg
  >> "!B64TMP!" echo dXBzdHJlYW0gcHJveHkgZm9yIHRoZSBJbnZpc2libGUgUGxheXdyaWdodCBlbmdpbmUuIFdpdGgg
  >> "!B64TMP!" echo YSBwcm94eSBzZXQsIHRoZSBlbmdpbmUgZGVyaXZlcyBpdHMgdGltZXpvbmUgYW5kIGxhbmd1YWdl
  >> "!B64TMP!" echo IGZyb20gdGhlIHByb3h5J3MgZXhpdCBJUC4gfAp8IGBJTlZJU0lCTEVfTUFYX1BBR0VTYCB8IGA0
  >> "!B64TMP!" echo YCB8IFBhZ2VzIHRoZSBJbnZpc2libGUgUGxheXdyaWdodCBlbmdpbmUgcmVuZGVycyBhdCBvbmNl
  >> "!B64TMP!" echo IChGaXJlZm94IGlzIGhlYXZ5KS4gfAp8IGBJTlZJU0lCTEVfQkxPQ0tfQURTYCB8IGBmYWxzZWAg
  >> "!B64TMP!" echo fCBgdHJ1ZWAgbWFrZXMgdGhlIEludmlzaWJsZSBQbGF5d3JpZ2h0IGVuZ2luZSBkcm9wIHJlcXVl
  >> "!B64TMP!" echo c3RzIHRvIGEgc2hvcnQgbGlzdCBvZiBhZC90cmFja2VyIGhvc3RzLiB8CnwgYExPR0dJTkdfTEVW
  >> "!B64TMP!" echo RUxgIHwgYGluZm9gIHwgRmlyZWNyYXdsIGxvZyB2ZXJib3NpdHkgKGBkZWJ1Z2AvYGluZm9gL2B3
  >> "!B64TMP!" echo YXJuYC9gZXJyb3JgKS4gfAp8IGBPUEVOQUlfQkFTRV9VUkxgIHwgKih1bnNldCkqIHwgT3BlbkFJ
  >> "!B64TMP!" echo LWNvbXBhdGlibGUgTExNIGVuZHBvaW50IGZvciBgL3YxL2V4dHJhY3RgICsgc3VtbWFyaWVzLiBG
  >> "!B64TMP!" echo b3IgYSBzYW1lLWhvc3Qgc2VydmVyIHVzZSBgaHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjxw
  >> "!B64TMP!" echo b3J0Pi92MWAuIHwKfCBgT1BFTkFJX0FQSV9LRVlgIHwgKih1bnNldCkqIHwgQW55IG5vbi1lbXB0
  >> "!B64TMP!" echo eSBzdHJpbmcgKG1vc3QgbG9jYWwgc2VydmVycyBpZ25vcmUgaXQpLiB8CnwgYE1PREVMX05BTUVg
  >> "!B64TMP!" echo IHwgKih1bnNldCkqIHwgVGhlIG1vZGVsIGlkIHRvIHVzZS4gfAp8IGBPTExBTUFfQkFTRV9VUkxg
  >> "!B64TMP!" echo IHwgKih1bnNldCkqIHwgVXNlIGluc3RlYWQgb2YgYE9QRU5BSV8qYCBmb3IgYW4gT2xsYW1hIGJh
  >> "!B64TMP!" echo Y2tlbmQuIHwKClNlYXJYTkcgYmVoYXZpb3VyIChlbmdpbmVzLCBmb3JtYXRzLCBsaW1pdGVyKSBp
  >> "!B64TMP!" echo cyB0dW5lZCBpbgpgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYC4gVGhlIGRlZmF1bHRzIGVu
  >> "!B64TMP!" echo YWJsZSBKU09OIG91dHB1dCBhbmQgZGlzYWJsZSB0aGUKYm90IGxpbWl0ZXIuIFRvIGFkZC9yZW1v
  >> "!B64TMP!" echo dmUgZW5naW5lcywgZWRpdCB0aGF0IGZpbGUgYW5kIHJ1biBgVXBkYXRlLmJhdGAgLwpgLi91cGRh
  >> "!B64TMP!" echo dGUuc2hgICh0aGUgY29udGFpbmVyIHJlYWRzIGl0IGF0IHN0YXJ0KS4KClRoZSBsb2NhbC13ZWIt
  >> "!B64TMP!" echo c2VhcmNoIHNraWxsIG5lZWRzIG5vIGNvbmZpZ3VyYXRpb246IGl0IHJlYWRzIHRoZSBzYW1lIGAu
  >> "!B64TMP!" echo ZW52YCBhdApydW50aW1lLiBUaGUgb25seSBleHRyYSBmaWxlIGl0IHVzZXMgaXMgYGluc3RhbGwt
  >> "!B64TMP!" echo ZGlyLnR4dGAgKHdyaXR0ZW4gYnkgdGhlCmluc3RhbGxlciBuZXh0IHRvIHRoZSBza2lsbCdzIGBT
  >> "!B64TMP!" echo S0lMTC5tZGApLCB3aGljaCByZWNvcmRzIHRoZSBpbnN0YWxsIGZvbGRlciBzbwp0aGUgc2tpbGwg
  >> "!B64TMP!" echo Y2FuIHN0YXJ0IHRoZSBzdGFjayBldmVuIGZyb20gYSBub24tZGVmYXVsdCBsb2NhdGlvbi4gVG8g
  >> "!B64TMP!" echo cG9pbnQgdGhlCnNraWxsIGF0IGEgZGlmZmVyZW50IGZvbGRlciwgc2V0IHRoZSBgTE9DQUxfU0VB
  >> "!B64TMP!" echo UkNIX0RJUmAgZW52aXJvbm1lbnQgdmFyaWFibGUuCgotLS0KCiMjIFRyb3VibGVzaG9vdGluZwoK
  >> "!B64TMP!" echo KipTZWFyWE5HIHJlc3RhcnQtbG9vcHMgd2l0aCBgY2hvd246IC9ldGMvc2VhcnhuZzogUGVybWlz
  >> "!B64TMP!" echo c2lvbiBkZW5pZWRgLCBgY3A6IGNhbid0IHN0YXQgJy9ldGMvc2VhcnhuZy9zZXR0aW5ncy55bWwn
  >> "!B64TMP!" echo YCwgYCIvZXRjL3NlYXJ4bmcvc2V0dGluZ3MueW1sIiBpcyBub3QgYSB2YWxpZCBmaWxlLCBleGl0
  >> "!B64TMP!" echo aW5nLi4uYCAoRmVkb3JhIC8gUkhFTCkuKioKU0VMaW51eCBpcyBibG9ja2luZyB0aGUgY29udGFp
  >> "!B64TMP!" echo bmVyIGZyb20gcmVhZGluZyB0aGUgYmluZC1tb3VudGVkIGBjb25maWcvc2VhcnhuZ2AKZm9sZGVy
  >> "!B64TMP!" echo LiBUaGUgaW5zdGFsbGVyIGZpeGVzIHRoaXMgYnkgd3JpdGluZyBgU0VBUlhOR19NT1VOVF9PUFRT
  >> "!B64TMP!" echo PSx6YCB0byBgLmVudmAKKHRoZSBjb21wb3NlIGZpbGUgYXBwZW5kcyBpdCB0byB0aGUgbW91bnQp
  >> "!B64TMP!" echo LiBDaGVjayB3aXRoIGBncmVwIFNFQVJYTkcgLmVudmAgYW5kCmBnZXRlbmZvcmNlYCwgdGhlbiBy
  >> "!B64TMP!" echo dW4gYC4vcnVuLnNoYC4gSWYgeW91IHNldCB0aGUgc3RhY2sgdXAgd2l0aCBhbiBvbGRlcgppbnN0
  >> "!B64TMP!" echo YWxsZXIsIHJlLXJ1biB0aGUgY3VycmVudCBvbmUuIE9uIGEgZmlsZXN5c3RlbSB0aGF0IGNhbm5v
  >> "!B64TMP!" echo dCBiZSByZWxhYmVsbGVkCihORlMsIEZBVC9OVEZTKSwgaW5zdGFsbCB0byBhIGxvY2FsIGV4dDQv
  >> "!B64TMP!" echo eGZzL2J0cmZzIGZvbGRlciBpbnN0ZWFkLgpJZiB5b3Ugc3RhcnQgU2VhclhORyBieSBoYW5kIHJh
  >> "!B64TMP!" echo dGhlciB0aGFuIHRocm91Z2ggdGhpcyBzdGFjaywgYWRkIGA6emAgdG8gdGhlCmAtdmAgb3B0aW9u
  >> "!B64TMP!" echo LCBlLmcuIGAtdiAuL2NvbmZpZy9zZWFyeG5nOi9ldGMvc2VhcnhuZzp6YC4KCioqU2VhcmNoZXMg
  >> "!B64TMP!" echo YXJlIGVtcHR5IGFuZCBTZWFyWE5HJ3MgbG9nIHNheXMgYEZhaWxlZCB0byBjb25uZWN0IHRvIC4u
  >> "!B64TMP!" echo LiBvdmVyIHByb3h5IDEyNy4wLjAuMSBhZnRlciAwIG1zYC4qKgpQb2RtYW4gY29waWVzIHRoZSBw
  >> "!B64TMP!" echo cm94eSB2YXJpYWJsZXMgb2YgdGhlIHNoZWxsIHRoYXQgc3RhcnRlZCBpdCAoYGh0dHBfcHJveHlg
  >> "!B64TMP!" echo LApgaHR0cHNfcHJveHlgLCDigKYpIGludG8gZXZlcnkgY29udGFpbmVyIOKAlCBEb2NrZXIgZG9l
  >> "!B64TMP!" echo cyBub3QuIEEgdmFsdWUgbGlrZQpgaHR0cDovLzEyNy4wLjAuMTo3ODkwYCAodHlwaWNhbCB3aXRo
  >> "!B64TMP!" echo IGEgbG9jYWwgcHJveHkvVlBOIHRvb2wpIHBvaW50cyBhdCB0aGUKKmNvbnRhaW5lciBpdHNlbGYq
  >> "!B64TMP!" echo IHRoZXJlLCBzbyBldmVyeSBvdXRnb2luZyByZXF1ZXN0IGZhaWxzIGluc3RhbnRseS4gVGhlCmlu
  >> "!B64TMP!" echo c3RhbGxlciwgYHJ1bi5zaGAgYW5kIGB1cGRhdGUuc2hgIGxvb2sgYXQgd2hhdCB0aGUgY29udGFp
  >> "!B64TMP!" echo bmVycyBhY3R1YWxseSByZWNlaXZlZAphbmQsIGlmIGEgcHJveHkgdmFyaWFibGUgcG9pbnRzIGF0
  >> "!B64TMP!" echo IGBsb2NhbGhvc3RgL2AxMjcueGAvYDo6MWAsIGJsYW5rIGV4YWN0bHkgdGhvc2UKdmFyaWFibGVz
  >> "!B64TMP!" echo IHRocm91Z2ggYSBnZW5lcmF0ZWQgYGRvY2tlci1jb21wb3NlLm92ZXJyaWRlLnltbGAuIFByb3hp
  >> "!B64TMP!" echo ZXMgdGhhdCBwb2ludCBhdAphIHJlYWwgaG9zdCAoY29ycG9yYXRlLCBMQU4pIGFyZSBsZWZ0IGFs
  >> "!B64TMP!" echo b25lLiBUbyBzdG9wIGluaGVyaXRpbmcgdGhlbSBhdCBhbGwsIHJ1bgpgdW5zZXQgaHR0cF9wcm94
  >> "!B64TMP!" echo eSBodHRwc19wcm94eSBhbGxfcHJveHkgSFRUUF9QUk9YWSBIVFRQU19QUk9YWSBBTExfUFJPWFlg
  >> "!B64TMP!" echo IGJlZm9yZQpgLi9ydW4uc2hgLgoKKipTZWFyWE5HIGxvZ3MgYFdBUk5JTkcgIi9ldGMvc2Vhcnhu
  >> "!B64TMP!" echo ZyIgZGlyZWN0b3J5IGlzIG5vdCBvd25lZCBieSAic2VhcnhuZzpzZWFyeG5nImAuKioKSGFybWxl
  >> "!B64TMP!" echo c3MgYW5kIGV4cGVjdGVkIHdpdGggcm9vdGxlc3MgUG9kbWFuOiB0aGUgaW5zdGFsbGVyIHNldHMK
  >> "!B64TMP!" echo YFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQPWZhbHNlYCBzbyBTZWFyWE5HIGRvZXMgbm90IHJlLW93
  >> "!B64TMP!" echo biB5b3VyIGNvbmZpZyBmb2xkZXIKKHdoaWNoIHdvdWxkIGxvY2sgKnlvdSogb3V0IG9mIGVkaXRp
  >> "!B64TMP!" echo bmcgaXQpLiBTZWFyWE5HIHJlYWRzIHRoZSBmaWxlcyBmaW5lLgoKKipUaGUgaW5zdGFsbGVyIHdp
  >> "!B64TMP!" echo bmRvdyBjbG9zZXMgaW1tZWRpYXRlbHkgd2hlbiBJIHN0YXJ0IGl0IGZyb20gdGhlIGZpbGUgbWFu
  >> "!B64TMP!" echo YWdlci4qKgpJdCBub3cgd2FpdHMgZm9yIGEga2V5IHByZXNzIGJlZm9yZSBjbG9zaW5nIHdoZW5l
  >> "!B64TMP!" echo dmVyIGEgbGF1bmNoZXIgKG5vdCBhbgppbnRlcmFjdGl2ZSBzaGVsbCkgb3BlbmVkIHRoZSB0ZXJt
  >> "!B64TMP!" echo aW5hbCwgc28gdGhlIG91dHB1dCBzdGF5cyByZWFkYWJsZSDigJQgYWxzbyBmb3IgYHJ1bi5zaGAs
  >> "!B64TMP!" echo CmBzdG9wLnNoYCwgYHVwZGF0ZS5zaGAgYW5kIGB1bmluc3RhbGwuc2hgLiBgTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X1BBVVNFPTBgIHR1cm5zIGl0IG9mZi4KCioqYHBvZG1hbiBjb21wb3NlYCBmYWlscyB3aXRoICJD
  >> "!B64TMP!" echo YW5ub3QgY29ubmVjdCB0byB0aGUgRG9ja2VyIGRhZW1vbiAuLi4gcG9kbWFuLnNvY2siLioqClRo
  >> "!B64TMP!" echo ZSBDb21wb3NlIHYyIHByb3ZpZGVyIHRhbGtzIHRvIFBvZG1hbidzIEFQSSBzb2NrZXQuIFRoZSBp
  >> "!B64TMP!" echo bnN0YWxsZXIgdHJpZXMgdG8Kc3RhcnQgaXQ7IGlmIHRoYXQgaXMgbm90IHBvc3NpYmxlIChubyBz
  >> "!B64TMP!" echo eXN0ZW1kKSwgcnVuCmBzeXN0ZW1jdGwgLS11c2VyIGVuYWJsZSAtLW5vdyBwb2RtYW4uc29ja2V0
  >> "!B64TMP!" echo YCAocm9vdGZ1bDogYHN1ZG8gc3lzdGVtY3RsIGVuYWJsZSAtLW5vdyBwb2RtYW4uc29ja2V0YCku
  >> "!B64TMP!" echo CgoqKiJObyBjb21wb3NlIHByb3ZpZGVyIHdhcyBmb3VuZCBmb3IgUG9kbWFuIi4qKgpJbnN0YWxs
  >> "!B64TMP!" echo IG9uZTogYHN1ZG8gZG5mIGluc3RhbGwgZG9ja2VyLWNvbXBvc2VgIChvciBgcG9kbWFuLWNvbXBv
  >> "!B64TMP!" echo c2VgOwpEZWJpYW4vVWJ1bnR1OiBgc3VkbyBhcHQgaW5zdGFsbCBkb2NrZXItY29tcG9zZS12MmAp
  >> "!B64TMP!" echo LgoKKipCb3RoIFBvZG1hbiBhbmQgRG9ja2VyIGFyZSBpbnN0YWxsZWQgYW5kIEkgd2FudCBEb2Nr
  >> "!B64TMP!" echo ZXIuKioKYExPQ0FMX1NFQVJDSF9FTkdJTkU9ZG9ja2VyIC4vaW5zdGFsbC1sb2NhbC1zZWFyY2gu
  >> "!B64TMP!" echo c2hgIOKAlCBpdCBpcyByZWNvcmRlZCBpbgpgLmVudmAsIHNvIHRoZSBvdGhlciBzY3JpcHRzIGZv
  >> "!B64TMP!" echo bGxvdy4gKFBvZG1hbiBpcyB1c2VkIG9ubHkgd2hlbiB5b3UgZG8gbm90IGNob29zZS4pCgoqKlRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsZXIgc2F5cyB0aGUgY29udGFpbmVyIGVuZ2luZSAiZGlkIG5vdCBjb21lIG9ubGlu
  >> "!B64TMP!" echo ZSIuKioKVGhlIGluc3RhbGxlciBsYXVuY2hlcyBEb2NrZXIgRGVza3RvcCAvIHRoZSBkb2NrZXIg
  >> "!B64TMP!" echo c2VydmljZSB3aGVuIHRoZSBlbmdpbmUgaXMKZG93biwgdGhlbiB3YWl0cyB1cCB0byA1IG1pbnV0
  >> "!B64TMP!" echo ZXMgKG92ZXJyaWRlIHdpdGggdGhlIGBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVRgCmVudiB2
  >> "!B64TMP!" echo YXIsIGluIHNlY29uZHMpLiBJZiBpdCB0aW1lcyBvdXQsIHN0YXJ0IERvY2tlciB5b3Vyc2VsZiwg
  >> "!B64TMP!" echo d2FpdCB1bnRpbCBpdApyZXBvcnRzICJydW5uaW5nIiwgYW5kIHJlLXJ1biB0aGUgaW5zdGFsbGVy
  >> "!B64TMP!" echo IOKAlCBhbnl0aGluZyBpdCBhbHJlYWR5IHdyb3RlIGlzCnNhZmVseSBvdmVyd3JpdHRlbi4KCioq
  >> "!B64TMP!" echo YGRvY2tlciBjb21wb3NlIHVwYCBmYWlscyB3aXRoIGEgcG9ydCBhbHJlYWR5IGluIHVzZS4qKgpS
  >> "!B64TMP!" echo ZS1ydW4gdGhlIGluc3RhbGxlciBhbmQgcGljayBkaWZmZXJlbnQgcG9ydHMsIG9yIHN0b3Agd2hh
  >> "!B64TMP!" echo dGV2ZXIncyB1c2luZyA5OTkwLzk5OTEuCgoqKk9uZSBzaXRlIGFsd2F5cyBmYWlscyBvciBoYW5n
  >> "!B64TMP!" echo cyAoZS5nLiBgbWNraW5zZXkuY29tYCkgd2hpbGUgb3RoZXJzIHdvcmssIGFuZCB0aGUgbG9nIHNo
  >> "!B64TMP!" echo b3dzIGAxOTguMTgueC54YC4qKgpXaGVuIGEgcGFnZSBjYW5ub3QgYmUgbG9hZGVkLCB0aGUgc2tp
  >> "!B64TMP!" echo bGwncyBzY3JpcHRzIG5vdyBydW4gYSAqTmV0d29yayBjaGVjayogZnJvbSB0aGUKaG9zdCAoRE5T
  >> "!B64TMP!" echo IHBsdXMgb25lIHNob3J0IFRDUCBjb25uZWN0aW9uKSBhbmQgcHJpbnQgdGhlIHJlc3VsdC4gYDE5
  >> "!B64TMP!" echo OC4xOC4wLjAvMTVgIGlzIGEKcmVzZXJ2ZWQgYmVuY2htYXJraW5nIHJhbmdlIHRoYXQgcHJveHkv
  >> "!B64TMP!" echo VlBOIHRvb2xzIChDbGFzaCwgTWlob21vLCBTdXJnZSwgc2luZy1ib3gsIC4uLikKaGFuZCBvdXQg
  >> "!B64TMP!" echo aW4gKmZha2UtSVAqIEROUyBtb2RlIGFuZCB0aGVuIHJlbGF5IHRoZW1zZWx2ZXMuIElmIHRoZSB0
  >> "!B64TMP!" echo b29sIGlzIHN0b3BwZWQsIGl0cwpUVU4gLyBzeXN0ZW0td2lkZSBtb2RlIGlzIG9mZiwgb3IgYSBy
  >> "!B64TMP!" echo dWxlIGRyb3BzIHRoYXQgc2l0ZSwgZXZlcnkgcGFja2V0IHRvIHRoZSBmYWtlCmFkZHJlc3MgaXMg
  >> "!B64TMP!" echo c2lsZW50bHkgZGlzY2FyZGVkOiB0aGUgY29ubmVjdGlvbiB0aW1lcyBvdXQgd2l0aCAwIGJ5dGVz
  >> "!B64TMP!" echo LCBmcm9tIHRoZSBob3N0CmFuZCBmcm9tIHRoZSBjb250YWluZXJzIGFsaWtlLiBUaGF0IGlzIGEg
  >> "!B64TMP!" echo bmV0d29yay1sZXZlbCBibG9jaywgbm90IGEgdGVtcG9yYXJ5IHNpdGUKZXJyb3IsIHNvIHRoZSBz
  >> "!B64TMP!" echo Y3JpcHRzIGRvICoqbm90Kiogd2FpdCBhbmQgcmV0cnkgaXQuIEZpeCB0aGUgcGF0aCBpbnN0ZWFk
  >> "!B64TMP!" echo OiBzdGFydCB0aGUKdG9vbCBhbmQgZW5hYmxlIFRVTiBtb2RlLCBhZGQgdGhlIGRvbWFpbiB0byBp
  >> "!B64TMP!" echo dHMgYGZha2UtaXAtZmlsdGVyYCAob3IgYSBESVJFQ1QgcnVsZSksIG9yCnR1cm4gZmFrZS1JUCBE
  >> "!B64TMP!" echo TlMgb2ZmLCB0aGVuIHJ1biB0aGUgc2NyYXBlIGFnYWluLiAoVGhlIHN0YWNrIGFscmVhZHkgZGlz
  >> "!B64TMP!" echo YWJsZXMgRmlyZWNyYXdsJ3MKcHJpdmF0ZS1hZGRyZXNzIGd1YXJkLCBzbyBmYWtlLUlQcyBhcmUg
  >> "!B64TMP!" echo bmV2ZXIgcmVmdXNlZCB1cCBmcm9udDsgdGhleSBqdXN0IGhhdmUgdG8KYWN0dWFsbHkgYmUgY2Fy
  >> "!B64TMP!" echo cmllZC4pIEEgcGFnZSB0aGF0IG1lcmVseSB0aW1lcyBvdXQgd2hpbGUgdGhlIHN0YWNrIGlzIHJ1
  >> "!B64TMP!" echo bm5pbmcgbm8gbG9uZ2VyCnRyaWdnZXJzIGEgcG9pbnRsZXNzIHN0YWNrIHJlc3RhcnQgZWl0aGVy
  >> "!B64TMP!" echo LgoKKipTZWFyWE5HIHJldHVybnMgYDQyOSBUb28gTWFueSBSZXF1ZXN0c2Agb3IgYmxvY2tzIHJl
  >> "!B64TMP!" echo cXVlc3RzLioqCllvdSdyZSBoaXR0aW5nIGFuIGV4dGVybmFsIGVuZ2luZSdzIHJhdGUgbGltaXQg
  >> "!B64TMP!" echo KG5vdCBTZWFyWE5HIGl0c2VsZikuIFdhaXQgYQptaW51dGUsIG9yIGluIGBjb25maWcvc2Vhcnhu
  >> "!B64TMP!" echo Zy9zZXR0aW5ncy55bWxgIHJlbW92ZSB0aGUgb2ZmZW5kaW5nIGVuZ2luZSB1bmRlcgpgZW5naW5l
  >> "!B64TMP!" echo czpgLiBUaGUgaW50ZXJuYWwgbGltaXRlciBpcyBhbHJlYWR5IGRpc2FibGVkIGZvciBsb2NhbCB1
  >> "!B64TMP!" echo c2UuCgoqKmAvdjEvZXh0cmFjdGAgcmV0dXJucyBhbiBlcnJvciAvICJtb2RlbCBub3QgY29uZmln
  >> "!B64TMP!" echo dXJlZCIuKioKWW91IGhhdmVuJ3QgY29ubmVjdGVkIGFuIExMTSDigJQgc2VlIFtzZWN0aW9uIERd
  >> "!B64TMP!" echo KCNkLWNvbm5lY3QtYW4tbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEvY3Jh
  >> "!B64TMP!" echo d2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoKKipGaXJlY3Jh
  >> "!B64TMP!" echo d2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhlIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsICoqbm90KioK
  >> "!B64TMP!" echo YGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBsb2Nh
  >> "!B64TMP!" echo bCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJX0JBU0VfVVJM
  >> "!B64TMP!" echo PWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3RhbGxlciBkb2Vz
  >> "!B64TMP!" echo IHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZpcnN0
  >> "!B64TMP!" echo OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqVGhlIGxvY2FsLXdl
  >> "!B64TMP!" echo Yi1zZWFyY2ggc2tpbGwgY2FuJ3QgZmluZCB0aGUgaW5zdGFsbCBmb2xkZXIuKioKVGhlIHNraWxs
  >> "!B64TMP!" echo IGxvb2tzIGZvciB0aGUgY29tcG9zZSBmb2xkZXIgdmlhICgxKSB0aGUgYExPQ0FMX1NFQVJDSF9E
  >> "!B64TMP!" echo SVJgIGVudiB2YXIsCigyKSB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFp
  >> "!B64TMP!" echo bmVycywgKDMpIHRoZSBgaW5zdGFsbC1kaXIudHh0YApoaW50IHRoZSBpbnN0YWxsZXIgd3JvdGUg
  >> "!B64TMP!" echo bmV4dCB0byB0aGUgc2tpbGwsIGFuZCAoNCkgYH4vbG9jYWwtc2VhcmNoYC4gSWYgeW91Cm1vdmVk
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsIGZvbGRlciwgcmUtcnVuIHRoZSBpbnN0YWxsZXIgb3IgYFVwZGF0ZS5iYXRg
  >> "!B64TMP!" echo IC8gYC4vdXBkYXRlLnNoYAp0byByZWZyZXNoIHRoZSBoaW50IOKAlCBvciBleHBvcnQgYExPQ0FM
  >> "!B64TMP!" echo X1NFQVJDSF9ESVI9L3BhdGgvdG8vbG9jYWwtc2VhcmNoYC4KCioqVGhlIGFnZW50IGRvZXNuJ3Qg
  >> "!B64TMP!" echo c2VlIHRoZSBza2lsbCBhZnRlciBpbnN0YWxsLioqClNraWxscyBhcmUgdXN1YWxseSBzY2FubmVk
  >> "!B64TMP!" echo IGF0IGFnZW50IHN0YXJ0dXAg4oCUIHJlc3RhcnQgdGhlIGFnZW50LiBBbHNvIGNoZWNrIHRoZQpz
  >> "!B64TMP!" echo a2lsbCBhY3R1YWxseSBsYW5kZWQgYXQgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJj
  >> "!B64TMP!" echo aC9TS0lMTC5tZGAgKHRoZSBpbnN0YWxsZXIKcHJpbnRzIHdoZXJlIGl0IHB1dCBpdCkuCgoqKkZp
  >> "!B64TMP!" echo cnN0IGBkb2NrZXIgY29tcG9zZSBwdWxsYCBpcyBzbG93IC8gaGl0cyBhIEdIQ1IgNDAxLioqClRo
  >> "!B64TMP!" echo ZSBGaXJlY3Jhd2wgaW1hZ2VzIGFyZSBwdWJsaWMsIGJ1dCByYXRlLWxpbWl0ZWQuIEF1dGhlbnRp
  >> "!B64TMP!" echo Y2F0ZToKYGVjaG8gIiRHSVRIVUJfUEFUIiB8IGRvY2tlciBsb2dpbiBnaGNyLmlvIC11IFlPVVJf
  >> "!B64TMP!" echo R0hfVVNFUiAtLXBhc3N3b3JkLXN0ZGluYAoodG9rZW4gbmVlZHMgYHJlYWQ6cGFja2FnZXNgKSwg
  >> "!B64TMP!" echo dGhlbiByZS1ydW4gYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCioqQ29udGFpbmVycyBr
  >> "!B64TMP!" echo ZWVwIHJlc3RhcnRpbmcuKioKQ2hlY2sgbG9nczogYGRvY2tlciBjb21wb3NlIGxvZ3MgZmlyZWNy
  >> "!B64TMP!" echo YXdsYCAob3IgYHNlYXJ4bmdgKS4gVGhlIG1vc3QgY29tbW9uCmNhdXNlIGlzIGEgbWlzc2luZy9l
  >> "!B64TMP!" echo bXB0eSBgLmVudmAgdmFsdWUgKGUuZy4gYFJBQkJJVE1RX1BBU1NXT1JEYCkuIFJlLXJ1biB0aGUK
  >> "!B64TMP!" echo aW5zdGFsbGVyIHRvIHJlZ2VuZXJhdGUgYSBjbGVhbiBgLmVudmAuCgoqKlNlYXJYTkcgVUkgbG9h
  >> "!B64TMP!" echo ZHMgYnV0IGAvc2VhcmNoP2Zvcm1hdD1qc29uYCByZXR1cm5zIEhUTUwuKioKVGhlIEpTT04gZm9y
  >> "!B64TMP!" echo bWF0IGlzbid0IGVuYWJsZWQuIFlvdXIgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgbXVz
  >> "!B64TMP!" echo dCBjb250YWluCmBzZWFyY2g6IGZvcm1hdHM6IFtodG1sLCBqc29uXWAgKHRoZSBzaGlwcGVkIGNv
  >> "!B64TMP!" echo bmZpZyBkb2VzKS4gUmVzdGFydCB3aXRoCmBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgYWZ0
  >> "!B64TMP!" echo ZXIgZWRpdGluZy4KCioqUmVzZXQgZXZlcnl0aGluZyB0byBkZWZhdWx0cy4qKgpSdW4gYFVuaW5z
  >> "!B64TMP!" echo dGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYCAoZGVsZXRlcyB2b2x1bWVzICsgZGF0YSArIHRo
  >> "!B64TMP!" echo ZSBza2lsbCksCnRoZW4gcnVuIHRoZSBpbnN0YWxsZXIgYWdhaW4uCgotLS0KCiMjIFVwZGF0aW5n
  >> "!B64TMP!" echo ICYgdW5pbnN0YWxsaW5nCgotICoqVXBkYXRlIGltYWdlcyAmIGFwcGx5IGNvbmZpZyBjaGFuZ2Vz
  >> "!B64TMP!" echo ICYgcmUtc3luYyB0aGUgc2tpbGw6KiogYFVwZGF0ZS5iYXRgIC8KICBgLi91cGRhdGUuc2hgIChg
  >> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UgcHVsbCAmJiBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHRoZW4gcmUtY29w
  >> "!B64TMP!" echo eQogIGBsb2NhbC13ZWItc2VhcmNoYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlz
  >> "!B64TMP!" echo IHByZXNlcnZlZC4KLSAqKlVwZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2Nr
  >> "!B64TMP!" echo ZXItY29tcG9zZS55bWxgIHRlbXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0
  >> "!B64TMP!" echo IGNvcGllcyB0aGUgbGF0ZXN0IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwt
  >> "!B64TMP!" echo d2ViLXNlYXJjaGAgc2tpbGwsIGFuZCBiYWNrcyB1cCB5b3VyIGV4aXN0aW5nIGAuZW52YCB0byBg
  >> "!B64TMP!" echo LmVudi5iYWsuPHRpbWVzdGFtcD5gLgotICoqVW5pbnN0YWxsOioqIGBVbmluc3RhbGwuYmF0YCAv
  >> "!B64TMP!" echo IGAuL3VuaW5zdGFsbC5zaGAuIFJlbW92ZXMgY29udGFpbmVycyArIERvY2tlcgogIHZvbHVtZXMg
  >> "!B64TMP!" echo KGFsbCBGaXJlY3Jhd2wvU2VhclhORyBkYXRhKSArIHRoZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tp
  >> "!B64TMP!" echo bGwgZnJvbQogIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2hgLCB0aGVuIGFza3Mg
  >> "!B64TMP!" echo d2hldGhlciB0byBkZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyLgogIFB1bGxlZCBpbWFnZXMgcmVt
  >> "!B64TMP!" echo YWluOyByZWNsYWltIHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAuCgotLS0KCiMjIERldmVs
  >> "!B64TMP!" echo b3BtZW50OiBmdWxsIGRldiByaWcgKHJlYnVpbGRpbmcgZXZlcnl0aGluZykKClRoZSBgZnVsbC1k
  >> "!B64TMP!" echo ZXYtcmlnL2AgZm9sZGVyIGhvbGRzIHR3byBzZWxmLWNvbnRhaW5lZCBwYWNrZXJzIOKAlApgbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoLXJpZy5iYXRgIChXaW5kb3dzKSBhbmQgYGxvY2FsLXNlYXJjaC1yaWcuc2hgIChM
  >> "!B64TMP!" echo aW51eC9tYWNPUykg4oCUCnRoYXQgdW5wYWNrIHRoZSBjb21wbGV0ZSBidWlsZC90ZXN0IGVudmly
  >> "!B64TMP!" echo b25tZW50IGluIG9uZSBzaG90OiB0aGUKbG9jYWwtc2VhcmNoIHNvdXJjZSB0cmVlLCBgZ2VuX2lu
  >> "!B64TMP!" echo c3RhbGxlcnMucHlgIC8gYGdlbl9yaWcucHlgLCBldmVyeSB0ZXN0CnNjcmlwdCwgYW5kIGBCVUlM
  >> "!B64TMP!" echo RC5tZGAuCgoxLiAqKlJ1biBhIHBhY2tlcioqIOKAlCBgbG9jYWwtc2VhcmNoLXJpZy5iYXRgIChX
  >> "!B64TMP!" echo aW5kb3dzKSBvcgogICBgbG9jYWwtc2VhcmNoLXJpZy5zaGAgKExpbnV4L21hY09TKToKCiAgIGBg
  >> "!B64TMP!" echo YGJhdAogICBmdWxsLWRldi1yaWdcbG9jYWwtc2VhcmNoLXJpZy5iYXQKICAgYGBgCgogICBgYGBz
  >> "!B64TMP!" echo aAogICAuL2Z1bGwtZGV2LXJpZy9sb2NhbC1zZWFyY2gtcmlnLnNoCiAgIGBgYAoKICAgVGhlIGZp
  >> "!B64TMP!" echo cnN0IHByb21wdCBpcyAqKlRhcmdldCBmb2xkZXIqKjoKCiAgIHwgWW91IHR5cGUgfCBXaGF0IGhh
  >> "!B64TMP!" echo cHBlbnMgfAogICB8LS0tfC0tLXwKICAgfCBhIGZvbGRlciBwYXRoLCBvciBqdXN0ICoqRW50ZXIq
  >> "!B64TMP!" echo KiAoZGVmYXVsdDogYDxyaWcgZm9sZGVyPlxsb2NhbC1zZWFyY2gtZGV2YCkgfCBVbnBhY2tzIHRo
  >> "!B64TMP!" echo ZSByaWcgdGhlcmUuIFRoZW4gYHlgID0gYnVpbGQgdGhlIGluc3RhbGxlcnMgcmlnaHQgYXdheSwg
  >> "!B64TMP!" echo YHlgID0gY29uZmlybS4gfAogICB8ICoqMSoqIHwgKipVcGRhdGVzIHRoZSByZXBvIGF1dG9tYXRp
  >> "!B64TMP!" echo Y2FsbHkqKiAoc2VlIHN0ZXAgMikuIHwKCiAgIE51bWJlcmVkIGFuc3dlcnMgYXJlIHJlc2VydmVk
  >> "!B64TMP!" echo IGZvciBhY3Rpb25zOyBvbmx5IHRoZSBleGFjdCB0ZXh0IGAxYCBpcwogICBzcGVjaWFsLCBzbyBh
  >> "!B64TMP!" echo IGZvbGRlciBzdWNoIGFzIGAxYWJjYCBvciBgQzpcLi4uYCBzdGlsbCBtZWFucyAidW5wYWNrIHRo
  >> "!B64TMP!" echo ZXJlIi4KCjIuICoqVXBkYXRlIHRoZSByZXBvIGF1dG9tYXRpY2FsbHkqKiDigJQgcnVuIHRoZSBw
  >> "!B64TMP!" echo YWNrZXIgZnJvbSB0aGUgcmVwbydzCiAgIGBmdWxsLWRldi1yaWcvYCBmb2xkZXIgYW5kIGFuc3dl
  >> "!B64TMP!" echo ciAqKjEqKi4gVGhlIHJlcG8gaXMgZGV0ZWN0ZWQgKHRoZSBmb2xkZXIKICAgYWJvdmUgYGZ1bGwt
  >> "!B64TMP!" echo ZGV2LXJpZy9gIHRoYXQgY29udGFpbnMgYC5naXRgKSwgc28gbm90aGluZyBlbHNlIGlzIGFza2Vk
  >> "!B64TMP!" echo OyBydW4KICAgYSBwYWNrZXIgZnJvbSBhbnl3aGVyZSBlbHNlIGFuZCBpdCBhc2tzIGZvciB0aGUg
  >> "!B64TMP!" echo cmVwbyBmb2xkZXIgYW5kIGEKICAgY29uZmlybWF0aW9uIGZpcnN0LiBJdCB0aGVuOgoKICAgMS4g
  >> "!B64TMP!" echo YnVpbGRzIGV2ZXJ5dGhpbmcgaW4gYSB0ZW1wIGZvbGRlciBmaXJzdCAoaW5zdGFsbGVycywgdGhl
  >> "!B64TMP!" echo biBmcmVzaAogICAgICBwYWNrZXJzKSDigJQgaWYgdGhlIGJ1aWxkIGZhaWxzLCB0aGUgcmVwbyBp
  >> "!B64TMP!" echo cyBsZWZ0IHVudG91Y2hlZDsKICAgMi4gcmVwbGFjZXMgdGhlIHR3byBwYWNrZXJzIGluIGBmdWxs
  >> "!B64TMP!" echo LWRldi1yaWcvYCAobmV2ZXIgdGhlIG9uZSB0aGF0IGlzCiAgICAgIHJ1bm5pbmcpOwogICAzLiBk
  >> "!B64TMP!" echo ZWxldGVzIGV2ZXJ5dGhpbmcgaW4gdGhlIHJlcG8gZXhjZXB0IGAuZ2l0YCwgYC5naXRodWJgIGFu
  >> "!B64TMP!" echo ZAogICAgICBgZnVsbC1kZXYtcmlnYDsKICAgNC4gY29waWVzIHRoZSBmcmVzaGx5IGJ1aWx0IGBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gvYCBmaWxlcyAoZG90ZmlsZXMgaW5jbHVkZWQpIGludG8KICAgICAgdGhlIHJl
  >> "!B64TMP!" echo cG8gcm9vdDsKICAgNS4gbWFya3MgZXZlcnkgYCouc2hgIGFzIGV4ZWN1dGFibGUgaW4gZ2l0IChg
  >> "!B64TMP!" echo MTAwNzU1YCwgc3RhZ2VkIHdpdGgKICAgICAgYGdpdCBhZGQgLS1jaG1vZD0reGApIOKAlCB0aGUg
  >> "!B64TMP!" echo Yml0IGlzIG90aGVyd2lzZSBsb3N0IHdoZW5ldmVyIGZpbGVzIHBhc3MKICAgICAgdGhyb3VnaCBX
  >> "!B64TMP!" echo aW5kb3dzOwogICA2LiByZW1vdmVzIHRoZSB0ZW1wIGZvbGRlciBhbmQgc2hvd3MgYGdpdCBzdGF0
  >> "!B64TMP!" echo dXNgLgoKICAgTm90aGluZyBpcyBjb21taXR0ZWQgb3IgcHVzaGVkLCBhbmQgYC5naXRodWIvVkVS
  >> "!B64TMP!" echo U0lPTmAgaXMgcHJlc2VydmVkIOKAlCBidW1wIGl0CiAgIHlvdXJzZWxmIHdoZW4geW91IHdhbnQg
  >> "!B64TMP!" echo YSBuZXcgcmVsZWFzZS4gTmVlZHMgUHl0aG9uIDMuOCsuCgozLiAqKlJlZ2VuZXJhdGUgZXZlcnl0
  >> "!B64TMP!" echo aGluZyoqIGluc2lkZSB0aGUgdW5wYWNrZWQgZm9sZGVyOgoKICAgYGBgc2gKICAgcHl0aG9uIGdl
  >> "!B64TMP!" echo bl9pbnN0YWxsZXJzLnB5ICAgIyByZWJ1aWxkIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdC8uc2gK
  >> "!B64TMP!" echo ICAgcHl0aG9uIGdlbl9yaWcucHkgICAgICAgICAgIyByZWJ1aWxkIHRoZSB0d28gcGFja2VycyBi
  >> "!B64TMP!" echo eXRlLWZvci1ieXRlCiAgIGBgYAoKICAgRnJlc2ggaW5zdGFsbGVycyBhcmUgd3JpdHRlbiB0byBg
  >> "!B64TMP!" echo PHRhcmdldD5cbG9jYWwtc2VhcmNoXGAsIGFuZCBmcmVzaAogICBwYWNrZXJzIHJlcGxhY2UgdGhl
  >> "!B64TMP!" echo IHVucGFja2VkIGBsb2NhbC1zZWFyY2gtcmlnLipgIGNvcGllcy4gYEJVSUxELm1kYAogICAoaW5z
  >> "!B64TMP!" echo aWRlIHRoZSB1bnBhY2tlZCBmb2xkZXIpIGRvY3VtZW50cyB0aGUgdGVzdCBzY3JpcHRzCiAgIChg
  >> "!B64TMP!" echo dGVzdF9iNjQucHlgLCBgdGVzdF9yaWcucHlgLCBgZTJlX3Rlc3Quc2hgLCAuLi4pLgoKTm90ZTog
  >> "!B64TMP!" echo dGhlIHBhY2tlcnMgZW1iZWQgdGhlIHNvdXJjZSB0cmVlICoqYXMgb2Ygd2hlbiB0aGV5IHdlcmUK
  >> "!B64TMP!" echo Z2VuZXJhdGVkKiouIE1ha2Ugc291cmNlIGVkaXRzIGZpcnN0LCBvciBjb3B5IHRoZSBlZGl0ZWQg
  >> "!B64TMP!" echo ZmlsZXMgaW50byB0aGUKdW5wYWNrZWQgYGxvY2FsLXNlYXJjaC9gIGZvbGRlciwgYmVmb3JlIHJ1
  >> "!B64TMP!" echo bm5pbmcgdGhlIGdlbmVyYXRvcnMuCgojIyBTZWN1cml0eSBub3RlcwoKLSBUaGlzIHN0YWNrIGlz
  >> "!B64TMP!" echo IGRlc2lnbmVkIGZvciAqKmxvY2FsIC8gdHJ1c3RlZC1uZXR3b3JrIHVzZSoqLiBGaXJlY3Jhd2wn
  >> "!B64TMP!" echo cyBBUEkgaXMKICAqKnVuYXV0aGVudGljYXRlZCoqIChgVVNFX0RCX0FVVEhFTlRJQ0FUSU9OPWZh
  >> "!B64TMP!" echo bHNlYCkgc28geW91ciBtb2RlbHMgY2FuIGNhbGwgaXQKICB3aXRob3V0IGEga2V5LiAqKkRvIG5v
  >> "!B64TMP!" echo dCBleHBvc2UgcG9ydHMgOTk5MC85OTkxIHRvIHRoZSBwdWJsaWMgaW50ZXJuZXQuKioKLSBBbGwg
  >> "!B64TMP!" echo Y3JlZGVudGlhbHMgKGBTRUFSWE5HX1NFQ1JFVGAsIGBCVUxMX0FVVEhfS0VZYCwgYFBPU1RHUkVT
  >> "!B64TMP!" echo X1BBU1NXT1JEYCwKICBgUkFCQklUTVFfUEFTU1dPUkRgLCBgQlJPV1NFUkxFU1NfVE9LRU5gKSBh
  >> "!B64TMP!" echo cmUgZ2VuZXJhdGVkIGFzIDI1Ni1iaXQgcmFuZG9tIGhleAogIGF0IGluc3RhbGwgdGltZSBhbmQg
  >> "!B64TMP!" echo c3RvcmVkIG9ubHkgaW4geW91ciBsb2NhbCBgLmVudmAuCi0gU2VhclhORydzIGJvdCBsaW1pdGVy
  >> "!B64TMP!" echo IGlzIGRpc2FibGVkIGFuZCBKU09OIG91dHB1dCBpcyBlbmFibGVkIHNvIG1vZGVscyBjYW4KICBx
  >> "!B64TMP!" echo dWVyeSBpdCDigJQgdGhpcyBpcyBpbnRlbnRpb25hbCBmb3IgbG9jYWwgdXNlLiBPbiBhIHB1Ymxp
  >> "!B64TMP!" echo YyBpbnN0YW5jZSB5b3UnZCB3YW50CiAgdGhlIGxpbWl0ZXIgYmFjayBvbi4KLSBZb3VyIHNlYXJj
  >> "!B64TMP!" echo aCBxdWVyaWVzIGFuZCBzY3JhcGVkIHBhZ2UgY29udGVudHMgbmV2ZXIgbGVhdmUgeW91ciBtYWNo
  >> "!B64TMP!" echo aW5lCiAgKGV4Y2VwdCB0aGUgb3V0Ym91bmQgZmV0Y2hlcyBTZWFyWE5HL0ZpcmVjcmF3bCBtYWtl
  >> "!B64TMP!" echo IHRvIHRoZSBwdWJsaWMgd2ViLCB3aGljaAogIGlzIHRoZSB3aG9sZSBwb2ludCkuCgotLS0KCiMj
  >> "!B64TMP!" echo IENyZWRpdHMgJiBsaWNlbnNlcwoKVGhpcyBwcm9qZWN0IGlzIGxpY2Vuc2VkIHVuZGVyIHRoZSAq
  >> "!B64TMP!" echo Kk1QTC0yLjAqKiBsaWNlbnNlIOKAlCBzZWUgW0xJQ0VOU0VdKExJQ0VOU0UpCihpdCBjb3ZlcnMg
  >> "!B64TMP!" echo dGhlIGJ1bmRsZWQgW2xvY2FsLXdlYi1zZWFyY2hdKGxvY2FsLXdlYi1zZWFyY2gpIHNraWxsIHRv
  >> "!B64TMP!" echo bykuCgotIFsqKlNlYXJYTkcqKl0oaHR0cHM6Ly9naXRodWIuY29tL3NlYXJ4bmcvc2VhcnhuZykg
  >> "!B64TMP!" echo 4oCUIEFHUEwtMy4wLCBwcml2YWN5LXJlc3BlY3RpbmcgbWV0YXNlYXJjaCBlbmdpbmUuCi0gWyoq
  >> "!B64TMP!" echo RmlyZWNyYXdsKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsKSDigJQg
  >> "!B64TMP!" echo QUdQTC0zLjAsIHRoZSBjb250ZXh0IEFQSSBmb3Igd2ViIHNjcmFwaW5nL2NyYXdsaW5nL3NlYXJj
  >> "!B64TMP!" echo aC4KLSBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXShodHRwczovL2dpdGh1Yi5jb20vZmlyZWNy
  >> "!B64TMP!" echo YXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKSDigJQgTUlULgotIFsqKkludmlzaWJsZSBQbGF5d3Jp
  >> "!B64TMP!" echo Z2h0KipdKGh0dHBzOi8vZ2l0aHViLmNvbS9vc3MtaW52aXNpYmxlL3BsYXl3cmlnaHQpIOKAlCBN
  >> "!B64TMP!" echo SVQgLyBBcGFjaGUtMi4wIChvcHRpb25hbCB0aGlyZCBicm93c2VyIGVuZ2luZSwgYnVpbHQgbG9j
  >> "!B64TMP!" echo YWxseTsgdGhlIEZpcmVmb3ggaXQgcGF0Y2hlcyBrZWVwcyBpdHMgb3duIGxpY2Vuc2VzKS4KLSBU
  >> "!B64TMP!" echo aGUgdXBzdHJlYW0gcHJvamVjdHMgcmV0YWluIHRoZWlyIG93biBsaWNlbnNlcyDigJQgcGxlYXNl
  >> "!B64TMP!" echo IHJlc3BlY3QgdGhlbS4KICBOb3RoaW5nIGZyb20gdGhlbSBpcyBidW5kbGVkIGluIHRoaXMgcmVw
  >> "!B64TMP!" echo b3NpdG9yeTsgdGhlIGluc3RhbGxlciBvbmx5IHB1bGxzCiAgdGhlaXIgb2ZmaWNpYWwgY29udGFp
  >> "!B64TMP!" echo bmVyIGltYWdlcyBhdCBpbnN0YWxsIHRpbWUuCgotLS0KCjxzdWI+QnVpbHQgc28gYW55IGxvY2Fs
  >> "!B64TMP!" echo IG1vZGVsIOKAlCBpbiBMTSBTdHVkaW8gb3Igb3RoZXJ3aXNlIOKAlCBjYW4gc2VhcmNoIGFuZCBy
  >> "!B64TMP!" echo ZWFkCnRoZSB3ZWIgd2l0aG91dCBhIHBhaWQgQVBJIGtleS4gQ29udHJpYnV0aW9ucyB3ZWxjb21l
  >> "!B64TMP!" echo Ljwvc3ViPgo=
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
  >> "!B64TMP!" echo IG5vdCBlcnJvcmxldmVsIDEgZ290byBkb2NrZXJfcmVhZHkNCmNhbGwgOnN0YXJ0X2RvY2tlcg0K
  >> "!B64TMP!" echo aWYgZXJyb3JsZXZlbCAxICgNCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQo6ZG9ja2VyX3JlYWR5
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
  >> "!B64TMP!" echo ZSBTdG9wLmJhdCB0byBzdG9wIHRoZSBzdGFjay4NCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAwDQoN
  >> "!B64TMP!" echo CjpzdGFydF9kb2NrZXINClJFTSAgTGF1bmNoZXMgRG9ja2VyIERlc2t0b3AgYW5kIHdhaXRzIChM
  >> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQgcywgZGVmYXVsdCAzMDApDQpSRU0gIHVudGlsICJk
  >> "!B64TMP!" echo b2NrZXIgaW5mbyIgYW5zd2Vycy4gZXhpdCAvYiAwID0gZW5naW5lIG9ubGluZSwgMSA9IGNvdWxk
  >> "!B64TMP!" echo IG5vdCBzdGFydCBpdC4NClJFTSAgU2FtZSBibG9jayBpbiBSdW4uYmF0LCBVcGRhdGUuYmF0IGFu
  >> "!B64TMP!" echo ZCBVbmluc3RhbGwuYmF0IC0ga2VlcCB0aGVtIGlkZW50aWNhbC4NCmVjaG8gW05PVEVdIFRoZSBE
  >> "!B64TMP!" echo b2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nIC0gdHJ5aW5nIHRvIHN0YXJ0IERvY2tlciBEZXNr
  >> "!B64TMP!" echo dG9wLi4uDQpzZXQgIkREX0VYRT0iDQppZiBleGlzdCAiJVByb2dyYW1GaWxlcyVcRG9ja2VyXERv
  >> "!B64TMP!" echo Y2tlclxEb2NrZXIgRGVza3RvcC5leGUiIHNldCAiRERfRVhFPSVQcm9ncmFtRmlsZXMlXERvY2tl
  >> "!B64TMP!" echo clxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIg0KaWYgbm90IGRlZmluZWQgRERfRVhFIGlmIGV4
  >> "!B64TMP!" echo aXN0ICIlUHJvZ3JhbUZpbGVzKHg4NiklXERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhl
  >> "!B64TMP!" echo IiBzZXQgIkREX0VYRT0lUHJvZ3JhbUZpbGVzKHg4NiklXERvY2tlclxEb2NrZXJcRG9ja2VyIERl
  >> "!B64TMP!" echo c2t0b3AuZXhlIg0KaWYgbm90IGRlZmluZWQgRERfRVhFIGlmIGV4aXN0ICIlTE9DQUxBUFBEQVRB
  >> "!B64TMP!" echo JVxQcm9ncmFtc1xEb2NrZXIgRGVza3RvcFxEb2NrZXIgRGVza3RvcC5leGUiIHNldCAiRERfRVhF
  >> "!B64TMP!" echo PSVMT0NBTEFQUERBVEElXFByb2dyYW1zXERvY2tlciBEZXNrdG9wXERvY2tlciBEZXNrdG9wLmV4
  >> "!B64TMP!" echo ZSINCmlmIG5vdCBkZWZpbmVkIEREX0VYRSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIgRGVza3Rv
  >> "!B64TMP!" echo cCB3YXMgbm90IGZvdW5kIGluIHRoZSB1c3VhbCBpbnN0YWxsIGxvY2F0aW9ucy4NCiAgZWNobyAg
  >> "!B64TMP!" echo IFN0YXJ0IERvY2tlciB5b3Vyc2VsZiwgd2FpdCB1bnRpbCBpdCBzYXlzICJydW5uaW5nIiwgdGhl
  >> "!B64TMP!" echo biBydW4gdGhpcyBhZ2Fpbi4NCiAgZXhpdCAvYiAxDQopDQpzZXQgIkREX1RJTUVPVVQ9MzAwIg0K
  >> "!B64TMP!" echo aWYgZGVmaW5lZCBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQgc2V0ICJERF9USU1FT1VUPSFM
  >> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQhIg0KZWNobyAgICAgTGF1bmNoaW5nOiAiIUREX0VY
  >> "!B64TMP!" echo RSEiDQpzdGFydCAiIiAiIUREX0VYRSEiDQplY2hvICAgICBXYWl0aW5nIGZvciB0aGUgRG9ja2Vy
  >> "!B64TMP!" echo IGVuZ2luZSB0byBjb21lIG9ubGluZSAtIHVwIHRvICFERF9USU1FT1VUISBzZWNvbmRzLi4uDQpz
  >> "!B64TMP!" echo ZXQgL2EgRERfV0FJVD0wDQo6c3RhcnRfZG9ja2VyX3dhaXQNCnRpbWVvdXQgL3QgNSAvbm9icmVh
  >> "!B64TMP!" echo ayA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSBwaW5nIC1uIDYgMTI3LjAuMC4xID5udWwgMj4m
  >> "!B64TMP!" echo MQ0Kc2V0IC9hIEREX1dBSVQrPTUNCmRvY2tlciBpbmZvID5udWwgMj4mMQ0KaWYgbm90IGVycm9y
  >> "!B64TMP!" echo bGV2ZWwgMSAoDQogIGVjaG8gW09LXSBEb2NrZXIgZW5naW5lIGlzIG9ubGluZSBhZnRlciAhRERf
  >> "!B64TMP!" echo V0FJVCFzLg0KICBleGl0IC9iIDANCikNCmlmICFERF9XQUlUISBnZXEgIUREX1RJTUVPVVQhICgN
  >> "!B64TMP!" echo CiAgZWNobyBbRVJST1JdIFRoZSBEb2NrZXIgZW5naW5lIGRpZCBub3QgY29tZSBvbmxpbmUgd2l0
  >> "!B64TMP!" echo aGluICFERF9USU1FT1VUISBzZWNvbmRzLg0KICBlY2hvICAgQ2hlY2sgRG9ja2VyIERlc2t0b3Ag
  >> "!B64TMP!" echo Zm9yIGVycm9ycywgd2FpdCB1bnRpbCBpdCBzYXlzICJydW5uaW5nIiwgdGhlbiBydW4gdGhpcyBh
  >> "!B64TMP!" echo Z2Fpbi4NCiAgZXhpdCAvYiAxDQopDQpzZXQgL2EgIkREX01PRD1ERF9XQUlUICUlIDE1Ig0KaWYg
  >> "!B64TMP!" echo IUREX01PRCEgZXF1IDAgZWNobyAgICAgLi4uIHN0aWxsIHdhaXRpbmcgIUREX1dBSVQhcw0KZ290
  >> "!B64TMP!" echo byBzdGFydF9kb2NrZXJfd2FpdA0K
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
  >> "!B64TMP!" echo DQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlmIG5vdCBlcnJvcmxldmVsIDEgZ290byBkb2Nr
  >> "!B64TMP!" echo ZXJfcmVhZHkNCmNhbGwgOnN0YXJ0X2RvY2tlcg0KaWYgZXJyb3JsZXZlbCAxICgNCiAgcGF1c2UN
  >> "!B64TMP!" echo CiAgZXhpdCAvYiAxDQopDQo6ZG9ja2VyX3JlYWR5DQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0K
  >> "!B64TMP!" echo ICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hv
  >> "!B64TMP!" echo ICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZp
  >> "!B64TMP!" echo Z3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvIFVwZGF0aW5nIExvY2Fs
  >> "!B64TMP!" echo IFNlYXJjaC4uLg0KZWNoby4NCmVjaG8gWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uDQpk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBwdWxsDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZyB3aXRoIHdoYXQg
  >> "!B64TMP!" echo aXMgYXZhaWxhYmxlLg0KKQ0KUkVNICBUaGUgSW52aXNpYmxlIFBsYXl3cmlnaHQgZW5naW5lIGhh
  >> "!B64TMP!" echo cyBubyBwdWJsaXNoZWQgaW1hZ2U6IGl0IGlzIGJ1aWx0IGZyb20NClJFTSAgLlxpbnZpc2libGUt
  >> "!B64TMP!" echo cGxheXdyaWdodC4gUmVidWlsZCBpdCB3aXRob3V0IHRoZSBjYWNoZSBzbyBhIG5ld2VyIGVuZ2lu
  >> "!B64TMP!" echo ZSBpcyBwaWNrZWQgdXAuDQpmaW5kc3RyIC9iIC9jOiJDT01QT1NFX1BST0ZJTEVTPWludmlzaWJs
  >> "!B64TMP!" echo ZSIgIi5lbnYiID5udWwgMj4mMQ0KaWYgbm90IGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gICBSZWJ1
  >> "!B64TMP!" echo aWxkaW5nIHRoZSBJbnZpc2libGUgUGxheXdyaWdodCBlbmdpbmUgXihmcmVzaCBkb3dubG9hZCwg
  >> "!B64TMP!" echo fjEwIG1pbl4pLi4uDQogIGRvY2tlciBjb21wb3NlIGJ1aWxkIC0tcHVsbCAtLW5vLWNhY2hlIGlu
  >> "!B64TMP!" echo dmlzaWJsZS1wbGF5d3JpZ2h0DQogIGlmIGVycm9ybGV2ZWwgMSBlY2hvICAgW1dBUk5JTkddIFRo
  >> "!B64TMP!" echo ZSBlbmdpbmUgcmVidWlsZCBmYWlsZWQuIEtlZXBpbmcgdGhlIGV4aXN0aW5nIGVuZ2luZSBpbWFn
  >> "!B64TMP!" echo ZS4NCikNCg0KZWNoby4NCmVjaG8gWzIvM10gUmVjcmVhdGluZyBjb250YWluZXJzIHdpdGggdXBk
  >> "!B64TMP!" echo YXRlZCBpbWFnZXMgKGRhdGEgaXMgcHJlc2VydmVkKS4uLg0KZG9ja2VyIGNvbXBvc2UgdXAgLWQN
  >> "!B64TMP!" echo CmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8uDQogIGVjaG8gW0VSUk9SXSBGYWlsZWQgdG8gcmVj
  >> "!B64TMP!" echo cmVhdGUgY29udGFpbmVycy4gU2VlIG1lc3NhZ2VzIGFib3ZlLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDENCikNCg0KZWNoby4NCmVjaG8gWzMvM10gUmVmcmVzaGluZyB0aGUgbG9jYWwtd2ViLXNlYXJj
  >> "!B64TMP!" echo aCBhZ2VudCBza2lsbC4uLg0KaWYgZXhpc3QgIiV+ZHAwbG9jYWwtd2ViLXNlYXJjaFxTS0lMTC5t
  >> "!B64TMP!" echo ZCIgKA0KICBzZXQgIlNLSUxMX0RJUj0lVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzXGxvY2Fs
  >> "!B64TMP!" echo LXdlYi1zZWFyY2giDQogIGlmIGV4aXN0ICIhU0tJTExfRElSISIgcmQgL3MgL3EgIiFTS0lMTF9E
  >> "!B64TMP!" echo SVIhIg0KICBpZiBub3QgZXhpc3QgIiVVU0VSUFJPRklMRSVcLmFnZW50c1xza2lsbHMiIG1rZGly
  >> "!B64TMP!" echo ICIlVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tpbGxzIg0KICB4Y29weSAvRSAvSSAvWSAvUSAiJX5k
  >> "!B64TMP!" echo cDBsb2NhbC13ZWItc2VhcmNoIiAiIVNLSUxMX0RJUiEiID5udWwNCiAgaWYgZXJyb3JsZXZlbCAx
  >> "!B64TMP!" echo ICgNCiAgICBlY2hvICAgW1dBUk5JTkddIENvdWxkIG5vdCBjb3B5IHRoZSBza2lsbCB0byAhU0tJ
  >> "!B64TMP!" echo TExfRElSIS4NCiAgKSBlbHNlICgNCiAgICA+ICIhU0tJTExfRElSIVxpbnN0YWxsLWRpci50eHQi
  >> "!B64TMP!" echo IGVjaG8gJX5kcDANCiAgICBlY2hvICAgU2tpbGwgcmVmcmVzaGVkIGF0ICFTS0lMTF9ESVIhDQog
  >> "!B64TMP!" echo ICkNCikgZWxzZSAoDQogIGVjaG8gICBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHNvdXJjZSBub3Qg
  >> "!B64TMP!" echo Zm91bmQgaW4gdGhpcyBmb2xkZXIgLSBza2lwcGluZy4NCikNCg0KZWNoby4NCmVjaG8gVXBkYXRl
  >> "!B64TMP!" echo IGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2ZWQuDQplY2hvICAgLSBJZiB5b3Ug
  >> "!B64TMP!" echo Y2hhbmdlZCBwb3J0cyBvciBMTE0gc2V0dGluZ3MgaW4gLmVudiwgdGhleSBhcmUgbm93IGFwcGxp
  >> "!B64TMP!" echo ZWQuDQplY2hvICAgLSBUaGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCB3YXMgcmUtc3luY2VkIGZy
  >> "!B64TMP!" echo b20gdGhpcyBmb2xkZXIuDQplY2hvICAgLSBUbyB1cGRhdGUgdGhlIFNlYXJYTkcgc2V0dGluZ3Mu
  >> "!B64TMP!" echo eW1sIG9yIGRvY2tlci1jb21wb3NlLnltbCB0ZW1wbGF0ZSwNCmVjaG8gICAgIHJlLXJ1biBpbnN0
  >> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5iYXQgKGl0IGJhY2tzIHVwIHlvdXIgY3VycmVudCAuZW52KS4NCmVj
  >> "!B64TMP!" echo aG8uDQpwYXVzZQ0KZXhpdCAvYiAwDQoNCjpzdGFydF9kb2NrZXINClJFTSAgTGF1bmNoZXMgRG9j
  >> "!B64TMP!" echo a2VyIERlc2t0b3AgYW5kIHdhaXRzIChMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQgcywgZGVm
  >> "!B64TMP!" echo YXVsdCAzMDApDQpSRU0gIHVudGlsICJkb2NrZXIgaW5mbyIgYW5zd2Vycy4gZXhpdCAvYiAwID0g
  >> "!B64TMP!" echo ZW5naW5lIG9ubGluZSwgMSA9IGNvdWxkIG5vdCBzdGFydCBpdC4NClJFTSAgU2FtZSBibG9jayBp
  >> "!B64TMP!" echo biBSdW4uYmF0LCBVcGRhdGUuYmF0IGFuZCBVbmluc3RhbGwuYmF0IC0ga2VlcCB0aGVtIGlkZW50
  >> "!B64TMP!" echo aWNhbC4NCmVjaG8gW05PVEVdIFRoZSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nIC0gdHJ5
  >> "!B64TMP!" echo aW5nIHRvIHN0YXJ0IERvY2tlciBEZXNrdG9wLi4uDQpzZXQgIkREX0VYRT0iDQppZiBleGlzdCAi
  >> "!B64TMP!" echo JVByb2dyYW1GaWxlcyVcRG9ja2VyXERvY2tlclxEb2NrZXIgRGVza3RvcC5leGUiIHNldCAiRERf
  >> "!B64TMP!" echo RVhFPSVQcm9ncmFtRmlsZXMlXERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIg0KaWYg
  >> "!B64TMP!" echo bm90IGRlZmluZWQgRERfRVhFIGlmIGV4aXN0ICIlUHJvZ3JhbUZpbGVzKHg4NiklXERvY2tlclxE
  >> "!B64TMP!" echo b2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIiBzZXQgIkREX0VYRT0lUHJvZ3JhbUZpbGVzKHg4Nikl
  >> "!B64TMP!" echo XERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIg0KaWYgbm90IGRlZmluZWQgRERfRVhF
  >> "!B64TMP!" echo IGlmIGV4aXN0ICIlTE9DQUxBUFBEQVRBJVxQcm9ncmFtc1xEb2NrZXIgRGVza3RvcFxEb2NrZXIg
  >> "!B64TMP!" echo RGVza3RvcC5leGUiIHNldCAiRERfRVhFPSVMT0NBTEFQUERBVEElXFByb2dyYW1zXERvY2tlciBE
  >> "!B64TMP!" echo ZXNrdG9wXERvY2tlciBEZXNrdG9wLmV4ZSINCmlmIG5vdCBkZWZpbmVkIEREX0VYRSAoDQogIGVj
  >> "!B64TMP!" echo aG8gW0VSUk9SXSBEb2NrZXIgRGVza3RvcCB3YXMgbm90IGZvdW5kIGluIHRoZSB1c3VhbCBpbnN0
  >> "!B64TMP!" echo YWxsIGxvY2F0aW9ucy4NCiAgZWNobyAgIFN0YXJ0IERvY2tlciB5b3Vyc2VsZiwgd2FpdCB1bnRp
  >> "!B64TMP!" echo bCBpdCBzYXlzICJydW5uaW5nIiwgdGhlbiBydW4gdGhpcyBhZ2Fpbi4NCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQpzZXQgIkREX1RJTUVPVVQ9MzAwIg0KaWYgZGVmaW5lZCBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJ
  >> "!B64TMP!" echo TUVPVVQgc2V0ICJERF9USU1FT1VUPSFMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQhIg0KZWNo
  >> "!B64TMP!" echo byAgICAgTGF1bmNoaW5nOiAiIUREX0VYRSEiDQpzdGFydCAiIiAiIUREX0VYRSEiDQplY2hvICAg
  >> "!B64TMP!" echo ICBXYWl0aW5nIGZvciB0aGUgRG9ja2VyIGVuZ2luZSB0byBjb21lIG9ubGluZSAtIHVwIHRvICFE
  >> "!B64TMP!" echo RF9USU1FT1VUISBzZWNvbmRzLi4uDQpzZXQgL2EgRERfV0FJVD0wDQo6c3RhcnRfZG9ja2VyX3dh
  >> "!B64TMP!" echo aXQNCnRpbWVvdXQgL3QgNSAvbm9icmVhayA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSBwaW5n
  >> "!B64TMP!" echo IC1uIDYgMTI3LjAuMC4xID5udWwgMj4mMQ0Kc2V0IC9hIEREX1dBSVQrPTUNCmRvY2tlciBpbmZv
  >> "!B64TMP!" echo ID5udWwgMj4mMQ0KaWYgbm90IGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW09LXSBEb2NrZXIgZW5n
  >> "!B64TMP!" echo aW5lIGlzIG9ubGluZSBhZnRlciAhRERfV0FJVCFzLg0KICBleGl0IC9iIDANCikNCmlmICFERF9X
  >> "!B64TMP!" echo QUlUISBnZXEgIUREX1RJTUVPVVQhICgNCiAgZWNobyBbRVJST1JdIFRoZSBEb2NrZXIgZW5naW5l
  >> "!B64TMP!" echo IGRpZCBub3QgY29tZSBvbmxpbmUgd2l0aGluICFERF9USU1FT1VUISBzZWNvbmRzLg0KICBlY2hv
  >> "!B64TMP!" echo ICAgQ2hlY2sgRG9ja2VyIERlc2t0b3AgZm9yIGVycm9ycywgd2FpdCB1bnRpbCBpdCBzYXlzICJy
  >> "!B64TMP!" echo dW5uaW5nIiwgdGhlbiBydW4gdGhpcyBhZ2Fpbi4NCiAgZXhpdCAvYiAxDQopDQpzZXQgL2EgIkRE
  >> "!B64TMP!" echo X01PRD1ERF9XQUlUICUlIDE1Ig0KaWYgIUREX01PRCEgZXF1IDAgZWNobyAgICAgLi4uIHN0aWxs
  >> "!B64TMP!" echo IHdhaXRpbmcgIUREX1dBSVQhcw0KZ290byBzdGFydF9kb2NrZXJfd2FpdA0K
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
  >> "!B64TMP!" echo c2UuDQpjaGNwIDY1MDAxID5udWwNCg0KUkVNICBUaGUgY29udGFpbmVycyBjYW4gb25seSBiZSBy
  >> "!B64TMP!" echo ZW1vdmVkIHdoaWxlIHRoZSBlbmdpbmUgYW5zd2Vyczogc3RhcnQgRG9ja2VyDQpSRU0gIERlc2t0
  >> "!B64TMP!" echo b3AgaWYgaXQgaXMgZG93biAoZGVsZXRpbmcgdGhlIGZvbGRlciBhbnl3YXkgd291bGQgb3JwaGFu
  >> "!B64TMP!" echo IHRoZW0pLg0KZG9ja2VyIGluZm8gPm51bCAyPiYxDQppZiBub3QgZXJyb3JsZXZlbCAxIGdvdG8g
  >> "!B64TMP!" echo ZG9ja2VyX3JlYWR5DQpjYWxsIDpzdGFydF9kb2NrZXINCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVj
  >> "!B64TMP!" echo aG8gICBOb3RoaW5nIHdhcyByZW1vdmVkLiBTdGFydCBEb2NrZXIgRGVza3RvcCBhbmQgcnVuIHRo
  >> "!B64TMP!" echo aXMgYWdhaW4sIG9yIGRlbGV0ZQ0KICBlY2hvICAgdGhpcyBmb2xkZXIgbWFudWFsbHkgXih0aGUg
  >> "!B64TMP!" echo Y29udGFpbmVycyBhbmQgdm9sdW1lcyB3b3VsZCBzdGF5IGJlaGluZF4pLg0KICBwYXVzZQ0KICBl
  >> "!B64TMP!" echo eGl0IC9iIDENCikNCjpkb2NrZXJfcmVhZHkNCg0KZWNoby4NCmVjaG8gU3RvcHBpbmcgYW5kIHJl
  >> "!B64TMP!" echo bW92aW5nIGNvbnRhaW5lcnMgKyB2b2x1bWVzLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duIC12IC0t
  >> "!B64TMP!" echo cmVtb3ZlLW9ycGhhbnMNCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8uDQogIGVjaG8gW1dBUk5J
  >> "!B64TMP!" echo TkddIGRvY2tlciBjb21wb3NlIGRvd24gcmVwb3J0ZWQgZXJyb3JzLg0KICBlY2hvICAgWW91IG1h
  >> "!B64TMP!" echo eSBuZWVkIHRvIHJlbW92ZSBsZWZ0b3ZlciBjb250YWluZXJzIG1hbnVhbGx5LCBlLmcuOg0KICBl
  >> "!B64TMP!" echo Y2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLWZpcmVjcmF3bCBsb2NhbC1zZWFyY2gt
  >> "!B64TMP!" echo c2VhcnhuZw0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXJlZGlzIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC1yYWJiaXRtcQ0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXBv
  >> "!B64TMP!" echo c3RncmVzIGxvY2FsLXNlYXJjaC1wbGF5d3JpZ2h0IGxvY2FsLXNlYXJjaC1icm93c2VybGVzcyBs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gtaW52aXNpYmxlDQopDQoNCmVjaG8uDQplY2hvIENvbnRhaW5lcnMgYW5kIHZv
  >> "!B64TMP!" echo bHVtZXMgcmVtb3ZlZC4NCmVjaG8uDQplY2hvIFJlbW92aW5nIHRoZSBsb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo IGFnZW50IHNraWxsLi4uDQpzZXQgIlNLSUxMX0RJUj0lVVNFUlBST0ZJTEUlXC5hZ2VudHNcc2tp
  >> "!B64TMP!" echo bGxzXGxvY2FsLXdlYi1zZWFyY2giDQppZiBleGlzdCAiIVNLSUxMX0RJUiEiICgNCiAgcmQgL3Mg
  >> "!B64TMP!" echo L3EgIiFTS0lMTF9ESVIhIg0KICBlY2hvICAgUmVtb3ZlZCAhU0tJTExfRElSIQ0KKSBlbHNlICgN
  >> "!B64TMP!" echo CiAgZWNobyAgIFNraWxsIG5vdCBmb3VuZCBeKGFscmVhZHkgcmVtb3ZlZF4pIC0gbm90aGluZyB0
  >> "!B64TMP!" echo byBkby4NCikNCmVjaG8uDQpSRU0gIFRoZSBzZWNvbmQgcHJvbXB0IGFsc28gbmVlZHMgYSBjb2Rl
  >> "!B64TMP!" echo IHBhZ2Ugb3RoZXIgdGhhbiA2NTAwMSAoc2VlIHRvcCBvZiBmaWxlKS4NCmNoY3AgIUxTX1BST01Q
  >> "!B64TMP!" echo VF9DUCEgPm51bCAyPiYxDQpzZXQgIkRFTEZJTEVTPSINCnNldCAvcCBERUxGSUxFUz0iQWxzbyBk
  >> "!B64TMP!" echo ZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBBTEwgaXRzIGZpbGVzPyBbeS9OXTogIg0KaWYg
  >> "!B64TMP!" echo L2kgbm90ICIhREVMRklMRVMhIj09InkiICgNCiAgZWNoby4NCiAgZWNobyBVbmluc3RhbGwgZmlu
  >> "!B64TMP!" echo aXNoZWQuIFRoZSBmb2xkZXIgd2FzIGtlcHQ6DQogIGVjaG8gICAlQ0QlDQogIGVjaG8gICBZb3Ug
  >> "!B64TMP!" echo Y2FuIGRlbGV0ZSBpdCBtYW51YWxseSBpZiB5b3Ugbm8gbG9uZ2VyIG5lZWQgdGhlIHNjcmlwdHMu
  >> "!B64TMP!" echo DQogIGVjaG8uDQogIHBhdXNlDQogIGV4aXQgL2IgMA0KKQ0KDQpjZCAvZCAiJVVTRVJQUk9GSUxF
  >> "!B64TMP!" echo JSINCmVjaG8gRGVsZXRpbmcgaW5zdGFsbCBmb2xkZXI6ICV+ZHAwDQpyZCAvcyAvcSAiJX5kcDAi
  >> "!B64TMP!" echo DQplY2hvLg0KZWNobyBVbmluc3RhbGwgY29tcGxldGUuIEdvb2RieWUhDQplY2hvLg0KcGF1c2UN
  >> "!B64TMP!" echo CmV4aXQgL2IgMA0KDQo6c3RhcnRfZG9ja2VyDQpSRU0gIExhdW5jaGVzIERvY2tlciBEZXNrdG9w
  >> "!B64TMP!" echo IGFuZCB3YWl0cyAoTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUIHMsIGRlZmF1bHQgMzAwKQ0K
  >> "!B64TMP!" echo UkVNICB1bnRpbCAiZG9ja2VyIGluZm8iIGFuc3dlcnMuIGV4aXQgL2IgMCA9IGVuZ2luZSBvbmxp
  >> "!B64TMP!" echo bmUsIDEgPSBjb3VsZCBub3Qgc3RhcnQgaXQuDQpSRU0gIFNhbWUgYmxvY2sgaW4gUnVuLmJhdCwg
  >> "!B64TMP!" echo VXBkYXRlLmJhdCBhbmQgVW5pbnN0YWxsLmJhdCAtIGtlZXAgdGhlbSBpZGVudGljYWwuDQplY2hv
  >> "!B64TMP!" echo IFtOT1RFXSBUaGUgRG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZyAtIHRyeWluZyB0byBzdGFy
  >> "!B64TMP!" echo dCBEb2NrZXIgRGVza3RvcC4uLg0Kc2V0ICJERF9FWEU9Ig0KaWYgZXhpc3QgIiVQcm9ncmFtRmls
  >> "!B64TMP!" echo ZXMlXERvY2tlclxEb2NrZXJcRG9ja2VyIERlc2t0b3AuZXhlIiBzZXQgIkREX0VYRT0lUHJvZ3Jh
  >> "!B64TMP!" echo bUZpbGVzJVxEb2NrZXJcRG9ja2VyXERvY2tlciBEZXNrdG9wLmV4ZSINCmlmIG5vdCBkZWZpbmVk
  >> "!B64TMP!" echo IEREX0VYRSBpZiBleGlzdCAiJVByb2dyYW1GaWxlcyh4ODYpJVxEb2NrZXJcRG9ja2VyXERvY2tl
  >> "!B64TMP!" echo ciBEZXNrdG9wLmV4ZSIgc2V0ICJERF9FWEU9JVByb2dyYW1GaWxlcyh4ODYpJVxEb2NrZXJcRG9j
  >> "!B64TMP!" echo a2VyXERvY2tlciBEZXNrdG9wLmV4ZSINCmlmIG5vdCBkZWZpbmVkIEREX0VYRSBpZiBleGlzdCAi
  >> "!B64TMP!" echo JUxPQ0FMQVBQREFUQSVcUHJvZ3JhbXNcRG9ja2VyIERlc2t0b3BcRG9ja2VyIERlc2t0b3AuZXhl
  >> "!B64TMP!" echo IiBzZXQgIkREX0VYRT0lTE9DQUxBUFBEQVRBJVxQcm9ncmFtc1xEb2NrZXIgRGVza3RvcFxEb2Nr
  >> "!B64TMP!" echo ZXIgRGVza3RvcC5leGUiDQppZiBub3QgZGVmaW5lZCBERF9FWEUgKA0KICBlY2hvIFtFUlJPUl0g
  >> "!B64TMP!" echo RG9ja2VyIERlc2t0b3Agd2FzIG5vdCBmb3VuZCBpbiB0aGUgdXN1YWwgaW5zdGFsbCBsb2NhdGlv
  >> "!B64TMP!" echo bnMuDQogIGVjaG8gICBTdGFydCBEb2NrZXIgeW91cnNlbGYsIHdhaXQgdW50aWwgaXQgc2F5cyAi
  >> "!B64TMP!" echo cnVubmluZyIsIHRoZW4gcnVuIHRoaXMgYWdhaW4uDQogIGV4aXQgL2IgMQ0KKQ0Kc2V0ICJERF9U
  >> "!B64TMP!" echo SU1FT1VUPTMwMCINCmlmIGRlZmluZWQgTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUIHNldCAi
  >> "!B64TMP!" echo RERfVElNRU9VVD0hTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUISINCmVjaG8gICAgIExhdW5j
  >> "!B64TMP!" echo aGluZzogIiFERF9FWEUhIg0Kc3RhcnQgIiIgIiFERF9FWEUhIg0KZWNobyAgICAgV2FpdGluZyBm
  >> "!B64TMP!" echo b3IgdGhlIERvY2tlciBlbmdpbmUgdG8gY29tZSBvbmxpbmUgLSB1cCB0byAhRERfVElNRU9VVCEg
  >> "!B64TMP!" echo c2Vjb25kcy4uLg0Kc2V0IC9hIEREX1dBSVQ9MA0KOnN0YXJ0X2RvY2tlcl93YWl0DQp0aW1lb3V0
  >> "!B64TMP!" echo IC90IDUgL25vYnJlYWsgPm51bCAyPiYxDQppZiBlcnJvcmxldmVsIDEgcGluZyAtbiA2IDEyNy4w
  >> "!B64TMP!" echo LjAuMSA+bnVsIDI+JjENCnNldCAvYSBERF9XQUlUKz01DQpkb2NrZXIgaW5mbyA+bnVsIDI+JjEN
  >> "!B64TMP!" echo CmlmIG5vdCBlcnJvcmxldmVsIDEgKA0KICBlY2hvIFtPS10gRG9ja2VyIGVuZ2luZSBpcyBvbmxp
  >> "!B64TMP!" echo bmUgYWZ0ZXIgIUREX1dBSVQhcy4NCiAgZXhpdCAvYiAwDQopDQppZiAhRERfV0FJVCEgZ2VxICFE
  >> "!B64TMP!" echo RF9USU1FT1VUISAoDQogIGVjaG8gW0VSUk9SXSBUaGUgRG9ja2VyIGVuZ2luZSBkaWQgbm90IGNv
  >> "!B64TMP!" echo bWUgb25saW5lIHdpdGhpbiAhRERfVElNRU9VVCEgc2Vjb25kcy4NCiAgZWNobyAgIENoZWNrIERv
  >> "!B64TMP!" echo Y2tlciBEZXNrdG9wIGZvciBlcnJvcnMsIHdhaXQgdW50aWwgaXQgc2F5cyAicnVubmluZyIsIHRo
  >> "!B64TMP!" echo ZW4gcnVuIHRoaXMgYWdhaW4uDQogIGV4aXQgL2IgMQ0KKQ0Kc2V0IC9hICJERF9NT0Q9RERfV0FJ
  >> "!B64TMP!" echo VCAlJSAxNSINCmlmICFERF9NT0QhIGVxdSAwIGVjaG8gICAgIC4uLiBzdGlsbCB3YWl0aW5nICFE
  >> "!B64TMP!" echo RF9XQUlUIXMNCmdvdG8gc3RhcnRfZG9ja2VyX3dhaXQNCg==
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
  >> "!B64TMP!" echo cmF3bCArIFNlYXJYTkcpLgojIFVzZXMgUG9kbWFuIHdoZW4gaXQgaXMgaW5zdGFsbGVkLCBvdGhl
  >> "!B64TMP!" echo cndpc2UgRG9ja2VyIChzZWUgZW5naW5lLnNoOyBvdmVycmlkZQojIHdpdGggTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X0VOR0lORT1wb2RtYW58ZG9ja2VyIG9yIHRoZSBzYW1lIGxpbmUgaW4gLmVudikuCnNldCAtdQpj
  >> "!B64TMP!" echo ZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsK
  >> "!B64TMP!" echo ICBlY2hvICJbRVJST1JdIGVuZ2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJl
  >> "!B64TMP!" echo LXJ1biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVj
  >> "!B64TMP!" echo ayBzb3VyY2U9ZW5naW5lLnNoCi4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdCAgICAgICAg
  >> "!B64TMP!" echo ICAjIGtlZXAgYSBsYXVuY2hlci1vcGVuZWQgd2luZG93IG9wZW4gYXQgdGhlIGVuZApsc19yZXF1
  >> "!B64TMP!" echo aXJlX2VuZ2luZSBydW5uaW5nCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJS
  >> "!B64TMP!" echo T1JdIE5vIC5lbnYgZmlsZSBmb3VuZCBpbiB0aGlzIGZvbGRlci4gUnVuIGluc3RhbGwtbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLnNoIGZpcnN0LiIgPiYyCiAgZXhpdCAxCmZpCgplY2hvICJTdGFydGluZyBMb2NhbCBT
  >> "!B64TMP!" echo ZWFyY2ggKEZpcmVjcmF3bCArIFNlYXJYTkcpIHdpdGggJEVOR0lORV9OQU1FLi4uIgokREMgdXAg
  >> "!B64TMP!" echo LWQgfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0byBzdGFydC4iID4mMjsgZXhpdCAxOyB9CgpT
  >> "!B64TMP!" echo RUFSWE5HX1BPUlQ9IiQobHNfZW52X3ZhbHVlIC5lbnYgU0VBUlhOR19QT1JUKSI7IFNFQVJYTkdf
  >> "!B64TMP!" echo UE9SVD0iJHtTRUFSWE5HX1BPUlQ6LTk5OTB9IgpGSVJFQ1JBV0xfUE9SVD0iJChsc19lbnZfdmFs
  >> "!B64TMP!" echo dWUgLmVudiBGSVJFQ1JBV0xfUE9SVCkiOyBGSVJFQ1JBV0xfUE9SVD0iJHtGSVJFQ1JBV0xfUE9S
  >> "!B64TMP!" echo VDotOTk5MX0iCmVjaG8KbHNfdmVyaWZ5X3NlYXJ4bmcgIiRTRUFSWE5HX1BPUlQiIHx8IGV4aXQg
  >> "!B64TMP!" echo MQpsc19maXhfY29udGFpbmVyX3Byb3h5ICIkU0VBUlhOR19QT1JUIiB8fCBleGl0IDEKCmVjaG8K
  >> "!B64TMP!" echo ZWNobyAiTG9jYWwgU2VhcmNoIGlzIHJ1bm5pbmcuIgplY2hvICIgIFNlYXJYTkc6ICAgaHR0cDov
  >> "!B64TMP!" echo L2xvY2FsaG9zdDoke1NFQVJYTkdfUE9SVH0iCmVjaG8gIiAgRmlyZWNyYXdsOiBodHRwOi8vbG9j
  >> "!B64TMP!" echo YWxob3N0OiR7RklSRUNSQVdMX1BPUlR9IgplY2hvICJSdW4gLi9zdG9wLnNoIHRvIHN0b3AgdGhl
  >> "!B64TMP!" echo IHN0YWNrLiIK
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
  >> "!B64TMP!" echo IiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsKICBlY2hvICJbRVJST1JdIGVu
  >> "!B64TMP!" echo Z2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJlLXJ1biBpbnN0YWxsLWxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVjayBzb3VyY2U9ZW5naW5lLnNo
  >> "!B64TMP!" echo Ci4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdApsc19yZXF1aXJlX2VuZ2luZQoKaWYgWyAh
  >> "!B64TMP!" echo IC1mICIuZW52IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQuIE5v
  >> "!B64TMP!" echo dGhpbmcgdG8gc3RvcC4iID4mMjsgZXhpdCAxCmZpCgplY2hvICJTdG9wcGluZyBMb2NhbCBTZWFy
  >> "!B64TMP!" echo Y2ggY29udGFpbmVycyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgokREMgZG93biB8fCB7IGVjaG8g
  >> "!B64TMP!" echo IltFUlJPUl0gRmFpbGVkIHRvIHN0b3AuIiA+JjI7IGV4aXQgMTsgfQoKZWNobwplY2hvICJMb2Nh
  >> "!B64TMP!" echo bCBTZWFyY2ggc3RvcHBlZC4gRGF0YSBpcyBwcmVzZXJ2ZWQgaW4gJEVOR0lORV9OQU1FIHZvbHVt
  >> "!B64TMP!" echo ZXMuIgplY2hvICJSdW4gLi9ydW4uc2ggdG8gc3RhcnQgaXQgYWdhaW4uIgo=
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
  >> "!B64TMP!" echo JChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsKICBl
  >> "!B64TMP!" echo Y2hvICJbRVJST1JdIGVuZ2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJlLXJ1
  >> "!B64TMP!" echo biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVjayBz
  >> "!B64TMP!" echo b3VyY2U9ZW5naW5lLnNoCi4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdApsc19yZXF1aXJl
  >> "!B64TMP!" echo X2VuZ2luZSBydW5uaW5nCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJST1Jd
  >> "!B64TMP!" echo IE5vIC5lbnYgZmlsZSBmb3VuZC4gUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGZpcnN0LiIg
  >> "!B64TMP!" echo PiYyCiAgZXhpdCAxCmZpCgplY2hvICJVcGRhdGluZyBMb2NhbCBTZWFyY2ggKHVzaW5nICRFTkdJ
  >> "!B64TMP!" echo TkVfTkFNRSkuLi4iCmVjaG8KZWNobyAiWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uIgok
  >> "!B64TMP!" echo REMgcHVsbCB8fCBlY2hvICJbV0FSTklOR10gU29tZSBpbWFnZXMgZmFpbGVkIHRvIHB1bGwuIENv
  >> "!B64TMP!" echo bnRpbnVpbmcuIgojIFRoZSBJbnZpc2libGUgUGxheXdyaWdodCBlbmdpbmUgaGFzIG5vIHB1Ymxp
  >> "!B64TMP!" echo c2hlZCBpbWFnZTogaXQgaXMgYnVpbHQgZnJvbQojIC4vaW52aXNpYmxlLXBsYXl3cmlnaHQuIFJl
  >> "!B64TMP!" echo YnVpbGQgaXQgd2l0aG91dCB0aGUgY2FjaGUgc28gYSBuZXdlciBlbmdpbmUgaXMgcGlja2VkIHVw
  >> "!B64TMP!" echo LgpjYXNlICIkKGxzX2Vudl92YWx1ZSAuZW52IENPTVBPU0VfUFJPRklMRVMpIiBpbgogICppbnZp
  >> "!B64TMP!" echo c2libGUqKQogICAgZWNobyAiICAgICAgUmVidWlsZGluZyB0aGUgSW52aXNpYmxlIFBsYXl3cmln
  >> "!B64TMP!" echo aHQgZW5naW5lIChmcmVzaCBkb3dubG9hZCwgfjEwIG1pbikuLi4iCiAgICAkREMgYnVpbGQgLS1w
  >> "!B64TMP!" echo dWxsIC0tbm8tY2FjaGUgaW52aXNpYmxlLXBsYXl3cmlnaHQgXAogICAgICB8fCBlY2hvICJbV0FS
  >> "!B64TMP!" echo TklOR10gVGhlIGVuZ2luZSByZWJ1aWxkIGZhaWxlZC4gS2VlcGluZyB0aGUgZXhpc3RpbmcgZW5n
  >> "!B64TMP!" echo aW5lIGltYWdlLiIgOzsKZXNhYwoKZWNobwplY2hvICJbMi8zXSBSZWNyZWF0aW5nIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgokREMgdXAgLWQg
  >> "!B64TMP!" echo fHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiIgPiYyOyBl
  >> "!B64TMP!" echo eGl0IDE7IH0KU0VBUlhOR19QT1JUPSIkKGxzX2Vudl92YWx1ZSAuZW52IFNFQVJYTkdfUE9SVCki
  >> "!B64TMP!" echo OyBTRUFSWE5HX1BPUlQ9IiR7U0VBUlhOR19QT1JUOi05OTkwfSIKbHNfdmVyaWZ5X3NlYXJ4bmcg
  >> "!B64TMP!" echo IiRTRUFSWE5HX1BPUlQiOyBWRVJJRllfUkM9JD8KaWYgWyAiJFZFUklGWV9SQyIgLWVxIDAgXTsg
  >> "!B64TMP!" echo dGhlbiBsc19maXhfY29udGFpbmVyX3Byb3h5ICIkU0VBUlhOR19QT1JUIjsgVkVSSUZZX1JDPSQ/
  >> "!B64TMP!" echo OyBmaQoKZWNobwplY2hvICJbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFn
  >> "!B64TMP!" echo ZW50IHNraWxsLi4uIgppZiBbIC1mICIuL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiIF07IHRo
  >> "!B64TMP!" echo ZW4KICBTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2giCiAg
  >> "!B64TMP!" echo cm0gLXJmICIkU0tJTExfRElSIgogIG1rZGlyIC1wICIkSE9NRS8uYWdlbnRzL3NraWxscyIKICBp
  >> "!B64TMP!" echo ZiBjcCAtciAuL2xvY2FsLXdlYi1zZWFyY2ggIiRTS0lMTF9ESVIiOyB0aGVuCiAgICBwcmludGYg
  >> "!B64TMP!" echo JyVzXG4nICIkKHB3ZCkiID4gIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IgogICAgZWNobyAi
  >> "!B64TMP!" echo ICBTa2lsbCByZWZyZXNoZWQgYXQgJFNLSUxMX0RJUiIKICBlbHNlCiAgICBlY2hvICIgIFtXQVJO
  >> "!B64TMP!" echo SU5HXSBDb3VsZCBub3QgY29weSB0aGUgc2tpbGwgdG8gJFNLSUxMX0RJUi4iCiAgZmkKZWxzZQog
  >> "!B64TMP!" echo IGVjaG8gIiAgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBzb3VyY2Ugbm90IGZvdW5kIGluIHRoaXMg
  >> "!B64TMP!" echo Zm9sZGVyIC0gc2tpcHBpbmcuIgpmaQoKZWNobwppZiBbICIkVkVSSUZZX1JDIiAtbmUgMCBdOyB0
  >> "!B64TMP!" echo aGVuCiAgZWNobyAiVXBkYXRlIGZpbmlzaGVkLCBidXQgU2VhclhORyBvciB0aGUgY29udGFpbmVy
  >> "!B64TMP!" echo cycgcHJveHkgc2V0dGluZ3MgbmVlZCBhdHRlbnRpb24gLSBzZWUgdGhlIGRldGFpbHMgYWJvdmUu
  >> "!B64TMP!" echo IiA+JjIKICBleGl0IDEKZmkKZWNobyAiVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMgd2Vy
  >> "!B64TMP!" echo ZSBwcmVzZXJ2ZWQuIgplY2hvICIgIC0gUG9ydCAvIExMTSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5v
  >> "!B64TMP!" echo dyBhcHBsaWVkLiIKZWNobyAiICAtIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHdhcyByZS1z
  >> "!B64TMP!" echo eW5jZWQgZnJvbSB0aGlzIGZvbGRlci4iCmVjaG8gIiAgLSBUbyB1cGRhdGUgdGhlIFNlYXJYTkcg
  >> "!B64TMP!" echo c2V0dGluZ3MueW1sIG9yIGRvY2tlci1jb21wb3NlLnltbCB0ZW1wbGF0ZSwiCmVjaG8gIiAgICBy
  >> "!B64TMP!" echo ZS1ydW4gaW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggKGl0IGJhY2tzIHVwIHlvdXIgY3VycmVudCAu
  >> "!B64TMP!" echo ZW52KS4iCg==
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
  >> "!B64TMP!" echo ICAgLSBzdG9wcyAmIHJlbW92ZXMgY29udGFpbmVycwojICAgLSByZW1vdmVzIGNvbnRhaW5lciB2
  >> "!B64TMP!" echo b2x1bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLCByZWRpcywgcmFiYml0bXEsIHBvc3RncmVzKQoj
  >> "!B64TMP!" echo ICAgLSByZW1vdmVzIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsICh+Ly5hZ2VudHMv
  >> "!B64TMP!" echo c2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gpCiMgICAtIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIKc2V0IC11CmNkICIkKGRpcm5hbWUgIiQwIikiIHx8IGV4aXQgMQpsb3dlcigp
  >> "!B64TMP!" echo IHsgcHJpbnRmICclcycgIiQxIiB8IHRyICdbOnVwcGVyOl0nICdbOmxvd2VyOl0nOyB9ICAjIGJh
  >> "!B64TMP!" echo c2gtMy4yIChtYWNPUykgc2FmZQoKWyAtZiAiLi9lbmdpbmUuc2giIF0gfHwgewogIGVjaG8gIltF
  >> "!B64TMP!" echo UlJPUl0gZW5naW5lLnNoIGlzIG1pc3NpbmcgZnJvbSB0aGlzIGZvbGRlci4gUmUtcnVuIGluc3Rh
  >> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLnNoLiIgPiYyOyBleGl0IDE7IH0KIyBzaGVsbGNoZWNrIHNvdXJjZT1l
  >> "!B64TMP!" echo bmdpbmUuc2gKLiAuL2VuZ2luZS5zaApsc19wYXVzZV9vbl9leGl0CmlmICEgbHNfc2VsZWN0X2Vu
  >> "!B64TMP!" echo Z2luZSAiLi8uZW52IjsgdGhlbgogIGVjaG8gIiAgWW91IGNhbiBkZWxldGUgdGhpcyBmb2xkZXIg
  >> "!B64TMP!" echo bWFudWFsbHkuIiA+JjIKICBleGl0IDEKZmkKbHNfc2VsZWN0X2NvbXBvc2UgfHwgZXhpdCAxCmxz
  >> "!B64TMP!" echo X2Vuc3VyZV9wb2RtYW5fc29ja2V0IHx8IGVjaG8gIiAgWyFdIFBvZG1hbidzIEFQSSBzb2NrZXQg
  >> "!B64TMP!" echo aXMgbm90IGFjdGl2ZSAtIGlmIGNvbXBvc2UgZmFpbHMsIHJ1bjogc3lzdGVtY3RsIC0tdXNlciBl
  >> "!B64TMP!" echo bmFibGUgLS1ub3cgcG9kbWFuLnNvY2tldCIKCmlmIFsgISAtZiAiLmVudiIgXTsgdGhlbgogIGVj
  >> "!B64TMP!" echo aG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBOb3RoaW5nIHRvIHVuaW5zdGFsbC4iID4m
  >> "!B64TMP!" echo MjsgZXhpdCAxCmZpCgpjYXQgPDwnTVNHJwo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KICBVbmluc3RhbGwgTG9jYWwgU2VhcmNoCj09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PQpUaGlzIHdpbGw6CiAgMS4gU3RvcCBhbmQgcmVtb3ZlIGFsbCBMb2NhbCBTZWFyY2ggY29udGFp
  >> "!B64TMP!" echo bmVycy4KICAyLiBSZW1vdmUgdGhlIGNvbnRhaW5lciBWT0xVTUVTIChGaXJlY3Jhd2wgam9iIHN0
  >> "!B64TMP!" echo YXRlLCByZWRpcyBjYWNoZSwKICAgICByYWJiaXRtcS9wb3N0Z3JlcyBkYXRhKS4gVGhpcyBkZWxl
  >> "!B64TMP!" echo dGVzIGFsbCBzdG9yZWQgZGF0YS4KICAzLiBSZW1vdmUgdGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdl
  >> "!B64TMP!" echo bnQgc2tpbGwgZnJvbQogICAgIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaAogIDQu
  >> "!B64TMP!" echo IChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgYWxsIGl0cyBmaWxlcy4K
  >> "!B64TMP!" echo CiAgUHVsbGVkIGltYWdlcyBhcmUgTk9UIHJlbW92ZWQgKHVzZSAncG9kbWFuIGltYWdlIHBydW5l
  >> "!B64TMP!" echo JyBvcgogICdkb2NrZXIgaW1hZ2UgcHJ1bmUnIHRvIHJlY2xhaW0gdGhhdCBkaXNrIHNwYWNlIHNl
  >> "!B64TMP!" echo cGFyYXRlbHkpLgpNU0cKZWNobwpwcmludGYgIkNvbnRpbnVlIHdpdGggdW5pbnN0YWxsPyBbeS9O
  >> "!B64TMP!" echo XTogIgpyZWFkIC1yIENPTkZJUk0KaWYgWyAiJChsb3dlciAiJENPTkZJUk0iKSIgIT0gInkiIF07
  >> "!B64TMP!" echo IHRoZW4gZWNobyAiVW5pbnN0YWxsIGNhbmNlbGxlZC4iOyBleGl0IDA7IGZpCgojIFRoZSBjb250
  >> "!B64TMP!" echo YWluZXJzIGNhbiBvbmx5IGJlIHJlbW92ZWQgd2hpbGUgdGhlIGVuZ2luZSBhbnN3ZXJzOiBzdGFy
  >> "!B64TMP!" echo dCBpdCBpZiBpdCBpcwojIGRvd24gKGRlbGV0aW5nIHRoZSBmb2xkZXIgd2l0aG91dCB0aGlzIHdv
  >> "!B64TMP!" echo dWxkIG9ycGhhbiBjb250YWluZXJzIGFuZCB2b2x1bWVzKS4KaWYgISBsc19lbnN1cmVfcnVubmlu
  >> "!B64TMP!" echo ZzsgdGhlbgogIGxzX2VyciAiVGhlICRFTkdJTkVfTkFNRSBlbmdpbmUgaXMgbm90IHJ1bm5pbmcg
  >> "!B64TMP!" echo YW5kIGNvdWxkIG5vdCBiZSBzdGFydGVkIGF1dG9tYXRpY2FsbHkuIgogIGxzX2VuZ2luZV9oaW50
  >> "!B64TMP!" echo CiAgZWNobyAiICBOb3RoaW5nIHdhcyByZW1vdmVkLiBTdGFydCB0aGUgZW5naW5lIGFuZCBydW4g
  >> "!B64TMP!" echo dGhpcyBhZ2FpbiwiID4mMgogIGVjaG8gIiAgb3IgZGVsZXRlIHRoaXMgZm9sZGVyIG1hbnVhbGx5
  >> "!B64TMP!" echo IChjb250YWluZXJzIGFuZCB2b2x1bWVzIHdvdWxkIHN0YXkgYmVoaW5kKS4iID4mMgogIGV4aXQg
  >> "!B64TMP!" echo MQpmaQpsc19zZWxlY3RfY29tcG9zZSB8fCBleGl0IDEgICAjIHRoZSBlbmdpbmUgbWF5IGhhdmUg
  >> "!B64TMP!" echo Y2hhbmdlZCB0byBEb2NrZXIKbHNfZW5zdXJlX3BvZG1hbl9zb2NrZXQgfHwgZWNobyAiICBbIV0g
  >> "!B64TMP!" echo UG9kbWFuJ3MgQVBJIHNvY2tldCBpcyBub3QgYWN0aXZlIC0gaWYgY29tcG9zZSBmYWlscywgcnVu
  >> "!B64TMP!" echo OiBzeXN0ZW1jdGwgLS11c2VyIGVuYWJsZSAtLW5vdyBwb2RtYW4uc29ja2V0IgoKZWNobwplY2hv
  >> "!B64TMP!" echo ICJTdG9wcGluZyBhbmQgcmVtb3ZpbmcgY29udGFpbmVycyArIHZvbHVtZXMuLi4iCiREQyBkb3du
  >> "!B64TMP!" echo IC12IC0tcmVtb3ZlLW9ycGhhbnMgfHwgZWNobyAiW1dBUk5JTkddIGRvY2tlciBjb21wb3NlIGRv
  >> "!B64TMP!" echo d24gcmVwb3J0ZWQgZXJyb3JzLiIKCmVjaG8KZWNobyAiQ29udGFpbmVycyBhbmQgdm9sdW1lcyBy
  >> "!B64TMP!" echo ZW1vdmVkLiIKZWNobwplY2hvICJSZW1vdmluZyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBz
  >> "!B64TMP!" echo a2lsbC4uLiIKU0tJTExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
  >> "!B64TMP!" echo IgppZiBbIC1kICIkU0tJTExfRElSIiBdOyB0aGVuCiAgcm0gLXJmICIkU0tJTExfRElSIgogIGVj
  >> "!B64TMP!" echo aG8gIiAgUmVtb3ZlZCAkU0tJTExfRElSIgplbHNlCiAgZWNobyAiICBTa2lsbCBub3QgZm91bmQg
  >> "!B64TMP!" echo KGFscmVhZHkgcmVtb3ZlZCkgLSBub3RoaW5nIHRvIGRvLiIKZmkKZWNobwpwcmludGYgIkFsc28g
  >> "!B64TMP!" echo ZGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgQUxMIGl0cyBmaWxlcz8gW3kvTl06ICIKcmVh
  >> "!B64TMP!" echo ZCAtciBERUxGSUxFUwppZiBbICIkKGxvd2VyICIkREVMRklMRVMiKSIgIT0gInkiIF07IHRoZW4K
  >> "!B64TMP!" echo ICBlY2hvCiAgZWNobyAiVW5pbnN0YWxsIGZpbmlzaGVkLiBUaGUgZm9sZGVyIHdhcyBrZXB0OiIK
  >> "!B64TMP!" echo ICBlY2hvICIgICQocHdkKSIKICBlY2hvICIgIFlvdSBjYW4gZGVsZXRlIGl0IG1hbnVhbGx5IGlm
  >> "!B64TMP!" echo IHlvdSBubyBsb25nZXIgbmVlZCB0aGUgc2NyaXB0cy4iCiAgZXhpdCAwCmZpCgpUQVJHRVQ9IiQo
  >> "!B64TMP!" echo cHdkKSIKY2QgIiRIT01FIgplY2hvICJEZWxldGluZyBpbnN0YWxsIGZvbGRlcjogJFRBUkdFVCIK
  >> "!B64TMP!" echo cm0gLXJmICIkVEFSR0VUIgplY2hvCmVjaG8gIlVuaW5zdGFsbCBjb21wbGV0ZS4gR29vZGJ5ZSEi
  >> "!B64TMP!" echo Cg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- engine.sh ---
set "NEED_B64=1"
if exist "!SRC!\engine.sh" (
  copy /Y "!SRC!\engine.sh" "!TARGET!\engine.sh" >nul 2>&1
  if exist "!TARGET!\engine.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] engine.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS186919069.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBlbmdpbmUuc2ggLSBjb250YWluZXItZW5naW5lIGRl
  >> "!B64TMP!" echo dGVjdGlvbiBmb3IgdGhlIExvY2FsIFNlYXJjaCBzaGVsbCBzY3JpcHRzCiMgPT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT0KIyAgU291cmNlZCBieSBydW4uc2ggLyBzdG9wLnNoIC8gdXBkYXRlLnNoIC8gdW5p
  >> "!B64TMP!" echo bnN0YWxsLnNoLCBhbmQgaW5saW5lZCB2ZXJiYXRpbQojICBpbnRvIGluc3RhbGwtbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoLnNoIGJ5IGdlbl9pbnN0YWxsZXJzLnB5IC0gc28gdGhlcmUgaXMgZXhhY3RseSBPTkUKIyAg
  >> "!B64TMP!" echo Y29weSBvZiB0aGlzIGxvZ2ljLiBJdCBpcyBhIGxpYnJhcnk6IGl0IGlzIG5vdCBtZWFudCB0byBi
  >> "!B64TMP!" echo ZSBydW4gb24gaXRzIG93bi4KIwojICBXaGljaCBlbmdpbmUgaXMgdXNlZCAoZmlyc3QgbWF0Y2gg
  >> "!B64TMP!" echo d2lucyk6CiMgICAgMS4gTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58ZG9ja2VyIGluIHRoZSBl
  >> "!B64TMP!" echo bnZpcm9ubWVudCAgIChmb3JjZWQpCiMgICAgMi4gTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58
  >> "!B64TMP!" echo ZG9ja2VyIGluIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYKIyAgICAgICAodGhlIGluc3RhbGxl
  >> "!B64TMP!" echo ciByZWNvcmRzIGl0cyBjaG9pY2UgdGhlcmUsIHNvIHJ1bi5zaCAvIHVwZGF0ZS5zaCBrZWVwCiMg
  >> "!B64TMP!" echo ICAgICAgIHVzaW5nIHRoZSBlbmdpbmUgdGhhdCBjcmVhdGVkIHRoZSBjb250YWluZXJzKQojICAg
  >> "!B64TMP!" echo IDMuIGF1dG8tZGV0ZWN0OiBQb2RtYW4gd2hlbiBpdCBpcyBpbnN0YWxsZWQsIG90aGVyd2lzZSBE
  >> "!B64TMP!" echo b2NrZXIKIyAgICAgICAoaWYgYm90aCBhcmUgaW5zdGFsbGVkLCBQb2RtYW4gd2lucykKIwojICBG
  >> "!B64TMP!" echo dW5jdGlvbnMgKGFsbCBiYXNoIDMuMiBzYWZlKToKIyAgICBsc19zZWxlY3RfZW5naW5lIFtFTlZG
  >> "!B64TMP!" echo SUxFXSAgc2V0cyBFTkdJTkUgKHBvZG1hbnxkb2NrZXIpLCBFTkdJTkVfTkFNRSwgRU5HSU5FX0FV
  >> "!B64TMP!" echo VE8KIyAgICBsc19lbmdpbmVfcnVubmluZyAgICAgICAgICAgMCB3aGVuIHRoZSBzZWxlY3RlZCBl
  >> "!B64TMP!" echo bmdpbmUgYW5zd2VycwojICAgIGxzX3N0YXJ0X2VuZ2luZSAgICAgICAgICAgICBiZXN0LWVmZm9y
  >> "!B64TMP!" echo dCBsYXVuY2ggb2YgYSBzdG9wcGVkIGVuZ2luZQojICAgIGxzX2Vuc3VyZV9ydW5uaW5nICAgICAg
  >> "!B64TMP!" echo ICAgICBlbmdpbmUgYW5zd2Vycywgb3Igc3RhcnQgaXQgYW5kIHdhaXQgKHRoZW4gRG9ja2VyIGZh
  >> "!B64TMP!" echo bGxiYWNrKTsgMC8xCiMgICAgbHNfZmFsbGJhY2tfZW5naW5lICAgICAgICAgIGF1dG8tcGlja2Vk
  >> "!B64TMP!" echo IFBvZG1hbiB1bnVzYWJsZSArIERvY2tlciBydW5uaW5nIC0+IERvY2tlcgojICAgIGxzX2VuZ2lu
  >> "!B64TMP!" echo ZV9oaW50ICAgICAgICAgICAgICBwcmludHMgImhvdyB0byBzdGFydCBpdCB5b3Vyc2VsZiIgaGVs
  >> "!B64TMP!" echo cAojICAgIGxzX3NlbGVjdF9jb21wb3NlICAgICAgICAgICBzZXRzIERDIChlLmcuICJwb2RtYW4g
  >> "!B64TMP!" echo Y29tcG9zZSIsICJkb2NrZXIgY29tcG9zZSIpCiMgICAgbHNfZW5zdXJlX3BvZG1hbl9zb2NrZXQg
  >> "!B64TMP!" echo ICAgIHN0YXJ0cyBQb2RtYW4ncyBBUEkgc29ja2V0IChuZWVkZWQgYnkgZG9ja2VyLWNvbXBvc2Up
  >> "!B64TMP!" echo CiMgICAgbHNfcGxhdGZvcm1fZW52ICAgICAgICAgICAgIHNldHMgTFNfTU9VTlRfT1BUUyAvIExT
  >> "!B64TMP!" echo X0ZPUkNFX09XTkVSU0hJUCBmb3IgLmVudgojICAgIGxzX3ZlcmlmeV9zZWFyeG5nIFBPUlQgICAg
  >> "!B64TMP!" echo ICB3YWl0cyB1bnRpbCBTZWFyWE5HIGFuc3dlcnM7IGRpYWdub3NlcyBpZiBpdCBkb2VzIG5vdAoj
  >> "!B64TMP!" echo ICAgIGxzX2ZpeF9jb250YWluZXJfcHJveHkgUE9SVCAgYmxhbmtzIGxvb3BiYWNrIHByb3h5IHZh
  >> "!B64TMP!" echo cmlhYmxlcyB0aGUgY29udGFpbmVycyBpbmhlcml0ZWQgZnJvbSB0aGUgc2hlbGwKIyAgICBsc19w
  >> "!B64TMP!" echo YXVzZV9vbl9leGl0ICAgICAgICAgICAga2VlcHMgYSBsYXVuY2hlci1vcGVuZWQgdGVybWluYWwg
  >> "!B64TMP!" echo d2luZG93IG9wZW4gYXQgdGhlIGVuZAojICAgIGxzX3JlcXVpcmVfZW5naW5lIFtydW5uaW5nXSBz
  >> "!B64TMP!" echo ZWxlY3QgKyBjb21wb3NlICgrIHJ1bm5pbmcgY2hlY2spOyBleGl0cyBvbiBmYWlsdXJlCiMgPT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0KCmxzX2xvd2VyKCkgeyBwcmludGYgJyVzJyAiJDEiIHwgdHIgJ1s6
  >> "!B64TMP!" echo dXBwZXI6XScgJ1s6bG93ZXI6XSc7IH0KbHNfZXJyKCkgICB7IGlmIHR5cGUgZXJyID4vZGV2L251
  >> "!B64TMP!" echo bGwgMj4mMTsgdGhlbiBlcnIgIiQxIjsgZWxzZSBwcmludGYgJ1tFUlJPUl0gJXNcbicgIiQxIiA+
  >> "!B64TMP!" echo JjI7IGZpOyB9CmxzX3NheSgpICAgeyBpZiB0eXBlIHNheSA+L2Rldi9udWxsIDI+JjE7IHRoZW4g
  >> "!B64TMP!" echo c2F5ICIkMSI7IGVsc2UgcHJpbnRmICclc1xuJyAiJDEiOyBmaTsgfQpsc19vaygpICAgIHsgaWYg
  >> "!B64TMP!" echo dHlwZSBvayAgPi9kZXYvbnVsbCAyPiYxOyB0aGVuIG9rICAiJDEiOyBlbHNlIHByaW50ZiAnW09L
  >> "!B64TMP!" echo XSAlc1xuJyAiJDEiOyBmaTsgfQoKIyBsc19lbnZfdmFsdWUgRklMRSBLRVkgLT4gdGhlIGxhc3Qg
  >> "!B64TMP!" echo S0VZPXZhbHVlIGxpbmUgb2YgRklMRSAocXVvdGVzIC8gQ1Igc3RyaXBwZWQpCmxzX2Vudl92YWx1
  >> "!B64TMP!" echo ZSgpIHsKICBbIC1mICIkMSIgXSB8fCByZXR1cm4gMAogIGdyZXAgLUUgIl4kMj0iICIkMSIgMj4v
  >> "!B64TMP!" echo ZGV2L251bGwgfCB0YWlsIC1uIDEgfCBjdXQgLWQ9IC1mMi0gfCB0ciAtZCAnXHIiJyB8IHRyIC1k
  >> "!B64TMP!" echo ICInIgp9Cgpsc19pbnN0YWxsX2hpbnQoKSB7CiAgbHNfc2F5ICIiCiAgbHNfc2F5ICJJbnN0YWxs
  >> "!B64TMP!" echo IG9uZSBvZiB0aGVtLCB0aGVuIHJlLXJ1bjoiCiAgbHNfc2F5ICIgIFBvZG1hbiAocHJlZmVycmVk
  >> "!B64TMP!" echo IHdoZW4gYm90aCBhcmUgaW5zdGFsbGVkKToiCiAgbHNfc2F5ICIgICAgRmVkb3JhIC8gUkhFTDog
  >> "!B64TMP!" echo ICAgc3VkbyBkbmYgaW5zdGFsbCBwb2RtYW4gZG9ja2VyLWNvbXBvc2UiCiAgbHNfc2F5ICIgICAg
  >> "!B64TMP!" echo RGViaWFuIC8gVWJ1bnR1OiAgc3VkbyBhcHQgaW5zdGFsbCBwb2RtYW4gZG9ja2VyLWNvbXBvc2Ut
  >> "!B64TMP!" echo djIiCiAgbHNfc2F5ICIgICAgbWFjT1M6ICAgICAgICAgICAgYnJldyBpbnN0YWxsIHBvZG1hbiBk
  >> "!B64TMP!" echo b2NrZXItY29tcG9zZSAmJiBwb2RtYW4gbWFjaGluZSBpbml0IgogIGxzX3NheSAiICBEb2NrZXI6
  >> "!B64TMP!" echo IgogIGxzX3NheSAiICAgIExpbnV4OiAgaHR0cHM6Ly9kb2NzLmRvY2tlci5jb20vZW5naW5lL2lu
  >> "!B64TMP!" echo c3RhbGwvIgogIGxzX3NheSAiICAgIG1hY09TOiAgaHR0cHM6Ly93d3cuZG9ja2VyLmNvbS9wcm9k
  >> "!B64TMP!" echo dWN0cy9kb2NrZXItZGVza3RvcC8iCn0KCmxzX3NlbGVjdF9lbmdpbmUoKSB7CiAgbG9jYWwgd2Fu
  >> "!B64TMP!" echo dD0iIiBzcmM9IiIgaGF2ZV9wPTAgaGF2ZV9kPTAKICBFTkdJTkU9IiI7IEVOR0lORV9OQU1FPSIi
  >> "!B64TMP!" echo OyBFTkdJTkVfQVVUTz0wCiAgY29tbWFuZCAtdiBwb2RtYW4gPi9kZXYvbnVsbCAyPiYxICYmIGhh
  >> "!B64TMP!" echo dmVfcD0xCiAgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxICYmIGhhdmVfZD0xCgog
  >> "!B64TMP!" echo IHdhbnQ9IiQobHNfbG93ZXIgIiR7TE9DQUxfU0VBUkNIX0VOR0lORTotfSIpIgogIGlmIFsgLW4g
  >> "!B64TMP!" echo IiR3YW50IiBdOyB0aGVuCiAgICBzcmM9IkxPQ0FMX1NFQVJDSF9FTkdJTkUiCiAgZWxpZiBbIC1u
  >> "!B64TMP!" echo ICIkezE6LX0iIF07IHRoZW4KICAgIHdhbnQ9IiQobHNfbG93ZXIgIiQobHNfZW52X3ZhbHVlICIk
  >> "!B64TMP!" echo MSIgTE9DQUxfU0VBUkNIX0VOR0lORSkiKSIKICAgIHNyYz0iLmVudiIKICBmaQogIGNhc2UgIiR3
  >> "!B64TMP!" echo YW50IiBpbgogICAgIiJ8YXV0bykgd2FudD0iIiA7OwogICAgcG9kbWFufGRvY2tlcikgOzsKICAg
  >> "!B64TMP!" echo ICopIGxzX2VyciAiJHNyYyBtdXN0IGJlICdwb2RtYW4nIG9yICdkb2NrZXInIChnb3QgJyR3YW50
  >> "!B64TMP!" echo JykuIjsgcmV0dXJuIDEgOzsKICBlc2FjCgogIGlmIFsgLW4gIiR3YW50IiBdOyB0aGVuCiAgICBp
  >> "!B64TMP!" echo ZiBbICIkd2FudCIgPSAicG9kbWFuIiBdICYmIFsgIiRoYXZlX3AiID0gMSBdOyB0aGVuIEVOR0lO
  >> "!B64TMP!" echo RT1wb2RtYW47IEVOR0lORV9OQU1FPVBvZG1hbjsgcmV0dXJuIDA7IGZpCiAgICBpZiBbICIkd2Fu
  >> "!B64TMP!" echo dCIgPSAiZG9ja2VyIiBdICYmIFsgIiRoYXZlX2QiID0gMSBdOyB0aGVuIEVOR0lORT1kb2NrZXI7
  >> "!B64TMP!" echo IEVOR0lORV9OQU1FPURvY2tlcjsgcmV0dXJuIDA7IGZpCiAgICBpZiBbICIkc3JjIiA9ICJMT0NB
  >> "!B64TMP!" echo TF9TRUFSQ0hfRU5HSU5FIiBdOyB0aGVuCiAgICAgIGxzX2VyciAiTE9DQUxfU0VBUkNIX0VOR0lO
  >> "!B64TMP!" echo RT0kd2FudCwgYnV0ICckd2FudCcgd2FzIG5vdCBmb3VuZCBvbiB5b3VyIFBBVEguIgogICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQogICAgZmkKICAgIGxzX3NheSAiICBbIV0gLmVudiBhc2tzIGZvciAnJHdhbnQnLCB3
  >> "!B64TMP!" echo aGljaCBpcyBub3QgaW5zdGFsbGVkIC0gYXV0by1kZXRlY3RpbmcgaW5zdGVhZC4iCiAgZmkKCiAg
  >> "!B64TMP!" echo RU5HSU5FX0FVVE89MQogIGlmICAgWyAiJGhhdmVfcCIgPSAxIF07IHRoZW4gRU5HSU5FPXBvZG1h
  >> "!B64TMP!" echo bjsgRU5HSU5FX05BTUU9UG9kbWFuCiAgZWxpZiBbICIkaGF2ZV9kIiA9IDEgXTsgdGhlbiBFTkdJ
  >> "!B64TMP!" echo TkU9ZG9ja2VyOyBFTkdJTkVfTkFNRT1Eb2NrZXIKICBlbHNlCiAgICBsc19lcnIgIk5laXRoZXIg
  >> "!B64TMP!" echo UG9kbWFuIG5vciBEb2NrZXIgd2FzIGZvdW5kIG9uIHlvdXIgUEFUSC4iCiAgICBsc19pbnN0YWxs
  >> "!B64TMP!" echo X2hpbnQKICAgIHJldHVybiAxCiAgZmkKICByZXR1cm4gMAp9Cgpsc19lbmdpbmVfcnVubmluZygp
  >> "!B64TMP!" echo IHsgIiRFTkdJTkUiIGluZm8gPi9kZXYvbnVsbCAyPiYxOyB9CgojIEF1dG8tcGlja2VkIFBvZG1h
  >> "!B64TMP!" echo biBjYW5ub3QgcnVuIGJ1dCBEb2NrZXIgYW5zd2VyczogdXNlIERvY2tlciAod2l0aCBhIG5vdGlj
  >> "!B64TMP!" echo ZQojIGZyb20gdGhlIGNhbGxlcikuIE5ldmVyIG92ZXJyaWRlcyBhbiBleHBsaWNpdCBMT0NBTF9T
  >> "!B64TMP!" echo RUFSQ0hfRU5HSU5FIC8gLmVudiBjaG9pY2UuCmxzX2ZhbGxiYWNrX2VuZ2luZSgpIHsKICBbICIk
  >> "!B64TMP!" echo e0VOR0lORV9BVVRPOi0wfSIgPSAxIF0gJiYgWyAiJEVOR0lORSIgPSAicG9kbWFuIiBdIHx8IHJl
  >> "!B64TMP!" echo dHVybiAxCiAgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYvbnVsbCAyPiYxIHx8IHJldHVybiAxCiAg
  >> "!B64TMP!" echo ZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAyPiYxIHx8IHJldHVybiAxCiAgRU5HSU5FPWRvY2tlcjsg
  >> "!B64TMP!" echo RU5HSU5FX05BTUU9RG9ja2VyCiAgcmV0dXJuIDAKfQoKIyBMYXVuY2ggYSBzdG9wcGVkIGVuZ2lu
  >> "!B64TMP!" echo ZS4gUmV0dXJucyAwIHdoZW4gYSBzdGFydCB3YXMgaXNzdWVkICh0aGUgY2FsbGVyIHdhaXRzCiMg
  >> "!B64TMP!" echo Zm9yIGl0IHdpdGggbHNfZW5naW5lX3J1bm5pbmcpLCAxIHdoZW4gdGhlcmUgaXMgbm90aGluZyBp
  >> "!B64TMP!" echo dCBjYW4gc3RhcnQuCmxzX3N0YXJ0X2VuZ2luZSgpIHsKICBsb2NhbCB1bml0CiAgaWYgWyAiJEVO
  >> "!B64TMP!" echo R0lORSIgPSAicG9kbWFuIiBdOyB0aGVuCiAgICAjIExpbnV4OiByb290bGVzcyBQb2RtYW4gaGFz
  >> "!B64TMP!" echo IG5vIGRhZW1vbiwgc28gdGhlcmUgaXMgbm90aGluZyB0byBzdGFydC4KICAgICMgbWFjT1M6IFBv
  >> "!B64TMP!" echo ZG1hbiBydW5zIGluIGEgVk0gKCJwb2RtYW4gbWFjaGluZSIpIHRoYXQgaGFzIHRvIGJlIHN0YXJ0
  >> "!B64TMP!" echo ZWQuCiAgICBpZiBbICIkKHVuYW1lKSIgPSAiRGFyd2luIiBdOyB0aGVuCiAgICAgIFsgLW4gIiQo
  >> "!B64TMP!" echo cG9kbWFuIG1hY2hpbmUgbGlzdCAtLWZvcm1hdCAne3suTmFtZX19JyAyPi9kZXYvbnVsbCkiIF0g
  >> "!B64TMP!" echo fHwgcmV0dXJuIDEKICAgICAgKCBwb2RtYW4gbWFjaGluZSBzdGFydCA+L2Rldi9udWxsIDI+JjEg
  >> "!B64TMP!" echo JiApCiAgICAgIHJldHVybiAwCiAgICBmaQogICAgcmV0dXJuIDEKICBmaQogIGlmIFsgIiQodW5h
  >> "!B64TMP!" echo bWUpIiA9ICJEYXJ3aW4iIF07IHRoZW4KICAgICMgbWFjT1M6IGxhdW5jaCBEb2NrZXIgRGVza3Rv
  >> "!B64TMP!" echo cCBpZiBpdCBpcyBpbnN0YWxsZWQKICAgIGlmIGNvbW1hbmQgLXYgb3BlbiA+L2Rldi9udWxsIDI+
  >> "!B64TMP!" echo JjEgXAogICAgICAgJiYgeyBbIC1kICIvQXBwbGljYXRpb25zL0RvY2tlci5hcHAiIF0gfHwgWyAt
  >> "!B64TMP!" echo ZCAiJEhPTUUvQXBwbGljYXRpb25zL0RvY2tlci5hcHAiIF07IH07IHRoZW4KICAgICAgb3BlbiAt
  >> "!B64TMP!" echo YSBEb2NrZXIgPi9kZXYvbnVsbCAyPiYxICYmIHJldHVybiAwCiAgICBmaQogICAgcmV0dXJuIDEK
  >> "!B64TMP!" echo ICBmaQogICMgTGludXg6IHN5c3RlbWQgdW5pdHMgKERvY2tlciBEZXNrdG9wIHVzZXMgZG9ja2Vy
  >> "!B64TMP!" echo LWRlc2t0b3AsIHRoZSBjbGFzc2ljCiAgIyBlbmdpbmUgdXNlcyBkb2NrZXIpLCB0aGVuIHNlcnZp
  >> "!B64TMP!" echo Y2UoMSkuIE5vbi1pbnRlcmFjdGl2ZSBzdWRvIG9ubHkgLSBhbgogICMgaW5zdGFsbGVyIG5ldmVy
  >> "!B64TMP!" echo IHByb21wdHMgZm9yIGEgcGFzc3dvcmQuCiAgaWYgY29tbWFuZCAtdiBzeXN0ZW1jdGwgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuCiAgICBmb3IgdW5pdCBpbiBkb2NrZXItZGVza3RvcCBkb2NrZXI7IGRv
  >> "!B64TMP!" echo CiAgICAgIGlmIHN5c3RlbWN0bCBzdGFydCAiJHVuaXQiID4vZGV2L251bGwgMj4mMTsgdGhlbiBy
  >> "!B64TMP!" echo ZXR1cm4gMDsgZmkKICAgICAgaWYgY29tbWFuZCAtdiBzdWRvID4vZGV2L251bGwgMj4mMSBcCiAg
  >> "!B64TMP!" echo ICAgICAgICYmIHN1ZG8gLW4gc3lzdGVtY3RsIHN0YXJ0ICIkdW5pdCIgPi9kZXYvbnVsbCAyPiYx
  >> "!B64TMP!" echo OyB0aGVuCiAgICAgICAgcmV0dXJuIDAKICAgICAgZmkKICAgIGRvbmUKICBmaQogIGlmIGNvbW1h
  >> "!B64TMP!" echo bmQgLXYgc2VydmljZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGlmIHNlcnZpY2UgZG9ja2Vy
  >> "!B64TMP!" echo IHN0YXJ0ID4vZGV2L251bGwgMj4mMTsgdGhlbiByZXR1cm4gMAogICAgZWxpZiBjb21tYW5kIC12
  >> "!B64TMP!" echo IHN1ZG8gPi9kZXYvbnVsbCAyPiYxIFwKICAgICAgICAgJiYgc3VkbyAtbiBzZXJ2aWNlIGRvY2tl
  >> "!B64TMP!" echo ciBzdGFydCA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgICAgcmV0dXJuIDAKICAgIGZpCiAgZmkK
  >> "!B64TMP!" echo ICByZXR1cm4gMQp9CgojIE1ha2Ugc3VyZSB0aGUgc2VsZWN0ZWQgZW5naW5lIGFuc3dlcnMuIElm
  >> "!B64TMP!" echo IGl0IGRvZXMgbm90OiBsYXVuY2ggaXQgKHdoZW4gaXQgY2FuCiMgYmUgbGF1bmNoZWQpLCB3YWl0
  >> "!B64TMP!" echo IGZvciBpdCB0byBjb21lIG9ubGluZSAoTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUIHNlY29u
  >> "!B64TMP!" echo ZHMsCiMgZGVmYXVsdCAzMDApLCBhbmQgYXMgYSBsYXN0IHJlc29ydCB1c2UgRG9ja2VyIHdoZW4g
  >> "!B64TMP!" echo UG9kbWFuIHdhcyBvbmx5IGF1dG8tcGlja2VkLgojIFJldHVybnMgMCB3aGVuIGFuIGVuZ2luZSBp
  >> "!B64TMP!" echo cyByZWFkeSAoRU5HSU5FIC8gRU5HSU5FX05BTUUgbWF5IGhhdmUgY2hhbmdlZCB0bwojIERvY2tl
  >> "!B64TMP!" echo ciAtIHNlbGVjdCB0aGUgY29tcG9zZSB0b29sIEFGVEVSIGNhbGxpbmcgdGhpcyksIDEgd2hlbiBu
  >> "!B64TMP!" echo b25lIGNvdWxkIGJlCiMgYnJvdWdodCB1cC4gUHJpbnRzIHdoYXQgaXQgaXMgZG9pbmc7IHRoZSBj
  >> "!B64TMP!" echo YWxsZXIgcHJpbnRzIHRoZSBmaW5hbCBlcnJvci4KbHNfZW5zdXJlX3J1bm5pbmcoKSB7CiAgbG9j
  >> "!B64TMP!" echo YWwgdGltZW91dD0iJHtMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQ6LTMwMH0iIHBvbGw9IiR7
  >> "!B64TMP!" echo TFNfRU5HSU5FX1BPTEw6LTV9IiB3YWl0ZWQ9MAogIFsgIiRwb2xsIiAtZ2UgMSBdIDI+L2Rldi9u
  >> "!B64TMP!" echo dWxsIHx8IHBvbGw9NQogIFsgIiR0aW1lb3V0IiAtZ2UgMSBdIDI+L2Rldi9udWxsIHx8IHRpbWVv
  >> "!B64TMP!" echo dXQ9MzAwCiAgbHNfZW5naW5lX3J1bm5pbmcgJiYgcmV0dXJuIDAKICBsc19zYXkgIiAgWyFdIFRo
  >> "!B64TMP!" echo ZSAkRU5HSU5FX05BTUUgZW5naW5lIGlzIG5vdCBydW5uaW5nIC0gdHJ5aW5nIHRvIHN0YXJ0IGl0
  >> "!B64TMP!" echo Li4uIgogIGlmIGxzX3N0YXJ0X2VuZ2luZTsgdGhlbgogICAgbHNfc2F5ICIgIExhdW5jaGVkICRF
  >> "!B64TMP!" echo TkdJTkVfTkFNRSBpbiB0aGUgYmFja2dyb3VuZCAtIHdhaXRpbmcgdXAgdG8gJHt0aW1lb3V0fXMg
  >> "!B64TMP!" echo Zm9yIGl0IHRvIGNvbWUgb25saW5lLi4uIgogICAgd2hpbGUgISBsc19lbmdpbmVfcnVubmluZzsg
  >> "!B64TMP!" echo ZG8KICAgICAgc2xlZXAgIiRwb2xsIgogICAgICB3YWl0ZWQ9JCgod2FpdGVkICsgcG9sbCkpCiAg
  >> "!B64TMP!" echo ICAgIGlmIFsgIiR3YWl0ZWQiIC1nZSAiJHRpbWVvdXQiIF07IHRoZW4KICAgICAgICBsc19lcnIg
  >> "!B64TMP!" echo IlRoZSAkRU5HSU5FX05BTUUgZW5naW5lIGRpZCBub3QgY29tZSBvbmxpbmUgd2l0aGluICR7dGlt
  >> "!B64TMP!" echo ZW91dH1zLiIKICAgICAgICBicmVhawogICAgICBmaQogICAgICBpZiBbICQoKHdhaXRlZCAlIDE1
  >> "!B64TMP!" echo KSkgLWx0ICIkcG9sbCIgXTsgdGhlbiBsc19zYXkgIiAgLi4uIHN0aWxsIHdhaXRpbmcsICR7d2Fp
  >> "!B64TMP!" echo dGVkfXMgZWxhcHNlZCI7IGZpCiAgICBkb25lCiAgICBpZiBsc19lbmdpbmVfcnVubmluZzsgdGhl
  >> "!B64TMP!" echo bgogICAgICBsc19vayAiJEVOR0lORV9OQU1FIGVuZ2luZSBpcyBvbmxpbmUgYWZ0ZXIgJHt3YWl0
  >> "!B64TMP!" echo ZWR9cy4iCiAgICAgIHJldHVybiAwCiAgICBmaQogIGZpCiAgaWYgbHNfZmFsbGJhY2tfZW5naW5l
  >> "!B64TMP!" echo OyB0aGVuCiAgICBsc19zYXkgIiAgWyFdIFBvZG1hbiBpcyBub3QgcmVzcG9uZGluZyAtIHVzaW5n
  >> "!B64TMP!" echo IERvY2tlciBpbnN0ZWFkLiIKICAgIHJldHVybiAwCiAgZmkKICByZXR1cm4gMQp9Cgpsc19lbmdp
  >> "!B64TMP!" echo bmVfaGludCgpIHsKICBpZiBbICIkRU5HSU5FIiA9ICJwb2RtYW4iIF07IHRoZW4KICAgIGxzX3Nh
  >> "!B64TMP!" echo eSAiICBSdW4gJ3BvZG1hbiBpbmZvJyB0byBzZWUgd2h5IFBvZG1hbiBkb2VzIG5vdCBhbnN3ZXIu
  >> "!B64TMP!" echo IgogICAgbHNfc2F5ICIgIChyb290bGVzcyBQb2RtYW4gbmVlZHMgYSBub3JtYWwgbG9naW4gc2Vz
  >> "!B64TMP!" echo c2lvbiBhbmQgc3VidWlkL3N1YmdpZCBlbnRyaWVzKSIKICAgIGxzX3NheSAiICBtYWNPUzogIHBv
  >> "!B64TMP!" echo ZG1hbiBtYWNoaW5lIGluaXQgJiYgcG9kbWFuIG1hY2hpbmUgc3RhcnQiCiAgZWxzZQogICAgbHNf
  >> "!B64TMP!" echo c2F5ICIgIExpbnV4OiAgc3VkbyBzeXN0ZW1jdGwgc3RhcnQgZG9ja2VyICAgIChvciBsYXVuY2gg
  >> "!B64TMP!" echo RG9ja2VyIERlc2t0b3ApIgogICAgbHNfc2F5ICIgICAgICAgICAgcGVybWlzc2lvbiBkZW5pZWQg
  >> "!B64TMP!" echo ZnJvbSBkb2NrZXI/IGFkZCB5b3Vyc2VsZiB0byB0aGUgZG9ja2VyIgogICAgbHNfc2F5ICIgICAg
  >> "!B64TMP!" echo ICAgICAgZ3JvdXA6ICBzdWRvIHVzZXJtb2QgLWFHIGRvY2tlciAke1VTRVI6LXlvdXJ1c2VyfSAg
  >> "!B64TMP!" echo KGxvZyBvdXQgYW5kIGJhY2sgaW4pIgogICAgbHNfc2F5ICIgIG1hY09TOiAgb3BlbiAtYSBEb2Nr
  >> "!B64TMP!" echo ZXIiCiAgZmkKfQoKbHNfc2VsZWN0X2NvbXBvc2UoKSB7CiAgREM9IiIKICBpZiBbICIkRU5HSU5F
  >> "!B64TMP!" echo IiA9ICJwb2RtYW4iIF07IHRoZW4KICAgIGlmIHBvZG1hbiBjb21wb3NlIHZlcnNpb24gPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIERDPSJwb2RtYW4gY29tcG9zZSIKICAgIGVsaWYgY29tbWFuZCAtdiBw
  >> "!B64TMP!" echo b2RtYW4tY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9InBvZG1hbi1jb21wb3NlIgog
  >> "!B64TMP!" echo ICAgZWxzZQogICAgICBsc19lcnIgIk5vIGNvbXBvc2UgcHJvdmlkZXIgd2FzIGZvdW5kIGZvciBQ
  >> "!B64TMP!" echo b2RtYW4uIgogICAgICBsc19zYXkgIiAgSW5zdGFsbCBvbmUgKENvbXBvc2UgdjIgJ2RvY2tlci1j
  >> "!B64TMP!" echo b21wb3NlJyBpcyB0aGUgbW9zdCBjb21wYXRpYmxlKToiCiAgICAgIGxzX3NheSAiICAgIEZlZG9y
  >> "!B64TMP!" echo YSAvIFJIRUw6ICAgIHN1ZG8gZG5mIGluc3RhbGwgZG9ja2VyLWNvbXBvc2UgICAgIChvcjogcG9k
  >> "!B64TMP!" echo bWFuLWNvbXBvc2UpIgogICAgICBsc19zYXkgIiAgICBEZWJpYW4gLyBVYnVudHU6ICBzdWRvIGFw
  >> "!B64TMP!" echo dCBpbnN0YWxsIGRvY2tlci1jb21wb3NlLXYyICAob3I6IHBvZG1hbi1jb21wb3NlKSIKICAgICAg
  >> "!B64TMP!" echo bHNfc2F5ICIgICAgbWFjT1M6ICAgICAgICAgICAgYnJldyBpbnN0YWxsIGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo IgogICAgICByZXR1cm4gMQogICAgZmkKICAgICMgJ3BvZG1hbiBjb21wb3NlJyBwcmludHMgYSBw
  >> "!B64TMP!" echo cm92aWRlciBiYW5uZXIgb24gZXZlcnkgY2FsbCBpbiBuZXdlciBQb2RtYW4uCiAgICBleHBvcnQg
  >> "!B64TMP!" echo UE9ETUFOX0NPTVBPU0VfV0FSTklOR19MT0dTPWZhbHNlCiAgZWxzZQogICAgaWYgZG9ja2VyIGNv
  >> "!B64TMP!" echo bXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlciBjb21wb3NlIgog
  >> "!B64TMP!" echo ICAgZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3NlID4vZGV2L251bGwgMj4mMTsgdGhlbiBE
  >> "!B64TMP!" echo Qz0iZG9ja2VyLWNvbXBvc2UiCiAgICBlbHNlCiAgICAgIGxzX2VyciAiRG9ja2VyIENvbXBvc2Ug
  >> "!B64TMP!" echo d2FzIG5vdCBmb3VuZC4gSW5zdGFsbCB0aGUgJ2RvY2tlciBjb21wb3NlJyBwbHVnaW4gKHYyKS4i
  >> "!B64TMP!" echo CiAgICAgIHJldHVybiAxCiAgICBmaQogIGZpCiAgcmV0dXJuIDAKfQoKIyAncG9kbWFuIGNvbXBv
  >> "!B64TMP!" echo c2UnIG5vcm1hbGx5IGhhbmRzIG92ZXIgdG8gZG9ja2VyLWNvbXBvc2UsIHdoaWNoIHRhbGtzIHRv
  >> "!B64TMP!" echo CiMgUG9kbWFuJ3MgQVBJIHNvY2tldC4gT24gYSBmcmVzaCBGZWRvcmEgc2Vzc2lvbiB0aGF0IHNv
  >> "!B64TMP!" echo Y2tldCBpcyBub3QgcnVubmluZywgYW5kCiMgZG9ja2VyLWNvbXBvc2UgdGhlbiBmYWlscyB3aXRo
  >> "!B64TMP!" echo ICJDYW5ub3QgY29ubmVjdCB0byB0aGUgRG9ja2VyIGRhZW1vbiIuIFN0YXJ0IGl0CiMgd2hlbiBw
  >> "!B64TMP!" echo b3NzaWJsZS4gUmV0dXJucyAwIHdoZW4gdGhlIHNvY2tldCBleGlzdHMgYWZ0ZXJ3YXJkcy4gTmV2
  >> "!B64TMP!" echo ZXIgZmF0YWw6IGEKIyBjb21wb3NlIHByb3ZpZGVyIHRoYXQgZG9lcyBub3QgbmVlZCB0aGUgc29j
  >> "!B64TMP!" echo a2V0IChwb2RtYW4tY29tcG9zZSkgd29ya3MgYW55d2F5Lgpsc19lbnN1cmVfcG9kbWFuX3NvY2tl
  >> "!B64TMP!" echo dCgpIHsKICBbICIkRU5HSU5FIiA9ICJwb2RtYW4iIF0gJiYgWyAiJERDIiA9ICJwb2RtYW4gY29t
  >> "!B64TMP!" echo cG9zZSIgXSB8fCByZXR1cm4gMAogIFsgIiQodW5hbWUpIiA9ICJMaW51eCIgXSB8fCByZXR1cm4g
  >> "!B64TMP!" echo MAogIFsgIiQocG9kbWFuIGluZm8gLS1mb3JtYXQgJ3t7Lkhvc3QuUmVtb3RlU29ja2V0LkV4aXN0
  >> "!B64TMP!" echo c319JyAyPi9kZXYvbnVsbCkiID0gInRydWUiIF0gJiYgcmV0dXJuIDAKICBpZiBjb21tYW5kIC12
  >> "!B64TMP!" echo IHN5c3RlbWN0bCA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGlmIFsgIiQocG9kbWFuIGluZm8g
  >> "!B64TMP!" echo LS1mb3JtYXQgJ3t7Lkhvc3QuU2VjdXJpdHkuUm9vdGxlc3N9fScgMj4vZGV2L251bGwpIiA9ICJ0
  >> "!B64TMP!" echo cnVlIiBdOyB0aGVuCiAgICAgIHN5c3RlbWN0bCAtLXVzZXIgc3RhcnQgcG9kbWFuLnNvY2tldCA+
  >> "!B64TMP!" echo L2Rldi9udWxsIDI+JjEKICAgIGVsc2UKICAgICAgc3lzdGVtY3RsIHN0YXJ0IHBvZG1hbi5zb2Nr
  >> "!B64TMP!" echo ZXQgPi9kZXYvbnVsbCAyPiYxIFwKICAgICAgICB8fCB7IGNvbW1hbmQgLXYgc3VkbyA+L2Rldi9u
  >> "!B64TMP!" echo dWxsIDI+JjEgJiYgc3VkbyAtbiBzeXN0ZW1jdGwgc3RhcnQgcG9kbWFuLnNvY2tldCA+L2Rldi9u
  >> "!B64TMP!" echo dWxsIDI+JjE7IH0KICAgIGZpCiAgZmkKICBbICIkKHBvZG1hbiBpbmZvIC0tZm9ybWF0ICd7ey5I
  >> "!B64TMP!" echo b3N0LlJlbW90ZVNvY2tldC5FeGlzdHN9fScgMj4vZGV2L251bGwpIiA9ICJ0cnVlIiBdCn0KCmxz
  >> "!B64TMP!" echo X3NlbGludXhfb24oKSB7CiAgWyAiJCh1bmFtZSkiID0gIkxpbnV4IiBdIHx8IHJldHVybiAxCiAg
  >> "!B64TMP!" echo aWYgY29tbWFuZCAtdiBnZXRlbmZvcmNlID4vZGV2L251bGwgMj4mMTsgdGhlbgogICAgY2FzZSAi
  >> "!B64TMP!" echo JChnZXRlbmZvcmNlIDI+L2Rldi9udWxsKSIgaW4gRW5mb3JjaW5nfFBlcm1pc3NpdmUpIHJldHVy
  >> "!B64TMP!" echo biAwIDs7IGVzYWMKICAgIHJldHVybiAxCiAgZmkKICBbIC1lIC9zeXMvZnMvc2VsaW51eC9lbmZv
  >> "!B64TMP!" echo cmNlIF0KfQoKbHNfcG9kbWFuX3Jvb3RsZXNzKCkgewogIFsgIiQocG9kbWFuIGluZm8gLS1mb3Jt
  >> "!B64TMP!" echo YXQgJ3t7Lkhvc3QuU2VjdXJpdHkuUm9vdGxlc3N9fScgMj4vZGV2L251bGwpIiA9ICJ0cnVlIiBd
  >> "!B64TMP!" echo Cn0KCiMgRGVjaWRlcyB0aGUgdHdvIFNlYXJYTkcgYmluZC1tb3VudCBzZXR0aW5ncyB0aGF0IHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsZXIgd3JpdGVzIHRvIC5lbnYKIyAodGhleSBmZWVkICR7U0VBUlhOR19NT1VOVF9P
  >> "!B64TMP!" echo UFRTfSAvICR7U0VBUlhOR19GT1JDRV9PV05FUlNISVB9IGluIHRoZSBjb21wb3NlIGZpbGUpOgoj
  >> "!B64TMP!" echo ICAgTFNfTU9VTlRfT1BUUyAgICAgICAiLHoiIG9uIFNFTGludXggaG9zdHMgKGxldHMgdGhlIGNv
  >> "!B64TMP!" echo bnRhaW5lciByZWFkIHRoZSBmb2xkZXIpCiMgICBMU19GT1JDRV9PV05FUlNISVAgICJmYWxzZSIg
  >> "!B64TMP!" echo b24gcm9vdGxlc3MgUG9kbWFuIChrZWVwcyB0aGUgZmlsZXMgeW91cnMpLCBlbHNlICJ0cnVlIgps
  >> "!B64TMP!" echo c19wbGF0Zm9ybV9lbnYoKSB7CiAgTFNfTU9VTlRfT1BUUz0iIjsgTFNfRk9SQ0VfT1dORVJTSElQ
  >> "!B64TMP!" echo PSJ0cnVlIgogIGlmIGxzX3NlbGludXhfb247IHRoZW4gTFNfTU9VTlRfT1BUUz0iLHoiOyBmaQog
  >> "!B64TMP!" echo IGlmIFsgIiRFTkdJTkUiID0gInBvZG1hbiIgXSAmJiBsc19wb2RtYW5fcm9vdGxlc3M7IHRoZW4g
  >> "!B64TMP!" echo TFNfRk9SQ0VfT1dORVJTSElQPSJmYWxzZSI7IGZpCiAgcmV0dXJuIDAKfQoKIyBsc19odHRwX29r
  >> "!B64TMP!" echo IFBPUlQgLT4gMCB3aGVuIHNvbWV0aGluZyBhbnN3ZXJzIEhUVFAgb24gbG9jYWxob3N0OlBPUlQu
  >> "!B64TMP!" echo IEEgYmFyZSBUQ1AKIyBjb25uZWN0IGlzIG5vdCBlbm91Z2g6IHRoZSBlbmdpbmUgcHVibGlzaGVz
  >> "!B64TMP!" echo IHRoZSBwb3J0IGV2ZW4gd2hpbGUgdGhlIGNvbnRhaW5lcgojIGJlaGluZCBpdCBpcyBjcmFzaC1s
  >> "!B64TMP!" echo b29waW5nLgpsc19odHRwX29rKCkgewogICgKICAgIGV4ZWMgMzw+Ii9kZXYvdGNwLzEyNy4wLjAu
  >> "!B64TMP!" echo MS8kMSIgfHwgZXhpdCAxCiAgICBwcmludGYgJ0dFVCAvIEhUVFAvMS4wXHJcbkhvc3Q6IGxvY2Fs
  >> "!B64TMP!" echo aG9zdFxyXG5cclxuJyA+JjMKICAgIGxpbmU9IiIKICAgIElGUz0gcmVhZCAtciAtdCAzIGxpbmUg
  >> "!B64TMP!" echo PCYzIHx8IGV4aXQgMQogICAgY2FzZSAiJGxpbmUiIGluIEhUVFAvKikgZXhpdCAwIDs7IGVzYWMK
  >> "!B64TMP!" echo ICAgIGV4aXQgMQogICkgMj4vZGV2L251bGwKfQoKIyBsc192ZXJpZnlfc2VhcnhuZyBQT1JUICAo
  >> "!B64TMP!" echo cnVuIGZyb20gdGhlIGluc3RhbGwgZm9sZGVyOyBuZWVkcyAkREMpCiMgV2FpdHMgdXAgdG8gTE9D
  >> "!B64TMP!" echo QUxfU0VBUkNIX1ZFUklGWV9USU1FT1VUIHNlY29uZHMgKGRlZmF1bHQgOTAsIDAgPSBza2lwKS4g
  >> "!B64TMP!" echo V2hlbgojIFNlYXJYTkcgbmV2ZXIgYW5zd2VycyBpdCBwcmludHMgdGhlIGNvbnRhaW5lciBzdGF0
  >> "!B64TMP!" echo ZSArIGxhc3QgbG9nIGxpbmVzIGFuZCwgZm9yCiMgcGVybWlzc2lvbiBlcnJvcnMsIHRoZSBTRUxp
  >> "!B64TMP!" echo bnV4IGZpeC4gUmV0dXJucyAxIGluIHRoYXQgY2FzZS4KbHNfdmVyaWZ5X3NlYXJ4bmcoKSB7CiAg
  >> "!B64TMP!" echo bG9jYWwgcG9ydD0iJDEiIGxpbWl0PSIke0xPQ0FMX1NFQVJDSF9WRVJJRllfVElNRU9VVDotOTB9
  >> "!B64TMP!" echo IiB3YWl0ZWQ9MCBsb2dzPSIiCiAgWyAiJGxpbWl0IiAtZ3QgMCBdIDI+L2Rldi9udWxsIHx8IHJl
  >> "!B64TMP!" echo dHVybiAwCiAgbHNfc2F5ICJDaGVja2luZyB0aGF0IFNlYXJYTkcgYW5zd2VycyBvbiBwb3J0ICRw
  >> "!B64TMP!" echo b3J0ICh1cCB0byAke2xpbWl0fXMpLi4uIgogIHdoaWxlIDo7IGRvCiAgICBpZiBsc19odHRwX29r
  >> "!B64TMP!" echo ICIkcG9ydCI7IHRoZW4gbHNfb2sgIlNlYXJYTkcgaXMgYW5zd2VyaW5nIG9uIHBvcnQgJHBvcnQu
  >> "!B64TMP!" echo IjsgcmV0dXJuIDA7IGZpCiAgICBbICIkd2FpdGVkIiAtZ2UgIiRsaW1pdCIgXSAmJiBicmVhawog
  >> "!B64TMP!" echo ICAgc2xlZXAgMwogICAgd2FpdGVkPSQoKHdhaXRlZCArIDMpKQogIGRvbmUKICBsc19lcnIgIlNl
  >> "!B64TMP!" echo YXJYTkcgZGlkIG5vdCBhbnN3ZXIgb24gcG9ydCAkcG9ydCB3aXRoaW4gJHtsaW1pdH1zLiIKICBs
  >> "!B64TMP!" echo c19zYXkgIiIKICBsc19zYXkgIiAgQ29udGFpbmVyIHN0YXRlOiIKICAkREMgcHMgMj4mMSB8IHNl
  >> "!B64TMP!" echo ZCAncy9eLyAgICAvJyB8IGhlYWQgLW4gMTIKICBsb2dzPSIkKCREQyBsb2dzIC0tdGFpbCAxNSBz
  >> "!B64TMP!" echo ZWFyeG5nIDI+JjEpIgogIGxzX3NheSAiICBMYXN0IFNlYXJYTkcgbG9nIGxpbmVzOiIKICBwcmlu
  >> "!B64TMP!" echo dGYgJyVzXG4nICIkbG9ncyIgfCBzZWQgJ3MvXi8gICAgLycKICBpZiBwcmludGYgJyVzJyAiJGxv
  >> "!B64TMP!" echo Z3MiIHwgZ3JlcCAtcWkgInBlcm1pc3Npb24gZGVuaWVkIjsgdGhlbgogICAgbHNfc2F5ICIiCiAg
  >> "!B64TMP!" echo ICBsc19zYXkgIiAgVGhpcyBpcyBhIGJpbmQtbW91bnQgcGVybWlzc2lvbiBwcm9ibGVtICh0eXBp
  >> "!B64TMP!" echo Y2FsIG9uIEZlZG9yYSAvIFJIRUwgd2l0aCIKICAgIGxzX3NheSAiICBTRUxpbnV4KS4gVGhlIGNv
  >> "!B64TMP!" echo bXBvc2UgZmlsZSBsYWJlbHMgdGhlIFNlYXJYTkcgY29uZmlnIGZvbGRlciB0aHJvdWdoIgogICAg
  >> "!B64TMP!" echo bHNfc2F5ICIgIFNFQVJYTkdfTU9VTlRfT1BUUyBpbiAuZW52LCB3aGljaCBzaG91bGQgcmVhZDog
  >> "!B64TMP!" echo IFNFQVJYTkdfTU9VTlRfT1BUUz0seiIKICAgIGxzX3NheSAiICBDaGVjazogIGdyZXAgU0VBUlhO
  >> "!B64TMP!" echo RyAuZW52IDsgZ2V0ZW5mb3JjZSIKICAgIGxzX3NheSAiICBUaGVuIHJlc3RhcnQgd2l0aCAuL3J1
  >> "!B64TMP!" echo bi5zaCAob3IgcmUtcnVuIHRoZSBpbnN0YWxsZXIpLiIKICBmaQogIHJldHVybiAxCn0KCiMgLS0t
  >> "!B64TMP!" echo LSBrZWVwIHRoZSB3aW5kb3cgb3BlbiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQojIEEgdGVybWluYWwgb3BlbmVkIGJ5IGEgZmlsZSBtYW5h
  >> "!B64TMP!" echo Z2VyIC8gbGF1bmNoZXIgY2xvc2VzIHRoZSBtb21lbnQgdGhlIHNjcmlwdCBlbmRzLAojIHRha2lu
  >> "!B64TMP!" echo ZyBhbGwgb3V0cHV0IHdpdGggaXQuIFdoZW4gbm8gaW50ZXJhY3RpdmUgc2hlbGwgc3RhcnRlZCB1
  >> "!B64TMP!" echo cywgd2FpdCBmb3IgYSBrZXkgcHJlc3MKIyBiZWZvcmUgZXhpdGluZyAoUnVuLmJhdCAvIEluc3Rh
  >> "!B64TMP!" echo bGwuYmF0IGRvIHRoZSBzYW1lIHdpdGggYHBhdXNlYCkuCiMgICBMT0NBTF9TRUFSQ0hfUEFVU0U9
  >> "!B64TMP!" echo MCAgICBuZXZlciB3YWl0ICAgICAgTE9DQUxfU0VBUkNIX1BBVVNFPTEgICBhbHdheXMgd2FpdCAo
  >> "!B64TMP!" echo b24gYSB0ZXJtaW5hbCkKbHNfbGF1bmNoZWRfZnJvbV9zaGVsbCgpIHsgICAjIDAgPSBhbiBpbnRl
  >> "!B64TMP!" echo cmFjdGl2ZSBzaGVsbCBzdGFydGVkIHVzICh0aGUgdGVybWluYWwgc3RheXMgb3BlbikKICBsb2Nh
  >> "!B64TMP!" echo bCBwaWQ9IiR7UFBJRDotMH0iIGNvbW09IiIgYXJncz0iIiBob3BzPTAKICBjb21tYW5kIC12IHBz
  >> "!B64TMP!" echo ID4vZGV2L251bGwgMj4mMSB8fCByZXR1cm4gMQogIHdoaWxlIFsgIiRwaWQiIC1ndCAxIF0gMj4v
  >> "!B64TMP!" echo ZGV2L251bGwgJiYgWyAiJGhvcHMiIC1sdCA4IF07IGRvCiAgICBjb21tPSIkKHBzIC1vIGNvbW09
  >> "!B64TMP!" echo IC1wICIkcGlkIiAyPi9kZXYvbnVsbCB8IHRyIC1kICcgJykiOyBjb21tPSIke2NvbW0jIyovfSI7
  >> "!B64TMP!" echo IGNvbW09IiR7Y29tbSMtfSIKICAgIGFyZ3M9IiQocHMgLW8gYXJncz0gLXAgIiRwaWQiIDI+L2Rl
  >> "!B64TMP!" echo di9udWxsKSIKICAgIGNhc2UgIiRjb21tIiBpbgogICAgICBiYXNofHpzaHxzaHxkYXNofGZpc2h8
  >> "!B64TMP!" echo a3NofG1rc2h8YXNofHRjc2h8Y3NofG51fGVsdmlzaHx4b25zaCkKICAgICAgICAjIGBzaCAtYyAi
  >> "!B64TMP!" echo Li9zY3JpcHQiYCBpcyBqdXN0IGEgbGF1bmNoZXIncyB3cmFwcGVyIC0gbG9vayB0aHJvdWdoIGl0
  >> "!B64TMP!" echo CiAgICAgICAgY2FzZSAiICRhcmdzICIgaW4gKiIgLWMgIiopIDs7ICopIHJldHVybiAwIDs7IGVz
  >> "!B64TMP!" echo YWMgOzsKICAgICAgc3Vkb3xkb2FzfGVudnx0aW1lfHRpbWVvdXR8bmljZXxzZXRzaWR8c3RkYnVm
  >> "!B64TMP!" echo fHNjcmlwdHxwa2V4ZWN8c3V8bm9odXApIDs7CiAgICAgICopIHJldHVybiAxIDs7CiAgICBlc2Fj
  >> "!B64TMP!" echo CiAgICBwaWQ9IiQocHMgLW8gcHBpZD0gLXAgIiRwaWQiIDI+L2Rldi9udWxsIHwgdHIgLWQgJyAn
  >> "!B64TMP!" echo KSI7IGhvcHM9JCgoaG9wcyArIDEpKQogIGRvbmUKICByZXR1cm4gMQp9Cgpsc19wYXVzZV9ub3co
  >> "!B64TMP!" echo KSB7CiAgcHJpbnRmICdcbicKICBwcmludGYgJ1ByZXNzIGFueSBrZXkgdG8gY2xvc2UgdGhpcyB3
  >> "!B64TMP!" echo aW5kb3cuLi4gJwogIHJlYWQgLW4gMSAtcyBfbHNfeCA8L2Rldi90dHkgMj4vZGV2L251bGwgfHwg
  >> "!B64TMP!" echo cmVhZCAtbiAxIC1zIF9sc194IDI+L2Rldi9udWxsIHx8IHNsZWVwIDMwCn0KCmxzX3BhdXNlX29u
  >> "!B64TMP!" echo X2V4aXQoKSB7CiAgY2FzZSAiJChsc19sb3dlciAiJHtMT0NBTF9TRUFSQ0hfUEFVU0U6LWF1dG99
  >> "!B64TMP!" echo IikiIGluCiAgICAwfG5vfGZhbHNlfG5ldmVyKSByZXR1cm4gMCA7OwogICAgMXx5ZXN8dHJ1ZXxh
  >> "!B64TMP!" echo bHdheXMpIDs7CiAgICAqKSBsc19sYXVuY2hlZF9mcm9tX3NoZWxsICYmIHJldHVybiAwIDs7CiAg
  >> "!B64TMP!" echo ZXNhYwogIHsgWyAtdCAwIF0gJiYgWyAtdCAxIF07IH0gfHwgcmV0dXJuIDAKICAjIHNoZWxsY2hl
  >> "!B64TMP!" echo Y2sgZGlzYWJsZT1TQzIxNTQKICB0cmFwICdfbHNfcmM9JD87IGxzX3BhdXNlX25vdzsgZXhpdCAk
  >> "!B64TMP!" echo X2xzX3JjJyBFWElUCn0KCiMgLS0tLSBpbmhlcml0ZWQgcHJveHkgdmFyaWFibGVzIC0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBQb2RtYW4gY29w
  >> "!B64TMP!" echo aWVzIHRoZSBob3N0IHNoZWxsJ3MgaHR0cF9wcm94eSAvIGh0dHBzX3Byb3h5IC8gLi4uIGludG8g
  >> "!B64TMP!" echo ZXZlcnkgY29udGFpbmVyCiMgKERvY2tlciBkb2VzIG5vdCkuIEEgbG9vcGJhY2sgdmFsdWUgc3Vj
  >> "!B64TMP!" echo aCBhcyBodHRwOi8vMTI3LjAuMC4xOjc4OTAgcG9pbnRzIGF0IHRoZQojIGNvbnRhaW5lciBpdHNl
  >> "!B64TMP!" echo bGYgdGhlcmUsIHNvIGV2ZXJ5IG91dGdvaW5nIHJlcXVlc3QgZmFpbHMgYXQgb25jZSAoIkZhaWxl
  >> "!B64TMP!" echo ZCB0byBjb25uZWN0IG92ZXIKIyBwcm94eSAxMjcuMC4wLjEgYWZ0ZXIgMCBtcyIpIGFsdGhvdWdo
  >> "!B64TMP!" echo IGV2ZXJ5IGNvbnRhaW5lciBzaG93cyAiVXAiLiBXaGF0IHRoZSBjb250YWluZXJzCiMgYWN0dWFs
  >> "!B64TMP!" echo bHkgcmVjZWl2ZWQgaXMgaW5zcGVjdGVkLCBhbmQgZXhhY3RseSB0aG9zZSBsb29wYmFjayB2YXJp
  >> "!B64TMP!" echo YWJsZXMgYXJlIGJsYW5rZWQgdGhyb3VnaCBhCiMgZ2VuZXJhdGVkIGRvY2tlci1jb21wb3NlLm92
  >> "!B64TMP!" echo ZXJyaWRlLnltbCAoZG9ja2VyIGNvbXBvc2UgYW5kIHBvZG1hbi1jb21wb3NlIGxvYWQgaXQKIyBh
  >> "!B64TMP!" echo dXRvbWF0aWNhbGx5KS4gUHJveGllcyB0aGF0IHBvaW50IGF0IGEgcmVhbCBob3N0IChjb3Jwb3Jh
  >> "!B64TMP!" echo dGUsIExBTikgYXJlIGxlZnQgYWxvbmUuCkxTX09WRVJSSURFPSJkb2NrZXItY29tcG9zZS5vdmVy
  >> "!B64TMP!" echo cmlkZS55bWwiCkxTX09WRVJSSURFX01BUks9IiMgbG9jYWwtc2VhcmNoOiBnZW5lcmF0ZWQgY29u
  >> "!B64TMP!" echo dGFpbmVyLW5ldHdvcmsgd29ya2Fyb3VuZCIKTFNfT1ZSX1BST1hZPSIiICAgICAgIyBzcGFjZSBz
  >> "!B64TMP!" echo ZXBhcmF0ZWQgKGxvd2VyY2FzZSkgcHJveHkgdmFyaWFibGUgbmFtZXMgYmxhbmtlZCBieSB0aGUg
  >> "!B64TMP!" echo b3ZlcnJpZGUKCmxzX292ZXJyaWRlX2lzX291cnMoKSB7IFsgLWYgIiRMU19PVkVSUklERSIgXSAm
  >> "!B64TMP!" echo JiBoZWFkIC1uIDEgIiRMU19PVkVSUklERSIgMj4vZGV2L251bGwgfCBncmVwIC1xICJeIyBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2g6IGdlbmVyYXRlZCBjb250YWluZXItIjsgfQoKIyBSZXN0b3JlIHRoZSB2YXJpYWJs
  >> "!B64TMP!" echo ZSBsaXN0IGZyb20gYW4gb3ZlcnJpZGUgdGhpcyB0b29sIHdyb3RlIGVhcmxpZXIuCmxzX292ZXJy
  >> "!B64TMP!" echo aWRlX2xvYWQoKSB7CiAgTFNfT1ZSX1BST1hZPSIiCiAgbHNfb3ZlcnJpZGVfaXNfb3VycyB8fCBy
  >> "!B64TMP!" echo ZXR1cm4gMAogIExTX09WUl9QUk9YWT0iJChzZWQgLW4gJ3MvXiMgbHMtcHJveHktdmFyczogKi8v
  >> "!B64TMP!" echo cCcgIiRMU19PVkVSUklERSIgfCBoZWFkIC1uIDEgfCB0ciAnQS1aICcgJ2EtelxuJyB8IGdyZXAg
  >> "!B64TMP!" echo LXYgJ14kJyB8IHNvcnQgLXUgfCB0ciAnXG4nICcgJyB8IHNlZCAncy8gKiQvLycpIgp9CgojIFdy
  >> "!B64TMP!" echo aXRlcyB0aGUgb3ZlcnJpZGUgZnJvbSBMU19PVlJfUFJPWFk7IHJlbW92ZXMgaXQgd2hlbiB0aGUg
  >> "!B64TMP!" echo bGlzdCBpcyBlbXB0eS4KbHNfb3ZlcnJpZGVfd3JpdGUoKSB7CiAgbG9jYWwgc3ZjIHYgdWMKICBp
  >> "!B64TMP!" echo ZiBbIC16ICIkTFNfT1ZSX1BST1hZIiBdOyB0aGVuIHJtIC1mICIkTFNfT1ZFUlJJREUiOyByZXR1
  >> "!B64TMP!" echo cm4gMDsgZmkKICB7CiAgICBlY2hvICIkTFNfT1ZFUlJJREVfTUFSSyAoc2FmZSB0byBkZWxldGUg
  >> "!B64TMP!" echo LSB0aGUgaW5zdGFsbGVyIHJld3JpdGVzIGl0KSIKICAgIGVjaG8gIiMgbHMtcHJveHktdmFyczog
  >> "!B64TMP!" echo JExTX09WUl9QUk9YWSIKICAgIGVjaG8gIiMgUHJveHkgdmFyaWFibGVzIGNvcGllZCBmcm9tIHRo
  >> "!B64TMP!" echo ZSBob3N0IHNoZWxsIHBvaW50IGF0IDEyNy4wLjAuMSwgd2hpY2ggaW5zaWRlIGEgY29udGFpbmVy
  >> "!B64TMP!" echo IGlzIgogICAgZWNobyAiIyB0aGUgY29udGFpbmVyIGl0c2VsZjogYmxhbmtlZCBmb3IgZXZlcnkg
  >> "!B64TMP!" echo c2VydmljZSB0aGF0IG5lZWRzIHRoZSBpbnRlcm5ldC4iCiAgICBlY2hvICJzZXJ2aWNlczoiCiAg
  >> "!B64TMP!" echo ICBmb3Igc3ZjIGluIHNlYXJ4bmcgZmlyZWNyYXdsIHBsYXl3cmlnaHQtc2VydmljZSBicm93c2Vy
  >> "!B64TMP!" echo bGVzcyBpbnZpc2libGUtcGxheXdyaWdodDsgZG8KICAgICAgZWNobyAiICAkc3ZjOiIKICAgICAg
  >> "!B64TMP!" echo ZWNobyAiICAgIGVudmlyb25tZW50OiIKICAgICAgZm9yIHYgaW4gJExTX09WUl9QUk9YWTsgZG8K
  >> "!B64TMP!" echo ICAgICAgICB1Yz0iJChwcmludGYgJyVzJyAiJHYiIHwgdHIgJ1s6bG93ZXI6XScgJ1s6dXBwZXI6
  >> "!B64TMP!" echo XScpIgogICAgICAgIGVjaG8gIiAgICAgIC0gXCIkdj1cIiIKICAgICAgICBlY2hvICIgICAgICAt
  >> "!B64TMP!" echo IFwiJHVjPVwiIgogICAgICBkb25lCiAgICBkb25lCiAgfSA+ICIkTFNfT1ZFUlJJREUiCn0KCiMg
  >> "!B64TMP!" echo UHJpbnRzICJOQU1FPXZhbHVlIiBmb3IgZXZlcnkgcHJveHkgdmFyaWFibGUgaW5zaWRlIHRoZSBT
  >> "!B64TMP!" echo ZWFyWE5HIGNvbnRhaW5lciB0aGF0IHBvaW50cyBhdAojIHRoaXMgdmVyeSBjb250YWluZXIgKGxv
  >> "!B64TMP!" echo Y2FsaG9zdCAvIDEyNy54IC8gOjoxKSwgb25lIHBlciBsaW5lLiBOb3RoaW5nIHdoZW4gYWxsIGlz
  >> "!B64TMP!" echo IHdlbGwuCmxzX2NvbnRhaW5lcl9sb29wYmFja19wcm94aWVzKCkgewogIGxvY2FsIGVudnR4dCBs
  >> "!B64TMP!" echo aW5lIG5hbWUgdmFsIGhvc3QKICBlbnZ0eHQ9IiQoIiRFTkdJTkUiIGV4ZWMgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LXNlYXJ4bmcgZW52IDI+L2Rldi9udWxsKSIgfHwgcmV0dXJuIDAKICB3aGlsZSBJRlM9IHJlYWQg
  >> "!B64TMP!" echo LXIgbGluZTsgZG8KICAgIG5hbWU9IiR7bGluZSUlPSp9IjsgdmFsPSIke2xpbmUjKj19IgogICAg
  >> "!B64TMP!" echo Y2FzZSAiJChsc19sb3dlciAiJG5hbWUiKSIgaW4gaHR0cF9wcm94eXxodHRwc19wcm94eXxhbGxf
  >> "!B64TMP!" echo cHJveHl8ZnRwX3Byb3h5KSA7OyAqKSBjb250aW51ZSA7OyBlc2FjCiAgICBbIC1uICIkdmFsIiBd
  >> "!B64TMP!" echo IHx8IGNvbnRpbnVlCiAgICBob3N0PSIke3ZhbCMqOi8vfSI7IGhvc3Q9IiR7aG9zdCMjKkB9Igog
  >> "!B64TMP!" echo ICAgY2FzZSAiJGhvc3QiIGluCiAgICAgIFxbKikgaG9zdD0iJHtob3N0I1xbfSI7IGhvc3Q9IiR7
  >> "!B64TMP!" echo aG9zdCUlXF0qfSIgOzsKICAgICAgKikgICBob3N0PSIke2hvc3QlJVs6L10qfSIgOzsKICAgIGVz
  >> "!B64TMP!" echo YWMKICAgIGNhc2UgIiRob3N0IiBpbiBsb2NhbGhvc3R8MTI3Lip8OjoxfDAuMC4wLjApIHByaW50
  >> "!B64TMP!" echo ZiAnJXM9JXNcbicgIiRuYW1lIiAiJHZhbCIgOzsgZXNhYwogIGRvbmUgPDxFT0YKJGVudnR4dApF
  >> "!B64TMP!" echo T0YKfQoKbHNfd2FpdF9odHRwKCkgeyAgICMgbHNfd2FpdF9odHRwIFBPUlQgU0VDT05EUwogIGxv
  >> "!B64TMP!" echo Y2FsIHdhaXRlZD0wCiAgd2hpbGUgISBsc19odHRwX29rICIkMSI7IGRvCiAgICBbICIkd2FpdGVk
  >> "!B64TMP!" echo IiAtZ2UgIiQyIiBdICYmIHJldHVybiAxCiAgICBzbGVlcCAyOyB3YWl0ZWQ9JCgod2FpdGVkICsg
  >> "!B64TMP!" echo MikpCiAgZG9uZQp9CgojIGxzX2ZpeF9jb250YWluZXJfcHJveHkgUE9SVCAgKHJ1biBmcm9tIHRo
  >> "!B64TMP!" echo ZSBpbnN0YWxsIGZvbGRlcjsgbmVlZHMgJERDIGFuZCB0aGUgc3RhY2sgdXApCmxzX2ZpeF9jb250
  >> "!B64TMP!" echo YWluZXJfcHJveHkoKSB7CiAgbG9jYWwgcG9ydD0iJDEiIGJhZCBuYW1lcyB2IG91dAogIFsgIiR7
  >> "!B64TMP!" echo TE9DQUxfU0VBUkNIX1ZFUklGWV9USU1FT1VUOi05MH0iIC1ndCAwIF0gMj4vZGV2L251bGwgfHwg
  >> "!B64TMP!" echo cmV0dXJuIDAKICBsc19zYXkgIkNoZWNraW5nIHRoZSBjb250YWluZXJzJyBwcm94eSBzZXR0aW5n
  >> "!B64TMP!" echo cy4uLiIKICBiYWQ9IiQobHNfY29udGFpbmVyX2xvb3BiYWNrX3Byb3hpZXMpIgogIGlmIFsgLXog
  >> "!B64TMP!" echo IiRiYWQiIF07IHRoZW4gbHNfb2sgIlRoZSBjb250YWluZXJzJyBwcm94eSBzZXR0aW5ncyBhcmUg
  >> "!B64TMP!" echo ZmluZS4iOyByZXR1cm4gMDsgZmkKCiAgbHNfZXJyICJUaGUgY29udGFpbmVycyBpbmhlcml0ZWQg
  >> "!B64TMP!" echo YSBwcm94eSBzZXR0aW5nIHRoYXQgY2Fubm90IHdvcmsgZnJvbSBpbnNpZGUgYSBjb250YWluZXI6
  >> "!B64TMP!" echo IgogIHByaW50ZiAnJXNcbicgIiRiYWQiIHwgc2VkICdzL14vICAgICAgLycKICBsc19zYXkgIiAg
  >> "!B64TMP!" echo KFBvZG1hbiBjb3BpZXMgeW91ciBzaGVsbCdzIHByb3h5IHZhcmlhYmxlcyBpbnRvIGV2ZXJ5IGNv
  >> "!B64TMP!" echo bnRhaW5lcjsgMTI3LjAuMC4xIHRoZXJlIGlzIgogIGxzX3NheSAiICAgdGhlIGNvbnRhaW5lciBp
  >> "!B64TMP!" echo dHNlbGYsIHNvIGV2ZXJ5IG91dGdvaW5nIHJlcXVlc3QgZmFpbHMgYXQgb25jZSAtIHNlYXJjaGVz
  >> "!B64TMP!" echo IHN0YXkgZW1wdHkuKSIKICBpZiBbIC1mICIkTFNfT1ZFUlJJREUiIF0gJiYgISBsc19vdmVycmlk
  >> "!B64TMP!" echo ZV9pc19vdXJzOyB0aGVuCiAgICBsc19zYXkgIiAgJExTX09WRVJSSURFIGV4aXN0cyBhbmQgaXMg
  >> "!B64TMP!" echo bm90IG91cnMsIHNvIEkgd2lsbCBub3QgY2hhbmdlIGl0LiBBZGQgdG8gdGhlICdlbnZpcm9ubWVu
  >> "!B64TMP!" echo dDonIG9mIgogICAgbHNfc2F5ICIgIHNlYXJ4bmcsIGZpcmVjcmF3bCwgcGxheXdyaWdodC1zZXJ2
  >> "!B64TMP!" echo aWNlLCBicm93c2VybGVzcyBhbmQgaW52aXNpYmxlLXBsYXl3cmlnaHQsIHNldCB0byBlbXB0eToi
  >> "!B64TMP!" echo CiAgICBsc19zYXkgIiAgICBodHRwX3Byb3h5PSAgIGh0dHBzX3Byb3h5PSAgIGFsbF9wcm94eT0g
  >> "!B64TMP!" echo ICAoYW5kIHRoZSBVUFBFUkNBU0UgdHdpbnMpIgogICAgcmV0dXJuIDEKICBmaQogIGxzX292ZXJy
  >> "!B64TMP!" echo aWRlX2xvYWQKICBuYW1lcz0iIgogIHdoaWxlIElGUz0gcmVhZCAtciB2OyBkbyBbIC1uICIkdiIg
  >> "!B64TMP!" echo XSAmJiBuYW1lcz0iJG5hbWVzICQobHNfbG93ZXIgIiR7diUlPSp9IikiOyBkb25lIDw8RU9GCiRi
  >> "!B64TMP!" echo YWQKRU9GCiAgIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MyMDg2CiAgTFNfT1ZSX1BST1hZPSIkKHBy
  >> "!B64TMP!" echo aW50ZiAnJXNcbicgJExTX09WUl9QUk9YWSAkbmFtZXMgfCBzb3J0IC11IHwgdHIgJ1xuJyAnICcg
  >> "!B64TMP!" echo fCBzZWQgJ3MvICokLy8nKSIKICBsc19zYXkgIiAgLT4gcmVtb3ZpbmcgdGhvc2UgdmFyaWFibGVz
  >> "!B64TMP!" echo IGluc2lkZSB0aGUgY29udGFpbmVycyAod3JpdHRlbiB0byAkTFNfT1ZFUlJJREUpLi4uIgogIGxz
  >> "!B64TMP!" echo X292ZXJyaWRlX3dyaXRlCiAgaWYgISBvdXQ9IiQoJERDIHVwIC1kIDI+JjEpIjsgdGhlbgogICAg
  >> "!B64TMP!" echo bHNfc2F5ICIgIFshXSAnJERDIHVwIC1kJyBmYWlsZWQgd2hpbGUgYXBwbHlpbmcgaXQ6IgogICAg
  >> "!B64TMP!" echo cHJpbnRmICclc1xuJyAiJG91dCIgfCB0YWlsIC1uIDUgfCBzZWQgJ3MvXi8gICAgICAvJwogICAg
  >> "!B64TMP!" echo cmV0dXJuIDEKICBmaQogIGxzX3dhaXRfaHR0cCAiJHBvcnQiIDYwIHx8IHRydWUKICBpZiBbIC1u
  >> "!B64TMP!" echo ICIkKGxzX2NvbnRhaW5lcl9sb29wYmFja19wcm94aWVzKSIgXTsgdGhlbgogICAgbHNfZXJyICJU
  >> "!B64TMP!" echo aGUgY29udGFpbmVycyBzdGlsbCBjYXJyeSBhIGxvb3BiYWNrIHByb3h5LiBVbnNldCBpdCBpbiB5
  >> "!B64TMP!" echo b3VyIHNoZWxsIGFuZCBydW4gLi9ydW4uc2g6IgogICAgbHNfc2F5ICIgICAgdW5zZXQgaHR0cF9w
  >> "!B64TMP!" echo cm94eSBodHRwc19wcm94eSBhbGxfcHJveHkgSFRUUF9QUk9YWSBIVFRQU19QUk9YWSBBTExfUFJP
  >> "!B64TMP!" echo WFkiCiAgICByZXR1cm4gMQogIGZpCiAgbHNfb2sgIlRoZSBpbmhlcml0ZWQgbG9vcGJhY2sgcHJv
  >> "!B64TMP!" echo eHkgaXMgZ29uZSBmcm9tIHRoZSBjb250YWluZXJzIChzZWUgJExTX09WRVJSSURFOyBkZWxldGUg
  >> "!B64TMP!" echo aXQgdG8gdW5kbykuIgogIHJldHVybiAwCn0KCiMgRm9yIHJ1bi5zaCAvIHN0b3Auc2ggLyB1cGRh
  >> "!B64TMP!" echo dGUuc2ggLyB1bmluc3RhbGwuc2ggKGN3ZCA9IHRoZSBpbnN0YWxsIGZvbGRlcikuCmxzX3JlcXVp
  >> "!B64TMP!" echo cmVfZW5naW5lKCkgewogIGxzX3NlbGVjdF9lbmdpbmUgIi4vLmVudiIgfHwgZXhpdCAxCiAgaWYg
  >> "!B64TMP!" echo WyAiJHsxOi19IiA9ICJydW5uaW5nIiBdICYmICEgbHNfZW5zdXJlX3J1bm5pbmc7IHRoZW4KICAg
  >> "!B64TMP!" echo IGxzX2VyciAiVGhlICRFTkdJTkVfTkFNRSBlbmdpbmUgaXMgbm90IHJ1bm5pbmcgYW5kIGNvdWxk
  >> "!B64TMP!" echo IG5vdCBiZSBzdGFydGVkIGF1dG9tYXRpY2FsbHkuIgogICAgbHNfZW5naW5lX2hpbnQKICAgIGV4
  >> "!B64TMP!" echo aXQgMQogIGZpCiAgbHNfc2VsZWN0X2NvbXBvc2UgfHwgZXhpdCAxCiAgbHNfZW5zdXJlX3BvZG1h
  >> "!B64TMP!" echo bl9zb2NrZXQgfHwgbHNfc2F5ICIgIFshXSBQb2RtYW4ncyBBUEkgc29ja2V0IGlzIG5vdCBhY3Rp
  >> "!B64TMP!" echo dmUgLSBpZiBjb21wb3NlIGZhaWxzLCBydW46IHN5c3RlbWN0bCAtLXVzZXIgZW5hYmxlIC0tbm93
  >> "!B64TMP!" echo IHBvZG1hbi5zb2NrZXQiCn0K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\engine.sh"
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
  >> "!B64TMP!" echo KiogdG91Y2ggdGhlIGxvY2FsCmNvbnRhaW5lciBzdGFjayDigJQgaXQgdGFsa3MgZGlyZWN0bHkg
  >> "!B64TMP!" echo dG8gWW91VHViZSB0aHJvdWdoICoqeXQtZGxwKiosIHNvIHRoZXJlJ3MKbm90aGluZyB0byBzZWxm
  >> "!B64TMP!" echo LWhlYWwgYW5kIG5vIHdhcm0tdXAgbmVlZGVkLiBJdCdzIHRoZSBvbmUgdG9vbCBpbiB0aGlzIHNr
  >> "!B64TMP!" echo aWxsCndpdGggYSBwaXAgZGVwZW5kZW5jeSAoZXZlcnl0aGluZyBlbHNlIGlzIHN0ZGxpYi1vbmx5
  >> "!B64TMP!" echo KSwgYW5kIGl0IGFsc28gbmVlZHMgYQpKYXZhU2NyaXB0IHJ1bnRpbWUgKERlbm8gb3IgTm9kZS5q
  >> "!B64TMP!" echo cyAyMispIG9uIGBQQVRIYCBiZWNhdXNlIFlvdVR1YmUgcmVxdWlyZXMKb25lIG5vdzoKCmBgYGJh
  >> "!B64TMP!" echo c2gKcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0XSIgICAjIG9uZS10aW1lIChpbmNsdWRl
  >> "!B64TMP!" echo cyB5dC1kbHAtZWpzKQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfeW91dHVi
  >> "!B64TMP!" echo ZV90cmFuc2NyaXB0LnB5IiAiPHZpZGVvX2lkIG9yIFVSTD4iIFstLWxhbmcgZW4sZGVdCmBgYAoK
  >> "!B64TMP!" echo UHJpbnRzIGVhY2ggY2FwdGlvbiBsaW5lIGFzIGBbTU06U1NdIHRleHRgLiBUYWtlcyBhIGJhcmUg
  >> "!B64TMP!" echo dmlkZW8gSUQgKHRoZSBgdj1gCnZhbHVlIGZyb20gdGhlIFVSTCwgb3IgdGhlIHBhcnQgYWZ0ZXIg
  >> "!B64TMP!" echo YHlvdXR1LmJlL2ApIG9yIGEgZnVsbCBVUkw7IGAtLWxhbmdgCnBpY2tzIHRoZSBjYXB0aW9uIGxh
  >> "!B64TMP!" echo bmd1YWdlKHMpLCBkZWZhdWx0IGBlbmAgKGF1dG8tZ2VuZXJhdGVkIGNhcHRpb25zIGNvdW50KS4K
  >> "!B64TMP!" echo WW91VHViZSBwcm90ZWN0cyBtYW55IHZpZGVvcycgY2FwdGlvbnMgd2l0aCBhICJQTyB0b2tlbiIg
  >> "!B64TMP!" echo dGhhdCBvbGRlciBzY3JhcGVycwooYHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgKSBjYW5ub3QgZ2V0
  >> "!B64TMP!" echo IOKAlCB0aGV5IHJlY2VpdmUgYW4gZW1wdHkgYW5zd2VyIOKAlCB3aGljaCBpcwp3aHkgeXQtZGxw
  >> "!B64TMP!" echo IGlzIHRoZSBlbmdpbmU7IHRoZSBvbGQgcGFja2FnZSBpcyBvbmx5IHVzZWQgYXMgYSBmYWxsYmFj
  >> "!B64TMP!" echo ayB3aGVuIHl0LWRscAppcyBtaXNzaW5nIG9yIGZhaWxzLiBPbiBmYWlsdXJlIHRoZSBzY3JpcHQg
  >> "!B64TMP!" echo c2F5cyB3aHkgKGJvdCBjaGVjaywgbm8gY2FwdGlvbnMKcGx1cyB0aGUgbGFuZ3VhZ2VzIHRoYXQg
  >> "!B64TMP!" echo ZG8gZXhpc3QsIG1pc3NpbmcgSmF2YVNjcmlwdCBydW50aW1lLCDigKYpLiBJZiBpdCBmYWlscwpm
  >> "!B64TMP!" echo b3IgZXZlcnkgdmlkZW8sIHVwZGF0ZSBmaXJzdDogYHBpcCBpbnN0YWxsIC1VICJ5dC1kbHBbZGVm
  >> "!B64TMP!" echo YXVsdF0iYCDigJQgWW91VHViZQpjaGFuZ2VzIG9mdGVuIGFuZCB5dC1kbHAgZm9sbG93cyB3aXRo
  >> "!B64TMP!" echo aW4gZGF5cy4KCiMjIFRoZSBmdWxsIHRvb2wgc2V0ICgyNCBGaXJlY3Jhd2wgTUNQLWVxdWl2YWxl
  >> "!B64TMP!" echo bnQgdG9vbHMpCgpCZXlvbmQgc2VhcmNoICsgc2NyYXBlLCB0aGUgc2tpbGwgZXhwb3NlcyB0aGUg
  >> "!B64TMP!" echo Y29tcGxldGUgRmlyZWNyYXdsIE1DUCB0b29sCnN1cmZhY2UgYXMgc2NyaXB0cy4gQWxsIG9mIHRo
  >> "!B64TMP!" echo ZW0gc2hhcmUgdGhlIHNlbGYtaGVhbGluZyBiZWhhdmlvdXIsIHByaW50CmNsZWFuIG91dHB1dCBi
  >> "!B64TMP!" echo eSBkZWZhdWx0LCBhbmQgc3VwcG9ydCBgLS1qc29uYCBmb3IgdGhlIHJhdyBBUEkgcmVzcG9uc2Uu
  >> "!B64TMP!" echo CkV4aXQgY29kZXM6IDAgc3VjY2VzcywgMSB0b29sIGZhaWx1cmUsIDIgdXNhZ2UgZXJyb3IuCgpU
  >> "!B64TMP!" echo aGlzIHZhcmlhbnQgb2YgdGhlIHNraWxsIGlzIGluc3RhbGxlZCB3aGVuIGEgRmlyZWNyYXdsIGFj
  >> "!B64TMP!" echo Y291bnQgd2FzCmNvbmZpZ3VyZWQgYXQgaW5zdGFsbCB0aW1lOyB3aXRob3V0IG9uZSwgb25seSB0
  >> "!B64TMP!" echo aGUgZnJlZSBsb2NhbCB0b29scyBhcmUKaW5zdGFsbGVkIChzZWUgdGhlIHNraWxsJ3MgY29yZS1v
  >> "!B64TMP!" echo bmx5IFNLSUxMLm1kKS4KCiMjIyBNYXAgJiBjcmF3bCDigJQgZGlzY292ZXIgYW5kIGNvbGxlY3Qg
  >> "!B64TMP!" echo c2l0ZSBjb250ZW50CgotICoqTWFwIGEgd2Vic2l0ZSoqIChsaXN0IHRoZSBVUkxzIHVuZGVyIGl0
  >> "!B64TMP!" echo LCBubyBwYWdlIGNvbnRlbnQpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX21hcC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLXNlYXJjaCB0ZXJt
  >> "!B64TMP!" echo XSBbLS1saW1pdCBOXQogIGBgYAoKLSAqKlJ1biBhIHNpdGUgY3Jhd2wqKiAoc3RhcnRzIGEgbXVs
  >> "!B64TMP!" echo dGktcGFnZSBjcmF3bCwgcG9sbHMgaXQgdG8gY29tcGxldGlvbiwKICBwcmludHMgZWFjaCBwYWdl
  >> "!B64TMP!" echo J3MgVVJMICsgbWFya2Rvd24pOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX2NyYXdsLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbSIgWy0tbGltaXQgTl0K
  >> "!B64TMP!" echo ICBgYGAKCiAgVXNlIGAtLWxpbWl0IE5gIHRvIGJvdW5kIHRoZSBjcmF3bCBpdHNlbGYgKHRoZSBj
  >> "!B64TMP!" echo cmF3bCBvdGhlcndpc2Ugd2Fsa3MgdGhlCiAgZW50aXJlIHNpdGUg4oCUIG9uIGEgbGFyZ2Ugc2l0
  >> "!B64TMP!" echo ZSB0aGF0IGNhbiB0YWtlIG1hbnkgbWludXRlcykuIExvbmcgY3Jhd2xzOgogIHJhaXNlIGAtLXRp
  >> "!B64TMP!" echo bWVvdXQgU2AgKGRlZmF1bHQgMzAwKSBvciBrZWVwIHBvbGxpbmcgbGF0ZXIgd2l0aAogIGB3ZWJf
  >> "!B64TMP!" echo Y3Jhd2xfc3RhdHVzLnB5IDxpZD5gOyBib3VuZCB0aGUgcHJpbnRlZCBvdXRwdXQgd2l0aCBgLS1t
  >> "!B64TMP!" echo YXgtcGFnZXMgTmAKICAoZGVmYXVsdCAyNSkgLyBgLS1tYXgtY2hhcnMgTmAgKGRlZmF1bHQgMjAw
  >> "!B64TMP!" echo MCBwZXIgcGFnZSkuCgotICoqR2V0IGNyYXdsIHN0YXR1cyoqIGZvciBhbiBleGlzdGluZyBjcmF3
  >> "!B64TMP!" echo bCBJRDoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9j
  >> "!B64TMP!" echo cmF3bF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKIyMjIFJlc2VhcmNoIGFnZW50IOKAlCBhc3lu
  >> "!B64TMP!" echo Y2hyb25vdXMgbXVsdGktc291cmNlIHN5bnRoZXNpcyAoYWNjb3VudCBmZWF0dXJlKQoKLSAqKlN0
  >> "!B64TMP!" echo YXJ0IGEgcmVzZWFyY2ggYWdlbnQgam9iKiogZnJvbSBhIHByb21wdCAoKyBvcHRpb25hbCBzZWVk
  >> "!B64TMP!" echo IFVSTHMpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2Vi
  >> "!B64TMP!" echo X2FnZW50LnB5IiAicmVzZWFyY2ggcXVlc3Rpb24iIFtzZWVkX3VybCAuLi5dCiAgYGBgCgotICoq
  >> "!B64TMP!" echo R2V0IGFnZW50IGpvYiBzdGF0dXMgLyByZXN1bHRzKiogKHBvbGwgdW50aWwgYGNvbXBsZXRlZGAg
  >> "!B64TMP!" echo b3IgYGZhaWxlZGA7CiAgcmVzZWFyY2ggY29tbW9ubHkgdGFrZXMgc2V2ZXJhbCBtaW51dGVzKToK
  >> "!B64TMP!" echo CiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9hZ2VudF9z
  >> "!B64TMP!" echo dGF0dXMucHkiICI8aWQ+IgogIGBgYAoKICBJZiB0aGUgam9iIGNhbm5vdCBmaW5pc2ggaW4gdGlt
  >> "!B64TMP!" echo ZSwgZmFsbCBiYWNrIHRvIGB3ZWJfc2VhcmNoLnB5YCArCiAgYHdlYl9zY3JhcGUucHlgIHRvIGdh
  >> "!B64TMP!" echo dGhlciBldmlkZW5jZSBzeW5jaHJvbm91c2x5LgoKIyMjIEludGVyYWN0IOKAlCBkcml2ZSBhIGxp
  >> "!B64TMP!" echo dmUgYnJvd3NlciBzZXNzaW9uIChhY2NvdW50IGZlYXR1cmUpCgotICoqSW50ZXJhY3Qgd2l0aCBh
  >> "!B64TMP!" echo IHBhZ2UqKiAoY2xpY2ssIGZpbGwgZmllbGRzLCBydW4gYnJvd3NlciBjb2RlOyBhY3RzIG9uCiAg
  >> "!B64TMP!" echo dGhlIExJVkUgc2l0ZSDigJQgZm9ybSBzdWJtaXNzaW9ucyBjYW4gaGF2ZSBwZXJzaXN0ZW50IHNp
  >> "!B64TMP!" echo ZGUgZWZmZWN0cyk6CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfaW50ZXJhY3QucHkiICgtLXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkgKC0tcHJvbXB0
  >> "!B64TMP!" echo ICIuLi4iIHwgLS1jb2RlICIuLi4iIFstLWxhbmd1YWdlIGJhc2h8cHl0aG9ufG5vZGVdKQogIGBg
  >> "!B64TMP!" echo YAoKLSAqKlN0b3AgYW4gaW50ZXJhY3Qgc2Vzc2lvbjoqKgoKICBgYGBiYXNoCiAgcHl0aG9uICI8
  >> "!B64TMP!" echo c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiICI8c2NyYXBlSWQ+
  >> "!B64TMP!" echo IgogIGBgYAoKIyMjIFBhcnNlIOKAlCBsb2NhbCBkb2N1bWVudHMgKGFjY291bnQgZmVhdHVyZSkK
  >> "!B64TMP!" echo Ci0gKipQYXJzZSBhIGxvY2FsIGZpbGUqKiAoSFRNTCwgUERGLCBXb3JkLCBSVEYsIE9wZW5Eb2N1
  >> "!B64TMP!" echo bWVudCwgc3ByZWFkc2hlZXRzKQogIGludG8gbWFya2Rvd24gLyBsaW5rcyAvIGEgc3VtbWFyeSAv
  >> "!B64TMP!" echo IHN0cnVjdHVyZWQgSlNPTjoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL3dlYl9wYXJzZS5weSIgIjxmaWxlUGF0aD4iIFstLWZvcm1hdHMgbWFya2Rvd24sbGlu
  >> "!B64TMP!" echo a3Msc3VtbWFyeSxqc29uXQogIGBgYAoKICBUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0aGUgRmly
  >> "!B64TMP!" echo ZWNyYXdsIEFQSSB0aGUgc2NyaXB0cyBhcmUgcG9pbnRlZCBhdCDigJQKICB3aXRoIGFuIGFjY291
  >> "!B64TMP!" echo bnQgdGhhdCBpcyB0aGUgY2xvdWQgQVBJLCBzbyB0aGUgZG9jdW1lbnQgTEVBVkVTIHRoZQogIG1h
  >> "!B64TMP!" echo Y2hpbmUuIFdlYiBVUkxzIGJlbG9uZyBpbiBgd2ViX3NjcmFwZS5weWAuCgojIyMgTW9uaXRvcnMg
  >> "!B64TMP!" echo 4oCUIHJlY3VycmluZyBjaGFuZ2UgdHJhY2tpbmcgKGFjY291bnQgZmVhdHVyZSkKClJlY3Vycmlu
  >> "!B64TMP!" echo ZyBzY3JhcGUvY3Jhd2wvc2VhcmNoIGNoZWNrcyB0aGF0IGRpZmYgZWFjaCBydW4gYWdhaW5zdCBp
  >> "!B64TMP!" echo dHMKcHJlZGVjZXNzb3IuIFJlcXVpcmVzIGEgRmlyZWNyYXdsIGFjY291bnQgQVBJIGtleSDigJQg
  >> "!B64TMP!" echo c2VlICJBY2NvdW50IGZlYXR1cmVzIgpiZWxvdzsgdGhlIHNlbGYtaG9zdGVkIHN0YWNrIG1heSBu
  >> "!B64TMP!" echo b3Qgc2VydmUgdGhlc2UgZW5kcG9pbnRzLgoKYGBgYmFzaApweXRob24gIjxza2lsbC1iYXNlLWRp
  >> "!B64TMP!" echo cj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiICAtLWJvZHkgJ3sibmFtZSI6Ii4uLiIs
  >> "!B64TMP!" echo ImdvYWwiOiIuLi4iLCJ0YXJnZXRzIjpbLi4uXX0nCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiICAgIFstLWxpbWl0IE5dIFstLW9mZnNldCBOXQpw
  >> "!B64TMP!" echo eXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQucHkiICAgICAi
  >> "!B64TMP!" echo PGlkPiIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfdXBkYXRl
  >> "!B64TMP!" echo LnB5IiAgIjxpZD4iIC0tYm9keSAneyJzdGF0ZSI6InBhdXNlZCJ9JwpweXRob24gIjxza2lsbC1i
  >> "!B64TMP!" echo YXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkiICAiPGlkPiIKcHl0aG9uICI8
  >> "!B64TMP!" echo c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfcnVuLnB5IiAgICAgIjxpZD4iCnB5
  >> "!B64TMP!" echo dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5weSIgICI8
  >> "!B64TMP!" echo aWQ+IiBbLS1zdGF0dXMgY29tcGxldGVkXQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfbW9uaXRvcl9jaGVjay5weSIgICAiPGlkPiIgIjxjaGVja0lkPiIKYGBgCgpgd2ViX21v
  >> "!B64TMP!" echo bml0b3JfY3JlYXRlLnB5YCB0YWtlcyB0aGUgZnVsbCBtb25pdG9yIEpTT04gdmlhIGAtLWJvZHkg
  >> "!B64TMP!" echo J3suLi59J2Agb3IKYC0tYm9keS1maWxlIEZJTEVgLiBDaGVja3MgcmVwb3J0IHBhZ2UgZGlmZnMg
  >> "!B64TMP!" echo KGBzYW1lYCAvIGBuZXdgIC8gYGNoYW5nZWRgIC8KYHJlbW92ZWRgIC8gYGVycm9yYCkuCgojIyMg
  >> "!B64TMP!" echo UmVzZWFyY2ggcGFwZXJzIOKAlCBiaW9tZWRpY2FsICsgYXJYaXYgbGl0ZXJhdHVyZSAoYWNjb3Vu
  >> "!B64TMP!" echo dCBmZWF0dXJlKQoKVGhlIHBhcGVyIGluZGV4IChhYnN0cmFjdHMgKyBmdWxsIHRleHQgYWNyb3Nz
  >> "!B64TMP!" echo IFB1Yk1lZCwgYmlvUnhpdiwgbWVkUnhpdiwKYXJYaXYsIERPSXMpLiBSZXF1aXJlcyByZXNlYXJj
  >> "!B64TMP!" echo aCBwZXJtaXNzaW9ucyDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVzIi4KCmBgYGJhc2gKcHl0aG9u
  >> "!B64TMP!" echo ICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSIgICJuYXR1
  >> "!B64TMP!" echo cmFsIGxhbmd1YWdlIHRvcGljIgpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJf
  >> "!B64TMP!" echo cmVzZWFyY2hfaW5zcGVjdC5weSIgImFyeGl2OjE3MDYuMDM3NjIiCnB5dGhvbiAiPHNraWxsLWJh
  >> "!B64TMP!" echo c2UtZGlyPi9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiAiYXJ4aXY6MTcwNi4wMzc2
  >> "!B64TMP!" echo MiIgLS1pbnRlbnQgIndoYXQgdG8gcmFuayBmb3IiIFstLW1vZGUgc2ltaWxhcnxjaXRlcnN8cmVm
  >> "!B64TMP!" echo ZXJlbmNlc10KcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3Jl
  >> "!B64TMP!" echo YWQucHkiICAgICJhcnhpdjoxNzA2LjAzNzYyIiAic3BlY2lmaWMgcXVlc3Rpb24iCmBgYAoKUGFw
  >> "!B64TMP!" echo ZXIgSURzIGFjY2VwdCBgYXJ4aXY6YCwgYHBtY2lkOmAsIGBwbWlkOmAsIGFuZCBgZG9pOmAgaWRl
  >> "!B64TMP!" echo bnRpZmllcnMuClNldmVyYWwgZGlzdGluY3QgZnJhbWluZ3Mgb2YgdGhlIHNhbWUgcXVlc3Rpb24g
  >> "!B64TMP!" echo c3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpGb3IgcmVzZWFyY2gtYWZmaWxpYXRlZCAqd2Vic2l0
  >> "!B64TMP!" echo ZXMqIChub3QgcGFwZXJzKSwgdXNlIGB3ZWJfc2VhcmNoLnB5YCB3aXRoCmAtLWNhdGVnb3JpZXMg
  >> "!B64TMP!" echo cmVzZWFyY2hgIGluc3RlYWQuCgojIyMgR2l0SHViICYgZGV2ZWxvcGVyIHNlYXJjaCAoYWNjb3Vu
  >> "!B64TMP!" echo dCBmZWF0dXJlcykKCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2Vi
  >> "!B64TMP!" echo X2dpdGh1Yl9zZWFyY2gucHkiICAgICAgImluZGV4ZWQgR2l0SHViIGlzc3VlL1BSL1JFQURNRSBx
  >> "!B64TMP!" echo dWVyeSIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2RldmVsb3Blcl9zZWFy
  >> "!B64TMP!" echo Y2gucHkiICAgImRldmVsb3BlciBxdWVzdGlvbiIgWy0tc2tpbGxzLW9ubHldCmBgYAoKVGhlIGRl
  >> "!B64TMP!" echo dmVsb3BlciBpbmRleCBjb3ZlcnMgR2l0SHViIGlzc3VlcywgbWVyZ2VkIFBScywgUkVBRE1Fcywg
  >> "!B64TMP!" echo YW5kIGN1cmF0ZWQKZG9jdW1lbnRhdGlvbiDigJQgdXNlIGl0IGZvciBjb2RlIGJlaGF2aW91ciwg
  >> "!B64TMP!" echo bGlicmFyaWVzLCBBUEkgY29udHJhY3RzLCBlcnJvcgptZXNzYWdlcywgYW5kIGtub3duIGJ1Z3Mu
  >> "!B64TMP!" echo CgojIyBBY2NvdW50IGZlYXR1cmVzIChhZ2VudCAvIGludGVyYWN0IC8gcGFyc2UgLyBtb25pdG9y
  >> "!B64TMP!" echo cyAvIHJlc2VhcmNoIC8gZGV2ZWxvcGVyIHNlYXJjaCkKClRoZXNlIEZpcmVjcmF3bCBmZWF0dXJl
  >> "!B64TMP!" echo cyBhcmUgYWNjb3VudC1nYXRlZC4gVGhlIGVhc2llc3Qgd2F5IHRvIHVzZSB0aGVtIGlzCnRoZSBp
  >> "!B64TMP!" echo bnN0YWxsZXI6IGFuc3dlciBgeWAgYXQgdGhlICJBZGQgYSBGaXJlY3Jhd2wgYWNjb3VudD8iIHF1
  >> "!B64TMP!" echo ZXN0aW9uIGFuZApwYXN0ZSB5b3VyIGtleSDigJQgaXQgd3JpdGVzCgpgYGBiYXNoCkZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgICAjIHRoZSBjbG91ZCBBUEkKRklS
  >> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVk9ZmMtLi4uICAgICAgICAgICAgICAgICAgICAgICAjIHlvdXIgYWNjb3Vu
  >> "!B64TMP!" echo dCBrZXkKYGBgCgppbnRvIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbCBmb2xkZXIncyBgLmVudmAs
  >> "!B64TMP!" echo IGFuZCBldmVyeSBzY3JpcHQgcGlja3MgdGhlCnZhbHVlcyB1cCBhdXRvbWF0aWNhbGx5LiBgZXhw
  >> "!B64TMP!" echo b3J0YGluZyB0aGUgc2FtZSBlbnYgdmFyIG5hbWVzICh0aGUgb25lcyB0aGUKb2ZmaWNpYWwgZmly
  >> "!B64TMP!" echo ZWNyYXdsLW1jcCBzZXJ2ZXIgdXNlcykgb3ZlcnJpZGVzIHRoZSBgLmVudmAgdmFsdWVzLiBXaXRo
  >> "!B64TMP!" echo IHRoZW0Kc2V0LCB0aGUgYWNjb3VudCBzY3JpcHRzIGNhbGwgdGhlIGNsb3VkIEFQSSBhbmQgc2Vu
  >> "!B64TMP!" echo ZCB0aGUga2V5IGFzIGEgQmVhcmVyCnRva2VuOyBldmVyeSBvdGhlciBzY3JpcHQga2VlcHMgdXNp
  >> "!B64TMP!" echo bmcgdGhlIGxvY2FsIHN0YWNrLiBXaXRob3V0IHRoZW0sIGFuCmFjY291bnQgdG9vbCBjYWxsZWQg
  >> "!B64TMP!" echo YWdhaW5zdCB0aGUgbG9jYWwgc3RhY2sgZmFpbHMgd2l0aCBhIG1lc3NhZ2UgdGhhdCBzYXlzCmV4
  >> "!B64TMP!" echo YWN0bHkgdGhpcyDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgdG9vbHMgb3ZlciBp
  >> "!B64TMP!" echo dCB1bmxlc3MgdGhlIHVzZXIKYXNrcy4KCiMjIElmIHNvbWV0aGluZyBnb2VzIHdyb25nCgotIFJl
  >> "!B64TMP!" echo dHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgb3IgVVJMIGJlZm9yZSBnaXZpbmcg
  >> "!B64TMP!" echo dXAuCi0gSWYgYSBzY3JpcHQgcHJpbnRzIGEgKipOZXR3b3JrIGNoZWNrKiogc2F5aW5nIHRoZSBy
  >> "!B64TMP!" echo b3V0ZSB0byBhIHNpdGUgaXMKICBibG9ja2VkIChlLmcuIHRoZSBzaXRlJ3MgbmFtZSByZXNvbHZl
  >> "!B64TMP!" echo cyB0byBhIHByb3h5L1ZQTiBmYWtlLUlQIHN1Y2ggYXMKICBgMTk4LjE4LngueGAgYW5kIG5vdGhp
  >> "!B64TMP!" echo bmcgYW5zd2VycyksIGRvIG5vdCByZXRyeSB0aGF0IFVSTCBhbmQgZG8gbm90IHdhaXQ6CiAgdGhl
  >> "!B64TMP!" echo IGNvbm5lY3Rpb24gaXMgYmxvY2tlZCBhdCB0aGUgbmV0d29yayBsZXZlbCwgc28gcmVwZWF0aW5n
  >> "!B64TMP!" echo IGl0IG9ubHkKICB3YXN0ZXMgdGltZS4gVXNlIGEgZGlmZmVyZW50IHNvdXJjZSBmb3IgdGhlIGlu
  >> "!B64TMP!" echo Zm9ybWF0aW9uIChhbm90aGVyIFVSTCwgZS5nLgogIGZyb20gYSBmcmVzaCBzZWFyY2gsIHdpdGgg
  >> "!B64TMP!" echo dGhpcyBzYW1lIHNraWxsKSwgYW5kIHRlbGwgdGhlIHVzZXIgd2hhdCB0aGUgY2hlY2sKICByZXBv
  >> "!B64TMP!" echo cnRlZCBzbyB0aGV5IGNhbiBmaXggdGhlaXIgbmV0d29yayAocHJveHkvVlBOIFRVTiBtb2RlLCBE
  >> "!B64TMP!" echo TlMpLgotIERvbid0IGZhbGwgYmFjayB0byBhbm90aGVyIHdlYiB0b29sIG92ZXIgYSBwcm9ibGVt
  >> "!B64TMP!" echo IHdpdGggdGhpcyBzdGFjayDigJQgZml4CiAgaXQgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBE
  >> "!B64TMP!" echo b2NrZXIgRGVza3RvcCkgYW5kIHJldHJ5LCB1bmxlc3MgdGhlIHVzZXIKICBhc2tzIGZvciBhbiBh
  >> "!B64TMP!" echo bHRlcm5hdGl2ZS4KLSBJZiBhIHNjcmlwdCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlciAo
  >> "!B64TMP!" echo cmFyZSDigJQgZGV0ZWN0aW9uIG5vcm1hbGx5IHdvcmtzCiAgdmlhIHRoZSBydW5uaW5nIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMsIHRoZSBpbnN0YWxsZXIncyByZWNvcmRlZCBwYXRoLCBvcgogIGB+L2xvY2FsLXNlYXJj
  >> "!B64TMP!" echo aGApLCBhc2sgdGhlIHVzZXIgZm9yIGl0cyBwYXRoIGFuZCByZS1ydW4gd2l0aAogIGBMT0NBTF9T
  >> "!B64TMP!" echo RUFSQ0hfRElSPTxwYXRoPmAuCi0gRXh0cmFjdCBvbmx5IHdoYXQgeW91IG5lZWQgZnJvbSBzY3Jh
  >> "!B64TMP!" echo cGVkIHBhZ2VzIOKAlCBkb24ndCBwYXN0ZSB3aG9sZSBwYWdlcwogIGJhY2sgdG8gdGhlIHVzZXIu
  >> "!B64TMP!" echo Cg==
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
  >> "!B64TMP!" echo b3VjaCB0aGUgbG9jYWwKY29udGFpbmVyIHN0YWNrIOKAlCBpdCB0YWxrcyBkaXJlY3RseSB0byBZ
  >> "!B64TMP!" echo b3VUdWJlIHRocm91Z2ggKip5dC1kbHAqKiwgc28gdGhlcmUncwpub3RoaW5nIHRvIHNlbGYtaGVh
  >> "!B64TMP!" echo bCBhbmQgbm8gd2FybS11cCBuZWVkZWQuIEl0J3MgdGhlIG9uZSB0b29sIGluIHRoaXMgc2tpbGwK
  >> "!B64TMP!" echo d2l0aCBhIHBpcCBkZXBlbmRlbmN5IChldmVyeXRoaW5nIGVsc2UgaXMgc3RkbGliLW9ubHkpLCBh
  >> "!B64TMP!" echo bmQgaXQgYWxzbyBuZWVkcyBhCkphdmFTY3JpcHQgcnVudGltZSAoRGVubyBvciBOb2RlLmpzIDIy
  >> "!B64TMP!" echo Kykgb24gYFBBVEhgIGJlY2F1c2UgWW91VHViZSByZXF1aXJlcwpvbmUgbm93OgoKYGBgYmFzaApw
  >> "!B64TMP!" echo aXAgaW5zdGFsbCAtVSAieXQtZGxwW2RlZmF1bHRdIiAgICMgb25lLXRpbWUgKGluY2x1ZGVzIHl0
  >> "!B64TMP!" echo LWRscC1lanMpCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl95b3V0dWJlX3Ry
  >> "!B64TMP!" echo YW5zY3JpcHQucHkiICI8dmlkZW9faWQgb3IgVVJMPiIgWy0tbGFuZyBlbixkZV0KYGBgCgpQcmlu
  >> "!B64TMP!" echo dHMgZWFjaCBjYXB0aW9uIGxpbmUgYXMgYFtNTTpTU10gdGV4dGAuIFRha2VzIGEgYmFyZSB2aWRl
  >> "!B64TMP!" echo byBJRCAodGhlIGB2PWAKdmFsdWUgZnJvbSB0aGUgVVJMLCBvciB0aGUgcGFydCBhZnRlciBgeW91
  >> "!B64TMP!" echo dHUuYmUvYCkgb3IgYSBmdWxsIFVSTDsgYC0tbGFuZ2AKcGlja3MgdGhlIGNhcHRpb24gbGFuZ3Vh
  >> "!B64TMP!" echo Z2UocyksIGRlZmF1bHQgYGVuYCAoYXV0by1nZW5lcmF0ZWQgY2FwdGlvbnMgY291bnQpLgpZb3VU
  >> "!B64TMP!" echo dWJlIHByb3RlY3RzIG1hbnkgdmlkZW9zJyBjYXB0aW9ucyB3aXRoIGEgIlBPIHRva2VuIiB0aGF0
  >> "!B64TMP!" echo IG9sZGVyIHNjcmFwZXJzCihgeW91dHViZS10cmFuc2NyaXB0LWFwaWApIGNhbm5vdCBnZXQg4oCU
  >> "!B64TMP!" echo IHRoZXkgcmVjZWl2ZSBhbiBlbXB0eSBhbnN3ZXIg4oCUIHdoaWNoIGlzCndoeSB5dC1kbHAgaXMg
  >> "!B64TMP!" echo dGhlIGVuZ2luZTsgdGhlIG9sZCBwYWNrYWdlIGlzIG9ubHkgdXNlZCBhcyBhIGZhbGxiYWNrIHdo
  >> "!B64TMP!" echo ZW4geXQtZGxwCmlzIG1pc3Npbmcgb3IgZmFpbHMuIE9uIGZhaWx1cmUgdGhlIHNjcmlwdCBzYXlz
  >> "!B64TMP!" echo IHdoeSAoYm90IGNoZWNrLCBubyBjYXB0aW9ucwpwbHVzIHRoZSBsYW5ndWFnZXMgdGhhdCBkbyBl
  >> "!B64TMP!" echo eGlzdCwgbWlzc2luZyBKYXZhU2NyaXB0IHJ1bnRpbWUsIOKApikuIElmIGl0IGZhaWxzCmZvciBl
  >> "!B64TMP!" echo dmVyeSB2aWRlbywgdXBkYXRlIGZpcnN0OiBgcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0
  >> "!B64TMP!" echo XSJgIOKAlCBZb3VUdWJlCmNoYW5nZXMgb2Z0ZW4gYW5kIHl0LWRscCBmb2xsb3dzIHdpdGhpbiBk
  >> "!B64TMP!" echo YXlzLgoKIyMgTWFwICYgY3Jhd2wg4oCUIGRpc2NvdmVyIGFuZCBjb2xsZWN0IHNpdGUgY29udGVu
  >> "!B64TMP!" echo dAoKLSAqKk1hcCBhIHdlYnNpdGUqKiAobGlzdCB0aGUgVVJMcyB1bmRlciBpdCwgbm8gcGFnZSBj
  >> "!B64TMP!" echo b250ZW50KToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
  >> "!B64TMP!" echo Yl9tYXAucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQg
  >> "!B64TMP!" echo Tl0KICBgYGAKCi0gKipSdW4gYSBzaXRlIGNyYXdsKiogKHN0YXJ0cyBhIG11bHRpLXBhZ2UgY3Jh
  >> "!B64TMP!" echo d2wsIHBvbGxzIGl0IHRvIGNvbXBsZXRpb24sCiAgcHJpbnRzIGVhY2ggcGFnZSdzIFVSTCArIG1h
  >> "!B64TMP!" echo cmtkb3duKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
  >> "!B64TMP!" echo Yl9jcmF3bC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLWxpbWl0IE5dCiAgYGBgCgogIFVz
  >> "!B64TMP!" echo ZSBgLS1saW1pdCBOYCB0byBib3VuZCB0aGUgY3Jhd2wgaXRzZWxmICh0aGUgY3Jhd2wgb3RoZXJ3
  >> "!B64TMP!" echo aXNlIHdhbGtzIHRoZQogIGVudGlyZSBzaXRlIOKAlCBvbiBhIGxhcmdlIHNpdGUgdGhhdCBjYW4g
  >> "!B64TMP!" echo dGFrZSBtYW55IG1pbnV0ZXMpLiBMb25nIGNyYXdsczoKICByYWlzZSBgLS10aW1lb3V0IFNgIChk
  >> "!B64TMP!" echo ZWZhdWx0IDMwMCkgb3Iga2VlcCBwb2xsaW5nIGxhdGVyIHdpdGgKICBgd2ViX2NyYXdsX3N0YXR1
  >> "!B64TMP!" echo cy5weSA8aWQ+YDsgYm91bmQgdGhlIHByaW50ZWQgb3V0cHV0IHdpdGggYC0tbWF4LXBhZ2VzIE5g
  >> "!B64TMP!" echo CiAgKGRlZmF1bHQgMjUpIC8gYC0tbWF4LWNoYXJzIE5gIChkZWZhdWx0IDIwMDAgcGVyIHBhZ2Up
  >> "!B64TMP!" echo LgoKLSAqKkdldCBjcmF3bCBzdGF0dXMqKiBmb3IgYW4gZXhpc3RpbmcgY3Jhd2wgSUQ6CgogIGBg
  >> "!B64TMP!" echo YGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVz
  >> "!B64TMP!" echo LnB5IiAiPGlkPiIKICBgYGAKCiMjIE9wdGlvbmFsOiBtb3JlIHRvb2xzIHZpYSBhIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBhY2NvdW50CgpUaGlzIHNraWxsIHdhcyBpbnN0YWxsZWQgd2l0aG91dCBvbmUsIHNvIGl0IHNo
  >> "!B64TMP!" echo aXBzIG9ubHkgdGhlIGZyZWUgbG9jYWwKdG9vbHMuIEEgcGFpZCBGaXJlY3Jhd2wgY2xvdWQgYWNj
  >> "!B64TMP!" echo b3VudCBjYW4gYWRkIG1vcmUgdG9vbHMgbGF0ZXIgaWYgeW91IHdhbnQKdGhlbTogcmUtcnVuIGBp
  >> "!B64TMP!" echo bnN0YWxsLWxvY2FsLXNlYXJjaGAgYW5kIGFuc3dlciBgeWAgdG8gdGhlCiJBZGQgYSBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgYWNjb3VudD8iIHF1ZXN0aW9uICh0aGUgaW5zdGFsbGVyIHdyaXRlcyB0aGUgY3JlZGVudGlh
  >> "!B64TMP!" echo bHMKaW50byB0aGUgaW5zdGFsbCBmb2xkZXIncyBgLmVudmAgZm9yIHlvdSBhbmQgaW5zdGFsbHMg
  >> "!B64TMP!" echo dGhlIGV4dHJhIHNjcmlwdHMpLgoKIyMgSWYgc29tZXRoaW5nIGdvZXMgd3JvbmcKCi0gUmV0cnkg
  >> "!B64TMP!" echo KipvbmNlKiogd2l0aCBhIGRpZmZlcmVudCBxdWVyeSBvciBVUkwgYmVmb3JlIGdpdmluZyB1cC4K
  >> "!B64TMP!" echo LSBJZiBhIHNjcmlwdCBwcmludHMgYSAqKk5ldHdvcmsgY2hlY2sqKiBzYXlpbmcgdGhlIHJvdXRl
  >> "!B64TMP!" echo IHRvIGEgc2l0ZSBpcwogIGJsb2NrZWQgKGUuZy4gdGhlIHNpdGUncyBuYW1lIHJlc29sdmVzIHRv
  >> "!B64TMP!" echo IGEgcHJveHkvVlBOIGZha2UtSVAgc3VjaCBhcwogIGAxOTguMTgueC54YCBhbmQgbm90aGluZyBh
  >> "!B64TMP!" echo bnN3ZXJzKSwgZG8gbm90IHJldHJ5IHRoYXQgVVJMIGFuZCBkbyBub3Qgd2FpdDoKICB0aGUgY29u
  >> "!B64TMP!" echo bmVjdGlvbiBpcyBibG9ja2VkIGF0IHRoZSBuZXR3b3JrIGxldmVsLCBzbyByZXBlYXRpbmcgaXQg
  >> "!B64TMP!" echo b25seQogIHdhc3RlcyB0aW1lLiBVc2UgYSBkaWZmZXJlbnQgc291cmNlIGZvciB0aGUgaW5mb3Jt
  >> "!B64TMP!" echo YXRpb24gKGFub3RoZXIgVVJMLCBlLmcuCiAgZnJvbSBhIGZyZXNoIHNlYXJjaCwgd2l0aCB0aGlz
  >> "!B64TMP!" echo IHNhbWUgc2tpbGwpLCBhbmQgdGVsbCB0aGUgdXNlciB3aGF0IHRoZSBjaGVjawogIHJlcG9ydGVk
  >> "!B64TMP!" echo IHNvIHRoZXkgY2FuIGZpeCB0aGVpciBuZXR3b3JrIChwcm94eS9WUE4gVFVOIG1vZGUsIEROUyku
  >> "!B64TMP!" echo Ci0gRG9uJ3QgZmFsbCBiYWNrIHRvIGFub3RoZXIgd2ViIHRvb2wgb3ZlciBhIHByb2JsZW0gd2l0
  >> "!B64TMP!" echo aCB0aGlzIHN0YWNrIOKAlCBmaXgKICBpdCAob3IgYXNrIHRoZSB1c2VyIHRvIHN0YXJ0IERvY2tl
  >> "!B64TMP!" echo ciBEZXNrdG9wKSBhbmQgcmV0cnksIHVubGVzcyB0aGUgdXNlcgogIGFza3MgZm9yIGFuIGFsdGVy
  >> "!B64TMP!" echo bmF0aXZlLgotIElmIGEgc2NyaXB0IGNhbid0IGZpbmQgdGhlIGluc3RhbGwgZm9sZGVyIChyYXJl
  >> "!B64TMP!" echo IOKAlCBkZXRlY3Rpb24gbm9ybWFsbHkgd29ya3MKICB2aWEgdGhlIHJ1bm5pbmcgY29udGFpbmVy
  >> "!B64TMP!" echo cywgdGhlIGluc3RhbGxlcidzIHJlY29yZGVkIHBhdGgsIG9yCiAgYH4vbG9jYWwtc2VhcmNoYCks
  >> "!B64TMP!" echo IGFzayB0aGUgdXNlciBmb3IgaXRzIHBhdGggYW5kIHJlLXJ1biB3aXRoCiAgYExPQ0FMX1NFQVJD
  >> "!B64TMP!" echo SF9ESVI9PHBhdGg+YC4KLSBFeHRyYWN0IG9ubHkgd2hhdCB5b3UgbmVlZCBmcm9tIHNjcmFwZWQg
  >> "!B64TMP!" echo cGFnZXMg4oCUIGRvbid0IHBhc3RlIHdob2xlIHBhZ2VzCiAgYmFjayB0byB0aGUgdXNlci4K
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
  >> "!B64TMP!" echo aXMgYWN0dWFsbHkgbGlzdGVuaW5nIG9uLCBwbHVzIGEgcXVpY2sKbmV0d29yayBkaWFnbm9zaXMg
  >> "!B64TMP!" echo KGRpYWdub3NlX3VybCkgdGhhdCBleHBsYWlucyBXSFkgYSBzaXRlIGNvdWxkIG5vdCBiZSBsb2Fk
  >> "!B64TMP!" echo ZWQuCgpUaGUgcG9ydHMgYXJlIE5PVCBhc3N1bWVkOiB0aGV5IGFyZSByZWFkIGZyb20gdGhlIGlu
  >> "!B64TMP!" echo c3RhbGwgZm9sZGVyJ3MgLmVudgpmaWxlICh0aGUgc2FtZSBvbmUgdGhlIGNvbXBvc2Ugc2V0dXAg
  >> "!B64TMP!" echo YW5kIFJ1bi5iYXQgLyBVcGRhdGUuYmF0IHVzZSksIHNvIGlmCnRoZSB1c2VyIHBpY2tlZCBjdXN0
  >> "!B64TMP!" echo b20gcG9ydHMgZHVyaW5nIHNldHVwLCBldmVyeSBzY3JpcHQgZm9sbG93cyB0aGVtLgpEZWZhdWx0
  >> "!B64TMP!" echo cyBtaXJyb3IgdGhlIGNvbXBvc2UgZmlsZSdzICR7VkFSOi1kZWZhdWx0fSBmYWxsYmFja3M6ClNl
  >> "!B64TMP!" echo YXJYTkcgOTk5MCwgRmlyZWNyYXdsIDk5OTEuCiIiIgppbXBvcnQgZXJybm8KaW1wb3J0IGlwYWRk
  >> "!B64TMP!" echo cmVzcwppbXBvcnQgb3MKaW1wb3J0IHNodXRpbAppbXBvcnQgc29ja2V0CmltcG9ydCBzdWJwcm9j
  >> "!B64TMP!" echo ZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRocmVhZGluZwppbXBvcnQgdGltZQpmcm9tIHVybGxpYi5w
  >> "!B64TMP!" echo YXJzZSBpbXBvcnQgdXJsc3BsaXQKCiMgRGVmYXVsdCBzdGRvdXQvc3RkZXJyIHRvIFVURi04IHJl
  >> "!B64TMP!" echo Z2FyZGxlc3Mgb2YgdGhlIGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUuZy4gV2luZG93cyBjcDEy
  >> "!B64TMP!" echo NTIpLiBjb25maWcucHkgaXMgaW1wb3J0ZWQgZmlyc3QgYnkgZXZlcnkgZW50cnktcG9pbnQKIyBz
  >> "!B64TMP!" echo Y3JpcHQsIHNvIHRoaXMgY292ZXJzIHRoZSBwcm9jZXNzIGV2ZW4gaWYgdGhpcyBtb2R1bGUgaXMg
  >> "!B64TMP!" echo ZXZlciBpbXBvcnRlZAojIG9uIGl0cyBvd24uIFNraXBwZWQgaWYgUFlUSE9OSU9FTkNPRElORyBp
  >> "!B64TMP!" echo cyBhbHJlYWR5IHNldCDigJQgYW4gZXhwbGljaXQKIyBvdmVycmlkZSBhbHdheXMgd2lucy4KaWYg
  >> "!B64TMP!" echo IlBZVEhPTklPRU5DT0RJTkciIG5vdCBpbiBvcy5lbnZpcm9uOgogICAgZm9yIF9zdHJlYW0gaW4g
  >> "!B64TMP!" echo KHN5cy5zdGRvdXQsIHN5cy5zdGRlcnIpOgogICAgICAgIGlmIGhhc2F0dHIoX3N0cmVhbSwgInJl
  >> "!B64TMP!" echo Y29uZmlndXJlIik6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIF9zdHJlYW0ucmVj
  >> "!B64TMP!" echo b25maWd1cmUoZW5jb2Rpbmc9InV0Zi04IikKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHBhc3MKCiMgQ29tcG9zZSBmaWxlIG5hbWVzIGFjY2VwdGVkIGFzICJ0
  >> "!B64TMP!" echo aGlzIGlzIHRoZSBpbnN0YWxsIGZvbGRlciIuCl9DT01QT1NFX0ZJTEVTID0gKCJkb2NrZXItY29t
  >> "!B64TMP!" echo cG9zZS55bWwiLCAiZG9ja2VyLWNvbXBvc2UueWFtbCIsCiAgICAgICAgICAgICAgICAgICJjb21w
  >> "!B64TMP!" echo b3NlLnltbCIsICJjb21wb3NlLnlhbWwiKQoKIyAuZW52IGtleSAtPiBkZWZhdWx0IHBvcnQgKG1h
  >> "!B64TMP!" echo dGNoZXMgdGhlIGRlZmF1bHRzIGluIGRvY2tlci1jb21wb3NlLnltbCkuCl9QT1JUX0tFWVMgPSB7
  >> "!B64TMP!" echo CiAgICAic2VhcnhuZyI6ICgiU0VBUlhOR19QT1JUIiwgIjk5OTAiKSwKICAgICJmaXJlY3Jhd2wi
  >> "!B64TMP!" echo OiAoIkZJUkVDUkFXTF9QT1JUIiwgIjk5OTEiKSwKfQoKCmRlZiBfaGFzX2NvbXBvc2VfZmlsZShk
  >> "!B64TMP!" echo KToKICAgIHJldHVybiBkIGlzIG5vdCBOb25lIGFuZCBhbnkoCiAgICAgICAgb3MucGF0aC5pc2Zp
  >> "!B64TMP!" echo bGUob3MucGF0aC5qb2luKGQsIGYpKSBmb3IgZiBpbiBfQ09NUE9TRV9GSUxFUwogICAgKQoKCkVO
  >> "!B64TMP!" echo R0lORVMgPSAoInBvZG1hbiIsICJkb2NrZXIiKSAgIyBwcmVmZXJlbmNlIG9yZGVyOiBQb2RtYW4g
  >> "!B64TMP!" echo d2lucyB3aGVuIGJvdGggZXhpc3QKCgpkZWYgaW5zdGFsbGVkX2VuZ2luZXMoKToKICAgICIiIlRo
  >> "!B64TMP!" echo ZSBjb250YWluZXIgZW5naW5lcyBmb3VuZCBvbiBQQVRILCBpbiBwcmVmZXJlbmNlIG9yZGVyLiIi
  >> "!B64TMP!" echo IgogICAgcmV0dXJuIFtlIGZvciBlIGluIEVOR0lORVMgaWYgc2h1dGlsLndoaWNoKGUpXQoKCmRl
  >> "!B64TMP!" echo ZiBlbmdpbmVfY2hvaWNlKGluc3RhbGxfZGlyPU5vbmUpOgogICAgIiIiV2hpY2ggY29udGFpbmVy
  >> "!B64TMP!" echo IGVuZ2luZSB0byB1c2U6IChlbmdpbmUsIGF1dG8pLgoKICAgIFNhbWUgcnVsZSBhcyBlbmdpbmUu
  >> "!B64TMP!" echo c2ggKHRoZSBzaGVsbCBzY3JpcHRzKToKICAgICAgMS4gTE9DQUxfU0VBUkNIX0VOR0lORT1wb2Rt
  >> "!B64TMP!" echo YW58ZG9ja2VyIGluIHRoZSBlbnZpcm9ubWVudCAoZm9yY2VkKSwKICAgICAgMi4gTE9DQUxfU0VB
  >> "!B64TMP!" echo UkNIX0VOR0lORSBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52ICh0aGUgaW5zdGFsbGVyCiAg
  >> "!B64TMP!" echo ICAgICAgIHJlY29yZHMgaXRzIGNob2ljZSB0aGVyZSksCiAgICAgIDMuIGF1dG8tZGV0ZWN0OiBQ
  >> "!B64TMP!" echo b2RtYW4gd2hlbiBpbnN0YWxsZWQsIG90aGVyd2lzZSBEb2NrZXIuCiAgICBgZW5naW5lYCBpcyAn
  >> "!B64TMP!" echo cG9kbWFuJywgJ2RvY2tlcicgb3IgTm9uZSAobm90aGluZyB1c2FibGUgaW5zdGFsbGVkKTsKICAg
  >> "!B64TMP!" echo IGBhdXRvYCBpcyBUcnVlIHdoZW4gZGV0ZWN0aW9uIHBpY2tlZCBpdCwgaS5lLiBhIGZhbGxiYWNr
  >> "!B64TMP!" echo IHRvIHRoZSBvdGhlcgogICAgZW5naW5lIGlzIGFjY2VwdGFibGUgaWYgdGhpcyBvbmUgY2Fubm90
  >> "!B64TMP!" echo IHJ1bi4KICAgICIiIgogICAgZm9yY2VkID0gKG9zLmVudmlyb24uZ2V0KCJMT0NBTF9TRUFSQ0hf
  >> "!B64TMP!" echo RU5HSU5FIikgb3IgIiIpLnN0cmlwKCkubG93ZXIoKQogICAgd2FudCA9IGZvcmNlZCBvciBsb2Fk
  >> "!B64TMP!" echo X2VudihpbnN0YWxsX2RpcikuZ2V0KCJMT0NBTF9TRUFSQ0hfRU5HSU5FIiwgIiIpLnN0cmlwKCku
  >> "!B64TMP!" echo bG93ZXIoKQogICAgaWYgd2FudCBpbiBFTkdJTkVTOgogICAgICAgIGlmIHNodXRpbC53aGljaCh3
  >> "!B64TMP!" echo YW50KToKICAgICAgICAgICAgcmV0dXJuIHdhbnQsIEZhbHNlCiAgICAgICAgaWYgZm9yY2VkOiAg
  >> "!B64TMP!" echo IyBhbiBleHBsaWNpdCBvdmVycmlkZSBtdXN0IG5vdCBiZSBzaWxlbnRseSBpZ25vcmVkCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBOb25lLCBGYWxzZQogICAgZm91bmQgPSBpbnN0YWxsZWRfZW5naW5lcygp
  >> "!B64TMP!" echo CiAgICByZXR1cm4gKGZvdW5kWzBdIGlmIGZvdW5kIGVsc2UgTm9uZSksIFRydWUKCgpkZWYgX2xh
  >> "!B64TMP!" echo YmVsZWRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlciBwZXIgdGhlIGNv
  >> "!B64TMP!" echo bXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMuIENvbXBvc2UKICAgIHRhZ3MgZWFjaCBjb250
  >> "!B64TMP!" echo YWluZXIgd2l0aCB0aGUgZGlyZWN0b3J5IGl0IHdhcyBzdGFydGVkIGZyb20sIHNvIHRoaXMKICAg
  >> "!B64TMP!" echo IGZpbmRzIHRoZSBmb2xkZXIgZXZlbiB0aG91Z2ggdGhlIHNraWxsIGl0c2VsZiBsaXZlcyBlbHNl
  >> "!B64TMP!" echo d2hlcmUuIEEKICAgIGNvbnRhaW5lciBlbmdpbmUgKFBvZG1hbiBvciBEb2NrZXIpIG11c3QgYmUg
  >> "!B64TMP!" echo cnVubmluZy4iIiIKICAgIGZvcmNlZCA9IChvcy5lbnZpcm9uLmdldCgiTE9DQUxfU0VBUkNIX0VO
  >> "!B64TMP!" echo R0lORSIpIG9yICIiKS5zdHJpcCgpLmxvd2VyKCkKICAgICMgYW4gZXhwbGljaXQgTE9DQUxfU0VB
  >> "!B64TMP!" echo UkNIX0VOR0lORSBtZWFucyAib25seSB0aGF0IGVuZ2luZSIKICAgIGZvciBlbmdpbmUgaW4gKFtm
  >> "!B64TMP!" echo b3JjZWRdIGlmIGZvcmNlZCBpbiBFTkdJTkVTIGFuZCBzaHV0aWwud2hpY2goZm9yY2VkKSBlbHNl
  >> "!B64TMP!" echo IGluc3RhbGxlZF9lbmdpbmVzKCkpOgogICAgICAgIHRyeToKICAgICAgICAgICAgcmVzID0gc3Vi
  >> "!B64TMP!" echo cHJvY2Vzcy5ydW4oCiAgICAgICAgICAgICAgICBbZW5naW5lLCAiY29udGFpbmVyIiwgImxzIiwg
  >> "!B64TMP!" echo Ii1hIiwgIi1xIiwKICAgICAgICAgICAgICAgICAiLS1maWx0ZXIiLCAibGFiZWw9Y29tLmRvY2tl
  >> "!B64TMP!" echo ci5jb21wb3NlLnNlcnZpY2U9c2VhcnhuZyJdLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnBy
  >> "!B64TMP!" echo b2Nlc3MuUElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAg
  >> "!B64TMP!" echo ICAgICBpZHMgPSByZXMuc3Rkb3V0LnNwbGl0KClbOjNdCiAgICAgICAgZXhjZXB0IChPU0Vycm9y
  >> "!B64TMP!" echo LCBGaWxlTm90Rm91bmRFcnJvcik6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgZm9yIGNp
  >> "!B64TMP!" echo ZCBpbiBpZHM6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG91dCA9IHN1YnByb2Nl
  >> "!B64TMP!" echo c3MucnVuKAogICAgICAgICAgICAgICAgICAgIFtlbmdpbmUsICJjb250YWluZXIiLCAiaW5zcGVj
  >> "!B64TMP!" echo dCIsIGNpZCwKICAgICAgICAgICAgICAgICAgICAgIi0tZm9ybWF0IiwKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgJ3t7aW5kZXggLkNvbmZpZy5MYWJlbHMgImNvbS5kb2NrZXIuY29tcG9zZS5wcm9qZWN0
  >> "!B64TMP!" echo LndvcmtpbmdfZGlyIn19J10sCiAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nlc3Mu
  >> "!B64TMP!" echo UElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgICAgICBl
  >> "!B64TMP!" echo eGNlcHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9yKToKICAgICAgICAgICAgICAgIGNvbnRp
  >> "!B64TMP!" echo bnVlCiAgICAgICAgICAgIHAgPSBvdXQuc3Rkb3V0LnN0cmlwKCkKICAgICAgICAgICAgaWYgcCBh
  >> "!B64TMP!" echo bmQgb3MucGF0aC5pc2RpcihwKToKICAgICAgICAgICAgICAgIHJldHVybiBwCiAgICByZXR1cm4g
  >> "!B64TMP!" echo Tm9uZQoKCmRlZiBfaGludGVkX2luc3RhbGxfZGlyKCk6CiAgICAiIiJUaGUgaW5zdGFsbCBwYXRo
  >> "!B64TMP!" echo IHJlY29yZGVkIGJ5IHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbGVyIHdoZW4gaXQKICAgIGNvcGll
  >> "!B64TMP!" echo ZCB0aGlzIHNraWxsIChpbnN0YWxsLWRpci50eHQgbmV4dCB0byBTS0lMTC5tZCkuIFRoaXMgd29y
  >> "!B64TMP!" echo a3MgZXZlbgogICAgd2hlbiB0aGUgY29udGFpbmVyIGVuZ2luZSBpcyBkb3duIGFuZCB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIgaXMgbm90IGluIHRoZQogICAgZGVmYXVsdCBsb2NhdGlvbi4gUmV0dXJucyBO
  >> "!B64TMP!" echo b25lIHdoZW4gdGhlcmUgaXMgbm8gaGludCBmaWxlIChlLmcuIHRoZQogICAgc2tpbGwgd2FzIGlu
  >> "!B64TMP!" echo c3RhbGxlZCBzdGFuZGFsb25lIGZyb20gdGhlIGxvY2FsLXdlYi1zZWFyY2ggcmVwbykuIiIiCiAg
  >> "!B64TMP!" echo ICBoaW50X2ZpbGUgPSBvcy5wYXRoLmpvaW4ob3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0
  >> "!B64TMP!" echo aChfX2ZpbGVfXykpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9zLnBhcmRpciwgImlu
  >> "!B64TMP!" echo c3RhbGwtZGlyLnR4dCIpCiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKGhpbnRfZmlsZSwgZW5j
  >> "!B64TMP!" echo b2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgICAgIHBhdGggPSBmaC5yZWFkKCkuc3RyaXAo
  >> "!B64TMP!" echo KS5yc3RyaXAoIlxcLyIpLnN0cmlwKCkKICAgICAgICByZXR1cm4gcGF0aCBvciBOb25lCiAgICBl
  >> "!B64TMP!" echo eGNlcHQgT1NFcnJvcjoKICAgICAgICByZXR1cm4gTm9uZQoKCmRlZiBmaW5kX2luc3RhbGxfZGly
  >> "!B64TMP!" echo KCk6CiAgICAiIiJUaGUgbG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyIChob2xkcyB0aGUgY29t
  >> "!B64TMP!" echo cG9zZSBmaWxlKSwgb3IgTm9uZS4KCiAgICBMb29rZWQgdXAgaW4gb3JkZXI6CiAgICAgIDEuIHRo
  >> "!B64TMP!" echo ZSBMT0NBTF9TRUFSQ0hfRElSIGVudiB2YXIgKGV4cGxpY2l0IG92ZXJyaWRlKSwKICAgICAgMi4g
  >> "!B64TMP!" echo dGhlIGNvbXBvc2UgbGFiZWwgb24gdGhlIGNvbnRhaW5lcnMgKGFuIGVuZ2luZSBtdXN0IGJlIHJ1
  >> "!B64TMP!" echo bm5pbmcpLAogICAgICAzLiBpbnN0YWxsLWRpci50eHQgcmVjb3JkZWQgYnkgdGhlIGxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaCBpbnN0YWxsZXIsCiAgICAgIDQuIH4vbG9jYWwtc2VhcmNoICh0aGUgaW5zdGFsbGVyJ3Mg
  >> "!B64TMP!" echo ZGVmYXVsdCBsb2NhdGlvbikuCiAgICAiIiIKICAgIGZvciBkIGluIChvcy5lbnZpcm9uLmdldCgi
  >> "!B64TMP!" echo TE9DQUxfU0VBUkNIX0RJUiIpLAogICAgICAgICAgICAgIF9sYWJlbGVkX2luc3RhbGxfZGlyKCks
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgX2hpbnRlZF9pbnN0YWxsX2RpcigpLAogICAgICAgICAgICAgIG9zLnBh
  >> "!B64TMP!" echo dGguZXhwYW5kdXNlcigifi9sb2NhbC1zZWFyY2giKSk6CiAgICAgICAgaWYgZCBhbmQgX2hhc19j
  >> "!B64TMP!" echo b21wb3NlX2ZpbGUoZCk6CiAgICAgICAgICAgIHJldHVybiBkCiAgICByZXR1cm4gTm9uZQoKCmRl
  >> "!B64TMP!" echo ZiBsb2FkX2VudihpbnN0YWxsX2Rpcik6CiAgICAiIiJUaGUgaW5zdGFsbCBmb2xkZXIncyAuZW52
  >> "!B64TMP!" echo IGFzIGEgZGljdCAoZW1wdHkgZGljdCBpZiBtaXNzaW5nL2ludmFsaWQpLiIiIgogICAgdmFsdWVz
  >> "!B64TMP!" echo ID0ge30KICAgIGlmIG5vdCBpbnN0YWxsX2RpcjoKICAgICAgICByZXR1cm4gdmFsdWVzCiAgICB0
  >> "!B64TMP!" echo cnk6CiAgICAgICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihpbnN0YWxsX2RpciwgIi5lbnYiKSwg
  >> "!B64TMP!" echo ZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgICAgIGZvciBsaW5lIGluIGZoOgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgICAgICAgICAgaWYgbm90IGxp
  >> "!B64TMP!" echo bmUgb3IgbGluZS5zdGFydHN3aXRoKCIjIikgb3IgIj0iIG5vdCBpbiBsaW5lOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICAgICBrZXksIF8sIHZhbCA9IGxpbmUucGFy
  >> "!B64TMP!" echo dGl0aW9uKCI9IikKICAgICAgICAgICAgICAgIHZhbHVlc1trZXkuc3RyaXAoKV0gPSB2YWwuc3Ry
  >> "!B64TMP!" echo aXAoKS5zdHJpcCgnIicpLnN0cmlwKCInIikKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHBh
  >> "!B64TMP!" echo c3MKICAgIHJldHVybiB2YWx1ZXMKCgpkZWYgZW5kcG9pbnRzKGluc3RhbGxfZGlyPU5vbmUpOgog
  >> "!B64TMP!" echo ICAgIiIieydzZWFyeG5nJzogJ2h0dHA6Ly9sb2NhbGhvc3Q6PHBvcnQ+JywgJ2ZpcmVjcmF3bCc6
  >> "!B64TMP!" echo ICcuLi4nfSwgd2l0aCB0aGUKICAgIHBvcnRzIHRha2VuIGZyb20gdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgLmVudiAoZGVmYXVsdHMgOTk5MC85OTkxKS4iIiIKICAgIHZhbHVlcyA9IGxvYWRfZW52KGlu
  >> "!B64TMP!" echo c3RhbGxfZGlyKQogICAgdXJscyA9IHt9CiAgICBmb3IgbmFtZSwgKGtleSwgZGVmYXVsdCkgaW4g
  >> "!B64TMP!" echo X1BPUlRfS0VZUy5pdGVtcygpOgogICAgICAgIHBvcnQgPSB2YWx1ZXMuZ2V0KGtleSkKICAgICAg
  >> "!B64TMP!" echo ICBpZiBub3QgcG9ydCBvciBub3QgcG9ydC5pc2RpZ2l0KCk6CiAgICAgICAgICAgIHBvcnQgPSBk
  >> "!B64TMP!" echo ZWZhdWx0CiAgICAgICAgdXJsc1tuYW1lXSA9ICJodHRwOi8vbG9jYWxob3N0Ont9Ii5mb3JtYXQo
  >> "!B64TMP!" echo cG9ydCkKICAgIHJldHVybiB1cmxzCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyAiV2h5IGRpZCB0
  >> "!B64TMP!" echo aGlzIHNpdGUgZmFpbD8iIC0gYSBxdWljayBuZXR3b3JrIGRpYWdub3NpcyBydW4gZnJvbSBUSElT
  >> "!B64TMP!" echo IG1hY2hpbmUKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KIyBGaXJlY3Jhd2wgcmVwb3J0cyBhIHNpdGUg
  >> "!B64TMP!" echo aXQgY2Fubm90IGxvYWQgYXMgYSBnZW5lcmljIGVycm9yIG9yIGEgdGltZW91dCwgYW5kCiMgYSBj
  >> "!B64TMP!" echo bGllbnQgdGhhdCBvbmx5IHNlZXMgdGhhdCB0ZW5kcyB0byB3YWl0IGFuZCByZXRyeS4gVmVyeSBv
  >> "!B64TMP!" echo ZnRlbiB0aGUgcmVhbAojIGNhdXNlIGlzIGxvY2FsIGFuZCBzdGF5cyB1bnRpbCB0aGUgbmV0d29y
  >> "!B64TMP!" echo ayBzZXR1cCBjaGFuZ2VzOiB0aGUgbmFtZSByZXNvbHZlcwojIHRvIGFuIGFkZHJlc3Mgbm90aGlu
  >> "!B64TMP!" echo ZyBhbnN3ZXJzIG9uIC0gdHlwaWNhbGx5IGEgcHJveHkvVlBOIHRvb2wncyBmYWtlLUlQIEROUwoj
  >> "!B64TMP!" echo IGhhbmRpbmcgb3V0IDE5OC4xOC4wLjAvMTUgd2hpbGUgaXRzIHR1bm5lbCBpcyBub3QgY2Fycnlp
  >> "!B64TMP!" echo bmcgdGhlIHRyYWZmaWMsIHNvCiMgZXZlcnkgcGFja2V0IGlzIHNpbGVudGx5IGRyb3BwZWQuIGRp
  >> "!B64TMP!" echo YWdub3NlX3VybCgpIHJlc29sdmVzIHRoZSBob3N0IGFuZCBtYWtlcwojIG9uZSBzaG9ydCBUQ1Ag
  >> "!B64TMP!" echo Y29ubmVjdGlvbiBwZXIgYWRkcmVzcyB0byBzYXkgc28gcGxhaW5seS4gSXQgb25seSBydW5zIEFG
  >> "!B64TMP!" echo VEVSIGEKIyBmYWlsdXJlIChuZXZlciBvbiB0aGUgaGFwcHkgcGF0aCksIGlzIGJvdW5kZWQgdG8g
  >> "!B64TMP!" echo YSBmZXcgc2Vjb25kcywgYW5kIG5ldmVyCiMgcmFpc2VzLgoKX0ZBS0VfSVBfTkVUID0gaXBhZGRy
  >> "!B64TMP!" echo ZXNzLmlwX25ldHdvcmsoIjE5OC4xOC4wLjAvMTUiKSAgIyBSRkMgMjU0NCBiZW5jaG1hcmtpbmcg
  >> "!B64TMP!" echo cmFuZ2UKX1NIQVJFRF9ORVQgPSBpcGFkZHJlc3MuaXBfbmV0d29yaygiMTAwLjY0LjAuMC8xMCIp
  >> "!B64TMP!" echo ICAgIyBSRkMgNjU5OCBDR05BVCAvIFZQTiBvdmVybGF5cwoKX0tJTkRfVEVYVCA9IHsKICAgICJm
  >> "!B64TMP!" echo YWtlLWlwIjogKCJhIGZha2UtSVAgYWRkcmVzcyAoMTk4LjE4LjAuMC8xNSBpcyByZXNlcnZlZCBm
  >> "!B64TMP!" echo b3IgYmVuY2htYXJraW5nIGFuZCBpcyAiCiAgICAgICAgICAgICAgICAibmV2ZXIgcm91dGVkIG9u
  >> "!B64TMP!" echo IHRoZSBpbnRlcm5ldDsgcHJveHkvVlBOIHRvb2xzIHN1Y2ggYXMgQ2xhc2gsIE1paG9tbywgIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIlN1cmdlLCBzaW5nLWJveCBvciBTaGFkb3dyb2NrZXQgaGFuZCB0aGVz
  >> "!B64TMP!" echo ZSBvdXQgaW4gZmFrZS1JUCBETlMgbW9kZSBhbmQgIgogICAgICAgICAgICAgICAgInJlbGF5IHRo
  >> "!B64TMP!" echo ZSB0cmFmZmljIHRoZW1zZWx2ZXMpIiksCiAgICAic2hhcmVkIjogKCJhIHNoYXJlZC1hZGRyZXNz
  >> "!B64TMP!" echo LXNwYWNlIGFkZHJlc3MgKDEwMC42NC4wLjAvMTA6IGNhcnJpZXItZ3JhZGUgTkFUIG9yIGEgIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAiVlBOIG92ZXJsYXkgc3VjaCBhcyBUYWlsc2NhbGUpIiksCiAgICAibG9v
  >> "!B64TMP!" echo cGJhY2siOiAiYSBsb29wYmFjayBhZGRyZXNzICh0aGlzIG1hY2hpbmUgaXRzZWxmKSIsCiAgICAi
  >> "!B64TMP!" echo bGluay1sb2NhbCI6ICJhIGxpbmstbG9jYWwgYWRkcmVzcyIsCiAgICAicHJpdmF0ZSI6ICJhIHBy
  >> "!B64TMP!" echo aXZhdGUtbmV0d29yayBhZGRyZXNzIiwKICAgICJyZXNlcnZlZCI6ICJhIHJlc2VydmVkLCBub24t
  >> "!B64TMP!" echo cHVibGljIGFkZHJlc3MiLAp9CgojIGdldGFkZHJpbmZvIGVycm9yIGNvZGVzIHRoYXQgbWVhbiAi
  >> "!B64TMP!" echo dGhpcyBuYW1lIGRvZXMgbm90IGV4aXN0IiAobm90IGEgaGljY3VwKS4KX05PX1NVQ0hfTkFNRSA9
  >> "!B64TMP!" echo IHNldChjIGZvciBjIGluIChnZXRhdHRyKHNvY2tldCwgIkVBSV9OT05BTUUiLCBOb25lKSwKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICBnZXRhdHRyKHNvY2tldCwgIkVBSV9OT0RBVEEi
  >> "!B64TMP!" echo LCBOb25lKSwgMTEwMDEpCiAgICAgICAgICAgICAgICAgICAgaWYgYyBpcyBub3QgTm9uZSkKCgpk
  >> "!B64TMP!" echo ZWYgY2xhc3NpZnlfaXAoYWRkcik6CiAgICAiIiJLaW5kIG9mIGEgTk9OLXB1YmxpYyBhZGRyZXNz
  >> "!B64TMP!" echo OiAnZmFrZS1pcCcsICdzaGFyZWQnLCAnbG9vcGJhY2snLAogICAgJ2xpbmstbG9jYWwnLCAncHJp
  >> "!B64TMP!" echo dmF0ZScgb3IgJ3Jlc2VydmVkJzsgTm9uZSBmb3IgYW4gb3JkaW5hcnkgcHVibGljIG9uZQogICAg
  >> "!B64TMP!" echo KG9yIHNvbWV0aGluZyB0aGF0IGlzIG5vdCBhbiBJUCBhZGRyZXNzKS4iIiIKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICBpcCA9IGlwYWRkcmVzcy5pcF9hZGRyZXNzKHN0cihhZGRyKS5zcGxpdCgiJSIsIDEpWzBd
  >> "!B64TMP!" echo KQogICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIG1hcHBlZCA9
  >> "!B64TMP!" echo IGdldGF0dHIoaXAsICJpcHY0X21hcHBlZCIsIE5vbmUpCiAgICBpZiBtYXBwZWQgaXMgbm90IE5v
  >> "!B64TMP!" echo bmU6CiAgICAgICAgaXAgPSBtYXBwZWQKICAgIGlmIGlwLnZlcnNpb24gPT0gNCBhbmQgaXAgaW4g
  >> "!B64TMP!" echo X0ZBS0VfSVBfTkVUOgogICAgICAgIHJldHVybiAiZmFrZS1pcCIKICAgIGlmIGlwLnZlcnNpb24g
  >> "!B64TMP!" echo PT0gNCBhbmQgaXAgaW4gX1NIQVJFRF9ORVQ6CiAgICAgICAgcmV0dXJuICJzaGFyZWQiCiAgICBp
  >> "!B64TMP!" echo ZiBpcC5pc19sb29wYmFjazoKICAgICAgICByZXR1cm4gImxvb3BiYWNrIgogICAgaWYgaXAuaXNf
  >> "!B64TMP!" echo bGlua19sb2NhbDoKICAgICAgICByZXR1cm4gImxpbmstbG9jYWwiCiAgICBpZiBpcC5pc19wcml2
  >> "!B64TMP!" echo YXRlOgogICAgICAgIHJldHVybiAicHJpdmF0ZSIKICAgIGlmIGlwLmlzX3Vuc3BlY2lmaWVkIG9y
  >> "!B64TMP!" echo IGlwLmlzX211bHRpY2FzdCBvciBpcC5pc19yZXNlcnZlZCBvciBub3QgaXAuaXNfZ2xvYmFsOgog
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiAicmVzZXJ2ZWQiCiAgICByZXR1cm4gTm9uZQoKCmRlZiBpc190aW1lb3V0
  >> "!B64TMP!" echo KGV4Yyk6CiAgICAiIiJUcnVlIHdoZW4gYGV4Y2AgKG9yIHRoZSByZWFzb24gd3JhcHBlZCBpbnNp
  >> "!B64TMP!" echo ZGUgYSBVUkxFcnJvcikgaXMgYSB0aW1lb3V0LiIiIgogICAgaWYgaXNpbnN0YW5jZShleGMsIChz
  >> "!B64TMP!" echo b2NrZXQudGltZW91dCwgVGltZW91dEVycm9yKSk6CiAgICAgICAgcmV0dXJuIFRydWUKICAgIHJl
  >> "!B64TMP!" echo dHVybiBpc2luc3RhbmNlKGdldGF0dHIoZXhjLCAicmVhc29uIiwgTm9uZSksIChzb2NrZXQudGlt
  >> "!B64TMP!" echo ZW91dCwgVGltZW91dEVycm9yKSkKCgpkZWYgdGNwX3Byb2JlKGFkZHIsIHBvcnQsIHRpbWVvdXQ9
  >> "!B64TMP!" echo My4wKToKICAgICIiIk9uZSBUQ1AgY29ubmVjdGlvbiBhdHRlbXB0IC0+IChzdGF0ZSwgc2Vjb25k
  >> "!B64TMP!" echo cykuIHN0YXRlIGlzICdvcGVuJywKICAgICd0aW1lb3V0JyAocGFja2V0cyBkcm9wcGVkKSwgJ3Jl
  >> "!B64TMP!" echo ZnVzZWQnLCAndW5yZWFjaGFibGUnIG9yICdlcnJvcicuIiIiCiAgICBzdGFydCA9IHRpbWUudGlt
  >> "!B64TMP!" echo ZSgpCiAgICB0cnk6CiAgICAgICAgd2l0aCBzb2NrZXQuY3JlYXRlX2Nvbm5lY3Rpb24oKGFkZHIs
  >> "!B64TMP!" echo IHBvcnQpLCB0aW1lb3V0PXRpbWVvdXQpOgogICAgICAgICAgICByZXR1cm4gIm9wZW4iLCB0aW1l
  >> "!B64TMP!" echo LnRpbWUoKSAtIHN0YXJ0CiAgICBleGNlcHQgKHNvY2tldC50aW1lb3V0LCBUaW1lb3V0RXJyb3Ip
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiAidGltZW91dCIsIHRpbWUudGltZSgpIC0gc3RhcnQKICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBDb25uZWN0aW9uUmVmdXNlZEVycm9yOgogICAgICAgIHJldHVybiAicmVmdXNlZCIsIHRpbWUu
  >> "!B64TMP!" echo dGltZSgpIC0gc3RhcnQKICAgIGV4Y2VwdCBPU0Vycm9yIGFzIGU6CiAgICAgICAgZ29uZSA9IChl
  >> "!B64TMP!" echo cnJuby5FTkVUVU5SRUFDSCwgZXJybm8uRUhPU1RVTlJFQUNIKQogICAgICAgIGlmIGdldGF0dHIo
  >> "!B64TMP!" echo ZSwgImVycm5vIiwgTm9uZSkgaW4gZ29uZSBvciBnZXRhdHRyKGUsICJ3aW5lcnJvciIsIE5vbmUp
  >> "!B64TMP!" echo IGluICgxMDA1MSwgMTAwNjUpOgogICAgICAgICAgICByZXR1cm4gInVucmVhY2hhYmxlIiwgdGlt
  >> "!B64TMP!" echo ZS50aW1lKCkgLSBzdGFydAogICAgICAgIHJldHVybiAiZXJyb3IiLCB0aW1lLnRpbWUoKSAtIHN0
  >> "!B64TMP!" echo YXJ0CgoKZGVmIHBvcnRfbGlzdGVuaW5nKGVuZHBvaW50LCB0aW1lb3V0PTEuMCk6CiAgICAiIiJU
  >> "!B64TMP!" echo cnVlIHdoZW4gc29tZXRoaW5nIGFjY2VwdHMgVENQIGNvbm5lY3Rpb25zIGF0IGFuIGh0dHAocykg
  >> "!B64TMP!" echo ZW5kcG9pbnQgVVJMCiAgICAodXNlZCB0byB0ZWxsICd0aGUgc3RhY2sgaXMgZG93bicgZnJvbSAn
  >> "!B64TMP!" echo dGhlIHN0YWNrIGlzIHVwIGJ1dCBzbG93JykuIiIiCiAgICB0cnk6CiAgICAgICAgcGFydHMgPSB1
  >> "!B64TMP!" echo cmxzcGxpdChlbmRwb2ludCkKICAgICAgICBob3N0ID0gcGFydHMuaG9zdG5hbWUgb3IgImxvY2Fs
  >> "!B64TMP!" echo aG9zdCIKICAgICAgICBwb3J0ID0gcGFydHMucG9ydCBvciAoNDQzIGlmIHBhcnRzLnNjaGVtZSA9
  >> "!B64TMP!" echo PSAiaHR0cHMiIGVsc2UgODApCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UKICAgIHJldHVybiB0Y3BfcHJvYmUoaG9zdCwgcG9ydCwgdGltZW91dClbMF0gPT0gIm9w
  >> "!B64TMP!" echo ZW4iCgoKZGVmIF9yZXNvbHZlKGhvc3QsIHRpbWVvdXQpOgogICAgIiIiQWRkcmVzc2VzIHRoZSBz
  >> "!B64TMP!" echo eXN0ZW0gcmVzb2x2ZXIgZ2l2ZXMgZm9yIGBob3N0YCAoZGVkdXBsaWNhdGVkLCBpbiBvcmRlciku
  >> "!B64TMP!" echo CiAgICBSYWlzZXMgc29ja2V0LmdhaWVycm9yIC8gVGltZW91dEVycm9yIChnZXRhZGRyaW5mbyBp
  >> "!B64TMP!" echo dHNlbGYgaGFzIG5vIHRpbWVvdXQpLiIiIgogICAgYm94ID0ge30KCiAgICBkZWYgd29yaygpOgog
  >> "!B64TMP!" echo ICAgICAgIHRyeToKICAgICAgICAgICAgYm94WyJ2Il0gPSBzb2NrZXQuZ2V0YWRkcmluZm8oaG9z
  >> "!B64TMP!" echo dCwgTm9uZSwgdHlwZT1zb2NrZXQuU09DS19TVFJFQU0pCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlv
  >> "!B64TMP!" echo biBhcyBlOiAgIyBoYW5kZWQgYmFjayB0byB0aGUgY2FsbGVyIGJlbG93CiAgICAgICAgICAgIGJv
  >> "!B64TMP!" echo eFsiZSJdID0gZQoKICAgIHQgPSB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD13b3JrLCBkYWVtb249
  >> "!B64TMP!" echo VHJ1ZSkKICAgIHQuc3RhcnQoKQogICAgdC5qb2luKHRpbWVvdXQpCiAgICBpZiB0LmlzX2FsaXZl
  >> "!B64TMP!" echo KCk6CiAgICAgICAgcmFpc2UgVGltZW91dEVycm9yKCJETlMgbG9va3VwIHRpbWVkIG91dCBhZnRl
  >> "!B64TMP!" echo ciB7Omd9cyIuZm9ybWF0KHRpbWVvdXQpKQogICAgaWYgImUiIGluIGJveDoKICAgICAgICByYWlz
  >> "!B64TMP!" echo ZSBib3hbImUiXQogICAgYWRkcnMgPSBbXQogICAgZm9yIGluZm8gaW4gYm94WyJ2Il06CiAgICAg
  >> "!B64TMP!" echo ICAgYSA9IGluZm9bNF1bMF0KICAgICAgICBpZiBhIG5vdCBpbiBhZGRyczoKICAgICAgICAgICAg
  >> "!B64TMP!" echo YWRkcnMuYXBwZW5kKGEpCiAgICByZXR1cm4gYWRkcnMKCgpkZWYgX3Byb2JlX2FsbChhZGRycywg
  >> "!B64TMP!" echo cG9ydCwgdGltZW91dCk6CiAgICAiIiJ0Y3BfcHJvYmUgZXZlcnkgYWRkcmVzcyBpbiBwYXJhbGxl
  >> "!B64TMP!" echo bCAtPiBbKGFkZHIsIHN0YXRlLCBzZWNvbmRzKV0uIiIiCiAgICBmb3VuZCA9IHt9CgogICAgZGVm
  >> "!B64TMP!" echo IHdvcmsoYSk6CiAgICAgICAgZm91bmRbYV0gPSB0Y3BfcHJvYmUoYSwgcG9ydCwgdGltZW91dCkK
  >> "!B64TMP!" echo CiAgICB0aHJlYWRzID0gW3RocmVhZGluZy5UaHJlYWQodGFyZ2V0PXdvcmssIGFyZ3M9KGEsKSwg
  >> "!B64TMP!" echo ZGFlbW9uPVRydWUpIGZvciBhIGluIGFkZHJzXQogICAgZm9yIHQgaW4gdGhyZWFkczoKICAgICAg
  >> "!B64TMP!" echo ICB0LnN0YXJ0KCkKICAgIGZvciB0IGluIHRocmVhZHM6CiAgICAgICAgdC5qb2luKHRpbWVvdXQg
  >> "!B64TMP!" echo KyAxLjApCiAgICByZXR1cm4gWyhhLCkgKyBmb3VuZC5nZXQoYSwgKCJ0aW1lb3V0IiwgdGltZW91
  >> "!B64TMP!" echo dCkpIGZvciBhIGluIGFkZHJzXQoKCmNsYXNzIERpYWdub3NpcyhvYmplY3QpOgogICAgIiIiT3V0
  >> "!B64TMP!" echo Y29tZSBvZiBkaWFnbm9zZV91cmwoKS4KCiAgICBibG9ja2VkICAgVHJ1ZSB3aGVuIG5vIGNvbm5l
  >> "!B64TMP!" echo Y3Rpb24gdG8gdGhlIHNpdGUgY291bGQgYmUgbWFkZSBmcm9tIHRoaXMKICAgICAgICAgICAgICBt
  >> "!B64TMP!" echo YWNoaW5lIHJpZ2h0IG5vdyAtIHdhaXRpbmcgYW5kIHJlLXJ1bm5pbmcgdGhlIHNhbWUgcmVxdWVz
  >> "!B64TMP!" echo dAogICAgICAgICAgICAgIHdpbGwgbm90IGNoYW5nZSB0aGF0LCBzbyBjYWxsZXJzIG11c3Qgbm90
  >> "!B64TMP!" echo IHJldHJ5IGl0LgogICAgdGV4dCAgICAgIHRoZSBwcmludGFibGUgbXVsdGktbGluZSBleHBsYW5h
  >> "!B64TMP!" echo dGlvbi4iIiIKCiAgICBkZWYgX19pbml0X18oc2VsZiwgaG9zdCwgYmxvY2tlZCwgbGluZXMpOgog
  >> "!B64TMP!" echo ICAgICAgIHNlbGYuaG9zdCA9IGhvc3QKICAgICAgICBzZWxmLmJsb2NrZWQgPSBibG9ja2VkCiAg
  >> "!B64TMP!" echo ICAgICAgc2VsZi5saW5lcyA9IGxpbmVzCgogICAgQHByb3BlcnR5CiAgICBkZWYgdGV4dChzZWxm
  >> "!B64TMP!" echo KToKICAgICAgICByZXR1cm4gIlxuIi5qb2luKHNlbGYubGluZXMpCgoKZGVmIF9kZXNjcmliZV9w
  >> "!B64TMP!" echo cm9iZShhZGRyLCBzdGF0ZSwgc2VjcywgdGltZW91dCk6CiAgICBpZiBzdGF0ZSA9PSAib3BlbiI6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuICJ7fTogY29ubmVjdGVkIGluIHs6LjFmfXMiLmZvcm1hdChhZGRyLCBz
  >> "!B64TMP!" echo ZWNzKQogICAgaWYgc3RhdGUgPT0gInRpbWVvdXQiOgogICAgICAgIHJldHVybiAie306IG5vIGFu
  >> "!B64TMP!" echo c3dlciB3aXRoaW4gezpnfXMgKHBhY2tldHMgYXJlIGJlaW5nIGRyb3BwZWQpIi5mb3JtYXQoYWRk
  >> "!B64TMP!" echo ciwgdGltZW91dCkKICAgIGlmIHN0YXRlID09ICJyZWZ1c2VkIjoKICAgICAgICByZXR1cm4gInt9
  >> "!B64TMP!" echo OiBjb25uZWN0aW9uIHJlZnVzZWQiLmZvcm1hdChhZGRyKQogICAgaWYgc3RhdGUgPT0gInVucmVh
  >> "!B64TMP!" echo Y2hhYmxlIjoKICAgICAgICByZXR1cm4gInt9OiBubyByb3V0ZSB0byBob3N0Ii5mb3JtYXQoYWRk
  >> "!B64TMP!" echo cikKICAgIHJldHVybiAie306IGNvbm5lY3Rpb24gZmFpbGVkIi5mb3JtYXQoYWRkcikKCgpkZWYg
  >> "!B64TMP!" echo X2RpYWdub3NlKHVybCwgY29ubmVjdF90aW1lb3V0LCBkbnNfdGltZW91dCk6CiAgICBwYXJ0cyA9
  >> "!B64TMP!" echo IHVybHNwbGl0KHVybCBpZiAiOi8vIiBpbiB1cmwgZWxzZSAiaHR0cHM6Ly8iICsgdXJsKQogICAg
  >> "!B64TMP!" echo aG9zdCA9IHBhcnRzLmhvc3RuYW1lCiAgICBpZiBub3QgaG9zdCBvciBwYXJ0cy5zY2hlbWUgbm90
  >> "!B64TMP!" echo IGluICgiaHR0cCIsICJodHRwcyIpOgogICAgICAgIHJldHVybiBOb25lCiAgICBpZiBob3N0Lmxv
  >> "!B64TMP!" echo d2VyKCkgPT0gImxvY2FsaG9zdCIgb3IgaG9zdC5sb3dlcigpLmVuZHN3aXRoKCIubG9jYWxob3N0
  >> "!B64TMP!" echo Iik6CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIHRyeToKICAgICAgICBwb3J0ID0gcGFydHMucG9y
  >> "!B64TMP!" echo dCBvciAoODAgaWYgcGFydHMuc2NoZW1lID09ICJodHRwIiBlbHNlIDQ0MykKICAgIGV4Y2VwdCBW
  >> "!B64TMP!" echo YWx1ZUVycm9yOgogICAgICAgIHJldHVybiBOb25lCgogICAgdHJ5OgogICAgICAgIGxpdGVyYWwg
  >> "!B64TMP!" echo PSBpcGFkZHJlc3MuaXBfYWRkcmVzcyhob3N0KQogICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAg
  >> "!B64TMP!" echo ICAgbGl0ZXJhbCA9IE5vbmUKICAgIGlmIGxpdGVyYWwgaXMgbm90IE5vbmU6CiAgICAgICAgaWYg
  >> "!B64TMP!" echo bGl0ZXJhbC5pc19sb29wYmFjazoKICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICBhZGRy
  >> "!B64TMP!" echo cyA9IFtob3N0XQogICAgZWxzZToKICAgICAgICB0cnk6CiAgICAgICAgICAgIGFkZHJzID0gX3Jl
  >> "!B64TMP!" echo c29sdmUoaG9zdCwgZG5zX3RpbWVvdXQpCiAgICAgICAgZXhjZXB0IHNvY2tldC5nYWllcnJvciBh
  >> "!B64TMP!" echo cyBlOgogICAgICAgICAgICBnb25lID0gZ2V0YXR0cihlLCAiZXJybm8iLCBOb25lKSBpbiBfTk9f
  >> "!B64TMP!" echo U1VDSF9OQU1FCiAgICAgICAgICAgIGxpbmVzID0gWyJOZXR3b3JrIGNoZWNrIGZvciB7fSAoZnJv
  >> "!B64TMP!" echo bSB0aGlzIG1hY2hpbmUpOiBETlMgbG9va3VwIGZhaWxlZCAoe30pLiIuZm9ybWF0KGhvc3QsIGUp
  >> "!B64TMP!" echo XQogICAgICAgICAgICBpZiBnb25lOgogICAgICAgICAgICAgICAgbGluZXMuYXBwZW5kKCJUaGUg
  >> "!B64TMP!" echo bmFtZSBkb2VzIG5vdCBleGlzdCBvciBpcyBiZWluZyBmaWx0ZXJlZCwgc28gdGhpcyBVUkwgY2Fu
  >> "!B64TMP!" echo bm90IGJlICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAibG9hZGVkLiBDaGVjayB0aGUg
  >> "!B64TMP!" echo c3BlbGxpbmcgb2YgdGhlIGFkZHJlc3MgYW5kIGFueSBETlMgZmlsdGVyIC8gIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICJWUE4gLyBob3N0cy1maWxlIGVudHJ5OyB3YWl0aW5nIGFuZCBy
  >> "!B64TMP!" echo ZXRyeWluZyB3aWxsIG5vdCBoZWxwLiIpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBsaW5lcy5hcHBlbmQoIlRoZSBETlMgcmVzb2x2ZXIgZ2F2ZSBhIHRlbXBvcmFyeSBmYWlsdXJl
  >> "!B64TMP!" echo OyBjaGVjayB0aGlzIG1hY2hpbmUncyAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIm5l
  >> "!B64TMP!" echo dHdvcmsgLyBETlMgc2V0dGluZ3MuIikKICAgICAgICAgICAgcmV0dXJuIERpYWdub3Npcyhob3N0
  >> "!B64TMP!" echo LCBnb25lLCBsaW5lcykKICAgICAgICBleGNlcHQgVGltZW91dEVycm9yIGFzIGU6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBEaWFnbm9zaXMoaG9zdCwgRmFsc2UsIFsKICAgICAgICAgICAgICAgICJOZXR3
  >> "!B64TMP!" echo b3JrIGNoZWNrIGZvciB7fSAoZnJvbSB0aGlzIG1hY2hpbmUpOiB7fS4gVGhlIEROUyByZXNvbHZl
  >> "!B64TMP!" echo ciBpcyAiCiAgICAgICAgICAgICAgICAibm90IGFuc3dlcmluZzsgY2hlY2sgdGhpcyBtYWNoaW5l
  >> "!B64TMP!" echo J3MgbmV0d29yayAvIEROUyBzZXR0aW5ncy4iLmZvcm1hdChob3N0LCBlKV0pCiAgICAgICAgaWYg
  >> "!B64TMP!" echo bm90IGFkZHJzOgogICAgICAgICAgICByZXR1cm4gTm9uZQoKICAgIGtpbmRzID0gWyhhLCBjbGFz
  >> "!B64TMP!" echo c2lmeV9pcChhKSkgZm9yIGEgaW4gYWRkcnNdCiAgICBwcm9iZXMgPSBfcHJvYmVfYWxsKGFkZHJz
  >> "!B64TMP!" echo Wzo0XSwgcG9ydCwgY29ubmVjdF90aW1lb3V0KQoKICAgIGxpbmVzID0gWyJOZXR3b3JrIGNoZWNr
  >> "!B64TMP!" echo IGZvciB7fSAocnVuIGZyb20gdGhpcyBtYWNoaW5lLCBub3QgZnJvbSBpbnNpZGUgdGhlIGNvbnRh
  >> "!B64TMP!" echo aW5lcik6Ii5mb3JtYXQoaG9zdCldCiAgICBpZiBsaXRlcmFsIGlzIE5vbmU6CiAgICAgICAgbGlu
  >> "!B64TMP!" echo ZXMuYXBwZW5kKCIgIEROUzoge30gLT4ge30iLmZvcm1hdChob3N0LCAiLCAiLmpvaW4oYWRkcnNb
  >> "!B64TMP!" echo OjRdKSkpCiAgICBzaG93biA9IHNldCgpCiAgICBmb3IgYSwgayBpbiBraW5kczoKICAgICAgICBp
  >> "!B64TMP!" echo ZiBrIGFuZCBrIG5vdCBpbiBzaG93bjoKICAgICAgICAgICAgc2hvd24uYWRkKGspCiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGxpbmVzLmFwcGVuZCgiICB7fSBpcyB7fS4iLmZvcm1hdChhLCBfS0lORF9URVhUW2tdKSkK
  >> "!B64TMP!" echo ICAgIGZvciBhLCBzdGF0ZSwgc2VjcyBpbiBwcm9iZXM6CiAgICAgICAgbGluZXMuYXBwZW5kKCIg
  >> "!B64TMP!" echo IFRDUCB7fToge30iLmZvcm1hdChwb3J0LCBfZGVzY3JpYmVfcHJvYmUoYSwgc3RhdGUsIHNlY3Ms
  >> "!B64TMP!" echo IGNvbm5lY3RfdGltZW91dCkpKQoKICAgIGlmIGFueShzdGF0ZSA9PSAib3BlbiIgZm9yIF9hLCBz
  >> "!B64TMP!" echo dGF0ZSwgX3MgaW4gcHJvYmVzKToKICAgICAgICBpZiBhbnkoayBmb3IgX2EsIGsgaW4ga2luZHMp
  >> "!B64TMP!" echo OgogICAgICAgICAgICBsaW5lcy5hcHBlbmQoIkEgcHJveHkvVlBOIGlzIGFuc3dlcmluZyBmb3Ig
  >> "!B64TMP!" echo dGhpcyBub24tcHVibGljIGFkZHJlc3MsIHNvIHRoaXMgbWFjaGluZSdzICIKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICJwYXRoIHdvcmtzLiBJZiB0aGUgc2NyYXBlIHN0aWxsIGZhaWxlZCwgdGhl
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBjb250YWluZXIgcHJvYmFibHkgIgogICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ImRvZXMgbm90IHVzZSB0aGUgc2FtZSBwYXRoIChpdHMgRE5TLCBwcm94eSBvciByb3V0aW5nKS4i
  >> "!B64TMP!" echo KQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGxpbmVzLmFwcGVuZCgiVGhlIHNpdGUgYWNjZXB0
  >> "!B64TMP!" echo cyBjb25uZWN0aW9ucyBmcm9tIHRoaXMgbWFjaGluZSwgc28gdGhpcyBpcyBub3QgYSBibG9ja2Vk
  >> "!B64TMP!" echo ICIKICAgICAgICAgICAgICAgICAgICAgICAgICJyb3V0ZTogbW9zdCBsaWtlbHkgdGhlIEZpcmVj
  >> "!B64TMP!" echo cmF3bC9icm93c2VyIGNvbnRhaW5lcidzIG93biBuZXR3b3JrIChETlMsICIKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICJwcm94eSwgcm91dGluZykgb3IgdGhlIHNpdGUgcmVmdXNpbmcgYXV0b21h
  >> "!B64TMP!" echo dGVkIGFjY2VzcyAoYm90IHByb3RlY3Rpb24pLiIpCiAgICAgICAgcmV0dXJuIERpYWdub3Npcyho
  >> "!B64TMP!" echo b3N0LCBGYWxzZSwgbGluZXMpCgogICAga2luZF9zZXQgPSBzZXQoayBmb3IgX2EsIGsgaW4ga2lu
  >> "!B64TMP!" echo ZHMgaWYgaykKICAgIHN0YXRlcyA9IHNldChzdGF0ZSBmb3IgX2EsIHN0YXRlLCBfcyBpbiBwcm9i
  >> "!B64TMP!" echo ZXMpCiAgICBpZiAiZmFrZS1pcCIgaW4ga2luZF9zZXQ6CiAgICAgICAgY2F1c2UgPSAoIkNhdXNl
  >> "!B64TMP!" echo OiBETlMgcmV0dXJuZWQgYSBmYWtlLUlQLCBidXQgdGhlIHByb3h5L1ZQTiB0b29sIHRoYXQgb3du
  >> "!B64TMP!" echo cyBpdCBpcyBub3QgY2FycnlpbmcgIgogICAgICAgICAgICAgICAgICJ0aGUgdHJhZmZpYyAodG9v
  >> "!B64TMP!" echo bCBzdG9wcGVkLCBpdHMgVFVOIC8gc3lzdGVtLXdpZGUgbW9kZSBvZmYsIG9yIGEgcnVsZSB0aGF0
  >> "!B64TMP!" echo IGRyb3BzICIKICAgICAgICAgICAgICAgICAidGhpcyBzaXRlKS4gRml4IG9uIHRoZSBuZXR3b3Jr
  >> "!B64TMP!" echo IHNpZGU6IHN0YXJ0IHRoZSB0b29sIGFuZCBlbmFibGUgVFVOIG1vZGUsIG9yIGFkZCAiCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgInRoaXMgZG9tYWluIHRvIGl0cyBmYWtlLWlwLWZpbHRlciAvIGEgRElSRUNU
  >> "!B64TMP!" echo IHJ1bGUsIG9yIHR1cm4gZmFrZS1JUCBETlMgb2ZmLiAiCiAgICAgICAgICAgICAgICAgIkRvY2tl
  >> "!B64TMP!" echo ci9Qb2RtYW4gY29udGFpbmVycyBuZWVkIHRoZSBzYW1lIHBhdGguIikKICAgIGVsaWYga2luZF9z
  >> "!B64TMP!" echo ZXQ6CiAgICAgICAgY2F1c2UgPSAoIkNhdXNlOiB0aGUgbmFtZSByZXNvbHZlcyB0byBhIG5vbi1w
  >> "!B64TMP!" echo dWJsaWMgYWRkcmVzcyB0aGF0IG5vdGhpbmcgYW5zd2VycyBvbiAiCiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IihhIFZQTiwgcHJveHksIEROUyBmaWx0ZXIgb3IgaG9zdHMtZmlsZSBlbnRyeSkuIENoZWNrIHRo
  >> "!B64TMP!" echo YXQgY29uZmlndXJhdGlvbiAiCiAgICAgICAgICAgICAgICAgImZvciB0aGlzIGRvbWFpbi4iKQog
  >> "!B64TMP!" echo ICAgZWxpZiAidGltZW91dCIgaW4gc3RhdGVzOgogICAgICAgIGNhdXNlID0gKCJDYXVzZTogcGFj
  >> "!B64TMP!" echo a2V0cyB0byB0aGUgc2l0ZSBhcmUgZHJvcHBlZCBiZWZvcmUgcmVhY2hpbmcgaXQgKGZpcmV3YWxs
  >> "!B64TMP!" echo LCBWUE4sICIKICAgICAgICAgICAgICAgICAiSVNQL2dlbyBibG9jaykgb3IgdGhlIHNpdGUgaXMg
  >> "!B64TMP!" echo ZG93bi4iKQogICAgZWxpZiAicmVmdXNlZCIgaW4gc3RhdGVzOgogICAgICAgIGNhdXNlID0gIkNh
  >> "!B64TMP!" echo dXNlOiB0aGUgc2VydmVyIGFjdGl2ZWx5IHJlZnVzZXMgY29ubmVjdGlvbnMgb24gcG9ydCB7fS4i
  >> "!B64TMP!" echo LmZvcm1hdChwb3J0KQogICAgZWxzZToKICAgICAgICBjYXVzZSA9ICJDYXVzZTogdGhlcmUgaXMg
  >> "!B64TMP!" echo bm8gbmV0d29yayByb3V0ZSB0byB0aGUgc2l0ZSBmcm9tIHRoaXMgbWFjaGluZS4iCiAgICBsaW5l
  >> "!B64TMP!" echo cy5hcHBlbmQoIlJlc3VsdDogbm8gY29ubmVjdGlvbiB0byB7fTp7fSBjYW4gYmUgbWFkZSAtIHRo
  >> "!B64TMP!" echo ZSByb3V0ZSBpcyBibG9ja2VkIGF0IHRoZSBuZXR3b3JrICIKICAgICAgICAgICAgICAgICAibGV2
  >> "!B64TMP!" echo ZWw7IHRoaXMgaXMgbm90IGEgdGVtcG9yYXJ5IHNpdGUgZXJyb3IuIi5mb3JtYXQoaG9zdCwgcG9y
  >> "!B64TMP!" echo dCkpCiAgICBsaW5lcy5hcHBlbmQoY2F1c2UpCiAgICBsaW5lcy5hcHBlbmQoIldhaXRpbmcgYW5k
  >> "!B64TMP!" echo IHJlLXJ1bm5pbmcgdGhpcyBzYW1lIHJlcXVlc3Qgd2lsbCBub3QgaGVscDogZG8gbm90IHJldHJ5
  >> "!B64TMP!" echo IHRoaXMgVVJMLiAiCiAgICAgICAgICAgICAgICAgIlVzZSBhIGRpZmZlcmVudCBzb3VyY2UgZm9y
  >> "!B64TMP!" echo IHRoZSBpbmZvcm1hdGlvbiAoYW5vdGhlciBVUkwsIGUuZy4gZnJvbSBhIGZyZXNoICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAid2ViX3NlYXJjaCkgYW5kIHRlbGwgdGhlIHVzZXIgYWJvdXQgdGhlIG5ldHdv
  >> "!B64TMP!" echo cmsgcHJvYmxlbS4iKQogICAgcmV0dXJuIERpYWdub3Npcyhob3N0LCBUcnVlLCBsaW5lcykKCgpk
  >> "!B64TMP!" echo ZWYgZGlhZ25vc2VfdXJsKHVybCwgY29ubmVjdF90aW1lb3V0PTMuMCwgZG5zX3RpbWVvdXQ9NS4w
  >> "!B64TMP!" echo KToKICAgICIiIkV4cGxhaW4sIGZyb20gdGhpcyBtYWNoaW5lLCB3aHkgYHVybGAgY291bGQgbm90
  >> "!B64TMP!" echo IGJlIGxvYWRlZDogcmVzb2x2ZSB0aGUKICAgIGhvc3QgYW5kIHRyeSBvbmUgVENQIGNvbm5lY3Rp
  >> "!B64TMP!" echo b24gcGVyIGFkZHJlc3MgKHBhcmFsbGVsLCBgY29ubmVjdF90aW1lb3V0YAogICAgc2Vjb25kcyBh
  >> "!B64TMP!" echo dCBtb3N0KS4gUmV0dXJucyBhIERpYWdub3Npcywgb3IgTm9uZSB3aGVuIG5vdGhpbmcgdXNlZnVs
  >> "!B64TMP!" echo IGNhbiBiZQogICAgc2FpZCAobm90IGFuIGh0dHAocykgVVJMLCBsb2NhbGhvc3QsIHVuZXhwZWN0
  >> "!B64TMP!" echo ZWQgZXJyb3IpLiBOZXZlciByYWlzZXMuIiIiCiAgICB0cnk6CiAgICAgICAgcmV0dXJuIF9kaWFn
  >> "!B64TMP!" echo bm9zZShzdHIodXJsKS5zdHJpcCgpLCBjb25uZWN0X3RpbWVvdXQsIGRuc190aW1lb3V0KQogICAg
  >> "!B64TMP!" echo ZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4gTm9uZQo=
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
  >> "!B64TMP!" echo IFBvZG1hbi9Eb2NrZXIsIG5vIGNvbXBvc2UpLgoKICAyLiBBcyBhIG1vZHVsZSAodXNlZCBieSB3
  >> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IC8gd2ViX3NjcmFwZS5weSBmb3Igc2VsZi1oZWFsaW5nKToKICAgICAgICAg
  >> "!B64TMP!" echo aW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAgICBvaywgbWVzc2FnZSwgY29kZSA9IGVuc3VyZV9z
  >> "!B64TMP!" echo dGFjay5lbnN1cmVfcmVhZHkoKQogICAgIFdoZW4gYSBzZWFyY2gvc2NyYXBlIHJlcXVlc3QgZmFp
  >> "!B64TMP!" echo bHMgd2l0aCBhIGNvbm5lY3Rpb24gZXJyb3IsIHRob3NlCiAgICAgc2NyaXB0cyBjYWxsIGVuc3Vy
  >> "!B64TMP!" echo ZV9yZWFkeSgpIGF1dG9tYXRpY2FsbHksIHRoZW4gcmV0cnkgdGhlIHJlcXVlc3QKICAgICBvbmNl
  >> "!B64TMP!" echo IOKAlCBzbyB0aGUgYWdlbnQgY2FuIGNhbGwgdGhlbSBkaXJlY3RseSB3aXRoIG5vIHdhcm0tdXAg
  >> "!B64TMP!" echo c3RlcC4KCkJlaGF2aW91ciAoYm90aCBDTEkgYW5kIG1vZHVsZSk6CiAgKiBCb3RoIGVuZHBvaW50
  >> "!B64TMP!" echo cyBhbnN3ZXJpbmcgLT4gcmV0dXJuIGltbWVkaWF0ZWx5IChmYXN0IHBhdGgsIDwgMSBzKS4KICAq
  >> "!B64TMP!" echo IE90aGVyd2lzZTogbWFrZSBzdXJlIHRoZSBjb250YWluZXIgZW5naW5lIGlzIHJ1bm5pbmcgKGlm
  >> "!B64TMP!" echo IGl0IGlzIGRvd24sIGxhdW5jaAogICAgRG9ja2VyIERlc2t0b3AgLyB0aGUgZG9ja2VyIHNlcnZp
  >> "!B64TMP!" echo Y2UgLyB0aGUgUG9kbWFuIG1hY2hpbmUgYW5kIHdhaXQgZm9yIGl0KSwKICAgIHRoZW4gc3RhcnQg
  >> "!B64TMP!" echo dGhlIGNvbnRhaW5lcnMgd2l0aCBgcG9kbWFuIGNvbXBvc2UgdXAgLWRgIC8gYGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlCiAgICB1cCAtZGAgaW4gdGhlIGluc3RhbGwgZm9sZGVyICh0aGUgc2FtZSBjb21tYW5kIFJ1
  >> "!B64TMP!" echo bi5iYXQgLyBydW4uc2ggcnVuLAogICAgd2l0aG91dCB0aGUgaW50ZXJhY3RpdmUgYHBhdXNlYCkg
  >> "!B64TMP!" echo YW5kIHdhaXQgdW50aWwgYm90aCBlbmRwb2ludHMgYW5zd2VyLgogICAgVGhlIGVuZ2luZSBpcyBQ
  >> "!B64TMP!" echo b2RtYW4gd2hlbiBpdCBpcyBpbnN0YWxsZWQgKGl0IHdpbnMgd2hlbiBib3RoIGFyZSksIGVsc2UK
  >> "!B64TMP!" echo ICAgIERvY2tlciAtIG92ZXJyaWRlIHdpdGggTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58ZG9j
  >> "!B64TMP!" echo a2VyLCBvciB0aGUgc2FtZSBsaW5lCiAgICBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52ICh0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIHJlY29yZHMgaXRzIGNob2ljZSB0aGVyZSkuCiAgICBUaGUgc3RhY2sgaXMg
  >> "!B64TMP!" echo TkVWRVIgc3RvcHBlZCBieSB0aGlzIHNjcmlwdC4KClRoZSByZWFkaW5lc3MgdGltZW91dCBkZWZh
  >> "!B64TMP!" echo dWx0cyB0byAyNDAgcyBhbmQgY2FuIGJlIG92ZXJyaWRkZW4gd2l0aCB0aGUKTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X1JFQURZX1RJTUVPVVQgZW52IHZhciAoc2Vjb25kcykg4oCUIHVzZWQgYnkgdGhlIHRlc3Qgc3Vp
  >> "!B64TMP!" echo dGUgdG8KZXhlcmNpc2UgdGhlIGZhaWx1cmUgcGF0aCBxdWlja2x5LgoKVGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyIChob2xkcyBkb2NrZXItY29tcG9zZS55bWwpIGlzIGZvdW5kIGJ5IGNvbmZpZy5weSwgaW4g
  >> "!B64TMP!" echo b3JkZXI6CiAgICAxLiB0aGUgTE9DQUxfU0VBUkNIX0RJUiBlbnYgdmFyIChleHBsaWNpdCBvdmVy
  >> "!B64TMP!" echo cmlkZSksCiAgICAyLiB0aGUgY29tcG9zZSBsYWJlbCBvbiB0aGUgY29udGFpbmVycyDigJQgY29t
  >> "!B64TMP!" echo cG9zZSB0YWdzIGVhY2ggY29udGFpbmVyIHdpdGgKICAgICAgIHRoZSBkaXJlY3RvcnkgaXQgd2Fz
  >> "!B64TMP!" echo IHN0YXJ0ZWQgZnJvbSAoZW5naW5lIG11c3QgYmUgdXApLAogICAgMy4gaW5zdGFsbC1kaXIudHh0
  >> "!B64TMP!" echo IOKAlCB0aGUgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGxlcgogICAg
  >> "!B64TMP!" echo ICAgd2hlbiBpdCBjb3BpZWQgdGhpcyBza2lsbCwKICAgIDQuIH4vbG9jYWwtc2VhcmNoLgoiIiIK
  >> "!B64TMP!" echo aW1wb3J0IGFyZ3BhcnNlCmltcG9ydCBvcwppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNz
  >> "!B64TMP!" echo CmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKaW1wb3J0IHVybGxpYi5lcnJvcgppbXBvcnQgdXJsbGli
  >> "!B64TMP!" echo LnJlcXVlc3QKCiMgRGVmYXVsdCBzdGRvdXQvc3RkZXJyIHRvIFVURi04IHJlZ2FyZGxlc3Mgb2Yg
  >> "!B64TMP!" echo dGhlIGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUuZy4gV2luZG93cyBjcDEyNTIpLCBzbyBzdGF0
  >> "!B64TMP!" echo dXMvcHJvZ3Jlc3MgbWVzc2FnZXMgbmV2ZXIgY3Jhc2ggd2l0aCBhCiMgVW5pY29kZUVuY29kZUVy
  >> "!B64TMP!" echo cm9yLiBTa2lwcGVkIGlmIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUIGFuCiMg
  >> "!B64TMP!" echo ZXhwbGljaXQgb3ZlcnJpZGUgYWx3YXlzIHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3Qg
  >> "!B64TMP!" echo aW4gb3MuZW52aXJvbjoKICAgIGZvciBfc3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJy
  >> "!B64TMP!" echo KToKICAgICAgICBpZiBoYXNhdHRyKF9zdHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgICAgICAgICBfc3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYt
  >> "!B64TMP!" echo OCIpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpz
  >> "!B64TMP!" echo eXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVf
  >> "!B64TMP!" echo XykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAg
  >> "!B64TMP!" echo KyAuZW52LWRyaXZlbiBlbmRwb2ludHMKClJFQURZX1RJTUVPVVQgPSBpbnQob3MuZW52aXJvbi5n
  >> "!B64TMP!" echo ZXQoIkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIiwgIjI0MCIpIG9yIDI0MCkKUE9MTF9FVkVS
  >> "!B64TMP!" echo WSA9IDMKRElTUExBWSA9IHsic2VhcnhuZyI6ICJTZWFyWE5HIiwgImZpcmVjcmF3bCI6ICJGaXJl
  >> "!B64TMP!" echo Y3Jhd2wifQoKCmRlZiBlbmRwb2ludF91cCh1cmwsIHRpbWVvdXQ9NCk6CiAgICAiIiJUcnVlIGlm
  >> "!B64TMP!" echo IHRoZSBlbmRwb2ludCBhY2NlcHRzIGNvbm5lY3Rpb25zIChhbnkgSFRUUCBzdGF0dXMgY291bnRz
  >> "!B64TMP!" echo KS4iIiIKICAgIHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QodXJsKQogICAgdHJ5OgogICAg
  >> "!B64TMP!" echo ICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9dGltZW91dCk6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHJldHVybiBUcnVlCiAgICBleGNlcHQgdXJsbGliLmVycm9yLkhUVFBFcnJvcjoK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gVHJ1ZSAgIyBnb3QgYW4gSFRUUCByZXNwb25zZSAoZXZlbiA0eHgvNXh4
  >> "!B64TMP!" echo KSA9IHNlcnZpY2UgaXMgdXAKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIEZh
  >> "!B64TMP!" echo bHNlICAjIGNvbm5lY3Rpb24gcmVmdXNlZCAvIHJlc2V0IC8gdGltZW91dCA9IGRvd24KCgpkZWYg
  >> "!B64TMP!" echo cG9ydF9vZih1cmwpOgogICAgcmV0dXJuIHVybC5yc3BsaXQoIjoiLCAxKVsxXQoKCmRlZiBzdGF0
  >> "!B64TMP!" echo dXMoZW5kcG9pbnRzKToKICAgIHJldHVybiB7bmFtZTogZW5kcG9pbnRfdXAodXJsKSBmb3IgbmFt
  >> "!B64TMP!" echo ZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpfQoKCmRlZiByZWFkeV9tZXNzYWdlKGVuZHBvaW50
  >> "!B64TMP!" echo cyk6CiAgICByZXR1cm4gIlN0YWNrIGlzIHJlYWR5IChTZWFyWE5HIDp7MH0sIEZpcmVjcmF3bCA6
  >> "!B64TMP!" echo ezF9KS4iLmZvcm1hdCgKICAgICAgICBwb3J0X29mKGVuZHBvaW50c1sic2VhcnhuZyJdKSwgcG9y
  >> "!B64TMP!" echo dF9vZihlbmRwb2ludHNbImZpcmVjcmF3bCJdKSkKCgpkZWYgX29rKGNtZCk6CiAgICB0cnk6CiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIHN1YnByb2Nlc3MucnVuKGNtZCwgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9y
  >> "!B64TMP!" echo KToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgY29tcG9zZV9jb21tYW5kKGVuZ2luZT0iZG9j
  >> "!B64TMP!" echo a2VyIik6CiAgICBpZiBlbmdpbmUgPT0gInBvZG1hbiI6CiAgICAgICAgaWYgc2h1dGlsLndoaWNo
  >> "!B64TMP!" echo KCJwb2RtYW4iKSBhbmQgX29rKFsicG9kbWFuIiwgImNvbXBvc2UiLCAidmVyc2lvbiJdKToKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIFsicG9kbWFuIiwgImNvbXBvc2UiXQogICAgICAgIGlmIHNodXRpbC53
  >> "!B64TMP!" echo aGljaCgicG9kbWFuLWNvbXBvc2UiKToKICAgICAgICAgICAgcmV0dXJuIFsicG9kbWFuLWNvbXBv
  >> "!B64TMP!" echo c2UiXQogICAgICAgIHJldHVybiBOb25lCiAgICBpZiBzaHV0aWwud2hpY2goImRvY2tlciIpIGFu
  >> "!B64TMP!" echo ZCBfb2soWyJkb2NrZXIiLCAiY29tcG9zZSIsICJ2ZXJzaW9uIl0pOgogICAgICAgIHJldHVybiBb
  >> "!B64TMP!" echo ImRvY2tlciIsICJjb21wb3NlIl0KICAgIGlmIHNodXRpbC53aGljaCgiZG9ja2VyLWNvbXBvc2Ui
  >> "!B64TMP!" echo KToKICAgICAgICByZXR1cm4gWyJkb2NrZXItY29tcG9zZSJdCiAgICByZXR1cm4gTm9uZQoKCmRl
  >> "!B64TMP!" echo ZiBlbmdpbmVfdXAoZW5naW5lKToKICAgIHJldHVybiBfb2soW2VuZ2luZSwgImluZm8iXSkKCgpk
  >> "!B64TMP!" echo ZWYgZW5zdXJlX3BvZG1hbl9zb2NrZXQoKToKICAgICIiImBwb2RtYW4gY29tcG9zZWAgbm9ybWFs
  >> "!B64TMP!" echo bHkgaGFuZHMgb3ZlciB0byBkb2NrZXItY29tcG9zZSwgd2hpY2ggdGFsa3MgdG8KICAgIFBvZG1h
  >> "!B64TMP!" echo bidzIEFQSSBzb2NrZXQ7IG9uIGEgZnJlc2ggRmVkb3JhIHNlc3Npb24gdGhhdCBzb2NrZXQgaXMg
  >> "!B64TMP!" echo bm90IHJ1bm5pbmcuCiAgICBCZXN0IGVmZm9ydCwgTGludXggb25seSwgbmV2ZXIgZmF0YWwuIFRy
  >> "!B64TMP!" echo dWUgd2hlbiB0aGUgc29ja2V0IGV4aXN0cy4iIiIKICAgIGltcG9ydCBwbGF0Zm9ybQogICAgaWYg
  >> "!B64TMP!" echo cGxhdGZvcm0uc3lzdGVtKCkgIT0gIkxpbnV4IjoKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRl
  >> "!B64TMP!" echo ZiBleGlzdHMoKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIG91dCA9IHN1YnByb2Nlc3MucnVu
  >> "!B64TMP!" echo KAogICAgICAgICAgICAgICAgWyJwb2RtYW4iLCAiaW5mbyIsICItLWZvcm1hdCIsICJ7ey5Ib3N0
  >> "!B64TMP!" echo LlJlbW90ZVNvY2tldC5FeGlzdHN9fSJdLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nl
  >> "!B64TMP!" echo c3MuUElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gb3V0LnN0ZG91dC5zdHJpcCgpID09ICJ0cnVlIgogICAgICAgIGV4Y2VwdCAoT1NF
  >> "!B64TMP!" echo cnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKCiAgICBp
  >> "!B64TMP!" echo ZiBleGlzdHMoKToKICAgICAgICByZXR1cm4gVHJ1ZQogICAgaWYgc2h1dGlsLndoaWNoKCJzeXN0
  >> "!B64TMP!" echo ZW1jdGwiKToKICAgICAgICByb290bGVzcyA9IHN1YnByb2Nlc3MucnVuKAogICAgICAgICAgICBb
  >> "!B64TMP!" echo InBvZG1hbiIsICJpbmZvIiwgIi0tZm9ybWF0IiwgInt7Lkhvc3QuU2VjdXJpdHkuUm9vdGxlc3N9
  >> "!B64TMP!" echo fSJdLAogICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vz
  >> "!B64TMP!" echo cy5ERVZOVUxMLCB0ZXh0PVRydWUKICAgICAgICApLnN0ZG91dC5zdHJpcCgpID09ICJ0cnVlIgog
  >> "!B64TMP!" echo ICAgICAgIGlmIHJvb3RsZXNzOgogICAgICAgICAgICBfb2soWyJzeXN0ZW1jdGwiLCAiLS11c2Vy
  >> "!B64TMP!" echo IiwgInN0YXJ0IiwgInBvZG1hbi5zb2NrZXQiXSkKICAgICAgICBlbGlmIG5vdCBfb2soWyJzeXN0
  >> "!B64TMP!" echo ZW1jdGwiLCAic3RhcnQiLCAicG9kbWFuLnNvY2tldCJdKSBhbmQgc2h1dGlsLndoaWNoKCJzdWRv
  >> "!B64TMP!" echo Iik6CiAgICAgICAgICAgIF9vayhbInN1ZG8iLCAiLW4iLCAic3lzdGVtY3RsIiwgInN0YXJ0Iiwg
  >> "!B64TMP!" echo InBvZG1hbi5zb2NrZXQiXSkKICAgIHJldHVybiBleGlzdHMoKQoKCmRlZiBmaW5kX2RvY2tlcl9k
  >> "!B64TMP!" echo ZXNrdG9wX2V4ZSgpOgogICAgY2FuZGlkYXRlcyA9IFsKICAgICAgICByIkM6XFByb2dyYW0gRmls
  >> "!B64TMP!" echo ZXNcRG9ja2VyXERvY2tlclxEb2NrZXIgRGVza3RvcC5leGUiLAogICAgICAgIG9zLnBhdGguZXhw
  >> "!B64TMP!" echo YW5kdmFycyhyIiVMT0NBTEFQUERBVEElXFByb2dyYW1zXERvY2tlciBEZXNrdG9wXERvY2tlciBE
  >> "!B64TMP!" echo ZXNrdG9wLmV4ZSIpLAogICAgXQogICAgZm9yIHAgaW4gY2FuZGlkYXRlczoKICAgICAgICBpZiBv
  >> "!B64TMP!" echo cy5wYXRoLmlzZmlsZShwKToKICAgICAgICAgICAgcmV0dXJuIHAKICAgIHJldHVybiBOb25lCgoK
  >> "!B64TMP!" echo ZGVmIHN0YXJ0X2VuZ2luZShlbmdpbmUpOgogICAgIiIiVHJ5IHRvIGxhdW5jaCB0aGUgY29udGFp
  >> "!B64TMP!" echo bmVyIGVuZ2luZSBmb3IgdGhpcyBPUy4gVHJ1ZSBpZiB0aGUgbGF1bmNoIHdhcwogICAgaW5pdGlh
  >> "!B64TMP!" echo dGVkIChub3QgdGhhdCBpdCBiZWNhbWUgcmVhZHkg4oCUIHRoYXQncyB3YWl0X2Zvcl9lbmdpbmUn
  >> "!B64TMP!" echo cyBqb2IpLiIiIgogICAgaW1wb3J0IHBsYXRmb3JtCiAgICBzeXN0ZW0gPSBwbGF0Zm9ybS5zeXN0
  >> "!B64TMP!" echo ZW0oKQogICAgaWYgZW5naW5lID09ICJwb2RtYW4iOgogICAgICAgICMgTGludXg6IHJvb3RsZXNz
  >> "!B64TMP!" echo IFBvZG1hbiBoYXMgbm8gZGFlbW9uIC0gbm90aGluZyB0byBzdGFydC4gbWFjT1MgLwogICAgICAg
  >> "!B64TMP!" echo ICMgV2luZG93czogUG9kbWFuIHJ1bnMgaW4gYSBWTSAoInBvZG1hbiBtYWNoaW5lIikgdGhhdCBt
  >> "!B64TMP!" echo dXN0IGJlIHN0YXJ0ZWQuCiAgICAgICAgaWYgc3lzdGVtID09ICJMaW51eCI6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBGYWxzZQogICAgICAgIHRyeToKICAgICAgICAgICAgbmFtZXMgPSBzdWJwcm9jZXNz
  >> "!B64TMP!" echo LnJ1bigKICAgICAgICAgICAgICAgIFsicG9kbWFuIiwgIm1hY2hpbmUiLCAibGlzdCIsICItLWZv
  >> "!B64TMP!" echo cm1hdCIsICJ7ey5OYW1lfX0iXSwKICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLlBJ
  >> "!B64TMP!" echo UEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsIHRleHQ9VHJ1ZSkKICAgICAgICAgICAgaWYg
  >> "!B64TMP!" echo bm90IG5hbWVzLnN0ZG91dC5zdHJpcCgpOgogICAgICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oWyJwb2RtYW4iLCAibWFjaGluZSIsICJzdGFydCJd
  >> "!B64TMP!" echo LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEws
  >> "!B64TMP!" echo IHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAg
  >> "!B64TMP!" echo ICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVt
  >> "!B64TMP!" echo ID09ICJXaW5kb3dzIjoKICAgICAgICBleGUgPSBmaW5kX2RvY2tlcl9kZXNrdG9wX2V4ZSgpCiAg
  >> "!B64TMP!" echo ICAgICAgaWYgbm90IGV4ZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgdHJ5Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFtleGVdLAogICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5V
  >> "!B64TMP!" echo TEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVtID09ICJEYXJ3aW4iOgogICAgICAgIHRy
  >> "!B64TMP!" echo eToKICAgICAgICAgICAgc3VicHJvY2Vzcy5Qb3BlbihbIm9wZW4iLCAiLS1iYWNrZ3JvdW5kIiwg
  >> "!B64TMP!" echo Ii1hIiwgIkRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJw
  >> "!B64TMP!" echo cm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxz
  >> "!B64TMP!" echo ZQogICAgIyBMaW51eDogYmVzdCBlZmZvcnQgd2l0aG91dCBhbiBpbnRlcmFjdGl2ZSBwYXNzd29y
  >> "!B64TMP!" echo ZCBwcm9tcHQuCiAgICB0cnk6CiAgICAgICAgaWYgaGFzYXR0cihvcywgImdldGV1aWQiKSBhbmQg
  >> "!B64TMP!" echo b3MuZ2V0ZXVpZCgpID09IDA6CiAgICAgICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihbInN5
  >> "!B64TMP!" echo c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1cm5jb2RlID09IDAKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oWyJzdWRvIiwgIi1uIiwgInN5c3RlbWN0bCIsICJz
  >> "!B64TMP!" echo dGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3RkZXJyPXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZp
  >> "!B64TMP!" echo bGVOb3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgd2FpdF9mb3JfZW5n
  >> "!B64TMP!" echo aW5lKGVuZ2luZSwgdGltZW91dD0xODApOgogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUoKSArIHRp
  >> "!B64TMP!" echo bWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgaWYgZW5naW5l
  >> "!B64TMP!" echo X3VwKGVuZ2luZSk6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgdGltZS5zbGVlcCgz
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIEZhbHNlCgoKZGVmIGVuc3VyZV9yZWFkeShjaGVja19vbmx5PUZhbHNlLCBy
  >> "!B64TMP!" echo ZWFkeV90aW1lb3V0PU5vbmUsIHBvbGxfZXZlcnk9Tm9uZSk6CiAgICAiIiJCcmluZyB0aGUgbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoIHN0YWNrIHRvIGEgcmVhZHkgc3RhdGUuIE5FVkVSIHN0b3BzIGl0LgoKICAgIFJl
  >> "!B64TMP!" echo dHVybnMgKG9rLCBtZXNzYWdlLCBleGl0X2NvZGUpOgogICAgICAgIG9rICAgICAgICAgVHJ1ZSB3
  >> "!B64TMP!" echo aGVuIGJvdGggZW5kcG9pbnRzIGFuc3dlci4KICAgICAgICBtZXNzYWdlICAgIGh1bWFuLXJlYWRh
  >> "!B64TMP!" echo YmxlIHN0YXR1cyAvIGd1aWRhbmNlIChwcm9ncmVzcyBpcyBwcmludGVkIHRvCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBzdGRlcnIgYWxvbmcgdGhlIHdheSkuCiAgICAgICAgZXhpdF9jb2RlICAwIHJlYWR5
  >> "!B64TMP!" echo LCAxIGRvd24vY291bGQgbm90IGJyaW5nIHVwLCAyIHByZXJlcXVpc2l0ZXMKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIG1pc3NpbmcgKG1hdGNoZXMgdGhlIENMSSBleGl0IGNvZGVzKS4KICAgICIiIgogICAg
  >> "!B64TMP!" echo aWYgcmVhZHlfdGltZW91dCBpcyBOb25lOgogICAgICAgIHJlYWR5X3RpbWVvdXQgPSBSRUFEWV9U
  >> "!B64TMP!" echo SU1FT1VUCiAgICBpZiBwb2xsX2V2ZXJ5IGlzIE5vbmU6CiAgICAgICAgcG9sbF9ldmVyeSA9IFBP
  >> "!B64TMP!" echo TExfRVZFUlkKCiAgICBlbmRwb2ludHMgPSBjb25maWcuZW5kcG9pbnRzKGNvbmZpZy5maW5kX2lu
  >> "!B64TMP!" echo c3RhbGxfZGlyKCkpCiAgICBzdCA9IHN0YXR1cyhlbmRwb2ludHMpCiAgICBpZiBhbGwoc3QudmFs
  >> "!B64TMP!" echo dWVzKCkpOgogICAgICAgIHJldHVybiBUcnVlLCByZWFkeV9tZXNzYWdlKGVuZHBvaW50cyksIDAK
  >> "!B64TMP!" echo CiAgICBwcmludCgiTG9jYWwtc2VhcmNoIHN0YWNrIGlzIERPV046IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKToKICAgICAgICBtYXJrID0g
  >> "!B64TMP!" echo Ik9LICAiIGlmIHN0W25hbWVdIGVsc2UgIkRPV04iCiAgICAgICAgcHJpbnQoZiIgIFt7bWFya31d
  >> "!B64TMP!" echo IHtESVNQTEFZW25hbWVdfSA6e3BvcnRfb2YodXJsKX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICBp
  >> "!B64TMP!" echo ZiBjaGVja19vbmx5OgogICAgICAgIHJldHVybiBGYWxzZSwgIlN0YWNrIGlzIGRvd24gKC0tY2hl
  >> "!B64TMP!" echo Y2s6IG5vdGhpbmcgd2FzIHN0YXJ0ZWQpLiIsIDEKCiAgICBlbmdpbmUsIGF1dG8gPSBjb25maWcu
  >> "!B64TMP!" echo ZW5naW5lX2Nob2ljZShjb25maWcuZmluZF9pbnN0YWxsX2RpcigpKQogICAgaWYgZW5naW5lIGlz
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAoIk5vIGNvbnRhaW5lciBlbmdpbmUgZm91bmQ6
  >> "!B64TMP!" echo IG5laXRoZXIgUG9kbWFuIG5vciBEb2NrZXIgaXMgIgogICAgICAgICAgICAgICAgICAgICAgICJv
  >> "!B64TMP!" echo biBQQVRIIChvciBMT0NBTF9TRUFSQ0hfRU5HSU5FIG5hbWVzIG9uZSB0aGF0IGlzIG5vdCAiCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgImluc3RhbGxlZCkuIEluc3RhbGwgb25lLCB0aGVuIHJlLXJ1
  >> "!B64TMP!" echo biB0aGlzIHNjcmlwdC4iKSwgMgogICAgbmFtZSA9IGVuZ2luZS5jYXBpdGFsaXplKCkKCiAgICBp
  >> "!B64TMP!" echo ZiBub3QgZW5naW5lX3VwKGVuZ2luZSk6CiAgICAgICAgcHJpbnQoZiJ7bmFtZX0gZW5naW5lIGlz
  >> "!B64TMP!" echo IG5vdCBydW5uaW5nIOKAlCB0cnlpbmcgdG8gc3RhcnQgaXQgLi4uIiwKICAgICAgICAgICAgICBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgc3RhcnRfZW5naW5lKGVuZ2luZSk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHByaW50KGYiV2FpdGluZyBmb3IgdGhlIHtuYW1lfSBlbmdpbmUgdG8gY29tZSB1cCAuLi4i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIG5vdCB3YWl0X2Zvcl9lbmdpbmUoZW5n
  >> "!B64TMP!" echo aW5lLCB0aW1lb3V0PTE4MCk6CiAgICAgICAgICAgICAgICByZXR1cm4gRmFsc2UsIChmIlRoZSB7
  >> "!B64TMP!" echo bmFtZX0gZW5naW5lIHdhcyBsYXVuY2hlZCBidXQgZGlkIG5vdCBhbnN3ZXIgIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgZiJ3aXRoaW4gMTgwIHMuIENoZWNrIHtuYW1lfSwgdGhlbiBy
  >> "!B64TMP!" echo ZS1ydW4gdGhpcyBzY3JpcHQuIiksIDIKICAgICAgICBlbGlmIGF1dG8gYW5kIGVuZ2luZSA9PSAi
  >> "!B64TMP!" echo cG9kbWFuIiBhbmQgc2h1dGlsLndoaWNoKCJkb2NrZXIiKSBhbmQgZW5naW5lX3VwKCJkb2NrZXIi
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgcHJpbnQoIlBvZG1hbiBpcyBub3QgcmVzcG9uZGluZyDigJQgdXNpbmcg
  >> "!B64TMP!" echo RG9ja2VyIGluc3RlYWQuIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBlbmdpbmUsIG5h
  >> "!B64TMP!" echo bWUgPSAiZG9ja2VyIiwgIkRvY2tlciIKICAgICAgICBlbHNlOgogICAgICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UsIChmIkNvdWxkIG5vdCBzdGFydCB0aGUge25hbWV9IGVuZ2luZSBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo ICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIihEb2NrZXIgRGVza3RvcCBub3QgZm91bmQg
  >> "!B64TMP!" echo aW4gdGhlIHVzdWFsIGxvY2F0aW9ucz8gIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiSXMg
  >> "!B64TMP!" echo cm9vdGxlc3MgUG9kbWFuIHNldCB1cCDigJQgZG9lcyAncG9kbWFuIGluZm8nIHdvcms/KS4gIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAiU3RhcnQgaXQgbWFudWFsbHksIHRoZW4gcmUtcnVu
  >> "!B64TMP!" echo IHRoaXMgc2NyaXB0LiIpLCAyCgogICAgIyBSZWNvbXB1dGVkIG5vdyB0aGF0IHRoZSBlbmdpbmUg
  >> "!B64TMP!" echo aXMgdXA6IHRoZSBjb21wb3NlLWxhYmVsIGxvb2t1cCAod2hpY2gKICAgICMgbmVlZHMgdGhlIGVu
  >> "!B64TMP!" echo Z2luZSkgY2FuIGZpbmQgdGhlIGluc3RhbGwgZGlyIHdoZXJlIHRoZSBvdGhlciBtZXRob2RzCiAg
  >> "!B64TMP!" echo ICAjIGNvdWxkIG5vdC4KICAgIGluc3RhbGxfZGlyID0gY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIo
  >> "!B64TMP!" echo KQogICAgaWYgbm90IGluc3RhbGxfZGlyOgogICAgICAgIHJldHVybiBGYWxzZSwgKCJDb3VsZCBu
  >> "!B64TMP!" echo b3QgZmluZCB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyICIKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiKG5vIGRvY2tlci1jb21wb3NlLnltbCBmb3VuZCkuIEFzayB0aGUgdXNlciB3aGVy
  >> "!B64TMP!" echo ZSB0aGVpciAiCiAgICAgICAgICAgICAgICAgICAgICAgImxvY2FsLXNlYXJjaCBmb2xkZXIgaXMs
  >> "!B64TMP!" echo IHRoZW4gcmUtcnVuIHRoaXMgc2NyaXB0IHdpdGggIgogICAgICAgICAgICAgICAgICAgICAgICJM
  >> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRElSIHNldCB0byB0aGF0IHBhdGgsIG9yIHN0YXJ0IHRoZSBzdGFjayBtYW51
  >> "!B64TMP!" echo YWxseSAiCiAgICAgICAgICAgICAgICAgICAgICAgIihSdW4uYmF0IC8gcnVuLnNoKS4iKSwgMgoK
  >> "!B64TMP!" echo ICAgIGNvbXBvc2UgPSBjb21wb3NlX2NvbW1hbmQoZW5naW5lKQogICAgaWYgbm90IGNvbXBvc2U6
  >> "!B64TMP!" echo CiAgICAgICAgaWYgZW5naW5lID09ICJwb2RtYW4iOgogICAgICAgICAgICByZXR1cm4gRmFsc2Us
  >> "!B64TMP!" echo ICgiTm8gY29tcG9zZSBwcm92aWRlciBmb3IgUG9kbWFuOiBpbnN0YWxsICdkb2NrZXItY29tcG9z
  >> "!B64TMP!" echo ZScgIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiKENvbXBvc2UgdjIpIG9yICdwb2RtYW4t
  >> "!B64TMP!" echo Y29tcG9zZScuIiksIDIKICAgICAgICByZXR1cm4gRmFsc2UsICJOZWl0aGVyICdkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZScgbm9yICdkb2NrZXItY29tcG9zZScgaXMgYXZhaWxhYmxlLiIsIDIKICAgIGNvbXBvc2Vf
  >> "!B64TMP!" echo bGFiZWwgPSAiICIuam9pbihjb21wb3NlKQoKICAgIGVudiA9IGRpY3Qob3MuZW52aXJvbikKICAg
  >> "!B64TMP!" echo IGlmIGVuZ2luZSA9PSAicG9kbWFuIjoKICAgICAgICBlbnZbIlBPRE1BTl9DT01QT1NFX1dBUk5J
  >> "!B64TMP!" echo TkdfTE9HUyJdID0gImZhbHNlIgogICAgICAgIGlmIGNvbXBvc2UgPT0gWyJwb2RtYW4iLCAiY29t
  >> "!B64TMP!" echo cG9zZSJdIGFuZCBub3QgZW5zdXJlX3BvZG1hbl9zb2NrZXQoKToKICAgICAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo IlBvZG1hbidzIEFQSSBzb2NrZXQgaXMgbm90IGFjdGl2ZTsgaWYgY29tcG9zZSBmYWlscywgcnVu
  >> "!B64TMP!" echo OiAiCiAgICAgICAgICAgICAgICAgICJzeXN0ZW1jdGwgLS11c2VyIGVuYWJsZSAtLW5vdyBwb2Rt
  >> "!B64TMP!" echo YW4uc29ja2V0IiwgZmlsZT1zeXMuc3RkZXJyKQoKICAgIHByaW50KGYiU3RhcnRpbmcgc3RhY2sg
  >> "!B64TMP!" echo aW4ge2luc3RhbGxfZGlyfSAoe2NvbXBvc2VfbGFiZWx9KSAuLi4iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY29tcG9zZSArIFsidXAiLCAiLWQiXSwgY3dkPWlu
  >> "!B64TMP!" echo c3RhbGxfZGlyLCBlbnY9ZW52KQogICAgaWYgcHJvYy5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIEZhbHNlLCBmIid7Y29tcG9zZV9sYWJlbH0gdXAgLWQnIGZhaWxlZCDigJQgc2VlIG91
  >> "!B64TMP!" echo dHB1dCBhYm92ZS4iLCAxCgogICAgcHJpbnQoIldhaXRpbmcgZm9yIGVuZHBvaW50cyAuLi4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICBkZWFkbGluZSA9IHRpbWUudGltZSgpICsgcmVhZHlfdGltZW91
  >> "!B64TMP!" echo dAogICAgd2hpbGUgdGltZS50aW1lKCkgPCBkZWFkbGluZToKICAgICAgICBzdCA9IHN0YXR1cyhl
  >> "!B64TMP!" echo bmRwb2ludHMpCiAgICAgICAgaWYgYWxsKHN0LnZhbHVlcygpKToKICAgICAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IFRydWUsIHJlYWR5X21lc3NhZ2UoZW5kcG9pbnRzKSwgMAogICAgICAgIHRpbWUuc2xlZXAocG9s
  >> "!B64TMP!" echo bF9ldmVyeSkKCiAgICBmb3IgbmFtZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpOgogICAgICAg
  >> "!B64TMP!" echo IG1hcmsgPSAiT0sgICIgaWYgc3RbbmFtZV0gZWxzZSAiRE9XTiIKICAgICAgICBwcmludChmIiAg
  >> "!B64TMP!" echo W3ttYXJrfV0ge0RJU1BMQVlbbmFtZV19IDp7cG9ydF9vZih1cmwpfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgIHJldHVybiBGYWxzZSwgKGYiU3RhY2sgZGlkIG5vdCBiZWNvbWUgcmVhZHkgd2l0aGlu
  >> "!B64TMP!" echo IHtyZWFkeV90aW1lb3V0fXMuIEluc3BlY3Qgd2l0aDpcbiIKICAgICAgICAgICAgICAgICAgIGYi
  >> "!B64TMP!" echo ICAgIGNkIHtpbnN0YWxsX2Rpcn0gJiYge2NvbXBvc2VfbGFiZWx9IGxvZ3MgLS10YWlsIDUwIiks
  >> "!B64TMP!" echo IDEKCgpkZWYgbWFpbigpOgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcihkZXNjcmlw
  >> "!B64TMP!" echo dGlvbj0iRW5zdXJlIHRoZSBsb2NhbC1zZWFyY2ggY29udGFpbmVyIHN0YWNrIGlzIHJ1bm5pbmcu
  >> "!B64TMP!" echo IikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1jaGVjayIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgaGVscD0ib25seSByZXBvcnQgc3RhdHVzOyBuZXZlciBzdGFydCBh
  >> "!B64TMP!" echo bnl0aGluZyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgb2ssIG1lc3NhZ2UsIGNv
  >> "!B64TMP!" echo ZGUgPSBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1hcmdzLmNoZWNrKQogICAgaWYgb2s6CiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQobWVzc2FnZSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQobWVzc2FnZSwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIGNvZGUKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18i
  >> "!B64TMP!" echo OgogICAgc3lzLmV4aXQobWFpbigpKQo=
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
  >> "!B64TMP!" echo NXh4KSBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZiwKICAqIHdoZW4gdGhlIExPQ0FM
  >> "!B64TMP!" echo IHN0YWNrIGZhaWxzIHRvIGxvYWQgYSBwYWdlLCB0aGUgbmV0d29yayBwYXRoIHRvIHRoYXQgc2l0
  >> "!B64TMP!" echo ZQogICAgaXMgY2hlY2tlZCBmaXJzdCAoY29uZmlnLmRpYWdub3NlX3VybCk6IGEgYmxvY2tlZCBy
  >> "!B64TMP!" echo b3V0ZSAoZS5nLiBhIHByb3h5L1ZQTgogICAgZmFrZS1JUCAxOTguMTgueC54IHdob3NlIHRyYWZm
  >> "!B64TMP!" echo aWMgaXMgZHJvcHBlZCkgaXMgcmVwb3J0ZWQgYXMgc3VjaCBhbmQgaXMKICAgIE5PVCByZXRyaWVk
  >> "!B64TMP!" echo LCBhbmQgYSBydW5uaW5nIHN0YWNrIGlzIG5ldmVyIHJlc3RhcnRlZCBvdmVyIGEgcmVxdWVzdCB0
  >> "!B64TMP!" echo aGF0CiAgICBtZXJlbHkgdGltZWQgb3V0LAogICogZXZlcnkgZmFpbHVyZSBpcyByZXBvcnRlZCBh
  >> "!B64TMP!" echo cyBhbiBGY0Vycm9yIHdpdGggYSBjbGVhciwgYWN0aW9uYWJsZSBtZXNzYWdlLgoKRW5kcG9pbnRz
  >> "!B64TMP!" echo OiB0aGUgYmFzZSBVUkwgZGVmYXVsdHMgdG8gdGhlIGxvY2FsIEZpcmVjcmF3bCBpbnN0YW5jZSAo
  >> "!B64TMP!" echo cG9ydCBmcm9tCkZJUkVDUkFXTF9QT1JUIGluIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYsIGRl
  >> "!B64TMP!" echo ZmF1bHQgOTk5MSkuIFR3byBzZXR0aW5ncyDigJQKdGhlIHNhbWUgbmFtZXMgdGhlIG9mZmljaWFs
  >> "!B64TMP!" echo IGZpcmVjcmF3bC1tY3Agc2VydmVyIHVzZXMg4oCUIG92ZXJyaWRlIGl0LiBFYWNoCmlzIHJlYWQg
  >> "!B64TMP!" echo ZnJvbSB0aGUgcHJvY2VzcyBlbnZpcm9ubWVudCBGSVJTVCwgdGhlbiBmcm9tIHRoZSBpbnN0YWxs
  >> "!B64TMP!" echo IGZvbGRlcidzCi5lbnYgKHdoZXJlIGluc3RhbGwtbG9jYWwtc2VhcmNoIHBlcnNpc3RzIHRoZSBj
  >> "!B64TMP!" echo cmVkZW50aWFscyB3aGVuIHlvdSBhbnN3ZXIKJ3knIHRvIGl0cyAiQWRkIGEgRmlyZWNyYXdsIGFj
  >> "!B64TMP!" echo Y291bnQ/IiBxdWVzdGlvbik6CgogIEZJUkVDUkFXTF9BUElfVVJMICAgIGJhc2UgVVJMIG9mIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIEFQSSAoZS5nLiB0aGUgY2xvdWQgQVBJLAogICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IGh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYpLiBTZXQgdGhpcyB0byB1c2UgYWNjb3VudAogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIGZlYXR1cmVzIChhZ2VudCwgaW50ZXJhY3QsIHBhcnNlLCBtb25p
  >> "!B64TMP!" echo dG9ycywgcmVzZWFyY2gsCiAgICAgICAgICAgICAgICAgICAgICAgZGV2ZWxvcGVyIHNlYXJjaCkg
  >> "!B64TMP!" echo dGhhdCB0aGUgc2VsZi1ob3N0ZWQgaW5zdGFuY2UgZG9lcwogICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IG5vdCBleHBvc2UuCiAgRklSRUNSQVdMX0FQSV9LRVkgICAgc2VudCBhcyBgQXV0aG9yaXphdGlv
  >> "!B64TMP!" echo bjogQmVhcmVyIDxrZXk+YCB3aGVuIHNldCDigJQKICAgICAgICAgICAgICAgICAgICAgICByZXF1
  >> "!B64TMP!" echo aXJlZCBieSB0aGUgY2xvdWQgQVBJIGFuZCBhY2NvdW50IGZlYXR1cmVzLgoKVXNhZ2UgZnJvbSBh
  >> "!B64TMP!" echo IHNpYmxpbmcgc2NyaXB0OgoKICAgIGltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjCiAgICBkYXRh
  >> "!B64TMP!" echo ID0gZmMuY2FsbCgiL3YxL21hcCIsIG1ldGhvZD0iUE9TVCIsIGJvZHk9eyJ1cmwiOiB1cmx9KQoK
  >> "!B64TMP!" echo YGNhbGwoKWAgcmV0dXJucyB0aGUgcGFyc2VkIEpTT04gcmVzcG9uc2UgYXMgYSBkaWN0IGFuZCBy
  >> "!B64TMP!" echo YWlzZXMgRmNFcnJvciBvbgphbnkgZmFpbHVyZSAoYWZ0ZXIgdGhlIHJldHJpZXMgZGVzY3JpYmVk
  >> "!B64TMP!" echo IGFib3ZlKS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB0aW1l
  >> "!B64TMP!" echo CmltcG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxpYi5wYXJzZQppbXBvcnQgdXJsbGliLnJl
  >> "!B64TMP!" echo cXVlc3QKCiMgRGVmYXVsdCBzdGRvdXQvc3RkZXJyIHRvIFVURi04IHJlZ2FyZGxlc3Mgb2YgdGhl
  >> "!B64TMP!" echo IGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUuZy4gV2luZG93cyBjcDEyNTIpLCBzbyBlcnJvciBt
  >> "!B64TMP!" echo ZXNzYWdlcyBhbmQgcHJvZ3Jlc3Mgb3V0cHV0IGNvbnRhaW5pbmcKIyBub24tQVNDSUkgdGV4dCBu
  >> "!B64TMP!" echo ZXZlciBjcmFzaCB3aXRoIGEgVW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmCiMgUFlUSE9O
  >> "!B64TMP!" echo SU9FTkNPRElORyBpcyBhbHJlYWR5IHNldCDigJQgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3YXlz
  >> "!B64TMP!" echo IHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZvciBf
  >> "!B64TMP!" echo c3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRyKF9z
  >> "!B64TMP!" echo dHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBf
  >> "!B64TMP!" echo c3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2VwdCBF
  >> "!B64TMP!" echo eGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
  >> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAjIHNp
  >> "!B64TMP!" echo YmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2ludHMK
  >> "!B64TMP!" echo CiMgRGVmYXVsdCB0aW1lb3V0IHBlciBIVFRQIGF0dGVtcHQgKHNlY29uZHMpOyBjYWxsZXJzIGNh
  >> "!B64TMP!" echo biBvdmVycmlkZS4KVElNRU9VVCA9IDkwCgojIFRyYW5zaWVudCBzdGF0dXNlcyB3b3J0aCByZXRy
  >> "!B64TMP!" echo eWluZzogcmF0ZSBsaW1pdCArIGNvbW1vbiBzZXJ2ZXIgZXJyb3JzLgpSRVRSWV9TVEFUVVNFUyA9
  >> "!B64TMP!" echo ICg0MjksIDUwMCwgNTAyLCA1MDMsIDUwNCkKIyBCYWNrb2ZmIGJlZm9yZSBlYWNoIHJldHJ5IChz
  >> "!B64TMP!" echo ZWNvbmRzKTogb25lIGVudHJ5IHBlciByZXRyeS4KUkVUUllfQkFDS09GRiA9ICgxLCAzKQoKIyBD
  >> "!B64TMP!" echo YWNoZWQgdmlldyBvZiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChsYXppbHkgY29tcHV0ZWQg
  >> "!B64TMP!" echo b25jZTogcmVzb2x2aW5nCiMgdGhlIGluc3RhbGwgZm9sZGVyIG1heSBxdWVyeSBEb2NrZXIpLiBI
  >> "!B64TMP!" echo b2xkcyB0aGUgRklSRUNSQVdMX0FQSV9VUkwgLwojIEZJUkVDUkFXTF9BUElfS0VZIHZhbHVlcyB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIHdyb3RlIHdoZW4gYSBGaXJlY3Jhd2wgYWNjb3VudCB3YXMKIyBjb25maWd1
  >> "!B64TMP!" echo cmVkIGF0IGluc3RhbGwgdGltZS4KX0lOU1RBTExfRU5WID0gTm9uZQoKCmRlZiBfaW5zdGFsbF9l
  >> "!B64TMP!" echo bnYoKToKICAgICIiIlRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgYXMgYSBkaWN0IChzZWUgY29u
  >> "!B64TMP!" echo ZmlnLmxvYWRfZW52KSwgY2FjaGVkLiIiIgogICAgZ2xvYmFsIF9JTlNUQUxMX0VOVgogICAgaWYg
  >> "!B64TMP!" echo X0lOU1RBTExfRU5WIGlzIE5vbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBfSU5TVEFMTF9F
  >> "!B64TMP!" echo TlYgPSBjb25maWcubG9hZF9lbnYoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSkKICAgICAgICBl
  >> "!B64TMP!" echo eGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBfSU5TVEFMTF9FTlYgPSB7fQogICAgcmV0dXJu
  >> "!B64TMP!" echo IF9JTlNUQUxMX0VOVgoKCmRlZiBfc2V0dGluZyhuYW1lKToKICAgICIiIlZhbHVlIG9mIEZJUkVD
  >> "!B64TMP!" echo UkFXTF9BUElfVVJMIC8gRklSRUNSQVdMX0FQSV9LRVk6IHRoZSBwcm9jZXNzCiAgICBlbnZpcm9u
  >> "!B64TMP!" echo bWVudCBmaXJzdCAodGhlIHNhbWUgb3ZlcnJpZGUgdGhlIG9mZmljaWFsIGZpcmVjcmF3bC1tY3Ag
  >> "!B64TMP!" echo c2VydmVyCiAgICBob25vdXJzKSwgdGhlbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52LiBTdHJp
  >> "!B64TMP!" echo cHBlZCwgcG9zc2libHkgZW1wdHkuIiIiCiAgICB2YWwgPSAob3MuZW52aXJvbi5nZXQobmFtZSkg
  >> "!B64TMP!" echo b3IgIiIpLnN0cmlwKCkKICAgIGlmIHZhbDoKICAgICAgICByZXR1cm4gdmFsCiAgICByZXR1cm4g
  >> "!B64TMP!" echo KF9pbnN0YWxsX2VudigpLmdldChuYW1lKSBvciAiIikuc3RyaXAoKQoKCmNsYXNzIEZjRXJyb3Io
  >> "!B64TMP!" echo RXhjZXB0aW9uKToKICAgICIiIkEgRmlyZWNyYXdsIEFQSSBmYWlsdXJlIGFmdGVyIGFsbCByZXRy
  >> "!B64TMP!" echo aWVzLCB3aXRoIGEgdXNlci1mYWNpbmcgaGludC4KCiAgICBBdHRyaWJ1dGVzOgogICAgICAgIG1l
  >> "!B64TMP!" echo c3NhZ2UgIHdoYXQgd2VudCB3cm9uZyAoc2luZ2xlIGxpbmUpCiAgICAgICAgc3RhdHVzICAgSFRU
  >> "!B64TMP!" echo UCBzdGF0dXMgY29kZSwgb3IgTm9uZSBmb3IgY29ubmVjdGlvbi9wcm90b2NvbCBlcnJvcnMKICAg
  >> "!B64TMP!" echo ICAgICBoaW50ICAgICBvcHRpb25hbCBleHRyYSBndWlkYW5jZSBwcmludGVkIGJ5IHRoZSBDTEkg
  >> "!B64TMP!" echo c2NyaXB0cwogICAgIiIiCgogICAgZGVmIF9faW5pdF9fKHNlbGYsIG1lc3NhZ2UsIHN0YXR1cz1O
  >> "!B64TMP!" echo b25lLCBoaW50PU5vbmUpOgogICAgICAgIHN1cGVyKCkuX19pbml0X18obWVzc2FnZSkKICAgICAg
  >> "!B64TMP!" echo ICBzZWxmLnN0YXR1cyA9IHN0YXR1cwogICAgICAgIHNlbGYuaGludCA9IGhpbnQKCgpkZWYgYmFz
  >> "!B64TMP!" echo ZV91cmwoKToKICAgICIiIlRoZSBGaXJlY3Jhd2wgYmFzZSBVUkw6IEZJUkVDUkFXTF9BUElfVVJM
  >> "!B64TMP!" echo IHdoZW4gc2V0IGluIHRoZSBlbnZpcm9ubWVudAogICAgb3IgdGhlIGluc3RhbGwgZm9sZGVyJ3Mg
  >> "!B64TMP!" echo LmVudiAoc2VsZi1ob3N0ZWQgcmVtb3RlIG9yIHRoZSBjbG91ZCBBUEkpLAogICAgb3RoZXJ3aXNl
  >> "!B64TMP!" echo IHRoZSBsb2NhbCBzdGFjaydzIGVuZHBvaW50IChGSVJFQ1JBV0xfUE9SVCBmcm9tIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsCiAgICBmb2xkZXIncyAuZW52LCBkZWZhdWx0IDk5OTEpLiIiIgogICAgb3ZlcnJpZGUgPSBf
  >> "!B64TMP!" echo c2V0dGluZygiRklSRUNSQVdMX0FQSV9VUkwiKQogICAgaWYgb3ZlcnJpZGU6CiAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIG92ZXJyaWRlLnJzdHJpcCgiLyIpCiAgICByZXR1cm4gY29uZmlnLmVuZHBvaW50cyhjb25m
  >> "!B64TMP!" echo aWcuZmluZF9pbnN0YWxsX2RpcigpKVsiZmlyZWNyYXdsIl0KCgpkZWYgaXNfbG9jYWwoKToKICAg
  >> "!B64TMP!" echo ICIiIlRydWUgd2hlbiByZXF1ZXN0cyBnbyB0byB0aGUgTE9DQUwgc3RhY2sgKG5vIEZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfVVJMIGluIHRoZQogICAgZW52aXJvbm1lbnQgb3IgdGhlIGluc3RhbGwgZm9sZGVyJ3Mg
  >> "!B64TMP!" echo LmVudiksIGkuZS4gc2VsZi1oZWFsaW5nIGEgZG93bgogICAgc3RhY2sgY2FuIGhlbHAuIiIiCiAg
  >> "!B64TMP!" echo ICByZXR1cm4gbm90IF9zZXR0aW5nKCJGSVJFQ1JBV0xfQVBJX1VSTCIpCgoKZGVmIHVybChwYXRo
  >> "!B64TMP!" echo KToKICAgICIiIkFic29sdXRlIFVSTCBmb3IgYW4gQVBJIHBhdGggbGlrZSAnL3YxL21hcCcgKHNl
  >> "!B64TMP!" echo ZSBiYXNlX3VybCgpKS4iIiIKICAgIHJldHVybiBiYXNlX3VybCgpICsgcGF0aAoKCmRlZiBhdXRo
  >> "!B64TMP!" echo X2hlYWRlcnMoKToKICAgICIiIkhlYWRlcnMgZm9yIGEgSlNPTiByZXF1ZXN0OiBjb250ZW50IHR5
  >> "!B64TMP!" echo cGUgKyBvcHRpb25hbCBCZWFyZXIgYXV0aCBmcm9tCiAgICBGSVJFQ1JBV0xfQVBJX0tFWSAoZW52
  >> "!B64TMP!" echo aXJvbm1lbnQgb3IgaW5zdGFsbCAuZW52OyBuZWVkZWQgZm9yIGFjY291bnQKICAgIGZlYXR1cmVz
  >> "!B64TMP!" echo IC8gdGhlIGNsb3VkIEFQSSkuIiIiCiAgICBoZWFkZXJzID0geyJDb250ZW50LVR5cGUiOiAiYXBw
  >> "!B64TMP!" echo bGljYXRpb24vanNvbiJ9CiAgICBrZXkgPSBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9LRVkiKQog
  >> "!B64TMP!" echo ICAgaWYga2V5OgogICAgICAgIGhlYWRlcnNbIkF1dGhvcml6YXRpb24iXSA9ICJCZWFyZXIgIiAr
  >> "!B64TMP!" echo IGtleQogICAgcmV0dXJuIGhlYWRlcnMKCgpkZWYgX3NlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0
  >> "!B64TMP!" echo aGUgY29udGFpbmVyIGVuZ2luZSArIHRoZSBjb250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRo
  >> "!B64TMP!" echo ZSBzYW1lCiAgICBsb2dpYyBhcyBlbnN1cmVfc3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQg
  >> "!B64TMP!" echo c28gdGhlIGZhc3QgcGF0aCAoc3RhY2sKICAgIGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0
  >> "!B64TMP!" echo dXJucyAob2ssIG1lc3NhZ2UpLiIiIgogICAgdHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sKICAgICAgICBvaywgbWVzc2FnZSwgX2NvZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5
  >> "!B64TMP!" echo KCkKICAgICAgICByZXR1cm4gb2ssIG1lc3NhZ2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTog
  >> "!B64TMP!" echo ICMgdW5leHBlY3RlZCBzZWxmLWhlYWwgZmFpbHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIEZhbHNlLCAic2VsZi1oZWFsIGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3Jt
  >> "!B64TMP!" echo YXQoZSkKCgpkZWYgX3JlYWRfYm9keShlKToKICAgICIiIkJlc3QtZWZmb3J0IGVycm9yIGJvZHkg
  >> "!B64TMP!" echo ZnJvbSBhbiBIVFRQRXJyb3IgKEpTT04gbWVzc2FnZSBvciByYXcgdGV4dCkuIiIiCiAgICB0cnk6
  >> "!B64TMP!" echo CiAgICAgICAgcmF3ID0gZS5yZWFkKCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuICIiCiAgICB0ZXh0ID0gcmF3LmRlY29kZSgidXRmLTgiLCAicmVwbGFjZSIpWzo4MDBdCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgcGF5bG9hZCA9IGpzb24ubG9hZHModGV4dCkKICAgICAgICBtc2cgPSBw
  >> "!B64TMP!" echo YXlsb2FkLmdldCgiZXJyb3IiKSBvciBwYXlsb2FkLmdldCgibWVzc2FnZSIpCiAgICAgICAgaWYg
  >> "!B64TMP!" echo aXNpbnN0YW5jZShtc2csIHN0cikgYW5kIG1zZzoKICAgICAgICAgICAgcmV0dXJuIG1zZwogICAg
  >> "!B64TMP!" echo ZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gdGV4dAoKCmRlZiBfaGlu
  >> "!B64TMP!" echo dF9mb3Jfc3RhdHVzKHN0YXR1cyk6CiAgICAiIiJBY3Rpb25hYmxlIGd1aWRhbmNlIGZvciB0aGUg
  >> "!B64TMP!" echo c3RhdHVzZXMgYWNjb3VudC1nYXRlZCBlbmRwb2ludHMgcmV0dXJuLiIiIgogICAgaWYgc3RhdHVz
  >> "!B64TMP!" echo IGluICg0MDEsIDQwMyk6CiAgICAgICAgcmV0dXJuICgiVGhpcyB0b29sIG5lZWRzIGFuIGF1dGhl
  >> "!B64TMP!" echo bnRpY2F0ZWQgRmlyZWNyYXdsIGFjY291bnQ6IHNldCAiCiAgICAgICAgICAgICAgICAiRklSRUNS
  >> "!B64TMP!" echo QVdMX0FQSV9LRVkgKGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jhd2wu
  >> "!B64TMP!" echo ZGV2ICIKICAgICAgICAgICAgICAgICJ0byB1c2UgdGhlIGNsb3VkIEFQSSkgYW5kIHJldHJ5LiIp
  >> "!B64TMP!" echo CiAgICBpZiBzdGF0dXMgPT0gNDA0OgogICAgICAgIHJldHVybiAoIlRoaXMgZW5kcG9pbnQgaXMg
  >> "!B64TMP!" echo bm90IGF2YWlsYWJsZSBvbiB0aGUgRmlyZWNyYXdsIGluc3RhbmNlIGl0ICIKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICJ3YXMgY2FsbGVkIGFnYWluc3QuIEFjY291bnQgdG9vbHMgKG1vbml0b3IgLyByZXNlYXJj
  >> "!B64TMP!" echo aCAvICIKICAgICAgICAgICAgICAgICJkZXZlbG9wZXIgc2VhcmNoKSBuZWVkIHRoZSBjbG91ZCBB
  >> "!B64TMP!" echo UEk6IHNldCAiCiAgICAgICAgICAgICAgICAiRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
  >> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiBhbmQgIgogICAgICAgICAgICAgICAgIkZJUkVDUkFXTF9BUElfS0VZLCB0
  >> "!B64TMP!" echo aGVuIHJldHJ5LiIpCiAgICBpZiBzdGF0dXMgaW4gUkVUUllfU1RBVFVTRVM6CiAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuICgiVGhlIEZpcmVjcmF3bCBzZXJ2aWNlIGFuc3dlcmVkIHdpdGggYSBzZXJ2ZXIgZXJyb3Iu
  >> "!B64TMP!" echo IEZvciBhIHBhZ2UgIgogICAgICAgICAgICAgICAgImZldGNoIHRoaXMgdXN1YWxseSBtZWFucyB0
  >> "!B64TMP!" echo aGUgdGFyZ2V0IHNpdGUgY291bGQgbm90IGJlIGxvYWRlZCAiCiAgICAgICAgICAgICAgICAiKHRp
  >> "!B64TMP!" echo bWVvdXQsIGJsb2NrZWQgcm91dGUgb3IgYm90IHByb3RlY3Rpb24pIC0gcmVwZWF0aW5nIHRoZSBz
  >> "!B64TMP!" echo YW1lICIKICAgICAgICAgICAgICAgICJyZXF1ZXN0IHJhcmVseSBjaGFuZ2VzIHRoYXQuIFJlYWQg
  >> "!B64TMP!" echo dGhlIGVycm9yIGFib3ZlLCBhbmQgaW5zcGVjdCAiCiAgICAgICAgICAgICAgICAidGhlIHN0YWNr
  >> "!B64TMP!" echo IHdpdGg6IGNkIDxpbnN0YWxsIGZvbGRlcj4gJiYgZG9ja2VyIGNvbXBvc2UgbG9ncyAiCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAiLS10YWlsIDUwIGZpcmVjcmF3bCAob3IgYHBvZG1hbiBjb21wb3NlIGxvZ3Mg
  >> "!B64TMP!" echo Li4uYCBpZiB0aGUgc3RhY2sgIgogICAgICAgICAgICAgICAgInJ1bnMgb24gUG9kbWFuKSIpCiAg
  >> "!B64TMP!" echo ICByZXR1cm4gTm9uZQoKCmRlZiBfdGFyZ2V0X3VybChib2R5KToKICAgICIiIlRoZSB3ZWIgcGFn
  >> "!B64TMP!" echo ZSBhIHJlcXVlc3QgYXNrcyBGaXJlY3Jhd2wgdG8gbG9hZCAoYm9keSAndXJsJywgb3IgdGhlIGZp
  >> "!B64TMP!" echo cnN0CiAgICBvZiAndXJscycpLCBvciBOb25lIGZvciBjYWxscyB0aGF0IGRvIG5vdCBmZXRjaCBh
  >> "!B64TMP!" echo IHBhZ2UgKHN0YXR1cyBwb2xscy4uLikuIiIiCiAgICBpZiBub3QgaXNpbnN0YW5jZShib2R5LCBk
  >> "!B64TMP!" echo aWN0KToKICAgICAgICByZXR1cm4gTm9uZQogICAgdGFyZ2V0ID0gYm9keS5nZXQoInVybCIpCiAg
  >> "!B64TMP!" echo ICBpZiBub3QgdGFyZ2V0IGFuZCBpc2luc3RhbmNlKGJvZHkuZ2V0KCJ1cmxzIiksIGxpc3QpIGFu
  >> "!B64TMP!" echo ZCBib2R5WyJ1cmxzIl06CiAgICAgICAgdGFyZ2V0ID0gYm9keVsidXJscyJdWzBdCiAgICByZXR1
  >> "!B64TMP!" echo cm4gdGFyZ2V0IGlmIGlzaW5zdGFuY2UodGFyZ2V0LCBzdHIpIGFuZCB0YXJnZXQuc3RyaXAoKSBl
  >> "!B64TMP!" echo bHNlIE5vbmUKCgpkZWYgX3JlcXVlc3QoZW5kcG9pbnQsIG1ldGhvZCwgYm9keV9ieXRlcywgaGVh
  >> "!B64TMP!" echo ZGVycywgdGltZW91dCk6CiAgICAiIiJPbmUgcmF3IEhUVFAgYXR0ZW1wdC4gUmFpc2VzIEhUVFBF
  >> "!B64TMP!" echo cnJvciAoc2VydmljZSBhbnN3ZXJlZCB3aXRoIGFuCiAgICBlcnJvciBzdGF0dXMg4oCUIHNlcnZp
  >> "!B64TMP!" echo Y2UgaXMgVVApIG9yIFVSTEVycm9yLWZhbWlseSAoY29ubmVjdGlvbiBwcm9ibGVtIOKAlAogICAg
  >> "!B64TMP!" echo c2VydmljZSBpcyBET1dOKS4gUmV0dXJucyB0aGUgcGFyc2VkIEpTT04gcmVzcG9uc2UuIiIiCiAg
  >> "!B64TMP!" echo ICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KGVuZHBvaW50LCBkYXRhPWJvZHlfYnl0ZXMs
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9aGVhZGVycywgbWV0aG9k
  >> "!B64TMP!" echo PW1ldGhvZCkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9dGlt
  >> "!B64TMP!" echo ZW91dCkgYXMgcjoKICAgICAgICB0ZXh0ID0gci5yZWFkKCkuZGVjb2RlKCJ1dGYtOCIsICJyZXBs
  >> "!B64TMP!" echo YWNlIikKICAgIGlmIG5vdCB0ZXh0LnN0cmlwKCk6CiAgICAgICAgcmV0dXJuIHt9CiAgICB0cnk6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIGpzb24ubG9hZHModGV4dCkKICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgog
  >> "!B64TMP!" echo ICAgICAgIHJhaXNlIEZjRXJyb3IoIkZpcmVjcmF3bCByZXR1cm5lZCBhIG5vbi1KU09OIHJlc3Bv
  >> "!B64TMP!" echo bnNlOiAiCiAgICAgICAgICAgICAgICAgICAgICArIHRleHRbOjMwMF0pCgoKZGVmIGNhbGwocGF0
  >> "!B64TMP!" echo aCwgbWV0aG9kPSJHRVQiLCBib2R5PU5vbmUsIHF1ZXJ5PU5vbmUsIHRpbWVvdXQ9VElNRU9VVCk6
  >> "!B64TMP!" echo CiAgICAiIiJDYWxsIHRoZSBGaXJlY3Jhd2wgQVBJIHdpdGggcmV0cmllcyArIHNlbGYtaGVhbGlu
  >> "!B64TMP!" echo Zy4KCiAgICBwYXRoICAgIEFQSSBwYXRoLCBlLmcuICIvdjEvbWFwIiBvciAiL3YxL2NyYXdsLzxp
  >> "!B64TMP!" echo ZD4iIChhbHJlYWR5IGVuY29kZWQpCiAgICBtZXRob2QgIEhUVFAgbWV0aG9kIChHRVQgLyBQT1NU
  >> "!B64TMP!" echo IC8gUEFUQ0ggLyBERUxFVEUpCiAgICBib2R5ICAgIEpTT04tc2VyaWFsaXNhYmxlIHJlcXVlc3Qg
  >> "!B64TMP!" echo Ym9keSAoZGljdCkgb3IgTm9uZQogICAgcXVlcnkgICBkaWN0IG9mIHF1ZXJ5LXN0cmluZyBwYXJh
  >> "!B64TMP!" echo bWV0ZXJzIChza2lwcGVkIHdoZW4gZW1wdHkvTm9uZSkKICAgIHRpbWVvdXQgc2Vjb25kcyBwZXIg
  >> "!B64TMP!" echo SFRUUCBhdHRlbXB0CgogICAgUmV0dXJucyB0aGUgcGFyc2VkIEpTT04gcmVzcG9uc2UgKGRpY3Qp
  >> "!B64TMP!" echo LiBSYWlzZXMgRmNFcnJvciBhZnRlciB0aGUKICAgIHJldHJpZXMgYXJlIGV4aGF1c3RlZCAoc2Vl
  >> "!B64TMP!" echo IG1vZHVsZSBkb2NzdHJpbmcgZm9yIHRoZSByZXRyeSBwb2xpY3kpLiIiIgogICAgZW5kcG9pbnQg
  >> "!B64TMP!" echo PSB1cmwocGF0aCkKICAgIGlmIHF1ZXJ5OgogICAgICAgIHBhaXJzID0gWyhrLCB2KSBmb3Igaywg
  >> "!B64TMP!" echo diBpbiBxdWVyeS5pdGVtcygpIGlmIHYgaXMgbm90IE5vbmVdCiAgICAgICAgaWYgcGFpcnM6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIGVuZHBvaW50ICs9ICI/IiArIHVybGxpYi5wYXJzZS51cmxlbmNvZGUocGFpcnMp
  >> "!B64TMP!" echo CiAgICBib2R5X2J5dGVzID0gTm9uZQogICAgaGVhZGVycyA9IGF1dGhfaGVhZGVycygpCiAgICBp
  >> "!B64TMP!" echo ZiBib2R5IGlzIG5vdCBOb25lOgogICAgICAgIGJvZHlfYnl0ZXMgPSBqc29uLmR1bXBzKGJvZHkp
  >> "!B64TMP!" echo LmVuY29kZSgidXRmLTgiKQoKICAgICMgQSBwYWdlIHRoZSBMT0NBTCBzdGFjayBpcyBhc2tlZCB0
  >> "!B64TMP!" echo byBsb2FkLiBXaGVuIHRoYXQgZmFpbHMsIHRoZSBuZXR3b3JrCiAgICAjIHBhdGggdG8gdGhlIHNp
  >> "!B64TMP!" echo dGUgaXMgY2hlY2tlZCAob25jZSBwZXIgY2FsbCkgc28gYSBibG9ja2VkIHJvdXRlIGlzCiAgICAj
  >> "!B64TMP!" echo IHJlcG9ydGVkIGFzIHN1Y2ggaW5zdGVhZCBvZiBiZWluZyB3YWl0ZWQgb24gYW5kIHJldHJpZWQu
  >> "!B64TMP!" echo CiAgICBzaXRlID0gX3RhcmdldF91cmwoYm9keSkgaWYgaXNfbG9jYWwoKSBlbHNlIE5vbmUKICAg
  >> "!B64TMP!" echo IGRpYWdfYm94ID0gW10KCiAgICBkZWYgc2l0ZV9kaWFnbm9zaXMoKToKICAgICAgICBpZiBub3Qg
  >> "!B64TMP!" echo ZGlhZ19ib3g6CiAgICAgICAgICAgIGRpYWdfYm94LmFwcGVuZChjb25maWcuZGlhZ25vc2VfdXJs
  >> "!B64TMP!" echo KHNpdGUpIGlmIHNpdGUgZWxzZSBOb25lKQogICAgICAgIHJldHVybiBkaWFnX2JveFswXQoKICAg
  >> "!B64TMP!" echo IGF0dGVtcHRzID0gMSArIGxlbihSRVRSWV9CQUNLT0ZGKSAgIyBpbml0aWFsICsgcmV0cmllcwog
  >> "!B64TMP!" echo ICAgZm9yIGF0dGVtcHQgaW4gcmFuZ2UoMSwgYXR0ZW1wdHMgKyAxKToKICAgICAgICAjIC0tLS0g
  >> "!B64TMP!" echo b25lIGF0dGVtcHQsIGNsYXNzaWZ5aW5nIGV2ZXJ5IGZhaWx1cmUgbW9kZSAtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLQogICAgICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50LCBt
  >> "!B64TMP!" echo ZXRob2QsIGJvZHlfYnl0ZXMsIGhlYWRlcnMsIHRpbWVvdXQpCiAgICAgICAgZXhjZXB0IHVybGxp
  >> "!B64TMP!" echo Yi5lcnJvci5IVFRQRXJyb3IgYXMgZToKICAgICAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIGRldGFpbCA9IF9yZWFkX2JvZHkoZSkKICAgICAgICAgICAgZGlhZyA9IHNpdGVfZGlh
  >> "!B64TMP!" echo Z25vc2lzKCkgaWYgKHNpdGUgYW5kIChzdGF0dXMgPj0gNTAwIG9yIHN0YXR1cyA9PSA0MDgpKSBl
  >> "!B64TMP!" echo bHNlIE5vbmUKICAgICAgICAgICAgYmxvY2tlZCA9IGJvb2woZGlhZyBhbmQgZGlhZy5ibG9ja2Vk
  >> "!B64TMP!" echo KQogICAgICAgICAgICBpZiBzdGF0dXMgaW4gUkVUUllfU1RBVFVTRVMgYW5kIGF0dGVtcHQgPCBh
  >> "!B64TMP!" echo dHRlbXB0cyBhbmQgbm90IGJsb2NrZWQ6CiAgICAgICAgICAgICAgICB3YWl0ID0gUkVUUllfQkFD
  >> "!B64TMP!" echo S09GRlthdHRlbXB0IC0gMV0KICAgICAgICAgICAgICAgIHByaW50KGYiRmlyZWNyYXdsIGFuc3dl
  >> "!B64TMP!" echo cmVkIHtzdGF0dXN9ICh7ZGV0YWlsIG9yICdzZXJ2ZXIgZXJyb3InfSkgIgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZiLigJQgcmV0cnlpbmcgaW4ge3dhaXR9cyAuLi4iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKHdhaXQpCiAgICAgICAgICAgICAgICBjb250aW51
  >> "!B64TMP!" echo ZQogICAgICAgICAgICBpZiBibG9ja2VkOgogICAgICAgICAgICAgICAgaGludCA9IGRpYWcudGV4
  >> "!B64TMP!" echo dAogICAgICAgICAgICBlbGlmIGRpYWc6CiAgICAgICAgICAgICAgICBoaW50ID0gZGlhZy50ZXh0
  >> "!B64TMP!" echo ICsgIlxuIiArIChfaGludF9mb3Jfc3RhdHVzKHN0YXR1cykgb3IgIiIpCiAgICAgICAgICAgIGVs
  >> "!B64TMP!" echo c2U6CiAgICAgICAgICAgICAgICBoaW50ID0gX2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpCiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJhaXNlIEZjRXJyb3IoIkhUVFAge317fXt9Ii5mb3JtYXQoCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBzdGF0dXMsICI6ICIgKyBkZXRhaWwgaWYgZGV0YWlsIGVsc2UgIiIsCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiIiBpZiBhdHRlbXB0ID09IDEgZWxzZSBmIiAoYWZ0ZXIge2F0dGVtcHR9IGF0dGVtcHRzKSIp
  >> "!B64TMP!" echo LAogICAgICAgICAgICAgICAgc3RhdHVzPXN0YXR1cywgaGludD1oaW50LnN0cmlwKCkgaWYgaGlu
  >> "!B64TMP!" echo dCBlbHNlIE5vbmUpIGZyb20gZQogICAgICAgIGV4Y2VwdCBGY0Vycm9yOgogICAgICAgICAgICBy
  >> "!B64TMP!" echo YWlzZQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgVVJMRXJyb3IgLyBDb25uZWN0
  >> "!B64TMP!" echo aW9uRXJyb3IgLyB0aW1lb3V0OiBET1dOCiAgICAgICAgICAgIGlmIG5vdCBpc19sb2NhbCgpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigKICAgICAgICAgICAgICAgICAgICAiY291bGQg
  >> "!B64TMP!" echo bm90IHJlYWNoIHt9ICh7fSkuIENoZWNrIHRoZSBVUkwgYW5kIHlvdXIgIgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICJuZXR3b3JrLCB0aGVuIHJldHJ5LiIuZm9ybWF0KGJhc2VfdXJsKCksIGUpKSBmcm9t
  >> "!B64TMP!" echo IGUKICAgICAgICAgICAgaWYgY29uZmlnLmlzX3RpbWVvdXQoZSkgYW5kIGNvbmZpZy5wb3J0X2xp
  >> "!B64TMP!" echo c3RlbmluZyhiYXNlX3VybCgpKToKICAgICAgICAgICAgICAgICMgVGhlIHN0YWNrIEFDQ0VQVFMg
  >> "!B64TMP!" echo Y29ubmVjdGlvbnM6IGl0IGlzIHVwLCB0aGUgcGFnZSBqdXN0IGRpZAogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IyBub3QgbG9hZCBpbiB0aW1lLiBSZXN0YXJ0aW5nIGl0IGFuZCByZXBlYXRpbmcgdGhlIHJlcXVl
  >> "!B64TMP!" echo c3QKICAgICAgICAgICAgICAgICMgd291bGQgb25seSB3YWl0IGFub3RoZXIgZnVsbCB0aW1lb3V0
  >> "!B64TMP!" echo LgogICAgICAgICAgICAgICAgZGlhZyA9IHNpdGVfZGlhZ25vc2lzKCkKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IHJhaXNlIEZjRXJyb3IoCiAgICAgICAgICAgICAgICAgICAgIm5vIGFuc3dlciBmcm9tIEZpcmVj
  >> "!B64TMP!" echo cmF3bCB3aXRoaW4ge31zICh7fSkuIFRoZSBzdGFjayBpcyAiCiAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo InJ1bm5pbmcsIHNvIGl0IHdhcyBub3QgcmVzdGFydGVkIGFuZCB0aGUgcmVxdWVzdCB3YXMgbm90
  >> "!B64TMP!" echo ICIKICAgICAgICAgICAgICAgICAgICAicmVwZWF0ZWQuIi5mb3JtYXQodGltZW91dCwgZSksCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgaGludD1kaWFnLnRleHQgaWYgZGlhZyBlbHNlIE5vbmUpIGZyb20g
  >> "!B64TMP!" echo ZQogICAgICAgICAgICBpZiBhdHRlbXB0IDwgYXR0ZW1wdHM6CiAgICAgICAgICAgICAgICAjIExv
  >> "!B64TMP!" echo Y2FsIHN0YWNrOiB0cnkgdG8gYnJpbmcgaXQgdXAsIHRoZW4gcmV0cnkgdGhlIHJlcXVlc3QuCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludChmIlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGlu
  >> "!B64TMP!" echo ZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAgICAgICAgICAgICAgICBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgICAgICAgICBvaywgbWVzc2FnZSA9IF9zZWxmaGVhbCgpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBpZiBub3Qgb2s6CiAgICAgICAgICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgInRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgY291bGQgbm90IGJl
  >> "!B64TMP!" echo IHN0YXJ0ZWQ6ICIgKyBtZXNzYWdlCiAgICAgICAgICAgICAgICAgICAgICAgICsgIiBSZXNvbHZl
  >> "!B64TMP!" echo IHRoZSBzdGFjayAob3IgYXNrIHRoZSB1c2VyIHRvIHN0YXJ0IFBvZG1hbi9Eb2NrZXIgIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICJEZXNrdG9wKSBhbmQgcmV0cnkg4oCUIGRvIE5PVCBmYWxs
  >> "!B64TMP!" echo IGJhY2sgdG8gb3RoZXIgd2ViICIKICAgICAgICAgICAgICAgICAgICAgICAgICAidG9vbHMgdW5s
  >> "!B64TMP!" echo ZXNzIHRoZSB1c2VyIGFza3MuIikgZnJvbSBlCiAgICAgICAgICAgICAgICBjb250aW51ZQogICAg
  >> "!B64TMP!" echo ICAgICAgICByYWlzZSBGY0Vycm9yKAogICAgICAgICAgICAgICAgInJlcXVlc3QgZmFpbGVkIGFm
  >> "!B64TMP!" echo dGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDoge30iLmZvcm1hdChlKSkgZnJvbSBlCiAgICAjIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlOiB0aGUgbG9vcCBlaXRoZXIgcmV0dXJucyBvciByYWlzZXMKICAgIHJhaXNlIEZj
  >> "!B64TMP!" echo RXJyb3IoInJlcXVlc3QgZmFpbGVkIHVuZXhwZWN0ZWRseSIpCgoKZGVmIGNhbGxfZm9ybShwYXRo
  >> "!B64TMP!" echo LCBmaWVsZHMsIGZpbGVfcGF0aCwgZmlsZV9maWVsZD0iZmlsZSIsIHRpbWVvdXQ9VElNRU9VVCk6
  >> "!B64TMP!" echo CiAgICAiIiJDYWxsIHRoZSBGaXJlY3Jhd2wgQVBJIHdpdGggYSBtdWx0aXBhcnQvZm9ybS1kYXRh
  >> "!B64TMP!" echo IGJvZHkgKHVzZWQgYnkKICAgIHdlYl9wYXJzZS5weSB0byB1cGxvYWQgYSBsb2NhbCBkb2N1bWVu
  >> "!B64TMP!" echo dCkuCgogICAgZmllbGRzICAgICAgZGljdCBvZiBmb3JtIGZpZWxkcyAodmFsdWVzIGFyZSBzdHIg
  >> "!B64TMP!" echo LyBpbnQgLyBsaXN0KQogICAgZmlsZV9wYXRoICAgdGhlIGZpbGUgdG8gdXBsb2FkIChyZWFkIGlu
  >> "!B64TMP!" echo IGJpbmFyeSBtb2RlKQogICAgZmlsZV9maWVsZCAgdGhlIGZvcm0gZmllbGQgbmFtZSBmb3IgdGhl
  >> "!B64TMP!" echo IGZpbGUgKEZpcmVjcmF3bDogImZpbGUiKQogICAgIiIiCiAgICBib3VuZGFyeSA9ICItLS0tbG9j
  >> "!B64TMP!" echo YWx3ZWJzZWFyY2giICsgZm9ybWF0KGludCh0aW1lLnRpbWUoKSAqIDEwMDApLCAieCIpCiAgICBw
  >> "!B64TMP!" echo YXJ0cyA9IFtdCiAgICBmb3Iga2V5LCB2YWwgaW4gKGZpZWxkcyBvciB7fSkuaXRlbXMoKToKICAg
  >> "!B64TMP!" echo ICAgICBpZiB2YWwgaXMgTm9uZToKICAgICAgICAgICAgY29udGludWUKICAgICAgICB2YWx1ZXMg
  >> "!B64TMP!" echo PSB2YWwgaWYgaXNpbnN0YW5jZSh2YWwsIGxpc3QpIGVsc2UgW3ZhbF0KICAgICAgICBmb3IgdiBp
  >> "!B64TMP!" echo biB2YWx1ZXM6CiAgICAgICAgICAgIHBhcnRzLmFwcGVuZCgoIi0tIiArIGJvdW5kYXJ5KS5lbmNv
  >> "!B64TMP!" echo ZGUoInV0Zi04IikpCiAgICAgICAgICAgIHBhcnRzLmFwcGVuZCgoJ0NvbnRlbnQtRGlzcG9zaXRp
  >> "!B64TMP!" echo b246IGZvcm0tZGF0YTsgbmFtZT0ie30iJwogICAgICAgICAgICAgICAgICAgICAgICAgIC5mb3Jt
  >> "!B64TMP!" echo YXQoa2V5KSkuZW5jb2RlKCJ1dGYtOCIpKQogICAgICAgICAgICBwYXJ0cy5hcHBlbmQoYiIiKQog
  >> "!B64TMP!" echo ICAgICAgICAgICBwYXJ0cy5hcHBlbmQoc3RyKHYpLmVuY29kZSgidXRmLTgiKSkKICAgIHRyeToK
  >> "!B64TMP!" echo ICAgICAgICB3aXRoIG9wZW4oZmlsZV9wYXRoLCAicmIiKSBhcyBmaDoKICAgICAgICAgICAgcGF5
  >> "!B64TMP!" echo bG9hZCA9IGZoLnJlYWQoKQogICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICByYWlzZSBG
  >> "!B64TMP!" echo Y0Vycm9yKCJjb3VsZCBub3QgcmVhZCB7fToge30iLmZvcm1hdChmaWxlX3BhdGgsIGUpKQogICAg
  >> "!B64TMP!" echo ZmlsZW5hbWUgPSBvcy5wYXRoLmJhc2VuYW1lKGZpbGVfcGF0aCkKICAgIHBhcnRzLmFwcGVuZCgo
  >> "!B64TMP!" echo Ii0tIiArIGJvdW5kYXJ5KS5lbmNvZGUoInV0Zi04IikpCiAgICBwYXJ0cy5hcHBlbmQoKCdDb250
  >> "!B64TMP!" echo ZW50LURpc3Bvc2l0aW9uOiBmb3JtLWRhdGE7IG5hbWU9Int9IjsgZmlsZW5hbWU9Int9IicKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgLmZvcm1hdChmaWxlX2ZpZWxkLCBmaWxlbmFtZSkpLmVuY29kZSgidXRm
  >> "!B64TMP!" echo LTgiKSkKICAgIHBhcnRzLmFwcGVuZChiIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vb2N0ZXQt
  >> "!B64TMP!" echo c3RyZWFtIikKICAgIHBhcnRzLmFwcGVuZChiIiIpCiAgICBwYXJ0cy5hcHBlbmQocGF5bG9hZCkK
  >> "!B64TMP!" echo ICAgIHBhcnRzLmFwcGVuZCgoIi0tIiArIGJvdW5kYXJ5ICsgIi0tIikuZW5jb2RlKCJ1dGYtOCIp
  >> "!B64TMP!" echo KQogICAgYm9keSA9IGIiXHJcbiIuam9pbihwYXJ0cykKCiAgICBlbmRwb2ludCA9IHVybChwYXRo
  >> "!B64TMP!" echo KQogICAgaGVhZGVycyA9IHsKICAgICAgICAiQ29udGVudC1UeXBlIjogIm11bHRpcGFydC9mb3Jt
  >> "!B64TMP!" echo LWRhdGE7IGJvdW5kYXJ5PSIgKyBib3VuZGFyeSwKICAgIH0KICAgIGtleSA9IF9zZXR0aW5nKCJG
  >> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX0tFWSIpCiAgICBpZiBrZXk6CiAgICAgICAgaGVhZGVyc1siQXV0aG9yaXph
  >> "!B64TMP!" echo dGlvbiJdID0gIkJlYXJlciAiICsga2V5CgogICAgdHJ5OgogICAgICAgIHJldHVybiBfcmVxdWVz
  >> "!B64TMP!" echo dChlbmRwb2ludCwgIlBPU1QiLCBib2R5LCBoZWFkZXJzLCB0aW1lb3V0KQogICAgZXhjZXB0IHVy
  >> "!B64TMP!" echo bGxpYi5lcnJvci5IVFRQRXJyb3IgYXMgZToKICAgICAgICBzdGF0dXMgPSBlLmNvZGUKICAgICAg
  >> "!B64TMP!" echo ICBkZXRhaWwgPSBfcmVhZF9ib2R5KGUpCiAgICAgICAgcmFpc2UgRmNFcnJvcigiSFRUUCB7fXt9
  >> "!B64TMP!" echo e30iLmZvcm1hdCgKICAgICAgICAgICAgc3RhdHVzLCAiOiAiICsgZGV0YWlsIGlmIGRldGFpbCBl
  >> "!B64TMP!" echo bHNlICIiKSwKICAgICAgICAgICAgc3RhdHVzPXN0YXR1cywgaGludD1faGludF9mb3Jfc3RhdHVz
  >> "!B64TMP!" echo KHN0YXR1cykpIGZyb20gZQogICAgZXhjZXB0IEZjRXJyb3I6CiAgICAgICAgcmFpc2UKICAgIGV4
  >> "!B64TMP!" echo Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgY29ubmVjdGlvbiBwcm9ibGVtOiBzdGFjayAocHJvYmFi
  >> "!B64TMP!" echo bHkpIGRvd24KICAgICAgICBpZiBub3QgaXNfbG9jYWwoKToKICAgICAgICAgICAgcmFpc2UgRmNF
  >> "!B64TMP!" echo cnJvcigKICAgICAgICAgICAgICAgICJjb3VsZCBub3QgcmVhY2gge30gKHt9KS4gQ2hlY2sgdGhl
  >> "!B64TMP!" echo IFVSTCBhbmQgeW91ciBuZXR3b3JrLCAiCiAgICAgICAgICAgICAgICAidGhlbiByZXRyeS4iLmZv
  >> "!B64TMP!" echo cm1hdChiYXNlX3VybCgpLCBlKSkgZnJvbSBlCiAgICAgICAgcHJpbnQoZiJTdGFjayB1bnJlYWNo
  >> "!B64TMP!" echo YWJsZSAoe2V9KSDigJQgc3RhcnRpbmcgaXQgYXV0b21hdGljYWxseSAuLi4iLAogICAgICAgICAg
  >> "!B64TMP!" echo ICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBvaywgbWVzc2FnZSA9IF9zZWxmaGVhbCgpCiAg
  >> "!B64TMP!" echo ICAgICAgaWYgbm90IG9rOgogICAgICAgICAgICByYWlzZSBGY0Vycm9yKCJ0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIHN0YWNrIGNvdWxkIG5vdCBiZSBzdGFydGVkOiAiCiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgKyBtZXNzYWdlKSBmcm9tIGUKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBfcmVx
  >> "!B64TMP!" echo dWVzdChlbmRwb2ludCwgIlBPU1QiLCBib2R5LCBoZWFkZXJzLCB0aW1lb3V0KQogICAgICAgIGV4
  >> "!B64TMP!" echo Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGUyOgogICAgICAgICAgICByYWlzZSBGY0Vy
  >> "!B64TMP!" echo cm9yKCJIVFRQIHt9OiB7fSIuZm9ybWF0KGUyLmNvZGUsIF9yZWFkX2JvZHkoZTIpKSwKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBzdGF0dXM9ZTIuY29kZSwKICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBoaW50PV9oaW50X2Zvcl9zdGF0dXMoZTIuY29kZSkpIGZyb20gZTIKICAgICAgICBleGNl
  >> "!B64TMP!" echo cHQgRXhjZXB0aW9uIGFzIGUyOgogICAgICAgICAgICByYWlzZSBGY0Vycm9yKCJyZXF1ZXN0IGZh
  >> "!B64TMP!" echo aWxlZCBhZnRlciB0aGUgc3RhY2sgd2FzIHN0YXJ0ZWQ6ICIKICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAie30iLmZvcm1hdChlMikpIGZyb20gZTIK
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
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JhcGUuCgpXaGVuIGEgcGFnZSBmYWlscyB0
  >> "!B64TMP!" echo byBsb2FkLCB0aGUgc2NyaXB0IGNoZWNrcyB0aGUgbmV0d29yayBwYXRoIHRvIHRoZSBzaXRlCihE
  >> "!B64TMP!" echo TlMgKyBvbmUgc2hvcnQgVENQIGNvbm5lY3Rpb24sIHNlZSBjb25maWcuZGlhZ25vc2VfdXJsKSBh
  >> "!B64TMP!" echo bmQgc2F5cyBwbGFpbmx5CndoZXRoZXIgdGhlIHJvdXRlIGlzIGJsb2NrZWQg4oCUIGUuZy4gYSBw
  >> "!B64TMP!" echo cm94eS9WUE4gZmFrZS1JUCBzdWNoIGFzIDE5OC4xOC54LngKd2hvc2UgdHJhZmZpYyBpcyBkcm9w
  >> "!B64TMP!" echo cGVkLiBBIGJsb2NrZWQgcm91dGUgaXMgTk9UIHJldHJpZWQgb3Igd2FpdGVkIG9uLCBhbmQgYQpy
  >> "!B64TMP!" echo dW5uaW5nIHN0YWNrIGlzIG5ldmVyIHJlc3RhcnRlZCBvdmVyIGEgcGFnZSB0aGF0IG1lcmVseSB0
  >> "!B64TMP!" echo aW1lZCBvdXQuCgpQcmludHMgdGhlIHBhZ2UncyBNYXJrZG93biB0byBzdGRvdXQsIHRydW5jYXRl
  >> "!B64TMP!" echo ZCBhdCAtLW1heC1jaGFycy4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmlt
  >> "!B64TMP!" echo cG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0
  >> "!B64TMP!" echo L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQoj
  >> "!B64TMP!" echo IChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gc2NyYXBlZCBwYWdlIGNvbnRlbnQgd2l0aCBub24t
  >> "!B64TMP!" echo QVNDSUkgdGV4dCBuZXZlcgojIGNyYXNoZXMgd2l0aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tp
  >> "!B64TMP!" echo cHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFscmVhZHkKIyBzZXQg4oCUIGFuIGV4cGxpY2l0
  >> "!B64TMP!" echo IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVu
  >> "!B64TMP!" echo dmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAg
  >> "!B64TMP!" echo ICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUiKToKICAgICAgICAgICAgdHJ5Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiKQogICAg
  >> "!B64TMP!" echo ICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGgu
  >> "!B64TMP!" echo aW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1w
  >> "!B64TMP!" echo b3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1k
  >> "!B64TMP!" echo cml2ZW4gZW5kcG9pbnRzCgojIFBvcnQgY29tZXMgZnJvbSBGSVJFQ1JBV0xfUE9SVCBpbiB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0IDk5OTEpLgpFTkRQT0lOVCA9IGNvbmZpZy5l
  >> "!B64TMP!" echo bmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSlbImZpcmVjcmF3bCJdICsgIi92MS9z
  >> "!B64TMP!" echo Y3JhcGUiCgpUSU1FT1VUID0gOTAgICMgc2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZl
  >> "!B64TMP!" echo dGNoKHVybCk6CiAgICAiIiJQT1NUIHRoZSBzY3JhcGUgcmVxdWVzdC4gUmFpc2VzIEhUVFBFcnJv
  >> "!B64TMP!" echo ciB3aGVuIHRoZSBzZXJ2aWNlIGFuc3dlcmVkCiAgICB3aXRoIGFuIGVycm9yIHN0YXR1cyAoc2Vy
  >> "!B64TMP!" echo dmljZSBpcyBVUCksIFVSTEVycm9yLWZhbWlseSBvbiBjb25uZWN0aW9uCiAgICBwcm9ibGVtcyAo
  >> "!B64TMP!" echo c2VydmljZSBpcyBET1dOKS4iIiIKICAgIGJvZHkgPSBqc29uLmR1bXBzKHsidXJsIjogdXJsLCAi
  >> "!B64TMP!" echo Zm9ybWF0cyI6IFsibWFya2Rvd24iXX0pLmVuY29kZSgpCiAgICByZXEgPSB1cmxsaWIucmVxdWVz
  >> "!B64TMP!" echo dC5SZXF1ZXN0KAogICAgICAgIEVORFBPSU5ULAogICAgICAgIGRhdGE9Ym9keSwKICAgICAgICBo
  >> "!B64TMP!" echo ZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24ifSwKICAgICAgICBtZXRo
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
  >> "!B64TMP!" echo ZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRlZiBlcnJvcl9kZXRhaWwoZSk6CiAgICAiIiJG
  >> "!B64TMP!" echo aXJlY3Jhd2wncyBvd24gZXJyb3IgdGV4dCBmcm9tIGFuIEhUVFBFcnJvciBib2R5IChKU09OIG1l
  >> "!B64TMP!" echo c3NhZ2Ugb3IKICAgIHJhdyB0ZXh0KSwgb3IgJycg4oCUIHRoaXMgaXMgd2hlcmUgdGhlIHJlYWwg
  >> "!B64TMP!" echo cmVhc29uIGZvciBhIGZhaWxlZCBzY3JhcGUgaXMuIiIiCiAgICB0cnk6CiAgICAgICAgdGV4dCA9
  >> "!B64TMP!" echo IGUucmVhZCgpLmRlY29kZSgidXRmLTgiLCAicmVwbGFjZSIpWzo4MDBdCiAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uOgogICAgICAgIHJldHVybiAiIgogICAgdHJ5OgogICAgICAgIHBheWxvYWQgPSBqc29u
  >> "!B64TMP!" echo LmxvYWRzKHRleHQpCiAgICAgICAgbXNnID0gcGF5bG9hZC5nZXQoImVycm9yIikgb3IgcGF5bG9h
  >> "!B64TMP!" echo ZC5nZXQoIm1lc3NhZ2UiKQogICAgICAgIGlmIGlzaW5zdGFuY2UobXNnLCBzdHIpIGFuZCBtc2c6
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiBtc2cKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFz
  >> "!B64TMP!" echo cwogICAgcmV0dXJuIHRleHQuc3RyaXAoKQoKCmRlZiBkaWFnbm9zZSh1cmwsIG9ubHlfaWZfYmxv
  >> "!B64TMP!" echo Y2tlZD1GYWxzZSk6CiAgICAiIiJQcmludCB0aGUgbmV0d29yayBkaWFnbm9zaXMgZm9yIGEgcGFn
  >> "!B64TMP!" echo ZSB0aGF0IGZhaWxlZCB0byBsb2FkIChzdGRlcnIpLgogICAgUmV0dXJucyBUcnVlIHdoZW4gdGhl
  >> "!B64TMP!" echo IHJvdXRlIHRvIHRoZSBzaXRlIGlzIGJsb2NrZWQsIGkuZS4gcmV0cnlpbmcgdGhlCiAgICBzYW1l
  >> "!B64TMP!" echo IFVSTCBjYW5ub3QgaGVscC4iIiIKICAgIGQgPSBjb25maWcuZGlhZ25vc2VfdXJsKHVybCkKICAg
  >> "!B64TMP!" echo IGlmIGQgaXMgTm9uZToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIGQuYmxvY2tlZCBvciBu
  >> "!B64TMP!" echo b3Qgb25seV9pZl9ibG9ja2VkOgogICAgICAgIHByaW50KGQudGV4dCwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIGQuYmxvY2tlZAoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5
  >> "!B64TMP!" echo cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgog
  >> "!B64TMP!" echo ICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3NjcmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMgTl0i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0KICAg
  >> "!B64TMP!" echo IG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0gMQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAg
  >> "!B64TMP!" echo ICAgICBpZiBhcmdzW2ldID09ICItLW1heC1jaGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkgKz0g
  >> "!B64TMP!" echo MgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAgICB0
  >> "!B64TMP!" echo cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRU
  >> "!B64TMP!" echo UEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUgc2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRoIGFu
  >> "!B64TMP!" echo IGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7CiAgICAgICAgIyBzdGFydGluZyBjb250YWluZXJz
  >> "!B64TMP!" echo IHdvdWxkIG5vdCBoZWxwLgogICAgICAgIGRldGFpbCA9IGVycm9yX2RldGFpbChlKQogICAgICAg
  >> "!B64TMP!" echo IHByaW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3VybH06IHtlfSIgKyAoZiIgLSB7ZGV0YWlsfSIg
  >> "!B64TMP!" echo aWYgZGV0YWlsIGVsc2UgIiIpLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAg
  >> "!B64TMP!" echo ICBpZiBkaWFnbm9zZSh1cmwpOgogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHByaW50KCJG
  >> "!B64TMP!" echo aXJlY3Jhd2wgYW5zd2VyZWQgd2l0aCBhbiBlcnJvciBzdGF0dXMgKHRoZSBzdGFjayBpcyBydW5u
  >> "!B64TMP!" echo aW5nKS4gIgogICAgICAgICAgICAgICJSZXRyeSBvbmNlIHdpdGggYSBkaWZmZXJlbnQgcmVzdWx0
  >> "!B64TMP!" echo IFVSTCwgb3IgaW5zcGVjdCB0aGUgc3RhY2sgIgogICAgICAgICAgICAgICJ3aXRoOiBjZCA8aW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21wb3NlIGxvZ3MgLS10YWlsIDUwICIKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAiZmlyZWNyYXdsIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCiAgICBl
  >> "!B64TMP!" echo eGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgaWYgY29uZmlnLmlzX3RpbWVvdXQoZSkgYW5k
  >> "!B64TMP!" echo IGNvbmZpZy5wb3J0X2xpc3RlbmluZyhFTkRQT0lOVCk6CiAgICAgICAgICAgICMgVGhlIHN0YWNr
  >> "!B64TMP!" echo IEFDQ0VQVFMgY29ubmVjdGlvbnM7IHRoZSBwYWdlIGp1c3QgZGlkIG5vdCBsb2FkIGluCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICMgdGltZS4gUmVzdGFydGluZyB0aGUgc3RhY2sgYW5kIHJlLXJ1bm5pbmcgdGhlIHNh
  >> "!B64TMP!" echo bWUgc2NyYXBlCiAgICAgICAgICAgICMgd291bGQgb25seSB3YWl0IGFub3RoZXIgZnVsbCB0aW1l
  >> "!B64TMP!" echo b3V0LgogICAgICAgICAgICBwcmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9OiBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgZGlkIG5vdCBhbnN3ZXIgd2l0aGluICIKICAgICAgICAgICAgICAgICAgZiJ7VElNRU9VVH1z
  >> "!B64TMP!" echo ICh7ZX0pLiBUaGUgc3RhY2sgaXMgcnVubmluZywgc28gaXQgd2FzIG5vdCAiCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICJyZXN0YXJ0ZWQgYW5kIHRoZSBzY3JhcGUgd2FzIG5vdCByZXBlYXRlZC4iLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIG5vdCBkaWFnbm9zZSh1cmwpOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcHJpbnQoIlRyeSBhIGRpZmZlcmVudCByZXN1bHQgVVJMOiB0aGlzIHBhZ2UgaXMgc2xv
  >> "!B64TMP!" echo dyBvciAiCiAgICAgICAgICAgICAgICAgICAgICAiYmxvY2tzIGF1dG9tYXRlZCBhY2Nlc3MuIiwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgICMgQ29ubmVjdGlv
  >> "!B64TMP!" echo biBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwK
  >> "!B64TMP!" echo ICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFwZS4KICAgICAgICBwcmludChmIlN0YWNrIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwo
  >> "!B64TMP!" echo KQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0NSQVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIKICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQu
  >> "!B64TMP!" echo IFJlc29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCByZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0
  >> "!B64TMP!" echo byBvdGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAgICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFz
  >> "!B64TMP!" echo a3MuIi5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMQog
  >> "!B64TMP!" echo ICAgICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgICAgICBleGNlcHQg
  >> "!B64TMP!" echo RXhjZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBwcmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1
  >> "!B64TMP!" echo cmx9IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDoge2UyfSIsCiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgZGlhZ25vc2UodXJsKQogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQoKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIG9yIHt9CiAgICBtYXJrZG93
  >> "!B64TMP!" echo biA9IHBheWxvYWQuZ2V0KCJtYXJrZG93biIpIG9yICIiIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwg
  >> "!B64TMP!" echo ZGljdCkgZWxzZSAiIgogICAgaWYgbm90IG1hcmtkb3duOgogICAgICAgIHByaW50KCJTQ1JBUEUg
  >> "!B64TMP!" echo UkVUVVJORUQgTk8gTUFSS0RPV04gZm9yIiwgdXJsLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoanNvbi5kdW1wcyhkYXRhKVs6ODAwXSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGRp
  >> "!B64TMP!" echo YWdub3NlKHVybCwgb25seV9pZl9ibG9ja2VkPVRydWUpCiAgICAgICAgcmV0dXJuIDEKCiAgICBp
  >> "!B64TMP!" echo ZiBsZW4obWFya2Rvd24pID4gbWF4X2NoYXJzOgogICAgICAgIG1hcmtkb3duID0gbWFya2Rvd25b
  >> "!B64TMP!" echo Om1heF9jaGFyc10gKyBmIlxuXG5bLi4uIHRydW5jYXRlZCBhdCB7bWF4X2NoYXJzfSBjaGFycyAu
  >> "!B64TMP!" echo Li5dIgogICAgcHJpbnQobWFya2Rvd24pCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJf
  >> "!B64TMP!" echo X21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
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
  >> "!B64TMP!" echo aXB0IGFuZCBwcmludCBpdCBhcyBgW01NOlNTXSB0ZXh0YCBsaW5lcy4KClVzYWdlOgogICAgcHl0
  >> "!B64TMP!" echo aG9uIHdlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkgPHZpZGVvX2lkIHwgeW91dHViZSB1cmw+IFst
  >> "!B64TMP!" echo LWxhbmcgZW4sZGVdCgpXaHkgeXQtZGxwOiBZb3VUdWJlIG5vdyBwcm90ZWN0cyB0aGUgY2FwdGlv
  >> "!B64TMP!" echo biB0cmFja3Mgb2YgYSBncm93aW5nIHNoYXJlIG9mCnZpZGVvcyB3aXRoIGEgIlBPIHRva2VuIiAo
  >> "!B64TMP!" echo dGhlIHRyYWNrIFVSTCBjYXJyaWVzIGBleHA9eHBlYCk7IGEgcGxhaW4gcmVxdWVzdApmb3Igc3Vj
  >> "!B64TMP!" echo aCBhIHRyYWNrIGdldHMgYW4gRU1QVFkgYW5zd2VyLiBgeW91dHViZS10cmFuc2NyaXB0LWFwaWAg
  >> "!B64TMP!" echo Y2Fubm90IHByb2R1Y2UKdGhhdCB0b2tlbiwgeXQtZGxwIGNhbi4gU28gdGhpcyBzY3JpcHQgdXNl
  >> "!B64TMP!" echo cyB5dC1kbHAsIHdoaWNoIG5lZWRzCgogICAgcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0
  >> "!B64TMP!" echo XSIgICAgICAgICMgaW5jbHVkZXMgeXQtZGxwLWVqcwogICAgKyBhIEphdmFTY3JpcHQgcnVudGlt
  >> "!B64TMP!" echo ZSBvbiBQQVRIOiBEZW5vLCBvciBOb2RlLmpzIDIyKyAoQnVuIC8gUXVpY2tKUyBhbHNvIHdvcmsp
  >> "!B64TMP!" echo CgpJZiB5dC1kbHAgaXMgbm90IGluc3RhbGxlZCAob3IgZmFpbHMpIGl0IGZhbGxzIGJhY2sgdG8g
  >> "!B64TMP!" echo dGhlIG9sZGVyCmB5b3V0dWJlLXRyYW5zY3JpcHQtYXBpYCBwYWNrYWdlLCB3aGljaCBzdGlsbCB3
  >> "!B64TMP!" echo b3JrcyBmb3IgdmlkZW9zIHRoYXQgYXJlIG5vdApiZWhpbmQgdGhlIHRva2VuIHlldC4KCkV4aXQg
  >> "!B64TMP!" echo c3RhdHVzOiAwID0gdHJhbnNjcmlwdCBwcmludGVkLCAxID0gZmFpbGVkIChyZWFzb24gb24gc3Rk
  >> "!B64TMP!" echo ZXJyKSwgMiA9IHVzYWdlLgoiIiIKaW1wb3J0IGdsb2IKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmlt
  >> "!B64TMP!" echo cG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0
  >> "!B64TMP!" echo IHRlbXBmaWxlCgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9m
  >> "!B64TMP!" echo IHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gdHJh
  >> "!B64TMP!" echo bnNjcmlwdHMgd2l0aCBub24tQVNDSUkgdGV4dCBuZXZlciBjcmFzaAojIHdpdGggYSBVbmljb2Rl
  >> "!B64TMP!" echo RW5jb2RlRXJyb3IuIFNraXBwZWQgaWYgUFlUSE9OSU9FTkNPRElORyBpcyBhbHJlYWR5IHNldCDi
  >> "!B64TMP!" echo gJQKIyBhbiBleHBsaWNpdCBvdmVycmlkZSBhbHdheXMgd2lucy4KaWYgIlBZVEhPTklPRU5DT0RJ
  >> "!B64TMP!" echo TkciIG5vdCBpbiBvcy5lbnZpcm9uOgogICAgZm9yIF9zdHJlYW0gaW4gKHN5cy5zdGRvdXQsIHN5
  >> "!B64TMP!" echo cy5zdGRlcnIpOgogICAgICAgIGlmIGhhc2F0dHIoX3N0cmVhbSwgInJlY29uZmlndXJlIik6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIF9zdHJlYW0ucmVjb25maWd1cmUoZW5jb2Rp
  >> "!B64TMP!" echo bmc9InV0Zi04IikKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IHBhc3MKClZJREVPX0lEID0gcmUuY29tcGlsZShyIl5bQS1aYS16MC05Xy1dezExfSQiKQpVUkxf
  >> "!B64TMP!" echo SUQgPSByZS5jb21waWxlKHIiKD86Wz8mXXY9fHlvdXR1XC5iZS98L3Nob3J0cy98L2VtYmVkL3wv
  >> "!B64TMP!" echo bGl2ZS98L3YvKShbQS1aYS16MC05Xy1dezExfSkiKQpMQU5HID0gcmUuY29tcGlsZShyIl5bQS1a
  >> "!B64TMP!" echo YS16XXsyLDN9KD86LVtBLVphLXowLTldezIsOH0pKiQiKQpZVERMUF9USU1FT1VUID0gMTgwICAj
  >> "!B64TMP!" echo IHNlY29uZHMKCgpjbGFzcyBUcmFuc2NyaXB0RXJyb3IoRXhjZXB0aW9uKToKICAgICIiIkEgZmFp
  >> "!B64TMP!" echo bHVyZSB3aG9zZSBtZXNzYWdlIGlzIGFscmVhZHkgd3JpdHRlbiBmb3IgdGhlIGVuZCB1c2VyLiIi
  >> "!B64TMP!" echo IgoKCmRlZiB2aWRlb19pZF9mcm9tKGFyZyk6CiAgICBhcmcgPSBhcmcuc3RyaXAoKQogICAgaWYg
  >> "!B64TMP!" echo VklERU9fSUQubWF0Y2goYXJnKToKICAgICAgICByZXR1cm4gYXJnCiAgICBtID0gVVJMX0lELnNl
  >> "!B64TMP!" echo YXJjaChhcmcpCiAgICByZXR1cm4gbS5ncm91cCgxKSBpZiBtIGVsc2UgTm9uZQoKCiMgLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tIHl0LWRscApkZWYgeXRkbHBfY29tbWFuZCgpOgogICAgIiIiSG93IHRvIHJ1biB5dC1k
  >> "!B64TMP!" echo bHAsIG9yIE5vbmUgd2hlbiBpdCBpcyBub3QgaW5zdGFsbGVkLiIiIgogICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo IGltcG9ydCB5dF9kbHAgICMgbm9xYTogRjQwMQogICAgICAgIHJldHVybiBbc3lzLmV4ZWN1dGFi
  >> "!B64TMP!" echo bGUsICItbSIsICJ5dF9kbHAiXQogICAgZXhjZXB0IEltcG9ydEVycm9yOgogICAgICAgIHBhc3MK
  >> "!B64TMP!" echo ICAgIGV4ZSA9IHNodXRpbC53aGljaCgieXQtZGxwIikKICAgIHJldHVybiBbZXhlXSBpZiBleGUg
  >> "!B64TMP!" echo ZWxzZSBOb25lCgoKZGVmIGpzX3J1bnRpbWVfYXJncygpOgogICAgIiIiKGV4dHJhIHl0LWRscCBh
  >> "!B64TMP!" echo cmdzLCBhIHJ1bnRpbWUgd2FzIGZvdW5kKS4geXQtZGxwIGl0c2VsZiBvbmx5IGVuYWJsZXMgRGVu
  >> "!B64TMP!" echo by4iIiIKICAgIGlmIHNodXRpbC53aGljaCgiZGVubyIpOgogICAgICAgIHJldHVybiBbXSwgVHJ1
  >> "!B64TMP!" echo ZQogICAgZm9yIGV4ZSwgbmFtZSBpbiAoKCJub2RlIiwgIm5vZGUiKSwgKCJidW4iLCAiYnVuIiks
  >> "!B64TMP!" echo ICgicWpzIiwgInF1aWNranMiKSwKICAgICAgICAgICAgICAgICAgICAgICgicXVpY2tqcyIsICJx
  >> "!B64TMP!" echo dWlja2pzIikpOgogICAgICAgIGlmIHNodXRpbC53aGljaChleGUpOgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gWyItLWpzLXJ1bnRpbWVzIiwgbmFtZV0sIFRydWUKICAgIHJldHVybiBbXSwgRmFsc2UKCgpk
  >> "!B64TMP!" echo ZWYgcGFyc2VfanNvbjMocGF0aCk6CiAgICAiIiJZb3VUdWJlJ3MganNvbjMgY2FwdGlvbiBmaWxl
  >> "!B64TMP!" echo IC0+IFsoc3RhcnRfc2Vjb25kcywgdGV4dCksIC4uLl0uIiIiCiAgICB3aXRoIG9wZW4ocGF0aCwg
  >> "!B64TMP!" echo ZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgZGF0YSA9IGpzb24ubG9hZChmaCkKICAg
  >> "!B64TMP!" echo IG91dCA9IFtdCiAgICBmb3IgZXYgaW4gZGF0YS5nZXQoImV2ZW50cyIsIFtdKToKICAgICAgICBz
  >> "!B64TMP!" echo ZWdzID0gZXYuZ2V0KCJzZWdzIikKICAgICAgICBpZiBub3Qgc2VnczoKICAgICAgICAgICAgY29u
  >> "!B64TMP!" echo dGludWUKICAgICAgICB0ZXh0ID0gIiIuam9pbihzLmdldCgidXRmOCIsICIiKSBmb3IgcyBpbiBz
  >> "!B64TMP!" echo ZWdzKS5yZXBsYWNlKCJcbiIsICIgIikuc3RyaXAoKQogICAgICAgIGlmIHRleHQ6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIG91dC5hcHBlbmQoKChldi5nZXQoInRTdGFydE1zIikgb3IgMCkgLyAxMDAwLjAsIHRleHQp
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIG91dAoKCmRlZiBwaWNrX2ZpbGUoZmlsZXMsIGxhbmdzKToKICAgICIiIkJl
  >> "!B64TMP!" echo c3QgY2FwdGlvbiBmaWxlIGZvciB0aGUgcmVxdWVzdGVkIGxhbmd1YWdlcyAoZXhhY3QgY29kZSwg
  >> "!B64TMP!" echo dGhlbiAtb3JpZywgdGhlbiBhbnkpLiIiIgogICAgZGVmIHJhbmsocGF0aCk6CiAgICAgICAgY29k
  >> "!B64TMP!" echo ZSA9IG9zLnBhdGguYmFzZW5hbWUocGF0aCkuc3BsaXQoIi4iKVstMl0gICMgPGlkPi48bGFuZz4u
  >> "!B64TMP!" echo anNvbjMKICAgICAgICBmb3IgaSwgbGFuZyBpbiBlbnVtZXJhdGUobGFuZ3MpOgogICAgICAgICAg
  >> "!B64TMP!" echo ICBpZiBjb2RlID09IGxhbmc6CiAgICAgICAgICAgICAgICByZXR1cm4gKGksIDApCiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGlmIGNvZGUgPT0gbGFuZyArICItb3JpZyI6CiAgICAgICAgICAgICAgICByZXR1cm4gKGks
  >> "!B64TMP!" echo IDEpCiAgICAgICAgICAgIGlmIGNvZGUuc3RhcnRzd2l0aChsYW5nKToKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAoaSwgMikKICAgICAgICByZXR1cm4gKGxlbihsYW5ncyksIDMpCiAgICByZXR1cm4g
  >> "!B64TMP!" echo c29ydGVkKGZpbGVzLCBrZXk9cmFuaylbMF0KCgpkZWYgYXZhaWxhYmxlX2xhbmd1YWdlcyhjbWQs
  >> "!B64TMP!" echo IHVybCk6CiAgICAiIiJMYW5ndWFnZSBjb2RlcyB5dC1kbHAgcmVwb3J0cyBmb3IgdGhlIHZpZGVv
  >> "!B64TMP!" echo IChmb3IgdGhlICdubyBzdWNoIGxhbmd1YWdlJyBtZXNzYWdlKS4iIiIKICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY21kICsgWyItLXNraXAtZG93bmxvYWQiLCAiLS1saXN0
  >> "!B64TMP!" echo LXN1YnMiLCAiLS1uby13YXJuaW5ncyIsICItLSIsIHVybF0sCiAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRydWUsIGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0i
  >> "!B64TMP!" echo cmVwbGFjZSIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHRpbWVvdXQ9WVRETFBfVElN
  >> "!B64TMP!" echo RU9VVCkKICAgIGV4Y2VwdCAoT1NFcnJvciwgc3VicHJvY2Vzcy5TdWJwcm9jZXNzRXJyb3IpOgog
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBbXQogICAgY29kZXMgPSBbXQogICAgZm9yIGxpbmUgaW4gcHJvYy5zdGRv
  >> "!B64TMP!" echo dXQuc3BsaXRsaW5lcygpOgogICAgICAgIHBhcnRzID0gbGluZS5zcGxpdCgpCiAgICAgICAgaWYg
  >> "!B64TMP!" echo KHBhcnRzIGFuZCBub3QgbGluZS5zdGFydHN3aXRoKCgiWyIsICIgIikpIGFuZCBwYXJ0c1swXSAh
  >> "!B64TMP!" echo PSAiTGFuZ3VhZ2UiCiAgICAgICAgICAgICAgICBhbmQgcmUubWF0Y2gociJeW0EtWmEtel17Miwz
  >> "!B64TMP!" echo fSgtW0EtWmEtejAtOV0rKSokIiwgcGFydHNbMF0pCiAgICAgICAgICAgICAgICBhbmQgcGFydHNb
  >> "!B64TMP!" echo MF0gbm90IGluIGNvZGVzKToKICAgICAgICAgICAgY29kZXMuYXBwZW5kKHBhcnRzWzBdKQogICAg
  >> "!B64TMP!" echo cmV0dXJuIGNvZGVzWzoxNV0KCgpkZWYgZXhwbGFpbl95dGRscF9mYWlsdXJlKG91dHB1dCwgaGF2
  >> "!B64TMP!" echo ZV9ydW50aW1lKToKICAgIGxvdyA9IG91dHB1dC5sb3dlcigpCiAgICBpZiAic2lnbiBpbiB0byBj
  >> "!B64TMP!" echo b25maXJtIiBpbiBsb3cgb3IgIm5vdCBhIGJvdCIgaW4gbG93OgogICAgICAgIHdoeSA9ICgiWW91
  >> "!B64TMP!" echo VHViZSBhc2tlZCBmb3IgYSBzaWduLWluIC8gYm90IGNoZWNrIGZvciB0aGlzIHJlcXVlc3QuIFRo
  >> "!B64TMP!" echo aXMgaXMgY29tbW9uIGJlaGluZCBhICIKICAgICAgICAgICAgICAgIlZQTiwgcHJveHkgb3Igb24g
  >> "!B64TMP!" echo YSBkYXRhY2VudGVyIGNvbm5lY3Rpb24gLSB0cnkgYWdhaW4gbGF0ZXIgb3IgZnJvbSBhbm90aGVy
  >> "!B64TMP!" echo IG5ldHdvcmsuIikKICAgIGVsaWYgKCJqYXZhc2NyaXB0IHJ1bnRpbWUiIGluIGxvdyBvciAianMg
  >> "!B64TMP!" echo cnVudGltZSIgaW4gbG93IG9yICJuIGNoYWxsZW5nZSIgaW4gbG93CiAgICAgICAgICBvciAiY2hh
  >> "!B64TMP!" echo bGxlbmdlIHNvbHZpbmcgZmFpbGVkIiBpbiBsb3cgb3IgImVqcyIgaW4gbG93KToKICAgICAgICB3
  >> "!B64TMP!" echo aHkgPSAoInl0LWRscCBjb3VsZCBub3Qgc29sdmUgWW91VHViZSdzIEphdmFTY3JpcHQgY2hhbGxl
  >> "!B64TMP!" echo bmdlLiBJbnN0YWxsIERlbm8gb3IgTm9kZS5qcyAyMisgIgogICAgICAgICAgICAgICAiYW5kIHRo
  >> "!B64TMP!" echo ZSB5dC1kbHAtZWpzIHBhY2thZ2U6IHBpcCBpbnN0YWxsIC1VIFwieXQtZGxwW2RlZmF1bHRdXCIi
  >> "!B64TMP!" echo KQogICAgZWxpZiAicG8gdG9rZW4iIGluIGxvdyBvciAicG9fdG9rZW4iIGluIGxvdzoKICAgICAg
  >> "!B64TMP!" echo ICB3aHkgPSAiWW91VHViZSB3YW50cyBhIFBPIHRva2VuIGZvciB0aGlzIHZpZGVvIGFuZCB5dC1k
  >> "!B64TMP!" echo bHAgY291bGQgbm90IG9idGFpbiBvbmU7IHVwZGF0ZSB5dC1kbHA6IHBpcCBpbnN0YWxsIC1VIFwi
  >> "!B64TMP!" echo eXQtZGxwW2RlZmF1bHRdXCIiCiAgICBlbGlmICgicHJpdmF0ZSB2aWRlbyIgaW4gbG93IG9yICJt
  >> "!B64TMP!" echo ZW1iZXJzLW9ubHkiIGluIGxvdyBvciAibWVtYmVycyBvbmx5IiBpbiBsb3cKICAgICAgICAgIG9y
  >> "!B64TMP!" echo ICgic2lnbiBpbiIgaW4gbG93IGFuZCAiYWdlIiBpbiBsb3cpKToKICAgICAgICB3aHkgPSAiVGhl
  >> "!B64TMP!" echo IHZpZGVvIGlzIHByaXZhdGUsIG1lbWJlcnMtb25seSBvciBhZ2UtcmVzdHJpY3RlZCAtIG5vIHB1
  >> "!B64TMP!" echo YmxpYyB0cmFuc2NyaXB0IGlzIGF2YWlsYWJsZS4iCiAgICBlbGlmICJ2aWRlbyB1bmF2YWlsYWJs
  >> "!B64TMP!" echo ZSIgaW4gbG93IG9yICJ0aGlzIHZpZGVvIGlzIG5vdCBhdmFpbGFibGUiIGluIGxvdyBvciAiaGFz
  >> "!B64TMP!" echo IGJlZW4gcmVtb3ZlZCIgaW4gbG93OgogICAgICAgIHdoeSA9ICJUaGUgdmlkZW8gaXMgdW5hdmFp
  >> "!B64TMP!" echo bGFibGUgKHJlbW92ZWQsIHByaXZhdGUgb3IgcmVnaW9uLWxvY2tlZCkuIgogICAgZWxpZiAiaHR0
  >> "!B64TMP!" echo cCBlcnJvciA0MjkiIGluIGxvdyBvciAidG9vIG1hbnkgcmVxdWVzdHMiIGluIGxvdzoKICAgICAg
  >> "!B64TMP!" echo ICB3aHkgPSAiWW91VHViZSBpcyByYXRlLWxpbWl0aW5nIHRoaXMgY29ubmVjdGlvbiAoSFRUUCA0
  >> "!B64TMP!" echo MjkpLiBXYWl0IGEgd2hpbGUgYW5kIHJldHJ5LiIKICAgIGVsc2U6CiAgICAgICAgZXJycyA9IFts
  >> "!B64TMP!" echo bi5zdHJpcCgpIGZvciBsbiBpbiBvdXRwdXQuc3BsaXRsaW5lcygpIGlmICJlcnJvciIgaW4gbG4u
  >> "!B64TMP!" echo bG93ZXIoKV0KICAgICAgICB3aHkgPSBlcnJzWy0xXSBpZiBlcnJzIGVsc2UgInl0LWRscCBmaW5p
  >> "!B64TMP!" echo c2hlZCB3aXRob3V0IHdyaXRpbmcgYSB0cmFuc2NyaXB0LiIKICAgIGlmIG5vdCBoYXZlX3J1bnRp
  >> "!B64TMP!" echo bWUgYW5kICJqYXZhc2NyaXB0IiBub3QgaW4gd2h5Lmxvd2VyKCk6CiAgICAgICAgd2h5ICs9ICgi
  >> "!B64TMP!" echo IChObyBKYXZhU2NyaXB0IHJ1bnRpbWUgLSBEZW5vIG9yIE5vZGUuanMgMjIrIC0gd2FzIGZvdW5k
  >> "!B64TMP!" echo IG9uIFBBVEg7IFlvdVR1YmUgbmVlZHMgb25lIGZvciAiCiAgICAgICAgICAgICAgICAieXQtZGxw
  >> "!B64TMP!" echo IHRvIHdvcmsgcmVsaWFibHkuKSIpCiAgICByZXR1cm4gd2h5CgoKZGVmIGZldGNoX3dpdGhfeXRk
  >> "!B64TMP!" echo bHAoY21kLCB2aWRlb19pZCwgbGFuZ3MpOgogICAgdXJsID0gImh0dHBzOi8vd3d3LnlvdXR1YmUu
  >> "!B64TMP!" echo Y29tL3dhdGNoP3Y9IiArIHZpZGVvX2lkCiAgICBqc19hcmdzLCBoYXZlX3J1bnRpbWUgPSBqc19y
  >> "!B64TMP!" echo dW50aW1lX2FyZ3MoKQogICAgdG1wID0gdGVtcGZpbGUubWtkdGVtcChwcmVmaXg9ImxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaC15dC0iKQogICAgdHJ5OgogICAgICAgIGJhc2UgPSBjbWQgKyBbIi0tc2tpcC1kb3dubG9h
  >> "!B64TMP!" echo ZCIsICItLW5vLXBsYXlsaXN0IiwgIi0tbm8tcHJvZ3Jlc3MiLCAiLS1uby13YXJuaW5ncyIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAiLS13cml0ZS1zdWJzIiwgIi0td3JpdGUtYXV0by1zdWJzIiwK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICItLXN1Yi1sYW5ncyIsICIsIi5qb2luKGwgKyAiLioiIGZv
  >> "!B64TMP!" echo ciBsIGluIGxhbmdzKSwKICAgICAgICAgICAgICAgICAgICAgICItLXN1Yi1mb3JtYXQiLCAianNv
  >> "!B64TMP!" echo bjMiLAogICAgICAgICAgICAgICAgICAgICAgIi1vIiwgb3MucGF0aC5qb2luKHRtcCwgIiUoaWQp
  >> "!B64TMP!" echo cy4lKGV4dClzIildCiAgICAgICAgcHJvYyA9IE5vbmUKICAgICAgICBmb3IgZXh0cmEgaW4gKFtq
  >> "!B64TMP!" echo c19hcmdzLCBbXV0gaWYganNfYXJncyBlbHNlIFtbXV0pOgogICAgICAgICAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oYmFzZSArIGV4dHJhICsgWyItLSIsIHVy
  >> "!B64TMP!" echo bF0sIGNhcHR1cmVfb3V0cHV0PVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJyZXBsYWNlIiwgdGltZW91dD1ZVERMUF9U
  >> "!B64TMP!" echo SU1FT1VUKQogICAgICAgICAgICBleGNlcHQgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZDoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHJhaXNlIFRyYW5zY3JpcHRFcnJvcigieXQtZGxwIHRpbWVkIG91dCBhZnRl
  >> "!B64TMP!" echo ciAlZCBzLiIgJSBZVERMUF9USU1FT1VUKQogICAgICAgICAgICBleGNlcHQgT1NFcnJvciBhcyBl
  >> "!B64TMP!" echo eGM6CiAgICAgICAgICAgICAgICByYWlzZSBUcmFuc2NyaXB0RXJyb3IoImNvdWxkIG5vdCBydW4g
  >> "!B64TMP!" echo eXQtZGxwOiAlcyIgJSBleGMpCiAgICAgICAgICAgIGlmICJubyBzdWNoIG9wdGlvbjogLS1qcy1y
  >> "!B64TMP!" echo dW50aW1lcyIgbm90IGluIHByb2Muc3RkZXJyOgogICAgICAgICAgICAgICAgYnJlYWsgICMgYW4g
  >> "!B64TMP!" echo b2xkIHl0LWRscCB3aXRob3V0IC0tanMtcnVudGltZXMgaXMgcmV0cmllZCB3aXRob3V0IGl0CiAg
  >> "!B64TMP!" echo ICAgICAgZmlsZXMgPSBnbG9iLmdsb2Iob3MucGF0aC5qb2luKHRtcCwgZ2xvYi5lc2NhcGUodmlk
  >> "!B64TMP!" echo ZW9faWQpICsgIi4qLmpzb24zIikpCiAgICAgICAgaWYgbm90IGZpbGVzOgogICAgICAgICAgICBv
  >> "!B64TMP!" echo dXRwdXQgPSAocHJvYy5zdGRvdXQgb3IgIiIpICsgIlxuIiArIChwcm9jLnN0ZGVyciBvciAiIikK
  >> "!B64TMP!" echo ICAgICAgICAgICAgaWYgcHJvYy5yZXR1cm5jb2RlID09IDAgYW5kICJubyBzdWJ0aXRsZXMiIGlu
  >> "!B64TMP!" echo IG91dHB1dC5sb3dlcigpOgogICAgICAgICAgICAgICAgbGFuZ3NfZm91bmQgPSBhdmFpbGFibGVf
  >> "!B64TMP!" echo bGFuZ3VhZ2VzKGNtZCwgdXJsKQogICAgICAgICAgICAgICAgbXNnID0gInRoZSB2aWRlbyBoYXMg
  >> "!B64TMP!" echo bm8gY2FwdGlvbnMgaW46ICVzLiIgJSAiLCAiLmpvaW4obGFuZ3MpCiAgICAgICAgICAgICAgICBp
  >> "!B64TMP!" echo ZiBsYW5nc19mb3VuZDoKICAgICAgICAgICAgICAgICAgICBtc2cgKz0gIiBBdmFpbGFibGU6ICVz
  >> "!B64TMP!" echo IC0gY2hvb3NlIG9uZSB3aXRoIC0tbGFuZy4iICUgIiwgIi5qb2luKGxhbmdzX2ZvdW5kKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmFpc2UgVHJhbnNjcmlwdEVycm9yKG1zZykKICAgICAgICAgICAgcmFpc2Ug
  >> "!B64TMP!" echo VHJhbnNjcmlwdEVycm9yKGV4cGxhaW5feXRkbHBfZmFpbHVyZShvdXRwdXQsIGhhdmVfcnVudGlt
  >> "!B64TMP!" echo ZSkpCiAgICAgICAgbGluZXMgPSBwYXJzZV9qc29uMyhwaWNrX2ZpbGUoZmlsZXMsIGxhbmdzKSkK
  >> "!B64TMP!" echo ICAgICAgICBpZiBub3QgbGluZXM6CiAgICAgICAgICAgIHJhaXNlIFRyYW5zY3JpcHRFcnJvcigi
  >> "!B64TMP!" echo dGhlIGNhcHRpb24gZmlsZSB3YXMgZW1wdHkuIikKICAgICAgICByZXR1cm4gbGluZXMKICAgIGZp
  >> "!B64TMP!" echo bmFsbHk6CiAgICAgICAgc2h1dGlsLnJtdHJlZSh0bXAsIGlnbm9yZV9lcnJvcnM9VHJ1ZSkKCgoj
  >> "!B64TMP!" echo IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0geW91dHVi
  >> "!B64TMP!" echo ZS10cmFuc2NyaXB0LWFwaSAoZmFsbGJhY2spCmRlZiBmZXRjaF93aXRoX2FwaSh2aWRlb19pZCwg
  >> "!B64TMP!" echo bGFuZ3MpOgogICAgZnJvbSB5b3V0dWJlX3RyYW5zY3JpcHRfYXBpIGltcG9ydCBZb3VUdWJlVHJh
  >> "!B64TMP!" echo bnNjcmlwdEFwaSAgIyBJbXBvcnRFcnJvciBoYW5kbGVkIGJ5IGNhbGxlcgogICAgdHJhbnNjcmlw
  >> "!B64TMP!" echo dCA9IFlvdVR1YmVUcmFuc2NyaXB0QXBpKCkuZmV0Y2godmlkZW9faWQsIGxhbmd1YWdlcz1sYW5n
  >> "!B64TMP!" echo cykKICAgIHJldHVybiBbKHNlZy5zdGFydCwgc2VnLnRleHQucmVwbGFjZSgiXG4iLCAiICIpKSBm
  >> "!B64TMP!" echo b3Igc2VnIGluIHRyYW5zY3JpcHQuc25pcHBldHNdCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gbWFpbgpk
  >> "!B64TMP!" echo ZWYgcGFyc2VfYXJncyhhcmd2KToKICAgIHZpZGVvLCBsYW5ncywgaSA9IE5vbmUsIFsiZW4iXSwg
  >> "!B64TMP!" echo MAogICAgd2hpbGUgaSA8IGxlbihhcmd2KToKICAgICAgICBhID0gYXJndltpXQogICAgICAgIGlm
  >> "!B64TMP!" echo IGEgaW4gKCItLWxhbmciLCAiLS1sYW5ncyIsICItbCIpIGFuZCBpICsgMSA8IGxlbihhcmd2KToK
  >> "!B64TMP!" echo ICAgICAgICAgICAgbGFuZ3MgPSBbeC5zdHJpcCgpIGZvciB4IGluIGFyZ3ZbaSArIDFdLnNwbGl0
  >> "!B64TMP!" echo KCIsIikgaWYgeC5zdHJpcCgpXQogICAgICAgICAgICBpICs9IDIKICAgICAgICBlbGlmIGEuc3Rh
  >> "!B64TMP!" echo cnRzd2l0aCgiLS1sYW5nPSIpOgogICAgICAgICAgICBsYW5ncyA9IFt4LnN0cmlwKCkgZm9yIHgg
  >> "!B64TMP!" echo aW4gYS5zcGxpdCgiPSIsIDEpWzFdLnNwbGl0KCIsIikgaWYgeC5zdHJpcCgpXQogICAgICAgICAg
  >> "!B64TMP!" echo ICBpICs9IDEKICAgICAgICBlbGlmIHZpZGVvIGlzIE5vbmUgYW5kIG5vdCBhLnN0YXJ0c3dpdGgo
  >> "!B64TMP!" echo Ii0iKToKICAgICAgICAgICAgdmlkZW8gPSBhCiAgICAgICAgICAgIGkgKz0gMQogICAgICAgIGVs
  >> "!B64TMP!" echo c2U6CiAgICAgICAgICAgIHJldHVybiBOb25lLCBOb25lCiAgICBpZiB2aWRlbyBpcyBOb25lIG9y
  >> "!B64TMP!" echo IG5vdCBsYW5ncyBvciBub3QgYWxsKExBTkcubWF0Y2gobCkgZm9yIGwgaW4gbGFuZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBOb25lLCBOb25lCiAgICByZXR1cm4gdmlkZW8sIGxhbmdzCgoKZGVmIG1haW4o
  >> "!B64TMP!" echo YXJndj1Ob25lKToKICAgIHZpZGVvLCBsYW5ncyA9IHBhcnNlX2FyZ3Moc3lzLmFyZ3ZbMTpdIGlm
  >> "!B64TMP!" echo IGFyZ3YgaXMgTm9uZSBlbHNlIGFyZ3YpCiAgICBpZiB2aWRlbyBpcyBOb25lOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KCJ1c2FnZTogd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSA8dmlkZW9faWQgfCB5b3V0dWJl
  >> "!B64TMP!" echo IHVybD4gWy0tbGFuZyBlbixkZV0iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gMgogICAgdmlkZW9faWQgPSB2aWRlb19pZF9mcm9tKHZpZGVvKQogICAgaWYg
  >> "!B64TMP!" echo bm90IHZpZGVvX2lkOgogICAgICAgIHByaW50KCJUUkFOU0NSSVBUIEZBSUxFRDogJyVzJyBpcyBu
  >> "!B64TMP!" echo b3QgYSBZb3VUdWJlIHZpZGVvIGlkIG9yIFVSTC4iICUgdmlkZW8sIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gMgoKICAgIHByb2JsZW1zID0gW10KICAgIGxpbmVzID0gTm9uZQogICAg
  >> "!B64TMP!" echo Y21kID0geXRkbHBfY29tbWFuZCgpCiAgICBpZiBjbWQ6CiAgICAgICAgdHJ5OgogICAgICAgICAg
  >> "!B64TMP!" echo ICBsaW5lcyA9IGZldGNoX3dpdGhfeXRkbHAoY21kLCB2aWRlb19pZCwgbGFuZ3MpCiAgICAgICAg
  >> "!B64TMP!" echo ZXhjZXB0IFRyYW5zY3JpcHRFcnJvciBhcyBleGM6CiAgICAgICAgICAgIHByb2JsZW1zLmFwcGVu
  >> "!B64TMP!" echo ZCgieXQtZGxwOiAlcyIgJSBleGMpCiAgICBlbHNlOgogICAgICAgIHByb2JsZW1zLmFwcGVuZCgi
  >> "!B64TMP!" echo eXQtZGxwIGlzIG5vdCBpbnN0YWxsZWQuIikKCiAgICBpZiBsaW5lcyBpcyBOb25lOgogICAgICAg
  >> "!B64TMP!" echo IHRyeToKICAgICAgICAgICAgbGluZXMgPSBmZXRjaF93aXRoX2FwaSh2aWRlb19pZCwgbGFuZ3Mp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGlmIGNtZDoKICAgICAgICAgICAgICAgIHByaW50KCIoeXQtZGxwIGZhaWxl
  >> "!B64TMP!" echo ZCAtIHVzZWQgdGhlIHlvdXR1YmUtdHJhbnNjcmlwdC1hcGkgZmFsbGJhY2spIiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAg
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEgLSBsaWJyYXJ5IGVy
  >> "!B64TMP!" echo cm9ycyBhcmUgdXNlci1mYWNpbmcgdGV4dAogICAgICAgICAgICBuYW1lID0gdHlwZShleGMpLl9f
  >> "!B64TMP!" echo bmFtZV9fCiAgICAgICAgICAgIGhpbnQgPSAoIiAoWW91VHViZSByZXF1aXJlcyBhIFBPIHRva2Vu
  >> "!B64TMP!" echo IGZvciB0aGlzIHZpZGVvIC0gb25seSB5dC1kbHAgY2FuIHJlYWQgaXQpIgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIGlmICJQb1Rva2VuIiBpbiBuYW1lIG9yICJ4cGUiIGluIHN0cihleGMpIGVsc2UgIiIp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHByb2JsZW1zLmFwcGVuZCgieW91dHViZS10cmFuc2NyaXB0LWFwaTogJXMl
  >> "!B64TMP!" echo cyIgJSAobmFtZSwgaGludCkpCgogICAgaWYgbGluZXMgaXMgTm9uZToKICAgICAgICBwcmludCgi
  >> "!B64TMP!" echo VFJBTlNDUklQVCBGQUlMRUQgZm9yICVzOiIgJSB2aWRlb19pZCwgZmlsZT1zeXMuc3RkZXJyKQog
  >> "!B64TMP!" echo ICAgICAgIGZvciBwIGluIHByb2JsZW1zOgogICAgICAgICAgICBwcmludCgiICAtICIgKyBwLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgbm90IGNtZDoKICAgICAgICAgICAgcHJpbnQoIklu
  >> "!B64TMP!" echo c3RhbGwgdGhlIHJlbGlhYmxlIGVuZ2luZTogIHBpcCBpbnN0YWxsIC1VIFwieXQtZGxwW2RlZmF1
  >> "!B64TMP!" echo bHRdXCJcbiIKICAgICAgICAgICAgICAgICAgImFuZCBoYXZlIERlbm8gb3IgTm9kZS5qcyAyMisg
  >> "!B64TMP!" echo b24gUEFUSCAoWW91VHViZSBuZWVkcyBhIEphdmFTY3JpcHQgcnVudGltZSkuIiwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgZm9yIHN0YXJ0
  >> "!B64TMP!" echo LCB0ZXh0IGluIGxpbmVzOgogICAgICAgIG1pbnMsIHNlY3MgPSBpbnQoc3RhcnQpIC8vIDYwLCBp
  >> "!B64TMP!" echo bnQoc3RhcnQpICUgNjAKICAgICAgICBwcmludCgiWyUwMmQ6JTAyZF0gJXMiICUgKG1pbnMsIHNl
  >> "!B64TMP!" echo Y3MsIHRleHQpKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAg
  >> "!B64TMP!" echo c3lzLmV4aXQobWFpbigpKQo=
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
>> "!TARGET!\.env" echo # ---- Invisible Playwright ^(only used if COMPOSE_PROFILES=invisible above; all optional^) ----
>> "!TARGET!\.env" echo INVISIBLE_GITHUB_TOKEN=
>> "!TARGET!\.env" echo INVISIBLE_PROXY_SERVER=
>> "!TARGET!\.env" echo INVISIBLE_PROXY_USERNAME=
>> "!TARGET!\.env" echo INVISIBLE_PROXY_PASSWORD=
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
if /i "!BROWSER_ENGINE!"=="invisible" (
  echo   Building the Invisible Playwright engine image ^(first time only: ~10 min, ~2 GB^)...
  docker compose up -d --build
) else (
  docker compose up -d
)
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
