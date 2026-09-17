import Foundation

/// Chooses which route a push-to-talk turn takes at key-down.
///
/// Split out of `PushToTalkManager` so the decision can be exercised directly:
/// the manager is a singleton wired to the audio stack, the realtime hub, and
/// the coordinator, and "what does a turn do with no network" is not a question
/// that should require any of them to answer.
enum PTTRoutePolicy {

  enum Decision: Equatable {
    /// No network path. Transcribe on-device so a dictation still types.
    case onDeviceDictation
    /// The hub is connected and admitted for this turn's context.
    case hubImmediate
    /// The hub has to warm first; buffer mic audio until it does.
    case hubWarmWait
    /// The user pinned `Voice Transcript`: record the turn, transcribe it with
    /// the speech-to-text engine, and let the chat model answer. The realtime
    /// hub is never engaged, so nothing waits on a socket that is not needed.
    case transcriptOnly
  }

  /// - Parameters:
  ///   - isOnline: whether a network path is currently satisfied.
  ///   - admitsImmediately: whether the realtime hub is already admitted for
  ///     this turn.
  ///   - voiceMode: the user's answer mode. `.transcript` bypasses the hub.
  ///
  /// Network is checked first and unconditionally. With no path, every remote
  /// route is unreachable, and a hub that reports itself admitted is reporting
  /// on a socket that cannot carry the turn — waiting on it spends the whole
  /// warm deadline before the first character is typed.
  static func decide(
    isOnline: Bool,
    admitsImmediately: Bool,
    voiceMode: PTTVoiceMode = .live
  ) -> Decision {
    guard isOnline else { return .onDeviceDictation }
    guard voiceMode == .live else { return .transcriptOnly }
    return admitsImmediately ? .hubImmediate : .hubWarmWait
  }
}
