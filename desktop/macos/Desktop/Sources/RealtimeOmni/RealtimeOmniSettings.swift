import Foundation

// MARK: - Realtime Omni Provider
//
// A single realtime "omni" model handles voice I/O for the floating bar:
//   - speech-to-text (replaces Deepgram)
//   - text-to-speech (replaces OpenAI TTS)
// Reasoning + every agent/tool still runs through ChatProvider (pi-mono/Claude),
// so the omni model is only the voice shell — nothing about tools changes.
//
// The user picks a provider in Advanced settings. "Auto" defers to
// AutoModelSelector, which refreshes a best-by-quality/speed pick daily from
// Artificial Analysis (https://artificialanalysis.ai).

enum RealtimeOmniProvider: String, CaseIterable, Sendable {
  case auto
  case geminiFlashLive
  case gemini38Live
  case geminiNativeAudioDialog
  case gptRealtime2

  var displayName: String {
    switch self {
    case .auto: return "Auto"
    case .geminiFlashLive: return "Gemini 3.1 Flash Live"
    case .gemini38Live: return "Gemini 3.8 Live"
    case .geminiNativeAudioDialog: return "Gemini 2.5 Flash Native Audio Dialog"
    case .gptRealtime2: return "GPT Realtime 2"
    }
  }

  var subtitle: String {
    switch self {
    case .auto: return "Daily-picks the best model by quality & speed"
    case .geminiFlashLive: return "Google · native audio + vision, lowest cost"
    case .gemini38Live: return "Google · low-latency dialogue, background async function calling"
    case .geminiNativeAudioDialog:
      return "Google · native-audio dialogue; also the automatic fallback for newer Live models"
    case .gptRealtime2: return "OpenAI · GA speech-to-speech"
    }
  }

  /// Concrete model identifier sent to the provider. `.auto` resolves elsewhere.
  var modelID: String {
    switch self {
    case .auto: return RealtimeOmniProvider.geminiFlashLive.modelID
    case .geminiFlashLive: return "gemini-3.1-flash-live-preview"
    case .gemini38Live: return "gemini-3.8-live"
    case .geminiNativeAudioDialog: return "gemini-2.5-flash-native-audio-latest"
    case .gptRealtime2: return "gpt-realtime-2"
    }
  }

  /// Concrete providers the resolver may choose from for `.auto`. Newer
  /// user-pinnable models stay out of the automatic pick until the daily
  /// quality/speed source scores them.
  static var selectable: [RealtimeOmniProvider] { [.geminiFlashLive, .gptRealtime2] }

  /// What the Voice Model picker offers. Auto is not offered: pinning the model
  /// is the point of the setting, and a resolved pick is what Auto did anyway.
  /// `.auto` stays decodable for values persisted before the picker changed.
  static var userSelectable: [RealtimeOmniProvider] { allCases.filter { $0 != .auto } }
}

// MARK: - Settings store (mirrors AssistantSettings persistence pattern)

@MainActor
final class RealtimeOmniSettings {
  static let shared = RealtimeOmniSettings()

  private let providerKey = "realtimeOmniProvider"
  /// Master switch: when off, the floating bar keeps using the legacy
  /// Deepgram STT + OpenAI/system TTS cascade. Lets us ship behind a flag.
  private let enabledKey = "realtimeOmniEnabled"

  private init() {
    UserDefaults.standard.register(defaults: [
      // Default to Auto: AutoModelSelector picks the best provider (currently Gemini),
      // and the hub fails over to the other realtime model (GPT Realtime), then the
      // Claude cascade, if it can't connect. The user can pin a provider in
      // Advanced → Voice Model. This default also drives the realtime hub provider.
      providerKey: RealtimeOmniProvider.auto.rawValue,
      enabledKey: false,
    ])
  }

  var isEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: enabledKey)
      NotificationCenter.default.post(name: .realtimeOmniSettingsDidChange, object: nil)
    }
  }

  /// The provider as configured by the user (may be `.auto`).
  var selectedProvider: RealtimeOmniProvider {
    get {
      let raw = UserDefaults.standard.string(forKey: providerKey)
      return raw.flatMap(RealtimeOmniProvider.init(rawValue:)) ?? .auto
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: providerKey)
      NotificationCenter.default.post(name: .realtimeOmniSettingsDidChange, object: nil)
    }
  }

  /// The concrete provider to actually use right now. Resolves `.auto` via the
  /// cached daily benchmark pick (falling back to Gemini when no pick exists).
  var effectiveProvider: RealtimeOmniProvider {
    guard selectedProvider == .auto else { return selectedProvider }
    return AutoModelSelector.shared.currentPick ?? .geminiFlashLive
  }

  /// The Voice Model picker no longer offers Auto. Freeze a stored Auto
  /// selection to the pick it would have resolved to, so behavior does not
  /// silently change and the model in use becomes a visible, user-owned choice.
  static func migrateStoredAutoSelection(defaults: UserDefaults = .standard) {
    let key = "realtimeOmniProvider"
    guard defaults.string(forKey: key) == RealtimeOmniProvider.auto.rawValue else { return }
    let frozen = AutoModelSelector.shared.currentPick ?? .geminiFlashLive
    defaults.set(frozen.rawValue, forKey: key)
    log("RealtimeOmniSettings: froze stored Auto voice model to \(frozen.rawValue)")
  }
}

extension Notification.Name {
  static let realtimeOmniSettingsDidChange = Notification.Name("realtimeOmniSettingsDidChange")
}
