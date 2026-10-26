#!/usr/bin/env bash
# Build, install and run the minimal repro on a physical device, then pull the log.
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 ./run_repro.sh <device> [repro|control|both] [extra args...]
#
# Examples:
#   ./run_repro.sh "$UDID"                     # repro
#   ./run_repro.sh "$UDID" both                # control first, then repro (two cold launches)
#   ./run_repro.sh "$UDID" repro opts237       # game SDK option set
#
# Preconditions:
#   - AirPods connected, Spatial Audio + Head Tracking enabled in Settings
#   - device connected, unlocked and trusting this Mac (xcrun devicectl list devices)
#   - microphone permission granted once (the first launch shows a prompt)

set -euo pipefail

DEVICE="${1:-}"
MODE="${2:-repro}"
shift || true
shift || true

[ -n "$DEVICE" ] || { echo "usage: DEVELOPMENT_TEAM=... $0 <device-udid-or-name> [repro|control|both] [args...]" >&2; exit 2; }
EXTRA_ARGS=("$@")

BUNDLE="com.example.SpatialAudioStallRepro"
TEAM="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple Developer team id}"
WAIT_SECONDS="${WAIT_SECONDS:-75}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/stallrepro-derived}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT_DIR"

build_and_install() {
    echo "== build ($PROJECT_DIR)"
    xcodebuild \
        -project "$PROJECT_DIR/SpatialAudioStallRepro.xcodeproj" \
        -scheme SpatialAudioStallRepro \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM" \
        -allowProvisioningUpdates \
        build

    echo "== install -> $DEVICE"
    xcrun devicectl device install app --device "$DEVICE" \
        "$DERIVED_DATA/Build/Products/Debug-iphoneos/SpatialAudioStallRepro.app"
}

run_mode() {
    local mode="$1"
    local log="$OUT_DIR/stall_repro_${mode}$(printf '_%s' "${EXTRA_ARGS[@]:-}" | tr ' ' '_').log"

    echo "== launch auto-$mode ${EXTRA_ARGS[*]:-}"
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
        "$BUNDLE" "auto-$mode" "${EXTRA_ARGS[@]:-}"

    echo "== waiting ${WAIT_SECONDS}s"
    sleep "$WAIT_SECONDS"

    echo "== pull log -> $log"
    xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" \
        --source Documents/stall_repro.log \
        --destination "$log" >/dev/null

    echo "== result ($mode)"
    awk -v mode="mode=$mode" '
        /^\[.*\] ===== RUN / { block = "" ; keep = 0 }
        /^\[.*\] ===== RUN mode=/ { if (index($0, mode) > 0) keep = 1 }
        keep { block = block $0 "\n" }
        END { printf "%s", block }
    ' "$log" | grep -E "ENV |STEP |SUMMARY |IMPACT |CAPTURE start|RUN DONE" || true
    echo "== log: $log"
}

build_and_install

case "$MODE" in
    repro|control) run_mode "$MODE" ;;
    both)
        run_mode control
        run_mode repro
        ;;
    *)
        echo "unknown mode: $MODE (expected repro|control|both)" >&2
        exit 2
        ;;
esac
