[CmdletBinding()]
param(
    [ValidateSet('amd64')][string]$Architecture = 'amd64',
    [string]$IndexUrl = 'https://pypi.org/simple',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
# A PowerShell 7 parent can pass its module directories through cmd.exe.
# Load the Windows PowerShell implementations rather than autoloading PS7 modules.
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -Force
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psd1" -Force
function Get-SourceHash([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -eq '.ico') { return (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
$root = $PSScriptRoot
$version = '3.12.10'
$zip = Join-Path $root ".build\python-$version-embed-$Architecture.zip"
$sha = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'
$stage = Join-Path $root ('.build\build-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $stage -Force)
$meta = Get-Content -Raw -LiteralPath (Join-Path $root 'tools\stubs.json') | ConvertFrom-Json
if ($meta.architecture -ne $Architecture -or $meta.python_abi -ne '3.12' -or $meta.format -ne 2) {
    throw 'Launcher ABI/architecture mismatch; run tools\build_stub.bat.'
}
foreach ($item in $meta.files.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $root ('tools\' + $item.Name))).Hash.ToLowerInvariant() -ne $item.Value) {
        throw "Launcher binary changed: $($item.Name). Run tools\build_stub.bat."
    }
}
foreach ($item in $meta.sources.PSObject.Properties) {
    if ((Get-SourceHash (Join-Path $root ('tools\' + $item.Name))) -ne $item.Value) {
        throw "Launcher source changed: $($item.Name). Run tools\build_stub.bat."
    }
}
if (-not (Test-Path -LiteralPath $zip)) {
    $part = Join-Path $stage 'python.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.python.org/ftp/python/$version/python-$version-embed-$Architecture.zip" -OutFile $part
    if ((Get-FileHash -LiteralPath $part).Hash.ToLowerInvariant() -ne $sha) { throw 'Python download checksum mismatch.' }
    Copy-Item -LiteralPath $part -Destination $zip
}
if ((Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -ne $sha) { throw 'Cached Python archive checksum mismatch.' }
$runtime = Join-Path $stage 'runtime'
Expand-Archive -LiteralPath $zip -DestinationPath $runtime
Copy-Item -LiteralPath (Join-Path $root 'tools\python_host.exe') -Destination (Join-Path $runtime 'python.exe') -Force
Copy-Item -LiteralPath (Join-Path $root 'tools\pythonw_host.exe') -Destination (Join-Path $runtime 'pythonw.exe') -Force
$python = Join-Path $runtime 'python.exe'
$args = @((Join-Path $root 'tools\build_runtime.py'), '--runtime', $runtime, '--index-url', $IndexUrl)
if ($SkipTests) { $args += '--skip-tests' }
& $python @args
if ($LASTEXITCODE) { throw "Build failed (exit $LASTEXITCODE). Diagnostics remain in $stage" }
Write-Host '[SoloPy] Build SUCCESS: dist\solopy.exe and dist\solopyw.exe'
