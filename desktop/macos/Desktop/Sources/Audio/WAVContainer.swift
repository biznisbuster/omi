import Foundation

/// One WAV container for every local audio byte the app hands to a player or a
/// recognizer, so the header arithmetic lives in exactly one place.
///
/// The engine's own client and the Gemini TTS reply both synthesize raw PCM
/// that must be wrapped before `AVAudioPlayer` or the engine's demuxer will
/// accept it; a growing live stream needs the placeholder form of the same
/// header. Those were three copies of the same byte layout.
enum WAVContainer {
  static let headerBytes = 44

  /// A complete WAV file with final sizes (16-bit PCM, little-endian).
  static func pcm16(pcm: Data, sampleRate: UInt32, channels: UInt16 = 1) -> Data {
    var out = Data(capacity: headerBytes + pcm.count)
    out.append(header(sampleRate: sampleRate, channels: channels, dataBytes: UInt32(pcm.count)))
    out.append(pcm)
    return out
  }

  /// Header for a take whose final size is unknown: both size fields carry the
  /// conventional "read until end of stream" placeholder, which is what a
  /// growing recording file holds while it is still being written.
  static func streamingHeader(sampleRate: UInt32, channels: UInt16 = 1) -> Data {
    header(sampleRate: sampleRate, channels: channels, dataBytes: UInt32.max)
  }

  private static func header(sampleRate: UInt32, channels: UInt16, dataBytes: UInt32) -> Data {
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * (bitsPerSample / 8)
    var out = Data(capacity: headerBytes)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
    out.append(Data("RIFF".utf8))
    append(dataBytes == UInt32.max ? UInt32.max : 36 + dataBytes)
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
    append(dataBytes)
    return out
  }
}
