@echo off
setlocal

REM ========== SoloPy Build Configuration ==========
REM Build machine Python version (must be installed on your machine)
set "BUILD_PYTHON_VERSION=3.12"

REM Embedded Python version to package into exe
set "EMBED_PYTHON_VERSION=3.12.8"

REM Target architecture: amd64, win32, or arm64
set "PYTHON_ARCH=amd64"

REM Output executable name
set "EXE_NAME=solopy"

REM Use Tsinghua mirror (set to 0 to use official sources)
set "USE_TSINGHUA=1"
REM ================================================

set "NO_PAUSE=0"
if /I "%~1"=="--no-pause" set "NO_PAUSE=1"

set "ROOT_DIR=%~dp0"
cd /d "%ROOT_DIR%"

echo ========================================
echo [SoloPy] Build Configuration
echo ========================================
echo Build machine Python: %BUILD_PYTHON_VERSION%
echo Embedded Python:      %EMBED_PYTHON_VERSION% (%PYTHON_ARCH%)
echo Output exe:           dist\%EXE_NAME%.exe
if "%USE_TSINGHUA%"=="1" (
    echo Mirror source:        Tsinghua ^(China^)
) else (
    echo Mirror source:        Official
)
echo ========================================
echo.

REM Check if Python is available
where py >nul 2>nul
if %errorlevel% equ 0 (
    set "PYTHON_CMD=py -%BUILD_PYTHON_VERSION%"
) else (
    where python >nul 2>nul
    if %errorlevel% equ 0 (
        set "PYTHON_CMD=python"
    ) else (
        echo [ERROR] Python not found! Please install Python %BUILD_PYTHON_VERSION% first.
        if "%NO_PAUSE%"=="0" pause
        exit /b 1
    )
)

REM Build command
if "%USE_TSINGHUA%"=="1" (
    %PYTHON_CMD% tools\build_solopy.py --python-version %EMBED_PYTHON_VERSION% --arch %PYTHON_ARCH% --name %EXE_NAME% --requirements solorequirements.txt
) else (
    %PYTHON_CMD% tools\build_solopy.py --python-version %EMBED_PYTHON_VERSION% --arch %PYTHON_ARCH% --name %EXE_NAME% --requirements solorequirements.txt --no-tsinghua
)

set "EXIT_CODE=%errorlevel%"
echo.
if %EXIT_CODE% neq 0 (
    echo ========================================
    echo [SoloPy] Build FAILED ^(Exit code: %EXIT_CODE%^)
    echo ========================================
) else (
    echo ========================================
    echo [SoloPy] Build SUCCESS
    echo Output: dist\%EXE_NAME%.exe
    echo ========================================
)

if "%NO_PAUSE%"=="0" (
    echo.
    pause
)
exit /b %EXIT_CODE%
