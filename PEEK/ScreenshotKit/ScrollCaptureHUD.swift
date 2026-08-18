import AppKit
import SwiftUI

@MainActor
final class ScrollCaptureHUDController {
    private let model = ScrollCaptureHUDModel()
    private var panel: NSPanel?

    func show(
        mode: ScrollCaptureMode,
        selectionRect: CGRect,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        close()
        model.modeDescription = mode.isAutomatic
            ? L10n.tr("正在自动滚动；到达底部会自动停止")
            : L10n.tr("请在选区内手动向下滚动，完成后点“停止并拼接”")
        model.message = L10n.tr("准备采集首帧")
        model.progressValue = 0
        model.frameDescription = L10n.tr("0 帧")

        let contentSize = CGSize(width: 390, height: 126)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: ScrollCaptureHUDView(
                model: model,
                onStop: onStop,
                onCancel: onCancel
            )
        )
        panel.setFrameOrigin(Self.panelOrigin(
            panelSize: contentSize,
            selectionRect: selectionRect
        ))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(_ progress: ScrollCaptureProgress) {
        model.message = progress.message
        model.frameDescription = L10n.tr(
            "已采集 %d/%d 帧",
            progress.acceptedFrameCount,
            progress.maximumFrameCount
        )
        model.progressValue = progress.maximumFrameCount > 0
            ? Double(progress.acceptedFrameCount) / Double(progress.maximumFrameCount)
            : 0
    }

    func showStitching() {
        model.message = L10n.tr("正在分析重叠区域并拼接…")
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private static func panelOrigin(panelSize: CGSize, selectionRect: CGRect) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect.insetBy(dx: -40, dy: -40)
        var x = selectionRect.midX - panelSize.width / 2
        x = min(max(x, visible.minX + 10), visible.maxX - panelSize.width - 10)

        let above = selectionRect.maxY + 12
        let below = selectionRect.minY - panelSize.height - 12
        let y: CGFloat
        if above + panelSize.height <= visible.maxY {
            y = above
        } else if below >= visible.minY {
            y = below
        } else {
            y = visible.minY + 12
        }
        return CGPoint(x: x, y: y)
    }
}

@MainActor
private final class ScrollCaptureHUDModel: ObservableObject {
    @Published var modeDescription = ""
    @Published var message = ""
    @Published var frameDescription = ""
    @Published var progressValue = 0.0
}

private struct ScrollCaptureHUDView: View {
    @ObservedObject var model: ScrollCaptureHUDModel
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.stack.badge.plus")
                    .foregroundStyle(.tint)
                Text(L10n.tr("滚动截图"))
                    .font(.headline)
                Spacer()
                Text(model.frameDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(model.modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: model.progressValue)
            HStack {
                Text(model.message)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Button(L10n.tr("取消"), role: .cancel, action: onCancel)
                Button(L10n.tr("停止并拼接"), action: onStop)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12))
        }
    }
}

private extension ScrollCaptureMode {
    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}
