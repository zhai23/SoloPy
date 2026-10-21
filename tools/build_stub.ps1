[CmdletBinding()]
param([ValidateSet('amd64')][string]$Architecture = 'amd64')
$ErrorActionPreference = 'Stop'
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -Force
function Get-SourceHash([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -eq '.ico') { return (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root ('.build\stub-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work -Force)
$version = '3.12.10'
$source = Join-Path $root ".build\Python-$version.tgz"
$expected = '15d9c623abfd2165fe816ea1fb385d6ed8cf3c664661ab357f1782e3036a6dac'
if (-not (Test-Path -LiteralPath $source)) {
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.python.org/ftp/python/$version/Python-$version.tgz" -OutFile $source
}
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Python header archive checksum mismatch.'
}
& tar -xf $source -C $work "Python-$version/Include" "Python-$version/PC/pyconfig.h"
if ($LASTEXITCODE) { throw 'Could not extract Python headers.' }
$include = Join-Path $work "Python-$version\Include"
$pc = Join-Path $work "Python-$version\PC"
$src = Join-Path $PSScriptRoot 'solopy_stub.c'
$miniz = Join-Path $PSScriptRoot 'vendor\miniz.c'
$icon = (Join-Path $PSScriptRoot 'solopy.ico').Replace('\', '/')
$manifest = (Join-Path $PSScriptRoot 'launcher.manifest.xml').Replace('\', '/')
$rc = Join-Path $work 'launcher.rc'
@("1 ICON `"$icon`"", "1 24 `"$manifest`"") | Set-Content -LiteralPath $rc -Encoding ascii
$variants = @(
    @{ Name='solopy_stub.exe'; Gui=$false; HostOnly=$false },
    @{ Name='solopyw_stub.exe'; Gui=$true; HostOnly=$false },
    @{ Name='python_host.exe'; Gui=$false; HostOnly=$true },
    @{ Name='pythonw_host.exe'; Gui=$true; HostOnly=$true }
)
if (Get-Command gcc -ErrorAction SilentlyContinue) {
    if ((& gcc -dumpmachine) -notmatch '^x86_64.*mingw') { throw 'An amd64 MinGW-w64 compiler is required.' }
    $res = Join-Path $work 'launcher.o'
    & windres $rc -O coff -o $res
    if ($LASTEXITCODE) { throw 'Resource compilation failed.' }
    foreach ($v in $variants) {
        $args = @('-std=c11','-O2','-municode','-static','-fstack-protector-strong',
            '-Wl,--dynamicbase,--nxcompat,--no-insert-timestamp','-I', $include, '-I', $pc, $src, $res)
        if ($v.HostOnly) { $args += '-DSOLOPY_HOST_ONLY' } else { $args += $miniz }
        if ($v.Gui) { $args += @('-DSOLOPY_WINDOWED','-mwindows') }
        $args += @('-o', (Join-Path $work $v.Name))
        & gcc @args
        if ($LASTEXITCODE) { throw "Compilation failed: $($v.Name)" }
    }
} elseif (Get-Command cl -ErrorAction SilentlyContinue) {
    $res = Join-Path $work 'launcher.res'
    & rc /nologo "/fo$res" $rc
    if ($LASTEXITCODE) { throw 'Resource compilation failed.' }
    foreach ($v in $variants) {
        $args = @('/nologo','/O2','/MT','/GS','/std:c11',
            "/I$include", "/I$pc", "/Fo$work\", $src, $res)
        if ($v.HostOnly) { $args += '/DSOLOPY_HOST_ONLY' } else { $args += $miniz }
        if ($v.Gui) { $args += '/DSOLOPY_WINDOWED' }
        $args += @('/link','/DYNAMICBASE','/NXCOMPAT','/Brepro','kernel32.lib','user32.lib',
            "/OUT:$(Join-Path $work $v.Name)")
        if ($v.Gui) { $args += @('/SUBSYSTEM:WINDOWS','/ENTRY:wmainCRTStartup') }
        else { $args += '/SUBSYSTEM:CONSOLE' }
        & cl @args
        if ($LASTEXITCODE) { throw "Compilation failed: $($v.Name)" }
    }
} else { throw 'Use MinGW-w64 gcc/windres on PATH, or an x64 MSVC developer shell.' }
$hashes = @{}
foreach ($v in $variants) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $work $v.Name))
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) { throw 'Compiler produced a non-amd64 executable.' }
}
foreach ($v in $variants) {
    Copy-Item -LiteralPath (Join-Path $work $v.Name) -Destination (Join-Path $PSScriptRoot $v.Name) -Force
    $hashes[$v.Name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $v.Name)).Hash.ToLowerInvariant()
}
$inputs = @{}
foreach ($name in @('solopy_stub.c','build_stub.ps1','launcher.manifest.xml','solopy.ico','vendor/miniz.c','vendor/miniz.h')) {
    $inputs[$name] = Get-SourceHash (Join-Path $PSScriptRoot $name)
}
@{ architecture=$Architecture; python_abi='3.12'; format=2; files=$hashes; sources=$inputs } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stubs.json') -Encoding UTF8
Write-Host '[stub] Built and recorded four amd64 / CPython 3.12 executables.'
