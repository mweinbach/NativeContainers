import ContainerPersistence
import Foundation
import MachineAPIClient

enum AppleLinuxMachineSnapshotMapper {
  static func identity(from machine: MachineSnapshot) -> LinuxMachineIdentity {
    LinuxMachineIdentity(
      id: machine.id,
      imageReference: machine.configuration.image.reference,
      platform: String(describing: machine.platform),
      createdAt: machine.createdDate
    )
  }

  static func state(from machine: MachineSnapshot) -> RuntimeState {
    RuntimeState(rawValue: machine.status.rawValue) ?? .unknown
  }

  static func configuration(
    from machine: MachineSnapshot
  ) throws -> LinuxMachineConfiguration {
    let homeMountValue = machine.bootConfig.homeMount.rawValue
    guard let homeMount = LinuxMachineHomeMount(rawValue: homeMountValue) else {
      throw LinuxMachineConfigurationError.unsupportedHomeMount(homeMountValue)
    }

    return try LinuxMachineConfiguration(
      cpuCount: machine.bootConfig.cpus,
      memoryBytes: machine.bootConfig.memory.toUInt64(unit: .bytes),
      homeMount: homeMount
    )
  }

  static func record(from machine: MachineSnapshot) throws -> LinuxMachineRecord {
    let configuration = try configuration(from: machine)
    return LinuxMachineRecord(
      id: machine.id,
      imageReference: machine.configuration.image.reference,
      platform: String(describing: machine.platform),
      state: state(from: machine),
      ipAddress: machine.ipAddress,
      createdAt: machine.createdDate,
      startedAt: machine.startedDate,
      diskSizeBytes: machine.diskSize,
      cpuCount: configuration.cpuCount,
      memoryBytes: configuration.memoryBytes,
      homeMount: configuration.homeMount,
      isInitialized: machine.initialized
    )
  }

  static func applying(
    _ configuration: LinuxMachineConfiguration,
    to current: MachineConfig
  ) throws -> MachineConfig {
    try current.with([
      "cpus": String(configuration.cpuCount),
      "memory":
        "\(configuration.memoryBytes / LinuxMachineConfiguration.bytesPerMiB)MiB",
      "home-mount": configuration.homeMount.rawValue,
    ])
  }
}
