#!/usr/bin/env bash
# distribute.sh testflight-ios | testflight-macos | developer-id
# Builds the sample app the way a store or direct download would ship it, to check that Pushwren
# reports the production APNs environment for distribution-signed builds.
# - testflight-ios / testflight-macos: archive and upload to App Store Connect (an app with bundle
#   ID com.pushwren.sample must exist there). TestFlight builds are the same binaries the App
#   Store and Mac App Store ship.
# - developer-id: archive and export a Developer ID-signed Mac app to build/developer-id/.
# Signing is Xcode's automatic signing with the account signed in to Xcode; the Team ID comes from
# Local.xcconfig. Each upload gets a new build number (UTC time) unless BUILD_NUMBER is set.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
kind=${1:-}
case $kind in
  testflight-ios) scheme=PushwrenSample-iOS destination='generic/platform=iOS' method=app-store-connect target=upload ;;
  testflight-macos) scheme=PushwrenSample-macOS destination='generic/platform=macOS' method=app-store-connect target=upload ;;
  developer-id) scheme=PushwrenSample-macOS destination='generic/platform=macOS' method=developer-id target=export ;;
  *) echo "usage: distribute.sh testflight-ios | testflight-macos | developer-id" >&2; exit 2 ;;
esac
[ -f Local.xcconfig ] || { echo "Local.xcconfig is missing: copy Local.xcconfig.example" >&2; exit 2; }
team=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\) *$/\1/p' Local.xcconfig)
[ -n "$team" ] || { echo "Local.xcconfig has no 10-character DEVELOPMENT_TEAM" >&2; exit 2; }
build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
out="build/$kind"
archive="$out/PushwrenSample.xcarchive"

xcodegen generate --quiet
rm -rf "$out"
mkdir -p "$out"
echo "== archiving $scheme, build $build_number"
xcodebuild archive -project PushwrenSample.xcodeproj -scheme "$scheme" -configuration Release \
  -destination "$destination" -archivePath "$archive" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build_number" -quiet

cat >"$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$method</string>
	<key>destination</key>
	<string>$target</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
echo "== exporting ($method, $target)"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" -allowProvisioningUpdates -quiet
if [ "$target" = upload ]; then
  echo "== uploaded build $build_number; TestFlight shows it once processed (usually 10-30 minutes)"
else
  echo "== exported to $out/export"
fi
