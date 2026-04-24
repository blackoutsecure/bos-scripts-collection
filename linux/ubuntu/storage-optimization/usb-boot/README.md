# USB Boot

Scripts and documentation for tuning an Ubuntu host that boots from a USB-attached disk (USB HDD, USB SSD, or large flash drive).

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Background

USB-attached boot media is much slower at random I/O than internal SATA/NVMe storage and is more sensitive to write amplification. This collection of tuning steps reduces background writes, batches flushes, keeps the disk awake, and offloads short-lived data to RAM.

## Available Scripts

| Script | Description |
|---|---|
| `configure-usb-boot-optimization.sh` | Applies hdparm, udev, fstab, zram, and sysctl tuning for USB-attached root disks |

## How the Script Works

1. Detects (or accepts via `--device`) the parent block device backing `/`.
2. Disables APM / spindown with `hdparm` (skipped if the device does not support hdparm, e.g. plain flash drives).
3. Enables write caching and persists it through a udev rule.
4. Sets read-ahead to 4096 sectors and persists it through a udev rule.
5. Backs up `/etc/fstab` (timestamped) and:
   - Adds `noatime,commit=60` only to the root (`/`) entry, and only if missing.
   - Adds a `tmpfs /tmp` entry, only if missing.
6. Installs and enables `zram-tools` for compressed swap.
7. Disables `apport`, `whoopsie`, and `motd-news` services/timers.
8. Drops VM writeback tuning into `/etc/sysctl.d/60-bos-usb-boot.conf` and reloads.
9. Logs all activity to `/var/log/configure-usb-boot-optimization.log`.

A reboot is recommended after the script completes.

## Usage

### Auto-detect device, prompt for confirmation (manual)

```bash
sudo bash ./linux/ubuntu/storage-optimization/usb-boot/configure-usb-boot-optimization.sh
```

### Explicit device, non-interactive (managed deployment)

```bash
sudo bash ./linux/ubuntu/storage-optimization/usb-boot/configure-usb-boot-optimization.sh --device /dev/sda
```

### Auto-detect, no prompt

```bash
sudo NONINTERACTIVE=1 bash ./linux/ubuntu/storage-optimization/usb-boot/configure-usb-boot-optimization.sh
# or
sudo bash ./linux/ubuntu/storage-optimization/usb-boot/configure-usb-boot-optimization.sh --yes
```

## Deployment

### Managed (Ansible, Intune for Linux, Chef, Puppet, Salt)

- Always pass `--device` (or `NONINTERACTIVE=1`) to avoid the confirmation prompt.
- All activity is logged to `/var/log/configure-usb-boot-optimization.log`.
- Monitor the exit code:
  - `0` — success (configured or already configured)
  - `1` — failure (review log for details)
- Schedule a reboot after success.

## Verification

```bash
mount | awk '$3 == "/" {print $6}'
blockdev --getra /dev/sdX
sudo hdparm -I /dev/sdX | grep -i 'Write cache'
zramctl
systemctl is-enabled zramswap.service
sysctl vm.dirty_background_ratio vm.dirty_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
```

## Reverting

```bash
# fstab
sudo cp /etc/fstab.backup.<timestamp> /etc/fstab

# udev + hdparm config
sudo rm -f /etc/udev/rules.d/99-bos-writecache.rules \
           /etc/udev/rules.d/60-bos-readahead.rules \
           /etc/hdparm.conf

# sysctl
sudo rm -f /etc/sysctl.d/60-bos-usb-boot.conf
sudo sysctl --system

# services
sudo systemctl enable --now apport.service whoopsie.service motd-news.timer

# zram
sudo systemctl disable --now zramswap.service
sudo apt-get remove --purge -y zram-tools

sudo reboot
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
