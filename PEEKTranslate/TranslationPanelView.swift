import AppKit
import OSLog
import SwiftUI
@preconcurrency import Translation

struct TranslationPanelRootView: View {
    let onClose: () -> Void

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                TranslationPanelAvailableView(onClose: onClose)
            } else {
                TranslationPanelUnavailableView(onClose: onClose)
            }
        }
        .frame(
            minWidth: TranslationPanelLayout.minimumWidth,
            minHeight: TranslationPanelLayout.minimumHeight
        )
        .accessibilityIdentifier("translation.panel.root")
    }
}

@available(macOS 15.0, *)
private struct TranslationPanelAvailableView: View {
    private struct PendingRequest: Sendable {
        let generation: Int
        let text: String
        let sourceIdentifier: String?
        let targetIdentifier: String
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shawnshoper.peek",
        category: "Translation"
    )

    let onClose: () -> Void

    @State private var sourceText = ""
    @State private var translatedText = ""
    @State private var sourceChoice = TranslationLanguageChoice.automatic
    @State private var targetChoice = TranslationLanguageChoice.system
    @State private var supportedLanguages: [TranslationLanguageDescriptor] = []
    @State private var detectedSourceIdentifier: String?
    @State private var resolvedTargetIdentifier: String?
    @State private var phase = TranslationPanelPhase.idle
    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingRequest: PendingRequest?
    @State private var translationGeneration = 0
    @State private var preparationTask: Task<Void, Never>?
    @State private var availabilityTimeoutTask: Task<Void, Never>?
    @State private var activationTimeoutTask: Task<Void, Never>?
    @State private var translationTimeoutTask: Task<Void, Never>?
    @State private var sessionActivationAttempt = 0
    @State private var activeLocalGeneration: Int?
    @State private var activeSessionToken: UUID?
    @State private var activeTranslationSession: TranslationSession?
    @State private var cloudTask: Task<Void, Never>?
    @State private var cloudPhases: [TranslationCloudProvider: TranslationCloudPhase] = [:]
    @State private var speechSynthesizer: NSSpeechSynthesizer?
    @State private var sourceIsFocused = true
    @State private var sourceIsComposing = false
    @State private var languageAvailability = LanguageAvailability()
    @ObservedObject private var hotKeyManager = ScreenshotGlobalHotKeyManager.shared
    @ObservedObject private var cloudSettings = TranslationCloudSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 14) {
                languageBar
                sourceCard
                Divider()
                resultArea
                    .layoutPriority(1)
                actionBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .background(Color.clear)
        .onExitCommand(perform: onClose)
        .task {
            await loadSupportedLanguages()
        }
        .onChange(of: sourceText) { newValue in
            let normalized = TranslationRequestPolicy.normalizedText(newValue)
            if normalized != newValue {
                sourceText = normalized
                return
            }
            refreshDetectedSourceLanguage()
            guard pendingRequest?.text != normalized || phase != .translating else { return }
            markTranslationStale()
        }
        .onChange(of: sourceIsComposing) { isComposing in
            guard isComposing else { return }
            markTranslationStale()
        }
        .onChange(of: sourceChoice) { _ in
            refreshDetectedSourceLanguage()
            markTranslationStale()
        }
        .onChange(of: targetChoice) { _ in markTranslationStale() }
        .onDisappear {
            preparationTask?.cancel()
            availabilityTimeoutTask?.cancel()
            activationTimeoutTask?.cancel()
            translationTimeoutTask?.cancel()
            cloudTask?.cancel()
            cancelSessionIfSupported(activeTranslationSession)
            activeTranslationSession = nil
            activeLocalGeneration = nil
            activeSessionToken = nil
            speechSynthesizer?.stopSpeaking()
            translationGeneration &+= 1
            pendingRequest = nil
            configuration = nil
        }
        .translationTask(configuration) { session in
            await translatePendingText(using: session)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            trafficLights
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text(L10n.tr("聚焦渐进式翻译"))
                .font(.system(size: 16, weight: .semibold))
            shortcutBadge(translationShortcutTitle)
            Spacer()
            shortcutBadge("esc")
            Button(L10n.tr("关闭"), action: onClose)
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("translation.close")
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private var trafficLights: some View {
        HStack(spacing: 9) {
            Button(action: onClose) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("关闭"))
            Circle().fill(Color(red: 1, green: 0.75, blue: 0.22))
                .frame(width: 12, height: 12)
            Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.35))
                .frame(width: 12, height: 12)
        }
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
    }

    private func shortcutBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.075))
            )
            .accessibilityHidden(true)
    }

    private var translationShortcutTitle: String {
        hotKeyManager.configuration.translation?.displayString ?? "—"
    }

    private var languageBar: some View {
        ZStack {
            HStack(spacing: 24) {
                sourceLanguageMenu
                Spacer(minLength: 74)
                targetLanguageMenu
            }
            Button(action: swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 42, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(detectedSourceIdentifier == nil || primaryTranslationText.isEmpty)
            .help(L10n.tr("交换语言"))
            .accessibilityIdentifier("translation.swap")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var sourceCard: some View {
        ZStack(alignment: .bottomLeading) {
            TranslationTextEditor(
                text: $sourceText,
                placeholder: L10n.tr("输入或粘贴需要翻译的文字"),
                shouldFocus: sourceIsFocused,
                onFocusChange: { sourceIsFocused = $0 },
                onCompositionChange: { sourceIsComposing = $0 },
                onSubmitTranslation: { submittedText in
                    submitTranslation(textOverride: submittedText)
                }
            )
            .padding(.bottom, 32)

            Text(characterCountText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 24)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
        .frame(minHeight: 176, maxHeight: 210)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    sourceIsFocused ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.12),
                    lineWidth: sourceIsFocused ? 1.5 : 1
                )
        }
        .animation(.easeInOut(duration: 0.14), value: sourceIsFocused)
    }

    private var resultArea: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    appleResultCard(
                        minimumHeight: cloudSettings.configuredProviders.isEmpty
                            ? max(166, proxy.size.height - 2)
                            : 166
                    )
                    ForEach(cloudSettings.configuredProviders) { provider in
                        cloudResultCard(provider)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(minHeight: 168)
    }

    private func appleResultCard(minimumHeight: CGFloat) -> some View {
        resultCardShell(
            title: L10n.tr("Apple 本地翻译"),
            badge: L10n.tr("本机"),
            systemImage: "apple.logo",
            minimumHeight: minimumHeight
        ) {
            if let requirement = phase.languagePackRequirement {
                languagePackMissingView(requirement)
            } else {
                translationContent(
                    text: translatedText,
                    placeholder: translatedPlaceholder,
                    statusText: statusText,
                    statusColor: statusColor,
                    isLoading: phase == .translating || phase == .waiting,
                    retryAction: phase.isRetryableFailure
                        ? { submitTranslation() }
                        : nil
                )
            }
        }
    }

    private func cloudResultCard(_ provider: TranslationCloudProvider) -> some View {
        let cloudPhase = cloudPhases[provider] ?? .idle
        return resultCardShell(
            title: provider.title,
            badge: L10n.tr("云端"),
            systemImage: provider.systemImage,
            minimumHeight: 166
        ) {
            translationContent(
                text: cloudPhase.output ?? "",
                placeholder: cloudPlaceholder(cloudPhase),
                statusText: cloudStatusText(cloudPhase),
                statusColor: cloudStatusColor(cloudPhase),
                isLoading: cloudPhase == .translating
            )
        }
    }

    private func resultCardShell<Content: View>(
        title: String,
        badge: String,
        systemImage: String,
        minimumHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.065))
                    )
                Spacer()
            }
            content()
        }
        .frame(
            maxWidth: .infinity,
            minHeight: max(0, minimumHeight - 32),
            alignment: .topLeading
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.026))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.105), lineWidth: 1)
        }
    }

    private func translationContent(
        text: String,
        placeholder: String,
        statusText: String,
        statusColor: Color,
        isLoading: Bool,
        retryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: 24, weight: .semibold))
                .lineSpacing(5)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)

            Spacer(minLength: 12)

            HStack(spacing: 9) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let retryAction {
                    Button(L10n.tr("重试"), action: retryAction)
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var characterCountText: String {
        let count = sourceText.count.formatted(.number.grouping(.automatic))
        let maximum = TranslationRequestPolicy.maximumCharacterCount
            .formatted(.number.grouping(.automatic))
        return "\(count)/\(maximum)"
    }

    private func languagePackMissingView(
        _ requirement: TranslationLanguagePackRequirement
    ) -> some View {
        let sourceName = requirement.sourceIdentifier.map {
            TranslationLanguagePresentation.localizedName(for: $0)
        } ?? L10n.tr("自动检测")
        let targetName = TranslationLanguagePresentation.localizedName(
            for: requirement.targetIdentifier
        )
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("尚未安装所需语言包"))
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.tr("%@ → %@ 语言包尚未安装", sourceName, targetName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("你可以继续输入。安装完成后重新打开 PEEK 翻译即可继续。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 9) {
                    Button(L10n.tr("打开系统设置"), action: openTranslationSettings)
                        .buttonStyle(.borderedProminent)
                    Button(L10n.tr("重新检查")) { submitTranslation() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton(
                title: L10n.tr("粘贴"),
                systemImage: "doc.on.clipboard",
                shortcut: "⌘V",
                action: pasteSourceText
            )
            .keyboardShortcut("v", modifiers: [.command])

            actionButton(
                title: L10n.tr("复制译文"),
                systemImage: "doc.on.doc",
                shortcut: "⌘C",
                enabled: !primaryTranslationText.isEmpty,
                action: copyTranslation
            )
            .keyboardShortcut("c", modifiers: [.command])

            actionButton(
                title: L10n.tr("翻译"),
                systemImage: "arrow.right.circle.fill",
                shortcut: "⌘↩",
                primary: true,
                enabled: TranslationRequestPolicy.shouldSubmit(
                    text: sourceText,
                    pendingText: pendingRequest?.text,
                    isTranslating: phase == .translating
                ),
                action: { submitTranslation() }
            )
            .keyboardShortcut(.return, modifiers: [.command])

            actionButton(
                title: L10n.tr("朗读"),
                systemImage: "speaker.wave.2",
                shortcut: "⌘R",
                enabled: !primaryTranslationText.isEmpty,
                action: speakTranslation
            )
            .keyboardShortcut("r", modifiers: [.command])

            targetLanguageActionMenu
        }
        .padding(4)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        shortcut: String,
        primary: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TranslationPanelActionLabel(
                title: title,
                systemImage: systemImage,
                shortcut: shortcut,
                primary: primary
            )
        }
        .buttonStyle(TranslationPanelActionButtonStyle())
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
    }

    private var sourceLanguageMenu: some View {
        Menu {
            Button {
                sourceChoice = .automatic
            } label: {
                languageMenuLabel(L10n.tr("自动检测"), selected: sourceChoice == .automatic)
            }
            Divider()
            ForEach(supportedLanguages) { language in
                Button {
                    sourceChoice = .language(language.identifier)
                } label: {
                    languageMenuLabel(
                        language.displayName,
                        selected: sourceChoice == .language(language.identifier)
                    )
                }
            }
        } label: {
            Text(sourceLanguageMenuTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(L10n.tr("源语言"))
    }

    private var targetLanguageMenu: some View {
        Menu {
            Button {
                targetChoice = .system
            } label: {
                languageMenuLabel(L10n.tr("跟随系统"), selected: targetChoice == .system)
            }
            Divider()
            ForEach(supportedLanguages) { language in
                Button {
                    targetChoice = .language(language.identifier)
                } label: {
                    languageMenuLabel(
                        language.displayName,
                        selected: targetChoice == .language(language.identifier)
                    )
                }
            }
        } label: {
            Text(targetLanguageMenuTitle)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(L10n.tr("目标语言"))
    }

    private var targetLanguageActionMenu: some View {
        Menu {
            Button { targetChoice = .system } label: {
                languageMenuLabel(L10n.tr("跟随系统"), selected: targetChoice == .system)
            }
            Divider()
            ForEach(supportedLanguages) { language in
                Button { targetChoice = .language(language.identifier) } label: {
                    languageMenuLabel(
                        language.displayName,
                        selected: targetChoice == .language(language.identifier)
                    )
                }
            }
        } label: {
            TranslationPanelActionLabel(
                title: L10n.tr("更多语言"),
                systemImage: "globe",
                shortcut: "⌘L",
                primary: false
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.tr("更多语言"))
    }

    @ViewBuilder
    private func languageMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private var targetLanguageTitle: String {
        switch targetChoice {
        case .system:
            return TranslationLanguagePresentation.localizedName(
                for: TranslationLanguagePresentation.systemTargetIdentifier
            )
        case .language(let identifier):
            return TranslationLanguagePresentation.localizedName(for: identifier)
        case .automatic:
            return L10n.tr("跟随系统")
        }
    }

    private var sourceLanguageMenuTitle: String {
        let prefix = sourceChoice == .automatic ? L10n.tr("自动检测") : L10n.tr("源语言")
        return "\(prefix) · \(sourceLanguageTitle)"
    }

    private var targetLanguageMenuTitle: String {
        "\(L10n.tr("翻译为")) · \(targetLanguageTitle)"
    }

    private var sourceLanguageTitle: String {
        switch sourceChoice {
        case .automatic:
            guard let detectedSourceIdentifier else { return L10n.tr("待识别") }
            return TranslationLanguagePresentation.localizedName(for: detectedSourceIdentifier)
        case .language(let identifier):
            return TranslationLanguagePresentation.localizedName(for: identifier)
        case .system:
            return TranslationLanguagePresentation.localizedName(
                for: TranslationLanguagePresentation.systemTargetIdentifier
            )
        }
    }

    private var primaryTranslationText: String {
        if !translatedText.isEmpty { return translatedText }
        for provider in cloudSettings.configuredProviders {
            if let output = cloudPhases[provider]?.output, !output.isEmpty { return output }
        }
        return ""
    }

    private var translatedPlaceholder: String {
        switch phase {
        case .failed(let message): return message
        case .unavailable: return L10n.tr("当前语言组合暂不支持")
        case .languagePackMissing: return L10n.tr("尚未安装所需语言包")
        case .stale: return L10n.tr("原文或语言已修改，按 ⌘↩ 重新翻译")
        default: return L10n.tr("译文会显示在这里")
        }
    }

    private var statusColor: Color {
        switch phase {
        case .failed, .unavailable, .languagePackMissing: return .orange
        case .translating, .waiting: return .blue
        case .stale: return .secondary
        default: return .green
        }
    }

    private var statusText: String {
        switch phase {
        case .waiting: return L10n.tr("等待输入完成…")
        case .translating: return L10n.tr("正在翻译…")
        case .translated: return L10n.tr("在本机完成翻译")
        case .unchanged: return L10n.tr("源语言与目标语言一致，已保留原文")
        case .languagePackMissing: return L10n.tr("语言包尚未安装")
        case .failed: return L10n.tr("翻译失败")
        case .unavailable: return L10n.tr("当前语言组合不可用")
        case .stale: return L10n.tr("按 ⌘↩ 开始翻译")
        case .idle: return L10n.tr("输入文字后按 ⌘↩ 开始翻译")
        }
    }

    private func cloudPlaceholder(_ cloudPhase: TranslationCloudPhase) -> String {
        if case .failed(let message) = cloudPhase { return message }
        return L10n.tr("译文会显示在这里")
    }

    private func cloudStatusText(_ cloudPhase: TranslationCloudPhase) -> String {
        switch cloudPhase {
        case .idle: return L10n.tr("输入文字后按 ⌘↩ 开始翻译")
        case .translating: return L10n.tr("正在通过云端翻译…")
        case .translated: return L10n.tr("云端翻译完成")
        case .failed: return L10n.tr("云端翻译失败")
        }
    }

    private func cloudStatusColor(_ cloudPhase: TranslationCloudPhase) -> Color {
        switch cloudPhase {
        case .failed: return .orange
        case .translating: return .blue
        default: return .green
        }
    }

    private func refreshDetectedSourceLanguage() {
        switch sourceChoice {
        case .automatic:
            detectedSourceIdentifier = TranslationLanguagePresentation
                .automaticSourceIdentifier(for: sourceText)
        case .language(let identifier):
            detectedSourceIdentifier = identifier
        case .system:
            detectedSourceIdentifier = TranslationLanguagePresentation.systemTargetIdentifier
        }
    }

    private func submitTranslation(textOverride: String? = nil) {
        let submittedText = TranslationRequestPolicy.normalizedText(textOverride ?? sourceText)
        if submittedText != sourceText {
            sourceText = submittedText
        }
        guard TranslationRequestPolicy.shouldSubmit(
            text: submittedText,
            pendingText: pendingRequest?.text,
            isTranslating: phase == .translating
        ) else {
            if !TranslationRequestPolicy.shouldTranslate(submittedText) {
                markTranslationStale()
            }
            return
        }

        cancelActiveRequest(preserveConfiguration: true, resetPhase: nil)
        let sourceIdentifier = resolvedSourceIdentifier(for: submittedText)
        let targetIdentifier = resolvedTargetIdentifier(for: sourceIdentifier)
        let request = PendingRequest(
            generation: translationGeneration,
            text: submittedText,
            sourceIdentifier: sourceIdentifier,
            targetIdentifier: targetIdentifier
        )
        pendingRequest = request
        activeLocalGeneration = request.generation
        detectedSourceIdentifier = request.sourceIdentifier
        resolvedTargetIdentifier = request.targetIdentifier
        translatedText = ""
        phase = .translating
        cloudPhases = Dictionary(
            uniqueKeysWithValues: cloudSettings.configuredProviders.map { ($0, .idle) }
        )
        Self.logger.debug(
            "Submit generation \(request.generation, privacy: .public), length \(request.text.count, privacy: .public)"
        )
        preparationTask = Task { @MainActor in
            await prepareTranslationIfAvailable(request)
        }
    }

    private func markTranslationStale() {
        cancelActiveRequest(preserveConfiguration: true, resetPhase: nil)
        translatedText = ""
        if !TranslationRequestPolicy.shouldTranslate(sourceText) {
            detectedSourceIdentifier = nil
        }
        cloudPhases = [:]
        phase = TranslationRequestPolicy.shouldTranslate(sourceText) ? .stale : .idle
    }

    private func prepareTranslationIfAvailable(_ request: PendingRequest) async {
        guard isCurrentLocalRequest(request) else { return }
        phase = .translating
        scheduleAvailabilityTimeout(for: request)

        let resolvedSourceIdentifier = request.sourceIdentifier
        let source = resolvedSourceIdentifier.map(Locale.Language.init(identifier:))
        let targetIdentifier = request.targetIdentifier
        let target = Locale.Language(identifier: targetIdentifier)
        detectedSourceIdentifier = resolvedSourceIdentifier
        resolvedTargetIdentifier = targetIdentifier

        if TranslationLanguageEquivalencePolicy.areEquivalent(
            sourceIdentifier: resolvedSourceIdentifier,
            targetIdentifier: targetIdentifier
        ) {
            availabilityTimeoutTask?.cancel()
            availabilityTimeoutTask = nil
            preparationTask = nil
            translatedText = request.text
            cloudPhases = [:]
            finishLocalRequest()
            phase = .unchanged
            Self.logger.debug(
                "Preserved source for equivalent language generation \(request.generation, privacy: .public)"
            )
            return
        }

        startCloudTranslations(
            request: request,
            sourceIdentifier: resolvedSourceIdentifier,
            targetIdentifier: targetIdentifier
        )

        let availabilityStatus: LanguageAvailability.Status
        do {
            if let source {
                availabilityStatus = await languageAvailability.status(from: source, to: target)
            } else {
                availabilityStatus = try await languageAvailability.status(for: request.text, to: target)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLocalRequest(request) else { return }
            finishLocalRequest()
            translatedText = ""
            phase = .failed(error.localizedDescription)
            Self.logger.error(
                "Availability failed for generation \(request.generation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        guard !Task.isCancelled, isCurrentLocalRequest(request) else { return }
        availabilityTimeoutTask?.cancel()
        availabilityTimeoutTask = nil
        preparationTask = nil

        switch TranslationAvailabilityPolicy.outcome(for: availabilityStatus) {
        case .ready:
            break
        case .requiresDownload:
            finishLocalRequest()
            translatedText = ""
            phase = .languagePackMissing(
                TranslationLanguagePackRequirement(
                    sourceIdentifier: source?.minimalIdentifier ?? resolvedSourceIdentifier,
                    targetIdentifier: targetIdentifier
                )
            )
            return
        case .unsupported:
            finishLocalRequest()
            translatedText = ""
            phase = .unavailable
            return
        }

        if var existing = configuration, existing.source == source, existing.target == target {
            existing.invalidate()
            configuration = existing
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        sessionActivationAttempt = 0
        scheduleActivationTimeout(for: request)
        Self.logger.debug(
            "Awaiting session generation \(request.generation, privacy: .public)"
        )
    }

    private func startCloudTranslations(
        request: PendingRequest,
        sourceIdentifier: String?,
        targetIdentifier: String
    ) {
        var configurations: [TranslationCloudConfiguration] = []
        for provider in cloudSettings.configuredProviders {
            do {
                if let configuration = try cloudSettings.configuration(for: provider) {
                    configurations.append(configuration)
                } else {
                    cloudPhases[provider] = .failed(L10n.tr("翻译服务配置不完整"))
                }
            } catch {
                cloudPhases[provider] = .failed(error.localizedDescription)
            }
        }
        guard !configurations.isEmpty else { return }
        for configuration in configurations {
            cloudPhases[configuration.provider] = .translating
        }
        cloudTask?.cancel()
        cloudTask = Task {
            await withTaskGroup(of: (TranslationCloudProvider, Result<String, Error>).self) { group in
                for cloudConfiguration in configurations {
                    group.addTask {
                        do {
                            let output = try await TranslationCloudClient.shared.translate(
                                text: request.text,
                                sourceIdentifier: sourceIdentifier,
                                targetIdentifier: targetIdentifier,
                                configuration: cloudConfiguration
                            )
                            return (cloudConfiguration.provider, .success(output))
                        } catch {
                            return (cloudConfiguration.provider, .failure(error))
                        }
                    }
                }
                for await (provider, result) in group {
                    guard !Task.isCancelled,
                          pendingRequest?.generation == request.generation,
                          sourceText == request.text else { continue }
                    switch result {
                    case .success(let output): cloudPhases[provider] = .translated(output)
                    case .failure(let error): cloudPhases[provider] = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func translatePendingText(using session: TranslationSession) async {
        guard let request = await MainActor.run(body: { pendingRequest }),
              await MainActor.run(body: { isCurrentLocalRequest(request) }) else { return }
        let sessionToken = UUID()
        let shouldStart = await MainActor.run {
            guard isCurrentLocalRequest(request) else { return false }
            activationTimeoutTask?.cancel()
            activationTimeoutTask = nil
            if activeSessionToken != nil {
                cancelSessionIfSupported(activeTranslationSession)
            }
            activeSessionToken = sessionToken
            activeTranslationSession = session
            scheduleTranslationTimeout(for: request, sessionToken: sessionToken)
            Self.logger.debug(
                "Session started generation \(request.generation, privacy: .public)"
            )
            return true
        }
        guard shouldStart else { return }
        do {
            let response = try await session.translate(request.text)
            await MainActor.run {
                guard isCurrentLocalRequest(request), activeSessionToken == sessionToken else {
                    return
                }
                finishLocalRequest(sessionToken: sessionToken)
                translatedText = response.targetText
                if sourceChoice == .automatic {
                    detectedSourceIdentifier = TranslationResponseLanguagePolicy.sourceIdentifier(
                        submittedIdentifier: request.sourceIdentifier,
                        responseIdentifier: response.sourceLanguage.minimalIdentifier
                    )
                }
                resolvedTargetIdentifier = TranslationResponseLanguagePolicy.targetIdentifier(
                    submittedIdentifier: request.targetIdentifier,
                    responseIdentifier: response.targetLanguage.minimalIdentifier
                )
                phase = .translated
                Self.logger.debug(
                    "Completed generation \(request.generation, privacy: .public)"
                )
            }
        } catch is CancellationError {
            await MainActor.run {
                guard isCurrentLocalRequest(request), activeSessionToken == sessionToken else {
                    return
                }
                finishLocalRequest(sessionToken: sessionToken)
                translatedText = ""
                phase = .failed(L10n.tr("翻译已中断，请重试"))
            }
            return
        } catch {
            await MainActor.run {
                guard isCurrentLocalRequest(request), activeSessionToken == sessionToken else {
                    return
                }
                finishLocalRequest(sessionToken: sessionToken)
                translatedText = ""
                phase = .failed(error.localizedDescription)
                Self.logger.error(
                    "Translation failed generation \(request.generation, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func isCurrentLocalRequest(_ request: PendingRequest) -> Bool {
        activeLocalGeneration == request.generation
            && TranslationRequestPolicy.isCurrent(
                requestGeneration: request.generation,
                requestText: request.text,
                currentGeneration: translationGeneration,
                currentText: sourceText
            )
    }

    private func resolvedSourceIdentifier(for text: String) -> String? {
        switch sourceChoice {
        case .automatic:
            return TranslationLanguagePresentation.automaticSourceIdentifier(for: text)
        case .language(let identifier):
            return identifier
        case .system:
            return TranslationLanguagePresentation.systemTargetIdentifier
        }
    }

    private func resolvedTargetIdentifier(for sourceIdentifier: String?) -> String {
        switch targetChoice {
        case .language(let identifier):
            return identifier
        case .system, .automatic:
            return TranslationLanguagePresentation.automaticTargetIdentifier(
                sourceIdentifier: sourceIdentifier,
                preferredTargetIdentifier: TranslationLanguagePresentation.systemTargetIdentifier
            )
        }
    }

    private func cancelActiveRequest(
        preserveConfiguration: Bool,
        resetPhase: TranslationPanelPhase?
    ) {
        preparationTask?.cancel()
        preparationTask = nil
        availabilityTimeoutTask?.cancel()
        availabilityTimeoutTask = nil
        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        translationTimeoutTask?.cancel()
        translationTimeoutTask = nil
        cloudTask?.cancel()
        cloudTask = nil
        activeLocalGeneration = nil
        cancelSessionIfSupported(activeTranslationSession)
        activeTranslationSession = nil
        activeSessionToken = nil
        translationGeneration &+= 1
        pendingRequest = nil
        if !preserveConfiguration { configuration = nil }
        if let resetPhase { phase = resetPhase }
    }

    private func finishLocalRequest(sessionToken: UUID? = nil) {
        if let sessionToken, activeSessionToken != sessionToken { return }
        preparationTask?.cancel()
        preparationTask = nil
        availabilityTimeoutTask?.cancel()
        availabilityTimeoutTask = nil
        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
        translationTimeoutTask?.cancel()
        translationTimeoutTask = nil
        activeLocalGeneration = nil
        activeTranslationSession = nil
        activeSessionToken = nil
    }

    private func scheduleAvailabilityTimeout(for request: PendingRequest) {
        availabilityTimeoutTask?.cancel()
        availabilityTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: TranslationRequestPolicy.availabilityTimeoutNanoseconds
                )
            } catch {
                return
            }
            guard isCurrentLocalRequest(request), phase == .translating else { return }
            preparationTask?.cancel()
            preparationTask = nil
            activeLocalGeneration = nil
            availabilityTimeoutTask = nil
            translatedText = ""
            phase = .failed(L10n.tr("语言检查超时，请重试"))
            Self.logger.error(
                "Availability timeout generation \(request.generation, privacy: .public)"
            )
        }
    }

    private func scheduleActivationTimeout(for request: PendingRequest) {
        activationTimeoutTask?.cancel()
        activationTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: TranslationRequestPolicy.sessionActivationTimeoutNanoseconds
                )
            } catch {
                return
            }
            guard isCurrentLocalRequest(request), activeSessionToken == nil else { return }
            if sessionActivationAttempt == 0, var existing = configuration {
                sessionActivationAttempt = 1
                existing.invalidate()
                configuration = existing
                Self.logger.notice(
                    "Retrying session activation generation \(request.generation, privacy: .public)"
                )
                scheduleActivationTimeout(for: request)
                return
            }
            activeLocalGeneration = nil
            activationTimeoutTask = nil
            translatedText = ""
            phase = .failed(L10n.tr("翻译服务未响应，请重试"))
            Self.logger.error(
                "Session activation timeout generation \(request.generation, privacy: .public)"
            )
        }
    }

    private func scheduleTranslationTimeout(
        for request: PendingRequest,
        sessionToken: UUID
    ) {
        translationTimeoutTask?.cancel()
        translationTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: TranslationRequestPolicy.translationTimeoutNanoseconds
                )
            } catch {
                return
            }
            guard isCurrentLocalRequest(request), activeSessionToken == sessionToken else { return }
            cancelSessionIfSupported(activeTranslationSession)
            activeTranslationSession = nil
            activeSessionToken = nil
            activeLocalGeneration = nil
            translationTimeoutTask = nil
            translatedText = ""
            phase = .failed(L10n.tr("翻译超时，请重试"))
            Self.logger.error(
                "Translation timeout generation \(request.generation, privacy: .public)"
            )
        }
    }

    private func cancelSessionIfSupported(_ session: TranslationSession?) {
        if #available(macOS 26.0, *) {
            session?.cancel()
        }
    }

    private func loadSupportedLanguages() async {
        let languages = await languageAvailability.supportedLanguages
        supportedLanguages = TranslationLanguagePresentation.descriptors(
            for: languages.map(\.minimalIdentifier)
        )
    }

    private func openTranslationSettings() {
        if !NSWorkspace.shared.open(TranslationLanguageSettings.url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
        onClose()
    }

    private func swapLanguages() {
        let output = primaryTranslationText
        guard let detectedSourceIdentifier, !output.isEmpty else {
            NSSound.beep()
            return
        }
        let previousTargetIdentifier = resolvedTargetIdentifier
            ?? targetChoice.languageIdentifier
            ?? TranslationLanguagePresentation.systemTargetIdentifier
        sourceChoice = .language(previousTargetIdentifier)
        targetChoice = .language(detectedSourceIdentifier)
        sourceText = output
        translatedText = ""
        self.detectedSourceIdentifier = previousTargetIdentifier
        resolvedTargetIdentifier = detectedSourceIdentifier
    }

    private func pasteSourceText() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        sourceText = TranslationRequestPolicy.normalizedText(text)
        sourceIsFocused = true
    }

    private func copyTranslation() {
        let output = primaryTranslationText
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    private func speakTranslation() {
        let output = primaryTranslationText
        guard !output.isEmpty else { return }
        let synthesizer = speechSynthesizer ?? NSSpeechSynthesizer()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() } else { synthesizer.startSpeaking(output) }
        speechSynthesizer = synthesizer
    }
}

private struct TranslationPanelUnavailableView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                Text(L10n.tr("聚焦渐进式翻译"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("esc").font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("关闭"), action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            Divider()
            VStack(spacing: 16) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text(L10n.tr("本地翻译需要 macOS 15 或更高版本"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("升级系统后，PEEK 会使用 macOS 本地语言模型完成翻译，内容不会上传第三方服务。"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onExitCommand(perform: onClose)
    }
}

private struct TranslationPanelActionLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let primary: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(shortcut)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(primary ? Color.white.opacity(0.78) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(primary ? Color.white.opacity(0.1) : Color.primary.opacity(0.065))
                )
        }
        .foregroundStyle(primary ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(primary ? Color.accentColor.opacity(0.92) : Color.clear)
        )
    }
}

private struct TranslationPanelActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
