param([Parameter(Mandatory=$true)][string]$WorkDirectory)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
Add-Type -Path (Join-Path $root 'lib/Mono.Cecil.dll')
Add-Type -Path @((Join-Path $PSScriptRoot 'RestoreDownload.cs'), (Join-Path $PSScriptRoot 'LauncherPatch.cs')) -ReferencedAssemblies @((Join-Path $root 'lib/Mono.Cecil.dll'), 'System.Core', 'System.IO.Compression')
$testDir = Join-Path ([IO.Path]::GetFullPath($WorkDirectory)) ('callbacks-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$template = @'
namespace Fixture {
    public static class Root {
        sealed class Closure {
            public static readonly Closure Instance = new Closure();
            readonly int value = VALUE;
            public int Callback() {return value;}
        }
        static int Callback() {return ANSWER;}
        public static int Run() {return Callback() + Closure.Instance.Callback();}
    }
}
'@
function Fixture([string]$Name, [int]$Value, [int]$Answer) {
    $path = Join-Path $testDir ($Name + '.dll')
    Add-Type -TypeDefinition ($template.Replace('VALUE', [string]$Value).Replace('ANSWER', [string]$Answer)) -OutputAssembly $path -OutputType Library
    $module = [Mono.Cecil.ModuleDefinition]::ReadModule($path)
    try {
        $type = $module.GetType('Fixture.Root')
        ($type.Methods | Where-Object Name -eq 'Callback').Name = '_Lambda$__0'
        $closure = $type.NestedTypes[0]
        $closure.Name = '_Closure$__0-0'
        ($closure.Methods | Where-Object Name -eq 'Callback').Name = '_Lambda$__1'
        $memory = [IO.MemoryStream]::new()
        try {$module.Write($memory); return ,$memory.ToArray()} finally {$memory.Dispose()}
    } finally {$module.Dispose()}
}
[byte[]]$donor = Fixture 'donor' 100 42
[byte[]]$target = Fixture 'target' -100 -42
$selected = [string[]]@('System.Int32 Fixture.Root::Run()')
$module = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.MemoryStream]::new($donor))
try {
    $required = [RestoreDownload]::RequiredMethods($module, $selected)
    if ($required.Count -ne 5) {throw "Incomplete callback dependency graph: $($required.Count)"}
} finally {$module.Dispose()}
[byte[]]$patched = [RestoreDownload]::Run($donor, $target, $selected)
$assembly = [Reflection.Assembly]::Load($patched)
$type = $assembly.GetType('Fixture.Root', $true)
if ($type.GetMethod('Run').Invoke($null, @()) -ne 142) {throw 'Restored callbacks did not execute donor behavior'}
$flags = [Reflection.BindingFlags]'NonPublic,Public,Static'
if ($type.GetMethod('_Lambda$__0', $flags).Invoke($null, @()) -ne -42) {throw 'Existing target callback was overwritten'}
Write-Output 'PASS - callbacks execute, closure initialization works, target name collisions preserved'
$module = [Mono.Cecil.ModuleDefinition]::ReadModule([IO.MemoryStream]::new($donor))
try {
    $method = $module.GetType('Fixture.Root').Methods | Where-Object Name -eq '_Lambda$__0'
    $method.Body = [Mono.Cecil.Cil.MethodBody]::new($method)
    $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldnull))
    $method.Body.Instructions.Add([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Throw))
    $memory = [IO.MemoryStream]::new()
    try {$module.Write($memory); $broken = $memory.ToArray()} finally {$memory.Dispose()}
} finally {$module.Dispose()}
$rejected = $false
try {[void][RestoreDownload]::Run($broken, $target, $selected)} catch {
    if ($_.Exception.ToString() -notlike '*Donor dependency was stripped*') {throw}
    $rejected = $true
}
if (!$rejected) {throw 'Stripped callback dependency was accepted'}
Write-Output 'PASS - stripped callback rejected before patch output'
