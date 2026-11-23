#!/bin/bash
source "$(dirname "$0")/env.sh"
CHECK_DIR="$(mktemp -d "$PROJECT/tmp/metadata-pipeline.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
export FUSIONPLAY_PROJECTED_METADATA_FIXTURE="$CHECK_DIR/events.json"
cargo test --offline --locked --manifest-path "$REPO/src/FusionPlay.MiPlaySdk/Cargo.toml" \
  projected_metadata_wire_pipeline_fixture -- --nocapture
[[ -s "$FUSIONPLAY_PROJECTED_METADATA_FIXTURE" ]]
cargo test --offline --locked --manifest-path "$REPO/src/FusionPlay.Host/Cargo.toml" \
  projected_metadata_pipeline_keeps_raw_fields_and_track_state -- --nocapture
printf 'PASS: actual MiPlay packet parser and source projection events consumed by Host reducer\n'
