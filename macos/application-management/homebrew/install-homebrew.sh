#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-homebrew.sh
# Purpose: Installs Homebrew on macOS using the official
#          install script. Apple Silicon installs to
#          /opt/homebrew; Intel installs to /usr/local.
#
# Idempotency:
#   If `brew` is already present and $forceInstall=false, exits
#   0 with "already installed". Safe to run multiple times.
#
# Deployment:
#   MDM (Intune, Jamf, Kandji, Mosyle, Workspace ONE):
#     Activity is streamed to both the console and $log.
#     The Homebrew installer is invoked with NONINTERACTIVE=1.
#     Exit codes:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#
#   Manual:
#     sudo bash ./application-management/homebrew/install-homebrew.sh
# =============================================================

# Define variables

appname="Homebrew"
log="/var/log/installhomebrew.log"
forceInstall="false"
brewurl="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# start logging (console + file)

exec > >(tee -a "$log") 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting install of $appname"
echo "##############################################################"
echo ""

if [ "$forceInstall" = "false" ]; then
   if [ -x "/opt/homebrew/bin/brew" ] || [ -x "/usr/local/bin/brew" ]; then
      echo "$(date) | $appname is already installed"
      exit 0
   fi
fi

echo "$(date) | Downloading and running the official $appname installer"
installer=$(curl --proto '=https' --tlsv1.2 -fsSL "$brewurl")
if [ -z "$installer" ]; then
   echo "$(date) | Failed to fetch $appname installer"
   exit 1
fi
if ! NONINTERACTIVE=1 /bin/bash -c "$installer"; then
   echo "$(date) | Failed to install $appname"
   exit 1
fi

if [ -x "/opt/homebrew/bin/brew" ]; then
   brewpath="/opt/homebrew/bin/brew"
elif [ -x "/usr/local/bin/brew" ]; then
   brewpath="/usr/local/bin/brew"
else
   echo "$(date) | $appname installer completed but brew binary not found"
   exit 1
fi

echo "$(date) | $appname installed"
echo "$(date) | Brew path: $brewpath"
echo "$(date) | Brew version: $("$brewpath" --version | head -1)"
exit 0
