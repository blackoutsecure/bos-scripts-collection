#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-sublime-text.sh
# Purpose: Downloads and installs the latest stable build of
#          Sublime Text on macOS into /Applications.
#
# Idempotency:
#   If $apppath exists and $forceInstall=false, exits 0 with
#   "already installed". Safe to run multiple times.
#
# Deployment:
#   MDM (Intune, Jamf, Kandji, Mosyle, Workspace ONE):
#     Activity is streamed to both the console and $log.
#     Exit codes:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#
#   Manual:
#     sudo bash ./application-management/sublime-text/install-sublime-text.sh
# =============================================================

# Define variables

tempfile="/tmp/sublime.zip"
appname="Sublime Text"
apppath="/Applications/Sublime Text.app"
log="/var/log/installsublime.log"
unzipdir="/tmp/sublime_extract"
forceInstall="false"
versionapi="https://www.sublimetext.com/updates/4/stable_update_check"

# start logging (console + file)

exec > >(tee -a "$log") 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting install of $appname"
echo "##############################################################"
echo ""

if [ "$forceInstall" = "false" ] && [ -d "$apppath" ]; then
   echo "$(date) | $appname is already installed"
   exit 0
fi

echo "$(date) | Fetching latest version"
version=$(curl --proto '=https' --tlsv1.2 -fsSL "$versionapi" \
   | grep -o '"latest_version": [0-9]*' | grep -o '[0-9]*')

if [ -z "$version" ]; then
   echo "$(date) | Failed to fetch latest version"
   exit 1
fi

echo "$(date) | Latest version: $version"
weburl="https://download.sublimetext.com/sublime_text_build_${version}_mac.zip"
echo "$(date) | Download URL: $weburl"

echo "$(date) | Downloading $appname"
if ! curl --proto '=https' --tlsv1.2 -fsSL -o "$tempfile" "$weburl"; then
   echo "$(date) | Failed to download $appname"
   exit 1
fi

echo "$(date) | Extracting $appname archive"
rm -rf "$unzipdir"
mkdir -p "$unzipdir"
if ! unzip -q "$tempfile" -d "$unzipdir" || [ ! -d "$unzipdir/Sublime Text.app" ]; then
   echo "$(date) | Failed to extract $appname"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | Copying $appname to Applications"
if ! cp -r "$unzipdir/Sublime Text.app" "$apppath"; then
   echo "$(date) | Failed to copy $appname to Applications"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | $appname installed"
echo "$(date) | Cleaning up"
rm -rf "$tempfile" "$unzipdir"
exit 0
