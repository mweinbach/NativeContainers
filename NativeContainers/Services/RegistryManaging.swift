import Foundation

protocol RegistryManaging: Sendable {
  func listRegistries() async throws -> [RegistryCredentialRecord]
  func prepareRegistryLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async throws -> RegistryLoginPlan
  func loginRegistry(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async throws
  func logoutRegistry(_ registry: RegistryCredentialRecord) async throws
}

extension RegistryManaging {
  func listRegistries() async throws -> [RegistryCredentialRecord] {
    throw RegistryManagementError.unsupported
  }

  func prepareRegistryLogin(
    server: String,
    username: String,
    transport: RegistryTransport
  ) async throws -> RegistryLoginPlan {
    throw RegistryManagementError.unsupported
  }

  func loginRegistry(
    _ plan: RegistryLoginPlan,
    password: String,
    allowingInsecureTransport: Bool,
    replacingDifferentUsername: Bool
  ) async throws {
    throw RegistryManagementError.unsupported
  }

  func logoutRegistry(_ registry: RegistryCredentialRecord) async throws {
    throw RegistryManagementError.unsupported
  }
}
