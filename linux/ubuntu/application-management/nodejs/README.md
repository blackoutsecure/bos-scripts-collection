# Node.js (Ubuntu)

Installs Node.js and the bundled `npm` on Ubuntu from the official
[NodeSource](https://github.com/nodesource/distributions) APT repository,
then verifies the install by recording `node --version` and `npm --version`.

## Script

[`install-nodejs.sh`](install-nodejs.sh)

## What it does

1. Installs prerequisites: `ca-certificates`, `curl`, `gnupg`, `apt-transport-https`.
2. Downloads the NodeSource signing key into `/etc/apt/keyrings/nodesource.gpg`
   and references it from the APT source via `signed-by=` (no use of the
   deprecated `apt-key`).
3. Writes `/etc/apt/sources.list.d/nodesource.list` pinned to the requested
   Node.js major version (default: current LTS, `22`) for the host's CPU
   architecture.
4. Runs `apt-get update` and installs the `nodejs` package. `npm` ships inside
   the NodeSource `nodejs` package, so the Ubuntu `npm` package is **not**
   installed alongside it (they conflict).
5. Verifies the install with `node --version` and `npm --version`.

## Why not the upstream one-liner?

The common NodeSource snippet:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
```

pipes a remote shell script straight into root. This script performs the same
setup steps explicitly (pinned keyring, `signed-by` repo, non-interactive
`apt-get install`) so it is auditable, idempotent, and safe to re-run from
management tooling.

## Usage

### Manual

```bash
sudo bash ./install-nodejs.sh
```

### Pin a specific Node.js major

Pass it as the first argument or via the `NODE_MAJOR` environment variable:

```bash
sudo ./install-nodejs.sh 20
sudo NODE_MAJOR=18 ./install-nodejs.sh
```

### Managed deployment (Ansible / Intune for Linux / Chef / Puppet / Salt)

Run the script as root. All activity is logged to `/var/log/install-nodejs.log`.
Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success (installed or already installed) |
| `1` | Failure (review the log) |

## Idempotency

- The keyring and sources file are only (re)written when missing or when the
  requested major changes.
- `apt-get install` is a no-op when the package is already current.
- Re-running with a different `NODE_MAJOR` repoints the repo and lets APT
  upgrade or downgrade `nodejs` to that line.

## Notes

- NodeSource publishes a single `nodistro` suite that works across supported
  Ubuntu releases, so the script does not need to detect the codename.
- To install global npm packages without `sudo`, configure an npm prefix
  inside the user's home directory (e.g. `npm config set prefix ~/.npm-global`)
  rather than running `npm install -g` as root.

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
