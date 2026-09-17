<#
.SYNOPSIS
Validate this Windows pilot and create new personal configuration; never overwrite.
.DESCRIPTION
Use Setup-Buddy.ps1 for interactive onboarding. This entry point accepts explicit
inputs and performs the same read-only prerequisites and transactional writes.
No sign-in, installation, repository change, portal launch or Scout registration
is performed. Destination must be an extracted My Buddy package directory.
#>
#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [Parameter(Mandatory)][string]$RepositoryName,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$UserEmail,
    [string]$Agent = '',
    [string]$Alias = 'primary',
    [string]$CliCommand = 'copilot',
    [string]$CliHome = '~\.copilot',
    [string]$McpConfigPath,
    [string]$InitScript,
    [string]$TimeZone = [TimeZoneInfo]::Local.Id,
    [string]$DailyAt = '09:00',
    [string]$EmailFolderId,
    [string]$Model = 'claude-opus-4.8',
    [ValidateSet('default','long_context')][string]$Context = 'default',
    [string]$GitHubLogin,
    [string[]]$GitHubRepositories = @(),
    [switch]$AllowConcurrentSessions,
    [switch]$CreateDesktopShortcut,
    [string]$Destination = $PSScriptRoot,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'distribution\Buddy.Setup.Core.ps1')
$options = @{}
foreach ($name in @('RepositoryPath','RepositoryName','Organization','Project','TenantId','UserEmail',
    'Agent','Alias','CliCommand','CliHome','McpConfigPath','InitScript','TimeZone','DailyAt',
    'EmailFolderId','Model','Context','GitHubLogin','GitHubRepositories','Destination')) {
    $options[$name] = Get-Variable -Name $name -ValueOnly
}
$options.AllowConcurrentSessions = [bool]$AllowConcurrentSessions
$options.CreateDesktopShortcut = [bool]$CreateDesktopShortcut
$plan = New-BuddySetupPlan -Options $options -PackageRoot $PSScriptRoot -ReadOnly:$ValidateOnly
if ($ValidateOnly) {
    $plan.report | ConvertTo-Json -Depth 10
    return
}
Write-BuddySetupPlan $plan | ConvertTo-Json -Depth 10
