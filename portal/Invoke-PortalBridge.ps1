#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
$root = Split-Path $PSScriptRoot -Parent
switch ($request.operation) {
    'doctor' { & (Join-Path $root 'Invoke-BuddyAgent.ps1') Doctor }
    'open-session' {
        & (Join-Path $root 'Open-BuddySession.ps1') -Repository $request.input.repository -SessionId ([Guid]$request.input.sessionId) `
            -SessionTitle $(if ($request.input.PSObject.Properties['sessionTitle']) { $request.input.sessionTitle } else { '' }) `
            -FocusOnly:($request.input.PSObject.Properties['focusOnly'] -and $request.input.focusOnly)
    }
    'native-status' {
        . (Join-Path $root 'Buddy.NativeTask.Core.ps1')
        $config = Read-BuddyAgentConfig (Join-Path $root 'buddy.agent.json')
        Get-BuddyNativeTaskStatus $config $request.input.repository ([Guid]$request.input.sessionId) `
            ([Guid]$request.input.requestId) | ConvertTo-Json -Depth 5
    }
    { $_ -in @('collect', 'collect-github') } {
        $argsForCollector = @{ AsOf = [DateTimeOffset]$request.asOf }
        if ($request.PSObject.Properties['since'] -and $request.since) { $argsForCollector.Since = [DateTimeOffset]$request.since }
        if ($request.PSObject.Properties['cache'] -and $request.cache) { $argsForCollector.CacheJson = $request.cache | ConvertTo-Json -Depth 80 -Compress }
        if ($request.PSObject.Properties['repository']) { $argsForCollector.Repository = $request.repository }
        if ($request.PSObject.Properties['pullRequestId']) { $argsForCollector.PullRequestId = [int]$request.pullRequestId }
        $collector = if ($request.operation -eq 'collect-github') { 'Get-BuddyGitHubPullRequests.ps1' } else { 'Get-BuddyPullRequests.ps1' }
        & (Join-Path $root $collector) @argsForCollector
    }
    { $_ -in @('preview', 'run', 'launch-native') } {
        $values = $request.input
        $argsForAgent = @{
            Repository = $values.repository
            Mode = $values.mode
            Task = $values.task
            SourceRef = $values.sourceRef
            InitializeEnvironment = [bool]$values.initializeEnvironment
        }
        if ($values.PSObject.Properties['agent']) { $argsForAgent.Agent = $values.agent }
        if ($values.PSObject.Properties['permissionMode']) { $argsForAgent.PermissionMode = $values.permissionMode }
        if ($values.PSObject.Properties['sessionId'] -and $values.sessionId) { $argsForAgent.ConversationSessionId = [Guid]$values.sessionId }
        if ($values.PSObject.Properties['resumeSession']) { $argsForAgent.ResumeSession = [bool]$values.resumeSession }
        if ($values.PSObject.Properties['sessionTitle']) { $argsForAgent.SessionTitle = $values.sessionTitle }
        $argsForAgent.NativeInteractive = $request.operation -ne 'run'
        if ($request.operation -in @('run','launch-native')) {
            $argsForAgent.RequestId = [Guid]$request.plan.requestId
            $argsForAgent.ApprovalHash = $request.plan.approvalHash
            if ($request.PSObject.Properties['launchNotAfter']) { $argsForAgent.LaunchNotAfter = [DateTimeOffset]$request.launchNotAfter }
        }
        $command = if ($request.operation -eq 'launch-native') { 'Run' } else { $request.operation }
        & (Join-Path $root 'Invoke-BuddyAgent.ps1') -Command $command @argsForAgent
    }
    default { throw 'Unsupported portal bridge operation.' }
}
