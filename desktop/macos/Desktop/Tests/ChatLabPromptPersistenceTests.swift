import XCTest

@testable import Omi_Computer

/// The Lab's save path: a saved version and the active selection must survive a
/// relaunch, edits to a saved version must be kept as typed, and the built-in
/// prompt must stay a code-owned baseline rather than accumulating drafts.
@MainActor
final class ChatLabPromptPersistenceTests: XCTestCase {

  private struct Harness {
    let suiteName: String
    let defaults: UserDefaults
    let store: ChatLabPromptStore
  }

  private func makeHarness() -> Harness {
    let suiteName = "ChatLabPromptPersistenceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return Harness(suiteName: suiteName, defaults: defaults, store: ChatLabPromptStore(defaults: defaults))
  }

  private func cleanup(_ harness: Harness) {
    harness.defaults.removePersistentDomain(forName: harness.suiteName)
  }

  /// A store over the same suite, to read what a next launch would see.
  private func relaunchedStore(_ harness: Harness) -> ChatLabPromptStore {
    ChatLabPromptStore(defaults: UserDefaults(suiteName: harness.suiteName)!)
  }

  func testSavedVersionRoundTripsThroughTheStore() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let saved = ChatLabSavedPrompt(
      id: "prompt-a", name: "v2", floatingPrefix: "floating prefix", mainPrompt: "main prompt")
    harness.store.upsert(saved)

    XCTAssertEqual(relaunchedStore(harness).loadVersions(), [saved])
  }

  func testCorruptStoredPayloadDegradesToNoSavedVersions() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    harness.defaults.set(Data("not json".utf8), forKey: ChatLabPromptStore.versionsKey)

    XCTAssertEqual(harness.store.loadVersions(), [])
  }

  func testANewLabStartsWithTheBuiltInPromptActive() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let vm = ChatLabViewModel(chatProvider: ChatProvider(), promptStore: harness.store)

    XCTAssertEqual(vm.versions.count, 1)
    XCTAssertTrue(vm.versions[vm.selectedVersionIndex].isBuiltIn)
    XCTAssertEqual(vm.editingFloatingPrefix, ChatProvider.floatingBarSystemPromptPrefix)
  }

  func testSavedVersionAndActiveSelectionSurviveRelaunch() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let provider = ChatProvider()
    let first = ChatLabViewModel(chatProvider: provider, promptStore: harness.store)
    first.editingFloatingPrefix = "custom floating prefix"
    first.editingMainPrompt = "custom main prompt"
    first.saveAsNewVersion(name: "my-prompt")

    XCTAssertEqual(first.versions.count, 2)
    XCTAssertEqual(first.versions[first.selectedVersionIndex].name, "my-prompt")
    XCTAssertEqual(harness.store.activeVersionID, first.versions[first.selectedVersionIndex].id)

    let second = ChatLabViewModel(chatProvider: provider, promptStore: relaunchedStore(harness))

    XCTAssertEqual(second.versions.map(\.name), ["v1 (current)", "my-prompt"])
    XCTAssertEqual(second.versions[second.selectedVersionIndex].name, "my-prompt")
    XCTAssertEqual(second.editingFloatingPrefix, "custom floating prefix")
    XCTAssertEqual(second.editingMainPrompt, "custom main prompt")
  }

  func testEditsToASavedVersionAreKeptAsTyped() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let provider = ChatProvider()
    let first = ChatLabViewModel(chatProvider: provider, promptStore: harness.store)
    first.editingFloatingPrefix = "draft prefix"
    first.editingMainPrompt = "draft main"
    first.saveAsNewVersion(name: "saved")

    first.editorDidChange(floatingPrefix: "edited prefix", mainPrompt: "edited main")

    let second = ChatLabViewModel(chatProvider: provider, promptStore: relaunchedStore(harness))
    XCTAssertEqual(second.editingFloatingPrefix, "edited prefix")
    XCTAssertEqual(second.editingMainPrompt, "edited main")
  }

  func testEditsToTheBuiltInPromptStayAScratchDraft() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let provider = ChatProvider()
    let first = ChatLabViewModel(chatProvider: provider, promptStore: harness.store)
    first.editorDidChange(floatingPrefix: "scratch", mainPrompt: "scratch main")

    XCTAssertEqual(harness.store.loadVersions(), [], "the built-in prompt is code-owned and must not be stored")

    let second = ChatLabViewModel(chatProvider: provider, promptStore: relaunchedStore(harness))
    XCTAssertEqual(second.editingFloatingPrefix, ChatProvider.floatingBarSystemPromptPrefix)
  }

  func testActivatingTheBuiltInPromptClearsTheStoredChoice() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    let vm = ChatLabViewModel(chatProvider: ChatProvider(), promptStore: harness.store)
    vm.editingFloatingPrefix = "floating"
    vm.saveAsNewVersion(name: "saved")
    XCTAssertNotNil(harness.store.activeVersionID)

    vm.activateVersion(at: 0)

    XCTAssertNil(harness.store.activeVersionID)
    XCTAssertTrue(vm.versions[vm.selectedVersionIndex].isBuiltIn)
    XCTAssertEqual(vm.editingFloatingPrefix, ChatProvider.floatingBarSystemPromptPrefix)
  }

  func testAnUnknownStoredActiveIDFallsBackToTheBuiltInPrompt() {
    let harness = makeHarness()
    defer { cleanup(harness) }

    harness.store.activeVersionID = "ghost-prompt-that-no-longer-exists"

    let vm = ChatLabViewModel(chatProvider: ChatProvider(), promptStore: harness.store)

    XCTAssertEqual(vm.selectedVersionIndex, 0)
    XCTAssertTrue(vm.versions[vm.selectedVersionIndex].isBuiltIn)
  }
}
