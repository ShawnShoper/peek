import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI

struct SearchPanelLowerContentPolicy: Equatable, Sendable {
    let accessibilityHidden: Bool
    let allowsHitTesting: Bool
    let isDisabled: Bool

    init(expanded: Bool) {
        accessibilityHidden = !expanded
        allowsHitTesting = expanded
        isDisabled = !expanded
    }
}

struct SearchPanelView: View {
    @ObservedObject var viewModel: SearchPanelViewModel
    var onExpansionChanged: (Bool) -> Void = { _ in }
    @FocusState private var searchFieldFocused: Bool
    @State private var hoveredAction: SearchPanelFileAction?
    @State private var showsNumericShortcuts = false
    @AppStorage(PEEKPreferenceKey.searchShowsPreview)
    private var showsPreview = true
    @AppStorage(PEEKPreferenceKey.searchResultDensity)
    private var resultDensityRaw = SearchResultDensity.standard.rawValue
    @AppStorage(PEEKPreferenceKey.searchWindowOpacity)
    private var searchWindowOpacity = 0.92

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
                .transaction { transaction in
                    // AppKit reveals the fixed canvas by resizing the panel.
                    // Keep the field free from SwiftUI layout animation.
                    transaction.animation = nil
                }
            lowerContent
        }
        .frame(
            minWidth: SearchPanelLayout.minimumWidth,
            idealWidth: SearchPanelLayout.width,
            minHeight: 590,
            idealHeight: SearchPanelLayout.expandedHeight
        )
        .background(
            SearchPanelWindowOpacityBridge(opacity: searchWindowOpacity)
                .frame(width: 0, height: 0)
        )
        .background(
            SearchPanelKeyboardBridge(
                isActive: viewModel.isPanelActive,
                moveUp: { viewModel.moveSelection(by: -1) },
                moveDown: { viewModel.moveSelection(by: 1) },
                activate: viewModel.openSelection,
                activateResultAtIndex: viewModel.openResult,
                optionStateChanged: { showsNumericShortcuts = $0 },
                cycleCategory: viewModel.cycleCategory,
                dismiss: viewModel.dismiss,
                isSearchFieldFocused: { searchFieldFocused }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            onExpansionChanged(isExpanded)
            guard viewModel.isPanelActive else { return }
            DispatchQueue.main.async { searchFieldFocused = true }
        }
        .onChange(of: isExpanded) { expanded in
            onExpansionChanged(expanded)
            guard !expanded, viewModel.isPanelActive else { return }
            DispatchQueue.main.async { searchFieldFocused = true }
        }
        .onChange(of: viewModel.isPanelActive) { isActive in
            showsNumericShortcuts = false
            guard isActive else {
                searchFieldFocused = false
                return
            }
            DispatchQueue.main.async { searchFieldFocused = true }
        }
    }

    private var isExpanded: Bool {
        viewModel.hasVisibleQuery
    }

    private var lowerContent: some View {
        let policy = SearchPanelLowerContentPolicy(expanded: isExpanded)
        return VStack(spacing: 0) {
            Divider().opacity(0.55)
            searchContent
            actionBar
            statusLine
        }
        .accessibilityHidden(policy.accessibilityHidden)
        .allowsHitTesting(policy.allowsHitTesting)
        .disabled(policy.isDisabled)
    }

    @ViewBuilder
    private var searchContent: some View {
        if showsPreview {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    resultList
                        .frame(width: max(370, proxy.size.width * 0.56))
                    Divider().opacity(0.55)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            resultList
        }
    }

    private var resultDensity: SearchResultDensity {
        SearchResultDensity(rawValue: resultDensityRaw) ?? .standard
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            TextField(L10n.tr("搜索应用、文件或文件夹"), text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFieldFocused)
                .accessibilityLabel(L10n.tr("搜索应用、文件或文件夹"))

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("清空搜索"))
            }

            searchOptionsMenu

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .accessibilityLabel("PEEK")

            Button {
                showsPreview.toggle()
            } label: {
                Image(systemName: showsPreview ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showsPreview ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(showsPreview ? L10n.tr("隐藏预览") : L10n.tr("显示预览"))
        }
        .padding(.horizontal, 15)
        .frame(height: 58)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    private var searchOptionsMenu: some View {
        Menu {
            Picker(L10n.tr("搜索范围"), selection: $viewModel.selectedCategory) {
                ForEach(SearchPanelCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            Divider()
            Toggle(isOn: $viewModel.includesHiddenFiles) {
                Label(L10n.tr("隐藏文件"), systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "line.3.horizontal.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(viewModel.selectedCategory.title)
    }

    private var keyboardHint: some View {
        HStack(spacing: 7) {
            Text(L10n.tr("⌃空格 呼出"))
            Text("·")
            Text(L10n.tr("↑↓ 选择"))
            Text("·")
            Text(L10n.tr("↩ 打开"))
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("快捷键：Control 空格呼出，上下箭头选择，回车打开"))
    }

    private func categoryButton(_ category: SearchPanelCategory) -> some View {
        let isSelected = viewModel.selectedCategory == category
        return Button {
            viewModel.selectedCategory = category
            searchFieldFocused = true
        } label: {
            Text(category.title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(0.075))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.86))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var hiddenFilesButton: some View {
        Button {
            viewModel.includesHiddenFiles.toggle()
            searchFieldFocused = true
        } label: {
            Label(
                L10n.tr("隐藏文件"),
                systemImage: viewModel.includesHiddenFiles ? "eye.fill" : "eye.slash"
            )
            .font(.caption.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(viewModel.includesHiddenFiles
                        ? Color.accentColor.opacity(0.82)
                        : Color.primary.opacity(0.075))
            )
            .foregroundStyle(viewModel.includesHiddenFiles
                ? Color.white
                : Color.primary.opacity(0.76))
        }
        .buttonStyle(.plain)
        .accessibilityValue(viewModel.includesHiddenFiles ? L10n.tr("已显示") : L10n.tr("已隐藏"))
    }

    private var resultList: some View {
        Group {
            if viewModel.results.isEmpty, !viewModel.isSearching {
                emptyResults
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.resultGroups) { group in
                                resultSection(
                                    title: viewModel.selectedCategory == .all
                                        ? group.kind.title
                                        : viewModel.selectedCategory.title,
                                    items: group.items
                                )
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: viewModel.selectedItemID) { selectedID in
                        guard let selectedID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
    }

    private var emptyResults: some View {
        VStack(spacing: 11) {
            Image(systemName: viewModel.errorMessage == nil
                ? "doc.text.magnifyingglass"
                : "exclamationmark.magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(viewModel.errorMessage ?? emptyResultMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultSection(
        title: String,
        items: [SearchPanelItem]
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(items.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 5)

        ForEach(items) { item in
            resultRow(
                item,
                shortcutIndex: numericShortcutIndex(for: item)
            )
                .id(item.id)
        }
    }

    private func numericShortcutIndex(for item: SearchPanelItem) -> Int? {
        guard showsNumericShortcuts,
              let index = viewModel.orderedResults.firstIndex(where: { $0.id == item.id }),
              index < 10 else { return nil }
        return index
    }

    private func resultRow(_ item: SearchPanelItem, shortcutIndex: Int?) -> some View {
        let isSelected = viewModel.selectedItemID == item.id
        let iconSize: CGFloat = resultDensity == .compact ? 32 : 36
        let verticalPadding: CGFloat = resultDensity == .compact ? 6 : 8
        return Button {
            viewModel.selectedItemID = item.id
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    SearchPanelFileIcon(
                        url: item.url,
                        size: iconSize,
                        fallbackSystemImage: item.category == .applications
                            ? "app.dashed"
                            : (item.isDirectory ? "folder.fill" : "doc")
                    )
                    if let shortcutIndex {
                        Text(shortcutIndex == 9 ? "0" : "\(shortcutIndex + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .frame(minWidth: 15, minHeight: 14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .offset(x: 5, y: -5)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Text(item.subtitle ?? item.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(isSelected
                            ? Color.white.opacity(0.78)
                            : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                viewModel.selectedItemID = item.id
                viewModel.openSelection()
            }
        )
        .help(item.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detailPane: some View {
        Group {
            if let item = viewModel.selectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailHeader(for: item)
                        preview(for: item)
                        metadataTable(for: item)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 11) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("选择结果以查看预览和文件信息"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.38))
    }

    private func detailHeader(for item: SearchPanelItem) -> some View {
        HStack(spacing: 14) {
            SearchPanelFileIcon(
                url: item.url,
                size: 48,
                fallbackSystemImage: item.category == .applications
                    ? "app.dashed"
                    : (item.isDirectory ? "folder.fill" : "doc")
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                Text(detailSubtitle(for: item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private func preview(for item: SearchPanelItem) -> some View {
        switch viewModel.previewKind {
        case .loading:
            previewSurface {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        case .image:
            previewSurface {
                if let image = viewModel.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
                        .padding(16)
                }
            }
            .accessibilityLabel(L10n.tr("%@ 的预览", item.displayName))
        case .text(let preview):
            previewSection(title: L10n.tr("文件内容"), systemImage: "doc.text") {
                VStack(spacing: 0) {
                    SearchPanelTextPreviewView(text: preview.text)
                        .frame(height: 260)
                    Divider().opacity(0.45)
                    HStack(spacing: 12) {
                        Text(L10n.tr(
                            "已显示 %@，文件共 %@",
                            ByteCountFormatter.string(
                                fromByteCount: Int64(preview.loadedByteCount),
                                countStyle: .file
                            ),
                            ByteCountFormatter.string(
                                fromByteCount: Int64(preview.totalByteCount),
                                countStyle: .file
                            )
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if viewModel.isLoadingMoreTextPreview {
                            ProgressView()
                                .controlSize(.small)
                        } else if preview.canLoadMore {
                            Button(L10n.tr("加载更多")) {
                                viewModel.loadMoreTextPreview()
                            }
                            .buttonStyle(.borderless)
                        } else if preview.isTruncated {
                            Text(L10n.tr("已达到预览上限"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        case .folder(let entries):
            previewSection(
                title: L10n.tr("文件夹内容（%d 项）", entries.count),
                systemImage: "folder"
            ) {
                if entries.isEmpty {
                    Text(L10n.tr("此文件夹为空或当前无权读取内容"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            folderEntryRow(entry)
                            if entry.id != entries.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }
            }
        case .application:
            applicationPreview(for: item)
        case .systemSettings(let settings):
            previewSection(title: L10n.tr("设置项目"), systemImage: "gearshape.2") {
                LazyVStack(spacing: 0) {
                    ForEach(settings) { setting in
                        Button {
                            viewModel.openSystemSetting(setting)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: setting.systemImage)
                                    .frame(width: 24)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(setting.title)
                                        .font(.callout.weight(.semibold))
                                    Text(setting.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if setting.id != settings.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        case .unavailable(let message):
            previewSurface {
                VStack(spacing: 10) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
                .padding(20)
            }
        }
    }

    private func previewSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }

    private func previewSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
            Divider().opacity(0.45)
            content()
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func folderEntryRow(_ entry: SearchPanelFolderEntry) -> some View {
        HStack(spacing: 11) {
            SearchPanelFileIcon(
                url: entry.url,
                size: 24,
                fallbackSystemImage: entry.isDirectory ? "folder.fill" : "doc"
            )
            Text(entry.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help(entry.url.path)
    }

    private func applicationPreview(for item: SearchPanelItem) -> some View {
        previewSection(title: L10n.tr("动作"), systemImage: "bolt.circle") {
            VStack(alignment: .leading, spacing: 0) {
                applicationActionButton(
                    title: L10n.tr("打开应用"),
                    systemImage: "arrow.up.forward.app.fill",
                    action: .open
                )
                Divider().opacity(0.35)
                applicationActionButton(
                    title: L10n.tr("在访达显示"),
                    systemImage: "folder.fill",
                    action: .revealInFinder
                )
                if let notice = viewModel.browserHistoryNotice {
                    Divider().opacity(0.35)
                    Label(notice, systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func applicationActionButton(
        title: String,
        systemImage: String,
        action: SearchPanelFileAction
    ) -> some View {
        let capability = viewModel.capability(for: action)
        return Button {
            viewModel.perform(action)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 25, height: 25)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!capability.isEnabled || viewModel.isPerformingAction)
        .opacity(capability.isEnabled ? 1 : 0.42)
        .help(capability.reason ?? title)
    }

    private func detailSubtitle(for item: SearchPanelItem) -> String {
        guard let fileSize = item.fileSize, !item.isDirectory else {
            return item.kindDescription
        }
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        return "\(item.kindDescription)  ·  \(size)"
    }

    private func metadataTable(for item: SearchPanelItem) -> some View {
        let fields = [
            SearchPanelMetadataField(label: L10n.tr("位置"), value: item.url.path)
        ] + viewModel.selectedMetadata.filter { field in
            field.label != L10n.tr("类型") && field.label != L10n.tr("位置")
        }
        return Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 {
                    Divider()
                        .opacity(0.45)
                        .gridCellColumns(2)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text(field.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 92, alignment: .leading)
                    Text(field.value)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(field.label)
                .accessibilityValue(field.value)
            }
        }
        .frame(maxWidth: 620)
    }

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(SearchPanelFileAction.allCases) { action in
                    actionButton(action)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 5)
    }

    private func actionButton(_ action: SearchPanelFileAction) -> some View {
        let capability = viewModel.capability(for: action)
        let enabled = capability.isEnabled
        let help = capability.reason ?? action.title
        let isHovered = hoveredAction == action
        return Button {
            viewModel.perform(action)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(action.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 94)
            .frame(minHeight: 46)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered && enabled
                        ? Color.primary.opacity(0.09)
                        : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || viewModel.isPerformingAction)
        .opacity(enabled && !viewModel.isPerformingAction ? 1 : 0.34)
        .onHover { hovering in
            hoveredAction = hovering ? action : nil
        }
        .help(help)
        .accessibilityLabel(action.title)
        .accessibilityValue(enabled ? L10n.tr("可用") : L10n.tr("不可用"))
        .accessibilityHint(help)
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 8)
            if let errorMessage = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            } else if let feedbackMessage = viewModel.feedbackMessage {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(feedbackMessage)
                    .foregroundStyle(.secondary)
            } else if let unavailableActionMessage = viewModel.unavailableActionMessage {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(unavailableActionMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.tr("本地搜索 · 应用结果优先显示 · 文件和文件夹来自授权目录"))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .font(.caption)
        .lineLimit(1)
        .frame(height: 29)
        .padding(.horizontal, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    private var emptyResultMessage: String {
        viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.tr("输入关键词开始查找应用、文件或文件夹")
            : L10n.tr("没有找到匹配结果；尚未完成索引的项目暂时不可见")
    }
}

private struct SearchPanelTextPreviewView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        let visibleOrigin = scrollView.contentView.bounds.origin
        let shouldPreservePosition = text.hasPrefix(textView.string)
        textView.string = text
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        if shouldPreservePosition {
            scrollView.contentView.scroll(to: visibleOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}

private struct SearchPanelWindowOpacityBridge: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let value = CGFloat(min(1, max(0.6, opacity)))
        DispatchQueue.main.async {
            nsView.window?.alphaValue = value
        }
    }
}

@MainActor
final class SearchPanelIconCache {
    static let shared = SearchPanelIconCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 512
    }

    func icon(for url: URL, size: CGFloat) async -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: max(32, size), height: max(32, size)),
            scale: scale,
            representationTypes: .icon
        )
        let cgImage: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                representation,
                _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
        guard !Task.isCancelled, let cgImage else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct SearchPanelFileIcon: View {
    let url: URL
    let size: CGFloat
    let fallbackSystemImage: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size >= 40 ? 7 : 3)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = await SearchPanelIconCache.shared.icon(for: url, size: size)
        }
    }
}
