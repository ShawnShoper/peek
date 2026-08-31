import AppKit
import SwiftUI

/// The Settings destination that should be visible while a guide step is presented.
///
/// `SettingsView` owns its tab selection, so the guide reports destinations instead
/// of mutating settings state or triggering any feature directly.
enum OnboardingGuideDestination: String, Equatable, Sendable {
    case general
    case search
    case clipboard
    case shortcuts
    case translation
    case capture
    case appearance
    case about

    var title: String {
        switch self {
        case .general: return L10n.tr("通用")
        case .search: return L10n.tr("搜索")
        case .clipboard: return L10n.tr("剪贴板")
        case .shortcuts: return L10n.tr("快捷键")
        case .translation: return L10n.tr("翻译")
        case .capture: return L10n.tr("截图")
        case .appearance: return L10n.tr("外观")
        case .about: return L10n.tr("关于")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .search: return "magnifyingglass"
        case .clipboard: return "clipboard"
        case .shortcuts: return "keyboard"
        case .translation: return "character.book.closed"
        case .capture: return "viewfinder.circle"
        case .appearance: return "paintpalette"
        case .about: return "info.circle"
        }
    }
}

/// A concrete control or section that the parent Settings view can highlight.
enum OnboardingGuideTarget: String, Equatable, Hashable, Sendable {
    case settingsTabs
    case documentSearch
    case clipboardHistory
    case capturePermission
    case scrollingCapture
    case recognition
    case translationUsage
    case shortcutRecorder
    case appearanceTheme
    case privacyPolicy
    case replayTutorial
}

/// Anchors reported by real Settings controls. The root Settings container resolves
/// these anchors through its overlay GeometryReader, so the guide never guesses a
/// fixed location and remains correct when the window or display size changes.
struct OnboardingGuideTargetPreferenceKey: PreferenceKey {
    static let defaultValue: [OnboardingGuideTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [OnboardingGuideTarget: Anchor<CGRect>],
        nextValue: () -> [OnboardingGuideTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    /// Marks a real Settings control as the focus target for one guide step.
    func onboardingGuideTarget(_ target: OnboardingGuideTarget) -> some View {
        anchorPreference(
            key: OnboardingGuideTargetPreferenceKey.self,
            value: .bounds,
            transform: { [target: $0] }
        )
    }
}

private struct OnboardingGuideTip: Identifiable {
    let systemImage: String
    let title: String
    let detail: String

    var id: String { systemImage + title }
}

/// Stable step identifiers are internal so first-run state and regression tests can
/// reason about the complete guide without depending on localized presentation text.
enum OnboardingGuideStep: Int, CaseIterable, Identifiable, Sendable {
        case welcome
        case search
        case clipboard
        case regionCapture
        case scrollingCapture
        case recognition
        case translation
        case shortcuts
        case appearance
        case privacy
        case complete

        var id: Int { rawValue }

        var destination: OnboardingGuideDestination {
            switch self {
            case .welcome: return .general
            case .search: return .search
            case .clipboard: return .clipboard
            case .regionCapture, .scrollingCapture, .recognition: return .capture
            case .translation: return .translation
            case .shortcuts: return .shortcuts
            case .appearance: return .appearance
            case .privacy, .complete: return .about
            }
        }

        var target: OnboardingGuideTarget {
            switch self {
            case .welcome: return .settingsTabs
            case .search: return .documentSearch
            case .clipboard: return .clipboardHistory
            case .regionCapture: return .capturePermission
            case .scrollingCapture: return .scrollingCapture
            case .recognition: return .recognition
            case .translation: return .translationUsage
            case .shortcuts: return .shortcutRecorder
            case .appearance: return .appearanceTheme
            case .privacy: return .privacyPolicy
            case .complete: return .replayTutorial
            }
        }

        var systemImage: String {
            switch self {
            case .welcome: return "sparkles"
            case .search: return "magnifyingglass.circle.fill"
            case .clipboard: return "clipboard.fill"
            case .regionCapture: return "viewfinder.circle.fill"
            case .scrollingCapture: return "scroll.fill"
            case .recognition: return "text.viewfinder"
            case .translation: return "character.book.closed.fill"
            case .shortcuts: return "keyboard.fill"
            case .appearance: return "paintpalette.fill"
            case .privacy: return "lock.shield.fill"
            case .complete: return "checkmark.seal.fill"
            }
        }

        var color: Color {
            switch self {
            case .welcome: return .accentColor
            case .search: return .blue
            case .clipboard: return .mint
            case .regionCapture: return .indigo
            case .scrollingCapture: return .teal
            case .recognition: return .purple
            case .translation: return .cyan
            case .shortcuts: return .orange
            case .appearance: return .pink
            case .privacy: return .green
            case .complete: return .green
            }
        }

        var title: String {
            switch self {
            case .welcome: return L10n.tr("欢迎使用 PEEK")
            case .search: return L10n.tr("快速找到应用、文件与文件夹")
            case .clipboard: return L10n.tr("找回最近复制的内容")
            case .regionCapture: return L10n.tr("区域截图与标注")
            case .scrollingCapture: return L10n.tr("截取完整的滚动内容")
            case .recognition: return L10n.tr("识别文字与二维码")
            case .translation: return L10n.tr("使用渐进式翻译")
            case .shortcuts: return L10n.tr("设置顺手且不冲突的快捷键")
            case .appearance: return L10n.tr("调整外观与菜单栏使用方式")
            case .privacy: return L10n.tr("了解权限与隐私边界")
            case .complete: return L10n.tr("PEEK 已准备就绪")
            }
        }

        var summary: String {
            switch self {
            case .welcome:
                return L10n.tr("PEEK 将文件查找、剪贴板、截图、识别和翻译集中在菜单栏中。接下来会逐项介绍，但不会替你执行操作或申请权限。")
            case .search:
                return L10n.tr("搜索使用本机索引，应用优先展示；文件和文件夹会在各自分组中出现。索引完成的内容可以立即查询。")
            case .clipboard:
                return L10n.tr("剪贴板历史在本机保留最近 100 条文字、图片、链接和文件记录，随时可以重新复制或粘贴。")
            case .regionCapture:
                return L10n.tr("拖出选区后，可移动或调整范围，再使用紧贴选区的工具栏完成标注、复制或保存。")
            case .scrollingCapture:
                return L10n.tr("PEEK 会优先识别鼠标所在的可滚动区域；识别不到时仍可自由调整选框。")
            case .recognition:
                return L10n.tr("OCR 在本机识别中英文；二维码识别成功后，会按文本、网址或图片类型展示结果。")
            case .translation:
                return L10n.tr("翻译使用独立浮窗。先输入原文，再主动提交翻译，避免输入过程中反复请求。")
            case .shortcuts:
                return L10n.tr("每项核心功能都可以单独录入快捷键。PEEK 会检查应用内部重复和可识别的系统冲突。")
            case .appearance:
                return L10n.tr("界面可跟随系统深浅色，也能调整搜索窗口的透明度、结果密度和预览方式。")
            case .privacy:
                return L10n.tr("文件索引、截图、OCR 和 Apple 本地翻译优先在本机处理；只有你启用的云翻译服务会接收主动提交的文本。")
            case .complete:
                return L10n.tr("关闭设置后，PEEK 会继续驻留在菜单栏。你可以随时回到设置重新查看本教程或调整功能。")
            }
        }

        var guidance: String {
            switch self {
            case .welcome:
                return L10n.tr("指引：教程会自动切换顶部设置分类。请按“下一步”依次查看，不需要现在完成任何授权。")
            case .search:
                return L10n.tr("指引：在“搜索”中先查看“应用搜索”，再进入“文档搜索”添加需要查找的文件夹；索引进度与日志可在同一页查看。")
            case .clipboard:
                return L10n.tr("指引：在“剪贴板”中开启记录并设置快捷键；打开历史后用方向键选择，Enter 复制，Command + Enter 复制并粘贴到之前的应用。")
            case .regionCapture:
                return L10n.tr("指引：授权屏幕录制后按区域截图快捷键，拖选范围；未选择工具时直接拖动选区，双击或按 Enter 复制结果。")
            case .scrollingCapture:
                return L10n.tr("指引：将鼠标放在网页或列表的滚动区域内，再按滚动截图快捷键；确认选区后开始采集，手动模式需点击“停止并拼接”。")
            case .recognition:
                return L10n.tr("指引：按截图 OCR 快捷键后拖选文字区域；普通截图选区检测到二维码时，可主动点击工具栏中的二维码按钮。")
            case .translation:
                return L10n.tr("指引：打开翻译浮窗，输入或粘贴文字，选择目标语言，然后按 Command + Enter 开始翻译。")
            case .shortcuts:
                return L10n.tr("指引：在“快捷键”页点击右侧按键框，再按下新组合；出现冲突提示时，请换用包含 Command、Option 或 Control 的组合。")
            case .appearance:
                return L10n.tr("指引：在“外观”选择跟随系统、浅色或深色；在“通用”设置搜索窗口出现的屏幕和位置。日常入口都在菜单栏图标中。")
            case .privacy:
                return L10n.tr("指引：在“关于”中打开内置隐私政策；需要目录、屏幕录制或辅助功能权限时，PEEK 会提供明确按钮，由你决定是否授权。")
            case .complete:
                return L10n.tr("指引：点击“完成教程”保存首次使用状态。以后可在设置中选择“重新查看新手教程”再次打开。")
            }
        }

        var shortcut: String? {
            switch self {
            case .search:
                return ScreenshotGlobalHotKeyAction.search.defaultShortcut.displayString
            case .clipboard:
                return ScreenshotGlobalHotKeyAction.clipboardHistory.defaultShortcut.displayString
            case .regionCapture:
                return ScreenshotGlobalHotKeyAction.region.defaultShortcut.displayString
            case .scrollingCapture:
                return ScreenshotGlobalHotKeyAction.scrolling.defaultShortcut.displayString
            case .recognition:
                return ScreenshotGlobalHotKeyAction.ocr.defaultShortcut.displayString
            case .translation:
                return ScreenshotGlobalHotKeyAction.translation.defaultShortcut.displayString
            default: return nil
            }
        }

        fileprivate var tips: [OnboardingGuideTip] {
            switch self {
            case .welcome:
                return [
                    OnboardingGuideTip(
                        systemImage: "menubar.rectangle",
                        title: L10n.tr("菜单栏常驻"),
                        detail: L10n.tr("关闭设置不会退出 PEEK；从菜单栏随时打开功能。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "hand.raised.fill",
                        title: L10n.tr("操作由你决定"),
                        detail: L10n.tr("教程只做说明，不会自动截图、索引、翻译或申请权限。")
                    )
                ]
            case .search:
                return [
                    OnboardingGuideTip(
                        systemImage: "app.fill",
                        title: L10n.tr("应用优先"),
                        detail: L10n.tr("相同名称下应用排在文件和文件夹之前，常用应用会逐步靠前。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "externaldrive.fill",
                        title: L10n.tr("增量索引"),
                        detail: L10n.tr("首次快速建立索引，之后在后台低占用更新；未索引内容暂时不会出现。")
                    )
                ]
            case .clipboard:
                return [
                    OnboardingGuideTip(
                        systemImage: "externaldrive.badge.checkmark",
                        title: L10n.tr("只保存在本机"),
                        detail: L10n.tr("历史内容位于 PEEK 的沙盒目录，不会自动上传网络。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "eye.slash.fill",
                        title: L10n.tr("敏感应用可忽略"),
                        detail: L10n.tr("可以暂停记录，或将密码管理器等应用加入忽略列表。")
                    )
                ]
            case .regionCapture:
                return [
                    OnboardingGuideTip(
                        systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                        title: L10n.tr("先选区，再确认"),
                        detail: L10n.tr("选区只是范围标记，移动和缩放后才按最终区域生成图片。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "pencil.tip.crop.circle",
                        title: L10n.tr("选区内直接编辑"),
                        detail: L10n.tr("可使用画笔、形状、文字、马赛克、取色、OCR 和二维码工具。")
                    )
                ]
            case .scrollingCapture:
                return [
                    OnboardingGuideTip(
                        systemImage: "cursorarrow.motionlines",
                        title: L10n.tr("自动识别目标"),
                        detail: L10n.tr("鼠标位于滚动区时预选内容区域，其他位置预选当前窗口。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "hand.draw.fill",
                        title: L10n.tr("始终可以手动调整"),
                        detail: L10n.tr("自动识别只是起点，最终以你确认的选框为准。")
                    )
                ]
            case .recognition:
                return [
                    OnboardingGuideTip(
                        systemImage: "text.viewfinder",
                        title: L10n.tr("本地 OCR"),
                        detail: L10n.tr("识别结果保留换行并尽量还原版式，可直接复制。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "qrcode.viewfinder",
                        title: L10n.tr("二维码结果"),
                        detail: L10n.tr("网址可以复制或打开，文本可以复制，图片内容可以预览。")
                    )
                ]
            case .translation:
                return [
                    OnboardingGuideTip(
                        systemImage: "command",
                        title: L10n.tr("主动翻译"),
                        detail: L10n.tr("按 Command + Enter 才开始翻译，输入文字本身不会触发请求。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "character.bubble.fill",
                        title: L10n.tr("主语言识别"),
                        detail: L10n.tr("中英或其他混合文本会优先判断占主导的语言，也可手动指定。")
                    )
                ]
            case .shortcuts:
                return [
                    OnboardingGuideTip(
                        systemImage: "checkmark.shield.fill",
                        title: L10n.tr("保存前检查"),
                        detail: L10n.tr("录入后会立即显示启用、停用或冲突状态。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "arrow.counterclockwise",
                        title: L10n.tr("可以恢复默认"),
                        detail: L10n.tr("修改不合适时，可恢复 PEEK 提供的默认组合。")
                    )
                ]
            case .appearance:
                return [
                    OnboardingGuideTip(
                        systemImage: "circle.lefthalf.filled",
                        title: L10n.tr("跟随系统"),
                        detail: L10n.tr("窗口主体、控件和文字会一起适配当前系统配色。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "rectangle.inset.filled",
                        title: L10n.tr("查找窗口"),
                        detail: L10n.tr("可调整透明度、结果密度、预览区域和跨显示器位置。")
                    )
                ]
            case .privacy:
                return [
                    OnboardingGuideTip(
                        systemImage: "lock.macwindow",
                        title: L10n.tr("本地优先"),
                        detail: L10n.tr("搜索索引不包含文件正文；截图和 OCR 结果不会由 PEEK 自动上传。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "checkmark.circle.fill",
                        title: L10n.tr("按需授权"),
                        detail: L10n.tr("不授权某项权限只会限制相关功能，不影响其他已就绪功能。")
                    )
                ]
            case .complete:
                return [
                    OnboardingGuideTip(
                        systemImage: "magnifyingglass",
                        title: L10n.tr("从查找开始"),
                        detail: L10n.tr("按文件查找快捷键，输入应用、文件或文件夹名称。")
                    ),
                    OnboardingGuideTip(
                        systemImage: "gearshape.fill",
                        title: L10n.tr("随时回来调整"),
                        detail: L10n.tr("菜单栏中的设置入口会保留教程、权限和所有个性化选项。")
                    )
                ]
            }
        }
}

private struct OnboardingSpotlightShape: Shape {
    let cutout: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let cutout {
            path.addRoundedRect(
                in: cutout,
                cornerSize: CGSize(width: 12, height: 12)
            )
        }
        return path
    }
}

private struct OnboardingGuidePlacement {
    let cardFrame: CGRect
    let arrowStart: CGPoint?
    let arrowEnd: CGPoint?
}

/// A first-run walkthrough designed to be overlaid on the real PEEK Settings window.
///
/// The parent view remains responsible for persistence and for selecting the real
/// Settings tab. This view never requests permission automatically, starts a
/// capture, or opens another PEEK tool. Any permission action requires an
/// explicit click from the user.
struct OnboardingGuideView: View {
    private let targetAnchors: [OnboardingGuideTarget: Anchor<CGRect>]
    private let onNavigate: (OnboardingGuideDestination) -> Void
    private let onTargetChange: (OnboardingGuideTarget) -> Void
    private let onAuthorizeDocuments: () -> Void
    private let onComplete: () -> Void
    private let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingGuideStep

    init(
        targetAnchors: [OnboardingGuideTarget: Anchor<CGRect>] = [:],
        initialStep: OnboardingGuideStep = .welcome,
        onNavigate: @escaping (OnboardingGuideDestination) -> Void = { _ in },
        onTargetChange: @escaping (OnboardingGuideTarget) -> Void = { _ in },
        onAuthorizeDocuments: @escaping () -> Void = {},
        onComplete: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.targetAnchors = targetAnchors
        self.onNavigate = onNavigate
        self.onTargetChange = onTargetChange
        self.onAuthorizeDocuments = onAuthorizeDocuments
        self.onComplete = onComplete
        self.onSkip = onSkip
        _currentStep = State(initialValue: initialStep)
    }

    var body: some View {
        GeometryReader { proxy in
            let targetRect = targetAnchors[currentStep.target].map { proxy[$0] }
            let visibleTarget = normalizedTarget(targetRect, in: proxy.size)
            let placement = guidePlacement(in: proxy.size, target: visibleTarget)

            ZStack {
                OnboardingSpotlightShape(cutout: visibleTarget)
                    .fill(
                        Color.black.opacity(0.46),
                        style: FillStyle(eoFill: true)
                    )
                    .contentShape(Rectangle())

                if let visibleTarget {
                    targetHighlight(visibleTarget)
                    if let start = placement.arrowStart, let end = placement.arrowEnd {
                        guideArrow(from: start, to: end)
                    }
                }

                guideCard
                    .frame(
                        width: placement.cardFrame.width,
                        height: placement.cardFrame.height
                    )
                    .position(
                        x: placement.cardFrame.midX,
                        y: placement.cardFrame.midY
                    )
                    .zIndex(2)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.24),
                value: currentStep
            )
        }
        .onAppear {
            reportCurrentTarget()
        }
        .onChange(of: currentStep) { _ in
            reportCurrentTarget()
        }
        .accessibilityElement(children: .contain)
    }

    private var guideCard: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider()
            cardContent
            Divider()
            cardFooter
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 20, y: 8)
    }

    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("PEEK 新手教程"))
                        .font(.headline)
                    Text(L10n.tr("用几分钟了解每一项核心功能"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(L10n.tr("跳过教程")) {
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ProgressView(
                    value: Double(currentStep.rawValue + 1),
                    total: Double(OnboardingGuideStep.allCases.count)
                )
                .progressViewStyle(.linear)
                Text(
                    L10n.tr(
                        "第 %d 步，共 %d 步",
                        currentStep.rawValue + 1,
                        OnboardingGuideStep.allCases.count
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var cardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                destinationIndicator
                stepHero
                guidanceCard
                ForEach(currentStep.tips) { tip in
                    tipRow(tip)
                }
            }
            .id(currentStep.id)
            .transition(reduceMotion ? .identity : .opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var destinationIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
            Text(L10n.tr("当前指引位置"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(currentStep.destination.title, systemImage: currentStep.destination.systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var stepHero: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: currentStep.systemImage)
                .font(.system(size: 25, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(currentStep.color)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(currentStep.color.opacity(0.12))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentStep.title)
                    .font(.title3.weight(.semibold))

                if let shortcut = currentStep.shortcut {
                    Text(L10n.tr("默认 %@", shortcut))
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(currentStep.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var guidanceCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("跟着做"))
                    .font(.subheadline.weight(.semibold))
                Text(currentStep.guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if currentStep == .search {
                    Button {
                        onAuthorizeDocuments()
                    } label: {
                        Label(
                            L10n.tr("授权文档搜索目录"),
                            systemImage: "folder.badge.plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.38), lineWidth: 1)
        }
    }

    private func tipRow(_ tip: OnboardingGuideTip) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: tip.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.subheadline.weight(.semibold))
                Text(tip.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var cardFooter: some View {
        HStack(spacing: 10) {
            Button(L10n.tr("上一步")) {
                move(by: -1)
            }
            .buttonStyle(.bordered)
            .disabled(currentStep == .welcome)

            Spacer(minLength: 8)

            if currentStep == .complete {
                Button(L10n.tr("完成教程")) {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.tr("下一步")) {
                    move(by: 1)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func targetHighlight(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func guideArrow(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)

            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 10
            let arrowSpread: CGFloat = .pi / 6
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - arrowLength * cos(angle - arrowSpread),
                y: end.y - arrowLength * sin(angle - arrowSpread)
            ))
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - arrowLength * cos(angle + arrowSpread),
                y: end.y - arrowLength * sin(angle + arrowSpread)
            ))
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func normalizedTarget(_ rect: CGRect?, in size: CGSize) -> CGRect? {
        guard let rect, rect.width > 1, rect.height > 1 else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.insetBy(dx: -7, dy: -7).intersection(bounds.insetBy(dx: 4, dy: 4))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    private func guidePlacement(in size: CGSize, target: CGRect?) -> OnboardingGuidePlacement {
        let bounds = CGRect(origin: .zero, size: size)
        let safeBounds = bounds.insetBy(dx: 18, dy: 18)
        let width = max(1, min(390, safeBounds.width))
        let height = max(1, min(390, safeBounds.height))
        let cardSize = CGSize(width: width, height: height)

        guard let target else {
            let frame = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
            return OnboardingGuidePlacement(cardFrame: frame, arrowStart: nil, arrowEnd: nil)
        }

        let gap: CGFloat = 30
        let available: [(side: Int, space: CGFloat)] = [
            (0, target.minX - safeBounds.minX),
            (1, safeBounds.maxX - target.maxX),
            (2, target.minY - safeBounds.minY),
            (3, safeBounds.maxY - target.maxY)
        ].sorted { $0.space > $1.space }

        var selectedFrame: CGRect?
        for candidate in available {
            let proposed: CGRect
            switch candidate.side {
            case 0:
                let candidateWidth = min(width, max(0, candidate.space - gap))
                guard candidateWidth >= min(300, safeBounds.width) else { continue }
                proposed = CGRect(
                    x: target.minX - gap - candidateWidth,
                    y: target.midY - height / 2,
                    width: candidateWidth,
                    height: height
                )
            case 1:
                let candidateWidth = min(width, max(0, candidate.space - gap))
                guard candidateWidth >= min(300, safeBounds.width) else { continue }
                proposed = CGRect(
                    x: target.maxX + gap,
                    y: target.midY - height / 2,
                    width: candidateWidth,
                    height: height
                )
            case 2:
                let candidateHeight = min(height, max(0, candidate.space - gap))
                guard candidateHeight >= min(260, safeBounds.height) else { continue }
                proposed = CGRect(
                    x: target.midX - width / 2,
                    y: target.minY - gap - candidateHeight,
                    width: width,
                    height: candidateHeight
                )
            default:
                let candidateHeight = min(height, max(0, candidate.space - gap))
                guard candidateHeight >= min(260, safeBounds.height) else { continue }
                proposed = CGRect(
                    x: target.midX - width / 2,
                    y: target.maxY + gap,
                    width: width,
                    height: candidateHeight
                )
            }

            let clamped = clamp(proposed, to: safeBounds)
            if !clamped.intersects(target.insetBy(dx: -10, dy: -10)) {
                selectedFrame = clamped
                break
            }
        }

        let frame = selectedFrame ?? farthestCornerFrame(
            cardSize: cardSize,
            safeBounds: safeBounds,
            from: target
        )
        guard !frame.intersects(target) else {
            return OnboardingGuidePlacement(cardFrame: frame, arrowStart: nil, arrowEnd: nil)
        }

        let start = nearestPoint(in: frame, to: CGPoint(x: target.midX, y: target.midY))
        let end = nearestPoint(in: target, to: CGPoint(x: frame.midX, y: frame.midY))
        return OnboardingGuidePlacement(cardFrame: frame, arrowStart: start, arrowEnd: end)
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
            y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)),
            width: min(rect.width, bounds.width),
            height: min(rect.height, bounds.height)
        )
    }

    private func farthestCornerFrame(
        cardSize: CGSize,
        safeBounds: CGRect,
        from target: CGRect
    ) -> CGRect {
        let frames = [
            CGRect(origin: safeBounds.origin, size: cardSize),
            CGRect(
                x: safeBounds.maxX - cardSize.width,
                y: safeBounds.minY,
                width: cardSize.width,
                height: cardSize.height
            ),
            CGRect(
                x: safeBounds.minX,
                y: safeBounds.maxY - cardSize.height,
                width: cardSize.width,
                height: cardSize.height
            ),
            CGRect(
                x: safeBounds.maxX - cardSize.width,
                y: safeBounds.maxY - cardSize.height,
                width: cardSize.width,
                height: cardSize.height
            )
        ]
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        return frames.max { lhs, rhs in
            squaredDistance(from: lhs, to: targetCenter)
                < squaredDistance(from: rhs, to: targetCenter)
        } ?? frames[0]
    }

    private func squaredDistance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    private func nearestPoint(in rect: CGRect, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func reportCurrentTarget() {
        onNavigate(currentStep.destination)
        onTargetChange(currentStep.target)
    }

    private func move(by offset: Int) {
        let target = min(
            max(currentStep.rawValue + offset, 0),
            OnboardingGuideStep.allCases.count - 1
        )
        guard
            let nextStep = OnboardingGuideStep(rawValue: target),
            nextStep != currentStep
        else { return }

        if reduceMotion {
            currentStep = nextStep
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                currentStep = nextStep
            }
        }
    }
}
