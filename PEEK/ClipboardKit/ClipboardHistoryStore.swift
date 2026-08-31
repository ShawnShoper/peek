import CryptoKit
import Foundation
import SQLite3

private let clipboardSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/// Persistent clipboard metadata store. All database and payload-file access is
/// actor isolated so polling, panel previews, and deletion never race.
actor ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    private let configuredRootURL: URL?
    private let limits: ClipboardHistoryLimits
    private var database: OpaquePointer?
    private var rootURL: URL?
    private var payloadDirectoryURL: URL?
    private var pendingDeletionDirectoryURL: URL?

    init(
        rootURL: URL? = nil,
        limits: ClipboardHistoryLimits = .standard
    ) {
        configuredRootURL = rootURL
        self.limits = limits
    }

    func loadRecords() throws -> [ClipboardHistoryRecord] {
        try prepareIfNeeded()
        return try queryRecords()
    }

    func storageSummary() throws -> ClipboardHistoryStorageSummary {
        let records = try loadRecords()
        return ClipboardHistoryStorageSummary(
            itemCount: records.count,
            byteCount: Self.safeStorageByteCount(records)
        )
    }

    /// Returns the list and its summary from one SQLite query. The monitor needs
    /// both after each save; querying twice doubled the work for every copy.
    func recordsAndStorageSummary() throws -> (
        records: [ClipboardHistoryRecord],
        summary: ClipboardHistoryStorageSummary
    ) {
        let records = try loadRecords()
        return (
            records,
            ClipboardHistoryStorageSummary(
                itemCount: records.count,
                byteCount: Self.safeStorageByteCount(records)
            )
        )
    }

    @discardableResult
    func save(_ capture: ClipboardHistoryCapture) throws -> ClipboardHistoryRecord {
        // Reject oversized in-memory content before PropertyListEncoder creates
        // a second copy or the store touches disk. This is especially important
        // for screenshots and PDFs, whose encoded payload can otherwise briefly
        // double peak memory use.
        let rawByteCount = capture.payload.rawContentByteCount
        guard rawByteCount <= limits.maximumItemBytes else {
            throw ClipboardHistoryError.itemTooLarge(rawByteCount)
        }

        try prepareIfNeeded()

        let payloadData: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            payloadData = try encoder.encode(capture.payload)
        } catch {
            throw ClipboardHistoryError.unavailable(error.localizedDescription)
        }

        let byteCount = Int64(payloadData.count)
        guard byteCount <= limits.maximumItemBytes else {
            throw ClipboardHistoryError.itemTooLarge(byteCount)
        }

        let digest = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let now = capture.capturedAt

        // Re-copying the current item refreshes it instead of producing a stack
        // of identical adjacent rows.
        if let latest = try queryRecords(limit: 1).first,
           latest.digest == digest {
            try execute(
                """
                UPDATE clipboard_records
                SET created_at = ?, source_app = ?, source_bundle_id = ?
                WHERE id = ?;
                """,
                bindings: [
                    .double(now.timeIntervalSince1970),
                    capture.sourceApplicationName.map(SQLiteValue.text) ?? .null,
                    capture.sourceBundleIdentifier.map(SQLiteValue.text) ?? .null,
                    .text(latest.id.uuidString),
                ]
            )
            return ClipboardHistoryRecord(
                id: latest.id,
                createdAt: now,
                kind: latest.kind,
                title: latest.title,
                detail: latest.detail,
                sourceApplicationName: capture.sourceApplicationName,
                sourceBundleIdentifier: capture.sourceBundleIdentifier,
                payloadFilename: latest.payloadFilename,
                byteCount: latest.byteCount,
                digest: latest.digest
            )
        }

        guard let payloadDirectoryURL else {
            throw ClipboardHistoryError.unavailable(L10n.tr("存储目录不可用"))
        }
        let id = UUID()
        let filename = "\(id.uuidString).clip"
        let payloadURL = payloadDirectoryURL.appendingPathComponent(filename)
        do {
            try payloadData.write(to: payloadURL, options: [.atomic])
        } catch {
            throw ClipboardHistoryError.unavailable(error.localizedDescription)
        }

        do {
            try execute(
                """
                INSERT INTO clipboard_records (
                    id, created_at, kind, title, detail, source_app,
                    source_bundle_id, payload_file, byte_count, digest
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(id.uuidString),
                    .double(now.timeIntervalSince1970),
                    .text(capture.kind.rawValue),
                    .text(capture.title),
                    .text(capture.detail),
                    capture.sourceApplicationName.map(SQLiteValue.text) ?? .null,
                    capture.sourceBundleIdentifier.map(SQLiteValue.text) ?? .null,
                    .text(filename),
                    .int64(byteCount),
                    .text(digest),
                ]
            )
        } catch {
            try? FileManager.default.removeItem(at: payloadURL)
            throw error
        }

        try pruneIfNeeded()
        return ClipboardHistoryRecord(
            id: id,
            createdAt: now,
            kind: capture.kind,
            title: capture.title,
            detail: capture.detail,
            sourceApplicationName: capture.sourceApplicationName,
            sourceBundleIdentifier: capture.sourceBundleIdentifier,
            payloadFilename: filename,
            byteCount: byteCount,
            digest: digest
        )
    }

    func payload(for record: ClipboardHistoryRecord) throws -> ClipboardPayloadEnvelope {
        try Task.checkCancellation()
        try prepareIfNeeded()
        guard let payloadDirectoryURL else {
            throw ClipboardHistoryError.payloadMissing
        }
        let url = payloadDirectoryURL.appendingPathComponent(record.payloadFilename)
        guard let data = try? Data(contentsOf: url) else {
            throw ClipboardHistoryError.payloadMissing
        }
        try Task.checkCancellation()
        do {
            // `PropertyListDecoder` is synchronous. Check immediately before
            // and after it so a superseded preview releases the decoded payload
            // without continuing into image/PDF work.
            try Task.checkCancellation()
            let payload = try PropertyListDecoder().decode(
                ClipboardPayloadEnvelope.self,
                from: data
            )
            try Task.checkCancellation()
            return payload
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw ClipboardHistoryError.payloadMissing
        }
    }

    func delete(_ record: ClipboardHistoryRecord) throws {
        try prepareIfNeeded()
        try delete(records: [record])
    }

    func clear() throws {
        try prepareIfNeeded()
        try delete(records: queryRecords())
        // Clear also sweeps payloads that lost their metadata in an earlier
        // interrupted save/delete, so private orphan data is not retained.
        reconcilePayloadStorage()
        // Remove deleted clipboard rows from the WAL and compact the database so
        // "Clear all" does not leave recoverable clipboard text in spare pages.
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
    }

    func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    private func prepareIfNeeded() throws {
        guard database == nil else { return }

        let root: URL
        if let configuredRootURL {
            root = configuredRootURL
        } else {
            do {
                root = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent("ClipboardHistory", isDirectory: true)
            } catch {
                throw ClipboardHistoryError.unavailable(error.localizedDescription)
            }
        }
        let payloads = root.appendingPathComponent("Payloads", isDirectory: true)
        let pendingDeletions = root.appendingPathComponent(
            "PendingPayloadDeletion",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: payloads,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: pendingDeletions,
                withIntermediateDirectories: true
            )
        } catch {
            throw ClipboardHistoryError.unavailable(error.localizedDescription)
        }

        let databaseURL = root.appendingPathComponent("clipboard-history.sqlite3")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? L10n.tr("无法打开 SQLite 数据库")
            if let handle { sqlite3_close(handle) }
            throw ClipboardHistoryError.unavailable(detail)
        }

        database = handle
        rootURL = root
        payloadDirectoryURL = payloads
        pendingDeletionDirectoryURL = pendingDeletions
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA secure_delete=ON;")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS clipboard_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    source_app TEXT,
                    source_bundle_id TEXT,
                    payload_file TEXT NOT NULL,
                    byte_count INTEGER NOT NULL,
                    digest TEXT NOT NULL
                );
                """
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS clipboard_records_created_at ON clipboard_records(created_at DESC);"
            )
            // A corrupted or manually edited database must not introduce a
            // negative byte count into pruning or summary arithmetic.
            try execute("DELETE FROM clipboard_records WHERE byte_count < 0;")
            reconcilePayloadStorage()
            // Existing users may have accumulated data under the former 1 GiB
            // policy. Keep readable items where possible while bringing count
            // and total storage under the new safety budget.
            try pruneIfNeeded()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    private func pruneIfNeeded() throws {
        let records = try queryRecords()
        var retainedBytes: Int64 = 0
        var expired: [ClipboardHistoryRecord] = []
        for (index, record) in records.enumerated() {
            let exceedsCount = index >= limits.maximumItemCount
            let (nextBytes, overflow) = retainedBytes.addingReportingOverflow(
                record.byteCount
            )
            let invalidByteCount = record.byteCount < 0
            let exceedsBytes = invalidByteCount
                || overflow
                || nextBytes > limits.maximumTotalBytes
            if exceedsCount || exceedsBytes {
                expired.append(record)
            } else {
                retainedBytes = nextBytes
            }
        }
        try delete(records: expired)
    }

    private struct StagedPayloadDeletion {
        let originalURL: URL
        let stagedURL: URL
    }

    /// Deletion is a recoverable two-phase operation. Payload files are first
    /// moved atomically into a staging directory, then SQLite metadata is
    /// committed. If SQLite fails, files are restored. If the process exits
    /// after the commit, startup reconciliation removes the staged files.
    private func delete(records: [ClipboardHistoryRecord]) throws {
        guard !records.isEmpty else { return }
        let stagedPayloads = try stagePayloadsForDeletion(records)
        try execute("BEGIN IMMEDIATE;")
        do {
            for record in records {
                try execute(
                    "DELETE FROM clipboard_records WHERE id = ?;",
                    bindings: [.text(record.id.uuidString)]
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            restoreStagedPayloads(stagedPayloads)
            throw error
        }
        finalizeStagedPayloads(stagedPayloads)
    }

    private func stagePayloadsForDeletion(
        _ records: [ClipboardHistoryRecord]
    ) throws -> [StagedPayloadDeletion] {
        guard let payloadDirectoryURL,
              let pendingDeletionDirectoryURL else { return [] }
        let fileManager = FileManager.default
        var staged: [StagedPayloadDeletion] = []
        do {
            for record in records {
                let originalURL = payloadDirectoryURL.appendingPathComponent(
                    record.payloadFilename
                )
                guard fileManager.fileExists(atPath: originalURL.path) else { continue }
                let stagedURL = pendingDeletionDirectoryURL.appendingPathComponent(
                    record.payloadFilename
                )
                if fileManager.fileExists(atPath: stagedURL.path) {
                    try fileManager.removeItem(at: stagedURL)
                }
                try fileManager.moveItem(at: originalURL, to: stagedURL)
                staged.append(.init(originalURL: originalURL, stagedURL: stagedURL))
            }
            return staged
        } catch {
            restoreStagedPayloads(staged)
            throw ClipboardHistoryError.unavailable(error.localizedDescription)
        }
    }

    private func restoreStagedPayloads(_ stagedPayloads: [StagedPayloadDeletion]) {
        let fileManager = FileManager.default
        for staged in stagedPayloads.reversed()
        where fileManager.fileExists(atPath: staged.stagedURL.path) {
            if fileManager.fileExists(atPath: staged.originalURL.path) {
                try? fileManager.removeItem(at: staged.stagedURL)
            } else {
                try? fileManager.moveItem(at: staged.stagedURL, to: staged.originalURL)
            }
        }
    }

    private func finalizeStagedPayloads(_ stagedPayloads: [StagedPayloadDeletion]) {
        let fileManager = FileManager.default
        for staged in stagedPayloads {
            try? fileManager.removeItem(at: staged.stagedURL)
        }
    }

    /// Repairs both sides of the metadata/file relationship:
    /// - staged payloads whose rows still exist are restored after a crash;
    /// - rows without payloads are removed;
    /// - payloads without rows are removed.
    /// Failed file operations remain recoverable and are retried on startup or
    /// the next explicit clear operation.
    private func reconcilePayloadStorage() {
        guard database != nil,
              let payloadDirectoryURL,
              let pendingDeletionDirectoryURL else { return }
        let fileManager = FileManager.default
        guard let records = try? queryRecords() else { return }
        let referencedNames = Set(records.map(\.payloadFilename))

        let stagedURLs = (try? fileManager.contentsOfDirectory(
            at: pendingDeletionDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for stagedURL in stagedURLs where stagedURL.pathExtension == "clip" {
            let filename = stagedURL.lastPathComponent
            let originalURL = payloadDirectoryURL.appendingPathComponent(filename)
            if referencedNames.contains(filename),
               !fileManager.fileExists(atPath: originalURL.path) {
                try? fileManager.moveItem(at: stagedURL, to: originalURL)
            } else {
                try? fileManager.removeItem(at: stagedURL)
            }
        }

        let missingRecords = records.filter {
            !fileManager.fileExists(
                atPath: payloadDirectoryURL.appendingPathComponent($0.payloadFilename).path
            )
        }
        if !missingRecords.isEmpty {
            try? deleteMetadataOnly(missingRecords)
        }

        let liveNames = referencedNames.subtracting(missingRecords.map(\.payloadFilename))
        let payloadURLs = (try? fileManager.contentsOfDirectory(
            at: payloadDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for payloadURL in payloadURLs
        where payloadURL.pathExtension == "clip"
            && !liveNames.contains(payloadURL.lastPathComponent) {
            try? fileManager.removeItem(at: payloadURL)
        }
    }

    private func deleteMetadataOnly(_ records: [ClipboardHistoryRecord]) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            for record in records {
                try execute(
                    "DELETE FROM clipboard_records WHERE id = ?;",
                    bindings: [.text(record.id.uuidString)]
                )
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func queryRecords(limit: Int? = nil) throws -> [ClipboardHistoryRecord] {
        guard let database else {
            throw ClipboardHistoryError.unavailable(L10n.tr("数据库尚未打开"))
        }
        let suffix = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let sql = """
            SELECT id, created_at, kind, title, detail, source_app,
                   source_bundle_id, payload_file, byte_count, digest
            FROM clipboard_records
            ORDER BY created_at DESC\(suffix);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw currentDatabaseError()
        }
        defer { sqlite3_finalize(statement) }

        var records: [ClipboardHistoryRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw currentDatabaseError() }
            guard
                let idString = textColumn(statement, index: 0),
                let id = UUID(uuidString: idString),
                let kindValue = textColumn(statement, index: 2),
                let kind = ClipboardHistoryKind(rawValue: kindValue),
                let title = textColumn(statement, index: 3),
                let detail = textColumn(statement, index: 4),
                let payloadFilename = textColumn(statement, index: 7),
                let digest = textColumn(statement, index: 9)
            else { continue }
            let byteCount = sqlite3_column_int64(statement, 8)
            guard byteCount >= 0 else { continue }
            records.append(
                ClipboardHistoryRecord(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    kind: kind,
                    title: title,
                    detail: detail,
                    sourceApplicationName: textColumn(statement, index: 5),
                    sourceBundleIdentifier: textColumn(statement, index: 6),
                    payloadFilename: payloadFilename,
                    byteCount: byteCount,
                    digest: digest
                )
            )
        }
        return records
    }

    nonisolated static func safeStorageByteCount(
        _ records: [ClipboardHistoryRecord]
    ) -> Int64 {
        var total: Int64 = 0
        for record in records where record.byteCount > 0 {
            let (next, overflow) = total.addingReportingOverflow(record.byteCount)
            if overflow { return Int64.max }
            total = next
        }
        return total
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws {
        guard let database else {
            throw ClipboardHistoryError.unavailable(L10n.tr("数据库尚未打开"))
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw currentDatabaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .null:
                status = sqlite3_bind_null(statement, index)
            case .text(let value):
                status = sqlite3_bind_text(statement, index, value, -1, clipboardSQLiteTransient)
            case .double(let value):
                status = sqlite3_bind_double(statement, index, value)
            case .int64(let value):
                status = sqlite3_bind_int64(statement, index, value)
            }
            guard status == SQLITE_OK else { throw currentDatabaseError() }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            // PRAGMA statements such as journal_mode legitimately return one
            // result row before completion.
            if status == SQLITE_ROW { continue }
            throw currentDatabaseError()
        }
    }

    private func currentDatabaseError() -> ClipboardHistoryError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? L10n.tr("未知数据库错误")
        return .unavailable(detail)
    }

    private func textColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}

private enum SQLiteValue {
    case null
    case text(String)
    case double(Double)
    case int64(Int64)
}
