#!/usr/bin/env bash
# Resolve LoopFwd iOS/Mac repo roots on this Mac. Never invents credentials.
# Sourced by Gate C runners. Prefer Cursor paths; fall back to legacy Documents paths.
#
# Exports (when found):
#   LOOPFWD_IOS_REPO / LOOPFWD_MAC_REPO / LOOPFWD_GATE_C_CREDS_DIR
#   GATE_C_INTAKE / GATE_C_READY_CHECK / GATE_C_APPLY
#
# Mac default (when LOOPFWD_MAC_REPO unset):
#   1) source drop-dir mac-repo.env if present (durable operator default)
#   2) prefer hub-start WT when it exists WITH GATE_C_SAME_REQUEST_ID_PROOF
#      + scripts/gate-c/gate-c-require-proof-tip.sh
#   3) else fall back to primary checkout only if THAT tip has proof
#   4) else leave a best-effort path for fail-closed proof-tip messaging
# Never git-switches a dirty/unrelated checkout — env default only.
set -euo pipefail

_pick_dir() {
  local d
  for d in "$@"; do
    if [[ -d "$d" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

# Swift tip marker only (primary may lack scripts/gate-c/).
_mac_has_swift_proof() {
  local repo="$1"
  [[ -n "$repo" ]] || return 1
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 1
  git -C "$repo" grep -q 'GATE_C_SAME_REQUEST_ID_PROOF' -- '*.swift' 2>/dev/null
}

# Hub-start eligibility: Swift proof + in-repo proof-tip script.
_mac_is_hub_start_ready() {
  local repo="$1"
  _mac_has_swift_proof "$repo" || return 1
  [[ -f "$repo/scripts/gate-c/gate-c-require-proof-tip.sh" ]]
}

export LOOPFWD_GATE_C_CREDS_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"

if [[ -z "${LOOPFWD_IOS_REPO:-}" ]]; then
  LOOPFWD_IOS_REPO="$(_pick_dir \
    "$HOME/Documents/Cursor/LoopFwd-For-iOS" \
    "$HOME/Documents/LoopFwd-For-iOS" \
    || true)"
  export LOOPFWD_IOS_REPO
fi

_HUB_START_WT="$HOME/Documents/Cursor/LoopFwd-worktrees/mac-gate-c-hub-start-641d"
_PRIMARY_MAC="$HOME/Documents/Cursor/LoopFwd-For-Mac"
_LEGACY_MAC="$HOME/Documents/LoopFwd-For-Mac"

# Durable drop-dir override (env only; no git checkout switch).
_MAC_REPO_FROM_DEFAULT=0
if [[ -z "${LOOPFWD_MAC_REPO:-}" ]]; then
  _mac_env="$LOOPFWD_GATE_C_CREDS_DIR/mac-repo.env"
  if [[ -f "$_mac_env" ]]; then
    # shellcheck disable=SC1090
    source "$_mac_env"
    _MAC_REPO_FROM_DEFAULT=1
  fi
fi

# If still unset, prefer proof-bearing hub-start; else primary with Swift proof.
if [[ -z "${LOOPFWD_MAC_REPO:-}" ]]; then
  if _mac_is_hub_start_ready "$_HUB_START_WT"; then
    LOOPFWD_MAC_REPO="$_HUB_START_WT"
  elif _mac_has_swift_proof "$_PRIMARY_MAC"; then
    LOOPFWD_MAC_REPO="$_PRIMARY_MAC"
  elif _mac_has_swift_proof "$_LEGACY_MAC"; then
    LOOPFWD_MAC_REPO="$_LEGACY_MAC"
  else
    LOOPFWD_MAC_REPO="$(_pick_dir "$_HUB_START_WT" "$_PRIMARY_MAC" "$_LEGACY_MAC" || true)"
  fi
  _MAC_REPO_FROM_DEFAULT=1
  export LOOPFWD_MAC_REPO
fi

# Soft recovery for durable default only: hub-start / mac-repo.env path vanished
# or lacks Swift proof → fall back only when primary tip has Swift proof.
# Explicit operator LOOPFWD_MAC_REPO to an unrelated bad path stays fail-closed.
if [[ -n "${LOOPFWD_MAC_REPO:-}" ]] && ! _mac_has_swift_proof "$LOOPFWD_MAC_REPO"; then
  if [[ "$_MAC_REPO_FROM_DEFAULT" == "1" || "$LOOPFWD_MAC_REPO" == "$_HUB_START_WT" ]]; then
    if _mac_has_swift_proof "$_PRIMARY_MAC"; then
      export LOOPFWD_MAC_REPO="$_PRIMARY_MAC"
    elif _mac_has_swift_proof "$_LEGACY_MAC"; then
      export LOOPFWD_MAC_REPO="$_LEGACY_MAC"
    fi
  fi
  # else keep current path; gate-c-require-proof-tip.sh will FAIL CLOSED
fi

# Aliases used by older scripts.
export LOOPFWD_IOS_ROOT="${LOOPFWD_IOS_ROOT:-${LOOPFWD_IOS_REPO:-}}"
export LOOPFWD_MAC_ROOT="${LOOPFWD_MAC_ROOT:-${LOOPFWD_MAC_REPO:-}}"

if [[ -n "${LOOPFWD_IOS_REPO:-}" ]]; then
  export GATE_C_INTAKE="${GATE_C_INTAKE:-$LOOPFWD_IOS_REPO/scripts/gate-c-creds-intake.sh}"
  export GATE_C_READY_CHECK="${GATE_C_READY_CHECK:-$LOOPFWD_IOS_REPO/scripts/gate-c-ready-check.sh}"
  export GATE_C_APPLY="${GATE_C_APPLY:-$LOOPFWD_IOS_REPO/scripts/gate-c-apply-creds.sh}"
fi

if [[ -n "${LOOPFWD_IOS_REPO:-}" ]]; then
  export GATE_C_START_HUB="${GATE_C_START_HUB:-$LOOPFWD_IOS_REPO/scripts/gate-c-start-hub.sh}"
fi
if [[ -z "${GATE_C_START_HUB:-}" || ! -f "${GATE_C_START_HUB}" ]]; then
  if [[ -n "${LOOPFWD_MAC_REPO:-}" && -f "$LOOPFWD_MAC_REPO/scripts/gate-c/gate-c-start-hub.sh" ]]; then
    export GATE_C_START_HUB="$LOOPFWD_MAC_REPO/scripts/gate-c/gate-c-start-hub.sh"
  fi
fi
