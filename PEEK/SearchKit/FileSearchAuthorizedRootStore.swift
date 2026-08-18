import Combine
import Foundation

enum FileSearchAuthorizedRootStatus: Equatable, Sendable {
    case authorized
    case reauthorizationRequired(String)
    case unavailable(String)

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }
}

struct FileSearchAuthorizedRoot: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL?
    let displayName: String
    let lastKnownPath: String
    let status: FileSearchAuthorizedRootStatus
}

enum FileSearchAuthorizationResult: Equatable, Sendable {
    case added(FileSearchAuthorizedRoot, removedNestedRoots: Int)
    case refreshed(FileSearchAuthorizedRoot, removedDuplicateRoots: Int)
    case coveredByExistingRoot(FileSearchAuthorizedRoot)

    var localizedDescription: String {
        switch self {
        case .added(let root, let removedNestedRoots):
            if removedNestedRoots > 0 {
                return L10n.tr(
                    "已授权“%@”，并移除 %d 个被其包含的重复目录",
                    root.displayName,
                    removedNestedRoots
                )
            }
            return L10n.tr("已授权“%@”", root.displayName)
        case .refreshed(let root, let removedDuplicateRoots):
            if removedDuplicateRoots > 0 {
                return L10n.tr(
                    "已更新“%@”的授权，并移除 %d 个重复目录",
                    root.displayName,
                    removedDuplicateRoots
                )
            }
            return L10n.tr("已更新“%@”的授权", root.displayName)
        case .coveredByExistingRoot(let root):
            return L10n.tr("该目录已包含在“%@”的授权范围内", root.displayName)
        }
    }
}

enum FileSearchAuthorizedRootError: LocalizedError, Equatable, Sendable {
    case notDirectory
    case rootNotFound
    case bookmarkCreationFailed(String)
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return L10n.tr("请选择一个文件夹")
        case .rootNotFound:
            return L10n.tr("授权目录不存在，请重新选择")
        case .bookmarkCreationFailed(let reason):
            return L10n.tr("无法保存目录授权：%@", reason)
        case .accessDenied(let path):
            return L10n.tr("无法访问“%@”，请重新授权", path)
        }
    }
}

/// A balanced security-scoped access lease. Keep the lease alive while an
/// index cycle reads `url`, then call `stop()` (or release the lease).
final class FileSearchSecurityScopedAccess: @unchecked Sendable {
    let rootID: UUID
    let url: URL

    private let lock = NSLock()
    private var isActive = true

    fileprivate init(rootID: UUID, url: URL) {
        self.rootID = rootID
        self.url = url
    }

    func stop() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
        lock.unlock()
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        stop()
    }
}

/// Owns the user-selected folders that the App Store sandbox permits the file
/// indexer to read. Querying this store never enumerates or indexes files.
@MainActor
final class FileSearchAuthorizedRootStore: ObservableObject {
    static let shared = FileSearchAuthorizedRootStore(
        onRootsChanged: {
            FileSearchIndexRuntime.shared.authorizedRootsDidChange()
        }
    )

    @Published private(set) var roots: [FileSearchAuthorizedRoot] = []
    @Published private(set) var persistenceMessage: String?

    private struct PersistedRoot: Codable, Equatable {
        let id: UUID
        var bookmarkData: Data
        var lastKnownPath: String
        var displayName: String
    }

    private struct PersistedState: Codable {
        let version: Int
        var roots: [PersistedRoot]
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let onRootsChanged: (() -> Void)?
    private var persistedRoots: [PersistedRoot]

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "fileSearch.authorizedRoots.v1",
        onRootsChanged: (() -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.onRootsChanged = onRootsChanged
        persistedRoots = []
        loadPersistedRoots()
        refresh(notifyChanges: false)
    }

    @discardableResult
    func addRoot(_ url: URL) throws -> FileSearchAuthorizationResult {
        try authorize(url, replacing: nil)
    }

    @discardableResult
    func reauthorizeRoot(
        id: UUID,
        with url: URL
    ) throws -> FileSearchAuthorizationResult {
        guard persistedRoots.contains(where: { $0.id == id }) else {
            throw FileSearchAuthorizedRootError.rootNotFound
        }
        return try authorize(url, replacing: id)
    }

    func removeRoot(id: UUID) {
        guard let index = persistedRoots.firstIndex(where: { $0.id == id }) else { return }
        persistedRoots.remove(at: index)
        persistAndRefresh()
    }

    /// Resolves every currently valid bookmark and starts security-scoped
    /// access. Invalid or stale-unrefreshable roots are omitted.
    func resolveScopedAccess() -> [FileSearchSecurityScopedAccess] {
        let authorizedIDs = Set(roots.compactMap { root in
            root.status.isAuthorized ? root.id : nil
        })
        return persistedRoots.compactMap { persisted in
            guard authorizedIDs.contains(persisted.id) else { return nil }
            return try? makeScopedAccess(from: persisted)
        }
    }

    func resolveScopedAccess(for id: UUID) throws -> FileSearchSecurityScopedAccess {
        guard roots.contains(where: { $0.id == id && $0.status.isAuthorized }),
              let persisted = persistedRoots.first(where: { $0.id == id }) else {
            throw FileSearchAuthorizedRootError.rootNotFound
        }
        return try makeScopedAccess(from: persisted)
    }

    /// Returns nil only when the item is outside every user-authorized root.
    /// If a matching bookmark exists but cannot be restored, this throws so a
    /// stale SQLite row cannot silently bypass sandbox authorization.
    func resolveScopedAccess(
        containing itemURL: URL
    ) throws -> FileSearchSecurityScopedAccess? {
        let itemPath = itemURL.standardizedFileURL.path
        guard let persisted = persistedRoots
            .filter({ Self.path(itemPath, isEqualToOrDescendantOf: $0.lastKnownPath) })
            .max(by: { $0.lastKnownPath.count < $1.lastKnownPath.count }) else {
            return nil
        }
        guard roots.contains(where: {
            $0.id == persisted.id && $0.status.isAuthorized
        }) else {
            throw FileSearchAuthorizedRootError.accessDenied(persisted.lastKnownPath)
        }
        return try makeScopedAccess(from: persisted)
    }

    /// Re-resolves bookmarks and replaces stale bookmark data when macOS still
    /// grants access to the resolved folder.
    func refresh(notifyChanges: Bool = true) {
        let previousRoots = roots
        var didUpdateBookmark = false
        var resolvedRoots: [FileSearchAuthorizedRoot] = []
        resolvedRoots.reserveCapacity(persistedRoots.count)

        for index in persistedRoots.indices {
            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: persistedRoots[index].bookmarkData,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    resolvedRoots.append(makeRoot(
                        from: persistedRoots[index],
                        url: resolvedURL,
                        status: .reauthorizationRequired(L10n.tr("无法恢复目录访问权限，请重新授权"))
                    ))
                    continue
                }
                defer { resolvedURL.stopAccessingSecurityScopedResource() }
                let url = Self.normalizedDirectoryURL(resolvedURL)
                guard Self.directoryExists(at: url) else {
                    resolvedRoots.append(makeRoot(
                        from: persistedRoots[index],
                        url: url,
                        status: .unavailable(L10n.tr("目录当前不可用或已被移除"))
                    ))
                    continue
                }

                if isStale {
                    do {
                        let refreshedBookmark = try Self.makeBookmark(for: url)
                        persistedRoots[index].bookmarkData = refreshedBookmark
                        didUpdateBookmark = true
                    } catch {
                        resolvedRoots.append(makeRoot(
                            from: persistedRoots[index],
                            url: url,
                            status: .reauthorizationRequired(L10n.tr("目录授权已过期，请重新授权"))
                        ))
                        continue
                    }
                }

                // A security-scoped bookmark may follow a moved/renamed
                // folder without being reported as stale. Keep containment
                // matching aligned with the live resolved URL either way.
                if persistedRoots[index].lastKnownPath != url.path {
                    persistedRoots[index].lastKnownPath = url.path
                    persistedRoots[index].displayName = Self.displayName(for: url)
                    didUpdateBookmark = true
                }

                resolvedRoots.append(makeRoot(
                    from: persistedRoots[index],
                    url: url,
                    status: .authorized
                ))
            } catch {
                resolvedRoots.append(makeRoot(
                    from: persistedRoots[index],
                    url: nil,
                    status: .reauthorizationRequired(L10n.tr("无法恢复目录授权，请重新授权"))
                ))
            }
        }

        let deduplicatedRoots = Self.deduplicatedResolvedRoots(resolvedRoots)
        let retainedIDs = Set(deduplicatedRoots.map(\.id))
        if retainedIDs.count != persistedRoots.count {
            persistedRoots.removeAll { !retainedIDs.contains($0.id) }
            didUpdateBookmark = true
        }
        roots = deduplicatedRoots
            .sorted { $0.lastKnownPath.localizedStandardCompare($1.lastKnownPath) == .orderedAscending }
        if didUpdateBookmark {
            persist()
        }
        if notifyChanges,
           didUpdateBookmark || previousRoots != roots {
            onRootsChanged?()
        }
    }

    private func authorize(
        _ selectedURL: URL,
        replacing rootID: UUID?
    ) throws -> FileSearchAuthorizationResult {
        let url = Self.normalizedDirectoryURL(selectedURL)
        guard Self.directoryExists(at: url) else {
            throw FileSearchAuthorizedRootError.notDirectory
        }

        let bookmarkData: Data
        do {
            bookmarkData = try Self.makeBookmark(for: url)
        } catch {
            throw FileSearchAuthorizedRootError.bookmarkCreationFailed(error.localizedDescription)
        }

        let selectedPath = url.path
        let candidates = persistedRoots.filter { $0.id != rootID }

        if let coveringRoot = candidates.first(where: {
            Self.path(selectedPath, isEqualToOrDescendantOf: $0.lastKnownPath)
        }) {
            if selectedPath == coveringRoot.lastKnownPath {
                let removedCount = persistedRoots.count - candidates.count
                persistedRoots.removeAll { $0.id == rootID || $0.id == coveringRoot.id }
                let updated = PersistedRoot(
                    id: coveringRoot.id,
                    bookmarkData: bookmarkData,
                    lastKnownPath: selectedPath,
                    displayName: Self.displayName(for: url)
                )
                persistedRoots.append(updated)
                persistAndRefresh()
                let root = roots.first(where: { $0.id == updated.id })
                    ?? makeRoot(from: updated, url: url, status: .authorized)
                return .refreshed(root, removedDuplicateRoots: removedCount)
            }

            if let rootID {
                persistedRoots.removeAll { $0.id == rootID }
                persistAndRefresh()
            }
            let root = roots.first(where: { $0.id == coveringRoot.id })
                ?? makeRoot(from: coveringRoot, url: nil, status: .authorized)
            return .coveredByExistingRoot(root)
        }

        let nestedIDs = Set(candidates.filter {
            Self.path($0.lastKnownPath, isEqualToOrDescendantOf: selectedPath)
        }.map(\.id))
        let removedNestedCount = nestedIDs.count
        persistedRoots.removeAll {
            $0.id == rootID || nestedIDs.contains($0.id)
        }

        let newID = rootID ?? UUID()
        let persisted = PersistedRoot(
            id: newID,
            bookmarkData: bookmarkData,
            lastKnownPath: selectedPath,
            displayName: Self.displayName(for: url)
        )
        persistedRoots.append(persisted)
        persistAndRefresh()
        let root = roots.first(where: { $0.id == newID })
            ?? makeRoot(from: persisted, url: url, status: .authorized)
        if rootID == nil {
            return .added(root, removedNestedRoots: removedNestedCount)
        }
        return .refreshed(root, removedDuplicateRoots: removedNestedCount)
    }

    private func loadPersistedRoots() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            persistedRoots = []
            persistenceMessage = nil
            return
        }
        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            persistedRoots = state.roots.filter {
                !FileSearchAccountHome.isPEEKSandboxPath($0.lastKnownPath)
            }
            persistenceMessage = nil
            if persistedRoots.count != state.roots.count {
                persist()
            }
        } catch {
            persistedRoots = []
            persistenceMessage = L10n.tr("授权目录配置无法读取，请重新添加目录")
        }
    }

    private func persistAndRefresh() {
        persist()
        refresh(notifyChanges: false)
        onRootsChanged?()
    }

    private func makeScopedAccess(
        from persisted: PersistedRoot
    ) throws -> FileSearchSecurityScopedAccess {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: persisted.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw FileSearchAuthorizedRootError.accessDenied(persisted.lastKnownPath)
        }
        guard !isStale,
              resolvedURL.startAccessingSecurityScopedResource() else {
            throw FileSearchAuthorizedRootError.accessDenied(persisted.lastKnownPath)
        }
        return FileSearchSecurityScopedAccess(
            rootID: persisted.id,
            url: resolvedURL
        )
    }

    private func persist() {
        do {
            let state = PersistedState(version: 1, roots: persistedRoots)
            let data = try JSONEncoder().encode(state)
            userDefaults.set(data, forKey: storageKey)
            persistenceMessage = nil
        } catch {
            persistenceMessage = L10n.tr(
                "授权目录配置保存失败：%@",
                error.localizedDescription
            )
        }
    }

    private func makeRoot(
        from persisted: PersistedRoot,
        url: URL?,
        status: FileSearchAuthorizedRootStatus
    ) -> FileSearchAuthorizedRoot {
        FileSearchAuthorizedRoot(
            id: persisted.id,
            url: url,
            displayName: url.map(Self.displayName(for:)) ?? persisted.displayName,
            lastKnownPath: url?.path ?? persisted.lastKnownPath,
            status: status
        )
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )
    }

    private static func normalizedDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func displayName(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.lastPathComponent : name
    }

    private static func path(
        _ candidate: String,
        isEqualToOrDescendantOf root: String
    ) -> Bool {
        if root == "/" { return candidate.hasPrefix("/") }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Persisted data is also normalized at authorization time, but this
    /// protects upgrades or manually corrupted defaults from exposing nested
    /// duplicate roots to the indexer.
    private static func deduplicatedResolvedRoots(
        _ roots: [FileSearchAuthorizedRoot]
    ) -> [FileSearchAuthorizedRoot] {
        roots.sorted { $0.lastKnownPath.count < $1.lastKnownPath.count }
            .reduce(into: []) { result, root in
                guard !result.contains(where: {
                    path(root.lastKnownPath, isEqualToOrDescendantOf: $0.lastKnownPath)
                }) else { return }
                result.append(root)
            }
    }
}
