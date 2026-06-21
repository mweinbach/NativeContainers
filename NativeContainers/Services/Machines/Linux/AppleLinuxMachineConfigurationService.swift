import Foundation
import MachineAPIClient

struct AppleLinuxMachineConfigurationService: MachineConfigurationManaging {
  private enum Reconciliation: Sendable {
    case confirmed(LinuxMachineConfigurationUpdateResult)
    case missing
    case stale
    case different
    case unknown(String)
  }

  private let machineTransport: any AppleMachineTransport
  private let runtimeMutationCoordinator: RuntimeMutationCoordinator

  init(
    machineTransport: any AppleMachineTransport = AppleMachineXPCTransport(),
    runtimeMutationCoordinator: RuntimeMutationCoordinator = .shared
  ) {
    self.machineTransport = machineTransport
    self.runtimeMutationCoordinator = runtimeMutationCoordinator
  }

  func updateConfiguration(
    for target: LinuxMachineIdentity,
    request: LinuxMachineConfigurationUpdateRequest
  ) async throws -> LinuxMachineConfigurationUpdateResult {
    try await runtimeMutationCoordinator.perform {
      guard target.hasStableCreationIdentity else {
        throw LinuxMachineConfigurationError.stableIdentityRequired(target.id)
      }

      let current = try await currentSnapshot(for: target)
      let desired = request.configuration
      if try AppleLinuxMachineSnapshotMapper.configuration(from: current) == desired {
        return Self.result(for: target, configuration: desired, snapshot: current)
      }

      let bootConfig = try AppleLinuxMachineSnapshotMapper.applying(
        desired,
        to: current.bootConfig
      )

      do {
        try await machineTransport.setConfig(id: target.id, bootConfig: bootConfig)
      } catch {
        let reconciliation = await reconcileIgnoringCancellation(
          target: target,
          desired: desired
        )
        switch reconciliation {
        case .confirmed(let result):
          return result
        case .missing:
          throw LinuxMachineConfigurationError.missing(target.id)
        case .stale:
          throw LinuxMachineConfigurationError.staleTarget(target.id)
        case .different:
          throw error
        case .unknown(let verification):
          throw LinuxMachineConfigurationError.updateOutcomeUnknown(
            id: target.id,
            operation: error.localizedDescription,
            reconciliation: verification
          )
        }
      }

      switch await reconcileIgnoringCancellation(target: target, desired: desired) {
      case .confirmed(let result):
        return result
      case .missing:
        throw LinuxMachineConfigurationError.missing(target.id)
      case .stale:
        throw LinuxMachineConfigurationError.staleTarget(target.id)
      case .different:
        throw LinuxMachineConfigurationError.updateNotConfirmed(target.id)
      case .unknown(let verification):
        throw LinuxMachineConfigurationError.updateOutcomeUnknown(
          id: target.id,
          operation: "the request returned without an error.",
          reconciliation: verification
        )
      }
    }
  }

  private func currentSnapshot(
    for target: LinuxMachineIdentity
  ) async throws -> MachineSnapshot {
    let machines = try await machineTransport.list()
    guard machines.contains(where: { $0.id == target.id }) else {
      throw LinuxMachineConfigurationError.missing(target.id)
    }

    let current = try await machineTransport.inspect(id: target.id)
    guard AppleLinuxMachineSnapshotMapper.identity(from: current) == target else {
      throw LinuxMachineConfigurationError.staleTarget(target.id)
    }
    return current
  }

  private func reconcileIgnoringCancellation(
    target: LinuxMachineIdentity,
    desired: LinuxMachineConfiguration
  ) async -> Reconciliation {
    let transport = machineTransport
    return await Task.detached {
      do {
        let machines = try await transport.list()
        guard machines.contains(where: { $0.id == target.id }) else {
          return Reconciliation.missing
        }

        let snapshot = try await transport.inspect(id: target.id)
        guard AppleLinuxMachineSnapshotMapper.identity(from: snapshot) == target else {
          return Reconciliation.stale
        }
        guard try AppleLinuxMachineSnapshotMapper.configuration(from: snapshot) == desired
        else {
          return Reconciliation.different
        }
        return Reconciliation.confirmed(
          Self.result(for: target, configuration: desired, snapshot: snapshot)
        )
      } catch {
        return Reconciliation.unknown(error.localizedDescription)
      }
    }.value
  }

  private static func result(
    for target: LinuxMachineIdentity,
    configuration: LinuxMachineConfiguration,
    snapshot: MachineSnapshot
  ) -> LinuxMachineConfigurationUpdateResult {
    LinuxMachineConfigurationUpdateResult(
      target: target,
      configuration: configuration,
      state: AppleLinuxMachineSnapshotMapper.state(from: snapshot)
    )
  }
}
