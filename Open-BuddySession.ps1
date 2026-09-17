<#
.SYNOPSIS
Focus or reopen an existing Buddy-linked Copilot session without sending a prompt.
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][Guid]$SessionId,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'buddy.agent.json'),
    [Guid]$NativeRequestId = [Guid]::Empty,
    [switch]$FocusOnly,
    [string]$SessionTitle = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Buddy.Terminal.Core.ps1')
Initialize-BuddyTerminalNative
$configPathResolved = Resolve-BuddyPath $ConfigPath
$config = Read-BuddyAgentConfig $configPathResolved
$nativeLaunch = $NativeRequestId -ne [Guid]::Empty
if ($nativeLaunch) {
    . (Join-Path $PSScriptRoot 'Buddy.NativeTask.Core.ps1')
    $ticket = Get-BuddyNativeTicket $config $SessionId $NativeRequestId
    Assert-BuddyNativePlan $config $ticket.plan
    $SessionTitle = $ticket.plan.sessionTitle
    $paths = Get-BuddyNativePaths $config.stateDirectory $SessionId
    if ((Test-Path $paths.consumed) -or (Test-Path $paths.started)) { throw 'Native launch already consumed. Use Continue to focus without replay.' }
}
$plan = Get-BuddyTerminalPlan $config $Repository $SessionId -SessionTitle $SessionTitle -AllowNewSession:($nativeLaunch -or $FocusOnly)
if ($nativeLaunch) { Set-BuddyNativeArguments $plan $ticket.plan }
[IO.Directory]::CreateDirectory((Split-Path $plan.recordPath -Parent)) | Out-Null
$openLock = $null
try {
    $openLock = [IO.File]::Open($plan.openLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if ($nativeLaunch -or (Test-Path -LiteralPath (Join-Path $config.cliHome "session-state\$SessionId\events.jsonl"))) {
        $plan.sessionTitle = Get-BuddySessionTitle $plan.sessionTitle $Repository $config.cliHome $SessionId -Persist
        $plan.windowTitle = $plan.sessionTitle
    }
    $result = Open-BuddyTerminalCore -Plan $plan -FocusOnly:$FocusOnly -FindWindow {
        param($value) Get-BuddyTrackedWindow $value
    } -FindExternal {
        param($id) Get-BuddyExternalSessionProcesses $id
    } -FocusWindow {
        param($record) Focus-BuddyTrackedWindow $plan $record
    } -LaunchWindow {
        param($value)
        $sharedLock = $null
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            try {
                $sharedLock = [IO.File]::Open($value.sharedWindowLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                break
            } catch [IO.IOException] {
                if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $sharedLock) { throw 'Another Buddy tab is starting. Wait for it to finish, then open this session again.' }
        try {
        # An unrecognized but live Buddy host must not be duplicated.
        $probe = [IO.File]::Open($value.activeLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
        if (-not $value.allowConcurrentSessions -and -not (Test-BuddyTerminalLockAvailable $value.checkoutLockPath)) {
            throw 'This checkout became busy while another Buddy tab was starting. Finish that run or use a separate checkout; no new tab was opened.'
        }
        $shell = (Get-Command pwsh -ErrorAction Stop).Source
        $hostScript = Join-Path $PSScriptRoot 'Buddy.Terminal.Host.ps1'
        foreach ($part in @($shell, $hostScript, $Repository, $configPathResolved)) {
            if ($part -match '["\r\n]') { throw 'Invalid quoted terminal argument.' }
        }
        $commandLine = '"{0}" -NoLogo -NoProfile -File "{1}" -Repository "{2}" -SessionId {3} -ConfigPath "{4}"' -f
            $shell, $hostScript, $Repository, $SessionId, $configPathResolved
        if ($nativeLaunch) { $commandLine += ' -NativeRequestId ' + $NativeRequestId }
        $environment = @{}
        foreach ($name in @('COPILOT_HOME', 'COPILOT_DISABLE_TERMINAL_TITLE', 'NO_COLOR', 'TERM', 'COLORTERM',
            'FORCE_COLOR', 'CLICOLOR', 'CLICOLOR_FORCE', 'CI',
            'COPILOT_ALLOW_ALL', 'COPILOT_ASSISTED_APPROVAL', 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
            $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:COPILOT_HOME = $value.cliHome
        # These are Scout-process overrides, not the user's native profile settings.
        foreach ($name in @('NO_COLOR', 'TERM', 'COPILOT_ALLOW_ALL', 'COPILOT_ASSISTED_APPROVAL',
            'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) { Set-BuddyProcessEnvironment $name $null }
        $env:COPILOT_DISABLE_TERMINAL_TITLE = '1'
        $colorEnvironment = Get-BuddyTerminalEnvironment $value.colorEnabled
        foreach ($name in $colorEnvironment.Keys) { Set-BuddyProcessEnvironment $name $colorEnvironment[$name] }
        $terminal = Get-Command wt -ErrorAction SilentlyContinue | Select-Object -First 1
        $process = $null
        try {
            if ($terminal) {
                foreach ($part in @($shell, $hostScript, $Repository, $configPathResolved, $value.workingDirectory)) {
                    if ($part.Contains(';')) { throw 'Windows Terminal handoff does not support semicolons in these paths.' }
                }
                $launch = [Diagnostics.ProcessStartInfo]::new()
                $launch.FileName = $terminal.Source
                $launch.UseShellExecute = $false
                $launchArguments = @('-w', $value.sharedWindowName, 'new-tab', '--title', $value.windowTitle,
                    '--suppressApplicationTitle', '-d', $value.workingDirectory,
                    $shell, '-NoLogo', '-NoProfile', '-File', $hostScript,
                    '-Repository', $Repository, '-SessionId', $SessionId.ToString(), '-ConfigPath', $configPathResolved)
                if ($nativeLaunch) { $launchArguments += @('-NativeRequestId', $NativeRequestId.ToString()) }
                foreach ($arg in $launchArguments) {
                    $launch.ArgumentList.Add($arg)
                }
                $process = [Diagnostics.Process]::Start($launch)
            } else {
                $startedPid = [MyBuddy.TerminalNative]::StartConsole($shell, $commandLine, $value.workingDirectory, $value.windowTitle)
                $process = Get-Process -Id $startedPid -ErrorAction Stop
            }
        } finally {
            foreach ($name in $environment.Keys) { Set-BuddyProcessEnvironment $name $environment[$name] }
        }
        try {
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                Start-Sleep -Milliseconds 200
                $record = Get-BuddyTrackedWindow $value
                if ($record) { return $record }
                if ($process.HasExited -and (-not $terminal -or $process.ExitCode -ne 0)) {
                    throw "The terminal closed before startup completed (exit $($process.ExitCode))."
                }
            }
            throw 'The terminal was launched but did not report ready. Check its window before clicking again; Buddy will not duplicate a live session.'
        } finally { $process.Dispose() }
        } finally { $sharedLock.Dispose() }
    }
    if ($nativeLaunch) {
        if ($result.status -ne 'opened') { throw "Native first launch was not started: $($result.status). No task was submitted." }
        $result.status = 'native-starting'
        $result.message = 'Native CLI tab launched. The bound extension will submit the approved task once in this exact session; startup/authentication may require your input.'
        $result | Add-Member requestId $NativeRequestId.ToString()
        $result | Add-Member runtimeActive $true
        $result | Add-Member safeToClose $false
        $result | Add-Member activity 'awaiting-native-startup-or-input'
    }
    $result | Add-Member sessionTitle $plan.sessionTitle
    $result | Add-Member nativePolicy $plan.nativePolicy
    $result | Add-Member permissionNote ($plan.nativePolicy.explanation + ' ' + $plan.nativePolicy.resumeNote)
    $result | ConvertTo-Json -Depth 6
} finally { if ($openLock) { $openLock.Dispose() } }
