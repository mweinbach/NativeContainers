import Foundation
import Testing

@testable import NativeContainers

@MainActor
@Suite("Container tools model")
struct ContainerToolsModelTests {
  @Test
  func detectsAndCachesPreferredShell() async {
    let service = ContainerToolingStub(
      shell: ContainerShell(executable: "/usr/bin/zsh", source: .environment)
    )
    let model = ContainerToolsModel(
      containerID: "dev",
      tooling: service,
      shellDiscovery: service
    )

    let first = await model.detectShell()
    let second = await model.detectShell()

    #expect(first == ContainerShell(executable: "/usr/bin/zsh", source: .environment))
    #expect(second == first)
    #expect(model.detectedShell == first)
    #expect(model.shellDetectionMessage == nil)
    #expect(await service.discoveryIDs == ["dev"])
  }
}

private actor ContainerToolingStub: ContainerTooling, ContainerShellDiscovering {
  private let shell: ContainerShell
  private(set) var discoveryIDs: [String] = []

  init(shell: ContainerShell) {
    self.shell = shell
  }

  func discoverShell(in id: String) -> ContainerShell {
    discoveryIDs.append(id)
    return shell
  }

  func executeCommand(
    in id: String,
    request: ContainerCommandRequest
  ) -> ContainerCommandResult {
    ContainerCommandResult(
      exitCode: 0,
      standardOutput: "",
      standardError: "",
      outputWasTruncated: false,
      duration: .zero
    )
  }

  func copyIntoContainer(id: String, source: URL, destination: String) {}

  func copyFromContainer(id: String, source: String, destination: URL) {}
}
