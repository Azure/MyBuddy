<#
.SYNOPSIS
Create a clean allowlisted Windows pilot ZIP with deterministic entry hashes.
.DESCRIPTION
Only distribution HELP/integration documents are mapped to the ZIP root.
Personal configs, accounts, state, tests, media and caches are never copied.
The manifest covers every other ZIP entry; it cannot hash itself. Fixed entry
times, ordering and metadata make repeated exports reproducible on the same runtime.
#>
#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'distribution\Buddy.Package.Core.ps1')
$target = [IO.Path]::GetFullPath($Destination)
if ([IO.Path]::GetExtension($target) -ine '.zip') { throw 'Export Destination must be a .zip file.' }
if (Test-Path -LiteralPath $target) { throw 'Export destination already exists; refusing to overwrite it.' }
Assert-BuddyPackagePath $target
if (-not (Test-Path -LiteralPath (Split-Path $target -Parent) -PathType Container)) { throw 'Export parent directory must already exist.' }
$payload = @(Get-BuddyPackagePayload $PSScriptRoot)
$manifest = [ordered]@{
    formatVersion=1
    package='My Buddy Windows pilot'
    hashAlgorithm='SHA256'
    scope='All ZIP entries except package.manifest.json itself. Integrity is not publisher authentication.'
    files=@($payload | ForEach-Object { [ordered]@{path=$_.entry;size=$_.size;sha256=$_.sha256} })
}
$manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 6) + "`n")
$stream = $null
$archive = $null
$created = $false
try {
    $stream = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $created = $true
    $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    foreach ($item in @($payload) + @([pscustomobject]@{entry='package.manifest.json';bytes=$manifestBytes})) {
        $entry = $archive.CreateEntry($item.entry,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
        $entry.ExternalAttributes = 0
        $output = $entry.Open()
        try { $output.Write($item.bytes,0,$item.bytes.Length) } finally { $output.Dispose() }
    }
    $archive.Dispose()
    $archive = $null
    $stream.Flush($true)
    $stream.Dispose()
    $stream = $null
    [pscustomobject]@{archive=$target;files=@($payload.entry);manifest='package.manifest.json';personalDataIncluded=$false;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json -Depth 4
} catch {
    if ($archive) { $archive.Dispose(); $archive = $null }
    if ($stream) { $stream.Dispose(); $stream = $null }
    if ($created) { Remove-Item -LiteralPath $target -Force -ErrorAction Continue }
    throw
} finally {
    if ($archive) { $archive.Dispose() }
    if ($stream) { $stream.Dispose() }
}
