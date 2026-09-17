import XCTest

@testable import Omi_Computer

/// One Live session start per rolling minute: a start re-sends the whole hub
/// context, and Google meters Live usage in tokens per minute — four starts in
/// a minute exceeded the 65k budget and every later start got a `1011 quota`
/// close that reads like a billing problem.
final class LiveSessionStartBudgetTests: XCTestCase {
  func testFirstStartIsAlwaysAllowed() {
    let budget = LiveSessionStartBudget()
    XCTAssertTrue(budget.canStart(now: Date()))
    XCTAssertEqual(budget.remainingWait(now: Date()), 0, accuracy: 0.001)
  }

  func testSecondStartInsideTheWindowIsDeferred() {
    var budget = LiveSessionStartBudget()
    let start = Date(timeIntervalSince1970: 1_000_000)
    budget.recordStart(now: start)

    let sixSecondsLater = start.addingTimeInterval(6)
    XCTAssertFalse(budget.canStart(now: sixSecondsLater))
    XCTAssertEqual(
      budget.remainingWait(now: sixSecondsLater),
      LiveSessionStartBudget.minimumInterval - 6,
      accuracy: 0.001)
  }

  func testStartIsAllowedAgainOnceTheWindowPasses() {
    var budget = LiveSessionStartBudget()
    let start = Date(timeIntervalSince1970: 1_000_000)
    budget.recordStart(now: start)

    let justAfter = start.addingTimeInterval(LiveSessionStartBudget.minimumInterval + 0.5)
    XCTAssertTrue(budget.canStart(now: justAfter))
    XCTAssertEqual(budget.remainingWait(now: justAfter), 0, accuracy: 0.001)

    budget.recordStart(now: justAfter)
    XCTAssertFalse(
      budget.canStart(now: justAfter.addingTimeInterval(1)),
      "recording a new start re-arms the window")
  }
}
