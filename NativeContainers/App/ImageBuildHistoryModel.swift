import Foundation
import Observation

@MainActor
@Observable
final class ImageBuildHistoryModel {
  private(set) var records: [ImageBuildHistoryRecord]
  private(set) var rejectedRecordCount: Int
  private(set) var isBusy = false
  private(set) var errorMessage: String?

  private let service: any ImageBuildHistoryStoring
  private var refreshRequested = false

  init(
    service: any ImageBuildHistoryStoring,
    initialSnapshot: ImageBuildHistorySnapshot? = nil
  ) {
    self.service = service
    records = initialSnapshot?.records ?? []
    rejectedRecordCount = initialSnapshot?.rejectedRecordCount ?? 0
  }

  func observe() async {
    let updates = await service.updates()
    await refresh()

    for await _ in updates {
      guard !Task.isCancelled else { return }
      await refresh()
    }
  }

  func refresh() async {
    guard !isBusy else {
      refreshRequested = true
      return
    }

    isBusy = true
    defer { isBusy = false }

    repeat {
      refreshRequested = false
      errorMessage = nil

      do {
        apply(try await service.load())
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    } while refreshRequested && !Task.isCancelled
  }

  func remove(id: UUID) async {
    await mutate {
      try await self.service.remove(id: id)
    }
  }

  func removeAll() async {
    await mutate {
      try await self.service.removeAll()
    }
  }

  func clearError() {
    errorMessage = nil
  }

  private func mutate(
    _ operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil

    do {
      try await operation()
      apply(try await service.load())
    } catch is CancellationError {
      await reloadBestEffort()
    } catch {
      let message = error.localizedDescription
      await reloadBestEffort()
      errorMessage = message
    }

    let mutationError = errorMessage
    isBusy = false

    if refreshRequested, !Task.isCancelled {
      await refresh()
      if let mutationError {
        errorMessage = mutationError
      }
    }
  }

  private func reloadBestEffort() async {
    if let snapshot = try? await service.load() {
      apply(snapshot)
    }
  }

  private func apply(_ snapshot: ImageBuildHistorySnapshot) {
    if records != snapshot.records {
      records = snapshot.records
    }
    if rejectedRecordCount != snapshot.rejectedRecordCount {
      rejectedRecordCount = snapshot.rejectedRecordCount
    }
  }
}
