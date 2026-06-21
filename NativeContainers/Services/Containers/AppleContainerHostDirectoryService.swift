import ContainerResource
import Foundation

struct AppleContainerHostDirectoryService: ContainerHostDirectoryManaging {
  private let bookmarks: any ContainerHostDirectoryBookmarking
  private let manifestStore: any ContainerHostDirectoryManifestStoring

  init(
    bookmarks: any ContainerHostDirectoryBookmarking =
      ContainerHostDirectoryBookmarkService(),
    manifestStore: any ContainerHostDirectoryManifestStoring =
      FileContainerHostDirectoryManifestStore()
  ) {
    self.bookmarks = bookmarks
    self.manifestStore = manifestStore
  }

  func reviewHostDirectory(
    _ request: ContainerHostDirectoryReviewRequest
  ) throws -> ContainerHostDirectoryMount {
    try bookmarks.review(request)
  }

  func prepare(
    _ mounts: [ContainerHostDirectoryMount],
    operationID: UUID
  ) throws -> ContainerHostDirectoryAccess? {
    guard !mounts.isEmpty else { return nil }

    let access = try bookmarks.resolve(mounts)
    do {
      try manifestStore.save(
        ContainerHostDirectoryManifest(
          operationID: operationID,
          mounts: mounts
        )
      )
      return access
    } catch {
      access.release()
      throw error
    }
  }

  func validateBeforeStart(
    _ configuredMounts: [Filesystem],
    operationID: UUID
  ) throws -> ContainerHostDirectoryAccess {
    guard let manifest = try manifestStore.load(operationID: operationID) else {
      throw ContainerHostDirectoryError.missingManifest
    }

    let access = try bookmarks.resolve(manifest.mounts)
    let expected = access.mounts.map(MountSignature.init)
    let current = configuredMounts.filter(\.isVirtiofs).map(MountSignature.init)
    guard expected.sorted() == current.sorted() else {
      access.release()
      throw ContainerHostDirectoryError.configurationChanged
    }
    return access
  }

  func cleanup(operationID: UUID) {
    manifestStore.remove(operationID: operationID)
  }
}

private struct MountSignature: Comparable {
  let source: String
  let destination: String
  let options: [String]

  init(_ filesystem: Filesystem) {
    source = URL(filePath: filesystem.source).standardizedFileURL.nativeContainersPOSIXPath
    destination = filesystem.destination
    options = filesystem.options.sorted()
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.destination != rhs.destination {
      return lhs.destination < rhs.destination
    }
    if lhs.source != rhs.source {
      return lhs.source < rhs.source
    }
    return lhs.options.lexicographicallyPrecedes(rhs.options)
  }
}
