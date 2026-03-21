@echo off
setlocal EnableExtensions

REM ========== SoloPy Build Configuration ==========
REM Python version used for both build environment and bundled runtime
REM Supports exact versions like 3.12.8 or short versions like 3.12
set "PYTHON_VERSION=3.9"

REM Target architecture: amd64, win32, or arm64
set "PYTHON_ARCH=amd64"

REM Output executable name
set "EXE_NAME=solopy"

REM Mirror display name
set "MIRROR_LABEL=Tsinghua"

REM Embedded Python download mirror
set "PYTHON_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/python"

REM PyPI index for pip/get-pip
set "PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple"
REM ================================================

set "EXIT_CODE=0"
set "NO_PAUSE=0"
if /I "%~1"=="--no-pause" set "NO_PAUSE=1"

set "ROOT_DIR=%~dp0"
cd /d "%ROOT_DIR%"

set "TOOLS_DIR=%ROOT_DIR%tools"
set "BUILD_DIR=%ROOT_DIR%.build"
set "DIST_DIR=%ROOT_DIR%dist"
set "RESOLVED_PYTHON_VERSION="
set "BUILD_PY_HOME=%BUILD_DIR%\py-build"
set "RUNTIME_PY_HOME=%BUILD_DIR%\py-runtime"
set "RUNTIME_REQ=%ROOT_DIR%requirements.txt"
set "GET_PIP=%TOOLS_DIR%\get-pip.py"
set "RUNNER=%TOOLS_DIR%\solopy_runner.py"
set "BUILD_PY=%BUILD_PY_HOME%\python.exe"
set "RUNTIME_PY=%RUNTIME_PY_HOME%\python.exe"
where powershell >nul 2>nul
if errorlevel 1 set "FAIL_MSG=PowerShell not found. Windows PowerShell is required." & goto :fail

if not exist "%RUNNER%" set "FAIL_MSG=Missing launcher: %RUNNER%" & goto :fail
if not exist "%GET_PIP%" set "FAIL_MSG=Missing tools\get-pip.py" & goto :fail
if not exist "%RUNTIME_REQ%" set "FAIL_MSG=Missing requirements.txt" & goto :fail

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

call :resolve_python_version "%PYTHON_VERSION%"
if errorlevel 1 goto :end

set "BUILD_ZIP=%BUILD_DIR%\python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip"
set "RUNTIME_ZIP=%BUILD_DIR%\python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip"

echo ========================================
echo [SoloPy] Build Configuration
echo ========================================
echo Python version:       %PYTHON_VERSION% (%PYTHON_ARCH%)
if /I not "%RESOLVED_PYTHON_VERSION%"=="%PYTHON_VERSION%" echo Resolved version:     %RESOLVED_PYTHON_VERSION%
echo Output exe:           dist\%EXE_NAME%.exe
echo Mirror source:        %MIRROR_LABEL%
echo ========================================
echo.

call :clean_build_dir
if errorlevel 1 goto :end

if exist "%BUILD_ZIP%" (
    echo [cache] Reusing %BUILD_ZIP%
) else (
    echo [download] %PYTHON_MIRROR%/%RESOLVED_PYTHON_VERSION%/python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%PYTHON_MIRROR%/%RESOLVED_PYTHON_VERSION%/python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip' -OutFile '%BUILD_ZIP%'"
    if errorlevel 1 set "FAIL_MSG=Failed to download embedded Python %RESOLVED_PYTHON_VERSION%" & goto :fail
)

call :extract_embed "%BUILD_ZIP%" "%BUILD_PY_HOME%"
if errorlevel 1 goto :end
call :patch_embed_runtime "%BUILD_PY_HOME%"
if errorlevel 1 goto :end
call :install_pip "%BUILD_PY%"
if errorlevel 1 goto :end
call :install_pyinstaller "%BUILD_PY%"
if errorlevel 1 goto :end

call :extract_embed "%RUNTIME_ZIP%" "%RUNTIME_PY_HOME%"
if errorlevel 1 goto :end
call :patch_embed_runtime "%RUNTIME_PY_HOME%"
if errorlevel 1 goto :end
call :install_pip "%RUNTIME_PY%"
if errorlevel 1 goto :end
call :install_requirements "%RUNTIME_PY%" "%RUNTIME_REQ%"
if errorlevel 1 goto :end

call :build_exe
if errorlevel 1 goto :end
call :smoke_test
if errorlevel 1 goto :end

echo.
echo ========================================
echo [SoloPy] Build SUCCESS
echo Output: dist\%EXE_NAME%.exe
echo ========================================
goto :end

:resolve_python_version
set "REQUESTED_VERSION=%~1"
set "RESOLVED_PYTHON_VERSION=%REQUESTED_VERSION%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$version = '%REQUESTED_VERSION%'; $arch = '%PYTHON_ARCH%'; $mirror = '%PYTHON_MIRROR%'; if ($version -match '^\d+\.\d+$') { $prefix = [regex]::Escape($version) + '\.\d+'; $resp = Invoke-WebRequest -Uri ($mirror + '/') -UseBasicParsing; $matches = [regex]::Matches($resp.Content, '([0-9]+\.[0-9]+\.[0-9]+)/') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match ('^' + $prefix + '$') } | Sort-Object {[version]$_} -Descending -Unique; if (-not $matches) { throw 'No matching patch version found' }; $resolved = $null; foreach ($candidate in $matches) { $zipUrl = '{0}/{1}/python-{1}-embed-{2}.zip' -f $mirror, $candidate, $arch; try { Invoke-WebRequest -Uri $zipUrl -Method Head -UseBasicParsing | Out-Null; $resolved = $candidate; break } catch {} }; if (-not $resolved) { throw 'No downloadable embed package found' }; $resolved } else { $version }" > "%BUILD_DIR%\resolved_python_version.txt"
if errorlevel 1 set "FAIL_MSG=Failed to resolve latest patch version for %REQUESTED_VERSION%" & goto :fail
set /p RESOLVED_PYTHON_VERSION=<"%BUILD_DIR%\resolved_python_version.txt"
if not defined RESOLVED_PYTHON_VERSION set "FAIL_MSG=Resolved Python version is empty" & goto :fail
exit /b 0

:extract_embed
set "ZIP_PATH=%~1"
set "DEST_DIR=%~2"
if exist "%DEST_DIR%" rmdir /s /q "%DEST_DIR%"
mkdir "%DEST_DIR%"
echo [extract] %ZIP_PATH%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%ZIP_PATH%' -DestinationPath '%DEST_DIR%' -Force"
if errorlevel 1 set "FAIL_MSG=Failed to extract %ZIP_PATH%" & goto :fail
exit /b 0

:patch_embed_runtime
set "PATCH_DIR=%~1"
echo [patch] %PATCH_DIR%
if not exist "%PATCH_DIR%\Lib\site-packages" mkdir "%PATCH_DIR%\Lib\site-packages"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$pth = Get-ChildItem -Path '%PATCH_DIR%' -Filter 'python*._pth' | Select-Object -First 1; if (-not $pth) { throw 'python*._pth not found' }; $lines = Get-Content $pth.FullName | Where-Object { $_ -and -not $_.StartsWith('#') }; foreach ($item in @('Lib','Lib/site-packages','import site')) { if ($lines -notcontains $item) { $lines += $item } }; Set-Content -Path $pth.FullName -Value $lines -Encoding ascii"
if errorlevel 1 set "FAIL_MSG=Failed to patch runtime in %PATCH_DIR%" & goto :fail
exit /b 0

:install_pip
set "PY_EXE=%~1"
echo [pip-bootstrap] %PY_EXE%
"%PY_EXE%" "%GET_PIP%" --disable-pip-version-check -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install pip with %PY_EXE%" & goto :fail
exit /b 0

:install_requirements
set "PY_EXE=%~1"
set "REQ_FILE=%~2"
echo [pip-install] %REQ_FILE%
"%PY_EXE%" -m pip install --disable-pip-version-check --upgrade -r "%REQ_FILE%" -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install requirements from %REQ_FILE%" & goto :fail
exit /b 0

:install_pyinstaller
set "PY_EXE=%~1"
echo [pip-install] pyinstaller
"%PY_EXE%" -m pip install --disable-pip-version-check --upgrade pyinstaller -i "%PYPI_INDEX%"
if errorlevel 1 set "FAIL_MSG=Failed to install pyinstaller" & goto :fail
exit /b 0

:build_exe
echo [build] PyInstaller
"%BUILD_PY%" -m PyInstaller --noconfirm --clean --onefile --name "%EXE_NAME%" --distpath "%DIST_DIR%" --workpath "%BUILD_DIR%\pyi-work" --specpath "%BUILD_DIR%\pyi-spec" --add-data "%RUNTIME_PY_HOME%;py" "%RUNNER%"
if errorlevel 1 set "FAIL_MSG=PyInstaller build failed" & goto :fail
exit /b 0

:smoke_test
echo [test] dist\%EXE_NAME%.exe -V
"%DIST_DIR%\%EXE_NAME%.exe" -V
if errorlevel 1 set "FAIL_MSG=Smoke test failed" & goto :fail
exit /b 0

:clean_build_dir
echo [clean] %BUILD_DIR% (keep embedded Python zip cache)
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Test-Path '%BUILD_DIR%') { Get-ChildItem -LiteralPath '%BUILD_DIR%' -Force | Where-Object { $_.Name -notlike 'python-*-embed-*.zip' } | Remove-Item -Recurse -Force }"
if errorlevel 1 set "FAIL_MSG=Failed to clean %BUILD_DIR%" & goto :fail
exit /b 0

:fail
set "EXIT_CODE=1"
echo.
echo ========================================
echo [SoloPy] Build FAILED
echo %FAIL_MSG%
echo ========================================

:end
if "%NO_PAUSE%"=="0" (
    echo.
    pause
)
exit /b %EXIT_CODE%
