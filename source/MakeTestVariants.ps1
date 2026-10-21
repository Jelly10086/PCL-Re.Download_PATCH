param([Parameter(Mandatory=$true)][string]$Pcl, [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Add-Type -Path (Join-Path $root 'lib/Mono.Cecil.dll')
Add-Type -Path @((Join-Path $PSScriptRoot 'RestoreDownload.cs'), (Join-Path $PSScriptRoot 'LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $root 'lib/Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Pcl).Path)
$resolver = [LauncherAssemblyResolver]::new($bytes)
$parameters = [Mono.Cecil.ReaderParameters]::new()
$parameters.AssemblyResolver = $resolver
$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly([IO.MemoryStream]::new($bytes), $parameters)
try {
    $assembly.Name.Version = [Version]::new(99,0,0,0)
    $assembly.Write((Join-Path $OutputDirectory 'PCL-version.exe'))
    $method = $assembly.MainModule.GetType('PCL.ModModpack').Methods | Where-Object {$_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 0}
    $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Nop))
    $assembly.Write((Join-Path $OutputDirectory 'PCL-mismatch.exe'))
} finally {$assembly.Dispose(); $resolver.Dispose()}
$legacyPath = Join-Path $OutputDirectory 'PCL-legacy.exe'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'LauncherPatch.ps1') -TargetPath $Pcl -OutputPath $legacyPath
if ($LASTEXITCODE -ne 0) {throw 'Legacy fixture patch failed'}
$legacyBytes = [IO.File]::ReadAllBytes($legacyPath)
$resolver = [LauncherAssemblyResolver]::new($legacyBytes)
$parameters = [Mono.Cecil.ReaderParameters]::new()
$parameters.AssemblyResolver = $resolver
$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly([IO.MemoryStream]::new($legacyBytes), $parameters)
try {
    $callback = @($assembly.MainModule.GetType('PCL.PageDownloadInstall').Methods | Where-Object {$_.Name.StartsWith('__DownloadRestore_')})
    if ($callback.Count -ne 1) {throw 'Expected one Minecraft download callback'}
    $callback[0].Body = [Mono.Cecil.Cil.MethodBody]::new($callback[0])
    $callback[0].Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
    $callback[0].Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Throw))
    $memory = [IO.MemoryStream]::new()
    try {$assembly.Write($memory); $broken = $memory.ToArray()} finally {$memory.Dispose()}
} finally {$assembly.Dispose(); $resolver.Dispose()}
[IO.File]::WriteAllBytes($legacyPath, $broken)
$recordPath = $legacyPath + '.download-patch.json'
$record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
$record.PatchedHash = [LauncherPatchEngine]::Hash($broken)
[IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
