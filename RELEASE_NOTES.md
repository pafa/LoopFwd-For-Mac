# LoopFwd 0.1.0 — early preview candidate

Apple Silicon · macOS 14+ · manual updates · ad-hoc signature.

The first open-source version is 0.1.0, with an intended v0.1.0 GitHub Pre-release.
The previous 1.0.0-beta.1 development label is superseded; no stable 1.0 is claimed.

This is a reviewable early-preview candidate, not a stable certification of
every provider or environment. Eight integrations ship: Codex, OpenCode,
Copilot, Claude Code, Gemini, Qwen, Kimi and Grok. Codex Desktop, OpenCode TUI
HTTP and Copilot CLI have basic real-task evidence and are labeled Preview
tested; other surfaces remain Experimental. See the README capability table.
The five optional providers are off by default for new users; existing choices
are preserved. No state or control authority is granted by a preview badge.
Publishing this MIT source does not require Developer ID or notarization.

## Changes in this candidate

- Preserve the original notch wings and external-display transparent hot area.
- Remove false completion derived from idle providers or historical responses.
- Stop cards overriding the shared lifecycle state.
- Match Codex CLI identity to the real thread ID, retain all managed identities,
  and remove the eight-result Desktop output cap.
- Keep a meaningful task title through short confirmations; prioritize active
  Todo steps rather than pending work or generic thinking text.
- Consolidate banner, sound and automatic reveal decisions, withdraw outdated
  session alerts, and offer notification-detail privacy.
- Perform return commands off the UI thread with bounded helper processes.
  App-only return no longer marks an exact task as viewed.
- Defer Cursor Agent, DeepSeek Harness, Mistral Vibe, WorkBuddy and Doubao Work.
  They are not scanned or offered for new installation in 0.1.0. Existing
  software, observers, configurations and conversations are not removed.
- Preserve keyboard selection by session ID and keep the selected card visible.
- Move new task/control entries into Labs; keep existing managed return/stop.
- Centralize beta/build identity and make downloaded SHA-256 files portable.
- Discover OpenCode active identities beyond the recent-session window and rotate expensive summaries.
- Preserve notification group members across bursts and withdraw late deliveries after handling.
- Keep stale managed identities recoverable; use the shared lifecycle reducer for managed projections.
- Move community quota estimates into Labs and label historical Codex usage with its report time.
- Add Chinese common settings/notifications and separate project, conversation and task-step labels.
- Discover custom Codex homes from the CLI process environment, verify open
  rollouts, and recheck bindings when a CLI switches threads without exiting.
- Keep failed binding verification stale; cwd-only matches do not become rich
  task observations or generate completion notifications.
- Align card/detail reply controls with Labs and validate terminal return
  prerequisites before advertising an exact jump.
- Avoid repeated long-prompt parsing and unchanged process classification;
  retain the existing refresh frequency and island dimensions.
- Bound optional Claude usage reads and record buffers; hide incomplete
  estimates while history is unread, unavailable or contains oversized records.
- Budget CLI process batches independently by provider and prioritize unread
  processes on the next scan. Partial scans do not refresh success timestamps.
- Remove unused Codex history-directory guessing and its unbounded caches.
- Query exact terminal visibility in the background and recheck notification
  settings before delivery; late results cannot revive handled task alerts.
- Retain only compact notification summaries, not full prompts, plans or
  provider control payloads, while preserving original event deduplication.
- Localize dynamic usage labels and reject malformed numeric limits and future
  report timestamps as fresh usage data.
- Add an explicit System / English / Simplified Chinese interface-language
  choice that takes effect after restart without changing macOS preferences.
- Keep Spark limit reports out of the main Codex allowance; show remaining
  versus used percentages explicitly and hide missing or old main reports.
- Reuse AppKit's visible-rect tracking area across island animations instead
  of repeatedly removing and recreating it as the view changes size.
- Remove the island's outer diffuse shadow and status glow while preserving
  its dimensions, card styling and pointer regions.
- Distinguish an oversized Codex tail record from an unreadable rollout,
  retain the last trusted state without refreshing its timestamp, and avoid
  a redundant historical-plan read when the live tail is unavailable.
- Localize detailed status counts, approval controls, observation errors and
  detail labels; use the selected app language for quota reset times.
- Distinguish partial provider reads from unavailable or incompatible data in
  Diagnostics, and label the last complete read explicitly.
- Preserve meaningful goals through compound confirmations such as “好的，继续”
  without filtering concrete requests such as “继续修复登录问题”.
- Show return failures inside task details as well as the main task list;
  an application-only return still does not mark the task as viewed.

## Installation and rollback

Verify the ZIP with the matching SHA-256 file in the same directory.
Quit the old LoopFwd, extract the ZIP, and drag the app into Applications.
If macOS blocks this ad-hoc build, review System Settings → Privacy & Security
→ Open Anyway. Only proceed when you trust the source and checksum; do not
disable system-wide security protections.

Keep the previous ZIP for manual rollback. Existing preferences and provider
data are outside the app bundle. Quitting may affect LoopFwd-managed tasks,
so the app asks before exiting while they are active.

## Confirmed user feedback

The reporter confirmed that the original fullscreen flicker and gray halo are
gone. This confirms the reported scenario, not all displays or fullscreen apps.
Explicit English and Simplified Chinese selection persisted after restart.
For the reported Codex Desktop task, card navigation and a completion
notification both returned to the correct conversation. These checks do not
replace full lifecycle, notification withdrawal or permission-recovery tests.

## Known limitations and follow-up work

- The five optional integrations have not passed authenticated model-task checks.
- OpenCode and Copilot actual terminal return and full failure/permission scenarios
  remain unverified; basic progress/multi-session tests have passed.
- Codex CLI/managed and OpenCode Desktop do not borrow other surfaces' test labels.
- Complete bilingual visible UI and text-scaling/accessibility review.
- Native notification permission/withdrawal behavior and detailed jump-failure reporting.
- Display switching, sleep/wake and permission deny/recover gates.
- Broader fullscreen and Space compatibility beyond the reported scenario.
- Thirty-minute performance acceptance and refreshed product media.

These follow-ups do not turn unavailable capabilities into release promises or
block the documented early-preview scope. Unknown or incompatible data remains
visible as degraded observation. No Intel, automatic updates, cloud, mobile,
daemon or cross-device history is included.
