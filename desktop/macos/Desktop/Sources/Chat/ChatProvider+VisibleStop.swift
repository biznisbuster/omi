import Foundation

/// The composer's stop, on the shared timeline (INV-6).
///
/// Kept beside `ChatVisibleStopPolicy` rather than in `ChatProvider.swift` so the
/// historic provider file stays under its convergence budget; the API is the
/// same either way — the stop targets whichever owner is active, not the lane
/// that asked.
extension ChatProvider {
  /// Whether the turn visible on the shared timeline can be stopped.
  var canStopVisibleTurn: Bool {
    ChatVisibleStopPolicy.canStop(isSending: isSending, activeOwner: activeTurnOwner)
  }

  /// Stops whichever turn is running on the shared timeline, whichever surface
  /// started it. The UI stop belongs to the timeline, not to one surface's lane.
  @discardableResult
  func stopVisibleTurn(reason: ChatTurnStopReason = .userStop) -> Bool {
    guard isSending else { return false }
    guard let owner = ChatVisibleStopPolicy.stopTarget(activeOwner: activeTurnOwner) else {
      log("ChatProvider: visible-turn stop ignored — no recorded active owner")
      return false
    }
    return stopAgent(owner: owner, reason: reason)
  }
}
