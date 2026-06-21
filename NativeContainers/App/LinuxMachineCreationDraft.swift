import Foundation

struct LinuxMachineCreationDraft {
  var name = ""
  var imageReference = ""
  var architecture = ContainerArchitecture.arm64
  var cpuCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
  var memoryMiB = 2_048
  var homeMount = LinuxMachineHomeMount.none
  var allowsWritableHomeMount = false
  var startAfterCreation = true

  func makeRequest() throws -> LinuxMachineCreationRequest {
    try LinuxMachineCreationRequest(
      name: name,
      imageReference: imageReference,
      architecture: architecture,
      cpuCount: cpuCount,
      memoryBytes: UInt64(memoryMiB) * LinuxMachineCreationRequest.bytesPerMiB,
      homeMount: homeMount,
      allowsWritableHomeMount: allowsWritableHomeMount,
      startAfterCreation: startAfterCreation
    )
  }
}
