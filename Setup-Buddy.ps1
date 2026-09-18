<#
.SYNOPSIS
Interactive teammate setup for the Windows My Buddy pilot.
.EXAMPLE
.\Setup-Buddy.ps1
.EXAMPLE
.\Setup-Buddy.ps1 -NonInteractive -AnswersFile .\setup.answers.json
.EXAMPLE
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Setup-Buddy.ps1 -NonInteractive -RepositoryPath 'C:\src\repo' -RepositoryName 'repo' -Organization 'https://dev.azure.com/org' -Project 'project' -TenantId '00000000-0000-0000-0000-000000000001' -UserEmail 'user@example.com' -Alias 'primary' -CliCommand 'copilot' -CliHome '~\.copilot' -TimeZone 'UTC' -DailyAt '09:00' -Model 'claude-opus-4.8' -Context 'default' -DisableGitHub
.EXAMPLE
.\Setup-Buddy.ps1 -Doctor -AnswersFile .\setup.answers.json
.DESCRIPTION
AnswersFile is a JSON object with parameter names and explicit values (booleans
must be JSON booleans). Direct parameters override file values. Doctor is read-only.
Copy distribution\setup.answers.example.json to setup.answers.json, then fill the
six required empty fields and your existing CLI profile. Omitted TimeZone uses
the computer's local zone. Do not check your personal answers into source control.
No installers, sign-ins, repository operations, Scout registration or portal
startup are performed. Only explicitly requested desktop shortcuts are created.
#>
#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$AnswersFile,
    [switch]$NonInteractive,
    [switch]$Doctor,
    [string]$RepositoryPath,
    [string]$RepositoryName,
    [string]$Organization,
    [string]$Project,
    [string]$TenantId,
    [string]$UserEmail,
    [string]$Agent,
    [string]$Alias,
    [string]$CliCommand,
    [string]$CliHome,
    [string]$McpConfigPath,
    [string]$InitScript,
    [string]$TimeZone,
    [string]$DailyAt,
    [string]$EmailFolderId,
    [string]$Model,
    [ValidateSet('default','long_context')][string]$Context,
    [string]$GitHubLogin,
    [string[]]$GitHubRepositories,
    [switch]$DisableGitHub,
    [switch]$AllowConcurrentSessions,
    [switch]$CreateDesktopShortcut,
    [string]$Destination
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'distribution\Buddy.Setup.Core.ps1')
$answers = @{}
if ($AnswersFile) {
    $answersPath = Resolve-BuddyPath $AnswersFile (Get-Location).Path
    $answers = Get-Content -LiteralPath $answersPath -Raw | ConvertFrom-Json -AsHashtable
    if ($answers -isnot [System.Collections.IDictionary]) { throw 'AnswersFile must contain a JSON object, not an array or scalar.' }
}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -in @('AnswersFile','NonInteractive','Doctor','Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction',
        'ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable','DisableGitHub')) { continue }
    if ($key -in @('AllowConcurrentSessions','CreateDesktopShortcut')) {
        $answers[$key] = [bool]$PSBoundParameters[$key]
        continue
    }
    if ($key -eq 'GitHubRepositories' -and $null -eq $PSBoundParameters[$key]) {
        $answers[$key] = [string[]]@()
        continue
    }
    $answers[$key] = $PSBoundParameters[$key]
}
if ($DisableGitHub) {
    if ($PSBoundParameters.ContainsKey('GitHubLogin') -or $PSBoundParameters.ContainsKey('GitHubRepositories')) {
        throw 'DisableGitHub cannot be combined with GitHubLogin or GitHubRepositories.'
    }
    $answers.GitHubLogin = ''
    $answers.GitHubRepositories = [string[]]@()
}
function Read-SetupAnswer {
    param([string]$Name, [string]$Prompt, [string]$Default = '')
    if ($answers.Contains($Name)) { return }
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $response = Read-Host $label
    $answers[$Name] = if ([string]::IsNullOrWhiteSpace($response)) { $Default } else { $response.Trim() }
}
function Read-SetupConsent {
    param([string]$Name, [string]$Prompt)
    if ($answers.Contains($Name)) { return }
    $response = Read-Host "$Prompt [y/N]"
    if ($response -notmatch '^(?i:y|yes|n|no)?$') { throw 'Please answer y or n; setup has not written anything.' }
    $answers[$Name] = $response -match '^(?i:y|yes)$'
}
if (-not $NonInteractive -and -not $AnswersFile) {
    Write-Host 'My Buddy Windows pilot setup. No software, sign-ins, source changes or Scout automations will be installed.'
    Read-SetupAnswer RepositoryPath 'Existing Git checkout root'
    Read-SetupAnswer Organization 'Azure DevOps organization URL (https://dev.azure.com/your-org)'
    Read-SetupAnswer Project 'Azure DevOps project'
    Read-SetupAnswer RepositoryName 'Azure DevOps repository name'
    Read-SetupAnswer TenantId 'Azure tenant ID (GUID)'
    Read-SetupAnswer UserEmail 'Your Azure DevOps user email'
    Read-SetupAnswer Alias 'Local repository alias' 'primary'
    Read-SetupAnswer CliCommand 'Personal Copilot CLI executable/command (no arguments)' 'copilot'
    Read-SetupAnswer CliHome 'Your existing Copilot CLI profile directory' '~\.copilot'
    $repoPath = Resolve-BuddyPath $answers.RepositoryPath (Get-Location).Path
    $profilePath = Resolve-BuddyPath $answers.CliHome (Get-Location).Path
    if ((Test-Path -LiteralPath $repoPath -PathType Container) -and (Test-Path -LiteralPath $profilePath -PathType Container)) {
        Write-Host 'Available handlers (choose an existing XFE/custom agent ID, or leave empty for Default CLI):'
        Get-BuddyAgentChoices $repoPath $profilePath | ForEach-Object { Write-Host "  $($_.id): $($_.label)" }
    }
    Read-SetupAnswer Agent 'Existing agent ID; empty selects Default CLI'
    Read-SetupAnswer McpConfigPath 'Optional existing MCP configuration file; empty uses profile discovery'
    Read-SetupAnswer InitScript 'Optional existing environment initializer; never executed during setup'
    Read-SetupAnswer EmailFolderId 'Exact Important folder ID if already known; otherwise leave empty for Scout to resolve'
    Read-SetupAnswer TimeZone 'Daily scan time zone' ([TimeZoneInfo]::Local.Id)
    Read-SetupAnswer DailyAt 'Daily scan local time (HH:mm)' '09:00'
    Read-SetupAnswer Model 'Native Copilot model (entitlement not verified)' 'claude-opus-4.8'
    Read-SetupAnswer Context 'Context: default or long_context' 'default'
    if (-not $answers.Contains('GitHubLogin') -and -not $answers.Contains('GitHubRepositories')) {
        $github = Read-Host 'Enable optional GitHub PR reads? [y/N]'
        if ($github -match '^(?i:y|yes)$') {
            Read-SetupAnswer GitHubLogin 'Your explicit GitHub login'
            $repositories = Read-Host 'Explicit GitHub owner/repository names, comma-separated'
            $answers.GitHubRepositories = @($repositories.Split(',') | ForEach-Object { $_.Trim() })
        } elseif ($github -notmatch '^(?i:n|no)?$') { throw 'Please answer y or n; setup has not written anything.' }
    }
    Write-Host 'Concurrent sessions share the checkout, active branch and working tree. No isolation or extra approval is granted.'
    Read-SetupConsent AllowConcurrentSessions 'Opt in to concurrent distinct sessions?'
    if (-not $Doctor) { Read-SetupConsent CreateDesktopShortcut 'Create a My Buddy desktop shortcut?' }
}
# One initializer owns configuration construction, validation and writes for both entry points.
$normalized = ConvertTo-BuddySetupOptions $answers $PSScriptRoot
& (Join-Path $PSScriptRoot 'Initialize-Buddy.ps1') @normalized -ValidateOnly:$Doctor
