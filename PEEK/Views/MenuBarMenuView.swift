import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    let searchProvider: FileSearchPanelProvider
    @EnvironmentObject private var screenshotService: ScreenshotService
    @ObservedObject private var hotKeyManager = ScreenshotGlobalHotKeyManager.shared

    var body: some View {
        Button {
            SearchPanelController.shared.toggle(provider: searchProvider)
        } label: {
            searchLabel
        }

        Button {
            Task { await screenshotService.captureRegion() }
        } label: {
            screenshotLabel(
                screenshotService.isCapturing ? L10n.tr("正在截图…") : L10n.tr("区域截图"),
                systemImage: "viewfinder",
                action: .region
            )
        }
        .disabled(screenshotService.isCapturing)

        Button {
            Task { await screenshotService.captureScrolling() }
        } label: {
            screenshotLabel(
                screenshotService.isScrolling ? L10n.tr("正在滚动截图…") : L10n.tr("滚动截图"),
                systemImage: "rectangle.stack.badge.plus",
                action: .scrolling
            )
        }
        .disabled(screenshotService.isCapturing)

        Button {
            Task { await screenshotService.captureAndRecognizeText() }
        } label: {
            screenshotLabel(
                screenshotService.isRecognizingText ? L10n.tr("正在识别文字…") : L10n.tr("OCR 截图"),
                systemImage: "text.viewfinder",
                action: .ocr
            )
        }
        .disabled(screenshotService.isCapturing || screenshotService.isRecognizingText)

        if screenshotService.isCapturing {
            Button {
                screenshotService.cancelActiveCapture()
            } label: {
                Label(L10n.tr("取消当前截图"), systemImage: "xmark.circle")
            }
        }

        if let message = screenshotService.lastMessage {
            Text(message)
        }

        Divider()

        Button {
            PEEKSettingsWindowPresenter.show()
        } label: {
            Label(L10n.tr("设置…"), systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Text(versionLabel)

        Divider()

        Button(L10n.tr("退出 PEEK")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private func screenshotLabel(
        _ title: String,
        systemImage: String,
        action: ScreenshotGlobalHotKeyAction
    ) -> some View {
        let shortcut = hotKeyManager.shortcut(for: action)?.displayString
        return Label(
            shortcut.map { "\(title)    \($0)" } ?? title,
            systemImage: systemImage
        )
    }

    private var searchLabel: some View {
        let action = ScreenshotGlobalHotKeyAction.search
        let shortcut = hotKeyManager.shortcut(for: action)?.displayString
        let state = hotKeyManager.registrationStates[action]
        let title: String
        if state == .systemConflict {
            title = L10n.tr("文件查找（快捷键冲突，可在设置中修改）")
        } else {
            title = L10n.tr("文件查找")
        }
        return Label(
            shortcut.map { "\(title)    \($0)" } ?? title,
            systemImage: "magnifyingglass"
        )
    }

    private var versionLabel: String {
        let dictionary = Bundle.main.infoDictionary
        let version = dictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = dictionary?["CFBundleVersion"] as? String ?? "-"
        return "PEEK \(version) [\(build)]"
    }
}
