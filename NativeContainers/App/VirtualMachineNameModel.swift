import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineNameModel {
  let machineID: UUID
  var name: String

  private(set) var isLoaded = false
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any VirtualMachineNameManaging
  private let didPersist: @MainActor @Sendable () async -> Void
  @ObservationIgnored private var persistedName: String

  init(
    machineID: UUID,
    initialName: String,
    service: any VirtualMachineNameManaging,
    didPersist: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.machineID = machineID
    name = initialName
    persistedName = initialName
    self.service = service
    self.didPersist = didPersist
  }

  var hasChanges: Bool {
    name != persistedName
  }

  var hasValidName: Bool {
    !normalizedName.isEmpty
  }

  var canSave: Bool {
    hasValidName && normalizedName != persistedName
  }

  func load() async {
    await load(force: false)
  }

  func reload() async {
    guard !isLoaded || !hasChanges else { return }
    await load(force: true)
  }

  @discardableResult
  func save() async -> Bool {
    guard isLoaded, !isLoading, !isWorking, canSave else { return false }

    isWorking = true
    errorMessage = nil
    defer { isWorking = false }

    do {
      apply(try await service.rename(name, for: machineID))
      await didPersist()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func resetChanges() {
    name = persistedName
  }

  func clearError() {
    errorMessage = nil
  }

  private func load(force: Bool) async {
    guard force || !isLoaded, !isLoading, !isWorking else { return }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      apply(try await service.currentName(id: machineID))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var normalizedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func apply(_ name: String) {
    persistedName = name
    self.name = name
    isLoaded = true
  }
}
