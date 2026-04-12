#!/usr/bin/env bash
# bump-version.sh — bump CURRENT_PROJECT_VERSION in Amperfy's pbxproj.
#
# Usage:
#   scripts/bump-version.sh <new-version>
#   scripts/bump-version.sh --help
#
# Example:
#   scripts/bump-version.sh 8

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$PROJECT_DIR/Amperfy.xcodeproj/project.pbxproj"

usage() {
  echo "Usage: $0 <new-version-number>"
  echo ""
  echo "Bumps CURRENT_PROJECT_VERSION across all build configs in:"
  echo "  $PBXPROJ"
  echo ""
  echo "Example: $0 8"
  exit "${1:-0}"
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage 0
[[ $# -ne 1 ]] && { echo "Error: expected exactly one argument (new version number)"; usage 1; }

NEW_VERSION="$1"

if ! [[ "$NEW_VERSION" =~ ^[0-9]+$ ]]; then
  echo "Error: version must be a positive integer, got '$NEW_VERSION'"
  exit 1
fi

if [[ ! -f "$PBXPROJ" ]]; then
  echo "Error: pbxproj not found at $PBXPROJ"
  exit 1
fi

# Find current version (first occurrence)
CURRENT_VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed 's/.*= \([0-9]*\);/\1/')

if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Error: could not find CURRENT_PROJECT_VERSION in pbxproj"
  exit 1
fi

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  echo "Already at version $NEW_VERSION — nothing to do."
  exit 0
fi

COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $CURRENT_VERSION;" "$PBXPROJ")
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_VERSION;/CURRENT_PROJECT_VERSION = $NEW_VERSION;/g" "$PBXPROJ"

VERIFY_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $NEW_VERSION;" "$PBXPROJ")
if [[ "$VERIFY_COUNT" -ne "$COUNT" ]]; then
  echo "Error: expected $COUNT replacements but found $VERIFY_COUNT after sed"
  exit 1
fi

echo "Bumped CURRENT_PROJECT_VERSION: $CURRENT_VERSION → $NEW_VERSION ($COUNT occurrences)"
