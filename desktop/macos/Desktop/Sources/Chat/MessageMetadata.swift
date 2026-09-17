import Foundation

/// Local-only evidence for one completed assistant turn.
///
/// Response Context only shows facts this client observed: tools and SQL on
/// the turn, whether a screenshot was attached, and the kernel snapshot
/// admitted at send. Token, cache, and cost numbers are not displayed —
/// the managed chat path defaults missing usage to zero and may estimate
/// tokens from prompt length.
struct MessageMetadata: Equatable {
  struct SourceOutcome: Equatable, Identifiable {
    var id: String { source }
    let source: String
    let outcome: String
  }

  var hasScreenshot: Bool
  var screenshotSizeBytes: Int?
  var toolNames: [String]
  var sqlRowsReturned: Int
  var sqlQueryCount: Int
  var sourceOutcomes: [SourceOutcome]
  var retainedTurnCount: Int
  var totalTurnCount: Int
  var omittedTurnCount: Int
  var offeredToolCount: Int
  var adapterId: String
  var credentialScopeLabel: String
  /// Served model identities observed on this turn's completions — captured
  /// from the provider RESPONSE stream (e.g. the gateway lane's resolved
  /// upstream model), never assumed from the request. Empty = unobserved.
  var modelsUsed: [String]
  /// Provider targets observed on completion events. This must never be
  /// synthesized from the runtime adapter or requested model.
  var providerTargets: [String]
  /// The concrete model this client asked a client-direct lane to serve
  /// (e.g. the selected OpenCode Go model). Attribution only when the provider
  /// reports no served identity — `modelsUsed` always wins.
  var requestedModel: String?
  /// What was on the user's screen when this turn was asked, as text (the voice hub's accepted
  /// screen observation, bounded). Journaled on the user row so later turns can answer "do you
  /// remember what I was reading?" from conversation history even when Rewind has no frame yet.
  var screenContext: String?
  /// Bounded, typed source evidence attached to the user turn. The runtime
  /// renders compact references and keeps the full body behind an evidence read
  /// boundary; this local model retains the body only for journal replay.
  var evidence: [ConversationEvidence]
  /// Which recognizer produced a voice user turn's text: `provider` (the
  /// realtime model's native input transcription) or `local` (the on-device
  /// fallback recognizer). Journaled on the user row so the transcript's origin
  /// stays visible after replay.
  var sttSource: String?
  /// Recognizer identity, e.g. `gemini-live` or `parakeet-v3`.
  var sttEngine: String?
  /// Recognizer model, when the engine names one: the realtime model whose
  /// native transcription ran, or `on-device` for the local recognizer.
  var sttModel: String?
  /// Language the saved transcript was recognized as (BCP-47/ISO code).
  var sttLanguage: String?
  /// Which speech model actually read this answer aloud: the configured
  /// provider, its model, and the voice. Recorded at playback start, including
  /// when a fallback spoke, so the caption names what the user heard rather
  /// than what was merely selected.
  var ttsProvider: String?
  var ttsModel: String?
  var ttsVoice: String?

  init(
    hasScreenshot: Bool = false,
    screenshotSizeBytes: Int? = nil,
    toolNames: [String] = [],
    sqlRowsReturned: Int = 0,
    sqlQueryCount: Int = 0,
    sourceOutcomes: [SourceOutcome] = [],
    retainedTurnCount: Int = 0,
    totalTurnCount: Int = 0,
    omittedTurnCount: Int = 0,
    offeredToolCount: Int = 0,
    adapterId: String = "",
    credentialScopeLabel: String = "",
    modelsUsed: [String] = [],
    providerTargets: [String] = [],
    requestedModel: String? = nil,
    screenContext: String? = nil,
    evidence: [ConversationEvidence] = [],
    sttSource: String? = nil,
    sttEngine: String? = nil,
    sttModel: String? = nil,
    sttLanguage: String? = nil,
    ttsProvider: String? = nil,
    ttsModel: String? = nil,
    ttsVoice: String? = nil
  ) {
    self.hasScreenshot = hasScreenshot
    self.screenshotSizeBytes = screenshotSizeBytes
    self.toolNames = toolNames
    self.sqlRowsReturned = sqlRowsReturned
    self.sqlQueryCount = sqlQueryCount
    self.sourceOutcomes = sourceOutcomes
    self.retainedTurnCount = retainedTurnCount
    self.totalTurnCount = totalTurnCount
    self.omittedTurnCount = omittedTurnCount
    self.offeredToolCount = offeredToolCount
    self.adapterId = adapterId
    self.credentialScopeLabel = credentialScopeLabel
    self.modelsUsed = modelsUsed
    self.providerTargets = providerTargets
    self.requestedModel = requestedModel
    self.screenContext = screenContext
    self.evidence = evidence
    self.sttSource = sttSource
    self.sttEngine = sttEngine
    self.sttModel = sttModel
    self.sttLanguage = sttLanguage
    self.ttsProvider = ttsProvider
    self.ttsModel = ttsModel
    self.ttsVoice = ttsVoice
  }

  static func fromCompletedTurn(
    snapshot: AgentContextSnapshot,
    profile: AgentExecutionProfile,
    imageByteCount: Int?,
    toolNames: [String],
    sqlRowsReturned: Int,
    sqlQueryCount: Int,
    modelsUsed: [String] = [],
    providerTargets: [String] = [],
    requestedModel: String? = nil
  ) -> MessageMetadata {
    let allowedToolNames = snapshot.capabilities["allowedToolNames"] as? [String] ?? []
    return MessageMetadata(
      hasScreenshot: imageByteCount != nil,
      screenshotSizeBytes: imageByteCount,
      toolNames: toolNames,
      sqlRowsReturned: sqlRowsReturned,
      sqlQueryCount: sqlQueryCount,
      sourceOutcomes: admittedSources(from: snapshot),
      retainedTurnCount: snapshot.contextPlan.retainedTurnCount,
      totalTurnCount: snapshot.contextPlan.totalTurnCount,
      omittedTurnCount: snapshot.contextPlan.omittedTurnCount,
      offeredToolCount: allowedToolNames.count,
      adapterId: profile.adapterId,
      credentialScopeLabel: Self.credentialLabel(profile.credentialScope),
      modelsUsed: modelsUsed,
      providerTargets: providerTargets,
      requestedModel: requestedModel
    )
  }

  var screenshotSummary: String {
    guard hasScreenshot, let size = screenshotSizeBytes else { return "None" }
    return "1 image (\(max(size, 0) / 1024) KB)"
  }

  var historySummary: String {
    if totalTurnCount == 0 {
      return "none"
    }
    if omittedTurnCount > 0 {
      return "\(retainedTurnCount) of \(totalTurnCount) turns (\(omittedTurnCount) omitted)"
    }
    return "\(retainedTurnCount) of \(totalTurnCount) turns"
  }

  var offeredToolsSummary: String {
    offeredToolCount == 1 ? "1 tool" : "\(offeredToolCount) tools"
  }

  /// "Model" row: the observed served identities, comma-joined. Empty string
  /// = none observed (the row is hidden rather than guessed).
  var modelsSummary: String {
    modelsUsed.joined(separator: ", ")
  }

  /// Always-visible attribution caption: the served identity when the provider
  /// named one, otherwise the concrete model this client requested from a
  /// client-direct lane, marked as requested so it is never read as served.
  var modelAttributionSummary: String? {
    if !modelsUsed.isEmpty { return modelsUsed.joined(separator: ", ") }
    if let requestedModel, !requestedModel.isEmpty { return "\(requestedModel) (requested)" }
    return nil
  }

  var providersSummary: String {
    providerTargets.joined(separator: ", ")
  }

  var pathSummary: String {
    [adapterId, credentialScopeLabel].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// "Transcribed by" line for a voice user turn: engine · model · language.
  /// Nil when no recognizer provenance was recorded (typed and legacy rows).
  var sttSummary: String? {
    guard let engine = sttEngine, !engine.isEmpty else { return nil }
    var parts = [engine]
    if let model = sttModel, !model.isEmpty { parts.append(model) }
    if let language = sttLanguage, !language.isEmpty { parts.append(language) }
    return parts.joined(separator: " · ")
  }

  /// "Spoken by" line for an answer that was read aloud: provider · model ·
  /// voice. Nil when no speech provenance was recorded.
  var ttsSummary: String? {
    guard let provider = ttsProvider, !provider.isEmpty else { return nil }
    var parts = [provider]
    if let model = ttsModel, !model.isEmpty { parts.append(model) }
    if let voice = ttsVoice, !voice.isEmpty { parts.append(voice) }
    return parts.joined(separator: " · ")
  }

  var sqlSummary: String? {
    guard sqlQueryCount > 0 else { return nil }
    let queryWord = sqlQueryCount == 1 ? "query" : "queries"
    let rowWord = sqlRowsReturned == 1 ? "row" : "rows"
    return "\(sqlQueryCount) \(queryWord) · \(sqlRowsReturned) \(rowWord)"
  }

  private static func admittedSources(from snapshot: AgentContextSnapshot) -> [SourceOutcome] {
    AgentContextSource.allCases.compactMap { source in
      guard
        let row = snapshot.sourceOutcomes.first(where: { $0["source"] as? String == source.rawValue }),
        let outcome = row["outcome"] as? String, !outcome.isEmpty
      else { return nil }
      return SourceOutcome(source: source.rawValue, outcome: outcome)
    }
  }

  private static func credentialLabel(_ scope: AgentExecutionProfile.CredentialScope) -> String {
    switch scope {
    case .managedCloud: return "managed"
    case .localUser: return "BYOK"
    }
  }
}
