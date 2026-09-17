import XCTest

@testable import Omi_Computer

/// Which recognizer serves a cascade transcription — and that the Voice Model
/// picker no longer leaves an unresolved Auto behind.
@MainActor
final class PTTTranscriptionPreferenceTests: XCTestCase {

  // MARK: - Recognizer routing

  func testAutomaticPrefersTheLocalDecodeAndKeepsTheCloudFallback() {
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .automatic, isAppleSilicon: true, localTranscript: "zdravo"),
      .local)
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .automatic, isAppleSilicon: true, localTranscript: "   "),
      .localThenCloud,
      "an empty local decode still gets the cloud recognizer's second chance")
  }

  func testCloudPinnedNeverDecodesOnDevice() {
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .cloud, isAppleSilicon: true, localTranscript: "zdravo"),
      .cloud)
  }

  func testOnDevicePinnedReportsAFailedDecodeInsteadOfGoingToCloud() {
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .onDevice, isAppleSilicon: true, localTranscript: "zdravo"),
      .local)
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .onDevice, isAppleSilicon: true, localTranscript: ""),
      .localFailed,
      "audio must not reach a cloud recognizer the user did not choose")
  }

  func testOnDevicePinnedOnIntelFailsRatherThanFallingThrough() {
    XCTAssertEqual(
      PTTTranscriptionRoutePolicy.decide(
        preference: .onDevice, isAppleSilicon: false, localTranscript: nil),
      .localFailed)
  }

  // MARK: - Auto frozen out of the voice picker

  func testVoiceModelPickerOffersNoAuto() {
    XCTAssertFalse(
      RealtimeOmniProvider.userSelectable.contains(.auto),
      "Auto is no longer a user choice; the resolved model is")
    XCTAssertEqual(
      Set(RealtimeOmniProvider.userSelectable),
      Set([.geminiFlashLive, .gemini38Live, .geminiNativeAudioDialog, .gptRealtime2]))
  }

  func testStoredAutoIsFrozenToTheResolvedPick() {
    let defaults = UserDefaults.standard
    let providerKey = "realtimeOmniProvider"
    let pickKey = "realtimeOmniAutoPick"
    let previousProvider = defaults.string(forKey: providerKey)
    let previousPick = defaults.string(forKey: pickKey)
    defer {
      if let previousProvider {
        defaults.set(previousProvider, forKey: providerKey)
      } else {
        defaults.removeObject(forKey: providerKey)
      }
      if let previousPick {
        defaults.set(previousPick, forKey: pickKey)
      } else {
        defaults.removeObject(forKey: pickKey)
      }
    }

    defaults.set(RealtimeOmniProvider.auto.rawValue, forKey: providerKey)
    defaults.set(RealtimeOmniProvider.gptRealtime2.rawValue, forKey: pickKey)

    RealtimeOmniSettings.migrateStoredAutoSelection(defaults: defaults)

    XCTAssertEqual(
      defaults.string(forKey: providerKey), RealtimeOmniProvider.gptRealtime2.rawValue,
      "an Auto choice becomes the model it would have used, so the picker shows the truth")
  }

  func testAbsentVoiceModelDefaultIsAlsoFrozenInsteadOfLeftBlankingThePicker() {
    let defaults = UserDefaults.standard
    let providerKey = "realtimeOmniProvider"
    let pickKey = "realtimeOmniAutoPick"
    let previousProvider = defaults.string(forKey: providerKey)
    let previousPick = defaults.string(forKey: pickKey)
    defer {
      if let previousProvider {
        defaults.set(previousProvider, forKey: providerKey)
      } else {
        defaults.removeObject(forKey: providerKey)
      }
      if let previousPick {
        defaults.set(previousPick, forKey: pickKey)
      } else {
        defaults.removeObject(forKey: pickKey)
      }
    }

    defaults.removeObject(forKey: providerKey)
    defaults.set(RealtimeOmniProvider.geminiNativeAudioDialog.rawValue, forKey: pickKey)

    RealtimeOmniSettings.migrateStoredAutoSelection(defaults: defaults)

    XCTAssertEqual(
      defaults.string(forKey: providerKey), RealtimeOmniProvider.geminiNativeAudioDialog.rawValue,
      "an unset value was Auto by default, so it must freeze to a concrete, selectable model")
  }

  func testExplicitVoiceModelIsNotTouchedByTheMigration() {
    let defaults = UserDefaults.standard
    let providerKey = "realtimeOmniProvider"
    let previousProvider = defaults.string(forKey: providerKey)
    defer {
      if let previousProvider {
        defaults.set(previousProvider, forKey: providerKey)
      } else {
        defaults.removeObject(forKey: providerKey)
      }
    }

    defaults.set(RealtimeOmniProvider.gemini38Live.rawValue, forKey: providerKey)
    RealtimeOmniSettings.migrateStoredAutoSelection(defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: providerKey), RealtimeOmniProvider.gemini38Live.rawValue)
  }
}
