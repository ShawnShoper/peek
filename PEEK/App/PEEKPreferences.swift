import Foundation
import SwiftUI

enum PEEKPreferenceKey {
    static let searchDefaultCategory = "search.defaultCategory"
    static let searchIncludeHidden = "search.includeHidden"
    static let searchResultLimit = "search.resultLimit"
    static let searchRetainsLastQuery = "search.retainsLastQuery"
    static let searchLastQuery = "search.lastQuery"
    static let searchWindowScreen = "search.windowScreen"
    static let searchWindowPosition = "search.windowPosition"
    static let searchWindowOpacity = "search.windowOpacity"
    static let searchShowsPreview = "search.showsPreview"
    static let searchResultDensity = "search.resultDensity"
    static let appearanceMode = "appearance.mode"
    static let appLanguage = "app.language"
    static let exclusionPaths = "search.exclusions.paths"
    static let applicationRootPaths = "search.applicationRoots.paths"
    static let documentDefaultRootPaths = "search.documentDefaultRoots.paths"
    static let didPresentDocumentAuthorization = "search.documentAuthorization.presented"
    static let openDocumentSearchSettings = "settings.openDocumentSearch"
}

enum SearchWindowScreenPreference: String, CaseIterable, Identifiable, Sendable {
    case mouse
    case main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: return L10n.tr("鼠标所在屏幕")
        case .main: return L10n.tr("主屏幕")
        }
    }
}

enum SearchWindowPositionPreference: String, CaseIterable, Identifiable, Sendable {
    case centered
    case remembered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centered: return L10n.tr("始终居中")
        case .remembered: return L10n.tr("记住上次位置")
        }
    }
}

enum PEEKAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统")
        case .light: return L10n.tr("浅色")
        case .dark: return L10n.tr("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SearchResultDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return L10n.tr("紧凑")
        case .standard: return L10n.tr("标准")
        }
    }
}

struct SearchPanelPreferences: Equatable, Sendable {
    var defaultCategory: SearchPanelCategory
    var includesHiddenFiles: Bool
    var resultLimit: Int
    var retainsLastQuery: Bool
    var showsPreview: Bool
    var density: SearchResultDensity
    var appearance: PEEKAppearanceMode
    var screen: SearchWindowScreenPreference
    var position: SearchWindowPositionPreference
    var windowOpacity: Double

    static func current(defaults: UserDefaults = .standard) -> SearchPanelPreferences {
        let configuredLimit = defaults.integer(forKey: PEEKPreferenceKey.searchResultLimit)
        return SearchPanelPreferences(
            // Every newly opened search panel starts from the complete result
            // set. Older builds persisted `.applications`; intentionally
            // ignore that stale value instead of reopening on a filtered tab.
            defaultCategory: .all,
            includesHiddenFiles: defaults.bool(
                forKey: PEEKPreferenceKey.searchIncludeHidden
            ),
            resultLimit: min(max(configuredLimit == 0 ? 80 : configuredLimit, 20), 200),
            retainsLastQuery: defaults.bool(
                forKey: PEEKPreferenceKey.searchRetainsLastQuery
            ),
            showsPreview: defaults.object(
                forKey: PEEKPreferenceKey.searchShowsPreview
            ) == nil
                ? true
                : defaults.bool(forKey: PEEKPreferenceKey.searchShowsPreview),
            density: SearchResultDensity(
                rawValue: defaults.string(
                    forKey: PEEKPreferenceKey.searchResultDensity
                ) ?? ""
            ) ?? .standard,
            appearance: PEEKAppearanceMode(
                rawValue: defaults.string(forKey: PEEKPreferenceKey.appearanceMode) ?? ""
            ) ?? .system,
            screen: SearchWindowScreenPreference(
                rawValue: defaults.string(forKey: PEEKPreferenceKey.searchWindowScreen) ?? ""
            ) ?? .mouse,
            position: SearchWindowPositionPreference(
                rawValue: defaults.string(forKey: PEEKPreferenceKey.searchWindowPosition) ?? ""
            ) ?? .centered,
            windowOpacity: min(
                1,
                max(
                    0.6,
                    defaults.object(forKey: PEEKPreferenceKey.searchWindowOpacity) == nil
                        ? 0.92
                        : defaults.double(forKey: PEEKPreferenceKey.searchWindowOpacity)
                )
            )
        )
    }
}

struct FileSearchExclusionPolicy: Equatable, Sendable {
    var paths: [String]

    init(paths: [String]) {
        self.paths = Self.normalizedPaths(paths)
    }

    static func current(defaults: UserDefaults = .standard) -> FileSearchExclusionPolicy {
        FileSearchExclusionPolicy(
            paths: defaults.stringArray(forKey: PEEKPreferenceKey.exclusionPaths) ?? []
        )
    }

    func excludes(_ url: URL, isDirectory: Bool) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        if paths.contains(where: {
            standardizedPath == $0 || standardizedPath.hasPrefix($0 + "/")
        }) {
            return true
        }
        return false
    }

    private static func normalizedPaths(_ values: [String]) -> [String] {
        uniqueSorted(values.compactMap { value in
            let expanded = NSString(string: value)
                .expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        })
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { left, right in
            left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}

@MainActor
final class FileSearchExclusionSettings: ObservableObject {
    static let shared = FileSearchExclusionSettings()

    @Published private(set) var policy: FileSearchExclusionPolicy
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        policy = .current(defaults: defaults)
    }

    func addPath(_ path: String) {
        update(paths: policy.paths + [path])
    }

    func removePath(_ path: String) {
        update(paths: policy.paths.filter { $0 != path })
    }

    func removeAll() {
        persist(FileSearchExclusionPolicy(paths: []))
    }

    private func update(paths: [String]) {
        persist(FileSearchExclusionPolicy(paths: paths))
    }

    private func persist(_ newPolicy: FileSearchExclusionPolicy) {
        guard newPolicy != policy else { return }
        policy = newPolicy
        defaults.set(newPolicy.paths, forKey: PEEKPreferenceKey.exclusionPaths)
        FileSearchIndexRuntime.shared.authorizedRootsDidChange()
    }
}

struct FileSearchDocumentDefaultRoot: Identifiable, Equatable, Sendable {
    let title: String
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var displayPath: String {
        let userHome = FileSearchAccountHome.url.path
        if path == userHome { return "~" }
        if path.hasPrefix(userHome + "/") {
            return "~" + String(path.dropFirst(userHome.count))
        }
        return path
    }
}

/// App Sandbox rewrites Foundation's home directory to
/// `~/Library/Containers/<bundle>/Data`. Search defaults must point at the
/// login account's real home so the Powerbox opens Documents/Desktop/Downloads
/// instead of PEEK's private container.
enum FileSearchAccountHome {
    static var url: URL {
        resolve(
            sandboxHomePath: NSHomeDirectory(),
            directoryServicePath: NSHomeDirectoryForUser(NSUserName())
        )
    }

    static func resolve(
        sandboxHomePath: String,
        directoryServicePath: String?
    ) -> URL {
        let candidates = [directoryServicePath, sandboxHomePath].compactMap { $0 }
        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate, isDirectory: true)
                .standardizedFileURL.path
            if let range = standardized.range(of: "/Library/Containers/") {
                return URL(
                    fileURLWithPath: String(standardized[..<range.lowerBound]),
                    isDirectory: true
                )
            }
        }
        return URL(
            fileURLWithPath: candidates.first ?? sandboxHomePath,
            isDirectory: true
        ).standardizedFileURL
    }

    static func isPEEKSandboxPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        return normalized.contains(
            "/Library/Containers/com.shawnshoper.peek/Data"
        )
    }
}

enum FileSearchDocumentRootAuthorization {
    static func exactRoot(
        for defaultRoot: FileSearchDocumentDefaultRoot,
        in authorizedRoots: [FileSearchAuthorizedRoot]
    ) -> FileSearchAuthorizedRoot? {
        let defaultPath = normalized(defaultRoot.path)
        return authorizedRoots.first { normalized($0.lastKnownPath) == defaultPath }
    }

    static func coveringAuthorizedRoot(
        for defaultRoot: FileSearchDocumentDefaultRoot,
        in authorizedRoots: [FileSearchAuthorizedRoot]
    ) -> FileSearchAuthorizedRoot? {
        let defaultPath = normalized(defaultRoot.path)
        return authorizedRoots
            .filter { root in
                guard root.status.isAuthorized else { return false }
                let rootPath = normalized(root.lastKnownPath)
                return defaultPath == rootPath || defaultPath.hasPrefix(rootPath + "/")
            }
            .max { normalized($0.lastKnownPath).count < normalized($1.lastKnownPath).count }
    }

    static func missingRoots(
        from defaultRoots: [FileSearchDocumentDefaultRoot],
        authorizedRoots: [FileSearchAuthorizedRoot]
    ) -> [FileSearchDocumentDefaultRoot] {
        defaultRoots.filter {
            coveringAuthorizedRoot(for: $0, in: authorizedRoots) == nil
        }
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

enum FileSearchFirstLaunchAuthorizationPromptPolicy {
    static func shouldPresent(
        missingRootCount: Int,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.object(
            forKey: PEEKPreferenceKey.didPresentDocumentAuthorization
        ) == nil else {
            return false
        }
        defaults.set(
            true,
            forKey: PEEKPreferenceKey.didPresentDocumentAuthorization
        )
        return missingRootCount > 0
    }
}

/// Default document locations are suggestions only. App Sandbox still
/// requires the user to confirm each location in NSOpenPanel before indexing.
@MainActor
final class FileSearchDocumentDefaultRootStore: ObservableObject {
    static var standardRoots: [FileSearchDocumentDefaultRoot] {
        let home = FileSearchAccountHome.url.path
        return [
            FileSearchDocumentDefaultRoot(title: L10n.tr("文稿"), path: home + "/Documents"),
            FileSearchDocumentDefaultRoot(title: L10n.tr("桌面"), path: home + "/Desktop"),
            FileSearchDocumentDefaultRoot(title: L10n.tr("下载"), path: home + "/Downloads")
        ]
    }

    static let shared = FileSearchDocumentDefaultRootStore()

    @Published private(set) var roots: [FileSearchDocumentDefaultRoot]

    private let defaults: UserDefaults
    private let pathsKey: String
    private let configuredRoots: [FileSearchDocumentDefaultRoot]

    init(
        defaults: UserDefaults = .standard,
        pathsKey: String = PEEKPreferenceKey.documentDefaultRootPaths,
        defaultRoots: [FileSearchDocumentDefaultRoot] = FileSearchDocumentDefaultRootStore.standardRoots
    ) {
        self.defaults = defaults
        self.pathsKey = pathsKey
        configuredRoots = Self.unique(defaultRoots)
        if defaults.object(forKey: pathsKey) == nil {
            roots = configuredRoots
            persist()
        } else {
            let stored = defaults.stringArray(forKey: pathsKey) ?? []
            let enabled = Self.migratedEnabledPaths(
                stored,
                configuredRoots: configuredRoots
            )
            roots = configuredRoots.filter { enabled.contains($0.path) }
            if Set(stored) != enabled {
                persist()
            }
        }
    }

    func removeRoot(path: String) {
        guard roots.contains(where: { $0.path == path }) else { return }
        roots.removeAll { $0.path == path }
        persist()
    }

    func restoreDefaults() {
        guard roots != configuredRoots else { return }
        roots = configuredRoots
        persist()
    }

    func contains(path: String) -> Bool {
        configuredRoots.contains { $0.path == path }
    }

    private func persist() {
        defaults.set(roots.map(\.path), forKey: pathsKey)
    }

    private static func unique(
        _ roots: [FileSearchDocumentDefaultRoot]
    ) -> [FileSearchDocumentDefaultRoot] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let normalized = URL(fileURLWithPath: root.path, isDirectory: true)
                .standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return FileSearchDocumentDefaultRoot(title: root.title, path: normalized)
        }
    }

    /// Maps the former sandbox-container defaults to the real account
    /// locations while preserving which of the three defaults the user had
    /// removed. The old catch-all container home is intentionally discarded.
    private static func migratedEnabledPaths(
        _ storedPaths: [String],
        configuredRoots: [FileSearchDocumentDefaultRoot]
    ) -> Set<String> {
        let configuredPaths = Set(configuredRoots.map(\.path))
        let configuredByLeaf = Dictionary(
            uniqueKeysWithValues: configuredRoots.map {
                ($0.url.lastPathComponent, $0.path)
            }
        )
        return storedPaths.reduce(into: Set<String>()) { result, storedPath in
            let normalized = URL(fileURLWithPath: storedPath, isDirectory: true)
                .standardizedFileURL.path
            if configuredPaths.contains(normalized) {
                result.insert(normalized)
                return
            }
            guard FileSearchAccountHome.isPEEKSandboxPath(normalized),
                  let migrated = configuredByLeaf[
                    URL(fileURLWithPath: normalized).lastPathComponent
                  ] else {
                return
            }
            result.insert(migrated)
        }
    }
}

struct FileSearchApplicationRoot: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL?
    let path: String
    let isDefault: Bool
    let customRootID: UUID?
    let status: FileSearchAuthorizedRootStatus

    var displayPath: String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

enum FileSearchApplicationRootError: LocalizedError, Equatable, Sendable {
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .duplicate(let path):
            return L10n.tr("“%@”已在应用搜索范围中", path)
        }
    }
}

/// User-facing application search roots. Default system roots are removable
/// and restorable; custom roots use a separate security-scoped bookmark store.
@MainActor
final class FileSearchApplicationRootStore: ObservableObject {
    static let defaultPaths = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications"
    ]

    static let shared = FileSearchApplicationRootStore(
        onRootsChanged: {
            FileSearchIndexRuntime.shared.authorizedRootsDidChange()
        }
    )

    @Published private(set) var roots: [FileSearchApplicationRoot] = []

    private let defaults: UserDefaults
    private let pathsKey: String
    private let customStore: FileSearchAuthorizedRootStore
    private let configuredDefaultPaths: [String]
    private let onRootsChanged: (() -> Void)?
    private var enabledDefaultPaths: [String]

    init(
        defaults: UserDefaults = .standard,
        pathsKey: String = PEEKPreferenceKey.applicationRootPaths,
        customStorageKey: String = "fileSearch.authorizedApplicationRoots.v1",
        defaultPaths: [String] = FileSearchApplicationRootStore.defaultPaths,
        onRootsChanged: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.pathsKey = pathsKey
        customStore = FileSearchAuthorizedRootStore(
            userDefaults: defaults,
            storageKey: customStorageKey
        )
        let normalizedDefaultPaths = Self.normalizedPaths(defaultPaths)
        configuredDefaultPaths = normalizedDefaultPaths
        self.onRootsChanged = onRootsChanged
        if defaults.object(forKey: pathsKey) == nil {
            enabledDefaultPaths = normalizedDefaultPaths
            defaults.set(enabledDefaultPaths, forKey: pathsKey)
        } else {
            enabledDefaultPaths = Self.normalizedPaths(
                defaults.stringArray(forKey: pathsKey) ?? []
            ).filter { normalizedDefaultPaths.contains($0) }
        }
        rebuildRoots()
    }

    func refresh() {
        let previous = roots
        customStore.refresh(notifyChanges: false)
        rebuildRoots()
        if roots != previous { onRootsChanged?() }
    }

    @discardableResult
    func addRoot(_ url: URL) throws -> FileSearchAuthorizationResult {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if roots.contains(where: { Self.pathsOverlap(path, $0.path) }) {
            throw FileSearchApplicationRootError.duplicate(path)
        }
        let result = try customStore.addRoot(url)
        rebuildRoots()
        onRootsChanged?()
        return result
    }

    @discardableResult
    func reauthorizeRoot(
        id: UUID,
        with url: URL
    ) throws -> FileSearchAuthorizationResult {
        let result = try customStore.reauthorizeRoot(id: id, with: url)
        rebuildRoots()
        onRootsChanged?()
        return result
    }

    func removeRoot(_ root: FileSearchApplicationRoot) {
        if root.isDefault {
            enabledDefaultPaths.removeAll { $0 == root.path }
            persistDefaultPaths()
        } else if let customRootID = root.customRootID {
            customStore.removeRoot(id: customRootID)
        }
        rebuildRoots()
        onRootsChanged?()
    }

    func restoreDefaults() {
        let restored = configuredDefaultPaths
        guard restored != enabledDefaultPaths else { return }
        enabledDefaultPaths = restored
        persistDefaultPaths()
        rebuildRoots()
        onRootsChanged?()
    }

    func defaultRootURLs() -> [URL] {
        roots.compactMap { root in
            guard root.isDefault, root.status.isAuthorized else { return nil }
            return root.url
        }
    }

    func resolveCustomScopedAccess() -> [FileSearchSecurityScopedAccess] {
        customStore.resolveScopedAccess()
    }

    func resolveScopedAccess(
        containing itemURL: URL
    ) throws -> FileSearchSecurityScopedAccess? {
        try customStore.resolveScopedAccess(containing: itemURL)
    }

    private func persistDefaultPaths() {
        defaults.set(enabledDefaultPaths, forKey: pathsKey)
    }

    private func rebuildRoots() {
        let defaultRoots = enabledDefaultPaths.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            return FileSearchApplicationRoot(
                id: "default:\(path)",
                url: exists ? url : nil,
                path: path,
                isDefault: true,
                customRootID: nil,
                status: exists ? .authorized : .unavailable(L10n.tr("目录当前不可用"))
            )
        }
        let customRoots = customStore.roots.map { root in
            FileSearchApplicationRoot(
                id: "custom:\(root.id.uuidString)",
                url: root.url,
                path: root.lastKnownPath,
                isDefault: false,
                customRootID: root.id,
                status: root.status
            )
        }
        roots = defaultRoots + customRoots.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { raw in
            let path = NSString(string: raw).expandingTildeInPath
            let normalized = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        left == right
            || left.hasPrefix(right + "/")
            || right.hasPrefix(left + "/")
    }
}

@MainActor
enum FileSearchSecurityScopeResolver {
    static func resolve(
        containing itemURL: URL
    ) throws -> FileSearchSecurityScopedAccess? {
        if let lease = try FileSearchAuthorizedRootStore.shared
            .resolveScopedAccess(containing: itemURL) {
            return lease
        }
        return try FileSearchApplicationRootStore.shared
            .resolveScopedAccess(containing: itemURL)
    }
}
