#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Target,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [AllowEmptyCollection()]
    [string[]] $TargetArguments = @(),

    [string] $__DesktopRunPayload,
    [string] $__DesktopRunResult,
    [string] $__DesktopRunTaskName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-NativeArgument {
    param([AllowNull()][string] $Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void] $builder.Append('"')
    $backslashes = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void] $builder.Append(('\' * (($backslashes * 2) + 1)))
            [void] $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void] $builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void] $builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void] $builder.Append(('\' * ($backslashes * 2)))
    }
    [void] $builder.Append('"')
    return $builder.ToString()
}

function Show-DesktopRunUsage {
    Write-Host 'Usage: desktop-run [/Explorer|/e] <program|document|url|shortcut> [arguments...]'
    Write-Host '       desktop-run [/Bridge|/b]   <program|document|url|shortcut> [arguments...]'
    Write-Host 'Default: Bridge. Use Explorer primarily for GUI apps, documents, URLs, and shortcuts.'
    Write-Host 'Shell built-ins and pipelines require cmd.exe /c or pwsh.exe -Command.'
}

function Resolve-DesktopRunTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [string] $BaseDirectory
    )

    $pathCandidate = $Value
    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*:' -and -not [IO.Path]::IsPathRooted($Value) -and -not [string]::IsNullOrWhiteSpace($BaseDirectory)) {
        $pathCandidate = Join-Path $BaseDirectory $Value
    }

    if (Test-Path -LiteralPath $pathCandidate) {
        $item = Get-Item -LiteralPath $pathCandidate
        $workingDirectory = ''
        if (-not $item.PSIsContainer -and $item.Extension -ne '.lnk') {
            $workingDirectory = $item.DirectoryName
        }
        elseif ($item.PSIsContainer) {
            $workingDirectory = $item.Parent.FullName
        }
        return [pscustomobject]@{
            Target           = $item.FullName
            WorkingDirectory = $workingDirectory
        }
    }

    $uri = $null
    if ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) {
        if ($uri.IsFile) {
            throw "File or target not found: '$Value'."
        }

        $knownShellProtocols = @('http', 'https', 'mailto', 'shell', 'ms-settings')
        $protocolRegistered = $false
        try {
            $protocolKey = Get-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\$($uri.Scheme)" -ErrorAction Stop
            $protocolRegistered = $null -ne $protocolKey.GetValue('URL Protocol', $null)
        }
        catch {
            $protocolRegistered = $false
        }
        if ($uri.Scheme -in $knownShellProtocols -or $protocolRegistered) {
            return [pscustomobject]@{ Target = $Value; WorkingDirectory = '' }
        }
        throw "No registered handler was found for URI scheme '$($uri.Scheme)'."
    }

    if (-not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Value)) {
        $command = Get-Command -Name $Value -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $command) {
            return [pscustomobject]@{
                Target           = $command.Source
                WorkingDirectory = Split-Path -Parent $command.Source
            }
        }
    }

    if ([IO.Path]::GetFileName($Value) -eq $Value) {
        $appName = if ([string]::IsNullOrEmpty([IO.Path]::GetExtension($Value))) { "$Value.exe" } else { $Value }
        $appPathKeys = @(
            "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\$appName"
            "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\App Paths\$appName"
            "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$appName"
        )
        foreach ($keyPath in $appPathKeys) {
            try {
                $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
                $appPath = [Environment]::ExpandEnvironmentVariables([string] $key.GetValue('', ''))
                if (-not [string]::IsNullOrWhiteSpace($appPath) -and (Test-Path -LiteralPath $appPath -PathType Leaf)) {
                    $appPath = (Get-Item -LiteralPath $appPath).FullName
                    return [pscustomobject]@{
                        Target           = $appPath
                        WorkingDirectory = Split-Path -Parent $appPath
                    }
                }
            }
            catch {
                # Try the next App Paths location.
            }
        }
    }

    throw "Command or target not found: '$Value'. For shell built-ins or pipelines, use cmd.exe /c or pwsh.exe -Command."
}

function Remove-TaskQuietly {
    param([string] $TaskName)

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        return
    }
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Cleanup is deliberately idempotent; the other side may have removed it first.
    }
}

function Stop-TaskAndHelperQuietly {
    param(
        [string] $TaskName,
        [string] $CoreScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        return
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task -and $task.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
    }
    catch {
        # The child may already have removed the task.
    }

    try {
        $taskPattern = '(?i)-__DesktopRunTaskName\s+"?' + [regex]::Escape($TaskName) + '"?(?:\s|$)'
        foreach ($helper in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
            if ($helper.ProcessId -eq $PID -or [string]::IsNullOrWhiteSpace($helper.CommandLine)) {
                continue
            }
            if ($helper.CommandLine.IndexOf($CoreScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                $helper.CommandLine -match $taskPattern) {
                Stop-Process -Id $helper.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        # Process cleanup is best-effort and restricted to this exact task name.
    }

    Remove-TaskQuietly -TaskName $TaskName
}

function Release-ComObjectQuietly {
    param([AllowNull()] $ComObject)

    if ($null -eq $ComObject) {
        return
    }
    try {
        if ([Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
            [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
        }
    }
    catch {
        # The helper process is exiting anyway; COM cleanup is best-effort.
    }
}

function Remove-StaleDesktopRunArtifacts {
    param(
        [string] $TempRoot,
        [string] $CoreScriptPath
    )

    try {
        $cutoff = (Get-Date).AddMinutes(-10)
        foreach ($task in @(Get-ScheduledTask -TaskName 'DesktopRun_*' -ErrorAction SilentlyContinue)) {
            if ($task.Description -ne 'Temporary bridge used by desktop-run; safe to delete.') {
                continue
            }
            $id = $task.TaskName.Substring('DesktopRun_'.Length)
            $files = @(Get-ChildItem -LiteralPath $TempRoot -Filter "$id.*.json" -File -ErrorAction SilentlyContinue)
            $isStale = $files.Count -eq 0 -or ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime -lt $cutoff
            if ($task.State -ne 'Running' -and $isStale) {
                $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        $helperCutoff = (Get-Date).AddMinutes(-2)
        foreach ($helper in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
            if ($helper.ProcessId -eq $PID -or $helper.CreationDate -ge $helperCutoff -or
                [string]::IsNullOrWhiteSpace($helper.CommandLine) -or
                $helper.CommandLine.IndexOf($CoreScriptPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }
            $match = [regex]::Match(
                $helper.CommandLine,
                '(?i)-__DesktopRunTaskName\s+"?(DesktopRun_[0-9a-f]{32})"?(?:\s|$)'
            )
            if ($match.Success -and $null -eq (Get-ScheduledTask -TaskName $match.Groups[1].Value -ErrorAction SilentlyContinue)) {
                Stop-Process -Id $helper.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $TempRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $cutoff |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Recovery cleanup must never prevent a new launch.
    }
}

# This branch runs inside the logged-on desktop session. Bridge mode executes
# from the temporary desktop-session helper; Explorer mode delegates execution
# to the automation object hosted by the real desktop Explorer process.
if (-not [string]::IsNullOrWhiteSpace($__DesktopRunPayload)) {
    $payload = $null
    $shell = $null
    $desktopDocument = $null
    $desktopWindow = $null
    $shellWindows = $null
    $childExitCode = 0

    try {
        $payload = Get-Content -Raw -LiteralPath $__DesktopRunPayload | ConvertFrom-Json
        Remove-Item -LiteralPath $__DesktopRunPayload -Force -ErrorAction SilentlyContinue

        $actualSessionId = (Get-Process -Id $PID).SessionId
        if ($actualSessionId -ne [int] $payload.SessionId) {
            throw "Desktop bridge entered session $actualSessionId instead of $($payload.SessionId)."
        }

        # Resolve the target only after entering the interactive desktop session.
        # Relative paths remain relative to the caller's original working directory.
        $resolved = Resolve-DesktopRunTarget `
            -Value ([string] $payload.Target) `
            -BaseDirectory ([string] $payload.CallerWorkingDirectory)
        $desktopTarget = [string] $resolved.Target
        $desktopWorkingDirectory = [string] $resolved.WorkingDirectory

        if ([string] $payload.LaunchMode -eq 'Explorer') {
            # Obtain the automation object that lives in the process hosting the
            # desktop view. ShellExecute then runs inside the real Explorer process,
            # so the target naturally inherits Explorer's token and environment.
            $shellWindowsType = [Type]::GetTypeFromCLSID(
                [Guid] '9BA05972-F6A8-11CF-A442-00A0C90A8F39'
            )
            $shellWindows = [Activator]::CreateInstance($shellWindowsType)
            $desktopLocation = 0 # CSIDL_DESKTOP
            $emptyLocationRoot = $null
            $desktopWindowHandle = 0
            $desktopWindow = $shellWindows.FindWindowSW(
                [ref] $desktopLocation,
                [ref] $emptyLocationRoot,
                8, # SWC_DESKTOP
                [ref] $desktopWindowHandle,
                1  # SWFO_NEEDDISPATCH
            )
            if ($null -eq $desktopWindow -or $desktopWindowHandle -eq 0) {
                throw 'The Explorer desktop automation object was not found.'
            }
            $desktopDocument = $desktopWindow.Document
            $shell = $desktopDocument.Application
            $environmentFrom = "Explorer PID $($payload.ExplorerProcessId)"
        }
        else {
            $shell = New-Object -ComObject Shell.Application
            $environmentFrom = 'Desktop bridge process environment'
        }

        $shell.ShellExecute(
            $desktopTarget,
            [string] $payload.Arguments,
            $desktopWorkingDirectory,
            'open',
            1
        )

        [pscustomobject]@{
            Success          = $true
            SessionId        = $actualSessionId
            User             = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            Target           = $desktopTarget
            Arguments        = [string] $payload.Arguments
            WorkingDirectory = $desktopWorkingDirectory
            LaunchMode       = [string] $payload.LaunchMode
            EnvironmentFrom  = $environmentFrom
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $__DesktopRunResult -Encoding UTF8
    }
    catch {
        $childExitCode = 1
        [pscustomobject]@{
            Success = $false
            Error   = $_.Exception.Message
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $__DesktopRunResult -Encoding UTF8
    }
    finally {
        Release-ComObjectQuietly -ComObject $shell
        Release-ComObjectQuietly -ComObject $desktopDocument
        Release-ComObjectQuietly -ComObject $desktopWindow
        Release-ComObjectQuietly -ComObject $shellWindows
        Remove-TaskQuietly -TaskName $__DesktopRunTaskName
    }

    exit $childExitCode
}

if ($Target -in @('/h', '/help', '/?', '-h', '--help', 'help')) {
    Show-DesktopRunUsage
    exit 0
}

$launchMode = 'Bridge'
if ($Target -in @('/e', '/explorer', '/b', '/bridge', '--')) {
    if ($Target -in @('/e', '/explorer')) {
        $launchMode = 'Explorer'
    }
    if ($TargetArguments.Count -eq 0) {
        Write-Error "Option '$Target' requires a target."
        exit 2
    }
    $Target = [string] $TargetArguments[0]
    $TargetArguments = @($TargetArguments | Select-Object -Skip 1)
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    Show-DesktopRunUsage
    exit 2
}

$exitCode = 0
$taskName = $null
$payloadPath = $null
$resultPath = $null
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) 'desktop-run'
$callerWorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path
Remove-StaleDesktopRunArtifacts -TempRoot $tempRoot -CoreScriptPath $PSCommandPath

try {
    $explorers = @(Get-Process explorer -ErrorAction Stop |
        Where-Object { $_.SessionId -ne 0 })

    if ($explorers.Count -eq 0) {
        throw 'No logged-on Windows desktop was found. Log on to the desktop first.'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DESKTOP_RUN_SESSION_ID)) {
        $sessionId = [int] $env:DESKTOP_RUN_SESSION_ID
        $explorers = @($explorers | Where-Object SessionId -eq $sessionId)
        if ($explorers.Count -eq 0) {
            throw "No Explorer desktop exists in session $sessionId."
        }
    }
    else {
        $sessionIds = @($explorers | Select-Object -ExpandProperty SessionId -Unique)
        if ($sessionIds.Count -ne 1) {
            throw "Multiple desktop sessions were found ($($sessionIds -join ', ')). Set DESKTOP_RUN_SESSION_ID first."
        }
        $sessionId = [int] $sessionIds[0]
    }

    $desktop = $explorers | Where-Object SessionId -eq $sessionId | Select-Object -First 1
    $desktopProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($desktop.Id)"
    $desktopOwner = Invoke-CimMethod -InputObject $desktopProcess -MethodName GetOwner
    if ($desktopOwner.ReturnValue -ne 0) {
        throw "Could not determine the desktop user (WMI result $($desktopOwner.ReturnValue))."
    }
    $desktopUser = "$($desktopOwner.Domain)\$($desktopOwner.User)"

    $argumentLine = (($TargetArguments | ForEach-Object {
        ConvertTo-NativeArgument -Value $_
    }) -join ' ')

    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    Get-ChildItem -LiteralPath $tempRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-1) |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $id = [guid]::NewGuid().ToString('N')
    $taskName = "DesktopRun_$id"
    $payloadPath = Join-Path $tempRoot "$id.payload.json"
    $resultPath = Join-Path $tempRoot "$id.result.json"

    [pscustomobject]@{
        Target           = $Target
        Arguments        = $argumentLine
        CallerWorkingDirectory = $callerWorkingDirectory
        SessionId        = $sessionId
        ExplorerProcessId = [int] $desktop.Id
        LaunchMode       = $launchMode
        TaskName         = $taskName
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $payloadPath -Encoding UTF8

    $desktopPowerShell = (Get-Process -Id $PID).Path
    $actionArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-STA'
        '-NonInteractive'
        '-ExecutionPolicy'
        'Bypass'
        '-WindowStyle'
        'Hidden'
        '-File'
        $PSCommandPath
        '-__DesktopRunPayload'
        $payloadPath
        '-__DesktopRunResult'
        $resultPath
        '-__DesktopRunTaskName'
        $taskName
    ) | ForEach-Object { ConvertTo-NativeArgument -Value $_ }

    $action = New-ScheduledTaskAction `
        -Execute $desktopPowerShell `
        -Argument ($actionArguments -join ' ') `
        -WorkingDirectory (Split-Path -Parent $PSCommandPath)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $desktopUser `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Description 'Temporary bridge used by desktop-run; safe to delete.' | Out-Null

    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-Path -LiteralPath $resultPath)) {
        $lastResult = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
        throw "The desktop bridge timed out. Task result: $lastResult"
    }

    $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    if (-not [bool] $result.Success) {
        throw [string] $result.Error
    }

    Write-Output "Started via $($result.LaunchMode) in desktop session $($result.SessionId) as $($result.User): $($result.Target)"
    if ($env:DESKTOP_RUN_DEBUG -eq '1') {
        Write-Output "Arguments: $($result.Arguments)"
        Write-Output "Working directory: $($result.WorkingDirectory)"
        Write-Output "Environment: $($result.EnvironmentFrom)"
    }
}
catch {
    $exitCode = 1
    [Console]::Error.WriteLine("desktop-run: $($_.Exception.Message)")
}
finally {
    Stop-TaskAndHelperQuietly -TaskName $taskName -CoreScriptPath $PSCommandPath
    foreach ($path in @($payloadPath, $resultPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $tempRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $exitCode
