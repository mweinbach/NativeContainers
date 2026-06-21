import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation

struct AppleImageInspectionService: Sendable {
  private let containerReader: any ContainerSnapshotReading
  private let policy: AppleImagePolicy

  init(
    containerReader: any ContainerSnapshotReading,
    policy: AppleImagePolicy
  ) {
    self.containerReader = containerReader
    self.policy = policy
  }

  func inspect(reference: String) async throws -> ImageInspection {
    let reference = try policy.validatedReference(reference)
    async let configurationRequest = policy.loadSystemConfiguration()
    async let allImagesRequest = ClientImage.list()
    async let containersRequest = containerReader.list()

    let configuration = try await configurationRequest
    let image = try await ClientImage.get(
      reference: reference,
      containerSystemConfig: configuration
    )
    let index = try await image.index()
    let allImages = try await allImagesRequest
    let containers = try await containersRequest
    var variants: [ImageVariantInspection] = []
    var warnings: [String] = []

    for descriptor in index.manifests {
      if descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
        continue
      }
      guard let platform = descriptor.platform else {
        warnings.append("Manifest \(descriptor.digest) has no platform and was skipped.")
        continue
      }
      do {
        let manifest = try await image.manifest(for: platform)
        let imageConfiguration = try await image.config(for: platform)
        let processConfiguration = imageConfiguration.config
        let size =
          descriptor.size + manifest.config.size
          + manifest.layers.reduce(0) { $0 + $1.size }
        variants.append(
          ImageVariantInspection(
            platform: platform.description,
            os: platform.os,
            architecture: platform.architecture,
            variant: platform.variant,
            manifestDigest: descriptor.digest,
            sizeBytes: size,
            createdAt: AppleImagePolicy.parseImageDate(imageConfiguration.created),
            author: imageConfiguration.author,
            user: processConfiguration?.user,
            workingDirectory: processConfiguration?.workingDir,
            entrypoint: processConfiguration?.entrypoint ?? [],
            command: processConfiguration?.cmd ?? [],
            environment: processConfiguration?.env ?? [],
            labels: processConfiguration?.labels ?? [:],
            layerCount: imageConfiguration.rootfs.diffIDs.count
          )
        )
      } catch {
        warnings.append(
          "Could not inspect \(platform.description): \(error.localizedDescription)"
        )
      }
    }

    variants.sort { $0.platform.localizedStandardCompare($1.platform) == .orderedAscending }
    let aliases = allImages.filter { $0.digest == image.digest && $0.reference != image.reference }
      .map(\.reference)
      .sorted()
    let usedBy = policy.containerIDs(
      using: image.reference,
      among: containers,
      configuration: configuration
    )

    return ImageInspection(
      reference: image.reference,
      displayReference: try ClientImage.denormalizeReference(
        image.reference,
        containerSystemConfig: configuration
      ),
      digest: image.digest,
      mediaType: image.descriptor.mediaType,
      indexSizeBytes: image.descriptor.size,
      createdAt: variants.compactMap(\.createdAt).min(),
      variants: variants,
      aliases: aliases,
      usedByContainerIDs: usedBy,
      warnings: warnings
    )
  }
}
