# Setup and recovery

[Back to product overview](../README.md) · [简体中文](SETUP.zh-CN.md)

## Installation and recovery

The [0.1.1 pre-release](https://github.com/pafa/LoopFwd-For-Mac/releases/tag/v0.1.1) contains the ZIP, checksum and build manifest:

1. Download its ZIP and matching SHA-256 file.
2. In their download directory, run `shasum -a 256 -c <archive-name>.sha256`.
3. Quit the old LoopFwd, extract the ZIP and drag LoopFwd into Applications.
4. Open the app. If macOS blocks this ad-hoc preview, review the warning in
   **System Settings → Privacy & Security → Open Anyway** only if you trust
   the source and have verified the checksum.

These packages are not Developer ID signed or notarized. This is independent
of publishing the MIT-licensed source; neither App Store submission nor an
Apple Developer membership is needed to read, fork or build the source.
See [Apple's Gatekeeper explanation](https://developer.apple.com/news/?id=saqachfa).

Updates are manual. Keep previously downloaded ZIPs for manual recovery. Version 0.1.0 has the same localized-resource startup risk fixed in 0.1.1; do not use it to recover from that fault.
Quitting may disconnect LoopFwd-managed tasks; external agent processes are not stopped.

## Build from source

Install full **Xcode 26.6**, **Node 24+**, **Python 3.11+**, **jq**, and **ripgrep**, then select Xcode using
`xcode-select`. Command Line Tools alone are insufficient for packaging icons.

```sh
./scripts/preflight
./scripts/verify
open dist/LoopFwd.app
```

For a quick compile, use `swift build`. For tests only, use `swift test`.
No provider configuration is changed by building or starting LoopFwd.
Python is used for installer transaction tests and explicit Kimi observer setup.
LoopFwd does not install or manage a separate Python environment.

## Setup and optional observers

Open **Settings → Setup status** to inspect software, data sources and permissions.
Use **Agents → Choose CLI…** when Finder's environment cannot find your CLI.
Enable only the providers you want to track.

Setup status distinguishes disabled integrations, installed-but-unverified software,
process-only observation, failed reads and successfully read empty sources. Each row
links to the relevant Agents, Integrations or Diagnostics settings; it never installs
an observer automatically.

In **General → Interface language**, choose System, English, or Simplified Chinese.
The default follows macOS; an explicit choice applies after restarting LoopFwd
and does not change the system language.

Codex usage comes from local reports, not a live account balance query. Main
Codex and Spark limits are kept separate; window labels reflect the reported
duration. Missing or old main-limit reports are not shown as current allowance.
Usage follows the same observed Codex data directory as task discovery, including
custom CLI homes and the explicit Agents data-folder selection. If automatic
discovery finds multiple account folders, select one rather than combining their
limits. Expired reset windows disappear until Codex reports again; they do not turn
into an assumed 100% balance. Recently modified rollouts and known active paths
are considered across month/year boundaries, with bounded reading.

If returning fails, LoopFwd distinguishes known terminal Automation denial, timeout,
closed targets and helper failures, with a refresh or setup action. No failure
falls back to typing into another window. Sound-import recovery failures display
the retained backup location; preserve that copy before retrying. The General idle
cleanup interval applies to Claude CLI, Codex CLI, OpenCode TUI/Desktop and Qwen
records, not every integration; Idle tasks remain hidden from the main island.

Controls for creating managed Codex tasks and OpenCode replies/approvals live in
**Integrations → Labs** and are off by default. Existing managed tasks retain
return and stop controls when Labs is disabled. Claude terminal input has its
own separate Labs switch. **Terminal.app is return-only** in 0.1.1:
global keyboard injection and its Accessibility setup prompt have been removed.
Other terminal controls require a session-addressed API. Hook/plugin
installation always requires a click.
Older Claude hooks need **Update hook** in Integrations to add event-source
identity. Until updated, their unbound events are ignored; restarting LoopFwd
does not rewrite the hook or enable controls. The prior script is backed up.

**Custom data directories:** Agents → Codex Desktop data defaults to the running
Codex app's environment. If that environment is unavailable or multiple roots
disagree, select the actual CODEX_HOME folder. This changes only LoopFwd's
preference; it never moves Codex data.

In Integrations → Claude Code, check the displayed settings target before
installing. Use Choose folder for a custom CLAUDE_CONFIG_DIR. Choosing a folder
does not install anything. Each edit keeps a separate private recovery folder;
Show backup opens it. Remove deregisters only the selected profile and retains
the shared observer files for other profiles. Unsupported layouts and symbolic
settings files are refused unchanged. After an interrupted operation, quit
LoopFwd and confirm the recorded owner has exited before moving that exact
configuration/script lock aside; do not delete backups or break a live lock.

Diagnostics distinguishes supported formats from observed version metadata and
its source. Unknown is explicit when actual version metadata is unavailable;
the app does not launch providers just to collect version numbers.

Task clicks say **Jump to task**, **Open App**, or explain why returning is
unavailable. Opening an application does not mark its task as viewed.

### Optional Gemini / Qwen observation

In **Integrations**, install the read-only observer for Gemini CLI **0.58.0**
or Qwen Code **0.23.0**. Select that CLI's configuration directory containing
`settings.json` and a **Node 24+** executable. LoopFwd adds only its own hooks,
preserving JSONC comments, existing hooks and disabled settings. Restart the
CLI afterwards; its workspace-trust rules still apply. This observes progress,
not approvals or guaranteed successful completion. Both remain Experimental.

LoopFwd follows each CLI's verified Node relaunch chain, rather than showing its
bootstrap processes as extra sessions. Qwen can register a session before login;
without a matching recording it retains that identity as **Process only**, with
no borrowed history or inferred completion. Existing observer installations need
an explicit **Reinstall** to receive the updated process matching; restarting
LoopFwd alone does not overwrite your installed hooks.

**Reinstall** repairs a missing observer copy; **Remove** removes matching
LoopFwd definitions without requiring the provider CLI, but still needs Node.
**Show backup folder** opens `.loopfwd-json-hooks` beside the selected settings
file. Keep its backups until you have verified your configuration. A killed
installation may leave `transaction.lock`: do not remove it while an installer
is running. After confirming its recorded process has ended, move that exact
lock aside and retry Remove/Reinstall. Review backups before any manual restore
so newer settings are not overwritten. LoopFwd never automatically breaks a lock.

### Optional Kimi observation

In **Integrations → Kimi Code observer**, choose the actual `KIMI_CODE_HOME`
folder, Node 24+, and Python 3.11+. Setup checks the selected official npm
installation at **0.41.0** without starting Kimi, then backs up `config.toml`
and adds only LoopFwd's three lifecycle hooks. Remove works without Kimi;
Reinstall repairs a missing observer copy. Keep the reported backup folder.
Unsupported TOML hook layouts or edited managed blocks are rejected unchanged.

Kimi closes its wire file between writes. The optional observer binds each
session to its live process and birth identity so those closed descriptors do
not hide tasks. Heartbeats identify sessions; they never advance task progress.
The corresponding main-agent wire remains the task-state source. Kimi's common
client identity does not distinguish TUI, Web and ACP, so this does not promise
an exact task return, approval handling, or control. It remains Experimental.
Building or starting LoopFwd does not install these hooks.

### Updating from development builds

Deferred integrations are neither scanned nor offered for new installation,
even if an older setting enabled them. No installed client, conversation,
observer or configuration is removed automatically. Previously installed hooks
may still run inside their provider; disabling LoopFwd observation does not
uninstall them. Keep the previous development build and its configuration backups
if you need its observer removal/recovery actions. Compare backups before a
manual restore so later user changes are not overwritten.
