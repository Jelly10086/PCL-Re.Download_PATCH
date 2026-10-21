[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
[IO.Directory]::CreateDirectory($WorkDirectory) | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
function Download([string]$Url, [string]$Name, [string]$ExpectedHash) {
    $path = Join-Path $WorkDirectory $Name
    Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing -TimeoutSec 120
    if ($ExpectedHash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHash) {throw "Sample hash mismatch: $Name"}
    return $path
}
function Official([string]$Commit, [string]$Name, [string]$ExpectedHash) {
    $archive = Download "https://raw.githubusercontent.com/Meloong-Git/PCL/$Commit/%E6%9C%80%E6%96%B0%E6%AD%A3%E5%BC%8F%E7%89%88.zip" "$Name.zip" ''
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.GetEntry('Plain Craft Launcher 2.exe')
        if (!$entry) {throw 'Official sample entry missing'}
        $path = Join-Path $WorkDirectory "$Name.exe"
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
    } finally {$zip.Dispose()}
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ExpectedHash) {throw "Sample hash mismatch: $Name"}
    return $path
}
$pcl = Official '6b9a50df911c9d68b69b24c979efba477fb14b67' 'PCL' '6b6e1260cb5a1d6a303855f1c60cab3d0bc1aebba7e40a964180188b271e7386'
$donor = Official '5ef81e4' 'Donor' '5582952ded3b443503f66c23b810802bd20f1a3e847b54d9e09653a825859a36'
$ce = Download 'https://github.com/PCL-Community/PCL-CE/releases/download/v2.15.1/PCL2_CE_Release_x64.exe' 'PCL-CE.exe' '168bd8369d5ed4e5478942677562913330ef1d30a5193870af910bd18198050c'
$hmcl = Download 'https://github.com/HMCL-dev/HMCL/releases/download/v3.17.0.362/HMCL-3.17.0.362.exe' 'HMCL.exe' '08ba3e5435b51ad5d8d5266acb8cfac88736c4b5afb9c30f6b6455565d0f8652'
$old = Download 'https://github.com/HMCL-dev/HMCL/releases/download/v3.17.0.361/HMCL-3.17.0.361.exe' 'HMCL-before.exe' '67308a1fb935f5520a43c42efcdde42ab392a6757ebb838eeffc85d54fb34a5f'
[ordered]@{PCL=$pcl; Donor=$donor; CE=$ce; HMCL=$hmcl; OldHMCL=$old} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkDirectory 'samples.json') -Encoding UTF8
Write-Output 'Regression samples ready - launchers are not executed'
