# Application management (Ubuntu)

Scripts that install or manage user-facing applications and developer
runtimes on Ubuntu.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Targets

| Target | Folder |
|---|---|
| Node.js (and npm) | [`nodejs/`](nodejs/) |

## Conventions

- Use `#!/bin/bash`.
- Run as root; require `EUID 0` and exit non-zero otherwise.
- Prefer `apt-get` with `DEBIAN_FRONTEND=noninteractive` over interactive `apt`.
- Use the modern APT pattern: dedicated keyring under `/etc/apt/keyrings/`
  referenced via `signed-by=` in the sources list. Do not use `apt-key`.
- Log to `/var/log/<script>.log` and return `0` on success, non-zero on failure.
- Keep installs idempotent (safe to re-run).

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
