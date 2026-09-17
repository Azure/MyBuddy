function Get-BuddyPrSignature {
    param($Value)
    function ConvertTo-BuddyCanonicalValue {
        param($InputValue)
        if ($null -eq $InputValue) { return $null }
        if ($InputValue -is [string] -or $InputValue -is [ValueType]) { return $InputValue }
        if ($InputValue -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($InputValue.Keys | Sort-Object -CaseSensitive)) { $result[$key] = ConvertTo-BuddyCanonicalValue $InputValue[$key] }
            return $result
        }
        if ($InputValue -is [pscustomobject]) {
            $result = [ordered]@{}
            foreach ($property in @($InputValue.PSObject.Properties | Sort-Object Name -CaseSensitive)) { $result[$property.Name] = ConvertTo-BuddyCanonicalValue $property.Value }
            return $result
        }
        if ($InputValue -is [System.Collections.IEnumerable] -and $InputValue -isnot [string]) {
            return ,@($InputValue | ForEach-Object { ConvertTo-BuddyCanonicalValue $_ })
        }
        return $InputValue
    }
    $json = ConvertTo-Json -InputObject (ConvertTo-BuddyCanonicalValue $Value) -Depth 80 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-BuddyPrScanWindow {
    param([DateTimeOffset]$AsOf, [Nullable[DateTimeOffset]]$Since, [int]$WindowDays)
    $requested = if ($null -ne $Since) { [DateTimeOffset]$Since } else { $AsOf.AddDays(-$WindowDays) }
    if ($requested -gt $AsOf) { throw 'Since must not be later than AsOf.' }
    $floor = $AsOf.AddDays(-7)
    $effective = if ($requested -lt $floor) { $floor } else { $requested }
    $overlap = $effective.AddSeconds(-60)
    if ($overlap -lt $floor) { $overlap = $floor }
    [pscustomobject]@{
        requestedSince = $requested.ToString('o'); since = $effective; querySince = $overlap
        lookbackCapped = $requested -lt $floor; gap = $requested -lt $floor
        overlapSeconds = [int]($effective - $overlap).TotalSeconds
    }
}

function New-BuddyPrScanCache {
    param([string]$CacheJson, [string]$Provider, $Scope, [DateTimeOffset]$AsOf, [switch]$Detail)
    $fingerprint = Get-BuddyPrSignature $Scope
    $cache = @{ version = 1; provider = $Provider; scopeFingerprint = $fingerprint; entries = @{}; bootstrapped = @{}; pending = @{} }
    $state = 'bootstrap'
    if ($Detail) { $state = 'detail-bypass' }
    elseif ($CacheJson) {
        try {
            $incoming = ConvertFrom-Json -InputObject $CacheJson -AsHashtable -Depth 80
            if ($incoming.version -eq 1 -and $incoming.provider -ceq $Provider -and
                $incoming.scopeFingerprint -ceq $fingerprint -and $incoming.entries -is [System.Collections.IDictionary]) {
                foreach ($key in $incoming.entries.Keys) {
                    $entry = $incoming.entries[$key]
                    if ($entry -isnot [System.Collections.IDictionary] -or $entry.repository -notin $Scope.repositories -or
                        $entry.pullRequestId -notmatch '^[1-9][0-9]*$' -or $entry.signature -notmatch '^[a-f0-9]{64}$' -or
                        $key -cne "$Provider`:$($entry.repository):$($entry.pullRequestId)") { throw 'Invalid cache entry.' }
                    $stamp = [DateTimeOffset]$entry.lastFullInspect
                    if ($stamp -gt $AsOf) { throw 'Cache observation is later than AsOf.' }
                    if ($entry.included -isnot [bool]) { throw 'Invalid cached ownership.' }
                    $clean = @{
                        repository = [string]$entry.repository; pullRequestId = [int]$entry.pullRequestId
                        signature = [string]$entry.signature; lastFullInspect = $stamp.ToString('o'); included = $entry.included
                    }
                    if ($Provider -eq 'ado') {
                        if ($entry.resources -isnot [System.Collections.IDictionary]) { throw 'Missing cached resources.' }
                        $clean.resources = @{}
                        foreach ($name in @('pr', 'threads', 'statuses', 'policies')) {
                            $resource = $entry.resources[$name]
                            if (-not $resource) { continue }
                            if ($resource.signature -notmatch '^[a-f0-9]{64}$') { throw 'Invalid resource signature.' }
                            $pages = @($resource.pages | ForEach-Object {
                                if ($_.signature -notmatch '^[a-f0-9]{64}$' -or [int]$_.count -lt 0) { throw 'Invalid resource page.' }
                                @{
                                    signature = [string]$_.signature; count = [int]$_.count
                                    etag = if ([string]$_.etag -cmatch '^(W/)?"[^"\r\n]{1,1000}"$') { [string]$_.etag } else { $null }
                                    continuation = if ($_.continuation) { [string]$_.continuation } else { $null }
                                }
                            })
                            $clean.resources[$name] = @{ signature = [string]$resource.signature; pages = $pages }
                        }
                        $clean.projectId = $entry['projectId']
                        $clean.inspectionKind = if ($entry['inspectionKind'] -eq 'attribution-only') { 'attribution-only' } else { 'full' }
                    } else { $clean.roles = @($entry['roles'] | Where-Object { $_ -in @('authored', 'assigned', 'review-requested', 'reviewed', 'delegated', 'tracked') }) }
                    $clean.state = $entry['state']
                    $cache.entries[$key] = $clean
                }
                $state = 'reused'
                if ($incoming.bootstrapped -is [System.Collections.IDictionary]) {
                    foreach ($repo in $Scope.repositories) {
                        $cache.bootstrapped[$repo] = $incoming.bootstrapped[$repo] -eq $true
                    }
                }
                if ($incoming.pending -is [System.Collections.IDictionary]) {
                    foreach ($key in $incoming.pending.Keys) {
                        $entry = $incoming.pending[$key]
                        if ($entry.repository -in $Scope.repositories -and $entry.pullRequestId -match '^[1-9][0-9]*$' -and
                            $key -ceq "$Provider`:$($entry.repository):$($entry.pullRequestId)") {
                            $cache.pending[$key] = @{ repository = [string]$entry.repository; pullRequestId = [int]$entry.pullRequestId }
                        }
                    }
                }
            } else { $state = 'scope-mismatch-bootstrap' }
        } catch { $state = 'invalid-cache-bootstrap'; $cache.entries.Clear(); $cache.bootstrapped.Clear(); $cache.pending.Clear() }
    }
    [pscustomobject]@{ cache = $cache; state = $state }
}

function Test-BuddyPrFutureEvidence {
    param($Value, [DateTimeOffset]$AsOf)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $false }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        foreach ($item in $Value) { if (Test-BuddyPrFutureEvidence $item $AsOf) { return $true } }
        return $false
    }
    $properties = if ($Value -is [System.Collections.IDictionary]) {
        @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Value[$_] } })
    } else { @($Value.PSObject.Properties) }
    foreach ($property in $properties) {
        if ($property.Name -in @('createdAt', 'updatedAt', 'submittedAt', 'publishedDate', 'lastUpdatedDate', 'lastContentUpdatedDate', 'creationDate', 'closedDate') -and $property.Value) {
            $stamp = [DateTimeOffset]::MinValue
            if ($property.Value -is [DateTime] -or $property.Value -is [DateTimeOffset]) { $stamp = [DateTimeOffset]$property.Value }
            else { $null = [DateTimeOffset]::TryParse([string]$property.Value, [ref]$stamp) }
            if ($stamp -gt $AsOf) { return $true }
        }
        if (Test-BuddyPrFutureEvidence $property.Value $AsOf) { return $true }
    }
    return $false
}
