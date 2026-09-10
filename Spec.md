# Cartographer

## Goal

Build a very small distributed experiment-control application for comparing coding harnesses across several Macs.

The system has two parts:

1. A central cloud-hosted web application.
2. A tiny native macOS menu-bar agent running on each test machine.

The cloud application is the control point. The Mac agents are simple workers that receive commands, run Git operations locally, and report automatically measurable information back to the server.

Keep the implementation as small and understandable as possible. Avoid frameworks, databases, abstractions, and infrastructure that are not clearly needed.

This is an experimental utility, not a production SaaS product.

## Size target

Try to keep each major piece very small:

* C# backend: approximately 200 lines or less if practical.
* HTML and JavaScript frontend: approximately 200 lines or less if practical.
* Swift macOS agent: approximately 200 lines or less if practical.

These are goals, not hard limits. Do not make the code obscure or brittle just to hit a line count.

Prefer simple, readable code over architecture patterns.

## Technology

### Cloud server

Use:

* C#
* ASP.NET Core Minimal API
* .NET 8 or newer
* JSON file persistence
* Static HTML frontend
* Bootstrap
* Vanilla JavaScript

Do not use:

* Razor
* React
* Angular
* Vue
* TypeScript unless there is a compelling reason
* Entity Framework
* SQLite
* any other database
* Redis
* message queues
* authentication systems beyond a simple shared API key if needed
* unnecessary dependency-injection layers or repository patterns

The server should be suitable for running inside a Docker container.

It should not contain provider-specific logic for Oracle Cloud or Google Cloud Run.

### macOS agent

Use:

* Swift
* SwiftUI
* MenuBarExtra if appropriate
* Foundation URLSession for HTTP
* Process for running Git commands
* NSPasteboard for clipboard access

The agent should run as a small macOS menu-bar application.

Do not build a full windowed application.

## Basic architecture

Each Mac initiates communication with the cloud server.

Do not require inbound connections to the Macs.

The Mac agent should periodically ask the server whether there is a command waiting for it.

Example:

```text
Mac -> GET /api/agents/{machineId}/command
Server -> current command or no command
```

This avoids port forwarding, public IP addresses, VPN configuration, and local HTTP servers.

The server is the authoritative source of experiment state.

## Machine configuration

Each Mac should have a very small local configuration containing:

```json
{
  "machineId": "openhands",
  "harness": "OpenHands",
  "repositoryPath": "/Users/example/Projects/Pathfinder",
  "serverUrl": "https://example.com",
  "apiKey": "optional-shared-secret"
}
```

Each machine has a unique `machineId`.

The harness name should be configurable rather than inferred.

Examples include:

* claude
* codex
* openhands
* dsh
* goose

The machine ID identifies the individual worker. The harness identifies the coding harness assigned to that worker.

A machine should register itself implicitly through its heartbeat. If the server receives a heartbeat from an unknown machine ID, it should create a machine record using the information supplied by the agent. Later heartbeats should update the existing record.

No separate machine-registration system is needed.

## Experiment model

An experiment attempt needs at least:

```json
{
  "baseline": "baselineB001",
  "taskNumber": 4,
  "attemptNumber": 2,
  "prompt": "Task text goes here"
}
```

A baseline is a Git tag identifying the exact commit from which an experiment starts.

For example:

```text
baselineB001
```

The cloud application should let the user manually choose or enter:

* baseline
* task number
* attempt number
* prompt

The server may suggest the next task number or next attempt number based on existing records, but the user should be able to override it.

The server should automatically assign a unique experiment ID and record when the experiment was created.

At minimum, store a `createdAt` timestamp. Additional timestamps such as preparation or collection times may be recorded if they are useful and inexpensive to implement.

### Experiments and runs

An experiment represents one attempt at one task from one baseline.

For example:

```text
Baseline: baselineB001
Task: 4
Attempt: 2
Prompt: Task text
```

Each participating machine produces one run within that experiment.

A run contains the machine-specific and harness-specific results, including Git statistics and manually entered evaluation information.

One experiment therefore contains multiple runs, normally one for each registered machine.

## Branch naming

When a new experiment starts, every registered Mac should create its own branch.

Use a predictable format:

```text
B001-T004-A02-openhands
B001-T004-A02-claude
B001-T004-A02-codex
```

The branch name must contain:

* baseline identifier
* task number
* attempt number
* harness or machine identifier

The Git baseline tag uses the longer form:

```text
baselineB001
```

When constructing the experiment branch name, remove the `baseline` prefix:

```text
baselineB001 -> B001
```

Therefore:

```text
baselineB001
Task 4
Attempt 2
OpenHands
```

produces:

```text
B001-T004-A02-openhands
```

The exact capitalization and padding rules should be consistent across all machines.

If the harness identifier alone cannot uniquely identify a run, the unique machine ID should also be included in the branch name.

## Starting an experiment

The web UI should have a simple form containing:

```text
Baseline
Task number
Attempt number
Prompt

[Start experiment]
```

When Start Experiment is clicked, the server creates a prepare command for every registered machine.

All registered machines should receive the experiment. V1 does not require selecting a subset of machines.

Each Mac eventually receives a command similar to:

```json
{
  "id": "unique-command-id",
  "type": "prepare",
  "baseline": "baselineB001",
  "taskNumber": 4,
  "attemptNumber": 2,
  "prompt": "..."
}
```

The Mac should then prepare its local Git repository.

The exact Git commands may depend on repository state, but the intended result is:

1. Fetch remote information and tags if needed.
2. Verify that the requested baseline tag exists.
3. Check the working tree for unexpected changes.
4. Leave any previous experiment branch.
5. Restore the repository to the commit identified by the specified baseline tag.
6. Create the new experiment branch from that baseline.
7. Verify the current branch.
8. Report success or failure to the server.

Do not silently destroy uncommitted work.

If the working tree contains unexpected uncommitted or untracked changes before preparation, report an error instead of resetting or deleting them.

## Machine status

Each agent should periodically report:

* machine ID
* harness
* current branch
* current state
* last error, if any

The heartbeat itself establishes that the agent is online. The agent does not need to send a separate `online` value.

The server should record the time of the most recent heartbeat and derive Online or Offline status from it.

The server should consider a machine offline if it has not sent a heartbeat within a reasonable period.

Suggested agent states:

```text
Idle
Preparing
Ready
Collecting
Collected
Error
```

`Collected` means that Git results for the current experiment have been successfully gathered and sent to the server.

This is separate from the manually entered run completion status described later.

## Menu-bar application

The Mac menu-bar application should remain extremely small.

The menu-bar icon or label should communicate status.

Suggested states:

* green: connected and ready
* orange: performing an operation
* red: error or cannot reach server
* gray: idle or no active experiment

The menu should show approximately:

```text
Cartographer
Status: Ready
Harness: OpenHands
Branch: B001-T004-A02-openhands
Copy Current Prompt
Open Dashboard
Refresh
Quit
```

`Copy Current Prompt` should copy the prompt for the current experiment to the macOS clipboard.

This is important because the user will manually paste that prompt into the coding harness.

The agent must not attempt to control OpenHands, Claude Code, Codex, DeepSeek Harness, or any other coding harness.

The user will run those manually.

## Completing an experiment

The cloud UI should have a button:

```text
[Complete experiment]
```

When Complete Experiment is clicked, every registered machine receives a collection command.

When a machine handles that command, it should first automatically stage and commit
all current changes in its repository (including untracked files), so there is no
need for the user to stage or commit by hand before completing the experiment. The
commit message should describe the experiment, e.g. the baseline, harness, task
number, and attempt number. If there is nothing to commit (the tree is already
clean), the agent should continue without making a commit. The agent should supply
an inline git identity so the commit never fails on machines that have no global
`user.name` / `user.email` configured.

The experiment branch's committed state (which now includes the agent's automatic
commit) is the state Cartographer measures.

After staging and committing, the agent should inspect the current experiment branch
and gather information that can be determined reliably from Git.

The agent should send the results to the server.

Do not reset the repository immediately after collection unless explicitly requested.

Leaving the completed experiment branch checked out is acceptable.

## Automatically collected run data

Collect only information that can be determined reliably and simply.

Required automatic fields:

* machine ID
* harness
* branch name
* baseline
* task number
* attempt number
* current commit SHA
* files changed
* files added
* files modified
* files deleted
* lines added
* lines deleted
* list of changed files

If easy, also collect:

* rename count
* per-file additions and deletions
* full Git diff

The server should tolerate missing optional fields.

Use Git itself as the source of truth.

The comparison should represent the committed difference between the baseline tag and the completed experiment branch.

Commands such as the following may be useful:

```bash
git diff --name-status BASELINE BRANCH
git diff --numstat BASELINE BRANCH
git diff BASELINE BRANCH
git rev-parse HEAD
git branch --show-current
git status --porcelain
```

For example, an experiment created from `baselineB001` should measure the difference between the commit identified by `baselineB001` and the current committed state of the experiment branch.

Do not attempt to infer token usage, model calls, tool calls, cost, or other harness-internal telemetry automatically.

## Manually entered run data

The cloud UI should allow the user to manually enter these values for each harness run:

* completion status
* score from 0 to 10
* elapsed time
* token usage
* notes

Completion status should be separate from score.

Suggested completion values:

```text
Completed
Aborted
```

Token usage may be blank.

Elapsed time may be blank.

Notes should be free text.

## Results view

The main experiment page should show a compact table such as:

```text
Harness      Status      Score    Time    Tokens    Files    +Lines    -Lines
Claude       Completed   8.5      3:42    32000       3        41        12
OpenHands    Completed   7.0      6:15    48000       5        77        19
DSH          Aborted     4.0      8:01    61000       4        52        31
```

Fields collected automatically should appear without manual entry.

Manual fields should be editable directly from the web interface.

## Persistence

Use a JSON file rather than a database.

The server should load the file at startup and save it when state changes.

Use safe writes.

A reasonable method is:

1. Serialize to a temporary file.
2. Replace the existing data file atomically where possible.

Keep the data model simple.

A possible top-level format is:

```json
{
  "machines": [],
  "experiments": []
}
```

Each experiment may contain its associated runs and command information if that keeps the model simple.

Do not create separate JSON files unless doing so clearly makes the implementation simpler.

The persistence code should be isolated enough that another storage method could be substituted later, but do not build an elaborate storage framework.

A small interface is sufficient if useful.

## Commands and duplicate handling

Every server command should have a unique ID.

Example:

```json
{
  "id": "uuid",
  "type": "prepare"
}
```

Each Mac should remember the last processed command or processed command IDs so it does not execute the same Git operation multiple times.

This can be stored in a tiny local JSON file or UserDefaults.

The server should also keep command state.

Suggested command states:

```text
Pending
Acknowledged
Complete
Failed
```

A command belongs to a specific machine even when the same experiment operation is sent to every registered machine.

For example, starting one experiment may create eight separate prepare commands, one for each of eight registered machines.

## Communication

Use ordinary HTTPS JSON requests.

Keep the API small.

A possible API is:

```text
GET  /api/state
GET  /api/machines
GET  /api/experiments
POST /api/experiments/start
POST /api/experiments/{id}/complete
GET  /api/agents/{machineId}/command
POST /api/agents/{machineId}/heartbeat
POST /api/agents/{machineId}/command-result
POST /api/experiments/{experimentId}/runs/{machineId}
```

This exact route structure is not mandatory.

Prefer fewer endpoints if the same behavior can be achieved cleanly.

## Polling

The Mac agents may use simple polling.

For example:

```text
Active experiment: poll every 3 to 5 seconds
Idle: poll every 30 seconds
```

Exact timing is not important.

Do not add WebSockets unless polling creates a real problem.

## Error handling

Keep error handling simple but visible.

Important errors include:

* cloud server unreachable
* repository path missing
* Git command failed
* baseline tag does not exist
* working tree has unexpected changes before preparation
* the automatic stage/commit fails during collection (e.g. git commit errors)
* branch already exists unexpectedly
* server command could not be completed

Errors should appear in both:

* the Mac menu-bar status
* the cloud dashboard

Do not automatically run destructive recovery commands when something unexpected happens.

## Security

This is a private experimental application.

Do not build user accounts.

If the server is exposed to the public internet, require one simple shared secret or API key for communication between agents and the server.

Administrative operations exposed through the browser should also be protected by a simple password or shared secret when the server is publicly reachable.

Do not implement OAuth or a user-management system.

Do not store secrets in source control.

## Docker

Provide a simple Dockerfile for the ASP.NET Core server.

The same server image should be deployable to:

* a normal Linux VM such as Oracle Cloud
* Google Cloud Run later

Do not add cloud-provider-specific code to the application.

Configuration such as data paths, API keys, and ports should come from environment variables or ordinary application configuration.

## Deployment portability

The server should not assume:

* a specific hostname
* a specific cloud vendor
* a specific Linux distribution
* permanent in-memory state
* a fixed HTTP port

Read the HTTP port from environment or application configuration as needed.

The JSON-file version can initially target a persistent VM disk.

Keep persistence separated enough that it could later be replaced if Cloud Run is used.

## Out of scope for version 1

Do not build:

* automated harness launching
* automated prompt submission into coding harnesses
* model telemetry collection
* token extraction from harness logs
* cost calculation
* multi-user accounts
* distributed locking
* WebSockets
* SQLite or another database
* React or another frontend framework
* elaborate styling
* charts
* CI/CD
* diff visualization UI
* code syntax highlighting
* Git merge management
* automatic grading

A full diff viewer may be added later.

For V1, collecting the diff and storing it is enough if doing so is easy.

## Code quality

Optimize for:

* few files
* few dependencies
* obvious control flow
* easy debugging
* easy modification by one developer

Avoid building generic frameworks.

Avoid unnecessary classes.

Avoid patterns used only because they are common in larger enterprise applications.

Comments should explain non-obvious behavior rather than narrate straightforward code.

## Expected deliverables

Produce:

1. ASP.NET Core server project.
2. Static Bootstrap and vanilla JavaScript web frontend.
3. Swift macOS menu-bar agent project.
4. Dockerfile for the server.
5. Example server configuration.
6. Example agent configuration.
7. Short README containing:

   * how to run the server locally
   * how to configure an agent
   * how to start the Mac agent
   * how to run a test experiment
   * any Git assumptions

## First end-to-end goal

The first goal is a working end-to-end path:

```text
Open dashboard
-> create experiment
-> server creates commands for every registered machine
-> agents receive experiment
-> agents verify baseline tags
-> agents create correct branches
-> menu bars show Ready
-> user manually runs coding harnesses
-> user clicks Complete (no manual staging or committing needed)
-> agents automatically stage and commit all experiment changes
-> agents collect committed Git statistics
-> results appear in dashboard
-> user enters completion status, score, elapsed time, tokens, and notes
```

If a design decision can be solved either with more infrastructure or with approximately 20 lines of straightforward code, choose the straightforward code.
