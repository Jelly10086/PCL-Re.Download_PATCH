[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$Version = 'dev',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputDirectory) {$OutputDirectory = Join-Path $root 'dist'}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$files = @('LauncherPatch.ps1', 'Launcher-Re.Download_PATCH.bat', 'Restore-Original.bat', 'README.md', 'LICENSE', 'NOTICE', 'UPSTREAM-LICENCE.txt',
    'source/LauncherPatch.cs', 'source/RestoreDownload.cs', 'source/BUILD.txt',
    'lib/Mono.Cecil.dll', 'lib/Mono.Cecil.LICENSE.txt', 'lib/PCL.Methods.gz', 'lib/PCL.Methods.json')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($file in $files) {if (![IO.File]::Exists((Join-Path $root $file))) {throw "Missing package file: $file"}}
# 在打包前使用与用户相同的编译路径验证引擎和方法数据
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'LauncherPatch.ps1') -ListLaunchers
if ($LASTEXITCODE -ne 0) {throw 'Entry point validation failed'}
Add-Type -Path (Join-Path $root 'lib/Mono.Cecil.dll')
Add-Type -Path @((Join-Path $root 'source/RestoreDownload.cs'), (Join-Path $root 'source/LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $root 'lib/Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
$archive = Join-Path $OutputDirectory "Launcher-Re.Download_PATCH-$Version.zip"
if ([IO.File]::Exists($archive)) {throw "Package already exists: $archive"}
$temporary = Join-Path $OutputDirectory ('.package-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $entry = $zip.CreateEntry($file, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $inputFile = [IO.File]::OpenRead((Join-Path $root $file))
            $outputFile = $entry.Open()
            try {$inputFile.CopyTo($outputFile)} finally {$inputFile.Dispose(); $outputFile.Dispose()}
        }
    } finally {$zip.Dispose()}
    [IO.File]::Move($temporary, $archive)
} finally {if ([IO.File]::Exists($temporary)) {[IO.File]::Delete($temporary)}}
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($archive + '.sha256', "$hash  $([IO.Path]::GetFileName($archive))`n", [Text.Encoding]::ASCII)
Write-Output "Built $archive"
