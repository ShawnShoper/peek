import Foundation

private final class FileSearchSchedulerDeferralProbe: @unchecked Sendable {
    private let scheduler: NSBackgroundActivityScheduler

    init(scheduler: NSBackgroundActivityScheduler) {
        self.scheduler = scheduler
    }

    func shouldDefer() -> Bool {
        scheduler.shouldDefer
    }
}

struct FileSearchIndexCoordinatorConfiguration: Sendable {
    var schedulerIdentifier: String
    var firstRunDelay: TimeInterval
    var interval: TimeInterval
    var tolerance: TimeInterval
    var fullIndexInterval: TimeInterval
    var lastFullIndexDefaultsKey: String
    var rootScanHistoryDefaultsKey: String

    init(
        schedulerIdentifier: String = "com.shawnshoper.peek.file-index",
        firstRunDelay: TimeInterval = 3,
        interval: TimeInterval = 30 * 60,
        tolerance: TimeInterval = 15 * 60,
        fullIndexInterval: TimeInterval = 7 * 24 * 60 * 60,
        lastFullIndexDefaultsKey: String = "fileSearch.lastCompletedFullIndex.v1",
        rootScanHistoryDefaultsKey: String = "fileSearch.rootLastSuccessfulScan.v1"
    ) {
        self.schedulerIdentifier = schedulerIdentifier
        self.firstRunDelay = max(1, firstRunDelay)
        self.interval = max(10 * 60, interval)
        self.tolerance = min(max(0, tolerance), self.interval)
        self.fullIndexInterval = max(24 * 60 * 60, fullIndexInterval)
        self.lastFullIndexDefaultsKey = lastFullIndexDefaultsKey
        self.rootScanHistoryDefaultsKey = rootScanHistoryDefaultsKey
    }

    static let standard = FileSearchIndexCoordinatorConfiguration()
}

/// Owns all indexing triggers. Search code must never invoke the indexer.
/// NSBackgroundActivityScheduler gives macOS final say over energy/thermal
/// timing, while the indexer applies the stricter app-level CPU budget.
actor FileSearchIndexCoordinator<Sink: FileSearchBackgroundIndexSink> {
    private let configuration: FileSearchIndexCoordinatorConfiguration
    private let activityGate: FileSearchActivityGate
    private let indexer: FileSearchBackgroundIndexer<Sink>
    private let scheduler: NSBackgroundActivityScheduler
    private let schedulerDeferralProbe: FileSearchSchedulerDeferralProbe
    private let defaultsStore: FileSearchIndexDefaultsStore

    private var firstRunTask: Task<Void, Never>?
    private var eventRunTask: Task<Void, Never>?
    private var pendingEventRun = false
    private var pendingApplicationPaths: Set<String> = []
    private var eventMonitoringAvailable = false
    private var activeRunTask: Task<FileSearchBackgroundIndexRunResult, Never>?
    private var activeRunID: UUID?
    private var isStarted = false

    init(
        sink: Sink,
        rootProvider: @escaping FileSearchBackgroundRootProvider,
        activityGate: FileSearchActivityGate = .shared,
        indexerConfiguration: FileSearchBackgroundIndexerConfiguration = .standard,
        coordinatorConfiguration: FileSearchIndexCoordinatorConfiguration = .standard,
        userDefaults: UserDefaults = .standard
    ) {
        configuration = coordinatorConfiguration
        self.activityGate = activityGate
        let defaultsStore = FileSearchIndexDefaultsStore(defaults: userDefaults)
        self.defaultsStore = defaultsStore

        let scheduler = NSBackgroundActivityScheduler(
            identifier: coordinatorConfiguration.schedulerIdentifier
        )
        scheduler.qualityOfService = .background
        scheduler.repeats = true
        scheduler.interval = coordinatorConfiguration.interval
        scheduler.tolerance = coordinatorConfiguration.tolerance
        self.scheduler = scheduler
        schedulerDeferralProbe = FileSearchSchedulerDeferralProbe(scheduler: scheduler)
        indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: rootProvider,
            activityGate: activityGate,
            configuration: indexerConfiguration,
            defaultsStore: defaultsStore,
            rootScanHistoryDefaultsKey: coordinatorConfiguration.rootScanHistoryDefaultsKey
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let deferralProbe = schedulerDeferralProbe
        scheduler.schedule { [weak self] completion in
            guard !deferralProbe.shouldDefer() else {
                completion(.deferred)
                return
            }
            guard let self else {
                completion(.finished)
                return
            }
            Task {
                let result = await self.runIfPossible(requireStarted: true)
                switch result {
                case .deferred:
                    completion(.deferred)
                case .completed, .limited, .noChanges, .failed:
                    // Failures are not system workload deferrals. Report the
                    // failure in UI, but do not request an immediate retry of
                    // the same broken full pass from the OS scheduler.
                    completion(.finished)
                }
            }
        }

        let delay = configuration.firstRunDelay
        firstRunTask = Task { [weak self] in
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                _ = await self?.runIfPossible(requireStarted: true)
            } catch {
                return
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        firstRunTask?.cancel()
        firstRunTask = nil
        eventRunTask?.cancel()
        eventRunTask = nil
        pendingEventRun = false
        pendingApplicationPaths.removeAll()
        activeRunTask?.cancel()
        activeRunTask = nil
        activeRunID = nil
        scheduler.invalidate()
    }

    /// Test/manual maintenance hook. Product UI should not call this from a
    /// query action; normal operation is `start()` plus scheduled triggers.
    @discardableResult
    func runNow() async -> FileSearchBackgroundIndexRunResult {
        await runIfPossible(requireStarted: false)
    }

    /// Coalesce ordinary events; application changes can preempt a long scan.
    /// Cancellation never publishes a partial generation, and all events stay
    /// durable until their replacement metadata is committed.
    func fileEventsDidArrive(applicationPaths: Set<String> = []) {
        guard isStarted else { return }
        pendingEventRun = true
        pendingApplicationPaths.formUnion(applicationPaths)
        if !applicationPaths.isEmpty { activeRunTask?.cancel() }
        guard eventRunTask == nil else { return }
        eventRunTask = Task { [weak self] in
            await self?.drainFileEvents()
        }
    }

    func setEventMonitoringAvailable(_ available: Bool) {
        eventMonitoringAvailable = available
    }

    private func drainFileEvents() async {
        defer { eventRunTask = nil }
        while pendingEventRun && isStarted && !Task.isCancelled {
            pendingEventRun = false
            do { try await Task<Never, Never>.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            var applications = pendingApplicationPaths
            pendingApplicationPaths.removeAll()
            if !applications.isEmpty { activeRunTask?.cancel() }
            while let activeRunTask, isStarted, !Task.isCancelled {
                _ = await activeRunTask.value
                await Task.yield()
            }
            applications.formUnion(pendingApplicationPaths)
            pendingApplicationPaths.removeAll()
            guard isStarted, !Task.isCancelled else { return }
            let result = await runIfPossible(requireStarted: true, forcedMode: .incremental,
                resourceProfile: applications.isEmpty ? .automatic : .fast,
                requestedChangePaths: applications.isEmpty ? nil : applications)
            if case .deferred = result {
                // The normal background schedule retries blocked work. Do not
                // spin while capture, OCR or system pressure holds the gate.
                return
            }
            if case .completed = result, (try? await indexer.hasPendingChanges()) == true {
                pendingEventRun = true
            }
            if !applications.isEmpty, (try? await indexer.hasPendingChanges()) == true {
                pendingEventRun = true
            }
        }
    }

    /// Explicit settings action. Unlike a query, this is a user-authorized
    /// complete rebuild and uses the bounded fast profile immediately.
    @discardableResult
    func rebuildNow() async -> FileSearchBackgroundIndexRunResult {
        await runIfPossible(
            requireStarted: false,
            forcedMode: .full,
            resourceProfile: .fast
        )
    }

    /// Refreshes exactly one configured root. Calls are serialized by the
    /// coordinator; callers may retry a deferred result to form a UI queue.
    @discardableResult
    func rebuildRootNow(path: String) async -> FileSearchBackgroundIndexRunResult {
        await runIfPossible(
            requireStarted: false,
            forcedMode: .incremental,
            resourceProfile: .fast,
            requestedRootPaths: [
                URL(fileURLWithPath: path, isDirectory: true)
                    .standardizedFileURL.path
            ]
        )
    }

    func setSearchPanelActive(_ isActive: Bool) async {
        await activityGate.setActivity(isActive, blocker: .searchPanel)
    }

    func setCaptureActive(_ isActive: Bool) async {
        await activityGate.setActivity(isActive, blocker: .capture)
    }

    func setOCRActive(_ isActive: Bool) async {
        await activityGate.setActivity(isActive, blocker: .ocr)
    }

    func setFileOperationActive(_ isActive: Bool) async {
        await activityGate.setActivity(isActive, blocker: .fileOperation)
    }

    private func runIfPossible(
        requireStarted: Bool,
        forcedMode: FileSearchBackgroundIndexMode? = nil,
        resourceProfile: FileSearchIndexResourceProfile = .automatic,
        requestedRootPaths: Set<String>? = nil,
        requestedChangePaths: Set<String>? = nil
    ) async -> FileSearchBackgroundIndexRunResult {
        guard !requireStarted || isStarted else { return .deferred }
        guard activeRunTask == nil else { return .deferred }

        let mode: FileSearchBackgroundIndexMode
        if let forcedMode {
            mode = forcedMode
        } else if requireStarted && !eventMonitoringAvailable {
            // A stream failure must not silently turn off routine discovery.
            // Keep the slower scheduled fallback until monitoring is restored.
            mode = .full
        } else {
            mode = await nextMode()
        }
        let taskPriority: TaskPriority = resourceProfile == .fast
            ? .utility
            : .background
        let task = Task(priority: taskPriority) { [indexer] in
            await indexer.run(
                mode: mode,
                resourceProfile: resourceProfile,
                requestedRootPaths: requestedRootPaths,
                requestedChangePaths: requestedChangePaths
            )
        }
        let runID = UUID()
        activeRunTask = task
        activeRunID = runID
        let result = await task.value

        // `stop()` can cancel this run and a manual/restarted run can begin
        // while the cancelled indexer is still unwinding. Only the task that
        // still owns the slot may clear it or publish full-index metadata.
        guard activeRunID == runID else { return result }
        activeRunTask = nil
        activeRunID = nil

        if case let .completed(mode: .full, roots, _) = result,
           roots > 0 {
            defaultsStore.set(
                Date().timeIntervalSince1970,
                forKey: configuration.lastFullIndexDefaultsKey
            )
        }
        if case .limited(mode: .full, _, _) = result {
            defaultsStore.set(Date().timeIntervalSince1970,
                forKey: configuration.lastFullIndexDefaultsKey + ".limitedAttempt")
        }
        return result
    }

    private func nextMode() async -> FileSearchBackgroundIndexMode {
        let lastCommittedIndex: Date?
        do {
            lastCommittedIndex = try await indexer.lastSuccessfulIndexDate()
        } catch {
            return .full
        }
        guard lastCommittedIndex != nil else {
            return .full
        }
        let storedTimestamp = max(defaultsStore.double(
            forKey: configuration.lastFullIndexDefaultsKey
        ), defaultsStore.double(forKey: configuration.lastFullIndexDefaultsKey + ".limitedAttempt"))
        guard storedTimestamp > 0 else { return .full }
        let lastFullDate = Date(timeIntervalSince1970: storedTimestamp)
        return Date().timeIntervalSince(lastFullDate) >= configuration.fullIndexInterval
            ? .full
            : .incremental
    }
}
