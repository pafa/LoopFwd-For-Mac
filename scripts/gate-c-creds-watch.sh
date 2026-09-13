#!/usr/bin/env bash
# Gate C creds watcher — poll drop-dir; when real Team ID + AuthKey appear,
# write .ready-ok and run iOS gate-c-creds-intake.sh. Never invents credentials.
set -euo pipefail

DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
LOG_DIR="${LOOPFWD_GATE_C_LOG_DIR:-$HOME/Library/Logs/LoopFwd}"
LOG_FILE="${LOG_DIR}/gate-c-creds-watch.log"
POLL_SECS="${LOOPFWD_GATE_C_WATCH_POLL_SECS:-15}"
IOS_ROOT="${LOOPFWD_IOS_ROOT:-$HOME/Documents/Cursor/LoopFwd-For-iOS}"
INTAKE="${IOS_ROOT}/scripts/gate-c-creds-intake.sh"
READY_OK="${DROP_DIR}/.ready-ok"
INTAKE_STAMP="${DROP_DIR}/.intake-ran"

mkdir -p "$DROP_DIR" "$LOG_DIR"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
  printf '%s %s\n' "$ts" "$*" | tee -a "$LOG_FILE" >/dev/null
  printf '%s %s\n' "$ts" "$*"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_placeholder_team() {
  local t="$1"
  case "$t" in
    ""|"ABCDEF1234"|"YOURTEAMID1"|"CHANGEME"|"TODO"|"REPLACE_ME"|"xxx"|"XXX"|"null"|"none")
      return 0
      ;;
  esac
  [[ "$t" == TEST* ]] && return 0
  return 1
}

is_placeholder_key_id() {
  local k="$1"
  case "$k" in
    ""|"ABCDEF1234"|"CHANGEME"|"TODO"|"REPLACE_ME"|"xxx"|"XXX"|"null"|"none")
      return 0
      ;;
  esac
  [[ "$k" == TEST* ]] && return 0
  return 1
}

find_auth_key() {
  if [[ -f "$DROP_DIR/AuthKey.p8" ]]; then
    printf '%s' "$DROP_DIR/AuthKey.p8"
    return 0
  fi
  local matches=()
  local f
  shopt -s nullglob
  matches=("$DROP_DIR"/AuthKey_*.p8)
  shopt -u nullglob
  if ((${#matches[@]} == 1)); then
    printf '%s' "${matches[0]}"
    return 0
  fi
  return 1
}

validate_and_ready() {
  local team_file="$DROP_DIR/team-id.txt"
  local key_path=""
  local team=""
  local key_id=""
  local base=""

  [[ -f "$team_file" ]] || return 1
  key_path="$(find_auth_key)" || return 1

  team="$(trim "$(tr -d '\r' <"$team_file" | head -n 1)")"
  if is_placeholder_team "$team"; then
    log "REFUSE placeholder Team ID (do not invent): '${team}'"
    return 2
  fi
  if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    log "REFUSE invalid Team ID format: '${team}'"
    return 2
  fi

  base="$(basename "$key_path")"
  if [[ "$base" =~ ^AuthKey_([A-Z0-9]+)\.p8$ ]]; then
    key_id="${BASH_REMATCH[1]}"
    if is_placeholder_key_id "$key_id"; then
      log "REFUSE placeholder AuthKey id in filename: $base"
      return 2
    fi
  elif [[ "$base" == AuthKey.p8 ]]; then
    :
  else
    log "REFUSE unexpected AuthKey name: $base"
    return 2
  fi

  if ! grep -q 'BEGIN PRIVATE KEY' "$key_path"; then
    log "REFUSE AuthKey missing BEGIN PRIVATE KEY: $key_path"
    return 2
  fi

  # Fingerprint of accepted inputs — re-run intake if files change.
  local fp
  fp="$(
    {
      printf 'team:%s\n' "$team"
      printf 'key:%s\n' "$base"
      shasum -a 256 "$key_path" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )"

  if [[ -f "$READY_OK" && -f "$INTAKE_STAMP" ]]; then
    local prev
    prev="$(trim "$(tr -d '\r' <"$INTAKE_STAMP" | head -n 1)")"
    if [[ "$prev" == "$fp" ]]; then
      return 0
    fi
  fi

  printf '%s\n' "$fp" >"$READY_OK"
  log "READY — wrote $READY_OK (team=$team key=$base)"

  if [[ ! -x "$INTAKE" ]]; then
    log "INTAKE SKIP — missing executable $INTAKE"
    printf '%s\n' "$fp" >"$INTAKE_STAMP"
    return 0
  fi

  log "INTAKE start: $INTAKE --drop-dir $DROP_DIR"
  if "$INTAKE" --drop-dir "$DROP_DIR" >>"$LOG_FILE" 2>&1; then
    printf '%s\n' "$fp" >"$INTAKE_STAMP"
    log "INTAKE OK"
  else
    local rc=$?
    log "INTAKE FAIL rc=$rc (will retry after next change or poll)"
    rm -f "$INTAKE_STAMP"
    return "$rc"
  fi
  return 0
}

log "gate-c-creds-watch START drop=$DROP_DIR poll=${POLL_SECS}s intake=$INTAKE"

while true; do
  set +e
  validate_and_ready
  rc=$?
  set -e
  # rc 1 = not present yet (quiet); 2 = refused; other = intake fail
  if [[ "$rc" -eq 1 ]]; then
    :
  elif [[ "$rc" -ne 0 ]]; then
    :
  fi
  sleep "$POLL_SECS"
done
