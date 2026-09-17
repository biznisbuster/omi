import Foundation

/// One push-to-talk turn streamed to the engine's progressive session
/// (`POST /v1/transcriptions/stream`, chunk `PUT`s, `finish`), so the engine
/// decodes audio while the user is still holding the key. Key-up then waits for
/// the tail instead of for the whole utterance — the batch path uploads
/// everything only after release and pays the full decode then.
///
/// The chunk shape mirrors the engine's own companion client: chunk 0 carries a
/// WAV header with unknown sizes plus the first ~0.25 s of audio, later chunks
/// are up to one second each, and every chunk is the next byte range of one
/// logical WAV file.
///
/// The engine's own documentation is the contract used here:
/// - session create takes `{language, filename?, media_type?}` + `Idempotency-Key`
/// - chunks are strictly sequenced (`sequence` must advance by one)
/// - `partial?wait_ms=` serves the committed `text` plus the display-only
///   `tail_text` while the take is open
/// - `finish` queues the normal initial ASR job, whose result is read exactly
///   like the batch path's (`GET /v1/jobs/{id}` then `GET /v1/transcriptions/{id}`)
actor TranscriptEngineStreamClient {
  /// Byte-range policy for one take. Pure, so the boundaries — which only move
  /// once per chunk, never per mic callback — are testable without a server.
  struct Chunker {
    /// Canonical WAV header size for 16 kHz mono signed-16-bit PCM.
    static let headerBytes = WAVContainer.headerBytes
    /// Total bytes of chunk 0, header included. The companion's constant: the
    /// engine starts provisional recognition after ~0.25 s instead of waiting
    /// for a full second.
    static let firstChunkTotalBytes = 8_192
    /// Later chunks: one second of the same 16 kHz mono s16le stream.
    static let laterChunkBytes = 32_000

    private(set) var buffered = Data()
    private(set) var chunksSent = 0
    private(set) var sentBytes = 0

    mutating func append(_ pcm: Data) {
      buffered.append(pcm)
    }

    /// The next chunk to upload, or nil while more audio is needed. Chunk 0
    /// waits for its small floor unless the take is already finishing.
    mutating func takeChunk(isFinishing: Bool = false) -> Data? {
      guard !buffered.isEmpty else { return nil }
      if chunksSent == 0 {
        let floor = Self.firstChunkTotalBytes - Self.headerBytes
        guard buffered.count >= floor || isFinishing else { return nil }
        let take = min(buffered.count, Self.laterChunkBytes)
        let pcm = buffered.prefix(take)
        buffered.removeFirst(take)
        chunksSent = 1
        sentBytes += Self.headerBytes + pcm.count
        return Self.streamingWAVHeader + pcm
      }
      let take = min(buffered.count, Self.laterChunkBytes)
      let pcm = buffered.prefix(take)
      buffered.removeFirst(take)
      chunksSent += 1
      sentBytes += pcm.count
      return Data(pcm)
    }

    var hasSentAnything: Bool { chunksSent > 0 }
    var hasBufferedAudio: Bool { !buffered.isEmpty }

    /// WAV container for a take whose final length is unknown: both size fields
    /// carry the conventional "read until end of stream" placeholder, which is
    /// what a growing recording file holds while it is still being written.
    static var streamingWAVHeader: Data {
      WAVContainer.streamingHeader(sampleRate: 16_000)
    }
  }

  private struct SessionCreated: Decodable {
    let sessionID: String
    let nextSequence: Int

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
      case nextSequence = "next_sequence"
    }
  }

  private struct Job: Decodable {
    let state: String
  }

  private struct Transcription: Decodable {
    let text: String?
  }

  private struct Partial: Decodable {
    let text: String?
    let tailText: String?

    enum CodingKeys: String, CodingKey {
      case text
      case tailText = "tail_text"
    }
  }

  private struct FinishResponse: Decodable {
    let jobID: String
    let transcriptionID: String

    enum CodingKeys: String, CodingKey {
      case jobID = "job_id"
      case transcriptionID = "transcription_id"
    }
  }

  private let baseURL: URL
  private let session: URLSession
  private var chunker = Chunker()
  private var sessionID: String?
  private var nextSequence = 0
  private var pumpTask: Task<Void, Never>?
  private var isFinishing = false
  private var isStopped = false
  private var failure: Error?
  private var language = "sr"

  init(baseURL: URL? = nil, session: URLSession = .shared) {
    self.baseURL = baseURL ?? TranscriptEngineClient.configured.baseURL
    self.session = session
  }

  /// Creates the engine's progressive session. Throws when the engine cannot be
  /// reached or refuses the session, so the caller can fall back to the batch
  /// path and tell the user the engine is not answering.
  func start(language: String) async throws {
    let code = TranscriptEngineClient.normalizedLanguage(language)
    guard TranscriptEngineClient.supportedLanguages.contains(code) else {
      throw TranscriptEngineClient.Failure.unsupportedLanguage(code)
    }
    self.language = code
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions/stream"))
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
    let body: [String: String] = [
      "language": code,
      "filename": "omi-turn.wav",
      "media_type": "audio/wav",
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    do {
      let (data, response) = try await self.session.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
        let engineError = TranscriptEngineClient.Failure.engineError(from: data)
      {
        throw engineError
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw TranscriptEngineClient.Failure.unavailable
      }
      guard let created = try? JSONDecoder().decode(SessionCreated.self, from: data),
        !created.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw TranscriptEngineClient.Failure.malformedResponse }
      sessionID = created.sessionID
      nextSequence = created.nextSequence
      startPumpIfNeeded()
    } catch {
      // A session that never opened must not keep buffering audio or look like
      // a usable transcript source to the caller.
      isStopped = true
      throw error
    }
  }

  /// Feed the next mic chunk. Returns immediately; uploads happen on the pump.
  func append(pcm16k: Data) {
    guard !isStopped, failure == nil else { return }
    chunker.append(pcm16k)
    startPumpIfNeeded()
  }

  /// Live display text while the take is open: the committed stitch plus the
  /// engine's display-only tail. Nil while nothing is decodable yet.
  func partialText() async -> String? {
    guard let sessionID, !isStopped,
      let url = url(
        path: "v1/transcriptions/stream/\(sessionID)/partial", query: ["wait_ms": "1500"])
    else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    guard let (data, _) = try? await session.data(for: request),
      let partial = try? JSONDecoder().decode(Partial.self, from: data)
    else { return nil }
    let committed = partial.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let tail = partial.tailText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let combined = [committed, tail].filter { !$0.isEmpty }.joined(separator: " ")
    return combined.isEmpty ? nil : combined
  }

  /// Flushes the remaining audio, finishes the session, and reads the final
  /// transcript through the same job/result flow the batch client uses.
  func finishAndRead(budget: TimeInterval = 25) async throws -> TranscriptEngineClient.Result {
    guard let sessionID else {
      throw failure ?? TranscriptEngineClient.Failure.unavailable
    }
    isFinishing = true
    await pumpTask?.value

    var request = URLRequest(
      url: baseURL.appendingPathComponent("v1/transcriptions/stream/\(sessionID)/finish"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["language": language])

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
      let engineError = TranscriptEngineClient.Failure.engineError(from: data)
    {
      throw engineError
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let finished = try? JSONDecoder().decode(FinishResponse.self, from: data)
    else { throw failure ?? TranscriptEngineClient.Failure.malformedResponse }
    isStopped = true

    let deadline = Date().addingTimeInterval(budget)
    let state = try await waitForJob(jobID: finished.jobID, until: deadline)
    guard state == "succeeded" else {
      throw TranscriptEngineClient.Failure.rejected(code: state)
    }
    let text = try await readTranscription(id: finished.transcriptionID)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TranscriptEngineClient.Failure.malformedResponse }
    return TranscriptEngineClient.Result(
      transcript: trimmed,
      provider: "transcript-engine",
      // Same client the caller configured: the model name must come from this
      // engine, not from a second client pointed at the default address (which
      // also made the test depend on a live server).
      model: await TranscriptEngineClient(baseURL: baseURL, session: session).activeModelName())
  }

  /// Best-effort release of an abandoned take. Never throws.
  func cancel() async {
    isStopped = true
    pumpTask?.cancel()
    guard let sessionID else { return }
    var request = URLRequest(
      url: baseURL.appendingPathComponent("v1/transcriptions/stream/\(sessionID)/cancel"))
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    _ = try? await session.data(for: request)
  }

  // MARK: - Pump

  /// A request URL built without force unwraps: a malformed base address is a
  /// configuration mistake, not a crash.
  private func url(path: String, query: [String: String] = [:]) -> URL? {
    guard
      var components = URLComponents(
        url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
    else { return nil }
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      }
    }
    return components.url
  }

  private func startPumpIfNeeded() {
    // Audio may arrive before the session create completes; the buffer holds it
    // and the pump starts only once there is a session to upload to.
    guard pumpTask == nil, sessionID != nil, !isStopped, failure == nil else { return }
    pumpTask = Task { [weak self] in
      await self?.pump()
    }
  }

  /// Serial upload loop: exactly one chunk is in flight at a time and the
  /// engine's `next_sequence` is only advanced by the acknowledgement, so a
  /// retried chunk can never be duplicated or skipped.
  private func pump() async {
    defer { pumpTask = nil }
    while !isStopped, failure == nil {
      guard let chunk = chunker.takeChunk(isFinishing: isFinishing) else {
        if isFinishing { return }
        try? await Task.sleep(for: .milliseconds(120))
        continue
      }
      do {
        try await upload(chunk: chunk, sequence: nextSequence)
      } catch {
        failure = error
        return
      }
    }
  }

  private func upload(chunk: Data, sequence: Int) async throws {
    guard let sessionID else { throw TranscriptEngineClient.Failure.unavailable }
    var request = URLRequest(
      url: baseURL.appendingPathComponent(
        "v1/transcriptions/stream/\(sessionID)/chunks/\(sequence)"))
    request.httpMethod = "PUT"
    request.timeoutInterval = 10
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = chunk
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptEngineClient.Failure.unavailable
    }
    // A refused chunk means the session cannot proceed (cancelled, expired, a
    // sequence conflict, or the engine's model is unavailable); the engine's
    // own code and message are the useful part, so they are kept verbatim.
    guard (200..<300).contains(http.statusCode) else {
      throw TranscriptEngineClient.Failure.engineError(from: data)
        ?? TranscriptEngineClient.Failure.rejected(code: "chunk_\(http.statusCode)")
    }
    nextSequence = sequence + 1
  }

  // MARK: - Result flow (same shape as the batch client)

  private func waitForJob(jobID: String, until deadline: Date) async throws -> String {
    while Date() < deadline {
      guard let url = url(path: "v1/jobs/\(jobID)", query: ["wait_ms": "15000"]) else {
        throw TranscriptEngineClient.Failure.unavailable
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 20
      guard let (data, _) = try? await session.data(for: request),
        let job = try? JSONDecoder().decode(Job.self, from: data)
      else { throw TranscriptEngineClient.Failure.unavailable }
      if job.state != "queued" && job.state != "running" && job.state != "pending" {
        return job.state
      }
    }
    throw TranscriptEngineClient.Failure.timedOut
  }

  private func readTranscription(id: String) async throws -> String {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions/\(id)"))
    request.timeoutInterval = 10
    guard let (data, _) = try? await session.data(for: request),
      let transcription = try? JSONDecoder().decode(Transcription.self, from: data),
      let text = transcription.text
    else { throw TranscriptEngineClient.Failure.malformedResponse }
    return text
  }
}
