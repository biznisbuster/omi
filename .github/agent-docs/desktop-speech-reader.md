# Desktop speech reader lane

How Transcript-mode answers are spoken aloud. The reader is a **separate Live
session** from Voice Live's hub: the hub answers questions, the reader only
reads text it is given.

## One code path, many models

`NativeAudioSpeechRenderer` (`desktop/macos/Desktop/Sources/FloatingControlBar/`)
owns the lane for every reader model. **Only the model id changes** — never add
model-specific branches:

| Model | Role |
|---|---|
| `gemini-2.5-flash-native-audio-latest` | default, verified reader |
| `gemini-3.1-flash-live-preview`, `gemini-3.8-live` | dialogue models, selectable, weaker readers |

`NativeAudioSpeechRendererTests.testEverySpeechModelSharesOneSetupPath` fails
if a model grows its own setup payload. The payload carries **only** the reader
contract (model, AUDIO modality, voice, verbatim instruction, output
transcription, context compression) — **never chat context**.

Transcript models (`gemini-3.5-transcribe*`) reject AUDIO output and are not
voices; the model picker must never offer them.

## Chunking (`NativeSpeechChunking`)

- `twoPart` (default): turns of **up to 500 characters**, cut at the last period
  inside the window (commas/dashes are not boundaries). A completed answer
  shorter than the window is a **single turn**; nothing is emitted while a
  short answer is still streaming.
- `whole`: one turn, after the answer completes.
- `standard` / `small`: the legacy TTS chunking, kept as fallbacks.

The service emits chunks as text arrives; the renderer's gate releases the next
turn only once the previous turn has produced audio, so turns never reach the
provider in the same moment (a burst makes it coalesce turns and drop
`turnComplete`).

## Completion is model-agnostic

Do not trust a single signal. In order of preference:

1. `turnComplete` — normal path.
2. `generationComplete` + **1.5 s of audio quiet** — 3.8 Live never sends
   `turnComplete`; completing immediately on `generationComplete` drops the
   trailing audio (it arrives while audio still streams).
3. **2 s of silence after audible speech** (peak level per PCM buffer) — a
   reader that stopped speaking is done even if the server keeps the turn open.
4. Safety caps: off-script (server transcription exceeds the script) and
   runaway duration (2.5× expected, minimum 15 s of **audible** audio).

A turn that never produced audio never completes silently; it waits for
`turnComplete` or the stall watchdog so the on-device fallback can read it.

## Voice Live is a different lane

`RealtimeHubController` warms a Gemini Live session **only in Voice Live mode**
(`PTTVoiceMode.current == .live`). In Transcript mode the hub would upload the
full chat context (~10k tokens) to a model that never speaks. Do not remove that
gate.

The Gemini prebuilt voices are shared: picking a native-audio reading voice also
sets the Live voice (and vice versa), so the two pickers cannot disagree.

## Fallbacks

Reader failure → `FloatingBarVoicePlaybackService.speakWithFallback` → on-device
Piper → system voice, with `recordFallback` telemetry. A chunk that was already
partly heard is never re-read from the start (`unspokenRemainder` estimates the
tail).

## Settings keys

- `speechNativeAudioModel` — reader model id.
- `speechNativeAudioChunking` — `twoPart` | `whole` | `standard` | `small`.
- `shortcut_selectedVoiceID` — the reading voice (`native:<name>` entries).
- `realtimeGeminiVoice` — the Voice Live voice, kept in sync for native voices.

## Tests

`Desktop/Tests/NativeAudioSpeechRendererTests.swift` (scripted socket:
pipelining, completion signals, trailing audio, runaway caps, rotation) and
`FloatingBarVoiceResponseSettingsTests` (voice/provider wiring).
