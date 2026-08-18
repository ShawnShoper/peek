import Foundation

struct SearchApplicationUsage: Codable, Equatable, Sendable {
    var openCount: Int
    var lastOpenedAt: Date
}

@MainActor
protocol SearchApplicationUsageTracking: AnyObject {
    func recordOpen(for applicationURL: URL)
}

/// Keeps application launch frequency local to this Mac. The data is small,
/// independent from the file index, and therefore remains available while an
/// index generation is being replaced.
@MainActor
final class SearchApplicationUsageStore: SearchApplicationUsageTracking {
    static let shared = SearchApplicationUsageStore()

    private static let defaultKey = "search.application-usage.v1"
    private static let maximumRecordCount = 1_000

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    private var records: [String: SearchApplicationUsage]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = SearchApplicationUsageStore.defaultKey,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: SearchApplicationUsage].self,
               from: data
           ) {
            records = decoded.filter { !$0.key.isEmpty && $0.value.openCount > 0 }
        } else {
            records = [:]
        }
    }

    func recordOpen(for applicationURL: URL) {
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return
        }
        let key = Self.key(for: applicationURL)
        let previous = records[key]
        let previousCount = previous?.openCount ?? 0
        let nextCount = previousCount == Int.max ? Int.max : previousCount + 1
        records[key] = SearchApplicationUsage(
            openCount: nextCount,
            lastOpenedAt: now()
        )
        pruneIfNeeded()
        persist()
    }

    func usage(for applicationURL: URL) -> SearchApplicationUsage? {
        records[Self.key(for: applicationURL)]
    }

    /// Applications stay ahead of documents in all-results mode. With an
    /// empty query, usage is the primary app signal. With a query, textual
    /// relevance remains primary and usage only resolves equal-score results.
    func ranked(
        _ results: [FileSearchResult],
        query: String,
        category: FileSearchCategory
    ) -> [FileSearchResult] {
        guard category == .all || category == .applications else { return results }

        let originalOrder = Dictionary(
            uniqueKeysWithValues: results.enumerated().map { ($0.element.id, $0.offset) }
        )
        let applications = results.filter { $0.item.kind == .application }
        let documents = results.filter { $0.item.kind != .application }
        let isEmptyQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let rankedApplications = applications.sorted { lhs, rhs in
            let lhsUsage = usage(for: lhs.item.url)
            let rhsUsage = usage(for: rhs.item.url)
            if !isEmptyQuery, abs(lhs.score - rhs.score) > 0.000_001 {
                return lhs.score > rhs.score
            }
            let lhsCount = lhsUsage?.openCount ?? 0
            let rhsCount = rhsUsage?.openCount ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsDate = lhsUsage?.lastOpenedAt ?? .distantPast
            let rhsDate = rhsUsage?.lastOpenedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return (originalOrder[lhs.id] ?? .max) < (originalOrder[rhs.id] ?? .max)
        }

        return category == .applications
            ? rankedApplications
            : rankedApplications + documents
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func pruneIfNeeded() {
        guard records.count > Self.maximumRecordCount else { return }
        let retained = records.sorted { lhs, rhs in
            if lhs.value.lastOpenedAt != rhs.value.lastOpenedAt {
                return lhs.value.lastOpenedAt > rhs.value.lastOpenedAt
            }
            return lhs.value.openCount > rhs.value.openCount
        }
        .prefix(Self.maximumRecordCount)
        records = Dictionary(
            uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
        )
    }

    private static func key(for url: URL) -> String {
        // Ranking runs on the UI actor. Standardization is lexical and avoids
        // synchronous filesystem work for every visible application result.
        url.standardizedFileURL.path
    }
}
