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
#   1. Detects (or accepts) the underlying physical disk that
#      backs the root filesystem -- walking through LVM,
#      dm-crypt, and mdraid stacks down to the real disk.
#   2. Classifies the disk (transport, rotational vs SSD, ATA
#      vs non-ATA) and SKIPS steps that don't apply:
#        * hdparm APM/spindown   -> only for rotational ATA
#        * hdparm write-cache    -> only for ATA devices
#        * read-ahead            -> always (applied to the
#          physical disk AND any dm/LV layered on top)
#   3. Adds noatime + commit=60 to the root fstab entry and
#      mounts /tmp on tmpfs.
#   4. Installs and enables zram-tools for compressed swap.
#   5. Disables noisy background services (apport, whoopsie,
#      motd-news).
#   6. Applies VM writeback sysctl tuning to batch dirty-page
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
# Walk dm-crypt / LVM / mdraid stacks down to the underlying physical disk(s).
# Returns one '/dev/<diskname>' per line. For a single-disk root, that's one line.
resolve_physical_disks() {
    local src="$1"
    [[ -z "$src" ]] && return 1
    # lsblk -s gives the inverse tree (children -> parents). The TYPE=="disk"
    # rows are the physical devices that back the given source.
    lsblk -s -no NAME,TYPE "$src" 2>/dev/null \
        | awk '$2 == "disk" {print "/dev/" $1}' \
        | sort -u
}

detect_root_physical_disk() {
    local rootsrc disks
    rootsrc="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -z "$rootsrc" ]] && return 1
    disks="$(resolve_physical_disks "$rootsrc" || true)"
    if [[ -z "$disks" ]]; then
        # Fallback: PKNAME (one level up). Handles oddball setups.
        local parent
        parent="$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -n1)"
        if [[ -n "$parent" ]]; then
            printf '/dev/%s\n' "$parent"
            return 0
        fi
        printf '%s\n' "$rootsrc"
        return 0
    fi
    # If the root is striped/RAID across multiple disks, take the first and warn.
    local count
    count="$(printf '%s\n' "$disks" | wc -l)"
    if [[ "$count" -gt 1 ]]; then
        echo "WARNING: root is backed by multiple physical disks:" >&2
        printf '         %s\n' $disks >&2
        echo "         Using the first one. Re-run with --device to target a specific disk." >&2
    fi
    printf '%s\n' "$disks" | head -n1
}

# Classify a physical disk so we only run tuning steps that make sense for it.
# Sets the following globals:
#   dev_transport  - usb|sata|nvme|mmc|virtio|...   (lsblk TRAN)
#   dev_rotational - 1 (HDD) | 0 (SSD/flash)
#   dev_is_ata     - 1 if hdparm -I succeeds (ATA command set works)
classify_device() {
    local d="$1"
    dev_transport="$(lsblk -dno TRAN "$d" 2>/dev/null | tr -d ' ')"
    [[ -z "$dev_transport" ]] && dev_transport="unknown"
    dev_rotational="$(cat "/sys/block/$(basename "$d")/queue/rotational" 2>/dev/null || echo 0)"
    if hdparm -I "$d" >/dev/null 2>&1; then
        dev_is_ata=1
    else
        dev_is_ata=0
    fi
}

if [[ -z "$device" ]]; then
    detected="$(detect_root_physical_disk || true)"
    if [[ -z "$detected" ]]; then
        echo "ERROR: Could not detect root physical disk."
        exit 1
    fi
    if [[ "$noninteractive" == "1" ]]; then
        device="$detected"
        echo "Using auto-detected device: $device"
    else
        # Interactive prompt goes to the controlling terminal even though
        # stdout is redirected to the log.
        {
            echo "Detected root physical disk: $detected"
            lsblk -dpno NAME,TRAN,SIZE,MODEL "$detected" 2>/dev/null || true
            read -r -p "Use detected device ($detected)? [Y/n]: " reply
            if [[ "$reply" =~ ^[Nn]$ ]]; then
                echo "Available block devices:"
                lsblk -dpno NAME,TRAN,SIZE,MODEL
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

# Refuse partitions / dm devices for the persistence steps -- they need a whole disk.
devtype="$(lsblk -dno TYPE "$device" 2>/dev/null | tr -d ' ')"
if [[ "$devtype" != "disk" ]]; then
    echo "ERROR: '$device' is type '$devtype', not a whole disk."
    echo "       Pass --device with the underlying physical disk (e.g. /dev/sda)."
    exit 1
fi

devbase="$(basename "$device")"
classify_device "$device"
echo "Target device   : $device (kernel name: $devbase)"
echo "  transport     : $dev_transport"
echo "  rotational    : $dev_rotational  (1=HDD, 0=SSD/flash)"
echo "  ATA cmd set   : $([[ $dev_is_ata -eq 1 ]] && echo yes || echo no)"

if [[ "$dev_transport" != "usb" ]]; then
    echo "NOTE: detected transport is '$dev_transport', not 'usb'. Continuing,"
    echo "      but this script is tuned specifically for USB-attached boot disks."
fi

# -------------------------------
# 1. Disable HDD spindown (hdparm) -- only meaningful for rotational ATA disks
# -------------------------------
echo "[1/7] Configuring hdparm (disable APM / spindown)..."
if [[ "$dev_is_ata" -ne 1 ]]; then
    echo "SKIP: $device does not respond to hdparm -I (non-ATA bridge, USB"
    echo "      flash stick, NVMe, or virtual disk). APM/spindown not applicable."
elif [[ "$dev_rotational" -ne 1 ]]; then
    echo "SKIP: $device is non-rotational (SSD/flash). APM/spindown is a"
    echo "      no-op on solid-state media."
else
    cat > /etc/hdparm.conf <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
$device {
    apm = 255
    spindown_time = 0
}
EOF
    if hdparm -B 255 -S 0 "$device" >/dev/null 2>&1; then
        echo "hdparm APM/spindown applied (and persisted in /etc/hdparm.conf)."
    else
        echo "WARNING: hdparm -B/-S not accepted by $device. /etc/hdparm.conf written anyway."
    fi
fi

# -------------------------------
# 2. Enable write caching -- only for ATA disks; modern USB sticks/NVMe handle this themselves
# -------------------------------
echo "[2/7] Enabling write caching..."
if [[ "$dev_is_ata" -ne 1 ]]; then
    echo "SKIP: $device does not accept ATA write-cache commands (non-ATA"
    echo "      bridge, USB flash, NVMe, or virtual disk). The kernel/firmware"
    echo "      manages write caching for these devices already."
elif hdparm -W 1 "$device" >/dev/null 2>&1; then
    cat > /etc/udev/rules.d/99-bos-writecache.rules <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
ACTION=="add", SUBSYSTEM=="block", KERNEL=="$devbase", RUN+="/usr/sbin/hdparm -W1 $device"
EOF
    echo "Write caching enabled and persisted via udev (keyed on $devbase)."
else
    echo "WARNING: hdparm -W1 not accepted by $device. Skipping persistence."
fi

# -------------------------------
# 3. Increase read-ahead -- always useful; apply to physical disk AND
#    any dm/LV layered on top (read-ahead is per-bdev).
# -------------------------------
echo "[3/7] Setting read-ahead buffer to ${readahead} sectors..."
ra_targets=("$device")
rootsrc="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ -n "$rootsrc" && "$rootsrc" != "$device" && -b "$rootsrc" ]]; then
    ra_targets+=("$rootsrc")
fi

# udev rule: key on the physical disk's kernel name. dm/LV read-ahead is
# re-applied at boot via a small systemd service (see below) since dm devices
# don't get a stable 'add' event we can hook reliably here.
cat > /etc/udev/rules.d/60-bos-readahead.rules <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$devbase", RUN+="/sbin/blockdev --setra $readahead $device"
EOF

# Apply now to every relevant block device, and persist dm/LV via a oneshot unit.
for t in "${ra_targets[@]}"; do
    if blockdev --setra "$readahead" "$t" >/dev/null 2>&1; then
        echo "  read-ahead set on $t"
    else
        echo "  WARNING: blockdev --setra failed on $t"
    fi
done

if [[ "${#ra_targets[@]}" -gt 1 ]]; then
    # Persist dm/LV read-ahead across reboots via a tiny systemd oneshot.
    cat > /etc/systemd/system/bos-readahead.service <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
[Unit]
Description=Apply bos-scripts read-ahead to root block devices
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/blockdev --setra $readahead ${ra_targets[*]}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now bos-readahead.service >/dev/null 2>&1; then
        echo "  bos-readahead.service enabled (persists read-ahead on dm/LV)."
    else
        echo "  WARNING: failed to enable bos-readahead.service."
    fi
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

echo "Read-ahead:"
for t in "${ra_targets[@]}"; do
    printf '  %-40s %s\n' "$t" "$(blockdev --getra "$t" 2>/dev/null || echo n/a)"
done

if [[ "$dev_is_ata" -eq 1 ]]; then
    echo "Write cache ($device):"
    hdparm -W "$device" 2>/dev/null | sed 's/^/  /' \
        || echo "  (hdparm -W query failed)"
else
    echo "Write cache: (skipped -- $device is not an ATA device; transport=$dev_transport)"
fi

echo "zram devices:"
zramctl 2>/dev/null || echo "  (zramctl unavailable)"

echo ""
echo "##############################################################"
echo "# $(date) | $scriptname complete. Reboot recommended."
echo "##############################################################"

exit 0
