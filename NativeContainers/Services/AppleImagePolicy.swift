import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation

struct AppleImagePolicy: Sendable {
  func validatedReference(_ reference: String) throws -> String {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else { throw ImageManagementError.missingReference }
    return reference
  }

  func resolvePlatform(
    _ request: ImagePlatformRequest
  ) throws -> (scope: ImagePlatformScope, platform: ContainerizationOCI.Platform?) {
    switch request {
    case .all:
      return (.all, nil)
    case .current:
      let platform = ContainerizationOCI.Platform.current
      return (.specific(Self.platformValue(platform)), platform)
    case .arm64:
      let platform = try ContainerizationOCI.Platform(from: "linux/arm64/v8")
      return (.specific(Self.platformValue(platform)), platform)
    case .amd64:
      let platform = try ContainerizationOCI.Platform(from: "linux/amd64")
      return (.specific(Self.platformValue(platform)), platform)
    }
  }

  func applePlatform(
    for scope: ImagePlatformScope
  ) throws -> ContainerizationOCI.Platform? {
    switch scope {
    case .all:
      nil
    case .specific(let platform):
      try ContainerizationOCI.Platform(from: platform.description)
    }
  }

  static func platformValue(
    _ platform: ContainerizationOCI.Platform
  ) -> OCIPlatformValue {
    OCIPlatformValue(
      os: platform.os,
      architecture: platform.architecture,
      variant: platform.variant
    )
  }

  func validatePlatform(
    _ platform: ContainerizationOCI.Platform,
    in image: ClientImage
  ) async throws {
    let available = try await availablePlatforms(in: image)
    try ImageTransferExecutionSafety.validatePlatform(
      Self.platformValue(platform),
      available: available.map(Self.platformValue),
      reference: image.reference
    )
    _ = try await image.config(for: platform)
  }

  func transferPlatforms(
    for scope: ImagePlatformScope,
    in image: ClientImage,
    requireAllPlatforms: Bool
  ) async throws -> [ContainerizationOCI.Platform] {
    switch scope {
    case .specific:
      guard let platform = try applePlatform(for: scope) else {
        throw ImageManagementError.noRunnablePlatforms(image.reference)
      }
      try await validatePlatform(platform, in: image)
      return [platform]
    case .all:
      guard requireAllPlatforms else { return [] }
      let platforms = try await availablePlatforms(in: image)
      guard !platforms.isEmpty else {
        throw ImageManagementError.noRunnablePlatforms(image.reference)
      }
      return platforms
    }
  }

  func availablePlatforms(
    in image: ClientImage
  ) async throws -> [ContainerizationOCI.Platform] {
    let index = try await image.index()
    var unique: [String: ContainerizationOCI.Platform] = [:]
    for descriptor in index.manifests {
      guard
        descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest",
        let platform = descriptor.platform
      else { continue }
      unique[platform.description] = platform
    }
    return unique.values.sorted { $0.description < $1.description }
  }

  func resolveRegistryTransport(
    reference: String,
    requestedTransport: RegistryTransport,
    configuration: ContainerSystemConfig
  ) throws -> (hostname: String, transport: RegistryTransport) {
    let parsed = try Reference.parse(reference)
    guard let domain = parsed.domain else {
      throw ImageManagementError.missingRegistryHost(reference)
    }
    let endpoint = try AppleRegistryEndpoint(server: domain)
    let requestedScheme = try RequestScheme(requestedTransport.rawValue)
    let resolvedScheme = try requestedScheme.schemeFor(
      host: endpoint.connectionHost,
      internalDnsDomain: configuration.dns.domain
    )
    guard let resolvedTransport = RegistryTransport(rawValue: resolvedScheme.rawValue) else {
      throw RegistryManagementError.invalidResolvedTransport
    }
    return (endpoint.hostname, resolvedTransport)
  }

  func ensureUserManaged(
    _ image: ClientImage,
    configuration: ContainerSystemConfig
  ) throws {
    try ensureUserManaged(reference: image.reference, configuration: configuration)
  }

  func ensureUserManaged(
    reference: String,
    configuration: ContainerSystemConfig
  ) throws {
    guard !isInfrastructureReference(reference, configuration: configuration) else {
      throw ImageManagementError.infrastructureImage(reference)
    }
  }

  func isInfrastructureReference(
    _ reference: String,
    configuration: ContainerSystemConfig
  ) -> Bool {
    if Utility.isInfraImage(
      name: reference,
      builderImage: configuration.build.image,
      initImage: configuration.vminit.image
    ) {
      return true
    }
    guard
      let normalizedReference = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      )
    else { return false }
    return [configuration.build.image, configuration.vminit.image].contains { managedReference in
      guard
        let normalizedManagedReference = try? ClientImage.normalizeReference(
          managedReference,
          containerSystemConfig: configuration
        )
      else { return false }
      return normalizedManagedReference == normalizedReference
    }
  }

  func containerIDs(
    using imageReference: String,
    among containers: [ContainerSnapshot],
    configuration: ContainerSystemConfig
  ) -> [String] {
    let normalizedImageReference = try? ClientImage.normalizeReference(
      imageReference,
      containerSystemConfig: configuration
    )
    return containers.filter { container in
      let containerReference = container.configuration.image.reference
      if containerReference == imageReference { return true }
      guard let normalizedImageReference else { return false }
      return
        (try? ClientImage.normalizeReference(
          containerReference,
          containerSystemConfig: configuration
        )) == normalizedImageReference
    }.map(\.id).sorted()
  }

  func loadSystemConfiguration() async throws -> ContainerSystemConfig {
    try await AppleContainerConfiguration.load()
  }

  static func parseImageDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: value)
  }
}
