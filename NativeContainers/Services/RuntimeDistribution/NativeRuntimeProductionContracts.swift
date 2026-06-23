import Darwin
import Foundation

struct NativeRuntimeSignedBinaryDigestCatalog: Equatable, Sendable {
  let container: String
  let containerAPIServer: String
  let containerRuntimeLinux: String
  let containerNetworkVMNet: String
  let containerCoreImages: String
  let machineAPIServer: String

  init(
    container: String,
    containerAPIServer: String,
    containerRuntimeLinux: String,
    containerNetworkVMNet: String,
    containerCoreImages: String,
    machineAPIServer: String
  ) throws {
    let values = [
      container,
      containerAPIServer,
      containerRuntimeLinux,
      containerNetworkVMNet,
      containerCoreImages,
      machineAPIServer,
    ]
    guard values.allSatisfy(Self.isSHA256) else {
      throw NativeRuntimeDistributionError.invalidManifest(
        "A signed runtime binary digest is not a lowercase SHA-256 value."
      )
    }
    self.container = container
    self.containerAPIServer = containerAPIServer
    self.containerRuntimeLinux = containerRuntimeLinux
    self.containerNetworkVMNet = containerNetworkVMNet
    self.containerCoreImages = containerCoreImages
    self.machineAPIServer = machineAPIServer
  }

  private static func isSHA256(_ value: String) -> Bool {
    let allowed = Set("0123456789abcdef")
    return value.count == 64 && value.allSatisfy(allowed.contains)
  }
}

enum NativeRuntimeProductionContractFactory {
  static let officialRuntimeVersion = "1.0.0"
  static let nativeRuntimeVersion = "1.0.0-nc.2"
  static let officialTeamIdentifier = "UPBK2H6LZM"
  static let nativePackageIdentifier = "com.nativecontainers.runtime"
  static let nativeInstallRootURL = URL(
    filePath: "/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2",
    directoryHint: .isDirectory
  )

  static func launchServicesByOrigin(
    userID: uid_t = getuid()
  ) -> [NativeRuntimeOrigin: [NativeRuntimeLaunchServiceContract]] {
    let domain = launchDomain(userID: userID)
    let definitions: [(String, String)] = [
      ("bin/container-apiserver", "com.apple.container.apiserver"),
      (
        "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux",
        "com.apple.container.container-runtime-linux.buildkit"
      ),
      (
        "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet",
        "com.apple.container.container-network-vmnet.default"
      ),
      (
        "libexec/container/plugins/container-core-images/bin/container-core-images",
        "com.apple.container.container-core-images"
      ),
      (
        "libexec/container/plugins/machine-apiserver/bin/machine-apiserver",
        "com.apple.container.machine-apiserver"
      ),
    ]
    func services(root: URL) -> [NativeRuntimeLaunchServiceContract] {
      definitions.map { path, label in
        NativeRuntimeLaunchServiceContract(
          label: label,
          domain: domain,
          executableURL: root.appending(
            path: path,
            directoryHint: .notDirectory
          )
        )
      }
    }
    return [
      .appleOfficial: services(
        root: URL(filePath: "/usr/local", directoryHint: .isDirectory)
      ),
      .nativeContainers: services(root: nativeInstallRootURL),
    ]
  }

  static func launchGraphContractsByOrigin(
    userID: uid_t = getuid()
  ) -> [NativeRuntimeOrigin: NativeRuntimeLaunchGraphContract] {
    launchServicesByOrigin(userID: userID).mapValues { services in
      let anchors = services.filter {
        $0.label == "com.apple.container.apiserver"
      }
      return NativeRuntimeLaunchGraphContract(
        services: services,
        requiredServices: anchors.isEmpty ? services : anchors
      )
    }
  }

  static func officialManifest(
    userID: uid_t = getuid()
  ) -> NativeRuntimeDistributionManifest {
    let root = URL(filePath: "/usr/local", directoryHint: .isDirectory)
    let domain = launchDomain(userID: userID)
    return NativeRuntimeDistributionManifest(
      origin: .appleOfficial,
      packageIdentifier: "com.apple.container-installer",
      packageVersion: officialRuntimeVersion,
      installRootURL: root,
      teamIdentifier: officialTeamIdentifier,
      builderArtifact: nil,
      artifacts: [
        artifact(
          path: "bin/container",
          digest: "ddbdf8f48d2718761b57afd450c4b02bf9174767043526d5274f0bd6b4863e33",
          role: .executable(signingIdentifier: "com.apple.container.cli")
        ),
        artifact(
          path: "bin/container-apiserver",
          digest: "12747bbc84384a71f715068a45c6214a6d86ac26a25946c70040fa0a7e893558",
          role: .launchService(
            label: "com.apple.container.apiserver",
            domain: domain,
            signingIdentifier: "com.apple.container.apiserver"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux",
          digest: "debfe3cfd4edbe0a0a6b75264a6c50c95ab13b913f941aa7b247d94526853885",
          role: .launchService(
            label: "com.apple.container.container-runtime-linux.buildkit",
            domain: domain,
            signingIdentifier: "com.apple.container.container-runtime-linux"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet",
          digest: "6b6c69ff515e54b3773fbc3839f9396763267528878b0181485822b1e0f40140",
          role: .launchService(
            label: "com.apple.container.container-network-vmnet.default",
            domain: domain,
            signingIdentifier: "com.apple.container.container-network-vmnet"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-core-images/bin/container-core-images",
          digest: "9147d8172f129aaf2528d5e0caf8151ef928ba28d7794b16df63534eda9d8acd",
          role: .launchService(
            label: "com.apple.container.container-core-images",
            domain: domain,
            signingIdentifier: "com.apple.container.container-core-images"
          )
        ),
        artifact(
          path: "libexec/container/plugins/machine-apiserver/bin/machine-apiserver",
          digest: "7571277d7f5c3909758094d6e2d2514ee5b1199abff0625f589b69e45b84b44d",
          role: .launchService(
            label: "com.apple.container.machine-apiserver",
            domain: domain,
            signingIdentifier: "com.apple.container.machine-apiserver"
          )
        ),
      ]
    )
  }

  static func nativeManifest(
    signedBinaryDigests: NativeRuntimeSignedBinaryDigestCatalog,
    userID: uid_t = getuid()
  ) -> NativeRuntimeDistributionManifest {
    let domain = launchDomain(userID: userID)
    return NativeRuntimeDistributionManifest(
      origin: .nativeContainers,
      packageIdentifier: nativePackageIdentifier,
      packageVersion: nativeRuntimeVersion,
      installRootURL: nativeInstallRootURL,
      teamIdentifier: NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
      builderArtifact: .pinned,
      artifacts: [
        artifact(
          path: "bin/container",
          digest: signedBinaryDigests.container,
          role: .executable(signingIdentifier: "com.apple.container.cli")
        ),
        artifact(
          path: "bin/container-apiserver",
          digest: signedBinaryDigests.containerAPIServer,
          role: .launchService(
            label: "com.apple.container.apiserver",
            domain: domain,
            signingIdentifier: "com.apple.container.apiserver"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux",
          digest: signedBinaryDigests.containerRuntimeLinux,
          role: .launchService(
            label: "com.apple.container.container-runtime-linux.buildkit",
            domain: domain,
            signingIdentifier: "com.apple.container.container-runtime-linux"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet",
          digest: signedBinaryDigests.containerNetworkVMNet,
          role: .launchService(
            label: "com.apple.container.container-network-vmnet.default",
            domain: domain,
            signingIdentifier: "com.apple.container.container-network-vmnet"
          )
        ),
        artifact(
          path:
            "libexec/container/plugins/container-core-images/bin/container-core-images",
          digest: signedBinaryDigests.containerCoreImages,
          role: .launchService(
            label: "com.apple.container.container-core-images",
            domain: domain,
            signingIdentifier: "com.apple.container.container-core-images"
          )
        ),
        artifact(
          path: "libexec/container/plugins/machine-apiserver/bin/machine-apiserver",
          digest: signedBinaryDigests.machineAPIServer,
          role: .launchService(
            label: "com.apple.container.machine-apiserver",
            domain: domain,
            signingIdentifier: "com.apple.container.machine-apiserver"
          )
        ),
        dataArtifact(
          path: "etc/container/config.toml",
          digest: "15d02e3707d200579e23f03cf883bc8980a9dc4bfc3ea4f6e09224b17737892a"
        ),
        dataArtifact(
          path: "libexec/container/plugins/container-runtime-linux/config.toml",
          digest: "d609af652f3e0224cb7f0cef315f873081506d010d2d1a8ff33508980e3427a7"
        ),
        dataArtifact(
          path: "libexec/container/plugins/container-network-vmnet/config.toml",
          digest: "7ec0d522dcf9c9bc78b1e0843916bd0a98cfec45ef5b35f04fb8407ecda3db3e"
        ),
        dataArtifact(
          path: "libexec/container/plugins/container-core-images/config.toml",
          digest: "89ebf5415177298d36f4c67c8c03db26fac1377b428f30a5ccf96407d8f63f9d"
        ),
        dataArtifact(
          path: "libexec/container/plugins/machine-apiserver/config.toml",
          digest: "819edb0d3c20517e8a56e11a9623b3804c6821d3920da3fa66d989f766103b6a"
        ),
        dataArtifact(
          path: "libexec/container/plugins/machine-apiserver/resources/init",
          digest: "77a7f83faca9f8656ef129d8f91ddc4e770c80478d07b805a2530b9a902bf15a"
        ),
        dataArtifact(
          path: "libexec/container/plugins/machine-apiserver/resources/create-user.sh",
          digest: "4f86a20d53412736a4cad54c3d511371beb70dd1156cd7991e7448885521b8cd"
        ),
        NativeRuntimePackageArtifact(
          relativePath: "share/nativecontainers-runtime/runtime-manifest.json",
          sha256: "b63f13be79466249c65db03befe38415057aa18b201bebc2d5e36609954344c4",
          maximumByteCount: 64 * 1_024,
          role: .builderArtifactMetadata
        ),
        NativeRuntimePackageArtifact(
          relativePath:
            "share/nativecontainers-runtime/container-builder-shim-0.12.0-nc.2.oci.tar",
          sha256: "d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680",
          maximumByteCount: 1_024 * 1_024 * 1_024,
          role: .data
        ),
      ]
    )
  }

  static func controlCommands() -> [NativeRuntimeOrigin: NativeRuntimeControlCommand] {
    [
      .appleOfficial: NativeRuntimeControlCommand(
        executableURL: URL(
          filePath: "/usr/local/bin/container",
          directoryHint: .notDirectory
        ),
        startArguments: ["system", "start"],
        stopArguments: ["system", "stop"]
      ),
      .nativeContainers: NativeRuntimeControlCommand(
        executableURL: nativeInstallRootURL.appending(
          path: "bin/container",
          directoryHint: .notDirectory
        ),
        startArguments: ["system", "start"],
        stopArguments: ["system", "stop"]
      ),
    ]
  }

  static func migrationLayout(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> NativeRuntimeMigrationLayout {
    let home = homeDirectoryURL.standardizedFileURL
    return NativeRuntimeMigrationLayout(
      sourceRootURL: home.appending(
        path: "Library/Application Support/com.apple.container",
        directoryHint: .isDirectory
      ),
      destinationRootURL: home.appending(
        path: "Library/Application Support/NativeContainers/Container Runtime",
        directoryHint: .isDirectory
      ),
      selections: [
        NativeRuntimeMigrationSelection(
          category: .imagesAndContent,
          sourceRelativePath: "content",
          destinationRelativePath: "content"
        ),
        NativeRuntimeMigrationSelection(
          category: .imagesAndContent,
          sourceRelativePath: "snapshots",
          destinationRelativePath: "snapshots"
        ),
        NativeRuntimeMigrationSelection(
          category: .volumes,
          sourceRelativePath: "volumes",
          destinationRelativePath: "volumes"
        ),
        NativeRuntimeMigrationSelection(
          category: .networks,
          sourceRelativePath: "networks",
          destinationRelativePath: "networks"
        ),
        NativeRuntimeMigrationSelection(
          category: .kernels,
          sourceRelativePath: "kernels",
          destinationRelativePath: "kernels"
        ),
        NativeRuntimeMigrationSelection(
          category: .configuration,
          sourceRelativePath: "state.json",
          destinationRelativePath: "state.json"
        ),
        NativeRuntimeMigrationSelection(
          category: .configuration,
          sourceRelativePath: "config/config.toml",
          destinationRelativePath: "config/config.toml",
          isRequired: false
        ),
        NativeRuntimeMigrationSelection(
          category: .machines,
          sourceRelativePath: "plugin-state/machine-apiserver/state.json",
          destinationRelativePath: "plugin-state/machine-apiserver/state.json"
        ),
        NativeRuntimeMigrationSelection(
          category: .machines,
          sourceRelativePath: "plugin-state/machine-apiserver/machines",
          destinationRelativePath: "plugin-state/machine-apiserver/machines"
        ),
      ]
    )
  }

  private static func launchDomain(userID: uid_t) -> String {
    "gui/\(userID)"
  }

  private static func artifact(
    path: String,
    digest: String,
    role: NativeRuntimeArtifactRole
  ) -> NativeRuntimePackageArtifact {
    NativeRuntimePackageArtifact(
      relativePath: path,
      sha256: digest,
      maximumByteCount: 512 * 1_024 * 1_024,
      role: role
    )
  }

  private static func dataArtifact(
    path: String,
    digest: String
  ) -> NativeRuntimePackageArtifact {
    NativeRuntimePackageArtifact(
      relativePath: path,
      sha256: digest,
      maximumByteCount: 64 * 1_024 * 1_024,
      role: .data
    )
  }
}
