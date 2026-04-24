#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-homebrew.sh
# Purpose: Automatically installs Homebrew (the macOS package
#          manager) using the official install script.
#
# The script checks whether the `brew` command is already
# available, and if not, runs the official Homebrew installer
# from https://brew.sh. On Apple Silicon Macs Homebrew installs
# to /opt/homebrew; on Intel Macs it installs to /usr/local.
#
# Detection / Idempotency:
#   If Homebrew is already installed (the `brew` executable is
#   found at /opt/homebrew/bin/brew or /usr/local/bin/brew) and
#   $forceInstall is "false", the script exits immediately
#   with code 0 and logs "already installed". It is safe to
#   run multiple times without side effects.
#
# Deployment:
#   MDM (Intune / Company Portal, Jamf, Kandji, Mosyle,
#        Workspace ONE, or any MDM that runs shell scripts):
#     Deploy as a managed shell script or custom app install.
#     All activity is logged to $log for review.
#     The installer runs non-interactively (NONINTERACTIVE=1).
#     Monitor the exit code returned to your MDM console:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#
#   Manual:
#     sudo bash ./application-management/homebrew/install-homebrew.sh
#
# Variables:
#   appname       - Display name used in log messages
#   log           - Full path of the log file written by this script
#   forceInstall  - Set to "true" to reinstall even if Homebrew
#                   is already present (useful for forced upgrades)
#   brewurl       - URL of the official Homebrew install script
# =============================================================

# Define variables

appname="Homebrew"
log="/var/log/installhomebrew.log"
forceInstall="false"
brewurl="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# start logging

exec 1>> "$log" 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting install of $appname"
echo "############################################################"
echo ""

# Check if Homebrew is already installed
# Homebrew installs to /opt/homebrew on Apple Silicon and /usr/local on Intel
if [ "$forceInstall" = "false" ]; then
   if [ -x "/opt/homebrew/bin/brew" ] || [ -x "/usr/local/bin/brew" ]; then
      echo "$(date) | $appname is already installed"
      exit 0
   fi
fi

# Download and run the official Homebrew install script
# NONINTERACTIVE=1 prevents the installer from waiting for user input (required for MDM)
echo "$(date) | Downloading and running the official $appname installer"
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$brewurl")"

if [ "$?" != "0" ]; then
   echo "$(date) | Failed to install $appname"
   exit 1
fi

# Verify installation succeeded by checking for the brew binary
if [ -x "/opt/homebrew/bin/brew" ] || [ -x "/usr/local/bin/brew" ]; then
   echo "$(date) | $appname Installed"

   # Determine the correct brew path and add to current session
   if [ -x "/opt/homebrew/bin/brew" ]; then
      brewpath="/opt/homebrew/bin/brew"
   else
      brewpath="/usr/local/bin/brew"
   fi

   echo "$(date) | Brew path: $brewpath"
   echo "$(date) | Brew version: $("$brewpath" --version | head -1)"
   exit 0
else
   echo "$(date) | $appname installer completed but brew binary not found"
   exit 1
fi
