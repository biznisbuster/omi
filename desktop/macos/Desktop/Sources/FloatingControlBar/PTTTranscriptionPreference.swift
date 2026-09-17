import Foundation

/// How a push-to-talk question is answered.
enum PTTVoiceMode: String, CaseIterable, Sendable {
  /// The realtime voice model hears the audio and answers directly.
  case live
  /// The turn is recorded, transcribed by the selected speech-to-text engine,
  /// and sent to the selected chat model. No realtime model is involved.
  case transcript

  static let defaultsKey = "pttVoiceMode"

  static var current: PTTVoiceMode {
    guard
      let raw = UserDefaults.standard.string(forKey: defaultsKey),
      let value = PTTVoiceMode(rawValue: raw)
    else { return .live }
    return value
  }

  var displayName: String {
    switch self {
    case .live: return "Voice Live"
    case .transcript: return "Voice Transcript"
    }
  }

  var subtitle: String {
    switch self {
    case .live:
      return "The realtime voice model listens and answers directly — lowest latency, native speech"
    case .transcript:
      return "Records, transcribes with the Speech-to-Text Engine, then sends the text to your chat model"
    }
  }
}

/// Which recognizer a transcription-lane PTT turn may use.
///
/// The live-voice lane transcribes inside the realtime model and is not this
/// choice. This governs the cascade lane: the audio that is decoded to text and
/// then answered by the selected chat model.
enum PTTTranscriptionPreference: String, CaseIterable, Sendable {
  /// On-device Parakeet first; the cloud batch recognizer when the local decode
  /// yields nothing (the historical behavior).
  case automatic
  /// On-device Parakeet only. A decode that yields nothing fails the turn
  /// instead of silently sending the audio to a cloud recognizer.
  case onDevice
  /// Cloud batch recognizer only (Omi's batch speech endpoint).
  case cloud
  /// The user's own local Transcript Engine server (its versioned local API).
  case transcriptEngine

  static let defaultsKey = "pttTranscriptionPreference"

  static var current: PTTTranscriptionPreference {
    guard
      let raw = UserDefaults.standard.string(forKey: defaultsKey),
      let value = PTTTranscriptionPreference(rawValue: raw)
    else { return .automatic }
    return value
  }

  var displayName: String {
    switch self {
    case .automatic: return "Automatic"
    case .onDevice: return "On-device (Parakeet v3)"
    case .cloud: return "Cloud (Omi batch)"
    case .transcriptEngine: return "Transcript Engine (local)"
    }
  }

  var subtitle: String {
    switch self {
    case .automatic: return "Decodes on this Mac, then falls back to the cloud batch recognizer"
    case .onDevice: return "Private and offline; a failed decode fails the turn instead of going to the cloud"
    case .cloud: return "Omi's batch speech endpoint; usually more accurate for some languages"
    case .transcriptEngine:
      return "Your own engine at 127.0.0.1:8765 (Serbian); falls back to the built-in chain when it is down"
    }
  }
}

/// Which recognizer serves one cascade transcription, and whether the cloud
/// fallback may run. Pure so the rule is testable without audio or network.
enum PTTTranscriptionRoutePolicy {
  enum Decision: Equatable {
    /// A non-empty local decode serves the turn.
    case local
    /// Decode on-device first; a failed/empty decode may fall through to cloud.
    case localThenCloud
    /// Cloud batch recognizer only.
    case cloud
    /// The preference forbids cloud and the local decode produced nothing.
    case localFailed
  }

  static func decide(
    preference: PTTTranscriptionPreference,
    isAppleSilicon: Bool,
    localTranscript: String?
  ) -> Decision {
    let local = localTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasLocal = isAppleSilicon && local?.isEmpty == false
    switch preference {
    case .cloud:
      return .cloud
    case .transcriptEngine:
      // The engine is a network hop to a local server; the caller attempts it
      // before this policy and falls back here when it cannot serve the turn.
      return hasLocal ? .local : .localThenCloud
    case .onDevice:
      return hasLocal ? .local : .localFailed
    case .automatic:
      return hasLocal ? .local : .localThenCloud
    }
  }
}

/// Which recognizer serves dictation (Omi Type voice typing).
///
/// The two lanes are different jobs: a transcript turn is a question for the
/// chat model, while a dictation is text for the focused app. The default stays
/// **Same as transcription** — the single pin the two lanes shared before this
/// choice existed — so an existing setup (for example a personal Transcript
/// Engine) keeps dictating exactly as it did. An explicit choice overrides it
/// per lane, and an On-device pin keeps a dictation off the network entirely.
enum PTTDictationTranscriptionPreference: String, CaseIterable, Sendable {
  /// Follow the transcript lane's recognizer pin.
  case sameAsTranscription
  /// Omi's cloud batch recognizer, with the on-device model as fallback.
  case automatic
  /// On-device Parakeet only. A dictation never leaves this Mac.
  case onDevice
  /// Cloud batch recognizer only.
  case cloud
  /// The user's own local Transcript Engine server, falling back to the
  /// built-in chain when it cannot serve the turn.
  case transcriptEngine

  static let defaultsKey = "pttDictationTranscriptionPreference"

  static var current: PTTDictationTranscriptionPreference {
    guard
      let raw = UserDefaults.standard.string(forKey: defaultsKey),
      let value = PTTDictationTranscriptionPreference(rawValue: raw)
    else { return .sameAsTranscription }
    return value
  }

  /// The recognizer pin a dictation actually follows.
  var resolved: PTTTranscriptionPreference {
    switch self {
    case .sameAsTranscription: return PTTTranscriptionPreference.current
    case .automatic: return .automatic
    case .onDevice: return .onDevice
    case .cloud: return .cloud
    case .transcriptEngine: return .transcriptEngine
    }
  }

  var displayName: String {
    switch self {
    case .sameAsTranscription: return "Same as transcription"
    case .automatic: return "Automatic"
    case .onDevice: return "On-device (Parakeet v3)"
    case .cloud: return "Cloud (Omi batch)"
    case .transcriptEngine: return "Transcript Engine (local)"
    }
  }

  var subtitle: String {
    switch self {
    case .sameAsTranscription:
      return "Follows the Transcription Model (\(PTTTranscriptionPreference.current.displayName))"
    case .automatic: return "Omi cloud batch first, then the on-device model"
    case .onDevice: return "Private and offline: a dictation never leaves this Mac"
    case .cloud: return "Omi's batch speech endpoint only"
    case .transcriptEngine:
      return "Your own engine first; the built-in chain takes over when it is down"
    }
  }
}

/// Raised when a turn is pinned to the on-device recognizer and the decode
/// produced nothing. The turn reports a transcription failure instead of
/// quietly routing the user's audio to a cloud recognizer they did not choose.
struct PTTOnDeviceTranscriptionUnavailable: LocalizedError {
  var errorDescription: String? {
    "On-device transcription produced no text (the speech-to-text engine is pinned to On-device)"
  }
}
