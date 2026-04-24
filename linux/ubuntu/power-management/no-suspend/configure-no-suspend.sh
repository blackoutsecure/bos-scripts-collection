#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  configure-no-suspend.sh
# Purpose: Prevents an Ubuntu host from suspending, hibernating,
#          or hybrid-sleeping. Useful for kiosk machines, lab
#          workstations, build agents, signage, or any always-on
#          endpoint where sleep states cause outages.
#
# What the script does:
#   1. Masks the systemd sleep, suspend, hibernate, and
#      hybrid-sleep targets so nothing can trigger them.
#   2. Configures /etc/systemd/logind.conf to ignore the suspend
#      key and lid-close events (docked and undocked).
#   3. Restarts systemd-logind to apply the logind changes.
#   4. Disables GNOME auto-suspend on AC and battery for the
#      desktop user (only when run inside a desktop session).
#   5. Sets the GNOME screen blanking delay to 10 minutes.
#   6. Disables DPMS screen power-off (X11 only) and makes the
#      change persistent in the user's ~/.profile.
#
# Detection / Idempotency:
#   - systemd targets are masked unconditionally; re-masking an
#     already-masked unit is a no-op.
#   - logind edits use anchored sed expressions so re-running
#     the script does not duplicate or corrupt entries.
#   - The ~/.profile xset entry is added only if missing.
#   Safe to run multiple times.
#
# Important notes:
#   - GNOME (`gsettings`) and X11 (`xset`) commands only work
#     inside an active desktop session for the logged-in user.
#     When this script is run as root by an MDM/CM tool with no
#     user session, those steps are skipped and a warning is
#     logged. Re-run the user-session portion as the desktop
#     user, or deploy the gsettings/xset steps via a per-user
#     login hook.
#   - Wayland sessions ignore `xset -dpms`; the gsettings
#     screen-blank delay is the supported control there.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt):
#     Run as root. The systemd and logind portions apply
#     system-wide. All activity is logged to $log. Exit codes:
#       0 = success (configured or already configured)
#       1 = failure (review log for details)
#     A reboot is recommended to ensure all consumers pick up
#     the new logind configuration.
#
#   Manual:
#     sudo bash ./linux/ubuntu/power-management/no-suspend/configure-no-suspend.sh
#
# Variables:
#   scriptname    - Display name used in log messages
#   log           - Full path of the log file written by this script
#   logindfile    - Path to the systemd logind configuration file
#   logindbackup  - Timestamped backup of $logindfile
#   idledelay     - GNOME screen blanking delay in seconds
#   targetuser    - Desktop user to apply gsettings/xset changes for
# =============================================================

# Define variables

scriptname="No-Suspend Configuration"
log="/var/log/configure-no-suspend.log"
logindfile="/etc/systemd/logind.conf"
logindbackup="/etc/systemd/logind.conf.backup.$(date +%Y%m%d-%H%M%S)"
idledelay=600
# When run via sudo, SUDO_USER points at the invoking desktop user.
# When run directly by an MDM as root, SUDO_USER will be empty and
# desktop-session steps will be skipped.
targetuser="${SUDO_USER:-}"

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

# Require root for the system-wide changes
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# -------------------------------
# 1. Mask system suspend targets
# -------------------------------
echo "[1/6] Masking systemd sleep targets..."
if ! systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target; then
    echo "ERROR: Failed to mask one or more sleep targets."
    exit 1
fi
echo "sleep / suspend / hibernate / hybrid-sleep targets masked."

# -------------------------------
# 2. Configure logind
# -------------------------------
echo "[2/6] Updating $logindfile..."
if [[ ! -f "$logindfile" ]]; then
    echo "ERROR: $logindfile not found."
    exit 1
fi

if ! cp "$logindfile" "$logindbackup"; then
    echo "ERROR: Failed to back up $logindfile to $logindbackup."
    exit 1
fi
echo "Backup created at $logindbackup"

set_logind_key() {
    local key="$1"
    local value="$2"
    if grep -Eq "^#?${key}=" "$logindfile"; then
        sed -i "s|^#\?${key}=.*|${key}=${value}|" "$logindfile"
    else
        # Append under the [Login] section, or at end of file as fallback.
        if grep -q "^\[Login\]" "$logindfile"; then
            sed -i "/^\[Login\]/a ${key}=${value}" "$logindfile"
        else
            printf '\n[Login]\n%s=%s\n' "$key" "$value" >> "$logindfile"
        fi
    fi
}

set_logind_key "HandleSuspendKey"      "ignore"
set_logind_key "HandleLidSwitch"       "ignore"
set_logind_key "HandleLidSwitchDocked" "ignore"

if ! systemctl restart systemd-logind; then
    echo "WARNING: Failed to restart systemd-logind. A reboot will pick up changes."
fi
echo "logind configured."

# -------------------------------
# 3 & 4. GNOME desktop session settings (gsettings)
# -------------------------------
echo "[3/6] Configuring GNOME power and idle settings..."
if [[ -z "$targetuser" || "$targetuser" == "root" ]]; then
    echo "WARNING: No desktop user detected (SUDO_USER is empty or root)."
    echo "         Skipping gsettings steps. Re-run the gsettings/xset"
    echo "         portion inside the user's desktop session, or deploy"
    echo "         them via a per-user login hook."
else
    user_uid="$(id -u "$targetuser" 2>/dev/null || echo "")"
    if [[ -z "$user_uid" ]]; then
        echo "WARNING: Could not resolve UID for user '$targetuser'. Skipping gsettings."
    else
        run_as_user() {
            sudo -u "$targetuser" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
                "$@"
        }

        run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' \
            && echo "GNOME AC auto-suspend disabled." \
            || echo "WARNING: Failed to set sleep-inactive-ac-type."

        run_as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' \
            && echo "GNOME battery auto-suspend disabled." \
            || echo "WARNING: Failed to set sleep-inactive-battery-type."

        echo "[4/6] Setting screen blanking delay to ${idledelay} seconds..."
        run_as_user gsettings set org.gnome.desktop.session idle-delay "$idledelay" \
            && echo "Screen blanking delay set." \
            || echo "WARNING: Failed to set idle-delay."
    fi
fi

# -------------------------------
# 5. Disable DPMS (X11 only) and persist in ~/.profile
# -------------------------------
echo "[5/6] Disabling DPMS screen power-off (X11 sessions only)..."
if [[ -n "$targetuser" && "$targetuser" != "root" ]]; then
    user_home="$(getent passwd "$targetuser" | cut -d: -f6)"
    if [[ -n "$user_home" && -d "$user_home" ]]; then
        # Best-effort live disable; will fail silently on Wayland or with no DISPLAY.
        sudo -u "$targetuser" bash -c 'xset -dpms 2>/dev/null || true'

        profile="${user_home}/.profile"
        if [[ -f "$profile" ]] && grep -q "xset -dpms" "$profile"; then
            echo "xset -dpms entry already present in $profile."
        else
            echo "xset -dpms" | sudo -u "$targetuser" tee -a "$profile" >/dev/null
            echo "Appended 'xset -dpms' to $profile."
        fi
    else
        echo "WARNING: Could not resolve home directory for '$targetuser'. Skipping DPMS persistence."
    fi
else
    echo "Skipping DPMS step (no desktop user context)."
fi

# -------------------------------
# 6. Verification
# -------------------------------
echo "[6/6] Verification:"

echo "Systemd targets (expect 'Loaded: masked'):"
for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    line="$(systemctl status "$unit" 2>/dev/null | grep -m1 Loaded || true)"
    printf '  %-22s %s\n' "$unit" "$line"
done

echo ""
echo "logind settings:"
grep -E '^(HandleSuspendKey|HandleLidSwitch|HandleLidSwitchDocked)=' "$logindfile" || true

if [[ -n "$targetuser" && "$targetuser" != "root" && -n "${user_uid:-}" ]]; then
    echo ""
    echo "GNOME power settings for '$targetuser':"
    echo -n "  AC suspend:      "
    run_as_user gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "n/a"
    echo -n "  Battery suspend: "
    run_as_user gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "n/a"
    echo -n "  Idle delay:      "
    run_as_user gsettings get org.gnome.desktop.session idle-delay 2>/dev/null || echo "n/a"
fi

echo ""
echo "##############################################################"
echo "# $(date) | $scriptname complete. Reboot recommended."
echo "##############################################################"

exit 0
