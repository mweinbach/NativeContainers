import Foundation
import Observation

@MainActor
@Observable
final class VirtualMachineSharedDirectoriesModel {
  let machineID: UUID

  private(set) var directories: [VirtualMachineSharedDirectorySummary]
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any VirtualMachineSharedDirectoryManaging

  init(
    machineID: UUID,
    initialConfiguration: VirtualMachineSharedDirectoryConfiguration = .empty,
    service: any VirtualMachineSharedDirectoryManaging
  ) {
    self.machineID = machineID
    self.service = service
    directories = Self.sortedSummaries(from: initialConfiguration)
  }

  func load() async {
    guard !isLoading, !isWorking else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      apply(try await service.configuration(id: machineID))
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
        request: VirtualMachineSharedDirectoryRequest(
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
      async throws -> VirtualMachineSharedDirectoryConfiguration
  ) async -> Bool {
    guard !isLoading, !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      apply(try await operation())
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func apply(_ configuration: VirtualMachineSharedDirectoryConfiguration) {
    directories = Self.sortedSummaries(from: configuration)
  }

  private static func sortedSummaries(
    from configuration: VirtualMachineSharedDirectoryConfiguration
  ) -> [VirtualMachineSharedDirectorySummary] {
    configuration.directories.map(\.summary).sorted {
      let comparison = $0.guestName.localizedStandardCompare($1.guestName)
      if comparison != .orderedSame {
        return comparison == .orderedAscending
      }
      return $0.id.uuidString < $1.id.uuidString
    }
  }
}

typealias MacVirtualMachineSharedDirectoriesModel =
  VirtualMachineSharedDirectoriesModel
typealias LinuxVirtualMachineSharedDirectoriesModel =
  VirtualMachineSharedDirectoriesModel
