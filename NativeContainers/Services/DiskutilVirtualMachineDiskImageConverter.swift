import Foundation

protocol VirtualMachineDiskImageConverting: Sendable {
  func convert(
    sourceURL: URL,
    destinationURL: URL,
    to format: VirtualMachineDiskImageFormat
  ) async throws
}

struct DiskutilVirtualMachineDiskImageConverter:
  VirtualMachineDiskImageConverting
{
  static let executableURL = URL(filePath: "/usr/sbin/diskutil")
  static let conversionTimeout: Duration = .seconds(6 * 60 * 60)

  private let executor: any HostCommandExecuting
  private let timeout: Duration

  init(
    executor: any HostCommandExecuting = FoundationHostCommandExecutor(),
    timeout: Duration = Self.conversionTimeout
  ) {
    self.executor = executor
    self.timeout = timeout
  }

  func convert(
    sourceURL: URL,
    destinationURL: URL,
    to format: VirtualMachineDiskImageFormat
  ) async throws {
    let result = try await executor.execute(
      executableURL: Self.executableURL,
      arguments: [
        "image",
        "create",
        "from",
        "--format",
        commandFormat(format),
        sourceURL.path(percentEncoded: false),
        destinationURL.path(percentEncoded: false),
      ],
      environment: nil,
      timeout: timeout
    )
    guard !result.outputWasTruncated else {
      throw VirtualMachineDiskImageMigrationError.conversionOutputTruncated
    }
    guard result.exitCode == 0 else {
      let diagnostic = [result.standardError, result.standardOutput]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw VirtualMachineDiskImageMigrationError.conversionFailed(
        exitCode: result.exitCode,
        diagnostic: String(diagnostic.suffix(2_000))
      )
    }
  }

  private func commandFormat(
    _ format: VirtualMachineDiskImageFormat
  ) -> String {
    switch format {
    case .raw:
      "RAW"
    case .asif:
      "ASIF"
    }
  }
}
