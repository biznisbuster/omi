import Foundation

/// A Chat Prompt Lab version that survives relaunches.
///
/// Evaluation runs are deliberately not stored: they carry live model output
/// and grades whose meaning belongs to the run that produced them.
struct ChatLabSavedPrompt: Codable, Equatable {
  let id: String
  var name: String
  var floatingPrefix: String
  var mainPrompt: String
}

/// Persistence for the Lab's saved prompt versions and its active selection.
///
/// The built-in "(current)" prompt is deliberately absent from the store: it is
/// rebuilt from `ChatProvider.floatingBarSystemPromptPrefix` +
/// `ChatPromptBuilder.buildDesktopChat` on every launch, so it can never go
/// stale against the code it mirrors. `activeVersionID == nil` means that
/// built-in prompt is the active one.
final class ChatLabPromptStore {
  static let versionsKey = "chatlab_prompt_versions_v1"
  static let activeIDKey = "chatlab_active_prompt_version_id"

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadVersions() -> [ChatLabSavedPrompt] {
    guard let data = defaults.data(forKey: Self.versionsKey) else { return [] }
    do {
      return try decoder.decode([ChatLabSavedPrompt].self, from: data)
    } catch {
      // Corrupt bytes must degrade to "no saved versions", never to a crash
      // loop: the Lab is a dev tool, and a bad write must stay recoverable by
      // saving again.
      log("ChatLab: failed to decode saved prompt versions: \(error)")
      return []
    }
  }

  func saveVersions(_ versions: [ChatLabSavedPrompt]) {
    do {
      defaults.set(try encoder.encode(versions), forKey: Self.versionsKey)
    } catch {
      log("ChatLab: failed to encode saved prompt versions: \(error)")
    }
  }

  /// Insert or replace one version, preserving the stored order.
  func upsert(_ prompt: ChatLabSavedPrompt) {
    var versions = loadVersions()
    if let index = versions.firstIndex(where: { $0.id == prompt.id }) {
      versions[index] = prompt
    } else {
      versions.append(prompt)
    }
    saveVersions(versions)
  }

  var activeVersionID: String? {
    get { defaults.string(forKey: Self.activeIDKey) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: Self.activeIDKey)
      } else {
        defaults.removeObject(forKey: Self.activeIDKey)
      }
    }
  }

  func reset() {
    defaults.removeObject(forKey: Self.versionsKey)
    defaults.removeObject(forKey: Self.activeIDKey)
  }
}
