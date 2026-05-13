import AppKit
import Combine

/// Borderless click-through panel that renders the current dictation text
/// like a film subtitle: a band across the bottom of the active screen,
/// styled with a configurable main color, outline (stroke) color, and drop
/// shadow. Intended for screencasts where the viewer should see what the
/// presenter is saying.
///
/// Behavior: everything spoken since the last clear stays on screen —
/// finals append into `committed`, the latest interim is shown alongside
/// them — until the user hits the clear-subtitles hotkey, which wipes
/// both buffers and hides the panel.
///
/// All methods touch AppKit and must run on the main thread. The type is
/// intentionally not `@MainActor` so it can be stored on non-isolated
/// owners; callers dispatch to main before invoking.
final class SubtitleOverlay: NSObject {
    private var window: NSPanel?
    private var label: NSTextField?
    private weak var settings: SettingsStore?
    private var cancellables: Set<AnyCancellable> = []

    /// Finalized text accumulated across utterances and stops. Cleared only
    /// by `clear()` (i.e. the user pressing the clear-subtitles hotkey).
    private var committed: String = ""
    /// The currently-streaming interim from Deepgram for the in-progress
    /// utterance. Replaced wholesale on each interim event; folded into
    /// `committed` on `commit(text:)`.
    private var interim: String = ""

    /// Soft cap on the visible character count. NSTextField with
    /// `maximumNumberOfLines = 3` would tail-truncate (cutting the *newest*
    /// words), which is the wrong direction for live subtitles — so we
    /// trim from the head ourselves with a leading ellipsis. The constant
    /// is sized generously for ~3 lines at default font/size; if the user
    /// overflows, NSTextField then truncates a few more chars at the end
    /// of the last line, which is acceptable.
    private static let tailCharBudget = 280

    func bind(settings: SettingsStore) {
        self.settings = settings
        cancellables.removeAll()
        // Re-render whenever any style knob changes — gives the user live
        // feedback while tweaking colors / font in Settings.
        let restyle: (Any) -> Void = { [weak self] _ in self?.applyStyle() }
        settings.$subtitleMainColor.sink(receiveValue: restyle).store(in: &cancellables)
        settings.$subtitleOutlineColor.sink(receiveValue: restyle).store(in: &cancellables)
        settings.$subtitleShadowColor.sink(receiveValue: restyle).store(in: &cancellables)
        settings.$subtitleFontFamily.sink(receiveValue: restyle).store(in: &cancellables)
        settings.$subtitleFontSize.sink(receiveValue: restyle).store(in: &cancellables)
        // Hiding the overlay when subtitle mode toggles off keeps stale
        // captions from sticking around after the user turns the feature
        // off mid-recording.
        settings.$subtitleMode
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if !enabled { self?.hide() }
            }
            .store(in: &cancellables)
    }

    /// Bring the subtitle window forward without changing buffered text.
    /// Safe to call repeatedly.
    func show() {
        ensureWindow()
        applyStyle()
        positionAtBottom()
        window?.orderFrontRegardless()
    }

    /// Replace the in-progress interim line. Triggers a re-render.
    func setInterim(text: String) {
        interim = text
        if !text.isEmpty { show() }
        applyStyle()
    }

    /// Fold a finalized chunk into the committed buffer and clear the
    /// interim. Adds a space separator when needed.
    func commit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if committed.isEmpty {
                committed = trimmed
            } else {
                let needsSpace = !committed.hasSuffix(" ") && !committed.hasSuffix("\n")
                committed += (needsSpace ? " " : "") + trimmed
            }
        }
        interim = ""
        if !committed.isEmpty { show() }
        applyStyle()
    }

    /// Wipe both buffers and hide the panel. Invoked by the clear-subtitles
    /// hotkey.
    func clear() {
        committed = ""
        interim = ""
        window?.orderOut(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        // Width is set in positionAtBottom() once we know the screen. Use a
        // reasonable initial size so the window exists; final geometry is
        // applied before it's shown.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Float above full-screen presentations and screen-shared windows so
        // it shows up in screencasts.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Click-through: the presenter should still be able to click whatever
        // is under the subtitle band.
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let contentRect = panel.contentView!.bounds

        // `wrappingLabelWithString` gives us a label whose cell is set up
        // for multi-line wrapping out of the box; a plain `labelWithString`
        // would render single-line regardless of `wraps`.
        let lbl = NSTextField(wrappingLabelWithString: "")
        lbl.isBezeled = false
        lbl.isEditable = false
        lbl.drawsBackground = false
        lbl.alignment = .center
        lbl.maximumNumberOfLines = 3
        lbl.lineBreakMode = .byWordWrapping
        lbl.cell?.wraps = true
        lbl.cell?.isScrollable = false
        lbl.translatesAutoresizingMaskIntoConstraints = true
        lbl.frame = contentRect.insetBy(dx: 60, dy: 12)
        lbl.autoresizingMask = [.width, .height]

        panel.contentView?.addSubview(lbl)

        self.window = panel
        self.label = lbl
    }

    private func renderedText() -> String {
        let combined: String
        if interim.isEmpty {
            combined = committed
        } else if committed.isEmpty {
            combined = interim
        } else {
            let needsSpace = !committed.hasSuffix(" ") && !committed.hasSuffix("\n")
            combined = committed + (needsSpace ? " " : "") + interim
        }
        return tail(combined)
    }

    /// Keep only the trailing `tailCharBudget` characters; longer strings
    /// get a leading ellipsis so the latest words remain visible.
    private func tail(_ s: String) -> String {
        let budget = Self.tailCharBudget
        if s.count <= budget { return s }
        let start = s.index(s.endIndex, offsetBy: -budget)
        return "…" + s[start...]
    }

    private func applyStyle() {
        guard let label, let settings else { return }

        let fontSize = CGFloat(settings.subtitleFontSize)
        let font = NSFont(name: settings.subtitleFontFamily, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let main = NSColor(hexString: settings.subtitleMainColor) ?? .white
        let outline = NSColor(hexString: settings.subtitleOutlineColor) ?? .black
        let shadowColor = NSColor(hexString: settings.subtitleShadowColor) ?? NSColor.black.withAlphaComponent(0.7)

        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        // Offset and blur scale loosely with font size so the look stays
        // consistent across sizes.
        let blur = max(2, fontSize * 0.12)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize * 0.04))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        // Negative stroke width tells AppKit to both stroke *and* fill the
        // glyph — so we get an outline behind the main color. Value is a
        // percentage of font size.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: main,
            .strokeColor: outline,
            .strokeWidth: -4.0,
            .shadow: shadow,
            .paragraphStyle: paragraph,
            .kern: 0.2
        ]

        label.attributedStringValue = NSAttributedString(string: renderedText(), attributes: attrs)
    }

    private func positionAtBottom() {
        guard let window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        // Subtitle band: 90% of screen width, centered, hugging the bottom
        // with a small gap. Height roomy enough for three lines plus
        // breathing room.
        let width = frame.width * 0.9
        let height = max(220, CGFloat(settings?.subtitleFontSize ?? 38) * 4.5)
        let origin = NSPoint(
            x: frame.minX + (frame.width - width) / 2,
            y: frame.minY + frame.height * 0.06
        )
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}

extension NSColor {
    /// Parse "#RRGGBB" or "#RRGGBBAA" (with or without leading `#`).
    /// Returns nil on malformed input.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >>  8) & 0xFF) / 255
            a = CGFloat( value        & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >>  8) & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Serialize to "#RRGGBBAA" in sRGB. Falls back to white on conversion
    /// failure (which only happens for very exotic color spaces).
    var hexStringRGBA: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FFFFFFFF" }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        let a = Int((rgb.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
