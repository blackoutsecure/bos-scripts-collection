#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-homebrew.sh
# Purpose: Installs Homebrew on macOS using the official
#          install script. Apple Silicon installs to
#          /opt/homebrew; Intel installs to /usr/local.
#
# Modes:
#   apply (default) - install Homebrew if not already present
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
#
# Idempotency:
#   If `brew` is already present and $forceInstall=false, exits
#   0 with "already installed". Safe to run multiple times.
#
# Deployment:
#   MDM (Intune, Jamf, Kandji, Mosyle, Workspace ONE):
#     Activity is streamed to both the console and $log.
#     The Homebrew installer is invoked with NONINTERACTIVE=1.
#     Exit codes:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#       2 = drift detected (only emitted by --check)
#
#   Manual:
#     sudo bash ./application-management/homebrew/install-homebrew.sh
# =============================================================

# Define variables

appname="Homebrew"
log="/var/log/installhomebrew.log"
forceInstall="false"
brewurl="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# Argument parsing
mode="apply"   # apply | check
for arg in "$@"; do
    case "$arg" in
        --check|--status) mode="check" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--check]
  (no args)   Apply: install Homebrew if not already present
  --check     Read-only audit: report whether macOS prerequisites and
              Homebrew itself are present. Exit 0 if compliant, 2 on drift.
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

    # Architecture and expected brew prefix
    arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$arch" in
        arm64)  expected_prefix="/opt/homebrew" ;;
        x86_64) expected_prefix="/usr/local" ;;
        *)      expected_prefix="" ;;
    esac
    if [[ -n "$expected_prefix" ]]; then
        report PASS "cpu architecture" "$arch (expects $expected_prefix)"
    else
        report FAIL "cpu architecture" "unsupported '$arch'"
    fi

    # Required tools for the installer
    for cmd in curl bash; do
        if command -v "$cmd" >/dev/null 2>&1; then
            report PASS "tool $cmd" "$(command -v "$cmd")"
        else
            report FAIL "tool $cmd" "missing"
        fi
    done

    # Apple Command Line Tools (Homebrew installer requires them)
    if xcode-select -p >/dev/null 2>&1; then
        report PASS "xcode command line tools" "$(xcode-select -p)"
    else
        report FAIL "xcode command line tools" "not installed (run: xcode-select --install)"
    fi

    # Network reachability to Homebrew installer URL
    if curl --proto '=https' --tlsv1.2 -fsSI -o /dev/null --max-time 10 "$brewurl" 2>/dev/null; then
        report PASS "installer reachable" "$brewurl"
    else
        report FAIL "installer reachable" "$brewurl unreachable"
    fi

    # Brew installed?
    brewbin=""
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        brewbin="/opt/homebrew/bin/brew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        brewbin="/usr/local/bin/brew"
    fi
    if [[ -n "$brewbin" ]]; then
        bv="$("$brewbin" --version 2>/dev/null | head -1)"
        report PASS "$appname installed" "${brewbin} (${bv:-unknown})"
    else
        report FAIL "$appname installed" "brew binary not found"
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

if [ "$forceInstall" = "false" ]; then
   if [ -x "/opt/homebrew/bin/brew" ] || [ -x "/usr/local/bin/brew" ]; then
      echo "$(date) | $appname is already installed"
      exit 0
   fi
fi

echo "$(date) | Downloading and running the official $appname installer"
installer=$(curl --proto '=https' --tlsv1.2 -fsSL "$brewurl")
if [ -z "$installer" ]; then
   echo "$(date) | Failed to fetch $appname installer"
   exit 1
fi
if ! NONINTERACTIVE=1 /bin/bash -c "$installer"; then
   echo "$(date) | Failed to install $appname"
   exit 1
fi

if [ -x "/opt/homebrew/bin/brew" ]; then
   brewpath="/opt/homebrew/bin/brew"
elif [ -x "/usr/local/bin/brew" ]; then
   brewpath="/usr/local/bin/brew"
else
   echo "$(date) | $appname installer completed but brew binary not found"
   exit 1
fi

echo "$(date) | $appname installed"
echo "$(date) | Brew path: $brewpath"
echo "$(date) | Brew version: $("$brewpath" --version | head -1)"
exit 0
