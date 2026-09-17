#requires -Version 7.0
function Get-BuddyPortalConnection {
    $file = Join-Path $env:LOCALAPPDATA 'MyBuddy\portal\connection.dpapi'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $value = & (Join-Path $PSScriptRoot 'Protect-PortalData.ps1') -Operation read -Path $file | ConvertFrom-Json
    if ($value.origin -notmatch '^http://127\.0\.0\.1:[0-9]+$' -or $value.token -notmatch '^[a-f0-9]{64}$') {
        throw 'Invalid local portal connection information.'
    }
    try {
        $health = Invoke-RestMethod -Method Get -Uri ($value.origin + '/health') -TimeoutSec 3
        if ($health.application -ne 'My Buddy Portal') { throw 'Port is not serving My Buddy.' }
    } catch [System.Net.Http.HttpRequestException] {
        return $null
    } catch [System.Threading.Tasks.TaskCanceledException] {
        return $null
    }
    $packageProperty = $value.PSObject.Properties['packageDirectory']
    if (-not $packageProperty -or [string]::IsNullOrWhiteSpace([string]$packageProperty.Value)) {
        throw 'The running portal does not identify its installation. Close it normally before starting this copy.'
    }
    $expected = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\', '/')
    $actual = [IO.Path]::GetFullPath([string]$packageProperty.Value).TrimEnd('\', '/')
    if (-not [string]::Equals($expected, $actual, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Another My Buddy installation is already running at $actual. Use that copy, or close its portal normally before starting this one. No state was changed."
    }
    return $value
}
