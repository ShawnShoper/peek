import AppKit
import SwiftUI

enum SearchPanelNumericShortcut {
    /// ANSI number-row key codes. Option+0 intentionally targets item 10.
    static func resultIndex(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0 // 1
        case 19: return 1 // 2
        case 20: return 2 // 3
        case 21: return 3 // 4
        case 23: return 4 // 5
        case 22: return 5 // 6
        case 26: return 6 // 7
        case 28: return 7 // 8
        case 25: return 8 // 9
        case 29: return 9 // 0
        default: return nil
        }
    }
}

@MainActor
final class SearchPanelKeyboardHostView: NSView {
    var windowDidChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange?(window)
    }
}

/// macOS 13-compatible key-command bridge. It watches only the panel that owns
/// this view, so file pickers and other application windows retain their normal
/// keyboard behavior.
struct SearchPanelKeyboardBridge: NSViewRepresentable {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let activate: () -> Void
    let activateResultAtIndex: (_ index: Int) -> Void
    let optionStateChanged: (_ isPressed: Bool) -> Void
    let cycleCategory: (_ reverse: Bool) -> Void
    let dismiss: () -> Void
    let isSearchFieldFocused: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            moveUp: moveUp,
            moveDown: moveDown,
            activate: activate,
            activateResultAtIndex: activateResultAtIndex,
            optionStateChanged: optionStateChanged,
            cycleCategory: cycleCategory,
            dismiss: dismiss,
            isSearchFieldFocused: isSearchFieldFocused
        )
    }

    func makeNSView(context: Context) -> SearchPanelKeyboardHostView {
        let view = SearchPanelKeyboardHostView(frame: .zero)
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.monitoredWindow = window
        }
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: SearchPanelKeyboardHostView, context: Context) {
        context.coordinator.moveUp = moveUp
        context.coordinator.moveDown = moveDown
        context.coordinator.activate = activate
        context.coordinator.activateResultAtIndex = activateResultAtIndex
        context.coordinator.optionStateChanged = optionStateChanged
        context.coordinator.cycleCategory = cycleCategory
        context.coordinator.dismiss = dismiss
        context.coordinator.isSearchFieldFocused = isSearchFieldFocused
    }

    static func dismantleNSView(
        _ nsView: SearchPanelKeyboardHostView,
        coordinator: Coordinator
    ) {
        nsView.windowDidChange = nil
        coordinator.monitoredWindow = nil
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var monitoredWindow: NSWindow?
        var moveUp: () -> Void
        var moveDown: () -> Void
        var activate: () -> Void
        var activateResultAtIndex: (_ index: Int) -> Void
        var optionStateChanged: (_ isPressed: Bool) -> Void
        var cycleCategory: (_ reverse: Bool) -> Void
        var dismiss: () -> Void
        var isSearchFieldFocused: () -> Bool
        private var eventMonitor: Any?

        init(
            moveUp: @escaping () -> Void,
            moveDown: @escaping () -> Void,
            activate: @escaping () -> Void,
            activateResultAtIndex: @escaping (_ index: Int) -> Void,
            optionStateChanged: @escaping (_ isPressed: Bool) -> Void,
            cycleCategory: @escaping (_ reverse: Bool) -> Void,
            dismiss: @escaping () -> Void,
            isSearchFieldFocused: @escaping () -> Bool
        ) {
            self.moveUp = moveUp
            self.moveDown = moveDown
            self.activate = activate
            self.activateResultAtIndex = activateResultAtIndex
            self.optionStateChanged = optionStateChanged
            self.cycleCategory = cycleCategory
            self.dismiss = dismiss
            self.isSearchFieldFocused = isSearchFieldFocused
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            optionStateChanged(NSEvent.modifierFlags.contains(.option))
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged]
            ) { [weak self] event in
                guard let self,
                      let monitoredWindow,
                      event.window === monitoredWindow || NSApp.keyWindow === monitoredWindow else {
                    return event
                }

                if event.type == .flagsChanged {
                    optionStateChanged(event.modifierFlags.contains(.option))
                    return event
                }

                // Let the input method consume arrows/return/escape while the
                // user is choosing a marked-text candidate.
                if let editor = event.window?.firstResponder as? NSTextView,
                   editor.hasMarkedText() {
                    return event
                }

                let modifiers = event.modifierFlags.intersection([
                    .command,
                    .control,
                    .option,
                    .shift
                ])

                if modifiers == .option,
                   let index = SearchPanelNumericShortcut.resultIndex(
                       forKeyCode: event.keyCode
                   ) {
                    activateResultAtIndex(index)
                    return nil
                }

                switch event.keyCode {
                case 126: // Up arrow
                    guard modifiers.isEmpty else { return event }
                    moveUp()
                case 125: // Down arrow
                    guard modifiers.isEmpty else { return event }
                    moveDown()
                case 36, 76: // Return / keypad Enter
                    guard modifiers.isEmpty else { return event }
                    activate()
                case 48: // Tab / Shift-Tab
                    guard isSearchFieldFocused(),
                          modifiers.isEmpty || modifiers == .shift else {
                        return event
                    }
                    cycleCategory(event.modifierFlags.contains(.shift))
                case 53: // Escape
                    guard modifiers.isEmpty else { return event }
                    dismiss()
                default:
                    return event
                }
                return nil
            }
        }

        func stopMonitoring() {
            optionStateChanged(false)
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
