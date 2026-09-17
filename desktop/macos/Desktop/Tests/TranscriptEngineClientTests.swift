import XCTest

@testable import Omi_Computer

private final class TranscriptEngineURLStub: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
  private nonisolated(unsafe) static var requests: [(path: String, method: String, body: Data?)] = []

  static func reset() {
    lock.withLock {
      routes = [:]
      requests = []
    }
  }

  static func respond(path: String, status: Int = 200, json: String) {
    lock.withLock { routes[path] = (status, Data(json.utf8)) }
  }

  static var captured: [(path: String, method: String, body: Data?)] {
    lock.withLock { requests }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let path = url.path
    let body = Self.bodyData(from: request)
    let route = Self.lock.withLock { () -> (Int, Data)? in
      Self.requests.append((path, request.httpMethod ?? "GET", body))
      return Self.routes[path]
    }

    guard let (status, data) = route else {
      let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"detail":"not found"}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

/// The pinned local Transcript Engine must serve the transcript lane through its
/// versioned API, and its failures must fall back instead of stranding a turn.
final class TranscriptEngineClientTests: XCTestCase {
  private var client: TranscriptEngineClient!

  override func setUp() {
    super.setUp()
    TranscriptEngineURLStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TranscriptEngineURLStub.self]
    client = TranscriptEngineClient(
      baseURL: URL(string: "http://127.0.0.1:8765")!,
      session: URLSession(configuration: configuration))
  }

  func testTranscribeSubmitsAudioThenReadsTheTranscript() async throws {
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions", json: #"{"job_id":"job-1","transcription_id":"tr-1"}"#)
    TranscriptEngineURLStub.respond(path: "/v1/jobs/job-1", json: #"{"state":"succeeded"}"#)
    TranscriptEngineURLStub.respond(path: "/v1/transcriptions/tr-1", json: #"{"text":"  Zdravo svete  "}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/models",
      json:
        #"{"active_model_id":"whisper-turbo","models":[{"id":"whisper-tiny-sr","active":false},{"id":"whisper-turbo","active":true}]}"#
    )

    let result = try await client.transcribe(pcm16k: Data(repeating: 1, count: 3200), language: "sr")

    XCTAssertEqual(result.transcript, "Zdravo svete")
    XCTAssertEqual(result.provider, "transcript-engine")
    XCTAssertEqual(result.model, "whisper-turbo")

    let upload = try XCTUnwrap(
      TranscriptEngineURLStub.captured.first { $0.path == "/v1/transcriptions" })
    XCTAssertEqual(upload.method, "POST")
    let body = try XCTUnwrap(upload.body)
    XCTAssertTrue(
      String(decoding: body.prefix(4), as: UTF8.self).contains("--"),
      "the upload must be multipart")
    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("name=\"language\""))
    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("RIFF"), "the audio must be a WAV")
  }

  func testAFailedJobIsRejectedInsteadOfReturningEmptyText() async {
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions", json: #"{"job_id":"job-2","transcription_id":"tr-2"}"#)
    TranscriptEngineURLStub.respond(path: "/v1/jobs/job-2", json: #"{"state":"failed"}"#)

    do {
      _ = try await client.transcribe(pcm16k: Data(repeating: 1, count: 3200), language: "sr")
      XCTFail("a failed job must not read as a transcript")
    } catch let failure as TranscriptEngineClient.Failure {
      XCTAssertEqual(failure, .rejected(code: "failed"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testUnsupportedLanguageFailsWithoutTouchingTheEngine() async {
    do {
      _ = try await client.transcribe(pcm16k: Data(repeating: 1, count: 3200), language: "en")
      XCTFail("the engine only decodes the languages it advertises")
    } catch let failure as TranscriptEngineClient.Failure {
      XCTAssertEqual(failure, .unsupportedLanguage("en"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertTrue(TranscriptEngineURLStub.captured.isEmpty)
  }

  func testReadyReflectsTheHealthEndpoint() async {
    TranscriptEngineURLStub.respond(path: "/v1/health/ready", json: #"{"status":"ready"}"#)
    let ready = await client.isReady()
    XCTAssertTrue(ready)

    TranscriptEngineURLStub.reset()
    let down = await client.isReady()
    XCTAssertFalse(down)
  }

  func testLanguageNormalizationAcceptsRegions() {
    XCTAssertEqual(TranscriptEngineClient.normalizedLanguage("sr-RS"), "sr")
    XCTAssertEqual(TranscriptEngineClient.normalizedLanguage("SR"), "sr")
  }

  func testWavWrapperCarriesPcm16HeaderAndPayload() throws {
    let pcm = Data(repeating: 7, count: 1000)
    let wav = TranscriptEngineClient.wav(pcm16k: pcm)

    XCTAssertEqual(wav.count, 44 + pcm.count)
    XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
    XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
    XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
    let dataSize = wav[40..<44].withUnsafeBytes { $0.load(as: UInt32.self) }
    XCTAssertEqual(UInt32(littleEndian: dataSize), UInt32(pcm.count))
  }

  // MARK: - Progressive (streaming) lane

  func testStreamedTurnUploadsTheHeaderChunkThenReadsTheTranscript() async throws {
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream",
      json: #"{"session_id":"sess-1","next_sequence":0}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream/sess-1/chunks/0",
      json: #"{"session_id":"sess-1","sequence":0,"next_sequence":1,"committed_bytes":8192,"duplicate":false}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream/sess-1/chunks/1",
      json: #"{"session_id":"sess-1","sequence":1,"next_sequence":2,"committed_bytes":20044,"duplicate":false}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream/sess-1/finish",
      json: #"{"job_id":"job-9","transcription_id":"tr-9"}"#)
    TranscriptEngineURLStub.respond(path: "/v1/jobs/job-9", json: #"{"state":"succeeded"}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/tr-9", json: #"{"text":"  Zdravo iz stream-a  "}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/models",
      json: #"{"active_model_id":"whisper-turbo","models":[{"id":"whisper-turbo","active":true}]}"#)

    let stream = TranscriptEngineStreamClient(
      baseURL: URL(string: "http://127.0.0.1:8765")!,
      session: stubbedSession())
    try await stream.start(language: "sr")
    // Enough audio for two chunks: the header chunk plus the continuing PCM tail.
    await stream.append(pcm16k: Data(repeating: 3, count: 60_000))
    let result = try await stream.finishAndRead()

    XCTAssertEqual(result.transcript, "Zdravo iz stream-a")
    XCTAssertEqual(result.provider, "transcript-engine")
    XCTAssertEqual(result.model, "whisper-turbo")

    let create = try XCTUnwrap(
      TranscriptEngineURLStub.captured.first { $0.path == "/v1/transcriptions/stream" })
    XCTAssertEqual(create.method, "POST")
    XCTAssertTrue(
      String(decoding: try XCTUnwrap(create.body), as: UTF8.self).contains("\"language\":\"sr\""))

    let chunk0 = try XCTUnwrap(
      TranscriptEngineURLStub.captured.first {
        $0.path == "/v1/transcriptions/stream/sess-1/chunks/0"
      })
    XCTAssertEqual(chunk0.method, "PUT")
    let firstBody = try XCTUnwrap(chunk0.body)
    XCTAssertEqual(
      String(decoding: firstBody.prefix(4), as: UTF8.self), "RIFF",
      "the engine can only demux a real audio file, so chunk 0 must carry the WAV header")
    let riffSize = firstBody[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
    XCTAssertEqual(
      UInt32(littleEndian: riffSize), UInt32.max,
      "a take whose final length is unknown uses the streaming placeholder")

    let chunk1 = try XCTUnwrap(
      TranscriptEngineURLStub.captured.first {
        $0.path == "/v1/transcriptions/stream/sess-1/chunks/1"
      })
    XCTAssertNotEqual(
      String(decoding: try XCTUnwrap(chunk1.body).prefix(4), as: UTF8.self), "RIFF",
      "later chunks are the continuing PCM range, not a second WAV file")

    XCTAssertTrue(
      TranscriptEngineURLStub.captured.contains {
        $0.path == "/v1/transcriptions/stream/sess-1/finish" && $0.method == "POST"
      })
  }

  func testStreamedTurnReadsTheLivePartialTextWhileOpen() async throws {
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream",
      json: #"{"session_id":"sess-2","next_sequence":0}"#)
    TranscriptEngineURLStub.respond(
      path: "/v1/transcriptions/stream/sess-2/partial",
      json: #"{"partial_generation":3,"text":"Zdravo","tail_text":"Marko kako"}"#)

    let stream = TranscriptEngineStreamClient(
      baseURL: URL(string: "http://127.0.0.1:8765")!,
      session: stubbedSession())
    try await stream.start(language: "sr")

    let partial = await stream.partialText()
    XCTAssertEqual(partial, "Zdravo Marko kako")
  }

  func testStreamStartFailureStopsBufferingAndSurfacesTheEngineError() async {
    // No stub for /v1/transcriptions/stream: the session create answers 404.
    let stream = TranscriptEngineStreamClient(
      baseURL: URL(string: "http://127.0.0.1:8765")!,
      session: stubbedSession())
    do {
      try await stream.start(language: "sr")
      XCTFail("an unreachable engine must fail the session create")
    } catch is TranscriptEngineClient.Failure {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    await stream.append(pcm16k: Data(repeating: 1, count: 20_000))
    do {
      _ = try await stream.finishAndRead()
      XCTFail("a stream that never opened must not read as a transcript")
    } catch is TranscriptEngineClient.Failure {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TranscriptEngineURLStub.self]
    return URLSession(configuration: configuration)
  }
}

/// The engine's model chooser reads the public registry shape and reports what
/// an activation actually did (the engine loads a selected model only after a
/// restart it owns).
final class TranscriptEngineModelCatalogTests: XCTestCase {
  func testParsesRegisteredModelsWithTheirStates() throws {
    let json = """
      {"active_model_id":"whisper-turbo","models":[
        {"id":"whisper-tiny-sr","active":false,"available":false,"load_state":"unavailable","content_state":"installed"},
        {"id":"whisper-turbo","active":true,"available":true,"load_state":"loaded","content_state":"installed"},
        {"id":"","active":false,"available":true,"load_state":"loaded","content_state":"installed"}
      ]}
      """
    let entries = TranscriptEngineModelCatalog.parseModels(Data(json.utf8))
    XCTAssertEqual(entries.count, 2, "an empty id is not a model")
    XCTAssertEqual(entries[0].id, "whisper-tiny-sr")
    XCTAssertEqual(entries[0].stateLabel, "Installed, not loaded")
    XCTAssertTrue(entries[1].active)
    XCTAssertEqual(entries[1].stateLabel, "Active")
  }

  func testActivationReportsARestartRequirement() throws {
    let needsRestart = TranscriptEngineModelCatalog.parseActivation(
      Data(#"{"model_id":"whisper-large-v3","restart_required":true,"changed":true,"selection_generation":4}"#.utf8))
    XCTAssertEqual(
      needsRestart,
      TranscriptEngineModelCatalog.ActivationResult(
        modelID: "whisper-large-v3", restartRequired: true, changed: true))

    XCTAssertNil(
      TranscriptEngineModelCatalog.parseActivation(Data(#"{"changed":true}"#.utf8)),
      "a reply without a model id must not read as a selection")
  }
}
/// The streaming lane's byte policy: chunk 0 carries the header and a small
/// first slice so the engine can start early; later chunks are one second each
/// and never re-order or drop audio.
final class TranscriptEngineStreamChunkerTests: XCTestCase {
  func testFirstChunkWaitsForItsSmallFloorAndCarriesTheStreamingHeader() {
    var chunker = TranscriptEngineStreamClient.Chunker()
    chunker.append(Data(repeating: 1, count: 1000))
    XCTAssertNil(
      chunker.takeChunk(),
      "a first chunk that carries the header should wait for ~0.25 s of audio")

    chunker.append(Data(repeating: 2, count: 8000))
    let chunk = chunker.takeChunk()
    let data = try? XCTUnwrap(chunk)
    XCTAssertEqual(data?.count, 44 + 9000)
    XCTAssertEqual(String(decoding: (data ?? Data())[0..<4], as: UTF8.self), "RIFF")
  }

  func testChunksKeepByteOrderAndStayBounded() {
    var chunker = TranscriptEngineStreamClient.Chunker()
    let pcm = Data((0..<100_000).map { UInt8($0 % 251) })
    chunker.append(pcm)

    let first = chunker.takeChunk()
    let second = chunker.takeChunk()
    let third = chunker.takeChunk()
    let fourth = chunker.takeChunk()
    XCTAssertEqual(first?.count, 44 + 32_000)
    XCTAssertEqual(second?.count, 32_000)
    XCTAssertEqual(third?.count, 32_000)
    XCTAssertEqual(fourth?.count, 4_000)
    XCTAssertNil(chunker.takeChunk())

    var reassembled = Data()
    for chunk in [first, second, third, fourth].compactMap({ $0 }) {
      reassembled.append(chunk)
    }
    reassembled.removeFirst(44)
    XCTAssertEqual(reassembled, pcm, "every byte must reach the engine exactly once")
  }

  func testFinishingFlushesAShortFirstChunkInsteadOfDroppingIt() {
    var chunker = TranscriptEngineStreamClient.Chunker()
    chunker.append(Data(repeating: 9, count: 200))
    XCTAssertNil(chunker.takeChunk())
    let flushed = chunker.takeChunk(isFinishing: true)
    XCTAssertEqual(flushed?.count, 44 + 200)
  }
}
