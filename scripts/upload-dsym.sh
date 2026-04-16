#!/usr/bin/env bash
set -euo pipefail

# Upload term-mesh dSYM debug symbols to Sentry.
#
# Usage:
#   ./scripts/upload-dsym.sh                        # auto-find latest Release dSYM in DerivedData
#   ./scripts/upload-dsym.sh /path/to/term-mesh.app.dSYM
#   ./scripts/upload-dsym.sh --build                # xcodebuild Release then upload
#
# Requirements:
#   - sentry-cli installed (brew install getsentry/tools/sentry-cli)
#   - ~/.sentryclirc with [auth] token= and project .sentryclirc with [defaults]

PROJECT_FILE="GhosttyTabs.xcodeproj/project.pbxproj"

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "Error: sentry-cli not installed. Run: brew install getsentry/tools/sentry-cli" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Error: $PROJECT_FILE not found. Run from repo root." >&2
  exit 1
fi

MARKETING=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')
echo "Project version: $MARKETING ($BUILD)"

DSYM_PATH=""
DO_BUILD=0

case "${1:-}" in
  --build)
    DO_BUILD=1
    ;;
  "")
    ;;
  *)
    DSYM_PATH="$1"
    ;;
esac

if [[ "$DO_BUILD" == "1" ]]; then
  echo "Building Release configuration..."
  xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh \
    -configuration Release -destination 'platform=macOS' build >/dev/null
fi

if [[ -z "$DSYM_PATH" ]]; then
  # Auto-find latest Release dSYM by modification time.
  DSYM_PATH="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path "*GhosttyTabs-*/Build/Products/Release/term-mesh.app.dSYM" \
      -maxdepth 8 -type d 2>/dev/null \
      | xargs -I {} stat -f "%m %N" {} 2>/dev/null \
      | sort -rn \
      | head -1 \
      | cut -d' ' -f2-
  )"
fi

if [[ -z "$DSYM_PATH" || ! -d "$DSYM_PATH" ]]; then
  echo "Error: dSYM not found. Build Release first (./scripts/upload-dsym.sh --build)." >&2
  exit 1
fi

# Verify binary version embedded in the adjacent .app matches project version.
APP_DIR="$(dirname "$DSYM_PATH")/term-mesh.app"
if [[ -d "$APP_DIR" ]]; then
  EMBEDDED_MARKETING="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  EMBEDDED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
  echo "dSYM path:       $DSYM_PATH"
  echo "dSYM version:    $EMBEDDED_MARKETING ($EMBEDDED_BUILD)"
  if [[ -n "$EMBEDDED_MARKETING" && "$EMBEDDED_MARKETING" != "$MARKETING" ]]; then
    echo "Warning: dSYM version ($EMBEDDED_MARKETING) differs from project version ($MARKETING)." >&2
    echo "         Run with --build to produce a fresh Release dSYM." >&2
  fi
fi

echo "Uploading dSYM to Sentry..."
sentry-cli debug-files upload --include-sources "$DSYM_PATH"
echo "Upload complete."
