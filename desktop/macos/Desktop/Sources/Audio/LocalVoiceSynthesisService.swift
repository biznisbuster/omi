import CryptoKit
import Foundation
import OmiSupport

/// On-device speech synthesis for floating-bar replies, backed by Piper.
///
/// A release-pinned Piper runtime (a self-contained Python wheel) and a Serbian
/// voice are installed under the app's support directory on first use, then
/// every utterance is rendered locally: no cloud TTS, no OpenAI key, no
/// subscription. Each downloaded artifact is SHA-256-verified before it is
/// trusted, so a failed or tampered install leaves the caller's existing
/// system-voice fallback untouched.
final class LocalVoiceSynthesisService: Sendable {
  static let shared = LocalVoiceSynthesisService()

  static let modelID = "sr_RS-serbski_institut-medium"
  static let modelDisplayName = "Serbian (Piper)"

  enum SynthesisError: LocalizedError {
    case notInstalled
    case emptyText
    case timeout
    case processFailed(String)

    var errorDescription: String? {
      switch self {
      case .notInstalled: return "The local voice is not installed yet."
      case .emptyText: return "Nothing to speak."
      case .timeout: return "Local voice synthesis timed out."
      case .processFailed(let detail): return "Local voice synthesis failed: \(detail)"
      }
    }
  }

  enum InstallError: LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(String)
    case runtimeUnavailable(String)

    var errorDescription: String? {
      switch self {
      case .downloadFailed(let name): return "Could not download \(name)."
      case .checksumMismatch(let name): return "\(name) failed its checksum check."
      case .runtimeUnavailable(let detail): return "Could not prepare the local voice runtime: \(detail)"
      }
    }
  }

  private struct Artifact {
    let name: String
    let url: URL
    let sha256: String
    let byteCount: Int64
  }

  private static let wheel = Artifact(
    name: "piper runtime",
    url: URL(
      string:
        "https://github.com/OHF-Voice/piper1-gpl/releases/download/v1.8.0/piper_tts-1.8.0-cp39-abi3-macosx_11_0_arm64.whl"
    )!,
    sha256: "33e7425933e9290fe651ae127916ed1ca6104cfa3d94e9049295dd3a5c449382",
    byteCount: 34_119_781
  )

  private static let voiceArtifacts: [Artifact] = [
    Artifact(
      name: "Serbian voice",
      url: URL(
        string:
          "https://huggingface.co/rhasspy/piper-voices/resolve/main/sr/sr_RS/serbski_institut/medium/\(modelID).onnx"
      )!,
      sha256: "d7003890cf596e653f660a4fd97fd17f57f1eceb6d9727abad9cd76d2fda0d80",
      byteCount: 76_733_615
    ),
    Artifact(
      name: "Serbian voice config",
      url: URL(
        string:
          "https://huggingface.co/rhasspy/piper-voices/resolve/main/sr/sr_RS/serbski_institut/medium/\(modelID).onnx.json"
      )!,
      sha256: "39ad6531b46ac629c0bed10aa9205dd2431e2dab3808b8535808711db87c2bc0",
      byteCount: 4_999
    ),
  ]

  private let rootURL: URL

  init(rootURL: URL = LocalVoiceSynthesisService.defaultRoot) {
    self.rootURL = rootURL
  }

  static var defaultRoot: URL {
    DesktopLocalProfile.applicationSupportURL()
      .appendingPathComponent("TTS", isDirectory: true)
      .appendingPathComponent("piper", isDirectory: true)
  }

  var modelURL: URL {
    rootURL.appendingPathComponent("voices", isDirectory: true)
      .appendingPathComponent("\(Self.modelID).onnx")
  }

  var modelConfigURL: URL {
    modelURL.appendingPathExtension("json")
  }

  var piperExecutableURL: URL {
    rootURL.appendingPathComponent("venv/bin/piper")
  }

  var isInstalled: Bool {
    let fileManager = FileManager.default
    return fileManager.isExecutableFile(atPath: piperExecutableURL.path)
      && fileManager.fileExists(atPath: modelURL.path)
      && fileManager.fileExists(atPath: modelConfigURL.path)
  }

  /// Render `text` to a WAV clip entirely on this Mac.
  func synthesize(text: String) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SynthesisError.emptyText }
    guard isInstalled else { throw SynthesisError.notInstalled }
    return try await Self.run(
      executable: piperExecutableURL,
      arguments: ["-m", modelURL.path, "-f", "-"],
      stdin: Data(trimmed.utf8),
      timeout: 60
    )
  }

  /// Download and prepare the Piper runtime and Serbian voice. Idempotent;
  /// safe to call when already installed.
  func ensureInstalled(progress: (@Sendable (String) -> Void)? = nil) async throws {
    if isInstalled { return }
    let fileManager = FileManager.default
    let installDirectory = rootURL.appendingPathComponent("install", isDirectory: true)
    let voicesDirectory = rootURL.appendingPathComponent("voices", isDirectory: true)
    try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)

    progress?("Downloading local voice runtime…")
    let wheelFile = installDirectory.appendingPathComponent(Self.wheel.url.lastPathComponent)
    try await ensureArtifact(Self.wheel, destination: wheelFile)

    progress?("Downloading Serbian voice…")
    for artifact in Self.voiceArtifacts {
      let destination = voicesDirectory.appendingPathComponent(artifact.url.lastPathComponent)
      try await ensureArtifact(artifact, destination: destination)
    }

    progress?("Preparing local voice runtime…")
    try await installRuntime(wheel: wheelFile)

    guard isInstalled else {
      throw InstallError.runtimeUnavailable("piper executable is missing after install")
    }
    progress?("Local voice ready")
  }

  // MARK: - Install helpers

  private func ensureArtifact(_ artifact: Artifact, destination: URL) async throws {
    let fileManager = FileManager.default
    if fileMatches(artifact, at: destination) { return }
    let (temporary, response) = try await URLSession.shared.download(from: artifact.url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw InstallError.downloadFailed(artifact.name)
    }
    let digest = try Self.sha256Hex(contentsOf: temporary)
    guard digest == artifact.sha256 else {
      try? fileManager.removeItem(at: temporary)
      throw InstallError.checksumMismatch(artifact.name)
    }
    try? fileManager.removeItem(at: destination)
    try fileManager.moveItem(at: temporary, to: destination)
  }

  private func fileMatches(_ artifact: Artifact, at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = (attributes[.size] as? NSNumber)?.int64Value,
      size == artifact.byteCount
    else { return false }
    return (try? Self.sha256Hex(contentsOf: url)) == artifact.sha256
  }

  private func installRuntime(wheel: URL) async throws {
    let fileManager = FileManager.default
    let venv = rootURL.appendingPathComponent("venv", isDirectory: true)
    if fileManager.isExecutableFile(atPath: piperExecutableURL.path) { return }

    if let uv = Self.uvExecutableURL(fileManager: fileManager) {
      _ = try? await Self.run(
        executable: uv, arguments: ["venv", "--python", "3.12", venv.path], timeout: 300)
      guard fileManager.isExecutableFile(atPath: venv.appendingPathComponent("bin/python").path) else {
        throw InstallError.runtimeUnavailable("uv venv failed")
      }
      let result = try await Self.runWithStatus(
        executable: uv,
        arguments: ["pip", "install", "--python", venv.appendingPathComponent("bin/python").path, wheel.path],
        timeout: 900
      )
      guard result.status == 0 else {
        throw InstallError.runtimeUnavailable(result.stderr)
      }
    } else {
      let python = URL(fileURLWithPath: "/usr/bin/python3")
      let create = try await Self.runWithStatus(
        executable: python, arguments: ["-m", "venv", venv.path], timeout: 300)
      guard create.status == 0 else {
        throw InstallError.runtimeUnavailable(create.stderr)
      }
      let pip = venv.appendingPathComponent("bin/pip")
      let install = try await Self.runWithStatus(
        executable: pip, arguments: ["install", wheel.path], timeout: 900)
      guard install.status == 0 else {
        throw InstallError.runtimeUnavailable(install.stderr)
      }
    }
  }

  private static func uvExecutableURL(fileManager: FileManager) -> URL? {
    let candidates = [
      "/opt/homebrew/bin/uv",
      "/usr/local/bin/uv",
      NSHomeDirectory() + "/.local/bin/uv",
    ]
    return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
      .map { URL(fileURLWithPath: $0) }
  }

  // MARK: - Process plumbing

  private struct RunResult {
    let status: Int32
    let stdout: Data
    let stderr: String
  }

  private static func run(
    executable: URL, arguments: [String], stdin: Data? = nil, timeout: TimeInterval
  ) async throws -> Data {
    let result = try await runProcess(
      executable: executable, arguments: arguments, stdin: stdin, timeout: timeout)
    guard result.status == 0 else {
      throw SynthesisError.processFailed(describeFailure(result))
    }
    return result.stdout
  }

  private static func runWithStatus(
    executable: URL, arguments: [String], timeout: TimeInterval
  ) async throws -> RunResult {
    try await runProcess(executable: executable, arguments: arguments, stdin: nil, timeout: timeout)
  }

  private static func describeFailure(_ result: RunResult) -> String {
    let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "exit status \(result.status)" : String(text.suffix(400))
  }

  private static func runProcess(
    executable: URL, arguments: [String], stdin: Data?, timeout: TimeInterval
  ) async throws -> RunResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
          return
        }

        if let stdin {
          stdinPipe.fileHandleForWriting.write(stdin)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem {
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + timeout, execute: watchdog)

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()

        continuation.resume(
          returning: RunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: String(decoding: stderrData, as: UTF8.self)
          ))
      }
    }
  }

  // MARK: - Checksums

  static func sha256Hex(contentsOf url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
