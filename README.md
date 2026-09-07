<p align="center">
  <img src="assets/icon-1024.png" width="96" height="96" alt="LoopFwd for Mac icon">
</p>
<h1 align="center">LoopFwd for Mac</h1>
<p align="center"><strong>Your agents are working. You shouldn't have to keep checking.</strong></p>
<p align="center">A small island on your Mac. A clear view of your AI tasks.</p>
<p align="center">
  <a href="https://github.com/pafa/LoopFwd-For-Mac/releases/tag/v0.1.0"><strong>Download for Mac</strong></a> ·
  <a href="#see-it-in-26-seconds">Watch the film</a> ·
  <a href="#features">Explore features</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>
<p align="center">Apple Silicon · macOS 14+ · Native SwiftUI + AppKit · MIT</p>

Running a few AI tasks at once shouldn't mean cycling through windows to ask, “Is it still working?”
**LoopFwd for Mac** brings ongoing tasks into one glanceable island: see what is happening,
notice when you are needed, and get back to the right place.
Keep using your own agents, editors and terminals.

## See it in 26 seconds

https://github.com/user-attachments/assets/d4fdb119-f78b-47f4-b49e-13d833e83da7

[Download the launch film · 26 seconds, with sound](https://github.com/pafa/LoopFwd-For-Mac/releases/download/v0.1.0/LoopFwd-Launch-Selected-A-26s.mp4)

*The selected product film. Integration availability for **0.1.0** is listed below.*

## Features

<table>
<tr>
<td width="33%" valign="top"><h3>👀 One glance, multiple tasks</h3>Keep active sessions from different tools and projects together. Expand the island when you want detail; scroll to reach more sessions.</td>
<td width="33%" valign="top"><h3>🧩 Know what is happening</h3>Read the <b>project, task and current step</b> separately. Meaningless follow-ups such as “continue” don't replace the task's goal.</td>
<td width="33%" valign="top"><h3>🔔 Notice the moments that matter</h3>Get alerts for confirmed completions, failures and supported live requests. Keep focusing on your work instead of repeatedly checking each window.</td>
</tr>
<tr>
<td width="33%" valign="top"><h3>🧭 Get back to the task</h3>Click to return using the available route. <b>Jump to task</b> and <b>Open App</b> are clearly different—Codex Desktop supports task links.</td>
<td width="33%" valign="top"><h3>✅ Done, then out of your way</h3>Completed tasks appear briefly and idle tasks leave the main list. The island stays focused on work in progress, not a growing archive.</td>
<td width="33%" valign="top"><h3>⌨️ Keep your hands on the keyboard</h3>Open the switcher with <b>Control + G</b>, cycle through sessions, press Return to jump, or Escape to dismiss. Choose your preferred modifier.</td>
</tr>
</table>


## Make it feel like your Mac

<table>
<tr>
<td width="33%" valign="top"><h3>🖥️ Notch or external display</h3>Use the MacBook notch's sides, or a transparent top-center hot area on a screen without one. Pick the display and choose Clean or Detailed style.</td>
<td width="33%" valign="top"><h3>🎛️ As much detail as you want</h3>Adjust panel width, height and text size. Choose task summaries, activity, model, branch, terminal labels and checklists when the source provides them.</td>
<td width="33%" valign="top"><h3>🌐 English or 简体中文</h3>Follow macOS, or explicitly choose English or Simplified Chinese in settings. Your interface changes; your original task text stays intact.</td>
</tr>
<tr>
<td width="33%" valign="top"><h3>🌙 Set your own rhythm</h3>Tune hover delay, automatic collapse, event reveal and fullscreen visibility. Choose alert types, hide notification details, and enable login launch when wanted.</td>
<td width="33%" valign="top"><h3>🎵 Sound that suits your day</h3>Pick sounds by event, preview them, import your own, and adjust volume. Quiet hours mute sounds overnight without hiding tasks that need attention.</td>
<td width="33%" valign="top"><h3>📊 Usage and allowance, in view</h3>See Codex's latest reported usage and remaining allowance when available, with reset time and data age. Main Codex and Spark stay separate—not a live balance query.</td>
</tr>
</table>


## Take the next step, right from the island

Optional **Labs** controls bring small actions closer to the work. They are experimental,
off by default, and appear only when the session provides a valid control path.

<table>
<tr>
<td width="33%" valign="top"><h3>🚀 Start a task</h3>Create a LoopFwd-managed Codex task from the island, send a follow-up, or stop that managed task. Your existing external sessions remain separate.</td>
<td width="33%" valign="top"><h3>💬 Give a quick answer</h3>Answer a supported live question or choose one of its options without leaving the island. Available through OpenCode and optional Claude terminal controls.</td>
<td width="33%" valign="top"><h3>☑️ Approve or decline</h3>Review a live request and choose whether the agent may continue. For supported OpenCode and Claude requests, with setup and permission requirements below.</td>
</tr>
</table>

These are not universal controls for all eight agents. Unavailable or unverified actions stay disabled;
Codex CLI/Desktop observation does not provide approval controls. See the setup details below.

### 🔒 Local by design. Clear when something is wrong.

The monitoring path reads local session data—no LoopFwd cloud account, telemetry or transcript uploads.
Setup status shows what's available; Diagnostics explains missing or stale sources and provides a
redacted report for troubleshooting. Permissions and observer installation stay behind explicit actions.

## Your tools, together

<p align="center">
  <img src="Sources/LoopFwd/Resources/agents/openai.png" width="32" height="32" alt="Codex">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/opencode.png" width="32" height="32" alt="OpenCode">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/githubcopilot.png" width="32" height="32" alt="Copilot">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/claude-color.png" width="32" height="32" alt="Claude Code">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/gemini-color.png" width="32" height="32" alt="Gemini">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/qwen.png" width="32" height="32" alt="Qwen">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/kimi.png" width="32" height="32" alt="Kimi">&nbsp;&nbsp;
  <img src="Sources/LoopFwd/Resources/agents/grok.png" width="32" height="32" alt="Grok">
</p>

**Codex · OpenCode · Copilot · Claude Code · Gemini · Qwen · Kimi · Grok**

Eight integrations, enabled only when you want them. The first three have basic real-task evidence
on specific surfaces; the other five are optional **Experimental** integrations, off by default on new installs.
[See the exact scope and current limitations](#compatibility-and-preview-notes).

## Fork it. Ask your agent. Make it yours.

Your workflow won't look exactly like someone else's—and it shouldn't have to.
**LoopFwd for Mac is MIT-licensed source, ready to adapt with your own coding agent.**

| 🍴 Start with a fork | 🤖 Describe your workflow | 🌱 Share what works |
| --- | --- | --- |
| Keep the native island and the integrations you already use. | Ask your agent to add a local tool, improve a task summary, tune the UI, or contribute a translation. | Test the focused change and send a small PR, including its actual capability and limitations. |

Different sources offer different abilities: a local transcript can describe a task;
a verified app link can return to it; a live control API can accept a response.
You don't need to implement everything to contribute a useful integration.

[Use the ready-to-adapt agent prompt and contribution guide](CONTRIBUTING.md#develop-with-your-own-agent).

## Get started

1. **[Download the 0.1.0 preview](https://github.com/pafa/LoopFwd-For-Mac/releases/tag/v0.1.0)** and its matching checksum.
2. **Move LoopFwd into Applications.** Quit any previous copy before replacing it.
3. **Open Setup status**, enable the integrations you use, then continue working in your own tools.

The preview is ad-hoc signed, not Apple-notarized. If macOS blocks it, verify the download and
review **System Settings → Privacy & Security → Open Anyway**. Don't disable system-wide protection.

---

## Compatibility and preview notes

**0.1.0 is an early preview, not a stable 1.0.**
“Preview tested” means basic real-task monitoring on the named surface—not every capability,
account or environment. Installed software and parser tests alone do not earn that label.

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

<details>
<summary><strong>Download verification, installation and rollback</strong></summary>

The [0.1.0 pre-release](https://github.com/pafa/LoopFwd-For-Mac/releases/tag/v0.1.0) contains the ZIP, checksum and build manifest:

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

</details>

<details>
<summary><strong>Build from source</strong></summary>

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

</details>

<details>
<summary><strong>Setup details, optional observers and development-build upgrades</strong></summary>

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

</details>

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
