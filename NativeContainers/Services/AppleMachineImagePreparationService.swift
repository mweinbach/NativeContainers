import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Darwin
import Foundation
import MachineAPIClient
import TerminalProgress

struct PreparedLinuxMachineCreation: Sendable {
  let configuration: MachineConfiguration
  let resources: MachineResources?
  let bootConfig: MachineConfig
}

protocol LinuxMachineImagePreparing: Sendable {
  func prepare(
    request: LinuxMachineCreationRequest,
    progressUpdate: @escaping ProgressUpdateHandler
  ) async throws -> PreparedLinuxMachineCreation
}

struct AppleMachineImagePreparationService: LinuxMachineImagePreparing {
  func prepare(
    request: LinuxMachineCreationRequest,
    progressUpdate: @escaping ProgressUpdateHandler
  ) async throws -> PreparedLinuxMachineCreation {
    let systemConfiguration = try await AppleContainerConfiguration.load()
    let platform = Platform(
      arch: request.architecture.rawValue,
      os: "linux",
      variant: nil
    )

    await progressUpdate([
      .setDescription("Fetching image"),
      .setItemsName("blobs"),
    ])
    let image = try await ClientImage.fetch(
      reference: request.imageReference,
      platform: platform,
      containerSystemConfig: systemConfiguration,
      progressUpdate: progressUpdate,
      maxConcurrentDownloads: 3
    )

    try Task.checkCancellation()
    await progressUpdate([
      .setDescription("Unpacking image"),
      .setItemsName("entries"),
    ])
    _ = try await image.getCreateSnapshot(
      platform: platform,
      progressUpdate: progressUpdate
    )

    let userSetup = UserSetup(
      username: NSUserName(),
      uid: getuid(),
      gid: getgid()
    )
    let configuration = try MachineConfiguration(
      id: request.name,
      image: image.description,
      platform: platform,
      userSetup: userSetup
    )
    let bootConfig = try systemConfiguration.machine.with([
      "cpus": String(request.cpuCount),
      "memory": "\(request.memoryBytes / LinuxMachineCreationRequest.bytesPerMiB)MiB",
      "home-mount": request.homeMount.rawValue,
    ])

    // Apple 1.0's public helper performs an additional direct-registry
    // referrers lookup for optional custom machine resources. The app's current
    // M3 surface intentionally supports standard OCI-rootfs machines; custom
    // disk/kernel artifacts remain a later, separately reviewed capability.
    return PreparedLinuxMachineCreation(
      configuration: configuration,
      resources: nil,
      bootConfig: bootConfig
    )
  }
}
