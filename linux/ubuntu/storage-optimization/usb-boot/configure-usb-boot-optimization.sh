#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  configure-usb-boot-optimization.sh
# Purpose: Tunes an Ubuntu host that boots from a USB-attached
#          disk (HDD, SSD, or large flash drive) so that random
#          writes are minimised, sequential reads are batched,
#          and the device does not spin down or get hammered by
#          unnecessary background writes.
#
# What the script does:
#   1. Detects (or accepts) the parent block device that backs
#      the root filesystem.
#   2. Disables APM / spindown via hdparm (skipped when the
#      device does not support hdparm, e.g. plain USB sticks).
#   3. Enables write caching on the device.
#   4. Increases the read-ahead buffer to 4096 sectors.
#   5. Adds noatime + commit=60 to the root fstab entry and
#      mounts /tmp on tmpfs.
#   6. Installs and enables zram-tools for compressed swap.
#   7. Disables noisy background services (apport, whoopsie,
#      motd-news).
#   8. Applies VM writeback sysctl tuning to batch dirty-page
#      flushes.
#
# Detection / Idempotency:
#   - hdparm config and udev rules are written with full file
#     replacement, so re-runs produce the same content.
#   - fstab edits are anchored to the root entry only and
#     guarded so noatime / commit / tmpfs are added at most
#     once. A timestamped backup is taken before any change.
#   - sysctl tuning lives in its own drop-in file and is
#     overwritten on re-run rather than appended repeatedly.
#   Safe to run multiple times.
#
# Non-interactive use (managed deployment):
#   Pass the device explicitly to skip the interactive prompt:
#     sudo bash configure-usb-boot-optimization.sh --device /dev/sda
#   Or set NONINTERACTIVE=1 to auto-accept the detected device.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt):
#     Run as root with --device or NONINTERACTIVE=1. All
#     activity is logged to $log. Exit codes:
#       0 = success (configured or already configured)
#       1 = failure (review log for details)
#     A reboot is recommended after success.
#
#   Manual:
#     sudo bash ./linux/ubuntu/storage-optimization/usb-boot/configure-usb-boot-optimization.sh
#
# Variables:
#   scriptname - Display name used in log messages
#   log        - Full path of the log file written by this script
#   readahead  - Read-ahead size in 512-byte sectors
#   sysctlfile - Sysctl drop-in file for VM writeback tuning
# =============================================================

# Define variables

scriptname="USB Boot Optimization"
log="/var/log/configure-usb-boot-optimization.log"
readahead=4096
sysctlfile="/etc/sysctl.d/60-bos-usb-boot.conf"

# Argument parsing
device=""
noninteractive="${NONINTERACTIVE:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            device="$2"
            noninteractive=1
            shift 2
            ;;
        --device=*)
            device="${1#*=}"
            noninteractive=1
            shift
            ;;
        -y|--yes|--non-interactive)
            noninteractive=1
            shift
            ;;
        -h|--help)
            cat <<USAGE
Usage: $(basename "$0") [--device /dev/sdX] [--yes]

  --device PATH   Target parent block device (skips prompt)
  --yes           Accept the auto-detected device without prompting
                  (also enabled when NONINTERACTIVE=1 is exported)
USAGE
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# start logging
# Tee all stdout/stderr to both the log file (appended) and the console
# so output is visible during interactive runs and captured for managed
# deployments / post-mortem review.
exec > >(tee -a "$log") 2>&1

echo ""
echo "##############################################################"
echo "# $(date) | Starting $scriptname"
echo "##############################################################"

# Require root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# -------------------------------
# Detect / confirm root device
# -------------------------------
detect_parent_device() {
    local rootsrc parent
    rootsrc="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ -z "$rootsrc" ]]; then
        return 1
    fi
    # lsblk handles nvme/mmc/dm-crypt naming better than a sed pattern.
    parent="$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -n1)"
    if [[ -n "$parent" ]]; then
        printf '/dev/%s\n' "$parent"
    else
        # Already a whole disk (e.g. /dev/sda); return as-is.
        printf '%s\n' "$rootsrc"
    fi
}

if [[ -z "$device" ]]; then
    detected="$(detect_parent_device || true)"
    if [[ -z "$detected" ]]; then
        echo "ERROR: Could not detect root parent device."
        exit 1
    fi
    if [[ "$noninteractive" == "1" ]]; then
        device="$detected"
        echo "Using auto-detected device: $device"
    else
        # Interactive prompt goes to the controlling terminal even though
        # stdout is redirected to the log.
        {
            echo "Detected root device: $detected"
            read -r -p "Use detected device ($detected)? [Y/n]: " reply
            if [[ "$reply" =~ ^[Nn]$ ]]; then
                echo "Available block devices:"
                lsblk -dpno NAME,SIZE,MODEL
                read -r -p "Enter device path (e.g., /dev/sda): " device
            else
                device="$detected"
            fi
        } </dev/tty >/dev/tty
    fi
fi

if [[ ! -b "$device" ]]; then
    echo "ERROR: '$device' is not a block device."
    exit 1
fi
devbase="$(basename "$device")"
echo "Target device: $device (kernel name: $devbase)"

# -------------------------------
# 1. Disable HDD spindown (hdparm)
# -------------------------------
echo "[1/7] Configuring hdparm (disable APM / spindown)..."
if hdparm -I "$device" >/dev/null 2>&1; then
    cat > /etc/hdparm.conf <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
$device {
    apm = 255
    spindown_time = 0
}
EOF
    if hdparm -B 255 -S 0 "$device" >/dev/null 2>&1; then
        echo "hdparm APM/spindown applied."
    else
        echo "WARNING: hdparm -B/-S not accepted by $device. Continuing."
    fi
else
    echo "WARNING: $device does not respond to hdparm (likely a USB flash"
    echo "         drive or non-ATA bridge). Skipping hdparm tuning."
fi

# -------------------------------
# 2. Enable write caching
# -------------------------------
echo "[2/7] Enabling write caching..."
if hdparm -W 1 "$device" >/dev/null 2>&1; then
    cat > /etc/udev/rules.d/99-bos-writecache.rules <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
ACTION=="add", KERNEL=="$devbase", RUN+="/usr/sbin/hdparm -W1 $device"
EOF
    echo "Write caching enabled and persisted via udev."
else
    echo "WARNING: Could not enable write cache via hdparm on $device. Skipping."
fi

# -------------------------------
# 3. Increase read-ahead
# -------------------------------
echo "[3/7] Setting read-ahead buffer to ${readahead} sectors..."
if blockdev --setra "$readahead" "$device" >/dev/null 2>&1; then
    cat > /etc/udev/rules.d/60-bos-readahead.rules <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
ACTION=="add", KERNEL=="$devbase", RUN+="/sbin/blockdev --setra $readahead $device"
EOF
    echo "Read-ahead set and persisted via udev."
else
    echo "WARNING: blockdev --setra failed on $device."
fi

# -------------------------------
# 4. Optimize /etc/fstab (root entry + tmpfs /tmp)
# -------------------------------
echo "[4/7] Optimizing /etc/fstab..."
fstabbackup="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
cp /etc/fstab "$fstabbackup"
echo "fstab backup created at $fstabbackup"

# Add noatime,commit=60 ONLY to the root (' / ') entry, and only if not present.
# Match lines whose mountpoint field (column 2) is exactly '/'.
if awk '$1 !~ /^#/ && $2 == "/" {found=1} END {exit !found}' /etc/fstab; then
    if awk '$1 !~ /^#/ && $2 == "/" && ($4 ~ /noatime/ && $4 ~ /commit=/) {found=1} END {exit !found}' /etc/fstab; then
        echo "Root fstab entry already has noatime + commit=. Skipping."
    else
        # Insert noatime,commit=60 into the options field of the root row only.
        awk 'BEGIN{OFS="\t"}
             $1 !~ /^#/ && $2 == "/" {
                 opts = $4
                 if (opts !~ /(^|,)noatime(,|$)/) opts = opts ",noatime"
                 if (opts !~ /(^|,)commit=/)    opts = opts ",commit=60"
                 $4 = opts
             }
             { print }' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
        echo "Added noatime,commit=60 to root fstab entry."
    fi
else
    echo "WARNING: No root ('/') entry found in /etc/fstab. Skipping fstab options."
fi

if grep -Eq '^[^#].*[[:space:]]/tmp[[:space:]]+tmpfs' /etc/fstab; then
    echo "/tmp tmpfs entry already present. Skipping."
else
    cat >> /etc/fstab <<EOF

# Managed by bos-scripts-collection: /tmp on tmpfs to reduce USB writes
tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0
EOF
    echo "Added tmpfs /tmp entry."
fi

# -------------------------------
# 5. Enable zram
# -------------------------------
echo "[5/7] Installing and enabling zram-tools..."
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s zram-tools >/dev/null 2>&1; then
    if ! apt-get update -y >/dev/null; then
        echo "WARNING: apt-get update failed."
    fi
    if ! apt-get install -y zram-tools >/dev/null; then
        echo "ERROR: Failed to install zram-tools."
        exit 1
    fi
else
    echo "zram-tools already installed."
fi

if systemctl enable --now zramswap.service >/dev/null 2>&1; then
    echo "zramswap.service enabled and started."
else
    echo "WARNING: Could not enable zramswap.service."
fi

# -------------------------------
# 6. Disable noisy background services
# -------------------------------
echo "[6/7] Disabling noisy background services..."
for svc in apport.service whoopsie.service motd-news.service motd-news.timer; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
        systemctl disable --now "$svc" >/dev/null 2>&1 \
            && echo "  disabled $svc" \
            || echo "  WARNING: could not disable $svc"
    fi
done

# -------------------------------
# 7. Kernel writeback tuning (idempotent drop-in)
# -------------------------------
echo "[7/7] Applying VM writeback sysctl tuning..."
cat > "$sysctlfile" <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
# USB-attached boot disk writeback tuning
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
EOF
if sysctl --system >/dev/null 2>&1; then
    echo "sysctl reloaded."
else
    echo "WARNING: sysctl --system reported errors."
fi

# -------------------------------
# Verification
# -------------------------------
echo ""
echo "=== Verification ==="
echo -n "Root mount options: "
mount | awk '$3 == "/" {print $6; exit}'

echo -n "Read-ahead ($device): "
blockdev --getra "$device" 2>/dev/null || echo "n/a"

echo "Write cache:"
hdparm -I "$device" 2>/dev/null | grep -i 'Write cache' || echo "  (hdparm not applicable to $device)"

echo "zram devices:"
zramctl 2>/dev/null || echo "  (zramctl unavailable)"

echo ""
echo "##############################################################"
echo "# $(date) | $scriptname complete. Reboot recommended."
echo "##############################################################"

exit 0
