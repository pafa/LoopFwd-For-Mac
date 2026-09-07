# LoopFwd 0.1.1 — patch preview

Apple Silicon · macOS 14+ deployment target · manual updates · ad-hoc signature.

These notes describe 0.1.1, build 3. Downloadable packages and their exact source
identity are listed on the corresponding GitHub pre-release page. The existing
v0.1.0 tag and download remain immutable; updates and rollback are manual.

## Fixes

- Fix a packaged-app startup crash when localized resources fall back to the
  build machine's directory. All runtime resources now resolve inside the app.
  Verification moves the built package, hides build resources and checks both
  languages before any provider service starts; missing resources fail visibly.
- Match Claude hooks by exact owned command. Preserve other commands in the
  same matcher group and unrelated commands whose paths contain “loopfwd”.
- Reject unsupported or unreadable hook settings. Keep separate private backups
  for every operation, preserve concurrent edits, and report recovery failures.
- Show the exact Claude settings target and allow choosing a custom
  CLAUDE_CONFIG_DIR. Removal affects only that profile; shared observer files
  remain available to other configured profiles.
- Remove Terminal.app global keyboard injection and its Accessibility setup
  prompt. Monitoring and verified terminal return remain available; replies and
  approvals require a session-addressed API even with Labs enabled.
- Read Codex Desktop's data root from the observed app environment, with an
  explicit folder fallback for unavailable/ambiguous roots. Finder's environment
  is not used as evidence of another app's CODEX_HOME.
- Separate observed provider versions/sources from supported reader versions in
  Diagnostics. Unknown is explicit; no provider executable is launched for a
  version probe.
- Replace inconsistent App provider icons with the exact unmodified assets from
  the declared npm 1.95.0 archive. Verify SHA-512 archive integrity and file-level
  SHA-256 provenance; include provenance identity in the build manifest.
- Localize remaining dynamic task-count/diagnostic/availability text and the new
  setup messages. Keep the approved LoopFwd logo, island size and display shape.
- Replace outdated architecture/test-history prose with current capability and
  configuration boundaries; improve issue reports for different installations.

## Scope and known limitations

Eight integrations remain: Codex, OpenCode, Copilot, Claude, Gemini, Qwen, Kimi
and Grok. Preview tested still refers only to existing basic evidence for Codex
Desktop, OpenCode TUI HTTP and Copilot CLI. It is not a new certification of
every feature, account or environment. Other surfaces remain Experimental.
Cursor, DeepSeek Harness, Mistral, WorkBuddy and Doubao Work stay deferred; no
installed client, user history or configuration is removed automatically.

Terminal.app replies and approvals are deliberately unavailable. iTerm/tmux/
WezTerm/kitty control remains experimental and requires the actual target API.
Codex CLI/Desktop observation does not provide live approval authority.

Observed versions currently use running-app bundle metadata or OpenCode's
current health response. Other surfaces may report unknown; a supported version
range is not the user's installed version.

The deployment target is macOS 14. CI runs on macOS 26; the local development
machine is macOS 26.6.2. A clean macOS 14 device run is not yet verified.
This gap does not imply a confirmed startup failure, nor a claim that all
macOS 14+ environments have been exercised.

These packages are not Developer ID signed or notarized. Review the download's
checksum and macOS warning before using Privacy & Security → Open Anyway.
No App Store submission is involved. Updates and rollback remain manual.

## Reviewing this candidate

Run `./scripts/verify` and `./scripts/verify-public-tree` from a clean clone.
For an upstream icon re-audit, use
`node scripts/verify-agent-icons.mjs --archive <original-1.95.0.tgz>`.
This optional check verifies the archive's pinned integrity before comparing
its original files; normal builds do not require a network connection.

A packaged-app smoke and exact candidate/CI results belong in the PR handoff.
Do not infer those results from this release-note file. Stable 1.0 remains a
separate readiness decision.
