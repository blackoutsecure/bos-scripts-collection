# Copilot Instructions: bos-scripts-collection

This repository stores reusable operating system administration scripts and supporting documentation.

## Repository Goals
- Keep scripts practical for enterprise deployment and local/manual execution.
- Prioritize reliability, clear logs, and predictable exit codes for management tooling.
- Use simple Bash with readable variable names and comments where logic is non-obvious.

## Script Conventions
- Use `#!/bin/bash` unless a script explicitly requires another shell.
- Quote variable expansions to avoid path/word-splitting issues.
- Return `0` for success and non-zero for failures.
- Log meaningful start/success/failure events when scripts are intended for managed deployment.
- Keep install scripts idempotent when possible (safe to run multiple times).

## Content Structure
- Top level is the operating system: `macos/`, `linux/`.
- Under Linux, group by distribution: `linux/ubuntu/`, `linux/debian/`, etc.
- Then by category, then by target: `<os>[/<distro>]/<category>/<target>/`.
- Example: `macos/application-management/sublime-text/install-sublime-text.sh`.
- Keep scripts directly in each target folder (no operation subfolders).
- Use action-oriented script names like `install-<target>.sh`.

## Documentation Expectations
- Each script should have a brief header explaining purpose and expected usage.
- Include notes for both managed deployment (MDM such as Intune/Jamf for macOS; Ansible/Intune for Linux) and manual execution where relevant.