import Foundation
import OSLog

/// `UserDefaults` is process-safe, but is not annotated Sendable in the macOS
/// 13 SDK. Keep every access behind one locked, explicitly Sendable adapter so
/// coordinator and indexer actors never transfer the raw instance.
final class FileSearchIndexDefaultsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func double(forKey key: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return defaults.double(forKey: key)
    }

    func set(_ value: Double, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(value, forKey: key)
    }

    func rootScanDates(forKey key: String) -> [String: TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        return stored.reduce(into: [:]) { result, element in
            if let timestamp = element.value as? NSNumber {
                result[element.key] = timestamp.doubleValue
            }
        }
    }

    func setRootScanDates(
        _ dates: [String: TimeInterval],
        forKey key: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(dates, forKey: key)
    }
}

struct FileSearchApplicationNames: Equatable, Sendable {
    let displayName: String
    let aliases: [String]
}

/// Resolves the name users actually see in Finder/Launchpad for every indexed
/// `.app`. Apple and third-party bundles use a mix of `InfoPlist.loctable`,
/// localized `InfoPlist.strings`, Bundle values and the package name. Preserve
/// Chinese and English variants as aliases so one generic index supports
/// localized names, pinyin, pinyin initials and English fuzzy queries.
enum FileSearchApplicationNameResolver {
    static func resolve(
        url: URL,
        preferredLanguages: [String] = Locale.preferredLanguages,
        fileManager: FileManager = .default
    ) -> FileSearchApplicationNames {
        let packageName = url.deletingPathExtension().lastPathComponent
        let fileManagerName = fileManager.displayName(atPath: url.path)
        let bundle = Bundle(url: url)
        let bundleDisplayName = bundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String

        let localizedNames = localizedInfoPlistNames(
            bundle: bundle,
            preferredLanguages: preferredLanguages,
            fileManager: fileManager
        )
        let preferredDisplayName = localizedNames.preferred
            ?? nonEmpty(bundleDisplayName)
            ?? nonEmpty(bundleName)
            ?? nonEmpty(fileManagerName)
            ?? packageName

        let localizedAliases = localizedNames.searchAliases.flatMap(chineseScriptVariants)
        let candidates = localizedAliases + [
            fileManagerName,
            packageName,
            bundleDisplayName,
            bundleName
        ].compactMap { $0 }.flatMap(chineseScriptVariants)
        return FileSearchApplicationNames(
            displayName: preferredDisplayName,
            aliases: FileSearchMatcher.uniqueAliases(
                candidates,
                excluding: preferredDisplayName
            )
        )
    }

    private static func localizedInfoPlistNames(
        bundle: Bundle?,
        preferredLanguages: [String],
        fileManager: FileManager
    ) -> (preferred: String?, searchAliases: [String]) {
        guard let resourceURL = bundle?.resourceURL else { return (nil, []) }
        var localizedNames: [String: String] = [:]

        let tableURL = resourceURL.appendingPathComponent("InfoPlist.loctable")
        if let root = propertyListDictionary(at: tableURL) {
            for (localization, rawValues) in root {
                guard localization != "LocProvenance",
                      localization != "none",
                      isSearchLocalization(
                        localization,
                        preferredLanguages: preferredLanguages
                      ),
                      let values = rawValues as? [String: Any],
                      let name = localizedName(in: values) else { continue }
                localizedNames[localization] = name
            }
        }

        // Some third-party apps use the older localized strings layout rather
        // than InfoPlist.loctable. Read only current/Chinese/English resources
        // to avoid indexing dozens of unrelated translations per app.
        let rootStringsURL = resourceURL.appendingPathComponent("InfoPlist.strings")
        if let values = propertyListStringDictionary(at: rootStringsURL),
           let name = localizedName(in: values) {
            localizedNames["none"] = name
        }
        let resourceChildren = (try? fileManager.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for localizationDirectory in resourceChildren where
            localizationDirectory.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame
        {
            let localization = localizationDirectory.deletingPathExtension().lastPathComponent
            guard isSearchLocalization(
                localization,
                preferredLanguages: preferredLanguages
            ) else { continue }
            let stringsURL = localizationDirectory.appendingPathComponent("InfoPlist.strings")
            guard let values = propertyListStringDictionary(at: stringsURL),
                  let name = localizedName(in: values) else { continue }
            localizedNames[localization] = name
        }

        let localizations = localizedNames.keys.filter { $0 != "none" }
        let preferredLocalization = Bundle.preferredLocalizations(
            from: Array(localizations),
            forPreferences: preferredLanguages
        ).first
        let preferredName = preferredLocalization.flatMap { localizedNames[$0] }
            ?? localizedNames["none"]
        return (
            preferredName,
            FileSearchMatcher.uniqueAliases(
                [preferredName].compactMap { $0 } + Array(localizedNames.values),
                excluding: ""
            )
        )
    }

    private static func propertyListDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else { return nil }
        return dictionary
    }

    private static func propertyListStringDictionary(at url: URL) -> [String: Any]? {
        propertyListDictionary(at: url)
    }

    private static func localizedName(in values: [String: Any]) -> String? {
        nonEmpty(values["CFBundleDisplayName"] as? String)
            ?? nonEmpty(values["CFBundleName"] as? String)
    }

    private static func isSearchLocalization(
        _ localization: String,
        preferredLanguages: [String]
    ) -> Bool {
        let normalized = normalizeLocalization(localization)
        if normalized == "base"
            || normalized == "en"
            || normalized.hasPrefix("en-")
            || normalized == "zh"
            || normalized.hasPrefix("zh-") {
            return true
        }
        return preferredLanguages.contains { preference in
            let preferred = normalizeLocalization(preference)
            return normalized == preferred
                || normalized.hasPrefix(preferred + "-")
                || preferred.hasPrefix(normalized + "-")
        }
    }

    private static func normalizeLocalization(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func chineseScriptVariants(_ value: String) -> [String] {
        var variants = [value]
        if let simplified = value.applyingTransform(
            StringTransform("Hant-Hans"),
            reverse: false
        ) {
            variants.append(simplified)
        }
        if let traditional = value.applyingTransform(
            StringTransform("Hans-Hant"),
            reverse: false
        ) {
            variants.append(traditional)
        }
        return variants
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private enum FileSearchBackgroundIndexControl: Error {
    case deferred
}

private struct FileSearchBackgroundRootScanResult {
    var indexedItems = 0
    var statistics = FileSearchRootCommitStatistics(
        indexedApplications: 0,
        indexedFiles: 0,
        indexedFolders: 0
    )
    var reachedLimit = false
    var rootChangedDuringScan = false
}

private struct FileSearchIndexExecutionPolicy: Sendable {
    let isFast: Bool
    let ignoresSystemDeferral: Bool
    let batchSize: Int
    let cpuBudget: FileSearchCPUBudget
    let ioBudget: FileSearchIOBudget

    var ignoredActivityBlockers: Set<FileSearchActivityBlocker> {
        // Keyboard and pointer activity must not starve indexing on a machine
        // that is used throughout the day. Both execution profiles may keep
        // advancing under their own CPU and I/O budgets. Explicit PEEK work
        // (search, capture, OCR and file operations) and system pressure remain
        // hard blockers because they are not included in this allow-list.
        [.userActive]
    }
}

/// Performs generation-based root scans. It never serves a query and never
/// runs because a query was opened; only the coordinator invokes it.
actor FileSearchBackgroundIndexer<Sink: FileSearchBackgroundIndexSink> {
    private static var logger: Logger {
        Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
            category: "FileSearchIndexer"
        )
    }
    private let sink: Sink
    private let rootProvider: FileSearchBackgroundRootProvider
    private let activityGate: FileSearchActivityGate
    private let incrementalCPUBudget: FileSearchCPUBudget
    private let fastCPUBudget: FileSearchCPUBudget
    private let incrementalIOBudget: FileSearchIOBudget
    private let fastIOBudget: FileSearchIOBudget
    private let configuration: FileSearchBackgroundIndexerConfiguration
    private let systemShouldDefer: @Sendable () -> Bool
    private let initialIndexProgress: FileSearchInitialIndexProgressTracker
    private let defaultsStore: FileSearchIndexDefaultsStore?
    private let rootScanHistoryDefaultsKey: String
    private var successfulRootScanDates: [String: TimeInterval]

    init(
        sink: Sink,
        rootProvider: @escaping FileSearchBackgroundRootProvider,
        activityGate: FileSearchActivityGate = .shared,
        configuration: FileSearchBackgroundIndexerConfiguration = .standard,
        defaultsStore: FileSearchIndexDefaultsStore? = nil,
        rootScanHistoryDefaultsKey: String = "fileSearch.rootLastSuccessfulScan.v1",
        initialIndexProgress: FileSearchInitialIndexProgressTracker = .shared,
        systemShouldDefer: @escaping @Sendable () -> Bool = { false }
    ) {
        self.sink = sink
        self.rootProvider = rootProvider
        self.activityGate = activityGate
        self.configuration = configuration
        self.systemShouldDefer = systemShouldDefer
        self.initialIndexProgress = initialIndexProgress
        self.defaultsStore = defaultsStore
        self.rootScanHistoryDefaultsKey = rootScanHistoryDefaultsKey
        successfulRootScanDates = defaultsStore?.rootScanDates(
            forKey: rootScanHistoryDefaultsKey
        ) ?? [:]
        incrementalCPUBudget = FileSearchCPUBudget(
            targetFraction: configuration.targetCPUFraction,
            microBatchSize: configuration.microBatchSize
        )
        fastCPUBudget = FileSearchCPUBudget(
            targetFraction: configuration.initialTargetCPUFraction,
            microBatchSize: configuration.initialMicroBatchSize,
            maximumTargetFraction: 0.05,
            maximumMicroBatchSize: 512
        )
        incrementalIOBudget = FileSearchIOBudget(
            maximumEntriesPerSecond: configuration.incrementalMaximumEntriesPerSecond
        )
        fastIOBudget = FileSearchIOBudget(
            maximumEntriesPerSecond: configuration.initialMaximumEntriesPerSecond
        )
    }

    func lastSuccessfulIndexDate() async throws -> Date? {
        try await sink.lastSuccessfulIndexDate()
    }

    func run(
        mode: FileSearchBackgroundIndexMode,
        resourceProfile: FileSearchIndexResourceProfile = .automatic,
        requestedRootPaths: Set<String>? = nil
    ) async -> FileSearchBackgroundIndexRunResult {
        let isInitialBuild: Bool
        let policy: FileSearchIndexExecutionPolicy
        do {
            let lastSuccessfulIndexDate = try await sink.lastSuccessfulIndexDate()
            isInitialBuild = mode == .full && lastSuccessfulIndexDate == nil
            let isFast = isInitialBuild || resourceProfile == .fast
            policy = FileSearchIndexExecutionPolicy(
                isFast: isFast,
                ignoresSystemDeferral: resourceProfile == .fast,
                batchSize: isFast
                    ? configuration.initialMicroBatchSize
                    : configuration.microBatchSize,
                cpuBudget: isFast ? fastCPUBudget : incrementalCPUBudget,
                ioBudget: isFast ? fastIOBudget : incrementalIOBudget
            )
            await activityGate.setRequiredIdleDuration(
                isFast
                    ? configuration.initialUserIdleDuration
                    : configuration.userIdleDuration
            )
            guard try await waitForActivityGate(policy: policy) else {
                return .deferred
            }
            try checkSystemDeferral(policy: policy)
            // Start CPU accounting before bookmark resolution/reconciliation.
            // General keyboard and pointer activity is allowed, while explicit
            // PEEK work and system pressure still keep the gate closed.
            await policy.cpuBudget.reset()
            await policy.ioBudget.reset()
        } catch {
            if error is CancellationError
                || error is FileSearchBackgroundIndexControl {
                return .deferred
            }
            return .failed(error.localizedDescription)
        }

        let lease: FileSearchBackgroundRootLease
        do {
            // Root providers may resolve bookmarks and reconcile SQLite, so
            // they must run only after both the idle and CPU-budget checks.
            lease = try await rootProvider(mode)
        } catch is CancellationError {
            return .deferred
        } catch {
            return .failed(error.localizedDescription)
        }

        let result: FileSearchBackgroundIndexRunResult
        do {
            result = try await execute(
                mode: mode,
                availableRoots: lease.roots,
                policy: policy,
                requestedRootPaths: requestedRootPaths
            )
        } catch is CancellationError {
            result = .deferred
        } catch FileSearchBackgroundIndexControl.deferred {
            result = .deferred
        } catch {
            result = .failed(error.localizedDescription)
        }
        if isInitialBuild {
            switch result {
            case .deferred, .failed:
                await initialIndexProgress.waitToRetry()
            case .completed, .noChanges:
                break
            }
        } else if case .deferred = result {
            await initialIndexProgress.clear()
        } else if case .failed = result {
            await initialIndexProgress.clear()
        }
        await lease.release()
        return result
    }

    private func execute(
        mode: FileSearchBackgroundIndexMode,
        availableRoots: [FileSearchBackgroundRoot],
        policy: FileSearchIndexExecutionPolicy,
        requestedRootPaths: Set<String>?
    ) async throws -> FileSearchBackgroundIndexRunResult {
        try await purgeOrphanedRows(policy: policy)
        let orderedRoots = Self.orderedDistinctRoots(availableRoots)
        let dirtyPaths: [URL]
        let roots: [FileSearchBackgroundRoot]
        if let requestedRootPaths {
            dirtyPaths = []
            roots = orderedRoots.filter {
                requestedRootPaths.contains($0.url.standardizedFileURL.path)
            }
        } else { switch mode {
        case .full:
            dirtyPaths = []
            roots = orderedRoots
        case .incremental:
            dirtyPaths = try await sink.dirtyPaths(
                limit: configuration.dirtyPathLimit
            )
            var selectedRootPaths = Set(dirtyPaths.compactMap { dirty -> String? in
                let dirtyPath = dirty.standardizedFileURL.path
                return orderedRoots
                    .filter {
                        Self.path(dirtyPath, isEqualToOrDescendantOf: $0.url.path)
                    }
                    .max { $0.url.pathComponents.count < $1.url.pathComponents.count }?
                    .url.path
            })

            // Dirty markers cover app-owned mutations. Finder, browsers and
            // downloaders do not notify this process, so every periodic
            // incremental run also refreshes exactly one clean retained root.
            // Persisted per-root success times make the choice survive relaunch
            // without turning a 30-minute pass into a full scan.
            let cleanRoots = orderedRoots.filter {
                !selectedRootPaths.contains($0.url.path)
            }
            if let oldestCleanRoot = oldestSuccessfullyScannedRoot(in: cleanRoots) {
                selectedRootPaths.insert(oldestCleanRoot.url.path)
            }
            roots = orderedRoots.filter {
                selectedRootPaths.contains($0.url.path)
            }
            guard !roots.isEmpty else { return .noChanges }
        } }

        guard !roots.isEmpty else {
            await initialIndexProgress.clear()
            return .completed(mode: mode, roots: 0, items: 0)
        }

        await initialIndexProgress.begin(
            rootCount: roots.count,
            phase: policy.isFast ? .indexingApplications : .indexingFiles
        )

        var completedRoots = 0
        var totalItems = 0
        var reachedGlobalLimit = false
        let everyAvailableRootPath = orderedRoots.map(\.url.path)

        for root in roots {
            // Preserve older committed generations for lower-priority roots
            // when the global cap is reached. Committing an empty generation
            // here would erase still-useful search results.
            try Task.checkCancellation()
            try checkSystemDeferral(policy: policy)
            guard try await waitForActivityGate(policy: policy) else {
                throw FileSearchBackgroundIndexControl.deferred
            }
            await initialIndexProgress.beginRoot(
                named: root.url.lastPathComponent.isEmpty
                    ? root.url.path
                    : root.url.lastPathComponent,
                phase: root.scope == .applications
                    ? .indexingApplications
                    : .indexingFiles
            )

            let retainedItemCount = try await sink.committedItemCount(
                excludingRootPath: root.url.path
            )
            let remainingCapacity = configuration.maximumIndexedItems
                - retainedItemCount
            guard remainingCapacity > 0 else {
                reachedGlobalLimit = true
                try await sink.setGlobalLimitReached(true)
                break
            }

            let token = try await sink.beginRootGeneration(rootURL: root.url)
            do {
                let nestedRootsToExclude = everyAvailableRootPath.filter {
                    $0 != root.url.path
                        && Self.path($0, isEqualToOrDescendantOf: root.url.path)
                }
                let result = try await scanRoot(
                    root,
                    token: token,
                    excludedSubtrees: nestedRootsToExclude,
                    remainingCapacity: remainingCapacity,
                    policy: policy
                )
                try await sink.commitRootGeneration(
                    token,
                    statistics: result.statistics,
                    reachedLimit: result.reachedLimit
                )
                if result.rootChangedDuringScan {
                    // The generation is internally valid, but the directory
                    // changed while it was being walked. Keep a dirty marker
                    // so the next incremental cycle performs a catch-up pass.
                    try await sink.markDirty(root.url)
                }
                await initialIndexProgress.completeApplicationRoot()
                recordSuccessfulScan(of: root)
                try await purgeObsoleteRows(for: token, policy: policy)
                completedRoots += 1
                totalItems += result.indexedItems
                if result.reachedLimit {
                    reachedGlobalLimit = true
                    try await sink.setGlobalLimitReached(true)
                    break
                }
            } catch {
                do {
                    try await sink.abortRootGeneration(token)
                } catch let abortError {
                    Self.logger.error(
                        "Abort staging generation failed root=\(token.rootPath, privacy: .private): \(abortError.localizedDescription, privacy: .private)"
                    )
                }
                throw error
            }
        }

        let scannedEveryRetainedRoot = completedRoots == orderedRoots.count
            && Set(roots.map { $0.url.standardizedFileURL.path })
                == Set(orderedRoots.map { $0.url.standardizedFileURL.path })
        if !reachedGlobalLimit, scannedEveryRetainedRoot {
            try await sink.setGlobalLimitReached(false)
        }

        return .completed(mode: mode, roots: completedRoots, items: totalItems)
    }

    private func purgeObsoleteRows(
        for token: FileSearchRootGeneration,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        while true {
            try checkSystemDeferral(policy: policy)
            guard try await waitForActivityGate(policy: policy) else {
                throw FileSearchBackgroundIndexControl.deferred
            }
            guard try await sink.purgeObsoleteEntries(
                for: token,
                limit: 1_000
            ) else { break }
            // One batched SQLite DELETE is not equivalent to 1,000 separate
            // filesystem metadata reads. Count it as one execution batch;
            // process CPU time still captures the real database work.
            try await policy.ioBudget.throttleAfterProcessing(policy.batchSize)
            try await policy.cpuBudget.throttleAfterBatch()
        }
    }

    private func purgeOrphanedRows(
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        // Drain all invisible generations before creating another staging
        // generation. Every batch is activity-gated and CPU-throttled, so a
        // large cleanup can pause safely without allowing the database to grow
        // by another full-root generation on every periodic run.
        while true {
            try checkSystemDeferral(policy: policy)
            guard try await waitForActivityGate(policy: policy) else {
                throw FileSearchBackgroundIndexControl.deferred
            }
            guard try await sink.purgeOrphanedEntries(limit: 1_000) else {
                break
            }
            try await policy.ioBudget.throttleAfterProcessing(policy.batchSize)
            try await policy.cpuBudget.throttleAfterBatch()
        }
    }

    private func scanRoot(
        _ root: FileSearchBackgroundRoot,
        token: FileSearchRootGeneration,
        excludedSubtrees: [String],
        remainingCapacity: Int,
        policy: FileSearchIndexExecutionPolicy
    ) async throws -> FileSearchBackgroundRootScanResult {
        guard remainingCapacity > 0 else {
            return FileSearchBackgroundRootScanResult(reachedLimit: true)
        }

        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: root.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let keys = Self.resourceKeys
        let rootModificationAtStart = try? root.url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let exclusionPolicy = root.scope == .files
            ? await MainActor.run { FileSearchExclusionSettings.shared.policy }
            : FileSearchExclusionPolicy(paths: [])
        var result = FileSearchBackgroundRootScanResult()
        var batch: [FileSearchItem] = []
        batch.reserveCapacity(policy.batchSize)
        var discoveredSinceProgressUpdate = 0

        if root.scope == .files {
            do {
                let values = try root.url.resourceValues(forKeys: keys)
                if let rootItem = Self.makeItem(
                    url: root.url,
                    values: values,
                    fileManager: fileManager
                ) {
                    batch.append(rootItem)
                    discoveredSinceProgressUpdate += 1
                    result.indexedItems += 1
                    Self.record(rootItem.kind, in: &result.statistics)
                }
            } catch {
                // A single item's metadata failure is not an enumerator
                // integrity failure. Count it and continue with descendants.
                result.statistics.inaccessibleLocations += 1
            }
        }

        var enumerationError: Error?
        var visitedSinceThrottle = 0
        guard let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                // A traversal error means the generation is incomplete. Stop
                // immediately; the caller aborts staging and retains the old
                // committed generation.
                return false
            }
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if result.indexedItems >= remainingCapacity {
                result.reachedLimit = true
                break
            }
            visitedSinceThrottle += 1

            let path = url.standardizedFileURL.path
            if excludedSubtrees.contains(where: {
                Self.path(path, isEqualToOrDescendantOf: $0)
            }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                try await throttleIfNeededAfterVisit(
                    &visitedSinceThrottle,
                    discoveredSinceProgressUpdate: &discoveredSinceProgressUpdate,
                    batch: &batch,
                    token: token,
                    policy: policy
                )
                continue
            }
            if Self.shouldSkipDescendants(of: url) {
                enumerator.skipDescendants()
                result.statistics.skippedGeneratedDirectories += 1
                try await throttleIfNeededAfterVisit(
                    &visitedSinceThrottle,
                    discoveredSinceProgressUpdate: &discoveredSinceProgressUpdate,
                    batch: &batch,
                    token: token,
                    policy: policy
                )
                continue
            }

            do {
                let values = try url.resourceValues(forKeys: keys)
                if root.scope == .files,
                   exclusionPolicy.excludes(
                       url,
                       isDirectory: values.isDirectory == true
                   ) {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    try await throttleIfNeededAfterVisit(
                        &visitedSinceThrottle,
                        discoveredSinceProgressUpdate: &discoveredSinceProgressUpdate,
                        batch: &batch,
                        token: token,
                        policy: policy
                    )
                    continue
                }
                if let item = Self.makeItem(
                    url: url,
                    values: values,
                    fileManager: fileManager
                ), root.scope != .applications || item.kind == .application {
                    batch.append(item)
                    discoveredSinceProgressUpdate += 1
                    result.indexedItems += 1
                    Self.record(item.kind, in: &result.statistics)
                }
            } catch {
                result.statistics.inaccessibleLocations += 1
            }

            try await throttleIfNeededAfterVisit(
                &visitedSinceThrottle,
                discoveredSinceProgressUpdate: &discoveredSinceProgressUpdate,
                batch: &batch,
                token: token,
                policy: policy
            )
        }

        if let enumerationError {
            result.statistics.inaccessibleLocations += 1
            throw enumerationError
        }
        if result.indexedItems >= remainingCapacity {
            result.reachedLimit = true
        }
        if discoveredSinceProgressUpdate > 0 {
            await initialIndexProgress.recordDiscovered(
                discoveredSinceProgressUpdate
            )
            discoveredSinceProgressUpdate = 0
        }
        if !batch.isEmpty {
            try await flush(
                &batch,
                token: token,
                processedEntries: max(visitedSinceThrottle, batch.count),
                policy: policy
            )
            visitedSinceThrottle = 0
        } else if visitedSinceThrottle > 0 {
            try await throttleAfterWork(
                processedEntries: visitedSinceThrottle,
                policy: policy
            )
            visitedSinceThrottle = 0
        }
        let rootModificationAtEnd = try? root.url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        result.rootChangedDuringScan = rootModificationAtStart != rootModificationAtEnd
        return result
    }

    private func throttleIfNeededAfterVisit(
        _ visitedCount: inout Int,
        discoveredSinceProgressUpdate: inout Int,
        batch: inout [FileSearchItem],
        token: FileSearchRootGeneration,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        guard visitedCount >= policy.batchSize else { return }
        if discoveredSinceProgressUpdate > 0 {
            await initialIndexProgress.recordDiscovered(
                discoveredSinceProgressUpdate
            )
            discoveredSinceProgressUpdate = 0
        }
        if batch.isEmpty {
            try await throttleAfterWork(
                processedEntries: visitedCount,
                policy: policy
            )
        } else {
            try await flush(
                &batch,
                token: token,
                processedEntries: visitedCount,
                policy: policy
            )
        }
        visitedCount = 0
    }

    private func flush(
        _ batch: inout [FileSearchItem],
        token: FileSearchRootGeneration,
        processedEntries: Int,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        try checkSystemDeferral(policy: policy)
        guard try await waitForActivityGate(policy: policy) else {
            throw FileSearchBackgroundIndexControl.deferred
        }
        let indexedCount = batch.count
        await initialIndexProgress.recordPaths(
            batch.suffix(8).map { $0.url.path }
        )
        try await sink.upsert(batch, in: token)
        await initialIndexProgress.recordIndexed(indexedCount)
        batch.removeAll(keepingCapacity: true)
        try await policy.ioBudget.throttleAfterProcessing(processedEntries)
        try await policy.cpuBudget.throttleAfterBatch()
    }

    private func throttleAfterWork(
        processedEntries: Int,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        try checkSystemDeferral(policy: policy)
        guard try await waitForActivityGate(policy: policy) else {
            throw FileSearchBackgroundIndexControl.deferred
        }
        try await policy.ioBudget.throttleAfterProcessing(processedEntries)
        try await policy.cpuBudget.throttleAfterBatch()
    }

    private func waitForActivityGate(
        policy: FileSearchIndexExecutionPolicy
    ) async throws -> Bool {
        try await activityGate.waitUntilAllowed(
            maximumWait: configuration.maximumActivityPause,
            ignoring: policy.ignoredActivityBlockers
        )
    }

    private func checkSystemDeferral(
        policy: FileSearchIndexExecutionPolicy
    ) throws {
        if !policy.ignoresSystemDeferral, systemShouldDefer() {
            throw FileSearchBackgroundIndexControl.deferred
        }
    }

    private func oldestSuccessfullyScannedRoot(
        in roots: [FileSearchBackgroundRoot]
    ) -> FileSearchBackgroundRoot? {
        roots.min { left, right in
            let leftDate = successfulRootScanDates[left.url.path]
                ?? -Double.greatestFiniteMagnitude
            let rightDate = successfulRootScanDates[right.url.path]
                ?? -Double.greatestFiniteMagnitude
            // `roots` is already application-first and deterministic. Keep
            // that order when two roots have never succeeded or share a time.
            return leftDate < rightDate
        }
    }

    private func recordSuccessfulScan(of root: FileSearchBackgroundRoot) {
        successfulRootScanDates[root.url.path] = Date().timeIntervalSince1970
        defaultsStore?.setRootScanDates(
            successfulRootScanDates,
            forKey: rootScanHistoryDefaultsKey
        )
    }

    private nonisolated static var resourceKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey,
            .isPackageKey,
            .isRegularFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey
        ]
    }

    nonisolated static func orderedDistinctRoots(
        _ roots: [FileSearchBackgroundRoot]
    ) -> [FileSearchBackgroundRoot] {
        var seen = Set<String>()
        return roots
            .sorted {
                if $0.scope.rawValue != $1.scope.rawValue {
                    return $0.scope.rawValue < $1.scope.rawValue
                }
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                let leftDepth = $0.url.pathComponents.count
                let rightDepth = $1.url.pathComponents.count
                if leftDepth != rightDepth { return leftDepth > rightDepth }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
            .filter { seen.insert($0.url.path).inserted }
    }

    private nonisolated static func shouldSkipDescendants(of url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if [
            "node_modules", "deriveddata", ".build", "caches",
            ".trash", ".cache"
        ].contains(name) {
            return true
        }
        let path = url.path.lowercased()
        return path.hasSuffix("/.git/objects")
            || path.hasSuffix("/.git/lfs/objects")
            || path.contains("/library/containers/")
            || path.contains("/library/group containers/")
    }

    private nonisolated static func path(
        _ candidate: String,
        isEqualToOrDescendantOf prefix: String
    ) -> Bool {
        candidate == prefix || candidate.hasPrefix(prefix + "/")
    }

    private nonisolated static func makeItem(
        url: URL,
        values: URLResourceValues,
        fileManager: FileManager
    ) -> FileSearchItem? {
        let isApplication = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        let isDirectory = values.isDirectory == true
        let isPackage = values.isPackage == true
        let kind: FileSearchItemKind
        if isApplication {
            kind = .application
        } else if isDirectory && !isPackage {
            kind = .folder
        } else if values.isRegularFile == true || isPackage {
            kind = .file
        } else {
            return nil
        }

        let displayedName = fileManager.displayName(atPath: url.path)
        let applicationNames = isApplication
            ? FileSearchApplicationNameResolver.resolve(
                url: url,
                fileManager: fileManager
            )
            : nil
        let isHidden = values.isHidden == true || url.pathComponents.contains {
            $0.hasPrefix(".") && $0.count > 1
        }
        let applicationVersion: String?
        if isApplication, let bundle = Bundle(url: url) {
            applicationVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        } else {
            applicationVersion = nil
        }
        let fallbackType: String
        switch kind {
        case .application: fallbackType = L10n.tr("应用程序")
        case .file: fallbackType = L10n.tr("文件")
        case .folder: fallbackType = L10n.tr("文件夹")
        }
        let localizedType = (try? url.resourceValues(
            forKeys: [.localizedTypeDescriptionKey]
        ))?.localizedTypeDescription

        return FileSearchItem(
            url: url,
            displayName: applicationNames?.displayName
                ?? (displayedName.isEmpty ? url.lastPathComponent : displayedName),
            kind: kind,
            typeDescription: localizedType ?? fallbackType,
            isHidden: isHidden,
            fileSize: kind == .file ? values.fileSize.map(Int64.init) : nil,
            createdAt: values.creationDate,
            modifiedAt: values.contentModificationDate,
            lastOpenedAt: values.contentAccessDate,
            applicationVersion: applicationVersion,
            searchAliases: applicationNames?.aliases ?? []
        )
    }

    private nonisolated static func record(
        _ kind: FileSearchItemKind,
        in statistics: inout FileSearchRootCommitStatistics
    ) {
        switch kind {
        case .application:
            statistics.indexedApplications = (statistics.indexedApplications ?? 0) + 1
        case .file:
            statistics.indexedFiles = (statistics.indexedFiles ?? 0) + 1
        case .folder:
            statistics.indexedFolders = (statistics.indexedFolders ?? 0) + 1
        }
    }
}
