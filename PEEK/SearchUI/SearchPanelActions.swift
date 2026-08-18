import AppKit
import Foundation

@MainActor
private final class SearchPanelAirDropSession: NSObject, NSSharingServiceDelegate {
    private let service: NSSharingService
    private var continuation: CheckedContinuation<Void, Error>?

    init(service: NSSharingService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    func share(_ items: [Any]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            service.perform(withItems: items)
        }
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didShareItems items: [Any]
    ) {
        finish(.success(()))
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        service.delegate = nil
        continuation.resume(with: result)
    }
}

enum SearchPanelFileAction: String, CaseIterable, Identifiable, Sendable {
    case open
    case copyItem
    case revealInFinder
    case copyPath
    case moveTo
    case copyTo
    case airDrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return L10n.tr("打开")
        case .revealInFinder: return L10n.tr("在访达显示")
        case .copyItem: return L10n.tr("复制")
        case .copyPath: return L10n.tr("复制路径")
        case .moveTo: return L10n.tr("移动到…")
        case .copyTo: return L10n.tr("复制到…")
        case .airDrop: return L10n.tr("隔空投送")
        }
    }

    var systemImage: String {
        switch self {
        case .open: return "arrow.up.forward.app"
        case .revealInFinder: return "folder"
        case .copyItem: return "doc.on.doc"
        case .copyPath: return "link"
        case .moveTo: return "folder.badge.plus"
        case .copyTo: return "square.on.square"
        case .airDrop: return "airplayaudio"
        }
    }
}

struct SearchPanelActionFeedback: Equatable, Sendable {
    let message: String
    let updatedURL: URL?

    init(_ message: String, updatedURL: URL? = nil) {
        self.message = message
        self.updatedURL = updatedURL
    }
}

struct SearchPanelActionCapability: Equatable, Sendable {
    let isEnabled: Bool
    let reason: String?

    static let enabled = SearchPanelActionCapability(isEnabled: true, reason: nil)

    static func disabled(_ reason: String) -> SearchPanelActionCapability {
        SearchPanelActionCapability(isEnabled: false, reason: reason)
    }
}

@MainActor
protocol SearchPanelActionHandling: AnyObject {
    func capability(
        for action: SearchPanelFileAction,
        item: SearchPanelItem
    ) -> SearchPanelActionCapability

    func capabilities(
        for item: SearchPanelItem
    ) async -> [SearchPanelFileAction: SearchPanelActionCapability]

    func perform(
        _ action: SearchPanelFileAction,
        item: SearchPanelItem
    ) async throws -> SearchPanelActionFeedback
}

extension SearchPanelActionHandling {
    func capability(
        for action: SearchPanelFileAction,
        item: SearchPanelItem
    ) -> SearchPanelActionCapability {
        .enabled
    }

    func capabilities(
        for item: SearchPanelItem
    ) async -> [SearchPanelFileAction: SearchPanelActionCapability] {
        Dictionary(uniqueKeysWithValues: SearchPanelFileAction.allCases
            .map { ($0, capability(for: $0, item: item)) })
    }
}

/// Native default actions. Copy and move are deliberately fail-closed: an
/// existing destination is never overwritten without a dedicated conflict UI.
@MainActor
final class DefaultSearchPanelActionHandler: SearchPanelActionHandling {
    func capabilities(
        for item: SearchPanelItem
    ) async -> [SearchPanelFileAction: SearchPanelActionCapability] {
        let actions = SearchPanelFileAction.allCases
        let sourceAccess: FileSearchSecurityScopedAccess?
        do {
            sourceAccess = try FileSearchSecurityScopeResolver.resolve(
                containing: item.url
            )
        } catch {
            let unavailable = SearchPanelActionCapability.disabled(error.localizedDescription)
            return Dictionary(uniqueKeysWithValues: actions.map { ($0, unavailable) })
        }
        defer { sourceAccess?.stop() }

        let url = item.url
        let protected = Self.isProtectedSystemItem(url)
        let fileState = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            return (
                exists: manager.fileExists(atPath: url.path),
                parentWritable: manager.isWritableFile(
                    atPath: url.deletingLastPathComponent().path
                )
            )
        }.value

        guard fileState.exists else {
            let missing = SearchPanelActionCapability.disabled(
                L10n.tr("文件已不存在，请刷新搜索结果")
            )
            return Dictionary(uniqueKeysWithValues: actions.map { ($0, missing) })
        }

        let moveCapability: SearchPanelActionCapability
        if protected {
            moveCapability = .disabled(L10n.tr("系统应用或系统文件不能从这里移动"))
        } else if !fileState.parentWritable {
            moveCapability = .disabled(L10n.tr("文件所在位置为只读，不能移动"))
        } else {
            moveCapability = .enabled
        }
        let airDropCapability: SearchPanelActionCapability =
            NSSharingService(named: .sendViaAirDrop) == nil
                ? .disabled(L10n.tr("当前 Mac 无法使用隔空投送"))
                : .enabled

        return Dictionary(uniqueKeysWithValues: actions.map { action in
            switch action {
            case .moveTo: return (action, moveCapability)
            case .airDrop: return (action, airDropCapability)
            default: return (action, .enabled)
            }
        })
    }

    func capability(
        for action: SearchPanelFileAction,
        item: SearchPanelItem
    ) -> SearchPanelActionCapability {
        let sourceAccess: FileSearchSecurityScopedAccess?
        do {
            sourceAccess = try FileSearchSecurityScopeResolver.resolve(
                containing: item.url
            )
        } catch {
            return .disabled(error.localizedDescription)
        }
        defer { sourceAccess?.stop() }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: item.url.path) else {
            return .disabled(L10n.tr("文件已不存在，请刷新搜索结果"))
        }

        switch action {
        case .moveTo:
            if Self.isProtectedSystemItem(item.url) {
                return .disabled(L10n.tr("系统应用或系统文件不能从这里移动"))
            }
            let parent = item.url.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: parent.path) else {
                return .disabled(L10n.tr("文件所在位置为只读，不能移动"))
            }
            return .enabled
        case .airDrop:
            return NSSharingService(named: .sendViaAirDrop) == nil
                ? .disabled(L10n.tr("当前 Mac 无法使用隔空投送"))
                : .enabled
        default:
            return .enabled
        }
    }

    func perform(
        _ action: SearchPanelFileAction,
        item: SearchPanelItem
    ) async throws -> SearchPanelActionFeedback {
        let sourceAccess = try FileSearchSecurityScopeResolver.resolve(
            containing: item.url
        )
        defer { sourceAccess?.stop() }

        switch action {
        case .open:
            guard NSWorkspace.shared.open(item.url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SearchPanelActionFeedback(L10n.tr("已打开 %@", item.displayName))

        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            return SearchPanelActionFeedback(L10n.tr("已在访达中显示"))

        case .copyItem:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item.url as NSURL]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return SearchPanelActionFeedback(L10n.tr("已复制文件"))

        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(item.url.path, forType: .string) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return SearchPanelActionFeedback(L10n.tr("已复制路径"))

        case .moveTo:
            let folder = try chooseDestinationFolder(prompt: L10n.tr("移动到此处"))
            // Powerbox already starts security-scoped access for URLs returned
            // by NSOpenPanel. Balance that grant exactly once after the file
            // operation; starting it again here would leak one scope.
            defer { folder.stopAccessingSecurityScopedResource() }
            let destination = folder.appendingPathComponent(
                item.url.lastPathComponent,
                isDirectory: item.isDirectory
            )
            try validateDestinationFolder(folder, source: item)
            try await Self.runFileOperation(
                source: item.url,
                destination: destination,
                shouldMove: true
            )
            return SearchPanelActionFeedback(
                L10n.tr("已移动到 %@", folder.lastPathComponent),
                updatedURL: destination
            )

        case .copyTo:
            let folder = try chooseDestinationFolder(prompt: L10n.tr("复制到此处"))
            defer { folder.stopAccessingSecurityScopedResource() }
            let destination = folder.appendingPathComponent(
                item.url.lastPathComponent,
                isDirectory: item.isDirectory
            )
            try validateDestinationFolder(folder, source: item)
            try await Self.runFileOperation(
                source: item.url,
                destination: destination,
                shouldMove: false
            )
            return SearchPanelActionFeedback(
                L10n.tr("已复制到 %@", folder.lastPathComponent),
                updatedURL: destination
            )

        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                throw SearchPanelActionError.airDropUnavailable
            }
            let shareSession = SearchPanelAirDropSession(service: service)
            try await shareSession.share([item.url])
            return SearchPanelActionFeedback(L10n.tr("隔空投送已完成"))

        }
    }

    private func chooseDestinationFolder(prompt: String) throws -> URL {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择目标文件夹")
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            throw SearchPanelActionError.destinationCancelled
        }
        return url
    }

    private func validateDestinationFolder(
        _ folder: URL,
        source item: SearchPanelItem
    ) throws {
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw SearchPanelActionError.destinationNotWritable(folder.lastPathComponent)
        }
        guard item.isDirectory else { return }

        let sourcePath = item.url.resolvingSymlinksInPath().standardizedFileURL.path
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard folderPath != sourcePath,
              !folderPath.hasPrefix(sourcePath + "/") else {
            throw SearchPanelActionError.invalidDestination(
                L10n.tr("不能把文件夹移动或复制到它自身内部")
            )
        }
    }

    private nonisolated static func runFileOperation(
        source: URL,
        destination: URL,
        shouldMove: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw SearchPanelActionError.destinationExists(destination.lastPathComponent)
            }
            if shouldMove {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
        }.value
    }

    private nonisolated static func isProtectedSystemItem(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let protectedRoots = ["/System", "/bin", "/sbin", "/usr"]
        return protectedRoots.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }
}
