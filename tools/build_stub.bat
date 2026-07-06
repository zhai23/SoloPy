@echo off
REM ============================================================
REM  Build the SoloPy native launcher stub (tools\solopy_stub.exe)
REM
REM  Run this ONLY when tools\solopy_stub.c or the icon changes.
REM  The produced tools\solopy_stub.exe is committed to the repo so
REM  that build.bat itself needs no C compiler.
REM
REM  Requires: Visual Studio 2022 (any edition with the C++ workload)
REM            or the Visual C++ Build Tools.
REM ============================================================
setlocal EnableExtensions

set "HERE=%~dp0"
set "STUB_C=%HERE%solopy_stub.c"
set "MINIZ_C=%HERE%vendor\miniz.c"
set "ICON=%HERE%solopy.ico"
set "RC=%HERE%solopy_stub.rc"
set "OUT=%HERE%solopy_stub.exe"

REM --- locate a Visual Studio / Build Tools installation ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo [stub] vswhere.exe not found. Install Visual Studio 2022 with the C++ workload.
    exit /b 1
)

for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH (
    echo [stub] No VC++ toolset found. Install the "Desktop development with C++" workload.
    exit /b 1
)

set "VCVARS=%VSPATH%\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo [stub] vcvars64.bat not found at "%VCVARS%".
    exit /b 1
)

echo [stub] Using toolset: %VSPATH%
call "%VCVARS%" >nul
if errorlevel 1 (
    echo [stub] Failed to initialise MSVC environment.
    exit /b 1
)

REM --- generate a resource script for the icon (optional) ---
set "RES="
if exist "%ICON%" (
    > "%RC%" echo 1 ICON "%ICON:\=\\%"
    rc /nologo /fo "%HERE%solopy_stub.res" "%RC%" >nul 2>nul
    if exist "%HERE%solopy_stub.res" set "RES=%HERE%solopy_stub.res"
)

set "OBJDIR=%HERE%.stub-obj"
if exist "%OBJDIR%" rmdir /s /q "%OBJDIR%"
mkdir "%OBJDIR%"

echo [stub] Compiling...
cl /nologo /O2 /Os /GS- /MT /DNDEBUG /DWIN32_LEAN_AND_MEAN ^
   /Fo"%OBJDIR%\\" ^
   "%STUB_C%" "%MINIZ_C%" %RES% ^
   /link /SUBSYSTEM:CONSOLE /OUT:"%OUT%" ^
   kernel32.lib user32.lib
if errorlevel 1 (
    echo [stub] Compilation FAILED.
    exit /b 1
)

del /q "%HERE%solopy_stub.rc" "%HERE%solopy_stub.res" 2>nul
rmdir /s /q "%OBJDIR%" 2>nul

echo [stub] Built: %OUT%
for %%A in ("%OUT%") do echo [stub] Size: %%~zA bytes
exit /b 0
