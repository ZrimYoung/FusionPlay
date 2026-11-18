#!/bin/bash
source "$(dirname "$0")/env.sh"
cd "$REPO"

case "${1:-all}" in
    all) targets=(aarch64-apple-ios aarch64-apple-ios-sim) ;;
    device) targets=(aarch64-apple-ios) ;;
    simulator) targets=(aarch64-apple-ios-sim) ;;
    *) printf 'Usage: %s [all|device|simulator]\n' "$0" >&2; exit 2 ;;
esac

for target in "${targets[@]}"; do
    target_libdir="$(rustc --print target-libdir --target "$target")"
    if [[ ! -d "$target_libdir" ]]; then
        printf 'Missing Rust target %s. Run rustup target add %s, then retry.\n' "$target" "$target" >&2
        exit 1
    fi
done

bindings="$IOS_BUILD/generated"
link="$IOS_DIR/.generated"
mkdir -p "$bindings"
if [[ ! -e "$link" && ! -L "$link" ]]; then
    ln -s "$bindings" "$link"
elif [[ ! -L "$link" || "$(readlink "$link")" != "$bindings" ]]; then
    printf '%s should link to %s. Move the existing item before rebuilding.\n' "$link" "$bindings" >&2
    exit 1
fi

host_manifest="$REPO/src/FusionPlay.Host/Cargo.toml"
# The generator runs on macOS, but reads the iOS archive below so the Swift
# module only imports symbols present on its respective target.
cargo build --locked --release --manifest-path "$host_manifest" --bin fusionplay-bindgen

for target in "${targets[@]}"; do
    case "$target" in
        aarch64-apple-ios) sdk=iphoneos ;;
        aarch64-apple-ios-sim) sdk=iphonesimulator ;;
    esac
    SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
        cargo rustc --locked --release --manifest-path "$host_manifest" --lib --target "$target" --crate-type staticlib
    mkdir -p "$bindings/$sdk"
    cp "$CARGO_TARGET_DIR/$target/release/libfusionplay_host.a" "$bindings/$sdk/libfusionplay_host.a"
done

(
    cd "$REPO/src/FusionPlay.Host"
    "$CARGO_TARGET_DIR/release/fusionplay-bindgen" generate \
        --library "$CARGO_TARGET_DIR/${targets[0]}/release/libfusionplay_host.a" \
        --language swift --config uniffi.toml --no-format --out-dir "$bindings"
)
cp "$bindings/FusionPlayBridgeFFI.modulemap" "$bindings/module.modulemap"

# Reuse FusionPlay's existing opaque source icon so each target uses the same
# artwork. Asset catalog compilation generates the device-specific sizes.
icons="$bindings/Assets.xcassets"
mkdir -p "$icons/AppIcon.appiconset"
cp "$IOS_DIR/Resources/Assets.xcassets/Contents.json" "$icons/Contents.json"
cp "$IOS_DIR/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" "$icons/AppIcon.appiconset/Contents.json"
sips -z 1024 1024 "$REPO/macos/Resources/AppIcon.png" \
    --out "$icons/AppIcon.appiconset/AppIcon.png" >/dev/null
