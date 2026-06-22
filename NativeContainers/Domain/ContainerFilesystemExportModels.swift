import Foundation

struct ContainerFilesystemExportRequest: Equatable, Sendable {
  let target: ContainerTerminalTargetIdentity
  let destinationURL: URL

  init(container: ContainerRecord, destinationURL: URL) throws {
    guard container.state == .stopped else {
      throw ContainerFilesystemExportError.containerMustBeStopped(container.id)
    }
    guard destinationURL.isFileURL else {
      throw ContainerFilesystemExportError.invalidDestinationURL
    }

    let destinationURL = destinationURL.standardizedFileURL
    let name = destinationURL.lastPathComponent
    guard
      !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains("\0")
    else {
      throw ContainerFilesystemExportError.invalidDestinationName(name)
    }
    guard destinationURL.pathExtension.caseInsensitiveCompare("tar") == .orderedSame else {
      throw ContainerFilesystemExportError.invalidArchiveExtension(name)
    }

    target = ContainerTerminalTargetIdentity(container: container)
    self.destinationURL = destinationURL
  }

  static func suggestedFileName(containerID: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = containerID.unicodeScalars.map { scalar -> Character in
      allowed.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let stem = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    return "\(stem.isEmpty ? "container" : stem).rootfs.tar"
  }
}

struct ContainerFilesystemExportReceipt: Equatable, Sendable {
  let target: ContainerTerminalTargetIdentity
  let destinationURL: URL
  let byteCount: Int64
  let sha256: String
}

struct ContainerFilesystemExportPartialCompletionError: LocalizedError, Equatable, Sendable {
  let receipt: ContainerFilesystemExportReceipt
  let failureMessage: String

  var errorDescription: String? {
    "The filesystem archive was committed, but finalization failed: \(failureMessage) The archive was retained."
  }
}

enum ContainerFilesystemExportError: LocalizedError, Equatable, Sendable {
  case invalidDestinationURL
  case invalidDestinationName(String)
  case invalidArchiveExtension(String)
  case unsafeDestinationParent(String)
  case destinationMustBeNew(String)
  case destinationChanged(String)
  case containerUnavailable(String)
  case containerIdentityChanged(String)
  case containerMustBeStopped(String)
  case unsafeArchive(String)
  case stagingUnavailable(String)
  case exportFailed(String)
  case publicationFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidDestinationURL:
      "Choose a local destination for the filesystem archive."
    case .invalidDestinationName(let name):
      "“\(name)” is not a safe archive name."
    case .invalidArchiveExtension(let name):
      "“\(name)” must use the .tar filename extension."
    case .unsafeDestinationParent(let path):
      "The archive parent at \(path) must be an owner-controlled directory that is not writable by other users."
    case .destinationMustBeNew(let path):
      "The archive destination at \(path) already exists. Choose a new filename."
    case .destinationChanged(let path):
      "The archive destination at \(path) changed while the export was running. Nothing was replaced."
    case .containerUnavailable(let id):
      "Container “\(id)” is no longer available."
    case .containerIdentityChanged(let id):
      "Container “\(id)” was replaced after this export was prepared."
    case .containerMustBeStopped(let id):
      "Container “\(id)” must be stopped before exporting its filesystem."
    case .unsafeArchive(let path):
      "Apple’s container service did not produce a safe, nonempty archive at \(path)."
    case .stagingUnavailable(let message):
      "A private export staging area could not be prepared: \(message)"
    case .exportFailed(let message):
      "Apple’s container service could not export the filesystem: \(message)"
    case .publicationFailed(let message):
      "The filesystem archive could not be committed: \(message)"
    }
  }
}
