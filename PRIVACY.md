# Privacy

LoopFwd is a local macOS application. It has no analytics SDK, telemetry
service, account system, advertising code, or cloud synchronization. LoopFwd
does not upload prompts, transcripts, repository contents, credentials, or
diagnostics through its observation path. Explicitly started managed Codex
tasks send your instructions to the Codex process; that provider may contact
its own services according to its configuration and privacy policy. LoopFwd
does not proxy those requests through a LoopFwd cloud service.

## Data read locally

To discover and describe running coding agents, LoopFwd may read:

- the macOS process table, process working directories, controlling terminals,
  and a small allowlist of provider-specific environment variables;
- provider-owned local session files and read-only desktop application stores;
- local Git `HEAD` files when the Git branch chip is enabled;
- loopback-only HTTP endpoints explicitly exposed by OpenCode; and
- bounded events from explicitly configured Claude, Gemini, Qwen and Kimi hooks.

0.1.0 scans only the eight integrations listed in README. Cursor Agent,
DeepSeek Harness, Mistral Vibe, WorkBuddy and Doubao Work are deferred, even
if a previous preference enabled them. No installed client, observer,
conversation or provider configuration is automatically deleted on upgrade.

Readers use bounded tails or limited queries wherever practical. A failed or
incompatible reader degrades to process-only or stale status instead of
inventing a session state.

## Data written locally

LoopFwd stores preferences in macOS UserDefaults. It changes provider or system
configuration only after an explicit user action:

- installing or removing the optional Claude notification hook;
- installing or removing the optional Gemini, Qwen or Kimi local Hook observer;
- enabling Launch at Login or requesting macOS notification/accessibility
  permission; and
- importing or removing a custom completion sound.

Provider configuration changes are backed up before rewriting. Removing a card
from LoopFwd does not delete the provider's conversation or transcript.

The optional local Hook observer runs only when explicitly configured. It writes
bounded, private (`0700` directory, `0600` files) observation events under
`~/Library/Application Support/LoopFwd/hook-events`: provider/session identity,
process start identity, transcript location, working directory, tool names/IDs,
event types, provider/arrival timestamps, provider version, conversation generation
and loop markers, and bounded stream metadata (message
identity, final/content-present flags, interruption and allowlisted error codes).
Kimi lifecycle events contain only the configured data root, session ID, cwd,
client type, event name, arrival time and matched process/birth identity. The
root comes from the explicitly installed command. Session titles, prompts,
models, profile names and heartbeat uptime are not copied into these events.
The heartbeat is not treated as task progress. Kimi setup requires a selected
Python 3.11+ runtime, checks the selected npm package metadata without starting
the provider, and backs up `config.toml` before modifying its own checked block.
### Observers installed by earlier development builds

Those observers may still run inside the provider until explicitly removed.
0.1.0 does not read their output or expose their installation controls. Keep
the earlier build and the original backups for removal/recovery; compare any
backup before restoring it over a newer user configuration.

The retained WorkBuddy collector records the actual runtime session identity
from `CODEBUDDY_SESSION_ID`, the matched application's location and host process
birth identity, and the allowlisted FinalStop reason. This distinguishes child
tasks from their parent without storing an environment dump. Proven child events
are discarded before writing so they cannot evict the main task's observation.
Its CLI version is
read from that installed application's package metadata, not an assumed version.
The deferred WorkBuddy reader accepts these events only after matching the live engine and
host process births. Optional transcript context is read only from the exact
session file inside its configured projects directory; missing desktop
transcripts are not replaced with another conversation. WorkBuddy observer setup
requires an explicit action and configuration-folder selection. It checks App
and bundled CLI metadata without launching the private CLI, backs up settings,
and preserves existing hooks and disable switches. Starting LoopFwd does not
enable these hooks or restart WorkBuddy.
It does not retain prompts, model output, tool arguments/results,
API keys or other environment values and never returns approval decisions. The
current buffer retains 64 events per provider/process-birth/session scope. At
128 scopes, new sessions trigger a bounded cleanup of records older than 24 hours
whose owner PID is confirmed absent. Live, unbound, recent or invalid scopes are
not evicted. Cleanup checks private ownership, schema and identity, quarantines
candidates in `.gc`, then removes only verified event files. Interrupted or
concurrently changed quarantine data is retained for later review or cleanup.
When no safe space can be reclaimed, new scopes are still refused; this is not a
conversation archive or a guarantee of unlimited history. Reinstall an existing
observer to update its private script copy; an App update alone does not replace
previously installed Hook commands.
Earlier Mistral setup was an explicit Settings action: select the Vibe home and Node
executable, validate the installed Vibe version, then back up and modify only the
managed block in `hooks.toml`. Private script copies and configuration backups
remain in that home's `.loopfwd-observer` folder. Removal does not require Vibe
or Python to remain installed and preserves text outside the verified block.
An interrupted operation may have already replaced the configuration: the App
reports an uncertain outcome and exposes the backup folder for manual recovery.

The Mistral observer also records the resolved data-directory path from its own
inherited `VIBE_HOME`, because the CLI rewrites the process title. It does not
copy other environment values or accept an event-supplied root. The earlier
DeepSeek Web observer writes a bounded private snapshot, not API keys, cookies
or full transcripts; it can remain installed after this upgrade, but is no
longer read by LoopFwd. Cursor's earlier hook collector records identity and
event metadata, not prompts or model output.

### Current Gemini / Qwen setup

Gemini/Qwen setup requires selecting the configuration folder and Node executable.
Only the selected `settings.json` is edited, using bundled Microsoft jsonc-parser
to preserve comments and unrelated settings. Version checks do not initiate a
model task. Private script copies, installation metadata and exact configuration
backups remain in `.loopfwd-json-hooks` beside that file. Backups may include
the provider's sensitive configuration: keep them private and never attach them
to a public issue. Removal preserves user hooks; disabled hooks and trust settings
are never enabled automatically. Interrupted transaction locks require explicit
review rather than automatic deletion. See the README recovery instructions.

## Diagnostics

The copyable diagnostics report contains provider health, data-source names,
and timestamps. Before copying, LoopFwd removes home-directory paths and
credential-shaped strings. It intentionally excludes prompts and full
transcripts. Review any diagnostic text before sharing it publicly.

LoopFwd may open a provider's local app, terminal window, or loopback web page
when you explicitly choose a session. It does not make non-loopback network
requests itself.
