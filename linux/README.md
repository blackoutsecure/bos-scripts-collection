# Linux

Linux administration scripts and supporting documentation.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Structure

Scripts are grouped by distribution under this folder. Use a distribution-specific subfolder when a script depends on a particular package manager, init system, or release.

```
linux/
  <distribution>/
    <category>/
      <target>/
        <action>-<target>.sh
        README.md
```

| Distribution | Folder |
|---|---|
| Ubuntu | [`ubuntu/`](ubuntu/) |

Add additional distribution folders (e.g. `debian/`, `rhel/`, `fedora/`) as needed. Place truly distro-agnostic scripts directly under `linux/` only if they are verified to work across the supported distributions.

## Deployment

Assets here are suitable for:

- Configuration management (Ansible, Chef, Puppet, Salt)
- MDM / endpoint management (e.g. Intune for Linux)
- Manual execution by administrators

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
