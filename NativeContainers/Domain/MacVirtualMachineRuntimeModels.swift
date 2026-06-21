import Foundation

struct ResolvedMacVirtualMachine: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let diskImageURL: URL
  let auxiliaryStorageURL: URL
  let hardwareModelURL: URL
  let machineIdentifierURL: URL
}

extension PreparedMacVirtualMachine {
  var resolvedMachine: ResolvedMacVirtualMachine {
    ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL
    )
  }
}

struct MacVirtualMachineRuntimeTarget: Equatable, Hashable, Sendable {
  let machineID: UUID
  let generation: UUID
}

enum MacVirtualMachineRuntimeState: Equatable, Sendable {
  case stopped
  case starting
  case running
  case pausing
  case paused
  case resuming
  case stopping
  case ownedElsewhere

  var label: String {
    switch self {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .pausing:
      "Pausing"
    case .paused:
      "Paused"
    case .resuming:
      "Resuming"
    case .stopping:
      "Stopping"
    case .ownedElsewhere:
      "Owned by another app instance"
    }
  }
}

struct MacVirtualMachineRuntimeSnapshot: Equatable, Sendable {
  let machineID: UUID
  let target: MacVirtualMachineRuntimeTarget?
  let state: MacVirtualMachineRuntimeState
  let errorMessage: String?

  init(
    machineID: UUID,
    target: MacVirtualMachineRuntimeTarget? = nil,
    state: MacVirtualMachineRuntimeState = .stopped,
    errorMessage: String? = nil
  ) {
    self.machineID = machineID
    self.target = target
    self.state = state
    self.errorMessage = errorMessage
  }

  var canStart: Bool {
    target == nil && (state == .stopped || state == .ownedElsewhere)
  }

  var canPause: Bool { state == .running }
  var canResume: Bool { state == .paused }
  var canRequestStop: Bool { state == .running || state == .paused }

  var canForceStop: Bool {
    target != nil && (state == .running || state == .paused || state == .stopping)
  }

  var canOpenConsole: Bool { target != nil }

  var isTransitioning: Bool {
    switch state {
    case .starting, .pausing, .resuming, .stopping:
      true
    case .stopped, .running, .paused, .ownedElsewhere:
      false
    }
  }
}

enum MacVirtualMachineRuntimeEvent: Equatable, Sendable {
  case guestStopped
  case stoppedWithError(String)
}

enum MacVirtualMachineRuntimeError: LocalizedError, Equatable, Sendable {
  case unavailable
  case requiresAppleSilicon
  case ownedElsewhere(UUID)
  case duplicateSession(UUID)
  case noActiveSession(UUID)
  case invalidState(UUID, MacVirtualMachineRuntimeState)
  case staleTarget(MacVirtualMachineRuntimeTarget)
  case operationUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "macOS virtual machine runtime support is unavailable in this app configuration."
    case .requiresAppleSilicon:
      "macOS virtual machines require a Mac with Apple silicon."
    case .ownedElsewhere(let identifier):
      "Virtual machine \(identifier.uuidString) is active in another NativeContainers process."
    case .duplicateSession(let identifier):
      "Virtual machine \(identifier.uuidString) already has an active runtime session."
    case .noActiveSession(let identifier):
      "Virtual machine \(identifier.uuidString) does not have an active runtime session."
    case .invalidState(let identifier, let state):
      "Virtual machine \(identifier.uuidString) cannot perform that operation while it is \(state.label.lowercased())."
    case .staleTarget(let target):
      "The requested operation belongs to an expired runtime session for virtual machine \(target.machineID.uuidString)."
    case .operationUnavailable(let operation):
      "Virtualization.framework cannot \(operation) the virtual machine in its current state."
    }
  }
}
