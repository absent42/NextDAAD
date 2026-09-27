@echo off
REM Launcher only. The logic is lib\externs.ps1. Args are re-quoted and a
REM trailing \ gets a . so powershell.exe does not read \" as an escaped quote.
setlocal EnableExtensions
set "KIT=%~dp0"
set "CALLERDIR=%CD%\."
set "ARGS="
:nextarg
if "%~1"=="" goto argsdone
set "ARG=%~1"
if "%ARG:~-1%"=="\" set "ARG=%ARG%."
set ARGS=%ARGS% "%ARG%"
shift
goto nextarg
:argsdone
cd /d "%KIT%"
powershell -NoProfile -ExecutionPolicy Bypass -File "lib\externs.ps1" -BaseDir "%CALLERDIR%" %ARGS%
endlocal & exit /b %ERRORLEVEL%
