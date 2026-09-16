import XCTest

@testable import Omi_Computer

final class ChatQuotaAdmissionPolicyTests: XCTestCase {
  func testManagedCloudWithoutByokIsGovernedByTheQuota() {
    XCTAssertTrue(
      ChatQuotaAdmissionPolicy.quotaGovernsSend(
        credentialScope: .managedCloud, isByokActive: false, selectedProvider: nil))
  }

  func testClientDirectByokExemptsAManagedCloudSend() {
    XCTAssertFalse(
      ChatQuotaAdmissionPolicy.quotaGovernsSend(
        credentialScope: .managedCloud, isByokActive: true, selectedProvider: .opencodego),
      "OpenCode Go chats never reach Omi's inference plane and must not be quota-blocked")
  }

  func testServerRoutedByokStaysGovernedByTheBackendVerdict() {
    XCTAssertTrue(
      ChatQuotaAdmissionPolicy.quotaGovernsSend(
        credentialScope: .managedCloud, isByokActive: true, selectedProvider: .openrouter),
      "server-routed BYOK keeps the backend as the exemption authority")
  }

  func testUnenrolledClientDirectKeyDoesNotExempt() {
    XCTAssertTrue(
      ChatQuotaAdmissionPolicy.quotaGovernsSend(
        credentialScope: .managedCloud, isByokActive: false, selectedProvider: .opencodego),
      "a selected-but-unenrolled provider is not an active BYOK environment")
  }

  func testLocalUserScopeIsNeverGovernedByTheManagedQuota() {
    XCTAssertFalse(
      ChatQuotaAdmissionPolicy.quotaGovernsSend(
        credentialScope: .localUser, isByokActive: false, selectedProvider: nil))
  }
}
