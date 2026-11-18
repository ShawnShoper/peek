import Foundation
import OSLog

/// Query facade and the only mutation surface shared by the foreground UI and
/// background indexer. Searching never starts a scan and never enumerates a
/// filesystem location. A bounded second read can complete a partial search
/// without occupying the foreground reader or the index writer.
actor FileSearchService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "FileSearch"
    )

    private let store: FileSearchIndexStore
    private let extendedSearchStore: FileSearchIndexStore

    init(store: FileSearchIndexStore = FileSearchIndexStore(), extendedQueryTimeLimit: TimeInterval = 1) {
        self.store = store
        self.extendedSearchStore = FileSearchIndexStore(
            databaseURL: store.databaseURL,
            queryTimeLimit: extendedQueryTimeLimit
        )
    }

    /// Drains pending service work and deterministically releases SQLite file handles.
    func shutdown() async {
        await store.close()
        await extendedSearchStore.close()
    }

    func search(_ request: FileSearchRequest) -> AsyncStream<FileSearchSnapshot> {
        let stores = [store, extendedSearchStore]
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task(priority: .userInitiated) {
                defer { continuation.finish() }
                for (index, store) in stores.enumerated() {
                    guard !Task.isCancelled else { return }
                    let snapshot = await Self.snapshot(for: request, using: store)
                    guard !Task.isCancelled else { return }
                    // Keep the foreground result if the second reader fails.
                    if index == 1, snapshot.failure != nil { return }
                    continuation.yield(snapshot)
                    if !snapshot.isQueryPartial { return }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentSnapshot(for request: FileSearchRequest) async -> FileSearchSnapshot {
        let first = await Self.snapshot(for: request, using: store)
        guard first.isQueryPartial, !Task.isCancelled else { return first }
        let second = await Self.snapshot(for: request, using: extendedSearchStore)
        return second.failure == nil ? second : first
    }

    private static func snapshot(
        for request: FileSearchRequest,
        using store: FileSearchIndexStore
    ) async -> FileSearchSnapshot {
        do {
            let queryResult = try await store.query(request)
            return FileSearchSnapshot(
                request: request,
                results: queryResult.results,
                phase: queryResult.metadata.phase,
                statistics: queryResult.metadata.statistics,
                isQueryPartial: queryResult.isQueryPartial
            )
        } catch {
            let failure = FileSearchFailure.indexUnavailable(error.localizedDescription)
            Self.logger.error(
                "SQLite snapshot failed: \(failure.diagnosticMessage, privacy: .private)"
            )
            return FileSearchSnapshot(
                request: request,
                results: [],
                phase: .idle,
                statistics: FileSearchStatistics(),
                failure: failure
            )
        }
    }

    func indexMetadata() async throws -> FileSearchIndexMetadata {
        try await store.metadata()
    }

    // MARK: - Explicit background-index API

    func beginRootGeneration(rootURL: URL) async throws -> FileSearchRootGeneration {
        try await store.beginRootGeneration(rootURL: rootURL)
    }

    func upsert(
        items: [FileSearchItem],
        generation: FileSearchRootGeneration
    ) async throws {
        try await store.upsert(items, in: generation)
    }

    func commitRootGeneration(
        _ generation: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics = .init(),
        reachedLimit: Bool = false
    ) async throws {
        try await store.commitRootGeneration(
            generation,
            statistics: statistics,
            reachedLimit: reachedLimit
        )
    }

    func abortRootGeneration(_ generation: FileSearchRootGeneration) async throws {
        do {
            try await store.abortRootGeneration(generation)
        } catch {
            Self.logger.error(
                "Abort generation failed for root=\(generation.rootPath, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    func dirtyPaths(limit: Int = 1_000) async throws -> [URL] {
        try await store.dirtyPaths(limit: limit)
    }

    func clearDirtyPaths(_ urls: [URL]) async throws {
        try await store.clearDirtyPaths(urls)
    }

    // MARK: - Cheap foreground mutations (never scan)

    func removeItem(at url: URL) async throws {
        do {
            try await store.removePath(url, includingDescendants: true)
        } catch {
            Self.logger.error(
                "Remove indexed path failed path=\(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    func replaceMovedItem(from sourceURL: URL, to destinationURL: URL) async throws {
        do {
            try await store.movePathPrefix(from: sourceURL, to: destinationURL)
        } catch {
            Self.logger.error(
                "Move indexed path failed source=\(sourceURL.path, privacy: .private) destination=\(destinationURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    /// A copy is intentionally not made searchable synchronously. The next
    /// scheduled background generation consumes this dirty marker.
    func indexItemTree(at rootURL: URL) async throws {
        try await markDirty(rootURL)
    }

    func markDirty(_ url: URL) async throws {
        do {
            try await store.markDirty(url)
        } catch {
            Self.logger.error(
                "Mark dirty failed path=\(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }
}
