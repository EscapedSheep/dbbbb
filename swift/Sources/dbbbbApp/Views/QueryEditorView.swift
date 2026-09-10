import SwiftUI
import AppKit

/// The query editor: a monospaced NSTextView with a 42px line-number gutter —
/// the layout the Electron reference draws with a separate `.line-numbers`
/// column. The gutter is a plain NSView pinned left of the scroll view and
/// redrawn on scroll and text changes (NSRulerView proved unreliable inside
/// NSViewRepresentable hosting; this setup is fully under our control).
struct QueryEditorView: NSViewRepresentable {
    @Environment(SessionStore.self) private var store

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> EditorContainerView {
        let container = EditorContainerView()
        let gutter = LineNumberGutterView()
        let textView = QueryNSTextView()
        let scroll = NSScrollView()

        textView.delegate = context.coordinator
        textView.font = AppFonts.mono(AppMetrics.editorFontSize)
        textView.textColor = NSColor(AppColors.text)
        textView.insertionPointColor = NSColor(AppColors.accent)
        textView.backgroundColor = NSColor(AppColors.bgPanel)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 20px line height over 13px type (reference .query-editor).
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = AppMetrics.editorLineHeight
        paragraph.maximumLineHeight = AppMetrics.editorLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: AppFonts.mono(AppMetrics.editorFontSize),
            .foregroundColor: NSColor(AppColors.text),
            .paragraphStyle: paragraph,
        ]
        textView.textContainerInset = NSSize(width: 12, height: 14)

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NSColor(AppColors.bgPanel)
        scroll.drawsBackground = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        container.install(gutter: gutter, scroll: scroll, textView: textView)
        textView.string = store.queryText
        textView.placeholder = Self.placeholder(for: store)
        context.coordinator.gutter = gutter
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        context.coordinator.store = store
        guard let textView = container.textView else { return }
        if textView.string != store.queryText, !context.coordinator.isEditing {
            textView.string = store.queryText
            container.gutter?.needsDisplay = true
        }
        let placeholder = Self.placeholder(for: store)
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        // The palette can flip with the appearance override; keep the view
        // colors pinned to the tokens.
        let background = NSColor(AppColors.bgPanel)
        if textView.backgroundColor != background {
            textView.backgroundColor = background
            textView.insertionPointColor = NSColor(AppColors.accent)
            textView.typingAttributes[.foregroundColor] = NSColor(AppColors.text)
            container.gutter?.needsDisplay = true
            container.scrollView?.backgroundColor = background
        }
    }

    /// Engine-aware hint, matching the reference editor's placeholder text.
    private static func placeholder(for store: SessionStore) -> String {
        if store.selectedSession?.profile.engine == .mongodb {
            switch store.mongoQueryMode {
            case .find: return "{ \"status\": \"ok\" }   —  ⌘Return to run"
            case .aggregate: return "[ { \"$match\": { \"status\": \"ok\" } } ]   —  ⌘Return to run"
            }
        }
        if store.selectedSession?.profile.engine == .bullmq {
            return "{ \"queue\": \"emails\", \"state\": \"failed\" }   —  ⌘Return to run"
        }
        return "select * from …   —  ⌘Return to run"
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var store: SessionStore
        weak var gutter: LineNumberGutterView?
        /// While the user types, textDidChange already pushed the text into
        /// the store; updateNSView must not write it back (cursor jump).
        var isEditing = false

        init(store: SessionStore) {
            self.store = store
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            store.queryText = textView.string
            gutter?.needsDisplay = true
        }
    }
}

/// NSTextView with a placeholder overlay (the reference editor's hint text).
final class QueryNSTextView: NSTextView {
    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = AppMetrics.editorLineHeight
        paragraph.maximumLineHeight = AppMetrics.editorLineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFonts.mono(AppMetrics.editorFontSize),
            .foregroundColor: NSColor(AppColors.textDisabled),
            .paragraphStyle: paragraph,
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width + 5,
                        y: textContainerInset.height),
            withAttributes: attributes)
    }
}

/// The horizontal stack: gutter (fixed 42px) + scroll view (rest). The gutter
/// observes the clip view's bounds so numbers track scrolling exactly.
final class EditorContainerView: NSView {
    private(set) weak var gutter: LineNumberGutterView?
    private(set) weak var scrollView: NSScrollView?
    private(set) weak var textView: QueryNSTextView?
    private var boundsObserver: NSObjectProtocol?

    func install(gutter: LineNumberGutterView, scroll: NSScrollView, textView: QueryNSTextView) {
        gutter.textView = textView
        gutter.frame = NSRect(x: 0, y: 0,
                              width: AppMetrics.editorGutterWidth, height: bounds.height)
        gutter.autoresizingMask = [.height]
        scroll.frame = NSRect(x: AppMetrics.editorGutterWidth, y: 0,
                              width: max(0, bounds.width - AppMetrics.editorGutterWidth),
                              height: bounds.height)
        scroll.autoresizingMask = [.width, .height]
        addSubview(gutter)
        addSubview(scroll)
        self.gutter = gutter
        self.scrollView = scroll
        self.textView = textView

        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak gutter] _ in
            Task { @MainActor in gutter?.needsDisplay = true }
        }
        // The observer targets this container's clip view, so its lifetime is
        // the container's; the weak gutter capture keeps the callback inert
        // past that.
    }
}

/// The line-number gutter: 12px mono numbers, right-aligned, disabled-gray on
/// the subtle background with a 1px right border (reference `.line-numbers`).
final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?

    /// NSTextView coordinates grow downward; flip so gutter math matches.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor(AppColors.bgSubtle).setFill()
        dirtyRect.fill()
        NSColor(AppColors.border).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFonts.mono(12),
            .foregroundColor: NSColor(AppColors.textDisabled),
        ]

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString

        var lineNumber = 1
        // Count newlines before the visible range to start numbering correctly.
        if characterRange.location > 0 {
            lineNumber += string.substring(to: characterRange.location)
                .components(separatedBy: "\n").count - 1
        }

        var glyphIndex = glyphRange.location
        var drewAny = false
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            let lineRect = layoutManager.boundingRect(forGlyphRange: lineRange, in: textContainer)
            let y = lineRect.minY + textView.textContainerInset.height - visibleRect.minY
            let label = String(lineNumber) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.maxX - 10 - size.width,
                            y: y + (AppMetrics.editorLineHeight - size.height) / 2),
                withAttributes: attributes)
            lineNumber += 1
            drewAny = true
            glyphIndex = NSMaxRange(lineRange)
        }

        // An empty document still has a line 1 (the reference gutter always
        // shows it); a trailing newline gives the empty tail line a number too.
        if !drewAny || string.hasSuffix("\n") {
            let extraRect = layoutManager.extraLineFragmentRect
            let y = (extraRect.isEmpty ? 0 : extraRect.minY)
                + textView.textContainerInset.height - visibleRect.minY
            let label = String(lineNumber) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: bounds.maxX - 10 - size.width,
                            y: y + (AppMetrics.editorLineHeight - size.height) / 2),
                withAttributes: attributes)
        }
    }
}
