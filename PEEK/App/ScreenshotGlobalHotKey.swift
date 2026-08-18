import Carbon.HIToolbox
import Combine
import Foundation

enum ScreenshotGlobalHotKeyAction: UInt32, CaseIterable, Codable, Identifiable, Sendable {
    case region = 1
    case scrolling = 2
    case ocr = 3
    case search = 4

    var id: UInt32 { rawValue }

    var displayName: String {
        switch self {
        case .region:
            return L10n.tr("区域截图")
        case .scrolling:
            return L10n.tr("滚动截图")
        case .ocr:
            return L10n.tr("截图 OCR")
        case .search:
            return L10n.tr("文件查找")
        }
    }

    var defaultShortcut: ScreenshotHotKey {
        let modifiers = UInt32(cmdKey | optionKey)
        switch self {
        case .region:
            return ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers)
        case .scrolling:
            return ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers)
        case .ocr:
            return ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: modifiers)
        case .search:
            return ScreenshotHotKey(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey)
            )
        }
    }

}

struct ScreenshotHotKey: Codable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let supportedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let requiredModifiers = UInt32(cmdKey | optionKey | controlKey)
    static let applicationReservedShortcuts: Set<ScreenshotHotKey> = [
        ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey)),
        ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey)),
        ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
    ]

    var isValid: Bool {
        modifiers & Self.requiredModifiers != 0
            && modifiers & ~Self.supportedModifiers == 0
            && keyDisplayName != nil
    }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyDisplayName ?? L10n.tr("未知键")
        return result
    }

    var keyDisplayName: String? {
        Self.keyDisplayNames[keyCode]
    }

    private static let keyDisplayNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_Space): L10n.tr("空格"),
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_ANSI_Keypad0): L10n.tr("小键盘0"),
        UInt32(kVK_ANSI_Keypad1): L10n.tr("小键盘1"),
        UInt32(kVK_ANSI_Keypad2): L10n.tr("小键盘2"),
        UInt32(kVK_ANSI_Keypad3): L10n.tr("小键盘3"),
        UInt32(kVK_ANSI_Keypad4): L10n.tr("小键盘4"),
        UInt32(kVK_ANSI_Keypad5): L10n.tr("小键盘5"),
        UInt32(kVK_ANSI_Keypad6): L10n.tr("小键盘6"),
        UInt32(kVK_ANSI_Keypad7): L10n.tr("小键盘7"),
        UInt32(kVK_ANSI_Keypad8): L10n.tr("小键盘8"),
        UInt32(kVK_ANSI_Keypad9): L10n.tr("小键盘9"),
        UInt32(kVK_ANSI_KeypadDecimal): L10n.tr("小键盘."),
        UInt32(kVK_ANSI_KeypadMultiply): L10n.tr("小键盘×"),
        UInt32(kVK_ANSI_KeypadPlus): L10n.tr("小键盘+"),
        UInt32(kVK_ANSI_KeypadClear): L10n.tr("小键盘清除"),
        UInt32(kVK_ANSI_KeypadDivide): L10n.tr("小键盘÷"),
        UInt32(kVK_ANSI_KeypadMinus): L10n.tr("小键盘-"),
        UInt32(kVK_ANSI_KeypadEquals): L10n.tr("小键盘="),
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20"
    ]
}

enum ScreenshotHotKeyConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidShortcut(ScreenshotGlobalHotKeyAction)
    case duplicateShortcut(ScreenshotGlobalHotKeyAction, ScreenshotGlobalHotKeyAction)
    case applicationReservedShortcut(ScreenshotGlobalHotKeyAction)

    var errorDescription: String? {
        switch self {
        case .invalidShortcut(let action):
            return L10n.tr(
                "“%@”快捷键无效，请至少使用 Command、Option 或 Control 中的一个修饰键",
                action.displayName
            )
        case .duplicateShortcut(let first, let second):
            return L10n.tr("“%@”与“%@”不能使用相同快捷键", first.displayName, second.displayName)
        case .applicationReservedShortcut(let action):
            return L10n.tr("“%@”不能使用 PEEK 菜单已经占用的快捷键", action.displayName)
        }
    }
}

struct ScreenshotHotKeyConfiguration: Codable, Equatable, Sendable {
    var region: ScreenshotHotKey?
    var scrolling: ScreenshotHotKey?
    var ocr: ScreenshotHotKey?
    var search: ScreenshotHotKey?

    init(
        region: ScreenshotHotKey?,
        scrolling: ScreenshotHotKey?,
        ocr: ScreenshotHotKey?,
        search: ScreenshotHotKey? = ScreenshotGlobalHotKeyAction.search.defaultShortcut
    ) {
        self.region = region
        self.scrolling = scrolling
        self.ocr = ocr
        self.search = search
    }

    static let defaults = ScreenshotHotKeyConfiguration(
        region: ScreenshotGlobalHotKeyAction.region.defaultShortcut,
        scrolling: ScreenshotGlobalHotKeyAction.scrolling.defaultShortcut,
        ocr: ScreenshotGlobalHotKeyAction.ocr.defaultShortcut,
        search: ScreenshotGlobalHotKeyAction.search.defaultShortcut
    )

    subscript(action: ScreenshotGlobalHotKeyAction) -> ScreenshotHotKey? {
        get {
            switch action {
            case .region: return region
            case .scrolling: return scrolling
            case .ocr: return ocr
            case .search: return search
            }
        }
        set {
            switch action {
            case .region: region = newValue
            case .scrolling: scrolling = newValue
            case .ocr: ocr = newValue
            case .search: search = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case region
        case scrolling
        case ocr
        case search
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decodeIfPresent(ScreenshotHotKey.self, forKey: .region)
        scrolling = try container.decodeIfPresent(ScreenshotHotKey.self, forKey: .scrolling)
        ocr = try container.decodeIfPresent(ScreenshotHotKey.self, forKey: .ocr)
        // Migrate configurations saved before file search existed. An explicit
        // JSON null still represents a user-disabled shortcut.
        search = container.contains(.search)
            ? try container.decodeIfPresent(ScreenshotHotKey.self, forKey: .search)
            : ScreenshotGlobalHotKeyAction.search.defaultShortcut
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(scrolling, forKey: .scrolling)
        try container.encodeIfPresent(ocr, forKey: .ocr)
        if let search {
            try container.encode(search, forKey: .search)
        } else {
            try container.encodeNil(forKey: .search)
        }
    }

    func validate() throws {
        var usedShortcuts: [ScreenshotHotKey: ScreenshotGlobalHotKeyAction] = [:]
        for action in ScreenshotGlobalHotKeyAction.allCases {
            guard let shortcut = self[action] else { continue }
            guard shortcut.isValid else {
                throw ScreenshotHotKeyConfigurationError.invalidShortcut(action)
            }
            if ScreenshotHotKey.applicationReservedShortcuts.contains(shortcut) {
                throw ScreenshotHotKeyConfigurationError.applicationReservedShortcut(action)
            }
            if let previousAction = usedShortcuts[shortcut] {
                throw ScreenshotHotKeyConfigurationError.duplicateShortcut(previousAction, action)
            }
            usedShortcuts[shortcut] = action
        }
    }

    var isValid: Bool {
        (try? validate()) != nil
    }
}

enum ScreenshotHotKeyRegistrationState: Equatable, Sendable {
    case success
    case systemConflict
    case failure(OSStatus)

    var localizedDescription: String {
        switch self {
        case .success:
            return L10n.tr("已启用")
        case .systemConflict:
            return L10n.tr("快捷键与 macOS 系统快捷键冲突")
        case .failure(let status) where status == OSStatus(eventHotKeyExistsErr):
            return L10n.tr("快捷键已被系统或其他应用占用")
        case .failure(let status) where status == OSStatus(eventHotKeyInvalidErr):
            return L10n.tr("快捷键无效，无法注册")
        case .failure(let status):
            return L10n.tr("快捷键注册失败（OSStatus %d）", status)
        }
    }
}

enum ScreenshotGlobalHotKeyManagerError: Error, Equatable, LocalizedError, Sendable {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(ScreenshotGlobalHotKeyAction, OSStatus)
    case systemShortcutConflict(ScreenshotGlobalHotKeyAction)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallationFailed(let status):
            return L10n.tr("无法启动全局快捷键监听（OSStatus %d）", status)
        case .systemShortcutConflict(let action):
            return L10n.tr(
                "“%@”快捷键与已启用的 macOS 系统快捷键冲突",
                action.displayName
            )
        case .registrationFailed(let action, let status)
            where status == OSStatus(eventHotKeyExistsErr):
            return L10n.tr("“%@”快捷键已被系统或其他应用占用", action.displayName)
        case .registrationFailed(let action, let status)
            where status == OSStatus(eventHotKeyInvalidErr):
            return L10n.tr("“%@”快捷键无效，无法注册", action.displayName)
        case .registrationFailed(let action, let status):
            return L10n.tr("“%@”快捷键注册失败（OSStatus %d）", action.displayName, status)
        }
    }
}

enum ScreenshotSystemHotKeyCheckResult: Equatable, Sendable {
    case available(Set<ScreenshotHotKey>)
    case unavailable(OSStatus)
}

/// Reads the effective system-wide shortcuts through the public Carbon API.
/// This covers Keyboard Settings items such as screenshots, accessibility and
/// keyboard navigation. Application-specific shortcuts are outside that API.
@MainActor
enum ScreenshotSystemHotKeyConflictDetector {
    static func check() -> ScreenshotSystemHotKeyCheckResult {
        var unmanagedHotKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanagedHotKeys)
        guard status == noErr else {
            return .unavailable(status)
        }
        guard let hotKeys = unmanagedHotKeys?.takeRetainedValue() else {
            return .unavailable(OSStatus(memFullErr))
        }
        return .available(enabledShortcuts(from: hotKeys as NSArray))
    }

    static func enabledShortcuts(from entries: NSArray) -> Set<ScreenshotHotKey> {
        var shortcuts = Set<ScreenshotHotKey>()
        for rawEntry in entries {
            guard let entry = rawEntry as? NSDictionary,
                  let enabled = entry.object(
                    forKey: kHISymbolicHotKeyEnabled as String
                  ) as? NSNumber,
                  enabled.boolValue,
                  let keyCode = entry.object(
                    forKey: kHISymbolicHotKeyCode as String
                  ) as? NSNumber,
                  let modifiers = entry.object(
                    forKey: kHISymbolicHotKeyModifiers as String
                  ) as? NSNumber else {
                continue
            }
            shortcuts.insert(ScreenshotHotKey(
                keyCode: keyCode.uint32Value,
                modifiers: modifiers.uint32Value & ScreenshotHotKey.supportedModifiers
            ))
        }
        return shortcuts
    }
}

/// Registers exclusive Carbon hot keys. A replacement is registered before
/// its predecessor is removed, so a failed customization never disables the
/// shortcut that was already working.
@MainActor
final class ScreenshotGlobalHotKeyManager: ObservableObject {
    static let shared = ScreenshotGlobalHotKeyManager()
    static let storageKey = "screenshot.hotkeys.v1"

    @Published private(set) var configuration: ScreenshotHotKeyConfiguration
    @Published private(set) var registrationStates: [
        ScreenshotGlobalHotKeyAction: ScreenshotHotKeyRegistrationState
    ] = [:]
    @Published private(set) var systemConflictCheckStatus: OSStatus?

    private struct Registration {
        let reference: EventHotKeyRef
        let eventID: UInt32
        let shortcut: ScreenshotHotKey
    }

    private let signature: OSType = 0x41495348 // "AISH"
    private let userDefaults: UserDefaults
    private var eventHandler: EventHandlerRef?
    private var registrations: [ScreenshotGlobalHotKeyAction: Registration] = [:]
    private var actionsByEventID: [UInt32: ScreenshotGlobalHotKeyAction] = [:]
    private var nextEventID: UInt32 = 1
    private var actionHandler: (@MainActor (ScreenshotGlobalHotKeyAction) -> Void)?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        configuration = Self.loadConfiguration(from: userDefaults)
    }

    func start(actionHandler: @escaping @MainActor (ScreenshotGlobalHotKeyAction) -> Void) {
        self.actionHandler = actionHandler
        do {
            try installEventHandlerIfNeeded()
        } catch let error as ScreenshotGlobalHotKeyManagerError {
            let status: OSStatus
            switch error {
            case .eventHandlerInstallationFailed(let value): status = value
            case .registrationFailed(_, let value): status = value
            case .systemShortcutConflict: return
            }
            for action in ScreenshotGlobalHotKeyAction.allCases where configuration[action] != nil {
                registrationStates[action] = .failure(status)
            }
            return
        } catch {
            return
        }

        for action in ScreenshotGlobalHotKeyAction.allCases {
            guard registrations[action] == nil,
                  let shortcut = configuration[action] else {
                if registrations[action] == nil {
                    registrationStates.removeValue(forKey: action)
                }
                continue
            }
            do {
                let registration = try register(shortcut, for: action)
                registrations[action] = registration
                registrationStates[action] = .success
            } catch let error as ScreenshotGlobalHotKeyManagerError {
                switch error {
                case .systemShortcutConflict:
                    registrationStates[action] = .systemConflict
                case .registrationFailed(_, let status):
                    registrationStates[action] = .failure(status)
                case .eventHandlerInstallationFailed(let status):
                    registrationStates[action] = .failure(status)
                }
            } catch {
                registrationStates[action] = .failure(OSStatus(paramErr))
            }
        }
    }

    func stop() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()
        actionsByEventID.removeAll()
        registrationStates.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        actionHandler = nil
    }

    func shortcut(for action: ScreenshotGlobalHotKeyAction) -> ScreenshotHotKey? {
        configuration[action]
    }

    func update(
        shortcut: ScreenshotHotKey,
        for action: ScreenshotGlobalHotKeyAction
    ) throws {
        var candidate = configuration
        candidate[action] = shortcut
        try candidate.validate()
        let encodedConfiguration = try JSONEncoder().encode(candidate)
        try installEventHandlerIfNeeded()
        try ensureAvailable(shortcut, for: action)

        if let current = registrations[action], current.shortcut == shortcut {
            configuration = candidate
            userDefaults.set(encodedConfiguration, forKey: Self.storageKey)
            registrationStates[action] = .success
            return
        }

        let replacement: Registration
        do {
            replacement = try registerUnchecked(shortcut, for: action)
        } catch {
            // The existing registration and persisted configuration remain intact.
            throw error
        }

        if let current = registrations[action] {
            UnregisterEventHotKey(current.reference)
            actionsByEventID.removeValue(forKey: current.eventID)
        }
        registrations[action] = replacement
        configuration = candidate
        userDefaults.set(encodedConfiguration, forKey: Self.storageKey)
        registrationStates[action] = .success
    }

    func disable(_ action: ScreenshotGlobalHotKeyAction) {
        if let registration = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(registration.reference)
            actionsByEventID.removeValue(forKey: registration.eventID)
        }
        configuration[action] = nil
        registrationStates.removeValue(forKey: action)
        persistConfiguration()
    }

    func disable(for action: ScreenshotGlobalHotKeyAction) {
        disable(action)
    }

    func restoreDefaults() throws {
        let candidate = ScreenshotHotKeyConfiguration.defaults
        try candidate.validate()
        let encodedConfiguration = try JSONEncoder().encode(candidate)
        try installEventHandlerIfNeeded()

        // Reuse any existing registration that already owns a desired default
        // shortcut, even when it currently belongs to a different action. This
        // makes cross-swaps transactional without briefly dropping working keys.
        var desiredRegistrations: [ScreenshotGlobalHotKeyAction: Registration] = [:]
        var newlyRegistered: [Registration] = []
        do {
            for action in ScreenshotGlobalHotKeyAction.allCases {
                guard let desiredShortcut = candidate[action] else { continue }
                try ensureAvailable(desiredShortcut, for: action)
                if let existing = registrations.values.first(where: {
                    $0.shortcut == desiredShortcut
                }) {
                    desiredRegistrations[action] = existing
                } else {
                    let registration = try registerUnchecked(desiredShortcut, for: action)
                    desiredRegistrations[action] = registration
                    newlyRegistered.append(registration)
                }
            }
        } catch {
            for registration in newlyRegistered {
                UnregisterEventHotKey(registration.reference)
                actionsByEventID.removeValue(forKey: registration.eventID)
            }
            throw error
        }

        let desiredEventIDs = Set(desiredRegistrations.values.map(\.eventID))
        for registration in registrations.values
            where !desiredEventIDs.contains(registration.eventID) {
            UnregisterEventHotKey(registration.reference)
            actionsByEventID.removeValue(forKey: registration.eventID)
        }
        for (action, registration) in desiredRegistrations {
            actionsByEventID[registration.eventID] = action
        }
        registrations = desiredRegistrations

        configuration = candidate
        userDefaults.set(encodedConfiguration, forKey: Self.storageKey)
        for action in ScreenshotGlobalHotKeyAction.allCases {
            if registrations[action] != nil {
                registrationStates[action] = .success
            } else {
                registrationStates.removeValue(forKey: action)
            }
        }
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var identifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard parameterStatus == noErr else { return parameterStatus }

                let manager = Unmanaged<ScreenshotGlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                let signature = identifier.signature
                let eventID = identifier.id
                Task { @MainActor in
                    manager.dispatch(signature: signature, eventID: eventID)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            eventHandler = nil
            throw ScreenshotGlobalHotKeyManagerError.eventHandlerInstallationFailed(status)
        }
    }

    private func register(
        _ shortcut: ScreenshotHotKey,
        for action: ScreenshotGlobalHotKeyAction
    ) throws -> Registration {
        guard shortcut.isValid else {
            throw ScreenshotHotKeyConfigurationError.invalidShortcut(action)
        }
        try ensureAvailable(shortcut, for: action)
        return try registerUnchecked(shortcut, for: action)
    }

    private func ensureAvailable(
        _ shortcut: ScreenshotHotKey,
        for action: ScreenshotGlobalHotKeyAction
    ) throws {
        switch ScreenshotSystemHotKeyConflictDetector.check() {
        case .available(let systemShortcuts):
            systemConflictCheckStatus = nil
            if systemShortcuts.contains(shortcut) {
                throw ScreenshotGlobalHotKeyManagerError.systemShortcutConflict(action)
            }
        case .unavailable(let status):
            // Keep Carbon exclusive registration as the final arbiter, but
            // expose that the broader system shortcut scan was unavailable.
            systemConflictCheckStatus = status
        }
    }

    private func registerUnchecked(
        _ shortcut: ScreenshotHotKey,
        for action: ScreenshotGlobalHotKeyAction
    ) throws -> Registration {
        let eventID = allocateEventID()
        let identifier = EventHotKeyID(signature: signature, id: eventID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            throw ScreenshotGlobalHotKeyManagerError.registrationFailed(action, status)
        }
        actionsByEventID[eventID] = action
        return Registration(reference: reference, eventID: eventID, shortcut: shortcut)
    }

    private func allocateEventID() -> UInt32 {
        while nextEventID == 0 || actionsByEventID[nextEventID] != nil {
            nextEventID &+= 1
        }
        let result = nextEventID
        nextEventID &+= 1
        return result
    }

    private func dispatch(signature: OSType, eventID: UInt32) {
        guard signature == self.signature,
              let action = actionsByEventID[eventID] else {
            return
        }
        actionHandler?(action)
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func loadConfiguration(from userDefaults: UserDefaults) -> ScreenshotHotKeyConfiguration {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ScreenshotHotKeyConfiguration.self, from: data),
              decoded.isValid else {
            return .defaults
        }
        return decoded
    }
}
