import AppKit
import Combine

/// Borderless floating panel that shows interim transcript text near the
/// mouse cursor while dictation is active. Single line, black text on a
/// white background, no chrome or controls. Text starts at the leading
/// edge and grows rightward; once it can no longer fit, alignment flips
/// so the trailing edge stays anchored at the right and older content
/// slides off the left with a head ellipsis ("running line").
///
/// All methods touch AppKit and must be invoked on the main thread; the type
/// is intentionally not `@MainActor` so it can be stored on non-isolated
/// owners (e.g. `DictationController`), which dispatch to main before calling.
final class HUDOverlay: NSObject, NSWindowDelegate {
    enum Anchor {
        case above
        case below
    }

    /// Newlines are collapsed to this glyph (U+23CE RETURN SYMBOL) so the
    /// HUD stays single-line while still showing the user when a paragraph
    /// or hard break came through. Padded with spaces so it reads as a
    /// discrete token rather than glued to neighboring words.
    private static let returnGlyph = " ⏎ "

    private var window: NSPanel?
    private var label: NSTextField?
    private var anchor: Anchor = .above
    private let maxTailChars = 220
    /// Set once the user drags the HUD. Subsequent shows keep the dragged
    /// position instead of jumping back to the cursor.
    private var userPositioned = false
    /// True while we move the window programmatically, so the
    /// `windowDidMove` notification doesn't mistakenly mark it as
    /// user-positioned.
    private var isMovingProgrammatically = false

    private weak var settings: SettingsStore?

    /// Kept for source compatibility with the controller; the minimal HUD
    /// has no controls bound to settings, so this is a no-op.
    func bind(settings: SettingsStore) {
        self.settings = settings
    }

    /// Kept for source compatibility; nothing on the HUD needs to react to
    /// session restarts now that the controls are gone.
    func markSettingsApplied() {}

    func setAnchor(_ newAnchor: Anchor) {
        guard newAnchor != anchor else { return }
        anchor = newAnchor
        // Honoring the new setting on the next show means dropping any
        // sticky drag offset.
        userPositioned = false
    }

    func show(text: String) {
        ensureWindow()
        update(text: text)
        if !userPositioned {
            positionAtCursor()
        }
        window?.orderFrontRegardless()
    }

    func update(text: String) {
        guard let label else { return }
        let rendered = render(text)
        label.stringValue = rendered
        // Left-align while the text still fits so it grows from the leading
        // edge; once it overflows, switch to right so the most recent words
        // stay pinned at the trailing edge and the head ellipsis hides what
        // slid off the left.
        let font = label.font ?? .systemFont(ofSize: 15, weight: .medium)
        let textWidth = (rendered as NSString).size(withAttributes: [.font: font]).width
        label.alignment = textWidth > label.bounds.width ? .right : .left
    }

    /// Collapse newlines to ⏎ and tail-truncate so the most recent words
    /// always fit at the right edge. Empty input shows a discreet hint.
    private func render(_ s: String) -> String {
        if s.isEmpty { return "Listening…" }
        let oneLine = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: Self.returnGlyph)
        return tail(oneLine)
    }

    /// For very long live transcripts we only want the most recent slice
    /// visible — the latest words matter, the beginning has already scrolled
    /// out of attention. Truncate from the head with a leading ellipsis.
    private func tail(_ s: String) -> String {
        if s.count <= maxTailChars { return s }
        let start = s.index(s.endIndex, offsetBy: -maxTailChars)
        return "…" + s[start...]
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Mouse events have to flow so the user can grab and drag the panel;
        // `isMovableByWindowBackground` then makes a drag from anywhere on
        // the body reposition the window. `nonactivatingPanel` keeps it from
        // stealing keyboard focus from the app being dictated into.
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let contentRect = panel.contentView!.bounds
        let background = NSView(frame: contentRect)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.white.cgColor
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        let lbl = NSTextField(labelWithString: "Listening…")
        lbl.font = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = .black
        lbl.alignment = .left
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingHead
        lbl.usesSingleLineMode = true
        lbl.drawsBackground = false
        lbl.isBezeled = false
        lbl.isEditable = false
        // NSTextField does not vertically center its content in a taller
        // frame, so size the label to its single-line intrinsic height and
        // place it on the midline manually. Width flexes with the panel;
        // height stays fixed.
        let labelHeight = lbl.intrinsicContentSize.height
        lbl.frame = NSRect(
            x: 14,
            y: (contentRect.height - labelHeight) / 2,
            width: contentRect.width - 28,
            height: labelHeight
        )
        lbl.autoresizingMask = [.width]
        background.addSubview(lbl)

        panel.contentView = background
        self.window = panel
        self.label = lbl
    }

    private func positionAtCursor() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let height = window.frame.height
        let above = anchor == .above
        let yOffset: CGFloat = above ? 24 : -height - 24
        var origin = NSPoint(
            x: mouse.x - window.frame.width / 2,
            y: mouse.y + yOffset
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - window.frame.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - height - 8))
        }
        isMovingProgrammatically = true
        window.setFrameOrigin(origin)
        isMovingProgrammatically = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isMovingProgrammatically else { return }
        userPositioned = true
    }
}
