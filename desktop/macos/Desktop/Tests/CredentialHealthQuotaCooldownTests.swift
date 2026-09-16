import XCTest

@testable import Omi_Computer

/// A rejected key stays rejected for its fingerprint; an exhausted quota only
/// pauses the key for a bounded cooldown, so the hub stops paying the provider's
/// warm timeout every turn but still retries once the quota may have reset.
@MainActor
final class CredentialHealthQuotaCooldownTests: XCTestCase {
  func testQuotaFailureSkipsTheKeyThenReleasesItAfterTheCooldown() {
    var current = Date(timeIntervalSince1970: 1_000_000)
    let health = CredentialHealthManager(now: { current })
    let fingerprint = "fp-gemini"

    XCTAssertTrue(health.canUseBYOK(provider: .gemini, fingerprint: fingerprint))

    health.recordProviderFailure(
      .providerQuotaExceeded(provider: .gemini),
      provider: .gemini,
      authMode: .byok,
      fingerprint: fingerprint,
      context: "test")

    XCTAssertFalse(
      health.canUseBYOK(provider: .gemini, fingerprint: fingerprint),
      "an exhausted quota must skip the key instead of re-paying the warm timeout")
    XCTAssertTrue(
      health.canUseBYOK(provider: .gemini, fingerprint: "another-key"),
      "a different key is unaffected")

    current = current.addingTimeInterval(CredentialHealthManager.quotaCooldown + 1)
    XCTAssertTrue(
      health.canUseBYOK(provider: .gemini, fingerprint: fingerprint),
      "the cooldown is bounded: the key is retried once it may have reset")
  }

  func testAuthFailureStaysAPermanentBanAndTransientFailuresDoNotBlock() {
    let health = CredentialHealthManager(now: Date.init)

    health.recordProviderFailure(
      .providerAuthFailed(provider: .openai, mode: .byok),
      provider: .openai,
      authMode: .byok,
      fingerprint: "fp-openai",
      context: "test")
    XCTAssertFalse(health.canUseBYOK(provider: .openai, fingerprint: "fp-openai"))

    health.recordProviderFailure(
      .providerTransient(provider: .gemini),
      provider: .gemini,
      authMode: .byok,
      fingerprint: "fp-gemini",
      context: "test")
    XCTAssertTrue(
      health.canUseBYOK(provider: .gemini, fingerprint: "fp-gemini"),
      "transient failures are not credential-level blocks")

    health.recordProviderFailure(
      .providerQuotaExceeded(provider: .gemini),
      provider: .gemini,
      authMode: .byok,
      fingerprint: nil,
      context: "test")
    XCTAssertTrue(
      health.canUseBYOK(provider: .gemini, fingerprint: "fp-gemini"),
      "a failure with no fingerprint cannot block a key")
  }
}
