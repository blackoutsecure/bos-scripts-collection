# Application Management

This folder groups macOS app lifecycle scripts by application.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Structure

Each application has its own subfolder:

```
application-management/
  <application-name>/
    install-<application-name>.sh
    README.md
```

- Keep scripts and documentation directly in the app folder.
- Use action-oriented names: `install-<app>.sh`, `uninstall-<app>.sh`.

## Deployment

Assets here are suitable for:

- MDM automated deployment (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE)
- Manual execution by administrators

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
