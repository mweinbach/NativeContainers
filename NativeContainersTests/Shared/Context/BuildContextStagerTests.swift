import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

struct BuildContextStagerTests {
  @Test
  func stagesPrivateCopyWithStableHashesAndFingerprint() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    let dockerfile = try fixture.write(
      "FROM scratch\nCOPY payload.txt /payload.txt\n",
      to: "Dockerfile"
    )
    let dockerignore = try fixture.write("ignored.txt\n", to: ".dockerignore")
    _ = try fixture.write("payload", to: "nested/payload.txt", executable: true)

    let staging: any BuildContextStaging = fixture.stager
    let first = try await staging.stage(sourceDirectory: fixture.sourceURL)
    let second = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    try await staging.validate(first)

    #expect(first.contextURL.deletingLastPathComponent() == fixture.stagingURL)
    #expect(first.contextURL.lastPathComponent == first.id.uuidString.lowercased())
    #expect(first.dockerfileURL == first.contextURL.appending(path: "Dockerfile"))
    #expect(try Data(contentsOf: first.dockerfileURL) == Data(contentsOf: dockerfile))
    #expect(first.dockerfileSHA256 == sha256(try Data(contentsOf: dockerfile)))
    #expect(first.dockerignoreURL == first.contextURL.appending(path: ".dockerignore"))
    #expect(first.dockerignoreSHA256 == sha256(try Data(contentsOf: dockerignore)))
    #expect(first.fingerprint == second.fingerprint)
    #expect(first.dockerfileSHA256 == second.dockerfileSHA256)

    let attributes = try FileManager.default.attributesOfItem(atPath: first.contextURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let stagedExecutable = first.contextURL.appending(path: "nested/payload.txt")
    let executableAttributes = try FileManager.default.attributesOfItem(
      atPath: stagedExecutable.path
    )
    #expect(((executableAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o100 != 0)
  }

  @Test
  func preservesDockerVisibleFileAndDirectoryModesInsidePrivateBoundary() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    let dockerfile = try fixture.write("FROM scratch\nCOPY . /app\n", to: "Dockerfile")
    let regular = try fixture.write("plain", to: "assets/plain.txt")
    let executable = try fixture.write("#!/bin/sh\n", to: "bin/entrypoint")
    let assets = regular.deletingLastPathComponent()
    let bin = executable.deletingLastPathComponent()
    for (url, mode) in [
      (dockerfile, 0o644),
      (regular, 0o644),
      (executable, 0o755),
      (assets, 0o755),
      (bin, 0o755),
    ] {
      try FileManager.default.setAttributes(
        [.posixPermissions: mode],
        ofItemAtPath: url.path(percentEncoded: false)
      )
    }

    let staged = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    try await fixture.stager.validate(staged)

    #expect(try permissions(of: staged.contextURL) == 0o700)
    #expect(try permissions(of: staged.contextURL.appending(path: "Dockerfile")) == 0o644)
    #expect(try permissions(of: staged.contextURL.appending(path: "assets")) == 0o755)
    #expect(try permissions(of: staged.contextURL.appending(path: "assets/plain.txt")) == 0o644)
    #expect(try permissions(of: staged.contextURL.appending(path: "bin")) == 0o755)
    #expect(try permissions(of: staged.contextURL.appending(path: "bin/entrypoint")) == 0o755)
  }

  @Test
  func fingerprintChangesWhenFileBytesChange() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\nCOPY payload /payload\n", to: "Dockerfile")
    let payload = try fixture.write("before", to: "payload")

    let first = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    try Data("after".utf8).write(to: payload)
    let second = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)

    #expect(first.fingerprint != second.fingerprint)
    #expect(first.dockerfileSHA256 == second.dockerfileSHA256)
  }

  @Test
  func validateRejectsPayloadMutationAfterReview() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\nCOPY payload /payload\n", to: "Dockerfile")
    _ = try fixture.write("reviewed", to: "payload")
    let staged = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    try await fixture.stager.validate(staged)

    try Data("mutated".utf8).write(to: staged.contextURL.appending(path: "payload"))

    await #expect(throws: BuildContextStagingError.stagedFingerprintMismatch) {
      try await fixture.stager.validate(staged)
    }
  }

  @Test
  func validateRejectsExecutableModeMutationAfterReview() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\nCOPY payload /payload\n", to: "Dockerfile")
    _ = try fixture.write("reviewed", to: "payload")
    let staged = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    let payload = staged.contextURL.appending(path: "payload")
    #expect(Darwin.chmod(payload.path(percentEncoded: false), 0o700) == 0)

    await #expect(throws: BuildContextStagingError.stagedFingerprintMismatch) {
      try await fixture.stager.validate(staged)
    }
  }

  @Test
  func validateRejectsModificationTimeMutationAfterReview() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\nCOPY payload /payload\n", to: "Dockerfile")
    _ = try fixture.write("reviewed", to: "payload")
    let staged = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    let payload = staged.contextURL.appending(path: "payload")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_234_567_890)],
      ofItemAtPath: payload.path(percentEncoded: false)
    )

    await #expect(throws: BuildContextStagingError.stagedFingerprintMismatch) {
      try await fixture.stager.validate(staged)
    }
  }

  @Test
  func stagesSelectedDockerfileSiblingIgnoreFile() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    let dockerfile = try fixture.write("FROM scratch\n", to: "docker/Release.Dockerfile")
    let ignore = try fixture.write(
      "local-only\n",
      to: "docker/Release.Dockerfile.dockerignore"
    )
    _ = try fixture.write("root ignore is not selected\n", to: ".dockerignore")

    let result = try await fixture.stager.stage(
      sourceDirectory: fixture.sourceURL,
      dockerfile: dockerfile,
      dockerignore: .dockerfileSibling
    )

    #expect(result.dockerfileURL.path.hasSuffix("/docker/Release.Dockerfile"))
    #expect(
      result.dockerignoreURL?.path.hasSuffix("/docker/Release.Dockerfile.dockerignore") == true)
    #expect(result.dockerignoreSHA256 == sha256(try Data(contentsOf: ignore)))
  }

  @Test
  func rejectsSymbolicLinksWithoutFollowingThem() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")
    let linkURL = fixture.sourceURL.appending(path: "escape")
    try FileManager.default.createSymbolicLink(
      at: linkURL,
      withDestinationURL: fixture.rootURL.appending(path: "outside-secret")
    )

    await #expect(
      throws: BuildContextStagingError.unsupportedEntry(
        path: "escape",
        kind: .symbolicLink
      )
    ) {
      _ = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
    #expect(try fixture.stagedDirectories().isEmpty)
  }

  @Test
  func rejectsFIFOs() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")
    let fifoURL = fixture.sourceURL.appending(path: "stream")
    try #require(Darwin.mkfifo(fifoURL.path, 0o600) == 0)

    await #expect(
      throws: BuildContextStagingError.unsupportedEntry(path: "stream", kind: .fifo)
    ) {
      _ = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
    #expect(try fixture.stagedDirectories().isEmpty)
  }

  @Test
  func rejectsLeadingCustomSyntaxDirectiveAndCleansFailedCopy() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write(
      """

      # ordinary leading comment
      # syntax = docker/dockerfile:1.9
      FROM scratch
      """,
      to: "Dockerfile"
    )
    _ = try fixture.write("copied before validation", to: "payload")

    await #expect(throws: BuildContextStagingError.customDockerfileSyntax) {
      _ = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }

    #expect(try fixture.stagedDirectories().isEmpty)
  }

  @Test
  func rejectsDockerfileAtExactSixteenKiBLimit() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    try Data(repeating: 0x20, count: 16 * 1_024).write(
      to: fixture.sourceURL.appending(path: "Dockerfile")
    )

    await #expect(throws: BuildContextStagingError.dockerfileTooLarge(16 * 1_024)) {
      _ = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
    #expect(try fixture.stagedDirectories().isEmpty)
  }

  @Test
  func rejectsDockerfileOutsideSourceBeforeCreatingStage() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")
    let outsideURL = fixture.rootURL.appending(path: "Outside.Dockerfile")
    try Data("FROM scratch\n".utf8).write(to: outsideURL)

    await #expect(
      throws: BuildContextStagingError.dockerfileOutsideContext(outsideURL.standardizedFileURL)
    ) {
      _ = try await fixture.stager.stage(
        sourceDirectory: fixture.sourceURL,
        dockerfile: outsideURL
      )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
  }

  @Test
  func rejectsStagingRootInsideSource() async throws {
    let fixture = try BuildContextStagingFixture(stagingInsideSource: true)
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")

    await #expect(throws: BuildContextStagingError.stagingRootOverlapsSource) {
      _ = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
  }

  @Test
  func rejectsStagingRootInsideSourceThroughAncestorAlias() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let actualURL = rootURL.appending(path: "actual", directoryHint: .isDirectory)
    let sourceURL = actualURL.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try Data("FROM scratch\n".utf8).write(to: sourceURL.appending(path: "Dockerfile"))
    let aliasURL = rootURL.appending(path: "alias", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: actualURL)
    let aliasedSourceURL = aliasURL.appending(path: "source", directoryHint: .isDirectory)
    let stagingURL = sourceURL.appending(path: ".staging", directoryHint: .isDirectory)
    let stager = BuildContextStager(stagingRoot: stagingURL)

    await #expect(throws: BuildContextStagingError.stagingRootOverlapsSource) {
      _ = try await stager.stage(sourceDirectory: aliasedSourceURL)
    }
    #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
  }

  @Test
  func discardRemovesOnlyReturnedStageAndIsIdempotent() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")
    let result = try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    #expect(FileManager.default.fileExists(atPath: result.contextURL.path))

    try await fixture.stager.discard(result)
    #expect(!FileManager.default.fileExists(atPath: result.contextURL.path))
    try await fixture.stager.discard(result)
  }

  @Test
  func preCancelledStageDoesNotCreateStagingArtifacts() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\n", to: "Dockerfile")
    let task = Task {
      try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(try fixture.stagedDirectories().isEmpty)
  }

  @Test
  func inFlightStageCancellationStopsDetachedCopyAndCleansPartialTree() async throws {
    let fixture = try BuildContextStagingFixture()
    defer { fixture.remove() }
    _ = try fixture.write("FROM scratch\nCOPY payload /payload\n", to: "Dockerfile")
    let payload = fixture.sourceURL.appending(path: "payload")
    let descriptor = Darwin.open(
      payload.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      0o600
    )
    try #require(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    try #require(Darwin.ftruncate(descriptor, 256 * 1_024 * 1_024) == 0)

    let task = Task {
      try await fixture.stager.stage(sourceDirectory: fixture.sourceURL)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while try fixture.stagedDirectories().isEmpty, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(!fixture.stagedDirectories().isEmpty)
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(try fixture.stagedDirectories().isEmpty)
  }
}

private struct BuildContextStagingFixture {
  let rootURL: URL
  let sourceURL: URL
  let stagingURL: URL
  let stager: BuildContextStager

  init(stagingInsideSource: Bool = false) throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    let sourceURL = rootURL.appending(path: "source", directoryHint: .isDirectory)
    let stagingURL =
      stagingInsideSource
      ? sourceURL.appending(path: ".staging", directoryHint: .isDirectory)
      : rootURL.appending(path: "staging", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

    self.rootURL = rootURL
    self.sourceURL = sourceURL
    self.stagingURL = stagingURL
    self.stager = BuildContextStager(stagingRoot: stagingURL)
  }

  @discardableResult
  func write(_ contents: String, to relativePath: String, executable: Bool = false) throws -> URL {
    let url = sourceURL.appending(path: relativePath, directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    if executable {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
      )
    }
    return url
  }

  func stagedDirectories() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: stagingURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: stagingURL,
      includingPropertiesForKeys: nil
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func permissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(
    atPath: url.path(percentEncoded: false)
  )
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}
