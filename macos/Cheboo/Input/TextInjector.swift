import AppKit
import CoreGraphics

/// Inserts arbitrary Unicode strings into whatever app currently has keyboard
/// focus.
///
/// The reliable cross-layout way to do this on macOS is via the general
/// pasteboard plus a synthesized ⌘V. The earlier approach —
/// `CGEventKeyboardSetUnicodeString` with a synthetic virtualKey of 0 — works
/// only when the focused app honors the attached Unicode string. Many apps
/// (including web inputs in Chromium and several IME-aware text fields)
/// instead translate the virtual key through the *current* keyboard layout,
/// so the moment the user switches to a Cyrillic / non-Latin layout
/// the synthetic events start typing "ф" instead of the actual transcript.
/// Pasteboard injection sidesteps the layout entirely.
///
/// We save and restore the previous pasteboard contents around the paste so
/// the user's clipboard isn't clobbered.
final class TextInjector {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private let pasteboard = NSPasteboard.general
    private let vKeyV: CGKeyCode = 9 // kVK_ANSI_V
    /// The original pasteboard contents from the *first* `type()` in a burst.
    /// Held until the trailing restore fires; rapid back-to-back injections
    /// (multiple finals within a single utterance) reuse this so the second
    /// `type()` doesn't snapshot the partial transcript we just pasted and
    /// then restore *that* to the user's clipboard.
    private var preservedSnapshot: [[NSPasteboard.PasteboardType: Data]]?
    private var pendingRestore: DispatchWorkItem?

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        // Only snapshot when there's no restore already in flight — otherwise
        // we'd capture our own paste as the "original" and lose the user's
        // real clipboard.
        if preservedSnapshot == nil {
            preservedSnapshot = snapshotPasteboard()
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendCommandV()
        // Slide the restore deadline forward each time so a burst of injects
        // collapses to a single restore at the end.
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.preservedSnapshot
            self.preservedSnapshot = nil
            self.pendingRestore = nil
            if let snapshot { self.restorePasteboard(snapshot) }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func sendCommandV() {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private func restorePasteboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        guard !snapshot.isEmpty else { return }
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
