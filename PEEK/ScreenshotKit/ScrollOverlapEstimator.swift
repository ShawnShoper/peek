import Foundation

/// 只依赖 RGBA 像素的重叠估计算法，可直接用合成像素数据做单元测试。
struct ScrollOverlapEstimator: Sendable {
    let configuration: ScrollOverlapSearchConfiguration

    init(configuration: ScrollOverlapSearchConfiguration = .init()) {
        self.configuration = configuration
    }

    func normalizedDifferenceAtSamePosition(
        _ first: ScrollPixelBuffer,
        _ second: ScrollPixelBuffer
    ) throws -> Double {
        try requireCompatible(first, second)
        return score(previous: first, next: second, overlap: first.height).difference
    }

    func isDuplicate(_ first: ScrollPixelBuffer, _ second: ScrollPixelBuffer) throws -> Bool {
        try normalizedDifferenceAtSamePosition(first, second)
            <= configuration.duplicateNormalizedDifference
    }

    /// 搜索“上一帧底部”与“下一帧顶部”的最佳重叠高度。
    /// 返回 nil 表示画面纹理不足或差异过大；调用方应按采集模式选择安全失败或固定比例回退。
    func estimate(
        previous: ScrollPixelBuffer,
        next: ScrollPixelBuffer
    ) throws -> ScrollOverlapEstimate? {
        try analyze(previous: previous, next: next).estimate
    }

    /// 搜索“上一帧底部”与“下一帧顶部”的最佳重叠高度，并返回可用于
    /// UI、日志及重试策略的结构化诊断。
    ///
    /// `preferredOverlapPixels` 只会作为额外候选参加相同的纹理、差异及
    /// 歧义校验，不会绕过可靠性阈值或强制产生匹配。
    func analyze(
        previous: ScrollPixelBuffer,
        next: ScrollPixelBuffer,
        preferredOverlapPixels: Int? = nil
    ) throws -> ScrollOverlapAnalysis {
        try requireCompatible(previous, next)
        try configuration.validate()

        let height = previous.height
        guard height >= 3 else {
            return failure(
                reason: .noCandidate,
                candidate: nil,
                evaluatedCandidateCount: 0,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        let minimumOverlap = max(1, Int((Double(height) * configuration.minimumOverlapRatio).rounded()))
        let maximumOverlap = min(
            height - 1,
            Int((Double(height) * configuration.maximumOverlapRatio).rounded())
        )
        guard minimumOverlap <= maximumOverlap else {
            return failure(
                reason: .noCandidate,
                candidate: nil,
                evaluatedCandidateCount: 0,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        let candidateRange = maximumOverlap - minimumOverlap
        let coarseStep = max(
            1,
            (candidateRange + configuration.maximumCoarseCandidates - 1)
                / configuration.maximumCoarseCandidates
        )
        var evaluated: [Int: CandidateScore] = [:]

        var overlap = minimumOverlap
        while overlap <= maximumOverlap {
            evaluated[overlap] = score(previous: previous, next: next, overlap: overlap)
            overlap += coarseStep
        }
        if evaluated[maximumOverlap] == nil {
            evaluated[maximumOverlap] = score(
                previous: previous,
                next: next,
                overlap: maximumOverlap
            )
        }

        // A caller may know the expected displacement from the wheel event.
        // Add that overlap to the search set, but subject it to exactly the same
        // scoring and fail-closed gates as every image-derived candidate.
        if let preferredOverlapPixels,
           (minimumOverlap ... maximumOverlap).contains(preferredOverlapPixels),
           evaluated[preferredOverlapPixels] == nil {
            evaluated[preferredOverlapPixels] = score(
                previous: previous,
                next: next,
                overlap: preferredOverlapPixels
            )
        }

        guard !evaluated.isEmpty else {
            return failure(
                reason: .noCandidate,
                candidate: nil,
                evaluatedCandidateCount: 0,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        // Low-texture coarse positions are not allowed to consume the Top-K
        // refinement budget. Refine multiple distinct candidates pixel by pixel
        // so a tall image cannot lose the true offset merely because sparse
        // sampling made one neighboring coarse position look slightly better.
        let texturedCoarseCandidates = evaluated
            .filter { $0.value.texture >= configuration.minimumTexture }
            .sorted(by: candidateSort)
        let refinementCenters = Array(
            texturedCoarseCandidates.prefix(configuration.refinementCandidateCount)
        )

        if refinementCenters.isEmpty {
            return failure(
                reason: .insufficientTexture,
                candidate: evaluated.min(by: candidateSort),
                evaluatedCandidateCount: evaluated.count,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        for center in refinementCenters {
            let refinementStart = max(minimumOverlap, center.key - coarseStep)
            let refinementEnd = min(maximumOverlap, center.key + coarseStep)
            if refinementStart <= refinementEnd {
                for refinedOverlap in refinementStart ... refinementEnd
                where evaluated[refinedOverlap] == nil {
                    evaluated[refinedOverlap] = score(
                        previous: previous,
                        next: next,
                        overlap: refinedOverlap
                    )
                }
            }
        }

        let texturedCandidates = evaluated
            .filter { $0.value.texture >= configuration.minimumTexture }
        guard let best = texturedCandidates.min(by: candidateSort) else {
            return failure(
                reason: .insufficientTexture,
                candidate: evaluated.min(by: candidateSort),
                evaluatedCandidateCount: evaluated.count,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }
        let bestOverlap = best.key
        let bestScore = best.value

        let exclusionRadius = max(2, coarseStep)
        let secondBestDifference = texturedCandidates
            .filter { abs($0.key - bestOverlap) > exclusionRadius }
            .map(\.value.difference)
            .min()
        let confidence = confidence(
            score: bestScore,
            secondBestDifference: secondBestDifference
        )
        let candidate = (key: bestOverlap, value: bestScore)

        guard bestScore.difference <= configuration.maximumNormalizedDifference else {
            return failure(
                reason: .differenceTooHigh,
                candidate: candidate,
                confidence: confidence,
                evaluatedCandidateCount: evaluated.count,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        if let secondBestDifference,
           max(0, secondBestDifference - bestScore.difference)
            < configuration.minimumDistinctCandidateDifference {
            return failure(
                reason: .ambiguous,
                candidate: candidate,
                confidence: confidence,
                evaluatedCandidateCount: evaluated.count,
                preferredOverlapPixels: preferredOverlapPixels
            )
        }

        let estimate = ScrollOverlapEstimate(
            overlapPixels: bestOverlap,
            newContentPixels: height - bestOverlap,
            normalizedDifference: bestScore.difference,
            confidence: confidence,
            usedFallback: false
        )
        return ScrollOverlapAnalysis(
            estimate: estimate,
            diagnostics: ScrollOverlapDiagnostics(
                failureReason: nil,
                candidateOverlapPixels: bestOverlap,
                normalizedDifference: bestScore.difference,
                texture: bestScore.texture,
                confidence: confidence,
                evaluatedCandidateCount: evaluated.count,
                preferredOverlapPixels: preferredOverlapPixels
            )
        )
    }

    private func failure(
        reason: ScrollOverlapFailureReason,
        candidate: (key: Int, value: CandidateScore)?,
        confidence: Double? = nil,
        evaluatedCandidateCount: Int,
        preferredOverlapPixels: Int?
    ) -> ScrollOverlapAnalysis {
        let resolvedConfidence = candidate.map {
            confidence ?? self.confidence(score: $0.value, secondBestDifference: nil)
        }
        return ScrollOverlapAnalysis(
            estimate: nil,
            diagnostics: ScrollOverlapDiagnostics(
                failureReason: reason,
                candidateOverlapPixels: candidate?.key,
                normalizedDifference: candidate?.value.difference,
                texture: candidate?.value.texture,
                confidence: resolvedConfidence,
                evaluatedCandidateCount: evaluatedCandidateCount,
                preferredOverlapPixels: preferredOverlapPixels
            )
        )
    }

    private func confidence(
        score: CandidateScore,
        secondBestDifference: Double?
    ) -> Double {
        let quality = max(
            0,
            1 - score.difference / configuration.maximumNormalizedDifference
        )
        let textureQuality = min(
            1,
            score.texture / max(configuration.minimumTexture * 8, 0.001)
        )
        let distinctness: Double
        if let secondBestDifference {
            distinctness = min(
                1,
                max(0, secondBestDifference - score.difference)
                    / configuration.maximumNormalizedDifference
            )
        } else {
            distinctness = 1
        }
        return min(1, 0.70 * quality + 0.20 * textureQuality + 0.10 * distinctness)
    }

    private func requireCompatible(
        _ first: ScrollPixelBuffer,
        _ second: ScrollPixelBuffer
    ) throws {
        guard first.width == second.width,
              first.height == second.height,
              first.width >= 2 else {
            throw ScrollCaptureError.incompatibleFrames
        }
    }

    private func score(
        previous: ScrollPixelBuffer,
        next: ScrollPixelBuffer,
        overlap: Int
    ) -> CandidateScore {
        let inset = min(max(1, previous.width / 25), max(1, previous.width / 4))
        let firstX = min(inset, previous.width - 2)
        let lastX = max(firstX, previous.width - inset - 2)
        let availableColumns = max(1, lastX - firstX + 1)
        let columnCount = min(configuration.sampleColumns, availableColumns)
        let rowCount = min(configuration.sampleRows, overlap)
        let previousStartY = previous.height - overlap

        return previous.rgbaData.withUnsafeBytes { previousRawBuffer in
            next.rgbaData.withUnsafeBytes { nextRawBuffer in
                guard let previousBase = previousRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let nextBase = nextRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return CandidateScore(difference: 1, texture: 0)
                }

                var globalDifferences: [Double] = []
                globalDifferences.reserveCapacity(rowCount * columnCount)
                var informativeDifferences: [Double] = []
                informativeDifferences.reserveCapacity(rowCount * columnCount / 4)
                var textureTotal = 0.0
                var sampleCount = 0

                // A smooth CSS gradient can occupy most of a page while the
                // useful scrolling evidence is limited to sparse glyph edges.
                // Treat only real local edges as informative; a per-pixel
                // gradient stays below this floor and therefore cannot dominate
                // either overlap ranking or the texture diagnostic.
                let lowTextureFloor = max(0.012, configuration.minimumTexture * 2.5)
                let informativeTextureThreshold = max(
                    0.025,
                    configuration.minimumTexture * 4
                )

                for rowIndex in 0 ..< rowCount {
                    let relativeY = sampledIndex(rowIndex, count: rowCount, extent: overlap)
                    let previousY = previousStartY + relativeY
                    let nextY = relativeY

                    for columnIndex in 0 ..< columnCount {
                        let relativeX = sampledIndex(
                            columnIndex,
                            count: columnCount,
                            extent: availableColumns
                        )
                        let x = firstX + relativeX
                        let previousOffset = previousY * previous.bytesPerRow + x * 4
                        let nextOffset = nextY * next.bytesPerRow + x * 4
                        let previousLuma = luma(previousBase, offset: previousOffset)
                        let nextLuma = luma(nextBase, offset: nextOffset)
                        let lumaDifference = Double(abs(previousLuma - nextLuma)) / 255

                        let redDifference = abs(
                            Int(previousBase[previousOffset]) - Int(nextBase[nextOffset])
                        )
                        let greenDifference = abs(
                            Int(previousBase[previousOffset + 1]) - Int(nextBase[nextOffset + 1])
                        )
                        let blueDifference = abs(
                            Int(previousBase[previousOffset + 2]) - Int(nextBase[nextOffset + 2])
                        )
                        let colorDifference = Double(
                            redDifference + greenDifference + blueDifference
                        ) / 765

                        let previousTexture = localLumaTexture(
                            previousBase,
                            x: x,
                            y: previousY,
                            width: previous.width,
                            height: previous.height,
                            bytesPerRow: previous.bytesPerRow
                        )
                        let nextTexture = localLumaTexture(
                            nextBase,
                            x: x,
                            y: nextY,
                            width: next.width,
                            height: next.height,
                            bytesPerRow: next.bytesPerRow
                        )
                        let structureDifference = localGradientDifference(
                            previousBase,
                            previousX: x,
                            previousY: previousY,
                            previousWidth: previous.width,
                            previousHeight: previous.height,
                            previousBytesPerRow: previous.bytesPerRow,
                            nextBase,
                            nextX: x,
                            nextY: nextY,
                            nextWidth: next.width,
                            nextHeight: next.height,
                            nextBytesPerRow: next.bytesPerRow
                        )
                        let difference = 0.60 * lumaDifference
                            + 0.25 * colorDifference
                            + 0.15 * structureDifference
                        let localTexture = max(previousTexture, nextTexture)

                        globalDifferences.append(difference)
                        if localTexture >= informativeTextureThreshold {
                            informativeDifferences.append(difference)
                        }
                        textureTotal += max(0, localTexture - lowTextureFloor)
                        sampleCount += 1
                    }
                }

                guard sampleCount > 0 else {
                    return CandidateScore(difference: 1, texture: 0)
                }
                let globalDifference = mean(globalDifferences)
                let difference: Double
                if informativeDifferences.isEmpty {
                    difference = globalDifference
                } else {
                    // Trim a small number of outliers (caret blink, antialiasing
                    // noise, tiny animations), but retain the majority of real
                    // edge evidence. The global term intentionally remains small
                    // so a large, low-texture fixed background cannot win over
                    // aligned scrolling text.
                    let informativeDifference = trimmedMean(
                        informativeDifferences,
                        trimFraction: 0.10
                    )
                    difference = 0.92 * informativeDifference
                        + 0.08 * globalDifference
                }
                return CandidateScore(
                    difference: difference,
                    texture: textureTotal / Double(sampleCount)
                )
            }
        }
    }
}

private func candidateSort(
    _ lhs: Dictionary<Int, CandidateScore>.Element,
    _ rhs: Dictionary<Int, CandidateScore>.Element
) -> Bool {
    if lhs.value.difference != rhs.value.difference {
        return lhs.value.difference < rhs.value.difference
    }
    return lhs.key < rhs.key
}

private struct CandidateScore {
    let difference: Double
    let texture: Double
}

private func sampledIndex(_ index: Int, count: Int, extent: Int) -> Int {
    guard count > 1, extent > 1 else { return 0 }
    return index * (extent - 1) / (count - 1)
}

private func luma(_ bytes: UnsafePointer<UInt8>, offset: Int) -> Int {
    // BT.601 的整数近似；alpha 不参与页面内容匹配。
    (77 * Int(bytes[offset])
        + 150 * Int(bytes[offset + 1])
        + 29 * Int(bytes[offset + 2])) >> 8
}

private func localLumaTexture(
    _ bytes: UnsafePointer<UInt8>,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    bytesPerRow: Int
) -> Double {
    let centerOffset = y * bytesPerRow + x * 4
    let center = luma(bytes, offset: centerOffset)
    var maximumGradient = 0

    if x > 0 {
        maximumGradient = max(
            maximumGradient,
            abs(center - luma(bytes, offset: centerOffset - 4))
        )
    }
    if x + 1 < width {
        maximumGradient = max(
            maximumGradient,
            abs(center - luma(bytes, offset: centerOffset + 4))
        )
    }
    if y > 0 {
        maximumGradient = max(
            maximumGradient,
            abs(center - luma(bytes, offset: centerOffset - bytesPerRow))
        )
    }
    if y + 1 < height {
        maximumGradient = max(
            maximumGradient,
            abs(center - luma(bytes, offset: centerOffset + bytesPerRow))
        )
    }
    return Double(maximumGradient) / 255
}

private func localGradientDifference(
    _ previous: UnsafePointer<UInt8>,
    previousX: Int,
    previousY: Int,
    previousWidth: Int,
    previousHeight: Int,
    previousBytesPerRow: Int,
    _ next: UnsafePointer<UInt8>,
    nextX: Int,
    nextY: Int,
    nextWidth: Int,
    nextHeight: Int,
    nextBytesPerRow: Int
) -> Double {
    let previousOffset = previousY * previousBytesPerRow + previousX * 4
    let nextOffset = nextY * nextBytesPerRow + nextX * 4
    let previousCenter = luma(previous, offset: previousOffset)
    let nextCenter = luma(next, offset: nextOffset)
    var total = 0.0
    var count = 0

    func accumulate(previousNeighborOffset: Int, nextNeighborOffset: Int) {
        let previousGradient = luma(previous, offset: previousNeighborOffset) - previousCenter
        let nextGradient = luma(next, offset: nextNeighborOffset) - nextCenter
        total += Double(min(255, abs(previousGradient - nextGradient))) / 255
        count += 1
    }

    if previousX > 0, nextX > 0 {
        accumulate(previousNeighborOffset: previousOffset - 4, nextNeighborOffset: nextOffset - 4)
    }
    if previousX + 1 < previousWidth, nextX + 1 < nextWidth {
        accumulate(previousNeighborOffset: previousOffset + 4, nextNeighborOffset: nextOffset + 4)
    }
    if previousY > 0, nextY > 0 {
        accumulate(
            previousNeighborOffset: previousOffset - previousBytesPerRow,
            nextNeighborOffset: nextOffset - nextBytesPerRow
        )
    }
    if previousY + 1 < previousHeight, nextY + 1 < nextHeight {
        accumulate(
            previousNeighborOffset: previousOffset + previousBytesPerRow,
            nextNeighborOffset: nextOffset + nextBytesPerRow
        )
    }
    return count > 0 ? total / Double(count) : 0
}

private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 1 }
    return values.reduce(0, +) / Double(values.count)
}

private func trimmedMean(_ values: [Double], trimFraction: Double) -> Double {
    guard values.count >= 10 else { return mean(values) }
    let sorted = values.sorted()
    let trimCount = min(
        Int(Double(sorted.count) * trimFraction),
        (sorted.count - 1) / 2
    )
    return mean(Array(sorted[trimCount ..< (sorted.count - trimCount)]))
}
