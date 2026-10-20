# Get-MLT.ps1 — thin stub command for the Mean Lead Time (MLT) KPI. (R13.3/R13.6)
# Follows the fixed KPI command pattern: param block -> import config -> resolve environment -> fetch -> transform -> aggregate -> output.
# Not yet implemented: this phase only establishes the one-command interface. When built it reuses KPI.Common.psm1 with no new data layer (R13.6).
[CmdletBinding(DefaultParameterSetName='Month')]
param(
    [ValidateSet('test','live')][string]$Environment = 'test',          # R2.1 default 'test'
    [Parameter(ParameterSetName='Month')][string]$Month,                # R8.1 single-month (mutually exclusive set)
    [Parameter(ParameterSetName='Range')][datetime]$StartDate,          # R8.2 date-range start
    [Parameter(ParameterSetName='Range')][datetime]$EndDate,            # R8.2 date-range end
    [string]$Developer,                                                 # R8.1 per-developer scope
    [string]$Project,                                                   # R8.1 per-project scope
    [switch]$AllDevelopers,                                             # R8.1 all-developers scope
    [string]$OutputPath = './mlt-report.csv'                            # R11 CSV destination
)

# import module stage binds to the shared library so the future implementation adds only aggregation/output, no data access (R13.6).
Import-Module "$PSScriptRoot/KPI.Common.psm1" -Force

# stub body: announce not-implemented and exit 0. Future sequence mirrors Get-ACR: import config -> resolve environment ->
# Build-JqlQuery + Get-JiraIssues -> transform -> aggregate (over ticket transition timestamps) -> output.
Write-Host 'Get-MLT (Mean Lead Time) is not yet implemented. It will reuse KPI.Common.psm1 (config, environment, Get-JiraIssues, user mapping) and add a Measure-Mlt + Export-MltReport pair, using ticket transition timestamps.'
exit 0
