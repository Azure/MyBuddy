Set-StrictMode -Version Latest

function Get-BuddyConfig {
    param([Parameter(Mandatory)][string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($config.version -ne 1 -or $config.windowDays -lt 1 -or $config.windowDays -gt 30) {
        throw 'Unsupported configuration version or lookback window.'
    }
    if ($config.azureDevOps.organization -cnotmatch '^https://(dev\.azure\.com/[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+\.visualstudio\.com)/?$' -or
        $config.azureDevOps.project -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 _.-]*$') {
        throw 'Configure a valid Azure DevOps organization URL and project name.'
    }
    $repositories = @($config.azureDevOps.repositories)
    if ($repositories.Count -eq 0 -or
        @($repositories | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 _.-]*$' }).Count -gt 0 -or
        @($repositories | Select-Object -Unique).Count -ne $repositories.Count) {
        throw 'Repository scope must contain unique valid repository names.'
    }
    foreach ($name in @('maxPullRequests', 'maxCommentsPerPullRequest', 'maxCommentCharacters')) {
        $value = $config.azureDevOps.$name
        if ($value -isnot [long] -and $value -isnot [int]) {
            throw "Configuration limit $name must be an integer."
        }
        if ($value -lt 1 -or $value -gt 10000) {
            throw "Invalid configuration limit: $name"
        }
    }
    Assert-BuddyInventorySettings $config
    return $config
}

function Get-BuddyProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function New-BuddyAdoUri {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query = @{},
        [Parameter(Mandatory)]$Config
    )
    $project = [regex]::Escape([Uri]::EscapeDataString($Config.azureDevOps.project))
    $repos = @($Config.azureDevOps.repositories | ForEach-Object { [regex]::Escape([Uri]::EscapeDataString($_)) }) -join '|'
    $pattern = "^/$project/_apis/git/repositories/($repos)(/pullrequests(/[1-9][0-9]*(/(threads|statuses))?)?)?$"
    if ($Path -cne '/_apis/connectionData' -and $Path -cnotmatch $pattern -and
        $Path -cnotmatch "^/$project/_apis/policy/evaluations$") {
        throw "Unapproved Azure DevOps API path: $Path"
    }
    $parts = foreach ($key in ($Query.Keys | Sort-Object)) {
        '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$Query[$key])
    }
    $uri = $Config.azureDevOps.organization.TrimEnd('/') + $Path
    if ($parts) { $uri += '?' + ($parts -join '&') }
    return $uri
}

function Get-BuddyThreadStatus {
    param($Value)
    $statuses = @{
        '0' = 'unknown'; '1' = 'active'; '2' = 'fixed'; '3' = 'wontFix'
        '4' = 'closed'; '5' = 'byDesign'; '6' = 'pending'
    }
    $text = [string]$Value
    if ($statuses.ContainsKey($text)) { return $statuses[$text] }
    if ($text -cin @('unknown', 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending')) {
        return $text
    }
    return 'unknown'
}

function Merge-BuddyPullRequests {
    param([object[]]$Authored = @(), [object[]]$Reviewing = @())
    $items = @{}
    foreach ($pr in @($Authored) + @($Reviewing)) {
        if ($null -eq $pr) { continue }
        $key = '{0}:{1}' -f $pr.repository.id, $pr.pullRequestId
        if (-not $items.ContainsKey($key)) { $items[$key] = $pr }
    }
    return @($items.Values | Sort-Object creationDate -Descending)
}

function ConvertTo-BuddyPullRequest {
    param(
        [Parameter(Mandatory)]$PullRequest,
        [object[]]$Threads = @(),
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][DateTimeOffset]$Since,
        [Parameter(Mandatory)][DateTimeOffset]$AsOf,
        [Parameter(Mandatory)]$Config,
        [string]$UserEmail = (Get-BuddyProperty $Config.azureDevOps 'userEmail' ''),
        [int]$MaxComments = 20,
        [int]$MaxCharacters = 1600,
        $Ownership,
        $ReadinessEvidence
    )
    $mine = $PullRequest.createdBy.id -eq $UserId
    $myReviews = @($PullRequest.reviewers | Where-Object { $_.id -eq $UserId })
    $vote = if ($myReviews.Count -gt 0) { [int]$myReviews[0].vote } else { $null }
    $reviewState = if ($null -eq $vote) {
        'not-assigned'
    } else {
        switch ($vote) {
            -10 { 'rejected' }
            -5 { 'waiting-for-author' }
            0 { 'not-reviewed' }
            5 { 'approved-with-suggestions' }
            10 { 'approved' }
            default { 'unknown' }
        }
    }
    $isDraft = Get-BuddyProperty $PullRequest 'isDraft'
    $isActive = $PullRequest.status -eq 'active'
    $url = '{0}/{1}/_git/{2}/pullrequest/{3}' -f $Config.azureDevOps.organization.TrimEnd('/'),
        [Uri]::EscapeDataString($Config.azureDevOps.project),
        [Uri]::EscapeDataString($PullRequest.repository.name), $PullRequest.pullRequestId
    $comments = [System.Collections.Generic.List[object]]::new()
    $activeCount = 0
    $unknownCount = 0
    $excludedCount = 0
    foreach ($thread in $Threads) {
        if (Get-BuddyProperty $thread 'isDeleted' $false) { continue }
        $status = Get-BuddyThreadStatus (Get-BuddyProperty $thread 'status' 'unknown')
        $open = $status -in @('active', 'pending')
        if ($open) { $activeCount++ }
        if ($status -eq 'unknown') { $unknownCount++ }
        foreach ($comment in @(Get-BuddyProperty $thread 'comments' @())) {
            if ($null -eq $comment -or (Get-BuddyProperty $comment 'isDeleted' $false)) { continue }
            if ([string](Get-BuddyProperty $comment 'commentType' '') -in @('system', '3')) { continue }
            $content = [string](Get-BuddyProperty $comment 'content' '')
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            if (Test-BuddyExcludedComment $content $Config) { $excludedCount++; continue }
            $published = [DateTimeOffset]$comment.publishedDate
            $updated = [DateTimeOffset](Get-BuddyProperty $comment 'lastUpdatedDate' $comment.publishedDate)
            if ($published -gt $AsOf -or $updated -gt $AsOf) { continue }
            $recent = $updated -ge $Since
            if (-not $recent -and -not $open) { continue }
            $author = Get-BuddyProperty $comment 'author'
            $authorId = [string](Get-BuddyProperty $author 'id' '')
            $comments.Add([pscustomobject]@{
                id = ('{0}:thread:{1}:comment:{2}' -f $PullRequest.pullRequestId, $thread.id, $comment.id)
                threadId = $thread.id
                commentId = $comment.id
                threadStatus = $status
                openThread = $open
                author = Get-BuddyProperty $author 'displayName' 'Unknown'
                authoredByUser = $authorId -eq $UserId
                ownershipUnknown = [string]::IsNullOrWhiteSpace($authorId)
                publishedAt = $published.ToString('o')
                updatedAt = $updated.ToString('o')
                recent = $recent
                carryover = -not $recent
                content = if ($content.Length -gt $MaxCharacters) { $content.Substring(0, $MaxCharacters) } else { $content }
                contentTruncated = $content.Length -gt $MaxCharacters
                url = $url + '?discussionId=' + $thread.id
            })
        }
    }
    # Prefer recent incoming feedback without losing counts for older open discussions.
    $ordered = @($comments | Sort-Object @{ Expression = 'recent'; Descending = $true },
        @{ Expression = 'authoredByUser'; Descending = $false },
        @{ Expression = 'updatedAt'; Descending = $true })
    $included = @($ordered | Select-Object -First $MaxComments)
    $incomingRecent = @($comments | Where-Object { $_.recent -and -not $_.authoredByUser -and -not $_.ownershipUnknown }).Count
    $openIncoming = @($comments | Where-Object { $_.openThread -and -not $_.authoredByUser -and -not $_.ownershipUnknown }).Count
    $created = [DateTimeOffset]$PullRequest.creationDate
    if (-not $Ownership) {
        $Ownership = Resolve-BuddyOwnership -Settings $Config.azureDevOps -Repository $PullRequest.repository.name `
            -PullRequestId $PullRequest.pullRequestId -Creator $PullRequest.createdBy.id -UserIdentities @($UserId, $UserEmail) `
            -Roles $(if ($myReviews.Count) { @('reviewer') } else { @() }) `
            -Description ([string](Get-BuddyProperty $PullRequest 'description' ''))
    }
    $readiness = New-BuddyReadiness -Status $PullRequest.status -IsDraft $isDraft `
        -HeadCommit (Get-BuddyProperty (Get-BuddyProperty $PullRequest 'lastMergeSourceCommit') 'commitId') `
        -ObservedAt ([DateTimeOffset]::UtcNow) -Evidence $ReadinessEvidence -ActiveThreadCount $activeCount -UnknownThreadCount $unknownCount
    return [pscustomobject]@{
        id = ('ado:{0}:{1}' -f $PullRequest.repository.name, $PullRequest.pullRequestId)
        provider = 'ado'
        repository = $PullRequest.repository.name
        pullRequestId = $PullRequest.pullRequestId
        title = $PullRequest.title
        url = $url
        createdAt = $created.ToString('o')
        status = $PullRequest.status
        isDraft = $isDraft
        authoredByUser = $mine
        ownership = $Ownership
        delegatedToUser = $Ownership.delegated
        trackedByUser = $Ownership.tracked
        userIsAssignee = $false
        readiness = $readiness
        mergeReadyCandidate = $readiness.mergeReadyCandidate
        userIsReviewer = $myReviews.Count -gt 0
        userVote = $vote
        userReviewState = $reviewState
        reviewDecisionCandidate = $isActive -and $isDraft -eq $false -and $myReviews.Count -gt 0 -and $vote -eq 0
        reReviewCandidate = $isActive -and $isDraft -eq $false -and $myReviews.Count -gt 0 -and $vote -ne 0 -and $incomingRecent -gt 0
        sourceBranch = $PullRequest.sourceRefName
        targetBranch = $PullRequest.targetRefName
        headCommit = Get-BuddyProperty (Get-BuddyProperty $PullRequest 'lastMergeSourceCommit') 'commitId'
        reviewerCount = @($PullRequest.reviewers).Count
        rejectingReviewerCount = @($PullRequest.reviewers | Where-Object { $_.vote -eq -10 }).Count
        waitingForAuthorReviewerCount = @($PullRequest.reviewers | Where-Object { $_.vote -eq -5 }).Count
        approvingReviewerCount = @($PullRequest.reviewers | Where-Object { $_.vote -in @(5, 10) }).Count
        reviewers = @($PullRequest.reviewers | ForEach-Object {
            [pscustomobject]@{
                name = $_.displayName
                isUser = $_.id -eq $UserId
                vote = $_.vote
                isGroup = Get-BuddyProperty $_ 'isContainer' $false
                isRequired = Get-BuddyProperty $_ 'isRequired' $false
            }
        })
        activeThreadCount = $activeCount
        unknownStatusThreadCount = $unknownCount
        recentIncomingCommentCount = $incomingRecent
        openIncomingCommentCount = $openIncoming
        authoredFeedbackCandidate = $isActive -and ($mine -or $Ownership.delegated -or $Ownership.tracked) -and ($incomingRecent -gt 0 -or $openIncoming -gt 0)
        inWindowEvidence = ($created -ge $Since -and $created -le $AsOf) -or @($comments | Where-Object recent).Count -gt 0
        carryover = $created -lt $Since -and @($comments | Where-Object recent).Count -eq 0
        reviewVoteTimestampsAvailable = $false
        matchingCommentCount = $comments.Count
        omittedCommentCount = [Math]::Max(0, $comments.Count - $included.Count)
        truncatedCommentCount = @($included | Where-Object contentTruncated).Count
        excludedCommentCount = $excludedCount
        comments = $included
    }

}

. (Join-Path $PSScriptRoot 'Buddy.PullRequests.Core.ps1')
