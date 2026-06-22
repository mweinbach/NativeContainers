import ContainerResource
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Container filesystem export request")
struct ContainerFilesystemExportRequestTests {
  @Test
  func validatesStoppedTargetAndTarDestination() throws {
    let snapshot = makeExportSnapshot(
      id: "api/prod",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let container = AppleRuntimeInventoryService.containerRecord(from: snapshot)
    let destination = URL(filePath: "/tmp/api.rootfs.tar")

    let request = try ContainerFilesystemExportRequest(
      container: container,
      destinationURL: destination
    )

    #expect(request.target == ContainerTerminalTargetIdentity(container: container))
    #expect(request.destinationURL == destination.standardizedFileURL)
    #expect(
      ContainerFilesystemExportRequest.suggestedFileName(containerID: "api/prod")
        == "api-prod.rootfs.tar"
    )
  }

  @Test
  func rejectsRunningContainerAndMisleadingArchiveExtension() throws {
    let running = AppleRuntimeInventoryService.containerRecord(
      from: makeExportSnapshot(
        id: "api",
        status: .running,
        createdAt: Date(timeIntervalSince1970: 42)
      )
    )

    #expect(throws: ContainerFilesystemExportError.containerMustBeStopped("api")) {
      _ = try ContainerFilesystemExportRequest(
        container: running,
        destinationURL: URL(filePath: "/tmp/api.tar")
      )
    }

    let stopped = AppleRuntimeInventoryService.containerRecord(
      from: makeExportSnapshot(
        id: "api",
        status: .stopped,
        createdAt: Date(timeIntervalSince1970: 42)
      )
    )
    #expect(
      throws: ContainerFilesystemExportError.invalidArchiveExtension("api.tgz")
    ) {
      _ = try ContainerFilesystemExportRequest(
        container: stopped,
        destinationURL: URL(filePath: "/tmp/api.tgz")
      )
    }
  }
}

@Suite(.serialized)
struct AppleContainerFilesystemExportServiceTests {
  @Test
  func exportsStoppedIdentityToNewArchiveAndReturnsDigest() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let bytes = Data("pax root filesystem fixture".utf8)
    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ExportTransportStub { archive in
      try bytes.write(to: archive)
    }
    let reader = ScriptedContainerSnapshotReader(snapshots: [snapshot])
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: reader,
      stagingRootDirectory: workspace.stagingRoot
    )
    let destination = workspace.outputRoot.appending(path: "api.rootfs.tar")
    let request = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: destination
    )

    let receipt = try await service.exportFilesystem(request)

    #expect(try Data(contentsOf: destination) == bytes)
    #expect(receipt.target == request.target)
    #expect(receipt.destinationURL == destination.standardizedFileURL)
    #expect(receipt.byteCount == Int64(bytes.count))
    #expect(receipt.sha256 == sha256(bytes))
    #expect(await transport.callCount == 1)
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.path(percentEncoded: false)
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func rejectsRunningOrRecreatedTargetBeforeAppleExport() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let reviewed = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ExportTransportStub { archive in
      try Data("unexpected".utf8).write(to: archive)
    }

    let runningService = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(
        snapshots: [
          makeExportSnapshot(
            id: "api",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 42)
          )
        ]
      ),
      stagingRootDirectory: workspace.stagingRoot
    )
    let runningRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: reviewed),
      destinationURL: workspace.outputRoot.appending(path: "running.tar")
    )
    await #expect(
      throws: ContainerFilesystemExportError.containerMustBeStopped("api")
    ) {
      try await runningService.exportFilesystem(runningRequest)
    }

    let recreatedService = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(
        snapshots: [
          makeExportSnapshot(
            id: "api",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 84)
          )
        ]
      ),
      stagingRootDirectory: workspace.stagingRoot
    )
    let recreatedRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: reviewed),
      destinationURL: workspace.outputRoot.appending(path: "recreated.tar")
    )
    await #expect(
      throws: ContainerFilesystemExportError.containerIdentityChanged("api")
    ) {
      try await recreatedService.exportFilesystem(recreatedRequest)
    }

    #expect(await transport.callCount == 0)
  }

  @Test
  func refusesPublicationWhenIdentityChangesAfterAppleExport() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let reviewed = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let replacement = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 84)
    )
    let transport = ExportTransportStub { archive in
      try Data("exported".utf8).write(to: archive)
    }
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(
        snapshots: [reviewed, replacement]
      ),
      stagingRootDirectory: workspace.stagingRoot
    )
    let destination = workspace.outputRoot.appending(path: "identity-drift.tar")
    let request = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: reviewed),
      destinationURL: destination
    )

    await #expect(
      throws: ContainerFilesystemExportError.containerIdentityChanged("api")
    ) {
      try await service.exportFilesystem(request)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
  }

  @Test
  func neverReplacesExistingOrRacedDestination() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let existing = workspace.outputRoot.appending(path: "existing.tar")
    let original = Data("keep me".utf8)
    try original.write(to: existing)

    let transport = ExportTransportStub { archive in
      try Data("exported".utf8).write(to: archive)
    }
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let existingRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: existing
    )
    await #expect(
      throws: ContainerFilesystemExportError.destinationMustBeNew(
        existing.path(percentEncoded: false)
      )
    ) {
      try await service.exportFilesystem(existingRequest)
    }
    #expect(try Data(contentsOf: existing) == original)
    #expect(await transport.callCount == 0)

    let raced = workspace.outputRoot.appending(path: "raced.tar")
    let external = Data("external writer".utf8)
    let racingTransport = ExportTransportStub { archive in
      try Data("exported".utf8).write(to: archive)
      try external.write(to: raced)
    }
    let racingService = AppleContainerFilesystemExportService(
      transport: racingTransport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let racedRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: raced
    )
    await #expect(
      throws: ContainerFilesystemExportError.destinationChanged(
        raced.path(percentEncoded: false)
      )
    ) {
      try await racingService.exportFilesystem(racedRequest)
    }
    #expect(try Data(contentsOf: raced) == external)
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
  }

  @Test
  func rejectsSymlinkDestinationAndUnsafeParent() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ExportTransportStub { archive in
      try Data("unexpected".utf8).write(to: archive)
    }

    let symlinkTarget = workspace.outputRoot.appending(path: "target.tar")
    try Data("target".utf8).write(to: symlinkTarget)
    let symlink = workspace.outputRoot.appending(path: "link.tar")
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: symlinkTarget
    )
    let symlinkService = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let symlinkRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: symlink
    )
    await #expect(
      throws: ContainerFilesystemExportError.destinationChanged(
        symlink.path(percentEncoded: false)
      )
    ) {
      try await symlinkService.exportFilesystem(symlinkRequest)
    }

    #expect(chmod(workspace.outputRoot.path(percentEncoded: false), 0o777) == 0)
    let unsafe = workspace.outputRoot.appending(path: "unsafe.tar")
    let unsafeService = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let unsafeRequest = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: unsafe
    )
    await #expect(
      throws: ContainerFilesystemExportError.unsafeDestinationParent(
        workspace.outputRoot.path(percentEncoded: false)
      )
    ) {
      try await unsafeService.exportFilesystem(unsafeRequest)
    }
    #expect(await transport.callCount == 0)
  }

  @Test
  func transportFailureCleansPrivateStagingAndLeavesNoDestination() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ExportTransportStub { _ in
      throw ExportFixtureError.failed
    }
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let destination = workspace.outputRoot.appending(path: "failed.tar")
    let request = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: destination
    )

    await #expect(
      throws: ContainerFilesystemExportError.exportFailed("fixture failure")
    ) {
      try await service.exportFilesystem(request)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
  }

  @Test
  func cancellationWaitsForAcceptedAppleExportBeforeCleaningStaging() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ControlledExportTransport(bytes: Data("settled".utf8))
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let destination = workspace.outputRoot.appending(path: "cancelled.tar")
    let request = try ContainerFilesystemExportRequest(
      container: AppleRuntimeInventoryService.containerRecord(from: snapshot),
      destinationURL: destination
    )
    let operation = Task {
      try await service.exportFilesystem(request)
    }

    while !(await transport.hasStarted) {
      await Task.yield()
    }
    operation.cancel()
    #expect(!(try stagingEntries(workspace.stagingRoot).isEmpty))
    await transport.finish()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
  }

  @Test
  func recoveryPreservesLockedOperationAndRemovesItAfterRelease() async throws {
    let workspace = try ExportTestWorkspace()
    defer { workspace.remove() }
    try FileManager.default.createDirectory(
      at: workspace.stagingRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(workspace.stagingRoot.path(percentEncoded: false), 0o700) == 0)

    let abandoned = workspace.stagingRoot.appending(
      path: ".nativecontainers-export-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: abandoned,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(abandoned.path(percentEncoded: false), 0o700) == 0)
    let lockURL = abandoned.appending(path: ".lock")
    let activeLease = try #require(try AdvisoryFileLock.acquire(at: lockURL))

    let snapshot = makeExportSnapshot(
      id: "api",
      status: .stopped,
      createdAt: Date(timeIntervalSince1970: 42)
    )
    let transport = ExportTransportStub { archive in
      try Data("exported".utf8).write(to: archive)
    }
    let service = AppleContainerFilesystemExportService(
      transport: transport,
      snapshotReader: ScriptedContainerSnapshotReader(snapshots: [snapshot]),
      stagingRootDirectory: workspace.stagingRoot
    )
    let container = AppleRuntimeInventoryService.containerRecord(from: snapshot)

    _ = try await service.exportFilesystem(
      ContainerFilesystemExportRequest(
        container: container,
        destinationURL: workspace.outputRoot.appending(path: "first.tar")
      )
    )
    #expect(FileManager.default.fileExists(atPath: abandoned.path(percentEncoded: false)))

    activeLease.release()
    _ = try await service.exportFilesystem(
      ContainerFilesystemExportRequest(
        container: container,
        destinationURL: workspace.outputRoot.appending(path: "second.tar")
      )
    )
    #expect(!FileManager.default.fileExists(atPath: abandoned.path(percentEncoded: false)))
    #expect(try stagingEntries(workspace.stagingRoot).isEmpty)
  }
}

private actor ExportTransportStub: ContainerFilesystemExportTransport {
  private let operation: @Sendable (URL) async throws -> Void
  private(set) var callCount = 0

  init(operation: @escaping @Sendable (URL) async throws -> Void) {
    self.operation = operation
  }

  func export(id: String, archive: URL) async throws {
    callCount += 1
    try await operation(archive)
  }
}

private actor ControlledExportTransport: ContainerFilesystemExportTransport {
  private let bytes: Data
  private var continuation: CheckedContinuation<Void, Never>?
  private var canFinish = false
  private(set) var hasStarted = false

  init(bytes: Data) {
    self.bytes = bytes
  }

  func export(id: String, archive: URL) async throws {
    hasStarted = true
    if !canFinish {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }
    try bytes.write(to: archive)
  }

  func finish() {
    canFinish = true
    continuation?.resume()
    continuation = nil
  }
}

private actor ScriptedContainerSnapshotReader: ContainerSnapshotReading {
  private var snapshots: [ContainerSnapshot]

  init(snapshots: [ContainerSnapshot]) {
    self.snapshots = snapshots
  }

  func list() -> [ContainerSnapshot] {
    snapshots
  }

  func get(id: String) throws -> ContainerSnapshot {
    guard let snapshot = snapshots.first else {
      throw ExportFixtureError.failed
    }
    if snapshots.count > 1 {
      snapshots.removeFirst()
    }
    return snapshot
  }
}

private enum ExportFixtureError: LocalizedError {
  case failed

  var errorDescription: String? {
    "fixture failure"
  }
}

private struct ExportTestWorkspace {
  let root: URL
  let outputRoot: URL
  let stagingRoot: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "nativecontainers-filesystem-export-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    outputRoot = root.appending(path: "output", directoryHint: .isDirectory)
    stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(
      at: outputRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(root.path(percentEncoded: false), 0o700) == 0)
    #expect(chmod(outputRoot.path(percentEncoded: false), 0o700) == 0)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func makeExportSnapshot(
  id: String,
  status: RuntimeStatus,
  createdAt: Date
) -> ContainerSnapshot {
  let descriptor = Descriptor(
    mediaType: "application/vnd.oci.image.index.v1+json",
    digest: "sha256:" + String(repeating: "a", count: 64),
    size: 1
  )
  let image = ImageDescription(
    reference: "example.invalid/api:latest",
    descriptor: descriptor
  )
  let process = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: [],
    environment: []
  )
  var configuration = ContainerConfiguration(
    id: id,
    image: image,
    process: process
  )
  configuration.creationDate = createdAt
  return ContainerSnapshot(
    configuration: configuration,
    status: status,
    networks: []
  )
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stagingEntries(_ root: URL) throws -> [String] {
  guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
    return []
  }
  return try FileManager.default.contentsOfDirectory(
    atPath: root.path(percentEncoded: false)
  )
}
