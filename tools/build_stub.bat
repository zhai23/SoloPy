@echo off
REM ============================================================
REM  Build the SoloPy native launcher stubs:
REM    tools\solopy_stub.exe   (console  -> becomes solopy.exe)
REM    tools\solopyw_stub.exe  (windowed -> becomes solopyw.exe, no console)
REM
REM  Both are compiled from the same solopy_stub.c; the windowed one
REM  is a GUI-subsystem build with SOLOPY_WINDOWED defined.
REM
REM  Run this ONLY when tools\solopy_stub.c or the icon changes.
REM  The produced .exe files are committed to the repo so that
REM  build.bat itself needs no C compiler.
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
set "OUT_CONSOLE=%HERE%solopy_stub.exe"
set "OUT_WINDOWED=%HERE%solopyw_stub.exe"

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

REM --- 1) console variant -> solopy_stub.exe ---
call :compile "%OUT_CONSOLE%" "CONSOLE" "" ""
if errorlevel 1 goto :fail

REM --- 2) windowed variant -> solopyw_stub.exe (GUI subsystem, no console) ---
REM     /ENTRY:mainCRTStartup keeps our main() entry point under /SUBSYSTEM:WINDOWS.
call :compile "%OUT_WINDOWED%" "WINDOWS" "/DSOLOPY_WINDOWED" "/ENTRY:mainCRTStartup"
if errorlevel 1 goto :fail

del /q "%HERE%solopy_stub.rc" "%HERE%solopy_stub.res" 2>nul

echo [stub] Built: %OUT_CONSOLE%
for %%A in ("%OUT_CONSOLE%") do echo [stub]   size: %%~zA bytes
echo [stub] Built: %OUT_WINDOWED%
for %%A in ("%OUT_WINDOWED%") do echo [stub]   size: %%~zA bytes
exit /b 0

:compile
REM %~1 = output exe, %~2 = subsystem, %~3 = extra defines, %~4 = extra link flags
set "C_OUT=%~1"
set "C_SUB=%~2"
set "C_DEF=%~3"
set "C_LINK=%~4"
set "OBJDIR=%HERE%.stub-obj"
if exist "%OBJDIR%" rmdir /s /q "%OBJDIR%"
mkdir "%OBJDIR%"
echo [stub] Compiling %C_SUB% -> %C_OUT%
cl /nologo /O2 /Os /GS- /MT /DNDEBUG /DWIN32_LEAN_AND_MEAN %C_DEF% ^
   /Fo"%OBJDIR%\\" ^
   "%STUB_C%" "%MINIZ_C%" %RES% ^
   /link /SUBSYSTEM:%C_SUB% %C_LINK% /OUT:"%C_OUT%" ^
   kernel32.lib user32.lib
set "RC_ERR=%errorlevel%"
rmdir /s /q "%OBJDIR%" 2>nul
if not "%RC_ERR%"=="0" (
    echo [stub] Compilation FAILED - %C_SUB%
    exit /b 1
)
exit /b 0

:fail
del /q "%HERE%solopy_stub.rc" "%HERE%solopy_stub.res" 2>nul
exit /b 1
