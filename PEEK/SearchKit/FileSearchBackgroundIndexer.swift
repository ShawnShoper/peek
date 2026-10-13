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

/// A restricted descendant is a local warning, not a failure of its parent.
/// Root-level denial and unexpected I/O failures still abort the generation.
/// Used only by one synchronous FileManager enumeration at a time.
final class FileSearchTraversalIssues {
    private(set) var inaccessiblePaths: Set<String> = []
    private(set) var fatalError: Error?

    func continueAfter(_ error: Error, at url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.standardizedFileURL.path + "/") else {
            fatalError = error
            return false
        }
        var underlying = error as NSError
        for _ in 0..<8 {
            if (underlying.domain == NSCocoaErrorDomain && underlying.code == CocoaError.fileReadNoPermission.rawValue)
                || (underlying.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(underlying.code)) {
                inaccessiblePaths.insert(path)
                return true
            }
            if (underlying.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(underlying.code))
                || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)) {
                // A descendant removed during enumeration is not permission
                // loss: allow its old metadata to disappear normally.
                return true
            }
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            underlying = next
        }
        fatalError = error
        return false
    }

    var distinctInaccessiblePaths: [String] {
        inaccessiblePaths.filter { candidate in
            var parent = (candidate as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if inaccessiblePaths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }
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
    var unencounteredItems = 0
}

/// The bounded count-pass inventory distinguishes newly-created entries from
/// entries belonging to later roots. Counts alone cannot make that distinction.
private struct FileSearchRootProgress {
    var remainingPaths: Set<String>
    var encountered = 0
    var skipped = 0
    var additional = 0

    mutating func encounter(_ path: String, skipped: Bool = false) {
        encountered += 1
        if remainingPaths.remove(path) == nil { additional += 1 }
        if skipped { self.skipped += 1 }
    }
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
        // advancing under their own CPU and I/O budgets, including while the
        // search panel reads committed SQLite generations. Capture, OCR, file
        // operations and system pressure remain hard blockers.
        [.userActive, .searchPanel]
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
    private let cpuWorkMeter: FileSearchCPUWorkMeter
    private let incrementalCPUBudget: FileSearchCPUBudget
    private let fastCPUBudget: FileSearchCPUBudget
    private let incrementalIOBudget: FileSearchIOBudget
    private let fastIOBudget: FileSearchIOBudget
    private let configuration: FileSearchBackgroundIndexerConfiguration
    private let systemShouldDefer: @Sendable () -> Bool
    private let initialIndexProgress: FileSearchInitialIndexProgressTracker
    private let defaultsStore: FileSearchIndexDefaultsStore?
    private let rootScanHistoryDefaultsKey: String
    private let activityCheckpointPolicy: FileSearchActivityCheckpointPolicy
    private var successfulRootScanDates: [String: TimeInterval]

    init(
        sink: Sink,
        rootProvider: @escaping FileSearchBackgroundRootProvider,
        activityGate: FileSearchActivityGate = .shared,
        configuration: FileSearchBackgroundIndexerConfiguration = .standard,
        defaultsStore: FileSearchIndexDefaultsStore? = nil,
        rootScanHistoryDefaultsKey: String = "fileSearch.rootLastSuccessfulScan.v1",
        initialIndexProgress: FileSearchInitialIndexProgressTracker = .shared,
        activityCheckpointPolicy: FileSearchActivityCheckpointPolicy = .standard,
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
        self.activityCheckpointPolicy = activityCheckpointPolicy
        successfulRootScanDates = defaultsStore?.rootScanDates(
            forKey: rootScanHistoryDefaultsKey
        ) ?? [:]
        let workMeter = FileSearchCPUWorkMeter()
        cpuWorkMeter = workMeter
        incrementalCPUBudget = FileSearchCPUBudget(
            targetFraction: configuration.targetCPUFraction,
            microBatchSize: configuration.microBatchSize,
            workMeter: workMeter
        )
        fastCPUBudget = FileSearchCPUBudget(
            targetFraction: configuration.initialTargetCPUFraction,
            microBatchSize: configuration.initialMicroBatchSize,
            maximumTargetFraction: 0.25,
            maximumMicroBatchSize: 512,
            workMeter: workMeter
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

    func hasPendingChanges() async throws -> Bool {
        try await !sink.dirtyPaths(limit: 1).isEmpty
    }

    func run(
        mode: FileSearchBackgroundIndexMode,
        resourceProfile: FileSearchIndexResourceProfile = .automatic,
        requestedRootPaths: Set<String>? = nil,
        requestedChangePaths: Set<String>? = nil
    ) async -> FileSearchBackgroundIndexRunResult {
        var policy: FileSearchIndexExecutionPolicy
        do {
            await initialIndexProgress.setCapacityWarning(try await sink.hasReachedLimit())
            // A partially built/full index must not fall back to the very
            // slow maintenance tier just because one app root committed.
            let isFast = mode == .full || resourceProfile == .fast
            policy = executionPolicy(
                isFast: isFast,
                ignoresSystemDeferral: resourceProfile == .fast
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
            // Search and keyboard/pointer activity are allowed. Capture/OCR,
            // file operations and system pressure still keep the gate closed.
            await policy.cpuBudget.reset()
            await policy.ioBudget.reset()
        } catch {
            if error is CancellationError
                || error is FileSearchBackgroundIndexControl {
                return .deferred
            }
            await initialIndexProgress.fail(error.localizedDescription)
            return .failed(error.localizedDescription)
        }

        let lease: FileSearchBackgroundRootLease
        do {
            // Root providers may resolve bookmarks and reconcile SQLite, so
            // they must run only after both the idle and CPU-budget checks.
            lease = try await FileSearchCPUWork.$meter.withValue(cpuWorkMeter) {
                try await rootProvider(mode)
            }
        } catch is CancellationError {
            return .deferred
        } catch {
            await initialIndexProgress.fail(error.localizedDescription)
            return .failed(error.localizedDescription)
        }

        let result: FileSearchBackgroundIndexRunResult
        do {
            if !policy.isFast {
                let unindexed = try await sink.hasUnindexedRoots(lease.roots.map(\.url))
                let rootPaths = Set(lease.roots.map(\.url.path))
                let rootRecovery = try await sink.dirtyPaths(limit: configuration.dirtyPathLimit)
                    .contains { rootPaths.contains($0.standardizedFileURL.path) }
                if unindexed || rootRecovery {
                    // Migration, event loss and changed authorization require
                    // bounded recovery, not a multi-hour maintenance crawl.
                    policy = executionPolicy(isFast: true, ignoresSystemDeferral: false)
                    await policy.cpuBudget.reset()
                    await policy.ioBudget.reset()
                }
            }
            Self.logger.info("Index mode=\(mode.rawValue, privacy: .public) fast=\(policy.isFast, privacy: .public)")
            result = try await FileSearchCPUWork.$meter.withValue(cpuWorkMeter) {
                if let requestedChangePaths {
                    // A small application event must not wait behind cleanup
                    // or counting of a cancelled, broad file generation.
                    return try await updateChangedPaths(requestedChangePaths.map { URL(fileURLWithPath: $0) },
                        roots: lease.roots, policy: policy)
                }
                return try await execute(
                    mode: mode,
                    availableRoots: lease.roots,
                    policy: policy,
                    requestedRootPaths: requestedRootPaths
                )
            }
        } catch is CancellationError {
            result = .deferred
        } catch FileSearchBackgroundIndexControl.deferred {
            result = .deferred
        } catch {
            result = .failed(error.localizedDescription)
        }
        switch result {
        case .failed(let message):
            await initialIndexProgress.fail(message)
        case .deferred:
            await initialIndexProgress.waitToRetry()
        case .limited:
            await initialIndexProgress.limitReached()
        case .completed, .noChanges:
            break
        }
        await lease.release()
        return result
    }

    private func executionPolicy(
        isFast: Bool,
        ignoresSystemDeferral: Bool
    ) -> FileSearchIndexExecutionPolicy {
        FileSearchIndexExecutionPolicy(
            isFast: isFast,
            ignoresSystemDeferral: ignoresSystemDeferral,
            batchSize: isFast ? configuration.initialMicroBatchSize : configuration.microBatchSize,
            cpuBudget: isFast ? fastCPUBudget : incrementalCPUBudget,
            ioBudget: isFast ? fastIOBudget : incrementalIOBudget
        )
    }

    private func execute(
        mode: FileSearchBackgroundIndexMode,
        availableRoots: [FileSearchBackgroundRoot],
        policy: FileSearchIndexExecutionPolicy,
        requestedRootPaths: Set<String>?,
        finalizeProgress: Bool = true
    ) async throws -> FileSearchBackgroundIndexRunResult {
        try await purgeOrphanedRows(policy: policy)
        let orderedRoots = Self.orderedDistinctRoots(availableRoots)
        // Finish the small application phase before counting a potentially
        // huge personal folder. Each phase has a real measured denominator.
        if mode == .full, requestedRootPaths == nil,
           orderedRoots.contains(where: { $0.scope == .applications }),
           orderedRoots.contains(where: { $0.scope == .files }) {
            var completed = 0
            var items = 0
            var limited = false
            var failures: [String] = []
            for scope in [FileSearchBackgroundRootScope.applications, .files] {
                let result = try await execute(mode: mode, availableRoots: availableRoots, policy: policy,
                    requestedRootPaths: Set(orderedRoots.filter { $0.scope == scope }.map(\.url.path)),
                    finalizeProgress: false)
                switch result {
                case let .completed(_, count, indexed): completed += count; items += indexed
                case let .limited(_, count, indexed): completed += count; items += indexed; limited = true
                case .failed(let message): failures.append(message)
                case .deferred: return .deferred
                case .noChanges: break
                }
            }
            if !failures.isEmpty { return .failed(failures.joined(separator: "\n")) }
            if !limited, completed == orderedRoots.count {
                try await sink.setGlobalLimitReached(false)
                await initialIndexProgress.finish()
                return .completed(mode: mode, roots: completed, items: items)
            }
            await initialIndexProgress.limitReached()
            return .limited(mode: mode, roots: completed, items: items)
        }
        let roots: [FileSearchBackgroundRoot]
        if let requestedRootPaths {
            roots = orderedRoots.filter {
                requestedRootPaths.contains($0.url.standardizedFileURL.path)
            }
        } else { switch mode {
        case .full:
            roots = orderedRoots
        case .incremental:
            let dirtyPaths = try await sink.dirtyPaths(
                limit: configuration.dirtyPathLimit
            )
            if try await !sink.hasUnindexedRoots(orderedRoots.map(\.url)) {
                return try await updateChangedPaths(dirtyPaths, roots: orderedRoots, policy: policy)
            }
            var selectedRootPaths = Set(dirtyPaths.compactMap { dirty -> String? in
                let dirtyPath = dirty.standardizedFileURL.path
                return orderedRoots
                    .filter {
                        Self.path(dirtyPath, isEqualToOrDescendantOf: $0.url.path)
                    }
                    .max { $0.url.pathComponents.count < $1.url.pathComponents.count }?
                    .url.path
            })

            for root in orderedRoots where try await sink.hasUnindexedRoots([root.url]) {
                selectedRootPaths.insert(root.url.path)
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

        var completedRoots = 0
        var totalItems = 0
        var reachedGlobalLimit = false
        let everyAvailableRootPath = orderedRoots.map(\.url.path)

        // Establish a real denominator before indexing. This count pass uses
        // only classification metadata, applies the same exclusions as the
        // index pass, and remains subject to the same activity/CPU/I/O gates.
        await initialIndexProgress.beginCounting(rootCount: roots.count)
        var countedItems = 0
        var inventories: [String: Set<String>] = [:]
        var failedRootPaths: Set<String> = []
        var failures: [String] = []
        for root in roots {
            try Task.checkCancellation()
            let nestedRootsToExclude = everyAvailableRootPath.filter {
                $0 != root.url.path
                    && Self.path($0, isEqualToOrDescendantOf: root.url.path)
            }
            await initialIndexProgress.beginRoot(named: root.url.path)
            do {
                let paths = try await countIndexableItems(
                    in: root,
                    excludedSubtrees: nestedRootsToExclude,
                    maximumItems: max(0, configuration.maximumIndexedItems - countedItems),
                    policy: policy
                )
                inventories[root.url.path] = paths
                countedItems += paths.count
            } catch {
                // A denied/missing directory must not stop unrelated roots.
                // Cancellation and workload deferral still stop the whole run.
                if error is CancellationError || error is FileSearchBackgroundIndexControl {
                    throw error
                }
                failedRootPaths.insert(root.url.path)
                failures.append(Self.rootFailureMessage(root, error: error))
                try await sink.markDirty(root.url)
            }
            await initialIndexProgress.completeRoot()
            if countedItems >= configuration.maximumIndexedItems { break }
        }
        await initialIndexProgress.beginIndexing(
            rootCount: roots.count - failedRootPaths.count,
            totalItemCount: countedItems,
            phase: roots.first?.scope == .applications
                ? .indexingApplications
                : .indexingFiles
        )

        for root in roots where !failedRootPaths.contains(root.url.path) {
            // Preserve older committed generations for lower-priority roots
            // when the global cap is reached. Committing an empty generation
            // here would erase still-useful search results.
            try Task.checkCancellation()
            try checkSystemDeferral(policy: policy)
            guard try await waitForActivityGate(policy: policy) else {
                throw FileSearchBackgroundIndexControl.deferred
            }
            var retainedItemCount = try await sink.committedItemCount(
                excludingRootPath: root.url.path
            )
            let countedPaths = inventories.removeValue(forKey: root.url.path) ?? []
            if root.scope == .applications {
                let needed = min(configuration.maximumIndexedItems, countedPaths.count)
                while configuration.maximumIndexedItems - retainedItemCount < needed {
                    let reclaimed = try await sink.reclaimFileEntries(
                        excludingRootPath: root.url.path,
                        limit: min(512, needed - (configuration.maximumIndexedItems - retainedItemCount))
                    )
                    guard reclaimed > 0 else { break }
                    retainedItemCount -= reclaimed
                    await initialIndexProgress.setCapacityWarning(true)
                    try await throttleAfterWork(processedEntries: reclaimed, policy: policy)
                }
            }
            let remainingCapacity = configuration.maximumIndexedItems
                - retainedItemCount
            guard remainingCapacity > 0 else {
                reachedGlobalLimit = true
                try await sink.setGlobalLimitReached(true)
                break
            }

            await initialIndexProgress.beginRoot(
                named: root.url.path,
                phase: root.scope == .applications ? .indexingApplications : .indexingFiles,
                countedItemCount: countedPaths.count
            )
            let token = try await sink.beginRootGeneration(rootURL: root.url)
            var committed = false
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
                    countedPaths: countedPaths,
                    policy: policy
                )
                try await sink.commitRootGeneration(
                    token,
                    statistics: result.statistics,
                    reachedLimit: result.reachedLimit
                )
                committed = true
                if result.rootChangedDuringScan {
                    // The generation is internally valid, but the directory
                    // changed while it was being walked. Keep a dirty marker
                    // so the next incremental cycle performs a catch-up pass.
                    try await sink.markDirty(root.url)
                }
                await initialIndexProgress.completeRoot(
                    unencounteredItems: result.unencounteredItems
                )
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
                // Once committed, a maintenance failure must not pretend that
                // the new generation was rolled back.
                if committed { throw error }
                do {
                    try await sink.abortRootGeneration(token)
                } catch let abortError {
                    Self.logger.error(
                        "Abort staging generation failed root=\(token.rootPath, privacy: .private): \(abortError.localizedDescription, privacy: .private)"
                    )
                }
                if error is CancellationError || error is FileSearchBackgroundIndexControl {
                    throw error
                }
                failures.append(Self.rootFailureMessage(root, error: error))
                try await sink.markDirty(root.url)
                await initialIndexProgress.completeRoot(failed: true)
            }
        }

        let scannedEveryRetainedRoot = completedRoots == orderedRoots.count
            && Set(roots.map { $0.url.standardizedFileURL.path })
                == Set(orderedRoots.map { $0.url.standardizedFileURL.path })
        if !reachedGlobalLimit, scannedEveryRetainedRoot {
            try await sink.setGlobalLimitReached(false)
        }

        // Files may have disappeared after the count pass. Reconcile the
        // denominator to the work actually encountered, then hide progress
        // only after every successful commit/limit decision has completed.
        await initialIndexProgress.reconcileTotalWithEncounteredItems()
        guard failures.isEmpty else {
            // Healthy roots are already committed; failed roots retain their
            // old generation and dirty marker for a later/manual retry.
            return .failed(failures.joined(separator: "\n"))
        }
        let storedLimit = try await sink.hasReachedLimit()
        if reachedGlobalLimit || (finalizeProgress && storedLimit) {
            await initialIndexProgress.limitReached()
            return .limited(mode: mode, roots: completedRoots, items: totalItems)
        }
        if finalizeProgress { await initialIndexProgress.finish() }

        return .completed(mode: mode, roots: completedRoots, items: totalItems)
    }

    /// A filesystem event replaces only the affected subtree. The staging
    /// generation is never published if a partial scan hits capacity or fails.
    private func updateChangedPaths(
        _ urls: [URL],
        roots: [FileSearchBackgroundRoot],
        policy: FileSearchIndexExecutionPolicy
    ) async throws -> FileSearchBackgroundIndexRunResult {
        let targets = Self.coalescedChangePaths(urls, roots: roots)
        guard !targets.isEmpty else {
            if try await sink.hasReachedLimit() { await initialIndexProgress.limitReached() }
            return .noChanges
        }
        var completed = 0
        var processed = 0
        var limited = false
        var failures: [String] = []
        for target in targets {
            try Task.checkCancellation()
            guard let owner = roots.filter({ Self.path(target.path, isEqualToOrDescendantOf: $0.url.path) })
                .max(by: { $0.url.path.count < $1.url.path.count }) else { continue }
            if target.path == owner.url.path {
                let result = try await execute(
                    mode: .incremental, availableRoots: roots, policy: policy,
                    requestedRootPaths: [owner.url.path]
                )
                switch result {
                case let .completed(_, count, items): completed += count; processed += items
                case let .limited(_, count, items): completed += count; processed += items; limited = true
                case .failed(let message): failures.append(message)
                case .deferred: throw FileSearchBackgroundIndexControl.deferred
                case .noChanges: break
                }
                continue
            }
            let subtree = FileSearchBackgroundRoot(url: target, scope: owner.scope)
            let nested = roots.map(\.url.path).filter {
                $0 != owner.url.path && Self.path($0, isEqualToOrDescendantOf: target.path)
            }
            var token: FileSearchRootGeneration?
            do {
                let exclusions = await MainActor.run { FileSearchExclusionSettings.shared.policy }
                let excluded = Self.isExcludedChange(target, owner: owner, policy: exclusions)
                var missing = false
                do { _ = try target.resourceValues(forKeys: Self.countResourceKeys) }
                catch {
                    guard Self.isMissing(error) else { throw error }
                    missing = true
                }
                await initialIndexProgress.beginCounting(rootCount: 1)
                await initialIndexProgress.beginRoot(named: target.path)
                let inventory = missing || excluded ? Set<String>() : try await countIndexableItems(
                    in: subtree, excludedSubtrees: nested,
                    maximumItems: configuration.maximumIndexedItems, policy: policy
                )
                let oldCount = try await sink.committedItemCount(under: target.path, rootPath: owner.url.path)
                var retained = try await sink.committedItemCount(excludingRootPath: nil) - oldCount
                if owner.scope == .applications || target.pathExtension.lowercased() == "app" {
                    while configuration.maximumIndexedItems - retained < inventory.count {
                        let freed = try await sink.reclaimFileEntries(
                            excludingRootPath: owner.url.path,
                            limit: min(512, inventory.count - (configuration.maximumIndexedItems - retained))
                        )
                        guard freed > 0 else { break }
                        retained -= freed
                        try await throttleAfterWork(processedEntries: freed, policy: policy)
                    }
                }
                let capacity = max(0, configuration.maximumIndexedItems - retained)
                guard inventory.isEmpty || capacity >= inventory.count else {
                    limited = true
                    try await sink.setGlobalLimitReached(true)
                    continue
                }
                await initialIndexProgress.beginIndexing(rootCount: 1, totalItemCount: inventory.count,
                    phase: owner.scope == .applications ? .indexingApplications : .indexingFiles)
                await initialIndexProgress.beginRoot(named: target.path, countedItemCount: inventory.count)
                let generation = try await sink.beginRootGeneration(rootURL: owner.url)
                token = generation
                var result = FileSearchBackgroundRootScanResult()
                if !missing && !excluded {
                    result = try await scanRoot(subtree, token: generation, excludedSubtrees: nested,
                        remainingCapacity: capacity, countedPaths: inventory, policy: policy)
                }
                guard !result.reachedLimit else {
                    try await sink.abortRootGeneration(generation)
                    token = nil
                    try await sink.setGlobalLimitReached(true)
                    limited = true
                    continue
                }
                try await sink.commitSubtreeGeneration(generation, path: target.path)
                token = nil
                if result.rootChangedDuringScan { try await sink.markDirty(target) }
                await initialIndexProgress.completeRoot(unencounteredItems: result.unencounteredItems)
                completed += 1
                processed += result.indexedItems
            } catch {
                if let token { try? await sink.abortRootGeneration(token) }
                if error is CancellationError || error is FileSearchBackgroundIndexControl { throw error }
                failures.append(Self.rootFailureMessage(subtree, error: error))
            }
        }
        if !failures.isEmpty { return .failed(failures.joined(separator: "\n")) }
        let storedLimit = try await sink.hasReachedLimit()
        if limited || storedLimit {
            await initialIndexProgress.limitReached()
            return .limited(mode: .incremental, roots: completed, items: processed)
        }
        await initialIndexProgress.finish()
        return .completed(mode: .incremental, roots: completed, items: processed)
    }

    nonisolated static func coalescedChangePaths(
        _ urls: [URL], roots: [FileSearchBackgroundRoot]
    ) -> [URL] {
        var paths = Set<String>()
        for url in urls {
            var candidate = url.standardizedFileURL
            // Changes inside an application invalidate its bundle metadata,
            // not thousands of package descendants.
            while candidate.pathComponents.count > 1 {
                if candidate.pathExtension.lowercased() == "app" { break }
                if candidate.deletingLastPathComponent().path == "/" { candidate = url.standardizedFileURL; break }
                candidate.deleteLastPathComponent()
            }
            if candidate.pathExtension.lowercased() != "app" { candidate = url.standardizedFileURL }
            guard roots.contains(where: { Self.path(candidate.path, isEqualToOrDescendantOf: $0.url.path) }) else { continue }
            paths.insert(candidate.path)
        }
        func ownerPath(_ path: String) -> String? {
            roots.filter { Self.path(path, isEqualToOrDescendantOf: $0.url.path) }
                .max { $0.url.path.count < $1.url.path.count }?.url.path
        }
        var selected: [String] = []
        for path in paths.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }) {
            if !selected.contains(where: {
                ownerPath(path) == ownerPath($0) && Self.path(path, isEqualToOrDescendantOf: $0)
            }) { selected.append(path) }
        }
        let orderedRoots = Self.orderedDistinctRoots(roots)
        let changedApplications = urls.compactMap { url -> String? in
            var candidate = url.standardizedFileURL
            while candidate.pathComponents.count > 1 {
                if candidate.pathExtension.lowercased() == "app" { return candidate.path }
                candidate.deleteLastPathComponent()
            }
            return nil
        }
        func priority(_ path: String) -> Int {
            // A pending ancestor refresh may absorb a newly installed app's
            // event. Preserve that event's priority after coalescing as well.
            if changedApplications.contains(where: {
                ownerPath($0) == ownerPath(path) && Self.path($0, isEqualToOrDescendantOf: path)
            }) { return -1 }
            let owner = ownerPath(path)
            return orderedRoots.firstIndex { $0.url.path == owner } ?? orderedRoots.count
        }
        return selected.sorted {
            priority($0) == priority($1) ? $0 < $1 : priority($0) < priority($1)
        }.map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func isExcludedChange(
        _ url: URL, owner: FileSearchBackgroundRoot, policy: FileSearchExclusionPolicy
    ) -> Bool {
        var candidate = url.standardizedFileURL
        while candidate.path != owner.url.path && candidate.pathComponents.count > 1 {
            if shouldSkipDescendants(of: candidate, scanningRoot: owner.url)
                || (owner.scope == .files && policy.excludes(candidate, isDirectory: true)) { return true }
            candidate.deleteLastPathComponent()
        }
        return false
    }

    private nonisolated static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }

    private static func rootFailureMessage(
        _ root: FileSearchBackgroundRoot,
        error: Error
    ) -> String {
        L10n.tr("无法索引 %@：%@", root.url.path, error.localizedDescription)
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
            await Task.yield()
            let deletedCount = try await sink.purgeObsoleteEntries(
                for: token,
                limit: 256
            )
            guard deletedCount > 0 else { break }
            try await policy.ioBudget.throttleAfterProcessing(deletedCount)
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
            await Task.yield()
            let deletedCount = try await sink.purgeOrphanedEntries(limit: 256)
            guard deletedCount > 0 else { break }
            try await policy.ioBudget.throttleAfterProcessing(deletedCount)
            try await policy.cpuBudget.throttleAfterBatch()
        }
    }

    private func countIndexableItems(
        in root: FileSearchBackgroundRoot,
        excludedSubtrees: [String],
        maximumItems: Int,
        policy: FileSearchIndexExecutionPolicy
    ) async throws -> Set<String> {
        guard maximumItems > 0 else { return [] }

        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: root.url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let exclusionPolicy = root.scope == .files
            ? await MainActor.run { FileSearchExclusionSettings.shared.policy }
            : FileSearchExclusionPolicy(paths: [])
        var paths: Set<String> = []
        var discoveredSinceProgressUpdate = 0
        var visitedSinceThrottle = 0

        if let values = try? root.url.resourceValues(
               forKeys: Self.countResourceKeys
           ),
           Self.indexableKind(
               url: root.url,
               values: values,
               scope: root.scope
           ) != nil {
            paths.insert(root.url.path)
            discoveredSinceProgressUpdate += 1
        }

        let rootValues = try root.url.resourceValues(forKeys: Self.countResourceKeys)
        if paths.count < maximumItems, rootValues.isDirectory == true,
           rootValues.isPackage != true, root.url.pathExtension.lowercased() != "app" {
            let issues = FileSearchTraversalIssues()
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: Array(Self.countResourceKeys),
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    issues.continueAfter(error, at: url, root: root.url)
                }
            ) else {
                throw CocoaError(.fileReadNoPermission)
            }

            while let url = FileSearchCPUWork.measure({ enumerator.nextObject() as? URL }) {
                try Task.checkCancellation()
                if paths.count >= maximumItems { break }
                visitedSinceThrottle += 1
                try await checkActivityAfterVisitIfNeeded(
                    visitedSinceThrottle,
                    policy: policy
                )

                try FileSearchCPUWork.measure {
                    let path = url.standardizedFileURL.path
                    if excludedSubtrees.contains(where: {
                        Self.path(path, isEqualToOrDescendantOf: $0)
                    }) {
                        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                            enumerator.skipDescendants()
                        }
                    } else if Self.shouldSkipDescendants(of: url, scanningRoot: root.url) {
                        enumerator.skipDescendants()
                    } else {
                        do {
                            let values = try url.resourceValues(forKeys: Self.countResourceKeys)
                            if root.scope == .files,
                               exclusionPolicy.excludes(url, isDirectory: values.isDirectory == true) {
                                if values.isDirectory == true { enumerator.skipDescendants() }
                            } else if Self.indexableKind(url: url, values: values, scope: root.scope) != nil {
                                paths.insert(path)
                                discoveredSinceProgressUpdate += 1
                            }
                        } catch {
                            guard issues.continueAfter(error, at: url, root: root.url) else { throw error }
                            enumerator.skipDescendants()
                        }
                    }
                }

                if visitedSinceThrottle >= policy.batchSize {
                    if discoveredSinceProgressUpdate > 0 {
                        await initialIndexProgress.recordDiscovered(
                            discoveredSinceProgressUpdate
                        )
                        discoveredSinceProgressUpdate = 0
                    }
                    try await throttleAfterWork(
                        processedEntries: visitedSinceThrottle,
                        policy: policy
                    )
                    visitedSinceThrottle = 0
                }
            }

            if let error = issues.fatalError { throw error }
        }

        if discoveredSinceProgressUpdate > 0 {
            await initialIndexProgress.recordDiscovered(
                discoveredSinceProgressUpdate
            )
        }
        if visitedSinceThrottle > 0 {
            try await throttleAfterWork(
                processedEntries: visitedSinceThrottle,
                policy: policy
            )
        }
        return paths
    }

    private func scanRoot(
        _ root: FileSearchBackgroundRoot,
        token: FileSearchRootGeneration,
        excludedSubtrees: [String],
        remainingCapacity: Int,
        countedPaths: Set<String>,
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
        let traversalKeys = root.scope == .applications ? Self.countResourceKeys : keys
        let rootModificationAtStart = try? root.url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let exclusionPolicy = root.scope == .files
            ? await MainActor.run { FileSearchExclusionSettings.shared.policy }
            : FileSearchExclusionPolicy(paths: [])
        var result = FileSearchBackgroundRootScanResult()
        var batch: [FileSearchItem] = []
        batch.reserveCapacity(policy.batchSize)
        var progress = FileSearchRootProgress(remainingPaths: countedPaths)

        let rootValues = try root.url.resourceValues(forKeys: keys)
        if Self.indexableKind(url: root.url, values: rootValues, scope: root.scope) != nil {
            FileSearchCPUWork.measure {
                do {
                    let values = try root.url.resourceValues(forKeys: keys)
                    if let rootItem = Self.makeItem(url: root.url, values: values, fileManager: fileManager) {
                        batch.append(rootItem)
                        progress.encounter(root.url.path)
                        result.indexedItems += 1
                        Self.record(rootItem.kind, in: &result.statistics)
                    }
                } catch {
                    // Metadata failures are counted but do not invalidate a walk.
                    result.statistics.inaccessibleLocations += 1
                    progress.encounter(root.url.path, skipped: true)
                }
            }
        }

        if rootValues.isDirectory != true || rootValues.isPackage == true
            || root.url.pathExtension.lowercased() == "app" {
            await publishProgress(&progress)
            if !batch.isEmpty {
                try await flush(&batch, token: token, processedEntries: batch.count, policy: policy)
            }
            return result
        }

        let issues = FileSearchTraversalIssues()
        var visitedSinceThrottle = 0
        guard let enumerator = fileManager.enumerator(
            at: root.url,
            includingPropertiesForKeys: Array(traversalKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                issues.continueAfter(error, at: url, root: root.url)
            }
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        while let url = FileSearchCPUWork.measure({ enumerator.nextObject() as? URL }) {
            try Task.checkCancellation()
            visitedSinceThrottle += 1
            try await checkActivityAfterVisitIfNeeded(
                visitedSinceThrottle,
                policy: policy
            )

            try FileSearchCPUWork.measure {
                let path = url.standardizedFileURL.path
                if excludedSubtrees.contains(where: { Self.path(path, isEqualToOrDescendantOf: $0) }) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    return
                }
                if Self.shouldSkipDescendants(of: url, scanningRoot: root.url) {
                    enumerator.skipDescendants()
                    result.statistics.skippedGeneratedDirectories += 1
                    return
                }
                do {
                    var values = try url.resourceValues(forKeys: traversalKeys)
                    if root.scope == .files,
                       exclusionPolicy.excludes(url, isDirectory: values.isDirectory == true) {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        return
                    }
                    // Do not resolve localized names/types for ordinary system
                    // files that cannot appear in an applications-only index.
                    guard Self.indexableKind(url: url, values: values, scope: root.scope) != nil else { return }
                    guard result.indexedItems < remainingCapacity else {
                        result.reachedLimit = true
                        return
                    }
                    if root.scope == .applications { values = try url.resourceValues(forKeys: keys) }
                    if let item = Self.makeItem(url: url, values: values, fileManager: fileManager) {
                        batch.append(item)
                        progress.encounter(path)
                        result.indexedItems += 1
                        Self.record(item.kind, in: &result.statistics)
                    }
                } catch {
                    guard issues.continueAfter(error, at: url, root: root.url) else { throw error }
                    enumerator.skipDescendants()
                }
            }

            if result.reachedLimit { break }

            try await throttleIfNeededAfterVisit(
                &visitedSinceThrottle,
                progress: &progress,
                batch: &batch,
                token: token,
                policy: policy
            )
        }

        if let error = issues.fatalError { throw error }
        await publishProgress(&progress)
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

        let inaccessiblePaths = issues.distinctInaccessiblePaths
        result.statistics.inaccessibleLocations += inaccessiblePaths.count
        // Keep only old metadata below unreadable descendants. Never copy an
        // entire old generation, which would resurrect files deleted elsewhere.
        for path in inaccessiblePaths {
            var afterPath: String?
            while true {
                try Task.checkCancellation()
                try checkSystemDeferral(policy: policy)
                guard try await waitForActivityGate(policy: policy) else {
                    throw FileSearchBackgroundIndexControl.deferred
                }
                let preserved = try await sink.preserveCommittedEntries(
                    under: path,
                    excluding: excludedSubtrees + exclusionPolicy.paths,
                    in: token,
                    afterPath: afterPath,
                    limit: min(policy.batchSize, max(0, remainingCapacity - result.indexedItems))
                )
                for entry in preserved.entries {
                    progress.encounter(entry.path)
                    Self.record(entry.kind, in: &result.statistics)
                }
                result.indexedItems += preserved.entries.count
                await publishProgress(&progress)
                await initialIndexProgress.recordIndexed(preserved.entries.count)
                try await throttleAfterWork(processedEntries: preserved.entries.count, policy: policy)
                guard preserved.hasMore else { break }
                guard result.indexedItems < remainingCapacity else {
                    // Abort rather than silently dropping protected old rows
                    // or exceeding the global item limit.
                    throw FileSearchIndexStoreError.unavailable(
                        L10n.tr("索引容量不足，无法安全保留受限目录的旧索引")
                    )
                }
                afterPath = preserved.entries.last?.path
            }
        }
        if result.indexedItems >= remainingCapacity { result.reachedLimit = true }
        let rootModificationAtEnd = try? root.url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        result.rootChangedDuringScan = rootModificationAtStart != rootModificationAtEnd
        // Unseen inventory entries were removed or became excluded after the
        // count pass. Reconcile only a complete walk, never a capped one.
        result.unencounteredItems = result.reachedLimit ? 0 : progress.remainingPaths.count
        return result
    }

    private func throttleIfNeededAfterVisit(
        _ visitedCount: inout Int,
        progress: inout FileSearchRootProgress,
        batch: inout [FileSearchItem],
        token: FileSearchRootGeneration,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        guard visitedCount >= policy.batchSize else { return }
        await publishProgress(&progress)
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

    private func publishProgress(_ progress: inout FileSearchRootProgress) async {
        await initialIndexProgress.recordEncountered(
            progress.encountered,
            newlyDiscovered: progress.additional
        )
        await initialIndexProgress.recordSkipped(progress.skipped)
        progress.encountered = 0
        progress.skipped = 0
        progress.additional = 0
    }

    /// The commit batch can be large during the first index, but explicit PEEK
    /// work must preempt traversal much sooner. This checkpoint observes the
    /// activity gate and accounts for traversal CPU without flushing SQLite.
    private func checkActivityAfterVisitIfNeeded(
        _ visitedCount: Int,
        policy: FileSearchIndexExecutionPolicy
    ) async throws {
        guard activityCheckpointPolicy.shouldCheck(
            afterVisitedEntries: visitedCount
        ) else { return }
        guard try await waitForActivityGate(policy: policy) else {
            throw FileSearchBackgroundIndexControl.deferred
        }
        // The 60-second feedback budget keeps average CPU low, but waiting
        // only after a complete SQLite batch still permits a visible one-second
        // burst during metadata-heavy traversal. Account for CPU every small
        // activity checkpoint as well (16 entries by default). The later batch
        // throttle observes the same baseline, so this does not double-sleep;
        // it simply bounds how much traversal work can run before yielding.
        try await policy.cpuBudget.throttleAfterBatch()
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
        // Yield before the first SQLite write as well as subsequent batches.
        // The feedback budget remains authoritative, while this prevents a
        // newly-started fast pass from monopolizing its executor immediately.
        await Task.yield()
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
            .contentAccessDateKey,
            .localizedNameKey,
            .localizedTypeDescriptionKey
        ]
    }

    private nonisolated static var countResourceKeys: Set<URLResourceKey> {
        [.isDirectoryKey, .isPackageKey, .isRegularFileKey]
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

    private nonisolated static func shouldSkipDescendants(
        of url: URL,
        scanningRoot rootURL: URL
    ) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if [
            "node_modules", "deriveddata", ".build", "caches",
            ".trash", ".cache"
        ].contains(name) {
            return true
        }
        let path = url.standardizedFileURL.path.lowercased()
        let rootPath = rootURL.standardizedFileURL.path.lowercased()
        // Skip app-container trees when they are encountered below a broad
        // authorized root. If the user explicitly selected a directory that
        // is already inside a container (also true for sandboxed test roots),
        // honor that narrower authorization instead of rejecting every child.
        let entersContainers = path.contains("/library/containers/")
            && !rootPath.contains("/library/containers/")
        let entersGroupContainers = path.contains("/library/group containers/")
            && !rootPath.contains("/library/group containers/")
        return path.hasSuffix("/.git/objects")
            || path.hasSuffix("/.git/lfs/objects")
            || entersContainers
            || entersGroupContainers
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
        guard let kind = indexableKind(
            url: url,
            values: values,
            scope: .files
        ) else { return nil }
        let isApplication = kind == .application

        let displayedName = values.localizedName ?? fileManager.displayName(atPath: url.path)
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
        let localizedType = values.localizedTypeDescription

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

    private nonisolated static func indexableKind(
        url: URL,
        values: URLResourceValues,
        scope: FileSearchBackgroundRootScope
    ) -> FileSearchItemKind? {
        let isApplication = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        let kind: FileSearchItemKind?
        if isApplication {
            kind = .application
        } else if values.isDirectory == true, values.isPackage != true {
            kind = .folder
        } else if values.isRegularFile == true || values.isPackage == true {
            kind = .file
        } else {
            kind = nil
        }
        guard scope != .applications || kind == .application else { return nil }
        return kind
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
