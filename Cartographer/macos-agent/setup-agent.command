#!/bin/bash
#
# setup-agent.command — double-clickable setup helper for the Cartographer agent.
#
# What it does, in order:
#   1. Finds the CartographerAgent binary NEXT TO this script (no building —
#      you copy the built executable and this file together).
#   2. "Unlocks" it: chmod +x and removes the macOS quarantine attribute
#      (the thing that makes a copied/airdropped binary refuse to launch).
#   3. Asks the questions a first run needs (machine id, harness, repo path,
#      server URL, API key) and writes ~/.cartographer/config.json BEFORE
#      the agent is ever started — so you edit nothing by hand afterwards.
#
# To run it from Finder: double-click this file. Finder opens it in
# Terminal.app with execution permission already granted on this copy
# (Finder-compatibility requires the .command extension, which this has).
# If you ever get "permission denied" running it manually, do:
#     chmod +x setup-agent.command

set -u                         # error out on unset variables
ipwd="$(cd "$(dirname "$0")" && pwd)"   # works even when double-clicked

BLUE="\033[1;34m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; OFF="\033[0m"
say()  { printf "$BLUE%s$OFF\n" "$1"; }
ok()   { printf "$GREEN%s$OFF\n" "$1"; }
warn() { printf "$YELLOW%s$OFF\n" "$1"; }

# ---------------------------------------------------------------------------
# Defaults shown inside the prompts. Press Enter to accept the default shown.
# ---------------------------------------------------------------------------
def_server="http://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):5080"
def_repo="$HOME/repos/Pathfinder"
def_harness="new-harness-$(jot -r 1 1000 9999 2>/dev/null || echo $RANDOM)"

# ---------------------------------------------------------------------------
# 1. Locate the agent binary next to this script. No building here.
# ---------------------------------------------------------------------------
say "==> Looking for the agent binary…"
BIN="$ipwd/CartographerAgent"
if [ ! -f "$BIN" ]; then
    echo "CartographerAgent executable not found next to this script:"
    echo "    $ipwd"
    echo "Copy the built executable into that folder, next to this file,"
    echo "then run this again. Aborting."
    exit 1
fi
ok "    Using binary: $BIN"

# ---------------------------------------------------------------------------
# 2. Unlock: chmod +x and strip quarantine
# ---------------------------------------------------------------------------
say "==> Unlocking the executable…"
chmod +x "$BIN" 2>/dev/null
# xattr -d errors harmlessly (suppressed) when no quarantine attribute exists.
xattr -d com.apple.quarantine "$BIN" 2>/dev/null
ok "    Executable is now runnable without Gatekeeper warnings."

# ---------------------------------------------------------------------------
# 3. First-run questions and config scaffold
# ---------------------------------------------------------------------------
CONFIG_DIR="$HOME/.cartographer"
CONFIG_FILE="$CONFIG_DIR/config.json"

# Re-running on an already-configured machine must NOT exit early — the
# auto-run install below may still need doing. So a decline only skips the
# config rewrite; everything after this step runs either way.
write_config=1
if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
    warn "==> A config already exists at $CONFIG_FILE"
    read -r -p "    Overwrite it with fresh values? [y/N] " ans
    case "$ans" in y|Y) true;; *) write_config=0; warn "    Keeping the existing config and continuing…";; esac
fi

if [ "$write_config" = 1 ]; then
echo ""
say "==> Agent setup: press ENTER to accept the [default] shown."
echo ""

# -- Machine id (must be unique per machine) ---------------------------------
default_machineid="new-machine-$(jot -r 1 1000 9999 2>/dev/null || echo $RANDOM)"
read -r -p "machineId            [${default_machineid}]: " machineid
machineid="${machineid:-$default_machineid}"

read -r -p "harness              [${def_harness}]: " harness
harness="${harness:-$def_harness}"

read -r -p "repositoryPath       [${def_repo}]: " repo
repo="${repo:-$def_repo}"

read -r -p "serverUrl            [${def_server}]: " server
server="${server:-$def_server}"

read -r -p "apiKey               []: " apikey

# ---------------------------------------------------------------------------
# 4. Write config.json
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" || { echo "Could not create $CONFIG_DIR"; exit 1; }
cat > "$CONFIG_FILE" <<EOF
{
  "machineId": "$machineid",
  "harness": "$harness",
  "repositoryPath": "$repo",
  "serverUrl": "$server",
  "apiKey": "$apikey"
}
EOF
ok "==> Wrote $CONFIG_FILE"
else
    ok "==> Keeping existing $CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# 5. Auto-run at login: install a LaunchAgent (if not already installed)
# ---------------------------------------------------------------------------
# macOS auto-start works via a LaunchAgent: a small plist placed in
# ~/Library/LaunchAgents that launchd reads when you log in. launchd starts
# the agent directly — no Terminal window ever opens; output goes to a log.
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_DIR/com.cartographer.agent.plist"
LOG_FILE="$CONFIG_DIR/agent.log"

install_launchagent() {
    mkdir -p "$LAUNCH_DIR" "$CONFIG_DIR" || { echo "Could not create $LAUNCH_DIR"; return 1; }
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cartographer.agent</string>

    <!-- The absolute binary path is baked in at setup time. -->
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>

    <!-- Start at login. -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Keep it running across the whole session (relaunch on crash). -->
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF
    # Register it with launchd and start it immediately (StartAtLoad-ish).
    launchctl bootout "gui/$(id -u)/com.cartographer.agent" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "launchctl bootstrap failed"; return 1; }
    ok "==> LaunchAgent installed: $PLIST"
    ok "==> Agent started in the background (log: $LOG_FILE)"
}

echo ""
auto_running=0
if [ -f "$PLIST" ]; then
    warn "==> Auto-run is already installed: $PLIST"
    warn "    (leaving it alone; to re-install, delete that file first)"
    auto_running=1
else
    read -r -p "==> Install auto-run at login (LaunchAgent, runs in background, no Terminal)? [Y/n] " ans
    case "$ans" in
    n|N) warn "    Skipping auto-run. Start the agent manually any time." ;;
    *) if install_launchagent; then auto_running=1
       else warn "    Auto-run install failed; start the agent manually instead."; fi ;;
    esac
fi

# ---------------------------------------------------------------------------
# 6. Offer to start the agent right away (foreground) — only when auto-run
#    was not set up, since in that case launchd is already running it.
# ---------------------------------------------------------------------------
if [ "$auto_running" = 1 ]; then
    echo ""
    ok "==> The agent is already running in the background (log: $LOG_FILE)."
    echo "Done. This window can be closed."
    exit 0
fi

echo ""
read -r -p "==> Start the agent in this window now? [Y/n] " ans
case "$ans" in n|N)
    echo "Done. This window can be closed."
    exit 0;;
esac

echo "Starting agent — press Ctrl+C to stop it."
echo ""
"$BIN"
