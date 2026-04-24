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
#        * I/O scheduler         -> bfq for HDD, none for SSD
#        * fstrim.timer          -> only for SSD/flash
#   3. Adds noatime + commit=60 to the root fstab entry and
#      mounts /tmp on tmpfs.
#   4. Installs and enables zram-tools and (unless
#      --no-zram-tune is passed) raises the compressed swap
#      pool from the stock ~256 MB to PERCENT=50 of RAM.
#   5. Disables noisy background services (apport, whoopsie,
#      motd-news).
#   6. Applies VM writeback sysctl tuning to batch dirty-page
#      flushes.
#
# Modes:
#   apply (default) - reconcile the system to the desired state
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
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
#       2 = drift detected (only emitted by --check)
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
zramswapfile="/etc/default/zramswap"
ioschedrule="/etc/udev/rules.d/60-bos-ioscheduler.rules"
zram_target_percent=50

# Argument parsing
device=""
noninteractive="${NONINTERACTIVE:-0}"
mode="apply"          # apply | check
tune_zram=1           # 0 = leave zram-tools defaults alone
install_bfq=1         # 0 = never apt-install linux-modules-extra to get bfq
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
        --check|--status)
            mode="check"
            noninteractive=1
            shift
            ;;
        --no-zram-tune)
            tune_zram=0
            shift
            ;;
        --no-install-bfq)
            install_bfq=0
            shift
            ;;
        -h|--help)
            cat <<USAGE
Usage: $(basename "$0") [--device /dev/sdX] [--yes] [--check]
                                  [--no-zram-tune] [--no-install-bfq]

  --device PATH      Target whole-disk device (skips prompt)
  --yes              Accept the auto-detected device without prompting
                     (also enabled when NONINTERACTIVE=1 is exported)
  --check            Read-only status check; do not modify anything.
                     Exit code: 0 = all settings match, 2 = drift detected.
  --no-zram-tune     Do NOT modify /etc/default/zramswap (leave the
                     distro default of ~256 MB compressed swap).
  --no-install-bfq   Do NOT apt-install linux-modules-extra to enable
                     the 'bfq' I/O scheduler when missing on rotational
                     disks. Falls back to mq-deadline silently.

Exit codes:
  0  apply OK / already configured (apply mode), or all checks PASS (--check)
  1  failure (review log for details)
  2  drift detected (--check only)
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
    # lsblk -s gives the inverse tree (children -> parents). -l forces list
    # output so NAME doesn't contain tree-drawing glyphs (e.g. "└─sda").
    # The TYPE=="disk" rows are the physical devices that back $src.
    lsblk -s -l -no NAME,TYPE "$src" 2>/dev/null \
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

# Build a list of "likely" candidate disks: real block devices, type=disk,
# non-zero size, excluding loop/zram/ram/dm. Returns one '/dev/<name>' per line.
list_candidate_disks() {
    lsblk -dpno NAME,TYPE,SIZE,TRAN,MODEL 2>/dev/null \
        | awk '$2 == "disk" && $3 != "0B" && $1 !~ /\/(loop|zram|ram|dm-)/ {print $1}'
}

# Pretty-print a numbered menu of candidates and read a selection.
# Sets the global $device on success, returns 1 on cancel.
prompt_candidate_menu() {
    local candidates=() line idx choice path
    while IFS= read -r line; do candidates+=("$line"); done < <(list_candidate_disks)
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        echo "No candidate disks found." >&2
        return 1
    fi

    echo ""
    echo "Likely candidates (filtered: real disks only, no loop/zram):"
    printf '  %3s  %-12s %-6s %-8s %s\n' "#" "DEVICE" "TRAN" "SIZE" "MODEL"
    idx=0
    for path in "${candidates[@]}"; do
        idx=$((idx + 1))
        # Re-query each row so columns line up cleanly regardless of MODEL spaces.
        local tran size model
        tran="$(lsblk -dno TRAN  "$path" 2>/dev/null | tr -d ' ')"
        size="$(lsblk -dno SIZE  "$path" 2>/dev/null | tr -d ' ')"
        model="$(lsblk -dno MODEL "$path" 2>/dev/null | sed 's/[[:space:]]\+$//')"
        printf '  %3d  %-12s %-6s %-8s %s\n' "$idx" "$path" "${tran:-?}" "${size:-?}" "${model:-}"
    done
    echo "    a  Advanced -- show ALL block devices and enter a custom path"
    echo "    q  Quit"

    read -r -p "Select [1-${#candidates[@]} / a / q]: " choice
    case "$choice" in
        q|Q) return 1 ;;
        a|A)
            echo ""
            echo "All block devices:"
            lsblk -pno NAME,TYPE,TRAN,SIZE,MODEL,MOUNTPOINTS
            read -r -p "Enter full device path (e.g. /dev/sdb): " path
            if [[ -z "$path" || ! -b "$path" ]]; then
                echo "Not a valid block device: '$path'" >&2
                return 1
            fi
            device="$path"
            ;;
        ''|*[!0-9]*)
            echo "Invalid selection: '$choice'" >&2
            return 1
            ;;
        *)
            if (( choice < 1 || choice > ${#candidates[@]} )); then
                echo "Selection out of range: $choice" >&2
                return 1
            fi
            device="${candidates[$((choice - 1))]}"
            ;;
    esac
    return 0
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
        # Interactive prompts go to the controlling terminal even though
        # stdout is redirected to the log via tee.
        {
            echo "Detected root physical disk: $detected"
            lsblk -dpno NAME,TRAN,SIZE,MODEL "$detected" 2>/dev/null || true
            read -r -p "Use detected device ($detected)? [Y/n]: " reply
            if [[ "$reply" =~ ^[Nn]$ ]]; then
                if ! prompt_candidate_menu; then
                    echo "ERROR: no device selected. Aborting."
                    exit 1
                fi
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

# =============================================================
# --check (read-only status) mode
# Exit 0 = all PASS, 2 = drift detected, 1 = error.
# =============================================================
if [[ "$mode" == "check" ]]; then
    echo ""
    echo "=== --check (read-only) ==="
    fail=0
    pass=0
    skip=0
    report() {
        local status="$1" name="$2" detail="$3"
        case "$status" in
            PASS) pass=$((pass+1)) ;;
            FAIL) fail=$((fail+1)) ;;
            SKIP) skip=$((skip+1)) ;;
        esac
        printf '  [%-4s] %-32s %s\n' "$status" "$name" "$detail"
    }

    # hdparm APM/spindown (only for rotational ATA)
    if [[ "$dev_is_ata" -eq 1 && "$dev_rotational" -eq 1 ]]; then
        if grep -q "^[[:space:]]*apm[[:space:]]*=[[:space:]]*255" /etc/hdparm.conf 2>/dev/null \
           && grep -q "^[[:space:]]*spindown_time[[:space:]]*=[[:space:]]*0" /etc/hdparm.conf 2>/dev/null; then
            report PASS "hdparm APM/spindown" "/etc/hdparm.conf has apm=255, spindown_time=0"
        else
            report FAIL "hdparm APM/spindown" "/etc/hdparm.conf missing apm/spindown entries"
        fi
    else
        report SKIP "hdparm APM/spindown" "n/a for $device (ata=$dev_is_ata rot=$dev_rotational)"
    fi

    # Write cache udev rule (ATA only)
    if [[ "$dev_is_ata" -eq 1 ]]; then
        if grep -q "KERNEL==\"$devbase\".*hdparm -W1" /etc/udev/rules.d/99-bos-writecache.rules 2>/dev/null; then
            report PASS "write-cache udev rule" "keyed on $devbase"
        else
            report FAIL "write-cache udev rule" "missing or wrong device"
        fi
    else
        report SKIP "write-cache udev rule" "n/a for non-ATA"
    fi

    # Read-ahead udev rule + live values
    if grep -q "KERNEL==\"$devbase\".*--setra $readahead" /etc/udev/rules.d/60-bos-readahead.rules 2>/dev/null; then
        report PASS "read-ahead udev rule" "keyed on $devbase, ra=$readahead"
    else
        report FAIL "read-ahead udev rule" "missing or wrong device/ra"
    fi
    for t in "${ra_targets[@]}"; do
        cur_ra="$(blockdev --getra "$t" 2>/dev/null || echo 0)"
        if [[ "$cur_ra" == "$readahead" ]]; then
            report PASS "read-ahead live ($t)" "$cur_ra"
        else
            report FAIL "read-ahead live ($t)" "got $cur_ra, want $readahead"
        fi
    done
    if [[ "${#ra_targets[@]}" -gt 1 ]]; then
        if systemctl is-enabled bos-readahead.service >/dev/null 2>&1; then
            report PASS "bos-readahead.service" "enabled"
        else
            report FAIL "bos-readahead.service" "not enabled"
        fi
        if [[ -x /usr/local/sbin/bos-readahead-apply ]]; then
            report PASS "bos-readahead helper" "/usr/local/sbin/bos-readahead-apply"
        else
            report FAIL "bos-readahead helper" "missing /usr/local/sbin/bos-readahead-apply"
        fi
    fi

    # I/O scheduler udev rule
    if grep -q "KERNEL==\"$devbase\"" "$ioschedrule" 2>/dev/null; then
        cur_sched="$(cat "/sys/block/$devbase/queue/scheduler" 2>/dev/null || echo '')"
        report PASS "I/O scheduler udev rule" "current=$cur_sched"
    else
        report FAIL "I/O scheduler udev rule" "missing $ioschedrule"
    fi

    # bfq module auto-load (only when the rule asks for bfq)
    if grep -q 'ATTR{queue/scheduler}="bfq"' "$ioschedrule" 2>/dev/null; then
        if [[ -f /etc/modules-load.d/bfq.conf ]] && grep -qx 'bfq' /etc/modules-load.d/bfq.conf; then
            report PASS "bfq module auto-load" "/etc/modules-load.d/bfq.conf"
        else
            report FAIL "bfq module auto-load" "missing /etc/modules-load.d/bfq.conf"
        fi
    else
        report SKIP "bfq module auto-load" "not using bfq"
    fi

    # fstrim.timer (SSD/flash only)
    if [[ "$dev_rotational" -eq 1 ]]; then
        report SKIP "fstrim.timer" "n/a (rotational)"
    elif systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
        report PASS "fstrim.timer" "enabled"
    else
        report FAIL "fstrim.timer" "not enabled"
    fi

    # fstab: noatime+commit on / and tmpfs /tmp
    if awk '$1 !~ /^#/ && $2 == "/" && ($4 ~ /noatime/ && $4 ~ /commit=/) {f=1} END {exit !f}' /etc/fstab; then
        report PASS "fstab root opts" "noatime,commit= present"
    else
        report FAIL "fstab root opts" "noatime/commit missing on /"
    fi
    if grep -Eq '^[^#].*[[:space:]]/tmp[[:space:]]+tmpfs' /etc/fstab; then
        report PASS "fstab /tmp tmpfs" "present"
    else
        report FAIL "fstab /tmp tmpfs" "missing"
    fi

    # zram service + tuning
    if systemctl is-enabled zramswap.service >/dev/null 2>&1; then
        report PASS "zramswap.service" "enabled"
    else
        report FAIL "zramswap.service" "not enabled"
    fi
    if [[ "$tune_zram" -eq 1 ]]; then
        if grep -Eq '^[[:space:]]*(PERCENT|ALLOCATION)=' "$zramswapfile" 2>/dev/null; then
            cur_zram="$(grep -E '^[[:space:]]*(PERCENT|ALLOCATION)=' "$zramswapfile" | head -1)"
            report PASS "zram size config" "$cur_zram"
        else
            report FAIL "zram size config" "stock defaults (~256 MB)"
        fi
    else
        report SKIP "zram size config" "--no-zram-tune"
    fi

    # Disabled noisy services
    # `systemctl is-enabled` returns 0 for several states. Treat anything
    # that means "won't auto-start" as PASS: disabled, masked, static (units
    # with no [Install] section -- they only run if pulled in or activated;
    # we mask them in the apply step so this becomes definitive), indirect,
    # linked. Only enabled / alias / enabled-runtime are FAIL.
    for svc in apport.service whoopsie.service motd-news.service motd-news.timer; do
        if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            report SKIP "service $svc" "not installed"
            continue
        fi
        # systemctl is-enabled can emit multiple lines (e.g. "disabled\nunknown"
        # when an alias has no install info). We only care about the primary
        # state on the first line.
        state="$(systemctl is-enabled "$svc" 2>/dev/null | head -n1)"
        [[ -z "$state" ]] && state="unknown"
        case "$state" in
            masked|disabled|static|indirect|linked)
                report PASS "service $svc" "$state"
                ;;
            enabled|alias|enabled-runtime)
                report FAIL "service $svc" "$state"
                ;;
            *)
                report FAIL "service $svc" "unexpected state '$state'"
                ;;
        esac
    done

    # sysctl drop-in
    if [[ -f "$sysctlfile" ]] \
       && grep -q '^vm.dirty_background_ratio = 5' "$sysctlfile" \
       && grep -q '^vm.dirty_ratio = 20' "$sysctlfile"; then
        report PASS "sysctl drop-in" "$sysctlfile present"
    else
        report FAIL "sysctl drop-in" "$sysctlfile missing/incorrect"
    fi

    echo ""
    echo "Summary: $pass PASS / $fail FAIL / $skip SKIP"
    if [[ "$fail" -gt 0 ]]; then
        echo "DRIFT DETECTED. Re-run without --check to reconcile."
        exit 2
    fi
    echo "All applicable settings already configured."
    exit 0
fi

# -------------------------------
# 1. Disable HDD spindown (hdparm) -- only meaningful for rotational ATA disks
# -------------------------------
echo "[1/9] Configuring hdparm (disable APM / spindown)..."
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
echo "[2/9] Enabling write caching..."
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
echo "[3/9] Setting read-ahead buffer to ${readahead} sectors..."
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
    # The targets are recomputed at boot by a helper script so the unit keeps
    # working if the LV moves to a different PV, the disk is reinitialized,
    # or the block-device tree changes after a kernel/LVM upgrade.
    helper="/usr/local/sbin/bos-readahead-apply"
    cat > "$helper" <<EOF
#!/bin/bash
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
# Re-applies read-ahead at boot to whatever block devices currently back '/'.
set -u
readahead=$readahead

rootsrc="\$(findmnt -n -o SOURCE / 2>/dev/null || true)"
[[ -z "\$rootsrc" ]] && exit 0

# Collect the root source plus every physical disk underneath it.
targets=("\$rootsrc")
while IFS= read -r d; do
    [[ -n "\$d" && -b "\$d" ]] && targets+=("\$d")
done < <(lsblk -s -l -no NAME,TYPE "\$rootsrc" 2>/dev/null \\
         | awk '\$2 == "disk" {print "/dev/" \$1}' \\
         | sort -u)

rc=0
for t in "\${targets[@]}"; do
    [[ -b "\$t" ]] || continue
    /sbin/blockdev --setra "\$readahead" "\$t" || rc=\$?
done
exit \$rc
EOF
    chmod 0755 "$helper"

    cat > /etc/systemd/system/bos-readahead.service <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
[Unit]
Description=Apply bos-scripts read-ahead to root block devices
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$helper
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
# 4. I/O scheduler -- pin via udev (bfq for HDD, none/mq-deadline for SSD)
# -------------------------------
echo "[4/9] Configuring I/O scheduler for $devbase..."
if [[ "$dev_rotational" -eq 1 ]]; then
    iosched="bfq"
else
    iosched="none"
fi

# Helper: re-read scheduler list.
sched_avail() { cat "/sys/block/$devbase/queue/scheduler" 2>/dev/null || true; }

avail="$(sched_avail)"
if [[ -z "$avail" ]]; then
    echo "SKIP: /sys/block/$devbase/queue/scheduler not readable."
    iosched=""
elif ! grep -qw "$iosched" <<<"$avail"; then
    # Preferred scheduler not currently offered by the kernel.
    if [[ "$iosched" == "bfq" ]]; then
        # Try modprobe first -- bfq is a module, sometimes just not loaded.
        if modprobe bfq >/dev/null 2>&1 && grep -qw bfq <<<"$(sched_avail)"; then
            echo "loaded 'bfq' kernel module."
            avail="$(sched_avail)"
        elif [[ "$install_bfq" -eq 1 ]]; then
            # bfq lives in linux-modules-extra-$(uname -r) on Ubuntu Server.
            kpkg="linux-modules-extra-$(uname -r)"
            if dpkg -s "$kpkg" >/dev/null 2>&1; then
                echo "NOTE: '$kpkg' already installed but 'bfq' still unavailable."
            else
                echo "Installing '$kpkg' to enable the bfq I/O scheduler..."
                export DEBIAN_FRONTEND=noninteractive
                if apt-get update -y >/dev/null 2>&1 \
                   && apt-get install -y "$kpkg" >/dev/null 2>&1; then
                    echo "  installed $kpkg"
                    modprobe bfq >/dev/null 2>&1 || true
                    avail="$(sched_avail)"
                else
                    echo "  WARNING: failed to install $kpkg (continuing without bfq)."
                fi
            fi
        else
            echo "NOTE: bfq missing and --no-install-bfq specified; not installing."
        fi
    fi

    # Re-check after modprobe / install attempt.
    if ! grep -qw "$iosched" <<<"$avail"; then
        if grep -qw "mq-deadline" <<<"$avail"; then
            echo "NOTE: '$iosched' not available; falling back to mq-deadline."
            iosched="mq-deadline"
        else
            iosched="$(echo "$avail" | tr -d '[]' | awk '{print $1}')"
            echo "NOTE: defaulting to first available scheduler '$iosched'."
        fi
    fi
fi

if [[ -n "$iosched" ]]; then
    cat > "$ioschedrule" <<EOF
# Managed by bos-scripts-collection / configure-usb-boot-optimization.sh
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="$devbase", ATTR{queue/scheduler}="$iosched"
EOF
    # Apply now too (udev rule covers reboots).
    if echo "$iosched" > "/sys/block/$devbase/queue/scheduler" 2>/dev/null; then
        echo "I/O scheduler set to '$iosched' on $devbase (persisted via udev)."
    else
        echo "WARNING: could not write scheduler live; udev rule will apply on reboot."
    fi

    # If we picked bfq, make sure the module is auto-loaded at boot. The udev
    # rule's ATTR{queue/scheduler}="bfq" will silently fall back to whatever
    # scheduler is active when bfq.ko isn't loaded yet, so this guarantees
    # the module is present before udev fires.
    if [[ "$iosched" == "bfq" ]]; then
        modlist="/etc/modules-load.d/bfq.conf"
        if [[ -f "$modlist" ]] && grep -qx "bfq" "$modlist"; then
            : # already pinned
        else
            echo "bfq" > "$modlist"
            echo "Pinned 'bfq' kernel module via $modlist."
        fi
    fi
fi

# -------------------------------
# 5. fstrim.timer -- only meaningful on SSD/flash
# -------------------------------
echo "[5/9] Configuring fstrim.timer..."
if [[ "$dev_rotational" -eq 1 ]]; then
    echo "SKIP: $device is rotational (HDD). TRIM/discard does not apply."
elif ! systemctl list-unit-files 2>/dev/null | grep -q '^fstrim.timer'; then
    echo "SKIP: fstrim.timer not present on this system."
else
    if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
        echo "fstrim.timer already enabled."
    else
        if systemctl enable --now fstrim.timer >/dev/null 2>&1; then
            echo "fstrim.timer enabled (weekly TRIM)."
        else
            echo "WARNING: could not enable fstrim.timer."
        fi
    fi
fi

# -------------------------------
# 6. Optimize /etc/fstab (root entry + tmpfs /tmp)
# -------------------------------
echo "[6/9] Optimizing /etc/fstab..."
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
echo "[7/9] Installing, enabling, and tuning zram-tools..."
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

# Tune /etc/default/zramswap so we get a useful pool instead of the
# stock ~256 MB. Only modify the file if the user has not already
# customized PERCENT/ALLOCATION (we treat the shipped commented-out
# values as "untouched defaults"). --no-zram-tune skips this entirely.
if [[ "$tune_zram" -ne 1 ]]; then
    echo "zram tuning skipped (--no-zram-tune)."
elif [[ ! -f "$zramswapfile" ]]; then
    echo "NOTE: $zramswapfile not present; cannot auto-tune zram size."
elif grep -Eq '^[[:space:]]*(PERCENT|ALLOCATION)=' "$zramswapfile"; then
    cur="$(grep -E '^[[:space:]]*(PERCENT|ALLOCATION)=' "$zramswapfile" | head -1)"
    echo "zram already customized ($cur). Leaving $zramswapfile untouched."
else
    cp "$zramswapfile" "${zramswapfile}.backup.$(date +%Y%m%d-%H%M%S)"
    # Replace the commented '# PERCENT=...' if present, else append.
    if grep -Eq '^[[:space:]]*#[[:space:]]*PERCENT=' "$zramswapfile"; then
        sed -i "s|^[[:space:]]*#[[:space:]]*PERCENT=.*|PERCENT=${zram_target_percent}|" "$zramswapfile"
    else
        printf '\n# Added by bos-scripts-collection / configure-usb-boot-optimization.sh\nPERCENT=%s\n' \
            "$zram_target_percent" >> "$zramswapfile"
    fi
    if systemctl restart zramswap.service >/dev/null 2>&1; then
        echo "zramswap retuned to PERCENT=${zram_target_percent} of RAM and restarted."
    else
        echo "WARNING: PERCENT=${zram_target_percent} written but zramswap restart failed."
    fi
fi

# -------------------------------
# 6. Disable noisy background services
# -------------------------------
echo "[8/9] Disabling noisy background services..."
for svc in apport.service whoopsie.service motd-news.service motd-news.timer; do
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        continue
    fi
    # Stop first (best effort), then mask. We mask rather than just disable
    # because units like whoopsie.service and motd-news.service are 'static'
    # (no [Install] section) -- 'disable' is a no-op on them. Mask reliably
    # prevents start via every path (manual, D-Bus activation, dependency).
    systemctl stop "$svc" >/dev/null 2>&1 || true
    if systemctl mask "$svc" >/dev/null 2>&1; then
        echo "  masked $svc"
    else
        echo "  WARNING: could not mask $svc"
    fi
done

# -------------------------------
# 7. Kernel writeback tuning (idempotent drop-in)
# -------------------------------
echo "[9/9] Applying VM writeback sysctl tuning..."
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

echo -n "I/O scheduler ($devbase): "
cat "/sys/block/$devbase/queue/scheduler" 2>/dev/null || echo "n/a"

if [[ "$dev_is_ata" -eq 1 ]]; then
    echo "Write cache ($device):"
    hdparm -W "$device" 2>/dev/null | sed 's/^/  /' \
        || echo "  (hdparm -W query failed)"
else
    echo "Write cache: (skipped -- $device is not an ATA device; transport=$dev_transport)"
fi

echo -n "fstrim.timer: "
if [[ "$dev_rotational" -eq 1 ]]; then
    echo "n/a (rotational disk)"
else
    systemctl is-enabled fstrim.timer 2>/dev/null || echo "(not present)"
fi

echo "zram devices:"
zramctl 2>/dev/null || echo "  (zramctl unavailable)"
echo -n "zram config: "
grep -E '^[[:space:]]*(PERCENT|ALLOCATION)=' "$zramswapfile" 2>/dev/null \
    | head -1 || echo "(stock defaults)"

echo ""
echo "##############################################################"
echo "# $(date) | $scriptname complete. Reboot recommended."
echo "##############################################################"

exit 0
