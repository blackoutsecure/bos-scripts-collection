# bos-scripts-collection

Reusable operating system administration scripts for enterprise deployment and manual execution.

Maintained by [Blackout Secure](https://blackoutsecure.app)

## Repository Structure

Scripts are organized by operating system at the top level, then by category, then by target (e.g. application name). For Linux, scripts are further grouped by distribution.

```
<os>/
  [<distribution>/]
    <category>/
      <target>/
        <action>-<target>.sh
        README.md
```

Current top-level operating systems:

| OS | Folder |
|---|---|
| macOS | [`macos/`](macos/) |
| Linux | [`linux/`](linux/) |

## Usage Context

Scripts are designed for:

- MDM / endpoint management deployment (Intune / Company Portal, Jamf, Kandji, Mosyle, Workspace ONE for macOS; Intune, Ansible, and similar tooling for Linux)
- Manual execution by administrators

All scripts log activity and return predictable exit codes suitable for automated monitoring.

## License

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the [Apache 2.0 License](LICENSE).
