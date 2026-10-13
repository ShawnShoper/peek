import Foundation

enum FileSearchBackgroundIndexMode: String, Sendable {
    case incremental
    case full
}

enum FileSearchIndexResourceProfile: Equatable, Sendable {
    /// Full passes and unfinished roots use bounded acceleration; routine
    /// maintenance of completed roots remains low impact.
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
    func hasUnindexedRoots(_ urls: [URL]) async throws -> Bool
    func committedItemCount(excludingRootPath: String?) async throws -> Int
    func committedItemCount(under path: String, rootPath: String) async throws -> Int
    func reclaimFileEntries(excludingRootPath: String, limit: Int) async throws -> Int
    func commitSubtreeGeneration(_ token: FileSearchRootGeneration, path: String) async throws
    func hasReachedLimit() async throws -> Bool
    func beginRootGeneration(rootURL: URL) async throws -> FileSearchRootGeneration
    func upsert(
        _ items: [FileSearchItem],
        in token: FileSearchRootGeneration
    ) async throws
    func preserveCommittedEntries(
        under path: String,
        excluding excludedPaths: [String],
        in token: FileSearchRootGeneration,
        afterPath: String?,
        limit: Int
    ) async throws -> FileSearchPreservedEntryBatch
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
    ) async throws -> Int
    func purgeOrphanedEntries(limit: Int) async throws -> Int
}

extension FileSearchIndexStore: FileSearchBackgroundIndexSink {
    func lastSuccessfulIndexDate() throws -> Date? {
        try metadata().lastSuccessfulIndexAt
    }

    func hasUnindexedRoots(_ urls: [URL]) throws -> Bool {
        let committed = Set(try rootStatuses().filter(\.hasCommittedGeneration).map(\.rootPath))
        return urls.contains { !committed.contains($0.standardizedFileURL.path) }
    }

    func hasReachedLimit() throws -> Bool { try metadata().phase == .limited }
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
        initialMicroBatchSize: Int = 128,
        initialTargetCPUFraction: Double = 0.20,
        incrementalMaximumEntriesPerSecond: Double = 160,
        initialMaximumEntriesPerSecond: Double = 5_000,
        initialUserIdleDuration: TimeInterval? = 0,
        userIdleDuration: TimeInterval = 0,
        maximumActivityPause: TimeInterval = 5 * 60,
        dirtyPathLimit: Int = 1_000
    ) {
        self.maximumIndexedItems = max(1_000, maximumIndexedItems)
        self.microBatchSize = min(max(microBatchSize, 16), 32)
        self.targetCPUFraction = min(max(targetCPUFraction, 0.001), 0.009)
        self.initialMicroBatchSize = min(max(initialMicroBatchSize, 32), 512)
        self.initialTargetCPUFraction = min(
            max(initialTargetCPUFraction, 0.01),
            0.25
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
    case limited(mode: FileSearchBackgroundIndexMode, roots: Int, items: Int)
    case noChanges
    case deferred
    case failed(String)
}

enum FileSearchInitialIndexProgressPhase: Equatable, Sendable {
    case scheduled
    case counting
    case indexingApplications
    case indexingFiles
    case waitingToRetry
    case failed
    case limited
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
    let failureMessage: String?
    var hasCapacityWarning = false

    init(
        phase: FileSearchInitialIndexProgressPhase,
        completedRoots: Int,
        totalRoots: Int,
        indexedApplications: Int,
        estimatedRemaining: TimeInterval?,
        discoveredItems: Int = 0,
        indexedItems: Int = 0,
        currentRootName: String? = nil,
        recentPaths: [String] = [],
        failureMessage: String? = nil
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
        self.failureMessage = failureMessage
    }

    /// Counting is intentionally indeterminate. Once the count pass finishes,
    /// indexing uses the known work-item total and grows that denominator if
    /// the second pass discovers newly-created items.
    var fractionCompleted: Double? {
        switch phase {
        case .scheduled:
            return 0
        case .counting:
            return nil
        case .indexingApplications, .indexingFiles:
            if discoveredItems > 0 {
                return min(
                    0.995,
                    max(0, Double(indexedItems) / Double(discoveredItems))
                )
            }
            guard totalRoots > 0 else { return nil }
            return min(
                0.995,
                max(0, Double(completedRoots) / Double(totalRoots))
            )
        case .waitingToRetry, .failed, .limited:
            return nil
        }
    }

    /// ETA changes below its displayed precision must not invalidate the whole
    /// SwiftUI search window every polling tick.
    func hasSamePresentation(as other: Self) -> Bool {
        phase == other.phase
            && hasCapacityWarning == other.hasCapacityWarning
            && completedRoots == other.completedRoots
            && totalRoots == other.totalRoots
            && indexedApplications == other.indexedApplications
            && discoveredItems == other.discoveredItems
            && indexedItems == other.indexedItems
            && currentRootName == other.currentRootName
            && recentPaths == other.recentPaths
            && failureMessage == other.failureMessage
            && Self.durationText(estimatedRemaining) == Self.durationText(other.estimatedRemaining)
    }

    /// Keep the track visible for every unfinished phase. Zero here means an
    /// empty track, not a measured 0%: only indexing copy reports a percentage.
    /// Counting, waiting and failures must never start an indeterminate animation.
    var progressBarValue: Double {
        switch phase {
        case .indexingApplications, .indexingFiles:
            return fractionCompleted ?? 0
        case .scheduled, .counting, .waitingToRetry, .failed, .limited:
            return 0
        }
    }

    /// Short, scannable copy for the compact row below the search field.
    /// The full path remains available through `localizedStatusMessage` for
    /// the tooltip and accessibility description.
    var localizedCompactTitle: String {
        if hasCapacityWarning && phase != .limited {
            return L10n.tr("容量已满 · %@", compactTitle)
        }
        return compactTitle
    }

    private var compactTitle: String {
        switch phase {
        case .scheduled:
            return L10n.tr("准备索引")
        case .counting:
            return rootScopedTitle(action: L10n.tr("统计总量"))
        case .indexingApplications, .indexingFiles:
            return rootScopedTitle(action: L10n.tr("索引"))
        case .waitingToRetry:
            return L10n.tr("等待系统空闲")
        case .failed:
            return L10n.tr("索引未完成")
        case .limited:
            return L10n.tr("索引容量已满")
        }
    }

    var localizedCompactDetail: String {
        switch phase {
        case .scheduled:
            return L10n.tr(
                "预计 %@",
                Self.durationText(estimatedRemaining)
            )
        case .counting:
            return compactCountingDetail()
        case .indexingApplications, .indexingFiles:
            return compactIndexingDetail()
        case .waitingToRetry:
            return L10n.tr("稍后自动重试")
        case .failed:
            return L10n.tr("悬停查看原因")
        case .limited:
            return L10n.tr("结果不完整 · 请调整搜索范围")
        }
    }

    var localizedStatusMessage: String {
        switch phase {
        case .scheduled:
            return L10n.tr(
                "首次索引预计约 %@",
                Self.durationText(estimatedRemaining)
            )
        case .counting:
            return countingStatus()
        case .indexingApplications:
            return activeStatus(prefix: L10n.tr("应用索引中"))
        case .indexingFiles:
            return activeStatus(prefix: L10n.tr("文档索引更新中"))
        case .waitingToRetry:
            return L10n.tr("首次索引等待系统空闲后重试")
        case .failed:
            return failureMessage ?? L10n.tr("索引未完成")
        case .limited:
            return L10n.tr("索引达到容量上限，部分项目未收录；请在设置中缩小搜索范围或添加排除目录。")
        }
    }

    private func countingStatus() -> String {
        let root = currentRootName.map { " · \($0)" } ?? ""
        let roots = totalRoots > 0
            ? L10n.tr(
                "，正在统计目录 %d/%d",
                min(totalRoots, completedRoots + 1),
                totalRoots
            )
            : ""
        return L10n.tr(
            "正在统计文件%@，已发现 %lld 项%@",
            root,
            Int64(discoveredItems),
            roots
        )
    }

    private func activeStatus(prefix: String) -> String {
        let root = currentRootName.map { " · \($0)" } ?? ""
        let counts = discoveredItems > 0
            ? L10n.tr(
                "，已处理 %lld / %lld 项",
                Int64(indexedItems),
                Int64(discoveredItems)
            )
            : ""
        let roots = totalRoots > 0
            ? L10n.tr(
                "，正在处理目录 %d/%d",
                min(totalRoots, completedRoots + 1),
                totalRoots
            )
            : ""
        return L10n.tr(
            "%@%@%@%@，预计剩余 %@",
            prefix,
            root,
            counts,
            roots,
            Self.durationText(estimatedRemaining)
        )
    }

    private func rootScopedTitle(action: String) -> String {
        guard let localizedRootName else { return action }
        return L10n.tr("%@：%@", action, localizedRootName)
    }

    private func compactCountingDetail() -> String {
        L10n.tr("已发现 %lld 项", Int64(discoveredItems))
    }

    private func compactIndexingDetail() -> String {
        let total = max(discoveredItems, indexedItems)
        // Integer arithmetic avoids 57 / 100 rendering as 56% due to binary
        // floating-point rounding. Full-width multiplication is overflow-safe.
        let denominator = max(0, discoveredItems > 0 ? discoveredItems : totalRoots)
        let numerator = min(denominator, max(0, discoveredItems > 0 ? indexedItems : completedRoots))
        let percentage = denominator > 0
            ? min(99, Int(UInt(denominator).dividingFullWidth(
                UInt(numerator).multipliedFullWidth(by: 100)
            ).quotient))
            : 0
        guard totalRoots > 0 else {
            return L10n.tr(
                "%lld / %lld 项 · %d%%",
                Int64(indexedItems),
                Int64(total),
                percentage
            )
        }
        return L10n.tr(
            "%lld / %lld 项 · %d%% · 目录 %d/%d",
            Int64(indexedItems),
            Int64(total),
            percentage,
            min(totalRoots, completedRoots + 1),
            totalRoots
        )
    }

    private var localizedRootName: String? {
        guard let currentRootName, !currentRootName.isEmpty else { return nil }
        let path = URL(fileURLWithPath: currentRootName)
            .standardizedFileURL
            .path
        switch path {
        case "/Applications":
            return L10n.tr("应用程序")
        case "/System/Applications", "/System/Library/CoreServices/Applications":
            return L10n.tr("系统应用")
        default:
            break
        }

        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        switch lastComponent {
        case "Applications":
            return L10n.tr("用户应用")
        case "Desktop":
            return L10n.tr("桌面")
        case "Documents":
            return L10n.tr("文稿")
        case "Downloads":
            return L10n.tr("下载")
        default:
            break
        }

        let components = URL(fileURLWithPath: path).pathComponents
        if components.count == 3, components[1] == "Users" {
            return L10n.tr("个人目录")
        }
        return lastComponent.isEmpty ? currentRootName : lastComponent
    }

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite else { return L10n.tr("少量时间") }
        let seconds = max(1, Int(ceil(duration)))
        if seconds < 60 { return L10n.tr("%d 秒", seconds) }
        return L10n.tr("%d 分钟", Int(ceil(Double(seconds) / 60)))
    }
}

/// Process-local live progress for the active background pass. A lightweight
/// count pass establishes the denominator before indexing starts. The index
/// pass keeps an independent encountered count so newly-created items can grow
/// the denominator without ever hiding work behind an early 100% value.
actor FileSearchInitialIndexProgressTracker {
    static let shared = FileSearchInitialIndexProgressTracker()

    private enum State {
        case inactive
        case scheduled(
            startedAt: TimeInterval,
            expectedDuration: TimeInterval,
            totalRoots: Int
        )
        case counting(
            completedRoots: Int,
            totalRoots: Int,
            discoveredItems: Int,
            currentRootName: String?
        )
        case indexing(
            startedAt: TimeInterval,
            phase: FileSearchInitialIndexProgressPhase,
            completedRoots: Int,
            totalRoots: Int,
            totalItems: Int,
            encounteredItems: Int,
            processedItems: Int,
            currentRootName: String?
        )
        case waitingToRetry
        case failed(String)
        case limited
    }

    private var state: State = .inactive
    private var hasCapacityWarning = false
    private var recentPaths: [String] = []
    private var rootCheckpoint: (total: Int, encountered: Int, processed: Int, counted: Int)?

    func schedule(applicationRootCount: Int, delay: TimeInterval) {
        recentPaths.removeAll(keepingCapacity: true)
        let roots = max(1, applicationRootCount)
        state = .scheduled(
            startedAt: ProcessInfo.processInfo.systemUptime,
            expectedDuration: max(3, delay + Double(roots * 2)),
            totalRoots: roots
        )
    }

    func beginCounting(rootCount: Int) {
        guard rootCount > 0 else {
            state = .inactive
            recentPaths.removeAll(keepingCapacity: true)
            return
        }
        recentPaths.removeAll(keepingCapacity: true)
        state = .counting(
            completedRoots: 0,
            totalRoots: rootCount,
            discoveredItems: 0,
            currentRootName: nil
        )
    }

    func beginIndexing(
        rootCount: Int,
        totalItemCount: Int,
        phase: FileSearchInitialIndexProgressPhase = .indexingApplications
    ) {
        guard rootCount > 0 else {
            state = .inactive
            recentPaths.removeAll(keepingCapacity: true)
            return
        }
        recentPaths.removeAll(keepingCapacity: true)
        rootCheckpoint = nil
        state = .indexing(
            startedAt: ProcessInfo.processInfo.systemUptime,
            phase: phase,
            completedRoots: 0,
            totalRoots: rootCount,
            totalItems: max(0, totalItemCount),
            encounteredItems: 0,
            processedItems: 0,
            currentRootName: nil
        )
    }

    func beginRoot(
        named name: String,
        phase requestedPhase: FileSearchInitialIndexProgressPhase? = nil,
        countedItemCount: Int = 0
    ) {
        if case let .counting(
            completedRoots,
            totalRoots,
            discoveredItems,
            _
        ) = state {
            state = .counting(
                completedRoots: completedRoots,
                totalRoots: totalRoots,
                discoveredItems: discoveredItems,
                currentRootName: name
            )
            return
        }
        guard case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            totalItems,
            encounteredItems,
            processedItems,
            _
        ) = state else { return }
        rootCheckpoint = (totalItems, encounteredItems, processedItems, max(0, countedItemCount))
        state = .indexing(
            startedAt: startedAt,
            phase: requestedPhase ?? phase,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            totalItems: totalItems,
            encounteredItems: encounteredItems,
            processedItems: processedItems,
            currentRootName: name
        )
    }

    func recordDiscovered(_ count: Int) {
        guard count > 0,
              case let .counting(
                completedRoots,
                totalRoots,
                discoveredItems,
                currentRootName
              ) = state else { return }
        state = .counting(
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            discoveredItems: discoveredItems + count,
            currentRootName: currentRootName
        )
    }

    func recordEncountered(_ count: Int, newlyDiscovered: Int = 0) {
        updateIndexingCounts(
            encounteredDelta: max(0, count),
            processedDelta: 0,
            additionalItems: max(0, newlyDiscovered)
        )
    }

    func recordIndexed(_ count: Int) {
        updateIndexingCounts(
            encounteredDelta: 0,
            processedDelta: max(0, count)
        )
    }

    func recordSkipped(_ count: Int) {
        recordIndexed(count)
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

    private func updateIndexingCounts(
        encounteredDelta: Int,
        processedDelta: Int,
        additionalItems: Int = 0
    ) {
        guard encounteredDelta > 0 || processedDelta > 0,
              case let .indexing(
                startedAt,
                phase,
                completedRoots,
                totalRoots,
                totalItems,
                encounteredItems,
                processedItems,
                currentRoot
              ) = state else { return }
        let nextEncountered = encounteredItems + encounteredDelta
        let nextProcessed = processedItems + processedDelta
        state = .indexing(
            startedAt: startedAt,
            phase: phase,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            totalItems: max(totalItems + additionalItems, max(nextEncountered, nextProcessed)),
            encounteredItems: nextEncountered,
            processedItems: nextProcessed,
            currentRootName: currentRoot
        )
    }

    func completeRoot(unencounteredItems: Int = 0, failed: Bool = false) {
        if case let .counting(
            completedRoots,
            totalRoots,
            discoveredItems,
            _
        ) = state {
            state = .counting(
                completedRoots: min(totalRoots, completedRoots + 1),
                totalRoots: totalRoots,
                discoveredItems: discoveredItems,
                currentRootName: nil
            )
            return
        }
        guard case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            totalItems,
            encounteredItems,
            processedItems,
            _
        ) = state else {
            return
        }
        let nextCompleted = min(totalRoots, completedRoots + 1)
        let checkpoint = failed ? rootCheckpoint : nil
        state = .indexing(
            startedAt: startedAt,
            phase: phase,
            completedRoots: nextCompleted,
            totalRoots: totalRoots,
            totalItems: checkpoint.map { max(0, $0.total - $0.counted) }
                ?? max(max(encounteredItems, processedItems), totalItems - max(0, unencounteredItems)),
            encounteredItems: checkpoint?.encountered ?? encounteredItems,
            processedItems: checkpoint?.processed ?? processedItems,
            currentRootName: nil
        )
        rootCheckpoint = nil
    }

    func reconcileTotalWithEncounteredItems() {
        guard case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            _,
            encounteredItems,
            processedItems,
            currentRootName
        ) = state else { return }
        state = .indexing(
            startedAt: startedAt,
            phase: phase,
            completedRoots: completedRoots,
            totalRoots: totalRoots,
            totalItems: max(encounteredItems, processedItems),
            encounteredItems: encounteredItems,
            processedItems: processedItems,
            currentRootName: currentRootName
        )
    }

    func finish() {
        state = .inactive
        hasCapacityWarning = false
        rootCheckpoint = nil
        recentPaths.removeAll(keepingCapacity: true)
    }

    func fail(_ message: String) {
        state = .failed(message)
        rootCheckpoint = nil
        recentPaths.removeAll(keepingCapacity: true)
    }

    func limitReached() {
        hasCapacityWarning = true
        state = .limited
        rootCheckpoint = nil
        recentPaths.removeAll(keepingCapacity: true)
    }

    func waitToRetry() {
        guard case .inactive = state else {
            state = .waitingToRetry
            return
        }
    }

    func clear() {
        finish()
    }

    func snapshot() -> FileSearchInitialIndexProgressSnapshot? {
        var value = makeSnapshot()
        value?.hasCapacityWarning = hasCapacityWarning
        return value
    }

    func setCapacityWarning(_ limited: Bool) {
        hasCapacityWarning = limited
    }

    private func makeSnapshot() -> FileSearchInitialIndexProgressSnapshot? {
        switch state {
        case .limited:
            return FileSearchInitialIndexProgressSnapshot(
                phase: .limited, completedRoots: 0, totalRoots: 0,
                indexedApplications: 0, estimatedRemaining: nil
            )
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
        case let .counting(
            completedRoots,
            totalRoots,
            discoveredItems,
            currentRoot
        ):
            return FileSearchInitialIndexProgressSnapshot(
                phase: .counting,
                completedRoots: completedRoots,
                totalRoots: totalRoots,
                indexedApplications: 0,
                estimatedRemaining: nil,
                discoveredItems: discoveredItems,
                indexedItems: 0,
                currentRootName: currentRoot,
                recentPaths: recentPaths
            )
        case let .indexing(
            startedAt,
            phase,
            completedRoots,
            totalRoots,
            totalItems,
            _,
            processedItems,
            currentRoot
        ):
            let elapsed = max(0.25, ProcessInfo.processInfo.systemUptime - startedAt)
            let observedRate = Double(processedItems) / elapsed
            let remainingItems = max(0, totalItems - processedItems)
            let remaining = observedRate > 0
                ? max(1, Double(remainingItems) / observedRate)
                : nil
            return FileSearchInitialIndexProgressSnapshot(
                phase: phase,
                completedRoots: completedRoots,
                totalRoots: totalRoots,
                indexedApplications: processedItems,
                estimatedRemaining: remaining,
                discoveredItems: totalItems,
                indexedItems: processedItems,
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
        case let .failed(message):
            return FileSearchInitialIndexProgressSnapshot(
                phase: .failed,
                completedRoots: 0,
                totalRoots: 0,
                indexedApplications: 0,
                estimatedRemaining: nil,
                failureMessage: message
            )
        }
    }
}
