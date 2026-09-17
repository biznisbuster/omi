import XCTest

@testable import Omi_Computer

/// The hub session's model choice: managed sessions are pinned to the model the
/// backend minted their token for, client-direct BYOK sessions follow the Voice
/// Model picker, and a provider failover never borrows the other provider's id.
final class RealtimeHubModelSelectionTests: XCTestCase {
  func testManagedSessionsKeepTheProvidersBackendModel() {
    XCTAssertEqual(
      RealtimeHubSettings.sessionModelID(
        provider: .gemini, isClientDirectBYOK: false, voiceModel: .gemini38Live),
      RealtimeHubProvider.gemini.modelID,
      "a minted token is scoped to the backend's model")
    XCTAssertEqual(
      RealtimeHubSettings.sessionModelID(
        provider: .openai, isClientDirectBYOK: false, voiceModel: .gptRealtime2),
      RealtimeHubProvider.openai.modelID)
  }

  func testClientDirectGeminiFollowsTheSelectedNewerLiveModel() {
    XCTAssertEqual(
      RealtimeHubSettings.sessionModelID(
        provider: .gemini, isClientDirectBYOK: true, voiceModel: .gemini38Live),
      "gemini-3.8-live")
  }

  func testClientDirectGeminiDefaultsToThePinnedModelForOtherSelections() {
    for voiceModel in [RealtimeOmniProvider.auto, .geminiFlashLive, .gptRealtime2] {
      XCTAssertEqual(
        RealtimeHubSettings.sessionModelID(
          provider: .gemini, isClientDirectBYOK: true, voiceModel: voiceModel),
        RealtimeHubProvider.gemini.modelID,
        "\(voiceModel) must not change the Gemini model id")
    }
  }

  func testGeminiFailoverNeverTakesTheOpenAIModelID() {
    XCTAssertEqual(
      RealtimeHubSettings.sessionModelID(
        provider: .openai, isClientDirectBYOK: true, voiceModel: .gemini38Live),
      RealtimeHubProvider.openai.modelID)
  }

  func testSameProviderModelFallbackIsTheNativeAudioDialogueModel() {
    XCTAssertEqual(
      RealtimeHubSettings.fallbackModelID(
        provider: .gemini, effectiveModelID: "gemini-3.8-live"),
      "gemini-2.5-flash-native-audio-latest")
    XCTAssertNil(
      RealtimeHubSettings.fallbackModelID(
        provider: .gemini, effectiveModelID: "gemini-2.5-flash-native-audio-latest"),
      "already on the fallback model — no second swap")
    XCTAssertNil(
      RealtimeHubSettings.fallbackModelID(
        provider: .openai, effectiveModelID: "gpt-realtime-2"),
      "OpenAI has no designated model fallback")
  }

  func testNativeAudioFallbackIsSelectableAndUsesItsLiveModelID() {
    XCTAssertTrue(RealtimeOmniProvider.allCases.contains(.geminiNativeAudioDialog))
    XCTAssertEqual(
      RealtimeOmniProvider.geminiNativeAudioDialog.modelID,
      "gemini-2.5-flash-native-audio-latest")
    XCTAssertEqual(
      RealtimeHubSettings.sessionModelID(
        provider: .gemini, isClientDirectBYOK: true, voiceModel: .geminiNativeAudioDialog),
      "gemini-2.5-flash-native-audio-latest")
  }

  func testNewerLiveModelIsSelectableWithoutJoiningAuto() {
    XCTAssertTrue(RealtimeOmniProvider.allCases.contains(.gemini38Live))
    XCTAssertEqual(RealtimeOmniProvider.gemini38Live.modelID, "gemini-3.8-live")
    XCTAssertFalse(
      RealtimeOmniProvider.selectable.contains(.gemini38Live),
      "Auto keeps resolving to the benchmark-scored models until 3.8 is scored")
  }
}
