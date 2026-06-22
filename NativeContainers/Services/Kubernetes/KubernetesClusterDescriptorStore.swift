import Darwin
import Foundation

actor KubernetesClusterDescriptorStore: KubernetesClusterDescriptorStoring {
  static let maximumDescriptorBytes = 64 * 1_024

  private static let descriptorFileName = "Cluster.json"

  private let rootURL: URL
  private let fileManager: FileManager

  init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
  }

  func load() throws -> KubernetesClusterDescriptor? {
    let rootPath = rootURL.nativeContainersPOSIXPath
    guard fileManager.fileExists(atPath: rootPath) else {
      return nil
    }
    try ensurePrivateRoot(createIfMissing: false)

    let url = descriptorURL
    guard fileManager.fileExists(atPath: url.nativeContainersPOSIXPath) else {
      return nil
    }
    let metadata = try validateDescriptorFile(at: url)
    guard let byteCount = Int(exactly: metadata.st_size) else {
      throw KubernetesClusterError.descriptorUnsafe
    }

    do {
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count == byteCount else {
        throw KubernetesClusterError.descriptorUnsafe
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .deferredToDate
      let descriptor = try decoder.decode(KubernetesClusterDescriptor.self, from: data)
      try Self.validate(descriptor)
      return descriptor
    } catch let error as KubernetesClusterError {
      throw error
    } catch {
      throw KubernetesClusterError.descriptorInvalid
    }
  }

  func save(_ descriptor: KubernetesClusterDescriptor) throws {
    try Self.validate(descriptor)
    try ensurePrivateRoot(createIfMissing: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(descriptor)
    } catch {
      throw KubernetesClusterError.ioFailure("encode its cluster record")
    }
    guard !data.isEmpty, data.count <= Self.maximumDescriptorBytes else {
      throw KubernetesClusterError.descriptorInvalid
    }

    let url = descriptorURL
    if fileManager.fileExists(atPath: url.nativeContainersPOSIXPath) {
      _ = try validateDescriptorFile(at: url)
    }

    do {
      try data.write(to: url, options: [.atomic])
      guard Darwin.chmod(url.nativeContainersPOSIXPath, mode_t(0o600)) == 0 else {
        throw KubernetesClusterError.ioFailure("secure its cluster record")
      }
      _ = try validateDescriptorFile(at: url)
      try excludeFromBackup(url)
    } catch let error as KubernetesClusterError {
      throw error
    } catch {
      throw KubernetesClusterError.ioFailure("save its cluster record")
    }
  }

  func remove() throws {
    let rootPath = rootURL.nativeContainersPOSIXPath
    guard fileManager.fileExists(atPath: rootPath) else {
      return
    }
    try ensurePrivateRoot(createIfMissing: false)

    let url = descriptorURL
    guard fileManager.fileExists(atPath: url.nativeContainersPOSIXPath) else {
      return
    }
    _ = try validateDescriptorFile(at: url)
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw KubernetesClusterError.ioFailure("remove its cluster record")
    }
  }

  private var descriptorURL: URL {
    rootURL.appending(
      path: Self.descriptorFileName,
      directoryHint: .notDirectory
    )
  }

  private func ensurePrivateRoot(createIfMissing: Bool) throws {
    let path = rootURL.nativeContainersPOSIXPath
    var metadata = stat()
    if Darwin.lstat(path, &metadata) == 0 {
      guard
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
      else {
        throw KubernetesClusterError.descriptorUnsafe
      }
    } else {
      guard errno == ENOENT, createIfMissing else {
        if errno == ENOENT {
          return
        }
        throw KubernetesClusterError.descriptorUnsafe
      }

      do {
        try fileManager.createDirectory(
          at: rootURL,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw KubernetesClusterError.ioFailure("prepare its private directory")
      }
    }

    guard Darwin.chmod(path, mode_t(0o700)) == 0 else {
      throw KubernetesClusterError.ioFailure("secure its private directory")
    }
    guard
      Darwin.lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(0o077) == 0
    else {
      throw KubernetesClusterError.descriptorUnsafe
    }

    do {
      try excludeFromBackup(rootURL)
    } catch {
      throw KubernetesClusterError.ioFailure("exclude its private directory from backup")
    }
  }

  private func validateDescriptorFile(at url: URL) throws -> stat {
    var metadata = stat()
    guard Darwin.lstat(url.nativeContainersPOSIXPath, &metadata) == 0 else {
      throw KubernetesClusterError.descriptorUnsafe
    }
    guard
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1,
      metadata.st_mode & mode_t(0o077) == 0,
      metadata.st_size > 0,
      metadata.st_size <= Self.maximumDescriptorBytes
    else {
      throw KubernetesClusterError.descriptorUnsafe
    }
    return metadata
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private static func validate(_ descriptor: KubernetesClusterDescriptor) throws {
    guard
      descriptor.schemaVersion == KubernetesClusterDescriptor.currentSchemaVersion,
      descriptor.machine.hasStableCreationIdentity,
      !descriptor.machine.id.isEmpty,
      descriptor.machine.id.count <= LinuxMachineCreationRequest.maximumNameLength,
      descriptor.machine.id.range(
        of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#,
        options: .regularExpression
      ) != nil,
      !descriptor.machine.imageReference.isEmpty,
      !descriptor.machine.platform.isEmpty,
      descriptor.distribution == .current,
      descriptor.distribution.installScriptURL.scheme == "https",
      descriptor.distribution.installScriptURL.host == "raw.githubusercontent.com",
      descriptor.distribution.installScriptSHA256.count == 64,
      descriptor.distribution.installScriptSHA256.allSatisfy({
        $0.isHexDigit && !$0.isUppercase
      })
    else {
      throw KubernetesClusterError.descriptorInvalid
    }
  }

  private static func defaultRootURL(fileManager: FileManager) -> URL {
    let applicationSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    return
      applicationSupport
      .appending(path: "NativeContainers", directoryHint: .isDirectory)
      .appending(path: "Kubernetes", directoryHint: .isDirectory)
  }
}
