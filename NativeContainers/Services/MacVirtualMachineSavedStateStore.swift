import CryptoKit
import Darwin
import Foundation

protocol MacVirtualMachineConfigurationFingerprinting: Sendable {
  func fingerprint(for machine: ResolvedMacVirtualMachine) throws -> String
}

protocol MacVirtualMachineSavedStateStoring: Sendable {
  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateStatus
  func beginSave(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateTransaction
  func commitSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateSummary
  func abortSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) async
  func beginRestore(
    for lease: MacVirtualMachineRuntimeLease
  ) async throws -> MacVirtualMachineSavedStateRestoreTransaction
  func finishRestore(
    _ transaction: MacVirtualMachineSavedStateRestoreTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) async throws
  func discard(for lease: MacVirtualMachineRuntimeLease) async throws
}

struct MacVirtualMachineConfigurationFingerprinter:
  MacVirtualMachineConfigurationFingerprinting
{
  private struct FileIdentity: Codable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
  }

  private struct Payload: Codable {
    let descriptor: MacVirtualMachineConfigurationDescriptor
    let hardwareModelSHA256: String
    let machineIdentifierSHA256: String
    let diskIdentity: FileIdentity
    let auxiliaryStorageIdentity: FileIdentity
  }

  private let descriptorService: any MacVirtualMachineConfigurationDescribing

  init(
    descriptorService: any MacVirtualMachineConfigurationDescribing =
      MacVirtualMachineConfigurationDescriptorService()
  ) {
    self.descriptorService = descriptorService
  }

  func fingerprint(for machine: ResolvedMacVirtualMachine) throws -> String {
    let payload = Payload(
      descriptor: try descriptorService.descriptor(for: machine),
      hardwareModelSHA256: try digest(of: machine.hardwareModelURL),
      machineIdentifierSHA256: try digest(of: machine.machineIdentifierURL),
      diskIdentity: try identity(of: machine.diskImageURL),
      auxiliaryStorageIdentity: try identity(of: machine.auxiliaryStorageURL)
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
      throw MacVirtualMachineSavedStateError.invalidBundle(
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

actor MacVirtualMachineSavedStateStore: MacVirtualMachineSavedStateStoring {
  static let directoryName = "SavedState"
  static let stateFilename = "Machine.vzvmsave"
  static let metadataFilename = "metadata.json"
  static let stagingPrefix = ".SavedState-"
  static let stagingSuffix = ".partial"
  static let restoringSuffix = ".restoring"
  static let discardingSuffix = ".discarding"

  private struct ActiveSave {
    let transaction: MacVirtualMachineSavedStateTransaction
    let borrow: MacVirtualMachineRuntimeLeaseBorrow
  }

  private struct ActiveRestore {
    let transaction: MacVirtualMachineSavedStateRestoreTransaction
    let borrow: MacVirtualMachineRuntimeLeaseBorrow
  }

  private let fileManager: FileManager
  private let fingerprinter: any MacVirtualMachineConfigurationFingerprinting
  private var activeSaves: [UUID: ActiveSave] = [:]
  private var activeRestores: [UUID: ActiveRestore] = [:]

  init(
    fileManager: FileManager = .default,
    fingerprinter: any MacVirtualMachineConfigurationFingerprinting =
      MacVirtualMachineConfigurationFingerprinter()
  ) {
    self.fileManager = fileManager
    self.fingerprinter = fingerprinter
  }

  func inspect(
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSavedStateStatus {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: lease.target.machineID)
    do {
      guard let artifact = try validatedArtifact(for: lease) else { return .none }
      return .available(artifact.summary)
    } catch {
      return .incompatible(error.localizedDescription)
    }
  }

  func beginSave(
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSavedStateTransaction {
    let borrow = try lease.borrow()
    do {
      try ensureNoActiveTransaction(for: lease.target.machineID)
      try recover(in: lease.machine.bundleURL)
      guard
        !fileManager.fileExists(
          atPath: savedStateDirectory(in: lease.machine.bundleURL).path
        )
      else {
        throw MacVirtualMachineSavedStateError.checkpointAlreadyExists(
          lease.target.machineID
        )
      }

      let operationID = UUID()
      let stagingDirectory = lease.machine.bundleURL.appending(
        path: Self.transactionName(
          operationID: operationID,
          suffix: Self.stagingSuffix
        ),
        directoryHint: .isDirectory
      )
      guard !fileManager.fileExists(atPath: stagingDirectory.path) else {
        throw MacVirtualMachineSavedStateError.invalidBundle(
          "a saved-state staging directory already exists"
        )
      }
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try syncDirectory(at: lease.machine.bundleURL)

      let transaction = MacVirtualMachineSavedStateTransaction(
        operationID: operationID,
        target: lease.target,
        stagingDirectoryURL: stagingDirectory,
        stateURL: stagingDirectory.appending(path: Self.stateFilename)
      )
      activeSaves[lease.target.machineID] = ActiveSave(
        transaction: transaction,
        borrow: borrow
      )
      return transaction
    } catch {
      borrow.release()
      throw error
    }
  }

  func commitSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSavedStateSummary {
    let active = try activeSave(transaction, for: lease)
    try requireDirectory(transaction.stagingDirectoryURL)
    let stateSize = try requireRegularFile(transaction.stateURL, nonempty: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: transaction.stateURL.path
    )
    try fullySyncFile(at: transaction.stateURL)

    let summary = MacVirtualMachineSavedStateSummary(
      createdAt: Date(),
      stateSizeBytes: stateSize
    )
    let metadata = MacVirtualMachineSavedStateMetadata(
      schemaVersion: MacVirtualMachineSavedStateMetadata.currentSchemaVersion,
      machineID: lease.target.machineID,
      configurationFingerprint: try fingerprinter.fingerprint(for: lease.machine),
      stateFilename: Self.stateFilename,
      createdAt: summary.createdAt,
      stateSizeBytes: summary.stateSizeBytes,
      hostOperatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
    let metadataURL = transaction.stagingDirectoryURL.appending(
      path: Self.metadataFilename
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: metadataURL.path
    )
    try fullySyncFile(at: metadataURL)
    try syncDirectory(at: transaction.stagingDirectoryURL)

    let finalDirectory = savedStateDirectory(in: lease.machine.bundleURL)
    guard !fileManager.fileExists(atPath: finalDirectory.path) else {
      throw MacVirtualMachineSavedStateError.checkpointAlreadyExists(
        lease.target.machineID
      )
    }
    try fileManager.moveItem(at: transaction.stagingDirectoryURL, to: finalDirectory)
    try syncDirectory(at: lease.machine.bundleURL)

    activeSaves[lease.target.machineID] = nil
    active.borrow.release()
    return summary
  }

  func abortSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) {
    guard let active = try? activeSave(transaction, for: lease) else { return }
    activeSaves[lease.target.machineID] = nil
    defer { active.borrow.release() }
    guard fileManager.fileExists(atPath: transaction.stagingDirectoryURL.path),
      (try? requireDirectory(transaction.stagingDirectoryURL)) != nil
    else { return }
    try? fileManager.removeItem(at: transaction.stagingDirectoryURL)
    try? syncDirectory(at: lease.machine.bundleURL)
  }

  func beginRestore(
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSavedStateRestoreTransaction {
    let borrow = try lease.borrow()
    do {
      try ensureNoActiveTransaction(for: lease.target.machineID)
      guard let artifact = try validatedArtifact(for: lease) else {
        throw MacVirtualMachineSavedStateError.missing(lease.target.machineID)
      }

      let operationID = UUID()
      let finalDirectory = savedStateDirectory(in: lease.machine.bundleURL)
      let consumingDirectory = lease.machine.bundleURL.appending(
        path: Self.transactionName(
          operationID: operationID,
          suffix: Self.restoringSuffix
        ),
        directoryHint: .isDirectory
      )
      try fileManager.moveItem(at: finalDirectory, to: consumingDirectory)
      try syncDirectory(at: lease.machine.bundleURL)

      let transaction = MacVirtualMachineSavedStateRestoreTransaction(
        operationID: operationID,
        target: lease.target,
        consumingDirectoryURL: consumingDirectory,
        artifact: MacVirtualMachineSavedStateArtifact(
          stateURL: consumingDirectory.appending(path: Self.stateFilename),
          summary: artifact.summary,
          configurationFingerprint: artifact.configurationFingerprint
        )
      )
      activeRestores[lease.target.machineID] = ActiveRestore(
        transaction: transaction,
        borrow: borrow
      )
      return transaction
    } catch {
      borrow.release()
      throw error
    }
  }

  func finishRestore(
    _ transaction: MacVirtualMachineSavedStateRestoreTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) throws {
    let active = try activeRestore(transaction, for: lease)
    activeRestores[lease.target.machineID] = nil
    defer { active.borrow.release() }
    guard fileManager.fileExists(atPath: transaction.consumingDirectoryURL.path) else {
      return
    }
    try requireDirectory(transaction.consumingDirectoryURL)
    try fileManager.removeItem(at: transaction.consumingDirectoryURL)
    try syncDirectory(at: lease.machine.bundleURL)
  }

  func discard(for lease: MacVirtualMachineRuntimeLease) throws {
    let borrow = try lease.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: lease.target.machineID)
    try recover(in: lease.machine.bundleURL)

    let finalDirectory = savedStateDirectory(in: lease.machine.bundleURL)
    guard fileManager.fileExists(atPath: finalDirectory.path) else { return }
    try requireDirectory(finalDirectory)
    let tombstone = lease.machine.bundleURL.appending(
      path: Self.transactionName(
        operationID: UUID(),
        suffix: Self.discardingSuffix
      ),
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: finalDirectory, to: tombstone)
    try syncDirectory(at: lease.machine.bundleURL)
    try fileManager.removeItem(at: tombstone)
    try syncDirectory(at: lease.machine.bundleURL)
  }

  private func validatedArtifact(
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> MacVirtualMachineSavedStateArtifact? {
    try recover(in: lease.machine.bundleURL)
    let directory = savedStateDirectory(in: lease.machine.bundleURL)
    guard fileManager.fileExists(atPath: directory.path) else { return nil }
    try requireDirectory(directory)

    let metadataURL = directory.appending(path: Self.metadataFilename)
    _ = try requireRegularFile(metadataURL, nonempty: true)
    let metadata = try JSONDecoder().decode(
      MacVirtualMachineSavedStateMetadata.self,
      from: Data(contentsOf: metadataURL)
    )
    guard metadata.schemaVersion == MacVirtualMachineSavedStateMetadata.currentSchemaVersion else {
      throw MacVirtualMachineSavedStateError.unsupportedSchema(metadata.schemaVersion)
    }
    guard metadata.machineID == lease.target.machineID,
      metadata.stateFilename == Self.stateFilename
    else {
      throw MacVirtualMachineSavedStateError.invalidBundle(
        "metadata does not belong to this virtual machine"
      )
    }
    guard
      metadata.hostOperatingSystemVersion
        == ProcessInfo.processInfo.operatingSystemVersionString
    else {
      throw MacVirtualMachineSavedStateError.incompatible(
        lease.target.machineID,
        "the host operating system changed after suspension"
      )
    }

    let stateURL = directory.appending(path: Self.stateFilename)
    let stateSize = try requireRegularFile(stateURL, nonempty: true)
    guard stateSize == metadata.stateSizeBytes else {
      throw MacVirtualMachineSavedStateError.invalidBundle(
        "the saved-state file size changed"
      )
    }
    let currentFingerprint = try fingerprinter.fingerprint(for: lease.machine)
    guard currentFingerprint == metadata.configurationFingerprint else {
      throw MacVirtualMachineSavedStateError.incompatible(
        lease.target.machineID,
        "the VM configuration or writable storage changed after suspension"
      )
    }
    return MacVirtualMachineSavedStateArtifact(
      stateURL: stateURL,
      summary: MacVirtualMachineSavedStateSummary(
        createdAt: metadata.createdAt,
        stateSizeBytes: metadata.stateSizeBytes
      ),
      configurationFingerprint: metadata.configurationFingerprint
    )
  }

  private func recover(in bundleURL: URL) throws {
    try requireDirectory(bundleURL)
    let entries = try fileManager.contentsOfDirectory(
      at: bundleURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    let orphans = entries.filter { url in
      let name = url.lastPathComponent
      guard name.hasPrefix(Self.stagingPrefix) else { return false }
      return name.hasSuffix(Self.stagingSuffix)
        || name.hasSuffix(Self.restoringSuffix)
        || name.hasSuffix(Self.discardingSuffix)
    }
    for orphan in orphans {
      try requireDirectory(orphan)
      try fileManager.removeItem(at: orphan)
    }
    if !orphans.isEmpty {
      try syncDirectory(at: bundleURL)
    }
  }

  private func ensureNoActiveTransaction(for machineID: UUID) throws {
    guard activeSaves[machineID] == nil, activeRestores[machineID] == nil else {
      throw MacVirtualMachineSavedStateError.operationInProgress(machineID)
    }
  }

  private func activeSave(
    _ transaction: MacVirtualMachineSavedStateTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> ActiveSave {
    guard let active = activeSaves[lease.target.machineID],
      active.transaction == transaction,
      transaction.target == lease.target
    else {
      throw MacVirtualMachineSavedStateError.invalidTransaction(
        lease.target.machineID
      )
    }
    return active
  }

  private func activeRestore(
    _ transaction: MacVirtualMachineSavedStateRestoreTransaction,
    for lease: MacVirtualMachineRuntimeLease
  ) throws -> ActiveRestore {
    guard let active = activeRestores[lease.target.machineID],
      active.transaction == transaction,
      transaction.target == lease.target
    else {
      throw MacVirtualMachineSavedStateError.invalidTransaction(
        lease.target.machineID
      )
    }
    return active
  }

  private func savedStateDirectory(in bundleURL: URL) -> URL {
    bundleURL.appending(path: Self.directoryName, directoryHint: .isDirectory)
  }

  private func requireDirectory(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MacVirtualMachineSavedStateError.invalidBundle(
        "\(url.lastPathComponent) is missing or symbolic"
      )
    }
  }

  private func requireRegularFile(_ url: URL, nonempty: Bool) throws -> UInt64 {
    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize,
      !nonempty || size > 0
    else {
      throw MacVirtualMachineSavedStateError.invalidBundle(
        "\(url.lastPathComponent) is missing, empty, or unsafe"
      )
    }
    return UInt64(size)
  }

  private func fullySyncFile(at url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0, Darwin.fsync(descriptor) != 0 {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func syncDirectory(at url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  private static func transactionName(operationID: UUID, suffix: String) -> String {
    "\(stagingPrefix)\(operationID.uuidString.lowercased())\(suffix)"
  }
}

extension SHA256.Digest {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
