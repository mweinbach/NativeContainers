import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeContainers

@Suite("Native runtime distribution foundation", .serialized)
struct NativeRuntimeDistributionFoundationTests {
  @Test
  func pinnedBuilderArtifactContractMatchesTheBuiltRelease() {
    #expect(NativeRuntimeBuilderArtifactContract.pinned.shimVersion == "0.12.0-nc.2")
    #expect(
      NativeRuntimeBuilderArtifactContract.pinned.sourceRevision
        == "f66f1680fe6b74d814fb5527247e7d81227fcecb"
    )
    #expect(
      NativeRuntimeBuilderArtifactContract.pinned.imageDigest
        == "sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff"
    )
  }

  @Test
  func pinnedRuntimeManifestDigestMatchesPublishedForkFixture() throws {
    let fixtureURL = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(
        path: "Fixtures/NativeRuntimeManifest-1.0.0-nc.2.json",
        directoryHint: .notDirectory
      )
    let fixtureData = try Data(contentsOf: fixtureURL)
    let digest = SHA256.hash(data: fixtureData)
      .map { String(format: "%02x", $0) }
      .joined()
    let expected =
      "b63f13be79466249c65db03befe38415057aa18b201bebc2d5e36609954344c4"
    #expect(digest == expected)

    let manifest = NativeRuntimeProductionContractFactory.nativeManifest(
      signedBinaryDigests: try NativeRuntimeSignedBinaryDigestCatalog(
        container: String(repeating: "a", count: 64),
        containerAPIServer: String(repeating: "b", count: 64),
        containerRuntimeLinux: String(repeating: "c", count: 64),
        containerNetworkVMNet: String(repeating: "d", count: 64),
        containerCoreImages: String(repeating: "e", count: 64),
        machineAPIServer: String(repeating: "f", count: 64)
      )
    )
    let packagedManifest = try #require(
      manifest.artifacts.first {
        $0.relativePath
          == "share/nativecontainers-runtime/runtime-manifest.json"
      }
    )
    #expect(packagedManifest.sha256 == expected)
  }

  @Test
  func distributionVerifierChecksReceiptArtifactsSignaturesAndBuilderMetadata() async throws {
    let manifest = testManifest(origin: .nativeContainers)
    let inspector = ArtifactInspectorDouble(
      observations: Dictionary(
        uniqueKeysWithValues: manifest.artifacts.map {
          (
            $0.relativePath,
            [
              observation(sha256: $0.sha256),
              observation(sha256: $0.sha256),
            ]
          )
        }
      ),
      smallFileContents: [
        "share/builder-artifact.json": try builderMetadataJSON()
      ]
    )
    let signatures = SignatureValidatorDouble()
    let verifier = NativeRuntimeDistributionVerifier(
      receiptReader: ReceiptReaderDouble(
        receipt: NativeRuntimePackageReceipt(
          packageIdentifier: manifest.packageIdentifier,
          version: manifest.packageVersion
        )
      ),
      artifactInspector: inspector,
      signatureValidator: signatures
    )

    let verified = try await verifier.verify(manifest)

    #expect(verified.origin == .nativeContainers)
    #expect(verified.builderArtifact == .pinned)
    #expect(verified.serviceExecutablePaths.count == 2)
    #expect(signatures.calls.count == 2)
    #expect(signatures.calls.allSatisfy { $0.teamIdentifier == "6UHAW5UAT4" })
    #expect(
      Set(signatures.calls.map(\.signingIdentifier))
        == ["com.nativecontainers.runtime.api", "com.nativecontainers.runtime.network"]
    )
  }

  @Test
  func distributionVerifierRejectsUnsafeArtifactBeforeSignatureValidation() async {
    let manifest = testManifest(origin: .nativeContainers)
    let signatures = SignatureValidatorDouble()
    let verifier = NativeRuntimeDistributionVerifier(
      receiptReader: ReceiptReaderDouble(
        receipt: NativeRuntimePackageReceipt(
          packageIdentifier: manifest.packageIdentifier,
          version: manifest.packageVersion
        )
      ),
      artifactInspector: ArtifactInspectorDouble(
        error: .unsafeArtifact("libexec/container-apiserver")
      ),
      signatureValidator: signatures
    )

    await #expect(throws: NativeRuntimeDistributionError.self) {
      _ = try await verifier.verify(manifest)
    }
    #expect(signatures.calls.isEmpty)
  }

  @Test
  func descriptorInspectorRejectsSymlinkArtifact() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "native-runtime-inspector-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let target = root.appending(path: "target")
    try Data("trusted".utf8).write(to: target)
    #expect(chmod(target.path, 0o700) == 0)
    let link = root.appending(path: "service")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let artifact = NativeRuntimePackageArtifact(
      relativePath: "service",
      sha256: String(repeating: "a", count: 64),
      maximumByteCount: 1_024,
      role: .executable(signingIdentifier: "com.nativecontainers.service")
    )
    let inspector = DescriptorRelativeNativeRuntimeArtifactInspector(
      requiredOwnerUID: getuid()
    )

    #expect(throws: NativeRuntimeDistributionError.self) {
      _ = try inspector.inspect(installRootURL: root, artifact: artifact)
    }
  }

  @Test
  func descriptorInspectorAllowsSecureCurrentUserOwnedIntermediateDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "native-runtime-owner-shape-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: bin,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
    let executable = bin.appending(path: "container")
    try Data("signed-runtime".utf8).write(to: executable)
    #expect(chmod(executable.path, 0o755) == 0)

    let artifact = NativeRuntimePackageArtifact(
      relativePath: "bin/container",
      sha256: String(repeating: "a", count: 64),
      maximumByteCount: 1_024,
      role: .executable(signingIdentifier: "com.apple.container.cli")
    )
    let inspector = DescriptorRelativeNativeRuntimeArtifactInspector(
      requiredOwnerUID: getuid(),
      allowedDirectoryOwnerUIDs: [0, getuid()]
    )

    let observation = try inspector.inspect(
      installRootURL: root,
      artifact: artifact
    )

    #expect(observation.byteCount == 14)
    if getuid() != 0 {
      let rootOnlyDirectories = DescriptorRelativeNativeRuntimeArtifactInspector(
        requiredOwnerUID: getuid(),
        allowedDirectoryOwnerUIDs: [0]
      )
      #expect(throws: NativeRuntimeDistributionError.self) {
        _ = try rootOnlyDirectories.inspect(
          installRootURL: root,
          artifact: artifact
        )
      }
    }
  }

  @Test
  func launchGraphClassifierAcceptsRequiredAnchorWithoutDynamicServices() throws {
    let contracts =
      NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin(
        userID: 501
      )
    let classifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contracts
    )
    let official = try #require(contracts[.appleOfficial])
    let anchor = try #require(
      official.services.first {
        official.requiredServiceKeys.contains(
          NativeRuntimeLaunchGraphContract.key($0)
        )
      }
    )

    #expect(
      try classifier.classify([launchObservation(anchor)])
        == .active(.appleOfficial)
    )
  }

  @Test
  func launchGraphClassifierRejectsOptionalServiceWithoutRequiredAnchor() throws {
    let contracts =
      NativeRuntimeProductionContractFactory.launchGraphContractsByOrigin(
        userID: 501
      )
    let classifier = NativeRuntimeLaunchGraphClassifier(
      contractsByOrigin: contracts
    )
    let official = try #require(contracts[.appleOfficial])
    let optional = try #require(
      official.services.first {
        !official.requiredServiceKeys.contains(
          NativeRuntimeLaunchGraphContract.key($0)
        )
      }
    )

    #expect(
      throws: NativeRuntimeLaunchGraphError.incompleteGraph(.appleOfficial)
    ) {
      _ = try classifier.classify([launchObservation(optional)])
    }
  }

  @Test
  func launchGraphClassifierRejectsMixedOwners() {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let classifier = NativeRuntimeLaunchGraphClassifier(
      manifests: [official, native]
    )
    let observations = [
      NativeRuntimeLaunchServiceObservation(
        label: official.launchServices[0].label,
        domain: official.launchServices[0].domain,
        executableURL: official.launchServices[0].executableURL
      ),
      NativeRuntimeLaunchServiceObservation(
        label: native.launchServices[1].label,
        domain: native.launchServices[1].domain,
        executableURL: native.launchServices[1].executableURL
      ),
    ]

    #expect(throws: NativeRuntimeLaunchGraphError.mixedOwners) {
      _ = try classifier.classify(observations)
    }
  }

  @Test
  func launchGraphClassifierRejectsUnknownExecutableOwner() {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let classifier = NativeRuntimeLaunchGraphClassifier(
      manifests: [official, native]
    )
    let observation = NativeRuntimeLaunchServiceObservation(
      label: native.launchServices[0].label,
      domain: native.launchServices[0].domain,
      executableURL: URL(filePath: "/tmp/unreviewed-container-apiserver")
    )

    #expect(throws: NativeRuntimeLaunchGraphError.self) {
      _ = try classifier.classify([observation])
    }
  }

  @Test
  func activeRuntimeFacadeRequiresVerifiedNativePackageAndNativeLaunchGraph() async throws {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let distributions = DistributionVerifierDouble()
    let verifier = ActiveNativeRuntimeVerifier(
      nativeManifest: native,
      allManifests: [official, native],
      distributionVerifier: distributions,
      graphSnapshotter: SnapshotDouble([observations(for: native)])
    )

    let verified = try await verifier.verifyActiveNativeRuntime()

    #expect(verified.origin == .nativeContainers)
    #expect(verified.builderArtifact == .pinned)
    #expect(await distributions.origins == [.nativeContainers])
  }

  @Test
  func activeRuntimeFacadeRejectsHealthEquivalentPackageWhenAppleGraphOwnsServices() async {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let verifier = ActiveNativeRuntimeVerifier(
      nativeManifest: native,
      allManifests: [official, native],
      distributionVerifier: DistributionVerifierDouble(),
      graphSnapshotter: SnapshotDouble([observations(for: official)])
    )

    await #expect(throws: NativeRuntimeActivationError.self) {
      _ = try await verifier.verifyActiveNativeRuntime()
    }
  }

  @Test
  func activationStopsAndVerifiesOfficialGraphBeforeStartingNativeGraph() async throws {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let snapshots = SnapshotDouble([
      observations(for: official),
      [],
      observations(for: native),
    ])
    let controller = GraphControllerDouble()
    let distributions = DistributionVerifierDouble()
    let coordinator = NativeRuntimeActivationCoordinator(
      manifests: [official, native],
      distributionVerifier: distributions,
      graphSnapshotter: snapshots,
      graphController: controller
    )

    try await coordinator.activate(.nativeContainers)

    #expect(
      await controller.operations
        == [
          .stop(.appleOfficial),
          .start(.nativeContainers),
        ]
    )
    #expect(
      await distributions.origins
        == [.nativeContainers, .appleOfficial]
    )
  }

  @Test
  func failedNativeActivationRollsBackToUnchangedOfficialDistribution() async {
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let snapshots = SnapshotDouble([
      observations(for: official),
      [],
      [],
      observations(for: official),
    ])
    let controller = GraphControllerDouble(
      failingOperation: .start(.nativeContainers)
    )
    let distributions = DistributionVerifierDouble()
    let coordinator = NativeRuntimeActivationCoordinator(
      manifests: [official, native],
      distributionVerifier: distributions,
      graphSnapshotter: snapshots,
      graphController: controller
    )

    await #expect(throws: NativeRuntimeActivationError.self) {
      try await coordinator.activate(.nativeContainers)
    }

    #expect(
      await controller.operations
        == [
          .stop(.appleOfficial),
          .start(.nativeContainers),
          .stop(.nativeContainers),
          .start(.appleOfficial),
        ]
    )
    #expect(
      await distributions.origins
        == [.nativeContainers, .appleOfficial, .appleOfficial]
    )
  }

  @Test
  func migrationCopiesOnlyPersistentSelectionsAndNeverChangesAppleSource() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let official = testManifest(origin: .appleOfficial)
    let native = testManifest(origin: .nativeContainers)
    let service = NativeRuntimeMigrationService(
      manifests: [official, native],
      graphSnapshotter: SnapshotDouble([[], []])
    )
    let sourceData = try Data(
      contentsOf: fixture.sourceRoot
        .appending(path: NativeRuntimePersistentDataCategory.machines.rawValue)
        .appending(path: "data.bin")
    )

    let result = try await service.migrate(fixture.layout)

    guard case .migrated(let fingerprint) = result else {
      Issue.record("Expected a fresh migration.")
      return
    }
    #expect(fingerprint.count == 64)
    for category in NativeRuntimePersistentDataCategory.allCases {
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.destinationRoot
            .appending(path: category.rawValue)
            .appending(path: "data.bin")
            .path
        )
      )
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.destinationRoot
          .appending(path: NativeRuntimePersistentDataCategory.imagesAndContent.rawValue)
          .appending(path: "daemon.log")
          .path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.destinationRoot
          .appending(path: NativeRuntimePersistentDataCategory.volumes.rawValue)
          .appending(path: "worker.pid")
          .path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.destinationRoot
          .appending(path: NativeRuntimePersistentDataCategory.configuration.rawValue)
          .appending(path: "launch.plist")
          .path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.destinationRoot
          .appending(path: NativeRuntimePersistentDataCategory.networks.rawValue)
          .appending(path: "logs")
          .path
      )
    )
    #expect(
      try Data(
        contentsOf: fixture.sourceRoot
          .appending(path: NativeRuntimePersistentDataCategory.machines.rawValue)
          .appending(path: "data.bin")
      ) == sourceData
    )
  }

  @Test
  func migrationFailureRemovesOnlyStagingAndPreservesAppleSource() async {
    let fixture: MigrationFixture
    do {
      fixture = try MigrationFixture()
    } catch {
      Issue.record("Could not create fixture: \(error)")
      return
    }
    defer { fixture.remove() }
    let sourceFile = fixture.sourceRoot
      .appending(path: NativeRuntimePersistentDataCategory.imagesAndContent.rawValue)
      .appending(path: "data.bin")
    let original = try? Data(contentsOf: sourceFile)
    let service = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[]]),
      copier: FailingMigrationCopier()
    )

    await #expect(throws: NativeRuntimeMigrationError.self) {
      _ = try await service.migrate(fixture.layout)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.destinationRoot.path))
    #expect((try? Data(contentsOf: sourceFile)) == original)
    #expect((try? fixture.partialMigrationDirectories().isEmpty) == true)
  }

  @Test
  func productionContractsPinOfficialAndNativeRuntimeOrigins() throws {
    let digests = try NativeRuntimeSignedBinaryDigestCatalog(
      container: String(repeating: "a", count: 64),
      containerAPIServer: String(repeating: "b", count: 64),
      containerRuntimeLinux: String(repeating: "c", count: 64),
      containerNetworkVMNet: String(repeating: "d", count: 64),
      containerCoreImages: String(repeating: "e", count: 64),
      machineAPIServer: String(repeating: "f", count: 64)
    )
    let official = NativeRuntimeProductionContractFactory.officialManifest(
      userID: 501
    )
    let native = NativeRuntimeProductionContractFactory.nativeManifest(
      signedBinaryDigests: digests,
      userID: 501
    )

    #expect(official.origin == .appleOfficial)
    #expect(official.installRootURL.path == "/usr/local")
    #expect(official.teamIdentifier == "UPBK2H6LZM")
    #expect(official.builderArtifact == nil)
    #expect(native.origin == .nativeContainers)
    #expect(native.packageVersion == "1.0.0-nc.2")
    #expect(native.teamIdentifier == "6UHAW5UAT4")
    #expect(native.builderArtifact == .pinned)
    #expect(
      native.installRootURL.path
        == "/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2"
    )
    #expect(Set(official.launchServices.map(\.label)) == Set(native.launchServices.map(\.label)))
    #expect(native.launchServices.allSatisfy { $0.domain == "gui/501" })
    let classifiedServices =
      NativeRuntimeProductionContractFactory.launchServicesByOrigin(
        userID: 501
      )
    #expect(classifiedServices[.appleOfficial] == official.launchServices)
    #expect(classifiedServices[.nativeContainers] == native.launchServices)
    let commands = NativeRuntimeProductionContractFactory.controlCommands()
    #expect(commands[.appleOfficial]?.executableURL.path == "/usr/local/bin/container")
    #expect(
      commands[.nativeContainers]?.executableURL.path
        == "/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2/bin/container"
    )
    #expect(
      commands.values.allSatisfy {
        $0.executableURL.lastPathComponent == "container"
          && $0.startArguments == ["system", "start"]
          && $0.stopArguments == ["system", "stop"]
      }
    )
    #expect(
      native.artifacts.contains {
        $0.relativePath == "etc/container/config.toml"
          && $0.sha256
            == "15d02e3707d200579e23f03cf883bc8980a9dc4bfc3ea4f6e09224b17737892a"
          && $0.role == .data
      }
    )
    #expect(
      native.artifacts.contains {
        $0.relativePath
          == "share/nativecontainers-runtime/container-builder-shim-0.12.0-nc.2.oci.tar"
          && $0.sha256
            == "d872daa5ff4534aeb18fb747e015e56cef1cd1b584e05d725b72b624b41a7680"
          && $0.role == .data
      }
    )
  }

  @Test
  func bundledReleaseContractPinsEverySignedRuntimeBinary() throws {
    let data = try releaseContractJSON()
    let catalog =
      try BundledNativeRuntimeReleaseContractLoader
      .decodeSignedBinaryDigests(data)

    #expect(catalog.container == String(repeating: "a", count: 64))
    #expect(catalog.containerAPIServer == String(repeating: "b", count: 64))
    #expect(catalog.containerRuntimeLinux == String(repeating: "c", count: 64))
    #expect(catalog.containerNetworkVMNet == String(repeating: "d", count: 64))
    #expect(catalog.containerCoreImages == String(repeating: "e", count: 64))
    #expect(catalog.machineAPIServer == String(repeating: "f", count: 64))
  }

  @Test
  func bundledReleaseContractRejectsUnreviewedArtifactSet() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: releaseContractJSON())
        as? [String: Any]
    )
    var digests = try #require(
      object["signedBinarySHA256"] as? [String: String]
    )
    digests["bin/unreviewed-helper"] = String(repeating: "0", count: 64)
    object["signedBinarySHA256"] = digests
    let data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )

    #expect(throws: NativeRuntimeDistributionError.self) {
      _ =
        try BundledNativeRuntimeReleaseContractLoader
        .decodeSignedBinaryDigests(data)
    }
  }

  @Test
  func buildSSHGateRequiresVerifiedNativePackageAndLaunchGraph() async throws {
    let activeVerifier = ActiveRuntimeVerifierDouble(
      distribution: verifiedDistribution(origin: .nativeContainers)
    )
    let verifier = NativeContainersImageBuildRuntimeCapabilityVerifier(
      activeRuntimeVerifier: activeVerifier
    )

    try await verifier.verifyBuildSSHSupport()

    #expect(await activeVerifier.callCount == 1)
  }

  @Test
  func capabilityGatesRejectVersionStringWithoutVerifiedNativeOrigin() async {
    let spoofed = ActiveRuntimeVerifierDouble(
      distribution: verifiedDistribution(
        origin: .appleOfficial,
        version: "1.0.0-nc.2"
      )
    )
    let buildVerifier = NativeContainersImageBuildRuntimeCapabilityVerifier(
      activeRuntimeVerifier: spoofed
    )
    let snapshotVerifier =
      NativeContainersLinuxMachineSnapshotRuntimeVerifier(
        activeRuntimeVerifier: spoofed
      )

    await #expect(throws: ImageBuildError.self) {
      try await buildVerifier.verifyBuildSSHSupport()
    }
    await #expect(throws: LinuxMachineSnapshotError.self) {
      try await snapshotVerifier.verifySnapshotSupport()
    }
    #expect(await spoofed.callCount == 2)
  }

  @Test
  func productionMigrationLayoutSelectsEveryPersistentAppleRuntimeStore() {
    let home = URL(filePath: "/Users/runtime-test", directoryHint: .isDirectory)
    let layout = NativeRuntimeProductionContractFactory.migrationLayout(
      homeDirectoryURL: home
    )

    #expect(
      layout.sourceRootURL.path
        == "/Users/runtime-test/Library/Application Support/com.apple.container"
    )
    #expect(
      layout.destinationRootURL.path
        == "/Users/runtime-test/Library/Application Support/NativeContainers/Container Runtime"
    )
    #expect(
      layout.selections
        == [
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

  @Test
  func migrationAllowsAnAbsentOptionalConfigurationFile() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let layout = NativeRuntimeMigrationLayout(
      sourceRootURL: fixture.sourceRoot,
      destinationRootURL: fixture.destinationRoot,
      selections: fixture.layout.selections + [
        NativeRuntimeMigrationSelection(
          category: .configuration,
          sourceRelativePath: "config/config.toml",
          destinationRelativePath: "config/config.toml",
          isRequired: false
        )
      ]
    )
    let service = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[], []])
    )

    let result = try await service.migrate(layout)

    guard case .migrated = result else {
      Issue.record("Expected migration with an absent optional configuration.")
      return
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.destinationRoot
          .appending(path: "config/config.toml")
          .path
      )
    )
  }

  @Test
  func migrationAllowsMultipleSelectionsForOnePersistentCategory() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let secondContent = fixture.sourceRoot.appending(
      path: "snapshots",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: secondContent,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try Data("snapshot-content".utf8).write(
      to: secondContent.appending(path: "data.bin")
    )
    let layout = NativeRuntimeMigrationLayout(
      sourceRootURL: fixture.sourceRoot,
      destinationRootURL: fixture.destinationRoot,
      selections: fixture.layout.selections + [
        NativeRuntimeMigrationSelection(
          category: .imagesAndContent,
          sourceRelativePath: "snapshots",
          destinationRelativePath: "snapshots"
        )
      ]
    )
    let service = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[], []])
    )

    let result = try await service.migrate(layout)

    guard case .migrated = result else {
      Issue.record("Expected migration with multiple content selections.")
      return
    }
    #expect(
      try Data(
        contentsOf: fixture.destinationRoot
          .appending(path: "snapshots")
          .appending(path: "data.bin")
      ) == Data("snapshot-content".utf8)
    )
  }

  @Test
  func migrationRejectsSymlinkSourceEntry() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let file = fixture.persistentFile(in: .imagesAndContent)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(
      at: file,
      withDestinationURL: fixture.persistentFile(in: .volumes)
    )

    await expectUnsafeMigration(fixture: fixture)
  }

  @Test
  func migrationRejectsHardLinkedSourceEntry() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let file = fixture.persistentFile(in: .imagesAndContent)
    try FileManager.default.linkItem(
      at: file,
      to: file.deletingLastPathComponent().appending(path: "alias.bin")
    )

    await expectUnsafeMigration(fixture: fixture)
  }

  @Test
  func migrationRejectsGroupOrWorldWritableSourceEntry() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    #expect(chmod(fixture.persistentFile(in: .imagesAndContent).path, 0o666) == 0)

    await expectUnsafeMigration(fixture: fixture)
  }

  @Test
  func migrationRejectsForeignOwnerContract() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let service = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[]]),
      copier: CloneOrCopyNativeRuntimePersistentDataCopier(
        requiredOwnerUID: getuid() &+ 1
      )
    )

    await #expect(throws: NativeRuntimeMigrationError.self) {
      _ = try await service.migrate(fixture.layout)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationRoot.path))
  }

  @Test
  func migrationPublishFailureCleansStagingAndPreservesSource() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let source = fixture.persistentFile(in: .machines)
    let original = try Data(contentsOf: source)
    let service = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[], []]),
      publisher: FailingMigrationPublisher(failure: .beforePublish)
    )

    await #expect(throws: NativeRuntimeMigrationError.self) {
      _ = try await service.migrate(fixture.layout)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.destinationRoot.path))
    #expect(try Data(contentsOf: source) == original)
    #expect(try fixture.partialMigrationDirectories().isEmpty)
  }

  @Test
  func migrationRecoversFromParentSyncFailureAfterAtomicPublish() async throws {
    let fixture = try MigrationFixture()
    defer { fixture.remove() }
    let firstService = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[], []]),
      publisher: FailingMigrationPublisher(failure: .afterPublish)
    )

    await #expect(throws: NativeRuntimeMigrationError.self) {
      _ = try await firstService.migrate(fixture.layout)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.destinationRoot.path))

    let recoveryService = NativeRuntimeMigrationService(
      manifests: [
        testManifest(origin: .appleOfficial),
        testManifest(origin: .nativeContainers),
      ],
      graphSnapshotter: SnapshotDouble([[]])
    )
    let result = try await recoveryService.migrate(fixture.layout)
    guard case .alreadyCompleted(let fingerprint) = result else {
      Issue.record("Expected recovery through the durable completion marker.")
      return
    }
    #expect(fingerprint.count == 64)
    #expect(try fixture.partialMigrationDirectories().isEmpty)
  }
}

private func expectUnsafeMigration(
  fixture: MigrationFixture
) async {
  let service = NativeRuntimeMigrationService(
    manifests: [
      testManifest(origin: .appleOfficial),
      testManifest(origin: .nativeContainers),
    ],
    graphSnapshotter: SnapshotDouble([[]])
  )
  await #expect(throws: NativeRuntimeMigrationError.self) {
    _ = try await service.migrate(fixture.layout)
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.destinationRoot.path))
}

private func releaseContractJSON() throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 1,
      "runtimeVersion": "1.0.0-nc.2",
      "packageIdentifier": "com.nativecontainers.runtime",
      "installRoot":
        "/Library/Application Support/NativeContainers/Runtime/1.0.0-nc.2",
      "signingTeamIdentifier": "6UHAW5UAT4",
      "builderShimVersion": "0.12.0-nc.2",
      "builderShimSourceRevision":
        "f66f1680fe6b74d814fb5527247e7d81227fcecb",
      "builderImageDigest":
        "sha256:b3574dc6b867fc91d1ed1d2941c74811961e2645ffa4c1fc68c19ae69e5fdbff",
      "signedBinarySHA256": [
        "bin/container": String(repeating: "a", count: 64),
        "bin/container-apiserver": String(repeating: "b", count: 64),
        "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux":
          String(repeating: "c", count: 64),
        "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet":
          String(repeating: "d", count: 64),
        "libexec/container/plugins/container-core-images/bin/container-core-images":
          String(repeating: "e", count: 64),
        "libexec/container/plugins/machine-apiserver/bin/machine-apiserver":
          String(repeating: "f", count: 64),
      ],
    ],
    options: [.sortedKeys]
  )
}

private func verifiedDistribution(
  origin: NativeRuntimeOrigin,
  version: String = "1.0.0-nc.2"
) -> NativeRuntimeVerifiedDistribution {
  NativeRuntimeVerifiedDistribution(
    origin: origin,
    packageIdentifier:
      origin == .nativeContainers
      ? "com.nativecontainers.runtime"
      : "com.apple.container-installer",
    version: version,
    installRootURL:
      origin == .nativeContainers
      ? NativeRuntimeProductionContractFactory.nativeInstallRootURL
      : URL(filePath: "/usr/local", directoryHint: .isDirectory),
    builderArtifact: .pinned,
    serviceExecutablePaths: [:]
  )
}

private func testManifest(
  origin: NativeRuntimeOrigin
) -> NativeRuntimeDistributionManifest {
  let root =
    origin == .appleOfficial
    ? URL(filePath: "/usr/local/libexec/apple-container")
    : URL(filePath: "/Library/NativeContainers/Runtime")
  let prefix =
    origin == .appleOfficial
    ? "com.apple.container"
    : "com.nativecontainers.runtime"
  return NativeRuntimeDistributionManifest(
    origin: origin,
    packageIdentifier:
      origin == .appleOfficial
      ? "com.apple.container-installer"
      : "com.nativecontainers.runtime",
    packageVersion: origin == .appleOfficial ? "1.0.0" : "1.0.0-nc.2",
    installRootURL: root,
    teamIdentifier:
      origin == .appleOfficial
      ? "UPBK2H6LZM"
      : NativeRuntimeDistributionManifest.nativeContainersTeamIdentifier,
    builderArtifact: .pinned,
    artifacts: [
      NativeRuntimePackageArtifact(
        relativePath: "libexec/container-apiserver",
        sha256: String(repeating: "a", count: 64),
        maximumByteCount: 64 * 1_024 * 1_024,
        role: .launchService(
          label: "com.apple.container.apiserver",
          domain: "system",
          signingIdentifier: "\(prefix).api"
        )
      ),
      NativeRuntimePackageArtifact(
        relativePath: "libexec/container-network-vmnet",
        sha256: String(repeating: "b", count: 64),
        maximumByteCount: 64 * 1_024 * 1_024,
        role: .launchService(
          label: "com.apple.container.network-vmnet",
          domain: "system",
          signingIdentifier: "\(prefix).network"
        )
      ),
      NativeRuntimePackageArtifact(
        relativePath: "share/builder-artifact.json",
        sha256: String(repeating: "c", count: 64),
        maximumByteCount: 4 * 1_024,
        role: .builderArtifactMetadata
      ),
    ]
  )
}

private func observations(
  for manifest: NativeRuntimeDistributionManifest
) -> [NativeRuntimeLaunchServiceObservation] {
  manifest.launchServices.map {
    NativeRuntimeLaunchServiceObservation(
      label: $0.label,
      domain: $0.domain,
      executableURL: $0.executableURL
    )
  }
}

private func launchObservation(
  _ service: NativeRuntimeLaunchServiceContract
) -> NativeRuntimeLaunchServiceObservation {
  NativeRuntimeLaunchServiceObservation(
    label: service.label,
    domain: service.domain,
    executableURL: service.executableURL
  )
}

private func observation(sha256: String) -> NativeRuntimeArtifactObservation {
  NativeRuntimeArtifactObservation(
    sha256: sha256,
    byteCount: 128,
    device: 1,
    inode: 2
  )
}

private func builderMetadataJSON() throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(NativeRuntimeBuilderArtifactContract.pinned)
  return String(decoding: data, as: UTF8.self)
}

private actor ReceiptReaderDouble: NativeRuntimePackageReceiptReading {
  let storedReceipt: NativeRuntimePackageReceipt?

  init(receipt: NativeRuntimePackageReceipt?) {
    storedReceipt = receipt
  }

  func receipt(packageIdentifier: String) async throws -> NativeRuntimePackageReceipt? {
    storedReceipt
  }
}

private final class ArtifactInspectorDouble:
  NativeRuntimeArtifactInspecting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var observations: [String: [NativeRuntimeArtifactObservation]]
  private let smallFileContents: [String: String]
  private let error: NativeRuntimeDistributionError?

  init(
    observations: [String: [NativeRuntimeArtifactObservation]] = [:],
    smallFileContents: [String: String] = [:],
    error: NativeRuntimeDistributionError? = nil
  ) {
    self.observations = observations
    self.smallFileContents = smallFileContents
    self.error = error
  }

  func inspect(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact
  ) throws -> NativeRuntimeArtifactObservation {
    if let error { throw error }
    return try lock.withLock {
      guard
        var values = observations[artifact.relativePath],
        !values.isEmpty
      else {
        throw NativeRuntimeDistributionError.unsafeArtifact(
          artifact.relativePath
        )
      }
      let value = values.removeFirst()
      observations[artifact.relativePath] = values
      return value
    }
  }

  func readSmallUTF8File(
    installRootURL: URL,
    artifact: NativeRuntimePackageArtifact,
    maximumByteCount: Int
  ) throws -> String {
    guard let value = smallFileContents[artifact.relativePath] else {
      throw NativeRuntimeDistributionError.unsafeArtifact(
        artifact.relativePath
      )
    }
    return value
  }
}

private final class SignatureValidatorDouble:
  NativeRuntimeCodeSignatureValidating,
  @unchecked Sendable
{
  struct Call: Equatable {
    let url: URL
    let teamIdentifier: String
    let signingIdentifier: String
  }

  private let lock = NSLock()
  private var storedCalls: [Call] = []

  var calls: [Call] {
    lock.withLock { storedCalls }
  }

  func validate(
    codeAt url: URL,
    teamIdentifier: String,
    signingIdentifier: String
  ) throws {
    lock.withLock {
      storedCalls.append(
        Call(
          url: url,
          teamIdentifier: teamIdentifier,
          signingIdentifier: signingIdentifier
        )
      )
    }
  }
}

private actor ActiveRuntimeVerifierDouble: ActiveNativeRuntimeVerifying {
  let distribution: NativeRuntimeVerifiedDistribution
  private(set) var callCount = 0

  init(distribution: NativeRuntimeVerifiedDistribution) {
    self.distribution = distribution
  }

  func verifyActiveNativeRuntime() async throws
    -> NativeRuntimeVerifiedDistribution
  {
    callCount += 1
    return distribution
  }
}

private actor DistributionVerifierDouble: NativeRuntimeDistributionVerifying {
  private(set) var origins: [NativeRuntimeOrigin] = []

  func verify(
    _ manifest: NativeRuntimeDistributionManifest
  ) async throws -> NativeRuntimeVerifiedDistribution {
    origins.append(manifest.origin)
    return NativeRuntimeVerifiedDistribution(
      origin: manifest.origin,
      packageIdentifier: manifest.packageIdentifier,
      version: manifest.packageVersion,
      installRootURL: manifest.installRootURL,
      builderArtifact: manifest.builderArtifact,
      serviceExecutablePaths: Dictionary(
        uniqueKeysWithValues: manifest.launchServices.map {
          ($0.label, $0.executableURL)
        }
      )
    )
  }
}

private actor SnapshotDouble: NativeRuntimeLaunchGraphSnapshotting {
  private var snapshots: [[NativeRuntimeLaunchServiceObservation]]

  init(_ snapshots: [[NativeRuntimeLaunchServiceObservation]]) {
    self.snapshots = snapshots
  }

  func snapshot() async throws -> [NativeRuntimeLaunchServiceObservation] {
    guard !snapshots.isEmpty else {
      throw NativeRuntimeLaunchGraphError.inspectionFailed(
        "No snapshot remains."
      )
    }
    return snapshots.removeFirst()
  }
}

private enum GraphOperation: Equatable, Sendable {
  case start(NativeRuntimeOrigin)
  case stop(NativeRuntimeOrigin)
}

private enum GraphControllerTestError: Error {
  case configuredFailure
}

private actor GraphControllerDouble: NativeRuntimeGraphControlling {
  private(set) var operations: [GraphOperation] = []
  private let failingOperation: GraphOperation?

  init(failingOperation: GraphOperation? = nil) {
    self.failingOperation = failingOperation
  }

  func start(_ origin: NativeRuntimeOrigin) async throws {
    let operation = GraphOperation.start(origin)
    operations.append(operation)
    if operation == failingOperation {
      throw GraphControllerTestError.configuredFailure
    }
  }

  func stop(_ origin: NativeRuntimeOrigin) async throws {
    let operation = GraphOperation.stop(origin)
    operations.append(operation)
    if operation == failingOperation {
      throw GraphControllerTestError.configuredFailure
    }
  }
}

private struct FailingMigrationCopier: NativeRuntimePersistentDataCopying {
  func copyPersistentData(
    layout: NativeRuntimeMigrationLayout,
    stagingRootURL: URL
  ) throws -> String {
    try FileManager.default.createDirectory(
      at: stagingRootURL.appending(path: "partial"),
      withIntermediateDirectories: false
    )
    throw NativeRuntimeMigrationError.copyFailed("injected failure")
  }
}

private struct FailingMigrationPublisher: NativeRuntimeMigrationPublishing {
  enum Failure: Equatable {
    case beforePublish
    case afterPublish
  }

  let failure: Failure
  private let publisher = AtomicNativeRuntimeMigrationPublisher()

  func synchronizeStagedTree(at stagingRootURL: URL) throws {
    try publisher.synchronizeStagedTree(at: stagingRootURL)
  }

  func publish(stagingRootURL: URL, destinationRootURL: URL) throws {
    if failure == .beforePublish {
      throw NativeRuntimeMigrationError.publishFailed("injected pre-publish failure")
    }
    try publisher.publish(
      stagingRootURL: stagingRootURL,
      destinationRootURL: destinationRootURL
    )
  }

  func synchronizeParent(of destinationRootURL: URL) throws {
    if failure == .afterPublish {
      throw NativeRuntimeMigrationError.publishFailed("injected parent sync failure")
    }
    try publisher.synchronizeParent(of: destinationRootURL)
  }
}

private struct MigrationFixture {
  let root: URL
  let sourceRoot: URL
  let destinationRoot: URL
  let layout: NativeRuntimeMigrationLayout

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "native-runtime-migration-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    sourceRoot = root.appending(path: "apple", directoryHint: .isDirectory)
    destinationRoot = root.appending(path: "native", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    var selections: [NativeRuntimeMigrationSelection] = []
    for category in NativeRuntimePersistentDataCategory.allCases {
      let directory = sourceRoot.appending(
        path: category.rawValue,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try Data("persistent-\(category.rawValue)".utf8).write(
        to: directory.appending(path: "data.bin")
      )
      selections.append(
        NativeRuntimeMigrationSelection(
          category: category,
          sourceRelativePath: category.rawValue,
          destinationRelativePath: category.rawValue
        )
      )
    }

    try Data("log".utf8).write(
      to:
        sourceRoot
        .appending(path: NativeRuntimePersistentDataCategory.imagesAndContent.rawValue)
        .appending(path: "daemon.log")
    )
    try Data("123".utf8).write(
      to:
        sourceRoot
        .appending(path: NativeRuntimePersistentDataCategory.volumes.rawValue)
        .appending(path: "worker.pid")
    )
    try Data("plist".utf8).write(
      to:
        sourceRoot
        .appending(path: NativeRuntimePersistentDataCategory.configuration.rawValue)
        .appending(path: "launch.plist")
    )
    let logs =
      sourceRoot
      .appending(path: NativeRuntimePersistentDataCategory.networks.rawValue)
      .appending(path: "logs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
    try Data("runtime".utf8).write(to: logs.appending(path: "network.txt"))

    layout = NativeRuntimeMigrationLayout(
      sourceRootURL: sourceRoot,
      destinationRootURL: destinationRoot,
      selections: selections
    )
  }

  func persistentFile(
    in category: NativeRuntimePersistentDataCategory
  ) -> URL {
    sourceRoot
      .appending(path: category.rawValue, directoryHint: .isDirectory)
      .appending(path: "data.bin", directoryHint: .notDirectory)
  }

  func partialMigrationDirectories() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(".nativecontainers-runtime-")
        && $0.lastPathComponent.hasSuffix(".partial")
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
