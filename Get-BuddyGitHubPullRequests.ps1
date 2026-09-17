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
. (Join-Path $PSScriptRoot 'Buddy.GitHub.Core.ps1')
. (Join-Path $PSScriptRoot 'Buddy.PrScan.Core.ps1')
$config = Get-BuddyConfig $ConfigPath
$settings = Get-BuddyProperty $config 'github'
if (-not $settings -or -not $settings.enabled) { throw 'GitHub collection is not enabled.' }
$detail = $PSBoundParameters.ContainsKey('PullRequestId')
if ($detail -and -not $Repository) { throw 'Repository is required with PullRequestId.' }
if ($Repository -and $Repository -notin $settings.repositories) { throw 'Repository is outside the configured scope.' }
$repositories = if ($Repository) { @($Repository) } else { @($settings.repositories) }
$window = Get-BuddyPrScanWindow -AsOf $AsOf -Since $Since -WindowDays $config.windowDays
$since = $window.since
$errors = [System.Collections.Generic.List[object]]::new()
$items = [System.Collections.Generic.List[object]]::new()
$repoCoverage = [System.Collections.Generic.List[object]]::new()
$gh = $null
$authenticatedLogin = $null
$size = [int]$settings.pageSize
$maxPages = [int]$settings.maxPages
$metrics = @{ metadataReads = 0; detailReads = 0; skippedUnchangedPullRequests = 0 }
$cacheState = $null

function Add-BuddyGitHubFailure {
    param([string]$Repo, [int]$Id, [string]$Operation)
    $errors.Add([pscustomobject]@{
        repository = $Repo; pullRequestId = $Id; operation = $Operation
        error = 'GitHub read failed, was denied, or returned unexpected data. No access bypass or raw error/source body retained.'
    })
}

function Invoke-BuddyGitHubRest {
    param([string]$Path)
    $metrics.metadataReads++
    $raw = & $gh api --hostname github.com --method GET $Path 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub REST read failed.' }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Invoke-BuddyGitHubQuery {
    param([string]$Query)
    if ($Query -notmatch '^\s*query\s*\{' -or $Query -match '\bmutation\s*[{(]') { throw 'Only GraphQL read queries are allowed.' }
    $raw = & $gh api --hostname github.com graphql -f "query=$Query" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub GraphQL read failed.' }
    $result = ($raw -join "`n") | ConvertFrom-Json
    if (@(Get-BuddyProperty $result 'errors' @()).Count -gt 0 -or -not (Get-BuddyProperty $result 'data')) { throw 'Incomplete GraphQL response.' }
    return $result.data
}

function Get-BuddyGitHubPr {
    param([string]$Repo, [int]$Id, [switch]$Metadata)
    $owner, $name = $Repo.Split('/')
    $query = @'
query { repository(owner:OWNER, name:NAME) { pullRequest(number:NUMBER) {
  number title url body state createdAt updatedAt isDraft author { login }
  headRefOid baseRefOid headRefName baseRefName mergeable mergeStateStatus reviewDecision
  baseRef { branchProtectionRule {
    requiresApprovingReviews requiredApprovingReviewCount requiresStatusChecks
    requiredStatusCheckContexts requiredStatusChecks { context app { databaseId } }
    requiresConversationResolution
  } }
} } }
'@
    $query = $query.Replace('OWNER', ($owner | ConvertTo-Json -Compress)).Replace('NAME', ($name | ConvertTo-Json -Compress)).Replace('NUMBER', [string]$Id)
    if ($Metadata) { $query = $query.Replace('url body state', 'url state'); $metrics.metadataReads++ }
    else { $metrics.detailReads++ }
    $data = Invoke-BuddyGitHubQuery $query
    if (-not $data.repository.pullRequest -or $data.repository.pullRequest.number -ne $Id) { throw 'PR is unavailable or has an unexpected identity.' }
    return $data.repository.pullRequest
}

function Get-BuddyGitHubConnection {
    param([string]$Repo, [int]$Id, [string]$Kind, [string]$NodeId, [switch]$Metadata)
    $owner, $name = $Repo.Split('/')
    $found = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    $seenCursors = [System.Collections.Generic.HashSet[string]]::new()
    $complete = $false
    $total = $null
    $pages = 0
    try {
        for ($page = 0; $page -lt $maxPages; $page++) {
            $after = if ($cursor) { ', after:' + ($cursor | ConvertTo-Json -Compress) } else { '' }
            $fields = switch ($Kind) {
                'reviewThreads' { 'id isResolved isOutdated' }
                'comments' { 'id body createdAt updatedAt url author { login }' }
                'threadComments' { 'id body createdAt updatedAt url author { login }' }
                'reviews' { 'id state body submittedAt updatedAt url author { login } commit { oid }' }
                'reviewRequests' { 'requestedReviewer { __typename ... on User { login } ... on Team { slug } }' }
                'assignees' { 'login' }
                'checks' { "__typename ... on CheckRun { name status conclusion detailsUrl isRequired(pullRequestNumber:$Id) checkSuite { app { databaseId } } } ... on StatusContext { context state targetUrl isRequired(pullRequestNumber:$Id) }" }
                default { throw 'Unknown connection.' }
            }
            if ($Metadata) { $fields = $fields -replace '\bbody\s*', '' }
            $connectionName = switch ($Kind) { 'checks' { 'contexts' }; 'threadComments' { 'comments' }; default { $Kind } }
            $connection = "$connectionName(first:$size$after) { totalCount pageInfo { hasNextPage endCursor } nodes { $fields } }"
            $selection = if ($Kind -eq 'checks') { "commits(last:1) { nodes { commit { statusCheckRollup { $connection } } } }" } else { $connection }
            $query = if ($Kind -eq 'threadComments') {
                'query { node(id:' + ($NodeId | ConvertTo-Json -Compress) + ") { ... on PullRequestReviewThread { $connection } } }"
            } else {
                'query { repository(owner:' + ($owner | ConvertTo-Json -Compress) + ', name:' + ($name | ConvertTo-Json -Compress) + ") { pullRequest(number:$Id) { $selection } } }"
            }
            if ($Metadata -or $Kind -notin @('comments', 'threadComments', 'reviews')) { $metrics.metadataReads++ }
            else { $metrics.detailReads++ }
            $data = Invoke-BuddyGitHubQuery $query
            $pages++
            $parent = if ($Kind -eq 'threadComments') { $data.node } else { $data.repository.pullRequest }
            if (-not $parent) { throw 'Missing connection parent.' }
            if ($Kind -eq 'checks') {
                if (@($parent.commits.nodes).Count -ne 1) { throw 'Head commit missing.' }
                $rollup = $parent.commits.nodes[0].commit.statusCheckRollup
                if ($null -eq $rollup) { $total = 0; $complete = $true; break }
                $result = $rollup.contexts
            } else { $result = $parent.$connectionName }
            if ($null -eq $result) { throw 'Missing connection.' }
            $total = [int]$result.totalCount
            foreach ($entry in @($result.nodes)) { if ($null -eq $entry) { throw 'Null connection node.' }; $found.Add($entry) }
            if (-not $result.pageInfo.hasNextPage) {
                $complete = $found.Count -eq $total
                break
            }
            $cursor = [string]$result.pageInfo.endCursor
            if (-not $cursor -or -not $seenCursors.Add($cursor)) { throw 'Invalid pagination cursor.' }
        }
    } catch { Add-BuddyGitHubFailure $Repo $Id $Kind }
    [pscustomobject]@{ items = $found.ToArray(); complete = $complete; total = $total; pages = $pages }
}

function Get-BuddyGitHubRules {
    param([string]$Repo, [string]$Branch, [int]$Id)
    $found = [System.Collections.Generic.List[object]]::new()
    $complete = $false
    try {
        for ($page = 1; $page -le $maxPages; $page++) {
            $batch = @(Invoke-BuddyGitHubRest "repos/$Repo/rules/branches/$([Uri]::EscapeDataString($Branch))?per_page=$size&page=$page")
            foreach ($rule in $batch) { $found.Add($rule) }
            if ($batch.Count -lt $size) { $complete = $true; break }
        }
    } catch { Add-BuddyGitHubFailure $Repo $Id 'effective-branch-rules' }
    [pscustomobject]@{ items = $found.ToArray(); complete = $complete }
}

function Get-BuddyGitHubSearch {
    param([string]$Repo, [string]$Qualifier, [string]$Value, [switch]$BootstrapOpen)
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $complete = $false
    $total = $null
    $pages = 0
    try {
        $activity = if ($BootstrapOpen) { 'is:open' } else { 'updated:>=' + $window.querySince.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $q = [Uri]::EscapeDataString("repo:$Repo is:pr $activity ${Qualifier}:$Value")
        for ($page = 1; $page -le $maxPages -and (($page - 1) * $size) -lt 1000; $page++) {
            $result = Invoke-BuddyGitHubRest "search/issues?q=$q&sort=updated&order=desc&per_page=$size&page=$page"
            $pages++
            $total = [int]$result.total_count
            foreach ($entry in @($result.items)) {
                if (-not $seen.Add([int]$entry.number)) { throw 'Repeated search item.' }
                $found.Add($entry)
            }
            if ($found.Count -ge $total) { $complete = -not $result.incomplete_results; break }
            if (@($result.items).Count -lt $size) { break }
        }
    } catch { Add-BuddyGitHubFailure $Repo 0 "search:$Qualifier" }
    [pscustomobject]@{ items = $found.ToArray(); complete = $complete; total = $total; pages = $pages; qualifier = $Qualifier }
}

function Get-BuddyGitHubVersion {
    param($Pr, $Assignees, $Requests, $Reviews, $Comments, $Threads, $Checks, $Rules)
    Get-BuddyPrSignature ([ordered]@{
        pr = $Pr | Select-Object * -ExcludeProperty body, assignees
        assignees = $Assignees.items; requests = $Requests.items
        reviews = @($Reviews.items | Select-Object * -ExcludeProperty body)
        comments = @($Comments.items | Select-Object * -ExcludeProperty body)
        threads = @($Threads.items | ForEach-Object {
            [ordered]@{ id = $_.id; isResolved = $_.isResolved; isOutdated = $_.isOutdated
                comments = @($_.comments.nodes | Select-Object * -ExcludeProperty body) }
        })
        checks = $Checks.items; rules = $Rules.items
    })
}

try {
    $gh = Get-BuddyExecutable 'gh' 'C:\Program Files\GitHub CLI\gh.exe'
    $authenticatedLogin = (Invoke-BuddyGitHubRest 'user').login
    if (-not $authenticatedLogin) { throw 'GitHub identity unavailable.' }
} catch { Add-BuddyGitHubFailure '' 0 'authentication' }
$cacheState = New-BuddyPrScanCache -CacheJson $CacheJson -Provider 'github' -AsOf $AsOf -Detail:$detail -Scope @{
    repositories = @($repositories); settings = $settings; authenticatedLogin = $authenticatedLogin
    briefingFilters = Get-BuddyProperty $config 'briefingFilters'; windowDays = $config.windowDays
}
$cache = $cacheState.cache
foreach ($repo in $repositories) {
    if (-not $authenticatedLogin) {
        $repoCoverage.Add([pscustomobject]@{ repository = $repo; status = 'unavailable'; discovered = 0; inspected = 0; omitted = 0 })
        continue
    }
    $startErrors = $errors.Count
    $candidates = [ordered]@{}
    $searchCoverage = [System.Collections.Generic.List[object]]::new()
    $discoveryComplete = $true
    if ($detail) { $candidates[[string]$PullRequestId] = @() }
    else {
        $roles = [ordered]@{ author = 'authored'; assignee = 'assigned'; 'review-requested' = 'review-requested'; 'reviewed-by' = 'reviewed' }
        foreach ($qualifier in $roles.Keys) {
            $result = Get-BuddyGitHubSearch $repo $qualifier $settings.login
            $searchCoverage.Add([pscustomobject]@{ role = $qualifier; complete = $result.complete; total = $result.total; retrieved = $result.items.Count; pages = $result.pages })
            if (-not $result.complete) { $discoveryComplete = $false }
            foreach ($pr in $result.items) {
                $key = [string]$pr.number
                if (-not $candidates.Contains($key)) { $candidates[$key] = @() }
                $candidates[$key] += $roles[$qualifier]
            }
            if (-not $cache.bootstrapped[$repo]) {
                $bootstrap = Get-BuddyGitHubSearch $repo $qualifier $settings.login -BootstrapOpen
                $searchCoverage.Add([pscustomobject]@{ role = "$qualifier-bootstrap-open"; complete = $bootstrap.complete; total = $bootstrap.total; retrieved = $bootstrap.items.Count; pages = $bootstrap.pages })
                if (-not $bootstrap.complete) { $discoveryComplete = $false }
                foreach ($pr in $bootstrap.items) {
                    if (-not $candidates.Contains([string]$pr.number)) { $candidates[[string]$pr.number] = @() }
                }
            }
        }
        $delegation = Get-BuddyProperty $settings 'delegation'
        if (Get-BuddyProperty $delegation 'enabled' $false) {
            foreach ($creator in @(Get-BuddyProperty $delegation 'trustedCreators' @())) {
                $result = Get-BuddyGitHubSearch $repo 'author' $creator
                $searchCoverage.Add([pscustomobject]@{ role = 'trusted-creator'; complete = $result.complete; total = $result.total; retrieved = $result.items.Count; pages = $result.pages })
                if (-not $result.complete) { $discoveryComplete = $false }
                $trustedResults = @($result.items)
                if (-not $cache.bootstrapped[$repo]) {
                    $bootstrap = Get-BuddyGitHubSearch $repo 'author' $creator -BootstrapOpen
                    $searchCoverage.Add([pscustomobject]@{ role = 'trusted-creator-bootstrap-open'; complete = $bootstrap.complete; total = $bootstrap.total; retrieved = $bootstrap.items.Count; pages = $bootstrap.pages })
                    if (-not $bootstrap.complete) { $discoveryComplete = $false }
                    $trustedResults += @($bootstrap.items)
                }
                foreach ($pr in $trustedResults) {
                    if (-not $candidates.Contains([string]$pr.number)) { $candidates[[string]$pr.number] = @() }
                }
            }
        }
        foreach ($tracked in @(Get-BuddyProperty $delegation 'trackedPullRequests' @() | Where-Object repository -eq $repo)) {
            if (-not $candidates.Contains([string]$tracked.pullRequestId)) { $candidates[[string]$tracked.pullRequestId] = @() }
        }
        foreach ($entry in @(@($cache.entries.Values) + @($cache.pending.Values) | Where-Object { $_.repository -eq $repo })) {
            if (-not $candidates.Contains([string]$entry.pullRequestId)) { $candidates[[string]$entry.pullRequestId] = @() }
        }
    }
    $trackedIds = @(Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'trackedPullRequests' @() | Where-Object repository -eq $repo | ForEach-Object { [string]$_.pullRequestId })
    $selected = @($candidates.Keys | Sort-Object @{ Expression = { $_ -in $trackedIds }; Descending = $true } -Stable)
    $inspected = 0
    $skipped = 0
    $omitted = 0
    $completeDetails = $true
    $scanComplete = $true
    foreach ($key in $selected) {
        $id = [int]$key
        $cacheKey = "github:$repo`:$id"
        $previouslyIncluded = $cache.entries.ContainsKey($cacheKey) -and $cache.entries[$cacheKey].included
        if (-not $detail) { $cache.pending[$cacheKey] = @{ repository = $repo; pullRequestId = $id } }
        try {
            $pr = Get-BuddyGitHubPr $repo $id -Metadata:(-not $detail)
            $assignees = Get-BuddyGitHubConnection $repo $id 'assignees'
            $pr | Add-Member -NotePropertyName assignees -NotePropertyValue ([pscustomobject]@{ nodes = $assignees.items })
            $requests = Get-BuddyGitHubConnection $repo $id 'reviewRequests'
            $reviews = Get-BuddyGitHubConnection $repo $id 'reviews' -Metadata:(-not $detail)
            $comments = Get-BuddyGitHubConnection $repo $id 'comments' -Metadata:(-not $detail)
            $threads = Get-BuddyGitHubConnection $repo $id 'reviewThreads'
            $threadCommentsComplete = $threads.complete
            $threadCommentCoverage = [System.Collections.Generic.List[object]]::new()
            foreach ($thread in $threads.items) {
                $replies = Get-BuddyGitHubConnection $repo $id 'threadComments' $thread.id -Metadata:(-not $detail)
                $thread | Add-Member -NotePropertyName comments -NotePropertyValue ([pscustomobject]@{ nodes = $replies.items })
                $threadCommentCoverage.Add([pscustomobject]@{ threadId = $thread.id; complete = $replies.complete; total = $replies.total; retrieved = $replies.items.Count; pages = $replies.pages })
                if (-not $replies.complete) { $threadCommentsComplete = $false }
            }
            $checks = Get-BuddyGitHubConnection $repo $id 'checks'
            $rules = Get-BuddyGitHubRules $repo $pr.baseRefName $id
            $metadataComplete = $assignees.complete -and $requests.complete -and $reviews.complete -and $comments.complete -and
                $threadCommentsComplete -and $checks.complete -and $rules.complete
            $signature = Get-BuddyGitHubVersion $pr $assignees $requests $reviews $comments $threads $checks $rules
            $unsettledEvidence = Test-BuddyPrFutureEvidence @($pr, $reviews.items, $comments.items, $threads.items) $AsOf.AddSeconds(-60)
            if (-not $detail -and $metadataComplete -and -not $unsettledEvidence -and $cache.entries.ContainsKey($cacheKey) -and
                $cache.entries[$cacheKey].signature -ceq $signature) {
                $skipped++; $metrics.skippedUnchangedPullRequests++; $cache.pending.Remove($cacheKey); continue
            }
            if (-not $detail -and $inspected -ge $settings.maxPullRequests) { $omitted++; $scanComplete = $false; continue }
            if (-not $detail) {
                $pr = Get-BuddyGitHubPr $repo $id
                $pr | Add-Member -NotePropertyName assignees -NotePropertyValue ([pscustomobject]@{ nodes = $assignees.items })
                if ($reviews.items.Count -or -not $reviews.complete) { $reviews = Get-BuddyGitHubConnection $repo $id 'reviews' }
                if ($comments.items.Count -or -not $comments.complete) { $comments = Get-BuddyGitHubConnection $repo $id 'comments' }
                $threadCommentCoverage.Clear()
                foreach ($thread in $threads.items) {
                    if ($thread.comments.nodes.Count -or -not $threadCommentsComplete) {
                        $replies = Get-BuddyGitHubConnection $repo $id 'threadComments' $thread.id
                        $thread.comments.nodes = $replies.items
                        if (-not $replies.complete) { $threadCommentsComplete = $false }
                        $threadCommentCoverage.Add([pscustomobject]@{ threadId = $thread.id; complete = $replies.complete; total = $replies.total; retrieved = $replies.items.Count; pages = $replies.pages })
                    } else {
                        $threadCommentCoverage.Add([pscustomobject]@{ threadId = $thread.id; complete = $true; total = 0; retrieved = 0; pages = 1 })
                    }
                }
            }
            $stable = $false
            try {
                $latest = Get-BuddyGitHubPr $repo $id -Metadata
                $stable = (Get-BuddyPrSignature ($pr | Select-Object * -ExcludeProperty body, assignees)) -ceq (Get-BuddyPrSignature $latest)
            } catch { Add-BuddyGitHubFailure $repo $id 'head-revalidation' }
            $versionStable = $signature -ceq (Get-BuddyGitHubVersion $pr $assignees $requests $reviews $comments $threads $checks $rules)
            $stable = $stable -and $versionStable
            $evidence = Get-BuddyGitHubEvidence $pr $checks $rules $reviews $threadCommentsComplete $stable
            $item = ConvertTo-BuddyGitHubPullRequest -PullRequest $pr -Repository $repo -Login $settings.login `
                -Threads $threads.items -IssueComments $comments.items -Reviews $reviews.items -ReviewRequests $requests.items `
                -Since $window.querySince -AsOf $AsOf -Config $config -ReadinessEvidence $evidence `
                -CommentsComplete ($comments.complete -and $threadCommentsComplete -and $reviews.complete)
            $complete = $assignees.complete -and $requests.complete -and $reviews.complete -and $comments.complete -and
                $threadCommentsComplete -and $checks.complete -and $rules.complete -and $stable
            $item | Add-Member -NotePropertyName collectionStatus -NotePropertyValue $(if ($complete) { 'complete' } else { 'partial' })
            $connectionCoverage = [ordered]@{}
            foreach ($entry in @(
                @{ name = 'assignees'; result = $assignees }, @{ name = 'reviewRequests'; result = $requests },
                @{ name = 'reviews'; result = $reviews }, @{ name = 'comments'; result = $comments },
                @{ name = 'reviewThreads'; result = $threads }, @{ name = 'checks'; result = $checks }
            )) {
                $r = $entry.result
                $connectionCoverage[$entry.name] = [pscustomobject]@{ complete = $r.complete; total = $r.total; retrieved = $r.items.Count; pages = $r.pages }
            }
            $connectionCoverage.threadComments = $threadCommentCoverage.ToArray()
            $item | Add-Member -NotePropertyName collectionCoverage -NotePropertyValue ([pscustomobject]$connectionCoverage)
            if (-not $complete -or $item.omittedCommentCount -gt 0 -or $item.truncatedCommentCount -gt 0) { $completeDetails = $false }
            $unsettledEvidence = Test-BuddyPrFutureEvidence @($pr, $reviews.items, $comments.items, $threads.items) $AsOf.AddSeconds(-60)
            if (-not $complete -or -not $metadataComplete -or -not $versionStable) { $scanComplete = $false }
            if (-not $detail -and $complete -and $metadataComplete -and $versionStable -and -not $unsettledEvidence) {
                $cache.entries[$cacheKey] = @{
                    repository = $repo; pullRequestId = $id; signature = $signature
                    lastFullInspect = $AsOf.ToString('o'); included = [bool]$item.ownership.included
                    state = $pr.state; roles = @($item.ownership.reasons)
                }
                $cache.pending.Remove($cacheKey)
            }
            if ($detail -or $item.ownership.included -or $previouslyIncluded) { $items.Add($item) }
            $inspected++
        } catch {
            Add-BuddyGitHubFailure $repo $id 'inspect-pr'
            $completeDetails = $false
            $scanComplete = $false
        }
    }
    if (-not $detail -and $scanComplete -and $discoveryComplete -and $errors.Count -eq $startErrors) { $cache.bootstrapped[$repo] = $true }
    $repoCoverage.Add([pscustomobject]@{
        repository = $repo
        status = if ($errors.Count -gt $startErrors -or -not $discoveryComplete -or -not $completeDetails -or $omitted) { 'partial' } else { 'complete-within-declared-scope' }
        discovered = $candidates.Count; inspected = $inspected; omitted = $omitted; skippedUnchanged = $skipped
        scanComplete = $scanComplete -and $discoveryComplete -and $errors.Count -eq $startErrors
        discoveryComplete = $discoveryComplete; searches = $searchCoverage.ToArray()
    })
}
$includeBodies = $IncludeComments -or $detail
$outputItems = if ($includeBodies) { @($items.ToArray()) } else { @($items | Select-Object * -ExcludeProperty comments, reviewers) }
[pscustomobject]@{
    source = 'GitHub'; readOnly = $true; asOf = $AsOf.ToString('o'); since = $since.ToString('o')
    observedAt = [DateTimeOffset]::UtcNow.ToString('o')
    commentBodiesIncluded = [bool]$includeBodies; user = $settings.login; authenticatedLogin = $authenticatedLogin
    repositories = @($repositories)
    cache = $cache
    scan = [pscustomobject]@{ cacheState = $cacheState.state; requestedSince = $window.requestedSince; querySince = $window.querySince.ToString('o'); overlapSeconds = $window.overlapSeconds; gap = $window.gap; lookbackCapped = $window.lookbackCapped; detailReads = $metrics.detailReads }
    coverage = [pscustomobject]@{
        checkpointSafe = -not $detail -and [bool]$authenticatedLogin -and @($repoCoverage | Where-Object { -not (Get-BuddyProperty $_ 'scanComplete' $false) }).Count -eq 0
        scanComplete = [bool]$authenticatedLogin -and @($repoCoverage | Where-Object { -not (Get-BuddyProperty $_ 'scanComplete' $false) }).Count -eq 0
        metadataReads = $metrics.metadataReads
        skippedUnchangedPullRequests = $metrics.skippedUnchangedPullRequests
        status = if (-not $authenticatedLogin) { 'unavailable' } elseif (@($repoCoverage | Where-Object status -ne 'complete-within-declared-scope').Count) { 'partial' } else { 'complete-within-declared-scope' }
        discoveredPullRequests = ($repoCoverage | Measure-Object discovered -Sum).Sum
        inspectedPullRequests = ($repoCoverage | Measure-Object inspected -Sum).Sum
        omittedPullRequests = ($repoCoverage | Measure-Object omitted -Sum).Sum
        pullRequestsWithOmittedComments = @($items | Where-Object omittedCommentCount -gt 0).Count
        pullRequestsWithTruncatedComments = @($items | Where-Object truncatedCommentCount -gt 0).Count
        repositories = $repoCoverage.ToArray(); errors = $errors.ToArray()
        delegation = [pscustomobject]@{
            status = if (-not $authenticatedLogin) { 'unavailable' } elseif (@(Get-BuddyProperty (Get-BuddyProperty $settings 'delegation') 'trustedCreators' @()).Count) { 'configured-markers-only' } else { 'no-trusted-agency-attribution-configured' }
            verifiedPullRequests = @($items | Where-Object delegatedToUser).Count
            explicitlyTrackedPullRequests = @($items | Where-Object trackedByUser).Count
        }
        maxPagesPerCollection = $maxPages; maxInspectedPerRepository = $settings.maxPullRequests
        limitations = @(
            'Incremental discovery searches updated timestamps (60-second overlap, at most seven days), all states, for authored/assigned/direct-review-requested/reviewed and trusted creators. Cache bootstrap also enumerates open carryover work. Known IDs are polled even if absent from search; no team-only or subscription ownership.'
            'Known PRs require body-free current PR, comment timestamps, review/thread state, check and effective rule metadata each scan: updatedAt alone does not version votes, resolution or checks. Only changed/new PRs read full bodies and are emitted for durable upsert. Search responses themselves may contain issue body snippets.'
            'Missing/foreign cache requires one-time open-work bootstrap; the provider cache contains signatures/IDs, never comment bodies. Presentation truncation can report partial status independently of checkpointSafe. Detail reads bypass the cache.'
            'Search is eventually consistent: the overlap handles ordinary timestamp precision/indexing lag, not an unbounded indexing outage. Gaps older than seven days are reported, not backfilled.'
            'PRs with timestamps within 60 seconds of AsOf, or future evidence, remain pending for another full observation rather than trusting second-precision timestamps as a settled body version. Failed/omitted IDs also remain pending independently of successful entity caches.'
            'Delegation requires a configured trusted creator plus an exact On-behalf-of: login description line, or a user-confirmed tracked PR ID. Empty trustedCreators cannot discover agency work automatically.'
            'Search is eventually consistent and capped at 1000 per query; every collection also has a configured page bound. Incomplete/error coverage is reported per repository and collection.'
            'AsOf bounds comment evidence, not historical PR/check state. Older open review-thread comments are labeled carryover; old conversation comments without resolution metadata are not inferred open.'
            'Draft, approvals, conflicts, rules, and thread status are current non-atomic observations. Candidate is never a guarantee of safe merge; revalidate and obtain human approval. No mutations.'
            'Legacy branch protection plus effective rules must be readable. Unknown required checks, unsupported rules, missing thread pages, or head changes prevent merge-ready candidates.'
        )
    }
    items = @($outputItems)
} | ConvertTo-Json -Depth 35 -Compress
