import Foundation
import Observation

@MainActor
@Observable
final class MacVirtualMachineSharedDirectoriesModel {
  let machineID: UUID

  private var configuration: MacVirtualMachineSharedDirectoryConfiguration
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any MacVirtualMachineSharedDirectoryManaging

  init(
    machineID: UUID,
    initialConfiguration: MacVirtualMachineSharedDirectoryConfiguration = .empty,
    service: any MacVirtualMachineSharedDirectoryManaging
  ) {
    self.machineID = machineID
    self.configuration = initialConfiguration
    self.service = service
  }

  var directories: [MacVirtualMachineSharedDirectorySummary] {
    configuration.directories.map(\.summary).sorted {
      let comparison = $0.guestName.localizedStandardCompare($1.guestName)
      if comparison != .orderedSame {
        return comparison == .orderedAscending
      }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  func load() async {
    guard !isLoading, !isWorking else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      configuration = try await service.configuration(id: machineID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func add(
    sourceURL: URL,
    guestName: String,
    readOnly: Bool
  ) async -> Bool {
    await mutate {
      try await self.service.add(
        to: self.machineID,
        request: MacVirtualMachineSharedDirectoryRequest(
          sourceURL: sourceURL,
          guestName: guestName,
          readOnly: readOnly
        )
      )
    }
  }

  func remove(id: UUID) async -> Bool {
    await mutate {
      try await self.service.remove(
        from: self.machineID,
        sharedDirectoryID: id
      )
    }
  }

  func report(_ error: any Error) {
    errorMessage = error.localizedDescription
  }

  func clearError() {
    errorMessage = nil
  }

  private func mutate(
    _ operation:
      @escaping @MainActor @Sendable ()
      async throws -> MacVirtualMachineSharedDirectoryConfiguration
  ) async -> Bool {
    guard !isLoading, !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      configuration = try await operation()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
