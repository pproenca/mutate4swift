#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
DIST="$ROOT/dist/mutate4swift"
TARBALL="$ROOT/dist/mutate4swift-macos-arm64.tar.gz"

echo "Building release..."
cd "$ROOT"
swift build -c release 2>&1

echo "Packaging..."
rm -rf "$DIST" "$TARBALL"
mkdir -p "$DIST"

# Copy binary
cp .build/release/mutate4swift "$DIST/mutate4swift"

# Strip debug symbols for smaller size
strip -x "$DIST/mutate4swift" 2>/dev/null || true

# Ad-hoc codesign (required on Apple Silicon)
codesign --force --sign - "$DIST/mutate4swift" 2>/dev/null || true

# Create tarball for GitHub releases
cd "$ROOT/dist"
tar -czf mutate4swift-macos-arm64.tar.gz mutate4swift/

echo ""
echo "Distribution:"
ls -lh "$DIST/mutate4swift"
echo ""
echo "Tarball:"
ls -lh "$TARBALL"
