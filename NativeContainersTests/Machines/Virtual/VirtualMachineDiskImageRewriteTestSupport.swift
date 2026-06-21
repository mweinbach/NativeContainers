import Foundation
import Testing

@testable import NativeContainers

struct RewriteFixture {
  let rootURL: URL
  let bundleURL: URL
  let installedURL: URL
  let sourceURL: URL
  let sourceMarker = Data("source-asif".utf8)
  let manifest: VirtualMachineManifest

  init(format: VirtualMachineDiskImageFormat) throws {
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
    let diskName = format == .asif ? "Disk.asif" : "Disk.img"
    sourceURL = installedURL.appending(path: diskName)
    try FileManager.default.createDirectory(
      at: installedURL,
      withIntermediateDirectories: true
    )
    try sourceMarker.write(to: sourceURL)
    try Data("aux".utf8).write(
      to: installedURL.appending(path: "AuxiliaryStorage")
    )
    try Data("hardware".utf8).write(
      to: bundleURL.appending(path: "HardwareModel")
    )
    try Data("identifier".utf8).write(
      to: bundleURL.appending(path: "MachineIdentifier")
    )

    let resources = try VirtualMachineResources(
      cpuCount: 4,
      memoryBytes: 4 * VirtualMachineResources.bytesPerGiB,
      diskBytes: 8 * VirtualMachineResources.bytesPerGiB
    )
    var manifest = try VirtualMachineManifest(
      name: "Rewrite Test",
      guest: .macOS,
      installState: .stopped,
      resources: resources,
      diskImagePath: "Installed/\(diskName)",
      diskImageFormat: format
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
final class RewriteStoreDouble:
  VirtualMachineDiskImageReplacementStoring
{
  private(set) var currentManifest: VirtualMachineManifest
  private(set) var commits: [VirtualMachineDiskImageReplacementCommit] = []
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
    guard id == currentManifest.id else {
      throw VirtualMachineModelError.virtualMachineNotFound(id)
    }
    return MacVirtualMachineRuntimeLease(
      machine: ResolvedMacVirtualMachine(
        manifest: currentManifest,
        bundleURL: bundleURL,
        diskImageURL: bundleURL.appending(path: currentManifest.diskImagePath),
        auxiliaryStorageURL: bundleURL.appending(
          path: currentManifest.auxiliaryStoragePath!
        ),
        hardwareModelURL: bundleURL.appending(
          path: currentManifest.hardwareModelPath!
        ),
        machineIdentifierURL: bundleURL.appending(
          path: currentManifest.machineIdentifierPath!
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
    _ commit: VirtualMachineDiskImageReplacementCommit,
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

struct RewriteSavedStateInspector:
  MacVirtualMachineSavedStateInspecting
{
  let status: MacVirtualMachineSavedStateStatus

  func inspect(
    for _: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus {
    status
  }
}

struct RewriteDiskImageInspector: VirtualMachineDiskImageInspecting {
  let sourceURL: URL
  let logicalBytes: UInt64
  let sourceLayerType: VirtualMachineDiskImageLayerType?
  let candidateBlockSizeBytes: UInt64

  func inspect(
    at url: URL,
    expectedFormat: VirtualMachineDiskImageFormat
  ) throws -> VirtualMachineDiskImageDescriptor {
    let isSource = url.standardizedFileURL == sourceURL.standardizedFileURL
    return VirtualMachineDiskImageDescriptor(
      format: expectedFormat,
      logicalBytes: logicalBytes,
      blockSizeBytes: isSource ? 512 : candidateBlockSizeBytes,
      layerType: isSource ? sourceLayerType : nil
    )
  }
}

struct RewriteArtifactInspector:
  VirtualMachineStorageArtifactInspecting
{
  let sourceMarker: Data
  let candidateMarker: Data
  let sourceAllocatedBytes: UInt64
  let candidateAllocatedBytes: UInt64
  private let base = FileVirtualMachineStorageArtifactInspector()

  func inspect(at url: URL) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try base.inspect(at: url)
    let data = try Data(contentsOf: url)
    let allocatedBytes =
      data == sourceMarker ? sourceAllocatedBytes : candidateAllocatedBytes
    return VirtualMachineStorageArtifactIdentity(
      device: identity.device,
      inode: identity.inode,
      fileType: identity.fileType,
      ownerUserID: identity.ownerUserID,
      linkCount: identity.linkCount,
      logicalBytes: identity.logicalBytes,
      allocatedBytes: allocatedBytes,
      entryCount: identity.entryCount,
      modificationSeconds: identity.modificationSeconds,
      modificationNanoseconds: identity.modificationNanoseconds,
      statusChangeSeconds: identity.statusChangeSeconds,
      statusChangeNanoseconds: identity.statusChangeNanoseconds,
      treeFingerprint: identity.treeFingerprint
    )
  }
}

actor RewriteConverter: VirtualMachineDiskImageConverting {
  static let candidateMarker = Data("rewritten-asif".utf8)

  enum Behavior: Sendable {
    case succeed
    case failAfterWriting
  }

  private let behavior: Behavior
  private(set) var callCount = 0

  init(behavior: Behavior = .succeed) {
    self.behavior = behavior
  }

  func convert(
    sourceURL _: URL,
    destinationURL: URL,
    to format: VirtualMachineDiskImageFormat
  ) async throws {
    #expect(format == .asif)
    callCount += 1
    try Self.candidateMarker.write(to: destinationURL)
    if behavior == .failAfterWriting {
      throw RewriteTestError.expected
    }
  }
}

enum RewriteTestError: LocalizedError {
  case expected

  var errorDescription: String? {
    "expected rewrite failure"
  }
}
