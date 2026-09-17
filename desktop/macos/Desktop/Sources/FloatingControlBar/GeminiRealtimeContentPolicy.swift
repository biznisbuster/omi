import Foundation

/// Which Gemini Live `modelTurn` parts may become the user-visible answer.
///
/// Thinking-enabled Live models (including `gemini-2.5-flash-native-audio-*`)
/// send internal thought summaries beside the spoken reply as parts marked
/// `thought: true`. They are the model's plan, not its answer: persisting them
/// puts the plan in the chat transcript and, when native audio never arrived,
/// the text-without-audio fallback speaks the plan aloud instead of the answer.
enum GeminiRealtimeContentPolicy {
  /// Visible answer text from one `modelTurn` part, `nil` for thought parts and
  /// for parts that carry no text (e.g. inline audio).
  static func visibleText(inPart part: [String: Any]) -> String? {
    if (part["thought"] as? Bool) == true { return nil }
    guard let text = part["text"] as? String, !text.isEmpty else { return nil }
    return text
  }

  /// Visible answer text for a Gemini `modelTurn` payload, in arrival order.
  static func visibleText(inModelTurn modelTurn: [String: Any]?) -> [String] {
    guard let parts = modelTurn?["parts"] as? [[String: Any]] else { return [] }
    return parts.compactMap { visibleText(inPart: $0) }
  }
}
