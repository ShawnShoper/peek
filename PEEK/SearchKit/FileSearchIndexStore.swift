import Foundation
import SQLite3

struct FileSearchRootGeneration: Hashable, Sendable {
    let rootPath: String
    let generation: Int64
    let dirtyCutoff: Int64

    init(rootPath: String, generation: Int64, dirtyCutoff: Int64) {
        self.rootPath = rootPath
        self.generation = generation
        self.dirtyCutoff = dirtyCutoff
    }

    /// Source compatibility for older tests and callers that constructed a
    /// token with the former wall-clock cutoff. Production tokens always use
    /// the monotonic SQLite revision initializer above.
    init(rootPath: String, generation: Int64, dirtyCutoff: TimeInterval) {
        self.init(
            rootPath: rootPath,
            generation: generation,
            dirtyCutoff: Int64(dirtyCutoff)
        )
    }
}

struct FileSearchRootCommitStatistics: Equatable, Sendable {
    var skippedGeneratedDirectories: Int
    var inaccessibleLocations: Int
    var indexedApplications: Int?
    var indexedFiles: Int?
    var indexedFolders: Int?

    init(
        skippedGeneratedDirectories: Int = 0,
        inaccessibleLocations: Int = 0,
        indexedApplications: Int? = nil,
        indexedFiles: Int? = nil,
        indexedFolders: Int? = nil
    ) {
        self.skippedGeneratedDirectories = skippedGeneratedDirectories
        self.inaccessibleLocations = inaccessibleLocations
        self.indexedApplications = indexedApplications
        self.indexedFiles = indexedFiles
        self.indexedFolders = indexedFolders
    }
}

struct FileSearchIndexMetadata: Equatable, Sendable {
    let phase: FileSearchIndexPhase
    let statistics: FileSearchStatistics
    let committedRootCount: Int
    let indexingRootCount: Int
    let dirtyPathCount: Int
    let lastSuccessfulIndexAt: Date?
}

struct FileSearchRootIndexStatus: Equatable, Sendable {
    let rootPath: String
    let hasCommittedGeneration: Bool
    let isIndexing: Bool
    let indexedItemCount: Int
    let lastSuccessfulIndexAt: Date?
    let inaccessibleLocationCount: Int
    var reachedLimit: Bool = false
}

struct FileSearchPreservedEntry: Equatable, Sendable {
    let path: String
    let kind: FileSearchItemKind
}

struct FileSearchPreservedEntryBatch: Sendable {
    var entries: [FileSearchPreservedEntry] = []
    var hasMore = false
}

struct FileSearchIndexQueryResult: Sendable {
    let results: [FileSearchResult]
    let metadata: FileSearchIndexMetadata
}

enum FileSearchIndexStoreError: LocalizedError {
    case unavailable(String)
    case sqlite(message: String, code: Int32)
    case staleGeneration

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): return message
        case let .sqlite(message, code): return "SQLite \(code): \(message)"
        case .staleGeneration: return L10n.tr("索引 generation 已失效")
        }
    }
}

/// Persistent search index. Opening and migrating SQLite is deliberately lazy:
/// constructing the app graph never performs disk I/O on AppKit's main actor.
/// Each store instance owns one actor-isolated connection. The search provider
/// and background runtime use separate instances, so WAL readers are not
/// serialized behind generation writes.
actor FileSearchIndexStore {
    private static let schemaVersion: Int64 = 7

    nonisolated static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PEEK", isDirectory: true)
            .appendingPathComponent("SearchIndex.sqlite3", isDirectory: false)
    }

    let databaseURL: URL
    private let queryTimeLimit: TimeInterval

    // SQLite is opened FULLMUTEX and every operational access remains actor
    // isolated. The annotation only permits deterministic close from the
    // actor's nonisolated deinitializer under Swift 6.
    nonisolated(unsafe) private var database: OpaquePointer?
    nonisolated(unsafe) private var queryDatabase: OpaquePointer?
    private var lastStartupError: FileSearchIndexStoreError?

    init(
        databaseURL: URL = FileSearchIndexStore.defaultDatabaseURL,
        queryTimeLimit: TimeInterval = 0.18
    ) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.queryTimeLimit = queryTimeLimit.isFinite
            ? min(max(queryTimeLimit, 0.02), 1)
            : 0.18
    }

    deinit {
        if let queryDatabase { sqlite3_close_v2(queryDatabase) }
        if let database { sqlite3_close_v2(database) }
    }

    /// Closes both SQLite connections after all actor-isolated work has drained.
    ///
    /// The app normally keeps the index store alive for its entire process lifetime,
    /// but an explicit close is useful for deterministic shutdown and for tests that
    /// must remove a temporary WAL database before the owning objects are released.
    func close() {
        if let queryDatabase {
            sqlite3_progress_handler(queryDatabase, 0, nil, nil)
            sqlite3_close_v2(queryDatabase)
            self.queryDatabase = nil
        }
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        lastStartupError = nil
    }

    func beginRootGeneration(rootURL: URL) throws -> FileSearchRootGeneration {
        let rootPath = rootURL.standardizedFileURL.path
        return try transaction {
            let previousStaging = try scalarInt64(
                "SELECT staging_generation FROM roots WHERE root_path = ?1",
                strings: [rootPath]
            )
            let previousActive = try scalarInt64(
                "SELECT active_generation FROM roots WHERE root_path = ?1",
                strings: [rootPath]
            ) ?? 0
            let previousEntryGeneration = try scalarInt64(
                "SELECT max(generation) FROM entries WHERE root_path = ?1",
                strings: [rootPath]
            ) ?? 0
            let generation = max(
                previousActive,
                previousStaging ?? 0,
                previousEntryGeneration
            ) + 1
            try execute(
                """
                INSERT INTO roots(root_path, staging_generation)
                VALUES(?1, ?2)
                ON CONFLICT(root_path) DO UPDATE SET
                    staging_generation = excluded.staging_generation
                """,
                bindings: [.text(rootPath), .int64(generation)]
            )
            return FileSearchRootGeneration(
                rootPath: rootPath,
                generation: generation,
                dirtyCutoff: try currentDirtyRevision()
            )
        }
    }

    func upsert(
        _ items: [FileSearchItem],
        in token: FileSearchRootGeneration
    ) throws {
        guard !items.isEmpty else { return }
        try validate(token)
        try transaction {
            let sql = """
            INSERT OR REPLACE INTO entries(
                root_path, generation, path, display_name, kind,
                type_description, is_hidden, file_size, created_at,
                modified_at, last_opened_at, application_version,
                normalized_name, normalized_path, compact_pinyin,
                pinyin_initials, word_initials, normalized_aliases,
                compact_alias_pinyin, alias_pinyin_initials, alias_word_initials
            ) VALUES(
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9,
                ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
                ?18, ?19, ?20, ?21
            )
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for item in items {
                let prepared = FileSearchPreparedItem(item: item)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind([
                    .text(token.rootPath),
                    .int64(token.generation),
                    .text(item.id),
                    .text(item.displayName),
                    .int64(Int64(item.kind.rawValue)),
                    .text(item.typeDescription),
                    .int64(item.isHidden ? 1 : 0),
                    item.fileSize.map(SQLiteBinding.int64) ?? .null,
                    item.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    item.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    item.lastOpenedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    item.applicationVersion.map(SQLiteBinding.text) ?? .null,
                    .text(prepared.normalizedName),
                    .text(prepared.normalizedPath),
                    .text(prepared.compactPinyin),
                    .text(prepared.pinyinInitials),
                    .text(prepared.wordInitials),
                    .text(prepared.normalizedAliasNames),
                    .text(prepared.compactAliasPinyin),
                    .text(prepared.aliasPinyinInitials),
                    .text(prepared.aliasWordInitials)
                ], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError()
                }
            }
        }
    }

    /// Copy only previously committed metadata under an unreadable descendant.
    /// Paging keeps this work cancellable/budgeted by the caller. New readable
    /// entries win, explicit exclusions still apply, and no filesystem access
    /// or broader authorization is implied by preserving existing metadata.
    func preserveCommittedEntries(
        under path: String,
        excluding excludedPaths: [String],
        in token: FileSearchRootGeneration,
        afterPath: String?,
        limit: Int
    ) throws -> FileSearchPreservedEntryBatch {
        guard path.hasPrefix(token.rootPath + "/") else {
            throw FileSearchIndexStoreError.unavailable("Cannot preserve entries outside the indexed root")
        }
        let batchLimit = min(max(0, limit), 512)
        return try transaction {
            try validate(token)
            var bindings: [SQLiteBinding] = [
                .text(token.rootPath), .int64(token.generation), .text(path),
                .text(path + "0"), afterPath.map(SQLiteBinding.text) ?? .null,
                .int64(Int64(batchLimit + 1))
            ]
            var exclusions = ""
            for excluded in Set(excludedPaths).sorted() {
                bindings.append(.text(excluded))
                let parameter = "?\(bindings.count)"
                exclusions += " AND NOT (source.path = \(parameter) OR substr(source.path, 1, length(\(parameter)) + 1) = \(parameter) || '/')"
            }
            // '/' sorts immediately before '0' under SQLite's BINARY collation.
            // The bounded path range enables keyset paging without LIKE escaping
            // bugs for directory names containing %, _ or non-ASCII characters.
            let selection = """
            FROM entries AS source
            WHERE source.root_path = ?1
              AND source.generation = (SELECT active_generation FROM roots WHERE root_path = ?1)
              AND source.path >= ?3 AND source.path < ?4
              AND (source.path = ?3 OR substr(source.path, 1, length(?3) + 1) = ?3 || '/')
              AND (?5 IS NULL OR source.path > ?5)
              AND NOT EXISTS (
                SELECT 1 FROM entries AS staged
                WHERE staged.root_path = ?1 AND staged.generation = ?2 AND staged.path = source.path
              )
              \(exclusions)
            ORDER BY source.path LIMIT ?6
            """
            let statement = try prepare("SELECT source.path, source.kind " + selection)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var entries: [FileSearchPreservedEntry] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                guard let path = columnText(statement, index: 0),
                      let kind = FileSearchItemKind(rawValue: Int(sqlite3_column_int(statement, 1))) else {
                    throw FileSearchIndexStoreError.unavailable("Invalid preserved index entry")
                }
                entries.append(FileSearchPreservedEntry(path: path, kind: kind))
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw sqliteError() }
            let hasMore = entries.count > batchLimit
            if hasMore { entries.removeLast() }
            guard !entries.isEmpty else { return FileSearchPreservedEntryBatch(hasMore: hasMore) }
            try Task.checkCancellation()
            bindings[5] = .int64(Int64(entries.count))
            let columns = """
            path, display_name, kind, type_description, is_hidden, file_size,
            created_at, modified_at, last_opened_at, application_version,
            normalized_name, normalized_path, compact_pinyin, pinyin_initials,
            word_initials, normalized_aliases, compact_alias_pinyin,
            alias_pinyin_initials, alias_word_initials
            """
            try execute(
                "INSERT INTO entries(root_path, generation, \(columns)) SELECT source.root_path, ?2, \(columns) " + selection,
                bindings: bindings
            )
            return FileSearchPreservedEntryBatch(entries: entries, hasMore: hasMore)
        }
    }

    func commitRootGeneration(
        _ token: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics = .init(),
        reachedLimit: Bool = false
    ) throws {
        let indexedApplications = try statistics.indexedApplications ?? stagedCount(
            token: token,
            kind: .application
        )
        let indexedFiles = try statistics.indexedFiles ?? stagedCount(
            token: token,
            kind: .file
        )
        let indexedFolders = try statistics.indexedFolders ?? stagedCount(
            token: token,
            kind: .folder
        )
        try transaction {
            try validate(token)
            try execute(
                """
                UPDATE roots SET
                    active_generation = ?2,
                    staging_generation = NULL,
                    last_success = ?3,
                    skipped_generated = ?4,
                    inaccessible = ?5,
                    reached_limit = ?6,
                    indexed_applications = ?7,
                    indexed_files = ?8,
                    indexed_folders = ?9
                WHERE root_path = ?1
                """,
                bindings: [
                    .text(token.rootPath),
                    .int64(token.generation),
                    .double(Date().timeIntervalSince1970),
                    .int64(Int64(statistics.skippedGeneratedDirectories)),
                    .int64(Int64(statistics.inaccessibleLocations)),
                    .int64(reachedLimit ? 1 : 0),
                    .int64(Int64(indexedApplications)),
                    .int64(Int64(indexedFiles)),
                    .int64(Int64(indexedFolders))
                ]
            )
            try execute(
                """
                DELETE FROM dirty_paths
                WHERE revision <= ?2
                  AND (path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/')
                  AND NOT EXISTS (
                    SELECT 1 FROM roots nested WHERE nested.root_path <> ?1
                      AND substr(nested.root_path, 1, length(?1) + 1) = ?1 || '/'
                      AND (dirty_paths.path = nested.root_path
                        OR substr(dirty_paths.path, 1, length(nested.root_path) + 1) = nested.root_path || '/')
                  )
                """,
                bindings: [.text(token.rootPath), .int64(token.dirtyCutoff)]
            )
        }
    }

    func abortRootGeneration(_ token: FileSearchRootGeneration) throws {
        try transaction {
            let staging = try scalarInt64(
                "SELECT staging_generation FROM roots WHERE root_path = ?1",
                strings: [token.rootPath]
            )
            guard staging == token.generation else { return }
            try execute(
                "UPDATE roots SET staging_generation = NULL WHERE root_path = ?1",
                bindings: [.text(token.rootPath)]
            )
        }
    }

    func query(_ request: FileSearchRequest) throws -> FileSearchIndexQueryResult {
        let queryDatabase = try requireQueryDatabase()
        let queryBudget = FileSearchSQLiteQueryBudget(timeLimit: queryTimeLimit)
        return try cancellableReadTransaction(
            on: queryDatabase,
            budget: queryBudget
        ) {
            try Task.checkCancellation()
            let metadata = try metadata(on: queryDatabase)
            guard metadata.committedRootCount > 0 else {
                return FileSearchIndexQueryResult(results: [], metadata: metadata)
            }

            let normalized = FileSearchMatcher.normalize(request.query)
            let compact = normalized.replacingOccurrences(of: " ", with: "")
            let kinds: [FileSearchItemKind]
            switch request.category {
            case .all: kinds = FileSearchItemKind.allCases
            case .applications: kinds = [.application]
            case .files: kinds = [.file]
            case .folders: kinds = [.folder]
            }

            queryBudget.activateDeadline()
            var candidates: [FileSearchPreparedItem] = []
            let candidateLimit = min(max(request.limit * 16, 256), 2_048)
            for kind in kinds {
                try Task.checkCancellation()
                if Self.shouldUseBoundedPrefixQuery(compactQuery: compact) {
                    candidates.append(contentsOf: try queryPrefixCandidates(
                        kind: kind,
                        normalizedQuery: normalized,
                        compactQuery: compact,
                        limit: candidateLimit,
                        database: queryDatabase,
                        budget: queryBudget
                    ))
                } else {
                    candidates.append(contentsOf: try queryCandidates(
                        kind: kind,
                        normalizedQuery: normalized,
                        compactQuery: compact,
                        limit: candidateLimit,
                        database: queryDatabase,
                        budget: queryBudget
                    ))
                }
                if queryBudget.didExceedDeadline { break }
            }
            return FileSearchIndexQueryResult(
                results: FileSearchMatcher.rank(candidates, request: request),
                metadata: metadata
            )
        }
    }

    func metadata() throws -> FileSearchIndexMetadata {
        try metadata(on: requireQueryDatabase())
    }

    /// Exposes the effective writer limits for diagnostics and regression
    /// tests. Values come from SQLite itself rather than duplicated constants.
    func writerStorageConfiguration() throws -> (tempStore: Int, cacheSize: Int) {
        let database = try requireDatabase()
        return (
            tempStore: Int(try scalarInt64("PRAGMA temp_store", database: database) ?? -1),
            cacheSize: Int(try scalarInt64("PRAGMA cache_size", database: database) ?? 0)
        )
    }

    private func metadata(on database: OpaquePointer) throws -> FileSearchIndexMetadata {
        let committedRootCount = Int(try scalarInt64(
            "SELECT count(*) FROM roots WHERE active_generation IS NOT NULL",
            database: database
        ) ?? 0)
        let indexingRootCount = Int(try scalarInt64(
            "SELECT count(*) FROM roots WHERE staging_generation IS NOT NULL",
            database: database
        ) ?? 0)
        let dirtyPathCount = Int(try scalarInt64(
            "SELECT count(*) FROM dirty_paths",
            database: database
        ) ?? 0)

        var statistics = FileSearchStatistics()
        let rootStatistics = try rows(
            """
            SELECT
                coalesce(sum(indexed_applications), 0),
                coalesce(sum(indexed_files), 0),
                coalesce(sum(indexed_folders), 0),
                coalesce(sum(skipped_generated), 0),
                coalesce(sum(inaccessible), 0),
                coalesce(max(reached_limit), 0),
                max(last_success)
            FROM roots WHERE active_generation IS NOT NULL
            """,
            database: database
        ).first
        statistics.indexedApplications = Int(rootStatistics?[0].int64 ?? 0)
        statistics.indexedFiles = Int(rootStatistics?[1].int64 ?? 0)
        statistics.indexedFolders = Int(rootStatistics?[2].int64 ?? 0)
        statistics.skippedGeneratedDirectories = Int(rootStatistics?[3].int64 ?? 0)
        statistics.inaccessibleLocations = Int(rootStatistics?[4].int64 ?? 0)
        let globalLimitReached = try scalarInt64(
            "SELECT int_value FROM index_state WHERE key = 'global_limit_reached'",
            database: database
        ) == 1
        let reachedLimit = rootStatistics?[5].int64 == 1 || globalLimitReached
        let lastSuccess = rootStatistics?[6].double.map(Date.init(timeIntervalSince1970:))

        let phase: FileSearchIndexPhase
        if committedRootCount == 0 {
            phase = indexingRootCount > 0 ? .indexingFiles : .idle
        } else {
            phase = reachedLimit ? .limited : .ready
        }
        return FileSearchIndexMetadata(
            phase: phase,
            statistics: statistics,
            committedRootCount: committedRootCount,
            indexingRootCount: indexingRootCount,
            dirtyPathCount: dirtyPathCount,
            lastSuccessfulIndexAt: lastSuccess
        )
    }

    func rootStatuses() throws -> [FileSearchRootIndexStatus] {
        let statement = try prepare(
            """
            SELECT
                root_path,
                active_generation IS NOT NULL,
                staging_generation IS NOT NULL,
                indexed_applications + indexed_files + indexed_folders,
                last_success,
                inaccessible,
                reached_limit
            FROM roots
            ORDER BY root_path COLLATE NOCASE
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [FileSearchRootIndexStatus] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let rootPath = columnText(statement, index: 0) {
                result.append(FileSearchRootIndexStatus(
                    rootPath: rootPath,
                    hasCommittedGeneration: sqlite3_column_int(statement, 1) != 0,
                    isIndexing: sqlite3_column_int(statement, 2) != 0,
                    indexedItemCount: Int(sqlite3_column_int64(statement, 3)),
                    lastSuccessfulIndexAt: optionalDate(statement, index: 4),
                    inaccessibleLocationCount: Int(sqlite3_column_int64(statement, 5)),
                    reachedLimit: sqlite3_column_int(statement, 6) != 0
                ))
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw sqliteError()
        }
        return result
    }

    func committedItemCount(excludingRootPath: String? = nil) throws -> Int {
        let sql = """
        SELECT coalesce(sum(
            indexed_applications + indexed_files + indexed_folders
        ), 0)
        FROM roots
        WHERE active_generation IS NOT NULL
        \(excludingRootPath == nil ? "" : "AND root_path <> ?1")
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let excludingRootPath {
            try bind([.text(excludingRootPath)], to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw sqliteError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Cheap foreground mutation. No filesystem reads are performed.
    func removePath(_ url: URL, includingDescendants: Bool = true) throws {
        let path = url.standardizedFileURL.path
        try transaction {
            let suffix = includingDescendants
                ? " OR substr(path, 1, length(?1) + 1) = ?1 || '/'"
                : ""
            let affected = try rows("SELECT DISTINCT root_path FROM entries WHERE path = ?1\(suffix)", bindings: [.text(path)])
            try execute(
                "DELETE FROM entries WHERE path = ?1\(suffix)",
                bindings: [.text(path)]
            )
            try insertDirtyPath(path)
            for row in affected { if let root = row[0].text { try refreshCommittedCounts(root) } }
        }
    }

    /// Rewrites already indexed rows after a successful move. It never walks
    /// the destination tree; any later divergence is handled by the scheduled
    /// background generation.
    func movePathPrefix(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL.path
        let destination = destinationURL.standardizedFileURL.path
        guard source != destination else { return }
        try transaction {
            let affected = try rows("""
                SELECT DISTINCT root_path FROM entries
                WHERE path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'
                   OR path = ?2 OR substr(path, 1, length(?2) + 1) = ?2 || '/'
                """, bindings: [.text(source), .text(destination)])
            let sourceRoot = try scalarText(
                """
                SELECT root_path FROM entries
                WHERE path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'
                ORDER BY length(path) ASC LIMIT 1
                """,
                strings: [source]
            )
            try execute(
                "DELETE FROM entries WHERE path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'",
                bindings: [.text(destination)]
            )
            if let sourceRoot,
               destination == sourceRoot || destination.hasPrefix(sourceRoot + "/") {
                try execute(
                    """
                    UPDATE OR REPLACE entries SET
                        path = ?2 || substr(path, length(?1) + 1),
                        normalized_path = lower(?2 || substr(path, length(?1) + 1))
                    WHERE path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'
                    """,
                    bindings: [.text(source), .text(destination)]
                )
            } else {
                // A destination outside the source's authorized root must not
                // remain searchable under the old root permission. The next
                // scheduled pass may add it only if another retained root
                // actually authorizes that destination.
                try execute(
                    "DELETE FROM entries WHERE path = ?1 OR substr(path, 1, length(?1) + 1) = ?1 || '/'",
                    bindings: [.text(source)]
                )
            }
            try insertDirtyPath(source)
            try insertDirtyPath(destination)
            for row in affected { if let root = row[0].text { try refreshCommittedCounts(root) } }
        }
    }

    func markDirty(_ url: URL) throws {
        try insertDirtyPath(url.standardizedFileURL.path)
    }

    /// Cursor and dirty paths advance atomically: a crash may replay work but
    /// cannot acknowledge filesystem events that have not reached SQLite.
    func recordFileEvents(_ urls: [URL], cursor: UInt64) throws {
        try transaction {
            for url in urls { try insertDirtyPath(url.standardizedFileURL.path) }
            try execute("INSERT INTO index_state(key, int_value) VALUES('event_cursor', ?1) ON CONFLICT(key) DO UPDATE SET int_value = max(int_value, excluded.int_value)",
                        bindings: [.int64(Int64(clamping: cursor))])
        }
    }

    func fileEventCursor() throws -> UInt64? {
        try scalarInt64("SELECT int_value FROM index_state WHERE key = 'event_cursor'")
            .map { UInt64(max(0, $0)) }
    }

    func committedItemCount(under path: String, rootPath: String) throws -> Int {
        Int(try scalarInt64("""
            SELECT count(*) FROM entries e JOIN roots r ON r.root_path = e.root_path
            WHERE e.root_path = ?1 AND e.generation = r.active_generation
              AND (e.path = ?2 OR e.path >= ?2 || '/' AND e.path < ?2 || '0')
            """, strings: [rootPath, path]) ?? 0)
    }

    /// Evict only cached non-application metadata, never filesystem content.
    /// Broad roots yield first; restricted roots are never used as donors.
    func reclaimFileEntries(excludingRootPath: String, limit: Int) throws -> Int {
        try transaction {
            let victims = try rows("""
                SELECT e.path, e.root_path, e.generation FROM entries e JOIN roots r ON r.root_path = e.root_path
                WHERE e.generation = r.active_generation AND e.kind <> ?1
                  AND e.root_path <> ?2 AND r.staging_generation IS NULL AND r.inaccessible = 0
                ORDER BY length(e.root_path), e.path DESC LIMIT ?3
                """, bindings: [.int64(Int64(FileSearchItemKind.application.rawValue)),
                                 .text(excludingRootPath), .int64(Int64(min(512, max(0, limit))))])
            var affected = Set<String>()
            for row in victims {
                guard let path = row[0].text, let root = row[1].text, let generation = row[2].int64 else { continue }
                try execute("DELETE FROM entries WHERE root_path = ?1 AND generation = ?2 AND path = ?3",
                            bindings: [.text(root), .int64(generation), .text(path)])
                affected.insert(root)
            }
            for root in affected {
                try refreshCommittedCounts(root)
                try execute("UPDATE roots SET reached_limit = 1 WHERE root_path = ?1", bindings: [.text(root)])
            }
            if !victims.isEmpty { try setGlobalLimitReachedInTransaction() }
            return victims.count
        }
    }

    private func setGlobalLimitReachedInTransaction() throws {
        try execute("INSERT INTO index_state(key, int_value) VALUES('global_limit_reached', 1) ON CONFLICT(key) DO UPDATE SET int_value = 1")
    }

    private func refreshCommittedCounts(_ root: String) throws {
        try execute("""
            UPDATE roots SET
              indexed_applications = (SELECT count(*) FROM entries WHERE root_path = ?1 AND generation = roots.active_generation AND kind = 0),
              indexed_files = (SELECT count(*) FROM entries WHERE root_path = ?1 AND generation = roots.active_generation AND kind = 1),
              indexed_folders = (SELECT count(*) FROM entries WHERE root_path = ?1 AND generation = roots.active_generation AND kind = 2)
            WHERE root_path = ?1
            """, bindings: [.text(root)])
    }

    /// Publish just one changed subtree, keeping unrelated rows and generation
    /// stable. Revision cutoffs preserve events arriving while it is scanned.
    func commitSubtreeGeneration(_ token: FileSearchRootGeneration, path: String) throws {
        guard path != token.rootPath, path.hasPrefix(token.rootPath + "/") else {
            throw FileSearchIndexStoreError.staleGeneration
        }
        try transaction {
            try validate(token)
            guard let active = try scalarInt64("SELECT active_generation FROM roots WHERE root_path = ?1", strings: [token.rootPath]) else {
                throw FileSearchIndexStoreError.staleGeneration
            }
            try execute("""
                DELETE FROM entries WHERE root_path = ?1 AND generation = ?2
                  AND (path = ?3 OR path >= ?3 || '/' AND path < ?3 || '0')
                """, bindings: [.text(token.rootPath), .int64(active), .text(path)])
            try execute("UPDATE entries SET generation = ?3 WHERE root_path = ?1 AND generation = ?2",
                        bindings: [.text(token.rootPath), .int64(token.generation), .int64(active)])
            try execute("UPDATE roots SET staging_generation = NULL WHERE root_path = ?1", bindings: [.text(token.rootPath)])
            try refreshCommittedCounts(token.rootPath)
            try execute("""
                DELETE FROM dirty_paths WHERE revision <= ?2
                  AND (path = ?1 OR path >= ?1 || '/' AND path < ?1 || '0')
                """, bindings: [.text(path), .int64(token.dirtyCutoff)])
        }
    }

    func dirtyPaths(limit: Int = 1_000) throws -> [URL] {
        let statement = try prepare(
            "SELECT path FROM dirty_paths ORDER BY CASE WHEN lower(path) LIKE '%.app' THEN 0 ELSE 1 END, revision ASC LIMIT ?1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.int64(Int64(max(1, min(limit, 10_000))))], to: statement)
        var result: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, index: 0) {
                result.append(URL(fileURLWithPath: path))
            }
        }
        return result
    }

    func clearDirtyPaths(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        try transaction {
            let statement = try prepare("DELETE FROM dirty_paths WHERE path = ?1")
            defer { sqlite3_finalize(statement) }
            for url in urls {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind([.text(url.standardizedFileURL.path)], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError()
                }
            }
        }
    }

    func setGlobalLimitReached(_ reached: Bool) throws {
        try transaction {
            try execute(
                """
                INSERT INTO index_state(key, int_value)
                VALUES('global_limit_reached', ?1)
                ON CONFLICT(key) DO UPDATE SET int_value = excluded.int_value
                """,
                bindings: [.int64(reached ? 1 : 0)]
            )
        }
    }

    /// Deletes at most `limit` invisible rows. The background indexer invokes
    /// this between CPU-budget sleeps instead of doing an unbounded DELETE in
    /// the generation commit transaction.
    func purgeObsoleteEntries(
        for token: FileSearchRootGeneration,
        limit: Int
    ) throws -> Int {
        let changed = try executeChangeCount(
            """
            DELETE FROM entries
            WHERE (root_path, generation, path) IN (
                SELECT root_path, generation, path FROM entries
                WHERE root_path = ?1 AND generation <> ?2
                LIMIT ?3
            )
            """,
            bindings: [
                .text(token.rootPath),
                .int64(token.generation),
                .int64(Int64(max(1, min(limit, 256))))
            ]
        )
        return changed
    }

    func purgeOrphanedEntries(limit: Int) throws -> Int {
        let changed = try executeChangeCount(
            """
            DELETE FROM entries
            WHERE (root_path, generation, path) IN (
                SELECT e.root_path, e.generation, e.path FROM entries e
                LEFT JOIN roots r ON r.root_path = e.root_path
                WHERE r.root_path IS NULL
                   OR (
                        (r.active_generation IS NULL OR e.generation <> r.active_generation)
                    AND (r.staging_generation IS NULL OR e.generation <> r.staging_generation)
                   )
                LIMIT ?1
            )
            """,
            bindings: [.int64(Int64(max(1, min(limit, 256))))]
        )
        return changed
    }

    /// Removes committed metadata for roots that are no longer authorized and
    /// records newly authorized roots for the next incremental cycle. This is
    /// SQL-only; it never reads a filesystem location.
    func reconcileRoots(retaining rootURLs: [URL]) throws {
        let retainedPaths = Set(rootURLs.map { $0.standardizedFileURL.path })
        try transaction {
            let existingRoots = try textValues("SELECT root_path FROM roots")
            for path in existingRoots where !retainedPaths.contains(path) {
                try execute(
                    "DELETE FROM roots WHERE root_path = ?1",
                    bindings: [.text(path)]
                )
            }

            let activeRoots = Set(try textValues(
                "SELECT root_path FROM roots WHERE active_generation IS NOT NULL"
            ))
            for path in retainedPaths where !activeRoots.contains(path) {
                try insertDirtyPath(path)
            }

            let dirtyPaths = try textValues("SELECT path FROM dirty_paths")
            for dirtyPath in dirtyPaths where !retainedPaths.contains(where: {
                dirtyPath == $0 || dirtyPath.hasPrefix($0 + "/")
            }) {
                try execute(
                    "DELETE FROM dirty_paths WHERE path = ?1",
                    bindings: [.text(dirtyPath)]
                )
            }
        }
    }

    private func queryCandidates(
        kind: FileSearchItemKind,
        normalizedQuery: String,
        compactQuery: String,
        limit: Int,
        database: OpaquePointer,
        budget: FileSearchSQLiteQueryBudget
    ) throws -> [FileSearchPreparedItem] {
        let baseSelect = """
        SELECT
            e.path, e.display_name, e.kind, e.type_description, e.is_hidden,
            e.file_size, e.created_at, e.modified_at, e.last_opened_at,
            e.application_version, e.normalized_name, e.normalized_path,
            e.compact_pinyin, e.pinyin_initials, e.word_initials,
            e.normalized_aliases, e.compact_alias_pinyin,
            e.alias_pinyin_initials, e.alias_word_initials
        FROM entries e
        JOIN roots r ON r.root_path = e.root_path
            AND r.active_generation = e.generation
        WHERE e.kind = ?1
        """
        let sql: String
        var bindings: [SQLiteBinding] = [.int64(Int64(kind.rawValue))]
        if normalizedQuery.isEmpty {
            sql = baseSelect + """
            GROUP BY e.path
            ORDER BY e.normalized_name COLLATE NOCASE, e.path COLLATE NOCASE
            LIMIT ?2
            """
            bindings.append(.int64(Int64(limit)))
        } else {
            let containsName = "%\(escapeLike(normalizedQuery))%"
            let containsCompact = "%\(escapeLike(compactQuery))%"
            let subsequence = subsequenceLikePattern(compactQuery)
            sql = baseSelect + """
            AND (
                e.normalized_name LIKE ?2 ESCAPE '\\'
                OR replace(e.normalized_name, ' ', '') LIKE ?3 ESCAPE '\\'
                OR replace(e.normalized_name, ' ', '') LIKE ?4 ESCAPE '\\'
                OR e.compact_pinyin LIKE ?3 ESCAPE '\\'
                OR e.compact_pinyin LIKE ?4 ESCAPE '\\'
                OR e.pinyin_initials LIKE ?3 ESCAPE '\\'
                OR e.pinyin_initials LIKE ?4 ESCAPE '\\'
                OR e.word_initials LIKE ?3 ESCAPE '\\'
                OR e.word_initials LIKE ?4 ESCAPE '\\'
                OR e.normalized_aliases LIKE ?2 ESCAPE '\\'
                OR e.normalized_aliases LIKE ?3 ESCAPE '\\'
                OR e.normalized_aliases LIKE ?4 ESCAPE '\\'
                OR e.compact_alias_pinyin LIKE ?3 ESCAPE '\\'
                OR e.compact_alias_pinyin LIKE ?4 ESCAPE '\\'
                OR e.alias_pinyin_initials LIKE ?3 ESCAPE '\\'
                OR e.alias_pinyin_initials LIKE ?4 ESCAPE '\\'
                OR e.alias_word_initials LIKE ?3 ESCAPE '\\'
                OR e.alias_word_initials LIKE ?4 ESCAPE '\\'
                OR e.normalized_path LIKE ?2 ESCAPE '\\'
            )
            GROUP BY e.path
            ORDER BY
                CASE
                    WHEN e.normalized_name = ?5 THEN 0
                    WHEN replace(e.normalized_name, ' ', '') = ?6 THEN 0
                    WHEN e.normalized_name LIKE ?7 ESCAPE '\\' THEN 1
                    WHEN e.normalized_aliases LIKE ?2 ESCAPE '\\' THEN 1
                    WHEN e.compact_pinyin = ?6 THEN 2
                    WHEN e.compact_alias_pinyin LIKE ?3 ESCAPE '\\' THEN 2
                    WHEN e.pinyin_initials = ?6 THEN 3
                    WHEN e.alias_pinyin_initials LIKE ?3 ESCAPE '\\' THEN 3
                    WHEN e.word_initials = ?6 THEN 4
                    WHEN e.alias_word_initials LIKE ?3 ESCAPE '\\' THEN 4
                    ELSE 5
                END,
                length(e.normalized_name), e.normalized_name COLLATE NOCASE
            LIMIT ?8
            """
            bindings.append(contentsOf: [
                .text(containsName),
                .text(containsCompact),
                .text(subsequence),
                .text(normalizedQuery),
                .text(compactQuery),
                .text("\(escapeLike(normalizedQuery))%"),
                .int64(Int64(limit))
            ])
        }

        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        return try preparedItems(
            from: statement,
            database: database,
            budget: budget
        )
    }

    /// One-character queries are the highest-frequency and least-selective
    /// case. Running every leading-wildcard/subsequence predicate for them
    /// scales linearly with the complete index, so use indexed prefix ranges.
    /// Multi-character searches keep the full contains/pinyin/fuzzy semantics.
    private func queryPrefixCandidates(
        kind: FileSearchItemKind,
        normalizedQuery: String,
        compactQuery: String,
        limit: Int,
        database: OpaquePointer,
        budget: FileSearchSQLiteQueryBudget
    ) throws -> [FileSearchPreparedItem] {
        let normalizedUpperBound = prefixUpperBound(for: normalizedQuery)
        let compactUpperBound = prefixUpperBound(for: compactQuery)
        let sql = """
        SELECT
            e.path, e.display_name, e.kind, e.type_description, e.is_hidden,
            e.file_size, e.created_at, e.modified_at, e.last_opened_at,
            e.application_version, e.normalized_name, e.normalized_path,
            e.compact_pinyin, e.pinyin_initials, e.word_initials,
            e.normalized_aliases, e.compact_alias_pinyin,
            e.alias_pinyin_initials, e.alias_word_initials
        FROM entries e
        JOIN roots r ON r.root_path = e.root_path
            AND r.active_generation = e.generation
        WHERE e.kind = ?1
          AND (
              (e.normalized_name >= ?2 AND e.normalized_name < ?3)
              OR (e.compact_pinyin >= ?4 AND e.compact_pinyin < ?5)
              OR (e.pinyin_initials >= ?4 AND e.pinyin_initials < ?5)
              OR (e.word_initials >= ?4 AND e.word_initials < ?5)
              OR (e.normalized_aliases >= ?2 AND e.normalized_aliases < ?3)
              OR (e.compact_alias_pinyin >= ?4 AND e.compact_alias_pinyin < ?5)
              OR (e.alias_pinyin_initials >= ?4 AND e.alias_pinyin_initials < ?5)
              OR (e.alias_word_initials >= ?4 AND e.alias_word_initials < ?5)
              OR (e.normalized_path >= ?2 AND e.normalized_path < ?3)
          )
        GROUP BY e.path
        ORDER BY
            CASE
                WHEN e.normalized_name = ?2 THEN 0
                WHEN e.normalized_name >= ?2 AND e.normalized_name < ?3 THEN 1
                WHEN e.compact_pinyin = ?4 THEN 2
                WHEN e.compact_pinyin >= ?4 AND e.compact_pinyin < ?5 THEN 3
                WHEN e.pinyin_initials >= ?4 AND e.pinyin_initials < ?5 THEN 4
                WHEN e.normalized_aliases = ?2 THEN 1
                WHEN e.normalized_aliases >= ?2 AND e.normalized_aliases < ?3 THEN 2
                WHEN e.compact_alias_pinyin >= ?4 AND e.compact_alias_pinyin < ?5 THEN 3
                WHEN e.alias_pinyin_initials >= ?4 AND e.alias_pinyin_initials < ?5 THEN 4
                WHEN e.normalized_path >= ?2 AND e.normalized_path < ?3 THEN 6
                ELSE 7
            END,
            length(e.normalized_name), e.normalized_name COLLATE NOCASE
        LIMIT ?6
        """
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind([
            .int64(Int64(kind.rawValue)),
            .text(normalizedQuery),
            .text(normalizedUpperBound),
            .text(compactQuery),
            .text(compactUpperBound),
            .int64(Int64(limit))
        ], to: statement)
        return try preparedItems(
            from: statement,
            database: database,
            budget: budget
        )
    }

    private func preparedItems(
        from statement: OpaquePointer,
        database: OpaquePointer,
        budget: FileSearchSQLiteQueryBudget
    ) throws -> [FileSearchPreparedItem] {
        var items: [FileSearchPreparedItem] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            if result == SQLITE_INTERRUPT, budget.didExceedDeadline {
                // A read-only SELECT may safely keep rows already emitted.
                // The unprocessed tail is intentionally omitted this time.
                break
            }
            guard result == SQLITE_ROW else {
                throw queryError(for: result, database: database)
            }
            guard let path = columnText(statement, index: 0),
                  let name = columnText(statement, index: 1),
                  let itemKind = FileSearchItemKind(
                    rawValue: Int(sqlite3_column_int64(statement, 2))
                  ) else { continue }
            let item = FileSearchItem(
                url: URL(fileURLWithPath: path),
                displayName: name,
                kind: itemKind,
                typeDescription: columnText(statement, index: 3) ?? "",
                isHidden: sqlite3_column_int64(statement, 4) != 0,
                fileSize: optionalInt64(statement, index: 5),
                createdAt: optionalDate(statement, index: 6),
                modifiedAt: optionalDate(statement, index: 7),
                lastOpenedAt: optionalDate(statement, index: 8),
                applicationVersion: columnText(statement, index: 9)
            )
            items.append(FileSearchPreparedItem(
                item: item,
                normalizedName: columnText(statement, index: 10) ?? "",
                normalizedPath: columnText(statement, index: 11) ?? "",
                compactPinyin: columnText(statement, index: 12) ?? "",
                pinyinInitials: columnText(statement, index: 13) ?? "",
                wordInitials: columnText(statement, index: 14) ?? "",
                normalizedAliasNames: columnText(statement, index: 15) ?? "",
                compactAliasPinyin: columnText(statement, index: 16) ?? "",
                aliasPinyinInitials: columnText(statement, index: 17) ?? "",
                aliasWordInitials: columnText(statement, index: 18) ?? ""
            ))
        }
        return items
    }

    nonisolated static func shouldUseBoundedPrefixQuery(
        compactQuery: String
    ) -> Bool {
        compactQuery.count == 1
    }

    private func prefixUpperBound(for value: String) -> String {
        value + "\u{10FFFF}"
    }

    private func validate(_ token: FileSearchRootGeneration) throws {
        let staging = try scalarInt64(
            "SELECT staging_generation FROM roots WHERE root_path = ?1",
            strings: [token.rootPath]
        )
        guard staging == token.generation else {
            throw FileSearchIndexStoreError.staleGeneration
        }
    }

    private func stagedCount(
        token: FileSearchRootGeneration,
        kind: FileSearchItemKind
    ) throws -> Int {
        Int(try scalarInt64(
            """
            SELECT count(*) FROM entries
            WHERE root_path = ?1 AND generation = ?2 AND kind = ?3
            """,
            bindings: [
                .text(token.rootPath),
                .int64(token.generation),
                .int64(Int64(kind.rawValue))
            ]
        ) ?? 0)
    }

    private func insertDirtyPath(_ path: String) throws {
        let revision = try nextDirtyRevision()
        try execute(
            """
            INSERT INTO dirty_paths(path, revision) VALUES(?1, ?2)
            ON CONFLICT(path) DO UPDATE SET revision = excluded.revision
            """,
            bindings: [.text(path), .int64(revision)]
        )
    }

    private func currentDirtyRevision() throws -> Int64 {
        try scalarInt64(
            "SELECT int_value FROM index_state WHERE key = 'dirty_revision'"
        ) ?? 0
    }

    private func nextDirtyRevision() throws -> Int64 {
        try execute(
            """
            INSERT INTO index_state(key, int_value)
            VALUES('dirty_revision', 1)
            ON CONFLICT(key) DO UPDATE SET int_value = int_value + 1
            """
        )
        return try currentDirtyRevision()
    }

    private nonisolated static func configureAndMigrate(
        _ database: OpaquePointer
    ) throws {
        func run(_ sql: String) throws {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(errorMessage)
                throw FileSearchIndexStoreError.sqlite(
                    message: message,
                    code: result
                )
            }
        }

        func scalarInt64(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(
                database,
                sql,
                -1,
                &statement,
                nil
            )
            guard prepareResult == SQLITE_OK, let statement else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: prepareResult
                )
            }
            defer { sqlite3_finalize(statement) }
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: stepResult
                )
            }
            return sqlite3_column_int64(statement, 0)
        }

        func schemaObjectExists(type: String, name: String) throws -> Bool {
            var statement: OpaquePointer?
            let sql = "SELECT 1 FROM sqlite_master WHERE type = ?1 AND name = ?2 LIMIT 1"
            let prepareResult = sqlite3_prepare_v2(
                database,
                sql,
                -1,
                &statement,
                nil
            )
            guard prepareResult == SQLITE_OK, let statement else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: prepareResult
                )
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(
                statement,
                1,
                type,
                -1,
                sqliteTransient
            ) == SQLITE_OK,
            sqlite3_bind_text(
                statement,
                2,
                name,
                -1,
                sqliteTransient
            ) == SQLITE_OK else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: sqlite3_errcode(database)
                )
            }
            return sqlite3_step(statement) == SQLITE_ROW
        }

        func columnExists(table: String, column: String) throws -> Bool {
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(
                database,
                "PRAGMA table_info(\(table))",
                -1,
                &statement,
                nil
            )
            guard prepareResult == SQLITE_OK, let statement else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: prepareResult
                )
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 1) else {
                    continue
                }
                if String(cString: rawName) == column { return true }
            }
            return false
        }

        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA synchronous=NORMAL")
        try run("PRAGMA foreign_keys=ON")
        try run("PRAGMA busy_timeout=5000")
        // Index creation and large write transactions may need temporary sort
        // storage. Keep that spillable and cap SQLite's writer page cache so a
        // first-launch migration cannot create a large transient RSS spike.
        try run("PRAGMA temp_store=FILE")
        try run("PRAGMA cache_size=-16384")
        let originalVersion = try scalarInt64("PRAGMA user_version")
        let hadRootsTable = try schemaObjectExists(type: "table", name: "roots")
        let hadDirtyPathsTable = try schemaObjectExists(
            type: "table",
            name: "dirty_paths"
        )

        try run("BEGIN IMMEDIATE")
        do {
            try run(
                """
                CREATE TABLE IF NOT EXISTS roots(
                    root_path TEXT PRIMARY KEY NOT NULL,
                    active_generation INTEGER,
                    staging_generation INTEGER,
                    last_success REAL,
                    skipped_generated INTEGER NOT NULL DEFAULT 0,
                    inaccessible INTEGER NOT NULL DEFAULT 0,
                    reached_limit INTEGER NOT NULL DEFAULT 0,
                    indexed_applications INTEGER NOT NULL DEFAULT 0,
                    indexed_files INTEGER NOT NULL DEFAULT 0,
                    indexed_folders INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try run(
                """
                CREATE TABLE IF NOT EXISTS entries(
                    root_path TEXT NOT NULL,
                    generation INTEGER NOT NULL,
                    path TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    kind INTEGER NOT NULL,
                    type_description TEXT NOT NULL,
                    is_hidden INTEGER NOT NULL,
                    file_size INTEGER,
                    created_at REAL,
                    modified_at REAL,
                    last_opened_at REAL,
                    application_version TEXT,
                    normalized_name TEXT NOT NULL,
                    normalized_path TEXT NOT NULL,
                    compact_pinyin TEXT NOT NULL,
                    pinyin_initials TEXT NOT NULL,
                    word_initials TEXT NOT NULL,
                    normalized_aliases TEXT NOT NULL DEFAULT '',
                    compact_alias_pinyin TEXT NOT NULL DEFAULT '',
                    alias_pinyin_initials TEXT NOT NULL DEFAULT '',
                    alias_word_initials TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(root_path, generation, path)
                ) WITHOUT ROWID
                """
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_generation_kind ON entries(root_path, generation, kind)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_name ON entries(kind, normalized_name)"
            )
            // These B-tree indexes back the bounded one-character prefix path.
            // Longer queries deliberately retain the full fuzzy matcher below.
            try run(
                "CREATE INDEX IF NOT EXISTS entries_compact_pinyin ON entries(kind, compact_pinyin)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_pinyin_initials ON entries(kind, pinyin_initials)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_word_initials ON entries(kind, word_initials)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_path ON entries(kind, normalized_path)"
            )

            // v3 added committed per-root counts. Defaults cannot describe an
            // already active legacy generation, so those generations are
            // invalidated below instead of remaining query-visible with zero
            // metadata counts.
            if try !columnExists(table: "roots", column: "indexed_applications") {
                try run(
                    "ALTER TABLE roots ADD COLUMN indexed_applications INTEGER NOT NULL DEFAULT 0"
                )
            }
            if try !columnExists(table: "roots", column: "indexed_files") {
                try run(
                    "ALTER TABLE roots ADD COLUMN indexed_files INTEGER NOT NULL DEFAULT 0"
                )
            }
            if try !columnExists(table: "roots", column: "indexed_folders") {
                try run(
                    "ALTER TABLE roots ADD COLUMN indexed_folders INTEGER NOT NULL DEFAULT 0"
                )
            }
            if try !columnExists(table: "entries", column: "normalized_aliases") {
                try run(
                    "ALTER TABLE entries ADD COLUMN normalized_aliases TEXT NOT NULL DEFAULT ''"
                )
            }
            if try !columnExists(table: "entries", column: "compact_alias_pinyin") {
                try run(
                    "ALTER TABLE entries ADD COLUMN compact_alias_pinyin TEXT NOT NULL DEFAULT ''"
                )
            }
            if try !columnExists(table: "entries", column: "alias_pinyin_initials") {
                try run(
                    "ALTER TABLE entries ADD COLUMN alias_pinyin_initials TEXT NOT NULL DEFAULT ''"
                )
            }
            if try !columnExists(table: "entries", column: "alias_word_initials") {
                try run(
                    "ALTER TABLE entries ADD COLUMN alias_word_initials TEXT NOT NULL DEFAULT ''"
                )
            }
            // Legacy databases do not have the alias columns. Create their
            // indexes only after every ALTER TABLE above has succeeded.
            try run(
                "CREATE INDEX IF NOT EXISTS entries_aliases ON entries(kind, normalized_aliases)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_alias_pinyin ON entries(kind, compact_alias_pinyin)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_alias_pinyin_initials ON entries(kind, alias_pinyin_initials)"
            )
            try run(
                "CREATE INDEX IF NOT EXISTS entries_alias_word_initials ON entries(kind, alias_word_initials)"
            )
            try run(
                """
                CREATE TABLE IF NOT EXISTS index_state(
                    key TEXT PRIMARY KEY NOT NULL,
                    int_value INTEGER NOT NULL
                )
                """
            )

            // v4 replaces wall-clock dirty markers with a database-local,
            // monotonic revision. This remains correct if system time moves
            // backwards while a root generation is being built.
            if !hadDirtyPathsTable {
                try run(
                    """
                    CREATE TABLE dirty_paths(
                        path TEXT PRIMARY KEY NOT NULL,
                        revision INTEGER NOT NULL
                    )
                    """
                )
            } else if try !columnExists(table: "dirty_paths", column: "revision") {
                try run(
                    """
                    CREATE TABLE dirty_paths_v4(
                        path TEXT PRIMARY KEY NOT NULL,
                        revision INTEGER NOT NULL
                    )
                    """
                )
                try run(
                    "INSERT OR REPLACE INTO dirty_paths_v4(path, revision) SELECT path, 1 FROM dirty_paths"
                )
                try run("DROP TABLE dirty_paths")
                try run("ALTER TABLE dirty_paths_v4 RENAME TO dirty_paths")
            }
            let maximumDirtyRevision = try scalarInt64(
                "SELECT coalesce(max(revision), 0) FROM dirty_paths"
            )
            try run(
                """
                INSERT INTO index_state(key, int_value)
                VALUES('dirty_revision', \(maximumDirtyRevision))
                ON CONFLICT(key) DO UPDATE SET
                    int_value = max(int_value, excluded.int_value)
                """
            )

            // v5 introduced localized application aliases; v6 expands the
            // resolver to every common macOS localization layout and adds
            // Chinese script variants. Existing application rows cannot be
            // repaired without reading their bundles again, so hide only roots
            // containing apps and queue them for a background rebuild.
            // Document generations remain queryable during that rebuild.
            if hadRootsTable && originalVersion >= 3 && originalVersion < 6 {
                let rebuildRevision = max(maximumDirtyRevision, 0) + 1
                let applicationRootPredicate =
                    """
                    indexed_applications > 0 OR EXISTS (
                        SELECT 1 FROM entries e
                        WHERE e.root_path = roots.root_path
                          AND e.generation = roots.active_generation
                          AND e.kind = 0
                    )
                    """
                try run(
                    """
                    UPDATE index_state SET int_value = \(rebuildRevision)
                    WHERE key = 'dirty_revision'
                    """
                )
                try run(
                    """
                    INSERT INTO dirty_paths(path, revision)
                    SELECT root_path, \(rebuildRevision) FROM roots
                    WHERE \(applicationRootPredicate)
                    ON CONFLICT(path) DO UPDATE SET revision = excluded.revision
                    """
                )
                try run(
                    """
                    UPDATE roots SET
                        active_generation = NULL,
                        staging_generation = NULL,
                        last_success = NULL,
                        skipped_generated = 0,
                        inaccessible = 0,
                        reached_limit = 0,
                        indexed_applications = 0,
                        indexed_files = 0,
                        indexed_folders = 0
                    WHERE \(applicationRootPredicate)
                    """
                )
                // Make the next coordinator pass a one-time full rebuild so
                // application roots use the fast application-first path. The
                // still-active document generations remain queryable until
                // their replacement generation commits.
                try run("UPDATE roots SET last_success = NULL")
            }

            let invalidationPredicate: String?
            if hadRootsTable && originalVersion < 3 {
                invalidationPredicate = "1 = 1"
            } else if hadRootsTable && originalVersion == 3 {
                // Heal databases opened by the earlier v3 migration too: a
                // zero-count active generation with visible entries is the
                // exact inconsistent state that migration could create.
                invalidationPredicate =
                    """
                    staging_generation IS NOT NULL OR (
                        active_generation IS NOT NULL
                        AND indexed_applications + indexed_files + indexed_folders = 0
                        AND EXISTS (
                            SELECT 1 FROM entries e
                            WHERE e.root_path = roots.root_path
                              AND e.generation = roots.active_generation
                        )
                    )
                    """
            } else {
                invalidationPredicate = nil
            }

            if let invalidationPredicate {
                let rebuildRevision = max(maximumDirtyRevision, 0) + 1
                try run(
                    """
                    UPDATE index_state SET int_value = \(rebuildRevision)
                    WHERE key = 'dirty_revision'
                    """
                )
                try run(
                    """
                    INSERT INTO dirty_paths(path, revision)
                    SELECT root_path, \(rebuildRevision) FROM roots
                    WHERE \(invalidationPredicate)
                    ON CONFLICT(path) DO UPDATE SET revision = excluded.revision
                    """
                )
                try run(
                    """
                    UPDATE roots SET
                        active_generation = NULL,
                        staging_generation = NULL,
                        last_success = NULL,
                        skipped_generated = 0,
                        inaccessible = 0,
                        reached_limit = 0,
                        indexed_applications = 0,
                        indexed_files = 0,
                        indexed_folders = 0
                    WHERE \(invalidationPredicate)
                    """
                )
            }

            try run("PRAGMA user_version=\(schemaVersion)")
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try FileSearchCPUWork.measure {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs a stable WAL read snapshot on the dedicated read-only connection.
    /// SQLite invokes the progress callback from inside `sqlite3_step`, which
    /// lets cancellation interrupt a scan instead of waiting for it to finish.
    private func cancellableReadTransaction<T>(
        on database: OpaquePointer,
        budget: FileSearchSQLiteQueryBudget,
        _ body: () throws -> T
    ) throws -> T {
        try executeControl("BEGIN DEFERRED", database: database)
        let progressContext = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(
            database,
            512,
            fileSearchSQLiteCancellationProgressHandler,
            progressContext
        )
        do {
            let result = try body()
            sqlite3_progress_handler(database, 0, nil, nil)
            try executeControl("COMMIT", database: database)
            return result
        } catch {
            sqlite3_progress_handler(database, 0, nil, nil)
            try? executeControl("ROLLBACK", database: database)
            if Task.isCancelled,
               case let FileSearchIndexStoreError.sqlite(_, code) = error,
               code == SQLITE_INTERRUPT {
                throw CancellationError()
            }
            throw error
        }
    }

    private func prepare(
        _ sql: String,
        database explicitDatabase: OpaquePointer? = nil
    ) throws -> OpaquePointer {
        let database = try explicitDatabase ?? requireDatabase()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(database: database) }
        return statement
    }

    private func executeControl(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw FileSearchIndexStoreError.sqlite(message: message, code: result)
        }
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func executeChangeCount(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws -> Int {
        // The two bounded generation-cleanup deletes run outside transaction().
        // They still belong to the background indexer's measured CPU budget.
        try FileSearchCPUWork.measure {
            let database = try requireDatabase()
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            return Int(sqlite3_changes(database))
        }
    }

    private func scalarInt64(
        _ sql: String,
        strings: [String] = [],
        database: OpaquePointer? = nil
    ) throws -> Int64? {
        try scalarInt64(
            sql,
            bindings: strings.map(SQLiteBinding.text),
            database: database
        )
    }

    private func scalarInt64(
        _ sql: String,
        bindings: [SQLiteBinding],
        database explicitDatabase: OpaquePointer? = nil
    ) throws -> Int64? {
        let database = try explicitDatabase ?? requireDatabase()
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw queryError(for: step, database: database)
        }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, 0)
    }

    private func scalarText(
        _ sql: String,
        strings: [String] = []
    ) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(strings.map(SQLiteBinding.text), to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, index: 0)
    }

    private func rows(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        database explicitDatabase: OpaquePointer? = nil
    ) throws -> [[SQLiteColumn]] {
        let database = try explicitDatabase ?? requireDatabase()
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [[SQLiteColumn]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw queryError(for: step, database: database)
            }
            result.append((0 ..< sqlite3_column_count(statement)).map { index in
                let type = sqlite3_column_type(statement, index)
                switch type {
                case SQLITE_INTEGER:
                    return .int64(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    return .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    return .text(columnText(statement, index: index) ?? "")
                default:
                    return .null
                }
            })
        }
        return result
    }

    private func textValues(_ sql: String) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError() }
            if let value = columnText(statement, index: 0) {
                result.append(value)
            }
        }
        return result
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .int64(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .double(value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func requireDatabase() throws -> OpaquePointer {
        if let database { return database }

        do {
            try Self.createParentDirectory(for: databaseURL)
            let openedDatabase = try Self.openDatabase(at: databaseURL)
            do {
                try Self.configureAndMigrate(openedDatabase)
                database = openedDatabase
                lastStartupError = nil
                return openedDatabase
            } catch {
                sqlite3_close_v2(openedDatabase)
                throw error
            }
        } catch let error as FileSearchIndexStoreError {
            // Never make a transient BUSY/LOCKED/I/O startup failure sticky.
            // The next user query or background pass retries initialization.
            lastStartupError = error
            throw error
        } catch {
            let wrapped = FileSearchIndexStoreError.unavailable(
                error.localizedDescription
            )
            lastStartupError = wrapped
            throw wrapped
        }
    }

    private func requireQueryDatabase() throws -> OpaquePointer {
        if let queryDatabase { return queryDatabase }

        do {
            if !FileManager.default.fileExists(atPath: databaseURL.path) {
                _ = try requireDatabase()
            }

            var opened = try Self.openConfiguredReadOnlyDatabase(at: databaseURL)
            if opened.version < Self.schemaVersion {
                let openedDatabase = opened.database
                sqlite3_close_v2(openedDatabase)
                _ = try requireDatabase()
                opened = try Self.openConfiguredReadOnlyDatabase(at: databaseURL)
            }
            queryDatabase = opened.database
            lastStartupError = nil
            return opened.database
        } catch let error as FileSearchIndexStoreError {
            lastStartupError = error
            throw error
        } catch {
            let wrapped = FileSearchIndexStoreError.unavailable(
                error.localizedDescription
            )
            lastStartupError = wrapped
            throw wrapped
        }
    }

    private func sqliteError() -> FileSearchIndexStoreError {
        guard let database else {
            return lastStartupError ?? .unavailable(L10n.tr("SQLite 索引不可用"))
        }
        return sqliteError(database: database)
    }

    private func sqliteError(database: OpaquePointer) -> FileSearchIndexStoreError {
        return .sqlite(
            message: String(cString: sqlite3_errmsg(database)),
            code: sqlite3_errcode(database)
        )
    }

    private func queryError(
        for result: Int32,
        database: OpaquePointer
    ) -> Error {
        if result == SQLITE_INTERRUPT, Task.isCancelled {
            return CancellationError()
        }
        return FileSearchIndexStoreError.sqlite(
            message: String(cString: sqlite3_errmsg(database)),
            code: result
        )
    }

    private static func createParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? L10n.tr("无法打开 SQLite 索引")
            if let database { sqlite3_close_v2(database) }
            throw FileSearchIndexStoreError.sqlite(message: message, code: result)
        }
        return database
    }

    private static func openReadOnlyDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? L10n.tr("无法打开 SQLite 索引")
            if let database { sqlite3_close_v2(database) }
            throw FileSearchIndexStoreError.sqlite(message: message, code: result)
        }
        return database
    }

    /// Owns the close-on-error rule for every validation/configuration step so
    /// a malformed schema or failed PRAGMA cannot leak a SQLite handle.
    private static func openConfiguredReadOnlyDatabase(
        at url: URL
    ) throws -> (database: OpaquePointer, version: Int64) {
        let database = try openReadOnlyDatabase(at: url)
        do {
            let version = try databaseUserVersion(database)
            try configureReadOnly(database)
            return (database, version)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    private static func configureReadOnly(_ database: OpaquePointer) throws {
        func run(_ sql: String) throws {
            let result = sqlite3_exec(database, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw FileSearchIndexStoreError.sqlite(
                    message: String(cString: sqlite3_errmsg(database)),
                    code: result
                )
            }
        }
        try run("PRAGMA query_only=ON")
        try run("PRAGMA busy_timeout=250")
        try run("PRAGMA temp_store=MEMORY")
    }

    private static func databaseUserVersion(_ database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA user_version",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw FileSearchIndexStoreError.sqlite(
                message: String(cString: sqlite3_errmsg(database)),
                code: prepareResult
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw FileSearchIndexStoreError.sqlite(
                message: String(cString: sqlite3_errmsg(database)),
                code: stepResult
            )
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func optionalInt64(_ statement: OpaquePointer, index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer, index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func subsequenceLikePattern(_ value: String) -> String {
        "%" + value.map { escapeLike(String($0)) }.joined(separator: "%") + "%"
    }
}

private enum SQLiteBinding {
    case text(String)
    case int64(Int64)
    case double(Double)
    case null
}

private enum SQLiteColumn {
    case text(String)
    case int64(Int64)
    case double(Double)
    case null

    var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var int64: Int64? {
        if case let .int64(value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case let .double(value): return value
        case let .int64(value): return Double(value)
        default: return nil
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class FileSearchSQLiteQueryBudget: @unchecked Sendable {
    private let timeLimitNanoseconds: UInt64
    private var deadlineNanoseconds: UInt64?
    private(set) var didExceedDeadline = false

    init(timeLimit: TimeInterval) {
        timeLimitNanoseconds = UInt64(timeLimit * 1_000_000_000)
    }

    func activateDeadline() {
        deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ timeLimitNanoseconds
    }

    func progressResult() -> Int32 {
        if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) { return 1 }
        guard let deadlineNanoseconds else { return 0 }
        if DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
            didExceedDeadline = true
            return 1
        }
        return 0
    }
}

/// Noncapturing C callback required by SQLite. The context is retained by the
/// synchronous caller until the handler is unregistered.
private let fileSearchSQLiteCancellationProgressHandler:
    @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
        guard let context else { return 0 }
        return Unmanaged<FileSearchSQLiteQueryBudget>
            .fromOpaque(context)
            .takeUnretainedValue()
            .progressResult()
    }
