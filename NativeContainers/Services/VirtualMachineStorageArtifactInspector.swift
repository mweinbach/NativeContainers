import CryptoKit
import Darwin
import Foundation

protocol VirtualMachineStorageArtifactInspecting: Sendable {
  func inspect(at url: URL) throws -> VirtualMachineStorageArtifactIdentity
}

struct FileVirtualMachineStorageArtifactInspector:
  VirtualMachineStorageArtifactInspecting
{
  private static let allocationBlockBytes: UInt64 = 512
  private static let maximumDepth = 128
  private static let maximumEntryCount = 250_000

  func inspect(at url: URL) throws -> VirtualMachineStorageArtifactIdentity {
    try Task.checkCancellation()
    let candidate = url.standardizedFileURL
    let entryName = candidate.lastPathComponent
    guard
      candidate.isFileURL,
      !entryName.isEmpty,
      entryName != ".",
      entryName != "..",
      !entryName.contains("/"),
      !entryName.contains("\0")
    else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "the candidate name is invalid"
      )
    }

    let parent = candidate.deletingLastPathComponent()
    let parentDescriptor = Darwin.open(
      parent.path(percentEncoded: false),
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard parentDescriptor >= 0 else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "the candidate parent cannot be opened safely"
      )
    }
    defer { Darwin.close(parentDescriptor) }

    var parentMetadata = stat()
    guard
      Darwin.fstat(parentDescriptor, &parentMetadata) == 0,
      Self.fileType(parentMetadata.st_mode) == mode_t(S_IFDIR),
      parentMetadata.st_uid == Darwin.geteuid()
    else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "the candidate parent is not an app-owned directory"
      )
    }

    var rootMetadata = stat()
    let status = entryName.withCString {
      Darwin.fstatat(
        parentDescriptor,
        $0,
        &rootMetadata,
        AT_SYMLINK_NOFOLLOW
      )
    }
    guard status == 0 else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "the reviewed candidate no longer exists"
      )
    }

    var accumulator = try Accumulator(rootMetadata: rootMetadata)
    try inspectEntry(
      named: entryName,
      relativePath: ".",
      parentDescriptor: parentDescriptor,
      metadata: rootMetadata,
      depth: 0,
      rootDevice: rootMetadata.st_dev,
      accumulator: &accumulator
    )
    return accumulator.identity
  }

  private func inspectEntry(
    named name: String,
    relativePath: String,
    parentDescriptor: Int32,
    metadata: stat,
    depth: Int,
    rootDevice: dev_t,
    accumulator: inout Accumulator
  ) throws {
    try Task.checkCancellation()
    guard depth <= Self.maximumDepth else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "the candidate tree is too deep"
      )
    }
    try accumulator.record(
      metadata: metadata,
      relativePath: relativePath,
      rootDevice: rootDevice
    )
    guard Self.fileType(metadata.st_mode) == mode_t(S_IFDIR) else {
      return
    }

    let descriptor = name.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
    }
    guard descriptor >= 0 else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a reviewed directory changed while it was inspected"
      )
    }
    defer { Darwin.close(descriptor) }

    var openedMetadata = stat()
    guard
      Darwin.fstat(descriptor, &openedMetadata) == 0,
      openedMetadata.st_dev == metadata.st_dev,
      openedMetadata.st_ino == metadata.st_ino,
      Self.fileType(openedMetadata.st_mode) == mode_t(S_IFDIR)
    else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a reviewed directory was replaced while it was inspected"
      )
    }

    for childName in try directoryNames(descriptor: descriptor) {
      try Task.checkCancellation()
      var childMetadata = stat()
      let status = childName.withCString {
        Darwin.fstatat(
          descriptor,
          $0,
          &childMetadata,
          AT_SYMLINK_NOFOLLOW
        )
      }
      guard status == 0 else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "an entry changed while the candidate was inspected"
        )
      }
      let childRelativePath =
        relativePath == "." ? childName : "\(relativePath)/\(childName)"
      try inspectEntry(
        named: childName,
        relativePath: childRelativePath,
        parentDescriptor: descriptor,
        metadata: childMetadata,
        depth: depth + 1,
        rootDevice: rootDevice,
        accumulator: &accumulator
      )
    }
  }

  private func directoryNames(descriptor: Int32) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
      if duplicate >= 0 {
        Darwin.close(duplicate)
      }
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a candidate directory cannot be enumerated"
      )
    }
    defer { Darwin.closedir(directory) }

    var names: [String] = []
    errno = 0
    while let entry = Darwin.readdir(directory) {
      try Task.checkCancellation()
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(
          to: CChar.self,
          capacity: Int(MAXNAMLEN) + 1
        ) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "a candidate contains an invalid entry name"
        )
      }
      names.append(name)
    }
    guard errno == 0 else {
      throw VirtualMachineStorageReclamationError.unsafeArtifact(
        "a candidate directory changed while it was enumerated"
      )
    }
    return names.sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
  }

  private static func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }

  private struct Accumulator {
    let rootMetadata: stat
    let rootFileType: VirtualMachineStorageArtifactFileType
    var entryCount = 0
    var logicalBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var fingerprintData = Data()

    init(rootMetadata: stat) throws {
      self.rootMetadata = rootMetadata
      rootFileType = try Self.validatedFileType(rootMetadata)
    }

    mutating func record(
      metadata: stat,
      relativePath: String,
      rootDevice: dev_t
    ) throws {
      guard entryCount < FileVirtualMachineStorageArtifactInspector.maximumEntryCount else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate tree contains too many entries"
        )
      }
      guard metadata.st_dev == rootDevice else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate crosses a filesystem boundary"
        )
      }
      let type = try Self.validatedFileType(metadata)
      guard metadata.st_uid == Darwin.geteuid() else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate contains content owned by another user"
        )
      }
      guard metadata.st_size >= 0, metadata.st_blocks >= 0 else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate contains invalid filesystem metadata"
        )
      }
      if type == .regularFile, metadata.st_nlink != 1 {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate contains a hard-linked file"
        )
      }

      entryCount += 1
      if type == .regularFile {
        logicalBytes = try Self.adding(
          logicalBytes,
          UInt64(metadata.st_size)
        )
      }
      let allocation = try Self.multiplying(
        UInt64(metadata.st_blocks),
        FileVirtualMachineStorageArtifactInspector.allocationBlockBytes
      )
      allocatedBytes = try Self.adding(allocatedBytes, allocation)

      let line =
        [
          relativePath,
          type.rawValue,
          String(UInt64(metadata.st_dev)),
          String(UInt64(metadata.st_ino)),
          String(UInt64(metadata.st_mode)),
          String(UInt64(metadata.st_uid)),
          String(UInt64(metadata.st_nlink)),
          String(Int64(metadata.st_size)),
          String(Int64(metadata.st_blocks)),
          String(Int64(metadata.st_mtimespec.tv_sec)),
          String(Int64(metadata.st_mtimespec.tv_nsec)),
          String(Int64(metadata.st_ctimespec.tv_sec)),
          String(Int64(metadata.st_ctimespec.tv_nsec)),
        ].joined(separator: "\u{0}") + "\n"
      fingerprintData.append(contentsOf: line.utf8)
    }

    var identity: VirtualMachineStorageArtifactIdentity {
      VirtualMachineStorageArtifactIdentity(
        device: UInt64(rootMetadata.st_dev),
        inode: UInt64(rootMetadata.st_ino),
        fileType: rootFileType,
        ownerUserID: UInt32(rootMetadata.st_uid),
        linkCount: UInt64(rootMetadata.st_nlink),
        logicalBytes: logicalBytes,
        allocatedBytes: allocatedBytes,
        entryCount: entryCount,
        modificationSeconds: Int64(rootMetadata.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(rootMetadata.st_mtimespec.tv_nsec),
        statusChangeSeconds: Int64(rootMetadata.st_ctimespec.tv_sec),
        statusChangeNanoseconds: Int64(rootMetadata.st_ctimespec.tv_nsec),
        treeFingerprint: SHA256.hash(data: fingerprintData).map {
          String(format: "%02x", $0)
        }.joined()
      )
    }

    private static func validatedFileType(
      _ metadata: stat
    ) throws -> VirtualMachineStorageArtifactFileType {
      switch FileVirtualMachineStorageArtifactInspector.fileType(metadata.st_mode) {
      case mode_t(S_IFREG):
        return .regularFile
      case mode_t(S_IFDIR):
        return .directory
      default:
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate contains a symbolic link or special file"
        )
      }
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
      let (sum, overflow) = lhs.addingReportingOverflow(rhs)
      guard !overflow else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate byte count overflowed"
        )
      }
      return sum
    }

    private static func multiplying(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
      let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
      guard !overflow else {
        throw VirtualMachineStorageReclamationError.unsafeArtifact(
          "the candidate allocation overflowed"
        )
      }
      return product
    }
  }
}
