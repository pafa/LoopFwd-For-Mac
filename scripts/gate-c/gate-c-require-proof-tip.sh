#!/usr/bin/env bash
# Gate C: fail-closed unless Mac tip Sources contain GATE_C_SAME_REQUEST_ID_PROOF.
# Prints TIP=<sha> and PROOF=1|0. Never invents creds. Never claims evidence PASS.
#
# Prefer drop-dir gate-c-resolve-paths.sh (scrubs non-existent LOOPFWD_MAC_REPO
# poison, then mac-repo.env / hub-start default). Env default only — do not
# auto-switch a dirty unrelated checkout.
set -euo pipefail

MARKER='GATE_C_SAME_REQUEST_ID_PROOF'
DROP_DIR="${LOOPFWD_GATE_C_CREDS_DIR:-$HOME/LoopFwd-GateC-Creds}"

if [[ -f "$DROP_DIR/gate-c-resolve-paths.sh" ]]; then
  # shellcheck disable=SC1090
  source "$DROP_DIR/gate-c-resolve-paths.sh"
elif [[ -z "${LOOPFWD_MAC_REPO:-}" && -f "$DROP_DIR/mac-repo.env" ]]; then
  # shellcheck disable=SC1090
  source "$DROP_DIR/mac-repo.env"
fi

MAC_REPO="${LOOPFWD_MAC_REPO:-$HOME/Documents/Cursor/LoopFwd-For-Mac}"

usage() {
  cat <<'EOF'
Usage: gate-c-require-proof-tip.sh

Fail-closed unless `git grep -q GATE_C_SAME_REQUEST_ID_PROOF -- '*.swift'`
succeeds in LOOPFWD_MAC_REPO.
Default resolution (when unset): drop-dir mac-repo.env → proof-bearing
hub-start worktree → primary checkout with proof.
Prints:
  TIP=<full-sha>
  PROOF=1|0
Exit 0 only when PROOF=1. Does not invent creds or claim Gate C PASS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "gate-c-require-proof-tip: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$MAC_REPO/.git" ]] && [[ ! -f "$MAC_REPO/.git" ]]; then
  echo "TIP="
  echo "PROOF=0"
  echo "gate-c-require-proof-tip: FAIL CLOSED — Mac repo missing/unusable: $MAC_REPO" >&2
  echo "  Optional: export LOOPFWD_MAC_REPO=.../LoopFwd-worktrees/mac-gate-c-hub-start-641d when that tip has proof." >&2
  exit 1
fi

TIP="$(git -C "$MAC_REPO" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "$TIP" ]]; then
  echo "TIP="
  echo "PROOF=0"
  echo "gate-c-require-proof-tip: FAIL CLOSED — cannot resolve HEAD in $MAC_REPO" >&2
  exit 1
fi

PROOF=0
if git -C "$MAC_REPO" grep -q "$MARKER" -- '*.swift' 2>/dev/null; then
  PROOF=1
fi

echo "TIP=$TIP"
echo "PROOF=$PROOF"
echo "LOOPFWD_MAC_REPO=$MAC_REPO"

if [[ "$PROOF" != "1" ]]; then
  echo "gate-c-require-proof-tip: FAIL CLOSED — tip missing $MARKER under $MAC_REPO" >&2
  echo "  origin/main may lack proof; use a tip WITH proof (primary main@056e6eb+ or hub-start worktree)." >&2
  echo "  Durable default: $DROP_DIR/mac-repo.env → hub-start WT when present with proof." >&2
  echo "  Optional: export LOOPFWD_MAC_REPO=\$HOME/Documents/Cursor/LoopFwd-worktrees/mac-gate-c-hub-start-641d" >&2
  echo "  Do not auto-switch if that checkout is dirty — set LOOPFWD_MAC_REPO via env only." >&2
  echo "  Evidence: NOT_RUN — not PASS." >&2
  exit 1
fi

exit 0
