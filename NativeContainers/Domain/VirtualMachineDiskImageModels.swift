import Foundation

enum VirtualMachineDiskImageFormat: String, Codable, CaseIterable, Sendable {
  case raw
  case asif

  var label: LocalizedStringResource {
    switch self {
    case .raw:
      "RAW"
    case .asif:
      "Apple sparse image"
    }
  }
}

enum VirtualMachineDiskImageLayerType: String, Codable, Sendable {
  case cache
  case overlay
  case unknown
}

struct VirtualMachineDiskImageDescriptor: Equatable, Sendable {
  static let rawBlockSizeBytes: UInt64 = 512

  let format: VirtualMachineDiskImageFormat
  let logicalBytes: UInt64
  let blockSizeBytes: UInt64
  let layerType: VirtualMachineDiskImageLayerType?

  init(
    format: VirtualMachineDiskImageFormat,
    logicalBytes: UInt64,
    blockSizeBytes: UInt64,
    layerType: VirtualMachineDiskImageLayerType? = nil
  ) {
    self.format = format
    self.logicalBytes = logicalBytes
    self.blockSizeBytes = blockSizeBytes
    self.layerType = layerType
  }

  var blockCount: UInt64 {
    logicalBytes / blockSizeBytes
  }
}

enum VirtualMachineDiskImageError: LocalizedError, Equatable, Sendable {
  case unsupportedHost(VirtualMachineDiskImageFormat)
  case unexpectedFormat(
    expected: VirtualMachineDiskImageFormat,
    actual: String
  )
  case invalidLogicalSize(UInt64)
  case inspectionFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedHost(let format):
      "The \(String(localized: format.label)) disk format requires macOS 27 or later."
    case .unexpectedFormat(let expected, let actual):
      "The disk manifest declares \(String(localized: expected.label)), but the image is \(actual)."
    case .invalidLogicalSize(let bytes):
      "The virtual disk reports an invalid logical size of \(bytes) bytes."
    case .inspectionFailed(let reason):
      "The virtual disk could not be inspected: \(reason)"
    }
  }
}
