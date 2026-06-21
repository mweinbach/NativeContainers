import Foundation

enum LinuxVirtualMachineRuntimeState: Equatable, Sendable {
  case stopped
  case starting
  case running
  case pausing
  case paused
  case resuming
  case ejectingInstallationMedia
  case stopping
  case ownedElsewhere

  var label: LocalizedStringResource {
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
    case .ejectingInstallationMedia:
      "Ejecting Installer"
    case .stopping:
      "Stopping"
    case .ownedElsewhere:
      "Owned by another app instance"
    }
  }
}

struct LinuxVirtualMachineRuntimeSnapshot: Equatable, Sendable {
  let machineID: UUID
  let revision: UInt64
  let target: LinuxVirtualMachineRuntimeTarget?
  let state: LinuxVirtualMachineRuntimeState
  let hasInstallationMedia: Bool
  let isForceStopQueued: Bool
  let isForceStopCompleteAwaitingCleanup: Bool
  let errorMessage: String?

  init(
    machineID: UUID,
    revision: UInt64 = 0,
    target: LinuxVirtualMachineRuntimeTarget? = nil,
    state: LinuxVirtualMachineRuntimeState = .stopped,
    hasInstallationMedia: Bool = false,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    self.machineID = machineID
    self.revision = revision
    self.target = target
    self.state = state
    self.hasInstallationMedia = hasInstallationMedia
    self.isForceStopQueued = isForceStopQueued
    self.isForceStopCompleteAwaitingCleanup = isForceStopCompleteAwaitingCleanup
    self.errorMessage = errorMessage
  }

  var canStart: Bool {
    target == nil && (state == .stopped || state == .ownedElsewhere)
  }

  var canPause: Bool { state == .running }
  var canResume: Bool { state == .paused }
  var canRequestStop: Bool { state == .running || state == .paused }

  var canEjectInstallationMedia: Bool {
    guard target != nil, hasInstallationMedia else { return false }
    return state == .running || state == .paused
  }

  var canForceStop: Bool {
    guard target != nil else { return false }
    return switch state {
    case .starting, .running, .pausing, .paused, .resuming,
      .ejectingInstallationMedia, .stopping:
      true
    case .stopped, .ownedElsewhere:
      false
    }
  }

  var canOpenConsole: Bool { target != nil }

  var isTransitioning: Bool {
    switch state {
    case .starting, .pausing, .resuming, .ejectingInstallationMedia, .stopping:
      true
    case .stopped, .running, .paused, .ownedElsewhere:
      false
    }
  }
}

enum LinuxVirtualMachineRuntimeError: LocalizedError, Equatable, Sendable {
  case unavailable
  case ownedElsewhere(UUID)
  case diskReplacementPending(UUID)
  case duplicateSession(UUID)
  case operationInProgress(UUID)
  case noActiveSession(UUID)
  case invalidState(UUID, LinuxVirtualMachineRuntimeState)
  case staleTarget(LinuxVirtualMachineRuntimeTarget)
  case operationUnavailable(String)
  case installationMediaNotAttached(UUID)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Linux virtual machine runtime support is unavailable in this app configuration."
    case .ownedElsewhere(let identifier):
      "Virtual machine \(identifier.uuidString) is active in another NativeContainers process."
    case .diskReplacementPending(let identifier):
      "Virtual machine \(identifier.uuidString) has disk replacement recovery pending."
    case .duplicateSession(let identifier):
      "Virtual machine \(identifier.uuidString) already has an active runtime session."
    case .operationInProgress(let identifier):
      "Virtual machine \(identifier.uuidString) is already changing runtime state."
    case .noActiveSession(let identifier):
      "Virtual machine \(identifier.uuidString) does not have an active runtime session."
    case .invalidState(let identifier, let state):
      "Virtual machine \(identifier.uuidString) cannot perform that operation while it is \(String(localized: state.label).lowercased())."
    case .staleTarget(let target):
      "The requested operation belongs to an expired runtime session for virtual machine \(target.machineID.uuidString)."
    case .operationUnavailable(let operation):
      "Virtualization.framework cannot \(operation) the virtual machine in its current state."
    case .installationMediaNotAttached(let identifier):
      "Virtual machine \(identifier.uuidString) does not have attached installation media."
    }
  }
}
