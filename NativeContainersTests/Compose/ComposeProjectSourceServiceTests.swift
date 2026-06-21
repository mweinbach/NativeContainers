import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Compose project source access")
struct ComposeProjectSourceServiceTests {
  @Test
  func acquiresOnePrivateConventionalFileAndPinsItsDigest() async throws {
    let fixture = try ComposeSourceFixture(files: ["compose.yaml": "services: {}\n"])
    defer { fixture.remove() }
    let service = FileComposeProjectSourceService()

    let lease = try await service.acquire(directoryURL: fixture.directoryURL)
    try await service.revalidate(lease)

    #expect(lease.summary.fileName == "compose.yaml")
    #expect(lease.summary.fileIdentity.byteCount == 13)
    #expect(lease.summary.fileIdentity.sha256.count == 64)

    await service.release(lease)
    await #expect(throws: ComposeProjectLifecycleError.sourceChanged) {
      try await service.revalidate(lease)
    }
  }

  @Test
  func rejectsAmbiguousConventionalFiles() async throws {
    let fixture = try ComposeSourceFixture(
      files: [
        "compose.yaml": "services: {}\n",
        "docker-compose.yml": "services: {}\n",
      ]
    )
    defer { fixture.remove() }
    let service = FileComposeProjectSourceService()

    await #expect(
      throws: ComposeProjectLifecycleError.composeFileAmbiguous([
        "compose.yaml", "docker-compose.yml",
      ])
    ) {
      _ = try await service.acquire(directoryURL: fixture.directoryURL)
    }
  }

  @Test
  func rejectsSymlinkedComposeFile() async throws {
    let fixture = try ComposeSourceFixture(files: ["actual.yaml": "services: {}\n"])
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(
      at: fixture.directoryURL.appending(path: "compose.yaml"),
      withDestinationURL: fixture.directoryURL.appending(path: "actual.yaml")
    )
    let service = FileComposeProjectSourceService()

    await #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try await service.acquire(directoryURL: fixture.directoryURL)
    }
  }

  @Test
  func revalidationDetectsAnInPlaceSourceChange() async throws {
    let fixture = try ComposeSourceFixture(files: ["compose.yaml": "services: {}\n"])
    defer { fixture.remove() }
    let service = FileComposeProjectSourceService()
    let lease = try await service.acquire(directoryURL: fixture.directoryURL)

    let fileURL = fixture.directoryURL.appending(path: "compose.yaml")
    try "services:\n  web: {}\n".write(to: fileURL, atomically: false, encoding: .utf8)
    guard chmod(fileURL.nativeContainersPOSIXPath, 0o600) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }

    await #expect(throws: ComposeProjectLifecycleError.sourceChanged) {
      try await service.revalidate(lease)
    }
    await service.release(lease)
  }
}

private final class ComposeSourceFixture {
  let directoryURL: URL

  init(files: [String: String]) throws {
    directoryURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-compose-source-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false
    )
    guard chmod(directoryURL.nativeContainersPOSIXPath, 0o700) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }
    for (name, contents) in files {
      let fileURL = directoryURL.appending(path: name)
      try contents.write(to: fileURL, atomically: false, encoding: .utf8)
      guard chmod(fileURL.nativeContainersPOSIXPath, 0o600) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
      }
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
