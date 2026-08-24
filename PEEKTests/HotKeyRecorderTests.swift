import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PEEK

final class HotKeyRecorderTests: XCTestCase {
    func testCommandOptionAResolvesToSupportedShortcut() throws {
        let input = HotKeyRecorderInput.resolve(
            keyCode: UInt16(kVK_ANSI_A),
            modifierFlags: [.command, .option]
        )
        let shortcut: ScreenshotHotKey
        switch input {
        case .shortcut(let value):
            shortcut = value
        default:
            XCTFail("Command-Option-A should be accepted")
            return
        }

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(shortcut.displayString, "⌥⌘A")
    }

    func testEscapeCancelsAndDeleteClearsWithoutModifiers() {
        XCTAssertEqual(
            HotKeyRecorderInput.resolve(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: []
            ),
            .cancel
        )
        XCTAssertEqual(
            HotKeyRecorderInput.resolve(
                keyCode: UInt16(kVK_Delete),
                modifierFlags: []
            ),
            .clear
        )
    }

    func testUnmodifiedLetterIsRejected() {
        XCTAssertEqual(
            HotKeyRecorderInput.resolve(
                keyCode: UInt16(kVK_ANSI_A),
                modifierFlags: []
            ),
            .unsupported
        )
    }

    @MainActor
    func testLocalMonitorConsumesCommandKeyEquivalentAndIsRemoved() throws {
        let token = NSObject()
        var installedHandler: HotKeyRecorderLocalEventMonitor.Handler?
        var removedToken: Any?
        let monitor = HotKeyRecorderLocalEventMonitor(
            installer: { handler in
                installedHandler = handler
                return token
            },
            remover: { removedToken = $0 }
        )
        var receivedEvent: NSEvent?

        monitor.install { receivedEvent = $0 }
        XCTAssertTrue(monitor.isInstalled)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_A)
        ))
        XCTAssertNil(try XCTUnwrap(installedHandler)(event))
        XCTAssertTrue(receivedEvent === event)

        monitor.remove()
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertTrue((removedToken as AnyObject) === token)
    }

    @MainActor
    func testRejectedCandidateKeepsPreviousConfigurationAndPersistence() throws {
        let suiteName = "HotKeyRecorderTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)
        let previousConfiguration = manager.configuration

        XCTAssertThrowsError(try manager.update(
            shortcut: ScreenshotGlobalHotKeyAction.scrolling.defaultShortcut,
            for: .region
        ))
        XCTAssertEqual(manager.configuration, previousConfiguration)
        XCTAssertNil(userDefaults.data(forKey: ScreenshotGlobalHotKeyManager.storageKey))
    }

    @MainActor
    func testRecordingCancellationDoesNotChangeConfiguration() throws {
        let suiteName = "HotKeyRecorderTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)
        let previousConfiguration = manager.configuration

        manager.beginRecordingShortcut(for: .region)
        manager.endRecordingShortcut(for: .region)

        XCTAssertEqual(manager.configuration, previousConfiguration)
        XCTAssertNil(userDefaults.data(forKey: ScreenshotGlobalHotKeyManager.storageKey))
    }
}
