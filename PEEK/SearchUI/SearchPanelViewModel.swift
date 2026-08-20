import AppKit
import Foundation
@preconcurrency import QuickLookThumbnailing

@MainActor
final class SearchPanelViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    @Published var selectedCategory: SearchPanelCategory = .all {
        didSet {
            guard selectedCategory != oldValue else { return }
            scheduleSearch(immediately: true)
        }
    }

    @Published var includesHiddenFiles = false {
        didSet {
            guard includesHiddenFiles != oldValue else { return }
            scheduleSearch(immediately: true)
        }
    }

    @Published private(set) var results: [SearchPanelItem] = []
    @Published var selectedItemID: SearchPanelItem.ID? {
        didSet {
            guard selectedItemID != oldValue else { return }
            loadPreview()
            refreshActionCapabilities()
        }
    }
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewKind: SearchPanelPreviewKind = .loading
    @Published private(set) var isLoadingMoreTextPreview = false
    @Published private(set) var isSearching = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var indexStatusMessage: String?
    @Published private(set) var isPanelActive = false

    var onRequestClose: (() -> Void)?

    private let provider: any SearchPanelProviding
    private let actionHandler: any SearchPanelActionHandling
    private let applicationUsageTracker: any SearchApplicationUsageTracking
    private var searchTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var capabilityTask: Task<Void, Never>?
    private var previewRequest: QLThumbnailGenerator.Request?
    private var previewTask: Task<Void, Never>?
    private var previewTimeoutTask: Task<Void, Never>?
    private var previewAccess: FileSearchSecurityScopedAccess?
    private var previewGeneration = 0
    private var actionCapabilities: [SearchPanelFileAction: SearchPanelActionCapability] = [:]
    private var searchGeneration = 0
    private var lastAppliedSearchGeneration: Int?

    init(
        provider: any SearchPanelProviding,
        actionHandler: (any SearchPanelActionHandling)? = nil,
        applicationUsageTracker: any SearchApplicationUsageTracking = SearchApplicationUsageStore.shared
    ) {
        let preferences = SearchPanelPreferences.current()
        let initialQuery = preferences.retainsLastQuery
            ? UserDefaults.standard.string(
                forKey: PEEKPreferenceKey.searchLastQuery
            ) ?? ""
            : ""
        self.provider = provider
        self.actionHandler = actionHandler ?? DefaultSearchPanelActionHandler()
        self.applicationUsageTracker = applicationUsageTracker
        selectedCategory = preferences.defaultCategory
        includesHiddenFiles = preferences.includesHiddenFiles
        query = initialQuery
    }

    deinit {
        searchTask?.cancel()
        actionTask?.cancel()
        capabilityTask?.cancel()
        previewTask?.cancel()
        previewTimeoutTask?.cancel()
        if let previewRequest {
            QLThumbnailGenerator.shared.cancel(previewRequest)
        }
        previewAccess?.stop()
    }

    var selectedItem: SearchPanelItem? {
        guard let selectedItemID else { return nil }
        return results.first { $0.id == selectedItemID }
    }

    var hasVisibleQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var resultGroups: [SearchPanelResultGroup] {
        guard selectedCategory == .all else {
            let kind: SearchPanelResultGroupKind = selectedCategory == .applications
                ? .applications
                : .documents
            return results.isEmpty ? [] : [SearchPanelResultGroup(kind: kind, items: results)]
        }
        let applications = results.filter { $0.category == .applications }
        let documents = results.filter {
            $0.category == .files || $0.category == .folders
        }
        return [
            SearchPanelResultGroup(kind: .applications, items: applications),
            SearchPanelResultGroup(kind: .documents, items: documents)
        ].filter { !$0.items.isEmpty }
    }

    var orderedResults: [SearchPanelItem] {
        resultGroups.flatMap(\.items)
    }

    var browserHistoryNotice: String? {
        guard let item = selectedItem,
              item.category == .applications,
              Self.isBrowserApplication(item) else { return nil }
        return L10n.tr("最近页面需要安装浏览器扩展并由用户单独授权")
    }

    var selectedMetadata: [SearchPanelMetadataField] {
        guard let item = selectedItem else { return [] }
        var fields = [
            SearchPanelMetadataField(label: L10n.tr("类型"), value: item.kindDescription),
            SearchPanelMetadataField(label: L10n.tr("位置"), value: item.url.deletingLastPathComponent().path)
        ]
        if let fileSize = item.fileSize, !item.isDirectory {
            fields.append(
                SearchPanelMetadataField(
                    label: L10n.tr("大小"),
                    value: ByteCountFormatter.string(
                        fromByteCount: fileSize,
                        countStyle: .file
                    )
                )
            )
        }
        if let modifiedAt = item.modifiedAt {
            fields.append(
                SearchPanelMetadataField(
                    label: L10n.tr("修改时间"),
                    value: Self.dateFormatter.string(from: modifiedAt)
                )
            )
        }
        fields.append(contentsOf: item.metadata)
        return fields
    }

    func capability(for action: SearchPanelFileAction) -> SearchPanelActionCapability {
        guard selectedItem != nil else {
            return .disabled(L10n.tr("请先选择一个搜索结果"))
        }
        return actionCapabilities[action]
            ?? .disabled(L10n.tr("正在检查当前项目是否可操作"))
    }

    var unavailableActionMessage: String? {
        let actions: [SearchPanelFileAction] = [.moveTo, .airDrop]
        let messages = actions.compactMap { action -> String? in
            let capability = capability(for: action)
            guard !capability.isEnabled, let reason = capability.reason else { return nil }
            return "\(action.title)：\(reason)"
        }
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "；")
    }

    func start() {
        activateForPanel()
    }

    func prewarm() {
        guard !isPanelActive, results.isEmpty, searchTask == nil else { return }
        scheduleSearch(immediately: true, allowWhileInactive: true)
    }

    func activateForPanel(initialQuery: String? = nil) {
        if let initialQuery, query != initialQuery {
            query = initialQuery
        }
        let wasActive = isPanelActive
        isPanelActive = true
        if selectedItemID == nil {
            selectedItemID = orderedResults.first?.id
        }
        loadPreview()
        refreshActionCapabilities()
        if !wasActive || searchTask == nil {
            scheduleSearch(immediately: true)
        }
    }

    func pauseForPanel() {
        guard isPanelActive else { return }
        isPanelActive = false
        persistQueryPreference()
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        capabilityTask?.cancel()
        capabilityTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        if let previewRequest {
            QLThumbnailGenerator.shared.cancel(previewRequest)
        }
        previewRequest = nil
        previewAccess?.stop()
        previewAccess = nil
        previewGeneration &+= 1
        isLoadingMoreTextPreview = false
        isSearching = false
    }

    func shutdown() {
        isPanelActive = false
        persistQueryPreference()
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        capabilityTask?.cancel()
        capabilityTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        if let previewRequest {
            QLThumbnailGenerator.shared.cancel(previewRequest)
        }
        previewRequest = nil
        previewAccess?.stop()
        previewAccess = nil
        previewGeneration &+= 1
        isLoadingMoreTextPreview = false
        isSearching = false
        actionTask?.cancel()
        actionTask = nil
        isPerformingAction = false
    }

    private func persistQueryPreference() {
        let preferences = SearchPanelPreferences.current()
        if preferences.retainsLastQuery {
            UserDefaults.standard.set(
                query,
                forKey: PEEKPreferenceKey.searchLastQuery
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: PEEKPreferenceKey.searchLastQuery
            )
        }
    }

    func moveSelection(by delta: Int) {
        let navigableResults = orderedResults
        guard !navigableResults.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { id in
            navigableResults.firstIndex { $0.id == id }
        } ?? (delta > 0 ? -1 : navigableResults.count)
        let nextIndex = min(
            max(currentIndex + delta, 0),
            navigableResults.count - 1
        )
        selectedItemID = navigableResults[nextIndex].id
    }

    func cycleCategory(reverse: Bool) {
        let categories = SearchPanelCategory.allCases
        guard let currentIndex = categories.firstIndex(of: selectedCategory) else {
            selectedCategory = .all
            return
        }
        let offset = reverse ? -1 : 1
        let nextIndex = (currentIndex + offset + categories.count) % categories.count
        selectedCategory = categories[nextIndex]
    }

    func openSelection() {
        perform(.open)
    }

    func loadMoreTextPreview() {
        guard case .text(let currentPreview) = previewKind,
              currentPreview.canLoadMore,
              let item = selectedItem,
              !isLoadingMoreTextPreview else { return }

        let generation = previewGeneration
        let selectedID = item.id
        let nextLimits = SearchPanelTextPreviewLoader.nextLimits(
            after: currentPreview
        )
        isLoadingMoreTextPreview = true
        do {
            previewAccess = try FileSearchSecurityScopeResolver.resolve(
                containing: item.url
            )
        } catch {
            isLoadingMoreTextPreview = false
            errorMessage = error.localizedDescription
            return
        }

        let url = item.url
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                SearchPanelTextPreviewLoader.load(
                    at: url,
                    byteLimit: nextLimits.byteLimit,
                    lineLimit: nextLimits.lineLimit
                )
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.previewGeneration == generation,
                  self.selectedItemID == selectedID else { return }
            self.previewTask = nil
            self.isLoadingMoreTextPreview = false
            self.finishPreviewAccess()
            if let preview {
                self.previewKind = .text(preview)
            }
        }
    }

    func openSystemSetting(_ setting: SearchPanelSystemSettingEntry) {
        guard NSWorkspace.shared.open(setting.destination) else {
            errorMessage = L10n.tr("无法打开该系统设置项目")
            return
        }
        feedbackMessage = L10n.tr("已打开 %@", setting.title)
    }

    func perform(_ action: SearchPanelFileAction) {
        let capability = capability(for: action)
        guard capability.isEnabled else {
            errorMessage = capability.reason ?? L10n.tr("当前操作不可用")
            return
        }
        guard let item = selectedItem else {
            errorMessage = SearchPanelActionError.noSelection.localizedDescription
            return
        }
        beginAction(action, item: item)
    }

    /// Opens a numbered result immediately. The shortcut uses the exact visual
    /// order (applications first in All) and does not wait for transient
    /// preview/capability work triggered by selection changes.
    func openResult(at index: Int) {
        let items = orderedResults
        guard items.indices.contains(index), !isPerformingAction else { return }
        let item = items[index]
        selectedItemID = item.id
        beginAction(.open, item: item)
    }

    private func beginAction(_ action: SearchPanelFileAction, item: SearchPanelItem) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        feedbackMessage = nil
        let actionHandler = actionHandler
        let provider = provider
        let blocksBackgroundIndex = action == .moveTo || action == .copyTo
        actionTask = Task { @MainActor [weak self, actionHandler, provider] in
            if blocksBackgroundIndex {
                FileSearchIndexRuntime.shared.setFileOperationActive(true)
            }
            defer {
                if blocksBackgroundIndex {
                    FileSearchIndexRuntime.shared.setFileOperationActive(false)
                }
            }
            do {
                let feedback = try await actionHandler.perform(action, item: item)
                if let destinationURL = feedback.updatedURL {
                    if action == .moveTo {
                        try await provider.didMoveItem(
                            from: item.url,
                            to: destinationURL
                        )
                    } else if action == .copyTo {
                        try await provider.didCopyItem(to: destinationURL)
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.finishAction(action, item: item, feedback: feedback)
            } catch SearchPanelActionError.destinationCancelled {
                guard !Task.isCancelled, let self else { return }
                self.finishActionWithCancellation()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.finishActionWithError(error)
            }
        }
    }

    func dismiss() {
        onRequestClose?()
    }

    private func finishAction(
        _ action: SearchPanelFileAction,
        item: SearchPanelItem,
        feedback: SearchPanelActionFeedback
    ) {
        isPerformingAction = false
        actionTask = nil
        feedbackMessage = feedback.message
        if action == .moveTo {
            results.removeAll { $0.id == item.id }
            selectedItemID = results.first?.id
            scheduleSearch(immediately: true)
        } else if action == .copyTo {
            scheduleSearch(immediately: true)
        }
        if action == .open {
            if item.category == .applications {
                applicationUsageTracker.recordOpen(for: item.url)
            }
            onRequestClose?()
        }
    }

    private func finishActionWithCancellation() {
        isPerformingAction = false
        actionTask = nil
        feedbackMessage = L10n.tr("已取消")
    }

    private func finishActionWithError(_ error: Error) {
        isPerformingAction = false
        actionTask = nil
        errorMessage = error.localizedDescription
    }

    private func scheduleSearch(
        immediately: Bool = false,
        allowWhileInactive: Bool = false
    ) {
        guard isPanelActive || allowWhileInactive else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let requestedQuery = query
        let requestedCategory = selectedCategory
        let requestedIncludesHidden = includesHiddenFiles
        isSearching = true
        errorMessage = nil
        let provider = provider
        searchTask = Task { @MainActor [weak self, provider] in
            do {
                if !immediately {
                    try await Task.sleep(nanoseconds: 160_000_000)
                }
                try Task.checkCancellation()
                let updates = provider.search(
                    query: requestedQuery,
                    category: requestedCategory,
                    includeHidden: requestedIncludesHidden
                )
                for try await response in updates {
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.applySearchUpdate(
                        response.items,
                        query: requestedQuery,
                        category: requestedCategory,
                        includeHidden: requestedIncludesHidden,
                        generation: generation
                    )
                    self.indexStatusMessage = response.statusMessage
                }
                guard !Task.isCancelled, let self else { return }
                self.finishSearch(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.finishSearchWithError(error, generation: generation)
            }
        }
    }

    private func applySearchUpdate(
        _ response: [SearchPanelItem],
        query: String,
        category: SearchPanelCategory,
        includeHidden: Bool,
        generation: Int
    ) {
        guard generation == searchGeneration,
              query == self.query,
              category == selectedCategory,
              includeHidden == includesHiddenFiles else { return }
        let isFirstUpdateForQuery = lastAppliedSearchGeneration != generation
        let previousSelectedURL = selectedItem?.url
        results = response
        if isFirstUpdateForQuery {
            lastAppliedSearchGeneration = generation
            selectedItemID = orderedResults.first?.id
        } else if let selectedItemID,
           response.contains(where: { $0.id == selectedItemID }) {
            if previousSelectedURL != selectedItem?.url {
                loadPreview()
            }
        } else {
            self.selectedItemID = orderedResults.first?.id
        }
    }

    private func finishSearch(generation: Int) {
        guard generation == searchGeneration else { return }
        isSearching = false
        searchTask = nil
    }

    private func finishSearchWithError(_ error: Error, generation: Int) {
        guard generation == searchGeneration else { return }
        isSearching = false
        searchTask = nil
        results = []
        selectedItemID = nil
        errorMessage = error.localizedDescription
    }

    private func loadPreview() {
        if let previewRequest {
            QLThumbnailGenerator.shared.cancel(previewRequest)
        }
        previewRequest = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewAccess?.stop()
        previewAccess = nil
        previewImage = nil
        previewKind = .loading
        isLoadingMoreTextPreview = false
        previewGeneration &+= 1

        guard isPanelActive,
              SearchPanelPreferences.current().showsPreview,
              let item = selectedItem else { return }
        let generation = previewGeneration
        let selectedID = item.id
        previewTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemID == selectedID else { return }
                self.beginPreviewLoad(
                    for: item,
                    generation: generation,
                    selectedID: selectedID
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func beginPreviewLoad(
        for item: SearchPanelItem,
        generation: Int,
        selectedID: SearchPanelItem.ID
    ) {
        previewTask = nil
        do {
            previewAccess = try FileSearchSecurityScopeResolver.resolve(
                containing: item.url
            )
        } catch {
            previewImage = nil
            previewKind = .unavailable(error.localizedDescription)
            return
        }

        if item.category == .applications {
            previewImage = nil
            if Self.isSystemSettingsApplication(item) {
                previewKind = .systemSettings(Self.systemSettingsCatalog())
            } else {
                previewKind = .application
            }
            finishPreviewAccess()
            return
        }

        if item.isDirectory {
            let includeHidden = includesHiddenFiles
            let url = item.url
            previewTask = Task { @MainActor [weak self] in
                let entries = await Task.detached(priority: .userInitiated) {
                    Self.folderEntries(at: url, includeHidden: includeHidden)
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.previewGeneration == generation,
                      self.selectedItemID == selectedID else { return }
                self.previewKind = .folder(entries)
                self.previewTask = nil
                self.finishPreviewAccess()
            }
            return
        }

        let url = item.url
        previewTask = Task { @MainActor [weak self] in
            let textPreview = await Task.detached(priority: .userInitiated) {
                SearchPanelTextPreviewLoader.load(at: url)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.previewGeneration == generation,
                  self.selectedItemID == selectedID else { return }
            self.previewTask = nil
            if let textPreview {
                self.previewKind = .text(textPreview)
                self.finishPreviewAccess()
            } else {
                self.loadQuickLookPreview(
                    for: item,
                    generation: generation,
                    selectedID: selectedID
                )
            }
        }
    }

    private func loadQuickLookPreview(
        for item: SearchPanelItem,
        generation: Int,
        selectedID: SearchPanelItem.ID
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 520, height: 340),
            scale: scale,
            representationTypes: .all
        )
        previewRequest = request
        previewTimeoutTask?.cancel()
        previewTimeoutTask = Task { @MainActor [weak self, request] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try Task.checkCancellation()
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemID == selectedID,
                      self.previewRequest === request else { return }
                QLThumbnailGenerator.shared.cancel(request)
                self.previewRequest = nil
                self.previewTimeoutTask = nil
                self.previewImage = nil
                self.previewKind = .unavailable(
                    L10n.tr("文件预览生成超时")
                )
                self.finishPreviewAccess()
            } catch {
                return
            }
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            let image = thumbnail?.cgImage
            Task { @MainActor [weak self, image] in
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedItemID == selectedID,
                      self.previewRequest === request else { return }
                defer {
                    self.previewTimeoutTask?.cancel()
                    self.previewTimeoutTask = nil
                    self.previewRequest = nil
                    self.finishPreviewAccess()
                }
                self.previewImage = image.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                self.previewKind = image == nil
                    ? .unavailable(L10n.tr("没有可用的文件预览"))
                    : .image
            }
        }
    }

    private func finishPreviewAccess() {
        previewAccess?.stop()
        previewAccess = nil
    }

    private func refreshActionCapabilities() {
        capabilityTask?.cancel()
        capabilityTask = nil
        guard isPanelActive, let item = selectedItem else {
            actionCapabilities.removeAll()
            return
        }
        actionCapabilities.removeAll()
        let handler = actionHandler
        let selectedID = item.id
        capabilityTask = Task { @MainActor [weak self, handler] in
            do {
                // Rapid keyboard navigation should never resolve bookmarks
                // for every transient selection.
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                let capabilities = await handler.capabilities(for: item)
                guard !Task.isCancelled,
                      let self,
                      self.selectedItemID == selectedID else { return }
                self.actionCapabilities = capabilities
                self.capabilityTask = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private nonisolated static func folderEntries(
        at url: URL,
        includeHidden: Bool
    ) -> [SearchPanelFolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
        return urls.compactMap { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            guard includeHidden || values?.isHidden != true else { return nil }
            return SearchPanelFolderEntry(
                url: child,
                displayName: values?.name ?? child.lastPathComponent,
                isDirectory: values?.isDirectory == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayName.localizedStandardCompare(rhs.displayName)
                == .orderedAscending
        }
        .prefix(80)
        .map { $0 }
    }

    private static func isSystemSettingsApplication(_ item: SearchPanelItem) -> Bool {
        item.applicationBundleIdentifier == "com.apple.systempreferences"
            || item.url.lastPathComponent == "System Settings.app"
            || item.url.lastPathComponent == "System Preferences.app"
    }

    private static func isBrowserApplication(_ item: SearchPanelItem) -> Bool {
        let identifiers: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ]
        if let identifier = item.applicationBundleIdentifier,
           identifiers.contains(identifier) {
            return true
        }
        let name = item.displayName.lowercased()
        return ["safari", "chrome", "firefox", "edge", "brave"]
            .contains { name.contains($0) }
    }

    private static func systemSettingsCatalog() -> [SearchPanelSystemSettingEntry] {
        let definitions: [(String, String, String, String)] = [
            ("privacy", L10n.tr("隐私与安全"), "hand.raised", "x-apple.systempreferences:com.apple.preference.security"),
            ("display", L10n.tr("显示器"), "display", "x-apple.systempreferences:com.apple.preference.displays"),
            ("keyboard", L10n.tr("键盘"), "keyboard", "x-apple.systempreferences:com.apple.preference.keyboard"),
            ("sound", L10n.tr("声音"), "speaker.wave.2", "x-apple.systempreferences:com.apple.preference.sound"),
            ("network", L10n.tr("网络"), "network", "x-apple.systempreferences:com.apple.preference.network"),
            ("general", L10n.tr("通用"), "gearshape", "x-apple.systempreferences:com.apple.preference.general")
        ]
        return definitions.compactMap { id, title, icon, destination in
            guard let url = URL(string: destination) else { return nil }
            return SearchPanelSystemSettingEntry(
                id: id,
                title: title,
                subtitle: L10n.tr("打开对应的系统设置页面"),
                systemImage: icon,
                destination: url
            )
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
