import XCTest

@testable import Omi_Computer

/// The composer's Stop belongs to the shared timeline (INV-6), not to the lane
/// that started the turn: refusing a voice-owned turn's stop is what made the
/// button read as dead.
final class ChatVisibleStopPolicyTests: XCTestCase {
  func testIdleTimelineHasNothingToStop() {
    XCTAssertTrue(ChatVisibleStopPolicy.canStop(isSending: false, activeOwner: nil))
    XCTAssertNil(ChatVisibleStopPolicy.stopTarget(activeOwner: nil))
  }

  func testEverySurfaceLaneCanBeStoppedFromTheTimeline() {
    let owners: [ChatTurnOwner] = [
      .mainChat, .floatingDefault, .floatingVoice, .taskChat("task-1"), .agentPill(UUID()),
    ]
    for owner in owners {
      XCTAssertTrue(
        ChatVisibleStopPolicy.canStop(isSending: true, activeOwner: owner),
        "\(owner) is a visible turn and must be stoppable")
      XCTAssertEqual(ChatVisibleStopPolicy.stopTarget(activeOwner: owner), owner)
    }
  }

  func testASendWithoutARecordedOwnerIsNotStoppable() {
    XCTAssertFalse(ChatVisibleStopPolicy.canStop(isSending: true, activeOwner: nil))
  }
}
