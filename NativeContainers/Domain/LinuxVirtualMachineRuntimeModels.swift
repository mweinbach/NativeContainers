import Foundation

enum LinuxVirtualMachineRuntimeState: Equatable, Sendable {
  case inspectingSavedState
  case stopped
  case starting
  case running
  case pausing
  case paused
  case resuming
  case saving
  case restoring
  case discardingSavedState
  case ejectingInstallationMedia
  case stopping
  case ownedElsewhere

  var label: LocalizedStringResource {
    switch self {
    case .inspectingSavedState:
      "Checking Saved State"
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
    case .saving:
      "Saving"
    case .restoring:
      "Restoring"
    case .discardingSavedState:
      "Discarding Saved State"
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
  let savedStateStatus: LinuxVirtualMachineSavedStateStatus
  let saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport
  let memoryBalloon: VirtualMachineMemoryBalloonSnapshot?
  let hasInstallationMedia: Bool
  let isReady: Bool
  let isForceStopQueued: Bool
  let isForceStopCompleteAwaitingCleanup: Bool
  let errorMessage: String?

  init(
    machineID: UUID,
    revision: UInt64 = 0,
    target: LinuxVirtualMachineRuntimeTarget? = nil,
    state: LinuxVirtualMachineRuntimeState = .stopped,
    savedStateStatus: LinuxVirtualMachineSavedStateStatus = .unknown,
    saveRestoreSupport: LinuxVirtualMachineSaveRestoreSupport = .unknown,
    memoryBalloon: VirtualMachineMemoryBalloonSnapshot? = nil,
    hasInstallationMedia: Bool = false,
    isReady: Bool = false,
    isForceStopQueued: Bool = false,
    isForceStopCompleteAwaitingCleanup: Bool = false,
    errorMessage: String? = nil
  ) {
    self.machineID = machineID
    self.revision = revision
    self.target = target
    self.state = state
    self.savedStateStatus = savedStateStatus
    self.saveRestoreSupport = saveRestoreSupport
    self.memoryBalloon = memoryBalloon
    self.hasInstallationMedia = hasInstallationMedia
    self.isReady = isReady
    self.isForceStopQueued = isForceStopQueued
    self.isForceStopCompleteAwaitingCleanup = isForceStopCompleteAwaitingCleanup
    self.errorMessage = errorMessage
  }

  var canStart: Bool {
    guard target == nil, state == .stopped || state == .ownedElsewhere else {
      return false
    }
    return switch savedStateStatus {
    case .unknown, .none, .available:
      true
    case .incompatible:
      false
    }
  }

  var canPause: Bool { state == .running }
  var canSetMemoryBalloonTarget: Bool {
    state == .running && memoryBalloon?.canRequestAnotherTarget == true
  }
  var canResume: Bool { state == .paused }
  var canSuspend: Bool {
    guard saveRestoreSupport.isSupported,
      state == .running || state == .paused
    else {
      return false
    }
    return switch savedStateStatus {
    case .unknown, .none:
      true
    case .available, .incompatible:
      false
    }
  }
  var canRequestStop: Bool { state == .running || state == .paused }
  var canStartFresh: Bool {
    guard target == nil, state == .stopped else { return false }
    return switch savedStateStatus {
    case .available, .incompatible:
      true
    case .unknown, .none:
      false
    }
  }
  var canDiscardSavedState: Bool { canStartFresh }

  var canEjectInstallationMedia: Bool {
    guard target != nil, hasInstallationMedia else { return false }
    return state == .running || state == .paused
  }

  var canForceStop: Bool {
    guard target != nil else { return false }
    return switch state {
    case .starting, .running, .pausing, .paused, .resuming, .saving,
      .restoring, .discardingSavedState, .ejectingInstallationMedia,
      .stopping:
      true
    case .inspectingSavedState, .stopped, .ownedElsewhere:
      false
    }
  }

  var canOpenConsole: Bool { target != nil }

  var isTransitioning: Bool {
    switch state {
    case .inspectingSavedState, .starting, .pausing, .resuming, .saving,
      .restoring, .discardingSavedState, .ejectingInstallationMedia,
      .stopping:
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
  case diskResizePending(UUID)
  case duplicateSession(UUID)
  case operationInProgress(UUID)
  case noActiveSession(UUID)
  case invalidState(UUID, LinuxVirtualMachineRuntimeState)
  case staleTarget(LinuxVirtualMachineRuntimeTarget)
  case operationUnavailable(String)
  case saveRestoreUnsupported(String)
  case installationMediaNotAttached(UUID)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Linux virtual machine runtime support is unavailable in this app configuration."
    case .ownedElsewhere(let identifier):
      "Virtual machine \(identifier.uuidString) is active in another NativeContainers process."
    case .diskReplacementPending(let identifier):
      "Virtual machine \(identifier.uuidString) has disk replacement recovery pending."
    case .diskResizePending(let identifier):
      "Virtual machine \(identifier.uuidString) has virtual disk growth recovery pending."
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
    case .saveRestoreUnsupported(let reason):
      "This virtual machine configuration does not support saving and restoring: \(reason)"
    case .installationMediaNotAttached(let identifier):
      "Virtual machine \(identifier.uuidString) does not have attached installation media."
    }
  }
}
