import Carbon.HIToolbox
import CoreServices
import Combine
import SQLite3
import SwiftUI
import XCTest
@testable import PEEK

final class FileSearchTests: XCTestCase {
    func testPriorityApplicationEventDoesNotWaitForDirtyPersonalRootRecovery() async throws {
        let context = makeContext()
        let apps = context.directory.appendingPathComponent("Applications")
        let home = context.directory.appendingPathComponent("UnavailablePersonalRoot")
        let application = apps.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        for root in [apps, home] {
            let token = try await store.beginRootGeneration(rootURL: root)
            try await store.commitRootGeneration(token)
        }
        try await store.markDirty(home)
        try await store.markDirty(application)
        let indexer = FileSearchBackgroundIndexer(sink: store, rootProvider: { _ in
            .init(roots: [.init(url: apps, scope: .applications), .init(url: home, scope: .files)])
        }, activityGate: .init(requiredIdleDuration: 0))
        let result = await indexer.run(mode: .incremental, resourceProfile: .fast,
            requestedChangePaths: [application.path])
        XCTAssertEqual(result, .completed(mode: .incremental, roots: 1, items: 1))
        let matches = try await store.query(.init(query: "New"))
        let pending = try await store.dirtyPaths()
        XCTAssertEqual(matches.results.first?.item.url.standardizedFileURL.path, application.standardizedFileURL.path)
        XCTAssertEqual(pending, [home])
        await store.close()
    }

    func testCapacityWarningRemainsVisibleDuringCountingAndPresentationChanges() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginCounting(rootCount: 1)
        let before = await tracker.snapshot()
        await tracker.setCapacityWarning(true)
        let after = await tracker.snapshot()
        XCTAssertTrue(after?.hasCapacityWarning == true)
        XCTAssertTrue(after?.localizedCompactTitle.contains("容量已满") == true)
        if let before, let after { XCTAssertFalse(before.hasSamePresentation(as: after)) }
    }

    func testParentCommitDoesNotAcknowledgeNestedRootEvents() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let parent = context.directory
        let child = parent.appendingPathComponent("Documents")
        let childGeneration = try await store.beginRootGeneration(rootURL: child)
        try await store.commitRootGeneration(childGeneration)
        let changed = child.appendingPathComponent("new.txt")
        try await store.markDirty(changed)
        let parentGeneration = try await store.beginRootGeneration(rootURL: parent)
        try await store.commitRootGeneration(parentGeneration)
        let dirty = try await store.dirtyPaths()
        XCTAssertEqual(dirty, [changed])
        await store.close()
    }

    func testOwnIndexEventsNeverCreateAFilesystemFeedbackLoopEvenIfExplicitlyAuthorized() {
        let root = FileSearchIndexStore.defaultDatabaseURL.deletingLastPathComponent()
        let events: [FileSearchFileEvent] = [.init(path: FileSearchIndexStore.defaultDatabaseURL.path + "-wal",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile), id: 1)]
        let urls = FileSearchEventStream.changedURLs(events, roots: [.init(url: root, scope: .files)], policy: .init(paths: []))
        XCTAssertTrue(urls.isEmpty)
    }

    func testFullIndexAtCapacityKeepsBothApplicationsAndReportsLimited() async throws {
        let context = makeContext()
        let apps = context.directory.appendingPathComponent("Applications")
        let docs = context.directory.appendingPathComponent("Documents")
        for root in [apps, docs] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let appURLs = ["Existing.app", "New.app"].map { apps.appendingPathComponent($0) }
        for app in appURLs { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true) }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        defer { Task { await store.close() } }
        let appToken = try await store.beginRootGeneration(rootURL: apps)
        try await store.upsert([item(path: appURLs[0].path, name: "Existing", kind: .application)], in: appToken)
        try await store.commitRootGeneration(appToken)
        var files = [item(path: docs.path, name: "Documents", kind: .folder)]
        for index in 0..<998 {
            let file = docs.appendingPathComponent("file-\(index).txt")
            try Data().write(to: file)
            files.append(item(path: file.path, name: file.lastPathComponent, kind: .file))
        }
        let token = try await store.beginRootGeneration(rootURL: docs)
        try await store.upsert(files, in: token)
        try await store.commitRootGeneration(token)
        let tracker = FileSearchInitialIndexProgressTracker()
        let indexer = FileSearchBackgroundIndexer(sink: store, rootProvider: { _ in
            .init(roots: [.init(url: apps, scope: .applications), .init(url: docs, scope: .files)])
        }, activityGate: .init(requiredIdleDuration: 0),
            configuration: .init(maximumIndexedItems: 1_000, initialMaximumEntriesPerSecond: 10_000),
            initialIndexProgress: tracker)
        for _ in 0..<2 {
            let result = await indexer.run(mode: .full, resourceProfile: .fast)
            guard case .limited = result else { return XCTFail("Expected explicit capacity result: \(result)") }
            let metadata = try await store.metadata()
            let progress = await tracker.snapshot()
            XCTAssertEqual(metadata.statistics.indexedApplications, 2)
            XCTAssertEqual(metadata.statistics.indexedItems, 1_000)
            XCTAssertEqual(progress?.phase, .limited)
        }
        await store.close()
    }

    func testIncrementalUpdatesOnlyChangedFileAndHandlesRenameAndDelete() async throws {
        let context = makeContext()
        let root = context.directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let changed = root.appendingPathComponent("changed.txt")
        let untouched = root.appendingPathComponent("untouched.txt")
        try Data("first".utf8).write(to: changed)
        try Data("keep".utf8).write(to: untouched)
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let indexer = FileSearchBackgroundIndexer(sink: store, rootProvider: { _ in
            .init(roots: [.init(url: root, scope: .files)])
        }, activityGate: .init(requiredIdleDuration: 0))
        _ = await indexer.run(mode: .full, resourceProfile: .fast)
        // Removing an unrelated file without an event proves a single-file
        // delta doesn't secretly re-enumerate or replace the complete root.
        try FileManager.default.removeItem(at: untouched)
        try Data("new content".utf8).write(to: changed)
        try await store.markDirty(changed)
        let updated = await indexer.run(mode: .incremental, resourceProfile: .fast)
        XCTAssertEqual(updated, .completed(mode: .incremental, roots: 1, items: 1))
        let unchangedResult = try await store.query(.init(query: "untouched"))
        XCTAssertEqual(unchangedResult.results.count, 1)
        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: changed, to: renamed)
        try await store.markDirty(changed)
        try await store.markDirty(renamed)
        _ = await indexer.run(mode: .incremental, resourceProfile: .fast)
        let old = try await store.query(.init(query: "changed"))
        let new = try await store.query(.init(query: "renamed"))
        XCTAssertTrue(old.results.isEmpty)
        XCTAssertEqual(new.results.count, 1)
        try FileManager.default.removeItem(at: renamed)
        try await store.markDirty(renamed)
        _ = await indexer.run(mode: .incremental, resourceProfile: .fast)
        let removed = try await store.query(.init(query: "renamed"))
        XCTAssertTrue(removed.results.isEmpty)
        let idle = await indexer.run(mode: .incremental)
        XCTAssertEqual(idle, .noChanges)
        await store.close()
    }

    func testSubtreeCommitPreservesLaterEventsAndUnrelatedItems() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let path = context.directory.appendingPathComponent("changed")
        let other = context.directory.appendingPathComponent("other")
        let old = try await store.beginRootGeneration(rootURL: context.directory)
        try await store.upsert([item(path: path.path, name: "old", kind: .file),
                               item(path: other.path, name: "other", kind: .file)], in: old)
        try await store.commitRootGeneration(old)
        try await store.recordFileEvents([path], cursor: 10)
        let delta = try await store.beginRootGeneration(rootURL: context.directory)
        try await store.upsert([item(path: path.path, name: "updated", kind: .file)], in: delta)
        try await store.recordFileEvents([path], cursor: 11)
        try await store.commitSubtreeGeneration(delta, path: path.path)
        let dirty = try await store.dirtyPaths()
        let cursor = try await store.fileEventCursor()
        let count = try await store.committedItemCount()
        XCTAssertEqual(dirty.map(\.path), [path.path])
        XCTAssertEqual(cursor, 11)
        XCTAssertEqual(count, 2)
        await store.close()
    }

    func testEventCoalescingKeepsNestedRootsAndCollapsesAppInternals() {
        let root = URL(fileURLWithPath: "/Users/test")
        let docs = root.appendingPathComponent("Documents")
        let roots: [FileSearchBackgroundRoot] = [.init(url: root, scope: .files), .init(url: docs, scope: .files)]
        let urls = [root, docs.appendingPathComponent("note.txt"), root.appendingPathComponent("Demo.app/Contents/Info.plist")]
        let paths = FileSearchBackgroundIndexer<FileSearchIndexStore>.coalescedChangePaths(urls, roots: roots)
        XCTAssertEqual(Set(paths.map(\.path)), [root.path, docs.appendingPathComponent("note.txt").path])
        let appPaths = FileSearchBackgroundIndexer<FileSearchIndexStore>.coalescedChangePaths([urls[2]], roots: roots)
        XCTAssertEqual(appPaths.first?.lastPathComponent, "Demo.app")
    }

    func testRecoveryQueuePrioritizesNewAppsBeforeBroadPersonalRoot() {
        let home = URL(fileURLWithPath: "/Users/test")
        let downloads = home.appendingPathComponent("Downloads")
        let apps = URL(fileURLWithPath: "/Applications")
        let roots: [FileSearchBackgroundRoot] = [
            .init(url: home, scope: .files, priority: 1_000),
            .init(url: downloads, scope: .files, priority: 2),
            .init(url: apps, scope: .applications)
        ]
        let paths = FileSearchBackgroundIndexer<FileSearchIndexStore>.coalescedChangePaths(
            [home, downloads, apps, downloads.appendingPathComponent("New.app/Contents/Info.plist")], roots: roots)
        XCTAssertEqual(paths, [downloads, apps, home])
        let ordinary = FileSearchBackgroundIndexer<FileSearchIndexStore>.coalescedChangePaths(
            [home, downloads, apps], roots: roots)
        XCTAssertEqual(ordinary, [apps, downloads, home])
    }

    func testFileEventsIgnoreGeneratedTreesAndHandleDroppedEvents() {
        let root = URL(fileURLWithPath: "/Users/test")
        let roots: [FileSearchBackgroundRoot] = [.init(url: root, scope: .files)]
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        let paths = FileSearchEventStream.changedURLs([
            .init(path: root.appendingPathComponent("node_modules/a.js").path, flags: flags, id: 1),
            .init(path: root.appendingPathComponent("Library/Containers/com.shawnshoper.peek/a.db").path, flags: flags, id: 2),
            .init(path: root.appendingPathComponent("note.txt").path, flags: flags, id: 3)
        ], roots: roots, policy: .init(paths: []))
        XCTAssertEqual(paths.map(\.lastPathComponent), ["note.txt"])
        let dropped = FileSearchEventStream.changedURLs([
            .init(path: root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped), id: 4)
        ], roots: roots, policy: .init(paths: []))
        XCTAssertEqual(dropped, [root])
    }

    func testNativeFileEventStreamObservesNewFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PEEK-EventTest-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let found = expectation(description: "file event")
        found.assertForOverFulfill = false
        let stream = FileSearchEventStream(roots: [root], since: FSEventsGetCurrentEventId()) { events in
            if events.contains(where: { $0.path.hasSuffix("/created.txt") }) { found.fulfill() }
        }
        XCTAssertTrue(stream.start())
        defer { stream.stop() }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("created.txt"))
        await fulfillment(of: [found], timeout: 8)
    }

    func testRootRefreshRetryPolicyUsesBoundedExponentialBackoff() {
        let policy = FileSearchRootRefreshRetryPolicy(
            maximumWait: 10,
            initialDelay: 0.25,
            maximumDelay: 1
        )

        XCTAssertEqual(policy.delay(afterDeferredAttempt: 0), 0.25)
        XCTAssertEqual(policy.delay(afterDeferredAttempt: 1), 0.5)
        XCTAssertEqual(policy.delay(afterDeferredAttempt: 2), 1)
        XCTAssertEqual(policy.delay(afterDeferredAttempt: 12), 1)
        XCTAssertTrue(policy.shouldRetry(elapsed: 9.99))
        XCTAssertFalse(policy.shouldRetry(elapsed: 10))
    }

    func testRootRefreshRetryPolicyRejectsNonFiniteAndExtremeInputs() {
        let policy = FileSearchRootRefreshRetryPolicy(
            maximumWait: .infinity,
            initialDelay: .nan,
            maximumDelay: .infinity
        )

        XCTAssertEqual(policy.maximumWait, 5 * 60)
        XCTAssertEqual(policy.initialDelay, 0.35)
        XCTAssertEqual(policy.maximumDelay, 2)
        XCTAssertTrue(policy.delay(afterDeferredAttempt: 1_000).isFinite)
        XCTAssertLessThanOrEqual(policy.delay(afterDeferredAttempt: 1_000), 10)
    }

    @MainActor
    func testBuiltInCommandsMatchChinesePinyinAndEnglishQueries() throws {
        let cases: [(query: String, behavior: SearchPanelLaunchBehavior)] = [
            ("剪贴板", .peekClipboardHistory),
            ("jiantieban", .peekClipboardHistory),
            ("scrolling screenshot", .peekScrollingCapture),
            ("ocr", .peekOCRCapture),
            ("kuaijiejian", .peekSettings(.shortcuts)),
            ("appearance", .peekSettings(.appearance))
        ]

        for testCase in cases {
            let items = PEEKBuiltInSearchRegistration.items(
                matching: testCase.query,
                category: .all
            )
            XCTAssertTrue(
                items.contains { $0.launchBehavior == testCase.behavior },
                "query=\(testCase.query)"
            )
        }
        XCTAssertTrue(
            PEEKBuiltInSearchRegistration.items(matching: "", category: .all).isEmpty
        )
        XCTAssertTrue(
            PEEKBuiltInSearchRegistration.items(matching: "OCR", category: .files).isEmpty
        )
    }

    func testHealthDiagnosticsReportContainsOnlyRedactedRuntimeFacts() {
        let snapshot = PEEKDiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            version: "0.3.0 (3)",
            bundleIdentifier: "com.shawnshoper.peek",
            systemVersion: "macOS Test",
            architecture: "arm64",
            displayDescriptions: ["display-1:1512x982@2.0x"],
            screenRecordingGranted: true,
            accessibilityGranted: false,
            hotKeyStatuses: ["search": "registered"],
            hotKeyFailureCount: 0,
            indexPhase: FileSearchIndexPhase.ready.rawValue,
            indexedItemCount: 42,
            committedRootCount: 2,
            indexingRootCount: 0,
            inaccessibleLocationCount: 0,
            authorizedDocumentRootCount: 3,
            configuredDocumentRootCount: 4,
            clipboardHistoryEnabled: true,
            clipboardItemCount: 7,
            clipboardByteCount: 512
        )

        let checks = PEEKHealthDiagnostics.checks(for: snapshot)
        XCTAssertEqual(checks.first { $0.id == "capture" }?.severity, .healthy)
        XCTAssertEqual(checks.first { $0.id == "scrolling" }?.severity, .warning)
        XCTAssertEqual(checks.first { $0.id == "directories" }?.severity, .warning)

        let report = PEEKHealthDiagnostics.report(for: snapshot)
        XCTAssertTrue(report.contains("Index items: 42"))
        XCTAssertTrue(report.contains("Clipboard records: 7"))
        XCTAssertFalse(report.contains("/Users/"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("api key"))
    }

    @MainActor
    func testTranslationSubAppMatchesChinesePinyinAndEnglishQueries() {
        for query in ["翻译", "fanyi", "fy", "translate", "PEEK Translate"] {
            let item = PEEKTranslateSearchRegistration.item(
                matching: query,
                category: .all
            )
            XCTAssertEqual(item?.id, PEEKTranslateSearchRegistration.itemIdentifier)
            XCTAssertEqual(item?.launchBehavior, .peekTranslation)
            XCTAssertEqual(item?.category, .applications)
        }
        XCTAssertNil(
            PEEKTranslateSearchRegistration.item(
                matching: "",
                category: .all
            )
        )
        XCTAssertNil(
            PEEKTranslateSearchRegistration.item(
                matching: "翻译",
                category: .files
            )
        )
    }

    @MainActor
    func testTranslationSubAppOnlyEnablesOpenAction() async throws {
        let item = try XCTUnwrap(
            PEEKTranslateSearchRegistration.item(
                matching: "翻译",
                category: .applications
            )
        )
        let capabilities = await DefaultSearchPanelActionHandler()
            .capabilities(for: item)
        XCTAssertEqual(capabilities[.open], .enabled)
        for action in SearchPanelFileAction.allCases where action != .open {
            XCTAssertEqual(capabilities[action]?.isEnabled, false)
        }
    }

    func testPinyinFullAndInitialQueriesMatchChineseApplication() {
        let notes = prepared(name: "备忘录", kind: .application)

        let full = FileSearchMatcher.rank(
            [notes],
            request: FileSearchRequest(query: "bei wang lu")
        )
        let initials = FileSearchMatcher.rank(
            [notes],
            request: FileSearchRequest(query: "bwl")
        )

        XCTAssertEqual(full.map(\.item.displayName), ["备忘录"])
        XCTAssertEqual(initials.map(\.item.displayName), ["备忘录"])
    }

    func testLocalizedApplicationAliasesMatchChinesePinyinInitialsAndPackageName() {
        let calculator = FileSearchPreparedItem(item: FileSearchItem(
            url: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            displayName: "计算器",
            kind: .application,
            typeDescription: "应用程序",
            isHidden: false,
            searchAliases: ["Calculator", "計算機"]
        ))

        for query in ["计算器", "jisuanqi", "jsq", "calc"] {
            let results = FileSearchMatcher.rank(
                [calculator],
                request: FileSearchRequest(query: query)
            )
            XCTAssertEqual(
                results.first?.item.displayName,
                "计算器",
                "query=\(query)"
            )
        }
    }

    func testApplicationNameResolverReadsLocalizedInfoPlistTable() throws {
        let appURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Calculator-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: appURL) }
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.calculator",
            "CFBundleName": "Calculator",
            "CFBundleDisplayName": "Calculator",
            "CFBundlePackageType": "APPL"
        ]
        let table: [String: Any] = [
            "en": ["CFBundleDisplayName": "Calculator"],
            "zh_CN": ["CFBundleDisplayName": "计算器"],
            "zh_TW": ["CFBundleDisplayName": "計算機"]
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contentsURL.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(
            fromPropertyList: table,
            format: .binary,
            options: 0
        ).write(to: resourcesURL.appendingPathComponent("InfoPlist.loctable"))

        let names = FileSearchApplicationNameResolver.resolve(
            url: appURL,
            preferredLanguages: ["zh-Hans-CN", "en"]
        )

        XCTAssertEqual(names.displayName, "计算器")
        XCTAssertTrue(names.aliases.contains("Calculator"))
        XCTAssertTrue(names.aliases.contains("計算機"))
    }

    func testApplicationNameResolverReadsLocalizedInfoPlistStringsForAnyApp() throws {
        let appURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LinguaDesk-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: appURL) }
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.linguadesk",
            "CFBundleName": "LinguaDesk",
            "CFBundleDisplayName": "LinguaDesk",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contentsURL.appendingPathComponent("Info.plist"))

        for (localization, displayName) in [
            "en": "LinguaDesk",
            "zh-Hans": "双语助手",
            "zh-Hant": "雙語助手"
        ] {
            let localizationURL = resourcesURL.appendingPathComponent(
                "\(localization).lproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: localizationURL,
                withIntermediateDirectories: true
            )
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleDisplayName": displayName],
                format: .binary,
                options: 0
            ).write(to: localizationURL.appendingPathComponent("InfoPlist.strings"))
        }

        let names = FileSearchApplicationNameResolver.resolve(
            url: appURL,
            preferredLanguages: ["zh-Hans-CN", "en"]
        )
        let prepared = FileSearchPreparedItem(item: FileSearchItem(
            url: appURL,
            displayName: names.displayName,
            kind: .application,
            typeDescription: "应用程序",
            isHidden: false,
            searchAliases: names.aliases
        ))

        XCTAssertEqual(names.displayName, "双语助手")
        XCTAssertTrue(names.aliases.contains("LinguaDesk"))
        XCTAssertTrue(names.aliases.contains("雙語助手"))
        for query in ["双语助手", "shuangyuzhushou", "syzs", "lingua"] {
            XCTAssertEqual(
                FileSearchMatcher.rank(
                    [prepared],
                    request: FileSearchRequest(query: query)
                ).first?.item.displayName,
                "双语助手",
                "query=\(query)"
            )
        }
    }

    func testGenericLocalizedAliasesSupportMultipleChineseAndBilingualApps() {
        let applications = [
            FileSearchPreparedItem(item: FileSearchItem(
                url: URL(fileURLWithPath: "/Applications/TextLab.app"),
                displayName: "文字工作台",
                kind: .application,
                typeDescription: "应用程序",
                isHidden: false,
                searchAliases: ["TextLab", "文字工作臺"]
            )),
            FileSearchPreparedItem(item: FileSearchItem(
                url: URL(fileURLWithPath: "/Applications/Voice Notes.app"),
                displayName: "语音便签 Voice Notes",
                kind: .application,
                typeDescription: "应用程序",
                isHidden: false,
                searchAliases: ["Voice Notes", "語音便籤"]
            ))
        ]

        let expectations: [(String, String)] = [
            ("文字工作台", "文字工作台"),
            ("wenzigongzuotai", "文字工作台"),
            ("wzgzt", "文字工作台"),
            ("textl", "文字工作台"),
            ("语音便签", "语音便签 Voice Notes"),
            ("yuyinbianqian", "语音便签 Voice Notes"),
            ("yybq", "语音便签 Voice Notes"),
            ("voice", "语音便签 Voice Notes")
        ]
        for (query, expectedName) in expectations {
            XCTAssertEqual(
                FileSearchMatcher.rank(
                    applications,
                    request: FileSearchRequest(query: query)
                ).first?.item.displayName,
                expectedName,
                "query=\(query)"
            )
        }
    }

    func testSystemCalculatorResolvesChineseDisplayNameAndEnglishAlias() throws {
        let calculatorURL = URL(
            fileURLWithPath: "/System/Applications/Calculator.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: calculatorURL.path) else {
            throw XCTSkip("当前 macOS 不包含系统计算器")
        }

        let names = FileSearchApplicationNameResolver.resolve(
            url: calculatorURL,
            preferredLanguages: ["zh-Hans-CN", "en"]
        )

        XCTAssertEqual(names.displayName, "计算器")
        XCTAssertTrue(names.aliases.contains("Calculator"))
    }

    func testEnglishFuzzyQueryMatchesWordInitials() {
        let code = prepared(name: "Visual Studio Code", kind: .application)

        let results = FileSearchMatcher.rank(
            [code],
            request: FileSearchRequest(query: "vsc")
        )

        XCTAssertEqual(results.first?.item.displayName, "Visual Studio Code")
    }

    func testSearchPanelLocalizesEveryResultKindInsteadOfShowingStoredRawType() {
        XCTAssertEqual(
            FileSearchPanelProvider.localizedKindDescription(.application),
            L10n.tr("应用程序")
        )
        XCTAssertEqual(
            FileSearchPanelProvider.localizedKindDescription(.file),
            L10n.tr("文件")
        )
        XCTAssertEqual(
            FileSearchPanelProvider.localizedKindDescription(.folder),
            L10n.tr("文件夹")
        )
    }

    func testAllResultsPlaceApplicationsBeforeDocumentsAndKeepDocumentRelevance() {
        let application = prepared(name: "Network Notes", kind: .application)
        let file = prepared(name: "note", kind: .file)
        let folder = prepared(name: "note", kind: .folder)

        let results = FileSearchMatcher.rank(
            [folder, file, application],
            request: FileSearchRequest(query: "note")
        )

        XCTAssertEqual(results.map(\.item.kind), [.application, .file, .folder])
    }

    func testApplicationWinsOnlyWhenNormalizedDisplayNamesAreEqual() {
        let items = [
            prepared(name: "Note", kind: .folder),
            prepared(name: "note", kind: .file),
            prepared(name: "NOTE", kind: .application)
        ]

        let results = FileSearchMatcher.rank(
            items,
            request: FileSearchRequest(query: "note")
        )

        XCTAssertEqual(results.map(\.item.kind), [.application, .file, .folder])
    }

    func testCategoryFilteringAndLimitAreDeterministic() {
        let items = [
            prepared(name: "Zulu", kind: .folder),
            prepared(name: "Alpha", kind: .folder),
            prepared(name: "Notes", kind: .application)
        ]

        let results = FileSearchMatcher.rank(
            items,
            request: FileSearchRequest(query: "", category: .folders, limit: 1)
        )

        XCTAssertEqual(results.map(\.item.displayName), ["Alpha"])
    }

    func testHiddenItemsAreOptIn() {
        let visible = prepared(name: "notes", kind: .file)
        let hidden = prepared(name: ".notes-private", kind: .file)

        let defaultResults = FileSearchMatcher.rank(
            [hidden, visible],
            request: FileSearchRequest(query: "notes")
        )
        let includingHidden = FileSearchMatcher.rank(
            [hidden, visible],
            request: FileSearchRequest(query: "notes", includeHidden: true)
        )

        XCTAssertEqual(defaultResults.map(\.item.displayName), ["notes"])
        XCTAssertEqual(
            Set(includingHidden.map(\.item.displayName)),
            ["notes", ".notes-private"]
        )
    }

    func testSearchDefaultIsControlSpaceAndLegacyConfigurationMigratesIt() throws {
        let defaultShortcut = ScreenshotGlobalHotKeyAction.search.defaultShortcut
        XCTAssertEqual(defaultShortcut.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(defaultShortcut.modifiers, UInt32(controlKey))
        XCTAssertEqual(defaultShortcut.displayString, "⌃空格")

        let region = ScreenshotGlobalHotKeyAction.region.defaultShortcut
        let scrolling = ScreenshotGlobalHotKeyAction.scrolling.defaultShortcut
        let ocr = ScreenshotGlobalHotKeyAction.ocr.defaultShortcut
        let legacy = """
        {
          "region": {"keyCode": \(region.keyCode), "modifiers": \(region.modifiers)},
          "scrolling": {"keyCode": \(scrolling.keyCode), "modifiers": \(scrolling.modifiers)},
          "ocr": {"keyCode": \(ocr.keyCode), "modifiers": \(ocr.modifiers)}
        }
        """
        let decoded = try JSONDecoder().decode(
            ScreenshotHotKeyConfiguration.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.search, defaultShortcut)
        XCTAssertEqual(
            decoded.translation,
            ScreenshotGlobalHotKeyAction.translation.defaultShortcut
        )
        XCTAssertEqual(
            decoded.clipboardHistory,
            ScreenshotGlobalHotKeyAction.clipboardHistory.defaultShortcut
        )
    }

    func testInitialApplicationIndexProgressProvidesReadableETAAndFraction() {
        let scheduled = FileSearchInitialIndexProgressSnapshot(
            phase: .scheduled,
            completedRoots: 0,
            totalRoots: 4,
            indexedApplications: 0,
            estimatedRemaining: 12
        )
        XCTAssertEqual(scheduled.fractionCompleted, 0)
        XCTAssertEqual(scheduled.progressBarValue, 0)
        XCTAssertEqual(scheduled.localizedCompactTitle, "准备索引")
        XCTAssertEqual(scheduled.localizedCompactDetail, "预计 12 秒")
        XCTAssertEqual(scheduled.localizedStatusMessage, "首次索引预计约 12 秒")

        let counting = FileSearchInitialIndexProgressSnapshot(
            phase: .counting,
            completedRoots: 1,
            totalRoots: 4,
            indexedApplications: 0,
            estimatedRemaining: nil,
            discoveredItems: 150,
            currentRootName: "/System/Applications"
        )
        XCTAssertNil(counting.fractionCompleted)
        XCTAssertEqual(counting.progressBarValue, 0)
        XCTAssertEqual(counting.localizedCompactTitle, "统计总量：系统应用")
        XCTAssertEqual(counting.localizedCompactDetail, "已发现 150 项")
        XCTAssertEqual(
            counting.localizedStatusMessage,
            "正在统计文件 · /System/Applications，已发现 150 项，正在统计目录 2/4"
        )

        let indexing = FileSearchInitialIndexProgressSnapshot(
            phase: .indexingApplications,
            completedRoots: 2,
            totalRoots: 4,
            indexedApplications: 120,
            estimatedRemaining: 65,
            discoveredItems: 150,
            indexedItems: 120,
            currentRootName: "/Applications"
        )
        XCTAssertEqual(indexing.fractionCompleted, 0.8)
        XCTAssertEqual(indexing.progressBarValue, 0.8)
        XCTAssertEqual(indexing.localizedCompactTitle, "索引：应用程序")
        XCTAssertEqual(
            indexing.localizedCompactDetail,
            "120 / 150 项 · 80% · 目录 3/4"
        )
        XCTAssertEqual(
            indexing.localizedStatusMessage,
            "应用索引中 · /Applications，已处理 120 / 150 项，正在处理目录 3/4，预计剩余 2 分钟"
        )

        let documents = FileSearchInitialIndexProgressSnapshot(
            phase: .counting,
            completedRoots: 1,
            totalRoots: 7,
            indexedApplications: 0,
            estimatedRemaining: nil,
            discoveredItems: 10_849,
            currentRootName: "/Users/test/Documents"
        )
        XCTAssertEqual(documents.localizedCompactTitle, "统计总量：文稿")
        XCTAssertEqual(documents.localizedCompactDetail, "已发现 10849 项")
    }

    func testUnfinishedIndexPhasesKeepAnEmptyTrackWithoutInventingPercentages() {
        for phase: FileSearchInitialIndexProgressPhase in [
            .scheduled, .counting, .waitingToRetry, .failed
        ] {
            let progress = FileSearchInitialIndexProgressSnapshot(
                phase: phase, completedRoots: 1, totalRoots: 7,
                indexedApplications: 0, estimatedRemaining: nil,
                discoveredItems: 10_849, indexedItems: 5_000,
                currentRootName: "/Users/test/Documents",
                failureMessage: "Permission denied"
            )
            XCTAssertEqual(progress.progressBarValue, 0, "\(phase)")
            XCTAssertFalse(progress.localizedCompactDetail.contains("%"), "\(phase)")
            XCTAssertFalse(progress.localizedStatusMessage.isEmpty)
        }
    }

    @MainActor
    func testIndexProgressRowRendersTrackForEveryUnfinishedPhaseInBothAppearances() throws {
        let phases: [FileSearchInitialIndexProgressPhase] = [
            .scheduled, .counting, .waitingToRetry, .failed,
            .indexingApplications, .indexingFiles
        ]
        for scheme in [ColorScheme.light, .dark] {
            for phase in phases {
                let progress = FileSearchInitialIndexProgressSnapshot(
                    phase: phase, completedRoots: 0, totalRoots: 2,
                    indexedApplications: 0, estimatedRemaining: nil,
                    discoveredItems: 100, indexedItems: 60,
                    currentRootName: "/Users/test/Documents",
                    failureMessage: "Permission denied"
                )
                let renderer = ImageRenderer(content:
                    SearchPanelIndexProgressRow(progress: progress)
                        .frame(width: SearchPanelLayout.minimumWidth)
                        .environment(\.colorScheme, scheme)
                        .background(scheme == .light ? Color.white : Color.black)
                )
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                XCTAssertEqual(bitmap.pixelsHigh, Int(SearchPanelLayout.indexProgressHeight))
                let rightX = bitmap.pixelsWide - 30
                // The right side is unfilled at 60%. Locate the fixed track
                // below the text without depending on font rasterization.
                let trackY = try XCTUnwrap((bitmap.pixelsHigh / 2 ..< bitmap.pixelsHigh).first { y in
                    guard let color = bitmap.colorAt(x: rightX, y: y)?.usingColorSpace(.deviceRGB) else {
                        return false
                    }
                    return color.redComponent > 0.05 && color.redComponent < 0.95
                        && abs(color.redComponent - color.blueComponent) < 0.02
                }, "Missing track: \(phase), \(scheme)")
                let left = try XCTUnwrap(bitmap.colorAt(x: 30, y: trackY)?.usingColorSpace(.deviceRGB))
                let right = try XCTUnwrap(bitmap.colorAt(x: rightX, y: trackY)?.usingColorSpace(.deviceRGB))
                let middle = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: trackY)?.usingColorSpace(.deviceRGB))
                if progress.progressBarValue == 0 {
                    XCTAssertEqual(left.redComponent, right.redComponent, accuracy: 0.02)
                    XCTAssertEqual(middle.redComponent, right.redComponent, accuracy: 0.02)
                    XCTAssertEqual(left.blueComponent, right.blueComponent, accuracy: 0.02)
                } else {
                    XCTAssertGreaterThan(left.blueComponent - left.redComponent, 0.2)
                    XCTAssertGreaterThan(middle.blueComponent - middle.redComponent, 0.2)
                    let unfilled = try XCTUnwrap(bitmap.colorAt(
                        x: Int(Double(bitmap.pixelsWide) * 0.8), y: trackY
                    )?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(unfilled.redComponent, right.redComponent, accuracy: 0.02)
                }
            }
        }
    }

    func testSearchWithNoCommittedIndexReturnsImmediatelyWithoutScanning() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        try FileManager.default.createDirectory(
            at: context.directory,
            withIntermediateDirectories: true
        )
        let unindexedFile = context.directory.appendingPathComponent("not-indexed.txt")
        try Data("exists".utf8).write(to: unindexedFile)

        let snapshots = await context.service.search(FileSearchRequest(query: "not-indexed"))
        var received: [FileSearchSnapshot] = []
        for await snapshot in snapshots { received.append(snapshot) }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.phase, .idle)
        XCTAssertEqual(received.first?.results, [])
        XCTAssertEqual(received.first?.statistics.indexedItems, 0)
        let metadata = try await context.service.indexMetadata()
        XCTAssertEqual(metadata.committedRootCount, 0)
        XCTAssertEqual(metadata.indexingRootCount, 0)
        XCTAssertEqual(metadata.dirtyPathCount, 0)
    }

    func testSQLiteStoreConstructionIsLazyUntilFirstActorAccess() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.databaseURL.path))

        _ = try await context.service.indexMetadata()

        XCTAssertTrue(FileManager.default.fileExists(atPath: context.databaseURL.path))
    }

    func testSingleCharacterQueryUsesBoundedIndexedPrefixPolicy() {
        XCTAssertTrue(FileSearchIndexStore.shouldUseBoundedPrefixQuery(
            compactQuery: "j"
        ))
        XCTAssertTrue(FileSearchIndexStore.shouldUseBoundedPrefixQuery(
            compactQuery: "计"
        ))
        XCTAssertFalse(FileSearchIndexStore.shouldUseBoundedPrefixQuery(
            compactQuery: ""
        ))
        XCTAssertFalse(FileSearchIndexStore.shouldUseBoundedPrefixQuery(
            compactQuery: "js"
        ))
    }

    func testSQLiteStartupFailureIsRetryableOnTheSameStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-RetryableIndexStartup-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = directory.appendingPathComponent("SearchIndex.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: databaseURL,
            withIntermediateDirectories: true
        )
        let store = FileSearchIndexStore(databaseURL: databaseURL)

        do {
            _ = try await store.metadata()
            XCTFail("a directory at the database path must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        try FileManager.default.removeItem(at: databaseURL)
        let recovered = try await store.metadata()
        XCTAssertEqual(recovered.committedRootCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testOneCharacterPrefixStillMatchesChineseNameAndPinyin() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(
                path: "/Applications/Calculator.app",
                name: "计算器",
                kind: .application,
                searchAliases: ["Calculator"]
            )],
            generation: generation
        )
        try await context.service.commitRootGeneration(generation)

        for query in ["计", "j", "c", "a"] {
            let snapshot = await context.service.currentSnapshot(
                for: FileSearchRequest(query: query)
            )
            XCTAssertEqual(snapshot.results.first?.item.displayName, "计算器")
        }
    }

    func testSQLiteProgressHandlerInterruptsAnActiveFuzzyQuery() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        _ = try await context.service.indexMetadata()
        try seedLargeCommittedIndex(at: context.databaseURL, itemCount: 40_000)
        let store = FileSearchIndexStore(
            databaseURL: context.databaseURL,
            queryTimeLimit: 1
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let task = Task {
            try await store.query(FileSearchRequest(
                query: "zz-not-present",
                category: .files,
                limit: 80
            ))
        }
        try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("the active SQLite query should be interrupted")
        } catch is CancellationError {
            // Expected: cancellation crosses sqlite3_step through the progress handler.
        }
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            1,
            "cancelled fuzzy scans must not keep the search actor occupied"
        )
    }

    func testLargeUncancelledFuzzyQueryHonorsWallClockBudget() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        _ = try await context.service.indexMetadata()
        try seedLargeCommittedIndex(at: context.databaseURL, itemCount: 40_000)
        let store = FileSearchIndexStore(
            databaseURL: context.databaseURL,
            queryTimeLimit: 0.03
        )
        let startedAt = ProcessInfo.processInfo.systemUptime

        let result = try await store.query(FileSearchRequest(
            query: "zz-not-present",
            category: .files,
            limit: 80
        ))

        XCTAssertTrue(result.results.isEmpty)
        XCTAssertEqual(result.metadata.statistics.indexedFiles, 40_000)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            0.5,
            "a no-hit fuzzy scan must yield before it can stall the search UI"
        )
    }

    func testSQLiteQueryFailureIsExplicitInsteadOfLookingLikeEmptyIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-BrokenIndex-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = directory.appendingPathComponent(
            "SearchIndex.sqlite3",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: databaseURL,
            withIntermediateDirectories: true
        )
        let service = FileSearchService(
            store: FileSearchIndexStore(databaseURL: databaseURL)
        )

        let snapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "anything")
        )
        XCTAssertNotNil(snapshot.failure)
        XCTAssertTrue(snapshot.results.isEmpty)

        let stream = await service.search(FileSearchRequest(query: "anything"))
        var streamedFailure: FileSearchFailure?
        for await update in stream {
            streamedFailure = update.failure
        }
        XCTAssertNotNil(streamedFailure)
    }

    func testCommittedApplicationIsQueryableWhileFileRootIsStillIndexing() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let applicationRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let fileRoot = URL(fileURLWithPath: "/authorized", isDirectory: true)

        let applicationGeneration = try await context.service.beginRootGeneration(
            rootURL: applicationRoot
        )
        try await context.service.upsert(
            items: [item(
                path: "/Applications/Notes.app",
                name: "备忘录",
                kind: .application
            )],
            generation: applicationGeneration
        )
        try await context.service.commitRootGeneration(
            applicationGeneration,
            statistics: .init(indexedApplications: 1)
        )

        let fileGeneration = try await context.service.beginRootGeneration(rootURL: fileRoot)
        try await context.service.upsert(
            items: [item(
                path: "/authorized/draft.txt",
                name: "draft.txt",
                kind: .file
            )],
            generation: fileGeneration
        )

        let available = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "bei wang")
        )
        let stagedFile = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "draft")
        )
        let metadata = try await context.service.indexMetadata()

        XCTAssertEqual(available.results.map(\.item.kind), [.application])
        XCTAssertTrue(stagedFile.results.isEmpty)
        XCTAssertEqual(metadata.committedRootCount, 1)
        XCTAssertEqual(metadata.indexingRootCount, 1)
    }

    func testInitialApplicationIndexShowsDynamicETAAndHidesAfterCommit() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.schedule(applicationRootCount: 3, delay: 5)
        let scheduled = await tracker.snapshot()
        XCTAssertEqual(scheduled?.phase, .scheduled)
        XCTAssertNotNil(scheduled?.estimatedRemaining)
        XCTAssertTrue(scheduled?.localizedStatusMessage.contains("预计") == true)

        await tracker.beginCounting(rootCount: 3)
        await tracker.beginRoot(named: "/Applications")
        await tracker.recordDiscovered(40)
        await tracker.completeRoot()
        let counted = await tracker.snapshot()
        XCTAssertEqual(counted?.phase, .counting)
        XCTAssertEqual(counted?.completedRoots, 1)
        XCTAssertEqual(counted?.discoveredItems, 40)
        XCTAssertNil(counted?.fractionCompleted)

        await tracker.beginIndexing(rootCount: 3, totalItemCount: 40)
        await tracker.beginRoot(named: "/Applications")
        await tracker.recordEncountered(40)
        await tracker.recordIndexed(24)
        await tracker.completeRoot()
        let indexing = await tracker.snapshot()
        XCTAssertEqual(indexing?.phase, .indexingApplications)
        XCTAssertEqual(indexing?.completedRoots, 1)
        XCTAssertEqual(indexing?.indexedApplications, 24)
        XCTAssertEqual(indexing?.discoveredItems, 40)
        XCTAssertEqual(indexing?.indexedItems, 24)
        XCTAssertEqual(indexing?.fractionCompleted, 0.6)
        XCTAssertNotNil(indexing?.estimatedRemaining)

        await tracker.completeRoot()
        await tracker.completeRoot()
        await tracker.finish()
        let completed = await tracker.snapshot()
        XCTAssertNil(completed)
    }

    func testLiveIndexProgressAllowsDiscoveredTotalToGrowDuringScan() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(
            rootCount: 2,
            totalItemCount: 20,
            phase: .indexingFiles
        )
        await tracker.beginRoot(named: "/Users/test/Desktop", phase: .indexingFiles)
        await tracker.recordEncountered(20)
        await tracker.recordIndexed(16)
        let first = await tracker.snapshot()

        await tracker.recordEncountered(15, newlyDiscovered: 15)
        await tracker.recordIndexed(8)
        let second = await tracker.snapshot()

        XCTAssertEqual(first?.discoveredItems, 20)
        XCTAssertEqual(first?.indexedItems, 16)
        XCTAssertEqual(second?.discoveredItems, 35)
        XCTAssertEqual(second?.indexedItems, 24)
        XCTAssertTrue(
            second?.localizedStatusMessage.contains(
                "已处理 24 / 35 项"
            ) == true
        )
    }

    func testIndexProgressNeverReportsCompleteWhileLaterRootsRemain() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(rootCount: 7, totalItemCount: 35)
        await tracker.completeRoot()
        await tracker.beginRoot(named: "/System/Applications")
        await tracker.recordEncountered(35)
        await tracker.recordIndexed(35)

        let caughtUp = await tracker.snapshot()
        XCTAssertEqual(caughtUp?.completedRoots, 1)
        XCTAssertEqual(caughtUp?.fractionCompleted, 0.995)
        XCTAssertTrue(
            caughtUp?.localizedStatusMessage.contains("正在处理目录 2/7") == true
        )

        await tracker.recordEncountered(30, newlyDiscovered: 30)
        let grown = await tracker.snapshot()
        XCTAssertEqual(grown?.discoveredItems, 65)
        XCTAssertEqual(grown?.indexedItems, 35)
        XCTAssertEqual(grown?.fractionCompleted, 35.0 / 65.0)
    }

    func testNewItemsGrowTotalBeforeEarlierRootExceedsGlobalCount() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(rootCount: 2, totalItemCount: 100)
        await tracker.beginRoot(named: "/A", countedItemCount: 10)
        await tracker.recordEncountered(50, newlyDiscovered: 40)
        await tracker.recordIndexed(50)
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot?.discoveredItems, 140)
        XCTAssertEqual(snapshot?.fractionCompleted, 50.0 / 140.0)
        XCTAssertTrue(snapshot?.localizedCompactDetail.contains("35%") == true)
    }

    func testCompletedRootRemovesDisappearedItemsFromTotal() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(rootCount: 2, totalItemCount: 100)
        await tracker.beginRoot(named: "/A", countedItemCount: 10)
        await tracker.recordEncountered(6)
        await tracker.recordIndexed(6)
        await tracker.completeRoot(unencounteredItems: 4)
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot?.discoveredItems, 96)
        XCTAssertEqual(snapshot?.indexedItems, 6)
        XCTAssertEqual(snapshot?.completedRoots, 1)
    }

    func testAbortedRootRemovesItsStagingProgressButRetainsEarlierWork() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(rootCount: 3, totalItemCount: 100)
        await tracker.beginRoot(named: "/A", countedItemCount: 10)
        await tracker.recordEncountered(10)
        await tracker.recordIndexed(10)
        await tracker.completeRoot()
        await tracker.beginRoot(named: "/B", countedItemCount: 20)
        await tracker.recordEncountered(15, newlyDiscovered: 5)
        await tracker.recordIndexed(15)
        await tracker.completeRoot(failed: true)
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot?.discoveredItems, 80)
        XCTAssertEqual(snapshot?.indexedItems, 10)
        XCTAssertEqual(snapshot?.completedRoots, 2)
    }

    func testIndexPercentageUsesExactOverflowSafeIntegerArithmetic() {
        let cases: [(processed: Int, total: Int, expected: Int)] = [
            (57, 100, 57), (29, 100, 29), (0, 100, 0),
            (100, 100, 99), (Int.max - 1, Int.max, 99), (1, 3, 33)
        ]
        for entry in cases {
            let snapshot = FileSearchInitialIndexProgressSnapshot(
                phase: .indexingFiles,
                completedRoots: 0,
                totalRoots: 1,
                indexedApplications: 0,
                estimatedRemaining: nil,
                discoveredItems: entry.total,
                indexedItems: entry.processed
            )
            XCTAssertTrue(
                snapshot.localizedCompactDetail.contains("· \(entry.expected)% ·"),
                snapshot.localizedCompactDetail
            )
        }
    }

    func testIndexFailureShowsActualCauseInsteadOfWaitingForIdle() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginCounting(rootCount: 2)
        await tracker.fail("/Documents: permission denied")
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot?.phase, .failed)
        XCTAssertEqual(snapshot?.localizedCompactTitle, "索引未完成")
        XCTAssertEqual(snapshot?.localizedStatusMessage, "/Documents: permission denied")
        XCTAssertEqual(snapshot?.progressBarValue, 0)
        await tracker.beginCounting(rootCount: 2)
        let retry = await tracker.snapshot()
        XCTAssertEqual(retry?.phase, .counting)
        XCTAssertNil(retry?.failureMessage)
    }

    func testLiveIndexProgressKeepsRecentPathsForSettingsLog() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.beginIndexing(
            rootCount: 1,
            totalItemCount: 1,
            phase: .indexingFiles
        )
        await tracker.beginRoot(named: "/Documents", phase: .indexingFiles)
        await tracker.recordPaths((0 ..< 16).map { "/Documents/item-\($0).txt" })

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot?.currentRootName, "/Documents")
        XCTAssertEqual(snapshot?.recentPaths.count, 12)
        XCTAssertEqual(snapshot?.recentPaths.first, "/Documents/item-4.txt")
        XCTAssertEqual(snapshot?.recentPaths.last, "/Documents/item-15.txt")
    }

    func testCommittedSQLiteIndexUsesApplicationGroupPriorityAndDocumentRelevance() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(items: [
            item(path: "/authorized/备忘录.app", name: "备忘录", kind: .application),
            item(path: "/authorized/bwl.txt", name: "bwl", kind: .file),
            item(path: "/authorized/bwl", name: "bwl", kind: .folder)
        ], generation: generation)
        try await context.service.commitRootGeneration(generation)

        let snapshot = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "bwl")
        )

        XCTAssertEqual(snapshot.phase, .ready)
        XCTAssertEqual(
            snapshot.results.map(\.item.kind),
            [.application, .file, .folder]
        )
        XCTAssertEqual(snapshot.results.first?.item.displayName, "备忘录")

        let sameNameGeneration = try await context.service.beginRootGeneration(
            rootURL: URL(fileURLWithPath: "/same-name")
        )
        try await context.service.upsert(items: [
            item(path: "/same-name/note.app", name: "note", kind: .application),
            item(path: "/same-name/note.txt", name: "note", kind: .file),
            item(path: "/same-name/note", name: "note", kind: .folder)
        ], generation: sameNameGeneration)
        try await context.service.commitRootGeneration(sameNameGeneration)
        let sameNameSnapshot = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "note")
        )
        XCTAssertEqual(
            sameNameSnapshot.results.map(\.item.kind),
            [.application, .file, .folder]
        )
    }

    func testCommittedSQLiteApplicationAliasesSupportLocalizedAndEnglishQueries() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(items: [
            item(
                path: "/System/Applications/Calculator.app",
                name: "计算器",
                kind: .application,
                searchAliases: ["Calculator", "計算機"]
            )
        ], generation: generation)
        try await context.service.commitRootGeneration(
            generation,
            statistics: .init(indexedApplications: 1)
        )

        for query in ["计算器", "jisuanqi", "jsq", "calc"] {
            let snapshot = await context.service.currentSnapshot(
                for: FileSearchRequest(query: query)
            )
            XCTAssertEqual(
                snapshot.results.first?.item.displayName,
                "计算器",
                "query=\(query)"
            )
        }
    }

    func testStagedGenerationIsInvisibleAndAbortPreservesPreviousGeneration() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let first = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(path: "/authorized/old.txt", name: "old", kind: .file)],
            generation: first
        )
        try await context.service.commitRootGeneration(first)

        let staging = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(path: "/authorized/new.txt", name: "new", kind: .file)],
            generation: staging
        )
        let beforeAbort = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "")
        )
        XCTAssertEqual(beforeAbort.results.map(\.item.displayName), ["old"])

        try await context.service.abortRootGeneration(staging)
        let afterAbort = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "")
        )
        XCTAssertEqual(afterAbort.results.map(\.item.displayName), ["old"])
    }

    func testCommitAtomicallyReplacesOnlyTheTargetRootGeneration() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let firstRoot = URL(fileURLWithPath: "/first")
        let secondRoot = URL(fileURLWithPath: "/second")
        let first = try await context.service.beginRootGeneration(rootURL: firstRoot)
        try await context.service.upsert(
            items: [item(path: "/first/old.txt", name: "old", kind: .file)],
            generation: first
        )
        try await context.service.commitRootGeneration(first)
        let second = try await context.service.beginRootGeneration(rootURL: secondRoot)
        try await context.service.upsert(
            items: [item(path: "/second/stable.txt", name: "stable", kind: .file)],
            generation: second
        )
        try await context.service.commitRootGeneration(second)

        let replacement = try await context.service.beginRootGeneration(rootURL: firstRoot)
        try await context.service.upsert(
            items: [item(path: "/first/new.txt", name: "new", kind: .file)],
            generation: replacement
        )
        try await context.service.commitRootGeneration(replacement)

        let snapshot = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "")
        )
        XCTAssertEqual(Set(snapshot.results.map(\.item.displayName)), ["new", "stable"])
        XCTAssertFalse(snapshot.results.contains { $0.item.displayName == "old" })
    }

    func testSupersededStagingTokenCannotWriteOrReplaceCommittedIndex() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let committed = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(path: "/authorized/stable", name: "stable", kind: .folder)],
            generation: committed
        )
        try await context.service.commitRootGeneration(committed)

        let stale = try await context.service.beginRootGeneration(rootURL: root)
        let current = try await context.service.beginRootGeneration(rootURL: root)
        do {
            try await context.service.upsert(
                items: [item(path: "/authorized/stale", name: "stale", kind: .folder)],
                generation: stale
            )
            XCTFail("stale generation must fail")
        } catch FileSearchIndexStoreError.staleGeneration {
            // Expected.
        }
        try await context.service.abortRootGeneration(current)

        let snapshot = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "")
        )
        XCTAssertEqual(snapshot.results.map(\.item.displayName), ["stable"])
    }

    func testMoveAndDeleteMutateCommittedRowsWithoutFilesystemScan() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let source = URL(fileURLWithPath: "/authorized/Source", isDirectory: true)
        let destination = URL(
            fileURLWithPath: "/authorized/Destination/Source",
            isDirectory: true
        )
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(items: [
            item(path: source.path, name: "Source", kind: .folder),
            item(
                path: source.appendingPathComponent("child.txt").path,
                name: "child",
                kind: .file
            )
        ], generation: generation)
        try await context.service.commitRootGeneration(generation)

        try await context.service.replaceMovedItem(from: source, to: destination)
        let moved = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "child")
        )
        XCTAssertEqual(
            moved.results.map(\.item.url.path),
            [destination.appendingPathComponent("child.txt").path]
        )

        try await context.service.removeItem(at: destination)
        let deleted = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "child")
        )
        XCTAssertEqual(deleted.results, [])
    }

    func testCopyOnlyMarksDirtyAndRemainsInvisibleUntilBackgroundCommit() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(path: "/authorized/source.txt", name: "source", kind: .file)],
            generation: generation
        )
        try await context.service.commitRootGeneration(generation)
        let copied = URL(fileURLWithPath: "/authorized/copied.txt")

        try await context.service.indexItemTree(at: copied)

        let query = await context.service.currentSnapshot(
            for: FileSearchRequest(query: "copied")
        )
        XCTAssertEqual(query.results, [])
        let dirtyPaths = try await context.service.dirtyPaths()
        XCTAssertEqual(dirtyPaths, [copied])
    }

    func testIndexPersistsAcrossStoreInstancesAndUsesWAL() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(
            items: [item(path: "/authorized/persistent.txt", name: "persistent", kind: .file)],
            generation: generation
        )
        try await context.service.commitRootGeneration(generation)

        let reopened = FileSearchService(store: FileSearchIndexStore(
            databaseURL: context.databaseURL
        ))
        let snapshot = await reopened.currentSnapshot(
            for: FileSearchRequest(query: "persistent")
        )
        XCTAssertEqual(snapshot.results.first?.item.displayName, "persistent")
        XCTAssertEqual(try journalMode(at: context.databaseURL), "wal")
    }

    func testSQLiteWriterUsesFileTempStorageAndBoundedCache() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let configuration = try await store.writerStorageConfiguration()
        XCTAssertEqual(configuration.tempStore, 1, "SQLITE_TEMP_STORE_FILE")
        XCTAssertEqual(configuration.cacheSize, -16_384, "negative cache_size is KiB")
    }

    func testMetadataReflectsCommittedStatisticsNotStagingRows() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = URL(fileURLWithPath: "/authorized")
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await context.service.upsert(items: [
            item(path: "/authorized/App.app", name: "App", kind: .application),
            item(path: "/authorized/file", name: "file", kind: .file),
            item(path: "/authorized/folder", name: "folder", kind: .folder)
        ], generation: generation)
        try await context.service.commitRootGeneration(
            generation,
            statistics: FileSearchRootCommitStatistics(
                skippedGeneratedDirectories: 7,
                inaccessibleLocations: 3
            ),
            reachedLimit: true
        )

        let metadata = try await context.service.indexMetadata()
        XCTAssertEqual(metadata.phase, .limited)
        XCTAssertEqual(metadata.committedRootCount, 1)
        XCTAssertEqual(metadata.statistics.indexedApplications, 1)
        XCTAssertEqual(metadata.statistics.indexedFiles, 1)
        XCTAssertEqual(metadata.statistics.indexedFolders, 1)
        XCTAssertEqual(metadata.statistics.skippedGeneratedDirectories, 7)
        XCTAssertEqual(metadata.statistics.inaccessibleLocations, 3)
        XCTAssertNotNil(metadata.lastSuccessfulIndexAt)
    }

    func testActivityGateTracksEveryInteractiveIndexerBlocker() async {
        let gate = FileSearchActivityGate(requiredIdleDuration: 0)
        let blockers: [FileSearchActivityBlocker] = [
            .searchPanel, .capture, .ocr, .fileOperation
        ]

        for blocker in blockers {
            await gate.setActivity(true, blocker: blocker)
            let active = await gate.snapshot()
            XCTAssertTrue(active.blockers.contains(blocker))
            await gate.setActivity(false, blocker: blocker)
            let inactive = await gate.snapshot()
            XCTAssertFalse(inactive.blockers.contains(blocker))
        }
    }

    func testIndexerChecksInteractiveActivityEverySixteenVisits() {
        let policy = FileSearchActivityCheckpointPolicy.standard

        XCTAssertEqual(policy.entryInterval, 16)
        XCTAssertFalse(policy.shouldCheck(afterVisitedEntries: 1))
        XCTAssertFalse(policy.shouldCheck(afterVisitedEntries: 15))
        XCTAssertTrue(policy.shouldCheck(afterVisitedEntries: 16))
        XCTAssertFalse(policy.shouldCheck(afterVisitedEntries: 17))
        XCTAssertTrue(policy.shouldCheck(afterVisitedEntries: 32))

        let clamped = FileSearchActivityCheckpointPolicy(entryInterval: 1_000)
        XCTAssertEqual(clamped.entryInterval, 64)
    }

    func testSearchPanelMayBeIgnoredWithoutIgnoringCaptureOrSystemPressure() async {
        let gate = FileSearchActivityGate(requiredIdleDuration: 0)
        await gate.setActivity(true, blocker: .searchPanel)

        let normal = await gate.snapshot()
        let fast = await gate.snapshot(ignoring: [.userActive, .searchPanel])

        XCTAssertFalse(normal.canIndex)
        XCTAssertTrue(fast.canIndex)

        for blocker: FileSearchActivityBlocker in [
            .capture, .ocr, .fileOperation, .lowPower, .thermalPressure, .systemDeferral
        ] {
            await gate.setActivity(true, blocker: blocker)
            let protected = await gate.snapshot(ignoring: [.userActive, .searchPanel])
            XCTAssertFalse(protected.canIndex)
            XCTAssertTrue(protected.blockers.contains(blocker))
            await gate.setActivity(false, blocker: blocker)
        }
    }

    func testBackgroundFullRunCommitsWithSearchPanelOpenAndReleasesLease() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent("Authorized", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("indexed".utf8).write(
            to: root.appendingPathComponent("periodic-index.txt")
        )

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let releaseRecorder = FileSearchLeaseReleaseRecorder()
        let gate = FileSearchActivityGate(requiredIdleDuration: 0)
        await gate.setActivity(true, blocker: .searchPanel)
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(
                    roots: [FileSearchBackgroundRoot(url: root, scope: .files)],
                    release: { await releaseRecorder.recordRelease() }
                )
            },
            activityGate: gate,
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .full)
        guard case let .completed(mode, roots, items) = result else {
            return XCTFail("expected completed full run, got \(result)")
        }
        XCTAssertEqual(mode, .full)
        XCTAssertEqual(roots, 1)
        XCTAssertGreaterThanOrEqual(items, 2)
        let releaseCount = await releaseRecorder.releaseCount()
        XCTAssertEqual(releaseCount, 1)

        let service = FileSearchService(store: store)
        let snapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "periodic-index")
        )
        XCTAssertEqual(snapshot.results.first?.item.displayName, "periodic-index.txt")
        let metadata = try await service.indexMetadata()
        XCTAssertEqual(metadata.indexingRootCount, 0)
    }

    func testApplicationRootIndexesOnlyApplicationsAndSkipsOtherSystemFiles() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent("Applications", isDirectory: true)
        let app = root.appendingPathComponent("Demo.app", isDirectory: true)
        let utilityFolder = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: utilityFolder,
            withIntermediateDirectories: true
        )
        try Data("system-file".utf8).write(
            to: root.appendingPathComponent("README.txt")
        )
        try Data("nested".utf8).write(
            to: utilityFolder.appendingPathComponent("helper.conf")
        )

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(roots: [
                    FileSearchBackgroundRoot(url: root, scope: .applications)
                ])
            },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                initialUserIdleDuration: 0,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .full)
        guard case let .completed(_, roots, items) = result else {
            return XCTFail("expected completed application pass, got \(result)")
        }
        XCTAssertEqual(roots, 1)
        XCTAssertEqual(items, 1)

        let service = FileSearchService(store: store)
        let all = await service.currentSnapshot(for: FileSearchRequest(query: ""))
        XCTAssertEqual(all.results.map(\.item.kind), [.application])
        XCTAssertEqual(all.results.map(\.item.url.path), [app.path])
        let systemFile = await service.currentSnapshot(
            for: FileSearchRequest(query: "README")
        )
        XCTAssertTrue(systemFile.results.isEmpty)
    }

    func testInitialIndexConfigurationStartsQuicklyAndPeriodicBudgetRemainsBelowOnePercent() {
        let coordinator = FileSearchIndexCoordinatorConfiguration.standard
        let indexer = FileSearchBackgroundIndexerConfiguration.standard

        XCTAssertEqual(coordinator.firstRunDelay, 3)
        XCTAssertEqual(indexer.initialUserIdleDuration, 0)
        XCTAssertEqual(indexer.userIdleDuration, 0)
        XCTAssertLessThan(indexer.targetCPUFraction, 0.01)
        XCTAssertEqual(indexer.initialTargetCPUFraction, 0.20)
        XCTAssertEqual(indexer.initialMicroBatchSize, 128)
        XCTAssertGreaterThan(indexer.initialMicroBatchSize, indexer.microBatchSize)
        XCTAssertGreaterThan(
            indexer.initialMaximumEntriesPerSecond,
            indexer.incrementalMaximumEntriesPerSecond
        )
    }

    func testIncrementalIndexContinuesWhileUserIsActiveAndSearchPanelIsOpen() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent(
            "AlwaysBackground",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let previous = try await store.beginRootGeneration(rootURL: root)
        try await store.commitRootGeneration(previous, statistics: .init())
        try Data("background".utf8).write(
            to: root.appendingPathComponent("continues-while-active.txt")
        )
        try await store.markDirty(root.appendingPathComponent("continues-while-active.txt"))

        let gate = FileSearchActivityGate(requiredIdleDuration: 3_600)
        await gate.setActivity(true, blocker: .userActive)
        await gate.setActivity(true, blocker: .searchPanel)
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(roots: [
                    FileSearchBackgroundRoot(url: root, scope: .files)
                ])
            },
            activityGate: gate,
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                incrementalMaximumEntriesPerSecond: 500,
                userIdleDuration: 3_600,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .incremental)
        guard case let .completed(mode, roots, items) = result else {
            return XCTFail("expected active-user indexing to complete, got \(result)")
        }
        XCTAssertEqual(mode, .incremental)
        XCTAssertEqual(roots, 1)
        XCTAssertEqual(items, 1)

        let snapshot = await FileSearchService(store: store).currentSnapshot(
            for: FileSearchRequest(query: "continues-while-active")
        )
        XCTAssertEqual(
            snapshot.results.first?.item.displayName,
            "continues-while-active.txt"
        )
    }

    func testManualCoordinatorRunForcesCompleteFastIndex() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent(
            "ManualAuthorized",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("manual".utf8).write(
            to: root.appendingPathComponent("manual-index.txt")
        )

        let suiteName = "PEEK-ManualIndex-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = FileSearchIndexModeRecorder()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let activityGate = FileSearchActivityGate(requiredIdleDuration: 0)
        let coordinator = FileSearchIndexCoordinator(
            sink: store,
            rootProvider: { mode in
                await recorder.record(mode)
                return FileSearchBackgroundRootLease(roots: [
                    FileSearchBackgroundRoot(url: root, scope: .files)
                ])
            },
            activityGate: activityGate,
            indexerConfiguration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                initialMicroBatchSize: 64,
                initialTargetCPUFraction: 0.25,
                incrementalMaximumEntriesPerSecond: 500,
                initialMaximumEntriesPerSecond: 10_000,
                initialUserIdleDuration: 0,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            ),
            userDefaults: defaults
        )

        let result = await coordinator.rebuildNow()
        guard case let .completed(mode, roots, items) = result else {
            return XCTFail("expected completed manual index, got \(result)")
        }
        XCTAssertEqual(mode, .full)
        XCTAssertEqual(roots, 1)
        XCTAssertEqual(items, 2)
        let recordedModes = await recorder.recordedModes()
        XCTAssertEqual(recordedModes, [.full])

        let snapshot = await FileSearchService(store: store).currentSnapshot(
            for: FileSearchRequest(query: "manual-index")
        )
        XCTAssertEqual(snapshot.results.first?.item.displayName, "manual-index.txt")
    }

    func testManualRootRefreshIndexesOnlyRequestedConfiguredRoot() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let first = context.directory.appendingPathComponent("First", isDirectory: true)
        let second = context.directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: first.appendingPathComponent("first-only.txt"))
        try Data("two".utf8).write(to: second.appendingPathComponent("second-only.txt"))

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let coordinator = FileSearchIndexCoordinator(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(roots: [
                    FileSearchBackgroundRoot(url: first, scope: .files),
                    FileSearchBackgroundRoot(url: second, scope: .files)
                ])
            },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            indexerConfiguration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                initialTargetCPUFraction: 0.05,
                initialMaximumEntriesPerSecond: 10_000,
                initialUserIdleDuration: 0,
                userIdleDuration: 0,
                maximumActivityPause: 1
            )
        )

        let result = await coordinator.rebuildRootNow(path: first.path)
        guard case let .completed(mode, roots, _) = result else {
            return XCTFail("expected one completed root, got \(result)")
        }
        XCTAssertEqual(mode, .incremental)
        XCTAssertEqual(roots, 1)
        let service = FileSearchService(store: store)
        let firstSnapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "first-only")
        )
        let secondSnapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "second-only")
        )
        XCTAssertEqual(firstSnapshot.results.first?.item.displayName, "first-only.txt")
        XCTAssertTrue(secondSnapshot.results.isEmpty)
    }

    func testMissingCountRootDoesNotBlockApplicationsOrReplaceOldGeneration() async throws {
        let context = makeContext()
        let apps = context.directory.appendingPathComponent("Applications", isDirectory: true)
        let app = apps.appendingPathComponent("Demo.app", isDirectory: true)
        let missing = context.directory.appendingPathComponent("Missing", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let old = try await store.beginRootGeneration(rootURL: missing)
        try await store.upsert([
            item(path: missing.appendingPathComponent("old-result.txt").path,
                 name: "old-result.txt", kind: .file)
        ], in: old)
        try await store.commitRootGeneration(old, statistics: .init())
        let tracker = FileSearchInitialIndexProgressTracker()
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [
                FileSearchBackgroundRoot(url: apps, scope: .applications),
                FileSearchBackgroundRoot(url: missing, scope: .files)
            ]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration,
            initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full, resourceProfile: .fast)
        guard case let .failed(message) = result else {
            return XCTFail("expected root failure, got \(result)")
        }
        XCTAssertTrue(message.contains(missing.path))
        let service = FileSearchService(store: store)
        let appsSnapshot = await service.currentSnapshot(for: .init(query: "Demo"))
        let oldSnapshot = await service.currentSnapshot(for: .init(query: "old-result"))
        XCTAssertEqual(appsSnapshot.results.first?.item.url.path, app.path)
        XCTAssertEqual(oldSnapshot.results.count, 1)
        let metadata = try await service.indexMetadata()
        XCTAssertEqual(metadata.committedRootCount, 2)
        XCTAssertEqual(metadata.indexingRootCount, 0)
        let dirty = try await store.dirtyPaths(limit: 10)
        XCTAssertTrue(dirty.contains { $0.path == missing.path })
        let progress = await tracker.snapshot()
        XCTAssertEqual(progress?.phase, .failed)
        XCTAssertEqual(progress?.failureMessage, message)
    }

    func testUnreadableChildStillCommitsReadableSiblingsAndHidesProgress() async throws {
        let context = makeContext()
        let denied = context.directory.appendingPathComponent("A-Denied", isDirectory: true)
        let child = denied.appendingPathComponent("Restricted", isDirectory: true)
        let healthy = context.directory.appendingPathComponent("Z-Healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try Data().write(to: healthy.appendingPathComponent("healthy.txt"))
        try Data().write(to: denied.appendingPathComponent("sibling.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: child.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        }
        guard !FileManager.default.isReadableFile(atPath: child.path) else {
            throw XCTSkip("test runner can read permission-restricted directories")
        }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let tracker = FileSearchInitialIndexProgressTracker()
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [
                FileSearchBackgroundRoot(url: denied, scope: .files),
                FileSearchBackgroundRoot(url: healthy, scope: .files)
            ]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration,
            initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full)
        guard case let .completed(_, roots, _) = result else {
            return XCTFail("expected completed pass with a restricted descendant, got \(result)")
        }
        XCTAssertEqual(roots, 2)
        let service = FileSearchService(store: store)
        let snapshot = await service.currentSnapshot(for: .init(query: "healthy.txt"))
        XCTAssertEqual(snapshot.results.count, 1)
        let sibling = await service.currentSnapshot(for: .init(query: "sibling.txt"))
        XCTAssertEqual(sibling.results.count, 1)
        let statuses = try await store.rootStatuses()
        XCTAssertEqual(statuses.first { $0.rootPath == denied.path }?.inaccessibleLocationCount, 1)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.committedRootCount, 2)
        XCTAssertEqual(metadata.indexingRootCount, 0)
        let progress = await tracker.snapshot()
        XCTAssertNil(progress)
    }

    func testTraversalOnlyRecoversFromDescendantPermissionAndRemovalErrors() {
        let root = URL(fileURLWithPath: "/TestRoot")
        let child = root.appendingPathComponent("Restricted")
        for error in [
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        ] {
            let issues = FileSearchTraversalIssues()
            XCTAssertTrue(issues.continueAfter(error, at: child, root: root))
            XCTAssertEqual(issues.distinctInaccessiblePaths, [child.path])
            XCTAssertNil(issues.fatalError)
            XCTAssertFalse(FileSearchTraversalIssues().continueAfter(error, at: root, root: root))
            XCTAssertFalse(FileSearchTraversalIssues().continueAfter(
                error, at: URL(fileURLWithPath: "/TestRootSibling"), root: root
            ))
        }
        let vanished = FileSearchTraversalIssues()
        XCTAssertTrue(vanished.continueAfter(CocoaError(.fileReadNoSuchFile), at: child, root: root))
        XCTAssertTrue(vanished.inaccessiblePaths.isEmpty)
        let ioFailure = FileSearchTraversalIssues()
        XCTAssertFalse(ioFailure.continueAfter(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)), at: child, root: root))
        XCTAssertNotNil(ioFailure.fatalError)
        let nested = FileSearchTraversalIssues()
        for url in [child.appendingPathComponent("Nested"), child, root.appendingPathComponent("Restricted-Sibling")] {
            XCTAssertTrue(nested.continueAfter(CocoaError(.fileReadNoPermission), at: url, root: root))
        }
        XCTAssertEqual(nested.distinctInaccessiblePaths, [child.path, root.appendingPathComponent("Restricted-Sibling").path])
    }

    func testPreservedEntryBatchesRespectBoundariesExclusionsAndNewerMetadata() async throws {
        let context = makeContext()
        let root = context.directory.appendingPathComponent("Root")
        let restricted = root.appendingPathComponent("Restricted_%_中")
        let excluded = restricted.appendingPathComponent("Excluded")
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let old = try await store.beginRootGeneration(rootURL: root)
        let files = (0..<5).map { number in
            item(path: restricted.appendingPathComponent("file-\(number).txt").path,
                 name: "old-\(number).txt", kind: .file)
        }
        try await store.upsert(files + [
            item(path: excluded.appendingPathComponent("secret.txt").path, name: "excluded.txt", kind: .file),
            item(path: root.appendingPathComponent("Restricted_%_中-sibling/other.txt").path, name: "other.txt", kind: .file)
        ], in: old)
        try await store.commitRootGeneration(old)
        let replacement = try await store.beginRootGeneration(rootURL: root)
        try await store.upsert([
            item(path: files[0].url.path, name: "newer-name.txt", kind: .file)
        ], in: replacement)
        let probe = try await store.preserveCommittedEntries(
            under: restricted.path, excluding: [excluded.path], in: replacement, afterPath: nil, limit: 0
        )
        XCTAssertTrue(probe.entries.isEmpty)
        XCTAssertTrue(probe.hasMore)
        let meter = FileSearchCPUWorkMeter()
        var copied: [FileSearchPreservedEntry] = []
        var cursor: String?
        repeat {
            let batch = try await FileSearchCPUWork.$meter.withValue(meter) {
                try await store.preserveCommittedEntries(
                    under: restricted.path, excluding: [excluded.path], in: replacement,
                    afterPath: cursor, limit: 2
                )
            }
            XCTAssertLessThanOrEqual(batch.entries.count, 2)
            copied += batch.entries
            cursor = batch.entries.last?.path
            if !batch.hasMore { break }
        } while copied.count < 10
        XCTAssertEqual(copied.count, 4)
        XCTAssertGreaterThan(meter.totalCPUTime, 0)
        try await store.commitRootGeneration(replacement)
        let service = FileSearchService(store: store)
        let fresh = await service.currentSnapshot(for: .init(query: "newer-name"))
        XCTAssertEqual(fresh.results.first?.item.url.path, files[0].url.path)
        let gone = await service.currentSnapshot(for: .init(query: "excluded"))
        XCTAssertTrue(gone.results.isEmpty)
        let other = await service.currentSnapshot(for: .init(query: "other.txt"))
        XCTAssertTrue(other.results.isEmpty)
        let count = try await store.committedItemCount()
        XCTAssertEqual(count, 5)
        do {
            _ = try await store.preserveCommittedEntries(
                under: restricted.path, excluding: [], in: old, afterPath: nil, limit: 2
            )
            XCTFail("stale generation must not receive preserved rows")
        } catch FileSearchIndexStoreError.staleGeneration {}
    }

    func testPermissionLostAfterCountingPreservesOnlyRestrictedEntriesAndRecovers() async throws {
        let context = makeContext()
        let root = context.directory.appendingPathComponent("Root", isDirectory: true)
        let restricted = root.appendingPathComponent("Restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("readable-new.txt"))
        try Data().write(to: restricted.appendingPathComponent("newly-readable.txt"))
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let old = try await store.beginRootGeneration(rootURL: root)
        try await store.upsert([
            item(path: restricted.appendingPathComponent("old-protected.txt").path, name: "old-protected.txt", kind: .file),
            item(path: root.appendingPathComponent("deleted-elsewhere.txt").path, name: "deleted-elsewhere.txt", kind: .file)
        ], in: old)
        try await store.commitRootGeneration(old)
        let tracker = FileSearchInitialIndexProgressTracker()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        guard !FileManager.default.isReadableFile(atPath: restricted.path) else {
            throw XCTSkip("test runner can read permission-restricted directories")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        let sink = ObservingBackgroundIndexSink(store: store, beforeBegin: { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        })
        let roots: FileSearchBackgroundRootProvider = { _ in
            FileSearchBackgroundRootLease(roots: [.init(url: root, scope: .files)])
        }
        let indexer = FileSearchBackgroundIndexer(
            sink: sink, rootProvider: roots, activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration, initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full)
        guard case .completed = result else { return XCTFail("expected partial-access completion, got \(result)") }
        let service = FileSearchService(store: store)
        let preserved = await service.currentSnapshot(for: .init(query: "old-protected"))
        let removed = await service.currentSnapshot(for: .init(query: "deleted-elsewhere"))
        let readable = await service.currentSnapshot(for: .init(query: "readable-new"))
        XCTAssertEqual(preserved.results.count, 1)
        XCTAssertTrue(removed.results.isEmpty)
        XCTAssertEqual(readable.results.count, 1)
        let completedProgress = await tracker.snapshot()
        XCTAssertNil(completedProgress)
        let statuses = try await store.rootStatuses()
        XCTAssertEqual(statuses.first?.inaccessibleLocationCount, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        let recovery = FileSearchBackgroundIndexer(
            sink: store, rootProvider: roots, activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration
        )
        let recovered = await recovery.run(mode: .full)
        guard case .completed = recovered else { return XCTFail("expected recovery, got \(recovered)") }
        let stale = await service.currentSnapshot(for: .init(query: "old-protected"))
        let current = await service.currentSnapshot(for: .init(query: "newly-readable"))
        XCTAssertTrue(stale.results.isEmpty)
        XCTAssertEqual(current.results.count, 1)
        let recoveredStatus = try await store.rootStatuses()
        XCTAssertEqual(recoveredStatus.first?.inaccessibleLocationCount, 0)
    }

    func testPermissionRestoredBetweenCountingAndIndexingLeavesNoStaleWarning() async throws {
        let context = makeContext()
        let root = context.directory.appendingPathComponent("Root", isDirectory: true)
        let restricted = root.appendingPathComponent("Restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try Data().write(to: restricted.appendingPathComponent("recovered.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        guard !FileManager.default.isReadableFile(atPath: restricted.path) else {
            throw XCTSkip("test runner can read permission-restricted directories")
        }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let tracker = FileSearchInitialIndexProgressTracker()
        let sink = ObservingBackgroundIndexSink(store: store, beforeBegin: { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        }, afterUpsert: { _ in
            let progress = await tracker.snapshot()
            XCTAssertEqual(progress?.discoveredItems, 3)
        })
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [.init(url: root, scope: .files)]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration, initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full)
        XCTAssertEqual(result, .completed(mode: .full, roots: 1, items: 3))
        let statuses = try await store.rootStatuses()
        XCTAssertEqual(statuses.first?.inaccessibleLocationCount, 0)
        let progress = await tracker.snapshot()
        XCTAssertNil(progress)
    }

    func testRestrictedDescendantCompletionPersistsAndNextLaunchUsesIncrementalIndex() async throws {
        let context = makeContext()
        let root = context.directory.appendingPathComponent("A-Root", isDirectory: true)
        let restricted = root.appendingPathComponent("Restricted", isDirectory: true)
        let healthy = context.directory.appendingPathComponent("Z-Healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("readable.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        guard !FileManager.default.isReadableFile(atPath: restricted.path) else {
            throw XCTSkip("test runner can read permission-restricted directories")
        }
        let suite = "PEEK-PermissionCompletion-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let modes = FileSearchIndexModeRecorder()
        let provider: FileSearchBackgroundRootProvider = { mode in
            await modes.record(mode)
            return FileSearchBackgroundRootLease(roots: [
                .init(url: root, scope: .files), .init(url: healthy, scope: .files)
            ])
        }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let first = FileSearchIndexCoordinator(
            sink: store, rootProvider: provider, activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            indexerConfiguration: indexingTestConfiguration,
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite))
        )
        let firstRun = await first.runNow()
        guard case let .completed(.full, roots, _) = firstRun else {
            return XCTFail("restricted child must not fail the full pass: \(firstRun)")
        }
        XCTAssertEqual(roots, 2)
        XCTAssertGreaterThan(UserDefaults(suiteName: suite)?.double(forKey: "fileSearch.lastCompletedFullIndex.v1") ?? 0, 0)
        await store.close()
        let reopened = FileSearchIndexStore(databaseURL: context.databaseURL)
        let persisted = try await reopened.rootStatuses()
        XCTAssertEqual(persisted.first { $0.rootPath == root.path }?.inaccessibleLocationCount, 1)
        let second = FileSearchIndexCoordinator(
            sink: reopened, rootProvider: provider, activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            indexerConfiguration: indexingTestConfiguration,
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suite))
        )
        let nextRun = await second.runNow()
        XCTAssertEqual(nextRun, .noChanges, "No filesystem events: keep the committed index without another scan")
        let recorded = await modes.recordedModes()
        XCTAssertEqual(recorded, [.full, .incremental])
    }

    func testPreservationCapacityFailureKeepsOldCommittedGenerationIntact() async throws {
        let context = makeContext()
        let root = context.directory.appendingPathComponent("Root", isDirectory: true)
        let restricted = root.appendingPathComponent("Restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        for index in 0..<10 {
            try Data().write(to: root.appendingPathComponent("new-\(index).txt"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        guard !FileManager.default.isReadableFile(atPath: restricted.path) else {
            throw XCTSkip("test runner can read permission-restricted directories")
        }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let old = try await store.beginRootGeneration(rootURL: root)
        try await store.upsert((0..<995).map { index in
            item(path: restricted.appendingPathComponent("old-\(index).txt").path,
                 name: "old-\(index).txt", kind: .file)
        }, in: old)
        try await store.commitRootGeneration(old)
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [.init(url: root, scope: .files)]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration
        )
        let result = await indexer.run(mode: .full)
        guard case .failed = result else { return XCTFail("must abort instead of losing protected rows: \(result)") }
        let statuses = try await store.rootStatuses()
        XCTAssertEqual(statuses.first?.indexedItemCount, 995)
        XCTAssertEqual(statuses.first?.isIndexing, false)
        let snapshot = await FileSearchService(store: store).currentSnapshot(for: .init(query: "old-994"))
        XCTAssertEqual(snapshot.results.count, 1)
    }

    func testFailedScanAbortsOnlyItsRootAndContinuesLaterRoots() async throws {
        let context = makeContext()
        let failing = context.directory.appendingPathComponent("A-Failing", isDirectory: true)
        let healthy = context.directory.appendingPathComponent("Z-Healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: failing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try Data().write(to: failing.appendingPathComponent("staged.txt"))
        try Data().write(to: healthy.appendingPathComponent("healthy.txt"))
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let old = try await store.beginRootGeneration(rootURL: failing)
        try await store.upsert([
            item(path: failing.appendingPathComponent("old.txt").path, name: "old.txt", kind: .file)
        ], in: old)
        try await store.commitRootGeneration(old, statistics: .init())
        let tracker = FileSearchInitialIndexProgressTracker()
        let sink = ObservingBackgroundIndexSink(store: store, afterUpsert: { token in
            if token.rootPath == failing.path { throw CocoaError(.fileReadNoPermission) }
        })
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [
                FileSearchBackgroundRoot(url: failing, scope: .files),
                FileSearchBackgroundRoot(url: healthy, scope: .files)
            ]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration,
            initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full, resourceProfile: .fast)
        guard case .failed = result else { return XCTFail("expected failure, got \(result)") }
        let service = FileSearchService(store: store)
        let oldResult = await service.currentSnapshot(for: .init(query: "old.txt"))
        let stagedResult = await service.currentSnapshot(for: .init(query: "staged.txt"))
        let healthyResult = await service.currentSnapshot(for: .init(query: "healthy.txt"))
        XCTAssertEqual(oldResult.results.count, 1)
        XCTAssertTrue(stagedResult.results.isEmpty)
        XCTAssertEqual(healthyResult.results.count, 1)
        let metadata = try await service.indexMetadata()
        XCTAssertEqual(metadata.indexingRootCount, 0)
        let dirty = try await store.dirtyPaths(limit: 10)
        XCTAssertTrue(dirty.contains { $0.path == failing.path })
    }

    func testInventoryDetectsAddedAndRemovedFilesBeforeGlobalTotalIsReached() async throws {
        let context = makeContext()
        let first = context.directory.appendingPathComponent("A-First", isDirectory: true)
        let second = context.directory.appendingPathComponent("B-Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let removed = first.appendingPathComponent("removed.txt")
        try Data().write(to: removed)
        for number in 0 ..< 9 {
            try Data().write(to: second.appendingPathComponent("item-\(number).txt"))
        }
        let tracker = FileSearchInitialIndexProgressTracker()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let sink = ObservingBackgroundIndexSink(store: store, beforeBegin: { root in
            if root == first {
                try Data().write(to: first.appendingPathComponent("added.txt"))
                try FileManager.default.removeItem(at: removed)
                let progress = await tracker.snapshot()
                XCTAssertEqual(progress?.discoveredItems, 12)
            } else if root == second {
                let progress = await tracker.snapshot()
                XCTAssertEqual(progress?.discoveredItems, 12, "removed entry must be reconciled after first commit")
                XCTAssertEqual(progress?.indexedItems, 2)
            }
        }, afterUpsert: { token in
            if token.rootPath == first.path {
                let progress = await tracker.snapshot()
                XCTAssertEqual(progress?.discoveredItems, 13, "addition must be visible even before exceeding global pre-count")
            }
        })
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [
                FileSearchBackgroundRoot(url: first, scope: .files),
                FileSearchBackgroundRoot(url: second, scope: .files)
            ]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: indexingTestConfiguration,
            initialIndexProgress: tracker
        )
        let result = await indexer.run(mode: .full)
        XCTAssertEqual(result, .completed(mode: .full, roots: 2, items: 12))
        let finished = await tracker.snapshot()
        XCTAssertNil(finished)
        let added = await FileSearchService(store: store).currentSnapshot(for: .init(query: "added.txt"))
        XCTAssertEqual(added.results.count, 1)
    }

    func testSearchPanelOpenStillDefersIndexForCapture() async throws {
        let context = makeContext()
        let gate = FileSearchActivityGate(requiredIdleDuration: 0)
        await gate.setActivity(true, blocker: .searchPanel)
        await gate.setActivity(true, blocker: .capture)
        let indexer = FileSearchBackgroundIndexer(
            sink: FileSearchIndexStore(databaseURL: context.databaseURL),
            rootProvider: { _ in
                XCTFail("must not acquire roots while capture is active")
                return FileSearchBackgroundRootLease(roots: [])
            },
            activityGate: gate,
            configuration: indexingTestConfiguration,
            initialIndexProgress: FileSearchInitialIndexProgressTracker()
        )
        let result = await indexer.run(mode: .full, resourceProfile: .fast)
        XCTAssertEqual(result, .deferred)
    }

    private var indexingTestConfiguration: FileSearchBackgroundIndexerConfiguration {
        FileSearchBackgroundIndexerConfiguration(
            maximumIndexedItems: 1_000,
            initialMaximumEntriesPerSecond: 10_000,
            userIdleDuration: 0,
            maximumActivityPause: 1
        )
    }

    func testBackgroundCancellationAbortsStagingAndNeverCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-BackgroundCancel-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("cancel".utf8).write(to: root.appendingPathComponent("cancel.txt"))

        let sink = CancellingBackgroundIndexSink()
        let releaseRecorder = FileSearchLeaseReleaseRecorder()
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(
                    roots: [FileSearchBackgroundRoot(url: root, scope: .files)],
                    release: { await releaseRecorder.recordRelease() }
                )
            },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .full)
        XCTAssertEqual(result, .deferred)
        let counts = await sink.counts()
        XCTAssertEqual(counts.begin, 1)
        XCTAssertEqual(counts.abort, 1)
        XCTAssertEqual(counts.commit, 0)
        let releaseCount = await releaseRecorder.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testCPUBudgetPolicyClampsBelowOnePercentAndUsesMicroBatches() async {
        let configuration = FileSearchBackgroundIndexerConfiguration(
            maximumIndexedItems: 1,
            microBatchSize: 100,
            targetCPUFraction: 1,
            userIdleDuration: 0,
            maximumActivityPause: 1,
            dirtyPathLimit: 1
        )
        XCTAssertEqual(configuration.targetCPUFraction, 0.009, accuracy: 0.000_001)
        XCTAssertEqual(configuration.microBatchSize, 32)

        let budget = FileSearchCPUBudget(
            targetFraction: 1,
            microBatchSize: 1,
            windowDuration: 10
        )
        let snapshot = await budget.snapshot()
        let batchSize = await budget.microBatchSize
        XCTAssertEqual(snapshot.targetFraction, 0.009, accuracy: 0.000_001)
        XCTAssertEqual(batchSize, 16)

        let fastBudget = FileSearchCPUBudget(
            targetFraction: 1,
            microBatchSize: 1_000,
            maximumTargetFraction: 0.25,
            maximumMicroBatchSize: 512
        )
        let fastSnapshot = await fastBudget.snapshot()
        let fastBatchSize = await fastBudget.microBatchSize
        XCTAssertEqual(fastSnapshot.targetFraction, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(fastBatchSize, 512)
    }

    func testCPUBudgetNeverCarriesDebtPastCurrentAccountingWindow() {
        XCTAssertEqual(
            FileSearchCPUBudget.requiredThrottleDelay(
                elapsedWall: 1,
                elapsedCPU: 2.48,
                targetFraction: 0.006,
                windowDuration: 60
            ),
            59,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            FileSearchCPUBudget.requiredThrottleDelay(
                elapsedWall: 10,
                elapsedCPU: 0.1,
                targetFraction: 0.05,
                windowDuration: 60
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testUnrelatedCPUWorkDoesNotCreateIndexingThrottleDebt() async throws {
        let meter = FileSearchCPUWorkMeter()
        let budget = FileSearchCPUBudget(workMeter: meter)
        await budget.reset()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.03
        while ProcessInfo.processInfo.systemUptime < deadline {}
        let start = ProcessInfo.processInfo.systemUptime
        try await budget.throttleAfterBatch()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        let snapshot = await budget.snapshot()
        XCTAssertEqual(meter.totalCPUTime, 0)
        XCTAssertEqual(snapshot.measuredFraction, 0)
    }

    func testCPUWorkMeterRecordsOnlySynchronousMeasuredWorkIncludingThrows() {
        let meter = FileSearchCPUWorkMeter()
        enum FixtureError: Error { case expected }
        XCTAssertThrowsError(try meter.measure {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.01
            while ProcessInfo.processInfo.systemUptime < deadline {}
            throw FixtureError.expected
        })
        let measured = meter.totalCPUTime
        XCTAssertGreaterThan(measured, 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.01
        while ProcessInfo.processInfo.systemUptime < deadline {}
        XCTAssertEqual(meter.totalCPUTime, measured)
    }

    func testIndexingTaskLocalMeterFollowsSQLiteActorWithoutChargingOtherWrites() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let meter = FileSearchCPUWorkMeter()
        let root = context.directory.appendingPathComponent("Metered")
        let fixture = item(path: root.appendingPathComponent("文稿.txt").path, name: "文稿.txt", kind: .file)
        try await FileSearchCPUWork.$meter.withValue(meter) {
            let generation = try await store.beginRootGeneration(rootURL: root)
            try await store.upsert([fixture], in: generation)
            try await store.commitRootGeneration(generation)
        }
        let measured = meter.totalCPUTime
        XCTAssertGreaterThan(measured, 0)
        try await store.markDirty(root)
        XCTAssertEqual(meter.totalCPUTime, measured)
        XCTAssertNil(FileSearchCPUWork.meter)
    }

    func testIncompleteRootIsDetectedEvenAfterAnotherRootCommits() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let first = context.directory.appendingPathComponent("First")
        let pending = context.directory.appendingPathComponent("Pending")
        let token = try await store.beginRootGeneration(rootURL: first)
        try await store.commitRootGeneration(token)
        let complete = try await store.hasUnindexedRoots([first])
        let incomplete = try await store.hasUnindexedRoots([first, pending])
        XCTAssertFalse(complete)
        XCTAssertTrue(incomplete)
        let staging = try await store.beginRootGeneration(rootURL: pending)
        let stillIncomplete = try await store.hasUnindexedRoots([pending])
        XCTAssertTrue(stillIncomplete)
        try await store.commitRootGeneration(staging)
        let finished = try await store.hasUnindexedRoots([first, pending])
        XCTAssertFalse(finished)
    }

    func testGenerationCleanupContributesToIndexingCPUWork() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let root = context.directory.appendingPathComponent("Cleanup")
        let fixture = item(path: root.appendingPathComponent("old.txt").path, name: "old.txt", kind: .file)
        let old = try await store.beginRootGeneration(rootURL: root)
        try await store.upsert([fixture], in: old)
        try await store.commitRootGeneration(old)
        let current = try await store.beginRootGeneration(rootURL: root)
        try await store.commitRootGeneration(current)
        let obsoleteMeter = FileSearchCPUWorkMeter()
        let deleted = try await FileSearchCPUWork.$meter.withValue(obsoleteMeter) {
            try await store.purgeObsoleteEntries(for: current, limit: 256)
        }
        XCTAssertEqual(deleted, 1)
        XCTAssertGreaterThan(obsoleteMeter.totalCPUTime, 0)

        let abandoned = try await store.beginRootGeneration(rootURL: root)
        try await store.upsert([fixture], in: abandoned)
        try await store.abortRootGeneration(abandoned)
        let orphanMeter = FileSearchCPUWorkMeter()
        let orphaned = try await FileSearchCPUWork.$meter.withValue(orphanMeter) {
            try await store.purgeOrphanedEntries(limit: 256)
        }
        XCTAssertEqual(orphaned, 1)
        XCTAssertGreaterThan(orphanMeter.totalCPUTime, 0)
    }

    func testIncrementalPassUsesFastBatchesForUnfinishedRoot() async throws {
        let context = makeContext()
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let complete = context.directory.appendingPathComponent("Complete")
        let pending = context.directory.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        for number in 0..<64 {
            try Data().write(to: pending.appendingPathComponent("item-\(number).txt"))
        }
        let committed = try await store.beginRootGeneration(rootURL: complete)
        try await store.commitRootGeneration(committed)
        let sink = ObservingBackgroundIndexSink(store: store)
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: [.init(url: pending, scope: .files)]) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: .standard,
            initialIndexProgress: FileSearchInitialIndexProgressTracker()
        )
        let result = await indexer.run(mode: .incremental)
        XCTAssertEqual(result, .completed(mode: .incremental, roots: 1, items: 65))
        let sizes = await sink.upsertBatchSizes()
        XCTAssertGreaterThan(sizes.max() ?? 0, 32)
    }

    func testDirtyRootRecoveryUsesBoundedFastProfileForCommittedIndex() async throws {
        let context = makeContext()
        let root = context.directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for number in 0..<64 { try Data().write(to: root.appendingPathComponent("fixture-\(number).txt")) }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let token = try await store.beginRootGeneration(rootURL: root)
        try await store.commitRootGeneration(token)
        try await store.markDirty(root)
        let sink = ObservingBackgroundIndexSink(store: store)
        let indexer = FileSearchBackgroundIndexer(sink: sink, rootProvider: { _ in
            .init(roots: [.init(url: root, scope: .files)])
        }, activityGate: .init(requiredIdleDuration: 0))
        let result = await indexer.run(mode: .incremental)
        XCTAssertEqual(result, .completed(mode: .incremental, roots: 1, items: 65))
        let batches = await sink.upsertBatchSizes()
        XCTAssertGreaterThan(batches.max() ?? 0, FileSearchBackgroundIndexerConfiguration.standard.microBatchSize)
        await store.close()
    }

    func testCPUWorkMeterDoesNotChargeThreadSleepAsCPU() {
        let meter = FileSearchCPUWorkMeter()
        meter.measure { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertLessThan(meter.totalCPUTime, 0.015)
    }

    func testProgressPresentationIgnoresSubsecondETAChangesButNotCounts() {
        func snapshot(_ remaining: TimeInterval, count: Int = 40) -> FileSearchInitialIndexProgressSnapshot {
            .init(phase: .indexingFiles, completedRoots: 1, totalRoots: 3,
                  indexedApplications: 0, estimatedRemaining: remaining,
                  discoveredItems: 100, indexedItems: count)
        }
        XCTAssertTrue(snapshot(28.9).hasSamePresentation(as: snapshot(28.1)))
        XCTAssertFalse(snapshot(28.9).hasSamePresentation(as: snapshot(27.9)))
        XCTAssertFalse(snapshot(28.9).hasSamePresentation(as: snapshot(28.9, count: 41)))
    }

    func testCommitPreservesDirtyWriteRecordedAfterGenerationBegan() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent("Authorized", isDirectory: true)
        let dirtyFile = root.appendingPathComponent("arrived-during-scan.txt")
        let generation = try await context.service.beginRootGeneration(rootURL: root)
        try await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
        try await context.service.markDirty(dirtyFile)
        try await context.service.commitRootGeneration(generation)

        let dirtyPaths = try await context.service.dirtyPaths()
        XCTAssertEqual(dirtyPaths, [dirtyFile])
    }

    func testRootReconciliationQueuesNewRootAndImmediatelyHidesRemovedRoot() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let service = FileSearchService(store: store)
        let oldRoot = URL(fileURLWithPath: "/old-authorized", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/new-authorized", isDirectory: true)
        let generation = try await service.beginRootGeneration(rootURL: oldRoot)
        try await service.upsert(
            items: [item(
                path: "/old-authorized/visible.txt",
                name: "visible",
                kind: .file
            )],
            generation: generation
        )
        try await service.commitRootGeneration(generation)

        try await store.reconcileRoots(retaining: [oldRoot, newRoot])
        let dirtyPathsAfterAddingRoot = try await store.dirtyPaths()
        XCTAssertTrue(dirtyPathsAfterAddingRoot.map(\.standardizedFileURL.path).contains(
            newRoot.standardizedFileURL.path
        ))
        try await store.reconcileRoots(retaining: [newRoot])

        let snapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "visible")
        )
        XCTAssertTrue(snapshot.results.isEmpty)
        let remainingDirtyPaths = try await store.dirtyPaths()
        XCTAssertEqual(
            remainingDirtyPaths.map(\.standardizedFileURL.path),
            [newRoot.standardizedFileURL.path]
        )
    }

    func testIncrementalRunRefreshesOneCleanRootWithoutDirtyMarker() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let root = context.directory.appendingPathComponent(
            "CleanAuthorized",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("external".utf8).write(
            to: root.appendingPathComponent("finder-created.txt")
        )

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        let defaultsSuite = "PEEK-CleanRootRotation-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            return XCTFail("unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(roots: [
                    FileSearchBackgroundRoot(url: root, scope: .files)
                ])
            },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            ),
            defaultsStore: FileSearchIndexDefaultsStore(defaults: defaults)
        )

        let dirtyPathsBeforeRun = try await store.dirtyPaths()
        XCTAssertEqual(dirtyPathsBeforeRun, [])
        let result = await indexer.run(mode: .incremental)
        guard case let .completed(mode, roots, _) = result else {
            return XCTFail("expected clean-root incremental refresh, got \(result)")
        }
        XCTAssertEqual(mode, .incremental)
        XCTAssertEqual(roots, 1)

        let service = FileSearchService(store: store)
        let snapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "finder-created")
        )
        XCTAssertEqual(snapshot.results.first?.item.displayName, "finder-created.txt")
    }

    func testIncrementalRunDoesNotClearLimitWithoutRefreshingEveryRoot() async throws {
        let context = makeContext()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let roots = ["RootA", "RootB"].map {
            context.directory.appendingPathComponent($0, isDirectory: true)
        }
        for root in roots {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try Data(root.lastPathComponent.utf8).write(
                to: root.appendingPathComponent("item.txt")
            )
            let generation = try await context.service.beginRootGeneration(rootURL: root)
            try await context.service.upsert(
                items: [item(
                    path: root.appendingPathComponent("old.txt").path,
                    name: "old.txt",
                    kind: .file
                )],
                generation: generation
            )
            try await context.service.commitRootGeneration(generation)
        }

        let store = FileSearchIndexStore(databaseURL: context.databaseURL)
        try await store.setGlobalLimitReached(true)
        let indexer = FileSearchBackgroundIndexer(
            sink: store,
            rootProvider: { _ in
                FileSearchBackgroundRootLease(roots: roots.map {
                    FileSearchBackgroundRoot(url: $0, scope: .files)
                })
            },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .incremental)
        XCTAssertEqual(result, .noChanges, "An unchanged completed root must not be walked on every periodic tick")
        let metadata = try await context.service.indexMetadata()
        XCTAssertEqual(metadata.phase, .limited)
    }

    func testBackgroundCleanupDrainsEveryInvisibleBatchBeforeIndexing() async {
        let sink = MultiBatchCleanupSink(remainingBatches: 12)
        let indexer = FileSearchBackgroundIndexer(
            sink: sink,
            rootProvider: { _ in FileSearchBackgroundRootLease(roots: []) },
            activityGate: FileSearchActivityGate(requiredIdleDuration: 0),
            configuration: FileSearchBackgroundIndexerConfiguration(
                maximumIndexedItems: 1_000,
                microBatchSize: 16,
                targetCPUFraction: 0.009,
                userIdleDuration: 0,
                maximumActivityPause: 1,
                dirtyPathLimit: 10
            )
        )

        let result = await indexer.run(mode: .incremental)
        XCTAssertEqual(result, .noChanges)
        let cleanupCalls = await sink.orphanCleanupCallCount()
        XCTAssertEqual(cleanupCalls, 13)
        let maximumCleanupLimit = await sink.maximumRequestedCleanupLimit()
        XCTAssertEqual(maximumCleanupLimit, 256)
    }

    func testSearchPanelPreferencesUseDefaultsAndClampStoredLimit() throws {
        let suiteName = "PEEK-SearchPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SearchPanelPreferences.current(defaults: defaults)
        XCTAssertEqual(initial.defaultCategory, .all)
        XCTAssertEqual(initial.resultLimit, 80)
        XCTAssertTrue(initial.showsPreview)
        XCTAssertEqual(initial.screen, .mouse)
        XCTAssertEqual(initial.position, .centered)

        defaults.set(
            SearchPanelCategory.applications.rawValue,
            forKey: PEEKPreferenceKey.searchDefaultCategory
        )
        defaults.set(500, forKey: PEEKPreferenceKey.searchResultLimit)
        defaults.set(true, forKey: PEEKPreferenceKey.searchIncludeHidden)
        defaults.set(false, forKey: PEEKPreferenceKey.searchShowsPreview)
        defaults.set(
            SearchResultDensity.compact.rawValue,
            forKey: PEEKPreferenceKey.searchResultDensity
        )

        let customized = SearchPanelPreferences.current(defaults: defaults)
        XCTAssertEqual(customized.defaultCategory, .all)
        XCTAssertEqual(customized.resultLimit, 200)
        XCTAssertTrue(customized.includesHiddenFiles)
        XCTAssertFalse(customized.showsPreview)
        XCTAssertEqual(customized.density, .compact)
    }

    func testFileSearchExclusionPolicyStartsEmptyAndOnlyMatchesUserPaths() throws {
        let suiteName = "PEEK-ExclusionPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(FileSearchExclusionPolicy.current(defaults: defaults).paths, [])

        let policy = FileSearchExclusionPolicy(
            paths: [" /Users/test/Archive/../Archive ", "relative/path"]
        )

        XCTAssertEqual(policy.paths, ["/Users/test/Archive"])
        XCTAssertTrue(policy.excludes(
            URL(fileURLWithPath: "/Users/test/Archive/report.pdf"),
            isDirectory: false
        ))
        XCTAssertFalse(policy.excludes(
            URL(fileURLWithPath: "/Users/test/Archive-Other"),
            isDirectory: true
        ))
        XCTAssertFalse(policy.excludes(
            URL(fileURLWithPath: "/Users/test/output/readme.md"),
            isDirectory: false
        ))
    }

    @MainActor
    func testApplicationRootDefaultsCanBeRemovedAndRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-ApplicationRoots-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstRoot = directory.appendingPathComponent("Applications-A", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Applications-B", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "PEEK-ApplicationRootDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FileSearchApplicationRootStore(
            defaults: defaults,
            pathsKey: "application-roots",
            customStorageKey: "custom-application-roots",
            defaultPaths: [firstRoot.path, secondRoot.path]
        )

        XCTAssertEqual(store.roots.map(\.path), [firstRoot.path, secondRoot.path])
        store.removeRoot(store.roots[0])
        XCTAssertEqual(store.roots.map(\.path), [secondRoot.path])

        let reloaded = FileSearchApplicationRootStore(
            defaults: defaults,
            pathsKey: "application-roots",
            customStorageKey: "custom-application-roots",
            defaultPaths: [firstRoot.path, secondRoot.path]
        )
        XCTAssertEqual(reloaded.roots.map(\.path), [secondRoot.path])
        reloaded.restoreDefaults()
        XCTAssertEqual(reloaded.roots.map(\.path), [firstRoot.path, secondRoot.path])
    }

    @MainActor
    func testDocumentDefaultRootsCanBeRemovedAndRestoredWithoutGrantingAccess() throws {
        let suiteName = "PEEK-DocumentRootDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configured = [
            FileSearchDocumentDefaultRoot(title: "文稿", path: "/Users/test/Documents"),
            FileSearchDocumentDefaultRoot(title: "桌面", path: "/Users/test/Desktop"),
            FileSearchDocumentDefaultRoot(title: "下载", path: "/Users/test/Downloads")
        ]
        let store = FileSearchDocumentDefaultRootStore(
            defaults: defaults,
            pathsKey: "document-default-roots",
            defaultRoots: configured
        )

        XCTAssertEqual(store.roots.map(\.title), ["文稿", "桌面", "下载"])
        store.removeRoot(path: "/Users/test/Desktop")
        XCTAssertEqual(store.roots.map(\.title), ["文稿", "下载"])

        let reloaded = FileSearchDocumentDefaultRootStore(
            defaults: defaults,
            pathsKey: "document-default-roots",
            defaultRoots: configured
        )
        XCTAssertEqual(reloaded.roots.map(\.title), ["文稿", "下载"])
        reloaded.restoreDefaults()
        XCTAssertEqual(reloaded.roots.map(\.title), ["文稿", "桌面", "下载"])
    }

    func testAccountHomeResolverRemovesPEEKSandboxContainerSuffix() {
        let containerHome = "/Users/test/Library/Containers/com.shawnshoper.peek/Data"
        let resolved = FileSearchAccountHome.resolve(
            sandboxHomePath: containerHome,
            directoryServicePath: containerHome
        )

        XCTAssertEqual(resolved.path, "/Users/test")
    }

    @MainActor
    func testLegacySandboxDocumentDefaultsMigrateWithoutCatchAllHome() throws {
        let suiteName = "PEEK-DocumentRootMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "document-default-roots"
        let legacy = "/Users/test/Library/Containers/com.shawnshoper.peek/Data"
        defaults.set([
            legacy + "/Documents",
            legacy + "/Desktop",
            legacy + "/Downloads",
            legacy
        ], forKey: key)
        let configured = [
            FileSearchDocumentDefaultRoot(title: "文稿", path: "/Users/test/Documents"),
            FileSearchDocumentDefaultRoot(title: "桌面", path: "/Users/test/Desktop"),
            FileSearchDocumentDefaultRoot(title: "下载", path: "/Users/test/Downloads")
        ]

        let store = FileSearchDocumentDefaultRootStore(
            defaults: defaults,
            pathsKey: key,
            defaultRoots: configured
        )

        XCTAssertEqual(store.roots, configured)
        XCTAssertEqual(
            defaults.stringArray(forKey: key),
            configured.map(\.path)
        )
        XCTAssertFalse(store.roots.contains { $0.title == "用户目录" })
    }

    func testExactDefaultAuthorizationUsesCanonicalPathToAvoidLocalizedDuplicate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-DefaultRootAlias-\(UUID().uuidString)",
            isDirectory: true
        )
        let target = directory.appendingPathComponent("Documents", isDirectory: true)
        let alias = directory.appendingPathComponent("文稿", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let defaultRoot = FileSearchDocumentDefaultRoot(
            title: "文稿",
            path: alias.path
        )
        let authorized = FileSearchAuthorizedRoot(
            id: UUID(),
            url: target,
            displayName: "Documents",
            lastKnownPath: target.path,
            status: .authorized
        )

        XCTAssertEqual(
            FileSearchDocumentRootAuthorization.exactRoot(
                for: defaultRoot,
                in: [authorized]
            )?.id,
            authorized.id
        )
    }

    func testUserHomeAuthorizationCoversEveryDefaultDocumentRootWithoutRemovingDefaults() {
        let configured = [
            FileSearchDocumentDefaultRoot(title: "文稿", path: "/Users/test/Documents"),
            FileSearchDocumentDefaultRoot(title: "桌面", path: "/Users/test/Desktop"),
            FileSearchDocumentDefaultRoot(title: "下载", path: "/Users/test/Downloads")
        ]
        let homeAuthorization = FileSearchAuthorizedRoot(
            id: UUID(),
            url: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            displayName: "test",
            lastKnownPath: "/Users/test",
            status: .authorized
        )

        let missing = FileSearchDocumentRootAuthorization.missingRoots(
            from: configured,
            authorizedRoots: [homeAuthorization]
        )

        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(configured.map(\.title), ["文稿", "桌面", "下载"])
        for root in configured {
            XCTAssertEqual(
                FileSearchDocumentRootAuthorization.coveringAuthorizedRoot(
                    for: root,
                    in: [homeAuthorization]
                )?.id,
                homeAuthorization.id
            )
        }
        XCTAssertNil(
            FileSearchDocumentRootAuthorization.exactRoot(
                for: configured[0],
                in: [homeAuthorization]
            )
        )
    }

    func testHomeAuthorizationPlansHighValueChildrenBeforeCatchAllRoot() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)

        let planned = FileSearchIndexRuntime.plannedFileRoots(
            authorizedRootURLs: [home],
            preferredRootURLs: [desktop, documents, downloads, home]
        )

        XCTAssertEqual(
            planned.map(\.url.path),
            [desktop.path, documents.path, downloads.path, home.path]
        )
        XCTAssertEqual(planned.map(\.priority), [0, 1, 2, 3])
        XCTAssertTrue(planned.allSatisfy { $0.scope == .files })
    }

    @MainActor
    func testRuntimeUsesCanonicalHighValueFoldersEvenWhenVisibleDefaultsWereReduced() throws {
        let suiteName = "PEEK-PriorityRootsIgnoreVisibleDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let configured = [
            FileSearchDocumentDefaultRoot(
                title: "桌面",
                path: home.appendingPathComponent("Desktop").path
            ),
            FileSearchDocumentDefaultRoot(title: "用户目录", path: home.path)
        ]
        let visibleStore = FileSearchDocumentDefaultRootStore(
            defaults: defaults,
            pathsKey: "visible-defaults",
            defaultRoots: configured
        )
        visibleStore.removeRoot(path: configured[0].path)
        XCTAssertEqual(visibleStore.roots.map(\.title), ["用户目录"])

        let planned = FileSearchIndexRuntime.plannedFileRoots(
            authorizedRootURLs: [home],
            preferredRootURLs: configured.map(\.url)
        )
        XCTAssertEqual(
            planned.map(\.url.path),
            ["/Users/test/Desktop", "/Users/test"]
        )
    }

    func testBackgroundRootOrderKeepsApplicationsThenPriorityFoldersThenHome() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let roots = [
            FileSearchBackgroundRoot(url: home, scope: .files, priority: 1_000),
            FileSearchBackgroundRoot(
                url: home.appendingPathComponent("Documents", isDirectory: true),
                scope: .files,
                priority: 1
            ),
            FileSearchBackgroundRoot(
                url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                scope: .applications
            ),
            FileSearchBackgroundRoot(
                url: home.appendingPathComponent("Desktop", isDirectory: true),
                scope: .files,
                priority: 0
            )
        ]

        XCTAssertEqual(
            FileSearchBackgroundIndexer<FileSearchIndexStore>
                .orderedDistinctRoots(roots)
                .map(\.url.path),
            [
                "/Applications",
                "/Users/test/Desktop",
                "/Users/test/Documents",
                "/Users/test"
            ]
        )
    }

    func testFirstLaunchAuthorizationPromptIsRecordedOnlyOnce() throws {
        let suiteName = "PEEK-FirstLaunchAuthorization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(FileSearchFirstLaunchAuthorizationPromptPolicy.shouldPresent(
            missingRootCount: 3,
            defaults: defaults
        ))
        XCTAssertFalse(FileSearchFirstLaunchAuthorizationPromptPolicy.shouldPresent(
            missingRootCount: 3,
            defaults: defaults
        ))
        XCTAssertTrue(defaults.bool(
            forKey: PEEKPreferenceKey.didPresentDocumentAuthorization
        ))
    }

    func testFirstLaunchAuthorizationPromptIsSilentlyCompletedWhenNothingIsMissing() throws {
        let suiteName = "PEEK-FirstLaunchAuthorizationComplete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(FileSearchFirstLaunchAuthorizationPromptPolicy.shouldPresent(
            missingRootCount: 0,
            defaults: defaults
        ))
        XCTAssertFalse(FileSearchFirstLaunchAuthorizationPromptPolicy.shouldPresent(
            missingRootCount: 2,
            defaults: defaults
        ))
    }

    func testLegacyV2IndexIsHiddenAndQueuedForBackgroundRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-LegacyV2-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = directory.appendingPathComponent("SearchIndex.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try createLegacyV2Index(at: databaseURL)

        let store = FileSearchIndexStore(databaseURL: databaseURL)
        let service = FileSearchService(store: store)
        let snapshot = await service.currentSnapshot(
            for: FileSearchRequest(query: "legacy-visible")
        )
        let metadata = try await service.indexMetadata()
        let dirtyPaths = try await service.dirtyPaths()

        XCTAssertTrue(snapshot.results.isEmpty)
        XCTAssertEqual(metadata.committedRootCount, 0)
        XCTAssertEqual(metadata.phase, .idle)
        XCTAssertEqual(
            dirtyPaths.map(\.standardizedFileURL.path),
            ["/legacy-authorized"]
        )
        XCTAssertEqual(try userVersion(at: databaseURL), 7)
    }

    func testV4MigrationRebuildsApplicationRootsButKeepsDocumentsQueryable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-LegacyV4Aliases-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = directory.appendingPathComponent("SearchIndex.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try createLegacyV4Index(at: databaseURL)

        let service = FileSearchService(
            store: FileSearchIndexStore(databaseURL: databaseURL)
        )
        let application = await service.currentSnapshot(
            for: FileSearchRequest(query: "calculator")
        )
        let document = await service.currentSnapshot(
            for: FileSearchRequest(query: "draft")
        )
        let metadata = try await service.indexMetadata()
        let dirtyPaths = try await service.dirtyPaths()

        XCTAssertTrue(application.results.isEmpty)
        XCTAssertEqual(document.results.first?.item.displayName, "draft.txt")
        XCTAssertEqual(metadata.committedRootCount, 1)
        XCTAssertNil(metadata.lastSuccessfulIndexAt)
        XCTAssertEqual(
            dirtyPaths.map(\.standardizedFileURL.path),
            ["/System/Applications"]
        )
        XCTAssertEqual(try userVersion(at: databaseURL), 7)
    }

    private func makeContext() -> (
        directory: URL,
        databaseURL: URL,
        service: FileSearchService
    ) {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-SQLiteIndexTests-\(UUID().uuidString)",
            isDirectory: true
        )
        // Keep files created by individual tests separate from the SQLite files.
        // Existing per-test cleanup may remove the workspace before local variables
        // are released; the database is removed only after its service is closed.
        let directory = fixtureDirectory.appendingPathComponent(
            "Workspace",
            isDirectory: true
        )
        let databaseURL = fixtureDirectory
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("SearchIndex.sqlite3")
        let service = FileSearchService(
            store: FileSearchIndexStore(databaseURL: databaseURL)
        )
        addTeardownBlock { [service, fixtureDirectory] in
            await service.shutdown()
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        return (
            directory,
            databaseURL,
            service
        )
    }

    private func item(
        path: String,
        name: String,
        kind: FileSearchItemKind,
        searchAliases: [String] = []
    ) -> FileSearchItem {
        FileSearchItem(
            url: URL(fileURLWithPath: path, isDirectory: kind != .file),
            displayName: name,
            kind: kind,
            typeDescription: kind.category.rawValue,
            isHidden: name.hasPrefix("."),
            searchAliases: searchAliases
        )
    }

    private func prepared(
        name: String,
        kind: FileSearchItemKind
    ) -> FileSearchPreparedItem {
        let suffix: String
        switch kind {
        case .application: suffix = ".app"
        case .file: suffix = ".txt"
        case .folder: suffix = ""
        }
        return FileSearchPreparedItem(item: item(
            path: "/tmp/\(name)\(suffix)",
            name: name,
            kind: kind
        ))
    }

    private func journalMode(at databaseURL: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            throw FileSearchIndexStoreError.unavailable("无法读取测试 SQLite")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw FileSearchIndexStoreError.unavailable("无法读取 journal_mode")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw FileSearchIndexStoreError.unavailable("journal_mode 为空")
        }
        return String(cString: value)
    }

    private func userVersion(at databaseURL: URL) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            throw FileSearchIndexStoreError.unavailable("无法读取测试 SQLite")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw FileSearchIndexStoreError.unavailable("无法读取 user_version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FileSearchIndexStoreError.unavailable("user_version 为空")
        }
        return sqlite3_column_int(statement, 0)
    }

    private func seedLargeCommittedIndex(
        at databaseURL: URL,
        itemCount: Int
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw FileSearchIndexStoreError.unavailable("无法打开大索引测试数据库")
        }
        defer { sqlite3_close_v2(database) }
        let boundedCount = max(1, min(itemCount, 200_000))
        let sql = """
        BEGIN IMMEDIATE;
        INSERT OR REPLACE INTO roots(
            root_path, active_generation, staging_generation, last_success,
            indexed_applications, indexed_files, indexed_folders
        ) VALUES('/cancel-root', 1, NULL, 1, 0, \(boundedCount), 0);
        WITH RECURSIVE sequence(value) AS (
            SELECT 1
            UNION ALL
            SELECT value + 1 FROM sequence WHERE value < \(boundedCount)
        )
        INSERT INTO entries(
            root_path, generation, path, display_name, kind,
            type_description, is_hidden, file_size, created_at,
            modified_at, last_opened_at, application_version,
            normalized_name, normalized_path, compact_pinyin,
            pinyin_initials, word_initials, normalized_aliases,
            compact_alias_pinyin, alias_pinyin_initials, alias_word_initials
        )
        SELECT
            '/cancel-root', 1,
            printf('/cancel-root/document-%06d.txt', value),
            printf('document-%06d.txt', value),
            1, 'file', 0, NULL, NULL, NULL, NULL, NULL,
            printf('document-%06d.txt', value),
            printf('/cancel-root/document-%06d.txt', value),
            printf('document%06d', value), 'd', 'd', '', '', '', ''
        FROM sequence;
        COMMIT;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw FileSearchIndexStoreError.sqlite(message: message, code: result)
        }
    }

    private func createLegacyV2Index(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw FileSearchIndexStoreError.unavailable("无法创建旧版测试 SQLite")
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        CREATE TABLE roots(
            root_path TEXT PRIMARY KEY NOT NULL,
            active_generation INTEGER,
            staging_generation INTEGER,
            last_success REAL,
            skipped_generated INTEGER NOT NULL DEFAULT 0,
            inaccessible INTEGER NOT NULL DEFAULT 0,
            reached_limit INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE entries(
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
            PRIMARY KEY(root_path, generation, path)
        ) WITHOUT ROWID;
        CREATE TABLE dirty_paths(
            path TEXT PRIMARY KEY NOT NULL,
            recorded_at REAL NOT NULL
        );
        INSERT INTO roots(root_path, active_generation, last_success)
        VALUES('/legacy-authorized', 1, 1);
        INSERT INTO entries(
            root_path, generation, path, display_name, kind,
            type_description, is_hidden, normalized_name, normalized_path,
            compact_pinyin, pinyin_initials, word_initials
        ) VALUES(
            '/legacy-authorized', 1, '/legacy-authorized/legacy-visible.txt',
            'legacy-visible.txt', 1, 'file', 0, 'legacy-visible.txt',
            '/legacy-authorized/legacy-visible.txt', '', '', 'lv'
        );
        PRAGMA user_version=2;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? "无法写入旧版测试 SQLite"
            sqlite3_free(errorMessage)
            throw FileSearchIndexStoreError.unavailable(message)
        }
    }

    private func createLegacyV4Index(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw FileSearchIndexStoreError.unavailable("无法创建 v4 测试 SQLite")
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        CREATE TABLE roots(
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
        );
        CREATE TABLE entries(
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
            PRIMARY KEY(root_path, generation, path)
        ) WITHOUT ROWID;
        CREATE TABLE dirty_paths(
            path TEXT PRIMARY KEY NOT NULL,
            revision INTEGER NOT NULL
        );
        CREATE TABLE index_state(
            key TEXT PRIMARY KEY NOT NULL,
            int_value INTEGER NOT NULL
        );
        INSERT INTO index_state(key, int_value) VALUES('dirty_revision', 0);
        INSERT INTO roots(
            root_path, active_generation, last_success,
            indexed_applications, indexed_files
        ) VALUES
            ('/System/Applications', 1, 1, 1, 0),
            ('/authorized', 1, 1, 0, 1);
        INSERT INTO entries(
            root_path, generation, path, display_name, kind,
            type_description, is_hidden, normalized_name, normalized_path,
            compact_pinyin, pinyin_initials, word_initials
        ) VALUES
            ('/System/Applications', 1,
             '/System/Applications/Calculator.app', 'Calculator', 0,
             'application', 0, 'calculator',
             '/system/applications/calculator.app', 'calculator', 'c', 'c'),
            ('/authorized', 1, '/authorized/draft.txt', 'draft.txt', 1,
             'file', 0, 'draft.txt', '/authorized/draft.txt', '', '', 'd');
        PRAGMA user_version=4;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? "无法写入 v4 测试 SQLite"
            sqlite3_free(errorMessage)
            throw FileSearchIndexStoreError.unavailable(message)
        }
    }
}

@MainActor
final class SearchPanelLayoutTests: XCTestCase {
    func testCollapsedLowerContentIsExcludedFromAccessibilityAndInteraction() {
        let policy = SearchPanelLowerContentPolicy(expanded: false)

        XCTAssertTrue(policy.accessibilityHidden)
        XCTAssertFalse(policy.allowsHitTesting)
        XCTAssertTrue(policy.isDisabled)
    }

    func testExpandedLowerContentRestoresAccessibilityAndInteraction() {
        let policy = SearchPanelLowerContentPolicy(expanded: true)

        XCTAssertFalse(policy.accessibilityHidden)
        XCTAssertTrue(policy.allowsHitTesting)
        XCTAssertFalse(policy.isDisabled)
    }

    func testNativeChromeUsesOneContinuousRoundedClip() {
        let chrome = SearchPanelChromeView(
            frame: CGRect(x: 0, y: 0, width: 920, height: 680)
        )

        XCTAssertEqual(chrome.material, .popover)
        XCTAssertEqual(chrome.blendingMode, .behindWindow)
        XCTAssertEqual(chrome.state, .active)
        XCTAssertTrue(chrome.wantsLayer)
        XCTAssertEqual(
            chrome.layer?.cornerRadius,
            SearchPanelLayout.cornerRadius
        )
        XCTAssertEqual(chrome.layer?.cornerCurve, .continuous)
        XCTAssertEqual(chrome.layer?.masksToBounds, true)
        XCTAssertEqual(chrome.layer?.borderWidth, 1)
    }

    func testExpandedCanvasRemainsTopAnchoredDuringNativeReveal() {
        for visibleHeight in [58, 100, 300, 680] as [CGFloat] {
            let bounds = CGRect(
                x: 0,
                y: 0,
                width: SearchPanelLayout.width,
                height: visibleHeight
            )
            let canvas = SearchPanelLayout.canvasFrame(
                in: bounds,
                expandedHeight: SearchPanelLayout.expandedHeight
            )

            XCTAssertEqual(canvas.height, SearchPanelLayout.expandedHeight)
            XCTAssertEqual(canvas.maxY, bounds.maxY, accuracy: 0.001)
            XCTAssertEqual(canvas.width, bounds.width)
        }
    }

    func testNativeResizeHonorsReduceMotionAndVisibility() {
        XCTAssertTrue(
            SearchPanelLayout.shouldAnimate(
                requested: true,
                panelVisible: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            SearchPanelLayout.shouldAnimate(
                requested: true,
                panelVisible: true,
                reduceMotion: true
            )
        )
        XCTAssertFalse(
            SearchPanelLayout.shouldAnimate(
                requested: true,
                panelVisible: false,
                reduceMotion: false
            )
        )
    }

    func testNativeAnimationUsesSlowerRevealAndFasterDismissal() {
        XCTAssertEqual(
            SearchPanelLayout.animationDuration(expanded: true),
            0.20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SearchPanelLayout.animationDuration(expanded: false),
            0.16,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            SearchPanelLayout.animationDuration(expanded: true),
            SearchPanelLayout.animationDuration(expanded: false)
        )
    }

    func testRapidExpansionTargetsKeepHeaderTopEdgeStable() {
        var frame = CGRect(
            x: 120,
            y: 722,
            width: SearchPanelLayout.width,
            height: SearchPanelLayout.collapsedHeight
        )
        let originalTopEdge = frame.maxY

        for iteration in 0 ..< 20 {
            frame = SearchPanelLayout.frame(
                from: frame,
                expanded: iteration.isMultiple(of: 2),
                visibleFrame: nil
            )
            XCTAssertEqual(frame.maxY, originalTopEdge, accuracy: 0.001)
        }

        XCTAssertEqual(frame.height, SearchPanelLayout.collapsedHeight)
    }

    func testCenteredCompactFrameKeepsLegacyExpandedHeaderPosition() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 2560, height: 1386)

        let expanded = SearchPanelLayout.centeredFrame(
            expanded: true,
            in: visibleFrame
        )
        let compact = SearchPanelLayout.centeredFrame(
            expanded: false,
            in: visibleFrame
        )

        XCTAssertEqual(compact.maxY, expanded.maxY)
        XCTAssertEqual(compact.minX, expanded.minX)
        XCTAssertEqual(compact.width, expanded.width)
        XCTAssertEqual(compact.height, SearchPanelLayout.collapsedHeight)
    }

    func testIndexProgressExpandsCompactPanelBelowSearchField() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let standard = SearchPanelLayout.centeredFrame(
            expanded: false,
            showsIndexProgress: false,
            in: visibleFrame
        )
        let indexing = SearchPanelLayout.centeredFrame(
            expanded: false,
            showsIndexProgress: true,
            in: visibleFrame
        )

        XCTAssertEqual(
            indexing.height,
            SearchPanelLayout.collapsedHeight + SearchPanelLayout.indexProgressHeight
        )
        XCTAssertEqual(indexing.maxY, standard.maxY, accuracy: 0.001)
    }

    func testIndexProgressDoesNotChangeExpandedPanelHeight() {
        let original = CGRect(x: 120, y: 722, width: 920, height: 58)

        let expanded = SearchPanelLayout.frame(
            from: original,
            expanded: true,
            showsIndexProgress: true,
            visibleFrame: nil
        )

        XCTAssertEqual(expanded.height, SearchPanelLayout.expandedHeight)
        XCTAssertEqual(expanded.maxY, original.maxY, accuracy: 0.001)
    }

    func testCenteredFramesRecalculateForCurrentDisplay() {
        let laptop = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let external = CGRect(x: 1440, y: -120, width: 2560, height: 1410)

        let laptopFrame = SearchPanelLayout.centeredFrame(
            expanded: true,
            in: laptop
        )
        let externalFrame = SearchPanelLayout.centeredFrame(
            expanded: true,
            in: external
        )

        XCTAssertEqual(laptopFrame.midX, laptop.midX, accuracy: 0.5)
        XCTAssertEqual(laptopFrame.midY, laptop.midY, accuracy: 0.5)
        XCTAssertEqual(externalFrame.midX, external.midX, accuracy: 0.5)
        XCTAssertEqual(externalFrame.midY, external.midY, accuracy: 0.5)
        XCTAssertNotEqual(laptopFrame.origin, externalFrame.origin)
    }

    func testCenteredExpandedFrameFitsSmallVisibleArea() {
        let visibleFrame = CGRect(x: -1024, y: 0, width: 1024, height: 700)

        let expanded = SearchPanelLayout.centeredFrame(
            expanded: true,
            in: visibleFrame
        )
        let compact = SearchPanelLayout.centeredFrame(
            expanded: false,
            in: visibleFrame
        )

        XCTAssertGreaterThanOrEqual(expanded.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(expanded.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(expanded.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(expanded.maxY, visibleFrame.maxY)
        XCTAssertEqual(compact.maxY, expanded.maxY)
    }

    func testCollapsePreservesTopEdge() {
        let original = CGRect(x: 120, y: 100, width: 920, height: 680)

        let collapsed = SearchPanelLayout.frame(
            from: original,
            expanded: false,
            visibleFrame: nil
        )

        XCTAssertEqual(collapsed.height, SearchPanelLayout.collapsedHeight)
        XCTAssertEqual(collapsed.maxY, original.maxY)
        XCTAssertEqual(collapsed.minX, original.minX)
    }

    func testExpandPreservesCollapsedTopEdge() {
        let collapsed = CGRect(
            x: 120,
            y: 722,
            width: 920,
            height: SearchPanelLayout.collapsedHeight
        )

        let expanded = SearchPanelLayout.frame(
            from: collapsed,
            expanded: true,
            visibleFrame: nil
        )

        XCTAssertEqual(expanded.height, SearchPanelLayout.expandedHeight)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
    }

    func testExpansionStaysInsideVisibleScreen() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let collapsed = CGRect(
            x: 260,
            y: 40,
            width: 920,
            height: SearchPanelLayout.collapsedHeight
        )

        let expanded = SearchPanelLayout.frame(
            from: collapsed,
            expanded: true,
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThanOrEqual(expanded.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(expanded.maxY, visibleFrame.maxY)
    }
}

@MainActor
final class SearchPanelViewModelTests: XCTestCase {
    func testInstalledApplicationPrecedesBuiltInToolsAndToolsHideInvalidActions() async throws {
        let application = panelItem(path: "/Applications/PEEK.app", name: "PEEK", category: .applications)
        let tool = try XCTUnwrap(PEEKTranslateSearchRegistration.item(matching: "翻译", category: .all))
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.init(items: [tool, application]))
                continuation.finish()
            }
        }
        let model = SearchPanelViewModel(provider: provider, actionHandler: SearchPanelTestActionHandler())
        defer { model.shutdown() }
        model.start()
        try await waitUntil { !model.isSearching && model.results.count == 2 }
        XCTAssertEqual(model.orderedResults.map(\.id), [application.id, tool.id])
        XCTAssertEqual(model.selectedItemID, application.id)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.visibleActions, [.open])
        XCTAssertNil(model.unavailableActionMessage)
    }
    func testIndexStatusStaysVisibleThroughCountingWaitingAndFailureUntilFinished() async throws {
        let tracker = FileSearchInitialIndexProgressTracker()
        let model = SearchPanelViewModel(
            provider: AnySearchPanelProvider { _, _, _ in
                AsyncThrowingStream { $0.finish() }
            },
            initialIndexProgressProvider: tracker,
            initialIndexProgressPollingIntervalNanoseconds: 10_000_000
        )
        defer { model.shutdown() }

        await tracker.schedule(applicationRootCount: 2, delay: 1)
        model.start()
        try await waitUntil { model.initialIndexProgress?.phase == .scheduled }

        await tracker.beginCounting(rootCount: 2)
        await tracker.recordDiscovered(100)
        try await waitUntil { model.initialIndexProgress?.discoveredItems == 100 }
        XCTAssertEqual(model.initialIndexProgress?.progressBarValue, 0)

        await tracker.waitToRetry()
        try await waitUntil { model.initialIndexProgress?.phase == .waitingToRetry }
        XCTAssertEqual(model.initialIndexProgress?.progressBarValue, 0)

        await tracker.fail("Permission denied")
        try await waitUntil { model.initialIndexProgress?.phase == .failed }
        XCTAssertEqual(model.initialIndexProgress?.localizedStatusMessage, "Permission denied")

        await tracker.beginIndexing(rootCount: 2, totalItemCount: 100, phase: .indexingFiles)
        await tracker.recordEncountered(60)
        await tracker.recordIndexed(60)
        try await waitUntil { model.initialIndexProgress?.progressBarValue == 0.6 }

        await tracker.recordEncountered(20, newlyDiscovered: 20)
        try await waitUntil { model.initialIndexProgress?.progressBarValue == 0.5 }
        XCTAssertEqual(model.initialIndexProgress?.discoveredItems, 120)

        await tracker.finish()
        try await waitUntil { model.initialIndexProgress == nil }
    }

    func testProgressPollingDoesNotRepublishUnchangedPresentation() async throws {
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { $0.finish() }
        }
        let progress = FileSearchInitialIndexProgressSnapshot(
            phase: .indexingFiles, completedRoots: 0, totalRoots: 1,
            indexedApplications: 0, estimatedRemaining: 10,
            discoveredItems: 100, indexedItems: 20
        )
        let progressProvider = SearchPanelInitialIndexProgressStub(progress)
        let model = SearchPanelViewModel(
            provider: provider, initialIndexProgressProvider: progressProvider,
            initialIndexProgressPollingIntervalNanoseconds: 10_000_000
        )
        var publications = 0
        let subscription = model.$initialIndexProgress.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel(); model.shutdown() }
        model.start()
        try await waitUntil { model.initialIndexProgress != nil }
        try await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(publications, 1)
        await progressProvider.setSnapshot(nil)
        try await waitUntil { model.initialIndexProgress == nil }
        XCTAssertEqual(publications, 2)
    }

    func testInitialIndexProgressAppearsWhileActiveAndHidesAfterCompletion() async throws {
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: []))
                continuation.finish()
            }
        }
        let progress = FileSearchInitialIndexProgressSnapshot(
            phase: .indexingApplications,
            completedRoots: 1,
            totalRoots: 4,
            indexedApplications: 12,
            estimatedRemaining: 3,
            discoveredItems: 40,
            indexedItems: 12,
            currentRootName: "Applications"
        )
        let progressProvider = SearchPanelInitialIndexProgressStub(progress)
        let viewModel = SearchPanelViewModel(
            provider: provider,
            initialIndexProgressProvider: progressProvider,
            initialIndexProgressPollingIntervalNanoseconds: 10_000_000
        )
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil { viewModel.initialIndexProgress == progress }

        await progressProvider.setSnapshot(nil)
        try await waitUntil { viewModel.initialIndexProgress == nil }

        await progressProvider.setSnapshot(progress)
        try await waitUntil { viewModel.initialIndexProgress == progress }
        viewModel.pauseForPanel()
        XCTAssertNil(viewModel.initialIndexProgress)
    }

    func testPausedPanelKeepsCachedResultsAndRefreshesWhenReactivated() async throws {
        var searchCount = 0
        let item = panelItem(
            path: "/Applications/PEEK.app",
            name: "PEEK",
            category: .applications
        )
        let provider = AnySearchPanelProvider { _, _, _ in
            searchCount += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: [item]))
                continuation.finish()
            }
        }
        let viewModel = SearchPanelViewModel(provider: provider)
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil { !viewModel.isSearching && searchCount == 1 }
        viewModel.pauseForPanel()

        XCTAssertFalse(viewModel.isPanelActive)
        XCTAssertEqual(viewModel.results.map(\.id), [item.id])

        viewModel.activateForPanel()
        try await waitUntil { !viewModel.isSearching && searchCount == 2 }
        XCTAssertTrue(viewModel.isPanelActive)
        XCTAssertEqual(viewModel.results.map(\.id), [item.id])
    }

    func testHiddenPanelDefersQueryUntilNextActivation() async throws {
        var searchCount = 0
        let provider = AnySearchPanelProvider { _, _, _ in
            searchCount += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: []))
                continuation.finish()
            }
        }
        let viewModel = SearchPanelViewModel(provider: provider)
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil { !viewModel.isSearching && searchCount == 1 }
        viewModel.pauseForPanel()
        viewModel.query = "hua.conf"
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(searchCount, 1)

        viewModel.activateForPanel()
        try await waitUntil { !viewModel.isSearching && searchCount == 2 }
    }

    func testKeyboardMonitorLifecycleRejectsDeliveriesAfterStopAndReplacement() {
        var lifecycle = SearchPanelKeyboardMonitorLifecycle()
        let firstGeneration = lifecycle.beginMonitoring()

        XCTAssertTrue(lifecycle.acceptsDelivery(for: firstGeneration))

        lifecycle.endMonitoring()
        XCTAssertFalse(lifecycle.acceptsDelivery(for: firstGeneration))

        let secondGeneration = lifecycle.beginMonitoring()
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(lifecycle.acceptsDelivery(for: firstGeneration))
        XCTAssertTrue(lifecycle.acceptsDelivery(for: secondGeneration))
    }

    func testStoppingKeyboardMonitorDoesNotPublishModifierStateDuringDismantle() async throws {
        var publishedStates: [Bool] = []
        let coordinator = SearchPanelKeyboardBridge.Coordinator(
            moveUp: {},
            moveDown: {},
            activate: {},
            activateResultAtIndex: { _ in },
            optionStateChanged: { publishedStates.append($0) },
            cycleCategory: { _ in },
            dismiss: {},
            isSearchFieldFocused: { true }
        )

        coordinator.startMonitoring()
        coordinator.stopMonitoring()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(publishedStates.isEmpty)
    }

    func testOptionNumberShortcutMapsOneThroughNineAndZeroToFirstTenResults() {
        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        XCTAssertEqual(
            keyCodes.compactMap(SearchPanelNumericShortcut.resultIndex),
            Array(0 ... 9)
        )
        XCTAssertNil(SearchPanelNumericShortcut.resultIndex(forKeyCode: 24))
    }

    func testNumberShortcutOpensVisualOrderAcrossApplicationsFilesAndFolders() async throws {
        let application = panelItem(
            path: "/Applications/PEEK.app",
            name: "PEEK",
            category: .applications
        )
        let file = panelItem(
            path: "/tmp/peek-notes.txt",
            name: "peek-notes.txt",
            category: .files
        )
        let folder = panelItem(
            path: "/tmp/peek-folder",
            name: "peek-folder",
            category: .folders
        )
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: [file, folder, application]))
                continuation.finish()
            }
        }
        let actionHandler = SearchPanelRecordingActionHandler()
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: actionHandler
        )
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil { !viewModel.isSearching && viewModel.results.count == 3 }
        XCTAssertEqual(viewModel.orderedResults.map(\.id), [application.id, file.id, folder.id])

        for index in 0 ..< 3 {
            viewModel.openResult(at: index)
            try await waitUntil { actionHandler.performedItemIDs.count == index + 1 }
        }

        XCTAssertEqual(actionHandler.performedItemIDs, [application.id, file.id, folder.id])
    }

    func testApplicationUsagePersistsAndRanksEmptyAllResultsAppsBeforeDocuments() throws {
        let suiteName = "PEEK-ApplicationUsage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var currentDate = Date(timeIntervalSince1970: 100)
        let store = SearchApplicationUsageStore(
            defaults: defaults,
            storageKey: "usage",
            now: { currentDate }
        )
        let notes = fileSearchResult(
            path: "/Applications/Notes.app",
            name: "Notes",
            kind: .application,
            score: 0
        )
        let preview = fileSearchResult(
            path: "/Applications/Preview.app",
            name: "Preview",
            kind: .application,
            score: 0
        )
        let document = fileSearchResult(
            path: "/tmp/notes.txt",
            name: "notes.txt",
            kind: .file,
            score: 0
        )

        store.recordOpen(for: notes.item.url)
        currentDate = Date(timeIntervalSince1970: 200)
        store.recordOpen(for: preview.item.url)
        currentDate = Date(timeIntervalSince1970: 300)
        store.recordOpen(for: preview.item.url)

        XCTAssertEqual(
            store.ranked(
                [document, notes, preview],
                query: "",
                category: .all
            ).map(\.item.displayName),
            ["Preview", "Notes", "notes.txt"]
        )

        let reloaded = SearchApplicationUsageStore(
            defaults: defaults,
            storageKey: "usage"
        )
        XCTAssertEqual(reloaded.usage(for: preview.item.url)?.openCount, 2)
        XCTAssertEqual(reloaded.usage(for: notes.item.url)?.openCount, 1)
    }

    func testApplicationUsageDoesNotOverrideMoreRelevantTextMatch() throws {
        let suiteName = "PEEK-ApplicationUsage-Relevance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SearchApplicationUsageStore(
            defaults: defaults,
            storageKey: "usage"
        )
        let exact = fileSearchResult(
            path: "/Applications/Calendar.app",
            name: "Calendar",
            kind: .application,
            score: 100
        )
        let frequent = fileSearchResult(
            path: "/Applications/Calculator.app",
            name: "Calculator",
            kind: .application,
            score: 80
        )
        for _ in 0 ..< 20 {
            store.recordOpen(for: frequent.item.url)
        }

        XCTAssertEqual(
            store.ranked(
                [exact, frequent],
                query: "calendar",
                category: .all
            ).first?.item.displayName,
            "Calendar"
        )
    }

    func testApplicationOpenClosesPanelBeforeAsynchronousLaunchCompletes() async throws {
        let suiteName = "PEEK-ApplicationUsage-Open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SearchApplicationUsageStore(
            defaults: defaults,
            storageKey: "usage"
        )
        let application = panelItem(
            path: "/Applications/PEEK.app",
            name: "PEEK",
            category: .applications
        )
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: [application]))
                continuation.finish()
            }
        }
        let launcher = SearchPanelDeferredApplicationLauncher()
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: DefaultSearchPanelActionHandler(
                applicationLauncher: launcher
            ),
            applicationUsageTracker: store
        )
        defer { viewModel.shutdown() }
        var didClose = false
        viewModel.onRequestClose = { didClose = true }

        viewModel.start()
        try await waitUntil {
            !viewModel.isSearching
                && viewModel.capability(for: .open).isEnabled
        }
        viewModel.perform(.open)
        XCTAssertTrue(didClose)
        XCTAssertNil(store.usage(for: application.url))
        try await waitUntil { launcher.requestedURLs == [application.url] }
        XCTAssertTrue(viewModel.isPerformingAction)

        launcher.finishSuccessfully()
        try await waitUntil {
            !viewModel.isPerformingAction
                && store.usage(for: application.url)?.openCount == 1
        }
    }

    func testAllCategoryGroupsApplicationsFirstAndArrowKeysFollowVisibleOrder() async throws {
        let defaults = UserDefaults.standard
        let previousPreviewValue = defaults.object(
            forKey: PEEKPreferenceKey.searchShowsPreview
        )
        defaults.set(false, forKey: PEEKPreferenceKey.searchShowsPreview)
        defer {
            if let previousPreviewValue {
                defaults.set(
                    previousPreviewValue,
                    forKey: PEEKPreferenceKey.searchShowsPreview
                )
            } else {
                defaults.removeObject(forKey: PEEKPreferenceKey.searchShowsPreview)
            }
        }

        let firstApplication = panelItem(
            path: "/Applications/PEEK.app",
            name: "PEEK",
            category: .applications
        )
        let secondApplication = panelItem(
            path: "/Applications/Preview.app",
            name: "Preview",
            category: .applications
        )
        let document = panelItem(
            path: "/tmp/peek-notes.txt",
            name: "peek-notes.txt",
            category: .files
        )
        let provider = AnySearchPanelProvider { query, _, _ in
            AsyncThrowingStream { continuation in
                let items = query == "next"
                    ? [document, secondApplication]
                    : [document, firstApplication]
                continuation.yield(SearchPanelSearchUpdate(items: items))
                continuation.finish()
            }
        }
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: SearchPanelTestActionHandler()
        )
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil { !viewModel.isSearching && viewModel.results.count == 2 }

        XCTAssertEqual(
            viewModel.resultGroups.map(\.kind),
            [.applications, .documents]
        )
        XCTAssertEqual(viewModel.selectedItemID, firstApplication.id)

        viewModel.moveSelection(by: 1)
        XCTAssertEqual(viewModel.selectedItemID, document.id)
        viewModel.moveSelection(by: -1)
        XCTAssertEqual(viewModel.selectedItemID, firstApplication.id)

        // A new query must select its new first visible result even when the
        // previously selected URL is still present in the response.
        viewModel.selectedItemID = document.id
        viewModel.query = "next"
        try await waitUntil {
            !viewModel.isSearching
                && viewModel.selectedItemID == secondApplication.id
        }
        XCTAssertEqual(viewModel.selectedItemID, secondApplication.id)
    }

    func testLargeTextPreviewIsBoundedAndLoadsMoreWithoutReplacingSelection() async throws {
        let defaults = UserDefaults.standard
        let previousPreviewValue = defaults.object(
            forKey: PEEKPreferenceKey.searchShowsPreview
        )
        let previousRetainsQueryValue = defaults.object(
            forKey: PEEKPreferenceKey.searchRetainsLastQuery
        )
        defaults.set(true, forKey: PEEKPreferenceKey.searchShowsPreview)
        defaults.set(false, forKey: PEEKPreferenceKey.searchRetainsLastQuery)
        defer {
            if let previousPreviewValue {
                defaults.set(
                    previousPreviewValue,
                    forKey: PEEKPreferenceKey.searchShowsPreview
                )
            } else {
                defaults.removeObject(forKey: PEEKPreferenceKey.searchShowsPreview)
            }
            if let previousRetainsQueryValue {
                defaults.set(
                    previousRetainsQueryValue,
                    forKey: PEEKPreferenceKey.searchRetainsLastQuery
                )
            } else {
                defaults.removeObject(forKey: PEEKPreferenceKey.searchRetainsLastQuery)
            }
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-LargePreview-\(UUID().uuidString).config"
        )
        let contents = (0 ..< 5_000)
            .map { "line-\($0)=value-\($0)\n" }
            .joined()
        try Data(contents.utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let item = SearchPanelItem(
            url: fileURL,
            displayName: "large.config",
            category: .files,
            fileSize: Int64(contents.utf8.count)
        )
        let provider = AnySearchPanelProvider { _, _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield(SearchPanelSearchUpdate(items: [item]))
                continuation.finish()
            }
        }
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: SearchPanelTestActionHandler()
        )
        defer { viewModel.shutdown() }

        viewModel.start()
        try await waitUntil {
            if case .text = viewModel.previewKind { return true }
            return false
        }
        guard case .text(let initialPreview) = viewModel.previewKind else {
            return XCTFail("Expected a bounded text preview")
        }
        XCTAssertEqual(viewModel.selectedItemID, item.id)
        XCTAssertLessThanOrEqual(
            initialPreview.loadedByteCount,
            SearchPanelTextPreviewLoader.initialByteLimit
        )
        XCTAssertLessThanOrEqual(
            initialPreview.text.filter(\.isNewline).count,
            SearchPanelTextPreviewLoader.initialLineLimit
        )
        XCTAssertTrue(initialPreview.isTruncated)
        XCTAssertTrue(initialPreview.canLoadMore)

        viewModel.loadMoreTextPreview()
        try await waitUntil {
            guard !viewModel.isLoadingMoreTextPreview,
                  case .text(let preview) = viewModel.previewKind else {
                return false
            }
            return preview.loadedByteCount > initialPreview.loadedByteCount
        }
        guard case .text(let expandedPreview) = viewModel.previewKind else {
            return XCTFail("Expected an expanded text preview")
        }
        XCTAssertEqual(viewModel.selectedItemID, item.id)
        XCTAssertGreaterThan(
            expandedPreview.loadedByteCount,
            initialPreview.loadedByteCount
        )
        XCTAssertLessThanOrEqual(
            expandedPreview.loadedByteCount,
            SearchPanelTextPreviewLoader.initialByteLimit
                + SearchPanelTextPreviewLoader.byteIncrement
        )
    }

    func testBoundedTextPreviewKeepsValidUTF8WhenChunkEndsInsideScalar() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-UnicodePreview-\(UUID().uuidString).conf"
        )
        let contents = String(repeating: "中", count: 40_000)
        try Data(contents.utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let preview = try XCTUnwrap(
            SearchPanelTextPreviewLoader.load(at: fileURL)
        )

        XCTAssertFalse(preview.text.isEmpty)
        XCTAssertTrue(preview.text.allSatisfy { $0 == "中" })
        XCTAssertLessThanOrEqual(
            preview.loadedByteCount,
            SearchPanelTextPreviewLoader.initialByteLimit
        )
        XCTAssertTrue(preview.isTruncated)
    }

    private func panelItem(
        path: String,
        name: String,
        category: SearchPanelCategory
    ) -> SearchPanelItem {
        SearchPanelItem(
            url: URL(fileURLWithPath: path),
            displayName: name,
            category: category,
            isDirectory: category == .applications || category == .folders
        )
    }

    private func fileSearchResult(
        path: String,
        name: String,
        kind: FileSearchItemKind,
        score: Double
    ) -> FileSearchResult {
        FileSearchResult(
            item: FileSearchItem(
                url: URL(fileURLWithPath: path),
                displayName: name,
                kind: kind,
                typeDescription: kind == .application ? "application" : "file",
                isHidden: false
            ),
            score: score
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Timed out waiting for search state")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class SearchPanelTestActionHandler: SearchPanelActionHandling {
    func capability(
        for action: SearchPanelFileAction,
        item: SearchPanelItem
    ) -> SearchPanelActionCapability {
        .enabled
    }

    func perform(
        _ action: SearchPanelFileAction,
        item: SearchPanelItem
    ) async throws -> SearchPanelActionFeedback {
        SearchPanelActionFeedback("ok")
    }
}

private actor SearchPanelInitialIndexProgressStub: SearchPanelInitialIndexProgressProviding {
    private var currentSnapshot: FileSearchInitialIndexProgressSnapshot?

    init(_ snapshot: FileSearchInitialIndexProgressSnapshot?) {
        currentSnapshot = snapshot
    }

    func snapshot() -> FileSearchInitialIndexProgressSnapshot? {
        currentSnapshot
    }

    func setSnapshot(_ snapshot: FileSearchInitialIndexProgressSnapshot?) {
        currentSnapshot = snapshot
    }
}

@MainActor
private final class SearchPanelDeferredApplicationLauncher: SearchPanelApplicationLaunching {
    private(set) var requestedURLs: [URL] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func openApplication(at url: URL) async throws {
        requestedURLs.append(url)
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finishSuccessfully() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SearchPanelRecordingActionHandler: SearchPanelActionHandling {
    private(set) var performedItemIDs: [SearchPanelItem.ID] = []

    func capability(
        for action: SearchPanelFileAction,
        item: SearchPanelItem
    ) -> SearchPanelActionCapability {
        .enabled
    }

    func perform(
        _ action: SearchPanelFileAction,
        item: SearchPanelItem
    ) async throws -> SearchPanelActionFeedback {
        performedItemIDs.append(item.id)
        return SearchPanelActionFeedback("ok")
    }
}

private actor FileSearchLeaseReleaseRecorder {
    private var count = 0

    func recordRelease() { count += 1 }
    func releaseCount() -> Int { count }
}

private actor FileSearchIndexModeRecorder {
    private var modes: [FileSearchBackgroundIndexMode] = []

    func record(_ mode: FileSearchBackgroundIndexMode) {
        modes.append(mode)
    }

    func recordedModes() -> [FileSearchBackgroundIndexMode] {
        modes
    }
}

/// Deterministic filesystem changes/failures between count, staging and commit.
/// Production SQLite remains the sink so tests verify generation visibility.
private actor ObservingBackgroundIndexSink: FileSearchBackgroundIndexSink {
    let store: FileSearchIndexStore
    let beforeBegin: @Sendable (URL) async throws -> Void
    let afterUpsert: @Sendable (FileSearchRootGeneration) async throws -> Void
    private var batchSizes: [Int] = []

    init(
        store: FileSearchIndexStore,
        beforeBegin: @escaping @Sendable (URL) async throws -> Void = { _ in },
        afterUpsert: @escaping @Sendable (FileSearchRootGeneration) async throws -> Void = { _ in }
    ) {
        self.store = store
        self.beforeBegin = beforeBegin
        self.afterUpsert = afterUpsert
    }

    func lastSuccessfulIndexDate() async throws -> Date? {
        try await store.lastSuccessfulIndexDate()
    }
    func hasUnindexedRoots(_ urls: [URL]) async throws -> Bool {
        try await store.hasUnindexedRoots(urls)
    }
    func committedItemCount(excludingRootPath: String?) async throws -> Int {
        try await store.committedItemCount(excludingRootPath: excludingRootPath)
    }
    func committedItemCount(under path: String, rootPath: String) async throws -> Int {
        try await store.committedItemCount(under: path, rootPath: rootPath)
    }
    func reclaimFileEntries(excludingRootPath: String, limit: Int) async throws -> Int {
        try await store.reclaimFileEntries(excludingRootPath: excludingRootPath, limit: limit)
    }
    func hasReachedLimit() async throws -> Bool { try await store.hasReachedLimit() }
    func commitSubtreeGeneration(_ token: FileSearchRootGeneration, path: String) async throws {
        try await store.commitSubtreeGeneration(token, path: path)
    }
    func beginRootGeneration(rootURL: URL) async throws -> FileSearchRootGeneration {
        try await beforeBegin(rootURL)
        return try await store.beginRootGeneration(rootURL: rootURL)
    }
    func upsert(_ items: [FileSearchItem], in token: FileSearchRootGeneration) async throws {
        batchSizes.append(items.count)
        try await store.upsert(items, in: token)
        try await afterUpsert(token)
    }
    func upsertBatchSizes() -> [Int] { batchSizes }
    func preserveCommittedEntries(
        under path: String, excluding excludedPaths: [String],
        in token: FileSearchRootGeneration, afterPath: String?, limit: Int
    ) async throws -> FileSearchPreservedEntryBatch {
        try await store.preserveCommittedEntries(
            under: path, excluding: excludedPaths, in: token, afterPath: afterPath, limit: limit
        )
    }
    func commitRootGeneration(
        _ token: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics,
        reachedLimit: Bool
    ) async throws {
        try await store.commitRootGeneration(token, statistics: statistics, reachedLimit: reachedLimit)
    }
    func abortRootGeneration(_ token: FileSearchRootGeneration) async throws {
        try await store.abortRootGeneration(token)
    }
    func dirtyPaths(limit: Int) async throws -> [URL] { try await store.dirtyPaths(limit: limit) }
    func markDirty(_ url: URL) async throws { try await store.markDirty(url) }
    func clearDirtyPaths(_ urls: [URL]) async throws { try await store.clearDirtyPaths(urls) }
    func setGlobalLimitReached(_ reached: Bool) async throws { try await store.setGlobalLimitReached(reached) }
    func purgeObsoleteEntries(for token: FileSearchRootGeneration, limit: Int) async throws -> Int {
        try await store.purgeObsoleteEntries(for: token, limit: limit)
    }
    func purgeOrphanedEntries(limit: Int) async throws -> Int {
        try await store.purgeOrphanedEntries(limit: limit)
    }
}

private actor CancellingBackgroundIndexSink: FileSearchBackgroundIndexSink {
    func committedItemCount(under path: String, rootPath: String) throws -> Int { 0 }
    func reclaimFileEntries(excludingRootPath: String, limit: Int) throws -> Int { 0 }
    func hasReachedLimit() throws -> Bool { false }
    func commitSubtreeGeneration(_ token: FileSearchRootGeneration, path: String) throws { throw CancellationError() }
    private var beginCount = 0
    private var abortCount = 0
    private var commitCount = 0

    func lastSuccessfulIndexDate() throws -> Date? { nil }
    func hasUnindexedRoots(_ urls: [URL]) throws -> Bool { !urls.isEmpty }
    func committedItemCount(excludingRootPath: String?) throws -> Int { 0 }
    func preserveCommittedEntries(
        under path: String, excluding excludedPaths: [String],
        in token: FileSearchRootGeneration, afterPath: String?, limit: Int
    ) throws -> FileSearchPreservedEntryBatch { .init() }

    func beginRootGeneration(rootURL: URL) throws -> FileSearchRootGeneration {
        beginCount += 1
        return FileSearchRootGeneration(
            rootPath: rootURL.standardizedFileURL.path,
            generation: Int64(beginCount),
            dirtyCutoff: Date().timeIntervalSince1970
        )
    }

    func upsert(
        _ items: [FileSearchItem],
        in token: FileSearchRootGeneration
    ) throws {
        throw CancellationError()
    }

    func commitRootGeneration(
        _ token: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics,
        reachedLimit: Bool
    ) throws {
        commitCount += 1
    }

    func abortRootGeneration(_ token: FileSearchRootGeneration) throws {
        abortCount += 1
    }

    func dirtyPaths(limit: Int) throws -> [URL] { [] }
    func markDirty(_ url: URL) throws {}
    func clearDirtyPaths(_ urls: [URL]) throws {}
    func setGlobalLimitReached(_ reached: Bool) throws {}
    func purgeObsoleteEntries(
        for token: FileSearchRootGeneration,
        limit: Int
    ) throws -> Int { 0 }
    func purgeOrphanedEntries(limit: Int) throws -> Int { 0 }

    func counts() -> (begin: Int, abort: Int, commit: Int) {
        (beginCount, abortCount, commitCount)
    }
}

private actor MultiBatchCleanupSink: FileSearchBackgroundIndexSink {
    func committedItemCount(under path: String, rootPath: String) throws -> Int { 0 }
    func reclaimFileEntries(excludingRootPath: String, limit: Int) throws -> Int { 0 }
    func hasReachedLimit() throws -> Bool { false }
    func commitSubtreeGeneration(_ token: FileSearchRootGeneration, path: String) throws { throw FileSearchIndexStoreError.staleGeneration }
    private var remainingBatches: Int
    private var cleanupCalls = 0
    private var requestedCleanupLimits: [Int] = []

    init(remainingBatches: Int) {
        self.remainingBatches = remainingBatches
    }

    func lastSuccessfulIndexDate() throws -> Date? { nil }
    func hasUnindexedRoots(_ urls: [URL]) throws -> Bool { !urls.isEmpty }
    func committedItemCount(excludingRootPath: String?) throws -> Int { 0 }
    func preserveCommittedEntries(
        under path: String, excluding excludedPaths: [String],
        in token: FileSearchRootGeneration, afterPath: String?, limit: Int
    ) throws -> FileSearchPreservedEntryBatch { .init() }
    func beginRootGeneration(rootURL: URL) throws -> FileSearchRootGeneration {
        XCTFail("cleanup-only run must not begin a generation")
        return FileSearchRootGeneration(
            rootPath: rootURL.path,
            generation: 1,
            dirtyCutoff: Int64(0)
        )
    }
    func upsert(
        _ items: [FileSearchItem],
        in token: FileSearchRootGeneration
    ) throws {}
    func commitRootGeneration(
        _ token: FileSearchRootGeneration,
        statistics: FileSearchRootCommitStatistics,
        reachedLimit: Bool
    ) throws {}
    func abortRootGeneration(_ token: FileSearchRootGeneration) throws {}
    func dirtyPaths(limit: Int) throws -> [URL] { [] }
    func markDirty(_ url: URL) throws {}
    func clearDirtyPaths(_ urls: [URL]) throws {}
    func setGlobalLimitReached(_ reached: Bool) throws {}
    func purgeObsoleteEntries(
        for token: FileSearchRootGeneration,
        limit: Int
    ) throws -> Int { 0 }
    func purgeOrphanedEntries(limit: Int) throws -> Int {
        cleanupCalls += 1
        requestedCleanupLimits.append(limit)
        guard remainingBatches > 0 else { return 0 }
        remainingBatches -= 1
        return limit
    }
    func orphanCleanupCallCount() -> Int { cleanupCalls }
    func maximumRequestedCleanupLimit() -> Int { requestedCleanupLimits.max() ?? 0 }
}

final class PEEKLocalizationTests: XCTestCase {
    func testAppLanguagePersistsAppleLanguagesAndCanReturnToSystem() throws {
        let suiteName = "PEEKLocalizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PEEKAppLanguage.english.apply(defaults: defaults)
        XCTAssertEqual(PEEKAppLanguage.current(defaults: defaults), .english)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        PEEKAppLanguage.simplifiedChinese.apply(defaults: defaults)
        XCTAssertEqual(
            defaults.stringArray(forKey: "AppleLanguages"),
            ["zh-Hans"]
        )

        PEEKAppLanguage.system.apply(defaults: defaults)
        XCTAssertEqual(PEEKAppLanguage.current(defaults: defaults), .system)
        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
        )
    }

    func testLocalizableCatalogHasCompleteEnglishCoverageAndSafeFormats() throws {
        let catalog = try loadCatalog(named: "Localizable")
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 600)

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations["en"] as? [String: Any],
                key
            )
            let stringUnit = try XCTUnwrap(
                english["stringUnit"] as? [String: Any],
                key
            )
            let value = try XCTUnwrap(stringUnit["value"] as? String, key)
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(formatSpecifiers(in: key), formatSpecifiers(in: value), key)
        }

        XCTAssertEqual(englishValue(for: "通用", in: strings), "General")
        XCTAssertEqual(englishValue(for: "搜索", in: strings), "Search")
        XCTAssertEqual(englishValue(for: "截图", in: strings), "Capture")
        XCTAssertEqual(
            englishValue(for: "识别二维码", in: strings),
            "Recognize QR Code"
        )
    }

    func testInfoPlistCatalogContainsBothSupportedLanguages() throws {
        let catalog = try loadCatalog(named: "InfoPlist")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let usage = try XCTUnwrap(
            strings["NSScreenCaptureUsageDescription"] as? [String: Any]
        )
        let localizations = try XCTUnwrap(
            usage["localizations"] as? [String: Any]
        )
        XCTAssertNotNil(localizations["en"])
        XCTAssertNotNil(localizations["zh-Hans"])
    }

    private func loadCatalog(named name: String) throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("PEEK/Resources")
            .appendingPathComponent("\(name).xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func englishValue(
        for key: String,
        in strings: [String: Any]
    ) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let english = localizations?["en"] as? [String: Any]
        let unit = english?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private func formatSpecifiers(in value: String) -> [String] {
        let pattern = #"%(?:lld|@|d|u)"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return (expression?.matches(in: value, range: range) ?? []).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }
}
