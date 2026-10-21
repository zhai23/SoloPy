@echo off
cd /d "%~dp0.."
"dist\solopy.exe" "tests\console_tool.py" %*
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
