# Cartographer

A very small distributed experiment-control application for comparing coding
harnesses across several Macs.

Two parts:

1. **Server** — a cloud-hosted ASP.NET Core web app (this repo, `server/`).
2. **macOS agent** — a tiny menu-bar app running on each test Mac (`macos-agent/`).

Each Mac periodically asks the server whether a command is waiting (polling),
so no inbound connections, port forwarding, or VPNs are needed. The server is
the authoritative source of experiment state and persists to a single JSON file.

## Layout

```
server/            ASP.NET Core server + static web frontend + Dockerfile
macos-agent/       Swift Package Manager menu-bar agent
example-config/    Sample agent and server configuration
```

## How to run the server locally

Requires .NET 8 SDK. From `server/`:

```bash
dotnet run
```

By default it listens on `http://localhost:5080` (see `appsettings.json`).
Open the dashboard in a browser: <http://localhost:5080>.

Configuration comes from environment variables (or `appsettings.json`):

| Variable | Purpose |
| --- | --- |
| `ASPNETCORE_URLS` | HTTP listen URL/port (e.g. `http://+:5080`) |
| `CARTOGRAPHER_DATA` | Path to the JSON persistence file (default `data.json`) |
| `CARTOGRAPHER_API_KEY` | Optional shared secret agents must send as `X-Api-Key` |
| `CARTOGRAPHER_WEB_PASSWORD` | Optional browser password for the dashboard |
| `CARTOGRAPHER_OFFLINE_SECONDS` | Heartbeats older than this count the machine Offline (default 90) |

If `CARTOGRAPHER_API_KEY` is set, every agent heartbeat/command call must send
it in the `X-Api-Key` header. If `CARTOGRAPHER_WEB_PASSWORD` is set, the
dashboard asks for the password once and remembers it in a cookie.

### Running in Docker

Build the image from `server/`:

```bash
docker build -t cartographer .
docker run -p 8080:8080 -v cart-data:/data cartographer
```

Persistent state lives in the `/data` volume. The same image works on a normal
Linux VM (e.g. Oracle Cloud) and on Google Cloud Run later — no provider-specific
code is included.

## How to configure an agent

Create `~/.cartographer/config.json` on each Mac, for example:

```json
{
  "machineId": "openhands",
  "harness": "OpenHands",
  "repositoryPath": "/Users/example/Projects/Pathfinder",
  "serverUrl": "https://example.com",
  "apiKey": ""
}
```

* `machineId` — unique per worker machine (e.g. `openhands`, `claude-machine-2`).
* `harness` — the coding harness assigned to that worker (e.g. `claude`, `codex`,
  `openhands`, `dsh`, `goose`). It is configurable, not inferred.
* `repositoryPath` — a local Git clone that the experiment runs in.
* `serverUrl` — the Cartographer server base URL.
* `apiKey` — leave empty, or set to the same value as `CARTOGRAPHER_API_KEY`.

The config path can be overridden with the `CARTOGRAPHER_CONFIG` environment
variable.

Each agent remembers the IDs of commands it has already processed (stored in
`UserDefaults`), so it never re-runs the same Git operation.

## How to start the Mac agent

From `macos-agent/`:

```bash
swift build
.open .build/debug/CartographerAgent
```

or open the package in Xcode:

```bash
open Package.swift
```

Run the `CartographerAgent` scheme. A menu-bar icon appears. Its color reflects
state: **green** ready, **orange** working, **red** error or unreachable server,
**gray** idle. The menu shows status, harness, branch, lets you **Copy Current
Prompt** (the experiment prompt, for pasting manually into a coding harness),
**Open Dashboard**, **Refresh**, and **Quit**.

If Python/`open` are unavailable, launch the built binary directly:

```bash
.build/debug/CartographerAgent &
```

The agent does **not** control any coding harness; you run OpenHands, Claude
Code, Codex, DeepSeek Harness, etc. manually and use **Copy Current Prompt** to
paste the task in.

## How to run a test experiment

1. Register at least one machine by starting its agent, which begins sending
   heartbeats and appears in the dashboard (registration is implicit).
2. In the dashboard, fill in **Baseline** (a Git tag such as `baselineB001`),
   **Task number**, **Attempt number**, and **Prompt**, then click
   **Start experiment**. The server creates a `prepare` command for every
   registered machine and an experiment record with a unique ID.
3. Each agent prepares its repo: verifies the baseline tag exists, checks the
   working tree is clean, creates its branch
   (e.g. `B001-T004-A02-openhands` for `baselineB001`, task 4, attempt 2,
   harness OpenHands), and reports errors if anything is wrong.
4. Manually run the coding harness in that repo on the new branch. When done,
   **stage and commit** all experiment changes yourself.
5. Click **Complete experiment** in the dashboard. The server sends a `collect`
   command to every machine. Each agent verifies the repo is clean, then gathers
   committed Git statistics (SHA, files/lines changed, and the full diff) and
   sends them to the server.
6. The experiment table fills in the automatically collected numbers. Enter the
   manual fields — completion status, score, elapsed time, tokens, notes — for
   each harness run directly in the table.

## Git assumptions

* Each repository is a normal Git clone and the harness runs inside it.
* Experiments are measured as the committed difference between the baseline tag
  (e.g. `baselineB001`) and the completed experiment branch.
* The working tree must be **clean** before preparing (uncommitted work is
  never destroyed) and before collecting (you must stage and commit first).
* The agent never auto-stages, commits, resets, or deletes anything.

## API

The server exposes a small JSON API (see `server/Program.cs`):

```
GET  /api/machines
GET  /api/experiments
GET  /api/experiments/{id}
POST /api/experiments/start
POST /api/experiments/{id}/complete
POST /api/experiments/{id}/runs/{machineId}
GET  /api/agents/{machineId}/command
POST /api/agents/{machineId}/heartbeat
POST /api/agents/{machineId}/command-result
```
