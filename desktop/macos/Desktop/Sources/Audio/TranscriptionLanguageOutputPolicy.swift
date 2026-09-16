import FluidAudio
import Foundation

/// What the local (Parakeet v3) decoder needs to know about the requested
/// language, and what our own output side owes when the model cannot know.
///
/// The v3 model is multilingual and language-agnostic past the acoustic stage:
/// its only language knob is a token filter that partitions the vocabulary by
/// *script* (Latin vs Cyrillic). It has no per-language allowlist — FluidAudio
/// documents that as future work — so closely related Latin-script languages
/// come out of the joint network with each other's orthography (Serbian speech
/// answered with Slovak/Czech vowel lengths, e.g. "Zakľučak", "bináriu").
enum TranscriptionLanguageOutputPolicy {
  /// The v3 language hint applies a script filter to decoder tokens.
  ///
  /// FluidAudio classifies Serbian as Cyrillic, but that filter also rejects
  /// ASCII letters — it would drop every Latin word ("Omi", "macOS", "TCC") —
  /// and the desktop transcripts are Latin-script. Serbian Latin shares its
  /// alphabet with Croatian/Bosnian, so those get the Latin hint: it blocks
  /// Cyrillic tokens (the Russian/Ukrainian confusion) while allowing every
  /// Latin Extended range the Serbian Latin alphabet lives in.
  static func parakeetLanguageHint(for language: String) -> Language? {
    switch language.prefix(2).lowercased() {
    case "sr", "hr", "bs", "sl":
      return .croatian
    default:
      return Language(rawValue: String(language.prefix(2)).lowercased())
    }
  }

  /// Serbian Latin letters — the alphabet the model should have produced.
  private static let serbianLatinLetters: Set<Character> = ["č", "ć", "đ", "š", "ž"]

  /// Latin letters and digraphs used by Serbian's Latin neighbours, mapped onto
  /// the Serbian alphabet. Applying this to a Serbian transcript turns the
  /// model's Slovak/Czech/Polish spellings back into Serbian readings:
  /// "Zakľučak" → "Zaključak", "bináriu" → "binariu", "povrty" → "povrty".
  private static let foreignDiacriticReplacements: [Character: String] = [
    "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y",
    "ĺ": "l", "ľ": "lj", "ŕ": "r", "ď": "d", "ť": "t", "ň": "n", "ń": "n",
    "ě": "e", "ř": "r", "ę": "e", "ą": "a", "ś": "s", "ź": "z", "ż": "z",
    "ô": "o", "ä": "a", "ö": "o", "ü": "u", "ß": "ss", "ă": "a", "â": "a",
    "î": "i", "û": "u", "ė": "e", "ų": "u", "ū": "u", "ā": "a", "ī": "i",
    "ē": "e", "ō": "o", "ł": "l", "ș": "s", "ț": "t", "ş": "s", "ğ": "g", "ı": "i",
  ]

  /// Fold foreign Latin diacritics onto the Serbian alphabet for Serbian
  /// sessions only. Other languages keep the decoder's text untouched: a
  /// genuine "über" in a German session must not become "uber".
  static func normalized(_ text: String, language: String) -> String {
    guard language.prefix(2).lowercased() == "sr" else { return text }
    guard text.contains(where: { $0.isLetter }) else { return text }

    var output = String()
    output.reserveCapacity(text.count)
    for character in text {
      if serbianLatinLetters.contains(character) {
        output.append(character)
        continue
      }
      if let replacement = foreignDiacriticReplacements[character] {
        output.append(contentsOf: replacement)
        continue
      }
      if let lowercased = character.lowercased().first,
        let replacement = foreignDiacriticReplacements[lowercased]
      {
        output.append(contentsOf: replacement.prefix(1).uppercased())
        output.append(contentsOf: replacement.dropFirst())
        continue
      }
      output.append(character)
    }
    return output
  }
}
