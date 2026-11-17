#!/usr/bin/env bash
set -euo pipefail

target=$1
scheme=$2
build_root=$3
simulator=$4
device=$5

case "$target" in
    all)
        status=0
        for platform in macos simulator device; do
            if bash "$0" "$platform" "$scheme" "$build_root" "$simulator" "$device"; then
                :
            else
                status=1
            fi
        done
        exit "$status"
        ;;
    macos|simulator|device) ;;
    *)
        echo "Usage: just benchmark [all|macos|simulator|device]" >&2
        exit 64
        ;;
esac

results="$build_root/results"
build_directory="$build_root/$target"
mkdir -p "$results"

case "$target" in
    macos)
        destination="platform=macOS"
        app="$build_directory/Build/Products/Release/$scheme.app"
        echo "=== macOS ==="
        ;;
    simulator)
        xcrun simctl list devices available --json > "$results/simulators.json"
        simulator=$(jq -er --arg selected "$simulator" '
            [.devices[][]
                | select(.deviceTypeIdentifier | contains(".iPhone-"))
                | select(if $selected == "booted" then .state == "Booted"
                    else .udid == $selected end)]
            | if length == 1 then .[0].udid
                else error("Select one iPhone Simulator using just --set simulator <UDID> benchmark simulator, or boot one iPhone.") end
        ' "$results/simulators.json")
        destination="platform=iOS Simulator,id=$simulator"
        app="$build_directory/Build/Products/Release-iphonesimulator/$scheme.app"
        echo "=== iPhone Simulator ($simulator) ==="
        xcrun simctl bootstatus "$simulator" -b
        open -a Simulator --args -CurrentDeviceUDID "$simulator"
        ;;
    device)
        xcrun devicectl list devices --json-output "$results/devices.json" --quiet
        device=$(jq -er --arg selected "$device" '
            [.result.devices[]
                | select(.hardwareProperties.reality == "physical")
                | select(.hardwareProperties.deviceType == "iPhone")
                | select(.deviceProperties.name == $selected
                    or .identifier == $selected or .hardwareProperties.udid == $selected)]
            | if length == 1 then .[0].hardwareProperties.udid
                else error("Select one connected iPhone using just --set device <name-or-UDID> benchmark device.") end
        ' "$results/devices.json")
        destination="platform=iOS,id=$device"
        app="$build_directory/Build/Products/Release-iphoneos/$scheme.app"
        echo "=== iPhone Physical Device ($device) ==="
        ;;
esac

build_log="$results/$target-build.log"
if just --set scheme "$scheme" --set destination "$destination" --set build_directory "$build_directory" build Release > "$build_log" 2>&1; then
    echo "Release build complete. Build log: $build_log"
else
    status=$?
    tail -n 80 "$build_log" >&2
    echo "Build failed. Full log: $build_log" >&2
    exit "$status"
fi

log="$results/$target.log"
case "$target" in
    macos)
        "$app/Contents/MacOS/$scheme" --benchmark 2>&1 | tee "$log"
        ;;
    simulator)
        bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
        xcrun simctl install "$simulator" "$app"
        xcrun simctl launch --console "$simulator" "$bundle_id" --benchmark 2>&1 | tee "$log"
        ;;
    device)
        bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
        xcrun devicectl device install app --device "$device" "$app"
        xcrun devicectl device process launch --device "$device" --console --timeout 120 "$bundle_id" -- --benchmark 2>&1 | tee "$log"
        ;;
esac

# The launch tools' own exit code does not consistently represent the app's exit code.
if ! grep -Fq 'BENCHMARK_STATUS: PASS' "$log"; then
    echo "Benchmark did not finish successfully. See $log" >&2
    exit 1
fi
echo "Results saved to $log"
