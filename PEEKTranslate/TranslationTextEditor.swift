import AppKit
import SwiftUI

struct TranslationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let shouldFocus: Bool
    let onFocusChange: (Bool) -> Void
    let onCompositionChange: (Bool) -> Void
    let onSubmitTranslation: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TranslationTextEditorContainer {
        let view = TranslationTextEditorContainer()
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.placeholderLabel.stringValue = placeholder
        view.updateAppearance()
        return view
    }

    func updateNSView(_ view: TranslationTextEditorContainer, context: Context) {
        context.coordinator.parent = self
        if !view.textView.hasMarkedText(), view.textView.string != text {
            view.textView.string = text
        }
        view.placeholderLabel.stringValue = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        view.updateAppearance()

        guard shouldFocus,
              view.window?.firstResponder !== view.textView else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            view.window?.makeFirstResponder(view.textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationTextEditor

        init(parent: TranslationTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let isComposing = textView.hasMarkedText()
            parent.onCompositionChange(isComposing)
            guard !isComposing else { return }
            let normalized = TranslationRequestPolicy.normalizedText(textView.string)
            if textView.string != normalized {
                textView.string = normalized
            }
            parent.text = normalized
            (textView.enclosingScrollView?.superview as? TranslationTextEditorContainer)?
                .placeholderLabel.isHidden = !normalized.isEmpty
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onCompositionChange(false)
            parent.onFocusChange(false)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(.command) == true else {
                return false
            }

            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            let normalized = TranslationRequestPolicy.normalizedText(textView.string)
            if textView.string != normalized {
                textView.string = normalized
            }
            parent.text = normalized
            parent.onCompositionChange(false)
            parent.onSubmitTranslation(normalized)
            return true
        }
    }
}

final class TranslationTextEditorContainer: NSView {
    static let textInset = CGSize(width: 24, height: 12)
    static let font = NSFont.systemFont(ofSize: 22, weight: .regular)

    let scrollView = NSScrollView()
    let textView = NSTextView()
    let placeholderLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        placeholderLabel.textColor = .tertiaryLabelColor
    }

    private func configure() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.font
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.setAccessibilityLabel(L10n.tr("原文"))
        scrollView.documentView = textView

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Self.font
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.isSelectable = false
        placeholderLabel.isEditable = false
        placeholderLabel.setAccessibilityElement(false)

        addSubview(scrollView)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.textInset.width
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Self.textInset.width
            ),
            placeholderLabel.firstBaselineAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.textInset.height + Self.font.ascender
            )
        ])
    }
}
