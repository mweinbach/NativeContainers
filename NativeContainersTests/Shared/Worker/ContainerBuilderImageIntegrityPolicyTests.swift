import ContainerPersistence
import Testing

@testable import NativeContainers

struct ContainerBuilderImageIntegrityPolicyTests {
  @Test
  func officialDefaultRetainsNormalFetchResolution() {
    let officialDefaultReference = "ghcr.io/apple/container-builder-shim/builder:0.12.0"

    #expect(BuildConfig.defaultImage == officialDefaultReference)
    #expect(resolution(for: BuildConfig.defaultImage) == .fetchNormally)
  }

  @Test
  func nativeReferenceRequiresExactPinnedLocalImage() {
    #expect(
      BuildConfig.nativeContainersImageReference
        == "nativecontainers.local/container-builder-shim:0.12.0-nc.2-release"
    )
    #expect(
      BuildConfig.nativeContainersImageDigest
        == "sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff"
    )
    #expect(
      resolution(for: BuildConfig.nativeContainersImageReference)
        == .requirePinnedLocal(expectedDigest: BuildConfig.nativeContainersImageDigest)
    )
  }

  @Test
  func retargetedReferenceDoesNotInheritNativeLocalTrust() {
    let retargetedReference =
      "nativecontainers.local/container-builder-shim:0.12.0-nc.2-retargeted"

    #expect(resolution(for: retargetedReference) == .fetchNormally)
  }

  @Test
  func missingPinnedNativeImageFailsClosed() {
    #expect(
      ContainerBuilderImageIntegrityPolicy.validate(
        resolution: nativeResolution,
        observation: nil
      ) == .missingPinnedImage
    )
  }

  @Test
  func matchingSyntheticIndexCannotMaskRetargetedResolvedManifest() {
    let retargetedManifestDigest =
      "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let observation = ContainerBuilderImageDigestObservation(
      topLevelDigest: BuildConfig.nativeContainersImageDigest,
      resolvedManifestDigest: retargetedManifestDigest
    )

    #expect(
      ContainerBuilderImageIntegrityPolicy.validate(
        resolution: nativeResolution,
        observation: observation
      )
        == .digestMismatch(
          expected: BuildConfig.nativeContainersImageDigest,
          actual: retargetedManifestDigest
        )
    )
  }

  @Test
  func exactResolvedManifestIsAcceptedUnderSyntheticIndex() {
    let syntheticIndexDigest =
      "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let observation = ContainerBuilderImageDigestObservation(
      topLevelDigest: syntheticIndexDigest,
      resolvedManifestDigest: BuildConfig.nativeContainersImageDigest
    )

    #expect(
      ContainerBuilderImageIntegrityPolicy.validate(
        resolution: nativeResolution,
        observation: observation
      ) == nil
    )
  }

  private var nativeResolution: ContainerBuilderImageResolution {
    resolution(for: BuildConfig.nativeContainersImageReference)
  }

  private func resolution(for reference: String) -> ContainerBuilderImageResolution {
    ContainerBuilderImageIntegrityPolicy.resolution(
      configuredReference: reference,
      nativeReference: BuildConfig.nativeContainersImageReference,
      nativeDigest: BuildConfig.nativeContainersImageDigest
    )
  }
}
