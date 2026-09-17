@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import OmiSupport
import VoiceTurnDomain

/// Boxes an `AVSpeechUtterance` (non-Sendable) so it can cross the
/// `@MainActor` task boundary from a nonisolated delegate callback.
private final class UtteranceBox: @unchecked Sendable {
  let value: AVSpeechUtterance
  init(_ value: AVSpeechUtterance) { self.value = value }
}

/// User-facing acknowledgement is selected from the admitted slow tool, never
/// from transcript text. This keeps the kernel as the only routing authority
/// while ensuring the user hears something immediately after admission.
enum RealtimeSlowToolAcknowledgementKind: String, CaseIterable, Sendable {
  case deeperThinking = "deeper-thinking"
  case publicWebSearch = "public-web-search"

  init?(toolName: String) {
    switch HubTool(rawValue: toolName) {
    case .thinkDeeper: self = .deeperThinking
    case .webSearch: self = .publicWebSearch
    default: return nil
    }
  }

  var phrases: [String] {
    switch self {
    case .deeperThinking:
      return [
        "Let me think that through.",
        "Give me a moment to think that through.",
        "Let me dig into that.",
        "I'll take a closer look.",
      ]
    case .publicWebSearch:
      return [
        "Let me look that up.",
        "I'll check the latest on that.",
        "Let me verify that.",
        "Checking the latest now.",
      ]
    }
  }

  /// Acknowledgements for the on-device Serbian voice. The English phrasing
  /// would be phonemized with Serbian rules, so the local voice gets its own
  /// lines.
  var localPhrases: [String] {
    switch self {
    case .deeperThinking:
      return [
        "Da razmislim malo.",
        "Daj mi trenutak da razmislim.",
        "Pogledaću detaljnije.",
        "Da se zamislim.",
      ]
    case .publicWebSearch:
      return [
        "Da provjerim.",
        "Tražim najnovije.",
        "Provjeravam to.",
        "Da vidim šta ima novo.",
      ]
    }
  }
}

@MainActor
final class FloatingBarVoicePlaybackService: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
  static let shared = FloatingBarVoicePlaybackService()

  // First chunk stays small so playback starts fast.
  nonisolated private static let firstChunkMinimumLength = 40
  nonisolated private static let firstChunkPreferredLength = 120
  nonisolated private static let firstChunkEmergencyLength = 200
  // Follow-up chunks are much larger so the response is stitched from fewer
  // generated audio clips. Each chunk boundary carries leading/trailing silence,
  // so fewer chunks means far less perceived pausing between sentences and
  // paragraphs of a long answer.
  nonisolated private static let followupChunkMinimumLength = 320
  nonisolated private static let followupChunkPreferredLength = 520
  nonisolated private static let followupChunkEmergencyLength = 800
  private var playbackRate: Float { ShortcutSettings.shared.voicePlaybackSpeed }

  nonisolated private static let voiceSampleText = "Hey, how is it going?"
  nonisolated static let backgroundAgentKickoffPhrases: [String] = [
    "I'll get an agent on that.",
    "Starting an agent for that now.",
    "Got it. I'm handing this to an agent.",
    "I'll have an agent work on that.",
    "I'm getting an agent started.",
    "I'll have an agent take it from here.",
    "Got it. I'm starting an agent now.",
    "I'll put an agent on that.",
    "An agent is getting started on that.",
    "I'm kicking off an agent now.",
  ]

  nonisolated private static let fillerPhrases: [String] = [
    "Let me check.",
    "One moment.",
    "Looking into it.",
    "Let me see.",
    "Checking now.",
    "Hold on.",
    "One sec.",
    "Working on it.",
  ]

  /// Filler lines for the on-device Serbian voice.
  nonisolated private static let localFillerPhrases: [String] = [
    "Da provjerim.",
    "Samo trenutak.",
    "Gledam.",
    "Sekund.",
    "Radim na tome.",
  ]

  /// Kickoff lines for the on-device Serbian voice.
  nonisolated static let localBackgroundAgentKickoffPhrases: [String] = [
    "Pokrećem agenta za to.",
    "Bavim se tim.",
    "Dajem to agentu.",
    "Agent počinje sa tim.",
    "Radim na tome.",
  ]

  private var playbackTask: Task<Void, Never>?
  private var fillerTask: Task<Void, Never>?
  private var currentMode: PlaybackMode?
  private var currentResponseID: String?
  private var interruptedResponseID: String?
  private var shouldInterruptNextResponse = false
  private var streamedText = ""
  private var bufferedText = ""
  private var synthesisQueue: [String] = []
  // Carries each chunk's source text alongside its synthesized audio so playback can fall
  // back to the system voice (speaking the text) if AVAudioPlayer can't play the audio.
  private var audioQueue: [(audio: Data, text: String)] = []
  private var isFillerSynthesizing = false
  private var isOneShotSynthesizing = false
  private var isSynthesizing = false
  private var hasStartedRealPlayback = false
  private var hasEmittedFirstChunk = false
  private var audioPlayer: AVAudioPlayer?
  private var activePlayerFallbackText = ""
  private var playbackGeneration: UInt64 = 0
  // AVSpeechSynthesizer delegates arrive asynchronously, including after a
  // stop. The current token is the sole owner of both the physical utterance
  // and its PTT lease; a callback for an older utterance must not drain a
  // replacement turn.
  private var activeSystemSpeechToken: SystemSpeechToken?
  private var activePTTLease: VoiceOutputLease?
  private var activeRealtimeSlowToolAcknowledgement: RealtimeSlowToolAcknowledgementKind?
  private var activeRealtimeSlowToolAcknowledgementTransport: String?

  /// QueryTracer for the in-flight query, handed in by the floating-bar window.
  /// Used to bracket the `tts_start` span (first real chunk → first audio out).
  var tracer: QueryTracer?
  private let speechSynthesizer = AVSpeechSynthesizer()

  private override init() {
    super.init()
    speechSynthesizer.delegate = self
  }

  var isSpeaking: Bool {
    if audioPlayer?.isPlaying == true { return true }
    if activeSystemSpeechToken != nil { return true }
    if isFillerSynthesizing { return true }
    if isOneShotSynthesizing { return true }
    if isSynthesizing { return true }
    return !audioQueue.isEmpty || !synthesisQueue.isEmpty
  }

  func playFillerIfEnabled() {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }
    if VoiceTurnCoordinator.shared.activeTurnID != nil,
      acquirePTTLeaseIfNeeded(.filler) == nil
    {
      return
    }
    setFloatingPillResponseGlow(true)

    if currentMode == nil {
      currentMode = resolvePlaybackMode()
    }
    hasStartedRealPlayback = false

    guard let mode = currentMode else { return }
    let phrase: String
    if case .localPiper = mode {
      phrase = Self.localFillerPhrases.randomElement() ?? "Samo trenutak."
    } else if case .geminiTTS = mode {
      phrase = Self.localFillerPhrases.randomElement() ?? "Samo trenutak."
    } else {
      phrase = Self.fillerPhrases.randomElement() ?? "One moment."
    }
    switch mode {
    case .systemVoice:
      enqueueSystemSpeech(phrase)
    case .geminiTTS(let voiceID):
      isFillerSynthesizing = true
      let generation = playbackGeneration
      fillerTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeGeminiSpeech(text: phrase, voiceID: voiceID)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            guard !self.hasStartedRealPlayback else {
              self.clearFloatingPillResponseGlowIfIdle()
              return
            }
            self.startPlayback(audioData, fallbackText: phrase)
            self.clearFloatingPillResponseGlowIfIdle()
          }
        } catch {
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            self.clearFloatingPillResponseGlowIfIdle()
          }
        }
      }
    case .openAI(let voiceID, let instructions):
      isFillerSynthesizing = true
      let generation = playbackGeneration
      fillerTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeOpenAISpeech(
            text: phrase, voiceID: voiceID, instructions: instructions)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            guard !self.hasStartedRealPlayback else {
              self.clearFloatingPillResponseGlowIfIdle()
              return
            }
            self.startPlayback(audioData, fallbackText: phrase)
            self.clearFloatingPillResponseGlowIfIdle()
          }
        } catch {
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            self.clearFloatingPillResponseGlowIfIdle()
          }
        }
      }
    case .localPiper:
      isFillerSynthesizing = true
      let generation = playbackGeneration
      fillerTask = Task { [weak self] in
        do {
          let audioData = try await LocalVoiceSynthesisService.shared.synthesize(text: phrase)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            guard !self.hasStartedRealPlayback else {
              self.clearFloatingPillResponseGlowIfIdle()
              return
            }
            self.startPlayback(audioData, fallbackText: phrase)
            self.clearFloatingPillResponseGlowIfIdle()
          }
        } catch {
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.isFillerSynthesizing = false
            self.fillerTask = nil
            self.clearFloatingPillResponseGlowIfIdle()
          }
        }
      }
    }
  }

  func playResponseIfEnabled(_ message: ChatMessage?) {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }
    updateStreamingResponseIfEnabled(message, isFinal: true)
  }

  func updateStreamingResponseIfEnabled(_ message: ChatMessage?, isFinal: Bool) {
    guard ShortcutSettings.shared.hasAnyFloatingBarVoiceAnswersEnabled else { return }
    guard let message else { return }

    if currentResponseID != message.id {
      resetPlaybackPipeline(clearMode: false, notifyPTTDrain: true)
      currentResponseID = message.id
      interruptedResponseID = shouldInterruptNextResponse ? message.id : nil
      shouldInterruptNextResponse = false
    }

    let text = Self.cleanedPlaybackText(from: message)
    guard !text.isEmpty, Self.shouldSpeak(text) else { return }
    if interruptedResponseID == message.id {
      streamedText = text
      bufferedText = ""
      clearFloatingPillResponseGlowIfIdle()
      return
    }
    if VoiceTurnCoordinator.shared.activeTurnID != nil,
      acquirePTTLeaseIfNeeded(.selectedVoiceFallback) == nil
    {
      return
    }
    setFloatingPillResponseGlow(true)

    if currentMode == nil {
      currentMode = resolvePlaybackMode()
    }

    guard let mode = currentMode else {
      return
    }

    if !text.hasPrefix(streamedText) {
      streamedText = ""
      bufferedText = ""
      synthesisQueue.removeAll()
      audioQueue.removeAll()
    }

    // Cancel filler and stop filler audio when first real chunk is ready
    if !hasStartedRealPlayback && text.count > 0 {
      hasStartedRealPlayback = true
      tracer?.begin("tts_start")
      fillerTask?.cancel()
      fillerTask = nil
      audioPlayer?.stop()
      audioPlayer = nil
      speechSynthesizer.stopSpeaking(at: .immediate)
    }

    if text.count > streamedText.count {
      let newText = String(text.dropFirst(streamedText.count))
      streamedText = text
      bufferedText += newText
      drainBufferedText(isFinal: isFinal, mode: mode)
    } else if isFinal {
      drainBufferedText(isFinal: true, mode: mode)
    }
  }

  private func resolvePlaybackMode() -> PlaybackMode {
    let selectedVoice = ShortcutSettings.voiceOption(for: ShortcutSettings.shared.selectedVoiceID)

    if selectedVoice.isOpenAI, let openAIVoice = selectedVoice.openAIVoice {
      return .openAI(
        voiceID: openAIVoice,
        instructions: selectedVoice.openAIInstructions ?? ""
      )
    }

    if selectedVoice.isGeminiTTS, let geminiVoice = selectedVoice.geminiVoice {
      return .geminiTTS(voiceID: geminiVoice)
    }

    if selectedVoice.isLocalPiper {
      return .localPiper
    }

    return .systemVoice(selectedVoice)
  }

  private func drainBufferedText(isFinal: Bool, mode: PlaybackMode) {
    while let boundary = Self.nextChunkBoundary(
      in: bufferedText, isFinal: isFinal, isFirstChunk: !hasEmittedFirstChunk)
    {
      let chunk = String(bufferedText[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
      bufferedText = String(bufferedText[boundary...]).trimmingCharacters(
        in: .whitespacesAndNewlines)

      guard !chunk.isEmpty, Self.shouldSpeak(chunk) else { continue }
      hasEmittedFirstChunk = true
      enqueueChunk(chunk, mode: mode)
    }
  }

  private func enqueueChunk(_ text: String, mode: PlaybackMode) {
    switch mode {
    case .systemVoice:
      enqueueSystemSpeech(text)
    case .openAI, .geminiTTS, .localPiper:
      synthesisQueue.append(text)
      startSynthesisIfNeeded(mode: mode)
    }
  }

  private func startSynthesisIfNeeded(mode: PlaybackMode) {
    guard !isSynthesizing else { return }
    guard !synthesisQueue.isEmpty else { return }

    let text = synthesisQueue.removeFirst()
    isSynthesizing = true
    let token = currentSynthesisToken()
    playbackTask?.cancel()
    playbackTask = Task { [weak self] in
      do {
        let audioData: Data
        switch mode {
        case .openAI, .geminiTTS, .localPiper:
          audioData = try await Self.synthesizeSpeech(mode: mode, text: text)
        case .systemVoice:
          return
        }
        try Task.checkCancellation()
        await MainActor.run {
          guard let self else { return }
          guard self.ownsCurrentSynthesisToken(token) else { return }
          self.isSynthesizing = false
          self.playbackTask = nil
          self.audioQueue.append((audio: audioData, text: text))
          self.startPlaybackIfNeeded()
          self.startSynthesisIfNeeded(mode: mode)
          self.clearFloatingPillResponseGlowIfIdle()
        }
      } catch is CancellationError {
        await MainActor.run {
          guard let self else { return }
          guard self.ownsCurrentSynthesisToken(token) else { return }
          self.isSynthesizing = false
          self.playbackTask = nil
          self.startSynthesisIfNeeded(mode: mode)
          self.clearFloatingPillResponseGlowIfIdle()
        }
      } catch {
        if Self.isCancellation(error) {
          await MainActor.run {
            guard let self else { return }
            guard self.ownsCurrentSynthesisToken(token) else { return }
            self.isSynthesizing = false
            self.playbackTask = nil
            self.startSynthesisIfNeeded(mode: mode)
            self.clearFloatingPillResponseGlowIfIdle()
          }
          return
        }

        await MainActor.run {
          guard let self else { return }
          guard self.ownsCurrentSynthesisToken(token) else { return }
          self.isSynthesizing = false
          self.playbackTask = nil
          guard self.canUseCloudTTSFallback(after: error, token: token, operation: "chunk") else {
            self.startSynthesisIfNeeded(mode: mode)
            self.clearFloatingPillResponseGlowIfIdle()
            return
          }
          log(
            "FloatingBarVoicePlaybackService: chunk synthesis failed, falling back: \(error.localizedDescription)"
          )
          var allowLocal = true
          if case .localPiper = mode { allowLocal = false }
          self.speakWithFallback(
            text, reason: Self.ttsFallbackReason(for: error), allowLocal: allowLocal)
          self.startSynthesisIfNeeded(mode: mode)
          self.clearFloatingPillResponseGlowIfIdle()
        }
      }
    }
  }

  func stop() {
    resetPlaybackPipeline(clearMode: true)
    currentResponseID = nil
    interruptedResponseID = nil
    shouldInterruptNextResponse = false
  }

  /// Play a short preview of the given voice so the user can hear it
  /// when switching voices in settings.
  func playVoiceSample(voiceID: String) {
    guard VoiceTurnCoordinator.shared.activeTurnID == nil else {
      log("FloatingBarVoicePlaybackService: voice sample denied while PTT owns audible output")
      return
    }
    resetPlaybackPipeline(clearMode: true)
    currentResponseID = nil
    interruptedResponseID = nil
    shouldInterruptNextResponse = false

    let phrase = Self.voiceSampleText
    let voice = ShortcutSettings.voiceOption(for: voiceID)

    if voice.isLocalSystem {
      enqueueSystemSpeech(phrase)
      return
    }

    if voice.isLocalPiper {
      let sample = ShortcutSettings.localVoiceSampleText
      let generation = playbackGeneration
      playbackTask = Task { [weak self] in
        do {
          let audioData = try await LocalVoiceSynthesisService.shared.synthesize(text: sample)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.startPlayback(audioData)
          }
        } catch is CancellationError {
          return
        } catch {
          if Self.isCancellation(error) { return }
          log(
            "FloatingBarVoicePlaybackService: local voice sample failed: \(error.localizedDescription)")
        }
      }
      return
    }

    if voice.isOpenAI, let openAIVoice = voice.openAIVoice {
      let generation = playbackGeneration
      playbackTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeOpenAISpeech(
            text: phrase, voiceID: openAIVoice, instructions: voice.openAIInstructions ?? "")
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.startPlayback(audioData)
          }
        } catch is CancellationError {
          return
        } catch {
          if Self.isCancellation(error) { return }
          log(
            "FloatingBarVoicePlaybackService: OpenAI voice sample failed: \(error.localizedDescription)"
          )
        }
      }
      return
    }

    if voice.isGeminiTTS, let geminiVoice = voice.geminiVoice {
      let generation = playbackGeneration
      let sample = ShortcutSettings.localVoiceSampleText
      playbackTask = Task { [weak self] in
        do {
          let audioData = try await Self.synthesizeGeminiSpeech(text: sample, voiceID: geminiVoice)
          try Task.checkCancellation()
          await MainActor.run {
            guard let self else { return }
            guard self.playbackGeneration == generation else { return }
            self.startPlayback(audioData)
          }
        } catch is CancellationError {
          return
        } catch {
          if Self.isCancellation(error) { return }
          log(
            "FloatingBarVoicePlaybackService: Gemini voice sample failed: \(error.localizedDescription)"
          )
        }
      }
      return
    }

    enqueueSystemSpeech(phrase)
  }

  /// Synthesize and play a single short phrase via the selected voice. Used by
  /// agent pills to speak a short acknowledgement like "On it" before the agent kicks off.
  func speakOneShot(_ text: String, lease: VoiceOutputLease? = nil) {
    let trimmed = InterjectVoiceFeedbackRouting.spokenText(from: text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let lease {
      guard VoiceTurnCoordinator.shared.outputSnapshot.activeLease == lease else {
        log("FloatingBarVoicePlaybackService: dropping one-shot with stale PTT lease")
        return
      }
      activePTTLease = lease
    } else if VoiceTurnCoordinator.shared.activeTurnID != nil,
      acquirePTTLeaseIfNeeded(.deterministicAgentAck) == nil
    {
      return
    }
    setFloatingPillResponseGlow(true)
    let mode = currentMode ?? resolvePlaybackMode()
    currentMode = mode
    switch mode {
    case .openAI, .geminiTTS, .localPiper:
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await Self.synthesizeSpeech(mode: mode, text: trimmed)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: trimmed)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            guard self.canUseCloudTTSFallback(after: error, token: token, operation: "one_shot") else { return }
            log(
              "FloatingBarVoicePlaybackService: one-shot synthesis failed; rendering the same response with the best "
                + "available voice reason=\(Self.ttsFallbackReason(for: error))")
            var allowLocal = true
            if case .localPiper = mode { allowLocal = false }
            self.speakWithFallback(
              trimmed, reason: Self.ttsFallbackReason(for: error), allowLocal: allowLocal)
          }
        }
      }
    case .systemVoice:
      enqueueSystemSpeech(trimmed)
    }
  }

  func speakBackgroundAgentKickoff() {
    if VoiceTurnCoordinator.shared.activeTurnID != nil,
      acquirePTTLeaseIfNeeded(.deterministicAgentAck) == nil
    {
      return
    }
    setFloatingPillResponseGlow(true)
    let mode = currentMode ?? resolvePlaybackMode()
    currentMode = mode
    let phrase: String
    if case .localPiper = mode {
      phrase = Self.randomLocalBackgroundAgentKickoffPhrase()
    } else if case .geminiTTS = mode {
      phrase = Self.randomLocalBackgroundAgentKickoffPhrase()
    } else {
      phrase = Self.randomBackgroundAgentKickoffPhrase()
    }

    switch mode {
    case .geminiTTS(let voiceID):
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await Self.synthesizeGeminiSpeech(text: phrase, voiceID: voiceID)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: phrase)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            guard
              self.canUseCloudTTSFallback(
                after: error, token: token, operation: "background_kickoff")
            else { return }
            self.speakWithFallback(
              phrase, reason: Self.ttsFallbackReason(for: error), allowLocal: true)
          }
        }
      }
    case .openAI(let voiceID, let instructions):
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await Self.cachedOrSynthesizedBackgroundAgentKickoffAudio(
            text: phrase, voiceID: voiceID, instructions: instructions)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: phrase)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            guard self.canUseCloudTTSFallback(after: error, token: token, operation: "background_kickoff")
            else { return }
            let cachedFallback = Self.cachedBackgroundAgentKickoffAudio(
              voiceID: voiceID, instructions: instructions)
            if let cachedFallback {
              self.recordSelectedVoiceFallback(
                to: "cached_openai_tts", reason: Self.ttsFallbackReason(for: error), outcome: .recovered)
              self.startPlayback(cachedFallback, fallbackText: phrase)
            } else {
              self.speakWithFallback(
                phrase, reason: Self.ttsFallbackReason(for: error), allowLocal: true)
            }
          }
        }
      }
    case .localPiper:
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await LocalVoiceSynthesisService.shared.synthesize(text: phrase)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: phrase)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            guard self.canUseCloudTTSFallback(after: error, token: token, operation: "background_kickoff")
            else { return }
            self.recordSelectedVoiceFallback(
              to: "system_voice_fallback", reason: Self.ttsFallbackReason(for: error), outcome: .degraded)
            self.enqueueSystemSpeech(phrase)
          }
        }
      }
    case .systemVoice:
      enqueueSystemSpeech(phrase)
    }
  }

  /// Speak the accepted slow-tool acknowledgement without waiting on realtime
  /// provider audio. A shipped clip for the session's exact provider voice is
  /// preferred; the selected batch-TTS cache and system voice remain fallbacks.
  ///
  /// The provider is required so a Gemini/Charon turn cannot accidentally play
  /// an OpenAI/cedar clip (or the unrelated selected voice-picker profile).
  func speakRealtimeSlowToolAcknowledgement(
    _ kind: RealtimeSlowToolAcknowledgementKind,
    provider: RealtimeHubProvider
  ) {
    if VoiceTurnCoordinator.shared.activeTurnID != nil,
      acquirePTTLeaseIfNeeded(.deterministicAgentAck) == nil
    {
      return
    }
    guard let phrase = kind.phrases.randomElement() else { return }
    activeRealtimeSlowToolAcknowledgement = kind
    log(
      "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement queued kind=\(kind.rawValue)"
    )
    setFloatingPillResponseGlow(true)
    let mode = currentMode ?? resolvePlaybackMode()
    currentMode = mode

    // Bundled clips are the only acknowledgement path that is both immediate
    // and independent of auth/network/cache state. The locator tolerates the
    // flattened and nested forms emitted by SwiftPM processed resources.
    if case .bundled(let data) = RealtimeVoicePhraseAudioSelection.select(
      provider: provider, kind: kind, phrase: phrase)
    {
      activeRealtimeSlowToolAcknowledgementTransport = "pre_recorded"
      startPlayback(data, fallbackText: phrase)
      return
    }

    switch mode {
    case .geminiTTS(let voiceID):
      let localPhrase = kind.localPhrases.randomElement() ?? phrase
      activeRealtimeSlowToolAcknowledgementTransport = "selected_voice"
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await Self.synthesizeGeminiSpeech(text: localPhrase, voiceID: voiceID)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: localPhrase)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.activeRealtimeSlowToolAcknowledgementTransport = "local_voice_fallback"
            self.speakWithFallback(phrase, reason: "ack_clip_unavailable", allowLocal: true)
          }
        }
      }
    case .openAI(let voiceID, let instructions):
      if let cached = Self.cachedRealtimeSlowToolAcknowledgementAudio(
        kind: kind,
        text: phrase,
        voiceID: voiceID,
        instructions: instructions)
      {
        activeRealtimeSlowToolAcknowledgementTransport = "selected_voice"
        startPlayback(cached, fallbackText: phrase)
      } else {
        activeRealtimeSlowToolAcknowledgementTransport = "local_voice_fallback"
        speakWithFallback(phrase, reason: "ack_clip_unavailable", allowLocal: true)
        Task {
          _ = try? await Self.cachedOrSynthesizedRealtimeSlowToolAcknowledgementAudio(
            kind: kind,
            text: phrase,
            voiceID: voiceID,
            instructions: instructions)
        }
      }
    case .systemVoice:
      activeRealtimeSlowToolAcknowledgementTransport = "system_voice"
      enqueueSystemSpeech(phrase)
    case .localPiper:
      let localPhrase = kind.localPhrases.randomElement() ?? phrase
      activeRealtimeSlowToolAcknowledgementTransport = "local_voice"
      let token = currentSynthesisToken()
      isOneShotSynthesizing = true
      Task { [weak self] in
        do {
          let audio = try await LocalVoiceSynthesisService.shared.synthesize(text: localPhrase)
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            self.startPlayback(audio, fallbackText: localPhrase)
          }
        } catch {
          await MainActor.run {
            guard let self, self.ownsCurrentSynthesisToken(token) else { return }
            self.isOneShotSynthesizing = false
            guard self.canUseCloudTTSFallback(after: error, token: token, operation: "realtime_ack")
            else { return }
            self.activeRealtimeSlowToolAcknowledgementTransport = "system_voice"
            self.speakWithFallback(
              localPhrase, reason: Self.ttsFallbackReason(for: error), allowLocal: false)
          }
        }
      }
    }
  }

  func prewarmBackgroundAgentKickoffPhrases() {
    // Synthesis needs an authenticated backend call; signed out it can only fail — and at launch
    // it walked the main thread into the auth fence while a restore held it (#11374).
    guard AuthService.shared.isSignedIn else { return }
    let mode = currentMode ?? resolvePlaybackMode()
    currentMode = mode
    guard case .openAI(let voiceID, let instructions) = mode else { return }

    Task {
      for phrase in Self.backgroundAgentKickoffPhrases {
        do {
          _ = try await Self.cachedOrSynthesizedBackgroundAgentKickoffAudio(
            text: phrase, voiceID: voiceID, instructions: instructions)
        } catch {
          log(
            "FloatingBarVoicePlaybackService: background agent kickoff cache prewarm failed: \(error.localizedDescription)"
          )
          return
        }
      }
    }
  }

  func prewarmRealtimeSlowToolAcknowledgementPhrases() {
    guard AuthService.shared.isSignedIn else { return }
    let mode = currentMode ?? resolvePlaybackMode()
    currentMode = mode
    guard case .openAI(let voiceID, let instructions) = mode else { return }

    Task {
      for kind in RealtimeSlowToolAcknowledgementKind.allCases {
        for phrase in kind.phrases {
          do {
            _ = try await Self.cachedOrSynthesizedRealtimeSlowToolAcknowledgementAudio(
              kind: kind,
              text: phrase,
              voiceID: voiceID,
              instructions: instructions)
          } catch {
            log(
              "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement cache prewarm failed: \(error.localizedDescription)"
            )
            return
          }
        }
      }
    }
  }

  @discardableResult
  func interruptCurrentResponse(
    leaseID expectedLeaseID: VoiceLeaseID? = nil,
    armNextResponse: Bool = false
  ) -> Bool {
    switch VoiceOutputHandoffPolicy.playbackStopAdmission(
      activeLease: activePTTLease,
      requestedLeaseID: expectedLeaseID,
      activeTurnID: VoiceTurnCoordinator.shared.activeTurnID
    ) {
    case .stale:
      log("FloatingBarVoicePlaybackService: ignored stale playback stop lease=\(expectedLeaseID?.description ?? "nil")")
      return false
    case .alreadyComplete:
      return true
    case .apply:
      break
    }
    if let currentResponseID {
      interruptedResponseID = currentResponseID
      shouldInterruptNextResponse = false
    } else {
      shouldInterruptNextResponse = armNextResponse
    }
    resetPlaybackPipeline(clearMode: false)
    clearFloatingPillResponseGlowIfIdle()
    return true
  }

  private func startPlaybackIfNeeded() {
    guard audioPlayer == nil else { return }
    guard !audioQueue.isEmpty else { return }
    let next = audioQueue.removeFirst()
    startPlayback(next.audio, fallbackText: next.text)
  }

  private func startPlayback(_ data: Data, fallbackText: String = "") {
    do {
      if UserDefaults.standard.bool(forKey: "forceTTSPlaybackFail") {
        throw NSError(domain: "TTSPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "forced playback failure"])
      }
      let player = try AVAudioPlayer(data: data)
      player.delegate = self
      player.enableRate = true
      player.rate = playbackRate
      player.prepareToPlay()
      let started =
        !UserDefaults.standard.bool(forKey: .forceTTSPlaybackStartFalse)
        && player.play()
      guard VoicePlaybackStartPolicy.accepts(started: started) else {
        throw NSError(
          domain: "TTSPlayback",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "audio player refused to start"])
      }
      audioPlayer = player
      activePlayerFallbackText = fallbackText
      if let lease = activePTTLease {
        _ = VoiceTurnCoordinator.shared.noteOutputProgress(lease)
      }
      if let acknowledgement = activeRealtimeSlowToolAcknowledgement,
        activePTTLease?.lane == .deterministicAgentAck
      {
        log(
          "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement started kind=\(acknowledgement.rawValue) transport=\(activeRealtimeSlowToolAcknowledgementTransport ?? "unknown")"
        )
      }
      tracer?.end("tts_start")
    } catch {
      // Don't drop the reply silently — speak this chunk with the system voice instead.
      log(
        "FloatingBarVoicePlaybackService: audio playback failed, falling back to system voice: \(error.localizedDescription)"
      )
      recordSelectedVoiceFallback(
        to: fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "none" : "system_voice_fallback",
        reason: "enqueue_failed",
        outcome: fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? .exhausted : .degraded)
      if activeRealtimeSlowToolAcknowledgement != nil {
        activeRealtimeSlowToolAcknowledgementTransport = "system_voice"
      }
      enqueueSystemSpeech(fallbackText)
    }
  }

  private func recordSelectedVoiceFallback(
    to: String,
    reason: String,
    outcome: DesktopFallbackOutcome
  ) {
    let from: String
    switch currentMode ?? resolvePlaybackMode() {
    case .localPiper: from = "local_piper"
    case .openAI: from = "openai_tts"
    case .geminiTTS: from = "gemini_tts"
    case .systemVoice: from = "system_voice"
    }
    DesktopDiagnosticsManager.shared.recordFallback(
      area: activePTTLease == nil ? "tts_fallback" : "ptt_cascade",
      from: from,
      to: to,
      reason: reason,
      outcome: outcome,
      extra: ["user_visible": outcome != .recovered])
  }

  private func currentSynthesisToken() -> VoiceSynthesisToken {
    VoiceSynthesisToken(generation: playbackGeneration, leaseID: activePTTLease?.id)
  }

  private func ownsCurrentSynthesisToken(_ token: VoiceSynthesisToken) -> Bool {
    VoiceSynthesisFallbackPolicy.ownsCurrentOutput(
      token: token,
      playbackGeneration: playbackGeneration,
      activeLeaseID: activePTTLease?.id)
  }

  /// A cancelled or superseded cloud request belongs to an old output owner.
  /// Never turn it into cached or system speech after that owner has gone away.
  private func canUseCloudTTSFallback(
    after error: Error,
    token: VoiceSynthesisToken,
    operation: String
  ) -> Bool {
    let allowed = VoiceSynthesisFallbackPolicy.shouldUseFallback(
      afterCancellation: Self.isCancellation(error),
      token: token,
      playbackGeneration: playbackGeneration,
      activeLeaseID: activePTTLease?.id)
    guard !allowed else { return true }
    log("FloatingBarVoicePlaybackService: dropping \(operation) fallback for cancelled or stale output")
    return false
  }

  /// The delegate callback is not a global "speech stopped" signal: AVFoundation
  /// may deliver it after `stopSpeaking` or after another utterance began.
  private func completeSystemSpeechIfCurrent(_ utterance: AVSpeechUtterance) -> Bool {
    guard
      SystemSpeechCallbackPolicy.matchesCurrentUtterance(
        callbackUtterance: utterance,
        currentToken: activeSystemSpeechToken,
        playbackGeneration: playbackGeneration)
    else { return false }
    guard
      SystemSpeechCallbackPolicy.accepts(
        callbackUtterance: utterance,
        currentToken: activeSystemSpeechToken,
        playbackGeneration: playbackGeneration,
        activeLeaseID: activePTTLease?.id)
    else {
      // This exact utterance finished after its lease was superseded. Clear
      // only its physical marker; never let it drain the replacement lease.
      activeSystemSpeechToken = nil
      return false
    }
    activeSystemSpeechToken = nil
    return true
  }

  /// The system voice must honor the same Voice Speed setting the OpenAI audio path
  /// applies via `AVAudioPlayer.rate`. It used to hardcode `0.47`, so with the default
  /// speed of 1.4× every system-voice utterance (spoken notifications, TTS fallbacks)
  /// crawled at ~1× while push-to-talk answers played at 1.4× — the same reply sounded
  /// like two different products. `AVSpeechUtterance.rate` is a 0…1 scale where ~0.47 is
  /// conversational pace, so the user's multiplier scales that base, clamped to the
  /// framework's legal range.
  nonisolated static func systemSpeechRate(playbackSpeed: Float) -> Float {
    let base: Float = 0.47
    return min(
      AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, base * playbackSpeed))
  }

  private func enqueueSystemSpeech(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      if let lease = activePTTLease {
        activePTTLease = nil
        VoiceTurnCoordinator.shared.publish(
          .playbackFailedScoped(
            turnID: lease.turnID,
            identity: lease.identity,
            leaseID: lease.id,
            message: "no fallback speech available"))
      }
      clearFloatingPillResponseGlowIfIdle()
      return
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = Self.systemSpeechRate(playbackSpeed: playbackRate)
    utterance.pitchMultiplier = 1.02
    utterance.volume = 1.0
    utterance.voice = preferredSystemVoice()
    activeSystemSpeechToken = SystemSpeechToken(
      generation: playbackGeneration,
      leaseID: activePTTLease?.id,
      utterance: utterance)
    speechSynthesizer.speak(utterance)
    tracer?.end("tts_start")
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.audioPlayer === player else { return }
      if let acknowledgement = self.activeRealtimeSlowToolAcknowledgement {
        log(
          "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement finished kind=\(acknowledgement.rawValue) transport=\(self.activeRealtimeSlowToolAcknowledgementTransport ?? "unknown") success=\(flag)"
        )
        self.activeRealtimeSlowToolAcknowledgement = nil
        self.activeRealtimeSlowToolAcknowledgementTransport = nil
      }
      let fallbackText = self.activePlayerFallbackText
      self.audioPlayer = nil
      self.activePlayerFallbackText = ""
      if !flag, !fallbackText.isEmpty {
        log("FloatingBarVoicePlaybackService: player ended unsuccessfully; using system voice")
        self.recordSelectedVoiceFallback(
          to: "system_voice_fallback", reason: "enqueue_failed", outcome: .degraded)
        self.enqueueSystemSpeech(fallbackText)
        return
      }
      self.startPlaybackIfNeeded()
      self.clearFloatingPillResponseGlowIfIdle()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didStart utterance: AVSpeechUtterance
  ) {
    let utteranceBox = UtteranceBox(utterance)
    Task { @MainActor [weak self, utteranceBox] in
      guard let self,
        SystemSpeechCallbackPolicy.matchesCurrentUtterance(
          callbackUtterance: utteranceBox.value,
          currentToken: self.activeSystemSpeechToken,
          playbackGeneration: self.playbackGeneration),
        let acknowledgement = self.activeRealtimeSlowToolAcknowledgement
      else { return }
      log(
        "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement started kind=\(acknowledgement.rawValue) transport=\(self.activeRealtimeSlowToolAcknowledgementTransport ?? "system_voice")"
      )
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let utteranceBox = UtteranceBox(utterance)
    Task { @MainActor [weak self, utteranceBox] in
      guard let self else { return }
      guard self.completeSystemSpeechIfCurrent(utteranceBox.value) else { return }
      if let acknowledgement = self.activeRealtimeSlowToolAcknowledgement {
        log(
          "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement finished kind=\(acknowledgement.rawValue) transport=\(self.activeRealtimeSlowToolAcknowledgementTransport ?? "system_voice") success=true"
        )
        self.activeRealtimeSlowToolAcknowledgement = nil
        self.activeRealtimeSlowToolAcknowledgementTransport = nil
      }
      self.startPlaybackIfNeeded()
      self.clearFloatingPillResponseGlowIfIdle()
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let utteranceBox = UtteranceBox(utterance)
    Task { @MainActor [weak self, utteranceBox] in
      guard let self else { return }
      guard self.completeSystemSpeechIfCurrent(utteranceBox.value) else { return }
      if let acknowledgement = self.activeRealtimeSlowToolAcknowledgement {
        log(
          "FloatingBarVoicePlaybackService: realtime slow-tool acknowledgement finished kind=\(acknowledgement.rawValue) transport=\(self.activeRealtimeSlowToolAcknowledgementTransport ?? "system_voice") success=false"
        )
        self.activeRealtimeSlowToolAcknowledgement = nil
        self.activeRealtimeSlowToolAcknowledgementTransport = nil
      }
      self.clearFloatingPillResponseGlowIfIdle()
    }
  }

  private func resetPlaybackPipeline(clearMode: Bool, notifyPTTDrain: Bool = false) {
    let leaseToRelease = activePTTLease
    playbackGeneration &+= 1
    playbackTask?.cancel()
    playbackTask = nil
    fillerTask?.cancel()
    fillerTask = nil
    isFillerSynthesizing = false
    isOneShotSynthesizing = false
    if clearMode {
      currentMode = nil
      // Drop the tracer only on full teardown. interruptCurrentResponse uses
      // clearMode:false and runs just before the next query assigns a fresh
      // tracer, so clearing there would discard the live one.
      tracer = nil
    }
    streamedText = ""
    bufferedText = ""
    synthesisQueue.removeAll()
    audioQueue.removeAll()
    isSynthesizing = false
    hasStartedRealPlayback = false
    hasEmittedFirstChunk = false
    audioPlayer?.stop()
    audioPlayer = nil
    activePlayerFallbackText = ""
    speechSynthesizer.stopSpeaking(at: .immediate)
    activeSystemSpeechToken = nil
    activeRealtimeSlowToolAcknowledgement = nil
    activeRealtimeSlowToolAcknowledgementTransport = nil
    activePTTLease = nil
    if let lease = leaseToRelease, notifyPTTDrain {
      _ = VoiceTurnCoordinator.shared.releaseOutput(lease)
    }
    setFloatingPillResponseGlow(false)
  }

  private func setFloatingPillResponseGlow(_ active: Bool) {
    if let lease = activePTTLease {
      VoiceTurnCoordinator.shared.publish(
        .responseActiveChanged(turnID: lease.turnID, active: active))
      return
    }
    VoiceTurnCoordinator.shared.setUnscopedResponseActive(active)
  }

  private func clearFloatingPillResponseGlowIfIdle() {
    if !isSpeaking {
      finishActivePTTLeaseIfIdle()
      setFloatingPillResponseGlow(false)
    }
  }

  private func acquirePTTLeaseIfNeeded(_ lane: VoiceOutputLane) -> VoiceOutputLease? {
    if let turnID = VoiceTurnCoordinator.shared.activeTurnID {
      _ = preemptFillerIfNeeded(for: lane, turnID: turnID)
    }
    if let activePTTLease {
      return activePTTLease.lane == lane ? activePTTLease : nil
    }
    guard let turnID = VoiceTurnCoordinator.shared.activeTurnID else { return nil }
    switch VoiceTurnCoordinator.shared.acquireOutput(lane, turnID: turnID) {
    case .acquired(let lease):
      activePTTLease = lease
      guard let providerIdentity = VoiceTurnCoordinator.shared.activeTurn?.providerEffectIdentity else {
        log("FloatingBarVoicePlaybackService: dropping PTT output without provider effect identity")
        activePTTLease = nil
        return nil
      }
      VoiceTurnCoordinator.shared.publish(
        .providerResponseStartedScoped(
          turnID: turnID,
          identity: providerIdentity,
          sessionID: nil,
          responseID: nil))
      return lease
    case .denied(let active):
      log(
        "FloatingBarVoicePlaybackService: dropping \(lane.rawValue) PTT output; "
          + "active_lane=\(active.lane.rawValue)")
      return nil
    case .staleTurn:
      log("FloatingBarVoicePlaybackService: dropping stale \(lane.rawValue) PTT output")
      return nil
    }
  }

  /// Real output always wins over a provisional filler phrase. Stop the audio
  /// engine before releasing its lease so the incoming lane cannot overlap it.
  @discardableResult
  func preemptFillerIfNeeded(for incomingLane: VoiceOutputLane, turnID: VoiceTurnID) -> Bool {
    guard let lease = activePTTLease,
      VoiceOutputHandoffPolicy.fillerCanYield(
        active: lease,
        to: incomingLane,
        turnID: turnID)
    else { return false }

    playbackGeneration &+= 1
    fillerTask?.cancel()
    fillerTask = nil
    isFillerSynthesizing = false
    audioPlayer?.stop()
    audioPlayer = nil
    speechSynthesizer.stopSpeaking(at: .immediate)
    activeSystemSpeechToken = nil
    activePTTLease = nil
    return VoiceTurnCoordinator.shared.releaseOutput(lease)
  }

  private func finishActivePTTLeaseIfIdle() {
    guard !isSpeaking, let lease = activePTTLease else { return }
    activePTTLease = nil
    _ = VoiceTurnCoordinator.shared.releaseOutput(lease)
  }

  private func preferredSystemVoice() -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let preferredNames = ["Ava", "Allison", "Samantha", "Karen", "Moira"]
    for name in preferredNames {
      if let voice = voices.first(where: {
        $0.name.localizedCaseInsensitiveContains(name)
      }) {
        return voice
      }
    }
    return AVSpeechSynthesisVoice(language: "en-US")
  }

  /// Synthesize speech through the desktop backend's OpenAI TTS proxy.
  /// APIClient attaches a user BYOK key when one is configured; otherwise the
  /// backend uses its server-side key.
  /// One synthesis entry point for every non-system playback mode: cloud
  /// OpenAI TTS or the on-device Piper voice selected in Settings.
  /// The best voice that can actually speak right now: the on-device Piper
  /// voice when it is installed, and the OS voice only as the last resort.
  ///
  /// Without this, a selected cloud voice whose synthesis is refused (Omi TTS is
  /// paywalled on a Free/client-direct account) degraded straight to the OS
  /// voice — which reads Serbian text in an English voice, or says nothing at
  /// all. The local voice is free, offline and honours the selected language.
  private func speakWithFallback(_ text: String, reason: String, allowLocal: Bool) {
    guard allowLocal, LocalVoiceSynthesisService.shared.isInstalled else {
      recordSelectedVoiceFallback(to: "system_voice_fallback", reason: reason, outcome: .degraded)
      enqueueSystemSpeech(text)
      return
    }
    let token = currentSynthesisToken()
    Task { [weak self] in
      do {
        let audio = try await LocalVoiceSynthesisService.shared.synthesize(text: text)
        await MainActor.run {
          guard let self, self.ownsCurrentSynthesisToken(token) else { return }
          self.recordSelectedVoiceFallback(to: "local_voice_fallback", reason: reason, outcome: .recovered)
          self.startPlayback(audio, fallbackText: text)
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.recordSelectedVoiceFallback(to: "system_voice_fallback", reason: reason, outcome: .degraded)
          self.enqueueSystemSpeech(text)
        }
      }
    }
  }

  private nonisolated static func synthesizeSpeech(mode: PlaybackMode, text: String) async throws -> Data {
    switch mode {
    case .openAI(let voiceID, let instructions):
      return try await synthesizeOpenAISpeech(
        text: text, voiceID: voiceID, instructions: instructions)
    case .geminiTTS(let voiceID):
      return try await synthesizeGeminiSpeech(text: text, voiceID: voiceID)
    case .localPiper:
      return try await LocalVoiceSynthesisService.shared.synthesize(text: text)
    case .systemVoice:
      throw CancellationError()
    }
  }

  /// Gemini's dedicated TTS model, spoken client-direct with the user's own
  /// Gemini key. Returns a WAV container (24 kHz mono s16le) so the existing
  /// playback path can feed it straight to `AVAudioPlayer`.
  ///
  /// This is the cloud voice that works without an OpenAI key, which is the
  /// whole point: the voice picker used to offer OpenAI voices that silently
  /// fell back to the system voice when no OpenAI key existed.
  nonisolated static let geminiTTSModels = [
    "gemini-3.1-flash-tts-preview",
    "gemini-2.5-flash-preview-tts",
  ]

  private nonisolated static func synthesizeGeminiSpeech(
    text: String,
    voiceID: String
  ) async throws -> Data {
    guard
      let key = APIKeyService.byokKey(.gemini)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else {
      throw CredentialHealthError.providerAuth(
        provider: .gemini,
        mode: .byok,
        message: "No Gemini key on this Mac. Add one in Developer API Keys."
      )
    }

    let body: [String: Any] = [
      "contents": [["parts": [["text": text]]]],
      "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceID]]],
      ],
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body)

    var lastError: Error = NSError(
      domain: "omi.gemini.tts",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Gemini TTS produced no audio."])
    for model in geminiTTSModels {
      var request = URLRequest(
        url: URL(
          string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)"
        )!)
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = bodyData
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
          lastError = CredentialHealthError.providerAuth(
            provider: .gemini,
            mode: .byok,
            message: "Gemini TTS rejected the request.")
          continue
        }
        if let pcm = geminiAudioPCM(in: data), !pcm.isEmpty {
          return WAVContainer.pcm16(pcm: pcm, sampleRate: 24_000)
        }
        lastError = NSError(
          domain: "omi.gemini.tts",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Gemini TTS produced no audio."])
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  /// The synthesized PCM inside a `generateContent` reply, or nil when the
  /// candidate carried no audio part.
  nonisolated static func geminiAudioPCM(in data: Data) -> Data? {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = payload["candidates"] as? [[String: Any]],
      let parts = candidates.first?["content"] as? [String: Any],
      let partList = parts["parts"] as? [[String: Any]]
    else { return nil }
    for part in partList {
      guard let inline = part["inlineData"] as? [String: Any],
        let encoded = inline["data"] as? String
      else { continue }
      return Data(base64Encoded: encoded)
    }
    return nil
  }

  private nonisolated static func synthesizeOpenAISpeech(
    text: String,
    voiceID: String,
    instructions: String
  ) async throws -> Data {
    let byokKey = APIKeyService.selectedBYOKLLMProvider == .openai ? APIKeyService.byokKey(.openai) : nil
    let fingerprint = byokKey.map(APIKeyService.byokFingerprint)
    if let fingerprint {
      let canUseKey = await MainActor.run {
        CredentialHealthManager.shared.canUseBYOK(provider: .openai, fingerprint: fingerprint)
      }
      guard canUseKey else {
        throw CredentialHealthError.providerAuth(
          provider: .openai,
          mode: .byok,
          message: "Your OpenAI key was rejected. Update it in Settings."
        )
      }
    }

    do {
      return try await APIClient.shared.synthesizeSpeech(
        request: APIClient.TtsSynthesizeRequest(
          text: text,
          voiceId: voiceID,
          instructions: instructions.isEmpty ? nil : instructions
        )
      )
    } catch let error as CredentialHealthError {
      await MainActor.run {
        if case .providerAuth(let provider, let mode, _) = error {
          CredentialHealthManager.shared.recordProviderFailure(
            error.failureClass,
            provider: provider,
            authMode: mode,
            fingerprint: fingerprint,
            context: "openai_tts"
          )
        } else {
          CredentialHealthManager.shared.record(error, context: "openai_tts")
        }
      }
      throw error
    }
  }

  private nonisolated static func ttsFallbackReason(for error: Error) -> String {
    if let apiError = error as? APIError,
      case .httpError(let statusCode, _) = apiError,
      statusCode == 429
    {
      return "quota"
    }
    guard let credentialError = error as? CredentialHealthError else { return "provider_5xx" }
    switch credentialError.failureClass {
    case .providerAuthFailed:
      return "auth"
    case .providerQuotaExceeded:
      return "provider_429"
    default:
      return "provider_5xx"
    }
  }

  nonisolated static func cleanedPlaybackText(from message: ChatMessage?) -> String {
    guard let message else { return "" }

    let baseText: String
    if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      baseText = message.text
    } else {
      baseText = message.contentBlocks.compactMap { block in
        switch block {
        case .text(_, let text):
          return text
        case .discoveryCard(_, let title, let summary, _):
          return "\(title). \(summary)"
        case .agentSpawn(_, _, _, _, let title, let objective, _):
          return "\(title). \(objective)"
        case .agentCompletion(_, _, _, _, let title, _, let output, _):
          return "\(title). \(output)"
        case .questionCard, .taskCard, .goalLink, .captureLink, .conversationLink, .memoryLink,
          .citation:
          return nil
        // The chip is a control, not narration. Speaking it would turn a
        // tappable next step into an answer that ends by asking out loud.
        case .followUp:
          return nil
        // Nor is the review card: reading three stored memories aloud would narrate the card's
        // controls instead of the answer.
        case .memoryReviewCard:
          return nil
        case .toolCall, .thinking:
          return nil
        }
      }.joined(separator: "\n\n")
    }

    let spoken = InterjectVoiceFeedbackRouting.spokenText(from: baseText)
    let collapsedWhitespace = spoken.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func shouldSpeak(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    if FloatingBarAnswerFailureCopy.isFailureCopy(lowercased) {
      return false
    }
    if lowercased.hasPrefix("⚠️") || lowercased.hasPrefix("warning:") {
      return false
    }
    return true
  }

  private nonisolated static func randomBackgroundAgentKickoffPhrase() -> String {
    backgroundAgentKickoffPhrases.randomElement() ?? "Starting an agent for that now."
  }

  private nonisolated static func randomLocalBackgroundAgentKickoffPhrase() -> String {
    localBackgroundAgentKickoffPhrases.randomElement() ?? "Bavim se tim."
  }

  private nonisolated static func cachedOrSynthesizedBackgroundAgentKickoffAudio(
    text: String,
    voiceID: String,
    instructions: String
  ) async throws -> Data {
    let cacheURL = backgroundAgentKickoffCacheURL(
      text: text, voiceID: voiceID, instructions: instructions)
    if let cached = try? Data(contentsOf: cacheURL), !cached.isEmpty {
      return cached
    }

    let audio = try await synthesizeOpenAISpeech(text: text, voiceID: voiceID, instructions: instructions)
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try audio.write(to: cacheURL, options: [.atomic])
    return audio
  }

  private nonisolated static func cachedBackgroundAgentKickoffAudio(
    voiceID: String,
    instructions: String
  ) -> Data? {
    let cached = backgroundAgentKickoffPhrases.shuffled().lazy.compactMap { phrase -> Data? in
      let url = backgroundAgentKickoffCacheURL(
        text: phrase, voiceID: voiceID, instructions: instructions)
      guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
      return data
    }
    return cached.first
  }

  private nonisolated static func backgroundAgentKickoffCacheURL(
    text: String,
    voiceID: String,
    instructions: String
  ) -> URL {
    let fingerprint = SHA256.hash(data: Data("\(voiceID)\n\(instructions)\n\(text)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return DesktopLocalProfile.applicationSupportURL()
      .appendingPathComponent("VoicePhraseCache", isDirectory: true)
      .appendingPathComponent("background-agent-kickoff-v1", isDirectory: true)
      .appendingPathComponent("\(fingerprint).mp3")
  }

  private nonisolated static func cachedOrSynthesizedRealtimeSlowToolAcknowledgementAudio(
    kind: RealtimeSlowToolAcknowledgementKind,
    text: String,
    voiceID: String,
    instructions: String
  ) async throws -> Data {
    let cacheURL = realtimeSlowToolAcknowledgementCacheURL(
      kind: kind,
      text: text,
      voiceID: voiceID,
      instructions: instructions)
    if let cached = try? Data(contentsOf: cacheURL), !cached.isEmpty {
      return cached
    }

    let audio = try await synthesizeOpenAISpeech(
      text: text,
      voiceID: voiceID,
      instructions: instructions)
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try audio.write(to: cacheURL, options: [.atomic])
    return audio
  }

  private nonisolated static func cachedRealtimeSlowToolAcknowledgementAudio(
    kind: RealtimeSlowToolAcknowledgementKind,
    text: String,
    voiceID: String,
    instructions: String
  ) -> Data? {
    let url = realtimeSlowToolAcknowledgementCacheURL(
      kind: kind,
      text: text,
      voiceID: voiceID,
      instructions: instructions)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    return data
  }

  private nonisolated static func realtimeSlowToolAcknowledgementCacheURL(
    kind: RealtimeSlowToolAcknowledgementKind,
    text: String,
    voiceID: String,
    instructions: String
  ) -> URL {
    let fingerprint = SHA256.hash(
      data: Data("\(kind.rawValue)\n\(voiceID)\n\(instructions)\n\(text)".utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
    return DesktopLocalProfile.applicationSupportURL()
      .appendingPathComponent("VoicePhraseCache", isDirectory: true)
      .appendingPathComponent("realtime-slow-tool-v1", isDirectory: true)
      .appendingPathComponent("\(fingerprint).mp3")
  }

  private nonisolated static func nextChunkBoundary(
    in text: String, isFinal: Bool, isFirstChunk: Bool
  ) -> String.Index? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if isFinal {
      return text.endIndex
    }

    let minLength = isFirstChunk ? firstChunkMinimumLength : followupChunkMinimumLength
    let preferredLength =
      isFirstChunk ? firstChunkPreferredLength : followupChunkPreferredLength
    let emergencyLength =
      isFirstChunk ? firstChunkEmergencyLength : followupChunkEmergencyLength

    guard text.count >= minLength else { return nil }

    let preferredLimit = text.index(
      text.startIndex, offsetBy: min(text.count, preferredLength))
    let preferredSlice = text[..<preferredLimit]

    if let punctuationIndex = preferredSlice.lastIndex(where: { ".!?\n".contains($0) }) {
      return text.index(after: punctuationIndex)
    }

    guard text.count >= preferredLength else { return nil }

    let emergencyLimit = text.index(
      text.startIndex, offsetBy: min(text.count, emergencyLength))
    let emergencySlice = text[..<emergencyLimit]

    if let punctuationIndex = emergencySlice.lastIndex(where: { ".!?\n".contains($0) }) {
      return text.index(after: punctuationIndex)
    }

    guard text.count >= emergencyLength else { return nil }

    if let clauseIndex = emergencySlice.lastIndex(where: { ",;:\n".contains($0) }) {
      return text.index(after: clauseIndex)
    }

    if let whitespaceIndex = emergencySlice.lastIndex(where: \.isWhitespace) {
      return whitespaceIndex
    }

    return emergencyLimit
  }

  private nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
      return true
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return true
    }

    if let urlError = error as? URLError, urlError.code == .cancelled {
      return true
    }

    return false
  }
}

enum VoicePlaybackStartPolicy {
  static func accepts(started: Bool) -> Bool { started }
}

/// Identity of one AVSpeech utterance. Generation invalidates all callbacks from
/// an interrupted playback pipeline; lease identity prevents an old utterance
/// from changing the response state for a newer PTT turn.
struct SystemSpeechToken: Equatable {
  let generation: UInt64
  let leaseID: VoiceLeaseID?
  let utteranceIdentity: ObjectIdentifier

  init(generation: UInt64, leaseID: VoiceLeaseID?, utterance: AnyObject) {
    self.generation = generation
    self.leaseID = leaseID
    utteranceIdentity = ObjectIdentifier(utterance)
  }
}

enum SystemSpeechCallbackPolicy {
  static func matchesCurrentUtterance(
    callbackUtterance: AnyObject,
    currentToken: SystemSpeechToken?,
    playbackGeneration: UInt64
  ) -> Bool {
    guard let currentToken else { return false }
    return currentToken.generation == playbackGeneration
      && currentToken.utteranceIdentity == ObjectIdentifier(callbackUtterance)
  }

  static func accepts(
    callbackUtterance: AnyObject,
    currentToken: SystemSpeechToken?,
    playbackGeneration: UInt64,
    activeLeaseID: VoiceLeaseID?
  ) -> Bool {
    guard
      matchesCurrentUtterance(
        callbackUtterance: callbackUtterance,
        currentToken: currentToken,
        playbackGeneration: playbackGeneration)
    else { return false }
    return currentToken?.leaseID == activeLeaseID
  }
}

/// A cloud synthesis must still own the same generation and PTT lease at its
/// completion boundary. This keeps every cloud-TTS fallback on one auditable
/// policy instead of letting individual completion handlers revive old speech.
struct VoiceSynthesisToken: Equatable {
  let generation: UInt64
  let leaseID: VoiceLeaseID?
}

enum VoiceSynthesisFallbackPolicy {
  static func ownsCurrentOutput(
    token: VoiceSynthesisToken,
    playbackGeneration: UInt64,
    activeLeaseID: VoiceLeaseID?
  ) -> Bool {
    token.generation == playbackGeneration && token.leaseID == activeLeaseID
  }

  static func shouldUseFallback(
    afterCancellation: Bool,
    token: VoiceSynthesisToken,
    playbackGeneration: UInt64,
    activeLeaseID: VoiceLeaseID?
  ) -> Bool {
    !afterCancellation
      && ownsCurrentOutput(
        token: token,
        playbackGeneration: playbackGeneration,
        activeLeaseID: activeLeaseID)
  }
}

private enum PlaybackMode: Sendable {
  case openAI(voiceID: String, instructions: String)
  case geminiTTS(voiceID: String)
  case localPiper
  case systemVoice(ShortcutSettings.VoiceOption)
}

/// The copy the floating bar shows in place of an answer it could not get.
///
/// One home for those strings, because the voice lane must never read them
/// aloud and the two halves have already drifted once: the empty-response copy
/// was rewritten while `shouldSpeak` went on matching the retired sentence, so
/// a voice query that produced nothing had its failure notice spoken. Adding a
/// line here suppresses it by construction; a copy edit that forgets this type
/// no longer has a silent failure mode, because the copy *is* this type.
enum FloatingBarAnswerFailureCopy {
  /// The turn finished with no answer content at all — no text, no blocks.
  static let emptyResponse = "Omi couldn't get an answer for that one."

  /// Retired wording. Kept because a transcript written by an older build can
  /// still hold it, and because staying silent on it costs one string.
  static let retired = ["Failed to get a response. Please try again."]

  private static let unspoken: Set<String> = Set(
    ([emptyResponse] + retired).map { $0.lowercased() })

  /// Whether already-lowercased spoken text is one of those notices.
  static func isFailureCopy(_ lowercasedText: String) -> Bool {
    unspoken.contains(lowercasedText)
  }
}
