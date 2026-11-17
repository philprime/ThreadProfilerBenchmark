# ThreadProfilerBenchmark

A small SwiftUI app for measuring the performance impact of a sampling thread profiler.

Each platform runs five baseline/profiled pairs of the same animation, drawing, scrolling, and catalog-update workload. Each arm warms up for 2 seconds and measures for 10 seconds, with a 1-second cooldown between arms. Sampling every 50 ms produces approximately 200 samples per trial and 1,000 per platform. Allow about two minutes per platform.

The native sampler suspends all other enumerated threads, captures up to 64 frame-pointer-based stack addresses per thread, and resumes them. One preallocated capture buffer is reused across samples. Only pause timings are retained, with no stack export or symbolication. The suspension window avoids heap allocation and Swift/Objective-C calls.

## Run

Use Xcode 27.2 and install the command-line dependencies:

```sh
brew bundle
```

Run all three with no flags:

```sh
just benchmark
```

This automatically selects and boots iPhone 18 Pro on the installed SDK's runtime and uses iPhone Sentry for the physical-device case. That iPhone must be connected and unlocked.

Individual targets can also be selected:

```sh
just benchmark macos
just benchmark simulator
just benchmark device
```

To select a simulator explicitly:

```sh
just --set simulator "<simulator-UDID>" benchmark simulator
```

Physical-device runs require a connected, unlocked iPhone with Developer Mode enabled and local signing configured in Xcode. Open `ThreadProfilerBenchmark.xcodeproj` to configure signing or run the app interactively.

Results, build logs, and device profiles are saved under `Results/`.

**Local benchmarks can use substantial CPU.** Simulator runs boot the selected simulator and leave it running. Shut it down afterward with `xcrun simctl shutdown "<simulator-UDID>"`. Use GitHub Actions to avoid running benchmarks on your own Mac.

## Results

### Recorded overview

CPU is percent of one core. Change is relative to baseline. Pause values are microseconds.

| Platform                                  | Samples | Baseline CPU | Profiled CPU | Change | Median pause | p95 pause |
| ----------------------------------------- | ------: | -----------: | -----------: | -----: | -----------: | --------: |
| [macOS](Results/macos.log)                |   1,000 |      24.632% |      24.621% | −0.04% |       67.125 |   132.708 |
| [iPhone Simulator](Results/simulator.log) |     999 |      28.038% |      26.092% | −6.94% |       29.792 |    66.750 |
| [iPhone Sentry](Results/device.log)       |   1,000 |      35.822% |      35.800% | −0.06% |       91.083 |   242.625 |

All 15 pairs passed with zero capture failures. The large Simulator variation, particularly its first trial, makes its CPU difference inconclusive.

| Platform  | Configuration                                  | OS/build          | Profile                                |
| --------- | ---------------------------------------------- | ----------------- | -------------------------------------- |
| macOS     | MacBook Pro `Mac16,5`, M4 Max, 14 cores, 36 GB | 27.2.1 / `26B131` | [JSON](Results/macos-profile.json)     |
| Simulator | iPhone 18 Pro, hosted on the same Mac          | 27.2 / `24B8117`  | [JSON](Results/simulator-profile.json) |
| iPhone    | iPhone 14 `iPhone14,7`, arm64e, 128 GB, wired  | 26.7.3 / `23H131` | [JSON](Results/device-profile.json)    |

Build evidence: [macOS](Results/macos-build.log), [Simulator](Results/simulator-build.log), [iPhone](Results/device-build.log).

These profiles were collected after measurement, with saved device metadata. They do not establish the power or thermal state during the run. Future runs capture profiles before measurement. Unique identifiers are excluded from profiles; raw logs are preserved unchanged.

### Interpretation

Each report aggregates the five pairs. CPU usage and update throughput use total work divided by total measurement time. Timer-gap and pause percentiles use all individual observations, rather than averages of per-trial percentiles. Reports include each trial's CPU usage and sample count, plus the mean and sample standard deviation of the paired CPU changes. Both arms use the same workload timer.

Profiler reports include sample counts, capture failures, and the mean, median, p95, p99, and maximum suspend/capture/resume window in microseconds and milliseconds. Mean suspension-call, stack-capture, and resumption-call costs are reported separately. Threads are suspended and resumed sequentially, so the complete window is not each individual thread's exact pause duration.

Five ordered pairs reduce noise but do not establish statistical significance. Timer callback gaps measure responsiveness, not authoritative frame-presentation timing.

## GitHub Actions

Pushes, pull requests, and manual workflow dispatches run the macOS and iPhone Simulator benchmarks on GitHub-hosted macOS runners. Each target publishes:

- A commit-linked check notice with CPU and pause-duration results.
- A job summary containing the full report.
- An artifact containing reports, build logs, and runner environment details.

CI uses ad-hoc signing and does not require Apple credentials. Each run writes to a fresh subdirectory under `Results/`, so it cannot publish the checked-in snapshot as a new result. Physical iPhone runs are local only.
