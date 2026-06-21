import ContainerResource
import Darwin
import Foundation
import SystemPackage

struct ApplePublishedSocketWorkspace: Sendable {
  let rootURL: URL

  init(
    rootURL: URL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    .appending(path: "NativeContainers", directoryHint: .isDirectory)
    .appending(path: "PublishedSockets", directoryHint: .isDirectory)
  ) {
    self.rootURL = rootURL.standardizedFileURL
  }

  var rootPath: String {
    rootURL.path()
  }

  func prepare(
    _ publications: [ContainerUnixSocketPublication],
    operationID: UUID
  ) throws -> [PublishSocket] {
    guard !publications.isEmpty else { return [] }

    var createdOperationDirectory = false
    do {
      let prepared = try prepareOperationDirectory(operationID: operationID)
      let operationURL = prepared.url
      createdOperationDirectory = prepared.created
      return try publications.map { publication in
        let hostURL = operationURL.appending(
          path: publication.hostSocketName,
          directoryHint: .notDirectory
        )
        try requireAbsentLeaf(hostURL)
        guard hostURL.path().utf8.count < 253 else {
          throw PublishedSocketWorkspaceError.hostPathTooLong
        }
        return try PublishSocket(
          containerPath: FilePath(publication.containerPath),
          hostPath: FilePath(hostURL.path()),
          permissions: nil
        )
      }
    } catch {
      if createdOperationDirectory {
        try? FileManager.default.removeItem(
          at: operationDirectoryURL(operationID: operationID)
        )
      }
      throw error
    }
  }

  func validateBeforeStart(
    _ sockets: [PublishSocket],
    operationID: UUID
  ) throws {
    guard !sockets.isEmpty else { return }

    let operationURL = operationDirectoryURL(operationID: operationID)
    try requireSecureDirectory(rootURL)
    try requireSecureDirectory(operationURL)

    for socket in sockets {
      let hostURL = URL(
        filePath: socket.hostPath.string,
        directoryHint: .notDirectory
      ).standardizedFileURL
      guard
        hostURL.deletingLastPathComponent().standardizedFileURL == operationURL,
        hostURL.lastPathComponent.range(
          of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\.sock$"#,
          options: .regularExpression
        ) != nil
      else {
        throw PublishedSocketWorkspaceError.outsideOwnedWorkspace
      }
      try requireAbsentLeaf(hostURL)
    }
  }

  func cleanup(operationID: UUID) {
    let operationURL = operationDirectoryURL(operationID: operationID)
    guard
      operationURL.deletingLastPathComponent().standardizedFileURL == rootURL
    else {
      return
    }
    try? FileManager.default.removeItem(at: operationURL)
  }

  private func prepareOperationDirectory(
    operationID: UUID
  ) throws -> (url: URL, created: Bool) {
    try createSecureDirectoryIfNeeded(rootURL)
    let operationURL = operationDirectoryURL(operationID: operationID)
    let existed = FileManager.default.fileExists(atPath: operationURL.path())
    try createSecureDirectoryIfNeeded(operationURL)
    return (operationURL, !existed)
  }

  private func operationDirectoryURL(operationID: UUID) -> URL {
    rootURL.appending(
      path: operationID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
  }

  private func createSecureDirectoryIfNeeded(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw PublishedSocketWorkspaceError.insecureDirectory
      }
      try requireSecureDirectory(url)
      return
    }

    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    guard chmod(url.path(), 0o700) == 0 else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }
    try requireSecureDirectory(url)
  }

  private func requireSecureDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path(), &info) == 0 else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }
    let fileType = info.st_mode & mode_t(S_IFMT)
    guard
      fileType == mode_t(S_IFDIR),
      info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }
  }

  private func requireAbsentLeaf(_ url: URL) throws {
    var info = stat()
    if lstat(url.path(), &info) == 0 {
      throw PublishedSocketWorkspaceError.hostPathOccupied(url.path())
    }
    guard errno == ENOENT else {
      throw PublishedSocketWorkspaceError.hostPathUnavailable(url.path())
    }
  }
}

enum PublishedSocketWorkspaceError: LocalizedError, Equatable {
  case insecureDirectory
  case outsideOwnedWorkspace
  case hostPathOccupied(String)
  case hostPathUnavailable(String)
  case hostPathTooLong

  var errorDescription: String? {
    switch self {
    case .insecureDirectory:
      "The private published-socket directory is missing or has unsafe ownership or permissions."
    case .outsideOwnedWorkspace:
      "Published sockets must stay inside the app-owned operation directory."
    case .hostPathOccupied(let path):
      "The host socket path “\(path)” already exists. It was not replaced."
    case .hostPathUnavailable(let path):
      "The host socket path “\(path)” could not be inspected safely."
    case .hostPathTooLong:
      "The generated host socket path is too long."
    }
  }
}
