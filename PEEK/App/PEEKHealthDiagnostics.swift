import Foundation

enum PEEKHealthSeverity: Int, Comparable, Sendable {
    case healthy
    case warning
    case error

    static func < (lhs: PEEKHealthSeverity, rhs: PEEKHealthSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PEEKHealthCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let severity: PEEKHealthSeverity
}

/// A deliberately redacted snapshot of runtime health. It contains counts and
/// permission states only; file paths, clipboard contents, search terms,
/// screenshots and translation credentials must never enter this type.
struct PEEKDiagnosticsSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let version: String
    let bundleIdentifier: String
    let systemVersion: String
    let architecture: String
    let displayDescriptions: [String]
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let hotKeyStatuses: [String: String]
    let hotKeyFailureCount: Int
    let indexPhase: String
    let indexedItemCount: Int
    let committedRootCount: Int
    let indexingRootCount: Int
    let inaccessibleLocationCount: Int
    let authorizedDocumentRootCount: Int
    let configuredDocumentRootCount: Int
    let clipboardHistoryEnabled: Bool
    let clipboardItemCount: Int
    let clipboardByteCount: Int64
}

enum PEEKHealthDiagnostics {
    static func checks(for snapshot: PEEKDiagnosticsSnapshot) -> [PEEKHealthCheck] {
        let captureSeverity: PEEKHealthSeverity = snapshot.screenRecordingGranted
            ? .healthy
            : .error
        let scrollingSeverity: PEEKHealthSeverity
        if !snapshot.screenRecordingGranted {
            scrollingSeverity = .error
        } else if !snapshot.accessibilityGranted {
            scrollingSeverity = .warning
        } else {
            scrollingSeverity = .healthy
        }
        let indexSeverity: PEEKHealthSeverity
        if snapshot.indexPhase == FileSearchIndexPhase.ready.rawValue
            || snapshot.indexPhase == FileSearchIndexPhase.limited.rawValue {
            indexSeverity = snapshot.inaccessibleLocationCount > 0 ? .warning : .healthy
        } else if snapshot.indexedItemCount > 0 {
            indexSeverity = .warning
        } else {
            indexSeverity = .error
        }
        let authorizationSeverity: PEEKHealthSeverity =
            snapshot.authorizedDocumentRootCount >= snapshot.configuredDocumentRootCount
                ? .healthy
                : .warning

        return [
            PEEKHealthCheck(
                id: "capture",
                title: L10n.tr("截图权限"),
                detail: snapshot.screenRecordingGranted
                    ? L10n.tr("屏幕录制权限已就绪")
                    : L10n.tr("未获得屏幕录制权限，截图与 OCR 暂不可用"),
                severity: captureSeverity
            ),
            PEEKHealthCheck(
                id: "scrolling",
                title: L10n.tr("滚动截图控制"),
                detail: snapshot.accessibilityGranted
                    ? L10n.tr("辅助功能权限已就绪")
                    : L10n.tr("未获得辅助功能权限，只能使用手动滚动模式"),
                severity: scrollingSeverity
            ),
            PEEKHealthCheck(
                id: "hotkeys",
                title: L10n.tr("全局快捷键"),
                detail: snapshot.hotKeyFailureCount == 0
                    ? L10n.tr("全部已配置快捷键均已注册")
                    : L10n.tr("%d 个快捷键存在冲突或注册失败", snapshot.hotKeyFailureCount),
                severity: snapshot.hotKeyFailureCount == 0 ? .healthy : .warning
            ),
            PEEKHealthCheck(
                id: "index",
                title: L10n.tr("文件索引"),
                detail: L10n.tr("%@ · %d 项", snapshot.indexPhase, snapshot.indexedItemCount),
                severity: indexSeverity
            ),
            PEEKHealthCheck(
                id: "directories",
                title: L10n.tr("搜索目录授权"),
                detail: L10n.tr(
                    "%d/%d 个目录已授权或已包含",
                    snapshot.authorizedDocumentRootCount,
                    snapshot.configuredDocumentRootCount
                ),
                severity: authorizationSeverity
            ),
            PEEKHealthCheck(
                id: "clipboard",
                title: L10n.tr("剪贴板历史"),
                detail: snapshot.clipboardHistoryEnabled
                    ? L10n.tr("已启用 · %d 条记录", snapshot.clipboardItemCount)
                    : L10n.tr("已停用，已有记录仍保留在本机"),
                severity: .healthy
            )
        ]
    }

    static func report(for snapshot: PEEKDiagnosticsSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        let hotKeys = snapshot.hotKeyStatuses.keys.sorted().map {
            "  \($0): \(snapshot.hotKeyStatuses[$0] ?? "unknown")"
        }
        return ([
            "PEEK Diagnostics (redacted)",
            "Generated: \(formatter.string(from: snapshot.generatedAt))",
            "Version: \(snapshot.version)",
            "Bundle: \(snapshot.bundleIdentifier)",
            "macOS: \(snapshot.systemVersion)",
            "Architecture: \(snapshot.architecture)",
            "Displays: \(snapshot.displayDescriptions.joined(separator: ", "))",
            "Screen recording: \(snapshot.screenRecordingGranted ? "granted" : "missing")",
            "Accessibility: \(snapshot.accessibilityGranted ? "granted" : "missing")",
            "Hot keys:",
        ] + hotKeys + [
            "Index phase: \(snapshot.indexPhase)",
            "Index items: \(snapshot.indexedItemCount)",
            "Committed roots: \(snapshot.committedRootCount)",
            "Indexing roots: \(snapshot.indexingRootCount)",
            "Inaccessible locations: \(snapshot.inaccessibleLocationCount)",
            "Authorized document roots: \(snapshot.authorizedDocumentRootCount)/\(snapshot.configuredDocumentRootCount)",
            "Clipboard history: \(snapshot.clipboardHistoryEnabled ? "enabled" : "disabled")",
            "Clipboard records: \(snapshot.clipboardItemCount)",
            "Clipboard storage bytes: \(snapshot.clipboardByteCount)",
            "",
            "Privacy: no file paths, file contents, clipboard contents, search terms, screenshots, or credentials are included."
        ]).joined(separator: "\n")
    }
}
