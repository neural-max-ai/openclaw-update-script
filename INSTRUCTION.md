# INSTRUCTION

## Purpose

This guide explains how to use `openclaw_update_all.sh` safely:
- precheck before update
- update to latest or to a specific version
- verify after update
- rollback if something goes wrong

---

## 1. Prepare the script

```bash
git clone https://github.com/neural-max-ai/openclaw-update-script.git
cd openclaw-update-script
chmod +x openclaw_update_all.sh
```

If you already downloaded just the script:

```bash
chmod +x openclaw_update_all.sh
```

---

## 2. Precheck before update

Always start here.

```bash
./openclaw_update_all.sh precheck
```

### What the precheck does
- confirms required commands exist
- detects the actual OpenClaw CLI binary in use
- resolves target update version
- checks gateway service state
- checks disk and memory state
- checks npm global write access
- checks CLI vs gateway unit version sync
- checks if gateway ExecStart points to the correct CLI

### If precheck warns about drift
The script can auto-remediate some drift during `update`, but if precheck is clearly broken, do not rush into production update blindly.

---

## 3. Update to latest available target

```bash
./openclaw_update_all.sh update
```

This will:
1. run precheck
2. stop `openclaw-gateway`
3. create backup of `~/.openclaw`
4. install target version
5. check CLI truth and version sync
6. remediate gateway drift if needed
7. restart gateway
8. run smoke checks

---

## 4. Update to a specific target version

If you want a pinned version, use:

```bash
./openclaw_update_all.sh update 2026.5.22
```

This is useful when:
- you want a known stable version
- you do not want the newest release yet
- you are aligning several hosts to the same version
- you are rolling back forward to a chosen target instead of latest

### Version format
Use:

```text
YYYY.M.P
```

Example:
- `2026.5.22`
- `2026.4.10`

---

## 5. Verify after update

After update, do not stop at a green install output.
Run:

```bash
./openclaw_update_all.sh verify
```

### What verify checks
- `openclaw gateway status`
- `openclaw status --deep`
- `openclaw health --json`
- CLI path truth
- CLI version sync with gateway unit
- gateway ExecStart path truth

### Recommended live validation after verify
Also check manually:
- `openclaw --version`
- `openclaw status`
- one real message in chat
- one small tool action if relevant
- one cron test if the host depends on cron jobs

---

## 6. Rollback if something breaks

If update completed but the system is not trustworthy, rollback early.

```bash
./openclaw_update_all.sh rollback
```

### Rollback does
- reinstalls the previous OpenClaw version recorded during the last update
- restores `~/.openclaw` from backup if available
- restarts gateway
- reruns truth and smoke checks

### Good rollback flow
```bash
./openclaw_update_all.sh rollback
./openclaw_update_all.sh verify
```

---

## 7. Non-interactive mode

For automation or when you already know you want to proceed:

```bash
ASSUME_YES=1 ./openclaw_update_all.sh update 2026.5.22
```

You can also use it with rollback:

```bash
ASSUME_YES=1 ./openclaw_update_all.sh rollback
```

---

## 8. Where logs and backups are stored

### Logs
```bash
~/openclaw-backup/logs/
```

### Backups and state
```bash
~/openclaw-backup/
```

### Rollback state file
```bash
~/openclaw-backup/last-update-state.env
```

---

## 9. Safe operator sequence

### Normal update
```bash
./openclaw_update_all.sh precheck
./openclaw_update_all.sh update 2026.5.22
./openclaw_update_all.sh verify
```

### If anything looks wrong
```bash
./openclaw_update_all.sh rollback
./openclaw_update_all.sh verify
```

---

## 10. Practical advice

- Update in a calm window, not in the middle of active work.
- Prefer pinned versions when stability matters more than novelty.
- If CLI version, gateway version, or chat behavior look inconsistent, treat it as drift and verify before trusting the host.
- Do not keep stacking fixes after a suspicious update. Roll back first, then inspect.
