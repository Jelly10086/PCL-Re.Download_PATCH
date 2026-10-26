param(
    [Parameter(Mandatory=$true)][string]$Original,
    [Parameter(Mandatory=$true)][string]$Patched,
    [Parameter(Mandatory=$true)][string]$WorkDirectory
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Add-Type -Path (Join-Path $root 'lib/Mono.Cecil.dll')
Add-Type -Path @((Join-Path $PSScriptRoot 'RestoreDownload.cs'), (Join-Path $PSScriptRoot 'LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $root 'lib/Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
$before = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Resolve-Path -LiteralPath $Original).Path)
$after = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Resolve-Path -LiteralPath $Patched).Path)
function Types($roots) {foreach ($t in $roots) {$t; Types $t.NestedTypes}}
$rules = (Get-Content -LiteralPath (Join-Path $root 'lib/PCL.Methods.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Methods
$oldMethods = @{}
foreach ($t in (Types $before.MainModule.Types)) {foreach ($m in $t.Methods) {$oldMethods[$m.FullName] = $m}}
$expected = @($rules | Where-Object {$oldMethods.ContainsKey($_.Method) -and ((!$_.RequiresMarker -and [LauncherPatchEngine]::RestrictionFingerprint($oldMethods[$_.Method]) -eq $_.RestrictedFingerprint) -or [LauncherPatchEngine]::HasDownloadRestriction($oldMethods[$_.Method]))} | ForEach-Object {$_.Method})
$expected += [LauncherPatchEngine]::NavigationRepairs($before.MainModule)
$changed = @()
$generated = @()
$jit = @()
foreach ($t in (Types $after.MainModule.Types)) {
    foreach ($m in $t.Methods) {
        if ($oldMethods.ContainsKey($m.FullName) -and [LauncherPatchEngine]::Fingerprint($m) -ne [LauncherPatchEngine]::Fingerprint($oldMethods[$m.FullName])) {
            $changed += $m.FullName
            $jit += $m.MetadataToken.ToInt32()
        }
        if (!$oldMethods.ContainsKey($m.FullName) -and $m.HasBody) {
            $code = @($m.Body.Instructions | Where-Object {$_.OpCode -ne [Mono.Cecil.Cil.OpCodes]::Nop})
            if ($code.Count -eq 2 -and $code[0].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldnull -and $code[1].OpCode -eq [Mono.Cecil.Cil.OpCodes]::Throw) {throw "Stripped callback copied: $($m.FullName)"}
            $generated += [pscustomobject]@{Type=$t.FullName.Replace('/', '+'); Method=$m.Name}
            $jit += $m.MetadataToken.ToInt32()
        }
    }
}
if (@(Compare-Object ($expected | Sort-Object) ($changed | Sort-Object)).Count -ne 0) {throw 'Unexpected original method changes'}
foreach ($type in $after.MainModule.Types | Where-Object FullName -eq 'PCL.PageDownloadLeft') {
    foreach ($method in $type.Methods | Where-Object {$_.IsConstructor -and !$_.IsStatic}) {
        $old = $oldMethods[$method.FullName]
        $sentinel = @($old.Body.Instructions | Where-Object {$_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $_.Operand -eq 'Future application initializer'})
        if ($sentinel.Count -and !($method.Body.Instructions | Where-Object {$_.OpCode -eq [Mono.Cecil.Cil.OpCodes]::Ldstr -and $_.Operand -eq 'Future application initializer'})) {throw 'Unrelated constructor initialization was removed'}
    }
}
if ($before.MainModule.Resources.Count -ne $after.MainModule.Resources.Count) {throw 'Resource count changed'}
foreach ($r in $before.MainModule.Resources) {
    $s = $after.MainModule.Resources | Where-Object Name -eq $r.Name
    if (!$s -or [LauncherPatchEngine]::Hash($r.GetResourceData()) -ne [LauncherPatchEngine]::Hash($s.GetResourceData())) {throw "Resource changed: $($r.Name)"}
}
$testDir = Join-Path ([IO.Path]::GetFullPath($WorkDirectory)) ('jit-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDir) | Out-Null
foreach ($r in $before.MainModule.Resources | Where-Object {$_.Name.EndsWith('.resources')}) {
    $reader = [Resources.ResourceReader]::new($r.GetResourceStream())
    try {
        $entries = $reader.GetEnumerator()
        while ($entries.MoveNext()) {
            $type = ''; [byte[]]$data = $null
            $reader.GetResourceData([string]$entries.Key, [ref]$type, [ref]$data)
            if ($type -ne 'ResourceTypeCode.ByteArray' -or $data.Length -lt 6 -or $data[4] -ne 77 -or $data[5] -ne 90) {continue}
            $size = [BitConverter]::ToInt32($data,0)
            if ($size -lt 2 -or $size -gt $data.Length - 4) {throw 'Invalid dependency resource'}
            $image = New-Object byte[] $size
            [Buffer]::BlockCopy($data,4,$image,0,$size)
            try {$module = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.MemoryStream]::new($image))}
            catch {if ($_.Exception.InnerException -is [BadImageFormatException]) {continue}; throw}
            try {$name = $module.Assembly.Name.Name} finally {$module.Dispose()}
            if ($name -notmatch '^[A-Za-z0-9_.-]+$') {throw 'Invalid dependency name'}
            [IO.File]::WriteAllBytes((Join-Path $testDir ($name + '.dll')), $image)
        }
    } finally {$reader.Dispose()}
}
$before.Dispose(); $after.Dispose()
$testExe = Join-Path $testDir 'PATCH_PCL.exe'
[IO.File]::Copy((Resolve-Path -LiteralPath $Patched).Path,$testExe)
$resolve = [ResolveEventHandler]{
    param($sender,$eventArgs)
    $name = ([Reflection.AssemblyName]::new($eventArgs.Name)).Name
    $path = Join-Path $testDir ($name + '.dll')
    if ([IO.File]::Exists($path)) {return [Reflection.Assembly]::LoadFrom($path)}
    return $null
}.GetNewClosure()
[AppDomain]::CurrentDomain.add_AssemblyResolve($resolve)
try {
    $assembly = [Reflection.Assembly]::LoadFrom($testExe)
    foreach ($token in $jit) {
        $method = $assembly.ManifestModule.ResolveMethod($token)
        [Runtime.CompilerServices.RuntimeHelpers]::PrepareMethod($method.MethodHandle)
    }
    Write-Output "JIT OK - $($changed.Count) changed methods, $($generated.Count) generated callbacks and constructors"
} finally {[AppDomain]::CurrentDomain.remove_AssemblyResolve($resolve)}
Write-Output 'PASS - method scope, resources and CLR JIT'
