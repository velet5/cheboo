import SwiftData
import SwiftUI

/// Shown after a recording finishes. The dictation controller's
/// `finalizedText` is the source of truth on entry; the user can edit it,
/// then copy / share / save / discard.
struct TranscriptEditorView: View {
    @EnvironmentObject private var dictation: DictationController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcript.createdAt, order: .reverse) private var recents: [Transcript]

    let onCopy: () -> Void

    @State private var draft: String = ""
    @State private var hasInitialized = false
    @State private var showShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(draft.count) chars")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $draft)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.regularMaterial)
                )
                .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                actionButton("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = draft
                    onCopy()
                }
                actionButton("Share", systemImage: "square.and.arrow.up") {
                    showShare = true
                }
                actionButton("Discard", systemImage: "trash", role: .destructive) {
                    dictation.clearSession()
                }
            }
        }
        .padding(.vertical, 12)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            draft = dictation.finalizedText
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [draft])
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
