import AppKit
import Combine

/// Borderless floating panel that shows interim transcript text near the
/// mouse cursor while dictation is active. Position can be anchored above
/// or below the cursor (configurable) and the user can drag the panel to
/// reposition it; once dragged, it sticks at the new spot for the rest of
/// the session — until the user changes the anchor setting, which re-arms
/// auto-positioning so the new preference takes effect on the next show.
///
/// All methods touch AppKit and must be invoked on the main thread; the type
/// is intentionally not `@MainActor` so it can be stored on non-isolated
/// owners (e.g. `DictationController`), which dispatch to main before calling.
final class HUDOverlay: NSObject, NSWindowDelegate {
    enum Anchor {
        case above
        case below
    }

    private var window: NSPanel?
    private var label: NSTextField?
    private var punctuateBox: NSButton?
    private var capitalizeBox: NSButton?
    private var restartButton: NSButton?
    private var anchor: Anchor = .above
    private let maxTailChars = 220
    /// Snapshot of the toggles when the current dictation session connected.
    /// Deepgram only reads these at connect time, so changing a checkbox
    /// mid-session is inert until we tear down and reconnect — we expose a
    /// restart button while the live values differ from this snapshot.
    private var appliedPunctuation: Bool = false
    private var appliedCapitalization: Bool = false
    /// Invoked when the user taps the restart-session button on the HUD.
    var onRestartRequested: (() -> Void)?
    /// Set once the user drags the HUD. Subsequent shows keep the dragged
    /// position instead of jumping back to the cursor.
    private var userPositioned = false
    /// True while we move the window programmatically, so the
    /// `windowDidMove` notification doesn't mistakenly mark it as
    /// user-positioned.
    private var isMovingProgrammatically = false

    private weak var settings: SettingsStore?
    private var cancellables: Set<AnyCancellable> = []

    func bind(settings: SettingsStore) {
        self.settings = settings
        cancellables.removeAll()
        // Reflect external changes (Settings window) back onto the HUD
        // checkboxes so the two surfaces stay in sync.
        settings.$autoPunctuation
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.punctuateBox?.state = value ? .on : .off
                self?.updateRestartButtonVisibility()
            }
            .store(in: &cancellables)
        settings.$autoCapitalization
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.capitalizeBox?.state = value ? .on : .off
                self?.updateRestartButtonVisibility()
            }
            .store(in: &cancellables)
    }

    /// Called by `DictationController` whenever a new Deepgram session is
    /// established — snapshots the toggle values that just took effect so the
    /// restart button can re-appear when they next diverge.
    func markSettingsApplied() {
        appliedPunctuation = settings?.autoPunctuation ?? false
        appliedCapitalization = settings?.autoCapitalization ?? false
        updateRestartButtonVisibility()
    }

    private func updateRestartButtonVisibility() {
        guard let settings, let restartButton else { return }
        let dirty = settings.autoPunctuation != appliedPunctuation
                  || settings.autoCapitalization != appliedCapitalization
        restartButton.isHidden = !dirty
    }

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
        label.stringValue = text.isEmpty ? "Listening…" : tail(text)
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 110),
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
        let blur = NSVisualEffectView(frame: contentRect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let lbl = NSTextField(wrappingLabelWithString: "Listening…")
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = .labelColor
        lbl.alignment = .left
        lbl.maximumNumberOfLines = 3
        lbl.lineBreakMode = .byWordWrapping
        // Reserve a strip at the bottom for the two checkboxes. The label
        // sits above that strip.
        let controlsHeight: CGFloat = 26
        lbl.frame = NSRect(
            x: 14,
            y: controlsHeight + 6,
            width: contentRect.width - 28,
            height: contentRect.height - controlsHeight - 16
        )
        lbl.autoresizingMask = [.width, .height]
        blur.addSubview(lbl)

        let punctBox = NSButton(
            checkboxWithTitle: "Punctuation",
            target: self,
            action: #selector(togglePunctuation(_:))
        )
        punctBox.font = .systemFont(ofSize: 11)
        punctBox.state = (settings?.autoPunctuation ?? false) ? .on : .off
        punctBox.sizeToFit()
        punctBox.frame.origin = NSPoint(x: 14, y: 6)
        punctBox.autoresizingMask = [.maxXMargin, .maxYMargin]
        blur.addSubview(punctBox)

        let capsBox = NSButton(
            checkboxWithTitle: "Capitalization",
            target: self,
            action: #selector(toggleCapitalization(_:))
        )
        capsBox.font = .systemFont(ofSize: 11)
        capsBox.state = (settings?.autoCapitalization ?? false) ? .on : .off
        capsBox.sizeToFit()
        capsBox.frame.origin = NSPoint(x: punctBox.frame.maxX + 16, y: 6)
        capsBox.autoresizingMask = [.maxXMargin, .maxYMargin]
        blur.addSubview(capsBox)

        let restartBtn = NSButton(
            title: "↻ Restart session",
            target: self,
            action: #selector(restartTapped(_:))
        )
        restartBtn.bezelStyle = .accessoryBarAction
        restartBtn.controlSize = .small
        restartBtn.font = .systemFont(ofSize: 11)
        restartBtn.sizeToFit()
        restartBtn.frame.origin = NSPoint(
            x: contentRect.width - restartBtn.frame.width - 14,
            y: 4
        )
        restartBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        restartBtn.isHidden = true
        blur.addSubview(restartBtn)

        panel.contentView = blur
        self.window = panel
        self.label = lbl
        self.punctuateBox = punctBox
        self.capitalizeBox = capsBox
        self.restartButton = restartBtn
    }

    @objc private func restartTapped(_ sender: NSButton) {
        onRestartRequested?()
    }

    @objc private func togglePunctuation(_ sender: NSButton) {
        settings?.autoPunctuation = (sender.state == .on)
    }

    @objc private func toggleCapitalization(_ sender: NSButton) {
        settings?.autoCapitalization = (sender.state == .on)
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
