import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import NativeContainers

@Suite("Apple runtime inventory mapping")
struct AppleRuntimeInventoryServiceTests {
  @Test
  func containerMappingPreservesEveryAppleSnapshotLabelUnchanged() {
    let descriptor = Descriptor(
      mediaType: "application/vnd.oci.image.index.v1+json",
      digest: "sha256:" + String(repeating: "a", count: 64),
      size: 1
    )
    let image = ImageDescription(
      reference: "example.invalid/api:latest",
      descriptor: descriptor
    )
    let process = ProcessConfiguration(
      executable: "/bin/sh",
      arguments: [],
      environment: []
    )
    var configuration = ContainerConfiguration(
      id: "compose-api-1",
      image: image,
      process: process
    )
    let labels = [
      ComposeLabelKey.project: "sample-stack",
      ComposeLabelKey.service: "api",
      ComposeLabelKey.containerNumber: "1",
      "example.invalid/verbatim": "  preserve me exactly  ",
    ]
    configuration.labels = labels
    configuration.creationDate = Date(timeIntervalSince1970: 42)

    let snapshot = ContainerSnapshot(
      configuration: configuration,
      status: .running,
      networks: [],
      startedDate: Date(timeIntervalSince1970: 84)
    )

    let record = AppleRuntimeInventoryService.containerRecord(from: snapshot)

    #expect(record.id == "compose-api-1")
    #expect(record.state == .running)
    #expect(record.imageReference == "example.invalid/api:latest")
    #expect(record.imageDigest == descriptor.digest)
    #expect(record.labels == labels)
  }
}
