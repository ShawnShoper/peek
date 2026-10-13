import Darwin
import Foundation

/// Only explicitly measured synchronous indexing work contributes to this
/// counter. Never measure across `await`: an actor may resume on another thread.
final class FileSearchCPUWorkMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: TimeInterval = 0

    var totalCPUTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }

    func measure<T>(_ work: () throws -> T) rethrows -> T {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer {
            let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let elapsed = end >= start ? Double(end - start) / 1_000_000_000 : 0
            lock.lock()
            accumulated += elapsed
            lock.unlock()
        }
        return try work()
    }
}

enum FileSearchCPUWork {
    // Task-local context follows indexing calls across actor hops, without
    // charging independent UI, clipboard, query or translation tasks.
    @TaskLocal static var meter: FileSearchCPUWorkMeter?

    static func measure<T>(_ work: () throws -> T) rethrows -> T {
        guard let meter else { return try work() }
        return try meter.measure(work)
    }
}

struct FileSearchCPUBudgetSnapshot: Equatable, Sendable {
    let targetFraction: Double
    let measuredFraction: Double
}

/// Feedback throttle for measured indexing CPU, not total app CPU. Maintenance
/// targets 0.6% of one core; full/recovery/manual passes use a bounded fast tier.
actor FileSearchCPUBudget {
    let targetFraction: Double
    let microBatchSize: Int

    private let windowDuration: TimeInterval
    private var baselineWallTime: TimeInterval
    private var baselineCPUTime: TimeInterval
    private var measuredFraction: Double = 0
    private let workMeter: FileSearchCPUWorkMeter

    init(
        targetFraction: Double = 0.006,
        microBatchSize: Int = 24,
        windowDuration: TimeInterval = 60,
        maximumTargetFraction: Double = 0.009,
        maximumMicroBatchSize: Int = 32,
        workMeter: FileSearchCPUWorkMeter = FileSearchCPUWorkMeter()
    ) {
        let targetCeiling = min(max(maximumTargetFraction, 0.009), 0.25)
        let batchCeiling = min(max(maximumMicroBatchSize, 32), 512)
        self.targetFraction = min(max(targetFraction, 0.001), targetCeiling)
        self.microBatchSize = min(max(microBatchSize, 16), batchCeiling)
        self.windowDuration = max(10, windowDuration)
        self.workMeter = workMeter
        baselineWallTime = ProcessInfo.processInfo.systemUptime
        baselineCPUTime = workMeter.totalCPUTime
    }

    func reset() {
        baselineWallTime = ProcessInfo.processInfo.systemUptime
        baselineCPUTime = workMeter.totalCPUTime
        measuredFraction = 0
    }

    func snapshot() -> FileSearchCPUBudgetSnapshot {
        FileSearchCPUBudgetSnapshot(
            targetFraction: targetFraction,
            measuredFraction: measuredFraction
        )
    }

    /// Call after each 16-32 item micro-batch, including the SQLite upsert.
    /// Sleep is sliced to one second so cancellation remains responsive.
    func throttleAfterBatch() async throws {
        try Task.checkCancellation()
        let nowWall = ProcessInfo.processInfo.systemUptime
        let nowCPU = workMeter.totalCPUTime
        let elapsedWall = max(nowWall - baselineWallTime, 0.000_001)
        let elapsedCPU = max(nowCPU - baselineCPUTime, 0)
        measuredFraction = elapsedCPU / elapsedWall

        var remainingDelay = Self.requiredThrottleDelay(
            elapsedWall: elapsedWall,
            elapsedCPU: elapsedCPU,
            targetFraction: targetFraction,
            windowDuration: windowDuration
        )
        while remainingDelay > 0 {
            try Task.checkCancellation()
            let slice = min(remainingDelay, 1)
            try await Task<Never, Never>.sleep(
                nanoseconds: UInt64(slice * 1_000_000_000)
            )
            remainingDelay -= slice
        }

        let finishedWall = ProcessInfo.processInfo.systemUptime
        let totalWall = max(finishedWall - baselineWallTime, 0.000_001)
        measuredFraction = max(workMeter.totalCPUTime - baselineCPUTime, 0) / totalWall
        if totalWall >= windowDuration {
            baselineWallTime = finishedWall
            baselineCPUTime = workMeter.totalCPUTime
            measuredFraction = 0
        }
    }

    /// Returns only the delay remaining in the current accounting window.
    /// CPU already spent cannot be "paid back" beyond that boundary: carrying
    /// an oversized batch into later windows can otherwise pause indexing for
    /// several minutes and make a healthy background pass look stuck.
    nonisolated static func requiredThrottleDelay(
        elapsedWall: TimeInterval,
        elapsedCPU: TimeInterval,
        targetFraction: Double,
        windowDuration: TimeInterval
    ) -> TimeInterval {
        let safeElapsedWall = max(elapsedWall, 0)
        let safeElapsedCPU = max(elapsedCPU, 0)
        let safeTarget = max(targetFraction, 0.000_001)
        let remainingForTarget = max(
            safeElapsedCPU / safeTarget - safeElapsedWall,
            0
        )
        let remainingInWindow = max(windowDuration - safeElapsedWall, 0)
        return min(remainingForTarget, remainingInWindow)
    }

}

/// Disk activity is approximated by visited filesystem entries instead of
/// bytes. Directory enumeration is metadata-heavy, so a token rate provides a
/// stable ceiling without reading file contents. Both counting and indexing
/// visits are charged. Fast and low-impact modes use independent
/// instances and rates.
actor FileSearchIOBudget {
    let maximumEntriesPerSecond: Double

    private var baselineWallTime: TimeInterval
    private var processedEntries = 0

    init(maximumEntriesPerSecond: Double) {
        self.maximumEntriesPerSecond = min(
            max(maximumEntriesPerSecond, 10),
            50_000
        )
        baselineWallTime = ProcessInfo.processInfo.systemUptime
    }

    func reset() {
        baselineWallTime = ProcessInfo.processInfo.systemUptime
        processedEntries = 0
    }

    /// Call after each filesystem micro-batch. Sleeps in short slices so
    /// capture/OCR cancellation and thermal deferral remain responsive.
    func throttleAfterProcessing(_ count: Int) async throws {
        guard count > 0 else { return }
        try Task.checkCancellation()
        processedEntries += count

        let elapsed = max(
            ProcessInfo.processInfo.systemUptime - baselineWallTime,
            0.000_001
        )
        let requiredElapsed = Double(processedEntries) / maximumEntriesPerSecond
        var remainingDelay = max(requiredElapsed - elapsed, 0)
        while remainingDelay > 0 {
            try Task.checkCancellation()
            let slice = min(remainingDelay, 0.1)
            try await Task<Never, Never>.sleep(
                nanoseconds: UInt64(slice * 1_000_000_000)
            )
            remainingDelay -= slice
        }

        if ProcessInfo.processInfo.systemUptime - baselineWallTime >= 60 {
            baselineWallTime = ProcessInfo.processInfo.systemUptime
            processedEntries = 0
        }
    }
}
