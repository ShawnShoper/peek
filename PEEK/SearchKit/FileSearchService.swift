import Foundation
import OSLog

/// Query facade and the only mutation surface shared by the foreground UI and
/// background indexer. Searching never starts a scan and never enumerates a
/// filesystem location; it reads the last committed SQLite generations once
/// and finishes the stream immediately.
actor FileSearchService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "FileSearch"
    )

    private let store: FileSearchIndexStore

    init(store: FileSearchIndexStore = FileSearchIndexStore()) {
        self.store = store
    }

    func search(_ request: FileSearchRequest) -> AsyncStream<FileSearchSnapshot> {
        let store = self.store
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task(priority: .userInitiated) {
                let snapshot: FileSearchSnapshot
                do {
                    let queryResult = try await store.query(request)
                    snapshot = FileSearchSnapshot(
                        request: request,
                        results: queryResult.results,
                        phase: queryResult.metadata.phase,
                        statistics: queryResult.metadata.statistics
                    )
                } catch {
                    let failure = FileSearchFailure.indexUnavailable(
                        error.localizedDescription
                    )
                    Self.logger.error(
                        "SQLite query failed: \(failure.diagnosticMessage, privacy: .private)"
                    )
                    snapshot = FileSearchSnapshot(
                        request: request,
                        results: [],
                        phase: .idle,
                        statistics: FileSearchStatistics(),
                        failure: failure
                    )
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(snapshot)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentSnapshot(for request: FileSearchRequest) async -> FileSearchSnapshot {
        do {
            let queryResult = try await store.query(request)
            return FileSearchSnapshot(
                request: request,
                results: queryResult.results,
                phase: queryResult.metadata.phase,
                statistics: queryResult.metadata.statistics
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
