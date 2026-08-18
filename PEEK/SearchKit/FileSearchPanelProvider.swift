import Foundation

@MainActor
final class FileSearchPanelProvider: SearchPanelProviding {
    static let shared = FileSearchPanelProvider()

    private let service: FileSearchService
    private let usageStore: SearchApplicationUsageStore

    init(
        service: FileSearchService = FileSearchService(),
        usageStore: SearchApplicationUsageStore = .shared
    ) {
        self.service = service
        self.usageStore = usageStore
    }

    func search(
        query: String,
        category: SearchPanelCategory,
        includeHidden: Bool
    ) -> AsyncThrowingStream<SearchPanelSearchUpdate, Error> {
        let preferences = SearchPanelPreferences.current()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendLimit = trimmedQuery.isEmpty
            && (category == .all || category == .applications)
            ? 500
            : preferences.resultLimit
        let request = FileSearchRequest(
            query: query,
            category: Self.category(category),
            includeHidden: includeHidden,
            limit: backendLimit
        )
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task(priority: .userInitiated) { [service, usageStore] in
                do {
                    let snapshots = await service.search(request)
                    for await snapshot in snapshots {
                        guard !Task.isCancelled else { break }
                        if let failure = snapshot.failure {
                            throw failure
                        }
                        let initialProgress = await FileSearchInitialIndexProgressTracker
                            .shared.snapshot()
                        let rankedResults = usageStore.ranked(
                            snapshot.results,
                            query: query,
                            category: request.category
                        )
                        continuation.yield(SearchPanelSearchUpdate(
                            items: rankedResults
                                .prefix(preferences.resultLimit)
                                .map(Self.panelItem),
                            statusMessage: Self.statusMessage(
                                snapshot,
                                initialProgress: initialProgress
                            )
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func statusMessage(
        _ snapshot: FileSearchSnapshot,
        initialProgress: FileSearchInitialIndexProgressSnapshot?
    ) -> String? {
        if let initialProgress {
            return initialProgress.localizedStatusMessage
        }
        let count = snapshot.statistics.indexedItems
        let inaccessible = snapshot.statistics.inaccessibleLocations
        switch snapshot.phase {
        case .idle:
            return L10n.tr("尚无已完成索引；应用快速索引即将开始")
        case .indexingApplications:
            return L10n.tr("正在快速建立应用索引；普通系统文件不会入库")
        case .indexingFiles:
            return L10n.tr("后台索引尚未完成；当前仅显示已提交结果")
        case .ready:
            return inaccessible > 0
                ? L10n.tr(
                    "已提交本地索引（%lld 项，%lld 处受权限限制）",
                    Int64(count),
                    Int64(inaccessible)
                )
                : L10n.tr("已提交本地索引（%lld 项）", Int64(count))
        case .limited:
            return L10n.tr("索引已达到 30 万项上限，结果可能不完整")
        }
    }

    func didMoveItem(from sourceURL: URL, to destinationURL: URL) async throws {
        try await service.replaceMovedItem(from: sourceURL, to: destinationURL)
    }

    func didCopyItem(to destinationURL: URL) async throws {
        // Copying only records a dirty path. It becomes searchable after the
        // next scheduled background index pass.
        try await service.markDirty(destinationURL)
    }

    private nonisolated static func category(
        _ category: SearchPanelCategory
    ) -> FileSearchCategory {
        switch category {
        case .all: return .all
        case .applications: return .applications
        case .files: return .files
        case .folders: return .folders
        }
    }

    private nonisolated static func panelItem(_ result: FileSearchResult) -> SearchPanelItem {
        let item = result.item
        var metadata: [SearchPanelMetadataField] = []
        if item.isHidden {
            metadata.append(SearchPanelMetadataField(label: L10n.tr("隐藏项目"), value: L10n.tr("是")))
        }
        if let version = item.applicationVersion {
            metadata.append(SearchPanelMetadataField(label: L10n.tr("应用版本"), value: version))
        }
        if let createdAt = item.createdAt {
            metadata.append(SearchPanelMetadataField(
                label: L10n.tr("创建时间"),
                value: Self.format(createdAt)
            ))
        }
        if let lastOpenedAt = item.lastOpenedAt {
            metadata.append(SearchPanelMetadataField(
                label: L10n.tr("最近访问（文件系统）"),
                value: Self.format(lastOpenedAt)
            ))
        }
        return SearchPanelItem(
            url: item.url,
            displayName: item.displayName,
            subtitle: item.url.path,
            kindDescription: localizedKindDescription(item.kind),
            category: panelCategory(item.kind),
            isDirectory: item.kind != .file,
            fileSize: item.fileSize,
            modifiedAt: item.modifiedAt,
            // Bundle metadata is intentionally not reopened on the UI path.
            // Application-specific previews use the indexed name/path and can
            // enrich details asynchronously if needed.
            applicationBundleIdentifier: nil,
            metadata: metadata
        )
    }

    private nonisolated static func panelCategory(
        _ kind: FileSearchItemKind
    ) -> SearchPanelCategory {
        switch kind {
        case .application: return .applications
        case .file: return .files
        case .folder: return .folders
        }
    }

    nonisolated static func localizedKindDescription(
        _ kind: FileSearchItemKind
    ) -> String {
        switch kind {
        case .application: return L10n.tr("应用程序")
        case .file: return L10n.tr("文件")
        case .folder: return L10n.tr("文件夹")
        }
    }

    private nonisolated static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
