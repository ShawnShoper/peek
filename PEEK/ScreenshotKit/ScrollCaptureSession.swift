import CoreGraphics
import Foundation

/// 一次滚动截图任务。actor 允许 UI 在采集中并发调用 stop/cancel。
actor ScrollCaptureSession {
    private static let maximumSamePositionRecaptures = 2
    private static let samePositionRecaptureInterval: TimeInterval = 0.25

    private let configuration: ScrollCaptureConfiguration
    private let capturer: ScrollFrameCapturing
    private let scrollDriver: AutomaticScrollDriving

    private(set) var isRunning = false
    private var stopRequested = false
    private var cancelRequested = false

    init(
        configuration: ScrollCaptureConfiguration,
        capturer: ScrollFrameCapturing = QuartzScrollFrameCapturer(),
        scrollDriver: AutomaticScrollDriving = QuartzAutomaticScrollDriver()
    ) {
        self.configuration = configuration
        self.capturer = capturer
        self.scrollDriver = scrollDriver
    }

    func start(
        progress: @escaping ScrollCaptureProgressHandler = { _ in }
    ) async throws -> ScrollCaptureResult {
        guard !isRunning else { throw ScrollCaptureError.alreadyRunning }
        try checkCancellation()
        let configuration = try configuration.validated()
        if case .automatic(let automatic) = configuration.mode {
            try automatic.validate()
            guard scrollDriver.hasAccessibilityPermission else {
                throw ScrollCaptureError.accessibilityPermissionDenied
            }
        }

        isRunning = true
        stopRequested = false
        defer {
            isRunning = false
            stopRequested = false
            cancelRequested = false
        }

        var capturedFrameCount = 0
        var frames: [ScrollPixelBuffer] = []
        var rawPreviousFrame: ScrollPixelBuffer?
        var overlaps: [ScrollOverlapEstimate] = []
        var warnings: [String] = []
        var movingRegion: ScrollMovingRegion?
        var consecutiveDuplicateCount = 0
        var stopReason: ScrollCaptureStopReason?
        var estimatedOutputHeight = 0
        let estimator = ScrollOverlapEstimator(configuration: configuration.overlapSearch)
        let startedAt = ProcessInfo.processInfo.systemUptime

        emit(
            progress,
            stage: .preparing,
            captured: 0,
            accepted: 0,
            maximum: configuration.maximumFrames,
            outputHeight: 0,
            overlap: nil,
            message: L10n.tr("准备滚动截图")
        )

        do {
            while stopReason == nil {
                try checkCancellation()
                if stopRequested {
                    stopReason = .userStopped
                    break
                }
                if let maximumDuration = configuration.maximumDuration,
                   ProcessInfo.processInfo.systemUptime - startedAt >= maximumDuration {
                    stopReason = .durationLimit
                    break
                }

                var recaptureAttempt = 0
                var lastRetryableFailure: ScrollCaptureError?

                captureAtCurrentScrollPosition: while true {
                emit(
                    progress,
                    stage: .capturing,
                    captured: capturedFrameCount,
                    accepted: frames.count,
                    maximum: configuration.maximumFrames,
                    outputHeight: estimatedOutputHeight,
                    overlap: overlaps.last?.overlapPixels,
                    message: captureProgressMessage(
                        hasAcceptedFrame: !frames.isEmpty,
                        recaptureAttempt: recaptureAttempt
                    )
                )

                let image: CGImage
                do {
                    image = try await capturer.capture(rect: configuration.captureRect)
                } catch {
                    // If the supplementary capture itself fails, preserve the
                    // overlap/region diagnosis that caused recovery to start.
                    // Permission and cancellation errors remain authoritative.
                    if let lastRetryableFailure,
                       shouldPreserveRetryDiagnosis(over: error) {
                        throw lastRetryableFailure
                    }
                    throw error
                }
                try checkCancellation()
                capturedFrameCount += 1
                let pixels = try ScrollPixelBuffer(cgImage: image)

                if let previous = frames.last {
                    do {
                        let acceptance = try evaluateCandidate(
                            pixels,
                            previous: previous,
                            rawPrevious: rawPreviousFrame,
                            movingRegion: movingRegion,
                            estimator: estimator,
                            preferredOverlapPixels: overlaps.last?.overlapPixels,
                            // Re-captures are physical attempts for metrics, not
                            // additional output frames. Keep user-facing errors
                            // on the logical next frame (for example, “第 2 帧”).
                            frameNumber: frames.count + 1
                        )

                        switch acceptance {
                        case .duplicate:
                            consecutiveDuplicateCount += 1
                            emit(
                                progress,
                                stage: .duplicateSkipped,
                                captured: capturedFrameCount,
                                accepted: frames.count,
                                maximum: configuration.maximumFrames,
                                outputHeight: estimatedOutputHeight,
                                overlap: previous.height,
                                message: L10n.tr("画面未变化，已跳过重复帧")
                            )

                            if case .automatic(let automatic) = configuration.mode,
                               consecutiveDuplicateCount >= automatic.consecutiveDuplicateLimit {
                                if frames.count == 1 {
                                    // A capture that never moved is not a scrolling
                                    // screenshot. Fail explicitly instead of returning
                                    // the first frame as a misleading successful result.
                                    throw ScrollCaptureError.targetDidNotScroll
                                }
                                stopReason = .endDetected
                            }

                        case .accepted(let accepted):
                            consecutiveDuplicateCount = 0
                            if let replacement = accepted.previousReplacement {
                                frames[frames.count - 1] = replacement
                                estimatedOutputHeight = replacement.height
                            }
                            frames.append(accepted.nextFrame)
                            rawPreviousFrame = pixels
                            movingRegion = accepted.movingRegion
                            overlaps.append(accepted.overlap)
                            if accepted.removedFixedEdges,
                               !warnings.contains(L10n.tr("已自动裁除固定标题栏或侧栏")) {
                                warnings.append(L10n.tr("已自动裁除固定标题栏或侧栏"))
                            }
                            estimatedOutputHeight += accepted.overlap.newContentPixels
                            try enforceOutputLimits(
                                width: frames[0].width,
                                height: estimatedOutputHeight,
                                limits: configuration.stitchLimits
                            )
                        }
                        break captureAtCurrentScrollPosition
                    } catch let failure as CandidateEvaluationFailure {
                        let error = failure.error
                        lastRetryableFailure = error
                        guard recaptureAttempt < Self.maximumSamePositionRecaptures else {
                            throw error
                        }

                        recaptureAttempt += 1
                        emit(
                            progress,
                            stage: .capturing,
                            captured: capturedFrameCount,
                            accepted: frames.count,
                            maximum: configuration.maximumFrames,
                            outputHeight: estimatedOutputHeight,
                            overlap: overlaps.last?.overlapPixels,
                            message: retryProgressMessage(
                                error: error,
                                diagnostics: failure.diagnostics,
                                attempt: recaptureAttempt,
                                maximumAttempts: Self.maximumSamePositionRecaptures
                            )
                        )

                        try await waitBeforeSamePositionRecapture(
                            configuration: configuration,
                            startedAt: startedAt,
                            stopReason: &stopReason
                        )
                        if stopReason != nil { break captureAtCurrentScrollPosition }
                    } catch let error as ScrollCaptureError {
                        guard isSamePositionRetryable(error) else { throw error }
                        lastRetryableFailure = error
                        guard recaptureAttempt < Self.maximumSamePositionRecaptures else {
                            throw error
                        }

                        recaptureAttempt += 1
                        emit(
                            progress,
                            stage: .capturing,
                            captured: capturedFrameCount,
                            accepted: frames.count,
                            maximum: configuration.maximumFrames,
                            outputHeight: estimatedOutputHeight,
                            overlap: overlaps.last?.overlapPixels,
                            message: retryProgressMessage(
                                error: error,
                                diagnostics: nil,
                                attempt: recaptureAttempt,
                                maximumAttempts: Self.maximumSamePositionRecaptures
                            )
                        )

                        try await waitBeforeSamePositionRecapture(
                            configuration: configuration,
                            startedAt: startedAt,
                            stopReason: &stopReason
                        )
                        if stopReason != nil { break captureAtCurrentScrollPosition }
                    }
                } else {
                    frames.append(pixels)
                    rawPreviousFrame = pixels
                    estimatedOutputHeight = pixels.height
                    try enforceOutputLimits(
                        width: pixels.width,
                        height: estimatedOutputHeight,
                        limits: configuration.stitchLimits
                    )
                    break captureAtCurrentScrollPosition
                }
                }

                if frames.count >= configuration.maximumFrames {
                    stopReason = .maximumFrames
                }
                if stopReason != nil { break }
                if stopRequested {
                    stopReason = .userStopped
                    break
                }

                if case .automatic(let automatic) = configuration.mode {
                    emit(
                        progress,
                        stage: .scrolling,
                        captured: capturedFrameCount,
                        accepted: frames.count,
                        maximum: configuration.maximumFrames,
                        outputHeight: estimatedOutputHeight,
                        overlap: overlaps.last?.overlapPixels,
                        message: L10n.tr("正在自动滚动")
                    )
                    try await scrollDriver.scroll(
                        at: configuration.scrollPoint ?? CGPoint(
                            x: configuration.captureRect.midX,
                            y: configuration.captureRect.midY
                        ),
                        amount: automatic.amount
                    )
                }

                try await waitForNextCapture(seconds: configuration.captureInterval)
            }
        } catch let error as ScrollCaptureError {
            guard frames.count >= 2,
                  overlaps.count == frames.count - 1,
                  let partialResult = try? await makePartialResult(
                      frames: frames,
                      overlaps: overlaps,
                      capturedFrameCount: capturedFrameCount,
                      warnings: warnings,
                      limits: configuration.stitchLimits
                  ) else {
                throw error
            }
            throw ScrollCapturePartialFailure(
                underlying: error,
                partialResult: partialResult
            )
        }

        try checkCancellation()
        guard !frames.isEmpty else { throw ScrollCaptureError.emptyCapture }
        let resolvedStopReason = stopReason ?? .userStopped

        emit(
            progress,
            stage: .stitching,
            captured: capturedFrameCount,
            accepted: frames.count,
            maximum: configuration.maximumFrames,
            outputHeight: estimatedOutputHeight,
            overlap: overlaps.last?.overlapPixels,
            message: L10n.tr("正在拼接 %d 帧图像", frames.count)
        )

        let stitchFrames = frames
        let stitchOverlaps = overlaps.map(\.overlapPixels)
        let stitchLimits = configuration.stitchLimits
        let stitched = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try VerticalImageStitcher().stitch(
                pixelBuffers: stitchFrames,
                overlaps: stitchOverlaps,
                limits: stitchLimits
            )
        }.value
        try checkCancellation()
        let image = try stitched.makeCGImage()
        emit(
            progress,
            stage: .finished,
            captured: capturedFrameCount,
            accepted: frames.count,
            maximum: configuration.maximumFrames,
            outputHeight: stitched.height,
            overlap: overlaps.last?.overlapPixels,
            message: L10n.tr("滚动截图已完成")
        )

        return ScrollCaptureResult(
            image: image,
            capturedFrameCount: capturedFrameCount,
            acceptedFrameCount: frames.count,
            stopReason: resolvedStopReason,
            overlaps: overlaps,
            warnings: warnings
        )
    }


    func stop() {
        guard isRunning else { return }
        stopRequested = true
    }

    func cancel() {
        cancelRequested = true
    }

    private func makePartialResult(
        frames: [ScrollPixelBuffer],
        overlaps: [ScrollOverlapEstimate],
        capturedFrameCount: Int,
        warnings: [String],
        limits: ScrollStitchLimits
    ) async throws -> ScrollCaptureResult {
        let stitchOverlaps = overlaps.map(\.overlapPixels)
        let stitched = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try VerticalImageStitcher().stitch(
                pixelBuffers: frames,
                overlaps: stitchOverlaps,
                limits: limits
            )
        }.value
        try checkCancellation()
        let image = try stitched.makeCGImage()
        var partialWarnings = warnings
        partialWarnings.append(L10n.tr("这是失败前已可靠采集的部分结果"))
        return ScrollCaptureResult(
            image: image,
            capturedFrameCount: capturedFrameCount,
            acceptedFrameCount: frames.count,
            stopReason: .failureRecovered,
            overlaps: overlaps,
            warnings: partialWarnings
        )
    }

    private enum CandidateEvaluation {
        case duplicate
        case accepted(CandidateAcceptance)
    }

    private struct CandidateAcceptance {
        let previousReplacement: ScrollPixelBuffer?
        let nextFrame: ScrollPixelBuffer
        let overlap: ScrollOverlapEstimate
        let movingRegion: ScrollMovingRegion?
        let removedFixedEdges: Bool
    }

    private struct CandidateEvaluationFailure: Error {
        let error: ScrollCaptureError
        let diagnostics: ScrollOverlapDiagnostics?
    }

    /// Evaluates one candidate without mutating session state. This is important
    /// for recovery: a rejected animation/transitional frame must not partially
    /// replace the accepted frame or lock in a moving-region crop.
    private func evaluateCandidate(
        _ pixels: ScrollPixelBuffer,
        previous: ScrollPixelBuffer,
        rawPrevious: ScrollPixelBuffer?,
        movingRegion: ScrollMovingRegion?,
        estimator: ScrollOverlapEstimator,
        preferredOverlapPixels: Int?,
        frameNumber: Int
    ) throws -> CandidateEvaluation {
        let comparisonPixels = if let movingRegion {
            try pixels.cropped(to: movingRegion.cropRect)
        } else {
            pixels
        }
        guard previous.width == comparisonPixels.width,
              previous.height == comparisonPixels.height else {
            throw ScrollCaptureError.incompatibleFrames
        }
        if try estimator.isDuplicate(previous, comparisonPixels) {
            return .duplicate
        }

        let analysis = try estimator.analyze(
            previous: previous,
            next: comparisonPixels,
            preferredOverlapPixels: preferredOverlapPixels
        )
        guard var estimate = analysis.estimate else {
            throw CandidateEvaluationFailure(
                error: .unreliableOverlap(
                    frame: frameNumber,
                    diagnostics: analysis.diagnostics
                ),
                diagnostics: analysis.diagnostics
            )
        }

        let fullPrevious = rawPrevious ?? previous
        let originalHeight = fullPrevious.height
        let displacement = previous.height - estimate.overlapPixels
        let originalOverlap = originalHeight - displacement
        let detection = try ScrollMovingRegionDetector().detect(
            previous: fullPrevious,
            next: pixels,
            overlapPixels: originalOverlap
        )
        guard case .safe(let detectedRegion) = detection else {
            if estimate.confidence < 0.55 {
                throw CandidateEvaluationFailure(
                    error: .unreliableOverlap(
                        frame: frameNumber,
                        diagnostics: analysis.diagnostics
                    ),
                    diagnostics: analysis.diagnostics
                )
            }
            throw ScrollCaptureError.unreliableScrollRegion(frame: frameNumber)
        }
        if let movingRegion, movingRegion.cropRect != detectedRegion.cropRect {
            throw ScrollCaptureError.unreliableScrollRegion(frame: frameNumber)
        }

        let effectiveRegion = movingRegion ?? detectedRegion
        if movingRegion == nil, effectiveRegion.removedFixedEdges {
            // A crop can only be established while accepting the second
            // logical frame, when every retained frame can still share one
            // coordinate space. A sticky header that appears later would
            // otherwise leave older full-size frames mixed with newly cropped
            // frames and produce an invalid or misaligned stitch.
            guard frameNumber == 2 else {
                throw ScrollCaptureError.unreliableScrollRegion(frame: frameNumber)
            }
            let croppedPrevious = try previous.cropped(to: effectiveRegion.cropRect)
            let croppedNext = try pixels.cropped(to: effectiveRegion.cropRect)
            let croppedAnalysis = try estimator.analyze(
                previous: croppedPrevious,
                next: croppedNext,
                preferredOverlapPixels: preferredOverlapPixels
            )
            guard let croppedEstimate = croppedAnalysis.estimate,
                  croppedEstimate.confidence >= 0.55 else {
                throw CandidateEvaluationFailure(
                    error: .unreliableScrollRegion(frame: frameNumber),
                    diagnostics: croppedAnalysis.diagnostics
                )
            }
            estimate = croppedEstimate
            return .accepted(CandidateAcceptance(
                previousReplacement: croppedPrevious,
                nextFrame: croppedNext,
                overlap: estimate,
                movingRegion: effectiveRegion,
                removedFixedEdges: true
            ))
        }

        guard estimate.confidence >= 0.55 else {
            throw CandidateEvaluationFailure(
                error: .unreliableOverlap(
                    frame: frameNumber,
                    diagnostics: analysis.diagnostics
                ),
                diagnostics: analysis.diagnostics
            )
        }
        let acceptedPixels = if movingRegion == nil {
            pixels
        } else {
            try pixels.cropped(to: effectiveRegion.cropRect)
        }
        return .accepted(CandidateAcceptance(
            previousReplacement: nil,
            nextFrame: acceptedPixels,
            overlap: estimate,
            movingRegion: movingRegion,
            removedFixedEdges: false
        ))
    }

    private func isSamePositionRetryable(_ error: ScrollCaptureError) -> Bool {
        switch error {
        case .unreliableOverlap, .unreliableScrollRegion:
            return true
        default:
            return false
        }
    }

    private func shouldPreserveRetryDiagnosis(over error: Error) -> Bool {
        guard let captureError = error as? ScrollCaptureError else { return false }
        switch captureError {
        case .captureFailed:
            return true
        default:
            return false
        }
    }

    private func captureProgressMessage(
        hasAcceptedFrame: Bool,
        recaptureAttempt: Int
    ) -> String {
        guard recaptureAttempt > 0 else {
            return hasAcceptedFrame ? L10n.tr("正在捕获下一帧") : L10n.tr("正在捕获首帧")
        }
        return L10n.tr(
            "正在原地补拍（第 %d/%d 次）",
            recaptureAttempt,
            Self.maximumSamePositionRecaptures
        )
    }

    private func retryProgressMessage(
        error: ScrollCaptureError,
        diagnostics: ScrollOverlapDiagnostics?,
        attempt: Int,
        maximumAttempts: Int
    ) -> String {
        let reason: String
        switch error {
        case .unreliableOverlap:
            reason = L10n.tr("重叠区域暂不稳定")
        case .unreliableScrollRegion:
            reason = L10n.tr("滚动内容区域暂不稳定")
        default:
            reason = L10n.tr("画面暂不稳定")
        }
        let diagnosticDetail = diagnostics.flatMap { diagnostics in
            diagnostics.failureReason == nil ? nil : diagnostics.localizedDescription
        }
        let resolvedReason = diagnosticDetail ?? reason
        return L10n.tr(
            "%@，保持当前位置并补拍（第 %d/%d 次）",
            resolvedReason,
            attempt,
            maximumAttempts
        )
    }

    /// Recovery deliberately does not call the scroll driver. The accepted
    /// frame, moving-region state and output height remain untouched until a
    /// supplementary capture passes every fail-closed check.
    private func waitBeforeSamePositionRecapture(
        configuration: ScrollCaptureConfiguration,
        startedAt: TimeInterval,
        stopReason: inout ScrollCaptureStopReason?
    ) async throws {
        try await waitForNextCapture(seconds: Self.samePositionRecaptureInterval)
        try checkCancellation()
        if stopRequested {
            stopReason = .userStopped
        } else if let maximumDuration = configuration.maximumDuration,
                  ProcessInfo.processInfo.systemUptime - startedAt >= maximumDuration {
            stopReason = .durationLimit
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelRequested {
            throw CancellationError()
        }
    }

    private func enforceOutputLimits(
        width: Int,
        height: Int,
        limits: ScrollStitchLimits
    ) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow,
              height <= limits.maximumOutputHeightPixels,
              pixelCount <= limits.maximumOutputPixels else {
            throw ScrollCaptureError.outputTooLarge(width: width, height: height)
        }
    }

    /// 分段等待，让 stop/cancel 最迟约 100ms 生效，而不是等完整采集间隔。
    private func waitForNextCapture(seconds: TimeInterval) async throws {
        var remaining = seconds
        while remaining > 0 {
            try checkCancellation()
            if stopRequested { return }
            let slice = min(remaining, 0.1)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
    }

    private func emit(
        _ progress: ScrollCaptureProgressHandler,
        stage: ScrollCaptureStage,
        captured: Int,
        accepted: Int,
        maximum: Int,
        outputHeight: Int,
        overlap: Int?,
        message: String
    ) {
        progress(
            ScrollCaptureProgress(
                stage: stage,
                capturedFrameCount: captured,
                acceptedFrameCount: accepted,
                maximumFrameCount: maximum,
                estimatedOutputHeightPixels: outputHeight,
                lastOverlapPixels: overlap,
                message: message
            )
        )
    }
}
