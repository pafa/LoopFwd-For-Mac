# Architecture

LoopFwd for Mac is one native macOS SwiftPM executable. Keep this structure until
a real product path requires another process or service. The app observes local
agent work, explains attention and returns the user to the best verified target.

## Current preview scope

`SupportRegistry.shippedKinds` is the allowlist for all scanning, settings,
Setup and diagnostics. It contains Codex, OpenCode, Copilot, Claude, Gemini,
Qwen, Kimi and Grok. Old preferences cannot re-enable deferred providers.

Basic real-task evidence exists for `codex.desktop`, `opencode.tui-http` and
`copilot.cli`. This is not a stable certification or permission to control
other surfaces of the same brand. Other integrations remain Experimental,
off by default on a fresh install; existing choices remain unchanged.

| Surface | Observation and evidence | Return / control boundary |
| --- | --- | --- |
| Codex Desktop | Read-only registry plus matching rollout; real monitoring, task-link and completion-notification evidence | Validated thread deep link; no reply, stop or approval authority |
| Codex CLI | Verified open rollout and real thread ID; process-specific CODEX_HOME | Actual terminal target; observation does not grant managed control |
| Codex managed | Official app-server projections and persisted thread IDs | Creation/follow-ups in Labs; existing managed tasks retain return/stop |
| OpenCode TUI HTTP | Stable 1.18.x API bound to the process's loopback port; basic dual-session/progress/result/question evidence | Live request revalidation before optional Labs reply/approval; real terminal return remains unverified |
| OpenCode Desktop | Read-only local store | Application-level return, no database-derived control authority |
| Copilot CLI | 1.0.83 open-session tracker plus event/objective files; real progress, dual identities, recovery, stop and explicit Autopilot task completion | App-level return; ordinary assistant turn end is not successful task completion; no approval control |
| Claude CLI | Registry, transcript and explicit attention hook; authenticated model tasks not yet verified | Exact verified terminal return; optional session-addressed Labs controls only, never global keyboard injection |
| Gemini / Qwen | Versioned registry/recording plus explicit progress observers | Experimental; no inferred completion or approval |
| Kimi | Lifecycle identity plus matching main wire 1.5, client 0.41.0 | Experimental; no exact task return or approval/control promise |
| Grok | Verified live session registry and event schema 1.0 | Experimental; authenticated model lifecycle and actual return remain unverified |

Cursor, DeepSeek Harness, Mistral and WorkBuddy source remains available for
future work and recovery of older installations. They are not active preview
integrations. Doubao Work has no production reader. Building or starting the app
does not install, remove or reconfigure any provider.

## Data flow and file ownership

```text
Process table + verified local stores / explicit observers
                         ↓
                    AgentScanner
                         ↓
          ProviderReadResult + AgentSession
                         ↓
          AgentMonitor + AgentLifecycleReducer
                 ↙                    ↘
      presentation policies       NotificationRouter
                 ↓                    ↓
       Island / menu / keyboard   macOS notifications
                 └─────────┬──────────┘
                    ReturnResolver
                         ↓
              TerminalBridge / provider API
```

- `App/`: lifecycle, single-instance activation and managed-task exit warning.
- `Core/`: observation contracts, discovery, lifecycle, presentation and scanning.
- `Providers/`: bounded reads of each provider's format and explicit installers.
- `System/`: macOS effects, notification decisions, target execution and settings edits.
- `UI/`: presentation of normalized state, never independent task-state inference.

## Discovery, identity and configuration directories

Stable IDs come from real provider session/thread identities, not PIDs. Temporary
process identity is reconciled with the session identity; process caches include
birth/command identity and are invalidated when the process disappears or changes.

Codex CLI discovery reads CODEX_HOME from the target process. Codex Desktop
reads the verified running application's environment, not LoopFwd's Finder
environment. If the environment cannot be read or multiple roots disagree, the
reader reports failure and the user can select the actual data folder in Agents.
An explicit selection changes only LoopFwd's preference; it never moves data.

Claude observation reads each CLI's CLAUDE_CONFIG_DIR. Hook configuration is a
separate, explicit action: Integrations displays the exact settings target and
allows selecting that directory. Choosing a folder does not install a hook or
claim that it is the configuration used by every Claude process.

Desktop registries use bounded, resumable discovery through `DesktopRegistryScan`.
Recent/known active sessions get priority, unvisited pages remain pending and
partial reads are visible. SQLite queries have a progress-handler deadline;
two independent Desktop databases can be read concurrently. A pending page is
not interpreted as an empty result or a new progress timestamp.

## State, attention and notifications

Keep task phase, attention, observation health and evidence timestamps separate.
Only an explicit current provider boundary can establish Working, Completed,
Failed or Stopped. Only a real unresolved input/approval request can establish
Needs attention. CPU, process existence, an old reply, idle or reader failure
cannot establish successful completion or attention.

Reader failures keep the last trusted task state with stale health during a
bounded reconciliation grace period. Persistently unavailable sessions leave
the active list with a provider-level explanation. Idle stays hidden; Completed
is shown for five seconds and Stopped for eight. Failed remains until viewed or
superseded. No conversation or transcript is deleted by this presentation.

`TaskPresentationResolver` separates project, semantic user task and current
step. Short confirmations do not replace the task; pending Todos do not pretend
to be in progress. Titles and retained summaries have explicit length bounds.

`NotificationRouter` owns banner, sound, reveal and suppression decisions.
Attention, failure and completion default on; started and stalled default off.
Events use session/turn/type/revision identity, not scan time. Aggregates retain
members so handled tasks and late deliveries can be withdrawn.

Suppression requires evidence that the exact task is being viewed, not merely
that its provider is frontmost. Passive visibility checks do not request Apple
Events access. Notification snapshots exclude transcript/control payloads;
clicks resolve the current session, never treat an old snapshot as authorization.

## Return and input authority

`ReturnResolver` distinguishes exact, provider-only and unavailable targets.
Cards, menus, notifications and keyboard use the same capability. Helpers run
off the UI thread with bounded duration/output; application-only return does
not mark a task as viewed.

Terminal.app can select a verified TTY for return, but has no session-bound
interactive input API. Global CGEvent typing has been removed, including its
Accessibility setup prompt. Terminal.app therefore remains return-only even
when Labs is enabled. Replies/approval keys require a session-addressed host
API and a freshly validated process/request; unsupported targets fail closed.

OpenCode control revalidates process, port, session and current request. Local
HTTP rejects non-loopback URLs, credentials and external redirects. Desktop
database observation never supplies credentials or control authority.

Managed Codex control applies only to threads owned through LoopFwd's app-server,
not arbitrary external TUI or Desktop tasks. Stop uses the official turn
interrupt and does not promise to undo previous command or network side effects.

## Explicit configuration transactions

`HookSettings` recognizes exact owned commands, including the previous
unquoted path and the current shell-quoted path. It never identifies ownership
from a brand substring. Removal filters only owned commands inside a matcher
group, preserving unrelated commands, prompt hooks and matcher metadata.
Unsupported structures are rejected unchanged.

`ClaudeHookInstaller` serializes each configuration edit and shared-script
update. Each attempt retains an independent private recovery directory.
Settings/backups are written through private temporary files (0600) and atomic
rename; the script is 0700. A concurrent external settings edit is preserved.
Failure restores the previous script only if the file still matches this
attempt; uncertain recovery is reported with the backup location.

Removing a hook deregisters only the selected profile. The small shared script
and spool remain because other explicitly configured profiles may reference
them. Old fixed-name backups are never removed. After an interrupted installer,
do not break a lock while its owner can still be running.

Gemini/Qwen and retained JSONC installers use the existing local transaction
helper with pinned jsonc-parser. Kimi uses the existing TOML transaction path.
None runs during startup. Snapshot or observer identity never grants control.

## Display, diagnostics and localization

The existing notch-wing dimensions and external-display transparent hot area
remain unchanged. AppKit tracking areas own hover, with a short collapse delay.
Content and background share the same shape; neither the panel nor SwiftUI adds
an outer diffuse shadow. Fullscreen Space eligibility is controlled by AppKit,
not menu-bar-height polling.

Diagnostics are bounded in memory. Supported reader versions are separate from
observed version metadata and its source. Current app-bundle and OpenCode health
versions can be reported; otherwise the actual version is unknown. The scanner
does not launch every CLI to guess a version. Export omits prompts, credentials
and full paths; the user must review it before sharing.

The String Catalog is the translation source for English/Simplified Chinese.
Language choice is resolved once per launch. Dynamic visible and VoiceOver
strings use parameterized localization; technical diagnostic field names remain
stable for issue reports.

## Validation and deferred work

Run the existing verification chain, focused regressions for changed behavior,
and a real packaged-app smoke for UI/packaging changes. Fixture success is not
real-account evidence. macOS 14 is the deployment target; current CI uses
macOS 26 and does not certify a real macOS 14 installation.

Do not add a daemon, dynamic plugin platform, own history database, cloud
account, cross-device service or general adapter framework for this preview.
A new integration needs a stable identity, bounded reader, explicit evidence
and failure semantics, honest return/control capabilities and a focused real
task check before it receives a Preview tested label.
