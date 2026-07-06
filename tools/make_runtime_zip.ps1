<#
    make_runtime_zip.ps1

    Builds a spec-compliant runtime zip from an embedded-Python directory and
    stamps it (plus a shared 16-byte build id + trailer) onto one or more stub
    executables, producing the final SoloPy launcher .exe files.

    Why not [ZipFile]::CreateFromDirectory?
      On Windows that API records directory-separator characters as backslashes
      (e.g. "Lib\site-packages\"). The ZIP spec (APPNOTE 4.4.17) mandates
      forward slashes, and the miniz extractor in solopy_stub.c follows the
      spec -- so it fails to recognize such entries as directories and aborts
      first-run extraction with "cannot write runtime file"
      (ERROR_PATH_NOT_FOUND). Here we author entries by hand with '/'
      separators and proper trailing-slash directory entries.

    Parameters:
      -Runtime <dir>   Source embedded-Python runtime directory.
      -WorkDir  <dir>  Scratch directory for the intermediate zip.
      -Pairs    <str>  Semicolon-separated "stub=out" pairs, e.g.
                       "C:\a\stub.exe=C:\dist\solopy.exe;C:\a\stubw.exe=C:\dist\solopyw.exe"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Runtime,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$Pairs
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$rtFull = (Resolve-Path -LiteralPath $Runtime).Path.TrimEnd('\', '/')
$zip = Join-Path $WorkDir 'runtime.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

# --- author a spec-compliant zip (forward-slash separators) ---------------
$fs = [System.IO.File]::Create($zip)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        # Emit explicit directory entries first (with trailing '/'), then files.
        $dirs = Get-ChildItem -LiteralPath $rtFull -Recurse -Directory -Force
        foreach ($d in $dirs) {
            $rel = $d.FullName.Substring($rtFull.Length).TrimStart('\', '/').Replace('\', '/')
            if ($rel -eq '') { continue }
            [void]$archive.CreateEntry($rel + '/', [System.IO.Compression.CompressionLevel]::NoCompression)
        }

        $files = Get-ChildItem -LiteralPath $rtFull -Recurse -File -Force
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($rtFull.Length).TrimStart('\', '/').Replace('\', '/')
            $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $in = [System.IO.File]::OpenRead($f.FullName)
            try {
                $out = $entry.Open()
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $fs.Dispose()
}

# --- stamp the zip + build id + trailer onto each stub --------------------
$zb = [System.IO.File]::ReadAllBytes($zip)
$id = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($id)
$len = [System.BitConverter]::GetBytes([UInt64]$zb.Length)
$magic = [System.Text.Encoding]::ASCII.GetBytes('SOLOPY01')

foreach ($pair in $Pairs.Split(';')) {
    if ($pair.Trim() -eq '') { continue }
    $parts = $pair.Split('=', 2)
    $stub = $parts[0]
    $out = $parts[1]
    $ofs = [System.IO.File]::Create($out)
    try {
        $sb = [System.IO.File]::ReadAllBytes($stub)
        $ofs.Write($sb, 0, $sb.Length)
        $ofs.Write($zb, 0, $zb.Length)
        $ofs.Write($id, 0, 16)
        $ofs.Write($len, 0, 8)
        $ofs.Write($magic, 0, 8)
    } finally {
        $ofs.Close()
    }
    Write-Host ('[assemble] {0}  ({1} bytes)' -f $out, (Get-Item $out).Length)
}

Remove-Item -LiteralPath $zip -Force
Write-Host ('[assemble] runtime bytes: {0}' -f $zb.Length)
