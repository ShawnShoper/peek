import AppKit
import Carbon.HIToolbox
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
