#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fusionplay-typography.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$CHECK_DIR/modules" \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Tests/TypographySmoke.swift" \
  -o "$CHECK_DIR/typography-smoke"
"$CHECK_DIR/typography-smoke"
