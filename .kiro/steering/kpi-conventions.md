---
inclusion: always
---

# KPI Toolkit Conventions

These conventions govern every KPI command and the shared library in this toolkit.
They are mandatory: new KPIs (RR, MLT) and any change to an existing KPI must follow
all three sections below.

## 1. The Single KPI Command Pattern

Every KPI or mapping command (`Get-ACR.ps1`, `Get-RR.ps1`, `Get-MLT.ps1`,
`Get-UserMapping.ps1`) is a **thin** script. It contains no shared logic of its own.
All reusable behavior lives in `KPI.Common.psm1`; command files only wire parameters
to library calls and catch terminating errors.

Each command follows this fixed sequence, in order:

```
param block -> import config -> resolve environment -> fetch -> transform -> aggregate -> output
```

- **param block** — typed parameters with `[CmdletBinding()]`; filters are parameters,
  never separate commands.
- **import config** — `Import-KpiConfig` loads and validates `global-config.json`.
- **resolve environment** — `Resolve-KpiEnvironment` selects `test` (default) or `live`.
- **fetch** — `Build-JqlQuery` composes the query (filters are parameters) and `Get-JiraIssues` /
  GitHub helpers retrieve raw source data. Any helper a command wires directly (including
  `Build-JqlQuery`) must be exported from `KPI.Common.psm1`; PowerShell makes only exported
  functions callable from a command script.
- **transform** — normalization (AI-assisted, phase, developer, project) applied to each item.
- **aggregate** — a `Measure-*` function computes the KPI (overall + breakdowns).
- **output** — an `Export-*Report` function renders the console table and writes CSV; a
  console-only switch (e.g. `-ConsoleOnly`) may skip the CSV and print tables only.

The command wraps the sequence in a `try/catch`; any library error is a terminating
error that the command writes and exits non-zero on. No KPI script may inline shared
logic, add a second command for a filter, or introduce its own data-access code.

## 2. Commenting Standard (Concise, Token-Conserving, Requirement-Annotated)

Comments must be **detailed but concise** and conserve tokens:

- One short line stating intent above each function.
- One short line above each non-obvious block.
- Where a block implements a specific acceptance criterion, annotate it with the
  requirement id inline, e.g. `# 5.1 override wins` or `# 10.3 dedupe by SHA`.
- Do **not** restate what the code plainly says, and do **not** use banner or decorative
  comment blocks.

Example:

```powershell
# Resolve an Epic name to exactly one of five phases; unmapped -> Unassigned.
function Resolve-TicketPhase {
    param([string]$EpicName, [object]$PhaseKeywordMap)
    foreach ($phase in $PhaseKeywordMap.PSObject.Properties) {   # 6.1 iterate configured phases
        foreach ($kw in $phase.Value) {
            if ($EpicName -like "*$kw*") { return $phase.Name }   # 6.2 first hit wins -> single phase
        }
    }
    return 'Unassigned'                                           # 6.3 no keyword matched
}
```

## 3. Living-Documentation Rule

Documentation must never drift from behavior. When a KPI's behavior changes, the author
updates the design document (`design.md`) **and** this steering file
(`.kiro/steering/kpi-conventions.md`) in the **same change** as the code. A behavior
change is not complete until the design doc and these conventions reflect it.
