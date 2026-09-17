import AVFoundation
import XCTest

@testable import Omi_Computer

@MainActor
final class FloatingBarVoiceResponseSettingsTests: XCTestCase {

  /// The system voice honors the user's Voice Speed multiplier the same way the OpenAI
  /// audio path does — a hardcoded utterance rate made spoken notifications crawl at ~1×
  /// while push-to-talk answers played at the default 1.4×.
  func testSystemSpeechRateScalesWithVoiceSpeed() {
    let normal = FloatingBarVoicePlaybackService.systemSpeechRate(playbackSpeed: 1.0)
    let fast = FloatingBarVoicePlaybackService.systemSpeechRate(playbackSpeed: 1.4)
    XCTAssertEqual(normal, 0.47, accuracy: 0.001)
    XCTAssertEqual(fast, 0.658, accuracy: 0.001)
    XCTAssertGreaterThan(fast, normal)
    // Extreme multipliers stay inside AVSpeechUtterance's legal range.
    XCTAssertLessThanOrEqual(
      FloatingBarVoicePlaybackService.systemSpeechRate(playbackSpeed: 10),
      AVSpeechUtteranceMaximumSpeechRate)
    XCTAssertGreaterThanOrEqual(
      FloatingBarVoicePlaybackService.systemSpeechRate(playbackSpeed: 0),
      AVSpeechUtteranceMinimumSpeechRate)
  }

  func testDefaultVoiceIsShimmerOpenAIHumanVoice() {
    XCTAssertEqual(ShortcutSettings.defaultVoiceID, ShortcutSettings.openAIShimmerVoiceID)

    let voice = ShortcutSettings.voiceOption(for: ShortcutSettings.defaultVoiceID)
    XCTAssertEqual(voice.name, "Shimmer")
    XCTAssertEqual(voice.gender, .female)
    XCTAssertTrue(voice.isOpenAI)
    XCTAssertEqual(voice.provider, .openAI)
    XCTAssertEqual(voice.openAIVoice, "shimmer")
  }

  func testShimmerVoiceHasNeutralDisplayName() {
    let voice = ShortcutSettings.voiceOption(for: ShortcutSettings.openAIShimmerVoiceID)
    XCTAssertEqual(voice.name, "Shimmer")
    XCTAssertEqual(voice.openAIVoice, "shimmer")
  }

  func testVoicePickerOffersOpenAIVoicesAndTheLocalPiperVoice() {
    XCTAssertFalse(
      ShortcutSettings.availableVoices.contains { $0.isLocalSystem },
      "the bare system voice is a fallback, not a picker entry")

    let localVoices = ShortcutSettings.availableVoices.filter { $0.isLocalPiper }
    XCTAssertEqual(localVoices.count, 1, "exactly one on-device voice is offered")
    let local = localVoices[0]
    XCTAssertEqual(local.id, ShortcutSettings.localPiperVoiceID)
    XCTAssertEqual(local.localModelID, LocalVoiceSynthesisService.modelID)
    XCTAssertNil(local.openAIVoice, "a local voice never routes through OpenAI")

    XCTAssertEqual(
      ShortcutSettings.defaultVoiceID, ShortcutSettings.openAIShimmerVoiceID,
      "adding a local voice must not change the default")
  }

  func testLegacyProxyVoicesAreNotAvailableInPicker() {
    XCTAssertFalse(
      ShortcutSettings.availableVoices.contains {
        $0.name.localizedCaseInsensitiveContains("Sloane")
          || $0.id == "BAMYoBHLZM7lJgJAmFz0"
      }
    )
  }

  func testInvalidVoiceFallsBackToDefaultOpenAIVoice() {
    let voice = ShortcutSettings.voiceOption(for: "missing")
    XCTAssertEqual(voice.id, ShortcutSettings.defaultVoiceID)
    XCTAssertTrue(voice.isOpenAI)
    XCTAssertEqual(voice.openAIVoice, "shimmer")
  }

  func testVoiceQueryAlwaysSpeaksAndTypedQueryUsesToggle() {
    let settings = ShortcutSettings.shared
    let originalTypedSetting = settings.floatingBarTypedQuestionVoiceAnswersEnabled

    defer {
      settings.floatingBarTypedQuestionVoiceAnswersEnabled = originalTypedSetting
    }

    settings.floatingBarTypedQuestionVoiceAnswersEnabled = false
    XCTAssertTrue(settings.shouldSpeakFloatingBarResponse(forVoiceQuery: true))
    XCTAssertFalse(settings.shouldSpeakFloatingBarResponse(forVoiceQuery: false))

    settings.floatingBarTypedQuestionVoiceAnswersEnabled = true
    XCTAssertTrue(settings.shouldSpeakFloatingBarResponse(forVoiceQuery: true))
    XCTAssertTrue(settings.shouldSpeakFloatingBarResponse(forVoiceQuery: false))
  }

  /// The voice picker must offer a cloud voice that works with the key a user
  /// actually has: OpenAI voices silently fell back to the system voice without
  /// an OpenAI key, and Gemini TTS is spoken client-direct with the Gemini key.
  func testGeminiVoicesResolveToATTSProviderWithAPrebuiltVoice() throws {
    let geminiVoices = ShortcutSettings.availableVoices.filter { $0.isGeminiTTS }
    XCTAssertFalse(geminiVoices.isEmpty, "the picker must list at least one Gemini voice")
    for voice in geminiVoices {
      XCTAssertEqual(voice.provider, .geminiTTS)
      XCTAssertNotNil(voice.geminiVoice, "\(voice.id) must name its prebuilt voice")
      XCTAssertNil(voice.openAIVoice, "\(voice.id) is not an OpenAI voice")
    }

    let kore = ShortcutSettings.voiceOption(for: "gemini:kore")
    XCTAssertTrue(kore.isGeminiTTS)
    XCTAssertEqual(kore.geminiVoice, "Kore")
    XCTAssertEqual(kore.description.contains("Gemini"), true)
  }

  @MainActor
  func testGeminiAudioPartIsDecodedFromTheGenerateContentReply() throws {
    let pcm = Data(repeating: 0x2A, count: 480)
    let reply = try JSONSerialization.data(withJSONObject: [
      "candidates": [
        [
          "content": [
            "parts": [
              [
                "inlineData": [
                  "mimeType": "audio/l16; rate=24000; channels=1",
                  "data": pcm.base64EncodedString(),
                ]
              ]
            ]
          ]
        ]
      ]
    ])

    let decoded = try XCTUnwrap(FloatingBarVoicePlaybackService.geminiAudioPCM(in: reply))
    XCTAssertEqual(decoded, pcm)
    XCTAssertNil(
      FloatingBarVoicePlaybackService.geminiAudioPCM(in: Data(#"{"candidates":[]}"#.utf8)),
      "a reply with no audio part must read as no audio, not as an empty take")
  }
}
