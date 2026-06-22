import DiskImageKit
import Foundation
@preconcurrency import Virtualization

protocol VirtualMachineDiskImageInspecting: Sendable {
  func inspect(
    at url: URL,
    expectedFormat: VirtualMachineDiskImageFormat
  ) throws -> VirtualMachineDiskImageDescriptor
}

struct AppleVirtualMachineDiskImageInspector: VirtualMachineDiskImageInspecting {
  func inspect(
    at url: URL,
    expectedFormat: VirtualMachineDiskImageFormat
  ) throws -> VirtualMachineDiskImageDescriptor {
    switch expectedFormat {
    case .raw:
      return try inspectRAW(at: url)
    case .asif:
      guard #available(macOS 27.0, *) else {
        throw VirtualMachineDiskImageError.unsupportedHost(.asif)
      }
      return try inspectASIF(at: url)
    }
  }

  private func inspectRAW(at url: URL) throws -> VirtualMachineDiskImageDescriptor {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let number = attributes[.size] as? NSNumber else {
        throw VirtualMachineDiskImageError.invalidLogicalSize(0)
      }
      let logicalBytes = number.uint64Value
      guard
        logicalBytes > 0,
        logicalBytes.isMultiple(
          of: VirtualMachineDiskImageDescriptor.rawBlockSizeBytes
        )
      else {
        throw VirtualMachineDiskImageError.invalidLogicalSize(logicalBytes)
      }
      return VirtualMachineDiskImageDescriptor(
        format: .raw,
        logicalBytes: logicalBytes,
        blockSizeBytes: VirtualMachineDiskImageDescriptor.rawBlockSizeBytes
      )
    } catch let error as VirtualMachineDiskImageError {
      throw error
    } catch {
      throw VirtualMachineDiskImageError.inspectionFailed(error.localizedDescription)
    }
  }

  @available(macOS 27.0, *)
  private func inspectASIF(at url: URL) throws -> VirtualMachineDiskImageDescriptor {
    do {
      let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
      guard image.format == .asif else {
        throw VirtualMachineDiskImageError.unexpectedFormat(
          expected: .asif,
          actual: Self.formatName(image.format)
        )
      }
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
        format: .asif,
        logicalBytes: logicalBytes,
        blockSizeBytes: blockSizeBytes,
        layerType: Self.layerType(image.layerType)
      )
    } catch let error as VirtualMachineDiskImageError {
      throw error
    } catch {
      throw VirtualMachineDiskImageError.inspectionFailed(error.localizedDescription)
    }
  }

  @available(macOS 27.0, *)
  private static func formatName(_ format: DiskImage.Format) -> String {
    switch format {
    case .asif:
      "ASIF"
    case .raw:
      "RAW"
    case .stack:
      "stack"
    @unknown default:
      "an unknown format"
    }
  }

  @available(macOS 27.0, *)
  private static func layerType(
    _ layerType: DiskImage.LayerType?
  ) -> VirtualMachineDiskImageLayerType? {
    switch layerType {
    case .cache:
      .cache
    case .overlay:
      .overlay
    case nil:
      nil
    default:
      .unknown
    }
  }
}

#if arch(arm64)
  @MainActor
  protocol AppleVirtualMachineDiskImageServicing {
    func descriptor(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VirtualMachineDiskImageDescriptor
    func descriptor(
      for machine: ResolvedLinuxVirtualMachine
    ) throws -> VirtualMachineDiskImageDescriptor
    func makeWritableAttachment(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VZStorageDeviceAttachment
    func makeWritableAttachment(
      for machine: ResolvedLinuxVirtualMachine
    ) throws -> VZStorageDeviceAttachment
  }

  @MainActor
  struct AppleVirtualMachineDiskImageService:
    AppleVirtualMachineDiskImageServicing
  {
    private struct Source {
      let manifest: VirtualMachineManifest
      let diskImageURL: URL
      let diskSnapshotLayerURLs: [URL]
    }

    private let inspector: any VirtualMachineDiskImageInspecting

    init(
      inspector: any VirtualMachineDiskImageInspecting =
        AppleVirtualMachineDiskImageInspector()
    ) {
      self.inspector = inspector
    }

    func descriptor(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VirtualMachineDiskImageDescriptor {
      try descriptor(
        for: Source(
          manifest: machine.manifest,
          diskImageURL: machine.diskImageURL,
          diskSnapshotLayerURLs: machine.diskSnapshotLayerURLs
        )
      )
    }

    func descriptor(
      for machine: ResolvedLinuxVirtualMachine
    ) throws -> VirtualMachineDiskImageDescriptor {
      try descriptor(
        for: Source(
          manifest: machine.manifest,
          diskImageURL: machine.diskImageURL,
          diskSnapshotLayerURLs: machine.diskSnapshotLayerURLs
        )
      )
    }

    private func descriptor(
      for source: Source
    ) throws -> VirtualMachineDiskImageDescriptor {
      guard !source.diskSnapshotLayerURLs.isEmpty else {
        return try inspector.inspect(
          at: source.diskImageURL,
          expectedFormat: source.manifest.effectiveDiskImageFormat
        )
      }
      guard #available(macOS 27.0, *) else {
        throw VirtualMachineDiskImageError.unsupportedHost(
          source.manifest.effectiveDiskImageFormat
        )
      }
      let image = try makeSnapshotStack(
        for: source,
        writableTopLayer: false
      )
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
        format: source.manifest.effectiveDiskImageFormat,
        logicalBytes: logicalBytes,
        blockSizeBytes: blockSizeBytes,
        layerType: .overlay
      )
    }

    func makeWritableAttachment(
      for machine: ResolvedMacVirtualMachine
    ) throws -> VZStorageDeviceAttachment {
      try makeWritableAttachment(
        for: Source(
          manifest: machine.manifest,
          diskImageURL: machine.diskImageURL,
          diskSnapshotLayerURLs: machine.diskSnapshotLayerURLs
        )
      )
    }

    func makeWritableAttachment(
      for machine: ResolvedLinuxVirtualMachine
    ) throws -> VZStorageDeviceAttachment {
      try makeWritableAttachment(
        for: Source(
          manifest: machine.manifest,
          diskImageURL: machine.diskImageURL,
          diskSnapshotLayerURLs: machine.diskSnapshotLayerURLs
        )
      )
    }

    private func makeWritableAttachment(
      for source: Source
    ) throws -> VZStorageDeviceAttachment {
      if !source.diskSnapshotLayerURLs.isEmpty {
        guard #available(macOS 27.0, *) else {
          throw VirtualMachineDiskImageError.unsupportedHost(
            source.manifest.effectiveDiskImageFormat
          )
        }
        return try VZDiskImageStorageDeviceAttachment(
          diskImage: makeSnapshotStack(
            for: source,
            writableTopLayer: true
          ),
          cachingMode: .automatic,
          synchronizationMode: .full
        )
      }

      switch source.manifest.effectiveDiskImageFormat {
      case .raw:
        return try VZDiskImageStorageDeviceAttachment(
          url: source.diskImageURL,
          readOnly: false,
          cachingMode: .automatic,
          synchronizationMode: .full
        )
      case .asif:
        guard #available(macOS 27.0, *) else {
          throw VirtualMachineDiskImageError.unsupportedHost(.asif)
        }
        return try makeASIFAttachment(for: source)
      }
    }

    @available(macOS 27.0, *)
    private func makeSnapshotStack(
      for source: Source,
      writableTopLayer: Bool
    ) throws -> DiskImage {
      let configuration = source.manifest.effectiveDiskSnapshotConfiguration
      guard configuration.hasSnapshots,
        configuration.layers.count == source.diskSnapshotLayerURLs.count
      else {
        throw VirtualMachineDiskImageError.inspectionFailed(
          "the snapshot manifest does not match its resolved layer stack"
        )
      }

      do {
        var image = try DiskImage(
          opening: .open(url: source.diskImageURL, mode: .readOnly)
        )
        for (index, layerURL) in source.diskSnapshotLayerURLs.enumerated() {
          let isTopLayer = index == source.diskSnapshotLayerURLs.indices.last
          let layer = try DiskImage(
            opening: .open(
              url: layerURL,
              mode: writableTopLayer && isTopLayer
                ? .readWrite : .readOnly
            )
          )
          image = try image.appending(layer)
        }
        guard image.format == .stack else {
          throw VirtualMachineDiskImageError.inspectionFailed(
            "DiskImageKit did not assemble the snapshot layer stack"
          )
        }
        return image
      } catch let error as VirtualMachineDiskImageError {
        throw error
      } catch {
        throw VirtualMachineDiskImageError.inspectionFailed(
          error.localizedDescription
        )
      }
    }

    @available(macOS 27.0, *)
    private func makeASIFAttachment(
      for source: Source
    ) throws -> VZStorageDeviceAttachment {
      let image: DiskImage
      do {
        image = try DiskImage(
          opening: .open(url: source.diskImageURL, mode: .readWrite)
        )
      } catch {
        throw VirtualMachineDiskImageError.inspectionFailed(
          error.localizedDescription
        )
      }
      guard image.format == .asif else {
        throw VirtualMachineDiskImageError.unexpectedFormat(
          expected: .asif,
          actual: "a non-ASIF image"
        )
      }
      return try VZDiskImageStorageDeviceAttachment(
        diskImage: image,
        cachingMode: .automatic,
        synchronizationMode: .full
      )
    }
  }
#endif
