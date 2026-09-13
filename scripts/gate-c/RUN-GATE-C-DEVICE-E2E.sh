#!/usr/bin/env bash
# Gate C device E2E entry for Mac operators.
# Prefer durable drop-dir orchestrator when present; otherwise fail closed with pointers.
# Never invents Team ID / .p8. Never PASS without GATE_C_SAME_REQUEST_ID_PROOF.
#
# Early gate (always): scripts/gate-c/gate-c-require-proof-tip.sh → TIP= / PROOF=1|0.
# Full orchestrator (drop-dir SoT when present): ~/LoopFwd-GateC-Creds/RUN-GATE-C-DEVICE-E2E.sh
# which also re-runs the proof tip before Hub start / device steps.
set -euo pipefail

DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure start-hub resolution prefers in-repo (iOS scripts/, then this dir).
export LOOPFWD_IOS_REPO="${LOOPFWD_IOS_REPO:-$HOME/Documents/Cursor/LoopFwd-For-iOS}"
export LOOPFWD_MAC_REPO="${LOOPFWD_MAC_REPO:-$HOME/Documents/Cursor/LoopFwd-For-Mac}"

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
