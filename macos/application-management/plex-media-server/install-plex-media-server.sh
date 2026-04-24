#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-plex-media-server.sh
# Purpose: Downloads and installs the latest version of
#          Plex Media Server on macOS into /Applications.
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
#     sudo bash ./application-management/plex-media-server/install-plex-media-server.sh
# =============================================================

# Define variables

tempfile="/tmp/plex.zip"
appname="Plex Media Server"
apppath="/Applications/Plex Media Server.app"
log="/var/log/installplex.log"
unzipdir="/tmp/plex_extract"
forceInstall="false"

# Plex public downloads API (category 5 = Plex Media Server)
plexapi="https://plex.tv/api/downloads/5.json"

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

echo "$(date) | Fetching latest version from Plex API"
plexjson=$(curl --proto '=https' --tlsv1.2 -fsSL "$plexapi")

if [ -z "$plexjson" ]; then
   echo "$(date) | Failed to fetch Plex downloads API"
   exit 1
fi

weburl=$(echo "$plexjson" | grep -o 'https://downloads\.plex\.tv/plex-media-server-new/[^"]*\/macos\/[^"]*\.zip' | head -1)

if [ -z "$weburl" ]; then
   echo "$(date) | Failed to extract macOS download URL from API response"
   exit 1
fi

version=$(echo "$plexjson" | grep -o '"MacOS":{[^}]*"version":"[^"]*"' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "$(date) | Latest version: $version"
echo "$(date) | Download URL: $weburl"

echo "$(date) | Downloading $appname"
if ! curl --proto '=https' --tlsv1.2 -fsSL -o "$tempfile" "$weburl"; then
   echo "$(date) | Failed to download $appname"
   exit 1
fi

echo "$(date) | Extracting $appname archive"
rm -rf "$unzipdir"
mkdir -p "$unzipdir"
if ! unzip -q "$tempfile" -d "$unzipdir" || [ ! -d "$unzipdir/Plex Media Server.app" ]; then
   echo "$(date) | Failed to extract $appname"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | Copying $appname to Applications"
if ! cp -r "$unzipdir/Plex Media Server.app" "$apppath"; then
   echo "$(date) | Failed to copy $appname to Applications"
   rm -rf "$tempfile" "$unzipdir"
   exit 1
fi

echo "$(date) | $appname installed"
echo "$(date) | Cleaning up"
rm -rf "$tempfile" "$unzipdir"
exit 0
