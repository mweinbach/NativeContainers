import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineUSBModel {
  let machineID: UUID

  private(set) var snapshot: MacVirtualMachineUSBSnapshot
  private(set) var runtimeState: MacVirtualMachineRuntimeState
  private(set) var isDiscovering = false
  private(set) var workingDeviceID: UInt64?
  private(set) var errorMessage: String?

  private let service: any MacVirtualMachineUSBManaging
  private let runtime: any MacVirtualMachineRuntimeManaging
  @ObservationIgnored private var usbObservationTask: Task<Void, Never>?
  @ObservationIgnored private var runtimeObservationTask: Task<Void, Never>?
  @ObservationIgnored private var runtimeRevision: UInt64

  init(
    machineID: UUID,
    service: any MacVirtualMachineUSBManaging,
    runtime: any MacVirtualMachineRuntimeManaging
  ) {
    self.machineID = machineID
    self.service = service
    self.runtime = runtime

    let runtimeSnapshot = runtime.snapshot(for: machineID)
    runtimeState = runtimeSnapshot.state
    runtimeRevision = runtimeSnapshot.revision
    service.setRuntimeTarget(runtimeSnapshot.target, for: machineID)
    snapshot = service.snapshot(for: machineID)
  }

  var canAttachDevices: Bool {
    runtimeState == .running || runtimeState == .paused
  }

  func observe() {
    if usbObservationTask == nil {
      let updates = service.updates(for: machineID)
      usbObservationTask = Task { @MainActor [weak self] in
        for await update in updates {
          guard !Task.isCancelled, let self else { return }
          apply(update)
        }
      }
    }

    if runtimeObservationTask == nil {
      let updates = runtime.updates(for: machineID)
      runtimeObservationTask = Task { @MainActor [weak self] in
        for await update in updates {
          guard !Task.isCancelled, let self else { return }
          apply(update)
        }
      }
    }
  }

  @discardableResult
  func discover() async -> Bool {
    guard !isDiscovering else { return false }
    isDiscovering = true
    errorMessage = nil
    defer {
      isDiscovering = false
      snapshot = service.snapshot(for: machineID)
    }

    do {
      try await service.discover(for: machineID)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func attach(deviceID: UInt64) async -> Bool {
    guard canAttachDevices,
      workingDeviceID == nil,
      let target = snapshot.target
    else {
      return false
    }
    return await perform(deviceID: deviceID) {
      try await service.attach(deviceID: deviceID, to: target)
    }
  }

  @discardableResult
  func detach(deviceID: UInt64) async -> Bool {
    guard workingDeviceID == nil,
      let target = snapshot.target
    else {
      return false
    }
    return await perform(deviceID: deviceID) {
      try await service.detach(deviceID: deviceID, from: target)
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func stopObserving() {
    usbObservationTask?.cancel()
    runtimeObservationTask?.cancel()
    usbObservationTask = nil
    runtimeObservationTask = nil
    service.setRuntimeTarget(nil, for: machineID)
    snapshot = service.snapshot(for: machineID)
  }

  private func apply(_ update: MacVirtualMachineUSBSnapshot) {
    guard update.revision >= snapshot.revision else { return }
    snapshot = update
  }

  private func apply(_ update: MacVirtualMachineRuntimeSnapshot) {
    guard update.revision >= runtimeRevision else { return }
    runtimeRevision = update.revision
    runtimeState = update.state
    service.setRuntimeTarget(update.target, for: machineID)
    snapshot = service.snapshot(for: machineID)
  }

  private func perform(
    deviceID: UInt64,
    operation: () async throws -> Void
  ) async -> Bool {
    workingDeviceID = deviceID
    errorMessage = nil
    defer {
      workingDeviceID = nil
      snapshot = service.snapshot(for: machineID)
    }

    do {
      try await operation()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  deinit {
    usbObservationTask?.cancel()
    runtimeObservationTask?.cancel()
  }
}
