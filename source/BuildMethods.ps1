[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DonorExe,
    [Parameter(Mandatory=$true)][string]$RestrictedExe
)
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot '..\lib'
Add-Type -Path (Join-Path $lib 'Mono.Cecil.dll')
Add-Type -Path @((Join-Path $PSScriptRoot 'RestoreDownload.cs'), (Join-Path $PSScriptRoot 'LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $lib 'Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
function Get-AllTypes($roots) {
    foreach ($t in $roots) { $t; Get-AllTypes $t.NestedTypes }
}
$donorBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $DonorExe).Path)
$resolver = [LauncherAssemblyResolver]::new($donorBytes)
$parameters = [Mono.Cecil.ReaderParameters]::new()
$parameters.AssemblyResolver = $resolver
$donor = [Mono.Cecil.AssemblyDefinition]::ReadAssembly([IO.MemoryStream]::new($donorBytes), $parameters)
$restricted = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Resolve-Path -LiteralPath $RestrictedExe).Path)
try {
    $jobs = @{
        'PCL.ModModpack' = @('ModpackInstall')
        'PCL.PageDownloadInstall' = @('LoaderInit')
        'PCL.PageDownloadModify' = @('LoadInstanceFinished')
        'PCL.PageDownloadResourceDetail' = @('InitializeStackResourceVersions')
    }
    $rules = @()
    foreach ($typeName in ($jobs.Keys | Sort-Object)) {
        foreach ($m in $restricted.MainModule.GetType($typeName).Methods | Where-Object {$_.Name -in $jobs[$typeName]}) {
            $rules += [ordered]@{Method=$m.FullName; RequiresMarker=[LauncherPatchEngine]::HasDownloadRestriction($m); RestrictedFingerprint=[LauncherPatchEngine]::RestrictionFingerprint($m)}
        }
    }
    $selected = @($rules | ForEach-Object {$_.Method})
    $required = [Collections.Generic.HashSet[string]]::new([string[]][RestoreDownload]::RequiredMethods($donor.MainModule, [string[]]$selected))
    $donor.MainModule.Resources.Clear()
    foreach ($type in (Get-AllTypes $donor.MainModule.Types)) {
        foreach ($m in $type.Methods) {
            if (!$m.HasBody -or $required.Contains($m.FullName)) {continue}
            $m.Body = [Mono.Cecil.Cil.MethodBody]::new($m)
            $m.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
            $m.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Throw))
        }
    }
    $memory = [IO.MemoryStream]::new()
    try {$donor.Write($memory); $bytes=$memory.ToArray()} finally {$memory.Dispose()}
    $file = [IO.File]::Create((Join-Path $lib 'PCL.Methods.gz'))
    $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Optimal)
    try {$gzip.Write($bytes, 0, $bytes.Length)} finally {$gzip.Dispose(); $file.Dispose()}
    $manifest = [ordered]@{Format=2; FingerprintAlgorithm='restriction-il-v1'; DonorSha256=[LauncherPatchEngine]::Hash($bytes); Methods=$rules}
    [IO.File]::WriteAllText((Join-Path $lib 'PCL.Methods.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Output 'Generated PCL method data - no launcher version filter'
} finally {$donor.Dispose(); $restricted.Dispose(); $resolver.Dispose()}
