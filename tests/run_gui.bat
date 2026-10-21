@echo off
setlocal EnableExtensions
cd /d "%~dp0.."
start "" "dist\solopyw.exe" "tests\gui_tool.py" %*
exit /b %ERRORLEVEL%
