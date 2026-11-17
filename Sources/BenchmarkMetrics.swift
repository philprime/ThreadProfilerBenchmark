import Foundation
import QuartzCore

struct BenchmarkResult {
    let wallSeconds: Double
    let cpuSeconds: Double
    let tickGaps: [Double]
    var profiler: TPProfilerStats
    var pauseDurations: [Double] = []

    var cpuPercent: Double { cpuSeconds / wallSeconds * 100 }
    var updatesPerSecond: Double { Double(tickGaps.count) / wallSeconds }

    func tickGapPercentile(_ fraction: Double) -> Double {
        Self.percentile(tickGaps, fraction) * 1_000
    }

    func pausePercentile(_ fraction: Double) -> Double {
        Self.percentile(pauseDurations, fraction)
    }

    static func aggregate(_ runs: [Self]) -> Self {
        var stats = TPProfilerStats()
        for run in runs {
            stats.samples += run.profiler.samples
            stats.threads += run.profiler.threads
            stats.frames += run.profiler.frames
            stats.failures += run.profiler.failures
            stats.truncatedStacks += run.profiler.truncatedStacks
            stats.suspensionSeconds += run.profiler.suspensionSeconds
            stats.maxSuspensionSeconds = max(stats.maxSuspensionSeconds, run.profiler.maxSuspensionSeconds)
            stats.suspendCallsSeconds += run.profiler.suspendCallsSeconds
            stats.stackCaptureSeconds += run.profiler.stackCaptureSeconds
            stats.resumeCallsSeconds += run.profiler.resumeCallsSeconds
        }
        return Self(
            wallSeconds: runs.reduce(0) { $0 + $1.wallSeconds },
            cpuSeconds: runs.reduce(0) { $0 + $1.cpuSeconds },
            tickGaps: runs.flatMap(\.tickGaps), profiler: stats,
            pauseDurations: runs.flatMap(\.pauseDurations)
        )
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
}

@MainActor
final class BenchmarkMetrics {
    private var isMeasuring = false
    private var lastTick = 0.0
    private var started = 0.0
    private var cpuStarted = 0.0
    private var tickGaps: [Double] = []

    func start() {
        tickGaps = []
        tickGaps.reserveCapacity(2_000)
        cpuStarted = TPProcessCPUSeconds()
        started = CACurrentMediaTime()
        lastTick = started
        isMeasuring = true
    }

    func tick() {
        guard isMeasuring else { return }
        let now = CACurrentMediaTime()
        if tickGaps.count < 2_000 {
            tickGaps.append(now - lastTick)
        }
        lastTick = now
    }

    func finish() -> BenchmarkResult {
        let wall = CACurrentMediaTime() - started
        let cpu = TPProcessCPUSeconds() - cpuStarted
        isMeasuring = false
        return BenchmarkResult(
            wallSeconds: wall, cpuSeconds: cpu, tickGaps: tickGaps, profiler: TPProfilerStats()
        )
    }
}
