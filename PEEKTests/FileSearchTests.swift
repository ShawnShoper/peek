import Carbon.HIToolbox
import SQLite3
import XCTest
@testable import PEEK

final class FileSearchTests: XCTestCase {
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
        XCTAssertEqual(scheduled.localizedStatusMessage, "首次索引预计约 12 秒")

        let indexing = FileSearchInitialIndexProgressSnapshot(
            phase: .indexingApplications,
            completedRoots: 2,
            totalRoots: 4,
            indexedApplications: 120,
            estimatedRemaining: 65,
            discoveredItems: 150,
            indexedItems: 120,
            currentRootName: "Applications"
        )
        XCTAssertEqual(indexing.fractionCompleted, 0.8)
        XCTAssertEqual(
            indexing.localizedStatusMessage,
            "应用索引中 · Applications，已索引 120 / 已发现 150 项，目录 3/4，预计剩余 2 分钟"
        )
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

        await tracker.begin(applicationRootCount: 3)
        await tracker.beginRoot(named: "Applications")
        await tracker.recordDiscovered(40)
        await tracker.recordIndexed(24)
        await tracker.completeApplicationRoot()
        let indexing = await tracker.snapshot()
        XCTAssertEqual(indexing?.phase, .indexingApplications)
        XCTAssertEqual(indexing?.completedRoots, 1)
        XCTAssertEqual(indexing?.indexedApplications, 24)
        XCTAssertEqual(indexing?.discoveredItems, 40)
        XCTAssertEqual(indexing?.indexedItems, 24)
        XCTAssertEqual(indexing?.fractionCompleted, 0.6)
        XCTAssertNotNil(indexing?.estimatedRemaining)

        await tracker.completeApplicationRoot()
        await tracker.completeApplicationRoot()
        let completed = await tracker.snapshot()
        XCTAssertNil(completed)
    }

    func testLiveIndexProgressAllowsDiscoveredTotalToGrowDuringScan() async {
        let tracker = FileSearchInitialIndexProgressTracker()
        await tracker.begin(rootCount: 2, phase: .indexingFiles)
        await tracker.beginRoot(named: "Desktop", phase: .indexingFiles)
        await tracker.recordDiscovered(20)
        await tracker.recordIndexed(16)
        let first = await tracker.snapshot()

        await tracker.recordDiscovered(15)
        await tracker.recordIndexed(8)
        let second = await tracker.snapshot()

        XCTAssertEqual(first?.discoveredItems, 20)
        XCTAssertEqual(first?.indexedItems, 16)
        XCTAssertEqual(second?.discoveredItems, 35)
        XCTAssertEqual(second?.indexedItems, 24)
        XCTAssertTrue(
            second?.localizedStatusMessage.contains(
                "已索引 24 / 已发现 35 项"
            ) == true
        )
        XCTAssertTrue(
            second?.localizedStatusMessage.contains("总数会随扫描动态增加") == true
        )
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

    func testFastIndexPolicyStillStopsWhileSearchPanelIsVisible() async {
        let gate = FileSearchActivityGate(requiredIdleDuration: 0)
        await gate.setActivity(true, blocker: .searchPanel)

        let normal = await gate.snapshot()
        let fast = await gate.snapshot(ignoring: [.userActive])

        XCTAssertFalse(normal.canIndex)
        XCTAssertFalse(fast.canIndex)

        await gate.setActivity(true, blocker: .capture)
        let protectedFast = await gate.snapshot(ignoring: [.userActive])
        XCTAssertFalse(protectedFast.canIndex)
    }

    func testBackgroundFullRunCommitsAuthorizedRootAndReleasesLease() async throws {
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
        XCTAssertLessThan(indexer.targetCPUFraction, 0.01)
        XCTAssertLessThanOrEqual(indexer.initialTargetCPUFraction, 0.05)
        XCTAssertGreaterThanOrEqual(indexer.initialTargetCPUFraction, 0.01)
        XCTAssertGreaterThan(indexer.initialMicroBatchSize, indexer.microBatchSize)
        XCTAssertGreaterThan(
            indexer.initialMaximumEntriesPerSecond,
            indexer.incrementalMaximumEntriesPerSecond
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
        guard case let .completed(_, refreshedRoots, _) = result else {
            return XCTFail("expected incremental refresh, got \(result)")
        }
        XCTAssertEqual(refreshedRoots, 1)
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
        XCTAssertEqual(try userVersion(at: databaseURL), 6)
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
        XCTAssertEqual(try userVersion(at: databaseURL), 6)
    }

    private func makeContext() -> (
        directory: URL,
        databaseURL: URL,
        service: FileSearchService
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PEEK-SQLiteIndexTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = directory.appendingPathComponent("SearchIndex.sqlite3")
        return (
            directory,
            databaseURL,
            FileSearchService(store: FileSearchIndexStore(databaseURL: databaseURL))
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
final class SearchPanelViewModelTests: XCTestCase {
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

    func testSuccessfulApplicationOpenUpdatesUsageBeforePanelCloses() async throws {
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
        let viewModel = SearchPanelViewModel(
            provider: provider,
            actionHandler: SearchPanelTestActionHandler(),
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
        try await waitUntil {
            didClose && store.usage(for: application.url)?.openCount == 1
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

private actor CancellingBackgroundIndexSink: FileSearchBackgroundIndexSink {
    private var beginCount = 0
    private var abortCount = 0
    private var commitCount = 0

    func lastSuccessfulIndexDate() throws -> Date? { nil }
    func committedItemCount(excludingRootPath: String?) throws -> Int { 0 }

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
    ) throws -> Bool { false }
    func purgeOrphanedEntries(limit: Int) throws -> Bool { false }

    func counts() -> (begin: Int, abort: Int, commit: Int) {
        (beginCount, abortCount, commitCount)
    }
}

private actor MultiBatchCleanupSink: FileSearchBackgroundIndexSink {
    private var remainingBatches: Int
    private var cleanupCalls = 0

    init(remainingBatches: Int) {
        self.remainingBatches = remainingBatches
    }

    func lastSuccessfulIndexDate() throws -> Date? { nil }
    func committedItemCount(excludingRootPath: String?) throws -> Int { 0 }
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
    ) throws -> Bool { false }
    func purgeOrphanedEntries(limit: Int) throws -> Bool {
        cleanupCalls += 1
        guard remainingBatches > 0 else { return false }
        remainingBatches -= 1
        return true
    }
    func orphanCleanupCallCount() -> Int { cleanupCalls }
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
