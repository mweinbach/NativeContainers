import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation

struct ImageBuildTagState: Equatable, Sendable {
  let currentDigests: [String: String]
  let infrastructureTags: Set<String>
}

struct ImageBuildStoredImage: Equatable, Sendable {
  let reference: String
  let digest: String
}

struct ImageBuildArchiveLoadResult: Equatable, Sendable {
  let images: [ImageBuildStoredImage]
  let rejectedMembers: [String]
  let reconciledFailureMessage: String?

  init(
    images: [ImageBuildStoredImage],
    rejectedMembers: [String],
    reconciledFailureMessage: String? = nil
  ) {
    self.images = images
    self.rejectedMembers = rejectedMembers
    self.reconciledFailureMessage = reconciledFailureMessage
  }
}

enum ImageBuildTagMutationOutcome: Equatable, Sendable {
  case applied
  case unchanged
  case drifted
}

enum ImageBuildTagMutationReconciliation {
  static func outcome(
    currentDigest: String?,
    reviewedDigest: String?,
    sourceDigest: String
  ) -> ImageBuildTagMutationOutcome {
    if currentDigest == sourceDigest { return .applied }
    if currentDigest == reviewedDigest { return .unchanged }
    return .drifted
  }
}

enum ImageBuildStoreError: LocalizedError, Equatable, Sendable {
  case mutationOutcomeUnknown(action: String, reference: String, details: String)

  var errorDescription: String? {
    switch self {
    case .mutationOutcomeUnknown(let action, let reference, let details):
      "Apple’s image service did not confirm \(action) for \(reference), and reconciliation failed: \(details) Refresh inventory before retrying."
    }
  }
}

protocol ImageBuildStoring: Sendable {
  func resolveTagExpectations(_ references: [String]) async throws
    -> [ContainerBuildTagExpectation]
  func tagState(for references: [String]) async throws -> ImageBuildTagState
  func loadArchive(
    at url: URL,
    expectedReference: String
  ) async throws -> ImageBuildArchiveLoadResult
  func verifySnapshot(
    reference: String,
    digest: String,
    platform: ContainerBuildPlatform
  ) async throws
  func applyTag(
    sourceReference: String,
    sourceDigest: String,
    target: ContainerBuildTagExpectation
  ) async throws
  func removeReferenceIfUnchanged(reference: String, digest: String) async throws -> Bool
}

struct AppleImageBuildStore: ImageBuildStoring {
  func resolveTagExpectations(
    _ references: [String]
  ) async throws -> [ContainerBuildTagExpectation] {
    guard !references.isEmpty else { throw ImageBuildError.emptyTags }
    let configuration = try await AppleContainerConfiguration.load()
    var normalized: [String] = []
    normalized.reserveCapacity(references.count)
    for reference in references {
      let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { throw ImageBuildError.emptyTags }
      let value = try ClientImage.normalizeReference(
        trimmed,
        containerSystemConfig: configuration
      )
      guard !isInfrastructure(value, configuration: configuration) else {
        throw ImageBuildError.infrastructureTag(value)
      }
      normalized.append(value)
    }
    guard Set(normalized).count == normalized.count else {
      throw ImageBuildError.duplicateTags
    }
    let images = try await ClientImage.list()
    return normalized.map { reference in
      ContainerBuildTagExpectation(
        reference: reference,
        existingDigest: images.first { $0.reference == reference }?.digest
      )
    }
  }

  func tagState(for references: [String]) async throws -> ImageBuildTagState {
    let configuration = try await AppleContainerConfiguration.load()
    let images = try await ClientImage.list()
    var digests: [String: String] = [:]
    var infrastructure = Set<String>()
    for reference in references {
      if let digest = images.first(where: { $0.reference == reference })?.digest {
        digests[reference] = digest
      }
      if isInfrastructure(reference, configuration: configuration) {
        infrastructure.insert(reference)
      }
    }
    return ImageBuildTagState(
      currentDigests: digests,
      infrastructureTags: infrastructure
    )
  }

  func loadArchive(
    at url: URL,
    expectedReference: String
  ) async throws -> ImageBuildArchiveLoadResult {
    do {
      let result = try await ClientImage.load(
        from: url.path(percentEncoded: false),
        force: false
      )
      return ImageBuildArchiveLoadResult(
        images: result.images.map {
          ImageBuildStoredImage(reference: $0.reference, digest: $0.digest)
        },
        rejectedMembers: result.rejectedMembers
      )
    } catch {
      let loadFailure = error
      let images: [ClientImage]
      do {
        images = try await ClientImage.list()
      } catch {
        throw ImageBuildStoreError.mutationOutcomeUnknown(
          action: "archive import",
          reference: expectedReference,
          details: error.localizedDescription
        )
      }
      let recovered = images.filter { $0.reference == expectedReference }
      guard !recovered.isEmpty else { throw loadFailure }
      return ImageBuildArchiveLoadResult(
        images: recovered.map {
          ImageBuildStoredImage(reference: $0.reference, digest: $0.digest)
        },
        rejectedMembers: [],
        reconciledFailureMessage: loadFailure.localizedDescription
      )
    }
  }

  func verifySnapshot(
    reference: String,
    digest: String,
    platform: ContainerBuildPlatform
  ) async throws {
    let image = try await requireImage(reference: reference, digest: digest)
    let applePlatform = try ContainerizationOCI.Platform(from: platform.description)
    _ = try await image.config(for: applePlatform)
    _ = try await image.getCreateSnapshot(platform: applePlatform)
    _ = try await image.getSnapshot(platform: applePlatform)
  }

  func applyTag(
    sourceReference: String,
    sourceDigest: String,
    target: ContainerBuildTagExpectation
  ) async throws {
    let images = try await ClientImage.list()
    guard images.first(where: { $0.reference == target.reference })?.digest == target.existingDigest
    else {
      throw ImageBuildError.stalePlan("local tag “\(target.reference)”")
    }
    let source = try requireImage(
      sourceReference,
      digest: sourceDigest,
      among: images
    )
    if target.existingDigest != sourceDigest {
      do {
        _ = try await source.tag(new: target.reference)
      } catch {
        let tagFailure = error
        let current: String?
        do {
          current = try await ClientImage.list().first {
            $0.reference == target.reference
          }?.digest
        } catch {
          throw ImageBuildStoreError.mutationOutcomeUnknown(
            action: "tag mutation",
            reference: target.reference,
            details: error.localizedDescription
          )
        }
        switch ImageBuildTagMutationReconciliation.outcome(
          currentDigest: current,
          reviewedDigest: target.existingDigest,
          sourceDigest: sourceDigest
        ) {
        case .applied:
          return
        case .unchanged:
          throw tagFailure
        case .drifted:
          throw ImageBuildError.stalePlan("local tag “\(target.reference)”")
        }
      }
    }
  }

  func removeReferenceIfUnchanged(reference: String, digest: String) async throws -> Bool {
    let current = try await ClientImage.list().first { $0.reference == reference }
    guard let current else { return true }
    guard current.digest == digest else { return false }
    try await ClientImage.delete(reference: reference, garbageCollect: false)
    return true
  }

  private func requireImage(reference: String, digest: String) async throws -> ClientImage {
    let images = try await ClientImage.list()
    return try requireImage(reference, digest: digest, among: images)
  }

  private func requireImage(
    _ reference: String,
    digest: String,
    among images: [ClientImage]
  ) throws -> ClientImage {
    guard let image = images.first(where: { $0.reference == reference }), image.digest == digest
    else {
      throw ImageBuildError.stagingReferenceChanged(reference)
    }
    return image
  }

  private func isInfrastructure(
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
      let normalized = try? ClientImage.normalizeReference(
        reference,
        containerSystemConfig: configuration
      )
    else { return false }
    return [configuration.build.image, configuration.vminit.image].contains { managed in
      (try? ClientImage.normalizeReference(
        managed,
        containerSystemConfig: configuration
      )) == normalized
    }
  }
}
