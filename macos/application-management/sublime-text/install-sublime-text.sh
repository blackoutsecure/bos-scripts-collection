#!/bin/bash

# =============================================================
# Copyright (c) 2026 Blackout Secure
# https://blackoutsecure.app
#
# Script:  install-sublime-text.sh
# Purpose: Automatically downloads and installs the latest
#          stable build of Sublime Text on macOS.
#
# The script queries the Sublime Text update API to obtain the
# current stable build number, constructs the download URL,
# downloads the .zip archive, extracts it, and copies the app
# bundle to /Applications.
#
# Detection / Idempotency:
#   If Sublime Text is already installed at $apppath and
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
#     sudo bash ./application-management/sublime-text/install-sublime-text.sh
#
# Variables:
#   tempfile      - Temporary path where the .zip download is saved
#   appname       - Display name used in log messages
#   apppath       - Expected installation path; used to detect
#                   whether Sublime Text is already installed
#   log           - Full path of the log file written by this script
#   mountpoint    - Temporary mount point reserved for .dmg handling
#   unzipdir      - Temporary directory used to extract the .zip archive
#   forceInstall  - Set to "true" to reinstall even if Sublime Text
#                   is already present (useful for forced upgrades)
# =============================================================

# Define variables

tempfile="/tmp/sublime.zip"
appname="Sublime Text"
apppath="/Applications/Sublime Text.app"
log="/var/log/installsublime.log"
mountpoint="/tmp/sublime_mount"
unzipdir="/tmp/sublime_extract"
forceInstall="false"

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

# Get the latest version from Sublime Text API
echo "$(date) | Fetching latest version"
version=$(curl -s https://www.sublimetext.com/updates/4/stable_update_check | grep -o '"latest_version": [0-9]*' | grep -o '[0-9]*')

if [ -z "$version" ]; then
   echo "$(date) | Failed to fetch latest version"
   exit 1
fi

echo "$(date) | Latest version: $version"
weburl="https://download.sublimetext.com/sublime_text_build_${version}_mac.zip"
echo "$(date) | Download URL: $weburl"

# Let's download the files we need and attempt to install...

echo "$(date) | Downloading $appname"
curl -L -f -o "$tempfile" "$weburl"

if [ "$?" != "0" ]; then
  # Something went wrong here, either the download failed or the mount/extract failed
  # Intune will pick up the exit status and the IT Pro can use that to determine what went wrong.
  # Intune can also return the log file if requested by the admin
   echo "$(date) | Failed to download $appname"
   exit 1
fi

if [[ "$weburl" == *.dmg ]]; then
   echo "$(date) | Mounting $appname disk image"
   mkdir -p "$mountpoint"
   hdiutil attach "$tempfile" -mountpoint "$mountpoint" -nobrowse

   if [ "$?" = "0" ]; then
      echo "$(date) | Copying $appname to Applications"
      cp -r "$mountpoint/Sublime Text.app" "$apppath"

      if [ "$?" = "0" ]; then
         echo "$(date) | $appname Installed"
         echo "$(date) | Unmounting disk image"
         hdiutil detach "$mountpoint"
         echo "$(date) | Cleaning Up"
         rm -rf "$tempfile"
         rm -rf "$mountpoint"
         exit 0
      else
         echo "$(date) | Failed to copy $appname to Applications"
         hdiutil detach "$mountpoint"
         rm -rf "$tempfile"
         rm -rf "$mountpoint"
         exit 1
      fi
   else
      echo "$(date) | Failed to mount $appname"
      exit 1
   fi
else
   echo "$(date) | Extracting $appname archive"
   rm -rf "$unzipdir"
   mkdir -p "$unzipdir"
   unzip -q "$tempfile" -d "$unzipdir"

   if [ "$?" = "0" ] && [ -d "$unzipdir/Sublime Text.app" ]; then
      echo "$(date) | Copying $appname to Applications"
      cp -r "$unzipdir/Sublime Text.app" "$apppath"

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
fi