import Darwin
import Foundation

struct ContainerHostDirectoryManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let operationID: UUID
  let mounts: [ContainerHostDirectoryMount]

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    operationID: UUID,
    mounts: [ContainerHostDirectoryMount]
  ) {
    self.schemaVersion = schemaVersion
    self.operationID = operationID
    self.mounts = mounts.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

protocol ContainerHostDirectoryManifestStoring: Sendable {
  func save(_ manifest: ContainerHostDirectoryManifest) throws
  func load(operationID: UUID) throws -> ContainerHostDirectoryManifest?
  func remove(operationID: UUID)
}

struct FileContainerHostDirectoryManifestStore: ContainerHostDirectoryManifestStoring {
  private static let maximumManifestBytes = 4 * 1_024 * 1_024

  let rootURL: URL

  init(rootURL: URL? = nil, fileManager: FileManager = .default) {
    self.rootURL =
      (rootURL
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Container Host Directories", directoryHint: .isDirectory)
      .appending(path: "v1", directoryHint: .isDirectory))
      .standardizedFileURL
  }

  func save(_ manifest: ContainerHostDirectoryManifest) throws {
    guard !manifest.mounts.isEmpty else {
      remove(operationID: manifest.operationID)
      return
    }

    try prepareRoot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    guard data.count <= Self.maximumManifestBytes else {
      throw ContainerHostDirectoryError.invalidManifest
    }

    let destination = manifestURL(operationID: manifest.operationID)
    let temporary = rootURL.appending(
      path: ".\(UUID().uuidString.lowercased()).partial",
      directoryHint: .notDirectory
    )
    let temporaryPath = temporary.nativeContainersPOSIXPath
    let descriptor = Darwin.open(
      temporaryPath,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    defer { Darwin.close(descriptor) }

    do {
      try write(data, to: descriptor)
      guard fsync(descriptor) == 0 else {
        throw ContainerHostDirectoryError.invalidManifest
      }
      guard Darwin.rename(temporaryPath, destination.nativeContainersPOSIXPath) == 0 else {
        throw ContainerHostDirectoryError.invalidManifest
      }
      try requireSecureManifest(destination)
      try syncRoot()
    } catch {
      _ = Darwin.unlink(temporaryPath)
      throw error
    }
  }

  func load(operationID: UUID) throws -> ContainerHostDirectoryManifest? {
    var rootMetadata = stat()
    let rootPath = rootURL.nativeContainersPOSIXPath
    guard lstat(rootPath, &rootMetadata) == 0 else {
      if errno == ENOENT { return nil }
      throw ContainerHostDirectoryError.invalidManifest
    }
    try requireSecureRoot()

    let url = manifestURL(operationID: operationID)
    let path = url.nativeContainersPOSIXPath
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw ContainerHostDirectoryError.invalidManifest
    }
    defer { Darwin.close(descriptor) }

    let size = try requireSecureManifestDescriptor(descriptor)
    let data = try read(from: descriptor, count: size)
    let manifest: ContainerHostDirectoryManifest
    do {
      manifest = try JSONDecoder().decode(ContainerHostDirectoryManifest.self, from: data)
    } catch {
      throw ContainerHostDirectoryError.invalidManifest
    }
    guard
      manifest.schemaVersion == ContainerHostDirectoryManifest.currentSchemaVersion,
      manifest.operationID == operationID,
      !manifest.mounts.isEmpty
    else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    return manifest
  }

  func remove(operationID: UUID) {
    do {
      try requireSecureRoot()
      let url = manifestURL(operationID: operationID)
      var metadata = stat()
      let path = url.nativeContainersPOSIXPath
      guard lstat(path, &metadata) == 0 else { return }
      try requireSecureManifest(url)
      _ = Darwin.unlink(path)
      try syncRoot()
    } catch {
      return
    }
  }

  private func prepareRoot() throws {
    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw ContainerHostDirectoryError.invalidManifest
    }
    try requireSecureRoot()
  }

  private func requireSecureRoot() throws {
    var metadata = stat()
    guard lstat(rootURL.nativeContainersPOSIXPath, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == getuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw ContainerHostDirectoryError.invalidManifest
    }
  }

  private func requireSecureManifest(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.nativeContainersPOSIXPath,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    defer { Darwin.close(descriptor) }
    _ = try requireSecureManifestDescriptor(descriptor)
  }

  private func requireSecureManifestDescriptor(_ descriptor: Int32) throws -> Int {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == getuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumManifestBytes
    else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    return Int(metadata.st_size)
  }

  private func manifestURL(operationID: UUID) -> URL {
    rootURL.appending(
      path: "\(operationID.uuidString.lowercased()).json",
      directoryHint: .notDirectory
    )
  }

  private func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        guard written > 0 else {
          throw ContainerHostDirectoryError.invalidManifest
        }
        offset += written
      }
    }
  }

  private func read(from descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    let bytesRead = try data.withUnsafeMutableBytes { rawBuffer -> Int in
      guard let baseAddress = rawBuffer.baseAddress else { return 0 }
      var offset = 0
      while offset < count {
        let result = Darwin.read(
          descriptor,
          baseAddress.advanced(by: offset),
          count - offset
        )
        guard result > 0 else {
          throw ContainerHostDirectoryError.invalidManifest
        }
        offset += result
      }
      return offset
    }
    guard bytesRead == count else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    return data
  }

  private func syncRoot() throws {
    let descriptor = Darwin.open(
      rootURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw ContainerHostDirectoryError.invalidManifest
    }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw ContainerHostDirectoryError.invalidManifest
    }
  }
}
