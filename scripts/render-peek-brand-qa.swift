#!/usr/bin/env swift

import AppKit
import Foundation

private enum QAError: Error {
    case unreadableImage(String)
    case cannotCreateOutput
    case cannotEncodeOutput
}

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let auditRoot = root.appendingPathComponent("audit/peek-brand-2026-08-17")
private let referenceURL = auditRoot.appendingPathComponent("reference.png")
private let iconURL = root.appendingPathComponent(
    "PEEK/Resources/BrandSources/PEEK-AppIconSource.png"
)
private let menuURL = root.appendingPathComponent(
    "PEEK/Resources/Assets.xcassets/PEEKMenuBarIcon.imageset/PEEKMenuBarIcon@2x.png"
)
private let outputURL = auditRoot.appendingPathComponent("comparison.png")

private func image(at url: URL) throws -> NSImage {
    guard let image = NSImage(contentsOf: url) else {
        throw QAError.unreadableImage(url.path)
    }
    return image
}

private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
    let scale = min(rect.width / size.width, rect.height / size.height)
    let fitted = NSSize(width: size.width * scale, height: size.height * scale)
    return NSRect(
        x: rect.midX - fitted.width / 2,
        y: rect.midY - fitted.height / 2,
        width: fitted.width,
        height: fitted.height
    )
}

do {
    let reference = try image(at: referenceURL)
    let icon = try image(at: iconURL)
    let menu = try image(at: menuURL)
    let canvasSize = NSSize(width: 1800, height: 980)
    let output = NSImage(size: canvasSize)

    output.lockFocus()
    NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let titleStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    let subtitleStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
    ]

    "Selected visual".draw(at: NSPoint(x: 56, y: 914), withAttributes: titleStyle)
    "PEEK production assets".draw(at: NSPoint(x: 956, y: 914), withAttributes: titleStyle)

    let leftPanel = NSRect(x: 48, y: 64, width: 820, height: 820)
    let rightPanel = NSRect(x: 932, y: 64, width: 820, height: 820)
    for panel in [leftPanel, rightPanel] {
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 30, yRadius: 30).fill()
    }

    reference.draw(
        in: aspectFit(reference.size, in: leftPanel.insetBy(dx: 28, dy: 28)),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    let iconRect = NSRect(x: 1057, y: 282, width: 570, height: 570)
    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

    let menuPlate = NSRect(x: 1224, y: 118, width: 236, height: 96)
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: menuPlate, xRadius: 22, yRadius: 22).fill()
    let menuRect = NSRect(x: 1256, y: 134, width: 64, height: 64)
    menu.draw(in: menuRect, from: .zero, operation: .sourceOver, fraction: 1)
    "PEEK".draw(at: NSPoint(x: 1338, y: 146), withAttributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
    ])
    "App icon + monochrome macOS template".draw(
        at: NSPoint(x: 1068, y: 78),
        withAttributes: subtitleStyle
    )

    output.unlockFocus()
    guard let tiff = output.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw QAError.cannotEncodeOutput
    }
    try FileManager.default.createDirectory(at: auditRoot, withIntermediateDirectories: true)
    try png.write(to: outputURL, options: .atomic)
    print(outputURL.path)
} catch {
    fputs("PEEK brand QA render failed: \(error)\n", stderr)
    exit(1)
}
