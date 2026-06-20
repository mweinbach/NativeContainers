import Foundation

protocol ContainerManaging: Sendable {
  func loadInventory() async throws -> ContainerInventory
  func inspectContainer(id: String) async throws -> ContainerInspection
  func startContainer(id: String) async throws
  func stopContainer(id: String) async throws
  func deleteContainer(id: String) async throws
  func startMachine(id: String) async throws
  func stopMachine(id: String) async throws
  func deleteMachine(id: String) async throws
}
