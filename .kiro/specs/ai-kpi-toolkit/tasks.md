# Implementation Plan: AI KPI Toolkit (ACR)

## Overview

Build the toolkit bottom-up in Windows PowerShell: scaffold the fixed file layout and steering conventions, grow `KPI.Common.psm1` one shared function at a time (each with Pester tests close to the implementation), then wire everything into `Get-ACR.ps1` end-to-end and add the `Get-UserMapping.ps1`, `Get-RR.ps1` (stub), and `Get-MLT.ps1` (stub) command files. Pure library functions are covered by property tests (Properties 1-14, 100+ iterations); HTTP boundaries are covered by mocked integration tests. Only the four command files + one shared module + config/mapping data files + the steering file are created, per R13.

Pester note: run tests non-interactively with `Invoke-Pester -CI` (single execution); never use watch mode.

## Tasks

- [x] 1. Scaffold repo layout, steering file, config template, and gitignore
  - Create `.kiro/steering/kpi-conventions.md` with the three required sections: the single command pattern (param block -> import config -> resolve environment -> fetch -> transform -> aggregate -> output), the concise/token-conserving commenting standard with requirement-id annotations, and the living-documentation rule
  - Create `global-config.sample.json` as the committed template matching the design config schema (two environments `test`/`live`, github block, phaseKeywordMap with five phases, validTargetBranches, aiEvidencedFieldId) using placeholder values and no real secrets
  - Create `.gitignore` that excludes the real `global-config.json` and `user-mapping.json` while keeping `global-config.sample.json`
  - Create empty placeholder `user-mapping.json` as a JSON array (`[]`) for local use (git-ignored)
  - _Requirements: 13.1, 13.2, 13.3, 13.4, 14.1, 14.2, 14.3, 14.4_
  - [ ]* 1.1 Write smoke tests for scaffold
    - Assert `.kiro/steering/kpi-conventions.md` exists and contains the three required section headings
    - Assert `global-config.sample.json` exists, parses as JSON, and has the required top-level keys
    - Assert no more than the four permitted command files will exist and `.gitignore` excludes the real config/mapping files
    - _Requirements: 13.3, 13.4, 14.1_

- [x] 2. Create KPI.Common.psm1 skeleton with error helper and exports
  - Create `KPI.Common.psm1` with `[CmdletBinding()]` scaffolding and the fixed set of regions for config/env/jira/github/aggregation/output/mapping
  - Implement private `New-KpiError` that throws a single structured terminating error used by all later functions
  - Declare the `Export-ModuleMember` list for the exported public API (`Import-KpiConfig`, `Resolve-KpiEnvironment`, `Get-JiraFields`, `Get-JiraIssues`, `Measure-TicketLoc`, `Measure-Acr`, `Export-AcrReport`, `Import-UserMapping`, `Add-UserMapping`, `Resolve-UserMapping`) keeping private helpers unexported
  - Add a Pester test harness that imports the module with `-Force`
  - _Requirements: 13.4, 13.5_
  - [ ]* 2.1 Write unit test for New-KpiError and module load
    - Assert the module imports and only the intended public functions are exported
    - Assert `New-KpiError` throws a terminating error carrying the supplied message
    - _Requirements: 13.4, 13.5_

- [x] 3. Implement Import-KpiConfig with two-environment validation
  - Implement `Import-KpiConfig` and the private `Get-ConfigValue` dotted-path resolver in `KPI.Common.psm1`
  - Read + `ConvertFrom-Json` the config; on missing file or JSON parse failure throw via `New-KpiError` naming the file path
  - Validate every required key (both `test` and `live` baseUrl/email/apiToken, github baseUrl/token, phaseKeywordMap, validTargetBranches, aiEvidencedFieldId); treat collections as non-empty checks; throw naming the exact missing key
  - Default-environment semantics (`test`) documented for downstream resolver
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10_
  - [ ]* 3.1 Write property test for config validation
    - **Feature: ai-kpi-toolkit, Property 1: Config validation names the missing key**
    - **Validates: Requirements 1.8, 1.9**
  - [ ]* 3.2 Write unit test for JSON parse failure
    - Assert malformed JSON throws an error identifying the config file path
    - _Requirements: 1.10_

- [x] 4. Implement Resolve-KpiEnvironment
  - Implement `Resolve-KpiEnvironment` returning the matching environment block, defaulting to `test`
  - Re-validate the environment value against `test`/`live` and throw via `New-KpiError` listing accepted values on mismatch (library-level safety for RR/MLT reuse)
  - _Requirements: 2.1, 2.2, 2.3, 2.4_
  - [ ]* 4.1 Write property test for invalid environment rejection
    - **Feature: ai-kpi-toolkit, Property 2: Invalid environment is rejected with accepted values**
    - **Validates: Requirements 2.3**
  - [ ]* 4.2 Write unit test for default environment
    - Assert omitting the environment resolves to the `test` block
    - _Requirements: 2.2_

- [x] 5. Implement JIRA request client with auth and error handling
  - Implement private `Invoke-JiraRequest` using basic auth (base64 `email:apiToken`) and `Invoke-RestMethod`, with a `Join-JiraUri` helper for base URL + path + query
  - Map 401/403 responses to an authentication-failure terminating error; map other non-success statuses to an error including the HTTP status code and request path/context
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_
  - [ ]* 5.1 Write integration tests for JIRA client (mocked HTTP)
    - Mock `Invoke-RestMethod`; assert the Authorization header is basic auth from the selected environment
    - Assert a 401/403 raises the auth-failure error and a 500 raises an error carrying status code + request context
    - _Requirements: 3.1, 3.4, 3.5_

- [x] 6. Implement Get-JiraFields field discovery
  - Implement `Get-JiraFields` querying `/rest/api/3/field` via `Invoke-JiraRequest`, matching the field named `AI Evidenced`, returning its id, and returning a not-found message when absent
  - _Requirements: 4.1, 4.2, 4.3, 4.4_
  - [ ]* 6.1 Write property test for field discovery semantics
    - **Feature: ai-kpi-toolkit, Property 12: Field discovery find semantics**
    - **Validates: Requirements 4.2, 4.4**

- [x] 7. Implement Test-TicketAiAssisted evaluator
  - Implement private `Test-TicketAiAssisted`: the AI Evidenced field value `AI Assisted` overrides; when field is empty or absent, fall back to a trimmed case-insensitive exact label match on `AI Assisted`; absent field raises no error; otherwise false
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_
  - [ ]* 7.1 Write property test for AI assistance precedence
    - **Feature: ai-kpi-toolkit, Property 3: AI assistance precedence**
    - **Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5**

- [x] 8. Implement Resolve-TicketPhase
  - Implement private `Resolve-TicketPhase` mapping an Epic name to exactly one of the five configured phases via first-keyword-hit over the phaseKeywordMap; return `Unassigned` when no keyword matches or Epic name is empty
  - _Requirements: 6.1, 6.2, 6.3_
  - [ ]* 8.1 Write property test for phase resolution
    - **Feature: ai-kpi-toolkit, Property 4: Phase resolution yields one of five phases or Unassigned**
    - **Validates: Requirements 6.1, 6.2, 6.3**

- [x] 9. Implement attribution and ticket normalization
  - Implement private `Resolve-TicketDeveloper` returning the assignee display name or `Unknown` when no assignee
  - Implement private `ConvertTo-KpiTicket` that builds the normalized ticket (`Key`, `Project` from JIRA project key, `Developer`, `IsAiAssisted`, `Phase` from the parent/Epic, `EpicName`, empty `PrRecords`) wiring in `Test-TicketAiAssisted`, `Resolve-TicketPhase`, and `Resolve-TicketDeveloper`
  - _Requirements: 7.1, 7.2, 7.3_
  - [ ]* 9.1 Write property test for developer and project attribution
    - **Feature: ai-kpi-toolkit, Property 5: Developer and project attribution**
    - **Validates: Requirements 7.1, 7.2, 7.3**

- [x] 10. Implement Build-JqlQuery filter engine
  - Implement private `Build-JqlQuery` supporting single-month and date-range time filters, per-developer/per-project scope, and all-developers scope; combine time + scope clauses
  - Throw via `New-KpiError` when both a month and a date-range are supplied (mutual exclusivity)
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_
  - [ ]* 10.1 Write property test for mutually exclusive time filters
    - **Feature: ai-kpi-toolkit, Property 6: Time filters are mutually exclusive**
    - **Validates: Requirements 8.3**
  - [ ]* 10.2 Write property test for filtered survivors satisfy predicates
    - **Feature: ai-kpi-toolkit, Property 7: Filtered survivors satisfy all applied predicates**
    - **Validates: Requirements 8.1, 8.2, 8.4, 8.5, 8.6, 8.7**

- [x] 11. Implement Get-JiraIssues paged fetch with normalization
  - Implement exported `Get-JiraIssues` calling `/rest/api/3/search` with the required field list (including the configured AI field id), following `startAt`/`maxResults` pagination until `total` is reached, and normalizing each issue through `ConvertTo-KpiTicket`
  - _Requirements: 3.2, 3.5, 5.1, 6.1, 7.1, 7.3_
  - [ ]* 11.1 Write integration test for paging + normalization (mocked HTTP)
    - Mock paged `/rest/api/3/search` responses; assert all pages are fetched and each returned ticket is normalized (IsAiAssisted/Phase/Developer/Project set)
    - _Requirements: 3.2_

- [x] 12. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 13. Implement GitHub client and PR linking
  - Implement private `Invoke-GitHubRequest` (token auth against the configured GitHub base URL) with error handling consistent with the JIRA client
  - Implement private `Get-IssueDevPrs` reading linked PRs from `/rest/dev-status/latest/issue/detail` as the primary link source
  - Implement private `Get-PrDetails` returning additions/deletions/changed-files, target branch, and commit SHAs for a PR
  - Implement private `Find-PrByKey` fallback that links a PR when the JIRA key appears in the PR title or branch name
  - _Requirements: 10.1, 10.2, 10.5, 10.6_
  - [ ]* 13.1 Write integration test for GitHub PR detail parsing (mocked HTTP)
    - Mock PR + commits responses; assert additions/deletions/changed-files, target branch, and SHAs are parsed; assert dev-panel retrieval shape
    - _Requirements: 10.1, 10.2, 10.5_
  - [ ]* 13.2 Write property test for fallback PR linking
    - **Feature: ai-kpi-toolkit, Property 11: Fallback PR linking by JIRA key**
    - **Validates: Requirements 10.6**

- [x] 14. Implement Measure-TicketLoc with SHA dedupe and branch filter
  - Implement exported `Measure-TicketLoc` filtering PR records to valid target branches, deduplicating commits by SHA via a HashSet, and aggregating additions/deletions/changed-files + unique commit count
  - _Requirements: 10.3, 10.4_
  - [ ]* 14.1 Write property test for commit SHA deduplication/idempotence
    - **Feature: ai-kpi-toolkit, Property 9: Commit SHA deduplication and idempotence**
    - **Validates: Requirements 10.3**
  - [ ]* 14.2 Write property test for valid target branch filtering
    - **Feature: ai-kpi-toolkit, Property 10: Only valid target branches are counted**
    - **Validates: Requirements 10.4**

- [x] 15. Implement Measure-Acr aggregation
  - Implement exported `Measure-Acr` computing overall ACR plus per-phase and per-developer breakdowns, each reporting assisted/total counts; ACR = assisted/total*100 rounded, with zero-division-safe `0` for empty sets/groups and results bounded 0-100
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7_
  - [ ]* 15.1 Write property test for ACR formula and zero-division safety
    - **Feature: ai-kpi-toolkit, Property 8: ACR formula with zero-division safety**
    - **Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7**

- [x] 16. Implement Export-AcrReport output writer
  - Implement exported `Export-AcrReport` rendering the console table (overall + per-phase + per-developer) and writing the CSV with a `Scope` column distinguishing Overall/Phase/Developer plus prepended filter-metadata rows (environment, time filter, scope filter)
  - Throw via `New-KpiError` naming the target path when the CSV cannot be written
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_
  - [ ]* 16.1 Write property test for CSV breakdowns and metadata
    - **Feature: ai-kpi-toolkit, Property 13: CSV report contains all breakdowns and filter metadata**
    - **Validates: Requirements 11.2, 11.3, 11.4, 11.5**
  - [ ]* 16.2 Write unit test for CSV write failure
    - Assert writing to an invalid path raises an error identifying the target path
    - _Requirements: 11.6_

- [x] 17. Implement user mapping functions and Get-UserMapping.ps1 command
  - Implement exported `Import-UserMapping` (load/initialize the `user-mapping.json` array), `Add-UserMapping` (append a person record with github/jira/aws, throwing on conflict when any identity is already linked to a different person), and `Resolve-UserMapping` (return the single person for a given source identity)
  - Create thin `Get-UserMapping.ps1` command following the fixed pattern: param block -> import module -> import mapping -> add/resolve -> persist/output, catching terminating errors
  - _Requirements: 12.1, 12.2, 12.3, 12.4, 13.1, 13.3, 13.5_
  - [ ]* 17.1 Write property test for user mapping conflict detection and linkage
    - **Feature: ai-kpi-toolkit, Property 14: User mapping conflict detection and linkage**
    - **Validates: Requirements 12.1, 12.2, 12.3, 12.4**

- [x] 18. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 19. Wire Get-ACR.ps1 end-to-end
  - Create `Get-ACR.ps1` with the full param block (`-Environment` ValidateSet test/live, mutually exclusive `-Month` vs `-StartDate`/`-EndDate` parameter sets, `-Developer`, `-Project`, `-AllDevelopers`, `-OutputPath`)
  - Import `KPI.Common.psm1` and execute the fixed sequence: import config -> resolve environment -> build JQL -> fetch + normalize issues -> aggregate ACR -> build filter metadata -> export report; catch terminating errors, write the message, and exit non-zero
  - _Requirements: 2.1, 8.1, 8.2, 8.3, 9.1, 11.5, 13.1, 13.2, 13.5_
  - [ ]* 19.1 Write integration test for ACR end-to-end (mocked HTTP)
    - Mock JIRA search + dev-status + GitHub; run `Get-ACR` with a month filter and assert a console table renders and the CSV contains overall/phase/developer rows + filter metadata
    - _Requirements: 9.2, 9.3, 9.4, 11.2, 11.5_

- [x] 20. Create Get-RR.ps1 and Get-MLT.ps1 stub commands
  - Create `Get-RR.ps1` and `Get-MLT.ps1` as thin stub command files that print a "not yet implemented" notice while following the shared command pattern and documenting their future reuse of `KPI.Common.psm1`
  - _Requirements: 13.3, 13.6_
  - [ ]* 20.1 Write smoke test for the four-command invariant
    - Assert exactly `Get-ACR.ps1`, `Get-RR.ps1`, `Get-MLT.ps1`, `Get-UserMapping.ps1` plus one `KPI.Common.psm1` exist and the stubs emit the not-implemented notice
    - _Requirements: 13.1, 13.3, 13.4_

- [x] 21. Final checkpoint - Full suite and documentation
  - Run the full Pester suite with `Invoke-Pester -CI` and ensure all tests pass
  - Confirm all 14 Correctness Properties have a corresponding property test and every requirement is referenced by a task
  - Apply the living-documentation rule: if behavior drifted from the spec during implementation, update `design.md` and `.kiro/steering/kpi-conventions.md` in the same change
  - Ensure all tests pass, ask the user if questions arise.
  - _Requirements: 14.4_

## Notes

- Tasks marked with `*` are optional test sub-tasks and can be skipped for a faster MVP; core implementation tasks are never optional.
- Each task references specific requirement sub-clauses for traceability, and property tasks reference the exact design property number.
- Only the four permitted command files + `KPI.Common.psm1` + config/mapping data files + the steering file are created; no additional commands or data layers (R13).
- Property tests run 100+ iterations against pure library functions; HTTP boundaries use mocked integration tests. Run Pester non-interactively (`Invoke-Pester -CI`), never in watch mode.
- Checkpoints (tasks 12, 18, 21) provide incremental validation points.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1", "2"] },
    { "id": 1, "tasks": ["1.1", "2.1", "3", "4", "5"] },
    { "id": 2, "tasks": ["3.1", "3.2", "4.1", "4.2", "5.1", "6", "7", "8", "9", "10", "13"] },
    { "id": 3, "tasks": ["6.1", "7.1", "8.1", "9.1", "10.1", "10.2", "13.1", "13.2", "11", "14"] },
    { "id": 4, "tasks": ["11.1", "14.1", "14.2", "15", "16", "17"] },
    { "id": 5, "tasks": ["15.1", "16.1", "16.2", "17.1", "19", "20"] },
    { "id": 6, "tasks": ["19.1", "20.1"] }
  ]
}
```
