import CoreGraphics
import Foundation
import NaturalLanguage
@preconcurrency import Translation

enum TranslationLanguageChoice: Hashable, Identifiable, Sendable {
    case automatic
    case system
    case language(String)

    var id: String {
        switch self {
        case .automatic: return "automatic"
        case .system: return "system"
        case .language(let identifier): return "language:\(identifier)"
        }
    }

    var languageIdentifier: String? {
        if case .language(let identifier) = self { return identifier }
        return nil
    }
}

struct TranslationLanguageDescriptor: Hashable, Identifiable, Sendable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
}

enum TranslationPanelPhase: Equatable, Sendable {
    case idle
    case stale
    case waiting
    case translating
    case translated
    case unchanged
    case languagePackMissing(TranslationLanguagePackRequirement)
    case unavailable
    case failed(String)

    var languagePackRequirement: TranslationLanguagePackRequirement? {
        guard case .languagePackMissing(let requirement) = self else { return nil }
        return requirement
    }

    var isRetryableFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct TranslationLanguagePackRequirement: Equatable, Sendable {
    let sourceIdentifier: String?
    let targetIdentifier: String
}

enum TranslationAvailabilityOutcome: Equatable, Sendable {
    case ready
    case requiresDownload
    case unsupported
}

@available(macOS 15.0, *)
enum TranslationAvailabilityPolicy {
    static func outcome(
        for status: LanguageAvailability.Status
    ) -> TranslationAvailabilityOutcome {
        switch status {
        case .installed:
            return .ready
        case .supported:
            return .requiresDownload
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }
}

enum TranslationLanguageSettings {
    static let url = URL(
        string: "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"
    )!
}

enum TranslationPanelLayout {
    static let width: CGFloat = 1_060
    static let height: CGFloat = 680
    static let minimumWidth: CGFloat = 820
    static let minimumHeight: CGFloat = 560
    static let screenMargin: CGFloat = 24
    static let cornerRadius: CGFloat = 20

    static func centeredFrame(in visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(minimumWidth, visibleFrame.width - screenMargin * 2)
        let availableHeight = max(minimumHeight, visibleFrame.height - screenMargin * 2)
        let resolvedWidth = min(width, availableWidth)
        let resolvedHeight = min(height, availableHeight)
        return CGRect(
            x: visibleFrame.midX - resolvedWidth / 2,
            y: visibleFrame.midY - resolvedHeight / 2,
            width: resolvedWidth,
            height: resolvedHeight
        ).integral
    }
}

enum TranslationPanelDismissalPolicy {
    static func shouldDismissAfterKeyChange(
        isVisible: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        isVisible && !isKeyWindow
    }
}

enum TranslationLanguagePresentation {
    private enum WritingScript: Hashable {
        case han
        case kana
        case hangul
        case cyrillic
        case arabic
        case hebrew
        case devanagari
        case thai
        case latin
    }

    static var systemTargetIdentifier: String {
        preferredSystemTargetIdentifier(from: Locale.preferredLanguages)
    }

    static func preferredSystemTargetIdentifier(from preferredLanguages: [String]) -> String {
        preferredLanguages.first ?? "en"
    }

    static func automaticSourceIdentifier(for text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let significantText = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.contains("://") && !$0.contains("@") }
            .joined(separator: " ")
        let scalars = Array(significantText.unicodeScalars)
        var counts: [WritingScript: Double] = [:]
        var scriptScalars: [WritingScript: [UnicodeScalar]] = [:]

        for scalar in scalars {
            guard let script = writingScript(for: scalar) else { continue }
            counts[script, default: 0] += 1
            scriptScalars[script, default: []].append(scalar)
        }
        guard !counts.isEmpty else { return nil }

        // Latin brand names and acronyms are common inside non-Latin sentences.
        // Discount all-uppercase ASCII tokens so they do not become the source language.
        let acronymCharacters = significantText
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .filter { token in
                let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                return !letters.isEmpty
                    && letters.allSatisfy(\.isASCII)
                    && String(token) == String(token).uppercased()
                    && letters.count <= 8
            }
            .reduce(0) { $0 + $1.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count }
        if acronymCharacters > 0, counts[.latin] != nil {
            counts[.latin] = max(0, (counts[.latin] ?? 0) - Double(acronymCharacters) * 0.9)
        }

        if (counts[.kana] ?? 0) > 0 {
            return "ja"
        }
        if (counts[.hangul] ?? 0) > 0,
           (counts[.hangul] ?? 0) >= (counts[.latin] ?? 0) * 0.55 {
            return "ko"
        }

        guard let dominantScript = counts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        if dominantScript == .han {
            return chineseScriptIdentifier(in: normalized)
        }
        if dominantScript == .latin,
           latinTextLooksLikeEnglishAcronym(significantText) {
            return "en"
        }
        if dominantScript == .latin {
            return latinLanguage(for: significantText)
        }

        let scriptOnlyText = String(
            String.UnicodeScalarView(scriptScalars[dominantScript] ?? [])
        )
        if dominantScript == .cyrillic {
            return cyrillicLanguage(for: scriptOnlyText)
        }
        if let language = NLLanguageRecognizer.dominantLanguage(for: scriptOnlyText),
           language != .undetermined,
           languageMatches(script: dominantScript, language: language) {
            return language.rawValue
        }
        return fallbackLanguage(for: dominantScript)
    }

    static func automaticTargetIdentifier(
        sourceIdentifier: String?,
        preferredTargetIdentifier: String
    ) -> String {
        preferredTargetIdentifier
    }

    static func localizedName(
        for identifier: String,
        locale: Locale = .current
    ) -> String {
        let lowercaseIdentifier = identifier.lowercased()
        if lowercaseIdentifier == "zh"
            || lowercaseIdentifier.contains("hans")
            || lowercaseIdentifier.hasSuffix("-cn") {
            return locale.localizedString(forIdentifier: "zh-Hans")
                ?? L10n.tr("简体中文")
        }
        if lowercaseIdentifier.contains("hant")
            || lowercaseIdentifier.hasSuffix("-tw")
            || lowercaseIdentifier.hasSuffix("-hk") {
            return locale.localizedString(forIdentifier: "zh-Hant")
                ?? L10n.tr("繁体中文")
        }
        let language = Locale.Language(identifier: identifier)
        let normalizedIdentifier = language.minimalIdentifier
        if let name = locale.localizedString(forIdentifier: normalizedIdentifier) {
            return name
        }
        if let languageCode = language.languageCode?.identifier,
           let name = locale.localizedString(forLanguageCode: languageCode) {
            return name
        }
        return identifier
    }

    static func descriptors(
        for identifiers: [String],
        locale: Locale = .current
    ) -> [TranslationLanguageDescriptor] {
        let uniqueIdentifiers = Set(identifiers)
        return uniqueIdentifiers
            .map {
                TranslationLanguageDescriptor(
                    identifier: $0,
                    displayName: localizedName(for: $0, locale: locale)
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    static func baseLanguageCode(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier
            ?? identifier.split(separator: "-").first.map(String.init)
            ?? identifier
    }

    private static func writingScript(for scalar: UnicodeScalar) -> WritingScript? {
        let value = Int(scalar.value)
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF:
            return .kana
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
            return .hangul
        case 0x0400...0x052F:
            return .cyrillic
        case 0x0590...0x05FF:
            return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
            return .arabic
        case 0x0900...0x097F:
            return .devanagari
        case 0x0E00...0x0E7F:
            return .thai
        case 0x00C0...0x024F, 0x1E00...0x1EFF:
            // Latin-1 Supplement, Latin Extended and Latin Extended Additional.
            // Keeping these characters in the sample improves detection for text
            // such as French, Spanish, Portuguese and Vietnamese.
            return CharacterSet.letters.contains(scalar) ? .latin : nil
        default:
            return CharacterSet.letters.contains(scalar) && scalar.isASCII ? .latin : nil
        }
    }

    private static func languageMatches(script: WritingScript, language: NLLanguage) -> Bool {
        let code = language.rawValue.lowercased()
        switch script {
        case .latin:
            return !["ru", "uk", "bg", "sr", "mk", "zh", "ja", "ko", "ar", "he", "hi", "th"]
                .contains(where: code.hasPrefix)
        case .cyrillic:
            return ["ru", "uk", "bg", "sr", "mk", "be"].contains(where: code.hasPrefix)
        case .arabic:
            return ["ar", "fa", "ur"].contains(where: code.hasPrefix)
        case .hebrew:
            return code.hasPrefix("he")
        case .devanagari:
            return ["hi", "mr", "ne"].contains(where: code.hasPrefix)
        case .thai:
            return code.hasPrefix("th")
        case .han:
            return code.hasPrefix("zh")
        case .kana:
            return code.hasPrefix("ja")
        case .hangul:
            return code.hasPrefix("ko")
        }
    }

    private static func fallbackLanguage(for script: WritingScript) -> String? {
        switch script {
        case .han: return "zh-Hans"
        case .kana: return "ja"
        case .hangul: return "ko"
        case .cyrillic: return "ru"
        case .arabic: return "ar"
        case .hebrew: return "he"
        case .devanagari: return "hi"
        case .thai: return "th"
        case .latin: return "en"
        }
    }

    private static func cyrillicLanguage(for text: String) -> String {
        let lowercase = text.lowercased()
        if lowercase.contains(where: { "ґєії".contains($0) }) { return "uk" }
        if lowercase.contains("ў") { return "be" }
        if lowercase.contains(where: { "јљњћђџ".contains($0) }) { return "sr" }
        if lowercase.contains(where: { "ѓќѕ".contains($0) }) { return "mk" }
        // Russian is the safest default for short Cyrillic input. NaturalLanguage
        // often labels short Russian words as Bulgarian when brand names are mixed in.
        return "ru"
    }

    private static func latinTextLooksLikeEnglishAcronym(_ text: String) -> Bool {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return !letters.isEmpty
                && letters.allSatisfy(\.isASCII)
                && (word == word.uppercased() || letters.count <= 3)
        }
    }

    private static func latinLanguage(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let strongest = hypotheses.first,
              strongest.key != .undetermined,
              languageMatches(script: .latin, language: strongest.key) else {
            return "en"
        }

        // English remains a safe result even with weak evidence. For another Latin
        // language we require both confidence and a clear lead over the runner-up.
        // This keeps real words such as "bonjour" and "goedemorgen", while ambiguous
        // brands such as "Tesla", "OpenAI" and "iPhone" fall back to English.
        if strongest.key == .english { return "en" }
        let runnerUpConfidence = hypotheses.dropFirst().first?.value ?? 0
        let confidenceLead = strongest.value - runnerUpConfidence
        let isSingleWord = words.count == 1
        let minimumConfidence: Double = isSingleWord ? 0.55 : 0.45
        let minimumLead: Double = isSingleWord ? 0.25 : 0.15
        guard strongest.value >= minimumConfidence,
              confidenceLead >= minimumLead else {
            return "en"
        }
        return strongest.key.rawValue
    }

    private static func chineseScriptIdentifier(in text: String) -> String {
        // ICU's Simplified/Traditional transforms provide broad script coverage
        // without maintaining an incomplete hand-written character list. A change
        // made while converting to Simplified is Traditional evidence; a change
        // made while converting to Traditional is Simplified evidence.
        let simplified = text.applyingTransform(
            StringTransform("Traditional-Simplified"),
            reverse: false
        )
        let traditional = text.applyingTransform(
            StringTransform("Simplified-Traditional"),
            reverse: false
        )
        let traditionalEvidence = transformationDifferenceScore(
            source: text,
            transformed: simplified
        )
        let simplifiedEvidence = transformationDifferenceScore(
            source: text,
            transformed: traditional
        )

        if traditionalEvidence > simplifiedEvidence {
            return "zh-Hant"
        }

        // Shared Han characters such as 搜、答、案 carry no script evidence.
        // Keep the existing Simplified Chinese default for ties so incremental
        // typing cannot flip merely because another shared character was added.
        return "zh-Hans"
    }

    private static func transformationDifferenceScore(
        source: String,
        transformed: String?
    ) -> Int {
        guard let transformed, transformed != source else { return 0 }
        let changedCharacters = zip(source, transformed).reduce(into: 0) { score, pair in
            if pair.0 != pair.1 { score += 1 }
        }
        return changedCharacters + abs(source.count - transformed.count)
    }
}

/// Keeps the language selected for a submitted request stable for its full lifecycle.
/// Apple's translation response can report a different source language for ambiguous
/// brands or short words, but that late guess must not rewrite routing or the UI label.
enum TranslationResponseLanguagePolicy {
    static func sourceIdentifier(
        submittedIdentifier: String?,
        responseIdentifier: String
    ) -> String {
        submittedIdentifier ?? responseIdentifier
    }

    static func targetIdentifier(
        submittedIdentifier: String,
        responseIdentifier _: String
    ) -> String {
        submittedIdentifier
    }
}

enum TranslationLanguageEquivalencePolicy {
    static func areEquivalent(sourceIdentifier: String?, targetIdentifier: String) -> Bool {
        guard let sourceIdentifier else { return false }
        let sourceBase = TranslationLanguagePresentation.baseLanguageCode(sourceIdentifier)
            .lowercased()
        let targetBase = TranslationLanguagePresentation.baseLanguageCode(targetIdentifier)
            .lowercased()
        guard sourceBase == targetBase else { return false }
        guard sourceBase == "zh" else { return true }

        return chineseScript(for: sourceIdentifier) == chineseScript(for: targetIdentifier)
    }

    private static func chineseScript(for identifier: String) -> String {
        let normalized = identifier.lowercased()
        if normalized.contains("hant")
            || normalized.hasSuffix("-tw")
            || normalized.hasSuffix("-hk") {
            return "traditional"
        }
        return "simplified"
    }
}

enum TranslationRequestPolicy {
    static let availabilityTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let sessionActivationTimeoutNanoseconds: UInt64 = 2_500_000_000
    static let translationTimeoutNanoseconds: UInt64 = 10_000_000_000
    static let maximumCharacterCount = 5_000

    static func normalizedText(_ text: String) -> String {
        String(text.prefix(maximumCharacterCount))
    }

    static func shouldTranslate(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldSubmit(
        text: String,
        pendingText: String?,
        isTranslating: Bool
    ) -> Bool {
        guard shouldTranslate(text) else { return false }
        return !(isTranslating && pendingText == text)
    }

    static func isCurrent(
        requestGeneration: Int,
        requestText: String,
        currentGeneration: Int,
        currentText: String
    ) -> Bool {
        requestGeneration == currentGeneration && requestText == currentText
    }
}
