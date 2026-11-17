import Foundation
import QuartzCore

struct BenchmarkResult {
    let wallSeconds: Double
    let cpuSeconds: Double
    let tickGaps: [Double]
    var profiler: TPProfilerStats

    var cpuPercent: Double { cpuSeconds / wallSeconds * 100 }
    var updatesPerSecond: Double { Double(tickGaps.count) / wallSeconds }

    func tickGapPercentile(_ fraction: Double) -> Double {
        guard !tickGaps.isEmpty else { return 0 }
        let sorted = tickGaps.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] * 1_000
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
