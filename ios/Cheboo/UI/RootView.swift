import SwiftData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Transcript.createdAt, order: .reverse) private var recents: [Transcript]

    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showOnboarding = false
    @State private var showCopyToast = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color.accentColor.opacity(0.05),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    transcriptArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    micArea
                        .padding(.bottom, 12)

                    recentArea
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Cheboo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack { HistoryView() }
            }
            .sheet(isPresented: $showOnboarding) {
                NavigationStack { SettingsView(onboarding: true) }
                    .interactiveDismissDisabled(settings.apiKey.isEmpty)
            }
            .overlay(alignment: .top) {
                if showCopyToast {
                    Toast(text: "Copied")
                        .padding(.top, 8)
                }
            }
            .onAppear {
                if settings.apiKey.isEmpty { showOnboarding = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cheboorequestStartDictation)) { _ in
                guard !dictation.isActive else { return }
                triggerToggle()
            }
        }
    }

    // MARK: - Transcript area

    private var transcriptArea: some View {
        Group {
            if dictation.isActive {
                LiveTranscriptView(
                    interim: dictation.interimText,
                    finalized: dictation.finalizedText,
                    status: dictation.status,
                    elapsed: dictation.elapsed
                )
            } else if !dictation.finalizedText.isEmpty || !dictation.interimText.isEmpty {
                TranscriptEditorView(onCopy: { showToast() })
            } else {
                IdlePlaceholder()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dictation.isActive)
    }

    // MARK: - Mic area

    private var micArea: some View {
        VStack(spacing: 10) {
            if case .error(let message) = dictation.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .onTapGesture { dictation.dismissError() }
            } else if case .denied = dictation.status {
                Text("Microphone access denied. Enable in Settings → Cheboo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            MicButton(
                isRecording: micIsRecording,
                isConnecting: micIsConnecting,
                level: dictation.audioLevel
            ) {
                triggerToggle()
            }

            statusLabel
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 18)
        }
    }

    private var micIsRecording: Bool {
        if case .recording = dictation.status { return true }
        if case .finishing = dictation.status { return true }
        return false
    }

    private var micIsConnecting: Bool {
        if case .connecting = dictation.status { return true }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch dictation.status {
        case .recording:
            Text("Recording — tap to stop")
        case .connecting:
            Text("Connecting…")
        case .finishing:
            Text("Finishing…")
        case .idle:
            if !dictation.finalizedText.isEmpty {
                Text("Tap to record again")
            } else {
                Text("Tap to start")
            }
        case .denied:
            Text("Microphone needed")
        case .error:
            Text("Tap to retry")
        }
    }

    // MARK: - Recent strip

    private var recentArea: some View {
        Group {
            if !recents.isEmpty && !dictation.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("See all") { showHistory = true }
                            .font(.footnote)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recents.prefix(8)) { transcript in
                                RecentChip(transcript: transcript) {
                                    UIPasteboard.general.string = transcript.text
                                    showToast()
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Actions

    private func triggerToggle() {
        let saveToHistory = settings.saveToHistory
        dictation.toggle { text, duration in
            guard saveToHistory else { return }
            let entry = Transcript(text: text, durationSeconds: duration)
            modelContext.insert(entry)
            try? modelContext.save()
        }
    }

    private func showToast() {
        withAnimation { showCopyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { showCopyToast = false }
        }
    }
}

// MARK: - Live transcript

private struct LiveTranscriptView: View {
    let interim: String
    let finalized: String
    let status: DictationController.Status
    let elapsed: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(opacity)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: opacity)
                Text(timeString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                let isEmpty = finalized.isEmpty && interim.isEmpty
                Text(isEmpty ? placeholder : combined)
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.regularMaterial)
        )
        .padding(.vertical, 12)
    }

    private var combined: AttributedString {
        var result = AttributedString()
        if !finalized.isEmpty {
            var f = AttributedString(finalized)
            f.foregroundColor = .primary
            result.append(f)
        }
        if !interim.isEmpty {
            if !finalized.isEmpty { result.append(AttributedString(" ")) }
            var i = AttributedString(interim)
            i.foregroundColor = .secondary
            result.append(i)
        }
        return result
    }

    private var placeholder: AttributedString {
        var s = AttributedString("Listening…")
        s.foregroundColor = .secondary
        return s
    }

    private var opacity: Double {
        switch status {
        case .recording: return 1
        case .connecting, .finishing: return 0.4
        default: return 0.2
        }
    }

    private var timeString: String {
        let total = Int(elapsed)
        let m = total / 60
        let s = total % 60
        let ms = Int((elapsed - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}

// MARK: - Idle placeholder

private struct IdlePlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Speak to transcribe")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Streams to Deepgram Nova-3. Tap the mic, talk, tap again.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

// MARK: - Recent chip

private struct RecentChip: View {
    let transcript: Transcript
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 6) {
                Text(transcript.preview)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(transcript.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toast

private struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(.thickMaterial)
            )
            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
