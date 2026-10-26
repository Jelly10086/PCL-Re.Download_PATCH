param([Parameter(Mandatory=$true)][string]$Pcl, [Parameter(Mandatory=$true)][string]$OutputDirectory, [string]$LatestPcl)
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
    $rules = Get-Content (Join-Path $root 'lib/PCL.Methods.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $opcodes = @{}
    foreach ($field in [Mono.Cecil.Cil.OpCodes].GetFields()) {$op = $field.GetValue($null); $opcodes[$op.Name] = $op}
    foreach ($rule in $rules.Methods) {
        $owner = $assembly.MainModule.Types | Where-Object {$_.Methods.FullName -contains $rule.Method}
        $method = $owner.Methods | Where-Object FullName -eq $rule.Method
        $processor = $method.Body.GetILProcessor()
        $padding = @{}
        foreach ($instruction in @($method.Body.Instructions)) {
            $name = $instruction.OpCode.Name
            if ($name.EndsWith('.s') -and $opcodes.ContainsKey($name.Substring(0,$name.Length-2))) {
                $instruction.OpCode = $opcodes[$name.Substring(0,$name.Length-2)]
                if ($name -eq 'ldc.i4.s') {$instruction.Operand = [int]$instruction.Operand}
            } elseif ($name -match '^(ldloc|stloc)\.([0-3])$') {
                $instruction.OpCode = $opcodes[$Matches[1]]
                $instruction.Operand = $method.Body.Variables[[int]$Matches[2]]
            } elseif ($name -match '^ldarg\.([0-3])$') {
                $slot = [int]$Matches[1]
                $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldarg
                $instruction.Operand = if ($method.HasThis -and $slot -eq 0) {$method.Body.ThisParameter} else {$method.Parameters[$slot - [int]$method.HasThis]}
            } elseif ($name -match '^ldc\.i4\.(m1|[0-8])$') {
                $instruction.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4
                $instruction.Operand = if ($Matches[1] -eq 'm1') {-1} else {[int]$Matches[1]}
            }
            if ($instruction.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and [LauncherPatchEngine]::IsDownloadRestrictionText([string]$instruction.Operand) -and $instruction.Operand -ne '关闭下载') {
                $instruction.Operand = 'PCL 今后不再提供 Minecraft 下载，提示说明已调整'
            } elseif ([LauncherPatchEngine]::IsLogSourcePath($instruction)) {
                $instruction.Operand = 'F:\AnotherBuild\Source.vb'
            }
            $nop = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Nop)
            $processor.InsertBefore($instruction,$nop)
            $padding[$instruction] = $nop
        }
        foreach ($instruction in $method.Body.Instructions) {
            if ($instruction.Operand -is [Mono.Cecil.Cil.Instruction]) {$instruction.Operand = $padding[$instruction.Operand]}
        }
        if ([LauncherPatchEngine]::RestrictionFingerprint($method) -ne $rule.RestrictedFingerprint) {throw "Equivalent IL did not match: $($rule.Method)"}
    }
    $assembly.Write((Join-Path $OutputDirectory 'PCL-compatible.exe'))
    $method = $assembly.MainModule.GetType('PCL.ModModpack').Methods | Where-Object {$_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 0}
    $processor = $method.Body.GetILProcessor()
    $entry = $method.Body.Instructions[0]
    $processor.InsertBefore($entry, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, 'Future application behavior'))
    $writeLine = $assembly.MainModule.ImportReference([Console].GetMethod('WriteLine', [type[]]@([string])))
    $processor.InsertBefore($entry, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $writeLine))
    $assembly.Write((Join-Path $OutputDirectory 'PCL-mismatch.exe'))
} finally {$assembly.Dispose(); $resolver.Dispose()}
$file = [IO.File]::OpenRead((Join-Path $root 'lib/PCL.Methods.gz'))
$gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress)
$memory = [IO.MemoryStream]::new()
try {$gzip.CopyTo($memory); $donor=$memory.ToArray()} finally {$memory.Dispose(); $gzip.Dispose(); $file.Dispose()}
$partial = [RestoreDownload]::Run($donor, $bytes, [string[]]@('System.Void PCL.ModModpack::ModpackInstall()'))
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'PCL-partial.exe'), $partial)
if ($LatestPcl) {
    $navigation = [RestoreDownload]::Run($donor, [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $LatestPcl).Path), [string[]]$rules.Methods.Method)
    $resolver = [LauncherAssemblyResolver]::new($navigation)
    $parameters = [Mono.Cecil.ReaderParameters]::new()
    $parameters.AssemblyResolver = $resolver
    $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly([IO.MemoryStream]::new($navigation), $parameters)
    try {
        $constructor = $assembly.MainModule.GetType('PCL.PageDownloadLeft').Methods | Where-Object {$_.IsConstructor -and !$_.IsStatic -and $_.Parameters.Count -eq 0}
        $initialize = $constructor.Body.Instructions | Where-Object {$_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'InitializeComponent'}
        $message = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldstr, 'Future application initializer')
        $processor = $constructor.Body.GetILProcessor()
        $processor.InsertAfter($initialize, $message)
        $writeLine = $assembly.MainModule.ImportReference([Console].GetMethod('WriteLine', [type[]]@([string])))
        $processor.InsertAfter($message, [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $writeLine))
        $assembly.Write((Join-Path $OutputDirectory 'PCL-navigation.exe'))
    } finally {$assembly.Dispose(); $resolver.Dispose()}
}
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
