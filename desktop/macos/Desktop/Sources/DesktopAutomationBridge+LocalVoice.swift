import Foundation

/// Voice-output automation actions: inspect and drive the floating-bar voice
/// picker, and exercise on-device synthesis, without cursor input. Selecting a
/// voice writes the same published value the Settings picker binds to — the
/// production path that also plays the preview sample.
extension DesktopAutomationActionRegistry {
  func registerLocalVoiceActions() {
    register(
      name: "voice_settings_snapshot",
      summary:
        "Return the selected floating-bar voice, its provider, and whether the on-device voice is installed",
      category: "voice",
      surfaces: ["settings"],
      safety: "read_only"
    ) { _ in
      await MainActor.run { Self.localVoiceSnapshot() }
    }

    register(
      name: "select_voice",
      summary: "Select a floating-bar voice through the picker's own published value",
      params: ["voice_id"],
      category: "voice",
      surfaces: ["settings"],
      safety: "local_ui_state",
      sideEffects: ["persists the selected voice id; plays the preview sample"]
    ) { params in
      guard let voiceID = params["voice_id"],
        ShortcutSettings.availableVoices.contains(where: { $0.id == voiceID })
      else {
        throw DesktopAutomationActionError.invalidParams(
          "voice_id must be one of the picker entries")
      }
      return await MainActor.run {
        ShortcutSettings.shared.selectedVoiceID = voiceID
        return Self.localVoiceSnapshot()
      }
    }

    register(
      name: "synthesize_local_voice",
      summary:
        "Render text with the on-device Piper voice (reports not_installed instead of throwing)",
      params: ["text"],
      category: "voice",
      surfaces: ["settings", "floating_bar"],
      safety: "local_artifact",
      sideEffects: ["spawns the local Piper process and returns a WAV clip"]
    ) { params in
      let text = params["text"] ?? ShortcutSettings.localVoiceSampleText
      let started = Date()
      do {
        let audio = try await LocalVoiceSynthesisService.shared.synthesize(text: text)
        return [
          "outcome": "synthesized",
          "bytes": String(audio.count),
          "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
        ]
      } catch LocalVoiceSynthesisService.SynthesisError.notInstalled {
        return ["outcome": "not_installed", "bytes": "0", "duration_ms": "0"]
      } catch LocalVoiceSynthesisService.SynthesisError.emptyText {
        return ["outcome": "empty_text", "bytes": "0", "duration_ms": "0"]
      }
    }
  }

  @MainActor
  private static func localVoiceSnapshot() -> [String: String] {
    let settings = ShortcutSettings.shared
    let selected = ShortcutSettings.voiceOption(for: settings.selectedVoiceID)
    return [
      "selected_voice_id": selected.id,
      "voice_name": selected.name,
      "voice_provider": selected.provider.rawValue,
      "voice_is_local_piper": selected.isLocalPiper ? "true" : "false",
      "local_voice_installed": LocalVoiceSynthesisService.shared.isInstalled ? "true" : "false",
      "available_voice_ids": ShortcutSettings.availableVoices.map(\.id).joined(separator: ","),
    ]
  }
}
