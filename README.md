# ThreadProfilerBenchmark

A small SwiftUI app for measuring the performance impact of a sampling thread profiler.

The same animation, drawing, scrolling, and catalog-update workload runs twice: once without profiling and once with a sample every 50 ms. Each arm warms up for 2 seconds and measures for 10 seconds, with a 1-second cooldown between arms.

The native sampler suspends all other enumerated threads, captures up to 64 frame-pointer-based stack addresses per thread, and resumes them. One preallocated capture buffer is reused across samples. Only pause timings are retained, with no stack export or symbolication. The suspension window avoids heap allocation and Swift/Objective-C calls.

## Run

Use Xcode 27.2 and install the command-line dependencies:

```sh
brew install just jq
```

Run one target or all three:

```sh
just benchmark macos
just benchmark simulator
just --set device "Your iPhone" benchmark device
just benchmark
```

The simulator target uses the single booted iPhone by default. To select a simulator explicitly:

```sh
just --set simulator "<simulator-UDID>" benchmark simulator
```

Physical-device runs require a connected, unlocked iPhone with Developer Mode enabled and local signing configured in Xcode. Open `ThreadProfilerBenchmark.xcodeproj` to configure signing or run the app interactively.

Results and build logs are saved under `.build/results/`.

**Local benchmarks can use substantial CPU.** Simulator runs boot the selected simulator and leave it running. Shut it down afterward with `xcrun simctl shutdown "<simulator-UDID>"`. Use GitHub Actions to avoid running benchmarks on your own Mac.

## Results

Each report compares process CPU time, main-thread update throughput, and timer callback gaps. Both arms use the same workload timer.

Profiler reports include sample counts, capture failures, and the mean, median, p95, p99, and maximum suspend/capture/resume window in microseconds and milliseconds. Mean suspension-call, stack-capture, and resumption-call costs are reported separately. Threads are suspended and resumed sequentially, so the complete window is not each individual thread's exact pause duration.

One ordered A/B pair is exploratory, not a statistically significant overhead estimate. Timer callback gaps measure responsiveness, not authoritative frame-presentation timing.

## GitHub Actions

Pushes, pull requests, and manual workflow dispatches run the macOS and iPhone Simulator benchmarks on GitHub-hosted macOS runners. Each target publishes:

- A commit-linked check notice with CPU and pause-duration results.
- A job summary containing the full report.
- An artifact containing reports, build logs, and runner environment details.

CI uses ad-hoc signing and does not require Apple credentials. Physical iPhone runs are local only.
