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
