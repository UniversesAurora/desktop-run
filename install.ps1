#requires -Version 7.4
[CmdletBinding()]
param([string] $InstallDirectory = (Join-Path $env:USERPROFILE '.local\bin'))

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'desktop-run only supports Windows.' }
$destination = [IO.Path]::GetFullPath($InstallDirectory)
[IO.Directory]::CreateDirectory($destination) | Out-Null
foreach ($name in @('desktop-run.cmd', 'desktop-run-core.ps1')) {
    $source = Join-Path $PSScriptRoot $name
    $target = Join-Path $destination $name
    if ([IO.Path]::GetFullPath($source) -ne $target) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Unblock-File -LiteralPath $target
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { $_ })
if ($destination.TrimEnd('\') -notin @($entries | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $destination) -join ';'), 'User')
}
if ($destination -notin ($env:Path -split ';')) { $env:Path += ";$destination" }
Write-Output "Installed two files in $destination"
Write-Output 'Open a new terminal, then run: desktop-run /h'
