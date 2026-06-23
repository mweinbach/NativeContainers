import Foundation

enum ContainerBuilderImageResolution: Equatable, Sendable {
  case fetchNormally
  case requirePinnedLocal(expectedDigest: String)
}

struct ContainerBuilderImageDigestObservation: Equatable, Sendable {
  let topLevelDigest: String
  let resolvedManifestDigest: String
}

enum ContainerBuilderImageIntegrityError: Equatable, Sendable {
  case missingPinnedImage
  case digestMismatch(expected: String, actual: String)
}

enum ContainerBuilderImageIntegrityPolicy {
  static func resolution(
    configuredReference: String,
    nativeReference: String,
    nativeDigest: String
  ) -> ContainerBuilderImageResolution {
    configuredReference == nativeReference
      ? .requirePinnedLocal(expectedDigest: nativeDigest)
      : .fetchNormally
  }

  static func validate(
    resolution: ContainerBuilderImageResolution,
    observation: ContainerBuilderImageDigestObservation?
  ) -> ContainerBuilderImageIntegrityError? {
    switch resolution {
    case .fetchNormally:
      return nil
    case .requirePinnedLocal(let expectedDigest):
      guard let observation else {
        return .missingPinnedImage
      }
      // Apple ImageStore can synthesize an indirect top-level index during
      // import. Only the resolved image-manifest descriptor is authoritative.
      guard observation.resolvedManifestDigest == expectedDigest else {
        return .digestMismatch(
          expected: expectedDigest,
          actual: observation.resolvedManifestDigest
        )
      }
      return nil
    }
  }
}
