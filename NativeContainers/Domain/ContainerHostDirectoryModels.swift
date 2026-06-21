import Foundation

struct ContainerHostDirectorySourceIdentity: Codable, Equatable, Hashable, Sendable {
  let device: UInt64
  let inode: UInt64
}

struct ContainerHostDirectoryReviewRequest: Equatable, Sendable {
  let sourceURL: URL
  let containerPath: String
  let isReadOnly: Bool
}

struct ContainerHostDirectoryMount: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let bookmarkData: Data
  let lastKnownPath: String
  let sourceIdentity: ContainerHostDirectorySourceIdentity
  let containerPath: String
  let isReadOnly: Bool

  init(
    id: UUID = UUID(),
    bookmarkData: Data,
    lastKnownPath: String,
    sourceIdentity: ContainerHostDirectorySourceIdentity,
    containerPath: String,
    isReadOnly: Bool
  ) throws {
    guard !bookmarkData.isEmpty else {
      throw ContainerHostDirectoryError.invalidBookmark
    }
    let lastKnownPath = lastKnownPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard lastKnownPath.hasPrefix("/"), !lastKnownPath.contains("\0") else {
      throw ContainerHostDirectoryError.invalidDirectory(lastKnownPath)
    }

    self.id = id
    self.bookmarkData = bookmarkData
    self.lastKnownPath = lastKnownPath
    self.sourceIdentity = sourceIdentity
    self.containerPath = try ContainerAttachmentPath.containerPath(containerPath)
    self.isReadOnly = isReadOnly
  }
}

enum ContainerHostDirectoryError: LocalizedError, Equatable, Sendable {
  case invalidBookmark
  case invalidDirectory(String)
  case rootDirectoryNotAllowed
  case accessDenied(String)
  case staleBookmark(String)
  case sourceIdentityChanged(String)
  case missingManifest
  case invalidManifest
  case configurationChanged

  var errorDescription: String? {
    switch self {
    case .invalidBookmark:
      "The selected host folder did not produce a valid persistent permission."
    case .invalidDirectory(let path):
      "The host-folder source is not a safe local directory: \(path)"
    case .rootDirectoryNotAllowed:
      "The Mac filesystem root cannot be shared with a container. Choose a narrower folder."
    case .accessDenied(let path):
      "NativeContainers cannot access the host folder at \(path). Choose it again."
    case .staleBookmark(let path):
      "The saved permission for \(path) is stale. Choose the folder again."
    case .sourceIdentityChanged(let path):
      "The folder behind \(path) was replaced after review. Choose the intended folder again."
    case .missingManifest:
      "The reviewed host-folder record is missing. Remove and recreate the container."
    case .invalidManifest:
      "The reviewed host-folder record is damaged or has unsafe permissions."
    case .configurationChanged:
      "The container’s host-folder mounts changed after review."
    }
  }
}
