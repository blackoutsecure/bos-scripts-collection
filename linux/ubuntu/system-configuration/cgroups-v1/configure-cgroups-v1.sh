#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  configure-cgroups-v1.sh
# Purpose: Configures Ubuntu to boot with the legacy cgroups v1
#          unified hierarchy disabled-style layout by adding the
#          `systemd.unified_cgroup_hierarchy=0` kernel parameter
#          to GRUB and regenerating the GRUB configuration.
#
# Some workloads (older container runtimes, certain monitoring
# agents, legacy Java tooling, and some Kubernetes node images)
# require cgroups v1. Modern Ubuntu releases default to cgroups
# v2 (unified hierarchy). This script flips the kernel cmdline
# back to v1 and updates GRUB so the change persists across
# reboots.
#
# Detection / Idempotency:
#   If `systemd.unified_cgroup_hierarchy=0` is already present
#   in /etc/default/grub the GRUB file is left untouched.
#   `update-grub` is still re-run to ensure the boot loader
#   matches the on-disk config. Safe to run multiple times.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt,
#            or any tool that runs shell scripts as root):
#     Deploy as a one-shot configuration script. All activity
#     is logged to $log for review. Monitor the exit code:
#       0 = success (configured or already configured)
#       1 = failure (review log for details)
#     A reboot is required to apply the change.
#
#   Manual:
#     sudo bash ./linux/ubuntu/system-configuration/cgroups-v1/configure-cgroups-v1.sh
#     sudo reboot
#
# Verification (after reboot):
#     cat /proc/cmdline | grep systemd.unified_cgroup_hierarchy
#     stat -fc %T /sys/fs/cgroup/    # expect "tmpfs" (v1) instead of "cgroup2fs"
#
# Variables:
#   scriptname  - Display name used in log messages
#   log         - Full path of the log file written by this script
#   grubfile    - Path to the GRUB defaults file to modify
#   grubbackup  - Path of the timestamped backup of $grubfile
#   kernelparam - Kernel cmdline parameter added to GRUB
# =============================================================

# Define variables

scriptname="Cgroups v1 Configuration"
log="/var/log/configure-cgroups-v1.log"
grubfile="/etc/default/grub"
grubbackup="/etc/default/grub.backup.$(date +%Y%m%d-%H%M%S)"
kernelparam="systemd.unified_cgroup_hierarchy=0"

# Argument parsing
mode="apply"
for arg in "$@"; do
    case "$arg" in
        --check|--status) mode="check" ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--check]
  (no args)   Apply: backup grub, add ${kernelparam}, update-grub
  --check     Read-only audit: report whether GRUB and the running kernel
              are configured for cgroups v1. Exit 0 if compliant, 2 on drift.
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
echo "# $(date) | Starting $scriptname"
echo "##############################################################"

# Require root (no interactive sudo prompts in managed deployment)
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# Verify GRUB file exists
if [[ ! -f "$grubfile" ]]; then
    echo "ERROR: $grubfile not found. This script targets Ubuntu/Debian-style GRUB systems."
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
        printf "  [%s] %-40s %s\n" "$verdict" "$name" "$detail"
        case "$verdict" in PASS) ((pass++));; FAIL) ((fail++));; esac
    }

    # 1. GRUB defaults file contains the parameter
    if grep -Eq "^GRUB_CMDLINE_LINUX=\"[^\"]*${kernelparam}" "$grubfile"; then
        report PASS "grub cmdline param" "${kernelparam} present in $grubfile"
    else
        report FAIL "grub cmdline param" "${kernelparam} NOT in $grubfile"
    fi

    # 2. Generated grub.cfg references it (i.e. update-grub has been run since edit)
    grubcfg=""
    for f in /boot/grub/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/debian/grub.cfg; do
        [[ -f "$f" ]] && { grubcfg="$f"; break; }
    done
    if [[ -z "$grubcfg" ]]; then
        report FAIL "generated grub.cfg" "could not locate grub.cfg under /boot"
    elif grep -q "$kernelparam" "$grubcfg"; then
        report PASS "generated grub.cfg" "${kernelparam} baked into $grubcfg"
    else
        report FAIL "generated grub.cfg" "${kernelparam} missing from $grubcfg (run update-grub)"
    fi

    # 3. Running kernel cmdline (only true after a reboot)
    if grep -q "$kernelparam" /proc/cmdline; then
        report PASS "running kernel cmdline" "${kernelparam} active"
    else
        report FAIL "running kernel cmdline" "not active (reboot required)"
    fi

    # 4. Live cgroup hierarchy
    fstype="$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo unknown)"
    if [[ "$fstype" == "tmpfs" ]]; then
        report PASS "live cgroup hierarchy" "tmpfs (cgroups v1)"
    elif [[ "$fstype" == "cgroup2fs" ]]; then
        report FAIL "live cgroup hierarchy" "cgroup2fs (still v2 — reboot required)"
    else
        report FAIL "live cgroup hierarchy" "unexpected fstype '$fstype'"
    fi

    echo ""
    echo "Summary: $pass PASS / $fail FAIL"
    if [[ "$fail" -gt 0 ]]; then
        echo "DRIFT DETECTED. Re-run without --check to reconcile (and reboot if not yet applied)."
        exit 2
    fi
    echo "All cgroups v1 settings active."
    exit 0
fi

# -------------------------------
# 1. Backup GRUB config
# -------------------------------
echo "[1/4] Backing up $grubfile..."
if ! cp "$grubfile" "$grubbackup"; then
    echo "ERROR: Failed to create backup at $grubbackup."
    exit 1
fi
echo "Backup created at $grubbackup"

# -------------------------------
# 2. Add cgroups v1 kernel parameter (idempotent)
# -------------------------------
echo "[2/4] Configuring GRUB to use cgroups v1..."
if grep -Eq "^GRUB_CMDLINE_LINUX=\"[^\"]*${kernelparam}" "$grubfile"; then
    echo "Parameter '$kernelparam' already present in GRUB_CMDLINE_LINUX. Skipping modification."
else
    # Insert at the start of GRUB_CMDLINE_LINUX="..." preserving any existing args.
    if ! sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"${kernelparam} |" "$grubfile"; then
        echo "ERROR: Failed to update $grubfile."
        exit 1
    fi

    # Confirm the edit landed (sed returns 0 even if the pattern did not match).
    if ! grep -q "$kernelparam" "$grubfile"; then
        echo "ERROR: GRUB_CMDLINE_LINUX line not found or not modified in $grubfile."
        echo "Restoring backup from $grubbackup."
        cp "$grubbackup" "$grubfile"
        exit 1
    fi
    echo "Added '$kernelparam' to GRUB_CMDLINE_LINUX."
fi

# -------------------------------
# 3. Update GRUB
# -------------------------------
echo "[3/4] Running update-grub..."
if ! update-grub >/dev/null; then
    echo "ERROR: update-grub failed."
    exit 1
fi
echo "GRUB updated."

# -------------------------------
# 4. Verification
# -------------------------------
echo "[4/4] Verification:"
echo "Current GRUB_CMDLINE_LINUX entry:"
grep "^GRUB_CMDLINE_LINUX=" "$grubfile"

echo ""
echo "##############################################################"
echo "# $(date) | $scriptname complete. Reboot required to apply."
echo "##############################################################"

exit 0
