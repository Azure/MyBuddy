#requires -Version 7.2
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Buddy.PathSafety.ps1')

function Get-BuddyPackageFiles {
    $runtime = @(
        '.gitignore',
        'Buddy.Core.ps1','Buddy.PullRequests.Core.ps1','Buddy.GitHub.Core.ps1','Buddy.PrScan.Core.ps1',
        'Get-BuddyPullRequests.ps1','Get-BuddyGitHubPullRequests.ps1',
        'Buddy.Agent.Core.ps1','Buddy.Terminal.Core.ps1','Buddy.Terminal.Host.ps1','Buddy.Terminal.Native.cs',
        'Buddy.NativeTask.Core.ps1','Buddy.NativeTask.Support.ps1','Buddy.NativeTask.Extension.mjs',
        'Invoke-BuddyAgent.ps1','Invoke-BuddyCli.ps1','Open-BuddySession.ps1','Receive-BuddyNativeTask.ps1',
        'Start-BuddyPortal.ps1','Sync-BuddyPortal.ps1','Invoke-BuddyScan.ps1','Scan.Worker.txt',
        'portal\index.html','portal\buddy-logo.svg','portal\server.mjs','portal\scan.mjs',
        'portal\Invoke-PortalBridge.ps1','portal\Portal.Client.ps1','portal\Protect-PortalData.ps1',
        'buddy.example.json','buddy.agent.example.json','Initialize-Buddy.ps1','Setup-Buddy.ps1','Export-Buddy.ps1',
        'distribution\Buddy.Setup.Core.ps1','distribution\Buddy.Package.Core.ps1','distribution\Buddy.PathSafety.ps1',
        'distribution\setup.answers.example.json',
        'distribution\Scout.Onboarding.template.txt','distribution\Scan.Automation.template.txt',
        'distribution\HELP.txt','distribution\scout-integration.txt'
    )
    foreach ($path in $runtime) { [pscustomobject]@{source=$path;entry=$path.Replace('\','/')} }
    [pscustomobject]@{source='distribution\HELP.txt';entry='HELP.txt'}
    [pscustomobject]@{source='distribution\scout-integration.txt';entry='scout-integration.txt'}
}

function Assert-BuddyPackagePath {
    param([string]$Path)
    Assert-BuddySafePath $Path
}

function Get-BuddyPackagePayload {
    param([string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    Assert-BuddyPackagePath $rootPath
    $files = @(Get-BuddyPackageFiles | Sort-Object -Property entry -CaseSensitive)
    if (@($files.entry | Select-Object -Unique).Count -ne $files.Count) { throw 'Duplicate package entry.' }
    $payload = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if ($file.source -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::IsPathRooted($file.source) -or
            $file.entry -match '(^|/)\.\.(/|$)' -or $file.entry.StartsWith('/')) { throw 'Unsafe allowlist path.' }
        $path = [IO.Path]::GetFullPath((Join-Path $rootPath $file.source))
        if (-not $path.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package source escapes its root.' }
        Assert-BuddyPackagePath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package source: $($file.source)" }
        $bytes = [IO.File]::ReadAllBytes($path)
        $payload.Add([pscustomobject]@{
            entry=$file.entry;bytes=$bytes;size=$bytes.Length
            sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        })
    }
    return @($payload)
}
