# Get-ACR.ps1 - thin command computing the AI Contribution Rate from JIRA. (R9/R13)
# Fixed KPI command pattern: param block -> import config -> resolve environment -> fetch -> transform -> aggregate -> output.
# All shared logic lives in KPI.Common.psm1; this file only wires parameters to library calls (R13.1/R13.2/R13.5).
[CmdletBinding(DefaultParameterSetName='Month')]
param(
    [ValidateSet('test','live')][string]$Environment = 'test',          # R2.1 default 'test'
    [Parameter(ParameterSetName='Month')][string]$Month,                # R8.1 single-month (mutually exclusive set)
    [Parameter(ParameterSetName='Range')][datetime]$StartDate,          # R8.2 date-range start
    [Parameter(ParameterSetName='Range')][datetime]$EndDate,            # R8.2 date-range end
    [string]$Developer,                                                 # R8.1 per-developer scope
    [string]$Project,                                                   # R8.1 per-project scope
    [switch]$AllDevelopers,                                             # R8.1 all-developers scope
    [switch]$ConsoleOnly,                                               # test mode: print per-phase counts only, no CSV
    [string]$OutputPath = './acr-report.csv'                            # R11 CSV destination (ignored when -ConsoleOnly)
)

# import config stage uses the shared library - no data access or shared logic inlined here (R13.5).
Import-Module "$PSScriptRoot/KPI.Common.psm1" -Force

try {
    $config  = Import-KpiConfig "$PSScriptRoot/global-config.json"       # import config (R1)
    $envBlk  = Resolve-KpiEnvironment $config $Environment               # resolve environment (R2.1)
    # pass only the active parameter set's time args - unset [datetime] params must not be splatted as $null (R8.1/R8.2/R8.3).
    $jqlArgs = @{ Developer = $Developer; Project = $Project; AllDevelopers = $AllDevelopers; UatPassedStatus = $config.uatPassedStatus }
    if ($PSCmdlet.ParameterSetName -eq 'Range') { $jqlArgs.StartDate = $StartDate; $jqlArgs.EndDate = $EndDate }
    else                                        { $jqlArgs.Month     = $Month }
    $jql     = Build-JqlQuery @jqlArgs                                   # fetch stage: compose JQL (resolved-or-UATpassed, Epics excluded)
    Write-Host "JQL: $jql" -ForegroundColor DarkGray                     # surface the query so it can be reviewed/debugged
    $tickets = Get-JiraIssues -Env $envBlk -Jql $jql -Config $config     # fetch + transform (normalization applied in-library, R5/R6/R7)
    $result  = Measure-Acr -Tickets $tickets                             # aggregate overall + per-phase + per-developer (R9.1)

    if ($ConsoleOnly) {
        # Test output: the fetched tickets, then per-phase counts, then an overall line. No CSV written.
        Write-Host ""
        Write-Host "Fetched $(@($tickets).Count) ticket(s):" -ForegroundColor Cyan
        @($tickets) |
            Sort-Object Phase, Key |
            ForEach-Object { [pscustomobject]@{ Key=$_.Key; Phase=$_.Phase; Type=$_.IssueType; Developer=$_.Developer; AI=$(if($_.IsAiAssisted){'Yes'}else{'No'}); Source=$_.AiSource; Summary=$_.Summary } } |
            Format-Table -AutoSize -Wrap
        Write-Host "Per phase:" -ForegroundColor Cyan
        $result.PerPhase |
            ForEach-Object { [pscustomobject]@{ Phase=$_.Key; Total=$_.Stat.Total; Assisted=$_.Stat.Assisted; NotAssisted=$_.Stat.NotAssisted; 'ACR%'=$_.Stat.Acr } } |
            Format-Table -AutoSize
        Write-Host "ACR Overall: $($result.Overall.Acr)%  Total=$($result.Overall.Total)  Assisted=$($result.Overall.Assisted)  NotAssisted=$($result.Overall.NotAssisted)" -ForegroundColor Green
    }
    else {
        # build filter metadata - compute scope/project parts first to avoid the string + if-expression precedence pitfall (R11.5).
        $timeFilter = if ($Month)     { "Month=$Month" }
                      elseif ($StartDate) { "Range=$StartDate..$EndDate" }
                      else { 'None' }
        $scopePart  = if ($AllDevelopers) { 'AllDevelopers' }
                      elseif ($Developer)  { "Developer=$Developer" }
                      else { 'All' }
        $projectPart = if ($Project) { " Project=$Project" } else { '' }
        $meta = [pscustomobject]@{
            Environment = $Environment
            TimeFilter  = $timeFilter
            ScopeFilter = $scopePart + $projectPart
        }
        Export-AcrReport -Result $result -FilterMeta $meta -OutputPath $OutputPath   # output console table + CSV (R11)
    }
}
catch { Write-Error $_.Exception.Message; exit 1 }   # 13.5 library terminating errors stop the command non-zero
