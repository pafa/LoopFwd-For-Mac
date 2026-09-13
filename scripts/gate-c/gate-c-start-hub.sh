#!/usr/bin/env bash
# Gate C: start Real Hub (LoopFwd-For-iOS/Hub) with GATE_C_STRICT=1.
# Fail-closed without applied APNs env. Never invents Team ID / .p8.
# Never uses MockHub. Does not claim Gate C PASS.
#
# Operator mirror under LoopFwd-For-Mac/scripts/gate-c/ (drop-dir churn survival).
# Prefers LoopFwd-For-iOS/scripts/gate-c-start-hub.sh when that file exists.
set -euo pipefail

# Mac operator copy. Prefer durable iOS in-repo script when present.
_IOS_START=""
for _c in \
  "${LOOPFWD_IOS_REPO:-}/scripts/gate-c-start-hub.sh" \
  "$HOME/Documents/Cursor/LoopFwd-For-iOS/scripts/gate-c-start-hub.sh" \
  "$HOME/Documents/LoopFwd-For-iOS/scripts/gate-c-start-hub.sh"; do
  if [[ -n "$_c" && -f "$_c" ]]; then
    _IOS_START="$_c"
    break
  fi
done
# Avoid infinite recursion if this file is the only copy.
if [[ -n "$_IOS_START" && "$_IOS_START" != "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" ]]; then
  exec bash "$_IOS_START" "$@"
fi


DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE_SCRIPTS="$HOME/.cursor/stores/bc-3b748a56-060e-4afd-b9df-ede1d370641d/internal/scripts"
HUB_URL="${LOOPFWD_HUB_URL:-http://127.0.0.1:8787}"
HUB_LOG="${LOOPFWD_HUB_LOG:-$DROP_DIR/hub-strict.log}"
HUB_PID_FILE="${LOOPFWD_HUB_PID_FILE:-$DROP_DIR/hub-strict.pid}"

usage() {
  cat <<'EOF'
Usage: gate-c-start-hub.sh

Starts Real Hub from LoopFwd-For-iOS/Hub (Cursor path preferred) with
GATE_C_STRICT=1 after sourcing applied Config/gate-c-apns.env.

Fail-closed if:
  - iOS Hub tree missing
  - applied APNs env missing / incomplete
  - port occupied by a non-strict / unconfigured Hub
  - Hub fails to become gateCStrict + apns.configured

Does not invent credentials. Does not start MockHub. Not Gate C PASS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "gate-c-start-hub: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "gate-c-start-hub: FAIL CLOSED — $*" >&2
  exit 1
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

find_script() {
  local name="$1"
  local c
  # Prefer durable in-repo copies, then drop-local, then sibling, then store.
  for c in \
    "${LOOPFWD_IOS_REPO:-}/scripts/$name" \
    "$HOME/Documents/Cursor/LoopFwd-For-iOS/scripts/$name" \
    "$HOME/Documents/LoopFwd-For-iOS/scripts/$name" \
    "${LOOPFWD_MAC_REPO:-}/scripts/gate-c/$name" \
    "$HOME/Documents/Cursor/LoopFwd-For-Mac/scripts/gate-c/$name" \
    "$DROP_DIR/$name" \
    "$SELF_DIR/$name" \
    "$STORE_SCRIPTS/$name"; do
    if [[ -n "$c" && -f "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

RESOLVE="$(find_script gate-c-resolve-paths.sh || true)"
if [[ -n "$RESOLVE" ]]; then
  # shellcheck disable=SC1090
  source "$RESOLVE"
fi

REPO="${LOOPFWD_IOS_REPO:-}"
# When this file lives at <repo>/scripts/gate-c-start-hub.sh, prefer that tree.
if [[ -z "$REPO" && -d "$SELF_DIR/../Hub" ]]; then
  REPO="$(cd "$SELF_DIR/.." && pwd)"
fi
if [[ -z "$REPO" ]]; then
  for d in \
    "$HOME/Documents/Cursor/LoopFwd-For-iOS" \
    "$HOME/Documents/LoopFwd-For-iOS"; do
    if [[ -d "$d/Hub" ]]; then
      REPO="$d"
      break
    fi
  done
fi
[[ -n "$REPO" && -d "$REPO/Hub" ]] || fail "Real Hub tree missing (expected LoopFwd-For-iOS/Hub under Documents/Cursor)"
export LOOPFWD_IOS_REPO="$REPO"

HUB_DIR="$REPO/Hub"
[[ -f "$HUB_DIR/server.mjs" || -f "$HUB_DIR/package.json" ]] || fail "Hub package/server missing under $HUB_DIR"

APNS_ENV_FILE="${LOOPFWD_APNS_ENV_FILE:-$REPO/Config/gate-c-apns.env}"
[[ -f "$APNS_ENV_FILE" ]] || fail "applied APNs env missing: $APNS_ENV_FILE (drop real team-id.txt + AuthKey_*.p8; wait for watcher; do not invent)"

set -a
# shellcheck disable=SC1090
source "$APNS_ENV_FILE"
set +a

[[ -n "${APNS_KEY_PATH:-}" && -f "${APNS_KEY_PATH}" ]] || fail "APNS_KEY_PATH unset or missing after sourcing $APNS_ENV_FILE"
[[ -n "${APNS_KEY_ID:-}" ]] || fail "APNS_KEY_ID unset after sourcing $APNS_ENV_FILE"
[[ -n "${APNS_TEAM_ID:-}" ]] || fail "APNS_TEAM_ID unset after sourcing $APNS_ENV_FILE"

hub_health_json() {
  curl -fsS --max-time 2 "$HUB_URL/v1/health" 2>/dev/null || true
}

hub_is_gate_c_ready() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | python3 -c '
import json,sys
try:
  h=json.load(sys.stdin)
except Exception:
  sys.exit(1)
ok = bool(h.get("ok"))
strict = bool(h.get("gateCStrict")) or bool(h.get("demoClearDisabled"))
apns = h.get("apns") or {}
configured = bool(apns.get("configured"))
sys.exit(0 if (ok and strict and configured) else 1)
' 2>/dev/null
}

hub_port_busy() {
  curl -fsS --max-time 1 "$HUB_URL/v1/health" >/dev/null 2>&1
}

HEALTH="$(hub_health_json)"
if hub_is_gate_c_ready "$HEALTH"; then
  log "Real Hub already GATE_C_STRICT + APNs configured at $HUB_URL"
  exit 0
fi

if hub_port_busy; then
  echo "gate-c-start-hub: Hub on $HUB_URL is UP but NOT Gate-C-ready" >&2
  echo "  Need gateCStrict/demoClearDisabled + apns.configured (real creds)." >&2
  echo "  Stop the non-strict Hub, then re-run. Do not use MockHub." >&2
  fail "existing Hub not GATE_C_STRICT+APNs"
fi

[[ -d "$HUB_DIR/node_modules" ]] || {
  log "Hub node_modules missing — running npm install"
  (cd "$HUB_DIR" && npm install) || fail "npm install failed in $HUB_DIR"
}

mkdir -p "$DROP_DIR"
: >"$HUB_LOG" || true

log "starting Real Hub with GATE_C_STRICT=1 from $HUB_DIR (not MockHub)"
(
  cd "$HUB_DIR"
  set -a
  # shellcheck disable=SC1090
  source "$APNS_ENV_FILE"
  set +a
  export GATE_C_STRICT=1
  if [[ -f package.json ]]; then
    nohup env GATE_C_STRICT=1 npm start >>"$HUB_LOG" 2>&1 &
  else
    nohup env GATE_C_STRICT=1 node server.mjs >>"$HUB_LOG" 2>&1 &
  fi
  echo $! >"$HUB_PID_FILE"
)

for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 0.5
  HEALTH="$(hub_health_json)"
  if hub_is_gate_c_ready "$HEALTH"; then
    log "Real Hub GATE_C_STRICT + APNs configured — health OK (not Gate C PASS)"
    exit 0
  fi
done

if hub_port_busy; then
  HEALTH="$(hub_health_json)"
  echo "gate-c-start-hub: Hub listening but not yet gateCStrict+apns.configured" >&2
  echo "  Inspect: curl -s $HUB_URL/v1/health | python3 -m json.tool" >&2
  echo "  Log: $HUB_LOG" >&2
  fail "Hub up but not Gate-C-ready"
fi

fail "Real Hub failed to start — see $HUB_LOG"
