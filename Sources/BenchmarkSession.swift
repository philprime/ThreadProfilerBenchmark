import Foundation
import Observation

struct BenchmarkItem: Identifiable {
    let id: Int
    let title: String
    let score: Int

    static func catalog(revision: Int) -> [Self] {
        (0..<240).map { index in
            Self(id: index, title: "Activity \(index + 1)", score: (index * 37 + revision * 11) % 101)
        }.sorted {
            $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
        }
    }
}

@MainActor
@Observable
final class BenchmarkSession {
    private(set) var isRunning = false
    private(set) var activityRunning = false
    private(set) var status = "Ready to compare baseline with 50 ms all-thread profiling."
    private(set) var report = ""
    private(set) var animationStart = Date.now
    private(set) var revision = 0
    private(set) var items = BenchmarkItem.catalog(revision: 0)

    @ObservationIgnored private var workTimer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private let metrics = BenchmarkMetrics()

    var scrollTarget: Int {
        let step = revision % 20
        let fraction = Double(step <= 10 ? step : 20 - step) / 10
        return items[Int(Double(items.count - 1) * fraction)].id
    }

    func runBenchmark() async -> Bool {
        guard !isRunning else { return false }
        guard let profiler = TPProfilerCreate() else {
            status = "Could not allocate profiler storage."
            print(status)
            return false
        }
        isRunning = true
        report = ""
        var measuring = false
        defer {
            if measuring { _ = metrics.finish() }
            stopActivity()
            TPProfilerDestroy(profiler)
            isRunning = false
        }

        do {
            var results: [BenchmarkResult] = []
            for profiling in [false, true] {
                let name = profiling ? "Profiler 50 ms" : "Baseline"
                status = "\(name): warming up for 2 seconds…"
                startActivity()
                try await Task.sleep(for: .seconds(2))
                if profiling, TPProfilerStart(profiler) != 0 {
                    status = "Could not start the sampling thread."
                    print(status)
                    return false
                }
                status = "\(name): measuring for 10 seconds…"
                metrics.start()
                measuring = true
                try await Task.sleep(for: .seconds(10))
                var result = metrics.finish()
                measuring = false
                stopActivity()
                // Joining the sampler happens outside the measurement window.
                result.profiler = TPProfilerStop(profiler)
                results.append(result)
                if !profiling {
                    status = "Baseline complete. Cooling down for 1 second…"
                    try await Task.sleep(for: .seconds(1))
                }
            }
            report = Self.format(results[0], results[1])
            print(report)
            let valid = results[1].profiler.samples > 0 && results[1].profiler.failures == 0
            status = valid ? "Comparison complete." : "Comparison invalid: profiler capture failed."
            return valid
        } catch {
            status = "Benchmark cancelled."
            return false
        }
    }

    private func startActivity() {
        revision = 0
        tickCount = 0
        items = BenchmarkItem.catalog(revision: 0)
        animationStart = .now
        activityRunning = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.metrics.tick()
                self.tickCount += 1
                if self.tickCount.isMultiple(of: 15) {
                    self.revision += 1
                    self.items = BenchmarkItem.catalog(revision: self.revision)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        workTimer = timer
    }

    private func stopActivity() {
        workTimer?.invalidate()
        workTimer = nil
        activityRunning = false
    }

    private static func format(_ baseline: BenchmarkResult, _ profiled: BenchmarkResult) -> String {
        func number(_ value: Double) -> String { String(format: "%.3f", value) }
        func row(_ name: String, _ a: Double, _ b: Double) -> String {
            "\(name.padding(toLength: 25, withPad: " ", startingAt: 0)) \(number(a)) -> \(number(b)) (Δ \(number(b - a)))"
        }
        func duration(_ seconds: Double) -> String {
            "\(number(seconds * 1_000_000)) µs (\(number(seconds * 1_000)) ms)"
        }
        #if os(macOS)
        let platform = "macOS"
        #elseif targetEnvironment(simulator)
        let platform = "iPhone Simulator"
        #else
        let platform = "iPhone Physical Device"
        #endif
        let stats = profiled.profiler
        let sampleCount = Double(max(1, stats.samples))
        return """
        THREAD PROFILER BENCHMARK (\(platform), Release, baseline -> profiler)
        Same animated/scrolling workload, 2 s warm-up + 10 s measurement per arm.
        CPU is process user + system time, all threads. CPU %: 100 = one core.
        \(row("Wall time (s)", baseline.wallSeconds, profiled.wallSeconds))
        \(row("Process CPU time (s)", baseline.cpuSeconds, profiled.cpuSeconds))
        \(row("Process CPU (%)", baseline.cpuPercent, profiled.cpuPercent))
        Relative CPU change: \(number((profiled.cpuPercent / baseline.cpuPercent - 1) * 100)) %
        \(row("Main updates / s", baseline.updatesPerSecond, profiled.updatesPerSecond))
        \(row("Tick gap p95 (ms)", baseline.tickGapPercentile(0.95), profiled.tickGapPercentile(0.95)))
        \(row("Tick gap max (ms)", baseline.tickGapPercentile(1), profiled.tickGapPercentile(1)))
        Samples: \(stats.samples), thread stacks: \(stats.threads), frames: \(stats.frames)
        Capture failures: \(stats.failures), stacks at 64-frame limit: \(stats.truncatedStacks)
        Stack buffers are reused each sample; only pause timings are retained.
        Suspend/capture/resume total: \(number(stats.suspensionSeconds * 1_000)) ms
        Pause window mean:   \(duration(stats.suspensionSeconds / sampleCount))
        Pause window median: \(duration(stats.medianSuspensionSeconds))
        Pause window p95:    \(duration(stats.p95SuspensionSeconds))
        Pause window p99:    \(duration(stats.p99SuspensionSeconds))
        Pause window max:    \(duration(stats.maxSuspensionSeconds))
        Suspend calls mean:  \(duration(stats.suspendCallsSeconds / sampleCount))
        Stack capture mean:  \(duration(stats.stackCaptureSeconds / sampleCount))
        Resume calls mean:   \(duration(stats.resumeCallsSeconds / sampleCount))
        Pause window spans the first suspend call through the final resume call.
        Threads are suspended/resumed sequentially, not all for the full window.
        Tick gaps are main-timer callback intervals, not presented-frame times.
        Both arms use the same 60 Hz workload timer.
        Sampler startup/shutdown and printing are outside the measurement window.
        One ordered pair is exploratory, not a statistically significant overhead estimate.
        """
    }
}
