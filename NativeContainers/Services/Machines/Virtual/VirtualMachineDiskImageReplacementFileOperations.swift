import Darwin
import Foundation

struct VirtualMachineDiskImageReplacementFileOperations:
  @unchecked Sendable
{
  private let artifactInspector: any VirtualMachineStorageArtifactInspecting
  private let journalStore: any VirtualMachineDiskImageReplacementJournaling
  private let fileManager: FileManager

  init(
    artifactInspector: any VirtualMachineStorageArtifactInspecting,
    journalStore: any VirtualMachineDiskImageReplacementJournaling,
    fileManager: FileManager
  ) {
    self.artifactInspector = artifactInspector
    self.journalStore = journalStore
    self.fileManager = fileManager
  }

  func loadJournal(
    in bundleURL: URL
  ) throws -> VirtualMachineDiskImageReplacementJournal? {
    try journalStore.load(in: bundleURL)
  }

  func saveJournal(
    _ journal: VirtualMachineDiskImageReplacementJournal,
    in bundleURL: URL
  ) throws {
    try journalStore.save(journal, in: bundleURL)
  }

  func inspectOwnedFile(
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    let identity = try artifactInspector.inspect(at: url)
    guard identity.fileType == .regularFile,
      identity.ownerUserID == UInt32(geteuid()),
      identity.linkCount == 1
    else {
      throw VirtualMachineDiskImageReplacementError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    return identity
  }

  func requireIdentity(
    _ expected: VirtualMachineStorageArtifactIdentity,
    at url: URL
  ) throws {
    guard try inspectOwnedFile(at: url).refersToSameStableFile(as: expected) else {
      throw VirtualMachineDiskImageReplacementError.staleSource
    }
  }

  func inspectRenamedFile(
    _ previous: VirtualMachineStorageArtifactIdentity?,
    at url: URL
  ) throws -> VirtualMachineStorageArtifactIdentity {
    guard let previous else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
    let current = try inspectOwnedFile(at: url)
    guard current.refersToSameStableFile(as: previous) else {
      throw VirtualMachineDiskImageReplacementError.staleSource
    }
    return current
  }

  func resolve(_ path: String, in bundleURL: URL) throws -> URL {
    let string = NSString(string: path)
    let components = string.pathComponents
    guard !string.isAbsolutePath,
      !components.isEmpty,
      !components.contains(".."),
      components.allSatisfy({ $0 != "/" && $0 != "." })
    else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
    let candidate = bundleURL.appending(path: path).standardizedFileURL
    let bundleComponents = bundleURL.standardizedFileURL.pathComponents
    guard candidate.pathComponents.count > bundleComponents.count,
      candidate.pathComponents.prefix(bundleComponents.count)
        .elementsEqual(bundleComponents)
    else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }
    return candidate
  }

  func requireAbsent(_ url: URL) throws {
    var metadata = stat()
    if Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 {
      throw VirtualMachineDiskImageReplacementError.destinationExists(url)
    }
    guard errno == ENOENT else {
      throw VirtualMachineDiskImageReplacementError.unsafeArtifact(
        url.lastPathComponent
      )
    }
  }

  func securePrivateArtifact(at url: URL) throws {
    _ = try inspectOwnedFile(at: url)
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  func promote(from stagingURL: URL, to destinationURL: URL) throws {
    try requireAbsent(destinationURL)
    try fileManager.moveItem(at: stagingURL, to: destinationURL)
    try synchronizeDirectory(destinationURL.deletingLastPathComponent())
  }

  func rollback(
    _ journal: VirtualMachineDiskImageReplacementJournal,
    in bundleURL: URL
  ) throws {
    let sourceURL = try resolve(journal.sourcePath, in: bundleURL)
    try requireIdentity(journal.sourceIdentity, at: sourceURL)

    let stagingURL = try resolve(journal.stagingPath, in: bundleURL)
    let destinationURL = try resolve(journal.destinationPath, in: bundleURL)
    let stagingExists = exists(stagingURL)
    let destinationExists = exists(destinationURL)

    switch journal.phase {
    case .planned, .terminationQuarantined:
      guard !destinationExists else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      if stagingExists {
        try removeOwnedFile(at: stagingURL)
        try synchronizeDirectory(stagingURL.deletingLastPathComponent())
      }
    case .converted:
      guard !(stagingExists && destinationExists),
        let expected = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      if stagingExists || destinationExists {
        let artifactURL = stagingExists ? stagingURL : destinationURL
        let identity = try inspectOwnedFile(at: artifactURL)
        guard identity.refersToSameStableFile(as: expected) else {
          throw VirtualMachineDiskImageReplacementError.invalidJournal
        }
        try fileManager.removeItem(at: artifactURL)
        try synchronizeDirectory(artifactURL.deletingLastPathComponent())
      }
    case .promoted:
      guard !stagingExists,
        let expected = journal.destinationIdentity
      else {
        throw VirtualMachineDiskImageReplacementError.invalidJournal
      }
      if destinationExists {
        try requireIdentity(expected, at: destinationURL)
        try fileManager.removeItem(at: destinationURL)
        try synchronizeDirectory(destinationURL.deletingLastPathComponent())
      }
    case .manifestUpdated:
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }

    try journalStore.remove(journal, from: bundleURL)
  }

  func finishCommitted(
    _ journal: VirtualMachineDiskImageReplacementJournal,
    in bundleURL: URL
  ) throws {
    guard journal.phase == .promoted || journal.phase == .manifestUpdated,
      let destinationIdentity = journal.destinationIdentity
    else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }

    let destinationURL = try resolve(journal.destinationPath, in: bundleURL)
    try requireIdentity(destinationIdentity, at: destinationURL)

    let stagingURL = try resolve(journal.stagingPath, in: bundleURL)
    guard !exists(stagingURL) else {
      throw VirtualMachineDiskImageReplacementError.invalidJournal
    }

    let sourceURL = try resolve(journal.sourcePath, in: bundleURL)
    if exists(sourceURL) {
      try requireIdentity(journal.sourceIdentity, at: sourceURL)
      try fileManager.removeItem(at: sourceURL)
      try synchronizeDirectory(sourceURL.deletingLastPathComponent())
    }
    try journalStore.remove(journal, from: bundleURL)
  }

  private func removeOwnedFile(at url: URL) throws {
    _ = try inspectOwnedFile(at: url)
    try fileManager.removeItem(at: url)
  }

  private func exists(_ url: URL) -> Bool {
    var metadata = stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageReplacementError.unsafeArtifact(
        url.lastPathComponent
      )
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
