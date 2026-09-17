#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][Guid]$SessionId,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Guid]$NativeRequestId = [Guid]::Empty
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Buddy.Terminal.Core.ps1')
Initialize-BuddyTerminalNative
$config = Read-BuddyAgentConfig $ConfigPath
$nativeLaunch = $NativeRequestId -ne [Guid]::Empty
$plan = Get-BuddyTerminalPlan $config $Repository $SessionId -AllowNewSession:$nativeLaunch
$activeLock = $null
$checkoutLock = $null
$record = $null
try {
    $activeLock = [IO.File]::Open($plan.activeLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (-not $plan.allowConcurrentSessions) {
        [IO.Directory]::CreateDirectory((Split-Path $plan.checkoutLockPath -Parent)) | Out-Null
        $checkoutLock = [IO.File]::Open($plan.checkoutLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    if ($nativeLaunch) {
        . (Join-Path $PSScriptRoot 'Buddy.NativeTask.Core.ps1')
        $ticket = Get-BuddyNativeTicket $config $SessionId $NativeRequestId
        Assert-BuddyNativePlan $config $ticket.plan
        $paths = Get-BuddyNativePaths $config.stateDirectory $SessionId
        if ((Test-Path $paths.consumed) -or (Test-Path (Join-Path $config.cliHome "session-state\$SessionId\events.jsonl"))) {
            throw 'Native launch already started or consumed. No automatic task replay is permitted.'
        }
        if ([DateTimeOffset]::UtcNow -gt [DateTimeOffset]$ticket.launchExpiresAt) { throw 'Native startup lease expired. No late task launch or automatic retry is permitted.' }
        Write-BuddyPrivateData $paths.started @{requestId=$NativeRequestId.ToString();sessionId=$SessionId.ToString();
            hostPid=$PID;hostStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')} -CreateNew
        Set-BuddyNativeArguments $plan $ticket.plan
    }
    if (@(Get-BuddyExternalSessionProcesses $SessionId).Count) { throw 'This session is already running in another process. No second runtime was started.' }
    [MyBuddy.TerminalNative]::BindCurrentTerminalHostLifetime()
    Set-Location -LiteralPath $plan.workingDirectory
    $env:COPILOT_HOME = $plan.cliHome
    Set-BuddyProcessEnvironment MY_BUDDY_NATIVE_SESSION $(if ($nativeLaunch) {$SessionId.ToString()} else {$null})
    $env:COPILOT_DISABLE_TERMINAL_TITLE = '1'
    foreach ($name in @('COPILOT_ALLOW_ALL', 'COPILOT_ASSISTED_APPROVAL',
        'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) { Set-BuddyProcessEnvironment $name $null }
    $colorEnvironment = Get-BuddyTerminalEnvironment $plan.colorEnabled
    foreach ($name in $colorEnvironment.Keys) { Set-BuddyProcessEnvironment $name $colorEnvironment[$name] }
    $PSStyle.OutputRendering = 'Ansi'
    $Host.UI.RawUI.WindowTitle = $plan.windowTitle
    $window = [MyBuddy.TerminalNative]::GetConsoleWindow()
    if ($window -eq [IntPtr]::Zero -or -not [MyBuddy.TerminalNative]::IsWindowVisible($window) -or
        [MyBuddy.TerminalNative]::WindowClass($window) -eq 'PseudoConsoleWindow') {
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            $window = Find-BuddyTerminalTabWindow $plan.windowTitle
            if ($window -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    if ($window -eq [IntPtr]::Zero -or -not [MyBuddy.TerminalNative]::IsWindowVisible($window) -or
        [MyBuddy.TerminalNative]::WindowClass($window) -eq 'PseudoConsoleWindow') {
        throw 'A uniquely identifiable Buddy terminal tab or console window is required.'
    }
    $windowPid = [MyBuddy.TerminalNative]::WindowProcess($window)
    $windowToken = [Guid]::NewGuid().ToString()
    [MyBuddy.TerminalNative]::MarkWindow($window, $windowToken)
    $record = [ordered]@{
        sessionId = $SessionId.ToString()
        hostPid = $PID
        hostStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        windowHandle = $window.ToInt64()
        windowPid = $windowPid
        windowStartedAt = (Get-Process -Id $windowPid).StartTime.ToUniversalTime().ToString('o')
        windowToken = $windowToken
        protectedWindowTitle = ConvertTo-BuddyProtectedValue @{sessionId=$plan.sessionId;title=$plan.windowTitle}
        sharedWindowName = $plan.sharedWindowName
        status = 'ready'
        terminalDefaults = $plan.terminalDefaults
        nativePolicy = $plan.nativePolicy
        colorEnabled = $plan.colorEnabled
        childProcessLifetime = 'terminal-host'
    }
    Write-BuddyTerminalRecord $plan.recordPath $record
    if ($nativeLaunch) {
        Write-Host 'My Buddy -> Copilot CLI. Your approved task is sent once.'
        Write-Host 'Continue directly in Copilot. No task timeout; close CLI before marking Done.'
    } else {
        Write-Host 'Resuming your saved Copilot session. No task replay or initialization.'
    }
    Write-Host 'Publishing still needs your explicit approval.'
    Write-Host 'Prefer exiting Copilot normally. Windows app-alias processes can survive tab closure and block Continue or Done.'
    Write-Host 'Saved conversation history is retained. Leftover processes require explicit cleanup approval.'
    Write-Host $plan.nativePolicy.explanation
    Write-Host $plan.nativePolicy.resumeNote
    if ($plan.allowConcurrentSessions) { Write-Host 'Shared checkout: you coordinate branches and edits across sessions.' }
    if ($plan.terminalDefaults) {
        Write-Host ("Native defaults: {0} | {1} | {2}" -f $plan.terminalDefaults.model, $plan.terminalDefaults.context, $plan.terminalDefaults.mode)
        if ($plan.terminalDefaults.mode -eq 'autopilot') {
            Write-Host 'Autopilot may act autonomously under your CLI permissions.'
        }
    }
    $arguments = @($plan.arguments)
    & $plan.executable @arguments
    if ($LASTEXITCODE -ne 0) { throw "Copilot exited with code $LASTEXITCODE." }
    $record.status = 'closed'
    Write-BuddyTerminalRecord $plan.recordPath $record
} catch {
    if (-not $record -and $activeLock) {
        $record = [ordered]@{
            sessionId = $SessionId.ToString(); hostPid = $PID
            hostStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
            status = 'failed'
        }
    }
    if ($record) {
        $record.status = 'failed'
        $record.error = $_.Exception.Message
        Write-BuddyTerminalRecord $plan.recordPath $record
    }
    Write-Host ("Unable to continue: " + $_.Exception.Message) -ForegroundColor Red
    if ([MyBuddy.TerminalNative]::FindWindow($plan.windowTitle) -ne [IntPtr]::Zero -or
        (Find-BuddyTerminalTabWindow $plan.windowTitle) -ne [IntPtr]::Zero) {
        Read-Host 'Press Enter to close this tab' | Out-Null
    }
} finally {
    if ($record -and $record.Contains('windowToken')) {
        [MyBuddy.TerminalNative]::UnmarkWindow([IntPtr]([long]$record.windowHandle), $record.windowToken)
    }
    if ($checkoutLock) { $checkoutLock.Dispose() }
    if ($activeLock) { $activeLock.Dispose() }
}
