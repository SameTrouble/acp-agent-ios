#!/usr/bin/env bash
#
# Archive the iOS app and upload the build to TestFlight (issue #14).
#
# Requires: xcodegen, Xcode command line tools, an App Store Connect API key.
# See ios/RELEASE.md for the one-time account, certificate and key setup.
#
# Usage:
#   ios/scripts/release-testflight.sh              # bump build, archive, upload
#   ios/scripts/release-testflight.sh --no-upload  # archive + export only
#   ios/scripts/release-testflight.sh -h|--help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/../App"
BUILD_DIR="$APP_DIR/.build"
ARCHIVE_PATH="$BUILD_DIR/ACPAgent.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
SCHEME="ACPAgent"

do_upload=true

usage() {
  cat <<'EOF'
Archive the iOS app and upload the build to TestFlight (issue #14).

Usage:
  ios/scripts/release-testflight.sh              # bump build, archive, upload
  ios/scripts/release-testflight.sh --no-upload  # archive + export only
  ios/scripts/release-testflight.sh -h|--help

Requires: xcodegen, Xcode, and an App Store Connect API key.
See ios/RELEASE.md for setup.

Environment:
  ACP_DEVELOPMENT_TEAM   10-character Apple team id (required)
  ACP_ASC_KEY_ID         App Store Connect API key id (upload only)
  ACP_ASC_ISSUER_ID      App Store Connect issuer id (upload only)
  ACP_BUILD_NUMBER       override the derived build number
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-upload) do_upload=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }

# --- Required configuration -------------------------------------------------
# The team owns the signing identity; the API key authenticates the upload.
# Both are secrets, so they come from the environment, never the repo.
: "${ACP_DEVELOPMENT_TEAM:?set ACP_DEVELOPMENT_TEAM to your 10-character Apple team id}"
if $do_upload; then
  : "${ACP_ASC_KEY_ID:?set ACP_ASC_KEY_ID to the App Store Connect API key id}"
  : "${ACP_ASC_ISSUER_ID:?set ACP_ASC_ISSUER_ID to the App Store Connect issuer id}"
fi

command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"

# --- Build number -----------------------------------------------------------
# TestFlight rejects a build number it has already seen, so every upload needs
# a fresh one. The number of commits on the current branch is monotonic and
# needs no state in the repo — but only if you release from the same branch
# every time. Hotfix branches with fewer commits than main will collide; pass
# ACP_BUILD_NUMBER explicitly in that case.
BUILD_NUMBER="${ACP_BUILD_NUMBER:-$(git -C "$SCRIPT_DIR" rev-list --count HEAD)}"
echo "==> build number $BUILD_NUMBER"

# --- Project generation -----------------------------------------------------
echo "==> generating Xcode project"
(cd "$APP_DIR" && xcodegen generate)

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Archive ----------------------------------------------------------------
# Automatic signing resolves the App Store distribution profile itself,
# so no profile files live in the repo.
echo "==> archiving"
archive_log="$BUILD_DIR/archive.log"
if ! xcodebuild archive \
  -project "$APP_DIR/ACPAgent.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$ACP_DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  > "$archive_log" 2>&1; then
  tail -40 "$archive_log"
  die "archive failed — see $archive_log"
fi
tail -5 "$archive_log"

# --- Export -----------------------------------------------------------------
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$ACP_DEVELOPMENT_TEAM</string>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

echo "==> exporting ipa"
export_log="$BUILD_DIR/export.log"
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  > "$export_log" 2>&1; then
  tail -40 "$export_log"
  die "export failed — see $export_log"
fi
tail -5 "$export_log"

IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
[[ -n "$IPA" ]] || die "no .ipa produced in $EXPORT_DIR"
echo "==> exported $IPA"

if ! $do_upload; then
  echo "==> --no-upload given, stopping before TestFlight"
  exit 0
fi

# --- Upload -----------------------------------------------------------------
# altool reads the private key from ~/.appstoreconnect/private_keys, so only
# the key id and issuer id need to be passed.
echo "==> validating with App Store Connect"
xcrun altool --validate-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ACP_ASC_KEY_ID" \
  --apiIssuer "$ACP_ASC_ISSUER_ID"

echo "==> uploading to TestFlight"
xcrun altool --upload-app \
  --type ios \
  --file "$IPA" \
  --apiKey "$ACP_ASC_KEY_ID" \
  --apiIssuer "$ACP_ASC_ISSUER_ID"

echo "==> uploaded build $BUILD_NUMBER — processing takes a few minutes,"
echo "    then it appears in TestFlight for the internal group."
