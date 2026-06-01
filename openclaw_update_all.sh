#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${HOME}/openclaw-backup"
STATE_FILE="${BACKUP_ROOT}/last-update-state.env"
LOG_DIR="${BACKUP_ROOT}/logs"
SERVICE_NAME="openclaw-gateway"
LOCK_FILE="/tmp/openclaw-update.lock"
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another openclaw update/rollback is already running: $LOCK_FILE" >&2; exit 1; }

MODE="${1:-}"
VERSION_ARG="${2:-}"
ASSUME_YES="${ASSUME_YES:-0}"
TARGET_VERSION=""
TS="$(date -u +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/update-${TS}.log"

PATH_OPENCLAW_BIN=""
PATH_OPENCLAW_REAL=""
UNIT_EXECSTART_LINE=""
UNIT_EXECSTART_ARGS=""
UNIT_GATEWAY_PORT=""
UNIT_OPENCLAW_ENTRY=""
UNIT_OPENCLAW_REAL=""
OPENCLAW_BIN=""
OPENCLAW_REAL=""
INSTALL_SCOPE=""
INSTALL_PREFIX=""
UNIT_FRAGMENT_PATH=""

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

confirm(){
  if [[ "$ASSUME_YES" == "1" ]]; then return 0; fi
  local prompt="$1 [y/N]: "
  local ans=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" ans </dev/tty
  else
    read -r -p "$prompt" ans
  fi
  ans="$(printf '%s' "$ans" | tr -d '\r' | xargs)"
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" || "$ans" == "Yes" ]]
}

realpath_safe(){
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || printf '%s\n' "$p"
}

validate_version(){
  [[ "${1:-}" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]
}

get_unit_fragment_path(){ systemctl --user show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null || true; }
get_unit_service_version(){
  systemctl --user cat "$SERVICE_NAME" 2>/dev/null | sed -nE 's/.*OPENCLAW_SERVICE_VERSION="?([^"[:space:]]+)"?.*/\1/p' | head -n1 || true
}
get_unit_execstart_line(){
  systemctl --user cat "$SERVICE_NAME" 2>/dev/null | sed -n 's/^ExecStart=//p' | head -n1 || true
}

discover_cli_layout(){
  need npm
  need python3

  PATH_OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || true)"
  PATH_OPENCLAW_REAL="$(realpath_safe "$PATH_OPENCLAW_BIN")"
  UNIT_EXECSTART_LINE="$(get_unit_execstart_line)"
  UNIT_EXECSTART_ARGS=""
  UNIT_GATEWAY_PORT=""
  UNIT_OPENCLAW_ENTRY=""
  UNIT_OPENCLAW_REAL=""

  if [[ -n "$UNIT_EXECSTART_LINE" ]]; then
    mapfile -t _exec_parts < <(python3 - <<'PY' "$UNIT_EXECSTART_LINE"
import shlex, sys
for part in shlex.split(sys.argv[1]):
    print(part)
PY
)
    if [[ ${#_exec_parts[@]} -gt 0 ]]; then
      UNIT_EXECSTART_ARGS="$(printf '%s\n' "${_exec_parts[@]}")"
      if [[ "${_exec_parts[0]}" == "/usr/bin/node" || "$(basename "${_exec_parts[0]}")" == "node" ]]; then
        if [[ ${#_exec_parts[@]} -ge 2 ]]; then
          UNIT_OPENCLAW_ENTRY="${_exec_parts[1]}"
        fi
      else
        UNIT_OPENCLAW_ENTRY="${_exec_parts[0]}"
      fi
      UNIT_OPENCLAW_REAL="$(realpath_safe "$UNIT_OPENCLAW_ENTRY")"
      for ((i=0; i<${#_exec_parts[@]}; i++)); do
        if [[ "${_exec_parts[$i]}" == "--port" && $((i+1)) -lt ${#_exec_parts[@]} ]]; then
          UNIT_GATEWAY_PORT="${_exec_parts[$((i+1))]}"
          break
        fi
      done
    fi
  fi

  if [[ -n "$UNIT_OPENCLAW_REAL" ]]; then
    OPENCLAW_REAL="$UNIT_OPENCLAW_REAL"
  elif [[ -n "$PATH_OPENCLAW_REAL" ]]; then
    OPENCLAW_REAL="$PATH_OPENCLAW_REAL"
  else
    fail "Cannot resolve working OpenClaw contour from systemd unit or PATH"
  fi

  case "$OPENCLAW_REAL" in
    /usr/lib/node_modules/openclaw/*)
      INSTALL_SCOPE="system"
      INSTALL_PREFIX="/usr"
      OPENCLAW_BIN="/usr/bin/openclaw"
      ;;
    /usr/local/lib/node_modules/openclaw/*)
      INSTALL_SCOPE="system"
      INSTALL_PREFIX="/usr/local"
      OPENCLAW_BIN="/usr/local/bin/openclaw"
      ;;
    *)
      fail "Unsupported working contour for production updater: ${OPENCLAW_REAL}"
      ;;
  esac

  [[ -x "$OPENCLAW_BIN" ]] || fail "Expected canonical CLI not found: ${OPENCLAW_BIN}"
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

get_cli_version(){ get_bin_version "$OPENCLAW_BIN"; }
get_path_cli_version(){ get_bin_version "$PATH_OPENCLAW_BIN"; }

ensure_runtime_truth(){
  discover_cli_layout
  UNIT_FRAGMENT_PATH="$(get_unit_fragment_path)"
  if [[ -n "$UNIT_FRAGMENT_PATH" ]]; then
    log "Runtime truth: unit fragment=${UNIT_FRAGMENT_PATH}"
  else
    log "Runtime truth: unit fragment path unavailable"
  fi
}

log_cli_layout(){
  discover_cli_layout
  log "CLI layout: PATH_OPENCLAW_BIN=${PATH_OPENCLAW_BIN:-<missing>} PATH_REAL=${PATH_OPENCLAW_REAL:-<missing>} PATH_VER=${PATH_OPENCLAW_BIN:+$(get_path_cli_version)}"
  log "CLI layout: UNIT_OPENCLAW_ENTRY=${UNIT_OPENCLAW_ENTRY:-<missing>} UNIT_OPENCLAW_REAL=${UNIT_OPENCLAW_REAL:-<missing>}"
  log "CLI layout: CANONICAL_OPENCLAW_BIN=${OPENCLAW_BIN:-<missing>} CANONICAL_REAL=${OPENCLAW_REAL:-<missing>} CANONICAL_VER=$(get_cli_version) INSTALL_SCOPE=${INSTALL_SCOPE} INSTALL_PREFIX=${INSTALL_PREFIX}"

  if [[ -n "$PATH_OPENCLAW_REAL" && -n "$UNIT_OPENCLAW_REAL" && "$PATH_OPENCLAW_REAL" != "$UNIT_OPENCLAW_REAL" ]]; then
    log "CLI path drift detected: PATH openclaw differs from unit contour"
  fi
}

resolve_target_version(){
  local status_out parsed npm_latest

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
  local path_ver canonical_ver
  path_ver="$(get_path_cli_version)"
  canonical_ver="$(get_cli_version)"

  log "CLI truth check: PATH_BIN=${PATH_OPENCLAW_BIN:-<missing>} PATH_REAL=${PATH_OPENCLAW_REAL:-<missing>} PATH_VER=${path_ver:-<unknown>}"
  log "CLI truth check: UNIT_REAL=${UNIT_OPENCLAW_REAL:-<missing>} CANONICAL_REAL=${OPENCLAW_REAL:-<missing>} CANONICAL_VER=${canonical_ver:-<unknown>}"

  [[ -n "$canonical_ver" ]] || { log "CLI truth failed: canonical CLI version unknown"; return 1; }
  [[ -n "$UNIT_OPENCLAW_REAL" ]] || { log "CLI truth failed: unit contour unresolved"; return 1; }
  [[ "$UNIT_OPENCLAW_REAL" == "$OPENCLAW_REAL" ]] || { log "CLI truth failed: canonical realpath differs from unit contour"; return 1; }

  if [[ -n "$PATH_OPENCLAW_BIN" && -n "$path_ver" && "$path_ver" != "$canonical_ver" ]]; then
    log "CLI truth warning: PATH version $path_ver != canonical version $canonical_ver"
  fi

  log "CLI truth OK"
}

check_gateway_truth(){
  [[ -n "$UNIT_EXECSTART_LINE" ]] || { log "Gateway truth failed: unit ExecStart unavailable"; return 1; }
  [[ -n "$UNIT_OPENCLAW_ENTRY" ]] || { log "Gateway truth failed: cannot resolve unit openclaw entry"; return 1; }
  [[ -n "$UNIT_OPENCLAW_REAL" ]] || { log "Gateway truth failed: cannot resolve unit openclaw realpath"; return 1; }
  [[ "$UNIT_OPENCLAW_REAL" == "$OPENCLAW_REAL" ]] || { log "Gateway truth failed: unit contour realpath differs from canonical contour"; return 1; }

  local first_token
  first_token="$(printf '%s\n' "$UNIT_EXECSTART_ARGS" | sed -n '1p')"
  if [[ -z "$first_token" ]]; then
    log "Gateway truth failed: unit ExecStart args unavailable"
    return 1
  fi

  if [[ "$(basename "$first_token")" != "node" && "$(basename "$first_token")" != "openclaw" ]]; then
    log "Gateway truth failed: ExecStart does not start with node or openclaw entry"
    return 1
  fi

  printf '%s\n' "$UNIT_EXECSTART_LINE" | grep -F ' gateway' >/dev/null || { log "Gateway truth failed: ExecStart missing gateway subcommand"; return 1; }
  [[ -n "$UNIT_GATEWAY_PORT" ]] || { log "Gateway truth failed: cannot resolve gateway port from unit args"; return 1; }

  log "Gateway truth OK: entry=${UNIT_OPENCLAW_ENTRY} real=${UNIT_OPENCLAW_REAL} port=${UNIT_GATEWAY_PORT}"
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
}

check_install_target(){
  discover_cli_layout
  [[ "$INSTALL_SCOPE" == "system" ]] || fail "Only system install is supported by this production updater"
  need sudo
  if sudo -n true 2>/dev/null; then
    log "Install target check OK: system install via ${INSTALL_PREFIX} (sudo cached)"
  else
    log "Install target check: system install via ${INSTALL_PREFIX} (sudo will prompt if needed)"
  fi
  return 0
}

run_npm_install(){
  local version="$1"
  discover_cli_layout
  [[ "$INSTALL_SCOPE" == "system" ]] || fail "Only system install is supported"
  log "npm install target: system (/usr)"
  sudo env PATH="$PATH" npm install -g "openclaw@${version}" | tee -a "$LOG_FILE"
}

ensure_gateway_active(){
  local context="$1"
  if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    return 0
  fi
  log "Gateway inactive during ${context}. Last logs:"
  journalctl --user -u "$SERVICE_NAME" -n 120 --no-pager | tee -a "$LOG_FILE" >/dev/null || true
  fail "Gateway is not active"
}

smoke_checks(){
  log "Smoke checks: service active + gateway status + deep status + channel probe"
  ensure_gateway_active "smoke checks"
  oc gateway status | tee -a "$LOG_FILE" >/dev/null
  oc status --deep | tee -a "$LOG_FILE" >/dev/null
  oc channels status --probe --timeout 30000 | tee -a "$LOG_FILE" >/dev/null
  journalctl --user -u "$SERVICE_NAME" -n 120 --no-pager | tee -a "$LOG_FILE" >/dev/null || true
}

verify_post_update(){
  log "=== VERIFY ==="
  ensure_gateway_active "verify"
  oc --version | tee -a "$LOG_FILE" >/dev/null
  oc gateway status | tee -a "$LOG_FILE" >/dev/null
  oc status --deep | tee -a "$LOG_FILE" >/dev/null
  oc channels status --probe --timeout 30000 | tee -a "$LOG_FILE" >/dev/null
  check_cli_truth || fail "Verify failed: CLI path truth mismatch"
  check_version_sync || fail "Verify failed: CLI/unit version mismatch"
  check_gateway_truth || fail "Verify failed: gateway truth mismatch"
  log "VERIFY SUCCESS"
}

backup_state(){
  local snap_dir="${BACKUP_ROOT}/${TS}"
  mkdir -p "$snap_dir"
  cp -a "${HOME}/.openclaw" "$snap_dir/" || true
  systemctl --user cat "$SERVICE_NAME" >"${snap_dir}/${SERVICE_NAME}.unit.txt" || true
  journalctl --user -u "$SERVICE_NAME" -n 300 --no-pager >"${snap_dir}/gateway.log" || true
  cat >"$STATE_FILE" <<EOF_STATE
TS=${TS}
BACKUP_DIR=${snap_dir}
PREV_VERSION=$(get_cli_version)
TARGET_VERSION=${TARGET_VERSION}
CANONICAL_OPENCLAW_BIN=${OPENCLAW_BIN}
CANONICAL_OPENCLAW_REAL=${OPENCLAW_REAL}
PATH_OPENCLAW_BIN=${PATH_OPENCLAW_BIN}
UNIT_OPENCLAW_ENTRY=${UNIT_OPENCLAW_ENTRY}
UNIT_OPENCLAW_REAL=${UNIT_OPENCLAW_REAL}
INSTALL_SCOPE=${INSTALL_SCOPE}
INSTALL_PREFIX=${INSTALL_PREFIX}
EOF_STATE
  log "Backup completed: ${snap_dir}"
}

precheck(){
  need npm; need systemctl; need journalctl; need sed; need grep; need readlink; need df; need free; need tee; need flock
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
  check_install_target
  check_cli_truth || fail "Precheck failed: working contour mismatch"
  check_version_sync || log "Precheck warning: CLI/unit version drift detected"
  check_gateway_truth || fail "Precheck failed: gateway unit is not the expected production contour"
  log "Precheck passed"
}

do_update(){
  log "=== UPDATE ==="
  precheck
  confirm "Proceed with update to ${TARGET_VERSION}?" || fail "Cancelled"

  log "Step: backup state before install"
  backup_state

  log "Step: install openclaw@${TARGET_VERSION}"
  run_npm_install "$TARGET_VERSION"

  discover_cli_layout
  log_cli_layout

  [[ "$(get_cli_version)" == "$TARGET_VERSION" ]] || fail "Canonical CLI version mismatch after update"

  log "Step: refresh gateway unit from updated CLI"
  oc gateway install --force | tee -a "$LOG_FILE" >/dev/null
  systemctl --user daemon-reload
  systemctl --user restart "${SERVICE_NAME}.service"
  sleep 4

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
  [[ "$INSTALL_SCOPE" == "system" ]] || fail "Rollback supports only system install"

  log "Step: reinstall previous version ${PREV_VERSION}"
  run_npm_install "$PREV_VERSION"

  if [[ -d "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}/.openclaw" ]]; then
    rm -rf "${HOME}/.openclaw"
    cp -a "${BACKUP_DIR}/.openclaw" "${HOME}/.openclaw"
  fi

  oc gateway install --force | tee -a "$LOG_FILE" >/dev/null
  systemctl --user daemon-reload
  systemctl --user restart "${SERVICE_NAME}.service"
  sleep 4

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
  $0 update 2026.5.28

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
