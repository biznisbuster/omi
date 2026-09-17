import Foundation

/// Which provider a background agent spawned from chat or voice runs on.
///
/// `.omiManaged` keeps the historical inheritance: the child runs on the same
/// lane as its parent, which for this app means the managed Omi lane and needs
/// an Omi plan. A directed provider runs the agent CLI installed on this Mac,
/// so background work does not depend on managed-lane billing — and it is the
/// only way to use a local agent when the managed lane answers `402`.
enum BackgroundAgentProvider: String, CaseIterable, Sendable {
  case omiManaged = "omi"
  case hermes
  case openclaw

  static let defaultsKey = "backgroundAgentProvider"

  static var current: BackgroundAgentProvider {
    guard
      let raw = UserDefaults.standard.string(forKey: defaultsKey),
      let value = BackgroundAgentProvider(rawValue: raw)
    else { return .omiManaged }
    return value
  }

  var displayName: String {
    switch self {
    case .omiManaged: return "Omi (managed)"
    case .hermes: return "Hermes (local)"
    case .openclaw: return "OpenClaw (local)"
    }
  }

  var subtitle: String {
    switch self {
    case .omiManaged:
      return "Agents inherit the chat lane; the managed lane needs an Omi plan"
    case .hermes:
      return "Agents run through the Hermes CLI installed on this Mac"
    case .openclaw:
      return "Agents run through the OpenClaw CLI installed on this Mac"
    }
  }

  /// The runtime adapter id this choice maps to; nil for the managed lane.
  var directedProviderID: String? {
    self == .omiManaged ? nil : rawValue
  }

  /// The pill-facing provider type, for install detection.
  var directedProvider: AgentPillsManager.DirectedProvider? {
    switch self {
    case .omiManaged: return nil
    case .hermes: return .hermes
    case .openclaw: return .openclaw
    }
  }

  /// Whether the chosen provider's CLI is installed right now.
  var isInstalled: Bool {
    guard let directedProvider else { return true }
    return LocalAgentProviderDetector.isAvailable(directedProvider)
  }
}

/// Pure spawn-provider policy. The voice model is offered local providers and,
/// when the user pinned one, told to pass it. A pinned provider that is not
/// installed degrades to today's behavior (offer what is registered, no
/// instruction) instead of producing a spawn that cannot start.
enum BackgroundAgentSpawnPolicy {
  static func voiceProviderOptions(
    configured: BackgroundAgentProvider,
    registered: [String]
  ) -> (options: [String], preferred: String?) {
    let registered = Array(Set(registered.filter { !$0.isEmpty })).sorted()
    guard let pinned = configured.directedProviderID, registered.contains(pinned) else {
      return (registered, nil)
    }
    return ([pinned], pinned)
  }
}
