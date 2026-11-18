import AppKit
import Carbon.HIToolbox
import SQLite3
import XCTest
@testable import PEEK

final class ClipboardHistoryStoreTests: XCTestCase {
    func testStoreKeepsNewestOneHundredRecordsAndPayloads() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(
            rootURL: root,
            limits: ClipboardHistoryLimits(
                maximumItemCount: 100,
                maximumTotalBytes: 16 * 1_024 * 1_024,
                maximumItemBytes: 1_024 * 1_024
            )
        )

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0 ..< 105 {
            _ = try await store.save(
                capture(
                    text: "item-\(index)",
                    date: baseDate.addingTimeInterval(Double(index))
                )
            )
        }

        let records = try await store.loadRecords()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.first?.title, "item-104")
        XCTAssertEqual(records.last?.title, "item-5")
        let payloads = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Payloads"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(payloads.count, 100)
        await store.close()
    }

    func testConsecutiveDuplicateRefreshesExistingRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(20)

        let first = try await store.save(capture(text: "same", date: firstDate))
        let second = try await store.save(capture(text: "same", date: secondDate))
        let records = try await store.loadRecords()

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].createdAt, secondDate)
        await store.close()
    }

    func testPayloadRoundTripAndDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let saved = try await store.save(capture(text: "PEEK clipboard", date: Date()))

        let payload = try await store.payload(for: saved)
        let textData = try XCTUnwrap(
            payload.data(forType: NSPasteboard.PasteboardType.string.rawValue)
        )
        XCTAssertEqual(String(data: textData, encoding: .utf8), "PEEK clipboard")

        try await store.delete(saved)
        let remainingAfterDelete = try await store.loadRecords()
        XCTAssertTrue(remainingAfterDelete.isEmpty)
        do {
            _ = try await store.payload(for: saved)
            XCTFail("Deleted payload should not remain readable")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryError, .payloadMissing)
        }
        await store.close()
    }

    func testV040RichTextMetadataIsRepairedOnceWithoutRewritingPayload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let html = Data("<p>旧记录 &amp; PEEK</p>".utf8)
        let envelope = ClipboardPayloadEnvelope(representations: [
            .init(type: NSPasteboard.PasteboardType.html.rawValue, data: html)
        ])
        let legacy = try await store.save(ClipboardHistoryCapture(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .richText, title: "Rich Text", detail: "0 characters",
            sourceApplicationName: "fixture", sourceBundleIdentifier: nil, payload: envelope
        ))
        await store.close()
        var handle: OpaquePointer?
        let databaseURL = root.appendingPathComponent("clipboard-history.sqlite3")
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 0", nil, nil, nil), SQLITE_OK)

        let reopened = ClipboardHistoryStore(rootURL: root)
        let rows = try await reopened.loadRecords()
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.id, legacy.id)
        XCTAssertEqual(row.digest, legacy.digest)
        XCTAssertEqual(row.payloadFilename, legacy.payloadFilename)
        XCTAssertEqual(row.createdAt, legacy.createdAt)
        XCTAssertEqual(row.sourceApplicationName, "fixture")
        XCTAssertEqual(row.title, "旧记录 & PEEK")
        XCTAssertEqual(row.detail, "\(row.title.count) characters")
        let payload = try await reopened.payload(for: row)
        XCTAssertEqual(payload, envelope)
        await reopened.close()

        // Simulate a matching row after the upgrade. Reopening must not scan
        // its payload a second time.
        XCTAssertEqual(sqlite3_exec(database,
            "UPDATE clipboard_records SET title = '富文本', detail = '0 个字符'", nil, nil, nil), SQLITE_OK)
        let afterUpgrade = ClipboardHistoryStore(rootURL: root)
        let laterRows = try await afterUpgrade.loadRecords()
        XCTAssertEqual(laterRows.first?.title, "富文本")
        await afterUpgrade.close()
    }

    func testCancelledPayloadRequestStopsBeforeReadingFromDisk() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let saved = try await store.save(capture(text: "cancel me", date: Date()))

        let request = Task<ClipboardPayloadEnvelope, Error> {
            // Enter the actor method with cancellation already set so this test
            // deterministically covers its earliest cancellation boundary.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.payload(for: saved)
        }

        do {
            _ = try await request.value
            XCTFail("A cancelled preview must not read its persisted payload")
        } catch is CancellationError {
            // Expected.
        }
        await store.close()
    }

    func testOversizedPayloadIsRejectedWithoutCreatingRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(
            rootURL: root,
            limits: ClipboardHistoryLimits(
                maximumItemCount: 100,
                maximumTotalBytes: 4_096,
                maximumItemBytes: 128
            )
        )
        let content = String(repeating: "x", count: 1_024)

        do {
            _ = try await store.save(capture(text: content, date: Date()))
            XCTFail("Oversized record must be rejected")
        } catch ClipboardHistoryError.itemTooLarge(_) {
            // Expected.
        }
        let records = try await store.loadRecords()
        XCTAssertTrue(records.isEmpty)
        await store.close()
    }

    func testRawPayloadLimitIsCheckedBeforePropertyListEncoding() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(
            rootURL: root,
            limits: ClipboardHistoryLimits(
                maximumItemCount: 100,
                maximumTotalBytes: 4_096,
                maximumItemBytes: 128
            )
        )
        let rawData = Data(repeating: 0xA5, count: 129)
        let oversizedCapture = ClipboardHistoryCapture(
            kind: .image,
            title: "oversized",
            detail: "129 bytes",
            sourceApplicationName: "Tests",
            sourceBundleIdentifier: "com.shawnshoper.peek.tests",
            payload: ClipboardPayloadEnvelope(representations: [
                ClipboardRepresentation(type: NSPasteboard.PasteboardType.png.rawValue, data: rawData),
            ])
        )

        do {
            _ = try await store.save(oversizedCapture)
            XCTFail("Raw payload must be rejected before plist encoding")
        } catch ClipboardHistoryError.itemTooLarge(let byteCount) {
            // An encoded plist would be larger; the exact raw size proves the
            // preflight guard ran before PropertyListEncoder.
            XCTAssertEqual(byteCount, 129)
        }
        let records = try await store.loadRecords()
        XCTAssertTrue(records.isEmpty)
        await store.close()
    }

    func testStandardLimitsUseCommercialSafetyBudget() {
        XCTAssertEqual(ClipboardHistoryLimits.standard.maximumItemCount, 100)
        XCTAssertEqual(
            ClipboardHistoryLimits.standard.maximumTotalBytes,
            256 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ClipboardHistoryLimits.standard.maximumItemBytes,
            32 * 1_024 * 1_024
        )
    }

    func testStartupReconcilesMissingOrphanAndInterruptedDeletionPayloads() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = ClipboardHistoryStore(rootURL: root)
        let retained = try await firstStore.save(
            capture(text: "restore-me", date: Date(timeIntervalSince1970: 10))
        )
        let missing = try await firstStore.save(
            capture(text: "missing", date: Date(timeIntervalSince1970: 20))
        )
        await firstStore.close()

        let payloadDirectory = root.appendingPathComponent("Payloads", isDirectory: true)
        let deletionDirectory = root.appendingPathComponent(
            "PendingPayloadDeletion",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: payloadDirectory.appendingPathComponent(retained.payloadFilename),
            to: deletionDirectory.appendingPathComponent(retained.payloadFilename)
        )
        try FileManager.default.removeItem(
            at: payloadDirectory.appendingPathComponent(missing.payloadFilename)
        )
        let orphanURL = payloadDirectory.appendingPathComponent("orphan.clip")
        try Data("private orphan".utf8).write(to: orphanURL)

        let recoveredStore = ClipboardHistoryStore(rootURL: root)
        let records = try await recoveredStore.loadRecords()

        XCTAssertEqual(records.map(\.id), [retained.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: payloadDirectory.appendingPathComponent(retained.payloadFilename).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: deletionDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        await recoveredStore.close()
    }

    func testClearRemovesRowsAndUnreferencedPayloadFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        _ = try await store.save(capture(text: "saved", date: Date()))
        let payloadDirectory = root.appendingPathComponent("Payloads", isDirectory: true)
        let orphanURL = payloadDirectory.appendingPathComponent("orphan.clip")
        try Data("private orphan".utf8).write(to: orphanURL)

        try await store.clear()

        let remainingRecords = try await store.loadRecords()
        XCTAssertTrue(remainingRecords.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: nil
        ).isEmpty)
        await store.close()
    }

    private func capture(text: String, date: Date) -> ClipboardHistoryCapture {
        ClipboardHistoryCapture(
            capturedAt: date,
            kind: .text,
            title: text,
            detail: "\(text.count)",
            sourceApplicationName: "Tests",
            sourceBundleIdentifier: "com.shawnshoper.peek.tests",
            payload: ClipboardPayloadEnvelope(
                representations: [
                    ClipboardRepresentation(
                        type: NSPasteboard.PasteboardType.string.rawValue,
                        data: Data(text.utf8)
                    ),
                ]
            )
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PEEK-ClipboardTests-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
final class ClipboardHistoryCaptureTests: XCTestCase {
    func testSensitiveMarkersRejectEntirePasteboardOwnershipChange() {
        for marker in ClipboardHistoryPrivacy.excludedTypes {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let first = NSPasteboardItem()
            first.setString("synthetic test value", forType: .string)
            let protected = NSPasteboardItem()
            protected.setData(Data(), forType: .init(marker))
            protected.setString("synthetic second value", forType: .string)
            XCTAssertTrue(pasteboard.writeObjects([first, protected]))
            XCTAssertNil(ClipboardHistoryMonitor.capture(from: pasteboard, sourceApplication: nil), marker)
        }
    }

    func testSensitiveSnapshotCannotBypassLivePasteboardFilter() {
        for marker in ClipboardHistoryPrivacy.excludedTypes {
            let protected = ClipboardHistoryPasteboardItemSnapshot(values: [
                marker: Data(), NSPasteboard.PasteboardType.string.rawValue: Data("synthetic".utf8)
            ])
            XCTAssertNil(ClipboardHistoryMonitor.capture(
                items: [snapshot(type: .fileURL, string: "file:///tmp/example.txt"), protected],
                sourceApplicationName: nil, sourceBundleIdentifier: nil))
        }
    }

    func testPlainTextCapturePreservesTextAndMetadata() throws {
        let capture = try XCTUnwrap(
            ClipboardHistoryMonitor.capture(
                items: [snapshot(type: .string, string: "hello PEEK")],
                sourceApplicationName: nil,
                sourceBundleIdentifier: nil
            )
        )
        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.title, "hello PEEK")
        XCTAssertEqual(
            capture.payload.data(forType: NSPasteboard.PasteboardType.string.rawValue),
            Data("hello PEEK".utf8)
        )
    }

    func testHTTPTextIsClassifiedAsLink() throws {
        let capture = try XCTUnwrap(
            ClipboardHistoryMonitor.capture(
                items: [snapshot(type: .string, string: "https://peek.example/path")],
                sourceApplicationName: nil,
                sourceBundleIdentifier: nil
            )
        )
        XCTAssertEqual(capture.kind, .link)
    }

    func testFileSelectionIsStoredAsOneLogicalRecord() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/one.txt"),
            URL(fileURLWithPath: "/tmp/two.txt"),
        ]

        let capture = try XCTUnwrap(
            ClipboardHistoryMonitor.capture(
                items: urls.map { snapshot(type: .fileURL, string: $0.absoluteString) },
                sourceApplicationName: nil,
                sourceBundleIdentifier: nil
            )
        )
        XCTAssertEqual(capture.kind, .files)
        XCTAssertEqual(capture.payload.fileURLs.count, 2)
    }

    func testSystemPasteboardCaptureKeepsOnlySupportedRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setString("hello PEEK", forType: .string)
        item.setData(
            Data(repeating: 0x7F, count: 128 * 1_024),
            forType: NSPasteboard.PasteboardType("com.peek.tests.unused-payload")
        )
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let capture = try XCTUnwrap(
            ClipboardHistoryMonitor.capture(
                from: pasteboard,
                sourceApplication: nil
            )
        )

        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.payload.representations.count, 1)
        XCTAssertEqual(
            capture.payload.representations.first?.type,
            NSPasteboard.PasteboardType.string.rawValue
        )
    }

    func testMonitorProcessesLatestPasteboardChangeWithoutParallelSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardMonitorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ClipboardHistoryStore(rootURL: root)
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardHistoryMonitor(
            pasteboard: pasteboard,
            store: store,
            defaults: defaults
        )
        monitor.setEnabled(true)

        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("first", forType: .string))
        monitor.pollPasteboardIfNeeded()
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("latest", forType: .string))
        monitor.pollPasteboardIfNeeded()

        let deadline = ContinuousClock.now + .seconds(3)
        var records: [ClipboardHistoryRecord] = []
        while ContinuousClock.now < deadline {
            records = try await store.loadRecords()
            if records.first?.title == "latest" { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(records.first?.title, "latest")
        monitor.stop()
        await store.close()
    }

    func testNewInstallDefaultsOffAndExplicitPreferenceIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardDefaultsTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let pasteboard = NSPasteboard.withUniqueName()
        let store = ClipboardHistoryStore(rootURL: root)

        let newInstall = ClipboardHistoryMonitor(
            pasteboard: pasteboard,
            store: store,
            defaults: defaults
        )
        XCTAssertFalse(newInstall.isEnabled)

        newInstall.setEnabled(true)
        let enabledAgain = ClipboardHistoryMonitor(
            pasteboard: pasteboard,
            store: store,
            defaults: defaults
        )
        XCTAssertTrue(enabledAgain.isEnabled)

        enabledAgain.setEnabled(false)
        let disabledAgain = ClipboardHistoryMonitor(
            pasteboard: pasteboard,
            store: store,
            defaults: defaults
        )
        XCTAssertFalse(disabledAgain.isEnabled)
        await store.close()
    }

    func testDisabledStartDoesNotPrepareStoreOrCreatePollingTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardDormantTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardDormantTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ClipboardHistoryStore(rootURL: root)
        let monitor = ClipboardHistoryMonitor(
            pasteboard: .withUniqueName(),
            store: store,
            defaults: defaults
        )

        monitor.start()
        await Task.yield()

        XCTAssertFalse(monitor.isEnabled)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        monitor.stop()
        await store.close()
    }

    func testExplicitLazyReloadPreparesStoreWhileHistoryRemainsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardLazyLoadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardLazyLoadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ClipboardHistoryStore(rootURL: root)
        let monitor = ClipboardHistoryMonitor(
            pasteboard: .withUniqueName(),
            store: store,
            defaults: defaults
        )
        monitor.start()

        monitor.reloadIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !FileManager.default.fileExists(atPath: root.path) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(monitor.isPolling)
        monitor.stop()
        await store.close()
    }

    func testEnablingHistoryLazilyLoadsStoreAndStartsPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardEnableLoadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardEnableLoadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ClipboardHistoryStore(rootURL: root)
        let monitor = ClipboardHistoryMonitor(
            pasteboard: .withUniqueName(),
            store: store,
            defaults: defaults
        )
        monitor.start()

        monitor.setEnabled(true)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !FileManager.default.fileExists(atPath: root.path) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(monitor.isPolling)
        monitor.stop()
        await store.close()
    }

    func testClearInvalidatesPendingCaptureSoItCannotReappear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardClearTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "PEEK.ClipboardClearTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ClipboardHistoryStore(rootURL: root)
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardHistoryMonitor(
            pasteboard: pasteboard,
            store: store,
            defaults: defaults
        )
        monitor.setEnabled(true)

        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString(
            String(repeating: "pending", count: 50_000),
            forType: .string
        ))
        monitor.pollPasteboardIfNeeded()
        await monitor.clearHistory()
        try await Task.sleep(for: .milliseconds(250))

        let remainingRecords = try await store.loadRecords()
        XCTAssertTrue(remainingRecords.isEmpty)
        XCTAssertTrue(monitor.records.isEmpty)
        monitor.stop()
        await store.close()
    }

    @MainActor
    func testLargeFinderSelectionReportsHowManyFileURLsWereRetained() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let limit = ClipboardHistoryLimits.maximumFileURLCount
        let urls = (0...limit).map { URL(fileURLWithPath: "/tmp/PEEK-selection-\($0)") }
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))
        let capture = try XCTUnwrap(ClipboardHistoryMonitor.capture(from: pasteboard, sourceApplication: nil))
        XCTAssertEqual(capture.title, L10n.tr("共 %d 个文件，已保留 %d 个", urls.count, limit))
        XCTAssertEqual(capture.payload.fileURLs, urls.prefix(limit).map(\.absoluteString))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(Array(urls.prefix(limit)) as [NSURL]))
        let exact = try XCTUnwrap(ClipboardHistoryMonitor.capture(from: pasteboard, sourceApplication: nil))
        XCTAssertEqual(exact.title, L10n.tr("%d 个文件", limit))
        XCTAssertEqual(exact.payload.fileURLs, capture.payload.fileURLs)
    }

    func testClipboardShortcutUsesDedicatedNonConflictingDefault() {
        let shortcut = ScreenshotGlobalHotKeyAction.clipboardHistory.defaultShortcut
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(shortcut.displayString, "⌃⌥⌘V")
        XCTAssertTrue(ScreenshotHotKeyConfiguration.defaults.isValid)
    }

    private func snapshot(
        type: NSPasteboard.PasteboardType,
        string: String
    ) -> ClipboardHistoryPasteboardItemSnapshot {
        ClipboardHistoryPasteboardItemSnapshot(
            values: [type.rawValue: Data(string.utf8)]
        )
    }
}

final class ClipboardHistoryPreviewLoaderTests: XCTestCase {
    func testRichOnlyCapturesPreserveOriginalRepresentationsAndPreviewLegacyPayloads() throws {
        let tail = String(repeating: "1234567890", count: 12)
        let body = "你好 & PEEK\n" + tail
        let rtf = try NSAttributedString(string: body).data(
            from: NSRange(location: 0, length: (body as NSString).length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = Data("""
            <html><head><title>Head title</title></head><body>
            <script>hidden script text</script><style>.unused { color: red }</style>
            <p>你好 &amp; <b>PEEK</b></p><p>\(tail)</p></body></html>
            """.utf8)
        for (type, bytes) in [(NSPasteboard.PasteboardType.rtf, rtf), (.html, html)] {
            let capture = try XCTUnwrap(ClipboardHistoryMonitor.capture(
                items: [ClipboardHistoryPasteboardItemSnapshot(values: [type.rawValue: bytes])],
                sourceApplicationName: nil, sourceBundleIdentifier: nil
            ))
            XCTAssertEqual(capture.kind, .richText)
            XCTAssertEqual(capture.title, String(body.replacingOccurrences(of: "\n", with: " ").prefix(89)) + "…")
            XCTAssertEqual(capture.detail, L10n.tr("%d 个字符", body.count))
            XCTAssertEqual(capture.payload.representations, [.init(type: type.rawValue, data: bytes)])

            // v0.4.0 saved rich-only records without a plain-text representation.
            let record = makeRecord(kind: .richText, title: "old title", byteCount: bytes.count)
            guard case .text(let preview) = ClipboardHistoryPreviewLoader.payloadPreview(record: record, payload: capture.payload) else {
                return XCTFail("Expected rich-text preview")
            }
            XCTAssertEqual(preview.text, body, type.rawValue)
            XCTAssertFalse(preview.isTruncated)
        }
    }

    func testLargeRichOnlyLegacyPreviewsBoundRTFAndHTMLInput() {
        let limit = ClipboardHistoryPreviewLoader.maximumTextPreviewBytes
        let body = "visible " + String(repeating: "a", count: limit * 2)
        let inputs = [
            (NSPasteboard.PasteboardType.rtf, Data((#"{\rtf1{\b "# + body + "}}").utf8)),
            (.html, Data(("<p>" + body + "</p>").utf8))
        ]
        for (type, data) in inputs {
            let record = makeRecord(kind: .richText, title: "old title", byteCount: data.count)
            let payload = ClipboardPayloadEnvelope(representations: [.init(type: type.rawValue, data: data)])
            guard case .text(let preview) = ClipboardHistoryPreviewLoader.payloadPreview(record: record, payload: payload) else {
                return XCTFail("Expected a partial rich-text preview")
            }
            XCTAssertTrue(preview.isTruncated, type.rawValue)
            XCTAssertEqual(preview.totalByteCount, data.count)
            XCTAssertEqual(preview.loadedByteCount, limit)
            XCTAssertTrue(preview.text.hasPrefix("visible "), type.rawValue)
            XCTAssertLessThanOrEqual(preview.text.utf8.count, limit)
        }
    }

    func testLegacyRichLinkUsesOriginalContentBeyondTruncatedTitle() {
        let link = "https://example.com/" + String(repeating: "p", count: 120)
        let data = Data(("<span>" + link + "</span>").utf8)
        let payload = ClipboardPayloadEnvelope(representations: [.init(type: NSPasteboard.PasteboardType.html.rawValue, data: data)])
        let record = makeRecord(kind: .link, title: String(link.prefix(89)) + "…", byteCount: data.count)
        XCTAssertEqual(ClipboardHistoryPreviewLoader.linkURL(record: record, payload: payload)?.absoluteString, link)
    }

    func testHTTPLinkCreatesOfflineLinkCard() throws {
        let value = "https://example.com/path?q=peek"
        let data = Data(value.utf8)
        let record = makeRecord(kind: .link, title: value, byteCount: data.count)
        let payload = ClipboardPayloadEnvelope(representations: [
            ClipboardRepresentation(
                type: NSPasteboard.PasteboardType.string.rawValue,
                data: data
            ),
        ])

        guard case .link(let url) = ClipboardHistoryPreviewLoader.payloadPreview(
            record: record,
            payload: payload
        ) else {
            return XCTFail("Expected an offline link card")
        }
        XCTAssertEqual(url.absoluteString, value)
    }

    func testLinkCardMetadataIsDerivedOfflineFromURLComponents() throws {
        let url = try XCTUnwrap(URL(
            string: "https://example.com/docs/peek?q=clipboard"
        ))

        let metadata = ClipboardHistoryLinkCardMetadata.make(for: url)

        XCTAssertEqual(metadata.host, "example.com")
        XCTAssertEqual(metadata.scheme, "HTTPS")
        XCTAssertEqual(metadata.pathSummary, "/docs/peek")
    }

    func testHTTPAndHTTPSRemainAvailableAsOfflineLinkCards() throws {
        for value in [
            "http://localhost/private",
            "https://example.com/path",
        ] {
            let data = Data(value.utf8)
            let record = makeRecord(kind: .link, title: value, byteCount: data.count)
            let payload = ClipboardPayloadEnvelope(representations: [
                ClipboardRepresentation(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    data: data
                ),
            ])

            guard case .link(let url) = ClipboardHistoryPreviewLoader.payloadPreview(
                record: record,
                payload: payload
            ) else {
                return XCTFail("Expected an offline link card for \(value)")
            }
            XCTAssertEqual(url.absoluteString, value)
        }
    }

    func testUnsafeLinkSchemesDoNotCreateWebPreview() {
        for value in [
            "file:///tmp/private.txt",
            "javascript:alert(1)",
            "peek://settings",
        ] {
            let data = Data(value.utf8)
            let record = makeRecord(kind: .link, title: value, byteCount: data.count)
            let payload = ClipboardPayloadEnvelope(representations: [
                ClipboardRepresentation(
                    type: NSPasteboard.PasteboardType.string.rawValue,
                    data: data
                ),
            ])

            guard case .unavailable = ClipboardHistoryPreviewLoader.payloadPreview(
                record: record,
                payload: payload
            ) else {
                XCTFail("Unsafe URL scheme should not be rendered: \(value)")
                continue
            }
        }
    }

    func testLargeClipboardTextPreviewIsBounded() throws {
        let data = Data(String(repeating: "预览", count: 180_000).utf8)
        let record = ClipboardHistoryRecord(
            id: UUID(),
            createdAt: Date(),
            kind: .text,
            title: "fallback",
            detail: "",
            sourceApplicationName: nil,
            sourceBundleIdentifier: nil,
            payloadFilename: "test.clip",
            byteCount: Int64(data.count),
            digest: "test"
        )
        let payload = ClipboardPayloadEnvelope(representations: [
            ClipboardRepresentation(
                type: NSPasteboard.PasteboardType.string.rawValue,
                data: data
            ),
        ])

        guard case .text(let preview) = ClipboardHistoryPreviewLoader.payloadPreview(
            record: record,
            payload: payload
        ) else {
            return XCTFail("Expected a bounded text preview")
        }
        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThanOrEqual(
            preview.loadedByteCount,
            ClipboardHistoryPreviewLoader.maximumTextPreviewBytes
        )
        XCTAssertFalse(preview.text.isEmpty)
    }

    func testFolderPreviewCapsEntriesAndSkipsHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ClipboardPreview-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< ClipboardHistoryPreviewLoader.maximumFolderEntries + 5 {
            try Data("item \(index)".utf8).write(
                to: root.appendingPathComponent("item-\(index).txt")
            )
        }
        try Data("hidden".utf8).write(
            to: root.appendingPathComponent(".hidden.txt")
        )

        let preview = try XCTUnwrap(
            ClipboardHistoryPreviewLoader.folderPreview(at: root)
        )
        XCTAssertEqual(
            preview.entries.count,
            ClipboardHistoryPreviewLoader.maximumFolderEntries
        )
        XCTAssertEqual(
            preview.totalItemCount,
            ClipboardHistoryPreviewLoader.maximumFolderEntries + 1
        )
        XCTAssertFalse(preview.isTotalItemCountExact)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.entries.contains { $0.displayName == ".hidden.txt" })
    }

    func testFileInspectionReturnsUsefulMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-preview-\(UUID().uuidString).conf"
        )
        try Data("name=PEEK".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = try XCTUnwrap(
            ClipboardHistoryPreviewLoader.inspectFiles([url]).first
        )
        XCTAssertEqual(item.displayName, url.lastPathComponent)
        XCTAssertEqual(item.fileSize, 9)
        XCTAssertFalse(item.isDirectory)
        XCTAssertTrue(item.isAvailable)
    }

    func testFileInspectionCapsLargeSelections() {
        let urls = (0 ..< ClipboardHistoryPreviewLoader.maximumFileURLs + 12).map {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "PEEK-missing-\($0).txt"
            )
        }

        let items = ClipboardHistoryPreviewLoader.inspectFiles(urls)

        XCTAssertEqual(items.count, ClipboardHistoryPreviewLoader.maximumFileURLs)
    }

    private func makeRecord(
        kind: ClipboardHistoryKind,
        title: String,
        byteCount: Int
    ) -> ClipboardHistoryRecord {
        ClipboardHistoryRecord(
            id: UUID(),
            createdAt: Date(),
            kind: kind,
            title: title,
            detail: "",
            sourceApplicationName: nil,
            sourceBundleIdentifier: nil,
            payloadFilename: "test.clip",
            byteCount: Int64(byteCount),
            digest: "test"
        )
    }
}

extension ClipboardHistoryStoreTests {
    func testWriterLockLeavesPayloadReadableAndDeleteCanBeRetried() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let item = capture(text: "locked row", date: Date())
        let record = try await store.save(item)
        let databaseURL = root.appendingPathComponent("clipboard-history.sqlite3")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        let writer = try XCTUnwrap(connection)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        do {
            try await store.delete(record)
            XCTFail("A second writer cannot delete the record while the lock is held")
        } catch ClipboardHistoryError.unavailable(_) {}

        let payload = try await store.payload(for: record)
        XCTAssertEqual(payload, item.payload)
        let retained = try await store.loadRecords()
        XCTAssertEqual(retained.map(\.id), [record.id])
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await store.delete(record)
        let remaining = try await store.loadRecords()
        XCTAssertTrue(remaining.isEmpty)
        await store.close()
    }

    func testDuplicatePayloadRefreshesReturnedAndPersistedDisplayMetadata() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(rootURL: root)
        let old = capture(text: "https://example.com", date: Date(timeIntervalSince1970: 1))
        let first = try await store.save(old)
        let latest = ClipboardHistoryCapture(
            capturedAt: Date(timeIntervalSince1970: 2),
            kind: .link, title: "Example", detail: "example.com",
            sourceApplicationName: nil, sourceBundleIdentifier: nil,
            payload: old.payload
        )

        let result = try await store.save(latest)
        XCTAssertEqual(result.id, first.id)
        XCTAssertEqual(result.kind, latest.kind)
        XCTAssertEqual(result.title, latest.title)
        XCTAssertEqual(result.detail, latest.detail)
        let stored = try await store.loadRecords()
        XCTAssertEqual(stored, [result])
        await store.close()
    }
}

@MainActor
final class ClipboardHistoryPasteTests: XCTestCase {
    func testFocusLostBeforeDeliverySuppressesPaste() async {
        var checkedFocus = false
        do {
            try await ClipboardHistoryPanelController.deliverPaste(
                to: 42,
                activate: { true },
                hasFocus: { checkedFocus = true; return false },
                post: { _ in XCTFail("The original app lost focus before delivery") }
            )
            XCTFail("A failed delivery must be reported to the caller")
        } catch {
            XCTAssertTrue(checkedFocus)
        }
    }

    func testRejectedActivationNeverSendsPaste() async {
        do {
            try await ClipboardHistoryPanelController.deliverPaste(
                to: 42,
                activate: { false },
                hasFocus: { XCTFail("Activation was rejected"); return true },
                post: { _ in XCTFail("The original app could not be activated") }
            )
            XCTFail("A rejected activation must be reported to the caller")
        } catch {
            XCTAssertTrue(error is ClipboardHistoryError)
        }
    }

    func testConfirmedFocusRoutesPasteOnlyToOriginalProcess() async throws {
        var recipients: [pid_t] = []
        try await ClipboardHistoryPanelController.deliverPaste(
            to: 42, activate: { true }, hasFocus: { true },
            post: { recipients.append($0) }
        )
        XCTAssertEqual(recipients, [42])
    }
}
