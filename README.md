# OpenClaw Update Script

Safe update and rollback helper for self-hosted OpenClaw setups.

This repository contains `openclaw_update_all.sh`, a practical update script that helps you:
- run a precheck before update
- update OpenClaw to the latest or to a specific target version
- verify post-update health
- rollback to the previous working version if needed
- detect CLI and gateway version drift
- keep a local backup snapshot before update

## What this script is for

This script is designed for operators who want a more careful update path than a blind `npm i -g openclaw@latest`.

It focuses on a few important things:
- checking the real installed CLI path
- checking version sync between CLI and gateway unit
- stopping the gateway cleanly before update
- creating a backup of `~/.openclaw`
- installing the target version
- starting the gateway again
- running smoke and verify checks
- giving you a rollback path if something breaks

## Repository contents

- `openclaw_update_all.sh` - the update, verify and rollback script
- `INSTRUCTION.md` - operator guide with step-by-step usage
- `LICENSE` - MIT

## Quick start

Download or clone the repository:

```bash
git clone https://github.com/neural-max-ai/openclaw-update-script.git
cd openclaw-update-script
chmod +x openclaw_update_all.sh
```

Run precheck first:

```bash
./openclaw_update_all.sh precheck
```

Update to the latest resolved version:

```bash
./openclaw_update_all.sh update
```

Update to a specific version:

```bash
./openclaw_update_all.sh update 2026.5.22
```

Verify after update:

```bash
./openclaw_update_all.sh verify
```

Rollback if needed:

```bash
./openclaw_update_all.sh rollback
```

## Supported flow

### 1. Precheck

```bash
./openclaw_update_all.sh precheck
```

What it checks:
- npm availability
- OpenClaw CLI path truth
- current update target resolution
- current gateway service state
- disk and memory snapshot
- npm global install access
- CLI vs gateway unit version drift
- gateway ExecStart path drift

### 2. Update

```bash
./openclaw_update_all.sh update
```

Or pin a target version:

```bash
./openclaw_update_all.sh update 2026.5.22
```

What it does:
- runs precheck
- stops `openclaw-gateway`
- creates a backup under `~/openclaw-backup/`
- installs the target version via npm
- checks CLI truth and version sync
- auto-remediates gateway unit drift when possible
- restarts the gateway
- runs smoke checks

### 3. Verify

```bash
./openclaw_update_all.sh verify
```

What it verifies:
- gateway status
- `openclaw status --deep`
- `openclaw health --json`
- CLI path truth
- CLI and gateway unit version sync
- gateway ExecStart path truth

### 4. Rollback

```bash
./openclaw_update_all.sh rollback
```

What it does:
- restores the previous OpenClaw version recorded during update
- restores `~/.openclaw` from backup if available
- rechecks CLI truth, version sync and gateway path
- restarts gateway and runs smoke checks

## Update to a specific target version

You can update to a specific OpenClaw version like this:

```bash
./openclaw_update_all.sh update 2026.5.22
```

Version format must match:

```text
YYYY.M.P
```

Example:
- `2026.5.22`
- `2026.4.10`

If you do not pass a version, the script tries to resolve the target version from:
1. `openclaw update status`
2. `npm view openclaw version`

## Non-interactive mode

For automation or remote sessions:

```bash
ASSUME_YES=1 ./openclaw_update_all.sh update 2026.5.22
```

## Logs and backups

Logs are stored in:

```bash
~/openclaw-backup/logs/
```

Backups are stored in:

```bash
~/openclaw-backup/
```

The script also keeps a state file for rollback:

```bash
~/openclaw-backup/last-update-state.env
```

## Important notes

- Run `precheck` before every real update.
- Prefer doing updates in a maintenance window.
- Do not skip verify after update.
- If health, gateway, status, or chat behavior look wrong, rollback early instead of stacking more changes.
- This script assumes a user-level `openclaw-gateway` systemd service.

## Good operator sequence

```bash
./openclaw_update_all.sh precheck
./openclaw_update_all.sh update 2026.5.22
./openclaw_update_all.sh verify
```

If anything looks broken:

```bash
./openclaw_update_all.sh rollback
./openclaw_update_all.sh verify
```

## License

MIT
