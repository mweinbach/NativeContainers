import ContainerPersistence
import ContainerXPC
import Foundation
import MachineAPIClient
import Testing

@testable import NativeContainers

@Suite("Apple machine XPC transport")
struct AppleMachineXPCTransportTests {
  @Test
  func encodesEveryMachineRouteAndDecodesSnapshots() async throws {
    let snapshot = try makeMachineSnapshot(initialized: true)
    let sender = RecordingMachineXPCSender(snapshot: snapshot)
    let transport = AppleMachineXPCTransport(requestSender: sender)

    let listed = try await transport.list()
    let inspected = try await transport.inspect(id: "dev")
    try await transport.create(
      configuration: snapshot.configuration,
      resources: nil,
      bootConfig: snapshot.bootConfig
    )
    let booted = try await transport.boot(
      id: "dev",
      dynamicEnvironment: ["SSH_AUTH_SOCK": "/tmp/agent"]
    )
    try await transport.setConfig(id: "dev", bootConfig: snapshot.bootConfig)
    try await transport.stop(id: "dev")
    try await transport.delete(id: "dev")

    #expect(listed.map(\.id) == ["dev"])
    #expect(inspected.initialized)
    #expect(booted.id == "dev")
    #expect(await sender.configurationIDs == ["dev"])
    #expect(await sender.bootConfigurations.first?.cpus == snapshot.bootConfig.cpus)
    #expect(
      await sender.routes == [
        MachineRoutes.listMachine.rawValue,
        MachineRoutes.inspectMachine.rawValue,
        MachineRoutes.createMachine.rawValue,
        MachineRoutes.bootMachine.rawValue,
        MachineRoutes.setConfig.rawValue,
        MachineRoutes.stopMachine.rawValue,
        MachineRoutes.deleteMachine.rawValue,
      ]
    )
  }
}

private actor RecordingMachineXPCSender: AppleXPCRequestSending {
  private let snapshot: MachineSnapshot
  private(set) var routes: [String] = []
  private(set) var configurationIDs: [String] = []
  private(set) var bootConfigurations: [MachineConfig] = []

  init(snapshot: MachineSnapshot) {
    self.snapshot = snapshot
  }

  func send(_ message: XPCMessage, operation: String) throws -> XPCMessage {
    let route = message.string(key: XPCMessage.routeKey) ?? ""
    routes.append(route)

    let response = XPCMessage(route: "testReply")
    switch route {
    case MachineRoutes.listMachine.rawValue:
      response.set(
        key: MachineKeys.machines.rawValue,
        value: try JSONEncoder().encode([snapshot])
      )
    case MachineRoutes.inspectMachine.rawValue, MachineRoutes.bootMachine.rawValue:
      response.set(
        key: MachineKeys.snapshot.rawValue,
        value: try JSONEncoder().encode(snapshot)
      )
    case MachineRoutes.setConfig.rawValue:
      if let id = message.string(key: MachineKeys.id.rawValue) {
        configurationIDs.append(id)
      }
      if let data = message.dataNoCopy(key: MachineKeys.bootConfig.rawValue) {
        bootConfigurations.append(try JSONDecoder().decode(MachineConfig.self, from: data))
      }
    default:
      break
    }
    return response
  }
}
