Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Buddy.Agent.Core.ps1')
. (Join-Path $PSScriptRoot 'Buddy.NativeTask.Support.ps1')

function Initialize-BuddyTerminalNative {
    if (-not $IsWindows) { throw 'Native window handoff currently requires Windows.' }
    if (-not ('MyBuddy.TerminalNative' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'Buddy.Terminal.Native.cs')
    }
}

function Get-BuddyTerminalEnvironment {
    param([bool]$EnableColor = $true)
    # Windows Terminal can inherit its broker's environment instead of the launcher.
    # Apply the interactive settings inside the final host, not just before wt.exe.
    $values = @{ NO_COLOR = $null; CLICOLOR = $null; FORCE_COLOR = $null; CLICOLOR_FORCE = $null; CI = $null }
    if ($EnableColor) {
        $values.TERM = 'xterm-256color'
        $values.COLORTERM = 'truecolor'
        $values.FORCE_COLOR = '3'
    }
    return $values
}

function Set-BuddyProcessEnvironment {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()]$Value)
    # In PowerShell/.NET 9, passing $null to SetEnvironmentVariable(string, string)
    # becomes an EMPTY variable, not a deletion. Copilot treats even NO_COLOR="" as disabled.
    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:\$Name" -ErrorAction SilentlyContinue
    } else {
        [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'Process')
    }
}

function Initialize-BuddyTerminalAutomation {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
}

function Get-BuddyTerminalTab {
    param([Parameter(Mandatory)][IntPtr]$Window, [Parameter(Mandatory)][string]$Title)
    try {
        Initialize-BuddyTerminalAutomation
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::TabItem),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $Title))
        $tabs = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($tabs.Count -eq 1) { return $tabs[0] }
    } catch {
        # A closed, inaccessible, renamed or ambiguous tab must never select another tab.
    }
    return $null
}

function Find-BuddyTerminalTabWindow {
    param([Parameter(Mandatory)][string]$Title)
    $windows = @([MyBuddy.TerminalNative]::TerminalWindows() | Where-Object {
        $null -ne (Get-BuddyTerminalTab $_ $Title)
    })
    if ($windows.Count -eq 1) { return $windows[0] }
    return [IntPtr]::Zero
}

function Get-BuddyTerminalPlan {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][Guid]$SessionId,
        [switch]$AllowNewSession,
        [string]$SessionTitle = ''
    )
    if ($SessionId -eq [Guid]::Empty) { throw 'A recorded Copilot session ID is required.' }
    $repo = $Config.repositories.PSObject.Properties[$Repository]
    if ($null -eq $repo) { throw 'The linked repository is no longer configured.' }
    if (-not (Test-Path -LiteralPath $repo.Value.path -PathType Container)) { throw 'The linked checkout is unavailable.' }
    $eventPath = Join-Path $Config.cliHome "session-state\$SessionId\events.jsonl"
    $hasEvents = Test-Path -LiteralPath $eventPath -PathType Leaf
    if (-not $hasEvents -and -not $AllowNewSession) {
        throw 'The recorded Copilot session is missing from this profile. No new conversation was created.'
    }
    # Resolve the session's persisted checkout; do not silently rebind an old session.
    if ($hasEvents) {
    $start = Get-Content -LiteralPath $eventPath |
        Where-Object { $_ -match '"type"\s*:\s*"session.start"' } |
        Select-Object -First 1 | ConvertFrom-Json
    if ($null -eq $start -or [Guid]$start.data.sessionId -ne $SessionId) { throw 'The saved session identity could not be verified.' }
    if ($start.data.PSObject.Properties['context'] -and $start.data.context.PSObject.Properties['cwd'] -and
        (Resolve-BuddyPath $start.data.context.cwd) -ne $repo.Value.path) {
        throw 'The saved session belongs to a different checkout. Correct its Buddy mapping before opening.'
    }
    }
    $command = Get-Command $Config.cliCommand -ErrorAction Stop | Select-Object -First 1
    if ($command.CommandType -notin @('Application', 'ExternalScript')) { throw 'Copilot must resolve to an executable or script.' }
    $key = Get-BuddyHash ($Config.cliHome.ToLowerInvariant() + '|' + $SessionId.ToString())
    $windowKey = Get-BuddyHash $Config.cliHome.ToLowerInvariant()
    $folder = Join-Path $env:LOCALAPPDATA 'MyBuddy\terminals'
    $arguments = @('-C', $repo.Value.path, '--session-id', $SessionId.ToString(), '--no-remote-export', '--no-auto-update')
    $policy = Get-BuddySavedNativePolicy $Config $Repository $SessionId
    $defaults = $policy.terminalDefaults
    $arguments += @('--model', $defaults.model, '--context', $defaults.context, '--mode', $defaults.mode)
    if ($policy.permissionMode -eq 'full') { $arguments += '--allow-all' }
    if (-not $defaults.color) { $arguments += '--no-color' }
    if ($Config.mcpConfigPath -and $Config.mcpConfigPath -ne (Join-Path $Config.cliHome 'mcp-config.json')) {
        $arguments += @('--additional-mcp-config', ('@' + $Config.mcpConfigPath))
    }
    $title = Get-BuddySessionTitle $SessionTitle $Repository $Config.cliHome $SessionId
    [pscustomobject]@{
        sessionId = $SessionId.ToString()
        workingDirectory = $repo.Value.path
        cliHome = $Config.cliHome
        executable = $command.Source
        arguments = $arguments
        terminalDefaults = $defaults
        nativePolicy = $policy
        colorEnabled = if ($defaults) { $defaults.color } else { $true }
        allowConcurrentSessions = Get-BuddyConcurrentSessions $Config
        recordPath = Join-Path $folder "$key.json"
        activeLockPath = Get-BuddySessionLockPath $Config.cliHome $SessionId
        openLockPath = Join-Path $folder "$key.open.lock"
        sharedWindowName = 'MyBuddy-' + $windowKey.Substring(0, 24)
        sharedWindowLockPath = Join-Path $folder "$windowKey.window.lock"
        checkoutLockPath = Join-Path $Config.stateDirectory ((Get-BuddyHash $repo.Value.path.ToLowerInvariant()) + '.lock')
        sessionTitle = $title
        windowTitle = $title
        sessionTitlePath = Get-BuddySessionTitlePath $Config.cliHome $SessionId
    }
}

function Test-BuddySessionArguments {
    param([string[]]$Arguments, [Parameter(Mandatory)][Guid]$SessionId)
    # Only exact session switches identify a runtime, not a GUID mentioned inside a prompt.
    for ($i = 1; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        if ($argument -in @('--session-id', '--resume', '-r') -and $i + 1 -lt $Arguments.Count) {
            if ($Arguments[$i + 1] -ieq $SessionId.ToString()) { return $true }
        }
        if ($argument -imatch '^--(session-id|resume)=(.+)$' -and $Matches[2] -ieq $SessionId.ToString()) { return $true }
    }
    return $false
}

function Get-BuddyExternalSessionProcesses {
    param([Parameter(Mandatory)][Guid]$SessionId)
    Initialize-BuddyTerminalNative
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='copilot.exe' OR Name='node.exe'" -ErrorAction Stop)
    foreach ($process in $processes) {
        if (-not $process.CommandLine) { continue }
        $arguments = [MyBuddy.TerminalNative]::Arguments($process.CommandLine)
        if ($process.Name -eq 'node.exe' -and
            -not @($arguments | Where-Object { $_ -match '[\\/]@github[\\/]copilot[\\/](npm-loader|index)\.js$' }).Count) { continue }
        if (Test-BuddySessionArguments $arguments $SessionId) {
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -ErrorAction Stop
            [pscustomobject]@{
                processId = [int]$process.ProcessId; parentProcessId = [int]$process.ParentProcessId
                orphaned = -not ($parent -and $parent.CreationDate -le $process.CreationDate)
            }
        }
    }
}

function Test-BuddyProcessIdentity {
    param([int]$ProcessId, [DateTimeOffset]$StartedAt)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try { return $process.StartTime.ToUniversalTime().Ticks -eq $StartedAt.UtcTicks }
    catch { return $false }
}

function Get-BuddyWindowState {
    param($Record, [string]$Title)
    $window = [IntPtr]([long]$Record.windowHandle)
    if (-not [MyBuddy.TerminalNative]::IsWindow($window) -or
        -not [MyBuddy.TerminalNative]::IsWindowVisible($window) -or
        [MyBuddy.TerminalNative]::WindowClass($window) -eq 'PseudoConsoleWindow') { return $null }
    $isTerminal = [MyBuddy.TerminalNative]::WindowClass($window) -eq 'CASCADIA_HOSTING_WINDOW_CLASS'
    [pscustomobject]@{
        processId = [MyBuddy.TerminalNative]::WindowProcess($window)
        marked = $Record.PSObject.Properties['windowToken'] -and
            [MyBuddy.TerminalNative]::HasWindowMark($window, $Record.windowToken)
        exactTarget = if ($isTerminal) { $null -ne (Get-BuddyTerminalTab $window $Title) }
            else { [MyBuddy.TerminalNative]::Title($window) -eq $Title }
    }
}

function Get-BuddyWindowRecordTitle {
    param($Plan, $Record)
    if ($Record.PSObject.Properties['protectedWindowTitle']) {
        $value = ConvertFrom-BuddyProtectedValue $Record.protectedWindowTitle
        if ($value.sessionId -cne $Plan.sessionId) { throw 'The protected window title belongs to another session.' }
        return [string]$value.title
    }
    # A live legacy tab keeps its actual title until the user closes it normally.
    if ($Record.PSObject.Properties['windowTitle'] -and $Record.windowTitle) { return [string]$Record.windowTitle }
    return $Plan.windowTitle
}

function Test-BuddyWindowRecord {
    param(
        [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Record,
        [scriptblock]$TestProcess = { param($id, $birth) Test-BuddyProcessIdentity $id $birth },
        [scriptblock]$ReadWindow = { param($record, $title) Get-BuddyWindowState $record $title }
    )
    foreach ($field in @('sessionId','status','hostPid','hostStartedAt','windowHandle','windowPid','windowStartedAt')) {
        if (-not $Record.PSObject.Properties[$field]) { return $false }
    }
    try {
        if ($Record.sessionId -ne $Plan.sessionId -or $Record.status -ne 'ready' -or
            -not (& $TestProcess $Record.hostPid $Record.hostStartedAt) -or
            -not (& $TestProcess $Record.windowPid $Record.windowStartedAt)) { return $false }
        $state = & $ReadWindow $Record (Get-BuddyWindowRecordTitle $Plan $Record)
        if (-not $state -or $state.processId -ne $Record.windowPid -or -not $state.exactTarget) { return $false }
        if ($Record.PSObject.Properties['windowToken'] -and -not $state.marked) { return $false }
    } catch { return $false }
    return $true
}

function Get-BuddyTrackedWindow {
    param([Parameter(Mandatory)]$Plan)
    if (-not (Test-Path -LiteralPath $Plan.recordPath -PathType Leaf)) { return $null }
    try { $record = Get-Content -LiteralPath $Plan.recordPath -Raw | ConvertFrom-Json }
    catch { return $null }
    if (-not $record) { return $null }
    foreach ($field in @('sessionId','status','hostPid','hostStartedAt')) {
        if (-not $record.PSObject.Properties[$field]) { return $null }
    }
    try {
        if ($record.sessionId -ne $Plan.sessionId -or
            -not (Test-BuddyProcessIdentity $record.hostPid $record.hostStartedAt)) { return $null }
    } catch { return $null }
    if ($record.status -eq 'failed') { throw ("The session window could not start Copilot: " + $record.error) }
    if (Test-BuddyWindowRecord $Plan $record) { return $record }
    return $null
}

function Focus-BuddyTrackedWindow {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Record)
    if (-not (Test-BuddyWindowRecord $Plan $Record)) { return 'unavailable' }
    $window = [IntPtr]([long]$Record.windowHandle)
    if ([MyBuddy.TerminalNative]::WindowClass($window) -eq 'CASCADIA_HOSTING_WINDOW_CLASS') {
        $tab = Get-BuddyTerminalTab $window (Get-BuddyWindowRecordTitle $Plan $Record)
        if (-not $tab) { return 'unavailable' }
        try {
            # wt focus-tab only accepts a mutable numeric index. Select the exact UIA element
            # instead: tab reordering cannot redirect this to a different conversation.
            $selection = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $selection.Select()
            # Windows Terminal reports UIA selection asynchronously.
            for ($attempt = 0; $attempt -lt 20 -and -not $selection.Current.IsSelected; $attempt++) {
                Start-Sleep -Milliseconds 50
            }
            if (-not $selection.Current.IsSelected) { return 'unavailable' }
        } catch { return 'unavailable' }
    }
    if (-not (Test-BuddyWindowRecord $Plan $Record)) { return 'unavailable' }
    if ([MyBuddy.TerminalNative]::Focus($window)) { return 'focused' }
    return 'attention-requested'
}

function Test-BuddyTerminalLockAvailable {
    param([Parameter(Mandatory)][string]$Path)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    try {
        $probe = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
        return $true
    } catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -in @(32, 33)) { return $false }
        throw
    }
}

function Write-BuddyTerminalRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
    $temp = $Path + '.' + [Guid]::NewGuid() + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Record | ConvertTo-Json -Depth 6))
        [IO.File]::Move($temp, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Open-BuddyTerminalCore {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][scriptblock]$FindWindow,
        [Parameter(Mandatory)][scriptblock]$FindExternal,
        [Parameter(Mandatory)][scriptblock]$FocusWindow,
        [Parameter(Mandatory)][scriptblock]$LaunchWindow,
        [switch]$FocusOnly
    )
    $record = & $FindWindow $Plan
    if ($record) {
        $focusResult = & $FocusWindow $record
        $focusStatus = if ($focusResult -is [bool]) {
            if ($focusResult) { 'focused' } else { 'attention-requested' }
        } else { [string]$focusResult }
        $focused = $focusStatus -eq 'focused'
        if ($focusStatus -notin @('focused', 'attention-requested')) {
            return [pscustomobject]@{
                status = 'already-running'; sessionId = $Plan.sessionId; promptSubmitted = $false
                launchDefaults = $Plan.terminalDefaults; defaultsApplied = $false
                message = 'The saved session is open, but its exact tab could not be selected safely. Use the existing tab; no duplicate was opened.'
            }
        }
        $defaultsNote = if ($Plan.terminalDefaults) {
            ' Existing sessions keep their settings and window; after exiting the CLI yourself, reopen to apply new defaults, colors and tab grouping.'
        } else { '' }
        if ((Get-BuddyWindowRecordTitle $Plan $record) -cne $Plan.windowTitle) {
            $defaultsNote += ' Its saved work title will apply when you next close and reopen the CLI; this live tab was not renamed.'
        }
        return [pscustomobject]@{
            status = if ($focused) { 'focused' } else { 'attention-requested' }
            sessionId = $Plan.sessionId
            message = if ($focused) { 'Focused your exact saved Copilot session tab/window.' + $defaultsNote }
                else { 'Selected your existing session tab. Windows kept foreground focus elsewhere; its taskbar button has been highlighted.' + $defaultsNote }
            promptSubmitted = $false
            launchDefaults = $Plan.terminalDefaults
            defaultsApplied = $false
        }
    }
    $external = @(& $FindExternal ([Guid]$Plan.sessionId))
    if ($external.Count -or -not (Test-BuddyTerminalLockAvailable $Plan.activeLockPath)) {
        $orphaned = @($external | Where-Object { $_.PSObject.Properties['orphaned'] -and $_.orphaned })
        return [pscustomobject]@{
            status = 'already-running'; sessionId = $Plan.sessionId; promptSubmitted = $false
            launchDefaults = $Plan.terminalDefaults; defaultsApplied = $false
            message = if ($orphaned.Count) {
                "Copilot is still running after its parent terminal exited (PID $($orphaned.processId -join ', ')). Stop that leftover process before resuming this saved session. Buddy did not stop it or open a duplicate."
            } else { 'This Copilot session is already running outside a window Buddy can identify safely. Use its existing terminal or VS Code window; no duplicate was opened.' }
        }
    }
    if ($FocusOnly) {
        return [pscustomobject]@{
            status='unavailable'; sessionId=$Plan.sessionId; promptSubmitted=$false
            message='The linked native tab is unavailable. No replacement runtime or prompt was started.'
        }
    }
    if (-not $Plan.allowConcurrentSessions -and -not (Test-BuddyTerminalLockAvailable $Plan.checkoutLockPath)) {
        return [pscustomobject]@{
            status = 'checkout-busy'; sessionId = $Plan.sessionId; promptSubmitted = $false
            launchDefaults = $Plan.terminalDefaults; defaultsApplied = $false
            message = 'This checkout is already in use by another Buddy session/run. Finish that run first, or use a separate configured checkout. No duplicate runtime or tab was opened.'
        }
    }
    $opened = & $LaunchWindow $Plan
    [pscustomobject]@{
        status = 'opened'; sessionId = $Plan.sessionId; promptSubmitted = $false
        message = 'Opened the saved conversation in a Buddy terminal tab (or a console when Windows Terminal is unavailable). No message or task was submitted.'
        windowHandle = $opened.windowHandle
        launchDefaults = $Plan.terminalDefaults
        defaultsApplied = $true
    }
}
