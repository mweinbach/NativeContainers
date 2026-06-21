import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite(.serialized)
struct ImageBuildOutputServiceTests {
  @Test
  func publishesReviewedOCIArchiveWithoutImageStoreMutation() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let bytes = Data("oci-archive".utf8)
    let result = try workspace.makeFileResult(
      buildID: buildID,
      kind: .ociArchive,
      bytes: bytes
    )
    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let destination = workspace.outputRoot.appending(path: "image.oci.tar")
    let plan = try await service.prepare(
      ImageBuildOutputSelection(kind: .ociArchive, destinationURL: destination)
    )
    let identity = try await manager.validateArtifact(result)

    let completion = try await service.publish(
      result,
      artifactIdentity: identity,
      plan: plan,
      authorization: .none
    )
    defer { Task { await service.discard(plan) } }

    #expect(try Data(contentsOf: destination) == bytes)
    guard case .ociArchive(let committed, let sha256, let byteCount) = completion else {
      Issue.record("Expected OCI archive completion")
      return
    }
    #expect(committed == destination.standardizedFileURL)
    #expect(sha256 == result.artifact.sha256)
    #expect(byteCount == Int64(bytes.count))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: workspace.outputRoot,
        includingPropertiesForKeys: nil
      ).map(\.lastPathComponent) == ["image.oci.tar"]
    )
  }

  @Test
  func archiveReplacementRequiresExactReviewedAuthorization() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let replacement = Data("replacement-archive".utf8)
    let result = try workspace.makeFileResult(
      buildID: buildID,
      kind: .rootFilesystemArchive,
      bytes: replacement
    )
    let destination = workspace.outputRoot.appending(path: "rootfs.tar")
    try Data("reviewed-old-value".utf8).write(to: destination)
    _ = chmod(destination.path(percentEncoded: false), 0o600)

    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let plan = try await service.prepare(
      ImageBuildOutputSelection(
        kind: .rootFilesystemArchive,
        destinationURL: destination
      )
    )
    defer { Task { await service.discard(plan) } }
    #expect(plan.replacesExistingDestination)
    let identity = try await manager.validateArtifact(result)

    do {
      _ = try await service.publish(
        result,
        artifactIdentity: identity,
        plan: plan,
        authorization: .none
      )
      Issue.record("Expected replacement authorization failure")
    } catch let error as ImageBuildOutputError {
      #expect(
        error
          == .outputReplacementRequiresConfirmation(
            destination.path(percentEncoded: false)
          )
      )
    }
    #expect(try Data(contentsOf: destination) == Data("reviewed-old-value".utf8))

    let completion = try await service.publish(
      result,
      artifactIdentity: identity,
      plan: plan,
      authorization: ImageBuildAuthorization(
        allowsTagReplacement: false,
        allowsRecreateStoppedBuilder: false,
        allowsStopRunningBuilder: false,
        allowsOutputReplacement: true
      )
    )
    #expect(try Data(contentsOf: destination) == replacement)
    guard case .rootFilesystemArchive = completion else {
      Issue.record("Expected root filesystem archive completion")
      return
    }
  }

  @Test
  func existingArchiveDriftAfterReviewFailsWithoutClobbering() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let result = try workspace.makeFileResult(
      buildID: buildID,
      kind: .ociArchive,
      bytes: Data("reviewed-output".utf8)
    )
    let destination = workspace.outputRoot.appending(path: "existing.oci.tar")
    try Data("original-reviewed-value".utf8).write(to: destination)
    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let plan = try await service.prepare(
      ImageBuildOutputSelection(kind: .ociArchive, destinationURL: destination)
    )
    defer { Task { await service.discard(plan) } }
    try Data("external-replacement".utf8).write(to: destination, options: .atomic)
    let identity = try await manager.validateArtifact(result)
    let authorization = ImageBuildAuthorization(
      allowsTagReplacement: false,
      allowsRecreateStoppedBuilder: false,
      allowsStopRunningBuilder: false,
      allowsOutputReplacement: true
    )

    do {
      _ = try await service.publish(
        result,
        artifactIdentity: identity,
        plan: plan,
        authorization: authorization
      )
      Issue.record("Expected reviewed destination drift failure")
    } catch let error as ImageBuildOutputError {
      #expect(error == .destinationChanged(destination.path(percentEncoded: false)))
    }

    #expect(try Data(contentsOf: destination) == Data("external-replacement".utf8))
  }

  @Test
  func destinationCreationAfterReviewFailsWithoutClobbering() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let result = try workspace.makeFileResult(
      buildID: buildID,
      kind: .ociArchive,
      bytes: Data("new-output".utf8)
    )
    let destination = workspace.outputRoot.appending(path: "raced.oci.tar")
    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let plan = try await service.prepare(
      ImageBuildOutputSelection(kind: .ociArchive, destinationURL: destination)
    )
    defer { Task { await service.discard(plan) } }
    try Data("external-writer".utf8).write(to: destination)
    let identity = try await manager.validateArtifact(result)

    do {
      _ = try await service.publish(
        result,
        artifactIdentity: identity,
        plan: plan,
        authorization: .none
      )
      Issue.record("Expected destination drift failure")
    } catch let error as ImageBuildOutputError {
      #expect(error == .destinationChanged(destination.path(percentEncoded: false)))
    }

    #expect(try Data(contentsOf: destination) == Data("external-writer".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: workspace.outputRoot,
        includingPropertiesForKeys: nil
      ).map(\.lastPathComponent) == ["raced.oci.tar"]
    )
  }

  @Test
  func publishesVerifiedLocalTreeAndPreservesRelativeSymlinksAndModes() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let source = try workspace.makeLocalSource(buildID: buildID)
    let executable = source.appending(path: "bin/tool")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\necho ready\n".utf8).write(to: executable)
    _ = chmod(executable.path(percentEncoded: false), 0o755)
    let link = source.appending(path: "tool")
    try FileManager.default.createSymbolicLink(
      atPath: link.path(percentEncoded: false),
      withDestinationPath: "bin/tool"
    )

    let result = try workspace.persistDirectoryResult(
      buildID: buildID,
      source: source
    )
    let destination = workspace.outputRoot.appending(
      path: "rootfs",
      directoryHint: .isDirectory
    )
    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let plan = try await service.prepare(
      ImageBuildOutputSelection(
        kind: .rootFilesystemDirectory,
        destinationURL: destination
      )
    )
    defer { Task { await service.discard(plan) } }
    let identity = try await manager.validateArtifact(result)

    let completion = try await service.publish(
      result,
      artifactIdentity: identity,
      plan: plan,
      authorization: .none
    )

    #expect(
      try Data(contentsOf: destination.appending(path: "bin/tool"))
        == Data("#!/bin/sh\necho ready\n".utf8)
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.appending(path: "bin/tool").path(percentEncoded: false)
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: destination.appending(path: "tool").path(percentEncoded: false)
      ) == "bin/tool"
    )
    guard case .rootFilesystemDirectory(_, let byteCount, let entryCount) = completion
    else {
      Issue.record("Expected root filesystem directory completion")
      return
    }
    #expect(byteCount == Int64(Data("#!/bin/sh\necho ready\n".utf8).count + "bin/tool".utf8.count))
    #expect(entryCount == 3)
  }

  @Test
  func directoryArtifactRejectsSpecialFilesAndCleansPrivatePartial() throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let source = try workspace.makeLocalSource(buildID: buildID)
    let fifo = source.appending(path: "blocked.fifo")
    #expect(mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)

    do {
      _ = try PrivateBuildDirectoryStore(
        rootDirectory: workspace.artifactRoot
      ).persist(
        sourceRootDirectory: workspace.sharedRoot,
        sourceDirectoryName: buildID.uuidString.lowercased(),
        buildID: buildID
      )
      Issue.record("Expected special-file rejection")
    } catch let error as PrivateBuildDirectoryStoreError {
      #expect(error == .unsupportedEntry("blocked.fifo"))
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: workspace.artifactRoot
          .appending(path: buildID.uuidString.lowercased())
          .path(percentEncoded: false)
      )
    )
  }

  @Test
  func preCancelledPublicationLeavesDestinationUntouched() async throws {
    let workspace = try OutputTestWorkspace()
    defer { workspace.remove() }

    let buildID = UUID()
    let result = try workspace.makeFileResult(
      buildID: buildID,
      kind: .ociArchive,
      bytes: Data(repeating: 0x41, count: 2 * 1024 * 1024)
    )
    let destination = workspace.outputRoot.appending(path: "cancelled.oci.tar")
    let service = AppleImageBuildOutputService(
      artifactRootDirectory: workspace.artifactRoot
    )
    let manager = AppleImageBuildArtifactManager(
      rootDirectory: workspace.artifactRoot,
      sharedExportRoot: { workspace.sharedRoot }
    )
    let plan = try await service.prepare(
      ImageBuildOutputSelection(kind: .ociArchive, destinationURL: destination)
    )
    defer { Task { await service.discard(plan) } }
    let identity = try await manager.validateArtifact(result)

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.publish(
        result,
        artifactIdentity: identity,
        plan: plan,
        authorization: .none
      )
    }
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: workspace.outputRoot,
        includingPropertiesForKeys: nil
      ).isEmpty
    )
  }
}

private struct OutputTestWorkspace {
  let root: URL
  let sharedRoot: URL
  let artifactRoot: URL
  let outputRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-output-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    sharedRoot = root.appending(path: "shared", directoryHint: .isDirectory)
    artifactRoot = root.appending(path: "artifacts", directoryHint: .isDirectory)
    outputRoot = root.appending(path: "output", directoryHint: .isDirectory)
    for directory in [root, sharedRoot, outputRoot] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      _ = chmod(directory.path(percentEncoded: false), 0o700)
    }
  }

  func makeFileResult(
    buildID: UUID,
    kind: ContainerBuildWorkerArtifactKind,
    bytes: Data
  ) throws -> ContainerBuildWorkerResult {
    let sourceDirectory = sharedRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    _ = chmod(sourceDirectory.path(percentEncoded: false), 0o700)
    try bytes.write(to: sourceDirectory.appending(path: PrivateBuildArtifactStore.archiveName))
    let privateArtifact = try PrivateBuildArtifactStore(
      rootDirectory: artifactRoot
    ).persist(
      sourceRootDirectory: sharedRoot,
      sourceDirectoryName: buildID.uuidString.lowercased(),
      buildID: buildID
    )
    return ContainerBuildWorkerResult(
      buildID: buildID,
      artifact: ContainerBuildWorkerArtifact(
        kind: kind,
        path: privateArtifact.url.path(percentEncoded: false),
        sha256: privateArtifact.sha256,
        byteCount: privateArtifact.byteCount,
        entryCount: nil
      ),
      stagingReference: nil,
      platforms: [.current],
      durationMilliseconds: 10
    )
  }

  func makeLocalSource(buildID: UUID) throws -> URL {
    let sourceDirectory = sharedRoot.appending(
      path: buildID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: sourceDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    _ = chmod(sourceDirectory.path(percentEncoded: false), 0o700)
    let local = sourceDirectory.appending(
      path: PrivateBuildDirectoryStore.directoryName,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: local,
      withIntermediateDirectories: false
    )
    return local
  }

  func persistDirectoryResult(
    buildID: UUID,
    source: URL
  ) throws -> ContainerBuildWorkerResult {
    let privateArtifact = try PrivateBuildDirectoryStore(
      rootDirectory: artifactRoot
    ).persist(
      sourceRootDirectory: sharedRoot,
      sourceDirectoryName: buildID.uuidString.lowercased(),
      buildID: buildID
    )
    return ContainerBuildWorkerResult(
      buildID: buildID,
      artifact: ContainerBuildWorkerArtifact(
        kind: .rootFilesystemDirectory,
        path: privateArtifact.url.path(percentEncoded: false),
        sha256: privateArtifact.sha256,
        byteCount: privateArtifact.byteCount,
        entryCount: privateArtifact.entryCount
      ),
      stagingReference: nil,
      platforms: [.current],
      durationMilliseconds: 10
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
