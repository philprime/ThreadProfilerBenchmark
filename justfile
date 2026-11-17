destination := "platform=macOS"
scheme := "ThreadProfilerBenchmark"
build_directory := ".build"
simulator := "booted"
device := "iPhone Sentry"

build configuration="Release":
    xcodebuild build -project {{ scheme }}.xcodeproj -scheme {{ scheme }} -configuration {{ configuration }} -destination '{{ destination }}' -derivedDataPath {{ build_directory }}

benchmark target="all":
    bash scripts/benchmark.sh {{ quote(target) }} {{ quote(scheme) }} {{ quote(build_directory) }} {{ quote(simulator) }} {{ quote(device) }}
