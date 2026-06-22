import Foundation
import Testing

@testable import NativeContainers

struct MacVirtualMachineConfigurationEditPolicyTests {
  @Test
  func centralizesStoppedAndSavedStateRules() {
    let policy = MacVirtualMachineConfigurationEditPolicy()
    let identifier = UUID()
    let stopped = MacVirtualMachineRuntimeSnapshot(
      machineID: identifier,
      state: .stopped,
      savedStateStatus: .none
    )
    let saved = MacVirtualMachineRuntimeSnapshot(
      machineID: identifier,
      state: .stopped,
      savedStateStatus: .available(
        MacVirtualMachineSavedStateSummary(
          createdAt: Date(timeIntervalSince1970: 1),
          stateSizeBytes: 1
        )
      )
    )

    #expect(
      policy.block(
        installState: .stopped,
        runtime: stopped,
        diskMaintenanceIsBusy: false
      ) == nil
    )
    #expect(
      policy.block(
        installState: .stopped,
        runtime: saved,
        diskMaintenanceIsBusy: false
      ) == .savedStatePresent
    )
    #expect(
      policy.block(
        installState: .stopped,
        runtime: stopped,
        diskMaintenanceIsBusy: true
      ) == .diskMaintenance
    )
    #expect(
      policy.nameBlock(
        installState: .stopped,
        runtime: saved,
        diskMaintenanceIsBusy: false
      ) == nil
    )
    #expect(
      policy.nameBlock(
        installState: .stopped,
        runtime: stopped,
        diskMaintenanceIsBusy: true
      ) == .diskMaintenance
    )
  }
}
