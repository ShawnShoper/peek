import CoreGraphics
import Foundation
import OSLog

/// 一次滚动截图任务。actor 允许 UI 在采集中并发调用 stop/cancel。
actor ScrollCaptureSession {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "ScrollCapture"
    )
    /// A wheel event is one transaction: after it has been delivered, keep
    /// sampling the same viewport until it either aligns or becomes stable.
    /// Never send a second wheel event while the first transaction is still
    /// unresolved, because those movements accumulate and can skip content.
    private static let maximumSamePositionRecaptures = 4
    /// A candidate can be temporarily impossible to align while a page is
    /// animating or rendering. Do not mistake the first such candidate for the
    /// document end. Send a small, bounded number of progressively shorter
    /// wheel events while every new sample is still compared with the last
    /// accepted frame; rejected pixels never enter the output.
    /// A changed-but-unproven tail may be a smooth-scroll transition or the
    /// last few sparse rows of a document. Give it one extra bounded sample so
    /// repeated geometric displacement can prove that the viewport has settled.
    private static let maximumTailSettleRecaptures = 3
    private static let samePositionRecaptureInterval: TimeInterval = 0.25
    private static let finalCaptureSettleInterval: TimeInterval = 0.20

    private let configuration: ScrollCaptureConfiguration
    private let capturer: ScrollFrameCapturing
    private let scrollDriver: AutomaticScrollDriving

    private(set) var isRunning = false
    private var stopRequested = false
    private var cancelRequested = false
    /// `Task.detached` does not inherit parent cancellation. Keep the active
    /// handle so both parent-task cancellation and the UI Cancel action can
    /// stop CPU-heavy row copying promptly.
    private var activeStitchTask: Task<ScrollPixelBuffer, Error>?

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
        defer {
            isRunning = false
            stopRequested = false
            cancelRequested = false
        }

        var capturedFrameCount = 0
        var frames: [ScrollPixelBuffer] = []
        var fixedOverlayRectsByFrame: [[ScrollPixelRect]] = []
        var rawPreviousFrame: ScrollPixelBuffer?
        var overlaps: [ScrollOverlapEstimate] = []
        var warnings: [String] = []
        var movingRegion: ScrollMovingRegion?
        // A short movement is only evidence of the document tail after this
        // session has already observed a materially larger, accepted movement.
        // Some apps consume every wheel event as only a few rows, so treating
        // the first short step as "near the bottom" stops them after one event.
        var lastAcceptedDisplacement: Int?
        var consecutiveDuplicateCount = 0
        var stopReason: ScrollCaptureStopReason?
        var estimatedOutputHeight = 0
        let estimator = ScrollOverlapEstimator(configuration: configuration.overlapSearch)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let durationDeadline = configuration.maximumDuration.map { startedAt + $0 }
        let isAutomaticMode: Bool
        if case .automatic = configuration.mode {
            isAutomaticMode = true
        } else {
            isAutomaticMode = false
        }

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
                // `stop` means “stop scrolling and stitch what is currently on
                // screen”, so the request starts one final capture instead of
                // terminating before the viewport is sampled. The short settle
                // delay lets the last wheel/manual movement finish rendering.
                let isFinalCapture = stopRequested
                if isFinalCapture {
                    try await waitForNextCapture(
                        seconds: Self.finalCaptureSettleInterval,
                        stopsEarly: false
                    )
                }

                var recaptureAttempt = 0
                var recaptureMaximumAttempts = Self.maximumSamePositionRecaptures
                var lastRetryableFailure: ScrollCaptureError?
                var pendingTailFrame: ScrollPixelBuffer?
                var pendingTailDisplacement: Int?

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
                        recaptureAttempt: recaptureAttempt,
                        maximumAttempts: recaptureMaximumAttempts
                    )
                )

                let image: CGImage
                do {
                    image = try await capturer.capture(rect: configuration.captureRect)
                } catch {
                    // A real backend failure must remain visible in automatic
                    // mode. Motion/overlap uncertainty is handled by the
                    // bounded reduced-step path before another capture begins.
                    if !isAutomaticMode,
                       let lastRetryableFailure,
                       shouldPreserveRetryDiagnosis(over: error) {
                        throw lastRetryableFailure
                    }
                    throw error
                }
                try checkCancellation()
                capturedFrameCount += 1
                try enforceOutputLimits(
                    width: image.width,
                    height: image.height,
                    limits: configuration.stitchLimits
                )
                let normalizedFrameBytes = rgbaByteCount(
                    width: image.width,
                    height: image.height
                )
                let firstFrameStitchPeak = saturatingSum([
                    normalizedFrameBytes,
                    normalizedFrameBytes,
                    normalizedFrameBytes
                ])
                if frames.isEmpty,
                   normalizedFrameBytes > configuration.memoryBudget.maximumRetainedFrameBytes
                    || firstFrameStitchPeak
                        > configuration.memoryBudget.maximumEstimatedPeakBytes {
                    // Do not normalize and then allocate another full output
                    // for a single frame that cannot fit the declared budget.
                    // The original capture is already the exact desired result.
                    return memoryLimitedSingleFrameResult(
                        image: image,
                        capturedFrameCount: capturedFrameCount,
                        normalizedFrameBytes: normalizedFrameBytes,
                        estimatedPeakBytes: firstFrameStitchPeak,
                        budget: configuration.memoryBudget,
                        maximumFrames: configuration.maximumFrames,
                        progress: progress
                    )
                }
                let pixels = try ScrollPixelBuffer(cgImage: image)
                let pendingComparisonPixels = if let movingRegion {
                    try pixels.cropped(to: movingRegion.cropRect)
                } else {
                    pixels
                }

                // A captured CGImage and its RGBA conversion coexist during
                // evaluation. Stop before expensive overlap analysis if this
                // transient working set would exceed the attempt budget. The
                // already accepted prefix remains independently stitchable.
                if !frames.isEmpty,
                   estimatedEvaluationPeakBytes(
                       frames: frames,
                       rawPreviousFrame: rawPreviousFrame,
                       candidate: pixels,
                       comparisonCandidate: pendingComparisonPixels,
                       pendingTailFrame: pendingTailFrame,
                       outputHeight: estimatedOutputHeight
                   ) > configuration.memoryBudget.maximumEstimatedPeakBytes {
                    markMemoryLimit(
                        acceptedFrameCount: frames.count,
                        frames: frames,
                        rawPreviousFrame: rawPreviousFrame,
                        outputHeight: estimatedOutputHeight,
                        budget: configuration.memoryBudget,
                        warnings: &warnings,
                        stopReason: &stopReason
                    )
                    break captureAtCurrentScrollPosition
                }

                if let previous = frames.last {
                    do {
                        let isLowImpactRecapture: Bool
                        if let pendingTailFrame {
                            if pendingTailFrame.rgbaData == pendingComparisonPixels.rgbaData {
                                isLowImpactRecapture = true
                            } else {
                                // Real pages rarely become byte-for-byte stable:
                                // carets, progress indicators and clocks can keep
                                // changing while the scroll offset is already
                                // settled. A bounded low-impact comparison is
                                // sufficient to unlock the exhaustive overlap
                                // check; moving-region validation still decides
                                // whether any pixels may enter the stitched image.
                                isLowImpactRecapture = (
                                    try? estimator.normalizedDifferenceAtSamePosition(
                                        pendingTailFrame,
                                        pendingComparisonPixels
                                    )
                                ).map {
                                    $0 <= estimator.configuration.duplicateNormalizedDifference
                                } ?? false
                            }
                        } else {
                            isLowImpactRecapture = false
                        }
                        let acceptance: CandidateEvaluation
                        if let rawPreviousFrame,
                           rawPreviousFrame.rgbaData == pixels.rgbaData {
                            // The full captured viewport is byte-for-byte the
                            // same as the last accepted viewport. A crop or
                            // moving-region recovery must never reinterpret it
                            // as new document content.
                            acceptance = .duplicate
                        } else {
                            acceptance = try evaluateCandidate(
                                pixels,
                                previous: previous,
                                rawPrevious: rawPreviousFrame,
                                movingRegion: movingRegion,
                                estimator: estimator,
                                preferredOverlapPixels: overlaps.last?.overlapPixels,
                                // Re-captures are physical attempts for metrics, not
                                // additional output frames. Keep user-facing errors
                                // on the logical next frame (for example, “第 2 帧”).
                                frameNumber: frames.count + 1,
                                automaticTailReferenceDisplacement: isAutomaticMode
                                    ? lastAcceptedDisplacement
                                    : nil,
                                pendingTailDisplacement: pendingTailDisplacement,
                                hasRetriedAtSamePosition: recaptureAttempt > 0,
                                allowStableStationaryRecovery: isLowImpactRecapture,
                                allowAutomaticRegionRecovery: isAutomaticMode
                            )
                        }

                        switch acceptance {
                        case .duplicate, .stationaryNoise:
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

                            if case .automatic(let automatic) = configuration.mode {
                                let position = await scrollDriver.currentPosition(
                                    at: configuration.scrollPoint ?? CGPoint(
                                        x: configuration.captureRect.midX,
                                        y: configuration.captureRect.midY
                                    )
                                )
                                let hasStationaryNoiseEvidence: Bool
                                if case .stationaryNoise = acceptance {
                                    hasStationaryNoiseEvidence = true
                                } else {
                                    hasStationaryNoiseEvidence = false
                                }
                                let requiredNoMovementTransactions: Int
                                if position == nil {
                                    // Exact duplicates need three independent
                                    // wheel transactions (normal, 1/2, 1/4).
                                    // Stationary-noise classification already
                                    // includes bounded same-position samples,
                                    // so the configured limit remains enough.
                                    requiredNoMovementTransactions = hasStationaryNoiseEvidence
                                        ? automatic.consecutiveDuplicateLimit
                                        : max(3, automatic.consecutiveDuplicateLimit)
                                } else {
                                    requiredNoMovementTransactions = max(
                                        2,
                                        automatic.consecutiveDuplicateLimit
                                    )
                                }
                                if position?.isAtEnd == true
                                    || consecutiveDuplicateCount >= requiredNoMovementTransactions {
                                    // A semantic scrollbar at its maximum is
                                    // authoritative. Without one, require three
                                    // independently delivered wheel transactions
                                    // (normal, 1/2 and 1/4) to show no movement.
                                    stopReason = .endDetected
                                }
                            }

                        case .accepted(let accepted):
                            consecutiveDuplicateCount = 0
                            var proposedFrames = frames
                            var proposedOverlayRects = fixedOverlayRectsByFrame
                            var proposedOutputHeight = estimatedOutputHeight
                            if let replacement = accepted.previousReplacement {
                                proposedFrames[proposedFrames.count - 1] = replacement
                                proposedOutputHeight = replacement.height
                            }
                            if !accepted.fixedOverlayRects.isEmpty,
                               !proposedOverlayRects.isEmpty {
                                proposedOverlayRects[proposedOverlayRects.count - 1] =
                                    mergedOverlayRects(
                                        proposedOverlayRects[proposedOverlayRects.count - 1],
                                        accepted.fixedOverlayRects
                                    )
                            }
                            proposedFrames.append(accepted.nextFrame)
                            proposedOverlayRects.append(accepted.fixedOverlayRects)
                            proposedOutputHeight += accepted.overlap.newContentPixels
                            let proposedRawPreviousFrame = uncroppedReferenceIfNeeded(
                                pixels,
                                movingRegion: accepted.movingRegion
                            )
                            try enforceOutputLimits(
                                width: proposedFrames[0].width,
                                height: proposedOutputHeight,
                                limits: configuration.stitchLimits
                            )
                            if exceedsMemoryBudget(
                                frames: proposedFrames,
                                rawPreviousFrame: proposedRawPreviousFrame,
                                outputHeight: proposedOutputHeight,
                                budget: configuration.memoryBudget
                            ) {
                                markMemoryLimit(
                                    acceptedFrameCount: frames.count,
                                    frames: frames,
                                    rawPreviousFrame: rawPreviousFrame,
                                    outputHeight: estimatedOutputHeight,
                                    budget: configuration.memoryBudget,
                                    warnings: &warnings,
                                    stopReason: &stopReason
                                )
                                break captureAtCurrentScrollPosition
                            }

                            frames = proposedFrames
                            fixedOverlayRectsByFrame = proposedOverlayRects
                            rawPreviousFrame = proposedRawPreviousFrame
                            movingRegion = accepted.movingRegion
                            overlaps.append(accepted.overlap)
                            if accepted.removedFixedEdges,
                               !warnings.contains(L10n.tr("已自动裁除固定标题栏或侧栏")) {
                                warnings.append(L10n.tr("已自动裁除固定标题栏或侧栏"))
                            }
                            estimatedOutputHeight = proposedOutputHeight
                            lastAcceptedDisplacement = accepted.overlap.newContentPixels
                            Self.logger.notice(
                                "stage=frame_accepted captured=\(capturedFrameCount, privacy: .public) accepted=\(frames.count, privacy: .public) displacement_px=\(accepted.overlap.newContentPixels, privacy: .public) overlap_px=\(accepted.overlap.overlapPixels, privacy: .public)"
                            )
                            if isAutomaticMode {
                                let position = await scrollDriver.currentPosition(
                                    at: configuration.scrollPoint ?? CGPoint(
                                        x: configuration.captureRect.midX,
                                        y: configuration.captureRect.midY
                                    )
                                )
                                if position?.isAtEnd == true {
                                    // The accepted frame is already the final
                                    // viewport. Stop only after its pixels have
                                    // entered the retained frame list.
                                    stopReason = .endDetected
                                }
                            }
                        }
                        break captureAtCurrentScrollPosition
                    } catch let failure as CandidateEvaluationFailure {
                        let error = failure.error
                        lastRetryableFailure = error
                        if failure.recoveryKind == .pendingTail
                            || failure.recoveryKind == .pendingStationaryCheck
                            || failure.recoveryKind == .pendingRegionValidation {
                            pendingTailFrame = pendingComparisonPixels
                            pendingTailDisplacement = failure.candidateDisplacement
                        } else if failure.recoveryKind == .stableTailRejected {
                            // The same settled pixels have already failed the
                            // exhaustive tail analysis. Repeating that expensive
                            // deterministic work cannot add evidence, but an
                            // automatic session can still send a shorter wheel
                            // event and compare the later viewport with the last
                            // accepted frame.
                            stopAfterUnresolvedAutomaticTransaction(
                                error: error,
                                capturedFrameCount: capturedFrameCount,
                                acceptedFrameCount: frames.count,
                                stopReason: &stopReason
                            )
                            if stopReason != nil {
                                break captureAtCurrentScrollPosition
                            }
                            throw error
                        }
                        let maximumAttempts: Int
                        switch failure.recoveryKind {
                        case .pendingTail:
                            maximumAttempts = Self.maximumTailSettleRecaptures
                        case .pendingStationaryCheck:
                            // One supplementary sample is enough to distinguish
                            // a stable sparse tail from a local animation. If no
                            // displacement can be proven, resume bounded wheel
                            // delivery instead of locking the session in place.
                            maximumAttempts = 1
                        case .pendingRegionValidation:
                            // One follow-up frame at the exact same scroll
                            // position proves the displacement is geometric,
                            // not a transient floating control animation.
                            maximumAttempts = 2
                        case .ordinary, .stableTailRejected:
                            maximumAttempts = Self.maximumSamePositionRecaptures
                        }
                        recaptureMaximumAttempts = maximumAttempts
                        guard recaptureAttempt < maximumAttempts else {
                            stopAfterUnresolvedAutomaticTransaction(
                                error: error,
                                capturedFrameCount: capturedFrameCount,
                                acceptedFrameCount: frames.count,
                                stopReason: &stopReason
                            )
                            if stopReason != nil {
                                break captureAtCurrentScrollPosition
                            }
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
                                maximumAttempts: maximumAttempts
                            )
                        )

                        let didWaitForRecapture = try await waitBeforeSamePositionRecapture(
                            durationDeadline: durationDeadline
                        )
                        if !didWaitForRecapture {
                            stopReason = .durationLimit
                            break captureAtCurrentScrollPosition
                        }
                    } catch let error as ScrollCaptureError {
                        guard isSamePositionRetryable(error) else { throw error }
                        lastRetryableFailure = error
                        guard recaptureAttempt < Self.maximumSamePositionRecaptures else {
                            stopAfterUnresolvedAutomaticTransaction(
                                error: error,
                                capturedFrameCount: capturedFrameCount,
                                acceptedFrameCount: frames.count,
                                stopReason: &stopReason
                            )
                            if stopReason != nil {
                                break captureAtCurrentScrollPosition
                            }
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

                        let didWaitForRecapture = try await waitBeforeSamePositionRecapture(
                            durationDeadline: durationDeadline
                        )
                        if !didWaitForRecapture {
                            stopReason = .durationLimit
                            break captureAtCurrentScrollPosition
                        }
                    }
                } else {
                    frames.append(pixels)
                    fixedOverlayRectsByFrame.append([])
                    // The first accepted frame is already the full reference.
                    // Keeping a second struct pointing at the same RGBA payload
                    // adds no validation value and obscures memory accounting.
                    rawPreviousFrame = nil
                    estimatedOutputHeight = pixels.height
                    try enforceOutputLimits(
                        width: pixels.width,
                        height: estimatedOutputHeight,
                        limits: configuration.stitchLimits
                    )
                    if exceedsMemoryBudget(
                        frames: frames,
                        rawPreviousFrame: rawPreviousFrame,
                        outputHeight: estimatedOutputHeight,
                        budget: configuration.memoryBudget
                    ) {
                        // The preflight above normally makes this unreachable,
                        // but keep the restricted single-frame path authoritative
                        // if a future pixel format changes actual Data sizing.
                        return memoryLimitedSingleFrameResult(
                            image: image,
                            capturedFrameCount: capturedFrameCount,
                            normalizedFrameBytes: pixels.rgbaData.count,
                            estimatedPeakBytes: estimatedStitchPeakBytes(
                                frames: frames,
                                rawPreviousFrame: rawPreviousFrame,
                                outputHeight: estimatedOutputHeight
                            ),
                            budget: configuration.memoryBudget,
                            maximumFrames: configuration.maximumFrames,
                            progress: progress
                        )
                    }
                    break captureAtCurrentScrollPosition
                }
                }

                if frames.count >= configuration.maximumFrames {
                    stopReason = .maximumFrames
                }
                if stopReason != nil { break }
                if stopRequested {
                    if isFinalCapture {
                        stopReason = .userStopped
                        break
                    }
                    // The request arrived while this capture/evaluation was in
                    // flight. Do not scroll again; loop once more so the final
                    // capture starts after the request was observed.
                    continue
                }
                if let maximumDuration = configuration.maximumDuration,
                   ProcessInfo.processInfo.systemUptime - startedAt >= maximumDuration {
                    // Duration is checked after the current viewport has been
                    // captured. Checking before capture silently lost content
                    // that had already scrolled during the final wait interval.
                    stopReason = .durationLimit
                    break
                }

                if case .automatic(let automatic) = configuration.mode {
                    let scrollPoint = configuration.scrollPoint ?? CGPoint(
                        x: configuration.captureRect.midX,
                        y: configuration.captureRect.midY
                    )
                    let position = await scrollDriver.currentPosition(at: scrollPoint)
                    let amount = AdaptiveScrollStepPlanner.amount(
                        configuredAmount: automatic.amount,
                        viewportHeight: configuration.captureRect.height,
                        position: position,
                        consecutiveNoMovementTransactions: consecutiveDuplicateCount
                    )
                    if amount == 0 {
                        stopReason = .endDetected
                        break
                    }
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
                    let positionDescription = position.map {
                        String(format: "%.5f", $0.progress)
                    } ?? "unavailable"
                    Self.logger.notice(
                        "stage=wheel_request captured=\(capturedFrameCount, privacy: .public) accepted=\(frames.count, privacy: .public) amount=\(amount, privacy: .public) semantic_progress=\(positionDescription, privacy: .public) no_movement_transactions=\(consecutiveDuplicateCount, privacy: .public)"
                    )
                    try await scrollDriver.scroll(
                        at: scrollPoint,
                        amount: amount
                    )
                }

                // Once an automatic wheel event has been sent, let its normal
                // render interval finish even if Stop arrives. Stop prevents the
                // *next* wheel event; interrupting this settle window could save
                // an intermediate smooth-scroll frame and lose the real tail.
                let mayInterruptWait: Bool
                if case .automatic = configuration.mode {
                    mayInterruptWait = false
                } else {
                    mayInterruptWait = true
                }
                try await waitForNextCapture(
                    seconds: configuration.captureInterval,
                    stopsEarly: mayInterruptWait
                )
            }
        } catch let error as ScrollCaptureError {
            // Driver and alignment failures are never evidence of the bottom.
            // Only an accepted AX maximum or bounded visual no-movement
            // transactions may produce `.endDetected`.
            guard frames.count >= 2,
                  overlaps.count == frames.count - 1,
                  let partialResult = try? await makePartialResult(
                      frames: frames,
                      overlaps: overlaps,
                      fixedOverlayRectsByFrame: fixedOverlayRectsByFrame,
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
        let stitchOverlayRects = fixedOverlayRectsByFrame
        let stitchLimits = configuration.stitchLimits
        let stitched = try await stitchFramesOffActor(
            frames: stitchFrames,
            overlaps: stitchOverlaps,
            fixedOverlayRectsByFrame: stitchOverlayRects,
            limits: stitchLimits
        )
        try checkCancellation()
        let image = try stitched.makeCGImage()
        let stopReasonDescription = String(describing: resolvedStopReason)
        Self.logger.notice(
            "stage=finished captured=\(capturedFrameCount, privacy: .public) accepted=\(frames.count, privacy: .public) output_height_px=\(stitched.height, privacy: .public) stop_reason=\(stopReasonDescription, privacy: .public)"
        )
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
        // The HUD can become interactive just before the asynchronous start
        // call enters this actor. Preserve that early request so a very fast
        // Stop click captures the current viewport instead of being discarded.
        stopRequested = true
    }

    func cancel() {
        cancelRequested = true
        activeStitchTask?.cancel()
    }

    private func makePartialResult(
        frames: [ScrollPixelBuffer],
        overlaps: [ScrollOverlapEstimate],
        fixedOverlayRectsByFrame: [[ScrollPixelRect]],
        capturedFrameCount: Int,
        warnings: [String],
        limits: ScrollStitchLimits
    ) async throws -> ScrollCaptureResult {
        let stitchOverlaps = overlaps.map(\.overlapPixels)
        let stitched = try await stitchFramesOffActor(
            frames: frames,
            overlaps: stitchOverlaps,
            fixedOverlayRectsByFrame: fixedOverlayRectsByFrame,
            limits: limits
        )
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
        /// The viewport contains a small local change, but neither the normal
        /// nor exhaustive overlap search can prove that content moved. Ignore
        /// those pixels and let the bounded duplicate policy decide whether to
        /// send another wheel event or finish at the document end.
        case stationaryNoise
        case accepted(CandidateAcceptance)
    }

    private struct CandidateAcceptance {
        let previousReplacement: ScrollPixelBuffer?
        let nextFrame: ScrollPixelBuffer
        let overlap: ScrollOverlapEstimate
        let movingRegion: ScrollMovingRegion?
        let removedFixedEdges: Bool
        let fixedOverlayRects: [ScrollPixelRect]
    }

    private struct CandidateEvaluationFailure: Error {
        enum RecoveryKind: Sendable, Equatable {
            case ordinary
            case pendingTail
            case pendingStationaryCheck
            case pendingRegionValidation
            case stableTailRejected
        }

        let error: ScrollCaptureError
        let diagnostics: ScrollOverlapDiagnostics?
        let recoveryKind: RecoveryKind
        let candidateDisplacement: Int?

        init(
            error: ScrollCaptureError,
            diagnostics: ScrollOverlapDiagnostics?,
            recoveryKind: RecoveryKind = .ordinary,
            candidateDisplacement: Int? = nil
        ) {
            self.error = error
            self.diagnostics = diagnostics
            self.recoveryKind = recoveryKind
            self.candidateDisplacement = candidateDisplacement
        }
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
        frameNumber: Int,
        automaticTailReferenceDisplacement: Int?,
        pendingTailDisplacement: Int?,
        hasRetriedAtSamePosition: Bool,
        allowStableStationaryRecovery: Bool,
        allowAutomaticRegionRecovery: Bool
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

        // Reaching the end of a document normally produces an identical frame.
        // Return before running either overlap search: comparing `Data` uses a
        // bounded byte equality check, while candidate scoring is intentionally
        // much more expensive. This exact-only fast path cannot hide a real
        // short scroll because any changed pixel continues through image-based
        // displacement validation below.
        if previous.rgbaData == comparisonPixels.rgbaData {
            return .duplicate
        }

        let samePositionDifference = try estimator.normalizedDifferenceAtSamePosition(
            previous,
            comparisonPixels
        )
        let isLowImpactChangedFrame = samePositionDifference
            <= estimator.configuration.duplicateNormalizedDifference
        let preliminaryAnalysis = try estimator.analyze(
            previous: previous,
            next: comparisonPixels,
            preferredOverlapPixels: preferredOverlapPixels
        )
        let maximumShortDisplacement = max(
            1,
            Int((Double(previous.height)
                * estimator.configuration.maximumShortMovementRatio).rounded(.up))
        )
        let candidateDisplacement = preliminaryAnalysis.estimate?.newContentPixels
        let isShortMovement = candidateDisplacement.map {
            $0 <= maximumShortDisplacement
        } ?? false
        let isTailContraction: Bool
        if let reference = automaticTailReferenceDisplacement,
           let candidateDisplacement {
            // A short step by itself is normal for apps that consume wheel
            // events conservatively. It becomes a tail candidate only after a
            // materially larger immediately preceding step and a strong
            // contraction. Near the real end, however, macOS apps may consume
            // a final partial wheel event that is much larger than the 5%
            // "micro tail" search range (for example 410 -> 248 px). Treat
            // that relative contraction as a tail candidate too, then require
            // a second capture at the same position before accepting it.
            let microContractionThreshold = min(
                maximumShortDisplacement,
                max(2, reference / 4)
            )
            let isMicroTailContraction = isShortMovement
                && reference > maximumShortDisplacement
                && candidateDisplacement <= microContractionThreshold
            let isModerateTailContraction = reference > maximumShortDisplacement
                && candidateDisplacement > maximumShortDisplacement
                && candidateDisplacement < reference
                && candidateDisplacement * 4 <= reference * 3
                && reference - candidateDisplacement >= max(4, reference / 8)
            isTailContraction = isMicroTailContraction
                || isModerateTailContraction
        } else {
            isTailContraction = false
        }
        let hasStableTailDisplacement = candidateDisplacement.map { current in
            pendingTailDisplacement.map { previous in
                abs(current - previous) <= 1
            } ?? false
        } ?? false
        let hasStableCandidateDisplacement = candidateDisplacement.map { current in
            pendingTailDisplacement.map { previous in
                abs(current - previous) <= 1
            } ?? false
        } ?? false

        let needsStationaryConfirmation = preliminaryAnalysis.estimate == nil
            && isLowImpactChangedFrame
            && !hasRetriedAtSamePosition
        let isStationaryRecoveryAnalysis = preliminaryAnalysis.estimate == nil
            && isLowImpactChangedFrame
            && allowStableStationaryRecovery
        let analysis: ScrollOverlapAnalysis
        if isTailContraction {
            if !hasStableTailDisplacement {
                // A smooth wheel event can expose only one or two rows in the
                // first sample. Even when that intermediate image has a valid
                // overlap, wait until a subsequent sample reports the same
                // displacement. Local animation pixels are not used as the
                // stability signal and still face moving-region validation.
                throw CandidateEvaluationFailure(
                    error: .unreliableOverlap(
                        frame: frameNumber,
                        diagnostics: preliminaryAnalysis.diagnostics
                    ),
                    diagnostics: preliminaryAnalysis.diagnostics,
                    recoveryKind: .pendingTail,
                    candidateDisplacement: candidateDisplacement
                )
            }
            if isShortMovement {
                analysis = try estimator.analyzeStableShortMovement(
                    previous: previous,
                    next: comparisonPixels,
                    preferredOverlapPixels: preferredOverlapPixels
                )
            } else {
                // Moderate partial-tail movements are outside the exhaustive
                // short-movement search window. Their normal overlap estimate
                // has already been repeated at the same physical position, so
                // preserve that measured displacement instead of discarding it.
                analysis = preliminaryAnalysis
            }
        } else if needsStationaryConfirmation {
            // One same-position sample gives sparse, low-contrast tails an
            // exhaustive chance without preventing the next wheel event on a
            // page whose caret or loading indicator keeps changing.
            throw CandidateEvaluationFailure(
                error: .unreliableOverlap(
                    frame: frameNumber,
                    diagnostics: preliminaryAnalysis.diagnostics
                ),
                diagnostics: preliminaryAnalysis.diagnostics,
                recoveryKind: .pendingStationaryCheck
            )
        } else if preliminaryAnalysis.estimate == nil,
                  isLowImpactChangedFrame,
                  allowStableStationaryRecovery {
            analysis = try estimator.analyzeStableShortMovement(
                previous: previous,
                next: comparisonPixels,
                preferredOverlapPixels: preferredOverlapPixels
            )
        } else if preliminaryAnalysis.estimate == nil,
                  isLowImpactChangedFrame,
                  hasRetriedAtSamePosition {
            // The low-impact change did not produce a stable, valid overlap.
            // It is safe to ignore because it is never appended to the output;
            // the caller can now send the next bounded wheel event.
            return .stationaryNoise
        } else {
            analysis = preliminaryAnalysis
        }
        guard var estimate = analysis.estimate else {
            // A sparse page can change only a small fraction of the full frame.
            // A non-identical frame must never count as proof that the document
            // ended. Keep it pending, recapture the same viewport, and only use
            // the temporally stable short-tail path after the pixels settle.
            if isTailContraction {
                let recoveryKind: CandidateEvaluationFailure.RecoveryKind =
                    hasStableTailDisplacement
                        ? .stableTailRejected
                        : .pendingTail
                throw CandidateEvaluationFailure(
                    error: .unreliableOverlap(
                        frame: frameNumber,
                        diagnostics: analysis.diagnostics
                    ),
                    diagnostics: analysis.diagnostics,
                    recoveryKind: recoveryKind,
                    candidateDisplacement: candidateDisplacement
                )
            }
            if isLowImpactChangedFrame, hasRetriedAtSamePosition {
                return .stationaryNoise
            }
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
        let displacementMatchesAcceptedBaseline = automaticTailReferenceDisplacement.map {
            abs(displacement - $0) <= max(3, $0 / 8)
        } ?? false
        let isStrongRegionRecoveryCandidate = allowAutomaticRegionRecovery
            && movingRegion != nil
            && estimate.confidence >= 0.65
            && (estimate.normalizedDifference ?? 1) <= 0.04
            && (displacementMatchesAcceptedBaseline
                || (isTailContraction && hasStableTailDisplacement))
        let canRecoverEstablishedMovingRegion = isStrongRegionRecoveryCandidate
            && hasRetriedAtSamePosition
            && hasStableCandidateDisplacement

        func acceptUsingEstablishedMovingRegion(
            _ establishedRegion: ScrollMovingRegion
        ) throws -> CandidateEvaluation {
            let acceptedPixels = try pixels.cropped(to: establishedRegion.cropRect)
            // A one-pixel sticky-header boundary wobble can make the overlap
            // detector report N+1 even though the target consumed the same
            // wheel step. Keep the established geometric baseline for this
            // bounded recovery so no row is silently eaten at the seam.
            let recoveredEstimate: ScrollOverlapEstimate
            if let baseline = automaticTailReferenceDisplacement,
               abs(displacement - baseline) <= 3,
               baseline > 0,
               baseline < previous.height {
                recoveredEstimate = ScrollOverlapEstimate(
                    overlapPixels: previous.height - baseline,
                    newContentPixels: baseline,
                    normalizedDifference: estimate.normalizedDifference,
                    confidence: estimate.confidence,
                    usedFallback: true
                )
            } else {
                recoveredEstimate = estimate
            }
            Self.logger.notice(
                "stage=moving_region_recovered frame=\(frameNumber, privacy: .public) observed_displacement_px=\(displacement, privacy: .public) stitched_displacement_px=\(recoveredEstimate.newContentPixels, privacy: .public) confidence=\(estimate.confidence, privacy: .public)"
            )
            return .accepted(CandidateAcceptance(
                previousReplacement: nil,
                nextFrame: acceptedPixels,
                overlap: recoveredEstimate,
                movingRegion: establishedRegion,
                removedFixedEdges: false,
                // Reuse the last validated overlay geometry for the preceding
                // frame. The recovered current frame remains the single final
                // occurrence, while the stitcher removes the stale copy from
                // the already accepted viewport.
                fixedOverlayRects: establishedRegion.fixedOverlayRects
            ))
        }

        func requireStableRegionValidation() throws -> Never {
            throw CandidateEvaluationFailure(
                error: .unreliableScrollRegion(frame: frameNumber),
                diagnostics: analysis.diagnostics,
                recoveryKind: .pendingRegionValidation,
                candidateDisplacement: displacement
            )
        }

        let detection = try ScrollMovingRegionDetector().detect(
            previous: fullPrevious,
            next: pixels,
            overlapPixels: originalOverlap
        )
        guard case .safe(let detectedRegion) = detection else {
            Self.logger.error(
                "stage=moving_region_rejected frame=\(frameNumber, privacy: .public) displacement_px=\(displacement, privacy: .public) overlap_px=\(originalOverlap, privacy: .public) confidence=\(estimate.confidence, privacy: .public) same_position_difference=\(samePositionDifference, privacy: .public)"
            )
            if isStationaryRecoveryAnalysis {
                // Exhaustive short-overlap search can occasionally find a
                // plausible offset inside a blinking caret or spinner. Region
                // validation is authoritative: discard that candidate as
                // stationary noise and allow a bounded next wheel event.
                return .stationaryNoise
            }
            if canRecoverEstablishedMovingRegion, let movingRegion {
                return try acceptUsingEstablishedMovingRegion(movingRegion)
            }
            if isStrongRegionRecoveryCandidate {
                try requireStableRegionValidation()
            }
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
            if isStationaryRecoveryAnalysis {
                return .stationaryNoise
            }
            if canRecoverEstablishedMovingRegion {
                return try acceptUsingEstablishedMovingRegion(movingRegion)
            }
            if isStrongRegionRecoveryCandidate {
                try requireStableRegionValidation()
            }
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
                if isStationaryRecoveryAnalysis {
                    return .stationaryNoise
                }
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
                if isStationaryRecoveryAnalysis {
                    return .stationaryNoise
                }
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
                removedFixedEdges: true,
                fixedOverlayRects: []
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
            // Persist even a full-size region. Its validated internal-overlay
            // geometry is the baseline used when a floating composer changes
            // size near the bottom of the next frame.
            movingRegion: detectedRegion,
            removedFixedEdges: false,
            fixedOverlayRects: detectedRegion.fixedOverlayRects
        ))
    }

    private func mergedOverlayRects(
        _ existing: [ScrollPixelRect],
        _ incoming: [ScrollPixelRect]
    ) -> [ScrollPixelRect] {
        var merged = existing
        for rect in incoming where !merged.contains(rect) {
            merged.append(rect)
        }
        return merged
    }

    private func isSamePositionRetryable(_ error: ScrollCaptureError) -> Bool {
        switch error {
        case .unreliableOverlap, .unreliableScrollRegion:
            return true
        default:
            return false
        }
    }

    /// An unresolved changed viewport is not proof of document end. It is also
    /// unsafe to send another wheel event: the target may already have consumed
    /// the first request, so a second request would compound the displacement
    /// and skip content. Finish with the validated prefix and record the real
    /// reason without presenting a misleading bottom-of-page error.
    private func stopAfterUnresolvedAutomaticTransaction(
        error: ScrollCaptureError,
        capturedFrameCount: Int,
        acceptedFrameCount: Int,
        stopReason: inout ScrollCaptureStopReason?
    ) {
        guard isSamePositionRetryable(error) else { return }
        stopReason = .alignmentStopped
        Self.logger.error(
            "stage=alignment_stopped captured=\(capturedFrameCount, privacy: .public) accepted=\(acceptedFrameCount, privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
        )
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
        recaptureAttempt: Int,
        maximumAttempts: Int
    ) -> String {
        guard recaptureAttempt > 0 else {
            return hasAcceptedFrame ? L10n.tr("正在捕获下一帧") : L10n.tr("正在捕获首帧")
        }
        return L10n.tr(
            "正在原地补拍（第 %d/%d 次）",
            recaptureAttempt,
            maximumAttempts
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
        durationDeadline: TimeInterval?
    ) async throws -> Bool {
        // Stop means “capture the current viewport and stitch”; it must not
        // interrupt the bounded settle/recovery samples for that final frame.
        var remaining = Self.samePositionRecaptureInterval
        while remaining > 0 {
            try checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if !stopRequested, let durationDeadline, now >= durationDeadline {
                return false
            }
            var slice = min(remaining, 0.1)
            if !stopRequested, let durationDeadline {
                slice = min(slice, max(0, durationDeadline - now))
                if slice == 0 { return false }
            }
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
        try checkCancellation()
        return true
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelRequested {
            throw CancellationError()
        }
    }

    private func stitchFramesOffActor(
        frames: [ScrollPixelBuffer],
        overlaps: [Int],
        fixedOverlayRectsByFrame: [[ScrollPixelRect]],
        limits: ScrollStitchLimits
    ) async throws -> ScrollPixelBuffer {
        try checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try VerticalImageStitcher().stitch(
                pixelBuffers: frames,
                overlaps: overlaps,
                fixedOverlayRectsByFrame: fixedOverlayRectsByFrame,
                limits: limits
            )
        }
        activeStitchTask = task
        defer { activeStitchTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Restricted completion path for a viewport whose normal
    /// RGBA-input-plus-output peak would exceed the attempt budget. Returning
    /// the original CGImage avoids allocating either normalized input or a
    /// duplicate stitch buffer while preserving the exact captured pixels.
    private func memoryLimitedSingleFrameResult(
        image: CGImage,
        capturedFrameCount: Int,
        normalizedFrameBytes: Int,
        estimatedPeakBytes: Int,
        budget: ScrollCaptureMemoryBudget,
        maximumFrames: Int,
        progress: ScrollCaptureProgressHandler
    ) -> ScrollCaptureResult {
        let warning = L10n.tr(
            "首帧超过滚动截图内存预算，已直接保留原始截图且未分配拼接缓冲区"
        )
        Self.logger.notice(
            "stage=first_frame_memory_fallback captured=\(capturedFrameCount, privacy: .public) normalized_rgba_bytes=\(normalizedFrameBytes, privacy: .public) estimated_normal_stitch_peak_bytes=\(estimatedPeakBytes, privacy: .public) retained_budget_bytes=\(budget.maximumRetainedFrameBytes, privacy: .public) peak_budget_bytes=\(budget.maximumEstimatedPeakBytes, privacy: .public)"
        )
        emit(
            progress,
            stage: .finished,
            captured: capturedFrameCount,
            accepted: 1,
            maximum: maximumFrames,
            outputHeight: image.height,
            overlap: nil,
            message: L10n.tr("滚动截图已完成")
        )
        return ScrollCaptureResult(
            image: image,
            capturedFrameCount: capturedFrameCount,
            acceptedFrameCount: 1,
            stopReason: .memoryLimit,
            overlaps: [],
            warnings: [warning]
        )
    }

    /// A full-size moving region can use the accepted frame itself as the next
    /// detector reference. Only a real crop needs one extra uncropped viewport.
    private func uncroppedReferenceIfNeeded(
        _ pixels: ScrollPixelBuffer,
        movingRegion: ScrollMovingRegion?
    ) -> ScrollPixelBuffer? {
        guard let movingRegion,
              movingRegion.cropRect != .full(width: pixels.width, height: pixels.height) else {
            return nil
        }
        return pixels
    }

    /// Actual retained input bytes, not a pixel-count proxy. This catches the
    /// high-overlap case where output height barely grows but every accepted
    /// Retina viewport still contributes a full RGBA allocation.
    private func retainedInputBytes(
        frames: [ScrollPixelBuffer],
        rawPreviousFrame: ScrollPixelBuffer?
    ) -> Int {
        saturatingSum(
            frames.map { $0.rgbaData.count }
                + [rawPreviousFrame?.rgbaData.count].compactMap { $0 }
        )
    }

    private func estimatedStitchPeakBytes(
        frames: [ScrollPixelBuffer],
        rawPreviousFrame: ScrollPixelBuffer?,
        outputHeight: Int
    ) -> Int {
        guard let first = frames.first else { return 0 }
        let outputBytes = rgbaByteCount(width: first.width, height: outputHeight)
        let largestViewportBytes = (
            frames.map { $0.rgbaData.count }
                + [rawPreviousFrame?.rgbaData.count].compactMap { $0 }
        ).max() ?? 0
        return saturatingSum([
            retainedInputBytes(frames: frames, rawPreviousFrame: rawPreviousFrame),
            outputBytes,
            // Reserve one viewport for the capture/image bridge and allocator
            // slack while the detached stitch task owns the output buffer.
            largestViewportBytes
        ])
    }

    private func estimatedEvaluationPeakBytes(
        frames: [ScrollPixelBuffer],
        rawPreviousFrame: ScrollPixelBuffer?,
        candidate: ScrollPixelBuffer,
        comparisonCandidate: ScrollPixelBuffer,
        pendingTailFrame: ScrollPixelBuffer?,
        outputHeight: Int
    ) -> Int {
        let outputBytes = frames.first.map {
            rgbaByteCount(width: $0.width, height: outputHeight)
        } ?? 0
        let comparisonOwnsAdditionalStorage = comparisonCandidate.width != candidate.width
            || comparisonCandidate.height != candidate.height
            || comparisonCandidate.bytesPerRow != candidate.bytesPerRow
        return saturatingSum([
            retainedInputBytes(frames: frames, rawPreviousFrame: rawPreviousFrame),
            outputBytes,
            // The captured CGImage and the normalized RGBA buffer coexist.
            candidate.rgbaData.count,
            candidate.rgbaData.count,
            comparisonOwnsAdditionalStorage ? comparisonCandidate.rgbaData.count : 0,
            pendingTailFrame?.rgbaData.count ?? 0
        ])
    }

    private func exceedsMemoryBudget(
        frames: [ScrollPixelBuffer],
        rawPreviousFrame: ScrollPixelBuffer?,
        outputHeight: Int,
        budget: ScrollCaptureMemoryBudget
    ) -> Bool {
        retainedInputBytes(frames: frames, rawPreviousFrame: rawPreviousFrame)
            > budget.maximumRetainedFrameBytes
            || estimatedStitchPeakBytes(
                frames: frames,
                rawPreviousFrame: rawPreviousFrame,
                outputHeight: outputHeight
            ) > budget.maximumEstimatedPeakBytes
    }

    private func markMemoryLimit(
        acceptedFrameCount: Int,
        frames: [ScrollPixelBuffer],
        rawPreviousFrame: ScrollPixelBuffer?,
        outputHeight: Int,
        budget: ScrollCaptureMemoryBudget,
        warnings: inout [String],
        stopReason: inout ScrollCaptureStopReason?
    ) {
        stopReason = .memoryLimit
        let warning = L10n.tr(
            "已达到滚动截图内存保护上限，已保留并拼接 %d 帧可靠内容",
            acceptedFrameCount
        )
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
        let retainedBytes = retainedInputBytes(
            frames: frames,
            rawPreviousFrame: rawPreviousFrame
        )
        let estimatedPeakBytes = estimatedStitchPeakBytes(
            frames: frames,
            rawPreviousFrame: rawPreviousFrame,
            outputHeight: outputHeight
        )
        Self.logger.notice(
            "stage=memory_limit accepted=\(acceptedFrameCount, privacy: .public) retained_rgba_bytes=\(retainedBytes, privacy: .public) estimated_stitch_peak_bytes=\(estimatedPeakBytes, privacy: .public) retained_budget_bytes=\(budget.maximumRetainedFrameBytes, privacy: .public) peak_budget_bytes=\(budget.maximumEstimatedPeakBytes, privacy: .public)"
        )
    }

    private func rgbaByteCount(width: Int, height: Int) -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return .max }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? .max : bytes
    }

    private func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
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
    private func waitForNextCapture(
        seconds: TimeInterval,
        stopsEarly: Bool = true
    ) async throws {
        var remaining = seconds
        while remaining > 0 {
            try checkCancellation()
            if stopsEarly, stopRequested { return }
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
