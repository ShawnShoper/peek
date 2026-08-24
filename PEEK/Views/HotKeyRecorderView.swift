import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    let shortcut: ScreenshotHotKey?
    let onRecordingChanged: (Bool) -> Void
    let onChange: (ScreenshotHotKey?) -> Bool

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.update(
            shortcut: shortcut,
            onRecordingChanged: onRecordingChanged,
            onChange: onChange
        )
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        nsView.update(
            shortcut: shortcut,
            onRecordingChanged: onRecordingChanged,
            onChange: onChange
        )
    }

    static func dismantleNSView(
        _ nsView: HotKeyRecorderButton,
        coordinator: Void
    ) {
        nsView.prepareForRemoval()
    }
}

enum HotKeyRecorderInput: Equatable {
    case cancel
    case clear
    case shortcut(ScreenshotHotKey)
    case unsupported

    private static let acceptedModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift,
    ]

    static func resolve(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> HotKeyRecorderInput {
        let independentFlags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(acceptedModifierFlags)

        if keyCode == UInt16(kVK_Escape), independentFlags.isEmpty {
            return .cancel
        }

        if (keyCode == UInt16(kVK_Delete)
            || keyCode == UInt16(kVK_ForwardDelete)),
            independentFlags.isEmpty {
            return .clear
        }

        let shortcut = ScreenshotHotKey(
            keyCode: UInt32(keyCode),
            modifiers: carbonModifiers(from: independentFlags)
        )
        return shortcut.isValid ? .shortcut(shortcut) : .unsupported
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}

/// Captures key-down events before AppKit routes Command combinations to the
/// Settings window's menus. Returning `nil` keeps a recorded shortcut from
/// also invoking a menu command while the recorder is active.
@MainActor
final class HotKeyRecorderLocalEventMonitor {
    typealias Handler = (NSEvent) -> NSEvent?
    typealias Installer = (@escaping Handler) -> Any?
    typealias Remover = (Any) -> Void

    private let installer: Installer
    private let remover: Remover
    private var token: Any?

    var isInstalled: Bool { token != nil }

    init(
        installer: @escaping Installer = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        remover: @escaping Remover = { NSEvent.removeMonitor($0) }
    ) {
        self.installer = installer
        self.remover = remover
    }

    func install(handler: @escaping (NSEvent) -> Void) {
        guard token == nil else { return }
        token = installer { event in
            handler(event)
            return nil
        }
    }

    func remove() {
        guard let token else { return }
        remover(token)
        self.token = nil
    }
}

final class HotKeyRecorderButton: NSButton {
    private var shortcut: ScreenshotHotKey?
    private var onRecordingChanged: ((Bool) -> Void)?
    private var onChange: ((ScreenshotHotKey?) -> Bool)?
    private var isRecording = false
    private let localEventMonitor = HotKeyRecorderLocalEventMonitor()

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        configureAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        shortcut: ScreenshotHotKey?,
        onRecordingChanged: @escaping (Bool) -> Void,
        onChange: @escaping (ScreenshotHotKey?) -> Bool
    ) {
        self.shortcut = shortcut
        self.onRecordingChanged = onRecordingChanged
        self.onChange = onChange
        refreshPresentation()
    }

    func prepareForRemoval() {
        let wasRecording = isRecording
        isRecording = false
        localEventMonitor.remove()
        removeFocusObservers()
        NotificationCenter.default.removeObserver(self)
        if wasRecording {
            onRecordingChanged?(false)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isRecording {
            cancelRecording()
        }
        return didResign
    }

    private func configureAppearance() {
        title = L10n.tr("未设置")
        bezelStyle = .rounded
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        isBordered = true
        focusRingType = .default
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(beginRecording)

        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.tr("录制快捷键"))
        setAccessibilityHelp(L10n.tr("点击后按下新的快捷键；按 Esc 取消，按 Delete 清除。"))
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        guard window?.makeFirstResponder(self) == true else {
            NSSound.beep()
            return
        }

        isRecording = true
        onRecordingChanged?(true)
        addFocusObservers()
        localEventMonitor.install { [weak self] event in
            guard let self, self.isRecording else { return }
            self.handleRecordingEvent(event)
        }
        refreshPresentation()
    }

    @objc private func focusWasLost(_ notification: Notification) {
        guard isRecording else { return }
        cancelRecording()
    }

    private func cancelRecording() {
        finishRecording()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        localEventMonitor.remove()
        removeFocusObservers()
        onRecordingChanged?(false)
        refreshPresentation()

        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func handleRecordingEvent(_ event: NSEvent) {
        switch HotKeyRecorderInput.resolve(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
        case .cancel:
            finishRecording()
        case .clear:
            if onChange?(nil) == true {
                shortcut = nil
            }
            finishRecording()
        case .shortcut(let newShortcut):
            if onChange?(newShortcut) == true {
                shortcut = newShortcut
            }
            finishRecording()
        case .unsupported:
            NSSound.beep()
        }
    }

    private func refreshPresentation() {
        if isRecording {
            title = L10n.tr("请按快捷键…")
            setAccessibilityValue(L10n.tr("正在录制，请按快捷键"))
        } else {
            let value = shortcut?.displayString ?? L10n.tr("未设置")
            title = value
            setAccessibilityValue(value)
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func addFocusObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusWasLost(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusWasLost(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    private func removeFocusObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

}
