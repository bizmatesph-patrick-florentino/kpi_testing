# Requirements Document

## Introduction

The AI KPI Toolkit is a Windows PowerShell command-line solution that measures engineering KPIs from JIRA Cloud (primary data source) and GitHub (secondary data source). The flagship KPI delivered end-to-end in this scope is the AI Contribution Rate (ACR): the percentage of tickets that were AI-assisted. The toolkit is a greenfield workspace and establishes the shared data layer, two-environment configuration, field discovery helper, user mapping command, and steering conventions that the future Review Rate (RR) and Mean Lead Time (MLT) KPIs will reuse.

The toolkit uses the JIRA Cloud REST API v3 with email plus API token authentication. It supports two configurable JIRA environments (a default test environment and a live environment), a global JSON configuration file, and a consistent one-command-per-KPI design. ACR is reported overall, per phase, per developer, and as assisted-versus-total counts, with results emitted to both a console table and a CSV file including the applied filter metadata.

RR and MLT are out of scope for implementation in this phase but the architecture and requirements note that both KPIs will reuse the shared data layer, configuration, and conventions established here.

## Glossary

- **Toolkit**: The complete AI KPI PowerShell solution comprising the KPI command scripts and the shared library.
- **KPI_Common**: The shared PowerShell library module (`KPI.Common.psm1`) providing configuration loading, authentication, JIRA and GitHub data access, phase resolution, filtering, and output helpers used by all KPI commands.
- **ACR_Command**: The `Get-ACR.ps1` command that computes the AI Contribution Rate.
- **UserMapping_Command**: The `Get-UserMapping.ps1` command that links one person's GitHub, JIRA, and AWS account identities.
- **Field_Discovery_Helper**: The helper routine that queries the JIRA field metadata endpoint to resolve the "AI Evidenced" custom field identifier.
- **Config_File**: The global JSON configuration file consumed by the Toolkit.
- **Config_Loader**: The KPI_Common component that reads, parses, and validates the Config_File.
- **JIRA_Client**: The KPI_Common component that calls the JIRA Cloud REST API v3.
- **GitHub_Client**: The KPI_Common component that calls the GitHub REST API.
- **Phase_Resolver**: The KPI_Common component that maps an Epic name to a phase using the configured keyword mapping.
- **Filter_Engine**: The KPI_Common component that applies date and scope filters to the ticket set.
- **Output_Writer**: The KPI_Common component that renders the console table and writes the CSV file.
- **AI_Evidenced_Field**: The JIRA custom field, identified by a resolved custom field identifier, whose value indicates AI assistance. JIRA may return this field as a plain string, an option object exposing a `value` member, or an array of either shape (a multi-value field).
- **AI_Marker_Value**: The configured string that marks a ticket as AI-assisted, supplied by the `aiAssistedValue` Config_File key; the default is `AI-Assisted`. The same marker applies to both the AI_Evidenced_Field and the Labels fallback under a trimmed, case-insensitive exact comparison.
- **UAT_Passed_Status**: The configured JIRA status name, supplied by the `uatPassedStatus` Config_File key, whose default is `UAT Passed`, that marks a ticket as having passed UAT; used by the time window to include tickets that transitioned to that status during the window.
- **AI_Source**: The evidence source recorded for each ticket's AI determination; one of `AIEvidenced` (the AI_Evidenced_Field matched the AI_Marker_Value), `Label` (a ticket Label matched the AI_Marker_Value), or `None` (no source matched).
- **ACR**: AI Contribution Rate, computed as (AI Assisted tickets / total tickets) * 100.
- **AI_Assisted_Ticket**: A JIRA ticket determined to be AI-assisted per the AI assistance determination rules.
- **Epic**: A JIRA issue of type `Epic` that acts as a phase container; an Epic is never counted as a ticket in ACR.
- **Environment**: A named JIRA target configuration; valid values are `test` (default) and `live`.
- **Phase**: One of five configured delivery phases, or the literal `Unassigned` when an Epic name maps to no configured keyword.
- **Developer**: The person identified by the JIRA ticket Assignee; `Unknown` when no assignee is present.
- **Project**: The JIRA project key associated with a ticket.
- **Development_Panel**: The JIRA development information returned by the development status detail endpoint, including linked pull requests.
- **Pull_Request**: A GitHub pull request (PR) linked to a JIRA ticket.
- **Valid_Target_Branch**: A branch name listed in the Config_File as an allowed PR target branch.
- **Steering_File**: The conventions document stored in `.kiro/steering` that defines the single consistent KPI pattern, commenting standard, and living-documentation rule.
- **RR**: Review Rate KPI (out of scope for implementation in this phase).
- **MLT**: Mean Lead Time KPI (out of scope for implementation in this phase).

## Requirements

### Requirement 1: Global JSON Configuration with Two Environments

**User Story:** As an engineering operations user, I want a single global JSON configuration file that defines two JIRA environments and all source settings, so that I can run KPI commands against test or live data without editing scripts.

#### Acceptance Criteria

1. THE Config_Loader SHALL read a global JSON Config_File that defines two JIRA environments named `test` and `live`.
2. THE Config_Loader SHALL designate the `test` environment as the default environment.
3. THE Config_File SHALL contain, for each JIRA environment, a JIRA base URL, an authentication email, and an API token.
4. THE Config_File SHALL contain a GitHub base URL and a GitHub access token.
5. THE Config_File SHALL contain a phase keyword mapping that associates keywords with each of the five phases.
6. THE Config_File SHALL contain a list of valid target branch names.
7. THE Config_File SHALL contain the resolved AI_Evidenced_Field custom field identifier.
8. WHEN the Config_File is loaded, THE Config_Loader SHALL validate that the required JIRA URL, email, API token, GitHub URL, GitHub token, phase keyword mapping, valid target branch list, AI_Evidenced_Field identifier, and UAT_Passed_Status (`uatPassedStatus`) are present.
9. IF a required Config_File value is missing or empty, THEN THE Config_Loader SHALL return an error that names the missing configuration key and SHALL stop command execution.
10. IF the Config_File cannot be parsed as JSON, THEN THE Config_Loader SHALL return an error that identifies the Config_File path and SHALL stop command execution.
11. WHERE the Config_File supplies the `aiAssistedValue` key, THE Config_Loader SHALL use that value as the AI_Marker_Value, and WHERE the `aiAssistedValue` key is absent or empty, THE Config_Loader SHALL use the default AI_Marker_Value `AI-Assisted`.
12. THE Config_File SHALL contain a `uatPassedStatus` value defining the UAT_Passed_Status, whose default value is `UAT Passed`.

### Requirement 2: Environment Selection Parameter

**User Story:** As a KPI user, I want an environment parameter on each KPI command, so that I can choose the test or live JIRA environment per run.

#### Acceptance Criteria

1. THE ACR_Command SHALL accept an `-Environment` parameter that accepts the values `test` and `live`.
2. WHEN the `-Environment` parameter is omitted, THE ACR_Command SHALL use the `test` environment.
3. IF the `-Environment` parameter value is not `test` and is not `live`, THEN THE ACR_Command SHALL return a validation error that lists the accepted values and SHALL stop command execution.
4. WHEN an Environment is selected, THE JIRA_Client SHALL use the JIRA base URL, email, and API token configured for that Environment.

### Requirement 3: JIRA Cloud Authentication and Data Access

**User Story:** As a KPI user, I want the toolkit to authenticate to JIRA Cloud with email and API token, so that it can retrieve ticket data from the primary source.

#### Acceptance Criteria

1. THE JIRA_Client SHALL authenticate to the JIRA Cloud REST API v3 using the configured email and API token for the selected Environment.
2. WHEN retrieving ticket data, THE JIRA_Client SHALL use the JIRA Cloud REST API v3 enhanced search endpoint `/rest/api/3/search/jql` as the primary data source.
3. WHERE GitHub data is required, THE GitHub_Client SHALL serve as the secondary data source.
4. IF a JIRA Cloud request returns an authentication failure, THEN THE JIRA_Client SHALL return an error that identifies the authentication failure and SHALL stop command execution.
5. IF a JIRA Cloud request returns a non-success HTTP status other than authentication failure, THEN THE JIRA_Client SHALL return an error that includes the HTTP status code and the request context.
6. WHEN a search response includes a next-page token, THE JIRA_Client SHALL request the following page using that `nextPageToken` value and SHALL continue retrieving pages until no next-page token is returned.

### Requirement 4: Field Discovery Helper

**User Story:** As a configuration maintainer, I want a field discovery helper that resolves the "AI Evidenced" custom field identifier from JIRA, so that I can populate the configuration with the correct custom field identifier.

#### Acceptance Criteria

1. THE Field_Discovery_Helper SHALL query the JIRA field metadata endpoint `/rest/api/3/field`.
2. WHEN the field metadata is retrieved, THE Field_Discovery_Helper SHALL identify the field whose name matches "AI Evidenced" and SHALL return the associated custom field identifier.
3. WHEN the matching custom field identifier is returned, THE Field_Discovery_Helper SHALL present the identifier so that it can be recorded in the Config_File.
4. IF no field named "AI Evidenced" is found, THEN THE Field_Discovery_Helper SHALL return a message stating that the field was not found.

### Requirement 5: AI Assistance Determination

**User Story:** As a KPI user, I want a precise rule for deciding whether a ticket is AI-assisted, so that the ACR reflects a consistent and auditable definition.

The AI_Marker_Value used throughout this requirement is the configured `aiAssistedValue` (default `AI-Assisted`), compared under a trimmed, case-insensitive exact match against both the AI_Evidenced_Field candidates and the ticket Labels.

#### Acceptance Criteria

1. WHEN the AI_Evidenced_Field is present on a ticket and any candidate value equals the AI_Marker_Value under a trimmed case-insensitive exact comparison, THE JIRA_Client SHALL classify the ticket as an AI_Assisted_Ticket with AI_Source `AIEvidenced` and SHALL use the AI_Evidenced_Field in place of the ticket Labels for AI assistance determination.
2. WHILE the AI_Evidenced_Field is empty on a ticket, THE JIRA_Client SHALL determine AI assistance from the ticket Labels using a trimmed case-insensitive exact match on the AI_Marker_Value.
3. IF the AI_Evidenced_Field is absent from a ticket, THEN THE JIRA_Client SHALL determine AI assistance from the ticket Labels using a trimmed case-insensitive exact match on the AI_Marker_Value and SHALL complete the determination without raising an error.
4. WHEN a ticket Label exactly matches the AI_Marker_Value under a trimmed case-insensitive comparison and the AI_Evidenced_Field does not override it, THE JIRA_Client SHALL classify the ticket as an AI_Assisted_Ticket with AI_Source `Label`.
5. WHEN neither the AI_Evidenced_Field nor a ticket Label matches the AI_Marker_Value under a trimmed case-insensitive comparison, THE JIRA_Client SHALL classify the ticket as not AI-assisted with AI_Source `None`.
6. WHEN the AI_Evidenced_Field is returned as a plain string, an option object exposing a `value` member, or an array containing either shape, THE JIRA_Client SHALL flatten every shape into candidate strings and SHALL classify the ticket as an AI_Assisted_Ticket when any candidate matches the AI_Marker_Value under a trimmed case-insensitive comparison.
7. IF the AI_Evidenced_Field is present and non-empty but no candidate matches the AI_Marker_Value, THEN THE JIRA_Client SHALL treat the field as authoritative and classify the ticket as not AI-assisted without consulting the ticket Labels.

### Requirement 6: Phase Resolution

**User Story:** As a KPI user, I want each ticket assigned to a delivery phase based on its Epic name, so that ACR can be broken down by phase.

#### Acceptance Criteria

1. WHEN resolving a ticket's Phase, THE Phase_Resolver SHALL derive the Phase from the ticket's Epic name using the configured phase keyword mapping.
2. THE Phase_Resolver SHALL map an Epic name to exactly one of the five configured phases when a configured keyword is present in the Epic name.
3. IF a ticket's Epic name matches no configured phase keyword, THEN THE Phase_Resolver SHALL assign the Phase value `Unassigned`.
4. THE JIRA_Client SHALL exclude every Epic from the counted ticket set, because an Epic is a phase container rather than a counted ticket.

### Requirement 7: Developer and Project Attribution

**User Story:** As a KPI user, I want tickets attributed to a developer and a project, so that ACR can be broken down by developer and project.

#### Acceptance Criteria

1. THE JIRA_Client SHALL set a ticket's Developer to the ticket Assignee.
2. IF a ticket has no Assignee, THEN THE JIRA_Client SHALL assign the Developer to the `Unknown` developer bucket and SHALL record that this attribution is a documented assumption.
3. THE JIRA_Client SHALL set a ticket's Project to the JIRA project key of the ticket.

### Requirement 8: Date and Scope Filtering

**User Story:** As a KPI user, I want to filter tickets by time period and by scope, so that I can measure ACR for a specific month or range and for specific developers or projects.

#### Acceptance Criteria

1. THE Filter_Engine SHALL accept a single-month filter.
2. THE Filter_Engine SHALL accept a date-range filter defined by a start date and an end date.
3. IF both a single-month filter and a date-range filter are supplied in one run, THEN THE Filter_Engine SHALL return a validation error that states that only one time filter may be applied and SHALL stop command execution.
4. THE Filter_Engine SHALL accept a per-developer scope filter that limits results to one developer.
5. THE Filter_Engine SHALL accept a per-project scope filter that limits results to one project.
6. THE Filter_Engine SHALL accept an all-developers scope that includes every developer.
7. WHEN a time filter and a scope filter are supplied together, THE Filter_Engine SHALL apply both filters to the ticket set.
8. WHEN a time window is applied, THE Filter_Engine SHALL include a ticket that was resolved within the window OR whose status changed to the UAT_Passed_Status during the window.
9. WHERE the UAT_Passed_Status is empty, THE Filter_Engine SHALL apply the time window using the resolved date alone.
10. THE Filter_Engine SHALL append the clause `issuetype != Epic` to every composed query so that no Epic is counted as a ticket.

### Requirement 9: AI Contribution Rate Calculation

**User Story:** As a KPI user, I want the AI Contribution Rate computed across the filtered tickets, so that I can report the share of AI-assisted work overall and by breakdown.

#### Acceptance Criteria

1. THE ACR_Command SHALL compute ACR as (AI Assisted tickets / total tickets) multiplied by 100.
2. THE ACR_Command SHALL report an overall ACR value for the filtered ticket set.
3. THE ACR_Command SHALL report ACR broken down per Phase.
4. THE ACR_Command SHALL report ACR broken down per Developer.
5. THE ACR_Command SHALL report the AI_Assisted_Ticket count and the total ticket count for the filtered ticket set.
6. IF the total ticket count for the filtered ticket set is zero, THEN THE ACR_Command SHALL report an ACR of zero and SHALL complete without raising a division error.
7. IF the total ticket count for a Phase or Developer breakdown group is zero, THEN THE ACR_Command SHALL report an ACR of zero for that group and SHALL complete without raising a division error.
8. THE ACR_Command SHALL report, for the overall set and for each Phase and Developer breakdown group, the not-assisted ticket count computed as the total ticket count minus the AI_Assisted_Ticket count.

### Requirement 10: Supporting Pull Request Metrics

**User Story:** As a KPI user, I want pull request metrics linked to tickets, so that ACR reporting can be supported by code change evidence from valid target branches.

#### Acceptance Criteria

1. THE JIRA_Client SHALL retrieve linked Pull_Requests from the JIRA Development_Panel using the endpoint `/rest/dev-status/latest/issue/detail`.
2. THE GitHub_Client SHALL retrieve, for each linked Pull_Request, the lines-of-code additions, deletions, and changed-files counts.
3. WHEN the same commit SHA appears in more than one retrieved Pull_Request record, THE GitHub_Client SHALL deduplicate the records by commit SHA so that each commit SHA is counted once.
4. THE GitHub_Client SHALL count only Pull_Requests whose target branch is a Valid_Target_Branch defined in the Config_File.
5. WHEN linking a JIRA ticket to a Pull_Request, THE JIRA_Client SHALL use the JIRA Development_Panel link as the primary link source.
6. WHERE the Development_Panel provides no link for a ticket, THE JIRA_Client SHALL link the ticket to a Pull_Request by matching the JIRA key found in the Pull_Request title or branch name.

### Requirement 11: Output Rendering

**User Story:** As a KPI user, I want ACR results in both a console table and a CSV file with breakdowns and filter metadata, so that I can read results immediately and share or archive them.

#### Acceptance Criteria

1. THE Output_Writer SHALL render ACR results as a console table.
2. THE Output_Writer SHALL write ACR results to a CSV file.
3. THE Output_Writer SHALL include a per-Phase breakdown in the console table and in the CSV file.
4. THE Output_Writer SHALL include a per-Developer breakdown in the console table and in the CSV file.
5. THE Output_Writer SHALL include the applied filter metadata, comprising the selected Environment, the applied time filter, and the applied scope filter, in the CSV file.
6. IF the CSV file cannot be written to the target path, THEN THE Output_Writer SHALL return an error that identifies the target path.
7. THE Output_Writer SHALL include the not-assisted ticket count alongside the AI_Assisted_Ticket count, total ticket count, and ACR value in each per-Phase and per-Developer row of the console table and the CSV file.
8. THE ACR_Command SHALL print the generated JQL query to the console.
9. WHERE the `-ConsoleOnly` switch is supplied, THE ACR_Command SHALL write no CSV file and SHALL instead print a per-ticket table listing the ticket Key, Phase, IssueType, Developer, AI assistance indicator, AI_Source, and Summary for each fetched ticket.
10. WHERE the `-ConsoleOnly` switch is supplied, THE ACR_Command SHALL print a per-Phase table of total, AI_Assisted_Ticket, not-assisted, and ACR values, and SHALL print an overall line reporting the overall ACR, total, AI_Assisted_Ticket, and not-assisted counts.

### Requirement 12: User Mapping Command

**User Story:** As a data integrity maintainer, I want a command that links one person's GitHub, JIRA, and AWS accounts, so that cross-source KPI data is not duplicated or mismatched across identities.

#### Acceptance Criteria

1. THE UserMapping_Command SHALL associate, for one person, a GitHub account identity, a JIRA account identity, and an AWS account identity.
2. THE UserMapping_Command SHALL produce a mapping that links the three account identities to a single person.
3. WHEN a KPI command attributes data across JIRA and GitHub sources, THE KPI_Common SHALL use the user mapping to associate records from different sources with the same person.
4. IF two source identities for one person are provided that would create a duplicate or mismatched mapping, THEN THE UserMapping_Command SHALL return an error that identifies the conflicting identities.

### Requirement 13: Toolkit Structure and Command Design

**User Story:** As a toolkit maintainer, I want a fixed file structure with one command per KPI and a single shared library, so that the toolkit stays consistent and easy to extend.

#### Acceptance Criteria

1. THE Toolkit SHALL expose exactly one command per KPI.
2. THE Toolkit SHALL implement filters as parameters of the KPI command rather than as additional commands.
3. THE Toolkit SHALL consist of exactly four KPI or mapping files named `Get-ACR.ps1`, `Get-RR.ps1`, `Get-MLT.ps1`, and `Get-UserMapping.ps1`.
4. THE Toolkit SHALL provide exactly one shared library file named `KPI.Common.psm1`.
5. THE ACR_Command and the UserMapping_Command SHALL obtain configuration loading, authentication, JIRA and GitHub data access, phase resolution, filtering, and output rendering from the KPI_Common shared library.
6. WHERE the RR and MLT KPIs are implemented in a future phase, THE Toolkit SHALL have RR and MLT reuse the KPI_Common shared data layer rather than introduce a separate data layer.

### Requirement 14: Steering Conventions

**User Story:** As a toolkit maintainer, I want a steering file that defines one consistent KPI pattern, a commenting standard, and a living-documentation rule, so that every KPI script follows the same conventions.

#### Acceptance Criteria

1. THE Toolkit SHALL include one Steering_File stored in the `.kiro/steering` directory.
2. THE Steering_File SHALL define one consistent implementation pattern that applies across all KPI commands.
3. THE Steering_File SHALL define a commenting standard that requires detailed but concise comments that conserve token usage.
4. THE Steering_File SHALL define a living-documentation rule that requires documentation to be updated when KPI behavior changes.
