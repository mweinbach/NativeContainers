import Foundation
import Observation

@MainActor
@Observable
final class KubernetesClusterModel {
  private(set) var snapshot = KubernetesClusterSnapshot.absent
  private(set) var resourceInventory: KubernetesResourceInventory?
  private(set) var progress: KubernetesClusterProgress?
  private(set) var isLoading = false
  private(set) var isLoadingResources = false
  private(set) var isWorking = false
  private(set) var isExporting = false
  private(set) var errorMessage: String?
  private(set) var resourceErrorMessage: String?

  @ObservationIgnored
  private let service: any KubernetesClusterManaging

  @ObservationIgnored
  private let didMutate: @MainActor @Sendable () async -> Void

  init(
    service: any KubernetesClusterManaging,
    initialSnapshot: KubernetesClusterSnapshot = .absent,
    didMutate: @escaping @MainActor @Sendable () async -> Void = {}
  ) {
    self.service = service
    snapshot = initialSnapshot
    self.didMutate = didMutate
  }

  var isBusy: Bool {
    isLoading || isLoadingResources || isWorking || isExporting
  }

  func refresh() async {
    guard !isBusy else { return }
    isLoading = true
    defer { isLoading = false }
    await reload()
  }

  func loadResources() async {
    guard
      !isBusy,
      snapshot.state == .ready || snapshot.state == .degraded
    else {
      return
    }
    isLoadingResources = true
    resourceErrorMessage = nil
    defer { isLoadingResources = false }

    do {
      resourceInventory = try await service.loadResourceInventory()
    } catch is CancellationError {
      return
    } catch {
      resourceErrorMessage = error.localizedDescription
    }
  }

  func provision(_ request: KubernetesClusterProvisionRequest) async -> Bool {
    guard !isBusy else { return false }
    clearResourceInventory()
    isWorking = true
    progress = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      snapshot = try await service.provision(request) { update in
        await self.receive(update)
      }
      await didMutate()
      return true
    } catch is CancellationError {
      errorMessage = String(localized: "Kubernetes setup was cancelled.")
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshAfterMutationFailure()
    return false
  }

  func retryProvisioning() async -> Bool {
    await performMutation { service in
      try await service.retryProvisioning { update in
        await self.receive(update)
      }
    }
  }

  func start() async -> Bool {
    await performMutation { service in
      try await service.start()
    }
  }

  func stop() async -> Bool {
    await performMutation { service in
      try await service.stop()
    }
  }

  func forceStop() async -> Bool {
    await performMutation { service in
      try await service.forceStop()
    }
  }

  func delete() async -> Bool {
    guard !isBusy else { return false }
    clearResourceInventory()
    isWorking = true
    progress = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      try await service.delete()
      snapshot = .absent
      await didMutate()
      return true
    } catch is CancellationError {
      errorMessage = String(localized: "Kubernetes deletion was cancelled.")
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshAfterMutationFailure()
    return false
  }

  func forget() async -> Bool {
    guard !isBusy else { return false }
    clearResourceInventory()
    isWorking = true
    progress = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      try await service.forget()
      snapshot = .absent
      return true
    } catch is CancellationError {
      errorMessage = String(localized: "Forgetting the Kubernetes record was cancelled.")
    } catch {
      errorMessage = error.localizedDescription
    }
    await reload(preserveError: true)
    return false
  }

  func prepareKubeconfigExport() async -> KubernetesKubeconfigExport? {
    guard !isBusy else { return nil }
    isExporting = true
    errorMessage = nil
    defer { isExporting = false }

    do {
      return try await service.exportKubeconfig()
    } catch is CancellationError {
      errorMessage = String(localized: "Kubeconfig export was cancelled.")
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func beginProvisioning() {
    progress = nil
    errorMessage = nil
  }

  func clearError() {
    errorMessage = nil
  }

  func clearResourceError() {
    resourceErrorMessage = nil
  }

  func makePodLogsModel(for pod: KubernetesPodRecord) -> KubernetesPodLogsModel {
    KubernetesPodLogsModel(service: service, pod: pod)
  }

  func scaleWorkload(
    _ workload: KubernetesWorkloadRecord,
    to targetReplicas: Int
  ) async -> Bool {
    guard !isBusy else { return false }
    isWorking = true
    resourceErrorMessage = nil
    defer { isWorking = false }

    let result: KubernetesWorkloadScaleResult
    do {
      result = try await service.scaleWorkload(
        try KubernetesWorkloadScaleRequest(
          workload: workload,
          targetReplicas: targetReplicas
        )
      )
    } catch is CancellationError {
      resourceErrorMessage = String(localized: "Scaling the workload was cancelled.")
      return false
    } catch {
      let mutationError = error.localizedDescription
      if let refreshed = try? await service.loadResourceInventory() {
        resourceInventory = refreshed
      }
      resourceErrorMessage = mutationError
      return false
    }

    do {
      resourceInventory = try await service.loadResourceInventory()
    } catch {
      resourceInventory = nil
      resourceErrorMessage = String(
        localized:
          "Scale to \(result.observedReplicas) replicas was confirmed, but resources could not be refreshed: \(error.localizedDescription)"
      )
    }
    return true
  }

  func restartWorkload(_ workload: KubernetesWorkloadRecord) async -> Bool {
    guard !isBusy else { return false }
    isWorking = true
    resourceErrorMessage = nil
    defer { isWorking = false }

    let result: KubernetesWorkloadRestartResult
    do {
      result = try await service.restartWorkload(
        try KubernetesWorkloadRestartRequest(workload: workload)
      )
    } catch is CancellationError {
      resourceErrorMessage = String(localized: "Restarting the workload was cancelled.")
      return false
    } catch {
      let mutationError = error.localizedDescription
      if let refreshed = try? await service.loadResourceInventory() {
        resourceInventory = refreshed
      }
      resourceErrorMessage = mutationError
      return false
    }

    do {
      resourceInventory = try await service.loadResourceInventory()
    } catch {
      resourceInventory = nil
      resourceErrorMessage = String(
        localized:
          "Restart of “\(result.request.name)” was confirmed, but resources could not be refreshed: \(error.localizedDescription)"
      )
    }
    return true
  }

  func deleteWorkload(_ workload: KubernetesWorkloadRecord) async -> Bool {
    guard !isBusy else { return false }
    isWorking = true
    resourceErrorMessage = nil
    defer { isWorking = false }

    let result: KubernetesWorkloadDeleteResult
    do {
      result = try await service.deleteWorkload(
        try KubernetesWorkloadDeleteRequest(workload: workload)
      )
    } catch is CancellationError {
      resourceErrorMessage = String(localized: "Deleting the workload was cancelled.")
      return false
    } catch {
      let mutationError = error.localizedDescription
      if let refreshed = try? await service.loadResourceInventory() {
        resourceInventory = refreshed
      }
      resourceErrorMessage = mutationError
      return false
    }

    do {
      resourceInventory = try await service.loadResourceInventory()
      switch result.outcome {
      case .deleted:
        break
      case .replacementPresent:
        resourceErrorMessage = String(
          localized:
            "The reviewed workload “\(result.request.name)” was deleted, but a same-name replacement now exists. NativeContainers did not modify it."
        )
      case .pendingFinalizers:
        resourceErrorMessage = String(
          localized:
            "Deletion of “\(result.request.name)” was accepted and is waiting for foreground finalizers."
        )
      }
    } catch {
      resourceInventory = nil
      resourceErrorMessage = String(
        localized:
          "Deletion of “\(result.request.name)” was accepted, but resources could not be refreshed: \(error.localizedDescription)"
      )
    }
    return true
  }

  private func performMutation(
    _ operation:
      @escaping @MainActor @Sendable (
        any KubernetesClusterManaging
      ) async throws -> KubernetesClusterSnapshot
  ) async -> Bool {
    guard !isBusy else { return false }
    clearResourceInventory()
    isWorking = true
    progress = nil
    errorMessage = nil
    defer { isWorking = false }

    do {
      snapshot = try await operation(service)
      await didMutate()
      return true
    } catch is CancellationError {
      errorMessage = String(localized: "The Kubernetes operation was cancelled.")
    } catch {
      errorMessage = error.localizedDescription
    }
    await refreshAfterMutationFailure()
    return false
  }

  private func refreshAfterMutationFailure() async {
    await didMutate()
    await reload(preserveError: true)
  }

  private func reload(preserveError: Bool = false) async {
    do {
      let previousMachine = snapshot.descriptor?.machine
      let loadedSnapshot = try await service.load()
      snapshot = loadedSnapshot
      if previousMachine != loadedSnapshot.descriptor?.machine
        || (loadedSnapshot.state != .ready && loadedSnapshot.state != .degraded)
      {
        clearResourceInventory()
      }
      if !preserveError {
        errorMessage = nil
      }
    } catch is CancellationError {
      return
    } catch {
      if !preserveError || errorMessage == nil {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func clearResourceInventory() {
    resourceInventory = nil
    resourceErrorMessage = nil
  }

  private func receive(_ update: KubernetesClusterProgress) {
    progress = update
  }
}
