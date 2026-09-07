# Security Policy

## Supported version

Security fixes are applied to the latest revision on `main`. Until the first
stable release, all builds should be treated as pre-release software.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use this repository's
GitHub **Private vulnerability reporting** form from the Security tab. Include
the affected commit or version, macOS version, reproduction steps, and the
smallest redacted diagnostic excerpt needed to explain the issue.

Do not include API keys, complete transcripts, private repository contents, or
unredacted local paths. We will acknowledge the report in the private advisory
and coordinate disclosure after a fix is available.

LoopFwd treats any bug that can send input to the wrong terminal, approve the
wrong request, expose provider data, or silently modify provider configuration
as a security issue.
