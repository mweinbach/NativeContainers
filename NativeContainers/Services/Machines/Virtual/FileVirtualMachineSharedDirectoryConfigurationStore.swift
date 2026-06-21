import Darwin
import Foundation

struct FileVirtualMachineSharedDirectoryConfigurationStore:
  VirtualMachineSharedDirectoryConfigurationStoring,
  @unchecked Sendable
{
  static let filename = "SharedDirectories.json"
  static let maximumFileSize = 1_048_576
  static let maximumBookmarkSize = 65_536
  static let maximumDirectoryCount = 128

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func load(
    from bundleURL: URL
  ) throws -> VirtualMachineSharedDirectoryConfiguration {
    let url = bundleURL.appending(path: Self.filename)
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      if errno == ENOENT {
        return .empty
      }
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the configuration file cannot be opened safely"
      )
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_mode & 0o077 == 0,
      metadata.st_uid == Darwin.geteuid(),
      metadata.st_nlink == 1,
      metadata.st_size >= 0,
      metadata.st_size <= Self.maximumFileSize
    else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the configuration file is not a private bounded regular file"
      )
    }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
    guard data.count <= Self.maximumFileSize else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the configuration file is too large"
      )
    }
    let configuration: VirtualMachineSharedDirectoryConfiguration
    do {
      configuration = try JSONDecoder().decode(
        VirtualMachineSharedDirectoryConfiguration.self,
        from: data
      )
    } catch {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the configuration file is not valid JSON"
      )
    }
    try validate(configuration)
    return configuration
  }

  func save(
    _ configuration: VirtualMachineSharedDirectoryConfiguration,
    to bundleURL: URL
  ) throws {
    try validate(configuration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    guard data.count <= Self.maximumFileSize else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the configuration file is too large"
      )
    }

    let finalURL = bundleURL.appending(path: Self.filename)
    let stagingURL = bundleURL.appending(
      path: ".SharedDirectories-\(UUID().uuidString.lowercased()).partial"
    )
    let stagingPath = stagingURL.path(percentEncoded: false)
    let descriptor = Darwin.open(
      stagingPath,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "a private staging file cannot be created"
      )
    }

    var shouldRemoveStagingFile = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveStagingFile {
        try? fileManager.removeItem(at: stagingURL)
      }
    }

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
          throw VirtualMachineSharedDirectoryError.invalidStore(
            "the private staging file cannot be written"
          )
        }
        offset += written
      }
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the private staging file cannot be synchronized"
      )
    }
    guard
      Darwin.rename(
        stagingPath,
        finalURL.path(percentEncoded: false)
      ) == 0
    else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the shared-folder configuration cannot be committed"
      )
    }
    shouldRemoveStagingFile = false
    try syncDirectory(bundleURL)
  }

  private func validate(
    _ configuration: VirtualMachineSharedDirectoryConfiguration
  ) throws {
    guard
      configuration.schemaVersion
        == VirtualMachineSharedDirectoryConfiguration.currentSchemaVersion
    else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "schema version \(configuration.schemaVersion) is unsupported"
      )
    }
    guard configuration.directories.count <= Self.maximumDirectoryCount else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "too many shared folders are configured"
      )
    }
    guard Set(configuration.directories.map(\.id)).count == configuration.directories.count
    else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "shared-folder identifiers are not unique"
      )
    }

    var names = Set<String>()
    for directory in configuration.directories {
      guard !directory.guestName.isEmpty,
        !directory.lastKnownPath.isEmpty,
        !directory.bookmarkData.isEmpty,
        directory.bookmarkData.count <= Self.maximumBookmarkSize
      else {
        throw VirtualMachineSharedDirectoryError.invalidStore(
          "a shared-folder record is incomplete or too large"
        )
      }
      let name = VirtualMachineSharedDirectoryNameNormalizer.normalized(
        directory.guestName
      )
      guard names.insert(name).inserted else {
        throw VirtualMachineSharedDirectoryError.invalidStore(
          "shared-folder names are not unique"
        )
      }
    }
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the virtual-machine bundle cannot be opened safely"
      )
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw VirtualMachineSharedDirectoryError.invalidStore(
        "the virtual-machine bundle cannot be synchronized"
      )
    }
  }
}

typealias FileMacVirtualMachineSharedDirectoryConfigurationStore =
  FileVirtualMachineSharedDirectoryConfigurationStore
typealias FileLinuxVirtualMachineSharedDirectoryConfigurationStore =
  FileVirtualMachineSharedDirectoryConfigurationStore
