import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineNetworkModel {
  let machineID: UUID

  private(set) var attachment: VirtualMachineNetworkAttachment
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any VirtualMachineNetworkManaging
  @ObservationIgnored private var hasLoaded = false

  init(
    machineID: UUID,
    initialConfiguration: VirtualMachineNetworkConfiguration = .nat,
    service: any VirtualMachineNetworkManaging
  ) {
    self.machineID = machineID
    attachment = initialConfiguration.attachment
    self.service = service
  }

  func load() async {
    guard !hasLoaded, !isLoading, !isWorking else { return }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      apply(try await service.snapshot(id: machineID))
      hasLoaded = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func use(_ attachment: VirtualMachineNetworkAttachment) async -> Bool {
    guard !isLoading, !isWorking, attachment != self.attachment else {
      return false
    }

    isWorking = true
    errorMessage = nil
    defer { isWorking = false }

    do {
      apply(
        try await service.setAttachment(
          attachment,
          for: machineID
        )
      )
      hasLoaded = true
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func apply(_ snapshot: VirtualMachineNetworkSnapshot) {
    attachment = snapshot.configuration.attachment
  }
}

typealias MacVirtualMachineNetworkModel = VirtualMachineNetworkModel
typealias LinuxVirtualMachineNetworkModel = VirtualMachineNetworkModel
