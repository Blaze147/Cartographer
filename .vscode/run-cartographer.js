#!/usr/bin/env node
/**
 * Cartographer F5 orchestrator (mirrors the working pattern from Test_X1's
 * run-poc.js).
 *
 * Preconditions (handled by the `build-all` preLaunchTask in tasks.json):
 *   - ASP.NET Core server already built (Cartographer/server).
 *   - Swift macOS agent already built (Cartographer/macos-agent).
 *
 * What this script does:
 *   1. Starts the ASP.NET Core server (on http://127.0.0.1:5080) in the
 *      foreground of this task and streams its log to the terminal.
 *   2. Waits until the server is reachable, then opens its dashboard UI in
 *      the browser (Safari).
 *   3. Ensures a local agent config exists (a small one pointing at this
 *      server), then launches the compiled Swift agent as a detached
 *      background menu-bar process so BOTH sides are running and talking.
 *   4. Stays alive until the server exits; pressing "Stop" in VSCode kills
 *      this script, which cleans up the server child process.
 */

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const WORKSPACE = path.join(__dirname, '..');
const DOTNET = '/usr/local/share/dotnet/dotnet';
const SERVER_DIR = path.join(WORKSPACE, 'Cartographer', 'server');
const SERVER_URL = 'http://127.0.0.1:5080/';
const PORT = 5080;

// Resolve the compiled Swift agent binary. SwiftPM places it at:
//   Cartographer/macos-agent/.build/debug/CartographerAgent
const AGENT_BIN = path.join(
  WORKSPACE, 'Cartographer', 'macos-agent', '.build', 'debug', 'CartographerAgent'
);

// Default local agent config. The agent reads CARTOGRAPHER_CONFIG or
// ~/.cartographer/config.json. If the user hasn't made one, we create a
// local one pointing at the server this script starts, so the agent can
// register and the two sides actually talk.
const LOCAL_CONFIG_PATH = path.join(os.homedir(), '.cartographer', 'config.json');
const DEFAULT_MACHINE_ID = os.hostname().toLowerCase().replace(/[^a-z0-9-]/g, '-') || 'local-mac';

function fail(msg) {
  console.error('\n[cartographer] ERROR: ' + msg);
  process.exit(1);
}

if (!fs.existsSync(DOTNET)) {
  fail(`dotnet not found at ${DOTNET}. Install the .NET SDK and update DOTNET in ${__filename}.`);
}
if (!fs.existsSync(path.join(SERVER_DIR, 'Cartographer.csproj'))) {
  fail(`Server project not found at ${SERVER_DIR}.`);
}
if (!fs.existsSync(AGENT_BIN)) {
  fail(`Agent binary not found at ${AGENT_BIN}. Did the build-all preLaunchTask succeed?`);
}

// ---- Local agent config -----------------------------------------------

function ensureAgentConfig() {
  // Only create one if the user hasn't already configured this machine.
  if (process.env.CARTOGRAPHER_CONFIG) return;
  if (fs.existsSync(LOCAL_CONFIG_PATH)) {
    console.log(`[cartographer] Using existing agent config at ${LOCAL_CONFIG_PATH}`);
    return;
  }
  try {
    const cfg = {
      machineId: DEFAULT_MACHINE_ID,
      harness: 'dsh',
      repositoryPath: WORKSPACE,
      serverUrl: 'http://127.0.0.1:5080',
      apiKey: ''
    };
    fs.mkdirSync(path.dirname(LOCAL_CONFIG_PATH), { recursive: true });
    fs.writeFileSync(LOCAL_CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n');
    console.log(`[cartographer] Created local agent config at ${LOCAL_CONFIG_PATH} pointing at this server.`);
  } catch (e) {
    console.error('[cartographer] Could not write agent config: ' + e.message);
  }
}

// ---- Server -----------------------------------------------------------

console.log('[cartographer] Starting Cartographer server on ' + SERVER_URL);

const webChild = spawn(DOTNET, ['run', '--no-build', '--project', SERVER_DIR], {
  cwd: SERVER_DIR,
  env: {
    ...process.env,
    ASPNETCORE_URLS: 'http://127.0.0.1:5080',
    ASPNETCORE_ENVIRONMENT: 'Development',
    CARTOGRAPHER_DATA: 'data.json'
  },
  stdio: ['ignore', 'pipe', 'pipe'],
});

webChild.stdout.on('data', (d) => process.stdout.write('[server] ' + d.toString()));
webChild.stderr.on('data', (d) => process.stderr.write('[server] ' + d.toString()));

// ---- Browser ----------------------------------------------------------

function openBrowser() {
  console.log(`\n[cartographer] Opening ${SERVER_URL} in Safari...`);
  try {
    execSync(`open -a Safari "${SERVER_URL}"`);
  } catch (e) {
    // Fall back to the default browser if Safari isn't available.
    try {
      execSync(`open "${SERVER_URL}"`);
      console.log('[cartographer] (used default browser)');
    } catch (e2) {
      console.error('[cartographer] Could not open a browser: ' + e2.message);
    }
  }
}

function waitForServer(attemptsLeft) {
  if (attemptsLeft <= 0) {
    console.error('[cartographer] Timed out waiting for the server to start; is port ' + PORT + ' already in use?');
    return;
  }
  let ok = false;
  try {
    const code = execSync(`curl -s -o /dev/null -w "%{http_code}" ${SERVER_URL}`, { timeout: 3000 }).toString().trim();
    // The dashboard returns 200 (or 401 only if a web password is set).
    ok = code === '200' || code === '401';
  } catch {
    ok = false;
  }
  if (ok) {
    openBrowser();
  } else {
    setTimeout(() => waitForServer(attemptsLeft - 1), 1000);
  }
}

// ---- Agent ------------------------------------------------------------

ensureAgentConfig();

// Launch the compiled agent as a detached background process. It owns the
// macOS menu-bar icon and runs independently of this task.
const agent = spawn(AGENT_BIN, [], {
  detached: true,
  stdio: 'ignore',
});
agent.unref();
console.log('[cartographer] macOS agent launched (look for its icon in the menu bar).');

waitForServer(30);

// Keep the task alive while the server runs. "Stop" in VSCode kills us here,
// which also tears down the server child process.
webChild.on('exit', (code) => {
  console.log(`\n[cartographer] Server exited (code ${code}).`);
  process.exit(code ?? 0);
});
