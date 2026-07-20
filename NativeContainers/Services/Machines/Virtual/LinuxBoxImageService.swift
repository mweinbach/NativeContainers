import Foundation

struct LinuxBoxImageService: Sendable {
  let catalog: LinuxBoxImageCatalog
  let cache: LinuxBoxImageCache

  init(
    catalog: LinuxBoxImageCatalog,
    cache: LinuxBoxImageCache = LinuxBoxImageCache()
  ) {
    self.catalog = catalog
    self.cache = cache
  }

  static func embedded(
    bundle: Bundle = .main,
    cache: LinuxBoxImageCache = LinuxBoxImageCache()
  ) throws -> LinuxBoxImageService {
    LinuxBoxImageService(
      catalog: try LinuxBoxImageCatalog.loadEmbedded(bundle: bundle),
      cache: cache
    )
  }

  func image(id: String) throws -> LinuxBoxImageRecord {
    guard let image = catalog.images.first(where: { $0.imageID == id }) else {
      throw LinuxBoxImageServiceError.imageNotFound(id)
    }
    return image
  }
  func recover() async throws {
    try await cache.recover(catalog: catalog)
  }

}

enum LinuxBoxImageServiceError: LocalizedError, Equatable, Sendable {
  case imageNotFound(String)
  var errorDescription: String? {
    switch self {
    case .imageNotFound(let id): "No Linux box image named \(id) is present in the embedded catalog."
    }
  }
}
