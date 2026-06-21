import Darwin
import Foundation

@testable import NativeContainers

struct DiskImageMigrationFixture {
  let rootURL: URL
  let bundleURL: URL
  let installedURL: URL
  let sourceURL: URL
  let destinationURL: URL
  var manifest: VirtualMachineManifest

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    bundleURL =
      rootURL
      .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
      .appendingPathExtension(VirtualMachineLibrary.bundleExtension)
    installedURL = bundleURL.appending(
      path: "Installed",
      directoryHint: .isDirectory
    )
    sourceURL = installedURL.appending(path: "Disk.img")
    destinationURL = installedURL.appending(path: "Disk.asif")
    try FileManager.default.createDirectory(
      at: installedURL,
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x5A, count: 8_192).write(to: sourceURL)
    let auxiliaryURL = installedURL.appending(path: "AuxiliaryStorage")
    let hardwareURL = bundleURL.appending(path: "HardwareModel")
    let identifierURL = bundleURL.appending(path: "MachineIdentifier")
    try Data("aux".utf8).write(to: auxiliaryURL)
    try Data("hardware".utf8).write(to: hardwareURL)
    try Data("identifier".utf8).write(to: identifierURL)

    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Migration Test",
      guest: .macOS,
      installState: .stopped,
      resources: resources,
      diskImagePath: "Installed/Disk.img"
    )
    manifest.auxiliaryStoragePath = "Installed/AuxiliaryStorage"
    manifest.hardwareModelPath = "HardwareModel"
    manifest.machineIdentifierPath = "MachineIdentifier"
    self.manifest = manifest
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

@MainActor
final class MigrationStoreDouble:
  VirtualMachineDiskImageMigrationStoring
{
  private(set) var currentManifest: VirtualMachineManifest
  private(set) var commits: [VirtualMachineDiskImageMigrationCommit] = []
  private(set) var acquireCount = 0
  private let bundleURL: URL

  init(manifest: VirtualMachineManifest, bundleURL: URL) {
    currentManifest = manifest
    self.bundleURL = bundleURL
  }

  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
  {
    VirtualMachineStorageInventory(
      rootURL: bundleURL.deletingLastPathComponent(),
      targets: [
        VirtualMachineStorageTarget(
          manifest: currentManifest,
          bundleURL: bundleURL
        )
      ]
    )
  }

  func acquireDiskImageReplacementRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease {
    acquireCount += 1
    guard id == currentManifest.id else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let diskURL = bundleURL.appending(path: currentManifest.diskImagePath)
    let machine = ResolvedMacVirtualMachine(
      manifest: currentManifest,
      bundleURL: bundleURL,
      diskImageURL: diskURL,
      auxiliaryStorageURL: bundleURL.appending(
        path: currentManifest.auxiliaryStoragePath!
      ),
      hardwareModelURL: bundleURL.appending(
        path: currentManifest.hardwareModelPath!
      ),
      machineIdentifierURL: bundleURL.appending(
        path: currentManifest.machineIdentifierPath!
      )
    )
    return MacVirtualMachineRuntimeLease(
      machine: machine,
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func commitDiskImageReplacement(
    _ commit: VirtualMachineDiskImageMigrationCommit,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest {
    guard lease.target.machineID == currentManifest.id,
      currentManifest.diskImagePath == commit.sourcePath,
      currentManifest.effectiveDiskImageFormat == commit.sourceFormat
    else {
      throw MacVirtualMachineRuntimeError.staleTarget(lease.target)
    }
    commits.append(commit)
    currentManifest.markDiskImageReplaced(
      to: commit.destinationPath,
      format: commit.destinationFormat
    )
    return currentManifest
  }
}

@MainActor
struct SavedStateInspectorDouble:
  MacVirtualMachineSavedStateInspecting
{
  let status: MacVirtualMachineSavedStateStatus

  func inspect(
    for _: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    status
  }
}

struct StubDiskImageInspector: VirtualMachineDiskImageInspecting {
  let rawLogicalBytes: UInt64
  let asifLogicalBytes: UInt64
  var asifBlockSizeBytes: UInt64 = 512

  func inspect(
    at _: URL,
    expectedFormat: VirtualMachineDiskImageFormat
  ) throws -> VirtualMachineDiskImageDescriptor {
    VirtualMachineDiskImageDescriptor(
      format: expectedFormat,
      logicalBytes: expectedFormat == .raw
        ? rawLogicalBytes : asifLogicalBytes,
      blockSizeBytes: expectedFormat == .raw ? 512 : asifBlockSizeBytes
    )
  }
}

enum TestDiskMigrationError: LocalizedError, Equatable {
  case expected

  var errorDescription: String? {
    "expected conversion failure"
  }
}

actor RecordingMigrationConverter:
  VirtualMachineDiskImageConverting
{
  enum Behavior: Equatable, Sendable {
    case succeed
    case failAfterWriting
    case terminationUnconfirmed
    case killSignalFailed
  }

  private let behavior: Behavior
  private(set) var callCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func convert(
    sourceURL _: URL,
    destinationURL: URL,
    to _: VirtualMachineDiskImageFormat
  ) async throws {
    callCount += 1
    try Data("converted-asif".utf8).write(to: destinationURL)
    if behavior == .failAfterWriting {
      throw TestDiskMigrationError.expected
    }
    if behavior == .terminationUnconfirmed {
      throw HostProcessError.didNotExitAfterKill
    }
    if behavior == .killSignalFailed {
      throw HostProcessError.signalFailed(signal: SIGKILL, code: EPERM)
    }
  }
}

struct StubHostBootSession: HostBootSessionIdentifying {
  let identifier: String

  func currentBootIdentifier() throws -> String {
    identifier
  }
}

@MainActor
final class RecoveryMigrationStoreDouble:
  VirtualMachineDiskImageMigrationStoring
{
  private let fixtures: [DiskImageMigrationFixture]

  init(fixtures: [DiskImageMigrationFixture]) {
    self.fixtures = fixtures
  }

  func loadVirtualMachineStorageInventory() async throws
    -> VirtualMachineStorageInventory
  {
    VirtualMachineStorageInventory(
      rootURL: fixtures[0].rootURL,
      targets: fixtures.map {
        VirtualMachineStorageTarget(
          manifest: $0.manifest,
          bundleURL: $0.bundleURL
        )
      }
    )
  }

  func acquireDiskImageReplacementRuntime(
    id: UUID
  ) async throws -> MacVirtualMachineRuntimeLease {
    guard let fixture = fixtures.first(where: { $0.manifest.id == id }) else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    let manifest = fixture.manifest
    return MacVirtualMachineRuntimeLease(
      machine: ResolvedMacVirtualMachine(
        manifest: manifest,
        bundleURL: fixture.bundleURL,
        diskImageURL: fixture.bundleURL.appending(path: manifest.diskImagePath),
        auxiliaryStorageURL: fixture.bundleURL.appending(
          path: manifest.auxiliaryStoragePath!
        ),
        hardwareModelURL: fixture.bundleURL.appending(
          path: manifest.hardwareModelPath!
        ),
        machineIdentifierURL: fixture.bundleURL.appending(
          path: manifest.machineIdentifierPath!
        )
      ),
      target: MacVirtualMachineRuntimeTarget(
        machineID: id,
        generation: UUID()
      ),
      release: {}
    )
  }

  func commitDiskImageReplacement(
    _: VirtualMachineDiskImageMigrationCommit,
    for _: MacVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineManifest {
    throw TestDiskMigrationError.expected
  }
}

actor BlockingMigrationConverter:
  VirtualMachineDiskImageConverting
{
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func convert(
    sourceURL _: URL,
    destinationURL: URL,
    to _: VirtualMachineDiskImageFormat
  ) async throws {
    try Data("partial-asif".utf8).write(to: destinationURL)
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
    try Task.checkCancellation()
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

@MainActor
func makeDiskImageMigrationService(
  store: MigrationStoreDouble,
  converter: any VirtualMachineDiskImageConverting,
  savedState: MacVirtualMachineSavedStateStatus,
  logicalBytes: UInt64,
  asifLogicalBytes: UInt64? = nil,
  asifBlockSizeBytes: UInt64 = 512,
  hostBootSession: any HostBootSessionIdentifying =
    DarwinHostBootSessionIdentifier()
) -> VirtualMachineDiskImageMigrationService {
  VirtualMachineDiskImageMigrationService(
    coordinator: makeDiskImageReplacementCoordinator(
      store: store,
      converter: converter,
      savedState: savedState,
      logicalBytes: logicalBytes,
      asifLogicalBytes: asifLogicalBytes,
      asifBlockSizeBytes: asifBlockSizeBytes,
      hostBootSession: hostBootSession
    )
  )
}

@MainActor
func makeDiskImageReplacementCoordinator(
  store: any VirtualMachineDiskImageReplacementStoring,
  converter: any VirtualMachineDiskImageConverting,
  savedState: MacVirtualMachineSavedStateStatus,
  logicalBytes: UInt64,
  asifLogicalBytes: UInt64? = nil,
  asifBlockSizeBytes: UInt64 = 512,
  hostBootSession: any HostBootSessionIdentifying =
    DarwinHostBootSessionIdentifier()
) -> VirtualMachineDiskImageReplacementCoordinator {
  VirtualMachineDiskImageReplacementCoordinator(
    store: store,
    savedStates: SavedStateInspectorDouble(status: savedState),
    converter: converter,
    imageInspector: StubDiskImageInspector(
      rawLogicalBytes: logicalBytes,
      asifLogicalBytes: asifLogicalBytes ?? logicalBytes,
      asifBlockSizeBytes: asifBlockSizeBytes
    ),
    hostBootSession: hostBootSession
  )
}

func diskImageMigrationPartials(in directory: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: nil
  ).filter {
    $0.lastPathComponent.hasPrefix(".DiskImageMigration-")
  }
}
