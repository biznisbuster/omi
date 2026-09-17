import XCTest

@testable import Omi_Computer

/// Which provider a background agent is offered at spawn time, and that a
/// pinned local provider reaches the voice model's tool schema.
@MainActor
final class BackgroundAgentProviderTests: XCTestCase {

  func testDefaultIsTheManagedLane() {
    XCTAssertEqual(BackgroundAgentProvider(rawValue: "omi"), .omiManaged)
    XCTAssertNil(BackgroundAgentProvider.omiManaged.directedProviderID)
    XCTAssertEqual(BackgroundAgentProvider.hermes.directedProviderID, "hermes")
    XCTAssertEqual(BackgroundAgentProvider.openclaw.directedProviderID, "openclaw")
  }

  func testPinnedInstalledProviderIsTheOnlyOptionAndIsPreferred() {
    let decision = BackgroundAgentSpawnPolicy.voiceProviderOptions(
      configured: .hermes, registered: ["hermes", "openclaw"])
    XCTAssertEqual(decision.options, ["hermes"])
    XCTAssertEqual(decision.preferred, "hermes")
  }

  func testPinnedUninstalledProviderDegradesToTheRegisteredSet() {
    let decision = BackgroundAgentSpawnPolicy.voiceProviderOptions(
      configured: .openclaw, registered: ["hermes"])
    XCTAssertEqual(decision.options, ["hermes"])
    XCTAssertNil(
      decision.preferred,
      "an uninstalled pin must not produce a spawn the runtime cannot start")
  }

  func testManagedKeepsEveryRegisteredOptionWithNoInstruction() {
    let decision = BackgroundAgentSpawnPolicy.voiceProviderOptions(
      configured: .omiManaged, registered: ["openclaw", "hermes"])
    XCTAssertEqual(decision.options, ["hermes", "openclaw"])
    XCTAssertNil(decision.preferred)
  }

  func testRegistrationListIsNormalised() {
    let decision = BackgroundAgentSpawnPolicy.voiceProviderOptions(
      configured: .omiManaged, registered: ["hermes", "", "hermes", "openclaw"])
    XCTAssertEqual(decision.options, ["hermes", "openclaw"])
  }

  func testSpawnToolSchemaCarriesThePinnedProviderAndItsInstruction() throws {
    let tools = RealtimeHubTools.openAITools(
      availableDirectedProviders: ["hermes"], preferredProvider: "hermes")
    let spawnTool = try XCTUnwrap(tools.first { $0["name"] as? String == "spawn_agent" })
    let parameters = try XCTUnwrap(spawnTool["parameters"] as? [String: Any])
    let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
    let provider = try XCTUnwrap(properties["provider"] as? [String: Any])

    XCTAssertEqual(provider["enum"] as? [String], ["hermes"])
    let description = try XCTUnwrap(provider["description"] as? String)
    XCTAssertTrue(
      description.contains("\"hermes\""),
      "the model must be told which provider to pass, not only offered it")
  }

  func testSpawnToolSchemaWithoutAPinKeepsTheOptionalWording() throws {
    let tools = RealtimeHubTools.openAITools(
      availableDirectedProviders: ["hermes", "openclaw"], preferredProvider: nil)
    let spawnTool = try XCTUnwrap(tools.first { $0["name"] as? String == "spawn_agent" })
    let parameters = try XCTUnwrap(spawnTool["parameters"] as? [String: Any])
    let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
    let provider = try XCTUnwrap(properties["provider"] as? [String: Any])

    XCTAssertEqual(provider["enum"] as? [String], ["hermes", "openclaw"])
    XCTAssertEqual(
      provider["description"] as? String,
      "Optional local provider override only when the current user explicitly names it; omit for a regular Omi agent.")
  }
}
