# LoopFwd

[简体中文](README.zh-CN.md)

A native Mac island for keeping track of local AI coding tasks: what is running,
what really needs your attention, and where to return.

LoopFwd uses the sides of the MacBook notch without changing your working
environment. On a display without a notch, a transparent top-center hot area
reveals the island. Completed tasks appear briefly; idle sessions do not become
a permanent task list.

## Preview status

The first open-source release is **0.1.0**, for Apple Silicon and macOS 14+.
It is an early preview, not a 1.0 or stable release.
This checkout is a development candidate, not a validated public release.
The preview includes **eight integrations**. **Preview tested** means basic
real-task monitoring was checked on the named surface, not all capabilities or
every user's environment. Installed software and parser tests alone do not earn
that label. Five optional integrations remain **Experimental**, off by default
on a fresh install; existing choices are preserved.

| Integration | Preview scope and evidence | Main limitation |
| --- | --- | --- |
| Codex | Desktop monitoring, task links and completion notification checked | CLI and managed surfaces remain experimental; no CLI/Desktop approval observation |
| OpenCode | TUI HTTP 1.18.x: real dual sessions, progress, explicit completion, stop and question handling | Desktop read-only remains experimental; actual terminal return is not verified |
| Copilot CLI | 1.0.83: real progress, dual sessions, identity recovery, stop and explicit Autopilot completion | Ordinary reply end is not successful goal completion; app-only return, no approval control |
| Claude Code CLI | Optional registry/transcript reader and explicit attention hook | Real authenticated tasks not yet verified; controls stay in Labs |
| Gemini CLI | Optional 0.58.0 reader and progress observer | No confirmed completion or approvals; authenticated tasks not yet verified |
| Qwen Code | Optional 0.23.0 registry and progress observer | No confirmed completion or approvals; authenticated tasks not yet verified |
| Kimi Code | Optional 0.41.0 main-wire reader and lifecycle observer | No exact task return; authenticated tasks not yet verified |
| Grok CLI | Optional 1.0.13 / event-schema 1.0 reader | Authenticated tasks and actual return not yet verified |

Cursor Agent, DeepSeek Harness, Mistral Vibe, WorkBuddy and Doubao Work are
**not supported in 0.1.0**. Their state interfaces or setup/version costs are
not suitable for this first release. Retained source is not an active integration.

Capabilities vary by data source. Codex CLI/Desktop transcripts do not provide
live approval observation. An idle provider or an old assistant reply is not
evidence of successful completion. Unknown, stale and incompatible data are
reported as observation health, not invented task outcomes.

## Build and run

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

## Install a preview package

When a tagged pre-release is available:

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

Updates are manual. Keep the previous ZIP to reinstall an earlier build.
Quitting may disconnect LoopFwd-managed tasks; external agent processes are not stopped.

## First use

Open **Settings → Setup status** to inspect software, data sources and permissions.
Use **Agents → Choose CLI…** when Finder's environment cannot find your CLI.
Enable only the providers you want to track.

In **General → Interface language**, choose System, English, or Simplified Chinese.
The default follows macOS; an explicit choice applies after restarting LoopFwd
and does not change the system language.

Codex usage comes from local reports, not a live account balance query. Main
Codex and Spark limits are kept separate; window labels reflect the reported
duration. Missing or old main-limit reports are not shown as current allowance.

Controls for creating managed Codex tasks and OpenCode replies/approvals live in
**Integrations → Labs** and are off by default. Existing managed tasks retain
return and stop controls when Labs is disabled. Claude terminal input has its
own separate Labs switch. Hook/plugin installation always requires a click.
Older Claude hooks need **Update hook** in Integrations to add event-source
identity. Until updated, their unbound events are ignored; restarting LoopFwd
does not rewrite the hook or enable controls. The prior script is backed up.

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

## Privacy and contributions

No telemetry, cloud synchronization or transcript uploads are performed by
LoopFwd's observation path. Optional managed provider commands use the provider's
own execution and network behavior. Review Diagnostics before sharing them.

Read [Privacy](PRIVACY.md), [Security](SECURITY.md),
[Contributing](CONTRIBUTING.md), and [Architecture](docs/ARCHITECTURE.md).
Bug reports should include the version/build identity and a redacted diagnostic
report, never credentials or transcripts.

## License

[MIT](LICENSE). Imported code, icon versions, licenses and trademark boundaries
are documented in [Third-party notices](THIRD_PARTY_NOTICES.md).
LoopFwd is not affiliated with the providers whose tools it observes.
