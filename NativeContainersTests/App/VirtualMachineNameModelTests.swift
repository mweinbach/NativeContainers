import Foundation
import Testing

@testable import NativeContainers

@Suite("Virtual machine name model")
@MainActor
struct VirtualMachineNameModelTests {
  @Test
  func loadPublishesPersistedNameOnlyOnce() async {
    let service = NameModelService(name: "Persisted")
    let model = VirtualMachineNameModel(
      machineID: UUID(),
      initialName: "Initial",
      service: service
    )

    await model.load()
    await model.load()

    #expect(model.isLoaded)
    #expect(model.name == "Persisted")
    #expect(!model.hasChanges)
    #expect(await service.loadCount == 1)
  }

  @Test
  func savePublishesTrimmedNameAndRefreshesInventory() async {
    let service = NameModelService(name: "Before")
    let refresh = NameRefreshRecorder()
    let model = VirtualMachineNameModel(
      machineID: UUID(),
      initialName: "Before",
      service: service
    ) {
      refresh.record()
    }
    await model.load()
    model.name = "  After  "

    let saved = await model.save()

    #expect(saved)
    #expect(model.name == "After")
    #expect(!model.hasChanges)
    #expect(await service.renameCount == 1)
    #expect(refresh.count == 1)
  }

  @Test
  func reloadPreservesAStagedNameUntilItIsReverted() async {
    let service = NameModelService(name: "Before")
    let model = VirtualMachineNameModel(
      machineID: UUID(),
      initialName: "Before",
      service: service
    )
    await model.load()
    model.name = "Draft"
    await service.replaceName("External")

    await model.reload()
    #expect(model.name == "Draft")

    model.resetChanges()
    await model.reload()
    #expect(model.name == "External")
    #expect(await service.loadCount == 2)
  }

  @Test
  func invalidAndFailedRenamesKeepTheDraftAvailable() async {
    let service = NameModelService(
      name: "Before",
      renameError: .unavailable
    )
    let model = VirtualMachineNameModel(
      machineID: UUID(),
      initialName: "Before",
      service: service
    )
    await model.load()

    model.name = "   "
    #expect(!model.hasValidName)
    #expect(!model.canSave)
    #expect(!(await model.save()))

    model.name = "After"
    #expect(!(await model.save()))
    #expect(model.name == "After")
    #expect(model.hasChanges)
    #expect(model.errorMessage?.contains("unavailable") == true)
  }
}

private actor NameModelService: VirtualMachineNameManaging {
  private var name: String
  private let renameError: VirtualMachineNameError?
  private(set) var loadCount = 0
  private(set) var renameCount = 0

  init(
    name: String,
    renameError: VirtualMachineNameError? = nil
  ) {
    self.name = name
    self.renameError = renameError
  }

  func currentName(id: UUID) -> String {
    loadCount += 1
    return name
  }

  func rename(_ name: String, for machineID: UUID) throws -> String {
    renameCount += 1
    if let renameError {
      throw renameError
    }
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return self.name
  }

  func replaceName(_ name: String) {
    self.name = name
  }
}

private final class NameRefreshRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCount = 0

  var count: Int { lock.withLock { storedCount } }

  func record() {
    lock.withLock { storedCount += 1 }
  }
}
