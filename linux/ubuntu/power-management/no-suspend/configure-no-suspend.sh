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
#       2 = drift detected (only emitted by --check)
#     A reboot is recommended to ensure all consumers pick up
#     the new logind configuration.
#
#   Manual:
#     sudo bash ./linux/ubuntu/power-management/no-suspend/configure-no-suspend.sh
#
# Modes:
#   apply (default) - reconcile the system to the desired state
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
#
# Variables:
#   appname    - Display name used in log messages
#   log           - Full path of the log file written by this script
#   logindfile    - Path to the systemd logind configuration file
#   logindbackup  - Timestamped backup of $logindfile
#   idledelay     - GNOME screen blanking delay in seconds
#   targetuser    - Desktop user to apply gsettings/xset changes for
# =============================================================

# Define variables

appname="No-Suspend Configuration"
log="/var/log/configure-no-suspend.log"
logindfile="/etc/systemd/logind.conf"
logindbackup="/etc/systemd/logind.conf.backup.$(date +%Y%m%d-%H%M%S)"
idledelay=600
# When run via sudo, SUDO_USER points at the invoking desktop user.
# When run directly by an MDM as root, SUDO_USER will be empty and
# desktop-session steps will be skipped.
targetuser="${SUDO_USER:-}"

# Argument parsing
mode="apply"   # apply | check
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--status)
            mode="check"
            shift
            ;;
        -h|--help)
            cat <<USAGE
Usage: $(basename "$0") [--check]

  --check   Read-only status check; do not modify anything.
            Exit code: 0 = all settings match, 2 = drift detected.

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

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting $appname"
echo "##############################################################"

# Require root for the system-wide changes
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# =============================================================
# --check (read-only status) mode
# Exit 0 = all PASS, 2 = drift detected.
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

    # systemd sleep targets must be masked
    for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        state="$(systemctl is-enabled "$unit" 2>/dev/null | head -n1)"
        if [[ "$state" == "masked" ]]; then
            report PASS "unit $unit" "masked"
        else
            report FAIL "unit $unit" "state=${state:-unknown}"
        fi
    done

    # logind keys
    for kv in "HandleSuspendKey=ignore" "HandleLidSwitch=ignore" "HandleLidSwitchDocked=ignore"; do
        if grep -Eq "^${kv%%=*}=${kv##*=}$" "$logindfile" 2>/dev/null; then
            report PASS "logind $kv" "set"
        else
            report FAIL "logind $kv" "missing or wrong value in $logindfile"
        fi
    done

    # GNOME / X11 desktop checks (only if a desktop user is in scope)
    if [[ -z "$targetuser" || "$targetuser" == "root" ]]; then
        report SKIP "GNOME power settings" "no desktop user (SUDO_USER empty/root)"
        report SKIP "GNOME idle-delay" "no desktop user"
        report SKIP "xset -dpms in ~/.profile" "no desktop user"
    else
        user_uid="$(id -u "$targetuser" 2>/dev/null || echo "")"
        user_home="$(getent passwd "$targetuser" | cut -d: -f6)"
        if [[ -z "$user_uid" ]]; then
            report SKIP "GNOME power settings" "could not resolve uid for $targetuser"
        else
            run_as_user_check() {
                sudo -u "$targetuser" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
                    "$@" 2>/dev/null
            }
            # If gsettings or the GNOME power schema isn't present (server / non-GNOME desktop / no DBus session),
            # there is nothing to check — skip rather than report a false drift.
            if ! run_as_user_check command -v gsettings >/dev/null 2>&1; then
                report SKIP "GNOME power settings" "gsettings not available for $targetuser"
                report SKIP "GNOME idle-delay"     "gsettings not available"
            elif ! run_as_user_check gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.settings-daemon\.plugins\.power$'; then
                report SKIP "GNOME power settings" "GNOME power schema not installed"
                report SKIP "GNOME idle-delay"     "GNOME desktop schema not installed"
            else
                ac="$(run_as_user_check gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type)"
                bat="$(run_as_user_check gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type)"
                idle="$(run_as_user_check gsettings get org.gnome.desktop.session idle-delay | awk '{print $NF}')"
                # Strip surrounding single quotes that gsettings prints around string values.
                ac="${ac//\'/}"
                bat="${bat//\'/}"
                [[ "$ac"  == "nothing" ]] && report PASS "GNOME ac suspend"      "nothing"  || report FAIL "GNOME ac suspend"      "got '${ac:-?}'"
                [[ "$bat" == "nothing" ]] && report PASS "GNOME battery suspend" "nothing"  || report FAIL "GNOME battery suspend" "got '${bat:-?}'"
                [[ "$idle" == "$idledelay" ]] && report PASS "GNOME idle-delay" "$idle" || report FAIL "GNOME idle-delay" "got '${idle:-?}', want $idledelay"
            fi
        fi
        if [[ -n "$user_home" && -f "$user_home/.profile" ]] && grep -q "xset -dpms" "$user_home/.profile"; then
            report PASS "xset -dpms in ~/.profile" "present"
        else
            report FAIL "xset -dpms in ~/.profile" "missing"
        fi
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
echo "# $(date) | $appname complete. Reboot recommended."
echo "##############################################################"

exit 0
