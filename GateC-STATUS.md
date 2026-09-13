# Gate C Status (Mac)

| Field | Value |
|-------|-------|
| tip SHA | `398c7fba4f64e503f741b497486bd930a0bb1b37` (`398c7fb`) |
| markers | MARKERS_OK |
| creds | CREDS_MISSING |
| watcher | ARMED (`com.loopfwd.gate-c-creds-watch`) |
| evidence | NOT_RUN |

## Notes

- Markers tip `398c7fb` greps `GATE_C_SAME_REQUEST_ID_PROOF`; phone projections use `openDetail: false`.
- Never invent Team ID. Drop `team-id.txt` + `AuthKey_*.p8` → `~/LoopFwd-GateC-Creds/`.
- Watcher polls drop-dir, refuses placeholders (`ABCDEF1234` / `TEST*`), writes `.ready-ok`, runs iOS `scripts/gate-c-creds-intake.sh`.
- Log: `~/Library/Logs/LoopFwd/gate-c-creds-watch.log`
- Watcher branch: `cursor/gate-c-creds-watcher-f858`. No device PASS claimed.

## Next

1. Place real `team-id.txt` + `AuthKey_*.p8` in `~/LoopFwd-GateC-Creds/` (watcher auto-intakes)
2. Confirm `.ready-ok` + Hub `GATE_C_STRICT=1`
3. Device E2E: live requestId clear proof via markers
