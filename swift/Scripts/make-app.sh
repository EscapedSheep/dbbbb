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
# so Developer ID signing and notarization are not possible here.
#
# Keychain caveat: an ad-hoc signature's designated requirement is anchored
# on the binary's cdhash — a hash of the binary's contents that changes with
# every rebuild. Keychain items (service names like `dev.dbbbb.connection`)
# are therefore NOT seamlessly shared across rebuilds: macOS re-prompts for
# authorization each time the binary changes, even with an unchanged bundle
# identifier. Once the app is signed with a Developer ID, the designated
# requirement anchors on the team ID + bundle identifier instead, which is
# stable across builds, so Keychain items created by earlier properly signed
# builds stay accessible without re-prompting.
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
# Fallback version, used only when HEAD carries no exact git tag. When HEAD
# is tagged, the tag is the single source of truth and must agree with this
# constant — a mismatch is a hard error (update the constant or fix the tag).
FALLBACK_VERSION="0.3.0"
MIN_MACOS="15.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/.." && pwd)"
RELEASE_DIR="$SWIFT_DIR/release"
ICON_SRC="$REPO_ROOT/build/icon.png"
ARCH="$(uname -m)"

if TAG="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null)"; then
  VERSION="${TAG#v}"
  if [[ "$VERSION" != "$FALLBACK_VERSION" ]]; then
    echo "error: git tag '$TAG' implies version '$VERSION' but FALLBACK_VERSION is '$FALLBACK_VERSION';" >&2
    echo "       update FALLBACK_VERSION in this script or move the tag" >&2
    exit 1
  fi
else
  VERSION="$FALLBACK_VERSION"
fi

APP_DIR="$RELEASE_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macOS-$ARCH.zip"

# Temp dirs created below (iconset, zip re-extraction, smoke-test HOME) and
# the smoke-test app process are always cleaned up, even on failure.
TMP_DIRS=()
cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  if ((${#TMP_DIRS[@]})); then
    rm -rf "${TMP_DIRS[@]}"
  fi
}
trap cleanup EXIT

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
ICONSET_TMP="$(mktemp -d)"
TMP_DIRS+=("$ICONSET_TMP")
ICONSET="$ICONSET_TMP/AppIcon.iconset"
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

echo "==> Verifying zip integrity (re-extract)"
ZIP_VERIFY_DIR="$(mktemp -d)"
TMP_DIRS+=("$ZIP_VERIFY_DIR")
ditto -x -k "$ZIP_PATH" "$ZIP_VERIFY_DIR"
[[ -x "$ZIP_VERIFY_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]] \
  || { echo "error: re-extracted zip is missing the app executable" >&2; exit 1; }

# ── 7. Smoke test: launch the bundled app, confirm it stays alive ───────────
if [[ "${SKIP_SMOKE_TEST:-0}" != "1" ]]; then
  echo "==> Smoke test: launching bundled app for 8s (sandboxed from real user data)"
  # Isolation: the smoke instance must not read or write the real user's
  # ~/Library/Application Support/dbbbb and must not eagerly reconnect the
  # real user's saved connections. A HOME override alone is NOT sufficient —
  # on macOS NSHomeDirectory()/FileManager ignore the HOME env var — so the
  # real mechanism is a Seatbelt profile (sandbox-exec) denying access to the
  # real data directory and to outbound networking. The throwaway HOME is
  # kept only as belt-and-braces for anything that does honor it.
  SMOKE_HOME="$(mktemp -d)"
  TMP_DIRS+=("$SMOKE_HOME")
  SMOKE_PROFILE="$SMOKE_HOME/smoke.sb"
  cat > "$SMOKE_PROFILE" <<EOF
(version 1)
(allow default)
(deny file-read* file-write*
  (literal "$HOME/Library/Application Support/$APP_NAME")
  (subpath "$HOME/Library/Application Support/$APP_NAME"))
(deny network-outbound)
EOF
  HOME="$SMOKE_HOME" sandbox-exec -f "$SMOKE_PROFILE" \
    "$APP_DIR/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 &
  APP_PID=$!
  sleep 8
  if kill -0 "$APP_PID" 2>/dev/null; then
    echo "==> Smoke test passed (pid $APP_PID alive after 8s); terminating"
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
  else
    echo "error: bundled app exited or crashed within 8s" >&2
    exit 1
  fi
fi

echo "==> Done:"
echo "    $APP_DIR"
echo "    $ZIP_PATH"
