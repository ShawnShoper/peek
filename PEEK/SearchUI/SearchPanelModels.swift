import Foundation
import UniformTypeIdentifiers

/// UI-facing categories. Search backends can map these to a local index or any
/// later implementation without coupling the floating panel to its engine.
enum SearchPanelCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case applications
    case files
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.tr("全部")
        case .applications: return L10n.tr("应用")
        case .files: return L10n.tr("文件")
        case .folders: return L10n.tr("文件夹")
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .applications: return "app.dashed"
        case .files: return "doc"
        case .folders: return "folder"
        }
    }
}

struct SearchPanelMetadataField: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

struct SearchPanelItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let subtitle: String?
    let kindDescription: String
    let category: SearchPanelCategory
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedAt: Date?
    let applicationBundleIdentifier: String?
    let metadata: [SearchPanelMetadataField]

    init(
        id: String? = nil,
        url: URL,
        displayName: String? = nil,
        subtitle: String? = nil,
        kindDescription: String = L10n.tr("文件"),
        category: SearchPanelCategory = .all,
        isDirectory: Bool = false,
        fileSize: Int64? = nil,
        modifiedAt: Date? = nil,
        applicationBundleIdentifier: String? = nil,
        metadata: [SearchPanelMetadataField] = []
    ) {
        self.id = id ?? url.standardizedFileURL.path
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.subtitle = subtitle
        self.kindDescription = kindDescription
        self.category = category
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.metadata = metadata
    }
}

enum SearchPanelResultGroupKind: String, Identifiable, Sendable {
    case applications
    case documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: return L10n.tr("应用结果")
        case .documents: return L10n.tr("文档结果")
        }
    }
}

struct SearchPanelResultGroup: Identifiable, Sendable {
    let kind: SearchPanelResultGroupKind
    let items: [SearchPanelItem]

    var id: String { kind.id }
}

struct SearchPanelFolderEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let displayName: String
    let isDirectory: Bool

    var id: String { url.standardizedFileURL.path }
}

struct SearchPanelSystemSettingEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let destination: URL
}

struct SearchPanelTextPreview: Equatable, Sendable {
    let text: String
    let loadedByteCount: Int
    let totalByteCount: Int
    let requestedByteLimit: Int
    let requestedLineLimit: Int

    var isTruncated: Bool {
        loadedByteCount < totalByteCount
    }

    var canLoadMore: Bool {
        isTruncated
            && (requestedByteLimit < SearchPanelTextPreviewLoader.maximumByteLimit
                || requestedLineLimit < SearchPanelTextPreviewLoader.maximumLineLimit)
    }
}

enum SearchPanelTextPreviewLoader {
    static let initialByteLimit = 32 * 1_024
    static let byteIncrement = 32 * 1_024
    static let maximumByteLimit = 256 * 1_024
    static let initialLineLimit = 300
    static let lineIncrement = 300
    static let maximumLineLimit = 3_000

    static func load(
        at url: URL,
        byteLimit: Int = initialByteLimit,
        lineLimit: Int = initialLineLimit
    ) -> SearchPanelTextPreview? {
        guard supportsTextPreview(at: url) else { return nil }

        let effectiveByteLimit = min(max(byteLimit, 1), maximumByteLimit)
        let effectiveLineLimit = min(max(lineLimit, 1), maximumLineLimit)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let totalByteCount = (try? handle.seekToEnd()).map(Int.init) ?? 0
        try? handle.seek(toOffset: 0)
        guard let rawData = try? handle.read(upToCount: effectiveByteLimit),
              !rawData.isEmpty else {
            return SearchPanelTextPreview(
                text: L10n.tr("空文件"),
                loadedByteCount: 0,
                totalByteCount: totalByteCount,
                requestedByteLimit: effectiveByteLimit,
                requestedLineLimit: effectiveLineLimit
            )
        }
        guard !rawData.contains(0),
              let decoded = decode(rawData) else { return nil }

        let limitedText = prefix(decoded.text, lineLimit: effectiveLineLimit)
        let loadedByteCount: Int
        if limitedText.utf8.count < decoded.text.utf8.count {
            loadedByteCount = limitedText.utf8.count
        } else {
            loadedByteCount = decoded.byteCount
        }
        return SearchPanelTextPreview(
            text: limitedText,
            loadedByteCount: min(loadedByteCount, totalByteCount),
            totalByteCount: totalByteCount,
            requestedByteLimit: effectiveByteLimit,
            requestedLineLimit: effectiveLineLimit
        )
    }

    static func nextLimits(
        after preview: SearchPanelTextPreview
    ) -> (byteLimit: Int, lineLimit: Int) {
        (
            min(preview.requestedByteLimit + byteIncrement, maximumByteLimit),
            min(preview.requestedLineLimit + lineIncrement, maximumLineLimit)
        )
    }

    private static func supportsTextPreview(at url: URL) -> Bool {
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "conf", "config", "ini", "log",
            "json", "jsonl", "xml", "yaml", "yml", "csv", "tsv",
            "swift", "m", "mm", "h", "c", "cc", "cpp", "py", "js",
            "ts", "tsx", "jsx", "java", "kt", "kts", "go", "rs", "sh",
            "zsh", "bash", "fish", "rb", "php", "html", "css", "sql"
        ]
        let pathExtension = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: pathExtension)
        return textExtensions.contains(pathExtension)
            || type?.conforms(to: .text) == true
            || type?.conforms(to: .sourceCode) == true
    }

    private static func decode(_ data: Data) -> (text: String, byteCount: Int)? {
        if let text = String(data: data, encoding: .utf8) {
            return (text, data.count)
        }
        // A bounded UTF-8 chunk can end in the middle of a scalar. Trim only
        // the incomplete tail instead of falling back to a mojibake encoding.
        for trailingByteCount in 1 ... min(3, data.count) {
            let prefix = data.dropLast(trailingByteCount)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, prefix.count)
            }
        }
        if let text = String(data: data, encoding: .utf16) {
            return (text, data.count)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, data.count)
        }
        return nil
    }

    private static func prefix(_ text: String, lineLimit: Int) -> String {
        var newlineCount = 0
        for index in text.indices {
            guard text[index].isNewline else { continue }
            newlineCount += 1
            if newlineCount == lineLimit {
                return String(text[...index])
            }
        }
        return text
    }
}

enum SearchPanelPreviewKind: Equatable, Sendable {
    case loading
    case image
    case text(SearchPanelTextPreview)
    case folder([SearchPanelFolderEntry])
    case application
    case systemSettings([SearchPanelSystemSettingEntry])
    case unavailable(String)
}

/// Minimal adapter boundary between SearchUI and the search/indexing core.
/// The provider is MainActor-isolated so a backend can safely publish results;
/// expensive lookup work should be dispatched internally by its implementation.
@MainActor
protocol SearchPanelProviding: AnyObject {
    func search(
        query: String,
        category: SearchPanelCategory,
        includeHidden: Bool
    ) -> AsyncThrowingStream<SearchPanelSearchUpdate, Error>

    func didMoveItem(from sourceURL: URL, to destinationURL: URL) async throws
    func didCopyItem(to destinationURL: URL) async throws
}

struct SearchPanelSearchUpdate: Sendable {
    let items: [SearchPanelItem]
    let statusMessage: String?

    init(items: [SearchPanelItem], statusMessage: String? = nil) {
        self.items = items
        self.statusMessage = statusMessage
    }
}

extension SearchPanelProviding {
    func didMoveItem(from sourceURL: URL, to destinationURL: URL) async throws {}
    func didCopyItem(to destinationURL: URL) async throws {}
}

/// Closure-backed type erasure for adapting an existing core without making
/// its concrete store or result model visible to SearchUI.
@MainActor
final class AnySearchPanelProvider: SearchPanelProviding {
    typealias SearchHandler = @MainActor (
        _ query: String,
        _ category: SearchPanelCategory,
        _ includeHidden: Bool
    ) -> AsyncThrowingStream<SearchPanelSearchUpdate, Error>
    private let searchHandler: SearchHandler

    init(search: @escaping SearchHandler) {
        searchHandler = search
    }

    func search(
        query: String,
        category: SearchPanelCategory,
        includeHidden: Bool
    ) -> AsyncThrowingStream<SearchPanelSearchUpdate, Error> {
        searchHandler(query, category, includeHidden)
    }

}

enum SearchPanelActionError: LocalizedError, Sendable {
    case noSelection
    case destinationCancelled
    case destinationExists(String)
    case destinationNotWritable(String)
    case invalidDestination(String)
    case airDropUnavailable

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return L10n.tr("请先选择一个搜索结果")
        case .destinationCancelled:
            return L10n.tr("已取消选择目标文件夹")
        case .destinationExists(let name):
            return L10n.tr("目标位置已存在“%@”，未覆盖原文件", name)
        case .destinationNotWritable(let name):
            return L10n.tr("目标文件夹“%@”不可写", name)
        case .invalidDestination(let message):
            return message
        case .airDropUnavailable:
            return L10n.tr("当前 Mac 无法使用隔空投送")
        }
    }
}
