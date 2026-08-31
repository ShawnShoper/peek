import Foundation
import SwiftUI

enum PrivacyPolicyLanguage: String, Equatable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static func resolve(
        appLanguage: PEEKAppLanguage,
        preferredLanguages: [String] = Bundle.main.preferredLocalizations
            + Locale.preferredLanguages
    ) -> PrivacyPolicyLanguage {
        switch appLanguage {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .system:
            let firstSupportedLanguage = preferredLanguages.first { identifier in
                let normalized = identifier.lowercased()
                return normalized.hasPrefix("zh") || normalized.hasPrefix("en")
            }
            return firstSupportedLanguage?.lowercased().hasPrefix("zh") == true
                ? .simplifiedChinese
                : .english
        }
    }
}

enum PrivacyPolicyBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
}

struct PrivacyPolicyDocument: Equatable {
    let language: PrivacyPolicyLanguage
    let blocks: [PrivacyPolicyBlock]

    static func load(
        appLanguage: PEEKAppLanguage,
        preferredLanguages: [String] = Bundle.main.preferredLocalizations
            + Locale.preferredLanguages,
        bundle: Bundle = .main
    ) throws -> PrivacyPolicyDocument {
        let language = PrivacyPolicyLanguage.resolve(
            appLanguage: appLanguage,
            preferredLanguages: preferredLanguages
        )
        let resourceName = "PrivacyPolicy.\(language.rawValue)"
        guard let url = bundle.url(forResource: resourceName, withExtension: "md") else {
            throw PrivacyPolicyDocumentError.missingResource(resourceName)
        }

        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PrivacyPolicyDocumentError.unreadableResource(resourceName)
        }

        let blocks = PrivacyPolicyMarkdownParser.parse(markdown)
        guard !blocks.isEmpty else {
            throw PrivacyPolicyDocumentError.emptyResource(resourceName)
        }
        return PrivacyPolicyDocument(language: language, blocks: blocks)
    }
}

enum PrivacyPolicyDocumentError: Error, Equatable {
    case missingResource(String)
    case unreadableResource(String)
    case emptyResource(String)
}

enum PrivacyPolicyMarkdownParser {
    static func parse(_ markdown: String) -> [PrivacyPolicyBlock] {
        var blocks: [PrivacyPolicyBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line.hasPrefix("#") {
                let markerCount = line.prefix { $0 == "#" }.count
                let contentStart = line.index(line.startIndex, offsetBy: markerCount)
                let heading = line[contentStart...].trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(level: markerCount, text: heading))
                    continue
                }
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        return blocks
    }
}

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let document: PrivacyPolicyDocument?

    init(appLanguage: PEEKAppLanguage, bundle: Bundle = .main) {
        document = try? PrivacyPolicyDocument.load(
            appLanguage: appLanguage,
            bundle: bundle
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let document {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                            policyBlock(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("无法载入隐私说明"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.tr("请重新安装 PEEK 后再试。"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("隐私政策"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("隐私说明内置于 PEEK，可离线查看。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func policyBlock(_ block: PrivacyPolicyBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            if level == 1 {
                // The sheet header already presents the localized document title.
                EmptyView()
            } else if level == 2 {
                richText(text)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 12)
            } else {
                richText(text)
                    .font(.headline)
                    .padding(.top, 5)
            }
        case .paragraph(let text):
            richText(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                richText(text)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 5)
        }
    }

    private func richText(_ source: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(source)
        return Text(attributed)
    }
}
