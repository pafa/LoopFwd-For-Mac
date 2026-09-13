# Gate C Status (Mac)

| Field | Value |
|-------|-------|
| tip SHA | `5150a5bb303bdda40c9bc0ec3a54f0ea68d98476` (`5150a5b`) |
| markers | MARKERS_OK |
| creds | CREDS_MISSING |
| evidence | NOT_RUN |

## Notes

- HEAD greps `GATE_C_SAME_REQUEST_ID_PROOF`; phone projections use `openDetail: false`.
- Never invent Team ID. Drop `team-id.txt` + `AuthKey_*.p8` → `~/LoopFwd-GateC-Creds/`.
- No device PASS claimed.

## Next

1. Place `team-id.txt` + `AuthKey_*.p8` in `~/LoopFwd-GateC-Creds/`
2. Run Gate C creds intake / Hub `GATE_C_STRICT=1`
3. Device E2E: live requestId clear proof via markers
