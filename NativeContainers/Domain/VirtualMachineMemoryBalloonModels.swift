import Foundation

struct VirtualMachineMemoryBalloonSnapshot: Equatable, Sendable {
  static let alignmentBytes = VirtualMachineComputeConfiguration.bytesPerMiB

  let configuredMemoryBytes: UInt64
  let minimumTargetMemoryBytes: UInt64
  let targetMemoryBytes: UInt64

  var isRequestingReclamation: Bool {
    targetMemoryBytes < configuredMemoryBytes
  }

  var canRequestAnotherTarget: Bool {
    minimumTargetMemoryBytes < configuredMemoryBytes
  }

  var targetOptions: [VirtualMachineMemoryBalloonTargetOption] {
    var options: [VirtualMachineMemoryBalloonTargetOption] = []
    var includedTargets: Set<UInt64> = []

    func append(
      _ kind: VirtualMachineMemoryBalloonTargetKind,
      target: UInt64
    ) {
      let alignedTarget = Self.alignedDown(target)
      guard
        (minimumTargetMemoryBytes...configuredMemoryBytes).contains(
          alignedTarget
        ),
        includedTargets.insert(alignedTarget).inserted
      else {
        return
      }
      options.append(
        VirtualMachineMemoryBalloonTargetOption(
          kind: kind,
          memoryBytes: alignedTarget
        )
      )
    }

    append(.full, target: configuredMemoryBytes)
    append(
      .threeQuarters,
      target: configuredMemoryBytes - configuredMemoryBytes / 4
    )
    append(.half, target: configuredMemoryBytes / 2)
    append(.minimum, target: minimumTargetMemoryBytes)
    return options
  }

  func validate() throws {
    guard configuredMemoryBytes >= minimumTargetMemoryBytes,
      configuredMemoryBytes.isMultiple(of: Self.alignmentBytes),
      minimumTargetMemoryBytes.isMultiple(of: Self.alignmentBytes)
    else {
      throw VirtualMachineMemoryBalloonError.invalidConfiguration
    }
    try validateTarget(targetMemoryBytes)
  }

  func validateTarget(_ memoryBytes: UInt64) throws {
    guard memoryBytes.isMultiple(of: Self.alignmentBytes) else {
      throw VirtualMachineMemoryBalloonError.targetMustUseWholeMebibytes
    }
    guard
      (minimumTargetMemoryBytes...configuredMemoryBytes).contains(
        memoryBytes
      )
    else {
      throw VirtualMachineMemoryBalloonError.targetOutsideRange(
        minimum: minimumTargetMemoryBytes,
        maximum: configuredMemoryBytes
      )
    }
  }

  private static func alignedDown(_ bytes: UInt64) -> UInt64 {
    bytes - bytes % alignmentBytes
  }
}

enum VirtualMachineMemoryBalloonTargetKind: Hashable, Sendable {
  case full
  case threeQuarters
  case half
  case minimum

  var label: LocalizedStringResource {
    switch self {
    case .full:
      "Full allocation"
    case .threeQuarters:
      "75% target"
    case .half:
      "50% target"
    case .minimum:
      "Minimum target"
    }
  }
}

struct VirtualMachineMemoryBalloonTargetOption:
  Equatable, Identifiable, Sendable
{
  let kind: VirtualMachineMemoryBalloonTargetKind
  let memoryBytes: UInt64

  var id: VirtualMachineMemoryBalloonTargetKind { kind }
}

enum VirtualMachineMemoryBalloonError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidConfiguration
  case targetMustUseWholeMebibytes
  case targetOutsideRange(minimum: UInt64, maximum: UInt64)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "This virtual machine does not expose a supported memory balloon device."
    case .invalidConfiguration:
      "The virtual machine memory balloon configuration is invalid."
    case .targetMustUseWholeMebibytes:
      "The guest memory target must use whole mebibytes."
    case .targetOutsideRange(let minimum, let maximum):
      "Choose a guest memory target between \(minimum) and \(maximum) bytes."
    }
  }
}
