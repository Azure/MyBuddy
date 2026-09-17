function Get-BuddyNativePolicy {
    param([Parameter(Mandatory)]$Config, [ValidateSet('native','full')][string]$PermissionMode = 'native')
    $configured = if ($Config.PSObject.Properties['terminalDefaults']) { $Config.terminalDefaults } else {
        [pscustomobject]@{model='claude-opus-4.8';context='long_context';mode='autopilot';color=$true}
    }
    if ($configured.model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or
        $configured.context -notin @('default','long_context') -or
        $configured.mode -notin @('interactive','plan','autopilot') -or $configured.color -isnot [bool]) {
        throw 'Invalid native terminal defaults.'
    }
    $defaults = $configured.PSObject.Copy()
    if ($PermissionMode -eq 'native' -and $defaults.mode -eq 'autopilot') { $defaults.mode = 'interactive' }
    [pscustomobject][ordered]@{
        version = 1
        permissionMode = $PermissionMode
        toolScope = 'all-native'
        configuredMode = $configured.mode
        effectiveMode = $defaults.mode
        terminalDefaults = $defaults
        explanation = if ($PermissionMode -eq 'full') {
            'All normal built-in and MCP tools; explicit full tool auto-approval for this session, including Continue. Publication still requires separate approval.'
        } elseif ($configured.mode -eq 'autopilot') {
            'Interactive replaces autopilot so native permission prompts can wait for you. All normal built-in and MCP tools remain available; no blanket approval.'
        } else {
            'All normal built-in and MCP tools with native permission prompts; no blanket approval.'
        }
        resumeNote = if ($PermissionMode -eq 'full') {
            'Continue retains this explicitly approved full tool auto-approval in this exact session; it does not authorize publication or other sessions.'
        } else {
            'Continue retains native permission prompting in this exact session, without replaying the task.'
        }
    }
}

function Get-BuddySavedNativePolicy {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][Guid]$SessionId)
    $fallback = Get-BuddyNativePolicy $Config
    $path = Join-Path $Config.stateDirectory "native\$SessionId.dpapi"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $fallback }
    $ticket = ConvertFrom-BuddyProtectedValue ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)))
    if (-not $ticket.PSObject.Properties['plan']) { return $fallback }
    $saved = $ticket.plan
    # Older records without an explicit session-scoped policy get normal prompts, never inferred approval.
    if (-not $saved.PSObject.Properties['nativePolicy']) { return $fallback }
    foreach ($field in @('sessionId','repository','cliHome','workingDirectory','execution','permissionMode','mode','approvalHash','terminalDefaults')) {
        if (-not $saved.PSObject.Properties[$field]) { throw 'Incomplete saved native launch policy. No permission upgrade was applied.' }
    }
    if ($saved.sessionId -cne $SessionId.ToString() -or $saved.repository -cne $Repository -or
        (Resolve-BuddyPath $saved.cliHome) -ne (Resolve-BuddyPath $Config.cliHome) -or
        (Resolve-BuddyPath $saved.workingDirectory) -ne (Resolve-BuddyPath $Config.repositories.PSObject.Properties[$Repository].Value.path) -or
        $saved.execution -ne 'native-interactive' -or $saved.permissionMode -notin @('native','full') -or
        ($saved.permissionMode -eq 'full' -and $saved.mode -ne 'specify')) {
        throw 'The saved native launch policy does not belong to this session and checkout.'
    }
    $unsigned = $saved.PSObject.Copy()
    $unsigned.PSObject.Properties.Remove('approvalHash')
    if ((Get-BuddyHash ($unsigned | ConvertTo-Json -Depth 10 -Compress)) -cne $saved.approvalHash) {
        throw 'The saved native launch policy no longer matches its approved preview.'
    }
    $policy = $saved.nativePolicy
    if (-not $policy -or -not $policy.PSObject.Properties['version'] -or $policy.version -ne 1 -or
        -not $policy.PSObject.Properties['configuredMode']) { throw 'Unsupported saved native launch policy.' }
    $configured = $saved.terminalDefaults.PSObject.Copy()
    $configured.mode = $policy.configuredMode
    $expected = Get-BuddyNativePolicy ([pscustomobject]@{terminalDefaults=$configured}) $saved.permissionMode
    if (($policy | ConvertTo-Json -Depth 10 -Compress) -cne ($expected | ConvertTo-Json -Depth 10 -Compress) -or
        ($saved.terminalDefaults | ConvertTo-Json -Compress) -cne ($expected.terminalDefaults | ConvertTo-Json -Compress)) {
        throw 'Inconsistent saved native launch policy. No permission upgrade was applied.'
    }
    return $expected
}

function Get-BuddyNativeSupport {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$RepositoryPath)
    if (-not $IsWindows) { throw 'Visible native tasks require Windows.' }
    $cli = Get-Command $Config.cliCommand -ErrorAction Stop | Select-Object -First 1
    $folder = Split-Path $cli.Source -Parent
    $candidates = @((Join-Path $folder 'node_modules\@github\copilot'), (Join-Path $folder '..\copilot'), $folder)
    $ancestor = $folder
    for ($i=0; $i -lt 5; $i++) {
        $ancestor = Split-Path $ancestor -Parent
        if (-not $ancestor) { break }
        $candidates += $ancestor
    }
    $distribution = $candidates | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ 'copilot-sdk\extension.js') -PathType Leaf
    } | Select-Object -First 1
    if (-not $distribution) { throw 'The installed CLI has no supported Copilot extension SDK. Native task startup is unavailable; no hidden fallback will run.' }
    $sdk = Join-Path $distribution 'copilot-sdk\extension.js'
    # Do not override an administrator/user disabling extensions.
    $settingsFiles = @((Join-Path $Config.cliHome 'settings.json'), (Join-Path $Config.cliHome 'config.json'))
    foreach ($relative in @('.github\copilot\settings.json','.github\copilot\settings.local.json','.claude\settings.json','.claude\settings.local.json')) {
        $settingsFiles += Join-Path $RepositoryPath $relative
    }
    foreach ($settings in $settingsFiles) {
        if (Test-Path -LiteralPath $settings) {
            $value = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            if ($value.PSObject.Properties['extensions'] -and
                (($value.extensions.PSObject.Properties['mode'] -and $value.extensions.mode -eq 'disabled') -or
                ($value.extensions.PSObject.Properties['disabledExtensions'] -and
                    $value.extensions.disabledExtensions -contains 'user:mybuddy-approved-task'))) {
                throw 'The native profile disables Buddy/extensions. Enable it yourself before previewing this task.'
            }
        }
    }
    [pscustomobject]@{
        hash = Get-BuddyHash ((Get-FileHash -LiteralPath $sdk).Hash + '|' +
            (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Buddy.NativeTask.Extension.mjs')).Hash + '|' +
            (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Receive-BuddyNativeTask.ps1')).Hash)
    }
}
