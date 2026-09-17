import Foundation

/// Which turn a stop requested from the UI may interrupt.
///
/// The chat-first shell renders one timeline over one `ChatProvider` (INV-6),
/// so the running turn the user is looking at may be owned by the voice lane
/// (`.floatingVoice`), the floating bar (`.floatingDefault`), a task chat, or an
/// agent pill. The composer used to ask for `.mainChat` explicitly, and
/// `ChatTurnOwner.canInterrupt` refuses that cross-lane request: the button read
/// as dead while a voice-owned turn kept streaming, and the log said only
/// "ignoring stop from non-owner turn".
///
/// The stop therefore belongs to the timeline, not to the lane: it targets
/// whichever owner is active. Pure so a regression back to lane-scoped stops
/// fails a test rather than a user's click.
enum ChatVisibleStopPolicy {
  /// Whether a stop may be issued right now.
  static func canStop(isSending: Bool, activeOwner: ChatTurnOwner?) -> Bool {
    !isSending || activeOwner != nil
  }

  /// The owner a visible-timeline stop must interrupt.
  static func stopTarget(activeOwner: ChatTurnOwner?) -> ChatTurnOwner? {
    activeOwner
  }
}
