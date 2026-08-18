#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BrandAssetError.cannotRead(url.path)
        }

        width = image.width
        height = image.height
        pixels = .init(repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrandAssetError.cannotCreateContext
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    mutating func removeEdgeConnectedCheckerboard() {
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * 8)

        func isNeutralBackground(_ pixelIndex: Int) -> Bool {
            let offset = pixelIndex * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            // Image generation returns transparency as a connected light-gray
            // checkerboard. Accept both checker tones while keeping the white
            // mascot intact because the blue squircle separates it from every
            // image edge.
            return min(red, green, blue) >= 165
                && max(red, green, blue) - min(red, green, blue) <= 18
        }

        func enqueue(_ pixelIndex: Int) {
            guard !visited[pixelIndex], isNeutralBackground(pixelIndex) else { return }
            visited[pixelIndex] = true
            queue.append(pixelIndex)
        }

        for x in 0..<width {
            enqueue(x)
            enqueue((height - 1) * width + x)
        }
        for y in 0..<height {
            enqueue(y * width)
            enqueue(y * width + width - 1)
        }

        var cursor = 0
        while cursor < queue.count {
            let pixelIndex = queue[cursor]
            cursor += 1
            let x = pixelIndex % width
            let y = pixelIndex / width

            if x > 0 { enqueue(pixelIndex - 1) }
            if x + 1 < width { enqueue(pixelIndex + 1) }
            if y > 0 { enqueue(pixelIndex - width) }
            if y + 1 < height { enqueue(pixelIndex + width) }
        }

        for pixelIndex in queue {
            let offset = pixelIndex * 4
            // The buffer is premultiplied RGBA. Clear color channels together
            // with alpha so ImageIO cannot clamp invalid RGB > alpha pixels
            // back into opaque checkerboard pixels while encoding PNG.
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }
    }

    mutating func convertToBlackTemplateMask() {
        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * 4
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let luminance = (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
            var alpha = UInt8(max(0, min(255, Int((255 - luminance).rounded()))))
            if alpha < 28 { alpha = 0 }
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = alpha
        }
    }

    func contentBounds(alphaThreshold: UInt8 = 24) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    func cgImage() throws -> CGImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw BrandAssetError.cannotCreateImage
        }
        return image
    }
}

private enum BrandAssetError: LocalizedError {
    case cannotRead(String)
    case cannotCreateContext
    case cannotCreateImage
    case cannotWrite(String)
    case emptyTemplate

    var errorDescription: String? {
        switch self {
        case .cannotRead(let path): "Cannot read image at \(path)"
        case .cannotCreateContext: "Cannot create bitmap context"
        case .cannotCreateImage: "Cannot create CGImage"
        case .cannotWrite(let path): "Cannot write image at \(path)"
        case .emptyTemplate: "Menu-bar template source is empty"
        }
    }
}

private func renderedImage(
    source: CGImage,
    sourceRect: CGRect,
    size: Int,
    padding: CGFloat = 0
) throws -> CGImage {
    let bytesPerRow = size * 4
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    guard let context = CGContext(
        data: &pixels,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw BrandAssetError.cannotCreateContext
    }

    context.interpolationQuality = .high
    let available = CGFloat(size) - padding * 2
    let scale = min(available / sourceRect.width, available / sourceRect.height)
    let drawSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
    let destination = CGRect(
        x: (CGFloat(size) - drawSize.width) / 2,
        y: (CGFloat(size) - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )

    guard let cropped = source.cropping(to: sourceRect.integral) else {
        throw BrandAssetError.cannotCreateImage
    }
    context.draw(cropped, in: destination)
    guard let output = context.makeImage() else { throw BrandAssetError.cannotCreateImage }
    return output
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw BrandAssetError.cannotWrite(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw BrandAssetError.cannotWrite(url.path)
    }
}

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let sourceRoot = root.appendingPathComponent("PEEK/Resources/BrandSources")
private let appIconRoot = root.appendingPathComponent(
    "PEEK/Resources/Assets.xcassets/AppIcon.appiconset"
)
private let menuIconRoot = root.appendingPathComponent(
    "PEEK/Resources/Assets.xcassets/PEEKMenuBarIcon.imageset"
)

do {
    var appIcon = try RGBAImage(
        contentsOf: sourceRoot.appendingPathComponent("PEEK-AppIcon-Generated.png")
    )
    appIcon.removeEdgeConnectedCheckerboard()
    let appCGImage = try appIcon.cgImage()
    let appSizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in appSizes {
        let output = try renderedImage(
            source: appCGImage,
            sourceRect: CGRect(x: 0, y: 0, width: appIcon.width, height: appIcon.height),
            size: size
        )
        try writePNG(output, to: appIconRoot.appendingPathComponent("AppIcon-\(size).png"))
        if size == 1024 {
            try writePNG(
                output,
                to: sourceRoot.appendingPathComponent("PEEK-AppIconSource.png")
            )
        }
    }

    var menuIcon = try RGBAImage(
        contentsOf: sourceRoot.appendingPathComponent("PEEK-MenuBar-Generated.png")
    )
    menuIcon.convertToBlackTemplateMask()
    guard let bounds = menuIcon.contentBounds() else { throw BrandAssetError.emptyTemplate }
    let menuCGImage = try menuIcon.cgImage()
    for size in [18, 36] {
        let output = try renderedImage(
            source: menuCGImage,
            sourceRect: bounds,
            size: size,
            padding: CGFloat(size) * 0.08
        )
        let suffix = size == 36 ? "@2x" : ""
        try writePNG(
            output,
            to: menuIconRoot.appendingPathComponent("PEEKMenuBarIcon\(suffix).png")
        )
    }

    print("Generated PEEK app icon and menu-bar template assets.")
} catch {
    fputs("Brand asset generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
