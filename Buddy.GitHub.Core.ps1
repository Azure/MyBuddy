function ConvertTo-BuddyGitHubPullRequest {
    param(
        [Parameter(Mandatory)]$PullRequest, [string]$Repository, [string]$Login,
        [object[]]$Threads = @(), [object[]]$IssueComments = @(), [object[]]$Reviews = @(),
        [object[]]$ReviewRequests = @(), [string[]]$DiscoveryRoles = @(),
        [DateTimeOffset]$Since, [DateTimeOffset]$AsOf, $Config, $ReadinessEvidence,
        [bool]$CommentsComplete = $false
    )
    $settings = $Config.github
    $mine = (Get-BuddyProperty $PullRequest.author 'login') -ieq $Login
    $assigned = @($PullRequest.assignees.nodes | Where-Object login -eq $Login).Count -gt 0
    $requested = @($ReviewRequests | Where-Object { (Get-BuddyProperty (Get-BuddyProperty $_ 'requestedReviewer') 'login') -ieq $Login }).Count -gt 0
    $myReviews = @($Reviews | Where-Object { (Get-BuddyProperty $_.author 'login') -ieq $Login } | Sort-Object submittedAt -Descending)
    $latestDecisions = @($Reviews | Where-Object state -in @('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED') |
        Sort-Object submittedAt -Descending | Group-Object { Get-BuddyProperty $_.author 'login' } | ForEach-Object { $_.Group[0] })
    $myDecision = @($latestDecisions | Where-Object { (Get-BuddyProperty $_.author 'login') -ieq $Login })
    $reviewState = if ($myDecision.Count) { [string]$myDecision[0].state } elseif ($requested) { 'not-reviewed' } elseif ($myReviews.Count) { 'commented' } else { 'not-assigned' }
    $roles = @($DiscoveryRoles)
    if ($mine) { $roles += 'authored' }
    if ($assigned) { $roles += 'assigned' }
    if ($requested) { $roles += 'review-requested' }
    if ($myReviews.Count) { $roles += 'reviewed' }
    $ownership = Resolve-BuddyOwnership -Settings $settings -Repository $Repository -PullRequestId $PullRequest.number `
        -Creator ([string](Get-BuddyProperty $PullRequest.author 'login')) -UserIdentities @($Login) `
        -Description ([string](Get-BuddyProperty $PullRequest 'body' '')) -Roles $roles
    $comments = [System.Collections.Generic.List[object]]::new()
    $excluded = 0
    $openCount = 0
    $unknownCount = 0
    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($thread in $Threads) {
        $resolved = Get-BuddyProperty $thread 'isResolved'
        $open = $resolved -eq $false
        if ($null -eq $resolved) { $unknownCount++ }
        if ($open) { $openCount++ }
        foreach ($comment in @($thread.comments.nodes)) {
            $sources.Add([pscustomobject]@{ comment = $comment; threadId = $thread.id; open = $open; state = if ($null -eq $resolved) { 'unknown' } elseif ($open) { 'active' } else { 'fixed' }; kind = 'review-thread' })
        }
    }
    foreach ($comment in $IssueComments) {
        $sources.Add([pscustomobject]@{ comment = $comment; threadId = $null; open = $false; state = 'not-applicable'; kind = 'conversation' })
    }
    foreach ($review in $Reviews) {
        if (-not (Get-BuddyProperty $review 'submittedAt') -or (Get-BuddyProperty $review 'state') -eq 'PENDING') { continue }
        $sources.Add([pscustomobject]@{
            comment = [pscustomobject]@{
                id = Get-BuddyProperty $review 'id'; body = Get-BuddyProperty $review 'body' ''
                author = $review.author; createdAt = $review.submittedAt; updatedAt = $review.submittedAt
                url = Get-BuddyProperty $review 'url' $PullRequest.url
            }
            threadId = $null; open = $false; state = 'not-applicable'; kind = 'review'
        })
    }
    foreach ($source in $sources) {
        $comment = $source.comment
        $body = [string](Get-BuddyProperty $comment 'body' '')
        if (-not $body) { continue }
        if (Test-BuddyExcludedComment $body $Config) { $excluded++; continue }
        $created = [DateTimeOffset](Get-BuddyProperty $comment 'createdAt')
        $updated = [DateTimeOffset](Get-BuddyProperty $comment 'updatedAt' $created)
        if ($created -gt $AsOf -or $updated -gt $AsOf) { continue }
        $recent = $updated -ge $Since
        if (-not $recent -and -not $source.open) { continue }
        $author = [string](Get-BuddyProperty $comment.author 'login' '')
        $comments.Add([pscustomobject]@{
            id = "github:$Repository`:$($PullRequest.number):comment:$($comment.id)"
            commentId = $comment.id; threadId = $source.threadId; kind = $source.kind
            threadStatus = $source.state; openThread = $source.open
            author = if ($author) { $author } else { 'Unknown' }
            authoredByUser = $author -ieq $Login; ownershipUnknown = -not $author
            publishedAt = $created.ToString('o'); updatedAt = $updated.ToString('o')
            recent = $recent; carryover = -not $recent
            content = if ($body.Length -gt $settings.maxCommentCharacters) { $body.Substring(0, $settings.maxCommentCharacters) } else { $body }
            contentTruncated = $body.Length -gt $settings.maxCommentCharacters
            url = Get-BuddyProperty $comment 'url' $PullRequest.url
        })
    }
    $included = @($comments | Sort-Object @{ Expression = 'recent'; Descending = $true },
        @{ Expression = 'authoredByUser'; Descending = $false }, @{ Expression = 'updatedAt'; Descending = $true } |
        Select-Object -First $settings.maxCommentsPerPullRequest)
    $incomingRecent = @($comments | Where-Object { $_.recent -and -not $_.authoredByUser -and -not $_.ownershipUnknown }).Count
    $incomingOpen = @($comments | Where-Object { $_.openThread -and -not $_.authoredByUser -and -not $_.ownershipUnknown }).Count
    $createdAt = [DateTimeOffset]$PullRequest.createdAt
    $recentEvidence = ($createdAt -ge $Since -and $createdAt -le $AsOf) -or @($comments | Where-Object recent).Count -gt 0
    $isDraft = Get-BuddyProperty $PullRequest 'isDraft'
    $active = $PullRequest.state -eq 'OPEN'
    $readiness = New-BuddyReadiness -Status $PullRequest.state -IsDraft $isDraft -HeadCommit $PullRequest.headRefOid `
        -ObservedAt ([DateTimeOffset]::UtcNow) -Evidence $ReadinessEvidence -ActiveThreadCount $openCount -UnknownThreadCount $unknownCount
    [pscustomobject]@{
        id = "github:$Repository`:$($PullRequest.number)"; provider = 'github'
        repository = $Repository; pullRequestId = $PullRequest.number; title = $PullRequest.title; url = $PullRequest.url
        status = if ($active) { 'active' } elseif ($PullRequest.state -eq 'MERGED') { 'completed' } else { 'abandoned' }
        providerStatus = $PullRequest.state; createdAt = $createdAt.ToString('o'); isDraft = $isDraft
        authoredByUser = $mine; userIsAssignee = $assigned; userIsReviewer = $requested -or $myReviews.Count -gt 0
        delegatedToUser = $ownership.delegated; trackedByUser = $ownership.tracked; ownership = $ownership
        userReviewState = $reviewState; userVote = $null
        reviewDecisionCandidate = $active -and $isDraft -eq $false -and $requested
        reReviewCandidate = $active -and $isDraft -eq $false -and $requested -and $myReviews.Count -gt 0
        authoredFeedbackCandidate = $active -and ($mine -or $ownership.delegated -or $ownership.tracked) -and ($incomingRecent -gt 0 -or $incomingOpen -gt 0)
        sourceBranch = $PullRequest.headRefName; targetBranch = $PullRequest.baseRefName; headCommit = $PullRequest.headRefOid
        reviewerCount = $latestDecisions.Count
        rejectingReviewerCount = @($latestDecisions | Where-Object state -eq 'CHANGES_REQUESTED').Count
        waitingForAuthorReviewerCount = 0
        approvingReviewerCount = @($latestDecisions | Where-Object state -eq 'APPROVED').Count
        reviewers = @($latestDecisions | ForEach-Object {
            [pscustomobject]@{ name = Get-BuddyProperty $_.author 'login' 'Unknown'; state = $_.state; submittedAt = $_.submittedAt; isUser = (Get-BuddyProperty $_.author 'login') -ieq $Login }
        })
        activeThreadCount = $openCount; unknownStatusThreadCount = $unknownCount
        recentIncomingCommentCount = $incomingRecent; openIncomingCommentCount = $incomingOpen
        inWindowEvidence = $recentEvidence; carryover = -not $recentEvidence -and $createdAt -lt $Since
        reviewVoteTimestampsAvailable = $true; commentCoverage = if ($CommentsComplete) { 'complete' } else { 'partial' }
        matchingCommentCount = $comments.Count; omittedCommentCount = [Math]::Max(0, $comments.Count - $included.Count)
        truncatedCommentCount = @($included | Where-Object contentTruncated).Count
        excludedCommentCount = $excluded; comments = $included
        readiness = $readiness; mergeReadyCandidate = $readiness.mergeReadyCandidate
    }
}

function Get-BuddyGitHubEvidence {
    param($Pr, $Checks, $Rules, $Reviews, [bool]$ThreadsComplete, [bool]$HeadStable)
    $checkItems = @($Checks.items | ForEach-Object {
        $isRun = $_.__typename -eq 'CheckRun'
        [pscustomobject]@{
            name = if ($isRun) { $_.name } else { $_.context }
            state = if ($isRun -and $_.status -ne 'COMPLETED') { 'PENDING' } elseif ($isRun) { [string]$_.conclusion } else { $_.state }
            required = Get-BuddyProperty $_ 'isRequired'
            url = if ($isRun) { Get-BuddyProperty $_ 'detailsUrl' } else { Get-BuddyProperty $_ 'targetUrl' }
            kind = $_.__typename
            appId = if ($isRun) { Get-BuddyProperty (Get-BuddyProperty (Get-BuddyProperty $_ 'checkSuite') 'app') 'databaseId' } else { $null }
        }
    })
    $protection = Get-BuddyProperty (Get-BuddyProperty $Pr 'baseRef') 'branchProtectionRule'
    $protectionKnown = $null -ne (Get-BuddyProperty $Pr 'baseRef') -and $null -ne $Pr.baseRef.PSObject.Properties['branchProtectionRule']
    $requiredNames = [System.Collections.Generic.List[string]]::new()
    foreach ($context in @(Get-BuddyProperty $protection 'requiredStatusCheckContexts' @())) { $requiredNames.Add($context) }
    $unknowns = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $protection) {
        foreach ($field in @('requiresStatusChecks', 'requiresApprovingReviews', 'requiredApprovingReviewCount', 'requiresConversationResolution')) {
            if ($null -eq (Get-BuddyProperty $protection $field)) { $unknowns.Add("Legacy branch protection field '$field' is unavailable.") }
        }
    }
    foreach ($check in @(Get-BuddyProperty $protection 'requiredStatusChecks' @())) {
        $requiredNames.Add($check.context)
        $appId = Get-BuddyProperty (Get-BuddyProperty $check 'app') 'databaseId'
        if ($appId -and @($checkItems | Where-Object { $_.name -eq $check.context -and $_.appId -eq $appId }).Count -eq 0) {
            $unknowns.Add("Legacy required check integration could not be verified: $($check.context).")
        }
    }
    if ((Get-BuddyProperty $protection 'requiresStatusChecks' $false) -and
        $null -eq $protection.PSObject.Properties['requiredStatusChecks']) {
        $unknowns.Add('Required-check integration bindings are unavailable.')
    }
    $policyBlockers = [System.Collections.Generic.List[string]]::new()
    $requiredReviews = [int](Get-BuddyProperty $protection 'requiredApprovingReviewCount' 0)
    foreach ($rule in $Rules.items) {
        $type = [string](Get-BuddyProperty $rule 'type' '')
        $parameters = Get-BuddyProperty $rule 'parameters'
        if ($type -eq 'required_status_checks') {
            if ($null -eq (Get-BuddyProperty $parameters 'required_status_checks')) { $unknowns.Add('Required-status-check rule parameters are unavailable.') }
            foreach ($check in @(Get-BuddyProperty $parameters 'required_status_checks' @())) {
                $requiredNames.Add($check.context)
                $integration = Get-BuddyProperty $check 'integration_id'
                if ($integration -and @($checkItems | Where-Object { $_.name -eq $check.context -and $_.appId -eq $integration }).Count -eq 0) {
                    $unknowns.Add("Required check integration could not be verified: $($check.context).")
                }
            }
        } elseif ($type -eq 'pull_request') {
            if ($null -eq (Get-BuddyProperty $parameters 'required_approving_review_count')) { $unknowns.Add('Required pull-request approval parameters are unavailable.') }
            $requiredReviews = [Math]::Max($requiredReviews, [int](Get-BuddyProperty $parameters 'required_approving_review_count' 0))
        } elseif ($type -notin @('non_fast_forward', 'deletion', 'creation')) {
            $unknowns.Add("Rule '$type' requires manual verification; it is not fully modeled.")
        }
    }
    $names = @($checkItems | ForEach-Object name)
    $missing = @($requiredNames | Select-Object -Unique | Where-Object { $_ -notin $names })
    $checkState = if (-not $Checks.complete) { 'unknown' }
        elseif ($missing.Count -gt 0) { 'pending' }
        elseif (@($checkItems | Where-Object state -in @('FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'STALE')).Count) { 'failed' }
        elseif (@($checkItems | Where-Object state -in @('PENDING', 'EXPECTED', 'QUEUED', 'IN_PROGRESS', 'WAITING', 'REQUESTED')).Count) { 'pending' }
        elseif (@($checkItems | Where-Object state -notin @('SUCCESS', 'NEUTRAL', 'SKIPPED')).Count) { 'unknown' }
        elseif (@($checkItems | Where-Object { $null -eq $_.required }).Count) { 'unknown' }
        else { 'passed' }
    if ((Get-BuddyProperty $protection 'requiresStatusChecks' $false) -and $requiredNames.Count -eq 0) {
        $unknowns.Add('Branch requires status checks but its required context list is unavailable.')
    }
    $decision = [string](Get-BuddyProperty $Pr 'reviewDecision' '')
    $latest = @($Reviews.items | Where-Object state -in @('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED') |
        Sort-Object submittedAt -Descending | Group-Object { Get-BuddyProperty $_.author 'login' } | ForEach-Object { $_.Group[0] })
    $approvalsState = if (-not $Reviews.complete) { 'unknown' }
        elseif ($decision -eq 'CHANGES_REQUESTED' -or @($latest | Where-Object state -eq 'CHANGES_REQUESTED').Count) { 'failed' }
        elseif ($decision -eq 'REVIEW_REQUIRED') { 'pending' }
        elseif ($decision -eq 'APPROVED') { 'passed' }
        elseif ($requiredReviews -eq 0 -and -not (Get-BuddyProperty $protection 'requiresApprovingReviews' $false) -and $Rules.complete -and $protectionKnown) { 'passed' }
        else { 'unknown' }
    $mergeState = [string](Get-BuddyProperty $Pr 'mergeStateStatus' 'UNKNOWN')
    if ($mergeState -in @('BLOCKED', 'BEHIND', 'UNSTABLE')) { $policyBlockers.Add("GitHub merge state is $mergeState; inspect branch requirements.") }
    elseif ($mergeState -notin @('CLEAN', 'DIRTY', 'DRAFT')) { $unknowns.Add("GitHub merge state is $mergeState.") }
    $policyState = if (-not $Rules.complete -or -not $protectionKnown -or $unknowns.Count) { 'unknown' }
        elseif ($policyBlockers.Count) { 'blocked' } else { 'passed' }
    [pscustomobject]@{
        headStable = $HeadStable; threadsComplete = $ThreadsComplete
        conflicts = switch ([string](Get-BuddyProperty $Pr 'mergeable' 'UNKNOWN')) { 'MERGEABLE' { 'clear' }; 'CONFLICTING' { 'conflicting' }; default { 'unknown' } }
        checks = [pscustomobject]@{ state = $checkState; coverage = if ($Checks.complete) { 'complete' } else { 'partial' }; items = $checkItems; missingRequired = $missing; requirementsSource = 'legacy-branch-protection-and-effective-rules' }
        policies = [pscustomobject]@{
            state = $policyState; coverage = if ($Rules.complete -and $protectionKnown) { 'complete' } else { 'partial' }
            mergeState = $mergeState; requiredChecks = @($requiredNames | Select-Object -Unique)
            rules = @($Rules.items | ForEach-Object { [pscustomobject]@{ type = $_.type } })
            legacyBranchProtectionPresent = $null -ne $protection
        }
        approvals = [pscustomobject]@{
            state = $approvalsState; coverage = if ($Reviews.complete) { 'complete' } else { 'partial' }
            decision = $decision; requiredCount = $requiredReviews
            approved = @($latest | Where-Object state -eq 'APPROVED').Count
            changesRequested = @($latest | Where-Object state -eq 'CHANGES_REQUESTED').Count
        }
        unknowns = $unknowns.ToArray(); blockers = $policyBlockers.ToArray()
    }
}
