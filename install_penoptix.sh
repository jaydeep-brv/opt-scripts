#!/bin/bash

# This script installs Penoptix on a Linux machine.
set -euo pipefail

SCRIPT_NAME="install_penoptix.sh"
KEY="${1:-}"
SECRET="${2:-}"
# Detect the real user even when running as root (e.g. SentinelOne session).
# SUDO_USER/LOGNAME can hold a bare uid there, so resolve every candidate through
# getent and accept only a name that actually exists.
resolve_user() {
  local name
  name=$(getent passwd "${1:-}" 2>/dev/null | cut -d: -f1) || true
  case "$name" in ""|root) return 0 ;; esac
  printf '%s' "$name"
}

CONSOLE_USER=$(who 2>/dev/null | awk 'NR==1 {print $1}' || true)
TARGET_USER=""
for candidate in "${TARGET_USER_OVERRIDE:-}" "${SUDO_USER:-}" "${LOGNAME:-}" "$CONSOLE_USER"; do
  [ -n "$candidate" ] || continue
  TARGET_USER=$(resolve_user "$candidate")
  if [ -n "$TARGET_USER" ]; then break; fi
done
# last resort: first regular (uid >= 1000) account on the box
[ -n "$TARGET_USER" ] || TARGET_USER=$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}' || true)

if [ -z "$TARGET_USER" ]; then
  display "Could not detect the target user. Run as that user, or set TARGET_USER_OVERRIDE=<user>."
  exit 1
fi

HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# log function
log() {
  echo "[$SCRIPT_NAME] - $1"
}

display() {
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

# removing panoptix capture only
# rm -rf /home/$TARGET_USER/.local/share/panoptix-capture/

# Create a temporary directory for downloads
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rm -f -- "$0"' EXIT
pushd "$TMP_DIR" >/dev/null

# Download deployment scripts
display "Downloading the deployment scripts"
log "Downloading Panoptix deployment script"
curl -fsSL https://gist.githubusercontent.com/dakbhavesh/4d80fc4242ce4a8f1aa537f5e7039037/raw/fdc8f0b462879dc1f86009c5d471bcbdca474ad7/gistfile1.txt -o deploy-panoptix.sh

# Download Heartbeat deployment script
log "Downloading Heartbeat deployment script"
curl -fsSL https://gist.githubusercontent.com/dakbhavesh/9c732ba3e982e3b9ac94419206fdfde3/raw/2e449a8d86656cfcf27ec0b1a937ea7d72bd32d4/gistfile1.txt -o deploy-heartbeat.sh

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

popd >/dev/null

# Cleanup downloaded scripts
display "Cleaning up downloaded scripts"
rm -rf "$TMP_DIR"

# Verification
display "Verifying the deployment"

log "=================================="
log " [1] Verifying Panoptix config in .bashrc"
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
  echo ""
  log "=================================="
  log " [2] Hook script installed and executable"
  ls -la "$HOME_DIR/.claude/hooks/send-turn.py"
  log "=================================="
  echo ""
  log " [3] Hook is wired into Claude Code's settings.json"
  cat "$HOME_DIR/.claude/settings.json" | python3 -m json.tool | grep -A10 -E "UserPromptSubmit|Stop"
  log "=================================="
  echo ""
  log "=================================="
  log " [4] Test sending a smoke-test prompt to Panoptix"
  echo '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-test","prompt":"hello panoptix","cwd":"/tmp"}' | python3 "$HOME_DIR/.claude/hooks/send-turn.py" && echo "OK"
  log "=================================="
else
  display "Claude configuration directory not found at: $HOME_DIR/.claude"
fi

# Self-removal
rm -f -- "$0"
