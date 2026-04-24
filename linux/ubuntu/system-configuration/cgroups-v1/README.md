# Cgroups v1

Scripts and documentation for switching Ubuntu back to the legacy cgroups v1 hierarchy.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Background

Modern Ubuntu releases default to **cgroups v2** (the unified hierarchy). Some workloads still require **cgroups v1**, including:

- Older container runtimes and Docker versions
- Some Kubernetes node images and CNI plugins
- Legacy Java workloads relying on cgroup v1 cpuset/memory layout
- Certain monitoring / APM agents

This is achieved by adding the kernel parameter `systemd.unified_cgroup_hierarchy=0` to GRUB and rebooting.

## Available Scripts

| Script | Description |
|---|---|
| `configure-cgroups-v1.sh` | Backs up `/etc/default/grub`, appends `systemd.unified_cgroup_hierarchy=0`, and runs `update-grub` |

## How the Script Works

1. Verifies it is running as root and that `/etc/default/grub` exists.
2. Creates a timestamped backup at `/etc/default/grub.backup.<timestamp>`.
3. If the parameter is not already present, inserts `systemd.unified_cgroup_hierarchy=0` at the start of `GRUB_CMDLINE_LINUX="..."`.
4. Runs `update-grub` to regenerate the boot loader configuration.
5. Logs all activity to `/var/log/configure-cgroups-v1.log`.

A **reboot is required** to apply the change.

## Deployment

### Managed (Ansible, Intune for Linux, Chef, Puppet, Salt)

Deploy `configure-cgroups-v1.sh` as a one-shot configuration script executed as root.

- All activity is logged to `/var/log/configure-cgroups-v1.log`.
- Monitor the exit code:
  - `0` — success (configured or already configured)
  - `1` — failure (review log for details)
- Schedule a reboot after the script reports success.

### Manual

```bash
sudo bash ./linux/ubuntu/system-configuration/cgroups-v1/configure-cgroups-v1.sh
sudo reboot
```

## Verification

After reboot:

```bash
cat /proc/cmdline | grep systemd.unified_cgroup_hierarchy
stat -fc %T /sys/fs/cgroup/
```

- `/proc/cmdline` should contain `systemd.unified_cgroup_hierarchy=0`.
- `stat -fc %T /sys/fs/cgroup/` should report `tmpfs` (cgroups v1) instead of `cgroup2fs`.

## Reverting

To revert, restore the most recent backup and update GRUB:

```bash
sudo cp /etc/default/grub.backup.<timestamp> /etc/default/grub
sudo update-grub
sudo reboot
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
