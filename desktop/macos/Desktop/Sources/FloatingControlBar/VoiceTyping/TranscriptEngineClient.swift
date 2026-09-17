import Foundation

/// Client for the user's own local Transcript Engine (whisper.cpp behind a
/// versioned local API).
///
/// When the user pins the engine as their Speech-to-Text Engine, this client —
/// not Omi's cloud batch and not the bundled Parakeet — decodes the turn, so
/// the model that transcribes is the one they chose.
struct TranscriptEngineClient: Sendable {
  static let baseURLDefaultsKey = "transcriptEngineBaseURL"
  static let defaultBaseURL = "http://127.0.0.1:8765"
  /// The API currently accepts one language. Anything else must fall back to
  /// the built-in chain rather than sending audio the engine cannot decode.
  static let supportedLanguages: Set<String> = ["sr"]

  struct Result: Sendable, Equatable {
    let transcript: String
    let provider: String
    let model: String?
  }

  enum Failure: Error, Equatable, CustomStringConvertible {
    case unavailable
    case unsupportedLanguage(String)
    case rejected(code: String?)
    case timedOut
    case malformedResponse

    var description: String {
      switch self {
      case .unavailable: return "transcript engine unreachable"
      case .unsupportedLanguage(let code): return "transcript engine does not support \(code)"
      case .rejected(let code): return "transcript engine job failed (\(code ?? "unknown"))"
      case .timedOut: return "transcript engine timed out"
      case .malformedResponse: return "transcript engine returned an unexpected response"
      }
    }
  }

  let baseURL: URL
  private let session: URLSession

  init(baseURL: URL? = nil, session: URLSession = .shared) {
    self.baseURL = baseURL ?? URL(string: Self.defaultBaseURL)!
    self.session = session
  }

  /// The engine at the user's configured address.
  static var configured: TranscriptEngineClient {
    let raw =
      UserDefaults.standard.string(forKey: baseURLDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let url = URL(string: raw), url.scheme != nil else {
      return TranscriptEngineClient()
    }
    return TranscriptEngineClient(baseURL: url)
  }

  /// Liveness only — readiness keeps a cold model from being reported as down.
  func isReady(timeout: TimeInterval = 1.5) async -> Bool {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/health/ready"))
    request.timeoutInterval = timeout
    guard let (_, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse
    else { return false }
    return (200..<300).contains(http.statusCode)
  }

  /// Submits one turn's audio, waits for the job, and returns its transcript.
  ///
  /// `budget` bounds the whole wait (submit + job + read): a voice turn must not
  /// hang on a stalled local server.
  func transcribe(
    pcm16k: Data,
    language: String,
    budget: TimeInterval = 45
  ) async throws -> Result {
    let code = Self.normalizedLanguage(language)
    guard Self.supportedLanguages.contains(code) else {
      throw Failure.unsupportedLanguage(code)
    }
    let deadline = Date().addingTimeInterval(budget)
    let created = try await createTranscription(wav: Self.wav(pcm16k: pcm16k), language: code)
    let state = try await waitForJob(jobID: created.jobID, until: deadline)
    guard state == "succeeded" else {
      throw Failure.rejected(code: state)
    }
    let text = try await readTranscription(id: created.transcriptionID)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.malformedResponse }
    return Result(
      transcript: trimmed,
      provider: "transcript-engine",
      model: await activeModelName())
  }

  // MARK: - Wire

  private struct Created: Decodable {
    let jobID: String
    let transcriptionID: String

    enum CodingKeys: String, CodingKey {
      case jobID = "job_id"
      case transcriptionID = "transcription_id"
    }
  }

  private func createTranscription(wav: Data, language: String) async throws -> Created {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
    let boundary = "omi-\(UUID().uuidString)"
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data()
    func append(_ string: String) {
      body.append(Data(string.utf8))
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\n")
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(wav)
    append("\r\n--\(boundary)--\r\n")
    request.httpBody = body

    guard let data = try? await session.data(for: request).0 else { throw Failure.unavailable }
    guard let created = try? JSONDecoder().decode(Created.self, from: data) else {
      throw Failure.malformedResponse
    }
    return created
  }

  private struct Job: Decodable {
    let state: String
  }

  private func waitForJob(jobID: String, until deadline: Date) async throws -> String {
    while Date() < deadline {
      var components = URLComponents(
        url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"), resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "wait_ms", value: "15000")]
      var request = URLRequest(url: components.url!)
      request.timeoutInterval = 20
      guard let data = try? await session.data(for: request).0,
        let job = try? JSONDecoder().decode(Job.self, from: data)
      else { throw Failure.unavailable }
      if job.state != "queued" && job.state != "running" && job.state != "pending" {
        return job.state
      }
    }
    throw Failure.timedOut
  }

  private struct Transcription: Decodable {
    let text: String?
  }

  private func readTranscription(id: String) async throws -> String {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcriptions/\(id)"))
    request.timeoutInterval = 10
    guard let data = try? await session.data(for: request).0,
      let transcription = try? JSONDecoder().decode(Transcription.self, from: data),
      let text = transcription.text
    else { throw Failure.malformedResponse }
    return text
  }

  /// Best-effort human name of the engine's active recognizer, for the
  /// per-message caption. Never blocks a transcript on its own failure.
  private func activeModelName() async -> String? {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
    request.timeoutInterval = 3
    guard let data = try? await session.data(for: request).0,
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    // The API answers either a bare list or the `{active_model_id, models}`
    // envelope; accept both so a version bump cannot silently drop the name.
    if let envelope = object as? [String: Any] {
      if let active = envelope["active_model_id"] as? String, !active.isEmpty {
        return active
      }
      if let models = envelope["models"] as? [[String: Any]] {
        return Self.activeModelID(in: models)
      }
      return nil
    }
    if let models = object as? [[String: Any]] {
      return Self.activeModelID(in: models)
    }
    return nil
  }

  private static func activeModelID(in models: [[String: Any]]) -> String? {
    models.first { ($0["active"] as? Bool) == true }?["id"] as? String
  }

  // MARK: - Pure helpers

  static func normalizedLanguage(_ raw: String) -> String {
    let base = raw.split(separator: "-").first.map(String.init) ?? raw
    return base.lowercased()
  }

  /// Wraps raw 16 kHz mono signed-16-bit PCM in a WAV container; the engine's
  /// normalization expects a real audio file, not a bare byte stream.
  static func wav(pcm16k: Data) -> Data {
    let sampleRate: UInt32 = 16_000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    var out = Data(capacity: 44 + pcm16k.count)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
    out.append(Data("RIFF".utf8))
    append(UInt32(36 + pcm16k.count))
    out.append(Data("WAVE".utf8))
    out.append(Data("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(channels)
    append(sampleRate)
    append(byteRate)
    append(blockAlign)
    append(bitsPerSample)
    out.append(Data("data".utf8))
    append(UInt32(pcm16k.count))
    out.append(pcm16k)
    return out
  }
}
