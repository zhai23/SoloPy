@echo off
setlocal EnableExtensions
set "ARGS="
set "NOPAUSE=0"
:parse
if "%~1"=="" goto :run
if /I "%~1"=="--no-pause" goto :no_pause
set "ARGS=%ARGS% %1"
shift /1
goto :parse
:no_pause
set "NOPAUSE=1"
shift /1
goto :parse
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %ARGS%
set "RESULT=%ERRORLEVEL%"
if "%NOPAUSE%"=="0" pause
exit /b %RESULT%
