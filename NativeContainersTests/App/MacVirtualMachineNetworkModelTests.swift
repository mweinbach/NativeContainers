import Foundation
import Testing

@testable import NativeContainers

@Suite("Mac virtual machine network model")
@MainActor
struct MacVirtualMachineNetworkModelTests {
  @Test
  func loadPublishesPersistedConfigurationOnlyOnce() async {
    let service = NetworkModelService(
      configuration: MacVirtualMachineNetworkConfiguration(
        revision: 4,
        attachment: .hostOnly
      )
    )
    let model = MacVirtualMachineNetworkModel(
      machineID: UUID(),
      service: service
    )

    await model.load()

    #expect(model.attachment == .hostOnly)
    #expect(model.errorMessage == nil)
    #expect(await service.snapshotCount == 1)

    await model.load()
    #expect(await service.snapshotCount == 1)
  }

  @Test
  func successfulMutationPublishesTheReturnedSnapshot() async {
    let service = NetworkModelService(configuration: .nat)
    let model = MacVirtualMachineNetworkModel(
      machineID: UUID(),
      service: service
    )

    let changed = await model.use(.shared)

    #expect(changed)
    #expect(model.attachment == .shared)
    #expect(model.errorMessage == nil)
    #expect(await service.setCount == 1)
  }

  @Test
  func failedMutationKeepsThePriorModeAndSurfacesTheError() async {
    let service = NetworkModelService(
      configuration: MacVirtualMachineNetworkConfiguration(
        revision: 2,
        attachment: .hostOnly
      ),
      mutationError: .unavailable
    )
    let model = MacVirtualMachineNetworkModel(
      machineID: UUID(),
      initialConfiguration: MacVirtualMachineNetworkConfiguration(
        revision: 2,
        attachment: .hostOnly
      ),
      service: service
    )

    let changed = await model.use(.shared)

    #expect(!changed)
    #expect(model.attachment == .hostOnly)
    #expect(model.errorMessage?.contains("unavailable") == true)

    model.clearError()
    #expect(model.errorMessage == nil)
  }
}

private actor NetworkModelService: MacVirtualMachineNetworkManaging {
  private var configuration: MacVirtualMachineNetworkConfiguration
  private let mutationError: MacVirtualMachineNetworkError?
  private(set) var snapshotCount = 0
  private(set) var setCount = 0

  init(
    configuration: MacVirtualMachineNetworkConfiguration,
    mutationError: MacVirtualMachineNetworkError? = nil
  ) {
    self.configuration = configuration
    self.mutationError = mutationError
  }

  func snapshot(id: UUID) throws -> MacVirtualMachineNetworkSnapshot {
    snapshotCount += 1
    return MacVirtualMachineNetworkSnapshot(configuration: configuration)
  }

  func setAttachment(
    _ attachment: MacVirtualMachineNetworkAttachment,
    for machineID: UUID
  ) throws -> MacVirtualMachineNetworkSnapshot {
    setCount += 1
    if let mutationError {
      throw mutationError
    }
    configuration = try configuration.settingAttachment(attachment)
    return MacVirtualMachineNetworkSnapshot(configuration: configuration)
  }
}
