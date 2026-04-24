# Homebrew

Scripts and documentation for managing Homebrew on macOS.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Application

- [brew.sh](https://brew.sh/)

## Available Scripts

| Script | Description |
|---|---|
| `install-homebrew.sh` | Automatically installs Homebrew using the official install script |

## How the Install Script Works

1. Checks whether `brew` is already present at `/opt/homebrew/bin/brew` (Apple Silicon) or `/usr/local/bin/brew` (Intel).
2. If not found, downloads and runs the official Homebrew install script from `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh`.
3. Runs non-interactively (`NONINTERACTIVE=1`) so it is safe for automated/MDM deployment.
4. Verifies the `brew` binary exists after installation and logs the detected version.
5. If Homebrew is already installed, exits immediately without making changes.

## Deployment

### MDM (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE)

Deploy `install-homebrew.sh` as a managed shell script or custom app install step.

- All activity is logged to `/var/log/installhomebrew.log`.
- Monitor the exit code in your MDM console:
  - `0` — success (installed or already present)
  - `1` — failure (review log for details)

### Manual

```bash
sudo bash ./application-management/homebrew/install-homebrew.sh
```

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
