#!/usr/bin/env bash
#
# make-app.sh — Package the SwiftPM release build of dbbbb into a proper
# dbbbb.app bundle plus a distributable zip archive.
#
# Usage:
#   swift/Scripts/make-app.sh            # full pipeline (build, bundle, sign, verify, zip, smoke-launch)
#   SKIP_SMOKE_TEST=1 swift/Scripts/make-app.sh   # skip the launch smoke test
#
# Outputs (under swift/release/):
#   dbbbb.app
#   dbbbb-<version>-macOS-<arch>.zip
#
# Signing: AD-HOC ONLY (codesign --sign -). This machine currently has zero
# valid codesigning identities (`security find-identity -v -p codesigning`),
# so Developer ID signing and notarization are not possible here. Ad-hoc
# signing still gives the bundle a stable designated requirement, which keeps
# Keychain items (service names like `dev.dbbbb.connection`) accessible as
# long as the bundle identifier and keychain service names stay unchanged.
#
# ── Upgrading to Developer ID + notarization once credentials exist ──
# Replace the ad-hoc codesign step below with:
#
#   1. Sign with your Developer ID Application identity + hardened runtime:
#        codesign --force --deep --options runtime --timestamp \
#          --sign "Developer ID Application: Your Name (TEAMID)" \
#          swift/release/dbbbb.app
#   2. Verify:
#        codesign --verify --deep --strict --verbose=2 swift/release/dbbbb.app
#        spctl --assess --type execute -vv swift/release/dbbbb.app   # must pass
#   3. Notarize the zip and staple the ticket:
#        xcrun notarytool submit swift/release/dbbbb-<ver>-macOS-<arch>.zip \
#          --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-pw> \
#          --wait
#        xcrun stapler staple swift/release/dbbbb.app
#      (then re-create the zip from the stapled .app)
#
# ────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
APP_NAME="dbbbb"
BUNDLE_ID="dev.dbbbb"
VERSION="0.2.0"
MIN_MACOS="15.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/.." && pwd)"
RELEASE_DIR="$SWIFT_DIR/release"
ICON_SRC="$REPO_ROOT/build/icon.png"
ARCH="$(uname -m)"

APP_DIR="$RELEASE_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macOS-$ARCH.zip"

echo "==> Packaging $APP_NAME $VERSION ($ARCH)"

# ── 1. Release build ─────────────────────────────────────────────────────────
echo "==> Building release binary"
cd "$SWIFT_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN_PATH" ]] || { echo "error: release binary not found at $BIN_PATH" >&2; exit 1; }

# ── 2. Self-containment check ────────────────────────────────────────────────
# All SwiftPM dependencies (MongoKitten, PostgresNIO, MySQLNIO, GRDB) are
# statically linked. Fail if the binary references any non-system dylib that
# we would have to bundle.
echo "==> Checking dynamic library references (otool -L)"
otool -L "$BIN_PATH"
if otool -L "$BIN_PATH" | tail -n +2 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/Library/|@rpath/libswift.*\.dylib)' ; then
  echo "error: binary depends on non-system dylibs; bundle them before shipping" >&2
  exit 1
fi

# ── 3. Assemble the .app bundle ──────────────────────────────────────────────
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<true/>
	<key>NSSupportsSuddenTermination</key>
	<true/>
</dict>
</plist>
EOF

# ── 4. Icon: build AppIcon.icns from build/icon.png via iconutil ────────────
echo "==> Generating AppIcon.icns from $ICON_SRC"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16:16" "32:16" "32:32" "64:32" "128:128" "256:128" "256:256" "512:256" "512:512" "1024:512"; do
  px="${spec%%:*}"
  base="${spec##*:}"
  if [[ "$px" -eq "$base" ]]; then
    name="icon_${base}x${base}.png"
  else
    name="icon_${base}x${base}@2x.png"
  fi
  sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

# ── 5. Ad-hoc code signing ───────────────────────────────────────────────────
# Hardened runtime (--options runtime) works fine with ad-hoc signing and
# keeps the bundle ready for notarization later; if it ever breaks execution,
# drop that flag and re-test the smoke launch below.
echo "==> Ad-hoc signing (codesign --sign -)"
codesign --force --deep --options runtime --sign - "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign -dv --verbose=2 "$APP_DIR" 2>&1 | grep -E '^(Identifier|Format|Signature)' || true

# Gatekeeper (spctl) will reject ad-hoc-signed apps — expected, not fatal.
if spctl --assess --type execute -vv "$APP_DIR" 2>&1; then
  echo "==> spctl: accepted"
else
  echo "==> spctl: rejected (expected for ad-hoc signature; users right-click → Open)"
fi

# ── 6. Zip archive ───────────────────────────────────────────────────────────
echo "==> Creating $ZIP_PATH"
cd "$RELEASE_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$(basename "$ZIP_PATH")"

# ── 7. Smoke test: launch the bundled app, confirm it stays alive ───────────
if [[ "${SKIP_SMOKE_TEST:-0}" != "1" ]]; then
  echo "==> Smoke test: launching bundled app for 8s"
  "$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 &
  APP_PID=$!
  sleep 8
  if kill -0 "$APP_PID" 2>/dev/null; then
    echo "==> Smoke test passed (pid $APP_PID alive after 8s); terminating"
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  else
    echo "error: bundled app exited or crashed within 8s" >&2
    exit 1
  fi
fi

echo "==> Done:"
echo "    $APP_DIR"
echo "    $ZIP_PATH"
