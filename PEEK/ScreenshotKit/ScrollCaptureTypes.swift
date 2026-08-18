import CoreGraphics
import Foundation

/// 滚动截图使用 Quartz 全局坐标：原点位于主显示器左上角，单位为逻辑点。
/// 调用方若从 AppKit 选区得到矩形，需要先转换为 Quartz 全局坐标。
struct ScrollCaptureConfiguration: Sendable {
    var captureRect: CGRect
    /// Quartz global coordinate used as the scroll event target. Defaults to
    /// the center of `captureRect` for manually selected regions.
    var scrollPoint: CGPoint? = nil
    var mode: ScrollCaptureMode = .manual
    var captureInterval: TimeInterval = 0.8
    var maximumFrames: Int = 30
    var maximumDuration: TimeInterval? = 300
    var overlapSearch = ScrollOverlapSearchConfiguration()
    var stitchLimits = ScrollStitchLimits()

    func validated() throws -> ScrollCaptureConfiguration {
        guard captureRect.isFinite,
              captureRect.width >= 1,
              captureRect.height >= 1 else {
            throw ScrollCaptureError.invalidCaptureRect
        }
        if let scrollPoint,
           ![scrollPoint.x, scrollPoint.y].allSatisfy(\.isFinite) {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("滚动目标坐标无效"))
        }
        guard captureInterval >= 0.1, captureInterval <= 30 else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("采集间隔必须在 0.1～30 秒之间"))
        }
        guard (1 ... 500).contains(maximumFrames) else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("最大页数必须在 1～500 之间"))
        }
        if let maximumDuration, maximumDuration < captureInterval {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("最长采集时间不能小于采集间隔"))
        }
        try overlapSearch.validate()
        try stitchLimits.validate()

        var copy = self
        copy.captureRect = captureRect.standardized.integral
        copy.scrollPoint = scrollPoint ?? CGPoint(
            x: copy.captureRect.midX,
            y: copy.captureRect.midY
        )
        return copy
    }
}

enum ScrollCaptureMode: Sendable {
    /// 用户在目标页面中手动滚动，采集器按固定间隔捕获同一区域。
    case manual
    /// 发送系统滚轮事件。开始前必须已获得 Post Event 权限，且目标窗口应位于前台。
    case automatic(AutomaticScrollConfiguration)
}

struct AutomaticScrollConfiguration: Sendable {
    /// 每次滚动的像素量；正数表示向页面下方滚动。
    var amount: Int32 = 700
    /// 连续捕获到相同画面的次数达到该值后，认为已到达页面底部。
    var consecutiveDuplicateLimit: Int = 2

    func validate() throws {
        guard amount > 0 else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("自动滚动距离必须大于 0"))
        }
        guard (1 ... 10).contains(consecutiveDuplicateLimit) else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("重复帧停止阈值必须在 1～10 之间"))
        }
    }
}

struct ScrollOverlapSearchConfiguration: Sendable {
    var minimumOverlapRatio: Double = 0.08
    var maximumOverlapRatio: Double = 0.95
    var maximumNormalizedDifference: Double = 0.14
    var duplicateNormalizedDifference: Double = 0.012
    var minimumTexture: Double = 0.004
    var sampleColumns: Int = 80
    var sampleRows: Int = 72
    var maximumCoarseCandidates: Int = 220
    /// Number of the best textured coarse candidates whose neighboring pixel
    /// offsets are searched exhaustively. Keeping more than one candidate is
    /// important for tall captures where the coarse step can skip the true
    /// overlap by several pixels.
    var refinementCandidateCount: Int = 8
    /// Two spatially separated candidates whose normalized differences are
    /// closer than this value are considered ambiguous. Ambiguity fails closed
    /// instead of selecting an arbitrary repeated pattern.
    var minimumDistinctCandidateDifference: Double = 0.004

    func validate() throws {
        guard minimumOverlapRatio > 0,
              maximumOverlapRatio < 1,
              minimumOverlapRatio < maximumOverlapRatio else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("重叠搜索比例无效"))
        }
        guard maximumNormalizedDifference > 0,
              maximumNormalizedDifference <= 1,
              duplicateNormalizedDifference >= 0,
              duplicateNormalizedDifference < maximumNormalizedDifference else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("图像差异阈值无效"))
        }
        guard minimumTexture >= 0, minimumTexture <= 1 else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("纹理阈值无效"))
        }
        guard sampleColumns >= 8,
              sampleRows >= 8,
              maximumCoarseCandidates >= 16,
              refinementCandidateCount >= 2,
              refinementCandidateCount <= maximumCoarseCandidates else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("重叠搜索采样参数过小"))
        }
        guard minimumDistinctCandidateDifference >= 0,
              minimumDistinctCandidateDifference < maximumNormalizedDifference else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("重叠候选区分阈值无效"))
        }
    }
}

struct ScrollStitchLimits: Sendable {
    var maximumOutputHeightPixels: Int = 40_000
    var maximumOutputPixels: Int = 40_000_000

    func validate() throws {
        guard maximumOutputHeightPixels >= 1_000,
              maximumOutputPixels >= 1_000_000 else {
            throw ScrollCaptureError.invalidConfiguration(L10n.tr("拼接图尺寸上限过小"))
        }
    }
}

enum ScrollCaptureStage: String, Sendable {
    case preparing
    case capturing
    case duplicateSkipped
    case scrolling
    case stitching
    case finished
}

struct ScrollCaptureProgress: Sendable {
    let stage: ScrollCaptureStage
    let capturedFrameCount: Int
    let acceptedFrameCount: Int
    let maximumFrameCount: Int
    let estimatedOutputHeightPixels: Int
    let lastOverlapPixels: Int?
    let message: String
}

typealias ScrollCaptureProgressHandler = @Sendable (ScrollCaptureProgress) -> Void

enum ScrollCaptureStopReason: String, Sendable {
    case userStopped
    case maximumFrames
    case durationLimit
    case endDetected
    /// A later frame failed validation, but the already accepted prefix was
    /// stitched successfully and is available for explicit user recovery.
    case failureRecovered
}

struct ScrollCaptureResult: @unchecked Sendable {
    let image: CGImage
    let capturedFrameCount: Int
    let acceptedFrameCount: Int
    let stopReason: ScrollCaptureStopReason
    let overlaps: [ScrollOverlapEstimate]
    let warnings: [String]
}

/// Carries a fail-closed scrolling error together with an independently
/// stitched prefix made only from frames that had already passed every overlap
/// and moving-region check. Callers may offer that prefix to the user, but must
/// never silently treat it as a complete scrolling capture.
struct ScrollCapturePartialFailure: LocalizedError, @unchecked Sendable {
    let underlying: ScrollCaptureError
    let partialResult: ScrollCaptureResult

    var errorDescription: String? { underlying.errorDescription }
}

struct ScrollOverlapEstimate: Sendable, Equatable {
    let overlapPixels: Int
    let newContentPixels: Int
    let normalizedDifference: Double?
    let confidence: Double
    let usedFallback: Bool
}

/// 重叠识别失败的可操作分类。调用方可以据此决定降低滚动步长、
/// 延迟补拍，或提示用户重新选择包含更多正文纹理的区域。
enum ScrollOverlapFailureReason: String, Sendable, Equatable {
    case differenceTooHigh
    case insufficientTexture
    case ambiguous
    case noCandidate

    var localizedDescription: String {
        switch self {
        case .differenceTooHigh:
            return L10n.tr("相邻画面差异过大")
        case .insufficientTexture:
            return L10n.tr("选区纹理不足")
        case .ambiguous:
            return L10n.tr("存在多个相似的重叠位置")
        case .noCandidate:
            return L10n.tr("没有可用的重叠候选")
        }
    }
}

/// 一次重叠搜索的结构化诊断。候选字段为 optional，因为尺寸过小等
/// `noCandidate` 情况下没有任何可报告的候选。
struct ScrollOverlapDiagnostics: Sendable, Equatable {
    let failureReason: ScrollOverlapFailureReason?
    let candidateOverlapPixels: Int?
    let normalizedDifference: Double?
    let texture: Double?
    let confidence: Double?
    let evaluatedCandidateCount: Int
    let preferredOverlapPixels: Int?

    var localizedDescription: String {
        guard let failureReason else {
            if let candidateOverlapPixels {
                return L10n.tr("已识别重叠区域：%d 像素", candidateOverlapPixels)
            }
            return L10n.tr("已识别重叠区域")
        }

        var details: [String] = [failureReason.localizedDescription]
        if let candidateOverlapPixels {
            details.append(L10n.tr("候选重叠 %d px", candidateOverlapPixels))
        }
        if let normalizedDifference {
            details.append(L10n.tr("差异 %@", Self.percentage(normalizedDifference)))
        }
        if let texture {
            details.append(L10n.tr("纹理 %@", Self.percentage(texture)))
        }
        if let confidence {
            details.append(L10n.tr("置信度 %@", Self.percentage(confidence)))
        }
        return details.joined(separator: "，")
    }

    private static func percentage(_ value: Double) -> String {
        "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

/// `estimate` 的结构化版本。成功与失败都返回诊断，便于 UI 展示或复制，
/// 同时让现有仅关心可选 estimate 的调用方保持兼容。
struct ScrollOverlapAnalysis: Sendable, Equatable {
    let estimate: ScrollOverlapEstimate?
    let diagnostics: ScrollOverlapDiagnostics

    var isSuccess: Bool { estimate != nil }
}

enum ScrollCaptureError: LocalizedError, Equatable {
    case alreadyRunning
    case invalidCaptureRect
    case invalidConfiguration(String)
    case screenRecordingPermissionDenied
    case accessibilityPermissionDenied
    case captureFailed
    case emptyCapture
    case incompatibleFrames
    case invalidPixelBuffer
    case scrollTargetChanged
    case targetDidNotScroll
    case unreliableOverlap(frame: Int, diagnostics: ScrollOverlapDiagnostics)
    case unreliableScrollRegion(frame: Int)
    case overlapCountMismatch
    case outputTooLarge(width: Int, height: Int)
    case bitmapContextCreationFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return L10n.tr("滚动截图任务已在运行")
        case .invalidCaptureRect:
            return L10n.tr("截图区域无效")
        case .invalidConfiguration(let message):
            return message
        case .screenRecordingPermissionDenied:
            return L10n.tr("未获得屏幕录制权限")
        case .accessibilityPermissionDenied:
            return L10n.tr("自动滚动需要系统的 Post Event 权限")
        case .captureFailed:
            return L10n.tr("无法捕获选定区域")
        case .emptyCapture:
            return L10n.tr("没有可拼接的截图帧")
        case .incompatibleFrames:
            return L10n.tr("相邻截图尺寸或像素格式不一致")
        case .invalidPixelBuffer:
            return L10n.tr("图像像素数据无效")
        case .scrollTargetChanged:
            return L10n.tr("目标窗口已关闭、移动、被遮挡或不再位于前台，已停止自动滚动")
        case .targetDidNotScroll:
            return L10n.tr("未检测到目标内容滚动。请将选区中心放在可滚动正文内，或确认页面尚未到底")
        case .unreliableOverlap(let frame, let diagnostics):
            let reason: String
            if diagnostics.failureReason != nil {
                reason = diagnostics.localizedDescription
            } else {
                var details: [String] = []
                if let overlap = diagnostics.candidateOverlapPixels {
                    details.append(L10n.tr("候选重叠 %d px", overlap))
                }
                if let difference = diagnostics.normalizedDifference {
                    details.append(
                        L10n.tr("差异 %d%%", Int((min(1, max(0, difference)) * 100).rounded()))
                    )
                }
                if let texture = diagnostics.texture {
                    details.append(
                        L10n.tr("纹理 %d%%", Int((min(1, max(0, texture)) * 100).rounded()))
                    )
                }
                if let confidence = diagnostics.confidence {
                    details.append(
                        L10n.tr("置信度 %d%%", Int((min(1, max(0, confidence)) * 100).rounded()))
                    )
                }
                reason = details.isEmpty ? L10n.tr("候选质量不足") : details.joined(separator: "，")
            }
            return L10n.tr(
                "第 %d 帧无法可靠识别重叠区域（%@），已原地补拍仍未恢复，且未生成可能错版的长图。可减小步长重试、重新框选或切换手动模式。",
                frame,
                reason
            )
        case .unreliableScrollRegion(let frame):
            return L10n.tr(
                "第 %d 帧检测到固定悬浮内容或滚动区域边界变化，已停止且未生成可能错版的长图。请重新框选纯滚动正文后重试。",
                frame
            )
        case .overlapCountMismatch:
            return L10n.tr("重叠数据数量与截图帧数量不匹配")
        case .outputTooLarge(let width, let height):
            return L10n.tr("拼接结果过大（%d×%d 像素）", width, height)
        case .bitmapContextCreationFailed:
            return L10n.tr("无法创建图像处理缓冲区")
        case .imageCreationFailed:
            return L10n.tr("无法生成拼接图像")
        }
    }
}

private extension CGRect {
    var isFinite: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite)
    }
}
