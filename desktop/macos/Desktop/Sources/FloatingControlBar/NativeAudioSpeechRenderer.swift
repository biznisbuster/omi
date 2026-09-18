import Foundation

/// The Live models the speech lane can read with. Every entry must support
/// `responseModalities: ["AUDIO"]` on `BidiGenerateContent`; the transcription
/// models (`gemini-3.5-transcribe*`) reject AUDIO outright and are not voices.
struct NativeAudioModelOption: Equatable, Sendable {
  let id: String
  let label: String
}

/// How much text one reader turn carries. Smaller turns keep the model's voice
/// steady — its prosody drifts inside a long utterance — while `standard` is the
/// pre-existing chunking kept as the fallback style. `twoPart` is the default
/// (opening sentences + one remainder turn); `whole` reads the complete answer
/// in a single turn.
enum NativeSpeechChunking: String, CaseIterable, Sendable {
  case twoPart
  case whole
  case standard
  case small

  nonisolated static let defaultsKey = "speechNativeAudioChunking"

  /// The user's pick. Defaults to `twoPart`: the opening sentences are read as
  /// soon as they exist, and the rest of the answer is held until it is
  /// complete and then read as one second turn. Two turns per answer keeps the
  /// generator ahead of playback (no underrun) and the Live request count
  /// minimal.
  nonisolated static var current: NativeSpeechChunking {
    let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    return NativeSpeechChunking(rawValue: stored) ?? .twoPart
  }

  var displayName: String {
    switch self {
    case .twoPart: return "Two parts (default)"
    case .whole: return "Whole answer (one turn)"
    case .standard: return "Standard (smooth)"
    case .small: return "Small (steadiest voice)"
    }
  }

  var subtitle: String {
    switch self {
    case .twoPart:
      return
        "Up to 500 characters per turn, ending at a sentence. The next turn starts as the previous one begins speaking, and a short answer is a single turn."
    case .whole:
      return
        "Waits for the complete answer and then reads it all in one turn. No join at all, but nothing is spoken until the answer finishes generating."
    case .standard:
      return
        "Larger turns keep the generator ahead of playback, so the reading is smooth; a very long turn can drift slightly."
    case .small:
      return
        "One short sentence per turn. Steadiest voice, but the reading can sound choppy because each turn's audio is shorter than the server's start-up time."
    }
  }

  var firstMinimum: Int {
    switch self {
    case .twoPart, .whole: return 10
    case .standard: return 40
    case .small: return 30
    }
  }
  var firstPreferred: Int {
    switch self {
    case .twoPart, .whole: return 80
    case .standard: return 120
    case .small: return 60
    }
  }
  var firstEmergency: Int {
    switch self {
    case .twoPart, .whole: return 120
    case .standard: return 200
    case .small: return 100
    }
  }
  var followupMinimum: Int { self == .standard ? 320 : 80 }
  var followupPreferred: Int { self == .standard ? 520 : 160 }
  var followupEmergency: Int { self == .standard ? 800 : 260 }

  /// The largest tail the final flush may emit as one turn. Without this the
  /// end of a streamed answer collapses into a single long utterance (observed
  /// live: 1118 characters in one turn), which is exactly where the voice
  /// drifts and the reading outlives the output watchdog.
  var finalFlushLimit: Int {
    switch self {
    case .twoPart: return 500
    case .whole: return .max
    case .standard: return 800
    case .small: return 260
    }
  }
}

/// When the reader's Live session starts a fresh context.
///
/// The session needs no history at all — every turn is "read this text" — so the
/// only reason to keep one socket is warmth. A long-lived context is pure cost:
/// it slows generation and can drift the model, so the lane retires the socket
/// after a bounded amount of text or wall-clock time (and the API's own sliding
/// window is the second line of defence). The rotation happens between turns,
/// while the tail of the last answer is still playing, so the fresh session is
/// warm before the next chunk needs it.
enum NativeAudioSessionRotation {
  /// ~700 tokens of input text; audio output in that window is the bulk of the
  /// context, so this keeps a session well inside a handful of minutes of talk.
  nonisolated static let characterBudget = 2500
  nonisolated static let maximumAge: TimeInterval = 10 * 60

  nonisolated static func shouldRotate(characters: Int, age: TimeInterval) -> Bool {
    characters >= characterBudget || age >= maximumAge
  }
}

/// Reads answer text aloud through a Gemini Live model, client-direct with the
/// user's own Gemini key.
///
/// Voice Live already speaks with these models; the speech lane (Transcript-mode
/// answers, fillers, acknowledgements) used the dedicated TTS models instead,
/// whose free-tier quota is a handful of requests per day. This renderer keeps
/// ONE warm Live session whose only job is "read this text verbatim", so a
/// Transcript answer gets the voice the user chose, with the first audio chunk
/// arriving a few hundred milliseconds after the text is sent.
///
/// Turns are pipelined: text is sent as soon as it is available, and the server
/// queues the next turn while the current one is still speaking (verified: no
/// interruption and every queued turn is read in full). Waiting for each
/// `turnComplete` before sending the next chunk is what made the joins audible.
///
/// The model is a dialogue model, not a TTS endpoint: the verbatim contract
/// lives in the system instruction, so a lapse is a quality issue and never a
/// correctness one — callers keep the on-device voice as their fallback.
///
/// All socket + queue state lives on `q`; the public API is thread-safe and
/// `speak` is awaitable (its own `turnComplete` resolves it; a session failure
/// throws).
final class NativeAudioSpeechRenderer: @unchecked Sendable {
  static let shared = NativeAudioSpeechRenderer()

  /// Languages that read Serbian, with the native-audio dialogue model as the
  /// pinned default. `speak`/`README` names here are the wire ids.
  nonisolated static let defaultModelID = "gemini-2.5-flash-native-audio-latest"
  nonisolated static let modelOptions: [NativeAudioModelOption] = [
    NativeAudioModelOption(
      id: defaultModelID, label: "2.5 Flash Native Audio (recommended)"),
    NativeAudioModelOption(
      id: "gemini-3.1-flash-live-preview", label: "3.1 Flash Live"),
    NativeAudioModelOption(
      id: "gemini-3.8-live", label: "3.8 Live"),
  ]

  /// The model Voice Live pins as its native-audio dialogue choice.
  nonisolated static var modelID: String { RealtimeOmniProvider.geminiNativeAudioDialog.modelID }

  nonisolated static let modelDefaultsKey = "speechNativeAudioModel"

  /// The user's pick, validated against the offered set so a retired or
  /// hand-edited id can never reach the wire.
  nonisolated static var selectedModelID: String {
    let stored = UserDefaults.standard.string(forKey: modelDefaultsKey) ?? ""
    return modelOptions.contains { $0.id == stored } ? stored : defaultModelID
  }

  nonisolated static func modelLabel(for id: String) -> String {
    modelOptions.first { $0.id == id }?.label ?? id
  }

  /// Rough Serbian speech rate, used to bound how long a reader turn may run.
  nonisolated static let nativeAudioCharactersPerSecond: Double = 13
  /// A reader turn may not run far past its text's expected speech duration:
  /// dialogue models occasionally keep talking or stream silence (observed
  /// live: ~100 s of audio for a 51-character line, with no `turnComplete`).
  /// The cap is three times the expected duration, never below 20 s, so
  /// legitimately slow speech is not cut.
  nonisolated static let runawayAudioFactor: Double = 2.5
  nonisolated static let minimumRunawayCapSeconds: TimeInterval = 15

  /// Whether the server's transcription shows a model that left the script.
  /// Generous: the reader may add a short natural token, but it may not keep
  /// talking past its text (observed live: ~100 s of audio for a 51-character
  /// line).
  nonisolated static func isOffScript(spokenCharacters: Int, scriptCharacters: Int) -> Bool {
    let allowed = max(scriptCharacters + 40, scriptCharacters * 6 / 5)
    return spokenCharacters > allowed
  }

  /// The longest audio a turn for `characterCount` characters may deliver.
  nonisolated static func runawayCapSeconds(forCharacterCount characterCount: Int) -> TimeInterval {
    max(
      minimumRunawayCapSeconds,
      Double(characterCount) / nativeAudioCharactersPerSecond * runawayAudioFactor)
  }

  /// After `generationComplete` the server may still be streaming audio (the
  /// API sends it while the spoken audio drains). The turn is finished once the
  /// stream has been quiet for this long, so trailing audio is never dropped.
  nonisolated static let generationQuietSeconds: TimeInterval = 1.5
  /// A reader that has spoken and then gone silent for this long is finished,
  /// whatever the server does with `turnComplete` — 3.8 Live keeps streaming
  /// silence for tens of seconds after the script (observed live: 20 s of audio
  /// for a 51-character line).
  nonisolated static let silenceCompletionSeconds: TimeInterval = 2
  /// Peak amplitude above which a PCM buffer counts as audible speech.
  nonisolated static let audiblePeakThreshold: Float = 0.02

  /// Peak amplitude (0…1) of little-endian Int16 PCM, sampled sparsely — this
  /// only has to tell speech from silence, not measure loudness.
  nonisolated static func peakLevel(ofPCM16 data: Data) -> Float {
    guard data.count >= 2 else { return 0 }
    var peak: Int16 = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let samples = raw.bindMemory(to: Int16.self)
      var index = 0
      while index < samples.count {
        let magnitude = samples[index] == Int16.min ? Int16.max : abs(samples[index])
        if magnitude > peak { peak = magnitude }
        index += 32
      }
    }
    return Float(peak) / 32_768
  }
  /// How long a session may spend reaching `setupComplete`.
  nonisolated static let setupTimeout: TimeInterval = 8
  /// A reader turn that produces no server message for this long is stalled.
  nonisolated static let stallTimeout: TimeInterval = 20
  /// A failed session is not retried on every chunk; the fallback voice speaks
  /// while the lane backs off. Applies only to sessions that never became ready
  /// (see `backoffApplies`).
  nonisolated static let failureBackoff: TimeInterval = 10
  /// The warm session is closed after this much silence and rebuilt on demand.
  /// Google resets an idle Live session at ~40 s (observed: `Connection reset
  /// by peer` on a warm socket), so closing first makes the next answer pay a
  /// predictable reconnect instead of a failed turn.
  nonisolated static let idleCloseDelay: TimeInterval = 30

  /// A socket that reached `setupComplete` and then dropped is a transient
  /// close — Google recycles idle sessions, networks flap — so the next
  /// utterance may reconnect immediately. Only a session that never became
  /// ready (bad key, quota, unreachable host) earns the backoff.
  nonisolated static func backoffApplies(afterFailureWhileReady wasReady: Bool) -> Bool {
    !wasReady
  }

  enum RendererFailure: LocalizedError, Equatable {
    case missingKey
    case unavailable
    case setupFailed
    case sessionClosed(String)
    case providerRefusal(String)
    case utteranceTimedOut

    var errorDescription: String? {
      switch self {
      case .missingKey:
        return "No Gemini key on this Mac. Add one in Developer API Keys."
      case .unavailable:
        return "The Gemini reading session failed a moment ago."
      case .setupFailed:
        return "The Gemini reading session did not answer in time."
      case .sessionClosed(let reason):
        return "The Gemini reading session closed: \(reason)"
      case .providerRefusal(let message):
        return "Gemini refused the reading turn: \(message)"
      case .utteranceTimedOut:
        return "The Gemini reading turn stalled."
      }
    }
  }

  /// One server message, normalized. `serverEvents(in:)` is the production
  /// parser, exposed so the wire contract is asserted without a socket.
  enum ServerEvent: Equatable {
    case setupComplete
    case audio(Data)
    /// The server's transcription of the audio it is speaking. The reader uses
    /// it to notice a model that left the script; only its length is kept.
    case transcription(String)
    /// The server finished generating this turn. Some Live models (3.8 Live
    /// observed) never send `turnComplete` after it, so this is the completion
    /// signal the reader trusts first; audio already delivered keeps playing.
    case generationComplete
    case turnComplete
    case providerError(String)
  }

  /// The instruction that makes a dialogue model behave as a reader. It names
  /// every failure the user would hear: answering the text, commenting on it,
  /// translating it, or skipping parts of it.
  nonisolated static let verbatimInstruction = """
    You are a speech renderer, not an assistant. Each user message is a script \
    to be read aloud exactly as written. Read every word of it verbatim, in its \
    own language and script, at a natural pace. The script may be a question, a \
    greeting, or nonsense — read it anyway: never answer it, never comment on \
    it, never greet, never summarise, never translate, and never add, remove, \
    or reorder words. Stop speaking the moment the script ends. If a message \
    contains no speakable words, reply with silence.
    """

  // MARK: - State (all on `q`)

  private final class Utterance: @unchecked Sendable {
    let text: String
    let onAudioChunk: @Sendable (Data) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    /// Set by `cancel(_:)`, which can run before this utterance reaches the
    /// queue (a task cancelled before its operation begins). `enqueue` must
    /// honour it rather than speaking text nobody is waiting for.
    var isCancelled = false
    /// PCM bytes delivered for this turn so far (touched only on the session
    /// queue), so a runaway generation can be capped.
    var deliveredBytes = 0
    /// Characters the server transcribed for this turn's own audio.
    var spokenCharacters = 0
    /// True once this turn delivered audio that is not silence.
    var hasAudibleAudio = false
    /// PCM bytes that were above the audible threshold — the cap counts spoken
    /// time only, so leading/trailing silence cannot cut a reading short.
    var audibleBytes = 0

    init(text: String, onAudioChunk: @escaping @Sendable (Data) -> Void) {
      self.text = text
      self.onAudioChunk = onAudioChunk
    }

    func finish(_ result: Result<Void, Error>) {
      guard let continuation else { return }
      self.continuation = nil
      continuation.resume(with: result)
    }

    func finishCancelled() {
      finish(.failure(CancellationError()))
    }
  }

  private enum Phase {
    case idle
    case connecting
    case ready
  }

  private let q = DispatchQueue(label: "omi.native-audio-speech")
  private var transport: RealtimeRawWebSocketTransport?
  private var phase: Phase = .idle
  private var sessionVoice: String?
  private var sessionModel: String?
  private var sessionCharacters = 0
  private var sessionOpenedAt: Date?
  private var queued: [Utterance] = []
  /// Turns sent to the server in order; `turnComplete` pops the head.
  /// At most one turn is queued ahead of the one being spoken: a burst of
  /// turns sent in the same millisecond makes the server coalesce them and lose
  /// the turn boundaries (observed: three sends, one `turnComplete`, stall).
  private var awaitingTurns: [Utterance] = []
  /// `turnComplete`s to swallow because the matching turn already finished
  /// locally after its audio drained. Without this a late `turnComplete` would
  /// pop the next turn's utterance.
  private var pendingServerTurnCompletions = 0
  /// True once the head turn's `generationComplete` arrived. The turn finishes
  /// when the audio stream has been quiet for `generationQuietSeconds`.
  private var headGenerationCompleted = false
  private var generationQuietTimer: DispatchSourceTimer?
  private var silenceTimer: DispatchSourceTimer?
  /// True once the head turn has produced its first audio. The next turn is
  /// sent at that point — the model is already speaking, so the queue keeps the
  /// speaker fed without a silent join (verified against the Live API: no
  /// interruption, every turn read in full).
  private var headProducedAudio = false
  /// A cancelled turn is still generating server-side. The next utterance takes
  /// a fresh socket (the hub's Gemini barge-in strategy) rather than queueing
  /// behind a reply nobody hears.
  private var awaitingCancelledTurnComplete = false
  private var unavailableUntil: Date?
  private var connectTimer: DispatchSourceTimer?
  private var stallTimer: DispatchSourceTimer?
  private var idleTimer: DispatchSourceTimer?
  /// Fences callbacks from a retired socket: a close/error/message delivered
  /// after `closeSession` must not fail the replacement session or mark a
  /// backoff for an intentional teardown.
  private var sessionGeneration = 0
  /// Injectable so the queue/session contract (pipelined turns, rotation) is
  /// behavioral-testable without a socket; production always uses RawWebSocket.
  private let rawWebSocketFactory: (URL, DispatchQueue) -> RealtimeRawWebSocketTransport

  init(
    rawWebSocketFactory: @escaping (URL, DispatchQueue) -> RealtimeRawWebSocketTransport = {
      RawWebSocket(url: $0, queue: $1)
    }
  ) {
    self.rawWebSocketFactory = rawWebSocketFactory
  }

  // MARK: - Public API

  /// Open the warm session before it is needed (an answer is still being
  /// generated), so the first chunk of speech does not pay the connect cost.
  func prewarm(voice: String) {
    q.async { [self] in
      guard phase == .idle else { return }
      guard !isBackingOff(), let key = Self.geminiKey() else { return }
      cancelIdleClose()
      openSession(voice: voice, model: Self.selectedModelID, key: key)
    }
  }

  /// Read `text` verbatim. Audio chunks arrive on the renderer's queue while the
  /// call is awaiting; the call resolves when the server completes its turn.
  func speak(
    text: String,
    voice: String,
    onAudioChunk: @escaping @Sendable (Data) -> Void
  ) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let utterance = Utterance(text: trimmed, onAudioChunk: onAudioChunk)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        utterance.continuation = continuation
        q.async { [self] in enqueue(utterance, voice: voice) }
      }
    } onCancel: {
      q.async { [self] in cancel(utterance) }
    }
  }

  /// Drop what is queued and abandon the turns already sent without closing the
  /// socket. The server generation they leave behind is fenced by
  /// `awaitingCancelledTurnComplete` until its `turnComplete` arrives.
  func cancelInFlight() {
    q.async { [self] in
      cancelIdleClose()
      abandonTurns()
      let dropped = queued
      queued = []
      for utterance in dropped { utterance.finish(.failure(CancellationError())) }
    }
  }

  /// Cancel everything and close the socket (explicit stop, mode switch).
  func stop() {
    q.async { [self] in
      abandonTurns()
      let dropped = queued
      queued = []
      for utterance in dropped { utterance.finish(.failure(CancellationError())) }
      closeSession(reason: "stop")
    }
  }

  // MARK: - Queue on `q`

  private func enqueue(_ utterance: Utterance, voice: String) {
    cancelIdleClose()
    if utterance.isCancelled {
      utterance.finishCancelled()
      return
    }
    if awaitingCancelledTurnComplete
      || (phase != .idle && (sessionVoice != voice || sessionModel != Self.selectedModelID))
    {
      // A cancelled generation still owns the server turns, and voice + model
      // are baked into setup, so neither state can be reused — take a fresh
      // socket (the hub's Gemini barge-in strategy) and let the old work fail.
      abandonTurns()
      let dropped = queued
      queued = []
      closeSession(reason: "fresh session required")
      for droppedUtterance in dropped { droppedUtterance.finishCancelled() }
    }
    guard let key = Self.geminiKey() else {
      utterance.finish(.failure(RendererFailure.missingKey))
      return
    }
    if phase == .idle, isBackingOff() {
      utterance.finish(.failure(RendererFailure.unavailable))
      return
    }
    queued.append(utterance)
    if phase == .idle {
      openSession(voice: voice, model: Self.selectedModelID, key: key)
    }
    pump()
  }

  /// Send queued turns up to the pipeline's limit: the head turn may have one
  /// successor waiting, and that successor goes out as soon as the head starts
  /// speaking. Never burst several turns into one millisecond.
  private func pump() {
    guard phase == .ready, !awaitingCancelledTurnComplete else { return }
    while let next = queued.first, canSendNextTurn() {
      queued.removeFirst()
      sendClientTurn(next.text)
      awaitingTurns.append(next)
      if awaitingTurns.count == 1 { headProducedAudio = false }
      sessionCharacters += next.text.count
    }
    if !awaitingTurns.isEmpty { armStallTimer() }
  }

  private func canSendNextTurn() -> Bool {
    if awaitingTurns.isEmpty { return true }
    return awaitingTurns.count == 1 && headProducedAudio
  }

  /// A turn that streams far past its text's expected speech duration is not
  /// reading — dialogue models can keep talking or stream silence (observed
  /// live: ~100 s of audio for a 51-character line, no `turnComplete`). The
  /// turn is finished as spoken and the session is retired; a pending successor
  /// fails into the caller's fallback rather than waiting on a dead generation.
  private func capRunawayTurn(_ head: Utterance) {
    let spokenSeconds = head.audibleBytes / 48_000
    log(
      "NativeAudioSpeechRenderer: capping runaway turn spokenSeconds=\(spokenSeconds) transcribed=\(head.spokenCharacters) script=\(head.text.count)"
    )
    head.finish(.success(()))
    let pending = awaitingTurns.dropFirst()
    awaitingTurns = []
    closeSession(reason: "runaway turn")
    for utterance in pending {
      utterance.finish(.failure(RendererFailure.sessionClosed("runaway turn")))
    }
  }

  private func completeTurn() {
    awaitingCancelledTurnComplete = false
    if pendingServerTurnCompletions > 0 {
      // This signal belongs to a turn already finished on generationComplete.
      pendingServerTurnCompletions -= 1
      pump()
      return
    }
    guard !awaitingTurns.isEmpty else {
      // The turn belonged to a cancelled utterance; nothing to resolve.
      pump()
      return
    }
    let finished = awaitingTurns.removeFirst()
    finished.finish(.success(()))
    headProducedAudio = false
    headGenerationCompleted = false
    cancelGenerationQuietTimer()
    cancelSilenceTimer()
    if awaitingTurns.isEmpty {
      cancelStallTimer()
      scheduleIdleClose()
      rotateSessionIfNeeded()
    }
    pump()
  }

  /// Cancel the outstanding turns without touching the socket. The server keeps
  /// generating them until the socket is retired; `awaitingCancelledTurnComplete`
  /// keeps the lane silent and `enqueue` takes a fresh socket next time.
  private func abandonTurns() {
    cancelStallTimer()
    let pending = awaitingTurns
    awaitingTurns = []
    headProducedAudio = false
    for utterance in pending { utterance.finishCancelled() }
    awaitingCancelledTurnComplete = awaitingCancelledTurnComplete || !pending.isEmpty
  }

  private func cancel(_ utterance: Utterance) {
    utterance.isCancelled = true
    if awaitingTurns.contains(where: { $0 === utterance }) {
      // Its slot keeps the FIFO order intact; the continuation is resumed here
      // and the later `turnComplete` becomes a no-op.
      utterance.finishCancelled()
      awaitingCancelledTurnComplete = true
      return
    }
    if let index = queued.firstIndex(where: { $0 === utterance }) {
      queued.remove(at: index)
    }
    utterance.finishCancelled()
  }

  // MARK: - Session on `q`

  private func openSession(voice: String, model: String, key: String) {
    guard let url = Self.sessionURL(key: key) else {
      failSession(RendererFailure.setupFailed)
      return
    }
    phase = .connecting
    sessionVoice = voice
    sessionModel = model
    sessionCharacters = 0
    sessionOpenedAt = Date()
    sessionGeneration += 1
    let generation = sessionGeneration
    let socket = rawWebSocketFactory(url, q)
    transport = socket
    socket.onOpen = { [weak self] in
      guard let self, generation == self.sessionGeneration else { return }
      self.sendSessionSetup(voice: voice, model: model)
    }
    socket.onMessage = { [weak self] data in
      guard let self, generation == self.sessionGeneration else { return }
      self.handle(data)
    }
    socket.onClose = { [weak self] code, reason in
      self?.failSessionIfCurrent(
        generation: generation,
        RendererFailure.sessionClosed("closed \(code) \(reason)"))
    }
    socket.onError = { [weak self] failure in
      self?.failSessionIfCurrent(
        generation: generation,
        RendererFailure.sessionClosed(failure.message))
    }
    socket.connect()
    scheduleConnectTimer()
  }

  private func failSessionIfCurrent(generation: Int, _ error: Error) {
    guard generation == sessionGeneration else { return }
    failSession(error)
  }

  private func sendSessionSetup(voice: String, model: String) {
    let payload = Self.sessionSetupPayload(voice: voice, model: model)
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else {
      failSession(RendererFailure.setupFailed)
      return
    }
    transport?.sendText(text, completion: nil)
  }

  private func handle(_ data: Data) {
    let events = Self.serverEvents(in: data)
    if !events.isEmpty { armStallTimer() }
    for event in events {
      switch event {
      case .setupComplete:
        guard phase == .connecting else { break }
        cancelConnectTimer()
        phase = .ready
        log(
          "NativeAudioSpeechRenderer: session ready voice=\(sessionVoice ?? "?") model=\(sessionModel ?? "?")")
        pump()
        // A prewarmed session whose answer never spoke must not hold the socket
        // (and its keepalive pings) for the process lifetime.
        if queued.isEmpty, awaitingTurns.isEmpty { scheduleIdleClose() }
      case .transcription(let text):
        // The model's own words, as the server heard them. A reader that says
        // far more than its script left the script.
        guard !awaitingCancelledTurnComplete, let head = awaitingTurns.first, !head.isCancelled else {
          break
        }
        head.spokenCharacters += text.count
        if Self.isOffScript(
          spokenCharacters: head.spokenCharacters, scriptCharacters: head.text.count)
        {
          log(
            "NativeAudioSpeechRenderer: capping off-script turn spoken=\(head.spokenCharacters) script=\(head.text.count)"
          )
          capRunawayTurn(head)
        }
      case .audio(let chunk):
        // Audio belongs to the oldest uncompleted turn. Cancelled or fenced
        // generations must not reach the speaker.
        guard !awaitingCancelledTurnComplete, let head = awaitingTurns.first, !head.isCancelled else {
          break
        }
        if !headProducedAudio {
          // The model started speaking: release the one successor turn so the
          // join has no silence to fall into.
          headProducedAudio = true
          pump()
        }
        head.onAudioChunk(chunk)
        head.deliveredBytes += chunk.count
        if Self.peakLevel(ofPCM16: chunk) >= Self.audiblePeakThreshold {
          head.hasAudibleAudio = true
          head.audibleBytes += chunk.count
          cancelSilenceTimer()
        } else if head.hasAudibleAudio {
          armSilenceTimer()
        }
        if headGenerationCompleted { armGenerationQuietTimer() }
        if Double(head.audibleBytes) / 48_000
          > Self.runawayCapSeconds(forCharacterCount: head.text.count)
        {
          capRunawayTurn(head)
        }
      case .generationComplete:
        // Generation is done, but the audio may still be streaming (the API
        // sends this before the last audio drains). Mark it and finish only
        // after the stream goes quiet, so trailing audio is never dropped; a
        // model that never sends `turnComplete` (3.8 Live observed) still
        // cannot stall the lane.
        guard !awaitingCancelledTurnComplete, awaitingTurns.first != nil else { break }
        headGenerationCompleted = true
        armGenerationQuietTimer()
      case .turnComplete:
        completeTurn()
      case .providerError(let message):
        failSession(RendererFailure.providerRefusal(message))
      }
    }
  }

  private func failSession(_ error: Error) {
    let wasReady = phase == .ready
    let failedTurns = awaitingTurns
    awaitingTurns = []
    closeSession(reason: error.localizedDescription)
    if Self.backoffApplies(afterFailureWhileReady: wasReady) {
      unavailableUntil = Date().addingTimeInterval(Self.failureBackoff)
    }
    for utterance in failedTurns { utterance.finish(.failure(error)) }
    let dropped = queued
    queued = []
    for utterance in dropped { utterance.finish(.failure(error)) }
    log("NativeAudioSpeechRenderer: session failed: \(error.localizedDescription)")
  }

  private func closeSession(reason: String) {
    cancelConnectTimer()
    cancelStallTimer()
    cancelIdleClose()
    // Retire callbacks from this socket before closing it: an in-flight
    // close/error must not fail the session that replaces it.
    sessionGeneration += 1
    transport?.close()
    transport = nil
    phase = .idle
    sessionVoice = nil
    sessionModel = nil
    sessionCharacters = 0
    sessionOpenedAt = nil
    // Callers resume the outstanding turns (with their error, or cancelled)
    // before closing; clearing here keeps no stale turn marker behind.
    awaitingTurns = []
    headProducedAudio = false
    headGenerationCompleted = false
    cancelGenerationQuietTimer()
    cancelSilenceTimer()
    pendingServerTurnCompletions = 0
    awaitingCancelledTurnComplete = false
    log("NativeAudioSpeechRenderer: session closed (\(reason))")
  }

  /// Retire the socket between turns so a day of answers never accumulates in
  /// one context. The replacement session is opened immediately, while the tail
  /// of the last answer is still playing, so the next chunk finds it warm.
  private func rotateSessionIfNeeded() {
    guard phase == .ready, queued.isEmpty, awaitingTurns.isEmpty else { return }
    let age = sessionOpenedAt.map { Date().timeIntervalSince($0) } ?? 0
    guard NativeAudioSessionRotation.shouldRotate(characters: sessionCharacters, age: age) else {
      return
    }
    let voice = sessionVoice
    let model = sessionModel
    log(
      "NativeAudioSpeechRenderer: rotating session characters=\(sessionCharacters) age=\(Int(age))s"
    )
    closeSession(reason: "context rotation")
    guard let voice, let model, let key = Self.geminiKey() else { return }
    openSession(voice: voice, model: model, key: key)
  }

  private func isBackingOff() -> Bool {
    guard let unavailableUntil else { return false }
    if unavailableUntil > Date() { return true }
    self.unavailableUntil = nil
    return false
  }

  // MARK: - Timers on `q`

  private func scheduleConnectTimer() {
    cancelConnectTimer()
    let timer = makeTimer(after: Self.setupTimeout) { [weak self] in
      self?.failSession(RendererFailure.setupFailed)
    }
    connectTimer = timer
  }

  private func cancelConnectTimer() {
    connectTimer?.cancel()
    connectTimer = nil
  }

  /// Restarted on every server message: a reader turn that goes quiet for
  /// `stallTimeout` fails the session so the fallback voice can speak.
  private func armStallTimer() {
    guard phase == .ready else { return }
    stallTimer?.cancel()
    let timer = makeTimer(after: Self.stallTimeout) { [weak self] in
      guard let self, self.phase == .ready, !self.awaitingCancelledTurnComplete,
        !self.awaitingTurns.isEmpty
      else { return }
      self.failSession(RendererFailure.utteranceTimedOut)
    }
    stallTimer = timer
  }

  private func cancelStallTimer() {
    stallTimer?.cancel()
    stallTimer = nil
  }

  /// Finish the head turn once `generationComplete` has arrived and no audio
  /// has followed for the quiet window. A turn that never produced audio waits
  /// for `turnComplete` (or the stall watchdog) instead of ending silently.
  private func armGenerationQuietTimer() {
    generationQuietTimer?.cancel()
    let timer = makeTimer(after: Self.generationQuietSeconds) { [weak self] in
      guard let self, self.headGenerationCompleted, !self.awaitingCancelledTurnComplete,
        let head = self.awaitingTurns.first, head.deliveredBytes > 0
      else { return }
      self.completeTurn()
      self.pendingServerTurnCompletions += 1
    }
    generationQuietTimer = timer
  }

  private func cancelGenerationQuietTimer() {
    generationQuietTimer?.cancel()
    generationQuietTimer = nil
  }

  /// The reader went silent after speaking: finish the turn once it has stayed
  /// silent for the window and the script should be done by now. This is what
  /// ends a 3.8 Live turn that keeps streaming silence forever.
  private func armSilenceTimer() {
    silenceTimer?.cancel()
    let timer = makeTimer(after: Self.silenceCompletionSeconds) { [weak self] in
      guard let self, !self.awaitingCancelledTurnComplete,
        let head = self.awaitingTurns.first, head.hasAudibleAudio
      else { return }
      let expected = Double(head.text.count) / Self.nativeAudioCharactersPerSecond
      let delivered = Double(head.deliveredBytes) / 48_000
      guard self.headGenerationCompleted || delivered >= expected else { return }
      log(
        "NativeAudioSpeechRenderer: completing after silence delivered=\(Int(delivered))s expected=\(Int(expected))s"
      )
      self.completeTurn()
      self.pendingServerTurnCompletions += 1
    }
    silenceTimer = timer
  }

  private func cancelSilenceTimer() {
    silenceTimer?.cancel()
    silenceTimer = nil
  }

  private func scheduleIdleClose() {
    cancelIdleClose()
    let timer = makeTimer(after: Self.idleCloseDelay) { [weak self] in
      guard let self, self.phase == .ready, self.awaitingTurns.isEmpty, self.queued.isEmpty else {
        return
      }
      self.closeSession(reason: "idle")
    }
    idleTimer = timer
  }

  private func cancelIdleClose() {
    idleTimer?.cancel()
    idleTimer = nil
  }

  private func makeTimer(after delay: TimeInterval, handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + delay)
    timer.setEventHandler(handler: handler)
    timer.resume()
    return timer
  }

  private func sendClientTurn(_ text: String) {
    let payload: [String: Any] = [
      "clientContent": [
        "turns": [["role": "user", "parts": [["text": text]]]],
        "turnComplete": true,
      ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return }
    transport?.sendText(json, completion: nil)
    log("NativeAudioSpeechRenderer: reading \(text.count) chars voice=\(sessionVoice ?? "?")")
  }

  // MARK: - Production seams (static, wire-level)

  nonisolated static func geminiKey() -> String? {
    guard let key = APIKeyService.byokKey(.gemini)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    else { return nil }
    return key
  }

  nonisolated static func sessionURL(key: String) -> URL? {
    var components = URLComponents(
      string:
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )
    components?.queryItems = [URLQueryItem(name: "key", value: key)]
    return components?.url
  }

  nonisolated static func sessionSetupPayload(voice: String, model: String = defaultModelID) -> [String: Any] {
    [
      "setup": [
        "model": "models/\(model)",
        "generationConfig": [
          "responseModalities": ["AUDIO"],
          "temperature": 0.1,
          "speechConfig": [
            "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]
          ],
        ],
        "systemInstruction": ["parts": [["text": verbatimInstruction]]],
        "outputAudioTranscription": [:],
        "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
        "contextWindowCompression": ["slidingWindow": [:]],
      ]
    ]
  }

  /// Normalized events in one server message: the setup ack, audio parts of a
  /// model turn, the turn boundary, and provider errors.
  nonisolated static func serverEvents(in message: Data) -> [ServerEvent] {
    guard let payload = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
      return []
    }
    if payload["setupComplete"] != nil { return [.setupComplete] }
    if let error = payload["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "Gemini Live error"
      return [.providerError(message)]
    }
    guard let serverContent = payload["serverContent"] as? [String: Any] else { return [] }
    var events: [ServerEvent] = []
    if let transcription = serverContent["outputTranscription"] as? [String: Any],
      let text = transcription["text"] as? String, !text.isEmpty
    {
      events.append(.transcription(text))
    }
    if let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
      for part in parts {
        guard let inline = part["inlineData"] as? [String: Any],
          let mime = inline["mimeType"] as? String, mime.contains("audio/pcm"),
          let encoded = inline["data"] as? String,
          let audio = Data(base64Encoded: encoded), !audio.isEmpty
        else { continue }
        events.append(.audio(audio))
      }
    }
    if (serverContent["generationComplete"] as? Bool) == true {
      events.append(.generationComplete)
    }
    if (serverContent["turnComplete"] as? Bool) == true { events.append(.turnComplete) }
    return events
  }
}
