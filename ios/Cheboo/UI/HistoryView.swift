import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcript.createdAt, order: .reverse) private var items: [Transcript]

    @State private var searchText = ""

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
    }

    private var filtered: [Transcript] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.text.lowercased().contains(query) }
    }

    private var list: some View {
        List {
            ForEach(filtered) { item in
                NavigationLink {
                    TranscriptDetailView(transcript: item)
                } label: {
                    row(for: item)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.insetGrouped)
    }

    private func row(for item: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.preview)
                .font(.body)
                .lineLimit(3)
            HStack(spacing: 8) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(durationLabel(item.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No transcripts yet")
                .font(.headline)
            Text("Recordings you finish will show up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filtered[index])
        }
        try? modelContext.save()
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

private struct TranscriptDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var transcript: Transcript
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(transcript.createdAt.formatted(date: .complete, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $transcript.text)
                    .font(.system(.body, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                    )
            }
            .padding()
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = transcript.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        showShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        modelContext.delete(transcript)
                        try? modelContext.save()
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheetWrapper(items: [transcript.text])
        }
        .onDisappear {
            try? modelContext.save()
        }
    }
}

private struct ShareSheetWrapper: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
