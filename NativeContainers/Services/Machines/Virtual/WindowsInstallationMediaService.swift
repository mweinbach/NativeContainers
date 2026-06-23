import CryptoKit
import Darwin
import Foundation

struct WindowsInstallationMediaCopyResult: Equatable, Sendable {
  let sha256: String
  let byteCount: UInt64
}

struct MountedDiskImage: Equatable, Sendable {
  let devicePath: String
  let mountURL: URL
  let volumeLabel: String
}

protocol DiskImageMounting: Sendable {
  func attach(_ imageURL: URL, readOnly: Bool) async throws -> MountedDiskImage
  func detach(_ image: MountedDiskImage) async throws
}

protocol WindowsInstallationMediaCopying: Sendable {
  func copy(from sourceURL: URL, to destinationURL: URL) async throws
    -> WindowsInstallationMediaCopyResult
}

protocol WindowsInstallationMediaInspecting: Sendable {
  func inspect(
    installationMediaURL: URL,
    sourceFilename: String,
    copy: WindowsInstallationMediaCopyResult
  ) async throws -> WindowsInstallationMediaMetadata
}

struct FileWindowsInstallationMediaCopier: WindowsInstallationMediaCopying {
  static let copyChunkSize = 4 * 1_024 * 1_024

  func copy(
    from requestedSourceURL: URL,
    to destinationURL: URL
  ) async throws -> WindowsInstallationMediaCopyResult {
    guard requestedSourceURL.isFileURL else {
      throw WindowsInstallationMediaError.nonFileMedia(requestedSourceURL)
    }
    guard requestedSourceURL.pathExtension.lowercased() == "iso" else {
      throw WindowsInstallationMediaError.unsupportedMedia(requestedSourceURL)
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
      throw WindowsInstallationMediaError.invalidMedia(sourceURL)
    }
    let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? input.close() }

    var initialMetadata = stat()
    guard Darwin.fstat(sourceDescriptor, &initialMetadata) == 0,
      initialMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    else {
      throw WindowsInstallationMediaError.invalidMedia(sourceURL)
    }
    guard initialMetadata.st_size > 0 else {
      throw WindowsInstallationMediaError.emptyMedia(sourceURL)
    }

    let destinationDescriptor = Darwin.open(
      destinationURL.path(percentEncoded: false),
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw WindowsInstallationMediaError.unableToCreateDestination(destinationURL)
    }
    let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
    var completed = false
    defer {
      try? output.close()
      if !completed {
        try? FileManager.default.removeItem(at: destinationURL)
      }
    }

    var hasher = SHA256()
    var copiedBytes: Int64 = 0
    while true {
      try Task.checkCancellation()
      guard let data = try input.read(upToCount: Self.copyChunkSize), !data.isEmpty else {
        break
      }
      try output.write(contentsOf: data)
      hasher.update(data: data)
      copiedBytes += Int64(data.count)
    }

    try Task.checkCancellation()
    guard copiedBytes == initialMetadata.st_size else {
      throw WindowsInstallationMediaError.incompleteCopy(
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
      throw WindowsInstallationMediaError.mediaChanged
    }

    try output.synchronize()
    completed = true
    return WindowsInstallationMediaCopyResult(
      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount: UInt64(copiedBytes)
    )
  }
}

struct DiskutilDiskImageMounter: DiskImageMounting {
  static let executableURL = URL(filePath: "/usr/sbin/diskutil")

  private let executor: any HostCommandExecuting

  init(executor: any HostCommandExecuting = FoundationHostCommandExecutor()) {
    self.executor = executor
  }

  func attach(_ imageURL: URL, readOnly: Bool) async throws -> MountedDiskImage {
    var arguments = ["image", "attach", "--plist", "--nobrowse"]
    if readOnly {
      arguments.append("--readOnly")
    }
    arguments.append(imageURL.path(percentEncoded: false))

    let result = try await executor.execute(
      executableURL: Self.executableURL,
      arguments: arguments,
      environment: nil,
      timeout: .seconds(120)
    )
    guard !result.outputWasTruncated else {
      throw WindowsInstallationMediaError.diskutilOutputTruncated
    }
    guard result.exitCode == 0 else {
      throw WindowsInstallationMediaError.attachFailed(
        Self.diagnostic(from: result)
      )
    }
    guard let data = result.standardOutput.data(using: .utf8),
      let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any],
      let entities = propertyList["system-entities"] as? [[String: Any]],
      let mountedEntity = entities.first(where: { $0["mount-point"] != nil }),
      let mountPath = mountedEntity["mount-point"] as? String,
      let devicePath =
        (entities.first?["dev-entry"] as? String)
        ?? (mountedEntity["dev-entry"] as? String)
    else {
      throw WindowsInstallationMediaError.invalidAttachResponse
    }

    let mountURL = URL(filePath: mountPath, directoryHint: .isDirectory)
    let label =
      (mountedEntity["volume-name"] as? String)
      ?? mountURL.lastPathComponent
    return MountedDiskImage(
      devicePath: devicePath,
      mountURL: mountURL,
      volumeLabel: label
    )
  }

  func detach(_ image: MountedDiskImage) async throws {
    let result = try await executor.execute(
      executableURL: Self.executableURL,
      arguments: ["image", "detach", image.devicePath],
      environment: nil,
      timeout: .seconds(120)
    )
    guard result.exitCode == 0 else {
      throw WindowsInstallationMediaError.detachFailed(
        Self.diagnostic(from: result)
      )
    }
  }

  private static func diagnostic(from result: HostCommandResult) -> String {
    String(
      [result.standardError, result.standardOutput]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .suffix(2_000)
    )
  }
}

struct DiskutilWindowsInstallationMediaInspector: WindowsInstallationMediaInspecting {
  private let mounter: any DiskImageMounting
  private let volumeInspector: WindowsInstallationMediaVolumeInspector

  init(
    mounter: any DiskImageMounting = DiskutilDiskImageMounter(),
    volumeInspector: WindowsInstallationMediaVolumeInspector =
      WindowsInstallationMediaVolumeInspector()
  ) {
    self.mounter = mounter
    self.volumeInspector = volumeInspector
  }

  func inspect(
    installationMediaURL: URL,
    sourceFilename: String,
    copy: WindowsInstallationMediaCopyResult
  ) async throws -> WindowsInstallationMediaMetadata {
    let image = try await mounter.attach(installationMediaURL, readOnly: true)
    do {
      let inspection = try volumeInspector.inspect(image.mountURL)
      try await mounter.detach(image)
      return WindowsInstallationMediaMetadata(
        sha256: copy.sha256,
        byteCount: copy.byteCount,
        volumeLabel: image.volumeLabel,
        architecture: .arm64,
        sourceFilename: sourceFilename,
        efiBootManagerPath: inspection.efiBootManagerPath,
        bootImagePath: inspection.bootImagePath,
        installImagePath: inspection.installImagePath
      )
    } catch {
      try? await mounter.detach(image)
      throw error
    }
  }
}

struct WindowsInstallationMediaVolumeInspection: Equatable, Sendable {
  let efiBootManagerPath: String
  let bootImagePath: String
  let installImagePath: String
}

struct WindowsInstallationMediaVolumeInspector: @unchecked Sendable {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func inspect(_ volumeURL: URL) throws -> WindowsInstallationMediaVolumeInspection {
    let bootManager = try resolve(
      components: ["efi", "boot", "bootaa64.efi"],
      in: volumeURL
    )
    try requireRegularNonemptyFile(bootManager, named: "efi/boot/bootaa64.efi")
    let machine = try portableExecutableMachine(at: bootManager)
    guard machine == 0xaa64 else {
      throw WindowsInstallationMediaError.unsupportedBootArchitecture(machine)
    }

    let bootImage = try resolve(components: ["sources", "boot.wim"], in: volumeURL)
    try requireRegularNonemptyFile(bootImage, named: "sources/boot.wim")
    let installImage = try resolve(
      components: ["sources", "install.wim"],
      in: volumeURL
    )
    try requireRegularNonemptyFile(installImage, named: "sources/install.wim")

    return WindowsInstallationMediaVolumeInspection(
      efiBootManagerPath: "efi/boot/bootaa64.efi",
      bootImagePath: "sources/boot.wim",
      installImagePath: "sources/install.wim"
    )
  }

  private func resolve(components: [String], in root: URL) throws -> URL {
    var candidate = root
    for component in components {
      let children = try fileManager.contentsOfDirectory(
        at: candidate,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: []
      )
      guard
        let child = children.first(where: {
          $0.lastPathComponent.compare(
            component,
            options: [.caseInsensitive, .literal]
          ) == .orderedSame
        })
      else {
        throw WindowsInstallationMediaError.missingRequiredFile(
          components.joined(separator: "/")
        )
      }
      candidate = child
    }
    return candidate
  }

  private func requireRegularNonemptyFile(_ url: URL, named name: String) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
      throw WindowsInstallationMediaError.invalidRequiredFile(name)
    }
  }

  private func portableExecutableMachine(at url: URL) throws -> UInt16 {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    guard let dosHeader = try file.read(upToCount: 64), dosHeader.count == 64,
      dosHeader[0] == 0x4d, dosHeader[1] == 0x5a
    else {
      throw WindowsInstallationMediaError.invalidPEBootManager
    }
    let peOffset = UInt64(littleEndianUInt32(in: dosHeader, at: 0x3c))
    try file.seek(toOffset: peOffset)
    guard let peHeader = try file.read(upToCount: 6), peHeader.count == 6,
      peHeader[0] == 0x50, peHeader[1] == 0x45,
      peHeader[2] == 0, peHeader[3] == 0
    else {
      throw WindowsInstallationMediaError.invalidPEBootManager
    }
    return UInt16(peHeader[4]) | (UInt16(peHeader[5]) << 8)
  }

  private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}

enum WindowsInstallationMediaError: LocalizedError, Equatable {
  case nonFileMedia(URL)
  case unsupportedMedia(URL)
  case invalidMedia(URL)
  case emptyMedia(URL)
  case unableToCreateDestination(URL)
  case incompleteCopy(expected: Int64, actual: Int64)
  case mediaChanged
  case diskutilOutputTruncated
  case attachFailed(String)
  case detachFailed(String)
  case invalidAttachResponse
  case missingRequiredFile(String)
  case invalidRequiredFile(String)
  case invalidPEBootManager
  case unsupportedBootArchitecture(UInt16)

  var errorDescription: String? {
    switch self {
    case .nonFileMedia(let url):
      "Windows installation media must be a local file: \(url.absoluteString)"
    case .unsupportedMedia(let url):
      "Windows installation media must be an ISO image: \(url.lastPathComponent)"
    case .invalidMedia(let url):
      "Windows installation media is not a readable regular file: \(url.lastPathComponent)"
    case .emptyMedia(let url):
      "Windows installation media is empty: \(url.lastPathComponent)"
    case .unableToCreateDestination(let url):
      "The Windows installation media destination could not be created: \(url.path)"
    case .incompleteCopy(let expected, let actual):
      "Windows installation media copy was incomplete (expected \(expected) bytes, copied \(actual))."
    case .mediaChanged:
      "Windows installation media changed while it was being copied."
    case .diskutilOutputTruncated:
      "diskutil returned an incomplete response while mounting Windows installation media."
    case .attachFailed(let diagnostic):
      "Windows installation media could not be mounted read-only: \(diagnostic)"
    case .detachFailed(let diagnostic):
      "Windows installation media could not be detached: \(diagnostic)"
    case .invalidAttachResponse:
      "diskutil did not report a mounted Windows installation volume."
    case .missingRequiredFile(let path):
      "The ISO is not Windows installation media because it is missing \(path)."
    case .invalidRequiredFile(let path):
      "The Windows installation ISO contains an invalid \(path)."
    case .invalidPEBootManager:
      "The Windows installation ISO contains an invalid ARM64 EFI boot manager."
    case .unsupportedBootArchitecture(let machine):
      "The Windows installation ISO is not ARM64 (PE machine 0x\(String(machine, radix: 16)))."
    }
  }
}
