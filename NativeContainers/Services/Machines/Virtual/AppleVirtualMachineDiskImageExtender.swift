import Darwin
@preconcurrency import DiskImageKit
import Foundation

struct VirtualMachineDiskImageResizeSource: Equatable, Sendable {
  let baseURL: URL
  let layerURLs: [URL]
  let expectedFormat: VirtualMachineDiskImageFormat

  var resizeArtifactURL: URL {
    layerURLs.last ?? baseURL
  }
}

protocol VirtualMachineDiskImageExtending: Sendable {
  func descriptor(
    for source: VirtualMachineDiskImageResizeSource
  ) throws -> VirtualMachineDiskImageDescriptor

  func extend(
    _ source: VirtualMachineDiskImageResizeSource,
    to targetLogicalBytes: UInt64
  ) throws -> VirtualMachineDiskImageDescriptor
}

struct AppleVirtualMachineDiskImageExtender:
  VirtualMachineDiskImageExtending
{
  func descriptor(
    for source: VirtualMachineDiskImageResizeSource
  ) throws -> VirtualMachineDiskImageDescriptor {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskImageResizeError.unavailable
    }
    return try descriptor(for: makeImage(for: source, writable: false), source: source)
  }

  func extend(
    _ source: VirtualMachineDiskImageResizeSource,
    to targetLogicalBytes: UInt64
  ) throws -> VirtualMachineDiskImageDescriptor {
    guard #available(macOS 27.0, *) else {
      throw VirtualMachineDiskImageResizeError.unavailable
    }

    let current = try descriptor(for: source)
    guard targetLogicalBytes > current.logicalBytes else {
      throw VirtualMachineDiskImageResizeError.growthRequired(
        current: current.logicalBytes,
        requested: targetLogicalBytes
      )
    }
    guard targetLogicalBytes.isMultiple(of: current.blockSizeBytes) else {
      throw VirtualMachineDiskImageResizeError.targetNotBlockAligned(
        target: targetLogicalBytes,
        blockSize: current.blockSizeBytes
      )
    }
    guard
      let blockCount = Int(
        exactly: targetLogicalBytes / current.blockSizeBytes
      )
    else {
      throw VirtualMachineDiskImageResizeError.targetTooLarge(
        targetLogicalBytes
      )
    }

    do {
      let image = try makeImage(for: source, writable: true)
      try image.truncate(blockCount: blockCount)
    }
    try fullySyncFile(at: source.resizeArtifactURL)

    let grown = try descriptor(for: source)
    guard grown.logicalBytes == targetLogicalBytes,
      grown.blockSizeBytes == current.blockSizeBytes
    else {
      throw VirtualMachineDiskImageResizeError.logicalSizeMismatch(
        expected: targetLogicalBytes,
        actual: grown.logicalBytes
      )
    }
    return grown
  }

  @available(macOS 27.0, *)
  private func makeImage(
    for source: VirtualMachineDiskImageResizeSource,
    writable: Bool
  ) throws -> DiskImage {
    do {
      guard !source.layerURLs.isEmpty else {
        let image = try DiskImage(
          opening: .open(
            url: source.baseURL,
            mode: writable ? .readWrite : .readOnly
          )
        )
        try validateStandaloneFormat(image, expected: source.expectedFormat)
        return image
      }

      var image = try DiskImage(
        opening: .open(url: source.baseURL, mode: .readOnly)
      )
      try validateStandaloneFormat(image, expected: source.expectedFormat)
      for (index, layerURL) in source.layerURLs.enumerated() {
        let isTopLayer = index == source.layerURLs.indices.last
        let layer = try DiskImage(
          opening: .open(
            url: layerURL,
            mode: writable && isTopLayer ? .readWrite : .readOnly
          )
        )
        let stack = try image.appending(layer)
        guard stack.format == .stack,
          stack.layers.count == index + 2,
          stack.layers.last?.url.standardizedFileURL
            == layerURL.standardizedFileURL,
          stack.layers.last?.layerType == .overlay
        else {
          throw VirtualMachineDiskImageResizeError.unsafeArtifact(
            "snapshot layer \(layerURL.lastPathComponent) is not an overlay"
          )
        }
        image = stack
      }
      guard image.format == .stack else {
        throw VirtualMachineDiskImageResizeError.unsafeArtifact(
          "DiskImageKit did not assemble the snapshot stack"
        )
      }
      return image
    } catch let error as VirtualMachineDiskImageResizeError {
      throw error
    } catch {
      throw VirtualMachineDiskImageResizeError.recoveryRequired(
        error.localizedDescription
      )
    }
  }

  @available(macOS 27.0, *)
  private func descriptor(
    for image: DiskImage,
    source: VirtualMachineDiskImageResizeSource
  ) throws -> VirtualMachineDiskImageDescriptor {
    guard let logicalBytes = UInt64(exactly: image.size),
      let blockSizeBytes = UInt64(exactly: image.blockSize.rawValue),
      logicalBytes > 0,
      blockSizeBytes > 0,
      logicalBytes.isMultiple(of: blockSizeBytes)
    else {
      throw VirtualMachineDiskImageError.invalidLogicalSize(
        UInt64(clamping: image.size)
      )
    }
    return VirtualMachineDiskImageDescriptor(
      format: source.expectedFormat,
      logicalBytes: logicalBytes,
      blockSizeBytes: blockSizeBytes,
      layerType: source.layerURLs.isEmpty ? nil : .overlay
    )
  }

  @available(macOS 27.0, *)
  private func validateStandaloneFormat(
    _ image: DiskImage,
    expected: VirtualMachineDiskImageFormat
  ) throws {
    let matches =
      switch expected {
      case .raw:
        image.format == .raw
      case .asif:
        image.format == .asif
      }
    guard matches, image.layerType == nil else {
      throw VirtualMachineDiskImageResizeError.unsafeArtifact(
        "the standalone disk does not match its declared format"
      )
    }
  }

  private func fullySyncFile(at url: URL) throws {
    let descriptor = Darwin.open(
      url.path(percentEncoded: false),
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw VirtualMachineDiskImageResizeError.unsafeArtifact(
        "the resized disk could not be synchronized"
      )
    }
    defer { Darwin.close(descriptor) }
    if Darwin.fcntl(descriptor, F_FULLFSYNC) != 0,
      Darwin.fsync(descriptor) != 0
    {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
