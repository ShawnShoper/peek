import Foundation
import OSLog

/// Bounded backoff for an explicit per-folder refresh that is waiting behind
/// another index pass. The old fixed 350 ms poll could live forever after the
/// settings window closed and wake the coordinator several times per second.
struct FileSearchRootRefreshRetryPolicy: Equatable, Sendable {
    var maximumWait: TimeInterval
    var initialDelay: TimeInterval
    var maximumDelay: TimeInterval

    init(
        maximumWait: TimeInterval = 5 * 60,
        initialDelay: TimeInterval = 0.35,
        maximumDelay: TimeInterval = 2
    ) {
        self.maximumWait = Self.boundedFinite(
            maximumWait,
            fallback: 5 * 60,
            range: 0 ... 30 * 60
        )
        self.initialDelay = Self.boundedFinite(
            initialDelay,
            fallback: 0.35,
            range: 0.05 ... 5
        )
        self.maximumDelay = Self.boundedFinite(
            maximumDelay,
            fallback: 2,
            range: self.initialDelay ... 10
        )
    }

    static let standard = FileSearchRootRefreshRetryPolicy()

    func shouldRetry(elapsed: TimeInterval) -> Bool {
        elapsed < maximumWait
    }

    func delay(afterDeferredAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return initialDelay }
        return min(initialDelay * pow(2, Double(attempt)), maximumDelay)
    }

    private static func boundedFinite(
        _ value: TimeInterval,
        fallback: TimeInterval,
        range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        guard value.isFinite else { return min(max(fallback, range.lowerBound), range.upperBound) }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Application-lifetime owner for the persistent background file index.
/// Search queries never call this type; only app lifecycle and explicit
/// interactive-activity signals reach the coordinator.
@MainActor
protocol FileSearchIndexActivityControlling: AnyObject {
    func setSearchPanelActive(_ isActive: Bool)
    /// Signals that foreground capture is starting without placing screenshot
    /// startup behind any existing indexing activity task. Screenshot latency
    /// and cleanup must never depend on the background indexer's queue.
    func beginCaptureActivity()
    /// Releases the matching blocker. Begin/end ordering is preserved on a
    /// dedicated fire-and-forget queue that cannot hold up screenshot state.
    func endCaptureActivity()
    func setOCRActive(_ isActive: Bool)
    func setFileOperationActive(_ isActive: Bool)
}

@MainActor
final class FileSearchIndexRuntime: FileSearchIndexActivityControlling {
    static let shared = FileSearchIndexRuntime()

    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "FileSearchRuntime"
    )

    private let store: FileSearchIndexStore
    private let coordinator: FileSearchIndexCoordinator<FileSearchIndexStore>
    private var lifecycleTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var captureActivityTask: Task<Void, Never>?

    private init() {
        let store = FileSearchIndexStore()
        self.store = store
        coordinator = FileSearchIndexCoordinator(
            sink: store,
            rootProvider: Self.makeRootProvider(store: store)
        )
    }

    func start() {
        let retainedRoots = retainedRootURLs()
        let applicationRootCount = FileSearchApplicationRootStore.shared.roots
            .filter { $0.status.isAuthorized }.count
        let store = store
        enqueueLifecycle { coordinator in
            // Reconcile persisted authorization before the coordinator's
            // delayed first pass. This is SQL-only: revoked roots disappear
            // from queries immediately and no filesystem tree is walked.
            do {
                try await store.reconcileRoots(retaining: retainedRoots)
            } catch {
                Self.logger.error(
                    "Startup root reconciliation failed: \(error.localizedDescription, privacy: .private)"
                )
            }
            let metadata: FileSearchIndexMetadata?
            do {
                metadata = try await store.metadata()
            } catch {
                Self.logger.error(
                    "Startup index metadata failed: \(error.localizedDescription, privacy: .private)"
                )
                metadata = nil
            }
            if metadata?.lastSuccessfulIndexAt == nil {
                let coordinatorConfiguration = FileSearchIndexCoordinatorConfiguration.standard
                let indexerConfiguration = FileSearchBackgroundIndexerConfiguration.standard
                await FileSearchInitialIndexProgressTracker.shared.schedule(
                    applicationRootCount: applicationRootCount,
                    delay: coordinatorConfiguration.firstRunDelay
                        + indexerConfiguration.initialUserIdleDuration
                )
            } else {
                await FileSearchInitialIndexProgressTracker.shared.clear()
            }
            await coordinator.start()
        }
    }

    func stop() {
        enqueueLifecycle { coordinator in
            await coordinator.stop()
        }
    }

    func setSearchPanelActive(_ isActive: Bool) {
        enqueueActivity { coordinator in
            await coordinator.setSearchPanelActive(isActive)
        }
    }

    func beginCaptureActivity() {
        enqueueCaptureActivity(true)
    }

    func endCaptureActivity() {
        enqueueCaptureActivity(false)
    }

    func setOCRActive(_ isActive: Bool) {
        enqueueActivity { coordinator in
            await coordinator.setOCRActive(isActive)
        }
    }

    func setFileOperationActive(_ isActive: Bool) {
        enqueueActivity { coordinator in
            await coordinator.setFileOperationActive(isActive)
        }
    }

    /// Runs only from an explicit settings action. Search queries remain
    /// read-only and never enter this path.
    func rebuildIndexNow() async -> FileSearchBackgroundIndexRunResult {
        guard !Task.isCancelled else { return .deferred }
        return await coordinator.rebuildNow()
    }

    /// Queues a single configured root behind any active background pass.
    /// Search queries never call this API.
    func rebuildRootWhenAvailable(
        _ url: URL,
        retryPolicy: FileSearchRootRefreshRetryPolicy = .standard
    ) async -> FileSearchBackgroundIndexRunResult {
        // Do not await the lifecycle queue here: it can contain a complete
        // background pass. The coordinator reports `.deferred` while busy,
        // allowing this method's cancellation-aware deadline to cover the
        // entire user request instead of starting only after that pass ends.
        let path = url.standardizedFileURL.path
        let startedAt = ProcessInfo.processInfo.systemUptime
        var deferredAttempt = 0
        while !Task.isCancelled {
            let result = await coordinator.rebuildRootNow(path: path)
            guard case .deferred = result else { return result }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            guard retryPolicy.shouldRetry(elapsed: elapsed) else {
                Self.logger.warning(
                    "Root refresh queue expired after \(elapsed, privacy: .public) seconds"
                )
                return .deferred
            }
            let delay = retryPolicy.delay(afterDeferredAttempt: deferredAttempt)
            deferredAttempt += 1
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return .deferred
            }
        }
        return .deferred
    }

    func metadata() async -> FileSearchIndexMetadata? {
        do {
            return try await store.metadata()
        } catch {
            Self.logger.error(
                "Index metadata query failed: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    func rootStatuses() async -> [String: FileSearchRootIndexStatus] {
        let statuses: [FileSearchRootIndexStatus]
        do {
            statuses = try await store.rootStatuses()
        } catch {
            Self.logger.error(
                "Root status query failed: \(error.localizedDescription, privacy: .private)"
            )
            statuses = []
        }
        return Dictionary(uniqueKeysWithValues: statuses.map {
            ($0.rootPath, $0)
        })
    }

    /// Authorization changes are reconciled immediately in SQLite, without a
    /// filesystem scan. New roots are marked dirty for the next scheduled
    /// incremental cycle; removed roots stop appearing in search at once.
    func authorizedRootsDidChange() {
        let retainedRoots = retainedRootURLs()
        let precedingTask = lifecycleTask
        let store = store
        lifecycleTask = Task {
            _ = await precedingTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await store.reconcileRoots(retaining: retainedRoots)
                // Authorization may have been added or refreshed for an
                // already committed path. Reconcile alone cannot distinguish
                // that from an unchanged root, so explicitly queue every
                // currently authorized user root for the next periodic pass.
                for root in retainedRoots {
                    try await store.markDirty(root)
                }
            } catch {
                Self.logger.error(
                    "Authorized root reconciliation failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func retainedRootURLs() -> [URL] {
        let authorizedDocumentRoots = FileSearchAuthorizedRootStore.shared.roots
            .compactMap { root in
                root.status.isAuthorized ? root.url : nil
            }
        let preferredDocumentRoots = Self.preferredDocumentRootURLs()
        let documentRoots = Self.plannedFileRoots(
            authorizedRootURLs: authorizedDocumentRoots,
            preferredRootURLs: preferredDocumentRoots
        ).map(\.url)
        let applicationRoots = FileSearchApplicationRootStore.shared.roots
            .compactMap { root in
                root.status.isAuthorized ? root.url : nil
            }
        return applicationRoots + documentRoots
    }

    private func enqueueLifecycle(
        _ operation: @escaping @Sendable (
            FileSearchIndexCoordinator<FileSearchIndexStore>
        ) async -> Void
    ) {
        let precedingTask = lifecycleTask
        let coordinator = coordinator
        lifecycleTask = Task {
            _ = await precedingTask?.value
            guard !Task.isCancelled else { return }
            await operation(coordinator)
        }
    }

    /// Preserve UI event order so a quick open/close or begin/end pair cannot
    /// leave a stale blocker set because two unstructured tasks raced.
    @discardableResult
    private func enqueueActivity(
        _ operation: @escaping @Sendable (
            FileSearchIndexCoordinator<FileSearchIndexStore>
        ) async -> Void
    ) -> Task<Void, Never> {
        let precedingTask = activityTask
        let coordinator = coordinator
        let task = Task {
            _ = await precedingTask?.value
            guard !Task.isCancelled else { return }
            await operation(coordinator)
        }
        activityTask = task
        return task
    }

    /// Capture uses its own direct activity-gate queue. A stale search/OCR/file
    /// operation signal may delay background-index bookkeeping, but it can no
    /// longer prevent the screenshot overlay from appearing or being cancelled.
    private func enqueueCaptureActivity(_ isActive: Bool) {
        let precedingTask = captureActivityTask
        let activityGate = FileSearchActivityGate.shared
        let task = Task {
            _ = await precedingTask?.value
            guard !Task.isCancelled else { return }
            await activityGate.setActivity(isActive, blocker: .capture)
        }
        captureActivityTask = task
    }

    private static func makeRootProvider(
        store: FileSearchIndexStore
    ) -> FileSearchBackgroundRootProvider {
        { _ in
            let access = await MainActor.run {
                (
                    FileSearchApplicationRootStore.shared.defaultRootURLs(),
                    FileSearchApplicationRootStore.shared.resolveCustomScopedAccess(),
                    FileSearchAuthorizedRootStore.shared.resolveScopedAccess(),
                    Self.preferredDocumentRootURLs()
                )
            }

            let applicationRoots = (access.0 + access.1.map(\.url)).map {
                FileSearchBackgroundRoot(url: $0, scope: .applications)
            }
            let fileRoots = Self.plannedFileRoots(
                authorizedRootURLs: access.2.map(\.url),
                preferredRootURLs: access.3
            ).filter {
                FileManager.default.fileExists(atPath: $0.url.path)
            }
            let allRoots = applicationRoots + fileRoots
            do {
                try await store.reconcileRoots(
                    retaining: allRoots.map(\.url)
                )
            } catch {
                // The lease object has not been constructed yet, so balance
                // every security-scope start on this error path explicitly.
                await MainActor.run {
                    (access.1 + access.2).forEach { $0.stop() }
                }
                throw error
            }

            return FileSearchBackgroundRootLease(
                roots: allRoots,
                release: {
                    await MainActor.run {
                        (access.1 + access.2).forEach { $0.stop() }
                    }
                }
            )
        }
    }

    /// Plans small, high-value descendants as independent generations while
    /// keeping the authorized parent as the final catch-all generation. The
    /// indexer excludes nested roots from their parent, so every path is still
    /// scanned once and each child becomes queryable immediately on commit.
    nonisolated static func plannedFileRoots(
        authorizedRootURLs: [URL],
        preferredRootURLs: [URL]
    ) -> [FileSearchBackgroundRoot] {
        let authorized = distinctURLs(authorizedRootURLs)
        var roots: [FileSearchBackgroundRoot] = []
        var seen = Set<String>()

        for (priority, preferred) in distinctURLs(preferredRootURLs).enumerated() {
            let path = preferred.path
            guard authorized.contains(where: {
                path == $0.path || path.hasPrefix($0.path + "/")
            }), seen.insert(path).inserted else { continue }
            roots.append(FileSearchBackgroundRoot(
                url: preferred,
                scope: .files,
                priority: priority
            ))
        }

        for (offset, root) in authorized.enumerated() where seen.insert(root.path).inserted {
            roots.append(FileSearchBackgroundRoot(
                url: root,
                scope: .files,
                priority: 1_000 + offset
            ))
        }
        return roots
    }

    private nonisolated static func distinctURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { rawURL in
            let url = rawURL.standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    @MainActor
    private static func preferredDocumentRootURLs() -> [URL] {
        // Root splitting is an internal scheduling optimization, not a search
        // scope preference. Use the canonical high-value locations even when
        // an older build left the visible default-root list incomplete; an
        // authorized Home root already grants these descendants either way.
        let roots = FileSearchDocumentDefaultRootStore.standardRoots.map(\.url)
        let preferredNames = ["Desktop", "Documents", "Downloads"]
        return roots.sorted { left, right in
            let leftRank = preferredNames.firstIndex(of: left.lastPathComponent)
                ?? preferredNames.count
            let rightRank = preferredNames.firstIndex(of: right.lastPathComponent)
                ?? preferredNames.count
            if leftRank != rightRank { return leftRank < rightRank }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
    }
}
