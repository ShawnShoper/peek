import Foundation

enum PEEKTranslateSearchRegistration {
    static let itemIdentifier = "peek.subapp.translation"

    @MainActor
    static func item(
        matching query: String,
        category: SearchPanelCategory
    ) -> SearchPanelItem? {
        guard category == .all || category == .applications else { return nil }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        let fileItem = FileSearchItem(
            url: Bundle.main.bundleURL,
            displayName: L10n.tr("PEEK 翻译"),
            kind: .application,
            typeDescription: L10n.tr("内置工具"),
            isHidden: false,
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            searchAliases: [
                "PEEK Translate",
                "Translate",
                "Translation",
                "翻译", // localization:ignore - cross-language search alias
                "翻译工具", // localization:ignore - cross-language search alias
                "fanyi",
                "fy"
            ]
        )
        let request = FileSearchRequest(
            query: trimmedQuery,
            category: .applications,
            includeHidden: true,
            limit: 1
        )
        guard !FileSearchMatcher.rank(
            [FileSearchPreparedItem(item: fileItem)],
            request: request
        ).isEmpty else {
            return nil
        }

        return SearchPanelItem(
            id: itemIdentifier,
            url: Bundle.main.bundleURL,
            displayName: fileItem.displayName,
            subtitle: L10n.tr("PEEK 内置翻译工具"),
            kindDescription: L10n.tr("内置工具"),
            category: .applications,
            isDirectory: true,
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            metadata: [
                SearchPanelMetadataField(
                    label: L10n.tr("处理方式"),
                    value: L10n.tr("Mac 本地处理")
                )
            ],
            launchBehavior: .peekTranslation
        )
    }
}
