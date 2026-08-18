import AppKit
import Foundation

/// Testable policy for the automatic/manual capture boundary. AX semantic
/// recognition is deliberately absent: it improves preselection but must not
/// disable automatic scrolling for a user-confirmed, window-anchored region.
enum ScrollCaptureModeResolver {
    /// Keep enough shared content between adjacent frames for low-texture or
    /// animated pages. The pixel setting remains a user-configured ceiling;
    /// it is never treated as a minimum.
    private static let preferredSelectionRatio: CGFloat = 0.35
    private static let hardMaximumSelectionRatio: CGFloat = 0.45

    static func resolve(
        automaticRequested: Bool,
        accessibilityGranted: Bool,
        hasValidatedWindowAnchor: Bool,
        configuredAmount: Int,
        captureHeight: CGFloat
    ) throws -> ScrollCaptureMode {
        guard automaticRequested else { return .manual }
        guard accessibilityGranted else {
            throw ScrollCaptureError.accessibilityPermissionDenied
        }
        guard hasValidatedWindowAnchor else {
            throw ScrollCaptureError.invalidConfiguration(
                L10n.tr("无法确认选区所属窗口，请将选区完整放在一个窗口内后重试")
            )
        }

        let boundedConfiguredAmount = min(max(1, configuredAmount), Int(Int32.max))
        let normalizedHeight = max(1, captureHeight)
        let preferredAmount = max(
            1,
            Int((normalizedHeight * preferredSelectionRatio).rounded(.down))
        )
        let hardMaximumAmount = max(
            1,
            Int((normalizedHeight * hardMaximumSelectionRatio).rounded(.down))
        )
        let safeAmount = min(
            boundedConfiguredAmount,
            preferredAmount,
            hardMaximumAmount
        )
        return .automatic(
            AutomaticScrollConfiguration(
                amount: Int32(safeAmount),
                consecutiveDuplicateLimit: 2
            )
        )
    }
}

@MainActor
final class ScrollDiagnosticsCopyTarget: NSObject {
    private let diagnostics: String

    init(diagnostics: String) {
        self.diagnostics = diagnostics
    }

    @objc func copyDiagnostics(_ sender: NSButton) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(diagnostics, forType: .string) {
            sender.title = L10n.tr("诊断已复制")
            sender.isEnabled = false
        } else {
            NSSound.beep()
        }
    }
}
