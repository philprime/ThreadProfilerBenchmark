#!/usr/bin/env bash
set -euo pipefail

target=$1
selected=$2
metadata=$3

hardware=$(system_profiler SPHardwareDataType -json | jq -c '.SPHardwareDataType[0] | {
    model: .machine_name, identifier: .machine_model, chip: .chip_type
}')
host=$(jq -n \
    --argjson hardware "$hardware" \
    --arg architecture "$(uname -m)" \
    --arg version "$(sw_vers -productVersion)" \
    --arg build "$(sw_vers -buildVersion)" \
    --argjson memory "$(sysctl -n hw.memsize)" \
    --argjson physicalCores "$(sysctl -n hw.physicalcpu)" \
    --argjson logicalCores "$(sysctl -n hw.logicalcpu)" '
    $hardware + {architecture: $architecture, memoryBytes: $memory,
        physicalCores: $physicalCores, logicalCores: $logicalCores,
        os: {name: "macOS", version: $version, build: $build}}
')

case "$target" in
    macos)
        device="$host"
        sdk=macosx
        ;;
    simulator)
        sdk=iphonesimulator
        device=$(jq -n \
            --slurpfile devices "$metadata/simulators.json" \
            --slurpfile runtimes "$metadata/runtimes.json" --arg selected "$selected" '
            first($devices[0].devices | to_entries[] | .key as $runtime | .value[]
                | select(.udid == $selected)
                | {model: .name, type: .deviceTypeIdentifier, runtime: $runtime}) as $device
            | first($runtimes[0].runtimes[] | select(.identifier == $device.runtime)) as $runtime
            | $device + {os: {name: $runtime.name, version: $runtime.version, build: $runtime.buildversion}}
        ')
        ;;
    device)
        sdk=iphoneos
        device=$(jq --arg selected "$selected" '
            first(.result.devices[] | select(.hardwareProperties.udid == $selected))
            | {model: .hardwareProperties.marketingName, identifier: .hardwareProperties.productType,
                board: .hardwareProperties.hardwareModel, architecture: .hardwareProperties.cpuType.name,
                storageBytes: .hardwareProperties.internalStorageCapacity,
                os: {name: "iOS", version: .deviceProperties.osVersionNumber, build: .deviceProperties.osBuildUpdate},
                developerMode: .deviceProperties.developerModeStatus,
                connection: .connectionProperties.transportType}
        ' "$metadata/devices.json")
        ;;
    *) echo "Unknown target: $target" >&2; exit 64 ;;
esac

jq -n \
    --arg platform "$target" --arg capturedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg timing "${PROFILE_TIMING:-before measurement}" \
    --arg xcode "$(xcodebuild -version)" \
    --arg sdk "$sdk" --arg sdkVersion "$(xcrun --sdk "$sdk" --show-sdk-version)" \
    --argjson device "$device" --argjson host "$host" '
    {platform: $platform, capturedAt: $capturedAt, captureTiming: $timing,
        xcode: $xcode, sdk: {name: $sdk, version: $sdkVersion}, device: $device}
    + if $platform == "macos" then {} else {host: $host} end
'
