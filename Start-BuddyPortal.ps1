<#
.SYNOPSIS
Start the local My Buddy portal, or open its authenticated browser view.
.EXAMPLE
.\Start-BuddyPortal.ps1 -Open
#>
#requires -Version 7.0
[CmdletBinding()]
param([switch]$Open, [switch]$Background)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The private portal currently uses Windows-user DPAPI encryption.' }
foreach ($name in @('buddy.config.json', 'buddy.agent.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw 'Personal configuration is missing. Run Setup-Buddy.ps1 in this installation before opening My Buddy.'
    }
}
. (Join-Path $PSScriptRoot 'portal\Portal.Client.ps1')
$connection = Get-BuddyPortalConnection
if ($connection) {
    if ($Open) { Start-Process ($connection.origin + '/#key=' + $connection.token) }
    Write-Output "My Buddy Portal: $($connection.origin)"
    return
}
$node = (Get-Command node -ErrorAction Stop).Source
$server = Join-Path $PSScriptRoot 'portal\server.mjs'
if (-not $Open -and -not $Background) {
    & $node $server
    exit $LASTEXITCODE
}
$process = Start-Process -FilePath $node -ArgumentList ('"' + $server + '"') -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Seconds 1
    $process.Refresh()
    if ($process.HasExited) { throw "Portal startup failed with exit code $($process.ExitCode). Run without -Open to see the error." }
    $connection = Get-BuddyPortalConnection
    if ($connection -and $connection.pid -eq $process.Id) {
        if ($Open) { Start-Process ($connection.origin + '/#key=' + $connection.token) }
        Write-Output "My Buddy Portal: $($connection.origin)"
        return
    }
}
throw "Portal did not become ready in time (PID $($process.Id)); do not start duplicate servers."
