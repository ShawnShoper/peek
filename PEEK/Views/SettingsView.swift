import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case general
        case search
        case shortcuts
        case capture
        case appearance
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L10n.tr("通用")
            case .search: return L10n.tr("搜索")
            case .shortcuts: return L10n.tr("快捷键")
            case .capture: return L10n.tr("截图")
            case .appearance: return L10n.tr("外观")
            case .about: return L10n.tr("关于")
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .search: return "magnifyingglass"
            case .shortcuts: return "keyboard"
            case .capture: return "viewfinder.circle"
            case .appearance: return "paintpalette"
            case .about: return "info.circle"
            }
        }
    }

    private enum SearchPane: String, CaseIterable, Identifiable {
        case documents
        case applications
        case exclusions
        case indexing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .documents: return L10n.tr("文档搜索")
            case .applications: return L10n.tr("应用搜索")
            case .exclusions: return L10n.tr("搜索排除")
            case .indexing: return L10n.tr("索引日志")
            }
        }

        var systemImage: String {
            switch self {
            case .documents: return "folder.fill"
            case .applications: return "app.fill"
            case .exclusions: return "shield.fill"
            case .indexing: return "list.bullet.rectangle.fill"
            }
        }
    }

    private enum ScreenshotReadiness {
        case unavailable
        case restartRequired
        case manualReady
        case automaticReady
        case busy

        var title: String {
            switch self {
            case .unavailable: return L10n.tr("截图不可用")
            case .restartRequired: return L10n.tr("授权已记录，需要重启")
            case .manualReady: return L10n.tr("基础截图已就绪")
            case .automaticReady: return L10n.tr("截图已就绪")
            case .busy: return L10n.tr("截图任务进行中")
            }
        }

        var message: String {
            switch self {
            case .unavailable:
                return L10n.tr("请先允许屏幕录制；授权后需要完全退出并重新打开 PEEK。")
            case .restartRequired:
                return L10n.tr("完全退出并重新打开后，macOS 才会应用新的屏幕录制权限。")
            case .manualReady:
                return L10n.tr("区域截图、标注、OCR 和手动滚动可用；自动滚动仍需辅助功能权限。")
            case .automaticReady:
                return L10n.tr("区域截图、滚动截图、标注、钉图与本地 OCR 均可使用。")
            case .busy:
                return L10n.tr("当前正在选区、编辑或拼接；按 Esc 可取消选区。")
            }
        }

        var systemImage: String {
            switch self {
            case .unavailable: return "exclamationmark.shield.fill"
            case .restartRequired: return "arrow.clockwise.circle.fill"
            case .manualReady: return "checkmark.circle"
            case .automaticReady: return "checkmark.circle.fill"
            case .busy: return "viewfinder.circle"
            }
        }

        var color: Color {
            switch self {
            case .unavailable: return .orange
            case .restartRequired, .manualReady: return .blue
            case .automaticReady: return .green
            case .busy: return .accentColor
            }
        }
    }

    private enum DocumentDirectoryPermission: Equatable {
        case authorized
        case included
        case pending
        case reauthorizationRequired

        var title: String {
            switch self {
            case .authorized: return L10n.tr("已授权")
            case .included: return L10n.tr("已包含")
            case .pending: return L10n.tr("待授权")
            case .reauthorizationRequired: return L10n.tr("需重新授权")
            }
        }

        var systemImage: String {
            switch self {
            case .authorized, .included: return "checkmark.circle.fill"
            case .pending: return "minus.circle.fill"
            case .reauthorizationRequired: return "arrow.clockwise.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .authorized, .included: return .green
            case .pending: return .yellow
            case .reauthorizationRequired: return .orange
            }
        }
    }

    private enum DocumentDirectoryIndexState: Equatable {
        case completed(Int)
        case updating
        case coveredByParent
        case waiting
        case notIndexed

        var title: String {
            switch self {
            case .completed: return L10n.tr("已完成")
            case .updating: return L10n.tr("更新中")
            case .coveredByParent: return L10n.tr("随上级目录")
            case .waiting: return L10n.tr("等待更新")
            case .notIndexed: return L10n.tr("未索引")
            }
        }

        var color: Color {
            switch self {
            case .completed: return .green
            case .updating: return .blue
            case .coveredByParent: return .secondary
            case .waiting: return .orange
            case .notIndexed: return .secondary
            }
        }
    }

    private struct DocumentDirectoryPresentation: Identifiable {
        let id: String
        let title: String
        let displayPath: String
        let url: URL
        let defaultRoot: FileSearchDocumentDefaultRoot?
        let exactAuthorizedRoot: FileSearchAuthorizedRoot?
        let coveringAuthorizedRoot: FileSearchAuthorizedRoot?
        let permission: DocumentDirectoryPermission
        let indexState: DocumentDirectoryIndexState
    }

    @EnvironmentObject private var screenshotService: ScreenshotService
    @ObservedObject private var hotKeyManager = ScreenshotGlobalHotKeyManager.shared
    @ObservedObject private var authorizedRootStore = FileSearchAuthorizedRootStore.shared
    @ObservedObject private var documentDefaultRootStore = FileSearchDocumentDefaultRootStore.shared
    @ObservedObject private var applicationRootStore = FileSearchApplicationRootStore.shared
    @ObservedObject private var exclusionSettings = FileSearchExclusionSettings.shared

    @AppStorage("screenshot.scrollAutomatic") private var automaticScrolling = true
    @AppStorage("screenshot.scrollAutoDetectTarget") private var autoDetectScrollTarget = true
    @AppStorage("screenshot.scrollAmount") private var automaticScrollAmount = 700
    @AppStorage("screenshot.scrollMaxFrames") private var scrollMaximumFrames = 30
    @AppStorage(PEEKPreferenceKey.searchDefaultCategory)
    private var defaultSearchCategoryRaw = SearchPanelCategory.all.rawValue
    @AppStorage(PEEKPreferenceKey.searchIncludeHidden)
    private var includesHiddenFilesByDefault = false
    @AppStorage(PEEKPreferenceKey.searchResultLimit)
    private var searchResultLimit = 80
    @AppStorage(PEEKPreferenceKey.searchRetainsLastQuery)
    private var retainsLastSearchQuery = false
    @AppStorage(PEEKPreferenceKey.searchWindowScreen)
    private var searchWindowScreenRaw = SearchWindowScreenPreference.mouse.rawValue
    @AppStorage(PEEKPreferenceKey.searchWindowPosition)
    private var searchWindowPositionRaw = SearchWindowPositionPreference.centered.rawValue
    @AppStorage(PEEKPreferenceKey.searchWindowOpacity)
    private var searchWindowOpacity = 0.92
    @AppStorage(PEEKPreferenceKey.searchShowsPreview)
    private var searchShowsPreview = true
    @AppStorage(PEEKPreferenceKey.searchResultDensity)
    private var searchResultDensityRaw = SearchResultDensity.standard.rawValue
    @AppStorage(PEEKPreferenceKey.appearanceMode)
    private var appearanceModeRaw = PEEKAppearanceMode.system.rawValue
    @AppStorage(PEEKPreferenceKey.appLanguage)
    private var appLanguageRaw = PEEKAppLanguage.system.rawValue

    @State private var selectedPane = Pane.general
    @State private var selectedSearchPane = SearchPane.documents
    @State private var screenRecordingGranted = ScreenRecordingPermission.isGranted
    @State private var accessibilityGranted = AccessibilityScrollPermission.isGranted
    @State private var screenRecordingRestartRequired = false
    @State private var permissionMessage: String?
    @State private var hotKeyMessage: String?
    @State private var fileIndexMessage: String?
    @State private var initialIndexProgress: FileSearchInitialIndexProgressSnapshot?
    @State private var indexMetadata: FileSearchIndexMetadata?
    @State private var rootIndexStatuses: [String: FileSearchRootIndexStatus] = [:]
    @State private var selectedDocumentDirectoryID: String?
    @State private var indexDatabaseSize: Int64?
    @State private var queuedRootRefreshPaths: Set<String> = []
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginMessage: String?
    @State private var showResetConfirmation = false
    @State private var showLanguageRestartPrompt = false

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPage
                .tabItem { Label(Pane.general.title, systemImage: Pane.general.systemImage) }
                .tag(Pane.general)

            searchPage
                .tabItem { Label(Pane.search.title, systemImage: Pane.search.systemImage) }
                .tag(Pane.search)

            shortcutsPage
                .tabItem { Label(Pane.shortcuts.title, systemImage: Pane.shortcuts.systemImage) }
                .tag(Pane.shortcuts)

            capturePage
                .tabItem { Label(Pane.capture.title, systemImage: Pane.capture.systemImage) }
                .tag(Pane.capture)

            appearancePage
                .tabItem { Label(Pane.appearance.title, systemImage: Pane.appearance.systemImage) }
                .tag(Pane.appearance)

            aboutPage
                .tabItem { Label(Pane.about.title, systemImage: Pane.about.systemImage) }
                .tag(Pane.about)
        }
        .onChange(of: appearanceModeRaw) { rawValue in
            PEEKAppearanceController.apply(
                PEEKAppearanceMode(rawValue: rawValue) ?? .system
            )
        }
        .task {
            applyPendingSettingsRoute()
            refreshPermissionState()
            refreshLaunchAtLoginState()
            authorizedRootStore.refresh()
            applicationRootStore.refresh()
            while !Task.isCancelled {
                await refreshIndexStatus()
                try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .peekOpenDocumentSearchSettings)
        ) { _ in
            showDocumentSearchSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState()
            refreshLaunchAtLoginState()
            authorizedRootStore.refresh()
            applicationRootStore.refresh()
        }
        .onChange(of: retainsLastSearchQuery) { isEnabled in
            if !isEnabled {
                UserDefaults.standard.removeObject(forKey: PEEKPreferenceKey.searchLastQuery)
            }
        }
        .confirmationDialog(
            L10n.tr("恢复设置默认值？"),
            isPresented: $showResetConfirmation
        ) {
            Button(L10n.tr("恢复默认"), role: .destructive) { restorePreferenceDefaults() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("将恢复通用、搜索、外观、截图和快捷键设置，不会删除授权目录或现有索引。"))
        }
        .alert(L10n.tr("需要重新启动 PEEK"), isPresented: $showLanguageRestartPrompt) {
            Button(L10n.tr("稍后"), role: .cancel) {}
            Button(L10n.tr("退出 PEEK")) { NSApp.terminate(nil) }
        } message: {
            Text(L10n.tr("语言已保存。完全退出并重新打开 PEEK 后，菜单栏、搜索、截图与设置界面会统一使用新语言。"))
        }
    }

    private var generalPage: some View {
        settingsPage(
            title: L10n.tr("通用设置"),
            subtitle: L10n.tr("启动方式、菜单栏与查找窗口行为"),
            systemImage: "gearshape.fill"
        ) {
            settingsSection(L10n.tr("启动")) {
                settingsControlRow(L10n.tr("登录时打开 PEEK")) {
                    Toggle(L10n.tr("登录时打开 PEEK"), isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { enabled in updateLaunchAtLogin(enabled) }
                    ))
                    .labelsHidden()
                }
                Label(L10n.tr("应用启动后只显示菜单栏图标，不自动打开普通窗口。"), systemImage: "menubar.rectangle")
                if let launchAtLoginMessage {
                    Label(launchAtLoginMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(L10n.tr("查找窗口")) {
                settingsControlRow(L10n.tr("窗口出现屏幕")) {
                    Picker(L10n.tr("窗口出现屏幕"), selection: $searchWindowScreenRaw) {
                        ForEach(SearchWindowScreenPreference.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
                settingsControlRow(L10n.tr("默认窗口位置")) {
                    Picker(L10n.tr("默认窗口位置"), selection: $searchWindowPositionRaw) {
                        ForEach(SearchWindowPositionPreference.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
                Text(L10n.tr("“始终居中”会按所选屏幕重新定位；“记住上次位置”会恢复用户上次调整后的窗口。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            settingsSection(L10n.tr("语言与数据")) {
                settingsControlRow(L10n.tr("应用语言")) {
                    Picker(L10n.tr("应用语言"), selection: $appLanguageRaw) {
                        ForEach(PEEKAppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                    .onChange(of: appLanguageRaw) { rawValue in
                        let language = PEEKAppLanguage(rawValue: rawValue) ?? .system
                        language.apply()
                        showLanguageRestartPrompt = true
                    }
                }
                Text(L10n.tr("支持跟随系统、简体中文和 English；切换后需重新启动 PEEK，以保证所有窗口和系统菜单使用同一语言。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                settingsActionRow(L10n.tr("恢复通用、搜索、外观、截图与快捷键设置")) {
                    Button(L10n.tr("恢复设置默认值…")) { showResetConfirmation = true }
                }
            }
        }
    }

    private var searchPage: some View {
        HSplitView {
            VStack(spacing: 0) {
                List {
                    Section(L10n.tr("搜索设置")) {
                        searchSidebarRow(.documents)
                        searchSidebarRow(.applications)
                        searchSidebarRow(.indexing)
                    }
                    Section(L10n.tr("隐私设置")) {
                        searchSidebarRow(.exclusions)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()
                searchConnectionFooter
            }
            .frame(minWidth: 240, idealWidth: 250, maxWidth: 270)

            Group {
                switch selectedSearchPane {
                case .documents: documentSearchPane
                case .applications: applicationSearchPane
                case .exclusions: exclusionSearchPane
                case .indexing: indexLogSearchPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func searchSidebarRow(_ pane: SearchPane) -> some View {
        Button {
            selectedSearchPane = pane
        } label: {
            HStack {
                Label(pane.title, systemImage: pane.systemImage)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selectedSearchPane == pane ? Color.accentColor : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedSearchPane == pane ? Color.white : Color.primary)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private var searchConnectionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indexConnectionColor)
                    .frame(width: 9, height: 9)
                Text(indexProgressStatusText)
                    .font(.caption)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let percentage = indexProgressPercentageText {
                    Text(percentage)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if isIndexUpdating {
                indexProgressBar
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var documentSearchPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("文档搜索范围"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.tr("管理用于本地索引的文件夹"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    chooseIndexFolders()
                } label: {
                    Label(L10n.tr("添加文件夹"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.tr("恢复默认")) {
                    documentDefaultRootStore.restoreDefaults()
                    fileIndexMessage = L10n.tr("已恢复文稿、桌面和下载")
                    selectFirstDocumentDirectoryIfNeeded()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                documentDirectoryTableHeader
                Divider()
                if documentDirectoryPresentations.isEmpty {
                    searchEmptyState(
                        icon: "folder.badge.plus",
                        title: L10n.tr("还没有文档目录"),
                        message: L10n.tr("点击“添加目录”，或使用“恢复默认”。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(documentDirectoryPresentations) { directory in
                                documentDirectoryTableRow(directory)
                                Divider()
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Text(documentDirectorySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isIndexUpdating {
                        Text(indexProgressStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            searchPaneFooter(L10n.tr("所有设置实时保存"))
        }
    }

    private var applicationSearchPane: some View {
        VStack(spacing: 0) {
            searchPaneHeader(title: L10n.tr("应用搜索范围")) {
                Button {
                    chooseApplicationFolder()
                } label: {
                    Label(L10n.tr("添加文件夹"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.tr("恢复默认")) {
                    applicationRootStore.restoreDefaults()
                    fileIndexMessage = L10n.tr("已恢复默认应用目录")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if applicationRootStore.roots.isEmpty {
                        searchEmptyState(
                            icon: "app.badge",
                            title: L10n.tr("应用搜索已关闭"),
                            message: L10n.tr("点击恢复默认，或用＋添加应用目录。")
                        )
                    } else {
                        ForEach(Array(applicationRootStore.roots.enumerated()), id: \.element.id) { index, root in
                            applicationRootRow(root, index: index)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            searchPaneFooter(
                applicationRootStore.roots.isEmpty
                    ? L10n.tr("当前不会返回应用程序结果。")
                    : L10n.tr("目录中只索引 .app，不索引普通系统文件。")
            )
        }
    }

    private var exclusionSearchPane: some View {
        VStack(spacing: 0) {
            searchPaneHeader(title: L10n.tr("搜索排除")) {
                Button {
                    chooseExclusionPath()
                } label: {
                    Label(L10n.tr("添加排除项"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help(L10n.tr("添加不搜索的文件或文件夹"))
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if exclusionSettings.policy.paths.isEmpty {
                        searchEmptyState(
                            icon: "shield",
                            title: L10n.tr("没有搜索排除项"),
                            message: L10n.tr("只有你主动添加的内容才会显示在这里。")
                        )
                    } else {
                        ForEach(Array(exclusionSettings.policy.paths.enumerated()), id: \.element) { index, path in
                            searchPathRow(
                                path: displayPath(path),
                                status: nil,
                                alternate: !index.isMultiple(of: 2),
                                deleteLabel: L10n.tr("移除排除项")
                            ) {
                                exclusionSettings.removePath(path)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            searchPaneFooter(
                exclusionSettings.policy.paths.isEmpty
                    ? L10n.tr("初始为空；PEEK 不替你添加排除目录。")
                    : L10n.tr("排除项将在下一次后台索引维护时生效。")
            )
        }
    }

    private var indexLogSearchPane: some View {
        VStack(spacing: 0) {
            searchPaneHeader(title: L10n.tr("索引日志")) {
                if isIndexUpdating {
                    Label(L10n.tr("正在更新"), systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                } else {
                    Label(indexConnectionText, systemImage: indexPhaseIcon)
                        .foregroundStyle(indexConnectionColor)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(indexConnectionColor)
                        .frame(width: 9, height: 9)
                    Text(indexProgressStatusText)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 12)
                    if let percentage = indexProgressPercentageText {
                        Text(percentage)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if isIndexUpdating {
                    indexProgressBar
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label(L10n.tr("实时索引记录"), systemImage: "terminal")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(L10n.tr("每秒刷新"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(indexLogLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)

            searchPaneFooter(L10n.tr("查询不会触发索引；这里只显示后台任务的实时状态。"))
        }
    }

    private var shortcutsPage: some View {
        settingsPage(
            title: L10n.tr("全局快捷键"),
            subtitle: L10n.tr("统一管理文件查找和截图快捷键"),
            systemImage: "keyboard.fill"
        ) {
            settingsSection {
                settingsActionRow(L10n.tr("点击组合后直接按下新快捷键；Delete 停用，Esc 取消。")) {
                    Button(L10n.tr("恢复默认")) { restoreDefaultHotKeys() }
                }
            }

            settingsSection(L10n.tr("快捷键")) {
                ForEach(ScreenshotGlobalHotKeyAction.allCases) { action in
                    hotKeyRow(action)
                }
            }

            settingsSection(L10n.tr("冲突检查")) {
                if let hotKeyMessage {
                    Label(hotKeyMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if let status = hotKeyManager.systemConflictCheckStatus {
                    Label(
                        L10n.tr(
                            "macOS 系统快捷键列表读取失败（OSStatus %d）；部分系统或第三方冲突可能无法识别。",
                            status
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Text(L10n.tr("保存前会检查 PEEK 内部重复、菜单占用、可读取的 macOS 系统快捷键和 Carbon 独占冲突。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var capturePage: some View {
        settingsPage(
            title: L10n.tr("截图与 OCR"),
            subtitle: L10n.tr("权限、剪贴板输出与滚动截图"),
            systemImage: "viewfinder.circle.fill"
        ) {
            settingsSection { readinessBanner }

            settingsSection(L10n.tr("系统权限")) {
                permissionRow(
                    title: L10n.tr("屏幕录制"),
                    detail: L10n.tr("区域截图、滚动截图和 OCR 截图的必需权限"),
                    isGranted: screenRecordingGranted,
                    buttonTitle: L10n.tr("打开屏幕录制设置"),
                    action: screenshotService.openScreenRecordingSettings
                )
                permissionRow(
                    title: L10n.tr("自动滚动控制"),
                    detail: L10n.tr("允许向确认的目标窗口发送滚轮事件"),
                    isGranted: accessibilityGranted,
                    buttonTitle: L10n.tr("打开辅助功能设置"),
                    action: screenshotService.openAccessibilitySettings
                )
                settingsActionRow(L10n.tr("重新读取 macOS 当前授权状态")) {
                    Button(L10n.tr("重新检查")) {
                        refreshPermissionState()
                        permissionMessage = L10n.tr("权限状态已刷新")
                    }
                    if screenRecordingRestartRequired {
                        Button(L10n.tr("退出 PEEK")) { NSApp.terminate(nil) }
                    }
                }
                if let permissionMessage {
                    Label(permissionMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            settingsSection(L10n.tr("输出")) {
                Label(L10n.tr("双击选区、按 Enter 或点击完成后直接写入系统剪贴板。"), systemImage: "doc.on.clipboard")
                Label(L10n.tr("默认不创建历史文件；只有工具栏“保存”才写入磁盘。"), systemImage: "square.and.arrow.down")
            }

            settingsSection(L10n.tr("滚动截图")) {
                settingsControlRow(L10n.tr("自动识别当前窗口的滚动区")) {
                    Toggle(L10n.tr("自动识别当前窗口的滚动区"), isOn: $autoDetectScrollTarget)
                        .labelsHidden()
                }
                Text(autoDetectScrollTarget
                    ? L10n.tr("鼠标位于可信滚动容器时预选该区域，其他位置预选整窗；手工调整后以用户选区为准。")
                    : L10n.tr("关闭后每次从自由选区开始。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                settingsControlRow(L10n.tr("采集模式")) {
                    Picker(L10n.tr("采集模式"), selection: $automaticScrolling) {
                        Text(L10n.tr("自动滚动")).tag(true)
                        Text(L10n.tr("手动滚动")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260, alignment: .trailing)
                }
                if automaticScrolling {
                    if !accessibilityGranted {
                        Label(L10n.tr("自动滚动尚未就绪，请授权或切换手动模式。"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    settingsControlRow(L10n.tr("单次滚动上限")) {
                        HStack(spacing: 10) {
                            Text(L10n.tr("%d 像素", automaticScrollAmount))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper(
                                L10n.tr("单次滚动上限"),
                                value: $automaticScrollAmount,
                                in: 200 ... 1_600,
                                step: 100
                            )
                            .labelsHidden()
                        }
                    }
                    Text(L10n.tr("实际步长按选区高度 35% 计算，并受该像素上限约束；任何情况下不超过选区高度 45%。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("手动模式定时采集选区；滚动完成后点击浮层中的“停止并拼接”。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                settingsControlRow(L10n.tr("最多采集帧数")) {
                    HStack(spacing: 10) {
                        Text(L10n.tr("%d 帧", scrollMaximumFrames))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper(
                            L10n.tr("最多采集帧数"),
                            value: $scrollMaximumFrames,
                            in: 2 ... 100
                        )
                        .labelsHidden()
                    }
                }
            }

            settingsSection(L10n.tr("OCR 与隐私")) {
                settingsControlRow(L10n.tr("识别语言")) {
                    Text(L10n.tr("自动识别中文与英文"))
                        .foregroundStyle(.secondary)
                }
                Label(L10n.tr("OCR 使用 macOS Vision 在本机处理，不上传图片或识别结果。"), systemImage: "lock.shield")
                Text(L10n.tr("受保护窗口和 DRM 内容由系统禁止捕获；PEEK 不会尝试绕过。"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearancePage: some View {
        settingsPage(
            title: L10n.tr("外观"),
            subtitle: L10n.tr("调整查找窗口的主题、密度与预览布局"),
            systemImage: "paintpalette.fill"
        ) {
            settingsSection(L10n.tr("主题")) {
                settingsControlRow(L10n.tr("界面主题")) {
                    Picker(L10n.tr("界面主题"), selection: $appearanceModeRaw) {
                        ForEach(PEEKAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260, alignment: .trailing)
                }
            }

            settingsSection(L10n.tr("搜索结果")) {
                settingsControlRow(L10n.tr("结果密度")) {
                    Picker(L10n.tr("结果密度"), selection: $searchResultDensityRaw) {
                        ForEach(SearchResultDensity.allCases) { density in
                            Text(density.title).tag(density.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260, alignment: .trailing)
                }
                settingsControlRow(L10n.tr("显示右侧文件预览")) {
                    Toggle(L10n.tr("显示右侧文件预览"), isOn: $searchShowsPreview)
                        .labelsHidden()
                }
                Text(L10n.tr("关闭预览后，结果列表会使用全部窗口宽度，并停止生成 Quick Look 缩略图。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            settingsSection(L10n.tr("查找窗口")) {
                settingsControlRow(
                    L10n.tr("窗口透明度"),
                    detail: L10n.tr("仅影响浮动搜索窗口，文字与预览仍保持可读")
                ) {
                    HStack(spacing: 12) {
                        Slider(value: $searchWindowOpacity, in: 0.6 ... 1, step: 0.05)
                        Text("\(Int((searchWindowOpacity * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            settingsSection(L10n.tr("可读性")) {
                Label(L10n.tr("使用系统字体、系统强调色和原生控件，以适配深浅色及辅助功能设置。"), systemImage: "textformat.size")
            }
        }
    }

    private var aboutPage: some View {
        settingsPage(
            title: L10n.tr("关于 PEEK"),
            subtitle: L10n.tr("本地优先的 macOS 文件查找与截图工具"),
            systemImage: "info.circle.fill"
        ) {
            settingsSection {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PEEK")
                            .font(.title2.weight(.semibold))
                        Text(versionLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            settingsSection(L10n.tr("产品边界")) {
                Label(L10n.tr("文件索引、拼音匹配、截图和 OCR 全部在本机执行。"), systemImage: "internaldrive")
                Label(L10n.tr("应用只访问系统开放位置和用户明确授权的目录。"), systemImage: "lock.shield")
                Label(L10n.tr("正常启动只显示菜单栏图标，不打开普通主窗口。"), systemImage: "menubar.rectangle")
            }

            settingsSection(L10n.tr("诊断")) {
                settingsActionRow(L10n.tr("不包含文件内容、截图或搜索词")) {
                    Button(L10n.tr("复制版本与索引信息")) { copyDiagnostics() }
                }
            }
        }
    }

    private func settingsPage<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            pageHeader(title: title, subtitle: subtitle, systemImage: systemImage)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingsSection<Content: View>(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 15) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsControlRow<Control: View>(
        _ title: String,
        detail: String? = nil,
        controlWidth: CGFloat = 260,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            control()
                .frame(width: controlWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsActionRow<Actions: View>(
        _ detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            actions()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageHeader(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var versionLabel: String {
        let dictionary = Bundle.main.infoDictionary
        let version = dictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = dictionary?["CFBundleVersion"] as? String ?? "-"
        return L10n.tr("版本 %@（%@）", version, build)
    }

    private var screenshotReadiness: ScreenshotReadiness {
        if screenshotService.isCapturing
            || screenshotService.isScrolling
            || screenshotService.isRecognizingText {
            return .busy
        }
        if screenRecordingRestartRequired { return .restartRequired }
        guard screenRecordingGranted else { return .unavailable }
        return automaticScrolling && !accessibilityGranted ? .manualReady : .automaticReady
    }

    private var readinessBanner: some View {
        let readiness = screenshotReadiness
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: readiness.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(readiness.color)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(readiness.title).font(.title3.weight(.semibold))
                Text(readiness.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if screenRecordingRestartRequired {
                Button(L10n.tr("退出 PEEK")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            } else if screenRecordingGranted {
                Button(L10n.tr("测试区域截图")) {
                    Task { await screenshotService.captureRegion() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(screenshotService.isCapturing)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button(L10n.tr("请求权限")) { requestScreenRecordingPermission() }
                        .buttonStyle(.borderedProminent)
                    Button(L10n.tr("打开系统设置")) { screenshotService.openScreenRecordingSettings() }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(isGranted ? L10n.tr("已授权") : L10n.tr("未授权"))
                .font(.caption.weight(.medium))
                .foregroundStyle(isGranted ? .green : .orange)
            if !isGranted { Button(buttonTitle, action: action) }
        }
    }

    private func hotKeyRow(_ action: ScreenshotGlobalHotKeyAction) -> some View {
        let state = hotKeyManager.registrationStates[action]
        let shortcut = hotKeyManager.shortcut(for: action)
        return HStack(spacing: 12) {
            Image(systemName: hotKeyIcon(for: action))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(action.displayName)
            Spacer()
            HotKeyRecorderView(shortcut: shortcut) { updateHotKey($0, for: action) }
                .frame(width: 112, height: 28)
            hotKeyStatus(shortcut: shortcut, state: state)
                .font(.caption)
                .frame(minWidth: 100, idealWidth: 150, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func hotKeyStatus(
        shortcut: ScreenshotHotKey?,
        state: ScreenshotHotKeyRegistrationState?
    ) -> some View {
        if shortcut == nil {
            Label(L10n.tr("已停用"), systemImage: "minus.circle").foregroundStyle(.secondary)
        } else if let state {
            switch state {
            case .success:
                Label(L10n.tr("已启用"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .systemConflict:
                Label(state.localizedDescription, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .failure(let status):
                Label(
                    ScreenshotHotKeyRegistrationState.failure(status).localizedDescription,
                    systemImage: "exclamationmark.circle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("检测中")).foregroundStyle(.secondary)
            }
        }
    }

    private func searchPaneHeader<Actions: View>(
        title: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.medium))
            Spacer()
            actions()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func searchPaneFooter(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let fileIndexMessage {
                    Text(fileIndexMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func searchEmptyState(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal, 30)
    }

    private var additionalDocumentRoots: [FileSearchAuthorizedRoot] {
        authorizedRootStore.roots.filter { authorized in
            !documentDefaultRootStore.roots.contains { defaultRoot in
                FileSearchDocumentRootAuthorization.exactRoot(
                    for: defaultRoot,
                    in: [authorized]
                ) != nil
            }
        }
    }

    private var documentDirectoryPresentations: [DocumentDirectoryPresentation] {
        let defaultRows = documentDefaultRootStore.roots.map { root in
            let exact = FileSearchDocumentRootAuthorization.exactRoot(
                for: root,
                in: authorizedRootStore.roots
            )
            let covering = FileSearchDocumentRootAuthorization.coveringAuthorizedRoot(
                for: root,
                in: authorizedRootStore.roots
            )
            let permission: DocumentDirectoryPermission
            if exact?.status.isAuthorized == true {
                permission = .authorized
            } else if covering != nil {
                permission = .included
            } else if exact == nil {
                permission = .pending
            } else {
                permission = .reauthorizationRequired
            }
            return DocumentDirectoryPresentation(
                id: "default:\(root.path)",
                title: root.title,
                displayPath: root.displayPath,
                url: root.url,
                defaultRoot: root,
                exactAuthorizedRoot: exact,
                coveringAuthorizedRoot: covering,
                permission: permission,
                indexState: permission == .included
                    ? .coveredByParent
                    : documentIndexState(for: exact)
            )
        }

        let customRows = additionalDocumentRoots.map { root in
            DocumentDirectoryPresentation(
                id: "authorized:\(root.id.uuidString)",
                title: root.displayName,
                displayPath: displayPath(root.lastKnownPath),
                url: root.url ?? URL(fileURLWithPath: root.lastKnownPath, isDirectory: true),
                defaultRoot: nil,
                exactAuthorizedRoot: root,
                coveringAuthorizedRoot: root.status.isAuthorized ? root : nil,
                permission: root.status.isAuthorized ? .authorized : .reauthorizationRequired,
                indexState: documentIndexState(for: root.status.isAuthorized ? root : nil)
            )
        }
        return defaultRows + customRows
    }

    private func documentIndexState(
        for root: FileSearchAuthorizedRoot?
    ) -> DocumentDirectoryIndexState {
        guard let root, root.status.isAuthorized else { return .notIndexed }
        let path = URL(fileURLWithPath: root.lastKnownPath, isDirectory: true)
            .standardizedFileURL.path
        guard let status = rootIndexStatuses[path] else { return .waiting }
        if status.isIndexing { return .updating }
        if status.hasCommittedGeneration {
            return .completed(status.indexedItemCount)
        }
        return .waiting
    }

    private var selectedDocumentDirectory: DocumentDirectoryPresentation? {
        let rows = documentDirectoryPresentations
        guard let selectedDocumentDirectoryID else { return rows.first }
        return rows.first { $0.id == selectedDocumentDirectoryID } ?? rows.first
    }

    private var documentAuthorizedCount: Int {
        documentDirectoryPresentations.filter {
            $0.permission == .authorized || $0.permission == .included
        }.count
    }

    private var documentDirectorySummary: String {
        L10n.tr(
            "%d 个目录 · %d 个已授权或已包含",
            documentDirectoryPresentations.count,
            documentAuthorizedCount
        )
    }

    private var documentDirectoryTableHeader: some View {
        HStack(spacing: 16) {
            Text(L10n.tr("文件夹"))
                .frame(width: 170, alignment: .leading)
            Text(L10n.tr("路径"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.tr("状态"))
                .frame(width: 150, alignment: .leading)
            Text(L10n.tr("操作"))
                .frame(width: 150, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func documentDirectoryTableRow(
        _ directory: DocumentDirectoryPresentation
    ) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.cyan)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(directory.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)

            Text(directory.displayPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directory.url.path)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Label(
                    directory.permission.title,
                    systemImage: directory.permission.systemImage
                )
                .foregroundStyle(directory.permission.color)

                if directory.indexState == .updating {
                    HStack(spacing: 7) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(width: 82)
                        Text(L10n.tr("更新中"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(directory.indexState.color)
                            .frame(width: 7, height: 7)
                        Text(directory.indexState.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 8) {
                if directory.permission == .pending
                    || directory.permission == .reauthorizationRequired {
                    Button(directory.permission == .pending ? L10n.tr("授权") : L10n.tr("重新授权")) {
                        authorizeDocumentDirectory(directory)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if shouldShowVisibleRefresh(for: directory),
                   let refreshURL = refreshURL(for: directory) {
                    Button {
                        startRootRefresh(refreshURL, title: directory.title)
                    } label: {
                        Label(
                            isRootRefreshPending(refreshURL)
                                ? L10n.tr("排队中")
                                : L10n.tr("刷新索引"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRootRefreshPending(refreshURL) || directory.indexState == .updating)
                }

                Menu {
                    if let refreshURL = refreshURL(for: directory) {
                        Button(L10n.tr("刷新索引")) {
                            startRootRefresh(refreshURL, title: directory.title)
                        }
                        .disabled(
                            isRootRefreshPending(refreshURL)
                                || directory.indexState == .updating
                        )
                        Divider()
                    }
                    Button(L10n.tr("在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([directory.url])
                    }
                    Divider()
                    Button(L10n.tr("移除目录"), role: .destructive) {
                        removeDocumentDirectory(directory)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L10n.tr("%@ 的更多操作", directory.title))
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 70)
        .accessibilityElement(children: .contain)
    }

    private func documentDirectoryInspector(
        _ directory: DocumentDirectoryPresentation
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: directory.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                Text(directory.title)
                    .font(.title2.weight(.semibold))
                Text(directory.displayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Label(
                    directory.permission.title,
                    systemImage: directory.permission.systemImage
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(directory.permission.color)
            }
            .padding(.top, 30)
            .padding(.horizontal, 18)

            Divider().padding(.vertical, 18)

            VStack(spacing: 12) {
                inspectorValueRow(L10n.tr("索引状态"), value: directory.indexState.title)
                inspectorValueRow(L10n.tr("范围"), value: L10n.tr("包含子文件夹"))
                if case .completed(let itemCount) = directory.indexState {
                    inspectorValueRow(
                        L10n.tr("已索引"),
                        value: L10n.tr("%lld 项", Int64(itemCount))
                    )
                }
            }
            .padding(.horizontal, 18)

            Divider().padding(.vertical, 18)

            VStack(spacing: 10) {
                if directory.permission == .pending
                    || directory.permission == .reauthorizationRequired {
                    Button(
                        directory.permission == .pending ? L10n.tr("授权目录") : L10n.tr("重新授权目录")
                    ) {
                        authorizeDocumentDirectory(directory)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                } else {
                    Button(L10n.tr("在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([directory.url])
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                Button(L10n.tr("移除目录"), role: .destructive) {
                    removeDocumentDirectory(directory)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspectorValueRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }

    private func selectFirstDocumentDirectoryIfNeeded() {
        let rows = documentDirectoryPresentations
        guard !rows.contains(where: { $0.id == selectedDocumentDirectoryID }) else { return }
        selectedDocumentDirectoryID = rows.first?.id
    }

    private func authorizeDocumentDirectory(
        _ directory: DocumentDirectoryPresentation
    ) {
        selectedDocumentDirectoryID = directory.id
        if let exact = directory.exactAuthorizedRoot {
            chooseIndexFolders(replacing: exact, suggestedURL: directory.url)
        } else {
            chooseIndexFolders(suggestedURL: directory.url)
        }
    }

    private func removeDocumentDirectory(
        _ directory: DocumentDirectoryPresentation
    ) {
        if let defaultRoot = directory.defaultRoot {
            documentDefaultRootStore.removeRoot(path: defaultRoot.path)
            if let exact = directory.exactAuthorizedRoot {
                authorizedRootStore.removeRoot(id: exact.id)
            }
            fileIndexMessage = L10n.tr("已移除 %@；可随时恢复默认", directory.title)
        } else if let exact = directory.exactAuthorizedRoot {
            authorizedRootStore.removeRoot(id: exact.id)
            fileIndexMessage = L10n.tr("已移除 %@", directory.title)
        }
        selectFirstDocumentDirectoryIfNeeded()
    }

    private func applicationRootRow(
        _ root: FileSearchApplicationRoot,
        index: Int
    ) -> some View {
        searchPathRow(
            path: root.displayPath,
            status: root.status,
            alternate: !index.isMultiple(of: 2),
            deleteLabel: L10n.tr("移除应用目录"),
            refresh: root.url.map { url in
                { startRootRefresh(url, title: root.displayPath) }
            },
            isRefreshPending: root.url.map(isRootRefreshPending) ?? false,
            reauthorize: root.status.isAuthorized || root.isDefault || root.customRootID == nil
                ? nil
                : { chooseApplicationFolder(replacing: root) }
        ) {
            applicationRootStore.removeRoot(root)
            fileIndexMessage = L10n.tr("已移除 %@", root.displayPath)
        }
    }

    private func searchPathRow(
        path: String,
        status: FileSearchAuthorizedRootStatus?,
        alternate: Bool,
        deleteLabel: String,
        refresh: (() -> Void)? = nil,
        isRefreshPending: Bool = false,
        reauthorize: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(path)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            if let status, !status.isAuthorized {
                Button(action: reauthorize ?? {}) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(reauthorize == nil)
                .help(authorizedRootStatus(status).detail ?? L10n.tr("目录不可用"))
            }
            Menu {
                if let refresh {
                    Button(
                        isRefreshPending ? L10n.tr("排队中") : L10n.tr("刷新索引"),
                        action: refresh
                    )
                    .disabled(isRefreshPending)
                    Divider()
                }
                Button(deleteLabel, role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L10n.tr("%@ 的更多操作", path))
        }
        .padding(.horizontal, 9)
        .frame(height: 36)
        .background(alternate ? Color.primary.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func refreshURL(
        for directory: DocumentDirectoryPresentation
    ) -> URL? {
        let root = directory.exactAuthorizedRoot ?? directory.coveringAuthorizedRoot
        guard let root, root.status.isAuthorized else { return nil }
        return root.url ?? URL(
            fileURLWithPath: root.lastKnownPath,
            isDirectory: true
        )
    }

    private func shouldShowVisibleRefresh(
        for directory: DocumentDirectoryPresentation
    ) -> Bool {
        // Included child rows share a parent generation and keep refresh in
        // their overflow menu. A dedicated button is reserved for a directly
        // configured root that is large or has never committed an index.
        guard directory.exactAuthorizedRoot?.status.isAuthorized == true,
              let url = refreshURL(for: directory) else { return false }
        let status = rootIndexStatuses[url.standardizedFileURL.path]
        return status?.indexedItemCount ?? 0 >= 1_000
            || status?.hasCommittedGeneration != true
    }

    private func isRootRefreshPending(_ url: URL) -> Bool {
        queuedRootRefreshPaths.contains(url.standardizedFileURL.path)
    }

    private func startRootRefresh(_ url: URL, title: String) {
        let path = url.standardizedFileURL.path
        guard queuedRootRefreshPaths.insert(path).inserted else { return }
        fileIndexMessage = L10n.tr("%@ 已加入更新队列", title)
        Task { @MainActor in
            let result = await FileSearchIndexRuntime.shared
                .rebuildRootWhenAvailable(url)
            queuedRootRefreshPaths.remove(path)
            await refreshIndexStatus()
            switch result {
            case let .completed(_, _, items):
                fileIndexMessage = L10n.tr("%@ 索引完成：%d 项", title, items)
            case .noChanges:
                fileIndexMessage = L10n.tr("%@ 没有可索引内容", title)
            case .deferred:
                fileIndexMessage = L10n.tr("%@ 更新已取消", title)
            case .failed(let message):
                fileIndexMessage = L10n.tr("%@ 更新失败：%@", title, message)
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileSearchAccountHome.url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func authorizedRootStatus(
        _ status: FileSearchAuthorizedRootStatus
    ) -> (title: String, detail: String?, systemImage: String, color: Color) {
        switch status {
        case .authorized:
            return (L10n.tr("已授权"), nil, "checkmark.circle.fill", .green)
        case .reauthorizationRequired(let reason):
            return (L10n.tr("需要重新授权"), reason, "exclamationmark.circle.fill", .orange)
        case .unavailable(let reason):
            return (L10n.tr("不可用"), reason, "xmark.circle.fill", .red)
        }
    }

    private var indexConnectionText: String {
        if isIndexUpdating { return L10n.tr("索引更新中") }
        switch indexMetadata?.phase {
        case .ready: return L10n.tr("已连接")
        case .indexingApplications: return L10n.tr("正在建立应用索引")
        case .indexingFiles: return L10n.tr("正在更新文档索引")
        case .limited: return L10n.tr("索引容量已满")
        case .idle, .none: return L10n.tr("等待建立索引")
        }
    }

    private var indexConnectionColor: Color {
        if isIndexUpdating { return .blue }
        switch indexMetadata?.phase {
        case .ready: return .green
        case .limited: return .orange
        case .indexingApplications, .indexingFiles: return .blue
        case .idle, .none: return .secondary
        }
    }

    private var isIndexUpdating: Bool {
        initialIndexProgress != nil
            || (indexMetadata?.indexingRootCount ?? 0) > 0
            || rootIndexStatuses.values.contains(where: \.isIndexing)
    }

    private var indexProgressStatusText: String {
        if let initialIndexProgress {
            return initialIndexProgress.localizedStatusMessage
        }
        if isIndexUpdating {
            return L10n.tr("正在后台更新索引；已完成的内容仍可搜索")
        }
        return indexConnectionText
    }

    private var indexProgressPercentageText: String? {
        guard let progress = initialIndexProgress else { return nil }
        if progress.discoveredItems > 0 {
            return L10n.tr(
                "已索引 %lld / 已发现 %lld",
                Int64(progress.indexedItems),
                Int64(progress.discoveredItems)
            )
        }
        guard let fraction = progress.fractionCompleted else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var indexLogLines: [String] {
        if let progress = initialIndexProgress {
            var lines: [String] = []
            if let root = progress.currentRootName, !root.isEmpty {
                lines.append(L10n.tr("目录：%@", root))
            }
            lines.append(
                L10n.tr(
                    "进度：已索引 %lld / 已发现 %lld 项",
                    Int64(progress.indexedItems),
                    Int64(progress.discoveredItems)
                )
            )
            lines.append(contentsOf: progress.recentPaths.reversed().map {
                L10n.tr("正在处理：%@", $0)
            })
            return lines
        }
        if let metadata = indexMetadata {
            return [
                L10n.tr("当前没有正在运行的索引任务。"),
                L10n.tr("已提交：%lld 项", Int64(metadata.statistics.indexedItems)),
                L10n.tr("上次完成：%@", formattedLastIndexDate)
            ]
        }
        return [L10n.tr("正在读取索引状态")]
    }

    @ViewBuilder
    private var indexProgressBar: some View {
        if let fraction = initialIndexProgress?.fractionCompleted {
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var indexPhaseTitle: String {
        guard let phase = indexMetadata?.phase else { return L10n.tr("正在读取索引状态") }
        switch phase {
        case .idle: return L10n.tr("索引尚未建立")
        case .indexingApplications: return L10n.tr("正在建立应用索引")
        case .indexingFiles: return L10n.tr("正在维护用户文件索引")
        case .ready: return L10n.tr("本地索引已就绪")
        case .limited: return L10n.tr("索引已达到容量上限")
        }
    }

    private var indexPhaseDetail: String {
        guard let metadata = indexMetadata else { return L10n.tr("请稍候…") }
        switch metadata.phase {
        case .idle: return L10n.tr("后台索引会持续低占用运行，查询不会触发扫描。")
        case .indexingApplications: return L10n.tr("应用目录完成一个即提交一个，可立即用于查询。")
        case .indexingFiles:
            if let progress = initialIndexProgress,
               progress.discoveredItems > 0 {
                return L10n.tr(
                    "已索引 %lld / 已发现 %lld 项；发现总数会随扫描继续增加。",
                    Int64(progress.indexedItems),
                    Int64(progress.discoveredItems)
                )
            }
            return L10n.tr("当前查询继续使用最近一次完整提交的结果。")
        case .ready:
            return L10n.tr(
                "已提交 %lld 项本地结果。",
                Int64(metadata.statistics.indexedItems)
            )
        case .limited: return L10n.tr("已提交结果达到 30 万项上限，部分内容可能不可见。")
        }
    }

    private var indexPhaseIcon: String {
        switch indexMetadata?.phase {
        case .idle, .none: return "clock"
        case .indexingApplications, .indexingFiles: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        }
    }

    private var indexPhaseColor: Color {
        switch indexMetadata?.phase {
        case .ready: return .green
        case .limited: return .orange
        default: return .blue
        }
    }

    private var formattedDatabaseSize: String {
        guard let indexDatabaseSize else { return "-" }
        return ByteCountFormatter.string(fromByteCount: indexDatabaseSize, countStyle: .file)
    }

    private var formattedLastIndexDate: String {
        guard let date = indexMetadata?.lastSuccessfulIndexAt else { return L10n.tr("尚未完成") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func refreshIndexStatus() async {
        initialIndexProgress = await FileSearchInitialIndexProgressTracker
            .shared.snapshot()
        indexMetadata = await FileSearchIndexRuntime.shared.metadata()
        rootIndexStatuses = await FileSearchIndexRuntime.shared.rootStatuses()
        indexDatabaseSize = (try? FileSearchIndexStore.defaultDatabaseURL.resourceValues(
            forKeys: [.fileSizeKey]
        ))?.fileSize.map(Int64.init)
    }

    private func refreshPermissionState() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
        accessibilityGranted = AccessibilityScrollPermission.isGranted
    }

    private func applyPendingSettingsRoute() {
        guard UserDefaults.standard.bool(
            forKey: PEEKPreferenceKey.openDocumentSearchSettings
        ) else {
            return
        }
        UserDefaults.standard.removeObject(
            forKey: PEEKPreferenceKey.openDocumentSearchSettings
        )
        showDocumentSearchSettings()
    }

    private func showDocumentSearchSettings() {
        selectedPane = .search
        selectedSearchPane = .documents
    }

    private func requestScreenRecordingPermission() {
        let requestAccepted = ScreenRecordingPermission.request()
        refreshPermissionState()
        if requestAccepted {
            screenRecordingRestartRequired = true
            permissionMessage = L10n.tr("授权已记录，请完全退出并重新打开 PEEK")
        } else if screenRecordingGranted {
            permissionMessage = L10n.tr("屏幕录制权限已授权")
        } else {
            permissionMessage = L10n.tr("请在系统设置中允许 PEEK，然后完全退出并重新打开应用")
        }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginMessage = L10n.tr("登录项需要在“系统设置 > 通用 > 登录项”中确认。")
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginState()
            launchAtLoginMessage = enabled ? L10n.tr("已设置为登录时打开") : L10n.tr("已关闭登录时打开")
        } catch {
            refreshLaunchAtLoginState()
            launchAtLoginMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func updateHotKey(
        _ shortcut: ScreenshotHotKey?,
        for action: ScreenshotGlobalHotKeyAction
    ) {
        do {
            if let shortcut {
                try hotKeyManager.update(shortcut: shortcut, for: action)
                hotKeyMessage = L10n.tr(
                    "“%@”已更新为 %@",
                    action.displayName,
                    shortcut.displayString
                )
            } else {
                hotKeyManager.disable(action)
                hotKeyMessage = L10n.tr("“%@”快捷键已停用", action.displayName)
            }
        } catch {
            hotKeyMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func restoreDefaultHotKeys() {
        do {
            try hotKeyManager.restoreDefaults()
            hotKeyMessage = L10n.tr("已恢复默认快捷键")
        } catch {
            hotKeyMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func hotKeyIcon(for action: ScreenshotGlobalHotKeyAction) -> String {
        switch action {
        case .region: return "viewfinder"
        case .scrolling: return "rectangle.stack.badge.plus"
        case .ocr: return "text.viewfinder"
        case .search: return "magnifyingglass"
        }
    }

    private func chooseIndexFolders(
        replacing root: FileSearchAuthorizedRoot? = nil,
        suggestedURL: URL? = nil
    ) {
        let panel = NSOpenPanel()
        panel.title = root == nil && suggestedURL == nil
            ? L10n.tr("选择要索引的目录")
            : (root == nil ? L10n.tr("授权文档搜索目录") : L10n.tr("重新授权索引目录"))
        panel.message = L10n.tr("PEEK 只会在后台索引你选择的目录及其子目录。")
        panel.prompt = root == nil && suggestedURL == nil
            ? L10n.tr("添加")
            : (root == nil ? L10n.tr("授权") : L10n.tr("重新授权"))
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = root == nil && suggestedURL == nil
        panel.resolvesAliases = true
        if let url = root?.url ?? suggestedURL { panel.directoryURL = url }

        guard panel.runModal() == .OK else { return }
        let selectedURLs = panel.urls
        defer { selectedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        if let systemURL = selectedURLs.first(where: { isProtectedSystemDocumentRoot($0) }) {
            fileIndexMessage = L10n.tr(
                "“%@”属于系统或应用目录，请在“应用搜索”中添加",
                systemURL.path
            )
            NSSound.beep()
            return
        }
        do {
            if let root, let url = selectedURLs.first {
                fileIndexMessage = try authorizedRootStore
                    .reauthorizeRoot(id: root.id, with: url).localizedDescription
            } else {
                fileIndexMessage = try selectedURLs.map {
                    try authorizedRootStore.addRoot($0).localizedDescription
                }.joined(separator: "；")
            }
        } catch {
            fileIndexMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func isProtectedSystemDocumentRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let protectedRoots = ["/Applications", "/System", "/Library", "/bin", "/sbin", "/usr"]
        return protectedRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private func chooseApplicationFolder(
        replacing root: FileSearchApplicationRoot? = nil
    ) {
        let panel = NSOpenPanel()
        panel.title = root == nil ? L10n.tr("添加应用目录") : L10n.tr("重新授权应用目录")
        panel.message = L10n.tr("PEEK 只会索引所选目录中的 .app，不会索引普通文件。")
        panel.prompt = root == nil ? L10n.tr("添加") : L10n.tr("重新授权")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let url = root?.url { panel.directoryURL = url }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        defer { selectedURL.stopAccessingSecurityScopedResource() }
        do {
            if let rootID = root?.customRootID {
                fileIndexMessage = try applicationRootStore
                    .reauthorizeRoot(id: rootID, with: selectedURL)
                    .localizedDescription
            } else {
                fileIndexMessage = try applicationRootStore
                    .addRoot(selectedURL)
                    .localizedDescription
            }
        } catch {
            fileIndexMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func chooseExclusionPath() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择要排除的文件或目录")
        panel.prompt = L10n.tr("排除")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let selectedURLs = panel.urls
        defer { selectedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        selectedURLs.forEach { exclusionSettings.addPath($0.path) }
        fileIndexMessage = selectedURLs.count == 1
            ? L10n.tr("已添加搜索排除项")
            : L10n.tr("已添加 %d 个搜索排除项", selectedURLs.count)
    }

    private func restorePreferenceDefaults() {
        defaultSearchCategoryRaw = SearchPanelCategory.all.rawValue
        includesHiddenFilesByDefault = false
        searchResultLimit = 80
        retainsLastSearchQuery = false
        searchWindowScreenRaw = SearchWindowScreenPreference.mouse.rawValue
        searchWindowPositionRaw = SearchWindowPositionPreference.centered.rawValue
        searchWindowOpacity = 0.92
        searchShowsPreview = true
        searchResultDensityRaw = SearchResultDensity.standard.rawValue
        appearanceModeRaw = PEEKAppearanceMode.system.rawValue
        appLanguageRaw = PEEKAppLanguage.system.rawValue
        PEEKAppLanguage.system.apply()
        automaticScrolling = true
        autoDetectScrollTarget = true
        automaticScrollAmount = 700
        scrollMaximumFrames = 30
        UserDefaults.standard.removeObject(forKey: PEEKPreferenceKey.searchLastQuery)
        restoreDefaultHotKeys()
    }

    private func copyDiagnostics() {
        let metadata = indexMetadata
        let lines = [
            "PEEK \(versionLabel)",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "-")",
            "Index phase: \(metadata?.phase.rawValue ?? "unknown")",
            "Index items: \(metadata?.statistics.indexedItems ?? 0)",
            "Committed roots: \(metadata?.committedRootCount ?? 0)",
            "Database: \(FileSearchIndexStore.defaultDatabaseURL.path)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
