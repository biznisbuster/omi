import Foundation

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
    }
  }

  var subtitle: String {
    switch self {
    case .automatic: return "Decodes on this Mac, then falls back to the cloud batch recognizer"
    case .onDevice: return "Private and offline; a failed decode fails the turn instead of going to the cloud"
    case .cloud: return "Omi's batch speech endpoint; usually more accurate for some languages"
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
    case .onDevice:
      return hasLocal ? .local : .localFailed
    case .automatic:
      return hasLocal ? .local : .localThenCloud
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
