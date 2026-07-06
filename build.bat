@echo off
setlocal EnableExtensions

REM ========== SoloPy Build Configuration ==========
REM Python version used for the bundled runtime
REM Supports exact versions like 3.12.8 or short versions like 3.12
set "PYTHON_VERSION=3.12"

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
set "RUNTIME_PY_HOME=%BUILD_DIR%\py-runtime"
set "RUNTIME_REQ=%ROOT_DIR%requirements.txt"
set "GET_PIP=%TOOLS_DIR%\get-pip.py"
set "STUB_EXE=%TOOLS_DIR%\solopy_stub.exe"
set "RUNTIME_PY=%RUNTIME_PY_HOME%\python.exe"
set "OUT_EXE=%DIST_DIR%\%EXE_NAME%.exe"

where powershell >nul 2>nul
if errorlevel 1 set "FAIL_MSG=PowerShell not found. Windows PowerShell is required." & goto :fail

if not exist "%STUB_EXE%" set "FAIL_MSG=Missing launcher stub: %STUB_EXE% (run tools\build_stub.bat once)" & goto :fail
if not exist "%GET_PIP%" set "FAIL_MSG=Missing tools\get-pip.py" & goto :fail
if not exist "%RUNTIME_REQ%" set "FAIL_MSG=Missing requirements.txt" & goto :fail

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"

call :resolve_python_version "%PYTHON_VERSION%"
if errorlevel 1 goto :end

set "RUNTIME_ZIP=%BUILD_DIR%\python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip"

echo ========================================
echo [SoloPy] Build Configuration
echo ========================================
echo Python version:       %PYTHON_VERSION% (%PYTHON_ARCH%)
if /I not "%RESOLVED_PYTHON_VERSION%"=="%PYTHON_VERSION%" echo Resolved version:     %RESOLVED_PYTHON_VERSION%
echo Output exe:           dist\%EXE_NAME%.exe
echo Launcher stub:        %STUB_EXE%
echo Mirror source:        %MIRROR_LABEL%
echo ========================================
echo.

call :clean_build_dir
if errorlevel 1 goto :end

if exist "%RUNTIME_ZIP%" (
    echo [cache] Reusing %RUNTIME_ZIP%
) else (
    echo [download] %PYTHON_MIRROR%/%RESOLVED_PYTHON_VERSION%/python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%PYTHON_MIRROR%/%RESOLVED_PYTHON_VERSION%/python-%RESOLVED_PYTHON_VERSION%-embed-%PYTHON_ARCH%.zip' -OutFile '%RUNTIME_ZIP%'"
    if errorlevel 1 set "FAIL_MSG=Failed to download embedded Python %RESOLVED_PYTHON_VERSION%" & goto :fail
)

call :extract_embed "%RUNTIME_ZIP%" "%RUNTIME_PY_HOME%"
if errorlevel 1 goto :end
call :patch_embed_runtime "%RUNTIME_PY_HOME%"
if errorlevel 1 goto :end
call :install_pip "%RUNTIME_PY%"
if errorlevel 1 goto :end
call :install_requirements "%RUNTIME_PY%" "%RUNTIME_REQ%"
if errorlevel 1 goto :end
call :prune_runtime "%RUNTIME_PY_HOME%"
if errorlevel 1 goto :end

call :assemble_exe
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

:prune_runtime
REM Trim build-only artefacts to shrink the runtime that ships inside the exe.
REM This lowers the one-time first-run extraction cost. Everything removed here
REM is only needed while installing packages, never at runtime.
set "PRUNE_DIR=%~1"
echo [prune] %PRUNE_DIR%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$root = '%PRUNE_DIR%'; $sp = Join-Path $root 'Lib\site-packages'; $targets = @('pip','pip-*.dist-info','setuptools','setuptools-*.dist-info','pkg_resources','wheel','wheel-*.dist-info','_distutils_hack'); foreach ($t in $targets) { Get-ChildItem -Path $sp -Filter $t -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }; Get-ChildItem -Path $root -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue"
if errorlevel 1 set "FAIL_MSG=Failed to prune runtime in %PRUNE_DIR%" & goto :fail
exit /b 0

:assemble_exe
echo [assemble] %OUT_EXE%
if exist "%OUT_EXE%" del /q "%OUT_EXE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $rt='%RUNTIME_PY_HOME%'; $stub='%STUB_EXE%'; $out='%OUT_EXE%'; $work='%BUILD_DIR%'; $zip=Join-Path $work 'runtime.zip'; if (Test-Path $zip) { Remove-Item $zip -Force }; Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::CreateFromDirectory($rt,$zip,[System.IO.Compression.CompressionLevel]::Optimal,$false); $fs=[System.IO.File]::Create($out); try { $sb=[System.IO.File]::ReadAllBytes($stub); $fs.Write($sb,0,$sb.Length); $zb=[System.IO.File]::ReadAllBytes($zip); $fs.Write($zb,0,$zb.Length); $id=New-Object byte[] 16; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($id); $fs.Write($id,0,16); $len=[System.BitConverter]::GetBytes([UInt64]$zb.Length); $fs.Write($len,0,8); $magic=[System.Text.Encoding]::ASCII.GetBytes('SOLOPY01'); $fs.Write($magic,0,8) } finally { $fs.Close() }; Remove-Item $zip -Force; Write-Host ('[assemble] runtime bytes: {0}' -f $zb.Length); Write-Host ('[assemble] exe bytes:     {0}' -f (Get-Item $out).Length)"
if errorlevel 1 set "FAIL_MSG=Failed to assemble %OUT_EXE%" & goto :fail
exit /b 0

:smoke_test
echo [test] dist\%EXE_NAME%.exe -V (first run performs one-time extraction)
"%OUT_EXE%" -V
if errorlevel 1 set "FAIL_MSG=Smoke test failed" & goto :fail
echo [test] dist\%EXE_NAME%.exe -c import check
"%OUT_EXE%" -c "import fastapi, uvicorn, httpx, pydantic, pydantic_settings; print('[test] deps ok')"
if errorlevel 1 set "FAIL_MSG=Dependency import smoke test failed" & goto :fail
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
