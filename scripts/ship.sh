#!/usr/bin/env bash
# ship.sh — archive, export, and upload Amperfy to TestFlight.
#
# Usage:
#   scripts/ship.sh <new-version>
#   scripts/ship.sh --help
#
# Example:
#   scripts/ship.sh 8
#
# This script:
#   1. Sources api-key.env and unlocks the build keychain
#   2. Bumps CURRENT_PROJECT_VERSION via bump-version.sh
#   3. Archives (xcodebuild archive, Release config, device destination)
#   4. Exports to .ipa (xcodebuild -exportArchive)
#   5. Uploads to TestFlight (xcrun altool --upload-app)
#   6. Prints a summary with version, delivery UUID, and HEAD commit SHA

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
SIGNING_DIR="$(cd "$PROJECT_DIR/../.signing" && pwd)"
PBXPROJ="$PROJECT_DIR/Amperfy.xcodeproj/project.pbxproj"
BUILD_DIR="$PROJECT_DIR/build"
KEYCHAIN="$HOME/Library/Keychains/spike-build.keychain-db"

usage() {
  echo "Usage: $0 <new-version-number>"
  echo ""
  echo "Bumps CURRENT_PROJECT_VERSION, archives Amperfy, exports .ipa,"
  echo "and uploads to TestFlight via altool."
  echo ""
  echo "Prerequisites:"
  echo "  - Xcode installed with iOS SDK"
  echo "  - spike/.signing/ populated (api-key.env, keychain.password, profiles)"
  echo "  - Build keychain created at $KEYCHAIN"
  echo ""
  echo "Example: $0 8"
  exit "${1:-0}"
}

step() { echo ""; echo "=== $1 ==="; }
fail() { echo "FAILED at step: $1"; exit 1; }

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage 0
[[ $# -ne 1 ]] && { echo "Error: expected exactly one argument (new version number)"; usage 1; }

NEW_VERSION="$1"

# ------------------------------------------------------------------
step "1/6 Source API key + unlock keychain"

if [[ ! -f "$SIGNING_DIR/api-key.env" ]]; then
  echo "Error: $SIGNING_DIR/api-key.env not found"
  exit 1
fi
# shellcheck disable=SC1091
source "$SIGNING_DIR/api-key.env"

if [[ ! -f "$SIGNING_DIR/keychain.password" ]]; then
  echo "Error: $SIGNING_DIR/keychain.password not found"
  exit 1
fi
security unlock-keychain \
  -p "$(cat "$SIGNING_DIR/keychain.password")" \
  "$KEYCHAIN" 2>/dev/null || true
echo "Keychain unlocked, KEY_ID=$APPSTORE_KEY_ID"

# ------------------------------------------------------------------
step "2/6 Bump version"

"$SCRIPTS_DIR/bump-version.sh" "$NEW_VERSION" || fail "version bump"

# Check if ReleaseNotes.swift was updated more recently than the version bump
RELEASE_NOTES="$PROJECT_DIR/Amperfy/SwiftUI/Settings/ReleaseNotes.swift"
if [[ -f "$RELEASE_NOTES" ]]; then
  NOTES_MOD=$(stat -f %m "$RELEASE_NOTES" 2>/dev/null || echo 0)
  PBXPROJ_MOD=$(stat -f %m "$PBXPROJ" 2>/dev/null || echo 0)
  if [[ "$NOTES_MOD" -lt "$PBXPROJ_MOD" ]]; then
    echo ""
    echo "⚠️  WARNING: ReleaseNotes.swift has NOT been updated since the last version bump!"
    echo "    Update Amperfy/SwiftUI/Settings/ReleaseNotes.swift with the new build's"
    echo "    What's New and Testing Focus before archiving."
    echo ""
  fi
else
  echo ""
  echo "⚠️  WARNING: ReleaseNotes.swift not found at expected path!"
  echo ""
fi

# ------------------------------------------------------------------
step "3/6 Archive"

mkdir -p "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT_DIR/Amperfy.xcodeproj" \
  -scheme Amperfy \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD_DIR/Amperfy.xcarchive" \
  -allowProvisioningUpdates=NO \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  archive 2>&1 | tail -5

if [[ ! -d "$BUILD_DIR/Amperfy.xcarchive" ]]; then
  fail "archive (xcarchive not found)"
fi
echo "Archive succeeded"

# ------------------------------------------------------------------
step "4/6 Export"

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/Amperfy.xcarchive" \
  -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR/export" \
  -allowProvisioningUpdates=NO 2>&1 | tail -3

if [[ ! -f "$BUILD_DIR/export/Amperfy.ipa" ]]; then
  fail "export (ipa not found)"
fi
echo "Export succeeded"

# ------------------------------------------------------------------
step "5/6 Upload to TestFlight"

UPLOAD_OUTPUT=$(xcrun altool --upload-app \
  -f "$BUILD_DIR/export/Amperfy.ipa" \
  -t ios \
  --apiKey "$APPSTORE_KEY_ID" \
  --apiIssuer "$APPSTORE_ISSUER_ID" 2>&1)

echo "$UPLOAD_OUTPUT"

if ! echo "$UPLOAD_OUTPUT" | grep -q 'UPLOAD SUCCEEDED'; then
  fail "upload"
fi

DELIVERY_UUID=$(echo "$UPLOAD_OUTPUT" | grep 'Delivery UUID:' | sed 's/.*Delivery UUID: //')

# ------------------------------------------------------------------
step "6/6 Summary"

COMMIT_SHA=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "Ship complete!"
echo "  Version:      $NEW_VERSION"
echo "  Delivery UUID: $DELIVERY_UUID"
echo "  Commit:       $COMMIT_SHA"
echo ""
echo "Paste into BACKLOG.md §6 and testflight-pipeline.md:"
echo "  CURRENT_PROJECT_VERSION=$NEW_VERSION, delivered $(date +%Y-%m-%d): \`$DELIVERY_UUID\`."
