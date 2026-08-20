import Foundation

enum FileSearchBackgroundIndexMode: String, Sendable {
    case incremental
    case full
}

enum FileSearchIndexResourceProfile: Equatable, Sendable {
    /// Automatically selects fast bootstrap only when no committed index
    /// exists; normal scheduled maintenance remains low impact.
    case automatic
    /// Explicit user request. Performs a complete pass immediately with the
    /// bounded fast CPU and filesystem budgets.
    case fast
}

enum FileSearchBackgroundRootScope: Int, Sendable {
    case applications = 0
    case files = 1
}

struct FileSearchBackgroundRoot: Hashable, Sendable {
    let url: URL
    let scope: FileSearchBackgroundRootScope
    /// Lower values commit earlier inside the same scope. This lets small,
    /// user-visible folders become queryable before a broad parent root.
    let priority: Int

    init(
        url: URL,
        scope: FileSearchBackgroundRootScope,
        priority: Int = 1_000
    ) {
        self.url = url.standardizedFileURL
        self.scope = scope
        self.priority = priority
    }
}

/// Keeps security-scoped bookmarks alive for exactly one background cycle.
/// The provider owns how access is acquired; the indexer always balances it by
/// awaiting `release()` before it returns.
struct FileSearchBackgroundRootLease: Sendable {
    let roots: [FileSearchBackgroundRoot]
    private let releaseOperation: @Sendable () async -> Void

    init(
        roots: [FileSearchBackgroundRoot],
        release: @escaping @Sendable () async -> Void = {}
    ) {
        self.roots = roots
        releaseOperation = release
    }

    func release() async {
        await releaseOperation()
    }
}

typealias FileSearchBackgroundRootProvider = @Sendable (
    FileSearchBackgroundIndexMode
) async throws -> FileSearchBackgroundRootLease

/// Narrow adapter boundary between the scheduler/scanner and the SQLite
/// generation store. A root's old generation stays queryable until `commit`.
protocol FileSearchBackgroundIndexSink: Sendable {
    func lastSuccessfulIndexDate() async throws -> Date?
    func committedItemCount(excludingRootPath: String?) async throws -> Int
    func beginRootGeneration(rootURL: URL) async throws -> FileSearchRootGeneration
    func upsert(
        _ items: [FileSearchItem],
        in token: FileSearchRootGeneration
    ) async throws
    func commitRootGeneration(
        _ token: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics,
        reachedLimit: Bool
    ) async throws
    func abortRootGeneration(_ token: FileSearchRootGeneration) async throws
    func dirtyPaths(limit: Int) async throws -> [URL]
    func markDirty(_ url: URL) async throws
    func clearDirtyPaths(_ urls: [URL]) async throws
    func setGlobalLimitReached(_ reached: Bool) async throws
    func purgeObsoleteEntries(
        for token: FileSearchRootGeneration,
        limit: Int
    ) async throws -> Bool
    func purgeOrphanedEntries(limit: Int) async throws -> Bool
}

extension FileSearchIndexStore: FileSearchBackgroundIndexSink {
    func lastSuccessfulIndexDate() throws -> Date? {
        try metadata().lastSuccessfulIndexAt
    }
}

struct FileSearchBackgroundIndexerConfiguration: Sendable {
    var maximumIndexedItems: Int
    var microBatchSize: Int
    var targetCPUFraction: Double
    var initialMicroBatchSize: Int
    var initialTargetCPUFraction: Double
    var incrementalMaximumEntriesPerSecond: Double
    var initialMaximumEntriesPerSecond: Double
    var initialUserIdleDuration: TimeInterval
    var userIdleDuration: TimeInterval
    var maximumActivityPause: TimeInterval
    var dirtyPathLimit: Int

    init(
        maximumIndexedItems: Int = 300_000,
        microBatchSize: Int = 24,
        targetCPUFraction: Double = 0.006,
        initialMicroBatchSize: Int = 256,
        initialTargetCPUFraction: Double = 0.05,
        incrementalMaximumEntriesPerSecond: Double = 160,
        initialMaximumEntriesPerSecond: Double = 2_500,
        initialUserIdleDuration: TimeInterval? = 0,
        userIdleDuration: TimeInterval = 0,
        maximumActivityPause: TimeInterval = 5 * 60,
        dirtyPathLimit: Int = 1_000
    ) {
        self.maximumIndexedItems = max(1_000, maximumIndexedItems)
        self.microBatchSize = min(max(microBatchSize, 16), 32)
        self.targetCPUFraction = min(max(targetCPUFraction, 0.001), 0.009)
        self.initialMicroBatchSize = min(max(initialMicroBatchSize, 64), 512)
        self.initialTargetCPUFraction = min(
            max(initialTargetCPUFraction, 0.01),
            0.05
        )
        self.incrementalMaximumEntriesPerSecond = min(
            max(incrementalMaximumEntriesPerSecond, 20),
            500
        )
        self.initialMaximumEntriesPerSecond = min(
            max(initialMaximumEntriesPerSecond, 500),
            10_000
        )
        self.initialUserIdleDuration = max(
            0,
            initialUserIdleDuration ?? min(userIdleDuration, 2)
        )
        self.userIdleDuration = max(0, userIdleDuration)
        self.maximumActivityPause = max(1, maximumActivityPause)
        self.dirtyPathLimit = min(max(dirtyPathLimit, 1), 10_000)
    }

    static let standard = FileSearchBackgroundIndexerConfiguration()
}

enum FileSearchBackgroundIndexRunResult: Equatable, Sendable {
    case completed(mode: FileSearchBackgroundIndexMode, roots: Int, items: Int)
    case noChanges
    case deferred
    case failed(String)
}

enum FileSearchInitialIndexProgressPhase: Equatable, Sendable {
    case scheduled
    case indexingApplications
    case indexingFiles
    case waitingToRetry
}

struct FileSearchInitialIndexProgressSnapshot: Equatable, Sendable {
    let phase: FileSearchInitialIndexProgressPhase
    let completedRoots: Int
    let totalRoots: Int
    let indexedApplications: Int
    let estimatedRemaining: TimeInterval?
    let discoveredItems: Int
    let indexedItems: Int
    let currentRootName: String?
    let recentPaths: [String]

    init(
        phase: FileSearchInitialIndexProgressPhase,
        completedRoots: Int,
        totalRoots: Int,
        indexedApplications: Int,
        estimatedRemaining: TimeInterval?,
        discoveredItems: Int = 0,
        indexedItems: Int = 0,
        currentRootName: String? = nil,
        recentPaths: [String] = []
    ) {
        self.phase = phase
        self.completedRoots = completedRoots
        self.totalRoots = totalRoots
        self.indexedApplications = indexedApplications
        self.estimatedRemaining = estimatedRemaining
        self.discoveredItems = discoveredItems
        self.indexedItems = indexedItems
        self.currentRootName = currentRootName
        self.recentPaths = recentPaths
    }

    /// A determinate value is available while the bounded application-root
    /// pass is running. Later low-CPU file maintenance has no reliable total
    /// and is intentionally represented by an indeterminate progress bar.
    var fractionCompleted: Double? {
        switch phase {
        case .scheduled:
            return 0
        case .indexingApplications, .indexingFiles:
            if discoveredItems > 0 {
                return min(
                    1,
                    max(0, Double(indexedItems) / Double(discoveredItems))
                )
            }
            guard totalRoots > 0 else { return nil }
            return min(1, max(0, Double(completedRoots) / Double(totalRoots)))
        case .waitingToRetry:
            return nil
        }
    }

    var localizedStatusMessage: String {
        switch phase {
        case .scheduled:
            return L10n.tr(
                "首次索引预计约 %@",
                Self.durationText(estimatedRemaining)
            )
        case .indexingApplications:
            return activeStatus(prefix: L10n.tr("应用索引中"))
        case .indexingFiles:
            return activeStatus(prefix: L10n.tr("文档索引更新中"))
        case .waitingToRetry:
            return L10n.tr("首次索引等待系统空闲后重试")
        }
    }

    private func activeStatus(prefix: String) -> String {
        let root = currentRootName.map { " · \($0)" } ?? ""
        let counts = discoveredItems > 0
            ? L10n.tr(
                "，已索引 %lld / 已发现 %lld 项",
                Int64(indexedItems),
                Int64(discoveredItems)
            )
            : ""
        let roots = totalRoots > 0
            ? L10n.tr("，目录 %d/%d", completedRoots + 1, totalRoots)
            : ""
        if phase == .indexingApplications {
            return L10n.tr(
                "%@%@%@%@，预计剩余 %@",
                prefix,
                root,
                counts,
                roots,
                Self.durationText(estimatedRemaining)
            )
        }
        return L10n.tr("%@%@%@%@；总数会随扫描动态增加", prefix, root, counts, roots)
    }

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite else { return L10n.tr("少量时间") }
        let seconds = max(1, Int(ceil(duration)))
        if seconds < 60 { return L10n.tr("%d 秒", seconds) }
        return L10n.tr("%d 分钟", Int(ceil(Double(seconds) / 60)))
    }
}

/// Process-local live progress for the active background pass. The discovered
/// denominator is intentionally dynamic: pre-counting a large tree would
/// double filesystem work and violate the low-CPU indexing contract.
actor FileSearchInitialIndexProgressTracker {
    static let shared = FileSearchInitialIndexProgressTracker()

    private enum State {
        case inactive
        case scheduled(
            startedAt: TimeInterval,
            expectedDuration: TimeInterval,
            totalRoots: Int
        )
        case indexing(
            startedAt: TimeInterval,
            phase: FileSearchInitialIndexProgressPhase,
            completedRoots: Int,
            totalRoots: Int,
            discoveredItems: Int,
            indexedItems: Int,
            currentRootName: String?
        )
        case waitingToRetry
    }

    private var state: State = .inactive
    private var recentPaths: [String] = []

    func schedule(applicationRootCount: Int, delay: TimeInterval) {
        recentPaths.removeAll(keepingCapacity: true)
        let roots = max(1, applicationRootCount)
        state = .scheduled(
            startedAt: ProcessInfo.processInfo.systemUptime,
            expectedDuration: max(3, delay + Double(roots * 2)),
            totalRoots: roots
        )
    }

    func begin(applicationRootCount: Int) {
        begin(
            rootCount: applicationRootCount,
            phase: .indexingApplications
        )
    }

    func begin(
        rootCount: Int,
        phase: FileSearchInitialIndexProgressPhase
    ) {
        guard rootCount > 0 else {
            state = .inactive
            recentPaths.removeAll(keepingCapacity: true)
            return
        }
        recentPaths.removeAll(keepingCapacity: true)
        state = .indexing(
            startedAt: ProcessInfo.processInfo.systemUptime,
            phase: phase,
            completedRoots: 0,
            totalRoots: rootCount,
            discoveredItems: 0,
            indexedItems: 0,
            currentRootName: nil
        )
    }

    func recordApplications(_ count: Int) {
        recordIndexed(count)
    }

    func beginRoot(
        named name: String,
        phase requestedPhase: FileSearchInitialIndexProgressPhase? = nil
    ) {
        guard case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            discovered,
            indexed,
            _
        ) = state else { return }
        state = .indexing(
            startedAt: startedAt,
            phase: requestedPhase ?? phase,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            discoveredItems: discovered,
            indexedItems: indexed,
            currentRootName: name
        )
    }

    func recordDiscovered(_ count: Int) {
        updateCounts(discoveredDelta: max(0, count), indexedDelta: 0)
    }

    func recordIndexed(_ count: Int) {
        updateCounts(discoveredDelta: 0, indexedDelta: max(0, count))
    }

    func recordPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths where recentPaths.last != path {
            recentPaths.append(path)
        }
        if recentPaths.count > 12 {
            recentPaths.removeFirst(recentPaths.count - 12)
        }
    }

    private func updateCounts(discoveredDelta: Int, indexedDelta: Int) {
        guard discoveredDelta > 0 || indexedDelta > 0,
              case let .indexing(
                startedAt,
                phase,
                completedRoots,
                totalRoots,
                discovered,
                indexed,
                currentRoot
              ) = state else { return }
        state = .indexing(
            startedAt: startedAt,
            phase: phase,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            discoveredItems: discovered + discoveredDelta,
            indexedItems: indexed + indexedDelta,
            currentRootName: currentRoot
        )
    }

    func completeApplicationRoot() {
        guard case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            discovered,
            indexed,
            currentRoot
        ) = state else {
            return
        }
        let nextCompleted = min(totalRoots, completedRoots + 1)
        if nextCompleted >= totalRoots {
            state = .inactive
        } else {
            state = .indexing(
                startedAt: startedAt,
                phase: phase,
                completedRoots: nextCompleted,
                totalRoots: totalRoots,
                discoveredItems: discovered,
                indexedItems: indexed,
                currentRootName: currentRoot
            )
        }
    }

    func waitToRetry() {
        guard case .inactive = state else {
            state = .waitingToRetry
            return
        }
    }

    func clear() {
        state = .inactive
        recentPaths.removeAll(keepingCapacity: true)
    }

    func snapshot() -> FileSearchInitialIndexProgressSnapshot? {
        switch state {
        case .inactive:
            return nil
        case let .scheduled(startedAt, expectedDuration, totalRoots):
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            return FileSearchInitialIndexProgressSnapshot(
                phase: .scheduled,
                completedRoots: 0,
                totalRoots: totalRoots,
                indexedApplications: 0,
                estimatedRemaining: max(1, expectedDuration - elapsed)
            )
        case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            discovered,
            indexed,
            currentRoot
        ):
            let elapsed = max(0.25, ProcessInfo.processInfo.systemUptime - startedAt)
            let observedRate = Double(indexed) / elapsed
            let estimatedTotal: Double
            if completedRoots > 0 {
                estimatedTotal = max(
                    Double(max(indexed, discovered)),
                    Double(indexed) * Double(totalRoots) / Double(completedRoots)
                )
            } else {
                estimatedTotal = max(
                    Double(totalRoots * 75),
                    Double(max(indexed, discovered) * 2)
                )
            }
            let remaining = observedRate > 0
                ? max(1, (estimatedTotal - Double(indexed)) / observedRate)
                : max(3, Double(totalRoots * 2))
            return FileSearchInitialIndexProgressSnapshot(
                phase: phase,
                completedRoots: completedRoots,
                totalRoots: totalRoots,
                indexedApplications: indexed,
                estimatedRemaining: remaining,
                discoveredItems: discovered,
                indexedItems: indexed,
                currentRootName: currentRoot,
                recentPaths: recentPaths
            )
        case .waitingToRetry:
            return FileSearchInitialIndexProgressSnapshot(
                phase: .waitingToRetry,
                completedRoots: 0,
                totalRoots: 0,
                indexedApplications: 0,
                estimatedRemaining: nil
            )
        }
    }
}
