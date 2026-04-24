#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-plex-media-server.sh
# Purpose: Automatically downloads and installs the latest
#          version of Plex Media Server on macOS.
#
# The script queries the Plex public downloads API to obtain
# the current macOS release URL, downloads the .zip archive,
# extracts it, and copies the app bundle to /Applications.
#
# Detection / Idempotency:
#   If Plex Media Server is already installed at $apppath and
#   $forceInstall is "false", the script exits immediately
#   with code 0 and logs "already installed". It is safe to
#   run multiple times without side effects.
#
# Deployment:
#   MDM (Intune / Company Portal, Jamf, Kandji, Mosyle,
#        Workspace ONE, or any MDM that runs shell scripts):
#     Deploy as a managed shell script or custom app install.
#     All activity is logged to $log for review.
#     Monitor the exit code returned to your MDM console:
#       0 = success (installed or already present)
#       1 = failure (review log for details)
#
#   Manual:
#     sudo bash ./application-management/plex-media-server/install-plex-media-server.sh
#
# Variables:
#   tempfile      - Temporary path where the .zip download is saved
#   appname       - Display name used in log messages
#   apppath       - Expected installation path; used to detect
#                   whether Plex Media Server is already installed
#   log           - Full path of the log file written by this script
#   unzipdir      - Temporary directory used to extract the .zip archive
#   forceInstall  - Set to "true" to reinstall even if Plex Media
#                   Server is already present (useful for forced upgrades)
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

# start logging

exec 1>> "$log" 2>&1

# Begin Script Body

echo ""
echo "##############################################################"
echo "# $(date) | Starting install of $appname"
echo "############################################################"
echo ""

# Check if app already exists
if [ "$forceInstall" = "false" ] && [ -d "$apppath" ]; then
   echo "$(date) | $appname is already installed"
   exit 0
fi

# Fetch the Plex downloads JSON and extract the macOS release URL
echo "$(date) | Fetching latest version from Plex API"
plexjson=$(curl -s "$plexapi")

if [ -z "$plexjson" ]; then
   echo "$(date) | Failed to fetch Plex downloads API"
   exit 1
fi

# Extract the macOS download URL (matches the /macos/ path in the releases)
weburl=$(echo "$plexjson" | grep -o 'https://downloads\.plex\.tv/plex-media-server-new/[^"]*\/macos\/[^"]*\.zip' | head -1)

if [ -z "$weburl" ]; then
   echo "$(date) | Failed to extract macOS download URL from API response"
   exit 1
fi

# Extract version from the MacOS section of the JSON
version=$(echo "$plexjson" | grep -o '"MacOS":{[^}]*"version":"[^"]*"' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "$(date) | Latest version: $version"
echo "$(date) | Download URL: $weburl"

# Download Plex Media Server

echo "$(date) | Downloading $appname"
curl -L -f -o "$tempfile" "$weburl"

if [ "$?" != "0" ]; then
   echo "$(date) | Failed to download $appname"
   exit 1
fi

# Extract and install

echo "$(date) | Extracting $appname archive"
rm -rf "$unzipdir"
mkdir -p "$unzipdir"
unzip -q "$tempfile" -d "$unzipdir"

if [ "$?" = "0" ] && [ -d "$unzipdir/Plex Media Server.app" ]; then
   echo "$(date) | Copying $appname to Applications"
   cp -r "$unzipdir/Plex Media Server.app" "$apppath"

   if [ "$?" = "0" ]; then
      echo "$(date) | $appname Installed"
      echo "$(date) | Cleaning Up"
      rm -rf "$tempfile"
      rm -rf "$unzipdir"
      exit 0
   else
      echo "$(date) | Failed to copy $appname to Applications"
      rm -rf "$tempfile"
      rm -rf "$unzipdir"
      exit 1
   fi
else
   echo "$(date) | Failed to extract $appname"
   rm -rf "$tempfile"
   rm -rf "$unzipdir"
   exit 1
fi
