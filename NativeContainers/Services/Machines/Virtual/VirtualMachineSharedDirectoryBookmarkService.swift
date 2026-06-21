import Darwin
import Foundation

final class VirtualMachineSharedDirectoryAccess: @unchecked Sendable {
  let directories: [ResolvedVirtualMachineSharedDirectory]

  private let stateLock = NSLock()
  private var accessedURLs: [URL]

  init(
    directories: [ResolvedVirtualMachineSharedDirectory],
    accessedURLs: [URL]
  ) {
    self.directories = directories
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

struct VirtualMachineSharedDirectoryBookmarkService:
  VirtualMachineSharedDirectoryBookmarking
{
  func makeRecord(
    request: VirtualMachineSharedDirectoryRequest,
    canonicalGuestName: String
  ) throws -> VirtualMachineSharedDirectory {
    let sourceURL = request.sourceURL.standardizedFileURL
    let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    let identity = try validateDirectory(
      sourceURL,
      readOnly: request.readOnly,
      displayPath: sourceURL.path(percentEncoded: false)
    )
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if request.readOnly {
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
      throw VirtualMachineSharedDirectoryError.accessDenied(
        sourceURL.path(percentEncoded: false)
      )
    }

    return VirtualMachineSharedDirectory(
      id: UUID(),
      guestName: canonicalGuestName,
      bookmarkData: bookmarkData,
      lastKnownPath: sourceURL.path(percentEncoded: false),
      sourceIdentity: identity,
      readOnly: request.readOnly
    )
  }

  func resolve(
    _ directories: [VirtualMachineSharedDirectory]
  ) throws -> VirtualMachineSharedDirectoryAccess {
    var resolved: [ResolvedVirtualMachineSharedDirectory] = []
    var accessedURLs: [URL] = []

    do {
      for directory in directories {
        var isStale = false
        let sourceURL: URL
        do {
          sourceURL = try URL(
            resolvingBookmarkData: directory.bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
          )
        } catch {
          throw VirtualMachineSharedDirectoryError.staleBookmark(
            directory.guestName
          )
        }
        guard !isStale else {
          throw VirtualMachineSharedDirectoryError.staleBookmark(
            directory.guestName
          )
        }
        guard sourceURL.startAccessingSecurityScopedResource() else {
          throw VirtualMachineSharedDirectoryError.accessDenied(
            directory.lastKnownPath
          )
        }
        accessedURLs.append(sourceURL)

        let identity = try validateDirectory(
          sourceURL,
          readOnly: directory.readOnly,
          displayPath: directory.lastKnownPath
        )
        guard identity == directory.sourceIdentity else {
          throw VirtualMachineSharedDirectoryError.sourceIdentityChanged(
            directory.guestName
          )
        }
        resolved.append(
          ResolvedVirtualMachineSharedDirectory(
            id: directory.id,
            guestName: directory.guestName,
            sourceURL: sourceURL,
            sourceIdentity: identity,
            readOnly: directory.readOnly
          )
        )
      }
      return VirtualMachineSharedDirectoryAccess(
        directories: resolved,
        accessedURLs: accessedURLs
      )
    } catch {
      for url in accessedURLs {
        url.stopAccessingSecurityScopedResource()
      }
      throw error
    }
  }

  private func validateDirectory(
    _ url: URL,
    readOnly: Bool,
    displayPath: String
  ) throws -> VirtualMachineSharedDirectorySourceIdentity {
    guard url.isFileURL else {
      throw VirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
    }
    let values: URLResourceValues
    do {
      values = try url.resourceValues(
        forKeys: [
          .isDirectoryKey,
          .isSymbolicLinkKey,
          .isReadableKey,
          .isWritableKey,
        ]
      )
    } catch {
      throw VirtualMachineSharedDirectoryError.accessDenied(displayPath)
    }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw VirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
    }
    guard values.isReadable == true, readOnly || values.isWritable == true else {
      throw VirtualMachineSharedDirectoryError.accessDenied(displayPath)
    }

    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw VirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
    }
    return VirtualMachineSharedDirectorySourceIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }
}

typealias MacVirtualMachineSharedDirectoryAccess = VirtualMachineSharedDirectoryAccess
typealias MacVirtualMachineSharedDirectoryBookmarkService =
  VirtualMachineSharedDirectoryBookmarkService
typealias LinuxVirtualMachineSharedDirectoryAccess = VirtualMachineSharedDirectoryAccess
typealias LinuxVirtualMachineSharedDirectoryBookmarkService =
  VirtualMachineSharedDirectoryBookmarkService
