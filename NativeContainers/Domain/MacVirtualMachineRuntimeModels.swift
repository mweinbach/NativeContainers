import Foundation

struct ResolvedMacVirtualMachine: Equatable, Sendable {
  let manifest: VirtualMachineManifest
  let bundleURL: URL
  let diskImageURL: URL
  let auxiliaryStorageURL: URL
  let hardwareModelURL: URL
  let machineIdentifierURL: URL
  let sharedDirectories: MacVirtualMachineSharedDirectoryConfiguration

  init(
    manifest: VirtualMachineManifest,
    bundleURL: URL,
    diskImageURL: URL,
    auxiliaryStorageURL: URL,
    hardwareModelURL: URL,
    machineIdentifierURL: URL,
    sharedDirectories: MacVirtualMachineSharedDirectoryConfiguration = .empty
  ) {
    self.manifest = manifest
    self.bundleURL = bundleURL
    self.diskImageURL = diskImageURL
    self.auxiliaryStorageURL = auxiliaryStorageURL
    self.hardwareModelURL = hardwareModelURL
    self.machineIdentifierURL = machineIdentifierURL
    self.sharedDirectories = sharedDirectories
  }
}

extension PreparedMacVirtualMachine {
  var resolvedMachine: ResolvedMacVirtualMachine {
    ResolvedMacVirtualMachine(
      manifest: manifest,
      bundleURL: bundleURL,
      diskImageURL: diskImageURL,
      auxiliaryStorageURL: auxiliaryStorageURL,
      hardwareModelURL: hardwareModelURL,
      machineIdentifierURL: machineIdentifierURL,
      sharedDirectories: .empty
    )
  }
}

struct MacVirtualMachineRuntimeTarget: Equatable, Hashable, Sendable {
  let machineID: UUID
  let generation: UUID
}

enum MacVirtualMachineSaveRestoreSupport: Equatable, Sendable {
  case unknown
  case supported
  case unsupported(String)

  var isSupported: Bool {
    self == .supported
  }
}

enum MacVirtualMachineRuntimeState: Equatable, Sendable {
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
    case .stopping:
      "Stopping"
    case .ownedElsewhere:
      "Owned by another app instance"
    }
  }
}

struct MacVirtualMachineRuntimeSnapshot: Equatable, Sendable {
  let machineID: UUID
  let revision: UInt64
  let target: MacVirtualMachineRuntimeTarget?
  let state: MacVirtualMachineRuntimeState
  let savedStateStatus: MacVirtualMachineSavedStateStatus
  let saveRestoreSupport: MacVirtualMachineSaveRestoreSupport
  let isForceStopQueued: Bool
  let isForceStopCompleteAwaitingCleanup: Bool
  let errorMessage: String?

  init(
    machineID: UUID,
    revision: UInt64 = 0,
    target: MacVirtualMachineRuntimeTarget? = nil,
    state: MacVirtualMachineRuntimeState = .stopped,
    savedStateStatus: MacVirtualMachineSavedStateStatus = .unknown,
    saveRestoreSupport: MacVirtualMachineSaveRestoreSupport = .unknown,
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
    self.isForceStopQueued = isForceStopQueued
    self.isForceStopCompleteAwaitingCleanup =
      isForceStopCompleteAwaitingCleanup
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
  var canDiscardSavedState: Bool {
    canStartFresh
  }

  var canForceStop: Bool {
    guard target != nil else { return false }
    return switch state {
    case .starting, .running, .pausing, .paused, .resuming, .saving, .restoring,
      .discardingSavedState, .stopping:
      true
    case .inspectingSavedState, .stopped, .ownedElsewhere:
      false
    }
  }

  var canOpenConsole: Bool { target != nil }

  var isTransitioning: Bool {
    switch state {
    case .inspectingSavedState, .starting, .pausing, .resuming, .saving, .restoring,
      .discardingSavedState, .stopping:
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
  case operationInProgress(UUID)
  case noActiveSession(UUID)
  case invalidState(UUID, MacVirtualMachineRuntimeState)
  case staleTarget(MacVirtualMachineRuntimeTarget)
  case operationUnavailable(String)
  case saveRestoreUnsupported(String)

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
    }
  }
}
