#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-nodejs.sh
# Purpose: Installs Node.js (and the bundled npm) on Ubuntu
#          from the official NodeSource APT repository, then
#          verifies the installation by recording the
#          `node --version` and `npm --version` output.
#
# What the script does:
#   1. Installs prerequisites (ca-certificates, curl, gnupg,
#      apt-transport-https).
#   2. Downloads the NodeSource signing key into a dedicated
#      keyring under /etc/apt/keyrings, using `signed-by=` in
#      the APT source line (apt-key is deprecated and is not
#      used).
#   3. Writes /etc/apt/sources.list.d/nodesource.list pinned
#      to the requested major version (default: the current
#      LTS line) for the host's CPU architecture.
#   4. Runs `apt-get update` and installs the `nodejs` package
#      (npm is bundled with the NodeSource nodejs package, so
#      a separate `npm` package is not installed and would
#      conflict if it were).
#   5. Verifies the install by running `node --version` and
#      `npm --version` and logging the results.
#
# Why not `curl ... | sudo -E bash -`?
#   The legacy NodeSource one-liner pipes a remote shell script
#   straight into root. This script performs the same setup
#   steps explicitly:
#     - pinned signing key in /etc/apt/keyrings
#     - signed-by APT source entry
#     - non-interactive apt-get install
#   This is auditable, idempotent, and safe to re-run from
#   management tooling.
#
# Detection / Idempotency:
#   - The keyring and sources file are only (re)written when
#     missing or when the requested NODE_MAJOR changes.
#   - APT installs are no-ops when the package is current.
#   - Re-running the script with the same NODE_MAJOR is a
#     no-op apart from `apt-get update`.
#   - Re-running the script with a different NODE_MAJOR
#     repoints the NodeSource repo and upgrades/downgrades
#     the `nodejs` package accordingly.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt):
#     Run as root. Optionally pin a Node.js major version via
#     the NODE_MAJOR environment variable or the first
#     positional argument:
#       sudo ./install-nodejs.sh           # default LTS (22)
#       sudo NODE_MAJOR=20 ./install-nodejs.sh
#       sudo ./install-nodejs.sh 22
#     All activity is logged to $log. Exit codes:
#       0 = success (installed or already installed)
#       1 = failure (review log for details)
#
#   Manual:
#     sudo bash ./linux/ubuntu/application-management/nodejs/install-nodejs.sh
#
# Variables:
#   appname    - Display name used in log messages
#   log           - Full path of the log file written by this script
#   node_major    - NodeSource major version line to install
#                   (e.g. 18, 20, 22). Defaults to the current LTS.
#   keyring       - Path to the NodeSource APT signing keyring
#   listfile      - Path to the NodeSource APT sources list file
# =============================================================

# Define variables

appname="Node.js Installation"
log="/var/log/install-nodejs.log"

# Current Node.js LTS major line. Override with NODE_MAJOR or arg 1.
default_node_major="22"
node_major="${1:-${NODE_MAJOR:-$default_node_major}}"

keyring="/etc/apt/keyrings/nodesource.gpg"
listfile="/etc/apt/sources.list.d/nodesource.list"

# start logging
exec > >(tee -a "$log") 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname"
echo "##############################################################"

# Require root for apt and /etc writes.
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# Validate NODE_MAJOR is a positive integer.
if ! [[ "$node_major" =~ ^[0-9]+$ ]]; then
    echo "ERROR: NODE_MAJOR must be a positive integer (got: '$node_major')."
    exit 1
fi

echo "Target Node.js major : $node_major"
echo "Keyring              : $keyring"
echo "Sources list         : $listfile"

# -------------------------------
# 1. Install prerequisites
# -------------------------------
echo "[1/4] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update; then
    echo "ERROR: apt-get update failed."
    exit 1
fi
if ! apt-get install -y ca-certificates curl gnupg apt-transport-https; then
    echo "ERROR: Failed to install prerequisite packages."
    exit 1
fi
echo "Prerequisites installed."

# -------------------------------
# 2. Install NodeSource signing key
# -------------------------------
echo "[2/4] Configuring NodeSource signing key..."
install -m 0755 -d /etc/apt/keyrings

if [[ ! -s "$keyring" ]]; then
    if ! curl --proto '=https' --tlsv1.2 -fsSL \
            "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
            | gpg --dearmor -o "$keyring"; then
        echo "ERROR: Failed to fetch NodeSource GPG key."
        rm -f "$keyring"
        exit 1
    fi
    chmod a+r "$keyring"
    echo "NodeSource GPG key installed at $keyring."
else
    echo "NodeSource GPG key already present."
fi

# -------------------------------
# 3. Configure NodeSource APT repo and install nodejs
# -------------------------------
echo "[3/4] Configuring NodeSource APT repository for Node.js $node_major..."
arch="$(dpkg --print-architecture)"
repo_line="deb [arch=${arch} signed-by=${keyring}] https://deb.nodesource.com/node_${node_major}.x nodistro main"

if ! grep -Fxq "$repo_line" "$listfile" 2>/dev/null; then
    echo "$repo_line" > "$listfile"
    echo "NodeSource APT repo written to $listfile."
else
    echo "NodeSource APT repo already configured."
fi

if ! apt-get update; then
    echo "ERROR: apt-get update failed after adding NodeSource repo."
    exit 1
fi

# The NodeSource `nodejs` package bundles npm. Do NOT install the
# Ubuntu `npm` package alongside it -- they conflict.
if ! apt-get install -y nodejs; then
    echo "ERROR: Failed to install nodejs from NodeSource."
    exit 1
fi
echo "Node.js package installed."

# -------------------------------
# 4. Verify install
# -------------------------------
echo "[4/4] Verifying installation..."

if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: 'node' binary not found on PATH after install."
    exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: 'npm' binary not found on PATH after install."
    exit 1
fi

node_version="$(node --version 2>&1)" || {
    echo "ERROR: 'node --version' failed: $node_version"
    exit 1
}
npm_version="$(npm --version 2>&1)" || {
    echo "ERROR: 'npm --version' failed: $npm_version"
    exit 1
}

echo "node --version : $node_version"
echo "npm  --version : $npm_version"

# Confirm the installed major matches what was requested.
installed_major="${node_version#v}"
installed_major="${installed_major%%.*}"
if [[ "$installed_major" != "$node_major" ]]; then
    echo "WARNING: Installed Node.js major ($installed_major) does not match requested ($node_major)."
fi

echo ""
echo "##############################################################"
echo "# $(date) | $appname completed successfully"
echo "##############################################################"
exit 0
