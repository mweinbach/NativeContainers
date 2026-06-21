import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationOCI
import Foundation
import Testing

@testable import NativeContainers

@Suite("Storage reclamation XPC clients")
struct StorageReclamationClientTests {
  @Test
  func containerClientUsesNonForceDeleteAndDecodesBoundedRequests() async throws {
    let sender = ReclamationXPCSender()
    let client = AppleContainerReclamationClient(requestSender: sender)

    let snapshots = try await client.list(ids: ["old"])
    let size = try await client.diskUsage(id: "old")
    try await client.deleteStopped(id: "old")

    #expect(snapshots.isEmpty)
    #expect(size == 4_096)
    #expect(
      await sender.routes
        == [
          XPCRoute.containerList.rawValue,
          XPCRoute.containerDiskUsage.rawValue,
          XPCRoute.containerDelete.rawValue,
        ]
    )
    #expect(await sender.deletedContainerIDs == ["old"])
    #expect(await sender.forceDeleteValues == [false])
  }

  @Test
  func imageClientUsesFocusedRoutesAndDecodesCleanupAccounting() async throws {
    let sender = ReclamationXPCSender()
    let client = AppleImagePruneClient(
      requestSender: sender,
      cleanupRequestSender: sender
    )

    let images = try await client.list()
    try await client.delete(reference: "example.invalid/old:latest")
    let cleanup = try await client.cleanUpOrphanedBlobs()
    let reclaimable = try await client.calculateReclaimableBytes(
      activeReferences: ["example.invalid/active:latest"]
    )

    #expect(images.map(\.reference) == ["example.invalid/old:latest"])
    #expect(await sender.deletedImageReferences == ["example.invalid/old:latest"])
    #expect(await sender.imageGarbageCollectValues == [false])
    #expect(cleanup.deletedDigests == ["sha256:orphan"])
    #expect(cleanup.reclaimedBytes == 2_048)
    #expect(reclaimable == 8_192)
    #expect(
      await sender.routes
        == [
          ImagesServiceXPCRoute.imageList.rawValue,
          ImagesServiceXPCRoute.imageDelete.rawValue,
          ImagesServiceXPCRoute.imageCleanupOrphanedBlobs.rawValue,
          ImagesServiceXPCRoute.imageDiskUsage.rawValue,
        ]
    )
  }
}

private actor ReclamationXPCSender: AppleXPCRequestSending {
  private(set) var routes: [String] = []
  private(set) var deletedContainerIDs: [String] = []
  private(set) var forceDeleteValues: [Bool] = []
  private(set) var deletedImageReferences: [String] = []
  private(set) var imageGarbageCollectValues: [Bool] = []

  func send(
    _ message: XPCMessage,
    operation: String
  ) async throws -> XPCMessage {
    let route = message.string(key: XPCMessage.routeKey) ?? ""
    routes.append(route)
    let response = XPCMessage(route: "testReply")

    switch route {
    case XPCRoute.containerList.rawValue:
      response.set(
        key: .containers,
        value: try JSONEncoder().encode([ContainerSnapshot]())
      )
    case XPCRoute.containerDiskUsage.rawValue:
      response.set(key: .containerSize, value: UInt64(4_096))
    case XPCRoute.containerDelete.rawValue:
      deletedContainerIDs.append(message.string(key: .id) ?? "")
      forceDeleteValues.append(message.bool(key: .forceDelete))
    case ImagesServiceXPCRoute.imageList.rawValue:
      let descriptor = Descriptor(
        mediaType: "application/vnd.oci.image.index.v1+json",
        digest: "sha256:old",
        size: 32
      )
      let image = ImageDescription(
        reference: "example.invalid/old:latest",
        descriptor: descriptor
      )
      response.set(
        key: .imageDescriptions,
        value: try JSONEncoder().encode([image])
      )
    case ImagesServiceXPCRoute.imageDelete.rawValue:
      deletedImageReferences.append(
        message.string(key: .imageReference) ?? ""
      )
      imageGarbageCollectValues.append(
        message.bool(key: .garbageCollect)
      )
    case ImagesServiceXPCRoute.imageCleanupOrphanedBlobs.rawValue:
      response.set(
        key: .digests,
        value: try JSONEncoder().encode(["sha256:orphan"])
      )
      response.set(key: .imageSize, value: UInt64(2_048))
    case ImagesServiceXPCRoute.imageDiskUsage.rawValue:
      response.set(key: .reclaimableSize, value: UInt64(8_192))
    default:
      break
    }

    return response
  }
}
