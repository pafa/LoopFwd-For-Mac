# Agent icon provenance

The 11 icons in `Sources/LoopFwd/Resources/agents/` are unmodified dark-theme
assets from `@lobehub/icons-static-png@1.95.0`, retrieved from the npm registry
on 2026-09-07. The 0.1.1 source candidate corrects earlier mismatched resources. The upstream project is
[Lobe Icons](https://github.com/lobehub/lobe-icons), licensed under MIT. The
distributed license is preserved in `LICENSES/lobe-icons-MIT.txt`.

The exact production hashes are stored in `agent-icon-checksums.sha256` and
verified before every release build. The original npm archive URL, SHA-512
integrity and per-file upstream paths/digests are recorded in
`agent-icon-provenance.json`. The archive was integrity-checked before import.
Use `node scripts/verify-agent-icons.mjs --archive <original-1.95.0.tgz>`
for an independent byte comparison against that archive. Normal builds verify
the recorded provenance offline.

## README theme variants

The 16 documentation-only images in `docs/assets/agents/{light,dark}/` are
unmodified light/dark variants for the eight preview integrations from the same
pinned npm package, retrieved through jsDelivr on 2026-09-07. Each file was
checked against the package index's SHA-256 digest and size before import.
The exact imported hashes are recorded in
`docs/assets/agent-icon-checksums.sha256` and checked by `scripts/verify`.

The READMEs use GitHub's theme-aware `picture` markup, with light images as the
fallback. White App icons must not be embedded directly on a white README.
These documentation assets do not replace the App's resources. Their MIT
license and trademark disclaimer are the same as those linked above.

The icons identify compatible third-party tools. Their owners retain all
rights in their names and marks; inclusion does not imply affiliation,
sponsorship, or endorsement.
