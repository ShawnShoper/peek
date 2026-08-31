import Foundation
import OSLog

/// 相邻两帧中可安全用于纵向拼接的单一矩形区域。
/// 边缘固定带会被裁除；紧凑悬浮控件交给拼接器回填，无法恢复的固定层仍安全终止。
struct ScrollMovingRegion: Sendable, Equatable {
    let cropRect: ScrollPixelRect
    let removedTopPixels: Int
    let removedBottomPixels: Int
    let removedLeftPixels: Int
    let removedRightPixels: Int
    /// Small fixed controls inside the scrolling viewport. Earlier occurrences
    /// can be repaired from the following frame after the document has moved;
    /// the final occurrence is intentionally retained once.
    var fixedOverlayRects: [ScrollPixelRect] = []

    var removedFixedEdges: Bool {
        removedTopPixels + removedBottomPixels + removedLeftPixels + removedRightPixels > 0
    }
}

enum ScrollMovingRegionDetection: Sendable, Equatable {
    case safe(ScrollMovingRegion)
    case unsafe
}

/// 在已知纵向位移后，区分“保持屏幕位置不变”的固定像素与“随正文移动”的像素。
/// 全局 overlap 置信度只能证明大部分像素匹配，不能排除固定标题栏、侧栏或悬浮层。
struct ScrollMovingRegionDetector: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "ScrollCapture"
    )
    struct Configuration: Sendable {
        var maximumSamePositionDifference = 0.025
        var minimumClassificationGap = 0.025
        var maximumShiftedDifference = 0.055
        var maximumFixedSuspectDifference = 0.006
        var minimumFixedSuspectTexture = 0.010
        var maximumEdgeFraction = 0.45
        var minimumRemainingFraction = 0.35
        var maximumProfileSamples = 96
        var baseTileSize = 12
        var maximumTileColumns = 64
        var maximumTileRows = 64
        var tileSamplesPerAxis = 6
        var minimumMovingTiles = 4
        var maximumUnexplainedFixedTiles = 1
        var maximumProfileGap = 2
    }

    let configuration: Configuration

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func detect(
        previous: ScrollPixelBuffer,
        next: ScrollPixelBuffer,
        overlapPixels: Int
    ) throws -> ScrollMovingRegionDetection {
        guard previous.width == next.width,
              previous.height == next.height,
              previous.width >= 16,
              previous.height >= 16,
              overlapPixels > 0,
              overlapPixels < previous.height else {
            throw ScrollCaptureError.incompatibleFrames
        }

        return previous.rgbaData.withUnsafeBytes { previousRaw in
            next.rgbaData.withUnsafeBytes { nextRaw in
                guard let previousBase = previousRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let nextBase = nextRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return .unsafe
                }
                let previousPlane = PixelPlane(
                    base: previousBase,
                    width: previous.width,
                    height: previous.height,
                    bytesPerRow: previous.bytesPerRow
                )
                let nextPlane = PixelPlane(
                    base: nextBase,
                    width: next.width,
                    height: next.height,
                    bytesPerRow: next.bytesPerRow
                )
                return analyze(
                    previous: previousPlane,
                    next: nextPlane,
                    overlapPixels: overlapPixels
                )
            }
        }
    }

    private func analyze(
        previous: PixelPlane,
        next: PixelPlane,
        overlapPixels: Int
    ) -> ScrollMovingRegionDetection {
        let displacement = previous.height - overlapPixels
        let horizontalSamples = sampledPositions(
            in: 0 ..< previous.width,
            maximum: configuration.maximumProfileSamples
        )
        let top = scanLeading(limit: overlapPixels) { y in
            profileIsFixed(
                previous: previous,
                next: next,
                positions: horizontalSamples,
                samePair: { x in ((x, y), (x, y)) },
                shiftedPair: { x in ((x, y + displacement), (x, y)) }
            )
        }
        let bottom = scanLeading(limit: overlapPixels) { offset in
            let y = previous.height - 1 - offset
            return profileIsFixed(
                previous: previous,
                next: next,
                positions: horizontalSamples,
                samePair: { x in ((x, y), (x, y)) },
                shiftedPair: { x in ((x, y), (x, y - displacement)) }
            )
        }

        let maximumVerticalCrop = Int(
            Double(previous.height) * configuration.maximumEdgeFraction
        )
        guard top <= maximumVerticalCrop,
              bottom <= maximumVerticalCrop,
              top + bottom < previous.height else {
            return .unsafe
        }

        let comparableRows = comparableYPositions(
            height: previous.height,
            displacement: displacement,
            overlap: overlapPixels,
            excludingTop: top,
            excludingBottom: bottom
        )
        guard !comparableRows.isEmpty else { return .unsafe }
        let verticalSamples = sampledValues(
            comparableRows,
            maximum: configuration.maximumProfileSamples
        )
        let left = scanLeading(limit: previous.width) { x in
            columnProfileIsFixed(
                x: x,
                yPositions: verticalSamples,
                previous: previous,
                next: next,
                displacement: displacement,
                overlap: overlapPixels
            )
        }
        let right = scanLeading(limit: previous.width) { offset in
            columnProfileIsFixed(
                x: previous.width - 1 - offset,
                yPositions: verticalSamples,
                previous: previous,
                next: next,
                displacement: displacement,
                overlap: overlapPixels
            )
        }

        let maximumHorizontalCrop = Int(
            Double(previous.width) * configuration.maximumEdgeFraction
        )
        guard left <= maximumHorizontalCrop,
              right <= maximumHorizontalCrop,
              left + right < previous.width else {
            return .unsafe
        }

        let cropRect = ScrollPixelRect(
            x: left,
            y: top,
            width: previous.width - left - right,
            height: previous.height - top - bottom
        )
        guard Double(cropRect.width) / Double(previous.width)
                >= configuration.minimumRemainingFraction,
              Double(cropRect.height) / Double(previous.height)
                >= configuration.minimumRemainingFraction,
              cropRect.height > displacement else {
            return .unsafe
        }

        let evidence = blockEvidence(
            previous: previous,
            next: next,
            displacement: displacement,
            overlap: overlapPixels,
            cropRect: cropRect
        )
        let removedFixedEdges = top + bottom + left + right > 0
        let fixedBackdropIsSafe = lowTextureFixedBackdropIsDominant(
            evidence: evidence,
            cropRect: cropRect,
            removedFixedEdges: removedFixedEdges
        )
        let recoverableOverlayRects = recoverableInternalFixedOverlays(
            evidence: evidence,
            displacement: displacement,
            overlapPixels: overlapPixels,
            cropRect: cropRect,
            removedFixedEdges: removedFixedEdges
        )
        let evidenceIsSafe = evidence.moving >= configuration.minimumMovingTiles
            && (evidence.fixed <= configuration.maximumUnexplainedFixedTiles
                || fixedBackdropIsSafe
                || recoverableOverlayRects != nil)
        guard evidenceIsSafe else {
            let clusterCount = connectedFixedRectClusters(evidence.fixedRects).count
            Self.logger.error(
                "stage=moving_region_evidence_rejected moving_tiles=\(evidence.moving, privacy: .public) fixed_tiles=\(evidence.fixed, privacy: .public) fixed_clusters=\(clusterCount, privacy: .public) fixed_area_px=\(evidence.fixedPixelArea, privacy: .public) displacement_px=\(displacement, privacy: .public) overlap_px=\(overlapPixels, privacy: .public) removed_edges=\(removedFixedEdges, privacy: .public) backdrop_safe=\(fixedBackdropIsSafe, privacy: .public)"
            )
            return .unsafe
        }

        if let recoverableOverlayRects, !recoverableOverlayRects.isEmpty {
            Self.logger.notice(
                "stage=moving_region_overlays_recoverable overlay_regions=\(recoverableOverlayRects.count, privacy: .public) displacement_px=\(displacement, privacy: .public) overlap_px=\(overlapPixels, privacy: .public)"
            )
        }

        return .safe(ScrollMovingRegion(
            cropRect: cropRect,
            removedTopPixels: top,
            removedBottomPixels: bottom,
            removedLeftPixels: left,
            removedRightPixels: right,
            fixedOverlayRects: recoverableOverlayRects ?? []
        ))
    }

    private func scanLeading(limit: Int, predicate: (Int) -> Bool) -> Int {
        var lastFixed = -1
        var gap = 0
        for index in 0 ..< limit {
            if predicate(index) {
                lastFixed = index
                gap = 0
            } else if lastFixed >= 0 {
                gap += 1
                if gap > configuration.maximumProfileGap { break }
            } else {
                // 固定带必须从边缘开始；不跨越正文去搜索内部区域。
                break
            }
        }
        return lastFixed + 1
    }

    private func profileIsFixed(
        previous: PixelPlane,
        next: PixelPlane,
        positions: [Int],
        samePair: (Int) -> (PixelPoint, PixelPoint),
        shiftedPair: (Int) -> (PixelPoint, PixelPoint)
    ) -> Bool {
        guard !positions.isEmpty else { return false }
        var informativeSameTotal = 0.0
        var informativeShiftedTotal = 0.0
        var informativeCount = 0
        for position in positions {
            let same = samePair(position)
            let shifted = shiftedPair(position)
            let texture = max(
                localTexture(previous, at: same.0),
                localTexture(next, at: same.1)
            )
            guard texture >= configuration.minimumFixedSuspectTexture else { continue }
            informativeSameTotal += pixelDifference(previous, same.0, next, same.1)
            informativeShiftedTotal += pixelDifference(previous, shifted.0, next, shifted.1)
            informativeCount += 1
        }
        guard informativeCount >= minimumInformativeSampleCount(for: positions.count) else {
            return false
        }
        let same = informativeSameTotal / Double(informativeCount)
        let shifted = informativeShiftedTotal / Double(informativeCount)
        return same <= configuration.maximumSamePositionDifference
            && shifted - same >= configuration.minimumClassificationGap
    }

    private func columnProfileIsFixed(
        x: Int,
        yPositions: [Int],
        previous: PixelPlane,
        next: PixelPlane,
        displacement: Int,
        overlap: Int
    ) -> Bool {
        var informativeSameTotal = 0.0
        var informativeShiftedTotal = 0.0
        var informativeCount = 0
        for y in yPositions {
            let texture = max(
                localTexture(previous, at: (x, y)),
                localTexture(next, at: (x, y))
            )
            guard texture >= configuration.minimumFixedSuspectTexture else { continue }
            let shiftedDifference: Double
            if y < overlap {
                shiftedDifference = pixelDifference(
                    previous,
                    (x, y + displacement),
                    next,
                    (x, y)
                )
            } else if y >= displacement {
                shiftedDifference = pixelDifference(
                    previous,
                    (x, y),
                    next,
                    (x, y - displacement)
                )
            } else {
                continue
            }
            informativeSameTotal += pixelDifference(previous, (x, y), next, (x, y))
            informativeShiftedTotal += shiftedDifference
            informativeCount += 1
        }
        guard informativeCount >= minimumInformativeSampleCount(for: yPositions.count) else {
            return false
        }
        let same = informativeSameTotal / Double(informativeCount)
        let shifted = informativeShiftedTotal / Double(informativeCount)
        return same <= configuration.maximumSamePositionDifference
            && shifted - same >= configuration.minimumClassificationGap
    }

    private func comparableYPositions(
        height: Int,
        displacement: Int,
        overlap: Int,
        excludingTop top: Int,
        excludingBottom bottom: Int
    ) -> [Int] {
        guard top < height - bottom else { return [] }
        return (top ..< (height - bottom)).filter {
            $0 < overlap || $0 >= displacement
        }
    }

    private struct BlockEvidence {
        var moving = 0
        var fixed = 0
        var fixedPixelArea = 0
        var fixedRects: [ScrollPixelRect] = []
    }

    private func blockEvidence(
        previous: PixelPlane,
        next: PixelPlane,
        displacement: Int,
        overlap: Int,
        cropRect: ScrollPixelRect
    ) -> BlockEvidence {
        let tileWidth = adaptiveTileExtent(
            length: cropRect.width,
            maximumTiles: configuration.maximumTileColumns
        )
        var yBreakpoints = Set([cropRect.y, cropRect.maxY])
        if overlap > cropRect.y, overlap < cropRect.maxY {
            yBreakpoints.insert(overlap)
        }
        if displacement > cropRect.y, displacement < cropRect.maxY {
            yBreakpoints.insert(displacement)
        }
        let sortedYBreakpoints = yBreakpoints.sorted()
        var evidence = BlockEvidence()
        for segmentIndex in 0 ..< (sortedYBreakpoints.count - 1) {
            let segmentStart = sortedYBreakpoints[segmentIndex]
            let segmentEnd = sortedYBreakpoints[segmentIndex + 1]
            let tileHeight = adaptiveTileExtent(
                length: segmentEnd - segmentStart,
                maximumTiles: configuration.maximumTileRows
            )
            var y = segmentStart
            while y < segmentEnd {
                let yEnd = min(y + tileHeight, segmentEnd)
                var x = cropRect.x
                while x < cropRect.maxX {
                    let xEnd = min(x + tileWidth, cropRect.maxX)
                    switch classifyBlock(
                        previous: previous,
                        next: next,
                        displacement: displacement,
                        overlap: overlap,
                        xRange: x ..< xEnd,
                        yRange: y ..< yEnd
                    ) {
                    case .moving:
                        evidence.moving += 1
                    case .fixed:
                        evidence.fixed += 1
                        let rect = ScrollPixelRect(
                            x: x,
                            y: y,
                            width: xEnd - x,
                            height: yEnd - y
                        )
                        evidence.fixedRects.append(rect)
                        evidence.fixedPixelArea += rect.width * rect.height
                    case .ambiguous:
                        break
                    }
                    x = xEnd
                }
                y = yEnd
            }
        }
        return evidence
    }

    private enum BlockClassification {
        case moving
        case fixed
        case ambiguous
    }

    private func classifyBlock(
        previous: PixelPlane,
        next: PixelPlane,
        displacement: Int,
        overlap: Int,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> BlockClassification {
        let maximumSamples = max(2, configuration.tileSamplesPerAxis)
        let xPositions = sampledPositions(in: xRange, maximum: maximumSamples)
        let yPositions = sampledPositions(in: yRange, maximum: maximumSamples)
        var informativeSameTotal = 0.0
        var informativeSameCount = 0
        var informativeShiftedTotal = 0.0
        var informativeShiftedCount = 0

        for y in yPositions {
            for x in xPositions {
                let texture = max(
                    localTexture(previous, at: (x, y)),
                    localTexture(next, at: (x, y))
                )
                guard texture >= configuration.minimumFixedSuspectTexture else { continue }
                informativeSameTotal += pixelDifference(previous, (x, y), next, (x, y))
                informativeSameCount += 1
                if y < overlap {
                    informativeShiftedTotal += pixelDifference(
                        previous,
                        (x, y + displacement),
                        next,
                        (x, y)
                    )
                    informativeShiftedCount += 1
                } else if y >= displacement {
                    informativeShiftedTotal += pixelDifference(
                        previous,
                        (x, y),
                        next,
                        (x, y - displacement)
                    )
                    informativeShiftedCount += 1
                }
            }
        }

        let totalSampleCount = xPositions.count * yPositions.count
        let requiredInformativeCount = minimumInformativeSampleCount(for: totalSampleCount)
        guard informativeSameCount >= requiredInformativeCount else { return .ambiguous }
        let same = informativeSameTotal / Double(informativeSameCount)
        if informativeShiftedCount >= requiredInformativeCount {
            let shifted = informativeShiftedTotal / Double(informativeShiftedCount)
            if same <= configuration.maximumSamePositionDifference,
               shifted - same >= configuration.minimumClassificationGap {
                return .fixed
            }
            if shifted <= configuration.maximumShiftedDifference,
               same - shifted >= configuration.minimumClassificationGap * 0.60 {
                return .moving
            }
            return .ambiguous
        }

        // 当单次滚动超过半屏时，中间存在无法做位移对齐的盲区。盲区内有纹理且
        // 两帧保持屏幕位置完全稳定的内容只能视为悬浮层嫌疑，必须安全失败。
        if same <= configuration.maximumFixedSuspectDifference {
            return .fixed
        }
        return .ambiguous
    }

    private func adaptiveTileExtent(length: Int, maximumTiles: Int) -> Int {
        let boundedMaximum = max(1, maximumTiles)
        let required = (length + boundedMaximum - 1) / boundedMaximum
        return max(configuration.baseTileSize, required)
    }

    private func sampledPositions(in range: Range<Int>, maximum: Int) -> [Int] {
        guard !range.isEmpty else { return [] }
        let count = min(max(1, maximum), range.count)
        if count == 1 { return [range.lowerBound] }
        return (0 ..< count).map {
            range.lowerBound + $0 * (range.count - 1) / (count - 1)
        }
    }

    private func sampledValues(_ values: [Int], maximum: Int) -> [Int] {
        guard !values.isEmpty else { return [] }
        let count = min(max(1, maximum), values.count)
        if count == 1 { return [values[0]] }
        return (0 ..< count).map {
            values[$0 * (values.count - 1) / (count - 1)]
        }
    }

    private func pixelDifference(
        _ first: PixelPlane,
        _ firstPoint: PixelPoint,
        _ second: PixelPlane,
        _ secondPoint: PixelPoint
    ) -> Double {
        let firstOffset = firstPoint.y * first.bytesPerRow + firstPoint.x * 4
        let secondOffset = secondPoint.y * second.bytesPerRow + secondPoint.x * 4
        let red = abs(Int(first.base[firstOffset]) - Int(second.base[secondOffset]))
        let green = abs(Int(first.base[firstOffset + 1]) - Int(second.base[secondOffset + 1]))
        let blue = abs(Int(first.base[firstOffset + 2]) - Int(second.base[secondOffset + 2]))
        return Double(red + green + blue) / 765
    }

    private func minimumInformativeSampleCount(for totalCount: Int) -> Int {
        min(totalCount, max(2, Int(ceil(Double(totalCount) * 0.02))))
    }

    /// A smooth fixed backdrop can classify many otherwise empty tiles as
    /// fixed, while sparse scrolling glyphs still provide overwhelming moving
    /// evidence. Accept only that distinctive, large-background shape; a
    /// compact high-texture overlay has far fewer fixed tiles and still fails.
    private func lowTextureFixedBackdropIsDominant(
        evidence: BlockEvidence,
        cropRect: ScrollPixelRect,
        removedFixedEdges: Bool
    ) -> Bool {
        guard !removedFixedEdges else { return false }
        let approximateColumns = min(
            configuration.maximumTileColumns,
            max(1, (cropRect.width + configuration.baseTileSize - 1)
                / configuration.baseTileSize)
        )
        let approximateRows = min(
            configuration.maximumTileRows,
            max(1, (cropRect.height + configuration.baseTileSize - 1)
                / configuration.baseTileSize)
        )
        let approximateTileCount = approximateColumns * approximateRows
        return evidence.fixed >= 8
            && evidence.fixed >= Int(ceil(Double(approximateTileCount) * 0.03))
            && evidence.fixed <= Int(ceil(Double(approximateTileCount) * 0.10))
            && evidence.moving >= evidence.fixed * 5
    }

    /// Compact fixed controls are recoverable when each connected component is
    /// either already inside the discarded overlap or can be sourced from the
    /// following viewport after one accepted displacement. Components are
    /// validated independently so a top control and a bottom control are not
    /// mistaken for one page-sized fixed region.
    private func recoverableInternalFixedOverlays(
        evidence: BlockEvidence,
        displacement: Int,
        overlapPixels: Int,
        cropRect: ScrollPixelRect,
        removedFixedEdges: Bool
    ) -> [ScrollPixelRect]? {
        guard !removedFixedEdges,
              evidence.fixed > configuration.maximumUnexplainedFixedTiles,
              !evidence.fixedRects.isEmpty,
              evidence.moving >= max(
                configuration.minimumMovingTiles,
                evidence.fixed * 2
              ) else {
            return nil
        }

        let cropArea = cropRect.width * cropRect.height
        guard cropArea > 0,
              Double(evidence.fixedPixelArea) / Double(cropArea) <= 0.10 else {
            return nil
        }

        let clusters = connectedFixedRectClusters(evidence.fixedRects)
        guard !clusters.isEmpty, clusters.count <= 8 else { return nil }

        let margin = configuration.baseTileSize
        let recoveryRects = clusters.map { cluster in
            expandedBoundingRect(of: cluster, margin: margin, clippedTo: cropRect)
        }
        let totalRecoveryArea = recoveryRects.reduce(0) {
            $0 + $1.width * $1.height
        }
        let totalAreaFraction = Double(totalRecoveryArea) / Double(cropArea)
        let maximumAreaFraction = recoveryRects.map {
            Double($0.width * $0.height) / Double(cropArea)
        }.max() ?? 0
        let maximumWidthFraction = recoveryRects.map {
            Double($0.width) / Double(cropRect.width)
        }.max() ?? 0
        let maximumHeightFraction = recoveryRects.map {
            Double($0.height) / Double(cropRect.height)
        }.max() ?? 0
        let allRectsCanBeRepaired = recoveryRects.allSatisfy { recoveryRect in
            // Top/middle controls are discarded with the overlap. A bottom
            // control can be repaired from y - displacement in the next frame.
            // The blind zone remains fail-closed.
            recoveryRect.maxY <= overlapPixels || recoveryRect.y >= displacement
        }
        guard totalAreaFraction <= 0.30,
              maximumAreaFraction <= 0.24,
              maximumWidthFraction <= 0.60,
              maximumHeightFraction <= 0.60,
              allRectsCanBeRepaired else {
            Self.logger.error(
                "stage=fixed_overlay_geometry_rejected regions=\(recoveryRects.count, privacy: .public) total_area_fraction=\(totalAreaFraction, privacy: .public) max_area_fraction=\(maximumAreaFraction, privacy: .public) max_width_fraction=\(maximumWidthFraction, privacy: .public) max_height_fraction=\(maximumHeightFraction, privacy: .public) repairable_position=\(allRectsCanBeRepaired, privacy: .public)"
            )
            return nil
        }
        return recoveryRects
    }

    private func connectedFixedRectClusters(
        _ rects: [ScrollPixelRect]
    ) -> [[ScrollPixelRect]] {
        var visited = Array(repeating: false, count: rects.count)
        var clusters: [[ScrollPixelRect]] = []
        let proximity = configuration.baseTileSize

        for start in rects.indices where !visited[start] {
            visited[start] = true
            var pending = [start]
            var cluster: [ScrollPixelRect] = []
            while let current = pending.popLast() {
                cluster.append(rects[current])
                for candidate in rects.indices where !visited[candidate] {
                    guard rectsAreConnected(
                        rects[current],
                        rects[candidate],
                        proximity: proximity
                    ) else { continue }
                    visited[candidate] = true
                    pending.append(candidate)
                }
            }
            clusters.append(cluster)
        }
        return clusters
    }

    private func rectsAreConnected(
        _ first: ScrollPixelRect,
        _ second: ScrollPixelRect,
        proximity: Int
    ) -> Bool {
        first.x <= second.maxX + proximity
            && second.x <= first.maxX + proximity
            && first.y <= second.maxY + proximity
            && second.y <= first.maxY + proximity
    }

    private func expandedBoundingRect(
        of rects: [ScrollPixelRect],
        margin: Int,
        clippedTo cropRect: ScrollPixelRect
    ) -> ScrollPixelRect {
        let minimumX = rects.map(\.x).min() ?? cropRect.x
        let minimumY = rects.map(\.y).min() ?? cropRect.y
        let maximumX = rects.map(\.maxX).max() ?? cropRect.maxX
        let maximumY = rects.map(\.maxY).max() ?? cropRect.maxY
        let x = max(cropRect.x, minimumX - margin)
        let y = max(cropRect.y, minimumY - margin)
        return ScrollPixelRect(
            x: x,
            y: y,
            width: min(cropRect.maxX, maximumX + margin) - x,
            height: min(cropRect.maxY, maximumY + margin) - y
        )
    }

    private func localTexture(_ plane: PixelPlane, at point: PixelPoint) -> Double {
        var strongest = 0.0
        if point.x > 0 {
            strongest = max(
                strongest,
                pixelDifference(plane, point, plane, (point.x - 1, point.y))
            )
        }
        if point.x + 1 < plane.width {
            strongest = max(
                strongest,
                pixelDifference(plane, point, plane, (point.x + 1, point.y))
            )
        }
        if point.y > 0 {
            strongest = max(
                strongest,
                pixelDifference(plane, point, plane, (point.x, point.y - 1))
            )
        }
        if point.y + 1 < plane.height {
            strongest = max(
                strongest,
                pixelDifference(plane, point, plane, (point.x, point.y + 1))
            )
        }
        return strongest
    }
}

private typealias PixelPoint = (x: Int, y: Int)

private struct PixelPlane {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
}
