import Foundation
import Testing

@testable import NativeContainers

struct DiskutilVirtualMachineDiskImageConverterTests {
  @Test
  func invokesTheDocumentedOutOfPlaceASIFConversion() async throws {
    let executor = RecordingDiskImageCommandExecutor(
      result: HostCommandResult(
        exitCode: 0,
        standardOutput: "created",
        standardError: "",
        outputWasTruncated: false
      )
    )
    let timeout: Duration = .seconds(321)
    let converter = DiskutilVirtualMachineDiskImageConverter(
      executor: executor,
      timeout: timeout
    )
    let source = URL(filePath: "/tmp/Source Disk.raw")
    let destination = URL(filePath: "/tmp/.Destination.asif.partial")

    try await converter.convert(
      sourceURL: source,
      destinationURL: destination,
      to: .asif
    )

    let invocation = try #require(await executor.invocation)
    #expect(invocation.executableURL == URL(filePath: "/usr/sbin/diskutil"))
    #expect(
      invocation.arguments == [
        "image",
        "create",
        "from",
        "--format",
        "ASIF",
        "/tmp/Source Disk.raw",
        "/tmp/.Destination.asif.partial",
      ]
    )
    #expect(invocation.environment == nil)
    #expect(invocation.timeout == timeout)
  }

  @Test
  func reportsBoundedDiskutilFailureOutput() async {
    let executor = RecordingDiskImageCommandExecutor(
      result: HostCommandResult(
        exitCode: 7,
        standardOutput: "stdout",
        standardError: "conversion refused",
        outputWasTruncated: false
      )
    )
    let converter = DiskutilVirtualMachineDiskImageConverter(
      executor: executor
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.conversionFailed(
        exitCode: 7,
        diagnostic: "conversion refused\nstdout"
      )
    ) {
      try await converter.convert(
        sourceURL: URL(filePath: "/tmp/source.raw"),
        destinationURL: URL(filePath: "/tmp/destination.asif"),
        to: .asif
      )
    }
  }

  @Test
  func refusesToAcceptTruncatedCommandOutput() async {
    let executor = RecordingDiskImageCommandExecutor(
      result: HostCommandResult(
        exitCode: 0,
        standardOutput: "partial",
        standardError: "",
        outputWasTruncated: true
      )
    )
    let converter = DiskutilVirtualMachineDiskImageConverter(
      executor: executor
    )

    await #expect(
      throws: VirtualMachineDiskImageMigrationError.conversionOutputTruncated
    ) {
      try await converter.convert(
        sourceURL: URL(filePath: "/tmp/source.raw"),
        destinationURL: URL(filePath: "/tmp/destination.asif"),
        to: .asif
      )
    }
  }
}

private actor RecordingDiskImageCommandExecutor: HostCommandExecuting {
  struct Invocation: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let timeout: Duration
  }

  private let result: HostCommandResult
  private(set) var invocation: Invocation?

  init(result: HostCommandResult) {
    self.result = result
  }

  func execute(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration
  ) async throws -> HostCommandResult {
    invocation = Invocation(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: timeout
    )
    return result
  }
}
