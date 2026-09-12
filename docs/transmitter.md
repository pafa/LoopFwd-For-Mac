# LoopFwd Mac — Session Hub Transmitter

Additive module under `Sources/LoopFwd/Transmitter/`. Disabled by default (`Pref.transmitterEnabled = false`). Does not change island UX.

## Layout

```
Sources/LoopFwd/Transmitter/
  RemoteProtocolModels.swift   # SessionProjection + action DTOs (protocol v1)
  SessionProjector.swift       # AgentSession → SessionProjection
  ActionIngress.swift          # Hub actionForward → revalidate + execute
  HubClient.swift              # HTTPS register/publish + WS /v1/transmitter
  TransmitterService.swift     # lifecycle, ≤2 Hz publish, hooks
```

Hooks (AppDelegate after existing starts):

- `AgentMonitor.shared` / `ApprovalCenter.shared` / `CodexAppServer.shared` → publish
- `AgentNotificationRouter` already running; transmitter listens to `.approvalNeeded` / `.agentLifecycleEvent`
- Actions execute only via `ApprovalCenter.respond` / `answerQuestion`, `OpenCodeSessions.replyPermission` / `answerQuestion`, `CodexAppServer.send` / `interrupt`

## Enable + Hub handshake

1. Start Hub (iOS repo):

```bash
# sibling checkout of LoopFwd-For-iOS
cd ../LoopFwd-For-iOS/Hub
npm install && npm start
# http://127.0.0.1:8787
```

2. Enable transmitter (defaults write or future Settings stub):

```bash
defaults write app.loopfwd.agent-control transmitterEnabled -bool true
defaults write app.loopfwd.agent-control transmitterHubURL -string 'http://127.0.0.1:8787'
# optional: transmitterPairingCode, transmitterDisplayName
```

3. Launch LoopFwd Mac → registers `POST /v1/transmitter/register`, connects `ws://127.0.0.1:8787/v1/transmitter?macToken=…`, publishes `sessionsPublish`.

4. Phone: pair the **fresh** `transmitterPairingCode` (printed in defaults / `TransmitterService.shared.pairingCode`), not only `LOOP-STUDIO`.

## E2E gate (same live requestId)

1. Create live OpenCode permission or Claude approval on Mac so projection has `approval.requestId` (or question).
2. Phone Approve / option / reply against Real Hub.
3. Hub forwards `actionForward` → Mac revalidates live id → executes → `actionResult`.
4. Mac projection no longer carries that `requestId`.

## Fail-closed

- No capability / no live requestId → controls not advertised; actions `rejected` / `expired`
- Observation stale → reject mutating actions
- Transmitter disabled → zero Hub traffic; Mac product unchanged
