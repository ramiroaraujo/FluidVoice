import SwiftUI

/// Settings → Audio: background-audio filtering, and the voice profile behind "Only transcribe my voice".
struct VoiceFilterSettingsCard: View {
    @EnvironmentObject private var appServices: AppServices
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @State private var profile = DictationVoiceProfile.load()
    @State private var recordingStartedAt: Date?
    @State private var isLearning = false
    @State private var message = ""

    private static let passage = """
    The quick brown fox jumps over the lazy dog. I'm recording a short sample so my dictation app can \
    recognize my voice and ignore everything else in the room. Some days I dictate emails, other days \
    notes, messages or code reviews. Wherever I am, I want the text to contain what I said and nothing \
    the television, the radio or the people around me said.
    """

    var body: some View {
        ThemedCard(style: .standard) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Background Audio", systemImage: "waveform.badge.minus")
                    .font(.fluidSystem(.headline))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 12) {
                    self.toggleRow(
                        title: "Filter Background Audio",
                        description: "Silences sound much quieter than your voice, like a TV, music or people across the room, before transcribing.",
                        isOn: self.$settings.filterBackgroundAudioEnabled
                    )
                    Divider().opacity(0.2)
                    self.toggleRow(
                        title: "Only Transcribe My Voice",
                        description: "Silences speech that doesn't sound like you. Needs a voice profile.",
                        isOn: Binding(
                            get: { self.settings.onlyMyVoiceEnabled && self.profile != nil },
                            set: { self.settings.onlyMyVoiceEnabled = $0 }
                        )
                    )
                    .disabled(self.profile == nil)
                    Divider().opacity(0.2)
                    self.profileRow
                }
            }
            .padding(16)
        }
        .onDisappear {
            guard self.recordingStartedAt != nil else { return }
            self.recordingStartedAt = nil
            Task { await self.appServices.asr.stopWithoutTranscription() }
        }
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Profile")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text(self.profileStatus)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if self.isLearning {
                    ProgressView().controlSize(.small)
                } else if self.recordingStartedAt != nil {
                    Button("Cancel") { Task { await self.cancelRecording() } }
                        .fluidOutlinedButton()
                        .controlSize(.small)
                    Button("Done") { Task { await self.finishRecording() } }
                        .fluidOutlinedButton()
                        .controlSize(.small)
                } else {
                    if self.profile != nil {
                        Button("Delete") { self.deleteProfile() }
                            .fluidOutlinedButton()
                            .controlSize(.small)
                    }
                    Button(self.profile == nil ? "Train My Voice" : "Retrain") { Task { await self.startRecording() } }
                        .fluidOutlinedButton()
                        .controlSize(.small)
                }
            }

            if let recordingStartedAt = self.recordingStartedAt {
                VStack(alignment: .leading, spacing: 8) {
                    TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(recordingStartedAt))
                        Text("Recording \(seconds)s. Read this aloud at your normal volume in a quiet room, or talk about anything for 30 seconds in any language you dictate in, then press Done.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(Self.passage)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(self.theme.palette.secondaryText.opacity(0.08)))
                }
            }

            if !self.message.isEmpty {
                Text(self.message)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileStatus: String {
        if self.isLearning { return "Learning your voice…" }
        guard let profile = self.profile else {
            return "Not set up. Record about 30 seconds of yourself talking."
        }
        let date = profile.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "Learned from \(Int(profile.speechSeconds.rounded())) seconds of speech on \(date)."
    }

    private func toggleRow(title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    private func startRecording() async {
        self.message = ""
        // The training capture keeps the hotkey and the dictation overlay out of the way, and nothing is pasted.
        _ = await self.appServices.asr.start(forDictionaryTraining: true, requiresPronunciation: false)
        guard self.appServices.asr.isRunning else {
            self.message = "Couldn't start recording. Finish any dictation in progress and check microphone access."
            return
        }
        self.recordingStartedAt = Date()
    }

    private func cancelRecording() async {
        self.recordingStartedAt = nil
        await self.appServices.asr.stopWithoutTranscription()
    }

    private func finishRecording() async {
        self.recordingStartedAt = nil
        self.isLearning = true
        defer { self.isLearning = false }
        let samples = await self.appServices.asr.stopWithoutTranscription()
        do {
            let profile = try await DictationVoiceMatcher.shared.enroll(samples)
            try profile.save()
            self.profile = profile
            self.settings.onlyMyVoiceEnabled = true
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func deleteProfile() {
        DictationVoiceProfile.delete()
        self.profile = nil
        self.settings.onlyMyVoiceEnabled = false
    }
}
