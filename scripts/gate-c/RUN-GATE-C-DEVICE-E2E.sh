#!/usr/bin/env bash
# Gate C device E2E entry for Mac operators.
# Prefer durable drop-dir orchestrator when present; otherwise fail closed with pointers.
# Never invents Team ID / .p8. Never PASS without GATE_C_SAME_REQUEST_ID_PROOF.
set -euo pipefail

DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure start-hub resolution prefers in-repo (iOS scripts/, then this dir).
export LOOPFWD_IOS_REPO="${LOOPFWD_IOS_REPO:-$HOME/Documents/Cursor/LoopFwd-For-iOS}"
export LOOPFWD_MAC_REPO="${LOOPFWD_MAC_REPO:-$HOME/Documents/Cursor/LoopFwd-For-Mac}"

DROP_RUN="$DROP_DIR/RUN-GATE-C-DEVICE-E2E.sh"
if [[ -f "$DROP_RUN" ]]; then
  exec bash "$DROP_RUN" "$@"
fi

echo "RUN-GATE-C-DEVICE-E2E: drop-dir orchestrator missing at $DROP_RUN" >&2
echo "  Restage from operator paste / INSTALL-FROM-PASTE, or run helpers under $SELF_DIR." >&2
echo "  start-hub: $LOOPFWD_IOS_REPO/scripts/gate-c-start-hub.sh (preferred) or $SELF_DIR/gate-c-start-hub.sh" >&2
echo "  Evidence: NOT_RUN — not PASS." >&2
exit 1
