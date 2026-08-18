import Darwin
import Foundation

struct FileSearchCPUBudgetSnapshot: Equatable, Sendable {
    let targetFraction: Double
    let measuredFraction: Double
}

/// Feedback throttle based on process CPU time. The standard target is 0.6%
/// of one core, leaving margin below the 1% product ceiling over a 60s window.
actor FileSearchCPUBudget {
    let targetFraction: Double
    let microBatchSize: Int

    private let windowDuration: TimeInterval
    private var baselineWallTime: TimeInterval
    private var baselineCPUTime: TimeInterval
    private var measuredFraction: Double = 0

    init(
        targetFraction: Double = 0.006,
        microBatchSize: Int = 24,
        windowDuration: TimeInterval = 60,
        maximumTargetFraction: Double = 0.009,
        maximumMicroBatchSize: Int = 32
    ) {
        let targetCeiling = min(max(maximumTargetFraction, 0.009), 0.25)
        let batchCeiling = min(max(maximumMicroBatchSize, 32), 512)
        self.targetFraction = min(max(targetFraction, 0.001), targetCeiling)
        self.microBatchSize = min(max(microBatchSize, 16), batchCeiling)
        self.windowDuration = max(10, windowDuration)
        baselineWallTime = ProcessInfo.processInfo.systemUptime
        baselineCPUTime = Self.processCPUTime()
    }

    func reset() {
        baselineWallTime = ProcessInfo.processInfo.systemUptime
        baselineCPUTime = Self.processCPUTime()
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
        let nowCPU = Self.processCPUTime()
        let elapsedWall = max(nowWall - baselineWallTime, 0.000_001)
        let elapsedCPU = max(nowCPU - baselineCPUTime, 0)
        measuredFraction = elapsedCPU / elapsedWall

        let requiredWall = elapsedCPU / targetFraction
        var remainingDelay = max(requiredWall - elapsedWall, 0)
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
        measuredFraction = max(Self.processCPUTime() - baselineCPUTime, 0) / totalWall
        if totalWall >= windowDuration {
            baselineWallTime = finishedWall
            baselineCPUTime = Self.processCPUTime()
            measuredFraction = 0
        }
    }

    private nonisolated static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = TimeInterval(usage.ru_utime.tv_sec)
            + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec)
            + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// Disk activity is approximated by visited filesystem entries instead of
/// bytes. Directory enumeration is metadata-heavy, so a token rate provides a
/// stable ceiling without reading file contents or issuing a second pre-count
/// pass. The fast bootstrap and low-impact incremental modes use independent
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
