import Foundation

/// The Transcript Engine's registered ASR models, read through its public
/// `/v1/models` route with activation recorded through `/v1/models/{id}/activate`.
///
/// The engine runs exactly one active model at a time (its own documentation:
/// activation persists a selection and never restarts the runtime), so this is a
/// single chooser — the transcript and dictation lanes share whatever the engine
/// has loaded. Omi records the choice here; the engine loads it on its next
/// restart, which the user's Transcript Companion performs.
@MainActor
final class TranscriptEngineModelCatalog: ObservableObject {
  struct Entry: Equatable, Identifiable, Sendable {
    let id: String
    let active: Bool
    let available: Bool
    let loadState: String
    let contentState: String

    var stateLabel: String {
      if active { return "Active" }
      if available { return "Loaded" }
      switch contentState {
      case "installed":
        return loadState == "unavailable" ? "Installed, not loaded" : loadState
      default:
        return contentState.isEmpty ? loadState : contentState
      }
    }
  }

  enum State: Equatable {
    case idle
    case loading
    case loaded([Entry])
    /// The engine did not answer; the message is user-facing.
    case unavailable(String)
  }

  /// One registry read: the active model plus every registered entry. Shared
  /// with discovery, which uses the same answer as proof of a live engine.
  struct Registry: Equatable {
    let activeModelID: String?
    let entries: [Entry]
  }

  static let shared = TranscriptEngineModelCatalog()

  @Published private(set) var state: State = .idle
  /// Outcome of an activation request, shown under the chooser.
  @Published private(set) var activationNotice: String?
  @Published private(set) var isActivating = false

  private let baseURLOverride: URL?
  private let session: URLSession

  init(baseURL: URL? = nil, session: URLSession = .shared) {
    self.baseURLOverride = baseURL
    self.session = session
  }

  /// Resolved per call, not cached at init: discovery may adopt a moved engine
  /// address while this pane is open.
  private var baseURL: URL {
    baseURLOverride ?? TranscriptEngineClient.configured.baseURL
  }

  var activeModelID: String? {
    guard case .loaded(let entries) = state else { return nil }
    return entries.first(where: \.active)?.id
  }

  func refresh() async {
    state = .loading
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
    request.timeoutInterval = 4
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        state = .unavailable("The engine answered with status \(response.httpStatusDescription).")
        return
      }
      let entries = Self.parseModels(data)
      guard !entries.isEmpty else {
        state = .unavailable("The engine lists no speech models.")
        return
      }
      state = .loaded(entries)
    } catch {
      state = .unavailable("The engine is not answering at \(baseURL.absoluteString).")
    }
  }

  /// Records a durable selection on the engine. The engine never restarts
  /// itself, so the chooser says when the pick takes effect.
  func activate(_ modelID: String) async {
    guard !isActivating else { return }
    isActivating = true
    activationNotice = nil
    defer { isActivating = false }

    var request = URLRequest(
      url: baseURL.appendingPathComponent("v1/models/\(modelID)/activate"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        activationNotice =
          "The engine refused the selection (status \(response.httpStatusDescription))."
        return
      }
      guard let parsed = Self.parseActivation(data) else {
        activationNotice = "The engine accepted the request but its answer was unreadable."
        return
      }
      if parsed.changed == false {
        activationNotice = "\(parsed.modelID) is already the engine's selection."
      } else if parsed.restartRequired {
        activationNotice =
          "\(parsed.modelID) is selected. The engine loads it after its next restart — restart it from your Transcript Companion."
      } else {
        activationNotice = "\(parsed.modelID) is selected and loaded."
      }
      await refresh()
    } catch {
      activationNotice = "The engine is not answering — the selection was not recorded."
    }
  }

  // MARK: - Pure parsing (testable without a server)

  nonisolated static func parseModels(_ data: Data) -> [Entry] {
    parseRegistry(data)?.entries ?? []
  }

  /// The whole registry answer, or nil when the payload is not the engine's
  /// model registry at all (the proof discovery uses).
  nonisolated static func parseRegistry(_ data: Data) -> Registry? {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawModels = payload["models"] as? [[String: Any]]
    else { return nil }
    let entries = rawModels.compactMap { raw -> Entry? in
      guard let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !id.isEmpty
      else { return nil }
      return Entry(
        id: id,
        active: (raw["active"] as? Bool) == true,
        available: (raw["available"] as? Bool) == true,
        loadState: raw["load_state"] as? String ?? "",
        contentState: raw["content_state"] as? String ?? "")
    }
    guard !entries.isEmpty else { return nil }
    let activeID = entries.first(where: \.active)?.id
    return Registry(activeModelID: activeID, entries: entries)
  }

  struct ActivationResult: Equatable {
    let modelID: String
    let restartRequired: Bool
    let changed: Bool
  }

  nonisolated static func parseActivation(_ data: Data) -> ActivationResult? {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let modelID = (payload["model_id"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !modelID.isEmpty
    else { return nil }
    return ActivationResult(
      modelID: modelID,
      restartRequired: (payload["restart_required"] as? Bool) == true,
      changed: (payload["changed"] as? Bool) == true)
  }
}

extension URLResponse {
  fileprivate var httpStatusDescription: String {
    (self as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "unknown"
  }
}
