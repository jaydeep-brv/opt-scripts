#!/bin/bash

# This script installs Penoptix on a Linux machine.
set -euo pipefail

SCRIPT_NAME="install_penoptix.sh"
KEY="${1:-}"
SECRET="${2:-}"
# Detect real user even when running as root (e.g. SentinelOne session)
if [ -n "${SUDO_USER:-}" ]; then
    TARGET_USER="$SUDO_USER"
elif [ -n "${LOGNAME:-}" ] && [ "$LOGNAME" != "root" ]; then
    TARGET_USER="$LOGNAME"
else
    # fallback: detect the owner of the current TTY/session
    TARGET_USER=$(who | awk 'NR==1 {print $1}')
fi

HOME_DIR=$(eval echo "~$TARGET_USER")

# log function
log () {
    echo "[$SCRIPT_NAME] - $1"
}

display(){
    # print message with new line
    echo ""
    echo "========================================================" 
    echo "$1"
    echo "========================================================" 
    echo ""
}

# Check if the arguments are provided
if [ -z "$KEY" ] || [ -z "$SECRET" ]; then
    display "API Key and Secret are required."
    echo "Usage: ./install_penoptix.sh <key> <secret>"
    exit 1
fi

display "Target user: $TARGET_USER | Home directory: $HOME_DIR"
# Create a temporary directory for downloads
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rm -f -- "$0"' EXIT
pushd "$TMP_DIR" > /dev/null

# Download deployment scripts
display "Downloading the deployment scripts"
log "Downloading Panoptix deployment script"
curl -fsSL https://gist.githubusercontent.com/dakbhavesh/4d80fc4242ce4a8f1aa537f5e7039037/raw/c44513889dc43831e8ac2a0d4db909f502bf05b0/gistfile1.txt -o deploy-panoptix.sh

# Download Heartbeat deployment script
log "Downloading Heartbeat deployment script"
curl -fsSL https://gist.githubusercontent.com/dakbhavesh/9c732ba3e982e3b9ac94419206fdfde3/raw/9003700894fedb143c7332d455b8a6aadf222995/gistfile1.txt -o deploy-heartbeat.sh

# Make scripts executable
log "Making the scripts executable"
chmod +x deploy-panoptix.sh
chmod +x deploy-heartbeat.sh

# Deploy Panoptix
display "Deploying Panoptix"

log "deploying Panoptix"
./deploy-panoptix.sh "$KEY" "$SECRET"
log "deployment completed"


# Deploy Heartbeat
log "deploying Heartbeat"
./deploy-heartbeat.sh "$KEY" "$SECRET"
log "deployment completed"

popd > /dev/null

# Cleanup downloaded scripts
display "Cleaning up downloaded scripts"
rm -rf "$TMP_DIR"

# Verification
display "Verifying the deployment"

log "=================================="
log "Verifying Panoptix config in .bashrc"
BASHRC="$HOME_DIR/.bashrc"
if [ -f "$BASHRC" ]; then
    grep -q "# Panoptix - Claude Code Audit" "$BASHRC" && echo "Marker start: OK" || echo "Marker start: MISSING"
    grep -q "export PANOPTIX_KEY_ID=$KEY" "$BASHRC" && echo "KEY_ID: OK" || echo "KEY_ID: MISSING or MISMATCH"
    grep -q "export PANOPTIX_KEY_SECRET=$SECRET" "$BASHRC" && echo "SECRET: OK" || echo "SECRET: MISSING or MISMATCH"
    grep -q "export PANOPTIX_URL=https://panoptix-capture.unleashteams.com/api/hook" "$BASHRC" && echo "URL: OK" || echo "URL: MISSING or MISMATCH"
    grep -q "# End Panoptix config" "$BASHRC" && echo "Marker end: OK" || echo "Marker end: MISSING"
else
    log ".bashrc not found at $BASHRC"
fi
log "=================================="

if [ -d "$HOME_DIR/.claude" ]; then
    log "=================================="
    log "Hook script installed and executable"
    ls -la "$HOME_DIR/.claude/hooks/send-turn.py"
    log "=================================="

    log "=================================="
    log "Hook is wired into Claude Code's settings.json"
    cat "$HOME_DIR/.claude/settings.json"
    log "=================================="

    log "=================================="
    echo '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-test","prompt":"hello panoptix","cwd":"/tmp"}' | python3 "$HOME_DIR/.claude/hooks/send-turn.py" && echo "OK"
    log "=================================="
else
    display "Claude configuration directory not found at: $HOME_DIR/.claude"
fi 

# Self-removal
rm -f -- "$0"
