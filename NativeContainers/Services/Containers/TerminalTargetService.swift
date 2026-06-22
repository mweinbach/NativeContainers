import Foundation

protocol TerminalTargetOpening: Sendable {
  func openTerminal(
    for target: TerminalTargetIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession
}

struct IdentityPinnedTerminalTargetService: TerminalTargetOpening {
  private let inventory: any ContainerInventoryLoading
  private let containerTerminal: any ContainerTerminalOpening
  private let machineTerminal: any MachineTerminalOpening
  private let podTerminal: any KubernetesPodTerminalOpening

  init(
    inventory: any ContainerInventoryLoading,
    containerTerminal: any ContainerTerminalOpening,
    machineTerminal: any MachineTerminalOpening,
    podTerminal: any KubernetesPodTerminalOpening =
      UnavailableKubernetesPodTerminalService()
  ) {
    self.inventory = inventory
    self.containerTerminal = containerTerminal
    self.machineTerminal = machineTerminal
    self.podTerminal = podTerminal
  }

  func openTerminal(
    for target: TerminalTargetIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    switch target {
    case .container(let identity):
      let currentInventory = try await inventory.loadInventory()
      guard
        let current = currentInventory.containers.first(where: { $0.id == identity.id })
      else {
        throw TerminalWorkspaceError.containerUnavailable(identity.id)
      }
      guard identity.matches(current) else {
        throw TerminalWorkspaceError.containerIdentityChanged(identity.id)
      }
      return try await containerTerminal.openTerminal(
        in: identity.id,
        request: request
      )

    case .linuxMachine(let identity):
      let currentInventory = try await inventory.loadInventory()
      guard
        let current = currentInventory.machines.first(where: { $0.id == identity.id })
      else {
        throw TerminalWorkspaceError.linuxMachineUnavailable(identity.id)
      }
      guard LinuxMachineIdentity(machine: current) == identity else {
        throw TerminalWorkspaceError.linuxMachineIdentityChanged(identity.id)
      }
      return try await machineTerminal.openTerminal(
        in: identity,
        request: try LinuxMachineTerminalRequest(containerRequest: request)
      )

    case .kubernetesPod(let identity):
      return try await podTerminal.openTerminal(
        in: identity,
        request: request
      )
    }
  }
}

struct UnavailableTerminalTargetService: TerminalTargetOpening {
  func openTerminal(
    for target: TerminalTargetIdentity,
    request: ContainerTerminalRequest
  ) async throws -> any ContainerTerminalSession {
    throw TerminalWorkspaceError.terminalServiceUnavailable
  }
}
