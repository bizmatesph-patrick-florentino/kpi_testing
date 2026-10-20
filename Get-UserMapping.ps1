# Get-UserMapping.ps1 — thin command linking one person's GitHub/JIRA/AWS identities. (R12/R13)
# Follows the fixed KPI command pattern: param block -> import module -> import mapping -> add/resolve -> persist/output.
# One command, three parameter sets (Add / Resolve / List) — filters are parameters, never extra commands (R13.1/R13.2).
[CmdletBinding(DefaultParameterSetName='List')]
param(
    [string]$MappingPath = "$PSScriptRoot/user-mapping.json",                # identity store location (git-ignored)

    [Parameter(ParameterSetName='Add', Mandatory)][string]$Person,          # Add mode: person + their identities (R12.1)
    [Parameter(ParameterSetName='Add')][string]$GitHub,
    [Parameter(ParameterSetName='Add')][string]$Jira,
    [Parameter(ParameterSetName='Add')][string]$Aws,

    [Parameter(ParameterSetName='Resolve', Mandatory)]
    [ValidateSet('github','jira','aws')][string]$Source,                    # Resolve mode: which identity to look up (R12.3)
    [Parameter(ParameterSetName='Resolve', Mandatory)][string]$Value
)

# import module — all reusable behavior lives in the shared library (R13.5).
Import-Module "$PSScriptRoot/KPI.Common.psm1" -Force

try {
    $store = Import-UserMapping $MappingPath                                 # import mapping (load/initialize store)

    switch ($PSCmdlet.ParameterSetName) {
        'Add' {
            $store = Add-UserMapping -Store $store -Person $Person -GitHub $GitHub -Jira $Jira -Aws $Aws   # add (R12.1/R12.2/R12.4)
            $store | ConvertTo-Json -Depth 5 | Set-Content -Path $MappingPath -Encoding UTF8               # persist updated store
            Write-Host "Linked '$Person' (github=$GitHub, jira=$Jira, aws=$Aws)."
        }
        'Resolve' {
            Resolve-UserMapping -Store $store -Source $Source -Value $Value   # resolve + output the person (R12.3)
        }
        default {
            $store | Format-Table person, github, jira, aws                   # List: show current mappings
        }
    }
}
catch { Write-Error $_.Exception.Message; exit 1 }   # library terminating errors stop the command non-zero (R13.5)
