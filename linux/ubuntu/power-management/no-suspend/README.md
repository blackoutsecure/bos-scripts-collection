# No-Suspend

Scripts and documentation for preventing an Ubuntu host from suspending, hibernating, or hybrid-sleeping.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Background

Always-on Ubuntu endpoints — kiosks, lab workstations, build agents, digital signage, lab probes — must not enter sleep states. Suspend and hibernate can be triggered from several layers (systemd targets, `logind` lid/key handling, GNOME power policy, X11 DPMS), so disabling sleep reliably requires touching all of them.

## Available Scripts

| Script | Description |
|---|---|
| `configure-no-suspend.sh` | Masks systemd sleep targets, configures `logind`, disables GNOME auto-suspend, and disables X11 DPMS |

## How the Script Works

1. Masks `sleep.target`, `suspend.target`, `hibernate.target`, and `hybrid-sleep.target`.
2. Backs up `/etc/systemd/logind.conf` (timestamped) and sets:
   - `HandleSuspendKey=ignore`
   - `HandleLidSwitch=ignore`
   - `HandleLidSwitchDocked=ignore`
3. Restarts `systemd-logind`.
4. For the invoking desktop user (`SUDO_USER`):
   - `gsettings set ... sleep-inactive-ac-type 'nothing'`
   - `gsettings set ... sleep-inactive-battery-type 'nothing'`
   - `gsettings set ... idle-delay 600` (10-minute screen blanking)
5. Disables X11 DPMS and appends `xset -dpms` to the user's `~/.profile` (idempotent).
6. Logs all activity to `/var/log/configure-no-suspend.log`.

## Important: Desktop-Session Steps

`gsettings` and `xset` only affect a logged-in desktop user's session. They are run via `sudo -u "$SUDO_USER"` against that user's D-Bus session. If the script is launched directly as root with no desktop user context (typical for MDM agents), those steps are skipped with a warning and must be applied separately:

- Re-run the script with `sudo` from inside the user's desktop session, or
- Deploy a per-user login hook that runs the equivalent `gsettings`/`xset` commands.

Wayland sessions ignore `xset -dpms`; rely on the GNOME idle-delay setting on Wayland.

## Deployment

### Managed (Ansible, Intune for Linux, Chef, Puppet, Salt)

Deploy `configure-no-suspend.sh` as a one-shot configuration script executed as root.

- All activity is logged to `/var/log/configure-no-suspend.log`.
- Monitor the exit code:
  - `0` — success (configured or already configured)
  - `1` — failure (review log for details)
- A reboot is recommended after success.

### Manual

```bash
sudo bash ./linux/ubuntu/power-management/no-suspend/configure-no-suspend.sh
```

## Verification

```bash
systemctl status sleep.target suspend.target hibernate.target hybrid-sleep.target | grep Loaded
grep -E 'HandleSuspendKey|HandleLidSwitch' /etc/systemd/logind.conf
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
gsettings get org.gnome.desktop.session idle-delay
xset -q | grep -i dpms   # X11 only
```

## Reverting

```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo cp /etc/systemd/logind.conf.backup.<timestamp> /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
gsettings reset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
gsettings reset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
gsettings reset org.gnome.desktop.session idle-delay
sed -i '/^xset -dpms$/d' ~/.profile
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
