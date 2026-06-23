import Darwin
import Foundation

protocol NativeRuntimeMigrationPublishing: Sendable {
  func synchronizeStagedTree(at stagingRootURL: URL) throws
  func publish(stagingRootURL: URL, destinationRootURL: URL) throws
  func synchronizeParent(of destinationRootURL: URL) throws
}

struct AtomicNativeRuntimeMigrationPublisher: NativeRuntimeMigrationPublishing {
  func synchronizeStagedTree(at stagingRootURL: URL) throws {
    let descriptor = Darwin.open(
      stagingRootURL.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not open the staged migration tree."
      )
    }
    defer { Darwin.close(descriptor) }
    try synchronizeNode(descriptor: descriptor, displayPath: stagingRootURL.path)
  }

  func publish(stagingRootURL: URL, destinationRootURL: URL) throws {
    guard
      Darwin.renameatx_np(
        AT_FDCWD,
        stagingRootURL.nativeContainersPOSIXPath,
        AT_FDCWD,
        destinationRootURL.nativeContainersPOSIXPath,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Exclusive rename failed with errno \(errno)."
      )
    }
  }

  func synchronizeParent(of destinationRootURL: URL) throws {
    let parent = destinationRootURL.deletingLastPathComponent()
    let descriptor = Darwin.open(
      parent.nativeContainersPOSIXPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not open the destination parent."
      )
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not synchronize the destination parent."
      )
    }
  }

  private func synchronizeNode(
    descriptor: Int32,
    displayPath: String
  ) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not inspect \(displayPath)."
      )
    }
    let kind = metadata.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFDIR) {
      for name in try directoryEntryNames(
        descriptor: descriptor,
        displayPath: displayPath
      ) {
        let child = Darwin.openat(
          descriptor,
          name,
          O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard child >= 0 else {
          throw NativeRuntimeMigrationError.publishFailed(
            "Could not open \(displayPath)/\(name)."
          )
        }
        do {
          try synchronizeNode(
            descriptor: child,
            displayPath: displayPath + "/" + name
          )
        } catch {
          Darwin.close(child)
          throw error
        }
        Darwin.close(child)
      }
    } else if kind != mode_t(S_IFREG) {
      throw NativeRuntimeMigrationError.publishFailed(
        "The staged tree contains a special file at \(displayPath)."
      )
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not synchronize \(displayPath)."
      )
    }
  }

  private func directoryEntryNames(
    descriptor: Int32,
    displayPath: String
  ) throws -> [String] {
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw NativeRuntimeMigrationError.publishFailed(
        "Could not enumerate \(displayPath)."
      )
    }
    defer { Darwin.closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = Darwin.readdir(directory) else {
        guard errno == 0 else {
          throw NativeRuntimeMigrationError.publishFailed(
            "Could not enumerate \(displayPath)."
          )
        }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(entry.pointee.d_namlen) + 1
        ) {
          String(cString: $0)
        }
      }
      if name != "." && name != ".." {
        names.append(name)
      }
    }
    return names.sorted()
  }
}
