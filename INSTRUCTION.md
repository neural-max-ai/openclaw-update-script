# INSTRUCTION

## Purpose

Use `openclaw_update_all.sh` to update a self-hosted OpenClaw gateway contour safely:

- `precheck` before update
- `update` to latest or pinned version
- `verify` after update
- manual `rollback` when needed

The script updates the OpenClaw package that backs the active `openclaw-gateway.service`.

## 1. Prepare

```bash
git clone https://github.com/neural-max-ai/openclaw-update-script.git
cd openclaw-update-script
chmod +x openclaw_update_all.sh
```

## 2. Precheck

```bash
./openclaw_update_all.sh precheck
```

Precheck verifies:

- required commands
- active OpenClaw gateway contour
- target version
- install prefix
- Node.js/npm/npm registry access
- free disk space
- CLI vs gateway unit version sync
- gateway ExecStart shape

Do not continue if precheck fails. Fix the reported problem first.

## 3. Update

Latest resolved npm version:

```bash
./openclaw_update_all.sh update
```

Pinned version:

```bash
./openclaw_update_all.sh update 2026.5.28
```

Update flow:

1. Run precheck.
2. Ask for confirmation unless `ASSUME_YES=1`.
3. Backup `~/.openclaw`, the gateway unit and recent gateway logs.
4. Install `openclaw@TARGET_VERSION` into the detected install prefix.
5. Refresh gateway unit with `openclaw gateway install --force`.
6. Restart `openclaw-gateway.service`.
7. Run smoke checks, including `openclaw doctor --fix --non-interactive --yes`.
8. Verify CLI/unit/gateway truth.

## 4. Verify

```bash
./openclaw_update_all.sh verify
```

Verify checks:

- gateway service is active
- `openclaw gateway status`
- `openclaw doctor --fix --non-interactive --yes`
- `openclaw status --deep`
- `openclaw channels status --probe --timeout 30000`
- CLI/unit/gateway version and contour sync

## 5. Rollback

```bash
./openclaw_update_all.sh rollback
```

Rollback uses `~/openclaw-backup/last-update-state.env`.

Rollback flow:

1. Ask for confirmation.
2. Reinstall previous OpenClaw version.
3. Restore `~/.openclaw` from backup through a staging directory.
4. Refresh and restart the gateway unit.
5. Run smoke and truth checks.
6. Remove rollback staging trash after success.

Rollback is manual by design. Inspect logs before running it.

## 6. Non-Interactive Mode

```bash
ASSUME_YES=1 ./openclaw_update_all.sh update
```

For system installs, non-interactive mode requires working passwordless/cached sudo:

```bash
sudo -n true
```

If sudo would prompt for a password, precheck fails before install.

## 7. Logs

```bash
ls -lt ~/openclaw-backup/logs/
tail -n 200 ~/openclaw-backup/logs/update-*.log
```

Backups are stored in:

```bash
~/openclaw-backup/<timestamp>/
```
