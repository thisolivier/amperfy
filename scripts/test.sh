#!/usr/bin/env bash
# test.sh — run Amperfy's xcodebuild tests on the iOS simulator.
#
# Usage:
#   scripts/test.sh                    # run all AmperfyKitTests
#   scripts/test.sh PlaylistMembershipQueryTest  # run one test class
#   scripts/test.sh --help

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Amperfy"
DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro"

usage() {
  echo "Usage: $0 [TestClassName]"
  echo ""
  echo "Runs xcodebuild test for the Amperfy scheme."
  echo "If a test class name is given, only that class runs."
  echo ""
  echo "Examples:"
  echo "  $0                              # all tests"
  echo "  $0 PlaylistMembershipQueryTest  # single class"
  exit "${1:-0}"
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage 0

ONLY_TESTING=""
if [[ $# -ge 1 ]]; then
  ONLY_TESTING="-only-testing:AmperfyKitTests/$1"
fi

echo "Running tests (scheme=$SCHEME)..."

# shellcheck disable=SC2086
xcodebuild test \
  -project "$PROJECT_DIR/Amperfy.xcodeproj" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  $ONLY_TESTING \
  2>&1 | tee /tmp/amperfy-test-output.log | tail -25

# Extract pass/fail summary
SUMMARY=$(grep -E 'Executed [0-9]+ tests?' /tmp/amperfy-test-output.log | tail -1)
if [[ -n "$SUMMARY" ]]; then
  echo ""
  echo "Summary: $SUMMARY"
fi

# Check for test failure
if grep -q '^\*\* TEST SUCCEEDED \*\*' /tmp/amperfy-test-output.log; then
  echo "Result: PASS"
  exit 0
else
  echo "Result: FAIL"
  exit 1
fi
