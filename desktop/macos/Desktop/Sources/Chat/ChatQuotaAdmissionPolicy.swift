import Foundation

/// Whether the managed-plan question quota governs a chat send.
///
/// The quota is Omi's billing boundary for inference it pays for. A
/// client-direct BYOK provider (OpenCode Go) never reaches Omi's inference
/// plane, so the managed quota must not block a chat the user pays for on
/// their own provider — the same local-BYOK exemption the floating bar's
/// `FloatingBarUsageLimiter` already honors. Server-routed BYOK keys stay
/// governed here: the backend is the authority for their exemption and its
/// verdict is expected to allow them.
enum ChatQuotaAdmissionPolicy {
  static func quotaGovernsSend(
    credentialScope: AgentExecutionProfile.CredentialScope,
    isByokActive: Bool,
    selectedProvider: BYOKProvider?
  ) -> Bool {
    guard credentialScope == .managedCloud else { return false }
    if isByokActive, selectedProvider?.isClientDirect == true { return false }
    return true
  }

  /// Presentation-side mirror of the same question for the app's managed shell.
  /// The quota banner must not warn about a boundary a client-direct lane will
  /// not cross: the user's sends already work, so "limit reached" is noise.
  static var managedQuotaGovernsThisLane: Bool {
    quotaGovernsSend(
      credentialScope: .managedCloud,
      isByokActive: APIKeyService.isByokActive,
      selectedProvider: APIKeyService.selectedBYOKLLMProvider)
  }
}
