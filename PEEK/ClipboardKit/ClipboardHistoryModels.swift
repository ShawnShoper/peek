import Foundation

enum ClipboardHistoryKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case image
    case files
    case link
    case pdf

    var title: String {
        switch self {
        case .text: return L10n.tr("文字")
        case .richText: return L10n.tr("富文本")
        case .image: return L10n.tr("图片")
        case .files: return L10n.tr("文件")
        case .link: return L10n.tr("链接")
        case .pdf: return "PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .link: return "link"
        case .pdf: return "doc.fill"
        }
    }
}

enum ClipboardHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case files
    case link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.tr("全部")
        case .text: return L10n.tr("文字")
        case .image: return L10n.tr("图片")
        case .files: return L10n.tr("文件")
        case .link: return L10n.tr("链接")
        }
    }

    func includes(_ kind: ClipboardHistoryKind) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            return kind == .text || kind == .richText
        case .image:
            return kind == .image
        case .files:
            return kind == .files || kind == .pdf
        case .link:
            return kind == .link
        }
    }
}

struct ClipboardHistoryRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: ClipboardHistoryKind
    let title: String
    let detail: String
    let sourceApplicationName: String?
    let sourceBundleIdentifier: String?
    let payloadFilename: String
    let byteCount: Int64
    let digest: String
}

struct ClipboardRepresentation: Codable, Equatable, Sendable {
    let type: String
    let data: Data
}

/// Binary-plist payload stored outside SQLite. Keeping large image bytes out of
/// the metadata database makes pruning predictable and avoids database growth
/// when users repeatedly copy screenshots.
struct ClipboardPayloadEnvelope: Codable, Equatable, Sendable {
    let representations: [ClipboardRepresentation]
    let fileURLs: [String]

    init(
        representations: [ClipboardRepresentation] = [],
        fileURLs: [String] = []
    ) {
        self.representations = representations
        self.fileURLs = fileURLs
    }

    func data(forType type: String) -> Data? {
        representations.first(where: { $0.type == type })?.data
    }

    /// Counts bytes already retained in memory before binary-plist encoding.
    /// The saturating additions keep a malformed or synthetic payload from
    /// overflowing and accidentally passing the store's safety limit.
    var rawContentByteCount: Int64 {
        var total: Int64 = 0
        for representation in representations {
            total = Self.saturatingAdd(total, representation.data.count)
        }
        for fileURL in fileURLs {
            total = Self.saturatingAdd(total, fileURL.utf8.count)
        }
        return total
    }

    private static func saturatingAdd(_ current: Int64, _ byteCount: Int) -> Int64 {
        guard byteCount <= Int(Int64.max) else { return Int64.max }
        let (result, overflow) = current.addingReportingOverflow(Int64(byteCount))
        return overflow ? Int64.max : result
    }
}

struct ClipboardHistoryCapture: Sendable {
    let capturedAt: Date
    let kind: ClipboardHistoryKind
    let title: String
    let detail: String
    let sourceApplicationName: String?
    let sourceBundleIdentifier: String?
    let payload: ClipboardPayloadEnvelope

    init(
        capturedAt: Date = Date(),
        kind: ClipboardHistoryKind,
        title: String,
        detail: String,
        sourceApplicationName: String?,
        sourceBundleIdentifier: String?,
        payload: ClipboardPayloadEnvelope
    ) {
        self.capturedAt = capturedAt
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.payload = payload
    }
}

struct ClipboardHistoryStorageSummary: Equatable, Sendable {
    let itemCount: Int
    let byteCount: Int64
}

struct ClipboardHistoryLimits: Equatable, Sendable {
    /// Caps both pasteboard materialization and previews for Finder selections.
    /// A single history record still preserves a useful multi-file operation
    /// without allowing thousands of file URLs to monopolize memory.
    static let maximumFileURLCount = 64

    static let standard = ClipboardHistoryLimits(
        maximumItemCount: 100,
        maximumTotalBytes: 256 * 1_024 * 1_024,
        maximumItemBytes: 32 * 1_024 * 1_024
    )

    let maximumItemCount: Int
    let maximumTotalBytes: Int64
    let maximumItemBytes: Int64
}

enum ClipboardHistoryError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case itemTooLarge(Int64)
    case unsupportedContent
    case payloadMissing
    case pasteboardWriteFailed
    case accessibilityRequired

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return L10n.tr("剪贴板历史暂不可用：%@", detail)
        case .itemTooLarge(let bytes):
            return L10n.tr("这条内容大小为 %@，超过单条 32 MB 的安全限制，未保存。", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .unsupportedContent:
            return L10n.tr("当前剪贴板内容类型暂不支持")
        case .payloadMissing:
            return L10n.tr("这条历史内容已损坏或被系统清理")
        case .pasteboardWriteFailed:
            return L10n.tr("无法将历史内容写回系统剪贴板")
        case .accessibilityRequired:
            return L10n.tr("内容已复制；允许辅助功能权限后才能自动粘贴到其他应用。")
        }
    }
}
