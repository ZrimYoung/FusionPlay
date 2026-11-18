#!/bin/bash
source "$(dirname "$0")/env.sh"

kind="${1:-simulator}"
case "$kind" in
    simulator) destination='generic/platform=iOS Simulator' ;;
    device) destination='generic/platform=iOS' ;;
    *) printf 'Usage: %s [simulator|device]\n' "$0" >&2; exit 2 ;;
esac

bash "$IOS_DIR/scripts/prepare.sh" "$kind"
output="$IOS_PROJECT_ROOT/artifacts/ios-$kind"
mkdir -p "$output"
xcodebuild -project "$IOS_DIR/FusionPlay.xcodeproj" -scheme FusionPlay \
    -configuration Release -destination "$destination" \
    -derivedDataPath "$IOS_BUILD/derived-$kind" \
    -clonedSourcePackagesDirPath "$IOS_BUILD/packages" \
    CONFIGURATION_BUILD_DIR="$output" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
printf '%s\n' "$output/FusionPlay.app"
