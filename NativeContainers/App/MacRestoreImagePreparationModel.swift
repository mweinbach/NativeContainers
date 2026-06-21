import Foundation
import Observation

enum MacRestoreImagePreparationStage: Equatable, Sendable {
  case idle
  case discovering
  case downloading
  case importing
  case preparing
  case finished
}

@MainActor
@Observable
final class MacRestoreImagePreparationModel {
  let machine: VirtualMachineManifest

  private(set) var stage: MacRestoreImagePreparationStage = .idle
  private(set) var latestImage: MacRestoreImageInfo?
  private(set) var downloadProgress: RestoreImageDownloadProgress?
  private(set) var errorMessage: String?

  private let discovery: any MacRestoreImageDiscovering
  private let acquisition: any RestoreImageAcquiring
  private let notifications: any AppNotificationManaging
  private let prepareMachine: @MainActor @Sendable (URL) async throws -> Void

  init(
    machine: VirtualMachineManifest,
    discovery: any MacRestoreImageDiscovering,
    acquisition: any RestoreImageAcquiring,
    notifications: any AppNotificationManaging = UnavailableAppNotificationService(),
    prepare: @escaping @MainActor @Sendable (URL) async throws -> Void
  ) {
    self.machine = machine
    self.discovery = discovery
    self.acquisition = acquisition
    self.notifications = notifications
    self.prepareMachine = prepare
  }

  var isWorking: Bool {
    switch stage {
    case .discovering, .downloading, .importing, .preparing:
      true
    case .idle, .finished:
      false
    }
  }

  var latestImageCompatibilityMessage: String? {
    guard let latestImage else { return nil }
    guard latestImage.isSupported else {
      return "This Mac does not support the latest restore image."
    }
    guard machine.resources.cpuCount >= latestImage.minimumCPUCount else {
      return
        "This image needs at least \(latestImage.minimumCPUCount) CPUs; \(machine.name) has \(machine.resources.cpuCount)."
    }
    guard machine.resources.memoryBytes >= latestImage.minimumMemoryBytes else {
      let required = ByteCountFormatter.string(
        fromByteCount: Int64(clamping: latestImage.minimumMemoryBytes),
        countStyle: .memory
      )
      return "This image needs at least \(required) of memory."
    }
    return nil
  }

  func discoverLatest() async {
    guard !isWorking, latestImage == nil else { return }
    stage = .discovering
    errorMessage = nil
    defer {
      if stage == .discovering { stage = .idle }
    }

    do {
      latestImage = try await discovery.latestSupported()
    } catch is CancellationError {
      errorMessage = "Restore-image discovery was cancelled."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func downloadLatestAndPrepare() async -> Bool {
    guard !isWorking else { return false }
    guard let latestImage else {
      errorMessage = "Discover the latest supported restore image first."
      return false
    }
    if let latestImageCompatibilityMessage {
      errorMessage = latestImageCompatibilityMessage
      return false
    }

    stage = .downloading
    downloadProgress = nil
    errorMessage = nil

    do {
      let lease = try await acquisition.acquire(.remote(latestImage.url)) {
        [weak self] update in
        await self?.receive(update)
      }
      return try await prepareAcquiredImage(lease)
    } catch is CancellationError {
      stage = .idle
      errorMessage = "The download is paused. Start it again to resume from the partial file."
      return false
    } catch {
      stage = .idle
      errorMessage = error.localizedDescription
      await notifications.deliver(
        .restoreImagePreparationFailed(machineID: machine.id, machineName: machine.name)
      )
      return false
    }
  }

  func prepareLocalImage(at url: URL) async -> Bool {
    guard !isWorking else { return false }
    stage = .importing
    downloadProgress = nil
    errorMessage = nil

    let hasSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      try Task.checkCancellation()
      let lease = try await acquisition.acquire(.local(url)) { [weak self] update in
        await self?.receive(update)
      }
      return try await prepareAcquiredImage(lease)
    } catch is CancellationError {
      stage = .idle
      errorMessage = "Restore-image import or preparation was cancelled. No partial copy was kept."
      return false
    } catch {
      stage = .idle
      errorMessage = error.localizedDescription
      await notifications.deliver(
        .restoreImagePreparationFailed(machineID: machine.id, machineName: machine.name)
      )
      return false
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func reportError(_ message: String) {
    errorMessage = message
  }

  private func prepareAcquiredImage(
    _ lease: RestoreImageCacheLease
  ) async throws -> Bool {
    do {
      try Task.checkCancellation()
      stage = .preparing
      try await prepareMachine(lease.fileURL)
      await acquisition.commit(lease)
      stage = .finished
      await notifications.deliver(
        .restoreImagePrepared(machineID: machine.id, machineName: machine.name)
      )
      return true
    } catch {
      let operationError = error
      do {
        try await acquisition.abandon(lease)
      } catch {
        throw RestoreImageAcquisitionError.cleanupFailed(
          operation: operationError.localizedDescription,
          cleanup: error.localizedDescription
        )
      }
      throw operationError
    }
  }

  private func receive(_ progress: RestoreImageDownloadProgress) {
    downloadProgress = progress
  }
}
