#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  configure-sh-to-bash.sh
# Purpose: Repoints /bin/sh from dash to bash on Ubuntu/Debian
#          systems by reconfiguring the `dash` package
#          non-interactively (equivalent to answering "No" to
#          the `dpkg-reconfigure dash` prompt).
#
# Some workloads, vendor install scripts, and legacy shell
# code rely on bash-isms while still invoking `/bin/sh`. On
# Ubuntu, /bin/sh defaults to dash for boot-time speed and
# POSIX strictness, which breaks those scripts. This script
# flips /bin/sh -> bash and verifies the change.
#
# Detection / Idempotency:
#   If /bin/sh already resolves to bash the dpkg-reconfigure
#   step is skipped. Verification still runs every time. Safe
#   to run multiple times.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt,
#            or any tool that runs shell scripts as root):
#     Deploy as a one-shot configuration script. All activity
#     is logged to $log AND streamed to the console. Exit codes:
#       0 = success (configured or already configured)
#       1 = failure (review log for details)
#     No reboot required. Already-running shells keep their
#     existing /bin/sh; new shells pick up bash immediately.
#
#   Manual:
#     sudo bash ./linux/ubuntu/system-configuration/sh-to-bash/configure-sh-to-bash.sh
#
# Verification:
#     ls -l /bin/sh                       # -> /bin/sh -> bash
#     readlink /bin/sh                    # bash
#     sh -c 'echo $BASH_VERSION'          # non-empty
#     sudo debconf-show dash | grep dash/sh
#         # * dash/sh: false   => /bin/sh is bash (correct)
#
# Variables:
#   appname - Display name used in log messages
#   log        - Full path of the log file written by this script
# =============================================================

# Define variables

appname="Configure /bin/sh -> bash"
log="/var/log/configure-sh-to-bash.log"

# Argument parsing
mode="apply"
for arg in "$@"; do
    case "$arg" in
        --check|--status) mode="check" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--check]
  (no args)   Apply: reconfigure dash so /bin/sh -> bash
  --check     Read-only audit: report whether /bin/sh is bash and the
              debconf selection matches. Exit 0 if compliant, 2 on drift.
EOF
            exit 0
            ;;
        *) echo "ERROR: unknown argument '$arg' (try --help)"; exit 1 ;;
    esac
done

# start logging
# Tee all stdout/stderr to both the log file (appended) and the console
# so output is visible during interactive runs and captured for managed
# deployments / post-mortem review.

exec > >(tee -a "$log") 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname"
echo "##############################################################"

# Require root (no interactive sudo prompts in managed deployment)
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# -------------------------------
# --check (read-only audit)
# -------------------------------
if [[ "$mode" == "check" ]]; then
    echo ""
    echo "=== --check (read-only) ==="
    pass=0; fail=0
    report() {
        local verdict="$1" name="$2" detail="$3"
        printf "  [%s] %-32s %s\n" "$verdict" "$name" "$detail"
        case "$verdict" in PASS) ((pass++));; FAIL) ((fail++));; esac
    }

    target="$(readlink -f /bin/sh 2>/dev/null || true)"
    if [[ "$(basename "${target:-}")" == "bash" ]]; then
        report PASS "/bin/sh symlink target" "$target"
    else
        report FAIL "/bin/sh symlink target" "${target:-missing}"
    fi

    bv="$(sh -c 'echo $BASH_VERSION' 2>/dev/null || true)"
    if [[ -n "$bv" ]]; then
        report PASS "sh -c \$BASH_VERSION"   "$bv"
    else
        report FAIL "sh -c \$BASH_VERSION"   "empty (sh is not bash)"
    fi

    if command -v debconf-show >/dev/null 2>&1; then
        dline="$(debconf-show dash 2>/dev/null | grep 'dash/sh' || true)"
        if [[ "$dline" == *"false"* ]]; then
            report PASS "debconf dash/sh"        "false (bash)"
        elif [[ -z "$dline" ]]; then
            report FAIL "debconf dash/sh"        "not set"
        else
            report FAIL "debconf dash/sh"        "$dline"
        fi
    else
        report FAIL "debconf-show available"     "missing"
    fi

    echo ""
    echo "Summary: $pass PASS / $fail FAIL"
    if [[ "$fail" -gt 0 ]]; then
        echo "DRIFT DETECTED. Re-run without --check to reconcile."
        exit 2
    fi
    echo "/bin/sh already points to bash."
    exit 0
fi

# Verify required tooling is present
for cmd in readlink dpkg-reconfigure debconf-set-selections; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found. This script targets Debian/Ubuntu."
        exit 1
    fi
done

# Verify dash is installed (required to reconfigure it)
if ! dpkg -s dash >/dev/null 2>&1; then
    echo "ERROR: 'dash' package is not installed. Nothing to reconfigure."
    exit 1
fi

# Verify bash is installed (we're switching /bin/sh to it)
if [[ ! -x /bin/bash ]]; then
    echo "ERROR: /bin/bash is missing or not executable. Cannot switch /bin/sh to bash."
    exit 1
fi

# -------------------------------
# 1. Detect current /bin/sh target
# -------------------------------
echo "[1/3] Inspecting current /bin/sh..."
current_target="$(readlink -f /bin/sh 2>/dev/null || true)"
if [[ -z "$current_target" ]]; then
    echo "ERROR: /bin/sh does not exist or is not a symlink we can resolve."
    exit 1
fi
echo "Current /bin/sh -> $current_target"

# -------------------------------
# 2. Reconfigure dash if needed (idempotent)
# -------------------------------
echo "[2/3] Ensuring /bin/sh points to bash..."
if [[ "$(basename "$current_target")" == "bash" ]]; then
    echo "/bin/sh already resolves to bash. Skipping dpkg-reconfigure."
else
    # Pre-seed debconf so dpkg-reconfigure runs unattended.
    # dash/sh = false  => "No, do not install dash as /bin/sh"
    # Mark the question as 'seen' so the noninteractive frontend will
    # actually act on the seeded answer instead of skipping it.
    if ! printf 'dash dash/sh boolean false\ndash dash/sh seen true\n' \
            | debconf-set-selections; then
        echo "ERROR: debconf-set-selections failed."
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg-reconfigure -f noninteractive dash; then
        echo "ERROR: dpkg-reconfigure dash failed."
        exit 1
    fi
    echo "dpkg-reconfigure dash completed."

    # Some Ubuntu releases honor the debconf answer but still leave the
    # /bin/sh symlink pointing at dash when reconfigured noninteractively.
    # If that happened, repoint the symlink directly so the system state
    # matches the debconf selection.
    post_target="$(readlink -f /bin/sh 2>/dev/null || true)"
    if [[ "$(basename "${post_target:-}")" != "bash" ]]; then
        echo "WARNING: /bin/sh still points to '$post_target' after reconfigure."
        echo "         Repointing /bin/sh -> bash directly."
        if ! ln -sf bash /bin/sh; then
            echo "ERROR: Failed to relink /bin/sh -> bash."
            exit 1
        fi
        echo "/bin/sh symlink updated."
    fi
fi

# -------------------------------
# 3. Verification
# -------------------------------
echo "[3/3] Verification:"

new_target="$(readlink -f /bin/sh 2>/dev/null || true)"
echo -n "  ls -l /bin/sh           : "
ls -l /bin/sh

echo "  readlink /bin/sh        : $(readlink /bin/sh 2>/dev/null || echo '(none)')"

bash_version_check="$(sh -c 'echo $BASH_VERSION' 2>/dev/null || true)"
if [[ -n "$bash_version_check" ]]; then
    echo "  sh -c 'echo \$BASH_VERSION': $bash_version_check"
else
    echo "  sh -c 'echo \$BASH_VERSION': (empty -- /bin/sh is NOT bash)"
fi

debconf_line="$(debconf-show dash 2>/dev/null | grep 'dash/sh' || true)"
echo "  debconf dash/sh         : ${debconf_line:-(not set)}"

if [[ "$(basename "${new_target:-}")" != "bash" || -z "$bash_version_check" ]]; then
    echo "ERROR: /bin/sh is not bash after reconfigure. Review the output above."
    exit 1
fi

echo ""
echo "##############################################################"
echo "# $(date) | $appname complete. /bin/sh now points to bash."
echo "##############################################################"

exit 0
