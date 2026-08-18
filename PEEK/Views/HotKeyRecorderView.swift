import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    let shortcut: ScreenshotHotKey?
    let onChange: (ScreenshotHotKey?) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.update(shortcut: shortcut, onChange: onChange)
        return button
    }

    func updateNSView(_ nsView: HotKeyRecorderButton, context: Context) {
        nsView.update(shortcut: shortcut, onChange: onChange)
    }
}

final class HotKeyRecorderButton: NSButton {
    private static let acceptedModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift,
    ]

    private var shortcut: ScreenshotHotKey?
    private var onChange: ((ScreenshotHotKey?) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        configureAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(
        shortcut: ScreenshotHotKey?,
        onChange: @escaping (ScreenshotHotKey?) -> Void
    ) {
        self.shortcut = shortcut
        self.onChange = onChange
        refreshPresentation()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let independentFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Self.acceptedModifierFlags)

        if event.keyCode == UInt16(kVK_Escape), independentFlags.isEmpty {
            finishRecording()
            return
        }

        if (event.keyCode == UInt16(kVK_Delete)
            || event.keyCode == UInt16(kVK_ForwardDelete)),
            independentFlags.isEmpty {
            shortcut = nil
            finishRecording()
            onChange?(nil)
            return
        }

        let carbonModifiers = Self.carbonModifiers(from: independentFlags)
        let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
        guard carbonModifiers & requiredModifiers != 0 else {
            NSSound.beep()
            return
        }

        let newShortcut = ScreenshotHotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )
        guard newShortcut.isValid else {
            NSSound.beep()
            return
        }

        shortcut = newShortcut
        finishRecording()
        onChange?(newShortcut)
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
        addFocusObservers()
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
        removeFocusObservers()
        refreshPresentation()

        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
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

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
