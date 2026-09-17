#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Request','Pending','Dispatch','Claim','Commit','FailDispatch')][string]$Action,
    [string]$ScanId,
    [string]$DispatchToken,
    [string]$ErrorMessage,
    [string]$PayloadJson
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'portal\Portal.Client.ps1')
$connection = Get-BuddyPortalConnection
if (-not $connection) {
    if ($Action -eq 'Pending') { '{"available":false,"portalRunning":false}'; return }
    throw 'My Buddy portal is not running.'
}
$headers = @{ Authorization = 'Bearer ' + $connection.token; 'X-Buddy-Action' = '1' }
try {
    $route = switch ($Action) {
        Request { '/api/scan' }; Pending { '/api/scan/pending' }; Dispatch { '/api/scan/dispatch' }
        Claim { '/api/scan/claim' }; Commit { '/api/scan/commit' }; FailDispatch { '/api/scan/fail-dispatch' }
    }
    if ($Action -eq 'Pending') {
        $result = Invoke-RestMethod -Method Get -Uri ($connection.origin + $route) -Headers $headers
    } else {
        $body = switch ($Action) {
            Commit {
                if (-not $PayloadJson) { $PayloadJson = [Console]::In.ReadToEnd() }
                $PayloadJson | ConvertFrom-Json | Out-Null
                $PayloadJson
            }
            Dispatch { @{ scanId = $ScanId } | ConvertTo-Json -Compress }
            FailDispatch { @{ scanId = $ScanId; dispatchToken = $DispatchToken; error = $ErrorMessage } | ConvertTo-Json -Compress }
            default { '{}' }
        }
        $result = Invoke-RestMethod -Method Post -Uri ($connection.origin + $route) -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    }
    $result | ConvertTo-Json -Depth 40 -Compress
} finally { $headers.Clear() }
