#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][DateTimeOffset]$AsOf,
    [Nullable[DateTimeOffset]]$Since,
    [string]$CacheJson,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'buddy.config.json'),
    [string]$Repository,
    [ValidateRange(1, 2147483647)][int]$PullRequestId,
    [switch]$IncludeComments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Buddy.Core.ps1')
. (Join-Path $PSScriptRoot 'Buddy.PrScan.Core.ps1')
$config = Get-BuddyConfig $ConfigPath
$settings = $config.azureDevOps
$userEmail = [string](Get-BuddyProperty $settings 'userEmail' '')
$projectPath = '/' + [Uri]::EscapeDataString($settings.project)
$detail = $PSBoundParameters.ContainsKey('PullRequestId')
if ($detail -and -not $Repository) { throw 'Repository is required with PullRequestId.' }
if ($Repository -and $Repository -cnotin $settings.repositories) { throw 'Repository is outside the configured scope.' }
$repositories = if ($Repository) { @($Repository) } else { @($settings.repositories) }
$window = Get-BuddyPrScanWindow -AsOf $AsOf -Since $Since -WindowDays $config.windowDays
$since = $window.since
$headers = @{}
$errors = [System.Collections.Generic.List[object]]::new()
$repoCoverage = [System.Collections.Generic.List[object]]::new()
$items = [System.Collections.Generic.List[object]]::new()
$maxPages = [int](Get-BuddyProperty $settings 'maxPages' 3)
$identity = $null
$metrics = @{ metadataReads = 0; skippedUnchangedPullRequests = 0; conditionalNotModified = 0; fullResourceReads = 0; descriptionReads = 0; threadBodyReads = 0 }

function Add-BuddyAdoFailure {
    param([string]$Operation, [string]$Repo, [int]$Id, $Failure)
    $response = Get-BuddyProperty $Failure.Exception 'Response'
    $status = Get-BuddyProperty $response 'StatusCode'
    $errors.Add([pscustomobject]@{
        repository = $Repo; pullRequestId = $Id; operation = $Operation
        error = if ($status) { "HTTP $([int]$status); access was not bypassed." } else { 'Read failed or returned incomplete/unexpected data; no source error body retained.' }
    })
}

function Invoke-BuddyAdoGet {
    param([string]$Path, [hashtable]$Query = @{}, [string]$ETag)
    $uri = New-BuddyAdoUri -Path $Path -Query $Query -Config $config
    $requestHeaders = @{} + $headers
    if ($ETag -cmatch '^(W/)?"[^"\r\n]{1,1000}"$') { $requestHeaders['If-None-Match'] = $ETag }
    $metrics.metadataReads++
    try { $response = Invoke-WebRequest -Method Get -Uri $uri -Headers $requestHeaders -MaximumRedirection 0 -TimeoutSec 60 }
    catch {
        if ([int](Get-BuddyProperty (Get-BuddyProperty $_.Exception 'Response') 'StatusCode' 0) -ne 304 -or -not $requestHeaders.ContainsKey('If-None-Match')) { throw }
        $metrics.conditionalNotModified++
        return [pscustomobject]@{ notModified = $true; etag = $ETag; data = $null; continuation = $null }
    }
    if ((Get-BuddyProperty $response 'StatusCode' 200) -eq 304) {
        if (-not $requestHeaders.ContainsKey('If-None-Match')) { throw 'Unexpected not-modified response.' }
        $metrics.conditionalNotModified++
        return [pscustomobject]@{ notModified = $true; etag = $ETag; data = $null; continuation = $null }
    }
    if ([string]$response.Headers['Content-Type'] -notmatch '^application/json') { throw 'Expected JSON.' }
    $metrics.fullResourceReads++
    if ($Path -match '/pullrequests/[0-9]+$') { $metrics.descriptionReads++ }
    if ($Path -match '/threads$') { $metrics.threadBodyReads++ }
    [pscustomobject]@{
        data = ([string]$response.Content).TrimStart([char]0xfeff) | ConvertFrom-Json
        notModified = $false
        etag = if ($response.Headers.ContainsKey('ETag')) { [string]($response.Headers['ETag'] -join '') } else { $null }
        continuation = if ($response.Headers.ContainsKey('x-ms-continuationtoken')) { [string]($response.Headers['x-ms-continuationtoken'] -join '') } else { $null }
    }
}

function Get-BuddyAdoResource {
    param([string]$Path, [hashtable]$Query, $Old, [switch]$SingleObject, [switch]$SinglePage)
    $found = [System.Collections.Generic.List[object]]::new()
    $pages = [System.Collections.Generic.List[object]]::new()
    $complete = $false
    $missingBodies = $false
    $continuation = $null
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    for ($page = 0; $page -lt $maxPages; $page++) {
        $q = @{} + $Query
        if (-not $SingleObject -and -not $SinglePage) { $q['$top'] = '100'; $q['$skip'] = [string]($page * 100) }
        if ($continuation) { $q['continuationToken'] = $continuation }
        $oldPage = if ($Old -and $page -lt @($Old.pages).Count) { $Old.pages[$page] } else { $null }
        $response = Invoke-BuddyAdoGet $Path $q $(if ($oldPage) { $oldPage.etag })
        if ($response.notModified) {
            if (-not $oldPage) { throw 'Missing cache validator state.' }
            $pages.Add($oldPage); $missingBodies = $true
            $count = [int]$oldPage.count; $continuation = $oldPage.continuation
        } else {
            if (-not $SingleObject -and $null -eq $response.data.PSObject.Properties['value']) { throw 'Missing resource collection.' }
            $batch = @(if ($SingleObject) { $response.data } else { $response.data.value })
            foreach ($entry in $batch) {
                $id = [string](Get-BuddyProperty $entry 'evaluationId' (Get-BuddyProperty $entry 'id' ''))
                if ($id -and -not $seen.Add($id)) { throw 'Repeated resource pagination item.' }
                $found.Add($entry)
            }
            $count = $batch.Count; $continuation = $response.continuation
            $pages.Add(@{ signature = Get-BuddyPrSignature $batch; etag = $response.etag; count = $count; continuation = $continuation })
        }
        if (-not $continuation -and ($SingleObject -or $SinglePage -or $count -lt 100)) { $complete = $true; break }
        if ($SingleObject -or $SinglePage) { break }
    }
    [pscustomobject]@{
        items = $found.ToArray(); complete = $complete; missingBodies = $missingBodies
        cache = @{ pages = $pages.ToArray(); signature = Get-BuddyPrSignature @($pages | ForEach-Object { $_.signature }) }
    }
}

function Get-BuddyAdoSafeResource {
    param([string]$Path, [hashtable]$Query, $Old, [string]$Repo, [string]$Operation, [int]$Id, [switch]$SinglePage)
    try { Get-BuddyAdoResource $Path $Query $Old -SinglePage:$SinglePage }
    catch {
        Add-BuddyAdoFailure $Operation $Repo $Id $_
        [pscustomobject]@{ items = @(); complete = $false; missingBodies = $false; cache = @{ pages = @(); signature = '' } }
    }
}

function Get-BuddyAdoCollection {
    param([string]$Path, [hashtable]$Query, [string]$Repo, [string]$Operation, [int]$Id = 0, [switch]$SinglePage)
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $complete = $false
    $continuation = $null
    $pages = 0
    try {
        for ($page = 0; $page -lt $maxPages; $page++) {
            $q = @{} + $Query
            if (-not $SinglePage) { $q['$top'] = '100'; $q['$skip'] = [string]($page * 100) }
            if ($continuation) { $q['continuationToken'] = $continuation }
            $result = Invoke-BuddyAdoGet $Path $q
            $pages++
            if ($null -eq $result.data.PSObject.Properties['value']) { throw 'Missing value collection.' }
            $batch = @($result.data.value)
            foreach ($entry in $batch) {
                $key = [string](Get-BuddyProperty $entry 'pullRequestId' (Get-BuddyProperty $entry 'evaluationId' (Get-BuddyProperty $entry 'id' '')))
                if ($key -and -not $seen.Add($key)) { throw 'Repeated pagination item.' }
                $found.Add($entry)
            }
            $continuation = $result.continuation
            if (-not $continuation -and ($SinglePage -or $batch.Count -lt 100)) { $complete = $true; break }
            if ($SinglePage) { break }
        }
    } catch { Add-BuddyAdoFailure $Operation $Repo $Id $_ }
    [pscustomobject]@{ items = $found.ToArray(); complete = $complete; pages = $pages }
}

function Get-BuddyAdoDiscovery {
    param([string]$Path, [string]$Filter, [string]$IdentityId, [string]$Repo, [string]$Operation)
    $active = Get-BuddyAdoCollection $Path @{
        'api-version' = '7.1'; 'searchCriteria.status' = 'active'; $Filter = $IdentityId
    } $Repo $Operation
    $closed = Get-BuddyAdoCollection $Path @{
        'api-version' = '7.1'; 'searchCriteria.status' = 'all'; $Filter = $IdentityId
        'searchCriteria.queryTimeRangeType' = 'closed'
        'searchCriteria.minTime' = $window.querySince.UtcDateTime.ToString('o')
        'searchCriteria.maxTime' = $AsOf.UtcDateTime.ToString('o')
    } $Repo "$Operation-closed-interval"
    [pscustomobject]@{ items = @($active.items) + @($closed.items); complete = $active.complete -and $closed.complete }
}

function Get-BuddyAdoEvidence {
    param($Pr, $ThreadResult, [string]$Path, $Statuses, $PolicyResult)
    $name = $Pr.repository.name
    $id = [int]$Pr.pullRequestId
    if (-not $Statuses) { $statuses = Get-BuddyAdoCollection "$Path/statuses" @{ 'api-version' = '7.1' } $name 'statuses' $id }
    $projectId = Get-BuddyProperty (Get-BuddyProperty $Pr.repository 'project') 'id'
    if (-not $PolicyResult) { $policyResult = [pscustomobject]@{ items = @(); complete = $false } }
    if ($projectId -and -not $PolicyResult.complete) {
        $policyResult = Get-BuddyAdoCollection "$projectPath/_apis/policy/evaluations" @{
            'api-version' = '7.1-preview.1'; artifactId = "vstfs:///CodeReview/CodeReviewId/$projectId/$id"
        } $name 'policy-evaluations' $id
    }
    $checks = @($statuses.items | ForEach-Object {
        [pscustomobject]@{
            name = [string](Get-BuddyProperty (Get-BuddyProperty $_ 'context') 'name' 'Unnamed status')
            state = [string](Get-BuddyProperty $_ 'state' 'unknown')
            required = $null
            url = Get-BuddyProperty $_ 'targetUrl'
        }
    })
    $policyItems = @($policyResult.items | ForEach-Object {
        $c = Get-BuddyProperty $_ 'configuration'
        [pscustomobject]@{
            name = Get-BuddyProperty (Get-BuddyProperty $c 'type') 'displayName' 'Unknown policy'
            state = Get-BuddyProperty $_ 'status' 'unknown'
            required = (Get-BuddyProperty $c 'isEnabled') -eq $true -and (Get-BuddyProperty $c 'isBlocking') -eq $true
            configurationKnown = $null -ne (Get-BuddyProperty $c 'isEnabled') -and $null -ne (Get-BuddyProperty $c 'isBlocking')
        }
    })
    $requiredPolicies = @($policyItems | Where-Object required)
    $policyState = if (-not $policyResult.complete -or @($policyItems | Where-Object { -not $_.configurationKnown }).Count) { 'unknown' }
        elseif (@($requiredPolicies | Where-Object state -eq 'rejected').Count) { 'failed' }
        elseif (@($requiredPolicies | Where-Object state -in @('queued', 'running', 'broken')).Count) { 'pending' }
        elseif (@($requiredPolicies | Where-Object state -notin @('approved', 'notApplicable')).Count) { 'unknown' }
        else { 'passed' }
    $checkState = if (-not $statuses.complete -or -not $policyResult.complete) { 'unknown' }
        elseif (@($checks | Where-Object state -in @('failed', 'error')).Count) { 'failed' }
        elseif (@($checks | Where-Object state -eq 'pending').Count) { 'pending' }
        elseif (@($checks | Where-Object state -notin @('succeeded', 'notApplicable')).Count) { 'unknown' }
        else { 'passed' }
    $reviewers = @(Get-BuddyProperty $Pr 'reviewers' @())
    $approvalsState = if (@($reviewers | Where-Object { $_.vote -lt 0 }).Count) { 'failed' }
        elseif (@($reviewers | Where-Object { (Get-BuddyProperty $_ 'isRequired' $false) -and $_.vote -notin @(5, 10) }).Count) { 'pending' }
        elseif ($null -eq $Pr.PSObject.Properties['reviewers'] -or $policyState -ne 'passed') { 'unknown' } else { 'passed' }
    $stable = $false
    try {
        $latest = (Invoke-BuddyAdoGet $Path @{ 'api-version' = '7.1' }).data
        $head = Get-BuddyProperty (Get-BuddyProperty $Pr 'lastMergeSourceCommit') 'commitId'
        $base = Get-BuddyProperty (Get-BuddyProperty $Pr 'lastMergeTargetCommit') 'commitId'
        $stable = $head -and $base -and
            $head -eq (Get-BuddyProperty (Get-BuddyProperty $latest 'lastMergeSourceCommit') 'commitId') -and
            $base -eq (Get-BuddyProperty (Get-BuddyProperty $latest 'lastMergeTargetCommit') 'commitId') -and
            $Pr.status -eq $latest.status -and (Get-BuddyProperty $Pr 'isDraft') -eq (Get-BuddyProperty $latest 'isDraft') -and
            (Get-BuddyProperty $Pr 'mergeStatus') -eq (Get-BuddyProperty $latest 'mergeStatus') -and
            (Get-BuddyPrSignature $Pr) -ceq (Get-BuddyPrSignature $latest)
    } catch { Add-BuddyAdoFailure 'head-revalidation' $name $id $_ }
    $mergeStatus = [string](Get-BuddyProperty $Pr 'mergeStatus' 'unknown')
    [pscustomobject]@{
        headStable = [bool]$stable; threadsComplete = $ThreadResult.complete
        conflicts = if ($mergeStatus -eq 'succeeded') { 'clear' } elseif ($mergeStatus -eq 'conflicts') { 'conflicting' } else { 'unknown' }
        checks = [pscustomobject]@{ state = $checkState; coverage = if ($statuses.complete) { 'complete' } else { 'partial' }; items = $checks; requirementsSource = 'policy-evaluations' }
        policies = [pscustomobject]@{ state = $policyState; coverage = if ($policyResult.complete) { 'complete' } else { 'partial' }; items = $policyItems }
        approvals = [pscustomobject]@{
            state = $approvalsState; coverage = if ($policyResult.complete) { 'complete' } else { 'partial' }
            approved = @($reviewers | Where-Object vote -in @(5, 10)).Count
            requiredPending = @($reviewers | Where-Object { (Get-BuddyProperty $_ 'isRequired' $false) -and $_.vote -notin @(5, 10) }).Count
        }
    }
}

try {
    try {
        $az = Get-BuddyExecutable 'az' 'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        $tokenArguments = @('account', 'get-access-token', '--resource', '499b84ac-1321-427f-aa17-267ca6975798', '--output', 'json', '--only-show-errors')
        $tenantId = Get-BuddyProperty $settings 'tenantId'
        if ($tenantId) { $tokenArguments += @('--tenant', $tenantId) }
        $tokenJson = & $az @tokenArguments 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'ADO authentication failed.' }
        $token = (([string]($tokenJson -join "`n")).TrimStart([char]0xfeff) | ConvertFrom-Json).accessToken
        if (-not $token) { throw 'No token.' }
        $headers.Authorization = "Bearer $token"
        $headers.Accept = 'application/json'
        Remove-Variable token, tokenJson
        $identity = (Invoke-BuddyAdoGet '/_apis/connectionData').data
        $userId = [string]$identity.authenticatedUser.id
        if (-not $userId -or $userId -eq [Guid]::Empty.ToString()) { throw 'No authenticated identity.' }
    } catch { $identity = $null; Add-BuddyAdoFailure 'authentication/identity' '' 0 $_ }
    $cacheState = New-BuddyPrScanCache -CacheJson $CacheJson -Provider 'ado' -AsOf $AsOf -Detail:$detail -Scope @{
        repositories = @($repositories); settings = $settings
        authenticatedUser = Get-BuddyProperty (Get-BuddyProperty $identity 'authenticatedUser') 'id'
        briefingFilters = Get-BuddyProperty $config 'briefingFilters'; windowDays = $config.windowDays
    }
    $cache = $cacheState.cache
    foreach ($name in $repositories) {
        $repoStartErrors = $errors.Count
        $discovery = [System.Collections.Generic.List[object]]::new()
        $discoveryComplete = $true
        $selected = @()
        $omitted = 0
        if (-not $identity) {
            $repoCoverage.Add([pscustomobject]@{ repository = $name; status = 'unavailable'; discovered = 0; inspected = 0; omitted = 0 })
            continue
        }
        $repoPath = "$projectPath/_apis/git/repositories/$([Uri]::EscapeDataString($name))/pullrequests"
        if ($detail) { $discovery.Add([pscustomobject]@{ pullRequestId = $PullRequestId; creationDate = $AsOf.ToString('o') }) }
        else {
            foreach ($filter in @('searchCriteria.creatorId', 'searchCriteria.reviewerId')) {
                $result = Get-BuddyAdoDiscovery $repoPath $filter $userId $name $filter
                foreach ($pr in $result.items) { $discovery.Add($pr) }
                if (-not $result.complete) { $discoveryComplete = $false }
            }
            $delegation = Get-BuddyProperty $settings 'delegation'
            if (Get-BuddyProperty $delegation 'enabled' $false) {
                foreach ($creator in @(Get-BuddyProperty $delegation 'trustedCreators' @())) {
                    $all = Get-BuddyAdoDiscovery $repoPath 'searchCriteria.creatorId' $creator $name 'delegated-discovery'
                    if (-not $all.complete) { $discoveryComplete = $false }
                    foreach ($candidate in $all.items) {
                        if ($candidate.createdBy.id -ine $creator) { continue }
                        $discovery.Add($candidate)
                    }
                }
            }
            foreach ($tracked in @(Get-BuddyProperty $delegation 'trackedPullRequests' @() | Where-Object repository -eq $name)) {
                $discovery.Add([pscustomobject]@{ pullRequestId = $tracked.pullRequestId; creationDate = $AsOf.ToString('o') })
            }
            foreach ($entry in @(@($cache.entries.Values) + @($cache.pending.Values) | Where-Object { $_.repository -eq $name })) {
                $discovery.Add([pscustomobject]@{ pullRequestId = $entry.pullRequestId; creationDate = $AsOf.ToString('o') })
            }
        }
        $uniqueById = [ordered]@{}
        foreach ($candidate in $discovery) {
            if (-not $uniqueById.Contains([string]$candidate.pullRequestId)) { $uniqueById[[string]$candidate.pullRequestId] = $candidate }
        }
        $unique = @($uniqueById.Values)
        $trackedIds = @(Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'trackedPullRequests' @() | Where-Object repository -eq $name | ForEach-Object pullRequestId)
        $selected = @($unique | Sort-Object @{ Expression = { $_.pullRequestId -in $trackedIds }; Descending = $true },
            @{ Expression = 'creationDate'; Descending = $true })
        $omitted = 0
        $inspected = 0
        $skipped = 0
        $scanComplete = $true
        foreach ($candidate in $selected) {
            $id = [int]$candidate.pullRequestId
            $path = "$repoPath/$id"
            $cacheKey = "ado:$name`:$id"
            if (-not $detail) { $cache.pending[$cacheKey] = @{ repository = $name; pullRequestId = $id } }
            $old = if (-not $detail -and $cache.entries.ContainsKey($cacheKey)) { $cache.entries[$cacheKey] } else { $null }
            $operation = 'inspect-pr'
            try {
                $oldResources = if ($old) { $old.resources } else { @{} }
                if ((Get-BuddyProperty (Get-BuddyProperty $candidate 'createdBy') 'id') -in @(Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'trustedCreators' @())) { $operation = 'delegated-attribution' }
                $prResource = Get-BuddyAdoResource $path @{ 'api-version' = '7.1' } $oldResources['pr'] -SingleObject
                $pr = if ($prResource.items.Count) { $prResource.items[0] } else { $null }
                $ownership = $null
                if ($pr) {
                    if ($pr.pullRequestId -ne $id -or $pr.repository.name -cne $name) { throw 'Unexpected PR identity.' }
                    $roles = @()
                    if (@($pr.reviewers | Where-Object id -eq $userId).Count) { $roles += 'reviewer' }
                    $ownership = Resolve-BuddyOwnership -Settings $settings -Repository $name -PullRequestId $id `
                        -Creator $pr.createdBy.id -UserIdentities @($userId, $userEmail) -Description ([string](Get-BuddyProperty $pr 'description' '')) -Roles $roles
                }
                $included = if ($ownership) { $ownership.included } elseif ($old) { $old.included } else { $false }
                if (-not $detail -and -not $included -and -not ($old -and $old.included)) {
                    if ($old -and $old.resources.pr.signature -ceq $prResource.cache.signature) { $skipped++; $metrics.skippedUnchangedPullRequests++ }
                    if (-not (Test-BuddyPrFutureEvidence $pr $AsOf)) {
                        $cache.entries[$cacheKey] = @{
                            repository = $name; pullRequestId = $id; signature = $prResource.cache.signature
                            lastFullInspect = if ($old -and $old.signature -ceq $prResource.cache.signature) { $old.lastFullInspect } else { $AsOf.ToString('o') }
                            included = $false; inspectionKind = 'attribution-only'; resources = @{ pr = $prResource.cache }
                        }
                        $cache.pending.Remove($cacheKey)
                    }
                    continue
                }
                $operation = 'inspect-pr'
                $projectId = if ($pr) { Get-BuddyProperty (Get-BuddyProperty $pr.repository 'project') 'id' } elseif ($old) { $old.projectId } else { $null }
                $policyQuery = @{ 'api-version' = '7.1-preview.1'; artifactId = "vstfs:///CodeReview/CodeReviewId/$projectId/$id" }
                $threads = Get-BuddyAdoSafeResource "$path/threads" @{ 'api-version' = '7.1' } $oldResources['threads'] $name 'threads' $id -SinglePage
                $statuses = Get-BuddyAdoSafeResource "$path/statuses" @{ 'api-version' = '7.1' } $oldResources['statuses'] $name 'statuses' $id
                $policies = if ($projectId) { Get-BuddyAdoSafeResource "$projectPath/_apis/policy/evaluations" $policyQuery $oldResources['policies'] $name 'policy-evaluations' $id }
                    else { [pscustomobject]@{ items = @(); complete = $false; missingBodies = $false; cache = @{ signature = ''; pages = @() } } }
                $resources = @{ pr = $prResource.cache; threads = $threads.cache; statuses = $statuses.cache; policies = $policies.cache }
                $signature = Get-BuddyPrSignature @($prResource.cache.signature, $threads.cache.signature, $statuses.cache.signature, $policies.cache.signature)
                $resourcesComplete = $prResource.complete -and $threads.complete -and $statuses.complete -and $policies.complete
                $futureEvidence = Test-BuddyPrFutureEvidence @($pr, $threads.items, $statuses.items, $policies.items) $AsOf
                if (-not $detail -and $old -and $resourcesComplete -and -not $futureEvidence -and $old.signature -ceq $signature) {
                    $skipped++; $metrics.skippedUnchangedPullRequests++; $cache.pending.Remove($cacheKey); continue
                }
                if (-not $detail -and $inspected -ge $settings.maxPullRequests) { $omitted++; $scanComplete = $false; continue }
                if ($prResource.missingBodies) {
                    $prResource = Get-BuddyAdoResource $path @{ 'api-version' = '7.1' } -SingleObject
                    $pr = $prResource.items[0]
                }
                if ($threads.missingBodies) { $threads = Get-BuddyAdoSafeResource "$path/threads" @{ 'api-version' = '7.1' } $null $name 'threads' $id -SinglePage }
                if ($statuses.missingBodies) { $statuses = Get-BuddyAdoSafeResource "$path/statuses" @{ 'api-version' = '7.1' } $null $name 'statuses' $id }
                if ($policies.missingBodies) { $policies = Get-BuddyAdoSafeResource "$projectPath/_apis/policy/evaluations" $policyQuery $null $name 'policy-evaluations' $id }
                $versionStable = $signature -ceq (Get-BuddyPrSignature @($prResource.cache.signature, $threads.cache.signature, $statuses.cache.signature, $policies.cache.signature))
                $evidence = Get-BuddyAdoEvidence $pr $threads $path $statuses $policies
                $evidence.headStable = $evidence.headStable -and $versionStable
                $item = ConvertTo-BuddyPullRequest -PullRequest $pr -Threads $threads.items -UserId $userId -UserEmail $userEmail `
                    -Since $window.querySince -AsOf $AsOf -Config $config -MaxComments $settings.maxCommentsPerPullRequest `
                    -MaxCharacters $settings.maxCommentCharacters -ReadinessEvidence $evidence
                $complete = $resourcesComplete -and $threads.complete -and $statuses.complete -and $policies.complete -and $evidence.headStable -and $versionStable
                $item | Add-Member -NotePropertyName collectionStatus -NotePropertyValue $(if ($complete) { 'complete' } else { 'partial' })
                $items.Add($item)
                $inspected++
                if (-not $complete) { $scanComplete = $false }
                $futureEvidence = Test-BuddyPrFutureEvidence @($pr, $threads.items, $statuses.items, $policies.items) $AsOf
                if (-not $detail -and $complete -and -not $futureEvidence) {
                    $cache.entries[$cacheKey] = @{
                        repository = $name; pullRequestId = $id; signature = $signature; resources = $resources
                        lastFullInspect = $AsOf.ToString('o'); included = [bool]$item.ownership.included
                        inspectionKind = 'full'; projectId = $projectId; state = $pr.status
                    }
                    $cache.pending.Remove($cacheKey)
                }
            } catch { Add-BuddyAdoFailure $operation $name $id $_; $scanComplete = $false }
        }
        $repoCoverage.Add([pscustomobject]@{
            repository = $name
            status = if ($errors.Count -gt $repoStartErrors -or -not $discoveryComplete -or $omitted -gt 0 -or
                @($items | Where-Object { $_.repository -eq $name -and ($_.collectionStatus -ne 'complete' -or $_.omittedCommentCount -gt 0 -or $_.truncatedCommentCount -gt 0) }).Count) { 'partial' } else { 'complete-within-declared-scope' }
            discovered = $unique.Count; inspected = $inspected; omitted = $omitted; skippedUnchanged = $skipped
            scanComplete = $scanComplete -and $discoveryComplete -and $errors.Count -eq $repoStartErrors
            discoveryComplete = $discoveryComplete
        })
    }
    $includeBodies = $IncludeComments -or $detail
    $outputItems = if ($includeBodies) { @($items.ToArray()) } else { @($items | Select-Object * -ExcludeProperty comments, reviewers) }
    [pscustomobject]@{
        source = 'Azure DevOps'; readOnly = $true; asOf = $AsOf.ToString('o'); since = $since.ToString('o')
        observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        commentBodiesIncluded = [bool]$includeBodies
        user = Get-BuddyProperty (Get-BuddyProperty $identity 'authenticatedUser') 'providerDisplayName'
        repositories = @($repositories)
        cache = $cache
        scan = [pscustomobject]@{
            cacheState = $cacheState.state; requestedSince = $window.requestedSince; querySince = $window.querySince.ToString('o')
            overlapSeconds = $window.overlapSeconds; gap = $window.gap; lookbackCapped = $window.lookbackCapped
            conditionalNotModified = $metrics.conditionalNotModified; fullResourceReads = $metrics.fullResourceReads
            descriptionReads = $metrics.descriptionReads; threadBodyReads = $metrics.threadBodyReads
        }
        coverage = [pscustomobject]@{
            checkpointSafe = -not $detail -and [bool]$identity -and @($repoCoverage | Where-Object { -not (Get-BuddyProperty $_ 'scanComplete' $false) }).Count -eq 0
            scanComplete = [bool]$identity -and @($repoCoverage | Where-Object { -not (Get-BuddyProperty $_ 'scanComplete' $false) }).Count -eq 0
            metadataReads = $metrics.metadataReads
            skippedUnchangedPullRequests = $metrics.skippedUnchangedPullRequests
            status = if (-not $identity) { 'unavailable' } elseif (@($repoCoverage | Where-Object status -ne 'complete-within-declared-scope').Count) { 'partial' } else { 'complete-within-declared-scope' }
            discoveredPullRequests = ($repoCoverage | Measure-Object discovered -Sum).Sum
            inspectedPullRequests = $items.Count
            omittedPullRequests = ($repoCoverage | Measure-Object omitted -Sum).Sum
            pullRequestsWithOmittedComments = @($items | Where-Object omittedCommentCount -gt 0).Count
            pullRequestsWithTruncatedComments = @($items | Where-Object truncatedCommentCount -gt 0).Count
            repositories = $repoCoverage.ToArray(); errors = $errors.ToArray()
            delegation = [pscustomobject]@{
                status = if (-not $identity) { 'unavailable' } elseif (-not (Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'enabled' $false)) { 'disabled' }
                    elseif (@(Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'trustedCreators' @()).Count -and
                        ($userEmail -or (Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'allowOnBehalfMarker' $false))) { 'configured-markers-only' }
                    else { 'no-trusted-agency-attribution-configured' }
                verifiedPullRequests = @($items | Where-Object delegatedToUser).Count
                explicitlyTrackedPullRequests = @($items | Where-Object trackedByUser).Count
            }
            maxPagesPerCollection = $maxPages; maxInspectedPerRepository = $settings.maxPullRequests
            limitations = @(
                'Discovery: active authored/direct-reviewer PRs and trusted-creator PRs, plus Closed-time interval queries for work closed between scans, known cached IDs, and explicitly user-confirmed tracked IDs; no team-only or subscription ownership. Existing open carryover must bootstrap once when no valid cache exists.'
                'ADO REST 7.1 documents minTime/maxTime for Created/Closed, not Updated. No unsupported updated filter is sent: bounded active metadata lists are polled so old PR comments and new review assignments cannot be missed by creation-date filters.'
                'ADO has no documented body-free thread/version endpoint; list descriptions truncate at 400 characters. Current PR, threads, statuses and policies are polled. Server-supplied ETags enable conditional 304 reads, never assumed. Without validators these endpoints necessarily return full resources again (descriptionReads/threadBodyReads report this); identical signatures skip triage, duplicate detail reads and output, not the unavoidable source polling.'
                'Attribution caches both included and excluded trusted-creator PRs only after a full description read; unchanged server validators can avoid fetching descriptions, but a truncated list hash alone never proves unchanged attribution. No source bodies are stored in the provider cache.'
                'Presentation truncation can report partial status independently of checkpointSafe; incomplete discovery/evidence prevents checkpointing. Detail approval reads bypass all cached validators. Activity older than seven days is not backfilled; open carryover and current state are still observed.'
                'Delegation requires a configured trusted creator ID and exactly one unquoted COPILOT_AI_GENERATED_START/END HTML comment block containing one Co-authored-by: Name <configured userEmail> trailer (email case-insensitive; HTML-escaped brackets supported). Duplicate blocks/coauthors and examples are not attribution; comments, commits, tags, and mentions alone never establish ownership.'
                'Standalone On-behalf-of identity markers require delegation.allowOnBehalfMarker: true and are not a fallback for malformed Copilot blocks. Missing trusted creator or verified userEmail configuration prevents automatic Copilot attribution.'
                'Delegated ownership is triage membership only, never task, publication, or merge approval.'
                'Reviews, policies, draft, conflicts, and thread resolution are current observed state, not historical AsOf state; AsOf filters comment timestamps and labels older carryover.'
                'Reads are non-atomic. Merge-ready is only a candidate; head/base and all requirements need revalidation and explicit human approval. No automatic merge.'
                'All open threads gate readiness, including threads whose IcM comment bodies are excluded. Omitted comments and failed collections must be surfaced.'
            )
        }
        items = @($outputItems)
    } | ConvertTo-Json -Depth 30 -Compress
} finally {
    $headers.Clear()
    Remove-Variable token, tokenJson -ErrorAction SilentlyContinue
}
