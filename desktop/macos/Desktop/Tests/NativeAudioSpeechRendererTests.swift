import XCTest

@testable import Omi_Computer

/// A scriptable stand-in for the Live socket. Callbacks are delivered on the
/// queue the renderer passed, exactly like `RawWebSocket`.
private final class FakeSpeechSocket: RealtimeRawWebSocketTransport, @unchecked Sendable {
  var onOpen: (() -> Void)?
  var onMessage: ((Data) -> Void)?
  var onClose: ((Int, String) -> Void)?
  var onError: ((RealtimeRawWebSocketFailure) -> Void)?
  /// Test hook: fires on every `sendText` with the raw JSON.
  var onSend: (@Sendable (String) -> Void)?

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var sentTexts: [String] = []
  private(set) var isClosed = false

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  func connect() {
    queue.async { [weak self] in self?.onOpen?() }
  }

  func sendText(_ text: String, completion: (@Sendable (Error?) -> Void)?) {
    lock.lock()
    sentTexts.append(text)
    lock.unlock()
    onSend?(text)
    completion?(nil)
  }

  func close() {
    lock.lock()
    isClosed = true
    lock.unlock()
  }

  func closeAndWait() async {}

  var sent: [String] {
    lock.lock()
    defer { lock.unlock() }
    return sentTexts
  }

  var clientTurns: [String] {
    sent.compactMap { text -> String? in
      guard let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let content = payload["clientContent"] as? [String: Any],
        let turns = content["turns"] as? [[String: Any]],
        let parts = turns.first?["parts"] as? [[String: Any]]
      else { return nil }
      return parts.first?["text"] as? String
    }
  }

  var setupModel: String? {
    guard
      let payload = sent.first.flatMap({
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }),
      let setup = payload["setup"] as? [String: Any]
    else { return nil }
    return setup["model"] as? String
  }

  func emit(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    queue.async { [weak self] in self?.onMessage?(data) }
  }

  func emitSetupComplete() {
    emit(["setupComplete": [:]])
  }

  func emitTurnComplete() {
    emit(["serverContent": ["turnComplete": true]])
  }

  func emitAudio(bytes: Int = 480) {
    emit([
      "serverContent": [
        "modelTurn": [
          "parts": [
            [
              "inlineData": [
                "mimeType": "audio/pcm;rate=24000",
                "data": Data(repeating: 0x11, count: bytes).base64EncodedString(),
              ]
            ]
          ]
        ]
      ]
    ])
  }

  func emitSilence(bytes: Int = 480) {
    emit([
      "serverContent": [
        "modelTurn": [
          "parts": [
            [
              "inlineData": [
                "mimeType": "audio/pcm;rate=24000",
                "data": Data(repeating: 0x00, count: bytes).base64EncodedString(),
              ]
            ]
          ]
        ]
      ]
    ])
  }
}

private final class SpeechSocketFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [FakeSpeechSocket] = []
  /// (socket index, raw JSON) for every send on every socket it made.
  var onSend: (@Sendable (Int, String) -> Void)?

  func make(queue: DispatchQueue) -> FakeSpeechSocket {
    let socket = FakeSpeechSocket(queue: queue)
    lock.lock()
    sockets.append(socket)
    let index = sockets.count - 1
    lock.unlock()
    socket.onSend = { [weak self] text in self?.onSend?(index, text) }
    return socket
  }

  var all: [FakeSpeechSocket] {
    lock.lock()
    defer { lock.unlock() }
    return sockets
  }

  var latest: FakeSpeechSocket? { all.last }
}

/// Ordered counter for send hooks invoked on the renderer's serial queue.
private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}

private final class TestGeminiKey {
  private let key = BYOKProvider.gemini.storageKey
  private let previous: String?

  init() {
    previous = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.set("AIza-test-reader-key", forKey: key)
  }

  deinit {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

/// The native-audio speech lane is a Live session, so its wire contract is the
/// test surface: the setup payload, the streamed audio parts, and the turn
/// boundary. These are the production seams the renderer embeds.
final class NativeAudioSpeechRendererTests: XCTestCase {

  func testModelIsTheNativeAudioModelVoiceLiveUses() {
    XCTAssertEqual(
      NativeAudioSpeechRenderer.modelID,
      RealtimeOmniProvider.geminiNativeAudioDialog.modelID,
      "the speech lane must read through the same Live model Voice Live speaks with")
    XCTAssertEqual(NativeAudioSpeechRenderer.modelID, "gemini-2.5-flash-native-audio-latest")
  }

  func testSetupPayloadPinsTheChosenVoiceAndAudioModality() throws {
    let payload = NativeAudioSpeechRenderer.sessionSetupPayload(voice: "Charon")
    let setup = try XCTUnwrap(payload["setup"] as? [String: Any])

    XCTAssertEqual(
      setup["model"] as? String,
      "models/\(NativeAudioSpeechRenderer.defaultModelID)")

    let generation = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
    XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
    XCTAssertEqual(generation["temperature"] as? Double, 0.1)

    let speech = try XCTUnwrap(generation["speechConfig"] as? [String: Any])
    let voiceConfig = try XCTUnwrap(speech["voiceConfig"] as? [String: Any])
    let prebuilt = try XCTUnwrap(voiceConfig["prebuiltVoiceConfig"] as? [String: Any])
    XCTAssertEqual(prebuilt["voiceName"] as? String, "Charon")

    let realtimeInput = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
    let activityDetection = try XCTUnwrap(
      realtimeInput["automaticActivityDetection"] as? [String: Any])
    XCTAssertEqual(
      activityDetection["disabled"] as? Bool, true,
      "the reader has no microphone; automatic activity detection must stay off")
  }

  func testSetupPayloadUsesTheChosenModel() throws {
    let payload = NativeAudioSpeechRenderer.sessionSetupPayload(
      voice: "Kore", model: "gemini-3.8-live")
    let setup = try XCTUnwrap(payload["setup"] as? [String: Any])
    XCTAssertEqual(setup["model"] as? String, "models/gemini-3.8-live")
  }

  /// A transcription model rejects `AUDIO` output outright (verified against
  /// `gemini-3.5-transcribe-live`: close 1007), so it must never become a voice.
  func testModelCatalogOffersOnlyAudioCapableReaderModels() {
    let options = NativeAudioSpeechRenderer.modelOptions
    XCTAssertFalse(options.isEmpty)
    XCTAssertTrue(
      options.contains { $0.id == NativeAudioSpeechRenderer.defaultModelID },
      "the shipped default must be selectable")
    for option in options {
      XCTAssertFalse(
        option.id.contains("transcribe"),
        "\(option.id) is a transcription model and cannot read text aloud")
    }
  }

  func testSelectedModelFallsBackToTheDefaultForUnknownValues() {
    let key = NativeAudioSpeechRenderer.modelDefaultsKey
    let previous = UserDefaults.standard.string(forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    UserDefaults.standard.set("gemini-3.5-transcribe-live", forKey: key)
    XCTAssertEqual(
      NativeAudioSpeechRenderer.selectedModelID, NativeAudioSpeechRenderer.defaultModelID,
      "a hand-edited non-voice model must not reach the wire")

    let offered = NativeAudioSpeechRenderer.modelOptions[1].id
    UserDefaults.standard.set(offered, forKey: key)
    XCTAssertEqual(NativeAudioSpeechRenderer.selectedModelID, offered)
  }

  /// The reader session needs no history, so a bounded context is pure win:
  /// a day of answers must not accumulate in one Live session.
  func testSessionRotationBoundsContextByTextAndAge() {
    XCTAssertFalse(NativeAudioSessionRotation.shouldRotate(characters: 120, age: 5))
    XCTAssertTrue(
      NativeAudioSessionRotation.shouldRotate(
        characters: NativeAudioSessionRotation.characterBudget, age: 1))
    XCTAssertTrue(
      NativeAudioSessionRotation.shouldRotate(
        characters: 1, age: NativeAudioSessionRotation.maximumAge))
  }

  func testSmallChunkingMakesShorterTurnsThanStandard() {
    XCTAssertLessThan(
      NativeSpeechChunking.small.followupPreferred,
      NativeSpeechChunking.standard.followupPreferred)
    XCTAssertLessThan(
      NativeSpeechChunking.small.followupMinimum,
      NativeSpeechChunking.standard.followupMinimum)
    XCTAssertGreaterThan(NativeSpeechChunking.small.followupPreferred, 0)
  }

  /// The end of a streamed answer used to collapse into one long turn (observed
  /// live: 1118 characters), where the voice drifts and the reading outlives the
  /// output watchdog. The final flush must keep splitting at the profile size.
  func testFinalFlushSplitsTheTailInsteadOfEmittingOneLongTurn() throws {
    let tail = String(repeating: "Ovo je rečenica koja se čita naglas. ", count: 40)
    XCTAssertGreaterThan(tail.count, NativeSpeechChunking.small.finalFlushLimit)

    XCTAssertFalse(
      FloatingBarVoicePlaybackService.finalFlushIsWholeBuffer(
        tail, isFinal: true, profile: .small),
      "a tail larger than the limit must keep splitting")

    // The split itself is the ordinary chunk boundary (as if not final).
    let boundary = try XCTUnwrap(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: tail, isFinal: false, isFirstChunk: false, profile: .small))
    XCTAssertNotEqual(boundary, tail.endIndex, "the tail must not flush as one turn")
    XCTAssertLessThanOrEqual(tail.distance(from: tail.startIndex, to: boundary), 300)

    // A tail that already fits the limit flushes whole.
    let short = "Kratak ostatak."
    XCTAssertTrue(
      FloatingBarVoicePlaybackService.finalFlushIsWholeBuffer(
        short, isFinal: true, profile: .small))
    XCTAssertEqual(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: short, isFinal: true, isFirstChunk: false, profile: .small),
      short.endIndex)
  }

  /// `twoPart` is the default: every turn is up to 500 characters, ending at
  /// the last period inside the window. A completed answer that fits the window
  /// is a single turn — never two with a pause between.
  func testTwoPartUsesFiveHundredCharacterSentenceAlignedTurns() throws {
    let key = NativeSpeechChunking.defaultsKey
    let previous = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertEqual(
      NativeSpeechChunking.current, .twoPart,
      "the default must be the 500-character two-part style")
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    }

    let short = "Prva rečenica je ovde. Druga rečenica je ovde. Treća je ovde."
    XCTAssertNil(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: short, isFinal: false, isFirstChunk: true, profile: .twoPart),
      "a short streaming answer must not split early")
    XCTAssertEqual(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: short, isFinal: true, isFirstChunk: true, profile: .twoPart),
      short.endIndex,
      "a completed short answer is one turn")

    let early = String(repeating: "a", count: 300) + ". "
    let long = early + String(repeating: "b", count: 300) + ". "
    for isFirstChunk in [true, false] {
      let boundary = try XCTUnwrap(
        FloatingBarVoicePlaybackService.nextChunkBoundary(
          in: long, isFinal: false, isFirstChunk: isFirstChunk, profile: .twoPart))
      XCTAssertEqual(
        String(long[..<boundary]), String(repeating: "a", count: 300) + ".",
        "only the period inside the 500-character window counts")
    }
    XCTAssertFalse(
      FloatingBarVoicePlaybackService.finalFlushIsWholeBuffer(
        long, isFinal: true, profile: .twoPart),
      "a long tail must split, not flush as one giant turn")
    XCTAssertEqual(NativeSpeechChunking.twoPart.finalFlushLimit, 500)

    let clauses = String(repeating: "Ovo je klauzula — i još jedna, ", count: 20)
    let capped = try XCTUnwrap(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: clauses, isFinal: false, isFirstChunk: true, profile: .twoPart))
    XCTAssertLessThanOrEqual(
      clauses.distance(from: clauses.startIndex, to: capped), 500,
      "the turn is capped even without a period")
  }

  /// The new whole-answer mode reads nothing until the response is complete and
  /// then sends it as a single turn.
  func testWholeAnswerModeWaitsForTheFinalText() {
    let text = "Prva rečenica. Druga rečenica. Treća rečenica."
    XCTAssertNil(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: text, isFinal: false, isFirstChunk: true, profile: .whole))
    XCTAssertNil(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: text, isFinal: false, isFirstChunk: false, profile: .whole))
    XCTAssertEqual(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: text, isFinal: true, isFirstChunk: false, profile: .whole),
      text.endIndex)
    XCTAssertEqual(NativeSpeechChunking.whole.finalFlushLimit, .max)
  }

  /// A socket that dropped after it was ready is transient (Google recycles
  /// idle sessions); the next answer must reconnect immediately, not wait out a
  /// backoff that sends it to the fallback voice.
  func testTransientSessionCloseDoesNotBackOffTheNextAnswer() {
    XCTAssertFalse(NativeAudioSpeechRenderer.backoffApplies(afterFailureWhileReady: true))
    XCTAssertTrue(NativeAudioSpeechRenderer.backoffApplies(afterFailureWhileReady: false))
    XCTAssertLessThanOrEqual(
      NativeAudioSpeechRenderer.idleCloseDelay, 40,
      "the idle close must beat the provider's idle reset")
  }

  /// A short answer that never reaches the opening rule is still read: the
  /// whole text is the opening turn, and there is no remainder.
  func testTwoPartShortAnswerIsStillSpoken() {
    let short = "Da, naravno."
    XCTAssertEqual(
      FloatingBarVoicePlaybackService.nextChunkBoundary(
        in: short, isFinal: true, isFirstChunk: true, profile: .twoPart),
      short.endIndex)
  }

  /// Every speech model shares one code path: the setup payload is identical
  /// except for the model id, and the reader never receives chat context. A
  /// model that needs its own logic must not be added silently.
  func testEverySpeechModelSharesOneSetupPath() throws {
    let models = NativeAudioSpeechRenderer.modelOptions.map(\.id)
    XCTAssertGreaterThanOrEqual(models.count, 2)
    let reference = try normalizedSetupPayload(model: NativeAudioSpeechRenderer.defaultModelID)
    for model in models {
      XCTAssertEqual(
        try normalizedSetupPayload(model: model), reference,
        "\(model) must not have its own reader setup")
    }

    let payload = NativeAudioSpeechRenderer.sessionSetupPayload(
      voice: "Charon", model: models[0])
    let setup = try XCTUnwrap(payload["setup"] as? [String: Any])
    XCTAssertEqual(
      Set(setup.keys),
      [
        "model", "generationConfig", "systemInstruction", "outputAudioTranscription",
        "realtimeInputConfig", "contextWindowCompression",
      ],
      "the reader payload carries only the reader contract — never chat context")
  }

  private func normalizedSetupPayload(model: String) throws -> String {
    let payload = NativeAudioSpeechRenderer.sessionSetupPayload(voice: "Charon", model: model)
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    return json.replacingOccurrences(of: model, with: "<model>")
  }

  /// A dialogue model that keeps streaming past its text's expected speech
  /// duration is cut off instead of holding the turn for minutes (observed
  /// live: ~100 s of audio for a 51-character line).
  func testRunawayTurnIsCappedInsteadOfStreamingForever() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let turnSent = expectation(description: "turn sent")
    let spoken = expectation(description: "turn resolved")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") { turnSent.fulfill() }
    }

    let task = Task {
      try await renderer.speak(text: "Kratka rečenica.", voice: "Charon") { _ in }
      spoken.fulfill()
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [turnSent], timeout: 5)

    // 25 seconds of PCM for a 15-character line is far past the cap.
    factory.latest?.emitAudio(bytes: 48_000 * 25)
    await fulfillment(of: [spoken], timeout: 5)

    _ = try await task.value
    XCTAssertTrue(
      factory.latest?.isClosed == true,
      "the runaway session must be retired, not left streaming")
    renderer.stop()
  }

  func testRunawayCapScalesWithTextAndHasAFloor() {
    XCTAssertEqual(
      NativeAudioSpeechRenderer.runawayCapSeconds(forCharacterCount: 51),
      NativeAudioSpeechRenderer.minimumRunawayCapSeconds, accuracy: 0.01)
    let long = NativeAudioSpeechRenderer.runawayCapSeconds(forCharacterCount: 500)
    XCTAssertGreaterThan(long, 90)
    XCTAssertLessThan(long, 110)
    XCTAssertGreaterThanOrEqual(
      NativeAudioSpeechRenderer.runawayCapSeconds(forCharacterCount: 1),
      NativeAudioSpeechRenderer.minimumRunawayCapSeconds)
  }

  /// The server's transcription of the reader's own audio is what detects a
  /// model that left the script; the allowance is generous so a natural token
  /// is never mistaken for babbling.
  func testOffScriptDetectionAllowsSlackAndCatchesBabbling() {
    XCTAssertFalse(
      NativeAudioSpeechRenderer.isOffScript(spokenCharacters: 60, scriptCharacters: 51))
    XCTAssertTrue(
      NativeAudioSpeechRenderer.isOffScript(spokenCharacters: 200, scriptCharacters: 51))
    XCTAssertFalse(
      NativeAudioSpeechRenderer.isOffScript(spokenCharacters: 550, scriptCharacters: 500))
    XCTAssertTrue(
      NativeAudioSpeechRenderer.isOffScript(spokenCharacters: 700, scriptCharacters: 500))
  }

  func testOutputTranscriptionIsParsedFromTheServerMessage() throws {
    let message = try JSONSerialization.data(withJSONObject: [
      "serverContent": ["outputTranscription": ["text": "Tu sam, Marko."]]
    ])
    XCTAssertEqual(
      NativeAudioSpeechRenderer.serverEvents(in: message),
      [.transcription("Tu sam, Marko.")])
  }

  /// 3.8 Live finishes generating but never sends `turnComplete`; the reader
  /// must finish the turn on `generationComplete` instead of stalling.
  func testGenerationCompleteFinishesATurnWhenTurnCompleteNeverArrives() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let turnSent = expectation(description: "turn sent")
    let spoken = expectation(description: "turn resolved")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") { turnSent.fulfill() }
    }

    let task = Task {
      try await renderer.speak(text: "Prva rečenica.", voice: "Charon") { _ in }
      spoken.fulfill()
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [turnSent], timeout: 5)

    factory.latest?.emitAudio()
    factory.latest?.emit(["serverContent": ["generationComplete": true]])
    await fulfillment(of: [spoken], timeout: 5)

    // A late turnComplete for the same turn must not resolve anything else.
    factory.latest?.emitTurnComplete()
    _ = try await task.value
    renderer.stop()
  }

  /// `generationComplete` before any audio must not finish the turn: doing so
  /// ended the turn silently (observed live: no audio at all for a long turn).
  func testGenerationCompleteWithoutAudioDoesNotFinishTheTurn() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let turnSent = expectation(description: "turn sent")
    let completedTooEarly = expectation(description: "turn must stay pending")
    completedTooEarly.isInverted = true
    let completed = expectation(description: "turn completed")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") { turnSent.fulfill() }
    }

    let task = Task {
      try await renderer.speak(text: "Prva rečenica.", voice: "Charon") { _ in }
      completed.fulfill()
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [turnSent], timeout: 5)

    factory.latest?.emit(["serverContent": ["generationComplete": true]])
    await fulfillment(of: [completedTooEarly], timeout: 1.0)

    factory.latest?.emitAudio()
    factory.latest?.emit(["serverContent": ["generationComplete": true]])
    await fulfillment(of: [completed], timeout: 5)

    _ = try await task.value
    renderer.stop()
  }

  /// 3.8 Live keeps streaming silence after the script and never sends
  /// `turnComplete`; a turn that has spoken and then gone silent must finish on
  /// its own instead of running into the duration cap.
  func testSilenceAfterSpeechCompletesATurnWithoutTurnComplete() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let turnSent = expectation(description: "turn sent")
    let spoken = expectation(description: "turn resolved")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") { turnSent.fulfill() }
    }

    let script = "Tu sam, Marko — čujem te jasno. Šta radimo dalje?"
    let task = Task {
      try await renderer.speak(text: script, voice: "Charon") { _ in }
      spoken.fulfill()
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [turnSent], timeout: 5)

    // Enough audible audio to cover the script, then a silent tail.
    factory.latest?.emitAudio(bytes: 48_000 * 5)
    factory.latest?.emitSilence(bytes: 48_000)
    await fulfillment(of: [spoken], timeout: 6)

    _ = try await task.value
    renderer.stop()
  }

  func testPeakLevelDistinguishesSilenceFromSpeech() {
    XCTAssertEqual(
      NativeAudioSpeechRenderer.peakLevel(ofPCM16: Data(repeating: 0, count: 480)), 0)
    XCTAssertGreaterThanOrEqual(
      NativeAudioSpeechRenderer.peakLevel(ofPCM16: Data(repeating: 0x11, count: 480)),
      NativeAudioSpeechRenderer.audiblePeakThreshold)
  }

  /// The API sends `generationComplete` while the spoken audio is still
  /// streaming; audio that follows must still reach the speaker. Completing on
  /// it immediately dropped the rest of the reading (observed live: only the
  /// first sentence was heard).
  func testAudioAfterGenerationCompleteIsStillDelivered() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let turnSent = expectation(description: "turn sent")
    let lateAudio = expectation(description: "trailing audio delivered")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") { turnSent.fulfill() }
    }
    let task = Task {
      try await renderer.speak(text: "Duža rečenica koja se čita.", voice: "Charon") { chunk in
        if chunk.count == 999 { lateAudio.fulfill() }
      }
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [turnSent], timeout: 5)

    factory.latest?.emitAudio(bytes: 480)
    factory.latest?.emit(["serverContent": ["generationComplete": true]])
    factory.latest?.emitAudio(bytes: 999)
    await fulfillment(of: [lateAudio], timeout: 5)

    factory.latest?.emitTurnComplete()
    _ = try await task.value
    renderer.stop()
  }

  func testGenerationCompleteIsParsedFromTheServerMessage() throws {
    let message = try JSONSerialization.data(withJSONObject: [
      "serverContent": ["generationComplete": true]
    ])
    XCTAssertEqual(
      NativeAudioSpeechRenderer.serverEvents(in: message), [.generationComplete])
  }

  /// A journal projection can hand the same answer a new row id while its audio
  /// is playing; that must continue the answer, not restart it (the live
  /// duplicate: the same text spoken twice, then again in the fallback voice).
  func testAnswerContinuesAcrossARowIdChange() {
    XCTAssertTrue(
      FloatingBarVoicePlaybackService.answerContinues(
        previous: "Tu sam, Marko.", new: "Tu sam, Marko. Sve je u redu."))
    XCTAssertFalse(
      FloatingBarVoicePlaybackService.answerContinues(
        previous: "Prvi odgovor.", new: "Potpuno drugi odgovor."))
    XCTAssertFalse(
      FloatingBarVoicePlaybackService.answerContinues(previous: "", new: "Bilo šta"))
  }

  /// The fallback voice must read only what the listener has not heard; a chunk
  /// that already finished playing must not be repeated in another voice.
  func testFallbackReadsOnlyWhatWasNotHeard() throws {
    let text = Array(repeating: "Ovo je rečenica koja se čita.", count: 12).joined(separator: " ")
    XCTAssertEqual(
      FloatingBarVoicePlaybackService.unspokenRemainder(of: text, deliveredBytes: 0), text,
      "nothing heard yet reads the whole chunk")

    let fullDuration = Int(Double(text.count) / 13 * 48_000)
    XCTAssertNil(
      FloatingBarVoicePlaybackService.unspokenRemainder(
        of: text, deliveredBytes: fullDuration),
      "a fully heard chunk must not be replayed")

    let remainder = try XCTUnwrap(
      FloatingBarVoicePlaybackService.unspokenRemainder(
        of: text, deliveredBytes: fullDuration / 2))
    XCTAssertLessThan(remainder.count, text.count)
    XCTAssertTrue(text.hasSuffix(remainder), "only the tail may be re-read")

    let almostAll = Int(Double(text.count - 20) / 13 * 48_000)
    XCTAssertNil(
      FloatingBarVoicePlaybackService.unspokenRemainder(of: text, deliveredBytes: almostAll),
      "a remainder too short to be worth another voice is dropped")
  }

  // MARK: - Session behavior (scripted socket)

  /// The join between two chunks must not wait for the previous turn, but it
  /// must also not burst onto the wire: the successor goes out once the head
  /// turn actually starts speaking.
  func testTurnsArePipelinedWithoutWaitingForThePreviousTurn() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let firstTurnSent = expectation(description: "first turn sent")
    let secondTurnSent = expectation(description: "second turn sent")
    let firstSpoken = expectation(description: "first turn completed")
    let secondSpoken = expectation(description: "second turn completed")
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("Prva rečenica.") { firstTurnSent.fulfill() }
      if text.contains("Druga rečenica.") { secondTurnSent.fulfill() }
    }

    let first = Task {
      try await renderer.speak(text: "Prva rečenica.", voice: "Charon") { _ in }
      firstSpoken.fulfill()
    }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [firstTurnSent], timeout: 5)

    let second = Task {
      try await renderer.speak(text: "Druga rečenica.", voice: "Charon") { _ in }
      secondSpoken.fulfill()
    }

    // The successor must not go out before the head speaks — a burst makes the
    // server coalesce turns and drop the boundaries.
    XCTAssertEqual(factory.latest?.clientTurns.count, 1)

    factory.latest?.emitAudio()
    await fulfillment(of: [secondTurnSent], timeout: 5)
    XCTAssertEqual(factory.latest?.clientTurns.count, 2)

    factory.latest?.emitTurnComplete()
    factory.latest?.emitTurnComplete()
    await fulfillment(of: [firstSpoken, secondSpoken], timeout: 5)

    _ = try await first.value
    _ = try await second.value
    renderer.stop()
  }

  /// Regression for the live failure: a completed answer queues several chunks
  /// at once, and sending them in the same millisecond produced one
  /// `turnComplete` for three turns — the rest stalled out. The wire may only
  /// ever carry one turn plus its released successor.
  func testQueuedTurnsAreNotBurstOntoTheWire() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let setupSent = expectation(description: "setup sent")
    let firstTurnSent = expectation(description: "first turn sent")
    let secondTurnSent = expectation(description: "second turn sent")
    let thirdTurnSent = expectation(description: "third turn sent")
    // `onSend` is invoked on the renderer's serial queue, so the counter is
    // ordered even when the three utterance tasks start concurrently.
    let clientTurnSends = Counter()
    factory.onSend = { _, text in
      if text.contains("\"setup\"") { setupSent.fulfill() }
      if text.contains("clientContent") {
        switch clientTurnSends.increment() {
        case 1: firstTurnSent.fulfill()
        case 2: secondTurnSent.fulfill()
        case 3: thirdTurnSent.fulfill()
        default: break
        }
      }
    }

    let first = Task { try await renderer.speak(text: "Prva rečenica.", voice: "Charon") { _ in } }
    let second = Task { try await renderer.speak(text: "Druga rečenica.", voice: "Charon") { _ in } }
    let third = Task { try await renderer.speak(text: "Treća rečenica.", voice: "Charon") { _ in } }

    await fulfillment(of: [setupSent], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [firstTurnSent], timeout: 5)

    // Three queued utterances, one on the wire: the successor and the trailing
    // turn wait for the head to start speaking.
    XCTAssertEqual(factory.latest?.clientTurns.count, 1)

    factory.latest?.emitAudio()
    await fulfillment(of: [secondTurnSent], timeout: 5)
    XCTAssertEqual(factory.latest?.clientTurns.count, 2)

    factory.latest?.emitAudio()
    factory.latest?.emitTurnComplete()
    factory.latest?.emitAudio()
    factory.latest?.emitTurnComplete()
    factory.latest?.emitTurnComplete()
    await fulfillment(of: [thirdTurnSent], timeout: 5)

    _ = try? await first.value
    _ = try? await second.value
    _ = try? await third.value
    XCTAssertEqual(
      factory.latest?.clientTurns.count, 3,
      "every queued turn must eventually reach the wire")
    renderer.stop()
  }

  /// The reader needs no history, so a long enough answer retires the socket at
  /// the next turn boundary and opens a fresh one while the tail still plays.
  func testSessionRotatesAfterTheCharacterBudget() async throws {
    let key = TestGeminiKey()
    _ = key
    let factory = SpeechSocketFactory()
    let renderer = NativeAudioSpeechRenderer { _, queue in factory.make(queue: queue) }

    let firstSetup = expectation(description: "first setup")
    let longTurnSent = expectation(description: "long turn sent")
    let secondSetup = expectation(description: "rotated setup")
    let spoken = expectation(description: "long turn completed")
    factory.onSend = { index, text in
      if text.contains("\"setup\"") {
        if index == 0 { firstSetup.fulfill() } else { secondSetup.fulfill() }
      }
      if text.contains("Rečenica.") { longTurnSent.fulfill() }
    }

    let longText = String(repeating: "Rečenica. ", count: 300)
    XCTAssertGreaterThan(longText.count, NativeAudioSessionRotation.characterBudget)

    let turn = Task {
      try await renderer.speak(text: longText, voice: "Charon") { _ in }
      spoken.fulfill()
    }

    await fulfillment(of: [firstSetup], timeout: 5)
    factory.latest?.emitSetupComplete()
    await fulfillment(of: [longTurnSent], timeout: 5)
    factory.latest?.emitTurnComplete()
    await fulfillment(of: [secondSetup, spoken], timeout: 5)

    XCTAssertEqual(factory.all.count, 2, "the session must be rebuilt, not reused")
    _ = try await turn.value
    renderer.stop()
  }

  /// The model is a dialogue model. If the instruction stops demanding verbatim
  /// reading, answers get summarised, answered, or prefixed with chatter.
  func testInstructionDemandsVerbatimReadingAndNothingElse() {
    let instruction = NativeAudioSpeechRenderer.verbatimInstruction.lowercased()
    for requirement in ["verbatim", "never answer", "never summarise", "never add"] {
      XCTAssertTrue(
        instruction.contains(requirement),
        "the reader instruction must state '\(requirement)'")
    }
  }

  func testStreamedAudioPartsAreDecodedFromModelTurns() throws {
    let first = Data(repeating: 0x11, count: 480)
    let second = Data(repeating: 0x22, count: 960)
    let message = try JSONSerialization.data(withJSONObject: [
      "serverContent": [
        "modelTurn": [
          "parts": [
            [
              "inlineData": [
                "mimeType": "audio/pcm;rate=24000",
                "data": first.base64EncodedString(),
              ]
            ],
            ["text": "not audio"],
            [
              "inlineData": [
                "mimeType": "audio/pcm;rate=24000",
                "data": second.base64EncodedString(),
              ]
            ],
          ]
        ]
      ]
    ])

    XCTAssertEqual(
      NativeAudioSpeechRenderer.serverEvents(in: message),
      [.audio(first), .audio(second)])
  }

  func testSetupAckTurnBoundaryAndProviderErrorAreRecognized() throws {
    let ack = try JSONSerialization.data(withJSONObject: ["setupComplete": [:]])
    XCTAssertEqual(NativeAudioSpeechRenderer.serverEvents(in: ack), [.setupComplete])

    let turn = try JSONSerialization.data(withJSONObject: [
      "serverContent": ["turnComplete": true]
    ])
    XCTAssertEqual(NativeAudioSpeechRenderer.serverEvents(in: turn), [.turnComplete])

    let error = try JSONSerialization.data(withJSONObject: [
      "error": ["code": 429, "message": "quota exceeded"]
    ])
    XCTAssertEqual(
      NativeAudioSpeechRenderer.serverEvents(in: error),
      [.providerError("quota exceeded")])

    XCTAssertEqual(
      NativeAudioSpeechRenderer.serverEvents(in: Data("not json".utf8)), [],
      "a malformed frame must read as no events, not crash the receive path")
  }

  func testSessionURLCarriesTheKeyAsAQueryParameter() throws {
    let url = try XCTUnwrap(NativeAudioSpeechRenderer.sessionURL(key: "AIza-test-key"))
    XCTAssertEqual(url.scheme, "wss")
    XCTAssertEqual(url.host, "generativelanguage.googleapis.com")
    XCTAssertTrue(url.path.contains("BidiGenerateContent"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(
      components.queryItems?.first(where: { $0.name == "key" })?.value, "AIza-test-key")
  }

  /// Without a key the lane must fail before any socket work, so the caller's
  /// fallback voice speaks immediately instead of waiting on a connect timeout.
  func testSpeakWithoutAGeminiKeyFailsFast() async throws {
    let storageKey = BYOKProvider.gemini.storageKey
    let previous = UserDefaults.standard.string(forKey: storageKey)
    UserDefaults.standard.removeObject(forKey: storageKey)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: storageKey)
      }
    }

    do {
      try await NativeAudioSpeechRenderer.shared.speak(text: "Zdravo", voice: "Charon") { _ in }
      XCTFail("a missing key must refuse the turn")
    } catch let failure as NativeAudioSpeechRenderer.RendererFailure {
      XCTAssertEqual(failure, .missingKey)
    }
  }
}
