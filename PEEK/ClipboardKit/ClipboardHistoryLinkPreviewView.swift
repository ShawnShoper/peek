import AppKit
import Foundation
import SwiftUI

/// Offline metadata for a link card. Building this value parses only the URL
/// string and never resolves DNS or opens a network connection.
struct ClipboardHistoryLinkCardMetadata: Equatable, Sendable {
    let host: String
    let scheme: String
    let pathSummary: String

    static func make(for url: URL) -> ClipboardHistoryLinkCardMetadata {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host ?? url.host ?? url.absoluteString
        let scheme = (components?.scheme ?? url.scheme ?? "link").uppercased()
        let path = components?.percentEncodedPath ?? url.path
        let pathSummary = path.isEmpty || path == "/" ? "/" : path
        return ClipboardHistoryLinkCardMetadata(
            host: host,
            scheme: scheme,
            pathSummary: pathSummary
        )
    }
}

/// An offline link card. PEEK deliberately does not embed remote pages here:
/// WKWebView would allow the page and its subresources to reach local/private
/// services. Network access occurs only after the user opens the URL in their
/// external browser.
struct ClipboardHistoryLinkPreviewView: View {
    let url: URL

    private var metadata: ClipboardHistoryLinkCardMetadata {
        .make(for: url)
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "link.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 7) {
                Text(metadata.host)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(url.absoluteString)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                linkBadge(metadata.scheme)
                if metadata.pathSummary != "/" {
                    linkBadge(metadata.pathSummary)
                }
            }

            Text(L10n.tr("离线链接预览，不会在 PEEK 内连接网站。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    copyURL()
                } label: {
                    Label(L10n.tr("复制链接"), systemImage: "doc.on.doc")
                }

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.tr("在浏览器中打开"), systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 8)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    private func linkBadge(_ value: String) -> some View {
        Text(value)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(0.07))
            )
    }

    private func copyURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}
