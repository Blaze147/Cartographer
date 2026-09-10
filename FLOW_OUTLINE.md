# Cartographer — Expected End-to-End Flow (and why you're currently stuck)

This document explains **exactly** what is supposed to happen, in order, when you use
Cartographer to run an experiment, and pinpoints why the agent is sitting on
`Status: Idle, Harness: dsh, Branch: ____` after you created an experiment.

---

## 1. The three moving parts

| Part | What it is | What it does |
| --- | --- | --- |
| **Server** (ASP.NET Core) | The web app on `http://127.0.0.1:5080` | Holds experiment state, persists to `server/data.json`, serves the dashboard. |
| **Agent** (Swift menu bar app) | `Cartographer/macos-agent` | Polls the server for commands, performs Git work, reports back. Runs **detached** after F5. |
| **Dashboard** (browser) | `server/wwwroot/index.html` | Lets you start/complete experiments and enter manual results. |

F5 (via `.vscode/run-cartographer.js`) starts the server, opens the dashboard, and
launches the agent as a background menu-bar process. The agent reads its config
from `~/.cartographer/config.json` and talks to the server at
`http://127.0.0.1:5080`.

---

## 2. The full intended flow, step by step

### A. Agent comes alive (after F5)
1. Agent loads `~/.cartographer/config.json`.
   - `repositoryPath` = where it will run Git (`/Users/james/Cartographer_WS2`).
   - `serverUrl` = `http://127.0.0.1:5080`.
2. Agent sets its own status to **Idle**. It **sends a heartbeat** to the server,
   which causes the server to register the machine (`jamess-macbook-pro-local`)
   and show it in the dashboard **Machines** table.
3. Agent starts a loop:
   - every **30 s** while Idle/Ready, every **5 s** while busy,
   - each tick: `POST /heartbeat` then `GET /agents/{machineId}/command`.

> **Menu bar state at this point:** `Status: Idle, Branch: ____` (blank is normal —
> the branch field only fills in after a `prepare` succeeds). "Copy Current Prompt"
> is **greyed out** because no prompt is loaded yet.

### B. You create an experiment (in the dashboard)
1. Fill in **Baseline tag** (default `baselineB001`), **Task**, **Attempt**, and
   a **Prompt**.
2. Click **Start experiment**.
3. Server creates an experiment record **and** a `prepare` command for **every
   machine currently registered**. The branch name is built predictably:
   - Baseline `baselineB001` + Task `1` + Attempt `1` + harness `dsh`
     → branch `B001-T001-A01-dsh`.

### C. Agent picks up the prepare command
4. On its next poll, the agent receives the `prepare` command and runs
   `prepare(cmd)`.
5. `prepare` does this **in order** (any failure aborts and reports back `Failed`):
   1. Checks the repository folder exists.
   2. Tries `git fetch --tags` (ignored if no remote).
   3. **Verifies the baseline tag resolves to a commit:**
      `git rev-parse --verify baselineB001^{commit}` — ⚠️ **this is the blocker.**
   4. Requires the working tree to be **clean** (`git status --porcelain` empty).
   5. Requires the target branch to **not already exist**.
   6. Creates + checks out the branch:
      `git checkout -b B001-T001-A01-dsh baselineB001`.
6. On success the agent:
   - sets status to **Ready**,
   - sets the **Branch** field to `B001-T001-A01-dsh`,
   - **stores the experiment prompt** so **"Copy Current Prompt" becomes enabled**,
   - reports the command `Complete` to the server.

### D. You run the coding harness
7. You click **Copy Current Prompt** (now enabled), paste it into your coding
   harness (OpenHands, Claude Code, Codex, DeepSeek Harness, etc.), and run it
   inside the checked-out branch in the repo.
8. When the work is done, you **stage and commit** the changes yourself (the agent
   never touches your commits).

### E. Collect results
9. In the dashboard click **Complete experiment**.
10. Server sends a `collect` command to every machine.
11. Agent verifies the tree is clean, gathers Git statistics (SHA, files/lines
    changed, full diff) between the baseline tag and `HEAD`, and reports them.
12. Agent sets status to **Collected**. The experiments table fills in the auto
    numbers; you fill in the manual fields (status, score, time, tokens, notes).

---

## 3. Why you're stuck right now — and yes, it's the git state

You're seeing **`Status: Idle, Branch: ____`**, and you can't copy the prompt. Here
is the diagnosis, confirmed by inspecting the code and your repo:

1. **A blank Branch is normal** until a `prepare` succeeds. Nothing is wrong there
   by itself — the field genuinely only fills in after a successful prepare.
2. **You can't copy the prompt yet by design.** The prompt is only loaded into the
   agent *after* a successful `prepare`. The **"Copy Current Prompt"** button is
   disabled until then. This is **not** a bug — it's the intended gate so you don't
   copy a prompt for an experiment whose branch isn't prepared yet.
3. **The real blocker is the missing Git baseline tag.** I inspected
   `/Users/james/Cartographer_WS2`:
   - Current branch: `main`
   - **Git tags: NONE** → in particular **`baselineB001` does not exist**.
   - Remotes: none.
   - Working tree: clean (good — this precondition is satisfied).

   The `prepare` step performs `git rev-parse --verify baselineB001^{commit}`, which
   **fails** because no such tag (or commit) exists. When that throws, the agent
   aborts `prepare`, sets `status = "Error"`, and reports the command as `Failed`.

### Why you saw "Idle" rather than "Error"
This depends on timing/machine registration, but the two most likely scenarios are:

- **Timing:** the experiment's `prepare` command hasn't been picked up yet. Right
  after creation the agent's next poll can be up to 30 s away, and its reason to stay
  "Idle" is that it still sees no pending command, or
- **No registered machine at start time:** `prepare` commands are only created for
  machines **currently in `store.Machines`**. If you created the experiment while the
  agent wasn't running (or after the DB was cleared), **no prepare command was
  generated**, so the agent has literally nothing to do and stays Idle forever.

> Server commands are **one-shot**: a prepare that fails is marked `Failed`, and a
> prepare that was never created won't spontaneously appear. Nothing retries.

---

## 4. What you need to do next (in order)

1. **Create the baseline tag.** In the repo the agent works on
   (`/Users/james/Cartographer_WS2`, per your current config), create a tag at a
   commit you want to treat as the baseline. For the default form field
   `baselineB001`:
   ```bash
   cd /Users/james/Cartographer_WS2
   git tag baselineB001 main        # or: git tag baselineB001 <some-commit-sha>
   git tag                          # confirm it exists
   ```
   (If you plan to test in a throwaway repo, you can instead make a fresh tag
   there and put the matching baseline string in the dashboard.)

2. **Make sure the agent is running and registered**, then confirm the dashboard
   **Machines** table shows your machine, and (re)create the experiment so a
   `prepare` command targets that registered machine.

3. Watch the agent transition: **Idle → Preparing → Ready**, Branch = `B001-T001-A01-dsh`.
4. **Copy Current Prompt** is now enabled — click it, paste into your harness.
5. Run, commit, then **Complete experiment** in the dashboard to collect stats.

---

## 5. Summary answer to your two questions

- **Is being stuck due to the git status of the project?** **Yes** — almost
  certainly. The repo the agent works on has **no `baselineB001` tag** (and no tags
  at all). The prepare step is hard-gated on that tag, so the agent can never reach
  `Ready`, set the branch, or unlock the prompt.
- **Is it a bug?** The **blank branch + disabled "Copy Prompt" is intended
  behavior** (by design, gated on successful prepare). The one genuinely surprising
  (arguably weak UX) aspect is that **a missing baseline tag fails the whole prepare
  and there's no auto-retry**, plus the fact that if the experiment was started with
  no machine registered, no prepare is ever issued. Neither is a crash; both are
  configuration/sequence conditions.

**Bottom line:** create the `baselineB001` tag, ensure the agent is registered,
re-create the experiment, and the described Idle → Ready flow (branch + enabled
Copy Prompt) will follow.
