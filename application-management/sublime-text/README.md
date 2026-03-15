# Sublime Text

Scripts and documentation for managing Sublime Text on macOS.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Application

- [sublimetext.com](https://www.sublimetext.com/)

## Available Scripts

| Script | Description |
|---|---|
| `install-sublime-text.sh` | Automatically downloads and installs the latest stable Sublime Text build |

## How the Install Script Works

1. Queries the Sublime Text update API for the current stable build number.
2. Constructs the download URL for the macOS `.zip` archive.
3. Downloads, extracts, and copies `Sublime Text.app` to `/Applications`.
4. If Sublime Text is already installed, exits immediately without making changes.

## Deployment

### MDM (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE)

Deploy `install-sublime-text.sh` as a managed shell script or custom app install step.

- All activity is logged to `/var/log/installsublime.log`.
- Monitor the exit code in your MDM console:
  - `0` — success (installed or already present)
  - `1` — failure (review log for details)

### Manual

```bash
sudo bash ./application-management/sublime-text/install-sublime-text.sh
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
