@echo off
setlocal

set "TARGET=tools\get-pip.py"
set "URL=https://bootstrap.pypa.io/get-pip.py"

echo ========================================
echo [SoloPy] Downloading get-pip.py
echo ========================================
echo.
echo Target: %TARGET%
echo Source: %URL%
echo.

REM Try curl first
where curl >nul 2>nul
if %errorlevel% equ 0 (
    echo Using curl...
    curl -L -o "%TARGET%" "%URL%"
    if %errorlevel% equ 0 (
        echo.
        echo [SUCCESS] Downloaded get-pip.py
        goto :check_size
    )
)

REM Fallback to PowerShell
echo Using PowerShell...
powershell -NoProfile -Command "Invoke-WebRequest -Uri '%URL%' -OutFile '%TARGET%'"
if %errorlevel% equ 0 (
    echo.
    echo [SUCCESS] Downloaded get-pip.py
    goto :check_size
)

echo.
echo [ERROR] Failed to download get-pip.py
echo.
echo Please download manually:
echo 1. Visit: %URL%
echo 2. Save to: %TARGET%
echo.
pause
exit /b 1

:check_size
for %%A in ("%TARGET%") do set SIZE=%%~zA
if %SIZE% LSS 1000000 (
    echo.
    echo [WARNING] File size is %SIZE% bytes, which seems too small
    echo Expected size: ~2MB
    echo.
    echo Please verify the download or try manual download:
    echo Visit: %URL%
    echo.
)

echo.
pause
exit /b 0
