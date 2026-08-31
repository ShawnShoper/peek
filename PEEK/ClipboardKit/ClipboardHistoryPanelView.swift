import AppKit
import SwiftUI

struct ClipboardHistoryPanelView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            HStack(spacing: 0) {
                historyList
                    .frame(width: 370)
                Divider().opacity(0.55)
                previewPane
            }
            Divider().opacity(0.55)
            footer
        }
        .frame(width: 880, height: 610)
        .background(
            ClipboardHistoryKeyboardBridge(
                moveUp: { viewModel.moveSelection(by: -1) },
                moveDown: { viewModel.moveSelection(by: 1) },
                copy: { viewModel.restoreSelected() },
                paste: { viewModel.restoreSelected(andPaste: true) },
                dismiss: viewModel.dismiss
            )
            .frame(width: 0, height: 0)
        )
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: viewModel.query) { _ in viewModel.queryDidChange() }
        .onChange(of: viewModel.selectedFilter) { _ in viewModel.filterDidChange() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clipboard.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                TextField(L10n.tr("搜索剪贴板历史"), text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("清空搜索"))
                }
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            Picker(L10n.tr("类型"), selection: $viewModel.selectedFilter) {
                ForEach(ClipboardHistoryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
    }

    private var historyList: some View {
        Group {
            if viewModel.filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(viewModel.records.isEmpty
                        ? L10n.tr("复制内容后会显示在这里")
                        : L10n.tr("没有匹配的记录"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(viewModel.filteredRecords) { record in
                                recordRow(record)
                                    .id(record.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: viewModel.selectedRecordID) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }

    private func recordRow(_ record: ClipboardHistoryRecord) -> some View {
        let selected = record.id == viewModel.selectedRecordID
        return HStack(spacing: 11) {
            Image(systemName: record.kind.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 29, height: 29)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.white.opacity(0.16) : Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let source = record.sourceApplicationName {
                        Text(source).lineLimit(1)
                    }
                    Text(viewModel.relativeTimeLabel(for: record))
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.select(record)
            viewModel.restoreSelected()
        }
        .onTapGesture { viewModel.select(record) }
        .contextMenu {
            Button(L10n.tr("复制")) {
                viewModel.select(record)
                viewModel.restoreSelected()
            }
            Button(L10n.tr("删除"), role: .destructive) {
                viewModel.select(record)
                viewModel.deleteSelected()
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                if let record = viewModel.selectedRecord {
                    Label(record.kind.title, systemImage: record.kind.systemImage)
                        .font(.headline)
                    Spacer()
                    Text(ByteCountFormatter.string(
                        fromByteCount: record.byteCount,
                        countStyle: .file
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 48)
            .padding(.horizontal, 18)
            Divider().opacity(0.45)
            if viewModel.fileItems.count > 1 {
                fileSelector
                Divider().opacity(0.45)
            }
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.16))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch viewModel.preview {
        case .empty:
            placeholder(L10n.tr("选择一条记录查看内容"), systemImage: "doc.text.magnifyingglass")
        case .loading:
            ProgressView().controlSize(.small)
        case .text(let text):
            textPreview(text.text, byteFooter: textByteFooter(text))
        case .link(let url):
            ClipboardHistoryLinkPreviewView(url: url)
        case .image(let image, let pixelWidth, let pixelHeight, let pageCount):
            VStack(spacing: 12) {
                previewImage(image)
                HStack(spacing: 14) {
                    Label("\(pixelWidth) × \(pixelHeight)", systemImage: "viewfinder")
                    if let pageCount {
                        Label(L10n.tr("%d 页", pageCount), systemImage: "doc.on.doc")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .fileText(let item, let text):
            VStack(spacing: 12) {
                fileIdentity(item)
                textPreview(
                    text.text,
                    byteFooter: L10n.tr(
                        "已显示 %@，文件共 %@",
                        ByteCountFormatter.string(
                            fromByteCount: Int64(text.loadedByteCount),
                            countStyle: .file
                        ),
                        ByteCountFormatter.string(
                            fromByteCount: Int64(text.totalByteCount),
                            countStyle: .file
                        )
                    )
                )
            }
        case .fileImage(let item, let image):
            VStack(spacing: 12) {
                fileIdentity(item)
                previewImage(image)
                fileMetadata(item)
            }
        case .folder(let item, let folder):
            VStack(spacing: 12) {
                fileIdentity(item)
                folderEntries(folder)
            }
        case .fileUnavailable(let item, let message):
            VStack(spacing: 16) {
                fileIdentity(item)
                placeholder(message, systemImage: "doc.questionmark")
                fileMetadata(item)
            }
        case .failure(let message):
            placeholder(message, systemImage: "exclamationmark.triangle")
        }
    }

    private var fileSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.fileItems) { item in
                    let selected = item.id == viewModel.selectedFileID
                    Button {
                        viewModel.selectPreviewFile(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 21, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                            Text(item.displayName)
                                .font(.caption)
                                .fontWeight(selected ? .semibold : .regular)
                                .lineLimit(1)
                                .frame(maxWidth: 130, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(selected
                                    ? Color.accentColor.opacity(0.65)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(item.displayName)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(height: 64)
    }

    private func previewImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            )
    }

    private func textPreview(_ text: String, byteFooter: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let byteFooter {
                Text(byteFooter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func textByteFooter(_ text: ClipboardHistoryTextPreview) -> String? {
        guard text.isTruncated else { return nil }
        return L10n.tr(
            "已显示 %@，文件共 %@",
            ByteCountFormatter.string(
                fromByteCount: Int64(text.loadedByteCount),
                countStyle: .file
            ),
            ByteCountFormatter.string(
                fromByteCount: Int64(text.totalByteCount),
                countStyle: .file
            )
        )
    }

    private func fileIdentity(_ item: ClipboardHistoryFilePreviewItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 29, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileMetadata(_ item: ClipboardHistoryFilePreviewItem) -> some View {
        VStack(spacing: 0) {
            metadataRow(L10n.tr("类型"), value: item.kindDescription)
            if let fileSize = item.fileSize {
                Divider().opacity(0.45)
                metadataRow(
                    L10n.tr("大小"),
                    value: ByteCountFormatter.string(
                        fromByteCount: fileSize,
                        countStyle: .file
                    )
                )
            }
            if let modifiedAt = item.modifiedAt {
                Divider().opacity(0.45)
                metadataRow(
                    L10n.tr("修改时间"),
                    value: modifiedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.vertical, 8)
    }

    private func folderEntries(_ folder: ClipboardHistoryFolderPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(folder.isTotalItemCountExact
                ? L10n.tr("文件夹内容（%d 项）", folder.totalItemCount)
                : L10n.tr("文件夹内容（至少 %d 项）", folder.totalItemCount))
                .font(.subheadline.weight(.semibold))
            if folder.entries.isEmpty {
                placeholder(
                    L10n.tr("此文件夹为空或当前无权读取内容"),
                    systemImage: "folder"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(folder.entries) { entry in
                            HStack(spacing: 9) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                                    .frame(width: 25, height: 25)
                                Text(entry.displayName)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                    }
                }
                if folder.isTruncated {
                    Text(L10n.tr("仅显示前 %d 项", folder.entries.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
            Text(title).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(L10n.tr("最多保留 100 条，内容仅存储在本机"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.tr("删除")) { viewModel.deleteSelected() }
                .disabled(viewModel.selectedRecord == nil)
            Button(L10n.tr("复制")) { viewModel.restoreSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(viewModel.selectedRecord == nil || viewModel.isBusy)
            Button(L10n.tr("复制并粘贴")) {
                viewModel.restoreSelected(andPaste: true)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedRecord == nil || viewModel.isBusy)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
    }
}

private struct ClipboardHistoryKeyboardBridge: NSViewRepresentable {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let copy: () -> Void
    let paste: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            moveUp: moveUp,
            moveDown: moveDown,
            copy: copy,
            paste: paste,
            dismiss: dismiss
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        private let moveUp: () -> Void
        private let moveDown: () -> Void
        private let copy: () -> Void
        private let paste: () -> Void
        private let dismiss: () -> Void
        private var monitor: Any?

        init(
            moveUp: @escaping () -> Void,
            moveDown: @escaping () -> Void,
            copy: @escaping () -> Void,
            paste: @escaping () -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.moveUp = moveUp
            self.moveDown = moveDown
            self.copy = copy
            self.paste = paste
            self.dismiss = dismiss
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window?.isKeyWindow == true else { return event }
                if let textView = event.window?.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                switch Int(event.keyCode) {
                case 53:
                    guard modifiers.isEmpty else { return event }
                    self.dismiss()
                    return nil
                case 125:
                    guard modifiers.isEmpty else { return event }
                    self.moveDown()
                    return nil
                case 126:
                    guard modifiers.isEmpty else { return event }
                    self.moveUp()
                    return nil
                case 36, 76:
                    if modifiers == .command {
                        self.paste()
                    } else if modifiers.isEmpty {
                        self.copy()
                    } else {
                        return event
                    }
                    return nil
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

    }
}
