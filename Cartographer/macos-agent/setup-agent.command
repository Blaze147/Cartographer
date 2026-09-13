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

if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
    warn "==> A config already exists at $CONFIG_FILE"
    read -r -p "    Overwrite it with fresh values? [y/N] " ans
    case "$ans" in y|Y) true;; *) echo "    Keeping the existing file."; exit 0;; esac
fi

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

# ---------------------------------------------------------------------------
# 5. Offer to start the agent right away
# ---------------------------------------------------------------------------
echo ""
read -r -p "==> Start the agent now? [Y/n] " ans
case "$ans" in n|N)
    echo "Done. Run this file again, or '$BIN' directly, later."
    exit 0;;
esac

echo "Starting agent — press Ctrl+C to stop it."
echo ""
"$BIN"
