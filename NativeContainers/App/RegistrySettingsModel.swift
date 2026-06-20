import Foundation
import Observation

@MainActor
@Observable
final class RegistrySettingsModel {
  private(set) var registries: [RegistryCredentialRecord] = []
  private(set) var loginPlan: RegistryLoginPlan?
  private(set) var isLoading = false
  private(set) var isWorking = false
  private(set) var errorMessage: String?

  private let service: any RegistryManaging

  init(service: any RegistryManaging) {
    self.service = service
  }

  func load() async {
    guard !isLoading, !isWorking else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      registries = try await service.listRegistries()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func prepareLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async -> RegistryLoginPlan? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let plan = try await service.prepareRegistryLogin(
        server: server,
        username: username,
        transport: transport
      )
      loginPlan = plan
      return plan
    } catch is CancellationError {
      return nil
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func login(
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async -> Bool {
    guard !isWorking, let loginPlan else {
      if loginPlan == nil {
        errorMessage = RegistryManagementError.missingServer.localizedDescription
      }
      return false
    }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await service.loginRegistry(
        loginPlan,
        password: password,
        allowingInsecureTransport: allowingInsecureTransport,
        replacingDifferentUsername: replacingDifferentUsername
      )
      self.loginPlan = nil
      await refreshAfterMutation(
        warningPrefix: "The registry login was saved, but the list could not refresh"
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func logout(_ registry: RegistryCredentialRecord) async -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await service.logoutRegistry(registry)
      await refreshAfterMutation(
        warningPrefix: "The registry login was removed, but the list could not refresh"
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func resetLogin() {
    loginPlan = nil
    errorMessage = nil
  }

  func clearError() {
    errorMessage = nil
  }

  private func refreshAfterMutation(warningPrefix: String) async {
    do {
      registries = try await service.listRegistries()
    } catch is CancellationError {
      errorMessage = "\(warningPrefix) because refreshing was cancelled."
    } catch {
      errorMessage = "\(warningPrefix): \(error.localizedDescription)"
    }
  }
}
