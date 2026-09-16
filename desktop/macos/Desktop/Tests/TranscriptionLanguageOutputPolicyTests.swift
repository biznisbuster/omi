import FluidAudio
import XCTest

@testable import Omi_Computer

final class TranscriptionLanguageOutputPolicyTests: XCTestCase {
  func testSerbianAndItsLatinNeighboursTakeTheLatinScriptHint() {
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "sr"), .croatian)
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "sr-RS"), .croatian)
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "HR"), .croatian)
  }

  func testHintMapsKnownLanguagesAndLeavesUnknownOnesUnfiltered() {
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "en"), .english)
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "de-DE"), .german)
    XCTAssertNil(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: "multi"))
    XCTAssertNil(TranscriptionLanguageOutputPolicy.parakeetLanguageHint(for: ""))
  }

  func testSerbianTranscriptsFoldForeignDiacriticsOntoTheSerbianAlphabet() {
    XCTAssertEqual(
      TranscriptionLanguageOutputPolicy.normalized("Zakľučak, dozvola postoji", language: "sr"),
      "Zaključak, dozvola postoji")
    XCTAssertEqual(
      TranscriptionLanguageOutputPolicy.normalized("bináriu", language: "sr"),
      "binariu")
    XCTAssertEqual(
      TranscriptionLanguageOutputPolicy.normalized("Áno, další test", language: "sr"),
      "Ano, dalši test",
      "vowel lengths are foreign; š is a Serbian letter and must survive")
  }

  func testSerbianAlphabetAndPunctuationSurviveUntouched() {
    let serbian = "ČćĐđŠšŽž — 22:53, „navodnici” (test)."
    XCTAssertEqual(TranscriptionLanguageOutputPolicy.normalized(serbian, language: "sr"), serbian)
  }

  func testOtherLanguagesKeepTheDecodersText() {
    XCTAssertEqual(
      TranscriptionLanguageOutputPolicy.normalized("Über Zakľučak", language: "de"),
      "Über Zakľučak",
      "normalization is a Serbian-only repair; a genuine German umlaut must survive")
  }
}
