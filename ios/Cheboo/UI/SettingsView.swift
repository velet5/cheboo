import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var onboarding: Bool = false

    @State private var keyDraft: String = ""
    @State private var showKey = false
    @State private var newKeyterm = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Group {
                        if showKey {
                            TextField("dg-… key", text: $keyDraft)
                        } else {
                            SecureField("dg-… key", text: $keyDraft)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if !keyDraft.isEmpty {
                    Button(role: .destructive) {
                        keyDraft = ""
                    } label: {
                        Label("Clear key", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("Deepgram API key")
            } footer: {
                Text("Stored locally in Keychain. Get a key at console.deepgram.com.")
            }

            Section("Transcription") {
                Picker("Language", selection: $settings.languageMode) {
                    ForEach(LanguageMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Auto punctuation", isOn: $settings.autoPunctuation)
                Toggle("Smart formatting", isOn: $settings.autoCapitalization)
            }

            Section {
                Toggle("Save to history", isOn: $settings.saveToHistory)
            } footer: {
                Text("When off, finished transcripts aren't persisted.")
            }

            Section {
                HStack {
                    TextField("Add term…", text: $newKeyterm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onSubmit(addKeyterm)
                    Button("Add", action: addKeyterm)
                        .disabled(newKeyterm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(settings.keyterms, id: \.self) { term in
                    Text(term)
                }
                .onDelete { indexSet in
                    settings.keyterms.remove(atOffsets: indexSet)
                }
                if settings.keyterms != Keyterms.defaults {
                    Button("Reset to defaults") {
                        settings.keyterms = Keyterms.defaults
                    }
                }
            } header: {
                Text("Keyterms (\(settings.keyterms.count))")
            } footer: {
                Text("Up to 100 terms biased toward dev jargon. Sent at connection time only when the list is non-empty.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link("Deepgram Console", destination: URL(string: "https://console.deepgram.com")!)
            } header: {
                Text("About")
            }
        }
        .navigationTitle(onboarding ? "Welcome" : "Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(onboarding ? "Continue" : "Done") {
                    commit()
                    dismiss()
                }
                .disabled(onboarding && keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !onboarding {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            keyDraft = settings.apiKey
        }
        .onChange(of: keyDraft) { _, newValue in
            // Auto-save key as user types so dismissing via swipe still keeps it.
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed != settings.apiKey {
                settings.apiKey = trimmed
            }
        }
    }

    private func addKeyterm() {
        let term = newKeyterm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !settings.keyterms.contains(term) else { return }
        settings.keyterms.insert(term, at: 0)
        newKeyterm = ""
    }

    private func commit() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespaces)
        if trimmed != settings.apiKey {
            settings.apiKey = trimmed
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
