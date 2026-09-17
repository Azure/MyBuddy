. (Join-Path $PSScriptRoot 'Buddy.Terminal.Core.ps1')

function Write-BuddyPrivateData {
    param([string]$Path, $Value, [switch]$CreateNew)
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    $bytes = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20 -Compress)), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    if ($CreateNew) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    } else {
        $temporary = $Path + '.' + [Guid]::NewGuid() + '.pending'
        try { [IO.File]::WriteAllBytes($temporary, $bytes); [IO.File]::Move($temporary, $Path, $true) }
        finally { if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary } }
    }
}

function Read-BuddyPrivateData {
    param([string]$Path)
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Get-BuddyNativePaths {
    param([string]$StateDirectory, [Guid]$SessionId)
    $folder = Join-Path $StateDirectory 'native'
    [pscustomobject]@{
        ticket = Join-Path $folder "$SessionId.dpapi"
        consumed = Join-Path $folder "$SessionId.consumed.dpapi"
        receipt = Join-Path $folder "$SessionId.receipt.dpapi"
        started = Join-Path $folder "$SessionId.started.dpapi"
    }
}

function Get-BuddyNativeTicket {
    param($Config, [Guid]$SessionId, [Guid]$RequestId)
    $paths = Get-BuddyNativePaths $Config.stateDirectory $SessionId
    $ticket = Read-BuddyPrivateData $paths.ticket
    if ($ticket.plan.sessionId -ne $SessionId.ToString() -or $ticket.plan.requestId -ne $RequestId.ToString() -or
        $ticket.plan.execution -ne 'native-interactive') { throw 'The native launch request does not match its approved session.' }
    $ticket
}

function Assert-BuddyNativePlan {
    param($Config, $Plan)
    $unsigned = $Plan.PSObject.Copy()
    $unsigned.PSObject.Properties.Remove('approvalHash')
    if ((Get-BuddyHash ($unsigned | ConvertTo-Json -Depth 10 -Compress)) -cne $Plan.approvalHash) {
        throw 'Native launch payload no longer matches its exact approved preview.'
    }
    $cli = Get-Command $Config.cliCommand -ErrorAction Stop | Select-Object -First 1
    $Config.cliCommand = $cli.Source
    $fresh = New-BuddyAgentPlan -Config $Config -Repository $Plan.repository -Mode $Plan.mode -Task $Plan.task `
        -SourceRef $Plan.sourceRef -Agent $(if ($Plan.agent) {$Plan.agent} else {'__default_cli__'}) `
        -PermissionMode $Plan.permissionMode -ConversationSessionId ([Guid]$Plan.sessionId) `
        -SessionTitle $(if ($Plan.PSObject.Properties['sessionTitle']) {$Plan.sessionTitle} else {''}) `
        -RequestId ([Guid]$Plan.requestId) -NativeInteractive
    if ($fresh.approvalHash -cne $Plan.approvalHash -or $fresh.sessionTitle -cne $Plan.sessionTitle) {
        throw 'Native launch approval is stale. Task title, CLI, MCP, defaults or checkout configuration changed; nothing was submitted.'
    }
}

function Set-BuddyNativeArguments {
    param($TerminalPlan, $TaskPlan)
    $arguments = @(Get-BuddyCliArguments $TaskPlan ([Guid]$TaskPlan.sessionId))
    $clean = @()
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -in @('--output-format','--model','--context','--mode','--allow-tool','--deny-tool')) { $i++; continue }
        if ($arguments[$i] -eq '--no-ask-user') { continue }
        $clean += $arguments[$i]
    }
    $defaults = $TaskPlan.terminalDefaults
    $TerminalPlan.arguments = $clean + @('--experimental', '--model', $defaults.model,
        '--context', $defaults.context, '--mode', $defaults.mode)
    if (-not $defaults.color) { $TerminalPlan.arguments += '--no-color' }
    $TerminalPlan.terminalDefaults = $defaults
    $TerminalPlan.colorEnabled = $defaults.color
    $TerminalPlan.nativePolicy = $TaskPlan.nativePolicy
}

function Start-BuddyNativeTask {
    param($Config, $Plan, [string]$ConfigPath, [DateTimeOffset]$LaunchNotAfter = [DateTimeOffset]::MinValue)
    Initialize-BuddyTerminalNative
    if ($LaunchNotAfter -eq [DateTimeOffset]::MinValue) { $LaunchNotAfter=[DateTimeOffset]::UtcNow.AddSeconds(60) }
    if ([DateTimeOffset]::UtcNow -gt $LaunchNotAfter) { throw 'Native launch lease expired. No late launch or automatic retry is permitted.' }
    Assert-BuddyNativePlan $Config $Plan
    $terminalPlan = Get-BuddyTerminalPlan $Config $Plan.repository ([Guid]$Plan.sessionId) -SessionTitle $Plan.sessionTitle -AllowNewSession
    if (Test-Path (Join-Path $Config.cliHome "session-state\$($Plan.sessionId)\events.jsonl")) {
        throw 'The approved new session already exists. No task was replayed.'
    }
    if (-not $terminalPlan.allowConcurrentSessions -and -not (Test-BuddyTerminalLockAvailable $terminalPlan.checkoutLockPath)) {
        throw 'Checkout busy: another Buddy task or native session owns this checkout. No hidden fallback or task submission.'
    }
    $paths = Get-BuddyNativePaths $Config.stateDirectory ([Guid]$Plan.sessionId)
    # Never overwrite/re-arm a request, including after a crash between consumption and SDK send.
    Write-BuddyPrivateData $paths.ticket @{ plan=$Plan; configPath=(Resolve-BuddyPath $ConfigPath)
        launchExpiresAt=$LaunchNotAfter.ToString('o') } -CreateNew
    $extensionFolder = Join-Path $Config.cliHome 'extensions\mybuddy-approved-task'
    [IO.Directory]::CreateDirectory($extensionFolder) | Out-Null
    $module = [Uri]::new((Join-Path $PSScriptRoot 'Buddy.NativeTask.Extension.mjs')).AbsoluteUri | ConvertTo-Json -Compress
    $helper = (Join-Path $PSScriptRoot 'Receive-BuddyNativeTask.ps1') | ConvertTo-Json -Compress
    $state = $Config.stateDirectory | ConvertTo-Json -Compress
    $loader = "import { attachApprovedTask } from $module;`nawait attachApprovedTask({ helper: $helper, stateDirectory: $state });`n"
    $extensionPath = Join-Path $extensionFolder 'extension.mjs'
    if (Test-Path $extensionPath) {
        if ([IO.File]::ReadAllText($extensionPath) -cne $loader) { throw 'A different Buddy extension already exists in this profile. Native task launch was not attempted.' }
    } else { [IO.File]::WriteAllText($extensionPath, $loader) }
    & (Join-Path $PSScriptRoot 'Open-BuddySession.ps1') -Repository $Plan.repository `
        -SessionId ([Guid]$Plan.sessionId) -ConfigPath $ConfigPath -NativeRequestId ([Guid]$Plan.requestId)
}

function Test-BuddyCurrentSessionError {
    param([string[]]$Events)
    $latest = $Events | Where-Object {
        $_ -match '"type"\s*:\s*"(session\.error|user\.message|assistant\.message)"'
    } | Select-Object -Last 1
    return [bool]($latest -match '"type"\s*:\s*"session\.error"')
}

function Get-BuddyNativeTaskStatus {
    param($Config, [string]$Repository, [Guid]$SessionId, [Guid]$RequestId)
    Initialize-BuddyTerminalNative
    $paths = Get-BuddyNativePaths $Config.stateDirectory $SessionId
    $result = [ordered]@{ sessionId=$SessionId.ToString(); requestId=$RequestId.ToString()
        status='native-orphaned'; runtimeActive=$false; safeToClose=$false; promptSubmitted=$false
        activity='unknown'; message='Native startup could not be verified. The task will never be automatically replayed.' }
    if (-not (Test-Path $paths.ticket)) {
        $result.status='native-failed'; $result.safeToClose=$true; $result.startupPending=$true
        $result.message='No protected launch request exists. No native task could be submitted.'
        return [pscustomobject]$result
    }
    $ticket = Get-BuddyNativeTicket $Config $SessionId $RequestId
    # Discovery uses the approved checkout/profile, even if current mappings were changed.
    $Config.repositories.PSObject.Properties[$Repository].Value.path = $ticket.plan.workingDirectory
    $Config.cliHome = $ticket.plan.cliHome
    $plan = Get-BuddyTerminalPlan $Config $Repository $SessionId -AllowNewSession
    $record = if (Test-Path $plan.recordPath) { Get-Content $plan.recordPath -Raw | ConvertFrom-Json } else { $null }
    $live = $record -and (Test-BuddyProcessIdentity $record.hostPid $record.hostStartedAt)
    $locked = -not (Test-BuddyTerminalLockAvailable $plan.activeLockPath)
    $externalProcesses = @(Get-BuddyExternalSessionProcesses $SessionId)
    $external = $externalProcesses.Count -gt 0
    $result.runtimeActive = [bool]($live -or $locked -or $external)
    $result.safeToClose = -not $result.runtimeActive -and
        ([DateTimeOffset]::UtcNow -gt [DateTimeOffset]$ticket.launchExpiresAt -or [bool]$record)
    $receipt = if (Test-Path $paths.receipt) { Read-BuddyPrivateData $paths.receipt } else { $null }
    $result.promptSubmitted = [bool]($receipt -and $receipt.status -eq 'submitted')
    if ($result.runtimeActive) {
        $result.status = if ($result.promptSubmitted) { 'native-active' } else { 'native-starting' }
        $result.activity = if ($result.promptSubmitted) { 'working-or-awaiting-input' } else { 'awaiting-native-startup-or-input' }
        $result.message = 'Use the visible native tab for live tool progress, authentication, permissions and questions. Opening a tab is not task completion.'
        if (-not $live -and -not $locked -and @($externalProcesses | Where-Object orphaned).Count) {
            $result.status = 'native-orphaned'; $result.activity = 'orphaned-runtime'
            $result.message = "Copilot is still running after its terminal exited (PID $($externalProcesses.processId -join ', ')). Stop the leftover process before resuming; Buddy will not interrupt it or open a duplicate."
        }
    } elseif ($record -and $record.status -in @('ready','closed') -and $result.safeToClose) {
        $result.status = 'native-closed'; $result.activity = 'closed'
        $result.message = 'The native CLI is no longer running. Continue reopens its saved history, or mark Done after reviewing the outcome. Closing the CLI does not prove task completion.'
    }
    if (($record -and $record.status -eq 'failed') -or ($receipt -and $receipt.status -eq 'failed')) {
        $result.status = 'native-failed'; $result.activity = 'blocked'
        $result.message = if ($receipt -and $receipt.status -eq 'failed') { $receipt.message } else { $record.error }
    }
    $events = Join-Path $ticket.plan.cliHome "session-state\$SessionId\events.jsonl"
    if (Test-Path $events) {
        if (Test-BuddyCurrentSessionError @(Get-Content -LiteralPath $events)) {
            $result.status = 'native-failed'; $result.activity = 'blocked'
            $result.message = 'The native CLI reported a session error. Inspect its visible tab and saved session; no automatic retry will occur.'
        }
    }
    if ($record -and $record.status -eq 'closed' -and -not $result.promptSubmitted) {
        $result.status = 'native-failed'
        $result.message = 'Native CLI closed without confirming the approved prompt was submitted. Extension startup, policy or authentication may have blocked it. No replay will occur.'
    }
    if ((Test-Path $paths.consumed) -and -not $result.promptSubmitted -and -not $result.runtimeActive) {
        $result.message = 'Launch was consumed, but prompt delivery cannot be confirmed. Inspect the exact saved session; no automatic resend is allowed.'
    }
    [pscustomobject]$result
}
