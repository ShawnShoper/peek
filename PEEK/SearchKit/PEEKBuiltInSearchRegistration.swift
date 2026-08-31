import Foundation

/// Registers PEEK's own commands in the same query pipeline as files and apps.
/// Built-in commands are generated in memory and never written to the file index.
enum PEEKBuiltInSearchRegistration {
    private struct Definition {
        let identifier: String
        let title: String
        let subtitle: String
        let aliases: [String]
        let behavior: SearchPanelLaunchBehavior
    }

    @MainActor
    static func items(
        matching query: String,
        category: SearchPanelCategory
    ) -> [SearchPanelItem] {
        guard category == .all || category == .applications else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        return definitions.compactMap { definition in
            let searchableItem = FileSearchItem(
                url: Bundle.main.bundleURL,
                displayName: definition.title,
                kind: .application,
                typeDescription: L10n.tr("内置工具"),
                isHidden: false,
                applicationVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                searchAliases: definition.aliases
            )
            let request = FileSearchRequest(
                query: trimmedQuery,
                category: .applications,
                includeHidden: true,
                limit: 1
            )
            guard !FileSearchMatcher.rank(
                [FileSearchPreparedItem(item: searchableItem)],
                request: request
            ).isEmpty else { return nil }

            return SearchPanelItem(
                id: definition.identifier,
                url: Bundle.main.bundleURL,
                displayName: definition.title,
                subtitle: definition.subtitle,
                kindDescription: L10n.tr("内置工具"),
                category: .applications,
                isDirectory: true,
                applicationBundleIdentifier: Bundle.main.bundleIdentifier,
                metadata: [
                    SearchPanelMetadataField(
                        label: L10n.tr("处理方式"),
                        value: L10n.tr("PEEK 内置操作")
                    )
                ],
                launchBehavior: definition.behavior
            )
        }
    }

    @MainActor
    private static var definitions: [Definition] {
        [
            Definition(
                identifier: PEEKTranslateSearchRegistration.itemIdentifier,
                title: L10n.tr("PEEK 翻译"),
                subtitle: L10n.tr("PEEK 内置翻译工具"),
                aliases: ["PEEK Translate", "Translate", "Translation", "翻译", "翻译工具", "fanyi", "fy"], // localization:ignore - cross-language search aliases
                behavior: .peekTranslation
            ),
            Definition(
                identifier: "peek.tool.clipboard-history",
                title: L10n.tr("剪贴板历史"),
                subtitle: L10n.tr("查看最近复制的文字、图片、链接和文件"),
                aliases: ["Clipboard", "Clipboard History", "剪贴板", "剪切板", "历史记录", "jiantieban", "jtb"], // localization:ignore - cross-language search aliases
                behavior: .peekClipboardHistory
            ),
            Definition(
                identifier: "peek.tool.region-capture",
                title: L10n.tr("区域截图"),
                subtitle: L10n.tr("框选屏幕区域并复制到剪贴板"),
                aliases: ["Screenshot", "Capture", "区域截图", "截图", "quyu jietu", "jt"], // localization:ignore - cross-language search aliases
                behavior: .peekRegionCapture
            ),
            Definition(
                identifier: "peek.tool.scrolling-capture",
                title: L10n.tr("滚动截图"),
                subtitle: L10n.tr("截取可滚动内容并自动拼接"),
                aliases: ["Scrolling Screenshot", "Long Screenshot", "滚动截图", "长截图", "gundong jietu", "cjt"], // localization:ignore - cross-language search aliases
                behavior: .peekScrollingCapture
            ),
            Definition(
                identifier: "peek.tool.ocr",
                title: L10n.tr("截图 OCR"),
                subtitle: L10n.tr("框选屏幕文字并在本机识别"),
                aliases: ["OCR", "Text Recognition", "文字识别", "识别文字", "tuwen shibie", "wzsb"], // localization:ignore - cross-language search aliases
                behavior: .peekOCRCapture
            ),
            settingsDefinition(.general, aliases: ["Settings", "Preferences", "设置", "偏好设置", "shezhi"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.search, aliases: ["Search Settings", "索引设置", "搜索设置", "sousuo shezhi"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.clipboard, aliases: ["Clipboard Settings", "剪贴板设置", "jiantieban shezhi"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.shortcuts, aliases: ["Keyboard Shortcuts", "快捷键设置", "kuaijiejian"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.translation, aliases: ["Translation Settings", "翻译设置", "fanyi shezhi"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.capture, aliases: ["Screenshot Settings", "截图设置", "jietu shezhi"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.appearance, aliases: ["Appearance", "Theme", "外观", "主题", "waiguan"]), // localization:ignore - cross-language search aliases
            settingsDefinition(.about, aliases: ["About PEEK", "Diagnostics", "关于", "诊断", "guanyu"]) // localization:ignore - cross-language search aliases
        ]
    }

    @MainActor
    private static func settingsDefinition(
        _ destination: PEEKSettingsDestination,
        aliases: [String]
    ) -> Definition {
        Definition(
            identifier: "peek.settings.\(destination.rawValue)",
            title: L10n.tr("%@设置", destination.title),
            subtitle: L10n.tr("打开 PEEK 设置"),
            aliases: aliases,
            behavior: .peekSettings(destination)
        )
    }
}
