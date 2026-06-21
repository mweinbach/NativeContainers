import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct SecureRegularFileValidatorTests {
  @Test
  func acceptsOwnedNonemptyRegularFile() throws {
    try withFixture { fixture in
      try Data("oci-archive".utf8).write(to: fixture.artifact)

      let identity = try fixture.validate()

      #expect(identity.size == 11)
    }
  }

  @Test
  func rejectsSymlinkArtifact() throws {
    try withFixture { fixture in
      let target = fixture.root.appending(path: "target.tar")
      try Data("not-reviewed".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: fixture.artifact, withDestinationURL: target)

      #expect(throws: SecureRegularFileValidationError.self) {
        _ = try fixture.validate()
      }
    }
  }

  @Test
  func rejectsHardLinkedArtifact() throws {
    try withFixture { fixture in
      let target = fixture.root.appending(path: "target.tar")
      try Data("not-private".utf8).write(to: target)
      try FileManager.default.linkItem(at: target, to: fixture.artifact)

      #expect(throws: SecureRegularFileValidationError.self) {
        _ = try fixture.validate()
      }
    }
  }

  @Test
  func rejectsGroupOrWorldWritableArtifact() throws {
    try withFixture { fixture in
      try Data("mutable".utf8).write(to: fixture.artifact)
      #expect(chmod(fixture.artifact.path(percentEncoded: false), 0o666) == 0)

      #expect(throws: SecureRegularFileValidationError.self) {
        _ = try fixture.validate()
      }
    }
  }

  @Test
  func rejectsDirectoryAtArtifactPath() throws {
    try withFixture { fixture in
      try FileManager.default.createDirectory(
        at: fixture.artifact, withIntermediateDirectories: false)

      #expect(throws: SecureRegularFileValidationError.self) {
        _ = try fixture.validate()
      }
    }
  }

  @Test
  func rejectsPathComponentsThatCouldEscapeTheReviewedDirectory() throws {
    try withFixture { fixture in
      #expect(throws: SecureRegularFileValidationError.invalidComponent("..")) {
        _ = try SecureRegularFileValidator.validate(
          rootDirectory: fixture.builderRoot,
          directoryName: "..",
          fileName: "out.tar"
        )
      }
      #expect(throws: SecureRegularFileValidationError.invalidComponent("nested/out.tar")) {
        _ = try SecureRegularFileValidator.validate(
          rootDirectory: fixture.builderRoot,
          directoryName: fixture.buildID.uuidString.lowercased(),
          fileName: "nested/out.tar"
        )
      }
    }
  }

  @Test
  func privateArtifactCopyIsBoundAndIndependentFromBuilderMount() throws {
    try withFixture { fixture in
      try Data("reviewed-oci".utf8).write(to: fixture.artifact)
      let privateRoot = fixture.root.appending(path: "private", directoryHint: .isDirectory)
      let store = PrivateBuildArtifactStore(rootDirectory: privateRoot)

      let artifact = try store.persist(
        sourceRootDirectory: fixture.builderRoot,
        sourceDirectoryName: fixture.buildID.uuidString.lowercased(),
        buildID: fixture.buildID
      )
      try Data("replaced-after-copy".utf8).write(to: fixture.artifact)

      _ = try store.validate(artifact, buildID: fixture.buildID)
      #expect(try Data(contentsOf: artifact.url) == Data("reviewed-oci".utf8))
      #expect(artifact.byteCount == 12)
      let attributes = try FileManager.default.attributesOfItem(atPath: artifact.url.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    }
  }

  @Test
  func privateArtifactValidationRejectsDigestAndSizeDrift() throws {
    try withFixture { fixture in
      try Data("reviewed-oci".utf8).write(to: fixture.artifact)
      let store = PrivateBuildArtifactStore(
        rootDirectory: fixture.root.appending(path: "private", directoryHint: .isDirectory)
      )
      let artifact = try store.persist(
        sourceRootDirectory: fixture.builderRoot,
        sourceDirectoryName: fixture.buildID.uuidString.lowercased(),
        buildID: fixture.buildID
      )

      #expect(throws: PrivateBuildArtifactStoreError.digestMismatch) {
        _ = try store.validate(
          PrivateBuildArtifact(
            url: artifact.url,
            sha256: String(repeating: "0", count: 64),
            byteCount: artifact.byteCount
          ),
          buildID: fixture.buildID
        )
      }
      #expect(throws: PrivateBuildArtifactStoreError.byteCountMismatch) {
        _ = try store.validate(
          PrivateBuildArtifact(
            url: artifact.url,
            sha256: artifact.sha256,
            byteCount: artifact.byteCount + 1
          ),
          buildID: fixture.buildID
        )
      }
    }
  }

  @Test
  func artifactCleanupRemovesPrivateAndInterruptedSharedExports() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-artifact-cleanup-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let buildID = UUID()
    let privateRoot = root.appending(path: "private", directoryHint: .isDirectory)
    let sharedRoot = root.appending(path: "shared", directoryHint: .isDirectory)
    let privateDirectory = privateRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    let sharedDirectory = sharedRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: privateDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sharedDirectory,
      withIntermediateDirectories: true
    )
    try Data("private".utf8).write(to: privateDirectory.appending(path: "out.tar"))
    try Data("interrupted".utf8).write(to: sharedDirectory.appending(path: "out.tar"))
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: privateRoot,
      sharedExportRoot: {
        guard !Task.isCancelled else { throw CancellationError() }
        return sharedRoot
      }
    )

    let cancelledCleanup = Task {
      while !Task.isCancelled { await Task.yield() }
      await manager.removeArtifacts(buildID: buildID)
    }
    cancelledCleanup.cancel()
    await cancelledCleanup.value

    #expect(!FileManager.default.fileExists(atPath: privateDirectory.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: sharedDirectory.path(percentEncoded: false)))
  }

  private func withFixture(_ body: (SecureFileFixture) throws -> Void) throws {
    let fixture = try SecureFileFixture()
    defer { fixture.remove() }
    try body(fixture)
  }
}

private struct SecureFileFixture {
  let root: URL
  let builderRoot: URL
  let buildID = UUID()
  let artifact: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-secure-file-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    builderRoot = root.appending(path: "builder", directoryHint: .isDirectory)
    let buildDirectory = builderRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    artifact = buildDirectory.appending(path: "out.tar", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
  }

  func validate() throws -> SecureRegularFileIdentity {
    try SecureRegularFileValidator.validate(
      rootDirectory: builderRoot,
      directoryName: buildID.uuidString.lowercased(),
      fileName: "out.tar"
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
