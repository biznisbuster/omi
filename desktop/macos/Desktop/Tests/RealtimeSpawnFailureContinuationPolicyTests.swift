import XCTest

@testable import Omi_Computer

final class RealtimeSpawnFailureContinuationPolicyTests: XCTestCase {
  func testFirstSpawnFailureContinuesTheTurnAndSecondTerminates() {
    var policy = RealtimeSpawnFailureContinuationPolicy()
    let turn = UUID()

    XCTAssertTrue(policy.beginContinuationIfAllowed(turnID: turn, failedProvider: "codex"))
    XCTAssertFalse(
      policy.beginContinuationIfAllowed(turnID: turn, failedProvider: "hermes"),
      "the second spawn failure in the same turn must terminate it — no retry loops")
  }

  func testDistinctTurnsEachGetOneContinuation() {
    var policy = RealtimeSpawnFailureContinuationPolicy()

    XCTAssertTrue(policy.beginContinuationIfAllowed(turnID: UUID(), failedProvider: nil))
    XCTAssertTrue(policy.beginContinuationIfAllowed(turnID: UUID(), failedProvider: "openclaw"))
  }

  func testDefaultAgentFailureStillGetsOneContinuation() {
    var policy = RealtimeSpawnFailureContinuationPolicy()
    let turn = UUID()

    XCTAssertTrue(policy.beginContinuationIfAllowed(turnID: turn, failedProvider: nil))
    XCTAssertFalse(policy.beginContinuationIfAllowed(turnID: turn, failedProvider: nil))
  }

  func testTakeFailedProviderConsumesTheFallbackFromLabelOnce() {
    var policy = RealtimeSpawnFailureContinuationPolicy()
    let turn = UUID()
    _ = policy.beginContinuationIfAllowed(turnID: turn, failedProvider: "codex")

    XCTAssertEqual(policy.takeFailedProvider(turnID: turn), "codex")
    XCTAssertNil(
      policy.takeFailedProvider(turnID: turn),
      "consuming twice would double-report the same fallback")
  }

  func testNoFailedProviderIsRecordedForDefaultAgentFailures() {
    var policy = RealtimeSpawnFailureContinuationPolicy()
    let turn = UUID()
    _ = policy.beginContinuationIfAllowed(turnID: turn, failedProvider: nil)

    XCTAssertNil(policy.takeFailedProvider(turnID: turn))
  }

  // MARK: - Single-flight spawn

  func testSecondSpawnInTheSameTurnIsADuplicate() {
    var policy = RealtimeSpawnSingleFlightPolicy()
    let turn = UUID()

    XCTAssertEqual(policy.claim(turnID: turn), .start)
    XCTAssertEqual(
      policy.claim(turnID: turn), .duplicate,
      "one spoken request must not create a second child run")
  }

  func testDistinctTurnsEachGetTheirOwnSpawn() {
    var policy = RealtimeSpawnSingleFlightPolicy()

    XCTAssertEqual(policy.claim(turnID: UUID()), .start)
    XCTAssertEqual(policy.claim(turnID: UUID()), .start)
  }

  func testAnAcceptedSpawnKeepsTheTurnClaimedEvenAfterTheAttemptFinishes() {
    var policy = RealtimeSpawnSingleFlightPolicy()
    let turn = UUID()

    XCTAssertEqual(policy.claim(turnID: turn), .start)
    XCTAssertTrue(policy.hasClaim(turnID: turn))
    XCTAssertEqual(policy.claim(turnID: turn), .duplicate)
  }

  func testAFailedAttemptReleasesTheTurnForTheBoundedRetry() {
    var policy = RealtimeSpawnSingleFlightPolicy()
    let turn = UUID()

    XCTAssertEqual(policy.claim(turnID: turn), .start)
    policy.release(turnID: turn)

    XCTAssertFalse(policy.hasClaim(turnID: turn))
    XCTAssertEqual(
      policy.claim(turnID: turn), .start,
      "the one allowed retry with another agent must be able to spawn")
  }

  func testClaimBookkeepingDoesNotGrowUnbounded() {
    var policy = RealtimeSpawnSingleFlightPolicy()
    let first = UUID()
    XCTAssertEqual(policy.claim(turnID: first), .start)

    for _ in 0..<128 {
      _ = policy.claim(turnID: UUID())
    }

    XCTAssertFalse(
      policy.hasClaim(turnID: first),
      "a full reset may only forget turns that can no longer be active")
  }
}
