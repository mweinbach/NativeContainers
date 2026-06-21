import ContainerResource
import Darwin
import Foundation
import SystemPackage

struct ApplePublishedSocketWorkspace: Sendable {
  private static let maximumPortableHostSocketPathBytes = 104

  let rootURL: URL

  init(rootURL: URL? = nil) {
    let defaultRootURL = URL(
      filePath: "/private/tmp",
      directoryHint: .isDirectory
    ).appending(
      path: "nativecontainers-\(getuid())",
      directoryHint: .isDirectory
    )
    self.rootURL = (rootURL ?? defaultRootURL).standardizedFileURL
  }

  var rootPath: String {
    rootURL.path(percentEncoded: false)
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
        guard
          hostURL.path(percentEncoded: false).utf8.count
            < Self.maximumPortableHostSocketPathBytes
        else {
          throw PublishedSocketWorkspaceError.hostPathTooLong
        }
        return try PublishSocket(
          containerPath: FilePath(publication.containerPath),
          hostPath: FilePath(hostURL.path(percentEncoded: false)),
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

    var createdOperationDirectory = false
    do {
      let prepared = try prepareOperationDirectory(operationID: operationID)
      let operationURL = prepared.url
      createdOperationDirectory = prepared.created

      for socket in sockets {
        let hostURL = URL(
          filePath: socket.hostPath.string,
          directoryHint: .notDirectory
        ).standardizedFileURL
        guard
          socket.hostPath.removingLastComponent()
            == FilePath(operationURL.path(percentEncoded: false)),
          hostURL.lastPathComponent.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\.sock$"#,
            options: .regularExpression
          ) != nil
        else {
          throw PublishedSocketWorkspaceError.outsideOwnedWorkspace
        }
        guard
          hostURL.path(percentEncoded: false).utf8.count
            < Self.maximumPortableHostSocketPathBytes
        else {
          throw PublishedSocketWorkspaceError.hostPathTooLong
        }
        try requireAbsentLeaf(hostURL)
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

  func cleanup(operationID: UUID) {
    let operationURL = operationDirectoryURL(operationID: operationID)
    guard
      FilePath(operationURL.path(percentEncoded: false)).removingLastComponent()
        == FilePath(rootURL.path(percentEncoded: false))
    else {
      return
    }
    do {
      try requireSecureDirectory(rootURL)
      try requireSecureDirectory(operationURL)
      try FileManager.default.removeItem(at: operationURL)
    } catch {
      return
    }
  }

  private func prepareOperationDirectory(
    operationID: UUID
  ) throws -> (url: URL, created: Bool) {
    _ = try createSecureDirectoryIfNeeded(rootURL)
    let operationURL = operationDirectoryURL(operationID: operationID)
    let created = try createSecureDirectoryIfNeeded(operationURL)
    return (operationURL, created)
  }

  private func operationDirectoryURL(operationID: UUID) -> URL {
    rootURL.appending(
      path: operationID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
  }

  private func createSecureDirectoryIfNeeded(_ url: URL) throws -> Bool {
    let path = url.path(percentEncoded: false)
    var info = stat()
    if lstat(path, &info) == 0 {
      try requireSecureDirectory(url)
      return false
    }
    guard errno == ENOENT else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }

    if mkdir(path, 0o700) == 0 {
      try requireSecureDirectory(url)
      return true
    }
    guard errno == EEXIST else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }

    try requireSecureDirectory(url)
    return false
  }

  private func requireSecureDirectory(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }
    let fileType = info.st_mode & mode_t(S_IFMT)
    guard
      fileType == mode_t(S_IFDIR),
      info.st_uid == getuid(),
      info.st_mode & 0o700 == 0o700,
      info.st_mode & 0o077 == 0
    else {
      throw PublishedSocketWorkspaceError.insecureDirectory
    }
  }

  private func requireAbsentLeaf(_ url: URL) throws {
    var info = stat()
    if lstat(url.path(percentEncoded: false), &info) == 0 {
      throw PublishedSocketWorkspaceError.hostPathOccupied(url.path(percentEncoded: false))
    }
    guard errno == ENOENT else {
      throw PublishedSocketWorkspaceError.hostPathUnavailable(url.path(percentEncoded: false))
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
      "The generated host socket path exceeds the portable macOS Unix-socket limit."
    }
  }
}
