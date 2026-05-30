#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${HOME}/openclaw-backup"
STATE_FILE="${BACKUP_ROOT}/last-update-state.env"
LOG_DIR="${BACKUP_ROOT}/logs"
SERVICE_NAME="openclaw-gateway"
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

MODE="${1:-}"
VERSION_ARG="${2:-}"
ASSUME_YES="${ASSUME_YES:-0}"
TARGET_VERSION=""
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/update-${TS}.log"

NPM_GLOBAL_PREFIX=""
NPM_GLOBAL_ROOT=""
NPM_GLOBAL_BIN_DIR=""
GLOBAL_OPENCLAW_BIN=""
PATH_OPENCLAW_BIN=""
OPENCLAW_BIN=""
UNIT_FRAGMENT_PATH=""

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

confirm(){
  if [[ "$ASSUME_YES" == "1" ]]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

realpath_safe(){
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || printf '%s\n' "$p"
}

validate_version(){
  [[ "${1:-}" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]
}

discover_cli_layout(){
  need npm

  NPM_GLOBAL_PREFIX="$(npm prefix -g 2>/dev/null || true)"
  NPM_GLOBAL_ROOT="$(npm root -g 2>/dev/null || true)"
  NPM_GLOBAL_BIN_DIR="${NPM_GLOBAL_PREFIX:+${NPM_GLOBAL_PREFIX}/bin}"
  GLOBAL_OPENCLAW_BIN="${NPM_GLOBAL_BIN_DIR:+${NPM_GLOBAL_BIN_DIR}/openclaw}"
  PATH_OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || true)"

  if [[ -n "$GLOBAL_OPENCLAW_BIN" && -x "$GLOBAL_OPENCLAW_BIN" ]]; then
    OPENCLAW_BIN="$GLOBAL_OPENCLAW_BIN"
  elif [[ -n "$PATH_OPENCLAW_BIN" && -x "$PATH_OPENCLAW_BIN" ]]; then
    OPENCLAW_BIN="$PATH_OPENCLAW_BIN"
  else
    fail "Cannot find executable openclaw (PATH='${PATH_OPENCLAW_BIN:-<missing>}', GLOBAL='${GLOBAL_OPENCLAW_BIN:-<missing>}')"
  fi
}

oc(){
  [[ -n "$OPENCLAW_BIN" ]] || discover_cli_layout
  "$OPENCLAW_BIN" "$@"
}

get_bin_version(){
  local bin="${1:-}"
  [[ -n "$bin" && -x "$bin" ]] || return 0
  "$bin" --version 2>/dev/null | grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1 || true
}

get_cli_version(){
  get_bin_version "$OPENCLAW_BIN"
}

get_path_cli_version(){
  get_bin_version "$PATH_OPENCLAW_BIN"
}

get_global_cli_version(){
  get_bin_version "$GLOBAL_OPENCLAW_BIN"
}

get_unit_fragment_path(){
  systemctl --user show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null || true
}

get_unit_service_version(){
  systemctl --user cat "$SERVICE_NAME" 2>/dev/null \
    | sed -nE 's/.*OPENCLAW_SERVICE_VERSION="?([^"[:space:]]+)"?.*/\1/p' \
    | head -n1 || true
}

get_unit_execstart_path(){
  systemctl --user cat "$SERVICE_NAME" 2>/dev/null \
    | sed -nE 's/^ExecStart=([^[:space:]]+).*/\1/p' \
    | head -n1 || true
}

ensure_runtime_truth(){
  discover_cli_layout
  UNIT_FRAGMENT_PATH="$(get_unit_fragment_path)"

  if [[ -z "$UNIT_FRAGMENT_PATH" ]]; then
    log "Runtime truth: unit fragment path unavailable"
    return 0
  fi

  log "Runtime truth: unit fragment=${UNIT_FRAGMENT_PATH}"
  return 0
}

log_cli_layout(){
  discover_cli_layout

  local path_real global_real canonical_real
  path_real="$(realpath_safe "$PATH_OPENCLAW_BIN")"
  global_real="$(realpath_safe "$GLOBAL_OPENCLAW_BIN")"
  canonical_real="$(realpath_safe "$OPENCLAW_BIN")"

  log "CLI layout: PATH_OPENCLAW_BIN=${PATH_OPENCLAW_BIN:-<missing>} PATH_REAL=${path_real:-<missing>} PATH_VER=${PATH_OPENCLAW_BIN:+$(get_path_cli_version)}"
  log "CLI layout: GLOBAL_OPENCLAW_BIN=${GLOBAL_OPENCLAW_BIN:-<missing>} GLOBAL_REAL=${global_real:-<missing>} GLOBAL_VER=${GLOBAL_OPENCLAW_BIN:+$(get_global_cli_version)}"
  log "CLI layout: CANONICAL_OPENCLAW_BIN=${OPENCLAW_BIN} CANONICAL_REAL=${canonical_real} CANONICAL_VER=$(get_cli_version)"

  if [[ -n "$PATH_OPENCLAW_BIN" && -n "$GLOBAL_OPENCLAW_BIN" && "$path_real" != "$global_real" ]]; then
    log "CLI path drift detected: PATH openclaw is not the same binary as npm global openclaw"
  fi
}

resolve_target_version(){
  local status_out parsed npm_latest

  if [[ -z "${NPM_CONFIG_PREFIX:-}" ]]; then
    export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
  fi

  if [[ -n "$VERSION_ARG" ]]; then
    validate_version "$VERSION_ARG" || fail "Invalid version format: '$VERSION_ARG'"
    TARGET_VERSION="$VERSION_ARG"
    log "Target version forced by argument: ${TARGET_VERSION}"
    return 0
  fi

  status_out="$(oc update status 2>/dev/null || true)"
  parsed="$(printf '%s\n' "$status_out" | grep -Eo '([0-9]{4}\.[0-9]+\.[0-9]+)' | tail -n1 || true)"

  if [[ -n "$parsed" ]]; then
    TARGET_VERSION="$parsed"
    log "Target version resolved from 'openclaw update status': ${TARGET_VERSION}"
    return 0
  fi

  npm_latest="$(npm view openclaw version 2>/dev/null || true)"
  if validate_version "$npm_latest"; then
    TARGET_VERSION="$npm_latest"
    log "Target version resolved from 'npm view openclaw version': ${TARGET_VERSION}"
    return 0
  fi

  fail "Cannot resolve target version from argument, update status, or npm"
}

check_cli_truth(){
  discover_cli_layout

  local path_bin path_real canonical_real path_ver canonical_ver
  path_bin="$PATH_OPENCLAW_BIN"
  path_real="$(realpath_safe "$path_bin")"
  canonical_real="$(realpath_safe "$OPENCLAW_BIN")"
  path_ver="$(get_path_cli_version)"
  canonical_ver="$(get_cli_version)"

  log "CLI truth check: PATH_BIN=${path_bin:-<missing>} PATH_REAL=${path_real:-<missing>} PATH_VER=${path_ver:-<unknown>}"
  log "CLI truth check: CANONICAL_BIN=${OPENCLAW_BIN} CANONICAL_REAL=${canonical_real:-<missing>} CANONICAL_VER=${canonical_ver:-<unknown>}"

  [[ -n "$path_bin" ]] || { log "CLI truth failed: PATH has no openclaw"; return 1; }
  [[ -n "$canonical_ver" ]] || { log "CLI truth failed: canonical CLI version unknown"; return 1; }
  [[ -n "$path_ver" ]] || { log "CLI truth failed: PATH CLI version unknown"; return 1; }
  [[ "$path_ver" == "$canonical_ver" ]] || { log "CLI truth failed: PATH version $path_ver != canonical version $canonical_ver"; return 1; }
  [[ "$path_real" == "$canonical_real" ]] || { log "CLI truth failed: PATH binary realpath differs from canonical binary"; return 1; }

  log "CLI truth OK"
  return 0
}

check_gateway_truth(){
  local unit_exec unit_exec_real canonical_real
  unit_exec="$(get_unit_execstart_path)"
  canonical_real="$(realpath_safe "$OPENCLAW_BIN")"

  if [[ -z "$unit_exec" ]]; then
    log "Gateway truth check: unit ExecStart path unavailable - skipping strict path check"
    return 0
  fi

  if [[ "$(basename "$unit_exec")" != "openclaw" ]]; then
    log "Gateway truth check: unit ExecStart is '${unit_exec}', not a direct openclaw binary - skipping strict path check"
    return 0
  fi

  unit_exec_real="$(realpath_safe "$unit_exec")"
  log "Gateway truth check: UNIT_EXEC=${unit_exec} UNIT_EXEC_REAL=${unit_exec_real} CANONICAL_REAL=${canonical_real}"

  [[ "$unit_exec_real" == "$canonical_real" ]] || { log "Gateway truth failed: unit ExecStart does not point to canonical CLI"; return 1; }

  log "Gateway truth OK"
  return 0
}

check_version_sync(){
  local cli_ver unit_ver
  cli_ver="$(get_cli_version)"
  unit_ver="$(get_unit_service_version)"

  log "Version sync check: CLI=${cli_ver:-<unknown>} UNIT_OPENCLAW_SERVICE_VERSION=${unit_ver:-<missing>}"

  [[ -n "$cli_ver" ]] || { log "Version sync check failed: cannot detect CLI version"; return 1; }
  [[ -n "$unit_ver" ]] || { log "Version sync check failed: unit OPENCLAW_SERVICE_VERSION is missing"; return 1; }
  [[ "$cli_ver" == "$unit_ver" ]] || { log "Version drift detected: CLI=$cli_ver != UNIT=$unit_ver"; return 1; }

  log "Version sync OK"
  return 0
}

check_npm_global_install_access(){
  discover_cli_layout

  [[ -n "$NPM_GLOBAL_PREFIX" ]] || fail "npm prefix -g returned empty"
  [[ -n "$NPM_GLOBAL_ROOT" ]] || fail "npm root -g returned empty"
  [[ -n "$NPM_GLOBAL_BIN_DIR" ]] || fail "npm global bin dir resolved empty"

  log "NPM access check: PREFIX=${NPM_GLOBAL_PREFIX} ROOT=${NPM_GLOBAL_ROOT} BIN_DIR=${NPM_GLOBAL_BIN_DIR}"

  if [[ -d "$NPM_GLOBAL_ROOT" && -d "$NPM_GLOBAL_BIN_DIR" && -w "$NPM_GLOBAL_ROOT" && -w "$NPM_GLOBAL_BIN_DIR" ]]; then
    log "NPM access check OK: global tree writable by current user"
    return 0
  fi

  need sudo

  if [[ "$ASSUME_YES" == "1" ]]; then
    sudo -n true 2>/dev/null || fail "ASSUME_YES=1 but sudo requires a password for npm -g operations"
  fi

  log "NPM access check: global tree is not writable by current user, sudo will be used for npm -g"
}

run_npm_global_install(){
  local version="$1"
  discover_cli_layout
  check_npm_global_install_access

  if [[ -d "$NPM_GLOBAL_ROOT" && -d "$NPM_GLOBAL_BIN_DIR" && -w "$NPM_GLOBAL_ROOT" && -w "$NPM_GLOBAL_BIN_DIR" ]]; then
    log "npm -g install: using current user"
    npm i -g "openclaw@${version}" | tee -a "$LOG_FILE"
    return 0
  fi

  log "npm -g install: using sudo for root-owned global tree"
  sudo npm i -g "openclaw@${version}" | tee -a "$LOG_FILE"
}

ensure_gateway_active(){
  local context="$1"

  if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    return 0
  fi

  log "Gateway inactive during ${context}. Running fallback recovery..."
  oc gateway install --force | tee -a "$LOG_FILE" >/dev/null || true
  systemctl --user daemon-reload || true
  systemctl --user restart "${SERVICE_NAME}.service" || true
  sleep 3

  if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    log "Gateway recovered by fallback"
    return 0
  fi

  log "Gateway still inactive after fallback. Last logs:"
  journalctl --user -u "$SERVICE_NAME" -n 120 --no-pager | tee -a "$LOG_FILE" >/dev/null || true
  fail "Gateway is not active"
}

smoke_checks(){
  log "Smoke checks: service active + CLI status + recent logs"
  ensure_gateway_active "smoke checks"
  oc gateway status | tee -a "$LOG_FILE" >/dev/null
  oc status | tee -a "$LOG_FILE" >/dev/null
  journalctl --user -u "$SERVICE_NAME" -n 120 --no-pager | tee -a "$LOG_FILE" >/dev/null || true
}

verify_post_update(){
  log "=== VERIFY ==="
  ensure_gateway_active "verify"

  log "Verify: gateway status"
  oc gateway status | tee -a "$LOG_FILE" >/dev/null

  log "Verify: deep status"
  oc status --deep | tee -a "$LOG_FILE" >/dev/null

  log "Verify: health"
  if ! oc health --json | tee -a "$LOG_FILE" >/dev/null; then
    log "Verify warning: health check returned non-zero"
  fi

  check_cli_truth || fail "Verify failed: CLI path truth mismatch"
  check_version_sync || fail "Verify failed: CLI/unit version mismatch"
  check_gateway_truth || fail "Verify failed: gateway ExecStart path mismatch"
  log "VERIFY SUCCESS"
}

auto_remediate_truth(){
  local reason="$1"
  local rem_dir fragment
  rem_dir="${BACKUP_ROOT}/${TS}/unit-remediation"
  mkdir -p "$rem_dir"

  log "Auto-remediation started: ${reason}"

  fragment="$(get_unit_fragment_path)"
  if [[ -n "$fragment" && -f "$fragment" ]]; then
    cp -a "$fragment" "${rem_dir}/$(basename "$fragment").bak"
    log "Backed up unit file: $fragment -> ${rem_dir}/"
  else
    log "Unit fragment not found or not file (FragmentPath='${fragment:-<empty>}'), continuing"
  fi

  log "Auto-remediation: stop gateway"
  systemctl --user stop "$SERVICE_NAME" || true

  if [[ -n "$fragment" && -f "$fragment" ]]; then
    if [[ "$fragment" == "$HOME"/* ]]; then
      rm -f "$fragment"
      log "Removed user unit fragment: $fragment"
    else
      log "Skip removing non-home fragment for safety: $fragment"
    fi
  fi

  log "Auto-remediation: daemon-reload"
  systemctl --user daemon-reload

  log "Auto-remediation: reinstall gateway unit from canonical CLI"
  oc gateway install --force | tee -a "$LOG_FILE" >/dev/null
  sleep 2

  log "Auto-remediation: start gateway"
  systemctl --user start "$SERVICE_NAME" || true
  sleep 3

  ensure_gateway_active "auto-remediation install/start sequence"
  smoke_checks
  check_cli_truth || fail "Auto-remediation failed: CLI truth still broken"
  check_version_sync || fail "Auto-remediation failed: version drift still present"
  check_gateway_truth || fail "Auto-remediation failed: gateway ExecStart still not canonical"
  log "Auto-remediation SUCCESS"
}

precheck(){
  need npm; need systemctl; need journalctl; need sed; need grep; need readlink; need df; need free; need tee
  discover_cli_layout
  resolve_target_version

  log "=== PRECHECK ==="
  log_cli_layout
  oc --version | tee -a "$LOG_FILE"
  oc update status | tee -a "$LOG_FILE" >/dev/null || true
  oc status | tee -a "$LOG_FILE" >/dev/null
  systemctl --user status "$SERVICE_NAME" --no-pager | tee -a "$LOG_FILE" >/dev/null || true
  df -h | tee -a "$LOG_FILE" >/dev/null
  free -h | tee -a "$LOG_FILE" >/dev/null
  ensure_runtime_truth
  check_npm_global_install_access

  if ! check_cli_truth; then
    fail "Precheck failed: PATH openclaw is not the same canonical CLI that npm -g will update"
  fi

  check_version_sync || log "Precheck warning: CLI/unit version drift detected (will auto-remediate during update if needed)"
  check_gateway_truth || log "Precheck warning: gateway ExecStart path drift detected (will auto-remediate during update if needed)"
  log "Precheck passed"
}

backup_state(){
  local snap_dir="${BACKUP_ROOT}/${TS}"
  mkdir -p "$snap_dir"
  cp -a "${HOME}/.openclaw" "$snap_dir/" || true
  systemctl --user cat "$SERVICE_NAME" >"${snap_dir}/${SERVICE_NAME}.unit.txt" || true
  journalctl --user -u "$SERVICE_NAME" -n 300 --no-pager >"${snap_dir}/gateway.log" || true

  local prev
  prev="$(get_cli_version)"

  cat >"$STATE_FILE" <<EOF_STATE
TS=${TS}
BACKUP_DIR=${snap_dir}
PREV_VERSION=${prev}
TARGET_VERSION=${TARGET_VERSION}
CANONICAL_OPENCLAW_BIN=${OPENCLAW_BIN}
PATH_OPENCLAW_BIN=${PATH_OPENCLAW_BIN}
GLOBAL_OPENCLAW_BIN=${GLOBAL_OPENCLAW_BIN}
EOF_STATE

  log "Backup completed: ${snap_dir}"
}

do_update(){
  local canonical_ver path_ver

  log "=== UPDATE ==="
  precheck
  confirm "Proceed with update to ${TARGET_VERSION}?" || fail "Cancelled"

  log "Step: stop ${SERVICE_NAME}"
  systemctl --user stop "$SERVICE_NAME" || true
  sleep 2

  backup_state

  log "Step: npm install openclaw@${TARGET_VERSION}"
  run_npm_global_install "$TARGET_VERSION"

  discover_cli_layout
  log_cli_layout

  local canonical_ver path_ver
  canonical_ver="$(get_cli_version)"
  path_ver="$(get_path_cli_version)"

  [[ "$canonical_ver" == "$TARGET_VERSION" ]] || fail "Canonical CLI version mismatch after update: ${canonical_ver:-<unknown>} (expected ${TARGET_VERSION})"
  [[ "$path_ver" == "$TARGET_VERSION" ]] || fail "PATH CLI version mismatch after update: ${path_ver:-<unknown>} (expected ${TARGET_VERSION})"

  if ! check_cli_truth || ! check_version_sync || ! check_gateway_truth; then
    auto_remediate_truth "post-update CLI/unit/gateway truth mismatch"
  fi

  log "Step: start ${SERVICE_NAME}"
  systemctl --user start "$SERVICE_NAME" || true
  sleep 3

  smoke_checks
  check_cli_truth || fail "Final CLI truth check failed after update"
  check_version_sync || fail "Final version sync check failed after update"
  check_gateway_truth || fail "Final gateway truth check failed after update"

  log "Update SUCCESS -> ${TARGET_VERSION}"
}

do_rollback(){
  log "=== ROLLBACK ==="
  [[ -f "$STATE_FILE" ]] || fail "State file not found: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${PREV_VERSION:-}" ]] || fail "PREV_VERSION missing in state"

  confirm "Rollback to ${PREV_VERSION}?" || fail "Cancelled"

  discover_cli_layout

  log "Step: stop ${SERVICE_NAME}"
  systemctl --user stop "$SERVICE_NAME" || true

  log "Step: reinstall previous version ${PREV_VERSION}"
  run_npm_global_install "$PREV_VERSION"

  if [[ -d "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}/.openclaw" ]]; then
    log "Step: restore ~/.openclaw from backup"
    rm -rf "${HOME}/.openclaw"
    cp -a "${BACKUP_DIR}/.openclaw" "${HOME}/.openclaw"
  else
    log "Rollback warning: backup dir missing or incomplete, skipping ~/.openclaw restore"
  fi

  discover_cli_layout
  log_cli_layout

  if ! check_cli_truth || ! check_version_sync || ! check_gateway_truth; then
    auto_remediate_truth "post-rollback CLI/unit/gateway truth mismatch"
  fi

  log "Step: start ${SERVICE_NAME}"
  systemctl --user start "$SERVICE_NAME" || true
  sleep 3

  smoke_checks
  check_cli_truth || fail "Final CLI truth check failed after rollback"
  check_version_sync || fail "Final version sync check failed after rollback"
  check_gateway_truth || fail "Final gateway truth check failed after rollback"

  log "Rollback SUCCESS -> ${PREV_VERSION}"
}

usage(){
  cat <<EOF
Usage:
  $0 precheck
  $0 update [YYYY.M.P]
  $0 verify
  $0 rollback

Examples:
  $0 update
  $0 update 2026.4.10

Options:
  ASSUME_YES=1   non-interactive confirmation

Logs:
  ${LOG_DIR}/update-*.log
EOF
}

case "$MODE" in
  precheck) precheck ;;
  update) do_update ;;
  verify) verify_post_update ;;
  rollback) do_rollback ;;
  *) usage; exit 1 ;;
esac
