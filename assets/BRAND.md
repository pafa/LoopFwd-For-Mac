# LoopFwd native brand assets

The native app uses the approved LoopFwd sail-forward V4 identity dated 2026-09-03.

- `LoopFwdMark.svg` is the four-path full-color master used on dark surfaces.
- `icon-1024.png` is the reviewed macOS app icon source.
- `Assets.xcassets/AppIcon.appiconset` contains the standard macOS icon renditions generated from that source.
- `AppIcon.icns` is a checked-in preview of the compiled icon. `make-app.sh` recompiles the asset catalog with Apple `actool` and packages that output.

The reviewed 1024 px source SHA-256 is
`259a56328ae30acea2a7c89c6409f4bfee9eed98d0663d183ae8f6ad0af79b0d`.

The in-app color and template SVGs under `Sources/LoopFwd/Resources/brand/` use the same sail, embedded `F`, hull and wake geometry.
