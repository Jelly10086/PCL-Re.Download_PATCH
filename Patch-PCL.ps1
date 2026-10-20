[CmdletBinding()]
param(
    [string]$TargetExe,
    [string]$OutputPath,
    [string]$SourceArchive,
    [ValidateSet('release', 'snapshot')]
    [string]$Build,
    [switch]$Restore,
    [switch]$CheckOnly,
    [switch]$ListBuilds
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
$releaseUrl = 'https://raw.githubusercontent.com/Meloong-Git/PCL/6b9a50df911c9d68b69b24c979efba477fb14b67/%E6%9C%80%E6%96%B0%E6%AD%A3%E5%BC%8F%E7%89%88.zip'

# 受支持的官方构建，新增构建时追加一项：
#   OriginalHash / PatchedHash 原版与修补后的 SHA256，DeltaFile / DeltaHash 对应差分，
#   BeforeLength 原版长度，AutoDownload 表示能否从官方仓库下载原包。
$builds = @(
    [pscustomobject]@{
        Name = '正式版 2.99.0.0'
        Id = 'release'
        OriginalHash = '6b6e1260cb5a1d6a303855f1c60cab3d0bc1aebba7e40a964180188b271e7386'
        PatchedHash = 'd4fe05b8c713c573fcd46e0efa1dc9b5463f5ec4fd03c3d9279d523e48f8d0bd'
        DeltaFile = 'download.patch.gz'
        DeltaHash = '6babd1946a33e433e187683ebbef6e0910e15144e18e8d97f274e15623bc06a7'
        BeforeLength = 5980160
        AutoDownload = $true
    },
    [pscustomobject]@{
        Name = '快照版 2.99.0.0'
        Id = 'snapshot'
        OriginalHash = '5b64d6d540c376390470cea3ab99d47661e8bca81be2ba647ea83e7d2e9428fa'
        PatchedHash = '144c5cb53b657bb2e7a3768bdd8c25d521b2b1733b6c2ecbde190b7d0317bb96'
        DeltaFile = 'download-snapshot-2.99.0.0.patch.gz'
        DeltaHash = '7cfcca7542a0656403d684b20e41f65e135502f734d21f60f471a55f61cbe506'
        BeforeLength = 5985280
        AutoDownload = $false
    }
)

function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()}
    finally {$sha.Dispose()}
}

function Get-FileHashLower([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Find-Build([string]$Hash) {
    if (!$Hash) {return $null}
    foreach ($item in $builds) {
        if ($Hash -eq $item.OriginalHash -or $Hash -eq $item.PatchedHash) {return $item}
    }
    return $null
}

function Find-BuildById([string]$Id) {
    foreach ($item in $builds) {
        if ($item.Id -eq $Id) {return $item}
    }
    throw "未知的构建：$Id"
}

function Get-AutoDownloadBuild {
    foreach ($item in $builds) {
        if ($item.AutoDownload) {return $item}
    }
    throw '没有可自动下载的官方构建'
}

function Assert-NotRunning([string]$Path) {
    # 只按精确路径比对：从其他路径运行的同名 PCL 不会被发现，但那样只会让 Replace/Move 因文件被占用而失败，仍安全
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {$processPath = $process.Path} catch {continue}
        if ($processPath -and [string]::Equals($processPath, $Path, [StringComparison]::OrdinalIgnoreCase)) {
            throw '请先关闭目标 PCL，再应用补丁或恢复原版'
        }
    }
}

function Write-Atomic([string]$Path, [byte[]]$Bytes, [string]$ExpectedCurrentHash) {
    Assert-NotRunning $Path
    $directory = [IO.Path]::GetDirectoryName($Path)
    if (![IO.Directory]::Exists($directory)) {throw "输出目录不存在：$directory"}
    $tempPath = Join-Path $directory ('.pcl-patch-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {$stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true)} finally {$stream.Dispose()}
        if ([IO.File]::Exists($Path)) {
            if (!$ExpectedCurrentHash -or (Get-FileHashLower $Path) -ne $ExpectedCurrentHash) {
                throw '运行期间目标文件发生变化，已停止操作，没有替换文件'
            }
            [IO.File]::Replace($tempPath, $Path, [NullString]::Value)
        } else {
            if ($ExpectedCurrentHash) {throw '运行期间目标文件被移除，已停止操作'}
            [IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($tempPath)) {[IO.File]::Delete($tempPath)}
    }
}

function Get-OfficialBytes($TargetBuild) {
    Add-Type -AssemblyName System.IO.Compression
    $temporaryArchive = $null
    try {
        if ($SourceArchive) {
            $archivePath = (Resolve-Path -LiteralPath $SourceArchive).Path
        } elseif ($TargetBuild.AutoDownload) {
            $temporaryArchive = Join-Path ([IO.Path]::GetTempPath()) ('pcl-2.99-' + [Guid]::NewGuid().ToString('N') + '.zip')
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Host '正在下载官方 PCL 2.99.0.0 原版...'
            Invoke-WebRequest -Uri $releaseUrl -OutFile $temporaryArchive -UseBasicParsing -TimeoutSec 90
            $archivePath = $temporaryArchive
        } else {
            throw "该构建（$($TargetBuild.Name)）没有可自动下载的原包，请把本机的官方 EXE 拖到 Apply-Patch.bat 上，或使用 -TargetExe"
        }
        $stream = [IO.File]::OpenRead($archivePath)
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
            try {
                $entry = $zip.GetEntry('Plain Craft Launcher 2.exe')
                if (!$entry -or $entry.Length -ne $TargetBuild.BeforeLength) {throw '压缩包内容与支持的官方版本不符'}
                $input = $entry.Open()
                $memory = [IO.MemoryStream]::new()
                try {$input.CopyTo($memory); return ,$memory.ToArray()} finally {$input.Dispose(); $memory.Dispose()}
            } finally {$zip.Dispose()}
        } finally {$stream.Dispose()}
    } finally {
        if ($temporaryArchive -and [IO.File]::Exists($temporaryArchive)) {[IO.File]::Delete($temporaryArchive)}
    }
}

try {
    if ($ListBuilds) {
        foreach ($item in $builds) {
            Write-Host "$($item.Name)（$($item.Id)）"
            Write-Host "  原版：$($item.OriginalHash)（$($item.BeforeLength) 字节）"
            Write-Host "  修补：$($item.PatchedHash)"
            Write-Host "  差分：$($item.DeltaFile)（$($item.DeltaHash)）"
        }
        exit 0
    }

    if ($TargetExe) {
        $TargetExe = (Resolve-Path -LiteralPath $TargetExe).Path
        if ($OutputPath -and $Restore) {throw '恢复时只能指定 -TargetExe 或 -OutputPath 中的一项'}
        if (!$OutputPath) {$OutputPath = $TargetExe}
    } elseif (!$OutputPath) {
        $OutputPath = Join-Path $PSScriptRoot 'Plain Craft Launcher 2 - Download Restored.exe'
    }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    $backupPath = $OutputPath + '.pcl-original.bak'
    $currentHash = $null
    if ([IO.File]::Exists($OutputPath)) {$currentHash = Get-FileHashLower $OutputPath}

    # 选择构建：-Build 优先；其次按输出文件、目标文件的哈希识别；
    # 都没有时（例如直接双击 Apply-Patch.bat）用可自动下载的正式版。
    if ($Build) {
        $target = Find-BuildById $Build
    } else {
        $target = Find-Build $currentHash
        if (!$target -and $TargetExe) {
            $target = Find-Build (Get-FileHashLower $TargetExe)
            if (!$target) {
                $supported = ($builds | ForEach-Object {"`n  - $($_.Name)：$($_.OriginalHash)"}) -join ''
                throw "目标文件不是受支持的官方 PCL 2.99.0.0，未做任何修改。支持的原版哈希：$supported"
            }
        }
        if (!$target -and $currentHash) {throw '输出位置已有其他文件，未覆盖或修改'}
        if (!$target) {$target = Get-AutoDownloadBuild}
    }

    if ($Restore) {
        if ($currentHash -eq $target.OriginalHash) {Write-Host '当前已是官方原版，无需恢复'; exit 0}
        $restoreBuild = Find-Build $currentHash
        if (!$restoreBuild) {throw '目标文件不是本补丁生成的版本，未执行恢复'}
        if (![IO.File]::Exists($backupPath)) {throw "找不到原版备份：$backupPath"}
        [byte[]]$original = [IO.File]::ReadAllBytes($backupPath)
        if ((Get-BytesHash $original) -ne $restoreBuild.OriginalHash) {throw '原版备份的哈希不匹配，未执行恢复'}
        if ($CheckOnly) {
            Write-Host "校验通过 - 原版备份完整（$($restoreBuild.Name)），未修改任何 EXE"
        } else {
            Write-Atomic $OutputPath $original $currentHash
            Write-Host "已恢复官方 PCL 2.99.0.0（$($restoreBuild.Name)）：$OutputPath"
        }
        exit 0
    }

    # 先判断输出是否已打补丁，再读 -TargetExe：输出已补丁时直接视为完成，即使 -TargetExe 指向别的原版也不覆盖
    if ($currentHash -eq $target.PatchedHash) {Write-Host "补丁已应用，无需重复操作：$OutputPath"; exit 0}
    if ($currentHash -and $currentHash -ne $target.OriginalHash) {
        if ($Build) {throw "目标文件与 -Build 指定的构建（$($target.Name)）不匹配，未覆盖或修改"}
        throw '输出位置已有其他文件，未覆盖或修改'
    }
    if ($TargetExe) {
        [byte[]]$original = [IO.File]::ReadAllBytes($TargetExe)
    } else {
        [byte[]]$original = Get-OfficialBytes $target
    }
    if ((Get-BytesHash $original) -ne $target.OriginalHash) {
        throw "此补丁只支持已校验的官方构建（$($target.Name)），其他版本未修改"
    }

    $patchPath = Join-Path $PSScriptRoot $target.DeltaFile
    if (![IO.File]::Exists($patchPath)) {throw "缺少差分文件：$patchPath"}
    if ((Get-FileHashLower $patchPath) -ne $target.DeltaHash) {throw '补丁数据的哈希不匹配，请重新获取补丁包'}
    $input = [IO.File]::OpenRead($patchPath)
    $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
    try {$patch = $reader.ReadToEnd() | ConvertFrom-Json} finally {$reader.Dispose(); $gzip.Dispose(); $input.Dispose()}
    if ($patch.format -ne 1 -or $patch.before -ne $target.OriginalHash -or $patch.after -ne $target.PatchedHash -or $original.Length -ne $patch.beforeLength) {
        throw '补丁清单与当前版本不符，已停止操作'
    }
    $memory = [IO.MemoryStream]::new([int]$patch.afterLength)
    try {
        foreach ($operation in $patch.operations) {
            if ($operation.PSObject.Properties['copy']) {
                [int]$offset = $operation.copy[0]
                [int]$length = $operation.copy[1]
                if ($offset -lt 0 -or $length -lt 0 -or [long]$offset + $length -gt $original.Length) {throw '补丁数据的复制范围无效'}
                $memory.Write($original, $offset, $length)
            } elseif ($operation.PSObject.Properties['data']) {
                [byte[]]$data = [Convert]::FromBase64String($operation.data)
                $memory.Write($data, 0, $data.Length)
            } else {throw '补丁数据包含无效操作'}
            if ($memory.Length -gt $patch.afterLength) {throw '补丁输出大小超出预期'}
        }
        [byte[]]$output = $memory.ToArray()
    } finally {$memory.Dispose()}
    if ($output.Length -ne $patch.afterLength -or (Get-BytesHash $output) -ne $target.PatchedHash) {throw '修补后的 EXE 校验失败，未写入目标文件'}
    if ($CheckOnly) {Write-Host "校验通过 - 原版、补丁和修补结果均匹配（$($target.Name)），未修改任何 EXE"; exit 0}

    if ([IO.File]::Exists($backupPath)) {
        if ((Get-FileHashLower $backupPath) -ne $target.OriginalHash) {throw '备份位置已有其他文件，未覆盖或修改'}
    } else {
        $backup = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {$backup.Write($original, 0, $original.Length); $backup.Flush($true)} finally {$backup.Dispose()}
    }
    Write-Atomic $OutputPath $output $currentHash
    Write-Host "补丁已应用（$($target.Name)）：$OutputPath"
    Write-Host "原版备份：$backupPath"
} catch {
    [Console]::Error.WriteLine('操作失败 - ' + $_.Exception.Message)
    exit 1
}
