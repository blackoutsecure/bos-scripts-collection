#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-rootless-docker.sh
# Purpose: Installs Docker Engine from Docker's official APT
#          repository and configures it to run in rootless mode
#          for a target non-root user on Ubuntu. Rootless Docker
#          runs the daemon and containers in a user namespace,
#          which removes the need to add the user to the
#          privileged "docker" group and reduces the blast
#          radius of a container escape.
#
# What the script does:
#   1. Installs prerequisites (uidmap, dbus-user-session,
#      slirp4netns, fuse-overlayfs, iptables, curl, gpg).
#   2. Adds Docker's official APT repository (HTTPS, signed by
#      Docker's GPG key pinned to /etc/apt/keyrings) and
#      installs docker-ce, docker-ce-cli, containerd.io, the
#      rootless-extras package, and the buildx/compose plugins.
#   3. Disables and masks the system-wide docker.service and
#      docker.socket so the rootful daemon does not run.
#   4. Allocates subuid/subgid for the target user (if missing)
#      and enables systemd lingering so the rootless daemon
#      starts at boot and survives logout.
#   5. Permits unprivileged user namespaces via a sysctl
#      drop-in (required on Ubuntu 24.04+ AppArmor defaults).
#   6. Runs `dockerd-rootless-setuptool.sh install` as the
#      target user and enables the per-user docker.service.
#   7. Adds DOCKER_HOST + XDG_RUNTIME_DIR to the user's
#      ~/.profile so `docker` CLI talks to the rootless socket
#      by default, then verifies with `docker version`.
#
# Modes:
#   apply (default) - reconcile the system to the desired state
#   --check         - read-only audit. Exit 0 = all PASS, 2 = drift
#
# Detection / Idempotency:
#   - APT repo, signing key, sysctl drop-in, subuid/subgid
#     entries, lingering, and ~/.profile lines are all guarded
#     and only added when missing.
#   - systemctl mask / disable on already-masked units is a
#     no-op.
#   - The setuptool is invoked with `install --force` only when
#     no prior rootless install is detected; otherwise the
#     existing user service is just (re)started.
#   Safe to run multiple times.
#
# Security notes:
#   - Script must run as root (EUID 0). The Docker repo is
#     pinned by signed-by= to a dedicated keyring; the apt key
#     is fetched over HTTPS only.
#   - The target user MUST be a real, non-root local account.
#     Service / system accounts (UID < 1000) are rejected.
#   - The system-wide rootful daemon is disabled AND masked to
#     prevent accidental privileged container execution.
#   - kernel.apparmor_restrict_unprivileged_userns=0 is
#     required for rootless containers on Ubuntu 24.04+. This
#     loosens an AppArmor hardening default; review against
#     your threat model before deploying broadly.
#   - cap_net_bind_service is granted to /usr/bin/rootlesskit
#     so rootless containers can publish ports < 1024. Omit by
#     passing --no-privileged-ports.
#
# Deployment:
#   Managed (Ansible, Intune for Linux, Chef, Puppet, Salt):
#     Run as root. Pass the target user via the first
#     positional argument or TARGET_USER:
#       sudo ./install-rootless-docker.sh builder
#       sudo TARGET_USER=builder ./install-rootless-docker.sh
#     All activity is logged to $log. Exit codes:
#       0 = success (configured or already configured)
#       1 = failure (review log for details)
#       2 = drift detected (only emitted by --check)
#
#   Manual:
#     sudo bash ./linux/ubuntu/application-management/rootless-docker/install-rootless-docker.sh "$USER"
#
# Variables:
#   appname  - Display name used in log messages
#   log         - Full path of the log file written by this script
#   targetuser  - Non-root user that will own the rootless daemon
#   keyring     - Pinned APT keyring file for Docker's signing key
#   listfile    - APT sources list file for the Docker repo
#   sysctlfile  - Sysctl drop-in for unprivileged userns
# =============================================================

set -o pipefail
umask 022

# Define variables

appname="Rootless Docker Configuration"
log="/var/log/install-rootless-docker.log"
keyring="/etc/apt/keyrings/docker.gpg"
listfile="/etc/apt/sources.list.d/docker.list"
sysctlfile="/etc/sysctl.d/60-bos-rootless-docker.conf"

# Argument parsing
mode="apply"                # apply | check
targetuser="${TARGET_USER:-${SUDO_USER:-}}"
allow_privileged_ports=1    # 0 = do not setcap rootlesskit
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--status)
            mode="check"
            shift
            ;;
        --user)
            targetuser="$2"
            shift 2
            ;;
        --user=*)
            targetuser="${1#*=}"
            shift
            ;;
        --no-privileged-ports)
            allow_privileged_ports=0
            shift
            ;;
        -h|--help)
            cat <<USAGE
Usage: $(basename "$0") [--user <name>] [--check] [--no-privileged-ports]

  <name> may also be passed as the first positional argument or via
  the TARGET_USER environment variable. It must be a non-root local
  account with UID >= 1000.

  --check                  Read-only audit; do not modify anything.
                           Exit code: 0 = all PASS, 2 = drift detected.
  --no-privileged-ports    Do not grant cap_net_bind_service to
                           /usr/bin/rootlesskit (rootless containers
                           will not be able to publish ports < 1024).

Exit codes:
  0  apply OK / already configured (apply mode), or all checks PASS (--check)
  1  failure (review log for details)
  2  drift detected (--check only)
USAGE
            exit 0
            ;;
        -*)
            echo "ERROR: unknown argument '$1' (try --help)" >&2
            exit 1
            ;;
        *)
            # First bare argument is the target user.
            if [[ -z "${targetuser_from_arg:-}" ]]; then
                targetuser="$1"
                targetuser_from_arg=1
                shift
            else
                echo "ERROR: unexpected argument '$1' (try --help)" >&2
                exit 1
            fi
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

# Require root for the system-wide install steps.
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (EUID 0)."
    exit 1
fi

# Validate target user.
if [[ -z "$targetuser" || "$targetuser" == "root" ]]; then
    echo "ERROR: A non-root target user is required."
    echo "       Pass it as: sudo $0 <username>"
    exit 1
fi
if [[ ! "$targetuser" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: Invalid username '$targetuser'."
    exit 1
fi
if ! id "$targetuser" >/dev/null 2>&1; then
    echo "ERROR: User '$targetuser' does not exist."
    exit 1
fi

user_uid="$(id -u "$targetuser")"
user_gid="$(id -gn "$targetuser")"
user_home="$(getent passwd "$targetuser" | cut -d: -f6)"
docker_host="unix:///run/user/${user_uid}/docker.sock"

if [[ "$user_uid" -lt 1000 ]]; then
    echo "ERROR: User '$targetuser' has UID $user_uid (< 1000)."
    echo "       Refusing to configure rootless Docker for a system account."
    exit 1
fi
if [[ -z "$user_home" || ! -d "$user_home" ]]; then
    echo "ERROR: Home directory for '$targetuser' not found."
    exit 1
fi

echo "Target user : $targetuser (uid=$user_uid)"
echo "Home dir    : $user_home"
echo "DOCKER_HOST : $docker_host"

run_as_user() {
    sudo -H -u "$targetuser" \
        XDG_RUNTIME_DIR="/run/user/${user_uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_uid}/bus" \
        PATH="/usr/bin:/usr/sbin:/bin:/sbin:${user_home}/bin" \
        "$@"
}

# =============================================================
# --check (read-only status) mode
# Exit 0 = all PASS, 2 = drift detected.
# =============================================================
if [[ "$mode" == "check" ]]; then
    echo ""
    echo "=== --check (read-only) ==="
    pass=0; fail=0
    report() {
        local verdict="$1" name="$2" detail="$3"
        printf "  [%-4s] %-36s %s\n" "$verdict" "$name" "$detail"
        case "$verdict" in PASS) ((pass++));; FAIL) ((fail++));; esac
    }

    for pkg in docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras uidmap; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            report PASS "package $pkg" "installed"
        else
            report FAIL "package $pkg" "missing"
        fi
    done

    for unit in docker.service docker.socket; do
        state="$(systemctl is-enabled "$unit" 2>/dev/null | head -n1)"
        if [[ "$state" == "masked" ]]; then
            report PASS "system unit $unit" "masked"
        else
            report FAIL "system unit $unit" "state=${state:-unknown}"
        fi
    done

    if grep -q "^${targetuser}:" /etc/subuid && grep -q "^${targetuser}:" /etc/subgid; then
        report PASS "subuid/subgid for $targetuser" "allocated"
    else
        report FAIL "subuid/subgid for $targetuser" "missing"
    fi

    if loginctl show-user "$targetuser" 2>/dev/null | grep -q "Linger=yes"; then
        report PASS "lingering for $targetuser" "enabled"
    else
        report FAIL "lingering for $targetuser" "disabled"
    fi

    if [[ -f "$sysctlfile" ]] && sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null | grep -q '^0$'; then
        report PASS "userns sysctl" "permitted"
    else
        report FAIL "userns sysctl" "drop-in or runtime value missing"
    fi

    if run_as_user systemctl --user is-enabled docker.service >/dev/null 2>&1; then
        report PASS "user docker.service" "enabled"
    else
        report FAIL "user docker.service" "not enabled for $targetuser"
    fi

    if run_as_user env DOCKER_HOST="$docker_host" docker version >/dev/null 2>&1; then
        report PASS "docker socket reachable" "$docker_host"
    else
        report FAIL "docker socket reachable" "$docker_host did not respond"
    fi

    echo ""
    echo "Summary: $pass PASS / $fail FAIL"
    if [[ "$fail" -gt 0 ]]; then
        echo "DRIFT DETECTED. Re-run without --check to reconcile."
        exit 2
    fi
    echo "All applicable settings already configured."
    exit 0
fi

# -------------------------------
# 1. Install prerequisites
# -------------------------------
echo "[1/7] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update; then
    echo "ERROR: apt-get update failed."
    exit 1
fi
if ! apt-get install -y \
        ca-certificates curl gnupg \
        uidmap dbus-user-session slirp4netns fuse-overlayfs iptables; then
    echo "ERROR: Failed to install prerequisite packages."
    exit 1
fi

# -------------------------------
# 2. Add Docker repo and install Docker Engine + rootless extras
# -------------------------------
echo "[2/7] Configuring Docker APT repository..."
codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
if [[ -z "$codename" ]]; then
    echo "ERROR: Could not determine Ubuntu codename from /etc/os-release."
    exit 1
fi

if [[ ! -s "$keyring" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL --proto '=https' --tlsv1.2 \
            "https://download.docker.com/linux/ubuntu/gpg" \
            | gpg --dearmor -o "$keyring"; then
        echo "ERROR: Failed to fetch or import Docker GPG key."
        exit 1
    fi
    chmod a+r "$keyring"
fi

repo_line="deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu ${codename} stable"
if ! grep -Fxq "$repo_line" "$listfile" 2>/dev/null; then
    echo "$repo_line" > "$listfile"
    chmod 0644 "$listfile"
fi

if ! apt-get update; then
    echo "ERROR: apt-get update failed after adding Docker repo."
    exit 1
fi
if ! apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-ce-rootless-extras \
        docker-buildx-plugin docker-compose-plugin; then
    echo "ERROR: Failed to install Docker packages."
    exit 1
fi

# -------------------------------
# 3. Disable the system-wide rootful daemon
# -------------------------------
echo "[3/7] Disabling and masking system-wide docker.service / docker.socket..."
systemctl disable --now docker.service docker.socket 2>/dev/null || true
systemctl mask docker.service docker.socket 2>/dev/null || true

# -------------------------------
# 4. Ensure subuid/subgid + lingering for the target user
# -------------------------------
echo "[4/7] Ensuring subuid/subgid allocations and lingering..."
if ! grep -q "^${targetuser}:" /etc/subuid || ! grep -q "^${targetuser}:" /etc/subgid; then
    if ! usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$targetuser"; then
        echo "ERROR: Failed to allocate subuid/subgid range for $targetuser."
        exit 1
    fi
fi

if ! loginctl show-user "$targetuser" 2>/dev/null | grep -q "Linger=yes"; then
    if ! loginctl enable-linger "$targetuser"; then
        echo "ERROR: Failed to enable lingering for $targetuser."
        exit 1
    fi
fi

# Ensure the user's runtime dir exists so `systemctl --user` works
# from this non-login shell.
runtime_dir="/run/user/${user_uid}"
if [[ ! -d "$runtime_dir" ]]; then
    install -d -m 0700 -o "$targetuser" -g "$user_gid" "$runtime_dir"
fi

# -------------------------------
# 5. Permit unprivileged user namespaces (Ubuntu 24.04+)
# -------------------------------
echo "[5/7] Writing $sysctlfile..."
cat > "$sysctlfile" <<'SYSCTL'
# Required for rootless container runtimes (Docker rootless,
# Podman) on Ubuntu 24.04+ where AppArmor restricts unprivileged
# user namespace creation by default.
kernel.apparmor_restrict_unprivileged_userns = 0
SYSCTL
chmod 0644 "$sysctlfile"
sysctl --system >/dev/null || true

# -------------------------------
# 6. Install rootless Docker for the target user
# -------------------------------
echo "[6/7] Installing rootless Docker for $targetuser..."

# Wait briefly for the user systemd instance to be reachable
# (started on demand by the linger logic above).
for _ in 1 2 3 4 5; do
    if run_as_user systemctl --user list-units >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if run_as_user systemctl --user is-enabled docker.service >/dev/null 2>&1; then
    run_as_user systemctl --user restart docker.service || true
else
    if ! run_as_user /usr/bin/dockerd-rootless-setuptool.sh install --force; then
        echo "ERROR: dockerd-rootless-setuptool.sh install failed for $targetuser."
        exit 1
    fi
fi

run_as_user systemctl --user enable docker.service || true
run_as_user systemctl --user start  docker.service || true

if [[ "$allow_privileged_ports" -eq 1 ]] \
   && command -v setcap >/dev/null 2>&1 \
   && [[ -x /usr/bin/rootlesskit ]]; then
    setcap cap_net_bind_service=ep /usr/bin/rootlesskit || true
fi

# -------------------------------
# 7. Configure user shell environment + verify
# -------------------------------
echo "[7/7] Configuring user shell environment and verifying..."
profile="${user_home}/.profile"
if [[ -f "$profile" ]] && ! grep -q "DOCKER_HOST=${docker_host}" "$profile"; then
    cat >> "$profile" <<EOF

# Added by install-rootless-docker.sh
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
export PATH="/usr/bin:\$PATH"
export DOCKER_HOST=${docker_host}
EOF
    chown "$targetuser":"$user_gid" "$profile"
fi

if ! run_as_user env DOCKER_HOST="$docker_host" docker version >/dev/null 2>&1; then
    echo "ERROR: 'docker version' failed against $docker_host."
    echo "       Inspect: sudo -u $targetuser XDG_RUNTIME_DIR=$runtime_dir \\"
    echo "                systemctl --user status docker"
    echo "       Logs:    sudo -u $targetuser XDG_RUNTIME_DIR=$runtime_dir \\"
    echo "                journalctl --user -u docker --no-pager"
    exit 1
fi

echo ""
echo "##############################################################"
echo "# $(date) | $appname completed successfully"
echo "# User '$targetuser' should open a new shell (or run"
echo "# 'source ~/.profile') to pick up DOCKER_HOST."
echo "##############################################################"
exit 0
