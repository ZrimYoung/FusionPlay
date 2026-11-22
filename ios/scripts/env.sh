#!/bin/bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(dirname "$IOS_DIR")"
IOS_PROJECT_ROOT="${FUSIONPLAY_IOS_PROJECT_ROOT:-$(dirname "$REPO")}"
mkdir -p "$IOS_PROJECT_ROOT"
IOS_PROJECT_ROOT="$(cd "$IOS_PROJECT_ROOT" && pwd)"
IOS_BUILD="$IOS_PROJECT_ROOT/build/ios"
mkdir -p "$IOS_BUILD" "$IOS_PROJECT_ROOT/cache" "$IOS_PROJECT_ROOT/artifacts"

# Use an existing Rust installation when available. The adjacent FusionPlay
# project may have a shared toolchain, while receiver build caches stay local.
if ! command -v cargo >/dev/null 2>&1; then
    shared_rust="$(dirname "$IOS_PROJECT_ROOT")/FusionPlay/tools/rust"
    if [[ -x "$shared_rust/cargo/bin/rustup" ]]; then
        export RUSTUP_HOME="${RUSTUP_HOME:-$shared_rust/rustup}"
        export PATH="$shared_rust/cargo/bin:$PATH"
    fi
fi
if ! command -v cargo >/dev/null 2>&1; then
    printf 'Rust is required. Install the stable toolchain via rustup and put cargo on PATH.\n' >&2
    exit 1
fi

export CARGO_HOME="$IOS_PROJECT_ROOT/cache/cargo"
export CARGO_TARGET_DIR="$IOS_PROJECT_ROOT/build/rust"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR"
