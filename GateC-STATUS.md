# Gate C Status (Mac)

| Field | Value |
|-------|-------|
| tip SHA | `4b28fbb29c1d11265ca1f87b28e9d7b0222ca813` (`4b28fbb`) |
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
