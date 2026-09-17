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
}
