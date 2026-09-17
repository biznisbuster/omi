import Foundation

/// One authority for which spoken voice each realtime provider is pinned to.
///
/// Both lanes deliberately use deep, calm male voices — Gemini's Charon and
/// the gpt-realtime family's cedar (its counterpart) — so a provider failover
/// changes the engine, not who Omi sounds like. Session builders read from
/// here; a per-call-site string is how the lanes drifted apart (marin).
///
/// Gemini's Live models let the user pick their prebuilt voice, and that pick
/// is what they actually hear in Voice Live mode. It is stored separately from
/// the batch-TTS voice picker because the two are different roles: the live
/// voice speaks natively, the TTS voice is the text-only fallback.
enum RealtimeHubVoicePolicy {
  static let geminiVoiceDefaultsKey = "realtimeGeminiVoice"

  /// Gemini prebuilt voices offered for the live lane, with display labels.
  /// The provider names are the wire values.
  static let selectableGeminiVoices: [(name: String, label: String)] = [
    ("Charon", "Charon — deep, calm"),
    ("Kore", "Kore — warm, natural"),
    ("Puck", "Puck — upbeat"),
    ("Aoede", "Aoede — light"),
    ("Fenrir", "Fenrir — grounded"),
  ]

  static let defaultGeminiVoice = "Charon"

  static func voiceName(for provider: RealtimeHubProvider) -> String {
    switch provider {
    case .openai: return "cedar"
    case .gemini: return selectedGeminiVoice()
    }
  }

  /// The stored Gemini voice, validated against the offered set so a stale or
  /// hand-edited value can never reach the provider wire.
  static func selectedGeminiVoice(defaults: UserDefaults = .standard) -> String {
    let stored = defaults.string(forKey: geminiVoiceDefaultsKey) ?? ""
    return selectableGeminiVoices.contains { $0.name == stored } ? stored : defaultGeminiVoice
  }
}
