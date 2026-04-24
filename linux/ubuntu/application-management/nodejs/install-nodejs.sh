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
#       2 = drift detected (only emitted by --check)
#
#   Manual:
#     sudo bash ./linux/ubuntu/application-management/nodejs/install-nodejs.sh
#
# Modes:
#   apply (default) - reconcile the system to the desired state
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
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

# Argument parsing -- accept --check (and --help) without consuming the
# positional NODE_MAJOR argument.
mode="apply"
positional=()
for arg in "$@"; do
    case "$arg" in
        --check|--status) mode="check" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--check] [NODE_MAJOR]
  NODE_MAJOR  Optional Node.js major version line to install (default: ${default_node_major}).
              May also be set via the NODE_MAJOR environment variable.
  --check     Read-only audit: report whether NodeSource repo, signing
              key, pin, and node/npm of the requested major are present.
              Exit 0 if compliant, 2 on drift.
EOF
            exit 0
            ;;
        --*) echo "ERROR: unknown argument '$arg' (try --help)"; exit 1 ;;
        *)   positional+=("$arg") ;;
    esac
done
node_major="${positional[0]:-${NODE_MAJOR:-$default_node_major}}"

keyring="/etc/apt/keyrings/nodesource.gpg"
listfile="/etc/apt/sources.list.d/nodesource.list"
prefsfile="/etc/apt/preferences.d/nodesource"

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

# =============================================================
# --check (read-only status) mode
# Exit 0 = all PASS, 2 = drift detected.
# =============================================================
if [[ "$mode" == "check" ]]; then
    echo ""
    echo "=== --check (read-only) ==="
    pass=0; fail=0
    report() {
        local verdict="$1" name="$2" detail="$3"
        printf "  [%-4s] %-40s %s\n" "$verdict" "$name" "$detail"
        case "$verdict" in PASS) ((pass++));; FAIL) ((fail++));; esac
    }

    # Distro must be Debian/Ubuntu (apt-based)
    if [[ -r /etc/os-release ]] && grep -Eq '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then
        report PASS "operating system" "Debian/Ubuntu family"
    else
        report FAIL "operating system" "not Debian/Ubuntu (apt required)"
    fi

    # Required prerequisite tools
    for cmd in apt-get dpkg curl gpg dpkg-query; do
        if command -v "$cmd" >/dev/null 2>&1; then
            report PASS "tool $cmd" "$(command -v "$cmd")"
        else
            report FAIL "tool $cmd" "missing"
        fi
    done

    # Prerequisite packages installed by step [1/4]
    for pkg in ca-certificates curl gnupg apt-transport-https; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            report PASS "package $pkg" "installed"
        else
            report FAIL "package $pkg" "missing"
        fi
    done

    # Keyrings directory
    if [[ -d /etc/apt/keyrings ]]; then
        report PASS "/etc/apt/keyrings dir" "present"
    else
        report FAIL "/etc/apt/keyrings dir" "missing"
    fi

    # NodeSource signing key
    if [[ -s "$keyring" ]]; then
        report PASS "nodesource keyring" "$keyring"
    else
        report FAIL "nodesource keyring" "missing $keyring"
    fi

    # NodeSource APT sources list pinned to the requested major
    arch="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
    expected_repo_line="deb [arch=${arch} signed-by=${keyring}] https://deb.nodesource.com/node_${node_major}.x nodistro main"
    if [[ -f "$listfile" ]] && grep -Fxq "$expected_repo_line" "$listfile"; then
        report PASS "nodesource sources list" "pinned to ${node_major}.x"
    else
        report FAIL "nodesource sources list" "missing or wrong major in $listfile"
    fi

    # Stale NodeSource sources for OTHER majors must not be present.
    # Scan every file under /etc/apt/sources.list.d (any name/extension)
    # plus /etc/apt/sources.list, regardless of legacy vs deb822 syntax.
    shopt -s nullglob
    stale_found=""
    scan_files=(/etc/apt/sources.list.d/*)
    [[ -f /etc/apt/sources.list ]] && scan_files+=(/etc/apt/sources.list)
    for f in "${scan_files[@]}"; do
        [[ -f "$f" ]] || continue
        # Each unique node_X.x reference in the file.
        while IFS= read -r m; do
            if [[ -n "$m" && "$m" != "$node_major" ]]; then
                stale_found="$f (major $m)"
                break 2
            fi
        done < <(grep -oE 'deb\.nodesource\.com/node_[0-9]+\.x' "$f" 2>/dev/null \
                   | sed -E 's|.*node_([0-9]+)\.x|\1|' | sort -u)
    done
    shopt -u nullglob
    if [[ -z "$stale_found" ]]; then
        report PASS "no stale nodesource sources" "ok"
    else
        report FAIL "no stale nodesource sources" "$stale_found"
    fi

    # APT pin for nodejs
    if [[ -f "$prefsfile" ]] \
       && grep -q "^Package: nodejs" "$prefsfile" \
       && grep -q "^Pin: version ${node_major}\\.\\*" "$prefsfile"; then
        report PASS "apt pin for nodejs" "$prefsfile pins ${node_major}.x"
    else
        report FAIL "apt pin for nodejs" "missing or wrong in $prefsfile"
    fi

    # nodejs package installed
    if dpkg-query -W -f='${Status}' nodejs 2>/dev/null | grep -q "install ok installed"; then
        report PASS "package nodejs" "installed"
    else
        report FAIL "package nodejs" "missing"
    fi

    # node and npm binaries on PATH
    for cmd in node npm; do
        if command -v "$cmd" >/dev/null 2>&1; then
            report PASS "binary $cmd" "$(command -v "$cmd")"
        else
            report FAIL "binary $cmd" "missing"
        fi
    done

    # Installed major matches requested
    if command -v node >/dev/null 2>&1; then
        nv="$(node --version 2>/dev/null)"
        installed_major="${nv#v}"
        installed_major="${installed_major%%.*}"
        if [[ "$installed_major" == "$node_major" ]]; then
            report PASS "node major matches"  "$nv (major $installed_major)"
        else
            report FAIL "node major matches"  "got '$nv' (major $installed_major), want $node_major"
        fi
    else
        report FAIL "node major matches"      "node not installed"
    fi
    if command -v npm >/dev/null 2>&1; then
        report PASS "npm version readable"    "$(npm --version 2>/dev/null || echo error)"
    else
        report FAIL "npm version readable"    "npm not installed"
    fi

    echo ""
    echo "Summary: $pass PASS / $fail FAIL"
    if [[ "$fail" -gt 0 ]]; then
        echo "DRIFT DETECTED. Re-run without --check to reconcile."
        exit 2
    fi
    echo "All applicable settings already configured."
    exit 0
fi

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

# Remove any stale NodeSource sources for OTHER major versions.
# We scan EVERY file under /etc/apt/sources.list.d (any name, any
# extension -- legacy .list and deb822 .sources) for references to
# deb.nodesource.com/node_X.x and delete the file if X != $node_major.
# Files whose only NodeSource reference matches our desired major are
# kept untouched. Anything we delete is backed up to /var/backups first.
backupdir="/var/backups/install-nodejs-$(date +%Y%m%d-%H%M%S)"
shopt -s nullglob
for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    # Pull every node_X.x reference in the file (URI or deb822 URIs:).
    mapfile -t majors_in_file < <(
        grep -oE 'deb\.nodesource\.com/node_[0-9]+\.x' "$f" 2>/dev/null \
            | sed -E 's|.*node_([0-9]+)\.x|\1|' \
            | sort -u
    )
    [[ "${#majors_in_file[@]}" -eq 0 ]] && continue
    # File mentions nodesource. Keep it only if every reference is our major.
    keep=1
    for m in "${majors_in_file[@]}"; do
        if [[ "$m" != "$node_major" ]]; then
            keep=0
            break
        fi
    done
    if [[ "$keep" -eq 0 ]]; then
        mkdir -p "$backupdir"
        cp -a "$f" "$backupdir/"
        echo "Removing stale NodeSource source: $f (had majors: ${majors_in_file[*]}; backup in $backupdir)"
        rm -f "$f"
    fi
done
shopt -u nullglob

# Also check the master /etc/apt/sources.list -- comment out any
# nodesource entries pointing at a different major. We don't delete
# this file; we patch it in place with a backup.
if [[ -f /etc/apt/sources.list ]] \
   && grep -E '^[[:space:]]*deb[[:space:]].*deb\.nodesource\.com/node_[0-9]+\.x' /etc/apt/sources.list \
        | grep -vq "node_${node_major}\.x"; then
    mkdir -p "$backupdir"
    cp -a /etc/apt/sources.list "$backupdir/"
    sed -i -E "s|^[[:space:]]*deb[[:space:]].*deb\\.nodesource\\.com/node_([0-9]+)\\.x.*|# disabled by install-nodejs.sh (was major \\1): &|" \
        /etc/apt/sources.list
    echo "Disabled stale NodeSource entries in /etc/apt/sources.list (backup in $backupdir)."
fi

if ! grep -Fxq "$repo_line" "$listfile" 2>/dev/null; then
    echo "$repo_line" > "$listfile"
    chmod 0644 "$listfile"
    echo "NodeSource APT repo written to $listfile."
else
    echo "NodeSource APT repo already configured."
fi

# Pin nodejs to the requested major as a defense in depth so any future
# stray nodesource source can't silently upgrade past our line.
cat > "$prefsfile" <<EOF
# Managed by install-nodejs.sh -- pin nodejs to the ${node_major}.x line.
Package: nodejs
Pin: version ${node_major}.*
Pin-Priority: 1001
EOF
chmod 0644 "$prefsfile"

if ! apt-get update; then
    echo "ERROR: apt-get update failed after adding NodeSource repo."
    exit 1
fi

# Pick the highest available nodejs version on the requested major line.
# Going through `apt-cache madison` (instead of relying on apt's candidate
# selection) sidesteps any pin-priority / installed-version edge cases on
# hosts that previously had a higher major installed.
target_version="$(apt-cache madison nodejs 2>/dev/null \
    | awk -v m="$node_major" '{ver=$3; sub(/^[0-9]+:/,"",ver); if (ver ~ "^"m"\\.") {print ver; exit}}')"
if [[ -z "$target_version" ]]; then
    echo "ERROR: No nodejs ${node_major}.x candidate available from APT."
    echo "       Inspect: apt-cache policy nodejs"
    exit 1
fi
echo "Installing nodejs=${target_version}"

# The NodeSource `nodejs` package bundles npm. Do NOT install the
# Ubuntu `npm` package alongside it -- they conflict.
# --allow-downgrades is required when an older host had a higher major.
if ! apt-get install -y --allow-downgrades "nodejs=${target_version}"; then
    echo "ERROR: Failed to install nodejs=${target_version} from NodeSource."
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
    echo "ERROR: Installed Node.js major ($installed_major) does not match requested ($node_major)."
    echo "       Inspect leftover NodeSource sources:"
    echo "         ls /etc/apt/sources.list.d/nodesource*.list"
    echo "         apt-cache policy nodejs"
    exit 1
fi

echo ""
echo "##############################################################"
echo "# $(date) | $appname completed successfully"
echo "##############################################################"
exit 0
