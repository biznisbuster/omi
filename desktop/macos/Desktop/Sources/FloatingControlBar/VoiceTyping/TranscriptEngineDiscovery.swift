import Foundation

/// Finds the Transcript Engine that is actually running.
///
/// The engine is a local service the user starts and stops; its port can move
/// (a second worktree, a restarted runtime, an occupied 8765). Reporting "not
/// answering" while the engine is up on the next port over is the wrong answer:
/// the app should find it, say so, and remember where it is.
///
/// Discovery is bounded and honest: the configured address first, then the
/// neighbouring loopback ports, and a candidate only counts when its own
/// `/v1/models` answers like the engine (a model registry with ids). The found
/// address is persisted so every later synchronous read agrees.
enum TranscriptEngineDiscovery {
  /// Ports a local engine is expected on: the documented default, then its
  /// immediate neighbours (a dev worktree that started while 8765 was taken).
  static let candidatePorts = [8765, 8766, 8767]

  struct Resolution: Equatable {
    let url: URL
    /// True when the configured address did not answer and a neighbour did.
    let movedFromConfiguredAddress: Bool
    let activeModelID: String?
    /// The active model answers MODEL_AVAILABLE. False means the engine runs
    /// but cannot accept work until its model loads (MODEL_RESTART_REQUIRED).
    let modelAvailable: Bool
  }

  enum Outcome: Equatable {
    case resolved(Resolution)
    /// Nothing answered on any tried address.
    case notRunning(tried: [URL])
  }

  private static let lock = NSLock()
  private nonisolated(unsafe) static var cached: (outcome: Outcome, at: Date)?
  /// A running engine does not move ports every second; re-probing on every
  /// call would add latency to every voice turn. A failure is re-probed sooner
  /// than a success because the user is likely starting the engine right then.
  private static let resolvedTTL: TimeInterval = 120
  private static let notRunningTTL: TimeInterval = 15

  /// The cached resolution when it is still fresh, for callers that must not
  /// block (UI copy). `resolve()` is the authority.
  static var cachedOutcome: Outcome? {
    lock.lock()
    defer { lock.unlock() }
    return cached?.outcome
  }

  /// Probes the configured address and its neighbours. Cheap when the cached
  /// outcome is fresh; the engine's own registry is the proof.
  static func resolve(session: URLSession = .shared) async -> Outcome {
    if let cached = freshCachedOutcome() { return cached }
    let configured = TranscriptEngineClient.configured.baseURL
    var tried: [URL] = [configured]
    var candidates: [URL] = [configured]
    for port in candidatePorts {
      guard let url = URL(string: "http://127.0.0.1:\(port)") else { continue }
      if url != configured, !candidates.contains(url) {
        candidates.append(url)
        tried.append(url)
      }
    }

    // Several engine instances can be up at once (one per dev worktree). A
    // healthy one wins over one whose worker has not loaded its model: the
    // difference between "transcribes" and "refuses every request with 503".
    var fallback: (index: Int, url: URL, registry: TranscriptEngineModelCatalog.Registry)?
    for (index, url) in candidates.enumerated() {
      guard let registry = await probe(url: url, session: session) else { continue }
      let healthy = registry.entries.contains {
        $0.active && $0.availabilityCode == "MODEL_AVAILABLE"
      }
      if healthy {
        let resolution = Resolution(
          url: url,
          movedFromConfiguredAddress: index > 0,
          activeModelID: registry.activeModelID,
          modelAvailable: true)
        store(.resolved(resolution))
        return .resolved(resolution)
      }
      if fallback == nil { fallback = (index, url, registry) }
    }
    if let fallback {
      let resolution = Resolution(
        url: fallback.url,
        movedFromConfiguredAddress: fallback.index > 0,
        activeModelID: fallback.registry.activeModelID,
        modelAvailable: false)
      store(.resolved(resolution))
      return .resolved(resolution)
    }
    let outcome = Outcome.notRunning(tried: tried)
    store(outcome)
    return outcome
  }

  /// Persists a moved address so synchronous readers (`configured`) follow the
  /// same engine the async paths found.
  static func adopt(_ resolution: Resolution) {
    guard resolution.movedFromConfiguredAddress else { return }
    UserDefaults.standard.set(
      resolution.url.absoluteString, forKey: TranscriptEngineClient.baseURLDefaultsKey)
    log(
      "TranscriptEngineDiscovery: engine found at \(resolution.url.absoluteString); updated the configured address")
  }

  private static func freshCachedOutcome() -> Outcome? {
    lock.lock()
    defer { lock.unlock() }
    guard let cached else { return nil }
    let ttl: TimeInterval
    switch cached.outcome {
    case .resolved: ttl = resolvedTTL
    case .notRunning: ttl = notRunningTTL
    }
    return Date().timeIntervalSince(cached.at) < ttl ? cached.outcome : nil
  }

  /// Test seam: the cache is process-wide by design, so a test that scripts a
  /// different engine landscape must clear it first.
  static func resetCacheForTesting() {
    lock.lock()
    defer { lock.unlock() }
    cached = nil
  }

  private static func store(_ outcome: Outcome) {
    lock.lock()
    defer { lock.unlock() }
    cached = (outcome, Date())
  }

  /// One read-only proof that `url` is this engine: its registry endpoint must
  /// answer with at least one model id.
  private static func probe(url: URL, session: URLSession) async -> TranscriptEngineModelCatalog.Registry? {
    var request = URLRequest(url: url.appendingPathComponent("v1/models"))
    request.timeoutInterval = 2
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    return TranscriptEngineModelCatalog.parseRegistry(data)
  }
}
