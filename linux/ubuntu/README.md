# Ubuntu

Ubuntu administration scripts and supporting documentation.

> Maintained by [Blackout Secure](https://blackoutsecure.app)

## Structure

```
linux/ubuntu/
  <category>/
    <target>/
      <action>-<target>.sh
      README.md
```

| Category | Folder |
|---|---|
| Power management | [`power-management/`](power-management/) |
| Storage optimization | [`storage-optimization/`](storage-optimization/) |
| System configuration | [`system-configuration/`](system-configuration/) |

Additional categories (for example `application-management/`, `security/`) will be added as scripts are contributed.

## Conventions

- Use `#!/bin/bash` unless a script explicitly requires another shell.
- Quote variable expansions to avoid path/word-splitting issues.
- Return `0` for success and non-zero for failures.
- Prefer `apt-get` (non-interactive friendly) over `apt` in scripts.
- Keep install scripts idempotent where possible.

## Copyright

Copyright (c) 2026 [Blackout Secure](https://blackoutsecure.app). Licensed under the Apache 2.0 License.
