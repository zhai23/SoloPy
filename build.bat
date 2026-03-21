@echo off
setlocal EnableExtensions

REM ========== SoloPy Build Configuration ==========
REM Python version used for both build environment and bundled runtime
set "PYTHON_VERSION=3.11.9"

REM Target architecture: amd64, win32, or arm64
set "PYTHON_ARCH=amd64"

REM Output executable name
set "EXE_NAME=solopy"

REM Use Tsinghua mirror (1=Yes, 0=Official)
set "USE_TSINGHUA=1"
REM ================================================

goto :main

:download_embed
set "REQ_VERSION=%~1"
set "REQ_ZIP=%~2"
if exist "%REQ_ZIP%" (
    echo [cache] Reusing %REQ_ZIP%
    goto :eof
)
set "REQ_URL=%PYTHON_MIRROR%/%REQ_VERSION%/python-%REQ_VERSION%-embed-%PYTHON_ARCH%.zip"
echo [download] %REQ_URL%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%REQ_URL%' -OutFile '%REQ_ZIP%'"
if errorlevel 1 set "FAIL_MSG=Failed to download embedded Python %REQ_VERSION%" & goto :fail
goto :eof

:extract_embed
set "ZIP_PATH=%~1"
set "DEST_DIR=%~2"
if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%"
mkdir "%DEST_DIR%"
echo [extract] %ZIP_PATH%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%ZIP_PATH%' -DestinationPath '%DEST_DIR%' -Force"
if errorlevel 1 set "FAIL_MSG=Failed to extract %ZIP_PATH%" & goto :fail
goto :eof

:patch_embed_runtime
set "PATCH_DIR=%~1"
echo [patch] %PATCH_DIR%
if not exist "%PATCH_DIR%\Lib\site-packages" mkdir "%PATCH_DIR%\Lib\site-packages"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$pth = Get-ChildItem -Path '%PATCH_DIR%' -Filter 'python*._pth' | Select-Object -First 1; if (-not $pth) { throw 'python*._pth not found' }; $lines = Get-Content $pth.FullName | Where-Object { $_ -and -not $_.StartsWith('#') }; foreach ($item in @('Lib','Lib/site-packages','import site')) { if ($lines -notcontains $item) { $lines += $item } }; Set-Content -Path $pth.FullName -Value $lines -Encoding ascii"
if errorlevel 1 set "FAIL_MSG=Failed to patch runtime in %PATCH_DIR%" & goto :fail
goto :eof

:install_pip
set "PY_EXE=%~1"
echo [pip-bootstrap] %PY_EXE%
"%PY_EXE%" "%GET_PIP%" --disable-pip-version-check -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install pip with %PY_EXE%" & goto :fail
goto :eof

:install_requirements
set "PY_EXE=%~1"
set "REQ_FILE=%~2"
echo [pip-install] %REQ_FILE%
"%PY_EXE%" -m pip install --disable-pip-version-check --upgrade -r "%REQ_FILE%" -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install requirements from %REQ_FILE%" & goto :fail
goto :eof

:install_pyinstaller
set "PY_EXE=%~1"
echo [pip-install] pyinstaller
"%PY_EXE%" -m pip install --disable-pip-version-check --upgrade pyinstaller -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install pyinstaller" & goto :fail
goto :eof

:build_exe
echo [build] PyInstaller
"%BUILD_PY%" -m PyInstaller --noconfirm --clean --onefile --name "%EXE_NAME%" --distpath "%DIST_DIR%" --workpath "%BUILD_DIR%\pyi-work" --specpath "%BUILD_DIR%\pyi-spec" --add-data "%RUNTIME_PY_HOME%;py" "%RUNNER%"
if errorlevel 1 set "FAIL_MSG=PyInstaller build failed" & goto :fail
goto :eof

:smoke_test
echo [test] dist\%EXE_NAME%.exe -V
"%DIST_DIR%\%EXE_NAME%.exe" -V
if errorlevel 1 set "FAIL_MSG=Smoke test failed" & goto :fail
goto :eof

:clean_build_dir
echo [clean] %BUILD_DIR% (keep embedded Python zip cache)
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%BUILD_DIR%') { Get-ChildItem -LiteralPath '%BUILD_DIR%' -Force | Where-Object { $_.Name -notlike 'python-*-embed-*.zip' } | Remove-Item -Recurse -Force }"
if errorlevel 1 set "FAIL_MSG=Failed to clean %BUILD_DIR%" & goto :fail
goto :eof

:fail
echo.
echo ========================================
echo [SoloPy] Build FAILED
echo %FAIL_MSG%
echo ========================================
if "%NO_PAUSE%"=="0" (
    echo.
    pause
)
exit /b 1

:main

set "NO_PAUSE=0"
if /I "%~1"=="--no-pause" set "NO_PAUSE=1"

set "ROOT_DIR=%~dp0"
cd /d "%ROOT_DIR%"

set "TOOLS_DIR=%ROOT_DIR%tools"
set "BUILD_DIR=%ROOT_DIR%.build"
set "DIST_DIR=%ROOT_DIR%dist"
set "BUILD_PY_HOME=%BUILD_DIR%\py-build"
set "RUNTIME_PY_HOME=%BUILD_DIR%\py-runtime"
set "BUILD_ZIP=%BUILD_DIR%\python-%PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip"
set "RUNTIME_ZIP=%BUILD_DIR%\python-%PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip"
set "RUNTIME_REQ=%ROOT_DIR%requirements.txt"
set "GET_PIP=%TOOLS_DIR%\get-pip.py"
set "RUNNER=%TOOLS_DIR%\solopy_runner.py"
set "BUILD_PY=%BUILD_PY_HOME%\python.exe"
set "RUNTIME_PY=%RUNTIME_PY_HOME%\python.exe"
set "MIRROR_LABEL=Official"
set "PYTHON_MIRROR=https://www.python.org/ftp/python"
set "PYPI_INDEX=https://pypi.org/simple"
if "%USE_TSINGHUA%"=="1" (
    set "MIRROR_LABEL=Tsinghua"
    set "PYTHON_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/python"
    set "PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple"
)

echo ========================================
echo [SoloPy] Build Configuration
echo ========================================
echo Python version:       %PYTHON_VERSION% (%PYTHON_ARCH%)
echo Output exe:           dist\%EXE_NAME%.exe
echo Mirror source:        %MIRROR_LABEL%
echo ========================================
echo.

where powershell >nul 2>nul
if errorlevel 1 set "FAIL_MSG=PowerShell not found. Windows PowerShell is required." & goto :fail

if not exist "%RUNNER%" set "FAIL_MSG=Missing launcher: %RUNNER%" & goto :fail
if not exist "%GET_PIP%" set "FAIL_MSG=Missing tools\get-pip.py" & goto :fail
if not exist "%RUNTIME_REQ%" set "FAIL_MSG=Missing requirements.txt" & goto :fail

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

call :clean_build_dir

call :download_embed "%PYTHON_VERSION%" "%BUILD_ZIP%"
call :extract_embed "%BUILD_ZIP%" "%BUILD_PY_HOME%"
call :patch_embed_runtime "%BUILD_PY_HOME%"
call :install_pip "%BUILD_PY%"
call :install_pyinstaller "%BUILD_PY%"

call :download_embed "%PYTHON_VERSION%" "%RUNTIME_ZIP%"
call :extract_embed "%RUNTIME_ZIP%" "%RUNTIME_PY_HOME%"
call :patch_embed_runtime "%RUNTIME_PY_HOME%"
call :install_pip "%RUNTIME_PY%"
call :install_requirements "%RUNTIME_PY%" "%RUNTIME_REQ%"

call :build_exe
call :smoke_test

echo.
echo ========================================
echo [SoloPy] Build SUCCESS
echo Output: dist\%EXE_NAME%.exe
echo ========================================
goto :end

:end
if "%NO_PAUSE%"=="0" (
    echo.
    pause
)
exit /b 0
