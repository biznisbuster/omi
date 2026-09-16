import AVFoundation
import XCTest

@testable import Omi_Computer

/// Local-only integration guard for the PTT on-device decode: it synthesizes a
/// Serbian sentence with the installed Piper voice, feeds the 16 kHz PCM
/// through `PTTLanguageIdentifier` exactly as push-to-talk does, and checks the
/// script contract the language hint exists for (Latin output, never Cyrillic).
///
/// Skips when the Piper voice or the Parakeet v3 model is not cached on this
/// Mac — CI has neither, so the deterministic pieces live in
/// `TranscriptionLanguageOutputPolicyTests` and this one is the real-audio
/// check a developer runs locally.
final class PTTLocalTranscriptionIntegrationTests: XCTestCase {
  private static var parakeetV3Installed: Bool {
    let path = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3")
    return FileManager.default.fileExists(atPath: path.path)
  }

  func testSerbianSpeechDecodesToLatinScriptThroughThePTTPath() async throws {
    guard LocalVoiceSynthesisService.shared.isInstalled else {
      throw XCTSkip("local Piper voice is not installed on this Mac")
    }
    guard Self.parakeetV3Installed else {
      throw XCTSkip("Parakeet v3 model is not cached on this Mac")
    }

    let phrase = "Zdravo Omi, kako si danas?"
    let wav = try await LocalVoiceSynthesisService.shared.synthesize(text: phrase)

    let pcm16k = try Self.pcm16k(fromWAV: wav)
    XCTAssertGreaterThan(pcm16k.count, 16_000, "the fixture must contain at least half a second of audio")

    let transcript = await PTTLanguageIdentifier.shared.transcribe(pcm16k: pcm16k, language: "sr")
    let text = try XCTUnwrap(transcript, "the on-device decode produced no text")
    print("[local PTT transcript] \(text)")

    XCTAssertFalse(text.isEmpty)
    XCTAssertGreaterThanOrEqual(text.count, 5)
    XCTAssertFalse(
      text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) },
      "a Serbian turn must not come back in Cyrillic: \(text)")
  }

  /// Decode a WAV clip to 16 kHz mono little-endian s16le, the PTT buffer format.
  private static func pcm16k(fromWAV data: Data) throws -> Data {
    let inputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ptt-fixture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: inputURL) }
    try data.write(to: inputURL)

    let file = try AVAudioFile(forReading: inputURL)
    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
      file.length > 0,
      let channels = inputBuffer.floatChannelData
    else {
      throw XCTSkip("the synthesized clip could not be read")
    }
    try file.read(into: inputBuffer)

    let input = channels.pointee
    let inputFrames = Int(inputBuffer.frameLength)
    let inputRate = inputBuffer.format.sampleRate
    let outputFrames = Int(Double(inputFrames) * 16_000.0 / inputRate)
    var output = [Int16](repeating: 0, count: outputFrames)
    for index in 0..<outputFrames {
      let sourcePosition = Double(index) * inputRate / 16_000.0
      let lower = min(Int(sourcePosition), inputFrames - 1)
      let upper = min(lower + 1, inputFrames - 1)
      let fraction = Float(sourcePosition - Double(lower))
      let sample = input[lower] * (1 - fraction) + input[upper] * fraction
      output[index] = Int16(max(-1, min(1, sample)) * 32_767)
    }
    return output.withUnsafeBufferPointer { Data(buffer: $0) }
  }
}
