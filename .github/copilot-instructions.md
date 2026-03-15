# Copilot Instructions: macos-scripts-collection

This repository stores reusable macOS administration scripts and supporting documentation.

## Repository Goals
- Keep scripts practical for enterprise deployment and local/manual execution.
- Prioritize reliability, clear logs, and predictable exit codes for MDM tooling.
- Use simple Bash with readable variable names and comments where logic is non-obvious.

## Script Conventions
- Use `#!/bin/bash` unless a script explicitly requires another shell.
- Quote variable expansions to avoid path/word-splitting issues.
- Return `0` for success and non-zero for failures.
- Log meaningful start/success/failure events when scripts are intended for managed deployment.
- Keep app install scripts idempotent when possible (safe to run multiple times).

## Content Structure
- `application-management/<application-name>/`: scripts and docs for one app.
- Keep scripts directly in each application folder (no operation subfolders).
- Use action-oriented script names like `install-<application-name>.sh`.

## Documentation Expectations
- Each script should have a brief header explaining purpose and expected usage.
- Include notes for both MDM deployment (Intune/Company Portal/Jamf/etc.) and manual execution where relevant.