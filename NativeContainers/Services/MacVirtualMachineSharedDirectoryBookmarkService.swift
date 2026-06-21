import Darwin
import Foundation

final class MacVirtualMachineSharedDirectoryAccess: @unchecked Sendable {
  let directories: [ResolvedMacVirtualMachineSharedDirectory]

  private let stateLock = NSLock()
  private var accessedURLs: [URL]

  init(
    directories: [ResolvedMacVirtualMachineSharedDirectory],
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

struct MacVirtualMachineSharedDirectoryBookmarkService:
  MacVirtualMachineSharedDirectoryBookmarking
{
  func makeRecord(
    request: MacVirtualMachineSharedDirectoryRequest,
    canonicalGuestName: String
  ) throws -> MacVirtualMachineSharedDirectory {
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
      throw MacVirtualMachineSharedDirectoryError.accessDenied(
        sourceURL.path(percentEncoded: false)
      )
    }

    return MacVirtualMachineSharedDirectory(
      id: UUID(),
      guestName: canonicalGuestName,
      bookmarkData: bookmarkData,
      lastKnownPath: sourceURL.path(percentEncoded: false),
      sourceIdentity: identity,
      readOnly: request.readOnly
    )
  }

  func resolve(
    _ directories: [MacVirtualMachineSharedDirectory]
  ) throws -> MacVirtualMachineSharedDirectoryAccess {
    var resolved: [ResolvedMacVirtualMachineSharedDirectory] = []
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
          throw MacVirtualMachineSharedDirectoryError.staleBookmark(
            directory.guestName
          )
        }
        guard sourceURL.startAccessingSecurityScopedResource() else {
          throw MacVirtualMachineSharedDirectoryError.accessDenied(
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
          throw MacVirtualMachineSharedDirectoryError.sourceIdentityChanged(
            directory.guestName
          )
        }
        resolved.append(
          ResolvedMacVirtualMachineSharedDirectory(
            id: directory.id,
            guestName: directory.guestName,
            sourceURL: sourceURL,
            sourceIdentity: identity,
            readOnly: directory.readOnly
          )
        )
      }
      return MacVirtualMachineSharedDirectoryAccess(
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
  ) throws -> MacVirtualMachineSharedDirectorySourceIdentity {
    guard url.isFileURL else {
      throw MacVirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
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
      throw MacVirtualMachineSharedDirectoryError.accessDenied(displayPath)
    }
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw MacVirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
    }
    guard values.isReadable == true, readOnly || values.isWritable == true else {
      throw MacVirtualMachineSharedDirectoryError.accessDenied(displayPath)
    }

    var metadata = stat()
    guard Darwin.lstat(url.path(percentEncoded: false), &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    else {
      throw MacVirtualMachineSharedDirectoryError.invalidDirectory(displayPath)
    }
    return MacVirtualMachineSharedDirectorySourceIdentity(
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }
}
