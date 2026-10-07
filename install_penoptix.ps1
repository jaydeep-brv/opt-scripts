# Penoptix Windows Installation Script
# This script installs Penoptix on a Windows machine.
# Requires: PowerShell 5.1+ (or PowerShell 7+)
# Usage: .\install_penoptix.ps1 <key> <secret>
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "API Key")]
    [string]$Key,

    [Parameter(Mandatory = $true, Position = 1, HelpMessage = "API Secret")]
    [string]$Secret
)

$ErrorActionPreference = "Stop"
# Enable TLS 1.2 for Invoke-WebRequest on older Windows versions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptName = "install_penoptix.ps1"
$TargetUser = $env:USERNAME
$HomeDir = $env:USERPROFILE

# ---------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    Write-Host "[$ScriptName] - $Message"
}

function Write-Display {
    param([string]$Message)
    Write-Host ""
    Write-Host "========================================================"
    Write-Host $Message
    Write-Host "========================================================"
    Write-Host ""
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

Write-Display "Target user: $TargetUser | Home directory: $HomeDir"

# Create a temporary directory for downloads
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
Write-Log "Created temp directory: $TmpDir"

try {
    Push-Location $TmpDir

    # -----------------------------------------------------------
    # Download deployment scripts
    # -----------------------------------------------------------
    Write-Display "Downloading the deployment scripts"

    Write-Log "Downloading Panoptix deployment script"
    Invoke-WebRequest `
        -Uri "https://gist.githubusercontent.com/dakbhavesh/4d80fc4242ce4a8f1aa537f5e7039037/raw/2d77c20c29d2f87014db5a55768992b4036b7dd7/gistfile1.txt" `
        -OutFile "deploy-panoptix.sh"

    Write-Log "Downloading Heartbeat deployment script"
    Invoke-WebRequest `
        -Uri "https://gist.githubusercontent.com/dakbhavesh/9c732ba3e982e3b9ac94419206fdfde3/raw/2ae4cf35b9bb9ac7583a657c9e45dc94f5a7810f/gistfile1.txt" `
        -OutFile "deploy-heartbeat.sh"

    # -----------------------------------------------------------
    # Deploy Panoptix
    # -----------------------------------------------------------
    Write-Display "Deploying Panoptix"

    Write-Log "Deploying Panoptix"
    # Note: The deployment scripts are bash scripts. On Windows they require
    # Git Bash, WSL, or MSYS2 to execute. Adjust the runner as needed.
    bash "./deploy-panoptix.sh" "$Key" "$Secret"
    Write-Log "Panoptix deployment completed"

    # Deploy Heartbeat
    Write-Log "Deploying Heartbeat"
    bash "./deploy-heartbeat.sh" "$Key" "$Secret"
    Write-Log "Heartbeat deployment completed"

    Pop-Location
}
finally {
    # -----------------------------------------------------------
    # Cleanup
    # -----------------------------------------------------------
    Write-Display "Cleaning up downloaded scripts"
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# Verification
# ---------------------------------------------------------------
Write-Display "Verifying the deployment"

# --- Check user-level environment variables (setx-style) ---
Write-Log "=================================="
Write-Log "Verifying Panoptix environment variables (user-level)"

$panoptixKeyId = [System.Environment]::GetEnvironmentVariable("PANOPTIX_KEY_ID", "User")
if ($panoptixKeyId) {
    Write-Host "KEY_ID: OK"
}
else {
    Write-Host "KEY_ID: MISSING"
}

$panoptixSecret = [System.Environment]::GetEnvironmentVariable("PANOPTIX_KEY_SECRET", "User")
if ($panoptixSecret) {
    Write-Host "SECRET: OK"
}
else {
    Write-Host "SECRET: MISSING"
}

$panoptixUrl = [System.Environment]::GetEnvironmentVariable("PANOPTIX_URL", "User")
if ($panoptixUrl) {
    Write-Host "URL: OK"
}
else {
    Write-Host "URL: MISSING"
}

# Also check process-level (current session) env vars as fallback
if (-not $panoptixKeyId) {
    $procVal = $env:PANOPTIX_KEY_ID
    if ($procVal) { Write-Host "KEY_ID: OK (process-level)" }
}
if (-not $panoptixSecret) {
    $procVal = $env:PANOPTIX_KEY_SECRET
    if ($procVal) { Write-Host "SECRET: OK (process-level)" }
}
if (-not $panoptixUrl) {
    $procVal = $env:PANOPTIX_URL
    if ($procVal) { Write-Host "URL: OK (process-level)" }
}

Write-Log "=================================="

# --- Check Claude Code configuration ---
$ClaudeDir = Join-Path $HomeDir ".claude"

if (Test-Path $ClaudeDir) {
    # Hook script
    Write-Log "=================================="
    Write-Log "Hook script installed and executable"
    $hookPath = Join-Path $ClaudeDir "hooks\send-turn.py"
    if (Test-Path $hookPath) {
        Get-Item $hookPath | Format-List Mode, LastWriteTime, Length, FullName
    }
    else {
        Write-Host "Hook script NOT FOUND at: $hookPath"
    }
    Write-Log "=================================="

    # settings.json
    Write-Log "=================================="
    Write-Log "Hook is wired into Claude Code's settings.json"
    $settingsPath = Join-Path $ClaudeDir "settings.json"
    if (Test-Path $settingsPath) {
        Get-Content $settingsPath
    }
    else {
        Write-Host "settings.json NOT FOUND at: $settingsPath"
    }
    Write-Log "=================================="

    # Smoke test the hook
    Write-Log "=================================="
    if (Test-Path $hookPath) {
        $testPayload = '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-test","prompt":"hello panoptix","cwd":"C:\\temp"}'
        $testPayload | python $hookPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Smoke test: OK"
        }
        else {
            Write-Host "Smoke test: FAILED (exit code $LASTEXITCODE)"
        }
    }
    Write-Log "=================================="
}
else {
    Write-Display "Claude configuration directory not found at: $ClaudeDir"
}

# ---------------------------------------------------------------
# Self-removal
# ---------------------------------------------------------------
# PowerShell equivalent of 'rm -f -- "$0"'
# Run through cmd to avoid file-lock issues
$selfPath = $PSCommandPath
if ($selfPath) {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 2 /nobreak >nul & del /f /q `"$selfPath`"" -WindowStyle Hidden -NoNewWindow
}
