import Foundation
import Observation

@MainActor
@Observable
final class FieldDiagnosticModel {
  private(set) var snapshot = FieldDiagnosticSnapshot.empty
  private(set) var isLoading = false
  private(set) var isClearing = false
  private(set) var isExporting = false
  private(set) var errorMessage: String?

  @ObservationIgnored
  private let service: any FieldDiagnosticManaging

  @ObservationIgnored
  private var updateTask: Task<Void, Never>?

  init(
    service: any FieldDiagnosticManaging,
    initialSnapshot: FieldDiagnosticSnapshot = .empty
  ) {
    self.service = service
    snapshot = initialSnapshot
  }

  deinit {
    updateTask?.cancel()
  }

  var isBusy: Bool {
    isLoading || isClearing || isExporting
  }

  func start() {
    guard updateTask == nil else { return }

    updateTask = Task { [weak self, service] in
      guard let self else { return }
      let updates = await service.updates()
      await self.refresh()

      for await _ in updates {
        guard !Task.isCancelled else { return }
        await self.refresh()
      }
    }
    service.start()
  }

  func refresh() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      snapshot = try await service.load()
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeAll() async {
    guard !isBusy else { return }
    isClearing = true
    defer { isClearing = false }

    do {
      try await service.removeAll()
      snapshot = try await service.load()
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func prepareExport(id: String) async -> FieldDiagnosticExport? {
    guard !isBusy else { return nil }
    isExporting = true
    defer { isExporting = false }

    do {
      let export = try await service.exportRecord(id: id)
      errorMessage = nil
      return export
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}
