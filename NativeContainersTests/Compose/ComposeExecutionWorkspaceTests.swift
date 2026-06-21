import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ComposeExecutionWorkspaceTests {
  @Test
  func storesReviewedBytesAtAStablePrivateImmutablePath() throws {
    let fixture = try ComposeExecutionWorkspaceFixture()
    defer { fixture.remove() }
    let workspace = FileComposeExecutionWorkspace(rootURL: fixture.rootURL)
    let bytes = Data(#"{"name":"sample","services":{}}"#.utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

    let lease = try workspace.prepare(
      operationID: UUID(),
      projectName: "sample",
      canonicalConfiguration: bytes,
      expectedSHA256: digest
    )

    #expect(try Data(contentsOf: lease.configurationURL) == bytes)
    var directoryMetadata = stat()
    var fileMetadata = stat()
    #expect(Darwin.lstat(lease.directoryURL.path, &directoryMetadata) == 0)
    #expect(Darwin.lstat(lease.configurationURL.path, &fileMetadata) == 0)
    #expect(directoryMetadata.st_mode & mode_t(0o777) == mode_t(0o700))
    #expect(fileMetadata.st_mode & mode_t(0o777) == mode_t(0o600))
    #expect(fileMetadata.st_nlink == 1)

    try workspace.release(lease)
    let secondLease = try workspace.prepare(
      operationID: UUID(),
      projectName: "sample",
      canonicalConfiguration: bytes,
      expectedSHA256: digest
    )

    #expect(secondLease.directoryURL == lease.directoryURL)
    #expect(secondLease.configurationURL == lease.configurationURL)
    #expect(secondLease.fileIdentity == lease.fileIdentity)
    #expect(FileManager.default.fileExists(atPath: lease.configurationURL.path))
  }

  @Test
  func refusesCanonicalBytesThatDoNotMatchTheReviewedDigest() throws {
    let fixture = try ComposeExecutionWorkspaceFixture()
    defer { fixture.remove() }
    let workspace = FileComposeExecutionWorkspace(rootURL: fixture.rootURL)

    #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try workspace.prepare(
        operationID: UUID(),
        projectName: "sample",
        canonicalConfiguration: Data("changed".utf8),
        expectedSHA256: String(repeating: "0", count: 64)
      )
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.rootURL.path).isEmpty
    )
  }

  @Test
  func refusesToReleaseAConfigurationReplacedAfterLeaseCreation() throws {
    let fixture = try ComposeExecutionWorkspaceFixture()
    defer { fixture.remove() }
    let workspace = FileComposeExecutionWorkspace(rootURL: fixture.rootURL)
    let bytes = Data(#"{"name":"sample","services":{}}"#.utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let lease = try workspace.prepare(
      operationID: UUID(),
      projectName: "sample",
      canonicalConfiguration: bytes,
      expectedSHA256: digest
    )

    try FileManager.default.removeItem(at: lease.configurationURL)
    try bytes.write(to: lease.configurationURL, options: .withoutOverwriting)
    #expect(Darwin.chmod(lease.configurationURL.path, mode_t(0o600)) == 0)

    #expect(throws: ComposeProjectLifecycleError.self) {
      try workspace.release(lease)
    }
    #expect(FileManager.default.fileExists(atPath: lease.configurationURL.path))
  }

  @Test
  func rejectsASymbolicLinkAtTheWorkspaceRoot() throws {
    let fixture = try ComposeExecutionWorkspaceFixture(createRoot: false)
    defer { fixture.remove() }
    let target = fixture.parentURL.appending(
      path: "target",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    #expect(Darwin.chmod(target.path, mode_t(0o700)) == 0)
    try FileManager.default.createSymbolicLink(
      at: fixture.rootURL,
      withDestinationURL: target
    )
    let workspace = FileComposeExecutionWorkspace(rootURL: fixture.rootURL)
    let bytes = Data("{}".utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

    #expect(throws: ComposeProjectLifecycleError.self) {
      _ = try workspace.prepare(
        operationID: UUID(),
        projectName: "sample",
        canonicalConfiguration: bytes,
        expectedSHA256: digest
      )
    }
  }
}

private final class ComposeExecutionWorkspaceFixture {
  let parentURL: URL
  let rootURL: URL

  init(createRoot: Bool = true) throws {
    parentURL = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-compose-execution-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    rootURL = parentURL.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: parentURL,
      withIntermediateDirectories: false
    )
    #expect(Darwin.chmod(parentURL.path, mode_t(0o700)) == 0)
    if createRoot {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: false
      )
      #expect(Darwin.chmod(rootURL.path, mode_t(0o700)) == 0)
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: parentURL)
  }
}
