# OpenClaw Update Script

Production update and rollback helper for self-hosted OpenClaw gateway setups.

The script is designed to update the real OpenClaw contour used by the user systemd gateway service, not a random `openclaw` binary found through `PATH`.

## What It Supports

Supported Linux user-systemd npm installs:

- system npm prefix: `/usr`
- system npm prefix: `/usr/local`
- current user npm prefix, including setups like `~/.npm-global`

Intentionally not supported:

- git/dev checkouts
- custom wrapper units
- non-systemd service managers

If the gateway unit does not look like a supported npm/systemd contour, `precheck` stops before update.

## Repository Contents

- `openclaw_update_all.sh` - update, verify and rollback script
- `INSTRUCTION.md` - operator guide
- `LICENSE` - MIT

## Quick Start

```bash
git clone https://github.com/neural-max-ai/openclaw-update-script.git
cd openclaw-update-script
chmod +x openclaw_update_all.sh
```

Run precheck:

```bash
./openclaw_update_all.sh precheck
```

Update to latest resolved npm version:

```bash
./openclaw_update_all.sh update
```

Update to a pinned version:

```bash
./openclaw_update_all.sh update 2026.5.28
```

Verify after update:

```bash
./openclaw_update_all.sh verify
```

Rollback manually if needed:

```bash
./openclaw_update_all.sh rollback
```

## Safety Features

- Resolves the active contour from `openclaw-gateway.service`.
- Verifies CLI version and gateway `OPENCLAW_SERVICE_VERSION` sync.
- Creates a backup snapshot before update.
- Writes rollback state with shell-safe quoting.
- Uses a lock file to avoid parallel update/rollback runs.
- Checks Node.js, npm, npm registry access and free disk space before install.
- Requires available `sudo -n true` when `ASSUME_YES=1` is used for system installs.
- Runs `openclaw doctor --fix --non-interactive --yes` during verify/smoke checks.
- Restores `~/.openclaw` through a staging directory during rollback.
- Removes rollback staging trash after a successful rollback.

## Target Version Resolution

Priority:

1. Explicit version from `update YYYY.M.P`.
2. `npm view openclaw version`.
3. Fallback parsing from `openclaw update status`.

## Environment Options

```bash
ASSUME_YES=1       # non-interactive confirmation
MIN_FREE_MB=1024   # minimum free disk space for HOME/install prefix
MIN_NODE_MAJOR=20  # minimum Node.js major version
```

## Logs And Backups

- Logs: `~/openclaw-backup/logs/update-*.log`
- Backup snapshots: `~/openclaw-backup/<timestamp>/`
- Rollback state: `~/openclaw-backup/last-update-state.env`

## Rollback Policy

Rollback is intentionally manual. If update or verify fails, inspect the log first, then run:

```bash
./openclaw_update_all.sh rollback
```
