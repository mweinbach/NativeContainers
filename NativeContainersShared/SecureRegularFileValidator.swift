import Darwin
import Foundation

struct SecureRegularFileIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let permissions: UInt16
  let owner: UInt32
  let linkCount: UInt64
  let modificationSeconds: Int64
  let modificationNanoseconds: Int64
}

enum SecureRegularFileValidationError: Error, Equatable, Sendable {
  case invalidComponent(String)
  case missing(String)
  case unsafeDirectory(String)
  case unsafeFile(String)
}

enum SecureRegularFileValidator {
  static func validate(
    rootDirectory: URL,
    directoryName: String,
    fileName: String,
    expectedOwner: uid_t = geteuid()
  ) throws -> SecureRegularFileIdentity {
    try withValidatedFileDescriptor(
      rootDirectory: rootDirectory,
      directoryName: directoryName,
      fileName: fileName,
      expectedOwner: expectedOwner
    ) { _, identity in
      identity
    }
  }

  static func withValidatedFileDescriptor<T>(
    rootDirectory: URL,
    directoryName: String,
    fileName: String,
    expectedOwner: uid_t = geteuid(),
    _ body: (Int32, SecureRegularFileIdentity) throws -> T
  ) throws -> T {
    try validateComponent(directoryName)
    try validateComponent(fileName)

    let rootPath = rootDirectory.standardizedFileURL.path(percentEncoded: false)
    let rootDescriptor = try openDirectory(
      path: rootPath,
      relativeTo: AT_FDCWD,
      expectedOwner: expectedOwner
    )
    defer { Darwin.close(rootDescriptor) }

    let directoryDescriptor = try openDirectory(
      path: directoryName,
      relativeTo: rootDescriptor,
      expectedOwner: expectedOwner
    )
    defer { Darwin.close(directoryDescriptor) }

    let descriptor = fileName.withCString {
      Darwin.openat(
        directoryDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
    }
    guard descriptor >= 0 else {
      let fullPath =
        rootDirectory
        .appending(path: directoryName, directoryHint: .isDirectory)
        .appending(path: fileName, directoryHint: .notDirectory)
        .path(percentEncoded: false)
      if errno == ENOENT {
        throw SecureRegularFileValidationError.missing(fullPath)
      }
      throw SecureRegularFileValidationError.unsafeFile(fullPath)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw SecureRegularFileValidationError.unsafeFile(fileName)
    }
    guard
      fileType(metadata.st_mode) == mode_t(S_IFREG),
      metadata.st_uid == expectedOwner,
      metadata.st_nlink == 1,
      metadata.st_size > 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      throw SecureRegularFileValidationError.unsafeFile(fileName)
    }

    let identity = SecureRegularFileIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      size: Int64(metadata.st_size),
      permissions: UInt16(metadata.st_mode & 0o7777),
      owner: UInt32(metadata.st_uid),
      linkCount: UInt64(metadata.st_nlink),
      modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
    )
    return try body(descriptor, identity)
  }

  private static func validateComponent(_ component: String) throws {
    guard
      !component.isEmpty,
      component != ".",
      component != "..",
      !component.contains("/"),
      !component.contains("\0")
    else {
      throw SecureRegularFileValidationError.invalidComponent(component)
    }
  }

  private static func openDirectory(
    path: String,
    relativeTo parentDescriptor: Int32,
    expectedOwner: uid_t
  ) throws -> Int32 {
    let descriptor = path.withCString {
      Darwin.openat(
        parentDescriptor,
        $0,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
    }
    guard descriptor >= 0 else {
      if errno == ENOENT {
        throw SecureRegularFileValidationError.missing(path)
      }
      throw SecureRegularFileValidationError.unsafeDirectory(path)
    }

    var metadata = stat()
    guard
      Darwin.fstat(descriptor, &metadata) == 0,
      fileType(metadata.st_mode) == mode_t(S_IFDIR),
      metadata.st_uid == expectedOwner,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    else {
      Darwin.close(descriptor)
      throw SecureRegularFileValidationError.unsafeDirectory(path)
    }
    return descriptor
  }

  private static func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }
}
