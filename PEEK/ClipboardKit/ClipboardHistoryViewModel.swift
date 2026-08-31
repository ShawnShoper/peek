import AppKit
import Combine
import Foundation
@preconcurrency import QuickLookThumbnailing

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    private enum PreviewWorkerResult: Sendable {
        case files([ClipboardHistoryFilePreviewItem])
        case payload(ClipboardHistoryPayloadPreview)
        case folder(ClipboardHistoryFolderPreview?)
        case text(SearchPanelTextPreview?)
    }

    enum Preview {
        case empty
        case loading
        case text(ClipboardHistoryTextPreview)
        case image(NSImage, pixelWidth: Int, pixelHeight: Int, pageCount: Int?)
        case link(URL)
        case fileText(ClipboardHistoryFilePreviewItem, SearchPanelTextPreview)
        case fileImage(ClipboardHistoryFilePreviewItem, NSImage)
        case folder(ClipboardHistoryFilePreviewItem, ClipboardHistoryFolderPreview)
        case fileUnavailable(ClipboardHistoryFilePreviewItem, String)
        case failure(String)
    }

    @Published var query = ""
    @Published var selectedFilter = ClipboardHistoryFilter.all
    @Published private(set) var records: [ClipboardHistoryRecord] = []
    @Published private(set) var filteredRecords: [ClipboardHistoryRecord] = []
    @Published private(set) var relativeTimeLabels: [UUID: String] = [:]
    @Published var selectedRecordID: UUID?
    @Published private(set) var preview: Preview = .empty
    @Published private(set) var fileItems: [ClipboardHistoryFilePreviewItem] = []
    @Published private(set) var selectedFileID: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false

    var onRequestClose: (() -> Void)?
    var onRequestPaste: (() throws -> Void)?

    private let monitor: ClipboardHistoryMonitor
    private var cancellables: Set<AnyCancellable> = []
    private var previewTask: Task<Void, Never>?
    private var previewWorkerTask: Task<PreviewWorkerResult?, Never>?
    private var previewTimeoutTask: Task<Void, Never>?
    private var previewRequest: QLThumbnailGenerator.Request?
    private var previewAccess: FileSearchSecurityScopedAccess?
    private var previewGeneration = 0
    private var timeRefreshTask: Task<Void, Never>?
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    init(monitor: ClipboardHistoryMonitor = .shared) {
        self.monitor = monitor
        records = monitor.records
        filteredRecords = monitor.records
        monitor.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] records in
                guard let self else { return }
                self.records = records
                self.rebuildFilteredRecords()
                self.refreshRelativeTimeLabels()
                self.reconcileSelection()
            }
            .store(in: &cancellables)
    }

    private func rebuildFilteredRecords() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredRecords = records.filter { record in
            guard selectedFilter.includes(record.kind) else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return [
                record.title,
                record.detail,
                record.sourceApplicationName ?? "",
            ].contains {
                $0.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
    }

    var selectedRecord: ClipboardHistoryRecord? {
        guard let selectedRecordID else { return nil }
        return filteredRecords.first { $0.id == selectedRecordID }
    }

    func activate() {
        monitor.setPanelVisible(true)
        monitor.reloadIfNeeded()
        rebuildFilteredRecords()
        refreshRelativeTimeLabels()
        startTimeRefresh()
        reconcileSelection()
        loadPreview()
    }

    func deactivate() {
        monitor.setPanelVisible(false)
        timeRefreshTask?.cancel()
        timeRefreshTask = nil
        cancelPreviewWork(incrementGeneration: true)
        fileItems = []
        selectedFileID = nil
        preview = .empty
    }

    func select(_ record: ClipboardHistoryRecord) {
        guard selectedRecordID != record.id else { return }
        selectedRecordID = record.id
        statusMessage = nil
        loadPreview(delayNanoseconds: 110_000_000)
    }

    func selectPreviewFile(_ item: ClipboardHistoryFilePreviewItem) {
        guard fileItems.contains(where: { $0.id == item.id }),
              selectedFileID != item.id else { return }
        cancelPreviewWork(incrementGeneration: true)
        selectedFileID = item.id
        preview = .loading
        beginFilePreview(for: item, generation: previewGeneration)
    }

    func moveSelection(by offset: Int) {
        let available = filteredRecords
        guard !available.isEmpty else { return }
        let currentIndex = selectedRecordID.flatMap { id in
            available.firstIndex { $0.id == id }
        } ?? 0
        let targetIndex = min(max(0, currentIndex + offset), available.count - 1)
        select(available[targetIndex])
    }

    func restoreSelected(andPaste: Bool = false) {
        guard let record = selectedRecord, !isBusy else { return }
        isBusy = true
        statusMessage = nil
        Task { [weak self, monitor] in
            do {
                try await monitor.restore(record)
                try await MainActor.run {
                    guard let self else { return }
                    if andPaste {
                        try self.onRequestPaste?()
                        self.statusMessage = L10n.tr("已粘贴")
                    } else {
                        self.statusMessage = L10n.tr("已复制回剪贴板")
                    }
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = error.localizedDescription
                    self?.isBusy = false
                    NSSound.beep()
                }
            }
        }
    }

    func deleteSelected() {
        guard let record = selectedRecord else { return }
        monitor.delete(record)
        statusMessage = L10n.tr("已删除一条记录")
    }

    func dismiss() {
        onRequestClose?()
    }

    func filterDidChange() {
        rebuildFilteredRecords()
        reconcileSelection(forceFirst: true)
    }

    func queryDidChange() {
        rebuildFilteredRecords()
        reconcileSelection(forceFirst: true)
    }

    func relativeTimeLabel(for record: ClipboardHistoryRecord) -> String {
        relativeTimeLabels[record.id]
            ?? relativeDateFormatter.localizedString(for: record.createdAt, relativeTo: Date())
    }

    private func reconcileSelection(forceFirst: Bool = false) {
        let available = filteredRecords
        if !forceFirst,
           let selectedRecordID,
           available.contains(where: { $0.id == selectedRecordID }) {
            return
        }
        self.selectedRecordID = available.first?.id
        loadPreview()
    }

    private func loadPreview(delayNanoseconds: UInt64 = 0) {
        cancelPreviewWork(incrementGeneration: true)
        fileItems = []
        selectedFileID = nil
        guard let record = selectedRecord else {
            preview = .empty
            return
        }
        let generation = previewGeneration
        let selectedRecordID = record.id
        preview = .loading
        previewTask = Task { @MainActor [weak self, monitor] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                let payload = try await monitor.payload(for: record)
                try Task.checkCancellation()
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedRecordID == selectedRecordID else { return }

                if !payload.fileURLs.isEmpty {
                    let urls = payload.fileURLs
                        .prefix(ClipboardHistoryPreviewLoader.maximumFileURLs)
                        .compactMap(URL.init(string:))
                    guard let work = await self.runPreviewWorker({
                        .files(ClipboardHistoryPreviewLoader.inspectFiles(urls))
                    }), case .files(let items) = work else { return }
                    guard !Task.isCancelled,
                          self.previewGeneration == generation,
                          self.selectedRecordID == selectedRecordID else { return }
                    self.previewWorkerTask = nil
                    self.previewTask = nil
                    self.fileItems = items
                    self.selectedFileID = items.first?.id
                    guard let first = items.first else {
                        self.preview = .failure(L10n.tr("没有可用的文件预览"))
                        return
                    }
                    self.beginFilePreview(for: first, generation: generation)
                    return
                }

                guard let work = await self.runPreviewWorker({
                    .payload(ClipboardHistoryPreviewLoader.payloadPreview(
                        record: record,
                        payload: payload
                    ))
                }), case .payload(let result) = work else { return }
                guard !Task.isCancelled,
                      self.previewGeneration == generation,
                      self.selectedRecordID == selectedRecordID else { return }
                self.previewWorkerTask = nil
                self.previewTask = nil
                self.applyPayloadPreview(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.preview = .failure(error.localizedDescription)
            }
        }
    }

    private func applyPayloadPreview(_ result: ClipboardHistoryPayloadPreview) {
        switch result {
        case .text(let text):
            preview = .text(text)
        case .bitmap(let bitmap):
            let image = NSImage(
                cgImage: bitmap.image,
                size: NSSize(width: bitmap.image.width, height: bitmap.image.height)
            )
            preview = .image(
                image,
                pixelWidth: bitmap.pixelWidth,
                pixelHeight: bitmap.pixelHeight,
                pageCount: bitmap.pageCount
            )
        case .link(let url):
            preview = .link(url)
        case .unavailable(let message):
            preview = .failure(message)
        }
    }

    private func beginFilePreview(
        for item: ClipboardHistoryFilePreviewItem,
        generation: Int
    ) {
        guard item.isAvailable else {
            preview = .fileUnavailable(
                item,
                L10n.tr("没有可用的文件预览")
            )
            return
        }
        do {
            previewAccess = try FileSearchSecurityScopeResolver.resolve(
                containing: item.url
            )
        } catch {
            preview = .fileUnavailable(item, error.localizedDescription)
            return
        }

        if item.isDirectory {
            previewTask = Task { @MainActor [weak self] in
                guard let self,
                      let work = await self.runPreviewWorker({
                          .folder(ClipboardHistoryPreviewLoader.folderPreview(at: item.url))
                      }), case .folder(let folder) = work else { return }
                guard !Task.isCancelled,
                      self.previewGeneration == generation,
                      self.selectedFileID == item.id else { return }
                self.previewWorkerTask = nil
                self.previewTask = nil
                self.finishPreviewAccess()
                if let folder {
                    self.preview = .folder(item, folder)
                } else {
                    self.preview = .fileUnavailable(
                        item,
                        L10n.tr("此文件夹为空或当前无权读取内容")
                    )
                }
            }
            return
        }

        previewTask = Task { @MainActor [weak self] in
            guard let self,
                  let work = await self.runPreviewWorker({
                      .text(ClipboardHistoryPreviewLoader.textFilePreview(at: item.url))
                  }), case .text(let text) = work else { return }
            guard !Task.isCancelled,
                  self.previewGeneration == generation,
                  self.selectedFileID == item.id else { return }
            self.previewWorkerTask = nil
            self.previewTask = nil
            if let text {
                self.finishPreviewAccess()
                self.preview = .fileText(item, text)
            } else {
                self.loadQuickLookPreview(for: item, generation: generation)
            }
        }
    }

    private func loadQuickLookPreview(
        for item: ClipboardHistoryFilePreviewItem,
        generation: Int
    ) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 560, height: 390),
            scale: scale,
            representationTypes: .all
        )
        previewRequest = request
        previewTimeoutTask = Task { @MainActor [weak self, request] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try Task.checkCancellation()
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedFileID == item.id,
                      self.previewRequest === request else { return }
                QLThumbnailGenerator.shared.cancel(request)
                self.previewRequest = nil
                self.previewTimeoutTask = nil
                self.finishPreviewAccess()
                self.preview = .fileUnavailable(
                    item,
                    L10n.tr("文件预览生成超时")
                )
            } catch {
                return
            }
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] thumbnail, _ in
            let image = thumbnail?.cgImage
            Task { @MainActor [weak self, image] in
                guard let self,
                      self.previewGeneration == generation,
                      self.selectedFileID == item.id,
                      self.previewRequest === request else { return }
                self.previewTimeoutTask?.cancel()
                self.previewTimeoutTask = nil
                self.previewRequest = nil
                self.finishPreviewAccess()
                guard let image else {
                    self.preview = .fileUnavailable(
                        item,
                        L10n.tr("没有可用的文件预览")
                    )
                    return
                }
                self.preview = .fileImage(
                    item,
                    NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    )
                )
            }
        }
    }

    private func runPreviewWorker(
        _ operation: @escaping @Sendable () -> PreviewWorkerResult
    ) async -> PreviewWorkerResult? {
        let worker = Task<PreviewWorkerResult?, Never>.detached(
            priority: .userInitiated
        ) {
            guard !Task.isCancelled else { return nil }
            let result = operation()
            guard !Task.isCancelled else { return nil }
            return result
        }
        previewWorkerTask = worker
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func cancelPreviewWork(incrementGeneration: Bool) {
        previewTask?.cancel()
        previewTask = nil
        previewWorkerTask?.cancel()
        previewWorkerTask = nil
        previewTimeoutTask?.cancel()
        previewTimeoutTask = nil
        if let previewRequest {
            QLThumbnailGenerator.shared.cancel(previewRequest)
        }
        previewRequest = nil
        finishPreviewAccess()
        if incrementGeneration { previewGeneration &+= 1 }
    }

    private func finishPreviewAccess() {
        previewAccess?.stop()
        previewAccess = nil
    }

    private func refreshRelativeTimeLabels() {
        let now = Date()
        relativeTimeLabels = Dictionary(uniqueKeysWithValues: records.map {
            ($0.id, relativeDateFormatter.localizedString(for: $0.createdAt, relativeTo: now))
        })
    }

    private func startTimeRefresh() {
        guard timeRefreshTask == nil else { return }
        timeRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                self?.refreshRelativeTimeLabels()
            }
        }
    }
}
