#!/bin/bash
# Archive the iOS and/or Mac app and upload to App Store Connect
# (TestFlight). Both binaries share the bundle ID chat.matron.app, so
# they land on ONE App Store Connect record (universal purchase).
#
# Usage:
#   scripts/testflight-upload.sh ios|mac|all
#
# Auth (choose one):
#   - App Store Connect API key (preferred, works headless):
#       ASC_KEY_ID=ABC123 ASC_ISSUER_ID=xxxx-... ASC_KEY_PATH=~/keys/AuthKey_ABC123.p8 \
#         scripts/testflight-upload.sh all
#   - No env vars: falls back to Xcode's stored Apple ID account, if any;
#     otherwise the export step fails with an auth error and the
#     .xcarchive in build/ can be uploaded manually via Xcode Organizer.
#
# Versioning: MARKETING_VERSION comes from project.yml; the build number
# (CURRENT_PROJECT_VERSION) is overridden here with `git rev-list --count
# HEAD` so every commit yields a unique, monotonically increasing build
# number — App Store Connect rejects re-uploads of a (version, build)
# pair it has already seen.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGETS="${1:-all}"
case "$TARGETS" in ios|mac|all) ;; *) echo "usage: $0 ios|mac|all" >&2; exit 64 ;; esac

# The two generated Info.plists are expected to be locally dirty
# (xcodegen regenerates them); anything else dirty is worth a warning.
if [[ -n "$(git status --porcelain | grep -v 'App/Info\.plist$' || true)" ]]; then
  echo "warning: working tree is dirty — the build number is derived from" >&2
  echo "committed history and won't reflect uncommitted changes." >&2
fi

BUILD_NUM="$(git rev-list --count HEAD)"
echo "==> build number: $BUILD_NUM ($(git rev-parse --short HEAD))"

xcodegen generate

AUTH_ARGS=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH_ARGS=(-authenticationKeyID "$ASC_KEY_ID"
             -authenticationKeyIssuerID "$ASC_ISSUER_ID"
             -authenticationKeyPath "$ASC_KEY_PATH")
  echo "==> uploading with App Store Connect API key $ASC_KEY_ID"
else
  echo "==> no ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH set — relying on Xcode's stored account"
fi

EXPORT_PLIST="build/export-options.plist"
mkdir -p build
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>4LJ7WRRRFD</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

ship() { # scheme, destination, archive path
  local scheme="$1" dest="$2" archive="build/$1.xcarchive"
  echo "==> archiving $scheme"
  xcodebuild archive \
    -scheme "$scheme" \
    -destination "$dest" \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
  echo "==> uploading $scheme archive"
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}
  echo "==> $scheme uploaded (build $BUILD_NUM) — it appears in TestFlight after App Store Connect finishes processing"
}

[[ "$TARGETS" == "ios" || "$TARGETS" == "all" ]] && ship Matron    "generic/platform=iOS"
[[ "$TARGETS" == "mac" || "$TARGETS" == "all" ]] && ship MatronMac "generic/platform=macOS"

echo "==> done"
