function Get-BuddyExecutable {
    param([string]$Name, [string]$WindowsPath)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if (Test-Path -LiteralPath $WindowsPath -PathType Leaf) { return $WindowsPath }
    throw "$Name is not installed or is unavailable."
}

function Test-BuddyExcludedComment {
    param([string]$Content, $Config)
    $filters = Get-BuddyProperty $Config 'briefingFilters'
    return (Get-BuddyProperty $filters 'excludeIcmMessages' $false) -and
        $Content -match '(?i)\bIcM\b|icm\.ad\.msft\.net|icm\.microsoft\.com|portal\.microsofticm\.com'
}

function Get-BuddyAttributionText {
    param([string]$Description)
    $lines = [System.Collections.Generic.List[string]]::new()
    $fenceCharacter = ''
    $fenceLength = 0
    foreach ($line in ($Description -split '\r?\n')) {
        if ($fenceLength) {
            if ($line -match ('^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$')) {
                $fenceLength = 0
            }
            $lines.Add('')
        } elseif ($line -match '^ {0,3}(`{3,}|~{3,})') {
            $fenceCharacter = $Matches[1].Substring(0, 1)
            $fenceLength = $Matches[1].Length
            $lines.Add('')
        } elseif ($line -match '^(?: {4}|\t| {0,3}>)') {
            $lines.Add('')
        } else { $lines.Add($line) }
    }
    $text = $lines -join "`n"
    $redact = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return [regex]::Replace($match.Value, '[^\r\n]', ' ')
    }
    $text = [regex]::Replace($text, '(?is)<(pre|code|blockquote)\b[^>]*>.*?(?:</\1\s*>|\z)', $redact)
    $text = [regex]::Replace($text, '(?s)(`+)(?!`).*?(?<!`)\1(?!`)', $redact)
    return [regex]::Replace($text, '(?s)<!--.*?(?:-->|\z)', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value -cmatch '^<!-- COPILOT_AI_GENERATED_(START|END) -->$') { return $match.Value }
        return [regex]::Replace($match.Value, '[^\r\n]', ' ')
    })
}

function Resolve-BuddyOwnership {
    param(
        $Settings, [string]$Repository, [int]$PullRequestId,
        [string]$Creator, [string[]]$UserIdentities, [string]$Description,
        [string[]]$Roles = @()
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[object]]::new()
    foreach ($role in $Roles) { if ($role) { $reasons.Add($role) } }
    if ($Creator -and $Creator -in $UserIdentities -and 'authored' -notin $reasons) { $reasons.Add('authored') }
    $delegation = Get-BuddyProperty $Settings 'delegation'
    foreach ($tracked in @(Get-BuddyProperty $delegation 'trackedPullRequests' @())) {
        if ($tracked.repository -ieq $Repository -and $tracked.pullRequestId -eq $PullRequestId -and
            (Get-BuddyProperty $tracked 'confirmedByUser' $false) -is [bool] -and $tracked.confirmedByUser) {
            $reasons.Add('tracked')
            $evidence.Add([pscustomobject]@{ kind = 'user-confirmed'; source = 'configuration'; verified = $true })
        }
    }
    $trusted = @(Get-BuddyProperty $delegation 'trustedCreators' @())
    if ((Get-BuddyProperty $delegation 'enabled' $false) -and $Creator -and $Creator -in $trusted) {
        # Creator trust and exact description metadata establish triage membership, not approval.
        # Count markers before removing examples, so duplicate/ambiguous blocks fail closed.
        $attributionText = Get-BuddyAttributionText $Description
        $markerCount = [regex]::Matches($Description, '(?i)COPILOT_AI_GENERATED_(START|END)').Count
        $email = [string](Get-BuddyProperty $Settings 'userEmail' '')
        if ($email -and $email -in $UserIdentities -and $markerCount -eq 2 -and
            [regex]::Matches([System.Net.WebUtility]::HtmlDecode($Description), '(?i)\bCo-authored-by[ \t]*:').Count -eq 1) {
            $block = [regex]::Match($attributionText, '(?ms)^<!-- COPILOT_AI_GENERATED_START -->[ \t]*\n(?<body>.*?)^<!-- COPILOT_AI_GENERATED_END -->[ \t]*$')
            if ($block.Success) {
                foreach ($line in ($block.Groups['body'].Value -split '\n')) {
                    # Decode only trailer entities, never encoded block delimiters or quoted markup.
                    $trailer = [System.Net.WebUtility]::HtmlDecode($line)
                    if ($trailer -match '[\r\n]') { continue }
                    $coauthor = [regex]::Match($trailer, '(?i)^Co-authored-by:[ \t]+[^\s<>][^<>\r\n]*?[ \t]+<(?<email>[^<>\s]+)>[ \t]*$')
                    if ($coauthor.Success -and $coauthor.Groups['email'].Value -ieq $email) {
                        $reasons.Add('delegated')
                        $evidence.Add([pscustomobject]@{
                            kind = 'verified-copilot-coauthor'; source = 'pull-request-description'
                            creator = $Creator; trustedCreator = $true; identity = $email
                            marker = 'Co-authored-by'
                            blockStart = '<!-- COPILOT_AI_GENERATED_START -->'
                            blockEnd = '<!-- COPILOT_AI_GENERATED_END -->'
                            verified = $true
                        })
                        break
                    }
                }
            }
        }
        if (-not $markerCount -and (Get-BuddyProperty $delegation 'allowOnBehalfMarker' $false)) {
            $markers = @([regex]::Matches($attributionText, '(?im)^On-behalf-of:[ \t]*([^ \t\r\n]+)[ \t]*$'))
            if ($markers.Count -eq 1 -and $markers[0].Groups[1].Value -in @($UserIdentities | Where-Object { $_ })) {
                $reasons.Add('delegated')
                $evidence.Add([pscustomobject]@{
                    kind = 'verified-on-behalf'; source = 'pull-request-description'
                    creator = $Creator; trustedCreator = $true; identity = $markers[0].Groups[1].Value
                    marker = 'On-behalf-of'; verified = $true
                })
            }
        }
    }
    [pscustomobject]@{
        included = $reasons.Count -gt 0
        reasons = @($reasons | Select-Object -Unique)
        delegated = 'delegated' -in $reasons
        tracked = 'tracked' -in $reasons
        evidence = $evidence.ToArray()
    }
}

function New-BuddyReadiness {
    param(
        [string]$Status, $IsDraft, [string]$HeadCommit, [DateTimeOffset]$ObservedAt,
        $Evidence, [int]$ActiveThreadCount, [int]$UnknownThreadCount
    )
    $blockers = [System.Collections.Generic.List[string]]::new()
    $unknowns = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[string]]::new()
    if ($Status -notin @('active', 'open', 'OPEN')) { $blockers.Add('PR is not open.') }
    if ($null -eq $IsDraft) { $unknowns.Add('Draft state is unknown.') }
    elseif ($IsDraft) { $blockers.Add('PR is a draft.'); $actions.Add('Complete the draft review before requesting merge approval.') }
    if (-not $HeadCommit) { $unknowns.Add('Head commit is unavailable.') }
    if (-not (Get-BuddyProperty $Evidence 'headStable' $false)) { $unknowns.Add('Head/base consistency has not been verified.') }
    $conflicts = [string](Get-BuddyProperty $Evidence 'conflicts' 'unknown')
    if ($conflicts -eq 'conflicting') { $blockers.Add('Merge conflicts exist.'); $actions.Add('Resolve conflicts and rerun checks on the new head.') }
    elseif ($conflicts -ne 'clear') { $unknowns.Add('Conflict state is unknown.') }
    $states = @{}
    foreach ($area in @('checks', 'policies', 'approvals')) {
        $part = Get-BuddyProperty $Evidence $area
        if ($null -eq $part) { $part = [pscustomobject]@{ state = 'unknown'; coverage = 'unavailable'; items = @() } }
        $states[$area] = $part
        $state = [string](Get-BuddyProperty $part 'state' 'unknown')
        if ((Get-BuddyProperty $part 'coverage' 'unavailable') -ne 'complete') {
            $unknowns.Add("$area coverage is incomplete.")
        }
        if ($state -in @('failed', 'pending', 'blocked')) {
            $blockers.Add("$area are $state.")
            $actions.Add("Inspect $area details and address outstanding requirements.")
        } elseif ($state -ne 'passed') { $unknowns.Add("$area requirements or result are unknown.") }
    }
    if (-not (Get-BuddyProperty $Evidence 'threadsComplete' $false)) { $unknowns.Add('Review thread coverage is incomplete.') }
    if ($UnknownThreadCount -gt 0) { $unknowns.Add("$UnknownThreadCount review thread statuses are unknown.") }
    if ($ActiveThreadCount -gt 0) {
        $blockers.Add("$ActiveThreadCount open review threads.")
        $actions.Add('Read open threads and verify whether a reply or code change is owed; do not auto-resolve.')
    }
    foreach ($text in @(Get-BuddyProperty $Evidence 'unknowns' @())) { $unknowns.Add($text) }
    foreach ($text in @(Get-BuddyProperty $Evidence 'blockers' @())) { $blockers.Add($text) }
    if ($unknowns.Count) { $actions.Add('Re-fetch missing checks, branch policy, approvals, and thread evidence before a merge decision.') }
    $candidate = $blockers.Count -eq 0 -and $unknowns.Count -eq 0
    if ($candidate) { $actions.Add('Candidate only: revalidate head/base and every requirement, then obtain explicit human merge approval.') }
    [pscustomobject]@{
        status = if ($Status -notin @('active', 'open', 'OPEN')) { 'not-open' } elseif ($blockers.Count) { 'blocked' } elseif ($unknowns.Count) { 'unknown' } else { 'merge-ready-candidate' }
        mergeReadyCandidate = $candidate
        blockers = @($blockers | Select-Object -Unique)
        unknowns = @($unknowns | Select-Object -Unique)
        nextActions = @($actions | Select-Object -Unique)
        checks = $states.checks; policies = $states.policies; approvals = $states.approvals
        conflicts = $conflicts
        openThreadCount = $ActiveThreadCount
        threadCoverage = if (Get-BuddyProperty $Evidence 'threadsComplete' $false) { 'complete' } else { 'partial-or-unavailable' }
        headCommit = $HeadCommit
        observedAt = $ObservedAt.ToString('o')
        requiresRevalidation = $true
        automaticMergeAllowed = $false
    }
}

function Assert-BuddyInventorySettings {
    param($Config)
    foreach ($provider in @('azureDevOps', 'github')) {
        $settings = Get-BuddyProperty $Config $provider
        if (-not $settings) { continue }
        $tenantId = Get-BuddyProperty $settings 'tenantId'
        if ($null -ne $tenantId -and ($provider -ne 'azureDevOps' -or $tenantId -isnot [string] -or
            $tenantId -notmatch '^[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$' -or
            $tenantId -eq [Guid]::Empty.ToString())) {
            throw 'Azure DevOps tenantId must be the organization tenant GUID or null.'
        }
        $delegation = Get-BuddyProperty $settings 'delegation'
        $unconfiguredEmail = $provider -eq 'azureDevOps' -and
            $null -eq (Get-BuddyProperty $settings 'userEmail') -and
            (Get-BuddyProperty $delegation 'enabled' $true) -eq $false
        if ($null -ne $settings.PSObject.Properties['userEmail'] -and -not $unconfiguredEmail) {
            $userEmail = $settings.userEmail
            $address = $null
            if ($provider -ne 'azureDevOps' -or $userEmail -isnot [string] -or
                $userEmail.Length -gt 254 -or $userEmail -match '[\s<>]' -or
                -not [System.Net.Mail.MailAddress]::TryCreate($userEmail, [ref]$address) -or
                $address.Address -cne $userEmail -or -not $address.Host.Contains('.')) {
                throw 'Invalid Azure DevOps userEmail; configure the verified identity email without a display name.'
            }
        }
        if ($provider -eq 'github') {
            $enabled = Get-BuddyProperty $settings 'enabled' $true
            if ($enabled -isnot [bool]) { throw 'GitHub enabled must be a boolean.' }
            if ($enabled -and ($settings.login -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$' -or
                @($settings.repositories).Count -eq 0 -or
                @($settings.repositories | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_.-]+$' -or $_.Split('/')[1] -in @('.', '..') }).Count)) {
                throw 'Invalid GitHub login or repository scope.'
            }
        }
        foreach ($limit in @('maxPages', 'pageSize', 'maxPullRequests', 'maxCommentsPerPullRequest', 'maxCommentCharacters')) {
            $value = Get-BuddyProperty $settings $limit
            if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 10000)) {
                throw "Invalid $provider limit: $limit"
            }
        }
        if ((Get-BuddyProperty $settings 'pageSize' 100) -gt 100 -or (Get-BuddyProperty $settings 'maxPages' 3) -gt 100) {
            throw 'Page size cannot exceed 100; page count cannot exceed 100.'
        }
        $delegation = Get-BuddyProperty $settings 'delegation'
        if ($null -ne $delegation -and $null -ne $delegation.PSObject.Properties['allowOnBehalfMarker'] -and
            $delegation.allowOnBehalfMarker -isnot [bool]) {
            throw 'allowOnBehalfMarker must be a boolean when configured.'
        }
        foreach ($creator in @(Get-BuddyProperty $delegation 'trustedCreators' @())) {
            $pattern = if ($provider -eq 'github') { '^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}(\[bot\])?$' } else { '^[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$' }
            if ($creator -isnot [string] -or $creator -notmatch $pattern) { throw "Invalid $provider trusted creator identity." }
        }
        foreach ($tracked in @(Get-BuddyProperty $delegation 'trackedPullRequests' @())) {
            if ($tracked.repository -notin $settings.repositories -or
                $tracked.pullRequestId -isnot [long] -and $tracked.pullRequestId -isnot [int] -or
                $tracked.pullRequestId -lt 1 -or $tracked.pullRequestId -gt [int]::MaxValue -or
                (Get-BuddyProperty $tracked 'confirmedByUser' $false) -isnot [bool] -or -not $tracked.confirmedByUser) {
                throw 'Tracked PRs require an approved repository, positive integer ID, and confirmedByUser: true.'
            }
        }
    }
}
