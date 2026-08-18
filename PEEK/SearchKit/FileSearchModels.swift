import Foundation

enum FileSearchCategory: String, CaseIterable, Codable, Sendable {
    case all
    case applications
    case files
    case folders
}

enum FileSearchItemKind: Int, Codable, CaseIterable, Sendable {
    case application = 0
    case file = 1
    case folder = 2

    var category: FileSearchCategory {
        switch self {
        case .application: return .applications
        case .file: return .files
        case .folder: return .folders
        }
    }
}

struct FileSearchItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let kind: FileSearchItemKind
    let typeDescription: String
    let isHidden: Bool
    let fileSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let lastOpenedAt: Date?
    let applicationVersion: String?
    /// Additional names accepted by search without changing the title shown
    /// in the result list. Applications use this for the on-disk English
    /// bundle name and other localized bundle names.
    let searchAliases: [String]

    init(
        url: URL,
        displayName: String,
        kind: FileSearchItemKind,
        typeDescription: String,
        isHidden: Bool,
        fileSize: Int64? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        applicationVersion: String? = nil,
        searchAliases: [String] = []
    ) {
        let standardizedURL = url.standardizedFileURL
        id = standardizedURL.path
        self.url = standardizedURL
        self.displayName = displayName
        self.kind = kind
        self.typeDescription = typeDescription
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastOpenedAt = lastOpenedAt
        self.applicationVersion = applicationVersion
        self.searchAliases = searchAliases
    }
}

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let item: FileSearchItem
    let score: Double

    var id: String { item.id }
}

enum FileSearchIndexPhase: String, Codable, Sendable {
    case idle
    case indexingApplications
    case indexingFiles
    case ready
    case limited

    var isComplete: Bool {
        self == .ready || self == .limited
    }
}

struct FileSearchStatistics: Equatable, Sendable {
    var indexedApplications = 0
    var indexedFiles = 0
    var indexedFolders = 0
    var skippedGeneratedDirectories = 0
    var inaccessibleLocations = 0

    var indexedItems: Int {
        indexedApplications + indexedFiles + indexedFolders
    }
}

struct FileSearchRequest: Equatable, Sendable {
    var query: String
    var category: FileSearchCategory
    var includeHidden: Bool
    var limit: Int

    init(
        query: String,
        category: FileSearchCategory = .all,
        includeHidden: Bool = false,
        limit: Int = 80
    ) {
        self.query = query
        self.category = category
        self.includeHidden = includeHidden
        self.limit = min(max(limit, 1), 500)
    }
}

struct FileSearchSnapshot: Equatable, Sendable {
    let request: FileSearchRequest
    let results: [FileSearchResult]
    let phase: FileSearchIndexPhase
    let statistics: FileSearchStatistics
    let failure: FileSearchFailure?

    init(
        request: FileSearchRequest,
        results: [FileSearchResult],
        phase: FileSearchIndexPhase,
        statistics: FileSearchStatistics,
        failure: FileSearchFailure? = nil
    ) {
        self.request = request
        self.results = results
        self.phase = phase
        self.statistics = statistics
        self.failure = failure
    }

    var isComplete: Bool { phase.isComplete }
}

enum FileSearchFailure: LocalizedError, Equatable, Sendable {
    case indexUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .indexUnavailable:
            return L10n.tr("本地搜索索引暂时不可用，请稍后重试或在设置中重新构建索引")
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .indexUnavailable(let message): return message
        }
    }
}
