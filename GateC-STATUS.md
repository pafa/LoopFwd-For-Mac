# Gate C Status (Mac)

| Field | Value |
|-------|-------|
| tip SHA |  () |
| markers | MARKERS_OK |
| creds | CREDS_MISSING |
| watcher | ARMED (`com.loopfwd.gate-c-creds-watch`) |
| evidence | NOT_RUN |

## Notes

- HEAD greps `GATE_C_SAME_REQUEST_ID_PROOF`; phone projections use `openDetail: false`.
- Never invent Team ID. Drop `team-id.txt` + `AuthKey_*.p8` → `~/LoopFwd-GateC-Creds/`.
- Watcher polls drop-dir, refuses placeholders (`ABCDEF1234` / `TEST*`), writes `.ready-ok`, runs iOS `scripts/gate-c-creds-intake.sh`.
- Log: `~/Library/Logs/LoopFwd/gate-c-creds-watch.log`
- Confirmed markers tip before watcher commit: `398c7fb`. No device PASS claimed.

## Next

1. Place real `team-id.txt` + `AuthKey_*.p8` in `~/LoopFwd-GateC-Creds/` (watcher auto-intakes)
2. Confirm `.ready-ok` + Hub `GATE_C_STRICT=1`
3. Device E2E: live requestId clear proof via markers
