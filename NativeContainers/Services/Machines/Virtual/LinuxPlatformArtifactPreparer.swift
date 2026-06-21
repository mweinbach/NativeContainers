import Darwin
import Foundation
@preconcurrency import Virtualization

struct LinuxPlatformArtifactURLs: Sendable {
  static let directoryName = "LinuxPlatform"
  static let efiVariableStoreFilename = "NVRAM"
  static let machineIdentifierFilename = "MachineIdentifier"
  static let installationMediaFilename = "Installation.iso"

  let directory: URL

  var efiVariableStore: URL {
    directory.appending(path: Self.efiVariableStoreFilename)
  }

  var machineIdentifier: URL {
    directory.appending(path: Self.machineIdentifierFilename)
  }

  var installationMedia: URL {
    directory.appending(path: Self.installationMediaFilename)
  }

  var all: [URL] {
    [efiVariableStore, machineIdentifier, installationMedia]
  }

  static var efiVariableStoreManifestPath: String {
    "\(directoryName)/\(efiVariableStoreFilename)"
  }

  static var machineIdentifierManifestPath: String {
    "\(directoryName)/\(machineIdentifierFilename)"
  }

  static var installationMediaManifestPath: String {
    "\(directoryName)/\(installationMediaFilename)"
  }
}

protocol LinuxPlatformArtifactPreparing: Sendable {
  func prepare(
    installationMediaURL: URL,
    destination: LinuxPlatformArtifactURLs
  ) async throws -> LinuxPlatformPreparationResult
}

protocol LinuxInstallationMediaCopying: Sendable {
  func copy(
    from sourceURL: URL,
    to destinationURL: URL
  ) async throws
}

protocol LinuxPlatformIdentityCreating: Sendable {
  func create(
    at destination: LinuxPlatformArtifactURLs
  ) throws -> LinuxPlatformPreparationResult
}

struct LinuxPlatformArtifactPreparer: LinuxPlatformArtifactPreparing {
  private let installationMediaCopier: any LinuxInstallationMediaCopying
  private let identityService: any LinuxPlatformIdentityCreating

  init(
    installationMediaCopier: any LinuxInstallationMediaCopying =
      FileLinuxInstallationMediaCopier(),
    identityService: any LinuxPlatformIdentityCreating =
      AppleLinuxPlatformIdentityService()
  ) {
    self.installationMediaCopier = installationMediaCopier
    self.identityService = identityService
  }

  func prepare(
    installationMediaURL: URL,
    destination: LinuxPlatformArtifactURLs
  ) async throws -> LinuxPlatformPreparationResult {
    try await installationMediaCopier.copy(
      from: installationMediaURL,
      to: destination.installationMedia
    )
    try Task.checkCancellation()
    return try identityService.create(at: destination)
  }
}

struct FileLinuxInstallationMediaCopier: LinuxInstallationMediaCopying {
  static let copyChunkSize = 4 * 1_024 * 1_024

  func copy(
    from requestedSourceURL: URL,
    to destinationURL: URL
  ) async throws {
    guard requestedSourceURL.isFileURL else {
      throw LinuxPlatformArtifactError.nonFileInstallationMedia(requestedSourceURL)
    }
    guard requestedSourceURL.pathExtension.lowercased() == "iso" else {
      throw LinuxPlatformArtifactError.unsupportedInstallationMedia(requestedSourceURL)
    }

    let sourceURL = requestedSourceURL.standardizedFileURL
    let startedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if startedSecurityScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let sourceDescriptor = Darwin.open(
      sourceURL.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard sourceDescriptor >= 0 else {
      throw LinuxPlatformArtifactError.invalidInstallationMedia(sourceURL)
    }
    let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? input.close() }

    var initialMetadata = stat()
    guard Darwin.fstat(sourceDescriptor, &initialMetadata) == 0,
      initialMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw LinuxPlatformArtifactError.invalidInstallationMedia(sourceURL)
    }
    guard initialMetadata.st_size > 0 else {
      throw LinuxPlatformArtifactError.emptyInstallationMedia(sourceURL)
    }

    let destinationDescriptor = Darwin.open(
      destinationURL.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw LinuxPlatformArtifactError.unableToCreateDestination(destinationURL)
    }
    let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
    defer { try? output.close() }

    var copiedBytes: Int64 = 0
    while true {
      try Task.checkCancellation()
      guard
        let data = try input.read(upToCount: Self.copyChunkSize),
        !data.isEmpty
      else {
        break
      }
      try output.write(contentsOf: data)
      copiedBytes += Int64(data.count)
    }

    try Task.checkCancellation()
    guard copiedBytes == initialMetadata.st_size else {
      throw LinuxPlatformArtifactError.incompleteCopy(
        expected: initialMetadata.st_size,
        actual: copiedBytes
      )
    }

    var finalMetadata = stat()
    guard Darwin.fstat(sourceDescriptor, &finalMetadata) == 0,
      finalMetadata.st_dev == initialMetadata.st_dev,
      finalMetadata.st_ino == initialMetadata.st_ino,
      finalMetadata.st_size == initialMetadata.st_size,
      finalMetadata.st_mtimespec.tv_sec == initialMetadata.st_mtimespec.tv_sec,
      finalMetadata.st_mtimespec.tv_nsec == initialMetadata.st_mtimespec.tv_nsec
    else {
      throw LinuxPlatformArtifactError.installationMediaChanged
    }
    try output.synchronize()
  }
}

struct AppleLinuxPlatformIdentityService: LinuxPlatformIdentityCreating {
  func create(
    at destination: LinuxPlatformArtifactURLs
  ) throws -> LinuxPlatformPreparationResult {
    let machineIdentifier = VZGenericMachineIdentifier()
    try machineIdentifier.dataRepresentation.write(
      to: destination.machineIdentifier,
      options: [.atomic]
    )
    _ = try VZEFIVariableStore(
      creatingVariableStoreAt: destination.efiVariableStore
    )

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.machineIdentifier.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.efiVariableStore.path
    )

    return LinuxPlatformPreparationResult(
      macAddress: VZMACAddress.randomLocallyAdministered().string
    )
  }
}

enum LinuxPlatformArtifactError: LocalizedError, Equatable {
  case nonFileInstallationMedia(URL)
  case unsupportedInstallationMedia(URL)
  case invalidInstallationMedia(URL)
  case emptyInstallationMedia(URL)
  case unableToCreateDestination(URL)
  case incompleteCopy(expected: Int64, actual: Int64)
  case installationMediaChanged
  case missingArtifact(String)

  var errorDescription: String? {
    switch self {
    case .nonFileInstallationMedia(let url):
      "Linux installation media must be a local file: \(url.absoluteString)"
    case .unsupportedInstallationMedia(let url):
      "Linux installation media must be an ISO image: \(url.lastPathComponent)"
    case .invalidInstallationMedia(let url):
      "Linux installation media is not a readable regular file: \(url.lastPathComponent)"
    case .emptyInstallationMedia(let url):
      "Linux installation media is empty: \(url.lastPathComponent)"
    case .unableToCreateDestination(let url):
      "The Linux installation media destination could not be created: \(url.path)"
    case .incompleteCopy(let expected, let actual):
      "Linux installation media copy was incomplete (expected \(expected) bytes, copied \(actual))."
    case .installationMediaChanged:
      "Linux installation media changed while it was being copied."
    case .missingArtifact(let filename):
      "Linux platform preparation did not create \(filename)."
    }
  }
}
