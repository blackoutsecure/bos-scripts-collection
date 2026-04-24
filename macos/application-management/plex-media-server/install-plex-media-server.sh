#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-plex-media-server.sh
# Purpose: Downloads and installs the latest version of
#          Plex Media Server on macOS into /Applications.
#
# Modes:
#   apply (default) - install Plex Media Server if not present
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
#
# Idempotency:
#   If $apppath exists and $forceInstall=false, exits 0 with
#   "already installed". Safe to run multiple times.
#
# Deployment:
#   MDM (Intune, Jamf, Kandji, Mosyle, Workspace ONE):
#     Activity is streamed to both the console and $log.
#     Exit codes:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#       2 = drift detected (only emitted by --check)
#
#   Manual:
#     sudo bash ./application-management/plex-media-server/install-plex-media-server.sh
# =============================================================

# Define variables

tempfile="/tmp/plex.zip"
appname="Plex Media Server"
apppath="/Applications/Plex Media Server.app"
log="/var/log/installplex.log"
unzipdir="/tmp/plex_extract"
forceInstall="false"

# Plex public downloads API (category 5 = Plex Media Server)
plexapi="https://plex.tv/api/downloads/5.json"

# Argument parsing
mode="apply"   # apply | check
for arg in "$@"; do
    case "$arg" in
        --check|--status) mode="check" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--check]
  (no args)   Apply: download and install Plex Media Server
  --check     Read-only audit: report whether macOS prerequisites and
              Plex Media Server are present. Exit 0 if compliant, 2 on drift.
EOF
            exit 0
            ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)"; exit 1 ;;
    esac
done

# start logging (console + file)

exec > >(tee -a "$log") 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting install of $appname"
echo "##############################################################"
echo ""

# =============================================================
# --check (read-only status) mode
# Exit 0 = all PASS, 2 = drift detected.
# =============================================================
if [[ "$mode" == "check" ]]; then
    echo "=== --check (read-only) ==="
    pass=0; fail=0
    report() {
        local verdict="$1" name="$2" detail="$3"
        printf "  [%-4s] %-32s %s\n" "$verdict" "$name" "$detail"
        case "$verdict" in PASS) ((pass++));; FAIL) ((fail++));; esac
    }

    # OS must be macOS
    os="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os" == "Darwin" ]]; then
        report PASS "operating system" "Darwin (macOS)"
    else
        report FAIL "operating system" "got '$os', want Darwin"
    fi

    # Required tools
    for cmd in curl unzip; do
        if command -v "$cmd" >/dev/null 2>&1; then
            report PASS "tool $cmd" "$(command -v "$cmd")"
        else
            report FAIL "tool $cmd" "missing"
        fi
    done

    # /Applications must exist and be writable for install
    if [[ -d "/Applications" && -w "/Applications" ]]; then
        report PASS "/Applications writable" "yes"
    else
        report FAIL "/Applications writable" "not writable (run as root)"
    fi

    # Plex downloads API reachability
    if curl --proto '=https' --tlsv1.2 -fsSI -o /dev/null --max-time 10 "$plexapi" 2>/dev/null; then
        report PASS "plex api reachable" "$plexapi"
    else
        report FAIL "plex api reachable" "$plexapi unreachable"
    fi

    # App installed?
    if [[ -d "$apppath" ]]; then
        plist="$apppath/Contents/Info.plist"
        ver="unknown"
        if [[ -f "$plist" ]] && command -v defaults >/dev/null 2>&1; then
            ver="$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
        fi
        report PASS "$appname installed" "$apppath (version $ver)"
    else
        report FAIL "$appname installed" "$apppath not present"
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

if [ "$forceInstall" = "false" ] && [ -d "$apppath" ]; then
   echo "$(date) | $appname is already installed"
   exit 0
fi

echo "$(date) | Fetching latest version from Plex API"
plexjson=$(curl --proto '=https' --tlsv1.2 -fsSL "$plexapi")

if [ -z "$plexjson" ]; then
   echo "$(date) | Failed to fetch Plex downloads API"
   exit 1
fi

weburl=$(echo "$plexjson" | grep -o 'https://downloads\.plex\.tv/plex-media-server-new/[^"]*\/macos\/[^"]*\.zip' | head -1)

if [ -z "$weburl" ]; then
   echo "$(date) | Failed to extract macOS download URL from API response"
   exit 1
fi

version=$(echo "$plexjson" | grep -o '"MacOS":{[^}]*"version":"[^"]*"' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "$(date) | Latest version: $version"
echo "$(date) | Download URL: $weburl"

echo "$(date) | Downloading $appname"
if ! curl --proto '=https' --tlsv1.2 -fsSL -o "$tempfile" "$weburl"; then
   echo "$(date) | Failed to download $appname"
   exit 1
fi

echo "$(date) | Extracting $appname archive"
rm -rf "$unzipdir"
mkdir -p "$unzipdir"
if ! unzip -q "$tempfile" -d "$unzipdir" || [ ! -d "$unzipdir/Plex Media Server.app" ]; then
   echo "$(date) | Failed to extract $appname"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | Copying $appname to Applications"
if ! cp -r "$unzipdir/Plex Media Server.app" "$apppath"; then
   echo "$(date) | Failed to copy $appname to Applications"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | $appname installed"
echo "$(date) | Cleaning up"
rm -rf "$tempfile" "$unzipdir"
exit 0
