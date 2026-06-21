import ContainerImagesServiceClient
import ContainerResource
import ContainerXPC
import Foundation

struct ImagePruneRecord: Equatable, Sendable {
  let reference: String
  let digest: String
  let indexSizeBytes: Int64
}

protocol ImagePruneTransport: Sendable {
  func list() async throws -> [ImagePruneRecord]
  func delete(reference: String) async throws
  func cleanUpOrphanedBlobs() async throws -> (
    deletedDigests: [String],
    reclaimedBytes: UInt64
  )
  func calculateReclaimableBytes(
    activeReferences: Set<String>
  ) async throws -> UInt64
}

struct AppleImagePruneClient: ImagePruneTransport {
  private static let serviceIdentifier =
    "com.apple.container.core.container-core-images"

  private let requestSender: any AppleXPCRequestSending
  private let cleanupRequestSender: any AppleXPCRequestSending

  init(
    operationTimeout: Duration = .seconds(15),
    cleanupTimeout: Duration = .seconds(60)
  ) {
    requestSender = AppleXPCRequestClient(
      serviceIdentifier: Self.serviceIdentifier,
      operationTimeout: operationTimeout
    )
    cleanupRequestSender = AppleXPCRequestClient(
      serviceIdentifier: Self.serviceIdentifier,
      operationTimeout: cleanupTimeout
    )
  }

  init(
    requestSender: any AppleXPCRequestSending,
    cleanupRequestSender: (any AppleXPCRequestSending)? = nil
  ) {
    self.requestSender = requestSender
    self.cleanupRequestSender = cleanupRequestSender ?? requestSender
  }

  func list() async throws -> [ImagePruneRecord] {
    let response = try await requestSender.send(
      XPCMessage(route: ImagesServiceXPCRoute.imageList),
      operation: "Inspect local images"
    )
    guard let data = response.dataNoCopy(key: .imageDescriptions) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return try JSONDecoder().decode([ImageDescription].self, from: data)
      .map {
        ImagePruneRecord(
          reference: $0.reference,
          digest: $0.digest,
          indexSizeBytes: $0.descriptor.size
        )
      }
  }

  func delete(reference: String) async throws {
    let message = XPCMessage(route: ImagesServiceXPCRoute.imageDelete)
    message.set(key: .imageReference, value: reference)
    message.set(key: .garbageCollect, value: false)
    _ = try await requestSender.send(
      message,
      operation: "Delete image reference"
    )
  }

  func cleanUpOrphanedBlobs() async throws -> (
    deletedDigests: [String],
    reclaimedBytes: UInt64
  ) {
    let response = try await cleanupRequestSender.send(
      XPCMessage(route: ImagesServiceXPCRoute.imageCleanupOrphanedBlobs),
      operation: "Clean up unreferenced image content"
    )
    guard let data = response.dataNoCopy(key: .digests) else {
      throw ResourceManagementError.invalidInfrastructureResponse
    }
    return (
      deletedDigests: try JSONDecoder().decode([String].self, from: data),
      reclaimedBytes: response.uint64(key: .imageSize)
    )
  }

  func calculateReclaimableBytes(
    activeReferences: Set<String>
  ) async throws -> UInt64 {
    let message = XPCMessage(route: ImagesServiceXPCRoute.imageDiskUsage)
    message.set(
      key: .activeImageReferences,
      value: try JSONEncoder().encode(activeReferences)
    )
    let response = try await requestSender.send(
      message,
      operation: "Measure reclaimable image storage"
    )
    return response.uint64(key: .reclaimableSize)
  }
}
