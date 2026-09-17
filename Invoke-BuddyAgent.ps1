<#
.SYNOPSIS
Portable Scout-to-Copilot bridge with full MCP discovery and explicit task contracts.
.DESCRIPTION
Doctor inspects local configuration without starting MCP servers. Preview returns
the exact task, scope and approval hash. Run requires that hash and request ID.
The hash prevents accidental payload changes; it does not prove human consent.
Scout must obtain explicit user approval before Run. There is no publish mode.
Native CLI permissions remain active; this is not a sandbox. MCP authentication
and unknown tool approvals can still require the user. CLI transcripts stay in the
user's existing Copilot profile and may contain private data.
.EXAMPLE
.\Invoke-BuddyAgent.ps1 Doctor
.EXAMPLE
.\Invoke-BuddyAgent.ps1 Preview -Repository xstore -Mode review -Task 'Review PR 123'
.EXAMPLE
.\Invoke-BuddyAgent.ps1 Preview -Repository xstore -Mode warmup -InitializeEnvironment
#>
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('Doctor', 'Preview', 'Run')][string]$Command = 'Doctor',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'buddy.agent.json'),
    [string]$Repository,
    [ValidateSet('review', 'develop', 'specify', 'warmup')][string]$Mode = 'review',
    [string]$Task = '',
    [string]$SourceRef = '',
    [string]$Agent = '',
    [ValidateSet('native', 'full')][string]$PermissionMode = 'native',
    [Guid]$ConversationSessionId = [Guid]::Empty,
    [switch]$ResumeSession,
    [Guid]$RequestId = [Guid]::Empty,
    [string]$ApprovalHash,
    [switch]$InitializeEnvironment,
    [switch]$NativeInteractive,
    [DateTimeOffset]$LaunchNotAfter = [DateTimeOffset]::MinValue,
    [string]$SessionTitle = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Buddy.Agent.Core.ps1')
$config = Read-BuddyAgentConfig $ConfigPath
$cli = Get-Command $config.cliCommand -ErrorAction Stop | Select-Object -First 1
if ($cli.CommandType -notin @('Application', 'ExternalScript')) { throw 'cliCommand must resolve to an executable or script, not an alias/function.' }
$config.cliCommand = $cli.Source

if ($Command -eq 'Doctor') {
    $servers = @()
    if ($config.mcpConfigPath) {
        $mcp = Get-Content -LiteralPath $config.mcpConfigPath -Raw | ConvertFrom-Json
        $servers = @($mcp.mcpServers.PSObject.Properties | ForEach-Object Name)
    }
    [pscustomobject]@{
        cli = $cli.Source
        cliHome = $config.cliHome
        callerCliHome = $env:COPILOT_HOME
        mcpConfigPath = $config.mcpConfigPath
        configuredServers = $servers
        sourceRoot = if ($config.PSObject.Properties['sourceRoot']) { $config.sourceRoot } else { $null }
        primaryRepository = if ($config.PSObject.Properties['primaryRepository']) { $config.primaryRepository } else { $null }
        specifyPermissionMode = if ($config.PSObject.Properties['specifyPermissionMode']) { $config.specifyPermissionMode } else { 'native' }
        allowConcurrentSessions = Get-BuddyConcurrentSessions $config
        connectivity = 'Not probed. Run an approved warmup; configured does not mean authenticated.'
        repositories = @($config.repositories.PSObject.Properties | ForEach-Object {
            $definition = if ($_.Value.agent) { Join-Path $_.Value.path ".github\agents\$($_.Value.agent).agent.md" } else { $null }
            [pscustomobject]@{
                alias = $_.Name
                path = $_.Value.path
                exists = Test-Path -LiteralPath $_.Value.path -PathType Container
                agent = $_.Value.agent
                description = if ($_.Value.PSObject.Properties['description']) { $_.Value.description } else { $_.Name }
                agents = @(Get-BuddyAgentChoices -RepositoryPath $_.Value.path -CliHome $config.cliHome)
                repositoryAgentFileExists = if ($definition) { Test-Path -LiteralPath $definition -PathType Leaf } else { $null }
                initializationConfigured = [bool]$_.Value.initScript
            }
        })
        permissionModel = 'Full MCP discovery; scoped task instructions plus existing CLI permissions. No universal MCP write guarantee.'
        profileNote = 'Existing agent restrictions, plugins and policies are retained. Visible native launches expose normal built-in/MCP tools without Buddy filtering. Native permissions use interactive instead of autopilot so prompts can wait. Explicit Specify full approval is retained only for that same session on Continue; publication approval remains separate.'
    } | ConvertTo-Json -Depth 8
    return
}

if (-not $Repository) { throw 'Choose a configured repository alias.' }
if ($RequestId -eq [Guid]::Empty) {
    if ($Command -eq 'Run') { throw 'Run requires the request ID returned by Preview.' }
    $RequestId = [Guid]::NewGuid()
}
$plan = New-BuddyAgentPlan -Config $config -Repository $Repository -Mode $Mode -Task $Task `
    -SessionTitle $SessionTitle `
    -SourceRef $SourceRef -Agent $Agent -PermissionMode $PermissionMode -RequestId $RequestId `
    -ConversationSessionId $ConversationSessionId -ResumeSession:$ResumeSession -InitializeEnvironment:$InitializeEnvironment -NativeInteractive:$NativeInteractive
if ($Command -eq 'Preview') {
    $plan | ConvertTo-Json -Depth 10
    return
}
if (-not $ApprovalHash -or $ApprovalHash -cne $plan.approvalHash) {
    throw 'Missing or stale task approval. Preview again and obtain explicit user approval of the exact task.'
}
if ($NativeInteractive) {
    . (Join-Path $PSScriptRoot 'Buddy.NativeTask.Core.ps1')
    try {
        Start-BuddyNativeTask -Config $config -Plan $plan -ConfigPath $ConfigPath -LaunchNotAfter $LaunchNotAfter
    } catch {
        $paths = Get-BuddyNativePaths $config.stateDirectory ([Guid]$plan.sessionId)
        if ((Test-Path $paths.ticket) -and -not (Test-Path $paths.receipt)) {
            Write-BuddyPrivateData $paths.receipt @{status='failed';message=$_.Exception.Message;at=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        throw
    }
    return
}

$stateDirectory = $config.stateDirectory
[IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
$statePath = Join-Path $stateDirectory "$RequestId.json"
$lockPath = Join-Path $stateDirectory ((Get-BuddyHash $plan.workingDirectory.ToLowerInvariant()) + '.lock')
$lock = $null
$sessionLock = $null
$process = $null
$sessionId = if ($ConversationSessionId -eq [Guid]::Empty) { [Guid]::NewGuid() } else { $ConversationSessionId }
$eventPath = Join-Path $config.cliHome "session-state\$sessionId\events.jsonl"
$existingEventLines = 0
if ($ResumeSession) {
    if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) { throw 'The original CLI session is missing. No replacement session was created.' }
} elseif (Test-Path -LiteralPath $eventPath) {
    throw 'Session already exists. Use an explicitly approved resume instead of starting over it.'
}
$state = [ordered]@{
    requestId = $RequestId.ToString(); approvalHash = $ApprovalHash
    sessionId = $sessionId.ToString(); mode = $Mode; status = 'starting'
    startedAt = [DateTimeOffset]::UtcNow.ToString('o'); finishedAt = $null
}
$stateCreated = $false
$processStarted = $false
try {
    $sessionLockPath = Get-BuddySessionLockPath $config.cliHome $sessionId
    [IO.Directory]::CreateDirectory((Split-Path $sessionLockPath -Parent)) | Out-Null
    $sessionLock = [IO.File]::Open($sessionLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (-not $plan.allowConcurrentSessions) {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    if (-not $ResumeSession -and (Test-Path -LiteralPath $eventPath)) {
        throw 'Session already exists. Use an explicitly approved resume instead of starting over it.'
    }
    if ($ResumeSession) { $existingEventLines = @(Get-Content -LiteralPath $eventPath).Count }
    $stream = [IO.File]::Open($statePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    $stateCreated = $true
    if ($SessionTitle) {
        Get-BuddySessionTitle $plan.sessionTitle $Repository $config.cliHome $sessionId -Persist | Out-Null
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json))
    $arguments = @(Get-BuddyCliArguments $plan $sessionId)
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $bootstrap = Join-Path $PSScriptRoot 'Invoke-BuddyCli.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.WorkingDirectory = $plan.workingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.Environment['COPILOT_HOME'] = $config.cliHome
    $start.Environment['MY_BUDDY_CLI_ENVELOPE'] = (@{ executable = $cli.Source; arguments = $arguments } | ConvertTo-Json -Depth 5 -Compress)
    # Do not inherit Scout's broad approval or credential overrides into the user's CLI profile.
    foreach ($name in @('COPILOT_ALLOW_ALL', 'COPILOT_ASSISTED_APPROVAL', 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
        $start.Environment.Remove($name) | Out-Null
    }
    if ($plan.initializationScript) {
        if (-not $IsWindows) { throw 'Corext initialization is only supported on Windows.' }
        foreach ($path in @($plan.initializationScript, $pwsh, $bootstrap)) {
            if ($path -match '["%!\r\n]') { throw 'Initialization paths contain unsupported cmd expansion characters.' }
        }
        $start.FileName = $env:ComSpec
        # cmd.exe does not understand ArgumentList's C-runtime backslash quote escaping.
        $start.Arguments = '/d /s /c "call "{0}" >nul && "{1}" -NoLogo -NoProfile -File "{2}""' -f
            $plan.initializationScript, $pwsh, $bootstrap
    } else {
        $start.FileName = $pwsh
        foreach ($arg in @('-NoLogo', '-NoProfile', '-File', $bootstrap)) { $start.ArgumentList.Add($arg) }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Could not start Copilot worker.' }
    $processStarted = $true
    $state.status = 'running'
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json))
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($plan.prompt)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($plan.timeoutSeconds * 1000)) {
        $process.Kill($true)
        $process.WaitForExit()
        $state.status = 'timed-out'
        throw 'Worker exceeded the approved time budget. Inspect its session before retrying; no automatic retry was attempted.'
    }
    $output = $stdout.GetAwaiter().GetResult()
    $errorOutput = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "Copilot exited with code $($process.ExitCode). $errorOutput" }
    $result = Read-BuddyRunEvents -EventPath $eventPath -ConsoleOutput $output -SkipLines $existingEventLines
    $state.status = 'returned-for-review'
    [pscustomobject]@{
        requestId = $RequestId.ToString(); sessionId = $sessionId.ToString()
        status = $state.status; mode = $Mode; agent = $plan.agent
        assessment = $result.assessment; toolCalls = $result.toolCalls
        mcpStatus = $result.mcpStatus
        configuredMcpServers = $plan.configuredMcpServers
        warnings = $errorOutput
        publicationAuthorized = $false
        note = 'Agent-reported output, not proof of task completion or absence of side effects. Scout must review it.'
    } | ConvertTo-Json -Depth 10
} catch {
    if ($state.status -ne 'timed-out') { $state.status = 'failed' }
    throw
} finally {
    if ($process) {
        if ($processStarted -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    if ($stateCreated) {
        $state.finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json))
    }
    if ($lock) { $lock.Dispose() }
    if ($sessionLock) { $sessionLock.Dispose() }
}
