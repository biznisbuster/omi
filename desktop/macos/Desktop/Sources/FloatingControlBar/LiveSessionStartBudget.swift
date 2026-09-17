import Foundation

/// Bounds how often a client-direct Live session may be (re)started.
///
/// Each Live session start carries the whole hub context to the provider — the
/// app's is ~23k tokens — and Google meters Live usage in tokens per minute.
/// Four starts inside a minute (barge-in replacement, a racing general warm, an
/// idle re-warm) measured ~92k tokens against a 65k TPM budget, and the next
/// start was answered with a `1011 quota` close that reads like a billing
/// problem while the console shows barely any requests used.
///
/// So: at most one start per rolling minute. A warm path that finds the session
/// already alive never consults this; a start that is needed but blocked lets
/// that turn run the cascade, and the next attempt after the window starts
/// normally.
struct LiveSessionStartBudget: Equatable {
  /// One start per rolling minute — the same window the provider meters.
  static let minimumInterval: TimeInterval = 60

  private(set) var lastStart: Date?

  init(lastStart: Date? = nil) {
    self.lastStart = lastStart
  }

  func canStart(now: Date) -> Bool {
    guard let lastStart else { return true }
    return now.timeIntervalSince(lastStart) >= Self.minimumInterval
  }

  /// Seconds until a start is allowed again; 0 when it is allowed now.
  func remainingWait(now: Date) -> TimeInterval {
    guard let lastStart else { return 0 }
    return max(0, Self.minimumInterval - now.timeIntervalSince(lastStart))
  }

  mutating func recordStart(now: Date) {
    lastStart = now
  }
}
