<#
.SYNOPSIS
Import a Scout briefing into the current user's private local portal.
.DESCRIPTION
Pass JSON through -BriefingJson or stdin. This updates the user's local UI only.
No source data is written to plaintext files. The portal saves Windows-encrypted
state. Use -ReadState to inspect feedback and job results without changing them.
#>
#requires -Version 7.0
[CmdletBinding()]
param([string]$BriefingJson, [switch]$ReadState)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'portal\Portal.Client.ps1')
$connection = Get-BuddyPortalConnection
if (-not $connection) { throw 'My Buddy Portal is not running. Start-BuddyPortal.ps1 -Open starts it.' }
$headers = @{ Authorization = 'Bearer ' + $connection.token; 'X-Buddy-Action' = '1' }
try {
    if ($ReadState) {
        $result = Invoke-RestMethod -Method Get -Uri ($connection.origin + '/api/state') -Headers $headers
        $result | ConvertTo-Json -Depth 30 -Compress
        return
    }
    if (-not $BriefingJson) { $BriefingJson = [Console]::In.ReadToEnd() }
    $BriefingJson | ConvertFrom-Json | Out-Null
    $result = Invoke-RestMethod -Method Post -Uri ($connection.origin + '/api/ingest') `
        -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($BriefingJson))
    $result | ConvertTo-Json -Compress
} finally { $headers.Clear() }
