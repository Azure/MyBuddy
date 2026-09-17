#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('claim','submitted','failed')][string]$Operation,
    [Parameter(Mandatory)][Guid]$SessionId,
    [Parameter(Mandatory)][string]$StateDirectory
)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$owned = $false
try {
    . (Join-Path $PSScriptRoot 'Buddy.NativeTask.Core.ps1')
    $paths = Get-BuddyNativePaths $StateDirectory $SessionId
    $ticket = Read-BuddyPrivateData $paths.ticket
    $config = Read-BuddyAgentConfig $ticket.configPath
    if ($ticket.plan.sessionId -ne $SessionId.ToString() -or $config.stateDirectory -ne $StateDirectory) {
        throw 'Native launch identity mismatch.'
    }
    # Newer native CLIs persist events.jsonl on the first message, not when the TUI starts.
    # The SDK foreground ID plus the approved host/process ancestry binds this initial send.
    $plan = Get-BuddyTerminalPlan $config $ticket.plan.repository $SessionId -AllowNewSession
    $record = Get-Content -LiteralPath $plan.recordPath -Raw | ConvertFrom-Json
    $started = Read-BuddyPrivateData $paths.started
    if ($record.status -ne 'ready' -or -not (Test-BuddyProcessIdentity $record.hostPid $record.hostStartedAt)) {
        throw 'No live, owned native host for this request.'
    }
    if ($started.hostPid -ne $record.hostPid -or
        -not (Test-BuddyProcessIdentity $started.hostPid $started.hostStartedAt) -or
        $started.requestId -ne $ticket.plan.requestId) {
        throw 'This is not the original approved native launch. Navigation cannot submit a task.'
    }
    $ancestor = $PID
    $owned = $false
    for ($i=0; $i -lt 16 -and $ancestor; $i++) {
        if ($ancestor -eq $record.hostPid) { $owned=$true; break }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" -ErrorAction Stop
        if (-not $process) { break }
        $ancestor = [int]$process.ParentProcessId
    }
    if (-not $owned) { throw 'Only the extension inside the approved native host can consume this request.' }
    if ($Operation -eq 'claim') {
        Assert-BuddyNativePlan $config $ticket.plan
        Write-BuddyPrivateData $paths.consumed @{requestId=$ticket.plan.requestId; approvalHash=$ticket.plan.approvalHash;
            sessionId=$SessionId.ToString(); consumedAt=[DateTimeOffset]::UtcNow.ToString('o')} -CreateNew
        @{prompt=$ticket.plan.prompt;sessionId=$SessionId.ToString()} | ConvertTo-Json -Depth 4 -Compress
    } else {
        if (-not (Test-Path $paths.consumed)) { throw 'Native request was not consumed.' }
        Write-BuddyPrivateData $paths.receipt @{status=$Operation;at=[DateTimeOffset]::UtcNow.ToString('o');
            message='The native extension could not confirm prompt submission. Inspect the tab; the request will not be replayed.'}
        '{"recorded":true}'
    }
} catch {
    if ($owned -and $Operation -eq 'claim' -and -not (Test-Path $paths.consumed)) {
        Write-BuddyPrivateData $paths.receipt @{status='failed';at=[DateTimeOffset]::UtcNow.ToString('o');
            message='The native extension rejected the launch identity or stale approval. Nothing was submitted; previewing or navigation cannot retry it.'}
    }
    [Console]::Error.WriteLine('Approved native request unavailable: ' + $_.Exception.Message)
    exit 1
}
