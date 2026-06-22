import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Container filesystem export model")
struct ContainerFilesystemExportModelTests {
  @Test
  func publishesReceiptAndForwardsIdentityPinnedRequest() async {
    let container = exportModelContainer()
    let destination = URL(filePath: "/tmp/api.rootfs.tar")
    let expected = ContainerFilesystemExportReceipt(
      target: ContainerTerminalTargetIdentity(container: container),
      destinationURL: destination,
      byteCount: 512,
      sha256: String(repeating: "a", count: 64)
    )
    let exporter = RecordingContainerFilesystemExporter { _ in expected }
    let model = ContainerFilesystemExportModel(
      container: container,
      exporter: exporter
    )

    let completed = await model.export(to: destination)

    #expect(completed)
    #expect(model.receipt == expected)
    #expect(model.errorMessage == nil)
    #expect(model.warningMessage == nil)
    #expect(!model.isExporting)
    let requests = await exporter.requests
    #expect(requests.count == 1)
    #expect(requests.first?.target == expected.target)
    #expect(requests.first?.destinationURL == destination)
  }

  @Test
  func reportsFailureWithoutClaimingCompletion() async {
    let container = exportModelContainer()
    let destination = URL(filePath: "/tmp/existing.tar")
    let exporter = RecordingContainerFilesystemExporter { _ in
      throw ContainerFilesystemExportError.destinationMustBeNew(
        destination.path(percentEncoded: false)
      )
    }
    let model = ContainerFilesystemExportModel(
      container: container,
      exporter: exporter
    )

    let completed = await model.export(to: destination)

    #expect(!completed)
    #expect(model.receipt == nil)
    #expect(
      model.errorMessage
        == ContainerFilesystemExportError.destinationMustBeNew(
          destination.path(percentEncoded: false)
        ).localizedDescription
    )
    #expect(!model.isExporting)
  }

  @Test
  func retainsPartialCompletionReceiptAndWarning() async {
    let container = exportModelContainer()
    let destination = URL(filePath: "/tmp/retained.tar")
    let receipt = ContainerFilesystemExportReceipt(
      target: ContainerTerminalTargetIdentity(container: container),
      destinationURL: destination,
      byteCount: 128,
      sha256: String(repeating: "b", count: 64)
    )
    let partial = ContainerFilesystemExportPartialCompletionError(
      receipt: receipt,
      failureMessage: "parent sync failed"
    )
    let exporter = RecordingContainerFilesystemExporter { _ in
      throw partial
    }
    let model = ContainerFilesystemExportModel(
      container: container,
      exporter: exporter
    )

    let completed = await model.export(to: destination)

    #expect(completed)
    #expect(model.receipt == receipt)
    #expect(model.warningMessage == partial.localizedDescription)
    #expect(model.errorMessage == nil)
  }
}

private actor RecordingContainerFilesystemExporter: ContainerFilesystemExporting {
  private let operation:
    @Sendable (ContainerFilesystemExportRequest) async throws
      -> ContainerFilesystemExportReceipt
  private(set) var requests: [ContainerFilesystemExportRequest] = []

  init(
    operation:
      @escaping @Sendable (ContainerFilesystemExportRequest) async throws
      -> ContainerFilesystemExportReceipt
  ) {
    self.operation = operation
  }

  func exportFilesystem(
    _ request: ContainerFilesystemExportRequest
  ) async throws -> ContainerFilesystemExportReceipt {
    requests.append(request)
    return try await operation(request)
  }
}

private func exportModelContainer() -> ContainerRecord {
  ContainerRecord(
    id: "api",
    imageReference: "example.invalid/api:latest",
    platform: "linux/arm64",
    state: .stopped,
    ipAddress: nil,
    createdAt: Date(timeIntervalSince1970: 42),
    startedAt: nil,
    cpuCount: 4,
    memoryBytes: 4 * 1_024 * 1_024 * 1_024,
    ports: []
  )
}
