import XCTest

@testable import Omi_Computer

/// Per-message provenance: which model produced an answer (voice or typed),
/// which recognizer produced the user's words, and which of those facts reach
/// the journal so the evidence survives replay.
@MainActor
final class ChatModelProvenanceTests: XCTestCase {

  // MARK: - Gemini thought parts

  func testGeminiThoughtPartsNeverBecomeAnswerText() {
    let thought: [String: Any] = [
      "thought": true,
      "text": "**Confirming Presence and Clarity** I've registered the Serbian question.",
    ]
    let answer: [String: Any] = ["text": "Tu sam, čujem te."]

    XCTAssertNil(
      GeminiRealtimeContentPolicy.visibleText(inPart: thought),
      "a thought summary is the model's plan — persisting or speaking it is the shipped defect")
    XCTAssertEqual(GeminiRealtimeContentPolicy.visibleText(inPart: answer), "Tu sam, čujem te.")
  }

  func testGeminiVisibleTextPreservesOrderAndSkipsEmptyOrAudioParts() {
    let parts: [[String: Any]] = [
      ["thought": true, "text": "plan"],
      ["text": "Prva rečenica. "],
      ["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": "AAAA"]],
      ["text": ""],
      ["text": "Druga."],
    ]

    XCTAssertEqual(
      GeminiRealtimeContentPolicy.visibleText(inModelTurn: ["parts": parts]),
      ["Prva rečenica. ", "Druga."])
  }

  // MARK: - Recognizer provenance

  func testProviderTranscriptProvenanceNamesTheProviderEngine() {
    let resolution = RealtimeHubTranscriptResolution(
      userText: "hello", providerLanguage: "en", localTranscript: nil, localLanguage: nil,
      usedLocalTranscript: false)

    var provenance = RealtimeTranscriptProvenance.resolve(
      resolution: resolution, providerEngine: "gemini-live",
      providerModel: "gemini-2.5-flash-native-audio-latest")
    XCTAssertEqual(provenance.source, .provider)
    XCTAssertEqual(provenance.engine, "gemini-live")
    XCTAssertEqual(provenance.model, "gemini-2.5-flash-native-audio-latest")
    XCTAssertEqual(provenance.language, "en")

    provenance = RealtimeTranscriptProvenance.resolve(
      resolution: resolution, providerEngine: "openai-realtime", providerModel: "whisper-1")
    XCTAssertEqual(provenance.engine, "openai-realtime")
    XCTAssertEqual(provenance.model, "whisper-1")
  }

  func testLocalTranscriptProvenanceNamesParakeet() {
    let resolution = RealtimeHubTranscriptResolution(
      userText: "zdravo", providerLanguage: "uk", localTranscript: "zdravo", localLanguage: "sr",
      usedLocalTranscript: true)

    let provenance = RealtimeTranscriptProvenance.resolve(
      resolution: resolution, providerEngine: "gemini-live", providerModel: "gemini-3.8-live")
    XCTAssertEqual(provenance.source, .local)
    XCTAssertEqual(provenance.engine, "parakeet-v3")
    XCTAssertEqual(provenance.model, "on-device")
    XCTAssertEqual(provenance.language, "sr")
  }

  // MARK: - Voice projection

  func testVoiceProjectionJournalsEffectiveModelAndRecognizer() {
    let projection = RealtimeStreamingJournalProjection(
      ownerID: "owner-1",
      continuityKey: "voice:turn-1",
      admissionSurface: .mainChat(chatId: nil),
      modelsUsed: ["gemini-2.5-flash-native-audio-latest"],
      screenContext: nil,
      evidence: []
    ).withSTTProvenance(
      RealtimeTranscriptProvenance(
        source: .provider, engine: "gemini-live",
        model: "gemini-2.5-flash-native-audio-latest", language: "sr"))

    let user = projection.userMessage(text: "Da li si tu?")
    XCTAssertEqual(user.metadata?.sttSummary, "gemini-live · gemini-2.5-flash-native-audio-latest · sr")

    let assistant = projection.assistantMessage(text: "Tu sam.", isStreaming: false)
    XCTAssertEqual(
      assistant.metadata?.modelAttributionSummary, "gemini-2.5-flash-native-audio-latest",
      "the journaled voice model must be the effective session model, not the provider default")

    let reStamped = projection.withSTTProvenance(nil)
    XCTAssertEqual(reStamped.userTurnID, projection.userTurnID)
    XCTAssertEqual(reStamped.assistantTurnID, projection.assistantTurnID)
  }

  // MARK: - Caption semantics

  func testServedModelWinsOverRequestedAttribution() {
    let metadata = MessageMetadata(
      modelsUsed: ["deepseek-v4.1-flash"], requestedModel: "some-other-model")
    XCTAssertEqual(metadata.modelAttributionSummary, "deepseek-v4.1-flash")
  }

  func testUnconfirmedRequestIsMarkedRequested() {
    let metadata = MessageMetadata(modelsUsed: [], requestedModel: "deepseek-v4.1-flash")
    XCTAssertEqual(
      metadata.modelAttributionSummary, "deepseek-v4.1-flash (requested)",
      "a client-direct request is not a served identity and must say so")
  }

  func testNoAttributionMeansNoCaption() {
    XCTAssertNil(MessageMetadata().modelAttributionSummary)
    XCTAssertNil(MessageMetadata().sttSummary)
  }

  // MARK: - Journal round-trip

  func testJournalRoundTripKeepsRecognizerProvenanceOnTheUserRow() throws {
    var message = ChatMessage(
      id: "user-turn-1",
      clientTurnId: "voice:turn-1",
      text: "Da li si tu?",
      sender: .user
    )
    message.metadata = MessageMetadata(
      sttSource: "local", sttEngine: "parakeet-v3", sttModel: "on-device", sttLanguage: "sr")

    let write = message.journalWrite(origin: "realtime_voice", status: .completed)
    let turn = try XCTUnwrap(
      KernelJournalTurn(
        dictionary: write.dictionary.merging([
          "conversationId": "conversation-1",
          "turnSeq": 1,
          "surfaceKind": "main_chat",
          "externalRefKind": "session",
          "externalRefId": "session-1",
        ]) { current, _ in current }))

    let restored = turn.chatMessage()
    XCTAssertEqual(restored.metadata?.sttEngine, "parakeet-v3")
    XCTAssertEqual(restored.metadata?.sttSource, "local")
    XCTAssertEqual(restored.metadata?.sttModel, "on-device")
    XCTAssertEqual(restored.metadata?.sttLanguage, "sr")
    XCTAssertEqual(restored.metadata?.sttSummary, "parakeet-v3 · on-device · sr")
  }

  func testJournalRoundTripKeepsRequestedModelOnTheAssistantRow() throws {
    var message = ChatMessage(
      id: "assistant-turn-1",
      clientTurnId: "typed:turn-1",
      text: "Odgovor",
      sender: .ai
    )
    message.metadata = MessageMetadata(modelsUsed: [], requestedModel: "deepseek-v4.1-flash")

    let write = message.journalWrite(origin: "typed_chat", status: .completed)
    let turn = try XCTUnwrap(
      KernelJournalTurn(
        dictionary: write.dictionary.merging([
          "conversationId": "conversation-1",
          "turnSeq": 2,
          "surfaceKind": "main_chat",
          "externalRefKind": "session",
          "externalRefId": "session-1",
        ]) { current, _ in current }))

    XCTAssertEqual(turn.chatMessage().metadata?.modelAttributionSummary, "deepseek-v4.1-flash (requested)")
  }

  func testJournalUpdateResendsAttributionAndScreenContext() throws {
    var message = ChatMessage(
      id: "assistant-turn-2",
      clientTurnId: "typed:turn-2",
      text: "Odgovor",
      sender: .ai
    )
    message.metadata = MessageMetadata(
      modelsUsed: ["served-model"], requestedModel: "requested-model")

    let update = message.journalUpdate(status: .completed)
    let metadataJSON = try XCTUnwrap(update.metadataJSON)
    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any])

    XCTAssertEqual(metadata["modelsUsed"] as? [String], ["served-model"])
    XCTAssertEqual(metadata["requestedModel"] as? String, "requested-model")
  }

  func testJournalUpdateKeepsUserScreenContextAndRecognizer() throws {
    var message = ChatMessage(
      id: "user-turn-2",
      clientTurnId: "voice:turn-2",
      text: "Pitanje",
      sender: .user
    )
    message.metadata = MessageMetadata(
      screenContext: "Safari — Gemini Live API GA",
      sttSource: "provider", sttEngine: "gemini-live", sttModel: "gemini-3.8-live",
      sttLanguage: "sr")

    let update = message.journalUpdate(status: .completed)
    let metadataJSON = try XCTUnwrap(update.metadataJSON)
    let metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any])

    XCTAssertEqual(metadata["screen_context"] as? String, "Safari — Gemini Live API GA")
    let stt = try XCTUnwrap(metadata["stt"] as? [String: String])
    XCTAssertEqual(stt["engine"], "gemini-live")
    XCTAssertEqual(stt["source"], "provider")
  }
}
