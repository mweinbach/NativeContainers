import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineComputeModel {
  let machineID: UUID

  var cpuCount: Int
  var memoryGiB: Int

  private(set) var diskBytes: UInt64
  private(set) var limits: VirtualMachineComputeLimits
  private(set) var isLoaded = false
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any VirtualMachineComputeManaging
  private let didPersist: @MainActor @Sendable () async -> Void
  @ObservationIgnored
  private var persistedConfiguration: VirtualMachineComputeConfiguration

  init(
    machineID: UUID,
    initialResources: VirtualMachineResources,
    service: any VirtualMachineComputeManaging,
    didPersist: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    cpuCount = initialResources.cpuCount
    memoryGiB = Self.gibibytes(roundingUp: initialResources.memoryBytes)
    diskBytes = initialResources.diskBytes
    limits = .conservative(resources: initialResources)
    persistedConfiguration = VirtualMachineComputeConfiguration(
      resources: initialResources
    )
    self.service = service
    self.didPersist = didPersist
  }

  var cpuRange: ClosedRange<Int> {
    limits.minimumCPUCount...limits.maximumCPUCount
  }

  var memoryGiBRange: ClosedRange<Int> {
    let minimum = Self.gibibytes(roundingUp: limits.minimumMemoryBytes)
    let maximum = Int(
      limits.maximumMemoryBytes / VirtualMachineResources.bytesPerGiB
    )
    return minimum...maximum
  }

  var hasChanges: Bool {
    guard let stagedConfiguration else { return true }
    return stagedConfiguration != persistedConfiguration
  }

  func load() async {
    await load(force: false)
  }

  func reload() async {
    guard !isLoaded || !hasChanges else { return }
    await load(force: true)
  }

  private func load(force: Bool) async {
    guard force || !isLoaded, !isLoading, !isWorking else { return }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      apply(try await service.snapshot(id: machineID))
      isLoaded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func save() async -> Bool {
    guard isLoaded, !isLoading, !isWorking, hasChanges else {
      return false
    }
    guard let stagedConfiguration else {
      errorMessage =
        VirtualMachineComputeError.invalidMemorySize(
          minimum: limits.minimumMemoryBytes,
          maximum: limits.maximumMemoryBytes
        ).localizedDescription
      return false
    }

    isWorking = true
    errorMessage = nil
    defer { isWorking = false }

    do {
      apply(
        try await service.setConfiguration(
          stagedConfiguration,
          for: machineID
        )
      )
      await didPersist()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func resetChanges() {
    cpuCount = persistedConfiguration.cpuCount
    memoryGiB = Self.gibibytes(
      roundingUp: persistedConfiguration.memoryBytes
    )
  }

  func clearError() {
    errorMessage = nil
  }

  private var stagedConfiguration: VirtualMachineComputeConfiguration? {
    guard memoryGiB > 0,
      let memoryBytes = UInt64(exactly: memoryGiB)?.multipliedReportingOverflow(
        by: VirtualMachineResources.bytesPerGiB
      ),
      !memoryBytes.overflow
    else {
      return nil
    }
    return VirtualMachineComputeConfiguration(
      cpuCount: cpuCount,
      memoryBytes: memoryBytes.partialValue
    )
  }

  private func apply(_ snapshot: VirtualMachineComputeSnapshot) {
    persistedConfiguration = snapshot.configuration
    cpuCount = snapshot.configuration.cpuCount
    memoryGiB = Self.gibibytes(
      roundingUp: snapshot.configuration.memoryBytes
    )
    diskBytes = snapshot.diskBytes
    limits = snapshot.limits
    isLoaded = true
  }

  private static func gibibytes(roundingUp bytes: UInt64) -> Int {
    let unit = VirtualMachineResources.bytesPerGiB
    return Int(clamping: (bytes + unit - 1) / unit)
  }
}
