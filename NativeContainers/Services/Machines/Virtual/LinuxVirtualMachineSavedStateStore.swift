import CryptoKit
import Darwin
import Foundation

protocol LinuxVirtualMachineConfigurationFingerprinting: Sendable {
  func fingerprint(for machine: ResolvedLinuxVirtualMachine) throws -> String
}

protocol LinuxVirtualMachineSavedStateStoring: Sendable {
  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus
  func beginSave(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateTransaction
  func commitSave(
    _ transaction: LinuxVirtualMachineSavedStateTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary
  func abortSave(
    _ transaction: LinuxVirtualMachineSavedStateTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async
  func beginRestore(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateRestoreTransaction
  func finishRestore(
    _ transaction: LinuxVirtualMachineSavedStateRestoreTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws
  func discard(for lease: LinuxVirtualMachineRuntimeLease) async throws
}

struct LinuxVirtualMachineConfigurationFingerprinter:
  LinuxVirtualMachineConfigurationFingerprinting
{
  private static let runtimeConfigurationVersion = 2

  private struct FileIdentity: Codable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
  }

  private struct Payload: Codable {
    let runtimeConfigurationVersion: Int
    let descriptor: LinuxVirtualMachineConfigurationDescriptor
    let machineIdentifierSHA256: String
    let diskIdentity: FileIdentity
    let diskSnapshotLayerIdentities: [FileIdentity]
    let efiVariableStoreIdentity: FileIdentity
    let installationMediaIdentity: FileIdentity?
  }

  private let descriptorService: any LinuxVirtualMachineConfigurationDescribing

  init(
    descriptorService: any LinuxVirtualMachineConfigurationDescribing =
      LinuxVirtualMachineConfigurationDescriptorService()
  ) {
    self.descriptorService = descriptorService
  }

  func fingerprint(for machine: ResolvedLinuxVirtualMachine) throws -> String {
    let payload = Payload(
      runtimeConfigurationVersion: Self.runtimeConfigurationVersion,
      descriptor: try descriptorService.descriptor(for: machine),
      machineIdentifierSHA256: try digest(of: machine.machineIdentifierURL),
      diskIdentity: try identity(of: machine.diskImageURL),
      diskSnapshotLayerIdentities: try machine.diskSnapshotLayerURLs.map(
        identity(of:)
      ),
      efiVariableStoreIdentity: try identity(
        of: machine.efiVariableStoreURL
      ),
      installationMediaIdentity: try machine.installationMediaURL.map(
        identity(of:)
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(payload)).hexString
  }

  private func digest(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).hexString
  }

  private func identity(of url: URL) throws -> FileIdentity {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw LinuxVirtualMachineSavedStateError.invalidBundle(
        "the configuration artifact \(url.lastPathComponent) is missing or unsafe"
      )
    }
    return FileIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      size: Int64(metadata.st_size),
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
    )
  }
}

struct LinuxVirtualMachineSavedStateStore:
  LinuxVirtualMachineSavedStateStoring
{
  static let directoryName = VirtualMachineSavedStateStore.directoryName
  static let stateFilename = VirtualMachineSavedStateStore.stateFilename
  static let metadataFilename = VirtualMachineSavedStateStore.metadataFilename
  static let stagingPrefix = VirtualMachineSavedStateStore.stagingPrefix
  static let stagingSuffix = VirtualMachineSavedStateStore.stagingSuffix
  static let restoringSuffix = VirtualMachineSavedStateStore.restoringSuffix
  static let discardingSuffix = VirtualMachineSavedStateStore.discardingSuffix

  private let store: VirtualMachineSavedStateStore
  private let fingerprinter: any LinuxVirtualMachineConfigurationFingerprinting

  init(
    fingerprinter: any LinuxVirtualMachineConfigurationFingerprinting =
      LinuxVirtualMachineConfigurationFingerprinter(),
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector()
  ) {
    store = VirtualMachineSavedStateStore(
      artifactInspector: artifactInspector
    )
    self.fingerprinter = fingerprinter
  }

  func inspect(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateStatus {
    try await store.inspect(for: context(for: lease))
  }

  func beginSave(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateTransaction {
    try await store.beginSave(for: context(for: lease))
  }

  func commitSave(
    _ transaction: LinuxVirtualMachineSavedStateTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateSummary {
    try await store.commitSave(transaction, for: context(for: lease))
  }

  func abortSave(
    _ transaction: LinuxVirtualMachineSavedStateTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async {
    await store.abortSave(transaction, for: context(for: lease))
  }

  func beginRestore(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> LinuxVirtualMachineSavedStateRestoreTransaction {
    try await store.beginRestore(for: context(for: lease))
  }

  func finishRestore(
    _ transaction: LinuxVirtualMachineSavedStateRestoreTransaction,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws {
    try await store.finishRestore(transaction, for: context(for: lease))
  }

  func discard(for lease: LinuxVirtualMachineRuntimeLease) async throws {
    try await store.discard(for: context(for: lease))
  }

  func prepareSavedStateReclamation(
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> VirtualMachineSavedStateReclamationCandidate? {
    try await store.prepareSavedStateReclamation(for: context(for: lease))
  }

  func reclaimSavedState(
    _ candidate: VirtualMachineSavedStateReclamationCandidate,
    for lease: LinuxVirtualMachineRuntimeLease
  ) async throws -> Bool {
    try await store.reclaimSavedState(candidate, for: context(for: lease))
  }

  private func context(
    for lease: LinuxVirtualMachineRuntimeLease
  ) -> VirtualMachineSavedStateContext {
    let fingerprinter = fingerprinter
    let machine = lease.machine
    return VirtualMachineSavedStateContext(
      target: lease.target,
      bundleURL: machine.bundleURL,
      machineName: machine.manifest.name,
      borrow: { try lease.borrow() },
      fingerprint: { try fingerprinter.fingerprint(for: machine) }
    )
  }
}
