import Foundation

struct VirtualMachineComputeConfiguration: Equatable, Sendable {
  static let bytesPerMiB: UInt64 = 1_048_576

  let cpuCount: Int
  let memoryBytes: UInt64

  init(cpuCount: Int, memoryBytes: UInt64) {
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
  }

  init(resources: VirtualMachineResources) {
    self.init(
      cpuCount: resources.cpuCount,
      memoryBytes: resources.memoryBytes
    )
  }

  func applying(to resources: VirtualMachineResources) throws -> VirtualMachineResources {
    try VirtualMachineResources(
      cpuCount: cpuCount,
      memoryBytes: memoryBytes,
      diskBytes: resources.diskBytes
    )
  }
}

struct VirtualMachineComputeLimits: Equatable, Sendable {
  let minimumCPUCount: Int
  let maximumCPUCount: Int
  let minimumMemoryBytes: UInt64
  let maximumMemoryBytes: UInt64

  func applyingGuestMinimum(
    cpuCount: Int?,
    memoryBytes: UInt64?
  ) throws -> VirtualMachineComputeLimits {
    let minimumCPUCount = max(self.minimumCPUCount, cpuCount ?? self.minimumCPUCount)
    let minimumMemoryBytes = max(
      self.minimumMemoryBytes,
      memoryBytes ?? self.minimumMemoryBytes
    )
    guard minimumCPUCount <= maximumCPUCount,
      minimumMemoryBytes <= maximumMemoryBytes
    else {
      throw VirtualMachineComputeError.hostCannotSupportGuestRequirements
    }
    return VirtualMachineComputeLimits(
      minimumCPUCount: minimumCPUCount,
      maximumCPUCount: maximumCPUCount,
      minimumMemoryBytes: minimumMemoryBytes,
      maximumMemoryBytes: maximumMemoryBytes
    )
  }

  func validate(_ configuration: VirtualMachineComputeConfiguration) throws {
    guard (minimumCPUCount...maximumCPUCount).contains(configuration.cpuCount) else {
      throw VirtualMachineComputeError.invalidCPUCount(
        minimum: minimumCPUCount,
        maximum: maximumCPUCount
      )
    }
    guard
      configuration.memoryBytes.isMultiple(
        of: VirtualMachineComputeConfiguration.bytesPerMiB
      )
    else {
      throw VirtualMachineComputeError.memoryMustBeMegabyteAligned
    }
    guard
      (minimumMemoryBytes...maximumMemoryBytes).contains(
        configuration.memoryBytes
      )
    else {
      throw VirtualMachineComputeError.invalidMemorySize(
        minimum: minimumMemoryBytes,
        maximum: maximumMemoryBytes
      )
    }
  }

  static func conservative(
    resources: VirtualMachineResources
  ) -> VirtualMachineComputeLimits {
    VirtualMachineComputeLimits(
      minimumCPUCount: resources.cpuCount,
      maximumCPUCount: resources.cpuCount,
      minimumMemoryBytes: resources.memoryBytes,
      maximumMemoryBytes: resources.memoryBytes
    )
  }
}

struct VirtualMachineComputeState: Equatable, Sendable {
  let guest: VirtualMachineGuest
  let configuration: VirtualMachineComputeConfiguration
  let diskBytes: UInt64
  let guestMinimumCPUCount: Int?
  let guestMinimumMemoryBytes: UInt64?

  init(
    guest: VirtualMachineGuest,
    configuration: VirtualMachineComputeConfiguration,
    diskBytes: UInt64,
    guestMinimumCPUCount: Int?,
    guestMinimumMemoryBytes: UInt64?
  ) {
    self.guest = guest
    self.configuration = configuration
    self.diskBytes = diskBytes
    self.guestMinimumCPUCount = guestMinimumCPUCount
    self.guestMinimumMemoryBytes = guestMinimumMemoryBytes
  }

  init(manifest: VirtualMachineManifest) {
    guest = manifest.guest
    configuration = VirtualMachineComputeConfiguration(
      resources: manifest.resources
    )
    diskBytes = manifest.resources.diskBytes
    guestMinimumCPUCount = manifest.macOSMinimumCPUCount
    guestMinimumMemoryBytes = manifest.macOSMinimumMemoryBytes
  }

  func snapshot(
    platformLimits: VirtualMachineComputeLimits
  ) throws -> VirtualMachineComputeSnapshot {
    let guestMinimums = try effectiveGuestMinimums()
    return VirtualMachineComputeSnapshot(
      configuration: configuration,
      diskBytes: diskBytes,
      limits: try platformLimits.applyingGuestMinimum(
        cpuCount: guestMinimums.cpuCount,
        memoryBytes: guestMinimums.memoryBytes
      )
    )
  }

  static func validatePersistedRequirements(
    in manifest: VirtualMachineManifest
  ) throws {
    _ = try VirtualMachineComputeState(manifest: manifest)
      .effectiveGuestMinimums()
  }

  private func effectiveGuestMinimums() throws -> (
    cpuCount: Int?,
    memoryBytes: UInt64?
  ) {
    switch guest {
    case .linux, .windows:
      guard guestMinimumCPUCount == nil,
        guestMinimumMemoryBytes == nil
      else {
        throw VirtualMachineComputeError.invalidPersistedGuestRequirements
      }
      if guest == .windows {
        return (
          2,
          4 * VirtualMachineResources.bytesPerGiB
        )
      }
      return (nil, nil)
    case .macOS:
      switch (guestMinimumCPUCount, guestMinimumMemoryBytes) {
      case (nil, nil):
        return (configuration.cpuCount, configuration.memoryBytes)
      case (.some(let cpuCount), .some(let memoryBytes)):
        guard cpuCount > 0,
          cpuCount <= configuration.cpuCount,
          memoryBytes > 0,
          memoryBytes <= configuration.memoryBytes,
          memoryBytes.isMultiple(
            of: VirtualMachineComputeConfiguration.bytesPerMiB
          )
        else {
          throw VirtualMachineComputeError.invalidPersistedGuestRequirements
        }
        return (cpuCount, memoryBytes)
      default:
        throw VirtualMachineComputeError.invalidPersistedGuestRequirements
      }
    }
  }
}

struct VirtualMachineComputeSnapshot: Equatable, Sendable {
  let configuration: VirtualMachineComputeConfiguration
  let diskBytes: UInt64
  let limits: VirtualMachineComputeLimits
}

enum VirtualMachineComputeError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidCPUCount(minimum: Int, maximum: Int)
  case invalidMemorySize(minimum: UInt64, maximum: UInt64)
  case memoryMustBeMegabyteAligned
  case hostCannotSupportGuestRequirements
  case invalidPersistedGuestRequirements
  case savedStateBlocksChanges(UUID)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Virtual machine compute configuration is unavailable."
    case .invalidCPUCount(let minimum, let maximum):
      "Choose between \(minimum) and \(maximum) virtual CPUs."
    case .invalidMemorySize(let minimum, let maximum):
      "Choose between \(Self.gibibytes(roundingUp: minimum)) and \(maximum / VirtualMachineResources.bytesPerGiB) GiB of memory."
    case .memoryMustBeMegabyteAligned:
      "Virtual machine memory must use whole mebibytes."
    case .hostCannotSupportGuestRequirements:
      "This Mac cannot satisfy the guest’s minimum CPU or memory requirements."
    case .invalidPersistedGuestRequirements:
      "The virtual machine’s stored guest CPU and memory requirements are incomplete or inconsistent with its current allocation."
    case .savedStateBlocksChanges:
      "Discard the saved state before changing this virtual machine’s CPU or memory."
    }
  }

  private static func gibibytes(roundingUp bytes: UInt64) -> UInt64 {
    let unit = VirtualMachineResources.bytesPerGiB
    return (bytes + unit - 1) / unit
  }
}
