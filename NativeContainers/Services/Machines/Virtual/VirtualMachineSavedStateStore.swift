import CryptoKit
import Darwin
import Foundation

struct VirtualMachineSavedStateContext: Sendable {
  let target: VirtualMachineRuntimeTarget
  let bundleURL: URL
  let machineName: String

  private let borrowHandler: @Sendable () throws -> VirtualMachineRuntimeLeaseBorrow
  private let fingerprintHandler: @Sendable () throws -> String

  init(
    target: VirtualMachineRuntimeTarget,
    bundleURL: URL,
    machineName: String,
    borrow: @escaping @Sendable () throws -> VirtualMachineRuntimeLeaseBorrow,
    fingerprint: @escaping @Sendable () throws -> String
  ) {
    self.target = target
    self.bundleURL = bundleURL
    self.machineName = machineName
    borrowHandler = borrow
    fingerprintHandler = fingerprint
  }

  func borrow() throws -> VirtualMachineRuntimeLeaseBorrow {
    try borrowHandler()
  }

  func configurationFingerprint() throws -> String {
    try fingerprintHandler()
  }
}

actor VirtualMachineSavedStateStore {
  static let directoryName = "SavedState"
  static let stateFilename = "Machine.vzvmsave"
  static let metadataFilename = "metadata.json"
  static let stagingPrefix = ".SavedState-"
  static let stagingSuffix = ".partial"
  static let restoringSuffix = ".restoring"
  static let discardingSuffix = ".discarding"

  private struct ActiveSave {
    let transaction: VirtualMachineSavedStateTransaction
    let borrow: VirtualMachineRuntimeLeaseBorrow
  }

  private struct ActiveRestore {
    let transaction: VirtualMachineSavedStateRestoreTransaction
    let borrow: VirtualMachineRuntimeLeaseBorrow
  }

  private let fileManager = FileManager.default
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private var activeSaves: [UUID: ActiveSave] = [:]
  private var activeRestores: [UUID: ActiveRestore] = [:]

  init(
    artifactInspector: any VirtualMachineStorageArtifactInspecting =
      FileVirtualMachineStorageArtifactInspector()
  ) {
    self.artifactInspector = artifactInspector
  }

  func inspect(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateStatus {
    let borrow = try context.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: context.target.machineID)
    do {
      guard let artifact = try validatedArtifact(for: context) else { return .none }
      return .available(artifact.summary)
    } catch {
      return .incompatible(error.localizedDescription)
    }
  }

  func beginSave(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateTransaction {
    let borrow = try context.borrow()
    do {
      try ensureNoActiveTransaction(for: context.target.machineID)
      try recover(in: context.bundleURL)
      guard
        !fileManager.fileExists(
          atPath: savedStateDirectory(in: context.bundleURL).path
        )
      else {
        throw VirtualMachineSavedStateError.checkpointAlreadyExists(
          context.target.machineID
        )
      }

      let operationID = UUID()
      let stagingDirectory = context.bundleURL.appending(
        path: Self.transactionName(
          operationID: operationID,
          suffix: Self.stagingSuffix
        ),
        directoryHint: .isDirectory
      )
      guard !fileManager.fileExists(atPath: stagingDirectory.path) else {
        throw VirtualMachineSavedStateError.invalidBundle(
          "a saved-state staging directory already exists"
        )
      }
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try syncDirectory(at: context.bundleURL)

      let transaction = VirtualMachineSavedStateTransaction(
        operationID: operationID,
        target: context.target,
        stagingDirectoryURL: stagingDirectory,
        stateURL: stagingDirectory.appending(path: Self.stateFilename)
      )
      activeSaves[context.target.machineID] = ActiveSave(
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
    _ transaction: VirtualMachineSavedStateTransaction,
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateSummary {
    let active = try activeSave(transaction, for: context)
    try requireDirectory(transaction.stagingDirectoryURL)
    let stateSize = try requireRegularFile(transaction.stateURL, nonempty: true)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: transaction.stateURL.path
    )
    try fullySyncFile(at: transaction.stateURL)

    let summary = VirtualMachineSavedStateSummary(
      createdAt: Date(),
      stateSizeBytes: stateSize
    )
    let metadata = VirtualMachineSavedStateMetadata(
      schemaVersion: VirtualMachineSavedStateMetadata.currentSchemaVersion,
      machineID: context.target.machineID,
      configurationFingerprint: try context.configurationFingerprint(),
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

    let finalDirectory = savedStateDirectory(in: context.bundleURL)
    guard !fileManager.fileExists(atPath: finalDirectory.path) else {
      throw VirtualMachineSavedStateError.checkpointAlreadyExists(
        context.target.machineID
      )
    }
    try fileManager.moveItem(at: transaction.stagingDirectoryURL, to: finalDirectory)
    try syncDirectory(at: context.bundleURL)

    activeSaves[context.target.machineID] = nil
    active.borrow.release()
    return summary
  }

  func abortSave(
    _ transaction: VirtualMachineSavedStateTransaction,
    for context: VirtualMachineSavedStateContext
  ) {
    guard let active = try? activeSave(transaction, for: context) else { return }
    activeSaves[context.target.machineID] = nil
    defer { active.borrow.release() }
    guard fileManager.fileExists(atPath: transaction.stagingDirectoryURL.path),
      (try? requireDirectory(transaction.stagingDirectoryURL)) != nil
    else { return }
    try? fileManager.removeItem(at: transaction.stagingDirectoryURL)
    try? syncDirectory(at: context.bundleURL)
  }

  func beginRestore(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateRestoreTransaction {
    let borrow = try context.borrow()
    do {
      try ensureNoActiveTransaction(for: context.target.machineID)
      guard let artifact = try validatedArtifact(for: context) else {
        throw VirtualMachineSavedStateError.missing(context.target.machineID)
      }

      let operationID = UUID()
      let finalDirectory = savedStateDirectory(in: context.bundleURL)
      let consumingDirectory = context.bundleURL.appending(
        path: Self.transactionName(
          operationID: operationID,
          suffix: Self.restoringSuffix
        ),
        directoryHint: .isDirectory
      )
      try fileManager.moveItem(at: finalDirectory, to: consumingDirectory)
      try syncDirectory(at: context.bundleURL)

      let transaction = VirtualMachineSavedStateRestoreTransaction(
        operationID: operationID,
        target: context.target,
        consumingDirectoryURL: consumingDirectory,
        artifact: VirtualMachineSavedStateArtifact(
          stateURL: consumingDirectory.appending(path: Self.stateFilename),
          summary: artifact.summary,
          configurationFingerprint: artifact.configurationFingerprint
        )
      )
      activeRestores[context.target.machineID] = ActiveRestore(
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
    _ transaction: VirtualMachineSavedStateRestoreTransaction,
    for context: VirtualMachineSavedStateContext
  ) throws {
    let active = try activeRestore(transaction, for: context)
    activeRestores[context.target.machineID] = nil
    defer { active.borrow.release() }
    guard fileManager.fileExists(atPath: transaction.consumingDirectoryURL.path) else {
      return
    }
    try requireDirectory(transaction.consumingDirectoryURL)
    try fileManager.removeItem(at: transaction.consumingDirectoryURL)
    try syncDirectory(at: context.bundleURL)
  }

  func discard(for context: VirtualMachineSavedStateContext) throws {
    let borrow = try context.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: context.target.machineID)
    try recover(in: context.bundleURL)

    let finalDirectory = savedStateDirectory(in: context.bundleURL)
    guard fileManager.fileExists(atPath: finalDirectory.path) else { return }
    try requireDirectory(finalDirectory)
    let tombstone = context.bundleURL.appending(
      path: Self.transactionName(
        operationID: UUID(),
        suffix: Self.discardingSuffix
      ),
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: finalDirectory, to: tombstone)
    try syncDirectory(at: context.bundleURL)
    try fileManager.removeItem(at: tombstone)
    try syncDirectory(at: context.bundleURL)
  }

  func prepareSavedStateReclamation(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateReclamationCandidate? {
    let borrow = try context.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: context.target.machineID)
    return try savedStateReclamationCandidate(for: context)
  }

  func reclaimSavedState(
    _ candidate: VirtualMachineSavedStateReclamationCandidate,
    for context: VirtualMachineSavedStateContext
  ) throws -> Bool {
    let borrow = try context.borrow()
    defer { borrow.release() }
    try ensureNoActiveTransaction(for: context.target.machineID)
    guard candidate.machineID == context.target.machineID,
      try savedStateReclamationCandidate(for: context) == candidate
    else {
      return false
    }

    try Task.checkCancellation()
    let finalDirectory = savedStateDirectory(in: context.bundleURL)
    let tombstone = context.bundleURL.appending(
      path: Self.transactionName(
        operationID: UUID(),
        suffix: Self.discardingSuffix
      ),
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: finalDirectory, to: tombstone)
    try syncDirectory(at: context.bundleURL)

    // The atomic rename commits this cleanup. Caller cancellation must not
    // abandon a committed tombstone halfway through reconciliation.
    try fileManager.removeItem(at: tombstone)
    try syncDirectory(at: context.bundleURL)
    return true
  }

  private func savedStateReclamationCandidate(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateReclamationCandidate? {
    let directory = savedStateDirectory(in: context.bundleURL)
    guard fileManager.fileExists(atPath: directory.path) else { return nil }
    let identity = try artifactInspector.inspect(at: directory)
    guard identity.fileType == .directory else {
      throw VirtualMachineSavedStateError.invalidBundle(
        "SavedState is not a directory"
      )
    }

    let metadataURL = directory.appending(path: Self.metadataFilename)
    _ = try requireRegularFile(metadataURL, nonempty: true)
    let metadata = try JSONDecoder().decode(
      VirtualMachineSavedStateMetadata.self,
      from: Data(contentsOf: metadataURL)
    )
    guard metadata.schemaVersion == VirtualMachineSavedStateMetadata.currentSchemaVersion else {
      throw VirtualMachineSavedStateError.unsupportedSchema(metadata.schemaVersion)
    }
    guard metadata.machineID == context.target.machineID,
      metadata.stateFilename == Self.stateFilename
    else {
      throw VirtualMachineSavedStateError.invalidBundle(
        "metadata does not belong to this virtual machine"
      )
    }
    let stateSize = try requireRegularFile(
      directory.appending(path: Self.stateFilename),
      nonempty: true
    )
    guard stateSize == metadata.stateSizeBytes else {
      throw VirtualMachineSavedStateError.invalidBundle(
        "the saved-state file size changed"
      )
    }
    return VirtualMachineSavedStateReclamationCandidate(
      machineID: context.target.machineID,
      machineName: context.machineName,
      createdAt: metadata.createdAt,
      stateSizeBytes: metadata.stateSizeBytes,
      configurationFingerprint: metadata.configurationFingerprint,
      artifactIdentity: identity
    )
  }

  private func validatedArtifact(
    for context: VirtualMachineSavedStateContext
  ) throws -> VirtualMachineSavedStateArtifact? {
    try recover(in: context.bundleURL)
    let directory = savedStateDirectory(in: context.bundleURL)
    guard fileManager.fileExists(atPath: directory.path) else { return nil }
    try requireDirectory(directory)

    let metadataURL = directory.appending(path: Self.metadataFilename)
    _ = try requireRegularFile(metadataURL, nonempty: true)
    let metadata = try JSONDecoder().decode(
      VirtualMachineSavedStateMetadata.self,
      from: Data(contentsOf: metadataURL)
    )
    guard metadata.schemaVersion == VirtualMachineSavedStateMetadata.currentSchemaVersion else {
      throw VirtualMachineSavedStateError.unsupportedSchema(metadata.schemaVersion)
    }
    guard metadata.machineID == context.target.machineID,
      metadata.stateFilename == Self.stateFilename
    else {
      throw VirtualMachineSavedStateError.invalidBundle(
        "metadata does not belong to this virtual machine"
      )
    }
    guard
      metadata.hostOperatingSystemVersion
        == ProcessInfo.processInfo.operatingSystemVersionString
    else {
      throw VirtualMachineSavedStateError.incompatible(
        context.target.machineID,
        "the host operating system changed after suspension"
      )
    }

    let stateURL = directory.appending(path: Self.stateFilename)
    let stateSize = try requireRegularFile(stateURL, nonempty: true)
    guard stateSize == metadata.stateSizeBytes else {
      throw VirtualMachineSavedStateError.invalidBundle(
        "the saved-state file size changed"
      )
    }
    let currentFingerprint = try context.configurationFingerprint()
    guard currentFingerprint == metadata.configurationFingerprint else {
      throw VirtualMachineSavedStateError.incompatible(
        context.target.machineID,
        "the VM configuration or writable storage changed after suspension"
      )
    }
    return VirtualMachineSavedStateArtifact(
      stateURL: stateURL,
      summary: VirtualMachineSavedStateSummary(
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
      throw VirtualMachineSavedStateError.operationInProgress(machineID)
    }
  }

  private func activeSave(
    _ transaction: VirtualMachineSavedStateTransaction,
    for context: VirtualMachineSavedStateContext
  ) throws -> ActiveSave {
    guard let active = activeSaves[context.target.machineID],
      active.transaction == transaction,
      transaction.target == context.target
    else {
      throw VirtualMachineSavedStateError.invalidTransaction(
        context.target.machineID
      )
    }
    return active
  }

  private func activeRestore(
    _ transaction: VirtualMachineSavedStateRestoreTransaction,
    for context: VirtualMachineSavedStateContext
  ) throws -> ActiveRestore {
    guard let active = activeRestores[context.target.machineID],
      active.transaction == transaction,
      transaction.target == context.target
    else {
      throw VirtualMachineSavedStateError.invalidTransaction(
        context.target.machineID
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
      throw VirtualMachineSavedStateError.invalidBundle(
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
      throw VirtualMachineSavedStateError.invalidBundle(
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
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
