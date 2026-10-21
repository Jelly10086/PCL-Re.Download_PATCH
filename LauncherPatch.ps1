[CmdletBinding()]
param(
    [Alias('TargetExe')][string]$TargetPath,
    [string]$OutputPath,
    [switch]$Restore,
    [switch]$CheckOnly,
    [switch]$ListLaunchers
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function File-Hash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()}
    finally {$stream.Dispose(); $sha.Dispose()}
}
function Bytes-Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()}
    finally {$sha.Dispose()}
}
function Assert-Closed([string]$Path) {
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {$p = $process.Path} catch {continue}
        if ($p -and [string]::Equals($p, $Path, [StringComparison]::OrdinalIgnoreCase)) {
            throw '请先关闭目标启动器'
        }
    }
    # Java 启动器的进程路径属于 JVM，需要同时核对 -jar 参数
    $fileName = [IO.Path]::GetFileName($Path)
    foreach ($process in (Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop)) {
        $command = $process.CommandLine
        if ($command -and $command -match '(?i)(?:^|\s)-jar\s+(?:"([^"]+)"|(\S+))') {
            $jar = $Matches[1]
            if (!$jar) {$jar = $Matches[2]}
            if ([string]::Equals($jar, $Path, [StringComparison]::OrdinalIgnoreCase) -or
                (![IO.Path]::IsPathRooted($jar) -and [string]::Equals([IO.Path]::GetFileName($jar), $fileName, [StringComparison]::OrdinalIgnoreCase))) {
                throw '请先关闭目标 Java 启动器；使用相同文件名启动的测试副本也需要关闭'
            }
        }
    }
}
function Write-Atomic([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.launcher-patch-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {$stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true)} finally {$stream.Dispose()}
        if ([IO.File]::Exists($Path)) {
            if (!$ExpectedHash -or (File-Hash $Path) -ne $ExpectedHash) {throw "运行期间文件发生变化，未替换：$Path"}
            [IO.File]::Replace($temp, $Path, [NullString]::Value)
        } else {
            if ($ExpectedHash) {throw "运行期间文件被移除：$Path"}
            [IO.File]::Move($temp, $Path)
        }
    } finally {if ([IO.File]::Exists($temp)) {[IO.File]::Delete($temp)}}
}
function Load-Engine {
    $lib = Join-Path $PSScriptRoot 'lib'
    if ((File-Hash (Join-Path $lib 'Mono.Cecil.dll')) -ne 'c41bdb9ffd3c5f6e17d2382c1012d73703e035e3f1100245fdd4e08c8dc6eb5b') {throw 'Mono.Cecil 依赖校验失败'}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -Path (Join-Path $lib 'Mono.Cecil.dll')
    if (!('LauncherPatchEngine' -as [type])) {
        Add-Type -Path @((Join-Path $PSScriptRoot 'source\RestoreDownload.cs'), (Join-Path $PSScriptRoot 'source\LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $lib 'Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
    }
    $rules = Get-Content -LiteralPath (Join-Path $lib 'PCL.Methods.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($rules.Format -ne 1) {throw 'PCL 方法数据格式无效'}
    $file = [IO.File]::OpenRead((Join-Path $lib 'PCL.Methods.gz'))
    $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress)
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = New-Object byte[] 8192
        while (($count = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $count)
            if ($memory.Length -gt 16777216) {throw 'PCL 方法数据过大'}
        }
        $script:donor = $memory.ToArray()
    } finally {$memory.Dispose(); $gzip.Dispose(); $file.Dispose()}
    if ((Bytes-Hash $script:donor) -ne $rules.DonorSha256) {throw 'PCL 方法数据校验失败'}
    $script:methodNames = [string[]]@($rules.Methods | ForEach-Object {$_.Method})
    $script:methodHashes = [string[]]@($rules.Methods | ForEach-Object {$_.RestrictedFingerprint})
}

$lock = $null
try {
    if ($PSVersionTable.PSEdition -eq 'Core') {throw '请使用 Windows PowerShell 5.1 或 BAT 入口运行'}
    Write-Host 'Launcher-Re.Download_PATCH'
    Write-Host '支持的启动器：PCL / PCL-CE / HMCL'
    Write-Host ''
    if ($ListLaunchers) {exit 0}
    if (!$TargetPath) {
        if ($CheckOnly -or $OutputPath) {throw '请指定 -TargetPath'}
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        try {
            $dialog.Title = '选择需要修补的启动器'
            $dialog.Filter = '启动器 (*.exe;*.jar;*.dll)|*.exe;*.jar;*.dll'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {Write-Host '已取消'; exit 0}
            $TargetPath = $dialog.FileName
        } finally {$dialog.Dispose()}
    }
    $TargetPath = (Resolve-Path -LiteralPath $TargetPath).Path
    if ([IO.Directory]::Exists($TargetPath)) {throw '请选择启动器文件'}
    if ($Restore -and $OutputPath) {throw '恢复时不能指定 -OutputPath'}
    if (!$OutputPath) {$OutputPath = $TargetPath}
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (![IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPath))) {throw '输出目录不存在'}
    $backupPath = $OutputPath + '.download-original.bak'
    $recordPath = $OutputPath + '.download-patch.json'
    if (!$CheckOnly) {
        $lock = [IO.FileStream]::new($OutputPath + '.download-patch.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    }
    Assert-Closed $TargetPath
    if ($OutputPath -ne $TargetPath) {Assert-Closed $OutputPath}
    [byte[]]$original = [IO.File]::ReadAllBytes($TargetPath)
    $originalHash = Bytes-Hash $original
    $currentHash = $null
    if ([IO.File]::Exists($OutputPath)) {$currentHash = File-Hash $OutputPath}
    if ($Restore) {
        if (![IO.File]::Exists($recordPath) -or ![IO.File]::Exists($backupPath)) {throw '找不到修补记录或原版备份'}
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.Format -ne 1 -or $record.OriginalHash -notmatch '^[0-9a-f]{64}$' -or $record.PatchedHash -notmatch '^[0-9a-f]{64}$') {throw '修补记录无效'}
        [byte[]]$backup = [IO.File]::ReadAllBytes($backupPath)
        if ((Bytes-Hash $backup) -ne $record.OriginalHash) {throw '原版备份校验失败'}
        if ($currentHash -eq $record.OriginalHash) {Write-Host '当前已是原版，无需恢复'; exit 0}
        if ($currentHash -ne $record.PatchedHash) {throw '目标文件已被更新或修改，未用旧备份覆盖'}
        if ($CheckOnly) {Write-Host '备份及修补记录校验通过，未修改文件'; exit 0}
        Assert-Closed $TargetPath
        Write-Atomic $OutputPath $backup $currentHash
        Write-Host "已恢复原版：$OutputPath"
        exit 0
    }
    if ($currentHash -and $currentHash -ne $originalHash) {throw '输出位置已有其他文件，未覆盖'}
    Load-Engine
    $result = [LauncherPatchEngine]::Patch($original, $script:donor, $script:methodNames, $script:methodHashes)
    Write-Host "启动器：$($result.Launcher)"
    if ($result.Status -eq 'AlreadyPatched') {Write-Host '限制入口已关闭，无需重复修补'; exit 0}
    if ($result.Status -eq 'NoRestriction') {Write-Host '未发现可修补的下载限制，未修改文件'; exit 0}
    if ($result.Status -ne 'Patched' -or $result.Changes.Length -lt 1) {throw '补丁未生成有效结果'}
    foreach ($change in $result.Changes) {Write-Host "  $change"}
    if ($CheckOnly) {Write-Host '特征匹配及修补结果回读验证通过，未修改文件'; exit 0}
    if ((File-Hash $TargetPath) -ne $originalHash) {throw '运行期间源文件发生变化，未应用补丁'}
    $patchedHash = Bytes-Hash $result.Bytes
    $recordHash = $null
    if ([IO.File]::Exists($recordPath)) {
        $oldRecord = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($oldRecord.Format -ne 1 -or $oldRecord.OriginalHash -ne $originalHash) {throw '已有其他原版的修补记录，请保留记录并使用新的文件路径'}
        $recordHash = File-Hash $recordPath
    }
    if ([IO.File]::Exists($backupPath)) {
        if ((File-Hash $backupPath) -ne $originalHash) {throw '备份位置已有其他文件，未覆盖'}
    } else {Write-Atomic $backupPath $original $null}
    $record = [ordered]@{
        Format = 1
        Launcher = $result.Launcher
        OriginalHash = $originalHash
        PatchedHash = $patchedHash
        Changes = @($result.Changes)
    }
    $recordBytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 5))
    Write-Atomic $recordPath $recordBytes $recordHash
    Assert-Closed $TargetPath
    Write-Atomic $OutputPath $result.Bytes $currentHash
    if ((File-Hash $OutputPath) -ne $patchedHash) {throw '落盘校验失败，请使用原版备份恢复'}
    Write-Host "修补完成：$OutputPath"
    Write-Host '恢复时请保留同目录的 .download-original.bak 和 .download-patch.json 文件'
} catch {
    [Console]::Error.WriteLine('操作失败 - ' + $_.Exception.Message)
    exit 1
} finally {if ($lock) {$lock.Dispose()}}
