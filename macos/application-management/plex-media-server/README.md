# Plex Media Server

Scripts and documentation for managing Plex Media Server on macOS.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Application

- [plex.tv/media-server-downloads](https://www.plex.tv/media-server-downloads/?cat=computer&plat=macos)

## Available Scripts

| Script | Description |
|---|---|
| `install-plex-media-server.sh` | Automatically downloads and installs the latest Plex Media Server release |

## How the Install Script Works

1. Queries the Plex public downloads API (`https://plex.tv/api/downloads/5.json`) for the current macOS release.
2. Extracts the download URL for the macOS universal `.zip` archive.
3. Downloads, extracts, and copies `Plex Media Server.app` to `/Applications`.
4. If Plex Media Server is already installed, exits immediately without making changes.

## Deployment

### MDM (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE)

Deploy `install-plex-media-server.sh` as a managed shell script or custom app install step.

- All activity is logged to `/var/log/installplex.log`.
- Monitor the exit code in your MDM console:
  - `0` — success (installed or already present)
  - `1` — failure (review log for details)

### Manual

```bash
sudo bash ./application-management/plex-media-server/install-plex-media-server.sh
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
