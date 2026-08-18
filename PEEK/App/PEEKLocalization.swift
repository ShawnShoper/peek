import Foundation

enum PEEKAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    fileprivate var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return ["zh-Hans"]
        case .english: return ["en"]
        }
    }

    static func current(defaults: UserDefaults = .standard) -> PEEKAppLanguage {
        PEEKAppLanguage(
            rawValue: defaults.string(forKey: PEEKPreferenceKey.appLanguage) ?? ""
        ) ?? .system
    }

    func apply(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: PEEKPreferenceKey.appLanguage)
        if let appleLanguages {
            defaults.set(appleLanguages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

enum L10n {
    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }

    static func localizedString(
        forKey key: String,
        language: PEEKAppLanguage,
        bundle: Bundle = .main
    ) -> String {
        let identifier: String
        switch language {
        case .system:
            return bundle.localizedString(forKey: key, value: key, table: "Localizable")
        case .simplifiedChinese:
            identifier = "zh-Hans"
        case .english:
            identifier = "en"
        }

        guard
            let path = bundle.path(forResource: identifier, ofType: "lproj"),
            let localizedBundle = Bundle(path: path)
        else {
            return key
        }
        return localizedBundle.localizedString(
            forKey: key,
            value: key,
            table: "Localizable"
        )
    }
}
