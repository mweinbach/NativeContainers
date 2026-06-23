import ContainerResource
import Foundation

enum ContainerBuilderSnapshotAdapter {
  static func safetySnapshot(
    _ snapshot: ContainerSnapshot?
  ) -> ContainerBuilderSafetySnapshot {
    guard let snapshot else { return .absent }
    let configuration = snapshot.configuration
    let process = configuration.initProcess
    let user: (UInt32, UInt32) = {
      guard case .id(let userID, let groupID) = process.user else {
        return (.max, .max)
      }
      return (userID, groupID)
    }()

    return ContainerBuilderSafetySnapshot(
      state: runtimeState(snapshot.status),
      identity: ContainerBuilderIdentitySnapshot(
        roleLabel: configuration.labels[ResourceLabelKeys.role],
        pluginLabel: configuration.labels[ResourceLabelKeys.plugin],
        executable: process.executable,
        arguments: process.arguments,
        userID: user.0,
        groupID: user.1,
        terminal: process.terminal,
        workingDirectory: process.workingDirectory,
        addedCapabilities: configuration.capAdd,
        mounts: configuration.mounts.map(mountIdentity),
        networks: configuration.networks.map {
          ContainerBuilderNetworkIdentity(
            networkID: $0.network,
            hostname: $0.options.hostname
          )
        }
      ),
      configuration: ContainerBuilderDesiredConfiguration(
        image: configuration.image.reference,
        imageDescriptorDigest: configuration.image.descriptor.digest,
        cpuCount: configuration.resources.cpus,
        memoryBytes: configuration.resources.memoryInBytes,
        rosettaEnabled: configuration.rosetta,
        managedColorEnvironment: process.environment.filter {
          $0.hasPrefix("BUILDKIT_COLORS=") || $0.hasPrefix("NO_COLOR=")
        }.sorted(),
        dns: configuration.dns.map {
          ContainerBuilderDNSConfiguration(
            nameservers: $0.nameservers,
            domain: $0.domain,
            searchDomains: $0.searchDomains,
            options: $0.options
          )
        },
        sshAgentForwarding: configuration.ssh
      )
    )
  }

  static func reviewedSnapshot(
    _ snapshot: ContainerSnapshot
  ) -> ContainerBuilderReviewedSnapshot {
    ContainerBuilderReviewedSnapshot(
      creationDate: snapshot.configuration.creationDate,
      safety: safetySnapshot(snapshot)
    )
  }

  static func identityRequirements(
    exportsRootPath: String,
    builtinNetworkID: String
  ) -> ContainerBuilderIdentityRequirements {
    ContainerBuilderIdentityRequirements(
      roleLabel: ResourceRoleValues.builder,
      pluginLabel: "builder",
      executable: "/usr/local/bin/container-builder-shim",
      pinnedArguments: ContainerBuilderPinnedArguments(
        rosettaEnabled: ["--debug", "--vsock"],
        rosettaDisabled: ["--debug", "--vsock", "--enable-qemu"]
      ),
      userID: 0,
      groupID: 0,
      terminal: false,
      workingDirectory: "/",
      addedCapabilities: ["ALL"],
      mounts: [
        ContainerBuilderMountIdentity(
          type: "tmpfs",
          source: "",
          destination: "/run",
          options: []
        ),
        ContainerBuilderMountIdentity(
          type: "virtiofs",
          source: exportsRootPath,
          destination: "/var/lib/container-builder-shim/exports",
          options: []
        ),
      ],
      networks: [
        ContainerBuilderNetworkIdentity(
          networkID: builtinNetworkID,
          hostname: ContainerBuilderRecord.containerID
        )
      ]
    )
  }

  static func runtimeState(_ status: RuntimeStatus) -> ContainerBuilderRuntimeState {
    switch status {
    case .running: .running
    case .stopped: .stopped
    case .stopping: .stopping
    case .unknown: .unknown
    }
  }

  private static func mountIdentity(_ mount: Filesystem) -> ContainerBuilderMountIdentity {
    let type: String =
      switch mount.type {
      case .tmpfs: "tmpfs"
      case .virtiofs: "virtiofs"
      case .block: "block"
      case .volume: "volume"
      }
    return ContainerBuilderMountIdentity(
      type: type,
      source: mount.source,
      destination: mount.destination,
      options: mount.options
    )
  }
}
