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

# start logging

exec 1>> "$log" 2>&1

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
