import XCTest

@testable import Omi_Computer

final class LocalVoiceSynthesisServiceTests: XCTestCase {
  private var root: URL = FileManager.default.temporaryDirectory

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("omi-local-voice-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func makeInstalledLayout(service: LocalVoiceSynthesisService) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: service.piperExecutableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: service.piperExecutableURL, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: service.piperExecutableURL.path)

    try fileManager.createDirectory(
      at: service.modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("model".utf8).write(to: service.modelURL)
    try Data("{}".utf8).write(to: service.modelConfigURL)
  }

  func testReportsNotInstalledOnAnEmptyRootAndRefusesSynthesis() async throws {
    let service = LocalVoiceSynthesisService(rootURL: root)

    XCTAssertFalse(service.isInstalled)
    do {
      _ = try await service.synthesize(text: "Zdravo")
      XCTFail("synthesis must be refused while the local voice is not installed")
    } catch let error as LocalVoiceSynthesisService.SynthesisError {
      guard case .notInstalled = error else {
        return XCTFail("expected .notInstalled, got \(error)")
      }
    }
  }

  func testReportsInstalledOnceRuntimeAndVoiceFilesExist() throws {
    let service = LocalVoiceSynthesisService(rootURL: root)
    try makeInstalledLayout(service: service)

    XCTAssertTrue(service.isInstalled)
  }

  func testEnsureInstalledIsANoOpWhenEverythingIsPresent() async throws {
    let service = LocalVoiceSynthesisService(rootURL: root)
    try makeInstalledLayout(service: service)

    try await service.ensureInstalled()
    XCTAssertTrue(service.isInstalled)
  }

  func testRejectsEmptyTextWithoutTouchingTheRuntime() async throws {
    let service = LocalVoiceSynthesisService(rootURL: root)
    try makeInstalledLayout(service: service)

    do {
      _ = try await service.synthesize(text: "   \n")
      XCTFail("empty text must not reach the runtime")
    } catch let error as LocalVoiceSynthesisService.SynthesisError {
      guard case .emptyText = error else {
        return XCTFail("expected .emptyText, got \(error)")
      }
    }
  }

  func testSha256HelperMatchesTheKnownDigest() throws {
    let file = root.appendingPathComponent("digest.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: file)

    XCTAssertEqual(
      try LocalVoiceSynthesisService.sha256Hex(contentsOf: file),
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
}
