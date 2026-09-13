#!/usr/bin/env bash
# Gate C device E2E entry for Mac operators.
# Prefer durable drop-dir orchestrator when present; otherwise fail closed with pointers.
# Never invents Team ID / .p8. Never PASS without GATE_C_SAME_REQUEST_ID_PROOF.
#
# Early gate (always): scripts/gate-c/gate-c-require-proof-tip.sh → TIP= / PROOF=1|0.
# Full orchestrator (drop-dir SoT when present): ~/LoopFwd-GateC-Creds/RUN-GATE-C-DEVICE-E2E.sh
# which also re-runs the proof tip before Hub start / device steps.
#
# Default LOOPFWD_MAC_REPO (when unset): this worktree if it has proof, else drop-dir
# mac-repo.env / resolve-paths (prefer hub-start). Env only — no git checkout switch.
set -euo pipefail

DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

export LOOPFWD_IOS_REPO="${LOOPFWD_IOS_REPO:-$HOME/Documents/Cursor/LoopFwd-For-iOS}"

if [[ -z "${LOOPFWD_MAC_REPO:-}" ]]; then
  if [[ -f "$DROP_DIR/gate-c-resolve-paths.sh" ]]; then
    # shellcheck disable=SC1090
    source "$DROP_DIR/gate-c-resolve-paths.sh"
  elif [[ -f "$DROP_DIR/mac-repo.env" ]]; then
    # shellcheck disable=SC1090
    source "$DROP_DIR/mac-repo.env"
  fi
fi
if [[ -z "${LOOPFWD_MAC_REPO:-}" ]]; then
  # This entry lives under hub-start (or another Mac tip) — prefer SELF Mac root when proofful.
  if [[ -f "$MAC_ROOT/scripts/gate-c/gate-c-require-proof-tip.sh" ]] \
    && git -C "$MAC_ROOT" grep -q 'GATE_C_SAME_REQUEST_ID_PROOF' -- '*.swift' 2>/dev/null; then
    export LOOPFWD_MAC_REPO="$MAC_ROOT"
  else
    export LOOPFWD_MAC_REPO="$HOME/Documents/Cursor/LoopFwd-worktrees/mac-gate-c-hub-start-641d"
  fi
fi

# --- proof tip BEFORE drop exec / any Hub or device step (fail-closed) ---
PROOF_TIP="$SELF_DIR/gate-c-require-proof-tip.sh"
if [[ ! -f "$PROOF_TIP" ]]; then
  echo "RUN-GATE-C-DEVICE-E2E: missing in-repo gate-c-require-proof-tip.sh at $PROOF_TIP" >&2
  echo "  Evidence: NOT_RUN — not PASS." >&2
  exit 1
fi
bash "$PROOF_TIP" || {
  echo "RUN-GATE-C-DEVICE-E2E: PROOF tip gate failed — device E2E blocked (not PASS)" >&2
  exit 1
}

DROP_RUN="$DROP_DIR/RUN-GATE-C-DEVICE-E2E.sh"
if [[ -f "$DROP_RUN" ]]; then
  exec bash "$DROP_RUN" "$@"
fi

echo "RUN-GATE-C-DEVICE-E2E: drop-dir orchestrator missing at $DROP_RUN" >&2
echo "  Restage from operator paste / INSTALL-FROM-PASTE, or run helpers under $SELF_DIR." >&2
echo "  start-hub: $LOOPFWD_IOS_REPO/scripts/gate-c-start-hub.sh (preferred) or $SELF_DIR/gate-c-start-hub.sh" >&2
echo "  Evidence: NOT_RUN — not PASS." >&2
exit 1
