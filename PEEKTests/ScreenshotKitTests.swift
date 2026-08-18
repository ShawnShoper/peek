import AppKit
import Carbon.HIToolbox
import CoreImage
import Foundation
import XCTest
@testable import PEEK

final class ScreenshotKitTests: XCTestCase {
    func testScreenshotHotkeyDoesNotAddPresentationDelay() {
        XCTAssertEqual(
            ScreenshotCapturePresentationDelay.hotKeyNanoseconds,
            0
        )
        XCTAssertEqual(
            ScreenshotCapturePresentationDelay.uiDismissalNanoseconds,
            160_000_000
        )
    }

    @MainActor
    func testSettingsWindowPresenterRecognizesOnlySwiftUISettingsWindow() {
        let settingsWindow = NSWindow()
        settingsWindow.identifier = NSUserInterfaceItemIdentifier(
            "com_apple_SwiftUI_Settings_window"
        )
        let unrelatedWindow = NSWindow()
        unrelatedWindow.identifier = NSUserInterfaceItemIdentifier("PEEK.search")

        XCTAssertTrue(PEEKSettingsWindowPresenter.isSettingsWindow(settingsWindow))
        XCTAssertFalse(PEEKSettingsWindowPresenter.isSettingsWindow(unrelatedWindow))
    }

    func testPEEKBrandUsesExpectedDisplayNameAndTemplateMenuIcon() throws {
        XCTAssertEqual(AppBrand.displayName, "PEEK")
        let hostAppURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let hostAppBundle = try XCTUnwrap(Bundle(url: hostAppURL))
        XCTAssertEqual(
            hostAppBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "PEEK"
        )
        let menuIcon = try XCTUnwrap(
            hostAppBundle.image(
                forResource: NSImage.Name(AppBrand.menuBarIconAssetName)
            )
        )
        XCTAssertTrue(menuIcon.isTemplate)
    }

    func testOCRLayoutFormatterPreservesIndentationBlankLinesAndColumns() {
        let imageSize = CGSize(width: 1_000, height: 1_000)
        func observation(_ text: String, _ rect: CGRect) -> PEEKOCRObservation {
            PEEKOCRObservation(
                id: UUID(),
                text: text,
                confidence: 0.99,
                normalizedBoundingBox: CGRect(
                    x: rect.minX / imageSize.width,
                    y: (imageSize.height - rect.maxY) / imageSize.height,
                    width: rect.width / imageSize.width,
                    height: rect.height / imageSize.height
                )
            )
        }

        let result = PEEKOCRLayoutFormatter.formattedText(
            observations: [
                observation("func demo() {", CGRect(x: 100, y: 80, width: 208, height: 40)),
                observation("let value = 42", CGRect(x: 168, y: 140, width: 224, height: 40)),
                observation("}", CGRect(x: 100, y: 200, width: 16, height: 40)),
                observation("Name", CGRect(x: 100, y: 330, width: 64, height: 40)),
                observation("Value", CGRect(x: 500, y: 330, width: 80, height: 40))
            ],
            imageSize: imageSize
        )

        XCTAssertTrue(result.contains("func demo() {\n    let value = 42\n}"))
        XCTAssertTrue(result.contains("}\n\nName"))
        let columnsLine = result.split(separator: "\n").first { $0.contains("Name") }
        let unwrappedColumnsLine = String(columnsLine ?? "")
        XCTAssertTrue(unwrappedColumnsLine.contains("Name"))
        XCTAssertTrue(unwrappedColumnsLine.contains("Value"))
        XCTAssertGreaterThanOrEqual(
            unwrappedColumnsLine.components(separatedBy: "Name")[1]
                .components(separatedBy: "Value")[0]
                .count,
            8
        )
    }

    func testOCRLayoutFormatterBuildsReadableRTFClipboardPayload() throws {
        let source = "标题\n    保留缩进\nColumn A        Column B"
        let data = try XCTUnwrap(PEEKOCRLayoutFormatter.richTextData(source))
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )

        XCTAssertEqual(decoded.string, source)
        XCTAssertTrue(data.count > source.utf8.count)
    }

    func testQRCodePayloadClassifierSeparatesTextAndSafeWebURLs() throws {
        XCTAssertEqual(
            PEEKQRCodePayloadClassifier.classify(string: "  普通文本  "),
            .text("普通文本")
        )
        XCTAssertEqual(
            PEEKQRCodePayloadClassifier.classify(
                string: "https://example.com/path?q=二维码"
            ),
            .url(try XCTUnwrap(URL(string: "https://example.com/path?q=二维码")))
        )
        XCTAssertEqual(
            PEEKQRCodePayloadClassifier.classify(string: "javascript:alert(1)"),
            .text("javascript:alert(1)")
        )
        XCTAssertEqual(
            PEEKQRCodePayloadClassifier.classify(string: "https://example.com/photo.png"),
            .url(try XCTUnwrap(URL(string: "https://example.com/photo.png")))
        )
    }

    @MainActor
    func testQRCodePayloadClassifierDecodesEmbeddedPNG() throws {
        let pngData = try makeTestPNGData()
        let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"
        guard case let .image(decodedData, mimeType)? =
            PEEKQRCodePayloadClassifier.classify(string: dataURL) else {
            return XCTFail("Expected embedded image payload")
        }
        XCTAssertEqual(decodedData, pngData)
        XCTAssertEqual(mimeType, "image/png")
    }

    @MainActor
    func testQRCodePayloadClassifierUsesRawImageDataBeforeString() throws {
        let pngData = try makeTestPNGData()
        guard case let .image(decodedData, _)? =
            PEEKQRCodePayloadClassifier.classify(
                string: "fallback text",
                data: pngData
            ) else {
            return XCTFail("Expected raw image payload")
        }
        XCTAssertEqual(decodedData, pngData)
        XCTAssertNil(PEEKQRCodePayloadClassifier.classify(string: nil, data: Data()))
    }

    func testQRCodeServiceRecognizesGeneratedTextQRCode() async throws {
        let message = "PEEK 二维码测试"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) != nil else {
            throw XCTSkip("Core Image QR rendering is unavailable in this XCTest host")
        }

        let service = PEEKQRCodeService()
        let containsQRCode = try await service.containsQRCode(image: image)
        XCTAssertTrue(containsQRCode)
        let result = try await service.recognize(image: image)

        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.observations[0].payload, .text(message))
    }

    @MainActor
    func testQRCodeProbeUsesBackgroundDetectionResultForHintDecision() async throws {
        let image = NSImage(size: CGSize(width: 96, height: 96), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }

        let detected = try await PEEKQRCodeService(qrCodeProbe: { _ in true })
            .containsQRCode(image: image)
        let notDetected = try await PEEKQRCodeService(qrCodeProbe: { _ in false })
            .containsQRCode(image: image)

        XCTAssertTrue(detected)
        XCTAssertFalse(notDetected)
    }

    func testCaptureErrorsProvideActionableRecoveryMessages() {
        XCTAssertEqual(
            ScreenshotCaptureError.screenRecordingPermissionDenied.errorDescription,
            "未获得屏幕录制权限，请在系统设置中授权后重试"
        )
        XCTAssertTrue(
            ScreenshotCaptureError.screenRecordingPermissionRequiresRestart
                .errorDescription?
                .contains("重新启动") == true
        )
        XCTAssertTrue(
            ScreenshotCaptureError.selectionTimedOut
                .errorDescription?
                .contains("60 秒") == true
        )
    }

    func testScrollFrameCapturerUsesInjectedModernBackend() async throws {
        let expectedRect = CGRect(x: 120, y: 80, width: 64, height: 48)
        let expectedImage = try makeSolidPixelBuffer(
            width: 64,
            height: 48,
            value: 140
        ).makeCGImage()
        let backend = RecordingScreenImageCapturer(image: expectedImage)
        let capturer = QuartzScrollFrameCapturer(
            screenCapturer: backend,
            permissionGranted: { true }
        )

        let result = try await capturer.capture(rect: expectedRect)

        XCTAssertEqual(result.width, expectedImage.width)
        XCTAssertEqual(result.height, expectedImage.height)
        let capturedRects = await backend.capturedRects()
        XCTAssertEqual(capturedRects, [expectedRect])
    }

    func testScrollFrameCapturerFailsBeforeBackendWhenPermissionDenied() async throws {
        let image = try makeSolidPixelBuffer(width: 2, height: 2, value: 0)
            .makeCGImage()
        let backend = RecordingScreenImageCapturer(image: image)
        let capturer = QuartzScrollFrameCapturer(
            screenCapturer: backend,
            permissionGranted: { false }
        )

        do {
            _ = try await capturer.capture(
                rect: CGRect(x: 0, y: 0, width: 2, height: 2)
            )
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(
                error as? ScrollCaptureError,
                .screenRecordingPermissionDenied
            )
        }
        let capturedRects = await backend.capturedRects()
        XCTAssertTrue(capturedRects.isEmpty)
    }

    func testSelectionClickAndDragThresholdDoNotConflict() {
        let start = CGPoint(x: 120, y: 80)
        XCTAssertFalse(
            screenshotSelectionGestureIsDrag(
                from: start,
                to: CGPoint(x: 123.99, y: 80)
            )
        )
        XCTAssertTrue(
            screenshotSelectionGestureIsDrag(
                from: start,
                to: CGPoint(x: 124, y: 80)
            )
        )
        XCTAssertTrue(
            screenshotSelectionGestureIsDrag(
                from: start,
                to: CGPoint(x: 123, y: 83)
            )
        )
    }

    func testPixelCoordinateUsesRetinaScaleAndAppKitTopConversion() {
        let frame = CGRect(x: -100, y: 50, width: 100, height: 50)
        XCTAssertEqual(
            screenshotPixelCoordinate(
                at: CGPoint(x: -100, y: 100),
                screenFrame: frame,
                pixelWidth: 200,
                pixelHeight: 100
            ),
            ScreenshotPixelCoordinate(x: 0, y: 0)
        )
        XCTAssertEqual(
            screenshotPixelCoordinate(
                at: CGPoint(x: 0, y: 50),
                screenFrame: frame,
                pixelWidth: 200,
                pixelHeight: 100
            ),
            ScreenshotPixelCoordinate(x: 199, y: 99)
        )
        XCTAssertEqual(
            screenshotPixelCoordinate(
                at: CGPoint(x: -50, y: 75),
                screenFrame: frame,
                pixelWidth: 200,
                pixelHeight: 100
            ),
            ScreenshotPixelCoordinate(x: 100, y: 50)
        )
    }

    func testPixelColorFormatsRGBAndHexForClipboard() throws {
        let color = try XCTUnwrap(
            ScreenshotPixelColor(
                color: NSColor(
                    srgbRed: 47.0 / 255,
                    green: 128.0 / 255,
                    blue: 237.0 / 255,
                    alpha: 1
                )
            )
        )
        XCTAssertEqual(color.hexString, "#2F80ED")
        XCTAssertEqual(color.rgbString, "RGB(47, 128, 237)")
        XCTAssertEqual(color.clipboardString, "RGB(47, 128, 237)  #2F80ED")
    }

    func testEditorZoomKeepsFitAtOneAndClampsPanAtTwoTimes() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
        let fit = screenshotEditorDisplayedImageRect(
            imageSize: CGSize(width: 200, height: 100),
            viewportBounds: viewport,
            contentInset: 20,
            zoomScale: 1,
            panOffset: CGSize(width: 500, height: -500)
        )
        XCTAssertEqual(fit, CGRect(x: 20, y: 60, width: 360, height: 180))

        let zoomed = screenshotEditorDisplayedImageRect(
            imageSize: CGSize(width: 200, height: 100),
            viewportBounds: viewport,
            contentInset: 20,
            zoomScale: 2,
            panOffset: CGSize(width: 500, height: -500)
        )
        XCTAssertEqual(zoomed, CGRect(x: 20, y: -80, width: 720, height: 360))
    }

    func testGlobalScreenshotHotkeyDefaultsAndDescriptions() {
        let defaultModifiers = UInt32(cmdKey | optionKey)
        XCTAssertEqual(
            ScreenshotHotKeyConfiguration.defaults.region,
            ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: defaultModifiers)
        )
        XCTAssertEqual(
            ScreenshotHotKeyConfiguration.defaults.scrolling,
            ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: defaultModifiers)
        )
        XCTAssertEqual(
            ScreenshotHotKeyConfiguration.defaults.ocr,
            ScreenshotHotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: defaultModifiers)
        )
        XCTAssertEqual(ScreenshotGlobalHotKeyAction.region.defaultShortcut.displayString, "⌥⌘2")
        XCTAssertEqual(ScreenshotGlobalHotKeyAction.scrolling.defaultShortcut.displayString, "⌥⌘3")
        XCTAssertEqual(ScreenshotGlobalHotKeyAction.ocr.defaultShortcut.displayString, "⌥⌘4")
        XCTAssertTrue(ScreenshotHotKeyConfiguration.defaults.isValid)
    }

    func testHotkeyAcceptsSupportedKeysWithRequiredModifiers() {
        let shortcuts = [
            ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(cmdKey)
            ),
            ScreenshotHotKey(
                keyCode: UInt32(kVK_F12),
                modifiers: UInt32(optionKey | shiftKey)
            ),
            ScreenshotHotKey(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey)
            )
        ]

        XCTAssertTrue(shortcuts.allSatisfy(\.isValid))
        XCTAssertEqual(shortcuts[0].displayString, "⌘A")
        XCTAssertEqual(shortcuts[1].displayString, "⌥⇧F12")
        XCTAssertEqual(shortcuts[2].displayString, "⌃空格")
    }

    func testHotkeyRejectsMissingRequiredModifierUnknownKeyAndUnsupportedFlags() {
        let shortcuts = [
            ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: 0
            ),
            ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(shiftKey)
            ),
            ScreenshotHotKey(
                keyCode: UInt32.max,
                modifiers: UInt32(cmdKey)
            ),
            ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: UInt32(cmdKey) | UInt32(1 << 31)
            )
        ]

        XCTAssertTrue(shortcuts.allSatisfy { !$0.isValid })
    }

    func testHotkeyConfigurationRejectsInvalidShortcut() {
        let invalidShortcut = ScreenshotHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(shiftKey)
        )
        let configuration = ScreenshotHotKeyConfiguration(
            region: invalidShortcut,
            scrolling: nil,
            ocr: nil
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? ScreenshotHotKeyConfigurationError,
                .invalidShortcut(.region)
            )
        }
        XCTAssertFalse(configuration.isValid)
    }

    func testHotkeyConfigurationRejectsApplicationDuplicate() {
        let duplicate = ScreenshotHotKey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | optionKey)
        )
        let configuration = ScreenshotHotKeyConfiguration(
            region: duplicate,
            scrolling: duplicate,
            ocr: nil
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? ScreenshotHotKeyConfigurationError,
                .duplicateShortcut(.region, .scrolling)
            )
        }
        XCTAssertFalse(configuration.isValid)
    }

    func testHotkeyConfigurationRejectsPEEKMenuShortcut() {
        let configuration = ScreenshotHotKeyConfiguration(
            region: ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_Q),
                modifiers: UInt32(cmdKey)
            ),
            scrolling: nil,
            ocr: nil
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(
                error as? ScreenshotHotKeyConfigurationError,
                .applicationReservedShortcut(.region)
            )
        }
    }

    @MainActor
    func testSystemHotkeyDetectorOnlyReturnsEnabledEntries() {
        let enabledShortcut: NSDictionary = [
            kHISymbolicHotKeyEnabled as String: true,
            kHISymbolicHotKeyCode as String: NSNumber(value: kVK_ANSI_3),
            kHISymbolicHotKeyModifiers as String: NSNumber(value: cmdKey | shiftKey)
        ]
        let disabledShortcut: NSDictionary = [
            kHISymbolicHotKeyEnabled as String: false,
            kHISymbolicHotKeyCode as String: NSNumber(value: kVK_ANSI_4),
            kHISymbolicHotKeyModifiers as String: NSNumber(value: cmdKey | shiftKey)
        ]

        let shortcuts = ScreenshotSystemHotKeyConflictDetector.enabledShortcuts(
            from: [enabledShortcut, disabledShortcut] as NSArray
        )

        XCTAssertEqual(shortcuts, [ScreenshotHotKey(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: UInt32(cmdKey | shiftKey)
        )])
    }

    func testNilShortcutDisablesActionAndSurvivesCodingRoundTrip() throws {
        var configuration = ScreenshotHotKeyConfiguration.defaults
        configuration[.scrolling] = nil

        XCTAssertNoThrow(try configuration.validate())
        XCTAssertNil(configuration[.scrolling])

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            ScreenshotHotKeyConfiguration.self,
            from: encoded
        )
        XCTAssertEqual(decoded, configuration)
        XCTAssertNil(decoded.scrolling)
    }

    @MainActor
    func testHotkeyConfigurationReloadsFromIsolatedUserDefaultsSuite() throws {
        let (userDefaults, suiteName) = try makeIsolatedUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let configuration = ScreenshotHotKeyConfiguration(
            region: ScreenshotHotKey(
                keyCode: UInt32(kVK_ANSI_R),
                modifiers: UInt32(controlKey | shiftKey)
            ),
            scrolling: nil,
            ocr: ScreenshotHotKey(
                keyCode: UInt32(kVK_F10),
                modifiers: UInt32(cmdKey | optionKey)
            )
        )
        userDefaults.set(
            try JSONEncoder().encode(configuration),
            forKey: ScreenshotGlobalHotKeyManager.storageKey
        )

        let reloadedManager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)

        XCTAssertEqual(reloadedManager.configuration, configuration)
        XCTAssertEqual(reloadedManager.shortcut(for: .region), configuration.region)
        XCTAssertNil(reloadedManager.shortcut(for: .scrolling))
        XCTAssertEqual(reloadedManager.shortcut(for: .ocr), configuration.ocr)
    }

    @MainActor
    func testDisablingHotkeyPersistsNilAndReloadsFromIsolatedSuite() throws {
        let (userDefaults, suiteName) = try makeIsolatedUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)

        manager.disable(.scrolling)

        let persistedData = try XCTUnwrap(
            userDefaults.data(forKey: ScreenshotGlobalHotKeyManager.storageKey)
        )
        let persistedConfiguration = try JSONDecoder().decode(
            ScreenshotHotKeyConfiguration.self,
            from: persistedData
        )
        let reloadedManager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)
        XCTAssertNil(persistedConfiguration.scrolling)
        XCTAssertNil(reloadedManager.shortcut(for: .scrolling))
        XCTAssertEqual(
            reloadedManager.shortcut(for: .region),
            ScreenshotGlobalHotKeyAction.region.defaultShortcut
        )
        XCTAssertEqual(
            reloadedManager.shortcut(for: .ocr),
            ScreenshotGlobalHotKeyAction.ocr.defaultShortcut
        )
    }

    @MainActor
    func testDamagedOrInvalidPersistedHotkeysFallBackToDefaults() throws {
        let (userDefaults, suiteName) = try makeIsolatedUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(
            Data("not valid hotkey json".utf8),
            forKey: ScreenshotGlobalHotKeyManager.storageKey
        )
        let damagedDataManager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)
        XCTAssertEqual(damagedDataManager.configuration, .defaults)

        let duplicate = ScreenshotGlobalHotKeyAction.region.defaultShortcut
        let invalidConfiguration = ScreenshotHotKeyConfiguration(
            region: duplicate,
            scrolling: duplicate,
            ocr: nil
        )
        userDefaults.set(
            try JSONEncoder().encode(invalidConfiguration),
            forKey: ScreenshotGlobalHotKeyManager.storageKey
        )
        let invalidDataManager = ScreenshotGlobalHotKeyManager(userDefaults: userDefaults)
        XCTAssertEqual(invalidDataManager.configuration, .defaults)
    }

    func testHotkeyRegistrationFailureIncludesOSStatus() {
        XCTAssertEqual(
            ScreenshotHotKeyRegistrationState.failure(-9876).localizedDescription,
            "快捷键注册失败（OSStatus -9876）"
        )
    }

    func testKnownCarbonRegistrationFailuresHaveReadableDescriptions() {
        let existsStatus = OSStatus(eventHotKeyExistsErr)
        let invalidStatus = OSStatus(eventHotKeyInvalidErr)

        XCTAssertEqual(
            ScreenshotHotKeyRegistrationState.failure(existsStatus).localizedDescription,
            "快捷键已被系统或其他应用占用"
        )
        XCTAssertEqual(
            ScreenshotHotKeyRegistrationState.failure(invalidStatus).localizedDescription,
            "快捷键无效，无法注册"
        )
        XCTAssertEqual(
            ScreenshotGlobalHotKeyManagerError.registrationFailed(
                .region,
                existsStatus
            ).errorDescription,
            "“区域截图”快捷键已被系统或其他应用占用"
        )
        XCTAssertEqual(
            ScreenshotGlobalHotKeyManagerError.registrationFailed(
                .scrolling,
                invalidStatus
            ).errorDescription,
            "“滚动截图”快捷键无效，无法注册"
        )
        XCTAssertEqual(
            ScreenshotHotKeyRegistrationState.systemConflict.localizedDescription,
            "快捷键与 macOS 系统快捷键冲突"
        )
        XCTAssertEqual(
            ScreenshotGlobalHotKeyManagerError.systemShortcutConflict(.ocr).errorDescription,
            "“截图 OCR”快捷键与已启用的 macOS 系统快捷键冲突"
        )
    }

    func testFrontmostWindowCandidateFiltersOwnerAndPreservesWindowOrder() {
        let backWindow = ScreenshotWindowCandidate(
            windowID: 301,
            ownerPID: 30,
            frame: CGRect(x: 40, y: 40, width: 400, height: 300),
            ownerName: "Back",
            title: "Back window"
        )
        let frontTargetWindow = ScreenshotWindowCandidate(
            windowID: 201,
            ownerPID: 20,
            frame: CGRect(x: 20, y: 20, width: 500, height: 400),
            ownerName: "Target",
            title: "Front target window"
        )
        let backTargetWindow = ScreenshotWindowCandidate(
            windowID: 202,
            ownerPID: 20,
            frame: CGRect(x: 80, y: 80, width: 300, height: 200),
            ownerName: "Target",
            title: "Back target window"
        )

        let result = frontmostScreenshotWindowCandidate(
            ownerPID: 20,
            in: [backWindow, frontTargetWindow, backTargetWindow]
        )

        XCTAssertEqual(result, frontTargetWindow)
        XCTAssertNil(frontmostScreenshotWindowCandidate(
            ownerPID: 99,
            in: [backWindow, frontTargetWindow, backTargetWindow]
        ))
    }

    func testInitialSelectionAcceptsStandardizedRectOnOneScreen() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 800, height: 600)
        ]
        let rawRect = CGRect(x: 450, y: 350, width: -300, height: -200)

        let result = validatedInitialScreenshotSelection(
            rawRect,
            desktopBounds: screens[0].union(screens[1]),
            screenFrames: screens
        )

        XCTAssertEqual(result, CGRect(x: 150, y: 150, width: 300, height: 200))
    }

    func testInitialSelectionRejectsInvalidAndCrossScreenRects() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_000, y: 0, width: 800, height: 600)
        ]
        let desktopBounds = screens[0].union(screens[1])

        XCTAssertNil(validatedInitialScreenshotSelection(
            CGRect(x: 20, y: 20, width: 7, height: 100),
            desktopBounds: desktopBounds,
            screenFrames: screens
        ))
        XCTAssertNil(validatedInitialScreenshotSelection(
            CGRect(x: CGFloat.infinity, y: 20, width: 100, height: 100),
            desktopBounds: desktopBounds,
            screenFrames: screens
        ))
        XCTAssertNil(validatedInitialScreenshotSelection(
            CGRect(x: -10, y: 20, width: 100, height: 100),
            desktopBounds: desktopBounds,
            screenFrames: screens
        ))
        XCTAssertNil(validatedInitialScreenshotSelection(
            CGRect(x: 900, y: 100, width: 200, height: 300),
            desktopBounds: desktopBounds,
            screenFrames: screens
        ))
        XCTAssertNil(validatedInitialScreenshotSelection(
            nil,
            desktopBounds: desktopBounds,
            screenFrames: screens
        ))
    }

    func testAutomaticHoverSelectionUsesSmallestNestedRegion() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let outerRegion = CGRect(x: 140, y: 130, width: 700, height: 520)
        let innerRegion = CGRect(x: 220, y: 180, width: 320, height: 260)

        let result = automaticHoverScreenshotSelection(
            at: CGPoint(x: 300, y: 260),
            windowRect: window,
            regionRects: [outerRegion, innerRegion]
        )

        XCTAssertEqual(result, innerRegion)
    }

    func testAutomaticHoverSelectionUsesWindowOutsideAllRegions() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)

        let result = automaticHoverScreenshotSelection(
            at: CGPoint(x: 120, y: 120),
            windowRect: window,
            regionRects: [
                CGRect(x: 180, y: 160, width: 620, height: 480),
                CGRect(x: 240, y: 210, width: 300, height: 220)
            ]
        )

        XCTAssertEqual(result, window)
    }

    func testAutomaticHoverSelectionReturnsNilOutsideWindow() {
        let result = automaticHoverScreenshotSelection(
            at: CGPoint(x: 50, y: 50),
            windowRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            // Even a malformed frozen region outside the anchored window
            // must not override the window boundary.
            regionRects: [CGRect(x: 20, y: 20, width: 80, height: 80)]
        )

        XCTAssertNil(result)
    }

    func testAutomaticHoverSelectionMovesFromAXRegionToWholeWindowWithinSameAppWindow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let region = CGRect(x: 180, y: 160, width: 620, height: 480)

        XCTAssertEqual(
            automaticHoverScreenshotSelection(
                at: CGPoint(x: 300, y: 260),
                windowRect: window,
                regionRects: [region]
            ),
            region
        )
        XCTAssertEqual(
            automaticHoverScreenshotSelection(
                at: CGPoint(x: 120, y: 120),
                windowRect: window,
                regionRects: [region]
            ),
            window
        )
    }

    func testInlineToolbarAnchorsBelowSelectionAndStaysOnScreen() {
        let frame = screenshotInlineToolbarFrame(
            selectionRect: CGRect(x: 500, y: 300, width: 400, height: 260),
            toolbarSize: CGSize(width: 720, height: 52),
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        XCTAssertEqual(frame, CGRect(x: 180, y: 240, width: 720, height: 52))
    }

    func testInlineToolbarMovesAboveSelectionWhenBottomSpaceIsInsufficient() {
        let frame = screenshotInlineToolbarFrame(
            selectionRect: CGRect(x: 40, y: 12, width: 320, height: 180),
            toolbarSize: CGSize(width: 500, height: 52),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )

        XCTAssertEqual(frame, CGRect(x: 8, y: 200, width: 500, height: 52))
    }

    func testInlineToolbarWidthIsClampedForSmallDisplays() {
        let frame = screenshotInlineToolbarFrame(
            selectionRect: CGRect(x: -1_100, y: 100, width: 500, height: 300),
            toolbarSize: CGSize(width: 900, height: 60),
            screenFrame: CGRect(x: -1_280, y: 0, width: 640, height: 480)
        )

        XCTAssertEqual(frame.minX, -1_272)
        XCTAssertEqual(frame.width, 624)
        XCTAssertGreaterThanOrEqual(frame.minY, 8)
        XCTAssertLessThanOrEqual(frame.maxY, 472)
    }

    func testQRCodeHintCentersBelowButtonAndClampsInsideToolbar() {
        XCTAssertEqual(
            screenshotQRCodeHintLeadingOffset(
                buttonMidX: 320,
                hintWidth: 224,
                toolbarWidth: 640
            ),
            208
        )
        XCTAssertEqual(
            screenshotQRCodeHintLeadingOffset(
                buttonMidX: 24,
                hintWidth: 224,
                toolbarWidth: 640
            ),
            0
        )
        XCTAssertEqual(
            screenshotQRCodeHintLeadingOffset(
                buttonMidX: 626,
                hintWidth: 224,
                toolbarWidth: 640
            ),
            416
        )
    }

    @MainActor
    func testPaletteButtonsDoNotTakeKeyboardFocusOrDrawFocusRing() {
        let button = NSButton()

        configureScreenshotPaletteButtonFocus(button)

        XCTAssertTrue(button.refusesFirstResponder)
        XCTAssertEqual(button.focusRingType, .none)
    }

    func testCustomColorPanelIsPlacedAboveScreenshotToolbar() {
        let toolbarLevel = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 2
        )

        XCTAssertGreaterThan(
            screenshotFloatingColorPanelLevel(toolbarLevel: toolbarLevel).rawValue,
            toolbarLevel.rawValue
        )
    }

    @MainActor
    func testScreenshotClipboardWriterBuildsEagerPNGAndTIFFPayloads() throws {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 24,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<24 {
            for x in 0..<32 {
                representation.setColor(
                    NSColor(deviceRed: 0.1, green: 0.45, blue: 0.95, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }
        let image = NSImage(size: CGSize(width: 32, height: 24))
        image.addRepresentation(representation)
        let payloads = screenshotPasteboardPayloads(for: image)

        XCTAssertEqual(Set(payloads.map(\.type)), Set([.png, .tiff]))
        XCTAssertTrue(payloads.allSatisfy { !$0.data.isEmpty })
        XCTAssertNotNil(payloads.first(where: { $0.type == .png }).flatMap {
            NSBitmapImageRep(data: $0.data)
        })
    }

    @MainActor
    func testShapeFillControlChangesRenderedRectangleInterior() throws {
        let base = NSImage(size: CGSize(width: 40, height: 40))
        base.lockFocus()
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 40, height: 40).fill()
        base.unlockFocus()

        var filledStyle = ScreenshotAnnotationStyle(
            color: .systemRed,
            lineWidth: 2,
            fontSize: 18,
            shapeFill: .filled
        )
        let filledImage = try XCTUnwrap(ScreenshotAnnotationRenderer.render(
            baseImage: base,
            annotations: [.rectangle(CGRect(x: 6, y: 6, width: 28, height: 28), filledStyle)]
        ))

        filledStyle.shapeFill = .outline
        let outlineImage = try XCTUnwrap(ScreenshotAnnotationRenderer.render(
            baseImage: base,
            annotations: [.rectangle(CGRect(x: 6, y: 6, width: 28, height: 28), filledStyle)]
        ))

        let filledBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(
            filledImage.tiffRepresentation
        )))
        let outlineBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(
            outlineImage.tiffRepresentation
        )))
        let filledCenter = try XCTUnwrap(filledBitmap.colorAt(x: 20, y: 20))
        let outlineCenter = try XCTUnwrap(outlineBitmap.colorAt(x: 20, y: 20))

        XCTAssertLessThan(filledCenter.greenComponent, 0.95)
        XCTAssertGreaterThan(outlineCenter.greenComponent, 0.99)
    }

    func testVerifiedAXRegionUsesAppKitCaptureRectAndQuartzScrollPoint() throws {
        let window = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            title: "Browser"
        )
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: window.quartzFrame,
            focusedWindowTitle: "AX Browser",
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 130, y: 160, width: 700, height: 480),
                    role: .webArea,
                    depth: 2
                ),
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 150, y: 180, width: 300, height: 300),
                    role: .scrollArea,
                    depth: 3
                ),
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 110, y: 120, width: 760, height: 540),
                    role: .scrollArea,
                    depth: 8
                ),
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 120, y: 140, width: 740, height: 500),
                    role: .scrollArea,
                    depth: 1,
                    isVisible: false
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_200, height: 900)],
            maximumAccessibilityDepth: 6,
            accessibilitySnapshot: accessibility,
            windowSnapshots: [window]
        ))

        XCTAssertEqual(result.ownerPID, 42)
        XCTAssertEqual(result.windowID, 420)
        XCTAssertEqual(result.source, .accessibilityWebArea)
        XCTAssertTrue(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.windowFrame, CGRect(x: 100, y: 200, width: 800, height: 600))
        XCTAssertEqual(result.captureRect, CGRect(x: 130, y: 260, width: 700, height: 480))
        // The capture rectangle is AppKit lower-left coordinates, while the
        // event target remains the AX/Quartz upper-left coordinate center.
        XCTAssertEqual(result.scrollPoint, CGPoint(x: 480, y: 400))
        XCTAssertEqual(result.title, "AX Browser")
        XCTAssertFalse(result.wasClippedToSingleScreen)
    }

    func testHoveredAXScrollRegionOverridesLargerHeuristicRegion() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 800, height: 600)
        let hoveredRegion = ScrollCaptureAccessibilityRegion(
            quartzFrame: CGRect(x: 160, y: 180, width: 300, height: 260),
            role: .scrollArea,
            depth: 4
        )
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 120, y: 140, width: 740, height: 500),
                    role: .webArea,
                    depth: 2
                ),
                hoveredRegion
            ],
            hoveredScrollRegion: hoveredRegion,
            didHitTestFocusedWindow: true
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_200, height: 900)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityScrollArea)
        XCTAssertTrue(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 160, y: 460, width: 300, height: 260))
        XCTAssertEqual(result.hoverSelectionRects, [result.captureRect])
        XCTAssertEqual(result.scrollPoint, CGPoint(x: 310, y: 310))
    }

    func testSuccessfulWindowHitWithoutHoveredScrollRegionFallsBackToWholeWindow() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 800, height: 600)
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 140, y: 160, width: 680, height: 480),
                    role: .webArea,
                    depth: 2
                )
            ],
            hoveredScrollRegion: nil,
            didHitTestFocusedWindow: true
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_200, height: 900)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityFocusedWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 100, y: 200, width: 800, height: 600))
        XCTAssertTrue(result.hoverSelectionRects.isEmpty)
    }

    func testHoveredNearWholeWindowWebAreaRemainsAutomaticPreselection() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 700, height: 500)
        let hoveredWebArea = ScrollCaptureAccessibilityRegion(
            quartzFrame: focusedWindow.insetBy(dx: 2, dy: 2),
            role: .webArea,
            depth: 4
        )
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            scrollRegions: [hoveredWebArea],
            hoveredScrollRegion: hoveredWebArea,
            didHitTestFocusedWindow: true
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityWebArea)
        XCTAssertTrue(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 102, y: 202, width: 696, height: 496))
        XCTAssertEqual(result.scrollPoint, CGPoint(x: 450, y: 350))
    }

    func testPointerSelectsPointedWindowForSameAppAndCurrentAppFrontmostFallback() throws {
        let sameAppResult = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: nil,
            pointerQuartzPoint: CGPoint(x: 700, y: 300),
            windowSnapshots: [
                ScrollCaptureWindowSnapshot(
                    ownerPID: 42,
                    windowID: 421,
                    quartzFrame: CGRect(x: 100, y: 100, width: 400, height: 500)
                ),
                ScrollCaptureWindowSnapshot(
                    ownerPID: 42,
                    windowID: 422,
                    quartzFrame: CGRect(x: 600, y: 150, width: 300, height: 400)
                )
            ]
        ))

        XCTAssertEqual(sameAppResult.ownerPID, 42)
        XCTAssertEqual(sameAppResult.windowID, 422)
        XCTAssertEqual(sameAppResult.source, .quartzWindow)

        let currentAppFrontmostResult = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 7,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: nil,
            pointerQuartzPoint: CGPoint(x: 400, y: 300),
            windowSnapshots: [
                ScrollCaptureWindowSnapshot(
                    ownerPID: 7,
                    windowID: 70,
                    quartzFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                ),
                ScrollCaptureWindowSnapshot(
                    ownerPID: 99,
                    windowID: 990,
                    quartzFrame: CGRect(x: 300, y: 200, width: 400, height: 300)
                ),
                ScrollCaptureWindowSnapshot(
                    ownerPID: 88,
                    windowID: 880,
                    quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        ))

        XCTAssertEqual(currentAppFrontmostResult.ownerPID, 99)
        XCTAssertEqual(currentAppFrontmostResult.windowID, 990)
        XCTAssertEqual(currentAppFrontmostResult.source, .quartzWindow)
    }

    @MainActor
    func testLiveResolverTimesOutBlockedAXProviderAndReturnsQuartzWindowWithoutWaiting() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let windowQuartzFrame = CGRect(x: 80, y: 80, width: 640, height: 480)
        let window = ScrollCaptureWindowSnapshot(
            ownerPID: 42_424,
            windowID: 424,
            quartzFrame: windowQuartzFrame,
            title: "Quartz fallback"
        )
        let lateAXSnapshot = ScrollCaptureAccessibilitySnapshot(
            ownerPID: window.ownerPID,
            focusedWindowQuartzFrame: window.quartzFrame,
            focusedWindowTitle: "Late AX result",
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: window.quartzFrame.insetBy(dx: 20, dy: 20),
                    role: .webArea,
                    depth: 2
                )
            ]
        )
        let resolver = ScrollCaptureTargetResolver(
            accessibilityTimeoutNanoseconds: 20_000_000,
            accessibilitySnapshotProvider: { _, _, _ in
                Thread.sleep(forTimeInterval: 0.6)
                return lateAXSnapshot
            },
            windowSnapshotProvider: { [window] in [window] }
        )

        let startedAt = Date()
        let resolvedTarget = await resolver.resolve(
            frontmostPID: window.ownerPID,
            currentPID: 7,
            screenFrames: [screenFrame]
        )
        let result = try XCTUnwrap(resolvedTarget)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            0.3,
            "Resolver must return on its timeout instead of awaiting the blocked AX provider"
        )
        XCTAssertEqual(result.ownerPID, window.ownerPID)
        XCTAssertEqual(result.windowID, window.windowID)
        XCTAssertEqual(result.source, .quartzWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.title, window.title)
        XCTAssertEqual(result.captureRect, result.windowFrame)
        XCTAssertTrue(result.hoverSelectionRects.isEmpty)
    }

    func testScrollTargetPrefersDeeperAccessibilityCandidateWhenFramesMatch() throws {
        let sharedRegion = CGRect(x: 150, y: 180, width: 600, height: 420)
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: sharedRegion,
                    role: .webArea,
                    depth: 1
                ),
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: sharedRegion,
                    role: .scrollArea,
                    depth: 4
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityScrollArea)
        XCTAssertTrue(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 150, y: 200, width: 600, height: 420))
        XCTAssertEqual(result.scrollPoint, CGPoint(x: 450, y: 390))
    }

    func testWholeWindowAccessibilityRegionIsOnlyFocusedWindowFallback() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 700, height: 500)
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: focusedWindow,
                    role: .scrollArea,
                    depth: 1
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityFocusedWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 100, y: 200, width: 700, height: 500))
    }

    func testDeepNearWholeWindowWebAreaIsNotVerified() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 700, height: 500)
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: focusedWindow.insetBy(dx: 2, dy: 2),
                    role: .webArea,
                    depth: 4
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityFocusedWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.captureRect, CGRect(x: 100, y: 200, width: 700, height: 500))
    }

    func testNearWholeWindowFallbackRetainsStableWindowAnchor() throws {
        let focusedWindow = CGRect(x: 100, y: 100, width: 700, height: 500)
        let window = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: focusedWindow,
            title: "Browser"
        )
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: focusedWindow,
            focusedWindowTitle: "AX Browser",
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: focusedWindow.insetBy(dx: 2, dy: 2),
                    role: .webArea,
                    depth: 4
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: accessibility,
            windowSnapshots: [window]
        ))

        XCTAssertEqual(result.ownerPID, 42)
        XCTAssertEqual(result.windowID, 420)
        XCTAssertEqual(result.windowFrame, CGRect(x: 100, y: 200, width: 700, height: 500))
        XCTAssertEqual(result.source, .accessibilityFocusedWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
    }

    func testManualSelectionPointResolvesTopmostExternalWindowAnchor() throws {
        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolveWindow(
            containingAppKitPoint: CGPoint(x: 400, y: 350),
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            windowSnapshots: [
                ScrollCaptureWindowSnapshot(
                    ownerPID: 7,
                    windowID: 70,
                    quartzFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
                ),
                ScrollCaptureWindowSnapshot(
                    ownerPID: 42,
                    windowID: 421,
                    quartzFrame: CGRect(x: 250, y: 200, width: 500, height: 400),
                    title: "Front"
                ),
                ScrollCaptureWindowSnapshot(
                    ownerPID: 42,
                    windowID: 422,
                    quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
                    title: "Back"
                )
            ]
        ))

        XCTAssertEqual(result.ownerPID, 42)
        XCTAssertEqual(result.windowID, 421)
        XCTAssertEqual(result.windowFrame, CGRect(x: 250, y: 200, width: 500, height: 400))
        XCTAssertEqual(result.source, .quartzWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
    }

    func testWindowAnchorSelectionCoverageAccepts100And98PercentButRejects9799Percent() {
        let anchor = ScrollCaptureWindowAnchor(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 0, y: 0, width: 10_000, height: 1_000)
        )
        let liveWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: anchor.quartzFrame
        )
        let cases: [(outsideWidth: CGFloat, shouldPass: Bool)] = [
            (0, true),
            (200, true),
            (201, false)
        ]

        for testCase in cases {
            let selection = CGRect(
                x: -testCase.outsideWidth,
                y: 0,
                width: 10_000,
                height: 1_000
            )
            let operation = {
                try ScrollCaptureWindowAnchorValidator.validate(
                    anchor: anchor,
                    selectionQuartzRect: selection,
                    scrollPoint: CGPoint(x: 5_000, y: 500),
                    currentPID: 7,
                    frontmostPID: 42,
                    windowSnapshots: [liveWindow]
                )
            }

            if testCase.shouldPass {
                XCTAssertNoThrow(try operation(), "outside width: \(testCase.outsideWidth)")
            } else {
                XCTAssertThrowsError(try operation()) { error in
                    XCTAssertEqual(error as? ScrollCaptureError, .scrollTargetChanged)
                }
            }
        }
    }

    func testWindowAnchorRejectsPIDAndWindowIDChanges() {
        let anchor = ScrollCaptureWindowAnchor(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let changedWindows = [
            ScrollCaptureWindowSnapshot(
                ownerPID: 43,
                windowID: 420,
                quartzFrame: anchor.quartzFrame
            ),
            ScrollCaptureWindowSnapshot(
                ownerPID: 42,
                windowID: 421,
                quartzFrame: anchor.quartzFrame
            )
        ]

        for liveWindow in changedWindows {
            assertWindowAnchorValidationFails(
                anchor: anchor,
                windowSnapshots: [liveWindow]
            )
        }
    }

    func testWindowAnchorFrameToleranceAcceptsTwoPointsAndRejectsLargerChange() {
        let anchor = ScrollCaptureWindowAnchor(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let withinTolerance = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 102, y: 98, width: 802, height: 598)
        )

        XCTAssertNoThrow(try ScrollCaptureWindowAnchorValidator.validate(
            anchor: anchor,
            selectionQuartzRect: CGRect(x: 150, y: 150, width: 700, height: 500),
            scrollPoint: CGPoint(x: 500, y: 400),
            currentPID: 7,
            frontmostPID: 42,
            windowSnapshots: [withinTolerance]
        ))

        let beyondTolerance = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 102.01, y: 100, width: 800, height: 600)
        )
        assertWindowAnchorValidationFails(
            anchor: anchor,
            windowSnapshots: [beyondTolerance]
        )
    }

    func testWindowAnchorRejectsWhenAnotherWindowCoversScrollPoint() {
        let anchor = ScrollCaptureWindowAnchor(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let coveringWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 99,
            windowID: 990,
            quartzFrame: CGRect(x: 450, y: 350, width: 300, height: 250)
        )
        let targetWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: anchor.quartzFrame
        )

        assertWindowAnchorValidationFails(
            anchor: anchor,
            windowSnapshots: [coveringWindow, targetWindow]
        )
    }

    func testWindowAnchorRejectsWhenTargetApplicationIsNoLongerFrontmost() {
        let anchor = ScrollCaptureWindowAnchor(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let targetWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 420,
            quartzFrame: anchor.quartzFrame
        )

        assertWindowAnchorValidationFails(
            anchor: anchor,
            frontmostPID: 99,
            windowSnapshots: [targetWindow]
        )
    }

    func testScrollTargetFallsBackFromUnusableAccessibilityToFrontmostQuartzWindow() throws {
        let frontTargetWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 421,
            quartzFrame: CGRect(x: 120, y: 100, width: 700, height: 500),
            title: "Front target"
        )
        let backTargetWindow = ScrollCaptureWindowSnapshot(
            ownerPID: 42,
            windowID: 422,
            quartzFrame: CGRect(x: 160, y: 140, width: 500, height: 400),
            title: "Back target"
        )
        let wrongProcessAccessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 99,
            focusedWindowQuartzFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            scrollRegions: []
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            accessibilitySnapshot: wrongProcessAccessibility,
            windowSnapshots: [
                ScrollCaptureWindowSnapshot(
                    ownerPID: 88,
                    windowID: 880,
                    quartzFrame: CGRect(x: 20, y: 20, width: 900, height: 700)
                ),
                frontTargetWindow,
                backTargetWindow
            ]
        ))

        XCTAssertEqual(result.ownerPID, 42)
        XCTAssertEqual(result.windowID, 421)
        XCTAssertEqual(result.source, .quartzWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.title, "Front target")
    }

    func testScrollTargetUsesFocusedWindowWhenAccessibilityHasNoValidRegion() throws {
        let accessibility = ScrollCaptureAccessibilitySnapshot(
            ownerPID: 42,
            focusedWindowQuartzFrame: CGRect(x: 100, y: 100, width: 700, height: 500),
            focusedWindowTitle: "Focused",
            scrollRegions: [
                ScrollCaptureAccessibilityRegion(
                    quartzFrame: CGRect(x: 120, y: 120, width: 500, height: 350),
                    role: .scrollArea,
                    depth: 9
                )
            ]
        )

        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
            maximumAccessibilityDepth: 6,
            accessibilitySnapshot: accessibility,
            windowSnapshots: []
        ))

        XCTAssertEqual(result.source, .accessibilityFocusedWindow)
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertEqual(result.windowID, 0)
        XCTAssertEqual(result.captureRect, CGRect(x: 100, y: 200, width: 700, height: 500))
    }

    func testScrollTargetFallbackFiltersCurrentAndIneligibleWindowsInServerOrder() throws {
        let currentPID: pid_t = 7
        let snapshots = [
            ScrollCaptureWindowSnapshot(
                ownerPID: currentPID,
                windowID: 70,
                quartzFrame: CGRect(x: 10, y: 10, width: 800, height: 600)
            ),
            ScrollCaptureWindowSnapshot(
                ownerPID: 20,
                windowID: 200,
                quartzFrame: CGRect(x: 20, y: 20, width: 760, height: 560),
                layer: 1
            ),
            ScrollCaptureWindowSnapshot(
                ownerPID: 30,
                windowID: 300,
                quartzFrame: CGRect(x: 30, y: 30, width: 720, height: 520),
                title: "First eligible"
            ),
            ScrollCaptureWindowSnapshot(
                ownerPID: 40,
                windowID: 400,
                quartzFrame: CGRect(x: 40, y: 40, width: 680, height: 480),
                title: "Second eligible"
            )
        ]

        for frontmostPID in [nil, currentPID] as [pid_t?] {
            let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
                frontmostPID: frontmostPID,
                currentPID: currentPID,
                screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 800)],
                accessibilitySnapshot: nil,
                windowSnapshots: snapshots
            ))
            XCTAssertEqual(result.ownerPID, 30)
            XCTAssertEqual(result.windowID, 300)
            XCTAssertEqual(result.source, .quartzWindow)
            XCTAssertFalse(result.isVerifiedScrollRegion)
            XCTAssertEqual(result.title, "First eligible")
        }
    }

    func testScrollTargetClipsCrossScreenWindowToLargestSingleScreen() throws {
        let result = try XCTUnwrap(ScrollCaptureTargetResolver.resolve(
            frontmostPID: 42,
            currentPID: 7,
            screenFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 800),
                CGRect(x: 1_000, y: 0, width: 800, height: 600)
            ],
            accessibilitySnapshot: nil,
            windowSnapshots: [
                ScrollCaptureWindowSnapshot(
                    ownerPID: 42,
                    windowID: 420,
                    quartzFrame: CGRect(x: 850, y: 100, width: 600, height: 500)
                )
            ]
        ))

        XCTAssertEqual(result.captureRect, CGRect(x: 1_000, y: 200, width: 450, height: 400))
        XCTAssertEqual(result.scrollPoint, CGPoint(x: 1_225, y: 400))
        XCTAssertFalse(result.isVerifiedScrollRegion)
        XCTAssertTrue(result.wasClippedToSingleScreen)
    }

    func testScrollCaptureConfigurationPreservesExplicitScrollPoint() throws {
        let explicitPoint = CGPoint(x: 777.25, y: 888.75)
        var configuration = ScrollCaptureConfiguration(
            captureRect: CGRect(x: 10.2, y: 20.2, width: 99.4, height: 79.6)
        )
        configuration.scrollPoint = explicitPoint

        let validated = try configuration.validated()

        XCTAssertEqual(validated.captureRect, configuration.captureRect.integral)
        XCTAssertEqual(validated.scrollPoint, explicitPoint)
    }

    func testScrollCaptureConfigurationRejectsNonFiniteScrollPoint() {
        let invalidPoints = [
            CGPoint(x: CGFloat.infinity, y: 10),
            CGPoint(x: 10, y: -CGFloat.infinity),
            CGPoint(x: CGFloat.nan, y: 10),
            CGPoint(x: 10, y: CGFloat.nan)
        ]

        for point in invalidPoints {
            var configuration = ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 200, height: 120)
            )
            configuration.scrollPoint = point

            XCTAssertThrowsError(try configuration.validated()) { error in
                XCTAssertEqual(
                    error as? ScrollCaptureError,
                    .invalidConfiguration("滚动目标坐标无效")
                )
            }
        }
    }

    func testScrollCaptureModeResolverUsesValidatedWindowAnchorWithoutAXSemanticRegion() throws {
        let mode = try ScrollCaptureModeResolver.resolve(
            automaticRequested: true,
            accessibilityGranted: true,
            hasValidatedWindowAnchor: true,
            configuredAmount: 700,
            captureHeight: 600
        )

        guard case .automatic(let configuration) = mode else {
            return XCTFail("A validated window anchor must enable automatic scrolling")
        }
        XCTAssertEqual(configuration.amount, 210)
        XCTAssertEqual(configuration.consecutiveDuplicateLimit, 2)
    }

    func testScrollCaptureModeResolverDoesNotApplyHiddenMinimumForSmallSelections() throws {
        let mode = try ScrollCaptureModeResolver.resolve(
            automaticRequested: true,
            accessibilityGranted: true,
            hasValidatedWindowAnchor: true,
            configuredAmount: 700,
            captureHeight: 120
        )

        guard case .automatic(let configuration) = mode else {
            return XCTFail("A validated window anchor must enable automatic scrolling")
        }
        XCTAssertEqual(configuration.amount, 42)
    }

    func testScrollCaptureModeResolverPreservesConfiguredAmountAsCeiling() throws {
        let mode = try ScrollCaptureModeResolver.resolve(
            automaticRequested: true,
            accessibilityGranted: true,
            hasValidatedWindowAnchor: true,
            configuredAmount: 120,
            captureHeight: 600
        )

        guard case .automatic(let configuration) = mode else {
            return XCTFail("A validated window anchor must enable automatic scrolling")
        }
        XCTAssertEqual(configuration.amount, 120)
    }

    func testScrollCaptureModeResolverRejectsMissingPermissionAndWindowAnchor() {
        XCTAssertThrowsError(try ScrollCaptureModeResolver.resolve(
            automaticRequested: true,
            accessibilityGranted: false,
            hasValidatedWindowAnchor: true,
            configuredAmount: 700,
            captureHeight: 600
        )) { error in
            XCTAssertEqual(error as? ScrollCaptureError, .accessibilityPermissionDenied)
        }

        XCTAssertThrowsError(try ScrollCaptureModeResolver.resolve(
            automaticRequested: true,
            accessibilityGranted: true,
            hasValidatedWindowAnchor: false,
            configuredAmount: 700,
            captureHeight: 600
        )) { error in
            XCTAssertEqual(
                error as? ScrollCaptureError,
                .invalidConfiguration(
                    "无法确认选区所属窗口，请将选区完整放在一个窗口内后重试"
                )
            )
        }
    }

    func testScrollCaptureModeResolverReturnsManualWhenAutomaticIsDisabled() throws {
        let mode = try ScrollCaptureModeResolver.resolve(
            automaticRequested: false,
            accessibilityGranted: false,
            hasValidatedWindowAnchor: false,
            configuredAmount: 0,
            captureHeight: 0
        )

        guard case .manual = mode else {
            return XCTFail("Disabling automatic scrolling must select manual mode")
        }
    }

    func testScrollCaptureSessionCancelledBeforeStartDoesNotCaptureFrame() async {
        let capturer = CountingScrollFrameCapturer()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 200, height: 120)
            ),
            capturer: capturer,
            scrollDriver: NoOpAutomaticScrollDriver()
        )

        await session.cancel()

        do {
            _ = try await session.start()
            XCTFail("Expected cancellation before the first frame capture")
        } catch is CancellationError {
            // Expected: a pre-start cancellation must be sticky until observed.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let captureCount = await capturer.captureCount
        XCTAssertEqual(captureCount, 0)
    }

    func testAutomaticScrollSessionCallsDriverWithConfiguredPointAndAmount() async throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let second = try makePixelBuffer(startingAtRow: 48, height: 100)
        let capturer = SequenceScrollFrameCapturer(images: [
            try first.makeCGImage(),
            try second.makeCGImage()
        ])
        let driver = RecordingAutomaticScrollDriver()
        let scrollPoint = CGPoint(x: 320, y: 240)
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                scrollPoint: scrollPoint,
                mode: .automatic(AutomaticScrollConfiguration(
                    amount: 420,
                    consecutiveDuplicateLimit: 2
                )),
                captureInterval: 0.1,
                maximumFrames: 2,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        let result = try await session.start()
        let calls = await driver.calls

        XCTAssertEqual(result.acceptedFrameCount, 2)
        XCTAssertEqual(calls, [AutomaticScrollCall(point: scrollPoint, amount: 420)])
    }

    func testAutomaticScrollSessionFailsWhenInitialScrollAttemptsDoNotMoveContent() async throws {
        let frame = try makePixelBuffer(startingAtRow: 0, height: 100)
        let image = try frame.makeCGImage()
        let capturer = SequenceScrollFrameCapturer(images: [image, image, image])
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: .automatic(AutomaticScrollConfiguration(
                    amount: 400,
                    consecutiveDuplicateLimit: 2
                )),
                captureInterval: 0.1,
                maximumFrames: 5,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        do {
            _ = try await session.start()
            XCTFail("A target that never moves must not produce a one-frame result")
        } catch let error as ScrollCaptureError {
            XCTAssertEqual(error, .targetDidNotScroll)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let captureCount = await capturer.captureCount
        let calls = await driver.calls
        XCTAssertEqual(captureCount, 3)
        XCTAssertEqual(calls.count, 2)
    }

    func testAutomaticScrollSessionTreatsDuplicatesAsEndAfterContentMoved() async throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let second = try makePixelBuffer(startingAtRow: 48, height: 100)
        let firstImage = try first.makeCGImage()
        let secondImage = try second.makeCGImage()
        let capturer = SequenceScrollFrameCapturer(images: [
            firstImage,
            secondImage,
            secondImage,
            secondImage
        ])
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: .automatic(AutomaticScrollConfiguration(
                    amount: 400,
                    consecutiveDuplicateLimit: 2
                )),
                captureInterval: 0.1,
                maximumFrames: 5,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        let result = try await session.start()

        XCTAssertEqual(result.stopReason, .endDetected)
        XCTAssertEqual(result.capturedFrameCount, 4)
        XCTAssertEqual(result.acceptedFrameCount, 2)
        XCTAssertEqual(result.overlaps.count, 1)
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testAutomaticScrollSessionRecapturesTransientFrameWithoutScrollingAgain() async throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let transient = try makeSolidPixelBuffer(width: 64, height: 100, value: 245)
        let stableSecond = try makePixelBuffer(startingAtRow: 60, height: 100)
        let capturer = SequenceScrollFrameCapturer(images: try [
            first.makeCGImage(),
            transient.makeCGImage(),
            stableSecond.makeCGImage()
        ])
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: .automatic(AutomaticScrollConfiguration(amount: 35)),
                captureInterval: 0.1,
                maximumFrames: 2,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        let result = try await session.start()
        let captureCount = await capturer.captureCount
        let calls = await driver.calls

        XCTAssertEqual(result.stopReason, .maximumFrames)
        XCTAssertEqual(result.capturedFrameCount, 3)
        XCTAssertEqual(result.acceptedFrameCount, 2)
        XCTAssertEqual(result.overlaps.map(\.overlapPixels), [40])
        XCTAssertEqual(captureCount, 3)
        XCTAssertEqual(calls.count, 1, "Same-position recovery must not issue another scroll")
    }

    func testAutomaticScrollSessionFailsWithLastDiagnosticsAfterThreeUnreliableCandidates() async throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let capturer = SequenceScrollFrameCapturer(images: try [
            first.makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 245).makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 225).makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 205).makeCGImage()
        ])
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: .automatic(AutomaticScrollConfiguration(amount: 35)),
                captureInterval: 0.1,
                maximumFrames: 2,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        do {
            _ = try await session.start()
            XCTFail("Three unreliable captures at one position must fail closed")
        } catch let error as ScrollCaptureError {
            guard case .unreliableOverlap(let frame, let diagnostics) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(frame, 2)
            XCTAssertEqual(diagnostics.failureReason, .differenceTooHigh)
            XCTAssertNotNil(diagnostics.candidateOverlapPixels)
            XCTAssertNotNil(diagnostics.normalizedDifference)
            XCTAssertGreaterThan(diagnostics.evaluatedCandidateCount, 0)
            XCTAssertTrue(error.localizedDescription.contains("相邻画面差异过大"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let captureCount = await capturer.captureCount
        let calls = await driver.calls
        XCTAssertEqual(captureCount, 4)
        XCTAssertEqual(calls.count, 1, "Retries at one scroll position must not re-scroll")
    }

    func testAutomaticScrollSessionCarriesOnlyValidatedPrefixAfterLaterFailure() async throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let second = try makePixelBuffer(startingAtRow: 60, height: 100)
        let capturer = SequenceScrollFrameCapturer(images: try [
            first.makeCGImage(),
            second.makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 245).makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 225).makeCGImage(),
            makeSolidPixelBuffer(width: 64, height: 100, value: 205).makeCGImage()
        ])
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: .automatic(AutomaticScrollConfiguration(amount: 35)),
                captureInterval: 0.1,
                maximumFrames: 5,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        do {
            _ = try await session.start()
            XCTFail("A later unreliable frame must not turn the prefix into a full success")
        } catch let failure as ScrollCapturePartialFailure {
            guard case .unreliableOverlap(let frame, _) = failure.underlying else {
                return XCTFail("Unexpected underlying error: \(failure.underlying)")
            }
            XCTAssertEqual(frame, 3)
            XCTAssertEqual(failure.partialResult.acceptedFrameCount, 2)
            XCTAssertEqual(failure.partialResult.capturedFrameCount, 5)
            XCTAssertEqual(failure.partialResult.stopReason, .failureRecovered)
            XCTAssertEqual(failure.partialResult.overlaps.map(\.overlapPixels), [40])
            XCTAssertTrue(
                failure.partialResult.warnings.contains("这是失败前已可靠采集的部分结果")
            )

            let partialPixels = try ScrollPixelBuffer(cgImage: failure.partialResult.image)
            let expected = try makePixelBuffer(startingAtRow: 0, height: 160)
            XCTAssertEqual(partialPixels.width, expected.width)
            XCTAssertEqual(partialPixels.height, expected.height)
            XCTAssertEqual(partialPixels.rgbaData, expected.rgbaData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let captureCount = await capturer.captureCount
        let calls = await driver.calls
        XCTAssertEqual(captureCount, 5)
        XCTAssertEqual(calls.count, 2, "Same-position recovery must not issue another scroll")
    }

    func testEveryCaptureModeFailsWithoutProducingImageWhenOverlapIsUnreliable() async throws {
        let firstPixels = try makeBrightnessShiftedPixelBuffer(
            startingAtRow: 0,
            brightnessOffset: 0,
            height: 100
        )
        let secondPixels = try makeBrightnessShiftedPixelBuffer(
            startingAtRow: 60,
            brightnessOffset: 20,
            height: 100
        )
        var overlapSearch = ScrollOverlapSearchConfiguration()
        overlapSearch.maximumNormalizedDifference = 0.075
        let lowConfidenceAnalysis = try ScrollOverlapEstimator(
            configuration: overlapSearch
        ).analyze(
            previous: firstPixels,
            next: secondPixels
        )
        let lowConfidenceEstimate = try XCTUnwrap(lowConfidenceAnalysis.estimate)
        XCTAssertLessThan(lowConfidenceEstimate.confidence, 0.55)

        let images = [
            try firstPixels.makeCGImage(),
            try secondPixels.makeCGImage()
        ]
        let modes: [(name: String, mode: ScrollCaptureMode)] = [
            ("automatic", .automatic(AutomaticScrollConfiguration())),
            ("manual", .manual)
        ]

        for captureMode in modes {
            let capturer = SequenceScrollFrameCapturer(images: images)
            var configuration = ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: 64, height: 100),
                mode: captureMode.mode,
                captureInterval: 0.1,
                maximumFrames: 2,
                maximumDuration: 10
            )
            configuration.overlapSearch = overlapSearch
            let session = ScrollCaptureSession(
                configuration: configuration,
                capturer: capturer,
                scrollDriver: NoOpAutomaticScrollDriver()
            )

            do {
                _ = try await session.start()
                XCTFail("Unreliable \(captureMode.name) overlap must not produce an image")
            } catch let error as ScrollCaptureError {
                guard case .unreliableOverlap(let frame, let diagnostics) = error else {
                    XCTFail("Unexpected \(captureMode.name) error: \(error)")
                    continue
                }
                XCTAssertEqual(frame, 2, captureMode.name)
                XCTAssertNil(diagnostics.failureReason, captureMode.name)
                XCTAssertEqual(
                    diagnostics.candidateOverlapPixels,
                    lowConfidenceEstimate.overlapPixels,
                    captureMode.name
                )
                XCTAssertEqual(
                    try XCTUnwrap(diagnostics.confidence),
                    lowConfidenceEstimate.confidence,
                    accuracy: 0.000_001,
                    captureMode.name
                )
                XCTAssertTrue(
                    error.localizedDescription.contains("未生成可能错版的长图"),
                    captureMode.name
                )
            } catch {
                XCTFail("Unexpected \(captureMode.name) error: \(error)")
            }

            let captureCount = await capturer.captureCount
            XCTAssertEqual(captureCount, 2, captureMode.name)
        }
    }

    func testScrollCaptureRemovesFixedTopBarBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(top: 18, left: 0)
    }

    func testScrollCaptureRemovesFixedLeftSidebarBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(top: 0, left: 20)
    }

    func testScrollCaptureRemovesFixedBottomBarBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(bottom: 16)
    }

    func testScrollCaptureRemovesFixedRightSidebarBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(right: 18)
    }

    func testScrollCaptureRemovesFixedTopAndLeftBandsBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(top: 18, left: 20)
    }

    func testScrollCaptureRemovesAllFixedEdgeBandsBeforeStitching() async throws {
        try await assertFixedBandsAreRemoved(
            top: 12,
            bottom: 14,
            left: 16,
            right: 18
        )
    }

    func testScrollCaptureDoesNotCropPureScrollingContent() async throws {
        try await assertFixedBandsAreRemoved(top: 0, left: 0)
    }

    func testScrollCaptureFailsClosedForInternalFixedOverlay() async throws {
        let width = 96
        let height = 120
        let scrollDistance = 48
        let overlay = CGRect(x: 28, y: 24, width: 40, height: 26)
        let first = try makeSyntheticScrollFrame(
            startingAtRow: 0,
            width: width,
            height: height,
            internalFixedOverlay: overlay
        )
        let second = try makeSyntheticScrollFrame(
            startingAtRow: scrollDistance,
            width: width,
            height: height,
            internalFixedOverlay: overlay
        )

        await assertScrollCaptureFailsClosed(frames: [first, second], expectedFrame: 2)
    }

    func testScrollCaptureFailsClosedForInternalOverlayOutsideOverlapRows() async throws {
        let width = 96
        let height = 140
        let scrollDistance = 98
        let overlay = CGRect(x: 22, y: 55, width: 52, height: 30)
        let frames = try [
            makeSyntheticScrollFrame(
                startingAtRow: 0,
                width: width,
                height: height,
                internalFixedOverlay: overlay
            ),
            makeSyntheticScrollFrame(
                startingAtRow: scrollDistance,
                width: width,
                height: height,
                internalFixedOverlay: overlay
            )
        ]

        await assertScrollCaptureFailsClosed(frames: frames, expectedFrame: 2)
    }

    func testLargeMovingRegionDetectorCompletesFullPath() throws {
        let width = 2_000
        let height = 1_600
        let displacement = 900
        let first = try makeSyntheticScrollFrame(
            startingAtRow: 0,
            width: width,
            height: height
        )
        let second = try makeSyntheticScrollFrame(
            startingAtRow: displacement,
            width: width,
            height: height
        )
        let detection = try ScrollMovingRegionDetector().detect(
            previous: first,
            next: second,
            overlapPixels: height - displacement
        )

        XCTAssertEqual(
            detection,
            .safe(ScrollMovingRegion(
                cropRect: .full(width: width, height: height),
                removedTopPixels: 0,
                removedBottomPixels: 0,
                removedLeftPixels: 0,
                removedRightPixels: 0
            ))
        )
    }

    func testScrollCaptureFailsClosedWhenMovingRegionDriftsBetweenFrames() async throws {
        let width = 96
        let height = 120
        let scrollDistance = 42
        let frames = try [
            makeSyntheticScrollFrame(
                startingAtRow: 0,
                width: width,
                height: height,
                fixedTop: 16,
                fixedLeft: 14
            ),
            makeSyntheticScrollFrame(
                startingAtRow: scrollDistance,
                width: width,
                height: height,
                fixedTop: 16,
                fixedLeft: 14
            ),
            makeSyntheticScrollFrame(
                startingAtRow: scrollDistance * 2,
                width: width,
                height: height,
                fixedTop: 15,
                fixedLeft: 14
            )
        ]

        await assertScrollCaptureFailsClosed(frames: frames, expectedFrame: 3)
    }

    func testScrollCaptureFailsClosedWhenStickyHeaderAppearsAfterSecondFrame() async throws {
        let width = 160
        let height = 180
        let scrollDistance = 60
        var documentRows: [[(UInt8, UInt8, UInt8)]] = []
        for globalY in 0 ..< (height + scrollDistance * 3) {
            var row: [(UInt8, UInt8, UInt8)] = []
            for x in 0 ..< width {
                let red = UInt8((globalY * 17 + x * 13) % 251)
                let green = UInt8((globalY * 29 + x * 7 + x * globalY) % 253)
                let blue = UInt8((globalY * 5 + x * 31) % 247)
                row.append((red, green, blue))
            }
            documentRows.append(row)
        }
        let first = try makeFrame(documentRows: documentRows, startingAtRow: 0, height: height)
        let second = try makeFrame(
            documentRows: documentRows,
            startingAtRow: scrollDistance,
            height: height
        )
        let lateSticky = try makeFrame(
            documentRows: documentRows,
            startingAtRow: scrollDistance * 2,
            height: height,
            fixedTopRowsFrom: 0 ..< 22,
            fixedTopSourceStartRow: scrollDistance
        )

        // The session retries a rejected logical frame twice at the same scroll
        // position. Supply the same stable sticky candidate for both retries so
        // the final error remains the frame-3 moving-region diagnosis.
        await assertScrollCaptureFailsClosed(
            frames: [first, second, lateSticky, lateSticky, lateSticky],
            expectedFrame: 3
        )
    }

    private func makeFrame(
        documentRows: [[(UInt8, UInt8, UInt8)]],
        startingAtRow: Int,
        height: Int,
        fixedTopRowsFrom: Range<Int>? = nil,
        fixedTopSourceStartRow: Int = 0
    ) throws -> ScrollPixelBuffer {
        let width = documentRows[0].count
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let sourceRow: Int
            if let fixedTopRowsFrom, fixedTopRowsFrom.contains(y) {
                sourceRow = fixedTopSourceStartRow + y
            } else {
                sourceRow = startingAtRow + y
            }
            for x in 0 ..< width {
                let pixel = documentRows[sourceRow][x]
                let offset = (y * width + x) * 4
                bytes[offset] = pixel.0
                bytes[offset + 1] = pixel.1
                bytes[offset + 2] = pixel.2
                bytes[offset + 3] = 255
            }
        }
        return try ScrollPixelBuffer(width: width, height: height, rgbaData: Data(bytes))
    }

    func testScrollCaptureSupportsSparseDocumentOverFixedSmoothGradient() async throws {
        let width = 320
        let height = 240
        let displacement = 84
        let expectedOverlap = height - displacement
        let frames = try [0, displacement, displacement * 2].map {
            try makeFixedGradientSparseDocumentFrame(
                startingAtRow: $0,
                width: width,
                height: height
            )
        }

        let analysis = try ScrollOverlapEstimator().analyze(
            previous: frames[0],
            next: frames[1]
        )
        let estimate = try XCTUnwrap(analysis.estimate)
        XCTAssertEqual(estimate.overlapPixels, expectedOverlap)
        XCTAssertGreaterThanOrEqual(estimate.confidence, 0.55)

        XCTAssertEqual(
            try ScrollMovingRegionDetector().detect(
                previous: frames[0],
                next: frames[1],
                overlapPixels: expectedOverlap
            ),
            .safe(ScrollMovingRegion(
                cropRect: .full(width: width, height: height),
                removedTopPixels: 0,
                removedBottomPixels: 0,
                removedLeftPixels: 0,
                removedRightPixels: 0
            ))
        )

        let capturer = SequenceScrollFrameCapturer(
            images: try frames.map { try $0.makeCGImage() }
        )
        let driver = RecordingAutomaticScrollDriver()
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(x: 0, y: 0, width: width, height: height),
                mode: .manual,
                captureInterval: 0.1,
                maximumFrames: frames.count,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: driver
        )

        let result = try await session.start()
        let scrollCalls = await driver.calls

        XCTAssertEqual(result.stopReason, .maximumFrames)
        XCTAssertEqual(result.acceptedFrameCount, 3)
        XCTAssertEqual(result.overlaps.map(\.overlapPixels), [
            expectedOverlap,
            expectedOverlap
        ])
        XCTAssertTrue(scrollCalls.isEmpty, "Manual capture must never invoke the scroll driver")
    }

    func testFixedSmoothGradientDoesNotHideHighTextureInternalOverlay() async throws {
        let width = 320
        let height = 240
        let displacement = 84
        let overlay = CGRect(x: 96, y: 72, width: 128, height: 54)
        let frames = try [0, displacement].map {
            try makeFixedGradientSparseDocumentFrame(
                startingAtRow: $0,
                width: width,
                height: height,
                internalFixedOverlay: overlay
            )
        }

        do {
            _ = try await captureSyntheticScrollFrames(frames)
            XCTFail("A high-texture fixed overlay must never produce a stitched result")
        } catch let error as ScrollCaptureError {
            switch error {
            case .unreliableScrollRegion(frame: 2),
                 .unreliableOverlap(frame: 2, diagnostics: _):
                break
            default:
                XCTFail("Unexpected fail-closed error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOverlapEstimatorFindsExactSharedRows() throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let second = try makePixelBuffer(startingAtRow: 60, height: 100)

        let estimate = try XCTUnwrap(
            ScrollOverlapEstimator().estimate(previous: first, next: second)
        )

        XCTAssertEqual(estimate.overlapPixels, 40)
        XCTAssertEqual(estimate.newContentPixels, 60)
        XCTAssertFalse(estimate.usedFallback)
        XCTAssertEqual(
            try XCTUnwrap(estimate.normalizedDifference),
            0,
            accuracy: 0.000_001
        )
    }

    func testOverlapEstimatorRefinesExactHighResolutionOverlapOutsideOldCoarseGrid() throws {
        let width = 2_000
        let height = 1_600
        let expectedOverlap = 703
        let displacement = height - expectedOverlap
        let first = try makePixelBuffer(startingAtRow: 0, width: width, height: height)
        let second = try makePixelBuffer(
            startingAtRow: displacement,
            width: width,
            height: height
        )
        let configuration = ScrollOverlapSearchConfiguration()
        let minimumOverlap = Int(
            (Double(height) * configuration.minimumOverlapRatio).rounded()
        )
        let maximumOverlap = Int(
            (Double(height) * configuration.maximumOverlapRatio).rounded()
        )
        let oldCoarseStep = max(
            1,
            (maximumOverlap - minimumOverlap + configuration.maximumCoarseCandidates - 1)
                / configuration.maximumCoarseCandidates
        )
        XCTAssertNotEqual(
            (expectedOverlap - minimumOverlap) % oldCoarseStep,
            0,
            "The fixture must exercise a true overlap skipped by the old coarse grid"
        )

        let analysis = try ScrollOverlapEstimator(configuration: configuration).analyze(
            previous: first,
            next: second
        )
        let estimate = try XCTUnwrap(analysis.estimate)

        XCTAssertNil(analysis.diagnostics.failureReason)
        XCTAssertEqual(estimate.overlapPixels, expectedOverlap)
        XCTAssertEqual(estimate.newContentPixels, displacement)
        XCTAssertEqual(try XCTUnwrap(estimate.normalizedDifference), 0, accuracy: 0.000_001)
    }

    func testOverlapEstimatorFindsSparseTexturedMatchWithoutPromotingFlatCandidates() throws {
        let width = 320
        let height = 240
        let displacement = 84
        let expectedOverlap = height - displacement
        let first = try makeSparseTextPixelBuffer(
            startingAtRow: 0,
            width: width,
            height: height
        )
        let second = try makeSparseTextPixelBuffer(
            startingAtRow: displacement,
            width: width,
            height: height
        )
        var configuration = ScrollOverlapSearchConfiguration()
        configuration.maximumCoarseCandidates = 24
        configuration.refinementCandidateCount = 8
        let minimumOverlap = Int(
            (Double(height) * configuration.minimumOverlapRatio).rounded()
        )
        let maximumOverlap = Int(
            (Double(height) * configuration.maximumOverlapRatio).rounded()
        )
        let coarseStep = max(
            1,
            (maximumOverlap - minimumOverlap + configuration.maximumCoarseCandidates - 1)
                / configuration.maximumCoarseCandidates
        )
        XCTAssertNotEqual((expectedOverlap - minimumOverlap) % coarseStep, 0)

        let analysis = try ScrollOverlapEstimator(configuration: configuration).analyze(
            previous: first,
            next: second
        )
        let estimate = try XCTUnwrap(analysis.estimate)

        XCTAssertNil(analysis.diagnostics.failureReason)
        XCTAssertEqual(estimate.overlapPixels, expectedOverlap)
        XCTAssertGreaterThan(try XCTUnwrap(analysis.diagnostics.texture), 0)
    }

    func testOverlapEstimatorReportsInsufficientTextureForPureColorFrames() throws {
        let first = try makeSolidPixelBuffer(width: 128, height: 200, value: 240)
        let second = try makeSolidPixelBuffer(width: 128, height: 200, value: 240)

        let analysis = try ScrollOverlapEstimator().analyze(previous: first, next: second)

        XCTAssertNil(analysis.estimate)
        XCTAssertEqual(analysis.diagnostics.failureReason, .insufficientTexture)
        XCTAssertEqual(analysis.diagnostics.texture, 0)
        XCTAssertNotNil(analysis.diagnostics.candidateOverlapPixels)
        XCTAssertGreaterThan(analysis.diagnostics.evaluatedCandidateCount, 0)
        XCTAssertTrue(analysis.diagnostics.localizedDescription.contains("选区纹理不足"))
    }

    func testOverlapEstimatorReportsAmbiguousForRepeatingTexture() throws {
        let first = try makeRepeatingTexturePixelBuffer(
            startingAtRow: 0,
            width: 128,
            height: 200,
            period: 16
        )
        let second = try makeRepeatingTexturePixelBuffer(
            startingAtRow: 64,
            width: 128,
            height: 200,
            period: 16
        )

        let analysis = try ScrollOverlapEstimator().analyze(previous: first, next: second)

        XCTAssertNil(analysis.estimate)
        XCTAssertEqual(analysis.diagnostics.failureReason, .ambiguous)
        XCTAssertNotNil(analysis.diagnostics.candidateOverlapPixels)
        XCTAssertEqual(analysis.diagnostics.normalizedDifference, 0)
        XCTAssertGreaterThan(try XCTUnwrap(analysis.diagnostics.texture), 0)
        XCTAssertTrue(analysis.diagnostics.localizedDescription.contains("多个相似"))
    }

    func testVerticalStitchProducesExactContinuousPixels() throws {
        let first = try makePixelBuffer(startingAtRow: 0, height: 100)
        let second = try makePixelBuffer(startingAtRow: 60, height: 100)
        let expected = try makePixelBuffer(startingAtRow: 0, height: 160)

        let result = try VerticalImageStitcher().stitch(
            pixelBuffers: [first, second],
            overlaps: [40]
        )

        XCTAssertEqual(result.width, expected.width)
        XCTAssertEqual(result.height, expected.height)
        XCTAssertEqual(result.rgbaData, expected.rgbaData)
    }

    @MainActor
    func testPinnedImageRotationPreservesRetinaPixelCount() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 100,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 100, height: 50)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let rotated = PEEKPinImageRenderer.rotated(image, quarterTurns: 1)
        let representation = try XCTUnwrap(rotated.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        })

        XCTAssertEqual(rotated.size, NSSize(width: 50, height: 100))
        XCTAssertEqual(representation.pixelsWide, 100)
        XCTAssertEqual(representation.pixelsHigh, 200)
    }

    private func makePixelBuffer(
        startingAtRow startRow: Int,
        width: Int = 64,
        height: Int
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for localY in 0 ..< height {
            let globalY = startRow + localY
            for x in 0 ..< width {
                let offset = (localY * width + x) * 4
                bytes[offset] = UInt8((globalY * 17 + x * 13) % 251)
                bytes[offset + 1] = UInt8((globalY * 29 + x * 7 + x * globalY) % 253)
                bytes[offset + 2] = UInt8((globalY * 5 + x * 31) % 247)
                bytes[offset + 3] = 255
            }
        }
        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    private func makeBrightnessShiftedPixelBuffer(
        startingAtRow startRow: Int,
        brightnessOffset: Int,
        width: Int = 64,
        height: Int
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for localY in 0 ..< height {
            let globalY = startRow + localY
            for x in 0 ..< width {
                let offset = (localY * width + x) * 4
                bytes[offset] = UInt8(40 + (globalY * 17 + x * 13) % 120 + brightnessOffset)
                bytes[offset + 1] = UInt8(
                    40 + (globalY * 29 + x * 7 + x * globalY) % 120 + brightnessOffset
                )
                bytes[offset + 2] = UInt8(40 + (globalY * 5 + x * 31) % 120 + brightnessOffset)
                bytes[offset + 3] = 255
            }
        }
        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    private func makeSolidPixelBuffer(
        width: Int,
        height: Int,
        value: UInt8
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: value, count: width * height * 4)
        for pixel in 0 ..< width * height {
            bytes[pixel * 4 + 3] = 255
        }
        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    /// Mostly blank page content with sparse, non-repeating text-like rows.
    /// It mirrors pages whose background occupies most sampled pixels while
    /// still providing enough real glyph edges for an exact overlap match.
    private func makeSparseTextPixelBuffer(
        startingAtRow startRow: Int,
        width: Int,
        height: Int
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for localY in 0 ..< height {
            let globalY = startRow + localY
            let paragraph = globalY / 47
            let rowInParagraph = globalY % 47
            let isTextRow = (7 ..< 17).contains(rowInParagraph)
            let variableWidth = max(1, width - 100)
            let lineEnd = min(width - 20, 70 + (paragraph * 43) % variableWidth)

            for x in 0 ..< width {
                let offset = (localY * width + x) * 4
                let isGlyph = isTextRow
                    && x >= 20
                    && x < lineEnd
                    && (x + paragraph * 11 + rowInParagraph * 3) % 19 < 9
                if isGlyph {
                    let shade = UInt8(
                        28 + (paragraph * 17 + rowInParagraph * 5 + x / 19 * 3) % 72
                    )
                    bytes[offset] = shade
                    bytes[offset + 1] = min(255, shade + 4)
                    bytes[offset + 2] = min(255, shade + 9)
                } else {
                    bytes[offset] = 244
                    bytes[offset + 1] = 246
                    bytes[offset + 2] = 249
                }
                bytes[offset + 3] = 255
            }
        }
        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    private func makeRepeatingTexturePixelBuffer(
        startingAtRow startRow: Int,
        width: Int,
        height: Int,
        period: Int
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for localY in 0 ..< height {
            let phase = (startRow + localY) % period
            for x in 0 ..< width {
                let offset = (localY * width + x) * 4
                let isDark = ((x / 4 + phase) % 4) < 2
                let value = UInt8(isDark ? 35 + phase : 220 - phase)
                bytes[offset] = value
                bytes[offset + 1] = UInt8(isDark ? 45 + phase : 225 - phase)
                bytes[offset + 2] = UInt8(isDark ? 55 + phase : 230 - phase)
                bytes[offset + 3] = 255
            }
        }
        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    private func assertFixedBandsAreRemoved(
        top: Int = 0,
        bottom: Int = 0,
        left: Int = 0,
        right: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let width = 96
        let height = 120
        let scrollDistance = 48
        let contentWidth = width - left - right
        let contentHeight = height - top - bottom
        let frames = try [
            makeSyntheticScrollFrame(
                startingAtRow: 0,
                width: width,
                height: height,
                fixedTop: top,
                fixedBottom: bottom,
                fixedLeft: left,
                fixedRight: right
            ),
            makeSyntheticScrollFrame(
                startingAtRow: scrollDistance,
                width: width,
                height: height,
                fixedTop: top,
                fixedBottom: bottom,
                fixedLeft: left,
                fixedRight: right
            ),
            makeSyntheticScrollFrame(
                startingAtRow: scrollDistance * 2,
                width: width,
                height: height,
                fixedTop: top,
                fixedBottom: bottom,
                fixedLeft: left,
                fixedRight: right
            )
        ]
        let result = try await captureSyntheticScrollFrames(frames)
        let actual = try ScrollPixelBuffer(cgImage: result.image)
        let expected = try makePixelBuffer(
            startingAtRow: 0,
            width: contentWidth,
            height: contentHeight + scrollDistance * 2
        )

        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        XCTAssertEqual(actual.rgbaData, expected.rgbaData, file: file, line: line)
        XCTAssertEqual(result.acceptedFrameCount, 3, file: file, line: line)
        XCTAssertEqual(result.overlaps.count, 2, file: file, line: line)
        XCTAssertTrue(
            result.overlaps.allSatisfy { $0.overlapPixels == contentHeight - scrollDistance },
            file: file,
            line: line
        )
    }

    private func assertScrollCaptureFailsClosed(
        frames: [ScrollPixelBuffer],
        expectedFrame: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await captureSyntheticScrollFrames(frames)
            XCTFail("Unsafe moving region must not produce a stitched image", file: file, line: line)
        } catch let failure as ScrollCapturePartialFailure {
            XCTAssertEqual(
                failure.underlying,
                .unreliableScrollRegion(frame: expectedFrame),
                file: file,
                line: line
            )
            XCTAssertEqual(
                failure.partialResult.acceptedFrameCount,
                expectedFrame - 1,
                file: file,
                line: line
            )
        } catch let error as ScrollCaptureError {
            XCTAssertEqual(
                error,
                .unreliableScrollRegion(frame: expectedFrame),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func captureSyntheticScrollFrames(
        _ frames: [ScrollPixelBuffer]
    ) async throws -> ScrollCaptureResult {
        let images = try frames.map { try $0.makeCGImage() }
        let capturer = SequenceScrollFrameCapturer(images: images)
        let session = ScrollCaptureSession(
            configuration: ScrollCaptureConfiguration(
                captureRect: CGRect(
                    x: 0,
                    y: 0,
                    width: frames[0].width,
                    height: frames[0].height
                ),
                mode: .manual,
                captureInterval: 0.1,
                maximumFrames: frames.count,
                maximumDuration: 10
            ),
            capturer: capturer,
            scrollDriver: NoOpAutomaticScrollDriver()
        )
        return try await session.start()
    }

    private func makeSyntheticScrollFrame(
        startingAtRow startRow: Int,
        width: Int,
        height: Int,
        fixedTop: Int = 0,
        fixedBottom: Int = 0,
        fixedLeft: Int = 0,
        fixedRight: Int = 0,
        internalFixedOverlay: CGRect? = nil,
        overlayPatternStartRow: Int? = nil
    ) throws -> ScrollPixelBuffer {
        let contentWidth = width - fixedLeft - fixedRight
        let contentHeight = height - fixedTop - fixedBottom
        let content = try makePixelBuffer(
            startingAtRow: startRow,
            width: contentWidth,
            height: contentHeight
        )
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0 ..< height {
            for x in 0 ..< width {
                let destinationOffset = (y * width + x) * 4
                if y >= fixedTop,
                   y < height - fixedBottom,
                   x >= fixedLeft,
                   x < width - fixedRight {
                    let sourceOffset = ((y - fixedTop) * contentWidth + (x - fixedLeft)) * 4
                    bytes[destinationOffset] = content.rgbaData[sourceOffset]
                    bytes[destinationOffset + 1] = content.rgbaData[sourceOffset + 1]
                    bytes[destinationOffset + 2] = content.rgbaData[sourceOffset + 2]
                    bytes[destinationOffset + 3] = content.rgbaData[sourceOffset + 3]
                } else {
                    bytes[destinationOffset] = UInt8((x * 11 + y * 3 + 37) % 251)
                    bytes[destinationOffset + 1] = UInt8((x * 5 + y * 17 + 71) % 253)
                    bytes[destinationOffset + 2] = UInt8((x * 23 + y * 7 + 19) % 247)
                    bytes[destinationOffset + 3] = 255
                }
            }
        }

        if let overlay = internalFixedOverlay?.integral {
            let minX = max(0, Int(overlay.minX))
            let maxX = min(width, Int(overlay.maxX))
            let minY = max(0, Int(overlay.minY))
            let maxY = min(height, Int(overlay.maxY))
            for y in minY ..< maxY {
                for x in minX ..< maxX {
                    let offset = (y * width + x) * 4
                    if let overlayPatternStartRow {
                        let globalY = overlayPatternStartRow + y
                        bytes[offset] = UInt8((globalY * 17 + x * 13) % 251)
                        bytes[offset + 1] = UInt8(
                            (globalY * 29 + x * 7 + x * globalY) % 253
                        )
                        bytes[offset + 2] = UInt8((globalY * 5 + x * 31) % 247)
                        bytes[offset + 3] = 255
                    } else {
                        bytes[offset] = UInt8((x * 19 + y * 7 + 101) % 251)
                        bytes[offset + 1] = UInt8((x * 3 + y * 29 + 53) % 253)
                        bytes[offset + 2] = UInt8((x * 31 + y * 5 + 13) % 247)
                        bytes[offset + 3] = 255
                    }
                }
            }
        }

        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    /// A browser-like composition where the background is fixed in viewport
    /// coordinates while sparse text belongs to document coordinates. This is
    /// deliberately hostile to whole-frame matching: most pixels prefer the
    /// same screen position, but glyph edges identify the true scroll offset.
    private func makeFixedGradientSparseDocumentFrame(
        startingAtRow startRow: Int,
        width: Int,
        height: Int,
        internalFixedOverlay: CGRect? = nil
    ) throws -> ScrollPixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        for localY in 0 ..< height {
            let globalY = startRow + localY
            let paragraph = globalY / 53
            let rowInParagraph = globalY % 53
            let isTextRow = (9 ..< 19).contains(rowInParagraph)
            let availableLineWidth = max(1, width - 112)
            let lineEnd = min(width - 24, 88 + (paragraph * 47) % availableLineWidth)

            for x in 0 ..< width {
                let offset = (localY * width + x) * 4
                let vertical = height > 1 ? localY * 50 / (height - 1) : 0
                let horizontal = width > 1 ? x * 8 / (width - 1) : 0
                let isGlyph = isTextRow
                    && x >= 28
                    && x < lineEnd
                    && (x + paragraph * 13 + rowInParagraph * 5) % 23 < 10

                if isGlyph {
                    let shade = UInt8(25 + (paragraph * 19 + x / 23 * 7) % 70)
                    bytes[offset] = shade
                    bytes[offset + 1] = min(255, shade + 7)
                    bytes[offset + 2] = min(255, shade + 13)
                } else {
                    // Total variation is large enough to look different after a
                    // scroll, while adjacent pixels remain intentionally smooth.
                    bytes[offset] = UInt8(178 + vertical + horizontal)
                    bytes[offset + 1] = UInt8(190 + vertical * 4 / 5 + horizontal)
                    bytes[offset + 2] = UInt8(211 + vertical * 2 / 5 + horizontal)
                }
                bytes[offset + 3] = 255
            }
        }

        if let overlay = internalFixedOverlay?.integral {
            let minX = max(0, Int(overlay.minX))
            let maxX = min(width, Int(overlay.maxX))
            let minY = max(0, Int(overlay.minY))
            let maxY = min(height, Int(overlay.maxY))
            for y in minY ..< maxY {
                for x in minX ..< maxX {
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8((x * 29 + y * 11 + 31) % 251)
                    bytes[offset + 1] = UInt8((x * 7 + y * 23 + 73) % 253)
                    bytes[offset + 2] = UInt8((x * 17 + y * 31 + 19) % 247)
                    bytes[offset + 3] = 255
                }
            }
        }

        return try ScrollPixelBuffer(
            width: width,
            height: height,
            rgbaData: Data(bytes)
        )
    }

    private func assertWindowAnchorValidationFails(
        anchor: ScrollCaptureWindowAnchor,
        selectionQuartzRect: CGRect = CGRect(x: 150, y: 150, width: 700, height: 500),
        scrollPoint: CGPoint = CGPoint(x: 500, y: 400),
        currentPID: pid_t = 7,
        frontmostPID: pid_t? = 42,
        windowSnapshots: [ScrollCaptureWindowSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ScrollCaptureWindowAnchorValidator.validate(
            anchor: anchor,
            selectionQuartzRect: selectionQuartzRect,
            scrollPoint: scrollPoint,
            currentPID: currentPID,
            frontmostPID: frontmostPID,
            windowSnapshots: windowSnapshots
        ), file: file, line: line) { error in
            XCTAssertEqual(
                error as? ScrollCaptureError,
                .scrollTargetChanged,
                file: file,
                line: line
            )
        }
    }

    private func makeIsolatedUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.shawnshoper.peekTests.hotkeys.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }

    @MainActor
    private func makeTestPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<2 {
            for x in 0..<2 {
                bitmap.setColor(
                    NSColor(deviceRed: 0.1, green: 0.7, blue: 0.35, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private actor CountingScrollFrameCapturer: ScrollFrameCapturing {
    private(set) var captureCount = 0

    func capture(rect: CGRect) async throws -> CGImage {
        captureCount += 1
        throw ScrollCaptureError.captureFailed
    }
}

private actor SequenceScrollFrameCapturer: ScrollFrameCapturing {
    private let images: [CGImage]
    private(set) var captureCount = 0

    init(images: [CGImage]) {
        self.images = images
    }

    func capture(rect: CGRect) async throws -> CGImage {
        guard captureCount < images.count else {
            throw ScrollCaptureError.captureFailed
        }
        let image = images[captureCount]
        captureCount += 1
        return image
    }
}

private actor RecordingScreenImageCapturer: ScreenImageCapturing {
    private let image: CGImage
    private var rects: [CGRect] = []

    init(image: CGImage) {
        self.image = image
    }

    func captureDisplay(
        displayID: CGDirectDisplayID,
        logicalFrame: CGRect
    ) async throws -> CGImage {
        image
    }

    func capture(rect: CGRect) async throws -> CGImage {
        rects.append(rect)
        return image
    }

    func capturedRects() -> [CGRect] { rects }
}

private struct NoOpAutomaticScrollDriver: AutomaticScrollDriving {
    let hasAccessibilityPermission = true

    func scroll(at globalPoint: CGPoint, amount: Int32) async throws {}
}

private struct AutomaticScrollCall: Equatable, Sendable {
    let point: CGPoint
    let amount: Int32
}

private actor RecordingAutomaticScrollDriver: AutomaticScrollDriving {
    nonisolated let hasAccessibilityPermission = true
    private(set) var calls: [AutomaticScrollCall] = []

    func scroll(at globalPoint: CGPoint, amount: Int32) async throws {
        calls.append(AutomaticScrollCall(point: globalPoint, amount: amount))
    }
}
