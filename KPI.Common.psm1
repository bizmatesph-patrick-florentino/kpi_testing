# KPI.Common.psm1 â€” shared library for all KPI commands (ACR now; RR/MLT reuse later).
# Public API is exported at the bottom; every other function stays private to the module.

#region config
# Reads, parses, and validates global-config.json. Returns a validated config object. (R1)
# 'test' is the default environment the downstream Resolve-KpiEnvironment selects (R1.2).
function Import-KpiConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { New-KpiError "Config file not found: $Path" }            # 1.10 path context
    try   { $cfg = Get-Content $Path -Raw | ConvertFrom-Json }
    catch { New-KpiError "Config file is not valid JSON: $Path. $($_.Exception.Message)" }  # 1.10 names file

    # Required dotted keys -> drive 1.8 presence check + 1.9 exact-key naming on failure.
    $required = @(
        'environments.test.baseUrl','environments.test.email','environments.test.apiToken',
        'environments.live.baseUrl','environments.live.email','environments.live.apiToken',
        'github.baseUrl','github.token',
        'phaseKeywordMap','validTargetBranches','aiEvidencedFieldId',
        'uatPassedStatus'
    )
    # Collections validate as non-empty; scalars validate as non-null/whitespace.
    $collectionKeys = @('phaseKeywordMap','validTargetBranches')
    foreach ($key in $required) {
        $value = Get-ConfigValue $cfg $key                                                 # 1.8 resolve required key
        if ($key -in $collectionKeys) {
            if ($null -eq $value -or (Measure-ConfigCount $value) -eq 0) {
                New-KpiError "Missing or empty configuration key: $key"                     # 1.9 names key, stops
            }
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$value)) {
            New-KpiError "Missing or empty configuration key: $key"                         # 1.9 names key, stops
        }
    }
    return $cfg
}

# Private: resolves a dotted path (e.g. environments.test.baseUrl) to its config value.
function Get-ConfigValue {
    [CmdletBinding()]
    param([object]$Config, [string]$DottedPath)
    $node = $Config
    foreach ($segment in $DottedPath.Split('.')) {       # walk each dotted segment
        if ($null -eq $node) { return $null }            # missing parent -> value is absent
        $node = $node.PSObject.Properties[$segment] | ForEach-Object { $_.Value }
    }
    return $node
}

# Private: counts members of a config collection (JSON object or array) for non-empty checks.
function Measure-ConfigCount {
    [CmdletBinding()]
    param([object]$Value)
    if ($Value -is [System.Management.Automation.PSCustomObject]) {   # JSON object -> count properties (phaseKeywordMap)
        return @($Value.PSObject.Properties).Count
    }
    return @($Value).Count                                            # array/scalar -> element count (validTargetBranches)
}
#endregion config

#region environment
# Validates -Environment and returns the matching environment block (default: test). (R2)
# Re-validates at library level so RR/MLT reuse is safe even though commands also use [ValidateSet].
function Resolve-KpiEnvironment {
    [CmdletBinding()]
    param([object]$Config, [string]$Environment = 'test')   # 2.2 default 'test' when omitted
    if ($Environment -notin @('test','live')) {
        New-KpiError "Invalid -Environment '$Environment'. Accepted values: test, live."   # 2.3 list accepted, stop
    }
    return $Config.environments.$Environment                 # 2.1/2.4 supply baseUrl/email/apiToken
}
#endregion environment

#region jira
# Private: single authenticated JIRA call (basic auth email:apiToken); returns parsed body. (R3)
function Invoke-JiraRequest {
    [CmdletBinding()]
    param([object]$Env, [string]$Path, [hashtable]$Query, [string]$Method = 'GET')
    # 3.1 basic auth header from base64("email:apiToken"); token value never logged.
    $pair    = "$($Env.email):$($Env.apiToken)"
    $basic   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Authorization = "Basic $basic"; Accept = 'application/json' }
    $uri     = Join-JiraUri $Env.baseUrl $Path $Query
    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method   # 3.1/3.2 primary data access
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__                     # may be null on transport errors
        if ($status -in 401,403) {
            New-KpiError "JIRA authentication failed ($status) for $Path."     # 3.4 identify auth failure, stop
        }
        New-KpiError "JIRA request failed ($status) for $Path. $($_.Exception.Message)"   # 3.5 status + request context
    }
}

# Private: builds a full JIRA URI from base URL + path + URL-encoded query string. (R3)
function Join-JiraUri {
    [CmdletBinding()]
    param([string]$BaseUrl, [string]$Path, [hashtable]$Query)
    $uri = "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"                  # join base + path without double slash
    if ($Query -and $Query.Count -gt 0) {                                     # append URL-encoded query when present
        $parts = foreach ($k in $Query.Keys) {
            "{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k])
        }
        $uri = "${uri}?$($parts -join '&')"   # brace-delimit so the base URI is not dropped before '?'
    }
    return $uri
}

# Resolves the "AI Evidenced" custom field id so it can be recorded in config. (R4)
function Get-JiraFields {
    [CmdletBinding()]
    param([object]$Env, [string]$FieldName = 'AI Evidenced')
    $fields = Invoke-JiraRequest $Env '/rest/api/3/field'                                # 4.1 query field metadata
    $match  = $fields | Where-Object { $_.name -eq $FieldName } | Select-Object -First 1 # 4.2 match name, take one
    if (-not $match) { return "Field '$FieldName' not found." }                          # 4.4 non-fatal not-found message
    return $match.id                                                                     # 4.3 id for aiEvidencedFieldId
}

# Private: classifies a ticket's AI assistance, returning both the boolean and the evidence source. (R5)
# Precedence: a present, non-empty AI Evidenced field is authoritative and overrides Labels;
# only an empty or absent field falls back to a trimmed case-insensitive exact label match.
# Returns @{ IsAssisted = <bool>; Source = 'AIEvidenced' | 'Label' | 'None' } so callers can show why.
# AssistedValue is the configured marker (e.g. "AI-Assisted"); defaults to "AI-Assisted" if not supplied.
function Resolve-TicketAiEvidence {
    [CmdletBinding()]
    param([object]$Ticket, [string]$AiFieldId, [string]$AssistedValue = 'AI-Assisted')

    # Read the field only if the property exists; absent -> no candidates, never errors (R5.3).
    # The AI Evidenced field can be a plain string, an option object (.value), or an ARRAY of either
    # (multi-select / labels-type field). Flatten every shape into comparable candidate strings.
    $candidates = @()
    $fields     = $Ticket.fields
    if ($fields -and ($fields.PSObject.Properties.Name -contains $AiFieldId)) {
        foreach ($item in @($fields.$AiFieldId)) {
            if ($null -eq $item) { continue }
            $candidates += if ($item -is [string]) { $item }
                           elseif ($item.PSObject.Properties.Name -contains 'value') { [string]$item.value }
                           else { [string]$item }
        }
    }
    $hasFieldValue = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0

    # 5.1 field override wins (case-insensitive exact match on the configured marker, any candidate).
    foreach ($cand in $candidates) {
        if ($cand -and ([string]$cand).Trim().Equals($AssistedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ IsAssisted = $true; Source = 'AIEvidenced' }
        }
    }
    # Field present and non-empty but not the marker -> authoritative not-assisted (R5 override).
    if ($hasFieldValue) { return @{ IsAssisted = $false; Source = 'None' } }

    # Field empty or absent (5.2 / 5.3) -> trimmed, case-insensitive EXACT label match (5.4), no partials.
    foreach ($label in @($fields.labels)) {
        if ($label -and ([string]$label).Trim().Equals($AssistedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ IsAssisted = $true; Source = 'Label' }              # 5.4 exact label match
        }
    }
    return @{ IsAssisted = $false; Source = 'None' }                      # 5.5 neither source matched
}

# Private: boolean-only AI assistance check (thin wrapper over Resolve-TicketAiEvidence). (R5)
function Test-TicketAiAssisted {
    [CmdletBinding()]
    param([object]$Ticket, [string]$AiFieldId, [string]$AssistedValue = 'AI-Assisted')
    return (Resolve-TicketAiEvidence $Ticket $AiFieldId $AssistedValue).IsAssisted
}

# Private: maps an Epic name to one of five phases via config keyword map; else Unassigned. (R6)
function Resolve-TicketPhase {
    [CmdletBinding()]
    param([string]$EpicName, [object]$PhaseKeywordMap)
    if ($EpicName) {                                              # empty/null Epic skips mapping -> Unassigned (R6.3)
        foreach ($phase in $PhaseKeywordMap.PSObject.Properties) {   # 6.1 iterate configured phases
            foreach ($kw in $phase.Value) {
                if ($EpicName -like "*$kw*") { return $phase.Name }  # 6.2 first keyword hit wins -> single phase
            }
        }
    }
    return 'Unassigned'                                          # 6.3 no keyword matched or empty Epic
}

# Private: returns the assignee display name, or Unknown when no assignee. (R7)
function Resolve-TicketDeveloper {
    [CmdletBinding()]
    param([object]$Assignee)
    if ($Assignee -and $Assignee.displayName) { return $Assignee.displayName }   # 7.1 assignee display name
    return 'Unknown'                                                             # 7.2 no assignee -> documented Unknown bucket
}

# Private: normalizes a raw JIRA issue into a KPI ticket (key/project/dev/phase/ai). (R5/R6/R7)
function ConvertTo-KpiTicket {
    [CmdletBinding()]
    param([object]$Issue, [object]$Config)
    $fields = $Issue.fields                                                      # may be sparse; guard every nested read
    # Epic name from the parent (Epic link) summary when present; else null feeds Unassigned (R6.3).
    $epicName = if ($fields -and $fields.parent -and $fields.parent.fields) { $fields.parent.fields.summary } else { $null }
    $aiVal    = if ($Config.PSObject.Properties.Name -contains 'aiAssistedValue' -and $Config.aiAssistedValue) { $Config.aiAssistedValue } else { 'AI-Assisted' }
    $evidence = Resolve-TicketAiEvidence $Issue $Config.aiEvidencedFieldId $aiVal                        # R5 AI evidence + source
    return [pscustomobject]@{
        Key          = $Issue.key
        Summary      = if ($fields) { $fields.summary } else { $null }                                  # ticket title for the per-ticket table
        IssueType    = if ($fields -and $fields.issuetype) { $fields.issuetype.name } else { $null }    # issue type (Epics already filtered out)
        Project      = if ($fields -and $fields.project) { $fields.project.key } else { $null }        # 7.3 JIRA project key
        Developer    = Resolve-TicketDeveloper $(if ($fields) { $fields.assignee } else { $null })     # 7.1/7.2 attribution
        IsAiAssisted = $evidence.IsAssisted                                                            # R5 assisted boolean
        AiSource     = $evidence.Source                                                                # why: AIEvidenced | Label | None
        EpicName     = $epicName
        Phase        = Resolve-TicketPhase $epicName $Config.phaseKeywordMap                            # R6 phase from Epic
        PrRecords    = @()                                                                              # populated later for LOC (R10)
    }
}

# Exported: builds JQL from mutually exclusive time filters plus optional scope; command wires it in the fetch stage. (R8)
# Time window counts a ticket if it was resolved OR reached the UAT-passed status in the window; Epics are never counted.
function Build-JqlQuery {
    [CmdletBinding()]
    param(
        [string]$Month,                              # e.g. 2024-05 (single-month, R8.1)
        [datetime]$StartDate, [datetime]$EndDate,    # date-range (R8.2)
        [string]$Developer, [string]$Project, [switch]$AllDevelopers,
        [string]$UatPassedStatus                     # configured status name (e.g. "UAT Passed"); empty -> resolved-only
    )
    $hasMonth = -not [string]::IsNullOrWhiteSpace($Month)   # month filter requested?
    $hasRange = $StartDate -or $EndDate                     # any range endpoint requested?
    if ($hasMonth -and $hasRange) {                                                        # 8.3 mutual exclusivity
        New-KpiError "Only one time filter may be applied: use -Month OR -StartDate/-EndDate, not both."
    }

    # Builds the time window: resolved-in-window OR reached UAT-passed-in-window, grouped so later ANDs are safe.
    $timeClause = {
        param($s, $e)
        $sd = '{0:yyyy-MM-dd}' -f $s; $ed = '{0:yyyy-MM-dd}' -f $e
        $resolved = "resolved >= '$sd' AND resolved <= '$ed'"                               # 8.1/8.2 resolved in window
        if ([string]::IsNullOrWhiteSpace($UatPassedStatus)) { return "($resolved)" }        # resolved-only fallback
        # OR a ticket that transitioned to UAT-passed during the window (counts QA/UAT progress, not just done).
        $uat = "status CHANGED TO ""$UatPassedStatus"" DURING ('$sd','$ed')"
        return "(($resolved) OR ($uat))"
    }

    $clauses = @()
    if ($hasMonth) {                                                                       # 8.1 single month
        $start = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', $null)
        $end   = $start.AddMonths(1).AddDays(-1)                                           # last day of month
        $clauses += (& $timeClause $start $end)
    } elseif ($hasRange) {                                                                 # 8.2 date range
        $clauses += (& $timeClause $StartDate $EndDate)
    }

    $clauses += "issuetype != Epic"                                                        # Epic is the phase container, never a counted ticket

    if ($Developer -and -not $AllDevelopers) { $clauses += "assignee = '$Developer'" }     # 8.4 per-developer (8.6 omits when all)
    if ($Project)                            { $clauses += "project = '$Project'" }        # 8.5 per-project

    return ($clauses -join ' AND ')                                                        # 8.7 time + scope combine with AND
}

# Fetches all tickets for a JQL via the enhanced /rest/api/3/search/jql endpoint, normalizing each issue. (R3)
# Uses nextPageToken-based paging (the legacy startAt /rest/api/3/search was retired by Atlassian -> HTTP 410).
function Get-JiraIssues {
    [CmdletBinding()]
    param([object]$Env, [string]$Jql, [object]$Config)
    # Request only the fields normalization needs; include issuetype (Epic guard) and the AI field (R5 eval).
    $fields  = "summary,labels,assignee,project,parent,issuetype,$($Config.aiEvidencedFieldId)"
    $all     = @(); $pageToken = $null; $max = 100
    do {
        # 3.2 one page per call; token paging. Errors (3.4/3.5) flow through Invoke-JiraRequest.
        $query = @{ jql = $Jql; maxResults = $max; fields = $fields }
        if ($pageToken) { $query.nextPageToken = $pageToken }                               # continue from previous page
        $resp = Invoke-JiraRequest $Env '/rest/api/3/search/jql' $query
        foreach ($issue in @($resp.issues)) {
            # Defensive Epic skip (belt-and-suspenders with the JQL issuetype filter): Epics are phase containers, not tickets.
            if ($issue.fields -and $issue.fields.issuetype -and $issue.fields.issuetype.name -eq 'Epic') { continue }
            $all += (ConvertTo-KpiTicket $issue $Config)                                    # R5/R6/R7 normalization
        }
        $pageToken = $resp.nextPageToken                                                    # null/absent on the last page
    } while ($pageToken)                                                                    # 3.2 page until no token remains
    return $all
}
#endregion jira

#region github
# Private: single authenticated GitHub call (token auth); returns parsed body. (R10)
# Mirrors the JIRA client error handling; the token is only placed in the header, never logged.
function Invoke-GitHubRequest {
    [CmdletBinding()]
    param([object]$Config, [string]$Path, [string]$Method = 'GET')
    # Bearer token auth + GitHub media type; token value stays in the header and is never echoed (SECURITY).
    $headers = @{
        Authorization = "Bearer $($Config.github.token)"
        Accept        = 'application/vnd.github+json'
    }
    $uri = "$($Config.github.baseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"   # join base + path without double slash
    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method  # 10.2 secondary data access
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__                    # may be null on transport errors
        if ($status -in 401,403) {
            New-KpiError "GitHub authentication failed ($status) for $Path."  # auth failure identified, stop (no token in message)
        }
        New-KpiError "GitHub request failed ($status) for $Path. $($_.Exception.Message)"   # status code + request path
    }
}

# Private: linked PRs for a JIRA ticket from the development panel. (R10.1/R10.5)
function Get-IssueDevPrs {
    [CmdletBinding()]
    param([object]$Env, [string]$IssueId)
    # 10.1 / 10.5 primary link: read GitHub pull requests off the JIRA dev-status detail endpoint.
    $resp = Invoke-JiraRequest $Env '/rest/dev-status/latest/issue/detail' `
            @{ issueId = $IssueId; applicationType = 'GitHub'; dataType = 'pullrequest' }
    return $resp.detail.pullRequests
}

# Private: per-PR additions/deletions/changed-files + commit SHAs + target branch. (R10.2)
function Get-PrDetails {
    [CmdletBinding()]
    param([object]$Config, [string]$Owner, [string]$Repo, [int]$Number)
    $pr      = Invoke-GitHubRequest $Config "/repos/$Owner/$Repo/pulls/$Number"           # PR totals + base ref
    $commits = Invoke-GitHubRequest $Config "/repos/$Owner/$Repo/pulls/$Number/commits"   # per-commit SHAs
    return [pscustomobject]@{
        Additions    = $pr.additions                 # 10.2 LOC added
        Deletions    = $pr.deletions                 # 10.2 LOC removed
        ChangedFiles = $pr.changed_files             # 10.2 files touched
        TargetBranch = $pr.base.ref                  # base branch -> valid-branch filter (R10.4)
        Shas         = @($commits.sha)               # commit SHAs -> dedupe source (R10.3)
    }
}

# Private: fallback link of a PR when the JIRA key appears in its title or branch. (R10.6)
# Used only when Get-IssueDevPrs yields no dev-panel link; matching is case-insensitive.
function Find-PrByKey {
    [CmdletBinding()]
    param([string]$IssueKey, [object[]]$CandidatePrs)
    $needle = $IssueKey.ToLowerInvariant()                                    # 10.6 case-insensitive compare
    return @($CandidatePrs | Where-Object {
        $title  = [string]$_.title                                           # PR title candidate
        $branch = if ($_.head) { [string]$_.head.ref } else { [string]$_.branch }   # branch/head ref candidate
        ($title  -and $title.ToLowerInvariant().Contains($needle)) -or                # 10.6 key in title
        ($branch -and $branch.ToLowerInvariant().Contains($needle))                   # 10.6 key in branch name
    })
}

# Aggregates ticket LOC: valid-branch filter + PR-identity dedupe for LOC + commit SHA dedupe for commits. (R10.3/R10.4)
# LOC (additions/deletions/changed-files) is per-PR, so the SAME PR targeting two valid branches must be
# counted once -> dedupe PR records by identity before summing. Commits are deduped by SHA independently so
# UniqueCommits counts each distinct commit once even when it rides more than one PR/branch.
function Measure-TicketLoc {
    [CmdletBinding()]
    param([object[]]$PrRecords, [string[]]$ValidTargetBranches)

    $valid = @($PrRecords | Where-Object { $_.TargetBranch -in $ValidTargetBranches })   # 10.4 keep only valid target branches

    $seenPrs   = [System.Collections.Generic.HashSet[string]]::new()   # PR identities already summed for LOC
    $seenShas  = [System.Collections.Generic.HashSet[string]]::new()   # 10.3 distinct commit SHAs
    $add = 0; $del = 0; $chg = 0
    foreach ($pr in $valid) {
        # PR identity key: prefer an explicit number/id; else fall back to a stable composite so missing-id PRs still dedupe.
        $prKey = if ($null -ne $pr.Number) { "num:$($pr.Number)" }
                 elseif ($null -ne $pr.Id)  { "id:$($pr.Id)" }
                 else { "fp:$($pr.TargetBranch)|$($pr.Additions)|$($pr.Deletions)|$($pr.ChangedFiles)|$(@($pr.Shas) -join ',')" }
        if ($seenPrs.Add($prKey)) {                                    # first time this PR identity is seen -> count its LOC once
            $add += [int]$pr.Additions                                 # 10.3 avoid double-counting same PR on two branches
            $del += [int]$pr.Deletions
            $chg += [int]$pr.ChangedFiles
        }
        foreach ($sha in @($pr.Shas)) {
            if ($sha) { [void]$seenShas.Add([string]$sha) }            # 10.3 each distinct SHA counted once
        }
    }
    return [pscustomobject]@{ Additions = $add; Deletions = $del; ChangedFiles = $chg; UniqueCommits = $seenShas.Count }
}
#endregion github

#region aggregation
# Overall + per-phase + per-developer ACR; zero-division safe, result bounded 0-100. (R9)
function Measure-Acr {
    [CmdletBinding()]
    param([object[]]$Tickets)
    # Inner stat over any ticket set: assisted/total counts + rounded rate, zero-division safe.
    $acr = {
        param($set)
        $total    = @($set).Count                                 # 9.5 total ticket count
        $assisted = @($set | Where-Object IsAiAssisted).Count     # 9.5 AI-assisted count
        $rate     = if ($total -eq 0) { 0 } else { [math]::Round(($assisted / $total) * 100, 2) }   # 9.1 formula / 9.6/9.7 zero-safe
        [pscustomobject]@{ Assisted = $assisted; NotAssisted = ($total - $assisted); Total = $total; Acr = $rate }
    }
    [pscustomobject]@{
        Overall      = & $acr $Tickets                                                                                    # 9.2 overall rate
        PerPhase     = $Tickets | Group-Object Phase     | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Stat = (& $acr $_.Group) } }   # 9.3 per-phase
        PerDeveloper = $Tickets | Group-Object Developer | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Stat = (& $acr $_.Group) } }   # 9.4 per-developer
    }
}
#endregion aggregation

#region output
# Renders the console table and writes the CSV with breakdowns + filter metadata. (R11)
function Export-AcrReport {
    [CmdletBinding()]
    param([object]$Result, [object]$FilterMeta, [string]$OutputPath)

    # Console (11.1): overall line + per-phase (11.3) + per-developer (11.4) tables.
    Write-Host "ACR Overall: $($Result.Overall.Acr)% ($($Result.Overall.Assisted)/$($Result.Overall.Total))"
    $Result.PerPhase     | Format-Table Key, @{n='ACR%';e={$_.Stat.Acr}}, @{n='Assisted';e={$_.Stat.Assisted}}, @{n='NotAssisted';e={$_.Stat.NotAssisted}}, @{n='Total';e={$_.Stat.Total}}   # 11.3 per-phase
    $Result.PerDeveloper | Format-Table Key, @{n='ACR%';e={$_.Stat.Acr}}, @{n='Assisted';e={$_.Stat.Assisted}}, @{n='NotAssisted';e={$_.Stat.NotAssisted}}, @{n='Total';e={$_.Stat.Total}}   # 11.4 per-developer

    # CSV rows: Scope column distinguishes Meta/Overall/Phase/Developer; filter metadata prepended (11.5).
    $rows = @()
    $rows += [pscustomobject]@{ Scope='Meta:Environment'; Name=$FilterMeta.Environment; Acr=''; Assisted=''; NotAssisted=''; Total='' }   # 11.5 environment
    $rows += [pscustomobject]@{ Scope='Meta:TimeFilter';  Name=$FilterMeta.TimeFilter;  Acr=''; Assisted=''; NotAssisted=''; Total='' }   # 11.5 time filter
    $rows += [pscustomobject]@{ Scope='Meta:ScopeFilter'; Name=$FilterMeta.ScopeFilter; Acr=''; Assisted=''; NotAssisted=''; Total='' }   # 11.5 scope filter
    $rows += [pscustomobject]@{ Scope='Overall'; Name='*'; Acr=$Result.Overall.Acr; Assisted=$Result.Overall.Assisted; NotAssisted=$Result.Overall.NotAssisted; Total=$Result.Overall.Total }   # 11.2 overall
    foreach ($p in $Result.PerPhase)     { $rows += [pscustomobject]@{ Scope='Phase';     Name=$p.Key; Acr=$p.Stat.Acr; Assisted=$p.Stat.Assisted; NotAssisted=$p.Stat.NotAssisted; Total=$p.Stat.Total } }   # 11.3 per-phase row
    foreach ($d in $Result.PerDeveloper) { $rows += [pscustomobject]@{ Scope='Developer'; Name=$d.Key; Acr=$d.Stat.Acr; Assisted=$d.Stat.Assisted; NotAssisted=$d.Stat.NotAssisted; Total=$d.Stat.Total } }   # 11.4 per-developer row

    # 11.6 wrap the write so a failed path surfaces a terminating error naming the path.
    try { $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 }
    catch { New-KpiError "Failed to write CSV to path: $OutputPath. $($_.Exception.Message)" }
}
#endregion output

#region mapping
# Loads or initializes the user-mapping.json identity store; missing file -> empty array. (R12)
function Import-UserMapping {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }                    # missing file -> initialize empty, never errors
    $data = Get-Content $Path -Raw | ConvertFrom-Json             # load the array of person records
    return @($data)                                               # coerce to array (single record / null safe)
}

# Appends a person record (github/jira/aws), throwing on identity conflict. (R12.1/R12.2/R12.4)
function Add-UserMapping {
    [CmdletBinding()]
    param([object[]]$Store, [string]$Person, [string]$GitHub, [string]$Jira, [string]$Aws)
    foreach ($e in $Store) {                                                           # scan existing links for conflicts
        foreach ($id in @(@{f='github';v=$GitHub}, @{f='jira';v=$Jira}, @{f='aws';v=$Aws})) {
            if ($e.($id.f) -eq $id.v -and $e.person -ne $Person) {                     # 12.4 identity owned by another person
                New-KpiError "Mapping conflict: $($id.f) '$($id.v)' is already linked to '$($e.person)', cannot link to '$Person'."
            }
        }
    }
    return @($Store + [pscustomobject]@{ person=$Person; github=$GitHub; jira=$Jira; aws=$Aws })   # 12.1/12.2 link three identities
}

# Resolves a source identity (github|jira|aws) to a canonical person. (R12.3)
function Resolve-UserMapping {
    [CmdletBinding()]
    param([object[]]$Store, [string]$Source, [string]$Value)
    ($Store | Where-Object { $_.$Source -eq $Value } | Select-Object -First 1).person   # 12.3 first match -> single person
}
#endregion mapping

#region error
# Private: throws a single structured terminating error used by all library functions.
function New-KpiError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $record = [System.Management.Automation.ErrorRecord]::new(
        [System.Exception]::new($Message),   # carries the supplied message
        'KpiError',                           # stable error id for callers
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null)
    throw $record                             # terminating -> command try/catch exits non-zero
}
#endregion error

# Public API only; every private helper above stays unexported.
Export-ModuleMember -Function @(
    'Import-KpiConfig',
    'Resolve-KpiEnvironment',
    'Get-JiraFields',
    'Build-JqlQuery',
    'Get-JiraIssues',
    'Measure-TicketLoc',
    'Measure-Acr',
    'Export-AcrReport',
    'Import-UserMapping',
    'Add-UserMapping',
    'Resolve-UserMapping'
)
