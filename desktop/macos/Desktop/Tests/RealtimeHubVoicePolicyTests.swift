import XCTest

@testable import Omi_Computer

final class RealtimeHubVoicePolicyTests: XCTestCase {
  private let key = RealtimeHubVoicePolicy.geminiVoiceDefaultsKey
  private var previous: String?

  override func setUp() {
    super.setUp()
    previous = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
  }

  override func tearDown() {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  /// Both lanes pin a deep male voice so a quota failover changes the engine,
  /// not who Omi sounds like. marin (female) regressing into the OpenAI lane
  /// is exactly the drift this guards against.
  func testEveryProviderPinsItsDeepMaleVoice() {
    XCTAssertEqual(RealtimeHubVoicePolicy.voiceName(for: .gemini), "Charon")
    XCTAssertEqual(RealtimeHubVoicePolicy.voiceName(for: .openai), "cedar")
  }

  /// The live lane's voice is the user's pick — it is what they hear in Voice
  /// Live mode — while an unknown stored value can never reach the wire.
  func testAChosenGeminiVoiceIsUsedAndStaleValuesFallBackToCharon() {
    UserDefaults.standard.set("Kore", forKey: key)
    XCTAssertEqual(RealtimeHubVoicePolicy.voiceName(for: .gemini), "Kore")

    UserDefaults.standard.set("not-a-voice", forKey: key)
    XCTAssertEqual(
      RealtimeHubVoicePolicy.voiceName(for: .gemini), "Charon",
      "a hand-edited voice name must not reach the provider wire")
  }

  /// The provider a quota failover lands on must resolve to cedar — the
  /// session payload identity the post-failover connection is configured with.
  func testFailoverAlternateResolvesToCedar() {
    XCTAssertEqual(RealtimeHubVoicePolicy.voiceName(for: RealtimeHubProvider.gemini.alternate), "cedar")
  }
}

/// Through the production payload seams the session builders embed — not the
/// lookup table — so a per-call-site voice string drifting back in (the marin
/// regression) fails here even if the policy itself is untouched.
final class RealtimeHubSessionVoicePayloadTests: XCTestCase {
  private let key = RealtimeHubVoicePolicy.geminiVoiceDefaultsKey
  private var previous: String?

  override func setUp() {
    super.setUp()
    previous = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
  }

  override func tearDown() {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testOpenAISessionPayloadSpeaksCedar() {
    let output = RealtimeHubSession.openAIOutputAudioConfig()
    XCTAssertEqual(output["voice"] as? String, "cedar")
  }

  func testGeminiSetupPayloadSpeaksTheSelectedVoice() {
    UserDefaults.standard.set("Kore", forKey: key)
    let speech = RealtimeHubSession.geminiSpeechConfig()
    let voiceConfig = speech["voiceConfig"] as? [String: Any]
    let prebuilt = voiceConfig?["prebuiltVoiceConfig"] as? [String: Any]
    XCTAssertEqual(
      prebuilt?["voiceName"] as? String, "Kore",
      "the session must be built with the voice the user chose")
  }
}
