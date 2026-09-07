#!/bin/sh
# Build one Apple Silicon preview app and its recoverable distribution artifacts.
set -eu
cd "$(dirname "$0")"

. ./assets/release.env
./scripts/preflight
observer_version="$(jq -r .version Integrations/DeepSeekHarnessObserver/package.json)"
git_head="$(git rev-parse HEAD 2>/dev/null || printf 'uncommitted')"
if [ -n "$(git status --porcelain -- Package.swift Sources Tests Integrations assets make-app.sh scripts)" ]; then
    git_head="$git_head-dirty"
fi
products=".build/release"
dist_dir="dist"
stage_root="$(mktemp -d "/private/tmp/loopfwd-package.XXXXXX")"
stage_dist="$stage_root/dist"
stage_app="$stage_dist/LoopFwd.app"
stage_archive="$stage_dist/LoopFwd-$release_version-macOS-arm64.zip"
stage_checksum="$stage_archive.sha256"
stage_manifest="$stage_dist/LoopFwd-$release_version-build-manifest.txt"
previous_dist="$stage_root/previous-dist"

cleanup() {
    case "$stage_root" in
        /private/tmp/loopfwd-package.*) rm -rf -- "$stage_root" ;;
    esac
}
trap cleanup EXIT INT TERM

swift build -c release --arch arm64

approved_icon_hash="259a56328ae30acea2a7c89c6409f4bfee9eed98d0663d183ae8f6ad0af79b0d"
test "$(shasum -a 256 assets/icon-1024.png | awk '{print $1}')" = "$approved_icon_hash"
shasum -a 256 -c assets/agent-icon-checksums.sha256
node scripts/verify-agent-icons.mjs
shasum -a 256 -c assets/brand-checksums.sha256

icon_output="$stage_root/icon"
mkdir -p "$icon_output"
xcrun actool \
    --compile "$icon_output" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$icon_output/partial.plist" \
    --output-format human-readable-text \
    --warnings \
    --errors \
    assets/Assets.xcassets

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$products/LoopFwd" "$stage_app/Contents/MacOS/LoopFwd"
cp assets/Info.plist "$stage_app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$app_version" "$stage_app/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$build_number" "$stage_app/Contents/Info.plist"
plutil -insert LoopFwdReleaseVersion -string "$release_version" "$stage_app/Contents/Info.plist"
plutil -insert LoopFwdBuildCommit -string "$git_head" "$stage_app/Contents/Info.plist"
plutil -insert LoopFwdReleaseChannel -string "$release_channel" "$stage_app/Contents/Info.plist"
cp "$icon_output/AppIcon.icns" "$stage_app/Contents/Resources/AppIcon.icns"
cp -R "$products/LoopFwd_LoopFwd.bundle" "$stage_app/Contents/Resources/"
node scripts/compile-localizations.mjs "$stage_app/Contents/Resources/LoopFwd_LoopFwd.bundle"
cp LICENSE "$stage_app/Contents/Resources/LICENSE"
cp PRIVACY.md "$stage_app/Contents/Resources/PRIVACY.md"
cp THIRD_PARTY_NOTICES.md "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSES/lobe-icons-MIT.txt "$stage_app/Contents/Resources/lobe-icons-MIT.txt"
cp RELEASE_NOTES.md "$stage_app/Contents/Resources/RELEASE_NOTES.md"
cp Integrations/LocalHooks/observe-hook.mjs "$stage_app/Contents/Resources/LoopFwdObserveHook.mjs"
cp Integrations/LocalHooks/install-mistral.py "$stage_app/Contents/Resources/LoopFwdInstallMistral.py"
mkdir -p "$stage_app/Contents/Resources/LoopFwdJSONHooks"
cp Integrations/LocalHooks/configure-json-hooks.mjs "$stage_app/Contents/Resources/LoopFwdJSONHooks/"
cp -R Integrations/LocalHooks/vendor "$stage_app/Contents/Resources/LoopFwdJSONHooks/"

# npm-compatible package tarball; installation is later performed only after
# the user clicks Install through the official dsh profile plugin command.
mkdir -p "$stage_root/observer/package"
cp -R Integrations/DeepSeekHarnessObserver/package.json \
      Integrations/DeepSeekHarnessObserver/cordis.patch.yml \
      Integrations/DeepSeekHarnessObserver/LICENSE \
      Integrations/DeepSeekHarnessObserver/lib \
      "$stage_root/observer/package/"
tar -czf "$stage_app/Contents/Resources/LoopFwdDSHObserver.tgz" \
    -C "$stage_root/observer" package

xattr -cr "$stage_app" 2>/dev/null || true
codesign --force --sign - --entitlements assets/entitlements.plist "$stage_app"
codesign --verify --deep --strict "$stage_app"
plutil -lint "$stage_app/Contents/Info.plist"
test "$(plutil -extract CFBundleShortVersionString raw "$stage_app/Contents/Info.plist")" = "$app_version"
test "$(lipo -archs "$stage_app/Contents/MacOS/LoopFwd")" = "arm64"
test -f "$stage_app/Contents/Resources/LoopFwdDSHObserver.tgz"
test -f "$stage_app/Contents/Resources/LICENSE"
test -f "$stage_app/Contents/Resources/PRIVACY.md"
test -f "$stage_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$stage_app/Contents/Resources/lobe-icons-MIT.txt"
test -f "$stage_app/Contents/Resources/AppIcon.icns"
test -f "$stage_app/Contents/Resources/LoopFwd_LoopFwd.bundle/brand/loopfwd-symbol-on-dark.svg"
test -f "$stage_app/Contents/Resources/LoopFwd_LoopFwd.bundle/brand/loopfwd-symbol-mono-black.svg"

ditto -c -k --sequesterRsrc --keepParent "$stage_app" "$stage_archive"
archive_hash="$(shasum -a 256 "$stage_archive" | awk '{print $1}')"
printf '%s  %s\n' "$archive_hash" "LoopFwd-$release_version-macOS-arm64.zip" > "$stage_checksum"

# Use the same source identity in the bundle and manifest.
build_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' \
    "product=LoopFwd" \
    "version=$release_version" \
    "appVersion=$app_version" \
    "build=$build_number" \
    "channel=$release_channel" \
    "releaseTag=v$release_version" \
    "observerVersion=$observer_version" \
    "swift=$(swift --version | head -1)" \
    "xcode=$(xcodebuild -version | tr '\n' ' ')" \
    "agentIcons=@lobehub/icons-static-png@1.95.0" \
    "agentIconProvenanceSha256=$(shasum -a 256 assets/agent-icon-provenance.json | awk '{print $1}')" \
    "platform=macOS 14+" \
    "architecture=arm64" \
    "signature=ad-hoc" \
    "gitHead=$git_head" \
    "builtAt=$build_time" \
    "deepSeekHarness=0.1.2-alpha.5" \
    "deepSeekHarnessCommit=db6bdc3576c2d4e7c965e8e3ed0c2a731eed87f5" \
    "deepSeekHarnessStatus=retained-resource-not-enabled-in-preview" \
    > "$stage_manifest"

test -s "$stage_archive"
test -s "$stage_checksum"
test -s "$stage_manifest"
test "$(shasum -a 256 "$stage_archive" | awk '{print $1}')" = "$archive_hash"

# Every artifact is complete before the existing distribution is touched.
# Replacing the directory keeps the previous candidate recoverable if the
# final rename fails.
if [ -e "$dist_dir" ]; then
    mv "$dist_dir" "$previous_dist"
fi
if ! mv "$stage_dist" "$dist_dir"; then
    if [ -e "$previous_dist" ]; then mv "$previous_dist" "$dist_dir"; fi
    exit 1
fi

echo "Built $dist_dir/LoopFwd.app"
echo "Archive $dist_dir/LoopFwd-$release_version-macOS-arm64.zip"
echo "Checksum $dist_dir/LoopFwd-$release_version-macOS-arm64.zip.sha256"
