import Foundation

/// Client-direct BYOK providers (OpenCode Go) run the agent against the vendor
/// API from this Mac. The agent adapter selects the provider/model from these
/// environment variables instead of the default Omi gateway route.
///
/// Kept out of `AgentRuntimeProcess.swift` so the runtime convergence ratchet
/// keeps the historic coordinator file under its line budget.
extension AgentRuntimeProcess {
  static func applyClientDirectProviderEnvironment(
    to env: inout [String: String],
    byokValues: [String: String]
  ) {
    if APIKeyService.selectedBYOKLLMProvider == .opencodego,
      byokValues[byokEnvironmentKey(for: .opencodego)] != nil
    {
      env["OMI_LLM_PROVIDER"] = "opencodego"
      env["OMI_LLM_MODEL"] = openCodeGoModel()
    } else {
      env.removeValue(forKey: "OMI_LLM_PROVIDER")
      env.removeValue(forKey: "OMI_LLM_MODEL")
    }
  }

  /// Selected OpenCode Go model id, validated against the published catalog so
  /// a stale or hand-edited UserDefaults value cannot reach the provider.
  static func openCodeGoModel() -> String {
    let stored = UserDefaults.standard.string(forKey: DefaultsKey.openCodeGoModel.rawValue) ?? ""
    return OpenCodeGoCatalog.models.contains { $0.id == stored } ? stored : OpenCodeGoCatalog.defaultModelID
  }
}
