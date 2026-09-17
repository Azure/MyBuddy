#requires -Version 7.2
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\Buddy.Agent.Core.ps1')
. (Join-Path $PSScriptRoot '..\Buddy.NativeTask.Support.ps1')
. (Join-Path $PSScriptRoot 'Buddy.PathSafety.ps1')

function Assert-BuddyPlainInput {
    param([string]$Value, [string]$Name, [switch]$Required)
    if (($Required -and [string]::IsNullOrWhiteSpace($Value)) -or
        $Value -match '[\p{Cc}\p{Cf}]' -or $Value.Length -gt 2048) {
        throw "$Name is missing or contains unsupported control characters/length."
    }
}

function Assert-BuddyNoLink {
    param([Parameter(Mandatory)][string]$Path)
    Assert-BuddySafePath $Path
}

function Invoke-BuddySetupProbe {
    param([string]$Command, [string[]]$Arguments, [string]$CliHome)
    $resolved = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
    if ($resolved.CommandType -notin @('Application','ExternalScript')) {
        throw "$Command must resolve to an executable or script, not an alias or function."
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($resolved.Source -match '\.ps1$') {
        $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        foreach ($arg in @('-NoProfile','-NonInteractive','-File',$resolved.Source) + $Arguments) { $start.ArgumentList.Add($arg) }
    } elseif ($resolved.Source -match '\.(cmd|bat)$') {
        # Only internal probe flags may reach cmd.exe, never arbitrary shell fragments.
        if ($resolved.Source -match '["%!\r\n]' -or @($Arguments | Where-Object { $_ -notmatch '^[a-zA-Z0-9_.=-]+$' }).Count) {
            throw 'Unsafe command-wrapper probe arguments.'
        }
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""' + $resolved.Source + '" ' + ($Arguments -join ' ') + '"'
    } else {
        $start.FileName = $resolved.Source
        foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    }
    if ($CliHome) { $start.Environment['COPILOT_HOME'] = $CliHome }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw "$Command read-only probe timed out."
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Command probe failed (exit $($process.ExitCode)); check this command manually." }
        [pscustomobject]@{ text = ($text + "`n" + $errorText).Trim(); path = $resolved.Source }
    } finally { $process.Dispose() }
}

function Get-BuddySetupPrerequisites {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Options)
    $checks = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $checks.Add([pscustomobject]@{name='Windows';required=$true;ok=[bool]$IsWindows;detail='Windows is required for DPAPI and native terminal handoff.';remediation='Use a Windows workstation.'})
    foreach ($probe in @(
        @{name='PowerShell';command='pwsh';args=@('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()');minimum=[version]'7.2';fix='winget install --id Microsoft.PowerShell --exact'},
        @{name='Node.js';command='node';args=@('--version');minimum=[version]'22.0';fix='winget install --id OpenJS.NodeJS.LTS --exact'},
        @{name='Git';command='git';args=@('--version');minimum=[version]'2.30';fix='winget install --id Git.Git --exact'},
        @{name='Azure CLI';command='az';args=@('version','--output','json');minimum=[version]'2.0';fix='winget install --id Microsoft.AzureCLI --exact'},
        @{name='Copilot CLI';command=$Options.CliCommand;args=@('--version');minimum=[version]'0.0';fix='Install/update your approved GitHub Copilot CLI distribution; then run copilot and sign in yourself.'}
    )) {
        try {
            $result = Invoke-BuddySetupProbe $probe.command $probe.args $Options.CliHome
            $versionText = if ($probe.name -eq 'Azure CLI') { ($result.text | ConvertFrom-Json).'azure-cli' } else { $result.text }
            if ($versionText -notmatch '(?<!\d)(\d+\.\d+(?:\.\d+)?)') { throw 'Version could not be determined.' }
            $version = [version]$Matches[1]
            if ($version -lt $probe.minimum) { throw "Version $version is below required $($probe.minimum)." }
            $checks.Add([pscustomobject]@{name=$probe.name;required=$true;ok=$true;detail="$version ($($result.path))";remediation=$null})
        } catch {
            $checks.Add([pscustomobject]@{name=$probe.name;required=$true;ok=$false;detail=$_.Exception.Message;remediation=$probe.fix})
        }
    }
    try {
        $help = (Invoke-BuddySetupProbe $Options.CliCommand @('--help') $Options.CliHome).text
        $requiredFlags = @('--experimental','--session-id','--context','--no-remote-export','--model','--mode','--no-auto-update')
        $missing = @($requiredFlags | Where-Object { $help -notmatch ([regex]::Escape($_) + '(?=[\s,=<\[]|$)') })
        if ($missing.Count) { throw "CLI help does not advertise required flags: $($missing -join ', ')." }
        $checks.Add([pscustomobject]@{name='CLI features';required=$true;ok=$true;detail=($requiredFlags -join ', ');remediation=$null})
    } catch {
        $checks.Add([pscustomobject]@{name='CLI features';required=$true;ok=$false;detail=$_.Exception.Message;remediation='Update the approved Copilot CLI; inspect copilot --help. No native-task fallback is enabled.'})
    }
    try {
        $config = [pscustomobject]@{cliCommand=$Options.CliCommand;cliHome=$Options.CliHome}
        $support = Get-BuddyNativeSupport -Config $config -RepositoryPath $Options.RepositoryPath
        $checks.Add([pscustomobject]@{name='Native extension SDK/policy';required=$true;ok=$true;detail="Read-only support hash: $($support.hash)";remediation=$null})
    } catch {
        $checks.Add([pscustomobject]@{name='Native extension SDK/policy';required=$true;ok=$false;detail=$_.Exception.Message;remediation='Use a CLI build with the extension SDK and ask your administrator about disabled extensions. Setup never installs an extension or changes policy.'})
    }
    try {
        $top = (Invoke-BuddySetupProbe 'git' @('-C',$Options.RepositoryPath,'rev-parse','--show-toplevel')).text
        if ([IO.Path]::GetFullPath($top).TrimEnd('\','/') -ine $Options.RepositoryPath.TrimEnd('\','/')) {
            throw 'RepositoryPath must be the root of an existing Git checkout, not a parent/subdirectory.'
        }
        $name = (Invoke-BuddySetupProbe 'git' @('-C',$Options.RepositoryPath,'config','user.name')).text
        $email = (Invoke-BuddySetupProbe 'git' @('-C',$Options.RepositoryPath,'config','user.email')).text
        if (-not $name -or $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'An effective Git user.name and valid user.email are required.' }
        if ($email -ine $Options.UserEmail) { $warnings.Add('Git user.email differs from the ADO user email. Verify this is intentional; neither identity was changed.') }
        $checks.Add([pscustomobject]@{name='Git checkout/identity';required=$true;ok=$true;detail='Existing checkout root and effective user.name/user.email verified read-only.';remediation=$null})
    } catch {
        $checks.Add([pscustomobject]@{name='Git checkout/identity';required=$true;ok=$false;detail=$_.Exception.Message;remediation='Use an existing checkout; set git -C <checkout> config user.name and user.email yourself. Setup does not clone, initialize, checkout or configure Git.'})
    }
    if ($Options.GitHubLogin) {
        try {
            $gh = Invoke-BuddySetupProbe 'gh' @('--version')
            if ($gh.text -notmatch '\bversion\s+2\.') { throw 'GitHub CLI 2.x is required.' }
            $checks.Add([pscustomobject]@{name='GitHub CLI';required=$true;ok=$true;detail=($gh.text -split "`n")[0];remediation=$null})
        } catch {
            $checks.Add([pscustomobject]@{name='GitHub CLI';required=$true;ok=$false;detail=$_.Exception.Message;remediation='winget install --id GitHub.cli --exact; then gh auth login yourself.'})
        }
    }
    $terminal = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $checks.Add([pscustomobject]@{name='Windows Terminal';required=$false;ok=[bool]$terminal;detail='Recommended for visible native sessions.';remediation='winget install --id Microsoft.WindowsTerminal --exact'})
    $warnings.Add('Authentication and model entitlement were not probed. Sign into Scout/M365, Azure CLI (az login --tenant <tenant-id>) and your chosen Copilot profile yourself; use gh auth login only if GitHub is enabled.')
    if ($Options.AllowConcurrentSessions) { $warnings.Add('Concurrent distinct sessions are opted in. Sessions share the checkout, branch and working tree; coordinate edits manually. No worktree isolation or extra permission is granted.') }
    [pscustomobject]@{ready=(@($checks | Where-Object { $_.required -and -not $_.ok }).Count -eq 0);checks=@($checks);warnings=@($warnings);readOnly=$true;authenticationVerified=$false;scheduleRegistered=$false}
}

function ConvertTo-BuddySetupOptions {
    param([System.Collections.IDictionary]$Options, [string]$PackageRoot)
    $value = @{
        Agent='';Alias='primary';CliCommand='copilot';CliHome='~\.copilot';McpConfigPath='';InitScript=''
        TimeZone=[TimeZoneInfo]::Local.Id;DailyAt='09:00';EmailFolderId='';Model='claude-opus-4.8';Context='default'
        GitHubLogin='';GitHubRepositories=@();AllowConcurrentSessions=$false;CreateDesktopShortcut=$false;Destination=$PackageRoot
        RepositoryPath='';RepositoryName='';Organization='';Project='';TenantId='';UserEmail=''
    }
    foreach ($key in $Options.Keys) {
        if (-not $value.ContainsKey($key)) { throw "Unsupported setup input: $key" }
        if ($key -in @('AllowConcurrentSessions','CreateDesktopShortcut')) {
            if ($Options[$key] -isnot [bool]) { throw "$key must be a JSON boolean." }
        } elseif ($key -eq 'GitHubRepositories') {
            if ($null -eq $Options[$key] -or $Options[$key] -is [string] -or $Options[$key] -isnot [System.Collections.IEnumerable]) {
                throw 'GitHubRepositories must be an array of owner/repository strings.'
            }
            foreach ($repo in $Options[$key]) { if ($repo -isnot [string]) { throw 'GitHubRepositories must contain strings.' } }
        } elseif ($null -ne $Options[$key] -and $Options[$key] -isnot [string]) { throw "$key must be a string." }
        $value[$key] = $Options[$key]
    }
    foreach ($key in $value.Keys) {
        if ($value[$key] -is [string]) { Assert-BuddyPlainInput $value[$key] $key }
    }
    foreach ($key in @('RepositoryPath','RepositoryName','Organization','Project','TenantId','UserEmail','CliCommand','CliHome','Destination','TimeZone','DailyAt','Model')) {
        Assert-BuddyPlainInput $value[$key] $key -Required
    }
    foreach ($key in @('RepositoryPath','CliHome','Destination')) {
        $value[$key] = Resolve-BuddyPath $value[$key] (Get-Location).Path
        if (-not (Test-Path -LiteralPath $value[$key] -PathType Container)) { throw "$key must be an existing directory." }
    }
    Assert-BuddyNoLink $value.Destination
    if (-not (Test-Path -LiteralPath (Join-Path $value.Destination 'Start-BuddyPortal.ps1') -PathType Leaf)) {
        throw 'Destination must be an extracted My Buddy package directory (Start-BuddyPortal.ps1 is missing).'
    }
    if ($value.Alias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') { throw 'Invalid repository alias.' }
    if ($value.Organization -notmatch '^https://(dev\.azure\.com/[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+\.visualstudio\.com)/?$' -or
        $value.Project -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 _.-]*$' -or $value.RepositoryName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 _.-]*$') {
        throw 'Invalid Azure DevOps organization URL, project or repository name.'
    }
    $tenant = [guid]::Empty
    if (-not [guid]::TryParseExact($value.TenantId,'D',[ref]$tenant) -or $tenant -eq [guid]::Empty) { throw 'TenantId must be a nonempty tenant GUID.' }
    if ($value.UserEmail -notmatch '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$') { throw 'UserEmail must be your explicit ADO email address.' }
    [void][TimeZoneInfo]::FindSystemTimeZoneById($value.TimeZone)
    if ($value.DailyAt -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') { throw 'DailyAt must be local time in HH:mm format.' }
    if ($value.Model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' -or $value.Context -notin @('default','long_context')) { throw 'Invalid model or context selection.' }
    if ($value.EmailFolderId -and ($value.EmailFolderId -notmatch '^[a-zA-Z0-9_+/=-]{16,2048}$' -or
        $value.EmailFolderId -match '^(Inbox|Important|Drafts|Sent|Archive|Deleted)(/|$)')) { throw 'EmailFolderId must be the exact opaque folder ID, not a folder name or URL.' }
    if ($value.Agent -eq '__default_cli__') { $value.Agent = '' }
    if ($value.Agent) {
        if ($value.Agent -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_. -]*$') { throw 'Invalid existing agent identifier.' }
        $choices = @(Get-BuddyAgentChoices $value.RepositoryPath $value.CliHome)
        if ($value.Agent -notin $choices.id) { throw 'The selected agent does not exist in this repository or the chosen CLI profile.' }
    }
    foreach ($key in @('McpConfigPath','InitScript')) {
        if ($value[$key]) {
            $value[$key] = Resolve-BuddyPath $value[$key] (Get-Location).Path
            if (-not (Test-Path -LiteralPath $value[$key] -PathType Leaf)) { throw "$key must be an existing file." }
        } else { $value[$key] = $null }
    }
    $mcpPaths = @((Join-Path $value.CliHome 'mcp-config.json'),(Join-Path $value.CliHome 'mcp_config.json'))
    if (-not $value.McpConfigPath) {
        $existing = @($mcpPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if ($existing.Count -gt 1) { throw 'Both MCP filenames exist; select McpConfigPath explicitly. Neither will be modified.' }
        if ($existing.Count -eq 1) { $value.McpConfigPath = $existing[0] }
    }
    if ($value.McpConfigPath) {
        $mcp = Get-Content -LiteralPath $value.McpConfigPath -Raw | ConvertFrom-Json -AsHashtable
        if (-not $mcp.ContainsKey('mcpServers') -or $mcp.mcpServers -isnot [System.Collections.IDictionary]) { throw 'McpConfigPath must use the Copilot CLI mcpServers object schema.' }
    }
    if ([bool]$value.GitHubLogin -ne ($value.GitHubRepositories.Count -gt 0)) { throw 'GitHub requires both an explicit login and a nonempty repository list, or neither.' }
    if ($value.GitHubLogin -and $value.GitHubLogin -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$') { throw 'Invalid GitHub login.' }
    foreach ($repo in $value.GitHubRepositories) {
        if ($repo -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -and
            $repo -notmatch '^[a-zA-Z0-9]/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'GitHub repositories must be explicit owner/repository names.' }
    }
    return $value
}

function Expand-BuddySetupTemplate {
    param([string]$Path, [System.Collections.IDictionary]$Tokens)
    $text = [IO.File]::ReadAllText($Path)
    # Match once so a replacement path containing token-like text is never reinterpreted.
    $text = [regex]::Replace($text, '__[A-Z_]+__', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if (-not $Tokens.Contains($match.Value)) { throw "Unknown onboarding template token: $($match.Value)" }
        return $Tokens[$match.Value]
    })
    return $text
}

function Get-BuddyShortcutPlan {
    param([string]$PackagePath, [string]$DesktopDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory))
    $desktop = $DesktopDirectory
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'Desktop directory is unavailable.' }
    Assert-BuddyNoLink $desktop
    $path = Join-Path $desktop 'My Buddy.lnk'
    if (Test-Path -LiteralPath $path) { throw 'My Buddy.lnk already exists; no shortcut will be overwritten.' }
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    [pscustomobject]@{path=$path;target=$pwsh;arguments=('-NoProfile -File "' + (Join-Path $PackagePath 'Start-BuddyPortal.ps1') + '" -Open');workingDirectory=$PackagePath}
}

function New-BuddySetupPlan {
    param([System.Collections.IDictionary]$Options, [string]$PackageRoot, [switch]$ReadOnly)
    $options = ConvertTo-BuddySetupOptions $Options $PackageRoot
    $names = @('buddy.agent.json','buddy.config.json','Scout-Setup.txt','Scan-Automation.txt')
    if (-not $ReadOnly) {
        foreach ($name in $names) {
            if (Test-Path -LiteralPath (Join-Path $options.Destination $name)) { throw "Personal setup file already exists ($name); no files were overwritten." }
        }
    }
    $agentConfig = Get-Content -LiteralPath (Join-Path $PackageRoot 'buddy.agent.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $agentConfig.cliCommand = $options.CliCommand
    $agentConfig.cliHome = $options.CliHome
    $agentConfig.primaryRepository = $options.Alias
    $agentConfig.sourceRoot = Split-Path $options.RepositoryPath -Parent
    $agentConfig.stateDirectory = Join-Path $options.Destination 'state\runs'
    $agentConfig.mcpConfigPath = $options.McpConfigPath
    $agentConfig.specifyPermissionMode = 'native'
    $agentConfig.allowConcurrentSessions = $options.AllowConcurrentSessions
    $agentConfig.terminalDefaults = @{model=$options.Model;context=$options.Context;mode='interactive';color=$true}
    $agentConfig.repositories = @{ $options.Alias = @{path=$options.RepositoryPath;agent=$options.Agent;initScript=$options.InitScript} }
    $briefing = Get-Content -LiteralPath (Join-Path $PackageRoot 'buddy.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $briefing.azureDevOps.organization = $options.Organization.TrimEnd('/')
    $briefing.azureDevOps.project = $options.Project
    $briefing.azureDevOps.repositories = @($options.RepositoryName)
    $briefing.azureDevOps.tenantId = $options.TenantId
    $briefing.azureDevOps.userEmail = $options.UserEmail
    $briefing.schedule = @{timeZone=$options.TimeZone;dailyAt=$options.DailyAt;enabled=$false;automationId=$null;registration='not-registered'}
    $briefing.email.folder = 'Inbox/Important'
    $briefing.email.folderId = if ($options.EmailFolderId) { $options.EmailFolderId } else { $null }
    $briefing.github.enabled = [bool]$options.GitHubLogin
    $briefing.github.login = if ($options.GitHubLogin) { $options.GitHubLogin } else { $null }
    $briefing.github.repositories = @($options.GitHubRepositories)
    foreach ($source in @('azureDevOps','github')) { $briefing[$source].delegation = @{enabled=$false;trustedCreators=@();trackedPullRequests=@()} }
    $files = [ordered]@{
        'buddy.agent.json' = ($agentConfig | ConvertTo-Json -Depth 20)
        'buddy.config.json' = ($briefing | ConvertTo-Json -Depth 20)
    }
    $tokens = @{
        '__PACKAGE_PATH__'=$options.Destination
        '__PORTAL_PATH__'=(Join-Path $options.Destination 'Start-BuddyPortal.ps1')
        '__TIME_ZONE__'=$options.TimeZone
        '__DAILY_AT__'=$options.DailyAt
    }
    $files['Scout-Setup.txt'] = Expand-BuddySetupTemplate (Join-Path $PackageRoot 'distribution\Scout.Onboarding.template.txt') $tokens
    $files['Scan-Automation.txt'] = Expand-BuddySetupTemplate (Join-Path $PackageRoot 'distribution\Scan.Automation.template.txt') $tokens
    $shortcut = if ($options.CreateDesktopShortcut) { Get-BuddyShortcutPlan $options.Destination } else { $null }
    $report = Get-BuddySetupPrerequisites $options
    if (-not $ReadOnly -and -not $report.ready) {
        $failures = @($report.checks | Where-Object { $_.required -and -not $_.ok } | ForEach-Object { "$($_.name): $($_.detail) Next: $($_.remediation)" })
        throw ("Prerequisites failed; no personal files were written.`n" + ($failures -join "`n"))
    }
    if ($report.ready) {
        $agentConfig.cliCommand = (Get-Command $options.CliCommand -ErrorAction Stop | Select-Object -First 1).Source
        $files['buddy.agent.json'] = $agentConfig | ConvertTo-Json -Depth 20
    }
    [pscustomobject]@{destination=$options.Destination;files=$files;shortcut=$shortcut;report=$report}
}

function Write-BuddySetupPlan {
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.report.ready) { throw 'Cannot apply a plan with failed prerequisites.' }
    $created = [Collections.Generic.List[string]]::new()
    $pendingShortcut = $null
    try {
        Assert-BuddyNoLink $Plan.destination
        foreach ($name in $Plan.files.Keys) {
            $path = Join-Path $Plan.destination $name
            $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $created.Add($path)
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Plan.files[$name] + "`n")
                $stream.Write($bytes,0,$bytes.Length)
                $stream.Flush($true)
            } finally { $stream.Dispose() }
        }
        if ($Plan.shortcut) {
            $pendingShortcut = Join-Path $Plan.destination ([guid]::NewGuid().ToString() + '.lnk')
            $shell = New-Object -ComObject WScript.Shell
            try {
                $link = $shell.CreateShortcut($pendingShortcut)
                $link.TargetPath = $Plan.shortcut.target
                $link.Arguments = $Plan.shortcut.arguments
                $link.WorkingDirectory = $Plan.shortcut.workingDirectory
                $link.Description = 'Open the local My Buddy portal'
                $link.Save()
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
            } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
            Assert-BuddyNoLink (Split-Path $Plan.shortcut.path -Parent)
            [IO.File]::Move($pendingShortcut,$Plan.shortcut.path,$false)
            $created.Add($Plan.shortcut.path)
        }
        [pscustomobject]@{
            files=@($created);scheduleEnabled=$false;scheduleRegistered=$false;credentialsCopied=$false
            portalStarted=$false;desktopShortcutCreated=[bool]$Plan.shortcut
            report=$Plan.report
            next='Read Scout-Setup.txt and review Scan-Automation.txt with Scout. Only supported Scout tools can register/confirm automations; JSON metadata does not schedule anything.'
        }
    } catch {
        foreach ($path in $created) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Continue } }
        throw
    } finally {
        if ($pendingShortcut -and (Test-Path -LiteralPath $pendingShortcut)) { Remove-Item -LiteralPath $pendingShortcut -Force -ErrorAction Continue }
    }
}
