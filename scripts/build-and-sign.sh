#!/bin/bash
# Build Dictator and re-sign with a stable designated requirement.
#
# Xcode's built-in CodeSign step runs AFTER custom build script phases,
# so a postBuildScript cannot apply a stable requirement — Xcode overwrites
# it. This wrapper builds the app, then re-signs the output bundle with a
# designated requirement based on the bundle identifier instead of the
# default cdhash.
#
# Why: macOS TCC identifies apps by their designated requirement. For ad-hoc
# signed apps, the default DR is `cdhash H"..."` which changes every rebuild.
# TCC then sees each rebuild as a new app and revokes microphone permission.
# Setting `designated => identifier "ai.dictator.app"` makes TCC identify
# the app by its stable bundle identifier, so mic permission persists.
#
# Usage:
#   scripts/build-and-sign.sh           # build + re-sign
#   scripts/build-and-sign.sh --deploy  # build + re-sign + copy to /Applications
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCHEME="Dictator"
CONFIGURATION="Debug"
BUNDLE_ID="ai.dictator.app"
ENTITLEMENTS="$REPO_ROOT/Sources/DictatorApp/Dictator.entitlements"

DEPLOY=false
if [[ "${1:-}" == "--deploy" ]]; then
  DEPLOY=true
fi

echo "==> Building Dictator ($CONFIGURATION)..."
xcodebuild \
  -project "$REPO_ROOT/Dictator.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  build 2>&1 | tail -5

# Locate the built app in DerivedData.
DERIVED_DATA=$(xcodebuild \
  -project "$REPO_ROOT/Dictator.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/CONFIGURATION_BUILD_DIR/ { print $2; exit }')

APP_PATH="$DERIVED_DATA/Dictator.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: built app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Re-signing with stable designated requirement (identifier \"$BUNDLE_ID\")..."

# Write the designated requirement to a temp file.
REQ_FILE=$(mktemp)
trap 'rm -f "$REQ_FILE"' EXIT
printf 'designated => identifier "%s"\n' "$BUNDLE_ID" > "$REQ_FILE"

codesign \
  --force \
  --sign - \
  --identifier "$BUNDLE_ID" \
  --requirements "$REQ_FILE" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP_PATH"

# Verify the designated requirement is stable (not cdhash).
DR=$(codesign -d -r- "$APP_PATH" 2>&1 | grep "designated" || true)
echo "==> $DR"

if [[ "$DR" == *"cdhash"* ]]; then
  echo "ERROR: designated requirement is still cdhash-based — TCC will not retain permission" >&2
  exit 1
fi

echo "==> Build + sign complete: $APP_PATH"

if $DEPLOY; then
  echo "==> Deploying to /Applications..."
  pkill -x Dictator 2>/dev/null || true
  sleep 1
  tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "/Applications/Dictator.app"
  cp -R "$APP_PATH" "/Applications/Dictator.app"
  echo "==> Deployed. Launching..."
  open "/Applications/Dictator.app"
  echo "==> Done. Trigger a dictation — you should get a fresh mic permission popup."
  echo "==> After granting, TCC will retain the permission across future rebuilds."
fi
