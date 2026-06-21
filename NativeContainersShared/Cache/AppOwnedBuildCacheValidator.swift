import CryptoKit
import Darwin
import Foundation

struct AppOwnedBuildCacheValidator: Sendable {
  private static let maximumEntryCount = 1_000_000
  private static let maximumByteCount: Int64 = 512 * 1_024 * 1_024 * 1_024
  private static let maximumIndexBytes: Int64 = 16 * 1_024 * 1_024
  private static let maximumLayoutBytes: Int64 = 4 * 1_024
  private static let maximumDescriptorBytes: Int64 = 64 * 1_024 * 1_024
  private static let maximumDirectoryDepth = 128

  func reviewExport(at source: URL) throws -> ReviewedAppOwnedBuildCacheExport {
    try validateDirectory(
      source,
      missing: .missingExport(source.path(percentEncoded: false)),
      allowsSharedRead: true
    )
    try secureExportRoot(source)
    let identity = try cacheDirectoryIdentity(source)
    let firstLayoutIdentity = try validateCacheLayout(source)
    let firstTreeIdentity = try inspectCacheTree(at: source)
    let layoutIdentity = try validateCacheLayout(source)
    let treeIdentity = try inspectCacheTree(at: source)
    guard try cacheDirectoryIdentity(source) == identity else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        source.path(percentEncoded: false)
      )
    }
    guard layoutIdentity == firstLayoutIdentity,
      treeIdentity == firstTreeIdentity
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        source.path(percentEncoded: false)
      )
    }
    return ReviewedAppOwnedBuildCacheExport(
      snapshot: treeIdentity.snapshot,
      directoryIdentity: identity,
      fingerprintSHA256: cacheFingerprint(
        directoryIdentity: identity,
        layoutIdentity: layoutIdentity,
        treeIdentity: treeIdentity
      )
    )
  }

  func validateCurrentCacheIfPresent(at currentURL: URL) throws -> Bool {
    guard fileExists(currentURL) else { return false }
    try validateDirectory(
      currentURL,
      missing: .unsafeCache(currentURL.path(percentEncoded: false))
    )
    _ = try validateCacheLayout(currentURL)
    _ = try measureCache(at: currentURL)
    return true
  }

  func validateOwnedCurrentBoundaryIfPresent(at currentURL: URL) throws -> Bool {
    var metadata = stat()
    if Darwin.lstat(currentURL.path(percentEncoded: false), &metadata) != 0 {
      if errno == ENOENT { return false }
      throw posixError("inspect cache entry", currentURL)
    }
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        currentURL.path(percentEncoded: false)
      )
    }
    return true
  }

  func validateDirectory(
    _ url: URL,
    missing: AppOwnedBuildCacheStoreError,
    allowsSharedRead: Bool = false
  ) throws {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0 else {
      if errno == ENOENT { throw missing }
      throw posixError("inspect directory", url)
    }
    let unsafePermissions: mode_t = allowsSharedRead ? 0o022 : 0o077
    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & unsafePermissions == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
  }

  func cacheDirectoryIdentity(
    _ url: URL
  ) throws -> AppOwnedBuildCacheDirectoryIdentity {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
    return AppOwnedBuildCacheDirectoryIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      owner: metadata.st_uid,
      permissions: UInt16(metadata.st_mode & 0o777)
    )
  }

  func measureCache(at root: URL) throws -> AppOwnedBuildCacheSnapshot {
    try inspectCacheTree(at: root).snapshot
  }

  private func validateCacheLayout(_ root: URL) throws -> AppOwnedBuildCacheLayoutIdentity {
    let layoutURL = root.appending(path: "oci-layout", directoryHint: .notDirectory)
    let layoutData = try readValidatedFile(layoutURL, maximumBytes: Self.maximumLayoutBytes)
    let layout = try decode(
      AppOwnedBuildCacheOCILayout.self,
      from: layoutData,
      path: layoutURL
    )
    guard layout.imageLayoutVersion == "1.0.0" else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        layoutURL.path(percentEncoded: false)
      )
    }

    let indexURL = root.appending(path: "index.json", directoryHint: .notDirectory)
    let indexData = try readValidatedFile(indexURL, maximumBytes: Self.maximumIndexBytes)
    let index = try decode(AppOwnedBuildCacheOCIIndex.self, from: indexData, path: indexURL)
    guard index.schemaVersion == 2, !index.manifests.isEmpty else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        indexURL.path(percentEncoded: false)
      )
    }

    let blobs = root.appending(path: "blobs", directoryHint: .isDirectory)
    try validateDirectory(
      blobs,
      missing: .unsafeCache(blobs.path(percentEncoded: false)),
      allowsSharedRead: true
    )
    for descriptor in index.manifests {
      try validateDescriptor(descriptor, root: root)
    }
    return AppOwnedBuildCacheLayoutIdentity(
      layoutSHA256: Self.sha256(layoutData),
      indexSHA256: Self.sha256(indexData)
    )
  }

  private func cacheFingerprint(
    directoryIdentity: AppOwnedBuildCacheDirectoryIdentity,
    layoutIdentity: AppOwnedBuildCacheLayoutIdentity,
    treeIdentity: AppOwnedBuildCacheTreeIdentity
  ) -> String {
    let material = [
      "nativecontainers-cache-handoff-v1",
      String(directoryIdentity.device),
      String(directoryIdentity.inode),
      String(directoryIdentity.owner),
      String(directoryIdentity.permissions),
      layoutIdentity.layoutSHA256,
      layoutIdentity.indexSHA256,
      treeIdentity.metadataSHA256,
      String(treeIdentity.snapshot.byteCount),
      String(treeIdentity.snapshot.entryCount),
    ].joined(separator: "\n")
    return Self.sha256(Data(material.utf8))
  }

  private func validateDescriptor(
    _ descriptor: AppOwnedBuildCacheOCIDescriptor,
    root: URL
  ) throws {
    let prefix = "sha256:"
    guard descriptor.digest.hasPrefix(prefix), descriptor.size > 0 else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        root.appending(path: "index.json").path(percentEncoded: false)
      )
    }
    let digest = String(descriptor.digest.dropFirst(prefix.count))
    guard digest.count == 64,
      digest.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(descriptor.digest)
    }
    let blob =
      root
      .appending(path: "blobs", directoryHint: .isDirectory)
      .appending(path: "sha256", directoryHint: .isDirectory)
      .appending(path: digest, directoryHint: .notDirectory)
    let data = try readValidatedFile(blob, maximumBytes: Self.maximumDescriptorBytes)
    guard Int64(data.count) == descriptor.size, Self.sha256(data) == digest else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(blob.path(percentEncoded: false))
    }
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data,
    path: URL
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw AppOwnedBuildCacheStoreError.unsafeCache(path.path(percentEncoded: false))
    }
  }

  private func readValidatedFile(_ url: URL, maximumBytes: Int64) throws -> Data {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
      }
      throw posixError("open cache metadata", url)
    }
    defer { Darwin.close(descriptor) }

    var metadataBefore = stat()
    guard Darwin.fstat(descriptor, &metadataBefore) == 0,
      metadataBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadataBefore.st_uid == geteuid(),
      metadataBefore.st_nlink == 1,
      metadataBefore.st_size > 0,
      metadataBefore.st_size <= maximumBytes,
      metadataBefore.st_mode & 0o022 == 0
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }

    var data = Data()
    data.reserveCapacity(Int(metadataBefore.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError("read cache metadata", url)
      }
      guard Int64(data.count) + Int64(count) <= maximumBytes else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    var metadataAfter = stat()
    var pathMetadata = stat()
    guard Darwin.fstat(descriptor, &metadataAfter) == 0,
      Darwin.lstat(url.path(percentEncoded: false), &pathMetadata) == 0,
      metadataAfter.st_dev == metadataBefore.st_dev,
      metadataAfter.st_ino == metadataBefore.st_ino,
      metadataAfter.st_mode == metadataBefore.st_mode,
      metadataAfter.st_uid == metadataBefore.st_uid,
      metadataAfter.st_nlink == metadataBefore.st_nlink,
      metadataAfter.st_size == metadataBefore.st_size,
      metadataAfter.st_mtimespec.tv_sec == metadataBefore.st_mtimespec.tv_sec,
      metadataAfter.st_mtimespec.tv_nsec == metadataBefore.st_mtimespec.tv_nsec,
      pathMetadata.st_dev == metadataAfter.st_dev,
      pathMetadata.st_ino == metadataAfter.st_ino,
      Int64(data.count) == metadataBefore.st_size
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(url.path(percentEncoded: false))
    }
    return data
  }

  private func secureExportRoot(_ url: URL) throws {
    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid()
    else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        url.path(percentEncoded: false)
      )
    }
    guard metadata.st_mode & 0o777 != 0o700 else { return }
    guard Darwin.chmod(url.path(percentEncoded: false), 0o700) == 0 else {
      throw posixError("secure cache export", url)
    }
  }

  private func inspectCacheTree(at root: URL) throws -> AppOwnedBuildCacheTreeIdentity {
    var byteCount: Int64 = 0
    var entryCount = 0
    var hasher = SHA256()
    try inspectCacheDirectory(
      root,
      relativePath: "",
      depth: 0,
      byteCount: &byteCount,
      entryCount: &entryCount,
      hasher: &hasher
    )
    return AppOwnedBuildCacheTreeIdentity(
      snapshot: AppOwnedBuildCacheSnapshot(
        byteCount: byteCount,
        entryCount: entryCount
      ),
      metadataSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }

  private func inspectCacheDirectory(
    _ directory: URL,
    relativePath: String,
    depth: Int,
    byteCount: inout Int64,
    entryCount: inout Int,
    hasher: inout SHA256
  ) throws {
    guard depth <= Self.maximumDirectoryDepth else {
      throw AppOwnedBuildCacheStoreError.unsafeCache(
        directory.path(percentEncoded: false)
      )
    }
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted {
        $0.lastPathComponent.utf8.lexicographicallyPrecedes(
          $1.lastPathComponent.utf8
        )
      }
    } catch {
      throw cocoaError("enumerate cache", directory, error)
    }

    for entry in entries {
      entryCount += 1
      guard entryCount <= Self.maximumEntryCount else {
        throw AppOwnedBuildCacheStoreError.tooManyEntries
      }
      let name = entry.lastPathComponent
      let entryRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
      var metadata = stat()
      guard Darwin.lstat(entry.path(percentEncoded: false), &metadata) == 0,
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o022 == 0
      else {
        throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
      }

      var record = Data()
      appendFingerprintString(entryRelativePath, to: &record)
      appendFingerprintInteger(UInt64(metadata.st_mode), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_dev), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_ino), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_uid), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_nlink), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_size)), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_blocks)), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_mtimespec.tv_sec)), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_mtimespec.tv_nsec), to: &record)
      appendFingerprintInteger(UInt64(bitPattern: Int64(metadata.st_ctimespec.tv_sec)), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_ctimespec.tv_nsec), to: &record)
      appendFingerprintInteger(UInt64(metadata.st_flags), to: &record)
      hasher.update(data: record)

      switch metadata.st_mode & mode_t(S_IFMT) {
      case mode_t(S_IFDIR):
        try inspectCacheDirectory(
          entry,
          relativePath: entryRelativePath,
          depth: depth + 1,
          byteCount: &byteCount,
          entryCount: &entryCount,
          hasher: &hasher
        )
      case mode_t(S_IFREG):
        guard metadata.st_nlink == 1 else {
          throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
        }
        byteCount = try adding(byteCount, Int64(metadata.st_blocks) * 512)
        guard byteCount <= Self.maximumByteCount else {
          throw AppOwnedBuildCacheStoreError.tooLarge
        }
      default:
        throw AppOwnedBuildCacheStoreError.unsafeCache(entry.path(percentEncoded: false))
      }
    }
  }

  private func appendFingerprintString(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    appendFingerprintInteger(UInt64(bytes.count), to: &data)
    data.append(bytes)
  }

  private func appendFingerprintInteger(_ value: UInt64, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { bytes in
      data.append(contentsOf: bytes)
    }
  }

  private func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw AppOwnedBuildCacheStoreError.tooLarge }
    return value
  }

  private func fileExists(_ url: URL) -> Bool {
    var metadata = stat()
    return Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0
  }

  private func posixError(
    _ operation: String,
    _ url: URL,
    code: Int32 = errno
  ) -> AppOwnedBuildCacheStoreError {
    AppOwnedBuildCacheStoreError.ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: code
    )
  }

  private func cocoaError(
    _ operation: String,
    _ url: URL,
    _ error: any Error
  ) -> AppOwnedBuildCacheStoreError {
    AppOwnedBuildCacheStoreError.ioFailure(
      operation: operation,
      path: url.path(percentEncoded: false),
      code: Int32((error as NSError).code)
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct AppOwnedBuildCacheOCILayout: Decodable {
  let imageLayoutVersion: String
}

private struct AppOwnedBuildCacheOCIIndex: Decodable {
  let schemaVersion: Int
  let manifests: [AppOwnedBuildCacheOCIDescriptor]
}

private struct AppOwnedBuildCacheOCIDescriptor: Decodable {
  let digest: String
  let size: Int64
}
