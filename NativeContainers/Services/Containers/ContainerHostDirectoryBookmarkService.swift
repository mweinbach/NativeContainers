import ContainerResource
import Darwin
import Foundation

final class ContainerHostDirectoryAccess: @unchecked Sendable {
  let mounts: [Filesystem]

  private let stateLock = NSLock()
  private var accessedURLs: [URL]

  init(mounts: [Filesystem], accessedURLs: [URL]) {
    self.mounts = mounts
    self.accessedURLs = accessedURLs
  }

  func release() {
    let urls = stateLock.withLock {
      let urls = accessedURLs
      accessedURLs.removeAll()
      return urls
    }
    for url in urls {
      url.stopAccessingSecurityScopedResource()
    }
  }

  deinit {
    release()
  }
}

protocol ContainerHostDirectoryBookmarking: Sendable {
  func review(_ request: ContainerHostDirectoryReviewRequest) throws -> ContainerHostDirectoryMount
  func resolve(_ mounts: [ContainerHostDirectoryMount]) throws -> ContainerHostDirectoryAccess
}

struct ContainerHostDirectoryBookmarkService: ContainerHostDirectoryBookmarking {
  func review(
    _ request: ContainerHostDirectoryReviewRequest
  ) throws -> ContainerHostDirectoryMount {
    let scopedURL = request.sourceURL
    let selectedPath = scopedURL.nativeContainersPOSIXPath
    let selectedIdentity = try directoryIdentityWithoutFollowingLeaf(
      selectedPath,
      displayPath: selectedPath
    )
    let didStartAccess = scopedURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        scopedURL.stopAccessingSecurityScopedResource()
      }
    }

    let sourceURL = try canonicalDirectoryURL(
      for: selectedPath,
      displayPath: selectedPath
    )
    let displayPath = sourceURL.nativeContainersPOSIXPath
    let identity = try validateDirectory(
      sourceURL,
      readOnly: request.isReadOnly,
      displayPath: selectedPath
    )
    guard identity == selectedIdentity else {
      throw ContainerHostDirectoryError.sourceIdentityChanged(selectedPath)
    }
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if request.isReadOnly {
      options.insert(.securityScopeAllowOnlyReadAccess)
    }

    let bookmarkData: Data
    do {
      bookmarkData = try sourceURL.bookmarkData(
        options: options,
        includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
        relativeTo: nil
      )
    } catch {
      throw ContainerHostDirectoryError.accessDenied(displayPath)
    }

    return try ContainerHostDirectoryMount(
      bookmarkData: bookmarkData,
      lastKnownPath: displayPath,
      sourceIdentity: identity,
      containerPath: request.containerPath,
      isReadOnly: request.isReadOnly
    )
  }

  func resolve(
    _ mounts: [ContainerHostDirectoryMount]
  ) throws -> ContainerHostDirectoryAccess {
    var filesystems: [Filesystem] = []
    var accessedURLs: [URL] = []

    do {
      for mount in mounts {
        var isStale = false
        let scopedURL: URL
        do {
          scopedURL = try URL(
            resolvingBookmarkData: mount.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
          )
        } catch {
          throw ContainerHostDirectoryError.staleBookmark(mount.lastKnownPath)
        }
        guard !isStale else {
          throw ContainerHostDirectoryError.staleBookmark(mount.lastKnownPath)
        }
        guard scopedURL.startAccessingSecurityScopedResource() else {
          throw ContainerHostDirectoryError.accessDenied(mount.lastKnownPath)
        }
        accessedURLs.append(scopedURL)

        let selectedPath = scopedURL.nativeContainersPOSIXPath
        let selectedIdentity = try directoryIdentityWithoutFollowingLeaf(
          selectedPath,
          displayPath: mount.lastKnownPath
        )
        let sourceURL = try canonicalDirectoryURL(
          for: selectedPath,
          displayPath: mount.lastKnownPath
        )
        let identity = try validateDirectory(
          sourceURL,
          readOnly: mount.isReadOnly,
          displayPath: mount.lastKnownPath
        )
        guard identity == selectedIdentity else {
          throw ContainerHostDirectoryError.sourceIdentityChanged(mount.lastKnownPath)
        }
        guard identity == mount.sourceIdentity else {
          throw ContainerHostDirectoryError.sourceIdentityChanged(mount.lastKnownPath)
        }

        filesystems.append(
          Filesystem.virtiofs(
            source: sourceURL.nativeContainersPOSIXPath,
            destination: mount.containerPath,
            options: mount.isReadOnly ? ["ro"] : []
          )
        )
      }

      return ContainerHostDirectoryAccess(
        mounts: filesystems,
        accessedURLs: accessedURLs
      )
    } catch {
      for url in accessedURLs {
        url.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  private func directoryIdentityWithoutFollowingLeaf(
    _ path: String,
    displayPath: String
  ) throws -> ContainerHostDirectorySourceIdentity {
    guard path != "/" else {
      throw ContainerHostDirectoryError.rootDirectoryNotAllowed
    }

    var metadata = stat()
    guard Darwin.lstat(path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw ContainerHostDirectoryError.invalidDirectory(displayPath)
    }

    return ContainerHostDirectorySourceIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }

  private func canonicalDirectoryURL(
    for path: String,
    displayPath: String
  ) throws -> URL {
    guard let resolvedPath = path.withCString({ Darwin.realpath($0, nil) }) else {
      throw ContainerHostDirectoryError.invalidDirectory(displayPath)
    }
    defer { Darwin.free(resolvedPath) }

    let canonicalPath = String(cString: resolvedPath)
    guard canonicalPath != "/" else {
      throw ContainerHostDirectoryError.rootDirectoryNotAllowed
    }
    return URL(fileURLWithPath: canonicalPath, isDirectory: true)
  }

  private func validateDirectory(
    _ url: URL,
    readOnly: Bool,
    displayPath: String
  ) throws -> ContainerHostDirectorySourceIdentity {
    guard url.isFileURL else {
      throw ContainerHostDirectoryError.invalidDirectory(displayPath)
    }
    let path = url.nativeContainersPOSIXPath
    guard path != "/" else {
      throw ContainerHostDirectoryError.rootDirectoryNotAllowed
    }

    let descriptor = try openDirectoryWithoutFollowingLinks(path, displayPath: displayPath)
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw ContainerHostDirectoryError.invalidDirectory(displayPath)
    }

    var requiredAccess = R_OK | X_OK
    if !readOnly {
      requiredAccess |= W_OK
    }
    guard Darwin.access(path, requiredAccess) == 0 else {
      throw ContainerHostDirectoryError.accessDenied(displayPath)
    }

    return ContainerHostDirectorySourceIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }

  private func openDirectoryWithoutFollowingLinks(
    _ path: String,
    displayPath: String
  ) throws -> Int32 {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty else {
      throw ContainerHostDirectoryError.rootDirectoryNotAllowed
    }

    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw ContainerHostDirectoryError.accessDenied(displayPath)
    }

    for component in components {
      let next = String(component).withCString {
        Darwin.openat(
          descriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
      }
      guard next >= 0 else {
        Darwin.close(descriptor)
        throw ContainerHostDirectoryError.invalidDirectory(displayPath)
      }
      Darwin.close(descriptor)
      descriptor = next
    }
    return descriptor
  }
}
