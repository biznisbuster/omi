import OmiTheme
import SwiftUI

extension SettingsContentView {
  /// One pane where every model role a voice turn can use is visible and
  /// choosable, and where the layout follows the selected answer mode:
  ///
  /// - **Voice Live** is one speech model doing hear/think/speak, so only that
  ///   model is offered.
  /// - **Voice Transcript** splits the roles: a transcription model, a
  ///   dictation model, the chat model that answers, and the spoken voice that
  ///   reads the answer aloud.
  ///
  /// The two settings that used to hide this distinction in copy alone
  /// (Speech-to-Text Engine under Transcription, Voice Model under AI &
  /// Automation) now live together, next to the mode that decides which of
  /// them is even in play.
  var voiceSection: some View {
    let mode = PTTVoiceMode(rawValue: pttVoiceMode) ?? .live
    return VStack(spacing: OmiSpacing.xl) {
      voiceModeCard

      if mode == .live {
        advancedCategoryHeader(title: "Live Voice", icon: "waveform")
        realtimeVoiceModelCard
      } else {
        advancedCategoryHeader(title: "Transcript Voice", icon: "text.bubble")
        transcriptionModelCard
        dictationModelCard
        chatModelCard
      }

      advancedCategoryHeader(title: "Voice Output", icon: "speaker.wave.2")
      spokenVoiceCard(mode: mode)
      voiceSpeedSlider(settingId: "floatingbar.voicespeed")

      advancedCategoryHeader(title: "Agents", icon: "person.2.badge.gearshape")
      backgroundAgentsCard

      advancedCategoryHeader(title: "Roles", icon: "list.bullet.rectangle")
      modelRolesCard
    }
  }

  // MARK: - Answer mode

  private var voiceModeCard: some View {
    settingsCard(settingId: "aichat.voicemode") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "waveform.and.mic")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Voice Answer Mode")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: $pttVoiceMode) {
            ForEach(PTTVoiceMode.allCases, id: \.rawValue) { mode in
              Text(mode.displayName).tag(mode.rawValue)
            }
          }
          .accessibilityIdentifier("aichat.voice_answer_mode")
        }

        Text((PTTVoiceMode(rawValue: pttVoiceMode) ?? .live).subtitle)
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Live mode

  private var realtimeVoiceModelCard: some View {
    settingsCard(settingId: "aichat.realtimevoice") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "waveform")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Voice Model")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: $realtimeOmniProvider) {
            ForEach(RealtimeOmniProvider.userSelectable, id: \.rawValue) { p in
              Text(p.displayName).tag(p.rawValue)
            }
          }
          .onChange(of: realtimeOmniProvider) { _, _ in
            // The picker writes @AppStorage directly (bypassing the RealtimeOmniSettings
            // setter), so post the change ourselves — this is what re-warms the realtime
            // hub on the newly selected provider (and is a no-op for unchanged providers).
            NotificationCenter.default.post(name: .realtimeOmniSettingsDidChange, object: nil)
          }
        }

        if let p = RealtimeOmniProvider(rawValue: realtimeOmniProvider), p != .auto {
          Text(p.subtitle)
            .scaledFont(size: OmiType.caption)
            .foregroundColor(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "Live voice uses this one model for everything: it hears your speech, writes the answer, and speaks it. Transcript and dictation models do not apply while this mode is selected."
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if let provider = RealtimeOmniProvider(rawValue: realtimeOmniProvider), provider != .auto,
          !RealtimeHubSettings.shared.canConnect
        {
          Text(
            "No matching provider key on this Mac, so Voice Live runs on Omi's managed lane — which serves its own model rather than this exact pick. Add the provider key in Advanced → Developer API Keys to use this model client-direct."
          )
          .scaledFont(size: OmiType.caption)
          .foregroundColor(SettingsInk.notice)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Transcript mode

  private var transcriptionModelCard: some View {
    settingsCard(settingId: "transcription.sttengine") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "waveform.badge.magnifyingglass")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Transcription Model")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: $pttTranscriptionPreference) {
            ForEach(PTTTranscriptionPreference.allCases, id: \.rawValue) { engine in
              Text(engine.displayName).tag(engine.rawValue)
            }
          }
        }

        Text(
          (PTTTranscriptionPreference(rawValue: pttTranscriptionPreference) ?? .automatic).subtitle
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Turns your voice into text for chat answers in Transcript mode.")
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if (PTTTranscriptionPreference(rawValue: pttTranscriptionPreference) ?? .automatic)
          == .transcriptEngine
        {
          GlassSeparator()
          transcriptEngineAddressRow
        }
      }
    }
  }

  /// The local engine's address had a stored preference and no door. A user
  /// running whisper.cpp on another port could only discover the key by
  /// reading the client's source.
  private var transcriptEngineAddressRow: some View {
    VStack(alignment: .leading, spacing: OmiSpacing.xs) {
      Text("Engine address")
        .scaledFont(size: OmiType.caption, weight: .medium)
        .foregroundColor(Ink.primary)
      TextField(TranscriptEngineClient.defaultBaseURL, text: $transcriptEngineBaseURL)
        .textFieldStyle(.roundedBorder)
        .scaledFont(size: OmiType.body)
        .accessibilityIdentifier("transcription.transcript_engine_url")
      Text(
        "Serbian only; other languages fall back to the built-in chain. Leave blank for \(TranscriptEngineClient.defaultBaseURL)."
      )
      .scaledFont(size: OmiType.caption)
      .foregroundColor(Ink.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var dictationModelCard: some View {
    settingsCard(settingId: "voice.dictationmodel") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "text.cursor")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Dictation Model")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: $pttDictationTranscriptionPreference) {
            ForEach(PTTDictationTranscriptionPreference.allCases, id: \.rawValue) { engine in
              Text(engine.displayName).tag(engine.rawValue)
            }
          }
          .accessibilityIdentifier("voice.dictation_model")
        }

        Text(
          (PTTDictationTranscriptionPreference(
            rawValue: pttDictationTranscriptionPreference) ?? .automatic).subtitle
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text("Types what you dictate with Omi Type into the focused app.")
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var chatModelCard: some View {
    let configured = APIKeyService.selectedBYOKLLMProvider
    return settingsCard(settingId: "voice.chatmodel") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "brain.head.profile")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Chat Model")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: chatModelProviderBinding) {
            // With nothing configured the stored pin is empty; say "managed"
            // rather than showing a provider the user never chose.
            if APIKeyService.selectedBYOKLLMProvider == nil {
              Text("Omi managed").tag("")
            }
            ForEach(BYOKLLMProvider.allCases) { provider in
              Text(provider.displayName).tag(provider.rawValue)
            }
          }
          .accessibilityIdentifier("voice.chat_model_provider")
          .onChange(of: chatModelProviderBinding.wrappedValue) { _, _ in
            // The runtime bakes the provider at spawn; a changed pin must not
            // leave a warm runtime serving the previous credential set. The
            // reconcile keeps the free-plan enrollment in step when the switch
            // is made from this pane instead of Developer API Keys.
            NotificationCenter.default.post(name: .realtimeOmniSettingsDidChange, object: nil)
            Task { await refreshBYOKActivation() }
          }
        }

        Text(chatModelStatusText)
          .scaledFont(size: OmiType.caption, weight: .medium)
          .foregroundColor(Ink.primary)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          "Answers typed chat and Transcript-mode voice. Without a key for the selected provider, chat stays on Omi managed."
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if configured == nil {
          Text("Add the provider's key in Advanced → Developer API Keys to use it here.")
            .scaledFont(size: OmiType.caption)
            .foregroundColor(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if configured == .opencodego {
          GlassSeparator()
          VStack(alignment: .leading, spacing: OmiSpacing.xs) {
            Text("OpenCode Go model")
              .scaledFont(size: OmiType.caption, weight: .medium)
              .foregroundColor(Ink.primary)
            SettingsMenuPicker(selection: $devOpenCodeGoModel) {
              ForEach(OpenCodeGoCatalog.models, id: \.id) { model in
                Text(model.name).tag(model.id)
              }
            }
            .accessibilityIdentifier("voice.chat_model_opencodego")
            Text("Runs directly against your OpenCode Go subscription from this Mac.")
              .scaledFont(size: OmiType.caption)
              .foregroundColor(Ink.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  /// The provider picker follows the stored choice when it is concrete and the
  /// resolved one otherwise, without writing a value merely for opening the
  /// pane (Developer Keys owns that migration). Empty means Omi managed.
  private var chatModelProviderBinding: Binding<String> {
    Binding(
      get: {
        BYOKLLMProvider(rawValue: devBYOKLLMProvider)?.rawValue
          ?? APIKeyService.selectedBYOKLLMProvider?.rawValue
          ?? ""
      },
      set: { devBYOKLLMProvider = $0 })
  }

  private var chatModelStatusText: String {
    guard let provider = APIKeyService.selectedBYOKLLMProvider else {
      return "Answering with Omi managed"
    }
    if provider == .opencodego {
      return "Answering with \(provider.displayName) · \(AgentRuntimeProcess.openCodeGoModel())"
    }
    return "Answering with \(provider.displayName)"
  }

  // MARK: - Voice output

  /// TTS exists in both modes but plays different roles: in Transcript mode it
  /// reads the chat model's answer aloud; in Live mode the provider speaks
  /// natively and this voice is only the text-without-audio fallback.
  private func spokenVoiceCard(mode: PTTVoiceMode) -> some View {
    settingsCard(settingId: "floatingbar.voice") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack(spacing: OmiSpacing.lg) {
          VStack(alignment: .leading, spacing: OmiSpacing.xxs) {
            Text(mode == .live ? "Fallback Voice (TTS)" : "Spoken Voice (TTS)")
              .scaledFont(size: OmiType.subheading, weight: .semibold)
              .foregroundColor(Ink.primary)
            Text(
              mode == .live
                ? "Used only when the Live model replies with text instead of native speech."
                : "Reads the chat model's answers out loud."
            )
            .scaledFont(size: OmiType.body)
            .foregroundColor(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(ShortcutSettings.voiceOption(for: shortcutSettings.selectedVoiceID).description)
              .scaledFont(size: OmiType.caption)
              .foregroundColor(Ink.secondary)
          }
          Spacer()
          SettingsMenuPicker(selection: $shortcutSettings.selectedVoiceID) {
            ForEach(ShortcutSettings.availableVoices) { voice in
              Text(voice.name).tag(voice.id)
            }
          }
        }

        if ShortcutSettings.voiceOption(for: shortcutSettings.selectedVoiceID).isLocalPiper {
          localVoiceInstallRow
        }
      }
    }
  }

  /// Installation state for the on-device Piper voice. The download is ~110 MB
  /// and happens once per Mac; until it finishes, replies fall back to the
  /// system voice rather than failing.
  @ViewBuilder
  private var localVoiceInstallRow: some View {
    HStack(spacing: OmiSpacing.sm) {
      if LocalVoiceSynthesisService.shared.isInstalled {
        Image(systemName: "checkmark.seal.fill")
          .foregroundColor(Ink.listeningGreen)
        Text(
          "On-device voice installed. Replies are synthesized on this Mac — nothing is sent to a cloud voice service."
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
      } else if isInstallingLocalVoice {
        ProgressView().controlSize(.mini)
        Text(localVoiceInstallMessage ?? "Installing local voice…")
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
      } else {
        Button("Install local voice (~110 MB)") {
          startLocalVoiceInstall()
        }
        .buttonStyle(.plain)
        .scaledFont(size: OmiType.caption, weight: .semibold)
        .foregroundColor(Ink.primary)
        if let localVoiceInstallError {
          Text(localVoiceInstallError)
            .scaledFont(size: OmiType.caption)
            .foregroundColor(SettingsInk.notice)
        }
      }
      Spacer()
    }
  }

  private func startLocalVoiceInstall() {
    guard !isInstallingLocalVoice else { return }
    isInstallingLocalVoice = true
    localVoiceInstallError = nil
    localVoiceInstallMessage = "Preparing download…"
    Task {
      do {
        try await LocalVoiceSynthesisService.shared.ensureInstalled { message in
          Task { @MainActor in
            localVoiceInstallMessage = message
          }
        }
        await MainActor.run {
          isInstallingLocalVoice = false
          localVoiceInstallMessage = nil
          FloatingBarVoicePlaybackService.shared.playVoiceSample(
            voiceID: shortcutSettings.selectedVoiceID)
        }
      } catch {
        await MainActor.run {
          isInstallingLocalVoice = false
          localVoiceInstallMessage = nil
          localVoiceInstallError = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Background agents

  private var backgroundAgentsCard: some View {
    let selectableProviders = BackgroundAgentProvider.allCases.filter {
      $0 == .omiManaged || $0.isInstalled
    }
    let selectedProvider =
      BackgroundAgentProvider(rawValue: backgroundAgentProvider) ?? .omiManaged

    return settingsCard(settingId: "aichat.backgroundagents") {
      VStack(alignment: .leading, spacing: OmiSpacing.md) {
        HStack {
          Image(systemName: "person.2.badge.gearshape")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Background Agents")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()

          SettingsMenuPicker(selection: $backgroundAgentProvider) {
            ForEach(selectableProviders, id: \.rawValue) { provider in
              Text(provider.displayName).tag(provider.rawValue)
            }
          }
          .accessibilityIdentifier("aichat.background_agent_provider")
          .onChange(of: backgroundAgentProvider) { _, _ in
            // The spawn tool schema is baked into the warm realtime session, so
            // a changed pin must rebuild it — same handoff the Voice Model uses.
            NotificationCenter.default.post(name: .realtimeOmniSettingsDidChange, object: nil)
          }
        }

        Text(selectedProvider.subtitle)
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if selectedProvider != .omiManaged, !selectedProvider.isInstalled {
          Text(
            "\(selectedProvider.displayName) is not installed right now — agents fall back to the Omi lane until it is."
          )
          .scaledFont(size: OmiType.caption)
          .foregroundColor(PageGlass.warning)
          .fixedSize(horizontal: false, vertical: true)
        }

        if selectableProviders.count == 1 {
          Text(
            "No local agent CLI detected. Install Hermes or OpenClaw to run background agents without an Omi plan."
          )
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Model roles

  /// One read-only role line: what runs, and where the control for it lives.
  private func modelRoleRow(_ title: String, value: String, hint: String) -> some View {
    VStack(alignment: .leading, spacing: OmiSpacing.hairline) {
      Text(title)
        .scaledFont(size: OmiType.caption, weight: .medium)
        .foregroundColor(Ink.primary)
      HStack(spacing: OmiSpacing.xs) {
        Text(value)
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("· \(hint)")
          .scaledFont(size: OmiType.micro)
          .foregroundColor(Ink.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The recognizers the transcript lane actually tries, in order, for the
  /// pinned Transcription Model. Live answers transcribe inside the voice
  /// model; this is the transcript lane.
  private var transcriptionChainDescription: String {
    switch PTTTranscriptionPreference.current {
    case .automatic:
      return "Parakeet v3 (on-device) → Omi cloud batch"
    case .onDevice:
      return "Parakeet v3 (on-device) only"
    case .cloud:
      return "Omi cloud batch only"
    case .transcriptEngine:
      return "Transcript Engine (\(TranscriptEngineClient.configured.baseURL.absoluteString)) → built-in fallback"
    }
  }

  private var dictationChainDescription: String {
    switch PTTDictationTranscriptionPreference.current {
    case .automatic:
      return "Omi cloud batch → Parakeet v3 (on-device)"
    case .onDevice:
      return "Parakeet v3 (on-device) only"
    case .cloud:
      return "Omi cloud batch only"
    case .transcriptEngine:
      return "Transcript Engine (\(TranscriptEngineClient.configured.baseURL.absoluteString)) → built-in fallback"
    }
  }

  private var modelRolesCard: some View {
    let voiceMode = PTTVoiceMode(rawValue: pttVoiceMode) ?? .live
    let voiceModel = RealtimeOmniSettings.shared.selectedProvider
    let chatProvider = APIKeyService.selectedBYOKLLMProvider
    let chatModel = AgentRuntimeProcess.configuredClientDirectModel()
    let chatValue =
      [chatProvider?.displayName, chatModel, chatProvider == nil ? "Omi managed" : nil]
      .compactMap { $0 }
      .joined(separator: " · ")
    let voiceValue = ShortcutSettings.voiceOption(for: shortcutSettings.selectedVoiceID)

    return settingsCard(settingId: "aichat.modelroles") {
      VStack(alignment: .leading, spacing: OmiSpacing.sm) {
        HStack {
          Image(systemName: "list.bullet.rectangle")
            .scaledFont(size: OmiType.subheading)
            .foregroundColor(Ink.secondary)

          Text("Model Roles")
            .scaledFont(size: OmiType.subheading, weight: .semibold)
            .foregroundColor(Ink.primary)

          Spacer()
        }

        Text(
          "What runs in each role right now. Live voice is one speech model doing all of it; Transcript mode splits the roles."
        )
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if voiceMode == .live {
          modelRoleRow(
            "Voice (Live): hears, thinks, speaks",
            value: "\(voiceModel.displayName) · \(voiceModel.modelID)",
            hint: "this pane")
        } else {
          modelRoleRow(
            "Voice transcription",
            value: transcriptionChainDescription,
            hint: "this pane")
        }
        modelRoleRow(
          "Dictation (voice typing)",
          value: dictationChainDescription,
          hint: "this pane")
        if voiceMode == .transcript {
          modelRoleRow(
            "Voice answer chat model",
            value: chatValue,
            hint: "this pane")
        }
        modelRoleRow(
          "Typed chat & agent runtime",
          value: chatValue,
          hint: "this pane")
        modelRoleRow(
          "Reading answers aloud (TTS)",
          value: voiceValue.description,
          hint: voiceMode == .live ? "fallback voice · this pane" : "this pane")
        modelRoleRow(
          "Background agents",
          value: (BackgroundAgentProvider(rawValue: backgroundAgentProvider) ?? .omiManaged)
            .displayName,
          hint: "this pane")
      }
    }
  }
}
