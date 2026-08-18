import Foundation

struct FileSearchPreparedItem: Sendable {
    let item: FileSearchItem
    let normalizedName: String
    let normalizedPath: String
    let compactPinyin: String
    let pinyinInitials: String
    let wordInitials: String
    let normalizedAliasNames: String
    let compactAliasPinyin: String
    let aliasPinyinInitials: String
    let aliasWordInitials: String

    init(item: FileSearchItem) {
        self.item = item
        normalizedName = FileSearchMatcher.normalize(item.displayName)
        normalizedPath = FileSearchMatcher.normalize(item.url.path)

        let pinyin = FileSearchMatcher.pinyin(item.displayName)
        compactPinyin = pinyin.replacingOccurrences(of: " ", with: "")
        pinyinInitials = pinyin
            .split(separator: " ")
            .compactMap(\.first)
            .map(String.init)
            .joined()
        wordInitials = FileSearchMatcher.wordInitials(item.displayName)

        let aliases = FileSearchMatcher.uniqueAliases(
            item.searchAliases,
            excluding: item.displayName
        )
        normalizedAliasNames = aliases
            .map(FileSearchMatcher.normalize)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let aliasPinyin = aliases.map(FileSearchMatcher.pinyin)
        compactAliasPinyin = aliasPinyin
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        aliasPinyinInitials = aliasPinyin
            .map {
                $0.split(separator: " ")
                    .compactMap(\.first)
                    .map(String.init)
                    .joined()
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        aliasWordInitials = aliases
            .map(FileSearchMatcher.wordInitials)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    init(
        item: FileSearchItem,
        normalizedName: String,
        normalizedPath: String,
        compactPinyin: String,
        pinyinInitials: String,
        wordInitials: String,
        normalizedAliasNames: String,
        compactAliasPinyin: String,
        aliasPinyinInitials: String,
        aliasWordInitials: String
    ) {
        self.item = item
        self.normalizedName = normalizedName
        self.normalizedPath = normalizedPath
        self.compactPinyin = compactPinyin
        self.pinyinInitials = pinyinInitials
        self.wordInitials = wordInitials
        self.normalizedAliasNames = normalizedAliasNames
        self.compactAliasPinyin = compactAliasPinyin
        self.aliasPinyinInitials = aliasPinyinInitials
        self.aliasWordInitials = aliasWordInitials
    }
}

enum FileSearchMatcher {
    static func rank(
        _ items: some Sequence<FileSearchPreparedItem>,
        request: FileSearchRequest
    ) -> [FileSearchResult] {
        let rawQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalize(rawQuery)
        let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
        let tokens = normalizedQuery.split(separator: " ").map(String.init)

        // The all-results experience is deliberately grouped: applications
        // are always shown before documents, while relevance remains the
        // primary ordering inside each group.
        var matches: [FileSearchResult] = []
        let trimThreshold = max(request.limit * 8, 256)
        for prepared in items {
            guard request.includeHidden || !prepared.item.isHidden else {
                continue
            }
            guard request.category == .all
                    || prepared.item.kind.category == request.category else {
                continue
            }
            if normalizedQuery.isEmpty {
                matches.append(
                    FileSearchResult(item: prepared.item, score: 0)
                )
                trimIfNeeded(
                    matches: &matches,
                    limit: request.limit,
                    threshold: trimThreshold,
                    applicationsFirst: request.category == .all
                )
                continue
            }
            guard let score = score(
                prepared,
                normalizedQuery: normalizedQuery,
                compactQuery: compactQuery,
                tokens: tokens
            ) else {
                continue
            }
            matches.append(
                FileSearchResult(item: prepared.item, score: score)
            )
            trimIfNeeded(
                matches: &matches,
                limit: request.limit,
                threshold: trimThreshold,
                applicationsFirst: request.category == .all
            )
        }

        matches.sort {
            isOrderedBefore(
                $0,
                $1,
                applicationsFirst: request.category == .all
            )
        }
        return Array(matches.prefix(request.limit))
    }

    private static func trimIfNeeded(
        matches: inout [FileSearchResult],
        limit: Int,
        threshold: Int,
        applicationsFirst: Bool
    ) {
        guard matches.count > threshold else { return }
        matches.sort {
            isOrderedBefore($0, $1, applicationsFirst: applicationsFirst)
        }
        matches = Array(matches.prefix(max(limit * 4, limit)))
    }

    private static func isOrderedBefore(
        _ lhs: FileSearchResult,
        _ rhs: FileSearchResult,
        applicationsFirst: Bool
    ) -> Bool {
        if applicationsFirst {
            let lhsIsApplication = lhs.item.kind == .application
            let rhsIsApplication = rhs.item.kind == .application
            if lhsIsApplication != rhsIsApplication {
                return lhsIsApplication
            }
        }
        let lhsName = normalize(lhs.item.displayName)
        let rhsName = normalize(rhs.item.displayName)
        if lhsName == rhsName, lhs.item.kind != rhs.item.kind {
            return lhs.item.kind.rawValue < rhs.item.kind.rawValue
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let nameOrder = lhs.item.displayName.localizedStandardCompare(rhs.item.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.item.kind != rhs.item.kind {
            return lhs.item.kind.rawValue < rhs.item.kind.rawValue
        }
        return lhs.item.url.path.localizedStandardCompare(rhs.item.url.path) == .orderedAscending
    }

    private static func score(
        _ prepared: FileSearchPreparedItem,
        normalizedQuery: String,
        compactQuery: String,
        tokens: [String]
    ) -> Double? {
        let name = prepared.normalizedName
        let compactName = name.replacingOccurrences(of: " ", with: "")
        var best: Double?

        func accept(_ candidate: Double?) {
            guard let candidate else { return }
            best = max(best ?? candidate, candidate)
        }

        if name == normalizedQuery || compactName == compactQuery { accept(1_200) }
        if name.hasPrefix(normalizedQuery) || compactName.hasPrefix(compactQuery) {
            accept(1_070 - Double(max(0, compactName.count - compactQuery.count)) * 0.2)
        }
        if let range = name.range(of: normalizedQuery) {
            accept(930 - Double(name.distance(from: name.startIndex, to: range.lowerBound)))
        }
        if prepared.compactPinyin == compactQuery { accept(900) }
        if prepared.compactPinyin.hasPrefix(compactQuery) { accept(850) }
        if prepared.pinyinInitials.hasPrefix(compactQuery) { accept(830) }
        if prepared.wordInitials.hasPrefix(compactQuery) { accept(820) }

        for alias in aliasComponents(prepared.normalizedAliasNames) {
            let compactAlias = alias.replacingOccurrences(of: " ", with: "")
            if alias == normalizedQuery || compactAlias == compactQuery { accept(1_150) }
            if alias.hasPrefix(normalizedQuery) || compactAlias.hasPrefix(compactQuery) {
                accept(1_020 - Double(max(0, compactAlias.count - compactQuery.count)) * 0.2)
            }
            if let range = alias.range(of: normalizedQuery) {
                accept(900 - Double(alias.distance(from: alias.startIndex, to: range.lowerBound)))
            }
            accept(subsequenceScore(query: compactQuery, candidate: compactAlias, base: 680))
        }
        for aliasPinyin in aliasComponents(prepared.compactAliasPinyin) {
            if aliasPinyin == compactQuery { accept(890) }
            if aliasPinyin.hasPrefix(compactQuery) { accept(845) }
            accept(subsequenceScore(query: compactQuery, candidate: aliasPinyin, base: 655))
        }
        for initials in aliasComponents(prepared.aliasPinyinInitials) {
            if initials.hasPrefix(compactQuery) { accept(825) }
            accept(subsequenceScore(query: compactQuery, candidate: initials, base: 635))
        }
        for initials in aliasComponents(prepared.aliasWordInitials) {
            if initials.hasPrefix(compactQuery) { accept(815) }
        }
        accept(subsequenceScore(query: compactQuery, candidate: compactName, base: 700))
        accept(subsequenceScore(
            query: compactQuery,
            candidate: prepared.compactPinyin,
            base: 660
        ))
        accept(subsequenceScore(
            query: compactQuery,
            candidate: prepared.pinyinInitials,
            base: 640
        ))

        if prepared.normalizedPath.contains(normalizedQuery) { accept(430) }

        // Multi-token queries must be explainable by the name, pinyin or path;
        // a single fuzzy token may not hide a completely missing second token.
        if tokens.count > 1 {
            let haystacks = [
                name,
                prepared.compactPinyin,
                prepared.normalizedAliasNames,
                prepared.compactAliasPinyin,
                prepared.normalizedPath
            ]
            guard tokens.allSatisfy({ token in
                haystacks.contains(where: { $0.contains(token) })
            }) else {
                return nil
            }
            accept((best ?? 0) + Double(tokens.count * 12))
        }
        return best
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}._-]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pinyin(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return normalize(mutable as String)
    }

    static func wordInitials(_ value: String) -> String {
        let withCamelCaseBoundaries = value.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return normalize(withCamelCaseBoundaries)
            .split(separator: " ")
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }

    static func uniqueAliases(_ aliases: [String], excluding displayName: String) -> [String] {
        let excluded = normalize(displayName)
        var seen = Set<String>()
        return aliases.compactMap { alias in
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalize(trimmed)
            guard !normalized.isEmpty,
                  normalized != excluded,
                  seen.insert(normalized).inserted else { return nil }
            return trimmed
        }
    }

    private static func aliasComponents(_ value: String) -> [String] {
        value.split(separator: "\n").map(String.init)
    }

    private static func subsequenceScore(
        query: String,
        candidate: String,
        base: Double
    ) -> Double? {
        guard !query.isEmpty, query.count <= candidate.count else { return nil }
        var searchIndex = candidate.startIndex
        var previousMatch: String.Index?
        var gapPenalty = 0
        var consecutiveBonus = 0

        for character in query {
            guard let match = candidate[searchIndex...].firstIndex(of: character) else {
                return nil
            }
            if let previousMatch {
                let expected = candidate.index(after: previousMatch)
                if match == expected {
                    consecutiveBonus += 7
                } else {
                    gapPenalty += candidate.distance(from: expected, to: match)
                }
            } else {
                gapPenalty += candidate.distance(from: candidate.startIndex, to: match)
            }
            previousMatch = match
            searchIndex = candidate.index(after: match)
        }
        let densityPenalty = Double(max(0, candidate.count - query.count)) * 0.35
        let score = base + Double(consecutiveBonus) - Double(gapPenalty * 3) - densityPenalty
        return score > base * 0.45 ? score : nil
    }
}
