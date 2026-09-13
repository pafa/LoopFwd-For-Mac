#!/usr/bin/env bash
# Gate C: one command after .ready-ok → intake/ready/oneshot/device-e2e (fail-closed).
# Never invents Team ID / .p8. Never claims PASS without same live requestId proof.
#
# Order:
#   1) require .ready-ok
#   2) export GATE_C_STRICT=1
#   3) resolve paths
#   4) gate-c-require-proof-tip.sh (TIP= / PROOF=1|0; fail-closed)
#   5) require openDetail: false tip marker
#   6) require physical iPhone/iPad (not Simulator/Mac)
#   7) optional intake (if drop-dir has creds + intake script)
#   8) ready-check (when applied env present)
#   9) run-gate-c-oneshot.sh
#  10) gate-c-start-hub.sh (Real Hub, GATE_C_STRICT=1; fail-closed; not MockHub)
#  11) gate-c-device-e2e.sh
set -euo pipefail

DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
STORE_SCRIPTS="$HOME/.cursor/stores/bc-3b748a56-060e-4afd-b9df-ede1d370641d/internal/scripts"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READY_OK="$DROP_DIR/.ready-ok"
# Exact Mac tip marker strings (must match Sources/LoopFwd tip — do not invent variants).
MARKER_PROOF='GATE_C_SAME_REQUEST_ID_PROOF'
MARKER_OPENDETAIL='openDetail: false'
# Armed watcher drop-dir convention (do not rename): team-id.txt + AuthKey_*.p8 / AuthKey.p8

usage() {
  cat <<'EOF'
Usage: RUN-GATE-C-DEVICE-E2E.sh

Fail-closed Gate C device E2E orchestrator.
Requires ~/LoopFwd-GateC-Creds/.ready-ok (watcher / intake after real creds).
Requires Mac tip WITH GATE_C_SAME_REQUEST_ID_PROOF via gate-c-require-proof-tip.sh,
plus openDetail: false. Requires a physical iPhone/iPad via
gate-c-require-physical-device.sh.
Exports GATE_C_STRICT=1. Runs oneshot, starts Real Hub (not MockHub),
then device-e2e helpers.
Does not invent Team ID / .p8. Does not claim evidence PASS without
same live requestId proof artifacts (GATE_C_SAME_REQUEST_ID_PROOF).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "RUN-GATE-C-DEVICE-E2E: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "RUN-GATE-C-DEVICE-E2E: FAIL CLOSED — $*" >&2
  exit 1
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

find_script() {
  local name="$1"
  local c
  # Prefer durable in-repo copies, then drop-local / self / store.
  for c in \
    "${LOOPFWD_IOS_REPO:-}/scripts/$name" \
    "$HOME/Documents/Cursor/LoopFwd-For-iOS/scripts/$name" \
    "$HOME/Documents/LoopFwd-For-iOS/scripts/$name" \
    "${LOOPFWD_MAC_REPO:-}/scripts/gate-c/$name" \
    "$HOME/Documents/Cursor/LoopFwd-For-Mac/scripts/gate-c/$name" \
    "$HOME/Documents/Cursor/LoopFwd-For-Mac/scripts/$name" \
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

# --- fail closed without .ready-ok ---
if [[ ! -f "$READY_OK" ]]; then
  echo "RUN-GATE-C-DEVICE-E2E: missing .ready-ok at $READY_OK" >&2
  echo "  Drop real team-id.txt + AuthKey_*.p8 into $DROP_DIR (do not invent)." >&2
  echo "  Wait for watcher com.loopfwd.gate-c-creds-watch, then re-run." >&2
  echo "  Evidence: NOT_RUN — not PASS." >&2
  exit 1
fi

# Refuse if drop-dir convention files vanished after .ready-ok (never invent).
if [[ ! -f "$DROP_DIR/team-id.txt" ]]; then
  fail "missing team-id.txt in $DROP_DIR (watcher convention; do not invent)"
fi
shopt -s nullglob
_p8_matches=("$DROP_DIR"/AuthKey_*.p8)
shopt -u nullglob
if ((${#_p8_matches[@]} == 0)) && [[ ! -f "$DROP_DIR/AuthKey.p8" ]]; then
  fail "missing AuthKey_*.p8 / AuthKey.p8 in $DROP_DIR (watcher convention; do not invent)"
fi

export GATE_C_STRICT=1
export LOOPFWD_GATE_C_CREDS_DIR="$DROP_DIR"

# Prefer resolve-paths (scrubs non-existent LOOPFWD_MAC_REPO poison, then
# mac-repo.env / hub-start). Env only; no git switch.
RESOLVE="$(find_script gate-c-resolve-paths.sh || true)"
if [[ -n "$RESOLVE" ]]; then
  # shellcheck disable=SC1090
  source "$RESOLVE"
else
  log "gate-c-resolve-paths.sh missing — using defaults"
  if [[ -n "${LOOPFWD_MAC_REPO:-}" && ! -d "${LOOPFWD_MAC_REPO}" ]]; then
    log "ignoring non-existent LOOPFWD_MAC_REPO=${LOOPFWD_MAC_REPO}"
    unset LOOPFWD_MAC_REPO
  fi
  if [[ -z "${LOOPFWD_MAC_REPO:-}" && -f "$DROP_DIR/mac-repo.env" ]]; then
    # shellcheck disable=SC1090
    source "$DROP_DIR/mac-repo.env"
  fi
  export LOOPFWD_IOS_REPO="${LOOPFWD_IOS_REPO:-$HOME/Documents/Cursor/LoopFwd-For-iOS}"
  # Prefer hub-start when present with proof; else primary (fail-closed later).
  _hub="$HOME/Documents/Cursor/LoopFwd-worktrees/mac-gate-c-hub-start-641d"
  if [[ -z "${LOOPFWD_MAC_REPO:-}" ]]; then
    if [[ -f "$_hub/scripts/gate-c/gate-c-require-proof-tip.sh" ]] \
      && git -C "$_hub" grep -q 'GATE_C_SAME_REQUEST_ID_PROOF' -- '*.swift' 2>/dev/null; then
      export LOOPFWD_MAC_REPO="$_hub"
    else
      export LOOPFWD_MAC_REPO="${LOOPFWD_MAC_REPO:-$HOME/Documents/Cursor/LoopFwd-For-Mac}"
    fi
  fi
fi

MAC_REPO="${LOOPFWD_MAC_REPO:-$HOME/Documents/Cursor/LoopFwd-For-Mac}"
[[ -d "$MAC_REPO/.git" || -f "$MAC_REPO/.git" ]] || fail "Mac repo missing/unusable: $MAC_REPO"
log "LOOPFWD_MAC_REPO=$MAC_REPO"

# --- proof tip BEFORE Hub start / device steps (fail-closed; prints TIP=/PROOF=) ---
PROOF_TIP="$(find_script gate-c-require-proof-tip.sh || true)"
[[ -n "$PROOF_TIP" ]] || fail "gate-c-require-proof-tip.sh not found in drop-dir / store / in-repo"
log "checking proof tip: $PROOF_TIP (LOOPFWD_MAC_REPO=$MAC_REPO)"
bash "$PROOF_TIP" || fail "PROOF tip gate failed — device E2E blocked (not PASS)"

# openDetail marker still required on the same tip
if ! git -C "$MAC_REPO" grep -q -F "$MARKER_OPENDETAIL" -- '*.swift'; then
  fail "Mac tip missing exact marker $MARKER_OPENDETAIL under $MAC_REPO"
fi
log "Mac markers OK (exact): $MARKER_PROOF ; $MARKER_OPENDETAIL"

ONESHOT="$(find_script run-gate-c-oneshot.sh || true)"
START_HUB="$(find_script gate-c-start-hub.sh || true)"
DEVICE_E2E="$(find_script gate-c-device-e2e.sh || true)"
PHYS="$(find_script gate-c-require-physical-device.sh || true)"
[[ -n "$ONESHOT" ]] || fail "run-gate-c-oneshot.sh not found in drop-dir / store scripts"
[[ -n "$START_HUB" ]] || fail "gate-c-start-hub.sh not found in drop-dir / store scripts (Real Hub required)"
[[ -n "$DEVICE_E2E" ]] || fail "gate-c-device-e2e.sh not found in drop-dir / store scripts"
[[ -n "$PHYS" ]] || fail "gate-c-require-physical-device.sh not found in drop-dir / store scripts"

# Prefer Cursor iOS path for oneshot REPO default if legacy missing.
if [[ -n "${LOOPFWD_IOS_REPO:-}" ]]; then
  export LOOPFWD_IOS_REPO
  export REPO="${REPO:-$LOOPFWD_IOS_REPO}"
fi

# --- physical device before oneshot / device-e2e ---
log "checking physical device: $PHYS"
bash "$PHYS" || fail "PHYSICAL_DEVICE=MISSING — connect a physical iPhone/iPad before E2E"

# Optional: re-run intake if present and drop-dir still has team + p8 (idempotent).
INTAKE="${GATE_C_INTAKE:-}"
if [[ -z "$INTAKE" && -n "${LOOPFWD_IOS_REPO:-}" ]]; then
  INTAKE="$LOOPFWD_IOS_REPO/scripts/gate-c-creds-intake.sh"
fi
if [[ -z "$INTAKE" || ! -x "$INTAKE" ]]; then
  # Drop-dir copy (armed watcher convention / local prestaged helpers).
  if [[ -x "$DROP_DIR/gate-c-creds-intake.sh" ]]; then
    INTAKE="$DROP_DIR/gate-c-creds-intake.sh"
  fi
fi
if [[ -x "$INTAKE" ]]; then
  log "running intake: $INTAKE"
  "$INTAKE" --drop-dir "$DROP_DIR" || fail "intake failed"
else
  log "intake script not executable/missing — skipping (watcher may have already applied)"
fi

READY_CHECK="${GATE_C_READY_CHECK:-}"
if [[ -z "$READY_CHECK" && -n "${LOOPFWD_IOS_REPO:-}" ]]; then
  READY_CHECK="$LOOPFWD_IOS_REPO/scripts/gate-c-ready-check.sh"
fi
if [[ -z "$READY_CHECK" || ! -x "$READY_CHECK" ]]; then
  if [[ -x "$DROP_DIR/gate-c-ready-check.sh" ]]; then
    READY_CHECK="$DROP_DIR/gate-c-ready-check.sh"
  fi
fi
APNS_ENV_FILE="${LOOPFWD_APNS_ENV_FILE:-${LOOPFWD_IOS_REPO:-}/Config/gate-c-apns.env}"
if [[ -f "$APNS_ENV_FILE" && -x "$READY_CHECK" ]]; then
  log "sourcing applied env + ready-check"
  set -a
  # shellcheck disable=SC1090
  source "$APNS_ENV_FILE"
  set +a
  export GATE_C_STRICT=1
  "$READY_CHECK" || fail "ready-check failed"
else
  log "ready-check deferred to oneshot (env or script not ready yet)"
fi

log "running oneshot: $ONESHOT"
bash "$ONESHOT" || fail "oneshot failed"

# Fail-closed Real Hub bring-up (Cursor LoopFwd-For-iOS/Hub). Not MockHub.
log "ensuring Real Hub GATE_C_STRICT=1: $START_HUB"
bash "$START_HUB" || fail "Real Hub not GATE_C_STRICT+APNs — device E2E blocked (not PASS)"

log "running device-e2e: $DEVICE_E2E"
# device-e2e fails closed without REQUEST_ID / capture proof — that is intentional.
bash "$DEVICE_E2E" || fail "device-e2e failed (no PASS without same live requestId proof)"

log "orchestrator finished helpers — PASS only if GATE_C_SAME_REQUEST_ID_PROOF artifacts exist"
log "Do not treat this script alone as Gate C evidence PASS."
exit 0
