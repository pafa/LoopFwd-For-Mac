# Contributing

LoopFwd for Mac is a native macOS Swift package. Packaging requires full Xcode 26.6,
Node 24+, jq, and ripgrep on Apple Silicon. The app's deployment target remains macOS 14.
Run `./scripts/preflight` for readable environment checks.

Before opening a change:

```bash
xcrun swift-format format --in-place --recursive Sources Tests
./scripts/verify-public-tree
./scripts/verify
```

Changes to `Integrations/DeepSeekHarnessObserver/` also require Node.js 24 or
later and:

```bash
npm test --prefix Integrations/DeepSeekHarnessObserver
```

Keep changes product-first and narrow:

- Add a provider Reader only when a real local data source exists.
- Treat process tables and transcripts as observation, never as approval authority.
- Keep provider configuration changes behind an explicit user action with a backup and recovery path.
- Do not add generated builds, diagnostics, transcripts, credentials, or personal machine paths.
- Preserve the notices in `THIRD_PARTY_NOTICES.md` when modifying imported upstream work.

## Compatibility checks without an exhaustive matrix

The deployment target is macOS 14. CI uses macOS 26; the local development
machine is 26.6.2. A clean macOS 14 runtime check is still unverified.
Contributors with that environment can verify a fresh download/build, launch,
empty state, one Codex task, return and notification. Report the exact OS,
LoopFwd commit, provider surface/version and any custom data-directory use;
do not submit prompts, credentials or complete paths.

Changes should add focused regression tests and run the existing verification
chain, not re-test every account/provider combination. A fixture is not
real-account acceptance. Keep unknown capabilities and versions explicit.

## Develop with your own agent

Fork the repository and use the coding agent you already trust. Useful contributions
include a local integration, clearer task summaries, a small interaction improvement,
translations and reproducible bug fixes. A reliable observation-only integration is
welcome; it does not need to implement replies or approvals.

Give your agent a concrete goal and a bounded starting prompt:

```text
I forked LoopFwd for Mac. Implement this focused change: [describe the need].
Read README, CONTRIBUTING and docs/ARCHITECTURE.md. Work on a task branch.
Reuse the existing implementation and official provider interfaces; avoid unrelated rewrites.
For an integration, state what it can observe, whether it can return to an exact task,
and whether a live, verifiable control interface actually exists.
Do not infer completion from old replies or promote process detection to rich task state.
Configuration writes need explicit actions, backups and recoverable failures.
Do not log in, purchase credits or expand permissions without approval.
Add focused regressions and run ./scripts/verify; smoke the real App for UI changes.
Open a small PR with the change, actual verification and limitations. Do not merge or publish it.
```

For provider work, start with [existing Readers](Sources/LoopFwd/Providers),
[surface contracts](Sources/LoopFwd/Core/IntegrationProfile.swift) and
[the support registry](Sources/LoopFwd/Core/SupportRegistry.swift). Keep stable session
identity, source freshness, task state and control authority separate. Add only the
capabilities supported by the actual source, keep unverified surfaces Experimental,
and test the production read path with sanitized fixtures. Never submit transcripts,
credentials or local configuration backups to a PR.

Generated code is still your contribution: review its complete diff, run the checks,
and describe which provider/version you actually exercised. Account or environment
limits are fine to disclose; they are not reasons to invent a passing result.

## Branches and pull requests

### Versioning

The first open-source release is **0.1.0**, an early preview, not a stable 1.0.
`assets/release.env` is the App's version authority: `release_version`,
`build_number`, and `release_channel`. The numeric bundle version is derived,
not maintained again in Info.plist. About and Diagnostics read the packaged metadata.

Use 0.1.x for fixes and 0.2.0 for the next feature iteration. Increment the build
number for each distributed rebuild. Do not silently replace a published ZIP or
move an existing tag; a replacement release needs a new patch version and tag.
Keep 0.x releases in the `preview` channel and mark GitHub releases as Pre-release.
Moving to 1.0 requires a separate product-readiness decision.

Update the English/Chinese README and Release Notes with the chosen version.
Preflight rejects mismatches, and verification checks the packaged version,
channel, build, manifest and Observer version. The Observer owns its version in
its package.json; its resource name is stable so version bumps need no Swift edits.
Provider compatibility versions and snapshot schema versions are independent.

### Workflow

`main` is the only long-lived branch. Use a short-lived branch for one focused
change, keep unrelated formatting out of the diff, and prefer squash merge.
Agent-created branches use the `codex/` prefix.

Keep `main` protected: changes go through a PR, required checks must pass, and
force pushes and branch deletion are disabled. A maintainer must approve the
reviewed candidate before an agent merges it; green checks alone are not approval.
After merging, delete that completed task branch and start the next change from
the updated `main`. Keep release tags immutable; do not maintain a separate
long-lived development or release branch for this preview.

At task handoff, explicitly provide the preview link, PR and head commit, a short
change summary, and actual check results. State whether the change is still on
the task branch or already on `main`, then ask the maintainer whether to merge
that specific candidate. Do not silently leave a finished change on a branch,
assume approval from earlier work, or describe a branch preview as the live homepage.
Wait for the answer before merging; materially changed candidates need confirmation again.

The required job names are `macOS build and tests` and `Observer and configuration tests`.
The macOS job includes the public-tree hygiene check before building. UI or packaging changes also
need a real launch smoke on macOS; record what was exercised in the pull
request.

Successful `main` builds retain the verified ZIP, matching SHA-256 file and
build manifest for 14 days in the Actions run. The artifact name includes the
built commit; extract the outer Actions archive before checking the inner app
ZIP with its SHA-256 file. These are review candidates, not public releases.
Never use an expiring Actions artifact URL as the website download link.

After real-device acceptance and explicit publication approval, use an
annotated preview tag and a GitHub Pre-release for the selected commit. Upload
the exact verified ZIP, checksum and manifest together, compare the manifest's
`gitHead` with the tag, and verify a fresh download before changing the website.
Keep the previous version's release URL for manual rollback. Publishing source,
creating a release and changing the website are separate approval boundaries.

Do not create a stable release tag from fixture-only evidence. Provider
lifecycle, display behavior, permissions, and the packaged App must pass their
real-device release gates first.

For 0.1.x previews, use the eight-provider scope in README and
`SupportRegistry.shippedKinds`. Basic real-task evidence earns a per-surface
Preview tested label, not stable certification. Optional integrations stay
Experimental; unverified accounts and uncommon environment combinations do not
block this preview. Deferred readers remain source references, not active support.

`verify-public-tree` accepts normal uncommitted development changes. Use
`./scripts/verify-public-tree --release` only when checking a clean release
commit. Build caches and packaged output are excluded from source-tree checks.

Translate visible strings in the String Catalog, not in generated runtime
resources. Keep new controls behind Labs until their authority and real target
checks have been exercised. An integration's support tier is controlled by
`SupportRegistry` per surface, never by brand-wide assumptions.
