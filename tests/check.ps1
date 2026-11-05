#requires -Version 7.4
param([switch] $Desktop)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'desktop-run-core.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
$quoteFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-NativeArgument' }, $true)
. ([scriptblock]::Create($quoteFunction.Extent.Text))
if ((ConvertTo-NativeArgument '') -cne '""') { throw 'Empty argument quoting failed.' }
if ((ConvertTo-NativeArgument 'hello world') -cne '"hello world"') { throw 'Space quoting failed.' }
if ((ConvertTo-NativeArgument 'a"b') -cne '"a\"b"') { throw 'Quote escaping failed.' }
& (Join-Path $root 'desktop-run.cmd') /h
if ($LASTEXITCODE -ne 0) { throw 'Help failed.' }
if ($Desktop) {
    foreach ($mode in @('/b', '/e')) {
        & (Join-Path $root 'desktop-run.cmd') $mode cmd.exe /d /c exit 0
        if ($LASTEXITCODE -ne 0) { throw "$mode launch failed." }
    }
    & (Join-Path $root 'desktop-run.cmd') ('desktop-run-missing-' + [guid]::NewGuid().ToString('N'))
    if ($LASTEXITCODE -ne 1) { throw 'Missing target must fail.' }
    $tasks = @(Get-ScheduledTask -TaskName 'DesktopRun_*' -ErrorAction SilentlyContinue)
    if ($tasks.Count) { throw 'DesktopRun tasks remain; inspect before retrying.' }
}
Write-Output 'Checks passed.'
