#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('read', 'write')][string]$Operation,
    [Parameter(Mandatory)][string]$Path
)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if (-not $IsWindows) { throw 'This local portal uses Windows DPAPI for private state.' }
Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
$scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
if ($Operation -eq 'read') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Protected portal data does not exist.' }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, $scope)
    Write-Output ([Text.Encoding]::UTF8.GetString($bytes))
} else {
    $text = [Console]::In.ReadToEnd()
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($text), $null, $scope)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temp = $Path + '.' + [Guid]::NewGuid().ToString() + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    }
}
