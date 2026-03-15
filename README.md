# macos-scripts-collection

Reusable macOS administration scripts for enterprise deployment and manual execution.

Maintained by [Blackout Secure](https://blackoutsecure.app)

## Repository Structure

```
application-management/
  <application-name>/
    install-<application-name>.sh
    README.md
```

Each application has its own folder under `application-management/`. Scripts and documentation live directly in that folder.

## Usage Context

Scripts are designed for:

- MDM automated deployment (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE)
- Manual execution by administrators

All scripts log activity and return predictable exit codes suitable for MDM monitoring.

## Applications

| Application | Folder |
|---|---|
| Sublime Text | [`application-management/sublime-text/`](application-management/sublime-text/) |

## License

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the [Apache 2.0 License](LICENSE).
